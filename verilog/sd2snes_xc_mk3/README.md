# Xeno Crisis on sd2snes: combined core (`sd2snes_xc_mk3`, experimental)

One bitstream, `fpga_xc_mk3.bi3`, with both music sources of the other two cores: the Opus decode mailbox of
[`../sd2snes_xc`](../sd2snes_xc/README.md) and the MSU-1 of [`../sd2snes_xc_msu`](../sd2snes_xc_msu/README.md).
The firmware picks the source when the game loads: MSU-1 if `<rom>.msu` is next to the ROM, else Opus.

**State: fits and meets timing in Quartus (25.1); not yet tried on hardware.** 14,432 of 15,408 logic elements
(94%; the Opus core 91%), 51 of 56 M9K, 18 multipliers. Slow 85C setup slack: `clk[1]` (soft CPU, 40.25 MHz)
+1.191 ns (Fmax 42.28 MHz), `clk[0]` (CLK2, 85.87 MHz) +1.111 ns; hold, recovery/removal and pulse width all
positive, no critical warnings.

## How it works

- **Project:** self-contained for testing: copies of all sources (the Opus core's from `../sd2snes_xc`, including
  `ip/mk3` and `config.vh`, and `msu.v`, `xc_dac.v`, `xc_msubox.v` from `../sd2snes_xc_msu`), so the folder builds
  on its own. Keep the copies in step with the originals (or switch back to references once it is settled).
  The PLL is `xc_mk3_pll.v` (a renamed copy of `ip/mk3/pll.v`, listed as a plain Verilog file: through the
  `.qip`, Quartus picked up a PLL without the soft CPU's `c1` output). `main.qsf` is the MSU-1 core's with
  `XC_MK3` defined as well and `xc_decbox.v` added. `make` builds
  `fpga_xc_mk3.bi3`.
- **`xc_top` (`MSU = 2`):** the decode mailbox and `xc_msubox` share the soft CPU address range (the mailbox does not
  use `0x010`/`0x014`). `CTRL` bit 3 reads the MCU's choice; the mixer reads it once at start and runs in Opus or
  MSU-1 mode exactly as in the other cores (`src/xc_soc` unchanged).
- **MCU:** `$C6 XC_RUN` bit 1 = MSU-1 music (the other cores ignore the bit). `xc_select_core()` (`src/xc_load.c`)
  takes `fpga_xc_mk3.bi3` whenever it is on the card; without it, the choice between `fpga_xc_msu` and `fpga_xc`
  is as before. With MSU-1 music the MCU runs `msu1_loop()` as with the MSU-1 core, otherwise the Opus service.

## Checks

- iverilog elaborates all three cores (Opus, MSU-1, combined) cleanly.
- RTL-in-the-loop, 900 frames each: the combined `xc_top` in Opus mode gives the same results as the Opus core (595
  decode jobs, game ticks, latencies, stream), and in MSU-1 mode the same as the MSU-1 core (9 MSU-1 register
  writes, no decode jobs); all reads and DMA bytes checked against the reference memory, 0 mismatches.
- Firmware: `config-mk3-stm32` and `config-mk3` build (`firmware.stm` 206,756 bytes).

## Use

Copy `fpga_xc_mk3.bi3` to `/sd2snes/` with the firmware of the same build. To go back to the two separate cores,
delete it from the card. It is not part of the release build (`MK3CORES` in the top-level `Makefile`) yet.
