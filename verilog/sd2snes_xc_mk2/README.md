# Xeno Crisis on sd2snes mk2

ISE project for the sd2snes mk2 (Spartan-3 XC3S400), laid out like the other mk2 cores (`sd2snes_xc_mk2.xise`,
macros `MK2 | XC_MSU`). `make mk2` builds `fpga_xc_mk2.bit`; `make mk2s` runs SmartXplorer.

**State: runs on hardware.** Fits and meets timing with the soft CPU at 22 MHz (+0.24 ns slack); the device is practically full.
Music comes from an MSU-1 pack (none without one), sound effects are mixed in software.

## Setup

- SD card: `fpga_xc_mk2.bit`, `xenocrisis_rp2040.bin` and `xc_soc.bin` in `/sd2snes/`, an MSU-1 pack next to the ROM
  (see `../sd2snes_xc_mk3/MSU1_PACK.md`). **`xc_soc.bin` and the firmware (`config-mk2`) must be from the same
  build.**
- The DAC interpolates linearly; define `XC_DAC_NOLINEAR` (Synthesize → Verilog Macros) to hold each sample instead.

## Differences from mk3 (`../sd2snes_xc_mk3`)

- **No mixer hardware** (tick timer, interrupts, BRR encoder). The firmware's wait loops call `xc_mix_poll()`, which
  runs the due 1 kHz ticks and mixes a block or two; sound effects are mixed and BRR-encoded in software.
- **No hardware divider:** software division (`src/xc_soc/xc_div.S`, identical results to the originals).
- **Speed-ups:** the 65816 code emitter and `memcpy` without stack stores, and the game's tile-flag loops in
  registers with two entries per store (`xc_tile.S`); every store is an SRAM write here. The mk2 firmware applies
  these through the "MK2P" patch table; the mk3 firmware ignores it.
- **Smaller soft CPU and SoC.** Anything removed halts with a fault code if reached:

| Part | Change | Why it is safe |
|---|---|---|
| Register file | LUT RAM, one write port, no reset | no timing change |
| ROR (register), REV16, REVSH | fault 0x01 | not in the firmware's code |
| MRS/MSR | only IPSR/PRIMASK (else fault 0x06) | only PRIMASK used in play |
| SIO divider | removed (DIV_CSR reads 0, else 0xBAD00004) | only the 4 redirected functions use it |
| APB | writes ignored, fixed reads | start-up only |
| Timer | 40 bits, raw reads | only TIMERAWH/L are read |
| Cache | one 16 KB 2-way write-through cache | |
| Other | no early fetch, no performance counters, no RAM clear, window queue 2 deep | |

Block RAM: 14 of 16 (cache 10, window rings 2, `dac_buf`, `snescmd_buf`).

## XST pitfall

Don't call a Verilog function twice in one always block: XST builds one shared circuit. This made every byte load
read 0xFF (black screen) while Verilator and Icarus simulated it correctly. The load lanes in `xc_soc.v` are plain
wires now.

## Testing

- **Hardware:** long sessions without a halt (649,385 mixer ticks, 998 sound effects, 9 music tracks).
- **RTL-in-the-loop** (Verilated `xc_top`, MesenCE for the SNES, 3,600 frames, every access checked): 0 mismatches;
  at 22 MHz, frame message → stream post p50 7.2 / p99 10.7 / max 29.4 ms (mk3: p50 6.1 ms), 1 of 3,670 game ticks
  late; mixer 21% of the CPU.
- **Lockstep** with the MesenCE interpreter: 3,000 random programs and 3.13 billion instructions of gameplay, 0
  mismatches; removed instructions halt with the right fault code.
