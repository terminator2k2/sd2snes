library STD;
use STD.TEXTIO.ALL;
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.all;

entity SPC7110Map is
	port(
		MCLK			: in std_logic;
		RST_N			: in std_logic;
		ENABLE		: in std_logic := '1';

		CA   			: in std_logic_vector(23 downto 0);
		DI				: in std_logic_vector(7 downto 0);
		DO				: out std_logic_vector(7 downto 0);
		CPURD_N		: in std_logic;
		CPUWR_N		: in std_logic;
		
		PA				: in std_logic_vector(7 downto 0);
		PARD_N		: in std_logic;
		PAWR_N		: in std_logic;
		
		ROMSEL_N		: in std_logic;
		RAMSEL_N		: in std_logic;
		-- SD2SNES PSRAM timing helper: asserted by the wrapper during the
		-- SNES CPU high phase when the raw address bus points at PROM.
		-- This lets the slow PSRAM be returned to the SNES PROM address
		-- before SYSCLKR_CE, instead of one synchronized edge later.
		SNES_PROM_PRIO	: in std_logic := '0';
		
		SYSCLKF_CE	: in std_logic;
		SYSCLKR_CE	: in std_logic;
		REFRESH		: in std_logic;
		
		IRQ_N			: out std_logic;

		ROM_ADDR		: out std_logic_vector(22 downto 0);
		ROM_Q			: in  std_logic_vector(15 downto 0);
		ROM_CE_N		: out std_logic;
		ROM_OE_N		: out std_logic;
		ROM_WORD		: out std_logic;
		-- Asserted when ROM_ADDR currently has the +1 DROM bank shift applied.
		-- Added for SD2SNES port so the wrapper can subtract the shift before
		-- driving PSRAM. No effect on MiSTer (leave unconnected there).
		ROM_IS_DROM	: out std_logic;
		-- Level signal: high whenever the SPC7110 core is waiting for or
		-- currently servicing a DROM access (i.e. the core's DROM_READ is
		-- asserted). This asserts EARLY  -  before the next SYSCLKF slot
		-- actually drives PSRAM  -  so the SD2SNES wrapper can preempt any
		-- MCU bus activity that would collide with the incoming DROM
		-- transaction. Without this, an MCU access that started during
		-- the previous SNES slot can straddle SYSCLKF and corrupt the
		-- decompressor's FIFO read. No effect on MiSTer (SDRAM latency
		-- is short enough that collisions are inherently avoided).
		DROM_PENDING	: out std_logic;
		
		BSRAM_ADDR	: out std_logic_vector(19 downto 0);
		BSRAM_D		: out std_logic_vector(7 downto 0);
		BSRAM_Q		: in  std_logic_vector(7 downto 0);
		BSRAM_CE_N	: out std_logic;
		BSRAM_OE_N	: out std_logic;
		BSRAM_WE_N	: out std_logic;

		MAP_ACTIVE  : out std_logic;
		MAP_CTRL		: in std_logic_vector(7 downto 0);
		ROM_MASK		: in std_logic_vector(23 downto 0);
		BSRAM_MASK	: in std_logic_vector(23 downto 0);
		
		EXT_RTC		: in std_logic_vector(64 downto 0)
	);
end SPC7110Map;


architecture rtl of SPC7110Map is

	signal PROM_OE_N 				: std_logic;
	
	signal SPC7110_DROM_A 		: std_logic_vector(22 downto 0);
	signal SPC7110_DROM_DO		: std_logic_vector(7 downto 0);
	signal SPC7110_DROM_OE_N	: std_logic;
	signal SPC7110_DROM_RDY 	: std_logic;
	signal SNES_ROM_A 			: std_logic_vector(22 downto 0);
	signal SNES_DROM_A 			: std_logic_vector(22 downto 0);
	signal SNES_DROM_OE_N 		: std_logic;
	
	signal SRAM_CE_N 				: std_logic;
	
	signal RTC_DI 					: std_logic_vector(3 downto 0);
	signal RTC_DO 					: std_logic_vector(3 downto 0);
	signal RTC_CE 					: std_logic;
	signal RTC_CK 					: std_logic;
		
	signal SPC7110_DO 			: std_logic_vector(7 downto 0);
	signal SNES_ROM_ACTIVE 		: std_logic;
	signal SPC7110_DROM_ACTIVE	: std_logic;
	signal ROM_RD 					: std_logic;
	-- SD2SNES port note: extended from a single register to an 8-bit shift
	-- register. MiSTer uses SDRAM (~2-cycle latency); SD2SNES uses PSRAM
	-- (~8-cycle latency at 96 MHz). DROM_RDY must fire after the PSRAM
	-- data is valid, not after the 2-cycle SDRAM delay. ROM_RD_LATE now
	-- asserts ~8 cycles after ROM_RD, ensuring the core latches valid data.
	signal ROM_RD_LATE 			: std_logic_vector(7 downto 0);
	
	signal MAP_SEL	  				: std_logic;

	-- Step 29: internal copies of ROM_ADDR and the DROM-path flag so they can
	-- be read back by the DROM capture process below. Without these, VHDL
	-- disallows reading the output ports from within the same architecture.
	signal ROM_ADDR_INT    : std_logic_vector(22 downto 0);
	signal ROM_IS_DROM_INT : std_logic;
	
begin
	
	MAP_SEL <= '1' when MAP_CTRL(7 downto 4) = X"D" else '0';
	MAP_ACTIVE <= MAP_SEL;

	SPC7110 : entity work.SPC7110
	port map(
		RST_N				=> RST_N and MAP_SEL,
		CLK				=> MCLK,
		ENABLE			=> ENABLE,

		CA					=> CA,
		DO					=> SPC7110_DO,
		DI					=> DI,
		CPURD_N			=> CPURD_N,
		CPUWR_N			=> CPUWR_N,
		
		SYSCLKF_CE		=> SYSCLKF_CE,
		SYSCLKR_CE		=> SYSCLKR_CE,

		DROM_A			=> SPC7110_DROM_A,
		DROM_OE_N		=> SPC7110_DROM_OE_N,
		DROM_DO			=> ROM_Q(7 downto 0),
		DROM_RDY			=> SPC7110_DROM_RDY,
		
		PROM_OE_N		=> PROM_OE_N,
		SNES_DROM_A		=> SNES_DROM_A,
		SNES_DROM_OE_N	=> SNES_DROM_OE_N,
		SRAM_CE_N		=> SRAM_CE_N,
		
		RTC_DO			=> RTC_DI,
		RTC_DI			=> RTC_DO,
		RTC_CE			=> RTC_CE,
		RTC_CK			=> RTC_CK

	);

	
	RTC : entity work.RTC4513
	port map(
		CLK			=> MCLK,
		ENABLE		=> ENABLE,

		DO				=> RTC_DO,
		DI				=> RTC_DI,
		CE				=> RTC_CE,
		CK				=> RTC_CK,
		
		EXT_RTC		=> EXT_RTC
	);
	
	
	process(MCLK, RST_N)
	begin
		if RST_N = '0' then
			SNES_ROM_ACTIVE <= '0';
			SPC7110_DROM_ACTIVE <= '0';
			SPC7110_DROM_RDY <= '0';
			ROM_RD_LATE <= (others => '0');
		elsif rising_edge(MCLK) then
			if SYSCLKF_CE = '1' then
				SPC7110_DROM_ACTIVE <= not SPC7110_DROM_OE_N;
				SNES_ROM_ACTIVE <= '0';
			elsif SYSCLKR_CE = '1' then
				SPC7110_DROM_ACTIVE <= '0';
				SNES_ROM_ACTIVE <= '1';
			end if;
			
			-- Shift register: ROM_RD -> ROM_RD_LATE(0) -> (1) -> ... -> (7).
			-- Count only while the core DROM address is actually present on PSRAM.
			-- If the fast SNES PROM path steals the bus, restart the delay so
			-- DROM_RDY cannot fire from a stale pre-steal ROM_RD pulse.
			if SPC7110_DROM_ACTIVE = '0' or SNES_PROM_PRIO = '1' then
				ROM_RD_LATE <= (others => '0');
			else
				ROM_RD_LATE <= ROM_RD_LATE(6 downto 0) & ROM_RD;
			end if;
						
			SPC7110_DROM_RDY <= '0';
			if SPC7110_DROM_RDY = '0' and ROM_RD_LATE(7) = '1' and SPC7110_DROM_ACTIVE = '1' and SNES_PROM_PRIO = '0' then
				SPC7110_DROM_RDY <= '1';
			end if;
		end if;
	end process;
	
	process(MCLK, RST_N)
	begin
		if RST_N = '0' then
			ROM_RD <= '0';
		elsif rising_edge(MCLK) then
			ROM_RD <= '0';
			if SYSCLKR_CE = '1' or SYSCLKF_CE = '1' then
				ROM_RD <= '1';
			end if;
		end if;
	end process;
	
	-- PSRAM address for SNES PROM reads: computed combinatorially from CA so the
	-- PSRAM sees the new address as soon as the SNES address bus is stable (~120 ns
	-- before SNES_READ_IN falls).  The original registered version only updated at
	-- SYSCLKR_CE (~15 ns into PHI2 HIGH), leaving only ~85 ns for a 70 ns PSRAM --
	-- not enough margin when SNES_READ falls early or SYSCLKR_CE fires late (+/-
	-- one CLK2 phase = 10 ns each), causing the intermittent 20 ns setup violation.
	SNES_ROM_A <= (not CA(23) and CA(22)) & (not CA(23) and CA(22)) & "0" & CA(19 downto 0);

	-- SYSCLK |___|---|
	-- 0 - slot for SPC7110 for DROM access if need, else same SNES access (for sdram refresh)
	-- 1 - slot for SNES for PROM/DROM access, first 1 MByte - PROM, rest - DROM
	process(SNES_ROM_A, SPC7110_DROM_A, SNES_DROM_A, SPC7110_DROM_ACTIVE, SNES_DROM_OE_N, SNES_ROM_ACTIVE, SNES_PROM_PRIO)
	begin
		if SNES_PROM_PRIO = '1' then
			ROM_ADDR_INT <= SNES_ROM_A;
		elsif SNES_ROM_ACTIVE = '0' then
			if SPC7110_DROM_ACTIVE = '1' then
				ROM_ADDR_INT <= std_logic_vector(unsigned(SPC7110_DROM_A(22 downto 20)) + "001") & SPC7110_DROM_A(19 downto 0);
			else
				ROM_ADDR_INT <= SNES_ROM_A;
			end if;
		else
			if SNES_DROM_OE_N = '0' then
				ROM_ADDR_INT <= std_logic_vector(unsigned(SNES_DROM_A(22 downto 20)) + "001") & SNES_DROM_A(19 downto 0);
			else
				ROM_ADDR_INT <= SNES_ROM_A;
			end if;
		end if;
	end process;
	ROM_ADDR    <= ROM_ADDR_INT;
	ROM_CE_N 	<= '0';
	ROM_OE_N 	<= not ROM_RD;
	ROM_WORD		<= '0';
	-- '1' when the ROM_ADDR mux above selected a branch that applies +1 to bits [22:20]
	ROM_IS_DROM_INT <= (not SNES_PROM_PRIO) and
							((not SNES_ROM_ACTIVE and SPC7110_DROM_ACTIVE) or
							(SNES_ROM_ACTIVE and not SNES_DROM_OE_N));
	ROM_IS_DROM	<= ROM_IS_DROM_INT;

	-- Early-warning level signal: '1' whenever the core has DROM_READ
	-- asserted. This goes high inside WS_LOAD_FIFO1 (or WS_LOAD_ADDR2 /
	-- WS_DP_READ1) at MCLK rate, well before the next SYSCLKF_CE latches
	-- SPC7110_DROM_ACTIVE. Wrapper uses this to keep the MCU off the
	-- PSRAM bus during the entire pending-DROM window.
	DROM_PENDING <= not SPC7110_DROM_OE_N;

	BSRAM_ADDR <= ("0000000" & CA(12 downto 0)) and BSRAM_MASK(19 downto 0);
	BSRAM_D    <= DI;
	BSRAM_CE_N <= SRAM_CE_N;
	BSRAM_OE_N <= CPURD_N;
	BSRAM_WE_N <= CPUWR_N;

	DO <= ROM_Q(7 downto 0) when PROM_OE_N = '0' or SNES_DROM_OE_N = '0' else
			BSRAM_Q when SRAM_CE_N = '0' else 
			SPC7110_DO;
			
	IRQ_N <= '1';


end rtl;
