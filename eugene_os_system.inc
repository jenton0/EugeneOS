; ============================================================
; EugeneOS platform layer for FASM
; Syscalls via int 0x80, flat binary, org 0x4000000
; ============================================================

format binary
use64
org 0x4000000

; ----------- Внутрішня таблиця файлів FASM -----------
MAX_FASM_FILES  equ 8
FASM_BUF_SIZE   equ 0x800000    ; 8MB на файл

section '.fasm_data' writeable
fasm_file_bufs  times MAX_FASM_FILES dq 0   ; вказівники на буфери
fasm_file_sizes times MAX_FASM_FILES dq 0   ; розміри
fasm_file_pos   times MAX_FASM_FILES dq 0   ; поточна позиція
fasm_file_names times MAX_FASM_FILES * 64 db 0 ; імена файлів
fasm_file_write times MAX_FASM_FILES db 0   ; 1=write mode

; Статичний пул пам'яті для FASM (замість mmap)
; Розміщуємо одразу після коду
align 0x1000
fasm_heap_start:
    rb 0x2000000    ; 32MB для FASM (source буфер + output + working space)
fasm_heap_ptr dq fasm_heap_start

; ----------- Syscall макроси -----------
macro eugene_sys num, arg1, arg2, arg3 {
    if num eq 0
        xor rax, rax
    else
        mov rax, num
    end if
    if ~ arg1 eq
        mov rsi, arg1
    end if
    if ~ arg2 eq
        mov rdi, arg2
    end if
    if ~ arg3 eq
        mov rdx, arg3
    end if
    int 0x80
}

; ----------- Виділення пам'яті (замість mmap) -----------
; Вхід: RCX = розмір
; Вихід: RAX = вказівник (або 0 при помилці)
eugene_alloc:
    mov rax, [fasm_heap_ptr]
    add qword [fasm_heap_ptr], rcx
    ; вирівнюємо до 4096
    add qword [fasm_heap_ptr], 0xFFF
    and qword [fasm_heap_ptr], ~0xFFF
    ret

; ----------- Пошук вільного слоту -----------
; Вихід: RAX = індекс (0..7) або -1
eugene_alloc_slot:
    xor rax, rax
.slot_loop:
    cmp rax, MAX_FASM_FILES
    jge .slot_fail
    cmp qword [fasm_file_bufs + rax*8], 0
    je  .slot_ok
    inc rax
    jmp .slot_loop
.slot_fail:
    mov rax, -1
    ret
.slot_ok:
    ret

; ----------- open_file (read mode) -----------
; Вхід: RDI = вказівник на рядок імені (null-terminated)
; Вихід: RAX = fd (>=3) або -1
open_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    call eugene_alloc_slot
    cmp rax, -1
    je  .of_fail
    mov rbx, rax        ; rbx = слот

    ; Зберігаємо ім'я
    lea rsi, [fasm_file_names + rbx*64]
    push rdi
    push rbx
    mov rcx, 63
.of_copy_name:
    mov al, [rdi]
    mov [rsi], al
    test al, al
    jz  .of_name_done
    inc rdi
    inc rsi
    dec rcx
    jnz .of_copy_name
    mov byte [rsi], 0
.of_name_done:
    pop rbx
    pop rdi

    ; Виділяємо буфер
    mov rcx, FASM_BUF_SIZE
    call eugene_alloc
    test rax, rax
    jz  .of_fail
    mov [fasm_file_bufs + rbx*8], rax   ; зберігаємо вказівник

    ; Читаємо файл через syscall 5
    ; RAX=5, RSI=ім'я, R9=буфер
    push rbx
    mov rsi, rdi        ; ім'я файлу
    mov r9, [fasm_file_bufs + rbx*8]
    mov rax, 5
    int 0x80            ; RAX = розмір прочитаного
    pop rbx

    test rax, rax
    jz  .of_fail_free

    mov [fasm_file_sizes + rbx*8], rax
    mov qword [fasm_file_pos + rbx*8], 0
    mov byte [fasm_file_write + rbx], 0
    lea rax, [rbx + 3]  ; fd = slot + 3

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

.of_fail_free:
    mov qword [fasm_file_bufs + rbx*8], 0
.of_fail:
    mov rax, -1
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ----------- create_file (write mode) -----------
; Вхід: RDI = вказівник на ім'я
; Вихід: RAX = fd або -1
create_file:
    push rbx
    push rsi
    push rdi

    call eugene_alloc_slot
    cmp rax, -1
    je  .cf_fail
    mov rbx, rax

    ; Зберігаємо ім'я
    lea rsi, [fasm_file_names + rbx*64]
    push rdi
    push rbx
    mov rcx, 63
.cf_copy:
    mov al, [rdi]
    mov [rsi], al
    test al, al
    jz  .cf_copy_done
    inc rdi
    inc rsi
    dec rcx
    jnz .cf_copy
    mov byte [rsi], 0
.cf_copy_done:
    pop rbx
    pop rdi

    ; Виділяємо буфер для вихідного файлу (16MB = досить для ядра)
    mov rcx, 0x1000000
    call eugene_alloc
    test rax, rax
    jz  .cf_fail
    mov [fasm_file_bufs + rbx*8], rax
    mov qword [fasm_file_sizes + rbx*8], 0
    mov qword [fasm_file_pos + rbx*8], 0
    mov byte [fasm_file_write + rbx], 1

    lea rax, [rbx + 3]
    pop rdi
    pop rsi
    pop rbx
    ret
.cf_fail:
    mov rax, -1
    pop rdi
    pop rsi
    pop rbx
    ret

; ----------- read_file -----------
; Вхід: RBX = fd, RCX = буфер, RDX = кількість байт
; Вихід: RAX = прочитано (0 = кінець)
read_file:
    push rsi
    push rdi
    push rbx
    push rcx
    push rdx

    sub rbx, 3
    mov rsi, [fasm_file_bufs + rbx*8]
    add rsi, [fasm_file_pos + rbx*8]
    mov rax, [fasm_file_sizes + rbx*8]
    sub rax, [fasm_file_pos + rbx*8]   ; залишилось
    test rax, rax
    jle .rf_eof
    cmp rax, rdx
    jle .rf_read
    mov rax, rdx
.rf_read:
    push rax
    mov rdi, rcx
    mov rcx, rax
    cld
    rep movsb
    pop rax
    add [fasm_file_pos + rbx*8], rax
    pop rdx
    pop rcx
    pop rbx
    pop rdi
    pop rsi
    ret
.rf_eof:
    xor rax, rax
    pop rdx
    pop rcx
    pop rbx
    pop rdi
    pop rsi
    ret

; ----------- write_file -----------
; Вхід: RBX = fd, RCX = буфер, RDX = кількість байт
; Вихід: RAX = записано
write_file:
    push rsi
    push rdi
    push rbx
    push rcx
    push rdx

    sub rbx, 3
    mov rdi, [fasm_file_bufs + rbx*8]
    add rdi, [fasm_file_pos + rbx*8]
    mov rsi, rcx
    mov rax, rdx
    push rax
    mov rcx, rdx
    cld
    rep movsb
    pop rax
    add [fasm_file_pos + rbx*8], rax
    mov rcx, [fasm_file_pos + rbx*8]
    cmp rcx, [fasm_file_sizes + rbx*8]
    jle .wf_done
    mov [fasm_file_sizes + rbx*8], rcx
.wf_done:
    pop rdx
    pop rcx
    pop rbx
    pop rdi
    pop rsi
    ret

; ----------- seek_file -----------
; Вхід: RBX = fd, RCX = offset, RDX = whence (0=SET,1=CUR,2=END)
; Вихід: RAX = нова позиція
seek_file:
    sub rbx, 3
    cmp rdx, 0
    je  .sf_set
    cmp rdx, 1
    je  .sf_cur
    ; SEEK_END
    mov rax, [fasm_file_sizes + rbx*8]
    add rax, rcx
    mov [fasm_file_pos + rbx*8], rax
    ret
.sf_cur:
    add rcx, [fasm_file_pos + rbx*8]
.sf_set:
    mov [fasm_file_pos + rbx*8], rcx
    mov rax, rcx
    ret

; ----------- close_file -----------
; Вхід: RBX = fd
close_file:
    push rsi
    push rdx
    push rbx

    sub rbx, 3
    cmp byte [fasm_file_write + rbx], 1
    jne .cf_no_flush

    ; Скидаємо буфер на диск через syscall 14
    lea rsi, [fasm_file_names + rbx*64]
    mov rdi, [fasm_file_bufs + rbx*8]
    mov rdx, [fasm_file_sizes + rbx*8]
    mov rax, 14
    int 0x80

.cf_no_flush:
    mov qword [fasm_file_bufs + rbx*8], 0
    mov qword [fasm_file_sizes + rbx*8], 0
    mov qword [fasm_file_pos + rbx*8], 0
    mov byte  [fasm_file_write + rbx], 0

    pop rbx
    pop rdx
    pop rsi
    ret

; ----------- sys_exit -----------
; Вхід: RBX = код виходу
sys_exit:
    xor rax, rax
    int 0x80
    jmp $

; ----------- display_string (для помилок FASM) -----------
; Вхід: RDI = рядок, RSI = довжина
display_string:
    push rsi
    push rdi
    mov rsi, rdi
    mov rax, 2
    int 0x80
    pop rdi
    pop rsi
    ret