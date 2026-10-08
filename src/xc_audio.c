/* Xeno Crisis on sd2snes: Opus decode service on the MCU (see xc_audio.h).
 *
 * mk3 with STM32F401 (firmware.stm, CONFIG_MK3_STM32): decodes the music packets the soft CPU's mixer submits.
 * mk3 with LPC1756 (firmware.im3): the Opus decoder does not fit (it needs ~26.5 KB of contiguous RAM plus ~11 KB
 * of stack; the LPC1756 has 16 KB of main RAM and 16 KB of AHB RAM, and the stock firmware leaves ~5 KB and
 * ~7 KB of them). There every job is answered at once as "nothing decoded" (ret 0, final range 0): the mixer
 * treats the track as ended (as the RP2040 firmware does with corrupted music data) and keeps mixing the sound
 * effects, which play normally. The music is silent.
 *
 * Bit-exactness: the decoder must produce exactly what the RP2040 firmware's libopus 1.3.1 produces.
 * Build libopus with FIXED_POINT, DISABLE_FLOAT_API, OPUS_FAST_INT64=0, the SILK ARMv5E macros
 * (OPUS_ARM_INLINE_ASM/EDSP/MEDIA for silk/ only) and M4_EXACT (celt/fixed_generic.h: 64-bit forms of
 * MULT16_32_Q16/P16/Q15, which are identical to the 16x16 split). Do NOT enable the CELT ARMv5E macros:
 * their MULT16_32_Q15 drops a bit and changes the output. See m4bench/ for the check.
 *
 * Timing: about 600k cycles per packet on a Cortex-M4 (instruction-count model, before flash wait states;
 * hot CELT files at -O2), i.e. about 7 ms at 84 MHz, for one packet every 20 ms. The mixer keeps up to
 * 6 packets (120 ms) of decoded music and sends the next packet as soon as one is decoded, so the whole
 * service (poll latency + transfer + decode) must stay below 20 ms per packet on average. The main loop
 * therefore calls xc_audio_poll() often, and long MCU jobs (the SRAM CRC) call xc_audio_service() in between.
 * The decoder is never reset between tracks (the firmware doesn't either).
 *
 * Statistics (DWT cycle counter): service time per packet, decode time, poll gaps, and how often the mixer
 * was already waiting for the next packet. Printed on the UART and written to /sd2snes/xc_debug.txt every
 * 1,500 packets (30 s of music) and when the game is left (long reset, reset to menu: xc_audio_report()).
 * xc_debug.txt (it was xcaudio.txt) starts with the load results: the FPGA core, and whether
 * xenocrisis_rp2040.bin and xc_soc.bin loaded (xc_load.c); it is first written right after loading
 * (xc_debug_loaded()), so it is there even when the game does not start.
 */
#include <string.h>
#include "config.h"
#if defined(CONFIG_MK3_STM32) && !defined(XC_MSU_DIAG)
#define XC_OPUS 1    /* the Opus decoder (firmware.stm; not in the MSU-1 diagnostic build) */
#endif
#include "fpga_spi.h"
#include "xc_audio.h"
#include "msu1.h"
#include "smc.h"
#include "memory.h"
extern snes_romprops_t romprops;
#ifdef XC_OPUS
#include "opus.h"
#endif
#include "uart.h"
#ifndef XC_HOST_TEST
#include "ff.h"
#endif

/* cycle counter: the Cortex-M3/M4 DWT (enabled in xc_audio_init) */
#ifndef XC_CYCLES
#define XC_DEMCR       (*(volatile uint32_t*)0xE000EDFCu)
#define XC_DWT_CTRL    (*(volatile uint32_t*)0xE0001000u)
#define XC_CYCLES()    (*(volatile uint32_t*)0xE0001004u)
#define XC_CYCLES_ON() do { XC_DEMCR |= 1u << 24; XC_DWT_CTRL |= 1u; } while(0)
#endif
#define XC_CYC_PER_US  (CONFIG_CPU_FREQUENCY / 1000000)

#ifdef XC_OPUS
/* opus_decoder_get_size(2) is 26,496 bytes for this build; keep a margin */
static uint32_t decoder_mem[27136 / 4];
static uint8_t packet[1536];
static int16_t pcm[480 * 2];
static int decoder_ok;
#endif
uint32_t xc_audio_packets, xc_audio_errors;
static uint32_t status_polls;
static uint8_t halt_reported;
static uint8_t active;
static uint8_t in_service;     /* xc_audio_poll() called from inside another MCU job (CRC, save) */
static uint32_t log_writes;
static uint32_t log_ms;        /* time the previous log write took */
static uint32_t soc_code, soc_addr;
static uint8_t soc_st;         /* last soft CPU status: bit 0 halted, bit 1 running */
#ifdef XC_MSU_DIAG
uint32_t xc_msu_mcu[4];        /* MSU-1 music, from msu1_loop(): track requests, last track, ctrl writes, refills */
#endif

static void read_perf(uint32_t* w);
#ifdef XC_MSU_DIAG
static char memres[480];
static uint8_t mem_checked;
static void mem_check(void);
#endif
static void check_soc(void);

static struct {
	uint32_t last_poll;          /* cycle count at the last poll */
	uint32_t last_done;          /* cycle count at the end of the last job */
	uint8_t first_poll_after_job;
	uint8_t log_due;
	uint32_t jobs, waiting;      /* jobs; jobs already waiting at the first poll after the previous one */
	uint32_t svc_sum, dec_sum;   /* us: whole service (read packet .. done), decode alone (32-bit: no 64-bit division in the image) */
	uint32_t svc_max, dec_max, gap_max;
	uint32_t gaps_over_5ms, gaps_over_20ms, svc_over_20ms;
	uint32_t perf[8];            /* FPGA counters at the previous log (xc_top "perf") */
} xs IN_AHBRAM;                  /* AHB RAM on the LPC1756, whose main RAM is short (cleared in xc_audio_init) */

/* SPI to the FPGA, one byte at a time, the way the stock firmware talks to it.
 *  - spi_rx_block()/spi_tx_block() (FPGA_RX_BLOCK/FPGA_TX_BLOCK) are never used with the FPGA elsewhere and are
 *    unsafe here. spi_rx_block() hangs for lengths that are a multiple of 4 on an aligned buffer: its DMA path
 *    uses peripheral flow control, which SPI does not support, so the transfer-complete flag never sets. And
 *    both run bytes back to back, while spi.v needs a gap after each byte (it loads the next read value and
 *    latches a written byte a few CLK2 cycles after the byte ends).
 *  - reads: FPGA_RX_BYTE() waits for the bus to go idle before each byte (as get_msu_pointer() does);
 *  - writes: FPGA_TX_BYTE() + FPGA_TX_SYNC() leaves the same gap after each byte. */
#ifdef XC_OPUS
static void xc_rx(uint8_t* dst, uint32_t n)
{
	while(n--) *dst++ = FPGA_RX_BYTE();
}
#endif

static void xc_tx(uint8_t b)
{
	FPGA_TX_BYTE(b);
	FPGA_TX_SYNC();
}

void xc_run(uint8_t run)
{
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XC_RUN);
	xc_tx(run);
	xc_tx(0x00); /* flop */
	FPGA_DESELECT();
}

void xc_audio_init(void)
{
#ifdef XC_OPUS
	decoder_ok = opus_decoder_get_size(2) <= (int)sizeof(decoder_mem)
		&& opus_decoder_init((OpusDecoder*)decoder_mem, 24000, 2) == OPUS_OK;
#endif
	xc_audio_packets = 0;
	xc_audio_errors = 0;
	status_polls = 0;
	halt_reported = 0;
	memset(&xs, 0, sizeof(xs));
	log_writes = 0;
	log_ms = 0;
	in_service = 0;
#ifdef XC_CYCLES_ON
	XC_CYCLES_ON();
#endif
	read_perf(xs.perf);
	xs.last_poll = XC_CYCLES();
	active = 1;
}

static uint32_t cyc_us(uint32_t c) { return c / XC_CYC_PER_US; }

/* FPGA performance counters: $C7 takes a snapshot, $C8 reads it (8 words, see xc_top.v "perf") */
static void read_perf(uint32_t* w)
{
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XC_PERF_SNAP);
	FPGA_DESELECT();
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XC_PERF);
	FPGA_RX_BYTE(); /* null read */
	for(int i = 0; i < 8; i++) {
		uint32_t v = 0;
		for(int k = 0; k < 4; k++) v |= (uint32_t)FPGA_RX_BYTE() << (8 * k);
		w[i] = v;
	}
	FPGA_DESELECT();
}

static uint32_t pct(uint32_t part, uint32_t whole) { return whole >= 100u ? part / (whole / 100u) : 0; }

static int format_stats(char* b, int size)
{
	uint32_t j = xs.jobs ? xs.jobs : 1;
	uint32_t w[8], d[8];
	read_perf(w);
	for(int i = 0; i < 8; i++) d[i] = w[i] - xs.perf[i];   /* since the previous log (32-bit counters wrap) */
	d[6] = w[6];                                             /* longest tick: reset by each snapshot */
	memcpy(xs.perf, w, sizeof(w));
	int n;
#ifdef XC_MSU_DIAG
	if(romprops.has_msu1) {
		/* the mixer's counters and state (src/xc_soc/xc_mix.c "dbg", "st"): RAM 0x20040000 = SRAM chip 0x48000
		   (the soft CPU's D-cache is write-back, so they may lag a little) */
		uint32_t m[25];
		sram_readblock(m, SRAM_SAVE_ADDR + 0x48000, sizeof(m));
		n = snprintf(b, size,
			"MSU-1: soc st %u code %08lx at %08lx\r\n"
			" mixer %08lx mode %06lx: ticks %lu calls %lu sfx %lu blocks %lu defer %lu pkts %lu msu wr %lu st %02lx trk %lu\r\n"
			" state %08lx %08lx %08lx %08lx %08lx %08lx %08lx\r\n"
			" MCU: tracks %lu (last %lu) ctrl %lu refills %lu\r\n",
			soc_st, soc_code, soc_addr, m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10],
			m[11], m[12], m[13], m[14], m[15], m[16], m[17],
			xc_msu_mcu[0], xc_msu_mcu[1], xc_msu_mcu[2], xc_msu_mcu[3]);
		if((soc_st & 1) && n >= 0 && n < size) {
			if(!mem_checked) { mem_checked = 1; mem_check(); }
			n += snprintf(b + n, size - n, "%s", memres);
		}
	} else
#endif
	n = snprintf(b, size,
		"MCU decode: %lu packets, %lu errors, mixer waited %lu\r\n"
		" service us (incl. poll gap): avg %lu max %lu, >20ms %lu\r\n"
		" decode us: avg %lu max %lu\r\n"
		" poll gaps: max %lu us, >5ms %lu, >20ms %lu\r\n",
		(unsigned long)xs.jobs, (unsigned long)xc_audio_errors, (unsigned long)xs.waiting,
		(unsigned long)(xs.svc_sum / j), (unsigned long)cyc_us(xs.svc_max), (unsigned long)xs.svc_over_20ms,
		(unsigned long)(xs.dec_sum / j), (unsigned long)cyc_us(xs.dec_max),
		(unsigned long)cyc_us(xs.gap_max), (unsigned long)xs.gaps_over_5ms, (unsigned long)xs.gaps_over_20ms);
	if(n < 0 || n >= size) return size - 1;
	n += snprintf(b + n, size - n,
		"FPGA since last log: %lu cycles; stalls fetch %lu%% flash %lu%% RAM %lu%%\r\n"
		" ticks %lu, >1 frame %lu, longest %lu us; window underruns %lu\r\n",
		(unsigned long)d[0], (unsigned long)pct(d[1], d[0]), (unsigned long)pct(d[2], d[0]), (unsigned long)pct(d[3], d[0]),
		(unsigned long)d[4], (unsigned long)d[5], (unsigned long)(d[6] * 4u / 161u), (unsigned long)d[7]);
	if(n < 0 || n >= size) return size - 1;
	return n;
}

static char stats_buf[512] IN_AHBRAM;

/* the load results, at the top of every xc_debug.txt */
static int format_load(char* b, int size)
{
	int n = snprintf(b, size,
		"FPGA core: %s\r\n"
		"xenocrisis_rp2040.bin: %s\r\n"
		"xc_soc.bin: %s\r\n"
		"MSU-1 pack: %s\r\n",
		romprops.fpga_conf ? (const char*)romprops.fpga_conf : "(none)", xc_load_status(0), xc_load_status(1),
		xc_load_status(2));
	return (n < 0 || n >= size) ? size - 1 : n;
}

/* stats_buf (n bytes) to /sd2snes/xc_debug.txt (rewritten each time) */
static void write_file(int n)
{
#ifndef XC_HOST_TEST
	FIL f;
	UINT bw = 0;
	FRESULT r = f_open(&f, "/sd2snes/xc_debug.txt", FA_WRITE | FA_CREATE_ALWAYS);
	if(r == FR_OK) {
		r = f_write(&f, stats_buf, n, &bw);
		FRESULT rc = f_close(&f);
		if(r == FR_OK) r = rc;
	}
	if(r != FR_OK) printf("xc_debug.txt: error %d\n", (int)r);
#else
	(void)n;
#endif
}

void xc_debug_loaded(void)
{
	int n = snprintf(stats_buf, sizeof(stats_buf), "[game loaded]\r\n");
	if(n < 0 || n >= (int)sizeof(stats_buf)) n = 0;
	n += format_load(stats_buf + n, sizeof(stats_buf) - n);
	printf("%s", stats_buf);
	write_file(n);
}

/* the load results and the statistics to the UART and to /sd2snes/xc_debug.txt */
static void write_log(const char* why)
{
	uint32_t t0 = XC_CYCLES();
	int n = snprintf(stats_buf, sizeof(stats_buf), "[%s #%lu, last write %lu ms]\r\n", why,
		(unsigned long)++log_writes, (unsigned long)log_ms);
	if(n < 0 || n >= (int)sizeof(stats_buf)) n = 0;
	n += format_load(stats_buf + n, sizeof(stats_buf) - n);
	n += format_stats(stats_buf + n, sizeof(stats_buf) - n);
	printf("%s", stats_buf);
	write_file(n);
#ifndef XC_HOST_TEST
	log_ms = (XC_CYCLES() - t0) / (XC_CYC_PER_US * 1000u);
#endif
}

#ifdef XC_MSU_DIAG
/* Once the soft CPU has halted: read its RAM back and check what the firmware's start code wrote there.
   The RP2040 firmware's crt0 copies .data (RAM 0x200000C0-0x20004E93) from flash 0x10CDD2D4 and zeroes .bss
   (0x20004F00-0x200232BF) before anything else runs. RP2040 RAM 0x20000000 = SRAM chip 0x08000. */
static void mem_note(char** p, int* left, uint32_t addr, uint8_t exp, uint8_t got)
{
	int w = snprintf(*p, *left, " %05lx:%02x>%02x", (unsigned long)(addr & 0xFFFFF), exp, got);
	if(w > 0 && w < *left) { *p += w; *left -= w; }
}
static void mem_check(void)
{
	uint8_t a[64], b[64];
	char* p = memres;
	int left = sizeof(memres);
	uint32_t bad = 0, shown = 0;
	int w = snprintf(p, left, " .data vs flash (addr:flash>ram):");
	p += w; left -= w;
	for(uint32_t off = 0; off < 0x4DD4u; off += 64) {
		uint32_t len = 0x4DD4u - off < 64 ? 0x4DD4u - off : 64;
		sram_readblock(a, SRAM_SAVE_ADDR + 0x8000u + 0xC0u + off, len);
		sram_readblock(b, 0xCDD2D4u + off, len);
		for(uint32_t i = 0; i < len; i++) if(a[i] != b[i]) {
			bad++;
			if(shown++ < 6) mem_note(&p, &left, 0x200000C0u + off + i, b[i], a[i]);
		}
	}
	w = snprintf(p, left, " = %lu of 19924 differ\r\n .bss nonzero (addr:0>ram):", (unsigned long)bad);
	if(w > 0 && w < left) { p += w; left -= w; }
	bad = 0; shown = 0;
	for(uint32_t off = 0; off < 0x1E3C0u; off += 64) {
		sram_readblock(a, SRAM_SAVE_ADDR + 0x8000u + 0x4F00u + off, 64);
		for(uint32_t i = 0; i < 64; i++) if(a[i]) {
			bad++;
			if(shown++ < 6) mem_note(&p, &left, 0x20004F00u + off + i, 0, a[i]);
		}
	}
	sram_readblock(a, SRAM_SAVE_ADDR + 0x8000u + 0x22E68u, 8);
	w = snprintf(p, left, " = %lu of 123840\r\n claimed @20022e68: %02x %02x %02x %02x %02x %02x %02x %02x\r\n",
		(unsigned long)bad, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
	(void)w;
}

/* MSU-1 music (msu1_loop): the log without the decode service */
void xc_msu_log(const char* why)
{
	if(!log_writes) { read_perf(xs.perf); log_ms = 0; }
	check_soc();
	write_log(why);
}
#endif

void xc_audio_report(void)
{
	if(!active) return;
	active = 0;
	write_log("game left");
}

static uint8_t read_status(uint16_t* len)
{
	uint8_t st;
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XCA_STATUS);
	FPGA_RX_BYTE(); /* null read to create delay */
	st = FPGA_RX_BYTE();
	*len = FPGA_RX_BYTE();
	*len |= (uint16_t)FPGA_RX_BYTE() << 8;
	FPGA_DESELECT();
	return st;
}

/* bring-up aid: report once on the UART if the soft CPU stopped (core fault, bus fault or firmware panic) */
static void check_soc(void)
{
	uint8_t st;
	uint32_t code = 0, addr = 0;
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XC_STATUS);
	FPGA_RX_BYTE(); /* null read */
	st = FPGA_RX_BYTE();
	for(int i = 0; i < 4; i++) code |= (uint32_t)FPGA_RX_BYTE() << (8 * i);
	for(int i = 0; i < 4; i++) addr |= (uint32_t)FPGA_RX_BYTE() << (8 * i);
	FPGA_DESELECT();
	soc_st = st; soc_code = code; soc_addr = addr;
	if((st & 1) && !halt_reported) {
		halt_reported = 1;
		printf("XC halted: %08lx at %08lx\n", code, addr);
	}
}

/* the job's result: ret (opus_decode() result) and final range; raises the soft CPU's decode interrupt */
static void send_done(int32_t ret, uint32_t range)
{
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XCA_DONE);
	for(int i = 0; i < 4; i++) xc_tx((uint8_t)((uint32_t)ret >> (8 * i)));
	for(int i = 0; i < 4; i++) xc_tx((uint8_t)(range >> (8 * i)));
	xc_tx(0x00); /* flop reset */
	FPGA_DESELECT();
}

void xc_audio_poll(void)
{
	uint16_t len;
	uint32_t now = XC_CYCLES();
	uint32_t gap = now - xs.last_poll;
	xs.last_poll = now;
	if(gap > xs.gap_max) xs.gap_max = gap;
	if(gap > 5000u * XC_CYC_PER_US) xs.gaps_over_5ms++;
	if(gap > 20000u * XC_CYC_PER_US) xs.gaps_over_20ms++;
	if(++status_polls >= 100000) {
		status_polls = 0;
		check_soc();
	}
	uint8_t st = read_status(&len);

	if(st & XCA_ST_RESET) {
#ifdef XC_OPUS
		decoder_ok = opus_decoder_init((OpusDecoder*)decoder_mem, 24000, 2) == OPUS_OK;
#endif
		FPGA_SELECT();
		xc_tx(FPGA_CMD_XCA_ACKRESET);
		FPGA_DESELECT();
		return; /* pick up a job on the next poll, after the reset is acknowledged */
	}
	uint8_t first = xs.first_poll_after_job;
	xs.first_poll_after_job = 0;
	if(!(st & XCA_ST_JOB)) {
		return;
	}
	if(first) xs.waiting++;
	uint32_t t0 = now - gap;     /* the job may have been waiting since the previous poll (or the previous job) */

#ifndef XC_OPUS
	/* LPC1756: no decoder. "Nothing decoded": the mixer ends the track and keeps mixing the sound effects. */
	(void)len;
	xc_audio_packets++;
	send_done(0, 0);
	uint32_t td = 0;
#else
	if(len > sizeof(packet)) {
		len = sizeof(packet);
	}
	FPGA_SELECT();
	xc_tx(FPGA_CMD_XCA_READPKT);
	FPGA_RX_BYTE(); /* null read */
	xc_rx(packet, len);
	FPGA_DESELECT();

	int32_t ret;
	uint32_t range = 0;
	uint32_t td = XC_CYCLES();
	if(decoder_ok) {
		ret = opus_decode((OpusDecoder*)decoder_mem, packet, len, pcm, 480, 0);
		opus_decoder_ctl((OpusDecoder*)decoder_mem, OPUS_GET_FINAL_RANGE(&range));
	} else {
		ret = OPUS_INTERNAL_ERROR;
	}
	td = XC_CYCLES() - td;
	if(ret < 0) {
		xc_audio_errors++;
		memset(pcm, 0, sizeof(pcm));
	}
	xc_audio_packets++;

	FPGA_SELECT();
	xc_tx(FPGA_CMD_XCA_WRITEPCM);
	{
		const uint8_t* p = (const uint8_t*)pcm;  /* the MCU is little-endian like the RP2040 */
		for(uint32_t i = 0; i < sizeof(pcm); i++) xc_tx(p[i]);
	}
	FPGA_DESELECT();

	send_done(ret, range);
#endif
	uint32_t end = XC_CYCLES();
	uint32_t svc = end - t0;
	xs.jobs++;
	xs.svc_sum += cyc_us(svc);
	xs.dec_sum += cyc_us(td);
	if(svc > xs.svc_max) xs.svc_max = svc;
	if(td > xs.dec_max) xs.dec_max = td;
	if(svc > 20000u * XC_CYC_PER_US) xs.svc_over_20ms++;
	xs.last_done = end;
	xs.last_poll = end;          /* the service time is not a poll gap */
	xs.first_poll_after_job = 1;
	/* every 1,500 packets (30 s of music): also written during play, so the log exists even if the console
	   is just switched off. Not from inside the CRC or a save (the save has a file open); the next main loop
	   job then writes it. The mixer holds up to 100 ms of decoded music, more than the SD write takes. */
	if(xs.jobs % 1500 == 0) xs.log_due = 1;
	if(xs.log_due && !in_service) {
		xs.log_due = 0;
		write_log("during play");
		xs.last_poll = XC_CYCLES();
	}
}

/* for long MCU jobs (SRAM CRC): serve a waiting job; the caller has deselected the FPGA */
void xc_audio_service(void)
{
	if(romprops.has_msu1) { msu1_audio_service(); return; }   /* MSU-1 music: the MSU-1 audio buffer instead */
	if(!active) return;
	in_service = 1;
	xc_audio_poll();
	in_service = 0;
}
