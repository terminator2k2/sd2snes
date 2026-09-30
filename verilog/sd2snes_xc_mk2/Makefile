CORE = xc_mk2

# Xeno Crisis on the sd2snes mk2 (Spartan-3 XC3S400), MSU-1 only: fpga_xc_mk2.bit. mk2-only core (no mk3 build);
# see README.md. The Verilog macros MK2 and XC_MSU come from sd2snes_xc_mk2.xise.
VSRC = address.v cheat.v dcm.v main.v mcu_cmd.v msu.v sd_dma.v spi.v xc_dac.v \
       xc_top.v xc_soc.v xc_m0.v xc_cache.v xc_bridge.v xc_window.v xc_stream.v xc_msubox.v
VHSRC =

HEADER = config.vh

COMMON_IP = dac_buf snescmd_buf

XIL_IP =
XIL_IPCORE_DIR = ip/mk2

include ../settings.mk
include ../common.mk
