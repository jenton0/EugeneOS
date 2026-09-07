#include "win.h"

/* ============================================================
 * EUGENE GUI — ЕЛЕМЕНТИ КЕРУВАННЯ
 *
 * У Windows 3.1 кнопка, поле вводу і список — це звичайні вікна
 * з власною процедурою. Тому вони безкоштовно отримують фокус,
 * обхід по Tab, перемальовування ділянками і все інше, що вміє
 * віконний менеджер. Тут точно так само: жодного окремого
 * механізму для елементів не існує.
 * ============================================================ */

enum { CLS_STATIC = 1, CLS_BUTTON, CLS_EDIT, CLS_LIST };

typedef struct {
    /* спільне */
    int    focused;

    /* кнопка */
    int    checked;
    int    pressed;
    int    inside;

    /* поле вводу */
    char*  text;
    int    cap, len;
    int    caret;
    int    top;          /* перший видимий візуальний рядок */
    int    caret_on;     /* фаза миготіння */
    int    anchor;       /* початок виділення; -1 = виділення немає */
    int    dragging;     /* тягнемо виділення мишею */

    /* список */
    char** items;
    int    count, alloc;
    int    sel, ltop;
    int    sb_drag, sb_grab;
    /* Колонки списку. Додатне число - зсув колонки від лівого краю,
       від'ємне - правий край, до якого сегмент притискається. Поки
       ntabs = 0, рядок малюється цілим, тому решта списків нічого
       не помічає. */
    int    tabs[6];
    int    ntabs;
} Ctl;

#define LH GUI_LINE_H

static int imax(int a, int b) { return a > b ? a : b; }
static int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static Ctl* C(Window* w) { return (Ctl*)w->ctl; }

static void notify(Window* w, int code) {
    if (w->parent) wnd_send(w->parent, WM_COMMAND, w->id, code);
}

/* ============================================================
 * STATIC — напис, рамка, група
 * ============================================================ */

static long static_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_PAINT: {
        GuiRect r; wnd_client_rect(w, &r);
        if (w->ctl_style == SS_FRAME) {
            /* Рамка групи: подвійна лінія з розривом під назву */
            int ty = r.y + 4;
            gui_bevel(r.x, ty, r.w, r.h - 4, 0);
            gui_bevel(r.x + 1, ty + 1, r.w - 2, r.h - 6, 1);
            if (w->title[0]) {
                int tw = gui_text_amp_w(w->title) + 6;
                gui_fill(r.x + 8, r.y, tw, GUI_FONT_H + 2, GUI_FACE);
                gui_text_amp(w->title, r.x + 11, r.y, GUI_TEXT);
            }
            return 0;
        }
        gui_fill_rect(&r, GUI_FACE);
        int tw = gui_text_amp_w(w->title);
        int tx = r.x;
        if (w->ctl_style == SS_CENTER) tx = r.x + (r.w - tw) / 2;
        else if (w->ctl_style == SS_RIGHT) tx = r.x + r.w - tw;
        gui_text_amp(w->title, tx, r.y + (r.h - GUI_FONT_H) / 2,
                     (w->style & WS_DISABLED) ? GUI_TEXT_DIM : GUI_TEXT);
        return 0;
    }
    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * BUTTON — натискна, прапорець, перемикач
 * ============================================================ */

static void radio_dot(int cx, int cy, int on) {
    /* Кружечок 12x12 без справжніх кіл: чотири рядки різної
       довжини дають достатньо круглу форму на такому розмірі. */
    static const int wdt[6] = { 4, 8, 10, 10, 8, 4 };
    for (int i = 0; i < 6; i++) {
        int half = wdt[i] / 2;
        gui_hline(cx - half, cy - 5 + i, wdt[i], GUI_WINDOW_BG);
        gui_hline(cx - half, cy + 4 - i, wdt[i], GUI_WINDOW_BG);
    }
    /* обвід */
    gui_hline(cx - 2, cy - 6, 5, GUI_SHADOW);
    gui_hline(cx - 2, cy + 5, 5, GUI_LIGHT);
    gui_vline(cx - 6, cy - 2, 5, GUI_SHADOW);
    gui_vline(cx + 5, cy - 2, 5, GUI_LIGHT);
    gui_line(cx - 5, cy - 5, cx - 3, cy - 3, GUI_SHADOW);
    gui_line(cx + 4, cy + 4, cx + 2, cy + 2, GUI_LIGHT);
    if (on) {
        gui_fill(cx - 2, cy - 2, 4, 4, GUI_TEXT);
        gui_fill(cx - 1, cy - 3, 2, 6, GUI_TEXT);
        gui_fill(cx - 3, cy - 1, 6, 2, GUI_TEXT);
    }
}

static void check_mark(int x, int y) {
    /* Галочка, як у Windows 3.1: коротка ліва частина, довга права */
    gui_line(x + 2, y + 5, x + 4, y + 7, GUI_TEXT);
    gui_line(x + 3, y + 5, x + 5, y + 7, GUI_TEXT);
    gui_line(x + 4, y + 7, x + 9, y + 2, GUI_TEXT);
    gui_line(x + 5, y + 7, x + 10, y + 2, GUI_TEXT);
}

static void button_activate(Window* w) {
    Ctl* c = C(w);
    if (w->ctl_style == BS_CHECK) {
        c->checked = !c->checked;
        wnd_invalidate(w);
    } else if (w->ctl_style == BS_RADIO) {
        /* Перемикачі одного батька взаємно виключні: вмикаючи один,
           гасимо решту. Групувати їх окремо ми не даємо — на цьому
           розмірі системи це зайва сутність. */
        Window* s = 0;
        while ((s = wnd_next_child(w->parent, s)) != 0) {
            if (s == w) continue;
            if (s->cls != CLS_BUTTON || s->ctl_style != BS_RADIO) continue;
            Ctl* sc = C(s);
            if (sc->checked) { sc->checked = 0; wnd_invalidate(s); }
        }
        c->checked = 1;
        wnd_invalidate(w);
    }
    notify(w, BN_CLICKED);
}

static long button_proc(Window* w, int msg, long a, long b) {
    Ctl* c = C(w);
    switch (msg) {
    case WM_PAINT: {
        GuiRect r; wnd_client_rect(w, &r);
        int dis = (w->style & WS_DISABLED) != 0;
        uint32_t tc = dis ? GUI_TEXT_DIM : GUI_TEXT;

        if (w->ctl_style == BS_CHECK || w->ctl_style == BS_RADIO) {
            gui_fill_rect(&r, GUI_FACE);
            int by = r.y + (r.h - 13) / 2;
            if (w->ctl_style == BS_CHECK) {
                gui_fill(r.x, by, 13, 13, GUI_WINDOW_BG);
                gui_bevel2(r.x, by, 13, 13, 0);
                if (c->checked) check_mark(r.x, by);
            } else {
                radio_dot(r.x + 6, by + 6, c->checked);
            }
            gui_text_amp(w->title, r.x + 18, r.y + (r.h - GUI_FONT_H) / 2, tc);
            if (c->focused)
                gui_focus_rect(r.x + 15, r.y + 1, r.w - 15, r.h - 2);
            return 0;
        }

        /* Натискна кнопка */
        int down = c->pressed && c->inside;
        gui_fill_rect(&r, GUI_FACE);
        if (w->ctl_style == BS_DEFPUSH) {
            /* Кнопка за замовчуванням має зайву чорну рамку — саме
               так Windows 3.1 показувала, що спрацює Enter. */
            gui_frame(r.x, r.y, r.w, r.h, GUI_DKSHADOW);
            gui_bevel2(r.x + 1, r.y + 1, r.w - 2, r.h - 2, down ? 0 : 1);
        } else {
            gui_bevel2(r.x, r.y, r.w, r.h, down ? 0 : 1);
        }
        int tw = gui_text_amp_w(w->title);
        int tx = r.x + (r.w - tw) / 2 + (down ? 1 : 0);
        int ty = r.y + (r.h - GUI_FONT_H) / 2 + (down ? 1 : 0);
        gui_text_amp(w->title, tx, ty, tc);
        if (c->focused)
            gui_focus_rect(r.x + 4, r.y + 4, r.w - 8, r.h - 8);
        return 0;
    }

    case WM_LBUTTONDOWN:
        if (w->style & WS_DISABLED) return 0;
        c->pressed = 1; c->inside = 1;
        wnd_capture(w);
        wnd_invalidate(w);
        return 0;

    case WM_MOUSEMOVE:
        if (c->pressed) {
            int in = (a >= 0 && b >= 0 && a < w->r.w && b < w->r.h);
            if (in != c->inside) { c->inside = in; wnd_invalidate(w); }
        }
        return 0;

    case WM_LBUTTONUP:
        if (c->pressed) {
            c->pressed = 0;
            wnd_release();
            wnd_invalidate(w);
            if (c->inside) button_activate(w);
        }
        return 0;

    case WM_KEYDOWN:
        if (w->style & WS_DISABLED) return 0;
        if (a == VK_SPACE || a == VK_ENTER) { button_activate(w); return 0; }
        /* Решту (Tab, стрілки) віддаємо батькові — фокус його справа */
        if (w->parent) return wnd_send(w->parent, WM_KEYDOWN, a, b);
        return 0;

    case WM_SETFOCUS:  c->focused = 1; wnd_invalidate(w); return 0;
    case WM_KILLFOCUS: c->focused = 0; c->pressed = 0; wnd_invalidate(w); return 0;

    case WM_DESTROY:
        if (w->ctl) { free(w->ctl); w->ctl = 0; }
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * EDIT — поле вводу
 *
 * Один прохід по тексту вміє одразу три речі: намалювати, знайти
 * позицію каретки і порахувати кількість візуальних рядків.
 * Тримати три окремі функції з однаковою логікою переносу — це
 * гарантовано розійтися в поведінці.
 * ============================================================ */

typedef struct {
    Window* w;
    Ctl*    c;
    int     render;
    int     want_pos;       /* -1 = не шукаємо */
    int     out_line, out_col;
    int     hit_x, hit_y;   /* -1 = не шукаємо */
    int     out_pos;
    int     sel_lo, sel_hi; /* діапазон виділення для підсвітки */
} EditWalk;

static int edit_walk(EditWalk* e) {
    Window* w = e->w;
    Ctl* c = e->c;
    GuiRect r; wnd_client_rect(w, &r);
    int inner = 2;
    int right = r.w - inner * 2;
    int vis = (r.h - inner * 2) / LH;
    if (vis < 1) vis = 1;

    int line = 0, col = 0, x = 0;
    int i = 0;
    int multi = (w->ctl_style == ES_MULTILINE);

    for (;;) {
        int ch = (i < c->len) ? (unsigned char)c->text[i] : -1;

        if (e->want_pos == i) { e->out_line = line; e->out_col = col; }

        if (ch < 0) break;

        if (ch == '\n' && multi) {
            if (e->hit_y >= 0 && e->hit_y == line && e->hit_x >= x)
                e->out_pos = i;
            line++; col = 0; x = 0; i++;
            continue;
        }

        int cw = gui_char_w((char)ch);
        if (multi && x + cw > right && col > 0) {
            line++; col = 0; x = 0;
            continue;                       /* той самий символ на новому рядку */
        }

        if (e->hit_y == line && e->hit_x >= x && e->hit_x < x + cw)
            e->out_pos = i;

        if (e->render) {
            int sl = line - c->top;
            if (sl >= 0 && sl < vis && (multi || (x >= 0 && x + cw <= right))) {
                int px = r.x + inner + x;
                int py = r.y + inner + sl * LH;
                int sel = (i >= e->sel_lo && i < e->sel_hi);
                if (sel) gui_fill(px, py, cw, LH, GUI_SELECT);
                gui_char((char)ch, px, py + 2, sel ? GUI_SELECT_TEXT : GUI_TEXT);
            }
        }

        x += cw; col++; i++;
    }

    if (e->hit_y >= line && e->hit_x >= 0 && e->out_pos < 0) e->out_pos = c->len;
    return line + 1;
}

static int edit_lines(Window* w) {
    EditWalk e; memset(&e, 0, sizeof(e));
    e.w = w; e.c = C(w); e.render = 0; e.want_pos = -1; e.hit_x = -1; e.hit_y = -1;
    e.out_pos = -1;
    return edit_walk(&e);
}

static void edit_caret_pos(Window* w, int* line, int* col) {
    EditWalk e; memset(&e, 0, sizeof(e));
    e.w = w; e.c = C(w); e.render = 0; e.want_pos = C(w)->caret;
    e.hit_x = -1; e.hit_y = -1; e.out_pos = -1;
    e.out_line = 0; e.out_col = 0;
    edit_walk(&e);
    *line = e.out_line; *col = e.out_col;
}

static int edit_vis(Window* w) {
    GuiRect r; wnd_client_rect(w, &r);
    int v = (r.h - 4) / LH;
    return v < 1 ? 1 : v;
}

static void edit_follow(Window* w) {
    Ctl* c = C(w);
    int line, col;
    edit_caret_pos(w, &line, &col);
    int vis = edit_vis(w);
    if (line < c->top) c->top = line;
    if (line >= c->top + vis) c->top = line - vis + 1;
    if (c->top < 0) c->top = 0;

    int total = edit_lines(w);
    wnd_set_scroll(w, 1, c->top, imax(0, total - vis), vis);
}

static void edit_insert(Window* w, char ch) {
    Ctl* c = C(w);
    if (w->ctl_style == ES_READONLY) return;
    c->anchor = -1;
    if (c->len + 1 >= c->cap) return;
    for (int i = c->len; i > c->caret; i--) c->text[i] = c->text[i - 1];
    c->text[c->caret] = ch;
    c->len++;
    c->caret++;
    c->text[c->len] = 0;
    edit_follow(w);
    wnd_invalidate(w);
    notify(w, EN_CHANGE);
}

static void edit_erase(Window* w, int at) {
    Ctl* c = C(w);
    if (w->ctl_style == ES_READONLY) return;
    if (at < 0 || at >= c->len) return;
    for (int i = at; i < c->len - 1; i++) c->text[i] = c->text[i + 1];
    c->len--;
    c->text[c->len] = 0;
    if (c->caret > at) c->caret--;
    edit_follow(w);
    wnd_invalidate(w);
    notify(w, EN_CHANGE);
}

/* --- Виділення --- */

static void edit_sel_range(Ctl* c, int* lo, int* hi) {
    if (c->anchor < 0 || c->anchor == c->caret) { *lo = -1; *hi = -1; return; }
    if (c->anchor < c->caret) { *lo = c->anchor; *hi = c->caret; }
    else                      { *lo = c->caret;  *hi = c->anchor; }
}

/* Прибрати виділений текст. Повертає 1, якщо було що прибирати. */
static int edit_del_sel(Window* w) {
    Ctl* c = C(w);
    int lo, hi;
    edit_sel_range(c, &lo, &hi);
    if (lo < 0) return 0;
    if (w->ctl_style == ES_READONLY) return 0;
    int n = hi - lo;
    for (int i = lo; i <= c->len - n; i++) c->text[i] = c->text[i + n];
    c->len -= n;
    c->text[c->len] = 0;
    c->caret = lo;
    c->anchor = -1;
    return 1;
}

static void edit_copy(Window* w, int cut) {
    Ctl* c = C(w);
    int lo, hi;
    edit_sel_range(c, &lo, &hi);
    if (lo < 0) return;
    clip_set(c->text + lo, hi - lo);
    if (cut && edit_del_sel(w)) {
        edit_follow(w);
        notify(w, EN_CHANGE);
    }
    wnd_invalidate(w);
}

static void edit_paste(Window* w) {
    Ctl* c = C(w);
    if (w->ctl_style == ES_READONLY) return;
    edit_del_sel(w);
    const char* s = clip_get();
    int n = clip_len();
    if (n <= 0) return;
    if (c->len + n >= c->cap) n = c->cap - 1 - c->len;
    if (n <= 0) return;
    for (int i = c->len; i >= c->caret; i--) c->text[i + n] = c->text[i];
    for (int i = 0; i < n; i++) c->text[c->caret + i] = s[i];
    c->len += n;
    c->caret += n;
    c->text[c->len] = 0;
    c->anchor = -1;
    edit_follow(w);
    wnd_invalidate(w);
    notify(w, EN_CHANGE);
}

/* Позиція у тексті під точкою робочої області */
static int edit_pos_at(Window* w, int cx, int cy) {
    Ctl* c = C(w);
    EditWalk e; memset(&e, 0, sizeof(e));
    e.w = w; e.c = c; e.render = 0; e.want_pos = -1;
    e.hit_x = cx - 2; if (e.hit_x < 0) e.hit_x = 0;
    e.hit_y = c->top + cy / LH;
    e.out_pos = -1;
    edit_walk(&e);
    return (e.out_pos >= 0) ? e.out_pos : c->len;
}

static long edit_proc(Window* w, int msg, long a, long b) {
    Ctl* c = C(w);
    int multi = (w->ctl_style == ES_MULTILINE);

    switch (msg) {
    case WM_PAINT: {
        GuiRect r; wnd_client_rect(w, &r);
        gui_fill_rect(&r, GUI_WINDOW_BG);
        if (gui_clip_push(&r)) {
            EditWalk e; memset(&e, 0, sizeof(e));
            e.w = w; e.c = c; e.render = 1; e.want_pos = -1;
            e.hit_x = -1; e.hit_y = -1; e.out_pos = -1;
            edit_sel_range(c, &e.sel_lo, &e.sel_hi);
            edit_walk(&e);

            if (c->focused && c->caret_on) {
                int line, col;
                edit_caret_pos(w, &line, &col);
                int sl = line - c->top;
                if (sl >= 0 && sl < edit_vis(w)) {
                    /* Ширина до каретки рахується тим самим шрифтом,
                       що й малювання, тому каретка не «пливе». */
                    int x = 0, i = 0;
                    while (i < c->caret && i < c->len) {
                        if (c->text[i] == '\n' && multi) { x = 0; i++; continue; }
                        int cw = gui_char_w(c->text[i]);
                        if (multi && x + cw > r.w - 4 && x > 0) { x = 0; continue; }
                        x += cw; i++;
                    }
                    gui_fill(r.x + 2 + x, r.y + 2 + sl * LH + 1, 1, GUI_FONT_H + 2, GUI_TEXT);
                }
            }
            gui_clip_pop();
        } else gui_clip_pop();
        return 0;
    }

    case WM_LBUTTONDOWN:
        c->caret = edit_pos_at(w, (int)a, (int)b);
        c->anchor = c->caret;       /* початок можливого протягування */
        c->dragging = 1;
        c->caret_on = 1;
        wnd_capture(w);
        wnd_invalidate(w);
        return 0;

    case WM_MOUSEMOVE:
        if (c->dragging) {
            int p = edit_pos_at(w, (int)a, (int)b);
            if (p != c->caret) { c->caret = p; edit_follow(w); wnd_invalidate(w); }
        }
        return 0;

    case WM_LBUTTONUP:
        if (c->dragging) {
            c->dragging = 0;
            wnd_release();
            if (c->anchor == c->caret) c->anchor = -1;
            wnd_invalidate(w);
        }
        return 0;

    case WM_LBUTTONDBLCLK: {
        /* Подвійний клік виділяє слово під курсором */
        int p = edit_pos_at(w, (int)a, (int)b);
        int lo = p, hi = p;
        while (lo > 0 && isalnum((unsigned char)c->text[lo - 1])) lo--;
        while (hi < c->len && isalnum((unsigned char)c->text[hi])) hi++;
        if (hi > lo) { c->anchor = lo; c->caret = hi; wnd_invalidate(w); }
        return 0;
    }

    case WM_CHAR:
        if (a >= 32 && a < 127) {
            if (edit_del_sel(w)) notify(w, EN_CHANGE);
            edit_insert(w, (char)a);
            return 0;
        }
        return 0;

    case WM_KEYDOWN: {
        int shift = (b & KEY_MOD_SHIFT) != 0;
        int ctrl  = (b & KEY_MOD_CTRL) != 0;

        if (ctrl) {
            switch (a) {
            case 0x2E: edit_copy(w, 0); return 0;                 /* Ctrl+C */
            case 0x2D: edit_copy(w, 1); return 0;                 /* Ctrl+X */
            case 0x2F: edit_paste(w);   return 0;                 /* Ctrl+V */
            case 0x1E:                                            /* Ctrl+A */
                c->anchor = 0; c->caret = c->len;
                wnd_invalidate(w);
                return 0;
            default: break;
            }
        }

        /* Будь-який рух каретки: із Shift тягне виділення, без нього гасить */
        switch (a) {
        case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
        case VK_HOME: case VK_END: case VK_PGUP: case VK_PGDN:
            if (shift) { if (c->anchor < 0) c->anchor = c->caret; }
            else       c->anchor = -1;
            break;
        default: break;
        }

        switch (a) {
        case VK_BKSP:
            if (edit_del_sel(w)) { edit_follow(w); wnd_invalidate(w); notify(w, EN_CHANGE); }
            else if (c->caret > 0) edit_erase(w, c->caret - 1);
            return 0;
        case VK_DEL:
            if (edit_del_sel(w)) { edit_follow(w); wnd_invalidate(w); notify(w, EN_CHANGE); }
            else edit_erase(w, c->caret);
            return 0;
        case VK_LEFT:  if (c->caret > 0) c->caret--; edit_follow(w); wnd_invalidate(w); return 0;
        case VK_RIGHT: if (c->caret < c->len) c->caret++; edit_follow(w); wnd_invalidate(w); return 0;
        case VK_HOME: {
            int l, col;
            edit_caret_pos(w, &l, &col);
            c->caret -= col;
            if (c->caret < 0) c->caret = 0;
            wnd_invalidate(w);
            return 0;
        }
        case VK_END: {
            /* Кінець візуального рядка: йдемо вперед, доки номер рядка той самий */
            int l0, col0;
            edit_caret_pos(w, &l0, &col0);
            while (c->caret < c->len) {
                int l, col;
                c->caret++;
                edit_caret_pos(w, &l, &col);
                if (l != l0) { c->caret--; break; }
            }
            wnd_invalidate(w);
            return 0;
        }
        case VK_ENTER:
            if (multi) {
                if (edit_del_sel(w)) notify(w, EN_CHANGE);
                edit_insert(w, '\n');
                return 0;
            }
            break;
        case VK_UP: case VK_DOWN: case VK_PGUP: case VK_PGDN:
            if (multi) {
                int l, col;
                edit_caret_pos(w, &l, &col);
                int vis = edit_vis(w);
                int nl = l;
                if (a == VK_UP) nl = l - 1;
                else if (a == VK_DOWN) nl = l + 1;
                else if (a == VK_PGUP) nl = l - vis;
                else nl = l + vis;
                if (nl < 0) nl = 0;
                EditWalk e; memset(&e, 0, sizeof(e));
                e.w = w; e.c = c; e.render = 0; e.want_pos = -1;
                e.hit_y = nl; e.hit_x = 0; e.out_pos = -1;
                edit_walk(&e);
                if (e.out_pos >= 0) c->caret = e.out_pos;
                edit_follow(w);
                wnd_invalidate(w);
                return 0;
            }
            break;
        default: break;
        }
        /* Те, чого поле не спожило, віддаємо батькові — так Enter
           у діалозі доходить до кнопки за замовчуванням. */
        if (w->parent) return wnd_send(w->parent, WM_KEYDOWN, a, b);
        return 0;
    }

    case WM_VSCROLL:
        c->top = (int)b;
        wnd_set_scroll(w, 1, c->top, w->vs_max, w->vs_page);
        wnd_invalidate(w);
        return 0;

    case WM_MOUSEWHEEL:
        if (multi) {
            int total = edit_lines(w);
            int vis = edit_vis(w);
            c->top = iclamp(c->top - (int)a * 3, 0, imax(0, total - vis));
            wnd_set_scroll(w, 1, c->top, imax(0, total - vis), vis);
            wnd_invalidate(w);
        }
        return 0;

    case WM_TIMER:
        if (c->focused) {
            c->caret_on = !c->caret_on;
            wnd_invalidate(w);
        }
        return 0;

    case WM_SETCURSOR:
        return GUI_CUR_IBEAM;

    case WM_SETFOCUS:  c->focused = 1; c->caret_on = 1; wnd_invalidate(w); return 0;
    case WM_KILLFOCUS: c->focused = 0; c->caret_on = 0; wnd_invalidate(w); return 0;

    case WM_DESTROY:
        if (c) { if (c->text) free(c->text); free(c); w->ctl = 0; }
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * LISTBOX
 * ============================================================ */

static int list_vis(Window* w) {
    GuiRect r; wnd_client_rect(w, &r);
    int v = r.h / LH;
    return v < 1 ? 1 : v;
}

static void list_sync_scroll(Window* w) {
    Ctl* c = C(w);
    int vis = list_vis(w);
    c->ltop = iclamp(c->ltop, 0, imax(0, c->count - vis));
    wnd_set_scroll(w, 1, c->ltop, imax(0, c->count - vis), vis);
}

static void list_follow(Window* w) {
    Ctl* c = C(w);
    int vis = list_vis(w);
    if (c->sel < 0) return;
    if (c->sel < c->ltop) c->ltop = c->sel;
    if (c->sel >= c->ltop + vis) c->ltop = c->sel - vis + 1;
    list_sync_scroll(w);
}

/* Рядок списку з табуляторами. Шрифт у нас пропорційний, тому
   вирівняти колонки пробілами неможливо - зсуви задаються в пікселях,
   рівно як це робили списки з LBS_USETABSTOPS. */
static void list_draw_item(Ctl* c, const char* s, int x, int y,
                           int right, uint32_t col) {
    if (c->ntabs <= 0) { gui_text_clip(s, x, y, right, col); return; }

    const char* p = s;
    int seg = 0;
    for (;;) {
        const char* e = p;
        while (*e && *e != '\t') e++;

        /* gui_text_clip хоче нуль у кінці, тому сегмент копіюємо */
        char part[48];
        int n = (int)(e - p);
        if (n > (int)sizeof(part) - 1) n = (int)sizeof(part) - 1;
        for (int i = 0; i < n; i++) part[i] = p[i];
        part[n] = 0;

        int sx = x;
        if (seg > 0 && seg <= c->ntabs) {
            int t = c->tabs[seg - 1];
            sx = (t >= 0) ? x + t : x + (-t) - gui_text_w(part);
        }
        gui_text_clip(part, sx, y, right, col);

        if (!*e) break;
        p = e + 1;
        seg++;
    }
}

static long list_proc(Window* w, int msg, long a, long b) {
    Ctl* c = C(w);
    switch (msg) {
    case WM_PAINT: {
        GuiRect r; wnd_client_rect(w, &r);
        gui_fill_rect(&r, GUI_WINDOW_BG);
        int vis = list_vis(w);
        if (gui_clip_push(&r)) {
            for (int i = 0; i < vis; i++) {
                int idx = c->ltop + i;
                if (idx < 0 || idx >= c->count) break;
                int y = r.y + i * LH;
                if (idx == c->sel) {
                    gui_fill(r.x, y, r.w, LH, GUI_SELECT);
                    list_draw_item(c, c->items[idx], r.x + 3, y + 2,
                                   r.x + r.w - 2, GUI_SELECT_TEXT);
                    if (c->focused) gui_focus_rect(r.x, y, r.w, LH);
                } else {
                    list_draw_item(c, c->items[idx], r.x + 3, y + 2,
                                   r.x + r.w - 2, GUI_TEXT);
                }
            }
            gui_clip_pop();
        } else gui_clip_pop();
        return 0;
    }

    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
        int idx = c->ltop + (int)b / LH;
        if (idx >= 0 && idx < c->count) {
            if (idx != c->sel) { c->sel = idx; notify(w, LBN_SELCHANGE); }
            wnd_invalidate(w);
            if (msg == WM_LBUTTONDBLCLK) notify(w, LBN_DBLCLK);
        }
        return 0;
    }

    case WM_KEYDOWN: {
        int vis = list_vis(w);
        int old = c->sel;
        switch (a) {
        case VK_UP:    if (c->sel > 0) c->sel--; break;
        case VK_DOWN:  if (c->sel < c->count - 1) c->sel++; break;
        case VK_PGUP:  c->sel = iclamp(c->sel - vis, 0, imax(0, c->count - 1)); break;
        case VK_PGDN:  c->sel = iclamp(c->sel + vis, 0, imax(0, c->count - 1)); break;
        case VK_HOME:  c->sel = c->count ? 0 : -1; break;
        case VK_END:   c->sel = c->count - 1; break;
        case VK_ENTER:
            /* Alt+Enter - це не "відкрити", а "властивості". Тому
               список його не споживає, а віддає батькові. */
            if (b & KEY_MOD_ALT) {
                if (w->parent) return wnd_send(w->parent, WM_KEYDOWN, a, b);
                return 0;
            }
            notify(w, LBN_DBLCLK);
            return 0;
        default:
            if (w->parent) return wnd_send(w->parent, WM_KEYDOWN, a, b);
            return 0;
        }
        if (c->sel != old) { list_follow(w); notify(w, LBN_SELCHANGE); wnd_invalidate(w); }
        return 0;
    }

    case WM_MOUSEWHEEL: {
        int vis = list_vis(w);
        c->ltop = iclamp(c->ltop - (int)a * 3, 0, imax(0, c->count - vis));
        list_sync_scroll(w);
        wnd_invalidate(w);
        return 0;
    }

    case WM_VSCROLL:
        c->ltop = (int)b;
        wnd_set_scroll(w, 1, c->ltop, w->vs_max, w->vs_page);
        wnd_invalidate(w);
        return 0;

    case WM_SETFOCUS:  c->focused = 1; wnd_invalidate(w); return 0;
    case WM_KILLFOCUS: c->focused = 0; wnd_invalidate(w); return 0;

    case WM_DESTROY:
        if (c) {
            for (int i = 0; i < c->count; i++) free(c->items[i]);
            if (c->items) free(c->items);
            free(c);
            w->ctl = 0;
        }
        return 0;

    default:
        return def_window_proc(w, msg, a, b);
    }
}

/* ============================================================
 * СТВОРЕННЯ
 * ============================================================ */

static Ctl* ctl_new(void) {
    Ctl* c = (Ctl*)malloc(sizeof(Ctl));
    if (!c) return 0;
    memset(c, 0, sizeof(Ctl));
    c->sel = -1;
    c->anchor = -1;
    return c;
}

Window* ctl_static(Window* parent, int id, const char* text,
                   int x, int y, int w, int h, int ss) {
    Ctl* c = ctl_new();
    if (!c) return 0;
    Window* p = wnd_create_child(parent, id, 0, ss, text, x, y, w, h, static_proc, 0);
    if (!p) { free(c); return 0; }
    p->ctl = c;
    p->cls = CLS_STATIC;
    p->focusable = 0;
    return p;
}

Window* ctl_button(Window* parent, int id, const char* text,
                   int x, int y, int w, int h, int bs) {
    Ctl* c = ctl_new();
    if (!c) return 0;
    Window* p = wnd_create_child(parent, id, 0, bs, text, x, y, w, h, button_proc, 0);
    if (!p) { free(c); return 0; }
    p->ctl = c;
    p->cls = CLS_BUTTON;
    p->focusable = 1;
    return p;
}

Window* ctl_edit(Window* parent, int id, const char* text,
                 int x, int y, int w, int h, int es, int cap) {
    if (cap < 16) cap = 16;
    Ctl* c = ctl_new();
    if (!c) return 0;
    c->text = (char*)malloc((unsigned long)cap);
    if (!c->text) { free(c); return 0; }
    c->cap = cap;
    c->len = 0;
    c->text[0] = 0;

    unsigned style = WS_CLIENTEDGE | ((es == ES_MULTILINE) ? WS_VSCROLL : 0);
    Window* p = wnd_create_child(parent, id, style, es, "", x, y, w, h, edit_proc, 0);
    if (!p) { free(c->text); free(c); return 0; }
    p->ctl = c;
    p->cls = CLS_EDIT;
    p->focusable = (es != ES_READONLY);
    if (text) edit_set(p, text);
    return p;
}

Window* ctl_list(Window* parent, int id, int x, int y, int w, int h) {
    Ctl* c = ctl_new();
    if (!c) return 0;
    c->alloc = 16;
    c->items = (char**)malloc(sizeof(char*) * 16);
    if (!c->items) { free(c); return 0; }
    Window* p = wnd_create_child(parent, id, WS_VSCROLL | WS_CLIENTEDGE, 0, "", x, y, w, h, list_proc, 0);
    if (!p) { free(c->items); free(c); return 0; }
    p->ctl = c;
    p->cls = CLS_LIST;
    p->focusable = 1;
    return p;
}

/* ============================================================
 * ДОСТУП ДО ВМІСТУ
 * ============================================================ */

void ctl_set_text(Window* w, const char* s) {
    if (!w) return;
    if (w->cls == CLS_EDIT) { edit_set(w, s); return; }
    int i = 0;
    if (s) while (s[i] && i < (int)sizeof(w->title) - 1) { w->title[i] = s[i]; i++; }
    w->title[i] = 0;
    wnd_invalidate(w);
}

const char* ctl_get_text(Window* w) {
    if (!w) return "";
    if (w->cls == CLS_EDIT) return edit_get(w);
    return w->title;
}

int ctl_get_check(Window* w) {
    if (!w || w->cls != CLS_BUTTON) return 0;
    return C(w)->checked;
}

void ctl_set_check(Window* w, int on) {
    if (!w || w->cls != CLS_BUTTON) return;
    C(w)->checked = on ? 1 : 0;
    wnd_invalidate(w);
}

/* Колонки списку в пікселях від лівого краю рядка. Від'ємне значення
   означає, що сегмент притискається правим краєм до -stops[i]: так
   вирівнюють стовпчик розміру, щоб одиниці стояли під одиницями. */
void list_set_tabs(Window* w, const int* stops, int n) {
    if (!w || w->cls != CLS_LIST) return;
    Ctl* c = C(w);
    if (n < 0) n = 0;
    if (n > 6) n = 6;
    for (int i = 0; i < n; i++) c->tabs[i] = stops[i];
    c->ntabs = n;
    wnd_invalidate(w);
}

void list_clear(Window* w) {
    if (!w || w->cls != CLS_LIST) return;
    Ctl* c = C(w);
    for (int i = 0; i < c->count; i++) free(c->items[i]);
    c->count = 0;
    c->sel = -1;
    c->ltop = 0;
    list_sync_scroll(w);
    wnd_invalidate(w);
}

int list_add(Window* w, const char* s) {
    if (!w || w->cls != CLS_LIST || !s) return -1;
    Ctl* c = C(w);
    if (c->count >= c->alloc) {
        int na = c->alloc * 2;
        char** ni = (char**)realloc(c->items, sizeof(char*) * (unsigned long)na);
        if (!ni) return -1;
        c->items = ni;
        c->alloc = na;
    }
    c->items[c->count] = strdup(s);
    if (!c->items[c->count]) return -1;
    c->count++;
    list_sync_scroll(w);
    wnd_invalidate(w);
    return c->count - 1;
}

int list_count(Window* w) {
    if (!w || w->cls != CLS_LIST) return 0;
    return C(w)->count;
}

const char* list_item(Window* w, int i) {
    if (!w || w->cls != CLS_LIST) return "";
    Ctl* c = C(w);
    if (i < 0 || i >= c->count) return "";
    return c->items[i];
}

int list_sel(Window* w) {
    if (!w || w->cls != CLS_LIST) return -1;
    return C(w)->sel;
}

void list_set_sel(Window* w, int i) {
    if (!w || w->cls != CLS_LIST) return;
    Ctl* c = C(w);
    c->sel = (i >= 0 && i < c->count) ? i : -1;
    list_follow(w);
    wnd_invalidate(w);
}

void edit_set(Window* w, const char* s) {
    if (!w || w->cls != CLS_EDIT) return;
    Ctl* c = C(w);
    int i = 0;
    if (s) while (s[i] && i < c->cap - 1) { c->text[i] = s[i]; i++; }
    c->text[i] = 0;
    c->len = i;
    c->caret = i;
    c->top = 0;
    edit_follow(w);
    wnd_invalidate(w);
}

const char* edit_get(Window* w) {
    if (!w || w->cls != CLS_EDIT) return "";
    return C(w)->text;
}

void edit_append(Window* w, const char* s) {
    if (!w || w->cls != CLS_EDIT || !s) return;
    Ctl* c = C(w);
    int i = 0;
    while (s[i] && c->len < c->cap - 1) c->text[c->len++] = s[i++];
    c->text[c->len] = 0;
    c->caret = c->len;
    edit_follow(w);
    wnd_invalidate(w);
}

int edit_len(Window* w) {
    if (!w || w->cls != CLS_EDIT) return 0;
    return C(w)->len;
}

void edit_set_caret(Window* w, int pos) {
    if (!w || w->cls != CLS_EDIT) return;
    Ctl* c = C(w);
    c->caret = iclamp(pos, 0, c->len);
    edit_follow(w);
    wnd_invalidate(w);
}
