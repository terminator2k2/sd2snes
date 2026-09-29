# Xeno Crisis on sd2snes mk2: cut-down soft CPU (work in progress)

This folder holds the mk2 (Spartan-3 XC3S400) variants of the two largest parts of the Xeno Crisis core, the soft CPU
(`xc_m0.v`) and the SoC around it (`xc_soc.v`). They are cut down to what the game actually uses. The mk2 core is
meant for the MSU-1 version only, so the music comes from an MSU-1 pack and there is no Opus decoding.

The mk3 cores (`../sd2snes_xc`, `../sd2snes_xc_msu`) do not use these files and are unchanged.

**Status:** there is no mk2 FPGA core yet. What is missing is the top level for the Spartan-3 (`main.v`, pin
constraints, the DCM clocks), the Xilinx memory blocks and the MCU side for the mk2 firmware. These two files are
checked in simulation (see below). The real open question is size: even cut down, the logic is about twice what the
mk2 FPGA has room for (see "Size").

## What is removed, and why that is safe

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

## Checks

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
- **Game on this core in lockstep** with the interpreter, and **the game on the Verilated SoC** (RTL-in-the-loop,
  MSU-1, 4 KB caches): see the results below.

## Size

Yosys, Spartan-3 (the numbers overcount compared with XST; the comparison is what matters). All the Xeno Crisis logic,
MSU-1, 2 KB caches:

| | LUTs | of which LUT1 | Flip-flops |
|---|---|---|---|
| mk3 design | 11,165 | 1,869 | 4,001 |
| this folder | 8,005 | 1,015 | 3,109 |
| SuperFX (GSU), which fits on the mk2 only just | 3,623 | 271 | 1,424 |
| whole XC3S400 | 7,168 | | 7,168 |

What is left is needed: the CPU core (~3,200), the cache and memory controller (~2,500), the BRR encoder (~800), the
`$3000` window (~800) and the clock-domain bridge (~500).

Block RAM is less of a problem than it looks. The XC3S400 has 16 block RAMs of 2 KB each (2,048 × 8 bits plus parity, or 512 × 32), with no
byte write enables. Without the unused MSU-1 data buffer (8 block RAMs), 14 are free after `dac_buf` and `snescmd_buf`.
A D-cache needs one block RAM per byte lane and way, so 8 of them hold up to 16 KB; a 4 KB I-cache needs 2 (32 bits
wide, no byte writes), plus tags. The caches can therefore stay large.
