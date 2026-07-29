    .syntax unified
    .cpu arm7tdmi
    .arm

    .section .vectors, "ax", %progbits
    .global _start
    .type _start, %function
_start:
    b       reset
    b       hang
    b       hang
    b       hang
    b       hang
    b       hang
    b       hang
    b       hang

    .section .text.startup, "ax", %progbits
reset:
    ldr     sp, =0x0000f000
    bl      arm_main
hang:
    b       hang
