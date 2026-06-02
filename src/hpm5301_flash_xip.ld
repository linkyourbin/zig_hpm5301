ENTRY(_start)

FLASH_SIZE = 1M;
STACK_SIZE = 0x400;

MEMORY
{
    FLASH (rx) : ORIGIN = 0x80000000, LENGTH = FLASH_SIZE
    ILM (wx)  : ORIGIN = 0x00000000, LENGTH = 128K
    DLM (w)   : ORIGIN = 0x00080300, LENGTH = 128K - 768
}

__nor_cfg_option_load_addr__ = ORIGIN(FLASH) + 0x400;
__boot_header_load_addr__ = ORIGIN(FLASH) + 0x1000;
__app_load_addr__ = ORIGIN(FLASH) + 0x3000;
__app_offset__ = __app_load_addr__ - __boot_header_load_addr__;

SECTIONS
{
    .nor_cfg_option __nor_cfg_option_load_addr__ : {
        KEEP(*(.nor_cfg_option))
    } > FLASH

    .boot_header __boot_header_load_addr__ : {
        __boot_header_start__ = .;
        KEEP(*(.boot_header))
        KEEP(*(.fw_info_table))
        __boot_header_end__ = .;
    } > FLASH

    .text __app_load_addr__ : {
        . = ALIGN(4);
        KEEP(*(.text._start))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > FLASH

    .data : {
        . = ALIGN(4);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        *(.data .data.*)
        . = ALIGN(4);
    } > DLM AT > FLASH

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start__ = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end__ = .;
    } > DLM

    .stack (NOLOAD) : {
        . = ALIGN(16);
        __stack_base__ = .;
        . += STACK_SIZE;
        . = ALIGN(16);
        __stack_top__ = .;
    } > DLM

    /DISCARD/ : {
        *(.riscv.attributes)
        *(.eh_frame)
        *(.eh_frame.*)
        *(.eh_frame_hdr)
        *(.comment)
        *(.debug*)
    }

    __fw_size__ = SIZEOF(.text) + SIZEOF(.data);
    ASSERT((__app_load_addr__ + __fw_size__) <= (ORIGIN(FLASH) + LENGTH(FLASH)), "FLASH overflow")
}
