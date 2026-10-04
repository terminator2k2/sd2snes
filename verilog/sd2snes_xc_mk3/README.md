# Xeno Crisis on sd2snes mk3: the `sd2snes_xc_mk3` core

Xeno Crisis on the sd2snes mk3 (FXPAK Pro): a soft Cortex-M0 CPU in the FPGA runs the cartridge's RP2040 firmware.
One bitstream, `fpga_xc_mk3.bi3`, plays the music either from the game's own Opus streams (decoded by the MCU) or
from an MSU-1 pack; the firmware picks one when the game loads. The mk2 port (Spartan-3, MSU-1 only, 20 MHz soft
CPU) is in [`../sd2snes_xc_mk2`](../sd2snes_xc_mk2/README.md).

**Status:**
- Quartus (25.1): fits and meets timing. 14,432 of 15,408 logic elements (94%), 51 of 56 M9K, 18 multipliers.
  Slow 85C setup slack: `clk[1]` (soft CPU, 40.25 MHz) +1.191 ns (Fmax 42.28 MHz), `clk[0]` (CLK2, 85.87 MHz)
  +1.111 ns; no critical warnings.
- Hardware: the separate Opus and MSU-1 cores this one combines ran the game at full speed with music and sound
  effects (no game tick longer than one SNES frame in 30 s of play). This combined core still has to be tried.
- Music: with an MSU-1 pack next to the ROM, from the pack (both MCUs). Without one, the STM32F401 firmware
  (`firmware.stm`) decodes the game's Opus streams; the LPC1756 firmware (`firmware.im3`) has no Opus decoder and
  plays the sound effects only. Pack layout and track list: [`MSU1_PACK.md`](MSU1_PACK.md).

## Setup

1. **FPGA:** this folder is a self-contained Quartus project (`sd2snes_xc_mk3.qpf`, EP4CE15F17C8); `make` builds
   `fpga_xc_mk3.bi3`. Copy it to `/sd2snes/`.
2. **MCU firmware:** `make CONFIG=config-mk3-stm32` / `make CONFIG=config-mk3` as usual (the STM32 build makes the
   Opus library first). The build also makes **`xc_soc.bin`** (`src/xc_soc/`: replacement bootrom and firmware
   additions) next to the firmware image. Copy it to `/sd2snes/` with the firmware: **the two must be from the
   same build.**
3. **The game:** the RP2040 flash dump as `/sd2snes/xenocrisis_rp2040.bin` (16 MB, supplied by the user like DSP
   files); load the cartridge's SNES ROM (`XENOCRISIS`, 128 KB, CRC32 `FE5B38F0`) from the menu. Without a `.srm`
   the save area starts from the dump's, so cartridge saves carry over. For MSU-1 music, put `<rom>.msu` and the
   `<rom>-<n>.pcm` tracks next to the ROM.
   - A missing or wrong dump or `xc_soc.bin` shows as a missing supplemental file. `/sd2snes/xc_debug.txt` (written
     right after loading, then every 30 s of music and when the game is left) has the load results, the MSU-1 pack
     check and the audio/performance statistics.

## Overview

```
                      sd2snes FPGA (CLK2, 85.9 MHz)                          | clk_soc (40.25 MHz)
 SNES bus --> address.v --> $3000 window: xc_window                           |
              (LoROM kernel)     descriptor queue -> DMA -> 512 B ring --> SNES|
                                 RX FIFO <-- SNES writes                       |
 PSRAM  <-- ROM FSM (main.v) <-- xc_bridge executor <== toggle handshake ===> xc_soc
 SRAM   <-- RAM FSM (main.v) <-- SRAM arbiter (DMA first)                     |   xc_m0 + I$ 16 KB + D$ 16 KB
 MCU    <-> mcu_cmd.v ($C0-$C8) <-> xc_decbox (Opus) + xc_msubox <== bridge ==>|   timer, SIO, NVIC, BRR, tick
 MSU-1  <-- msu.v (audio only) --> xc_dac (DAC)
```

- **Clocks:** the soft CPU runs at 40.25 MHz from a second PLL output (8 MHz × 161/32; an exact 40 MHz has no
  common VCO with CLK2's 85.87 MHz). The microsecond timer and mixer tick take the clock as a fraction
  (`SOC_CLK_NUM/SOC_CLK_DEN` = 161/4) with phase accumulators, so time stays exact.
- **Crossing:** everything goes through `xc_bridge`, one operation at a time (cache line, register access or single
  access), with toggle handshakes and two small dual-clock RAMs, so the SoC clock can be changed freely: PLL `clk1`
  = 161/*d*, `SOC_CLK_NUM/SOC_CLK_DEN` = 1288/*d* reduced, and the `clk[1]` line in `main.sdc` (e.g. *d* = 34:
  37.88 MHz, the fallback if timing ever fails).
- **Memory buses:** PSRAM through the GSU core's free-slot scheme (one access per SNES cycle when the SNES isn't
  reading ROM). The SNES never uses the SRAM chip in this core, so it is the SoC's: line fills and write-backs run
  as bursts of up to 32 bytes, 8 CLK2 cycles per byte (`XC_RAM_LEN`, `XC_RAM_BSTB`); the window DMA has priority
  between bursts.

## Memory

PSRAM (16 MB), built by the MCU at load time (`src/xc_load.c`; `src/xc_soc/xc_build_image.py` makes the same as a
file for debugging and MesenCE; a ROM file larger than 128 KB is loaded as such a prebuilt image):

| PSRAM | Contents | Used by |
|---|---|---|
| `0x000000-0x01FFFF` | SNES kernel ROM (128 KB) | SNES, LoROM |
| `0x020000-0xCFFFFF` | RP2040 flash `0x020000-0xCFFFFF` | soft CPU (flash offset = PSRAM address) |
| `0xD00000-0xD1FFFF` | RP2040 flash `0x000000-0x01FFFF` | soft CPU |
| `0xD20000-0xD23FFF` | replacement bootrom | soft CPU, address 0 |
| `0xD24000-0xD27FFF` | firmware additions (RP2040 flash `0xF00000`) | soft CPU |

This keeps clear of the MCU's areas at 0xE00000 and up; the cheat area at 0xD00000 is used (no cheats or save
states with this game).

SRAM chip (512 KB):

| Address | Contents |
|---|---|
| `0x00000-0x07FFF` | RP2040 flash save area (`0xFF8000-0xFFFFFF`), loaded from and saved to the `.srm` (32 KB) |
| `0x08000-0x49FFF` | RP2040 RAM (264 KB) |
| `0x4A000-0x4AFFF` | RP2040 USB RAM |
| `0x4C000-0x4DFFF` | register shadow for the boot-time APB setup |

## The SoC (`xc_soc.v`)

- **Caches:** I-cache 16 KB 2-way (flash, bootrom); D-cache 16 KB 2-way write-back (RAM, flash, bootrom), 32-byte
  lines. Hits without wait states. A dirty victim goes to the bridge's write buffer and is written after the fill.
  Flash and RAM aliases share one cache key. Writing `TX_LEN` first writes back the dirty lines of the posted range
  (the whole cache for posts over 4 KB). The save area, USB RAM and register shadow are uncached.
- **Peripherals:**
  - Timer (`0x40054000`): 64-bit microsecond counter; alarms halt the core if armed (never in this mode).
  - SIO: CPUID, spinlocks, radix-2 divider (32 cycles, RP2040 results incl. division by zero and `INT_MIN / -1`);
    interpolator accesses halt.
  - NVIC/VTOR: IRQ 26 mixer tick, IRQ 27 decode done (synchronized from CLK2); lowest pending first.
  - BRR encoder `xc_brr.v` and tick `xc_tick.v`, in the SoC clock domain.
  - APB: register shadow in SRAM with the atomic aliases; fixed status values, PLL lock and `CLK_x_SELECTED` derived
    from the stored control registers.
  - Debug/panic (`0x50802010/14`): a panic or fault halts the core; the MCU reads the halt code and address (`$C5`)
    and prints them on its UART.
- **Start-up:** invalidate the caches, clear SRAM `0x08000-0x4DFFF` (about 30 ms), take SP/PC from the vector table
  at `0x10000100` (where boot2 leaves the RP2040) and set VTOR there. The SoC is held in reset while the SNES is in
  reset (`SNES_DEADr`) and until the MCU sends `$C6 XC_RUN`.
- **`$3000` window** (`xc_window.v`): 8 descriptors deep (`{RAM address, length ≤ 64 KB}` or one immediate byte); a
  DMA reader on the SRAM chip fills the 512-byte ring the SNES reads. Register semantics as in MesenCE's SoC mode
  (`src/xc_soc/xc_soc.h`).
- **Performance counters** (`$C7`/`$C8`, logged in `xc_debug.txt`): SoC cycles, cycles stalled on instruction
  fetches / flash data / RAM data, game ticks, ticks longer than a frame, longest tick, window underruns.

- **Music source** (`xc_top`, `MSU = 2`): the Opus decode mailbox (`xc_decbox.v`) and the MSU-1 registers
  (`xc_msubox.v`) share one address range in the soft CPU's map (the mailbox does not use `0x010`/`0x014`). `CTRL`
  bit 3 reads the MCU's choice (`$C6 XC_RUN` bit 1); the mixer (`src/xc_soc/xc_mix.c`) reads it once at start and
  runs in Opus or MSU-1 mode.
- **MSU-1** (`msu.v`, `xc_dac.v`): register writes come from the soft CPU only (the SNES does not see the MSU-1; the
  MCU clears `FEAT_MSU1`); no data buffer, since the game has no MSU-1 data. `xc_dac.v` is `dac.v` with linear
  interpolation instead of the 3-stage CIC (about 520 LUTs + 4 DSP multipliers instead of about 1,600 LUTs); same
  buffer, MCU interface, 44.1 kHz timing, volume ramp and I2S output.

Left out to save space: cheats and in-game hooks (`XC_WITH_CHEAT` in `main.v`; so the reset-to-menu button
combination doesn't work, a long reset does), save states, the MSU-1 data port.

## Soft CPU in MSU-1 mode (`src/xc_soc/xc_mix.c`)

- The game's music position still advances at the same pace (packets count as decoded, nothing goes to the MCU),
  so its end-of-track and loop logic are unchanged. The music is not mixed into the BRR stream; the sound effects are.
- When the game starts a track from the beginning, the mixer requests MSU-1 track n (the stream's number in the
  firmware's table). A track the game loops onto itself plays with MSU-1 repeat. An intro plays once, and its loop
  part starts as soon as the intro `.pcm` ends.
- Pause and resume map to the MSU-1 play bit; a reset stops the MSU-1; a missing `.pcm` is silent. The mixer waits
  for "audio busy" to clear before writing the control register.

## MCU (sd2snes `src/`)

- **Detection** (`smc.c`): map `$30`, chipset `$63`, maker `BM`, game `XCRI`; 32 KB save RAM. `xc_select_core()`
  (`xc_load.c`) loads `fpga_xc_mk3.bi3` and chooses MSU-1 music when `<rom>.msu` is next to the ROM.
- **Loading** (`memory.c`, `xc_load.c`): the SNES ROM, then the dump (two SD DMA transfers) and `xc_soc.bin`, and
  the additions' patch table is applied in the PSRAM. The dump is checked for size and firmware build
  (`multicore_launch_core1` at `0x10059060`), `xc_soc.bin` for its header. `xc_run()` releases the soft CPU just
  before the SNES leaves reset, with the music choice in bit 1.
- **MSU-1 music:** the usual `msu1_loop()`, with one change for Xeno Crisis: it checks the save RAM every second
  even while music plays, regardless of the MSU-1 autosave setting, because this is the game's only save path while
  it runs. During that CRC and the save, `xc_audio_service()` refills the MSU-1 audio buffer.
- **Opus decode service** (`xc_audio.c`, polled from `main.c`): the mixer posts one 20 ms packet at a time through
  the mailbox (`xc_decbox`); the MCU decodes it and returns the PCM (about 7 ms per packet on the STM32F401). Long
  MCU jobs (the save RAM CRC, `save_sram()`) serve the decoder in between, and with this game the main loop skips
  its per-iteration `sram_reliable()` and the CIC debug print, which stalled it for up to 12 ms. All SPI transfers
  are byte by byte (`FPGA_RX_BYTE`, `FPGA_TX_BYTE` + `FPGA_TX_SYNC`): the block functions hang or corrupt data with
  the FPGA.
- **Opus library:** `make` builds `libopus_xc.a` from the vendored Opus 1.3.1 (`src/xc_opus/`, `build.sh` and its
  patches: decoder only, no SILK downsampler, trimmed): `-Os`, the hot CELT synthesis files `-O2`, small-footprint
  `cwrs.c`. It decodes the game's streams bit-exact (checksum `0xdb88f8e0`, host and Cortex-M4 model).
  `firmware.stm` is about 206 KB of 212 KB; `stm32f401.ld` makes the `.ahbram` buffers `NOLOAD` (8,992 bytes less
  in the image) and asserts that the image fits.
- **LPC1756** (`firmware.im3`), without a pack: the decoder (about 26.5 KB contiguous RAM plus 11 KB of stack) doesn't fit, so every
  packet is answered as "nothing decoded"; the mixer treats the track as ended and keeps mixing the sound effects
  (checked in MesenCE: identical screenshots, audio = the sound effects alone).

FPGA commands (`mcu_cmd.v`):

| Command | Function |
|---|---|
| `$C0` XCA_STATUS | read: null, {reset, job}, length (2 bytes LE) |
| `$C1` XCA_READPKT | read: null, packet bytes |
| `$C2` XCA_WRITEPCM | write: 1,920 PCM bytes |
| `$C3` XCA_DONE | write: ret (4 LE), final range (4 LE), flop byte; raises IRQ 27 |
| `$C4` XCA_ACKRESET | clear the decoder reset request |
| `$C5` XC_STATUS | read: null, {running, halted}, halt code (4 LE), halt address (4 LE) |
| `$C6` XC_RUN | write: bit 0 = release the soft CPU (0 = hold it), bit 1 = MSU-1 music |
| `$C7` XC_PERF_SNAP | snapshot of the performance counters |
| `$C8` XC_PERF | read: null, 8 counters (4 bytes LE each) |

## Verification

- **Whole game on the RTL** (`runner_rtl`, `XC_RTL=1`): MesenCE runs the SNES, the Verilated `xc_top` replaces the
  RP2040, with models of the PSRAM, SRAM chip, window strobes and MCU decode service. Every core read is checked
  against a reference memory and every window DMA byte against what the core wrote: 3,600 frames, about 390 million
  reads, 0 mismatches. Music correlates at 1.000 with MesenCE.
- **`xc_m0`:** random-program lockstep with the MesenCE interpreter (2 × 3,000 programs) and full-firmware lockstep,
  0 mismatches. **Divider:** 2 million divisions, 0 wrong. **`xc_brr`:** bit-exact on 1,040,000 blocks.
- **`$3000` window** (`tb_xc_window.v`): 600 frames of recorded traffic from an SRAM model with random latency, 0
  errors; planted bugs are caught. **SRAM bursts:** `rambench/tb_ram_burst.v` against an asynchronous SRAM model.
- **MCU ↔ FPGA link** (`mcutest/`): the real `xc_audio.c` against `spi.v`, `mcu_cmd.v` and `xc_decbox.v` with an
  STM32 SPI master model; 500 packets bit-exact (this found the block-transfer hang). LPC1756 path: 500/500 jobs
  answered, no hang.

- **Combined core:** iverilog elaborates the project cleanly. RTL-in-the-loop, 900 frames each: in Opus mode the
  same results as the former Opus-only core (595 decode jobs, game ticks, latencies, stream), in MSU-1 mode the same
  as the former MSU-1-only core (9 MSU-1 register writes, no decode jobs); 0 mismatches.
- **MSU-1 in MesenCE:** with a pack of test tones, the register writes and recorded audio were right for intros,
  repeats, intro → loop, pause/resume, missing tracks and reset. `fpga/msutest/tb_msu.v` checks `xc_msubox` +
  `msu.v` + `xc_dac.v` (register writes and status, "audio busy", 44.1 kHz input rate, same output as `dac.v`).

## Project files

Copies of all sources, so the folder builds on its own. The PLL is `xc_mk3_pll.v`, a renamed copy of the standard
mk3 PLL listed as a plain Verilog file (through a `.qip`, Quartus picked up a PLL without the soft CPU's `c1`
output). `main.qsf` defines `MK3`, `XC_MSU` and `XC_MK3`.

## Open points (hardware)

1. This core on hardware, with and without an MSU-1 pack.
2. Saves: the `.srm` appears after the first save, and a cartridge save carries over from the dump.
3. LPC1756 firmware: sound effects only, and with an MSU-1 pack.
4. Reset: `SNES_DEADr` holds the SoC in reset during reset to menu and long reset (watch the UART for a halt report).
