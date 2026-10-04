# Xeno Crisis on sd2snes mk3: `sd2snes_xc_mk3`

A soft Cortex-M0 in the FPGA runs the cartridge's RP2040 firmware on the sd2snes mk3 (FXPAK Pro). One bitstream,
`fpga_xc_mk3.bi3`, plays the music either from the game's Opus streams (decoded by the MCU) or from an MSU-1 pack;
the firmware chooses when the game loads. The mk2 port is in [`../sd2snes_xc_mk2`](../sd2snes_xc_mk2/README.md).

**Status:** fits and meets timing in Quartus 25.1 (94% of the logic, 51 of 56 M9K; soft CPU 40.25 MHz +1.19 ns,
CLK2 85.87 MHz +1.11 ns). The separate Opus and MSU-1 cores it combines ran at full speed on hardware; this core
still has to be tried there.

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

- **Clocks:** soft CPU 40.25 MHz (PLL 8 MHz × 161/32); timer and mixer tick use `SOC_CLK_NUM/DEN` = 161/4. All
  crossings go through `xc_bridge`, so the SoC clock can be changed freely (fallback 37.88 MHz: PLL `clk1` /34,
  `SOC_CLK_NUM/DEN` = 644/17, `main.sdc`).
- **Memory:** PSRAM through the free-slot scheme; the SRAM chip belongs to the SoC (32-byte bursts, 8 CLK2 cycles per
  byte; the window DMA has priority).
- **SoC:** 16 KB I-cache and 16 KB write-back D-cache (2-way); timer, SIO (spinlocks, divider), NVIC (IRQ 26 tick,
  27 decode done), BRR encoder, APB register shadow; a panic or fault halts the core and the MCU logs it. Held in
  reset with the SNES and until `$C6 XC_RUN`.
- **Window:** 8 descriptors (RAM address + length, or one byte), DMA into a 512-byte ring the SNES reads.
- **Music source:** the Opus mailbox (`xc_decbox`) and the MSU-1 registers (`xc_msubox`) share one address range;
  `CTRL` bit 3 is the MCU's choice, read once by the mixer at start.
- **MSU-1:** written only by the soft CPU (the SNES doesn't see it), no data port; `xc_dac.v` is `dac.v` with linear
  interpolation instead of the CIC.
- Left out: cheats and in-game hooks (a long reset returns to the menu, the button combination doesn't), save states.

| PSRAM | Contents | SRAM chip | Contents |
|---|---|---|---|
| `0x000000-0x01FFFF` | SNES ROM | `0x00000-0x07FFF` | save area (`.srm`) |
| `0x020000-0xCFFFFF` | RP2040 flash `0x020000-` | `0x08000-0x49FFF` | RP2040 RAM |
| `0xD00000-0xD1FFFF` | RP2040 flash `0x000000-` | `0x4A000-0x4AFFF` | USB RAM |
| `0xD20000-0xD23FFF` | replacement bootrom | `0x4C000-0x4DFFF` | APB register shadow |
| `0xD24000-0xD27FFF` | firmware additions (`0xF00000`) | | |

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

1. This core, with and without an MSU-1 pack.
2. Saves: `.srm` after the first save; cartridge saves carried over.
3. LPC1756 firmware, with and without a pack.
4. Reset to menu and long reset.
