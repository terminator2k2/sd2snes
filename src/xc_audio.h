/* Xeno Crisis on sd2snes: Opus decode service on the MCU.
 * The soft CPU in the FPGA runs the game's mixer and posts one music packet at a time to the decode
 * mailbox (xc_decbox.v). This module decodes it with libopus 1.3.1 (fixed point, 24 kHz stereo, 20 ms
 * frames) and returns the 480 stereo samples, opus_decode()'s result and the decoder's final range. */
#ifndef XC_AUDIO_H
#define XC_AUDIO_H
#include <stdint.h>

/* FPGA commands (mcu_cmd.v, handled by xc_decbox.v) */
#define FPGA_CMD_XCA_STATUS    (0xc0)  /* read: status byte, packet length (2 bytes, little-endian) */
#define   XCA_ST_JOB           0x01    /* a packet is waiting */
#define   XCA_ST_RESET         0x02    /* the mixer asked for a decoder reset */
#define FPGA_CMD_XCA_READPKT   (0xc1)  /* read: packet bytes from offset 0 */
#define FPGA_CMD_XCA_WRITEPCM  (0xc2)  /* write: 1920 bytes of PCM (L, R int16 little-endian) from offset 0 */
#define FPGA_CMD_XCA_DONE      (0xc3)  /* write: ret (4 bytes LE), final range (4 bytes LE); raises the IRQ */
#define FPGA_CMD_XCA_ACKRESET  (0xc4)  /* clear the reset request */
#define FPGA_CMD_XC_STATUS     (0xc5)  /* read: (null), {running, halted}, halt code (4 LE), halt address (4 LE) */
#define FPGA_CMD_XC_RUN        (0xc6)  /* write: 1 = release the soft CPU, 0 = hold it in reset */
#define FPGA_CMD_XC_PERF_SNAP  (0xc7)  /* snapshot of the FPGA performance counters */
#define FPGA_CMD_XC_PERF       (0xc8)  /* read: (null), 8 counters (4 bytes LE each), see xc_top.v "perf" */

void xc_run(uint8_t run);   /* release (1) / hold (0) the soft CPU; release once the image and the save are loaded */
void xc_audio_init(void);   /* call when a Xeno Crisis cartridge is started */
void xc_audio_poll(void);   /* call from the main loop while the game runs; returns quickly when idle */
void xc_audio_service(void);/* same, from inside long MCU jobs (FPGA deselected); does nothing when no game runs */
void xc_audio_report(void); /* when the game is left: timing statistics to the UART and /sd2snes/xcaudio.txt */
extern uint32_t xc_audio_packets, xc_audio_errors;

/* xc_load.c: loading a 128 KB kernel ROM builds the image from /sd2snes/xenocrisis_rp2040.bin + /sd2snes/xc_soc.bin */
const char* xc_load_image(void);   /* NULL when done, else the name of the missing / wrong file */
void xc_load_dump_save(void);      /* no .srm: seed the save RAM from the dump's save area */

#endif
