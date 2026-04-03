ENTRY(_start)

SECTIONS
{
    . = 0x4000000; 

    .text :
    {
        /* Точка входу завжди перша */
        *entry.o(.text)
        
        /* Весь інший код */
        *(.text .text.*)
    }

    .rodata :
    {
        /* У Linux константи лежать в .rodata, а Windows GCC часто кладе їх в .rdata */
        *(.rodata .rodata.*)
        *(.rdata .rdata.*)
    }

    .data :
    {
        *(.data .data.*)
    }

    .bss :
    {
        *(.bss .bss.*)
    }

    /* Відрізаємо віндове сміття, яке нам у сирому бінарнику точно не треба */
    /DISCARD/ :
    {
        *(.eh_frame)
        *(.comment)
        *(.reloc)
        *(.pdata)
        *(.xdata)
    }
}