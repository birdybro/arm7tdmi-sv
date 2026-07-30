/* SPDX-License-Identifier: GPL-3.0-only */
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;
    .text : {
        KEEP(*(.text))
    }

    /DISCARD/ : {
        *(.ARM.attributes)
        *(.comment)
        *(.note*)
    }
}

ASSERT(SIZEOF(.text) <= 0x400, "generic SoC smoke ROM exceeds 1 KiB")
