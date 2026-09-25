# Xeno Crisis on sd2snes: the `sd2snes_xc` core (step 4)

This step turns the pieces from the earlier steps into a complete sd2snes mk3 (FXPAK Pro) implementation. The pieces were the soft CPU, the `$3000` window, the audio split and the no-native-code firmware.

The implementation has four parts:
- an FPGA core, `verilog/sd2snes_xc`, derived from `sd2snes_gsu`;
- the MCU firmware changes;
- an image builder that makes the single file the sd2snes loads;
- an RTL-in-the-loop test, in which MesenCE runs the whole game on the Verilated FPGA design.

Status: everything is simulated and checked except what needs Quartus or hardware. That means the fit, timing closure at 40 MHz, and the first run on a real FXPAK Pro.

## Overview

```
                      sd2snes FPGA (CLK2, 85.9 MHz)                          | clk_soc (40 MHz)
 SNES bus --> address.v --> $3000 window: xc_window                           |
              (LoROM kernel)     descriptor queue -> DMA -> 512 B ring --> SNES|
                                 RX FIFO <-- SNES writes                       |
 PSRAM  <-- ROM FSM (main.v) <-- xc_bridge executor <== toggle handshake ===> xc_soc
 SRAM   <-- RAM FSM (main.v) <-- SRAM arbiter (DMA first, per byte)           |   xc_m0 + I$ 4 KB + D$ 8 KB
 MCU    <-> mcu_cmd.v ($C0-$C6) <-> xc_decbox (Opus mailbox) <== bridge ===>   |   timer, SIO, NVIC, BRR, tick
```

- **Clock domains.** The soft CPU runs in its own clock domain, 40 MHz from a second PLL output (8 MHz × 5). The sd2snes side (`CLK2`) keeps the GSU core's 85.9 MHz.
- **The crossing.** Everything crosses through `xc_bridge`. It carries one operation at a time: a cache line, a register access or a single uncached access. The request and completion are toggles through two-flop synchronizers, and the data sits in two small dual-clock RAMs. The SoC clock can therefore be changed freely (`SOC_MHZ` and the PLL's `clk1_multiply_by`).
- **Memory buses.** The ROM bus (PSRAM) and RAM bus (SRAM chip) requests use the ports and state machines of the GSU core.
  - The PSRAM is shared with the SNES through the existing free-slot scheme: one access per SNES cycle, when the SNES isn't reading ROM.
  - The SNES never touches the SRAM chip in this core, so the SRAM bus is all ours: 7 cycles (≈80 ns) per byte.

## Memory

### PSRAM (16 MB): the image the MCU loads

| PSRAM / file offset | Contents | Used by |
|---|---|---|
| `0x000000-0x01FFFF` | SNES kernel ROM (128 KB) | SNES, LoROM (`address.v` masks to 128 KB) |
| `0x020000-0xCFFFFF` | RP2040 flash `0x020000-0xCFFFFF` | soft CPU (flash offset = PSRAM address) |
| `0xD00000-0xD1FFFF` | RP2040 flash `0x000000-0x01FFFF` | soft CPU |
| `0xD20000-0xD23FFF` | replacement bootrom (`xc_bootrom.bin`) | soft CPU, address 0 |
| `0xD24000-0xD27FFF` | RP2040 flash `0xF00000-0xF03FFF` (firmware additions) | soft CPU |

- `socfw/xc_build_image.py` builds this 13.8 MB file from the kernel dump and the RP2040 flash dump. It applies the SoC patches as `xc_patch_image.py` does.
- The layout keeps clear of the PSRAM areas the MCU uses while a game runs: 0xE00000 and up (menu, save states, SPC dumps).
- The cheat area at 0xD00000 is used. The MCU skips cheats and save states for this cartridge; the core has no cheat engine anyway.

### SRAM chip (512 KB)

| Address | Contents |
|---|---|
| `0x00000-0x07FFF` | RP2040 flash save area (`0xFF8000-0xFFFFFF`): the game's saves. The MCU loads it from and writes it to the `.srm` (32 KB) with its normal save RAM code. |
| `0x08000-0x49FFF` | RP2040 RAM (264 KB) |
| `0x4A000-0x4AFFF` | RP2040 USB RAM |
| `0x4C000-0x4DFFF` | register shadow for the boot-time APB setup (clocks, resets, PLLs, pads) |

## The SoC (`xc_soc.v`)

### Caches

- **I-cache:** 4 KB, 2-way, 32-byte lines. It caches flash and bootrom. Code fetched from RAM goes through the D-cache instead.
- **D-cache:** 8 KB, 2-way, write-back. It caches RAM, flash and bootrom.
- **Hits** answer in the same cycle: the cache RAMs are addressed with `bus_next_addr`, so there are no wait states.
- **Stores:** after a store, the following D-cache access waits one cycle (read-during-write).
- **Aliases:** the flash aliases (`0x10`–`0x13`) and the RAM alias (`0x21`) fold into one cache key.
- **Coherence with the window DMA:** a write to `TX_LEN` first writes back the dirty D-cache lines of `[TX_ADDR, TX_ADDR + length)`. Posts longer than 4 KB write back the whole cache. Then the descriptor goes to the window.
- **Uncached:** the save area, USB RAM and the register shadow.

### Peripherals

| Peripheral | Implementation |
|---|---|
| Timer (`0x40054000`) | 64-bit microsecond counter: RAW and latched reads. Alarms are not implemented and halt the core if armed; SoC mode never arms them. |
| SIO (`0xD0000000`) | CPUID 0 and the spinlocks. The divider is radix-2 (32 cycles); a read of the quotient or remainder waits until it is ready, with the same results as MesenCE and the RP2040 (division by zero, `INT_MIN / -1`). Interpolator accesses halt the core. |
| NVIC / VTOR | 32-bit enable and pending registers. The lowest pending and enabled IRQ is taken first, as in MesenCE. IRQ 26 is the tick; IRQ 27 is decode done, synchronized from CLK2. |
| BRR encoder, tick | `xc_brr.v`, `xc_tick.v`, both in the SoC clock domain |
| Debug and panic (`0x50802010/14`) | A panic, core fault or bus fault halts the core. The MCU can read the halt code and address (`$C5`) and prints them on its UART. |
| APB (`0x40000000-0x400FFFFF`) | A register shadow in SRAM with the RP2040's atomic aliases (XOR, set, clear). `RESET_DONE`, XOSC and ROSC status, watchdog reason and TBMAN are fixed values. The PLL `LOCK` bit and the clock `CLK_x_SELECTED` registers are derived from the stored control registers, exactly as MesenCE does it. |

### Start-up

1. Invalidate both caches.
2. Clear SRAM `0x08000-0x4DFFF`, so RAM starts as it does in MesenCE (about 30 ms).
3. Read SP and PC from the flash vector table at `0x10000100`, where boot2 leaves the RP2040, and set VTOR to that address.
4. Release the core.

The SoC is held in reset while the SNES is in reset (`SNES_DEADr`, like the cartridge's RP2040), and until the MCU sends `$C6 XC_RUN`.

### `$3000` window (`xc_window.v`)

- Descriptors are 8 deep, `{RAM address, length ≤ 64 KB}` or one immediate byte.
- A DMA reader on the SRAM chip fills the 512-byte ring (`xc_stream`), which the SNES reads.
- An SRAM arbiter gives the DMA priority over the SoC, one byte at a time.
- The register semantics are those of MesenCE's SoC mode (`socfw/xc_soc.h`).

## MCU (sd2snes `src/`)

- **Detection** (`smc.c`): map `$30`, chipset `$63`, maker `BM`, game `XCRI`. It sets `FPGA_XC` (`/sd2snes/fpga_xc.bi3`) and 32 KB of save RAM. mk3 (STM32) only.
- **Loading** (`memory.c`):
  - the image loads as a normal ROM;
  - the `.srm` loads to the SRAM chip, which is filled with `0xFF` (erased flash) when there is no `.srm`;
  - no cheats or save states;
  - `xc_run(1)` releases the soft CPU just before the SNES leaves reset.
- **Main loop** (`main.c`): `xc_audio_poll()` provides the Opus decode service (`xc_audio.c`) and a halt report on the UART.
- **Opus library:** `xc_opus/build.sh <opus-1.3.1 source>` builds `libopus_xc.a`. The settings are exact (see the script). **Built with the sd2snes MCU flags and run on a Cortex-M4 instruction-level model, it decodes all 480,000 samples bit-exact** (checksum `0xdb88f8e0`, the same as the host decoder that matches the firmware).
- **Size, with the real mini bitstream** (`fpga_mini.bi3`, 56,939 bytes, embedded by the build):
  - **`firmware.stm` is 208,300 bytes: a 207,788-byte image plus the 512-byte header, against 212,480 + 512.** That leaves 4,692 bytes free.
  - Two changes were needed to fit:
    - **`stm32f401.ld`:** the `.ahbram` buffers (8 KB sort buffer, MSU-1) became `NOLOAD`. On the STM32 nothing initializes them from flash, but their 8,992 zero bytes were stored in the image. The RAM layout is unchanged. Stock 1.11.2 shrinks by the same 8,992 bytes (153,936 → 144,944).
    - **`xc_opus/build.sh`:** `-Os`, and `SMALL_FOOTPRINT` for `cwrs.c` only (computes the PVQ codeword counts instead of a 5 KB table). Still bit-exact: checksum `0xdb88f8e0` on the host and on the Cortex-M4 model.
  - The linker script also gained an `ASSERT`: before, the `.data` and `.ahbram` load bytes were not checked against the flash region, so an oversized firmware linked without an error. With `-O2` Opus the image would have been about 20 KB too large; now that fails to link.
- **MCU time for the Opus decoder:** about 33 M cycles/s (39% of 84 MHz, instruction-level Cortex-M4 model, before flash wait states). That is +27% over `-O2` with the table (26.0 M); −Os accounts for 18% and the computed `cwrs` for 8%.

FPGA commands (`mcu_cmd.v`):

| Command | Function |
|---|---|
| `$C0` XCA_STATUS | read: null, {reset, job}, length (2 bytes LE) |
| `$C1` XCA_READPKT | read: null, packet bytes |
| `$C2` XCA_WRITEPCM | write: 1,920 PCM bytes |
| `$C3` XCA_DONE | write: ret (4 LE), final range (4 LE), flop byte; raises IRQ 27 |
| `$C4` XCA_ACKRESET | clear the decoder reset request |
| `$C5` XC_STATUS | read: null, {running, halted}, halt code (4 LE), halt address (4 LE) |
| `$C6` XC_RUN | write: 1 = release the soft CPU, 0 = hold it |

## Building and using it

1. **FPGA:** `verilog/sd2snes_xc` is a Quartus project (`sd2snes_xc.qpf`, EP4CE15F17C8) like the other mk3 cores. `make` in that folder produces `fpga_xc.bi3`; copy it to `/sd2snes/` on the SD card.
2. **MCU:** build the Opus library (`src/xc_opus/build.sh <opus-1.3.1>`), then the firmware as usual (`make CONFIG=config-mk3-stm32`).
3. **Game image:** in `socfw/`, run `build.sh`, then:

       xc_build_image.py XENOCRIS.sfc xenocrisis_rp2040.bin "Xeno Crisis.sfc" --srm "Xeno Crisis.srm"

   Put both files on the SD card. The `.srm` holds the saves from the cartridge's flash; without it the game starts with an empty save.

### Features left out of this core

Leaving these out saves about 2,600 LEs and 20 M9K blocks. The first two can be switched back on in `main.v`.
- **MSU-1 and the DAC** (`XC_WITH_MSU`).
- **Cheats and in-game hooks** (`XC_WITH_CHEAT`). The reset-to-menu button combination therefore doesn't work; a long reset still returns to the menu.
- **Save states.**

## Verification

| What | How | Result |
|---|---|---|
| `$3000` window with DMA | `tb_xc_window.v`: directed tests, then 600 frames of recorded traffic. Each recorded group is posted as a descriptor from an SRAM model with random latency (2–13 cycles). | **543,562 SNES reads and 6,312 writes checked, 1,144 descriptors, 0 errors, 0 underruns.** Planted bugs are all caught: DMA address step, in-flight byte kept after a flush, pending count without the queue, no ring headroom. With 2–41 cycle latency the ring runs dry and reads fail, which is why the DMA gets the SRAM first. |
| Divider | Verilator, 2,000,000 random and edge-case divisions, signed and unsigned | 0 wrong |
| **Whole game on the RTL** | `runner_rtl` (`XC_RTL=1`): MesenCE runs the SNES and the Verilated `xc_top` replaces the RP2040. It has models of the PSRAM (free-slot wait), the SRAM chip, the SNES window strobes and the MCU decode service. Two checkers run the whole time: every core read of RAM, flash, bootrom or save is compared with a flat reference memory, and every byte the window DMA reads is compared with what the core wrote. 3,600 frames (60 s): boot, title, menus, gameplay. | **394,022,873 core reads and 38,292,028 writes, 0 mismatches; 3,334,741 DMA bytes, 0 mismatches.** 7,073 descriptors, 2,786 decode jobs, 3.33 MB streamed. Screenshots are identical to MesenCE SoC mode up to frame 150. After that, gameplay timing differs (40 MHz soft CPU vs the emulated 133 MHz RP2040, as with the sizing model), and the game plays normally (see the montage). Music correlates at 1.000 with SoC mode, shifted by 16–24 ms. |
| …the checks are sharp | Bugs the RTL-in-the-loop run found while bringing the SoC up | The exception number was off by 16; the reset vector was taken one cycle too early; `TX_ADDR` never reached the window; the clean loop compared tags one cycle before they were read (the DMA checker caught the stale data). |
| **Timing changes** (see "Timing") | `xc_m0`: random-program ISA lockstep, 2 × 3,000 programs; and the full-firmware lockstep in SoC mode (`runner_cosim`, 300 frames). `xc_brr`: `tb_brr` (40,000 game blocks + 1,000,000 random). `xc_window`: `tb_xc_window` 600-frame replay. Whole game on the RTL, 3,600 frames, against the original RTL run with the same harness. | **ISA: 2.83 M instructions, 52,208 interrupt entries, 0 mismatches. Firmware: 388,116,519 instructions, 5,067 interrupt entries, 0 mismatches. BRR: 0 mismatches (180 cycles/block). Window: 0 errors, 0 underruns.** Whole game: 371,879,820 core reads / 38,291,537 writes and 3,336,551 DMA bytes, 0 mismatches. Game ticks 60.55/s vs 60.59/s. Frame message → stream post p50/p95/p99/max: 7.61/11.51/14.86/37.48 ms vs 7.56/11.47/15.20/37.31 ms. Audio correlation with the original RTL: median 0.9992, lag 0. Screenshots are identical to the original RTL through frame 1,680 (well into gameplay). After that, small timing differences change positions, and the game plays normally. (A rerun of the *original* RTL also differs from its first run from frame 1,620, so screenshots in gameplay aren't a sharp test; the checkers and latency are.) |
| Image builder | The RTL runs from the file `xc_build_image.py` produced (`XC_RTL_IMAGE`) | Same results and screenshots as the RTL's own layout |
| MCU firmware | `make CONFIG=config-mk3-stm32` with the changes, the Opus library (`-Os`, small-footprint `cwrs.c`) and the real `fpga_mini.bi3` (56,939 bytes) | **Builds and links: `firmware.stm` 208,300 bytes (limit 212,992 with header).** The embedded bitstream is byte-identical to the file. With `-O2` Opus the link stops with "firmware image does not fit in flash". Opus decoder output: checksum `0xdb88f8e0`, as before (host and Cortex-M4 model). |
| Core elaboration | iverilog, `-DMK3`, the whole `sd2snes_xc` (Altera IP replaced by behavioural models) | Clean |

The "reads found the ring empty" statistic was 68 in 60 s. Each one is a SNES read that came within about 250 ns of a post, before the first byte arrived. The kernel is polling at those moments, as it does on the cartridge, where the RP2040's DMA also takes time.

## Size (estimate)

Quartus isn't available here. Yosys (`synth_intel`, Cyclone IV E) numbers for `xc_top`, statistics off:

| Block | LUTs | Flip-flops | RAM blocks |
|---|---|---|---|
| xc_m0 (multiplier in logic) | 5,326 | 830 | |
| xc_soc (controller, peripherals) | 2,900 | 1,018 | |
| xc_brr (squares in logic) | 2,312 | 361 | 1 |
| caches (I$, D$) | 786 | 192 | 20 |
| xc_window + xc_stream | 1,187 | 576 | 2 |
| xc_div | 603 | 199 | |
| xc_bridge | 331 | 219 | 2 |
| xc_decbox, xc_tick, top | 551 | 353 | 8 |
| **Total** | **13,996** | **3,748** | **33** |

- **Multipliers:** 2,841 of those LUTs are multipliers that Quartus maps to DSP blocks (the core's 32×32 multiply and the BRR encoder's two squares, five 18×18 multipliers). That leaves about **11,150 LUTs**.
- **Base:** the sd2snes base without MSU/DAC/cheats is about 1,400 LUTs.
- **Total:** about **12,500 of 15,408 LEs (≈81%)**, **34 of 56 M9K**, 5 of 56 multipliers.

This should fit. Timing is covered in the next section.

## Timing (estimate, and the changes it led to)

Quartus isn't available here, so timing was estimated with a small static-timing script (`fpga/timing/sta.py`) on the Yosys netlist:
- **Netlist:** the design is mapped to 4-input LUTs, with adders, multipliers and block RAMs kept as whole cells.
- **Delays** (rough Cyclone IV C8 figures): 1 ns per LUT level including routing; 0.1 ns per carry bit; 3 ns M9K clock-to-out; 4.5 ns for an 18×18 multiplier and 7.5 ns for 32×32.
- **Paths:** the worst register-to-register path in each clock domain. Asynchronous-read memories count as logic, and clock-domain crossings are ignored (they go through synchronizers).

**Calibration.** The same script rates the shipping mk3 SA-1 and GSU cores at 15.8 and 14.1 ns. Both are constrained, and run, at 85.9 MHz (11.65 ns) with no multicycle exceptions. So the script overestimates by a factor of **1.21–1.36**, and the "real" columns below divide by that range.

| Clock domain | Needed | Before | After | After, real (÷1.36 … ÷1.21) |
|---|---|---|---|---|
| `clk_soc` (soft CPU, 40 MHz) | 25.0 ns | 45.4 | **25.7** | **18.9–21.2 ns** (≈47–53 MHz) |
| `clk2` (window, bridge, mailbox; 85.9 MHz) | 11.65 ns | 13.4 | **12.7** | **9.3–10.5 ns** |

**Before: 40 MHz would not have closed, and neither would the 32 MHz fallback.** The original design came out at 33–37 ns, which is 27–30 MHz. The worst path ran through everything in one cycle:
1. D-cache tag RAM, hit compare and read-data mux;
2. the core decoding the arriving instruction word and reading the register file;
3. the 32×32 multiplier;
4. write-back.

A second path of the same length went from the adder, through the next bus address, back into the cache's address register.

**Changes** (all verified as described below):
- **`xc_m0`, decode only from the fetch buffer.** A fetched word is latched and executed the next cycle; a new state `S_X32` handles 32-bit instructions. This takes the cache hit path out of decode/execute. The 30-bit `pc+2` buffer compare became `hit & ~pc[1]`.
- **`xc_m0`, early fetch.** When an instruction finishes and its successor's word isn't in the buffer, the fetch is issued in that same cycle, for sequential code, taken branches, BX and 32-bit instructions. The target never depends on bus data, and this is off in step mode. It hides the latch cycle: game timing is unchanged (below).
- **`xc_m0`, two-cycle MUL.** The product is registered, which lets Quartus use the DSP output register. MUL is 0.08% of the instructions executed.
- **`xc_m0`, cache data kept out of the ALU.** Register selects in LDM/STM, POP and exception stacking no longer depend on `bus_ready`. Exception return's SP adjustment has its own adder. The ALU sum enters the next-bus-address mux last. All of these were false paths functionally, but Quartus would have timed them.
- **`xc_brr`, a third pipeline stage.** The variable shift and clamp now come before the squares. It is still bit-exact; a block takes 180 cycles instead of 179.
- **`xc_window`, registered `ring_room`.** It uses 3 bytes of headroom instead of 2, which takes two subtractions and a compare out of the DMA decision on `clk2`.

**Area:** 244 fewer LUTs and 62 more flip-flops (same Yosys flow, before vs after).

What's left on `clk_soc` is the register read → adder → next bus address → cache key path. On `clk2` it is the `TX_PENDING` sum. **40 MHz should now close with about 15–25% margin.** Quartus has the last word. If it doesn't close, `SOC_MHZ` 32 with PLL multiply 4 is now a comfortable fallback.

## Not done yet

1. **Quartus fit and timing.**
   - The estimate above says both domains close, `clk_soc` with 15–25% margin. Check `clk_soc` at 40 MHz and `clk2` at 85.9 MHz in the Quartus timing report.
   - The fallback is still `clk1_multiply_by` 4 with `SOC_MHZ` 32.
2. **First hardware run.**
   - Check that `SNES_DEADr` behaves as the SoC reset expects during the MCU's reset sequence.
   - Watch the UART for the halt report.
   - Check the saves: the `.srm` appears after the first save.
3. **MCU on hardware.** The flash budget is settled with the real mini bitstream (4,692 bytes free, see "MCU"). Measure the decoder's real time on the STM32F401 (modelled: 39% of 84 MHz before flash wait states).
