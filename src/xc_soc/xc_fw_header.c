/* Header at 0x10F00000: tells MesenCE and xc_patch_image.py where to put what.
 *   word 0 magic "MXCX", word 1 version, word 2 xc_mix_install (unused since v2, kept for v1 tools),
 *   word 3 number of patches, then {firmware address, target, kind} per patch:
 *     kind 0: 16-byte veneer at the function entry: push {r0}; ldr r0, =target; mov ip, r0; pop {r0}; bx ip
 *     kind 1: the function is already such a veneer (flash functions): replace its target word at +12
 *     kind 2: "movs r0, #0; bx lr" (4 bytes) */
#include <stdint.h>

extern void xc_mix_install(void (*entry)(void));
extern int xc_bus_init(), xc_bus_flush(), xc_bus_wait_tx(), xc_bus_send(), xc_bus_recv(), xc_bus_push();
extern void xc_sleep_until(), xc_panic();
extern int xc_puts(), xc_printf();
extern void xc_flash_do_cmd(), xc_flash_range_erase(), xc_flash_range_program();

#define P(addr, fn, kind) addr, (uint32_t)(fn), kind

__attribute__((section(".text.xc_header"), used))
const uint32_t xc_fw_header[4 + 3 * 17] = {
	0x5843584Du, 2, (uint32_t)xc_mix_install, 17,
	P(0x10059060u, xc_mix_install, 0),        /* multicore_launch_core1 */
	P(0x10054288u, 0, 2),                     /* set_sys_clock_pll */
	P(0x10056EB6u, 0, 2),                     /* stdio_init_all */
	P(0x10056E3Cu, xc_puts, 0),
	P(0x10056EA0u, xc_printf, 0),
	P(0x100555C0u, xc_panic, 0),
	P(0x10054ECCu, xc_sleep_until, 0),
	P(0x10066D94u, xc_bus_init, 0),
	P(0x100670CCu, xc_bus_flush, 0),
	P(0x10067188u, xc_bus_wait_tx, 0),
	P(0x100671A4u, xc_bus_send, 0),
	P(0x100671F4u, xc_bus_recv, 0),
	P(0x10067274u, xc_bus_push, 0),
	P(0x1006E560u, xc_flash_do_cmd, 1),
	P(0x1006E610u, xc_flash_range_program, 1),
	P(0x1006E690u, xc_flash_range_erase, 1),
	P(0x10067E34u, 0, 2),                     /* core1_init_opus: never reached (no core 1); returns 0 if it were */
};
