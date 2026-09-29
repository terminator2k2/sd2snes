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
| Audio mixer | `xc_mix.c`, `xc_mix_entry.S`, `xc_mix.ld` | `0x10F00000` (free flash space), data and stack in `SCRATCH_X` | On the cartridge, core 1 decodes the Opus music and mixes it with the sound effects. The soft CPU has no second core, so this work runs as two interrupt handlers instead: a 1 kHz tick and a "packet decoded" interrupt. The MCU decodes the Opus packets, which it receives through a mailbox. The `xc_brr` hardware block does the BRR encoding. On the MSU-1 core, the mixer sends the game's music commands to the MSU-1 instead, and only mixes the sound effects. |
| Function replacements | `xc_shim.c` | `0x10F00000` region | Replacements for firmware functions that depend on RP2040 hardware: the SNES bus layer (PIO + DMA → the `$3000` window FIFOs), `sleep_until`, `puts`/`printf` (→ debug port), `panic`, and the flash write/erase functions (→ the save area, which lives in the cartridge SRAM and is saved as the `.srm` file). |
| Patch table | `xc_fw_header.c` | `0x10F00000` | The header ("MXCX", version 2) with the list of firmware addresses to redirect. `multicore_launch_core1` becomes `xc_mix_install`, which sets up the mixer. Clock and stdio setup become "return 0". |
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
- `xc_patch_image.py`, `xc_build_image.py`: offline tools that apply the same patches to a flash dump and build
  a complete prebuilt image. The firmware does this itself at load time now, so these are only needed for
  debugging or for comparing against an emulator (for example MesenCE).
