#ifndef GUI_H
#define GUI_H

#include "stdlib.h"

/* ============================================================
 * EUGENE GUI — НИЖНІЙ ШАР (аналог GDI)
 *
 * Тут живе все, що вміє класти пікселі: буфер кадру, обрізання,
 * примітиви, шрифт, курсор і сира черга подій від ядра.
 *
 * Вікон, кнопок і меню тут НЕМА — вони у win.h, який стоїть
 * поверх цього шару. Розділення таке саме, як у Windows 3.1:
 * GDI.EXE окремо від USER.EXE.
 *
 * ГОЛОВНА ІДЕЯ РЕНДЕРУ — «БРУДНІ ПРЯМОКУТНИКИ»
 * Замість «намалювати все і показати» ми позначаємо
 * gui_invalidate(x,y,w,h) там, де щось змінилося, і gui_flush()
 * виводить на екран лише ці ділянки. Рух курсора чіпає два
 * прямокутники 12x19 замість трьох мегабайтів.
 * ============================================================ */

/* ==========================================================
 * ПАЛІТРА Windows 3.1
 * ========================================================== */
#define GUI_DESKTOP      0x00008080   /* бірюзовий робочий стіл */
#define GUI_FACE         0x00C0C0C0   /* сіре тло елементів */
#define GUI_LIGHT        0x00FFFFFF   /* верхня-ліва грань */
#define GUI_SHADOW       0x00808080   /* нижня-права грань */
#define GUI_DKSHADOW     0x00000000   /* зовнішня темна грань */
#define GUI_TITLE_ACT    0x00000080   /* заголовок активного вікна */
#define GUI_TITLE_INACT  0x00808080   /* заголовок неактивного */
#define GUI_TITLE_TEXT   0x00FFFFFF
#define GUI_TEXT         0x00000000
#define GUI_TEXT_DIM     0x00808080   /* недоступний елемент */
#define GUI_SELECT       0x00000080   /* тло виділення */
#define GUI_SELECT_TEXT  0x00FFFFFF
#define GUI_WINDOW_BG    0x00FFFFFF   /* робоча область документа */

/* ==========================================================
 * ГЕОМЕТРІЯ
 * ========================================================== */
typedef struct { int x, y, w, h; } GuiRect;

static inline int gui_rect_empty(const GuiRect* r) {
    return r->w <= 0 || r->h <= 0;
}

static inline int gui_rect_has(const GuiRect* r, int px, int py) {
    return px >= r->x && px < r->x + r->w &&
           py >= r->y && py < r->y + r->h;
}

/* Перетин. Повертає 0, якщо порожній. out можна не задавати. */
int  gui_rect_isect(const GuiRect* a, const GuiRect* b, GuiRect* out);

/* ==========================================================
 * ЯДРО РЕНДЕРУ
 * ========================================================== */

/* Ініціалізація: дізнається розмір екрана, виділяє буфер кадру.
   Повертає 0 при помилці (не вистачило пам'яті). */
int  gui_init(void);

int  gui_width(void);
int  gui_height(void);

void gui_invalidate(int x, int y, int w, int h);
void gui_invalidate_rect(const GuiRect* r);
void gui_invalidate_all(void);

/* Вивести на екран усе позначене. Раз за кадр.
   Повертає кількість реально виведених прямокутників. */
int  gui_flush(void);

/* ==========================================================
 * ОБРІЗАННЯ (CLIPPING)
 *
 * Без цього елемент керування малює за межами свого вікна, а
 * кожен додаток мусить рахувати межі вручну в кожному рядку.
 * Тепер межі задаються один раз, а примітиви їх поважають.
 *
 * Стек потрібен тому, що малювання вкладене: вікно ставить свою
 * робочу область, елемент усередині — свою, і після нього треба
 * повернути попередню.
 * ========================================================== */
#define GUI_CLIP_DEPTH 16

void gui_clip_reset(void);                   /* весь екран */
void gui_clip_get(GuiRect* out);
int  gui_clip_push(const GuiRect* r);        /* нове = поточне ∩ r; 0 = порожньо */
void gui_clip_pop(void);

/* ==========================================================
 * ПРИМІТИВИ
 * Малюють у буфер кадру і НЕ позначають ділянку брудною —
 * це робить той, хто знає, що саме змінилося.
 * ========================================================== */
void gui_fill(int x, int y, int w, int h, uint32_t color);
void gui_fill_rect(const GuiRect* r, uint32_t color);
void gui_hline(int x, int y, int len, uint32_t color);
void gui_vline(int x, int y, int len, uint32_t color);
void gui_frame(int x, int y, int w, int h, uint32_t color);
void gui_line(int x0, int y0, int x1, int y1, uint32_t color);

/* Об'ємна рамка в один піксель. raised != 0 — опукла. */
void gui_bevel(int x, int y, int w, int h, int raised);

/* Подвійна рамка Windows 3.1: зовнішня + внутрішня грані.
   Саме вона дає впізнаваний вигляд кнопок і полів.
   raised: 1 — кнопка, 0 — втиснуте поле. */
void gui_bevel2(int x, int y, int w, int h, int raised);

/* Сіре решето 50% — тло робочого столу і затінення недоступного. */
void gui_dither(int x, int y, int w, int h, uint32_t a, uint32_t b);

/* Пунктирна рамка фокуса (крапка через піксель). */
void gui_focus_rect(int x, int y, int w, int h);

/* Рамка XOR — нею Windows 3.1 малювала контур вікна при
   перетягуванні. Другий виклик з тими самими координатами
   стирає її і повертає екран у попередній стан. */
void gui_xor_frame(int x, int y, int w, int h, int thick);

/* Один піксель із урахуванням обрізання. */
void gui_pixel(int x, int y, uint32_t color);

/* Прямий доступ до буфера кадру — для швидкого копіювання рядків.
   stride повертається в ПІКСЕЛЯХ, не в байтах. */
uint32_t* gui_fb(int* stride);

/* ==========================================================
 * РАСТРОВІ ЗОБРАЖЕННЯ
 *
 * Формат BMP розбирається тут, у програмі: ядро вміє показувати
 * .BMP лише командою OPEN на весь екран, а вікну потрібна
 * картинка як дані. Нових системних викликів для цього не треба —
 * досить read_file_max().
 * ========================================================== */
typedef struct {
    int       w, h;
    uint32_t* px;      /* 0x00RRGGBB, зверху вниз */
} GuiBitmap;

GuiBitmap* bmp_load(const char* filename);
void       bmp_free(GuiBitmap* b);

void gui_bitmap(const GuiBitmap* b, int x, int y);
/* Колір key не малюється — так робляться піктограми з прозорим тлом */
void gui_bitmap_key(const GuiBitmap* b, int x, int y, uint32_t key);
/* Вписати у прямокутник, найближчим сусідом (масштаб без згладжування) */
void gui_bitmap_fit(const GuiBitmap* b, int x, int y, int w, int h);

/* Кадровий такт для відео: ms > 0 вмикає, 0 вимикає. Такт
   GUI_EV_TICK лишається на своїй чверті секунди - його період
   обрано під миготіння каретки. */
void gui_frame_events(int ms);

/* ==========================================================
 * ТЕКСТ
 * ========================================================== */
void gui_char(char c, int x, int y, uint32_t color);
void gui_text(const char* s, int x, int y, uint32_t color);
void gui_text_clip(const char* s, int x, int y, int right, uint32_t color);
int  gui_text_w(const char* s);
int  gui_text_wn(const char* s, int n);
int  gui_char_w(char c);

/* Текст із підкресленою літерою після '&' — пункти меню та
   написи на кнопках у Windows 3.1 позначали так гарячу клавішу.
   Повертає ASCII гарячої літери у нижньому регістрі (0 якщо нема). */
char gui_text_amp(const char* s, int x, int y, uint32_t color);
int  gui_text_amp_w(const char* s);
char gui_text_amp_key(const char* s);

#define GUI_LINE_H   12     /* висота рядка тексту */
#define GUI_FONT_H   8      /* висота гліфа */

/* ==========================================================
 * ПОДІЇ
 * ========================================================== */
enum {
    GUI_EV_NONE = 0,
    GUI_EV_MOUSE_DOWN,
    GUI_EV_MOUSE_UP,
    GUI_EV_MOUSE_MOVE,
    GUI_EV_MOUSE_DBL,
    GUI_EV_WHEEL,
    GUI_EV_KEY,
    GUI_EV_TICK,
    GUI_EV_FRAME
};

/* Кнопки миші — бітова маска */
#define GUI_MB_LEFT   1
#define GUI_MB_RIGHT  2

typedef struct {
    int      type;
    int      x, y;
    int      button;      /* GUI_MB_* для подій натискання */
    int      buttons;     /* повний стан кнопок на момент події */
    int      wheel;       /* GUI_EV_WHEEL: знакова кількість тіків */
    uint8_t  ascii;       /* GUI_EV_KEY */
    uint8_t  scancode;
    uint8_t  mods;        /* KEY_MOD_* зі stdlib.h */
} GuiEvent;

int  gui_poll(GuiEvent* ev);
void gui_mouse(int* x, int* y, int* buttons);
uint64_t gui_ticks(void);

/* ==========================================================
 * КУРСОР
 *
 * Курсор лежить у тому самому буфері кадру, що й усе інше, і
 * сам зберігає та повертає те, що під ним (save-under).
 *
 * ПОРЯДОК ВИКЛИКІВ У КАДРІ:
 *     gui_cursor_erase();     // зняти курсор з буфера
 *     ... тут малюємо ...
 *     gui_cursor_draw();      // покласти курсор назад
 *     gui_flush();
 *
 * Якщо малювати ДО erase, збережене тло стане застарілим і erase
 * заляпає ним свіжий кадр. Якщо erase не викликати взагалі —
 * стрілка лишиться в буфері й на екрані буде слід.
 * ========================================================== */
enum {
    GUI_CUR_ARROW = 0,
    GUI_CUR_IBEAM,
    GUI_CUR_SIZE_WE,
    GUI_CUR_SIZE_NS,
    GUI_CUR_SIZE_NWSE,
    GUI_CUR_SIZE_NESW,
    GUI_CUR_WAIT,
    GUI_CUR_COUNT
};

void gui_cursor_draw(void);
void gui_cursor_erase(void);
void gui_cursor_set(int shape);
int  gui_cursor_get(void);

#endif /* GUI_H */
