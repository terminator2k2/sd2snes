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

- **Clock domains.**
  - The soft CPU runs in its own clock domain, **40.25 MHz** from a second output of the same PLL (8 MHz × 161/32). The sd2snes side (`CLK2`) keeps the GSU core's 85.87 MHz (8 MHz × 161/15).
  - Both outputs share one 1,288 MHz VCO. An exact 40 MHz is impossible next to 85.87 MHz, because there is no common VCO (Quartus error 15094).
  - The SoC's microsecond timer and mixer tick take the clock as a fraction (`SOC_CLK_NUM/SOC_CLK_DEN` = 161/4 MHz) and use phase accumulators, so time stays exact. `tb_xc_clkfrac.v` checks this for 161/4, 40/1, 1288/33 and 161/5.
- **The crossing.** Everything crosses through `xc_bridge`. It carries one operation at a time: a cache line, a register access or a single uncached access. The request and completion are toggles through two-flop synchronizers, and the data sits in two small dual-clock RAMs. The SoC clock can therefore be changed freely. Set the PLL's `clk1` to 161/*d* and `SOC_CLK_NUM/SOC_CLK_DEN` to 1288/*d* MHz, reduced (for example *d* = 40: 32.2 MHz, 161/5). Also set the `clk[1]` line in `main.sdc`.
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

- **I-cache:** 16 KB, 2-way, 32-byte lines (`IIDX` = 8; it was 4 KB). It caches flash and bootrom. Code fetched from RAM goes through the D-cache instead.
- **D-cache:** 16 KB, 2-way, write-back (`DIDX` = 8; it was 8 KB). It caches RAM, flash and bootrom.
- **Deferred write-back:** on a miss that evicts a dirty line, the victim goes into the bridge's write buffer, the fill is done first, and the victim is written to the SRAM chip afterwards while the core runs on cache hits. The next access that needs the bridge waits for that write, so bridge operations stay in order.
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

- **Both mk3 MCUs.** The FPGA core, the game image and everything below except Opus are the same for both.
  - **STM32F401 (`firmware.stm`):** full support, including the music decoder.
  - **LPC1756 (`firmware.im3`):** no music.
    - The Opus decoder needs about 26.5 KB of contiguous RAM plus about 11 KB of stack. Its CELT half alone is about 17 KB, larger than either of the LPC1756's two 16 KB RAM banks. The stock firmware already leaves only about 5 KB and 7 KB free.
    - Its decode service therefore answers every music packet at once as "nothing decoded" (ret 0, final range 0). The mixer treats the track as ended (the RP2040 firmware's path for corrupted music data) and keeps mixing the sound effects.
    - Checked in MesenCE (`XC_NODEC=1`, 3,600 frames): all 120 screenshots are identical to the normal run, with no faults and the same stream. The audio is exactly the sound-effect part of the normal soundtrack: correlation 0.141 at zero lag, which equals √(energy ratio 0.020).
    - `firmware.im3`: 144,648 bytes; main RAM use is the stock 10,868 bytes + 16.
- **Detection** (`smc.c`, `CONFIG_MK3`): map `$30`, chipset `$63`, maker `BM`, game `XCRI`. It sets `FPGA_XC` (`/sd2snes/fpga_xc.bi3`) and 32 KB of save RAM.
- **Loading** (`memory.c`, `xc_load.c`):
  - the 128 KB SNES ROM loads as a normal ROM; then `xc_load_image()` adds the RP2040 flash dump (`/sd2snes/xenocrisis_rp2040.bin`, two SD DMA transfers: flash `0x020000-0xCFFFFF` to PSRAM `0x020000`, flash `0x000000-0x01FFFF` to `0xD00000`) and `/sd2snes/xc_soc.bin` (bootrom to `0xD20000`, firmware additions to `0xD24000`), and applies the additions' patch table (17 redirects) in the PSRAM. Checked on the host against `xc_build_image.py`: the PSRAM image (`0x000000-0xD27FFF`) and the seeded save area are byte-identical;
  - a larger file is a prebuilt image (`xc_build_image.py`) and loads as is;
  - the `.srm` loads to the SRAM chip. Without a `.srm`, the save area comes from the dump (`0xFF8000-0xFFFFFF`) when the image was built from it, else it is filled with `0xFF` (erased flash);
  - no cheats or save states;
  - `xc_run(1)` releases the soft CPU just before the SNES leaves reset.
- **Main loop** (`main.c`): `xc_audio_poll()` provides the Opus decode service (`xc_audio.c`) and a halt report on the UART. With Xeno Crisis the loop skips its per-iteration `sram_reliable()` (256 PSRAM reads, 1–2 ms, which also take ROM-bus slots from the soft CPU); `snes_main_loop()` still runs it every 250 ms.
- **First hardware statistics** (163 s of play, 8,136 packets): decode 7.0 ms on average (the model said 7.1), max 25 ms (the CELT → hybrid switch at a track start runs a CELT PLC frame with a pitch search: 24–27 ms in the model too). The service time per packet has a second cluster at 20–26 ms (6%): packets that waited behind a 12 ms MCU pause every 250 ms. A second log (after the change below) placed it: the main loop's debug print of the CIC state, whose `get_cic_state()` samples the CIC pin 100,000 times. It is skipped with Xeno Crisis now. The other pause, 3 ms every 250 ms, was `sram_reliable()` in `snes_main_loop()`: 1,024 PSRAM reads that each wait for a ROM-bus slot behind the soft CPU and take slots from its flash fetches meanwhile; with Xeno Crisis it now does 4 reads instead of 256 (1 ms in the second log). The second log also shows no poll gap over 20 ms and a 21 ms log write. The log also reports how long its own previous write took.
- **Long MCU jobs serve the decoder in between** (`memory.c`): the save RAM CRC (32 KB every 250 ms, about 20 ms) calls `xc_audio_service()` every 512 bytes, and `save_sram()` after every 512-byte sector written to the SD card.
- **Timing statistics** (`xc_audio.c`, DWT cycle counter): per packet the service time (including the poll gap before it) and the decode time, the poll gaps, and how often the mixer was already waiting for the next packet. Printed on the UART and written to **`/sd2snes/xcaudio.txt`** every 1,500 packets (30 s of music) and when the game is left (long reset or reset to menu). The first version wrote it only when the game was left, so switching the console off lost it. The periodic write is skipped inside the CRC or a save and done at the next main-loop job; FatFs errors go to the UART.
- **Opus library:** `xc_opus/build.sh <opus-1.3.1 source>` builds `libopus_xc.a`. The settings are exact (see the script). **Built with the sd2snes MCU flags and run on a Cortex-M4 instruction-level model, it decodes all 480,000 samples bit-exact** (checksum `0xdb88f8e0`, the same as the host decoder that matches the firmware).
- **Size, with the real mini bitstream** (`fpga_mini.bi3`, 56,939 bytes, embedded by the build):
  - **`firmware.stm` is 212,788 bytes (with the stutter changes: hot Opus files at `-O2`, statistics): a 212,276-byte image plus the 512-byte header, against 212,480 + 512.** That leaves 204 bytes free (4,692 before the stutter changes, 1,352 before `xc_load.c`). RAM: 13.4 KB left for the stack (Opus needs about 11 KB).
  - Two changes were needed to fit:
    - **`stm32f401.ld`:** the `.ahbram` buffers (8 KB sort buffer, MSU-1) became `NOLOAD`. On the STM32 nothing initializes them from flash, but their 8,992 zero bytes were stored in the image. The RAM layout is unchanged. Stock 1.11.2 shrinks by the same 8,992 bytes (153,936 → 144,944).
    - **`xc_opus/build.sh`:** `-Os`, and `SMALL_FOOTPRINT` for `cwrs.c` only (computes the PVQ codeword counts instead of a 5 KB table). Still bit-exact: checksum `0xdb88f8e0` on the host and on the Cortex-M4 model.
  - The linker script also gained an `ASSERT`: before, the `.data` and `.ahbram` load bytes were not checked against the flash region, so an oversized firmware linked without an error. With `-O2` Opus the image would have been about 20 KB too large; now that fails to link.
- **SPI to the FPGA (fixed after the first hardware run):**
  - The decode service first used `FPGA_RX_BLOCK`/`FPGA_TX_BLOCK`. Stock firmware never uses them with the FPGA, and they fail there in two ways:
    - `spi_rx_block` takes a DMA path for lengths that are a multiple of 4 on an aligned buffer. That path uses peripheral flow control, which SPI doesn't support, so its transfer-complete wait never ends and the **MCU hangs**. On hardware this happened within the first few packets (a quarter of the game's packets qualify; the first is packet #4). The mixer then waited for its decode result forever, so there was no music and no sound effects, while the game itself kept running.
    - Both run bytes back to back. `spi.v` loads the next read value and latches a written byte a few CLK2 cycles after each byte, so back-to-back bytes arrive corrupted.
  - Now every byte goes through `FPGA_RX_BYTE()`, or `FPGA_TX_BYTE()` + `FPGA_TX_SYNC()`, the way the stock firmware talks to the FPGA.
- **MCU time for the Opus decoder:** about 29.8 M cycles/s (36% of 84 MHz, instruction-level Cortex-M4 model, before flash wait states), i.e. about 7.1 ms per 20 ms packet. The hot CELT synthesis files (`kiss_fft`, `mdct`, `celt`, `celt_decoder`: FFT, MDCT, comb filter, deemphasis) are built `-O2`, the rest `-Os`: −10% time for +1.8 KB (it was 33.1 M, 39%, all `-Os`). All `-O2` with the PVQ table would be 26.0 M; the computed `cwrs` costs 8% but saves the 5 KB the flash does not have.
- **Audio stutter (second hardware run) and the throughput rule.** The mixer submits one packet at a time. A packet is 20 ms of music, so the whole service per packet (poll latency, SPI transfer, decode) must average below 20 ms, or the music runs dry. Measured in MesenCE with a fixed service time per packet (`XC_DEC_LATENCY_US`, 30 s of play, SoC mode):

  | Service time per packet | Old mixer: music underruns | New mixer: music underruns |
  |---|---|---|
  | 6–18 ms | 0 | 0 |
  | 19 ms | 80 | 0 |
  | 20 ms | 1,832 | 0 |
  | 25 ms | — | 7,608 |
  | 15–18 ms + 20–40 ms MCU pause every 250 ms | 0 | 0 |

  The old mixer also stopped mixing entirely while a decode was out, so the BRR rings (about 128 ms) drained during long MCU pauses and the sound effects stuttered with the music. Changes:
  - **Mixer** (`socfw/xc_mix.c`, needs a rebuilt image): mixes the sound effects and the already decoded music while a packet is being decoded (the slot for that packet is left out), and sends the next packet as soon as a result arrives instead of at the next tick. The BRR rings now stay full in every run above; an MCU pause only reaches the music once the decoded PCM (up to 100 ms) is used up. With a 6 ms service time the output is identical to the old mixer (correlation 1.0000 at zero lag). RTL run (900 frames, 15 ms): 0 reference mismatches, 0 DMA mismatches, 59.3 game ticks/s.
  - **MCU:** no `sram_reliable()` per loop iteration, decode service inside the CRC and the save, `-O2` for the hot CELT files (above).
  - The model's decode time comes from an instruction-level estimate. The real STM32 cost (flash wait states, ART cache misses) is not known; `xcaudio.txt` reports it.

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
| `$C7` XC_PERF_SNAP | snapshot of the performance counters |
| `$C8` XC_PERF | read: null, 8 counters (4 bytes LE each) |

**Slowdowns and flicker (hardware counters, first log):** in 30.8 s of play the soft CPU spent 42% of its cycles waiting for memory (instruction fetches 14%, flash data 8%, RAM data 20%), and 92 of 1,711 game ticks (5.4%) took longer than one SNES frame (longest 25 ms). Quartus: `clk[1]` Fmax 41.26 MHz (slack 0.61 ns at 40.25 MHz, worst path into the stack pointer), so the clock cannot go up; 81% of the logic elements and 28% of the memory bits are used. The window underran 42 times in 30 s, the same rate as in the co-simulation (reads right after a post, while the kernel polls). So the fix is fewer and shorter memory stalls. The co-simulation with the bus latencies doubled (RAM 14 CLK2 cycles per byte, up to 56 cycles for a free SNES slot), 600 frames:

| Caches | Stalled on memory | Tick p95 / p99 / max | Ticks longer than a frame |
|---|---|---|---|
| 4 KB I$ + 8 KB D$ (before) | 25.6% | 10.88 / 13.74 / 29.9 ms | 3 of 580 |
| 4 KB + 8 KB, deferred write-back | 22.6% | 10.30 / 12.72 / 25.9 ms | 3 of 579 |
| 8 KB + 16 KB | 16.0% | 9.39 / 12.09 / 29.2 ms | 2 of 580 |
| 16 KB + 16 KB | 12.6% | 9.14 / 11.76 / 29.0 ms | 1 of 580 |
| **16 KB + 16 KB, deferred write-back** | **10.5%** | **8.66 / 11.38 / 25.9 ms** | **1 of 581** |

All runs: 0 reference mismatches, 0 DMA mismatches. With the normal bus latencies (900 frames): stalled 8.2% instead of 20.5%, tick p95 / p99 8.45 / 10.95 ms instead of 9.38 / 11.71, screenshots identical up to frame 150 (after that the game's timing differs, as before), 101.7 M core reads and 822 KB of DMA checked with 0 mismatches. The caches take 16 more M9K blocks (about 50 of 56). If `clk[1]` misses timing with the 16 KB I-cache, `IIDX` 7 (8 KB) uses no more M9K blocks than the old 4 KB one.

**On hardware with the 16 KB caches** (second log, 29.9 s of play): memory stalls 22% (instruction fetches 5%, flash data 5%, RAM data 12%) instead of 42%; 8 of 1,827 game ticks longer than a frame (0.4%, was 5.4%), longest 18.3 ms (was 25 ms); 61 ticks per second, i.e. full speed. Quartus: `clk[1]` Fmax 40.98 MHz, slack 0.44 ns; 85% of the logic elements, 61% of the memory bits. `main.sdc` now also has the clock uncertainty for `clk[1]` to itself (Critical Warning 332169).

**SRAM bursts** (after the second log, where RAM data was the largest stall at 12%): the SRAM chip is 8 bits wide, and each byte of a line fill or write-back used to be a separate request through the bridge, the arbiter and `main.v`'s RAM state machine, about 15 CLK2 cycles per byte. Now the bridge asks for the whole line at once (`XC_RAM_LEN`, up to 32 bytes) and `main.v` runs the bytes back to back, each still a full SRAM access (ADDR for `RAM_CYCLE_LEN` + 1 cycles, END, IDLE): 8 cycles per byte. `XC_RAM_BSTB` marks each byte (read: data valid; write: byte taken, present the next). The window DMA still reads single bytes, with priority between bursts; the MCU waits for a burst to end (at most about 3 µs).
- `rambench/tb_ram_burst.v` runs the real `main.v` RAM pipeline against an asynchronous SRAM model (10 ns, write at the rising edge of WE, address checked stable during WE): 32-byte write and read, single bytes, a burst up to the last address. **PASS; 32 bytes in 258 CLK2 cycles (8.1 per byte).**
- Co-simulation (the C++ model of `main.v` follows the same protocol), 900 frames, normal latencies: stalled on memory 5.9% instead of 8.2% (RAM data 3.5% instead of 5.4%), tick p95 8.08 ms, 2 ticks longer than a frame, screenshots identical to frame 150, 104 M core reads and 822 KB of DMA checked with 0 mismatches. With doubled latencies (600 frames): 8.2% instead of 10.5%, longest tick 21.6 instead of 25.9 ms.

**Timing after the SRAM bursts:** the first Quartus build with the bursts missed timing on `clk[1]` by 4.36 ns (Fmax about 34 MHz; the build before had +0.44 ns). The failing paths were all inside the core, from `pc` to the register file, the flags and the cache key (data delay 29.5 ns); the burst logic itself is in the `clk[0]` domain, which kept +1.24 ns. So the fitter placed the core worse this time (85% of the logic, 49 of 56 M9K), and those paths had no margin to lose. Changes:
- **`xc_m0`: PC + 4 in a register.** The value the core reads as PC was `pc + 4` from an adder, so the paths ran through two 32-bit carry chains (PC + 4, then the ALU). `pc4r` now follows `pc` on sequential steps (+2 / +4 of the register); after a jump it is recomputed in the next cycle, and the jump empties the fetch buffer, so the next instruction is fetched first and cannot start before `pc4r` is valid. Only a jump to the word already in the buffer loses a cycle. Checked: the random ISA lockstep (2 × 3,000 programs, 2.86 M instructions, 0 mismatches) and the whole game on the RTL (900 frames: identical results and all 30 screenshots identical to the build without the change; 104 M core reads, 0 mismatches).
- **`main.qsf`:** optimization mode "Aggressive Performance", register duplication and combinational physical synthesis, router effort ×2, as in the cx4 and dsp cores.
- **If timing still fails:** lower the soft CPU clock to 37.88 MHz: `ip/mk3/pll.v` `clk1_divide_by` 34 (instead of 32), `main.sdc` `clk[1]` `-divide_by 34`, `main.v` `.SOC_CLK_NUM(644), .SOC_CLK_DEN(17)` (8 MHz × 161 / 34 = 644/17 MHz). That is 6% slower, less than the bursts and caches gained.

**On hardware with the SRAM bursts and the PC + 4 register** (third log, 29.9 s of play): 0 of 1,842 game ticks longer than a frame (was 8 of 1,827), longest 14.2 ms (was 18.3); memory stalls 21% (fetch 5%, flash data 7%, RAM data 9% instead of 12%). Quartus: `clk[1]` slack +0.69 ns (Fmax 41.4 MHz), `clk[0]` +1.19 ns, no critical warnings; 91% of the logic elements, 49 of 56 M9K. The game runs smoothly. Little logic is left for further additions.

**Performance counters** (`xc_top.v`, "perf"; the MCU logs them in `xcaudio.txt`, as differences since the previous log): SoC cycles; cycles stalled on instruction fetches, on flash data and on RAM data; game ticks (the firmware read the SNES end-of-frame message and posted its next stream descriptor), ticks longer than one SNES frame (16.64 ms), the longest tick; and window underruns (SNES reads that found the prefetch ring empty while a descriptor was queued). They were added after the first hardware reports of slowdowns and flicker at the top of the screen, which the RTL co-simulation doesn't show (3–5 ticks longer than a frame in 900 frames). In the co-simulation they match the bus monitor's own counts (e.g. 123 ticks, longest 456,420 vs 456,421 cycles, 1 underrun). The SoC counters are copied on a synchronized toggle; `clk[0]` and `clk[1]` are asynchronous clock groups in `main.sdc`, so the MCU's read of the static snapshot is not timed.

## Building and using it

1. **FPGA:** `verilog/sd2snes_xc` is a Quartus project (`sd2snes_xc.qpf`, EP4CE15F17C8) like the other mk3 cores. `make` in that folder produces `fpga_xc.bi3`; copy it to `/sd2snes/` on the SD card.
2. **MCU:** build the Opus library (`src/xc_opus/build.sh <opus-1.3.1>`), then the firmware as usual (`make CONFIG=config-mk3-stm32`).
3. **Soft CPU files:** in `socfw/`, run `build.sh`. Copy `xc_soc.bin` (replacement bootrom + firmware additions, 33,280 bytes) to `/sd2snes/`, next to `fpga_xc.bi3`. Like the bitstream, it belongs to the firmware release, not to the game.
4. **The game:** put the RP2040 flash dump in `/sd2snes/xenocrisis_rp2040.bin` (16 MB, supplied by the user like the DSP or BS-X files) and load the cartridge's SNES ROM from the menu like any other game (`XENOCRISIS`, 128 KB, CRC32 `FE5B38F0`). The firmware builds the image in the PSRAM (`src/xc_load.c`). Without a `.srm` the save area starts from the dump's, so the cartridge's saves carry over; from then on the saves go to the `.srm` as usual.
   - A missing or wrong `xenocrisis_rp2040.bin` or `xc_soc.bin` is reported by the menu as a missing supplemental file (as for DSP firmware). The dump is checked for size (16 MB) and firmware build (`multicore_launch_core1` at `0x10059060`); `xc_soc.bin` for its header.
   - `xc_build_image.py` still works: a file larger than 128 KB is taken as a prebuilt image and loaded as is.

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
| **MCU ↔ FPGA link, LPC1756 build** (`mcutest/`, `XC_NODEC=1`, `xc_audio.c` without `CONFIG_MK3_STM32`) | Same harness | 500/500 jobs answered (ret 0, range 0), no hang, no Opus code linked |
| **MCU ↔ FPGA link, end to end** (`mcutest/`) | The real `src/xc_audio.c`, compiled for the host, with the FPGA SPI macros mapped to an STM32F401 SPI master model (42 MHz, mode 0; the timing of the stock `spi_tx_byte`/`spi_rx_byte`/`spi_rx_block`) against the real `spi.v`, `mcu_cmd.v` and `xc_decbox.v`. The soft-core side of the mailbox feeds the game's 500 Opus packets as the mixer does; ret, final range and PCM are compared with a direct decode. | **Found the bug behind "no music, no sound effects" on hardware (below): the original code hangs at packet #4.** Fixed code: 500/500 packets, 0 mismatches, PCM checksum `0xdb88f8e0`. It still works with a 1-cycle gap before each read byte (`spi_rx_byte` has several); it fails with no gap. SPI time: about 0.5 ms per packet (2.4% of the MCU). |
| Image builder | The RTL runs from the file `xc_build_image.py` produced (`XC_RTL_IMAGE`) | Same results and screenshots as the RTL's own layout |
| MCU firmware | `make CONFIG=config-mk3-stm32` with the changes, the Opus library (`-Os`, hot CELT files `-O2`, small-footprint `cwrs.c`) and the real `fpga_mini.bi3` (56,939 bytes) | **Builds and links: `firmware.stm` 212,788 bytes (limit 212,992 with header).** The embedded bitstream is byte-identical to the file. With `-O2` Opus the link stops with "firmware image does not fit in flash". Opus decoder output: checksum `0xdb88f8e0`, as before (host and Cortex-M4 model). |
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

What's left on `clk_soc` is the register read → adder → next bus address → cache key path. On `clk2` it is the `TX_PENDING` sum. **40.25 MHz (24.84 ns, the PLL's actual clock) should now close with about 15–25% margin.** Quartus has the last word. If it doesn't close, the fallback is 32.2 MHz: PLL `clk1` 161/40, `SOC_CLK_NUM/DEN` 161/5, and `main.sdc` `clk[1]` 161/40.

## Not done yet

1. **Quartus fit and timing.**
   - The estimate above says both domains close, `clk_soc` with 15–25% margin. Check `clk_soc` (`clk[1]`, 40.25 MHz) and `clk2` (`clk[0]`, 85.87 MHz) in the Quartus timing report.
   - Fallback: 32.2 MHz (see "Timing").
   - The first Quartus run failed on the PLL (an exact 40 MHz next to 85.87 MHz can't be made; error 15094). The fix: `clk1` = 161/32, and `clk0` requested as the exact 161/15 it already ran at.
2. **First hardware run** (done: the game boots and plays; there was no audio until the SPI fix above, so audio on hardware is still to be confirmed).
   - Check that `SNES_DEADr` behaves as the SoC reset expects during the MCU's reset sequence.
   - Watch the UART for the halt report.
   - Check the saves: the `.srm` appears after the first save.
3. **MCU on hardware.** The flash budget is settled with the real mini bitstream (4,692 bytes free, see "MCU"). Measure the decoder's real time on the STM32F401 (modelled: 39% of 84 MHz before flash wait states). On the LPC1756 (`firmware.im3`), check the game with sound effects only.
