`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// spc7110_bsram.v
// Block RAM for SPC7110 battery-backed SRAM.
// 32768 x 8 bits. Port A is used by the SPC7110 core; Port B is reserved
// for MCU save-file load/store (currently unused; will be hooked up in Step 3).
//
// Quartus infers this as M9K blocks (B-port is optimised away when unconnected).
//
// Power-on default: all $FF, loaded from spc7110_bsram_init.mif at bitstream
// load time. This matches how real battery-backed S-RAM behaves when the
// coin battery is dead or the cart is factory-fresh. Some SPC7110 games
// (notably Tengai Makyou Zero) check specific S-RAM bytes as flags for
// MODE 1/MODE 2 self-check state; initializing BSRAM to $00 (FPGA default)
// would make flag checks see spurious "MODE 2 already ran" state on cold
// boot, causing game crashes.
//////////////////////////////////////////////////////////////////////////////////
module spc7110_bsram (
  input         clock,
  input  [14:0] address_a,
  input  [7:0]  data_a,
  input         wren_a,
  output reg [7:0] q_a,
  input  [14:0] address_b,
  input  [7:0]  data_b,
  input         wren_b,
  output reg [7:0] q_b
);

// RAM with explicit MIF-based initialization. The ramstyle and ram_init_file
// attributes tell Quartus to infer M9K blocks and pre-populate them from
// the provided .mif file at bitstream-load time.
(* ramstyle = "M9K", ram_init_file = "spc7110_bsram_init.mif" *)
reg [7:0] mem [0:32767];

always @(posedge clock) begin
  if (wren_a) mem[address_a] <= data_a;
  q_a <= mem[address_a];
end

always @(posedge clock) begin
  if (wren_b) mem[address_b] <= data_b;
  q_b <= mem[address_b];
end

endmodule
