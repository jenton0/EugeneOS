#ifndef STDLIB_H
#define STDLIB_H

/* ==========================================================
 * EUGENE OS — libc header
 *
 * ПРАВИЛО ПРО НОМЕРИ SYSCALL — ЧИТАТИ ПЕРЕД ТИМ, ЯК ЩОСЬ МІНЯТИ:
 *
 * Номери 1, 5 і 9 заморожені у тій формі, у якій їх бачать готові
 * бінарники на диску (порт DOOM зібрано задовго до цих змін і його
 * вихідників у нас немає). Одного разу ми додали до них аргументи —
 * ліміт у RDI для 5 і крок рядка для 9 — і зламали все, що вже
 * лежало на диску: старі програми ці поля не заповнюють, тому ядро
 * читало як аргументи сміття зі стеку.
 *
 * Тому: НІКОЛИ не додавай аргумент до наявного номера. Заводь новий.
 * Так з'явилися 24, 25 і 26.
 *
 * ЗМІНИ ПОРІВНЯНО ЗІ СТАРОЮ ВЕРСІЄЮ:
 *  - додано syscall 15 (розмір екрана) — щоб GUI не хардкодив 1024x768;
 *  - syscall 24: read_file_max() — читання з лімітом розміру буфера;
 *  - syscall 25: blit_buffer_stride() — вивід шматка великого буфера;
 *  - syscall 26: get_key_event() — клавіша з готовим ASCII і модифікаторами;
 *  - get_file_list() тепер передає розмір буфера в ядро;
 *  - прибрано fabs()/atof(): вони повертають double, а це несумісно
 *    з -mgeneral-regs-only. Планувальник ядра однаково не зберігає
 *    стан FPU/SSE при перемиканні задач, тому плаваюча кома тут
 *    у будь-якому разі небезпечна;
 *  - прибрано int32_t/ptrdiff_t як `int` там, де це було невірно.
 * ========================================================== */

/* ==========================================
 * 1. БАЗОВІ ТИПИ
 * ========================================== */
#define NULL      ((void*)0)
#define TRUE      1
#define FALSE     0
#define EOF       (-1)

typedef unsigned char      uint8_t;
typedef signed char        int8_t;
typedef unsigned short     uint16_t;
typedef signed short       int16_t;
typedef unsigned int       uint32_t;
typedef signed int         int32_t;
typedef unsigned long long uint64_t;
typedef signed long long   int64_t;
typedef unsigned long      size_t;
typedef long               ssize_t;
typedef long               intptr_t;
typedef unsigned long      uintptr_t;
typedef long               off_t;
typedef long               ptrdiff_t;   /* ВИПРАВЛЕНО: було int */

#define INT_MAX     2147483647
#define INT_MIN     (-2147483647 - 1)   /* ВИПРАВЛЕНО: -2147483648 має тип long */
#define UINT_MAX    4294967295U
#define LONG_MAX    9223372036854775807LL
#define LONG_MIN    (-9223372036854775807LL - 1)
#define SIZE_MAX    (~(size_t)0)

/* ==========================================
 * 2. ФАЙЛОВА СИСТЕМА
 * ========================================== */
typedef void FILE;
#define stdin    ((FILE*)0)
#define stdout   ((FILE*)1)
#define stderr   ((FILE*)2)

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define O_RDONLY  0
#define O_WRONLY  1
#define O_RDWR    2
#define O_CREAT   0x40
#define O_TRUNC   0x200
#define O_APPEND  0x400

#define EPERM     1
#define ENOENT    2
#define ENOMEM    12
#define EACCES    13
#define EISDIR    21
#define EINVAL    22
#define ENOSPC    28

/* ==========================================
 * 3. СИСТЕМНІ ВИКЛИКИ EUGENE OS
 *
 * Домовленість ядра (див. SyscallHandler у kernel.asm):
 *   RAX = номер, RSI = arg1, R9 = arg2, RDI = arg3, RDX = arg4
 * Ядро зберігає ВСІ регістри крім RAX (він і є результатом).
 * ========================================== */

static inline uint64_t _syscall2(uint64_t num, uint64_t a1, uint64_t a2) {
    register uint64_t rax __asm__("rax") = num;
    register uint64_t rsi __asm__("rsi") = a1;
    register uint64_t r9  __asm__("r9")  = a2;
    __asm__ volatile ("int $0x80" : "+r"(rax) : "r"(rsi), "r"(r9) : "memory");
    return rax;
}

static inline uint64_t _syscall3(uint64_t num, uint64_t a1, uint64_t a2, uint64_t a3) {
    register uint64_t rax __asm__("rax") = num;
    register uint64_t rsi __asm__("rsi") = a1;
    register uint64_t rdi __asm__("rdi") = a2;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("int $0x80" : "+r"(rax) : "r"(rsi), "r"(rdi), "r"(rdx) : "memory");
    return rax;
}

/* Сумісність зі старим кодом, який кличе syscall(num, a1, a2) */
#define syscall(num, a1, a2) _syscall2((uint64_t)(num), (uint64_t)(a1), (uint64_t)(a2))

/* --- Публічні обгортки --- */

static inline void sys_exit(void) {
    __asm__ volatile ("xor %%rax, %%rax\n\tint $0x80" ::: "rax", "memory");
    for (;;) { }
}

/* syscall 1 — сирий скан-код, СТАРА форма (біт 0x80 = відпускання).
   Формат зафіксований назавжди: його чекають готові бінарники на
   диску. Якщо потрібен готовий ASCII і модифікатори — get_key_event(),
   це syscall 26. Користуйся ЧИМОСЬ ОДНИМ: черга спільна. */
static inline uint64_t get_key(void)                        { return _syscall2(1, 0, 0); }
static inline void     print(const char* s, uint32_t color) { _syscall2(2, (uint64_t)s, (uint64_t)color); }
static inline void     clear_screen(void)                   { _syscall2(4, 0, 0); }
static inline void     put_char(char c, uint32_t color)     { _syscall2(6, (uint64_t)(uint8_t)c, (uint64_t)color); }
static inline void     erase_char(void)                     { _syscall2(7, 0, 0); }
static inline void     list_files(void)                     { _syscall2(8, 0, 0); }
static inline uint64_t get_ticks(void)                      { return _syscall2(10, 0, 0); }

/*
 * syscall 24 — читання файлу з лімітом.
 *   name     — звичайне ім'я "NAME.EXT" (НЕ 11-байтний FAT-формат!)
 *   dest     — куди класти дані
 *   maxbytes — скільки байт МАКСИМУМ можна записати в dest (0 = без ліміту)
 * Повертає реальну кількість скопійованих байт.
 *
 * ЧОМУ ОКРЕМИЙ НОМЕР, А НЕ syscall 5.
 * Старий syscall 5 писав у dest ПОВНИМИ кластерами і повертав
 * округлений розмір: 20-байтний .TXT затирав 4 КБ пам'яті програми.
 * Ліміт спершу додали прямо в syscall 5, у регістр RDI — і зламали
 * усі готові бінарники на диску (порт DOOM), бо вони цей регістр не
 * заповнюють і ядро брало як ліміт сміття. Тому номер 5 повернуто до
 * старої поведінки назавжди, а виправлена форма живе тут.
 */
static inline uint64_t read_file_max(const char* name, void* dest, uint64_t maxbytes) {
    register uint64_t rax __asm__("rax") = 24;
    register uint64_t rsi __asm__("rsi") = (uint64_t)name;
    register uint64_t r9  __asm__("r9")  = (uint64_t)dest;
    register uint64_t rdi __asm__("rdi") = maxbytes;
    __asm__ volatile ("int $0x80"
                      : "+r"(rax)
                      : "r"(rsi), "r"(r9), "r"(rdi)
                      : "memory");
    return rax;
}

/* Без ліміту, але через ту саму безпечну форму: ядро скопіює рівно
   стільки байт, скільки у файлі. ЗАВЖДИ вказуй ліміт, якщо можеш. */
static inline uint64_t read_file(const char* name, void* dest) {
    return read_file_max(name, dest, 0);
}

/* syscall 13 — список файлів поточної директорії у вигляді
   "NAME    EXT\nNAME    EXT/\n...\0".
   ВИПРАВЛЕНО: тепер передаємо розмір буфера, ядро його не перевищить. */
static inline void get_file_list(char* buf, uint64_t bufsize) {
    _syscall2(13, (uint64_t)buf, bufsize);
}

/* syscall 11 — сирі дані миші одним числом:
     bits[15:0] = X, bits[31:16] = Y, bits[47:32] = click (1=ліва, 2=права) */
static inline uint64_t sys_get_mouse(void) { return _syscall2(11, 0, 0); }

static inline void get_mouse(uint32_t* x, uint32_t* y, uint32_t* click) {
    uint64_t r = sys_get_mouse();
    if (x)     *x     = (uint32_t)( r        & 0xFFFF);
    if (y)     *y     = (uint32_t)((r >> 16) & 0xFFFF);
    if (click) *click = (uint32_t)((r >> 32) & 0xFFFF);
}

/* Розширена версія: додатково віддає прокрутку колеса.
   wheel — знакове число тіків, накопичене з минулого виклику.
   ВАЖЛИВО: syscall 11 ОЧИЩАЄ накопичувач колеса в ядрі, тому
   викликати get_mouse_ex() треба РІВНО РАЗ за кадр — інакше
   частина прокрутки загубиться.
   Знак: додатне = колесо крутять "на себе" (вниз по документу). */
static inline void get_mouse_ex(uint32_t* x, uint32_t* y, uint32_t* click, int* wheel) {
    uint64_t r = sys_get_mouse();
    if (x)     *x     = (uint32_t)( r        & 0xFFFF);
    if (y)     *y     = (uint32_t)((r >> 16) & 0xFFFF);
    if (click) *click = (uint32_t)((r >> 32) & 0xFFFF);
    if (wheel) *wheel = (int)(signed char)((r >> 48) & 0xFF);
}

/* syscall 12 — час RTC: bits[7:0]=хвилини(BCD), bits[15:8]=години(BCD) */
static inline uint64_t sys_get_time(void) { return _syscall2(12, 0, 0); }

/* syscall 14 — записати буфер у файл. Повертає кількість байт, 0 = помилка */
static inline uint64_t write_file(const char* name, const void* buf, uint64_t size) {
    return _syscall3(14, (uint64_t)name, (uint64_t)buf, size);
}

/* ==========================================
 * СПРАВЖНІ ФАЙЛОВІ ДЕСКРИПТОРИ (syscalls 16-20)
 *
 * Раніше open()/read()/lseek() емулювались у libc: файл цілком
 * читався в malloc-буфер, а write() нікуди не потрапляв. Тепер
 * цим займається ядро, і файли реально зберігаються.
 *
 * Обмеження: ядро тримає вміст відкритого файлу в пам'яті
 * (стеля 8 МБ на файл, до 8 файлів одночасно) і скидає його
 * на диск при close(). Якщо close() не викликати - зміни
 * втрачаються.
 * ========================================== */

static inline int sys_open(const char* name, int flags) {
    return (int)(long)_syscall2(16, (uint64_t)name, (uint64_t)flags);
}
static inline long sys_read_fd(int fd, void* buf, uint64_t count) {
    return (long)_syscall3(17, (uint64_t)fd, (uint64_t)buf, count);
}
static inline long sys_write_fd(int fd, const void* buf, uint64_t count) {
    return (long)_syscall3(18, (uint64_t)fd, (uint64_t)buf, count);
}
static inline long sys_lseek_fd(int fd, long offset, int whence) {
    return (long)_syscall3(19, (uint64_t)fd, (uint64_t)offset, (uint64_t)whence);
}
static inline int sys_close_fd(int fd) {
    return (int)(long)_syscall2(20, (uint64_t)fd, 0);
}

/* syscall 21 — аргументи командного рядка (те, що йшло після імені
   програми у 'RUN PROG.BIN arg1 arg2'). Повертає довжину рядка. */
static inline uint64_t get_args(char* buf, uint64_t bufsize) {
    return _syscall2(21, (uint64_t)buf, bufsize);
}

/* ==========================================
 * ОПЕРАЦІЇ НАД ФАЙЛАМИ (syscalls 32-35)
 *
 * Читати й писати вміст файлу програма вміла давно. Це — про сам
 * каталог: видалити, створити, перейменувати, скопіювати. Раніше
 * усе це вміла лише консоль ядра (RM, MKDIR, COPY), тож файловий
 * менеджер оболонки міг ходити по диску, але не змінювати його.
 *
 * Усі працюють у ПОТОЧНОМУ каталозі — імена без шляху, як і в
 * решті системи. Повертають 1 при успіху, 0 при помилці.
 * ========================================== */

/* Видалити файл. Каталог видалити не можна: його вміст лишився б
   у FAT зайнятим назавжди. */
static inline int sys_unlink(const char* name) {
    return (int)(long)_syscall2(32, (uint64_t)name, 0);
}

/* Створити підкаталог. 0, якщо таке ім'я вже зайняте. */
static inline int sys_mkdir(const char* name) {
    return (int)(long)_syscall2(33, (uint64_t)name, 0);
}

/* Перейменувати файл або каталог. 0, якщо джерела немає або нове
   ім'я вже зайняте. Дані нікуди не рухаються — міняється лише
   запис у каталозі. */
static inline int sys_rename(const char* oldname, const char* newname) {
    return (int)(long)_syscall2(34, (uint64_t)oldname, (uint64_t)newname);
}

/* Копія файлу під новим ім'ям. Стеля — 16 МБ (розмір буфера
   завантаження в ядрі). Каталоги не копіюються. */
static inline int sys_copy(const char* srcname, const char* dstname) {
    return (int)(long)_syscall2(35, (uint64_t)srcname, (uint64_t)dstname);
}

/* ==========================================
 * syscall 36 — тип файлу
 *
 * Ядро читає перший сектор і дивиться підпис EUGN. Тільки якщо
 * підпису немає, воно здогадується за розширенням. Оболонка має
 * питати ядро, а не тримати власну таблицю розширень: інакше
 * підпис EUGN для GUI не значив би нічого.
 *
 * RAX: тип у бітах 0-15, ширина в 16-31, висота в 32-47.
 * Ширина й висота заповнені лише для відео та зображення EUGN.
 * ========================================== */
#define FT_UNKNOWN  0
#define FT_PROGRAM  1
#define FT_TEXT     2
#define FT_BITMAP   3
#define FT_SOUND    4
#define FT_VIDEO    5
#define FT_IMAGE    6
#define FT_SYSTEM   7
#define FT_DIR      8

static inline long sys_filetype(const char* name) {
    return (long)_syscall2(36, (uint64_t)name, 0);
}
static inline int ft_kind(long r)   { return (int)(r & 0xFFFF); }
static inline int ft_width(long r)  { return (int)((r >> 16) & 0xFFFF); }
static inline int ft_height(long r) { return (int)((r >> 32) & 0xFFFF); }

/* ==========================================
 * syscall 38 — вміст каталогу з розміром, датою й атрибутами
 *
 * Номер 27 (get_file_list) віддає самі імена одним рядком. Чисел, з
 * яких роблять колонки «розмір» і «змінено», там немає, а дописати їх
 * туди не можна: формат 27 чекають готові бінарники на диску. Тому
 * окремий номер і окремий запис.
 *
 * Ім'я лежить сирими 11 байтами FAT ("HELLO   TXT") — рівно так, як
 * його віддає 27, тому розбирає його той самий код оболонки.
 * ========================================== */
#define FA_READONLY 0x01
#define FA_HIDDEN   0x02
#define FA_SYSTEM   0x04
#define FA_DIR      0x10
#define FA_ARCHIVE  0x20

typedef struct {
    char     name[12];   /* 11 сирих байтів FAT і нуль */
    uint8_t  attr;
    uint8_t  _pad;
    uint16_t date;       /* рік-1980 у бітах 9-15, місяць 5-8, день 0-4 */
    uint16_t time;       /* години 11-15, хвилини 5-10, секунди/2 0-4 */
    uint16_t _pad2;
    uint32_t size;       /* байтів; у каталогу 0 */
    uint32_t cluster;    /* перший кластер */
    uint32_t _pad3;
} FileInfo;

/* Ядро розкладає поля за зміщеннями вручну, тому розмір запису має
   лишатися рівно таким. Якщо зсунеться — тут не збереться. */
typedef char _fileinfo_is_32_bytes[(sizeof(FileInfo) == 32) ? 1 : -1];

/* Заповнює до max записів; повертає, скільки заповнено. */
static inline int sys_dirinfo(FileInfo* out, int max) {
    return (int)(long)_syscall2(38, (uint64_t)out, (uint64_t)max);
}

/* Поля дати й часу FAT у звичайні числа. */
static inline int fat_year(uint16_t d)  { return 1980 + ((d >> 9) & 0x7F); }
static inline int fat_month(uint16_t d) { return (d >> 5) & 0x0F; }
static inline int fat_day(uint16_t d)   { return d & 0x1F; }
static inline int fat_hour(uint16_t t)  { return (t >> 11) & 0x1F; }
static inline int fat_min(uint16_t t)   { return (t >> 5) & 0x3F; }

/* ==========================================
 * syscall 39/40 — відео у вікні
 *
 * Програвач у консолі малює кадр прямо в екран і сам крутить цикл,
 * тому у вікні його не показати. Тут ядро лише розкодовує черговий
 * кадр у наш буфер — формат живе там, де й жив, — а куди й у якому
 * масштабі покласти готовий кадр, вирішує той, хто має вікно.
 *
 * Кадр приходить як 32 біти на піксель, зверху вниз: рівно те, що
 * лежить у GuiBitmap, тож масштабує його звичайний gui_bitmap_fit.
 * ========================================== */

/* Повертає (висота << 16) | ширина, або 0, якщо не вийшло. */
static inline long sys_video_open(const char* name) {
    return (long)_syscall2(39, (uint64_t)name, 0);
}
static inline int vid_width(long r)  { return (int)(r & 0xFFFF); }
static inline int vid_height(long r) { return (int)((r >> 16) & 0xFFFF); }

/* 1 — кадр записано; 0 — потік скінчився або буфер замалий. */
static inline int sys_video_frame(void* dst, uint32_t cap) {
    return (int)(long)_syscall2(40, (uint64_t)dst, (uint64_t)cap);
}

/* ==========================================
 * syscall 41/42/43 — програма у вікні
 *
 * Досі запуск програми означав, що вона забирає екран: `.blit`
 * писав прямо у фреймбуфер, а `syscall 37` присипляв того, хто
 * запустив. Полотно знімає перше, а 41 — друге.
 *
 * Саму програму перезбирати не треба: вона й далі кличе ті самі
 * syscall 9 (blit) і 15 (розмір екрана), просто ядро відповідає на
 * них інакше — розміром полотна замість розміру екрана.
 * ========================================== */
/* Полотно видає ЯДРО, а не ми. Спершу буфер передавала оболонка зі
   своєї купи — і вікно лишалося чорним: PagingCloneSpace робить купу
   власною для кожного адресного простору, тож за однією адресою в
   батька й дитини лежать РІЗНІ фізичні сторінки. Дитина малювала у
   свою копію, а оболонка показувала свою, ніким не писану. */

/* Запустити у вікні й лишитись жити. Повертає адресу полотна
   (32 біти на піксель, крок дорівнює ширині) або 0. */
static inline uint32_t* spawn_windowed(const char* name,
                                       uint32_t w, uint32_t h) {
    return (uint32_t*)_syscall2(41, (uint64_t)name,
                               ((uint64_t)h << 32) | (uint64_t)w);
}

/* Чи жива ще дитина. Поки прохання про запуск не виконане, теж 1. */
static inline int child_alive(void) {
    return (int)(long)_syscall2(42, 0, 0);
}

/* Кому діставатись клавішам: 1 — дитині, 0 — знову нам. Черга одна
   на всіх, тож без цього оболонка й гра крали б клавіші одна в
   одної через одну. Миша лишається в оболонки завжди — саме тому
   клацання по іншому вікну завжди може повернути клавіатуру. */
static inline void keys_to_child(int on) {
    _syscall2(43, (uint64_t)on, 0);
}

/* Скільки разів у полотно вже щось клали. Оболонці треба знати не
   "чи час малювати", а "чи є що малювати": інакше вона перемальовує
   вікно й тоді, коли програма ще вантажиться, і забирає в неї той
   самий час, якого їй бракує. */
static inline uint32_t canvas_seq(void) {
    return (uint32_t)_syscall2(44, 0, 0);
}

/* Віддати решту кванта. Головний цикл оболонки здебільшого не робить
   нічого; крутитись при цьому означає забирати половину процесора в
   того, хто справді працює - програми у вікні. */
static inline void sys_yield(void) { _syscall2(45, 0, 0); }

/* syscall 15 — НОВИЙ: реальний розмір екрана.
   RAX = (height << 32) | width */
static inline uint64_t sys_screen_info(void) { return _syscall2(15, 0, 0); }

static inline void get_screen_size(uint32_t* w, uint32_t* h) {
    uint64_t r = sys_screen_info();
    if (w) *w = (uint32_t)(r & 0xFFFFFFFFULL);
    if (h) *h = (uint32_t)(r >> 32);
}

/* ==========================================
 * КЛАВІАТУРА З МОДИФІКАТОРАМИ
 *
 * Раніше get_key() віддавав сирий скан-код, і кожна програма мала
 * власну таблицю розкладки — лише у верхньому регістрі. Тепер ядро
 * саме перекладає скан-код в ASCII з урахуванням Shift і CapsLock.
 *
 * Формат результату syscall 1:
 *    біти  7..0  ASCII (0 = клавіша без друкованого символу)
 *    біти 15..8  скан-код (стрілки, F-клавіші)
 *    біти 23..16 модифікатори
 * ========================================== */

#define KEY_MOD_SHIFT  1
#define KEY_MOD_CTRL   2
#define KEY_MOD_ALT    4
#define KEY_MOD_CAPS   8

typedef struct {
    uint8_t ascii;      /* готовий символ, 0 якщо недрукований */
    uint8_t scancode;   /* сирий код: стрілки, F1..F12, Esc */
    uint8_t mods;       /* KEY_MOD_* */
} KeyEvent;

/* Повертає 1, якщо клавішу натиснуто, 0 якщо черга порожня. */
static inline int get_key_event(KeyEvent* ev) {
    uint64_t r = _syscall2(26, 0, 0);
    if (r == 0) return 0;
    ev->ascii    = (uint8_t)( r        & 0xFF);
    ev->scancode = (uint8_t)((r >> 8)  & 0xFF);
    ev->mods     = (uint8_t)((r >> 16) & 0xFF);
    return 1;
}

/* ==========================================
 * syscall 23 — хто малює курсор миші
 *
 * За замовчуванням курсор малює ядро, просто у фреймбуфер.
 * Але програма, яка веде власний буфер кадру і виводить його
 * ЧАСТИНАМИ, від цього страждає: ядро запам'ятовує фон під
 * курсором, програма робить свій blit поверх, а ядро потім
 * "відновлює" вже застарілий фон — на екрані лишається слід.
 *
 * Тому GUI-програми забирають курсор собі.
 * ========================================== */
static inline void set_cursor_owner(int app_owns) {
    _syscall2(23, (uint64_t)(app_owns ? 1 : 0), 0);
}

/* ==========================================
 * syscall 28 — запустити іншу програму
 *
 * У ядрі рівно дві задачі, тобто одночасно жива ЛИШЕ ОДНА
 * програма, і всі вони вантажаться за тією самою адресою. Тому
 * «запустити з вікна» — це ланцюжок: ми йдемо, названа програма
 * працює, а коли завершиться, ядро саме поверне нас назад.
 *
 * Виклик лише лишає прохання; піти маємо ми самі, тому одразу
 * після нього робимо sys_exit().
 * ========================================== */
static inline void exec_program(const char* name) {
    _syscall2(28, (uint64_t)name, 0);
    sys_exit();
}

/* ==========================================
 * syscall 37 — запустити програму й ЛИШИТИСЬ ЖИВИМ
 *
 * Відмінність від exec_program принципова. Той був ланцюжком: ми
 * лишали прохання й мусили померти, а ядро запускало названу вже
 * після нас. Саме тому оболонка після виходу гри вантажилась із
 * диска заново — це була не та сама оболонка, а нова.
 *
 * Тут ми лише засинаємо. Слот задачі, адресний простір, стек і купа
 * лишаються на місці; виклик повертається, коли названа програма
 * завершиться, і ми продовжуємо з тим самим станом.
 *
 * Екран після чужої програми зіпсований — той, хто викликав, мусить
 * перемалюватись сам.
 * ========================================== */
static inline void spawn_program(const char* name) {
    _syscall2(37, (uint64_t)name, 0);
}

/* ==========================================
 * syscall 31 — крок рядка фреймбуфера в пікселях
 *
 * Потрібен ЛИШЕ тим програмам, які пишуть у фреймбуфер напряму:
 * його адреса приходить у RDI при старті програми. Специфікація
 * UEFI дозволяє кроку бути більшим за ширину екрана, тому рахувати
 * адресу рядка як y*width — помилка, яка проявиться на залізі.
 *
 * Тим, хто виводить через blit_buffer, крок не потрібен: рядки
 * розкладає ядро.
 * ========================================== */
static inline uint32_t get_screen_stride(void) {
    return (uint32_t)_syscall2(31, 0, 0);
}

/* ==========================================
 * syscall 29/30 — поточний каталог
 *
 * change_dir() приймає ім'я підкаталогу або ".." на рівень вище
 * і повертає 1 при успіху. Після нього get_file_list() віддає
 * список уже нового каталогу — окремо нічого оновлювати не треба.
 *
 * get_cwd() дає шлях рядком, як його показує консоль: "C:\GEMES\".
 * ========================================== */
static inline int change_dir(const char* name) {
    return (int)(long)_syscall2(29, (uint64_t)name, 0);
}

static inline void get_cwd(char* buf, uint64_t size) {
    _syscall2(30, (uint64_t)buf, size);
}

/* ==========================================
 * syscall 22 — швидка заливка прямокутника
 *
 * У GUI це найчастіша операція: фон вікна, заголовок, кнопки.
 * У C це вкладений цикл по пікселях; ядро робить те саме
 * порядковим rep stosd, тобто в рази швидше.
 *
 * Координати обрізаються по краях екрана, тому від'ємні чи
 * завеликі значення безпечні.
 * ========================================== */
typedef struct {
    int32_t x, y, w, h;
    uint32_t color;
} FillRectArgs;

static inline void fill_rect(int x, int y, int w, int h, uint32_t color) {
    FillRectArgs a = { x, y, w, h, color };
    _syscall2(22, (uint64_t)&a, 0);
}

/* Вивід буфера на екран.
 *
 * ДВА НОМЕРИ, І ЦЕ ПРИНЦИПОВО:
 *   syscall 9  — читає рівно перші 5 полів (24 байти) і НЕ дивиться
 *                на stride. Старі бінарники кладуть цю структуру на
 *                стек через `sub rsp,0x18`, тож за нею одразу лежить
 *                збережений RBP. Коли ядро почало читати звідти крок
 *                рядка, воно отримувало адресу стеку як число і йшло
 *                читати за сотні мегабайт від буфера.
 *   syscall 25 — читає всі 6 полів. Саме він потрібен, щоб вивести
 *                ШМАТОК великого буфера (часткове оновлення екрана).
 */
typedef struct {
    uint32_t *buffer;
    uint32_t x, y, w, h;
    uint32_t stride;    /* крок рядка у буфері; 0 = дорівнює w. Лише syscall 25 */
} BlitArgs;

static inline void blit_buffer(uint32_t *buf, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    BlitArgs a = { buf, x, y, w, h, 0 };
    _syscall2(9, (uint64_t)&a, 0);
}

/* Вивести ШМАТОК великого буфера.
 *
 * Без цього неможливе часткове оновлення екрана: ядро брало крок
 * рядка рівним ширині ділянки і читало не ті пікселі. Тепер крок
 * задається окремо — передаємо повну ширину буфера, а w/h описують
 * лише ту частину, яку треба показати. */
static inline void blit_buffer_stride(uint32_t *buf, uint32_t x, uint32_t y,
                                      uint32_t w, uint32_t h, uint32_t stride) {
    BlitArgs a = { buf, x, y, w, h, stride };
    _syscall2(25, (uint64_t)&a, 0);
}

/* ==========================================
 * 4. ПРОТОТИПИ — реалізація в eugene_libc.c
 * ========================================== */

/* Пам'ять */
void  init_heap(void);
void* malloc(size_t size);
void  free(void* ptr);
void* calloc(size_t nitems, size_t size);
void* realloc(void* ptr, size_t size);

/* Рядки */
unsigned long strlen(const char* s);
int           strcmp(const char* s1, const char* s2);
int           strncmp(const char* s1, const char* s2, unsigned long n);
int           strcasecmp(const char* s1, const char* s2);
int           strncasecmp(const char* s1, const char* s2, unsigned long n);
char*         strcpy(char* dest, const char* src);
char*         strncpy(char* dest, const char* src, unsigned long n);
char*         strcat(char* dest, const char* src);
char*         strncat(char* dest, const char* src, unsigned long n);
char*         strchr(const char* s, int c);
char*         strrchr(const char* s, int c);
char*         strstr(const char* haystack, const char* needle);
char*         strdup(const char* s);

/* Пам'ять (mem*) */
void* memcpy(void* dest, const void* src, unsigned long n);
void* memset(void* s, int c, unsigned long n);
void* memmove(void* dest, const void* src, size_t n);
int   memcmp(const void* s1, const void* s2, unsigned long n);

/* Числа / утиліти */
int    atoi(const char* str);
int    abs(int j);
int    isspace(int c);
int    isdigit(int c);
int    isalpha(int c);
int    isalnum(int c);
int    toupper(int c);
int    tolower(int c);

/* Сортування / пошук */
void  qsort(void* base, size_t n, size_t size, int (*cmp)(const void*, const void*));
void* bsearch(const void* key, const void* base, size_t n, size_t size,
              int (*cmp)(const void*, const void*));

/* Форматований вивід */
int printf(const char* format, ...);
int fprintf(FILE* stream, const char* format, ...);
int sprintf(char* str, const char* format, ...);
int snprintf(char* str, size_t size, const char* format, ...);
int vfprintf(FILE* stream, const char* format, void* arg);
int vsnprintf(char* str, size_t size, const char* format, void* args);
int vsprintf(char* str, const char* format, __builtin_va_list args);
int sscanf(const char* str, const char* format, ...);
int fscanf(FILE* stream, const char* format, ...);
int puts(const char* s);
int putchar(int c);
int fflush(FILE* stream);

/* Файловий I/O */
int           open(const char* pathname, int flags, ...);
int           read(int fd, void* buf, unsigned long count);
int           write(int fd, const void* buf, unsigned long count);
long          lseek(int fd, long offset, int whence);
int           close(int fd);
FILE*         fopen(const char* filename, const char* mode);
unsigned long fread(void* ptr, unsigned long size, unsigned long count, FILE* stream);
size_t        fwrite(const void* ptr, size_t size, size_t count, FILE* stream);
int           fseek(FILE* stream, long offset, int origin);
long          ftell(FILE* stream);
int           fclose(FILE* stream);
int           feof(FILE* stream);
int           ferror(FILE* stream);
void          rewind(FILE* stream);
char*         fgets(char* s, int n, FILE* stream);

/* Система */
void  exit(int status);
char* getenv(const char* name);
int   system(const char* command);
int   remove(const char* filename);
int   rename(const char* old, const char* newf);
int   mkdir(const char* pathname, int mode);

#endif /* STDLIB_H */
