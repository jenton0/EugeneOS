#include "win.h"

/* ============================================================
 * EUGENE GUI — ВІКОННИЙ МЕНЕДЖЕР
 *
 * Що тут відбувається за один кадр:
 *   1) знімаємо курсор з буфера кадру;
 *   2) розбираємо події від ядра і роздаємо їх вікнам;
 *   3) перемальовуємо ЛИШЕ недійсні ділянки, знизу вгору
 *      за порядком вікон;
 *   4) кладемо курсор назад і виводимо недійсні ділянки на екран.
 *
 * Порядок пунктів 1 і 3 не переставляти: курсор лежить у тому
 * самому буфері, і якщо малювати під ним, він розмажеться слідом.
 * ============================================================ */

#define WM_MAX_WINDOWS  96
#define INVAL_MAX       24

static Window  g_pool[WM_MAX_WINDOWS];
static Window* g_z[WM_MAX_WINDOWS];      /* 0 — найнижче, n-1 — найвище */
static int     g_zn = 0;

static Window* g_active  = 0;
static Window* g_focus   = 0;
static Window* g_capture = 0;
static Window* g_modal   = 0;

static uint32_t g_desk_color = GUI_DESKTOP;
static WndProc  g_desk_proc  = 0;
static int      g_quit = 0;

/* --- Недійсні ділянки екрана --- */
static GuiRect g_inval[INVAL_MAX];
static int     g_inval_n = 0;
static int     g_inval_all = 1;

/* --- Перетягування та зміна розміру контуром --- */
static int     g_track = 0;          /* 0 нема, 1 перенос, 2 розмір */
static int     g_track_ht = 0;
static int     g_track_dx = 0, g_track_dy = 0;
static GuiRect g_track_rect;
static Window* g_track_win = 0;

/* --- Перетягування повзунка смуги прокрутки --- */
static int     g_sb_drag = 0;        /* 0 нема, 1 вертикальна, 2 горизонтальна */
static int     g_sb_grab = 0;
static Window* g_sb_win = 0;

static int g_cursor_want = GUI_CUR_ARROW;

/* ============================================================
 * ДРІБНИЦІ
 * ============================================================ */

static int imax(int a, int b) { return a > b ? a : b; }
static int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void str_set(char* dst, int cap, const char* src) {
    int i = 0;
    if (!src) { dst[0] = 0; return; }
    while (src[i] && i < cap - 1) { dst[i] = src[i]; i++; }
    dst[i] = 0;
}

int wm_should_quit(void) { return g_quit; }
void wm_quit(void) { g_quit = 1; }
void wm_set_desktop(uint32_t c) { g_desk_color = c; g_inval_all = 1; }
void wm_set_desktop_proc(WndProc p) { g_desk_proc = p; g_inval_all = 1; }

/* ============================================================
 * НЕДІЙСНІ ДІЛЯНКИ
 * ============================================================ */

void wm_invalidate_screen(const GuiRect* r) {
    if (g_inval_all || !r || r->w <= 0 || r->h <= 0) return;
    GuiRect scr = { 0, 0, gui_width(), gui_height() };
    GuiRect c;
    if (!gui_rect_isect(r, &scr, &c)) return;

    for (int i = 0; i < g_inval_n; i++) {
        GuiRect* d = &g_inval[i];
        if (c.x >= d->x && c.y >= d->y &&
            c.x + c.w <= d->x + d->w && c.y + c.h <= d->y + d->h) return;
    }
    if (g_inval_n < INVAL_MAX) { g_inval[g_inval_n++] = c; return; }

    /* Список переповнено — злипаємось у все. Гірше за точний облік,
       але ніколи не губить оновлень. */
    g_inval_all = 1;
    g_inval_n = 0;
}

/* Позначити лише чотири смуги по краях прямокутника — для контуру
   перетягування, який займає периметр, а не всю площу. */
static void inval_frame(const GuiRect* r, int t) {
    GuiRect s;
    s.x = r->x; s.y = r->y;              s.w = r->w; s.h = t;      wm_invalidate_screen(&s);
    s.x = r->x; s.y = r->y + r->h - t;   s.w = r->w; s.h = t;      wm_invalidate_screen(&s);
    s.x = r->x; s.y = r->y;              s.w = t;    s.h = r->h;   wm_invalidate_screen(&s);
    s.x = r->x + r->w - t; s.y = r->y;   s.w = t;    s.h = r->h;   wm_invalidate_screen(&s);
}

void wnd_invalidate(Window* w) {
    if (!w || !w->used || !w->visible) return;
    wm_invalidate_screen(&w->r);
}

void wnd_invalidate_client(Window* w) {
    if (!w || !w->used || !w->visible) return;
    GuiRect c; wnd_client_rect(w, &c);
    wm_invalidate_screen(&c);
}

void wnd_invalidate_area(Window* w, int cx, int cy, int cw, int ch) {
    if (!w || !w->used || !w->visible) return;
    GuiRect c; wnd_client_rect(w, &c);
    GuiRect a = { c.x + cx, c.y + cy, cw, ch };
    GuiRect out;
    if (gui_rect_isect(&a, &c, &out)) wm_invalidate_screen(&out);
}

/* ============================================================
 * ГЕОМЕТРІЯ
 * ============================================================ */

static int border_of(const Window* w) {
    if (w->style & WS_SIZEBOX) return WMET_BORDER;
    if (w->style & WS_BORDER)  return 1;
    return 0;
}

static int title_of(const Window* w) {
    return (w->style & WS_TITLE) ? WMET_TITLE : 0;
}

static int menu_of(const Window* w) {
    return (w->menu && w->menu->count > 0) ? WMET_MENU : 0;
}

void wnd_client_rect(const Window* w, GuiRect* out) {
    int b = border_of(w);
    int t = title_of(w);
    int m = menu_of(w);
    int e = (w->style & WS_CLIENTEDGE) ? 2 : 0;

    out->x = w->r.x + b + e;
    out->y = w->r.y + b + t + m + e;
    out->w = w->r.w - 2 * b - 2 * e - ((w->style & WS_VSCROLL) ? WMET_SB : 0);
    out->h = w->r.h - 2 * b - t - m - 2 * e - ((w->style & WS_HSCROLL) ? WMET_SB : 0);
    if (out->w < 0) out->w = 0;
    if (out->h < 0) out->h = 0;
}

void wnd_client_size(const Window* w, int* cw, int* ch) {
    GuiRect c; wnd_client_rect(w, &c);
    if (cw) *cw = c.w;
    if (ch) *ch = c.h;
}

void wnd_menubar_rect(const Window* w, GuiRect* out) {
    int b = border_of(w);
    out->x = w->r.x + b;
    out->y = w->r.y + b + title_of(w);
    out->w = w->r.w - 2 * b;
    out->h = menu_of(w);
}

/* Прямокутники смуг прокрутки в екранних координатах */
static void vs_rect(const Window* w, GuiRect* out) {
    int b = border_of(w), t = title_of(w), m = menu_of(w);
    out->x = w->r.x + w->r.w - b - WMET_SB;
    out->y = w->r.y + b + t + m;
    out->w = WMET_SB;
    out->h = w->r.h - 2 * b - t - m - ((w->style & WS_HSCROLL) ? WMET_SB : 0);
    if (out->h < 0) out->h = 0;
}

static void hs_rect(const Window* w, GuiRect* out) {
    int b = border_of(w);
    out->x = w->r.x + b;
    out->y = w->r.y + w->r.h - b - WMET_SB;
    out->w = w->r.w - 2 * b - ((w->style & WS_VSCROLL) ? WMET_SB : 0);
    out->h = WMET_SB;
    if (out->w < 0) out->w = 0;
}

/* Кнопки заголовка. slot: 0 — найправіша. */
static void title_btn(const Window* w, int slot, GuiRect* out) {
    int b = border_of(w);
    out->w = WMET_BTN;
    out->h = WMET_BTN;
    out->x = w->r.x + w->r.w - b - 3 - (slot + 1) * (WMET_BTN + 2) + 2;
    out->y = w->r.y + b + (WMET_TITLE - WMET_BTN) / 2;
}

static void sysmenu_rect(const Window* w, GuiRect* out) {
    int b = border_of(w);
    out->x = w->r.x + b + 3;
    out->y = w->r.y + b + (WMET_TITLE - WMET_BTN) / 2;
    out->w = WMET_BTN;
    out->h = WMET_BTN;
}

int wnd_hittest(Window* w, int sx, int sy) {
    if (!gui_rect_has(&w->r, sx, sy)) return HT_NONE;

    int b = border_of(w);
    int t = title_of(w);
    int m = menu_of(w);

    /* Рамка зміни розміру — лише якщо вікно взагалі можна тягнути */
    if ((w->style & WS_SIZEBOX) && !w->maximized) {
        int L = sx < w->r.x + b;
        int R = sx >= w->r.x + w->r.w - b;
        int T = sy < w->r.y + b;
        int B = sy >= w->r.y + w->r.h - b;
        int corner = 12;
        int cL = sx < w->r.x + corner;
        int cR = sx >= w->r.x + w->r.w - corner;
        int cT = sy < w->r.y + corner;
        int cB = sy >= w->r.y + w->r.h - corner;
        if ((T || L) && cT && cL) return HT_TOPLEFT;
        if ((T || R) && cT && cR) return HT_TOPRIGHT;
        if ((B || L) && cB && cL) return HT_BOTLEFT;
        if ((B || R) && cB && cR) return HT_BOTRIGHT;
        if (L) return HT_LEFT;
        if (R) return HT_RIGHT;
        if (T) return HT_TOP;
        if (B) return HT_BOTTOM;
    }

    if (t) {
        GuiRect tr = { w->r.x + b, w->r.y + b, w->r.w - 2 * b, t };
        if (gui_rect_has(&tr, sx, sy)) {
            GuiRect q;
            if (w->style & WS_SYSMENU) {
                sysmenu_rect(w, &q);
                if (gui_rect_has(&q, sx, sy)) return HT_SYSMENU;
            }
            int slot = 0;
            if (w->style & WS_MAXBOX) {
                title_btn(w, slot++, &q);
                if (gui_rect_has(&q, sx, sy)) return HT_MAX;
            }
            if (w->style & WS_MINBOX) {
                title_btn(w, slot++, &q);
                if (gui_rect_has(&q, sx, sy)) return HT_MIN;
            }
            return HT_CAPTION;
        }
    }

    if (m) {
        GuiRect mr = { w->r.x + b, w->r.y + b + t, w->r.w - 2 * b, m };
        if (gui_rect_has(&mr, sx, sy)) return HT_MENU;
    }

    if (w->style & WS_VSCROLL) {
        GuiRect q; vs_rect(w, &q);
        if (gui_rect_has(&q, sx, sy)) return HT_VSCROLL;
    }
    if (w->style & WS_HSCROLL) {
        GuiRect q; hs_rect(w, &q);
        if (gui_rect_has(&q, sx, sy)) return HT_HSCROLL;
    }
    return HT_CLIENT;
}

/* ============================================================
 * СТВОРЕННЯ ТА ПОРЯДОК
 * ============================================================ */

int wm_init(void) {
    if (!gui_init()) return 0;
    memset(g_pool, 0, sizeof(g_pool));
    g_zn = 0;
    g_active = 0; g_focus = 0; g_capture = 0; g_modal = 0;
    g_inval_all = 1;
    g_quit = 0;
    return 1;
}

static Window* pool_alloc(void) {
    for (int i = 0; i < WM_MAX_WINDOWS; i++)
        if (!g_pool[i].used) {
            memset(&g_pool[i], 0, sizeof(Window));
            g_pool[i].used = 1;
            return &g_pool[i];
        }
    return 0;
}

static void z_add(Window* w) {
    if (g_zn >= WM_MAX_WINDOWS) return;
    g_z[g_zn++] = w;
}

static void z_remove(Window* w) {
    for (int i = 0; i < g_zn; i++)
        if (g_z[i] == w) {
            for (int j = i; j < g_zn - 1; j++) g_z[j] = g_z[j + 1];
            g_zn--;
            return;
        }
}

void wnd_to_top(Window* w) {
    if (!w || (w->style & WS_CHILD)) return;
    z_remove(w);
    z_add(w);
    wnd_invalidate(w);
}

Window* wnd_create(const char* title, unsigned style,
                   int x, int y, int w, int h, WndProc proc, void* data) {
    Window* p = pool_alloc();
    if (!p) return 0;
    p->r.x = x; p->r.y = y; p->r.w = w; p->r.h = h;
    p->restore = p->r;
    str_set(p->title, sizeof(p->title), title);
    p->style = style;
    p->proc = proc;
    p->data = data;
    p->visible = 1;
    p->min_w = 120;
    p->min_h = 60;
    p->focusable = 1;
    z_add(p);
    wnd_send(p, WM_CREATE, 0, 0);
    if (!(style & WS_POPUP)) wnd_activate(p);
    wnd_invalidate(p);
    return p;
}

static void child_place(Window* c) {
    GuiRect pc;
    wnd_client_rect(c->parent, &pc);
    c->r.x = pc.x + c->rel_x;
    c->r.y = pc.y + c->rel_y;
}

Window* wnd_create_child(Window* parent, int id, unsigned style, int ctl_style,
                         const char* text, int x, int y, int w, int h,
                         WndProc proc, void* data) {
    if (!parent) return 0;
    Window* c = pool_alloc();
    if (!c) return 0;
    c->parent = parent;
    c->id = id;
    c->style = style | WS_CHILD;
    c->ctl_style = ctl_style;
    c->rel_x = x; c->rel_y = y;
    c->r.w = w; c->r.h = h;
    str_set(c->title, sizeof(c->title), text);
    c->proc = proc;
    c->data = data;
    c->visible = 1;
    child_place(c);
    wnd_send(c, WM_CREATE, 0, 0);
    return c;
}

/* Діти вікна — у порядку створення в пулі */
static int child_first(Window* parent, int from, Window** out) {
    for (int i = from; i < WM_MAX_WINDOWS; i++)
        if (g_pool[i].used && g_pool[i].parent == parent) {
            *out = &g_pool[i];
            return i + 1;
        }
    return -1;
}

/* Обхід дітей: after=0 — перша дитина. Потрібен, наприклад,
   перемикачам, щоб гасити сусідів по групі. */
Window* wnd_next_child(Window* parent, Window* after) {
    int start = 0;
    if (after) start = (int)(after - g_pool) + 1;
    Window* c;
    if (child_first(parent, start, &c) > 0) return c;
    return 0;
}

Window* wnd_child_by_id(Window* parent, int id) {
    Window* c; int it = 0;
    while ((it = child_first(parent, it, &c)) > 0)
        if (c->id == id) return c;
    return 0;
}

void wnd_destroy(Window* w) {
    if (!w || !w->used) return;

    /* Спершу діти: інакше вони лишаться сиротами в пулі */
    Window* c; int it = 0;
    while ((it = child_first(w, it, &c)) > 0) { wnd_destroy(c); it = 0; }

    wnd_send(w, WM_DESTROY, 0, 0);
    wnd_invalidate(w);
    z_remove(w);
    if (g_active  == w) g_active = 0;
    if (g_focus   == w) g_focus = 0;
    if (g_capture == w) g_capture = 0;
    if (g_modal   == w) g_modal = 0;
    if (g_track_win == w) { g_track = 0; g_track_win = 0; }
    if (g_sb_win == w) { g_sb_drag = 0; g_sb_win = 0; }
    w->used = 0;

    /* Активним стає верхнє з тих, що лишились */
    if (!g_active) {
        for (int i = g_zn - 1; i >= 0; i--)
            if (g_z[i]->visible && !(g_z[i]->style & WS_POPUP)) {
                wnd_activate(g_z[i]);
                break;
            }
    }
}

void wnd_show(Window* w, int visible) {
    if (!w || !w->used) return;
    if (w->visible == visible) return;
    wnd_invalidate(w);
    w->visible = visible;
    wnd_invalidate(w);
    if (!visible && g_active == w) g_active = 0;
}

void wnd_set_title(Window* w, const char* t) {
    if (!w) return;
    str_set(w->title, sizeof(w->title), t);
    wnd_invalidate(w);
}

void wnd_enable(Window* w, int on) {
    if (!w) return;
    if (on) w->style &= ~WS_DISABLED;
    else    w->style |=  WS_DISABLED;
    wnd_invalidate(w);
}

Window* wnd_active(void) { return g_active; }

void wnd_activate(Window* w) {
    if (!w || (w->style & (WS_CHILD | WS_POPUP))) return;
    if (g_active == w) { wnd_to_top(w); return; }
    if (g_active) {
        wnd_send(g_active, WM_ACTIVATE, 0, 0);
        wnd_invalidate(g_active);
    }
    g_active = w;
    w->minimized = 0;
    wnd_to_top(w);
    wnd_send(w, WM_ACTIVATE, 1, 0);

    /* Фокус — першому здатному його взяти елементу, інакше самому вікну */
    Window* c; int it = 0; Window* first = 0;
    while ((it = child_first(w, it, &c)) > 0)
        if (c->focusable && c->visible && !(c->style & WS_DISABLED)) { first = c; break; }
    wnd_focus(first ? first : w);
}

void wnd_focus(Window* w) {
    if (g_focus == w) return;
    if (g_focus) { wnd_send(g_focus, WM_KILLFOCUS, 0, 0); wnd_invalidate(g_focus); }
    g_focus = w;
    if (g_focus) { wnd_send(g_focus, WM_SETFOCUS, 0, 0); wnd_invalidate(g_focus); }
}

Window* wnd_get_focus(void) { return g_focus; }
void wnd_capture(Window* w) { g_capture = w; }
void wnd_release(void) { g_capture = 0; }

/* ============================================================
 * ЗГОРТАННЯ, РОЗГОРТАННЯ, ГЕОМЕТРІЯ
 * ============================================================ */

/* Згорнуте вікно у Windows 3.1 ставало піктограмою на робочому
   столі, а не кнопкою на панелі. Місце піктограми рахуємо за
   порядковим номером серед згорнутих. */
#define ICO_W 72
#define ICO_H 56

/* Номер місця піктограми закріплюється за вікном при згортанні і
   тримається у полі icon.

   Раніше він рахувався з позиції вікна в порядку Z — і піктограма
   стрибала на інше місце від самого лише кліку, бо клік піднімає
   вікно нагору. Другий клік подвійного тоді влучав уже в порожній
   стіл, і згорнуте вікно неможливо було відновити. */
static int icon_slot_take(Window* w) {
    for (int s = 0; s < 64; s++) {
        int busy = 0;
        for (int i = 0; i < g_zn; i++)
            if (g_z[i] != w && g_z[i]->minimized && g_z[i]->icon == s) { busy = 1; break; }
        if (!busy) return s;
    }
    return 0;
}

static void icon_slot(Window* w, GuiRect* out) {
    int per_row = imax(1, gui_width() / ICO_W);
    int n = w->icon;
    out->w = ICO_W;
    out->h = ICO_H;
    out->x = (n % per_row) * ICO_W + 6;
    out->y = gui_height() - ICO_H - 6 - (n / per_row) * ICO_H;
}

void wnd_minimize(Window* w, int on) {
    if (!w || w->minimized == on) return;
    wnd_invalidate(w);
    if (on) {
        w->icon = icon_slot_take(w);
        w->minimized = 1;
        if (g_active == w) g_active = 0;
        if (g_focus && (g_focus == w || g_focus->parent == w)) wnd_focus(0);
    } else {
        w->minimized = 0;
        wnd_activate(w);
    }
    g_inval_all = 1;    /* піктограми зсуваються — простіше перемалювати все */
}

void wnd_maximize(Window* w, int on) {
    if (!w || w->maximized == on) return;
    wnd_invalidate(w);
    if (on) {
        w->restore = w->r;
        w->r.x = 0; w->r.y = 0;
        w->r.w = gui_width();
        w->r.h = gui_height();
    } else {
        w->r = w->restore;
    }
    w->maximized = on;

    Window* c; int it = 0;
    while ((it = child_first(w, it, &c)) > 0) child_place(c);

    int cw, ch; wnd_client_size(w, &cw, &ch);
    wnd_send(w, WM_SIZE, cw, ch);
    wnd_invalidate(w);
}

void wnd_move(Window* w, int x, int y, int cw, int ch) {
    if (!w) return;
    wnd_invalidate(w);
    int moved  = (x != w->r.x || y != w->r.y);
    int resized = (cw != w->r.w || ch != w->r.h);
    w->r.x = x; w->r.y = y; w->r.w = cw; w->r.h = ch;

    Window* c; int it = 0;
    while ((it = child_first(w, it, &c)) > 0) child_place(c);

    if (moved)  wnd_send(w, WM_MOVE, x, y);
    if (resized) {
        int a, b; wnd_client_size(w, &a, &b);
        wnd_send(w, WM_SIZE, a, b);
    }
    wnd_invalidate(w);
}

void wnd_move_child(Window* c, int x, int y, int w, int h) {
    if (!c || !(c->style & WS_CHILD)) return;
    wnd_invalidate(c);
    c->rel_x = x; c->rel_y = y;
    c->r.w = w;  c->r.h = h;
    child_place(c);
    wnd_send(c, WM_SIZE, w, h);
    wnd_invalidate(c);
}

void wnd_set_scroll(Window* w, int vert, int pos, int max, int page) {
    if (!w) return;
    if (max < 0) max = 0;
    if (page < 1) page = 1;
    pos = iclamp(pos, 0, max);
    if (vert) { w->vs_pos = pos; w->vs_max = max; w->vs_page = page; }
    else      { w->hs_pos = pos; w->hs_max = max; w->hs_page = page; }
    wnd_invalidate(w);
}

int wnd_get_scroll(Window* w, int vert) {
    if (!w) return 0;
    return vert ? w->vs_pos : w->hs_pos;
}

/* ============================================================
 * ПОШУК ВІКНА ПІД ТОЧКОЮ
 * ============================================================ */

Window* wnd_from_point(int sx, int sy) {
    for (int i = g_zn - 1; i >= 0; i--) {
        Window* w = g_z[i];
        if (!w->visible) continue;
        if (w->minimized) {
            GuiRect ic; icon_slot(w, &ic);
            if (gui_rect_has(&ic, sx, sy)) return w;
            continue;
        }
        if (gui_rect_has(&w->r, sx, sy)) return w;
    }
    return 0;
}

static Window* child_from_point(Window* parent, int sx, int sy) {
    Window* c; int it = 0; Window* found = 0;
    while ((it = child_first(parent, it, &c)) > 0)
        if (c->visible && gui_rect_has(&c->r, sx, sy)) found = c;  /* пізніший зверху */
    return found;
}

/* ============================================================
 * МАЛЮВАННЯ
 * ============================================================ */

static void draw_title_glyph(int ht, const GuiRect* q) {
    int cx = q->x + q->w / 2;
    int cy = q->y + q->h / 2;
    if (ht == HT_SYSMENU) {
        gui_fill(q->x + 3, cy - 1, q->w - 6, 3, GUI_DKSHADOW);
    } else if (ht == HT_MIN) {
        gui_fill(cx - 3, q->y + q->h - 5, 7, 3, GUI_DKSHADOW);
        gui_line(cx - 3, q->y + q->h - 6, cx + 3, q->y + q->h - 6, GUI_DKSHADOW);
    } else if (ht == HT_MAX) {
        gui_frame(cx - 4, cy - 4, 9, 9, GUI_DKSHADOW);
        gui_hline(cx - 4, cy - 3, 9, GUI_DKSHADOW);
    }
}

static void draw_scrollbar(Window* w, int vert) {
    GuiRect q;
    if (vert) vs_rect(w, &q); else hs_rect(w, &q);
    if (q.w <= 0 || q.h <= 0) return;

    int pos  = vert ? w->vs_pos  : w->hs_pos;
    int max  = vert ? w->vs_max  : w->hs_max;
    int page = vert ? w->vs_page : w->hs_page;

    gui_fill_rect(&q, 0x00E0E0E0);

    /* Кнопки-стрілки на кінцях */
    int bs = WMET_SB;
    GuiRect a1, a2;
    if (vert) {
        a1.x = q.x; a1.y = q.y;              a1.w = bs; a1.h = bs;
        a2.x = q.x; a2.y = q.y + q.h - bs;   a2.w = bs; a2.h = bs;
    } else {
        a1.x = q.x;              a1.y = q.y; a1.w = bs; a1.h = bs;
        a2.x = q.x + q.w - bs;   a2.y = q.y; a2.w = bs; a2.h = bs;
    }
    gui_fill_rect(&a1, GUI_FACE); gui_bevel2(a1.x, a1.y, a1.w, a1.h, 1);
    gui_fill_rect(&a2, GUI_FACE); gui_bevel2(a2.x, a2.y, a2.w, a2.h, 1);

    /* Трикутники */
    for (int i = 0; i < 4; i++) {
        if (vert) {
            gui_hline(a1.x + bs / 2 - i, a1.y + bs / 2 - 2 + i, i * 2 + 1, GUI_DKSHADOW);
            gui_hline(a2.x + bs / 2 - (3 - i), a2.y + bs / 2 - 2 + i, (3 - i) * 2 + 1, GUI_DKSHADOW);
        } else {
            gui_vline(a1.x + bs / 2 - 2 + i, a1.y + bs / 2 - i, i * 2 + 1, GUI_DKSHADOW);
            gui_vline(a2.x + bs / 2 - 2 + i, a2.y + bs / 2 - (3 - i), (3 - i) * 2 + 1, GUI_DKSHADOW);
        }
    }

    if (max <= 0) return;

    /* Повзунок */
    int track = (vert ? q.h : q.w) - 2 * bs;
    if (track < 12) return;
    int total = max + page;
    int th = imax(10, track * page / imax(1, total));
    int ty = (track - th) * pos / imax(1, max);

    if (vert) {
        gui_fill(q.x, q.y + bs + ty, q.w, th, GUI_FACE);
        gui_bevel2(q.x, q.y + bs + ty, q.w, th, 1);
    } else {
        gui_fill(q.x + bs + ty, q.y, th, q.h, GUI_FACE);
        gui_bevel2(q.x + bs + ty, q.y, th, q.h, 1);
    }
}

static void draw_nc(Window* w) {
    int b = border_of(w);
    int t = title_of(w);

    /* Зовнішня рамка */
    if (b > 0) {
        gui_fill_rect(&w->r, GUI_FACE);
        gui_frame(w->r.x, w->r.y, w->r.w, w->r.h, GUI_DKSHADOW);
        if (b > 1) {
            gui_bevel(w->r.x + 1, w->r.y + 1, w->r.w - 2, w->r.h - 2, 1);
            gui_bevel(w->r.x + b - 1, w->r.y + b - 1,
                      w->r.w - 2 * b + 2, w->r.h - 2 * b + 2, 0);
        }
    }

    /* Заголовок */
    if (t) {
        int act = (w == g_active);
        GuiRect tr = { w->r.x + b, w->r.y + b, w->r.w - 2 * b, t };
        gui_fill_rect(&tr, act ? GUI_TITLE_ACT : GUI_TITLE_INACT);

        int tx = tr.x + 4;
        if (w->style & WS_SYSMENU) {
            GuiRect q; sysmenu_rect(w, &q);
            gui_fill_rect(&q, GUI_FACE);
            gui_bevel2(q.x, q.y, q.w, q.h, 1);
            draw_title_glyph(HT_SYSMENU, &q);
            tx = q.x + q.w + 5;
        }

        int right = tr.x + tr.w - 4;
        int slot = 0;
        if (w->style & WS_MAXBOX) {
            GuiRect q; title_btn(w, slot++, &q);
            gui_fill_rect(&q, GUI_FACE);
            gui_bevel2(q.x, q.y, q.w, q.h, 1);
            draw_title_glyph(HT_MAX, &q);
            right = q.x - 4;
        }
        if (w->style & WS_MINBOX) {
            GuiRect q; title_btn(w, slot++, &q);
            gui_fill_rect(&q, GUI_FACE);
            gui_bevel2(q.x, q.y, q.w, q.h, 1);
            draw_title_glyph(HT_MIN, &q);
            right = q.x - 4;
        }

        gui_text_clip(w->title, tx, tr.y + (t - GUI_FONT_H) / 2 + 1, right, GUI_TITLE_TEXT);
    }

    if (menu_of(w)) menu_bar_draw(w);

    /* Втиснута рамка навколо робочої області */
    if (w->style & WS_CLIENTEDGE) {
        GuiRect c; wnd_client_rect(w, &c);
        gui_bevel2(c.x - 2, c.y - 2, c.w + 4, c.h + 4, 0);
    }

    if (w->style & WS_VSCROLL) draw_scrollbar(w, 1);
    if (w->style & WS_HSCROLL) draw_scrollbar(w, 0);

    /* Куточок між смугами */
    if ((w->style & WS_VSCROLL) && (w->style & WS_HSCROLL)) {
        GuiRect v, h; vs_rect(w, &v); hs_rect(w, &h);
        gui_fill(v.x, h.y, WMET_SB, WMET_SB, GUI_FACE);
    }
}

static void draw_icon(Window* w) {
    GuiRect ic; icon_slot(w, &ic);
    gui_fill(ic.x + 20, ic.y + 4, 32, 28, GUI_FACE);
    gui_bevel2(ic.x + 20, ic.y + 4, 32, 28, 1);
    gui_fill(ic.x + 25, ic.y + 9, 22, 5, GUI_TITLE_ACT);
    gui_fill(ic.x + 25, ic.y + 16, 22, 12, GUI_WINDOW_BG);

    int tw = gui_text_w(w->title);
    int tx = ic.x + (ic.w - tw) / 2;
    if (tw > ic.w) tx = ic.x;
    gui_text_clip(w->title, tx, ic.y + 38, ic.x + ic.w, GUI_TITLE_TEXT);
}

static void paint_child(Window* c, const GuiRect* dirty) {
    if (!c->visible) return;
    GuiRect out;
    if (!gui_rect_isect(&c->r, dirty, &out)) return;
    if (!gui_clip_push(&c->r)) { gui_clip_pop(); return; }

    /* Елемент проходить той самий шлях, що й вікно: спершу неробоча
       область (втиснута рамка, смуга прокрутки), потім вміст із
       обрізанням по робочій області. Тому смуга прокрутки списку
       і поля вводу малюється тим самим кодом, що й у вікна. */
    wnd_send(c, WM_NCPAINT, 0, 0);
    GuiRect cc; wnd_client_rect(c, &cc);
    if (gui_clip_push(&cc)) wnd_send(c, WM_PAINT, 0, 0);
    gui_clip_pop();
    gui_clip_pop();
}

static void paint_window(Window* w, const GuiRect* dirty) {
    if (w->minimized) {
        GuiRect ic; icon_slot(w, &ic);
        GuiRect out;
        if (!gui_rect_isect(&ic, dirty, &out)) return;
        if (!gui_clip_push(&ic)) { gui_clip_pop(); return; }
        draw_icon(w);
        gui_clip_pop();
        return;
    }

    GuiRect out;
    if (!gui_rect_isect(&w->r, dirty, &out)) return;

    if (!gui_clip_push(&w->r)) { gui_clip_pop(); return; }
    wnd_send(w, WM_NCPAINT, 0, 0);

    GuiRect c; wnd_client_rect(w, &c);
    if (gui_clip_push(&c)) {
        if (!(w->style & WS_NOBKGND)) wnd_send(w, WM_ERASEBKGND, 0, 0);
        wnd_send(w, WM_PAINT, 0, 0);
        Window* ch; int it = 0;
        while ((it = child_first(w, it, &ch)) > 0) paint_child(ch, dirty);
    }
    gui_clip_pop();
    gui_clip_pop();
}

/* Чи накриває outer весь inner цілком */
static int rect_covers(const GuiRect* outer, const GuiRect* inner) {
    return inner->x >= outer->x && inner->y >= outer->y &&
           inner->x + inner->w <= outer->x + outer->w &&
           inner->y + inner->h <= outer->y + outer->h;
}

static void paint_pass(const GuiRect* dirty) {
    gui_clip_reset();
    if (!gui_clip_push(dirty)) { gui_clip_pop(); return; }

    /* Найвище непрозоре вікно, яке ПОВНІСТЮ накриває брудний
       прямокутник, робить усе під собою марною роботою.

       Поки кадр перемальовували раз на подію, це нічого не важило.
       Вікно з грою просить перемалювання двадцять разів на секунду -
       і під ним щоразу наново малювався дифузійний стіл, а за ним
       значки диспетчера програм, яких там однаково не видно.

       Непрозорим вважаємо вікно з рамкою: воно малює і рамку, і всю
       робочу область, тобто свій прямокутник закриває цілком. */
    int first = -1;
    for (int i = g_zn - 1; i >= 0; i--) {
        Window* w = g_z[i];
        if (!w->visible) continue;
        if (!(w->style & WS_BORDER)) continue;
        if (rect_covers(&w->r, dirty)) { first = i; break; }
    }

    if (first < 0) {
        first = 0;
        /* Робочий стіл */
        if (g_desk_proc) g_desk_proc(0, WM_PAINT, 0, 0);
        else             gui_fill_rect(dirty, g_desk_color);
    }

    for (int i = first; i < g_zn; i++)
        if (g_z[i]->visible) paint_window(g_z[i], dirty);

    gui_clip_pop();
    gui_invalidate_rect(dirty);
}

static void paint_all(void) {
    if (g_inval_all) {
        GuiRect full = { 0, 0, gui_width(), gui_height() };
        paint_pass(&full);
        gui_invalidate_all();
        g_inval_all = 0;
        g_inval_n = 0;
        return;
    }
    for (int i = 0; i < g_inval_n; i++) paint_pass(&g_inval[i]);
    g_inval_n = 0;
}

/* ============================================================
 * ОБРОБНИК ЗА ЗАМОВЧУВАННЯМ
 * ============================================================ */

long def_window_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_NCPAINT:
        draw_nc(w);
        return 0;

    case WM_ERASEBKGND: {
        GuiRect c; wnd_client_rect(w, &c);
        gui_fill_rect(&c, (w->style & WS_CHILD) ? GUI_FACE : GUI_WINDOW_BG);
        return 0;
    }

    case WM_CLOSE:
        wnd_destroy(w);
        return 0;

    case WM_KEYDOWN:
        /* Tab обходить елементи керування — без цього з клавіатури
           до кнопок і полів просто не дістатися. */
        if (a == 0x0F && !(w->style & WS_CHILD)) {
            Window* c; int it = 0;
            Window* first = 0; Window* prev = 0; Window* next = 0;
            Window* cur = g_focus;
            int seen = 0;
            while ((it = child_first(w, it, &c)) > 0) {
                if (!c->focusable || !c->visible || (c->style & WS_DISABLED)) continue;
                if (!first) first = c;
                if (seen && !next) next = c;
                if (c == cur) seen = 1;
                if (!seen) prev = c;
            }
            if (b & KEY_MOD_SHIFT) wnd_focus(prev ? prev : first);
            else                   wnd_focus(next ? next : first);
            return 0;
        }
        return 0;

    case WM_VSCROLL:
        wnd_set_scroll(w, 1, (int)b, w->vs_max, w->vs_page);
        return 0;
    case WM_HSCROLL:
        wnd_set_scroll(w, 0, (int)b, w->hs_max, w->hs_page);
        return 0;

    case WM_MOUSEWHEEL:
        if (w->style & WS_VSCROLL) {
            int np = iclamp(w->vs_pos - (int)a * 3, 0, w->vs_max);
            if (np != w->vs_pos) {
                wnd_send(w, WM_VSCROLL, SB_THUMB, np);
                wnd_invalidate(w);
            }
        }
        return 0;

    default:
        return 0;
    }
}

long wnd_send(Window* w, int msg, long a, long b) {
    if (!w || !w->used) return 0;
    if (w->proc) return w->proc(w, msg, a, b);
    return def_window_proc(w, msg, a, b);
}

/* ============================================================
 * ОБРОБКА МИШІ В НЕРОБОЧІЙ ОБЛАСТІ
 * ============================================================ */

static int cursor_for_ht(int ht) {
    switch (ht) {
    case HT_LEFT: case HT_RIGHT:      return GUI_CUR_SIZE_WE;
    case HT_TOP:  case HT_BOTTOM:     return GUI_CUR_SIZE_NS;
    case HT_TOPLEFT: case HT_BOTRIGHT: return GUI_CUR_SIZE_NWSE;
    case HT_TOPRIGHT: case HT_BOTLEFT: return GUI_CUR_SIZE_NESW;
    default: return GUI_CUR_ARROW;
    }
}

static void track_begin(Window* w, int mode, int ht, int sx, int sy) {
    g_track = mode;
    g_track_ht = ht;
    g_track_win = w;
    g_track_rect = w->r;
    g_track_dx = sx - w->r.x;
    g_track_dy = sy - w->r.y;
    wnd_capture(w);
    inval_frame(&g_track_rect, 3);
}

static void track_update(int sx, int sy) {
    inval_frame(&g_track_rect, 3);
    GuiRect r = g_track_win->r;

    if (g_track == 1) {
        r.x = sx - g_track_dx;
        r.y = sy - g_track_dy;
        /* Не даємо затягнути заголовок за межі екрана — інакше
           вікно вже не повернути. */
        r.x = iclamp(r.x, -r.w + 40, gui_width() - 40);
        r.y = iclamp(r.y, 0, gui_height() - WMET_TITLE - 4);
    } else {
        int x0 = r.x, y0 = r.y, x1 = r.x + r.w, y1 = r.y + r.h;
        switch (g_track_ht) {
        case HT_LEFT:     x0 = sx; break;
        case HT_RIGHT:    x1 = sx; break;
        case HT_TOP:      y0 = sy; break;
        case HT_BOTTOM:   y1 = sy; break;
        case HT_TOPLEFT:  x0 = sx; y0 = sy; break;
        case HT_TOPRIGHT: x1 = sx; y0 = sy; break;
        case HT_BOTLEFT:  x0 = sx; y1 = sy; break;
        case HT_BOTRIGHT: x1 = sx; y1 = sy; break;
        }
        if (x1 - x0 < g_track_win->min_w) {
            if (x0 != r.x) x0 = x1 - g_track_win->min_w;
            else           x1 = x0 + g_track_win->min_w;
        }
        if (y1 - y0 < g_track_win->min_h) {
            if (y0 != r.y) y0 = y1 - g_track_win->min_h;
            else           y1 = y0 + g_track_win->min_h;
        }
        r.x = x0; r.y = y0; r.w = x1 - x0; r.h = y1 - y0;
    }
    g_track_rect = r;
    inval_frame(&g_track_rect, 3);
}

static void track_end(void) {
    if (!g_track) return;
    inval_frame(&g_track_rect, 3);
    Window* w = g_track_win;
    g_track = 0;
    g_track_win = 0;
    wnd_release();
    if (w) wnd_move(w, g_track_rect.x, g_track_rect.y, g_track_rect.w, g_track_rect.h);
}

/* Клік у смугу прокрутки */
static void sb_click(Window* w, int vert, int sx, int sy) {
    GuiRect q;
    if (vert) vs_rect(w, &q); else hs_rect(w, &q);
    int bs = WMET_SB;
    int pos = vert ? w->vs_pos : w->hs_pos;
    int max = vert ? w->vs_max : w->hs_max;
    int page = vert ? w->vs_page : w->hs_page;
    int along = vert ? (sy - q.y) : (sx - q.x);
    int len   = vert ? q.h : q.w;

    if (along < bs) { wnd_send(w, vert ? WM_VSCROLL : WM_HSCROLL, SB_LINEUP, iclamp(pos - 1, 0, max)); }
    else if (along >= len - bs) { wnd_send(w, vert ? WM_VSCROLL : WM_HSCROLL, SB_LINEDOWN, iclamp(pos + 1, 0, max)); }
    else if (max > 0) {
        int track = len - 2 * bs;
        int total = max + page;
        int th = imax(10, track * page / imax(1, total));
        int ty = (track - th) * pos / imax(1, max);
        int rel = along - bs;
        if (rel < ty) {
            wnd_send(w, vert ? WM_VSCROLL : WM_HSCROLL, SB_PAGEUP, iclamp(pos - page, 0, max));
        } else if (rel >= ty + th) {
            wnd_send(w, vert ? WM_VSCROLL : WM_HSCROLL, SB_PAGEDOWN, iclamp(pos + page, 0, max));
        } else {
            g_sb_drag = vert ? 1 : 2;
            g_sb_grab = rel - ty;
            g_sb_win = w;
            wnd_capture(w);
        }
    }
    wnd_invalidate(w);
}

static void sb_drag(int sx, int sy) {
    Window* w = g_sb_win;
    if (!w) return;
    int vert = (g_sb_drag == 1);
    GuiRect q;
    if (vert) vs_rect(w, &q); else hs_rect(w, &q);
    int bs = WMET_SB;
    int max = vert ? w->vs_max : w->hs_max;
    int page = vert ? w->vs_page : w->hs_page;
    int len = vert ? q.h : q.w;
    int track = len - 2 * bs;
    int total = max + page;
    int th = imax(10, track * page / imax(1, total));
    if (track <= th) return;
    int along = (vert ? (sy - q.y) : (sx - q.x)) - bs - g_sb_grab;
    int np = iclamp(along * max / (track - th), 0, max);
    if (np != (vert ? w->vs_pos : w->hs_pos)) {
        wnd_send(w, vert ? WM_VSCROLL : WM_HSCROLL, SB_THUMB, np);
        wnd_invalidate(w);
    }
}

/* Системне меню вікна — те, що ховається за квадратиком зліва */
static void do_sysmenu(Window* w) {
    Menu* m = menu_create();
    if (!m) return;
    menu_add(m, 1, "&Restore", w->maximized ? 0 : MF_DISABLED);
    menu_add(m, 2, "&Move", 0);
    menu_add(m, 3, "&Size", (w->style & WS_SIZEBOX) ? 0 : MF_DISABLED);
    menu_add(m, 4, "Mi&nimize", (w->style & WS_MINBOX) ? 0 : MF_DISABLED);
    menu_add(m, 5, "Ma&ximize", (w->style & WS_MAXBOX) ? 0 : MF_DISABLED);
    menu_sep(m);
    menu_add(m, 6, "&Close", 0);

    int b = border_of(w);
    int id = menu_popup(m, w->r.x + b + 3, w->r.y + b + WMET_TITLE);
    menu_free(m);

    switch (id) {
    case 1: wnd_maximize(w, 0); break;
    case 4: wnd_minimize(w, 1); break;
    case 5: wnd_maximize(w, 1); break;
    case 6: wnd_send(w, WM_CLOSE, 0, 0); break;
    default: break;
    }
}

/* ============================================================
 * РОЗДАЧА ПОДІЙ
 * ============================================================ */

/* Чи належить вікно модальному ланцюжку (саме воно або його елемент) */
static int in_modal(Window* w) {
    if (!g_modal) return 1;
    while (w) {
        if (w == g_modal) return 1;
        w = w->parent;
    }
    return 0;
}

static void send_mouse(Window* target, int msg, int sx, int sy) {
    if (!target) return;
    GuiRect c;
    wnd_client_rect(target, &c);
    wnd_send(target, msg, sx - c.x, sy - c.y);
}

static void on_mouse_down(int sx, int sy, int dbl) {
    /* Захоплення сильніше за все: саме так відкрите меню бачить
       клік поза собою і встигає закритися. */
    if (g_capture) {
        send_mouse(g_capture, dbl ? WM_LBUTTONDBLCLK : WM_LBUTTONDOWN, sx, sy);
        return;
    }
    Window* top = wnd_from_point(sx, sy);
    if (!in_modal(top)) return;
    if (!top) {
        /* Клік по столу: оболонка може щось із цим зробити — у
           Windows 3.1 подвійний клік по столу відкривав список задач. */
        wnd_focus(0);
        if (g_desk_proc)
            g_desk_proc(0, dbl ? WM_LBUTTONDBLCLK : WM_LBUTTONDOWN, sx, sy);
        return;
    }

    if (top->minimized) {
        /* Windows 3.1 відновлювала піктограму подвійним кліком, але
           одинарний тут теж відновлює: інакше єдиний шлях назад
           залежить від того, чи встиг користувач у вікно часу. */
        wnd_minimize(top, 0);
        return;
    }

    if (!(top->style & WS_POPUP) && top != g_active) wnd_activate(top);

    int ht = wnd_hittest(top, sx, sy);
    switch (ht) {
    case HT_CAPTION:
        if (dbl && (top->style & WS_MAXBOX)) wnd_maximize(top, !top->maximized);
        else if (!top->maximized) track_begin(top, 1, ht, sx, sy);
        return;
    case HT_SYSMENU:
        if (dbl) wnd_send(top, WM_CLOSE, 0, 0);
        else     do_sysmenu(top);
        return;
    case HT_MIN:
        wnd_minimize(top, 1);
        return;
    case HT_MAX:
        wnd_maximize(top, !top->maximized);
        return;
    case HT_LEFT: case HT_RIGHT: case HT_TOP: case HT_BOTTOM:
    case HT_TOPLEFT: case HT_TOPRIGHT: case HT_BOTLEFT: case HT_BOTRIGHT:
        track_begin(top, 2, ht, sx, sy);
        return;
    case HT_MENU:
        menu_bar_click(top, sx, sy);
        return;
    case HT_VSCROLL:
        sb_click(top, 1, sx, sy);
        return;
    case HT_HSCROLL:
        sb_click(top, 0, sx, sy);
        return;
    default:
        break;
    }

    Window* c = child_from_point(top, sx, sy);
    Window* target = c ? c : top;
    if (c && c->focusable && !(c->style & WS_DISABLED)) wnd_focus(c);
    else if (!c) wnd_focus(top);

    /* Смуга прокрутки всередині елемента — те саме, що й у вікна */
    if (c) {
        int cht = wnd_hittest(c, sx, sy);
        if (cht == HT_VSCROLL) { sb_click(c, 1, sx, sy); return; }
        if (cht == HT_HSCROLL) { sb_click(c, 0, sx, sy); return; }
    }
    send_mouse(target, dbl ? WM_LBUTTONDBLCLK : WM_LBUTTONDOWN, sx, sy);
}

static void on_mouse_up(int sx, int sy) {
    if (g_track) { track_end(); return; }
    if (g_sb_drag) { g_sb_drag = 0; g_sb_win = 0; wnd_release(); return; }

    Window* target = g_capture;
    if (!target) {
        Window* top = wnd_from_point(sx, sy);
        if (!in_modal(top)) return;
        if (!top) return;
        Window* c = child_from_point(top, sx, sy);
        target = c ? c : top;
    }
    send_mouse(target, WM_LBUTTONUP, sx, sy);
}

static void on_mouse_move(int sx, int sy) {
    if (g_track) { track_update(sx, sy); return; }
    if (g_sb_drag) { sb_drag(sx, sy); return; }

    Window* target = g_capture;
    if (!target) {
        Window* top = wnd_from_point(sx, sy);
        if (top && in_modal(top)) {
            int ht = wnd_hittest(top, sx, sy);
            g_cursor_want = cursor_for_ht(ht);
            Window* c = child_from_point(top, sx, sy);
            target = c ? c : top;
            if (ht != HT_CLIENT && !c) { send_mouse(top, WM_MOUSEMOVE, sx, sy); return; }
        } else {
            g_cursor_want = GUI_CUR_ARROW;
            return;
        }
    }
    if (target) {
        long cur = wnd_send(target, WM_SETCURSOR, 0, 0);
        if (cur > 0) g_cursor_want = (int)cur;
        send_mouse(target, WM_MOUSEMOVE, sx, sy);
    }
}

static void on_key(const GuiEvent* e) {
    Window* t = g_focus;

    /* Поки відкрите меню або модальний діалог, клавіші мусять іти саме
       туди. Фокус при цьому лишається на вікні, яке його відкрило:
       спадний список — це WS_POPUP, він фокус не забирає. Без цієї
       перевірки стрілки, Enter, Esc і гарячі літери в меню не працювали
       взагалі — воно слухалося лише миші. */
    if (g_modal && !in_modal(t)) t = g_modal;

    if (!t) t = g_modal ? g_modal : g_active;
    if (!t) return;

    /* Alt+літера — рядок меню активного вікна */
    if ((e->mods & KEY_MOD_ALT) && e->ascii) {
        Window* top = t;
        while (top && (top->style & WS_CHILD)) top = top->parent;
        if (top && menu_bar_key(top, (char)e->ascii)) return;
    }

    wnd_send(t, WM_KEYDOWN, e->scancode, e->mods);

    /* Ctrl+C і Alt+F — це команди, а не символи. Без цієї перевірки
       поле вводу дописувало б 'c' поверх копіювання. */
    if ((e->mods & (KEY_MOD_CTRL | KEY_MOD_ALT)) == 0 &&
        e->ascii >= 32 && e->ascii < 127)
        wnd_send(t, WM_CHAR, e->ascii, e->mods);
}

/* ============================================================
 * ЦИКЛ
 * ============================================================ */

void wm_pump(void) {
    int did_work = 0;   /* чи сталося цього оберту хоч щось */
    GuiEvent e;

    /* Курсор знімається ПЕРШИМ: він лежить у буфері кадру поверх
       тла, і поки він там, малювати під ним не можна. */
    gui_cursor_erase();

    while (gui_poll(&e)) {
        did_work = 1;
        switch (e.type) {
        case GUI_EV_MOUSE_DOWN:
            if (e.button & GUI_MB_LEFT) on_mouse_down(e.x, e.y, 0);
            else if (e.button & GUI_MB_RIGHT) {
                Window* top = wnd_from_point(e.x, e.y);
                if (top && in_modal(top)) {
                    Window* c = child_from_point(top, e.x, e.y);
                    send_mouse(c ? c : top, WM_RBUTTONDOWN, e.x, e.y);
                }
            }
            break;
        case GUI_EV_MOUSE_DBL:
            on_mouse_down(e.x, e.y, 1);
            break;
        case GUI_EV_MOUSE_UP:
            if (e.button & GUI_MB_LEFT) on_mouse_up(e.x, e.y);
            break;
        case GUI_EV_MOUSE_MOVE:
            on_mouse_move(e.x, e.y);
            break;
        case GUI_EV_WHEEL: {
            Window* top = wnd_from_point(e.x, e.y);
            if (!top) top = g_active;
            if (top && in_modal(top)) {
                Window* c = child_from_point(top, e.x, e.y);
                wnd_send(c ? c : top, WM_MOUSEWHEEL, e.wheel, 0);
            }
            break;
        }
        case GUI_EV_KEY:
            on_key(&e);
            break;
        case GUI_EV_TICK:
            for (int i = 0; i < g_zn; i++)
                if (g_z[i]->visible) wnd_send(g_z[i], WM_TIMER, 0, 0);
            break;
        case GUI_EV_FRAME:
            /* Такт відео й програм у вікні. Ходить лише поки хтось
               його попросив - див. gui_frame_events().

               Перебираємо З КІНЦЯ: вікно може закритися просто в
               обробнику (програма завершилась), а видалення зсуває
               список уліво. Ідучи вперед, ми б після цього
               перестрибнули сусіда або вийшли за межу. */
            for (int i = g_zn - 1; i >= 0; i--) {
                if (i >= g_zn) continue;
                if (g_z[i]->visible) wnd_send(g_z[i], WM_FRAME, 0, 0);
            }
            break;
        default:
            break;
        }
    }

    /* Чи було цього оберту хоч щось. Знімок беремо ДО малювання:
       paint_all() список недійсних ділянок очищає. */
    int busy = did_work || g_inval_all || g_inval_n > 0 || g_track;

    /* Меню і модальні діалоги крутять власний цикл усередині
       обробки подій, і той цикл встигає покласти курсор назад.
       Тому перед малюванням знімаємо його ще раз: інакше під
       курсором лишиться застаріле тло і на екрані буде слід. */
    gui_cursor_erase();

    paint_all();

    /* Контур перетягування малюємо ПІСЛЯ всього: це XOR поверх
       готового кадру, як робила Windows 3.1. Наступний кадр
       перемалює ту смугу і контур зникне сам. */
    if (g_track) {
        gui_clip_reset();
        gui_xor_frame(g_track_rect.x, g_track_rect.y,
                      g_track_rect.w, g_track_rect.h, 3);
        GuiRect fr = g_track_rect;
        GuiRect s;
        s.x = fr.x; s.y = fr.y;            s.w = fr.w; s.h = 3;  gui_invalidate_rect(&s);
        s.x = fr.x; s.y = fr.y + fr.h - 3; s.w = fr.w; s.h = 3;  gui_invalidate_rect(&s);
        s.x = fr.x; s.y = fr.y;            s.w = 3;    s.h = fr.h; gui_invalidate_rect(&s);
        s.x = fr.x + fr.w - 3; s.y = fr.y; s.w = 3;    s.h = fr.h; gui_invalidate_rect(&s);
    }

    gui_cursor_set(g_track == 2 ? cursor_for_ht(g_track_ht) : g_cursor_want);
    gui_cursor_draw();
    gui_flush();

    /* Нічого не сталося - віддаємо решту кванта. Інакше цикл
       крутиться намарно й забирає половину процесора в програми,
       яка малює у вікно. Таймер на 1000 Гц розбудить назад. */
    if (!busy) sys_yield();
}

void wm_run(void) {
    while (!g_quit) wm_pump();
}

/* ============================================================
 * ПЕРЕЛІК ВІКОН І БУФЕР ОБМІНУ
 * ============================================================ */

int wnd_top_count(void) {
    int n = 0;
    for (int i = 0; i < g_zn; i++)
        if (!(g_z[i]->style & WS_POPUP)) n++;
    return n;
}

Window* wnd_top_at(int i) {
    /* Нумеруємо згори вниз: 0 — найвище вікно */
    int n = 0;
    for (int k = g_zn - 1; k >= 0; k--) {
        if (g_z[k]->style & WS_POPUP) continue;
        if (n == i) return g_z[k];
        n++;
    }
    return 0;
}

#define CLIP_CAP 4096
static char g_clip[CLIP_CAP];
static int  g_clip_len = 0;

void clip_set(const char* s, int len) {
    if (!s || len <= 0) { g_clip_len = 0; g_clip[0] = 0; return; }
    if (len > CLIP_CAP - 1) len = CLIP_CAP - 1;
    for (int i = 0; i < len; i++) g_clip[i] = s[i];
    g_clip[len] = 0;
    g_clip_len = len;
}

const char* clip_get(void) { return g_clip; }
int         clip_len(void) { return g_clip_len; }

/* ============================================================
 * МОДАЛЬНИЙ ЦИКЛ
 * ============================================================ */

typedef struct { int done; int result; } DlgState;

/* Стан модальності тримаємо в самому вікні через поле icon —
   воно для діалогів не використовується. */
static DlgState g_dlg[8];
static Window*  g_dlg_win[8];
static int      g_dlg_n = 0;

void dlg_end(Window* dlg, int result) {
    for (int i = 0; i < g_dlg_n; i++)
        if (g_dlg_win[i] == dlg) { g_dlg[i].done = 1; g_dlg[i].result = result; return; }
}

int dlg_modal(Window* dlg) {
    if (!dlg || g_dlg_n >= 8) return 0;
    Window* prev_modal = g_modal;
    Window* prev_active = g_active;

    int slot = g_dlg_n++;
    g_dlg_win[slot] = dlg;
    g_dlg[slot].done = 0;
    g_dlg[slot].result = 0;

    g_modal = dlg;
    wnd_to_top(dlg);
    g_active = dlg;
    wnd_send(dlg, WM_INITDIALOG, 0, 0);

    Window* c; int it = 0;
    while ((it = child_first(dlg, it, &c)) > 0)
        if (c->focusable && !(c->style & WS_DISABLED)) { wnd_focus(c); break; }

    while (!g_dlg[slot].done && !g_quit) wm_pump();

    int res = g_dlg[slot].result;
    g_dlg_n--;
    g_modal = prev_modal;

    /* Вікно НЕ знищуємо: той, хто відкрив діалог, ще має зчитати
       з нього введені значення. Знищення — його справа. */
    wnd_show(dlg, 0);
    if (prev_active && prev_active->used) wnd_activate(prev_active);
    return res;
}

/* Дозволяє меню тимчасово перехопити весь ввід */
Window* wm_set_modal(Window* w);
Window* wm_set_modal(Window* w) {
    Window* prev = g_modal;
    g_modal = w;
    return prev;
}
