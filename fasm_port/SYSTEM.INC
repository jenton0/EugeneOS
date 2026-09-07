
; flat assembler interface for EUGENE OS (x86-64)
; Порт на основі SOURCE/LINUX/X64/SYSTEM.INC
; Copyright (c) 1999-2022, Tomasz Grysztar. All rights reserved.
;
; ==========================================================
; ЩО ТУТ ВІДРІЗНЯЄТЬСЯ ВІД LINUX-ВЕРСІЇ
;
; 1) Замість інструкції syscall — int 0x80 з домовленістю EUGENE OS:
;        RAX = номер, RSI = arg1, R9 = arg2, RDI = arg3, RDX = arg4
;    Тобто НЕ Linux-подібна (там RDI/RSI/RDX). Через це кожна
;    обгортка перекладає аргументи явно.
;
; 2) Немає brk/mmap. Робоча пам'ять — фіксований регіон, заданий
;    константами нижче. Це нормально: ядро однокористувацьке
;    і ніхто, крім fasm, цю ділянку не чіпає.
;
; 3) Немає змінних оточення — get_environment_variable завжди
;    повертає порожній результат. fasm використовує їх лише
;    для INCLUDE, а шляхи ми й так не підтримуємо.
;
; 4) Немає підкаталогів: FAT32-шар ядра працює з поточною
;    директорією, тому adapt_path зрізає шлях до імені файлу.
;
; 5) Стеля розміру файлу — FD_CAP ядра (8 МБ на відкритий файл).
; ==========================================================


; ==========================================================
; ТИМЧАСОВА ДІАГНОСТИКА
; Друкує результат кожного файлового виклику, щоб побачити,
; на якому саме кроці губиться вміст. Вимкнути: DEBUG_IO = 0
; ==========================================================
DEBUG_IO = 0

macro DBG msg, val
{
    if DEBUG_IO
        mov     [dbg_save_rax],rax
        mov     [dbg_save_rbx],rbx
        mov     [dbg_save_rcx],rcx
        mov     [dbg_save_rdx],rdx
        mov     [dbg_save_rsi],rsi
        mov     [dbg_save_rdi],rdi
        mov     dword [dbg_save_val],val    ; val завжди 32-бітний регістр
        mov     esi,msg
        call    display_string
        mov     eax,dword [dbg_save_val]
        call    display_number
        mov     esi,_dbg_nl
        call    display_string
        mov     rax,[dbg_save_rax]
        mov     rbx,[dbg_save_rbx]
        mov     rcx,[dbg_save_rcx]
        mov     rdx,[dbg_save_rdx]
        mov     rsi,[dbg_save_rsi]
        mov     rdi,[dbg_save_rdi]
    end if
}

; --- Прапорці open() (значення з stdlib.h ядра) ---
O_RDONLY   = 0
O_WRONLY   = 1
O_RDWR     = 2
O_CREAT    = 040h
O_TRUNC    = 0200h
O_APPEND   = 0400h

; --- Номери системних викликів EUGENE OS ---
SYS_EXIT     = 0
SYS_PRINT    = 2
SYS_PUTCHAR  = 6
SYS_OPEN     = 16
SYS_READ     = 17
SYS_WRITE    = 18
SYS_LSEEK    = 19
SYS_CLOSE    = 20
SYS_GETARGS  = 21

; --- Робоча пам'ять fasm ---
; Лежить вище буферів файлових дескрипторів ядра (ті займають
; 128..192 МБ). Усі вказівники в ядрі fasm 32-бітні, тому вся
; ця ділянка ОБОВ'ЯЗКОВО має бути нижче 4 ГБ.
FASM_MEMORY_BASE = 0C000000h        ; 192 МБ
FASM_MEMORY_SIZE = 4000000h         ; 64 МБ робочої пам'яті

init_memory:
        ; Стек програми ядро ставить на AppStackTop (~64 МБ).
        ; Нижня межа стеку потрібна fasm для перевірки переповнення.
        mov     eax,esp
        and     eax,not 0FFFh
        add     eax,1000h-10000h
        mov     [stack_limit],eax

        mov     ecx,[memory_setting]
        shl     ecx,10
        jnz     eug_have_size
        mov     ecx,FASM_MEMORY_SIZE
      eug_have_size:
        cmp     ecx,FASM_MEMORY_SIZE
        jbe     eug_size_ok
        mov     ecx,FASM_MEMORY_SIZE    ; більше ми фізично не маємо
      eug_size_ok:
        mov     eax,FASM_MEMORY_BASE
        mov     [additional_memory],eax
        lea     edi,[eax+ecx]
        mov     [memory_end],edi
        ; чверть під додаткову пам'ять, решта під основну
        shr     ecx,2
        add     eax,ecx
        mov     [additional_memory_end],eax
        mov     [memory_start],eax
        ret

exit_program:
        movzx   edi,al
        mov     rax,SYS_EXIT
        int     0x80
        jmp     exit_program            ; ядро сюди не повертається

; ==========================================================
; ФАЙЛОВІ ОПЕРАЦІЇ
;
; Домовленість fasm (та сама, що в Linux-версії):
;   вхід:  EDX = ім'я файлу (open/create), EBX = дескриптор,
;          EDX = буфер, ECX = кількість (read/write)
;   вихід: EBX = дескриптор, CF=1 при помилці
; ==========================================================

; adapt_path — EDX = шлях -> buffer = саме ім'я файлу.
; Підкаталогів немає, тому зрізаємо все до останнього роздільника
; і заодно приводимо до верхнього регістру (FAT32 у ядрі
; порівнює імена побайтово).
    adapt_path:
        mov     esi,edx
        mov     edi,buffer
        ; знаходимо останній роздільник; R10 = початок імені файлу
        mov     r10,rsi
      eug_scan_sep:
        lodsb
        or      al,al
        jz      eug_scan_done
        cmp     al,'\'
        je      eug_mark_sep
        cmp     al,'/'
        je      eug_mark_sep
        cmp     al,':'
        jne     eug_scan_sep
      eug_mark_sep:
        mov     r10,rsi
        jmp     eug_scan_sep
      eug_scan_done:
        mov     rsi,r10
      eug_copy_name:
        lodsb
        cmp     al,'a'
        jb      eug_store_char
        cmp     al,'z'
        ja      eug_store_char
        sub     al,20h                  ; у верхній регістр
      eug_store_char:
        stos    byte [edi]
        or      al,al
        jnz     eug_copy_name
        cmp     edi,buffer+1000h
        ja      out_of_memory
        ret

open:
        mov     r12d,esi
        mov     r13d,edi
        call    adapt_path
        mov     rax,SYS_OPEN
        mov     esi,buffer              ; arg1 = ім'я
        mov     r9,O_RDONLY             ; arg2 = прапорці
        int     0x80
        mov     esi,r12d
        mov     edi,r13d
        DBG     _dbg_open,eax
        test    eax,eax
        js      file_error
        mov     ebx,eax
        clc
        ret

create:
        mov     r12d,esi
        mov     r13d,edi
        mov     r15d,edx
        call    adapt_path
        mov     rax,SYS_OPEN
        mov     esi,buffer
        mov     r9,O_CREAT+O_TRUNC+O_WRONLY
        int     0x80
        mov     esi,r12d
        mov     edi,r13d
        test    eax,eax
        js      file_error
        mov     ebx,eax
        clc
        ret

close:
        ; КРИТИЧНО: ESI МУСИТЬ пережити цей виклик.
        ; У preprocess_file одразу після 'call close' іде 'mov ebx,esi',
        ; де ESI = адреса щойно прочитаних даних файлу. У Linux-версії
        ; дескриптор передається через EDI, тому ESI там ніхто не чіпав.
        ; У нашому ABI дескриптор іде через RSI — і поки ми його не
        ; зберігали, fasm після close брав вміст файлу з адреси 0
        ; і бачив порожній вхід (1 passes, 0 bytes).
        mov     r12d,esi
        mov     r13d,edi
        mov     rax,SYS_CLOSE
        mov     esi,ebx                 ; arg1 = дескриптор
        int     0x80
        mov     esi,r12d
        mov     edi,r13d
        ret

read:
        mov     r12d,esi
        mov     r13d,edi
        mov     r14d,ecx                ; скільки просили (для перевірки нижче)
        mov     rax,SYS_READ
        mov     esi,ebx                 ; arg1 = дескриптор
        mov     r9d,edx                 ; arg2 = буфер
        mov     edi,ecx                 ; arg3 = скільки байт
        int     0x80
        mov     ecx,r14d
        mov     esi,r12d
        mov     edi,r13d
        DBG     _dbg_want,ecx
        DBG     _dbg_read,eax
        test    eax,eax
        js      file_error
        cmp     eax,ecx                 ; прочитали менше, ніж просили?
        jne     file_error
        clc
        ret
    file_error:
        stc
        ret

write:
        mov     r12d,esi
        mov     r13d,edi
        mov     r14d,ecx
        mov     rax,SYS_WRITE
        mov     esi,ebx
        mov     r9d,edx
        mov     edi,ecx
        int     0x80
        mov     ecx,r14d
        mov     esi,r12d
        mov     edi,r13d
        test    eax,eax
        js      file_error
        clc
        ret

lseek:
        ; вхід: EBX = дескриптор, EDX = зміщення, AL = звідки
        mov     r12d,esi
        mov     r13d,edi
        movzx   r10d,al                 ; зберігаємо whence
        mov     rax,SYS_LSEEK
        mov     esi,ebx
        movsxd  r9,edx                  ; зміщення знакове
        mov     rdi,r10
        int     0x80
        mov     esi,r12d
        mov     edi,r13d
        DBG     _dbg_seek,eax
        cmp     eax,-1
        je      file_error
        clc
        ret

; ==========================================================
; ВИВІД НА ЕКРАН
; ==========================================================

display_string:
        ; ESI = нуль-термінований рядок.
        ; Ядро EUGENE OS зберігає всі регістри крім RAX, тому
        ; зберігати щось окремо не треба — лише R9 під аргумент.
        mov     r10d,r9d
        mov     rax,SYS_PRINT
        mov     r9,0x00FFFFFF           ; білий
        int     0x80
        mov     r9d,r10d
        ret

display_character:
        ; DL = символ. ESI/EDI мають вижити — fasm на це розраховує.
        ;
        ; ВАЖЛИВО: ця процедура НЕ ЧІПАЄ R10 і R11 — на них тримаються
        ; лічильники в display_number і display_block, які її кличуть.
        ; R9 (аргумент кольору) ховаємо у верхню половину R12.
        mov     r12,rsi
        mov     r13,rdi
        mov     r14,r9
        movzx   rsi,dl
        mov     rax,SYS_PUTCHAR
        mov     r9,0x00FFFFFF
        int     0x80
        mov     r9,r14
        mov     rsi,r12
        mov     rdi,r13
        ret

display_number:
        ; Узято з Linux-версії, яка теж уникає push (modes.inc робить
        ; його 32-бітним). Відмінність: EBX ховаємо в R11, а не в R14,
        ; бо R14 тепер використовує display_character.
        mov     r11d,ebx
        mov     ecx,1000000000
        xor     edx,edx
        xor     bl,bl
      eug_display_loop:
        div     ecx
        mov     r15d,edx
        cmp     ecx,1
        je      eug_display_digit
        or      bl,bl
        jnz     eug_display_digit
        or      al,al
        jz      eug_digit_ok
        not     bl
      eug_display_digit:
        mov     dl,al
        add     dl,30h
        mov     r10d,ecx                ; display_character не чіпає R10
        call    display_character
        mov     ecx,r10d
      eug_digit_ok:
        mov     eax,ecx
        xor     edx,edx
        mov     ecx,10
        div     ecx
        mov     ecx,eax
        mov     eax,r15d
        or      ecx,ecx
        jnz     eug_display_loop
        mov     ebx,r11d
        ret

display_user_messages:
        ; Окремого потоку помилок немає — усе йде на екран.
        ret

display_block:
        ; ESI = дані, ECX = довжина (без нуль-термінатора).
        ;
        ; ВАЖЛИВО: не можна зберігати ESI/EDI у R12D/R13D, бо
        ; display_character усередині циклу використовує САМЕ ЦІ
        ; регістри — вони б затерлися на першій же ітерації.
        ; Тому лічильник і покажчик тримаємо у R10D/R11D.
        test    ecx,ecx
        jz      eug_block_displayed
        add     [displayed_count],ecx
        mov     al,[rsi+rcx-1]
        mov     [last_displayed],al     ; fasm перевіряє останній символ

        mov     r10d,esi                ; покажчик
        mov     r11d,ecx                ; лічильник
      eug_block_loop:
        mov     dl,[r10]
        call    display_character       ; псує R12D/R13D, але не R10/R11
        inc     r10d
        dec     r11d
        jnz     eug_block_loop
      eug_block_displayed:
        ret

; ==========================================================
; ЗМІННІ ОТОЧЕННЯ
; Їх у нас немає. fasm звертається сюди лише щоб знайти INCLUDE,
; тож просто повідомляємо, що змінної не існує.
; ==========================================================
get_environment_variable:
        ret


; ==========================================================
; ОБРОБНИКИ ПОМИЛОК
; Взято з Linux-версії дослівно: вони побудовані поверх наших
; же display_* / open / read / lseek / close, тому нічого
; платформозалежного в них немає. Єдина відмінність — con_handle
; у нас ні на що не впливає, бо потік помилок той самий екран.
; ==========================================================
fatal_error:
        mov        [con_handle],2
        mov        esi,error_prefix
        call        display_string
        pop        esi
        call        display_string
        mov        esi,error_suffix
        call        display_string
        mov        al,0FFh
        jmp        exit_program
assembler_error:
        mov        [con_handle],2
        call        display_user_messages
        mov        ebx,[current_line]
        test        ebx,ebx
        jz        eug_display_error_message
        push        dword 0
      eug_get_error_lines:
        mov        eax,[ebx]
        cmp        byte [eax],0
        je        eug_get_next_error_line
        push        ebx
        test        byte [ebx+7],80h
        jz        eug_display_error_line
        mov        edx,ebx
      eug_find_definition_origin:
        mov        edx,[edx+12]
        test        byte [edx+7],80h
        jnz        eug_find_definition_origin
        push        edx
      eug_get_next_error_line:
        mov        ebx,[ebx+8]
        jmp        eug_get_error_lines
      eug_display_error_line:
        mov        esi,[ebx]
        call        display_string
        mov        esi,line_number_start
        call        display_string
        mov        eax,[ebx+4]
        and        eax,7FFFFFFFh
        call        display_number
        mov        dl,']'
        call        display_character
        pop        esi
        cmp        ebx,esi
        je        eug_line_number_ok
        mov        dl,20h
        call        display_character
        push        esi
        mov        esi,[esi]
        movzx        ecx,byte [esi]
        inc        esi
        call        display_block
        mov        esi,line_number_start
        call        display_string
        pop        esi
        mov        eax,[esi+4]
        and        eax,7FFFFFFFh
        call        display_number
        mov        dl,']'
        call        display_character
      eug_line_number_ok:
        mov        esi,line_data_start
        call        display_string
        mov        esi,ebx
        mov        edx,[esi]
        call        open
        mov        al,2
        xor        edx,edx
        call        lseek
        mov        edx,[esi+8]
        sub        eax,edx
        jz        eug_line_data_displayed
        push        eax
        xor        al,al
        call        lseek
        mov        ecx,[esp]
        mov        edx,[additional_memory]
        lea        eax,[edx+ecx]
        cmp        eax,[additional_memory_end]
        ja        out_of_memory
        call        read
        call        close
        pop        ecx
        mov        esi,[additional_memory]
      eug_get_line_data:
        mov        al,[esi]
        cmp        al,0Ah
        je        eug_display_line_data
        cmp        al,0Dh
        je        eug_display_line_data
        cmp        al,1Ah
        je        eug_display_line_data
        or        al,al
        jz        eug_display_line_data
        inc        esi
        loop        eug_get_line_data
      eug_display_line_data:
        mov        ecx,esi
        mov        esi,[additional_memory]
        sub        ecx,esi
        call        display_block
      eug_line_data_displayed:
        mov        esi,lf
        call        display_string
        pop        ebx
        or        ebx,ebx
        jnz        eug_display_error_line
        cmp        [preprocessing_done],0
        je        eug_display_error_message
        mov        esi,preprocessed_instruction_prefix
        call        display_string
        mov        esi,[current_line]
        add        esi,16
        mov        edi,[additional_memory]
        xor        dl,dl
      eug_convert_instruction:
        lodsb
        cmp        al,1Ah
        je        eug_copy_symbol
        cmp        al,22h
        je        eug_copy_symbol
        cmp        al,3Bh
        je        eug_instruction_converted
        stosb
        or        al,al
        jz        eug_instruction_converted
        xor        dl,dl
        jmp        eug_convert_instruction
      eug_copy_symbol:
        or        dl,dl
        jz        eug_space_ok
        mov        byte [edi],20h
        inc        edi
      eug_space_ok:
        cmp        al,22h
        je        eug_quoted
        lodsb
        movzx        ecx,al
        rep        movsb
        or        dl,-1
        jmp        eug_convert_instruction
      eug_quoted:
        mov        al,27h
        stosb
        lodsd
        mov        ecx,eax
        jecxz        eug_quoted_copied
      eug_copy_quoted:
        lodsb
        stosb
        cmp        al,27h
        jne        eug_quote_ok
        stosb
      eug_quote_ok:
        loop        eug_copy_quoted
      eug_quoted_copied:
        mov        al,27h
        stosb
        or        dl,-1
        jmp        eug_convert_instruction
      eug_instruction_converted:
        xor        al,al
        stosb
        mov        esi,[additional_memory]
        call        display_string
        mov        esi,lf
        call        display_string
      eug_display_error_message:
        mov        esi,error_prefix
        call        display_string
        pop        esi
        call        display_string
        mov        esi,error_suffix
        call        display_string
        mov        al,2
        jmp        exit_program

; ==========================================================
; ЧАС ДЛЯ ЗАГОЛОВКІВ ФОРМАТІВ
; Реального RTC з датою в ядрі поки немає, тому віддаємо
; фіксовану мітку. На результат асемблювання це не впливає —
; timestamp потрапляє лише в заголовки PE/ELF.
; ==========================================================
make_timestamp:
        mov     eax,0
        cdq
        ret

; ==========================================================
; РЯДКИ, ЯКІ ВИКОРИСТОВУЄ ЯДРО FASM
; У Linux-версії вони теж лежать саме тут, у SYSTEM.INC.
; error_suffix навмисно БЕЗ нуля — далі одразу йде lf, і разом
; вони утворюють ".\n". Не міняти порядок!
; ==========================================================
_dbg_open       db 'DBG open  fd=',0
_dbg_seek       db 'DBG lseek pos=',0
_dbg_want       db 'DBG read  want=',0
_dbg_read       db 'DBG read  got=',0
_dbg_nl         db 0Ah,0

align 8
dbg_save_rax    dq ?
dbg_save_rbx    dq ?
dbg_save_rcx    dq ?
dbg_save_rdx    dq ?
dbg_save_rsi    dq ?
dbg_save_rdi    dq ?
dbg_save_val    dd ?
dbg_save_pad    dd ?

error_prefix                    db 'error: ',0
error_suffix                    db '.'
lf                              db 0Ah,0
line_number_start               db ' [',0
line_data_start                 db ':',0Ah,0
preprocessed_instruction_prefix db 'processed: ',0
