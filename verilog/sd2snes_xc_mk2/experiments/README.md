# Size experiments (synthesis only)

These patches record how the first-round mk2 design (`xc_m0.v`/`xc_soc.v` of commit "cut-down soft CPU and SoC")
was shrunk further, step by step. They were **only synthesized, not simulated or tested**: they show how much each
step saves, not that the result works. All six are applied in the core in the folder above; the core then got two more
changes that the patches don't contain: the LRU bits and the bridge buffers in distributed RAM, and a 16 KB cache.

They apply in order, with `patch -p1`, to a flat folder holding the Xeno Crisis sources as the mk2 core would use them:

- `xc_m0.v`, `xc_soc.v` of the first-round mk2 design (`git show <commit>:verilog/sd2snes_xc_mk2/xc_soc.v`, from the
  commit "NVIC acknowledge wins over a tick");
- `xc_top.v`, `xc_cache.v`, `xc_bridge.v`, `xc_window.v`, `xc_stream.v`, `xc_brr.v`, `xc_tick.v`, `xc_decbox.v` from
  `../sd2snes_xc`;
- `xc_msubox.v` from `../sd2snes_xc_msu`.

Note that `xc_bridge.v`'s `xc_dpram8` must read asynchronously (distributed RAM) for Yosys.

## Method

Yosys `synth_xilinx -family xc3s -flatten`, `xc_top` with MSU = 1 and STATS = 0. Numbers are LUTs; a RAM16X1D takes
2 more LUT sites.

## Results

| Step | Patch | LUTs | Saving | Flip-flops |
|---|---|---|---|---|
| mk2 folder as committed (2 KB I + 2 KB D cache) | – | 7,900 (+87 RAM16) | | 3,109 |
| No performance counters in `xc_top` | `1-no-perf-counters` | 7,827 | −73 | 2,617 |
| Mixer, BRR encoder, tick timer and interrupts removed (the MCU would mix) | `2-mixer-on-mcu` | 7,022 (+72 RAM16) | −805 | 2,111 |
| One cache (4 KB) for code and data | `3-one-cache` | 6,850 | −172 | 2,039 |
| Write-through D-cache: no dirty lines, write-back or clean-before-DMA | `4-write-through` | 6,376 | −474 | 1,927 |
| `$3000` descriptor queue 8 → 2 entries (4 entries: −197) | `5-window-queue-2` | 6,003 (+64 RAM16) | −373 | 1,721 |
| No early instruction fetch | `6-no-early-fetch` | **5,765** (+64 RAM16) | −238 | 1,721 |
| (on top of step 4) SoC on CLK2, no synchronizers in the bridge | `x-sync-bridge` | 6,437 | about 0 | |

A 1-bit-per-cycle shifter instead of the barrel shifter showed no saving in Yosys, so it is not included.

What is left after step 6 (hierarchical synthesis): CPU core ~3,250 LUTs + 64 RAM16, SoC controller ~1,500, bridge
~520, window ~440, cache tags/LRU ~240, stream ring ~200.

## Against the mk2 FPGA

Measured the same way, complete cores (including the base sd2snes logic):

| Design | LUTs |
|---|---|
| gsu3 (FX3) core, ludufre fork: fits the XC3S400 | 5,488 |
| classic gsu core, same fork: fits | 5,987 |
| Xeno Crisis base logic (address, MCU interface, MSU-1, DAC, cheats, ...) | 1,817 |
| Xeno Crisis after all steps: 1,817 + 5,765 + 128 (LUT RAM) | **~7,700** |
| without the cheat engine (~500 standalone; loses the in-game hooks) | ~7,200 |
| the XC3S400 | 7,168 |

After all steps it is still about 1.2–1.3× the largest design known to fit. These are Yosys estimates; ISE maps more
densely, so only an ISE build can settle it.

## Costs, still to be measured

- **Write-through:** every store goes over the bridge to the 8-bit SRAM, which is slow.
- **One cache:** code and data compete for the same lines.
- **Short descriptor queue:** the firmware queues single bytes, so a queue of 2 makes it wait for the SNES more often.
- **No early fetch:** about one cycle more per taken branch.
- **The Spartan-3 -4 clock:** it probably can't run the soft CPU at 40 MHz.

At 40 MHz with separate 4 KB caches, the CPU had about a third of its time spare (RTL-in-the-loop). How much of that
these steps use up is unknown.
