# xc_soc – Xeno Crisis soft CPU support

Xeno Crisis ships on a SNES cartridge with an RP2040 coprocessor. The sd2snes cores (`sd2snes_xc`, `sd2snes_xc_msu`
on FXPAK Pro / mk3 at about 40 MHz, `sd2snes_xc_mk2` on mk2 at 20 MHz) replace the RP2040 with a soft Cortex-M0
that runs the game's own firmware (the flash dump `xenocrisis_rp2040.bin`) from the PSRAM.

That CPU has no RP2040 boot ROM, no second core and none of the PIO/DMA peripherals. The code in this folder fills
those gaps. It is built into one file, **`xc_soc.bin`**, which contains no game code or data.

## Where it goes

Copy `xc_soc.bin` to `/sd2snes/` next to the firmware and the Xeno Crisis cores; mk2 and mk3 use the same file.
When the game starts, the MCU (`src/xc_load.c`) loads the SNES ROM, `xenocrisis_rp2040.bin` and `xc_soc.bin` into
the PSRAM, applies the patch tables (below) and starts the soft CPU.

**`xc_soc.bin` must come from the same build as the firmware** (the build writes it to `src/obj-<config>/` next
to the firmware image). The loader refuses a mismatched file; `xc_debug.txt` says why. All firmware addresses here
belong to the **Xeno Crisis SNES v1.00** RP2040 firmware; the loader refuses other builds.

## What is in it

| Part | Source | Runs at | Purpose |
|---|---|---|---|
| Replacement bootrom | `xc_bootrom.c`, `xc_bootrom_memcpy.S`, `xc_bootrom_tables.S`, `xc_bootrom_flags.S`, `xc_bootrom.ld` | `0x00000000` | The boot ROM functions the pico-sdk looks up: tables, bit operations, memset/memcpy, soft float/double (on libgcc). Functions never used in play (sqrt, trig, exp/log) stop with a panic code. |
| Mixer | `xc_mix.c`, `xc_mix_entry.S`, `xc_mix.ld` | `0x10F00000` (free flash), data and stack in `SCRATCH_X` | Does core 1's work. mk3: a 1 kHz tick and a "packet decoded" interrupt; the MCU decodes the Opus music, `xc_brr` encodes BRR; on the MSU-1 core the music commands go to the MSU-1. mk2: no interrupts, see "mk2" below. |
| Function replacements | `xc_shim.c` | `0x10F00000` region | Firmware functions that need RP2040 hardware: the SNES bus layer (→ `$3000` window), `sleep_until`, `puts`/`printf` (→ debug port), `panic`, flash write/erase (→ save area in the cartridge SRAM, saved as `.srm`). |
| Patch tables | `xc_fw_header.c` | `0x10F00000` | Main table ("MXCX" v2): the firmware addresses to redirect (`multicore_launch_core1` → `xc_mix_install`, clock/stdio setup → "return 0", ...). Then the mk2 table ("MK2P", up to 64 entries), applied only by the mk2 firmware. |
| mk2 only | `xc_div.S`, `xc_mix_voice.S`, `xc_brr_sw.S`, `xc_brr_sw.h`, `xc_emit.S` | `0x10F00000` region | Software division (no SIO divider on mk2; same r0–r3 as the originals, including division by zero), mixing and BRR encoding in assembly, the faster 65816 code emitter. |
| Register map | `xc_soc.h` | – | SoC registers: BRR encoder, decode mailbox / MSU-1 control, tick timer, debug port, `$3000` window, IRQs. |

Patch kinds: 0 = veneer at the function entry to the replacement, 1 = new target for an existing veneer, 2 = "return
0", 3 = write a word (code patches; mk2 table only).

## File layout of `xc_soc.bin`

| Offset | Size | Contents | Loaded to (PSRAM) |
|---|---|---|---|
| `0x0000` | 512 bytes | `"XSOC"`, version 1, bootrom length, additions length (LE words), then `0xFF` | – |
| `0x0200` | 16 KB | bootrom, padded with `0xFF` | `0xD20000` (soft CPU `0x00000000`) |
| `0x4200` | 16 KB | firmware additions, padded with `0xFF` | `0xD24000` (RP2040 flash `0x10F00000`) |

## Building

`make` in `src/` builds `xc_soc.bin` with the firmware. On its own: `make` (→ `./xc_soc.bin`, plus `xc_fw.bin`,
`xc_bootrom.bin`), `make OUT=dir`, `make clean`. Needs only `arm-none-eabi-gcc` (`-mcpu=cortex-m0plus`). The build
fails if either part is over 16 KB.

## Other files

- `test_mix_math.c`: the mixer's division-free rounding against the firmware's, every input
  (`cc -O2 test_mix_math.c && ./a.out`).
- `test_brr_sw.c`: the software BRR encoder against the firmware's (`cc -O2 test_brr_sw.c -lm && ./a.out
  [blocks.bin ...]`; without files 2 million random blocks; MesenCE writes block files with `XC_BRRDUMP=file`).
- `test_brr_sw_asm.py`, `test_mix_voice_asm.py`: the assembly against the C versions in Unicorn (`pip install unicorn`).
- `xc_patch_image.py`, `xc_build_image.py`: apply the patches to a flash dump offline (`--mk2` for the mk2 table),
  for debugging or comparing with an emulator.

## mk2

The mk2 core runs the soft CPU at 20 MHz, has no tick timer, interrupts or `xc_brr` encoder, and its cache is
write-through: **every store, including every register pushed on the stack, is a write to the 8-bit SRAM chip.**
So the hot code avoids stores.

**Mixer.** The mk2 table starts it with `xc_mix_install_mk2`. The firmware's wait loops call `xc_mix_poll()`
(`xc_mix_entry.S`), which checks without a store whether a tick is due or the left BRR ring has room; only then does
it switch to the mixer's stack and run the due ticks and two blocks (eight, with the encoder's fast mode, while the
rings are less than half full). The mixer only runs inside core 0's calls, so core 1 counts as always parked.

- Sound effects have the same volume left and right, so one channel is mixed (two 16-bit samples per word),
  encoded once and written to both rings; different volumes fall back to a stereo path in C.
- BRR encoding (`xc_brr_sw.*`): instead of all 11 shifts, the smallest shift without clipping (s0) and s0 - 1,
  with the firmware's nibble rule and error sum (s0 - 1 skipped when a lower bound of its error is already too
  high). On 178,720 blocks of the game's sound effects 99.9% are identical to the firmware's, the rest have the
  same error. Fast mode (s0 only) gives ~1 dB more noise on about 10% of the blocks.

**Speed-ups.** Slow frames make the game slow down and can make the SNES still update the screen when it starts
drawing (flicker at the top). Profiled in the RTL simulation, fixed in software, all with the same results as the
originals (unit tests against the firmware's functions in an ARM emulator, screenshots in MesenCE):

- **65816 code emitter** (`xc_emit.S`): the firmware builds the code it streams to the SNES byte by byte through
  nested functions that push registers (about 14 stores for a two-byte instruction). The mk2 table redirects
  `emit8`, `emit16` and the opcode helpers (LDA #, LDX #, STA dp, STA abs, STX abs, STZ abs) to leaf functions,
  entered through veneers without a store (`ldr r3, =fn; bx r3`), and turns seven one-line wrappers into tail
  calls without a push.
- **`memcpy`** (`xc_bootrom_memcpy.S`, in the bootrom, so mk3 gets it too): word stores also between buffers of
  different alignment, and no stack stores (the `-Os` C version kept its values on the stack).

RTL simulation of the mk2 core, 60 s of play, full sound:

| | no speed-ups | now |
|---|---|---|
| frame message → stream post, p95 / p99 / max | 11.1 / 13.5 / 55.9 ms | 9.5 / 10.9 / 33.5 ms |
| game ticks later than one frame | 10 of 3,616 | 3 of 3,679 |
| mixer | | 1,489 blocks/s (the game needs ~1,490), 22% of the CPU, left BRR ring empty in 4 of 59,895 ms |

What is left in slow frames is mostly the game's own code, and waiting in `xc_bus_send()` for the SNES to read the
previous part of the stream (the RP2040 firmware also keeps one part in flight at a time).

Tried and not kept: pausing the mixer while a SNES message is waiting (the SNES nearly always has bytes waiting,
so the rings ran low), and mixing less while a frame is being built (the windows got no shorter: the mixer had been
using time spent waiting for the SNES).
