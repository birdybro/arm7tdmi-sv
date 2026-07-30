/*
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ARMv4T FPGA smoke ROM for arm7tdmi_generic_soc.
 *
 * The program runs without a C runtime. It exercises the paths most useful
 * during physical-board bring-up, reports its current test number through the
 * signature MMIO register, and terminates in one of two permanent states:
 *
 *   PASS: status = 0x50415353, signature = 0xa7d1c0de, UART "GIP"
 *   FAIL: status = 0x4641494c, signature = failing test number, UART "F"
 *
 * The MiSTer wrapper renders those states as green/red video and displays the
 * signature as a 32-bit barcode, so no debugger is required on the board.
 */

    .syntax unified
    .cpu arm7tdmi
    .arch armv4t
    .arm
    .section .text
    .global _start

    .equ RAM_BASE,       0x10000000
    .equ TIMER_BASE,     0x20000000
    .equ UART_BASE,      0x20001000
    .equ TEST_BASE,      0x20002000
    .equ TEST_STATUS,    0
    .equ TEST_SIGNATURE, 4

_start:
    b       reset
    b       undefined_vector
    b       swi_vector
    b       prefetch_abort_vector
    b       data_abort_vector
    b       reserved_vector
    b       irq_handler
    b       fiq_vector

    .org    0x40
reset:
    mov     r10, #0x20000000
    add     r10, r10, #0x2000
    ldr     r0, =0x52554e21             /* "RUN!" */
    str     r0, [r10, #TEST_STATUS]
    mov     r11, #1
    str     r11, [r10, #TEST_SIGNATURE]

    mov     sp, #RAM_BASE
    add     sp, sp, #0x400
    mov     r4, #RAM_BASE

    /* 1: word, byte, halfword, and signed-load lane behavior. */
    ldr     r0, =0x11223344
    str     r0, [r4]
    ldr     r1, [r4]
    cmp     r1, r0
    bne     fail
    ldrb    r1, [r4, #1]
    cmp     r1, #0x33
    bne     fail
    mov     r1, #0xaa
    strb    r1, [r4, #2]
    ldr     r1, [r4]
    ldr     r2, =0x11aa3344
    cmp     r1, r2
    bne     fail
    ldr     r1, =0x0000beef
    strh    r1, [r4, #4]
    ldrh    r2, [r4, #4]
    cmp     r2, r1
    bne     fail
    ldrsb   r2, [r4, #4]
    cmn     r2, #0x11                   /* 0xffffffef + 0x11 == 0 */
    bne     fail

    /* 2: arithmetic flags, conditional suppression, and barrel shifts. */
    mov     r11, #2
    str     r11, [r10, #TEST_SIGNATURE]
    ldr     r0, =0x7fffffff
    adds    r1, r0, #1
    bvc     fail
    bpl     fail
    ldr     r2, =0x80000000
    cmp     r1, r2
    bne     fail
    mov     r3, #0
    cmp     r3, #0
    moveq   r3, #0x5a
    movne   r3, #0xa5
    cmp     r3, #0x5a
    bne     fail
    mov     r3, #1
    mov     r3, r3, lsl #31
    cmp     r3, r2
    bne     fail
    movs    r3, r3, ror #1
    bcs     fail
    ldr     r2, =0x40000000
    cmp     r3, r2
    bne     fail

    /* 3: short and long multiply datapaths. */
    mov     r11, #3
    str     r11, [r10, #TEST_SIGNATURE]
    mov     r0, #37
    mov     r1, #13
    mul     r2, r0, r1
    ldr     r3, =481
    cmp     r2, r3
    bne     fail
    mvn     r0, #0
    mov     r1, #2
    umull   r2, r3, r0, r1
    mvn     r0, #1
    cmp     r2, r0
    bne     fail
    cmp     r3, #1
    bne     fail

    /* 4: block transfers, stack integrity, BL, and ARM return semantics. */
    mov     r11, #4
    str     r11, [r10, #TEST_SIGNATURE]
    mov     r5, #0x15
    mov     r6, #0x26
    mov     r7, #0x37
    mov     r8, #0x48
    stmdb   sp!, {r5-r8}
    mov     r5, #0
    mov     r6, #0
    mov     r7, #0
    mov     r8, #0
    ldmia   sp!, {r5-r8}
    cmp     r5, #0x15
    cmpeq   r6, #0x26
    cmpeq   r7, #0x37
    cmpeq   r8, #0x48
    bne     fail
    mov     r0, #0x21
    bl      arm_subroutine
    cmp     r0, #0x42
    bne     fail

    /* 5: atomic SWP read/write pair and lock path. */
    mov     r11, #5
    str     r11, [r10, #TEST_SIGNATURE]
    ldr     r0, =0xdeadbeef
    str     r0, [r4, #0x20]
    ldr     r1, =0xa5a5a5a5
    add     r3, r4, #0x20
    swp     r2, r1, [r3]
    cmp     r2, r0
    bne     fail
    ldr     r2, [r3]
    cmp     r2, r1
    bne     fail

    /* 6: ARM-to-Thumb-to-ARM BX interworking. */
    mov     r11, #6
    str     r11, [r10, #TEST_SIGNATURE]
    mov     r0, #0x12
    adr     lr, thumb_return
    ldr     r1, =thumb_test + 1
    bx      r1
thumb_return:
    cmp     r0, #0x2a
    bne     fail

    /* The early "G" means all non-interrupt CPU tests passed. */
    mov     r0, #'G'
    bl      uart_putc

    /* 7: synchronized IRQ entry, banked LR, handler store, and return. */
    mov     r11, #7
    str     r11, [r10, #TEST_SIGNATURE]
    mov     r0, #0
    str     r0, [r4, #0x80]
    mov     r5, #TIMER_BASE
    mov     r0, #0x80
    str     r0, [r5, #4]
    mov     r0, #3
    str     r0, [r5, #8]
    mrs     r0, cpsr
    bic     r0, r0, #0x80
    msr     cpsr_c, r0
    ldr     r6, =0x00010000
irq_wait:
    ldr     r0, [r4, #0x80]
    cmp     r0, #1
    beq     pass
    subs    r6, r6, #1
    bne     irq_wait
    b       fail

pass:
    ldr     r0, =0xa7d1c0de
    str     r0, [r10, #TEST_SIGNATURE]
    ldr     r0, =0x50415353             /* "PASS" */
    str     r0, [r10, #TEST_STATUS]
    mov     r0, #'P'
    bl      uart_putc
pass_loop:
    b       pass_loop

fail:
    str     r11, [r10, #TEST_SIGNATURE]
    ldr     r0, =0x4641494c             /* "FAIL" */
    str     r0, [r10, #TEST_STATUS]
    mov     r0, #'F'
    bl      uart_putc
fail_loop:
    b       fail_loop

arm_subroutine:
    add     r0, r0, r0
    mov     pc, lr

uart_putc:
    mov     r1, #TIMER_BASE
    add     r1, r1, #0x1000
    str     r0, [r1]
    mov     pc, lr

undefined_vector:
    mov     r11, #0xe1
    b       exception_fail
swi_vector:
    mov     r11, #0xe2
    b       exception_fail
prefetch_abort_vector:
    mov     r11, #0xe3
    b       exception_fail
data_abort_vector:
    mov     r11, #0xe4
    b       exception_fail
reserved_vector:
    mov     r11, #0xe5
    b       exception_fail
fiq_vector:
    mov     r11, #0xe6
exception_fail:
    mov     r10, #0x20000000
    add     r10, r10, #0x2000
    b       fail

irq_handler:
    mov     r0, #1
    str     r0, [r5, #12]              /* clear and disable timer */
    str     r0, [r4, #0x80]
    mov     r0, #'I'
    mov     r1, #TIMER_BASE
    add     r1, r1, #0x1000
    str     r0, [r1]
    subs    pc, lr, #4

    .align  2
    .thumb
    .thumb_func
thumb_test:
    adds    r0, #0x18
    lsls    r0, r0, #1
    lsrs    r0, r0, #1
    bx      lr

    .arm
    .ltorg
