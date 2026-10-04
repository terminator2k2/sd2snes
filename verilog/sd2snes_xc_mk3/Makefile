CORE = xc_mk3

# Xeno Crisis combined core (fpga_xc_mk3.bi3): Opus decode mailbox and MSU-1, chosen at load time.
# Self-contained test project: copies of the sources of ../sd2snes_xc and ../sd2snes_xc_msu (keep them in step).
# main.qsf defines XC_MSU and XC_MK3.
VSRC = address.v cheat.v dcm.v main.v mcu_cmd.v sd_dma.v spi.v rtc.v \
       xc_top.v xc_soc.v xc_m0.v xc_cache.v xc_bridge.v xc_window.v xc_stream.v xc_brr.v xc_tick.v xc_decbox.v \
       msu.v xc_dac.v xc_msubox.v xc_mk3_pll.v
VHSRC =

HEADER = config.vh

COMMON_IP = dac_buf msu_databuf snescmd_buf

XIL_IP =
XIL_IPCORE_DIR = ip/mk2

INT_IP =
INT_IP_DIR = ip/mk3

include ../settings.mk
include ../common.mk
