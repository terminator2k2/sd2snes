/* Header at 0x10F00000: tells MesenCE and xc_patch_image.py where to put what.
 *   word 0 magic "MXCX", word 1 version, word 2 xc_mix_install (unused since v2, kept for v1 tools),
 *   word 3 number of patches, then {firmware address, target, kind} per patch:
 *     kind 0: 16-byte veneer at the function entry: push {r0}; ldr r0, =target; mov ip, r0; pop {r0}; bx ip
 *     kind 1: the function is already such a veneer (flash functions): replace its target word at +12
 *     kind 2: "movs r0, #0; bx lr" (4 bytes)
 *   then the mk2 table: word "MK2P", number of patches, {firmware address, target, kind 0} per patch. Only a core
 *   without the SIO hardware divider (sd2snes mk2) applies it. It is outside the main table because the loaders
 *   of the mk3 firmware and MesenCE up to now treat an unknown kind as kind 2. */
#include <stdint.h>

extern void xc_mix_install(void (*entry)(void));
extern int xc_bus_init(), xc_bus_flush(), xc_bus_wait_tx(), xc_bus_send(), xc_bus_recv(), xc_bus_push();
extern void xc_sleep_until(), xc_panic();
extern int xc_puts(), xc_printf();
extern void xc_flash_do_cmd(), xc_flash_range_erase(), xc_flash_range_program();
extern void xc_sdiv32(), xc_udiv32(), xc_sdiv64(), xc_udiv64();

#define P(addr, fn, kind) addr, (uint32_t)(fn), kind

__attribute__((section(".text.xc_header"), used))
const uint32_t xc_fw_header[4 + 3 * 17 + 2 + 3 * 4] = {
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
	/* mk2 table: the pico-sdk divider functions -> software division (xc_div.S). These are all the entry points
	   into the divider code from outside it; the other readers of the divider (the soft-float/double wrappers
	   around the bootrom calls) only read DIV_CSR, which reads 0 (not dirty) on the mk2 core. */
	0x50324B4Du, 4,                           /* "MK2P" */
	P(0x10067EE8u, xc_sdiv32, 0),             /* divmod_s32s32 (__aeabi_idivmod) */
	P(0x10067F38u, xc_udiv32, 0),             /* divmod_u32u32 (__aeabi_uidivmod) */
	P(0x10067FB4u, xc_udiv64, 0),             /* divmod_u64u64 (__aeabi_uldivmod) */
	P(0x10067F84u, xc_sdiv64, 0),             /* divmod_s64s64 (not called in this build; for completeness) */
};
