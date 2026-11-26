/*
 * Copyright (c) 2026 Khushi Vishwanath, Harshil Kundety, Adi Redkar
 * SPDX-License-Identifier: Apache-2.0
 *
 * Ring-Oscillator Jitter TRNG
 * ---------------------------
 * A true random number generator that harvests physical entropy from the
 * timing jitter of free-running ring oscillators, rather than producing a
 * deterministic pseudo-random sequence from an LFSR.
 *
 * Flow:   3 ring oscillators (odd inverter chains, different lengths)
 *      -> 2-FF synchronizers into the clk domain
 *      -> XOR mixing            (raw entropy bit, 1 per clk)
 *      -> von Neumann debiaser  (removes static bias)
 *      -> 8-bit assembler       (serial bit -> parallel byte)
 *      -> optional LFSR whitener
 *
 * NOTE on simulation vs. hardware:
 *   A bare combinational ring is a zero-delay loop that stalls an RTL
 *   (event-driven) simulator.  For the cocotb RTL test we therefore define
 *   SIM_RO (see test/Makefile) which swaps the physical rings for a
 *   behavioural jitter emulator (two differently-seeded LFSRs) so the whole
 *   datapath and its statistics can be exercised.  Synthesis (LibreLane) and
 *   gate-level simulation use the real combinational rings.
 */

`default_nettype none

module tt_um_harshilkundety_ro_trng (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------------
  // Controls
  // ---------------------------------------------------------------------------
  wire enable    = ui_in[0];   // gate the entropy source + datapath
  wire whiten_en = ui_in[1];   // XOR the assembled byte with an LFSR whitener

  // ---------------------------------------------------------------------------
  // Entropy source -> raw entropy bit (1 sample per clk)
  // ---------------------------------------------------------------------------
  wire raw_bit;

`ifdef SIM_RO
  // -------- Behavioural jitter emulator (simulation only) --------
  // Two maximal-length LFSRs of different lengths, advanced every clk and
  // XOR-mixed.  This is NOT the hardware; it only gives the RTL testbench a
  // well-distributed raw bit stream so the debiaser / assembler / statistics
  // can be verified without a zero-delay combinational loop.
  reg [14:0] lfsr_a;
  reg [16:0] lfsr_b;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsr_a <= 15'h3A5C;
      lfsr_b <= 17'h1C2F3;
    end else if (enable) begin
      // x^15 + x^14 + 1
      lfsr_a <= {lfsr_a[13:0], lfsr_a[14] ^ lfsr_a[13]};
      // x^17 + x^14 + 1
      lfsr_b <= {lfsr_b[15:0], lfsr_b[16] ^ lfsr_b[13]};
    end
  end
  assign raw_bit = lfsr_a[0] ^ lfsr_b[0] ^ lfsr_b[9];
`else
  // -------- Physical ring oscillators (hardware) --------
  wire ro0, ro1, ro2;
  ring_osc #(.STAGES(13)) u_ro0 (.en(enable), .osc(ro0));
  ring_osc #(.STAGES(15)) u_ro1 (.en(enable), .osc(ro1));
  ring_osc #(.STAGES(17)) u_ro2 (.en(enable), .osc(ro2));

  // 2-FF synchronizers: bring each asynchronous oscillator into the clk domain.
  // The metastability / jitter captured here is the entropy.
  reg [2:0] sync0, sync1, sync2;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync0 <= 3'b0;
      sync1 <= 3'b0;
      sync2 <= 3'b0;
    end else begin
      sync0 <= {sync0[1:0], ro0};
      sync1 <= {sync1[1:0], ro1};
      sync2 <= {sync2[1:0], ro2};
    end
  end
  assign raw_bit = sync0[2] ^ sync1[2] ^ sync2[2];
`endif

  // ---------------------------------------------------------------------------
  // Von Neumann debiaser: consume raw bits in pairs.
  //   10 -> emit 1,  01 -> emit 0,  00/11 -> discard.
  // Removes a constant bias in the raw bit probability.
  // ---------------------------------------------------------------------------
  reg       have_prev;   // a first-of-pair bit is held
  reg       prev_bit;    // the held bit
  reg       vn_bit;      // debiased output bit
  reg       vn_valid;    // 1-clk strobe when vn_bit is fresh

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_prev <= 1'b0;
      prev_bit  <= 1'b0;
      vn_bit    <= 1'b0;
      vn_valid  <= 1'b0;
    end else begin
      vn_valid <= 1'b0;
      if (enable) begin
        if (!have_prev) begin
          have_prev <= 1'b1;
          prev_bit  <= raw_bit;
        end else begin
          have_prev <= 1'b0;          // a full pair consumed
          if (prev_bit != raw_bit) begin
            vn_bit   <= prev_bit;     // 10 -> 1, 01 -> 0
            vn_valid <= 1'b1;
          end
          // prev_bit == raw_bit -> discard, emit nothing
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 8-bit assembler: shift debiased bits into a byte.
  // ---------------------------------------------------------------------------
  reg [7:0] shift_reg;
  reg [2:0] bit_count;
  reg [7:0] rand_byte;    // latched output byte
  reg       byte_valid;   // 1-clk strobe when rand_byte is fresh

  // Maximal-length 8-bit LFSR used as a whitener (x^8 + x^6 + x^5 + x^4 + 1).
  reg [7:0] white_lfsr;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_reg  <= 8'b0;
      bit_count  <= 3'b0;
      rand_byte  <= 8'b0;
      byte_valid <= 1'b0;
      white_lfsr <= 8'hA5;
    end else begin
      byte_valid <= 1'b0;
      if (vn_valid) begin
        shift_reg <= {shift_reg[6:0], vn_bit};
        white_lfsr <= {white_lfsr[6:0],
                       white_lfsr[7] ^ white_lfsr[5] ^ white_lfsr[4] ^ white_lfsr[3]};
        if (bit_count == 3'd7) begin
          bit_count  <= 3'd0;
          rand_byte  <= whiten_en ? ({shift_reg[6:0], vn_bit} ^ white_lfsr)
                                  :  {shift_reg[6:0], vn_bit};
          byte_valid <= 1'b1;
        end else begin
          bit_count <= bit_count + 3'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign uo_out = rand_byte;

  assign uio_out[0] = vn_bit;      // serial debiased random bit
  assign uio_out[1] = vn_valid;    // new serial bit available
  assign uio_out[2] = byte_valid;  // new random byte available
  assign uio_out[7:3] = 5'b0;

  assign uio_oe = 8'b0000_0111;    // [2:0] outputs, rest inputs

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, ui_in[7:2], uio_in, 1'b0};

endmodule


// =============================================================================
// Ring oscillator: an enabled combinational inverter loop.
//
// `en` low forces the ring quiet; `en` high makes it a free-running odd
// inverter chain that oscillates at a frequency set by cell + wire delays.
// The cycle-to-cycle jitter of that oscillation is the physical entropy source.
//
// The (* keep *) attributes stop the synthesizer from collapsing the chain of
// inverters (which it would otherwise recognise as a no-op / constant).
// This module is only elaborated for synthesis and gate-level sim; the RTL
// cocotb test uses the SIM_RO behavioural model above instead.
// =============================================================================
`ifndef SIM_RO
module ring_osc #(
    parameter STAGES = 13   // must be odd
) (
    input  wire en,
    output wire osc
);

  (* keep = "true" *) wire [STAGES-1:0] chain;

  // First stage: enable gate + inversion of the loop feedback.
  (* keep = "true" *) wire first_stage = ~(en & chain[STAGES-1]);
  assign chain[0] = first_stage;

  genvar i;
  generate
    for (i = 1; i < STAGES; i = i + 1) begin : g_inv
      (* keep = "true" *) wire inv_stage = ~chain[i-1];
      assign chain[i] = inv_stage;
    end
  endgenerate

  assign osc = chain[STAGES-1];

endmodule
`endif

`default_nettype wire
