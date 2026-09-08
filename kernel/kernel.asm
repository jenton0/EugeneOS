format binary as 'bin'      
use64                       
org 0x100000                

; ==========================================================
; КАРТА ПАМ'ЯТІ ЯДРА
; ==========================================================
VideoMemoryBase equ 0x1000000  ; 16 МБ: Буфер для завантаження файлів з диска
DirBuffer       equ 0x2000000  ; 32 МБ: Буфер для читання папок (VFS)
BackBufferBase  equ 0x3000000  ; 48 МБ: Буфер для рендеру відео/кадрів
; Рядок кадру, уже розтягнутий по горизонталі. Лежить одразу за
; заднім буфером: 320*240*4 = 300 КБ, далі до 64 МБ нічого немає.
; Задній буфер росте від 48 МБ, тому буфер рядка кладемо вище за
; будь-який можливий кадр - на 61 МБ, за мегабайт до сторінки-вартового
; під стеком програм. Між ними лишається 13 МБ під кадр.
LineBufBase     equ 0x3D00000
VIDBUF_MAX      equ 0xD00000

; Відео, відкрите для показу у вікні, лежить ОКРЕМО від
; VideoMemoryBase. Той буфер спільний: у нього читає файл усе -
; від bmp_load до запуску програми. Програвачу консолі це байдуже,
; бо поки він грає, більше нічого не відбувається. У вікні ж
; достатньо відкрити картинку - і потік відео перетворився б на
; сміття просто посеред показу.
; 0xC000000..0x10000000 - єдина вільна ділянка: нижче буфери
; дескрипторів, вище купа програм.
VidFileBase     equ 0xC000000  ; 192 МБ
VIDFILE_MAX     equ 0x4000000  ; 64 МБ - до купи програм

; Полотно теж мусить лежати ПОЗА приватизованими діапазонами.
; PagingCloneSpace робить власними стек, образ програми та всю купу
; (0x10000000+), тому буфер, узятий там через malloc, у батька й
; дитини - це РІЗНІ фізичні сторінки за однією адресою: дитина
; малює у свою копію, а батько показує свою, ніким не писану.
; 0x7500000 лежить між буфером редактора й буферами дескрипторів,
; тобто у спільній частині простору.
CanvasBase      equ 0x7500000  ; 117 МБ
; 8 МБ: полотно роблять розміром з екран, щоб програма малювала
; точно так само, як малювала б на весь екран. 1280x1024x4 - це
; 5 МБ, тож із запасом. Вище - буфери дескрипторів на 0x8000000.
CANVAS_MAX      equ 0x800000

; Текст, надрукований задачею у вікні. Лежить поруч із полотном і з
; тієї ж причини: у спільній частині простору, бо пише його дитина,
; а показує батько. Досі такий текст просто зникав - малювати його
; на екран означало б лягти поверх усієї оболонки.
AppTextBase     equ 0x7D00000  ; 125 МБ
APPTEXT_MAX     equ 0x8000     ; 32 КБ

; Буфер прийому TCP. Тримати його всередині образу ядра як rb не
; можна: fasm заповнив би ті чверть мегабайта нулями просто у файлі.
; Тому окрема ділянка - між текстом задачі та буферами дескрипторів.
TcpRxBase       equ 0x7D10000  ; 125 МБ + 64 КБ
TCP_RXCAP       equ 0x40000    ; 256 КБ

; Поле вікна в TCP шістнадцятибітне, тому оголосити більше за це не
; можна, хоч би скільки ми вміщали. Буфер більший саме тому: вікно
; закривається не тоді, коли буфер повний, а коли повний на 64 КБ.
TCP_WINMAX      equ 65535

; Скільки чекати підтвердження і скільки разів перепитувати.
; Час, а не оберти циклу: скільки обертів устигне зробити
; NetPollBackground, залежить від того, чим зайнята машина, а
; півсекунди лишаються півсекундою.
TCP_RTO         equ 500        ; мілісекунд; таймер у нас на 1000 Гц
TCP_RETRIES     equ 5

; --- TCP ---
TCP_FIN         equ 0x01
TCP_SYN         equ 0x02
TCP_RST         equ 0x04
TCP_PSH         equ 0x08
TCP_ACK         equ 0x10

TCPS_CLOSED     equ 0
TCPS_SYNSENT    equ 1
TCPS_ESTAB      equ 2
TCPS_DONE       equ 3


; --- РЕДАКТОР ---
; Буфер більше не статичний масив у тілі ядра, а окрема ділянка
; пам'яті: 32 КБ не вміщали навіть kernel.asm (285 КБ), і файл
; мовчки обрізався при відкритті, а збереження знищувало решту.
; Місце вибране між мережевими буферами (закінчуються на 0x7006000)
; і буферами файлових дескрипторів (починаються на 0x8000000).
EditorBuffer    equ 0x7100000  ; 113 МБ
EDITOR_CAP      equ 0x400000   ; 4 МБ - із запасом на порядок
AppMemoryBase   equ 0x4000000  ; 64 МБ: Адреса, куди вантажаться .APP/.BIN програми

; --- БЛОК ВІДОМОСТЕЙ ВІД ЗАВАНТАЖУВАЧА ---
; Лежить на 0x200000, вказівник приходить у R10. Підпис потрібен,
; щоб відрізнити справжній блок від сміття в регістрі: старі
; завантажувачі R10 не заповнювали. Значення дублюється в
; boot/main.asm - при зміні правити в обох місцях.
BOOTINFO_SIG    equ 0x31544F4F42475545   ; 'EUGBOOT1'

; --- АВАРІЙНИЙ ВИХІД ІЗ ПРОГРАМИ ---
;
; Комбінація винесена сюди, бо вона залежить не від нас, а від того,
; що діється НАД віртуальною машиною. Ctrl+Alt+Del забирає собі
; Windows і до гостя він не доходить; частину Ctrl+Alt+щось забирає
; QEMU (Ctrl+Alt+G відпускає мишу, Ctrl+Alt+цифра перемикає консолі).
;
; Тому Ctrl+Shift+Q: жоден із шарів над нами його не чіпає, три
; клавіші випадково не натиснеш, а в DOOM клавіша Q ні до чого не
; прив'язана.
;
; Міняти тут, в одному місці.
; --- ВІКНО ПРОГРАМИ В АДРЕСНОМУ ПРОСТОРІ ---
; Від сторінки одразу НАД вартовим до купи ядра. Вартовий лишається
; поза межею й тому далі ловить переповнення стека - у цьому весь
; сенс того, що межа починається не з 0x3E00000.
AppSpaceLow     equ 0x3E01000   ; над сторінкою-вартовим
AppSpaceHigh    equ 0x5000000   ; далі купа ядра

KILL_KEY        equ 0x10        ; скан-код Q
KILL_MODS       equ 3           ; Shift(1) | Ctrl(2)

; --- ВЛАСНИЙ ФОРМАТ ФАЙЛІВ EUGN ---
;
; Ім'я файлу не є його типом: розширення можна перейменувати, а
; вміст - ні. Тому власні формати починаються з підпису, і саме він
; вирішує, що з файлом робити. Розширення лишається другим кроком,
; для чужих форматів на кшталт BMP чи TXT.
;
; Заголовок, 16 байтів:
;   +0  'EUGN'   підпис
;   +4  тип      1=відео 2=зображення 3=звук 4=системний
;   +5  версія
;   +6  ширина   2 байти
;   +8  висота   2 байти
;   +10 прапорці 2 байти
;   +12 розмір даних після заголовка, 4 байти
EUG_MAGIC   equ 0x4E475545  ; 'EUGN' у порядку байтів пам'яті
EUG_HDR     equ 16
EUG_VIDEO   equ 1
EUG_IMAGE   equ 2
EUG_SOUND   equ 3
EUG_SYSTEM  equ 4

; --- Єдиний перелік типів для системного виклику 36 ---
; Об'єднує те, що відоме з підпису, і те, що вгадане за іменем:
; програмі байдуже, звідки система це знає, їй потрібен тип.
; Значення дублюються в libc/include/stdlib.h.
FT_UNKNOWN  equ 0
FT_PROGRAM  equ 1
FT_TEXT     equ 2
FT_BITMAP   equ 3
FT_SOUND    equ 4
FT_VIDEO    equ 5
FT_IMAGE    equ 6
FT_SYSTEM   equ 7
FT_DIR      equ 8

; --- РОЗПОДІЛЬНИК ФІЗИЧНИХ КАДРІВ ---
;
; Роздає сторінки по 4 КБ. Перший споживач - власні сторінкові
; таблиці: щоб забрати пейджинг у прошивки, треба спершу мати куди
; покласти PML4.
;
; Обслуговує НЕ всю пам'ять, а лише те, що вище за фіксовану карту
; ядра. Причина проста: нижче 384 МБ кожна адреса вже комусь
; належить - образ ядра, буфери завантаження, купи, мережа, буфери
; дескрипторів, робоча пам'ять асемблера. Перелічувати їх усі в
; розподільнику означало б завести другий опис тієї самої карти,
; який роз'їдеться з першим при першій же зміні. Тому межа одна й
; груба: усе нижче зайняте назавжди, усе вище можна роздавати.
;
; При 512 МБ це лишає близько 128 МБ, тобто 32768 кадрів. Таблицям
; треба сім сторінок.
FramePoolBase   equ 0x18000000  ; 384 МБ: перший кадр, який можна роздати
FrameBitmapBase equ 0x300000    ; бітова карта: 3 МБ, одразу за блоком
FRAME_LIMIT     equ 0x100000000 ; стеля 4 ГБ - вище пам'яті не буває
; --- Палітра консолі у стилі MS-DOS ---
COL_TEXT        equ 0x00AAAAAA  ; світло-сірий: основний текст
COL_BRIGHT      equ 0x00FFFFFF  ; білий: заголовки та акценти
COL_DIM         equ 0x00808080  ; тьмяний: другорядне
COL_ERROR       equ 0x00FF5555  ; помилки

; Скільки шин PCI сканувати. У QEMU пристрої на шині 0, але
; мости можуть додати ще кілька. 8 - з великим запасом і швидко.
PCI_MAX_BUS     equ 8
MAX_CPUS        equ 32         ; стеля списку ядер

; --- Буфери мережевої карти ---
; Лежать у вільній ділянці 100..128 МБ (між купою і буферами
; файлових дескрипторів). Усе нижче 4 ГБ, як вимагає 32-бітний DMA.
NetRxBuffer     equ 0x7000000  ; 112 МБ: кільцевий буфер прийому
NetRxSize       equ 8192       ; те, що ми оголошуємо карті
NetRxAlloc      equ 0x4000     ; а насправді відводимо 16 КБ - запас,
                               ; бо при WRAP=1 карта пише за межу буфера
NetTxBuffer     equ 0x7004000  ; чотири буфери передачі по 2 КБ
NetTxSize       equ 2048

AppStackTop     equ 0x3FFFFF8  ; Вершина стеку для програм.
                               ; НЕ кратне 16, і це НАВМИСНО: SysV ABI вимагає
                               ; вирівнювання 16 ПЕРЕД call, тобто на ВХОДІ у
                               ; функцію RSP % 16 == 8 (call уже поклав адресу
                               ; повернення). Ядро заходить у програму через
                               ; iretq, без call, тому мусить подати саме таке
                               ; значення. Ставили 0x3FFFFF0 - і кожен movaps
                               ; по стеку в чужих програмах (DOOM) давав #GP.
HeapBase        equ 0x5000000  ; 80 МБ: купа ЯДРА
HeapSize        equ 0x1C00000  ; 28 МБ (до 108 МБ, далі буфери мережі)

; --- КУПА ПРОГРАМ КОРИСТУВАЧА ---
; Лежить вище за все інше, бо вона найбільша й найшвидше росте.
; ВАЖЛИВО: раніше вона стояла на 0x8000000 і ПОВНІСТЮ накладалася
; на FileDataBase - буфери файлових дескрипторів. Програма, яка
; водночас виділяла пам'ять і тримала відкритий файл, затирала
; власні дані. Тепер розведено.
;
; Значення дублюється у libc/eugene_libc.c (HEAP_START/HEAP_SIZE) -
; при зміні правити в обох місцях.
UserHeapBase    equ 0x10000000 ; 256 МБ
UserHeapSize    equ 0x8000000  ; 128 МБ (до 384 МБ)

; --- Файлові дескриптори (syscalls 16-20) ---
MAX_FD          equ 8          ; скільки файлів можна тримати відкритими
FD_CAP          equ 0x800000   ; 8 МБ - стеля розміру одного відкритого файлу
FileDataBase    equ 0x8000000  ; 128 МБ: буфери даних, MAX_FD * FD_CAP = 64 МБ
                               ; (тобто зайнято до 192 МБ)
FD_ENT          equ 64         ; розмір запису таблиці дескрипторів

; Прапорці open()
O_CREAT         equ 0x40
O_TRUNC         equ 0x200
O_APPEND        equ 0x400

; ==========================================================
; 1. ІНІЦІАЛІЗАЦІЯ ЯДРА (ТОЧКА ВХОДУ)
; ==========================================================
start:
    cli                         ; Вимикаємо переривання до повного налаштування
    cld                         ; Встановлюємо напрямок копіювання рядків (вперед)
    
    ; Отримуємо параметри екрана від UEFI-завантажувача
    mov     [ScreenBase], rcx   ; Базова адреса фреймбуфера
    mov     [ScreenWidth], edx  ; Ширина: скільки пікселів ВИДНО в рядку
    mov     [ScreenHeight], r8d ; Висота екрана (в пікселях)
    mov     [ScreenStride], r9d ; Крок: скільки перескочити до наступного рядка

    ; Старий завантажувач R9 не передавав — там буде сміття з UEFI.
    ; Крок фізично не може бути меншим за ширину, тому таке значення
    ; вважаємо відсутнім і повертаємось до старої поведінки.
    mov     eax, [ScreenStride]
    cmp     eax, [ScreenWidth]
    jae     .stride_ok
    mov     eax, [ScreenWidth]
    mov     [ScreenStride], eax
.stride_ok:

    ; --- Блок відомостей від завантажувача (R10) ---
    ;
    ; Досі ядро не знало нічого про те, які області пам'яті тримає
    ; прошивка, і розкладало свої структури за фіксованими адресами
    ; наосліп. Тепер завантажувач передає карту пам'яті UEFI.
    ;
    ; Старі завантажувачі R10 не заповнювали, тому там може бути
    ; сміття. Приймаємо блок лише за наявності підпису - саме тому
    ; підпис і потрібен: інакше ядро пішло б розбирати випадкову
    ; адресу як карту.
    xor     eax, eax
    mov     [MemMapAddr], rax
    mov     [MemMapSize], rax
    test    r10, r10
    jz      .no_bootinfo
    ; Перш ніж читати за вказівником, перевіряємо його на осудність.
    ; Тут ще немає IDT, тому відмова сторінки за диким вказівником
    ; дала б потрійну помилку й ребут без єдиного слова на екрані.
    test    r10, 7                  ; блок вирівняний по 8
    jnz     .no_bootinfo
    cmp     r10, 0x1000             ; нижче першої сторінки бути не може
    jb      .no_bootinfo
    mov     rax, 0x100000000
    cmp     r10, rax                ; і завжди нижче 4 ГБ
    jae     .no_bootinfo
    mov     rax, BOOTINFO_SIG
    cmp     qword [r10], rax
    jne     .no_bootinfo
    mov     rax, [r10 + 8]
    mov     [MemMapAddr], rax
    mov     rax, [r10 + 16]
    mov     [MemMapSize], rax
    mov     eax, [r10 + 24]
    mov     [MemMapDescSize], eax
    mov     eax, [r10 + 28]
    mov     [MemMapDescVer], eax
.no_bootinfo:

    ; Розподільник кадрів будується одразу: він працює лише з
    ; пам'яттю і нічого більше не потребує.
    call    FrameAllocInit

    ; І одразу забираємо сторінкові таблиці в прошивки. Досі ядро
    ; працювало на її таблицях, у пам'яті, яку вона після виходу зі
    ; служб вважає вільною - тобто на структурах, які саме ж могло
    ; затерти.
    call    PagingInit

    call    EnableSSE           ; Власна ініціалізація FPU/SSE (не покладаємось на UEFI)
    call    ClearScreen         ; Очищаємо екран
    call    DrawTaskbar         ; Малюємо верхню панель задач
    
    ; Ініціалізація підсистем ОС
    call    InitFAT32           ; Запускаємо файлову систему FAT32
    call    InitMouse
    call    InitHeap            ; Ініціалізуємо менеджер пам'яті
    ; Задача 0 - саме ядро - готова від самого початку й ніколи не
    ; звільняється. Без цього планувальник не знайшов би жодної
    ; готової задачі й крутився б порожнім колом.
    mov     byte [TaskState], 1
    call    InitTask1           ; Створюємо фоновий процес
    call    InitInterrupts      ; Налаштовуємо IDT (переривання та таймер)

    ; --- Банер у стилі MS-DOS ---
    mov     rcx, 10
    mov     rdx, 10
    lea     r8,  [MsgName]
    mov     r9d, COL_BRIGHT
    call    DrawString

    mov     rcx, 10
    mov     rdx, 30
    lea     r8,  [MsgCopy]
    mov     r9d, COL_TEXT
    call    DrawString

    mov     rcx, 10
    mov     rdx, 60
    lea     r8,  [MsgHint]
    mov     r9d, COL_TEXT
    call    DrawString

    ; Початкова позиція курсора консолі
    mov     [CursorX], 10
    mov     [CursorY], 90
    call    PrintPrompt         

; ==========================================================
; 2. ГОЛОВНИЙ ЦИКЛ ЯДРА (MAIN LOOP)
; ==========================================================
kernel_loop:
    call    NetPollBackground   ; Відповідаємо на ARP і пінг у фоні
    call    BlinkCursor         ; Курсор блимає, як у MS-DOS
    call    CheckKeyboard       ; Перевіряємо, чи натиснута клавіша
    mov     rcx, 10000          ; Штучна затримка, щоб не перегрівати CPU
.delay:
    dec     rcx
    jnz     .delay
    jmp     kernel_loop         

; Заморозка системи (при критичних помилках)
hang:                           
    cli                         
    hlt                         
    jmp     hang

; ==========================================================
; 3. КОМАНДНА ОБОЛОНКА (SHELL)
; ==========================================================
ExecuteCommand:
    mov     rbx, [BufferLen]
    mov     byte [CmdBuffer + rbx], 0   ; Ставимо 0 у кінці рядка (Null-terminated)
    call    NewLine             

    ; --- Диспетчер команд (Шукаємо збіги) ---
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdLS]
    call    StrCmp              
    test    rax, rax
    jz      .run_ls             

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCD]
    call    StrPrefix           
    test    rax, rax
    jz      .run_cd

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdOpen]
    call    StrPrefix           
    test    rax, rax
    jz      .run_open

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdFile]
    call    StrPrefix
    test    rax, rax
    jz      .run_file

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdRen]
    call    StrPrefix
    test    rax, rax
    jz      .run_ren

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdEdit]
    call    StrPrefix
    test    rax, rax
    jz      .run_edit
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCreate]
    call    StrPrefix
    test    rax, rax
    jz      .run_create
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdRM]
    call    StrPrefix
    test    rax, rax
    jz      .run_rm

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdTime]
    call    StrCmp
    test    rax, rax
    jz      .run_time

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdInfo]
    call    StrCmp
    test    rax, rax
    jz      .run_info

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdMemMap]
    call    StrCmp
    test    rax, rax
    jz      .run_memmap

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdTasks]
    call    StrCmp
    test    rax, rax
    jz      .run_tasks

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdPaging]
    call    StrCmp
    test    rax, rax
    jz      .run_paging

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdPfTest]
    call    StrCmp
    test    rax, rax
    jz      .run_pftest

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdNullTest]
    call    StrCmp
    test    rax, rax
    jz      .run_nulltest

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdBeep]
    call    StrCmp
    test    rax, rax
    jz      .run_beep

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdPci]
    call    StrCmp
    test    rax, rax
    jz      .run_pci

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCpuInfo]
    call    StrCmp
    test    rax, rax
    jz      .run_cpuinfo

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdNetInit]
    call    StrCmp
    test    rax, rax
    jz      .run_netinit

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdNetTest]
    call    StrCmp
    test    rax, rax
    jz      .run_nettest

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdPingArg]       ; 'PING ' з пробілом - є аргумент
    call    StrPrefix
    test    rax, rax
    jz      .run_pingname

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdNsLookup]
    call    StrPrefix
    test    rax, rax
    jz      .run_nslookup

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdHttpGet]
    call    StrPrefix
    test    rax, rax
    jz      .run_httpget

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdTcp]
    call    StrPrefix
    test    rax, rax
    jz      .run_tcp

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdSetDns]
    call    StrPrefix
    test    rax, rax
    jz      .run_setdns

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCopy]
    call    StrPrefix
    test    rax, rax
    jz      .run_copy

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdInstall]
    call    StrPrefix
    test    rax, rax
    jz      .run_install

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdPing]
    call    StrCmp
    test    rax, rax
    jz      .run_ping

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdDhcp]
    call    StrCmp
    test    rax, rax
    jz      .run_dhcp

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdIpconfig]
    call    StrCmp
    test    rax, rax
    jz      .run_ipconfig

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdHelp]
    call    StrCmp
    test    rax, rax
    jz      .run_help
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdWin]
    call    StrCmp
    test    rax, rax
    jz      .run_win

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCLS]
    call    StrCmp
    test    rax, rax
    jz      .run_cls

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdBack]
    call    StrCmp
    test    rax, rax
    jz      .run_back

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdReboot]
    call    StrCmp
    test    rax, rax
    jz      .run_reboot
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdRun]
    call    StrPrefix
    test    rax, rax
    jz      .run_app
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdMkdir]
    call    StrPrefix
    test    rax, rax
    jz      .run_mkdir

    ; Якщо жодна команда не підійшла - виводимо помилку
    cmp     [BufferLen], 0
    je      .finish

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgUnknown]
    mov     r9d, 0x000000FF     ; Червоний колір
    call    DrawString
    call    NewLine
    jmp     .finish

; --- Обробник CLS (Очищення екрана) ---
.run_cls:
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    jmp     .finish

; --- Обробник WIN (Тест GUI вікна) ---
.run_win:
    ; Малюємо тестове вікно посеред екрана
    mov     rcx, 150       ; X координата
    mov     rdx, 150       ; Y координата
    mov     r8,  400       ; Ширина
    mov     r9,  200       ; Висота
    call    DrawWindow

    ; Текст у заголовку вікна
    mov     rcx, 155
    mov     rdx, 155
    lea     r8,  [MsgWinTitle]      
    mov     r9d, 0x00FFFFFF     ; Білий текст
    call    DrawString

    ; Текст у тілі вікна
    mov     rcx, 170
    mov     rdx, 200
    lea     r8,  [MsgWinBody]      
    mov     r9d, 0x00000000     ; Чорний текст
    call    DrawString

    ; Опускаємо курсор консолі нижче вікна, щоб не писати поверх нього
    mov     qword [CursorX], 20
    mov     qword [CursorY], 380
    jmp     .finish

; --- Обробник CD (Зміна папки) ---
.run_cd:
    lea     rsi, [CmdBuffer + 3]        
    cmp     byte [rsi], '.'
    jne     .normal_cd
    cmp     byte [rsi+1], '.'
    jne     .normal_cd
    
    ; Якщо це "CD .."
    lea     rdi, [ParsedFileName]
    mov     rax, 0x2020202020202E2E    
    mov     qword [rdi], rax           
    mov     dword [rdi+8], 0x00202020  
    jmp     .do_cd_find

.normal_cd:
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    
.do_cd_find:
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .not_found_msg
    
    test    dl, 0x10            
    jz      .not_a_dir          

    test    eax, eax
    jnz     .set_cd
    mov     eax, [RootCluster]
    
.set_cd:
    ; Зберігаємо стару папку в історію
    push    rbx
    mov     ebx, [DirHistoryIndex]
    cmp     ebx, 63                 
    jge     .skip_history
    mov     ecx, [CurrentDirCluster]
    mov     dword [DirHistoryStack + ebx*4], ecx
    inc     dword [DirHistoryIndex]
.skip_history:
    pop     rbx
    mov     [CurrentDirCluster], eax

    ; Оновлюємо рядок шляху для промпту
    cmp     byte [CmdBuffer + 3], '.'   
    je      .cd_dotdot
    lea     rsi, [CmdBuffer + 3]        
    call    AppendPath
    jmp     .finish
.cd_dotdot:
    call    RemoveLastPath
    jmp     .finish

.not_a_dir:                     
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNotDir]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish

; --- Обробник OPEN (Диспетчер файлів) ---
; FILE <файл> - що система думає про цей файл, не відкриваючи його.
; REN <старе> <нове> - перейменувати файл або каталог.
;
; Процедура для цього в ядрі вже була - її додали разом із
; системними викликами для файлового менеджера. У консолі команди
; не було, і саме вона тепер потрібна: щоб перевести відео зі
; старого .BIN на власне розширення.
.run_ren:
    ; Шукаємо межу між двома іменами - пробіл після першого.
    lea     rsi, [CmdBuffer + 4]
    xor     ecx, ecx
.rn_find:
    mov     al, [rsi + rcx]
    test    al, al
    jz      .rn_usage
    cmp     al, ' '
    je      .rn_found
    inc     ecx
    cmp     ecx, 60
    jb      .rn_find
    jmp     .rn_usage
.rn_found:
    inc     ecx
    lea     rdx, [rsi + rcx]        ; друге ім'я
    cmp     byte [rdx], 0
    je      .rn_usage

    push    rdx
    lea     rdi, [SysNameA]
    call    FormatFAT32Name         ; RSI = старе ім'я
    pop     rsi
    lea     rdi, [SysNameB]
    call    FormatFAT32Name

    lea     r8,  [SysNameA]
    lea     r9,  [SysNameB]
    call    RenameFAT32
    jc      .rn_fail

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgRenOk]
    mov     r9d, 0x0000FF00
    call    DrawString
    mov     rcx, 130
    mov     rdx, [CursorY]
    lea     r8,  [SysNameB]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    jmp     .finish

.rn_fail:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgRenFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .finish

.rn_usage:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgRenUsage]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .finish

; Потрібна саме тому, що тип тепер визначається за вмістом: інакше
; переконатися, що розпізнавання працює, можна лише відкривши файл
; і подивившись, що станеться.
.run_file:
    lea     rsi, [CmdBuffer + 5]
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .not_found_msg
    test    dl, 0x10
    jnz     .not_a_dir
    mov     [LoadedFileSize], ebx
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    call    FileCommand
    jmp     .finish

.run_open:
    lea     rsi, [CmdBuffer + 5]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name

    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .not_found_msg

    test    dl, 0x10            
    jnz     .not_a_dir

    mov     [LoadedFileSize], ebx
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    
    ; --- Тип файлу визначаємо за вмістом, а не за іменем ---
    ;
    ; Досі розгалуження йшло за розширенням, і це давало дві тихі
    ; вади одразу: .BIN і .APP - розширення ПРОГРАМ - віддавались
    ; програвачу відео, а картинку можна було спробувати виконати.
    ; Ім'я файлу не є його типом; тип лежить усередині.
    call    EugDetect
    test    al, al
    jz      .open_by_ext

    cmp     al, EUG_VIDEO
    je      .open_video
    cmp     al, EUG_IMAGE
    je      .open_bmp
    cmp     al, EUG_SOUND
    je      .open_wav
    cmp     al, EUG_SYSTEM
    je      .open_system
    jmp     .open_unknown

    ; Файл без нашого підпису - дивимось на розширення. Це здогад, а
    ; не знання, тому й лишається другим кроком.
.open_by_ext:
    mov     eax, dword [ParsedFileName + 8]
    and     eax, 0x00FFFFFF     

    cmp     eax, 0x00505041     ; 'APP'
    je      .open_program
    cmp     eax, 0x004E4942     ; 'BIN'
    je      .open_program
    cmp     eax, 0x00445645     ; 'EVD' - відео без заголовка
    je      .open_video
    cmp     eax, 0x00475545     ; 'EUG' - але підпису немає
    je      .open_badeug
    cmp     eax, 0x00504D42     ; 'BMP'
    je      .open_bmp
    cmp     eax, 0x00545854     ; 'TXT'
    je      .open_txt
    cmp     eax, 0x00564157     ; 'WAV'
    je      .open_wav

.open_unknown:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgUnknownExt]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish

    ; Програму не показують - її запускають. Раніше саме тут
    ; починалось найдивніше: оболонку віддавали програвачу відео.
.open_program:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgIsProgram]
    mov     r9d, 0x0000FFFF
    call    DrawString
    call    NewLine
    jmp     .finish

.open_system:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgSysFile]
    mov     r9d, 0x0000FFFF
    call    DrawString
    call    NewLine
    jmp     .finish

.open_badeug:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgEugBroken]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish


.open_video:
    call    RunBadApplePlayer
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgVideoDone]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    jmp     .finish

.open_bmp:
    mov     r9, VideoMemoryBase
    mov     eax, [MediaOffset]
    add     r9, rax
    call    DrawBMP
.wait_esc_bmp:
    in      al, 0x64
    test    al, 1
    jz      .wait_esc_bmp
    test    al, 0x20            ; байт від миші - ігноруємо
    jz      .web_kbd
    in      al, 0x60
    mov     byte [MouseState], 0
    jmp     .wait_esc_bmp
.web_kbd:
    in      al, 0x60
    cmp     al, 0x01
    jne     .wait_esc_bmp
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    jmp     .finish

.open_txt:
    ; Було: вивалювали весь текст у консоль одним DrawString - усе,
    ; що не влізло на екран, губилося без можливості прокрутити.
    ; Стало: те саме вікно, що й у редактора, але лише для читання.
    jmp     .view_file

.open_wav:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgAudio]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    mov     rax, 311
    call    PlaySound
    call    BeepDelay
    call    StopSound
    jmp     .finish

; Спроба запустити ядро як програму. Пояснюємо, що це, підказуємо,
; що з цим файлом насправді роблять, і віддаємо керування консолі
; ядра - там поруч команда INSTALL, якою його ставлять.
.ra_is_kernel:
    ; Чистимо екран: інакше текст лягає поверх вікон GUI, який нас
    ; щойно покликав, і прочитати його неможливо.
    ;
    ; Повертаємось звідси у консоль ядра, а не в GUI - так і задумано.
    ; Відмова запустити образ ядра це системна помилка, а не звичайний
    ; вихід програми: показати її треба там, де поруч є INSTALL, яким
    ; цей файл насправді ставлять. Ланцюжок ExecStack тут навмисно не
    ; доводиться до кінця; FindFAT32Entry на зворотному шляху не
    ; знаходить оболонку, і керування лишається в консолі - саме там,
    ; де воно й потрібне.
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNotApp]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNotApp2]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgPressAnyKey]
    mov     r9d, 0x0000FFFF
    call    DrawString
.rk_flush:
    in      al, 0x64
    test    al, 1
    jz      .rk_wait
    in      al, 0x60
    jmp     .rk_flush
.rk_wait:
    in      al, 0x64
    test    al, 1
    jz      .rk_wait
    test    al, 0x20                ; байт від миші - ігноруємо
    jz      .rk_kbd
    in      al, 0x60
    mov     byte [MouseState], 0
    jmp     .rk_wait
.rk_kbd:
    in      al, 0x60
    test    al, 0x80                ; чекаємо саме натискання
    jnz     .rk_wait
    mov     byte [ExecPending], 0
    ; Якщо запуск просила програма, її треба розбудити - інакше
    ; відмова запустити образ ядра теж повісила б оболонку.
    cmp     qword [SpawnParent], 0
    jne     .ra_spawn_failed
    jmp     .ra_after_app

.not_found_msg:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgReadErr]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish
    
; --- Обробник RUN (Запуск сторонніх програм) ---
.run_app:
    ; Зберігаємо хвіст рядка після імені програми, щоб вона могла
    ; прочитати свої аргументи через syscall 21.
    lea     rsi, [CmdBuffer + 4]
    lea     rdi, [CmdArgs]
    xor     ecx, ecx
.ra_skip:                               ; пропускаємо саме ім'я програми
    mov     al, [rsi + rcx]
    test    al, al
    jz      .ra_noargs
    cmp     al, ' '
    je      .ra_copy
    inc     ecx
    cmp     ecx, 100
    jb      .ra_skip
.ra_noargs:
    mov     byte [CmdArgs], 0
    jmp     .ra_parsed
.ra_copy:
    inc     ecx                         ; пропускаємо сам пробіл
    xor     edx, edx
.ra_cp:
    mov     al, [rsi + rcx]
    mov     [rdi + rdx], al
    test    al, al
    jz      .ra_parsed
    inc     ecx
    inc     edx
    cmp     edx, 126
    jb      .ra_cp
    mov     byte [rdi + rdx], 0
.ra_parsed:

    lea     rsi, [CmdBuffer + 4]
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name

    mov     byte [ExecDepth], 0         ; новий ланцюжок запусків

; --- Сюди ж повертаємось, коли програма попросила запустити іншу ---
.ra_load:
    ; Позначаємо, що ядро працює з диском. Читання образу йде тут з
    ; УВІМКНЕНИМИ перериваннями, тобто таймер може спинити нас просто
    ; посеред ланцюга - а syscall іншої задачі піде тими самими
    ; SectorBuffer і FatCacheBuf. Див. FsWaitIfNeeded.
    mov     byte [FsBusy], 1
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .ra_load_failed
    mov     [LoadedFileSize], ebx

    ; FindFAT32Entry віддає початковий кластер у EAX, а створення
    ; простору нижче затирає RAX своїм результатом. Без цього рядка
    ; LoadFAT32Chain іде по ланцюгу від випадкового числа й кладе за
    ; 64 МБ сміття - програма стартує й падає на першій інструкції.
    mov     [LoadStartCluster], eax

    ; --- Образ вантажимо ВЖЕ В ПРОСТІР ПРОГРАМИ ---
    ;
    ; Раніше ядро писало образ за фізичною адресою через тотожне
    ; відображення. Тепер вікно програми в кожної задачі своє, тож
    ; писати треба в її сторінки - інакше програма застане чуже.
    ;
    ; Сторінки під образ наперед не виділяємо: запис у них дасть
    ; відмову, а обробник видасть кадр. Той самий механізм, що й для
    ; купи, лише область інша.
    call    PagingCloneSpace
    test    rax, rax
    jz      .load_shared            ; кадрів немає - вантажимо як раніше
    mov     [PendingCR3], rax

    ; Простір програми на час завантаження стає простором задачі 0.
    ; Інакше перше ж переривання таймера повернуло б нас у ядерний
    ; простір посеред читання, і решта образу лягла б не туди.
    mov     [TaskCR3], rax
    mov     cr3, rax
.load_shared:

    mov     eax, [LoadStartCluster]
    mov     r9, AppMemoryBase
    call    LoadFAT32Chain

    ; Перший байт образу читаємо ЗАРАЗ, поки діє простір програми:
    ; у ядерному просторі за цією адресою лежить зовсім інше -
    ; сторінки там свої, і образу в них немає.
    mov     al, [AppMemoryBase]
    mov     [AppFirstByte], al

    ; Повертаємо задачі 0 її власний простір.
    cmp     qword [PendingCR3], 0
    je      .load_done
    mov     rax, [PagePml4]
    mov     [TaskCR3], rax
    mov     cr3, rax
.load_done:
    mov     byte [FsBusy], 0        ; диск вільний

    ; --- Це програма чи образ ядра? ---
    ;
    ; Ядро злінковане на org 0x100000, а програми вантажаться за
    ; AppMemoryBase, тому кожна його абсолютна адреса б'є мимо.
    ; Але падає воно ще раніше: перша ж інструкція ядра - cli
    ; (0xFA), тобто вимкнути переривання і вбити планувальник.
    ; Далі воно ставить власні GDT/IDT поверх наших - потрійна
    ; помилка і ребут без жодного пояснення.
    ;
    ; Розпізнаємо саме за цим байтом, а не за іменем файлу: так
    ; ловляться і KERNEL.BIN, і KERNEL.BAK, і будь-який K2.BIN,
    ; зібраний щойно. Жодна програма користувача не починається з
    ; cli - їй це просто нічого не дає.
    cmp     byte [AppFirstByte], 0xFA
    je      .ra_is_kernel

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgRun]
    mov     r9d, 0x00FF00FF
    call    DrawString
    call    NewLine

    mov     byte [ExecPending], 0
    call    SpawnAppTask

.wait_for_app:
    ; Спати, а не крутитись. Планувальник ділить час порівну між
    ; ГОТОВИМИ задачами, а ця тут лише опитує три прапорці - і при
    ; живій оболонці з грою забирала собі третину процесора просто
    ; так. hlt віддає решту кванта, а таймер на 1000 Гц будить нас
    ; назад через мілісекунду: для опитування цього з головою.
    sti
    hlt
    call    CheckKeyboard

    ; Пам'ять задачі, що завершилась, повертаємо тут-таки. Раніше це
    ; робилось лише після виходу з циклу - а поки жива оболонка, ми
    ; звідси не виходимо взагалі. Позначка ж одна на всіх: другий
    ; запуск затер би позначку про перший, і той простір лишився б
    ; зайнятим назавжди.
    cmp     qword [PendingFree], 0
    je      .nothing_to_free
    mov     rax, [PendingFree]
    mov     qword [PendingFree], 0
    call    PagingFreeSpace
.nothing_to_free:
    ; Задача попросила запуск через 37 і заснула. Її слот, простір і
    ; пам'ять лишились на місці - ми лише додаємо ще одну задачу.
    cmp     byte [SpawnPending], 1
    je      .ra_spawn_child
    cmp     byte [AppRunning], 1
    je      .wait_for_app
    jmp     .ra_after_app

; Запуск дитини не вдався - найчастіше просто одруківка в імені.
;
; Раніше звідси йшли просто у .finish, тобто ядро поверталося до
; свого запрошення, а той, хто просив запуск, лишався спати
; НАЗАВЖДИ. Одна помилка в імені файлу вішала оболонку.
.ra_load_failed:
    mov     byte [FsBusy], 0        ; диск вільний і після невдачі
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgReadErr]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

.ra_spawn_failed:
    mov     byte [SpawnBusy], 0
    ; Полотно, підготовлене під запуск, що не відбувся. Лишити його
    ; означало б, що НАСТУПНА, звичайна програма мовчки дістане чуже
    ; полотно й малюватиме в нікуди - екран порожній, а вона працює.
    mov     qword [PendingCanvas], 0
    mov     rbx, [SpawnParent]
    test    rbx, rbx
    jz      .finish                 ; запуск просила консоль - як раніше

    ; Клонований простір, який так і не знадобився, повертаємо в пул
    ; тут-таки: іншої нагоди про нього згадати не буде.
    mov     qword [SpawnParent], 0
    mov     byte [TaskState + rbx], 1
    mov     rax, [PendingCR3]
    test    rax, rax
    jz      .rsf_no_space
    mov     qword [PendingCR3], 0
    call    PagingFreeSpace
.rsf_no_space:
    jmp     .wait_for_app

.ra_spawn_child:
    mov     byte [SpawnPending], 0
    lea     rsi, [ExecRequest]
    lea     rdi, [ParsedFileName]
    mov     rcx, 11
    cld
    rep     movsb
    jmp     .ra_load

.ra_after_app:
    ; --- Повернення пам'яті задачі, що завершилась ---
    ;
    ; Сюди сходяться всі три шляхи виходу: звичайний, аварійне
    ; вбиття з клавіатури і зняття після винятку. Тут ми вже в
    ; ядерному просторі, на своєму стеку, без обмежень - тобто це
    ; єдине місце, де звільняти безпечно.
    mov     rax, [PendingFree]
    test    rax, rax
    jz      .no_pending_free
    mov     qword [PendingFree], 0
    call    PagingFreeSpace
.no_pending_free:
    ; --- Програма попросила запустити іншу (syscall 28)? ---
    cmp     byte [ExecPending], 0
    jne     .ra_chain

    ; --- Ні. Може, ми самі сюди прийшли з чийогось запуску? ---
    cmp     byte [ExecDepth], 0
    je      .ra_finish
    dec     byte [ExecDepth]
    movzx   rax, byte [ExecDepth]
    imul    rax, 11
    lea     rsi, [ExecStack]
    add     rsi, rax
    lea     rdi, [ParsedFileName]
    mov     rcx, 11
    cld
    rep     movsb
    jmp     .ra_load                    ; вертаємо того, хто запускав

.ra_chain:
    mov     byte [ExecPending], 0
    ; Запам'ятовуємо, кого треба буде повернути після нової програми
    movzx   rax, byte [ExecDepth]
    cmp     al, 3
    jae     .ra_nopush
    imul    rax, 11
    lea     rdi, [ExecStack]
    add     rdi, rax
    lea     rsi, [ParsedFileName]
    mov     rcx, 11
    cld
    rep     movsb
    inc     byte [ExecDepth]
.ra_nopush:
    lea     rsi, [ExecRequest]
    lea     rdi, [ParsedFileName]
    mov     rcx, 11
    cld
    rep     movsb
    jmp     .ra_load

.ra_finish:

    ; ВИПРАВЛЕНО: раніше тут одразу йшов ClearScreen, тому вивід
    ; консольної програми (наприклад fasm) стирався за мить після
    ; завершення - на екрані щось мигало і зникало.
    ; Тепер чекаємо на клавішу, а екран чистимо лише після неї.
    ; Для GUI-програм це не заважає: вони самі малюють на весь екран.
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgPressAnyKey]
    mov     r9d, 0x0000FFFF         
    call    DrawString

.wfa_flush:                         ; спорожнюємо чергу клавіатури,
    in      al, 0x64                ; щоб не зарахувати стару клавішу
    test    al, 1
    jz      .wfa_wait
    in      al, 0x60
    jmp     .wfa_flush

.wfa_wait:
    in      al, 0x64
    test    al, 1
    jz      .wfa_wait
    test    al, 0x20                ; байт від миші - ігноруємо
    jz      .wfa_kbd
    in      al, 0x60
    mov     byte [MouseState], 0
    jmp     .wfa_wait
.wfa_kbd:
    in      al, 0x60
    test    al, 0x80                ; чекаємо саме натискання
    jnz     .wfa_wait

    call    ClearScreen             
    call    DrawTaskbar             
    mov     qword [CursorX], 20     
    mov     qword [CursorY], 100
    jmp     .finish                 

; --- Обробник BACK (Крок назад по історії папок) ---
.run_back:
    mov     ebx, [DirHistoryIndex]
    test    ebx, ebx                
    jz      .no_history             
    dec     ebx                     
    mov     [DirHistoryIndex], ebx
    mov     eax, dword [DirHistoryStack + ebx*4]  
    mov     [CurrentDirCluster], eax              
    call    RemoveLastPath          
    jmp     .finish

.no_history:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNoHistory]
    mov     r9d, 0x000000FF         
    call    DrawString
    call    NewLine
    jmp     .finish

; --- Інші команди ОС ---
.run_ls:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgLS]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    call    ListFilesFAT32      
    jmp     .finish

.run_info:                      
    xor     eax, eax
    cpuid                       
    mov     dword [VendorID], ebx
    mov     dword [VendorID + 4], edx
    mov     dword [VendorID + 8], ecx
    lea     rsi, [VendorID]
    mov     rcx, 12
.to_upper:
    cmp     byte [rsi], 'a'
    jb      .skip_char
    cmp     byte [rsi], 'z'
    ja      .skip_char
    sub     byte [rsi], 32
.skip_char:
    inc     rsi
    dec     rcx
    jnz     .to_upper
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgCPU]
    mov     r9d, 0x0000FF00     
    call    DrawString
    add     rcx, 110
    lea     r8,  [VendorID]
    mov     r9d, 0x00FFFFFF     
    call    DrawString
    call    NewLine
    jmp     .finish

.run_time:
    call    GetRTC
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgTime]
    mov     r9d, 0x00AAAAAA
    call    DrawString
    add     rcx, 90
    lea     r8,  [TimeStr]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    jmp     .finish

; Навмисна відмова сторінки: перевірка того, що обробник справді
; знімає CR2 і розбирає код помилки. Інакше цей шлях лишався б
; Запис через нульовий покажчик. Має дати відмову з адресою 0 і
; бітом W=1: сторінки немає, зверталися на запис.
.run_nulltest:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNullTest]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    xor     rax, rax
    mov     qword [rax], 0
    jmp     .finish

; неперевіреним доти, доки щось не впаде по-справжньому - тобто
; саме тоді, коли діагностика найпотрібніша.
;
; Читаємо рівно на 4 ГБ - перша адреса за межею нашого відображення.
; Це заразом підтверджує, що межа саме там, де ми думаємо.
.run_pftest:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgPfTest]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    mov     rax, 0x100000000
    mov     rax, [rax]
    jmp     .finish

.run_paging:
    call    PagingCommand
    jmp     .finish

.run_tasks:
    call    TasksCommand
    jmp     .finish

.run_memmap:
    call    MemMapCommand
    jmp     .finish

.run_beep:
    mov     rax, 311            
    call    PlaySound
    call    BeepDelay
    mov     rax, 233            
    call    PlaySound
    call    BeepDelay
    mov     rax, 261            
    call    PlaySound
    call    BeepDelay
    call    StopSound
    call    NewLine
    jmp     .finish

.run_help:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgHelpList]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    call    NewLine
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgHelpNet]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgHelpSys]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine
    jmp     .finish
    
.run_mkdir:
    lea     rsi, [CmdBuffer + 6]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name             
    lea     r8, [ParsedFileName]
    call    CreateDirFAT32              
    jc      .disk_err_msg                   
    
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgDirCreated]
    mov     r9d, 0x0000FF00
    call    DrawString
    add     rcx, 150
    lea     r8,  [ParsedFileName]
    call    DrawString                  
    call    NewLine
    jmp     .finish

.run_create:
    lea     rsi, [CmdBuffer + 7]        
    lea     rdi, [ParsedFileName]       
    call    FormatFAT32Name             
    lea     r8, [ParsedFileName]
    call    CreateFileFAT32             
    jc      .disk_err_msg                   
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgCreated]
    mov     r9d, 0x0000FF00
    call    DrawString
    add     rcx, 120
    lea     r8,  [ParsedFileName]
    call    DrawString                  
    call    NewLine
    jmp     .finish

.run_rm:
    lea     rsi, [CmdBuffer + 3]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    DeleteFileFAT32
    jc      .disk_err_msg                     
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgDeleted]
    mov     r9d, 0x0000FF00             
    call    DrawString
    call    NewLine
    jmp     .finish

.disk_err_msg:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgWriteErr]
    mov     r9d, 0x000000FF             
    call    DrawString
    call    NewLine
    jmp     .finish

.run_reboot:
    in      al, 0x64
    test    al, 2
    jnz     .run_reboot
    mov     al, 0xFE            
    out     0x64, al
    jmp     hang

; --- ІЗОЛЬОВАНА ПІДСИСТЕМА РЕДАКТОРА / ПЕРЕГЛЯДАЧА ---
; Спільний код для EDIT (редагування) і OPEN (лише перегляд).
; Різницю задає EdReadOnly.
.run_edit:
    mov     byte [EdReadOnly], 0
    lea     rsi, [CmdBuffer + 5]
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    jmp     .ed_common

; Вхід із OPEN. .run_open уже знайшов файл і завантажив його вміст
; у VideoMemoryBase, а LoadedFileSize виставлено — тому тут одразу
; переходимо до копіювання, без повторного читання з диска.
.view_file:
    mov     byte [EdReadOnly], 1
    call    .ed_reset
    jmp     .ed_copy

.ed_common:
    call    .ed_reset

    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .ui_init            
    mov     [LoadedFileSize], ebx
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain

.ed_copy:
    ; Довжина тепер береться з розміру файлу, а не з пошуку нульового
    ; байта: нуль усередині файлу раніше обрізав текст мовчки.
    mov     rsi, VideoMemoryBase
    mov     rdi, EditorBuffer
    xor     rcx, rcx
    mov     ecx, [LoadedFileSize]
    cmp     rcx, EDITOR_CAP - 1
    jbe     .re_size_ok
    mov     rcx, EDITOR_CAP - 1     ; на 4 МБ це вже майже неможливо
.re_size_ok:
    mov     [EdLen], rcx
    cld
    rep     movsb
    mov     qword [EditorCursor], 0 ; каретка на початку файлу

    ; --- Це взагалі текст? ---
    ; Нульовий байт у текстовому файлі не трапляється, а в бінарнику
    ; трапляється майже завжди. Раніше довжина шукалась саме за нулем,
    ; тому бінарник просто обрізався на першому ж і виглядав коротким.
    ; Тепер файл вантажиться повністю - і без цієї перевірки його можна
    ; було б відкрити на редагування, ввести один символ і зіпсувати
    ; F2-ом. Тому: знайшли нуль - тільки перегляд.
    mov     byte [EdBinary], 0
    mov     rcx, [EdLen]
    cmp     rcx, 8192               ; дивитись весь файл сенсу немає
    jbe     .re_scan
    mov     rcx, 8192
.re_scan:
    test    rcx, rcx
    jz      .re_text
    mov     rsi, EditorBuffer
.re_scan_l:
    cmp     byte [rsi], 0
    je      .re_binary
    inc     rsi
    dec     rcx
    jnz     .re_scan_l
    jmp     .re_text
.re_binary:
    mov     byte [EdBinary], 1
    mov     byte [EdReadOnly], 1
.re_text:

.ui_init:
    call    ClearScreen
    mov     rdi, [ScreenBase]
    movsxd  rcx, dword [ScreenStride]
    imul    rcx, 20
    mov     eax, 0x000000AA         ; синя смуга - режим редагування
    cmp     byte [EdReadOnly], 0
    je      .ed_hdr_color
    mov     eax, 0x00006060         ; бірюзова - режим перегляду
.ed_hdr_color:
    cld
    rep     stosd

    lea     r8,  [MsgEditor]
    cmp     byte [EdReadOnly], 0
    je      .ed_hdr_text
    lea     r8,  [MsgViewer]
.ed_hdr_text:
    mov     rcx, 20
    mov     rdx, 0
    mov     r9d, 0x00FFFFFF
    call    DrawString

    mov     qword [CursorX], 20
    mov     qword [CursorY], 40

    call    .ed_render
    jmp     .editor_loop

; ----------------------------------------------------------
; .ed_status - права частина заголовка: де стоїть каретка і
; скільки всього тексту. Без цього повідомлення FASM про помилку
; в рядку N нема з чим зіставити.
; ----------------------------------------------------------
.ed_status:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9

    ; Перемальовуємо ВСЮ смугу заголовка разом із підказкою: інакше
    ; від попереднього стану лишаються верхні рядки пікселів.
    mov     rdi, [ScreenBase]
    mov     ecx, [ScreenStride]
    imul    ecx, 20
    mov     eax, 0x000000AA         ; синя - редагування
    cmp     byte [EdBinary], 0
    je      .es_chk_ro
    mov     eax, 0x00800000         ; темно-червона - бінарник
    jmp     .es_fill
.es_chk_ro:
    cmp     byte [EdReadOnly], 0
    je      .es_fill
    mov     eax, 0x00006060         ; бірюзова - перегляд
.es_fill:
    cld
    rep     stosd

    mov     rcx, 20
    mov     rdx, 0
    lea     r8,  [MsgEditor]
    cmp     byte [EdBinary], 0
    je      .es_chk_hdr
    lea     r8,  [MsgBinary]
    jmp     .es_hdr
.es_chk_hdr:
    cmp     byte [EdReadOnly], 0
    je      .es_hdr
    lea     r8,  [MsgViewer]
.es_hdr:
    mov     r9d, 0x00FFFFFF
    call    DrawString

    cmp     byte [EdGotoMode], 0
    jne     .es_goto

    ; --- LINE n ---
    lea     rdi, [EdStatusStr]
    mov     eax, [EdLineNo]
    call    DecToStr
    mov     rcx, 420
    mov     rdx, 0
    lea     r8,  [MsgEdLine]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    mov     rcx, 470
    mov     rdx, 0
    lea     r8,  [EdStatusStr]
    mov     r9d, 0x0000FF00
    call    DrawString

    ; --- COL c ---
    lea     rdi, [EdStatusStr]
    mov     eax, [EdCaretCol]
    inc     eax
    call    DecToStr
    mov     rcx, 570
    mov     rdx, 0
    lea     r8,  [MsgEdCol]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    mov     rcx, 610
    mov     rdx, 0
    lea     r8,  [EdStatusStr]
    mov     r9d, 0x0000FF00
    call    DrawString

    ; --- SIZE ---
    lea     rdi, [EdStatusStr]
    mov     rax, [EdLen]
    call    DecToStr
    mov     rcx, 700
    mov     rdx, 0
    lea     r8,  [MsgEdSize]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    mov     rcx, 750
    mov     rdx, 0
    lea     r8,  [EdStatusStr]
    mov     r9d, 0x0000FF00
    call    DrawString
    jmp     .es_done

.es_goto:
    mov     rcx, 420
    mov     rdx, 0
    lea     r8,  [MsgEdGoto]
    mov     r9d, 0x00FFFF00
    call    DrawString
    lea     rdi, [EdStatusStr]
    mov     rax, [EdGotoNum]
    call    DecToStr
    mov     rcx, 520
    mov     rdx, 0
    lea     r8,  [EdStatusStr]
    mov     r9d, 0x00FFFFFF
    call    DrawString

.es_done:
    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; Робота з логічними рядками. Рядки в асемблерному коді завжди
; коротші за ширину екрана, тому рух угору-вниз рахуємо саме по
; логічних рядках - це і простіше, і поводиться передбачувано.
; ----------------------------------------------------------
; RAX = позиція -> RAX = початок логічного рядка
.ed_line_start:
    push    rbx
    mov     rbx, EditorBuffer
.ls_l:
    test    rax, rax
    jz      .ls_done
    cmp     byte [rbx + rax - 1], 10
    je      .ls_done
    dec     rax
    jmp     .ls_l
.ls_done:
    pop     rbx
    ret

; RAX = будь-яка позиція в рядку -> RAX = позиція його LF або EdLen
.ed_line_end:
    push    rbx
    push    rcx
    mov     rbx, EditorBuffer
    mov     rcx, [EdLen]
.le_l:
    cmp     rax, rcx
    jae     .le_done
    cmp     byte [rbx + rax], 10
    je      .le_done
    inc     rax
    jmp     .le_l
.le_done:
    pop     rcx
    pop     rbx
    ret

; ----------------------------------------------------------
; .ed_reset - скинути стан перед відкриттям файлу.
; ----------------------------------------------------------
.ed_reset:
    push    rax
    push    rcx
    push    rdi
    ; Буфер більше не затираємо: 4 МБ нулів на кожне відкриття - це
    ; мільйони записів даремно. Довжина тепер явна, тож старі байти
    ; за нею просто ніхто не читає.
    mov     qword [EdLen], 0
    mov     qword [EditorCursor], 0
    mov     byte [EdGotoMode], 0
    mov     byte [EdBinary], 0      ; інакше прапорець тягнувся б із попереднього файлу
    mov     dword [EdScroll], 0
    mov     byte [EdFollow], 0      ; при відкритті показуємо ПОЧАТОК файлу
    mov     byte [EdExtended], 0
    pop     rdi
    pop     rcx
    pop     rax
    ret

; ----------------------------------------------------------
; .ed_render - перемалювати текст із прокруткою.
;
; Прохід 1 рахує, у якому візуальному рядку стоїть каретка.
; Якщо EdFollow=1 (щойно друкували) - підганяємо EdScroll так,
; щоб каретка була видима. Прохід 2 малює лише видимі рядки.
; Раніше текст просто малювався від початку, і все, що не влізло
; на екран, зникало назавжди.
; ----------------------------------------------------------
.ed_render:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11

    ; --- геометрія текстової області ---
    mov     eax, [ScreenWidth]
    sub     eax, 40
    xor     edx, edx
    mov     ecx, 9
    div     ecx
    test    eax, eax
    jnz     .er_cols_ok
    mov     eax, 1
.er_cols_ok:
    mov     [EdCols], eax

    mov     eax, [ScreenHeight]
    sub     eax, 60
    xor     edx, edx
    mov     ecx, 20
    div     ecx
    test    eax, eax
    jnz     .er_rows_ok
    mov     eax, 1
.er_rows_ok:
    mov     [EdRows], eax

    ; ================= ПРОХІД 1: рахуємо рядки =================
    ; Прохід іде по ВСЬОМУ тексту, а не до каретки, і принагідно
    ; запам'ятовує, у якому рядку й колонці каретка опинилась.
    ; Раніше каретка завжди була кінцем тексту, тому цього не
    ; потрібно було - і саме тому редагувати всередині було нічим.
    xor     r10d, r10d              ; поточний рядок
    xor     r11d, r11d              ; поточна колонка
    xor     r9, r9                  ; позиція в тексті
    mov     dword [EdCaretRow], 0
    mov     dword [EdCaretCol], 0
    mov     dword [EdLineNo], 1
    mov     rcx, [EdLen]
    mov     rsi, EditorBuffer
    test    rcx, rcx
    jz      .er_p1_done
.er_p1:
    mov     al, [rsi]
    inc     rsi
    inc     r9
    dec     rcx
    cmp     al, 13
    je      .er_p1_cr
    cmp     al, 10
    je      .er_p1_nl
    cmp     r11d, dword [EdCols]
    jb      .er_p1_put
    inc     r10d
    xor     r11d, r11d
.er_p1_put:
    inc     r11d
    jmp     .er_p1_mark
.er_p1_cr:
    test    rcx, rcx                ; CRLF рахуємо за один перенос
    jz      .er_p1_nl
    cmp     byte [rsi], 10
    jne     .er_p1_nl
    inc     rsi
    inc     r9
    dec     rcx
.er_p1_nl:
    inc     r10d
    xor     r11d, r11d
    cmp     r9, [EditorCursor]
    ja      .er_p1_next             ; логічний рядок рахуємо лише до каретки
    inc     dword [EdLineNo]
.er_p1_mark:
    cmp     r9, [EditorCursor]
    jne     .er_p1_next
    mov     [EdCaretRow], r10d
    mov     [EdCaretCol], r11d
.er_p1_next:
    test    rcx, rcx
    jnz     .er_p1
.er_p1_done:
    mov     [EdLines], r10d

    ; --- прокрутка їде за кареткою в ОБИДВА боки ---
    ; Раніше каретка могла бути лише в кінці тексту, тому вистачало
    ; підтягувати екран донизу. Тепер вона ходить вільно, і екран
    ; має наздоганяти її і вгору теж.
    cmp     byte [EdFollow], 0
    je      .er_scroll_ok
    mov     eax, [EdCaretRow]
    cmp     eax, [EdScroll]
    jae     .er_chk_below
    mov     [EdScroll], eax         ; каретка вище видимого - піднімаємось
    jmp     .er_scroll_ok
.er_chk_below:
    mov     eax, [EdCaretRow]
    sub     eax, [EdRows]
    inc     eax
    js      .er_scroll_ok           ; каретка й так видима
    cmp     eax, [EdScroll]
    jbe     .er_scroll_ok
    mov     [EdScroll], eax
.er_scroll_ok:

    ; ================= ПРОХІД 2: малюємо =================
    ; чистимо все під синьою смугою заголовка
    mov     rdi, [ScreenBase]
    mov     eax, [ScreenStride]
    imul    eax, 20
    shl     eax, 2
    mov     ebx, eax
    add     rdi, rbx
    mov     eax, [ScreenStride]
    mov     ecx, [ScreenHeight]
    sub     ecx, 20
    imul    eax, ecx
    mov     ecx, eax
    xor     eax, eax
    cld
    rep     stosd

    xor     r10d, r10d
    xor     r11d, r11d
    mov     rcx, [EdLen]            ; малюємо весь текст, а не до каретки
    mov     rsi, EditorBuffer
    test    rcx, rcx
    jz      .er_caret
.er_p2:
    mov     al, [rsi]
    inc     rsi
    dec     rcx
    cmp     al, 13
    je      .er_p2_cr
    cmp     al, 10
    je      .er_p2_nl
    cmp     r11d, dword [EdCols]
    jb      .er_p2_put
    inc     r10d
    xor     r11d, r11d
.er_p2_put:
    mov     ebx, r10d
    sub     ebx, [EdScroll]
    js      .er_p2_skip             ; вище видимої області
    cmp     ebx, dword [EdRows]
    jae     .er_p2_skip             ; нижче видимої області

    movzx   r8, al                  ; символ (робимо ДО псування AL)
    push    rcx
    push    rsi
    push    r10
    push    r11
    mov     eax, r11d
    imul    eax, 9
    add     eax, 20
    mov     rcx, rax                ; X
    mov     eax, ebx
    imul    eax, 20
    add     eax, 40
    mov     rdx, rax                ; Y
    mov     r9d, 0x00FFFFFF
    call    DrawChar_Safe           ; УВАГА: псує R10, тому він у стеку
    pop     r11
    pop     r10
    pop     rsi
    pop     rcx
.er_p2_skip:
    inc     r11d
    jmp     .er_p2_next
.er_p2_cr:
    test    rcx, rcx
    jz      .er_p2_nl
    cmp     byte [rsi], 10
    jne     .er_p2_nl
    inc     rsi
    dec     rcx
.er_p2_nl:
    inc     r10d
    xor     r11d, r11d
.er_p2_next:
    test    rcx, rcx
    jnz     .er_p2

.er_caret:
    ; Координати каретки беремо з проходу 1: вона більше не
    ; зобов'язана стояти після останнього символу.
    mov     eax, [EdCaretCol]
    imul    eax, 9
    add     eax, 20
    mov     [CursorX], rax
    mov     eax, [EdCaretRow]
    sub     eax, [EdScroll]
    jns     .er_caret_vis
    xor     eax, eax
.er_caret_vis:
    imul    eax, 20
    add     eax, 40
    mov     [CursorY], rax

    call    .ed_status

    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

.editor_loop:
    cmp     byte [EdReadOnly], 0
    jne     .ed_no_caret            ; у перегляді каретки немає
    call    DrawCursor
.ed_no_caret:
    in      al, 0x64
    test    al, 1
    jz      .editor_loop
    ; ВИПРАВЛЕНО: біт 5 == 1 означає, що байт від МИШІ, а не з клавіатури.
    ; Без цієї перевірки dx=1 при русі мишею читався як скан-код 0x01 (ESC)
    ; і редактор просто вилітав, а байт 0x08 сипав у текст символ '7'.
    test    al, 0x20
    jz      .ed_kbd_byte
    in      al, 0x60                ; байт миші - викидаємо
    mov     byte [MouseState], 0    ; наступний пакет почнеться з нуля
    jmp     .editor_loop
.ed_kbd_byte:
    in      al, 0x60

    ; --- Розширені клавіші приходять як 0xE0 + код ---
    ; Раніше 0xE0 не мав біта 0x80, тому проходив далі й потрапляв
    ; у xlatb як звичайний символ, а сам код клавіші губився.
    cmp     al, 0xE0
    jne     .ed_not_ext
    mov     byte [EdExtended], 1
    jmp     .editor_loop
.ed_not_ext:
    test    al, 0x80            ; відпускання клавіші
    jz      .ed_press
    mov     byte [EdExtended], 0
    jmp     .editor_loop
.ed_press:
    mov     byte [EdExtended], 0

    ; --- режим введення номера рядка (F3) перехоплює все ---
    cmp     byte [EdGotoMode], 0
    jne     .ed_goto_key

    cmp     al, 0x01            ; ESC
    je      .exit_editor
    cmp     al, 0x3C            ; F2 - зберегти
    je      .ed_try_save
    cmp     al, 0x3D            ; F3 - перейти на рядок
    je      .ed_goto_start
    cmp     al, 0x0E            ; Backspace
    je      .ed_try_bs
    cmp     al, 0x53            ; Delete
    je      .ed_try_del

    ; --- Рух каретки. Коди однакові і для сірих клавіш (префікс
    ;     0xE0), і для цифрової панелі при вимкненому NumLock,
    ;     тому префікс тут не перевіряємо.
    ;
    ; Стрілки тепер рухають КАРЕТКУ, а не екран: екран іде за нею
    ; сам. Раніше стрілки прокручували текст, і потрапити кудись
    ; усередину файлу було нічим.
    cmp     al, 0x48            ; вгору
    je      .ed_up
    cmp     al, 0x50            ; вниз
    je      .ed_down
    cmp     al, 0x4B            ; вліво
    je      .ed_left
    cmp     al, 0x4D            ; вправо
    je      .ed_right
    cmp     al, 0x49            ; PgUp
    je      .ed_pgup
    cmp     al, 0x51            ; PgDn
    je      .ed_pgdn
    cmp     al, 0x47            ; Home - початок рядка
    je      .ed_home
    cmp     al, 0x4F            ; End - кінець рядка
    je      .ed_end

    lea     rbx, [ScanCodes]
    xlatb
    test    al, al
    jz      .editor_loop

    cmp     byte [EdReadOnly], 0    ; перегляд - ввід ігноруємо
    jne     .editor_loop

    cmp     al, 13                  ; Enter
    jne     .ed_do_insert
    mov     al, 10                  ; у буфер кладемо LF, як і GUI-редактор

.ed_do_insert:
    ; Вставка в ДОВІЛЬНЕ місце: хвіст після каретки зсувається
    ; вправо на один байт. Раніше символ просто дописувався в
    ; кінець буфера.
    mov     rbx, [EdLen]
    cmp     rbx, EDITOR_CAP - 2
    jae     .editor_loop

    push    rax
    mov     rcx, [EdLen]
    sub     rcx, [EditorCursor]     ; довжина хвоста
    mov     rsi, EditorBuffer
    add     rsi, [EdLen]
    dec     rsi                     ; останній байт тексту
    mov     rdi, rsi
    inc     rdi                     ; на позицію правіше
    std
    rep     movsb
    cld
    pop     rax

    mov     rbx, EditorBuffer
    add     rbx, [EditorCursor]
    mov     [rbx], al
    inc     qword [EditorCursor]
    inc     qword [EdLen]

    call    EraseCursor
    mov     byte [EdFollow], 1
    call    .ed_render
    jmp     .editor_loop

; ----------------------------------------------------------
; Прокрутка. EdFollow=0 означає "не тягнути екран за кареткою",
; інакше .ed_render одразу поверне нас назад до місця вводу.
; ----------------------------------------------------------
; У режимі перегляду файл не змінюємо: збереження, стирання
; і ввід символів просто ігноруються.
.ed_try_save:
    cmp     byte [EdReadOnly], 0
    jne     .editor_loop
    jmp     .save_editor

.ed_try_bs:
    cmp     byte [EdReadOnly], 0
    jne     .editor_loop
    jmp     .bs_editor

.ed_left:
    cmp     qword [EditorCursor], 0
    je      .editor_loop
    dec     qword [EditorCursor]
    jmp     .ed_moved

.ed_right:
    mov     rax, [EditorCursor]
    cmp     rax, [EdLen]
    jae     .editor_loop
    inc     qword [EditorCursor]
    jmp     .ed_moved

.ed_up:
    call    .ed_caret_up
    jmp     .ed_moved

.ed_down:
    call    .ed_caret_down
    jmp     .ed_moved

.ed_pgup:
    mov     ecx, [EdRows]
    test    ecx, ecx
    jz      .ed_moved
.ed_pu_l:
    push    rcx
    call    .ed_caret_up
    pop     rcx
    dec     ecx
    jnz     .ed_pu_l
    jmp     .ed_moved

.ed_pgdn:
    mov     ecx, [EdRows]
    test    ecx, ecx
    jz      .ed_moved
.ed_pd_l:
    push    rcx
    call    .ed_caret_down
    pop     rcx
    dec     ecx
    jnz     .ed_pd_l
    jmp     .ed_moved

.ed_home:
    mov     rax, [EditorCursor]
    call    .ed_line_start
    mov     [EditorCursor], rax
    jmp     .ed_moved

.ed_end:
    mov     rax, [EditorCursor]
    call    .ed_line_start
    call    .ed_line_end
    mov     [EditorCursor], rax
    jmp     .ed_moved

.ed_moved:
    call    EraseCursor
    mov     byte [EdFollow], 1
    call    .ed_render
    jmp     .editor_loop

.ed_try_del:
    cmp     byte [EdReadOnly], 0
    jne     .editor_loop
    mov     rax, [EditorCursor]
    cmp     rax, [EdLen]
    jae     .editor_loop
    mov     rcx, [EdLen]
    sub     rcx, rax
    dec     rcx                     ; байтів після того, що видаляємо
    mov     rdi, EditorBuffer
    add     rdi, rax
    mov     rsi, rdi
    inc     rsi
    cld
    rep     movsb
    dec     qword [EdLen]
    jmp     .ed_moved

; --- Перехід на рядок за номером (F3) ---
; Саме заради цього в заголовку показується номер рядка: FASM
; повідомляє про помилку рядком, і треба вміти туди дістатись.
.ed_goto_start:
    mov     byte [EdGotoMode], 1
    mov     qword [EdGotoNum], 0
    call    .ed_render
    jmp     .editor_loop

.ed_goto_key:
    cmp     al, 0x01                ; ESC - скасувати
    je      .ed_goto_cancel
    cmp     al, 0x1C                ; Enter - перейти
    je      .ed_goto_apply
    cmp     al, 0x0E                ; Backspace - стерти цифру
    je      .ed_goto_bs

    lea     rbx, [ScanCodes]
    xlatb
    cmp     al, '0'
    jb      .editor_loop
    cmp     al, '9'
    ja      .editor_loop
    sub     al, '0'
    movzx   rbx, al
    mov     rax, [EdGotoNum]
    cmp     rax, 1000000            ; далі номер уже безглуздий
    ja      .editor_loop
    imul    rax, 10
    add     rax, rbx
    mov     [EdGotoNum], rax
    call    .ed_render
    jmp     .editor_loop

.ed_goto_bs:
    mov     rax, [EdGotoNum]
    xor     rdx, rdx
    mov     rcx, 10
    div     rcx
    mov     [EdGotoNum], rax
    call    .ed_render
    jmp     .editor_loop

.ed_goto_cancel:
    mov     byte [EdGotoMode], 0
    call    .ed_render
    jmp     .editor_loop

.ed_goto_apply:
    mov     byte [EdGotoMode], 0
    mov     rcx, [EdGotoNum]
    test    rcx, rcx
    jnz     .ed_go_have
    mov     rcx, 1
.ed_go_have:
    dec     rcx                     ; скільки переносів пропустити
    xor     rax, rax                ; шукаємо з початку файлу
    test    rcx, rcx
    jz      .ed_go_set
    mov     rsi, EditorBuffer
    xor     rax, rax
.ed_go_l:
    cmp     rax, [EdLen]
    jae     .ed_go_set
    cmp     byte [rsi + rax], 10
    jne     .ed_go_next
    dec     rcx
    jz      .ed_go_found
.ed_go_next:
    inc     rax
    jmp     .ed_go_l
.ed_go_found:
    inc     rax                     ; стаємо за перенос
.ed_go_set:
    cmp     rax, [EdLen]
    jbe     .ed_go_ok
    mov     rax, [EdLen]
.ed_go_ok:
    mov     [EditorCursor], rax
    jmp     .ed_moved

; EAX = бажаний EdScroll -> обрізаний так, щоб останній рядок
; лишався видимим (порожній екран нижче тексту нікому не потрібен)
.ed_clamp:
    push    rbx
    mov     ebx, [EdLines]
    sub     ebx, [EdRows]
    inc     ebx
    jns     .ed_cl_have
    xor     ebx, ebx
.ed_cl_have:
    cmp     eax, ebx
    jbe     .ed_cl_done
    mov     eax, ebx
.ed_cl_done:
    pop     rbx
    ret

.bs_editor:
    ; Стирає символ ПЕРЕД кареткою в довільному місці тексту,
    ; підтягуючи хвіст. Раніше просто зменшувалась довжина і в
    ; кінець клався нуль - тобто стерти можна було лише останній
    ; введений символ.
    cmp     qword [EditorCursor], 0
    je      .editor_loop
    call    EraseCursor
    dec     qword [EditorCursor]
    mov     rcx, [EdLen]
    sub     rcx, [EditorCursor]
    dec     rcx                     ; байтів після того, що стираємо
    mov     rdi, EditorBuffer
    add     rdi, [EditorCursor]
    mov     rsi, rdi
    inc     rsi
    cld
    rep     movsb
    dec     qword [EdLen]
    mov     byte [EdFollow], 1
    call    .ed_render
    call    DrawCursor
    jmp     .editor_loop

; ----------------------------------------------------------
; Рух каретки на логічний рядок угору або вниз зі збереженням
; колонки - так, як поводиться будь-який звичний редактор.
; ----------------------------------------------------------
.ed_caret_up:
    push    rax
    push    rbx
    mov     rax, [EditorCursor]
    call    .ed_line_start
    mov     [EdTmp], rax            ; початок поточного рядка
    test    rax, rax
    jz      .cu_done                ; вже перший рядок
    mov     rbx, [EditorCursor]
    sub     rbx, rax
    mov     [EdCol], rbx            ; колонка

    mov     rax, [EdTmp]
    dec     rax                     ; на перенос попереднього рядка
    call    .ed_line_start
    mov     [EdTmp], rax            ; початок попереднього
    call    .ed_line_end               ; RAX був початком -> став кінцем
    mov     rbx, rax
    mov     rax, [EdTmp]
    add     rax, [EdCol]
    cmp     rax, rbx
    jbe     .cu_set
    mov     rax, rbx                ; рядок коротший - стаємо в кінець
.cu_set:
    mov     [EditorCursor], rax
.cu_done:
    pop     rbx
    pop     rax
    ret

.ed_caret_down:
    push    rax
    push    rbx
    mov     rax, [EditorCursor]
    call    .ed_line_start
    mov     [EdTmp], rax
    mov     rbx, [EditorCursor]
    sub     rbx, rax
    mov     [EdCol], rbx

    mov     rax, [EdTmp]
    call    .ed_line_end               ; кінець поточного рядка
    cmp     rax, [EdLen]
    jae     .cd_done                ; це останній рядок
    inc     rax                     ; за перенос - початок наступного
    mov     [EdTmp], rax
    call    .ed_line_end
    mov     rbx, rax
    mov     rax, [EdTmp]
    add     rax, [EdCol]
    cmp     rax, rbx
    jbe     .cd_set
    mov     rax, rbx
.cd_set:
    mov     [EditorCursor], rax
.cd_done:
    pop     rbx
    pop     rax
    ret

.save_editor:
    lea     r8, [ParsedFileName]
    call    SaveFileFAT32
    jnc     .save_ok
    lea     r8, [ParsedFileName]
    call    CreateFileFAT32
    lea     r8, [ParsedFileName]
    call    SaveFileFAT32
    jc      .save_fail
.save_ok:
    mov     rcx, 450
    mov     rdx, 0
    lea     r8,  [MsgSaved]
    mov     r9d, 0x0000FF00
    call    DrawString
    jmp     .editor_loop
.save_fail:
    mov     rcx, 450
    mov     rdx, 0
    lea     r8,  [MsgErrFat]
    mov     r9d, 0x000000FF
    call    DrawString
    jmp     .editor_loop

.exit_editor:
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    jmp     .finish

.run_pci:
    call    ScanPCI
    jmp     .finish

.run_cpuinfo:
    call    CpuInfoCommand
    jmp     .finish

.run_netinit:
    call    NetInitCommand
    jmp     .finish

.run_nettest:
    call    NetTestCommand
    jmp     .finish

.run_ping:
    call    PingCommand
    jmp     .finish

.run_pingname:
    call    PingNameCommand
    jmp     .finish

.run_nslookup:
    call    NsLookupCommand
    jmp     .finish

.run_httpget:
    call    HttpGetCommand
    jmp     .finish

.run_tcp:
    call    TcpCommand
    jmp     .finish

.run_setdns:
    call    SetDnsCommand
    jmp     .finish

.run_copy:
    call    CopyCommand
    jmp     .finish

.run_install:
    call    InstallCommand
    jmp     .finish

.run_dhcp:
    call    DhcpCommand
    jmp     .finish

.run_ipconfig:
    call    IpconfigCommand
    jmp     .finish

.finish:
    mov     qword [BufferLen], 0        
    call    PrintPrompt                 
    ret

; ==========================================================
; 4. СИСТЕМНІ УТИЛІТИ 
; ==========================================================
PrintPrompt:
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    lea     r8,  [CurrentPath]
    mov     r9d, COL_TEXT               ; у DOS промпт того ж кольору, що й текст
    call    DrawString
    
    lea     rsi, [CurrentPath]
    xor     rax, rax
.len_loop:
    cmp     byte [rsi+rax], 0
    je      .len_done
    inc     rax
    jmp     .len_loop
.len_done:
    imul    rax, 9
    add     qword [CursorX], rax        
    
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r8,  '>'
    mov     r9d, COL_TEXT
    call    DrawChar_Safe
    add     qword [CursorX], 9          ; у DOS після '>' один пробіл
    
    call    DrawCursor                  
    ret

AppendPath:
    lea     rdi, [CurrentPath]
.find_end:
    cmp     byte [rdi], 0
    je      .copy_name
    inc     rdi
    jmp     .find_end
.copy_name:
    mov     al, [rsi]
    test    al, al
    jz      .add_slash
    cmp     al, ' '
    je      .add_slash
    cmp     al, 'a'
    jb      .store
    cmp     al, 'z'
    ja      .store
    sub     al, 32
.store:
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     .copy_name
.add_slash:
    mov     word [rdi], 0x002F          
    ret

RemoveLastPath:
    lea     rdi, [CurrentPath]
.find_end_rm:
    cmp     byte [rdi], 0
    je      .found_end
    inc     rdi
    jmp     .find_end_rm
.found_end:
    dec     rdi                         
    lea     rbx, [CurrentPath + 5]      
    cmp     rdi, rbx
    jle     .done                       

    dec     rdi                         
.scan_back:
    cmp     rdi, rbx
    jle     .set_root
    cmp     byte [rdi], '/'             
    je      .cut
    dec     rdi
    jmp     .scan_back
.set_root:
    lea     rdi, [CurrentPath + 4]      
.cut:
    inc     rdi
    mov     byte [rdi], 0               
.done:
    ret

NewLine:
    ; ВИПРАВЛЕНО: зберігаємо RAX/R10
    push    rax
    push    r10
    mov     qword [CursorX], 20         
    mov     rax, [CursorY]
    add     rax, 20                     
    movsxd  r10, dword [ScreenHeight]
    sub     r10, 20                     
    cmp     rax, r10
    jge     .scroll_needed
    mov     [CursorY], rax              
    pop     r10
    pop     rax
    ret
.scroll_needed:
    call    ScrollScreen                
    pop     r10
    pop     rax
    ret

; StrCmp - порівняння БЕЗ урахування регістру.
;
; Відколи таблиця скан-кодів віддає малі літери (щоб можна було
; друкувати текст змішаним регістром), команда 'help' не збігалася
; з рядком 'HELP' у коді. Піднімати регістр у таблиці не можна -
; тоді зникнуть малі літери. Тому регістр ігнорується саме тут,
; як це й робив MS-DOS.
StrCmp:
    push    rsi
    push    rdi
    push    rbx
.loop:
    mov     al, [rsi]
    mov     bl, [rdi]
    ; обидва символи до верхнього регістру перед порівнянням
    cmp     al, 'a'
    jb      .a_ok
    cmp     al, 'z'
    ja      .a_ok
    sub     al, 32
.a_ok:
    cmp     bl, 'a'
    jb      .b_ok
    cmp     bl, 'z'
    ja      .b_ok
    sub     bl, 32
.b_ok:
    cmp     al, bl
    jne     .ne
    test    al, al
    jz      .eq
    inc     rsi
    inc     rdi
    jmp     .loop
.ne:
    pop     rbx
    pop     rdi
    pop     rsi
    mov     rax, 1
    ret
.eq:
    pop     rbx
    pop     rdi
    pop     rsi
    xor     rax, rax
    ret

; StrPrefix - перевірка префікса, теж без урахування регістру.
StrPrefix:
    push    rsi
    push    rdi
    push    rbx
.loop:
    mov     bl, [rdi]
    test    bl, bl
    jz      .match
    mov     al, [rsi]
    cmp     al, 'a'
    jb      .pa_ok
    cmp     al, 'z'
    ja      .pa_ok
    sub     al, 32
.pa_ok:
    cmp     bl, 'a'
    jb      .pb_ok
    cmp     bl, 'z'
    ja      .pb_ok
    sub     bl, 32
.pb_ok:
    cmp     al, bl
    jne     .ne
    inc     rsi
    inc     rdi
    jmp     .loop
.match:
    pop     rbx
    pop     rdi
    pop     rsi
    xor     rax, rax
    ret
.ne:
    pop     rbx
    pop     rdi
    pop     rsi
    mov     rax, 1
    ret

FormatFAT32Name:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     rdx, rdi            
    mov     rcx, 11
    mov     al, ' '
    cld
    rep stosb                   
    
    mov     rdi, rdx            
    mov     rcx, 8              
.copy_n:
    lodsb
    test    al, al
    jz      .done
    cmp     al, ' '             ; пробіл = кінець імені (початок 2-го аргументу)
    je      .done
    cmp     al, '.'
    je      .do_ext
    cmp     al, 'a'
    jb      .st_n
    cmp     al, 'z'
    ja      .st_n
    sub     al, 32
.st_n:
    stosb
    loop    .copy_n
.skip:
    lodsb
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .done
    cmp     al, '.'
    jne     .skip
.do_ext:
    mov     rdi, rdx
    add     rdi, 8              
    mov     rcx, 3
.copy_e:
    lodsb
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .done
    cmp     al, 'a'
    jb      .st_e
    cmp     al, 'z'
    ja      .st_e
    sub     al, 32
.st_e:
    stosb
    loop    .copy_e
.done:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

CheckKeyboard:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    r8
    push    r9
.poll_loop:
    in      al, 0x64
    test    al, 1               ; Чи є дані в буфері?
    jz      .exit
    
    test    al, 0x20            ; Біт 5 == 1 означає, що це дані від МИШІ!
    jnz     .handle_mouse

.handle_kbd:
    in      al, 0x60            ; Читаємо скан-код клавіатури

    ; --- Модифікатори відстежуємо окремо: і натискання, і відпускання ---
    ; Без цього неможливо давати малі й великі літери, а Ctrl/Alt
    ; взагалі не існують для програм.
    mov     ah, al
    and     ah, 0x7F            ; код без біта відпускання
    cmp     ah, 0x2A            ; лівий Shift
    je      .kbd_mod_shift
    cmp     ah, 0x36            ; правий Shift
    je      .kbd_mod_shift
    cmp     ah, 0x1D            ; Ctrl
    je      .kbd_mod_ctrl
    cmp     ah, 0x38            ; Alt
    je      .kbd_mod_alt
    cmp     ah, 0x3A            ; CapsLock
    je      .kbd_mod_caps
    jmp     .kbd_not_mod

.kbd_mod_shift:
    test    al, 0x80
    jnz     .kbd_shift_up
    or      byte [KbdMods], 1
    jmp     .poll_loop
.kbd_shift_up:
    and     byte [KbdMods], 0xFE
    jmp     .poll_loop
.kbd_mod_ctrl:
    test    al, 0x80
    jnz     .kbd_ctrl_up
    or      byte [KbdMods], 2
    jmp     .poll_loop
.kbd_ctrl_up:
    and     byte [KbdMods], 0xFD
    jmp     .poll_loop
.kbd_mod_alt:
    test    al, 0x80
    jnz     .kbd_alt_up
    or      byte [KbdMods], 4
    jmp     .poll_loop
.kbd_alt_up:
    and     byte [KbdMods], 0xFB
    jmp     .poll_loop
.kbd_mod_caps:
    test    al, 0x80            ; перемикаємо лише при натисканні
    jnz     .poll_loop
    xor     byte [KbdMods], 8
    jmp     .poll_loop

.kbd_not_mod:
    cmp     byte [AppRunning], 1
    jne     .check_release      

    ; --- Аварійний вихід із програми ---
    ;
    ; Поки програма працює, кожен скан-код іде просто в чергу для
    ; неї, а ядро чекає, доки вона сама скаже, що завершилась. Якщо
    ; програма цього не робить - а DOOM саме такий, його меню виходу
    ; до ядра не доходить - вийти можна було лише скиданням машини.
    ;
    ; Тому одна комбінація перехоплюється ядром і в чергу НЕ
    ; потрапляє. Яка саме - див. KILL_KEY на початку файлу.
    cmp     al, KILL_KEY                ; саме натискання, не відпускання
    jne     .kbd_to_app
    mov     ah, [KbdMods]
    and     ah, KILL_MODS
    cmp     ah, KILL_MODS
    jne     .kbd_to_app

    ; Те саме, що робить звичайний вихід програми, але без
    ; перемикання контексту: ми вже в задачі ядра.
    mov     byte [MouseOwnedByApp], 0
    mov     rbx, [AppTask]
    test    rbx, rbx
    jz      .kill_hk_console
    call    KeysReleaseFor              ; черга клавіш більше не її
    mov     byte [TaskState + rbx], 0
    mov     rcx, [TaskCR3 + rbx*8]
    mov     [PendingFree], rcx
    mov     rcx, [PagePml4]
    mov     [TaskCR3 + rbx*8], rcx

    ; Якщо у вбитої задачі був батько, що спить на syscall 37 -
    ; будимо його. Без цього оболонка, яка запустила гру, лишалася б
    ; спати назавжди, і рятувало б лише перезавантаження машини.
    mov     rcx, [TaskParent + rbx*8]
    mov     qword [TaskParent + rbx*8], 0
    test    rcx, rcx
    jz      .kill_hk_console
    mov     byte [TaskState + rcx], 1
    mov     [AppTask], rcx          ; тепер поточна програма - батько
    jmp     .poll_loop              ; AppRunning лишається: програми ще є

.kill_hk_console:
    mov     byte [AppRunning], 0
    mov     qword [CurrentTask], 0
    jmp     .poll_loop

.kbd_to_app:

    ; --- ФІКС ДЛЯ DOOM (Запис у FIFO чергу) ---
    movzx   ebx, byte [KbdHead]
    mov     [KbdBuffer + ebx], al
    inc     bl
    mov     [KbdHead], bl
    jmp     .poll_loop          ; Читаємо порт далі, щоб нічого не пропустити

.check_release:
    test    al, 0x80            
    jnz     .poll_loop

.normal_kbd:
    cmp     al, 0x1C    
    je      .enter
    cmp     al, 0x0E            
    je      .bs
    lea     rbx, [ScanCodes]    
    xlatb                       
    test    al, al
    jz      .poll_loop               
    mov     rbx, [BufferLen]
    cmp     rbx, 60             
    jge     .poll_loop
    call    EraseCursor
    mov     [CmdBuffer + rbx], al
    inc     qword [BufferLen]
    movzx   r8, al
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r9d, 0x00FFFFFF
    call    DrawChar_Safe
    add     qword [CursorX], 9  
    call    DrawCursor
    jmp     .poll_loop
.bs:                            
    cmp     qword [BufferLen], 0
    je      .poll_loop               
    call    EraseCursor
    dec     qword [BufferLen]
    sub     qword [CursorX], 9  
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    call    EraseChar           
    call    DrawCursor
    jmp     .poll_loop
.enter:
    call    EraseCursor
    call    ExecuteCommand      
    jmp     .poll_loop

.handle_mouse:
    in      al, 0x60            ; Читаємо байт пакета миші
    movzx   ebx, byte [MouseState]
    ; ДОДАНО: перший байт пакета зобов'язаний мати біт 3.
    ; Якщо це не так - фаза збита, чекаємо на справжній початок пакета.
    test    ebx, ebx
    jnz     .mp_store
    test    al, 0x08
    jnz     .mp_store
    jmp     .poll_loop
.mp_store:
    mov     [MousePacket + ebx], al
    inc     bl
    cmp     bl, [MousePacketLen]    ; 3 або 4 - залежить від типу миші
    jne     .save_m_state

    ; --- Зібрали повний пакет! ---
    xor     bl, bl              ; Скидаємо стан для наступного пакета

    ; 1. ЧИТАЄМО КЛІКИ
    mov     al, [MousePacket]
    and     al, 3               ; Виділяємо нижні 2 біти (0=нічого, 1=ліва, 2=права)
    mov     [MouseClick], al

    ; 1b. КОЛЕСО ПРОКРУТКИ (лише якщо миша в режимі IntelliMouse)
    cmp     byte [MousePacketLen], 4
    jne     .no_wheel_data
    mov     al, [MousePacket + 3]
    and     al, 0x0F            ; ось Z - знакове 4-бітне число (-8..7)
    cmp     al, 8
    jb      .wheel_positive
    or      al, 0xF0            ; розширюємо знак на весь байт
.wheel_positive:
    movsx   ecx, al
    movsx   edx, byte [MouseWheel]
    add     edx, ecx
    cmp     edx, 100            ; обмежуємо накопичувач, щоб не переповнився,
    jle     .wheel_lo           ; якщо програма довго його не читає
    mov     edx, 100
.wheel_lo:
    cmp     edx, -100
    jge     .wheel_store
    mov     edx, -100
.wheel_store:
    mov     [MouseWheel], dl
.no_wheel_data:

    ; Курсор миші ядро БІЛЬШЕ НЕ МАЛЮЄ.
    ;
    ; Він був тимчасовим - щоб перевірити, що миша взагалі працює.
    ; Тепер курсор малює графічна оболонка у власному буфері, а два
    ; малювальники в один фреймбуфер неминуче конфліктували: ядро
    ; запам'ятовувало фон, у якому вже був курсор програми, і потім
    ; "відновлювало" його в старому місці - екран засівався стрілками.
    ;
    ; Ядро й далі відстежує координати та кнопки і віддає їх через
    ; syscall 11 - саме це від нього й потрібно.

    ; 3. ОНОВЛЮЄМО КООРДИНАТИ X
    movsx   ecx, byte [MousePacket + 1]  
    mov     edx, [MouseX]
    add     edx, ecx
    cmp     edx, 0
    jge     .x_ok
    xor     edx, edx
.x_ok:
    mov     eax, [ScreenWidth]
    sub     eax, 5              ; Віднімаємо розмір курсору
    cmp     edx, eax
    jl      .x_set
    mov     edx, eax
.x_set:
    mov     [MouseX], edx

    ; 4. ОНОВЛЮЄМО КООРДИНАТИ Y (у PS/2 він інвертований)
    movsx   ecx, byte [MousePacket + 2]  
    mov     edx, [MouseY]
    sub     edx, ecx
    cmp     edx, 0
    jge     .y_ok
    xor     edx, edx
.y_ok:
    mov     eax, [ScreenHeight]
    sub     eax, 5
    cmp     edx, eax
    jl      .y_set
    mov     edx, eax
.y_set:
    mov     [MouseY], edx

    ; Координати оновлено; малювання - справа оболонки.
    
.save_m_state:
    mov     [MouseState], bl
    jmp     .poll_loop

.exit:
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

InitMouse:
    push    rax
    push    rbx

    ; --- 1. Очищаємо буфер від старого сміття ---
.flush:
    in      al, 0x64
    test    al, 1
    jz      .done_flush
    in      al, 0x60
    jmp     .flush
.done_flush:

    ; --- 2. Налаштування миші ---
    mov     al, 0xA8            ; Дозволяємо AUX пристрій (мишу)
    out     0x64, al

    mov     al, 0x20            
    out     0x64, al
    call    WaitKbdOut
    in      al, 0x60
    or      al, 2               ; Вмикаємо переривання миші
    and     al, 0xDF            ; ФІКС: Примусово знімаємо біт "Disable Mouse"!
    mov     bl, al

    mov     al, 0x60            
    out     0x64, al
    call    WaitKbdIn
    mov     al, bl
    out     0x60, al

    mov     al, 0xF6            ; Встановлюємо дефолтні налаштування
    call    MouseWrite

    ; --- Спроба перевести мишу в режим IntelliMouse (з колесом) ---
    ; Магічна послідовність зі специфікації: три Set Sample Rate
    ; поспіль зі значеннями 200, 100, 80. Після неї миша, яка вміє
    ; колесо, змінює свій ID з 0 на 3 і починає слати 4-байтні пакети.
    mov     al, 0xF3
    call    MouseWrite
    mov     al, 200
    call    MouseWrite
    mov     al, 0xF3
    call    MouseWrite
    mov     al, 100
    call    MouseWrite
    mov     al, 0xF3
    call    MouseWrite
    mov     al, 80
    call    MouseWrite

    ; Запитуємо ID пристрою (0xF2)
    mov     al, 0xF2
    call    MouseWrite          ; MouseWrite вже зчитав ACK
    call    WaitKbdOut
    in      al, 0x60            ; сам ID: 0 = звичайна, 3 = з колесом
    cmp     al, 3
    jne     .no_wheel
    mov     byte [MousePacketLen], 4    ; перемикаємось на 4-байтні пакети
.no_wheel:

    ; Розумна частота опитування - 100 пакетів/сек
    mov     al, 0xF3
    call    MouseWrite
    mov     al, 100
    call    MouseWrite

    mov     al, 0xF4            ; Вмикаємо передачу даних пакетів
    call    MouseWrite

    mov     byte [MouseState], 0    ; на всяк випадок скидаємо лічильник байт

    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; MouseWrite - надіслати байт AL мишці і зчитати ACK.
; Замінює повторюваний блок 0xD4 / WaitKbdIn / out / WaitKbdOut / in.
; ----------------------------------------------------------
MouseWrite:
    push    rbx
    mov     bl, al              ; зберігаємо байт, який шлемо
    mov     al, 0xD4            ; наступний байт - для AUX-пристрою
    out     0x64, al
    call    WaitKbdIn
    mov     al, bl
    out     0x60, al
    call    WaitKbdOut
    in      al, 0x60            ; ACK (0xFA)
    pop     rbx
    ret

WaitKbdIn:
    in      al, 0x64
    test    al, 2
    jnz     WaitKbdIn
    ret

WaitKbdOut:
    in      al, 0x64
    test    al, 1
    jz      WaitKbdOut
    ret
GetRTC:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    lea     rdi, [TimeStr]
    mov     al, 4               
    call    ReadRTC
    call    FormatBCD
    mov     [rdi], ax
    mov     al, 2               
    call    ReadRTC
    call    FormatBCD
    mov     [rdi + 3], ax
    mov     al, 0               
    call    ReadRTC
    call    FormatBCD
    mov     [rdi + 6], ax
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

ReadRTC:
    out     0x70, al
    in      al, 0x71
    ret

FormatBCD:
    mov     ah, al
    shr     ah, 4
    and     al, 0x0F
    add     ah, '0'
    add     al, '0'
    xchg    al, ah              
    ret

; ------------------------------------------------------------
; FatNow - поточні дата й час у тому вигляді, у якому їх тримає
; запис каталогу FAT.
;   AX = дата: (рік - 1980) << 9 | місяць << 5 | день
;   DX = час:  години << 11 | хвилини << 5 | секунди / 2
;
; Годинник у CMOS віддає BCD, тому кожне число доводиться переводити.
; Перед читанням чекаємо, поки зникне прапорець оновлення (регістр
; 0x0A, біт 7): напівоновлений час, на відміну від показань на
; екрані, залишиться на диску назавжди.
;
; Рік CMOS дає двома цифрами, тому вважаємо його за 20xx. Для машини,
; на якій ця система взагалі здатна завантажитись, це безпечно.
; ------------------------------------------------------------
FatNow:
    push    rbx
    push    rcx
.fn_wait:
    mov     al, 0x0A
    out     0x70, al
    in      al, 0x71
    test    al, 0x80
    jnz     .fn_wait

    ; --- дата ---
    mov     al, 0x09                ; рік, дві цифри
    call    ReadRTC
    call    BcdToBin
    movzx   ebx, al
    add     ebx, 2000 - 1980
    shl     ebx, 9

    mov     al, 0x08                ; місяць
    call    ReadRTC
    call    BcdToBin
    movzx   ecx, al
    shl     ecx, 5
    or      ebx, ecx

    mov     al, 0x07                ; день
    call    ReadRTC
    call    BcdToBin
    movzx   ecx, al
    or      ebx, ecx
    push    rbx                     ; дата готова, місце під неї - стек

    ; --- час ---
    mov     al, 0x04                ; години
    call    ReadRTC
    call    BcdToBin
    movzx   ebx, al
    shl     ebx, 11

    mov     al, 0x02                ; хвилини
    call    ReadRTC
    call    BcdToBin
    movzx   ecx, al
    shl     ecx, 5
    or      ebx, ecx

    mov     al, 0x00                ; секунди; у FAT крок дві секунди
    call    ReadRTC
    call    BcdToBin
    movzx   ecx, al
    shr     ecx, 1
    or      ebx, ecx

    mov     edx, ebx                ; DX = час
    pop     rax                     ; AX = дата
    pop     rcx
    pop     rbx
    ret

; BcdToBin - AL із BCD у звичайне число. Псує лише AX.
BcdToBin:
    push    rcx
    mov     cl, al
    shr     al, 4
    and     al, 0x0F
    mov     ah, 10
    mul     ah                      ; AX = старша цифра * 10
    and     cl, 0x0F
    add     al, cl
    pop     rcx
    ret

PlaySound:
    push    rax
    push    rcx
    push    rdx
    mov     rcx, rax
    mov     rax, 1193180
    xor     rdx, rdx
    div     rcx                 
    mov     rcx, rax
    mov     al, 0xB6            
    out     0x43, al
    mov     al, cl              
    out     0x42, al
    mov     al, ch              
    out     0x42, al
    in      al, 0x61            
    or      al, 3
    out     0x61, al
    pop     rdx
    pop     rcx
    pop     rax
    ret

StopSound:
    push    rax
    in      al, 0x61
    and     al, 0xFC            
    out     0x61, al
    pop     rax
    ret

BeepDelay:
    push    rcx
    mov     rcx, 0x07FFFFFF     
.loop_d:
    dec     rcx
    jnz     .loop_d
    pop     rcx
    ret

; ==========================================================
; 13. МЕНЕДЖЕР ДИНАМІЧНОЇ ПАМ'ЯТІ (HEAP)
; ==========================================================
InitHeap:
    mov     rax, HeapBase
    mov     qword [rax], HeapSize - 24  
    mov     qword [rax + 8], 0          
    mov     qword [rax + 16], 0         
    ret

kmalloc:
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    
    add     rcx, 7
    and     rcx, 0xFFFFFFFFFFFFFFF8
    mov     rax, HeapBase
.find_block:
    test    rax, rax
    jz      .out_of_memory      

    cmp     qword [rax + 16], 0         
    jne     .next_block
    cmp     qword [rax], rcx            
    jb      .next_block

    mov     rbx, qword [rax]            
    sub     rbx, rcx                    
    cmp     rbx, 32                     
    jl      .take_whole_block

    mov     qword [rax], rcx            
    
    lea     rdi, [rax + 24 + rcx]       
    sub     rbx, 24                     
    mov     qword [rdi], rbx            
    mov     rdx, qword [rax + 8]        
    mov     qword [rdi + 8], rdx        
    mov     qword [rdi + 16], 0         
    mov     qword [rax + 8], rdi        

.take_whole_block:
    mov     qword [rax + 16], 1         
    add     rax, 24                     
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

.next_block:
    mov     rax, qword [rax + 8]        
    jmp     .find_block

.out_of_memory:
    xor     rax, rax                    
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

kfree:
    test    rcx, rcx
    jz      .done                       
    sub     rcx, 24                     
    mov     qword [rcx + 16], 0         
.done:
    ret

; ==========================================================
; 5. ФАЙЛОВА СИСТЕМА (FAT32 & VFS)
; ==========================================================
InitFAT32:
    ; ДОПОВНЕНО: тепер зберігаємо ще NumFATs, SectorsPerFAT і TotalClusters —
    ; без них не можна ні адресувати FAT далі першого сектора, ні
    ; підтримувати копії FAT в узгодженому стані.
    xor     eax, eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    ; Якщо сектор 0 — це вже VBR (починається з JMP), розділу немає
    mov     al, byte [SectorBuffer]
    cmp     al, 0xEB
    je      .no_mbr
    cmp     al, 0xE9
    je      .no_mbr
    mov     eax, dword [SectorBuffer + 0x1BE + 8]
    jmp     .have_vs
.no_mbr:
    xor     eax, eax
.have_vs:
    mov     [VolumeStartLBA], eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA

    movzx   ebx, word [SectorBuffer + 0x0E]      ; ReservedSectors
    movzx   ecx, byte [SectorBuffer + 0x10]      ; NumFATs
    mov     [NumFATs], cl
    mov     edx, dword [SectorBuffer + 0x24]     ; SectorsPerFAT32
    mov     [SectorsPerFAT], edx
    mov     al, byte [SectorBuffer + 0x0D]
    mov     [SectorsPerCluster], al

    mov     eax, ebx
    add     eax, [VolumeStartLBA]
    mov     [FAT1LBA], eax                      ; FAT1 = VolumeStart + Reserved

    imul    edx, ecx                            ; NumFATs * SectorsPerFAT
    mov     esi, ebx
    add     esi, edx                            ; Reserved + усі FAT
    mov     eax, esi
    add     eax, [VolumeStartLBA]
    mov     [DataRegionLBA], eax

    ; TotalClusters = (TotalSectors - Reserved - усі FAT) / SPC + 2
    mov     eax, dword [SectorBuffer + 0x20]    ; TotSec32
    test    eax, eax
    jnz     .have_total
    movzx   eax, word [SectorBuffer + 0x13]     ; TotSec16
.have_total:
    sub     eax, esi
    xor     edx, edx
    movzx   ecx, byte [SectorsPerCluster]
    test    ecx, ecx
    jnz     .spc_ok
    mov     ecx, 1
.spc_ok:
    div     ecx
    add     eax, 2
    mov     [TotalClusters], eax

    mov     eax, dword [SectorBuffer + 0x2C]
    mov     [RootCluster], eax
    mov     [CurrentDirCluster], eax

    ; скидаємо кеш FAT
    mov     dword [FatCacheLBA], 0
    mov     byte [FatCacheDirty], 0
    mov     dword [AllocHint], 2
    ret

; ==========================================================
; НОВИЙ ШАР FAT32 — див. коментар над FatWriteFile
; ==========================================================

; EAX = кластер -> EAX = LBA першого сектора цього кластера
ClusterToLBA:
    push    rcx
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    pop     rcx
    ret

; Скидає кешований сектор FAT на диск у ВСІ копії таблиці.
; Якщо писати лише в першу копію, chkdsk вважає том пошкодженим.
FatFlush:
    cmp     byte [FatCacheDirty], 0
    je      .ff_done
    cmp     dword [FatCacheLBA], 0
    je      .ff_done
    push    rax
    push    rcx
    push    rdx
    push    rdi
    xor     ecx, ecx
.ff_loop:
    mov     eax, [SectorsPerFAT]
    imul    eax, ecx
    add     eax, [FatCacheLBA]
    lea     rdi, [FatCacheBuf]
    push    rcx
    call    WriteSectorATA
    pop     rcx
    inc     ecx
    movzx   edx, byte [NumFATs]
    test    edx, edx
    jnz     .ff_n_ok
    mov     edx, 1
.ff_n_ok:
    cmp     ecx, edx
    jb      .ff_loop
    mov     byte [FatCacheDirty], 0
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
.ff_done:
    ret

; EAX = LBA сектора FAT, який треба мати в кеші
FatLoadSector:
    cmp     eax, [FatCacheLBA]
    je      .fls_done
    push    rax
    call    FatFlush
    pop     rax
    push    rdi
    mov     [FatCacheLBA], eax
    lea     rdi, [FatCacheBuf]
    call    ReadSectorATA
    pop     rdi
.fls_done:
    ret

; EAX = кластер -> EAX = значення FAT (0x0FFFFFFF якщо поза межами)
FatGetEntry:
    push    rbx
    push    rcx
    cmp     eax, 2
    jb      .fge_bad
    cmp     eax, [TotalClusters]
    jae     .fge_bad
    mov     ebx, eax
    shl     ebx, 2
    and     ebx, 511                ; зміщення всередині сектора
    shr     eax, 7                  ; номер сектора = cl*4/512 = cl/128
    add     eax, [FAT1LBA]
    call    FatLoadSector
    lea     rcx, [FatCacheBuf]
    mov     eax, dword [rcx + rbx]
    and     eax, 0x0FFFFFFF
    pop     rcx
    pop     rbx
    ret
.fge_bad:
    mov     eax, 0x0FFFFFFF
    pop     rcx
    pop     rbx
    ret

; EAX = кластер, EDX = нове значення
FatSetEntry:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    cmp     eax, 2
    jb      .fse_done
    cmp     eax, [TotalClusters]
    jae     .fse_done
    mov     ebx, eax
    shl     ebx, 2
    and     ebx, 511
    shr     eax, 7
    add     eax, [FAT1LBA]
    call    FatLoadSector
    lea     rcx, [FatCacheBuf]
    mov     eax, dword [rcx + rbx]
    and     eax, 0xF0000000         ; верхні 4 біти зарезервовані спекою
    and     edx, 0x0FFFFFFF
    or      eax, edx
    mov     dword [rcx + rbx], eax
    mov     byte [FatCacheDirty], 1
.fse_done:
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; Виділяє вільний кластер, позначає його EOC.
; -> EAX = кластер, CF=0. Якщо місця немає: EAX=0, CF=1.
ChainAlloc:
    push    rbx
    push    rcx
    push    rdx
    mov     ebx, [AllocHint]
    cmp     ebx, 2
    jae     .ca_p
    mov     ebx, 2
.ca_p:
    xor     ecx, ecx
.ca_scan:
    cmp     ebx, [TotalClusters]
    jae     .ca_next_pass
    mov     eax, ebx
    call    FatGetEntry
    test    eax, eax
    jz      .ca_found
    inc     ebx
    jmp     .ca_scan
.ca_next_pass:
    inc     ecx
    cmp     ecx, 2
    jae     .ca_full
    mov     ebx, 2                  ; другий прохід — з початку таблиці
    jmp     .ca_scan
.ca_found:
    mov     eax, ebx
    mov     edx, 0x0FFFFFFF
    call    FatSetEntry
    mov     eax, ebx
    inc     eax
    mov     [AllocHint], eax
    mov     eax, ebx
    clc
    pop     rdx
    pop     rcx
    pop     rbx
    ret
.ca_full:
    xor     eax, eax
    stc
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; EAX = кластер — обнуляє його на диску (обов'язково для директорій)
ClusterZero:
    push    rax
    push    rcx
    push    rdi
    push    r10
    push    r11
    call    ClusterToLBA
    mov     r10d, eax
    movzx   r11d, byte [SectorsPerCluster]
    lea     rdi, [IoScratch]
    mov     rcx, 512
    xor     al, al
    cld
    rep     stosb
.cz_loop:
    test    r11d, r11d
    jz      .cz_done
    mov     eax, r10d
    lea     rdi, [IoScratch]
    call    WriteSectorATA
    inc     r10d
    dec     r11d
    jmp     .cz_loop
.cz_done:
    pop     r11
    pop     r10
    pop     rdi
    pop     rcx
    pop     rax
    ret

; EAX = початок ланцюга — звільняє весь ланцюг
ChainFree:
    push    rax
    push    rdx
    push    r10
    push    r11
    mov     r10d, eax
    xor     r11d, r11d
.cf_loop:
    cmp     r10d, 2
    jb      .cf_done
    cmp     r10d, 0x0FFFFFF8
    jae     .cf_done
    cmp     r10d, [TotalClusters]
    jae     .cf_done
    mov     eax, r10d
    call    FatGetEntry             ; EAX = наступний
    push    rax
    mov     eax, r10d
    xor     edx, edx
    call    FatSetEntry             ; звільняємо поточний
    mov     eax, r10d
    cmp     eax, [AllocHint]
    jae     .cf_no_hint
    mov     [AllocHint], eax
.cf_no_hint:
    pop     rax
    mov     r10d, eax
    inc     r11d
    cmp     r11d, 0x100000          ; захист від зациклення на битій FAT
    jb      .cf_loop
.cf_done:
    call    FatFlush
    pop     r11
    pop     r10
    pop     rdx
    pop     rax
    ret

; EAX = початок ланцюга (0 = ще немає), ECX = скільки кластерів треба.
; -> EAX = новий початок ланцюга, CF=0. При браку місця: EAX=0, CF=1,
;    причому все, що встигли виділити, ВЖЕ звільнено (інакше кластери
;    витікали б назавжди).
ChainResize:
    push    rbx
    push    rcx
    push    rdx
    push    r10
    push    r11
    push    r12
    mov     r10d, eax               ; початок
    mov     r11d, ecx               ; потрібно кластерів

    test    r11d, r11d
    jnz     .cr_need
    test    r10d, r10d
    jz      .cr_zero_ok
    mov     eax, r10d
    call    ChainFree
.cr_zero_ok:
    xor     eax, eax
    clc
    jmp     .cr_exit

.cr_need:
    test    r10d, r10d
    jnz     .cr_have_start
    call    ChainAlloc
    jc      .cr_fail_nostart
    mov     r10d, eax
.cr_have_start:
    mov     ebx, r10d               ; поточний кластер
    mov     ecx, 1                  ; скільки вже маємо
.cr_grow:
    cmp     ecx, r11d
    jae     .cr_trim
    mov     eax, ebx
    call    FatGetEntry
    cmp     eax, 2
    jb      .cr_alloc
    cmp     eax, 0x0FFFFFF8
    jae     .cr_alloc
    cmp     eax, [TotalClusters]
    jb      .cr_next
.cr_alloc:
    push    rbx
    call    ChainAlloc
    pop     rbx
    jc      .cr_fail_rollback
    push    rax
    mov     edx, eax
    mov     eax, ebx
    call    FatSetEntry             ; ebx -> новий
    pop     rax
.cr_next:
    mov     ebx, eax
    inc     ecx
    jmp     .cr_grow

.cr_trim:
    mov     eax, ebx
    call    FatGetEntry
    mov     r12d, eax               ; зайвий хвіст
    mov     eax, ebx
    mov     edx, 0x0FFFFFFF
    call    FatSetEntry             ; тут ланцюг закінчується
    cmp     r12d, 2
    jb      .cr_ok
    cmp     r12d, 0x0FFFFFF8
    jae     .cr_ok
    cmp     r12d, [TotalClusters]
    jae     .cr_ok
    mov     eax, r12d
    call    ChainFree
.cr_ok:
    call    FatFlush
    mov     eax, r10d
    clc
    jmp     .cr_exit

.cr_fail_rollback:
    mov     eax, ebx
    mov     edx, 0x0FFFFFFF
    call    FatSetEntry
    mov     eax, r10d
    call    ChainFree
.cr_fail_nostart:
    call    FatFlush
    xor     eax, eax
    stc
.cr_exit:
    pop     r12
    pop     r11
    pop     r10
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; Обхід УСЬОГО ланцюга директорії (раніше дивився лише перший сектор).
; EAX = кластер директорії, R8 = 11-байтне ім'я, DL = режим
;   DL=0 — шукати ім'я, DL=1 — шукати вільний слот
; -> CF=0 + [DirEntrySector], [DirEntryOffset], сектор у SectorBuffer
DirScan:
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12
    push    r13
    mov     r13b, dl
    mov     r10d, eax
    xor     r12d, r12d
.ds_cluster:
    cmp     r10d, 2
    jb      .ds_notfound
    cmp     r10d, 0x0FFFFFF8
    jae     .ds_notfound
    cmp     r10d, [TotalClusters]
    jae     .ds_notfound
    mov     eax, r10d
    call    ClusterToLBA
    mov     r11d, eax
    movzx   ecx, byte [SectorsPerCluster]
.ds_sector:
    push    rcx
    mov     eax, r11d
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    xor     ebx, ebx
.ds_entry:
    lea     rsi, [SectorBuffer]
    add     rsi, rbx
    mov     al, [rsi]
    test    r13b, r13b
    jz      .ds_find
    ; --- режим 1: вільний слот ---
    test    al, al
    jz      .ds_hit
    cmp     al, 0xE5
    je      .ds_hit
    jmp     .ds_next_entry
.ds_find:
    ; --- режим 0: пошук імені ---
    test    al, al
    jz      .ds_notfound_pop
    cmp     al, 0xE5
    je      .ds_next_entry
    cmp     byte [rsi + 11], 0x0F   ; довге ім'я (LFN) — пропускаємо
    je      .ds_next_entry
    push    rcx
    push    rsi
    mov     rdi, r8
    mov     rcx, 11
    cld
    repe    cmpsb
    pop     rsi
    pop     rcx
    je      .ds_hit
.ds_next_entry:
    add     ebx, 32
    cmp     ebx, 512
    jb      .ds_entry
    pop     rcx
    inc     r11d
    dec     ecx
    jnz     .ds_sector
    mov     eax, r10d
    call    FatGetEntry
    mov     r10d, eax
    inc     r12d
    cmp     r12d, 65536
    jb      .ds_cluster
    jmp     .ds_notfound
.ds_hit:
    pop     rcx
    mov     [DirEntrySector], r11d
    mov     [DirEntryOffset], ebx
    clc
    jmp     .ds_exit
.ds_notfound_pop:
    pop     rcx
.ds_notfound:
    stc
.ds_exit:
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; EAX = кластер директорії. Знаходить вільний слот, а якщо директорія
; заповнена — дописує їй новий кластер (раніше вперався в 16 записів).
DirFindFree:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r10
    mov     r10d, eax
    xor     r8, r8
    mov     dl, 1
    mov     eax, r10d
    call    DirScan
    jnc     .dff_ok

    mov     ebx, r10d
.dff_last:
    mov     eax, ebx
    call    FatGetEntry
    cmp     eax, 2
    jb      .dff_append
    cmp     eax, 0x0FFFFFF8
    jae     .dff_append
    cmp     eax, [TotalClusters]
    jae     .dff_append
    mov     ebx, eax
    jmp     .dff_last
.dff_append:
    call    ChainAlloc
    jc      .dff_fail
    mov     ecx, eax
    mov     edx, eax
    mov     eax, ebx
    call    FatSetEntry
    call    FatFlush
    mov     eax, ecx
    call    ClusterZero
    mov     eax, ecx
    call    ClusterToLBA
    mov     [DirEntrySector], eax
    mov     dword [DirEntryOffset], 0
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
.dff_ok:
    clc
    jmp     .dff_exit
.dff_fail:
    stc
.dff_exit:
    pop     r10
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; FatWriteFile — створити або перезаписати файл.
;   R8  = 11-байтне ім'я у форматі FAT
;   R9  = буфер даних
;   EBX = розмір у байтах
; -> CF=0 успіх, CF=1 помилка
;
; ЩО БУЛО НЕ ТАК У СТАРОМУ WriteFileFAT32Generic:
;  1) писав РІВНО ОДИН сектор на кластер, а читання (LoadFAT32Chain)
;     читає SectorsPerCluster секторів. Будь-який файл понад 512 байт
;     читався назад зіпсованим;
;  2) зв'язував ланцюг лише в першому секторі FAT (кластери < 128),
;     причому lea rdi,[FileBuffer+rcx*4] при великому номері кластера
;     писав за межі 512-байтного буфера — затирання пам'яті ядра;
;  3) шукав запис лише в першому секторі директорії — 16 файлів;
;  4) не звільняв старий ланцюг при перезаписі — FAT текла кластерами.
; ==========================================================
FatWriteFile:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14

    mov     r12d, ebx               ; розмір файлу
    ; need = (size + байт_у_кластері - 1) / байт_у_кластері
    movzx   ecx, byte [SectorsPerCluster]
    shl     ecx, 9
    mov     eax, r12d
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    mov     r13d, eax               ; потрібно кластерів

    mov     byte [FwExisted], 0
    mov     dl, 0
    mov     eax, [CurrentDirCluster]
    call    DirScan
    jc      .fw_create

    mov     byte [FwExisted], 1
    mov     ecx, [DirEntryOffset]
    lea     rsi, [SectorBuffer]
    add     rsi, rcx
    test    byte [rsi + 11], 0x10   ; це директорія?
    jnz     .fw_fail
    movzx   eax, word [rsi + 0x14]
    shl     eax, 16
    mov     ax, word [rsi + 0x1A]
    mov     r10d, eax
    jmp     .fw_have_entry

.fw_create:
    mov     eax, [CurrentDirCluster]
    call    DirFindFree
    jc      .fw_fail
    mov     ecx, [DirEntryOffset]
    lea     rdi, [SectorBuffer]
    add     rdi, rcx
    push    rdi
    mov     rcx, 32
    xor     al, al
    cld
    rep     stosb
    pop     rdi
    push    rdi
    mov     rsi, r8
    mov     rcx, 11
    cld
    rep     movsb
    pop     rdi
    mov     byte [rdi + 11], 0x20
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    xor     r10d, r10d

.fw_have_entry:
    mov     eax, r10d
    mov     ecx, r13d
    call    ChainResize
    jc      .fw_resize_failed
    mov     r10d, eax

    ; --- Пишемо дані ПОВНИМИ кластерами ---
    mov     r11d, r10d
    mov     rsi, r9
    mov     ebx, r12d
.fw_cluster:
    test    ebx, ebx
    jz      .fw_data_done
    cmp     r11d, 2
    jb      .fw_data_done
    cmp     r11d, 0x0FFFFFF8
    jae     .fw_data_done
    mov     eax, r11d
    call    ClusterToLBA
    mov     r14d, eax
    movzx   ecx, byte [SectorsPerCluster]
.fw_sector:
    test    ebx, ebx
    jz      .fw_next_cluster
    ; 1) обнуляємо службовий сектор (хвіст файлу має бути нулями)
    push    rcx
    push    rsi
    lea     rdi, [IoScratch]
    mov     rcx, 512
    xor     al, al
    cld
    rep     stosb
    pop     rsi
    pop     rcx
    ; 2) копіюємо min(залишок, 512) байт; RSI просувається
    push    rcx
    mov     ecx, ebx
    cmp     ecx, 512
    jbe     .fw_have_n
    mov     ecx, 512
.fw_have_n:
    sub     ebx, ecx
    lea     rdi, [IoScratch]
    cld
    rep     movsb
    pop     rcx
    ; 3) пишемо сектор
    push    rcx
    push    rsi
    mov     eax, r14d
    lea     rdi, [IoScratch]
    call    WriteSectorATA
    pop     rsi
    pop     rcx
    inc     r14d
    dec     ecx
    jnz     .fw_sector
.fw_next_cluster:
    mov     eax, r11d
    call    FatGetEntry
    mov     r11d, eax
    jmp     .fw_cluster

.fw_data_done:
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    mov     ecx, [DirEntryOffset]
    lea     rdi, [SectorBuffer]
    add     rdi, rcx
    mov     eax, r10d
    mov     word [rdi + 0x1A], ax
    shr     eax, 16
    mov     word [rdi + 0x14], ax
    mov     eax, r12d
    mov     dword [rdi + 0x1C], eax
    mov     byte [rdi + 11], 0x20

    ; Дата й час зміни. Досі запис лишався з нулями, і колонка
    ; "змінено" у файловому менеджері була б порожня для всього,
    ; що система створила сама. Місце обрано тут, бо через нього
    ; проходить і новий файл, і перезапис наявного.
    push    rdi
    call    FatNow                  ; AX = дата, DX = час
    pop     rdi
    mov     [rdi + 0x18], ax        ; дата зміни
    mov     [rdi + 0x16], dx        ; час зміни
    mov     [rdi + 0x12], ax        ; останній доступ

    ; Дату створення новий файл отримує, а наявний зберігає: перезапис
    ; вмісту не робить файл створеним заново.
    cmp     byte [FwExisted], 0
    jne     .fw_keep_created
    mov     [rdi + 0x10], ax
    mov     [rdi + 0x0E], dx
.fw_keep_created:
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    call    FatFlush
    clc
    jmp     .fw_exit

.fw_resize_failed:
    ; Місця не вистачило. ChainResize уже все звільнив — лишається
    ; привести запис директорії до узгодженого стану.
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    mov     ecx, [DirEntryOffset]
    lea     rdi, [SectorBuffer]
    add     rdi, rcx
    mov     word [rdi + 0x1A], 0
    mov     word [rdi + 0x14], 0
    mov     dword [rdi + 0x1C], 0
    cmp     byte [FwExisted], 0
    jne     .fw_rf_store
    mov     byte [rdi], 0xE5        ; новий файл просто прибираємо
.fw_rf_store:
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    call    FatFlush
.fw_fail:
    stc
.fw_exit:
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret


GetNextFAT32Cluster:
    ; ВИПРАВЛЕНО: раніше читав сектор FAT напряму, повз кеш запису —
    ; після FatSetEntry міг повернути застаріле значення.
    call    FatGetEntry
    ret


FindFAT32Entry:
    push    rcx
    push    rsi
    push    rdi
    push    r9
    mov     eax, [CurrentDirCluster]

.search_cluster:
    cmp     eax, 0x0FFFFFF8
    jae     .not_found
    
    push    rax                         
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    
    mov     r9, DirBuffer       
    movzx   ecx, byte [SectorsPerCluster]
.read_dir_sec:
    push    rax
    push    rcx
    mov     rdi, r9
    call    ReadSectorATA
    add     r9, 512
    pop     rcx
    pop     rax
    inc     eax
    dec     ecx
    jnz     .read_dir_sec
    
    lea     rsi, [DirBuffer]    
    movzx   ecx, byte [SectorsPerCluster]
    shl     ecx, 4              

.check_entry:
    mov     al, [rsi]
    test    al, al
    jz      .not_found_pop_rax          
    cmp     al, 0xE5
    je      .next_entry
    
    push    rcx
    push    rsi
    mov     rdi, r8
    mov     rcx, 11
    cld
    repe cmpsb
    pop     rsi
    pop     rcx
    je      .found

.next_entry:
    add     rsi, 32
    dec     rcx
    jnz     .check_entry
    
    pop     rax                         
    call    GetNextFAT32Cluster
    jmp     .search_cluster

.found:
    pop     rax                         
    movzx   eax, word [rsi + 0x14]
    shl     eax, 16
    mov     ax, word [rsi + 0x1A]
    test    eax, eax
    jnz     .get_size
    mov     eax, [RootCluster]  
.get_size:
    mov     ebx, dword [rsi + 0x1C]
    mov     dl, byte [rsi + 0x0B]
    clc
    pop     r9
    pop     rdi
    pop     rsi
    pop     rcx
    ret

.not_found_pop_rax:                     
    pop     rax

.not_found:
    stc
    pop     r9
    pop     rdi
    pop     rsi
    pop     rcx
    ret

LoadFAT32Chain:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    r8
    xor     r8, r8              
.load_loop:
    cmp     eax, 0x0FFFFFF8
    jae     .done
    push    rax
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    movzx   ecx, byte [SectorsPerCluster]
.read_sec:
    push    rax
    push    rcx
    mov     rdi, r9
    call    ReadSectorATA
    add     r9, 512
    add     r8, 512
    pop     rcx
    pop     rax
    inc     eax
    dec     ecx
    jnz     .read_sec
    pop     rax
    call    GetNextFAT32Cluster
    jmp     .load_loop
.done:
    mov     rbx, r8
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

ListFilesFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     eax, [CurrentDirCluster]
    mov     r9, DirBuffer       
    call    LoadFAT32Chain
    mov     rsi, DirBuffer      
.parse:
    mov     al, [rsi]
    test    al, al
    jz      .done
    cmp     al, 0xE5
    je      .next
    mov     dl, [rsi + 0x0B]
    cmp     dl, 0x0F            
    je      .next
    test    dl, 0x08            
    jnz     .next
    push    rsi
    lea     rdi, [FileNameBuf]
    mov     rcx, 11
    cld
    rep movsb
    mov     byte [rdi], 0
    pop     rsi
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [FileNameBuf]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    test    byte [rsi + 0x0B], 0x10
    jz      .show_size
    add     rcx, 120
    lea     r8, [DirTag]
    mov     r9d, 0x00AAAAAA
    call    DrawString
    jmp     .no_dir_tag
.show_size:
    ; ДОДАНО: розмір файлу в байтах — без нього неможливо відрізнити
    ; "файл порожній" від "файл не читається".
    push    rsi
    mov     eax, dword [rsi + 0x1C]
    lea     rdi, [SizeBuf]
    call    DecToStr
    mov     rcx, 130
    mov     rdx, [CursorY]
    lea     r8,  [SizeBuf]
    mov     r9d, 0x0000AAAA
    call    DrawString
    pop     rsi
.no_dir_tag:
    call    NewLine
.next:
    add     rsi, 32
    jmp     .parse
.done:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

CreateFileFAT32:
    ; R8 = 11-байтне ім'я. Якщо файл уже існує — просто успіх
    ; (раніше створювався другий запис з тим самим іменем).
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     dl, 0
    mov     eax, [CurrentDirCluster]
    call    DirScan
    jnc     .cfe_exists
    mov     eax, [CurrentDirCluster]
    call    DirFindFree
    jc      .cfe_fail
    mov     ecx, [DirEntryOffset]
    lea     rdi, [SectorBuffer]
    add     rdi, rcx
    push    rdi
    mov     rcx, 32
    xor     al, al
    cld
    rep     stosb
    pop     rdi
    push    rdi
    mov     rsi, r8
    mov     rcx, 11
    cld
    rep     movsb
    pop     rdi
    mov     byte [rdi + 11], 0x20
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
.cfe_exists:
    clc
    jmp     .cfe_exit
.cfe_fail:
    stc
.cfe_exit:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret


CreateDirFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi

    call    AllocateFATCluster
    jc      .exit_mkdir_err
    mov     ebx, eax                

    ; Вільний слот шукаємо по ВСЬОМУ ланцюгу каталогу, а не в
    ; першому його секторі. Старий код перебирав рівно 16 записів
    ; і після них казав "нема місця" - а в корені реального диска
    ; записів завжди більше. DirFindFree обходить увесь ланцюг і
    ; за потреби доростає каталог новим кластером; так само вже
    ; робить CreateFileFAT32.
    mov     eax, [CurrentDirCluster]
    call    DirFindFree
    jc      .exit_mkdir_nospace
    mov     eax, [DirEntrySector]
    mov     [TempSector], eax
    mov     ecx, [DirEntryOffset]
    lea     rsi, [SectorBuffer]
    add     rsi, rcx

.found_slot:
    push    rsi
    mov     rdi, rsi
    mov     rsi, r8                  
    mov     rcx, 11
    cld
    rep movsb
    pop     rsi

    mov     byte [rsi+11], 0x10     
    
    push    rdi
    lea     rdi, [rsi+12]
    mov     rcx, 20
    xor     al, al
    cld
    rep stosb                        
    pop     rdi

    mov     edx, ebx
    mov     word [rsi+26], dx        
    shr     edx, 16
    mov     word [rsi+20], dx        

    ; Той самий штамп, що й у файлів: інакше каталог, створений
    ; нами, стоїть у списку без дати.
    push    rdi
    push    rsi
    call    FatNow                  ; AX = дата, DX = час
    pop     rsi
    pop     rdi
    mov     [rsi + 0x18], ax
    mov     [rsi + 0x16], dx
    mov     [rsi + 0x10], ax
    mov     [rsi + 0x0E], dx
    mov     [rsi + 0x12], ax

    mov     eax, [TempSector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA          

    lea     rdi, [SectorBuffer]
    mov     rcx, 512
    xor     al, al
    cld
    rep stosb                        

    lea     rsi, [SectorBuffer]
    
    mov     dword [rsi],   0x2020202E   
    mov     dword [rsi+4], 0x20202020   
    mov     dword [rsi+8], 0x10202020   
    mov     edx, ebx
    mov     word [rsi+26], dx
    shr     edx, 16
    mov     word [rsi+20], dx

    add     rsi, 32
    mov     dword [rsi],   0x20202E2E   
    mov     dword [rsi+4], 0x20202020   
    mov     dword [rsi+8], 0x10202020   
    
    mov     edx, dword [CurrentDirCluster]
    cmp     edx, [RootCluster]
    jne     .not_root_parent
    xor     edx, edx                
.not_root_parent:
    mov     word [rsi+26], dx
    shr     edx, 16
    mov     word [rsi+20], dx

    mov     eax, ebx
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA

    clc                             
    jmp     .exit_mkdir

.exit_mkdir_nospace:
    ; Місця під запис у каталозі не знайшлося, а кластер під сам
    ; каталог ми вже виділили. Повертаємо його у FAT: інакше кожна
    ; невдала спроба з'їдала б кластер назавжди, і побачити це можна
    ; було б лише через fat32_fsck.
    mov     eax, ebx
    call    ChainFree
    call    FatFlush
    stc
    jmp     .exit_mkdir

.exit_mkdir_err:
    stc                             
.exit_mkdir:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

DeleteFileFAT32:
    ; R8 = 11-байтне ім'я. ВИПРАВЛЕНО: шукає по всій директорії
    ; і звільняє весь ланцюг кластерів, а не лише позначає запис.
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    r10
    mov     dl, 0
    mov     eax, [CurrentDirCluster]
    call    DirScan
    jc      .del_fail
    mov     ecx, [DirEntryOffset]
    lea     rdi, [SectorBuffer]
    add     rdi, rcx
    movzx   eax, word [rdi + 0x14]
    shl     eax, 16
    mov     ax, word [rdi + 0x1A]
    mov     r10d, eax
    mov     byte [rdi], 0xE5
    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    cmp     r10d, 2
    jb      .del_ok
    mov     eax, r10d
    call    ChainFree
.del_ok:
    call    FatFlush
    clc
    jmp     .del_exit
.del_fail:
    stc
.del_exit:
    pop     r10
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; RenameFAT32 - змінити ім'я запису в поточному каталозі.
;   R8 = старе 11-байтне ім'я у форматі FAT
;   R9 = нове
; -> CF=0 успіх, CF=1 помилка
;
; Дані файлу нікуди не рухаються: у FAT32 ім'я живе лише в
; 32-байтному записі каталогу, кластери на нього не посилаються.
; Тому перейменування - це запис 11 байт у той самий сектор.
; Каталог перейменувати теж можна: записи "." і ".." усередині
; нього тримають КЛАСТЕР батька, а не його ім'я.
; ==========================================================
RenameFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r10

    mov     r10, r8                 ; старе ім'я треба буде повернути

    ; Нове ім'я вже зайняте? Тоді відмова. Два однакові записи в
    ; одному каталозі роблять другий файл недосяжним назавжди:
    ; будь-який пошук зупиняється на першому.
    mov     r8, r9
    call    FindFAT32Entry
    jnc     .rn_fail

    mov     r8, r10
    mov     dl, 0
    mov     eax, [CurrentDirCluster]
    call    DirScan                 ; сектор запису лишається у SectorBuffer
    jc      .rn_fail

    mov     ecx, [DirEntryOffset]
    lea     rdi, [SectorBuffer]
    add     rdi, rcx
    mov     rsi, r9
    mov     rcx, 11
    cld
    rep     movsb

    mov     eax, [DirEntrySector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    clc
    jmp     .rn_exit

.rn_fail:
    stc
.rn_exit:
    pop     r10
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret


; ==========================================================
; CopyFileFAT32 - копія файлу під іншим ім'ям у тому ж каталозі.
;   R8 = 11-байтне ім'я джерела, R9 = ім'я призначення
; -> CF=0 успіх, CF=1 помилка
;
; Те саме, що робить команда COPY у консолі: файл читається цілком
; у буфер завантаження і пишеться назад під новим ім'ям. Стеля
; розміру - розмір того буфера, 16 МБ.
; ==========================================================
CopyFileFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r13

    mov     r13, r9                 ; ім'я призначення

    ; Копія файлу в себе. Без цієї перевірки FatWriteFile спершу
    ; обрізав би ланцюг джерела до нуля, а вже потім писав дані -
    ; тобто джерело зникло б до того, як його прочитали.
    mov     rsi, r8
    mov     rdi, r9
    mov     rcx, 11
    cld
    repe    cmpsb
    je      .cp_fail

    call    FindFAT32Entry          ; EAX=кластер, EBX=розмір, DL=атрибути
    jc      .cp_fail
    test    dl, 0x10                ; каталог цілком копіювати нічим
    jnz     .cp_fail
    cmp     ebx, 0x1000000          ; більше за буфер не потягнемо
    ja      .cp_fail

    push    rbx                     ; розмір переживе завантаження
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    pop     rbx

    mov     r8, r13
    mov     r9, VideoMemoryBase
    call    FatWriteFile
    jc      .cp_fail
    clc
    jmp     .cp_exit

.cp_fail:
    stc
.cp_exit:
    pop     r13
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret



AllocateFATCluster:
    ; ВИПРАВЛЕНО: раніше сканував лише перший сектор FAT — тобто
    ; на всьому диску могло існувати щонайбільше 126 кластерів.
    call    ChainAlloc
    pushf
    call    FatFlush
    popf
    ret


SaveFileFAT32:
    ; R8 = ім'я. Зберігає EditorBuffer. Тепер просто делегує
    ; у FatWriteFile, який сам створює файл, якщо його немає.
    push    rax
    push    rbx
    push    rcx
    push    rsi
    push    r9
    ; Довжина береться з EdLen, а не з пошуку нульового байта:
    ; інакше нуль усередині файлу обрізав би збереження мовчки.
    mov     r9, EditorBuffer
    mov     rbx, [EdLen]
    call    FatWriteFile
    pop     r9
    pop     rsi
    pop     rcx
    pop     rbx
    pop     rax
    ret


WriteFileFAT32Generic:
    ; Старий інтерфейс: R8 = ім'я, R9 = буфер, EBX = розмір.
    ; Тіло повністю замінено на FatWriteFile.
    call    FatWriteFile
    ret


ReadSectorATA:
    push    rdx
    push    rcx
    push    rbx
    push    rax
    mov     ebx, eax
    mov     edx, 0x1F6
    shr     eax, 24
    or      al, 0xE0            
    out     dx, al
    mov     edx, 0x1F2
    mov     al, 1                
    out     dx, al
    mov     edx, 0x1F3
    mov     eax, ebx            
    out     dx, al
    mov     edx, 0x1F4
    mov     eax, ebx            
    shr     eax, 8
    out     dx, al
    mov     edx, 0x1F5
    mov     eax, ebx            
    shr     eax, 16
    out     dx, al
    mov     edx, 0x1F7
    mov     al, 0x20
    out     dx, al
.wait_ready:
    in      al, dx
    test    al, 8                
    jz      .wait_ready
    mov     edx, 0x1F0
    mov     rcx, 256
    cld
    rep insw                    
    pop     rax
    pop     rbx
    pop     rcx
    pop     rdx
    ret

WriteSectorATA:
    push    rdx
    push    rcx
    push    rbx
    push    rax
    mov     ebx, eax
    mov     edx, 0x1F6
    shr     eax, 24
    or      al, 0xE0
    out     dx, al
    mov     edx, 0x1F2
    mov     al, 1
    out     dx, al
    mov     edx, 0x1F3
    mov     eax, ebx
    out     dx, al
    mov     edx, 0x1F4
    mov     eax, ebx
    shr     eax, 8
    out     dx, al
    mov     edx, 0x1F5
    mov     eax, ebx
    shr     eax, 16
    out     dx, al
    mov     edx, 0x1F7
    mov     al, 0x30
    out     dx, al
.wait_bsy:
    in      al, dx
    test    al, 0x80            
    jnz     .wait_bsy
.wait_drq:
    in      al, dx
    test    al, 0x01            
    jnz     .disk_error
    test    al, 0x08            
    jz      .wait_drq
    mov     edx, 0x1F0
    mov     rcx, 256
    mov     rsi, rdi            
    cld
    rep outsw
    mov     edx, 0x1F7
    mov     al, 0xE7            
    out     dx, al
.wait_flush:
    in      al, dx
    test    al, 0x80
    jnz     .wait_flush
    clc                         
    jmp     .exit_w
.disk_error:
    stc                         
.exit_w:
    pop     rax
    pop     rbx
    pop     rcx
    pop     rdx
    ret

; ==========================================================
; 7. ГРАФІКА ТА ВІДЕОПАМ'ЯТЬ
; ==========================================================
; ----------------------------------------------------------
; BlinkCursor - блимання курсора приблизно двічі на секунду.
; Перемикає стан за таймером; малює/стирає лише на межі зміни,
; щоб не миготіти зайвий раз.
; ----------------------------------------------------------
BlinkCursor:
    push    rax
    push    rcx
    push    rdx
    mov     rax, [SystemTicks]
    xor     rdx, rdx
    mov     rcx, 9                  ; період фази (в тіках таймера)
    div     rcx
    and     al, 1                   ; 0 або 1 - фаза блимання
    cmp     al, [CursorPhase]
    je      .bc_done                ; фаза не змінилась - нічого не робимо
    mov     [CursorPhase], al
    test    al, al
    jz      .bc_hide
    call    DrawCursor
    jmp     .bc_done
.bc_hide:
    call    EraseCursor
.bc_done:
    pop     rdx
    pop     rcx
    pop     rax
    ret

DrawTaskbar:
    ; У MS-DOS верхньої панелі немає — консоль займає весь екран.
    ; Процедуру лишено, бо її кличуть з десятка місць; тепер вона
    ; просто нічого не малює.
    ret

ScrollScreen:
    push    rdi
    push    rsi
    push    rax
    push    rcx
    push    rdx
    push    r10
    mov     rdi, [ScreenBase]            
    movsxd  r10, dword [ScreenStride]
    imul    r10, 20                     
    mov     rsi, rdi
    lea     rsi, [rsi + r10 * 4]        
    movsxd  rcx, dword [ScreenHeight]
    sub     rcx, 20                     
    movsxd  rax, dword [ScreenStride]    
    imul    rcx, rax                    
    cld
    rep     movsd                       
    mov     rcx, r10                    
    xor     eax, eax                    
    rep     stosd                       
    pop     r10
    pop     rdx
    pop     rcx
    pop     rax
    pop     rsi
    pop     rdi
    ret

; ----------------------------------------------------------
; EnableSSE - ввімкнення FPU та SSE.
; Без цього будь-яка інструкція xmm дає #UD (виняток 6).
; ----------------------------------------------------------
EnableSSE:
    push    rax
    mov     rax, cr0
    and     ax, 0xFFFB          ; CR0.EM = 0 (не емулюємо FPU)
    or      ax, 0x2             ; CR0.MP = 1
    mov     cr0, rax
    mov     rax, cr4
    or      ax, 0x600           ; CR4.OSFXSR (bit 9) | CR4.OSXMMEXCPT (bit 10)
    mov     cr4, rax
    fninit
    pop     rax
    ret

; ----------------------------------------------------------
; ClearScreen
; ВИПРАВЛЕНО: тепер зберігає регістри (раніше тихо
; знищувала RAX/RCX/RDX/RDI у всіх, хто її викликав).
; ----------------------------------------------------------
ClearScreen:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    mov     rdi, [ScreenBase]
    movsxd  rcx, dword [ScreenStride]
    movsxd  rdx, dword [ScreenHeight]
    imul    rcx, rdx
    xor     eax, eax            
    cld                         
    rep     stosd
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

DrawString:
    push    rsi
    push    rax
    push    rbx
    push    r10
    mov     rsi, r8              
.next_char:
    lodsb                       
    test    al, al
    jz      .str_done            
    
    cmp     al, 10              
    je      .do_newline
    cmp     al, 13              
    je      .next_char          
    
    movzx   r8, al
    push    rcx
    push    rdx
    push    r9
    call    DrawChar_Safe        
    pop     r9
    pop     rdx
    pop     rcx
    add     rcx, 9              
    
    movsxd  r10, dword [ScreenWidth]
    sub     r10, 20
    cmp     rcx, r10
    jge     .do_newline
    jmp     .next_char

.do_newline:
    mov     rcx, 20             
    add     rdx, 20             
    
    movsxd  r10, dword [ScreenHeight]
    sub     r10, 20
    cmp     rdx, r10
    jl      .next_char          
    
    push    rcx
    push    rdx
    call    ScrollScreen        
    pop     rdx
    pop     rcx
    sub     rdx, 20             
    jmp     .next_char

.str_done:
    pop     r10
    pop     rbx
    pop     rax
    pop     rsi
    ret                         

DrawChar_Safe:
    push    rdi
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rax
    mov     rax, r8                     

    ; ВИПРАВЛЕНО: тут стояло примусове піднімання регістру -
    ; залишок від часів, коли шрифт мав лише великі літери.
    ; Через нього малі літери ніколи не з'являлися на екрані.
    ; Заразом межа була 93 (стара таблиця), тепер 126.
.check_limit:
    cmp     al, 32
    jl      .draw_space
    cmp     al, 126
    jg      .draw_space
    jmp     .calc_offset
    
.draw_space:
    mov     al, 32

.calc_offset:
    ; ВИПРАВЛЕНО: перевіряємо межі екрана ДО обчислення адреси.
    cmp     rcx, 0
    jl      .dcs_skip
    cmp     rdx, 0
    jl      .dcs_skip
    movsxd  r10, dword [ScreenStride]
    sub     r10, 8
    cmp     rcx, r10
    jg      .dcs_skip
    movsxd  r10, dword [ScreenHeight]
    sub     r10, 8
    cmp     rdx, r10
    jg      .dcs_skip

    movzx   rbx, al
    sub     rbx, 32                     
    imul    rbx, 8                      
    lea     rsi, [FontData + rbx + 7]   
    mov     rax, rdx
    movsxd  r10, dword [ScreenStride]
    imul    rax, r10
    add     rax, rcx
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    mov     rcx, 8                      
.ln:
    mov     al, [rsi]
    dec     rsi
    push    rcx
    mov     rcx, 8                      
.px:
    shl     al, 1                       
    jnc     .sk
    mov     [rdi], r9d                  
.sk:
    add     rdi, 4                      
    dec     rcx
    jnz     .px
    pop     rcx
    movsxd  r10, dword [ScreenStride]    
    shl     r10, 2
    sub     r10, 32
    add     rdi, r10
    dec     rcx
    jnz     .ln
.dcs_skip:
    pop     rax
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rdi
    ret

EraseChar:  
    push    rdi
    push    rcx
    push    rdx
    push    rax
    mov     rax, rdx
    movsxd  r10, dword [ScreenStride]
    imul    rax, r10
    add     rax, rcx
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    xor     eax, eax        
    mov     rcx, 8
.el:
    push    rcx
    mov     rcx, 8
.ep:
    mov     [rdi], eax
    add     rdi, 4
    dec     rcx
    jnz     .ep
    pop     rcx
    movsxd  r10, dword [ScreenStride]
    shl     r10, 2
    sub     r10, 32
    add     rdi, r10
    dec     rcx
    jnz     .el
    pop     rax
    pop     rdx
    pop     rcx
    pop     rdi
    ret

DrawCursor:
    push    rdi
    push    rax
    push    rcx
    push    rdx
    push    r10
    mov     rax, [CursorY]
    movsxd  r10, dword [ScreenStride]
    imul    rax, r10
    add     rax, [CursorX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    movsxd  r10, dword [ScreenStride]
    imul    r10, 7
    shl     r10, 2
    add     rdi, r10
    mov     eax, 0x00AAAAAA     
    mov     rcx, 8              
    cld
    rep     stosd
    pop     r10
    pop     rdx
    pop     rcx
    pop     rax
    pop     rdi
    ret

EraseCursor:
    push    rdi
    push    rax
    push    rcx
    push    rdx
    push    r10
    mov     rax, [CursorY]
    movsxd  r10, dword [ScreenStride]
    imul    rax, r10
    add     rax, [CursorX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    movsxd  r10, dword [ScreenStride]
    imul    r10, 7
    shl     r10, 2
    add     rdi, r10
    xor     eax, eax            
    mov     rcx, 8
    cld
    rep     stosd
    pop     r10
    pop     rdx
    pop     rcx
    pop     rax
    pop     rdi
    ret

; --- ВІДНОВЛЕННЯ СТАРОГО ФОНУ ПІД МИШЕЮ ---
RestoreMouseCursor:
    ; Якщо програма малює курсор сама - ядро не чіпає екран взагалі.
    ; Інакше виходить мазня: ядро запам'ятовує фон, програма робить
    ; свій blit поверх, а ядро потім "відновлює" вже застарілий фон.
    cmp     byte [MouseOwnedByApp], 0
    jne     .skip
    cmp     byte [MouseDrawn], 0
    je      .skip                   ; Якщо ще не малювали - нічого не відновлюємо
    push    rax rbx rcx rdx rdi rsi r8 r9
    mov     eax, [OldMouseY]
    movsxd  rbx, dword [ScreenStride]
    imul    rax, rbx
    add     eax, [OldMouseX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax                ; Куди пишемо (екран)
    lea     rsi, [MouseBg]          ; Звідки беремо (наш буфер)
    mov     r8, 5                   ; Висота 5
.row:
    mov     rcx, 5                  ; Ширина 5
    push    rdi
    cld
    rep     movsd
    pop     rdi
    movsxd  rbx, dword [ScreenStride]
    shl     rbx, 2
    add     rdi, rbx
    dec     r8
    jnz     .row
    pop     r9 r8 rsi rdi rdx rcx rbx rax
.skip:
    ret

; --- ЗБЕРЕЖЕННЯ НОВОГО ФОНУ ПІД МИШЕЮ ---
; ----------------------------------------------------------
; НЕ ВИКОРИСТОВУЄТЬСЯ. Малювання курсора перенесено в оболонку
; (libgui). Залишено на випадок, якщо знадобиться текстовий режим
; без графічної оболонки.
; ----------------------------------------------------------
SaveMouseCursor:
    ; Якщо курсор малює програма, ядро не запам'ятовує фон.
    ; Інакше воно збереже шматок екрана з УЖЕ намальованим курсором
    ; програми, а RestoreMouseCursor потім поверне його на місце -
    ; саме звідси бралися стрілки, розкидані по екрану.
    cmp     byte [MouseOwnedByApp], 0
    jne     .smc_skip
    push    rax rbx rcx rdx rdi rsi r8 r9
    mov     byte [MouseDrawn], 1    ; Ставимо прапорець
    mov     eax, [MouseY]
    mov     [OldMouseY], eax        ; Запам'ятовуємо, де ми зараз
    mov     eax, [MouseX]
    mov     [OldMouseX], eax

    mov     eax, [MouseY]
    movsxd  rbx, dword [ScreenStride]
    imul    rax, rbx
    add     eax, [MouseX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rsi, rax                ; Звідки беремо (екран)
    lea     rdi, [MouseBg]          ; Куди пишемо (буфер)
    mov     r8, 5
.row_s:
    mov     rcx, 5
    push    rsi
    cld
    rep     movsd
    pop     rsi
    movsxd  rbx, dword [ScreenStride]
    shl     rbx, 2
    add     rsi, rbx
    dec     r8
    jnz     .row_s
    pop     r9 r8 rsi rdi rdx rcx rbx rax
.smc_skip:
    ret

; --- МАЛЮВАННЯ САМОГО КУРСОРУ (Червоний квадрат 5х5) ---
DrawMouseCursor:
    cmp     byte [MouseOwnedByApp], 0
    jne     .dmc_skip               ; курсором розпоряджається програма
    push    rax rbx rcx rdx rdi r8 r9 r10
    mov     eax, [MouseY]
    movsxd  rbx, dword [ScreenStride]
    imul    rax, rbx
    add     eax, [MouseX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    mov     r10d, 0x00FF0000        ; Колір курсору (Червоний)
    mov     r8, 5
.row_d:
    mov     rcx, 5
    push    rdi
    mov     eax, r10d
    cld
    rep     stosd
    pop     rdi
    movsxd  rbx, dword [ScreenStride]
    shl     rbx, 2
    add     rdi, rbx
    dec     r8
    jnz     .row_d
    pop     r10 r9 r8 rdi rdx rcx rbx rax
.dmc_skip:
    ret
; ==========================================================
; 14. ГРАФІЧНА ОБОЛОНКА (GUI ВІКНА)
; ==========================================================

; Малює зафарбований прямокутник
; Виклик: RCX=X, RDX=Y, R8=Ширина, R9=Висота, R10d=Колір
DrawRect:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    
    ; Обчислюємо початкову адресу: ScreenBase + (Y * ScreenStride + X) * 4
    mov     rax, rdx
    movsxd  rbx, dword [ScreenStride]
    imul    rax, rbx
    add     rax, rcx
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax

    mov     eax, r10d           ; Колір
    mov     r11, r8             ; Зберігаємо ширину

.row_loop:
    test    r9, r9
    jz      .done
    
    mov     rcx, r11            ; Кількість пікселів у рядку
    push    rdi
    cld
    rep     stosd               ; Малюємо 1 лінію
    pop     rdi
    
    ; Переходимо рівно на один рядок екрана вниз
    movsxd  rbx, dword [ScreenStride]
    shl     rbx, 2
    add     rdi, rbx            
    
    dec     r9
    jmp     .row_loop

.done:
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; Малює вікно у стилі Windows 95
; Виклик: RCX=X, RDX=Y, R8=Ширина, R9=Висота
DrawWindow:
    push    rcx
    push    rdx
    push    r8
    push    r9
    push    r10
    
    ; 1. Основний фон вікна (Світло-сірий)
    mov     r10d, 0x00C0C0C0
    call    DrawRect

    ; 2. Заголовок вікна (Синій) - висота 24 пікселі
    push    r9
    mov     r9, 24
    mov     r10d, 0x000000AA
    call    DrawRect
    pop     r9

    ; 3. Малюємо рамки вікна (Чорні, товщина 2 пікселі)
    ; Верхня лінія
    push    r9
    mov     r9, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r9
    
    ; Нижня лінія
    push    rcx
    push    rdx
    push    r9
    add     rdx, r9
    sub     rdx, 2          
    mov     r9, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r9
    pop     rdx
    pop     rcx

    ; Ліва лінія
    push    r8
    mov     r8, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r8
    
    ; Права лінія
    push    rcx
    push    r8
    add     rcx, r8
    sub     rcx, 2
    mov     r8, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r8
    pop     rcx

    pop     r10
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    ret

; ==========================================================
; 8. МЕДІА РУШІЇ (ВІДЕО ТА ФОТО)
; ==========================================================
; ==========================================================
; ==========================================================
; FileCommand - звіт про тип файлу, уже завантаженого в буфер.
; ==========================================================
FileCommand:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    rsi

    call    EugDetect
    test    al, al
    jz      .fc_by_ext

    cmp     al, EUG_VIDEO
    je      .fc_video
    cmp     al, EUG_IMAGE
    je      .fc_image
    cmp     al, EUG_SOUND
    je      .fc_sound
    cmp     al, EUG_SYSTEM
    je      .fc_system
    lea     r8,  [MsgTypeUnk]
    jmp     .fc_show

.fc_video:
    lea     r8,  [MsgTypeVideo]
    jmp     .fc_show_full
.fc_image:
    lea     r8,  [MsgTypeImage]
    jmp     .fc_show_full
.fc_sound:
    lea     r8,  [MsgTypeSound]
    jmp     .fc_show_ver
.fc_system:
    lea     r8,  [MsgTypeSystem]
    jmp     .fc_show_ver

    ; Підпису немає - лишається здогад за розширенням.
.fc_by_ext:
    mov     eax, dword [ParsedFileName + 8]
    and     eax, 0x00FFFFFF
    lea     r8,  [MsgTypeProg]
    cmp     eax, 0x00505041     ; 'APP'
    je      .fc_show
    cmp     eax, 0x004E4942     ; 'BIN'
    je      .fc_show
    lea     r8,  [MsgTypeRawVid]
    cmp     eax, 0x00445645     ; 'EVD'
    je      .fc_show
    lea     r8,  [MsgTypeBmp]
    cmp     eax, 0x00504D42     ; 'BMP'
    je      .fc_show
    lea     r8,  [MsgTypeText]
    cmp     eax, 0x00545854     ; 'TXT'
    je      .fc_show
    lea     r8,  [MsgTypeWav]
    cmp     eax, 0x00564157     ; 'WAV'
    je      .fc_show
    lea     r8,  [MsgTypeUnk]
    jmp     .fc_show

    ; Покажчик на рядок типу кладемо у змінну, а не тягнемо через
    ; стек: DrawString усе одно знадобиться двічі, і R8 у неї свій.
.fc_show_full:
    mov     [FileTypeStr], r8
    mov     ecx, 2                  ; версія, ширина, висота
    jmp     .fc_head
.fc_show_ver:
    mov     [FileTypeStr], r8
    mov     ecx, 1                  ; лише версія
    jmp     .fc_head
.fc_show:
    mov     [FileTypeStr], r8
    xor     ecx, ecx                ; нічого понад тип і розмір

.fc_head:
    push    rcx
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgTypeLabel]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     rcx, 150
    mov     rdx, [CursorY]
    mov     r8,  [FileTypeStr]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    pop     rcx

    mov     eax, [LoadedFileSize]
    lea     r8,  [MsgFileSize]
    call    MemMapLine

    test    ecx, ecx
    jz      .fc_exit

    mov     rsi, VideoMemoryBase
    movzx   eax, byte [rsi + 5]
    lea     r8,  [MsgFileVer]
    call    MemMapLine

    cmp     ecx, 2
    jb      .fc_exit

    mov     rsi, VideoMemoryBase
    movzx   eax, word [rsi + 6]
    lea     r8,  [MsgFileWidth]
    call    MemMapLine

    mov     rsi, VideoMemoryBase
    movzx   eax, word [rsi + 8]
    lea     r8,  [MsgFileHeight]
    call    MemMapLine

.fc_exit:
    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; EugDetect - який тип у файлу, щойно завантаженого в буфер.
;
; -> AL = тип, або 0 якщо підпису немає
;    [MediaOffset] = де починаються самі дані
;
; Файл уже лежить у VideoMemoryBase, тому дивитись у нього нічого
; не коштує. Зміщення потрібне тому, що споживачі даних - програвач
; і виведення картинки - мають починати після заголовка, а у файлів
; без підпису його немає взагалі.
; ==========================================================
; ==========================================================
; EugDetectAt - чи є в буфері наш підпис.
;   RSI = буфер, RDX = розмір файлу
;   -> AL = тип, або 0; [MediaOffset] = де починаються дані
;
; Винесено окремо від EugDetect тому, що перевіряти тип треба і
; для файлу, завантаженого цілком, і для одного прочитаного
; сектора: системний виклик типу файлу не має права тягнути з
; диска сотні мегабайтів заради шістнадцяти байтів заголовка.
; ==========================================================
EugDetectAt:
    mov     dword [MediaOffset], 0
    cmp     rdx, EUG_HDR
    jb      .eda_none
    cmp     dword [rsi], EUG_MAGIC
    jne     .eda_none
    mov     dword [MediaOffset], EUG_HDR
    movzx   eax, byte [rsi + 4]
    ret
.eda_none:
    xor     eax, eax
    ret

; ==========================================================
; EugDetect - те саме для файлу, уже завантаженого в буфер.
; ==========================================================
EugDetect:
    push    rsi
    push    rdx
    mov     rsi, VideoMemoryBase
    mov     edx, [LoadedFileSize]
    call    EugDetectAt
    pop     rdx
    pop     rsi
    ret

RunBadApplePlayer:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    
    mov     rcx, VideoMemoryBase
    mov     eax, [LoadedFileSize]
    add     rcx, rax
    mov     [VideoEOFPtr], rcx

    ; Дані починаються після заголовка, якщо він є. У файлів без
    ; підпису зміщення нульове, тож старі записи грають як і грали.
    mov     rcx, VideoMemoryBase
    mov     eax, [MediaOffset]
    add     rcx, rax
    mov     [VideoDataPtr], rcx
    mov     dword [RLE_Count], 0
    mov     dword [FramesRendered], 0

    ; --- Розміри кадру беремо із заголовка ---
    ;
    ; У файлів без підпису розмір був зашитий у код: 320x240 і ніяк
    ; інакше. Нові несуть свої розміри в заголовку, тому програвач
    ; більше не прив'язаний до одного формату.
    mov     dword [VidSrcW], 320
    mov     dword [VidSrcH], 240
    cmp     dword [MediaOffset], 0
    je      .dims_ready

    mov     rsi, VideoMemoryBase
    movzx   eax, word [rsi + 6]
    movzx   ecx, word [rsi + 8]
    test    eax, eax
    jz      .dims_ready             ; нулі в заголовку - лишаємо типові
    test    ecx, ecx
    jz      .dims_ready
    mov     [VidSrcW], eax
    mov     [VidSrcH], ecx
.dims_ready:

    ; Кадр мусить уміститися в задній буфер. Без цієї перевірки
    ; декодер писав би за його межі - тобто в стек програм і далі,
    ; за зіпсованим розміром у заголовку чи просто за чужим файлом.
    mov     eax, [VidSrcW]
    mul     dword [VidSrcH]
    test    edx, edx
    jnz     .too_big                ; добуток не вліз навіть у 32 біти
    mov     [VidPixels], eax
    shl     eax, 2
    jc      .too_big
    cmp     eax, VIDBUF_MAX
    ja      .too_big

    ; --- Масштаб під поточний режим ---
    ;
    ; Більше деталей, ніж є у файлі, взяти нізвідки. Тому "на весь
    ; екран" означає збільшення, а не різкішу картинку.
    ;
    ; Множник цілий, а не дробовий. На такій графіці дробовий дає
    ; рвані краї: частина вихідних пікселів займала б три екранних,
    ; частина чотири, і рівні лінії перетворилися б на сходинки
    ; різної висоти. Цілий множник лишає зображення чистим ціною
    ; полів по краях.
    mov     eax, [ScreenWidth]
    xor     edx, edx
    div     dword [VidSrcW]
    mov     ebx, eax                ; скільки разів уміщається по ширині

    mov     eax, [ScreenHeight]
    xor     edx, edx
    div     dword [VidSrcH]         ; і по висоті

    cmp     eax, ebx
    jbe     .scale_take
    mov     eax, ebx                ; беремо менше з двох
.scale_take:
    test    eax, eax
    jnz     .scale_ok
    mov     eax, 1                  ; екран менший за кадр - без масштабу
.scale_ok:
    mov     [VidScale], eax

    mov     ecx, eax
    mov     eax, [VidSrcW]
    mul     ecx
    mov     [VidW], eax
    mov     eax, [VidSrcH]
    mul     ecx
    mov     [VidH], eax

    mov     eax, [ScreenWidth]
    sub     eax, [VidW]
    shr     eax, 1
    mov     [StartX], eax

    mov     eax, [ScreenHeight]
    sub     eax, [VidH]
    shr     eax, 1
    mov     [StartY], eax

    call    ClearScreen

.playback_loop:
    in      al, 0x64
    test    al, 1
    jz      .no_key
    test    al, 0x20            ; байт від миші - ігноруємо
    jz      .pb_kbd
    in      al, 0x60
    mov     byte [MouseState], 0
    jmp     .no_key
.pb_kbd:
    in      al, 0x60
    cmp     al, 0x01                
    je      .exit_ok
.no_key:
    mov     rax, [VideoDataPtr]
    cmp     rax, [VideoEOFPtr]
    jae     .exit_ok

    call    StartFrameTimer         
    call    DecodeFrameToBackBuffer 
    call    BlitBackBufferToScreen  
    call    WaitFrameTimer          

    inc     dword [FramesRendered]
    jmp     .playback_loop
.too_big:
    ; Кадр не влазить у задній буфер. Мовчки обрізати не можна:
    ; декодер писав би за межі буфера, у стек програм.
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgVidTooBig]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

.exit_ok:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

DecodeFrameToBackBuffer:
    push    rax
    push    rcx
    push    rdi
    push    rsi
    mov     rdi, BackBufferBase
    mov     ecx, [VidPixels]        ; розмір кадру задає заголовок
.px_loop:
    cmp     dword [RLE_Count], 0
    ja      .draw_px
    mov     rsi, [VideoDataPtr]
    lodsb
    test    al, al
    jz      .black_px
    mov     eax, 0x00FFFFFF    
    jmp     .save_color
.black_px:
    mov     eax, 0x00000000    
.save_color:
    mov     [RLE_Color], eax
    lodsd
    mov     [RLE_Count], eax
    mov     [VideoDataPtr], rsi
.draw_px:
    mov     eax, [RLE_Color]
    stosd
    dec     dword [RLE_Count]
    dec     rcx
    jnz     .px_loop
    pop     rsi
    pop     rdi
    pop     rcx
    pop     rax
    ret

; ==========================================================
; BlitBackBufferToScreen - кадр 320x240 на екран із масштабом.
;
; Масштабування робиться саме тут, а не в декодері: декодер пише
; кадр як є, а розмір на екрані залежить лише від режиму. Так
; формат файлу лишається незмінним.
;
; Горизонтальне розтягнення робимо ОДИН раз на вихідний рядок, у
; окремий буфер, а вертикальне - копіюванням готового рядка кілька
; разів. Інакше та сама робота повторювалась би для кожного з N
; однакових рядків, а їх при множнику 3 виходить утричі більше за
; вихідні.
; ==========================================================
BlitBackBufferToScreen:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    rsi
    push    r10
    push    r11

    mov     rsi, BackBufferBase
    mov     r10d, [VidSrcH]         ; вихідних рядків
    mov     ecx, [StartY]           ; рядок екрана, куди ліг би цей

.line_loop:
    ; --- один вихідний рядок -> розтягнутий рядок у буфері ---
    mov     rdi, LineBufBase
    mov     r11d, [VidSrcW]
.hx_loop:
    lodsd                           ; піксель джерела; RSI сам іде далі
    mov     ebx, [VidScale]
.hx_rep:
    stosd
    dec     ebx
    jnz     .hx_rep
    dec     r11
    jnz     .hx_loop
    ; RSI тепер рівно на початку наступного вихідного рядка

    ; --- готовий рядок кладемо на екран стільки разів, як множник ---
    mov     r11d, [VidScale]
.vy_loop:
    mov     rax, rcx
    movsxd  rdx, dword [ScreenStride]
    imul    rax, rdx
    add     eax, [StartX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax

    push    rcx
    push    rsi
    mov     rsi, LineBufBase
    mov     ecx, [VidW]
    ; Ширина на екрані могла стати непарною: вихідна ширина тепер
    ; приходить із заголовка й не зобов'язана ділитись на два.
    shr     ecx, 1
    cld
    rep     movsq
    test    dword [VidW], 1
    jz      .vy_copied
    movsd
.vy_copied:
    pop     rsi
    pop     rcx

    inc     rcx
    dec     r11d
    jnz     .vy_loop

    dec     r10
    jnz     .line_loop

    pop     r11
    pop     r10
    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

StartFrameTimer:
    push    rax
    mov     rax, [SystemTicks]
    add     rax, 41                 
    mov     [FrameTargetTick], rax
    pop     rax
    ret

WaitFrameTimer:
    push    rax
.wait:
    mov     rax, [SystemTicks]
    cmp     rax, [FrameTargetTick]
    jl      .wait                   
    pop     rax
    ret

FrameTargetTick dq 0                

DrawBMP:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r10
    push    r11
    push    r12
    cmp     word [r9], 0x4D42
    jne     .err
    cmp     word [r9 + 0x1C], 24
    jne     .err
    mov     r10d, dword [r9 + 0x12]     
    mov     r11d, dword [r9 + 0x16]     
    mov     eax, dword [r9 + 0x0A]      
    lea     rsi, [r9 + rax]             
    mov     eax, r10d
    imul    eax, 3                      
    mov     ebx, eax
    add     eax, 3
    and     eax, 0xFFFFFFFC             
    sub     eax, ebx                    
    mov     r12d, eax                   
    mov     eax, [ScreenWidth]
    sub     eax, r10d                   
    shr     eax, 1
    mov     [StartX], eax
    mov     eax, [ScreenHeight]
    sub     eax, r11d                   
    shr     eax, 1
    mov     [StartY], eax
    call    ClearScreen
    mov     r8d, r11d
    dec     r8d                         
.row_loop:
    mov     eax, [StartY]
    add     eax, r8d
    movsxd  rdx, dword [ScreenStride]
    imul    rax, rdx
    add     eax, [StartX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax                    
    mov     rcx, r10                    
.pixel_loop:
    movzx   eax, byte [rsi]             
    movzx   ebx, byte [rsi+1]           
    shl     ebx, 8
    or      eax, ebx
    movzx   ebx, byte [rsi+2]           
    shl     ebx, 16
    or      eax, ebx
    stosd                               
    add     rsi, 3                      
    dec     rcx
    jnz     .pixel_loop
    add     rsi, r12
    dec     r8d
    js      .done                       
    jmp     .row_loop
.done:
    clc                                 
    pop     r12
    pop     r11
    pop     r10
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret
.err:
    stc                                 
    pop     r12
    pop     r11
    pop     r10
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; 9. ДАНІ ТА ЗМІННІ ЯДРА
; ==========================================================
ScreenBase      dq 0
ScreenWidth     dd 0      ; видима ширина - для обрізання й центрування
ScreenStride    dd 0      ; PixelsPerScanLine - для будь-якої адресації

; --- КАРТА ПАМ'ЯТІ ВІД ЗАВАНТАЖУВАЧА ---
; Заповнюється з блока, вказівник на який приходить у R10. Нулі тут
; означають, що завантажувач старий і карти не передав - працюємо як
; раніше, за фіксованими адресами.
MemMapAddr      dq 0
MemMapSize      dq 0
MemMapDescSize  dd 0
MemMapDescVer   dd 0
ScreenHeight    dd 0
CursorX         dq 0
CursorY         dq 0

CmdBuffer       rb 64            
BufferLen       dq 0

; Список команд
CmdWin          db 'WIN', 0
CmdPci          db 'PCI', 0
CmdCpuInfo      db 'CPUINFO', 0
CmdNetInit      db 'NETINIT', 0
CmdNetTest      db 'NETTEST', 0
CmdPing         db 'PING', 0
CmdPingArg      db 'PING ', 0
CmdNsLookup     db 'NSLOOKUP ', 0
CmdSetDns       db 'SETDNS ', 0
CmdTcp          db 'TCP ', 0
CmdHttpGet      db 'GET ', 0
CmdCopy         db 'COPY ', 0
CmdInstall      db 'INSTALL ', 0
CmdDhcp         db 'DHCP', 0
CmdIpconfig     db 'IPCONFIG', 0
CmdHelp         db 'HELP', 0
CmdInfo         db 'INFO', 0
CmdMemMap       db 'MEMMAP', 0
CmdTasks        db 'TASKS', 0
MsgTasksTitle   db 'TASK TABLE:', 0
MsgTasksSlots   db 'SLOTS TOTAL:', 0
MsgTasksReady   db 'READY:', 0
MsgTasksCur     db 'CURRENT SLOT:', 0
MsgTasksApp     db 'APP IN SLOT:', 0
MsgTasksNoApp   db 'NO PROGRAM RUNNING.', 0
MsgTasksBg      db 'BACKGROUND TURNS:', 0
MsgTasksDemand  db 'HEAP PAGES MAPPED:', 0
MsgTasksSpaces  db 'ADDRESS SPACES MADE:', 0
MsgTasksFreed   db 'ADDRESS SPACES FREED:', 0
MsgTasksEach    db 'SLOT 0..7:', 0
TaskLineBuf     rb 24
CmdPaging       db 'PAGING', 0
CmdPfTest       db 'PFTEST', 0
CmdNullTest     db 'NULLTEST', 0
MsgNullTest     db 'WRITING THROUGH A NULL POINTER. A PANIC IS THE EXPECTED RESULT.', 0
MsgPfTest       db 'READING AT 4 GB. A PAGE FAULT PANIC IS THE EXPECTED RESULT.', 0
MsgPgTitle      db 'PAGING STATUS:', 0
MsgPgOk         db 'OWN PAGE TABLES ACTIVE.', 0
MsgPgFirmware   db 'RUNNING ON FIRMWARE TABLES. NO MEMORY MAP?', 0
MsgPgPml4       db 'PML4 AT:', 0
MsgPgCr3        db 'CR3 NOW:', 0
MsgPgMapped     db 'IDENTITY MAPPED, GB:', 0
MsgPgFrames     db 'TABLE FRAMES USED:', 0
align 8
PagePml4        dq 0
PagePdpt        dq 0
PagePd0         dq 0
CmdReboot       db 'REBOOT', 0
CmdCLS          db 'CLS', 0
CmdLS           db 'LS', 0
CmdCD           db 'CD ', 0
CmdOpen         db 'OPEN ', 0
CmdFile         db 'FILE ', 0
CmdRen          db 'REN ', 0
MsgRenUsage     db 'USAGE: REN <OLD NAME> <NEW NAME>', 0
MsgRenFail      db 'RENAME FAILED. NO SUCH FILE, OR THE NAME IS TAKEN.', 0
MsgRenOk        db 'RENAMED TO', 0
MsgTypeLabel    db 'TYPE:', 0
MsgTypeVideo    db 'EUGENE VIDEO (EUGN)', 0
MsgTypeImage    db 'EUGENE IMAGE (EUGN)', 0
MsgTypeSound    db 'EUGENE SOUND (EUGN)', 0
MsgTypeSystem   db 'EUGENE SYSTEM FILE (EUGN)', 0
MsgTypeProg     db 'PROGRAM', 0
MsgTypeRawVid   db 'VIDEO, NO HEADER', 0
MsgTypeBmp      db 'BITMAP IMAGE', 0
MsgTypeText     db 'PLAIN TEXT', 0
MsgTypeWav      db 'SOUND', 0
MsgTypeUnk      db 'UNKNOWN', 0
MsgFileSize     db 'SIZE, BYTES:', 0
MsgFileWidth    db 'WIDTH:', 0
MsgFileHeight   db 'HEIGHT:', 0
MsgFileVer      db 'FORMAT VERSION:', 0
CmdEdit         db 'EDIT ', 0
CmdCreate       db 'CREATE ', 0
CmdRM           db 'RM ', 0
CmdTime         db 'TIME', 0
CmdBeep         db 'BEEP', 0
CmdMkdir        db 'MKDIR ', 0          
CmdBack         db 'BACK', 0
CmdRun          db 'RUN ', 0        

; Тексти і повідомлення
MsgName         db 'EUGENE OS  Version 2.0', 0
MsgCopy         db '(C) 2026 Eugene.  All rights reserved.', 0
MsgHint         db 'Type HELP for a list of commands.', 0
MsgMmTitle      db 'FIRMWARE MEMORY MAP:', 0
MsgMmNone       db 'NO MEMORY MAP. OLD BOOTLOADER, OR ALLOCATION FAILED.', 0
MsgMmEntries    db 'ENTRIES:', 0
MsgMmFree       db 'FREE RAM, MB:', 0
MsgMmReclaim    db 'RECLAIMABLE RAM, MB:', 0
MsgMmOurs       db 'LOADER AND KERNEL, KB:', 0
MsgMmResv       db 'RESERVED RAM, MB:', 0
MsgMmMmio       db 'MMIO (NOT RAM), MB:', 0
MsgMmTop        db 'HIGHEST ADDRESS, MB:', 0
MsgMmFb         db 'FRAMEBUFFER AT, MB:', 0
MsgMmFrames     db 'POOL FRAMES:', 0
MsgMmFramesFree db 'POOL FRAMES FREE:', 0
align 8
MmFree          dq 0
MmReclaim       dq 0
MmOurs          dq 0
MmResv          dq 0
MmMmio          dq 0
MmTop           dq 0
FrameCount      dq 0    ; скільки кадрів обслуговує пул
FrameFreeCount  dq 0    ; скільки з них вільні
FrameNextHint   dq 0    ; звідки почати наступний пошук
FrameBitmapBytes dq 0   ; розмір бітової карти в байтах
MmEntries       dd 0
MemMapNumBuf    rb 24
MsgHelpList     db 'FILES: LS, CD, OPEN, FILE, EDIT, CREATE, COPY, REN, RM, MKDIR, RUN, INSTALL', 0
MsgHelpNet      db 'NET:   NETINIT, DHCP, IPCONFIG, PING <IP|HOST>, NSLOOKUP <HOST>, SETDNS <IP>, PCI', 0
MsgHelpSys      db 'SYS:   HELP, CLS, REBOOT, WIN, INFO, CPUINFO, TIME, BEEP', 0
MsgWinTitle     db 'System Status', 0
MsgWinBody      db 'GUI Window System works!', 0
MsgCPU          db 'CPU DETECTED:', 0
CurrentPath     db 'C:\', 0
                times 250 db 0      
MsgUnknown      db 'UNKNOWN COMMAND', 0
MsgLS           db 'FILES IN CURRENT DIRECTORY:', 0
MsgCreated      db 'FILE CREATED: ', 0
MsgDirCreated   db 'DIRECTORY CREATED: ', 0
MsgDeleted      db 'FILE DELETED', 0
MsgTime         db 'RTC TIME: ', 0
TimeStr         db '00:00:00', 0
MsgWriteErr     db 'DISK WRITE ERROR (READ-ONLY?)', 0
MsgReadErr      db 'FILE OR DIRECTORY NOT FOUND', 0
MsgNotDir       db 'ERROR: NOT A DIRECTORY', 0
MsgUnknownExt   db 'ERROR: NO APP ASSIGNED FOR THIS EXTENSION', 0
MsgVidTooBig    db 'FRAME TOO LARGE FOR THE VIDEO BUFFER (13 MB).', 0
MsgIsProgram    db 'THIS IS A PROGRAM. USE  RUN <FILE>  TO START IT.', 0
MsgSysFile      db 'EUGENE SYSTEM FILE. NOTHING TO DISPLAY.', 0
MsgEugBroken    db 'EUG FILE WITHOUT A VALID EUGN SIGNATURE.', 0
align 4
MediaOffset     dd 0
VidSrcW         dd 320  ; розмір кадру у файлі
VidSrcH         dd 240
VidPixels       dd 320*240
VidScale        dd 1    ; цілий множник збільшення кадру
VidOpen         dd 0    ; чи відкрито відео для показу у вікні
VidFileSize     dd 0    ; розмір того файлу; LoadedFileSize спільний
VidW            dd 320  ; розмір кадру на екрані після масштабування
VidH            dd 240
align 8
FileTypeStr     dq 0
MsgAudio        db 'AUDIO PLAYBACK STUB (PC SPEAKER)', 0
MsgVideoDone    db 'PLAYBACK FINISHED', 0
DirTag          db '<DIR>', 0
MsgEditor       db 'EDITOR  F2:SAVE  F3:GOTO  ESC:EXIT', 0
MsgViewer       db 'VIEWER  ESC:EXIT   (READ ONLY)', 0
MsgBinary       db 'BINARY FILE - READ ONLY  ESC:EXIT', 0
MsgSaved        db '[ SAVED ]', 0
MsgEdLine       db 'LINE', 0
MsgEdCol        db 'COL', 0
MsgEdSize       db 'SIZE', 0
MsgEdGoto       db 'GO TO LINE:', 0
EdStatusStr     db '0', 0
                times 24 db 0
MsgErrFat       db '[ FAT ERROR ]', 0
MsgRun          db 'LAUNCHING EXTERNAL APP...', 0
MsgNotApp       db 'THIS IS A KERNEL IMAGE, NOT A PROGRAM.', 0
MsgNotApp2      db 'USE  INSTALL <FILE>  TO MAKE IT THE SYSTEM KERNEL.', 0
ExecPending     db 0            ; програма попросила запустити іншу
ExecRequest     rb 16           ; її FAT-ім'я
ExecStack       rb 44           ; куди повертатись: до 4 рівнів по 11 байт
ExecDepth       db 0
AppRunning      db 0            
; --- Клавіатурний FIFO буфер (для Doom) ---
KbdBuffer       rb 256
KbdHead         db 0
KbdTail         db 0

; --- Змінні PS/2 Миші ---
MouseState      db 0
MousePacket     rb 4                ; 4 байти: у режимі IntelliMouse є ще ось Z
MousePacketLen  db 3                ; 3 = звичайна миша, 4 = з колесом
MouseWheel      db 0                ; накопичувач прокрутки (знаковий), чиститься при читанні
MouseX          dd 400
MouseY          dd 300   
; --- Змінні для відмальовки курсору ---
OldMouseX    dd 400
OldMouseY    dd 300
MouseDrawn   db 0        ; Прапорець: чи малювали ми вже курсор
MouseBg      rd 25       ; Буфер на 25 пікселів (5x5) для збереження фону 

MouseClick      db 0    ; 0 - не натиснуто, 1 - лівий клік, 2 - правий

SectorBuffer    rb 512          
IoScratch       rb 512          ; службовий сектор для запису даних
FatCacheBuf     rb 512          ; кеш одного сектора FAT
FatCacheLBA     dd 0            ; який саме сектор зараз у кеші
FatCacheDirty   db 0
NumFATs         db 0            ; скільки копій FAT на томі
SectorsPerFAT   dd 0
TotalClusters   dd 0            ; верхня межа номера кластера
AllocHint       dd 2            ; звідки починати пошук вільного кластера
DirEntrySector  dd 0            ; результат DirScan
DirEntryOffset  dd 0
FwExisted       db 0
CursorPhase     db 0            ; поточна фаза блимання курсора
KbdMods         db 0            ; 1=Shift 2=Ctrl 4=Alt 8=CapsLock
MouseOwnedByApp db 0            ; 1 = курсор малює програма, не ядро

; --- Інформація про процесор ---
align 8
AcpiRsdp        dq 0            ; знайдений RSDP
AcpiMadt        dq 0            ; таблиця з описом процесорів
AcpiIsXsdt      db 0            ; 1 = ACPI 2.0+, вказівники 64-бітні
align 4
CpuCount        dd 0            ; скільки ядер увімкнено
LapicBase       dd 0            ; адреса локального APIC
CpuIds          rb MAX_CPUS     ; їхні APIC ID
CpuBrand        rb 52           ; назва процесора з CPUID

MsgCpuCores     db 'CPU CORES:', 0
MsgCpuIds       db 'APIC IDS:', 0
MsgCpuLapic     db 'LAPIC BASE:', 0
MsgCpuHeap      db 'USER HEAP SIZE:', 0
MsgCpuMb        db 'MB', 0
MsgCpuSmp       db '(SMP NOT ENABLED - ONLY CORE 0 IS USED)', 0

; --- PCI ---
align 8
PciBuf          rb 24           ; тимчасовий рядок для друку чисел
PciNetFound     dd 0            ; 1 = мережеву карту знайдено
PciClass        dd 0            ; клас поточного пристрою

; --- Стан мережевої карти ---
NetReady        db 0            ; 1 = карта ініціалізована
align 8
NetMac          rb 6            ; наша MAC-адреса
align 4
NetRxPos        dd 0            ; наша позиція читання в кільцевому буфері
NetTxSlot       dd 0            ; який з чотирьох буферів передачі наступний

MsgNetMac       db 'MAC ADDRESS:', 0
MsgNetUp        db 'RTL8139 INITIALIZED. LINK UP.', 0
MsgNetFail      db 'NETWORK INIT FAILED (NO RTL8139 FOUND).', 0

; --- Буфери й адреси для ARP ---
align 4
NetFrame        rb 1600         ; кадр, який відправляємо (DHCP ~350 байт)
NetRxFrame      rb 1600         ; кадр, який прийняли
NetGwMac        rb 6            ; MAC шлюзу, коли дізнаємось
NetLastLen      dd 0

; Початкові адреси. Після DHCP вони замінюються отриманими.
NetMyIp         db 10, 0, 2, 15
NetGwIp         db 10, 0, 2, 2
NetMask         db 255, 255, 255, 0
NetDnsIp        db 10, 0, 2, 3
NetBcastMac     db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
NetBcastIp      db 255, 255, 255, 255

; --- Стан DHCP ---
align 4
DhcpXid         dd 0            ; ідентифікатор транзакції
DhcpState       db 0            ; 0 = нічого, 2 = OFFER, 5 = ACK
align 4
DhcpOfferIp     db 0, 0, 0, 0   ; яку адресу нам пропонують
DhcpServerIp    db 0, 0, 0, 0   ; хто пропонує
DhcpBuf         rb 320          ; тіло DHCP-пакета

MsgDhcpGo       db 'REQUESTING ADDRESS FROM DHCP SERVER...', 0
MsgDhcpOffer    db 'OFFER RECEIVED:', 0
MsgDhcpIp       db 'IP ADDRESS:', 0
MsgDhcpMask     db 'SUBNET MASK:', 0
MsgDhcpGw       db 'GATEWAY:', 0
MsgDhcpDns      db 'DNS SERVER:', 0
MsgDhcpFail     db 'DHCP FAILED (NO RESPONSE).', 0

; --- DNS ---
align 2
DnsId           dw 0            ; ідентифікатор нашого запиту
DnsGot          db 0            ; 1 = адресу знайдено
align 4
NetTargetIp     db 0, 0, 0, 0   ; результат розв'язання імені
DnsBuf          rb 320          ; тіло DNS-запиту
DnsLen          dd 0            ; довжина зібраного DNS-запиту
NetUdpCount     dd 0            ; діагностика: скільки UDP-пакетів прийнято
NetLastPort     dd 0            ; порт призначення останнього UDP
DnsStage        dd 0            ; як далеко дійшов NetResolve
DnsSentLen      dd 0            ; довжина, передана у NetSendUdp
DnsFrameLen     dd 0            ; підсумкова довжина кадру
DnsTxOk         db 0            ; 1 = NetSend повернув успіх
DnsFellBack     db 0            ; уже пробували запасний сервер імен
align 4
DnsDbgCalls     dd 0            ; скільки разів викликано NetHandleDns
DnsDbgStage     dd 0            ; як далеко пройшов розбір
DnsDbgId        dd 0            ; ID у відповіді
DnsDbgMyId      dd 0            ; ID, який ми чекали
DnsDbgAn        dd 0            ; ANCOUNT
DnsDbgType      dd 0            ; тип першого запису
DnsDbgRdLen     dd 0            ; довжина його даних

MsgDnsFound     db 'ADDRESS:', 0
MsgDnsFail      db 'COULD NOT RESOLVE HOST NAME.', 0
MsgDbgUdp       db 'UDP PACKETS:', 0
MsgDbgPort      db 'LAST PORT:', 0
MsgDbgStage     db 'STAGE:', 0
MsgDbgGw        db 'GWKNOWN:', 0
MsgDbgTx        db 'TX:', 0
MsgDbgLen       db 'LEN:', 0
MsgBadIp        db 'INVALID IP ADDRESS.', 0
MsgCopied       db 'COPIED TO', 0
MsgCopyUsage    db 'USAGE: COPY <SOURCE> <DEST>', 0
MsgInstUsage    db 'USAGE: INSTALL FILE.BIN', 0
MsgInstNoSrc    db 'SOURCE FILE NOT FOUND', 0
MsgInstIsDir    db 'SOURCE IS A DIRECTORY', 0
MsgInstEmpty    db 'SOURCE FILE IS EMPTY', 0
MsgInstBig      db 'SOURCE FILE TOO LARGE', 0
MsgInstBakFail  db 'COULD NOT WRITE KERNEL.BAK - NOTHING CHANGED', 0
MsgInstWrFail   db 'COULD NOT WRITE KERNEL.BIN - SYSTEM MAY NOT BOOT', 0
MsgInstOk       db 'INSTALLED. PREVIOUS KERNEL SAVED AS KERNEL.BAK', 0
MsgInstHint     db 'TYPE REBOOT TO START THE NEW KERNEL.', 0
FatKernelBin    db 'KERNEL  BIN'
FatKernelBak    db 'KERNEL  BAK'
MsgCopyNoSrc    db 'SOURCE FILE NOT FOUND.', 0
MsgCopyIsDir    db 'CANNOT COPY A DIRECTORY.', 0
MsgCopyBig      db 'FILE TOO LARGE (LIMIT 16 MB).', 0
MsgCopyFail     db 'WRITE FAILED (DISK FULL?).', 0
MsgDbgAn        db 'ANS:', 0
MsgDbgType      db 'TYPE:', 0
MsgDbgRd        db 'RDL:', 0
MsgDbgIds       db 'MYID:', 0
MsgDbgGot       db 'GOT:', 0
MsgDbgCalls     db 'CALLS:', 0
MsgPingName     db 'PINGING', 0
MsgPingFrom     db 'REPLY FROM', 0

MsgArpSent      db 'ARP REQUEST SENT TO 10.0.2.2', 0
MsgArpGw        db 'GATEWAY MAC:', 0
MsgArpOk        db 'NETWORK RX/TX WORKING.', 0
MsgArpNone      db 'NO REPLY (TIMEOUT).', 0
MsgArpOther     db 'GOT A FRAME, BUT NOT AN ARP REPLY.', 0
MsgTxFail       db 'TRANSMIT FAILED.', 0

; --- Стан мережевого стека ---
NetGwKnown      db 0            ; 1 = MAC шлюзу відома
NetPingGot      db 0            ; 1 = прийшла відповідь на наш пінг
align 2
NetIpId         dw 0            ; лічильник ідентифікаторів IP-пакетів
align 4
NetArpReplies   dd 0            ; скільки разів ми відповіли на ARP
NetPingsAnswered dd 0           ; скільки чужих пінгів ми обслужили

; --- TCP ---
;
; Клієнтський і на одне з'єднання за раз - як і решта підсистем тут:
; стан декодера відео теж один. Цього досить, щоб зробити запит і
; прочитати відповідь.
;
; Чого свідомо немає: переупорядкування (сегмент не за номером просто
; відкидаємо, і відправник надішле його ще раз - повільно, зате
; правильно), вікна більшого за буфер, і будь-яких опцій.
align 8
TcpState        db 0            ; TCPS_*
TcpFinSeen      db 0            ; співрозмовник закрив свій бік
TcpRstSeen      db 0            ; з'єднання збили
TcpGotAck       db 0            ; прийшов ACK на послане нами
align 2
TcpLocalPort    dw 0            ; порти зберігаємо в МЕРЕЖЕВОМУ порядку
TcpRemotePort   dw 0
TcpPortSeed     dw 0            ; щоб два з'єднання поспіль не збіглись
TcpRemoteIp     db 0, 0, 0, 0
align 4
TcpSndNxt       dd 0            ; наступний номер, який ми пошлемо
TcpSndUna       dd 0            ; найстаріше, ще не підтверджене ними
TcpRcvNxt       dd 0            ; номер, якого ми чекаємо від них
TcpRxLen        dd 0            ; скільки байтів уже прийнято
align 4
TcpCmdIp        db 0, 0, 0, 0   ; аргументи команди TCP
TcpCmdPort      dw 0
MsgTcpTrying    db 'CONNECTING TO', 0
MsgTcpOk        db 'CONNECTED - HANDSHAKE COMPLETE', 0
align 4
TcpRxSegs       dd 0            ; скільки TCP-сегментів прийшло взагалі
TcpFailWhy      db 0            ; чому не вийшло; див. TcpCommand
MsgTcpNoCard    db 'NETWORK CARD IS NOT UP - RUN NETINIT FIRST', 0
MsgTcpNoArp     db 'NO ARP REPLY FROM GATEWAY - IS THE NETWORK UP', 0
MsgTcpNoSend    db 'COULD NOT SEND THE PACKET', 0
MsgTcpRst       db 'REFUSED - RST RECEIVED, SO THE PACKET DID ARRIVE', 0
MsgTcpTimeout   db 'NO REPLY - TIMED OUT', 0
MsgTcpSeen      db 'TCP SEGMENTS RECEIVED:', 0
HttpTxtGet      db 'GET ', 0
HttpTxtVer      db ' HTTP/1.0', 13, 10, 'Host: ', 0
HttpTxtTail     db 13, 10, 'Connection: close', 13, 10, 13, 10, 0
MsgHttpResolved db 'RESOLVED TO:', 0
MsgHttpDnsFail  db 'COULD NOT RESOLVE THAT NAME', 0
MsgDnsStage     db 'DNS STOPPED AT STAGE:', 0
MsgDnsTx        db 'FRAME SENT:', 0
align 8
HttpPath        rb 128
HttpReqBuf      rb 512
MsgHttpBytes    db 'BYTES RECEIVED:', 0
MsgHttpNoSend   db 'REQUEST WAS NOT ACKNOWLEDGED', 0
MsgHttpUsage    db 'USAGE: GET <HOST OR IP> [PATH]', 0
MsgTcpUsage     db 'USAGE: TCP <IP> <PORT>', 0

MsgPingTo       db 'PINGING 10.0.2.2 WITH 32 BYTES OF DATA:', 0
MsgPingOk       db 'REPLY FROM 10.0.2.2   SEQ=', 0
MsgPingLost     db 'REQUEST TIMED OUT.', 0
MsgPingStat     db 'RECEIVED', 0
MsgPingOf4      db 'OF 4 REPLIES.', 0
MsgNoArp        db 'CANNOT RESOLVE GATEWAY MAC (ARP FAILED).', 0
PciNetBus       dd 0
PciNetDev       dd 0
PciNetFn        dd 0
PciNetVendor    dd 0
PciNetDevice    dd 0
PciNetIoBase    dd 0            ; базовий порт вводу-виводу (BAR0)
PciNetMmio      dd 0            ; або адреса в пам'яті, якщо BAR0 такий
PciNetIrq       dd 0            ; лінія переривання

MsgPciHdr       db 'BUS:DEV.FN  VENDOR:DEVICE  CLASS', 0
PciColon        db ':', 0
PciDot          db '.', 0
PciIoTag        db 'IO=', 0
PciIrqTag       db 'IRQ=', 0
PciClsOther     db 'DEVICE', 0
PciClsStorage   db 'STORAGE', 0
PciClsNet       db 'NETWORK', 0
PciClsVga       db 'DISPLAY', 0
PciClsBridge    db 'BRIDGE', 0
PciClsSerial    db 'USB/SERIAL', 0
MsgNoNet        db 'NO NETWORK CONTROLLER FOUND.', 0
MsgNetOk        db 'NETWORK CONTROLLER READY FOR DRIVER.', 0
align 8
FdTable         rb MAX_FD * FD_ENT   ; таблиця відкритих файлів
CmdArgs         rb 128               ; хвіст командного рядка для RUN
FATSectorBuffer rb 512          
FileBuffer      rb 512          
FileNameBuf     rb 12           
ParsedFileName  rb 12           
; Два імені для файлових syscall-ів: перейменування й копіювання
; тримають у руках обидва одночасно, а ParsedFileName один.
SysNameA        rb 12
SysNameB        rb 12

VolumeStartLBA  dd 0
DataRegionLBA   dd 0
SectorsPerCluster db 0
FAT1LBA         dd 0
RootCluster     dd 0
CurrentDirCluster dd 2          
TempSector      dd 0

; --- СИСТЕМА ПЕРЕРИВАНЬ ТА БАГАТОЗАДАЧНОСТІ ---
align 8
IDT:
    times 256 dq 0, 0           
IDTR:
    dw 256 * 16 - 1             
    dq 0                        

SystemTicks     dq 0            
CodeSegment     dw 0            

MAX_TASKS       equ 8
align 8
; --- ТАБЛИЦЯ ЗАДАЧ ---
; Слот 0 - ядро, воно готове завжди. Решта роздаються програмам.
; Стан потрібен саме масивом: доти, доки "чи є програма" було одним
; прапорцем, слот теж міг бути лише один.
align 8
TaskRSP         rq MAX_TASKS
TaskState       rb MAX_TASKS    ; 0 вільний, 1 готовий
align 8
AppTask         dq 0            ; слот, у якому зараз програма
BgTicks         dq 0            ; оберти фонової задачі
DemandPages     dq 0            ; сторінок купи виділено на вимогу
SpacesMade      dq 0            ; скільки адресних просторів створено
SpacesFreed     dq 0            ; скільки просторів повернуто в пул
PendingFree     dq 0            ; простір, який чекає на звільнення
SpawnPending    db 0            ; хтось попросив запуск через 37 і заснув
SpawnBusy       db 0            ; запуск триває: образ ще вантажиться з диска
align 8
SpawnBusyFor    dq 0            ; для кого саме він триває
align 8
SpawnParent     dq 0            ; хто просив запуск і чекає на дитину
align 8
TaskParent      rq MAX_TASKS    ; кого розбудити, коли задача завершиться
PendingCR3      dq 0            ; простір, підготовлений під запуск
LoadStartCluster dd 0          ; кластер образу, збережений до клонування
align 8
SpawnSwitched   db 0            ; чи перемикали простір під час запуску
AppFirstByte    db 0            ; перший байт образу, знятий у його просторі
align 8
ClonePml4       dq 0
ClonePdpt       dq 0
ClonePd0        dq 0
align 8
TaskCR3         rq MAX_TASKS    ; корінь таблиць кожної задачі
CurrentTask     dq 0                    

; --- ПОЛОТНО ЗАДАЧІ ---
;
; Досі blit завжди йшов прямо у фреймбуфер, і саме тому програма
; неминуче забирала екран собі: іншого місця, куди малювати, не
; існувало. Полотно - це місце. Якщо задачі його видано, ядро
; спрямовує її вивід туди, а оболонка потім кладе готове у вікно.
;
; Полотно видається при запуску й живе рівно стільки, скільки слот:
; SpawnAppTask виставляє його кожній задачі, тож наступна не може
; успадкувати чуже.
align 8
; Оголошено через times, а не rq: rq лише резервує місце, а нуль
; тут принциповий - TaskCanvas[0] належить ядру й мусить лишатися
; нулем, інакше blit самого ядра пішов би за випадковою адресою.
TaskCanvas:     times MAX_TASKS dq 0   ; буфер; 0 = малювати прямо в екран
align 8
TaskCanvasW:    times MAX_TASKS dd 0
TaskCanvasH:    times MAX_TASKS dd 0
TaskCanvasS:    times MAX_TASKS dd 0   ; крок рядка в пікселях
align 8
CanvasSeq       dd 0            ; скільки разів у полотно щось клали
align 8
PendingCanvas   dq 0            ; полотно, підготовлене під наступний запуск
PendingCanvasW  dd 0
PendingCanvasH  dd 0
PendingCanvasS  dd 0
align 8
KeysToChild     db 0            ; 1 = клавіші читає дитина, а не батько
align 8
KeysOwner       dq 0            ; хто віддав чергу своїй дитині
align 8
FsBusy          db 0            ; ядро зараз працює з диском
align 8
; Заголовок буфера тексту. Оболонка бере його адресу один раз
; (syscall 46) і далі читає поля прямо з пам'яті: вона спільна, тож
; питати ядро на кожному кадрі немає потреби.
AppTextHdr:
    dq  AppTextBase             ; +0  де лежить текст
    dd  0                       ; +8  скільки байтів
    dd  0                       ; +12 лічильник змін
align 8

; --- СТЕК ІСТОРІЇ ПАПОК ---
DirHistoryIndex   dd 0                  
DirHistoryStack:  times 64 dd 0         
MsgNoHistory      db 'NO HISTORY TO GO BACK', 0
MsgPressAnyKey  db '--- PROGRAM FINISHED. PRESS ANY KEY ---', 0

LoadedFileSize  dd 0            

RLE_Color       dd 0
RLE_Count       dd 0
VideoDataPtr    dq 0
VideoEOFPtr     dq 0
StartX          dd 0
StartY          dd 0
FramesRendered  dd 0

VendorID        db '            ', 0  

EdCols          dd 0            ; символів у рядку
EdRows          dd 0            ; рядків на екрані
EdLines         dd 0            ; скільки візуальних рядків у тексті
EdScroll        dd 0            ; перший видимий рядок
EdFollow        db 0            ; 1 = прокрутка їде за кареткою
EdExtended      db 0            ; отримано префікс 0xE0
EdReadOnly      db 0            ; 1 = вікно перегляду (OPEN), 0 = редактор (EDIT)
; EditorCursor тепер саме КАРЕТКА, а не кінець тексту. Довжина
; лежить окремо в EdLen. Раніше це була одна змінна, тому текст
; можна було дописувати лише в кінець, а стрілки рухали не каретку,
; а екран - редагувати всередині файлу було неможливо в принципі.
EditorCursor    dq 0            ; позиція каретки, 0..EdLen
EdLen           dq 0            ; скільки байтів тексту в буфері
EdCaretRow      dd 0            ; візуальний рядок каретки
EdCaretCol      dd 0            ; візуальна колонка каретки
EdLineNo        dd 0            ; логічний рядок каретки, з одиниці
EdCol           dq 0            ; колонка при русі вгору-вниз
EdTmp           dq 0
EdGotoMode      db 0            ; 1 = введення номера рядка
EdGotoNum       dq 0
EdBinary        db 0            ; 1 = у файлі є нульові байти

; ==========================================================
; 11. ПЛАНУВАЛЬНИК ТА ПЕРЕРИВАННЯ (SCHEDULER & IDT)
; ==========================================================
; ==========================================================
; ПІДСИСТЕМА PCI
;
; Конфігураційний простір кожного пристрою (256 байт) доступний
; через два порти:
;     0xCF8 - сюди пишемо, ЩО хочемо прочитати
;     0xCFC - звідси читаємо результат
;
; Формат адреси для 0xCF8:
;   біт 31     = 1 (обов'язково, інакше запит ігнорується)
;   біти 23-16 = номер шини      (0..255)
;   біти 15-11 = номер пристрою  (0..31)
;   біти 10-8  = номер функції   (0..7)
;   біти 7-2   = номер регістра  (зміщення / 4)
;   біти 1-0   = 00 (читати можна лише вирівняними двословами)
;
; Якщо за адресою нікого немає, Vendor ID читається як 0xFFFF -
; шина просто не відповідає і на лініях лишаються одиниці.
; ==========================================================

; PciConfigRead - прочитати двослово з конфігураційного простору.
;   EBX = шина, ECX = пристрій, EDX = функція, EDI = зміщення
;   -> EAX = значення
PciConfigRead:
    push    rbx
    push    rcx
    push    rdx
    push    rdi

    ; Складаємо 32-бітну адресу за схемою вище
    and     ebx, 0xFF
    shl     ebx, 16                 ; шина у біти 23-16
    and     ecx, 0x1F
    shl     ecx, 11                 ; пристрій у біти 15-11
    and     edx, 0x07
    shl     edx, 8                  ; функція у біти 10-8
    and     edi, 0xFC               ; зміщення, вирівняне на 4

    mov     eax, 0x80000000         ; біт 31 - дозвіл доступу
    or      eax, ebx
    or      eax, ecx
    or      eax, edx
    or      eax, edi

    mov     dx, 0xCF8
    out     dx, eax                 ; кажемо, ЩО хочемо
    mov     dx, 0xCFC
    in      eax, dx                 ; забираємо значення

    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; PciConfigWrite - записати двослово. Аргументи ті самі,
; ESI = значення для запису.
PciConfigWrite:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    and     ebx, 0xFF
    shl     ebx, 16
    and     ecx, 0x1F
    shl     ecx, 11
    and     edx, 0x07
    shl     edx, 8
    and     edi, 0xFC
    mov     eax, 0x80000000
    or      eax, ebx
    or      eax, ecx
    or      eax, edx
    or      eax, edi
    mov     dx, 0xCF8
    out     dx, eax
    mov     eax, esi
    mov     dx, 0xCFC
    out     dx, eax
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; HexN - EAX -> CL шістнадцяткових цифр у [RDI], нуль-термінований.
; Потрібен, щоб друкувати 10EC:8139 замість 16 цифр HexToStr.
HexN:
    push    rax
    push    rbx
    push    rcx
    push    rdi
    movzx   ecx, cl
    test    ecx, ecx
    jz      .hn_done
    mov     ebx, ecx
    shl     ebx, 2
    mov     ecx, ebx                ; скільки бітів зсувати
    sub     ecx, 4
.hn_loop:
    mov     ebx, eax
    shr     ebx, cl
    and     ebx, 0x0F
    cmp     bl, 10
    jb      .hn_digit
    add     bl, 'A' - 10
    jmp     .hn_store
.hn_digit:
    add     bl, '0'
.hn_store:
    mov     [rdi], bl
    inc     rdi
    sub     ecx, 4
    jns     .hn_loop
.hn_done:
    mov     byte [rdi], 0
    pop     rdi
    pop     rcx
    pop     rbx
    pop     rax
    ret

; PciPrintHex - надрукувати EAX як CL цифр у позиції RCX,[CursorY]
PciPrintHex:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9
    push    r10
    mov     r10, rcx                ; зберігаємо X
    mov     cl, dl                  ; DL = скільки цифр
    lea     rdi, [PciBuf]
    call    HexN
    mov     rcx, r10
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_TEXT
    call    DrawString
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; ScanPCI - обійти шину і показати всі знайдені пристрої.
; Заразом запам'ятовує першу знайдену мережеву карту -
; вона знадобиться драйверу на наступному етапі.
; ==========================================================
; ScanPciQuiet - знайти мережеву карту, нічого не друкуючи.
; Потрібно, щоб NETINIT працював без попереднього виклику PCI.
ScanPciQuiet:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    mov     dword [PciNetFound], 0
    xor     r12d, r12d
.sq_bus:
    xor     r13d, r13d
.sq_dev:
    xor     r14d, r14d
.sq_fn:
    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    xor     edi, edi
    call    PciConfigRead
    cmp     ax, 0xFFFF
    je      .sq_next_fn
    mov     esi, eax

    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    mov     edi, 0x08
    call    PciConfigRead
    shr     eax, 24
    cmp     al, 0x02                ; мережевий контролер?
    jne     .sq_next_fn
    cmp     dword [PciNetFound], 0
    jne     .sq_next_fn

    mov     dword [PciNetFound], 1
    mov     [PciNetBus], r12d
    mov     [PciNetDev], r13d
    mov     [PciNetFn],  r14d
    mov     eax, esi
    and     eax, 0xFFFF
    mov     [PciNetVendor], eax
    mov     eax, esi
    shr     eax, 16
    mov     [PciNetDevice], eax

    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    mov     edi, 0x10
    call    PciConfigRead
    test    eax, 1
    jz      .sq_bar_mem
    and     eax, 0xFFFFFFFC
    mov     [PciNetIoBase], eax
    jmp     .sq_bar_done
.sq_bar_mem:
    and     eax, 0xFFFFFFF0
    mov     [PciNetMmio], eax
.sq_bar_done:
    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    mov     edi, 0x3C
    call    PciConfigRead
    and     eax, 0xFF
    mov     [PciNetIrq], eax

.sq_next_fn:
    inc     r14d
    cmp     r14d, 8
    jb      .sq_fn
    inc     r13d
    cmp     r13d, 32
    jb      .sq_dev
    inc     r12d
    cmp     r12d, PCI_MAX_BUS
    jb      .sq_bus
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

ScanPCI:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13
    push    r14

    mov     dword [PciNetFound], 0

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPciHdr]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    xor     r12d, r12d              ; R12 = шина
.bus_loop:
    xor     r13d, r13d              ; R13 = пристрій
.dev_loop:
    xor     r14d, r14d              ; R14 = функція
.fn_loop:
    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    xor     edi, edi                ; регістр 0x00: Vendor + Device
    call    PciConfigRead
    cmp     ax, 0xFFFF              ; 0xFFFF = пристрою немає
    je      .next_fn

    mov     esi, eax                ; ESI = Vendor|Device на весь час

    ; --- Виводимо адресу у форматі ШИНА:ПРИСТРІЙ.ФУНКЦІЯ ---
    mov     eax, r12d
    mov     rcx, 10
    mov     dl, 2
    call    PciPrintHex
    mov     rcx, 28
    mov     rdx, [CursorY]
    lea     r8, [PciColon]
    mov     r9d, COL_DIM
    call    DrawString
    mov     eax, r13d
    mov     rcx, 37
    mov     dl, 2
    call    PciPrintHex
    mov     rcx, 55
    mov     rdx, [CursorY]
    lea     r8, [PciDot]
    mov     r9d, COL_DIM
    call    DrawString
    mov     eax, r14d
    mov     rcx, 64
    mov     dl, 1
    call    PciPrintHex

    ; --- Vendor:Device ---
    mov     eax, esi
    and     eax, 0xFFFF             ; молодші 16 біт = Vendor
    mov     rcx, 90
    mov     dl, 4
    call    PciPrintHex
    mov     rcx, 126
    mov     rdx, [CursorY]
    lea     r8, [PciColon]
    mov     r9d, COL_DIM
    call    DrawString
    mov     eax, esi
    shr     eax, 16                 ; старші 16 біт = Device
    mov     rcx, 135
    mov     dl, 4
    call    PciPrintHex

    ; --- Клас пристрою (регістр 0x08, старший байт) ---
    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    mov     edi, 0x08
    call    PciConfigRead
    shr     eax, 24                 ; байт класу
    ; ВИПРАВЛЕНО: раніше клас лежав у R8, але нижче йде
    ; 'push r9 / pop r8' для друку назви класу — і R8 затирався
    ; адресою рядка. Через це перевірка 'cmp r8b, 2' завжди хибила,
    ; і ресурси мережевої карти не зберігались.
    mov     [PciClass], eax

    ; підписуємо найпоширеніші класи словами
    lea     r9, [PciClsOther]
    cmp     al, 0x01
    jne     .not_stor
    lea     r9, [PciClsStorage]
.not_stor:
    cmp     al, 0x02
    jne     .not_net
    lea     r9, [PciClsNet]
.not_net:
    cmp     al, 0x03
    jne     .not_vga
    lea     r9, [PciClsVga]
.not_vga:
    cmp     al, 0x06
    jne     .not_bridge
    lea     r9, [PciClsBridge]
.not_bridge:
    cmp     al, 0x0C
    jne     .not_serial
    lea     r9, [PciClsSerial]
.not_serial:

    mov     rcx, 180
    mov     rdx, [CursorY]
    push    r9
    pop     r8
    mov     r9d, COL_TEXT
    call    DrawString

    ; --- Якщо це мережевий контролер - запам'ятовуємо ---
    cmp     byte [PciClass], 0x02
    jne     .not_network
    cmp     dword [PciNetFound], 0
    jne     .not_network            ; беремо тільки першу карту

    mov     dword [PciNetFound], 1
    mov     [PciNetBus], r12d
    mov     [PciNetDev], r13d
    mov     [PciNetFn],  r14d
    mov     eax, esi
    and     eax, 0xFFFF
    mov     [PciNetVendor], eax
    mov     eax, esi
    shr     eax, 16
    mov     [PciNetDevice], eax

    ; BAR0 (регістр 0x10). Молодший біт = 1 означає, що це порти
    ; вводу-виводу, а не пам'ять; сама адреса - у бітах 31-2.
    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    mov     edi, 0x10
    call    PciConfigRead
    test    eax, 1
    jz      .bar_mem
    and     eax, 0xFFFFFFFC
    mov     [PciNetIoBase], eax
    jmp     .bar_done
.bar_mem:
    and     eax, 0xFFFFFFF0
    mov     [PciNetMmio], eax
.bar_done:

    ; Interrupt Line - регістр 0x3C, молодший байт
    mov     ebx, r12d
    mov     ecx, r13d
    mov     edx, r14d
    mov     edi, 0x3C
    call    PciConfigRead
    and     eax, 0xFF
    mov     [PciNetIrq], eax

    ; Показуємо ресурси карти в тому ж рядку
    mov     rcx, 300
    mov     rdx, [CursorY]
    lea     r8, [PciIoTag]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     eax, [PciNetIoBase]
    mov     rcx, 330
    mov     dl, 4
    call    PciPrintHex
    mov     rcx, 380
    mov     rdx, [CursorY]
    lea     r8, [PciIrqTag]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     eax, [PciNetIrq]
    mov     rcx, 420
    mov     dl, 2
    call    PciPrintHex
.not_network:

    call    NewLine

    ; --- Чи є в пристрою інші функції? ---
    ; Регістр 0x0C, байт Header Type. Біт 7 = багатофункційний.
    test    r14d, r14d
    jnz     .next_fn                ; перевіряємо лише на функції 0
    mov     ebx, r12d
    mov     ecx, r13d
    xor     edx, edx
    mov     edi, 0x0C
    call    PciConfigRead
    shr     eax, 16
    test    al, 0x80
    jz      .next_dev               ; однофункційний - решту не чіпаємо

.next_fn:
    inc     r14d
    cmp     r14d, 8
    jb      .fn_loop
.next_dev:
    inc     r13d
    cmp     r13d, 32
    jb      .dev_loop
    inc     r12d
    cmp     r12d, PCI_MAX_BUS
    jb      .bus_loop

    ; --- Підсумок ---
    cmp     dword [PciNetFound], 0
    jne     .have_net
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNoNet]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .scan_done
.have_net:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetOk]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
.scan_done:
    pop     r14
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret


; ==========================================================
; ДРАЙВЕР МЕРЕЖЕВОЇ КАРТИ RTL8139
;
; Уся взаємодія - через порти вводу-виводу, починаючи від
; базової адреси BAR0, яку ми дізналися при скануванні PCI.
; Тобто регістр CR лежить за адресою [PciNetIoBase + 0x37].
;
; ЧОМУ САМЕ RTL8139: він працює через порти, а не через
; відображену пам'ять, і має ОДИН суцільний кільцевий буфер
; прийому замість дескрипторних кілець, як в e1000. Для
; першого драйвера це вдвічі менше коду.
;
; ВАЖЛИВО ПРО ПАМ'ЯТЬ: у нас немає пейджингу, UEFI лишив
; identity mapping - тому фізична адреса дорівнює віртуальній
; і буфер можна віддати карті напряму, без трансляції.
; Карта адресує DMA лише 32 бітами, а наші буфери на 112 МБ -
; влазить із запасом.
; ==========================================================

; --- Регістри RTL8139 (зміщення від бази) ---
RTL_IDR0        equ 0x00        ; MAC-адреса, 6 байт, тільки читання
RTL_TSD0        equ 0x10        ; статус передачі, 4 штуки по 4 байти
RTL_TSAD0       equ 0x20        ; адреси буферів передачі
RTL_RBSTART     equ 0x30        ; адреса кільцевого буфера прийому
RTL_CR          equ 0x37        ; команди
RTL_CAPR        equ 0x38        ; докуди ми прочитали буфер
RTL_CBR         equ 0x3A        ; докуди карта записала
RTL_IMR         equ 0x3C        ; які події сигналізувати
RTL_ISR         equ 0x3E        ; які події сталися
RTL_TCR         equ 0x40        ; налаштування передачі
RTL_RCR         equ 0x44        ; налаштування прийому
RTL_CONFIG1     equ 0x52        ; живлення

; Біти регістра CR
RTL_CR_RST      equ 0x10        ; скидання чіпа
RTL_CR_RE       equ 0x08        ; дозволити прийом
RTL_CR_TE       equ 0x04        ; дозволити передачу
RTL_CR_BUFE     equ 0x01        ; 1 = буфер прийому порожній

; ==========================================================
; NetInit - підготувати карту до роботи.
; -> CF=0 успіх, CF=1 помилка (карти немає або не той чіп)
; ==========================================================
NetInit:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi

    mov     byte [NetReady], 0

    ; --- Чи знайшли ми взагалі карту при скануванні PCI? ---
    cmp     dword [PciNetFound], 0
    je      .ni_fail
    cmp     dword [PciNetVendor], 0x10EC    ; Realtek
    jne     .ni_fail
    cmp     dword [PciNetDevice], 0x8139
    jne     .ni_fail
    cmp     dword [PciNetIoBase], 0
    je      .ni_fail

    ; --- Дозволяємо карті бути власником шини ---
    ; Без цього DMA не працює: карта фізично не зможе писати
    ; в нашу пам'ять, і буфер прийому завжди буде порожній.
    ; Регістр 0x04 конфігураційного простору:
    ;   біт 0 = доступ до портів вводу-виводу
    ;   біт 2 = Bus Master (право самостійно писати в пам'ять)
    mov     ebx, [PciNetBus]
    mov     ecx, [PciNetDev]
    mov     edx, [PciNetFn]
    mov     edi, 0x04
    call    PciConfigRead
    or      eax, 0x05
    mov     esi, eax
    mov     ebx, [PciNetBus]
    mov     ecx, [PciNetDev]
    mov     edx, [PciNetFn]
    mov     edi, 0x04
    call    PciConfigWrite

    ; --- Вмикаємо живлення ---
    ; Після ввімкнення чіп у сплячому режимі; нуль у CONFIG1
    ; переводить його в робочий.
    mov     edx, [PciNetIoBase]
    add     edx, RTL_CONFIG1
    xor     al, al
    out     dx, al

    ; --- Скидання ---
    ; Ставимо біт RST і чекаємо, доки карта сама його не зніме.
    mov     edx, [PciNetIoBase]
    add     edx, RTL_CR
    mov     al, RTL_CR_RST
    out     dx, al
    mov     ecx, 1000000            ; стеля очікування, щоб не зависнути
.ni_wait_reset:
    in      al, dx
    test    al, RTL_CR_RST
    jz      .ni_reset_done          ; біт знявся - скидання завершено
    dec     ecx
    jnz     .ni_wait_reset
    jmp     .ni_fail                ; карта не відповіла
.ni_reset_done:

    ; --- Віддаємо карті буфер прийому ---
    ; Розмір просимо 8 КБ, а виділяємо 8К+16+1500. Причина в тому,
    ; що при WRAP=1 карта НЕ обриває кадр на межі буфера, а спокійно
    ; пише за його кінець. Якщо не лишити запасу - затре чужу пам'ять.
    mov     edx, [PciNetIoBase]
    add     edx, RTL_RBSTART
    mov     eax, NetRxBuffer
    out     dx, eax

    ; --- Які події карта має відмічати в ISR ---
    ; Ми працюємо полінгом (як клавіатура й миша), тобто самі
    ; заглядаємо в ISR. IMR лишаємо нульовим, щоб карта не смикала
    ; лінію переривання, яку ми все одно не обробляємо.
    mov     edx, [PciNetIoBase]
    add     edx, RTL_IMR
    xor     ax, ax
    out     dx, ax

    ; --- Що приймати ---
    ;   біт 0 AAP  - усі кадри підряд (promiscuous)
    ;   біт 1 APM  - адресовані нашій MAC
    ;   біт 2 AM   - групові
    ;   біт 3 AB   - широкомовні (потрібні для ARP!)
    ;   біт 7 WRAP - не загортати кадр на межі буфера
    ;   біти 11-12 = 00 - розмір буфера 8 КБ + 16
    mov     edx, [PciNetIoBase]
    add     edx, RTL_RCR
    mov     eax, 0x0000008F
    out     dx, eax

    ; --- Вмикаємо прийом і передачу ---
    mov     edx, [PciNetIoBase]
    add     edx, RTL_CR
    mov     al, RTL_CR_RE or RTL_CR_TE
    out     dx, al

    ; --- Читаємо MAC-адресу карти ---
    mov     edx, [PciNetIoBase]
    lea     rdi, [NetMac]
    xor     ecx, ecx
.ni_mac:
    in      al, dx
    mov     [rdi], al
    inc     rdi
    inc     edx
    inc     ecx
    cmp     ecx, 6
    jb      .ni_mac

    mov     dword [NetRxPos], 0
    mov     dword [NetTxSlot], 0
    mov     byte [NetReady], 1
    clc
    jmp     .ni_exit
.ni_fail:
    stc
.ni_exit:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetPrintMac - вивести MAC у вигляді XX:XX:XX:XX:XX:XX
; ==========================================================
NetPrintMac:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13
    lea     r12, [NetMac]
    xor     r13d, r13d
    mov     rcx, 120                ; X першого байта
.pm_loop:
    movzx   eax, byte [r12 + r13]
    mov     dl, 2
    call    PciPrintHex
    add     rcx, 18
    inc     r13d
    cmp     r13d, 6
    jae     .pm_done
    ; двокрапка між байтами
    push    rcx
    mov     rdx, [CursorY]
    lea     r8, [PciColon]
    mov     r9d, COL_DIM
    call    DrawString
    pop     rcx
    add     rcx, 9
    jmp     .pm_loop
.pm_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; CmdNetInit - обробник команди NETINIT
; ==========================================================
NetInitCommand:
    push    rax
    push    rcx
    push    rdx
    push    r8
    push    r9

    ; Якщо PCI ще не сканували - робимо це мовчки зараз,
    ; інакше NetInit не знатиме адреси карти.
    cmp     dword [PciNetFound], 0
    jne     .nc_have_pci
    call    ScanPciQuiet
.nc_have_pci:

    call    NetInit
    jc      .nc_fail

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetMac]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NetPrintMac
    call    NewLine

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetUp]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    jmp     .nc_done

.nc_fail:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.nc_done:
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    pop     rax
    ret


; ==========================================================
; ПЕРЕДАЧА КАДРУ
;
; Карта має ЧОТИРИ буфери передачі, які використовуються по колу.
; На кожен дві пари регістрів:
;   TSAD0..3 (0x20+) - сюди пишемо адресу буфера
;   TSD0..3  (0x10+) - статус і розмір
;
; Механіка: пишемо адресу в TSAD, потім розмір у TSD - і САМ ФАКТ
; запису розміру запускає передачу. Окремої команди 'відправ' немає.
;
; Біт OWN (0x2000) у TSD: поки карта передає - нуль, коли DMA
; завершився - одиниця.
; ==========================================================

; NetSend - відправити кадр.
;   RSI = дані, ECX = довжина в байтах
;   -> CF=0 успіх, CF=1 карта не готова
NetSend:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    cmp     byte [NetReady], 0
    je      .ns_fail
    test    ecx, ecx
    jz      .ns_fail
    cmp     ecx, NetTxSize
    ja      .ns_fail

    mov     r10d, [NetTxSlot]       ; який буфер зараз наш
    and     r10d, 3

    ; --- Копіюємо кадр у буфер передачі ---
    mov     eax, NetTxSize
    imul    eax, r10d
    add     eax, NetTxBuffer
    mov     r11d, eax               ; R11 = адреса нашого буфера

    mov     rdi, r11
    push    rcx
    ; спершу зануляємо 60 байт: Ethernet вимагає мінімум 60,
    ; коротші кадри доповнюємо нулями, інакше карта їх відкине
    mov     rcx, 60
    xor     al, al
    cld
    rep     stosb
    pop     rcx

    mov     rdi, r11
    push    rcx
    cld
    rep     movsb                   ; RSI -> RDI, ECX байт
    pop     rcx

    ; довжина не менша за 60
    cmp     ecx, 60
    jae     .ns_len_ok
    mov     ecx, 60
.ns_len_ok:

    ; --- Адреса буфера в TSAD ---
    mov     edx, [PciNetIoBase]
    add     edx, RTL_TSAD0
    mov     eax, r10d
    shl     eax, 2                  ; кожен регістр по 4 байти
    add     edx, eax
    mov     eax, r11d
    out     dx, eax

    ; --- Розмір у TSD: цей запис і запускає передачу ---
    mov     edx, [PciNetIoBase]
    add     edx, RTL_TSD0
    mov     eax, r10d
    shl     eax, 2
    add     edx, eax
    mov     eax, ecx
    and     eax, 0x1FFF             ; біти 12-0 = довжина
    out     dx, eax

    ; --- Чекаємо, доки карта забере дані (біт OWN) ---
    mov     ecx, 2000000
.ns_wait:
    in      eax, dx
    test    eax, 0x2000             ; OWN = 1 -> DMA завершено
    jnz     .ns_sent
    dec     ecx
    jnz     .ns_wait
    jmp     .ns_fail
.ns_sent:

    inc     dword [NetTxSlot]       ; наступного разу інший буфер
    clc
    jmp     .ns_exit
.ns_fail:
    stc
.ns_exit:
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; ПРИЙОМ КАДРУ
;
; Буфер кільцевий. CBR каже, докуди дописала карта; наша позиція
; читання лежить у NetRxPos. Кожен кадр має заголовок:
;     [2 байти статус][2 байти довжина][дані...]
; Довжина включає 4 байти CRC, які нам не потрібні.
;
; ПАСТКА: у CAPR завжди пишеться позиція МІНУС 16. Це апаратна
; особливість чіпа, не помилка. Якщо записати справжнє зміщення,
; карта почне псувати буфер.
; ==========================================================

; NetPoll - забрати один кадр, якщо він є.
;   RDI = куди покласти, ECX = розмір приймача
;   -> EAX = довжина кадру (0 = нічого немає)
NetPoll:
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    xor     eax, eax
    cmp     byte [NetReady], 0
    je      .np_exit

    ; Біт BUFE у CR: 1 = буфер порожній, читати нічого
    mov     edx, [PciNetIoBase]
    add     edx, RTL_CR
    in      al, dx
    test    al, RTL_CR_BUFE
    jnz     .np_empty

    ; --- Заголовок кадру за поточною позицією ---
    mov     r10d, [NetRxPos]
    and     r10d, 0x1FFF            ; позиція в межах 8 КБ
    mov     esi, NetRxBuffer
    add     esi, r10d

    movzx   ebx, word [rsi]         ; статус
    test    bx, 1                   ; біт 0 = кадр прийнято без помилок
    jz      .np_bad
    movzx   r11d, word [rsi + 2]    ; довжина разом із CRC
    cmp     r11d, 4
    jbe     .np_bad
    cmp     r11d, 2000
    ja      .np_bad
    sub     r11d, 4                 ; відкидаємо CRC

    ; --- Копіюємо дані викликачу ---
    mov     eax, r11d
    cmp     eax, ecx
    jbe     .np_fits
    mov     eax, ecx                ; не більше, ніж просили
.np_fits:
    mov     [NetLastLen], eax       ; запам'ятовуємо, скільки віддамо
    add     rsi, 4                  ; пропускаємо заголовок
    mov     ecx, eax
    cld
    rep     movsb

    ; --- Просуваємо позицію читання ---
    ; Кадр займає 4 байти заголовка + дані + CRC, і все це
    ; вирівнюється вгору до 4 байтів.
    mov     r10d, [NetRxPos]
    add     r10d, r11d
    add     r10d, 4 + 4             ; заголовок + CRC
    add     r10d, 3
    and     r10d, not 3             ; вирівнювання
    and     r10d, 0x1FFF
    mov     [NetRxPos], r10d

    ; --- Повідомляємо карті, докуди ми прочитали ---
    mov     edx, [PciNetIoBase]
    add     edx, RTL_CAPR
    mov     r11d, r10d
    sub     r11d, 16                ; ОБОВ'ЯЗКОВЕ зміщення (див. вище)
    mov     ax, r11w
    out     dx, ax

    ; Скидаємо позначку ROK у ISR (записом одиниці)
    mov     edx, [PciNetIoBase]
    add     edx, RTL_ISR
    mov     ax, 1
    out     dx, ax
    ; Повертаємо довжину, збережену до того, як AX пішов у CAPR/ISR
    mov     eax, [NetLastLen]
    jmp     .np_exit

.np_bad:
    ; Кадр зіпсований - найпростіше перезапустити приймач
    mov     dword [NetRxPos], 0
    mov     edx, [PciNetIoBase]
    add     edx, RTL_CAPR
    mov     ax, 0xFFF0
    out     dx, ax
.np_empty:
    xor     eax, eax
.np_exit:
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ==========================================================
; NETTEST - зібрати ARP-запит, відправити і дочекатися відповіді.
;
; У режимі 'user' QEMU емулює шлюз 10.0.2.2 і відповідає на ARP.
; Якщо ми побачимо його MAC - працює ВЕСЬ ланцюг: передача,
; прийом, кільцевий буфер і розбір кадру.
;
; Структура ARP-запиту (42 байти):
;   0..5   MAC отримувача = FF:FF:FF:FF:FF:FF (широкомовно)
;   6..11  наша MAC
;   12..13 тип 0x0806 = ARP
;   14..15 тип мережі 0x0001 = Ethernet
;   16..17 тип протоколу 0x0800 = IPv4
;   18     довжина MAC = 6
;   19     довжина IP = 4
;   20..21 операція 0x0001 = запит
;   22..27 наша MAC
;   28..31 наша IP
;   32..37 MAC, яку шукаємо (нулі)
;   38..41 IP, яку шукаємо
;
; УВАГА: у мережі числа пишуться старшим байтом уперед
; (big-endian), а x86 зберігає навпаки - тому всі двобайтові
; поля задані вручну по байтах.
; ==========================================================
NetTestCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12

    cmp     byte [NetReady], 0
    jne     .nt_ready
    call    ScanPciQuiet
    call    NetInit
    jc      .nt_nocard
.nt_ready:

    ; --- Складаємо кадр ---
    lea     rdi, [NetFrame]
    mov     rcx, 64
    xor     al, al
    cld
    rep     stosb

    lea     rdi, [NetFrame]
    ; отримувач: широкомовна адреса
    mov     rcx, 6
    mov     al, 0xFF
    rep     stosb
    ; відправник: ми
    lea     rsi, [NetMac]
    mov     rcx, 6
    rep     movsb
    ; тип кадру 0x0806 (ARP), старшим байтом уперед
    mov     byte [rdi], 0x08
    mov     byte [rdi + 1], 0x06

    lea     rdi, [NetFrame + 14]
    mov     byte [rdi + 0], 0x00    ; тип мережі: Ethernet
    mov     byte [rdi + 1], 0x01
    mov     byte [rdi + 2], 0x08    ; тип протоколу: IPv4
    mov     byte [rdi + 3], 0x00
    mov     byte [rdi + 4], 6       ; довжина MAC
    mov     byte [rdi + 5], 4       ; довжина IP
    mov     byte [rdi + 6], 0x00    ; операція: запит
    mov     byte [rdi + 7], 0x01

    ; наша MAC і наша IP
    lea     rdi, [NetFrame + 22]
    lea     rsi, [NetMac]
    mov     rcx, 6
    rep     movsb
    lea     rsi, [NetMyIp]
    mov     rcx, 4
    rep     movsb
    ; шукана MAC лишається нулями, далі шукана IP
    lea     rdi, [NetFrame + 38]
    lea     rsi, [NetGwIp]
    mov     rcx, 4
    rep     movsb

    ; --- Відправляємо ---
    lea     rsi, [NetFrame]
    mov     ecx, 42
    call    NetSend
    jc      .nt_sendfail

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgArpSent]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine

    ; --- Чекаємо відповідь ---
    mov     r12d, 3000000
.nt_wait:
    lea     rdi, [NetRxFrame]
    mov     ecx, 1600
    call    NetPoll
    test    eax, eax
    jnz     .nt_got
    dec     r12d
    jnz     .nt_wait

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgArpNone]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .nt_done

.nt_got:
    ; Чи це справді ARP-відповідь? Тип кадру 0x0806, операція 0x0002
    cmp     byte [NetRxFrame + 12], 0x08
    jne     .nt_other
    cmp     byte [NetRxFrame + 13], 0x06
    jne     .nt_other
    cmp     byte [NetRxFrame + 21], 0x02
    jne     .nt_other

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgArpGw]
    mov     r9d, COL_TEXT
    call    DrawString

    ; MAC відправника лежить у полі 22..27
    lea     rsi, [NetRxFrame + 22]
    lea     rdi, [NetGwMac]
    mov     rcx, 6
    cld
    rep     movsb
    lea     r12, [NetGwMac]
    call    NetPrintMacAt
    call    NewLine

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgArpOk]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    jmp     .nt_done

.nt_other:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgArpOther]
    mov     r9d, COL_DIM
    call    DrawString
    call    NewLine
    jmp     .nt_done

.nt_sendfail:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTxFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .nt_done
.nt_nocard:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.nt_done:
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; NetPrintMacAt - надрукувати 6 байт за адресою R12
NetPrintMacAt:
    push    rax
    push    rcx
    push    rdx
    push    r8
    push    r9
    push    r13
    xor     r13d, r13d
    mov     rcx, 200
.pma_loop:
    movzx   eax, byte [r12 + r13]
    mov     dl, 2
    call    PciPrintHex
    add     rcx, 18
    inc     r13d
    cmp     r13d, 6
    jae     .pma_done
    push    rcx
    mov     rdx, [CursorY]
    lea     r8, [PciColon]
    mov     r9d, COL_DIM
    call    DrawString
    pop     rcx
    add     rcx, 9
    jmp     .pma_loop
.pma_done:
    pop     r13
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    pop     rax
    ret


; ==========================================================
; КОНТРОЛЬНА СУМА (RFC 1071)
;
; Складаємо дані як 16-бітні слова у 32-бітний акумулятор,
; потім згортаємо переноси зі старшої половини в молодшу
; і інвертуємо результат.
;
; ВАЖЛИВО: порядок байтів тут НЕ МАЄ ЗНАЧЕННЯ. Додавання
; симетричне, тож читаємо слова так, як вони лежать у пам'яті,
; і результат кладемо так само - вийде правильно. Це стандартний
; прийом, а не хитрість.
;
; RSI = дані, ECX = довжина -> AX = готова сума
; ==========================================================
NetChecksum:
    push    rbx
    push    rcx
    push    rsi
    xor     eax, eax
    xor     ebx, ebx
.cs_loop:
    cmp     ecx, 2
    jb      .cs_tail
    movzx   ebx, word [rsi]
    add     eax, ebx
    add     rsi, 2
    sub     ecx, 2
    jmp     .cs_loop
.cs_tail:
    test    ecx, ecx
    jz      .cs_fold
    movzx   ebx, byte [rsi]     ; непарний останній байт
    add     eax, ebx
.cs_fold:
    mov     ebx, eax
    shr     ebx, 16
    and     eax, 0xFFFF
    add     eax, ebx            ; згортаємо переноси
    mov     ebx, eax
    shr     ebx, 16
    add     eax, ebx            ; і ще раз, якщо виник новий перенос
    not     eax
    and     eax, 0xFFFF
    pop     rsi
    pop     rcx
    pop     rbx
    ret

; ==========================================================
; NetBuildEth - заповнити заголовок Ethernet у [NetFrame].
;   RSI = MAC отримувача, BX = тип кадру (вже big-endian)
; ==========================================================
NetBuildEth:
    push    rcx
    push    rsi
    push    rdi
    lea     rdi, [NetFrame]
    mov     rcx, 6
    cld
    rep     movsb                   ; отримувач
    lea     rsi, [NetMac]
    mov     rcx, 6
    rep     movsb                   ; ми
    mov     [rdi], bx               ; тип кадру
    pop     rdi
    pop     rsi
    pop     rcx
    ret

; ==========================================================
; NetSendArpReply - відповісти на чужий ARP-запит.
; Вхідний кадр лежить у NetRxFrame.
;
; Без цього нас у мережі просто не бачать: хост не знатиме
; нашу MAC і не зможе надіслати нам жодного пакета.
; ==========================================================
NetSendArpReply:
    push    rax
    push    rbx
    push    rcx
    push    rsi
    push    rdi

    ; Ethernet: відповідаємо тому, хто питав
    lea     rsi, [NetRxFrame + 6]   ; MAC відправника запиту
    mov     bx, 0x0608              ; 0x0806 у пам'яті лежить як 08 06
    call    NetBuildEth

    lea     rdi, [NetFrame + 14]
    mov     byte [rdi + 0], 0x00    ; Ethernet
    mov     byte [rdi + 1], 0x01
    mov     byte [rdi + 2], 0x08    ; IPv4
    mov     byte [rdi + 3], 0x00
    mov     byte [rdi + 4], 6
    mov     byte [rdi + 5], 4
    mov     byte [rdi + 6], 0x00    ; операція 2 = відповідь
    mov     byte [rdi + 7], 0x02

    ; відправник відповіді - ми
    lea     rdi, [NetFrame + 22]
    lea     rsi, [NetMac]
    mov     rcx, 6
    cld
    rep     movsb
    lea     rsi, [NetMyIp]
    mov     rcx, 4
    rep     movsb
    ; отримувач - той, хто питав
    lea     rsi, [NetRxFrame + 22]
    mov     rcx, 10                 ; його MAC (6) + його IP (4)
    rep     movsb

    lea     rsi, [NetFrame]
    mov     ecx, 42
    call    NetSend

    inc     dword [NetArpReplies]
    pop     rdi
    pop     rsi
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetSendIcmp - зібрати й відправити ICMP-пакет.
;   AL  = тип (8 = echo request, 0 = echo reply)
;   RSI = MAC отримувача
;   RDI = IP отримувача (4 байти)
;   BX  = ідентифікатор, CX = номер послідовності
;
; Структура: Ethernet(14) + IPv4(20) + ICMP(8) + дані(32)
; ==========================================================
NetSendIcmp:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12

    mov     r10b, al                ; тип ICMP
    mov     r11w, bx                ; ідентифікатор
    mov     r12w, cx                ; послідовність
    push    rdi                     ; IP отримувача знадобиться нижче

    mov     bx, 0x0008              ; 0x0800 у пам'яті = 08 00
    call    NetBuildEth

    ; --- IPv4, 20 байт ---
    lea     rdi, [NetFrame + 14]
    mov     byte [rdi + 0], 0x45    ; версія 4, довжина заголовка 5 слів
    mov     byte [rdi + 1], 0x00
    mov     byte [rdi + 2], 0x00    ; загальна довжина = 20 + 8 + 32 = 60
    mov     byte [rdi + 3], 60
    mov     ax, [NetIpId]
    mov     [rdi + 4], ax           ; ідентифікатор пакета
    inc     word [NetIpId]
    mov     byte [rdi + 6], 0x00
    mov     byte [rdi + 7], 0x00
    mov     byte [rdi + 8], 64      ; TTL
    mov     byte [rdi + 9], 1       ; протокол 1 = ICMP
    mov     word [rdi + 10], 0      ; сума рахується з нулем у цьому полі
    push    rdi
    lea     rsi, [NetMyIp]
    add     rdi, 12
    mov     rcx, 4
    cld
    rep     movsb                   ; наша IP
    pop     rdi
    pop     rsi                     ; IP отримувача (зі стеку вище)
    push    rsi
    push    rdi
    add     rdi, 16
    mov     rcx, 4
    rep     movsb
    pop     rdi
    pop     rsi

    ; контрольна сума заголовка IP
    push    rsi
    mov     rsi, rdi
    mov     ecx, 20
    call    NetChecksum
    mov     [rdi + 10], ax
    pop     rsi

    ; --- ICMP, 8 байт заголовка + 32 байти даних ---
    lea     rdi, [NetFrame + 34]
    mov     [rdi + 0], r10b         ; тип
    mov     byte [rdi + 1], 0       ; код
    mov     word [rdi + 2], 0       ; сума - поки нуль
    mov     [rdi + 4], r11w         ; ідентифікатор
    mov     [rdi + 6], r12w         ; послідовність

    ; наповнюємо дані впізнаваним візерунком
    push    rdi
    add     rdi, 8
    mov     ecx, 32
    mov     al, 'A'
.si_fill:
    mov     [rdi], al
    inc     rdi
    inc     al
    cmp     al, 'Z'
    jbe     .si_next
    mov     al, 'A'
.si_next:
    dec     ecx
    jnz     .si_fill
    pop     rdi

    ; сума ICMP рахується по ВСЬОМУ пакету, разом із даними
    mov     rsi, rdi
    mov     ecx, 40
    call    NetChecksum
    mov     [rdi + 2], ax

    ; --- Відправляємо: 14 + 20 + 40 = 74 байти ---
    lea     rsi, [NetFrame]
    mov     ecx, 74
    call    NetSend

    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetHandleFrame - розібрати прийнятий кадр і відреагувати.
; Кадр у NetRxFrame, EAX = його довжина.
;
; Це серце мережі: сюди приходить усе, що прийшло з дроту.
; ==========================================================
NetHandleFrame:
    push    rax
    push    rbx
    push    rcx
    push    rsi
    push    rdi

    cmp     eax, 42
    jb      .hf_done                ; заміле для чогось осмисленого

    ; --- Тип кадру у байтах 12-13 ---
    mov     al, [NetRxFrame + 12]
    mov     ah, [NetRxFrame + 13]

    cmp     al, 0x08
    jne     .hf_done
    cmp     ah, 0x06
    je      .hf_arp
    cmp     ah, 0x00
    je      .hf_ip
    jmp     .hf_done

; ---------- ARP ----------
.hf_arp:
    ; Нас цікавить лише запит (операція 1), адресований НАШІЙ IP
    cmp     byte [NetRxFrame + 20], 0x00
    jne     .hf_arp_reply_check
    cmp     byte [NetRxFrame + 21], 0x01
    jne     .hf_arp_reply_check

    ; чи шукана IP - наша?
    lea     rsi, [NetRxFrame + 38]
    lea     rdi, [NetMyIp]
    mov     rcx, 4
    cld
    repe    cmpsb
    jne     .hf_done
    call    NetSendArpReply
    jmp     .hf_done

.hf_arp_reply_check:
    ; ARP-відповідь - запам'ятовуємо MAC відправника
    cmp     byte [NetRxFrame + 21], 0x02
    jne     .hf_done
    lea     rsi, [NetRxFrame + 22]
    lea     rdi, [NetGwMac]
    mov     rcx, 6
    cld
    rep     movsb
    mov     byte [NetGwKnown], 1
    jmp     .hf_done

; ---------- IPv4 ----------
.hf_ip:
    ; Протокол лежить у байті 9 заголовка IP (тобто 14+9 = 23)
    cmp     byte [NetRxFrame + 23], 17  ; 17 = UDP
    je      .hf_udp
    cmp     byte [NetRxFrame + 23], 6   ; 6 = TCP
    je      .hf_tcp
    cmp     byte [NetRxFrame + 23], 1   ; 1 = ICMP
    jne     .hf_done

    ; Заголовок IP може бути довшим за 20 байт, якщо є опції.
    ; Його довжина - молодші 4 біти першого байта, у 32-бітних словах.
    movzx   ebx, byte [NetRxFrame + 14]
    and     ebx, 0x0F
    shl     ebx, 2                  ; * 4 = довжина в байтах
    add     ebx, 14                 ; + Ethernet
    lea     rsi, [NetRxFrame]
    add     rsi, rbx                ; RSI = початок ICMP

    mov     al, [rsi]
    cmp     al, 8                   ; echo request - треба відповісти
    je      .hf_echo_req
    cmp     al, 0                   ; echo reply - наш пінг повернувся
    je      .hf_echo_rep
    jmp     .hf_done

.hf_echo_rep:
    mov     byte [NetPingGot], 1
    jmp     .hf_done

; ---------- TCP ----------
.hf_tcp:
    call    NetHandleTcp
    jmp     .hf_done

; ---------- UDP ----------
.hf_udp:
    inc     dword [NetUdpCount]     ; діагностика: скільки UDP прийшло
    ; знову рахуємо довжину IP-заголовка, вона може бути не 20
    movzx   ebx, byte [NetRxFrame + 14]
    and     ebx, 0x0F
    shl     ebx, 2
    add     ebx, 14
    lea     rsi, [NetRxFrame]
    add     rsi, rbx                ; RSI = початок UDP

    ; запам'ятовуємо порт призначення останнього UDP-пакета
    movzx   eax, byte [rsi + 2]
    shl     eax, 8
    movzx   ebx, byte [rsi + 3]
    or      eax, ebx
    mov     [NetLastPort], eax

    ; DHCP приходить на порт 68 (0x0044), DNS - на наш 50000 (0xC350).
    ;
    ; ВИПРАВЛЕНО: раніше першою стояла перевірка 'старший байт порту = 0',
    ; і при невдачі одразу йшов вихід. Для DNS старший байт 0xC3, тому
    ; всі відповіді відсікались ще до порівняння з нашим портом.
    cmp     byte [rsi + 2], 0x00
    jne     .hf_chk_dns             ; не DHCP - пробуємо DNS
    cmp     byte [rsi + 3], 68
    je      .hf_dhcp
.hf_chk_dns:
    cmp     byte [rsi + 2], 0xC3    ; наш порт 50000 = 0xC350
    jne     .hf_done
    cmp     byte [rsi + 3], 0x50
    je      .hf_dns
    jmp     .hf_done
.hf_dhcp:
    add     rsi, 8                  ; пропускаємо заголовок UDP
    call    NetHandleDhcp
    jmp     .hf_done
.hf_dns:
    add     rsi, 8
    call    NetHandleDns
    jmp     .hf_done

.hf_echo_req:
    ; Відповідаємо тому, хто спитав. Ідентифікатор і послідовність
    ; беремо з запиту - так вимагає протокол.
    mov     bx, [rsi + 4]
    mov     cx, [rsi + 6]
    push    rbx
    push    rcx
    lea     rsi, [NetRxFrame + 6]   ; його MAC
    lea     rdi, [NetRxFrame + 26]  ; його IP (14 + 12)
    pop     rcx
    pop     rbx
    mov     al, 0                   ; тип 0 = echo reply
    call    NetSendIcmp
    inc     dword [NetPingsAnswered]

.hf_done:
    pop     rdi
    pop     rsi
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetPollBackground - викликається з головного циклу ядра.
; Завдяки цьому система відповідає на ARP і пінг у фоні,
; поки ти працюєш у консолі.
; ==========================================================
NetPollBackground:
    cmp     byte [NetReady], 0
    je      .pb_done
    push    rax
    push    rcx
    push    rdi
    lea     rdi, [NetRxFrame]
    mov     ecx, 1600
    call    NetPoll
    test    eax, eax
    jz      .pb_none
    call    NetHandleFrame
.pb_none:
    pop     rdi
    pop     rcx
    pop     rax
.pb_done:
    ret

; ==========================================================
; PingCommand - команда PING
; ==========================================================
PingCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13

    cmp     byte [NetReady], 0
    jne     .pg_ready
    call    ScanPciQuiet
    call    NetInit
    jc      .pg_nocard
.pg_ready:

    ; --- Спершу треба знати MAC шлюзу ---
    cmp     byte [NetGwKnown], 0
    jne     .pg_have_mac
    call    NetDoArp
    cmp     byte [NetGwKnown], 0
    je      .pg_noarp
.pg_have_mac:

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingTo]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine

    xor     r13d, r13d              ; лічильник відповідей
    mov     r12d, 1                 ; номер послідовності
.pg_loop:
    mov     byte [NetPingGot], 0
    mov     al, 8                   ; echo request
    lea     rsi, [NetGwMac]
    lea     rdi, [NetGwIp]
    mov     bx, 0x3412              ; ідентифікатор - будь-який
    mov     cx, r12w
    call    NetSendIcmp

    ; чекаємо відповідь
    mov     ecx, 2000000
.pg_wait:
    call    NetPollBackground
    cmp     byte [NetPingGot], 0
    jne     .pg_reply
    dec     ecx
    jnz     .pg_wait

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingLost]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .pg_next

.pg_reply:
    inc     r13d
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingOk]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     eax, r12d
    mov     rcx, 250
    mov     dl, 2
    call    PciPrintHex
    call    NewLine

.pg_next:
    inc     r12d
    cmp     r12d, 4                 ; чотири пакети, як у класичному ping
    jbe     .pg_loop

    ; --- Підсумок ---
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingStat]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     eax, r13d
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 92
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     rcx, 110
    mov     rdx, [CursorY]
    lea     r8, [MsgPingOf4]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    jmp     .pg_done

.pg_noarp:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNoArp]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .pg_done
.pg_nocard:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.pg_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; NetDoArp - дізнатися MAC шлюзу (тихо, без виводу)
NetDoArp:
    push    rax
    push    rbx
    push    rcx
    push    rsi
    push    rdi

    lea     rdi, [NetFrame]
    mov     rcx, 64
    xor     al, al
    cld
    rep     stosb
    lea     rdi, [NetFrame]
    mov     rcx, 6
    mov     al, 0xFF
    rep     stosb
    lea     rsi, [NetMac]
    mov     rcx, 6
    rep     movsb
    mov     byte [rdi], 0x08
    mov     byte [rdi + 1], 0x06
    lea     rdi, [NetFrame + 14]
    mov     byte [rdi + 0], 0x00
    mov     byte [rdi + 1], 0x01
    mov     byte [rdi + 2], 0x08
    mov     byte [rdi + 3], 0x00
    mov     byte [rdi + 4], 6
    mov     byte [rdi + 5], 4
    mov     byte [rdi + 6], 0x00
    mov     byte [rdi + 7], 0x01
    lea     rdi, [NetFrame + 22]
    lea     rsi, [NetMac]
    mov     rcx, 6
    rep     movsb
    lea     rsi, [NetMyIp]
    mov     rcx, 4
    rep     movsb
    lea     rdi, [NetFrame + 38]
    lea     rsi, [NetGwIp]
    mov     rcx, 4
    rep     movsb

    lea     rsi, [NetFrame]
    mov     ecx, 42
    call    NetSend

    mov     ecx, 2000000
.da_wait:
    call    NetPollBackground
    cmp     byte [NetGwKnown], 0
    jne     .da_done
    dec     ecx
    jnz     .da_wait
.da_done:
    pop     rdi
    pop     rsi
    pop     rcx
    pop     rbx
    pop     rax
    ret


; ==========================================================
; UDP
;
; Заголовок усього 8 байт:
;   0-1 порт відправника
;   2-3 порт отримувача
;   4-5 довжина (заголовок + дані)
;   6-7 контрольна сума
;
; У IPv4 сума UDP НЕОБОВ'ЯЗКОВА - нуль означає 'не рахували',
; і приймач її не перевіряє. Це помітно спрощує код, і так
; роблять багато вбудованих стеків.
; ==========================================================

; NetSendUdp - зібрати й відправити UDP-пакет.
;   RSI = MAC отримувача
;   RDI = IP отримувача (4 байти)
;   BX  = порт відправника (big-endian), CX = порт отримувача
;   R10 = дані, R11D = довжина даних
NetSendUdp:
    ; R10/R11 - вхідні аргументи, але зберігаємо їх теж: так процедура
    ; не псує регістри викликача і подібних помилок більше не буде.
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14

    mov     r12w, bx                ; порт відправника
    mov     r13w, cx                ; порт отримувача
    push    rdi                     ; IP отримувача

    mov     bx, 0x0008              ; тип кадру 0x0800 у порядку пам'яті
    call    NetBuildEth

    ; --- IPv4 ---
    lea     rdi, [NetFrame + 14]
    mov     byte [rdi + 0], 0x45
    mov     byte [rdi + 1], 0x00
    ; загальна довжина = 20 (IP) + 8 (UDP) + дані, старшим байтом уперед
    mov     eax, r11d
    add     eax, 28
    mov     r14d, eax               ; знадобиться нижче
    mov     [rdi + 2], ah
    mov     [rdi + 3], al
    mov     ax, [NetIpId]
    mov     [rdi + 4], ax
    inc     word [NetIpId]
    mov     word [rdi + 6], 0
    mov     byte [rdi + 8], 64      ; TTL
    mov     byte [rdi + 9], 17      ; протокол 17 = UDP
    mov     word [rdi + 10], 0
    push    rdi
    lea     rsi, [NetMyIp]
    add     rdi, 12
    mov     rcx, 4
    cld
    rep     movsb
    pop     rdi
    pop     rsi                     ; IP отримувача
    push    rdi
    add     rdi, 16
    mov     rcx, 4
    rep     movsb
    pop     rdi

    push    rsi
    mov     rsi, rdi
    mov     ecx, 20
    call    NetChecksum
    mov     [rdi + 10], ax
    pop     rsi

    ; --- UDP ---
    lea     rdi, [NetFrame + 34]
    mov     [rdi + 0], r12w         ; порти вже в потрібному порядку
    mov     [rdi + 2], r13w
    mov     eax, r11d
    add     eax, 8                  ; довжина UDP = заголовок + дані
    mov     [rdi + 4], ah
    mov     [rdi + 5], al
    mov     word [rdi + 6], 0       ; сума не рахується (дозволено в IPv4)

    ; --- Дані ---
    lea     rdi, [NetFrame + 42]
    mov     rsi, r10
    mov     ecx, r11d
    cld
    rep     movsb

    ; --- Відправляємо ---
    lea     rsi, [NetFrame]
    mov     ecx, r14d
    add     ecx, 14                 ; + Ethernet
    mov     [DnsFrameLen], ecx      ; діагностика: реальна довжина кадру
    call    NetSend
    jc      .su_txfail
    mov     byte [DnsTxOk], 1
    jmp     .su_txdone
.su_txfail:
    mov     byte [DnsTxOk], 0
.su_txdone:

    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; DHCP
;
; Формат успадкований від BOOTP: 236 байт фіксованих полів,
; більшість з яких нам не потрібні, потім 'чарівне число'
; 63 82 53 63 (саме воно відрізняє DHCP від чистого BOOTP),
; а за ним список опцій у форматі [тип][довжина][значення].
;
; Обмін:  DISCOVER -> OFFER -> REQUEST -> ACK
; Порти:  клієнт 68, сервер 67
; ==========================================================

; NetBuildDhcp - заповнити спільну частину пакета в DhcpBuf.
;   AL = тип повідомлення (1 = DISCOVER, 3 = REQUEST)
;   -> ECX = довжина готового пакета
NetBuildDhcp:
    push    rax
    push    rbx
    push    rsi
    push    rdi
    push    r10

    mov     r10b, al                ; тип повідомлення

    lea     rdi, [DhcpBuf]
    mov     rcx, 300
    xor     al, al
    cld
    rep     stosb

    lea     rdi, [DhcpBuf]
    mov     byte [rdi + 0], 1       ; op: запит від клієнта
    mov     byte [rdi + 1], 1       ; тип мережі: Ethernet
    mov     byte [rdi + 2], 6       ; довжина MAC
    mov     byte [rdi + 3], 0       ; hops
    ; ідентифікатор транзакції - щоб упізнати свою відповідь
    mov     eax, [DhcpXid]
    mov     [rdi + 4], eax
    mov     word [rdi + 8], 0       ; secs
    mov     byte [rdi + 10], 0x80   ; прапорець broadcast: у нас ще
    mov     byte [rdi + 11], 0x00   ; немає адреси, відповідь має йти всім

    ; наша MAC у полі chaddr (зміщення 28)
    lea     rdi, [DhcpBuf + 28]
    lea     rsi, [NetMac]
    mov     rcx, 6
    rep     movsb

    ; чарівне число на зміщенні 236
    lea     rdi, [DhcpBuf + 236]
    mov     byte [rdi + 0], 99      ; 0x63
    mov     byte [rdi + 1], 130     ; 0x82
    mov     byte [rdi + 2], 83      ; 0x53
    mov     byte [rdi + 3], 99      ; 0x63

    ; --- Опції ---
    lea     rdi, [DhcpBuf + 240]
    mov     byte [rdi + 0], 53      ; тип повідомлення
    mov     byte [rdi + 1], 1
    mov     [rdi + 2], r10b
    add     rdi, 3

    ; Для REQUEST додаємо, яку адресу просимо і в кого
    cmp     r10b, 3
    jne     .bd_no_req
    mov     byte [rdi + 0], 50      ; бажана адреса
    mov     byte [rdi + 1], 4
    push    rdi
    add     rdi, 2
    lea     rsi, [DhcpOfferIp]
    mov     rcx, 4
    rep     movsb
    pop     rdi
    add     rdi, 6
    mov     byte [rdi + 0], 54      ; ідентифікатор сервера
    mov     byte [rdi + 1], 4
    push    rdi
    add     rdi, 2
    lea     rsi, [DhcpServerIp]
    mov     rcx, 4
    rep     movsb
    pop     rdi
    add     rdi, 6
.bd_no_req:

    ; що саме хочемо дізнатися
    mov     byte [rdi + 0], 55      ; список параметрів
    mov     byte [rdi + 1], 3
    mov     byte [rdi + 2], 1       ; маска підмережі
    mov     byte [rdi + 3], 3       ; шлюз
    mov     byte [rdi + 4], 6       ; DNS-сервер
    add     rdi, 5
    mov     byte [rdi], 255         ; кінець опцій
    inc     rdi

    ; довжина = скільки набралося, але не менше 300 (деякі сервери
    ; відкидають надто короткі пакети)
    lea     rax, [DhcpBuf]
    sub     rdi, rax
    mov     ecx, edi
    cmp     ecx, 300
    jae     .bd_len_ok
    mov     ecx, 300
.bd_len_ok:

    pop     r10
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rax
    ret

; NetSendDhcp - відправити DHCP-пакет широкомовно.
;   AL = тип повідомлення
NetSendDhcp:
    push    rax
    push    rbx
    push    rcx
    push    rsi
    push    rdi
    push    r10
    push    r11

    call    NetBuildDhcp
    mov     r11d, ecx
    lea     r10, [DhcpBuf]

    lea     rsi, [NetBcastMac]      ; FF:FF:FF:FF:FF:FF
    lea     rdi, [NetBcastIp]       ; 255.255.255.255
    mov     bx, 0x4400              ; порт 68 у порядку мережі
    mov     cx, 0x4300              ; порт 67
    call    NetSendUdp

    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetHandleDhcp - розібрати відповідь сервера.
; RSI = початок DHCP-даних усередині прийнятого кадру
; ==========================================================
NetHandleDhcp:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    ; Чи наша це транзакція?
    mov     eax, [rsi + 4]
    cmp     eax, [DhcpXid]
    jne     .hd_done

    ; Чарівне число на місці?
    cmp     byte [rsi + 236], 99
    jne     .hd_done
    cmp     byte [rsi + 237], 130
    jne     .hd_done

    ; Запропонована нам адреса лежить у полі yiaddr (зміщення 16)
    lea     rdi, [DhcpOfferIp]
    push    rsi
    add     rsi, 16
    mov     rcx, 4
    cld
    rep     movsb
    pop     rsi

    ; --- Проходимо список опцій ---
    lea     r10, [rsi + 240]
    xor     r11d, r11d              ; тип повідомлення
.hd_opt:
    movzx   eax, byte [r10]
    cmp     al, 255                 ; кінець списку
    je      .hd_opts_done
    cmp     al, 0                   ; заповнювач - пропускаємо
    je      .hd_pad
    movzx   ebx, byte [r10 + 1]     ; довжина значення

    cmp     al, 53                  ; тип повідомлення
    jne     .hd_not_53
    movzx   r11d, byte [r10 + 2]
    jmp     .hd_next
.hd_not_53:
    cmp     al, 1                   ; маска підмережі
    jne     .hd_not_1
    push    rsi
    push    rdi
    lea     rsi, [r10 + 2]
    lea     rdi, [NetMask]
    mov     rcx, 4
    cld
    rep     movsb
    pop     rdi
    pop     rsi
    jmp     .hd_next
.hd_not_1:
    cmp     al, 3                   ; шлюз
    jne     .hd_not_3
    push    rsi
    push    rdi
    lea     rsi, [r10 + 2]
    lea     rdi, [NetGwIp]
    mov     rcx, 4
    cld
    rep     movsb
    pop     rdi
    pop     rsi
    mov     byte [NetGwKnown], 0    ; шлюз змінився - MAC треба заново
    jmp     .hd_next
.hd_not_3:
    cmp     al, 6                   ; DNS-сервер
    jne     .hd_not_6
    push    rsi
    push    rdi
    lea     rsi, [r10 + 2]
    lea     rdi, [NetDnsIp]
    mov     rcx, 4
    cld
    rep     movsb
    pop     rdi
    pop     rsi
    jmp     .hd_next
.hd_not_6:
    cmp     al, 54                  ; ідентифікатор сервера
    jne     .hd_next
    push    rsi
    push    rdi
    lea     rsi, [r10 + 2]
    lea     rdi, [DhcpServerIp]
    mov     rcx, 4
    cld
    rep     movsb
    pop     rdi
    pop     rsi

.hd_next:
    movzx   ebx, byte [r10 + 1]
    add     r10, 2
    add     r10, rbx
    jmp     .hd_check
.hd_pad:
    inc     r10
.hd_check:
    lea     rax, [rsi + 1500]
    cmp     r10, rax                ; не вилазимо за межі кадру
    jb      .hd_opt

.hd_opts_done:
    cmp     r11d, 2                 ; OFFER?
    jne     .hd_check_ack
    mov     byte [DhcpState], 2     ; отримали пропозицію
    jmp     .hd_done
.hd_check_ack:
    cmp     r11d, 5                 ; ACK?
    jne     .hd_done
    ; Адреса наша - застосовуємо
    lea     rsi, [DhcpOfferIp]
    lea     rdi, [NetMyIp]
    mov     rcx, 4
    cld
    rep     movsb
    mov     byte [DhcpState], 5

.hd_done:
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetPrintIp - надрукувати 4 байти IP як A.B.C.D
; RSI = адреса, RCX = X-координата
; ==========================================================
NetPrintIp:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13
    mov     r12, rsi
    xor     r13d, r13d
.pi_loop:
    movzx   eax, byte [r12 + r13]
    lea     rdi, [PciBuf]
    call    DecToStr
    push    rcx
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_TEXT
    call    DrawString
    pop     rcx
    ; зсуваємось на ширину надрукованого числа
    movzx   eax, byte [r12 + r13]
    add     rcx, 9
    cmp     eax, 10
    jb      .pi_dot
    add     rcx, 9
    cmp     eax, 100
    jb      .pi_dot
    add     rcx, 9
.pi_dot:
    inc     r13d
    cmp     r13d, 4
    jae     .pi_done
    push    rcx
    mov     rdx, [CursorY]
    lea     r8, [PciDot]
    mov     r9d, COL_TEXT
    call    DrawString
    pop     rcx
    add     rcx, 9
    jmp     .pi_loop
.pi_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; DhcpCommand - команда DHCP
; ==========================================================
DhcpCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12

    cmp     byte [NetReady], 0
    jne     .dc_ready
    call    ScanPciQuiet
    call    NetInit
    jc      .dc_nocard
.dc_ready:

    ; Ідентифікатор транзакції - беремо з лічильника тіків,
    ; щоб він відрізнявся між запусками
    mov     rax, [SystemTicks]
    or      eax, 0x51000000
    mov     [DhcpXid], eax
    mov     byte [DhcpState], 0

    ; На час пошуку адреси наша IP - нульова
    mov     dword [NetMyIp], 0

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpGo]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine

    ; --- DISCOVER ---
    mov     al, 1
    call    NetSendDhcp

    mov     r12d, 3000000
.dc_wait_offer:
    call    NetPollBackground
    cmp     byte [DhcpState], 2
    je      .dc_got_offer
    dec     r12d
    jnz     .dc_wait_offer
    jmp     .dc_timeout

.dc_got_offer:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpOffer]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [DhcpOfferIp]
    mov     rcx, 180
    call    NetPrintIp
    call    NewLine

    ; --- REQUEST ---
    mov     al, 3
    call    NetSendDhcp

    mov     r12d, 3000000
.dc_wait_ack:
    call    NetPollBackground
    cmp     byte [DhcpState], 5
    je      .dc_got_ack
    dec     r12d
    jnz     .dc_wait_ack
    jmp     .dc_timeout

.dc_got_ack:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpIp]
    mov     r9d, COL_BRIGHT
    call    DrawString
    lea     rsi, [NetMyIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpMask]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetMask]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpGw]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetGwIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpDns]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetDnsIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
    jmp     .dc_done

.dc_timeout:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .dc_done
.dc_nocard:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.dc_done:
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; IPCONFIG - показати поточні налаштування
IpconfigCommand:
    push    rcx
    push    rdx
    push    rsi
    push    r8
    push    r9
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpIp]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetMyIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpMask]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetMask]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpGw]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetGwIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpDns]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetDnsIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
    pop     r9
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    ret


; ==========================================================
; DNS
;
; Запит іде по UDP на порт 53. Заголовок 12 байт:
;   0-1  ідентифікатор (щоб упізнати свою відповідь)
;   2-3  прапорці; 0x0100 = 'хочу рекурсивний пошук'
;   4-5  скільки питань (у нас 1)
;   6-7  скільки відповідей (у запиті 0)
;   8-11 інші лічильники
;
; ІМ'Я КОДУЄТЬСЯ ОСОБЛИВО: не рядком з крапками, а послідовністю
; частин, кожна з яких починається зі своєї довжини:
;     google.com  ->  6 g o o g l e 3 c o m 0
; Кінець - нульовий байт.
;
; У ВІДПОВІДІ є хитрість - СТИСНЕННЯ ІМЕН. Замість повторення
; імені сервер може поставити 2 байти, де старші два біти = 11
; (тобто байт >= 0xC0), а решта - зміщення на вже наявне ім'я
; у цьому ж пакеті. Тому при пропусканні імені треба це вміти
; розпізнавати, інакше розбір поїде.
; ==========================================================

; NetDnsEncode - закодувати ім'я з [rsi] у формат DNS у [rdi].
; -> ECX = довжина закодованого імені разом із нулем
NetDnsEncode:
    push    rax
    push    rbx
    push    rsi
    push    rdi
    push    r10
    push    r11

    mov     r10, rdi                ; початок, щоб порахувати довжину
    mov     r11, rdi                ; сюди запишемо довжину частини
    inc     rdi                     ; саму частину пишемо з наступного байта
    xor     bl, bl                  ; лічильник символів у частині

.de_loop:
    mov     al, [rsi]
    inc     rsi
    test    al, al
    jz      .de_end
    cmp     al, '.'
    je      .de_dot
    cmp     al, ' '
    je      .de_end
    ; малі літери у верхній регістр не переводимо: DNS байдужий
    ; до регістру, а зайве перетворення тільки заплутає
    mov     [rdi], al
    inc     rdi
    inc     bl
    jmp     .de_loop

.de_dot:
    mov     [r11], bl               ; записуємо довжину попередньої частини
    mov     r11, rdi                ; наступна довжина буде тут
    inc     rdi
    xor     bl, bl
    jmp     .de_loop

.de_end:
    mov     [r11], bl               ; довжина останньої частини
    mov     byte [rdi], 0           ; кінець імені
    inc     rdi
    mov     rcx, rdi
    sub     rcx, r10                ; скільки всього вийшло

    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rax
    ret

; NetDnsSkipName - пропустити ім'я в пакеті.
; RSI = поточна позиція -> RSI за іменем
NetDnsSkipName:
    push    rax
.sn_loop:
    mov     al, [rsi]
    test    al, al
    jz      .sn_zero
    and     al, 0xC0
    cmp     al, 0xC0                ; вказівник стиснення?
    je      .sn_ptr
    movzx   eax, byte [rsi]
    inc     rsi
    add     rsi, rax                ; пропускаємо частину
    jmp     .sn_loop
.sn_ptr:
    add     rsi, 2                  ; вказівник завжди рівно 2 байти
    jmp     .sn_done
.sn_zero:
    inc     rsi                     ; нульовий байт кінця імені
.sn_done:
    pop     rax
    ret

; ==========================================================
; NetResolve - дізнатися IP за іменем.
; RSI = ім'я (нуль-термінований рядок)
; -> CF=0 і адреса в NetTargetIp, CF=1 якщо не вдалося
; ==========================================================
NetResolve:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12

    mov     byte [DnsGot], 0
    mov     dword [DnsStage], 1     ; діагностика: увійшли в NetResolve

    ; --- Заголовок запиту ---
    lea     rdi, [DnsBuf]
    mov     rcx, 300
    push    rax
    xor     al, al
    cld
    rep     stosb
    pop     rax

    mov     rax, [SystemTicks]
    mov     [DnsId], ax
    lea     rdi, [DnsBuf]
    mov     [rdi + 0], ax           ; ідентифікатор
    mov     byte [rdi + 2], 0x01    ; прапорці: рекурсивний запит
    mov     byte [rdi + 3], 0x00
    mov     byte [rdi + 4], 0x00    ; одне питання
    mov     byte [rdi + 5], 0x01

    ; --- Питання: закодоване ім'я + тип + клас ---
    lea     rdi, [DnsBuf + 12]
    call    NetDnsEncode            ; RSI -> RDI, ECX = довжина
    add     rdi, rcx
    mov     byte [rdi + 0], 0x00    ; тип A (адреса IPv4)
    mov     byte [rdi + 1], 0x01
    mov     byte [rdi + 2], 0x00    ; клас IN (інтернет)
    mov     byte [rdi + 3], 0x01
    add     rdi, 4

    lea     rax, [DnsBuf]
    sub     rdi, rax
    ; ВИПРАВЛЕНО: довжину зберігаємо у ЗМІННУ, а не в R11.
    ; Нижче викликається NetDoArp, який крутить NetPollBackground,
    ; а обробники всередині псують R10/R11. Через це в NetSendUdp
    ; потрапляло сміття, довжина кадру виходила величезною і
    ; перевірка 'cmp ecx, NetTxSize / ja .ns_fail' тихо його відкидала.
    mov     [DnsLen], edi

    ; --- Спершу переконуємось, що знаємо MAC шлюзу ---
    cmp     byte [NetGwKnown], 0
    jne     .nr_have_mac
    call    NetDoArp
    cmp     byte [NetGwKnown], 0
    je      .nr_fail
.nr_have_mac:
    mov     dword [DnsStage], 2     ; MAC шлюзу відома

    mov     byte [DnsFellBack], 0
.nr_send:
    ; і лише тепер, коли ніхто більше не викликається, готуємо аргументи
    mov     r11d, [DnsLen]
    lea     r10, [DnsBuf]
    lea     rsi, [NetGwMac]
    lea     rdi, [NetDnsIp]
    ; ВАЖЛИВО: як порт відправника беремо високий (50000), а не 53.
    ; Клієнти так і роблять, і slirp у QEMU надійніше відповідає.
    mov     bx, 0x50C3              ; 50000 = 0xC350, у пам'яті 0xC3,0x50
    mov     cx, 0x3500              ; порт сервера 53
    mov     [DnsSentLen], r11d      ; діагностика: з якою довжиною шлемо
    mov     dword [DnsStage], 3
    call    NetSendUdp
    mov     dword [DnsStage], 4     ; повернулись із відправки

    ; --- Чекаємо відповідь ---
    ;
    ; По часу, а не по обертах циклу: скільки обертів устигне зробити
    ; NetPollBackground, залежить від того, чим зайнята машина.
    mov     rbx, [SystemTicks]
    add     rbx, 2000               ; дві секунди на відповідь
.nr_wait:
    call    NetPollBackground
    cmp     byte [DnsGot], 0
    jne     .nr_ok
    mov     rax, [SystemTicks]
    cmp     rax, rbx
    jb      .nr_wait

    ; Тиша. Вбудований резолвер slirp за 10.0.2.3 відповідає не в
    ; кожній збірці QEMU, і мовчазна відмова тут коштувала б ручного
    ; SETDNS на кожному запуску. Тому один раз пробуємо публічний
    ; сервер: NAT до нього однаково працює, раз працює TCP назовні.
    cmp     byte [DnsFellBack], 0
    jne     .nr_fail
    mov     byte [DnsFellBack], 1
    mov     dword [NetDnsIp], 0x08080808    ; 8.8.8.8
    mov     byte [DnsGot], 0
    jmp     .nr_send

.nr_ok:
    clc
    jmp     .nr_exit
.nr_fail:
    stc
.nr_exit:
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NetHandleDns - розібрати відповідь DNS.
; RSI = початок даних DNS у прийнятому кадрі
; ==========================================================
NetHandleDns:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    mov     r10, rsi                ; початок пакета - знадобиться

    ; Наш ідентифікатор?
    mov     ax, [rsi]
    cmp     ax, [DnsId]
    jne     .hn_done

    ; Скільки відповідей? (байти 6-7, старшим уперед)
    movzx   ebx, byte [rsi + 6]
    shl     ebx, 8
    movzx   eax, byte [rsi + 7]
    or      ebx, eax
    test    ebx, ebx
    jz      .hn_done                ; нічого не знайдено
    mov     r11d, ebx               ; лічильник відповідей

    ; Пропускаємо секцію питань. Їх стільки, скільки в байтах 4-5,
    ; але ми завжди шлемо рівно одне.
    add     rsi, 12
    call    NetDnsSkipName
    add     rsi, 4                  ; тип + клас

    ; --- Перебираємо відповіді ---
.hn_ans:
    call    NetDnsSkipName
    movzx   eax, byte [rsi]         ; тип запису
    shl     eax, 8
    movzx   ecx, byte [rsi + 1]
    or      eax, ecx
    movzx   ecx, byte [rsi + 8]     ; довжина даних
    shl     ecx, 8
    movzx   edx, byte [rsi + 9]
    or      ecx, edx
    add     rsi, 10                 ; тип+клас+TTL+довжина

    cmp     eax, 1                  ; тип A?
    jne     .hn_skip
    cmp     ecx, 4                  ; і рівно 4 байти адреси?
    jne     .hn_skip

    ; Знайшли адресу
    lea     rdi, [NetTargetIp]
    push    rcx
    mov     rcx, 4
    cld
    rep     movsb
    pop     rcx
    mov     byte [DnsGot], 1
    jmp     .hn_done

.hn_skip:
    add     rsi, rcx                ; пропускаємо дані цього запису
    dec     r11d
    jnz     .hn_ans

.hn_done:
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; NsLookupCommand - команда NSLOOKUP <ім'я>
; ==========================================================
; ==========================================================
; TCP
; ==========================================================

; ----------------------------------------------------------
; NetTcpChecksum - сума сегмента разом із псевдозаголовком.
;   RDI = початок сегмента, ECX = його довжина
;   -> AX = готове значення, кладеться в поле як є
;
; Псевдозаголовка в пам'яті не існує - його поля просто додаються
; до суми. У UDP суму дозволено не рахувати взагалі, у TCP - ні,
; тому обійтись як там не вийде.
;
; Байти беремо так, як вони лягли б у мережу: сума байт-орієнтована,
; а не числова, тому довжину переставляємо вручну.
; ----------------------------------------------------------
NetTcpChecksum:
    push    rbx
    push    rcx
    push    rdx
    push    rsi

    xor     eax, eax
    movzx   ebx, word [NetMyIp]
    add     eax, ebx
    movzx   ebx, word [NetMyIp + 2]
    add     eax, ebx
    movzx   ebx, word [TcpRemoteIp]
    add     eax, ebx
    movzx   ebx, word [TcpRemoteIp + 2]
    add     eax, ebx
    add     eax, 0x0600             ; байти 00 06: нуль і номер протоколу
    mov     bx, cx
    xchg    bl, bh                  ; довжина старшим байтом уперед
    movzx   ebx, bx
    add     eax, ebx

    mov     rsi, rdi
    mov     edx, ecx
.tcs_loop:
    cmp     edx, 2
    jb      .tcs_tail
    movzx   ebx, word [rsi]
    add     eax, ebx
    add     rsi, 2
    sub     edx, 2
    jmp     .tcs_loop
.tcs_tail:
    test    edx, edx
    jz      .tcs_fold
    movzx   ebx, byte [rsi]
    add     eax, ebx
.tcs_fold:
    mov     ebx, eax
    shr     ebx, 16
    and     eax, 0xFFFF
    add     eax, ebx
    mov     ebx, eax
    shr     ebx, 16
    add     eax, ebx
    not     eax
    and     eax, 0xFFFF

    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ----------------------------------------------------------
; NetSendTcp - зібрати й відправити один сегмент.
;   DL   = прапорці (TCP_SYN, TCP_ACK, ...)
;   R10  = дані, R11D = скільки їх (0, якщо самі прапорці)
;   Решту бере зі стану з'єднання.
;   -> CF=1, якщо відправити не вдалося
; ----------------------------------------------------------
NetSendTcp:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12
    push    r14

    movzx   r12d, dl                ; прапорці переживуть виклики нижче

    cmp     byte [NetGwKnown], 0
    jne     .st_have_mac
    call    NetDoArp
    cmp     byte [NetGwKnown], 0
    je      .st_fail
.st_have_mac:

    lea     rsi, [NetGwMac]
    mov     bx, 0x0008              ; 0x0800 у порядку пам'яті
    call    NetBuildEth

    ; --- IPv4 ---
    lea     rdi, [NetFrame + 14]
    mov     byte [rdi + 0], 0x45
    mov     byte [rdi + 1], 0x00
    mov     eax, r11d
    add     eax, 40                 ; 20 IP + 20 TCP
    mov     r14d, eax
    mov     [rdi + 2], ah
    mov     [rdi + 3], al
    mov     ax, [NetIpId]
    mov     [rdi + 4], ax
    inc     word [NetIpId]
    mov     word [rdi + 6], 0
    mov     byte [rdi + 8], 64      ; TTL
    mov     byte [rdi + 9], 6       ; протокол 6 = TCP
    mov     word [rdi + 10], 0
    push    rdi
    lea     rsi, [NetMyIp]
    add     rdi, 12
    mov     rcx, 4
    cld
    rep     movsb
    lea     rsi, [TcpRemoteIp]
    mov     rcx, 4
    rep     movsb
    pop     rdi

    mov     rsi, rdi
    mov     ecx, 20
    call    NetChecksum
    mov     [rdi + 10], ax

    ; --- TCP ---
    lea     rdi, [NetFrame + 34]
    mov     ax, [TcpLocalPort]
    mov     [rdi + 0], ax
    mov     ax, [TcpRemotePort]
    mov     [rdi + 2], ax
    mov     eax, [TcpSndNxt]
    bswap   eax
    mov     [rdi + 4], eax
    mov     eax, [TcpRcvNxt]
    bswap   eax
    mov     [rdi + 8], eax
    mov     byte [rdi + 12], 0x50   ; заголовок 5 слів, опцій немає
    mov     [rdi + 13], r12b

    ; Вікном оголошуємо те, що ще вміщаємо, але не більше за стелю
    ; самого поля: воно шістнадцятибітне. Збрехати більше означало б
    ; попросити даних, які нікуди подіти.
    mov     eax, TCP_RXCAP
    sub     eax, [TcpRxLen]
    jns     .st_win_pos
    xor     eax, eax
.st_win_pos:
    cmp     eax, TCP_WINMAX
    jbe     .st_win_ok
    mov     eax, TCP_WINMAX
.st_win_ok:
    mov     [rdi + 14], ah
    mov     [rdi + 15], al
    mov     word [rdi + 16], 0      ; сума - нижче, поки нуль
    mov     word [rdi + 18], 0      ; вказівник термінових даних

    test    r11d, r11d
    jz      .st_no_data
    push    rdi
    lea     rdi, [NetFrame + 54]
    mov     rsi, r10
    mov     ecx, r11d
    cld
    rep     movsb
    pop     rdi
.st_no_data:

    mov     ecx, r11d
    add     ecx, 20
    call    NetTcpChecksum
    mov     [rdi + 16], ax

    lea     rsi, [NetFrame]
    mov     ecx, r14d
    add     ecx, 14
    call    NetSend
    jc      .st_fail
    clc
    jmp     .st_exit
.st_fail:
    stc
.st_exit:
    pop     r14
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; NetHandleTcp - розібрати прийнятий сегмент.
; Кадр лежить у NetRxFrame. Кличеться з NetHandleFrame.
;
; Приймаємо лише те, що точно за порядком: сегмент із чужим номером
; просто відкидаємо, і відправник надішле його ще раз. Черга з дірок
; коштувала б окремої структури, а виграшу на наших швидкостях не
; дала б жодного.
; ----------------------------------------------------------
NetHandleTcp:
    ; Лічимо ВСІ TCP-сегменти, ще до перевірки портів і стану. Нуль
    ; тут означає, що назад не прийшло нічого - тобто справа в тому,
    ; що ми відправляємо, а не в тому, як розбираємо.
    inc     dword [TcpRxSegs]

    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11

    cmp     byte [TcpState], TCPS_CLOSED
    je      .ht_done                ; нічого не відкрито - нема чого слухати

    movzx   r8d, byte [NetRxFrame + 14]
    and     r8d, 0x0F
    shl     r8d, 2                  ; довжина заголовка IP
    lea     rsi, [NetRxFrame + 14]
    add     rsi, r8                 ; RSI -> початок TCP

    ; Чужі розмови нас не стосуються
    mov     ax, [rsi + 2]
    cmp     ax, [TcpLocalPort]
    jne     .ht_done
    mov     ax, [rsi + 0]
    cmp     ax, [TcpRemotePort]
    jne     .ht_done

    mov     dl, [rsi + 13]          ; прапорці

    test    dl, TCP_RST
    jz      .ht_no_rst
    mov     byte [TcpRstSeen], 1
    mov     byte [TcpState], TCPS_DONE
    jmp     .ht_done
.ht_no_rst:

    ; --- скільки корисних даних ---
    movzx   eax, byte [NetRxFrame + 16]
    shl     eax, 8
    movzx   ecx, byte [NetRxFrame + 17]
    or      eax, ecx                ; загальна довжина IP-пакета
    sub     eax, r8d                ; мінус заголовок IP
    movzx   ecx, byte [rsi + 12]
    shr     ecx, 4
    shl     ecx, 2                  ; довжина заголовка TCP
    mov     r10d, ecx               ; знадобиться як зсув до даних
    sub     eax, ecx
    js      .ht_done                ; зіпсована довжина
    mov     r9d, eax                ; R9D = байтів даних

    ; --- SYN_SENT: чекаємо SYN+ACK ---
    cmp     byte [TcpState], TCPS_SYNSENT
    jne     .ht_established
    mov     al, dl
    and     al, TCP_SYN or TCP_ACK
    cmp     al, TCP_SYN or TCP_ACK
    jne     .ht_done

    mov     eax, [rsi + 4]
    bswap   eax
    inc     eax                     ; SYN займає один номер
    mov     [TcpRcvNxt], eax
    mov     eax, [rsi + 8]
    bswap   eax
    mov     [TcpSndUna], eax
    mov     [TcpSndNxt], eax
    mov     byte [TcpState], TCPS_ESTAB

    mov     dl, TCP_ACK
    xor     r10, r10
    xor     r11d, r11d
    call    NetSendTcp
    jmp     .ht_done

.ht_established:
    ; --- ACK: посуваємо межу підтвердженого ---
    test    dl, TCP_ACK
    jz      .ht_no_ack
    mov     eax, [rsi + 8]
    bswap   eax
    mov     [TcpSndUna], eax
    mov     byte [TcpGotAck], 1
.ht_no_ack:

    ; --- Дані ---
    test    r9d, r9d
    jz      .ht_check_fin
    mov     eax, [rsi + 4]
    bswap   eax
    cmp     eax, [TcpRcvNxt]
    jne     .ht_dup_ack             ; не наш шматок - просимо повторити

    mov     eax, TCP_RXCAP
    sub     eax, [TcpRxLen]
    jle     .ht_no_room
    cmp     r9d, eax
    jle     .ht_fits
    mov     r9d, eax                ; більше не вміщаємо
.ht_fits:
    push    rsi
    push    rdi
    mov     rdi, TcpRxBase
    mov     eax, [TcpRxLen]
    add     rdi, rax
    add     rsi, r10                ; пропускаємо заголовок TCP
    mov     ecx, r9d
    cld
    rep     movsb
    pop     rdi
    pop     rsi

    mov     eax, [TcpRcvNxt]
    add     eax, r9d
    mov     [TcpRcvNxt], eax
    mov     eax, [TcpRxLen]
    add     eax, r9d
    mov     [TcpRxLen], eax
.ht_no_room:

.ht_check_fin:
    test    dl, TCP_FIN
    jz      .ht_ack_if_needed
    inc     dword [TcpRcvNxt]       ; FIN теж займає номер
    mov     byte [TcpFinSeen], 1
    mov     byte [TcpState], TCPS_DONE
    mov     dl, TCP_ACK
    xor     r10, r10
    xor     r11d, r11d
    call    NetSendTcp
    jmp     .ht_done

.ht_ack_if_needed:
    test    r9d, r9d
    jz      .ht_done                ; нічого не прийняли - нічого й підтверджувати
.ht_dup_ack:
    mov     dl, TCP_ACK
    xor     r10, r10
    xor     r11d, r11d
    call    NetSendTcp

.ht_done:
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; TcpParsePort - розібрати десяткове число з рядка RSI.
;   -> AX = число, RSI показує за ним; CF=1, якщо цифр не було
; ----------------------------------------------------------
TcpParsePort:
    push    rbx
    push    rcx
    xor     eax, eax
    xor     ecx, ecx                ; скільки цифр узяли
.tpp_loop:
    movzx   ebx, byte [rsi]
    cmp     bl, '0'
    jb      .tpp_end
    cmp     bl, '9'
    ja      .tpp_end
    sub     bl, '0'
    imul    eax, eax, 10
    add     eax, ebx
    inc     rsi
    inc     ecx
    cmp     eax, 65535
    ja      .tpp_fail               ; у порт таке не влізе
    jmp     .tpp_loop
.tpp_end:
    test    ecx, ecx
    jz      .tpp_fail
    clc
    jmp     .tpp_exit
.tpp_fail:
    stc
.tpp_exit:
    pop     rcx
    pop     rbx
    ret

; ----------------------------------------------------------
; TcpConnect - відкрити з'єднання й дочекатися підтвердження.
;   RSI = адреса отримувача (4 байти), CX = порт у звичайному вигляді
;   -> CF=0 встановлено, CF=1 ні
;
; Чекаємо так само, як чекає DNS: крутимо NetPollBackground і
; дивимось на стан. Свого потоку в мережевого стека немає, тож
; приймати кадри більше нема кому.
; ----------------------------------------------------------
TcpConnect:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r13

    ; Причини невдачі розділяємо. Спершу тут було одне повідомлення
    ; на всі випадки - і воно однаково казало "немає відповіді" й
    ; тоді, коли пакет навіть не пішов. Шукати з таким підказником
    ; можна довго.
    mov     byte [TcpFailWhy], 0
    mov     dword [TcpRxSegs], 0

    cmp     byte [NetReady], 0
    jne     .tc_card_ok
    mov     byte [TcpFailWhy], 1        ; карту не піднято
    jmp     .tc_fail
.tc_card_ok:

    mov     byte [TcpState], TCPS_CLOSED
    mov     byte [TcpFinSeen], 0
    mov     byte [TcpRstSeen], 0
    mov     byte [TcpGotAck], 0
    mov     dword [TcpRxLen], 0
    mov     dword [TcpRcvNxt], 0

    lea     rdi, [TcpRemoteIp]
    push    rcx
    mov     rcx, 4
    cld
    rep     movsb
    pop     rcx

    xchg    cl, ch                  ; порт у мережевий порядок
    mov     [TcpRemotePort], cx

    ; MAC шлюзу питаємо ДО відправки, щоб відрізнити "мережі немає"
    ; від "порт мовчить".
    cmp     byte [NetGwKnown], 0
    jne     .tc_arp_ok
    call    NetDoArp
    cmp     byte [NetGwKnown], 0
    jne     .tc_arp_ok
    mov     byte [TcpFailWhy], 2        ; шлюз не відповів на ARP
    jmp     .tc_fail
.tc_arp_ok:

    ; Локальний порт із динамічного діапазону. Лічильник потрібен,
    ; щоб два з'єднання поспіль не взяли той самий номер: відповіді
    ; на попереднє інакше зарахувалися б новому.
    mov     ax, [TcpPortSeed]
    inc     word [TcpPortSeed]
    and     ax, 0x0FFF
    or      ax, 0xC000              ; 49152..53247
    xchg    al, ah
    mov     [TcpLocalPort], ax

    ; Початковий номер беремо від таймера з тієї ж причини.
    mov     rax, [SystemTicks]      ; лічильник 64-бітний, беремо молодшу частину
    shl     eax, 8
    mov     [TcpSndNxt], eax
    mov     [TcpSndUna], eax

    mov     byte [TcpState], TCPS_SYNSENT

    ; TcpSndNxt тут НЕ рушимо. SYN займає один номер, але додати його
    ; зараз означало б, що повторний SYN піде вже з наступним - для
    ; того боку це був би інший сегмент. Правильне значення прийде
    ; разом із SYN+ACK: обробник візьме його з їхнього поля ACK.
    mov     r13d, TCP_RETRIES
.tc_try:
    mov     dl, TCP_SYN
    xor     r10, r10
    xor     r11d, r11d
    call    NetSendTcp
    jnc     .tc_sent
    mov     byte [TcpFailWhy], 3        ; кадр не пішов у дріт
    jmp     .tc_fail
.tc_sent:
    mov     rbx, [SystemTicks]
    add     rbx, TCP_RTO                ; коли перепитувати
.tc_wait:
    call    NetPollBackground
    cmp     byte [TcpState], TCPS_ESTAB
    je      .tc_ok
    cmp     byte [TcpRstSeen], 0
    je      .tc_tick
    mov     byte [TcpFailWhy], 4        ; RST - пакет ДІЙШОВ, порт закритий
    jmp     .tc_fail
.tc_tick:
    mov     rax, [SystemTicks]
    cmp     rax, rbx
    jb      .tc_wait

    ; Тиша. Шлемо той самий SYN ще раз: губиться і перший пакет теж,
    ; а без повтору одна втрата означала б відмову з'єднання.
    dec     r13d
    jnz     .tc_try
    mov     byte [TcpFailWhy], 5        ; так ніхто нічого й не відповів

.tc_fail:
    mov     byte [TcpState], TCPS_CLOSED
    stc
    jmp     .tc_exit
.tc_ok:
    clc
.tc_exit:
    pop     r13
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; TcpSend - надіслати дані й дочекатися підтвердження.
;   RSI = дані, ECX = скільки їх
;   -> CF=1, якщо підтвердження не дочекались
;
; Крок за раз: шлемо сегмент і чекаємо ACK, перш ніж слати
; наступний. Вікно відправника нам поки ні до чого - запити, які ми
; робимо, в один сегмент і вміщаються, а стоп-і-чекай простий і
; очевидно правильний.
; ----------------------------------------------------------
TcpSend:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r13
    push    r14

    cmp     byte [TcpState], TCPS_ESTAB
    jne     .ts_fail
    test    ecx, ecx
    jz      .ts_ok
    cmp     ecx, 1400
    jbe     .ts_len_ok
    mov     ecx, 1400               ; в один сегмент більше не кладемо
.ts_len_ok:

    mov     r10, rsi
    mov     r11d, ecx

    ; Номер, з якого йдуть ці дані, і номер, після якого вони
    ; закінчуються. TcpSndNxt рушимо аж тоді, коли їх підтвердять:
    ; повторний сегмент мусить піти з ТИМ САМИМ номером, інакше для
    ; того боку це буде новий шматок, а не повтор загубленого.
    mov     edi, [TcpSndNxt]        ; EDI = початковий номер (поле 32-бітне)
    mov     r14d, edi
    add     r14d, r11d              ; R14D = номер після наших даних

    mov     r13d, TCP_RETRIES
.ts_try:
    mov     [TcpSndNxt], edi        ; щоразу з того самого місця
    mov     byte [TcpGotAck], 0
    mov     dl, TCP_PSH or TCP_ACK
    call    NetSendTcp
    jc      .ts_fail

    mov     rbx, [SystemTicks]
    add     rbx, TCP_RTO
.ts_wait:
    call    NetPollBackground
    cmp     byte [TcpRstSeen], 0
    jne     .ts_fail

    ; Підтвердили все, що ми послали? Порівнюємо ВІДНІМАННЯМ, а не
    ; "більше-дорівнює": номери 32-бітні й переповнюються по колу, і
    ; після переповнення пряме порівняння дало б протилежний висновок.
    mov     eax, [TcpSndUna]
    sub     eax, r14d
    jns     .ts_acked

    mov     rax, [SystemTicks]
    cmp     rax, rbx
    jb      .ts_wait

    dec     r13d
    jnz     .ts_try
    jmp     .ts_fail

.ts_acked:
    mov     [TcpSndNxt], r14d       ; тепер дані справді позаду
.ts_ok:
    clc
    jmp     .ts_exit
.ts_fail:
    stc
.ts_exit:
    pop     r14
    pop     r13
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

TcpRecvWait:
    push    rax
    push    rbx

    ; Тут повторювати нічого: дані шле той бік, і якщо сегмент
    ; загубиться, повторить його теж він - наш ACK просто не посунеться
    ; вперед, і цього досить. Нам лишається тільки чекати з розумною
    ; стелею, щоб не висіти вічно, коли сервер замовк назовсім.
    mov     rbx, [SystemTicks]
    add     rbx, 10000              ; десять секунд на всю відповідь
.trw_loop:
    call    NetPollBackground
    cmp     byte [TcpFinSeen], 0
    jne     .trw_done
    cmp     byte [TcpRstSeen], 0
    jne     .trw_done
    ; Буфер повний - далі чекати нема сенсу.
    mov     eax, [TcpRxLen]
    cmp     eax, TCP_RXCAP
    jae     .trw_done
    mov     rax, [SystemTicks]
    cmp     rax, rbx
    jb      .trw_loop
.trw_done:
    pop     rbx
    pop     rax
    ret

TcpCloseConn:
    push    rax
    push    rbx
    push    rdx
    push    r10
    push    r11

    cmp     byte [TcpState], TCPS_ESTAB
    jne     .tcc_done

    mov     dl, TCP_FIN or TCP_ACK
    xor     r10, r10
    xor     r11d, r11d
    call    NetSendTcp
    inc     dword [TcpSndNxt]       ; FIN теж займає номер

    mov     rbx, [SystemTicks]
    add     rbx, 1000               ; секунди на відповідь на наш FIN досить
.tcc_wait:
    call    NetPollBackground
    cmp     byte [TcpFinSeen], 0
    jne     .tcc_done
    mov     rax, [SystemTicks]
    cmp     rax, rbx
    jb      .tcc_wait

.tcc_done:
    mov     byte [TcpState], TCPS_CLOSED
    pop     r11
    pop     r10
    pop     rdx
    pop     rbx
    pop     rax
    ret

NsLookupCommand:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    r8
    push    r9

    cmp     byte [NetReady], 0
    jne     .nl_ready
    call    ScanPciQuiet
    call    NetInit
    jc      .nl_nocard
.nl_ready:

    lea     rsi, [CmdBuffer + 9]    ; хвіст після 'NSLOOKUP '
    call    NetResolve
    jc      .nl_fail

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDnsFound]
    mov     r9d, COL_BRIGHT
    call    DrawString
    lea     rsi, [NetTargetIp]
    mov     rcx, 100
    call    NetPrintIp
    call    NewLine
    jmp     .nl_done

.nl_fail:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDnsFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

    jmp     .nl_done
.nl_nocard:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.nl_done:
    pop     r9
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; PingNameCommand - PING <ім'я>: спершу резолвимо, потім пінгуємо
; ==========================================================
PingNameCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13

    cmp     byte [NetReady], 0
    jne     .pn_ready
    call    ScanPciQuiet
    call    NetInit
    jc      .pn_nocard
.pn_ready:

    ; Спершу пробуємо прочитати аргумент як адресу. Якщо це IP -
    ; DNS не потрібен зовсім.
    lea     rsi, [CmdBuffer + 5]    ; хвіст після 'PING '
    lea     rdi, [NetTargetIp]
    call    ParseIp
    jnc     .pn_have_ip

    lea     rsi, [CmdBuffer + 5]
    call    NetResolve
    jc      .pn_dnsfail
.pn_have_ip:
    ; для зовнішніх адрес потрібна MAC шлюзу
    cmp     byte [NetGwKnown], 0
    jne     .pn_gw_ok
    call    NetDoArp
.pn_gw_ok:

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingName]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetTargetIp]
    mov     rcx, 100
    call    NetPrintIp
    call    NewLine

    ; --- Чотири пакети на знайдену адресу ---
    ; Зовнішні адреси йдуть через шлюз, тому MAC беремо його.
    xor     r13d, r13d
    mov     r12d, 1
.pn_loop:
    mov     byte [NetPingGot], 0
    mov     al, 8
    lea     rsi, [NetGwMac]
    lea     rdi, [NetTargetIp]
    mov     bx, 0x3412
    mov     cx, r12w
    call    NetSendIcmp

    mov     ecx, 2500000
.pn_wait:
    call    NetPollBackground
    cmp     byte [NetPingGot], 0
    jne     .pn_reply
    dec     ecx
    jnz     .pn_wait

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingLost]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .pn_next

.pn_reply:
    inc     r13d
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingFrom]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [NetTargetIp]
    mov     rcx, 110
    call    NetPrintIp
    call    NewLine

.pn_next:
    inc     r12d
    cmp     r12d, 4
    jbe     .pn_loop

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgPingStat]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     eax, r13d
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 92
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     rcx, 110
    mov     rdx, [CursorY]
    lea     r8, [MsgPingOf4]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    jmp     .pn_done

.pn_dnsfail:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDnsFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .pn_done
.pn_nocard:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgNetFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.pn_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret


; ==========================================================
; ParseIp - розібрати рядок виду "8.8.8.8" у 4 байти.
;   RSI = рядок, RDI = куди покласти
;   -> CF=0 якщо це справді IP, CF=1 якщо ні (тоді це ім'я)
;
; Потрібно, щоб PING 8.8.8.8 не намагався резолвити "8.8.8.8"
; через DNS, а йшов на адресу напряму.
; ==========================================================
ParseIp:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi

    xor     ecx, ecx                ; скільки чисел розібрали
.pi_part:
    xor     eax, eax                ; поточне число
    xor     edx, edx                ; скільки цифр у ньому
.pi_digit:
    mov     bl, [rsi]
    cmp     bl, '0'
    jb      .pi_end_num
    cmp     bl, '9'
    ja      .pi_end_num
    sub     bl, '0'
    imul    eax, 10
    movzx   ebx, bl
    add     eax, ebx
    cmp     eax, 255                ; байт не може бути більшим
    ja      .pi_fail
    inc     rsi
    inc     edx
    cmp     edx, 3
    jbe     .pi_digit
.pi_end_num:
    test    edx, edx
    jz      .pi_fail                ; жодної цифри - це не IP
    mov     [rdi], al
    inc     rdi
    inc     ecx
    cmp     ecx, 4
    je      .pi_last

    cmp     byte [rsi], '.'
    jne     .pi_fail
    inc     rsi
    jmp     .pi_part

.pi_last:
    ; після четвертого числа має бути кінець рядка або пробіл
    mov     bl, [rsi]
    test    bl, bl
    jz      .pi_ok
    cmp     bl, ' '
    je      .pi_ok
.pi_fail:
    stc
    jmp     .pi_exit
.pi_ok:
    clc
.pi_exit:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; SetDnsCommand - SETDNS <адреса>
; Потрібна, коли DNS-сервер, виданий по DHCP, не працює:
; у режимі QEMU 'user' slirp проксює запити на DNS хоста,
; і якщо той мертвий, гість теж нічого не отримає.
; ==========================================================
; ==========================================================
; TCP <ip> <порт> - відкрити з'єднання й одразу закрити.
;
; Команда навмисно нічого не передає: вона перевіряє саме рукостискання,
; тобто найтоншу частину. Якщо SYN пішов, SYN+ACK повернувся і наш ACK
; прийняли - решта протоколу вже справа техніки.
; ==========================================================
TcpCommand:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9

    lea     rsi, [CmdBuffer + 4]    ; хвіст після 'TCP '
    lea     rdi, [TcpCmdIp]
    call    ParseIp
    jc      .tcmd_bad

    ; ParseIp зберігає RSI і повертає його на початок рядка, тому
    ; пропустити адресу доводиться самим: цифри й крапки, потім
    ; пробіли. Без цього порт розбирався з початку рядка - і замість
    ; 80 виходило 10.
.tcmd_skipip:
    mov     al, [rsi]
    cmp     al, '.'
    je      .tcmd_adv
    cmp     al, '0'
    jb      .tcmd_skipsp
    cmp     al, '9'
    ja      .tcmd_skipsp
.tcmd_adv:
    inc     rsi
    jmp     .tcmd_skipip
.tcmd_skipsp:
    cmp     byte [rsi], ' '
    jne     .tcmd_port
    inc     rsi
    jmp     .tcmd_skipsp
.tcmd_port:
    call    TcpParsePort
    jc      .tcmd_bad
    ; Порт кладемо в пам'ять: DrawString нижче затирає RCX, а тримати
    ; його в регістрі через півдесятка викликів - шукати біду.
    mov     [TcpCmdPort], ax

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTcpTrying]
    mov     r9d, COL_TEXT
    call    DrawString
    lea     rsi, [TcpCmdIp]
    mov     rcx, 130
    call    NetPrintIp

    ; Порт друкуємо теж - саме на ньому вже раз і спіткнулися:
    ; ParseIp повертала RSI на початок, і замість 80 виходило 10.
    movzx   eax, word [TcpCmdPort]
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 230
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    lea     rsi, [TcpCmdIp]
    mov     cx, [TcpCmdPort]
    call    TcpConnect
    jc      .tcmd_fail

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTcpOk]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    call    TcpCloseConn
    jmp     .tcmd_done

.tcmd_fail:
    ; Кожна причина має власне пояснення. Найважливіше з них - RST:
    ; він означає, що наш пакет дійшов і його зрозуміли, тобто сам
    ; протокол працює, а закритий лише порт.
    lea     r8, [MsgTcpTimeout]
    cmp     byte [TcpFailWhy], 1
    jne     .tcf_n1
    lea     r8, [MsgTcpNoCard]
.tcf_n1:
    cmp     byte [TcpFailWhy], 2
    jne     .tcf_n2
    lea     r8, [MsgTcpNoArp]
.tcf_n2:
    cmp     byte [TcpFailWhy], 3
    jne     .tcf_n3
    lea     r8, [MsgTcpNoSend]
.tcf_n3:
    cmp     byte [TcpFailWhy], 4
    jne     .tcf_n4
    lea     r8, [MsgTcpRst]
.tcf_n4:
    mov     rcx, 10
    mov     rdx, [CursorY]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

    ; Скільки TCP-сегментів побачили. Нуль означає, що назад не
    ; прийшло нічого - шукати треба в тому, ЩО ми відправляємо.
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTcpSeen]
    mov     r9d, COL_DIM
    call    DrawString
    mov     eax, [TcpRxSegs]
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 220
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_DIM
    call    DrawString
    call    NewLine
    jmp     .tcmd_done

.tcmd_bad:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTcpUsage]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

.tcmd_done:
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; GET <ip> - забрати кореневу сторінку по HTTP.
;
; Запит навмисно HTTP/1.0 і без заголовка Host: у 1.0 він не
; обов'язковий, а будувати його з адреси заради перевірки транспорту
; сенсу немає. Версія 1.0 зручна ще й тим, що сервер сам закриває
; з'єднання, віддавши відповідь, - тобто FIN приходить природно, і
; нам не треба вгадувати, скільки байтів чекати.
; ==========================================================
; ----------------------------------------------------------
; StrAppendZ - дописати рядок RSI у кінець RDI.
; RDI лишається за останнім скопійованим байтом, нуля не кладемо:
; рядок збирається шматками, і термінатор ставить той, хто закінчив.
; RSI не псуємо.
; ----------------------------------------------------------
StrAppendZ:
    push    rax
    push    rsi
.saz_loop:
    mov     al, [rsi]
    test    al, al
    jz      .saz_done
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     .saz_loop
.saz_done:
    pop     rsi
    pop     rax
    ret

; ==========================================================
; GET <хост> [шлях] - забрати сторінку по HTTP.
;
; Хост можна писати і адресою, і іменем: спершу пробуємо розібрати
; як IP, і лише коли не виходить - питаємо DNS. Так GET 1.1.1.1 не
; йде резолвити рядок "1.1.1.1", як колись робив PING.
;
; Запит - HTTP/1.0 із заголовком Host:. Без нього сервери з іменним
; хостингом віддають чужу сторінку або помилку: на одній адресі їх
; сотні, і розрізняє їх саме цей рядок. Версія 1.0 зручна тим, що
; сервер сам закриває з'єднання, віддавши відповідь, - FIN приходить
; природно, і не треба вгадувати, скільки байтів чекати.
; ==========================================================
HttpGetCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13

    ; Без картки не буде ні DNS, ні з'єднання. Перевіряємо тут, бо
    ; інакше помилка виходить брехлива: резолвер спиняється на ARP і
    ; каже "не змогла розв'язати ім'я", хоча мережі просто немає.
    cmp     byte [NetReady], 0
    jne     .hg_card_ok
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTcpNoCard]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .hg_done
.hg_card_ok:

    lea     rsi, [CmdBuffer + 4]    ; хвіст після .GET .
    mov     r12, rsi                ; початок імені хоста

    ; --- Розрізаємо на хост і шлях ---
.hg_tok:
    mov     al, [rsi]
    test    al, al
    jz      .hg_nopath
    cmp     al, ' '
    je      .hg_split
    inc     rsi
    jmp     .hg_tok
.hg_split:
    mov     byte [rsi], 0           ; обриваємо ім'я просто в рядку команди
    inc     rsi
.hg_sp:
    cmp     byte [rsi], ' '
    jne     .hg_havepath
    inc     rsi
    jmp     .hg_sp
.hg_havepath:
    cmp     byte [rsi], 0
    je      .hg_nopath
    lea     rdi, [HttpPath]
    call    StrAppendZ
    mov     byte [rdi], 0
    jmp     .hg_haveall
.hg_nopath:
    mov     byte [HttpPath], '/'
    mov     byte [HttpPath + 1], 0
.hg_haveall:

    test    r12, r12
    jz      .hg_bad
    cmp     byte [r12], 0
    je      .hg_bad

    ; --- Адреса: спершу як IP, потім через DNS ---
    mov     rsi, r12
    lea     rdi, [TcpCmdIp]
    call    ParseIp
    jnc     .hg_haveip

    mov     rsi, r12
    call    NetResolve
    jc      .hg_dnsfail
    lea     rsi, [NetTargetIp]
    lea     rdi, [TcpCmdIp]
    mov     rcx, 4
    cld
    rep     movsb

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgHttpResolved]
    mov     r9d, COL_DIM
    call    DrawString
    lea     rsi, [TcpCmdIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
.hg_haveip:

    ; --- Збираємо запит ---
    lea     rdi, [HttpReqBuf]
    lea     rsi, [HttpTxtGet]
    call    StrAppendZ
    lea     rsi, [HttpPath]
    call    StrAppendZ
    lea     rsi, [HttpTxtVer]
    call    StrAppendZ
    mov     rsi, r12
    call    StrAppendZ
    lea     rsi, [HttpTxtTail]
    call    StrAppendZ
    lea     rax, [HttpReqBuf]
    mov     r13, rdi
    sub     r13, rax                ; R13 = довжина запиту

    mov     word [TcpCmdPort], 80
    lea     rsi, [TcpCmdIp]
    mov     cx, 80
    call    TcpConnect
    jc      .hg_failed

    lea     rsi, [HttpReqBuf]
    mov     ecx, r13d
    call    TcpSend
    jc      .hg_nosend

    call    TcpRecvWait
    call    TcpCloseConn

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgHttpBytes]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     eax, [TcpRxLen]
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 150
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    cmp     dword [TcpRxLen], 0
    je      .hg_done

    ; --- Друкуємо початок відповіді ---
    ;
    ; Рядки ріжемо на місці: буфер нам більше не потрібен, а копіювати
    ; кожен кудись іще - зайва робота заради нічого.
    mov     r12, TcpRxBase
    xor     r13d, r13d
.hg_line:
    cmp     r13d, 14                ; більше екран однаково не покаже
    jae     .hg_done
    mov     rsi, r12
.hg_scan:
    mov     eax, [TcpRxLen]
    mov     rbx, TcpRxBase
    add     rbx, rax
    cmp     r12, rbx
    jae     .hg_done                ; дані скінчились
    mov     al, [r12]
    cmp     al, 13
    je      .hg_eol
    cmp     al, 10
    je      .hg_eol
    inc     r12
    jmp     .hg_scan
.hg_eol:
    mov     byte [r12], 0
    inc     r12
    mov     al, [r12]
    cmp     al, 10                  ; за CR майже завжди йде LF
    jne     .hg_print
    inc     r12
.hg_print:
    mov     rcx, 10
    mov     rdx, [CursorY]
    mov     r8, rsi
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine
    inc     r13d
    jmp     .hg_line

.hg_nosend:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgHttpNoSend]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    call    TcpCloseConn
    jmp     .hg_done

.hg_dnsfail:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgHttpDnsFail]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

    ; Змінні діагностики в NetResolve були, але їх ніхто не друкував.
    ; Стадія каже, де саме воно спинилось: 1 - увійшли, 2 - MAC шлюзу
    ; відома, 3 - зібрали запит, 4 - повернулись із відправки. Четверта
    ; разом із "надіслано: 1" означає, що запит пішов, а відповіді немає.
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDnsStage]
    mov     r9d, COL_DIM
    call    DrawString
    mov     eax, [DnsStage]
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 210
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_DIM
    call    DrawString

    mov     rcx, 250
    mov     rdx, [CursorY]
    lea     r8, [MsgDnsTx]
    mov     r9d, COL_DIM
    call    DrawString
    movzx   eax, byte [DnsTxOk]
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 370
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_DIM
    call    DrawString
    call    NewLine
    jmp     .hg_done

.hg_failed:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgTcpTimeout]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
    jmp     .hg_done

.hg_bad:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgHttpUsage]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

.hg_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

SetDnsCommand:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9

    lea     rsi, [CmdBuffer + 7]    ; хвіст після 'SETDNS '
    lea     rdi, [NetDnsIp]
    call    ParseIp
    jc      .sd_bad

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgDhcpDns]
    mov     r9d, COL_BRIGHT
    call    DrawString
    lea     rsi, [NetDnsIp]
    mov     rcx, 130
    call    NetPrintIp
    call    NewLine
    jmp     .sd_done
.sd_bad:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgBadIp]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.sd_done:
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; COPY <джерело> <призначення>
;
; Читає файл цілком у службовий буфер і записує під новим ім'ям.
; Стеля - розмір буфера (16 МБ), цього вистачає навіть для ядра.
;
; Окремий випадок, який варто обробити: копіювання файлу в себе.
; Без перевірки FatWriteFile спершу обрізав би ланцюг до потрібної
; довжини, а потім писав дані, які вже прочитані в пам'ять - тобто
; спрацювало б, але сенсу нуль, а ризик є.
; ==========================================================
; ==========================================================
; INSTALL <файл> - поставити свіжозібраний бінарник ядром.
;
; Порядок навмисно такий: спершу поточне KERNEL.BIN відкладається
; у KERNEL.BAK, і лише потім на його місце лягає нове. Якщо
; резервна копія не записалась - не чіпаємо взагалі нічого.
;
; Відкотитись із робочої системи можна звичайним
;   COPY KERNEL.BAK KERNEL.BIN
; ==========================================================
InstallCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13

    ; --- джерело ---
    lea     rsi, [CmdBuffer + 8]        ; хвіст після 'INSTALL '
    cmp     byte [rsi], 0
    je      .in_noarg
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .in_nosrc
    test    dl, 0x10
    jnz     .in_isdir
    test    ebx, ebx
    jz      .in_empty
    cmp     ebx, 0x1000000              ; не більше за буфер завантаження
    ja      .in_toobig
    mov     r12d, ebx                   ; розмір нового ядра

    ; --- резервна копія поточного ядра ---
    lea     r8, [FatKernelBin]
    call    FindFAT32Entry
    jc      .in_nobak                   ; ядра на диску ще немає
    mov     r13d, ebx
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    lea     r8, [FatKernelBak]
    mov     ebx, r13d
    mov     r9, VideoMemoryBase
    call    FatWriteFile
    jc      .in_bakfail
.in_nobak:

    ; --- ставимо нове ---
    lea     rsi, [CmdBuffer + 8]
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .in_nosrc
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    lea     r8, [FatKernelBin]
    mov     ebx, r12d
    mov     r9, VideoMemoryBase
    call    FatWriteFile
    jc      .in_wrfail

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgInstOk]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgInstHint]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine
    jmp     .in_done

.in_noarg:
    lea     r8, [MsgInstUsage]
    jmp     .in_err
.in_nosrc:
    lea     r8, [MsgInstNoSrc]
    jmp     .in_err
.in_isdir:
    lea     r8, [MsgInstIsDir]
    jmp     .in_err
.in_empty:
    lea     r8, [MsgInstEmpty]
    jmp     .in_err
.in_toobig:
    lea     r8, [MsgInstBig]
    jmp     .in_err
.in_bakfail:
    lea     r8, [MsgInstBakFail]
    jmp     .in_err
.in_wrfail:
    lea     r8, [MsgInstWrFail]
.in_err:
    mov     rcx, 10
    mov     rdx, [CursorY]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.in_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; MEMMAP - показати карту пам'яті, отриману від прошивки.
;
; Це перший споживач блока відомостей від завантажувача і водночас
; перевірка того, що блок дійшов цілим. Далі ці самі числа стануть
; вхідними для розподільника фізичних кадрів: щоб виділити сторінку
; під власні таблиці, треба спершу знати, які сторінки вільні.
;
; Типи областей за специфікацією UEFI:
;   1,2   код і дані завантажувача - тут лежить саме ЯДРО, зайнято;
;   3,4   код і дані служб завантаження - після виходу вільні;
;   7     звичайна пам'ять - вільна;
;   решта прошивка, ACPI, MMIO - чіпати не можна.
; ==========================================================
; ==========================================================
; FrameAllocInit - побудувати бітову карту вільних кадрів.
;
; Біт = один кадр 4 КБ, рахуючи від FramePoolBase. Одиниця означає
; зайнято. Починаємо з усього зайнятого і звільняємо лише те, що
; прошивка назвала придатним: помилитись у бік "зайнято" безпечно,
; у бік "вільно" - ні.
;
; Придатним вважаємо тип 7 (звичайна пам'ять) і типи 3-4 (код і
; дані служб завантаження): після виходу зі служб вони наші.
; ==========================================================
FrameAllocInit:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    xor     rax, rax
    mov     [FrameCount], rax
    mov     [FrameFreeCount], rax
    mov     [FrameNextHint], rax

    cmp     qword [MemMapAddr], 0
    je      .fi_exit
    cmp     dword [MemMapDescSize], 0
    je      .fi_exit

    ; --- Перший прохід: де закінчується придатна пам'ять ---
    xor     r10, r10                ; верхня межа
    mov     rsi, [MemMapAddr]
    mov     rbx, rsi
    add     rbx, [MemMapSize]
    mov     ecx, [MemMapDescSize]
.fi_top:
    cmp     rsi, rbx
    jae     .fi_top_done
    mov     eax, [rsi]
    cmp     eax, 7
    je      .fi_top_take
    cmp     eax, 3
    jb      .fi_top_next
    cmp     eax, 4
    ja      .fi_top_next
.fi_top_take:
    mov     rdx, [rsi + 24]
    shl     rdx, 12
    add     rdx, [rsi + 8]          ; кінець області
    mov     rax, FRAME_LIMIT
    cmp     rdx, rax
    ja      .fi_top_next            ; вище 4 ГБ не беремо
    cmp     rdx, r10
    jbe     .fi_top_next
    mov     r10, rdx
.fi_top_next:
    add     rsi, rcx
    jmp     .fi_top
.fi_top_done:

    mov     rax, FramePoolBase
    cmp     r10, rax
    jbe     .fi_exit                ; придатної пам'яті вище межі немає

    ; Скільки кадрів обслуговуємо і скільки байтів під бітову карту
    sub     r10, rax
    shr     r10, 12                 ; кількість кадрів
    mov     [FrameCount], r10
    mov     r11, r10
    add     r11, 7
    shr     r11, 3                  ; байтів у бітовій карті
    mov     [FrameBitmapBytes], r11

    ; --- Усе зайняте ---
    mov     rdi, FrameBitmapBase
    mov     rcx, r11
    mov     al, 0xFF
    cld
    rep     stosb

    ; --- Другий прохід: звільняємо придатне ---
    mov     rsi, [MemMapAddr]
    mov     rbx, rsi
    add     rbx, [MemMapSize]
    mov     ecx, [MemMapDescSize]
.fi_free:
    cmp     rsi, rbx
    jae     .fi_free_done
    mov     eax, [rsi]
    cmp     eax, 7
    je      .fi_free_take
    cmp     eax, 3
    jb      .fi_free_next
    cmp     eax, 4
    ja      .fi_free_next
.fi_free_take:
    push    rbx
    push    rcx
    mov     r10, [rsi + 8]          ; початок області
    mov     r11, [rsi + 24]
    shl     r11, 12
    add     r11, r10                ; кінець області

    mov     rax, FramePoolBase
    cmp     r10, rax
    jae     .fi_lo_ok
    mov     r10, rax                ; обрізаємо знизу по межі пулу
.fi_lo_ok:
    mov     rax, [FrameCount]
    shl     rax, 12
    add     rax, FramePoolBase      ; кінець пулу
    cmp     r11, rax
    jbe     .fi_hi_ok
    mov     r11, rax                ; і зверху
.fi_hi_ok:
    cmp     r10, r11
    jae     .fi_free_pop            ; область цілком поза пулом

.fi_bit_loop:
    mov     rax, r10
    sub     rax, FramePoolBase
    shr     rax, 12                 ; номер кадру
    mov     rdx, rax
    shr     rdx, 3                  ; байт у бітовій карті
    and     eax, 7                  ; біт у байті
    mov     cl, al
    mov     al, 1
    shl     al, cl
    not     al
    and     [FrameBitmapBase + rdx], al
    inc     qword [FrameFreeCount]
    add     r10, 0x1000
    cmp     r10, r11
    jb      .fi_bit_loop

.fi_free_pop:
    pop     rcx
    pop     rbx
.fi_free_next:
    add     rsi, rcx
    jmp     .fi_free
.fi_free_done:

.fi_exit:
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; FrameAlloc -> RAX = фізична адреса вільного кадру, обнуленого,
;               або 0, якщо вільних немає.
; ==========================================================
FrameAlloc:
    push    rbx
    push    rcx
    push    rdx
    push    rdi

    cmp     qword [FrameFreeCount], 0
    je      .fa_none

    mov     rbx, [FrameNextHint]    ; звідки шукати цього разу
    xor     rcx, rcx                ; скільки кадрів переглянуто
.fa_scan:
    cmp     rcx, [FrameCount]
    jae     .fa_none
    cmp     rbx, [FrameCount]
    jb      .fa_no_wrap
    xor     rbx, rbx                ; дійшли до кінця - на початок
.fa_no_wrap:
    ; RDI тут робочий: у ньому байт бітової карти. Тримати його в
    ; RDX не можна - RDX і є індексом цього байта.
    mov     rdx, rbx
    shr     rdx, 3
    movzx   edi, byte [FrameBitmapBase + rdx]
    mov     rax, rbx
    and     eax, 7
    bt      edi, eax
    jnc     .fa_found
    inc     rbx
    inc     rcx
    jmp     .fa_scan

.fa_found:
    ; помітити зайнятим
    mov     rax, rbx
    mov     rdx, rax
    shr     rdx, 3
    and     eax, 7
    mov     cl, al
    mov     al, 1
    shl     al, cl
    or      [FrameBitmapBase + rdx], al
    dec     qword [FrameFreeCount]
    mov     rax, rbx
    inc     rax
    mov     [FrameNextHint], rax

    ; адреса кадру
    mov     rax, rbx
    shl     rax, 12
    add     rax, FramePoolBase

    ; Кадр віддаємо обнуленим: під сторінкові таблиці інакше не
    ; можна - сміття в невикористаних записах процесор тлумачить
    ; як справжні відображення.
    push    rax
    mov     rdi, rax
    mov     rcx, 512
    xor     eax, eax
    cld
    rep     stosq
    pop     rax
    jmp     .fa_exit

.fa_none:
    xor     rax, rax
.fa_exit:
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ==========================================================
; FrameFree - RAX = фізична адреса кадру, поверненого в пул.
; ==========================================================
FrameFree:
    push    rax
    push    rbx
    push    rcx
    push    rdx

    mov     rbx, FramePoolBase
    cmp     rax, rbx
    jb      .ff_exit                ; не наш кадр
    sub     rax, rbx
    shr     rax, 12
    cmp     rax, [FrameCount]
    jae     .ff_exit

    mov     rbx, rax
    mov     rdx, rax
    shr     rdx, 3
    and     eax, 7
    mov     cl, al
    mov     al, 1
    shl     al, cl
    test    [FrameBitmapBase + rdx], al
    jz      .ff_exit                ; уже вільний - подвійне звільнення
    not     al
    and     [FrameBitmapBase + rdx], al
    inc     qword [FrameFreeCount]
    mov     [FrameNextHint], rbx    ; наступний пошук почнеться звідси

.ff_exit:
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; PagingBuild - побудувати власні сторінкові таблиці.
;
; У довгому режимі пейджинг увімкнено ЗАВЖДИ: вимкнути його не
; можна, інакше процесор випаде з режиму. Тобто система й досі
; працює - але на таблицях, які лишила прошивка, у пам'яті, яку
; після виходу зі служб вона вважає вільною. Ядро виконується на
; структурах, які саме ж може затерти.
;
; Будуємо тотожне відображення 0..4 ГБ сторінками по 2 МБ:
;   PML4[0] -> PDPT
;   PDPT[0..3] -> чотири каталоги по 1 ГБ
;   кожен каталог - 512 записів по 2 МБ з бітом PS
;
; Чому саме 4 ГБ: уся пам'ять закінчується на 511 МБ, але
; фреймбуфер сидить на 2 ГБ, у дірі PCI. Менший діапазон лишив би
; систему без екрана. Більший не потрібен: 12 ГБ апертури під 1 ТіБ
; ми не адресуємо ніколи.
;
; Шість кадрів, 24 КБ. Тотожне відображення означає, що після
; перемикання геть нічого не має змінитися - це і є критерій
; правильності.
;
; -> RAX = фізична адреса PML4, або 0 якщо не вистачило кадрів
; ==========================================================
; ==========================================================
; PagingSplitEntry - розщепити один запис каталогу на таблицю
; з 512 сторінок по 4 КБ, лишивши одну з них невідображеною.
;
;   RSI = номер запису в першому каталозі (кожен описує 2 МБ)
;   RDI = номер сторінки всередині, яку лишити невідображеною
;   -> CF=1, якщо не вистачило кадру
;
; Вимкнути одну сторінку 4 КБ усередині сторінки 2 МБ не можна -
; тільки замінити всю сторінку таблицею. Звідси й процедура: ця
; дія потрібна щонайменше двічі.
;
; Біта PS у підмінному записі немає, і саме його відсутність
; каже процесору, що запис указує на таблицю, а не на велику
; сторінку. Одна зайва одиниця тут перетворила б 2 МБ пам'яті на
; випадкову адресу.
; ==========================================================
PagingSplitEntry:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8

    mov     r8, rsi                 ; запис каталогу
    mov     rbx, rdi                ; яку сторінку лишити невідображеною

    call    FrameAlloc
    test    rax, rax
    jz      .pse_fail
    mov     rsi, rax                ; нова таблиця

    mov     rax, r8
    shl     rax, 21                 ; база області: запис * 2 МБ

    xor     rcx, rcx
    mov     rdi, rsi
.pse_loop:
    cmp     rcx, rbx
    je      .pse_skip               ; нуль у запису = сторінки немає
    mov     rdx, rax
    or      rdx, 3                  ; present | writable
    mov     [rdi], rdx
.pse_skip:
    add     rdi, 8
    add     rax, 0x1000
    inc     rcx
    cmp     rcx, 512
    jb      .pse_loop

    mov     rdi, [PagePd0]
    mov     rax, rsi
    or      rax, 3                  ; без PS - це таблиця
    mov     [rdi + r8*8], rax
    clc
    jmp     .pse_exit

.pse_fail:
    stc
.pse_exit:
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; PagingCloneSpace - новий адресний простір, точна копія ядерного.
;
; -> RAX = фізична адреса нового PML4, або 0 якщо не вистачило кадрів
;
; Копія навмисно ТОЧНА. На цьому кроці перевіряється саме
; перемикання CR3, а не поділ пам'яті: якщо система живе з різними
; таблицями, які описують те саме, значить механізм працює - і лише
; тоді має сенс робити простори різними по суті.
;
; Копіюємо PDPT і PD0 цілком, по 512 записів кожен. Каталоги
; PD1..PD3 лишаються спільними: на них указує скопійований PDPT, і
; це правильно - там немає нічого, що мало б відрізнятися.
; ==========================================================
; ==========================================================
; PagingPrivatise - зробити групу записів каталогу власною.
;
;   RCX = перший запис, RDX = скільки їх
;   Каталог береться з [ClonePd0]
;   -> CF=1, якщо не вистачило кадрів
;
; Кожен запис замінюється порожньою таблицею. Кадр приходить
; обнуленим, а нуль у запису таблиці й означає "сторінки немає" -
; отже вся область стає невідображеною й підкачується на вимогу.
; ==========================================================
; ==========================================================
; PagingFreeGroup - звільнити групу приватних записів каталогу.
;
;   RDI = каталог, RCX = перший запис, RDX = скільки їх
;
; Спершу сторінки всередині таблиці, потім сама таблиця. Порядок
; саме такий: звільнивши таблицю першою, ми втратили б перелік
; сторінок, які вона описує, і вони лишились би зайнятими назавжди.
; ==========================================================
PagingFreeGroup:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
.pfg_entry:
    mov     rax, [rdi + rcx*8]
    test    al, 1
    jz      .pfg_next               ; запису немає - нічого звільняти
    shr     rax, 12
    shl     rax, 12
    mov     rbx, rax                ; таблиця сторінок

    xor     rsi, rsi
.pfg_page:
    mov     rax, [rbx + rsi*8]
    test    al, 1
    jz      .pfg_page_next
    shr     rax, 12
    shl     rax, 12
    call    FrameFree
.pfg_page_next:
    inc     rsi
    cmp     rsi, 512
    jb      .pfg_page

    mov     rax, rbx
    call    FrameFree               ; тепер і сама таблиця
    mov     qword [rdi + rcx*8], 0
.pfg_next:
    inc     rcx
    dec     rdx
    jnz     .pfg_entry
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; PagingFreeSpace - повернути в пул усе, що належало задачі.
;
;   RAX = фізична адреса PML4 простору
;
; Звільняємо ЛИШЕ приватні групи: вікно програми (31..39) і купу
; (128..191). Решта каталогу спільна з ядром, і звільнити її
; означало б забрати в ядра його ж пам'ять - причому непомітно, бо
; сторінки лишаться відображеними, доки хтось не візьме той кадр
; під щось інше.
; ==========================================================
PagingFreeSpace:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    mov     r10, rax                ; PML4
    test    r10, r10
    jz      .pfs_exit

    mov     rsi, [r10]              ; PML4[0] -> PDPT
    test    sil, 1
    jz      .pfs_pml4only
    shr     rsi, 12
    shl     rsi, 12
    mov     r11, rsi

    mov     rsi, [r11]              ; PDPT[0] -> PD0
    test    sil, 1
    jz      .pfs_nopd
    shr     rsi, 12
    shl     rsi, 12
    mov     rdi, rsi                ; каталог

    mov     rcx, 31                 ; стек і образ
    mov     rdx, 9
    call    PagingFreeGroup

    mov     rcx, UserHeapBase shr 21
    mov     rdx, UserHeapSize shr 21
    call    PagingFreeGroup

    mov     rax, rdi
    call    FrameFree               ; каталог
.pfs_nopd:
    mov     rax, r11
    call    FrameFree               ; PDPT
.pfs_pml4only:
    mov     rax, r10
    call    FrameFree               ; PML4
    inc     qword [SpacesFreed]

.pfs_exit:
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

PagingPrivatise:
    push    rax
    push    rcx
    push    rdx
    push    rdi
.pp_loop:
    call    FrameAlloc
    test    rax, rax
    jz      .pp_fail
    mov     rdi, [ClonePd0]
    or      rax, 3                  ; таблиця present, її записи - ні
    mov     [rdi + rcx*8], rax
    inc     rcx
    dec     rdx
    jnz     .pp_loop
    clc
    jmp     .pp_exit
.pp_fail:
    stc
.pp_exit:
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

PagingCloneSpace:
    push    rcx
    push    rsi
    push    rdi

    call    FrameAlloc
    test    rax, rax
    jz      .pcs_fail
    mov     [ClonePml4], rax

    call    FrameAlloc
    test    rax, rax
    jz      .pcs_fail
    mov     [ClonePdpt], rax

    call    FrameAlloc
    test    rax, rax
    jz      .pcs_fail
    mov     [ClonePd0], rax

    mov     rsi, [PagePdpt]
    mov     rdi, [ClonePdpt]
    mov     rcx, 512
    cld
    rep     movsq

    mov     rsi, [PagePd0]
    mov     rdi, [ClonePd0]
    mov     rcx, 512
    rep     movsq

    ; У новому PDPT нульовий запис має вести на ВЛАСНИЙ PD0, а не на
    ; ядерний - інакше копія описувала б чужі таблиці.
    mov     rax, [ClonePd0]
    or      rax, 3
    mov     rdi, [ClonePdpt]
    mov     [rdi], rax

    mov     rax, [ClonePdpt]
    or      rax, 3
    mov     rdi, [ClonePml4]
    mov     [rdi], rax

    ; --- Тепер робимо простір справді ВЛАСНИМ ---
    ;
    ; Скопійований каталог поки описує ті самі фізичні сторінки, що
    ; й ядерний. Підміняємо дві групи записів порожніми таблицями:
    ; вікно програми (стек і образ) та купу. Порожня таблиця означає,
    ; що сторінок немає - вони виникнуть на вимогу, кожна своя.
    ;
    ; Решта записів лишається спільною, і це принципово: там ядро,
    ; його стек, буфери й бітова карта кадрів. Підмінити зайвий запис
    ; означало б відібрати в ядра власний код посеред роботи.
    mov     rcx, 31                 ; стек (31) і образ (32..39)
    mov     rdx, 9
    call    PagingPrivatise
    jc      .pcs_fail

    mov     rcx, UserHeapBase shr 21
    mov     rdx, UserHeapSize shr 21
    call    PagingPrivatise
    jc      .pcs_fail

    inc     qword [SpacesMade]
    mov     rax, [ClonePml4]
    pop     rdi
    pop     rsi
    pop     rcx
    ret

.pcs_fail:
    xor     rax, rax
    pop     rdi
    pop     rsi
    pop     rcx
    ret

PagingBuild:
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9

    call    FrameAlloc
    test    rax, rax
    jz      .pb_fail
    mov     [PagePml4], rax

    call    FrameAlloc
    test    rax, rax
    jz      .pb_fail
    mov     [PagePdpt], rax

    ; PML4[0] -> PDPT. Решта 511 записів лишаються нулями: кадр
    ; приходить обнуленим, і це принципово - сміття в запису
    ; процесор тлумачить як справжнє відображення.
    mov     rdi, [PagePml4]
    mov     rax, [PagePdpt]
    or      rax, 3                  ; present | writable
    mov     [rdi], rax

    xor     r8, r8                  ; номер гігабайта
.pb_pd:
    call    FrameAlloc
    test    rax, rax
    jz      .pb_fail
    mov     rbx, rax                ; каталог сторінок
    test    r8, r8
    jnz     .pb_not_first
    mov     [PagePd0], rbx          ; перший каталог знадобиться нижче
.pb_not_first:

    mov     rdi, [PagePdpt]
    mov     rax, rbx
    or      rax, 3
    mov     [rdi + r8*8], rax

    ; 512 записів по 2 МБ підряд
    mov     rdi, rbx
    mov     rcx, 512
    mov     rax, r8
    shl     rax, 30                 ; база цього гігабайта
    or      rax, 0x83               ; present | writable | PS (2 МБ)
    ; За 2 ГБ пам'яті вже немає - там діра PCI, фреймбуфер і решта
    ; MMIO. Прошивка мапить її некешованою, і ми маємо так само:
    ; кешований запис у регістр пристрою дійде до нього тоді, коли
    ; кеш вирішить, а не коли ми написали. Під емулятором різниці
    ; не видно, на залізі - видно одразу.
    cmp     r8, 2
    jb      .pb_cache_ok
    or      rax, 0x10               ; PCD - заборона кешування
.pb_cache_ok:
.pb_pde:
    mov     [rdi], rax
    add     rdi, 8
    add     rax, 0x200000
    dec     rcx
    jnz     .pb_pde

    inc     r8
    cmp     r8, 4
    jb      .pb_pd

    ; --- Дві сторінки, які мають лишитися недоступними ---
    ;
    ; Нульова: розіменування нульового покажчика - найчастіша
    ; помилка в C. Зараз воно тихо пише в перший кілобайт пам'яті,
    ; а падає потім і зовсім в іншому місці.
    ;
    ; На 62 МБ: сторінка-вартовий під стеком програм. Стек росте
    ; вниз від 64 МБ, а на 48 МБ лежить буфер кадрів відео. Досі
    ; переповнення стека тихо псувало картинку.
    mov     rsi, 0                  ; перший запис каталогу: 0..2 МБ
    mov     rdi, 0                  ; нульова сторінка
    call    PagingSplitEntry
    jc      .pb_fail

    mov     rsi, 31                 ; запис 31: 62..64 МБ
    mov     rdi, 0                  ; найнижча сторінка області
    call    PagingSplitEntry
    jc      .pb_fail

    ; --- Купа програм: адреси є, сторінок немає ---
    ;
    ; 128 МБ під купу - це претензія на адресний простір, а не
    ; використання: справжня програма чіпає одиниці мегабайтів.
    ; Тому таблиці створюємо, а сторінки в них лишаємо відсутніми.
    ; Кадр з'явиться в мить першого звернення, і не раніше.
    ;
    ; Кадр приходить обнуленим, тож усі 512 записів таблиці вже
    ; означають "сторінки немає" - дописувати нічого не треба.
    mov     r8, UserHeapBase shr 21     ; перший запис каталогу
    mov     r9, UserHeapSize shr 21     ; скільки їх
.pb_heap:
    call    FrameAlloc
    test    rax, rax
    jz      .pb_fail
    mov     rdi, [PagePd0]
    or      rax, 3                      ; сама таблиця present, її записи - ні
    mov     [rdi + r8*8], rax
    inc     r8
    dec     r9
    jnz     .pb_heap

    mov     rax, [PagePml4]
    jmp     .pb_exit
.pb_fail:
    xor     rax, rax
.pb_exit:
    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ==========================================================
; PAGING - забрати сторінкові таблиці в прошивки.
;
; Зроблено командою, а не дією на старті, навмисно: хибне
; відображення вбиває машину на наступній же вибірці інструкції,
; без жодного повідомлення. Команду можна пережити перезапуском,
; старт - ні.
; ==========================================================
; ==========================================================
; PagingInit - викликається на старті, мовчки.
;
; Якщо кадрів немає (стара версія завантажувача не передала карту),
; лишаємось на таблицях прошивки й працюємо як раніше. Це не
; аварія: до цієї зміни система так жила завжди.
; ==========================================================
PagingInit:
    push    rax
    push    rcx
    call    PagingBuild
    test    rax, rax
    jz      .pi_exit
    mov     cr3, rax                ; TLB скидається сам

    ; Спершу всі слоти дивляться в простір ядра. Задача, яка не
    ; просила власного, працює в спільному - як і досі.
    xor     rcx, rcx
.pi_fill:
    mov     [TaskCR3 + rcx*8], rax
    inc     rcx
    cmp     rcx, MAX_TASKS
    jb      .pi_fill
.pi_exit:
    pop     rcx
    pop     rax
    ret

; ==========================================================
; PAGING - звіт про те, чиї таблиці зараз діють.
;
; Будувати їх удруге команда не має права: це коштувало б ще шести
; кадрів і не змінило б нічого. Тому лише показуємо стан.
; ==========================================================
PagingCommand:
    push    rax
    push    rcx
    push    rdx
    push    rdi

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgPgTitle]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    cmp     qword [PagePml4], 0
    je      .pg_firmware

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgPgOk]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine

    mov     rax, [PagePml4]
    lea     rdi, [MemMapNumBuf]
    call    HexToStr
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgPgPml4]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     rcx, 320
    mov     rdx, [CursorY]
    lea     r8,  [MemMapNumBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    ; CR3 читаємо з процесора, а не зі своєї змінної: збіг цих двох
    ; значень і є доказом, що діють саме наші таблиці.
    mov     rax, cr3
    lea     rdi, [MemMapNumBuf]
    call    HexToStr
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgPgCr3]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     rcx, 320
    mov     rdx, [CursorY]
    lea     r8,  [MemMapNumBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    mov     rax, 4
    lea     r8,  [MsgPgMapped]
    call    MemMapLine

    mov     rax, 8
    lea     r8,  [MsgPgFrames]
    call    MemMapLine
    jmp     .pg_exit

.pg_firmware:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgPgFirmware]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

.pg_exit:
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; TASKS - стан таблиці задач.
;
; Потрібна саме тепер: доти, доки слот був один, дивитись не було
; на що. Тепер це єдиний спосіб побачити, що слоти звільняються
; після виходу програми, а не течуть.
; ==========================================================
TasksCommand:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    r10

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgTasksTitle]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    mov     eax, MAX_TASKS
    lea     r8,  [MsgTasksSlots]
    call    MemMapLine

    xor     r10d, r10d
    xor     ecx, ecx
.tc_count:
    cmp     byte [TaskState + rcx], 1
    jne     .tc_next
    inc     r10d
.tc_next:
    inc     ecx
    cmp     ecx, MAX_TASKS
    jb      .tc_count

    mov     eax, r10d
    lea     r8,  [MsgTasksReady]
    call    MemMapLine

    ; Стан кожного слота окремо: одна цифра на слот. Підсумкове
    ; число каже, скільки задач готово, але не каже ЯКИХ - а саме
    ; це потрібно, коли підозрюєш, що звільнили не той слот.
    lea     rdi, [TaskLineBuf]
    xor     ecx, ecx
.tc_row:
    movzx   eax, byte [TaskState + rcx]
    add     al, 48
    mov     [rdi], al
    mov     byte [rdi + 1], 32
    add     rdi, 2
    inc     ecx
    cmp     ecx, MAX_TASKS
    jb      .tc_row
    mov     byte [rdi], 0

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgTasksEach]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     rcx, 320
    mov     rdx, [CursorY]
    lea     r8,  [TaskLineBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    mov     rax, [CurrentTask]
    lea     r8,  [MsgTasksCur]
    call    MemMapLine

    ; Число, яке має РОСТИ між двома викликами команди. Саме воно, а
    ; не позначка "готова", доводить, що задачі чергуються.
    mov     rax, [BgTicks]
    lea     r8,  [MsgTasksBg]
    call    MemMapLine

    ; Скільки сторінок купи програма справді зачепила. Різниця між
    ; цим числом і 32768 - тобто 128 МБ у сторінках - і є те, що
    ; демандна підкачка зекономила.
    mov     rax, [DemandPages]
    lea     r8,  [MsgTasksDemand]
    call    MemMapLine

    mov     rax, [SpacesMade]
    lea     r8,  [MsgTasksSpaces]
    call    MemMapLine

    mov     rax, [SpacesFreed]
    lea     r8,  [MsgTasksFreed]
    call    MemMapLine

    cmp     byte [AppRunning], 1
    jne     .tc_noapp
    mov     rax, [AppTask]
    lea     r8,  [MsgTasksApp]
    call    MemMapLine
    jmp     .tc_exit

.tc_noapp:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgTasksNoApp]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine

.tc_exit:
    pop     r10
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

MemMapCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgMmTitle]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    cmp     qword [MemMapAddr], 0
    je      .none
    cmp     dword [MemMapDescSize], 0
    je      .none

    ; Лічильники тримаємо в пам'яті, а не в регістрах: їх сім, і
    ; жонглювання регістрами тут дало б код, у якому помилку видно
    ; лише за результатом.
    xor     rax, rax
    mov     [MmFree], rax
    mov     [MmReclaim], rax
    mov     [MmOurs], rax
    mov     [MmResv], rax
    mov     [MmMmio], rax
    mov     [MmTop], rax
    mov     dword [MmEntries], 0

    mov     rsi, [MemMapAddr]
    mov     rbx, rsi
    add     rbx, [MemMapSize]
    mov     ecx, [MemMapDescSize]   ; 32-бітний mov сам обнуляє старші біти RCX

.mm_loop:
    cmp     rsi, rbx
    jae     .mm_done
    inc     dword [MmEntries]
    mov     eax, [rsi]              ; тип області
    mov     rdx, [rsi + 24]         ; кількість сторінок по 4 КБ

    ; Найвища адреса, якої взагалі торкається карта. Саме її має
    ; накрити тотожне відображення, коли ядро візьме сторінкові
    ; таблиці собі: за нею лежить і фреймбуфер.
    push    rax
    mov     rax, rdx
    shl     rax, 12
    add     rax, [rsi + 8]          ; PhysicalStart + розмір
    cmp     rax, [MmTop]
    jbe     .mm_no_top
    mov     [MmTop], rax
.mm_no_top:
    pop     rax

    cmp     eax, 7
    je      .mm_free
    cmp     eax, 11
    je      .mm_mmio
    cmp     eax, 12
    je      .mm_mmio
    cmp     eax, 3
    jb      .mm_check_ours
    cmp     eax, 4
    jbe     .mm_reclaim
.mm_resv:
    add     [MmResv], rdx
    jmp     .mm_next
.mm_check_ours:
    cmp     eax, 1
    jb      .mm_resv
    add     [MmOurs], rdx
    jmp     .mm_next
.mm_free:
    add     [MmFree], rdx
    jmp     .mm_next
.mm_reclaim:
    add     [MmReclaim], rdx
    jmp     .mm_next
.mm_mmio:
    add     [MmMmio], rdx
.mm_next:
    add     rsi, rcx
    jmp     .mm_loop

.mm_done:
    mov     eax, [MmEntries]
    lea     r8,  [MsgMmEntries]
    call    MemMapLine

    mov     rax, [MmFree]
    shr     rax, 8                  ; сторінки по 4 КБ -> мегабайти
    lea     r8,  [MsgMmFree]
    call    MemMapLine

    mov     rax, [MmReclaim]
    shr     rax, 8
    lea     r8,  [MsgMmReclaim]
    call    MemMapLine

    ; Наше - це образ ядра, блок відомостей і сам завантажувач.
    ; У мегабайтах це округлялось до нуля, тому тут кілобайти.
    mov     rax, [MmOurs]
    shl     rax, 2                  ; сторінки -> кілобайти
    lea     r8,  [MsgMmOurs]
    call    MemMapLine

    mov     rax, [MmResv]
    shr     rax, 8
    lea     r8,  [MsgMmResv]
    call    MemMapLine

    ; MMIO - не пам'ять. За цими адресами відповідають пристрої, і
    ; саме через них розмір "зайнятого" виглядає більшим за RAM.
    mov     rax, [MmMmio]
    shr     rax, 8
    lea     r8,  [MsgMmMmio]
    call    MemMapLine

    mov     rax, [MmTop]
    shr     rax, 20                 ; байти -> мегабайти
    lea     r8,  [MsgMmTop]
    call    MemMapLine

    mov     rax, [ScreenBase]
    shr     rax, 20
    lea     r8,  [MsgMmFb]
    call    MemMapLine

    mov     rax, [FrameCount]
    lea     r8,  [MsgMmFrames]
    call    MemMapLine

    mov     rax, [FrameFreeCount]
    lea     r8,  [MsgMmFramesFree]
    call    MemMapLine
    jmp     .mm_exit

.none:
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8,  [MsgMmNone]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine

.mm_exit:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

MemMapLine:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9

    ; Число переводимо ПЕРШИМ, поки RAX іще цілий: DrawString своїх
    ; гарантій щодо регістрів не дає.
    lea     rdi, [MemMapNumBuf]
    call    DecToStr

    mov     rcx, 10
    mov     rdx, [CursorY]
    mov     r9d, COL_TEXT
    call    DrawString              ; R8 = підпис

    mov     rcx, 320
    mov     rdx, [CursorY]
    lea     r8,  [MemMapNumBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

CopyCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12
    push    r13

    ; --- Шукаємо межу між двома іменами ---
    lea     rsi, [CmdBuffer + 5]    ; хвіст після 'COPY '
    mov     r12, rsi                ; R12 = джерело
    xor     ecx, ecx
.cc_find:
    mov     al, [rsi + rcx]
    test    al, al
    jz      .cc_noarg               ; другого імені немає
    cmp     al, ' '
    je      .cc_found
    inc     ecx
    cmp     ecx, 60
    jb      .cc_find
    jmp     .cc_noarg
.cc_found:
    inc     ecx                     ; пропускаємо сам пробіл
    lea     r13, [rsi + rcx]        ; R13 = призначення
    cmp     byte [r13], 0
    je      .cc_noarg

    ; --- Читаємо джерело ---
    mov     rsi, r12
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .cc_nosrc
    test    dl, 0x10                ; це каталог?
    jnz     .cc_isdir

    mov     r9d, ebx                ; R9 = розмір файлу
    cmp     r9d, 0x1000000          ; не більший за буфер (16 МБ)
    ja      .cc_toobig

    push    r9
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    pop     r9

    ; --- Записуємо під новим ім'ям ---
    mov     rsi, r13
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    mov     rbx, r9                 ; розмір
    mov     r9, VideoMemoryBase     ; дані
    call    FatWriteFile
    jc      .cc_wrfail

    ; --- Повідомляємо про успіх ---
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgCopied]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     rcx, 90
    mov     rdx, [CursorY]
    lea     r8, [ParsedFileName]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
    jmp     .cc_done

.cc_noarg:
    lea     r8, [MsgCopyUsage]
    jmp     .cc_err
.cc_nosrc:
    lea     r8, [MsgCopyNoSrc]
    jmp     .cc_err
.cc_isdir:
    lea     r8, [MsgCopyIsDir]
    jmp     .cc_err
.cc_toobig:
    lea     r8, [MsgCopyBig]
    jmp     .cc_err
.cc_wrfail:
    lea     r8, [MsgCopyFail]
.cc_err:
    mov     rcx, 10
    mov     rdx, [CursorY]
    mov     r9d, COL_ERROR
    call    DrawString
    call    NewLine
.cc_done:
    pop     r13
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret


; ==========================================================
; ВИЯВЛЕННЯ ЯДЕР ПРОЦЕСОРА (ACPI)
;
; Це фундамент для майбутнього SMP. Сам запуск ядер тут НЕ
; робиться - лише з'ясовуємо, скільки їх є і які в них номери.
;
; Ланцюжок такий:
;   RSDP  - знаходимо сигнатуру 'RSD PTR ' у пам'яті BIOS
;   XSDT  - таблиця вказівників на інші таблиці
;   MADT  - серед них шукаємо 'APIC', там список процесорів
;
; У MADT записи йдуть підряд: [тип][довжина][дані]. Тип 0 -
; локальний APIC, тобто одне ядро. Прапорець 'увімкнене' у
; біті 0 - вимкнені ядра рахувати не можна.
; ==========================================================

; ScanCpus - порахувати ядра. Результат у CpuCount, ID у CpuIds.
ScanCpus:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12

    mov     dword [CpuCount], 0
    mov     qword [AcpiRsdp], 0

    ; --- Шукаємо RSDP у розширеній області BIOS (0xE0000..0xFFFFF) ---
    ; Сигнатура вирівняна на 16 байт, тому крок 16.
    mov     rsi, 0xE0000
.sc_find:
    cmp     rsi, 0x100000
    jae     .sc_no_acpi
    mov     rax, [rsi]
    mov     rbx, 'RSD PTR '
    cmp     rax, rbx
    je      .sc_found_rsdp
    add     rsi, 16
    jmp     .sc_find

.sc_found_rsdp:
    mov     [AcpiRsdp], rsi

    ; Версія 2.0+ має XSDT з 64-бітними вказівниками (зміщення 24).
    ; Версія 1.0 - лише RSDT з 32-бітними (зміщення 16).
    movzx   eax, byte [rsi + 15]    ; Revision
    test    eax, eax
    jz      .sc_use_rsdt
    mov     r10, [rsi + 24]         ; XSDT
    mov     byte [AcpiIsXsdt], 1
    jmp     .sc_have_table
.sc_use_rsdt:
    mov     r10d, [rsi + 16]        ; RSDT
    mov     byte [AcpiIsXsdt], 0
.sc_have_table:
    test    r10, r10
    jz      .sc_no_acpi

    ; --- Перебираємо вказівники в таблиці, шукаємо MADT ---
    mov     eax, [r10 + 4]          ; довжина таблиці
    sub     eax, 36                 ; мінус заголовок
    xor     r11d, r11d              ; лічильник записів
    mov     ecx, 4
    cmp     byte [AcpiIsXsdt], 0
    je      .sc_step_ok
    mov     ecx, 8                  ; в XSDT вказівники по 8 байт
.sc_step_ok:
    xor     edx, edx
    div     ecx                     ; EAX = скільки записів
    mov     r11d, eax

    lea     r12, [r10 + 36]         ; перший вказівник
.sc_next_tbl:
    test    r11d, r11d
    jz      .sc_no_madt
    cmp     byte [AcpiIsXsdt], 0
    je      .sc_rd32
    mov     rsi, [r12]
    add     r12, 8
    jmp     .sc_check
.sc_rd32:
    mov     esi, [r12]
    add     r12, 4
.sc_check:
    dec     r11d
    test    rsi, rsi
    jz      .sc_next_tbl
    mov     eax, [rsi]
    cmp     eax, 'APIC'             ; сигнатура MADT
    jne     .sc_next_tbl

    ; --- Знайшли MADT: перебираємо записи ---
    mov     [AcpiMadt], rsi
    mov     eax, [rsi + 36]         ; адреса локального APIC
    mov     [LapicBase], eax
    mov     ecx, [rsi + 4]          ; довжина всієї таблиці
    lea     rdi, [rsi + 44]         ; перший запис
    add     rsi, rcx                ; кінець таблиці

.sc_entry:
    cmp     rdi, rsi
    jae     .sc_done
    movzx   eax, byte [rdi]         ; тип запису
    movzx   ebx, byte [rdi + 1]     ; довжина
    test    ebx, ebx
    jz      .sc_done                ; нульова довжина - зациклилися б

    test    al, al                  ; тип 0 = локальний APIC (ядро)
    jnz     .sc_entry_next
    mov     eax, [rdi + 4]          ; прапорці
    test    eax, 1                  ; біт 0 = ядро увімкнене
    jz      .sc_entry_next          ; вимкнені не рахуємо

    mov     ecx, [CpuCount]
    cmp     ecx, MAX_CPUS
    jae     .sc_entry_next
    movzx   eax, byte [rdi + 3]     ; APIC ID
    lea     rdx, [CpuIds]
    mov     [rdx + rcx], al
    inc     dword [CpuCount]

.sc_entry_next:
    add     rdi, rbx
    jmp     .sc_entry

.sc_no_madt:
.sc_no_acpi:
    ; ACPI немає або таблиця не знайшлася - вважаємо, що ядро одне
    cmp     dword [CpuCount], 0
    jne     .sc_done
    mov     dword [CpuCount], 1
.sc_done:
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; CpuInfoCommand - команда CPUINFO
; ==========================================================
CpuInfoCommand:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r12

    call    ScanCpus

    ; --- Назва процесора через CPUID ---
    ; Функції 0x80000002..4 віддають 48 символів назви у EAX,EBX,ECX,EDX.
    mov     eax, 0x80000000
    cpuid
    cmp     eax, 0x80000004
    jb      .ci_no_brand

    lea     rdi, [CpuBrand]
    mov     r12d, 0x80000002
.ci_brand:
    mov     eax, r12d
    cpuid
    mov     [rdi], eax
    mov     [rdi + 4], ebx
    mov     [rdi + 8], ecx
    mov     [rdi + 12], edx
    add     rdi, 16
    inc     r12d
    cmp     r12d, 0x80000005
    jb      .ci_brand
    mov     byte [rdi], 0

    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [CpuBrand]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine
.ci_no_brand:

    ; --- Кількість ядер ---
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgCpuCores]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     eax, [CpuCount]
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 130
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    call    NewLine

    ; --- Список APIC ID ---
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgCpuIds]
    mov     r9d, COL_TEXT
    call    DrawString
    xor     r12d, r12d
    mov     rcx, 110
.ci_ids:
    cmp     r12d, [CpuCount]
    jae     .ci_ids_done
    cmp     r12d, MAX_CPUS
    jae     .ci_ids_done
    lea     rdi, [CpuIds]
    movzx   eax, byte [rdi + r12]
    mov     dl, 2
    call    PciPrintHex
    add     rcx, 27
    inc     r12d
    jmp     .ci_ids
.ci_ids_done:
    call    NewLine

    ; --- Адреса локального APIC ---
    cmp     dword [LapicBase], 0
    je      .ci_no_lapic
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgCpuLapic]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     eax, [LapicBase]
    mov     rcx, 130
    mov     dl, 8
    call    PciPrintHex
    call    NewLine
.ci_no_lapic:

    ; --- Скільки пам'яті під купами ---
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgCpuHeap]
    mov     r9d, COL_TEXT
    call    DrawString
    mov     eax, UserHeapSize / 1024 / 1024
    lea     rdi, [PciBuf]
    call    DecToStr
    mov     rcx, 160
    mov     rdx, [CursorY]
    lea     r8, [PciBuf]
    mov     r9d, COL_BRIGHT
    call    DrawString
    mov     rcx, 190
    mov     rdx, [CursorY]
    lea     r8, [MsgCpuMb]
    mov     r9d, COL_TEXT
    call    DrawString
    call    NewLine

    ; --- Чесно кажемо, що ядра поки не використовуються ---
    cmp     dword [CpuCount], 1
    jbe     .ci_done
    mov     rcx, 10
    mov     rdx, [CursorY]
    lea     r8, [MsgCpuSmp]
    mov     r9d, COL_DIM
    call    DrawString
    call    NewLine
.ci_done:
    pop     r12
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret


InitInterrupts:
    mov     ax, cs
    mov     [CodeSegment], ax

    lea     rax, [IDT]
    mov     qword [IDTR + 2], rax

    mov     rcx, 0                  
    lea     rsi, [ExceptionVectors] 
.register_exceptions:
    mov     rdx, [rsi + rcx*8]      
    call    SetIDTGate              
    inc     rcx
    cmp     rcx, 32                 
    jl      .register_exceptions

    mov     rcx, 32
    lea     rdx, [TimerHandler]
    call    SetIDTGate

    mov     rcx, 128
    lea     rdx, [SyscallHandler]
    call    SetIDTGate

    lidt    [IDTR]

    mov     al, 0x11
    out     0x20, al
    out     0xA0, al
    mov     al, 0x20            
    out     0x21, al
    mov     al, 0x28            
    out     0xA1, al
    mov     al, 4
    out     0x21, al
    mov     al, 2
    out     0xA1, al
    mov     al, 1
    out     0x21, al
    out     0xA1, al

    mov     al, 11111110b       
    out     0x21, al
    mov     al, 11111111b
    out     0xA1, al

    mov     al, 00110100b       
    out     0x43, al
    mov     ax, 1193            
    out     0x40, al
    mov     al, ah
    out     0x40, al

    sti                         
    ret

SetIDTGate:
    ; ВХІД: RCX = номер вектора, RDX = адреса обробника
    ; ВИПРАВЛЕНО: раніше функція знищувала RCX та RDX,
    ; через що цикл реєстрації винятків встановлював
    ; лише вектори 0, 1 і 17 (0 -> 1 -> 17 -> 273 -> вихід з циклу).
    push    rax
    push    rbx
    push    rcx
    push    rdx
    shl     rcx, 4              
    lea     rbx, [IDT + rcx]
    
    mov     rax, rdx
    mov     word [rbx], ax      
    
    mov     ax, [CodeSegment]
    mov     word [rbx + 2], ax  
    
    mov     word [rbx + 4], 0x8E00 
    
    shr     rdx, 16
    mov     word [rbx + 6], dx  
    
    shr     rdx, 16
    mov     dword [rbx + 8], edx 
    mov     dword [rbx + 12], 0  
    
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

align 16
TimerHandler:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rbp
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rax, [CurrentTask]
    mov     [TaskRSP + rax*8], rsp

    inc     qword [SystemTicks]
    mov     rax, [SystemTicks]
    and     rax, 0x100
    jz      .draw_black
    mov     eax, 0x00FF0000
    jmp     .draw_dot
.draw_black:
    mov     eax, 0x00000000
.draw_dot:
    mov     rdi, [ScreenBase]
    stosd

    mov     al, 0x20
    out     0x20, al

    ; --- Наступна ГОТОВА задача ---
    ;
    ; Обходимо слоти по колу, починаючи з наступного за поточним, і
    ; беремо перший готовий. Задача 0 - ядро - готова завжди, тому
    ; цикл гарантовано має чим закінчитись.
    ;
    ; Раніше тут була не черга, а розгалуження на два випадки:
    ; "працює програма" і "не працює". Слот був один, і питання
    ; "яка задача наступна" не існувало.
    mov     rcx, MAX_TASKS
    mov     rax, [CurrentTask]
.next_slot:
    inc     rax
    cmp     rax, MAX_TASKS
    jl      .slot_wrapped
    xor     rax, rax
.slot_wrapped:
    cmp     byte [TaskState + rax], 1
    je      .set_task
    dec     rcx
    jnz     .next_slot
    xor     rax, rax                ; готових немає - лишається ядро
.set_task:
    mov     [CurrentTask], rax    

    ; --- Простір і стек перемикаються ПОРУЧ ---
    ;
    ; Між mov cr3 і mov rsp не має бути жодного звернення до стека.
    ; Після зміни CR3 діє вже новий простір, а RSP іще вказує на
    ; стек попередньої задачі, якого в новому просторі може не бути.
    ; Будь-який push, call чи переривання в цю мить дасть відмову
    ; сторінки на неіснуючому стеку - тобто подвійну помилку й ребут.
    ;
    ; Перевірка на збіг не косметична: перезавантаження CR3 скидає
    ; весь TLB. Без неї ми скидали б його тисячу разів на секунду
    ; навіть тоді, коли простір той самий.
    mov     rbx, [TaskCR3 + rax*8]
    mov     rcx, cr3
    cmp     rbx, rcx
    je      .cr3_same
    mov     cr3, rbx
.cr3_same:
    mov     rsp, [TaskRSP + rax*8]

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax

    iretq                           

align 16
SyscallHandler:
    cmp     rax, 0                  
    je      .sys_exit

    push    rcx
    push    rdx
    push    rbx
    push    rbp
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15

    ; Виклики, що працюють із диском, спершу дочікуються, поки ядро
    ; закінчить своє читання. Перевірка тут, а не по тілах: одне
    ; місце легше тримати повним, ніж вісімнадцять.
    call    FsWaitIfNeeded

    cmp     rax, 1                  
    je      .sys_getkey
    cmp     rax, 2
    je      .sys_print 
    cmp     rax, 4                  
    je      .sys_clear              
    cmp     rax, 5                  
    je      .sys_readfile           
    cmp     rax, 6                  
    je      .sys_putchar
    cmp     rax, 7                  
    je      .sys_erasechar
    cmp     rax, 8                  
    je      .sys_ls                 
    cmp     rax, 9                  
    je      .sys_blit               
    cmp     rax, 10                 
    je      .sys_getticks           
    cmp     rax, 11                 ; Отримати мишу
    je      .sys_getmouse           
    cmp     rax, 12
    je      .sys_get_time
    cmp     rax, 13
    je      .sys_get_file_list
    cmp     rax, 14
    je      .sys_writefile
    cmp     rax, 15                 ; розмір екрана
    je      .sys_screen_info
    cmp     rax, 16                 ; open
    je      .sys_open
    cmp     rax, 17                 ; read
    je      .sys_read
    cmp     rax, 18                 ; write
    je      .sys_write
    cmp     rax, 19                 ; lseek
    je      .sys_lseek
    cmp     rax, 20                 ; close
    je      .sys_close
    cmp     rax, 21                 ; аргументи командного рядка
    je      .sys_get_args
    cmp     rax, 22                 ; заливка прямокутника
    je      .sys_fill_rect
    cmp     rax, 23                 ; хто малює курсор миші
    je      .sys_cursor_owner
    ; --- НОВІ ФОРМИ СТАРИХ ВИКЛИКІВ ---
    ; Номери 1, 5 і 9 зафіксовані назавжди у тому вигляді, у якому їх
    ; бачать готові бінарники на диску (порт DOOM зібрано до цих змін).
    ; Усе, що ми додали пізніше, живе під власними номерами.
    cmp     rax, 24                 ; читання файлу з лімітом (нова форма 5)
    je      .sys_readfile_max
    cmp     rax, 25                 ; blit із власним кроком рядка (нова форма 9)
    je      .sys_blit_stride
    cmp     rax, 26                 ; клавіша з ASCII та модифікаторами (нова форма 1)
    je      .sys_keyevent
    cmp     rax, 28                 ; запустити іншу програму
    je      .sys_exec
    cmp     rax, 29                 ; змінити поточний каталог
    je      .sys_chdir
    cmp     rax, 30                 ; поточний шлях рядком
    je      .sys_getcwd
    cmp     rax, 31                 ; крок рядка фреймбуфера
    je      .sys_screen_stride
    cmp     rax, 32                 ; видалити файл
    je      .sys_unlink
    cmp     rax, 33                 ; створити каталог
    je      .sys_mkdir
    cmp     rax, 34                 ; перейменувати
    je      .sys_rename
    cmp     rax, 35                 ; копіювати файл
    je      .sys_copy
    cmp     rax, 36                 ; тип файлу
    je      .sys_filetype
    cmp     rax, 37                 ; запустити програму й лишитись живим
    je      .sys_spawn
    cmp     rax, 38                 ; каталог із розміром, датою й атрибутами
    je      .sys_dirinfo
    cmp     rax, 39                 ; відкрити відео для показу у вікні
    je      .sys_video_open
    cmp     rax, 40                 ; розкодувати наступний кадр
    je      .sys_video_frame
    cmp     rax, 41                 ; запустити програму у вікні
    je      .sys_spawn_windowed
    cmp     rax, 42                 ; чи жива дитина
    je      .sys_child_alive
    cmp     rax, 43                 ; кому діставатись клавішам
    je      .sys_keys_to_child
    cmp     rax, 44                 ; лічильник кадрів у полотні
    je      .sys_canvas_seq
    cmp     rax, 45                 ; віддати решту кванта
    je      .sys_yield
    cmp     rax, 46                 ; де лежить текст задачі у вікні
    je      .sys_app_text

    jmp     .syscall_end        

; syscall 28 - попросити ядро запустити іншу програму.
;   RSI = ім'я файлу ("DOOM.BIN")
;
; Програма при цьому НЕ зникає одразу: ми лише запам'ятовуємо
; прохання. Виконає його обробник RUN одразу після того, як
; поточна програма завершиться через syscall 0.
;
; Навіщо так. У ядрі рівно дві задачі (MAX_TASKS = 2), тобто
; одночасно жива лише ОДНА програма, і всі вони вантажаться за
; тією самою адресою AppMemoryBase. Тому «запустити з вікна»
; означає ланцюжок: оболонка йде, програма працює, а коли вона
; завершиться - ядро саме повертає оболонку назад. Стек ExecStack
; і тримає той шлях назад.
; syscall 31 - крок рядка фреймбуфера в пікселях.
;   -> RAX = PixelsPerScanLine
;
; Потрібен лише тим програмам, які пишуть у фреймбуфер НАПРЯМУ
; (адреса приходить у RDI при старті). Ті, що виводять через
; blit, крок не цікавить: рядки розкладає ядро.
;
; Окремий номер, а не розширення syscall 15: той повертає
; висоту й ширину одним числом, і його формат заморожений.
.sys_screen_stride:
    mov     rax, [CurrentTask]
    mov     rbx, [TaskCanvas + rax*8]
    test    rbx, rbx
    jz      .sss_real
    mov     eax, [TaskCanvasS + rax*4]  ; 32-бітний mov сам обнуляє верх
    jmp     .syscall_end
.sss_real:
    xor     rax, rax
    mov     eax, [ScreenStride]
    jmp     .syscall_end

; syscall 37 - запустити іншу програму й ЛИШИТИСЬ ЖИВИМ.
;   RSI = ім'я файлу
;
; Відмінність від 28 принципова. Той був ланцюжком: програма
; лишала прохання й мусила померти, а ядро запускало названу вже
; після неї. Оболонка через це вивантажувалась і після виходу гри
; вантажилась із диска заново.
;
; Тепер задача не вмирає, а ЗАСИНАЄ: слот, простір, стек і купа
; лишаються на місці. Планувальник більше не дає їй такту, доки
; дитина не завершиться.
;
; Контекст зберігати вручну не треба - і це головна причина, чому
; засинання зроблено саме циклом із hlt. Обробник таймера має
; власний формат кадру, і побудувати сумісний із ним кадр тут, у
; системному виклику з іншим порядком регістрів, означало б завести
; другий опис того самого. Замість цього ми просто крутимось, доки
; таймер сам не зніме нас звичайним шляхом.
.sys_spawn:
    mov     qword [PendingCanvas], 0    ; звичайний запуск - без полотна
    lea     rdi, [ExecRequest]
    call    FormatFAT32Name         ; RSI -> 11-байтне ім'я
    mov     rax, [CurrentTask]
    mov     [SpawnParent], rax
    mov     byte [TaskState + rax], 2   ; призупинено, слот НЕ звільняємо
    mov     byte [SpawnPending], 1
    mov     byte [MouseOwnedByApp], 0   ; курсор на час сну не наш

.spawn_block:
    sti                             ; без цього таймер нас не зніме
    hlt
    mov     rax, [CurrentTask]
    cmp     byte [TaskState + rax], 2
    je      .spawn_block
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 41 - запустити програму У ВІКНІ й лишитись жити.
;
; Від 37 відрізняється двома речами. По-перше, батько НЕ засинає:
; поки гра малює у полотно, оболонка мусить малювати вікно, а спляча
; задача не малює нічого. По-друге, дитина дістає полотно - буфер,
; у який піде її blit замість фреймбуфера.
;
; Буфер видає ЯДРО, а не той, хто просить. Спершу його передавала
; оболонка зі своєї купи - і нічого не працювало: PagingCloneSpace
; робить купу власною для кожного простору, тож за однією адресою в
; батька й дитини лежать різні фізичні сторінки. Дитина малювала у
; свою копію, оболонка показувала свою, і вікно лишалося чорним.
;
; Гру перезбирати не треба: вона й далі кличе ті самі syscall 9 і 15,
; просто ядро тепер відповідає на них інакше.
;
;   RSI = ім'я файлу
;   R9  = (висота << 32) | ширина
;   RAX = адреса полотна, або 0, якщо не вийшло
;
; Запуск без полотна тут не має сенсу - для цього є 37, тому нульові
; чи завеликі розміри просто відхиляються.
; ------------------------------------------------------------
.sys_spawn_windowed:
    lea     rdi, [ExecRequest]
    call    FormatFAT32Name         ; RSI -> 11-байтне ім'я

    mov     qword [PendingCanvas], 0
    mov     dword [PendingCanvasW], 0
    mov     dword [PendingCanvasH], 0
    mov     dword [PendingCanvasS], 0
    xor     r10, r10                ; що повернемо: адреса полотна

    test    r9, r9
    jz      .spw_fail
    mov     ecx, r9d                ; ширина
    test    ecx, ecx
    jz      .spw_fail
    mov     rdx, r9
    shr     rdx, 32                 ; висота
    test    edx, edx
    jz      .spw_fail

    ; Кадр мусить уміститися в те, що ми готові під нього віддати.
    mov     eax, ecx
    mul     edx
    test    edx, edx
    jnz     .spw_fail               ; добуток не вліз навіть у 32 біти
    cmp     eax, CANVAS_MAX / 4
    ja      .spw_fail
    mov     edx, r9d                ; ширину повертаємо на місце
    mov     rcx, r9
    shr     rcx, 32                 ; висота

    mov     qword [PendingCanvas], CanvasBase
    mov     [PendingCanvasW], edx
    mov     [PendingCanvasH], ecx
    mov     [PendingCanvasS], edx   ; крок дорівнює ширині
    mov     r10, CanvasBase
.spw_no_canvas:

    mov     rax, [CurrentTask]
    mov     [SpawnParent], rax
    mov     [SpawnBusyFor], rax
    mov     byte [SpawnPending], 1
    mov     byte [SpawnBusy], 1
    ; TaskState батька не чіпаємо - у цьому й уся різниця з 37.
    mov     rax, r10
    jmp     .syscall_end
.spw_fail:
    mov     qword [PendingCanvas], 0
    xor     rax, rax
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 42 - чи жива ще дитина, запущена через 41.
;   RAX = 1, якщо так
;
; Оболонці цього досить: тримати номер слота їй нема потреби, бо
; дитина в неї одна. Поки прохання про запуск іще не виконане,
; відповідаємо "жива" - інакше вікно закрилося б раніше, ніж гра
; встигла б стартувати.
; ------------------------------------------------------------
.sys_child_alive:
    mov     rdx, [CurrentTask]
    cmp     byte [SpawnBusy], 0
    je      .ca_scan_start
    cmp     [SpawnBusyFor], rdx
    jne     .ca_scan_start
    mov     rax, 1
    jmp     .syscall_end
.ca_scan_start:
    mov     rcx, 1
.ca_scan:
    cmp     byte [TaskState + rcx], 0
    je      .ca_next
    cmp     [TaskParent + rcx*8], rdx
    jne     .ca_next
    mov     rax, 1
    jmp     .syscall_end
.ca_next:
    inc     rcx
    cmp     rcx, MAX_TASKS
    jb      .ca_scan
    xor     rax, rax
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 43 - кому діставатись клавішам.
;   RSI = 1 - чергу читає наша дитина, 0 - знову ми
;
; Черга клавіатури одна на всіх, і syscall 1 та 26 обидва тягнуть з
; неї. Поки жива була лише одна задача, питання не стояло. Тепер
; оболонка й гра живі одночасно, і без цього вони крали б клавіші
; одна в одної через одну.
;
; Миші це не стосується: вона лишається в оболонки, і саме тому
; клацання по іншому вікну завжди може повернути клавіатуру назад.
; ------------------------------------------------------------

; ------------------------------------------------------------
; syscall 44 - лічильник кадрів, покладених у полотно.
;   RAX = скільки разів у полотно щось клали
;
; Оболонці треба знати не "чи час малювати", а "чи є що малювати".
; Без цього вона перемальовувала вікно двадцять чотири рази на
; секунду навіть тоді, коли гра ще вантажила рівень, - і забирала
; в неї саме той час, якого їй бракувало.
; ------------------------------------------------------------
.sys_canvas_seq:
    xor     rax, rax
    mov     eax, [CanvasSeq]
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 46 - де лежить текст, надрукований задачею у вікні.
;   RAX = адреса заголовка:
;         +0  буфер, +8 довжина, +12 лічильник змін
;
; Адресу оболонка бере один раз і далі читає поля прямо з пам'яті:
; вона спільна, тож питати ядро на кожному кадрі немає потреби.
; ------------------------------------------------------------
.sys_app_text:
    mov     rax, AppTextHdr
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 45 - віддати решту кванта.
;
; Оболонка в головному циклі здебільшого не робить нічого: подій
; немає, перемальовувати нічого. Крутитись при цьому означає забирати
; половину процесора в того, хто справді працює - програми у вікні.
; hlt віддає решту кванта, а таймер на 1000 Гц будить назад.
; ------------------------------------------------------------
.sys_yield:
    sti
    hlt
    xor     rax, rax
    jmp     .syscall_end

.sys_keys_to_child:
    test    rsi, rsi
    jz      .ktc_off
    mov     rax, [CurrentTask]
    mov     [KeysOwner], rax
    mov     byte [KeysToChild], 1
    jmp     .syscall_end
.ktc_off:
    mov     byte [KeysToChild], 0
    mov     qword [KeysOwner], 0
    jmp     .syscall_end

; .key_gate - чи заборонено поточній задачі читати чергу клавіш.
;   -> CF=1 заборонено, CF=0 можна
;
; Мітка локальна навмисно: глобальна обірвала б область видимості
; решти .sys_* нижче, і всі jmp .syscall_end після неї перестали б
; знаходити ціль.
;
; Слот 0 (ядро) не обмежуємо ніколи: через нього йде вихід із гри.
.key_gate:
    push    rax
    cmp     byte [KeysToChild], 0
    je      .kg_open
    mov     rax, [CurrentTask]
    test    rax, rax
    jz      .kg_open                ; ядро читає завжди
    cmp     rax, [KeysOwner]
    je      .kg_closed              ; сам віддав - сам і не читає
    mov     rax, [TaskParent + rax*8]
    cmp     rax, [KeysOwner]
    je      .kg_open                ; це його дитина - їй і клавіші
.kg_closed:
    pop     rax
    stc
    ret
.kg_open:
    pop     rax
    clc
    ret

.sys_exec:
    lea     rdi, [ExecRequest]
    call    FormatFAT32Name         ; RSI -> RDI, 11-байтне FAT-ім'я
    mov     byte [ExecPending], 1
    jmp     .syscall_end

; syscall 29 - зміна поточного каталогу.
;   RSI = ім'я підкаталогу ("GEMES") або ".." на рівень вище
;   -> RAX = 1 успіх, 0 якщо такого каталогу немає
;
; Це те саме, що робить команда CD у консолі: змінює
; CurrentDirCluster, кладе попередній у DirHistoryStack і
; підправляє рядок CurrentPath. Після цього syscall 13 віддає
; список уже нового каталогу - окремо нічого оновлювати не треба.
.sys_chdir:
    push    rsi                     ; ім'я знадобиться для рядка шляху

    cmp     byte [rsi], '.'
    jne     .cd_normal
    cmp     byte [rsi + 1], '.'
    jne     .cd_normal

    ; ".." - шукаємо запис з іменем ".." у FAT-форматі
    lea     rdi, [ParsedFileName]
    mov     rax, 0x2020202020202E2E
    mov     qword [rdi], rax
    mov     dword [rdi + 8], 0x00202020
    jmp     .cd_find

.cd_normal:
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name

.cd_find:
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .cd_fail
    test    dl, 0x10                ; це взагалі каталог?
    jz      .cd_fail

    ; ".." кореня має кластер 0 - там мається на увазі корінь
    test    eax, eax
    jnz     .cd_apply
    mov     eax, [RootCluster]

.cd_apply:
    mov     ebx, [DirHistoryIndex]
    cmp     ebx, 63
    jge     .cd_nohist
    mov     ecx, [CurrentDirCluster]
    mov     dword [DirHistoryStack + ebx*4], ecx
    inc     dword [DirHistoryIndex]
.cd_nohist:
    mov     [CurrentDirCluster], eax

    pop     rsi
    cmp     byte [rsi], '.'
    je      .cd_up
    call    AppendPath
    mov     rax, 1
    jmp     .syscall_end
.cd_up:
    call    RemoveLastPath
    mov     rax, 1
    jmp     .syscall_end

.cd_fail:
    pop     rsi
    xor     rax, rax
    jmp     .syscall_end

; syscall 30 - поточний шлях рядком ("C:\GEMES\").
;   RSI = буфер, R9 = його розмір
.sys_getcwd:
    test    r9, r9
    jz      .cwd_done
    mov     rdi, rsi
    lea     rsi, [CurrentPath]
    mov     rcx, r9
    dec     rcx                     ; місце під нуль-термінатор
.cwd_copy:
    test    rcx, rcx
    jz      .cwd_term
    mov     al, [rsi]
    test    al, al
    jz      .cwd_term
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .cwd_copy
.cwd_term:
    mov     byte [rdi], 0
.cwd_done:
    xor     rax, rax
    jmp     .syscall_end

; ==========================================================
; ОПЕРАЦІЇ НАД ФАЙЛАМИ (syscalls 32-35)
;
; Досі програма вміла лише читати й писати ВМІСТ файлу, а все, що
; змінює сам каталог - видалити, створити, перейменувати, копіювати -
; жило тільки командами консолі (RM, MKDIR, COPY). Через це файловий
; менеджер в оболонці міг ходити по диску, але нічого на ньому не
; змінював.
;
; Тут не з'явилося ані рядка нової роботи з FAT: усе це вже вміють
; DeleteFileFAT32, CreateDirFAT32, RenameFAT32 і CopyFileFAT32.
; Syscall лише переводить ASCIIZ-ім'я від програми у 11-байтний
; формат FAT і кличе потрібну процедуру.
;
; Усі чотири працюють у ПОТОЧНОМУ каталозі (шляхів у іменах немає -
; їх не розуміє й решта системи) і повертають однаково:
;   RAX = 1 успіх, 0 помилка.
; ==========================================================

; syscall 32 - видалити файл.
;   RSI = ім'я ("README.TXT")
;
; Каталоги навмисно не видаляємо. DeleteFileFAT32 звільнив би ланцюг
; самого каталогу, а ланцюги файлів усередині лишились би зайнятими
; назавжди - витік, який видно лише через fat32_fsck. Порожній
; каталог теж не пускаємо: перевірити порожнечу нічим, а помилитися
; тут означає тихо втратити чужі дані.
.sys_unlink:
    lea     rdi, [SysNameA]
    call    FormatFAT32Name
    lea     r8,  [SysNameA]
    call    FindFAT32Entry
    jc      .fop_fail
    test    dl, 0x10
    jnz     .fop_fail
    lea     r8,  [SysNameA]
    call    DeleteFileFAT32
    jc      .fop_fail
    jmp     .fop_ok

; syscall 33 - створити підкаталог у поточному.
;   RSI = ім'я
.sys_mkdir:
    lea     rdi, [SysNameA]
    call    FormatFAT32Name
    lea     r8,  [SysNameA]
    call    FindFAT32Entry
    jnc     .fop_fail               ; таке ім'я вже зайняте
    lea     r8,  [SysNameA]
    call    CreateDirFAT32
    jc      .fop_fail
    jmp     .fop_ok

; syscall 34 - перейменувати файл або каталог.
;   RSI = старе ім'я, R9 = нове
.sys_rename:
    push    r9
    lea     rdi, [SysNameA]
    call    FormatFAT32Name         ; RSI -> SysNameA
    pop     rsi                     ; нове ім'я
    lea     rdi, [SysNameB]
    call    FormatFAT32Name
    lea     r8,  [SysNameA]
    lea     r9,  [SysNameB]
    call    RenameFAT32
    jc      .fop_fail
    jmp     .fop_ok

; syscall 35 - копіювати файл.
;   RSI = джерело, R9 = призначення
.sys_copy:
    push    r9
    lea     rdi, [SysNameA]
    call    FormatFAT32Name
    pop     rsi
    lea     rdi, [SysNameB]
    call    FormatFAT32Name
    lea     r8,  [SysNameA]
    lea     r9,  [SysNameB]
    call    CopyFileFAT32
    jc      .fop_fail
    jmp     .fop_ok

; syscall 36 - тип файлу.
;   RSI = ім'я
;   -> RAX: біти 7..0 тип, 31..16 ширина, 47..32 висота
;
; Ширина й висота вкладені сюди навмисно: за правилом незмінності
; номерів додати їх пізніше окремим аргументом буде вже не можна,
; а програмі, яка відкриває зображення, вони потрібні.
;
; Читаємо ОДИН сектор, а не файл цілком: тип лежить у перших
; шістнадцяти байтах, і тягти заради них сотні мегабайтів немає
; жодних підстав.
.sys_filetype:
    lea     rdi, [SysNameA]
    call    FormatFAT32Name
    lea     r8,  [SysNameA]
    call    FindFAT32Entry
    jc      .ft_unknown

    test    dl, 0x10
    jnz     .ft_dir

    ; EAX = перший кластер, EBX = розмір
    push    rbx
    test    eax, eax
    jz      .ft_by_ext_pop          ; порожній файл - заголовка немає
    call    ClusterToLBA
    lea     rdi, [FileBuffer]
    call    ReadSectorATA

    lea     rsi, [FileBuffer]
    pop     rdx                     ; розмір файлу
    push    rdx
    call    EugDetectAt
    test    al, al
    jz      .ft_by_ext_pop

    ; Наш формат: тип із заголовка, розміри звідти ж
    pop     rbx
    movzx   ecx, al
    mov     eax, FT_UNKNOWN
    cmp     ecx, EUG_VIDEO
    je      .ft_eug_video
    cmp     ecx, EUG_IMAGE
    je      .ft_eug_image
    cmp     ecx, EUG_SOUND
    je      .ft_eug_sound
    cmp     ecx, EUG_SYSTEM
    je      .ft_eug_system
    jmp     .ft_done
.ft_eug_video:
    mov     eax, FT_VIDEO
    jmp     .ft_dims
.ft_eug_image:
    mov     eax, FT_IMAGE
    jmp     .ft_dims
.ft_eug_sound:
    mov     eax, FT_SOUND
    jmp     .ft_done
.ft_eug_system:
    mov     eax, FT_SYSTEM
    jmp     .ft_done

.ft_dims:
    lea     rsi, [FileBuffer]
    movzx   rcx, word [rsi + 6]     ; ширина
    shl     rcx, 16
    or      rax, rcx
    movzx   rcx, word [rsi + 8]     ; висота
    shl     rcx, 32
    or      rax, rcx
    jmp     .ft_done

.ft_by_ext_pop:
    pop     rbx
    ; Підпису немає - здогад за розширенням.
    mov     ecx, dword [SysNameA + 8]
    and     ecx, 0x00FFFFFF
    mov     eax, FT_PROGRAM
    cmp     ecx, 0x00505041         ; 'APP'
    je      .ft_done
    cmp     ecx, 0x004E4942         ; 'BIN'
    je      .ft_done
    mov     eax, FT_TEXT
    cmp     ecx, 0x00545854         ; 'TXT'
    je      .ft_done
    mov     eax, FT_BITMAP
    cmp     ecx, 0x00504D42         ; 'BMP'
    je      .ft_done
    mov     eax, FT_SOUND
    cmp     ecx, 0x00564157         ; 'WAV'
    je      .ft_done
    mov     eax, FT_VIDEO
    cmp     ecx, 0x00445645         ; 'EVD'
    je      .ft_done
    mov     eax, FT_SYSTEM
    cmp     ecx, 0x00475545         ; 'EUG'
    je      .ft_done
    mov     eax, FT_UNKNOWN
    jmp     .ft_done

.ft_dir:
    mov     eax, FT_DIR
    jmp     .ft_done
.ft_unknown:
    mov     eax, FT_UNKNOWN
.ft_done:
    jmp     .syscall_end

.fop_ok:
    mov     rax, 1
    jmp     .syscall_end
.fop_fail:
    xor     rax, rax
    jmp     .syscall_end

; syscall 1 - клавіатура, СТАРА форма.
;   -> RAX = сирий скан-код (біт 0x80 = відпускання клавіші),
;            0 якщо черга порожня
;
; ФОРМАТ НЕ МІНЯТИ. На нього спираються готові бінарники, зібрані до
; появи syscall 26 - зокрема порт DOOM на диску, який розрізняє
; натискання і відпускання саме за бітом 0x80 скан-коду. Коли сюди
; поклали ASCII у молодший байт, у DOOM поїхало все керування.
; Нова форма, з ASCII і модифікаторами, живе під номером 26.
.sys_getkey:
    call    .key_gate           ; чи наша черга взагалі
    jc      .no_key
    mov     al, [KbdTail]
    cmp     al, [KbdHead]       ; Чи є нові дані в буфері?
    je      .no_key
    movzx   ebx, al
    movzx   rax, byte [KbdBuffer + ebx] ; Читаємо найстаріший байт
    inc     bl                  ; Зсуваємо хвіст черги
    mov     [KbdTail], bl
    jmp     .syscall_end
.no_key:
    xor     rax, rax            ; Повертаємо 0, якщо клавіш не було
    jmp     .syscall_end

; syscall 26 - клавіатура, нова форма. Повертає одразу три речі, щоб
; програмі не треба було мати власну таблицю розкладки:
;    біти  7..0  ASCII (0 = клавіша без друкованого символу)
;    біти 15..8  скан-код (стрілки, F-клавіші тощо)
;    біти 23..16 модифікатори: 1=Shift 2=Ctrl 4=Alt 8=Caps
; 0 = черга порожня.
;
; Черга спільна із syscall 1, тому програма має користуватись
; ЧИМОСЬ ОДНИМ: хто перший прочитав, той і забрав подію.
.sys_keyevent:
    call    .key_gate           ; чи наша черга взагалі
    jc      .no_key_ev
    mov     al, [KbdTail]
    cmp     al, [KbdHead]       ; Чи є нові дані в буфері?
    je      .no_key_ev
    movzx   ebx, al
    movzx   rcx, byte [KbdBuffer + ebx] ; скан-код
    inc     bl                  ; Зсуваємо хвіст черги
    mov     [KbdTail], bl

    ; --- Перекладаємо скан-код в ASCII ---
    xor     rax, rax
    cmp     cl, 128
    jae     .gk_pack            ; поза таблицею - лише скан-код

    movzx   rdx, cl
    test    byte [KbdMods], 1   ; Shift?
    jz      .gk_normal
    lea     rsi, [ScanCodesShift]
    jmp     .gk_lookup
.gk_normal:
    lea     rsi, [ScanCodes]
.gk_lookup:
    mov     al, [rsi + rdx]

    ; CapsLock міняє регістр ЛИШЕ літер, на цифри й розділові не діє
    test    byte [KbdMods], 8
    jz      .gk_pack
    cmp     al, 'a'
    jb      .gk_pack
    cmp     al, 'z'
    ja      .gk_caps_upper
    sub     al, 32              ; мала -> велика
    jmp     .gk_pack
.gk_caps_upper:
    cmp     al, 'A'
    jb      .gk_pack
    cmp     al, 'Z'
    ja      .gk_pack
    add     al, 32              ; велика -> мала (Shift+Caps)

.gk_pack:
    movzx   rdx, cl
    shl     rdx, 8
    or      rax, rdx            ; скан-код у біти 15..8
    movzx   rdx, byte [KbdMods]
    shl     rdx, 16
    or      rax, rdx            ; модифікатори у біти 23..16
    jmp     .syscall_end
.no_key_ev:
    xor     rax, rax            ; Повертаємо 0, якщо клавіш не було
    jmp     .syscall_end

; .no_screen - чи заборонено поточній задачі малювати текст на екран.
;   -> CF=1 заборонено (у задачі є полотно), CF=0 можна
;
; Текстові виклики (2, 4, 6, 7, 8) малюють ПРЯМО у фреймбуфер, повз
; blit, і полотна не бачать у принципі. Для задачі у вікні це
; означало б, що її текст лягає поверх усієї оболонки - саме це й
; було видно, коли DOOM друкував свій журнал запуску поверх вікон.
;
; Текст просто зникає. Це і є правильна відповідь: консолі, у яку
; його писати, у віконної задачі немає, а псувати чужий екран вона
; права не має.
.no_screen:
    push    rax
    mov     rax, [CurrentTask]
    cmp     qword [TaskCanvas + rax*8], 0
    pop     rax
    je      .ns_allow
    stc
    ret
.ns_allow:
    clc
    ret

.sys_print:
    call    .no_screen
    jnc     .sp_to_screen
    ; Задача у вікні: текст не малюємо, а складаємо в буфер - його
    ; покаже оболонка. Досі він тут просто зникав.
    call    AppTextPutStr
    jmp     .syscall_end
.sp_to_screen:
    mov     rcx, [CursorX]      
    mov     rdx, [CursorY]      
    mov     r8,  rsi            
    call    DrawString          
    mov     [CursorX], rcx      
    mov     [CursorY], rdx      
    jmp     .syscall_end        
    
.sys_clear:
    call    .no_screen
    jnc     .sc_to_screen
    call    AppTextReset
    jmp     .syscall_end
.sc_to_screen:
    call    ClearScreen
    mov     qword [CursorX], 20     
    mov     qword [CursorY], 40
    jmp     .syscall_end    

; syscall 5 - читання файлу, СТАРА форма.
;   RSI = ім'я файлу ("NAME.EXT")
;   R9  = куди класти дані
;   -> RAX = скільки байт зчитано (округлено вгору до кластера)
;
; СЮДИ НЕ ДОДАВАТИ ЛІМІТ. Готові бінарники, зібрані до появи
; syscall 24 (порт DOOM на диску), викликають цей номер так:
;       lea rsi,[rbp-0x70] / mov eax,5 / mov r9,r14 / int 0x80
; тобто RDI не заповнюють узагалі - там лишається сміття від
; попереднього коду. Коли ядро почало читати з RDI ліміт, WAD
; мовчки обрізався до випадкового числа байтів.
; Форма з лімітом - syscall 24.
.sys_readfile:
    push    r9                          ; буфер користувача
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .read_fail_pop
    test    dl, 0x10
    jnz     .read_fail_pop
    pop     r9
    call    LoadFAT32Chain
    mov     rax, rbx
    jmp     .syscall_end

.read_fail_pop:
    pop     r9
    xor     rax, rax
    jmp     .syscall_end

; syscall 24 - читання файлу з лімітом.
;   RSI = ім'я файлу ("NAME.EXT")
;   R9  = куди класти дані
;   RDI = МАКСИМУМ байт (0 = без обмежень)
;   -> RAX = скільки байт реально скопійовано
;
; Чим кращий за syscall 5:
;  1) повертає СПРАВЖНІЙ розмір файлу, а не округлений до кластера;
;  2) читає кластери у службовий буфер ядра і копіює в програму рівно
;     стільки, скільки треба - 20-байтний .TXT більше не затирає 4 КБ
;     чужої пам'яті.
.sys_readfile_max:
    push    r9                          ; буфер користувача
    push    rdi                         ; ліміт
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .read_max_fail
    test    dl, 0x10
    jnz     .read_max_fail

    mov     r10d, ebx                   ; R10 = СПРАВЖНІЙ розмір файлу
    pop     r11                         ; R11 = ліміт
    pop     r12                         ; R12 = буфер користувача

    ; Читаємо кластери у СЛУЖБОВИЙ буфер ядра, не в пам'ять програми
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain              ; RBX = скільки байт реально зчитано

    ; RCX = min(розмір_файлу, зчитано, ліміт)
    mov     rcx, r10
    cmp     rcx, rbx
    jbe     .rf_have
    mov     rcx, rbx
.rf_have:
    test    r11, r11
    jz      .rf_copy
    cmp     rcx, r11
    jbe     .rf_copy
    mov     rcx, r11
.rf_copy:
    mov     rax, rcx                    ; це й буде результат
    mov     rsi, VideoMemoryBase
    mov     rdi, r12
    cld
    rep     movsb
    jmp     .syscall_end

.read_max_fail:
    pop     rdi
    pop     r9
    xor     rax, rax
    jmp     .syscall_end

.sys_putchar:
    call    .no_screen
    jnc     .spc_to_screen
    mov     al, sil                 ; молодший байт RSI - сам символ
    call    AppTextPutChar
    jmp     .syscall_end
.spc_to_screen:
    cmp     rsi, 10             
    je      .putchar_newline
    cmp     rsi, 13             
    je      .syscall_end

    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r8, rsi              
    call    DrawChar_Safe        
    add     qword [CursorX], 9  
    jmp     .syscall_end
.putchar_newline:
    call    NewLine
    jmp     .syscall_end

.sys_erasechar:
    call    .no_screen
    jnc     .se_to_screen
    ; У буфері стерти символ - це просто вкоротити його на байт.
    mov     eax, [AppTextHdr + 8]
    test    eax, eax
    jz      .syscall_end
    dec     eax
    mov     [AppTextHdr + 8], eax
    inc     dword [AppTextHdr + 12]
    jmp     .syscall_end
.se_to_screen:
    mov     rcx, [CursorX]
    cmp     rcx, 20             
    jle     .syscall_end
    
    sub     rcx, 9              
    mov     [CursorX], rcx
    mov     rdx, [CursorY]
    call    EraseChar           
    jmp     .syscall_end

.sys_ls:
    call    .no_screen
    jc      .syscall_end
    call    ListFilesFAT32          
    jmp     .syscall_end

; syscall 9 - вивід буфера на екран, СТАРА форма.
; Структура за RSI, рівно 24 байти:
;   +0  покажчик на буфер
;   +8  X на екрані
;   +12 Y на екрані
;   +16 ширина
;   +20 висота
;
; СЮДИ НЕ ДОДАВАТИ 6-те ПОЛЕ. Готові бінарники, зібрані до появи
; syscall 25 (порт DOOM на диску), кладуть цю структуру на стек
; через `sub rsp,0x18` - за нею одразу лежить збережений RBP.
; Прочитаний звідти "крок рядка" дає адресу стеку як число
; (близько 67 мільйонів), і blit починає читати за сотні мегабайт
; від буфера. Форма з кроком - syscall 25.
.sys_blit:
    xor     r15d, r15d                  ; крок рядка = ширина ділянки
    jmp     .blit_common

; syscall 25 - те саме, але з власним кроком рядка у буфері-джерелі.
;   +24 крок рядка у пікселях (0 = дорівнює ширині)
;
; Без цього неможливе часткове оновлення екрана: щоб вивести ШМАТОК
; великого буфера, w/h мають описувати лише частину, а крок - повну
; ширину буфера. Інакше ядро читає не ті пікселі.
.sys_blit_stride:
    mov     r15d, dword [rsi+24]

.blit_common:
    mov     r8, [rsi+0]
    mov     r9d, dword [rsi+8]
    mov     r10d, dword [rsi+12]
    mov     r11d, dword [rsi+16]
    mov     r12d, dword [rsi+20]

    test    r15d, r15d
    jnz     .blit_stride_ok
    mov     r15d, r11d
.blit_stride_ok:

    test    r11d, r11d
    jle     .syscall_end
    test    r12d, r12d
    jle     .syscall_end

    ; Від'ємні координати не обробляємо: обчислена адреса пішла б
    ; ліворуч від початку рядка, тобто в чужу пам'ять. Раніше цього
    ; не перевіряли, і рятувало лише те, що ніхто так не малював.
    cmp     r9d, 0
    jl      .syscall_end
    cmp     r10d, 0
    jl      .syscall_end

    ; --- Куди пише ця задача: у полотно чи прямо в екран ---
    ;
    ; Тримаємо в РЕГІСТРАХ, а не в глобальних змінних. Регістри
    ; планувальник зберігає окремо для кожної задачі, а спільна
    ; змінна означала б, що дві задачі, які опинились у blit
    ; одночасно, пишуть за адресою одна одної.
    ;
    ;   RDX  = база призначення
    ;   R13D = його крок рядка
    ;   EAX  = його ширина, ECX = його висота
    mov     rax, [CurrentTask]
    mov     rdx, [TaskCanvas + rax*8]
    test    rdx, rdx
    jz      .blit_to_screen
    mov     r13d, [TaskCanvasS + rax*4]
    mov     ecx,  [TaskCanvasH + rax*4]
    mov     eax,  [TaskCanvasW + rax*4]
    inc     dword [CanvasSeq]
    jmp     .blit_target_ready
.blit_to_screen:
    mov     rdx, [ScreenBase]
    mov     r13d, [ScreenStride]
    mov     ecx, [ScreenHeight]
    mov     eax, [ScreenWidth]
.blit_target_ready:

    ; --- Обрізаємо ширину по краю призначення ---
    ; R14D = скільки пікселів у рядку реально копіювати
    sub     eax, r9d
    jle     .syscall_end            ; X уже за межами
    mov     r14d, eax
    cmp     r14d, r11d
    jle     .blit_w_ok
    mov     r14d, r11d              ; не більше, ніж ширина буфера
.blit_w_ok:

    ; --- І висоту, ОДИН раз, а не перевіркою на кожному рядку ---
    sub     ecx, r10d
    jle     .syscall_end            ; Y уже за межами
    cmp     r12d, ecx
    jle     .blit_h_ok
    mov     r12d, ecx
.blit_h_ok:

    mov     r11d, r13d              ; R11D = крок призначення
    xor     r13d, r13d              ; R13D = номер рядка
.blit_row:
    cmp     r13d, r12d
    jge     .syscall_end

    mov     eax, r10d
    add     eax, r13d
    movsxd  rax, eax
    movsxd  rbx, r11d               ; крок призначення
    imul    rax, rbx
    movsxd  rbx, r9d
    add     rax, rbx
    shl     rax, 2
    add     rax, rdx
    mov     rdi, rax

    movsxd  rax, r13d
    movsxd  rbx, r15d               ; крок рядка у буфері-джерелі
    imul    rax, rbx
    shl     rax, 2
    add     rax, r8
    mov     rsi, rax

    movsxd  rcx, r14d               ; а копіюємо лише обрізану кількість
    cld
    rep     movsd

    inc     r13d
    jmp     .blit_row

.sys_getticks:
    mov     rax, [SystemTicks]      
    jmp     .syscall_end            

; syscall 15 - розмір екрана.
; RAX = (height << 32) | width
;
; Задачі з полотном за екран віддаємо саме полотно. Інакше програма
; розрахує свій кадр під справжній екран, а покладемо ми його у
; вікно - і не влізе ані кадр, ані сама думка про вікно.
.sys_screen_info:
    mov     rax, [CurrentTask]
    mov     rbx, [TaskCanvas + rax*8]
    test    rbx, rbx
    jz      .ssi_real_screen
    mov     ebx, [TaskCanvasH + rax*4]
    mov     ecx, [TaskCanvasW + rax*4]
    xor     rax, rax
    mov     eax, ebx
    shl     rax, 32
    or      rax, rcx
    jmp     .syscall_end
.ssi_real_screen:
    xor     rax, rax
    mov     eax, [ScreenHeight]
    shl     rax, 32
    mov     ebx, [ScreenWidth]  ; 32-бітний mov сам обнуляє верхню половину RBX
    or      rax, rbx
    jmp     .syscall_end

.sys_getmouse:
    ; Розкладка результату (сумісна зі старою):
    ;   [15:0]  X
    ;   [31:16] Y
    ;   [47:32] клік (1=ліва, 2=права)
    ;   [55:48] НОВЕ: накопичена прокрутка колеса, знаковий байт.
    ;           Читання ОЧИЩАЄ накопичувач, тому кожен тік віддається рівно раз.
    xor     rax, rax
    xor     rbx, rbx

    mov     bl, byte [MouseWheel]
    mov     byte [MouseWheel], 0
    shl     rbx, 48
    mov     rax, rbx

    movzx   rbx, byte [MouseClick]
    shl     rbx, 32
    or      rax, rbx

    movzx   rbx, word [MouseY]
    shl     rbx, 16
    or      rax, rbx

    movzx   rbx, word [MouseX]
    or      rax, rbx
    jmp     .syscall_end

.sys_get_time:
    ; Читаємо Хвилини (регістр 0x02)
    mov al, 0x02
    out 0x70, al
    in al, 0x71
    mov cl, al      ; Тимчасово кладемо хвилини в CL

    ; Читаємо Години (регістр 0x04)
    mov al, 0x04
    out 0x70, al
    in al, 0x71
    mov ch, al      ; Години в CH

    ; Формуємо результат у RAX
    xor rax, rax    ; Очищаємо RAX від сміття!
    mov ah, ch
    mov al, cl
    
    jmp .syscall_end ; ПРАВИЛЬНИЙ ВИХІД З СИСКОЛУ!

.sys_get_file_list:
    ; RSI = адреса буфера з C-коду, R9 = його розмір у байтах
    ; ВИПРАВЛЕНО: додано контроль межі буфера.
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r11

    mov rdi, rsi            ; RDI тепер вказує на наш C-буфер
    mov r11, r9             ; R11 = розмір буфера
    test r11, r11
    jnz .fl_size_ok
    mov r11, 2048           ; старий код не передавав розмір - беремо 2 КБ
.fl_size_ok:
    sub r11, 16             ; запас на один запис (11 байт імені + слеш + LF + 0)
    jle .done_dir
    add r11, rdi            ; R11 = адреса, далі якої писати не можна

    ; 1. Завантажуємо директорію в DirBuffer (використовуємо твою функцію!)
    mov eax, [CurrentDirCluster]
    mov r9, DirBuffer       
    call LoadFAT32Chain

    ; 2. Починаємо парсити DirBuffer
    mov rsi, DirBuffer      
.parse_dir:
    cmp rdi, r11            ; чи лишилось місце в буфері?
    jae .done_dir
    mov al, [rsi]
    test al, al             ; 0x00 = кінець директорії
    jz .done_dir
    cmp al, 0xE5            ; 0xE5 = видалений файл
    je .next_dir_entry

    mov dl, [rsi + 0x0B]    ; Читаємо атрибути
    cmp dl, 0x0F            ; Пропускаємо довгі імена (LFN)
    je .next_dir_entry
    test dl, 0x08           ; Пропускаємо мітку тому (Volume Label)
    jnz .next_dir_entry

    ; 3. Копіюємо 11 символів імені (8 ім'я + 3 розширення) у C-буфер
    push rsi
    mov rcx, 11
.copy_name:
    mov al, [rsi]
    mov [rdi], al           ; Пишемо букву в буфер
    inc rdi
    inc rsi
    dec rcx
    jnz .copy_name
    pop rsi

    ; 4. Якщо це папка, додаємо слеш '/' для краси
    test byte [rsi + 0x0B], 0x10
    jz .is_file
    mov byte [rdi], '/'
    inc rdi
.is_file:

    ; 5. Додаємо символ нового рядка '\n' (щоб розділяти файли)
    mov byte [rdi], 10      ; 10 = ASCII код для \n
    inc rdi

.next_dir_entry:
    add rsi, 32             ; Переходимо до наступного 32-байтного запису FAT32
    jmp .parse_dir

.done_dir:
    mov byte [rdi], 0       ; Нуль-термінатор, щоб C-код зрозумів, де кінець тексту

    ; Відновлюємо регістри
    pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    xor rax, rax            ; Очищаємо RAX від сміття
    jmp .syscall_end        ; Правильний вихід з сисколу!

; ------------------------------------------------------------
; syscall 38 - вміст каталогу разом із розміром, датою й атрибутами.
;
; Номер 27 віддає самі імена одним рядком, і поки список був списком,
; цього вистачало. Колонок "розмір" і "змінено" з нього не зробити:
; тих чисел у рядку просто немає, а дописати їх у 27 не можна - його
; формат чекають готові бінарники на диску. Тому окремий номер.
;
;   RSI = буфер під записи
;   R9  = скільки записів у нього влізе
;   RAX = скільки записів заповнено
;
; Запис - 32 байти:
;   +0  ім'я: 11 сирих байтів FAT і нуль (крапку ставить оболонка)
;   +12 атрибути   +13 запас
;   +14 дата зміни +16 час зміни  +18 запас
;   +20 розмір     +24 перший кластер  +28 запас
;
; Дату й час беремо з полів ЗМІНИ (0x18/0x16), а не створення: файловий
; менеджер показує саме "коли востаннє чіпали".
; ------------------------------------------------------------
.sys_dirinfo:
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11

    ; Каталог читаємо ПЕРШИМ, а свої два числа тримаємо на стеку:
    ; LoadFAT32Chain зберігає лише rax, rcx, rdx, rdi та r8, тож
    ; покладатися на те, що вона не зачепить r10/r11, підстав немає.
    push    rsi                     ; буфер
    push    r9                      ; ліміт записів

    mov     eax, [CurrentDirCluster]
    mov     r9, DirBuffer
    call    LoadFAT32Chain

    pop     r11                     ; R11 = ліміт
    pop     rdi                     ; RDI = куди писати
    xor     r10, r10                ; R10 = скільки записано
    test    r11, r11
    jz      .di_done

    mov     rsi, DirBuffer
.di_scan:
    cmp     r10, r11
    jae     .di_done
    mov     al, [rsi]
    test    al, al                  ; 0x00 - далі каталог порожній
    jz      .di_done
    cmp     al, 0xE5                ; видалений запис
    je      .di_next

    mov     dl, [rsi + 0x0B]
    cmp     dl, 0x0F                ; частина довгого імені
    je      .di_next
    test    dl, 0x08                ; мітка тому
    jnz     .di_next

    ; --- ім'я: 11 байтів як лежать, далі нуль ---
    push    rsi
    push    rdi
    mov     rcx, 11
.di_name:
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jnz     .di_name
    mov     byte [rdi], 0
    pop     rdi
    pop     rsi

    ; --- решта полів ---
    mov     al, [rsi + 0x0B]
    mov     [rdi + 12], al          ; атрибути
    mov     byte [rdi + 13], 0
    mov     ax, [rsi + 0x18]
    mov     [rdi + 14], ax          ; дата зміни
    mov     ax, [rsi + 0x16]
    mov     [rdi + 16], ax          ; час зміни
    mov     word [rdi + 18], 0
    mov     eax, [rsi + 0x1C]
    mov     [rdi + 20], eax         ; розмір у байтах

    movzx   eax, word [rsi + 0x14]  ; старші 16 біт кластера
    shl     eax, 16
    movzx   ecx, word [rsi + 0x1A]  ; молодші
    or      eax, ecx
    mov     [rdi + 24], eax
    mov     dword [rdi + 28], 0

    add     rdi, 32
    inc     r10
.di_next:
    add     rsi, 32
    jmp     .di_scan

.di_done:
    mov     rax, r10
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 39 - відкрити відео для показу у вікні.
;
; Програвач у консолі малює кадр прямо в екран і сам крутить цикл,
; тому у вікні його не показати. Розділяємо: декодування лишається
; тут, бо тут і живе формат, а куди й у якому масштабі покласти
; готовий кадр - справа того, хто має вікно.
;
;   RSI = ім'я файлу
;   RAX = (висота << 16) | ширина, або 0, якщо не вийшло
; ------------------------------------------------------------
.sys_video_open:
    mov     dword [VidOpen], 0
    lea     rdi, [SysNameA]
    call    FormatFAT32Name
    lea     r8,  [SysNameA]
    call    FindFAT32Entry
    jc      .vo_fail
    test    dl, 0x10
    jnz     .vo_fail                ; каталог відео не буває
    cmp     ebx, VIDFILE_MAX
    ja      .vo_fail                ; у власний буфер не вміститься

    mov     [VidFileSize], ebx
    mov     r9, VidFileBase
    call    LoadFAT32Chain

    ; EugDetectAt заразом виставляє MediaOffset. Файл із підписом
    ; мусить бути саме відео; без підпису пускаємо, як пускали
    ; завжди - старі записи заголовка не мають.
    mov     rsi, VidFileBase
    mov     edx, [VidFileSize]
    call    EugDetectAt
    test    al, al
    jz      .vo_dims_default
    cmp     al, EUG_VIDEO
    jne     .vo_fail

    ; --- розміри кадру з заголовка ---
    mov     rsi, VidFileBase
    movzx   eax, word [rsi + 6]
    movzx   ecx, word [rsi + 8]
    test    eax, eax
    jz      .vo_dims_default
    test    ecx, ecx
    jz      .vo_dims_default
    mov     [VidSrcW], eax
    mov     [VidSrcH], ecx
    jmp     .vo_dims_ready
.vo_dims_default:
    mov     dword [VidSrcW], 320
    mov     dword [VidSrcH], 240
.vo_dims_ready:

    ; Кадр мусить лишатися в межах, які ми готові під нього віддати.
    mov     eax, [VidSrcW]
    mul     dword [VidSrcH]
    test    edx, edx
    jnz     .vo_fail                ; добуток не вліз навіть у 32 біти
    cmp     eax, VIDBUF_MAX / 4
    ja      .vo_fail
    mov     [VidPixels], eax

    ; --- курсор у потоці ---
    ;
    ; MediaOffset тут лише читається: далі його перепише перший-ліпший
    ; відкритий файл, а показ відео від того залежати не має.
    mov     rcx, VidFileBase
    mov     eax, [VidFileSize]
    add     rcx, rax
    mov     [VideoEOFPtr], rcx
    mov     rcx, VidFileBase
    mov     eax, [MediaOffset]
    add     rcx, rax
    mov     [VideoDataPtr], rcx
    mov     dword [RLE_Count], 0
    mov     dword [FramesRendered], 0
    mov     dword [VidOpen], 1

    mov     eax, [VidSrcH]
    shl     eax, 16
    or      eax, [VidSrcW]
    jmp     .syscall_end
.vo_fail:
    mov     dword [VidOpen], 0
    xor     eax, eax
    jmp     .syscall_end

; ------------------------------------------------------------
; syscall 40 - розкодувати наступний кадр у буфер програми.
;
;   RSI = куди писати (по 32 біти на піксель, зверху вниз)
;   R9  = розмір того буфера в байтах
;   RAX = 1, якщо кадр записано; 0, якщо потік скінчився,
;         буфер замалий або відео не відкрито
;
; Потік RLE: байт кольору (0 - чорний, інакше білий), за ним чотири
; байти довжини серії. Серія може переходити з кадру в кадр, тому
; лічильник живе між викликами - так само, як у програвачі консолі.
; ------------------------------------------------------------
.sys_video_frame:
    cmp     dword [VidOpen], 0
    je      .vf_fail
    mov     eax, [VidPixels]
    shl     rax, 2
    cmp     r9, rax
    jb      .vf_fail                ; у такий буфер кадр не влізе

    mov     rax, [VideoDataPtr]
    cmp     rax, [VideoEOFPtr]
    jae     .vf_fail                ; потік скінчився

    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    rsi

    cld
    mov     rdi, rsi                ; куди пишемо кадр
    mov     ecx, [VidPixels]
    mov     rsi, [VideoDataPtr]
    mov     rdx, [VideoEOFPtr]
.vf_px:
    cmp     dword [RLE_Count], 0
    ja      .vf_draw
    ; наступна серія - це п'ять байтів; менше означає обірваний файл
    mov     rbx, rsi
    add     rbx, 5
    cmp     rbx, rdx
    ja      .vf_tail
    movzx   eax, byte [rsi]
    inc     rsi
    test    al, al
    jz      .vf_black
    mov     eax, 0x00FFFFFF
    jmp     .vf_color
.vf_black:
    xor     eax, eax
.vf_color:
    mov     [RLE_Color], eax
    mov     eax, [rsi]
    add     rsi, 4
    mov     [RLE_Count], eax
.vf_draw:
    mov     eax, [RLE_Color]
    stosd
    dec     dword [RLE_Count]
    dec     rcx
    jnz     .vf_px
    jmp     .vf_store

.vf_tail:
    ; Даних на цілий кадр не стало. Хвіст лишаємо чорним, а не
    ; сміттям попереднього кадру, і на цьому потік закриваємо.
    xor     eax, eax
    rep     stosd
    mov     rsi, rdx
.vf_store:
    mov     [VideoDataPtr], rsi
    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    mov     rax, 1
    jmp     .syscall_end
.vf_fail:
    xor     eax, eax
    jmp     .syscall_end

.sys_writefile:
    ; RSI = вказівник на ім'я файлу (звичайний рядок, форматується тут)
    ; RDI = вказівник на буфер даних
    ; RDX = розмір у байтах
    push    rdi
    push    rdx
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name         ; форматуємо ім'я з RSI → ParsedFileName
    pop     rdx
    pop     rdi

    ; FatWriteFile сам створює файл, якщо його немає, і сам
    ; перезаписує наявний зі звільненням старого ланцюга кластерів.
    ; Раніше тут було три окремі обходи директорії поспіль.
    lea     r8, [ParsedFileName]
    mov     r9, rdi                 ; буфер даних
    mov     rbx, rdx                ; розмір
    call    FatWriteFile
    jc      .wf_fail
    mov     rax, rdx               ; повертаємо кількість записаних байт
    jmp     .syscall_end

.wf_fail:
    xor     rax, rax               ; 0 = помилка
    jmp     .syscall_end

; ---------- syscall 16: open(name, flags) ----------
;   RSI = ім'я ("NAME.EXT"), R9 = прапорці
;   -> RAX = fd, або -1
.sys_open:
    ; шукаємо вільний дескриптор
    xor     r10d, r10d
.so_find:
    cmp     r10d, MAX_FD
    jge     .so_fail
    mov     eax, r10d
    call    FdEntry
    cmp     qword [rbx], 0
    je      .so_got
    inc     r10d
    jmp     .so_find
.so_got:
    mov     r12, rbx                ; R12 = запис таблиці
    mov     r13d, r10d              ; R13 = номер fd

    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name         ; RSI -> 11-байтне ім'я

    ; чи є файл на диску?
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .so_missing

    ; є: перевіряємо, що це не директорія
    test    dl, 0x10
    jnz     .so_fail
    mov     r14d, ebx               ; R14 = розмір файлу
    cmp     r14d, FD_CAP
    jbe     .so_size_ok
    mov     r14d, FD_CAP            ; більший за стелю - обрізаємо
.so_size_ok:
    test    r9, O_TRUNC
    jz      .so_load
    xor     r14d, r14d              ; O_TRUNC - вміст не читаємо
    jmp     .so_fill

.so_load:
    test    r14d, r14d
    jz      .so_fill
    ; читаємо файл у службовий буфер, далі копіюємо до себе
    push    r9
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    pop     r9
    mov     eax, r13d
    call    FdData
    mov     rsi, VideoMemoryBase
    mov     ecx, r14d
    cld
    rep     movsb
    jmp     .so_fill

.so_missing:
    test    r9, O_CREAT
    jz      .so_fail                ; немає файлу і не просили створювати
    xor     r14d, r14d

.so_fill:
    mov     rbx, r12
    mov     qword [rbx], 1          ; used
    mov     qword [rbx + 16], r14   ; size
    mov     qword [rbx + 24], r9    ; flags
    ; dirty = 1, якщо файл новий або обнулений: тоді навіть порожній
    ; файл має з'явитись на диску при close
    xor     eax, eax
    test    r9, O_CREAT or O_TRUNC
    jz      .so_clean
    mov     eax, 1
.so_clean:
    mov     qword [rbx + 32], rax   ; dirty
    ; позиція: 0, або кінець файлу для O_APPEND
    xor     rax, rax
    test    r9, O_APPEND
    jz      .so_pos
    mov     rax, r14
.so_pos:
    mov     qword [rbx + 8], rax
    ; запам'ятовуємо ім'я, щоб знати, куди писати при close
    lea     rdi, [rbx + 40]
    lea     rsi, [ParsedFileName]
    mov     rcx, 11
    cld
    rep     movsb

    mov     eax, r13d
    jmp     .syscall_end
.so_fail:
    mov     rax, -1
    jmp     .syscall_end

; ---------- syscall 17: read(fd, buf, count) ----------
;   RSI = fd, R9 = буфер, RDI = скільки байт
;   -> RAX = скільки прочитано (0 = кінець файлу), -1 = помилка
.sys_read:
    mov     eax, esi
    call    FdEntry
    jc      .sr_fail
    cmp     qword [rbx], 0
    je      .sr_fail

    mov     r10, [rbx + 8]          ; pos
    mov     r11, [rbx + 16]         ; size
    cmp     r10, r11
    jae     .sr_eof
    mov     rcx, r11
    sub     rcx, r10                ; скільки лишилось до кінця
    cmp     rcx, rdi
    jbe     .sr_have
    mov     rcx, rdi
.sr_have:
    push    rcx
    mov     eax, esi
    call    FdData
    mov     rsi, rdi
    add     rsi, r10                ; звідки читаємо
    mov     rdi, r9                 ; куди
    cld
    rep     movsb
    pop     rcx
    add     [rbx + 8], rcx          ; просуваємо позицію
    mov     rax, rcx
    jmp     .syscall_end
.sr_eof:
    xor     rax, rax
    jmp     .syscall_end
.sr_fail:
    mov     rax, -1
    jmp     .syscall_end

; ---------- syscall 18: write(fd, buf, count) ----------
;   RSI = fd, R9 = буфер, RDI = скільки байт
;   -> RAX = скільки записано, -1 = помилка
.sys_write:
    mov     eax, esi
    call    FdEntry
    jc      .sw_fail
    cmp     qword [rbx], 0
    je      .sw_fail

    mov     r10, [rbx + 8]          ; pos
    cmp     r10, FD_CAP
    jae     .sw_full
    mov     rcx, FD_CAP
    sub     rcx, r10                ; скільки місця лишилось
    cmp     rcx, rdi
    jbe     .sw_have
    mov     rcx, rdi
.sw_have:
    push    rcx
    mov     eax, esi
    call    FdData
    add     rdi, r10                ; куди пишемо
    mov     rsi, r9                 ; звідки
    cld
    rep     movsb
    pop     rcx
    add     [rbx + 8], rcx
    mov     qword [rbx + 32], 1     ; dirty
    ; якщо вийшли за поточний розмір - файл виріс
    mov     rax, [rbx + 8]
    cmp     rax, [rbx + 16]
    jbe     .sw_done
    mov     [rbx + 16], rax
.sw_done:
    mov     rax, rcx
    jmp     .syscall_end
.sw_full:
    xor     rax, rax
    jmp     .syscall_end
.sw_fail:
    mov     rax, -1
    jmp     .syscall_end

; ---------- syscall 19: lseek(fd, offset, whence) ----------
;   RSI = fd, R9 = зміщення (знакове), RDI = 0:SET 1:CUR 2:END
;   -> RAX = нова позиція, -1 = помилка
.sys_lseek:
    mov     eax, esi
    call    FdEntry
    jc      .sl_fail
    cmp     qword [rbx], 0
    je      .sl_fail

    cmp     rdi, 1
    je      .sl_cur
    cmp     rdi, 2
    je      .sl_end
    mov     rax, r9                 ; SEEK_SET
    jmp     .sl_check
.sl_cur:
    mov     rax, [rbx + 8]
    add     rax, r9
    jmp     .sl_check
.sl_end:
    mov     rax, [rbx + 16]
    add     rax, r9
.sl_check:
    cmp     rax, 0
    jl      .sl_fail                ; від'ємна позиція неприпустима
    cmp     rax, FD_CAP
    ja      .sl_fail
    mov     [rbx + 8], rax
    jmp     .syscall_end
.sl_fail:
    mov     rax, -1
    jmp     .syscall_end

; ---------- syscall 20: close(fd) ----------
;   RSI = fd  -> RAX = 0, або -1
.sys_close:
    mov     eax, esi
    call    FdEntry
    jc      .sc_fail
    cmp     qword [rbx], 0
    je      .sc_fail

    cmp     qword [rbx + 32], 0     ; dirty?
    je      .sc_free
    ; скидаємо буфер на диск одним викликом
    push    rbx
    mov     eax, esi
    call    FdData
    mov     r9, rdi                 ; дані
    lea     r8, [rbx + 40]          ; ім'я у форматі FAT
    mov     ebx, dword [rbx + 16]   ; розмір
    call    FatWriteFile
    pop     rbx
.sc_free:
    mov     qword [rbx], 0          ; звільняємо дескриптор
    mov     qword [rbx + 8], 0
    mov     qword [rbx + 16], 0
    mov     qword [rbx + 24], 0
    mov     qword [rbx + 32], 0
    xor     rax, rax
    jmp     .syscall_end
.sc_fail:
    mov     rax, -1
    jmp     .syscall_end

; ---------- syscall 21: аргументи командного рядка ----------
;   RSI = буфер, R9 = його розмір
;   -> RAX = довжина рядка (без нуль-термінатора)
; Потрібно, щоб можна було запускати 'RUN FASM.BIN A.ASM A.BIN'.
.sys_get_args:
    push    rsi
    push    rdi
    mov     rdi, rsi
    lea     rsi, [CmdArgs]
    xor     ecx, ecx
.sga_loop:
    cmp     rcx, r9
    jae     .sga_done
    cmp     rcx, 127
    jae     .sga_done
    mov     al, [rsi + rcx]
    test    al, al
    jz      .sga_done
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .sga_loop
.sga_done:
    test    r9, r9
    jz      .sga_ret
    mov     byte [rdi + rcx], 0
.sga_ret:
    mov     rax, rcx
    pop     rdi
    pop     rsi
    jmp     .syscall_end


; syscall 22 - залити прямокутник кольором.
;   RSI = вказівник на структуру: x, y, w, h, колір (5 двослів)
; Обрізається по краях екрана, тому від'ємні чи завеликі значення
; безпечні - вони просто нічого не намалюють.
.sys_fill_rect:
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13

    mov     r10d, [rsi]             ; x
    mov     r11d, [rsi + 4]         ; y
    mov     r12d, [rsi + 8]         ; ширина
    mov     r13d, [rsi + 12]        ; висота
    mov     ebx,  [rsi + 16]        ; колір

    ; --- Обрізаємо зліва і зверху ---
    cmp     r10d, 0
    jge     .fr_x_ok
    add     r12d, r10d              ; ширина зменшується на те, що зліва
    xor     r10d, r10d
.fr_x_ok:
    cmp     r11d, 0
    jge     .fr_y_ok
    add     r13d, r11d
    xor     r11d, r11d
.fr_y_ok:
    cmp     r12d, 0
    jle     .fr_done
    cmp     r13d, 0
    jle     .fr_done

    ; --- Куди пише ця задача ---
    ;
    ; Раніше тут стояли ScreenWidth і ScreenBase просто так, і задача
    ; у вікні цим викликом замальовувала весь екран поверх оболонки -
    ; та сама вада, що була в друку тексту. Ціль тримаємо в регістрах,
    ; бо дві живі задачі можуть опинитись тут одночасно.
    ;   R8   = база призначення, R9D = його крок
    ;   ECX  = його ширина,      EAX = його висота
    mov     rax, [CurrentTask]
    mov     r8, [TaskCanvas + rax*8]
    test    r8, r8
    jz      .fr_screen
    mov     r9d, [TaskCanvasS + rax*4]
    mov     ecx, [TaskCanvasW + rax*4]
    mov     eax, [TaskCanvasH + rax*4]
    inc     dword [CanvasSeq]
    jmp     .fr_target_ready
.fr_screen:
    mov     r8,  [ScreenBase]
    mov     r9d, [ScreenStride]
    mov     ecx, [ScreenWidth]
    mov     eax, [ScreenHeight]
.fr_target_ready:

    ; --- Обрізаємо справа і знизу ---
    sub     ecx, r10d
    jle     .fr_done
    cmp     r12d, ecx
    jle     .fr_w_ok
    mov     r12d, ecx
.fr_w_ok:
    sub     eax, r11d
    jle     .fr_done
    cmp     r13d, eax
    jle     .fr_h_ok
    mov     r13d, eax
.fr_h_ok:

    ; --- Заливаємо порядково ---
    mov     eax, r11d
    imul    eax, r9d
    add     eax, r10d
    shl     rax, 2
    add     rax, r8
    mov     rdi, rax                ; RDI = початок першого рядка

    mov     edx, r9d
    shl     edx, 2                  ; крок між рядками в байтах
    cld
.fr_row:
    push    rdi
    mov     ecx, r12d
    mov     eax, ebx
    rep     stosd
    pop     rdi
    add     rdi, rdx
    dec     r13d
    jnz     .fr_row

.fr_done:
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    xor     rax, rax
    jmp     .syscall_end

; syscall 23 - хто відповідає за курсор миші.
;   RSI = 1 - курсор малює ПРОГРАМА, ядро не чіпає екран
;   RSI = 0 - курсор знову малює ядро (стан за замовчуванням)
;
; Потрібно програмам, які малюють у власний буфер і виводять його
; частинами: інакше ядро відновлює фон, збережений до їхнього
; виведення, і на екрані лишається слід від курсора.
.sys_cursor_owner:
    ; Задача з полотном курсором не розпоряджається: вона малює у
    ; вікно, а курсор належить тому, хто малює екран.
    mov     rax, [CurrentTask]
    cmp     qword [TaskCanvas + rax*8], 0
    jne     .syscall_end
    test    rsi, rsi
    jz      .sco_kernel
    ; Ядро курсор більше не малює взагалі, тож приховувати нічого.
    ; Прапорець лишено для сумісності: старі програми можуть його
    ; виставляти, і це нічого не змінює.
    mov     byte [MouseDrawn], 0
    mov     byte [MouseOwnedByApp], 1
    jmp     .syscall_end
.sco_kernel:
    mov     byte [MouseOwnedByApp], 0
    mov     byte [MouseDrawn], 0
    jmp     .syscall_end

.sys_exit:
    cli                             
    mov     byte [MouseOwnedByApp], 0   ; програма пішла - курсор знову наш
    ; Слот звільняємо, інакше він лишився б зайнятим назавжди й після
    ; кількох запусків вільних не стало б.
    ;
    ; Нульовий не звільняємо НІКОЛИ, хай би що там опинилось у
    ; CurrentTask: це слот самого ядра, і без нього планувальнику
    ; нема кого виконувати взагалі.
    mov     rax, [CurrentTask]
    test    rax, rax
    jz      .exit_keep_kernel
    mov     rbx, rax
    call    KeysReleaseFor              ; черга клавіш більше не її
    ; Простір задачі не звільняємо тут: ми на її ж стеку, і робити
    ; це зараз означало б рубати гілку під собою. Лише позначаємо -
    ; звільнить обробник RUN, коли повернеться у свій простір.
    mov     rbx, [TaskCR3 + rax*8]
    mov     [PendingFree], rbx
    mov     rbx, [PagePml4]
    mov     [TaskCR3 + rax*8], rbx
    mov     byte [TaskState + rax], 0
    ; Якщо в задачі є батько, який заснув на syscall 37 - будимо
    ; його, і програми на цьому не закінчуються. Інакше повертаємо
    ; керування консолі, як і раніше.
    mov     rbx, [TaskParent + rax*8]
    mov     qword [TaskParent + rax*8], 0
    test    rbx, rbx
    jz      .exit_keep_kernel
    mov     byte [TaskState + rbx], 1
    mov     qword [CurrentTask], 0
    mov     rax, [TaskCR3]
    mov     cr3, rax
    mov     rsp, [TaskRSP]
    jmp     .exit_restore

.exit_keep_kernel:
    mov     byte [AppRunning], 0    
    mov     qword [CurrentTask], 0  

    ; Повертаємось у простір ядра тут-таки, поруч зі стеком, і за тим
    ; самим правилом: між зміною CR3 і зміною RSP - жодного звернення
    ; до стека. Далі ми виконуємось як задача 0 і не маємо права
    ; лишатися в просторі щойно знятої програми.
    mov     rax, [TaskCR3]
    mov     cr3, rax
    mov     rsp, [TaskRSP]          
.exit_restore:
    pop     r15                     
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    iretq

.syscall_end:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rbx
    pop     rdx
    pop     rcx
    iretq                       

; ==========================================================
; ФАЙЛОВІ ДЕСКРИПТОРИ (syscalls 16-20)
;
; Запис таблиці FdTable (FD_ENT = 64 байти):
;   +0  used   (dq)  0 = вільний
;   +8  pos    (dq)  поточна позиція
;   +16 size   (dq)  розмір файлу
;   +24 flags  (dq)
;   +32 dirty  (dq)  1 = треба скинути на диск при close
;   +40 name   (11 байт, формат FAT)
;
; Дані файлу лежать окремо: FileDataBase + fd*FD_CAP
; ==========================================================

; EAX = fd -> RBX = адреса запису таблиці. CF=1 якщо fd некоректний.
FdEntry:
    cmp     eax, 0
    jl      .fe_bad
    cmp     eax, MAX_FD
    jge     .fe_bad
    mov     ebx, eax
    imul    ebx, FD_ENT
    lea     rbx, [FdTable + rbx]
    clc
    ret
.fe_bad:
    stc
    ret

; EAX = fd -> RDI = адреса буфера даних цього дескриптора
FdData:
    push    rax
    mov     rdi, FD_CAP
    imul    rdi, rax
    add     rdi, FileDataBase
    pop     rax
    ret

align 16
; ==========================================================
; BackgroundTask - друга задача, яка існує лише щоб довести, що
; планувальник справді перемикає задачі.
;
; Досі вона малювала жовту літеру посеред екрана - і не виконувалась
; жодного разу: старий планувальник умів перемикатись лише на
; програму, а до фонової задачі черга не доходила ніколи.
;
; Тепер вона рахує оберти й одразу засинає через hlt. Ціна - одне
; перемикання контексту на оберт, тобто майже нуль. Користь - число,
; яке росте: якщо воно змінилося між двома викликами TASKS, значить
; задачі справді чергуються, а не просто позначені готовими.
; ==========================================================
BackgroundTask:
    inc     qword [BgTicks]
    hlt                             ; до наступного переривання таймера
    jmp     BackgroundTask

InitTask1:
    push    rax
    push    rcx             

    mov     rax, Task1_StackTop 
    
    xor     rcx, rcx
    mov     cx, ss              
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], Task1_StackTop 
    
    sub     rax, 8
    mov     qword [rax], 0x202  
    
    xor     rcx, rcx
    mov     cx, cs              
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], BackgroundTask 

    mov     rcx, 15
.push_regs:
    sub     rax, 8
    mov     qword [rax], 0      
    loop    .push_regs

    mov     [TaskRSP + 8], rax
    mov     byte [TaskState + 1], 1     ; тепер вона справді в черзі

    pop     rcx
    pop     rax             
    ret
    
; ------------------------------------------------------------
; KeysReleaseFor - зняти передачу клавіатури, якщо вона стосується
; задачі RBX: або це сам власник, або його дитина.
;
; Без цього прапорець лишався б піднятим після смерті задачі, а
; KeysOwner вказував би на порожній слот. Наступна задача в тому ж
; слоті стала б глухою, і причину шукали б довго.
;
; Псує лише прапорці; регістри лишає як були.
; ------------------------------------------------------------
; ------------------------------------------------------------
; FsWaitIfNeeded - дочекатися, поки ядро закінчить роботу з диском.
;   RAX = номер системного виклику (не псується)
;
; Увесь шар FAT ходить через спільні буфери: SectorBuffer (три
; десятки місць), FatCacheBuf, DirBuffer, SysNameA, а ще
; DirEntrySector з DirEntryOffset і VideoMemoryBase як проміжний.
;
; Самі виклики переплестися НЕ можуть: вектор 0x80 зареєстровано як
; interrupt gate (0x8E), тобто виконуються вони з вимкненими
; перериваннями й до кінця. Небезпечне інше - завантаження образу
; програми йде в задачі ядра з УВІМКНЕНИМИ перериваннями, і таймер
; може спинити його просто посеред читання ланцюга.
;
; Тому чекаємо саме тут. Оновити список файлів, поки ядро вантажить
; гру, означало б переплести дві операції в тих самих 512 байтах -
; причому зіпсувався б вміст файлу, а не впав стек, тобто дізналися
; б ми про це набагато пізніше й зовсім не там.
; ------------------------------------------------------------
; БУФЕР ТЕКСТУ ЗАДАЧІ У ВІКНІ
;
; Текстові виклики малюють прямо у фреймбуфер, повз blit, і полотна
; не бачать. Спершу задачі з полотном їх просто не виконували - і
; програма, яка лише друкує, у вікні не показувала нічого. Тепер
; текст складається сюди, а показує його оболонка.
;
; Буфер один, як і вікно програми: розрізняти кількох дітей ядро
; однаково не вміє.
; ------------------------------------------------------------

; AppTextPutChar - додати байт AL. Регістри лишає як були.
;
; Коли місця не стало, викидаємо ПЕРШУ половину. Журнал запуску
; цікавий на початку, працююча програма - у кінці; половина зберігає
; обидва краї краще, ніж будь-яке з двох правил окремо.
AppTextPutChar:
    push    rbx
    push    rcx
    push    rdi
    push    rsi
    mov     bl, al

    mov     ecx, [AppTextHdr + 8]
    cmp     ecx, APPTEXT_MAX
    jb      .atp_room
    mov     rsi, AppTextBase + APPTEXT_MAX / 2
    mov     rdi, AppTextBase
    mov     rcx, APPTEXT_MAX / 2
    cld
    rep     movsb
    mov     ecx, APPTEXT_MAX / 2
.atp_room:
    mov     rdi, AppTextBase
    add     rdi, rcx
    mov     [rdi], bl
    inc     ecx
    mov     [AppTextHdr + 8], ecx
    inc     dword [AppTextHdr + 12]

    pop     rsi
    pop     rdi
    pop     rcx
    pop     rbx
    ret

; AppTextPutStr - додати рядок із RSI до нуля.
AppTextPutStr:
    push    rax
    push    rsi
.atps_loop:
    mov     al, [rsi]
    test    al, al
    jz      .atps_done
    call    AppTextPutChar
    inc     rsi
    jmp     .atps_loop
.atps_done:
    pop     rsi
    pop     rax
    ret

; AppTextReset - буфер порожній. Кличеться і при запуску задачі,
; щоб у вікні не лишався журнал попередньої.
AppTextReset:
    mov     dword [AppTextHdr + 8], 0
    inc     dword [AppTextHdr + 12]
    ret

; ------------------------------------------------------------
FsSyscallList:
    db 5, 8, 13, 14, 16, 17, 18, 19, 20, 24, 29
    db 32, 33, 34, 35, 36, 38, 39
    db 0xFF                         ; кінець переліку

FsWaitIfNeeded:
    push    rbx
    push    rcx
    push    rsi

    lea     rsi, [FsSyscallList]
.fsw_scan:
    mov     bl, [rsi]
    cmp     bl, 0xFF
    je      .fsw_done               ; виклик диска не чіпає
    movzx   rcx, bl
    cmp     rcx, rax
    je      .fsw_wait
    inc     rsi
    jmp     .fsw_scan

.fsw_wait:
    cmp     byte [FsBusy], 0
    je      .fsw_done
    ; Ми всередині виклику, тобто з вимкненими перериваннями. Щоб
    ; задача ядра встигла дочитати, їх треба на цей час віддати.
    sti
    hlt
    cli
    jmp     .fsw_wait

.fsw_done:
    pop     rsi
    pop     rcx
    pop     rbx
    ret

KeysReleaseFor:
    push    rax
    cmp     byte [KeysToChild], 0
    je      .krf_done
    cmp     rbx, [KeysOwner]
    je      .krf_clear              ; помер сам власник
    mov     rax, [TaskParent + rbx*8]
    cmp     rax, [KeysOwner]
    jne     .krf_done               ; чужа задача - не наша справа
.krf_clear:
    mov     byte [KeysToChild], 0
    mov     qword [KeysOwner], 0
.krf_done:
    pop     rax
    ret

SpawnAppTask:
    cli                         
    ; Слот більше не прибитий цвяхом до одиниці: шукаємо вільний.
    ; Нульовий пропускаємо - він завжди належить ядру.
    mov     rcx, 1
.find_slot:
    cmp     byte [TaskState + rcx], 0
    je      .slot_found
    inc     rcx
    cmp     rcx, MAX_TASKS
    jb      .find_slot
    ; Вільних слотів немає. Прапорець зняти обов'язково: інакше
    ; батько вічно чув би "дитина жива" й ніколи не закрив би вікно.
    mov     byte [SpawnBusy], 0
    mov     qword [PendingCanvas], 0
    sti
    ret
.slot_found:
    ; Полотно видається саме тут - кожній задачі без винятку. Для
    ; звичайного запуску PendingCanvas нульовий, і слот дістає нуль,
    ; тобто малює прямо в екран, як завжди. Завдяки цьому наступна
    ; задача не може успадкувати полотно попередньої.
    mov     rax, [PendingCanvas]
    mov     [TaskCanvas + rcx*8], rax
    mov     eax, [PendingCanvasW]
    mov     [TaskCanvasW + rcx*4], eax
    mov     eax, [PendingCanvasH]
    mov     [TaskCanvasH + rcx*4], eax
    mov     eax, [PendingCanvasS]
    mov     [TaskCanvasS + rcx*4], eax
    mov     qword [PendingCanvas], 0
    call    AppTextReset            ; щоб не лишався журнал попередньої

    mov     [AppTask], rcx
    mov     byte [AppRunning], 1    

    ; Кого будити, коли ця задача завершиться. Нуль означає, що
    ; будити нікого - програму запустили з консолі.
    mov     rax, [SpawnParent]
    mov     [TaskParent + rcx*8], rax
    mov     qword [SpawnParent], 0

    ; Власний адресний простір для програми. Поки це точна копія
    ; ядерного, тобто нічого не змінює по суті - але CR3 у задачі
    ; вже свій, і планувальник справді його перемикає.
    ;
    ; Якщо кадрів не вистачило, лишаємо спільний простір: краще
    ; працювати як раніше, ніж не запуститись зовсім.
    ; Кадр задачі мусить лягти в ЇЇ простір, а не в ядерний.
    ; Стек програми тепер приватний: у ядерному просторі за адресою
    ; AppStackTop зовсім інші сторінки. Побудований не там кадр
    ; означає, що задача стартує з порожнім стеком - і перший же pop
    ; дає збій, який нічим діагностувати.
    ;
    ; Переривання тут уже заборонені (cli на вході), тому підміняти
    ; простір задачі 0 не треба: перемкнути нас назад нікому.
    mov     byte [SpawnSwitched], 0
    mov     rax, [PendingCR3]
    test    rax, rax
    jz      .space_shared
    mov     [TaskCR3 + rcx*8], rax
    mov     qword [PendingCR3], 0
    mov     cr3, rax
    mov     byte [SpawnSwitched], 1
.space_shared:
    mov     rax, AppStackTop 
    
    xor     rcx, rcx
    mov     cx, ss
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], AppStackTop 
    
    sub     rax, 8
    mov     qword [rax], 0x202  
    
    xor     rcx, rcx
    mov     cx, cs
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], AppMemoryBase 

    mov     rcx, 15
.push_regs_app:
    sub     rax, 8
    mov     qword [rax], 0      
    loop    .push_regs_app

    ; Стартові аргументи для програми (SysV: RDI, RSI, RDX)
    ; [rax+64] = RDI, [rax+72] = RSI, [rax+88] = RDX - згідно з порядком pop у TimerHandler
    mov     rdi, [ScreenBase]
    mov     [rax + 64], rdi      ; RDI = адреса фреймбуфера
    
    xor     rsi, rsi
    mov     esi, [ScreenWidth]
    mov     [rax + 72], rsi      ; RSI = ширина

    xor     rdx, rdx
    mov     edx, [ScreenHeight]
    mov     [rax + 88], rdx      ; RDX = висота

    mov     rcx, [AppTask]
    mov     [TaskRSP + rcx*8], rax
    mov     byte [TaskState + rcx], 1
    ; Аж ТЕПЕР задача існує для стороннього ока. Доти SpawnPending
    ; уже був знятий, а TaskParent іще не виставлений, і в цю щілину
    ; - а вона завдовжки з усе читання образу з диска - батько бачив
    ; "дитини немає" й закривав вікно, поки гра ще вантажилась.
    mov     byte [SpawnBusy], 0

    ; Повертаємо ядерний простір: далі ми знову звичайна задача 0.
    cmp     byte [SpawnSwitched], 0
    je      .spawn_done
    mov     rax, [PagePml4]
    mov     cr3, rax
.spawn_done:

    sti
    ret

; ==========================================================
; ДАНІ ТА СТЕКИ
; ==========================================================

; === Виділяємо стек для фонової задачі в ядрі ===
align 16
Task1_Stack     rb 4096
Task1_StackTop:

; ==========================================================
; 12. ОБРОБНИКИ АПАРАТНИХ ВИНЯТКІВ (EXCEPTIONS 0-31)
; ==========================================================

macro isr_no_err vector {
    align 8
    isr_#vector:
        cli
        push    0           
        push    vector      
        jmp     isr_common_stub
}

macro isr_err vector {
    align 8
    isr_#vector:
        cli
        push    vector      
        jmp     isr_common_stub
}

isr_no_err 0   ; Divide by zero
isr_no_err 1   ; Debug
isr_no_err 2   ; NMI
isr_no_err 3   ; Breakpoint
isr_no_err 4   ; Overflow
isr_no_err 5   ; Bound Range Exceeded
isr_no_err 6   ; Invalid Opcode
isr_no_err 7   ; Device Not Available
isr_err    8   ; Double Fault 
isr_no_err 9   ; Coprocessor Segment Overrun
isr_err    10  ; Invalid TSS 
isr_err    11  ; Segment Not Present 
isr_err    12  ; Stack-Segment Fault 
isr_err    13  ; General Protection Fault 
isr_err    14  ; Page Fault 
isr_no_err 15  ; Reserved
isr_no_err 16  ; x87 Floating-Point Exception
isr_err    17  ; Alignment Check 
isr_no_err 18  ; Machine Check
isr_no_err 19  ; SIMD Floating-Point Exception
isr_no_err 20  ; Virtualization Exception
isr_err    21  ; Control Protection Exception 
isr_no_err 22
isr_no_err 23
isr_no_err 24
isr_no_err 25
isr_no_err 26
isr_no_err 27
isr_no_err 28
isr_no_err 29
isr_err    30  ; Security Exception 
isr_no_err 31

align 8
ExceptionVectors:
    dq isr_0, isr_1, isr_2, isr_3, isr_4, isr_5, isr_6, isr_7
    dq isr_8, isr_9, isr_10, isr_11, isr_12, isr_13, isr_14, isr_15
    dq isr_16, isr_17, isr_18, isr_19, isr_20, isr_21, isr_22, isr_23
    dq isr_24, isr_25, isr_26, isr_27, isr_28, isr_29, isr_30, isr_31

align 16
isr_common_stub:
    ; --- Спершу: чи це законна відмова на купі програми? ---
    ;
    ; Купа оголошена як адреси, але кадрів під нею немає, доки
    ; програма туди не звернеться. Перше звернення потрапляє сюди -
    ; і це НЕ аварія, а звичайна подія: виділяємо кадр, відображаємо
    ; і повертаємось так, ніби нічого не сталося.
    ;
    ; Саме тому тут не можна зачепити жоден регістр програми: вона
    ; продовжить виконання з тієї самої інструкції.
    ;
    ; Межа законного мусить бути ВУЗЬКОЮ. Якщо помилитись і виділяти
    ; кадр на будь-яку відмову, система перестане ловити те, заради
    ; чого ставились нульова сторінка й вартовий під стеком: справжня
    ; вада програми тихо отримає пам'ять і поїде далі.
    push    rax
    push    rcx
    push    rdx
    push    rsi

    mov     rax, [rsp + 32]             ; вектор: чотири push вище
    cmp     rax, 14
    jne     .no_demand

    mov     rcx, [rsp + 40]             ; код помилки
    test    cl, 1                       ; сторінка присутня?
    jnz     .no_demand                  ; тоді це порушення прав, не наш випадок

    mov     rax, cr2

    ; Дві законні області: вікно програми - стек і образ - та купа.
    ; Усе інше лишається аварією, як і було.
    mov     rcx, AppSpaceLow
    cmp     rax, rcx
    jb      .chk_heap
    mov     rcx, AppSpaceHigh
    cmp     rax, rcx
    jb      .demand_ok
.chk_heap:
    mov     rcx, UserHeapBase
    cmp     rax, rcx
    jb      .no_demand
    mov     rcx, UserHeapBase + UserHeapSize
    cmp     rax, rcx
    jae     .no_demand
.demand_ok:

    ; Запис каталогу має існувати - таблиці під купу створені на
    ; старті. Якщо його раптом немає, краще впасти чесно, ніж писати
    ; за адресою нуль.
    ; Каталог беремо з ПОТОЧНОГО CR3, а не з глобальної змінної:
    ; сторінку треба відобразити в тому просторі, у якому стався
    ; збій. Поки простори однакові, різниці немає - але щойно вони
    ; стануть різними, глобальний PD0 віддав би сторінку не тій
    ; задачі, і та далі падала б на тій самій адресі вічно.
    mov     rsi, cr3
    shr     rsi, 12
    shl     rsi, 12                 ; корінь таблиць
    mov     rsi, [rsi]              ; PML4[0] -> PDPT
    test    sil, 1
    jz      .no_demand
    shr     rsi, 12
    shl     rsi, 12
    mov     rsi, [rsi]              ; PDPT[0] -> PD0
    test    sil, 1
    jz      .no_demand
    shr     rsi, 12
    shl     rsi, 12                 ; адреса каталогу

    mov     rdx, rax
    shr     rdx, 21
    mov     rdx, [rsi + rdx*8]      ; запис каталогу
    test    dl, 1
    jz      .no_demand
    shr     rdx, 12
    shl     rdx, 12                     ; адреса таблиці сторінок

    push    rax
    call    FrameAlloc
    mov     rcx, rax
    pop     rax
    test    rcx, rcx
    jz      .no_demand                  ; кадрів немає - хай падає чесно

    mov     rsi, rax
    shr     rsi, 12
    and     esi, 511                    ; номер сторінки в таблиці
    or      rcx, 3                      ; present | writable
    mov     [rdx + rsi*8], rcx
    invlpg  [rax]
    inc     qword [DemandPages]

    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    add     rsp, 16                     ; знімаємо вектор і код помилки
    iretq

.no_demand:
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax

    ; На вершині стеку: [номер вектора][код помилки][RIP][CS][RFLAGS][RSP][SS]
    mov     rax, [rsp]              ; номер вектора
    mov     [LastFaultVector], rax
    mov     rax, [rsp + 16]         ; RIP, де впало
    mov     [LastFaultRIP], rax

    ; Код помилки лежить одразу під номером вектора. Для векторів
    ; без коду макрос кладе нуль, тому читати можна завжди.
    mov     rax, [rsp + 8]
    mov     [LastFaultErr], rax

    ; CR2 - адреса, за якою стався збій. Дійсна лише зараз:
    ; наступна відмова сторінки її перепише.
    mov     rax, cr2
    mov     [LastFaultCR2], rax

    ; ВИПРАВЛЕНО: весь вивід РОБИМО ДО відновлення регістрів ядра,
    ; інакше ClearScreen/DrawTaskbar/PrintPrompt знову їх затирали.
    cmp     qword [CurrentTask], 0
    je      .kernel_panic       

.kill_app:
    mov     rax, [CurrentTask]
    test    rax, rax
    jz      .kill_keep_kernel
    mov     byte [TaskState + rax], 0
    mov     rbx, [TaskCR3 + rax*8]
    mov     [PendingFree], rbx
    mov     rbx, [PagePml4]
    mov     [TaskCR3 + rax*8], rbx

    ; Якщо в збійної задачі був батько, що спить на syscall 37 -
    ; будимо його. Оболонка має пережити падіння того, що вона
    ; запустила: саме заради цього вона й лишається живою.
    mov     rbx, [TaskParent + rax*8]
    mov     qword [TaskParent + rax*8], 0
    test    rbx, rbx
    jz      .kill_keep_kernel
    mov     byte [TaskState + rbx], 1
    mov     [AppTask], rbx
    mov     qword [CurrentTask], 0
    jmp     .kill_to_kernel     ; AppRunning лишається: батько живий

.kill_keep_kernel:
    mov     byte [AppRunning], 0
    mov     qword [CurrentTask], 0

.kill_to_kernel:

    ; Спершу переходимо в простір і на стек ядра: стек збійної
    ; програми може бути зруйнований, а її простір з наступним
    ; кроком перестане містити ядерні дані. Збережені регістри
    ; лежать ВИЩЕ RSP, тому call/push нижче них нічого не псують.
    mov     rax, [TaskCR3]
    mov     cr3, rax
    mov     rsp, [TaskRSP]

    call    ClearScreen             
    call    DrawTaskbar             
    mov     qword [CursorX], 20     
    mov     qword [CursorY], 100

    mov     rcx, 20
    mov     rdx, 100
    lea     r8,  [MsgCrash]
    mov     r9d, 0x000000FF     
    call    DrawString

    ; Показуємо номер винятку та адресу збою
    mov     rcx, 20
    mov     rdx, 120
    lea     r8,  [MsgFaultVec]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultVector]
    lea     rdi, [HexBuf]
    call    HexToStr
    mov     rcx, 130
    mov     rdx, 120
    lea     r8,  [HexBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    mov     rcx, 20
    mov     rdx, 140
    lea     r8,  [MsgFaultRIP]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultRIP]
    lea     rdi, [HexBuf]
    call    HexToStr
    mov     rcx, 130
    mov     rdx, 140
    lea     r8,  [HexBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    ; Для відмови сторінки номера вектора й RIP замало: потрібні
    ; адреса, за якою впало, і причина. Без них кожна помилка
    ; наступних кроків шукалася б наосліп.
    mov     qword [CursorY], 170
    cmp     qword [LastFaultVector], 14
    jne     .pf_app_done

    mov     rcx, 20
    mov     rdx, 160
    lea     r8,  [MsgFaultCR2]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultCR2]
    lea     rdi, [HexBuf]
    call    HexToStr
    mov     rcx, 130
    mov     rdx, 160
    lea     r8,  [HexBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    mov     rcx, 20
    mov     rdx, 180
    lea     r8,  [MsgFaultErr]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultErr]
    call    FaultErrDecode
    mov     rcx, 130
    mov     rdx, 180
    lea     r8,  [FaultErrBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    mov     qword [CursorY], 210
.pf_app_done:
    mov     qword [CursorX], 20
    call    PrintPrompt

    ; А тепер - повертаємо контекст ядра і виходимо
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax

    iretq                       

.kernel_panic:
    ; Виняток у самому ядрі. Далі буде лише зупинка, тому це
    ; єдина нагода щось показати - і показане має бути читабельним.
    ;
    ; ВИПРАВЛЕНО: раніше паніка друкувалася поверх того, що вже було
    ; на екрані, і накладалася на банер. Числа були, прочитати їх
    ; було неможливо. Тепер екран чиститься, як і на шляху падіння
    ; програми.
    call    ClearScreen
    call    DrawTaskbar

    mov     rcx, 20
    mov     rdx, 100
    lea     r8,  [MsgPanic]
    mov     r9d, 0x000000FF
    call    DrawString

    mov     rcx, 20
    mov     rdx, 130
    lea     r8,  [MsgFaultVec]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultVector]
    lea     rdi, [HexBuf]
    call    HexToStr
    mov     rcx, 130
    mov     rdx, 130
    lea     r8,  [HexBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    mov     rcx, 20
    mov     rdx, 150
    lea     r8,  [MsgFaultRIP]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultRIP]
    lea     rdi, [HexBuf]
    call    HexToStr
    mov     rcx, 130
    mov     rdx, 150
    lea     r8,  [HexBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    ; Для відмови сторінки - адреса, за якою впало, і причина.
    cmp     qword [LastFaultVector], 14
    jne     .panic_halt

    mov     rcx, 20
    mov     rdx, 170
    lea     r8,  [MsgFaultCR2]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultCR2]
    lea     rdi, [HexBuf]
    call    HexToStr
    mov     rcx, 130
    mov     rdx, 170
    lea     r8,  [HexBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

    mov     rcx, 20
    mov     rdx, 190
    lea     r8,  [MsgFaultErr]
    mov     r9d, 0x0000FFFF
    call    DrawString
    mov     rax, [LastFaultErr]
    call    FaultErrDecode
    mov     rcx, 130
    mov     rdx, 190
    lea     r8,  [FaultErrBuf]
    mov     r9d, 0x0000FFFF
    call    DrawString

.panic_halt:
    cli
    hlt
    jmp     .panic_halt

; ----------------------------------------------------------
; FaultErrDecode - RAX = код помилки сторінки -> рядок у FaultErrBuf
;
; Біти коду:
;   0 P     0 сторінки немає, 1 сторінка є але права не ті
;   1 W     1 збій стався на записі
;   2 U     1 звернення з режиму користувача
;   3 RSVD  1 зарезервований біт у запису таблиці не нульовий
;   4 I     1 збій на вибірці інструкції
;
; Друкувати саме біти, а не число, свідомо: у налагодженні читають
; причину, а не шістнадцяткове значення.
; ----------------------------------------------------------
FaultErrDecode:
    push    rax
    push    rbx
    push    rcx
    push    rsi
    push    rdi

    mov     rbx, rax
    lea     rsi, [MsgErrTemplate]
    lea     rdi, [FaultErrBuf]
    mov     rcx, 15
    cld
    rep     movsb

    lea     rdi, [FaultErrBuf]
    xor     ecx, ecx
.fed_loop:
    mov     rax, rcx
    lea     rax, [rax + rax*2]      ; позиція цифри = 1 + номер*3
    inc     rax
    bt      ebx, ecx
    jc      .fed_one
    mov     byte [rdi + rax], '0'
    jmp     .fed_next
.fed_one:
    mov     byte [rdi + rax], '1'
.fed_next:
    inc     ecx
    cmp     ecx, 5
    jb      .fed_loop

    pop     rdi
    pop     rsi
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; DecToStr - EAX -> десятковий рядок у [RDI], нуль-терміновий
; ----------------------------------------------------------
DecToStr:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    test    eax, eax
    jnz     .d_conv
    mov     byte [rdi], '0'
    mov     byte [rdi + 1], 0
    jmp     .d_done
.d_conv:
    xor     ecx, ecx
    mov     ebx, 10
.d_loop:
    xor     edx, edx
    div     ebx
    add     dl, '0'
    push    rdx
    inc     ecx
    test    eax, eax
    jnz     .d_loop
.d_out:
    pop     rdx
    mov     [rdi], dl
    inc     rdi
    dec     ecx
    jnz     .d_out
    mov     byte [rdi], 0
.d_done:
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ----------------------------------------------------------
; HexToStr - RAX -> 16 hex-символів у [RDI], нуль-термінований
; ----------------------------------------------------------
HexToStr:
    push    rax
    push    rbx
    push    rcx
    push    rdi
    mov     rcx, 16
.hts_loop:
    rol     rax, 4
    mov     bl, al
    and     bl, 0x0F
    cmp     bl, 10
    jb      .hts_digit
    add     bl, 'A' - 10
    jmp     .hts_store
.hts_digit:
    add     bl, '0'
.hts_store:
    mov     [rdi], bl
    inc     rdi
    dec     rcx
    jnz     .hts_loop
    mov     byte [rdi], 0
    pop     rdi
    pop     rcx
    pop     rbx
    pop     rax
    ret

align 8
LastFaultVector dq 0
LastFaultRIP    dq 0
; --- Відмова сторінки ---
; CR2 і код помилки знімаємо на вході в обробник: після переходу на
; стек ядра збійний контекст уже недоступний, а CR2 перепишеться
; наступною ж відмовою.
LastFaultErr    dq 0
LastFaultCR2    dq 0
FaultErrBuf     rb 16
MsgErrTemplate  db 'P0 W0 U0 R0 I0', 0
MsgFaultCR2     db 'ADDR  :', 0
MsgFaultErr     db 'P/W/U/R/I:', 0
HexBuf          rb 20
SizeBuf         rb 16
MsgCrash    db 'FATAL EXCEPTION: APP KILLED TO PROTECT KERNEL', 0
MsgPanic    db 'KERNEL PANIC. VECTOR / RIP:', 0
MsgFaultVec db 'VECTOR:', 0
MsgFaultRIP db 'RIP   :', 0

; Основна розкладка: те, що друкується без Shift.
; Літери тут МАЛІ - великі дає Shift або CapsLock.
ScanCodes:
    db 0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, 9
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 13, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 39, '`', 0, '\'
    db 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '
    times 100 db 0 

; Розкладка з натиснутим Shift.
ScanCodesShift:
    db 0, 27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8, 9
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 13, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', 34, '~', 0, '\'
    db 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' '
    times 100 db 0 

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
    dq 0x3078CC0000000000, 0x00000000000000FF, 0x3018000000000000, 0x000078067CC67C00
    dq 0xC0C0DCE6C6C6F800, 0x00007CC6C0C67C00, 0x06067CC6C6C67E00, 0x00007CC6FEC07C00
    dq 0x1C32307C30303000, 0x00007EC67E067C00, 0xC0C0DCE6C6C6C600, 0x3000703030307800
    dq 0x0C001C0C0CCC7800, 0xC0C0CCD8F0D8CC00, 0x7030303030307800, 0x0000D8FEFED6C600
    dq 0x0000DCE6C6C6C600, 0x00007CC6C6C67C00, 0x0000F8CCF8C0C000, 0x00007CCC7C0C0C00
    dq 0x0000DCE6C0C0C000, 0x00007CC07C06FC00, 0x30307C3030361C00, 0x0000C6C6C6CE7600
    dq 0x0000C6C6C66C3800, 0x0000C6D6FEFE6C00, 0x0000C66C386CC600, 0x0000C6C67E067C00
    dq 0x0000FE1C3870FE00, 0x1C3030E030301C00, 0x3030303030303000, 0x7018180618187000
    dq 0x76DC000000000000
