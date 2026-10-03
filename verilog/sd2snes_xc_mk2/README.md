# Xeno Crisis on sd2snes mk2

`sd2snes_xc_mk2` is a complete ISE project for the sd2snes mk2 (Spartan-3 XC3S400), laid out like the other mk2 cores:
`Makefile`, `sd2snes_xc_mk2.xise` (Verilog macros `MK2 | XC_MSU`), `main.ucf`, `config.vh`, `dcm.v` and the Xilinx
memory blocks in `ip/mk2`. `make mk2` builds `fpga_xc_mk2.bit`; `make mk2s` runs SmartXplorer.

**State: runs on hardware.** It fits and meets timing with the soft CPU at 20 MHz (the device is practically full:
any addition needs slices freed elsewhere). On a real mk2 the game plays with music from an MSU-1 pack and the
sound effects mixed in software; without a pack it runs without music.

## Setup

- The mk2 MCU firmware (`config-mk2`) detects the cartridge, builds the image like the mk3 firmware, applies the
  extra "MK2P" patch table and loads `/sd2snes/fpga_xc_mk2.bit`.
- SD card: `xenocrisis_rp2040.bin` and `xc_soc.bin` as on mk3, plus this core as `fpga_xc_mk2.bit`; an MSU-1 pack
  next to the ROM for music. **`xc_soc.bin` and the firmware must come from the same build** (the firmware checks
  the patch table and refuses one it can't apply).
- Linear interpolation in the DAC: define `XC_DAC_LINEAR` (project properties → Synthesize → Verilog Macros, next to
  `MK2 | XC_MSU`). Without it, each sample is held until the next one. Both fit and meet timing.

## How it differs from mk3

MSU-1 only. The mk3 cores (`../sd2snes_xc`, `../sd2snes_xc_msu`) don't use these files and are unchanged.

- **No mixer hardware** (tick timer, interrupts, BRR encoder removed for space; see `experiments/`). The MK2P table
  starts the mixer (`src/xc_soc/xc_mix.c`) without interrupts: the firmware's wait loops call `xc_mix_poll()`, which
  runs the 1 kHz ticks that are due and mixes a block or two while the BRR rings have room. Music requests go to the
  MSU-1 as on mk3; sound effects are mixed and BRR-encoded in software (assembly, see `src/xc_soc/README.md`).
- **No hardware divider:** the MK2P table redirects the pico-sdk divider functions to software division
  (`src/xc_soc/xc_div.S`; identical r0–r3 to the originals over 608,000 operand pairs).
- **Speed-ups for 20 MHz** (also in the MK2P table and the bootrom): the firmware's 65816 code emitter and `memcpy`
  without stack stores (on this core every store is an SRAM write). See "mk2 speed-ups" in `src/xc_soc/README.md`.
- **Smaller soft CPU and SoC**, with what was removed halting with a fault code if ever reached:

| Part | Change | Why it is safe |
|---|---|---|
| Register file | LUT RAM, one write port, no reset | design change; no instruction timing changes |
| ROR (register), REV16, REVSH | halt (fault 0x01); right shifter 32 bits | not in the firmware's code (REV stays: newlib uses it) |
| MRS/MSR | only MRS IPSR/PRIMASK, MSR PRIMASK (else fault 0x06) | only PRIMASK used during play |
| SIO divider | removed; DIV_CSR reads 0, other accesses halt (0xBAD00004) | only the 4 redirected functions use it |
| APB | writes ignored, fixed reads (only CLK_REF/CLK_SYS source kept) | only accessed at start-up |
| Timer | 40 bits; TIMEHR/TIMELR read the raw counter | only TIMERAWH/TIMERAWL are read |
| Cache | one 16 KB 2-way write-through cache for code and data | |
| Other | no early fetch, no performance counters, no RAM clear at start, window descriptor queue 2 deep | `experiments/README.md` |

The MK2P table sits after the main table, so the same `xc_soc.bin` works on mk3 (whose firmware ignores it).

## Files

| File | Contents |
|---|---|
| `main.v` | the Xeno Crisis `main.v` with its mk2 branch; adds `soc_dcm` |
| `dcm.v` | `my_dcm` (CLK2 = 24 MHz × 25 / 7 = 85.7 MHz, as in the gsu core), `soc_dcm` (24 MHz × 5 / 6 = 20 MHz) |
| `main.ucf` | mk2 pinout (as sd2snes_gsu) plus TIG between CLK2 and the soft CPU clock (through `xc_bridge`'s synchronizers) |
| `xc_m0.v`, `xc_soc.v`, `xc_cache.v` | soft CPU, SoC and cache (see above) |
| `xc_bridge.v` | clock-domain bridge; its buffers in distributed RAM |
| `xc_window.v`, `xc_stream.v` | `$3000` window |
| `xc_top.v` | the blocks together, MSU-1 only |
| `msu.v`, `xc_dac.v`, `xc_msubox.v` | MSU-1 audio (no data port), DAC (one channel at a time through a shared datapath), soft CPU → MSU-1 registers |
| `address.v`, `cheat.v`, `mcu_cmd.v`, `sd_dma.v`, `spi.v` | as in `../sd2snes_xc` |

Block RAM: cache data 8, cache tags 2, window rings 2, `dac_buf` 1, `snescmd_buf` 1: 14 of 16.

## XST pitfall: don't call a function twice in one always block

The first bitstream showed a black screen: every byte load read 0xFF. XST (ISE 14.7) built the function
`lane_out()`, called twice in one block of `xc_soc.v` (cache data and erased-flash 0xFFFFFFFF), as one shared
circuit. Verilator and Icarus simulate it correctly, so no simulation showed it. The load lanes are now plain wires
(addressed halfword on bits 15:0, addressed byte on 7:0; `xc_m0` extends them itself), which is also smaller.

## Testing

- **Hardware:** long sessions without a halt (e.g. 649,385 mixer ticks, 998 sound effects, 9 music tracks).
- **RTL-in-the-loop:** `xc_top` Verilated with MesenCE running the SNES side, 3,600 frames of the test script, every
  core and DMA access checked against a reference memory: 0 mismatches. With full sound and the current speed-ups:
  frame message → stream post p50 7.3 / p95 9.5 / p99 10.9 / max 33.5 ms (mk3: p50 6.1 ms); 3 of 3,679 game ticks
  later than one frame; mixer 22% of the CPU, the BRR ring empty in 4 of 59,895 one-millisecond samples.
- **Lockstep** against the MesenCE interpreter: 3,000 random programs (1.42 million instructions) and 3.13 billion
  instructions of gameplay, 0 mismatches. A directed test checks that the removed instructions halt with the right
  fault code.
- **MesenCE, mk2 mode** (`XC_SOC=1 XC_MK2=1`): screenshots identical to mk3; MSU-1 register writes the same as on the
  mk3 MSU-1 core to within 1 ms.
