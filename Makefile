MCUSRC := src

README := README*


MK3MCUPATH := $(MCUSRC)/obj-mk3


MK3MCU := firmware.im3


SAVESTATEPATH := savestate
SAVESTATEFILES := savestate*.yml

MENUPATH := snes

MK3MENU := m3nu.bin

FPGAPATH := verilog
MK2EXT := bit
MK3EXT := bi3
MK2CORES := base cx4 gsu obc1 sdd1 sa1 dsp sgb sgb_msu
MK3CORES := base cx4 gsu obc1 sdd1 sa1 dsp sgb st0011 st0018 col20 xc_msu


MK3FPGA := $(foreach C,$(MK3CORES),$(FPGAPATH)/sd2snes_$C/fpga_$C.$(MK3EXT))


MK3MINI := $(FPGAPATH)/sd2snes_mini/fpga_mini.bi3


MK3CLEAN := $(foreach C,$(MK3CORES) mini,$(FPGAPATH)/sd2snes_$C/.clean.$(MK3EXT))

BIN := bin

UTILS := utils

-include src/VERSION
include src/version.mk

TARGETPARENT := release/v$(CONFIG_VERSION)
TARGET := $(TARGETPARENT)/sd2snes

all: version fpga build release

fpga:  $(MK3FPGA)


$(MK3FPGA) $(MK3MINI):
	$(MAKE) -C $(dir $@) mk3

$(MK3CLEAN):
	$(MAKE) -C $(dir $@) mk3_clean

build:  $(MK3MINI)
	$(MAKE) -C snes
	$(MAKE) -C src CONFIG=config-mk3

clean:  $(MK3CLEAN)
	$(MAKE) -C snes clean
	$(MAKE) -C src clean CONFIG=config-mk3

release: version bsxpage
	rm -rf $(TARGETPARENT)
	mkdir -p $(TARGET)
	cp $(BIN)/*.bin $(TARGET)
ifneq ($(README),)
	cp $(README) $(TARGET)
endif
	
	cp $(MK3FPGA) $(TARGET)
	
	cp $(MK3MCUPATH)/$(MK3MCU) $(TARGET)
	
	
	cp $(MENUPATH)/$(MK3MENU) $(TARGET)
ifneq ($(SAVESTATEPATH),)
	cp $(SAVESTATEPATH)/$(SAVESTATEFILES) $(TARGET)
endif
	cd $(TARGETPARENT) && zip -r sd2snes_firmware_v$(CONFIG_VERSION).zip sd2snes

bsxpage:
	$(MAKE) -C $(UTILS)
	mkdir -p bin
	cd bin && ../$(UTILS)/genbsxpage

version:
	@echo Version: $(CONFIG_VERSION)

# ---- ludufre PT-BR fork: mk3-only targets (no mk2 = no Xilinx ISE) ----
# `mk3`     : full from-scratch mk3 release (FPGA cores via Quartus [Make-cached]
#             + firmware mk3/stm32 + menu + bsxpage), assembled + zipped. Nothing
#             from the official zip. Needs QUARTUS_ROOTDIR in the env (prepare.sh).
# `mk3-fw`  : just menu + firmware (mk3 + stm32) — fast, for device-update
#             iteration; skips the big FPGA cores (only needs the mini cfgware).
mk3: version $(MK3FPGA) $(MK3MINI) bsxpage mk3-fw
	rm -rf $(TARGETPARENT)
	mkdir -p $(TARGET)
	cp bin/*.bin $(TARGET)
	cp $(README) $(TARGET)
	cp $(MK3FPGA) $(TARGET)
	cp $(MK3MCUPATH)/$(MK3MCU) $(TARGET)
	cp $(MENUPATH)/$(MK3MENU) $(TARGET)
	cp $(SAVESTATEPATH)/$(SAVESTATEFILES) $(TARGET)
	cd $(TARGETPARENT) && zip -r sd2snes_firmware_v$(CONFIG_VERSION).zip sd2snes

mk3-fw: $(MK3MINI)
	$(MAKE) -C snes
	$(MAKE) -C src CONFIG=config-mk3

.PHONY: version release bsxpage mk3 mk3-fw  $(MK3FPGA)  $(MK3MINI)  $(MK3CLEAN)
