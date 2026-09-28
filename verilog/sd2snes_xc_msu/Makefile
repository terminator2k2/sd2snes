CORE = xc_msu

# Xeno Crisis MSU-1 core (fpga_xc_msu.bi3). The soft CPU, main.v and the other shared sources come from
# ../sd2snes_xc (like sd2snes_sgb_msu takes them from ../sd2snes_sgb); msu.v, xc_dac.v and xc_msubox.v are
# this core's own. main.qsf defines XC_MSU.
XC = ../sd2snes_xc

VSRC = $(addprefix $(XC)/, address.v cheat.v dcm.v main.v mcu_cmd.v sd_dma.v spi.v rtc.v \
         xc_top.v xc_soc.v xc_m0.v xc_cache.v xc_bridge.v xc_window.v xc_stream.v xc_brr.v xc_tick.v) \
       msu.v xc_dac.v xc_msubox.v
VHSRC =

HEADER = $(XC)/config.vh

COMMON_IP = dac_buf msu_databuf snescmd_buf

XIL_IP =
XIL_IPCORE_DIR = $(XC)/ip/mk2

INT_IP = pll
INT_IP_DIR = $(XC)/ip/mk3

include ../settings.mk
include ../common.mk
