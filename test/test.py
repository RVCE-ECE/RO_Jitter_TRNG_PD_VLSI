# SPDX-FileCopyrightText: © 2026 Khushi Vishwanath, Harshil Kundety, Adi Redkar
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the Ring-Oscillator Jitter TRNG.
#
# A TRNG is validated by the *statistics* of its output, not by exact expected
# values (there is no "correct" random byte). The RTL test therefore collects a
# long stream of output bits and checks that they are roughly unbiased and that
# the output bytes are not stuck/repeating. For a full evaluation the collected
# stream would be fed to a suite such as the NIST Statistical Test Suite (STS).
#
# Under gate-level sim (GATES=yes) the ring oscillators are deterministic
# unit-delay loops, so we only smoke-test that the pipeline runs.

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

GL = os.environ.get("GATES", "") == "yes"

# Bit positions on the bidirectional output bus.
SER_BIT = 0
BIT_VALID = 1
BYTE_VALID = 2


async def reset(dut, ui_in=0):
    dut.ena.value = 1
    dut.ui_in.value = ui_in
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def collect(dut, cycles):
    """Run `cycles` clocks, harvesting debiased serial bits and output bytes."""
    bits = []
    byte_vals = []
    for _ in range(cycles):
        await ClockCycles(dut.clk, 1)
        uio = int(dut.uio_out.value)
        if (uio >> BIT_VALID) & 1:
            bits.append((uio >> SER_BIT) & 1)
        if (uio >> BYTE_VALID) & 1:
            byte_vals.append(int(dut.uo_out.value))
    return bits, byte_vals


@cocotb.test()
async def test_runs_and_produces_output(dut):
    """Enable the TRNG and confirm it generates bits and bytes."""
    dut._log.info("Start: enable entropy source, no whitening")
    cocotb.start_soon(Clock(dut.clk, 10, unit="us").start())

    await reset(dut, ui_in=0b01)  # EN=1, WHITEN=0

    if GL:
        # The ring oscillators are combinational loops. In 4-state gate-level
        # simulation an inverter loop seeded at X stays at X (~X == X), so the
        # entropy datapath cannot be evaluated here. Just confirm the design
        # clocks without crashing; randomness is validated in RTL sim (above)
        # and ultimately on hardware with a statistical suite (e.g. NIST STS).
        await ClockCycles(dut.clk, 50)
        dut._log.info("Gate-level: skipping entropy checks (RO is X in 4-state sim)")
        return

    bits, byte_vals = await collect(dut, 20000)
    dut._log.info(f"collected {len(bits)} debiased bits, {len(byte_vals)} bytes")

    # --- RTL statistical checks ---
    assert len(bits) > 1000, f"too few debiased bits produced: {len(bits)}"
    assert len(byte_vals) > 50, f"too few bytes produced: {len(byte_vals)}"

    # Monobit: fraction of 1s should be close to 0.5 after von Neumann debiasing.
    ones = sum(bits)
    frac = ones / len(bits)
    dut._log.info(f"monobit: fraction of 1s = {frac:.4f}")
    assert 0.40 < frac < 0.60, f"serial bit stream looks biased: frac={frac:.4f}"

    # Output bytes must not be stuck at a single value.
    assert len(set(byte_vals)) > 10, "output bytes are not varying (stuck TRNG)"

    # Bit-level balance across whole bytes as a second sanity check.
    byte_ones = sum(bin(b).count("1") for b in byte_vals)
    byte_frac = byte_ones / (8 * len(byte_vals))
    dut._log.info(f"byte-bit fraction of 1s = {byte_frac:.4f}")
    assert 0.40 < byte_frac < 0.60, f"output bytes look biased: frac={byte_frac:.4f}"


@cocotb.test()
async def test_disabled_is_idle(dut):
    """With EN=0 the TRNG should not emit byte-valid strobes."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="us").start())
    await reset(dut, ui_in=0)  # EN=0
    _, byte_vals = await collect(dut, 100 if GL else 2000)
    assert len(byte_vals) == 0, "bytes were produced while disabled"


@cocotb.test()
async def test_whitener_path(dut):
    """With WHITEN=1 the TRNG still produces varied output bytes."""
    if GL:
        return
    cocotb.start_soon(Clock(dut.clk, 10, unit="us").start())
    await reset(dut, ui_in=0b11)  # EN=1, WHITEN=1
    _, byte_vals = await collect(dut, 20000)
    assert len(byte_vals) > 50, f"too few whitened bytes: {len(byte_vals)}"
    assert len(set(byte_vals)) > 10, "whitened output bytes are not varying"
