/* Interrupt wrappers: run the mixer on its own stack (top of SCRATCH_X), not on core 0's.
 * The core has no nesting, so one stack is enough. Hardware stacking already saved r0-r3, r12, lr, pc, xPSR. */
	.syntax unified
	.cpu cortex-m0plus
	.thumb

	.section .text.xc_irq, "ax"
	.global xc_irq_tick
	.global xc_irq_decoded
	.thumb_func
xc_irq_tick:
	ldr r1, =xc_mix_tick
	b 1f
	.thumb_func
xc_irq_decoded:
	ldr r1, =xc_mix_decoded
1:	mov r0, sp
	ldr r2, =__xc_stack_top
	mov sp, r2
	push {r0, lr}            /* old SP and EXC_RETURN */
	blx r1
	pop {r0, r1}
	mov sp, r0
	bx r1
	.pool

/* mk2: called by core 0's wait loops (xc_shim.c). Does nothing until xc_mix_install_mk2() has run; then runs the
 * due mixer ticks on the mixer's stack (never nested: core 0 only). Keeps r0-r3 and r12 like a normal call may not,
 * so the callers treat it as an ordinary function call. */
	.section .text.xc_mix_poll, "ax"
	.global xc_mix_poll
	.thumb_func
xc_mix_poll:
	ldr r0, =xc_mix_coop
	ldr r0, [r0]
	ldr r1, =0x434F4F50
	cmp r0, r1
	bne 2f
	mov r0, sp
	ldr r2, =__xc_stack_top
	mov sp, r2
	push {r0, lr}
	bl xc_mix_poll_body
	pop {r0, r1}
	mov sp, r0
	bx r1
2:	bx lr
	.pool
