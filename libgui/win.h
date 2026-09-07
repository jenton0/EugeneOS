#ifndef WIN_H
#define WIN_H

#include "gui.h"

/* ============================================================
 * EUGENE GUI — ВЕРХНІЙ ШАР (аналог USER)
 *
 * Тут вікно нарешті стає ОБ'ЄКТОМ: у нього є власна процедура,
 * яка отримує повідомлення, а все, що вона не обробила, падає
 * у def_window_proc. Саме з цієї єдиної конструкції у Windows 3.1
 * виростало все решта — елементи керування (вони теж вікна),
 * меню, діалоги, фокус, захоплення миші.
 *
 * Раніше в оболонці поведінка вікна була гілкою if/else всередині
 * циклу рендеру, тому кожен новий додаток вимагав правити рендерер.
 * Тепер новий додаток — це одна функція.
 * ============================================================ */

typedef struct Window Window;
typedef struct Menu   Menu;

/* Повертає результат обробки; що не обробили — віддаємо у def_window_proc */
typedef long (*WndProc)(Window* w, int msg, long a, long b);

/* ==========================================================
 * ПОВІДОМЛЕННЯ
 * ========================================================== */
#define WM_CREATE         1
#define WM_DESTROY        2
#define WM_PAINT          3    /* обрізання вже виставлено по робочій області */
#define WM_ERASEBKGND     4
#define WM_NCPAINT        5    /* рамка, заголовок, кнопки */
#define WM_SIZE           6    /* a=w b=h робочої області */
#define WM_MOVE           7
#define WM_MOUSEMOVE      8    /* a=x b=y у координатах робочої області */
#define WM_LBUTTONDOWN    9
#define WM_LBUTTONUP     10
#define WM_LBUTTONDBLCLK 11
#define WM_RBUTTONDOWN   12
#define WM_RBUTTONUP     13
#define WM_MOUSEWHEEL    14    /* a=тіки (знакове) */
#define WM_KEYDOWN       15    /* a=скан-код b=модифікатори */
#define WM_CHAR          16    /* a=ascii b=модифікатори */
#define WM_SETFOCUS      17
#define WM_KILLFOCUS     18
#define WM_ACTIVATE      19    /* a=1 активоване, 0 деактивоване */
#define WM_COMMAND       20    /* a=id елемента b=код сповіщення */
#define WM_TIMER         21
#define WM_CLOSE         22
#define WM_VSCROLL       23    /* a=дія b=нова позиція */
#define WM_HSCROLL       24
#define WM_SETCURSOR     25    /* повернути GUI_CUR_*, або -1 = за замовчуванням */
#define WM_INITDIALOG    26
#define WM_FRAME         27    /* кадровий такт; див. gui_frame_events */
#define WM_USER         100

/* ==========================================================
 * СКАН-КОДИ, які приходять у WM_KEYDOWN
 * ========================================================== */
#define VK_ESC     0x01
#define VK_BKSP    0x0E
#define VK_TAB     0x0F
#define VK_ENTER   0x1C
#define VK_SPACE   0x39
#define VK_HOME    0x47
#define VK_UP      0x48
#define VK_PGUP    0x49
#define VK_LEFT    0x4B
#define VK_RIGHT   0x4D
#define VK_END     0x4F
#define VK_DOWN    0x50
#define VK_PGDN    0x51
#define VK_DEL     0x53
#define VK_F1      0x3B
#define VK_F5      0x3F
#define VK_F7      0x41
#define VK_F8      0x42
#define VK_F10     0x44

/* Коди сповіщень у WM_COMMAND */
#define BN_CLICKED        0
#define EN_CHANGE         1
#define LBN_SELCHANGE     2
#define LBN_DBLCLK        3
#define MN_SELECT         4     /* вибрано пункт меню */

/* Дії прокрутки */
#define SB_LINEUP         1
#define SB_LINEDOWN       2
#define SB_PAGEUP         3
#define SB_PAGEDOWN       4
#define SB_THUMB          5

/* ==========================================================
 * СТИЛІ ВІКНА
 * ========================================================== */
#define WS_BORDER      0x00000001
#define WS_TITLE       0x00000002
#define WS_SYSMENU     0x00000004
#define WS_MINBOX      0x00000008
#define WS_MAXBOX      0x00000010
#define WS_SIZEBOX     0x00000020
#define WS_VSCROLL     0x00000040
#define WS_HSCROLL     0x00000080
#define WS_CHILD       0x00000100
#define WS_DISABLED    0x00000200
#define WS_CLIENTEDGE  0x00000400   /* втиснута рамка робочої області */
#define WS_POPUP       0x00000800   /* меню, підказки: без активації */
#define WS_NOBKGND     0x00001000   /* тло малює сам додаток */

#define WS_OVERLAP  (WS_BORDER|WS_TITLE|WS_SYSMENU|WS_MINBOX|WS_MAXBOX|WS_SIZEBOX)
#define WS_DIALOG   (WS_BORDER|WS_TITLE|WS_SYSMENU)

/* Стилі елементів керування (поле ctl_style) */
#define BS_PUSH        0
#define BS_DEFPUSH     1
#define BS_CHECK       2
#define BS_RADIO       3
#define BS_GROUP       4

#define SS_LEFT        0
#define SS_CENTER      1
#define SS_RIGHT       2
#define SS_FRAME       3

#define ES_SINGLE      0
#define ES_MULTILINE   1
#define ES_READONLY    2

/* ==========================================================
 * РОЗМІРИ ЕЛЕМЕНТІВ ОФОРМЛЕННЯ
 * ========================================================== */
#define WMET_BORDER    4    /* товщина рамки, вона ж зона зміни розміру */
#define WMET_TITLE     18
#define WMET_MENU      18
#define WMET_SB        15   /* ширина смуги прокрутки */
#define WMET_BTN       14   /* кнопки заголовка */

/* ==========================================================
 * ЗОНИ ВІКНА (результат перевірки влучання)
 * ========================================================== */
enum {
    HT_NONE = 0, HT_CLIENT, HT_CAPTION, HT_SYSMENU, HT_MIN, HT_MAX, HT_CLOSE,
    HT_LEFT, HT_RIGHT, HT_TOP, HT_BOTTOM,
    HT_TOPLEFT, HT_TOPRIGHT, HT_BOTLEFT, HT_BOTRIGHT,
    HT_VSCROLL, HT_HSCROLL, HT_MENU
};

/* ==========================================================
 * ВІКНО
 * ========================================================== */
struct Window {
    int       used;
    GuiRect   r;              /* повний кадр вікна в координатах екрана */
    GuiRect   restore;        /* геометрія до максимізації */
    char      title[48];
    unsigned  style;
    int       ctl_style;
    int       visible;
    int       minimized;
    int       maximized;
    int       id;             /* ідентифікатор елемента для WM_COMMAND */
    WndProc   proc;
    void*     data;           /* довільні дані додатка */
    Window*   parent;         /* не NULL лише в елементів керування */
    Menu*     menu;           /* рядок меню (лише верхні вікна) */
    int       min_w, min_h;

    /* Дочірнє вікно тримає позицію ВІДНОСНО робочої області батька,
       інакше при перетягуванні вікна елементи лишалися б на місці. */
    int       rel_x, rel_y;
    int       focusable;      /* чи бере фокус по Tab */
    int       cls;            /* клас елемента, CLS_* у win.c */

    /* Стан прокрутки. Тримається тут, бо смуги малює def_window_proc. */
    int       vs_pos, vs_max, vs_page;
    int       hs_pos, hs_max, hs_page;

    /* Внутрішнє */
    void*     ctl;            /* дані елемента керування */
    int       icon;           /* індекс піктограми для згорнутого вигляду */
};

/* ==========================================================
 * ЖИТТЄВИЙ ЦИКЛ
 * ========================================================== */
int      wm_init(void);
Window*  wnd_create(const char* title, unsigned style,
                    int x, int y, int w, int h, WndProc proc, void* data);
Window*  wnd_create_child(Window* parent, int id, unsigned style, int ctl_style,
                          const char* text, int x, int y, int w, int h,
                          WndProc proc, void* data);
void     wnd_destroy(Window* w);
void     wnd_show(Window* w, int visible);
void     wnd_set_title(Window* w, const char* t);
void     wnd_move(Window* w, int x, int y, int cw, int ch);
void     wnd_minimize(Window* w, int on);
void     wnd_maximize(Window* w, int on);
void     wnd_enable(Window* w, int on);
void     wnd_move_child(Window* c, int x, int y, int w, int h);

/* Геометрія */
void     wnd_client_rect(const Window* w, GuiRect* out);   /* екранні координати */
void     wnd_client_size(const Window* w, int* cw, int* ch);
int      wnd_hittest(Window* w, int sx, int sy);

void     wnd_menubar_rect(const Window* w, GuiRect* out);

/* Перемальовування */
void     wnd_invalidate(Window* w);                        /* усе вікно */
void     wnd_invalidate_client(Window* w);
void     wnd_invalidate_area(Window* w, int cx, int cy, int cw, int ch);
void     wm_invalidate_screen(const GuiRect* r);

/* Порядок, фокус, захоплення */
void     wnd_activate(Window* w);
void     wnd_to_top(Window* w);
Window*  wnd_active(void);
void     wnd_focus(Window* w);
Window*  wnd_get_focus(void);
void     wnd_capture(Window* w);
void     wnd_release(void);
Window*  wnd_from_point(int sx, int sy);
Window*  wnd_child_by_id(Window* parent, int id);

Window* wnd_next_child(Window* parent, Window* after);

/* Обробник за замовчуванням: рамка, заголовок, перетягування,
   зміна розміру, кнопки, смуги прокрутки, Tab між елементами. */
long     def_window_proc(Window* w, int msg, long a, long b);

/* Надіслати повідомлення напряму */
long     wnd_send(Window* w, int msg, long a, long b);

/* Смуги прокрутки */
void     wnd_set_scroll(Window* w, int vert, int pos, int max, int page);
int      wnd_get_scroll(Window* w, int vert);

/* ==========================================================
 * ЦИКЛ ПОВІДОМЛЕНЬ
 * ========================================================== */
void     wm_pump(void);        /* один кадр: події, малювання, вивід */
void     wm_run(void);         /* доки не wm_quit() */
void     wm_quit(void);
int      wm_should_quit(void);

/* Перелік верхніх вікон, від найвищого до найнижчого.
   Потрібен списку задач: у Windows 3.1 його відкривав подвійний
   клік по робочому столу. */
int      wnd_top_count(void);
Window* wnd_top_at(int i);

/* ==========================================================
 * БУФЕР ОБМІНУ
 * Один на всю систему, як CLIPBRD.EXE у Windows 3.1: поля
 * вводу кладуть у нього виділений текст і беруть його назад.
 * ========================================================== */
void        clip_set(const char* s, int len);
const char* clip_get(void);
int         clip_len(void);

/* Перехопити весь ввід одним вікном (меню, модальний діалог).
   Повертає попереднє модальне вікно — його треба повернути назад. */
Window* wm_set_modal(Window* w);

/* Колір робочого столу і його перемальовування */
void     wm_set_desktop(uint32_t color);
void     wm_set_desktop_proc(WndProc p);   /* хто малює тло; 0 = суцільний колір */

/* ==========================================================
 * МЕНЮ
 * ========================================================== */
#define MF_SEPARATOR   0x01
#define MF_CHECKED     0x02
#define MF_DISABLED    0x04

typedef struct {
    int   id;
    char  text[32];
    int   flags;
    Menu* sub;
} MenuItem;

struct Menu {
    MenuItem items[24];
    int      count;
};

Menu* menu_create(void);
void  menu_free(Menu* m);
void  menu_add(Menu* m, int id, const char* text, int flags);
void  menu_add_sub(Menu* m, const char* text, Menu* sub);
void  menu_sep(Menu* m);
void  menu_check(Menu* m, int id, int on);
void  menu_enable(Menu* m, int id, int on);
void  wnd_set_menu(Window* w, Menu* m);

/* Малює рядок меню; викликається з def_window_proc */
void  menu_bar_draw(Window* w);
/* Клік у рядок меню: розкриває список і веде його до вибору.
   Повертає 1, якщо подію спожито. */
int   menu_bar_click(Window* w, int sx, int sy);
/* Alt+літера. Повертає 1, якщо знайдено відповідний пункт. */
int   menu_bar_key(Window* w, char ch);
/* Контекстне меню в точці екрана. Повертає id або 0. */
int   menu_popup(Menu* m, int sx, int sy);

/* ==========================================================
 * ЕЛЕМЕНТИ КЕРУВАННЯ
 * ========================================================== */
Window* ctl_button(Window* parent, int id, const char* text,
                   int x, int y, int w, int h, int bs);
Window* ctl_static(Window* parent, int id, const char* text,
                   int x, int y, int w, int h, int ss);
Window* ctl_edit(Window* parent, int id, const char* text,
                 int x, int y, int w, int h, int es, int cap);
Window* ctl_list(Window* parent, int id,
                 int x, int y, int w, int h);

void        ctl_set_text(Window* w, const char* s);
const char* ctl_get_text(Window* w);
int         ctl_get_check(Window* w);
void        ctl_set_check(Window* w, int on);

void        list_clear(Window* w);
int         list_add(Window* w, const char* s);
int         list_count(Window* w);
const char* list_item(Window* w, int i);
int         list_sel(Window* w);
void        list_set_sel(Window* w, int i);

/* Колонки рядків списку: зсуви в пікселях від лівого краю. Сегменти
   розділяються символом '\t'. Від'ємний зсув притискає сегмент правим
   краєм - для стовпчика чисел. Максимум 6 колонок. */
void        list_set_tabs(Window* w, const int* stops, int n);

void        edit_set(Window* w, const char* s);
const char* edit_get(Window* w);
void        edit_append(Window* w, const char* s);
int         edit_len(Window* w);
void        edit_set_caret(Window* w, int pos);

/* ==========================================================
 * ДІАЛОГИ
 * ========================================================== */
#define MB_OK           1
#define MB_OKCANCEL     2
#define MB_YESNO        3
#define MB_YESNOCANCEL  4

#define IDOK      1
#define IDCANCEL  2
#define IDYES     3
#define IDNO      4

/* Модальний цикл: крутиться, доки вікно не завершить dlg_end().
   Решта вікон на цей час недоступна — саме це й робить діалог
   модальним. Повертає код, переданий у dlg_end. */
int   dlg_modal(Window* dlg);
void  dlg_end(Window* dlg, int result);

/* Порожній модальний діалог: рамка, заголовок, Enter та Esc уже
   працюють. Далі його наповнюють ctl_*, показують dlg_modal і
   прибирають wnd_destroy. */
Window* dlg_create(const char* title, int w, int h);

int   msg_box(const char* title, const char* text, int buttons);

/* Стандартний діалог вибору файлу. Пише ім'я у out, повертає 1. */
int   dlg_open_file(const char* title, char* out, int cap);

/* Рядок вводу одним викликом. Повертає 1, якщо натиснуто OK. */
int   dlg_input(const char* title, const char* prompt, char* buf, int cap);

#endif /* WIN_H */
