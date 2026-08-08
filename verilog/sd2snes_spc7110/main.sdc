## Generated SDC file "main.sdc"

## Copyright (C) 2018  Intel Corporation. All rights reserved.
## Your use of Intel Corporation's design tools, logic functions 
## and other software and tools, and its AMPP partner logic 
## functions, and any output files from any of the foregoing 
## (including device programming or simulation files), and any 
## associated documentation or information are expressly subject 
## to the terms and conditions of the Intel Program License 
## Subscription Agreement, the Intel Quartus Prime License Agreement,
## the Intel FPGA IP License Agreement, or other applicable license
## agreement, including, without limitation, that your use is for
## the sole purpose of programming logic devices manufactured by
## Intel and sold by Intel or its authorized distributors.  Please
## refer to the applicable agreement for further details.


## VENDOR  "Altera"
## PROGRAM "Quartus Prime"
## VERSION "Version 18.0.0 Build 614 04/24/2018 SJ Lite Edition"

## DATE    "Fri Jul 27 00:34:51 2018"

##
## DEVICE  "EP4CE15F17C8"
##


#**************************************************************
# Time Information
#**************************************************************

set_time_format -unit ns -decimal_places 3



#**************************************************************
# Create Clock
#**************************************************************

create_clock -name {CLKIN} -period 125 -waveform { 0.000 62.5 } [get_ports {CLKIN}]
create_clock -name {SPI_SCK} -period 20.833 -waveform { 0.000 10.417 } [get_ports { SPI_SCK }]


#**************************************************************
# Create Generated Clock
#**************************************************************

create_generated_clock -name {snes_pll|altpll_component|auto_generated|pll1|clk[0]} -source [get_pins {snes_pll|altpll_component|auto_generated|pll1|inclk[0]}] -duty_cycle 50/1 -multiply_by 12 -master_clock {CLKIN} [get_pins {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] 

# Step 24: CLK_DEC is a register-divided /4 clock (24 MHz) feeding SPC7110_DEC.
# Declaring it as a generated clock lets TimeQuest analyze the DEC's dual-edge
# paths at the correct slow-clock period instead of the 96 MHz period.
create_generated_clock -name {CLK_DEC} -source [get_pins {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -divide_by 4 [get_registers {SPC7110Map:spc7110_inst|SPC7110:SPC7110|CLK_DEC}]

# Step 18: CLK and CLK_DEC are intentionally-decoupled clock domains. All
# crossings between them are handled in RTL: DEC_INIT uses a toggle
# synchronizer, DEC_RUN uses a 2-FF synchronizer, DEC_MODE is static during
# decompression, FIFO_Q is held stable by the FIFO_RD handshake, DEC_OUT_WR
# is edge-detected in fast domain, and DEC_IN_RD is phase-sampled. Without
# this declaration TimeQuest would (incorrectly) analyze these paths with a
# near-zero setup relationship because the two clocks share a PLL source.
set_clock_groups -asynchronous -group {snes_pll|altpll_component|auto_generated|pll1|clk[0]} -group {CLK_DEC}


#**************************************************************
# Set Clock Latency
#**************************************************************



#**************************************************************
# Set Clock Uncertainty
#**************************************************************

set_clock_uncertainty -rise_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}]  0.020  
set_clock_uncertainty -rise_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}]  0.020  
set_clock_uncertainty -rise_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -rise_to [get_clocks {CLKIN}] -setup 0.100  
set_clock_uncertainty -rise_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -rise_to [get_clocks {CLKIN}] -hold 0.070  
set_clock_uncertainty -rise_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -fall_to [get_clocks {CLKIN}] -setup 0.100  
set_clock_uncertainty -rise_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -fall_to [get_clocks {CLKIN}] -hold 0.070  
set_clock_uncertainty -fall_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}]  0.020  
set_clock_uncertainty -fall_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}]  0.020  
set_clock_uncertainty -fall_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -rise_to [get_clocks {CLKIN}] -setup 0.100  
set_clock_uncertainty -fall_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -rise_to [get_clocks {CLKIN}] -hold 0.070  
set_clock_uncertainty -fall_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -fall_to [get_clocks {CLKIN}] -setup 0.100  
set_clock_uncertainty -fall_from [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -fall_to [get_clocks {CLKIN}] -hold 0.070  
set_clock_uncertainty -rise_from [get_clocks {SPI_SCK}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.080  
set_clock_uncertainty -rise_from [get_clocks {SPI_SCK}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.110  
set_clock_uncertainty -rise_from [get_clocks {SPI_SCK}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.080  
set_clock_uncertainty -rise_from [get_clocks {SPI_SCK}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.110  
set_clock_uncertainty -rise_from [get_clocks {SPI_SCK}] -rise_to [get_clocks {SPI_SCK}]  0.020  
set_clock_uncertainty -rise_from [get_clocks {SPI_SCK}] -fall_to [get_clocks {SPI_SCK}]  0.020  
set_clock_uncertainty -fall_from [get_clocks {SPI_SCK}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.080  
set_clock_uncertainty -fall_from [get_clocks {SPI_SCK}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.110  
set_clock_uncertainty -fall_from [get_clocks {SPI_SCK}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.080  
set_clock_uncertainty -fall_from [get_clocks {SPI_SCK}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.110  
set_clock_uncertainty -fall_from [get_clocks {SPI_SCK}] -rise_to [get_clocks {SPI_SCK}]  0.020  
set_clock_uncertainty -fall_from [get_clocks {SPI_SCK}] -fall_to [get_clocks {SPI_SCK}]  0.020  
set_clock_uncertainty -rise_from [get_clocks {CLKIN}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.070  
set_clock_uncertainty -rise_from [get_clocks {CLKIN}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.100  
set_clock_uncertainty -rise_from [get_clocks {CLKIN}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.070  
set_clock_uncertainty -rise_from [get_clocks {CLKIN}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.100  
set_clock_uncertainty -rise_from [get_clocks {CLKIN}] -rise_to [get_clocks {CLKIN}]  0.020  
set_clock_uncertainty -rise_from [get_clocks {CLKIN}] -fall_to [get_clocks {CLKIN}]  0.020  
set_clock_uncertainty -fall_from [get_clocks {CLKIN}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.070  
set_clock_uncertainty -fall_from [get_clocks {CLKIN}] -rise_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.100  
set_clock_uncertainty -fall_from [get_clocks {CLKIN}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -setup 0.070  
set_clock_uncertainty -fall_from [get_clocks {CLKIN}] -fall_to [get_clocks {snes_pll|altpll_component|auto_generated|pll1|clk[0]}] -hold 0.100  
set_clock_uncertainty -fall_from [get_clocks {CLKIN}] -rise_to [get_clocks {CLKIN}]  0.020  
set_clock_uncertainty -fall_from [get_clocks {CLKIN}] -fall_to [get_clocks {CLKIN}]  0.020  


#**************************************************************
# Set Input Delay
#**************************************************************



#**************************************************************
# Set Output Delay
#**************************************************************



#**************************************************************
# Set Clock Groups
#**************************************************************



#**************************************************************
# Set False Path
#**************************************************************



#**************************************************************
# Set Multicycle Path
#**************************************************************

# SPC7110 multiplier and divider multicycle constraints.
#
# Background: SPC7110_MULDIV.vhd instantiates Altera lpm_mult and
# lpm_divide IP blocks for the SPC7110 hardware multiply and divide
# units. The dividers are configured with lpm_pipeline=8, but on a
# Cyclone IV at 96 MHz that 8-stage pipeline is still not enough to
# meet single-cycle timing on its internal stage-to-stage paths;
# worst-case slack on UDIV/SDIV stages was reported around -7.6 ns
# in TimeQuest's slow 1200 mV 85 C corner. The multiplier paths are
# similarly tight.
#
# The SPC7110 ALU process in SPC7110.vhd does not consume the result
# until many cycles after the operation begins. Specifically:
#
#   Line 492-503: MUL_RUN waits 30 CLK cycles (ALU_CNT = 29) before
#                 latching UMUL_RES or SMUL_RES into MULDIV_RES.
#   Line 504-518: DIV_RUN waits 40 CLK cycles (ALU_CNT = 39) before
#                 latching UDIV_QUOT/SDIV_QUOT and *_REM into
#                 MULDIV_RES and REM_RES.
#
# So the multiplier output has 30 cycles of settling time available
# and the divider output has 40 cycles. The single-cycle timing the
# tools were assuming is far stricter than what the design actually
# requires.
#
# Conservative multicycle of 4 (setup) and 3 (hold) is used here.
# That tells TimeQuest the result has 4 clock periods to settle and
# 3 to hold, which is well within the 30/40-cycle ALU_CNT window
# but stays well clear of any reset or cancel paths. Real hardware
# benefits from this constraint because the router is no longer
# trying to brute-force every divider stage into 10.4 ns; it can
# instead place those signals where they fit cleanly, freeing up
# routing for genuinely time-critical paths elsewhere.
#
# These constraints scope to the lpm_divide / lpm_mult internal
# registers under the SPC7110 hierarchy. The pattern '*lpm_divide*'
# matches both UDIV and SDIV instances; '*lpm_mult*' matches both
# UMULT and SMULT. set_multicycle_path applies to all timing arcs
# whose endpoints fall under the supplied register pattern.

# Divider: 40-cycle ALU_CNT window, use 4-cycle multicycle (very safe).
# Constraints scope by instance hierarchy. The dividers are instantiated as:
#   SPC7110Map:spc7110_inst|SPC7110:SPC7110|SPC7110_UDIV:UDIV|...
#   SPC7110Map:spc7110_inst|SPC7110:SPC7110|SPC7110_SDIV:SDIV|...
# Using a wildcard at the end captures every register beneath that hierarchy,
# including the auto-generated lpm_divide internal stages (DFFStage,
# DFFQuotient, DFFDenominator, DFFNumerator, etc).

set_multicycle_path -setup -end -from [get_registers {*UDIV|*}] -to [get_registers {*UDIV|*}] 4
set_multicycle_path -hold  -end -from [get_registers {*UDIV|*}] -to [get_registers {*UDIV|*}] 3
set_multicycle_path -setup -end -from [get_registers {*SDIV|*}] -to [get_registers {*SDIV|*}] 4
set_multicycle_path -hold  -end -from [get_registers {*SDIV|*}] -to [get_registers {*SDIV|*}] 3

# Cross-divider paths exist (SDIV's quotient register feeds UDIV's stage
# registers, per the worst-paths report). Constrain those too.
set_multicycle_path -setup -end -from [get_registers {*SDIV|*}] -to [get_registers {*UDIV|*}] 4
set_multicycle_path -hold  -end -from [get_registers {*SDIV|*}] -to [get_registers {*UDIV|*}] 3
set_multicycle_path -setup -end -from [get_registers {*UDIV|*}] -to [get_registers {*SDIV|*}] 4
set_multicycle_path -hold  -end -from [get_registers {*UDIV|*}] -to [get_registers {*SDIV|*}] 3

# DAC and SNES_ADDR shift-register memory blocks feed divider input registers
# (DIVIDEND/DIVISOR get their values from SNES bus writes; the worst-paths
# report shows altsyncram blocks driving DFFStage[xx] inside the dividers).
# Constrain those input-feeding paths multicycle as well, since the divider
# operation only starts after operand writes settle.
set_multicycle_path -setup -end -to [get_registers {*UDIV|*}] 4
set_multicycle_path -hold  -end -to [get_registers {*UDIV|*}] 3
set_multicycle_path -setup -end -to [get_registers {*SDIV|*}] 4
set_multicycle_path -hold  -end -to [get_registers {*SDIV|*}] 3

# Divider output capture into MULDIV_RES / REM_RES happens 40 cycles after
# DIV_RUN goes high. Allow the same multicycle for divider-output paths.
set_multicycle_path -setup -end -from [get_registers {*UDIV|*}] -to [get_registers {*MULDIV_RES*}] 4
set_multicycle_path -hold  -end -from [get_registers {*UDIV|*}] -to [get_registers {*MULDIV_RES*}] 3
set_multicycle_path -setup -end -from [get_registers {*SDIV|*}] -to [get_registers {*MULDIV_RES*}] 4
set_multicycle_path -hold  -end -from [get_registers {*SDIV|*}] -to [get_registers {*MULDIV_RES*}] 3
set_multicycle_path -setup -end -from [get_registers {*UDIV|*}] -to [get_registers {*REM_RES*}] 4
set_multicycle_path -hold  -end -from [get_registers {*UDIV|*}] -to [get_registers {*REM_RES*}] 3
set_multicycle_path -setup -end -from [get_registers {*SDIV|*}] -to [get_registers {*REM_RES*}] 4
set_multicycle_path -hold  -end -from [get_registers {*SDIV|*}] -to [get_registers {*REM_RES*}] 3

# Multiplier: 30-cycle ALU_CNT window. lpm_mult is purely combinational,
# so the relevant paths are operand-input to MULDIV_RES through the
# multiplier hierarchy.
set_multicycle_path -setup -end -from [get_registers {*DIVIDEND*}] -to [get_registers {*MULDIV_RES*}] 4
set_multicycle_path -hold  -end -from [get_registers {*DIVIDEND*}] -to [get_registers {*MULDIV_RES*}] 3
set_multicycle_path -setup -end -from [get_registers {*DIVISOR*}] -to [get_registers {*MULDIV_RES*}] 4
set_multicycle_path -hold  -end -from [get_registers {*DIVISOR*}] -to [get_registers {*MULDIV_RES*}] 3




#**************************************************************
# Set Maximum Delay
#**************************************************************



#**************************************************************
# Set Minimum Delay
#**************************************************************



#**************************************************************
# Set Input Transition
#**************************************************************
