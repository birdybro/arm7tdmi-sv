/*
 * Repository-authored ARMv4T differential program.
 *
 * QEMU and the RTL execute the same linked image. State comparison starts at
 * measure_begin and stops before measure_end. The program deliberately stays
 * within behavior shared by ARM7TDMI and QEMU's ARM926 model: no ARMv5
 * instructions, implementation-defined inputs, exceptions, or unaligned
 * accesses.
 */

    .syntax unified
    .cpu arm7tdmi
    .section .text
    .global _start
    .global measure_begin
    .global measure_end

    .arm
_start:
    b       initialize

initialize:
    mov     r0, #0
    mov     r1, #0
    mov     r2, #0
    mov     r3, #0
    mov     r4, #0
    mov     r5, #0
    mov     r6, #0
    mov     r7, #0
    mov     r8, #0
    mov     r9, #0
    mov     r10, #0
    mov     r11, #0
    mov     r12, #0
    mov     r13, #0x30000
    mov     r14, #0
    cmp     r0, r0
    b       measure_begin

measure_begin:
    mov     r0, #5
    mov     r1, #3
    adds    r2, r0, r1
    subs    r3, r2, #10
    and     r4, r2, #6
    eor     r5, r4, #3
    orr     r6, r5, #0x10
    bic     r7, r6, #1
    mvn     r8, #0
    mov     r9, r0, lsl #3
    mov     r9, r9, lsr #1
    mov     r9, r9, asr #1
    mov     r11, #2
    mov     r12, r0, lsl r11
    cmp     r2, #8
    addne   r3, r3, #1
    addeq   r3, r3, #2
    mul     r8, r0, r1

    mov     r10, #0x20000
    str     r2, [r10]
    ldr     r9, [r10]
    mov     r11, #0xab
    strb    r11, [r10, #4]
    ldrb    r12, [r10, #4]
    mov     r11, #0x1200
    add     r11, r11, #0x34
    strh    r11, [r10, #6]
    ldrh    r4, [r10, #6]
    mov     r5, #0x80
    strb    r5, [r10, #8]
    ldrsb   r6, [r10, #8]
    mov     r5, #0x8000
    strh    r5, [r10, #10]
    ldrsh   r7, [r10, #10]

    stmia   r10, {r0-r4}
    mov     r0, #0
    mov     r1, #0
    mov     r2, #0
    mov     r3, #0
    mov     r4, #0
    ldmia   r10, {r0-r4}
    bl      arm_subroutine
    /* .thumb_func gives this symbol the interworking low bit already. */
    ldr     r0, =thumb_entry
    bx      r0

arm_subroutine:
    add     r5, r0, r1
    mov     pc, lr

    .thumb
    .thumb_func
thumb_entry:
    movs    r0, #9
    adds    r1, r0, #7
    subs    r2, r1, #3
    lsls    r3, r2, #2
    lsrs    r3, r3, #1
    asrs    r4, r3, #1
    eors    r4, r2
    cmp     r4, #8
    beq     thumb_condition_skipped
    movs    r5, #0x44
thumb_condition_skipped:
    push    {r0, r1, r5}
    movs    r0, #1
    movs    r1, #2
    movs    r5, #3
    pop     {r0, r1, r5}
    bl      thumb_subroutine
    ldr     r3, =arm_return
    bx      r3

thumb_subroutine:
    adds    r6, r6, #1
    bx      lr

    .arm
    .align  2
arm_return:
    mov     r10, #0x20000
    mov     r5, #0x55
    swp     r6, r5, [r10]
    str     r0, [r10, #0]
    str     r1, [r10, #4]
    str     r2, [r10, #8]
    str     r3, [r10, #12]
    str     r4, [r10, #16]
    ldmia   r10, {r8-r12}
    b       measure_end

measure_end:
    /* QEMU-only semihosted success; the RTL scoreboard stops before here. */
    mov     r0, #0x20
    ldr     r1, =semihost_exit
    svc     #0x123456

    .ltorg

semihost_exit:
    .word   0x00020026
    .word   0
