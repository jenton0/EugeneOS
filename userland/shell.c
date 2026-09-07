#include "win.h"

/* ============================================================
 * EUGENE OS — ОБОЛОНКА
 *
 * Раніше тут було все одразу: власний шрифт, власний буфер кадру,
 * власне малювання вікон і поведінка трьох додатків, зшита гілками
 * if/else просто в циклі рендеру. Через це кожен новий додаток
 * означав правку рендерера, а libgui з його частковим оновленням
 * екрана лежав окремо і оболонці не діставався.
 *
 * Тепер оболонка не малює вікон і не читає мишу. Вона лише описує
 * чотири процедури вікон і віддає їх віконному менеджеру:
 *
 *    progman_proc   Диспетчер програм — сітка піктограм, запуск
 *    console_proc   Консоль з історією та рядком вводу
 *    editor_proc    Текстовий редактор з меню Файл
 *    files_proc     Файловий менеджер
 *
 * Усе інше — рамки, заголовки, перетягування, зміна розміру,
 * смуги прокрутки, меню, діалоги, фокус — робить libgui.
 * ============================================================ */

/* --- Пункти меню --- */
#define IDM_RUN        101
#define IDM_EXIT       102
#define IDM_CONSOLE    201
#define IDM_EDITOR     202
#define IDM_FILES      203
#define IDM_ARRANGE    204
#define IDM_ABOUT      301
#define IDM_TASKS      205
#define IDM_ED_NEW     401
#define IDM_ED_OPEN    402
#define IDM_ED_SAVE    403
#define IDM_ED_CLOSE   404
#define IDM_ED_CUT     405
#define IDM_ED_COPY    406
#define IDM_ED_PASTE   407
#define IDM_ED_ALL     408
#define IDM_FM_OPEN    501
#define IDM_FM_COPY    502
#define IDM_FM_RENAME  503
#define IDM_FM_DELETE  504
#define IDM_FM_MKDIR   505
#define IDM_FM_RUN     506
#define IDM_FM_UP      507
#define IDM_FM_REFRESH 508
#define IDM_FM_CLOSE   509
#define IDM_FM_PROPS   510

/* --- Елементи керування --- */
#define IDC_LOG        1
#define IDC_CMD        2
#define IDC_TEXT       3
#define IDC_LIST       4
#define IDC_OPEN       5
#define IDC_RUN        6
#define IDC_REFRESH    7
#define IDC_UP         8
#define IDC_TASKS      20
#define IDB_SWITCH     21
#define IDB_END        22

/* Скан-коди літер для синтетичних Ctrl+клавіш з меню */
#define SC_A 0x1E
#define SC_C 0x2E
#define SC_V 0x2F
#define SC_X 0x2D

#define LOG_CAP        8192
#define TEXT_CAP       8192

static Window* g_progman = 0;
static Window* g_console = 0;
static Window* g_editor  = 0;
static Window* g_files   = 0;

/* Вікна відкриваються з кількох місць, тому оголошуємо наперед */
static void open_console(void);
static void open_editor(void);
static void open_files(void);
static void task_list(void);
static void progman_scan(void);
static void progman_title(void);
static void files_refresh(Window* w);
static void open_player(const char* name);
static void ask_and_run(const char* name);
static void frame_sync(void);

/* Запустити програму й повернутися сюди ж.
 *
 * Раніше тут стояв exec_program, після якого оболонка не існувала:
 * ядро вивантажувало її, а після виходу програми вантажило з диска
 * заново. Усі вікна, поточний каталог і виділення при цьому
 * зникали, бо це була вже інша оболонка.
 *
 * Тепер ми просто засинаємо. Стан лишається наш, але екран програма
 * зіпсувала — тому перемальовуємо все. */
static void run_and_return(const char* name) {
    spawn_program(name);
    gui_invalidate_all();
}
static void open_viewer(const char* name);

/* ============================================================
 * ДРІБНИЦІ
 * ============================================================ */

static void num_to_dec(int v, char* buf) {
    if (v == 0) { buf[0] = '0'; buf[1] = 0; return; }
    char tmp[16];
    int i = 0, neg = 0;
    if (v < 0) { neg = 1; v = -v; }
    while (v > 0 && i < 14) { tmp[i++] = (char)('0' + v % 10); v /= 10; }
    if (neg) tmp[i++] = '-';
    int j = 0;
    while (i > 0) buf[j++] = tmp[--i];
    buf[j] = 0;
}

static void sappend(char* dst, int cap, const char* src) {
    int i = 0;
    while (i < cap - 1 && dst[i]) i++;
    while (i < cap - 1 && *src) dst[i++] = *src++;
    dst[i] = 0;
}

/* "NAME    EXT" -> "NAME.EXT"; каталог позначено '/' у кінці */
static void fat_to_name(const char* fat, char* out) {
    int n = 0;
    for (int i = 0; i < 8 && fat[i] && fat[i] != ' '; i++) out[n++] = fat[i];
    if (fat[8] && fat[8] != ' ' && fat[8] != '/') {
        out[n++] = '.';
        for (int i = 8; i < 11 && fat[i] && fat[i] != ' ' && fat[i] != '/'; i++)
            out[n++] = fat[i];
    }
    out[n] = 0;
}

static int name_ends(const char* s, const char* ext) {
    int ls = (int)strlen(s), le = (int)strlen(ext);
    if (ls < le) return 0;
    return strcasecmp(s + ls - le, ext) == 0;
}

/* ============================================================
 * СПИСОК ФАЙЛІВ
 * Ядро віддає його одним рядком: "NAME    EXT\nNAME    EXT/\n..."
 * ============================================================ */

#define MAX_FILES 64
#define FNAME_CAP 20

static char     g_files_raw[MAX_FILES][FNAME_CAP];
static FileInfo g_files_inf[MAX_FILES];
static int      g_files_n = 0;

static void scan_files(void) {
    /* Раніше тут розбирався рядок від syscall 27: імена через '\n'.
       Тепер каталог приходить записами (syscall 38) - разом із
       розміром, датою й атрибутами, з яких і роблять колонки. */
    int n = sys_dirinfo(g_files_inf, MAX_FILES);
    if (n < 0) n = 0;
    if (n > MAX_FILES) n = MAX_FILES;
    g_files_n = n;

    /* g_files_raw лишається таким, яким його бачить решта коду:
       11 сирих байтів імені і слеш у каталогу. Завдяки цьому нічого
       з написаного раніше чіпати не довелося. */
    for (int i = 0; i < n; i++) {
        int j = 0;
        while (j < 11 && g_files_inf[i].name[j]) {
            g_files_raw[i][j] = g_files_inf[i].name[j];
            j++;
        }
        if (g_files_inf[i].attr & FA_DIR) g_files_raw[i][j++] = '/';
        g_files_raw[i][j] = 0;
    }
}

/* "07.09.2026  14:22" з полів FAT. Нуль у даті означає, що запис її
   не несе - так буває у "." і ".." на деяких дисках. */
static void append_stamp(char* dst, int cap, const FileInfo* fi) {
    if (fi->date == 0) { sappend(dst, cap, "-"); return; }
    char n[16];
    num_to_dec(fat_day(fi->date), n);
    if (n[1] == 0) sappend(dst, cap, "0");
    sappend(dst, cap, n);
    sappend(dst, cap, ".");
    num_to_dec(fat_month(fi->date), n);
    if (n[1] == 0) sappend(dst, cap, "0");
    sappend(dst, cap, n);
    sappend(dst, cap, ".");
    num_to_dec(fat_year(fi->date), n);
    sappend(dst, cap, n);
    sappend(dst, cap, "  ");
    num_to_dec(fat_hour(fi->time), n);
    if (n[1] == 0) sappend(dst, cap, "0");
    sappend(dst, cap, n);
    sappend(dst, cap, ":");
    num_to_dec(fat_min(fi->time), n);
    if (n[1] == 0) sappend(dst, cap, "0");
    sappend(dst, cap, n);
}

static int fat_is_dir(const char* fat) {
    for (int i = 0; i < FNAME_CAP && fat[i]; i++)
        if (fat[i] == '/') return 1;
    return 0;
}

/* ============================================================
 * КОНСОЛЬ
 * ============================================================ */

static void log_add(const char* s) {
    if (!g_console) return;
    Window* log = wnd_child_by_id(g_console, IDC_LOG);
    if (!log) return;
    edit_append(log, s);
    edit_append(log, "\n");
}

static void console_exec(const char* cmd) {
    char msg[256];

    if (cmd[0] == 0) return;

    msg[0] = 0;
    sappend(msg, sizeof(msg), "> ");
    sappend(msg, sizeof(msg), cmd);
    log_add(msg);

    if (strcasecmp(cmd, "help") == 0) {
        log_add("HELP  CLS  VER  TIME  LIST  EXIT");
        log_add("CD <dir>     увійти в каталог, CD .. вгору");
        log_add("RUN <file>   запустити програму");
        log_add("ECHO <text>  надрукувати рядок");
    }
    else if (strcasecmp(cmd, "cls") == 0) {
        Window* log = wnd_child_by_id(g_console, IDC_LOG);
        edit_set(log, "");
    }
    else if (strcasecmp(cmd, "ver") == 0) {
        log_add("EUGENE OS — GUI SHELL 2.0");
        log_add("Window manager: libgui (win/ctl/menu)");
    }
    else if (strcasecmp(cmd, "time") == 0) {
        uint64_t t = sys_get_time();
        int hh = (int)((t >> 8) & 0xFF);
        int mm = (int)(t & 0xFF);
        char b[64], n[16];
        b[0] = 0;
        sappend(b, sizeof(b), "TIME ");
        num_to_dec(((hh >> 4) & 0xF) * 10 + (hh & 0xF), n); sappend(b, sizeof(b), n);
        sappend(b, sizeof(b), ":");
        num_to_dec(((mm >> 4) & 0xF) * 10 + (mm & 0xF), n); sappend(b, sizeof(b), n);
        log_add(b);
    }
    else if (strncasecmp(cmd, "cd ", 3) == 0 || strcasecmp(cmd, "cd..") == 0) {
        const char* dir = (cmd[2] == 0x20) ? cmd + 3 : cmd + 2;
        while (*dir == 0x20) dir++;
        if (!change_dir(dir)) {
            log_add("No such directory.");
        } else {
            char p[80];
            p[0] = 0;
            get_cwd(p, sizeof(p));
            log_add(p);
            /* Решта вікон дивиться в той самий каталог */
            if (g_files) files_refresh(g_files);
            progman_scan();
            if (g_progman) {
                wnd_send(g_progman, WM_SIZE, 0, 0);
                wnd_invalidate(g_progman);
            }
        }
    }
    else if (strcasecmp(cmd, "list") == 0) {
        char p[80];
        p[0] = 0;
        get_cwd(p, sizeof(p));
        log_add(p);
        scan_files();
        for (int i = 0; i < g_files_n; i++) {
            char nm[FNAME_CAP];
            fat_to_name(g_files_raw[i], nm);
            if (fat_is_dir(g_files_raw[i])) sappend(nm, sizeof(nm), "  <DIR>");
            log_add(nm);
        }
    }
    else if (strncasecmp(cmd, "echo ", 5) == 0) {
        log_add(cmd + 5);
    }
    else if (strncasecmp(cmd, "run ", 4) == 0) {
        run_and_return(cmd + 4);
    }
    else if (strcasecmp(cmd, "exit") == 0) {
        wm_quit();
    }
    else {
        msg[0] = 0;
        sappend(msg, sizeof(msg), "Unknown command: ");
        sappend(msg, sizeof(msg), cmd);
        log_add(msg);
    }
}

static long console_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_CREATE: {
        int cw, ch;
        wnd_client_size(w, &cw, &ch);
        ctl_edit(w, IDC_LOG, "", 4, 4, cw - 8, ch - 34, ES_MULTILINE, LOG_CAP);
        /* Журнал не бере фокус: Tab і клавіші мають іти в рядок
           вводу, а не в стрічку виводу. Прокрутка колесом і смугою
           працює і без фокуса. */
        Window* log = wnd_child_by_id(w, IDC_LOG);
        if (log) log->focusable = 0;
        ctl_edit(w, IDC_CMD, "", 4, ch - 26, cw - 8, 22, ES_SINGLE, 120);
        return 0;
    }

    case WM_SIZE: {
        Window* log = wnd_child_by_id(w, IDC_LOG);
        Window* cmd = wnd_child_by_id(w, IDC_CMD);
        if (log) wnd_move_child(log, 4, 4, (int)a - 8, (int)b - 34);
        if (cmd) wnd_move_child(cmd, 4, (int)b - 26, (int)a - 8, 22);
        return 0;
    }

    case WM_COMMAND:
        return 0;

    case WM_KEYDOWN:
        /* Enter у рядку вводу доходить сюди: поле віддає батькові
           все, чого не спожило само. */
        if (a == VK_ENTER) {
            Window* cmd = wnd_child_by_id(w, IDC_CMD);
            if (cmd) {
                char line[128];
                const char* s = edit_get(cmd);
                int i = 0;
                while (s[i] && i < 127) { line[i] = s[i]; i++; }
                line[i] = 0;
                edit_set(cmd, "");
                console_exec(line);
            }
            return 0;
        }
        return def_window_proc(w, msg, a, b);

    case WM_CLOSE:
        wnd_destroy(w);
        g_console = 0;
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * РЕДАКТОР
 * ============================================================ */

static char g_ed_file[FNAME_CAP] = "";

static void editor_title(void) {
    if (!g_editor) return;
    char t[64];
    t[0] = 0;
    sappend(t, sizeof(t), "Notepad — ");
    sappend(t, sizeof(t), g_ed_file[0] ? g_ed_file : "(untitled)");
    wnd_set_title(g_editor, t);
}

static void editor_open(const char* name) {
    Window* ed = wnd_child_by_id(g_editor, IDC_TEXT);
    if (!ed) return;
    char* buf = (char*)malloc(TEXT_CAP);
    if (!buf) return;
    buf[0] = 0;
    uint64_t n = read_file_max(name, buf, TEXT_CAP - 1);
    buf[n] = 0;
    edit_set(ed, buf);
    free(buf);

    int i = 0;
    while (name[i] && i < FNAME_CAP - 1) { g_ed_file[i] = name[i]; i++; }
    g_ed_file[i] = 0;
    editor_title();
}

static void editor_save(void) {
    Window* ed = wnd_child_by_id(g_editor, IDC_TEXT);
    if (!ed) return;
    if (!g_ed_file[0]) {
        char nm[FNAME_CAP];
        nm[0] = 0;
        if (!dlg_input("Save As", "File name:", nm, FNAME_CAP)) return;
        int i = 0;
        while (nm[i] && i < FNAME_CAP - 1) { g_ed_file[i] = nm[i]; i++; }
        g_ed_file[i] = 0;
    }
    const char* txt = edit_get(ed);
    uint64_t n = write_file(g_ed_file, txt, strlen(txt));
    if (n == 0) msg_box("Notepad", "Could not write the file.", MB_OK);
    else editor_title();
}

static long editor_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_CREATE: {
        int cw, ch;
        wnd_client_size(w, &cw, &ch);
        ctl_edit(w, IDC_TEXT, "", 2, 2, cw - 4, ch - 4, ES_MULTILINE, TEXT_CAP);
        return 0;
    }

    case WM_SIZE: {
        Window* ed = wnd_child_by_id(w, IDC_TEXT);
        if (ed) wnd_move_child(ed, 2, 2, (int)a - 4, (int)b - 4);
        return 0;
    }

    case WM_COMMAND:
        switch (a) {
        case IDM_ED_NEW: {
            Window* ed = wnd_child_by_id(w, IDC_TEXT);
            edit_set(ed, "");
            g_ed_file[0] = 0;
            editor_title();
            return 0;
        }
        case IDM_ED_OPEN: {
            char nm[FNAME_CAP];
            nm[0] = 0;
            if (dlg_open_file("Open", nm, FNAME_CAP)) {
                char clean[FNAME_CAP];
                fat_to_name(nm, clean);
                editor_open(clean);
            }
            return 0;
        }
        case IDM_ED_SAVE:
            editor_save();
            return 0;
        case IDM_ED_CLOSE:
            wnd_send(w, WM_CLOSE, 0, 0);
            return 0;

        /* Правка віддається самому полю вводу синтетичним Ctrl+клавішею:
           уся логіка виділення й буфера обміну вже там, дублювати її
           в меню означало б розвести дві копії поведінки. */
        case IDM_ED_CUT:   case IDM_ED_COPY:
        case IDM_ED_PASTE: case IDM_ED_ALL: {
            Window* ed = wnd_child_by_id(w, IDC_TEXT);
            if (!ed) return 0;
            wnd_focus(ed);
            int sc = (a == IDM_ED_CUT)   ? SC_X :
                     (a == IDM_ED_COPY)  ? SC_C :
                     (a == IDM_ED_PASTE) ? SC_V : SC_A;
            wnd_send(ed, WM_KEYDOWN, sc, KEY_MOD_CTRL);
            return 0;
        }
        default:
            return 0;
        }

    case WM_CLOSE:
        if (w->menu) { menu_free(w->menu); w->menu = 0; }
        wnd_destroy(w);
        g_editor = 0;
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * ФАЙЛОВИЙ МЕНЕДЖЕР
 * ============================================================ */

/* Заголовок вікна показує, де ми зараз. Шлях бере ядро — той самий,
   що й у промпті консолі. */
static void files_title(Window* w) {
    char path[64];
    path[0] = 0;
    get_cwd(path, sizeof(path));
    char t[96];
    t[0] = 0;
    sappend(t, sizeof(t), "File Manager — ");
    sappend(t, sizeof(t), path[0] ? path : "C:\\");
    wnd_set_title(w, t);
}

static void files_refresh(Window* w) {
    Window* lb = wnd_child_by_id(w, IDC_LIST);
    if (!lb) return;
    scan_files();
    list_clear(lb);
    for (int i = 0; i < g_files_n; i++) {
        char nm[FNAME_CAP];
        fat_to_name(g_files_raw[i], nm);
        if (nm[0] == '.' && nm[1] == 0) continue;   /* "." сенсу не має */

        /* Три колонки: ім'я, розмір, дата зміни. Розділені табулятором,
           а зсуви задає list_set_tabs - шрифт пропорційний, пробілами
           стовпчик не вирівняти. */
        char row[FNAME_CAP + 48];
        row[0] = 0;
        if (fat_is_dir(g_files_raw[i])) {
            /* Каталоги в дужках і зверху не сортуємо — порядок такий,
               як на диску, як і в самій FAT32. */
            sappend(row, sizeof(row), "[");
            sappend(row, sizeof(row), nm);
            sappend(row, sizeof(row), "]\t<DIR>\t");
        } else {
            char sz[16];
            num_to_dec((int)g_files_inf[i].size, sz);
            sappend(row, sizeof(row), nm);
            sappend(row, sizeof(row), "\t");
            sappend(row, sizeof(row), sz);
            sappend(row, sizeof(row), "\t");
        }
        append_stamp(row, sizeof(row), &g_files_inf[i]);
        list_add(lb, row);
    }
    if (list_count(lb) > 0) list_set_sel(lb, 0);
    files_title(w);
}

/* Індекс у списку -> індекс у g_files_raw. Розходяться, бо "." ми
   зі списку викидаємо. */
static int files_raw_index(int sel) {
    int k = 0;
    for (int i = 0; i < g_files_n; i++) {
        char nm[FNAME_CAP];
        fat_to_name(g_files_raw[i], nm);
        if (nm[0] == '.' && nm[1] == 0) continue;
        if (k == sel) return i;
        k++;
    }
    return -1;
}

static void files_activate(Window* w) {
    Window* lb = wnd_child_by_id(w, IDC_LIST);
    if (!lb) return;
    int idx = files_raw_index(list_sel(lb));
    if (idx < 0) return;

    char nm[FNAME_CAP];
    fat_to_name(g_files_raw[idx], nm);

    if (fat_is_dir(g_files_raw[idx])) {
        if (!change_dir(nm)) {
            msg_box("File Manager", "Cannot open that directory.", MB_OK);
            return;
        }
        files_refresh(w);
        /* Диспетчер програм показує вміст того самого каталогу */
        if (g_progman) {
            progman_scan();
            wnd_send(g_progman, WM_SIZE, 0, 0);
            wnd_invalidate(g_progman);
        }
        return;
    }

    /* Тип питаємо в ядра, як і диспетчер програм. Доти тут стояв
       ланцюжок розширень, а все незнайоме йшло в редактор - тобто
       подвійний клік по 22-мегабайтному відео тягнув його в буфер
       редактора на 4 МБ. */
    switch (ft_kind(sys_filetype(nm))) {
    case FT_BITMAP:
    case FT_IMAGE:
        open_viewer(nm);
        return;
    case FT_VIDEO:
        open_player(nm);
        return;
    case FT_PROGRAM:
        ask_and_run(nm);
        return;
    case FT_TEXT:
        break;                      /* нижче - редактор */
    default:
        /* .ASM ядро за розширенням не знає, а редактор його відкриває */
        if (name_ends(nm, ".ASM")) break;
        msg_box("File Manager",
                "No application is associated with this file.", MB_OK);
        return;
    }
    open_editor();
    if (!g_editor) return;
    editor_open(nm);
    wnd_activate(g_editor);
}

/* ============================================================
 * ПЕРЕГЛЯДАЧ ЗОБРАЖЕНЬ
 *
 * Ядро вміє показати .BMP лише на весь екран командою OPEN.
 * Тут картинка живе у звичайному вікні: її можна посунути,
 * змінити розмір і гортати, якщо вона більша за вікно.
 * ============================================================ */

static Window*    g_viewer = 0;
static GuiBitmap* g_view_bmp = 0;

static void viewer_scroll_range(Window* w) {
    GuiRect c;
    wnd_client_rect(w, &c);
    int iw = g_view_bmp ? g_view_bmp->w : 0;
    int ih = g_view_bmp ? g_view_bmp->h : 0;
    /* Одиниця прокрутки тут — піксель, а не рядок тексту */
    wnd_set_scroll(w, 1, w->vs_pos, (ih > c.h) ? ih - c.h : 0, c.h > 0 ? c.h : 1);
    wnd_set_scroll(w, 0, w->hs_pos, (iw > c.w) ? iw - c.w : 0, c.w > 0 ? c.w : 1);
}

static long viewer_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_ERASEBKGND: {
        GuiRect c; wnd_client_rect(w, &c);
        gui_fill_rect(&c, GUI_FACE);
        return 0;
    }

    case WM_PAINT: {
        GuiRect c; wnd_client_rect(w, &c);
        if (!g_view_bmp) {
            gui_text("Could not read the image.", c.x + 8, c.y + 8, GUI_TEXT);
            return 0;
        }
        /* Менша за вікно — центруємо; більша — гортаємо */
        int ox = (g_view_bmp->w < c.w) ? c.x + (c.w - g_view_bmp->w) / 2
                                       : c.x - w->hs_pos;
        int oy = (g_view_bmp->h < c.h) ? c.y + (c.h - g_view_bmp->h) / 2
                                       : c.y - w->vs_pos;
        gui_bitmap(g_view_bmp, ox, oy);
        return 0;
    }

    case WM_SIZE:
        viewer_scroll_range(w);
        return 0;

    case WM_VSCROLL:
        wnd_set_scroll(w, 1, (int)b, w->vs_max, w->vs_page);
        wnd_invalidate(w);
        return 0;

    case WM_HSCROLL:
        wnd_set_scroll(w, 0, (int)b, w->hs_max, w->hs_page);
        wnd_invalidate(w);
        return 0;

    case WM_MOUSEWHEEL: {
        /* За замовчуванням колесо крутить на три одиниці — для
           пікселів це непомітно, тому тут свій крок. */
        int np = w->vs_pos - (int)a * 40;
        if (np < 0) np = 0;
        if (np > w->vs_max) np = w->vs_max;
        if (np != w->vs_pos) {
            wnd_set_scroll(w, 1, np, w->vs_max, w->vs_page);
            wnd_invalidate(w);
        }
        return 0;
    }

    case WM_CLOSE:
        if (g_view_bmp) { bmp_free(g_view_bmp); g_view_bmp = 0; }
        wnd_destroy(w);
        g_viewer = 0;
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

static void open_viewer(const char* name) {
    GuiBitmap* b = bmp_load(name);
    if (!b) {
        char m[80];
        m[0] = 0;
        sappend(m, sizeof(m), "Cannot read ");
        sappend(m, sizeof(m), name);
        sappend(m, sizeof(m), ".\nOnly uncompressed BMP is supported.");
        msg_box("Image Viewer", m, MB_OK);
        return;
    }

    if (g_view_bmp) bmp_free(g_view_bmp);
    g_view_bmp = b;

    char t[80];
    t[0] = 0;
    sappend(t, sizeof(t), "Image — ");
    sappend(t, sizeof(t), name);

    if (!g_viewer) {
        /* Вікно під розмір картинки, але не більше за екран */
        int vw = b->w + 2 * WMET_BORDER + WMET_SB + 8;
        int vh = b->h + 2 * WMET_BORDER + WMET_TITLE + WMET_SB + 8;
        if (vw > gui_width() - 80)  vw = gui_width() - 80;
        if (vh > gui_height() - 80) vh = gui_height() - 80;
        if (vw < 200) vw = 200;
        if (vh < 150) vh = 150;
        g_viewer = wnd_create(t, WS_OVERLAP | WS_VSCROLL | WS_HSCROLL | WS_CLIENTEDGE,
                              70, 60, vw, vh, viewer_proc, 0);
    } else {
        wnd_set_title(g_viewer, t);
    }
    if (!g_viewer) return;

    g_viewer->vs_pos = 0;
    g_viewer->hs_pos = 0;
    viewer_scroll_range(g_viewer);
    wnd_activate(g_viewer);
    wnd_invalidate(g_viewer);
}

/* ============================================================
 * ПРОГРАВАЧ ВІДЕО
 *
 * Ядро розкодовує черговий кадр у наш буфер (syscall 40), а куди й
 * у якому масштабі його покласти - вирішуємо ми. Тому те саме
 * відео, яке з консолі йшло на весь екран і забирало машину собі,
 * тут живе у вікні поруч із рештою.
 *
 * Стан декодера в ядрі один, тому й програвач один: відкрити друге
 * відео означає перезапустити це вікно з новим файлом.
 * ============================================================ */

static Window*  g_player = 0;
static GuiBitmap g_vframe = { 0, 0, 0 };   /* кадр як звичайна картинка */
static int      g_vplaying = 0;
static int      g_vdone = 0;      /* потік дограв до кінця */
static char     g_vname[FNAME_CAP];

static void player_title(void) {
    if (!g_player) return;
    char t[80];
    t[0] = 0;
    sappend(t, sizeof(t), "Video — ");
    sappend(t, sizeof(t), g_vname);
    if (g_vdone)          sappend(t, sizeof(t), "  (finished - Space replays)");
    else if (!g_vplaying) sappend(t, sizeof(t), "  (paused)");
    wnd_set_title(g_player, t);
}

static void player_stop(void) {
    g_vplaying = 0;
    frame_sync();
}

static long player_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_PAINT: {
        GuiRect c; wnd_client_rect(w, &c);
        if (!g_vframe.px || g_vframe.w <= 0 || g_vframe.h <= 0) {
            gui_fill_rect(&c, 0x00000000);
            return 0;
        }

        /* Вписуємо кадр у вікно, зберігаючи пропорції. Більше
           деталей, ніж є у файлі, взяти нізвідки - це збільшення,
           а не різкіша картинка. Множник тут, на відміну від
           повноекранного показу, дробовий: вікно тягнуть за край,
           і цілий множник стрибав би розміром. */
        int dw = c.w, dh = c.h;
        if (dw * g_vframe.h > dh * g_vframe.w) dw = dh * g_vframe.w / g_vframe.h;
        else                                   dh = dw * g_vframe.h / g_vframe.w;
        if (dw < 1) dw = 1;
        if (dh < 1) dh = 1;
        int ox = c.x + (c.w - dw) / 2;
        int oy = c.y + (c.h - dh) / 2;

        /* Поля навколо кадру заливаємо самі, а не через WM_ERASEBKGND
           (вікно створене з WS_NOBKGND). Інакше на кожному з двадцяти
           чотирьох кадрів секунди воно спершу чорніло цілком, а вже
           потім отримувало картинку - тобто блимало. */
        if (oy > c.y)            gui_fill(c.x, c.y, c.w, oy - c.y, 0x00000000);
        if (oy + dh < c.y + c.h) gui_fill(c.x, oy + dh, c.w,
                                          c.y + c.h - oy - dh, 0x00000000);
        if (ox > c.x)            gui_fill(c.x, oy, ox - c.x, dh, 0x00000000);
        if (ox + dw < c.x + c.w) gui_fill(ox + dw, oy, c.x + c.w - ox - dw,
                                          dh, 0x00000000);

        gui_bitmap_fit(&g_vframe, ox, oy, dw, dh);
        return 0;
    }

    case WM_FRAME: {
        if (!g_vplaying || !g_vframe.px) return 0;
        uint32_t cap = (uint32_t)g_vframe.w * (uint32_t)g_vframe.h * 4u;
        if (!sys_video_frame(g_vframe.px, cap)) {
            /* Потік скінчився. Останній кадр лишаємо на екрані:
               порожнє чорне вікно виглядало б як помилка. */
            g_vdone = 1;
            player_stop();
            player_title();
            return 0;
        }
        wnd_invalidate_client(w);
        return 0;
    }

    case WM_KEYDOWN:
        if (a == VK_SPACE) {
            /* Дограло - пробіл починає спочатку, а не знімає паузу
               з потоку, у якому вже нічого немає. */
            if (g_vdone) { open_player(g_vname); return 0; }
            g_vplaying = !g_vplaying;
            frame_sync();
            player_title();
            return 0;
        }
        return def_window_proc(w, msg, a, b);

    case WM_CLOSE:
        player_stop();
        if (g_vframe.px) free(g_vframe.px);
        g_vframe.px = 0;
        g_vframe.w = 0;
        g_vframe.h = 0;
        wnd_destroy(w);
        g_player = 0;
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

static void open_player(const char* name) {
    long r = sys_video_open(name);
    if (!r) {
        char m[112];
        m[0] = 0;
        sappend(m, sizeof(m), "Cannot play ");
        sappend(m, sizeof(m), name);
        sappend(m, sizeof(m), ".\nIt is not a video, or its frame is too large.");
        msg_box("Video", m, MB_OK);
        return;
    }

    int vw = vid_width(r), vh = vid_height(r);
    if (vw <= 0 || vh <= 0) return;

    uint32_t* px = (uint32_t*)malloc((unsigned long)vw * (unsigned long)vh * 4);
    if (!px) {
        msg_box("Video", "Not enough memory for one frame.", MB_OK);
        return;
    }
    for (int i = 0; i < vw * vh; i++) px[i] = 0;

    if (g_vframe.px) free(g_vframe.px);
    g_vframe.px = px;
    g_vframe.w  = vw;
    g_vframe.h  = vh;

    int j = 0;
    while (name[j] && j < FNAME_CAP - 1) { g_vname[j] = name[j]; j++; }
    g_vname[j] = 0;

    if (!g_player) {
        /* Вікно під розмір кадру, але не більше за екран */
        int ww = vw + 2 * WMET_BORDER + 8;
        int wh = vh + 2 * WMET_BORDER + WMET_TITLE + 8;
        if (ww > gui_width() - 60)  ww = gui_width() - 60;
        if (wh > gui_height() - 60) wh = gui_height() - 60;
        if (ww < 200) ww = 200;
        if (wh < 150) wh = 150;
        g_player = wnd_create("Video", WS_OVERLAP | WS_CLIENTEDGE | WS_NOBKGND,
                              100, 70, ww, wh, player_proc, 0);
        if (!g_player) {
            free(px);
            g_vframe.px = 0;
            g_vframe.w = 0;
            g_vframe.h = 0;
            return;
        }
    }

    g_vplaying = 1;
    g_vdone = 0;
    frame_sync();              /* той самий темп, що й у програвача консолі */
    player_title();
    wnd_activate(g_player);
    wnd_invalidate(g_player);
}

/* ============================================================
 * ПРОГРАМА У ВІКНІ
 *
 * Досі запуск програми означав, що вона забирає екран: її blit ішов
 * прямо у фреймбуфер, а оболонка на цей час спала. Тепер ядро вміє
 * видати задачі полотно (syscall 41) і спрямувати весь її вивід
 * туди, а оболонка лишається живою й кладе те полотно у вікно.
 *
 * Гру для цього не перезбирали: DOOM і далі кличе ті самі syscall 9
 * і 15, просто ядро відповідає на них розміром полотна.
 *
 * Вікно одне: ядро вміє сказати лише "дитина жива", і розрізняти
 * кількох дітей йому нічим.
 * ============================================================ */

/* Полотно роблять розміром З ЕКРАН, а не в розмір вікна. Спершу воно
   було 640x400, і гра малювала зі зсувом: DOOM центрує кадр під той
   розмір, який вважає екраном, і все, що не влізло, зрізалось правим
   та нижнім краєм. З полотном на весь екран програма малює точно
   так само, як малювала б на весь екран, а вікно вже масштабує
   готове зображення. */

static Window*   g_app = 0;
static GuiBitmap g_appfb = { 0, 0, 0 };
static char      g_appname[FNAME_CAP];
static uint32_t  g_appseq = 0;   /* останній показаний кадр полотна */
static int       g_app_modal = 0; /* усередині діалогу з цього ж вікна */

/* Кадровий такт спільний на всіх, тому вмикаємо його не наказом,
   а узгодженням: хтось із двох його хоче - він іде. */
static void frame_sync(void) {
    gui_frame_events((g_vplaying || g_app) ? 41 : 0);
}

static void app_title(void) {
    if (!g_app) return;
    char t[80];
    t[0] = 0;
    sappend(t, sizeof(t), g_appname);
    sappend(t, sizeof(t), "  —  Ctrl+Shift+Q to end");
    wnd_set_title(g_app, t);
}

static void app_close(void) {
    if (!g_app) return;
    keys_to_child(0);
    Window* w = g_app;
    g_app = 0;
    /* Полотно ядрове - звільняти нам нічого. */
    g_appfb.px = 0;
    g_appfb.w = 0;
    g_appfb.h = 0;
    frame_sync();
    wnd_destroy(w);
}

static long app_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_PAINT: {
        GuiRect c; wnd_client_rect(w, &c);
        if (!g_appfb.px) { gui_fill_rect(&c, 0x00000000); return 0; }

        int dw = c.w, dh = c.h;
        if (dw * g_appfb.h > dh * g_appfb.w) dw = dh * g_appfb.w / g_appfb.h;
        else                                 dh = dw * g_appfb.h / g_appfb.w;
        if (dw < 1) dw = 1;
        if (dh < 1) dh = 1;
        int ox = c.x + (c.w - dw) / 2;
        int oy = c.y + (c.h - dh) / 2;

        if (oy > c.y)            gui_fill(c.x, c.y, c.w, oy - c.y, 0x00000000);
        if (oy + dh < c.y + c.h) gui_fill(c.x, oy + dh, c.w,
                                          c.y + c.h - oy - dh, 0x00000000);
        if (ox > c.x)            gui_fill(c.x, oy, ox - c.x, dh, 0x00000000);
        if (ox + dw < c.x + c.w) gui_fill(ox + dw, oy, c.x + c.w - ox - dw,
                                          dh, 0x00000000);

        gui_bitmap_fit(&g_appfb, ox, oy, dw, dh);
        return 0;
    }

    case WM_FRAME: {
        /* Полотно програма малює сама й коли захоче. Ми лише
           стежимо, чи вона жива, і перемальовуємо вікно тоді, коли
           там справді з'явився новий кадр. */
        if (!child_alive()) {
            /* Не закриваємо вікно, поки його ж обробник сидить у
               модальному діалозі: dlg_modal крутить той самий цикл
               подій, тобто WM_FRAME туди доходить, і знищення вікна
               висмикнуло б його з-під власного стека. */
            if (!g_app_modal) app_close();
            return 0;
        }
        uint32_t s = canvas_seq();
        if (s != g_appseq) { g_appseq = s; wnd_invalidate_client(w); }
        return 0;
    }

    case WM_ACTIVATE:
        /* Клавіші йдуть тому вікну, яке зараз активне. Миша при
           цьому лишається в оболонки завжди - інакше з гри не було б
           як вийти, не вбиваючи її. */
        keys_to_child(a ? 1 : 0);
        return 0;

    case WM_CLOSE:
        /* Поки програма жива, її полотно - її пам'ять. Звільнити
           буфер під нею означало б, що наступний її кадр ляже в
           чужу купу. Убити задачу оболонка не вміє, тому кажемо
           прямо, чим це робиться. */
        if (child_alive()) {
            g_app_modal = 1;
            msg_box(g_appname,
                    "The program is still running.\n"
                    "Press Ctrl+Shift+Q to end it.", MB_OK);
            g_app_modal = 0;
            return 0;
        }
        app_close();
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

static void open_app_window(const char* name) {
    if (g_app) { wnd_activate(g_app); return; }

    /* Вікна немає, а дитина є - значить, попередня ще працює. Пускати
       другу не можна: обидві читали б диск через ті самі буфери ядра
       й малювали б в одне полотно. Саме так усе й розсипалось, коли
       вікно закривалося передчасно. */
    if (child_alive()) {
        msg_box("Run", "Another program is still running.\n"
                       "Press Ctrl+Shift+Q to end it first.", MB_OK);
        return;
    }

    /* Буфер видає ядро. Брати його з malloc не можна: купа в кожного
       адресного простору своя, тож дитина малювала б у власну копію
       тієї самої адреси, а ми показували б свою - порожню. */
    uint32_t sw = 0, sh = 0;
    get_screen_size(&sw, &sh);
    if (sw == 0 || sh == 0) { sw = 640; sh = 400; }

    uint32_t* px = spawn_windowed(name, sw, sh);
    if (!px) {
        msg_box("Run", "The kernel refused to start it.", MB_OK);
        return;
    }
    for (uint32_t i = 0; i < sw * sh; i++) px[i] = 0;

    g_appfb.px = px;
    g_appfb.w  = (int)sw;
    g_appfb.h  = (int)sh;
    g_appseq   = canvas_seq();   /* рахуємо новим лише те, що буде далі */

    int j = 0;
    while (name[j] && j < FNAME_CAP - 1) { g_appname[j] = name[j]; j++; }
    g_appname[j] = 0;

    /* Вікно - дві третини екрана: полотно однаково масштабується */
    int ww = (int)sw * 2 / 3;
    int wh = (int)sh * 2 / 3;
    if (ww < 240) ww = 240;
    if (wh < 180) wh = 180;
    if (ww > gui_width() - 40)  ww = gui_width() - 40;
    if (wh > gui_height() - 40) wh = gui_height() - 40;
    g_app = wnd_create(name, WS_OVERLAP | WS_CLIENTEDGE | WS_NOBKGND,
                       40, 40, ww, wh, app_proc, 0);
    if (!g_app) {
        g_appfb.px = 0;
        g_appfb.w = 0;
        g_appfb.h = 0;
        return;
    }

    app_title();
    frame_sync();
    wnd_activate(g_app);        /* WM_ACTIVATE сам віддасть клавіші дитині */
    wnd_invalidate(g_app);
}

/* Питання одне на два місця, звідки запускають програму. Вибір тут
   справжній: у вікно вміє лише те, що малює графіку через blit.
   Текстові виклики задачі з полотном ядро просто не виконує, тому
   програма, яка лише друкує, у вікні не покаже нічого. */
static void ask_and_run(const char* name) {
    char q[160];
    q[0] = 0;
    sappend(q, sizeof(q), "Run ");
    sappend(q, sizeof(q), name);
    sappend(q, sizeof(q), "?\n\nYes - in a window (graphics programs only)\n");
    sappend(q, sizeof(q), "No - full screen, the shell waits for it");
    int r = msg_box("Run", q, MB_YESNOCANCEL);
    if (r == IDYES)     open_app_window(name);
    else if (r == IDNO) run_and_return(name);
}

/* Кнопка «вгору» — те саме, що подвійний клік по [..] */
static void files_up(Window* w) {
    if (!change_dir("..")) return;
    files_refresh(w);
    if (g_progman) {
        progman_scan();
        wnd_send(g_progman, WM_SIZE, 0, 0);
        wnd_invalidate(g_progman);
    }
}

/* ============================================================
 * ОПЕРАЦІЇ НАД ФАЙЛАМИ
 *
 * Ядро дає їх системними викликами 32-35 і робить у ПОТОЧНОМУ
 * каталозі: імені зі шляхом не розуміє ні воно, ні решта системи.
 * Звідси дірка, яку видно просто в меню — Copy і Rename є, а Move
 * (F7 у Windows 3.1) немає. Переносити нікуди, поки ім'я не вміє
 * нести в собі каталог.
 * ============================================================ */

/* Ім'я виділеного рядка у звичайному вигляді ("README.TXT").
   Повертає 0, якщо не виділено нічого. */
static int files_selected(Window* w, char* out, int* is_dir) {
    Window* lb = wnd_child_by_id(w, IDC_LIST);
    if (!lb) return 0;
    int idx = files_raw_index(list_sel(lb));
    if (idx < 0) return 0;
    fat_to_name(g_files_raw[idx], out);
    if (is_dir) *is_dir = fat_is_dir(g_files_raw[idx]);
    return 1;
}

/* Після зміни на диску застарілим стає не лише список: диспетчер
   програм показує той самий каталог і мусить перечитати його теж. */
static void files_changed(Window* w) {
    files_refresh(w);
    progman_scan();
    if (g_progman) {
        wnd_send(g_progman, WM_SIZE, 0, 0);
        wnd_invalidate(g_progman);
    }
}

static void files_delete(Window* w) {
    char nm[FNAME_CAP];
    int  dir = 0;
    if (!files_selected(w, nm, &dir)) return;

    if (dir) {
        msg_box("Delete",
                "Directories cannot be deleted.\n"
                "The files inside would stay on the disk forever.",
                MB_OK);
        return;
    }

    char q[96];
    q[0] = 0;
    sappend(q, sizeof(q), "Delete ");
    sappend(q, sizeof(q), nm);
    sappend(q, sizeof(q), "?");
    if (msg_box("Delete", q, MB_YESNO) != IDYES) return;

    if (!sys_unlink(nm)) {
        msg_box("Delete", "The file could not be deleted.", MB_OK);
        return;
    }
    files_changed(w);
}

static void files_copy(Window* w) {
    char nm[FNAME_CAP];
    int  dir = 0;
    if (!files_selected(w, nm, &dir)) return;

    if (dir) {
        msg_box("Copy", "Directories cannot be copied.", MB_OK);
        return;
    }

    char prompt[96];
    prompt[0] = 0;
    sappend(prompt, sizeof(prompt), "Copy ");
    sappend(prompt, sizeof(prompt), nm);
    sappend(prompt, sizeof(prompt), " to:");

    char to[FNAME_CAP];
    to[0] = 0;
    if (!dlg_input("Copy", prompt, to, FNAME_CAP)) return;
    if (to[0] == 0) return;

    if (!sys_copy(nm, to)) {
        msg_box("Copy",
                "The file could not be copied.\n"
                "The name may be taken, or the file is over 16 MB.",
                MB_OK);
        return;
    }
    files_changed(w);
}

static void files_rename(Window* w) {
    char nm[FNAME_CAP];
    if (!files_selected(w, nm, 0)) return;

    /* Старе ім'я лишається в полі: перейменування частіше правка
       на пару літер, ніж нове ім'я з нуля. */
    char to[FNAME_CAP];
    int i = 0;
    while (nm[i] && i < FNAME_CAP - 1) { to[i] = nm[i]; i++; }
    to[i] = 0;

    if (!dlg_input("Rename", "New name:", to, FNAME_CAP)) return;
    if (to[0] == 0) return;

    if (!sys_rename(nm, to)) {
        msg_box("Rename",
                "The name could not be changed.\n"
                "It may already be taken.",
                MB_OK);
        return;
    }
    files_changed(w);
}

static void files_mkdir(Window* w) {
    char nm[FNAME_CAP];
    nm[0] = 0;
    if (!dlg_input("Create Directory", "New directory name:", nm, FNAME_CAP)) return;
    if (nm[0] == 0) return;

    if (!sys_mkdir(nm)) {
        msg_box("Create Directory",
                "The directory could not be created.\n"
                "The name may already be taken.",
                MB_OK);
        return;
    }
    files_changed(w);
}

/* Властивості виділеного файлу.

   Тип питаємо в ядра, а не вгадуємо за іменем: для наших форматів
   воно читає підпис EUGN у заголовку і звідти ж бере розміри кадру.
   Досі ядро рахувало ті розміри намарно - спитати їх не було звідки. */
static void files_props(Window* w) {
    Window* lb = wnd_child_by_id(w, IDC_LIST);
    if (!lb) return;
    int idx = files_raw_index(list_sel(lb));
    if (idx < 0) return;

    char nm[FNAME_CAP];
    fat_to_name(g_files_raw[idx], nm);
    const FileInfo* fi = &g_files_inf[idx];

    static const char* kinds[9] = {
        "Unknown", "Program", "Text", "Bitmap image", "Sound",
        "Video", "Image (EUGN)", "System (EUGN)", "Directory"
    };
    long ft = sys_filetype(nm);
    int  k  = ft_kind(ft);
    if (k < 0 || k > 8) k = 0;

    int dw = 268, dh = 210;
    Window* d = dlg_create("Properties", dw, dh);
    if (!d) return;

    int id = 700, y = 12;
    int lx = 12, vx = 96, vw = dw - 96 - 16;
    char v[64];
    char n[16];

    ctl_static(d, id++, "Name:", lx, y, 80, 12, SS_LEFT);
    ctl_static(d, id++, nm,      vx, y, vw, 12, SS_LEFT);
    y += 18;

    ctl_static(d, id++, "Type:",   lx, y, 80, 12, SS_LEFT);
    ctl_static(d, id++, kinds[k],  vx, y, vw, 12, SS_LEFT);
    y += 18;

    ctl_static(d, id++, "Size:", lx, y, 80, 12, SS_LEFT);
    v[0] = 0;
    if (fi->attr & FA_DIR) {
        sappend(v, sizeof(v), "(directory)");
    } else {
        num_to_dec((int)fi->size, n);
        sappend(v, sizeof(v), n);
        sappend(v, sizeof(v), " bytes");
    }
    ctl_static(d, id++, v, vx, y, vw, 12, SS_LEFT);
    y += 18;

    ctl_static(d, id++, "Modified:", lx, y, 80, 12, SS_LEFT);
    v[0] = 0;
    append_stamp(v, sizeof(v), fi);
    ctl_static(d, id++, v, vx, y, vw, 12, SS_LEFT);
    y += 18;

    /* Розміри кадру несуть лише наші формати; у решти тут нулі */
    if (ft_width(ft) > 0 && ft_height(ft) > 0) {
        ctl_static(d, id++, "Frame:", lx, y, 80, 12, SS_LEFT);
        v[0] = 0;
        num_to_dec(ft_width(ft), n);
        sappend(v, sizeof(v), n);
        sappend(v, sizeof(v), " x ");
        num_to_dec(ft_height(ft), n);
        sappend(v, sizeof(v), n);
        ctl_static(d, id++, v, vx, y, vw, 12, SS_LEFT);
        y += 18;
    }

    ctl_static(d, id++, "Attributes:", lx, y, 80, 12, SS_LEFT);
    v[0] = 0;
    if (fi->attr & FA_READONLY) sappend(v, sizeof(v), "read-only ");
    if (fi->attr & FA_HIDDEN)   sappend(v, sizeof(v), "hidden ");
    if (fi->attr & FA_SYSTEM)   sappend(v, sizeof(v), "system ");
    if (fi->attr & FA_ARCHIVE)  sappend(v, sizeof(v), "archive ");
    if (v[0] == 0) sappend(v, sizeof(v), "none");
    ctl_static(d, id++, v, vx, y, vw, 12, SS_LEFT);
    y += 18;

    ctl_static(d, id++, "Cluster:", lx, y, 80, 12, SS_LEFT);
    num_to_dec((int)fi->cluster, n);
    ctl_static(d, id++, n, vx, y, vw, 12, SS_LEFT);

    ctl_button(d, IDOK, "OK", dw - 94, dh - 62, 74, 24, BS_DEFPUSH);
    dlg_modal(d);
    wnd_destroy(d);
}

static long files_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_CREATE: {
        int cw, ch;
        wnd_client_size(w, &cw, &ch);
        Window* lb = ctl_list(w, IDC_LIST, 6, 6, cw - 12, ch - 44);
        /* Ім'я зліва, розмір притиснутий правим краєм, дата за ним */
        static const int tabs[2] = { -190, 200 };
        list_set_tabs(lb, tabs, 2);
        ctl_button(w, IDC_OPEN,    "&Open",    6,   ch - 32, 62, 24, BS_DEFPUSH);
        ctl_button(w, IDC_UP,      "&Up",      74,  ch - 32, 50, 24, BS_PUSH);
        ctl_button(w, IDC_RUN,     "&Run",     130, ch - 32, 56, 24, BS_PUSH);
        ctl_button(w, IDC_REFRESH, "Re&fresh", 192, ch - 32, 68, 24, BS_PUSH);
        files_title(w);
        return 0;
    }

    case WM_SIZE: {
        Window* lb = wnd_child_by_id(w, IDC_LIST);
        if (lb) wnd_move_child(lb, 6, 6, (int)a - 12, (int)b - 44);
        int ids[4] = { IDC_OPEN, IDC_UP, IDC_RUN, IDC_REFRESH };
        int bw[4]  = { 62, 50, 56, 68 };
        int bx = 6;
        for (int i = 0; i < 4; i++) {
            Window* c = wnd_child_by_id(w, ids[i]);
            if (c) wnd_move_child(c, bx, (int)b - 32, bw[i], 24);
            bx += bw[i] + 6;
        }
        return 0;
    }

    case WM_COMMAND:
        if (a == IDC_LIST && b == LBN_DBLCLK) { files_activate(w); return 0; }

        /* Меню й кнопки приходять одним повідомленням. Номери не
           перетинаються (IDC_* < 100, IDM_FM_* > 500), тому пункти
           меню розбираються першими, до перевірки на BN_CLICKED. */
        switch (a) {
        case IDM_FM_OPEN:    files_activate(w); return 0;
        case IDM_FM_RUN:     files_activate(w); return 0;
        case IDM_FM_COPY:    files_copy(w);     return 0;
        case IDM_FM_RENAME:  files_rename(w);   return 0;
        case IDM_FM_DELETE:  files_delete(w);   return 0;
        case IDM_FM_MKDIR:   files_mkdir(w);    return 0;
        case IDM_FM_PROPS:   files_props(w);    return 0;
        case IDM_FM_UP:      files_up(w);       return 0;
        case IDM_FM_REFRESH: files_refresh(w);  return 0;
        case IDM_FM_CLOSE:   wnd_send(w, WM_CLOSE, 0, 0); return 0;
        default: break;
        }

        if (b != BN_CLICKED) return 0;
        if (a == IDC_REFRESH) { files_refresh(w); return 0; }
        if (a == IDC_UP)      { files_up(w); return 0; }
        if (a == IDC_OPEN || a == IDC_RUN) { files_activate(w); return 0; }
        return 0;

    /* Клавіші Windows 3.1: F8 копіювати, Del видалити, F5 оновити.
       Сюди вони доходять зі списку — він віддає батькові все, чого
       не спожив сам. */
    case WM_KEYDOWN:
        switch (a) {
        case VK_F8:  files_copy(w);    return 0;
        case VK_DEL: files_delete(w);  return 0;
        case VK_F5:  files_refresh(w); return 0;
        case VK_ENTER:
            /* Список віддає нам Enter лише з Alt - без нього він сам
               відкриває виділене. */
            if (b & KEY_MOD_ALT) { files_props(w); return 0; }
            break;
        default: break;
        }
        return def_window_proc(w, msg, a, b);

    case WM_CLOSE:
        if (w->menu) { menu_free(w->menu); w->menu = 0; }
        wnd_destroy(w);
        g_files = 0;
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * ДИСПЕТЧЕР ПРОГРАМ
 *
 * Сітка піктограм, як у Program Manager. Малюємо самі, бо це не
 * список і не таблиця: піктограми розкладаються по рядках і
 * реагують на подвійний клік.
 * ============================================================ */

#define ICON_W 84
#define ICON_H 68

typedef struct {
    char       name[FNAME_CAP];
    int        kind;      /* 0 програма, 1 текст, 2 дані, 3 зображення,
                             4 відео, 5 каталог, 6 системний EUGN */
    GuiBitmap* ico;       /* NAME.BMP поряд, якщо є */
} ProgItem;

static ProgItem g_prog[MAX_FILES];
static int      g_prog_n = 0;
static int      g_prog_sel = -1;

/* "APP.BIN" -> "APP.BMP". Саме так програма отримує власну
   піктограму: поклав поряд файл із тим самим іменем — і він
   з'явився на сітці. Ніякого окремого формату .ICO ми не заводимо. */
static void icon_name_for(const char* prog, char* out, int cap) {
    int n = 0;
    while (prog[n] && prog[n] != '.' && n < cap - 5) { out[n] = prog[n]; n++; }
    out[n++] = '.';
    out[n++] = 'B';
    out[n++] = 'M';
    out[n++] = 'P';
    out[n] = 0;
}

/* Тип питаємо в ядра (syscall 36): воно читає перший сектор і дивиться
   підпис EUGN, і лише за його відсутності гадає за розширенням. Друга
   таблиця розширень тут означала б, що підпис EUGN для GUI не значить
   нічого - саме заради нього він і заводився. */
static int prog_kind_of(const char* nm, int is_dir) {
    if (is_dir) return 5;
    switch (ft_kind(sys_filetype(nm))) {
    case FT_PROGRAM: return 0;
    case FT_TEXT:    return 1;
    case FT_BITMAP:  return 3;
    case FT_IMAGE:   return 3;   /* зображення EUGN: значок той самий */
    case FT_VIDEO:   return 4;
    case FT_SYSTEM:  return 6;
    case FT_DIR:     return 5;
    default:
        /* .ASM ядро за розширенням не знає, а редактор його відкриває */
        return name_ends(nm, ".ASM") ? 1 : 2;
    }
}

static void progman_scan(void) {
    /* Піктограми попереднього каталогу більше не потрібні */
    for (int i = 0; i < g_prog_n; i++) {
        if (g_prog[i].ico) { bmp_free(g_prog[i].ico); g_prog[i].ico = 0; }
    }

    scan_files();
    g_prog_n = 0;
    for (int i = 0; i < g_files_n && g_prog_n < MAX_FILES; i++) {
        char nm[FNAME_CAP];
        fat_to_name(g_files_raw[i], nm);
        if (nm[0] == '.' && nm[1] == 0) continue;   /* "." сенсу не має */

        /* Показуємо все, що лежить на диску. Раніше сітка пускала лише
           п'ять розширень, і решта - каталоги, .EVD, .WAD, файли без
           розширення - для оболонки не існувала. Незнайомий тип тепер
           отримує загальний значок, а не зникає. */
        int kind = prog_kind_of(nm, fat_is_dir(g_files_raw[i]));
        int j = 0;
        while (nm[j] && j < FNAME_CAP - 1) { g_prog[g_prog_n].name[j] = nm[j]; j++; }
        g_prog[g_prog_n].name[j] = 0;
        g_prog[g_prog_n].kind = kind;
        g_prog[g_prog_n].ico  = 0;
        g_prog_n++;
    }

    /* Тепер шукаємо піктограми. Окремим проходом, бо для .BMP
       піктограмою є він сам, а для решти — однойменний файл. */
    for (int i = 0; i < g_prog_n; i++) {
        if (g_prog[i].kind == 5) continue;   /* у каталога значок власний */
        char icon[FNAME_CAP];
        if (g_prog[i].kind == 3) {
            int j = 0;
            while (g_prog[i].name[j] && j < FNAME_CAP - 1) { icon[j] = g_prog[i].name[j]; j++; }
            icon[j] = 0;
        } else {
            icon_name_for(g_prog[i].name, icon, sizeof(icon));
            /* Немає такого файлу — bmp_load просто поверне 0 */
        }
        GuiBitmap* b = bmp_load(icon);
        if (!b) continue;
        /* Величезну картинку тримати в пам'яті заради значка 32x30
           безглуздо: як піктограму беремо лише невелику. */
        if (b->w > 128 || b->h > 128) { bmp_free(b); continue; }
        g_prog[i].ico = b;
    }

    g_prog_sel = -1;

    progman_title();
}

/* Заголовок показує, вміст якого каталогу зараз на сітці. Винесено
   окремо, бо перший progman_scan() відбувається ще до створення
   вікна - тоді заголовок ставити нема кому. */
static void progman_title(void) {
    if (!g_progman) return;
    char path[64];
    path[0] = 0;
    get_cwd(path, sizeof(path));
    char t[96];
    t[0] = 0;
    sappend(t, sizeof(t), "Program Manager — ");
    sappend(t, sizeof(t), path[0] ? path : "C:");
    wnd_set_title(g_progman, t);
}

static void prog_cell(Window* w, int idx, GuiRect* out) {
    GuiRect c; wnd_client_rect(w, &c);
    int cols = c.w / ICON_W;
    if (cols < 1) cols = 1;
    out->x = c.x + (idx % cols) * ICON_W + 4;
    out->y = c.y + (idx / cols) * ICON_H + 4;
    out->w = ICON_W - 8;
    out->h = ICON_H - 8;
}

static void draw_prog_icon(const GuiRect* cell, const ProgItem* it, int sel) {
    int ix = cell->x + (cell->w - 32) / 2;
    int iy = cell->y + 2;

    if (it->ico) {
        /* Справжня піктограма з файлу NAME.BMP. Пурпуровий вважаємо
           прозорим - так робилися панелі інструментів у Windows 3.1. */
        gui_bitmap_fit(it->ico, ix, iy, 32, 30);
    } else if (it->kind == 3) {
        /* Зображення без власної піктограми: рамка з «горами» */
        gui_fill(ix, iy, 32, 30, GUI_WINDOW_BG);
        gui_frame(ix, iy, 32, 30, GUI_DKSHADOW);
        gui_line(ix + 3, iy + 25, ix + 12, iy + 12, GUI_SHADOW);
        gui_line(ix + 12, iy + 12, ix + 20, iy + 22, GUI_SHADOW);
        gui_line(ix + 20, iy + 22, ix + 28, iy + 14, GUI_SHADOW);
        gui_fill(ix + 22, iy + 5, 5, 5, GUI_TEXT_DIM);
    } else if (it->kind == 0) {
        /* Програма: віконце з синім заголовком */
        gui_fill(ix, iy, 32, 30, GUI_FACE);
        gui_bevel2(ix, iy, 32, 30, 1);
        gui_fill(ix + 3, iy + 3, 26, 5, GUI_TITLE_ACT);
        gui_fill(ix + 3, iy + 10, 26, 16, GUI_WINDOW_BG);
        gui_hline(ix + 6, iy + 14, 20, GUI_SHADOW);
        gui_hline(ix + 6, iy + 18, 20, GUI_SHADOW);
        gui_hline(ix + 6, iy + 22, 14, GUI_SHADOW);
    } else if (it->kind == 5) {
        /* Каталог: тека з язичком */
        gui_fill(ix + 2, iy + 2, 13, 6, GUI_FACE);
        gui_bevel2(ix + 2, iy + 2, 13, 6, 1);
        gui_fill(ix + 2, iy + 6, 28, 21, GUI_FACE);
        gui_bevel2(ix + 2, iy + 6, 28, 21, 1);
        gui_hline(ix + 5, iy + 11, 22, GUI_SHADOW);
    } else if (it->kind == 4) {
        /* Відео: кадр кіноплівки з перфорацією */
        gui_fill(ix + 2, iy + 3, 28, 24, GUI_DKSHADOW);
        for (int k = 0; k < 4; k++) {
            gui_fill(ix + 4,  iy + 6 + k * 5, 3, 3, GUI_WINDOW_BG);
            gui_fill(ix + 25, iy + 6 + k * 5, 3, 3, GUI_WINDOW_BG);
        }
        gui_fill(ix + 10, iy + 7, 12, 16, GUI_WINDOW_BG);
        for (int k = 0; k < 7; k++)
            gui_hline(ix + 13, iy + 8 + k, 1 + k, GUI_TITLE_ACT);
        for (int k = 0; k < 7; k++)
            gui_hline(ix + 13, iy + 15 + k, 7 - k, GUI_TITLE_ACT);
    } else if (it->kind == 6) {
        /* Системний файл EUGN: аркуш із печаткою */
        gui_fill(ix + 4, iy, 24, 30, GUI_WINDOW_BG);
        gui_frame(ix + 4, iy, 24, 30, GUI_DKSHADOW);
        gui_hline(ix + 8, iy + 5, 16, GUI_SHADOW);
        gui_hline(ix + 8, iy + 8, 16, GUI_SHADOW);
        for (int k = 0; k < 6; k++)
            gui_hline(ix + 16 - k, iy + 13 + k, 1 + k * 2, GUI_TITLE_ACT);
        for (int k = 0; k < 6; k++)
            gui_hline(ix + 11 + k, iy + 19 + k, 11 - k * 2, GUI_TITLE_ACT);
    } else {
        /* Документ: аркуш із загнутим кутом. Рядки тексту малюємо лише
           знайомому типу — незнайомий лишається майже порожнім. */
        gui_fill(ix + 4, iy, 24, 30, GUI_WINDOW_BG);
        gui_frame(ix + 4, iy, 24, 30, GUI_DKSHADOW);
        gui_fill(ix + 20, iy, 8, 8, GUI_FACE);
        gui_line(ix + 20, iy, ix + 27, iy + 7, GUI_DKSHADOW);
        int rows = (it->kind == 1) ? 5 : 2;
        for (int k = 0; k < rows; k++)
            gui_hline(ix + 8, iy + 12 + k * 3, 16, GUI_SHADOW);
    }

    /* Каталог підписуємо в дужках — так само, як у File Manager */
    char label[FNAME_CAP + 2];
    label[0] = 0;
    if (it->kind == 5) {
        sappend(label, sizeof(label), "[");
        sappend(label, sizeof(label), it->name);
        sappend(label, sizeof(label), "]");
    } else {
        sappend(label, sizeof(label), it->name);
    }

    int tw = gui_text_w(label);
    int tx = cell->x + (cell->w - tw) / 2;
    int ty = cell->y + 36;
    if (sel) {
        gui_fill(tx - 2, ty - 1, tw + 4, GUI_FONT_H + 3, GUI_SELECT);
        gui_text_clip(label, tx, ty, cell->x + cell->w + 6, GUI_SELECT_TEXT);
        gui_focus_rect(tx - 2, ty - 1, tw + 4, GUI_FONT_H + 3);
    } else {
        gui_text_clip(label, tx, ty, cell->x + cell->w + 6, GUI_TEXT);
    }
}

static int prog_hit(Window* w, int cx, int cy) {
    GuiRect c; wnd_client_rect(w, &c);
    int cols = c.w / ICON_W;
    if (cols < 1) cols = 1;
    int col = cx / ICON_W;
    int row = (cy + w->vs_pos * ICON_H) / ICON_H;
    if (col < 0 || col >= cols) return -1;
    int idx = row * cols + col;
    if (idx < 0 || idx >= g_prog_n) return -1;
    return idx;
}

static void prog_launch(Window* w, int idx) {
    if (idx < 0 || idx >= g_prog_n) return;
    ProgItem* it = &g_prog[idx];

    if (it->kind == 5) {
        /* Каталог відкривається просто в сітці, а File Manager переходить
           слідом: поточний каталог у них спільний, він один на процес. */
        if (!change_dir(it->name)) {
            msg_box("Program Manager", "Cannot open that directory.", MB_OK);
            return;
        }
        progman_scan();
        if (w) { wnd_send(w, WM_SIZE, 0, 0); wnd_invalidate(w); }
        if (g_files) files_refresh(g_files);
        return;
    }
    if (it->kind == 3) { open_viewer(it->name); return; }
    if (it->kind == 0) { ask_and_run(it->name); return; }
    if (it->kind == 4) { open_player(it->name); return; }
    if (it->kind != 1) {
        /* Тип видно на сітці, але відкрити його нічим. Кажемо про це
           прямо, а не тягнемо двійковий файл у текстовий редактор. */
        msg_box("Program Manager",
                "No application is associated with this file.", MB_OK);
        return;
    }
    open_editor();
    if (g_editor) {
        editor_open(it->name);
        wnd_activate(g_editor);
    }
}

static long progman_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_ERASEBKGND: {
        GuiRect c; wnd_client_rect(w, &c);
        gui_fill_rect(&c, GUI_FACE);
        return 0;
    }

    case WM_PAINT: {
        GuiRect c; wnd_client_rect(w, &c);
        int cols = c.w / ICON_W;
        if (cols < 1) cols = 1;
        for (int i = 0; i < g_prog_n; i++) {
            GuiRect cell;
            prog_cell(w, i, &cell);
            cell.y -= w->vs_pos * ICON_H;
            if (cell.y + cell.h < c.y || cell.y > c.y + c.h) continue;
            draw_prog_icon(&cell, &g_prog[i], i == g_prog_sel);
        }
        return 0;
    }

    case WM_SIZE: {
        GuiRect c; wnd_client_rect(w, &c);
        int cols = c.w / ICON_W;
        if (cols < 1) cols = 1;
        int rows = (g_prog_n + cols - 1) / cols;
        int page = c.h / ICON_H;
        if (page < 1) page = 1;
        wnd_set_scroll(w, 1, w->vs_pos, (rows > page) ? rows - page : 0, page);
        return 0;
    }

    case WM_LBUTTONDOWN: {
        int idx = prog_hit(w, (int)a, (int)b);
        if (idx != g_prog_sel) { g_prog_sel = idx; wnd_invalidate_client(w); }
        return 0;
    }

    case WM_LBUTTONDBLCLK: {
        int idx = prog_hit(w, (int)a, (int)b);
        if (idx >= 0) { g_prog_sel = idx; prog_launch(w, idx); }
        return 0;
    }

    case WM_KEYDOWN:
        if (a == VK_ENTER && g_prog_sel >= 0) { prog_launch(w, g_prog_sel); return 0; }
        if (a == VK_LEFT  && g_prog_sel > 0) { g_prog_sel--; wnd_invalidate_client(w); return 0; }
        if (a == VK_RIGHT && g_prog_sel < g_prog_n - 1) { g_prog_sel++; wnd_invalidate_client(w); return 0; }
        return def_window_proc(w, msg, a, b);

    case WM_VSCROLL:
        wnd_set_scroll(w, 1, (int)b, w->vs_max, w->vs_page);
        wnd_invalidate(w);
        return 0;

    case WM_COMMAND:
        switch (a) {
        case IDM_RUN: {
            char nm[FNAME_CAP];
            nm[0] = 0;
            if (dlg_input("Run", "Program name:", nm, FNAME_CAP) && nm[0])
                run_and_return(nm);
            return 0;
        }
        case IDM_EXIT:
            wnd_send(w, WM_CLOSE, 0, 0);
            return 0;
        case IDM_CONSOLE: open_console(); return 0;
        case IDM_EDITOR:  open_editor();  return 0;
        case IDM_FILES:   open_files();   return 0;
        case IDM_TASKS:   task_list();    return 0;
        case IDM_ARRANGE:
            progman_scan();
            wnd_send(w, WM_SIZE, 0, 0);
            wnd_invalidate(w);
            return 0;
        case IDM_ABOUT:
            msg_box("About Eugene OS",
                    "Eugene OS — GUI Shell 2.0\n"
                    "Window manager: libgui\n"
                    "Windows, menus, dialogs, controls.",
                    MB_OK);
            return 0;
        default:
            return 0;
        }

    case WM_CLOSE:
        if (msg_box("Program Manager",
                    "Quit to the text console?", MB_OKCANCEL) == IDOK)
            wm_quit();
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * ВІДКРИТТЯ ВІКОН
 * ============================================================ */

static void open_console(void) {
    if (g_console) { wnd_activate(g_console); return; }
    int sw = gui_width(), sh = gui_height();
    int cw = sw * 46 / 100; if (cw < 340) cw = 340;
    int ch = sh * 52 / 100; if (ch < 240) ch = 240;
    int cx = sw - cw - 24; if (cx < 24) cx = 24;
    int cy = sh - ch - 40; if (cy < 40) cy = 40;
    g_console = wnd_create("Console", WS_OVERLAP | WS_CLIENTEDGE,
                           cx, cy, cw, ch, console_proc, 0);
    if (g_console) {
        log_add("EUGENE OS console. Type HELP.");
        wnd_activate(g_console);
    }
}

static void open_editor(void) {
    if (g_editor) { wnd_activate(g_editor); return; }
    g_editor = wnd_create("Notepad — (untitled)", WS_OVERLAP,
                          140, 120, 440, 300, editor_proc, 0);
    if (!g_editor) return;

    Menu* file = menu_create();
    menu_add(file, IDM_ED_NEW,  "&New", 0);
    menu_add(file, IDM_ED_OPEN, "&Open...", 0);
    menu_add(file, IDM_ED_SAVE, "&Save", 0);
    menu_sep(file);
    menu_add(file, IDM_ED_CLOSE, "&Close", 0);

    Menu* edit = menu_create();
    menu_add(edit, IDM_ED_CUT,   "Cu&t	Ctrl+X", 0);
    menu_add(edit, IDM_ED_COPY,  "&Copy	Ctrl+C", 0);
    menu_add(edit, IDM_ED_PASTE, "&Paste	Ctrl+V", 0);
    menu_sep(edit);
    menu_add(edit, IDM_ED_ALL,   "Select &All	Ctrl+A", 0);

    Menu* bar = menu_create();
    menu_add_sub(bar, "&File", file);
    menu_add_sub(bar, "&Edit", edit);
    wnd_set_menu(g_editor, bar);

    /* Меню з'їдає частину висоти — елементи треба перекласти */
    int cw, ch;
    wnd_client_size(g_editor, &cw, &ch);
    wnd_send(g_editor, WM_SIZE, cw, ch);
    wnd_activate(g_editor);
}
static void open_files(void) {
    if (g_files) { wnd_activate(g_files); return; }
    g_files = wnd_create("File Manager", WS_OVERLAP,
                         320, 180, 420, 320, files_proc, 0);
    if (!g_files) return;

    /* Порядок пунктів і клавіші — як у File Manager із Windows 3.1.
       Move (F7) там теж є, у нас його немає: ядро розуміє тільки
       ім'я без шляху, тож переносити файл нікуди. */
    Menu* file = menu_create();
    menu_add(file, IDM_FM_OPEN,   "&Open\tEnter", 0);
    menu_add(file, IDM_FM_RUN,    "&Run", 0);
    menu_sep(file);
    menu_add(file, IDM_FM_COPY,   "&Copy...\tF8", 0);
    menu_add(file, IDM_FM_RENAME, "Re&name...", 0);
    menu_add(file, IDM_FM_DELETE, "&Delete\tDel", 0);
    menu_sep(file);
    menu_add(file, IDM_FM_MKDIR,  "Create &Directory...", 0);
    menu_sep(file);
    menu_add(file, IDM_FM_PROPS,  "P&roperties...\tAlt+Enter", 0);
    menu_sep(file);
    menu_add(file, IDM_FM_CLOSE,  "C&lose", 0);

    Menu* view = menu_create();
    menu_add(view, IDM_FM_UP,      "&Up One Level", 0);
    menu_add(view, IDM_FM_REFRESH, "&Refresh\tF5", 0);

    Menu* bar = menu_create();
    menu_add_sub(bar, "&File", file);
    menu_add_sub(bar, "&View", view);
    wnd_set_menu(g_files, bar);

    /* Меню з'їдає частину висоти — список і кнопки треба перекласти */
    int cw, ch;
    wnd_client_size(g_files, &cw, &ch);
    wnd_send(g_files, WM_SIZE, cw, ch);

    files_refresh(g_files);
    wnd_activate(g_files);
}

/* ============================================================
 * РОБОЧИЙ СТІЛ
 * ============================================================ */

/* ============================================================
 * СПИСОК ЗАДАЧ
 *
 * У Windows 3.1 його відкривав подвійний клік по робочому столу.
 * Тут він потрібен навіть більше: вікна можуть повністю накрити
 * одне одного, а панелі завдань немає — це вже Win 95.
 * ============================================================ */

static Window* g_task_win[16];
static int     g_task_n = 0;

static long tasklist_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_COMMAND:
        if (a == IDC_TASKS && b == LBN_DBLCLK) { dlg_end(w, IDB_SWITCH); return 0; }
        if (b == BN_CLICKED) { dlg_end(w, (int)a); return 0; }
        return 0;
    case WM_KEYDOWN:
        if (a == VK_ESC) { dlg_end(w, IDCANCEL); return 0; }
        return def_window_proc(w, msg, a, b);
    case WM_CLOSE:
        dlg_end(w, IDCANCEL);
        return 0;
    default:
        return def_window_proc(w, msg, a, b);
    }
}

static void task_list(void) {
    int dw = 270, dh = 250;
    int x = (gui_width() - dw) / 2;
    int y = (gui_height() - dh) / 3;
    Window* d = wnd_create("Task List", WS_DIALOG, x, y, dw, dh, tasklist_proc, 0);
    if (!d) return;
    d->min_w = 120; d->min_h = 90;

    Window* lb = ctl_list(d, IDC_TASKS, 10, 8, dw - 30, 152);
    ctl_button(d, IDB_SWITCH, "&Switch To", 10,  dh - 62, 78, 24, BS_DEFPUSH);
    ctl_button(d, IDB_END,    "&End Task",  94,  dh - 62, 78, 24, BS_PUSH);
    ctl_button(d, IDCANCEL,   "Cancel",     178, dh - 62, 62, 24, BS_PUSH);

    g_task_n = 0;
    int n = wnd_top_count();
    for (int i = 0; i < n && g_task_n < 16; i++) {
        Window* t = wnd_top_at(i);
        if (!t || t == d || !t->visible) continue;
        char line[64];
        line[0] = 0;
        sappend(line, sizeof(line), t->title[0] ? t->title : "(untitled)");
        if (t->minimized) sappend(line, sizeof(line), "   (icon)");
        list_add(lb, line);
        g_task_win[g_task_n++] = t;
    }
    if (list_count(lb) > 0) list_set_sel(lb, 0);

    int res = dlg_modal(d);
    int sel = list_sel(lb);          /* читаємо ДО знищення вікна */
    Window* target = (sel >= 0 && sel < g_task_n) ? g_task_win[sel] : 0;
    wnd_destroy(d);

    if (!target || !target->used) return;
    if (res == IDB_SWITCH) {
        if (target->minimized) wnd_minimize(target, 0);
        else                   wnd_activate(target);
    } else if (res == IDB_END) {
        wnd_send(target, WM_CLOSE, 0, 0);
    }
}

static long desktop_proc(Window* w, int msg, long a, long b) {
    (void)w; (void)a; (void)b;
    if (msg == WM_PAINT) {
        /* Сіре решето поверх бірюзи — саме так виглядав стандартний
           робочий стіл Windows 3.1. */
        GuiRect c;
        gui_clip_get(&c);
        gui_dither(c.x, c.y, c.w, c.h, GUI_DESKTOP, 0x00006A6A);
    }
    else if (msg == WM_LBUTTONDBLCLK) {
        task_list();
    }
    return 0;
}

/* ============================================================
 * ТОЧКА ВХОДУ
 * ============================================================ */

void gui_main(void) {
    clear_screen();
    init_heap();

    if (!wm_init()) {
        print("\nFATAL: NOT ENOUGH MEMORY FOR THE FRAME BUFFER\n", 0x00FF0000);
        sys_exit();
    }

    wm_set_desktop_proc(desktop_proc);
    progman_scan();

    int sw = gui_width(), sh = gui_height();

    /* Диспетчер займає ліву половину, консоль - праву нижню.
       Раніше він розтягувався майже на весь екран і повністю
       накривав консоль, через що здавалося, що її немає. */
    int pw = sw * 45 / 100; if (pw < 360) pw = 360;
    int ph = sh * 62 / 100; if (ph < 300) ph = 300;

    g_progman = wnd_create("Program Manager",
                           WS_BORDER | WS_TITLE | WS_SYSMENU | WS_MINBOX |
                           WS_MAXBOX | WS_SIZEBOX | WS_VSCROLL,
                           16, 16, pw, ph, progman_proc, 0);

    if (g_progman) {
        Menu* file = menu_create();
        menu_add(file, IDM_RUN,  "&Run...", 0);
        menu_sep(file);
        menu_add(file, IDM_EXIT, "E&xit Windows", 0);

        Menu* win = menu_create();
        menu_add(win, IDM_CONSOLE, "&Console", 0);
        menu_add(win, IDM_EDITOR,  "&Notepad", 0);
        menu_add(win, IDM_FILES,   "&File Manager", 0);
        menu_sep(win);
        menu_add(win, IDM_ARRANGE, "&Refresh Icons", 0);
        menu_sep(win);
        menu_add(win, IDM_TASKS,   "&Task List...	dbl-click desktop", 0);

        Menu* help = menu_create();
        menu_add(help, IDM_ABOUT, "&About...", 0);

        Menu* bar = menu_create();
        menu_add_sub(bar, "&File", file);
        menu_add_sub(bar, "&Window", win);
        menu_add_sub(bar, "&Help", help);
        wnd_set_menu(g_progman, bar);

        int cw, ch;
        wnd_client_size(g_progman, &cw, &ch);
        wnd_send(g_progman, WM_SIZE, cw, ch);
        progman_title();
    }

    open_console();
    if (g_progman) wnd_activate(g_progman);

    wm_run();

    clear_screen();
    sys_exit();
}
