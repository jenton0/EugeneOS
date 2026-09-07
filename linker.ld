/* ============================================================
 * EUGENE OS - linker script for userland flat binaries
 *
 * ПРО ФОРМАТ (важливо, тут була засада):
 *
 * MinGW GCC генерує PE-COFF об'єктники, і ld працює в емуляції
 * i386pep. Ця емуляція виконує PE-специфічні дії над ВИХІДНИМ
 * файлом ЗАВЖДИ - навіть якщо попросити --oformat binary. Саме
 * тому будь-яка спроба зробити не-PE вивід дає:
 *     "cannot perform PE operations on non PE output file"
 *
 * Тому схема така: ld робить звичайний PE, а objcopy -O binary
 * потім зрізає заголовки. Щоб PE-заголовки нічого не зіпсували,
 * ВЕСЬ образ зібрано в ОДНУ секцію .image - разом із .bss.
 * При одній секції objcopy кладе її на зміщення 0 незалежно від
 * того, що PE записав у ImageBase та RVA.
 *
 * Скрипт свідомо БЕЗ OUTPUT_FORMAT - працює і з MinGW (PE),
 * і з ELF-крос-компілятором.
 *
 * ЩО ТУТ КРИТИЧНО:
 *   1) секція з _start МУСИТЬ бути найпершою - ядро стрибає рівно
 *      на AppMemoryBase, без жодного заголовка;
 *   2) імена секцій різні у PE та ELF:
 *          константи:  PE -> .rdata      ELF -> .rodata
 *      тому ловимо обидва набори, інакше вони стануть orphan-секціями;
 *   3) .bss лежить УСЕРЕДИНІ .image, тому ld заповнює його нулями
 *      прямо у файлі. Образ більший на ~13 КБ, зате нема жодних
 *      дірок вирівнювання між секціями. _start з entry.c однаково
 *      обнуляє його ще раз - на випадок повторного запуску програми.
 * ============================================================ */

ENTRY(_start)

SECTIONS
{
    /* МУСИТЬ збігатися з AppMemoryBase у kernel.asm */
    . = 0x4000000;

    .image : ALIGN(16)
    {
        /* --- КОД --- */
        *(.text.entry)                          /* _start - завжди першим */
        *(.text .text.* .text$* .gnu.linkonce.t.*)
        . = ALIGN(16);

        /* --- КОНСТАНТИ (PE: .rdata, ELF: .rodata) --- */
        *(.rdata .rdata.* .rdata$*)
        *(.rodata .rodata.* .gnu.linkonce.r.*)
        . = ALIGN(16);

        /* --- ІНІЦІАЛІЗОВАНІ ДАНІ --- */
        *(.data .data.* .data$* .gnu.linkonce.d.*)
        *(.got .got.plt)
        . = ALIGN(16);

        /* --- НЕІНІЦІАЛІЗОВАНІ ДАНІ (ld заповнить нулями у файлі) --- */
        __bss_start = .;
        *(.bss .bss.* .bss$* .gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    __image_end = .;

    /* --- СМІТТЯ, ЯКЕ НЕ МАЄ ПОТРАПИТИ В ОБРАЗ --- */
    /DISCARD/ :
    {
        *(.pdata)                 /* PE: таблиці розкрутки SEH */
        *(.xdata)
        *(.idata .idata.*)        /* PE: імпорт - у нас його нема */
        *(.edata)
        *(.CRT .CRT$*)
        *(.tls .tls$*)
        *(.rsrc)
        *(.reloc)
        *(.buildid)
        *(.note.gnu.property)     /* ELF */
        *(.note.GNU-stack)
        *(.note.*)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.gcc_except_table)
        *(.comment)
        *(.debug*)
        *(.drectve)
    }

    /* Жорстка перевірка на етапі лінковки: якщо _start не на початку
       образу - лінковка впаде тут із зрозумілим текстом, а не мовчки
       дасть бінарник, який ядро виконає як сміття. */
    __ld_assert_entry = ASSERT(_start == 0x4000000,
        "FATAL: _start ne na 0x4000000. Perevir poryadok .o faylin ta orphan-sekcii.");
}
