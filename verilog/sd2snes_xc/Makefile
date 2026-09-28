CORE = xc

VSRC = address.v cheat.v dac.v dcm.v main.v mcu_cmd.v msu.v sd_dma.v spi.v \
       xc_top.v xc_soc.v xc_m0.v xc_cache.v xc_bridge.v xc_window.v xc_stream.v xc_decbox.v xc_msubox.v xc_dac.v xc_brr.v xc_tick.v
VHSRC =

HEADER = config.vh

COMMON_IP = dac_buf msu_databuf snescmd_buf

XIL_IP =
XIL_IPCORE_DIR = ip/mk2

INT_IP = pll

include ../settings.mk
include ../common.mk

# Xeno Crisis MSU-1 core: revision "msu" (msu.qsf = main.qsf + XC_MSU). "make msu" builds fpga_xc_msu.bi3.
msu: fpga_$(CORE)_msu.bi3
mk3: fpga_$(CORE)_msu.bi3

fpga_$(CORE)_msu.bi3: output_files/msu.rbf
	../../utils/rle $^ $@

output_files/msu.rbf: $(VSRC) $(VHSRC) $(HEADER) $(INT_IP) $(INT_QIP) main.sdc msu.qsf
	rm -rf db incremental_db
	$(INTEL_ENV) $(INTEL_BIN)/quartus_map --read_settings_files=on --write_settings_files=off sd2snes_$(CORE) -c msu
	$(INTEL_ENV) $(INTEL_BIN)/quartus_fit --read_settings_files=on --write_settings_files=off sd2snes_$(CORE) -c msu
	$(INTEL_ENV) $(INTEL_BIN)/quartus_sta sd2snes_$(CORE) -c msu
	@! grep -q 'TNS.*-' output_files/msu.sta.summary || (echo "[mk3] sd2snes_$(CORE) msu: Timing not met!"; \
		[ "$(IGNORE_TIMING)"a = 1a ] || (echo "Aborting. To ignore timing violations, run make [...] IGNORE_TIMING=1."; rm "$@"; exit 55))
	$(INTEL_ENV) $(INTEL_BIN)/quartus_asm --read_settings_files=off --write_settings_files=off sd2snes_$(CORE) -c msu

.PHONY: msu
