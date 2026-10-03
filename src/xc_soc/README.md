# xc_soc – Xeno Crisis soft CPU support

Xeno Crisis ships on a SNES cartridge with an RP2040 coprocessor. On the FXPAK Pro / sd2snes
mk3, the `sd2snes_xc` and `sd2snes_xc_msu` FPGA cores replace the RP2040 with a soft Cortex-M0 CPU. That CPU
runs the game's own RP2040 firmware (the flash dump `xenocrisis_rp2040.bin`) from the PSRAM.

This CPU has no RP2040 boot ROM, no second core and none of the RP2040's PIO/DMA peripherals. It also runs much
slower (about 40 MHz). The code in this folder fills those gaps. It is built into one file,
**`xc_soc.bin`**, which the sd2snes firmware loads together with the game.

`xc_soc.bin` does not contain any of the game's code or data. It only contains code written for sd2snes.

## Where it goes

Copy `xc_soc.bin` to `/sd2snes/` on the SD card, next to the firmware, `fpga_xc.bi3` and
`fpga_xc_msu.bi3`. Both cores use the same file. When Xeno Crisis starts, the MCU (`src/xc_load.c`) does
this:

1. It loads the 128 KB SNES ROM, `/sd2snes/xenocrisis_rp2040.bin` and `xc_soc.bin` into the PSRAM.
2. It redirects the firmware functions listed in the additions' patch table (see below) to their replacements.
3. It starts the soft CPU.

`xc_soc.bin` has to come from the same build as the firmware. If it is missing or from an older build, the game
may have no sound or may hang. The build places it next to `firmware.stm` / `firmware.im3`, so copy both
together.

## What is in it

| Part | Source | Runs at (soft CPU) | Purpose |
|---|---|---|---|
| Replacement bootrom | `xc_bootrom.c`, `xc_bootrom_tables.S`, `xc_bootrom_flags.S`, `xc_bootrom.ld` | `0x00000000` | The RP2040 boot ROM functions that the pico-sdk runtime looks up: the lookup tables, bit operations, memset/memcpy and the soft-float/soft-double tables (built on libgcc). Functions the game never calls during play (sqrt, trig, exp/log) stop with a panic code. |
| Audio mixer | `xc_mix.c`, `xc_mix_entry.S`, `xc_mix.ld` | `0x10F00000` (free flash space), data and stack in `SCRATCH_X` | On the cartridge, core 1 decodes the Opus music and mixes it with the sound effects. The soft CPU has no second core, so this work runs as two interrupt handlers instead: a 1 kHz tick and a "packet decoded" interrupt. The MCU decodes the Opus packets, which it receives through a mailbox. The `xc_brr` hardware block does the BRR encoding. On the MSU-1 core, the mixer sends the game's music commands to the MSU-1 instead, and only mixes the sound effects. On the mk2 core (no tick timer, interrupts or BRR encoder), the mk2 table starts it in a mode without interrupts instead: the firmware's wait loops in `xc_shim.c` call `xc_mix_poll()`, which runs the 1 kHz ticks that are due and mixes a block or two while the BRR rings have room. The sound effects are mixed and BRR-encoded in software there (`xc_mix_voice.S`, `xc_brr_sw.S`), the music comes from the MSU-1. |
| Function replacements | `xc_shim.c` | `0x10F00000` region | Replacements for firmware functions that depend on RP2040 hardware: the SNES bus layer (PIO + DMA → the `$3000` window FIFOs), `sleep_until`, `puts`/`printf` (→ debug port), `panic`, and the flash write/erase functions (→ the save area, which lives in the cartridge SRAM and is saved as the `.srm` file). |
| Patch table | `xc_fw_header.c` | `0x10F00000` | The header ("MXCX", version 2) with the list of firmware addresses to redirect. `multicore_launch_core1` becomes `xc_mix_install`, which sets up the mixer. Clock and stdio setup become "return 0". A second table ("MK2P") follows it; only a loader for a core without the SIO hardware divider (sd2snes mk2) applies it. |
| mk2 mixing | `xc_mix_voice.S`, `xc_brr_sw.S`, `xc_brr_sw.h` | `0x10F00000` region | Mono voice mixing and the BRR encoder in hand-written Thumb assembly, for the mk2 core (see "mk2 mixing" below). |
| mk2 table | `xc_fw_header.c` | – | After the main table ("MK2P", up to 64 entries): the divider functions below, `multicore_launch_core1` → `xc_mix_install_mk2` (the mixer without interrupts), and the 65816 code emitter (`xc_emit.S`, with code patches: kind 3 writes a word). |
| Software division (mk2 only) | `xc_div.S` | `0x10F00000` region | Replacements for the pico-sdk divider functions (32- and 64-bit, signed and unsigned), for the mk2 core, which has no SIO divider. They give the same results in r0–r3 as the originals, including division by zero. The mk3 cores keep the hardware divider and don't use them. |
| Register map | `xc_soc.h` | – | The SoC registers the FPGA cores add around the CPU: BRR encoder, decode mailbox / MSU-1 control, tick timer, debug port, `$3000` window, IRQ numbers. |

All addresses in `xc_mix.c`, `xc_shim.c` and `xc_fw_header.c` belong to the **Xeno Crisis SNES v1.00** RP2040
firmware. The loader checks this and refuses other builds.

## File layout of `xc_soc.bin`

| Offset | Size | Contents | Loaded to (PSRAM) |
|---|---|---|---|
| `0x0000` | 512 bytes | Header: `"XSOC"`, version 1, bootrom length, additions length (32-bit LE words); the rest is `0xFF` | – |
| `0x0200` | 16 KB | Replacement bootrom, padded with `0xFF` | `0xD20000` (soft CPU `0x00000000`) |
| `0x4200` | 16 KB | Firmware additions (header + mixer + replacements), padded with `0xFF` | `0xD24000` (RP2040 flash `0x10F00000`) |

The build fails if either part is larger than 16 KB.

## Building

`make` in `src/` builds `xc_soc.bin` together with the firmware and writes it to `src/obj-<config>/`. To build
only this file:

```
make            # -> ./xc_soc.bin (plus xc_fw.bin, xc_bootrom.bin)
make OUT=dir    # -> dir/xc_soc.bin
make clean
```

This only needs `arm-none-eabi-gcc`, the same toolchain as the firmware. The code is built with
`-mcpu=cortex-m0plus`, because it runs next to the RP2040 firmware on the same ARMv6-M instruction set. The
soft CPU implements what the game firmware uses: the Cortex-M0+ subset, including VTOR.

## Other files

- `test_mix_math.c`: a host test. It checks that the mixer's division-free rounding helpers give the same
  results as the firmware's division-based ones for every input. Build and run it with
  `cc -O2 test_mix_math.c && ./a.out`.
- `test_brr_sw.c`: host test of the mk2 software BRR encoder (`xc_brr_sw.h`) against the firmware's brute-force
  encoder: `cc -O2 test_brr_sw.c -lm && ./a.out [blocks.bin ...]` (without files: 2 million random blocks;
  `blocks.bin`: 16 int16 per block, as MesenCE writes them with `XC_BRRDUMP=file`).
- `test_brr_sw_asm.py`, `test_mix_voice_asm.py`: run the assembly (`xc_brr_sw.S`, `xc_mix_voice.S`) in the Unicorn
  ARM emulator (`pip install unicorn`) and compare it with the C versions, block by block.
- `xc_patch_image.py`, `xc_build_image.py`: offline tools that apply the same patches to a flash dump and build
  a complete prebuilt image. The firmware does this itself at load time now, so these are only needed for
  debugging or for comparing against an emulator (for example MesenCE).

## mk2 mixing

The sd2snes mk2 core has no room for the mixer's tick timer, interrupts or the `xc_brr` encoder, and it runs the
soft CPU at 20 MHz. There the mixer (`xc_mix_install_mk2`) runs from core 0's wait loops, and does in software
what `xc_brr` does in hardware on mk3:

- **When:** `xc_mix_poll()` (`xc_mix_entry.S`) is called in every round of the firmware's wait loops. It checks,
  without a single store, whether a tick is due or the left BRR ring has room; only then does it switch to the
  mixer's stack and run the due ticks and two blocks (about 0.15 ms each; eight, and the encoder's fast mode,
  while the rings are less than half full). The mixer only runs inside
  core 0's calls, so core 1 counts as always parked (core 0's save waits for that in a loop that calls nothing).
- **Why stores matter:** the mk2 core's cache is write-through, so every store (including every register pushed on
  the stack) goes out to the 8-bit SRAM chip. The compiled C spilled registers inside its loops; the hot loops are
  therefore written in assembly, with everything in registers.
- **Mixing:** the game's sound effects have the same volume left and right. Then one channel is mixed, into
  16-bit samples two per word, encoded once, and written to both rings (4 stores per block and ring instead of
  9). Voices with different volumes fall back to a stereo path in C.
- **BRR encoding** (`xc_brr_sw.h`, `xc_brr_sw.S`): the firmware tries all 11 shifts per block. This encoder takes
  the smallest shift at which no sample clips (s0) and s0 - 1, with the firmware's nibble rule and error sum; s0 - 1
  is skipped when a lower bound of its error (the clipping of the largest and smallest sample) already reaches
  the error at s0, or the most that error can be. On the game's sound effects (178,720 blocks from 60 s of play)
  99.9% of the blocks come out identical to the firmware's, the rest have the same error. On very loud blocks the
  firmware's 32-bit error sum can wrap and pick a clipping shift; this one does not follow it there. Fast mode
  (s0 only, when the mixer has fallen behind) gives ~1 dB more noise on about 10% of the blocks.
- **Result** (RTL simulation of the mk2 core at 20 MHz, 60 s of play): 1,487 blocks per second, the game needs
  ~1,490; the mixer takes 24% of the CPU; the left BRR ring was empty in 3 of 59,869 millisecond samples.

### mk2 speed-ups

At 20 MHz, with every store going out to the SRAM chip, some frames take longer than one SNES frame (the game then
slows down, and the SNES may still be updating the screen when it starts drawing: flicker at the top). Profiling
those frames in the RTL simulation (60 s of play) showed two hot spots that are cheap to fix in software:

- **The firmware's 65816 code emitter** (`xc_emit.S`): the firmware builds the code it streams to the SNES one
  byte at a time through small nested functions, each pushing registers, so a two-byte instruction cost about 14
  stores. The mk2 table redirects `emit8`, `emit16` and the six opcode helpers (LDA #, LDX #, STA dp, STA abs,
  STX abs, STZ abs) to leaf functions that store only the output bytes and the new length.
- **`memcpy` between buffers of different alignment** (`rom_memcpy`, now `xc_bootrom_memcpy.S`): copied byte by byte
  before; now with word stores (aligned word loads shifted together). This one is in the bootrom, so mk3 gets it
  too (same results, the change only matters for speed).

Both give the same results as the originals (unit tests against the firmware's own functions in an ARM emulator;
60 screenshots over 60 s of play in MesenCE identical). RTL simulation, 60 s of play, mixer on:

| | before | after |
|---|---|---|
| game ticks later than one frame | 10 of 3,616 | 3 of 3,671 |
| frame message to stream post, p95 / p99 / max | 11.1 / 13.5 / 55.9 ms | 9.8 / 11.6 / 41.0 ms |

Second round (same method, frames over 10 ms profiled):

- **`memcpy` by hand** (`xc_bootrom_memcpy.S`): the C version compiled with `-Os` kept copies of its values on the
  stack, two extra stack stores per 16 bytes in the aligned loop and one per word in the shifting loop. The
  assembler version has no stack stores in the aligned and short cases and four pushes for the shifting loop
  (half the stores over all alignments and lengths 0-69, 100, 255, 256, 1000, 1023; same results as the C version).
- **The emitter's entry points without stack stores**: the veneers of the mk2 table (`push {r0}` ... `pop {r0}`)
  cost a store per call, and the firmware's one-line wrappers that take the builder from a global
  (`push {r4, lr}; ...; bl emit; pop {r4, pc}`) two more. The mk2 table now has code patches (kind 3: write a
  word), which put a veneer `ldr r3, =fn; bx r3` on the eight emitter functions (they clobber r3 anyway) and turn
  seven wrappers into tail calls without a push. The tile map loops call two wrappers per tile, 14 stores
  before, 8 now. This makes the table 53 entries long; the mk2 firmware takes up to 64 (16 before) and knows
  kind 3, so **this `xc_soc.bin` needs the mk2 firmware of the same build**.

RTL simulation, 60 s of play:

| | before | after |
|---|---|---|
| frames over 10 ms (frame message to stream post) | 148 | 91 |
| p95 / p99 / max | 9.80 / 11.64 / 40.95 ms | 9.45 / 10.93 / 33.51 ms |
| game ticks later than one frame | 3 of 3,671 | 3 of 3,679 |

What is left in the slow frames is mostly the game's own code, and waiting in `xc_bus_send()` until the SNES has
read the previous part of the stream (the RP2040 firmware also has one part in flight at a time).

Not kept: stopping the mixer while a SNES message is waiting (`RX_LEVEL`). The SNES has bytes waiting most of
the time, so the mixer kept stopping, the BRR rings stayed less than half full and nothing got faster. Also not
kept: mixing only while the rings are less than a quarter full between the SNES's frame message and the stream
post. The mixer then ran a quarter as long inside those windows, but they got no shorter (p95 9.44 ms): it had
been filling time spent waiting for the SNES. The encoder's fast mode was needed twice as often.
