`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// xc_msubox: the MSU-1 core's replacement for xc_decbox (fpga_xc_msu.bi3, `define XC_MSU).
//
// The music comes from an MSU-1 pack instead of the Opus streams: the soft CPU's mixer turns the game's
// track starts into MSU-1 register writes (socfw/xc_mix.c, "MSU-1 mode"). Same place in the soft CPU's
// address map as the decode mailbox (see socfw/xc_soc.h):
//   0x000 CTRL    read: bit 3 = 1 (MSU-1 core; the Opus core reads 0 there). Writes are ignored.
//   0x010 MSUREG  write: bits 2:0 = MSU-1 register ($2000 + n), bits 15:8 = value (msu.v register write)
//   0x014 MSUSTAT read: the MSU-1 status byte ($2000 read: data busy, audio busy, repeat, playing, error, 010)
// Reads take one extra cycle, like the mailbox's.
//////////////////////////////////////////////////////////////////////////////////
module xc_msubox (
  input clk,
  input rst,

  // soft core
  input sel,
  input we,
  input [11:2] addr,
  input [31:0] wdata,
  output reg [31:0] rdata,
  output ready,

  // msu.v register port
  output reg msu_we,           // one-cycle write strobe
  output reg [2:0] msu_addr,
  output reg [7:0] msu_data,
  input [7:0] msu_status
);

reg rd_pending;
assign ready = sel & (we | rd_pending);

always @(posedge clk) begin
  msu_we <= 1'b0;
  if(rst) begin
    rd_pending <= 1'b0;
  end else begin
    rd_pending <= sel & ~we & ~rd_pending;
    if(sel && !we && !rd_pending) begin
      case(addr[11:2])
        10'h000: rdata <= 32'h8;
        10'h005: rdata <= {24'd0, msu_status};
        default: rdata <= 32'd0;
      endcase
    end
    if(sel && we && addr[11:2] == 10'h004) begin
      msu_we <= 1'b1;
      msu_addr <= wdata[2:0];
      msu_data <= wdata[15:8];
    end
  end
end

endmodule
