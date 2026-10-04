# Xeno Crisis on sd2snes mk3: `sd2snes_xc_mk3`

A soft Cortex-M0 in the FPGA runs the cartridge's RP2040 firmware on the sd2snes mk3 (FXPAK Pro). One bitstream,
`fpga_xc_mk3.bi3`, plays the music either from the game's Opus streams (decoded by the MCU) or from an MSU-1 pack;
the firmware chooses when the game loads. The mk2 port is in [`../sd2snes_xc_mk2`](../sd2snes_xc_mk2/README.md).

**Status: runs on hardware** (FXPAK Pro, STM32 firmware), with Opus music and with an MSU-1 pack; saves work. Fits and meets
timing in Quartus 25.1 (94% of the logic, 51 of 56 M9K; soft CPU 40.25 MHz +1.19 ns, CLK2 85.87 MHz +1.11 ns).

**Music:** with `<rom>.msu` next to the ROM, from the MSU-1 pack ([`MSU1_PACK.md`](MSU1_PACK.md)). Otherwise the
STM32F401 firmware (`firmware.stm`) decodes the Opus music; the LPC1756 firmware (`firmware.im3`) has no Opus decoder
and plays the sound effects only.

## Setup

1. `make` here (Quartus project `sd2snes_xc_mk3.qpf`, self-contained) builds `fpga_xc_mk3.bi3`.
2. `make CONFIG=config-mk3-stm32` / `config-mk3` builds the firmware and **`xc_soc.bin`**; both go to `/sd2snes/`
   and **must be from the same build**.
3. Put the RP2040 flash dump in `/sd2snes/xenocrisis_rp2040.bin` (16 MB) and load the SNES ROM (`XENOCRISIS`, 128 KB,
   CRC32 `FE5B38F0`). Without a `.srm`, the cartridge's saves carry over from the dump. `/sd2snes/xc_debug.txt` has
   the load results and statistics.

## Design

The FPGA has two clock domains. The sd2snes side runs at 85.87 MHz (CLK2) and talks to the SNES, the MCU and the
memory chips. The soft CPU side runs at 40.25 MHz and holds the RP2040 replacement. Everything between the two goes
through one bridge.

```
         sd2snes side (CLK2, 85.87 MHz)                    soft CPU side (40.25 MHz)

 SNES  <--> $3000 window (xc_window) --+
 PSRAM <--> ROM state machine ---------+
 SRAM  <--> RAM state machine ---------+-- xc_bridge --> xc_soc: Cortex-M0 (xc_m0),
 MCU   <--> mcu_cmd.v <--> Opus mailbox/MSU-1 regs --+       16 KB I-cache, 16 KB D-cache,
 audio <--  msu.v + xc_dac                                   timer, SIO, NVIC, BRR encoder
```

### How a frame gets to the SNES

1. The soft CPU runs the game's RP2040 firmware from the PSRAM (code) and the SRAM chip (RAM).
2. It builds 65816 code for the SNES in its RAM and posts it to the `$3000` window as descriptors (RAM address and
   length; up to 8 queued).
3. The window's DMA copies the bytes into a 512-byte ring; the SNES reads and runs them from `$3000`.
4. The SNES writes its input and frame messages back through the window's RX FIFO.

### Parts

| Part | What it does |
|---|---|
| `xc_m0`, `xc_soc` | Cortex-M0 with the RP2040 peripherals the firmware uses: timer, SIO (spinlocks, divider), NVIC (IRQ 26 mixer tick, IRQ 27 decode done), BRR encoder, APB register shadow. A panic or fault halts it and the MCU logs the code. |
| caches | 16 KB I-cache and 16 KB write-back D-cache, both 2-way; hits have no wait states |
| `xc_bridge` | the only path between the clock domains, so the soft CPU clock can be changed freely |
| memory | PSRAM shared with the SNES (free-slot scheme); the SRAM chip belongs to the soft CPU (32-byte bursts; the window DMA goes first) |
| music | Opus mailbox (`xc_decbox`) and MSU-1 registers (`xc_msubox`) side by side; `CTRL` bit 3 tells the mixer which one (the MCU sets it with `$C6`) |
| MSU-1 | `msu.v` driven only by the soft CPU (the SNES doesn't see it), no data port; `xc_dac.v` with linear interpolation |
| start | held in reset with the SNES and until the MCU sends `$C6 XC_RUN` |

Left out for space: cheats and in-game hooks (a long reset returns to the menu, the button combination doesn't),
save states.

### Clock

The soft CPU clock is 40.25 MHz (PLL: 8 MHz × 161/32). The timer and mixer tick get it as `SOC_CLK_NUM/DEN` = 161/4,
so time stays exact. If timing ever fails, use 37.88 MHz: PLL `clk1` divide by 34, `SOC_CLK_NUM/DEN` = 644/17, and
the `clk[1]` line in `main.sdc`.

### Memory maps

PSRAM (16 MB, built by the MCU when the game loads):

| Address | Contents |
|---|---|
| `0x000000-0x01FFFF` | SNES ROM (128 KB) |
| `0x020000-0xCFFFFF` | RP2040 flash `0x020000-0xCFFFFF` |
| `0xD00000-0xD1FFFF` | RP2040 flash `0x000000-0x01FFFF` |
| `0xD20000-0xD23FFF` | replacement bootrom (soft CPU address 0) |
| `0xD24000-0xD27FFF` | firmware additions (RP2040 flash `0xF00000`) |

SRAM chip (512 KB):

| Address | Contents |
|---|---|
| `0x00000-0x07FFF` | save area (the `.srm`, 32 KB) |
| `0x08000-0x49FFF` | RP2040 RAM (264 KB) |
| `0x4A000-0x4AFFF` | RP2040 USB RAM |
| `0x4C000-0x4DFFF` | APB register shadow |

## Firmware

- **MSU-1 mode** (`src/xc_soc/xc_mix.c`): the game's music logic runs unchanged; each track start becomes an MSU-1
  request (repeat for looping tracks, intro then loop part, pause/resume, stop on reset). The MCU runs
  `msu1_loop()`, and checks and saves the save RAM every second even during music.
- **Opus mode:** the mixer posts one 20 ms packet at a time; the MCU decodes it (about 7 ms on the STM32F401) with
  `libopus_xc.a`, built from the vendored Opus 1.3.1 (decoder only, bit-exact). Long MCU jobs serve the decoder in
  between; SPI transfers are byte by byte (the block functions hang with the FPGA).

| Command | Function |
|---|---|
| `$C0`–`$C4` | Opus mailbox: status, read packet, write PCM, done (raises IRQ 27), acknowledge reset |
| `$C5` XC_STATUS | running/halted, halt code and address |
| `$C6` XC_RUN | bit 0 release the soft CPU, bit 1 MSU-1 music |
| `$C7` / `$C8` | performance counter snapshot / read |

## Verification

- **RTL-in-the-loop:** MesenCE runs the SNES, Verilated `xc_top` the RP2040 side; every read and DMA byte checked
  against a reference memory (3,600 frames, 0 mismatches). The combined core gives the same results as the former
  separate cores in both modes.
- **Units:** `xc_m0` lockstep with the MesenCE interpreter, divider (2 million divisions), `xc_brr` (bit-exact),
  `$3000` window (recorded traffic, random latency), SRAM bursts, MCU ↔ FPGA link (500 packets bit-exact),
  MSU-1 path (`tb_msu.v`, test-tone pack in MesenCE).

## Open points (hardware)

1. LPC1756 firmware, with and without a pack.
2. Reset to menu and long reset.
