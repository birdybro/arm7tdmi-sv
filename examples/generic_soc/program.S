/*
 * Repository-authored ARMv4T program embedded by arm7tdmi_generic_soc.
 * It checks RAM, emits 'G', programs the timer, takes IRQ, and emits 'I'.
 */

    .syntax unified
    .cpu arm7tdmi
    .arm
    .section .text
    .global _start

_start:
    b       reset
    b       .
    b       .
    b       .
    b       .
    b       .
    b       irq
    b       .

    .org    0x40
reset:
    mov     r0, #0x10000000
    mov     r1, #0x2a
    str     r1, [r0]
    ldr     r2, [r0]
    cmp     r2, #0x2a
    bne     fail
    add     r2, r2, #1
    str     r2, [r0, #4]

    mov     r3, #0x20000000
    add     r3, r3, #0x1000
    mov     r4, #'G'
    str     r4, [r3]

    mov     r5, #0x20000000
    mov     r6, #0x50
    str     r6, [r5, #4]
    mov     r6, #3
    str     r6, [r5, #8]

    mrs     r7, cpsr
    bic     r7, r7, #0x80
    msr     cpsr_c, r7
run:
    b       run

fail:
    mov     r4, #'F'
    str     r4, [r3]
    b       .

    .org    0xa0
irq:
    mov     r8, #1
    str     r8, [r5, #12]
    mov     r9, #'I'
    str     r9, [r3]
    subs    pc, lr, #4
