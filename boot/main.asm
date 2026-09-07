format PE64 EFI
entry main

; ==========================================================
; ЗМІЩЕННЯ В ТАБЛИЦЯХ UEFI
;
; EFI_BOOT_SERVICES починається з EFI_TABLE_HEADER на 24 байти
; (Signature 8 + Revision 4 + HeaderSize 4 + CRC32 4 + Reserved 4),
; далі йдуть покажчики на функції по 8 байтів кожен. Звідси:
;
;   24 RaiseTPL      32 RestoreTPL    40 AllocatePages  48 FreePages
;   56 GetMemoryMap  64 AllocatePool  ...  152 HandleProtocol
;   ...  232 ExitBootServices  ...  320 LocateProtocol
;
; Числа тут іменовані навмисно: голі 0x28 і 0x38 у коді вже один
; раз коштували нам того, що ExitBootServices ніколи не викликався.
; ==========================================================
BS_ALLOCATE_PAGES     equ 0x28    ; 40
BS_GET_MEMORY_MAP     equ 0x38    ; 56
BS_FREE_POOL          equ 0x48    ; 72
BS_HANDLE_PROTOCOL    equ 0x98    ; 152
BS_EXIT_BOOT_SERVICES equ 0xE8    ; 232
BS_STALL              equ 0xF8    ; 248
BS_LOCATE_PROTOCOL    equ 320

; EFI_FILE_PROTOCOL
FILE_OPEN             equ 0x08
FILE_CLOSE            equ 0x10
FILE_READ             equ 0x20
FILE_GET_INFO         equ 0x40

; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL
CONOUT_OUTPUT_STRING  equ 0x08

; EFI_GRAPHICS_OUTPUT_PROTOCOL
GOP_QUERY_MODE        equ 0
GOP_SET_MODE          equ 8
GOP_BLT               equ 16
GOP_MODE              equ 24

; Аргументи AllocatePages
ALLOCATE_ADDRESS      equ 2
EFI_LOADER_DATA       equ 2

; --- БЛОК ВІДОМОСТЕЙ ДЛЯ ЯДРА ---
; Лежить одразу за образом ядра, у ділянці 2..16 МБ, яку ядро ні під
; що не використовує (наступна зайнята адреса - 0x1000000).
; Розкладка: +0 підпис, +8 адреса карти, +16 розмір карти,
; +24 розмір дескриптора, +28 версія дескриптора.
BOOTINFO_BASE  equ 0x200000
BOOTINFO_HDR   equ 32
BOOTINFO_PAGES equ 17          ; 32 байти заголовка + 64 КБ карти
BOOTINFO_SIG   equ 0x31544F4F42475545   ; 'EUGBOOT1'

; Скільки режимів готові показати. Прошивки зазвичай дають одиниці,
; але специфікація стелі не ставить, тому список обрізаємо.
MAX_MODES             equ 32

; EFI_GRAPHICS_PIXEL_FORMAT (MODE_INFORMATION +12)
;
; Досі код мовчки припускав формат 1 і на цьому стенді був правий:
; QEMU видає BGR у всіх 30 режимах. Але припущення - не гарантія.
PIXEL_FORMAT_RGB      equ 0     ; PixelRedGreenBlueReserved8BitPerColor
PIXEL_FORMAT_BGR      equ 1     ; PixelBlueGreenRedReserved8BitPerColor
PIXEL_FORMAT_MASK     equ 2     ; PixelBitMask - маски в PixelInformation
PIXEL_FORMAT_BLT      equ 3     ; PixelBltOnly - лінійного буфера НЕМАЄ

; EFI_GRAPHICS_OUTPUT_BLT_OPERATION
BLT_VIDEO_FILL        equ 0

; Скільки разів проганяти кожен вимір, щоб усереднити
BENCH_PASSES          equ 10
BENCH_IO_PASSES       equ 3
BENCH_BUF_SIZE        equ 262144

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

    ; Калібрування лічильника тактів. Робиться до всього іншого,
    ; бо далі кожен етап старту засікається саме ним.
    call    CalibrateTSC
    call    ReadTSC
    mov     [StageT0], rax

    ; --- 3. ГРАФІКА (GOP) ---
    mov     rax, [rcx + 320]
    lea     rcx, [GOP_GUID]
    xor     rdx, rdx
    lea     r8,  [gop_interface]
    call    rax
    test    rax, rax
    jnz     error_video

    ; --- 4. ОТРИМАННЯ ДАНИХ ЕКРАНА ---
    call    ReadGopMode
    call    ReadTSC
    mov     [StageT1], rax

    ; --- 4b. ПЕРЕЛІК ДОСТУПНИХ РЕЖИМІВ ---
    call    EnumModes
    call    ReadTSC
    mov     [StageT2], rax

    ; --- 4c. ЧИ Є ВЗАГАЛІ ЛІНІЙНИЙ ФРЕЙМБУФЕР ---
    ;
    ; PixelBltOnly означає, що прошивка не дає прямого доступу до
    ; відеопам'яті: малювати можна лише через GOP Blt(). Уся наша
    ; графіка - і завантажувача, і ядра - пише у фреймбуфер напряму,
    ; тому такий режим для нас непридатний, а ScreenBase у ньому
    ; взагалі не має сенсу. Але це не привід одразу здаватись:
    ; спершу шукаємо в переліку режим із лінійним буфером.
    cmp     dword [ScreenFormat], PIXEL_FORMAT_BLT
    jne     .fb_ok

    call    FindLinearMode
    cmp     eax, -1
    je      error_blt

    mov     rcx, [gop_interface]
    mov     edx, eax
    sub     rsp, 32
    mov     rax, [gop_interface]
    mov     rax, [rax + GOP_SET_MODE]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     error_blt

    call    ReadGopMode
    cmp     dword [ScreenFormat], PIXEL_FORMAT_BLT
    je      error_blt
.fb_ok:

    ; --- 5. ЗБІР ІНФОРМАЦІЇ ПРО ЗАЛІЗО ---
    call    GetHardwareInfo
    call    GetRamInfo
    call    GetDiskInfo
    call    ReadTSC
    mov     [StageT3], rax

    ; --- 6. ВІДМАЛЬОВКА СТАТИЧНОГО ІНТЕРФЕЙСУ ---
    call    DrawSetupScreen
    call    ReadTSC
    mov     [StageT4], rax

    ; --- 7. ГОЛОВНИЙ ЦИКЛ ІНТЕРАКТИВНОГО МЕНЮ ---
    jmp     menu_loop

; ==========================================================
; ЕКРАН НАЛАШТУВАНЬ
;
; Винесено в окрему процедуру, бо після SetMode екран доводиться
; малювати заново: змінюється не лише роздільність, а й адреса
; фреймбуфера.
; ==========================================================
DrawSetupScreen:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32

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

    ; --- ВІДЕОРЕЖИМ GOP ---
    ; Показуємо не лише роздільність, а й КРОК РЯДКА. Це головне
    ; число всієї теми: специфікація дозволяє йому бути більшим за
    ; ширину, і саме на ньому ламається переносимість, якщо його
    ; ігнорувати. Хай буде видно одразу на екрані завантажувача.
    call    BuildVideoStr
    mov     rcx, 40
    mov     rdx, 205
    lea     r8,  [MsgVideo]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 150
    mov     rdx, 205
    lea     r8,  [VideoStr]
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

    mov     rsp, rbp
    pop     rbp
    ret

; ==========================================================
; ГОЛОВНИЙ ЦИКЛ ІНТЕРАКТИВНОГО МЕНЮ
; ==========================================================
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
    mov     byte [MenuIndex], 4
    jmp     menu_loop

.move_down:
    cmp     byte [MenuIndex], 4
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
    je      action_video
    cmp     byte [MenuIndex], 2
    je      action_bench
    cmp     byte [MenuIndex], 3
    je      action_reboot
    cmp     byte [MenuIndex], 4
    je      action_shutdown
    jmp     menu_loop

; ==========================================================
; ВИМІРЮВАННЯ
;
; Заливки псують екран, тому спершу міряємо, а вже потім малюємо
; результати. Кожен вимір проганяється кілька разів і ділиться -
; одиничний замір під емулятором нічого не вартий.
; ==========================================================
action_bench:
    ; --- 1. ПРЯМИЙ ЗАПИС У ФРЕЙМБУФЕР ---
    call    ReadTSC
    mov     r14, rax
    mov     r15d, BENCH_PASSES
.direct:
    mov     ecx, 0x00000020
    call    FillScreen
    dec     r15d
    jnz     .direct
    call    ReadTSC
    sub     rax, r14
    xor     rdx, rdx
    mov     rcx, BENCH_PASSES
    div     rcx
    call    TicksToUs
    mov     [BenchDirect], rax

    ; --- 2. ТЕ САМЕ ЧЕРЕЗ GOP BLT ---
    call    ReadTSC
    mov     r14, rax
    mov     r15d, BENCH_PASSES
.blt:
    call    BltFillScreen
    dec     r15d
    jnz     .blt
    call    ReadTSC
    sub     rax, r14
    xor     rdx, rdx
    mov     rcx, BENCH_PASSES
    div     rcx
    call    TicksToUs
    mov     [BenchBlt], rax

    ; --- 3. ЧИТАННЯ ЯДРА З ДИСКА ---
    call    BenchKernelRead

    ; --- 4. РЕЗУЛЬТАТИ ---
bench_loop:
    call    DrawBenchScreen
bench_key:
    mov     rcx, [SystemTable]
    mov     rcx, [rcx + 48]
    lea     rdx, [KeyInput]
    mov     rax, [rcx + 8]
    call    rax
    cmp     rax, 0
    jne     bench_key
    mov     ax, [KeyInput]
    cmp     ax, 0x17                    ; ESC
    je      .back
    mov     ax, [KeyInput + 2]
    cmp     ax, 0x0D                    ; ENTER
    je      .back
    jmp     bench_key
.back:
    call    DrawSetupScreen
    jmp     menu_loop

; ==========================================================
; ЕКРАН ВИБОРУ ВІДЕОРЕЖИМУ
;
; Тут завантажувач уперше не спостерігає за GOP, а керує ним:
; перелік через QueryMode зібрано заздалегідь у EnumModes,
; перемикання - через SetMode.
; ==========================================================
action_video:
    cmp     dword [ModeCount], 0
    je      menu_loop

video_loop:
    call    DrawVideoScreen

video_key:
    mov     rcx, [SystemTable]
    mov     rcx, [rcx + 48]         ; ConIn
    lea     rdx, [KeyInput]
    mov     rax, [rcx + 8]          ; ReadKeyStroke
    call    rax
    cmp     rax, 0
    jne     video_key

    mov     ax, [KeyInput]          ; ScanCode
    cmp     ax, 0x01                ; UP
    je      .up
    cmp     ax, 0x02                ; DOWN
    je      .down
    cmp     ax, 0x17                ; ESC
    je      .back
    mov     ax, [KeyInput + 2]      ; UnicodeChar
    cmp     ax, 0x0D                ; ENTER
    je      .apply
    jmp     video_key

.up:
    cmp     dword [ModeSel], 0
    je      .up_wrap
    dec     dword [ModeSel]
    jmp     video_loop
.up_wrap:
    mov     eax, [ModeCount]
    dec     eax
    mov     [ModeSel], eax
    jmp     video_loop

.down:
    mov     eax, [ModeSel]
    inc     eax
    cmp     eax, [ModeCount]
    jb      .down_ok
    xor     eax, eax
.down_ok:
    mov     [ModeSel], eax
    jmp     video_loop

.back:
    call    DrawSetupScreen
    jmp     menu_loop

.apply:
    ; Режим без лінійного фреймбуфера відкидаємо ще до SetMode:
    ; перемкнутись у нього означало б осліпнути.
    mov     qword [ModeFailed], 0
    mov     qword [ModeNoLinear], 0
    mov     eax, [ModeSel]
    shl     eax, 4
    lea     rdx, [ModeTable]
    add     rdx, rax
    cmp     dword [rdx + 12], PIXEL_FORMAT_BLT
    jne     .apply_ok
    mov     qword [ModeNoLinear], 1
    jmp     video_loop
.apply_ok:

    ; SetMode(This, ModeNumber). Після успіху змінюється все:
    ; роздільність, крок рядка і навіть адреса фреймбуфера, тому
    ; дані екрана перечитуються повністю.
    mov     rcx, [gop_interface]
    mov     edx, [ModeSel]
    sub     rsp, 32
    mov     rax, [gop_interface]
    mov     rax, [rax + GOP_SET_MODE]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .failed

    call    ReadGopMode
    call    DrawSetupScreen
    jmp     menu_loop

.failed:
    ; Прошивка відмовила - режим лишився старим, екран цілий.
    ; Просто повідомляємо і повертаємось до списку.
    mov     [ModeFailed], rax
    jmp     video_loop

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
    ; --- LOADED IMAGE -> ФАЙЛОВА СИСТЕМА -> КОРІНЬ ТОМУ ---
    mov     rcx, [Handle]
    lea     rdx, [EFI_LOADED_IMAGE_PROTOCOL_GUID]
    lea     r8,  [LoadedImage]
    mov     rax, [BS]
    call    qword [rax + BS_HANDLE_PROTOCOL]
    test    rax, rax
    jnz     .err_img

    mov     rax, [LoadedImage]
    mov     rcx, [rax + 0x18]
    mov     [DeviceHandle], rcx
    lea     rdx, [EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID]
    lea     r8,  [FileSystem]
    mov     rax, [BS]
    call    qword [rax + BS_HANDLE_PROTOCOL]
    test    rax, rax
    jnz     .err_fs

    mov     rcx, [FileSystem]
    lea     rdx, [RootFolder]
    mov     rax, [rcx + FILE_OPEN]      ; OpenVolume
    call    rax
    test    rax, rax
    jnz     .err_fs

    ; --- ВІДКРИТИ KERNEL.BIN ---
    mov     rcx, [RootFolder]
    lea     rdx, [FileHandle]
    lea     r8,  [KernelPath]
    mov     r9,  1                      ; EFI_FILE_MODE_READ
    sub     rsp, 32
    mov     qword [rsp + 32], 0
    mov     rax, [rcx + FILE_OPEN]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .err_open

    ; --- СПРАВЖНІЙ РОЗМІР ФАЙЛУ ---
    ;
    ; Раніше ми просто просили прочитати мегабайт і сподівались, що
    ; ядро в нього влізе. Read чесно обрізав би все, що більше, і ми
    ; стрибнули б у напівзавантажений образ без жодного попередження.
    ; EFI_FILE_INFO: +0 Size, +8 FileSize.
    mov     qword [InfoSize], 512
    mov     rcx, [FileHandle]
    lea     rdx, [EFI_FILE_INFO_GUID]
    lea     r8,  [InfoSize]
    lea     r9,  [FileInfo]
    sub     rsp, 32
    mov     rax, [rcx + FILE_GET_INFO]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .err_info

    mov     rax, qword [FileInfo + 8]
    test    rax, rax
    jz      .err_info
    mov     [KernelSize], rax
    mov     [KernelWanted], rax

    ; --- ЗАРЕЗЕРВУВАТИ ПАМ'ЯТЬ ПІД ЯДРО ---
    ;
    ; Адреса 0x100000 більше не береться на віру. Ядро - плаский
    ; образ, злінкований саме на неї, тому просимо цю конкретну
    ; адресу (AllocateAddress). Якщо прошивка тримає там своє -
    ; чесно відмовляємось замість того, щоб затерти її пам'ять.
    mov     rax, [KernelSize]
    add     rax, 0xFFF
    shr     rax, 12
    mov     [KernelPages], rax
    mov     rcx, ALLOCATE_ADDRESS
    mov     rdx, EFI_LOADER_DATA
    mov     r8,  [KernelPages]
    lea     r9,  [KernelBuffer]
    sub     rsp, 32
    mov     rax, [BS]
    call    qword [rax + BS_ALLOCATE_PAGES]
    add     rsp, 32
    test    rax, rax
    jnz     .err_mem

    ; --- ПРОЧИТАТИ ЯДРО ---
    mov     rcx, [FileHandle]
    lea     rdx, [KernelSize]
    mov     r8,  [KernelBuffer]
    sub     rsp, 32
    mov     rax, [rcx + FILE_READ]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .err_read

    ; Read повертає у KernelSize скільки насправді прочитано.
    ; Якщо це не збігається з розміром файлу - образ неповний.
    mov     rax, [KernelSize]
    cmp     rax, [KernelWanted]
    jne     .err_read

    mov     rcx, [FileHandle]
    mov     rax, [rcx + FILE_CLOSE]
    call    rax

    mov     ecx, 0x00000000
    call    FillScreen
    jmp     exit_uefi_start

.err_img:
    lea     r8, [MsgErrImg]
    jmp     Fatal
.err_fs:
    lea     r8, [MsgErrFs]
    jmp     Fatal
.err_open:
    lea     r8, [MsgErrOpen]
    jmp     Fatal
.err_info:
    lea     r8, [MsgErrInfo]
    jmp     Fatal
.err_mem:
    lea     r8, [MsgErrMem]
    jmp     Fatal
.err_read:
    lea     r8, [MsgErrRead]
    jmp     Fatal

exit_uefi_start:

    ; --- ВИХІД ЗІ СЛУЖБ ЗАВАНТАЖЕННЯ ---
    ;
    ; Тут раніше було найтихіше з усіх лих цього файлу. Стояли голі
    ; зміщення 0x28 і 0x38, тобто викликались AllocatePages зі
    ; сміттям замість аргументів (він чесно повертав помилку 2 і не
    ; робив нічого) і GetMemoryMap замість ExitBootServices.
    ; Отже служби завантаження НІКОЛИ не вимикались, і ядро
    ; стартувало поверх живої прошивки. Працювало це лише тому, що
    ; ядро одразу ставить свої GDT/IDT і перепрограмовує контролер
    ; переривань, після чого прошивка вже не отримує керування і
    ; не має нагоди поскаржитись.
    ;
    ; MapKey протухає від будь-якої зміни карти пам'яті, тому карту
    ; беремо заново перед кожною спробою. Кількість спроб обмежена:
    ; краще чесно сказати про поразку, ніж зависнути назавжди.
    ; --- МІСЦЕ ПІД КАРТУ ПАМ'ЯТІ ДЛЯ ЯДРА ---
    ;
    ; Ядро мусить знати, які області тримає прошивка: інакше воно
    ; розкладає свої структури за фіксованими адресами наосліп. Досі
    ; карта нікуди не віддавалась, і саме це було справжньою ціною
    ; давнього дефекту зі зміщеннями, а не напис RAM SIZE UNKNOWN.
    ;
    ; Виділяємо сторінки ЗАРАЗ, до виходу зі служб: після виходу
    ; виділяти вже нічим. Адреса фіксована й лежить одразу за образом
    ; ядра, у ділянці 2..16 МБ, яку ядро ні під що не використовує.
    ;
    ; Невдача тут не фатальна: ядро вміє працювати і без карти, тому
    ; просто лишаємо BootInfoPtr нулем.
    mov     rcx, ALLOCATE_ADDRESS
    mov     rdx, EFI_LOADER_DATA
    mov     r8,  BOOTINFO_PAGES
    lea     r9,  [BootInfoAddr]
    sub     rsp, 32
    mov     rax, [BS]
    call    qword [rax + BS_ALLOCATE_PAGES]
    add     rsp, 32
    test    rax, rax
    jnz     .no_bootinfo
    mov     rax, [BootInfoAddr]
    mov     [BootInfoPtr], rax
.no_bootinfo:

    mov     qword [ExitTries], 16
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
    call    qword [rax + BS_GET_MEMORY_MAP]
    test    rax, rax
    jnz     .again

    mov     rcx, [Handle]
    mov     rdx, [MapKey]
    mov     rax, [BS]
    call    qword [rax + BS_EXIT_BOOT_SERVICES]
    test    rax, rax
    jz      .out

.again:
    mov     [FatalStatus], rax
    mov     rsp, rbp
    pop     rbp
    dec     qword [ExitTries]
    jnz     exit_uefi_loop
    mov     rax, [FatalStatus]
    lea     r8,  [MsgErrExit]
    jmp     Fatal

.out:
    mov     rsp, rbp
    pop     rbp

    ; --- КОПІЮЄМО КАРТУ ПАМ'ЯТІ В МІСЦЕ, ВІДОМЕ ЯДРУ ---
    ;
    ; Робимо це ПІСЛЯ виходу зі служб, а не до нього: копіювання не
    ; чіпає розподіл пам'яті, тож MapKey зіпсувати не може, а буфер
    ; MemoryMap нікуди не подівся - він у даних цього образу.
    ;
    ; Розкладка блока:
    ;   +0  підпис          +8  адреса карти
    ;   +16 розмір карти    +24 розмір дескриптора
    ;   +28 версія дескриптора
    cmp     qword [BootInfoPtr], 0
    je      .no_map

    mov     rdi, [BootInfoPtr]
    mov     rax, BOOTINFO_SIG
    mov     [rdi], rax
    mov     rax, [BootInfoPtr]
    add     rax, BOOTINFO_HDR
    mov     [rdi + 8], rax              ; адреса самої карти
    mov     rax, [MemoryMapSize]
    mov     [rdi + 16], rax
    mov     eax, dword [DescriptorSize]
    mov     [rdi + 24], eax
    mov     eax, [DescriptorVersion]
    mov     [rdi + 28], eax

    lea     rsi, [MemoryMap]
    mov     rdi, [BootInfoPtr]
    add     rdi, BOOTINFO_HDR
    mov     rcx, [MemoryMapSize]
    cld
    rep     movsb
.no_map:

    ; Домовленість про передачу керування ядру:
    ;   RCX = база фреймбуфера
    ;   RDX = ширина (скільки пікселів видно)
    ;   R8  = висота
    ;   R9  = крок рядка в пікселях (скільки перескочити до наступного)
    ;   R10 = блок відомостей із картою пам'яті, або 0 якщо його немає
    ;
    ; R10 доданий окремим регістром, а не замість чогось: на диску
    ; лежать образи ядра, зібрані до цієї зміни, і вони мусять
    ; лишитись працездатними.
    mov     rcx, [ScreenBase]
    mov     edx, [ScreenWidth]
    mov     r8d, [ScreenHeight]
    mov     r9d, [ScreenStride]
    mov     r10, [BootInfoPtr]
    jmp     qword [KernelBuffer]

; ==========================================================
; ЧИТАННЯ ПОТОЧНОГО РЕЖИМУ GOP
;
; Викликається на старті і повторно після кожного SetMode.
; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE: +0 MaxMode, +4 Mode,
; +8 Info, +24 FrameBufferBase.
; MODE_INFORMATION: +4 ширина, +8 висота, +12 формат пікселя,
; +32 PixelsPerScanLine.
; ==========================================================
ReadGopMode:
    push    rsi rdi r10 rax
    mov     rcx, [gop_interface]
    mov     rsi, [rcx + GOP_MODE]
    mov     rdi, [rsi + 24]
    mov     [ScreenBase], rdi

    mov     eax, [rsi + 4]              ; поточний номер режиму
    mov     [ModeCurrent], eax

    mov     r10, [rsi + 8]
    mov     eax, [r10 + 4]
    mov     [ScreenWidth], eax
    mov     eax, [r10 + 8]
    mov     [ScreenHeight], eax

    ; Крок рядка. Це НЕ те саме, що ширина: специфікація дозволяє
    ; прошивці вирівнювати рядки, і тоді крок більший. Ширина - це
    ; скільки пікселів видно, крок - скільки перескочити до
    ; наступного рядка. Захист від прошивки, яка бреше нулем.
    mov     eax, [r10 + 32]
    cmp     eax, [ScreenWidth]
    jae     .stride_ok
    mov     eax, [ScreenWidth]
.stride_ok:
    mov     [ScreenStride], eax

    ; Порядок каналів. Для PixelBitMask прошивка дає власні маски в
    ; PixelInformation (Info+16): Red, Green, Blue, Reserved по 4
    ; байти. Зсув кожного каналу рахуємо один раз тут, щоб MapColor
    ; потім не шукав молодший біт на кожному кольорі.
    mov     eax, [r10 + 12]
    mov     [ScreenFormat], eax
    cmp     eax, PIXEL_FORMAT_MASK
    jne     .no_mask

    mov     eax, [r10 + 16]
    mov     [MaskRed], eax
    bsf     ecx, eax
    jnz     .r_ok
    xor     ecx, ecx
.r_ok:
    mov     [RedShift], ecx

    mov     eax, [r10 + 20]
    mov     [MaskGreen], eax
    bsf     ecx, eax
    jnz     .g_ok
    xor     ecx, ecx
.g_ok:
    mov     [GreenShift], ecx

    mov     eax, [r10 + 24]
    mov     [MaskBlue], eax
    bsf     ecx, eax
    jnz     .b_ok
    xor     ecx, ecx
.b_ok:
    mov     [BlueShift], ecx

.no_mask:
    pop     rax r10 rdi rsi
    ret

; ==========================================================
; ПЕРЕВЕДЕННЯ КОЛЬОРУ В НАТИВНИЙ ПОРЯДОК КАНАЛІВ
;
; Весь код завантажувача задає кольори як 0x00RRGGBB - так зручно
; читати. У пам'яті ж порядок диктує прошивка. Переклад робиться
; один раз на заливку або на рядок тексту, а не на кожен піксель,
; тому на швидкість малювання це не впливає.
;
; EAX = 0x00RRGGBB на вході, нативне слово на виході.
; ==========================================================
MapColor:
    push    rbx rcx rdx
    mov     ecx, [ScreenFormat]

    cmp     ecx, PIXEL_FORMAT_BGR
    je      .done                   ; синій молодший - це вже наш вигляд
    cmp     ecx, PIXEL_FORMAT_RGB
    je      .rgb
    cmp     ecx, PIXEL_FORMAT_MASK
    je      .mask
    jmp     .done

.rgb:
    ; Червоний і синій міняються місцями, зелений лишається.
    mov     ebx, eax
    shr     ebx, 16
    and     ebx, 0xFF               ; R
    mov     edx, eax
    and     edx, 0xFF               ; B
    shl     edx, 16
    and     eax, 0x0000FF00         ; G
    or      eax, ebx
    or      eax, edx
    jmp     .done

.mask:
    mov     ebx, eax
    shr     ebx, 16
    and     ebx, 0xFF
    mov     ecx, [RedShift]
    shl     ebx, cl
    and     ebx, [MaskRed]
    mov     edx, ebx

    mov     ebx, eax
    shr     ebx, 8
    and     ebx, 0xFF
    mov     ecx, [GreenShift]
    shl     ebx, cl
    and     ebx, [MaskGreen]
    or      edx, ebx

    mov     ebx, eax
    and     ebx, 0xFF
    mov     ecx, [BlueShift]
    shl     ebx, cl
    and     ebx, [MaskBlue]
    or      edx, ebx

    mov     eax, edx
.done:
    pop     rdx rcx rbx
    ret

; Назва формату пікселя. EAX = формат, результат у R8.
FormatName:
    cmp     eax, PIXEL_FORMAT_RGB
    jne     .n1
    lea     r8, [MsgFmtRGB]
    ret
.n1:
    cmp     eax, PIXEL_FORMAT_BGR
    jne     .n2
    lea     r8, [MsgFmtBGR]
    ret
.n2:
    cmp     eax, PIXEL_FORMAT_MASK
    jne     .n3
    lea     r8, [MsgFmtMask]
    ret
.n3:
    cmp     eax, PIXEL_FORMAT_BLT
    jne     .n4
    lea     r8, [MsgFmtBlt]
    ret
.n4:
    lea     r8, [MsgFmtUnk]
    ret

; ==========================================================
; ВИМІРЮВАННЯ ЧАСУ
;
; Єдиний годинник, доступний і до, і після ExitBootServices - це
; лічильник тактів процесора. Сам по собі він безрозмірний, тому
; калібруємо його один раз об Stall() з Boot Services: просимо
; прошивку зачекати 100 мс і дивимось, скільки тактів минуло.
;
; ВАЖЛИВО про інтерпретацію: під TCG усе це - числа емулятора, а
; не заліза. Вони чесно порівнюються МІЖ СОБОЮ (що дорожче за що),
; але як абсолютні величини для реальної машини не годяться.
; ==========================================================
ReadTSC:
    rdtsc                       ; EDX:EAX, запис в EAX обнуляє старші RAX
    shl     rdx, 32
    or      rax, rdx
    ret

CalibrateTSC:
    push    rbx rcx rdx
    call    ReadTSC
    mov     rbx, rax

    mov     rcx, 100000         ; мікросекунд = 100 мс
    sub     rsp, 32
    mov     rax, [BS]
    call    qword [rax + BS_STALL]
    add     rsp, 32

    call    ReadTSC
    sub     rax, rbx
    xor     rdx, rdx
    mov     rcx, 100000
    div     rcx                 ; тактів на мікросекунду
    test    rax, rax
    jnz     .ok
    mov     rax, 1              ; захист від ділення на нуль далі
.ok:
    mov     [TscPerUs], rax
    pop     rdx rcx rbx
    ret

; RAX = різниця тактів -> RAX = мікросекунди
TicksToUs:
    push    rdx rcx
    xor     rdx, rdx
    mov     rcx, [TscPerUs]
    div     rcx
    pop     rcx rdx
    ret

; Малює рядок "ПІДПИС : NNNN US".
;   RCX = y, RDX = підпис, RAX = мікросекунди
DrawUs:
    push    rbx r10 r11 rdi
    mov     r11, rcx
    mov     r10, rdx
    mov     rbx, rax

    mov     rcx, 40
    mov     rdx, r11
    mov     r8,  r10
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color

    lea     rdi, [BenchStr]
    mov     rax, rbx
    call    UInt64ToDecString
    mov     byte [rdi], ' '
    mov     byte [rdi+1], 'U'
    mov     byte [rdi+2], 'S'
    mov     byte [rdi+3], 0

    mov     rcx, 420
    mov     rdx, r11
    lea     r8,  [BenchStr]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color
    pop     rdi r11 r10 rbx
    ret

; Заливка всього екрана через GOP Blt(), операція EfiBltVideoFill.
; У Blt десять аргументів: чотири в регістрах, шість на стеку.
BltFillScreen:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 96
    and     rsp, -16

    mov     rcx, [gop_interface]
    lea     rdx, [BltPixel]
    mov     r8,  BLT_VIDEO_FILL
    xor     r9,  r9                     ; SourceX
    mov     qword [rsp+32], 0           ; SourceY
    mov     qword [rsp+40], 0           ; DestinationX
    mov     qword [rsp+48], 0           ; DestinationY
    xor     rax, rax
    mov     eax, [ScreenWidth]
    mov     [rsp+56], rax               ; Width
    xor     rax, rax
    mov     eax, [ScreenHeight]
    mov     [rsp+64], rax               ; Height
    mov     qword [rsp+72], 0           ; Delta
    mov     rax, [gop_interface]
    mov     rax, [rax + GOP_BLT]
    call    rax

    mov     rsp, rbp
    pop     rbp
    ret

; Міряє повний шлях читання ядра з диска: Open + GetInfo + Read +
; Close, кілька проходів. Саме повний шлях, а не лише Read - бо на
; старті нас цікавить не пропускна здатність, а скільки коштує
; дістати файл узагалі.
BenchKernelRead:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64
    and     rsp, -16
    push    rbx r14 r15

    mov     qword [BenchRead], 0
    mov     qword [BenchBytes], 0

    ; Буфер виділяємо один раз і надалі перевикористовуємо.
    cmp     qword [BenchBufPtr], 0
    jne     .have_buf
    mov     qword [BenchPages], BENCH_BUF_SIZE / 4096
    mov     rcx, 0                      ; AllocateAnyPages
    mov     rdx, EFI_LOADER_DATA
    mov     r8,  [BenchPages]
    lea     r9,  [BenchBufPtr]
    sub     rsp, 32
    mov     rax, [BS]
    call    qword [rax + BS_ALLOCATE_PAGES]
    add     rsp, 32
    test    rax, rax
    jz      .have_buf
    mov     qword [BenchBufPtr], 0
    jmp     .out
.have_buf:

    mov     rcx, [Handle]
    lea     rdx, [EFI_LOADED_IMAGE_PROTOCOL_GUID]
    lea     r8,  [LoadedImage]
    mov     rax, [BS]
    call    qword [rax + BS_HANDLE_PROTOCOL]
    test    rax, rax
    jnz     .out

    mov     rax, [LoadedImage]
    mov     rcx, [rax + 0x18]
    lea     rdx, [EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID]
    lea     r8,  [FileSystem]
    mov     rax, [BS]
    call    qword [rax + BS_HANDLE_PROTOCOL]
    test    rax, rax
    jnz     .out

    mov     rcx, [FileSystem]
    lea     rdx, [RootFolder]
    mov     rax, [rcx + FILE_OPEN]
    call    rax
    test    rax, rax
    jnz     .out

    call    ReadTSC
    mov     r14, rax
    mov     r15d, BENCH_IO_PASSES
.pass:
    mov     rcx, [RootFolder]
    lea     rdx, [FileHandle]
    lea     r8,  [KernelPath]
    mov     r9,  1
    sub     rsp, 32
    mov     qword [rsp + 32], 0
    mov     rax, [rcx + FILE_OPEN]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .out2

    mov     qword [InfoSize], 512
    mov     rcx, [FileHandle]
    lea     rdx, [EFI_FILE_INFO_GUID]
    lea     r8,  [InfoSize]
    lea     r9,  [FileInfo]
    sub     rsp, 32
    mov     rax, [rcx + FILE_GET_INFO]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .out2

    mov     rax, qword [FileInfo + 8]
    cmp     rax, BENCH_BUF_SIZE
    jbe     .fits
    mov     rax, BENCH_BUF_SIZE
.fits:
    mov     [BenchBytes], rax
    mov     [BenchSize], rax

    mov     rcx, [FileHandle]
    lea     rdx, [BenchSize]
    mov     r8,  [BenchBufPtr]
    sub     rsp, 32
    mov     rax, [rcx + FILE_READ]
    call    rax
    add     rsp, 32

    mov     rcx, [FileHandle]
    mov     rax, [rcx + FILE_CLOSE]
    call    rax

    dec     r15d
    jnz     .pass

    call    ReadTSC
    sub     rax, r14
    xor     rdx, rdx
    mov     rcx, BENCH_IO_PASSES
    div     rcx
    call    TicksToUs
    mov     [BenchRead], rax
.out2:
.out:
    pop     r15 r14 rbx
    mov     rsp, rbp
    pop     rbp
    ret

; ==========================================================
; ЕКРАН РЕЗУЛЬТАТІВ
; ==========================================================
DrawBenchScreen:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32

    mov     ecx, 0x000000AA
    call    FillScreen

    mov     rcx, 40
    mov     rdx, 40
    lea     r8,  [MsgBenchTitle]
    mov     r9d, 0x00FFFFFF
    call    DrawString_Color
    mov     rcx, 40
    mov     rdx, 60
    lea     r8,  [MsgLine]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color

    ; Калібрування - показуємо, щоб було видно, наскільки числам вірити
    mov     rcx, 40
    mov     rdx, 90
    lea     r8,  [MsgTsc]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    lea     rdi, [BenchStr]
    mov     rax, [TscPerUs]
    call    UInt64ToDecString
    mov     rcx, 420
    mov     rdx, 90
    lea     r8,  [BenchStr]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color

    ; --- ЕТАПИ СТАРТУ ---
    mov     rcx, 40
    mov     rdx, 130
    lea     r8,  [MsgBenchBoot]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color

    mov     rax, [StageT1]
    sub     rax, [StageT0]
    call    TicksToUs
    mov     rcx, 160
    lea     rdx, [MsgStGop]
    call    DrawUs

    mov     rax, [StageT2]
    sub     rax, [StageT1]
    call    TicksToUs
    mov     rcx, 180
    lea     rdx, [MsgStEnum]
    call    DrawUs

    mov     rax, [StageT3]
    sub     rax, [StageT2]
    call    TicksToUs
    mov     rcx, 200
    lea     rdx, [MsgStHw]
    call    DrawUs

    mov     rax, [StageT4]
    sub     rax, [StageT3]
    call    TicksToUs
    mov     rcx, 220
    lea     rdx, [MsgStDraw]
    call    DrawUs

    mov     rax, [StageT4]
    sub     rax, [StageT0]
    call    TicksToUs
    mov     rcx, 250
    lea     rdx, [MsgStTotal]
    call    DrawUs

    ; --- ЗАЛИВКА ЕКРАНА ---
    mov     rcx, 40
    mov     rdx, 290
    lea     r8,  [MsgBenchFill]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color

    mov     rax, [BenchDirect]
    mov     rcx, 320
    lea     rdx, [MsgFillDirect]
    call    DrawUs

    mov     rax, [BenchBlt]
    mov     rcx, 340
    lea     rdx, [MsgFillBlt]
    call    DrawUs

    ; --- ЧИТАННЯ З ДИСКА ---
    mov     rcx, 40
    mov     rdx, 380
    lea     r8,  [MsgBenchIo]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color

    mov     rax, [BenchRead]
    mov     rcx, 410
    lea     rdx, [MsgIoKernel]
    call    DrawUs

    mov     rcx, 40
    mov     rdx, 460
    lea     r8,  [MsgBenchNote]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 40
    mov     rdx, 480
    lea     r8,  [MsgBenchBack]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color

    mov     rsp, rbp
    pop     rbp
    ret

; Дописує нуль-термінований рядок з R8 у RDI.
; RDI лишається на новому нулі - як після UInt64ToDecString.
AppendStr:
    push    rax r8
.l: mov     al, [r8]
    test    al, al
    jz      .d
    mov     [rdi], al
    inc     rdi
    inc     r8
    jmp     .l
.d: mov     byte [rdi], 0
    pop     r8 rax
    ret

; Шукає в переліку перший режим із лінійним фреймбуфером.
; Повертає номер у EAX або -1, якщо таких немає взагалі.
FindLinearMode:
    push    rbx rcx
    xor     ecx, ecx
.l: cmp     ecx, [ModeCount]
    jae     .none
    mov     eax, ecx
    shl     eax, 4
    lea     rbx, [ModeTable]
    add     rbx, rax
    cmp     dword [rbx + 12], PIXEL_FORMAT_BLT
    je      .next
    cmp     dword [rbx], 0          ; нульова ширина - режим порожній
    je      .next
    mov     eax, ecx
    pop     rcx rbx
    ret
.next:
    inc     ecx
    jmp     .l
.none:
    mov     eax, -1
    pop     rcx rbx
    ret

; ==========================================================
; ПЕРЕЛІК РЕЖИМІВ ЧЕРЕЗ QueryMode
;
; QueryMode сам виділяє буфер під MODE_INFORMATION і віддає його
; нам у власність, тому кожен треба звільнити через FreePool.
; Зберігаємо по 16 байтів на режим: ширина, висота, крок, формат.
; ==========================================================
EnumModes:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64
    and     rsp, -16
    push    rbx r12

    mov     rax, [gop_interface]
    mov     rax, [rax + GOP_MODE]
    mov     eax, [rax]                  ; MaxMode
    cmp     eax, MAX_MODES
    jbe     .cap
    mov     eax, MAX_MODES
.cap:
    mov     [ModeCount], eax

    xor     r12d, r12d
.next:
    cmp     r12d, [ModeCount]
    jae     .done

    mov     qword [QueryInfo], 0
    mov     rcx, [gop_interface]
    mov     edx, r12d
    lea     r8,  [QuerySize]
    lea     r9,  [QueryInfo]
    sub     rsp, 32
    mov     rax, [gop_interface]
    mov     rax, [rax + GOP_QUERY_MODE]
    call    rax
    add     rsp, 32
    test    rax, rax
    jnz     .skip

    mov     rsi, [QueryInfo]
    test    rsi, rsi
    jz      .skip

    mov     eax, r12d
    shl     eax, 4                      ; 16 байтів на запис
    lea     rbx, [ModeTable]
    add     rbx, rax
    mov     eax, [rsi + 4]
    mov     [rbx], eax                  ; ширина
    mov     eax, [rsi + 8]
    mov     [rbx + 4], eax              ; висота
    mov     eax, [rsi + 32]
    mov     [rbx + 8], eax              ; крок рядка
    mov     eax, [rsi + 12]
    mov     [rbx + 12], eax             ; формат пікселя

    mov     rcx, [QueryInfo]
    sub     rsp, 32
    mov     rax, [BS]
    call    qword [rax + BS_FREE_POOL]
    add     rsp, 32

.skip:
    inc     r12d
    jmp     .next
.done:
    pop     r12 rbx
    mov     rsp, rbp
    pop     rbp
    ret

; ==========================================================
; ЕКРАН СПИСКУ РЕЖИМІВ
; ==========================================================
DrawVideoScreen:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32
    push    rbx r12

    mov     ecx, 0x000000AA
    call    FillScreen

    mov     rcx, 40
    mov     rdx, 40
    lea     r8,  [MsgVidTitle]
    mov     r9d, 0x00FFFFFF
    call    DrawString_Color
    mov     rcx, 40
    mov     rdx, 60
    lea     r8,  [MsgLine]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 90
    lea     r8,  [MsgVidHelp]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color

    ; Якщо попередній SetMode провалився - сказати про це вголос.
    cmp     qword [ModeFailed], 0
    je      .chk_linear
    mov     rcx, 40
    mov     rdx, 110
    lea     r8,  [MsgVidFail]
    mov     r9d, 0x00FF0000
    call    DrawString_Color
    jmp     .list

.chk_linear:
    cmp     qword [ModeNoLinear], 0
    je      .list
    mov     rcx, 40
    mov     rdx, 110
    lea     r8,  [MsgVidNoLin]
    mov     r9d, 0x00FF0000
    call    DrawString_Color

.list:
    xor     r12d, r12d
.row:
    cmp     r12d, [ModeCount]
    jae     .done

    mov     eax, r12d
    call    BuildModeStr

    ; Поточний режим позначаємо, вибраний - підсвічуємо.
    mov     r9d, 0x00AAAAAA
    cmp     r12d, [ModeCurrent]
    jne     .not_cur
    mov     r9d, 0x00FFFFFF
.not_cur:
    cmp     r12d, [ModeSel]
    jne     .draw
    mov     r9d, 0x0000FF00
.draw:
    mov     eax, r12d
    imul    eax, 20
    add     eax, 150
    mov     rdx, rax
    mov     rcx, 40
    lea     r8,  [ModeStr]
    call    DrawString_Color

    inc     r12d
    jmp     .row
.done:
    pop     r12 rbx
    mov     rsp, rbp
    pop     rbp
    ret

; Складає рядок опису режиму у ModeStr. EAX = номер режиму.
; Вигляд: "[ 3 ] 1280X800  STRIDE 1280  FMT 1  <-- ACTIVE"
BuildModeStr:
    push    rbx rax rdi rsi
    mov     ebx, eax
    lea     rdi, [ModeStr]

    mov     byte [rdi], '['
    mov     byte [rdi+1], ' '
    add     rdi, 2
    mov     eax, ebx
    call    UInt64ToDecString
    mov     byte [rdi], ' '
    mov     byte [rdi+1], ']'
    mov     byte [rdi+2], ' '
    add     rdi, 3

    mov     eax, ebx
    shl     eax, 4
    lea     rsi, [ModeTable]
    add     rsi, rax

    xor     rax, rax
    mov     eax, [rsi]
    call    UInt64ToDecString
    mov     byte [rdi], 'X'
    inc     rdi
    xor     rax, rax
    mov     eax, [rsi + 4]
    call    UInt64ToDecString

    mov     dword [rdi], 0x54532020     ; "  ST"
    mov     dword [rdi+4], 0x45444952   ; "RIDE"
    mov     byte  [rdi+8], ' '
    add     rdi, 9
    xor     rax, rax
    mov     eax, [rsi + 8]
    call    UInt64ToDecString

    mov     byte [rdi], ' '
    mov     byte [rdi+1], ' '
    add     rdi, 2
    mov     eax, [rsi + 12]
    call    FormatName
    call    AppendStr

    cmp     ebx, [ModeCurrent]
    jne     .done
    mov     dword [rdi], 0x2D3C2020     ; "  <-"
    mov     dword [rdi+4], 0x4341202D   ; "- AC"
    mov     dword [rdi+8], 0x45564954   ; "TIVE"
    mov     byte  [rdi+12], 0
.done:
    pop     rsi rdi rax rbx
    ret

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

    mov     rcx, 40
    mov     rdx, 460
    lea     r8,  [MsgOpt3]
    mov     r9d, 0x00555555
    cmp     byte [MenuIndex], 3
    jne     .d3
    mov     r9d, 0x0000FF00
.d3: call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 490
    lea     r8,  [MsgOpt4]
    mov     r9d, 0x00555555
    cmp     byte [MenuIndex], 4
    jne     .d4
    mov     r9d, 0x0000FF00
.d4: call    DrawString_Color
    pop     r9 r8 rdx rcx rax
    ret

; ==========================================================
; ОБРОБНИКИ ПОМИЛОК
; ==========================================================
; Найперша можлива поразка: GOP не піднявся. Фреймбуфера ще немає,
; малювати нічим, тому єдине, що лишається - текстова консоль
; прошивки. Раніше тут стояло голе "jmp $": чорний екран і мовчання.
error_video:
    mov     rcx, [SystemTable]
    mov     rcx, [rcx + 64]             ; ConOut
    lea     rdx, [MsgNoGopW]
    mov     rax, [rcx + CONOUT_OUTPUT_STRING]
    call    rax
.hang:
    cli
    hlt
    jmp     .hang

; Прошивка не дала жодного режиму з лінійним фреймбуфером - тільки
; Blt(). Малювати нам нічим, тому знову лишається ConOut.
error_blt:
    mov     rcx, [SystemTable]
    mov     rcx, [rcx + 64]             ; ConOut
    lea     rdx, [MsgNoLinearW]
    mov     rax, [rcx + CONOUT_OUTPUT_STRING]
    call    rax
.hang:
    cli
    hlt
    jmp     .hang

; Фатальна помилка після того, як екран уже наш.
;   R8  = повідомлення (тільки великі літери - у шрифті лише 32..93)
;   RAX = код стану EFI
Fatal:
    mov     [FatalStatus], rax
    mov     [FatalMsg], r8

    mov     ecx, 0x00000000
    call    FillScreen

    mov     rcx, 40
    mov     rdx, 60
    lea     r8,  [MsgFatal]
    mov     r9d, 0x00FF0000
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 100
    mov     r8,  [FatalMsg]
    mov     r9d, 0x00FFFFFF
    call    DrawString_Color

    ; Коди помилок EFI мають зведений старший біт, а змістовна
    ; частина сидить у молодших. Показуємо саме її: 2 - невірний
    ; параметр, 5 - замалий буфер, 14 - не знайдено.
    lea     rdi, [FatalStr]
    mov     rax, [FatalStatus]
    and     rax, 0xFFFF
    call    UInt64ToDecString

    mov     rcx, 40
    mov     rdx, 140
    lea     r8,  [MsgStatus]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
    mov     rcx, 190
    mov     rdx, 140
    lea     r8,  [FatalStr]
    mov     r9d, 0x00FFFF00
    call    DrawString_Color

    mov     rcx, 40
    mov     rdx, 190
    lea     r8,  [MsgHalted]
    mov     r9d, 0x00AAAAAA
    call    DrawString_Color
.hang:
    cli
    hlt
    jmp     .hang

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
    call    qword [rax + BS_GET_MEMORY_MAP]
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

; Складає рядок "1280x800  STRIDE 1280" у VideoStr.
; RAX = число, RDI = куди - домовленість UInt64ToDecString;
; після виклику RDI показує на нуль-термінатор, тому дописувати
; наступний шматок можна одразу.
BuildVideoStr:
    push    rax rdi
    lea     rdi, [VideoStr]

    xor     rax, rax
    mov     eax, [ScreenWidth]
    call    UInt64ToDecString
    ; У шрифті завантажувача лише великі літери — мала 'x'
    ; виходить за межі таблиці гліфів і малюється порожнечею.
    mov     byte [rdi], 'X'
    inc     rdi

    xor     rax, rax
    mov     eax, [ScreenHeight]
    call    UInt64ToDecString

    mov     dword [rdi], 0x54532020     ; "  ST"
    mov     dword [rdi+4], 0x45444952   ; "RIDE"
    mov     byte  [rdi+8], ' '
    add     rdi, 9

    xor     rax, rax
    mov     eax, [ScreenStride]
    call    UInt64ToDecString

    ; Порядок каналів - теж частина опису режиму, а не дрібниця:
    ; саме він вирішує, чи буде червоне червоним.
    mov     byte [rdi], ' '
    mov     byte [rdi+1], ' '
    add     rdi, 2
    mov     eax, [ScreenFormat]
    call    FormatName
    call    AppendStr

    pop     rdi rax
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
    call    MapColor            ; 0x00RRGGBB -> порядок каналів прошивки
    mov     rdi, [ScreenBase]
    
    ; Заливаємо ПО КРОКУ РЯДКА, а не по ширині: інакше при кроці
    ; більшому за ширину заливка поїде по діагоналі й не дійде до
    ; низу екрана. Зайві пікселі вирівнювання зафарбувати не шкода —
    ; вони однаково лежать у межах буфера.
    movsxd  rcx, dword [ScreenStride]
    movsxd  rdx, dword [ScreenHeight]
    imul    rcx, rdx
    
    cld                         ; ОБОВ'ЯЗКОВО! Гарантує запис вперед
    rep     stosd
    
    pop     rdx rcx rax rdi
    ret

DrawString_Color:
    push rbx rax rsi r9
    ; Один переклад на весь рядок. DrawChar кличеться тільки звідси,
    ; тому далі по ланцюжку колір уже нативний.
    mov     eax, r9d
    call    MapColor
    mov     r9d, eax
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
    ; І адреса пікселя, і перехід на наступний рядок рахуються
    ; за КРОКОМ, а не за шириною.
    mov eax, [ScreenStride]
    imul rax, rdx
    add rax, rcx
    shl rax, 2
    add rax, [ScreenBase]
    mov rdi, rax
    mov ebx, [ScreenStride]
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
ScreenWidth     dd 0      ; скільки пікселів видно в рядку
ScreenHeight    dd 0
ScreenStride    dd 0      ; PixelsPerScanLine; може бути БІЛЬШИМ за ширину
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
MsgVideo        db 'VIDEO GOP :', 0
VideoStr        db 'DETECTING...', 0
                times 32 db 0

; --- ДІАГНОСТИКА ПОРАЗОК ---
; У шрифті лише коди 32..93, тому всі ці рядки - тільки великими.
MsgFatal        db '*** BOOT FAILURE ***', 0
MsgStatus       db 'EFI STATUS:', 0
MsgHalted       db 'SYSTEM HALTED. POWER OFF AND RESTART.', 0
MsgErrImg       db 'CANNOT GET LOADED IMAGE PROTOCOL', 0
MsgErrFs        db 'CANNOT OPEN BOOT FILESYSTEM', 0
MsgErrOpen      db 'KERNEL.BIN NOT FOUND ON BOOT VOLUME', 0
MsgErrInfo      db 'CANNOT READ SIZE OF KERNEL.BIN', 0
MsgErrMem       db 'CANNOT RESERVE MEMORY AT 100000', 0
MsgErrRead      db 'KERNEL.BIN READ FAILED OR TRUNCATED', 0
MsgErrExit      db 'EXITBOOTSERVICES FAILED 16 TIMES', 0
FatalStr        db '0', 0
                times 24 db 0
FatalStatus     dq 0
FatalMsg        dq 0
ExitTries       dq 0

; Єдине повідомлення, яке доводиться складати в UTF-16: якщо GOP не
; піднявся, то намалювати його нема чим і лишається лише ConOut.
MsgNoGopW       dw 'G','O','P',' ','I','N','I','T',' ','F','A','I','L','E','D'
                dw 13, 10, 0
MsgNoLinearW    dw 'N','O',' ','L','I','N','E','A','R',' ','F','R','A','M'
                dw 'E','B','U','F','F','E','R',' ','M','O','D','E'
                dw 13, 10, 0

CPUBrandString  db 'DETECTING CPU...', 0 
                times 48 db 0
RamStr          db 'UNKNOWN   ', 0, 0, 0, 0, 0, 0, 0, 0, 0
DiskStr         db 'DETECTING...', 0, 0, 0, 0, 0, 0, 0, 0, 0
MsgFWData       db 'UEFI 64-BIT NATIVE', 0

MsgBootMenu     db '--- BOOT OPTIONS --- (Use ARROWS and ENTER)', 0
MsgOpt0         db '[ 1 ] BOOT EUGENE OS CORE', 0
MsgOpt1         db '[ 2 ] SELECT VIDEO MODE', 0
MsgOpt2         db '[ 3 ] RUN BENCHMARKS', 0
MsgOpt3         db '[ 4 ] REBOOT SYSTEM', 0
MsgOpt4         db '[ 5 ] SHUTDOWN VM', 0

; --- ЕКРАН ВИМІРЮВАНЬ ---
MsgBenchTitle   db 'EUGENE OS - BOOT MEASUREMENTS', 0
MsgTsc          db 'TSC TICKS PER MICROSECOND :', 0
MsgBenchBoot    db '--- STARTUP STAGES ---', 0
MsgStGop        db 'LOCATE GOP + READ MODE :', 0
MsgStEnum       db 'ENUMERATE VIDEO MODES  :', 0
MsgStHw         db 'CPU / RAM / DISK INFO  :', 0
MsgStDraw       db 'DRAW SETUP SCREEN      :', 0
MsgStTotal      db 'TOTAL TO FIRST SCREEN  :', 0
MsgBenchFill    db '--- FULL SCREEN FILL, AVERAGE OF 10 ---', 0
MsgFillDirect   db 'DIRECT FRAMEBUFFER     :', 0
MsgFillBlt      db 'GOP BLT VIDEOFILL      :', 0
MsgBenchIo      db '--- KERNEL LOAD, AVERAGE OF 3 ---', 0
MsgIoKernel     db 'OPEN + GETINFO + READ  :', 0
MsgBenchNote    db 'NUMBERS ARE FROM THE EMULATOR, NOT REAL HARDWARE.', 0
MsgBenchBack    db 'PRESS ESC OR ENTER TO RETURN.', 0
BenchStr        db '0', 0
                times 32 db 0
TscPerUs        dq 1
StageT0         dq 0
StageT1         dq 0
StageT2         dq 0
StageT3         dq 0
StageT4         dq 0
BenchDirect     dq 0
BenchBlt        dq 0
BenchRead       dq 0
BenchBytes      dq 0
BenchSize       dq 0
BltPixel        db 0x20, 0x00, 0x00, 0x00   ; B, G, R, Reserved
; Буфер під вимір читання з диска. Статичним його робити не можна:
; FASM матеріалізує rb у файлі образу, і 256 КБ нулів поїхали б на
; диск разом із завантажувачем. Тому виділяємо через AllocatePages.
BenchBufPtr     dq 0
BenchPages      dq 0

; --- ЕКРАН ВИБОРУ ВІДЕОРЕЖИМУ ---
MsgVidTitle     db 'EUGENE OS - GOP VIDEO MODES', 0
MsgVidHelp      db 'ARROWS SELECT, ENTER APPLY, ESC BACK', 0
MsgVidFail      db 'FIRMWARE REFUSED SETMODE - MODE UNCHANGED', 0
MsgVidNoLin     db 'BLT-ONLY MODE HAS NO LINEAR FRAMEBUFFER', 0
ModeNoLinear    dq 0

; --- ФОРМАТ ПІКСЕЛЯ ---
MsgFmtRGB       db 'RGB', 0
MsgFmtBGR       db 'BGR', 0
MsgFmtMask      db 'MASK', 0
MsgFmtBlt       db 'BLT', 0
MsgFmtUnk       db 'UNK', 0
MaskRed         dd 0
MaskGreen       dd 0
MaskBlue        dd 0
RedShift        dd 0
GreenShift      dd 0
BlueShift       dd 0
ModeStr         db '?', 0
                times 64 db 0
ModeCount       dd 0
ModeSel         dd 0
ModeCurrent     dd 0
ModeFailed      dq 0
QuerySize       dq 0
QueryInfo       dq 0
ScreenFormat    dd 0
                dd 0
ModeTable       rb MAX_MODES * 16


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
; Адреса, на яку злінковане ядро. Для AllocatePages з типом
; AllocateAddress це водночас і вхідний параметр, і місце, куди
; прошивка запише підтверджену адресу.
KernelBuffer dq 0x100000
; Для Read це параметр "туди й назад": на вході - скільки можна,
; на виході - скільки насправді прочитано. Тому справжній розмір
; тримаємо окремо в KernelWanted, щоб було з чим порівняти.
KernelSize   dq 0
KernelWanted dq 0
KernelPages  dq 0
InfoSize     dq 0
FileInfo     rb 512
EFI_FILE_INFO_GUID: db 0x92, 0x6E, 0x57, 0x09, 0x3F, 0x6D, 0xD2, 0x11, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
KernelPath dw 'k','e','r','n','e','l','.','b','i','n', 0
MemoryMapSize dq 65536
MapKey dq 0
DescriptorSize dq 0
DescriptorVersion dd 0
MemoryMap rb 65536

; Для AllocatePages з типом AllocateAddress це водночас і вхідний
; параметр, і місце, куди прошивка запише підтверджену адресу.
BootInfoAddr dq BOOTINFO_BASE
BootInfoPtr  dq 0

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