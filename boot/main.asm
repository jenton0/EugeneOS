format PE64 EFI
entry main

section '.text' code executable readable

main:
    sub     rsp, 40             
    mov     [Handle], rcx
    mov     [SystemTable], rdx
    mov     rbx, rdx            

    ; --- 1. ГЛУШИМО ТЕКСТОВУ КОНСОЛЬ UEFI ---
    mov     rcx, [SystemTable]
    mov     rcx, [rcx + 64]     ; ConOut
    mov     rax, [rcx + 48]     ; ClearScreen
    call    rax

    ; --- 2. ІНІЦІАЛІЗАЦІЯ UEFI (Boot Services) ---
    mov     rcx, [rbx + 96]     
    mov     [BS], rcx

    ; --- 3. ГРАФІКА (GOP) ---
    mov     rax, [rcx + 320]    
    lea     rcx, [GOP_GUID]
    xor     rdx, rdx
    lea     r8,  [gop_interface]
    call    rax
    test    rax, rax
    jnz     error_video         

   ; --- 4. ОТРИМАННЯ ДАНИХ ЕКРАНА ---
    mov     rcx, [gop_interface]
    mov     rsi, [rcx + 24]     
    mov     rdi, [rsi + 24]     
    mov     [ScreenBase], rdi
    
    mov     r10, [rsi + 8]      ; Зберігаємо вказівник у R10
    mov     eax, [r10 + 4]      ; Читаємо ширину
    mov     [ScreenWidth], eax
    mov     eax, [r10 + 8]      ; Читаємо висоту (тепер R10 не затертий!)
    mov     [ScreenHeight], eax

    ; --- 5. ЗБІР ІНФОРМАЦІЇ ПРО ЗАЛІЗО ---
    call    GetHardwareInfo     
    call    GetRamInfo          
    call    GetDiskInfo         

    ; --- 6. ВІДМАЛЬОВКА СТАТИЧНОГО ІНТЕРФЕЙСУ ---
    mov     ecx, 0x000000AA     ; Фон (Темно-синій)
    call    FillScreen

    mov     rcx, 40
    mov     rdx, 40
    lea     r8,  [MsgTitle]
    mov     r9d, 0x00FFFFFF     
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 60
    lea     r8,  [MsgLine]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color

    ; --- БЛОК 1: SYSTEM INFORMATION ---
    mov     rcx, 40
    mov     rdx, 100
    lea     r8,  [MsgSysInfo]
    mov     r9d, 0x00FFFF00     
    call    DrawString_Color

    ; CPU / RAM / DISK / FW
    mov     rcx, 40
    mov     rdx, 130
    lea     r8,  [MsgCPU]
    mov     r9d, 0x00AAAAAA     
    call    DrawString_Color
    mov     rcx, 150
    mov     rdx, 130
    lea     r8,  [CPUBrandString]
    mov     r9d, 0x00FFFFFF     
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 155
    lea     r8,  [MsgRAM]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 150
    mov     rdx, 155
    lea     r8,  [RamStr]
    mov     r9d, 0x00FFFFFF
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 180
    lea     r8,  [MsgDisk]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 150
    mov     rdx, 180
    lea     r8,  [DiskStr]
    mov     r9d, 0x00FFFFFF
    call    DrawString_Color

    ; --- БЛОК 2: HEALTH MONITORING (ЗАГОТОВКА) ---
    mov     rcx, 40
    mov     rdx, 220
    lea     r8,  [MsgHealth]
    mov     r9d, 0x00FFFF00     
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 250
    lea     r8,  [MsgTemp]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 150
    mov     rdx, 250
    lea     r8,  [MsgUnknown]
    mov     r9d, 0x00FF0000     ; Червоний
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 275
    lea     r8,  [MsgFan]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 150
    mov     rdx, 275
    lea     r8,  [MsgUnknown]
    mov     r9d, 0x00FF0000
    call    DrawString_Color

    ; Заголовок меню
    mov     rcx, 40
    mov     rdx, 330
    lea     r8,  [MsgBootMenu]
    mov     r9d, 0x00FFFF00     
    call    DrawString_Color

    ; --- 7. ГОЛОВНИЙ ЦИКЛ ІНТЕРАКТИВНОГО МЕНЮ ---
menu_loop:
    call    DrawMenu

wait_key:
    mov     rcx, [SystemTable]
    mov     rcx, [rcx + 48]     ; ConIn
    lea     rdx, [KeyInput]
    mov     rax, [rcx + 8]      ; ReadKeyStroke
    call    rax
    cmp     rax, 0
    jne     wait_key

    mov     ax, [KeyInput]      ; ScanCode
    cmp     ax, 0x01            ; UP
    je      .move_up
    cmp     ax, 0x02            ; DOWN
    je      .move_down
    mov     ax, [KeyInput + 2]
    cmp     ax, 0x0D            ; ENTER
    je      .execute
    jmp     wait_key

.move_up:
    cmp     byte [MenuIndex], 0
    je      .wrap_bottom
    dec     byte [MenuIndex]
    jmp     menu_loop
.wrap_bottom:
    mov     byte [MenuIndex], 2
    jmp     menu_loop

.move_down:
    cmp     byte [MenuIndex], 2
    je      .wrap_top
    inc     byte [MenuIndex]
    jmp     menu_loop
.wrap_top:
    mov     byte [MenuIndex], 0
    jmp     menu_loop

.execute:
    cmp     byte [MenuIndex], 0
    je      action_load
    cmp     byte [MenuIndex], 1
    je      action_reboot
    cmp     byte [MenuIndex], 2
    je      action_shutdown

; ==========================================================
; СЕКЦІЯ ДІЙ ТА СИСТЕМНИХ ВИКЛИКІВ
; ==========================================================
action_reboot:
    mov     rax, [SystemTable]
    mov     rax, [rax + 0x58]   ; RuntimeServices
    mov     r10, [rax + 0x68]   ; ResetSystem
    mov     rcx, 0              ; EfiResetCold
    xor     rdx, rdx
    xor     r8,  r8
    xor     r9,  r9
    sub     rsp, 32
    call    r10
    jmp     $

action_shutdown:
    mov     rax, [SystemTable]
    mov     rax, [rax + 0x58]   ; RuntimeServices
    mov     r10, [rax + 0x68]   ; ResetSystem
    mov     rcx, 2              ; EfiResetShutdown
    xor     rdx, rdx
    xor     r8,  r8
    xor     r9,  r9
    sub     rsp, 32
    call    r10
    jmp     $

action_load:
    mov     rcx, [Handle]
    lea     rdx, [EFI_LOADED_IMAGE_PROTOCOL_GUID]
    lea     r8,  [LoadedImage]
    mov     rax, [BS]
    call    qword [rax + 0x98]  
    mov     rax, [LoadedImage]
    mov     rcx, [rax + 0x18]
    mov     [DeviceHandle], rcx
    lea     rdx, [EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID]
    lea     r8,  [FileSystem]
    mov     rax, [BS]
    call    qword [rax + 0x98]
    mov     rcx, [FileSystem]
    lea     rdx, [RootFolder]
    mov     rax, [rcx + 0x08]   
    call    rax
    mov     rcx, [RootFolder]
    lea     rdx, [FileHandle]
    lea     r8,  [KernelPath]
    mov     r9,  1              
    sub     rsp, 32
    mov     qword [rsp + 32], 0
    mov     rax, [rcx + 0x08]   
    call    rax
    add     rsp, 32
    mov     rcx, [FileHandle]
    lea     rdx, [KernelSize]
    mov     r8,  [KernelBuffer]
    mov     rax, [rcx + 0x20]   
    call    rax

    mov     ecx, 0x00000000     
    call    FillScreen

exit_uefi_loop:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64
    and     rsp, -16
    mov     qword [MemoryMapSize], 65536
    lea     rcx, [MemoryMapSize]
    lea     rdx, [MemoryMap]
    lea     r8,  [MapKey]
    lea     r9,  [DescriptorSize]
    lea     rax, [DescriptorVersion]
    mov     [rsp+32], rax
    mov     rax, [BS]
    call    qword [rax + 0x28]  
    mov     rcx, [Handle]
    mov     rdx, [MapKey]
    mov     rax, [BS]
    call    qword [rax + 0x38]  
    mov     rsp, rbp
    pop     rbp
    test    rax, rax
    jnz     exit_uefi_loop      

    mov     rcx, [ScreenBase]
    mov     edx, [ScreenWidth]
    mov     r8d, [ScreenHeight]
    jmp     qword [KernelBuffer]

DrawMenu:
    push    rax rcx rdx r8 r9
    mov     rcx, 40
    mov     rdx, 370
    lea     r8,  [MsgOpt0]
    mov     r9d, 0x00555555
    cmp     byte [MenuIndex], 0
    jne     .d0
    mov     r9d, 0x0000FF00
.d0: call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 400
    lea     r8,  [MsgOpt1]
    mov     r9d, 0x00555555
    cmp     byte [MenuIndex], 1
    jne     .d1
    mov     r9d, 0x0000FF00
.d1: call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 430
    lea     r8,  [MsgOpt2]
    mov     r9d, 0x00555555
    cmp     byte [MenuIndex], 2
    jne     .d2
    mov     r9d, 0x0000FF00
.d2: call    DrawString_Color
    pop     r9 r8 rdx rcx rax
    ret

; ==========================================================
; ОБРОБНИКИ ПОМИЛОК
; ==========================================================
error_video: 
    jmp $
error_disk: 
    mov ecx, 0x000000FF 
    call FillScreen
    jmp $
error_file_missing: 
    mov ecx, 0x0000FFFF 
    call FillScreen
    jmp $

; ==========================================================
; ДОПОМІЖНІ ФУНКЦІЇ (HARDWARE / GRAPHICS)
; ==========================================================
GetHardwareInfo:
    push    rax rbx rcx rdx
    mov     eax, 0x80000002
    cpuid
    mov     dword [CPUBrandString], eax
    mov     dword [CPUBrandString+4], ebx
    mov     dword [CPUBrandString+8], ecx
    mov     dword [CPUBrandString+12], edx
    mov     eax, 0x80000003
    cpuid
    mov     dword [CPUBrandString+16], eax
    mov     dword [CPUBrandString+20], ebx
    mov     dword [CPUBrandString+24], ecx
    mov     dword [CPUBrandString+28], edx
    mov     eax, 0x80000004
    cpuid
    mov     dword [CPUBrandString+32], eax
    mov     dword [CPUBrandString+36], ebx
    mov     dword [CPUBrandString+40], ecx
    mov     dword [CPUBrandString+44], edx
    pop     rdx rcx rbx rax
    ret

GetRamInfo:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64
    mov     qword [MemoryMapSize], 65536
    lea     rcx, [MemoryMapSize]
    lea     rdx, [MemoryMap]
    lea     r8,  [MapKey]
    lea     r9,  [DescriptorSize]
    lea     rax, [DescriptorVersion]
    mov     [rsp+32], rax
    mov     rax, [BS]
    call    qword [rax + 0x28]
    test    rax, rax
    jnz     .done
    xor     r10, r10
    mov     rsi, MemoryMap
    mov     rcx, [MemoryMapSize]
    mov     rbx, [DescriptorSize]
.ml: cmp rcx, 0
    jle .md
    mov eax, dword [rsi]
    cmp eax, 7
    jne .s
    add r10, qword [rsi + 24]
.s: add rsi, rbx
    sub rcx, rbx
    jmp .ml
.md: shr r10, 8
    add r10, 32
    and r10, -64
    mov rax, r10
    lea     rdi, [RamStr]
    call    UInt64ToDecString
    mov     dword [rdi], 0x00424D20
.done: mov rsp, rbp
    pop rbp
    ret

GetDiskInfo:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov rcx, [Handle]
    lea rdx, [EFI_LOADED_IMAGE_PROTOCOL_GUID]
    lea r8, [LoadedImage]
    mov rax, [BS]
    call qword [rax + 0x98]
    mov rax, [LoadedImage]
    mov rcx, [rax + 0x18]
    mov [DeviceHandle], rcx
    lea rdx, [EFI_BLOCK_IO_PROTOCOL_GUID]
    lea r8, [BlockIO]
    mov rax, [BS]
    call qword [rax + 0x98]
    mov rax, [BlockIO]
    mov rbx, [rax + 8]
    mov eax, dword [rbx + 12]
    mov rcx, qword [rbx + 24]
    inc rcx
    imul rax, rcx
    shr rax, 20
    lea rdi, [DiskStr]
    call UInt64ToDecString
    mov dword [rdi], 0x00424D20
.done: mov rsp, rbp
    pop rbp
    ret

UInt64ToDecString:
    push rbx rcx rdx rsi
    mov rcx, 10
    mov rbx, rsp
    sub rsp, 32
    mov rsi, rsp
.l: xor rdx, rdx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .l
.c: mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    cmp rsi, rsp
    jne .c
    mov byte [rdi], 0
    mov rsp, rbx
    pop rsi rdx rcx rbx
    ret

FillScreen:
    push    rdi rax rcx rdx
    mov     eax, ecx
    mov     rdi, [ScreenBase]
    
    ; Рахуємо кількість пікселів у 64-бітних регістрах
    movsxd  rcx, dword [ScreenWidth]
    movsxd  rdx, dword [ScreenHeight]
    imul    rcx, rdx
    
    cld                         ; ОБОВ'ЯЗКОВО! Гарантує запис вперед
    rep     stosd
    
    pop     rdx rcx rax rdi
    ret

DrawString_Color:
    push rbx rax rsi r9
    mov rsi, r8
.l: xor rax, rax
    lodsb
    test al, al
    jz .d
    sub al, 32
    imul ax, 8
    lea r8, [FontData + rax]
    push rcx rdx
    call DrawChar
    pop rdx rcx
    add rcx, 9
    jmp .l
.d: pop r9 rsi rax rbx
    ret

DrawChar:
    push rdi rax rbx rcx rdx rsi
    mov eax, [ScreenWidth]
    imul rax, rdx
    add rax, rcx
    shl rax, 2
    add rax, [ScreenBase]
    mov rdi, rax
    mov ebx, [ScreenWidth]
    shl ebx, 2
    sub ebx, 32
    mov rcx, 8
    mov rsi, r8
.y: mov al, [rsi + rcx - 1]
    mov dl, 8
.x: shl al, 1
    jnc .s
    mov dword [rdi], r9d
.s: add rdi, 4
    dec dl
    jnz .x
    add rdi, rbx
    loop .y
    pop rsi rdx rcx rbx rax rdi
    ret

; ==========================================================
; DATA SECTION
; ==========================================================
section '.data' data readable writeable

Handle          dq 0
SystemTable     dq 0
BS              dq 0
gop_interface   dq 0
ScreenBase      dq 0
ScreenWidth     dd 0
ScreenHeight    dd 0
KeyInput        dw 0, 0
MenuIndex       db 0

MsgTitle        db 'EUGENE OS - UEFI SETUP UTILITY V1.3', 0
MsgLine         db '==================================================', 0
MsgSysInfo      db '--- SYSTEM INFORMATION ---', 0
MsgCPU          db 'PROCESSOR :', 0
MsgRAM          db 'RAM SIZE  :', 0
MsgDisk         db 'DISK SIZE :', 0
MsgHealth       db '--- HEALTH MONITORING ---', 0
MsgTemp         db 'CPU TEMP  :', 0
MsgFan          db 'FAN SPEED :', 0
MsgUnknown      db 'UNKNOWN / N/A', 0

CPUBrandString  db 'DETECTING CPU...', 0 
                times 48 db 0
RamStr          db 'UNKNOWN   ', 0, 0, 0, 0, 0, 0, 0, 0, 0
DiskStr         db 'DETECTING...', 0, 0, 0, 0, 0, 0, 0, 0, 0
MsgFWData       db 'UEFI 64-BIT NATIVE', 0

MsgBootMenu     db '--- BOOT OPTIONS --- (Use ARROWS and ENTER)', 0
MsgOpt0         db '[ 1 ] BOOT EUGENE OS CORE', 0
MsgOpt1         db '[ 2 ] REBOOT SYSTEM', 0
MsgOpt2         db '[ 3 ] SHUTDOWN VM', 0

align 16
GOP_GUID: db 0xDE, 0xA9, 0x42, 0x90, 0xDC, 0x23, 0x38, 0x4A, 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A
align 16
EFI_LOADED_IMAGE_PROTOCOL_GUID: db 0xA1, 0x31, 0x1B, 0x5B, 0x62, 0x95, 0xD2, 0x11, 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
align 16
EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID: db 0x22, 0x5B, 0x4E, 0x96, 0x59, 0x64, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
align 16
EFI_BLOCK_IO_PROTOCOL_GUID: db 0x21, 0x5B, 0x4E, 0x96, 0x59, 0x64, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B

LoadedImage dq 0
DeviceHandle dq 0
FileSystem dq 0
RootFolder dq 0
FileHandle dq 0
BlockIO dq 0
KernelBuffer dq 0x100000
KernelSize dq 0x100000
KernelPath dw 'k','e','r','n','e','l','.','b','i','n', 0
MemoryMapSize dq 65536
MapKey dq 0
DescriptorSize dq 0
DescriptorVersion dd 0
MemoryMap rb 65536

align 8
FontData:
    dq 0
    dq 0x1818181818001800, 0x2424240000000000, 0x24247E247E242400, 0x183C603C063C1800
    dq 0x66C6181830660000, 0x386C3876DC000000, 0x1818300000000000, 0x0C183030180C0000
    dq 0x30180C0C18300000, 0x00663CFF3C660000, 0x0018187E18180000, 0x0000000000181830
    dq 0x0000007E00000000, 0x0000000000181800, 0x006030180C060000
    dq 0x3C666666663C0000, 0x18381818183C0000, 0x3C660C18307E0000, 0x3C660C0C663C0000
    dq 0x0C1C3C6C7E0C0000, 0x7E603E06063C0000, 0x1C30603C663C0000, 0x7E060C1830300000
    dq 0x3C663C663C000000, 0x3C663C060C380000
    dq 0x0018180018180000, 0x0018180018183000, 0x060C1830180C0600, 0x00007E007E000000
    dq 0x6030180C18306000, 0x3C660C1800180000, 0x3C666E6E603E0000
    dq 0x183C66667E666600, 0x7E66667E66667E00, 0x3C66606060663C00, 0x7C66666666667C00
    dq 0x7E60607860607E00, 0x7E60607860606000, 0x3C66606E663C0000, 0x6666667E66666600
    dq 0x3C18181818183C00, 0x1E060606663C0000, 0x666C78786C660000, 0x6060606060607E00
    dq 0x63777F6B63630000, 0x66767F6E66660000, 0x3C666666663C0000
    dq 0x7E66667E60600000, 0x3C6666666C360000, 0x7E66667E6C660000, 0x3C603C06663C0000
    dq 0x7E18181818180000, 0x66666666663C0000, 0x666666663C180000, 0x63636B7F77630000
    dq 0x66663C183C660000, 0x66663C1818180000, 0x7E060C18307E0000
    dq 0x3C303030303C0000, 0x00060C1830600000, 0x3C0C0C0C0C3C0000
    
section '.reloc' fixups data discardable