`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// xc_soc: the RP2040 core 0 replacement for Xeno Crisis on sd2snes mk2 (clk_soc domain). mk2 variant of
// ../sd2snes_xc/xc_soc.v (MSU-1 only), cut down for size:
//   - no SIO hardware divider: xc_soc.bin replaces the pico-sdk divider functions with software division
//     (patch kind 3, applied by the mk2 loader); an access to the divider registers halts (0xBAD00004);
//   - APB (clocks, resets, PLLs, ...; only used while the firmware starts): fixed read values instead of the
//     register shadow in SRAM. The status registers the firmware waits on read as ready; the only state kept
//     is the SRC field of CLK_REF_CTRL / CLK_SYS_CTRL, for their CLK_x_SELECTED registers (the firmware
//     waits for SELECTED == 1 and later for its SRC bit); every other register reads 0, as the shadow did;
//   - NVIC: only IRQ 26 (mixer tick); the MSU-1 core has no decode interrupt;
//   - timer: TIMEHR/TIMELR read the raw counter (the firmware only reads TIMERAWH/TIMERAWL).
//
//   xc_m0 core + I-cache + write-back D-cache (2-way, 32-byte lines; sizes: parameters IIDX, DIDX), a memory controller,
//   the SoC-local peripherals (timer, SIO subset with the hardware divider, NVIC/VTOR, BRR encoder,
//   mixer tick, debug/panic port) and xc_bridge operations for everything on the sd2snes side
//   (PSRAM, SRAM chip, $3000 window, decode mailbox).
//
// Memory map (RP2040 addresses -> sd2snes memories; see SD2SNES_CORE.md):
//   0x00000000-0x00003FFF  bootrom (replacement)       PSRAM 0xD20000        cached, read-only
//   0x10000000-0x13FFFFFF  flash (4 XIP aliases)       offset o:
//       o < 0x020000                                   PSRAM 0xD00000 + o    cached, read-only
//       o < 0xD00000                                   PSRAM o               cached, read-only
//       0xF00000 <= o < 0xF04000 (firmware additions)  PSRAM 0xD24000 + (o & 0x3FFF)
//       o >= 0xFF8000 (save area)                      SRAM 0x00000 + (o & 0x7FFF)  uncached, writable
//       anything else                                  reads 0xFF (erased flash)
//   0x20000000-0x20041FFF  RAM (and the 0x21 alias)    SRAM 0x08000 + o      cached, write-back
//   0x50100000-0x50100FFF  USB RAM                     SRAM 0x4A000 + o      uncached
//   0x40000000-0x400FFFFF  APB                         timer local; the rest: writes ignored, fixed reads
//   0x50800000 BRR, 0x50802000 tick/debug/panic        local
//   0x50801000 decode mailbox, 0x50803000 $3000 window CLK2 side, through the bridge
//   0xD0000000 SIO (CPUID, spinlocks), 0xE0000000 PPB (NVIC, VTOR)   local
//   0x14/0x15/0x18xxxxxx XIP/SSI control: reads 0, writes ignored
//
// Start-up: invalidate the caches, clear SRAM 0x08000-0x4DFFF (RAM, USB RAM, unused 0x4C000-) so the
// firmware starts from the same state as in MesenCE, read SP/PC from the flash vector table at
// 0x10000100 (where boot2 leaves the RP2040), VTOR = 0x10000100, then release the core.
//
// The D-cache is written back to the SRAM chip before the $3000 window's DMA can read it: a write to
// TX_LEN first cleans the lines of [TX_ADDR, TX_ADDR + length) (or the whole cache for long ranges).
//////////////////////////////////////////////////////////////////////////////////
module xc_soc #(
  parameter CLK_NUM = 40,            // clk frequency = CLK_NUM / CLK_DEN MHz (sd2snes PLL: 161/4 = 40.25 MHz)
  parameter CLK_DEN = 1,
  parameter CORE_DEBUG = 0,         // xc_m0 debug read port and counters (lockstep harness only)
  parameter DIDX = 7,               // D-cache sets = 2^DIDX (2 ways x 32 B lines): 7 = 8 KB, 8 = 16 KB
  parameter IIDX = 6                // I-cache sets = 2^IIDX: 6 = 4 KB, 7 = 8 KB, 8 = 16 KB
) (
  input clk,
  input rst,

  // bridge (see xc_bridge.v)
  output reg op_start,
  output reg [2:0] op_kind,
  output reg [23:0] op_addr,
  output reg [5:0] op_len,
  output reg wb_we,                // data words for the bridge (xc_bridge wram)
  output reg [2:0] wb_addr,
  output reg [31:0] wb_data,
  input op_done,
  output [2:0] rb_addr,            // result words (xc_bridge rram, registered read)
  input [31:0] rb_q,

  input dec_irq_tog,               // toggles (CLK2 domain) when the MCU finished a decode job

  // status
  output reg running,              // core released from reset
  output reg halted,               // core fault, bus fault or firmware panic
  output reg [31:0] halt_code,     // core fault code / panic value / 0xBAD0000x bus fault
  output reg [31:0] halt_addr,
  output reg dbg_char_valid,       // debug port (0x50802010)
  output reg [7:0] dbg_char,

  // lockstep / debug access to the core (unused on hardware)
  input step_mode,
  input step_go,
  output step_done,
  input dbg_we,
  input [4:0] dbg_sel,
  input [31:0] dbg_wdata,
  input [4:0] dbg_rsel,
  output [31:0] dbg_rdata,
  // bus observation (simulation checkers)
  output mon_req,
  output mon_ready,
  output mon_we,
  output mon_fetch,
  output [1:0] mon_size,
  output [31:0] mon_addr,
  output [31:0] mon_wdata,
  output [31:0] mon_rdata,
  output [7:0] core_fault_code_o
);

localparam [2:0] OP_PSRAM_RD = 3'd0, OP_SRAM_RD = 3'd1, OP_SRAM_WR = 3'd2,
                 OP_WIN_RD = 3'd3, OP_WIN_WR = 3'd4, OP_DEC_RD = 3'd5, OP_DEC_WR = 3'd6;

//------------------------------------------------------------------------------
// Core
//------------------------------------------------------------------------------
wire bus_req, bus_we, bus_fetch;
wire [1:0] bus_size;
wire [31:0] bus_addr, bus_wdata;
reg bus_ready;
reg [31:0] bus_rdata;
wire bus_next_req;
wire [31:0] bus_next_addr;
reg fast_ready;                     // combinational: cache hits and simple peripheral registers
reg [31:0] fast_rdata;
reg slow_ready;                     // registered: operations that went through the controller
reg [31:0] slow_rdata;
always @* begin
  bus_ready = fast_ready | slow_ready;
  bus_rdata = fast_ready ? fast_rdata : slow_rdata;
end
reg [31:0] vtor;
wire exc_req;
wire [5:0] exc_num;
wire exc_ack;
wire core_fault;
wire [7:0] core_fault_code;
wire sleeping;
reg core_rst;
reg [31:0] reset_sp, reset_pc;

xc_m0 #(.DEBUG(CORE_DEBUG)) core (
  .clk(clk), .rst(core_rst), .reset_sp(reset_sp), .reset_pc(reset_pc),
  .bus_req(bus_req), .bus_we(bus_we), .bus_fetch(bus_fetch), .bus_size(bus_size), .bus_addr(bus_addr),
  .bus_wdata(bus_wdata), .bus_ready(bus_ready), .bus_rdata(bus_rdata),
  .bus_next_req(bus_next_req), .bus_next_addr(bus_next_addr),
  .vtor(vtor), .exc_req(exc_req), .exc_num(exc_num), .exc_ack(exc_ack),
  .step_mode(step_mode), .step_go(step_go), .step_done(step_done), .fault(core_fault), .fault_code(core_fault_code),
  .sleeping(sleeping),
  .dbg_we(dbg_we), .dbg_sel(dbg_sel), .dbg_wdata(dbg_wdata), .dbg_rsel(dbg_rsel), .dbg_rdata(dbg_rdata)
);

assign mon_req = bus_req;
assign mon_ready = bus_ready;
assign mon_we = bus_we;
assign mon_fetch = bus_fetch;
assign mon_size = bus_size;
assign mon_addr = bus_addr;
assign mon_wdata = bus_wdata;
assign mon_rdata = bus_rdata;
assign core_fault_code_o = core_fault_code;

//------------------------------------------------------------------------------
// Address classification
//------------------------------------------------------------------------------
localparam [3:0] C_BOOT = 4'd0, C_FLASH = 4'd1, C_RAM = 4'd2, C_SAVE = 4'd3, C_EMPTY = 4'd4, C_USB = 4'd5,
                 C_APB = 4'd6, C_TIMER = 4'd7, C_BRR = 4'd8, C_TICK = 4'd9, C_DEC = 4'd10, C_WIN = 4'd11,
                 C_SIO = 4'd12, C_PPB = 4'd13, C_NOP = 4'd14, C_BAD = 4'd15;

function [3:0] classify(input [31:0] a);
  reg [23:0] o;
  begin
    o = a[23:0];
    if(a[31:14] == 18'd0) classify = C_BOOT;
    else if(a[31:26] == 6'b000100) begin
      if(o[23:15] == 9'h1FF) classify = C_SAVE;
      else if(o < 24'hD00000 || o[23:14] == 10'h3C0) classify = C_FLASH;
      else classify = C_EMPTY;
    end
    else if(a[31:25] == 7'b0010000) classify = (a[23:19] == 5'd0 && a[18:0] < 19'h42000) ? C_RAM : C_BAD;
    else if(a[31:12] == 20'h50100) classify = C_USB;
    else if(a[31:14] == 18'h10015) classify = C_TIMER;           // 0x40054000-0x40057FFF (with aliases)
    else if(a[31:20] == 12'h400) classify = C_APB;
    else if(a[31:12] == 20'h50800) classify = C_BRR;
    else if(a[31:12] == 20'h50801) classify = C_DEC;
    else if(a[31:12] == 20'h50802) classify = C_TICK;
    else if(a[31:12] == 20'h50803) classify = C_WIN;
    else if(a[31:28] == 4'hD) classify = C_SIO;
    else if(a[31:28] == 4'hE) classify = C_PPB;
    else if(a[31:24] == 8'h14 || a[31:24] == 8'h15 || a[31:24] == 8'h18) classify = C_NOP;
    else classify = C_BAD;
  end
endfunction

// cache key: {region (0 boot, 1 flash, 2 RAM), 24-bit offset}; flash and RAM aliases fold together
function [25:0] cache_key(input [31:0] a);
  begin
    if(a[31:28] == 4'h1) cache_key = {2'd1, a[23:0]};
    else if(a[31:28] == 4'h2) cache_key = {2'd2, 5'd0, a[18:0]};
    else cache_key = {2'd0, 10'd0, a[13:0]};
  end
endfunction

// physical address of a cacheable key: {1 = SRAM chip / 0 = PSRAM, 24-bit address}
function [24:0] key_phys(input [25:0] k);
  reg [23:0] o;
  begin
    o = k[23:0];
    case(k[25:24])
      2'd0: key_phys = {1'b0, 24'hD20000 + {10'd0, o[13:0]}};
      2'd1: begin
        if(o[23:17] == 7'd0) key_phys = {1'b0, 24'hD00000 + o};
        else if(o[23:14] == 10'h3C0) key_phys = {1'b0, 24'hD24000 + {10'd0, o[13:0]}};
        else key_phys = {1'b0, o};
      end
      default: key_phys = {1'b1, 24'h008000 + o};
    endcase
  end
endfunction

wire [3:0] cls = classify(bus_addr);
wire [25:0] key_cur = cache_key(bus_addr);
wire use_ic = bus_fetch && (cls == C_BOOT || cls == C_FLASH);
wire use_dc = !use_ic && (cls == C_BOOT || cls == C_FLASH || cls == C_RAM);

// byte lanes
reg [3:0] be;
reg [31:0] wd_lanes;
always @* begin
  case(bus_size)
    2'd0: begin be = 4'b0001 << bus_addr[1:0]; wd_lanes = {4{bus_wdata[7:0]}}; end
    2'd1: begin be = bus_addr[1] ? 4'b1100 : 4'b0011; wd_lanes = {2{bus_wdata[15:0]}}; end
    default: begin be = 4'b1111; wd_lanes = bus_wdata; end
  endcase
end
function [31:0] lane_out(input [31:0] w, input [1:0] a, input [1:0] size);
  begin
    case(size)
      2'd0: lane_out = {24'd0, w[{a, 3'b000} +: 8]};
      2'd1: lane_out = {16'd0, a[1] ? w[31:16] : w[15:0]};
      default: lane_out = w;
    endcase
  end
endfunction

//------------------------------------------------------------------------------
// Caches
//------------------------------------------------------------------------------
localparam DTAG = 21 - DIDX;        // D$: 2^DIDX sets x 2 ways x 32 B, tag = key[25:DIDX+5]
localparam ITAG = 21 - IIDX;        // I$: 2^IIDX sets x 2 ways x 32 B, tag = key[25:IIDX+5]
localparam MIDX = (DIDX > IIDX) ? DIDX : IIDX;

reg ctl_rd;                         // controller drives the cache read address
reg [25:0] ctl_key;
wire [25:0] rd_key = ctl_rd ? ctl_key : bus_next_req ? cache_key(bus_next_addr) : key_cur;

wire [31:0] dq0, dq1, iq0, iq1;
wire [DTAG+1:0] dt0, dt1;
wire [ITAG+1:0] it0, it1;
reg d_dwe, d_dway, d_twe, d_tway, d_touch, d_touch_way;
reg [DIDX+2:0] d_dword;
reg [3:0] d_dbe;
reg [31:0] d_dwdata;
reg [DIDX-1:0] d_tset, d_touch_set;
reg [DTAG+1:0] d_twdata;
reg i_dwe, i_dway, i_twe, i_tway, i_touch, i_touch_way;
reg [IIDX+2:0] i_dword;
reg [31:0] i_dwdata;
reg [IIDX-1:0] i_tset, i_touch_set;
reg [ITAG+1:0] i_twdata;
reg lru_reset;
wire d_lru_way, i_lru_way;

xc_cache #(.SETS(1 << DIDX), .IDXW(DIDX), .TAGW(DTAG)) dcache (
  .clk(clk), .rd_word(rd_key[DIDX+4:2]), .q0(dq0), .q1(dq1), .t0(dt0), .t1(dt1),
  .dwe(d_dwe), .dway(d_dway), .dword(d_dword), .dbe(d_dbe), .dwdata(d_dwdata),
  .twe(d_twe), .tway(d_tway), .tset(d_tset), .twdata(d_twdata),
  .lru_set(key_cur[DIDX+4:5]), .lru_way(d_lru_way), .touch(d_touch), .touch_set(d_touch_set), .touch_way(d_touch_way),
  .inv_all_lru(lru_reset)
);
xc_cache #(.SETS(1 << IIDX), .IDXW(IIDX), .TAGW(ITAG)) icache (
  .clk(clk), .rd_word(rd_key[IIDX+4:2]), .q0(iq0), .q1(iq1), .t0(it0), .t1(it1),
  .dwe(i_dwe), .dway(i_dway), .dword(i_dword), .dbe(4'b1111), .dwdata(i_dwdata),
  .twe(i_twe), .tway(i_tway), .tset(i_tset), .twdata(i_twdata),
  .lru_set(key_cur[IIDX+4:5]), .lru_way(i_lru_way), .touch(i_touch), .touch_set(i_touch_set), .touch_way(i_touch_way),
  .inv_all_lru(lru_reset)
);

// the read outputs belong to rd_key_q; they are stale if a write to the same cache happened at that edge
reg [25:0] rd_key_q;
reg d_stale, i_stale;
always @(posedge clk) begin
  rd_key_q <= rd_key;
  d_stale <= d_dwe | d_twe;
  i_stale <= i_dwe | i_twe;
end
wire rd_match = (rd_key_q[25:2] == key_cur[25:2]);
wire d_hit0 = dt0[DTAG+1] && dt0[DTAG-1:0] == key_cur[25:DIDX+5];
wire d_hit1 = dt1[DTAG+1] && dt1[DTAG-1:0] == key_cur[25:DIDX+5];
wire i_hit0 = it0[ITAG+1] && it0[ITAG-1:0] == key_cur[25:IIDX+5];
wire i_hit1 = it1[ITAG+1] && it1[ITAG-1:0] == key_cur[25:IIDX+5];
wire d_look = rd_match & ~d_stale;
wire i_look = rd_match & ~i_stale;
wire d_hit = d_look & (d_hit0 | d_hit1);
wire i_hit = i_look & (i_hit0 | i_hit1);
wire [31:0] d_word = d_hit1 ? dq1 : dq0;
wire [31:0] i_word = i_hit1 ? iq1 : iq0;

//------------------------------------------------------------------------------
// Local peripherals
//------------------------------------------------------------------------------
// timer: 64-bit microseconds
reg [63:0] time_us;
reg [15:0] us_div;                  // phase accumulator: + CLK_DEN per clock, one microsecond per CLK_NUM
always @(posedge clk) begin
  if(rst) begin
    time_us <= 64'd0; us_div <= 16'd0;
  end else if(us_div + CLK_DEN >= CLK_NUM) begin
    us_div <= us_div + CLK_DEN - CLK_NUM; time_us <= time_us + 64'd1;
  end else us_div <= us_div + CLK_DEN;
end

// BRR encoder, tick
wire idle_req;                      // defined with the controller
wire brr_sel = idle_req & (cls == C_BRR);
wire tick_sel = idle_req & (cls == C_TICK) & bus_we & (bus_addr[11:0] < 12'h010);
wire [31:0] brr_rdata, tick_rdata;
wire brr_busy, tick_irq;
xc_brr brr (.clk(clk), .rst(rst), .sel(brr_sel), .we(bus_we), .addr(bus_addr[6:2]), .wdata(bus_wdata), .rdata(brr_rdata), .busy(brr_busy));
xc_tick #(.CLK_NUM(CLK_NUM), .CLK_DEN(CLK_DEN)) tick (.clk(clk), .rst(rst), .sel(tick_sel), .we(bus_we), .addr(bus_addr[3:2]), .wdata(bus_wdata), .rdata(tick_rdata), .irq(tick_irq));

reg [31:0] spinlocks;
reg nvic_en, nvic_pend;             // IRQ 26 (mixer tick) only
reg [1:0] clk_ref_src;              // CLK_REF_CTRL SRC
reg clk_sys_src;                    // CLK_SYS_CTRL SRC
// APB write with the RP2040 atomic aliases (addr[13:12]: 0 write, 1 XOR, 2 set, 3 clear)
function [1:0] apb_alias2(input [1:0] old, input [1:0] v, input [1:0] mode);
  case(mode)
    2'd0: apb_alias2 = v;
    2'd1: apb_alias2 = old ^ v;
    2'd2: apb_alias2 = old | v;
    default: apb_alias2 = old & ~v;
  endcase
endfunction

// interrupts: IRQ 26 only (dec_irq_tog is not used: the MSU-1 core has no decode interrupt)
assign exc_req = nvic_pend & nvic_en & running & ~halted;
assign exc_num = 6'd42;                        // 16 + 26

//------------------------------------------------------------------------------
// Controller
//------------------------------------------------------------------------------
localparam [4:0] S_INIT_TAGS = 5'd0, S_INIT_CLR = 5'd1, S_INIT_CLRW = 5'd2, S_INIT_VEC = 5'd3, S_INIT_VECW = 5'd4,
                 S_IDLE = 5'd5, S_MISS = 5'd6, S_WB_RD = 5'd7, S_WB_OP = 5'd8, S_FILL = 5'd9, S_FILL_WR = 5'd10,
                 S_RETRY = 5'd11, S_UNC = 5'd12, S_UNC_DONE = 5'd13,
                 S_CLEAN = 5'd16, S_CLEAN_CHK = 5'd17, S_CLEAN_NEXT = 5'd18, S_HALT = 5'd19, S_SEL = 5'd20, S_RELEASE = 5'd21, S_POST = 5'd22, S_CLEAN_WAIT = 5'd23, S_UNC_RD = 5'd24, S_UNC_RD2 = 5'd25;

reg [4:0] st, wb_ret;
reg [9:0] cnt;
reg [23:0] clr_addr;

// miss / write-back bookkeeping
reg m_icache;                       // miss is in the I$
// Deferred write-back: a dirty victim is copied into the bridge's write buffer, the fill goes first, and the
// victim is written to SRAM after it, while the core continues on cache hits. Any access that needs the
// bridge waits until that write is done (bridge operations stay in order: the SRAM always sees the victim
// before anything can read that line again).
reg bg_pend;                        // victim in the bridge write buffer, write not started yet
reg bg_busy;                        // victim write in progress
reg [23:0] bg_addr;
reg m_way;
reg [25:0] m_key;                   // line key of the miss
wire [24:0] m_phys = key_phys(m_key);
reg [DIDX-1:0] wb_set;
reg wb_way;
reg [DTAG-1:0] wb_tag;
reg [3:0] wb_i;
reg [2:0] rbi;                      // result word index (the bridge RAM reads it at every edge)
assign rb_addr = rbi;
wire [24:0] wb_phys = key_phys({wb_tag, wb_set, 5'd0});
wire [24:0] vec_phys = key_phys(cache_key(32'h10000100));

// uncached access
reg [31:0] unc_data;
reg [2:0] unc_mode;                 // 0 read, 4 write

// window TX_ADDR copy (for the clean before a post) and clean range
reg [31:0] win_txaddr;
reg [31:0] post_len;
reg [25:0] cl_key, cl_end;
reg cl_all;
reg [DIDX-1:0] cl_set;


wire [31:0] rbuf_word = rb_q;

// APB register without the atomic alias bits
wire [31:0] apb_reg = {bus_addr[31:14], 2'b00, bus_addr[11:0]};

assign idle_req = (st == S_IDLE) & bus_req & ~slow_ready & ~halted;

always @* begin
  fast_ready = 1'b0;
  fast_rdata = 32'd0;
  if(idle_req) begin
    if(use_ic) begin
      fast_ready = i_hit;
      fast_rdata = i_word;
    end else if(use_dc) begin
      if(bus_we) fast_ready = d_hit | (d_look & (cls != C_RAM));   // writes to flash/bootrom are ignored
      else fast_ready = d_hit;
      fast_rdata = lane_out(d_word, bus_addr[1:0], bus_size);
    end else begin
      case(cls)
        C_EMPTY: begin fast_ready = 1'b1; fast_rdata = lane_out(32'hFFFFFFFF, bus_addr[1:0], bus_size); end
        C_NOP: fast_ready = 1'b1;
        C_APB: begin
          // fixed values (see the header); writes only update clk_ref_src / clk_sys_src
          fast_ready = 1'b1;
          case(apb_reg)
            32'h4000C008: fast_rdata = 32'hFFFFFFFF;                        // RESETS RESET_DONE
            32'h40024004: fast_rdata = 32'h80001000;                        // XOSC STATUS
            32'h40028000, 32'h4002C000: fast_rdata = 32'h80000000;          // PLL CS: LOCK
            32'h40060018: fast_rdata = 32'h80000000;                        // ROSC STATUS
            32'h40008038: fast_rdata = {28'd0, clk_ref_src == 2'd3, clk_ref_src == 2'd2, clk_ref_src == 2'd1, clk_ref_src == 2'd0}; // CLK_REF_SELECTED
            32'h40008044: fast_rdata = {30'd0, clk_sys_src, ~clk_sys_src};  // CLK_SYS_SELECTED
            default: fast_rdata = 32'd0;
          endcase
        end
        C_TIMER: begin
          fast_ready = 1'b1;
          case(bus_addr[7:0])
            8'h08, 8'h24: fast_rdata = time_us[63:32];   // TIMEHR (no latch), TIMERAWH
            8'h0C, 8'h28: fast_rdata = time_us[31:0];    // TIMELR, TIMERAWL
            default: fast_rdata = 32'd0;         // ARMED, INTR, ...: no alarms in use
          endcase
        end
        C_BRR: begin fast_ready = 1'b1; fast_rdata = brr_rdata; end
        C_TICK: begin fast_ready = 1'b1; fast_rdata = (bus_addr[11:0] < 12'h010) ? tick_rdata : 32'd0; end
        C_WIN: fast_ready = bus_we && bus_addr[11:0] == 12'h000;    // TX_ADDR: kept here, sent to the window with TX_LEN
        C_SIO: begin
          fast_ready = 1'b1;
          case(bus_addr[11:0])
            12'h000: fast_rdata = 32'd0;                          // CPUID: core 0
            12'h050: fast_rdata = 32'h2;                          // FIFO_ST: RDY
            12'h05C: fast_rdata = spinlocks;
            default: begin
              if(bus_addr[11:7] == 5'b00010) fast_rdata = spinlocks[bus_addr[6:2]] ? 32'd0 : (32'd1 << bus_addr[6:2]);
              if(bus_addr[11:7] == 5'b00001) fast_ready = 1'b0;   // interpolators: halt below
              if(bus_addr[11:5] == 7'b0000011) fast_ready = 1'b0; // divider (0x060-0x07C): halt below
            end
          endcase
        end
        C_PPB: begin
          fast_ready = 1'b1;
          case(bus_addr)
            32'hE000ED00: fast_rdata = 32'h410CC601;
            32'hE000ED08: fast_rdata = vtor;
            32'hE000E100, 32'hE000E180: fast_rdata = {5'd0, nvic_en, 26'd0};
            32'hE000E200, 32'hE000E280: fast_rdata = {5'd0, nvic_pend, 26'd0};
            default: fast_rdata = 32'd0;
          endcase
        end
        default: ;
      endcase
    end
  end
end

always @(posedge clk) begin
  op_start <= 1'b0;
  wb_we <= 1'b0;
  slow_ready <= 1'b0;
  d_dwe <= 1'b0; d_twe <= 1'b0; d_touch <= 1'b0;
  i_dwe <= 1'b0; i_twe <= 1'b0; i_touch <= 1'b0;
  lru_reset <= 1'b0;
  dbg_char_valid <= 1'b0;

  if(bg_busy && op_done) bg_busy <= 1'b0;
  if(rst) begin
    bg_pend <= 1'b0; bg_busy <= 1'b0;
    st <= S_INIT_TAGS;
    cnt <= 9'd0;
    core_rst <= 1'b1;
    running <= 1'b0;
    halted <= 1'b0;
    halt_code <= 32'd0;
    halt_addr <= 32'd0;
    ctl_rd <= 1'b0;
    vtor <= 32'h10000100;
    spinlocks <= 32'd0;
    nvic_en <= 1'b0;
    nvic_pend <= 1'b0;
    clk_ref_src <= 2'd0;
    clk_sys_src <= 1'b0;
    win_txaddr <= 32'd0;
    lru_reset <= 1'b1;
  end else begin
    // interrupt sources and acknowledge
    if(tick_irq) nvic_pend <= 1'b1;
    if(exc_ack) nvic_pend <= 1'b0;             // as the mk3 SoC: the acknowledge wins over a tick in the same cycle
    if(core_fault && !halted) begin
      halted <= 1'b1; halt_code <= {24'h0FA017, core_fault_code}; halt_addr <= bus_addr;
    end

    case(st)
      //------------------------------------------------------------ start-up
      S_INIT_TAGS: begin
        // invalidate both ways of every set of both caches (2 x the larger number of sets, in cycles)
        d_twe <= 1'b1; d_tway <= cnt[0]; d_tset <= cnt[DIDX:1]; d_twdata <= 0;
        wb_we <= 1'b1; wb_addr <= cnt[2:0]; wb_data <= 32'd0;     // zero data words for the SRAM clear
        rbi <= 3'd0;
        i_twe <= 1'b1; i_tway <= cnt[0]; i_tset <= cnt[IIDX:1]; i_twdata <= 0;
        cnt <= cnt + 9'd1;
        if(cnt == (10'd2 << MIDX) - 10'd1) begin st <= S_INIT_CLR; clr_addr <= 24'h008000; end
      end
      S_INIT_CLR: begin
        op_kind <= OP_SRAM_WR; op_addr <= clr_addr; op_len <= 6'd32; op_start <= 1'b1;
        st <= S_INIT_CLRW;
      end
      S_INIT_CLRW: if(op_done) begin
        clr_addr <= clr_addr + 24'd32;
        st <= (clr_addr + 24'd32 >= 24'h04E000) ? S_INIT_VEC : S_INIT_CLR;
      end
      S_INIT_VEC: begin
        op_kind <= OP_PSRAM_RD; op_addr <= vec_phys[23:0]; op_len <= 6'd8; op_start <= 1'b1;
        cnt <= 9'd0;
        st <= S_INIT_VECW;
      end
      S_INIT_VECW: begin
        // op_done, then read result word 0 (SP) and word 1 (PC)
        if(op_done) begin cnt <= 9'd1; rbi <= 3'd0; end
        else if(cnt != 9'd0) begin
          cnt <= cnt + 9'd1;
          if(cnt == 9'd2) rbi <= 3'd1;
          if(cnt == 9'd3) reset_sp <= rb_q;
          if(cnt == 9'd5) begin reset_pc <= {rb_q[31:1], 1'b0}; st <= S_RELEASE; end
        end
      end
      S_RELEASE: begin             // the core takes reset_sp/reset_pc while in reset
        core_rst <= 1'b0;
        running <= 1'b1;
        st <= S_IDLE;
      end

      //------------------------------------------------------------ normal operation
      S_IDLE: begin
        ctl_rd <= 1'b0;
        if(idle_req) begin
          if(fast_ready) begin
            // side effects of the accesses answered combinationally
            if(use_ic) begin
              i_touch <= 1'b1; i_touch_set <= key_cur[IIDX+4:5]; i_touch_way <= i_hit1;
            end else if(use_dc) begin
              if(bus_we && cls == C_RAM) begin
                d_dwe <= 1'b1; d_dway <= d_hit1; d_dword <= key_cur[DIDX+4:2]; d_dbe <= be; d_dwdata <= wd_lanes;
                d_twe <= 1'b1; d_tway <= d_hit1; d_tset <= key_cur[DIDX+4:5]; d_twdata <= {1'b1, 1'b1, key_cur[25:DIDX+5]};
              end
              if(d_hit) begin d_touch <= 1'b1; d_touch_set <= key_cur[DIDX+4:5]; d_touch_way <= d_hit1; end
            end else begin
              case(cls)
                C_TIMER: begin
                  if(bus_we && bus_addr[7:0] >= 8'h10 && bus_addr[7:0] <= 8'h1C) begin
                    halted <= 1'b1; halt_code <= 32'hBAD00003; halt_addr <= bus_addr;   // timer alarms: unsupported
                  end
                end
                C_TICK: begin
                  if(bus_we && bus_addr[11:0] == 12'h010) begin dbg_char_valid <= 1'b1; dbg_char <= bus_wdata[7:0]; end
                  if(bus_we && bus_addr[11:0] == 12'h014) begin halted <= 1'b1; halt_code <= bus_wdata; halt_addr <= 32'h50802014; end
                end
                C_WIN: if(bus_we) win_txaddr <= bus_wdata;           // TX_ADDR (the only fast window access)
                C_APB: if(bus_we) begin
                  if(apb_reg == 32'h40008030) clk_ref_src <= apb_alias2(clk_ref_src, bus_wdata[1:0], bus_addr[13:12]);
                  if(apb_reg == 32'h4000803C) clk_sys_src <= apb_alias2({1'b0, clk_sys_src}, {1'b0, bus_wdata[0]}, bus_addr[13:12]) != 2'd0;
                end
                C_SIO: begin
                  if(bus_addr[11:7] == 5'b00010) begin                   // spinlocks 0x100-0x17C
                    if(bus_we) spinlocks[bus_addr[6:2]] <= 1'b0;
                    else spinlocks[bus_addr[6:2]] <= 1'b1;
                  end
                end
                C_PPB: if(bus_we) case(bus_addr)
                  32'hE000ED08: vtor <= {bus_wdata[31:8], 8'd0};
                  32'hE000E100: if(bus_wdata[26]) nvic_en <= 1'b1;
                  32'hE000E180: if(bus_wdata[26]) nvic_en <= 1'b0;
                  32'hE000E200: if(bus_wdata[26]) nvic_pend <= 1'b1;
                  32'hE000E280: if(bus_wdata[26]) nvic_pend <= 1'b0;
                  default: ;
                endcase
                default: ;
              endcase
            end
          end else if(bg_busy) begin
            // the deferred write-back still has the bridge
          end else if(use_ic) begin
            if(i_look) begin
              m_icache <= 1'b1; m_key <= {key_cur[25:5], 5'd0};
              m_way <= !it0[ITAG+1] ? 1'b0 : !it1[ITAG+1] ? 1'b1 : i_lru_way;
              st <= S_FILL;
            end
          end else if(use_dc) begin
            if(d_look) begin
              // miss: pick the victim, write it back if dirty, then fill
              m_icache <= 1'b0; m_key <= {key_cur[25:5], 5'd0};
              m_way <= !dt0[DTAG+1] ? 1'b0 : !dt1[DTAG+1] ? 1'b1 : d_lru_way;
              st <= S_MISS;
            end
          end else begin
            case(cls)
              C_SAVE, C_USB: begin
                // single SRAM access of 1, 2 or 4 bytes
                op_kind <= bus_we ? OP_SRAM_WR : OP_SRAM_RD;
                op_addr <= (cls == C_SAVE) ? {9'd0, bus_addr[14:0]} : (24'h04A000 + {12'd0, bus_addr[11:0]});
                op_len <= (bus_size == 2'd0) ? 6'd1 : (bus_size == 2'd1) ? 6'd2 : 6'd4;
                wb_we <= 1'b1; wb_addr <= 3'd0; wb_data <= bus_wdata;
                op_start <= 1'b1; rbi <= 3'd0;
                unc_mode <= bus_we ? 3'd4 : 3'd0;
                st <= S_UNC;
              end
              C_DEC: begin
                op_kind <= bus_we ? OP_DEC_WR : OP_DEC_RD; op_addr <= {12'd0, bus_addr[11:0]}; op_len <= 6'd4;
                wb_we <= 1'b1; wb_addr <= 3'd0; wb_data <= bus_wdata; op_start <= 1'b1; rbi <= 3'd0; unc_mode <= bus_we ? 3'd4 : 3'd0;
                st <= S_UNC;
              end
              C_WIN: begin
                if(bus_we && bus_addr[11:0] == 12'h004 && bus_wdata != 32'd0) begin
                  // clean the D$ for the range the DMA will read, then post
                  post_len <= bus_wdata;
                  cl_key <= cache_key(win_txaddr) & ~26'h1F;
                  cl_end <= cache_key(win_txaddr + bus_wdata - 32'd1);
                  cl_all <= (bus_wdata > 32'd4096) || (win_txaddr[31:28] != 4'h2);
                  cl_set <= {DIDX{1'b0}};
                  st <= S_CLEAN;
                end else begin
                  op_kind <= bus_we ? OP_WIN_WR : OP_WIN_RD; op_addr <= {12'd0, bus_addr[11:0]}; op_len <= 6'd4;
                  wb_we <= 1'b1; wb_addr <= 3'd0; wb_data <= bus_wdata; op_start <= 1'b1; rbi <= 3'd0; unc_mode <= bus_we ? 3'd4 : 3'd0;
                  st <= S_UNC;
                end
              end
              C_SIO: begin            // divider (not present) or interpolators
                halted <= 1'b1; halt_code <= 32'hBAD00004; halt_addr <= bus_addr;
              end
              default: begin
                halted <= 1'b1; halt_code <= 32'hBAD00001; halt_addr <= bus_addr;
              end
            endcase
          end
        end
      end

      //------------------------------------------------------------ D$ miss: write back the victim
      S_MISS: begin
        if((m_way ? dt1[DTAG+1] & dt1[DTAG] : dt0[DTAG+1] & dt0[DTAG])) begin
          wb_set <= m_key[DIDX+4:5]; wb_way <= m_way; wb_tag <= m_way ? dt1[DTAG-1:0] : dt0[DTAG-1:0];
          wb_ret <= S_FILL;
          wb_i <= 4'd0;
          ctl_rd <= 1'b1; ctl_key <= {m_way ? dt1[DTAG-1:0] : dt0[DTAG-1:0], m_key[DIDX+4:5], 5'd0};
          st <= S_WB_RD;
        end else st <= S_FILL;
      end
      // read the 8 words of line {wb_tag, wb_set} (one cycle latency) into 'line', then write it to SRAM
      S_WB_RD: begin
        ctl_rd <= 1'b1;
        ctl_key <= {wb_tag, wb_set, 3'd0, 2'd0} + {21'd0, wb_i[2:0] + 3'd1, 2'b00};
        if(wb_i != 4'd0) begin wb_we <= 1'b1; wb_addr <= wb_i[2:0] - 3'd1; wb_data <= wb_way ? dq1 : dq0; end
        wb_i <= wb_i + 4'd1;
        if(wb_i == 4'd8) begin
          ctl_rd <= 1'b0;
          // clear the dirty bit now; the line stays valid
          d_twe <= 1'b1; d_tway <= wb_way; d_tset <= wb_set; d_twdata <= {1'b1, 1'b0, wb_tag};
          if(wb_ret == S_FILL) begin
            // miss: fill first, write the victim afterwards (the last data word is written on this edge)
            bg_pend <= 1'b1; bg_addr <= wb_phys[23:0];
            st <= S_FILL;
          end else begin
            op_kind <= OP_SRAM_WR; op_addr <= wb_phys[23:0]; op_len <= 6'd32;
            op_start <= 1'b1;           // the last data word is written on the same edge
            st <= S_WB_OP;
          end
        end
      end
      S_WB_OP: if(op_done) st <= wb_ret;

      //------------------------------------------------------------ fill
      S_FILL: begin
        op_kind <= m_phys[24] ? OP_SRAM_RD : OP_PSRAM_RD;
        op_addr <= m_phys[23:0];
        op_len <= 6'd32;
        op_start <= 1'b1;
        cnt <= 9'd0;
        st <= S_FILL_WR;
      end
      S_FILL_WR: begin
        // after op_done: rbi = 0..7 on consecutive edges, word k arrives two edges after rbi = k
        if(cnt != 9'd0 || op_done) begin
          cnt <= cnt + 9'd1;
          rbi <= cnt[2:0];
        end
        if(cnt >= 9'd2) begin
          if(m_icache) begin
            i_dwe <= 1'b1; i_dway <= m_way; i_dword <= {m_key[IIDX+4:5], cnt[2:0] - 3'd2}; i_dwdata <= rb_q;
          end else begin
            d_dwe <= 1'b1; d_dway <= m_way; d_dword <= {m_key[DIDX+4:5], cnt[2:0] - 3'd2}; d_dbe <= 4'b1111; d_dwdata <= rb_q;
          end
          if(cnt == 9'd9) begin
            if(m_icache) begin i_twe <= 1'b1; i_tway <= m_way; i_tset <= m_key[IIDX+4:5]; i_twdata <= {1'b1, 1'b0, m_key[25:IIDX+5]}; end
            else begin d_twe <= 1'b1; d_tway <= m_way; d_tset <= m_key[DIDX+4:5]; d_twdata <= {1'b1, 1'b0, m_key[25:DIDX+5]}; end
            if(bg_pend) begin
              // the fill is complete: now write the victim from the bridge's write buffer
              op_kind <= OP_SRAM_WR; op_addr <= bg_addr; op_len <= 6'd32; op_start <= 1'b1;
              bg_pend <= 1'b0; bg_busy <= 1'b1;
            end
            st <= S_RETRY;
          end
        end
      end
      S_RETRY: st <= S_IDLE;       // the cache read port re-reads the requested address

      //------------------------------------------------------------ uncached operations
      S_UNC: if(op_done) st <= S_UNC_RD;     // rbi = 0: result word 0 is read at the next edge
      S_UNC_RD: st <= S_UNC_RD2;
      S_UNC_RD2: begin
        unc_data <= (bus_size == 2'd0) ? {24'd0, rbuf_word[7:0]} : (bus_size == 2'd1) ? {16'd0, rbuf_word[15:0]} : rbuf_word;
        st <= S_UNC_DONE;
      end
      S_UNC_DONE: begin
        slow_ready <= 1'b1; slow_rdata <= unc_data;
        st <= S_SEL;
      end
      S_SEL: st <= S_IDLE;          // the core has taken the data; one cycle before the next request

      //------------------------------------------------------------ clean before a window post
      S_CLEAN: begin
        // read the tags of the next line (or set) to check
        ctl_rd <= 1'b1;
        ctl_key <= cl_all ? {{DTAG{1'b0}}, cl_set, 5'd0} : cl_key;
        st <= S_CLEAN_WAIT;
      end
      S_CLEAN_WAIT: st <= S_CLEAN_CHK;   // the cache reads ctl_key at the end of this cycle
      S_CLEAN_CHK: begin
        // tags for ctl_key are valid now
        ctl_rd <= 1'b1;
        if(cl_all ? (dt0[DTAG+1] & dt0[DTAG]) : (dt0[DTAG+1] & dt0[DTAG] & dt0[DTAG-1:0] == cl_key[25:DIDX+5])) begin
          wb_set <= cl_all ? cl_set : cl_key[DIDX+4:5]; wb_way <= 1'b0; wb_tag <= dt0[DTAG-1:0]; wb_i <= 4'd0; wb_ret <= S_CLEAN;
          ctl_key <= {dt0[DTAG-1:0], cl_all ? cl_set : cl_key[DIDX+4:5], 5'd0};
          st <= S_WB_RD;
        end else if(cl_all ? (dt1[DTAG+1] & dt1[DTAG]) : (dt1[DTAG+1] & dt1[DTAG] & dt1[DTAG-1:0] == cl_key[25:DIDX+5])) begin
          wb_set <= cl_all ? cl_set : cl_key[DIDX+4:5]; wb_way <= 1'b1; wb_tag <= dt1[DTAG-1:0]; wb_i <= 4'd0; wb_ret <= S_CLEAN;
          ctl_key <= {dt1[DTAG-1:0], cl_all ? cl_set : cl_key[DIDX+4:5], 5'd0};
          st <= S_WB_RD;
        end else st <= S_CLEAN_NEXT;
      end
      S_CLEAN_NEXT: begin
        ctl_rd <= 1'b0;
        if(cl_all ? (cl_set == {DIDX{1'b1}}) : (cl_key[25:5] >= cl_end[25:5])) begin
          // clean done: post the descriptor (TX_ADDR, then TX_LEN)
          op_kind <= OP_WIN_WR; op_addr <= 24'h000000; op_len <= 6'd4; op_start <= 1'b1;
          wb_we <= 1'b1; wb_addr <= 3'd0; wb_data <= win_txaddr;
          st <= S_POST;
        end else begin
          if(cl_all) cl_set <= cl_set + 1'b1;
          else cl_key <= cl_key + 26'd32;
          st <= S_CLEAN;
        end
      end

      S_POST: if(op_done) begin
        op_kind <= OP_WIN_WR; op_addr <= 24'h000004; op_len <= 6'd4; op_start <= 1'b1;
        wb_we <= 1'b1; wb_addr <= 3'd0; wb_data <= post_len;
        unc_mode <= 3'd4;
        st <= S_UNC;
      end

      S_HALT: ;
      default: st <= S_IDLE;
    endcase

    if(halted) begin
      core_rst <= 1'b1;
      running <= 1'b0;
    end
  end
end

endmodule
