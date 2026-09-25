/* Xeno Crisis on sd2snes: Opus decode service on the MCU (see xc_audio.h).
 *
 * Bit-exactness: the decoder must produce exactly what the RP2040 firmware's libopus 1.3.1 produces.
 * Build libopus with FIXED_POINT, DISABLE_FLOAT_API, OPUS_FAST_INT64=0, the SILK ARMv5E macros
 * (OPUS_ARM_INLINE_ASM/EDSP/MEDIA for silk/ only) and M4_EXACT (celt/fixed_generic.h: 64-bit forms of
 * MULT16_32_Q16/P16/Q15, which are identical to the 16x16 split). Do NOT enable the CELT ARMv5E macros:
 * their MULT16_32_Q15 drops a bit and changes the output. See m4bench/ for the check.
 *
 * Timing: about 385k instructions / 520k cycles per packet on a Cortex-M4 (instruction-count model),
 * i.e. about 6 ms at 84 MHz; the mixer keeps up to 6 packets (120 ms) of decoded music, so a poll every
 * few ms is plenty. The decoder is never reset between tracks (the firmware doesn't either).
 */
#include <string.h>
#include "config.h"
#include "fpga_spi.h"
#include "xc_audio.h"
#include "opus.h"
#include "uart.h"

/* opus_decoder_get_size(2) is 26,496 bytes for this build; keep a margin */
static uint32_t decoder_mem[27136 / 4];
static uint8_t packet[1536];
static int16_t pcm[480 * 2];
static int decoder_ok;
uint32_t xc_audio_packets, xc_audio_errors;
static uint32_t status_polls;
static uint8_t halt_reported;

void xc_run(uint8_t run)
{
	FPGA_SELECT();
	FPGA_TX_BYTE(FPGA_CMD_XC_RUN);
	FPGA_TX_BYTE(run);
	FPGA_TX_BYTE(0x00); /* flop */
	FPGA_DESELECT();
}

void xc_audio_init(void)
{
	decoder_ok = opus_decoder_get_size(2) <= (int)sizeof(decoder_mem)
		&& opus_decoder_init((OpusDecoder*)decoder_mem, 24000, 2) == OPUS_OK;
	xc_audio_packets = 0;
	xc_audio_errors = 0;
	status_polls = 0;
	halt_reported = 0;
}

static uint8_t read_status(uint16_t* len)
{
	uint8_t st;
	FPGA_SELECT();
	FPGA_TX_BYTE(FPGA_CMD_XCA_STATUS);
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
	FPGA_TX_BYTE(FPGA_CMD_XC_STATUS);
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

void xc_audio_poll(void)
{
	uint16_t len;
	if(++status_polls >= 100000) {
		status_polls = 0;
		check_soc();
	}
	uint8_t st = read_status(&len);

	if(st & XCA_ST_RESET) {
		decoder_ok = opus_decoder_init((OpusDecoder*)decoder_mem, 24000, 2) == OPUS_OK;
		FPGA_SELECT();
		FPGA_TX_BYTE(FPGA_CMD_XCA_ACKRESET);
		FPGA_DESELECT();
		return; /* pick up a job on the next poll, after the reset is acknowledged */
	}
	if(!(st & XCA_ST_JOB)) {
		return;
	}

	if(len > sizeof(packet)) {
		len = sizeof(packet);
	}
	FPGA_SELECT();
	FPGA_TX_BYTE(FPGA_CMD_XCA_READPKT);
	FPGA_RX_BYTE(); /* null read */
	FPGA_RX_BLOCK(packet, len);
	FPGA_DESELECT();

	int32_t ret;
	uint32_t range = 0;
	if(decoder_ok) {
		ret = opus_decode((OpusDecoder*)decoder_mem, packet, len, pcm, 480, 0);
		opus_decoder_ctl((OpusDecoder*)decoder_mem, OPUS_GET_FINAL_RANGE(&range));
	} else {
		ret = OPUS_INTERNAL_ERROR;
	}
	if(ret < 0) {
		xc_audio_errors++;
		memset(pcm, 0, sizeof(pcm));
	}
	xc_audio_packets++;

	FPGA_SELECT();
	FPGA_TX_BYTE(FPGA_CMD_XCA_WRITEPCM);
	FPGA_TX_BLOCK((uint8_t*)pcm, sizeof(pcm)); /* the MCU is little-endian like the RP2040 */
	FPGA_DESELECT();

	FPGA_SELECT();
	FPGA_TX_BYTE(FPGA_CMD_XCA_DONE);
	for(int i = 0; i < 4; i++) FPGA_TX_BYTE((uint8_t)((uint32_t)ret >> (8 * i)));
	for(int i = 0; i < 4; i++) FPGA_TX_BYTE((uint8_t)(range >> (8 * i)));
	FPGA_TX_BYTE(0x00); /* flop reset */
	FPGA_DESELECT();
}
