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
 * was already waiting for the next packet. Printed on the UART and written to /sd2snes/xcaudio.txt every
 * 1,500 packets (30 s of music) and when the game is left (long reset, reset to menu: xc_audio_report()).
 */
#include <string.h>
#include "config.h"
#include "fpga_spi.h"
#include "xc_audio.h"
#ifdef CONFIG_MK3_STM32
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
#define XC_HIST        48              /* 1 ms buckets; the last one is "47 ms or more" */

#ifdef CONFIG_MK3_STM32
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

static struct {
	uint32_t last_poll;          /* cycle count at the last poll */
	uint32_t last_done;          /* cycle count at the end of the last job */
	uint8_t first_poll_after_job;
	uint8_t log_due;
	uint32_t jobs, waiting;      /* jobs; jobs already waiting at the first poll after the previous one */
	uint64_t svc_sum, dec_sum;   /* cycles: whole service (read packet .. done), decode alone */
	uint32_t svc_max, dec_max, gap_max;
	uint32_t gaps_over_5ms, gaps_over_20ms;
	uint32_t svc_hist[XC_HIST];  /* per-job service time + the poll gap before it (ms) */
	uint32_t gap_hist[XC_HIST];  /* poll gaps (ms), all polls */
} xs IN_AHBRAM;                  /* AHB RAM on the LPC1756, whose main RAM is short (cleared in xc_audio_init) */

/* SPI to the FPGA, one byte at a time, the way the stock firmware talks to it.
 *  - spi_rx_block()/spi_tx_block() (FPGA_RX_BLOCK/FPGA_TX_BLOCK) are never used with the FPGA elsewhere and are
 *    unsafe here. spi_rx_block() hangs for lengths that are a multiple of 4 on an aligned buffer: its DMA path
 *    uses peripheral flow control, which SPI does not support, so the transfer-complete flag never sets. And
 *    both run bytes back to back, while spi.v needs a gap after each byte (it loads the next read value and
 *    latches a written byte a few CLK2 cycles after the byte ends).
 *  - reads: FPGA_RX_BYTE() waits for the bus to go idle before each byte (as get_msu_pointer() does);
 *  - writes: FPGA_TX_BYTE() + FPGA_TX_SYNC() leaves the same gap after each byte. */
#ifdef CONFIG_MK3_STM32
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
#ifdef CONFIG_MK3_STM32
	decoder_ok = opus_decoder_get_size(2) <= (int)sizeof(decoder_mem)
		&& opus_decoder_init((OpusDecoder*)decoder_mem, 24000, 2) == OPUS_OK;
#endif
	xc_audio_packets = 0;
	xc_audio_errors = 0;
	status_polls = 0;
	halt_reported = 0;
	memset(&xs, 0, sizeof(xs));
	log_writes = 0;
	in_service = 0;
#ifdef XC_CYCLES_ON
	XC_CYCLES_ON();
#endif
	xs.last_poll = XC_CYCLES();
	active = 1;
}

static void hist_add(uint32_t* h, uint32_t cycles)
{
	uint32_t ms = cycles / (XC_CYC_PER_US * 1000u);
	h[ms < XC_HIST ? ms : XC_HIST - 1]++;
}

static uint32_t cyc_us(uint64_t c) { return (uint32_t)(c / XC_CYC_PER_US); }

/* p-th percentile (per mille) of a 1 ms histogram, in ms (upper bucket edge) */
static uint32_t hist_pct(const uint32_t* h, uint32_t permille)
{
	uint32_t n = 0, acc = 0;
	for(int i = 0; i < XC_HIST; i++) n += h[i];
	if(!n) return 0;
	for(int i = 0; i < XC_HIST; i++) {
		acc += h[i];
		if((uint64_t)acc * 1000u >= (uint64_t)n * permille) return i + 1;
	}
	return XC_HIST;
}

static int format_stats(char* b, int size)
{
	uint32_t j = xs.jobs ? xs.jobs : 1;
	int n = snprintf(b, size,
		"Xeno Crisis audio (MCU decode service): %lu packets, %lu errors, mixer already waiting for %lu\r\n"
		"  service per packet (us): avg %lu, max %lu; p50 %lu ms, p99 %lu ms, p99.9 %lu ms (with the poll gap before)\r\n"
		"  decode alone (us): avg %lu, max %lu\r\n"
		"  poll gaps: max %lu us, over 5 ms %lu, over 20 ms %lu; p99.9 %lu ms\r\n",
		(unsigned long)xs.jobs, (unsigned long)xc_audio_errors, (unsigned long)xs.waiting,
		(unsigned long)cyc_us(xs.svc_sum / j), (unsigned long)cyc_us(xs.svc_max),
		(unsigned long)hist_pct(xs.svc_hist, 500), (unsigned long)hist_pct(xs.svc_hist, 990),
		(unsigned long)hist_pct(xs.svc_hist, 999),
		(unsigned long)cyc_us(xs.dec_sum / j), (unsigned long)cyc_us(xs.dec_max),
		(unsigned long)cyc_us(xs.gap_max), (unsigned long)xs.gaps_over_5ms, (unsigned long)xs.gaps_over_20ms,
		(unsigned long)hist_pct(xs.gap_hist, 999));
	if(n < 0 || n >= size) return size - 1;
	for(int k = 0; k < 2; k++) {
		const uint32_t* h = k ? xs.gap_hist : xs.svc_hist;
		int m = snprintf(b + n, size - n, "  %s ms histogram:", k ? "poll gap" : "service");
		if(m < 0 || m >= size - n) return size - 1;
		n += m;
		for(int i = 0; i < XC_HIST; i++) {
			if(!h[i]) continue;
			m = snprintf(b + n, size - n, " %d:%lu", i, (unsigned long)h[i]);
			if(m < 0 || m >= size - n) return size - 1;
			n += m;
		}
		m = snprintf(b + n, size - n, "\r\n");
		if(m < 0 || m >= size - n) return size - 1;
		n += m;
	}
	return n;
}

/* when the game is left: statistics to the UART and to /sd2snes/xcaudio.txt */
static char stats_buf[1024] IN_AHBRAM;


/* statistics to the UART and to /sd2snes/xcaudio.txt (rewritten each time) */
static void write_log(const char* why)
{
	int n = snprintf(stats_buf, sizeof(stats_buf), "[%s, log #%lu]\r\n", why, (unsigned long)++log_writes);
	if(n < 0 || n >= (int)sizeof(stats_buf)) n = 0;
	n += format_stats(stats_buf + n, sizeof(stats_buf) - n);
	printf("%s", stats_buf);
#ifndef XC_HOST_TEST
	FIL f;
	UINT bw = 0;
	FRESULT r = f_open(&f, "/sd2snes/xcaudio.txt", FA_WRITE | FA_CREATE_ALWAYS);
	if(r == FR_OK) {
		r = f_write(&f, stats_buf, n, &bw);
		FRESULT rc = f_close(&f);
		if(r == FR_OK) r = rc;
	}
	if(r != FR_OK) printf("xcaudio.txt: write failed (FatFs error %d)\n", (int)r);
#else
	(void)n;
#endif
}

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
	if((st & 1) && !halt_reported) {
		halt_reported = 1;
		printf("Xeno Crisis soft CPU halted: code %08lx at %08lx\n", code, addr);
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
	hist_add(xs.gap_hist, gap);
	if(++status_polls >= 100000) {
		status_polls = 0;
		check_soc();
	}
	uint8_t st = read_status(&len);

	if(st & XCA_ST_RESET) {
#ifdef CONFIG_MK3_STM32
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

#ifndef CONFIG_MK3_STM32
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
	xs.svc_sum += svc;
	xs.dec_sum += td;
	if(svc > xs.svc_max) xs.svc_max = svc;
	if(td > xs.dec_max) xs.dec_max = td;
	hist_add(xs.svc_hist, svc);
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
	if(!active) return;
	in_service = 1;
	xc_audio_poll();
	in_service = 0;
}
