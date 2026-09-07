#include "gui.h"

/* ============================================================
 * GUIDEMO — перевірка нового шару рендеру
 *
 * Показує три речі, заради яких усе робилося:
 *   1. вигляд у стилі Windows 3.1 (об'ємні рамки, палітра)
 *   2. пропорційний шрифт з малими літерами
 *   3. часткове оновлення екрана
 *
 * Лічильник унизу показує, скільки прямокутників виводиться
 * на екран за кадр. У спокої це два — смуга стану і ділянка під
 * курсором; при русі миші три — стара позиція курсора, нова і
 * смуга стану. Ніколи не весь екран, як було раніше.
 *
 * ESC — вихід.
 * ============================================================ */

static int scr_w, scr_h;

/* --- Вікно --- */
typedef struct {
    GuiRect r;
    char    title[40];
    int     active;
} DemoWin;

static DemoWin g_win[2];
static int     g_nwin = 2;
static int     g_active = 0;

/* Скільки ділянок вивелося минулого кадру — для наочності */
static int g_last_rects = 0;

/* ============================================================
 * Малювання вікна у стилі Windows 3.1
 * ============================================================ */
static void draw_window(DemoWin* w) {
    GuiRect* r = &w->r;

    /* Зовнішня рамка: темна лінія, потім об'ємний кант.
       Саме подвійна рамка дає впізнаваний вигляд. */
    gui_frame(r->x, r->y, r->w, r->h, GUI_DKSHADOW);
    gui_fill(r->x + 1, r->y + 1, r->w - 2, r->h - 2, GUI_FACE);
    gui_bevel(r->x + 1, r->y + 1, r->w - 2, r->h - 2, 1);

    /* Заголовок */
    uint32_t tc = w->active ? GUI_TITLE_ACT : GUI_TITLE_INACT;
    gui_fill(r->x + 3, r->y + 3, r->w - 6, 18, tc);
    gui_text(w->title, r->x + 24, r->y + 8, GUI_TITLE_TEXT);

    /* Кнопка системного меню зліва */
    gui_fill(r->x + 5, r->y + 5, 14, 14, GUI_FACE);
    gui_bevel(r->x + 5, r->y + 5, 14, 14, 1);
    gui_fill(r->x + 8, r->y + 11, 8, 2, GUI_DKSHADOW);

    /* Кнопки згортання і розгортання справа */
    int bx = r->x + r->w - 37;
    for (int i = 0; i < 2; i++) {
        gui_fill(bx, r->y + 5, 14, 14, GUI_FACE);
        gui_bevel(bx, r->y + 5, 14, 14, 1);
        if (i == 0) gui_fill(bx + 4, r->y + 15, 6, 2, GUI_DKSHADOW);
        else        gui_frame(bx + 3, r->y + 8, 8, 8, GUI_DKSHADOW);
        bx += 16;
    }

    /* Робоча область — втиснута, як у Win 3.1 */
    int cx = r->x + 4, cy = r->y + 24;
    int cw = r->w - 8, ch = r->h - 28;
    gui_bevel(cx, cy, cw, ch, 0);
    gui_fill(cx + 1, cy + 1, cw - 2, ch - 2, GUI_WINDOW_BG);

    /* Текст: демонструє малі літери й пропорційність */
    gui_text_clip("The quick brown fox jumps over the lazy dog.",
                  cx + 6, cy + 8, cx + cw - 4, GUI_TEXT);
    gui_text_clip("Proportional font: iiii vs mmmm",
                  cx + 6, cy + 8 + GUI_LINE_H, cx + cw - 4, GUI_TEXT);
    gui_text_clip("Symbols: {}[]()<>#@$%&*_~^|",
                  cx + 6, cy + 8 + GUI_LINE_H * 2, cx + cw - 4, GUI_TEXT);

    /* Кнопка */
    int bw = 76, bh = 22;
    int bxx = cx + 8, byy = cy + ch - bh - 8;
    gui_fill(bxx, byy, bw, bh, GUI_FACE);
    gui_bevel(bxx, byy, bw, bh, 1);
    gui_frame(bxx, byy, bw, bh, GUI_DKSHADOW);
    int tw = gui_text_w("OK");
    gui_text("OK", bxx + (bw - tw) / 2, byy + (bh - 8) / 2, GUI_TEXT);
}

static void draw_all(void) {
    gui_fill(0, 0, scr_w, scr_h, GUI_DESKTOP);
    /* неактивні спершу, активне зверху */
    for (int i = 0; i < g_nwin; i++) if (i != g_active) draw_window(&g_win[i]);
    draw_window(&g_win[g_active]);
}

/* Рядок стану внизу: показує, що оновлення справді часткове */
static void draw_status(void) {
    int y = scr_h - 20;
    gui_fill(0, y, scr_w, 20, GUI_FACE);
    gui_hline(0, y, scr_w, GUI_LIGHT);

    char buf[80];
    char num[16];
    buf[0] = 0;
    /* власна конкатенація, щоб не тягнути sprintf */
    const char* p = "Rects last frame: ";
    int n = 0;
    while (*p) buf[n++] = *p++;
    int v = g_last_rects, d = 0;
    char tmp[8];
    if (v == 0) tmp[d++] = '0';
    while (v > 0) { tmp[d++] = (char)('0' + v % 10); v /= 10; }
    while (d > 0) buf[n++] = tmp[--d];
    p = "   ESC to exit";
    while (*p) buf[n++] = *p++;
    buf[n] = 0;
    (void)num;

    gui_text(buf, 8, y + 6, GUI_TEXT);
    gui_invalidate(0, y, scr_w, 20);
}

/* Яке вікно лежить n-м зверху: активне завжди найвище, решта —
   у своєму порядку. Раніше цей порядок був переплутаний, і клік у
   зоні перекриття потрапляв у нижнє вікно замість верхнього. */
static int win_by_depth(int n) {
    if (n == 0) return g_active;
    return (n - 1 < g_active) ? (n - 1) : n;
}

int main_gui(void) {
    if (!gui_init()) return 1;
    scr_w = gui_width();
    scr_h = gui_height();

    g_win[0].r.x = 60;  g_win[0].r.y = 50;
    g_win[0].r.w = 400; g_win[0].r.h = 220;
    g_win[0].active = 1;
    {
        const char* t = "Window One";
        int i = 0; while (t[i]) { g_win[0].title[i] = t[i]; i++; } g_win[0].title[i] = 0;
    }
    g_win[1].r.x = 300; g_win[1].r.y = 180;
    g_win[1].r.w = 380; g_win[1].r.h = 200;
    g_win[1].active = 0;
    {
        const char* t = "Window Two";
        int i = 0; while (t[i]) { g_win[1].title[i] = t[i]; i++; } g_win[1].title[i] = 0;
    }

    draw_all();
    gui_invalidate_all();

    int dragging = 0, drag_dx = 0, drag_dy = 0;

    for (;;) {
        GuiEvent e;
        int need_redraw = 0;

        while (gui_poll(&e)) {
            if (e.type == GUI_EV_KEY && e.scancode == 0x01) return 0;   /* ESC */

            if (e.type == GUI_EV_MOUSE_DOWN) {
                /* згори вниз: перше вікно, що накрило точку, і є верхнім */
                for (int n = 0; n < g_nwin; n++) {
                    int idx = win_by_depth(n);
                    if (gui_rect_has(&g_win[idx].r, e.x, e.y)) {
                        if (idx != g_active) {
                            g_win[g_active].active = 0;
                            g_active = idx;
                            g_win[g_active].active = 1;
                            need_redraw = 1;
                        }
                        /* захоплення за заголовок */
                        if (e.y < g_win[idx].r.y + 22) {
                            dragging = 1;
                            drag_dx = e.x - g_win[idx].r.x;
                            drag_dy = e.y - g_win[idx].r.y;
                        }
                        break;
                    }
                }
            }
            else if (e.type == GUI_EV_MOUSE_UP) {
                dragging = 0;
            }
            else if (e.type == GUI_EV_MOUSE_MOVE) {
                if (dragging) {
                    GuiRect* r = &g_win[g_active].r;
                    /* стару позицію вікна теж треба оновити */
                    gui_invalidate(r->x, r->y, r->w, r->h);
                    r->x = e.x - drag_dx;
                    r->y = e.y - drag_dy;
                    if (r->x < 0) r->x = 0;
                    if (r->y < 0) r->y = 0;
                    if (r->x > scr_w - 40) r->x = scr_w - 40;
                    if (r->y > scr_h - 40) r->y = scr_h - 40;
                    gui_invalidate(r->x, r->y, r->w, r->h);
                    need_redraw = 1;
                }
            }
        }

        /* Курсор знімається ПЕРШИМ: він лежить у буфері кадру поверх
           тла, і поки він там, малювати під ним не можна — інакше
           збережене тло застаріє і erase заляпає ним свіжий кадр.
           Викликати треба щокадру, а не лише на рух миші: саме через
           це раніше на екрані лишався слід зі стрілок. */
        gui_cursor_erase();

        if (need_redraw) draw_all();
        draw_status();

        gui_cursor_draw();
        g_last_rects = gui_flush();
    }
}

void gui_main(void) {
    clear_screen();
    init_heap();
    main_gui();
    clear_screen();
    sys_exit();
}
