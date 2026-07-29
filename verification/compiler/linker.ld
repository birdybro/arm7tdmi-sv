ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .vectors 0x00000000 :
    {
        KEEP(*(.vectors))
    } > RAM

    .text :
    {
        *(.text.startup)
        *(.text .text.*)
        *(.glue_7t)
        *(.glue_7)
    } > RAM

    .rodata :
    {
        *(.rodata .rodata.*)
    } > RAM

    .data :
    {
        *(.data .data.*)
    } > RAM

    .bss (NOLOAD) :
    {
        *(.bss .bss.* COMMON)
    } > RAM

    /DISCARD/ :
    {
        *(.ARM.exidx*)
        *(.comment)
    }
}
