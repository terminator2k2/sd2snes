MCUSRC := src

README := README*

MK3MCUPATH := $(MCUSRC)/obj-mk3
STMMCUPATH := $(MCUSRC)/obj-mk3-stm32

MK3MCU := firmware.im3
STMMCU := firmware.stm

SAVESTATEPATH := savestate
SAVESTATEFILES := savestate*.yml

MENUPATH := snes

MK3MENU := m3nu.bin

FPGAPATH := verilog

MK3EXT := bi3

MK3CORES := base cx4 gsu obc1 sdd1 sa1 dsp sgb spc7110


MK3FPGA := $(foreach C,$(MK3CORES),$(FPGAPATH)/sd2snes_$C/fpga_$C.$(MK3EXT))


MK3MINI := $(FPGAPATH)/sd2snes_mini/fpga_mini.bi3


MK3CLEAN := $(foreach C,$(MK3CORES) mini,$(FPGAPATH)/sd2snes_$C/.clean.$(MK3EXT))

UTILS := utils

-include src/VERSION
include src/version.mk

TARGETPARENT := release/v$(CONFIG_VERSION)
TARGET := $(TARGETPARENT)/sd2snes

all: version fpga build release

fpga: $ $(MK3FPGA)

$(MK3FPGA) $(MK3MINI):
	$(MAKE) -C $(dir $@) mk3

$(MK3CLEAN):
	$(MAKE) -C $(dir $@) mk3_clean

build:  $(MK3MINI)
	$(MAKE) -C snes
	$(MAKE) -C src CONFIG=config-mk3
	$(MAKE) -C src CONFIG=config-mk3-stm32

clean:  $(MK3CLEAN)
	$(MAKE) -C snes clean
	$(MAKE) -C src clean CONFIG=config-mk3
	$(MAKE) -C src clean CONFIG=config-mk3-stm32

release: version bsxpage
	rm -rf $(TARGETPARENT)
	mkdir -p $(TARGET)
	cp bin/*.bin $(TARGET)
	cp $(README) $(TARGET)
	cp $(MK3FPGA) $(TARGET)
	cp $(MK3MCUPATH)/$(MK3MCU) $(TARGET)
	cp $(STMMCUPATH)/$(STMMCU) $(TARGET)
	cp $(MENUPATH)/$(MK3MENU) $(TARGET)
	cp $(SAVESTATEPATH)/$(SAVESTATEFILES) $(TARGET)
	cd $(TARGETPARENT) && zip -r sd2snes_firmware_v$(CONFIG_VERSION).zip sd2snes

bsxpage:
	cd bin && ../$(UTILS)/genbsxpage

version:
	@echo Version: $(CONFIG_VERSION)

.PHONY: version release bsxpage  $(MK3FPGA)  $(MK3MINI)  $(MK3CLEAN)
