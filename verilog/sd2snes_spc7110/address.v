`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// address.v -- SPC7110 mapping
//
// SPC7110 cart memory map (canonical, per wiki.superfamicom.org):
//   $00-$3F:8000-FFFF   PROM mirror (first 1 MB of ROM)  [SlowROM region]
//   $80-$BF:8000-FFFF   PROM mirror (same)               [FastROM region]
//   $C0-$FF:0000-FFFF   PROM mirror (first 1 MB, full banks)
//   $40-$4F:0000-FFFF   banked DROM window (via $4831, 1 MB each bank)
//   $50-$5F:0000-FFFF   decompression buffer read window (from core)
//   $60-$6F:0000-FFFF   (unmapped)
//   $D0-$DF / $E0-$EF / $F0-$FF:0000-FFFF  DROM via banks $4831-$4833
//   $00-$3F,$80-$BF:6000-7FFF  SRAM window (enabled by $4830.7)
//   $4800-$4842        SPC7110 register set
//
// For SD2SNES, the SPC7110 core in SPC7110Map handles its own register decode
// and ROM routing. The address.v here provides fallback ROM mapping (used
// when the core is not driving the bus) and -- from Step 22a -- the PSRAM
// mapping for the saveram window, matching the SDD1 convention.
//
// ROM storage in PSRAM is linear at $000000 onward (MCU DMA'd the .sfc file
// in that way). PROM = first 1 MB; DROM = banks starting at 1 MB offset.
// Backup SRAM lives at PSRAM $E00000+, same base the MCU uses for .srm I/O
// (see sd2snes_base/address.v: SAVERAM_ADDR = {$E, 0, SAVERAM_BASE, 11'h0}
// with SAVERAM_BASE = srambase = 0 for SPC7110 in smc.c).
//////////////////////////////////////////////////////////////////////////////////

module address(
  input [15:0] featurebits,
  input [23:0] SNES_ADDR,
  input [7:0] SNES_PA,
  input SNES_ROMSEL,
  output [23:0] ROM_ADDR,
  output ROM_HIT,
  output IS_SAVERAM,
  output IS_ROM,
  output IS_WRITABLE,
  input [23:0] SAVERAM_MASK,
  input [23:0] ROM_MASK,
  output msu_enable,
  output r213f_enable,
  output r2100_hit,
  output snescmd_enable,
  output nmicmd_enable,
  output return_vector_enable,
  output branch1_enable,
  output branch2_enable,
  output branch3_enable
);

parameter [2:0]
  FEAT_MSU1 = 3,
  FEAT_213F = 4
;

// SPC7110 register range: $xx:4800-487F (low half of I/O page).
// Not counted as a ROM/RAM hit here -- the core handles it.
wire IS_SPC7110_REG = (SNES_ADDR[22] == 1'b0)
                    & (SNES_ADDR[15:8] == 8'h48)
                    & (SNES_ADDR[7]    == 1'b0);

// PROM (first 1 MB): HiROM-style upper-half-of-bank for banks $00-$3F, $80-$BF
wire IS_PROM_UPPER = (SNES_ADDR[22] == 1'b0) & (SNES_ADDR[15] == 1'b1);

// Full-bank PROM/DROM at $C0-$FF:0000-FFFF
wire IS_FULLBANK = (SNES_ADDR[23:22] == 2'b11); // C0-FF

// Decompression buffer window at $50-$5F is handled inside the core.
wire IS_DECBUF = (SNES_ADDR[23:20] == 4'h5);

// SRAM window at $00-$3F,$80-$BF:6000-7FFF (8 KB bank-mirrored).
// The SPC7110 core enables it via $4830.7; address.v flags IS_SAVERAM so
// main.v routes the access to PSRAM $E00000+ via the same ROM_HIT /
// IS_WRITABLE path every other SD2SNES mapper uses.
wire IS_SRAM_WINDOW = (SNES_ADDR[22] == 1'b0) & (SNES_ADDR[15:13] == 3'b011);

// IS_ROM drives the external level-converter direction on the cart edge.
// Assert on any address that SPC7110 fetches ROM bytes from (PROM, DROM,
// decbuf) or on ordinary ROMSEL assertion.
assign IS_ROM = ~SNES_ROMSEL | IS_PROM_UPPER | IS_FULLBANK | IS_DECBUF;

// IS_SAVERAM: window the SPC7110 maps to SRAM. Stored linearly at PSRAM
// $E00000+ (same base as every other SD2SNES HiROM mapper; MCU .srm DMA
// uses the same base with srambase = 0 from smc.c).
assign IS_SAVERAM = IS_SRAM_WINDOW;

assign IS_WRITABLE = IS_SAVERAM;

// ---------------------------------------------------------------------------
// Step 22a: saveram linear packing.
//
// SPC7110 (HiROM-style) SRAM appears at $00-$3F and $80-$BF bank halves,
// mirrored; within each bank, only the 8 KB window $6000-$7FFF. Pack into
// a 19-bit linear offset using bank bits [21:16] and the 13-bit intra-bank
// offset [12:0]. Ignoring [23] folds the $00-$3F and $80-$BF mirrors onto
// the same PSRAM bytes (correct for battery RAM, where both windows are
// supposed to see identical contents).
//
// Examples (8 KB SAVERAM_MASK = $001FFF):
//   $00:7FF0 -> packed $01FF0 -> masked $1FF0 -> PSRAM $E01FF0
//   $B0:6000 -> packed $60000 -> masked $0000 -> PSRAM $E00000
// Examples (32 KB SAVERAM_MASK = $007FFF):
//   $00:6000 -> packed $00000 -> masked $0000 -> PSRAM $E00000
//   $03:7FFF -> packed $07FFF -> masked $7FFF -> PSRAM $E07FFF
// ---------------------------------------------------------------------------
wire [18:0] SAVERAM_PACKED = {SNES_ADDR[21:16], SNES_ADDR[12:0]};

wire [23:0] SAVERAM_PSRAM_ADDR = 24'hE00000
                                 + ({5'h00, SAVERAM_PACKED} & SAVERAM_MASK);

// Fallback ROM address for PSRAM. Saveram window now routes to $E00000+;
// other accesses use the same linear PROM layout as before.
wire [23:0] ROM_FALLBACK_ADDR =
     IS_SRAM_WINDOW ? SAVERAM_PSRAM_ADDR                                        // $E00000+ packed
   : IS_FULLBANK    ? ({2'b00, SNES_ADDR[21:0]} & ROM_MASK)                      // C0-FF linear
   : IS_PROM_UPPER  ? ({3'b000, SNES_ADDR[21:16], SNES_ADDR[14:0]} & ROM_MASK)   // HiROM-style
   :                  ({1'b0, !SNES_ADDR[23], SNES_ADDR[21:0]} & ROM_MASK);      // default LoROM-ish

assign ROM_ADDR = ROM_FALLBACK_ADDR;

// Signals PSRAM may be accessed for this address
assign ROM_HIT = IS_ROM | IS_WRITABLE;

// MSU / register overrides
assign msu_enable = featurebits[FEAT_MSU1] & (!SNES_ADDR[22] && ((SNES_ADDR[15:0] & 16'hfff8) == 16'h2000));
assign r213f_enable = featurebits[FEAT_213F] & (SNES_PA == 8'h3f);
assign r2100_hit = (SNES_PA == 8'h00);

assign snescmd_enable = ({SNES_ADDR[22], SNES_ADDR[15:9]} == 8'b0_0010101);
assign nmicmd_enable = (SNES_ADDR == 24'h002BF2);
assign return_vector_enable = (SNES_ADDR == 24'h002A6C);
assign branch1_enable = (SNES_ADDR == 24'h002A1F);
assign branch2_enable = (SNES_ADDR == 24'h002A59);
assign branch3_enable = (SNES_ADDR == 24'h002A5E);

endmodule
