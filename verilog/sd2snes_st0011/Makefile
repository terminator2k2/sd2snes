CORE = st0011

# Dedicated ST010/ST011 (uPD96050) core.
#   - No MSU-1: frees 8 BRAM on mk2 / 16 M9K on mk3.
# is KEPT. Removing it looked free -- this core fetches the
# 16384-word program externally and never reads the on-chip ROM once
# ext_pgm_en is high -- but it leaves no opcode source at all while that bit
# is low, i.e. between FPGA configuration and the MCU's feature write.
# Dropping MSU-1 alone is enough to fit the mk2 XC3S400: 15 of 16 BRAM.

VSRC = address.v cheat.v clk_test.v dcm.v dma.v upd77c25.v \
       upd77c25_extpgm.v main.v mcu_cmd.v sd_dma.v spi.v
VHSRC =

COMMON_IP = snescmd_buf upd77c25_datram upd77c25_datrom

HEADER = config.vh

XIL_IP =
XIL_IPCORE_DIR = ip/mk2

INT_IP = pll

include ../settings.mk
include ../common.mk
