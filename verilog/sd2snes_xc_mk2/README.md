# Xeno Crisis on sd2snes mk2 (fit test core)

`sd2snes_xc_mk2` is a complete ISE project for the sd2snes mk2 (Spartan-3 XC3S400), laid out like the other mk2 cores:
`Makefile`, `sd2snes_xc_mk2.xise` (Verilog macros `MK2 | XC_MSU`), `main.ucf`, `config.vh`, `dcm.v` and the Xilinx
memory blocks in `ip/mk2`. `make mk2` builds `fpga_xc_mk2.bit`; `make mk2s` runs SmartXplorer.

**State: it fits and meets timing (soft CPU at 20 MHz), the mk2 firmware loads it, the music plays from an MSU-1
pack and the sound effects are mixed in software. Tested in MesenCE (mk2 mode) and in RTL-in-the-loop simulation
(below), not yet on hardware.**

- The mk2 MCU firmware (`config-mk2`) detects the cartridge, builds the image like the mk3 firmware (and applies the
  "MK2P" table), and loads `/sd2snes/fpga_xc_mk2.bit`. The SD card needs the same files as on mk3:
  `xenocrisis_rp2040.bin` and `xc_soc.bin` (from the same firmware build), plus this core as `fpga_xc_mk2.bit`,
  and an MSU-1 pack next to the ROM for music.
- The mixer's tick, interrupts and the BRR encoder were removed to make room (see `experiments/`). Instead, the mk2
  table starts the mixer (`src/xc_soc/xc_mix.c`) in a mode without interrupts: the firmware's wait loops call
  `xc_mix_poll()`, which runs the 1 kHz ticks that are due and mixes a block or two while the BRR rings have room.
  It sends the music requests to the MSU-1 exactly as on mk3, and mixes and BRR-encodes the sound effects in
  software (hand-written assembly; see "mk2 mixing" in `src/xc_soc/README.md`).

MSU-1 only (the music comes from an MSU-1 pack). The mk3 cores (`../sd2snes_xc`, `../sd2snes_xc_msu`) do not use
these files and are unchanged.

## What is in it

| File | Contents |
|---|---|
| `main.v` | the Xeno Crisis `main.v` with its mk2 branch; adds `soc_dcm` for the soft CPU clock |
| `dcm.v` | `my_dcm` (CLK2 = 24 MHz x 25 / 7 = 85.7 MHz, as in the gsu core) and `soc_dcm` (soft CPU: 24 MHz x 5 / 6 = 20 MHz) |
| `main.ucf` | the mk2 pinout (as sd2snes_gsu) plus TIG between CLK2 and the soft CPU clock (the paths through `xc_bridge`'s synchronizers) |
| `xc_m0.v` | soft CPU core: register file in LUT RAM, no ROR/REV16/REVSH, MRS/MSR IPSR/PRIMASK only, no interrupts, no early fetch |
| `xc_soc.v` | SoC: one 16 KB 2-way write-through cache for code and data, no divider, fixed APB reads, no BRR/tick/NVIC, 40-bit timer, no RAM clear at start, halt address not captured, no adders for the fixed PSRAM offsets |
| `xc_cache.v` | cache storage; LRU bits in distributed RAM (no reset: they are only a replacement hint) |
| `xc_bridge.v` | clock-domain bridge; its two 8 x 32 buffers in distributed RAM |
| `xc_window.v`, `xc_stream.v` | `$3000` window, descriptor queue 2 entries deep |
| `xc_top.v` | the blocks together, MSU-1 only, no performance counters |
| `msu.v`, `xc_dac.v`, `xc_msubox.v` | MSU-1 audio (no data port), DAC (Xilinx `dac_buf` ports; sample-and-hold instead of linear interpolation unless `XC_DAC_LINEAR` is defined), soft CPU → MSU-1 registers |
| `address.v`, `cheat.v`, `mcu_cmd.v`, `sd_dma.v`, `spi.v` | as in `../sd2snes_xc` |

Block RAM: cache data 8 (one per byte lane and way), cache tags 2, window rings 2, `dac_buf` 1, `snescmd_buf` 1: 14 of 16.

## ISE results so far

| Build | Slices | 4-input LUTs | Flip-flops |
|---|---|---|---|
| first build (XST speed) | 3,752 of 3,584 (105%) | 6,624 (92%) | 2,916 |
| XST area | 3,766 (105%) | 6,660 (92%) | 2,917 |
| + 40-bit timer, no RAM clear, no halt address, no offset adders, DAC without interpolation | 3,582 of 3,584 (99.9%) | | |

Timing of that build (40 MHz soft CPU): the CPU's worst path is 45 ns (fetch-buffer compare, decode, register read,
shifter/ALU, next PC; more than half of it routing), about 22 MHz; CLK2 misses 85.7 MHz by 9.6 ns on ordinary sd2snes
paths (brightness patch, SD clock, bridge synchronizer), because the full chip forces long routes. The soft CPU now runs
at 20 MHz.

## Soft CPU at 20 MHz (RTL-in-the-loop)

`xc_top` as in this folder (16 KB write-through cache, RAM not cleared), Verilated, with MesenCE running the SNES
side; 3,600 frames of the test script, every core and DMA access checked against a reference memory:

| | 20 MHz, no mixer | 40 MHz, no mixer | 20 MHz, music only (silent BRR) | 20 MHz, full sound | mk3 (40 MHz, mixer on interrupts) |
|---|---|---|---|---|---|
| game ticks later than one frame | 30 of 3,566 | 25 of 3,571 | 7 of 3,658 | 7 of 3,612 | 2 of 3,651 |
| frame message → stream post, p50 / p99 / max | 4.6 / 16.5 / 55.7 ms | 3.3 / 16.5 / 35.3 ms | 7.5 / 12.3 / 55.8 ms | 7.9 / 13.3 / 55.9 ms | 6.1 ms (p50) |
| BRR blocks mixed | – | – | | 89,040 (1,487/s) | 89,360 (MesenCE) |
| mixer's share of the CPU | – | – | | 24.1% | |
| left BRR ring empty (sampled every ms) | | | | 3 of 59,869 | |
| mismatches against the reference memory | 0 | 0 | 0 | 0 | 0 |

Without the mixer, the BRR rings stay empty and the SNES gets only half the stream; with it, the stream is as on
mk3 again. With full sound, the mixer keeps up: the left BRR ring was empty in 3 of 59,869 one-millisecond samples
(less than half full in 8,103; then the mixer mixes more blocks per call and the encoder uses its fast mode, which
it did for 10,396 blocks). The game takes a slightly different course than in the other runs (the CPU timing is
different), so its stream totals are not comparable. The two runs without the mixer halted after the last frame, while the simulation was
shutting down; the run with the mixer did not. In MesenCE, the MSU-1 register writes of the mk2 mode (17 in the
test script: 4 track requests including an intro → loop change, and pauses) are the same as on the mk3 MSU-1 core,
to within 1 ms.

ISE (last build, 20 MHz): 3,582 of 3,584 slices; all constraints met, CLK2 slack +0.032 ns, soft CPU +0.075 ns
(worst-case conditions). There is no room left: any addition needs slices freed elsewhere.

## Things to look at in the ISE reports

- **Utilisation:** slices / LUTs (map report). Yosys estimates it at 7,859 LUTs (6,187 without LUT1 buffers) plus 144
  RAM16X1D, about 1.2–1.3x the gsu3 (FX3) core measured the same way (see "Size").
- **Timing:** CLK2 (85.7 MHz) and the soft CPU clock (20 MHz). The CPU's worst path is 45 ns on the Spartan-3 -4
  (about 22 MHz); 40 MHz, as on mk3, would be `soc_dcm` x 5 / 3 and `.SOC_CLK_NUM(40)` in `main.v`.
- The XST optimisation settings are the gsu core's (speed). If mapping fails for lack of space, try Optimization Goal
  = Area in the project properties.

## First round of cuts: what is removed, and why that is safe

The CPU and SoC changes below were checked in simulation. The later size steps (write-through cache, no mixer, and so
on) are described in `experiments/README.md`; they were only synthesized.

The evidence comes from two sources:

- **What runs:** every instruction and register access of the soft CPU during 60 s of gameplay (3,600 frames of the
  MesenCE test script, MSU-1 build).
- **What can ever run:** the game's firmware disassembled, to check which instructions appear in its code at all.

Anything removed halts the CPU with a fault code if it is ever reached (reported on the MCU's UART), so a case the
test did not cover shows up instead of misbehaving.

| Part | Change | Evidence |
|---|---|---|
| Register file (`xc_m0.v`) | One write port and no reset, so it maps to LUT RAM instead of 480 flip-flops. SP and LR are set in two start-up cycles. Interrupt entry writes LR one bus cycle before SP instead of in the same cycle. | Design change; no instruction timing changes. |
| ROR (register) | Halts (fault 0x01). The right shifter is 32 bits wide instead of 64. | Never executed; not in the code (the 3 byte patterns that decode as ROR are pointer tables). |
| REV16, REVSH | Halt (fault 0x01). REV stays: newlib's compare routine at `0x1006D8CE` uses it. | Not in the code. |
| MRS/MSR | Only MRS IPSR/PRIMASK and MSR PRIMASK remain; the others halt (fault 0x06). | Only PRIMASK is used during play; IPSR appears in pico-sdk code. |
| SIO hardware divider (`xc_soc.v`) | Removed. `xc_soc.bin` has an extra patch table ("MK2P") that redirects the pico-sdk divider functions to software division (`src/xc_soc/xc_div.S`). DIV_CSR reads 0 (the soft-float/double wrappers read it); any other divider access halts (0xBAD00004). | The divider is only used by those functions (all 4 entry points found in the disassembly). |
| APB registers | No register shadow in SRAM. Writes are ignored; reads return fixed values (reset done, oscillators stable, PLLs locked). The only state kept is the clock-source field of CLK_REF/CLK_SYS, for their SELECTED registers. | APB is only accessed while the firmware starts (about 100 accesses in total). |
| NVIC | Only IRQ 26 (mixer tick). | The MSU-1 build has no decode interrupt (IRQ 27). |
| Timer | TIMEHR/TIMELR read the raw counter (no latch). | Only TIMERAWH/TIMERAWL are read. |

The extra patch table sits after the main one, so the mk3 firmware and older MesenCE builds don't see it: the
`xc_soc.bin` built here works unchanged on mk3.

## Checks (first round of cuts only)

- **Software division:** the original divider functions (hardware divider, as MesenCE models it) and the replacements
  were called with 608,000 operand pairs: edge cases (0, ±1, INT_MIN, all ones, division by zero) and random values,
  32 and 64 bits, signed and unsigned. r0–r3 are identical in every case. (A deliberately wrong pairing shows
  thousands of differences, so the test does catch them.)
- **Removed instructions:** a directed test (Icarus Verilog) checks that ROR (two encodings), REV16, REVSH, MRS
  APSR/MSP and MSR APSR/MSP halt with the right fault code, and that REV, MRS IPSR/PRIMASK, MSR PRIMASK, SBC, LSR and
  ASR do not.
- **Random instruction test:** 3,000 random programs (1.42 million instructions, 26,346 interrupt entries) run on this
  core in lockstep with the MesenCE interpreter: 0 mismatches.
- **Game in MesenCE, mk2 mode** (`XC_SOC=1 XC_MK2=1`: software division, fixed APB reads, faults on anything
  removed): 3,600 frames without a fault. All 120 screenshots are identical to the mk3 run. The SNES received the
  same data (7,134 stream transfers, 3,227,563 bytes). The audio differs in four short stretches (about 3% of the
  samples), where sound effects start a tick earlier or later: software division changes the CPU timing slightly.
  Division adds about 366,000 instructions per minute, a negligible load.
- **Game on this core in lockstep** with the interpreter (every instruction's registers, flags and memory accesses
  compared), mk2 mode, from save states through the gameplay part of the test script (frames 1,200-3,600, in
  300-frame pieces): 3.13 billion instructions and about 40,000 interrupt entries, 0 mismatches. The first 1,200
  frames (start-up, menus) ran in lockstep without a mismatch too.
- **Game on the Verilated SoC** (RTL-in-the-loop: `xc_top` with the first-round `xc_m0.v`/`xc_soc.v`, MSU-1, 4 KB caches, 40.25 MHz), 3,600
  frames (with the NVIC change of the last commit: 2,550 frames, then the simulation was stopped): no halt, and every core and DMA access checked against the reference memory (354 million reads, 38 million
  writes, 3.4 MB of DMA) without a mismatch. Compared with the mk3 SoC (16 KB caches), the CPU is busy for longer
  (instruction-fetch stalls 11% of the cycles instead of 2%), but it still spends a third of its time waiting for the
  SNES, and the answer to a frame message takes 7.2 ms (median; 13 ms at the 99th percentile) instead of 6.1 ms.
  One earlier run halted after the last frame, while the simulator was shutting down (bus access to an address
  equal to the timer value); the same design ran through that point cleanly on a rerun, so it looks like a
  test-bench artefact, but keep an eye on it.

## Size

Yosys `synth_xilinx -family xc3s -flatten`, whole design (Yosys counts more than XST; the comparison is what matters):

| Design | LUTs | without LUT1 | RAM16X1D | Flip-flops | Block RAM |
|---|---|---|---|---|---|
| this core | 7,859 | 6,187 | 144 | 2,868 | 12 + 2 IP |
| gsu3 (FX3) core, ludufre fork: fits the XC3S400 | 5,488 | 5,096 | 0 | 2,640 | |
| classic gsu core, same fork: fits (with SmartXplorer) | 5,987 | 5,611 | 0 | 3,213 | |
| XC3S400 | 7,168 LUTs (3,584 slices) | | | 7,168 | 16 |

A RAM16X1D takes two LUT sites. Counting those and leaving out the LUT1 buffers, this core needs about 6,500 LUT sites
against 5,100–5,600 for the gsu cores. Only an ISE build can say whether it fits.

History of the Xeno Crisis logic (`xc_top` alone, 2 KB caches): mk3 design 11,165 LUTs → first round of cuts 7,900 →
size steps 5,765 (see `experiments/`).
