#include "win.h"

/* ============================================================
 * EUGENE GUI — МЕНЮ ТА ДІАЛОГИ
 *
 * Меню тут — не окремий механізм, а звичайне вікно зі стилем
 * WS_POPUP, яке на час показу забирає собі захоплення миші.
 * Саме захоплення дає головну властивість меню: клік будь-де
 * поза списком доходить до нього самого і закриває його.
 *
 * Модальний діалог влаштований так само просто: вікно, яке на
 * час свого життя перехоплює весь ввід, і власний цикл, що
 * крутиться, доки діалог не завершиться.
 * ============================================================ */

#define MI_H      16      /* висота звичайного пункту */
#define MI_SEP_H  7       /* висота роздільника */
#define MI_PADL   22      /* відступ зліва під позначку */
#define MI_PADR   22      /* відступ справа під стрілку підменю */

static int imax(int a, int b) { return a > b ? a : b; }

/* ============================================================
 * ПОБУДОВА МЕНЮ
 * ============================================================ */

Menu* menu_create(void) {
    Menu* m = (Menu*)malloc(sizeof(Menu));
    if (!m) return 0;
    memset(m, 0, sizeof(Menu));
    return m;
}

void menu_free(Menu* m) {
    if (!m) return;
    for (int i = 0; i < m->count; i++)
        if (m->items[i].sub) menu_free(m->items[i].sub);
    free(m);
}

static void mi_text(MenuItem* it, const char* s) {
    int i = 0;
    if (s) while (s[i] && i < (int)sizeof(it->text) - 1) { it->text[i] = s[i]; i++; }
    it->text[i] = 0;
}

void menu_add(Menu* m, int id, const char* text, int flags) {
    if (!m || m->count >= 24) return;
    MenuItem* it = &m->items[m->count++];
    it->id = id;
    it->flags = flags;
    it->sub = 0;
    mi_text(it, text);
}

void menu_add_sub(Menu* m, const char* text, Menu* sub) {
    if (!m || m->count >= 24) return;
    MenuItem* it = &m->items[m->count++];
    it->id = 0;
    it->flags = 0;
    it->sub = sub;
    mi_text(it, text);
}

void menu_sep(Menu* m) {
    if (!m || m->count >= 24) return;
    MenuItem* it = &m->items[m->count++];
    it->id = 0;
    it->flags = MF_SEPARATOR;
    it->sub = 0;
    it->text[0] = 0;
}

static MenuItem* menu_find(Menu* m, int id) {
    if (!m) return 0;
    for (int i = 0; i < m->count; i++) {
        if (m->items[i].id == id && !m->items[i].sub) return &m->items[i];
        if (m->items[i].sub) {
            MenuItem* r = menu_find(m->items[i].sub, id);
            if (r) return r;
        }
    }
    return 0;
}

void menu_check(Menu* m, int id, int on) {
    MenuItem* it = menu_find(m, id);
    if (!it) return;
    if (on) it->flags |= MF_CHECKED;
    else    it->flags &= ~MF_CHECKED;
}

void menu_enable(Menu* m, int id, int on) {
    MenuItem* it = menu_find(m, id);
    if (!it) return;
    if (on) it->flags &= ~MF_DISABLED;
    else    it->flags |= MF_DISABLED;
}

void wnd_set_menu(Window* w, Menu* m) {
    if (!w) return;
    w->menu = m;
    wnd_invalidate(w);
}

/* ============================================================
 * СПАДНИЙ СПИСОК
 * ============================================================ */

typedef struct {
    Menu* m;
    int   hot;
    int   result;
    int   done;
    int   sub_open;
} PopupState;

static int popup_item_y(PopupState* st, int idx) {
    int y = 3;
    for (int i = 0; i < idx; i++)
        y += (st->m->items[i].flags & MF_SEPARATOR) ? MI_SEP_H : MI_H;
    return y;
}

static int popup_hit(PopupState* st, int cy) {
    int y = 3;
    for (int i = 0; i < st->m->count; i++) {
        int h = (st->m->items[i].flags & MF_SEPARATOR) ? MI_SEP_H : MI_H;
        if (cy >= y && cy < y + h) return (st->m->items[i].flags & MF_SEPARATOR) ? -1 : i;
        y += h;
    }
    return -1;
}

static void popup_size(Menu* m, int* w, int* h) {
    int tw = 0, th = 6;
    for (int i = 0; i < m->count; i++) {
        if (m->items[i].flags & MF_SEPARATOR) { th += MI_SEP_H; continue; }
        int x = gui_text_amp_w(m->items[i].text);
        if (x > tw) tw = x;
        th += MI_H;
    }
    *w = tw + MI_PADL + MI_PADR;
    *h = th;
    if (*w < 90) *w = 90;
}

static void draw_check(int x, int y) {
    gui_line(x + 2, y + 5, x + 4, y + 7, GUI_TEXT);
    gui_line(x + 3, y + 5, x + 5, y + 7, GUI_TEXT);
    gui_line(x + 4, y + 7, x + 9, y + 2, GUI_TEXT);
    gui_line(x + 5, y + 7, x + 10, y + 2, GUI_TEXT);
}

static long popup_proc(Window* w, int msg, long a, long b);

/* Оголошено наперед: підменю відкриває себе рекурсивно */
static int popup_run(Menu* m, int sx, int sy, int* out_esc);

static long popup_proc(Window* w, int msg, long a, long b) {
    PopupState* st = (PopupState*)w->data;
    switch (msg) {

    case WM_NCPAINT: {
        /* Рамка меню — та сама об'ємна фаска, що й у кнопки */
        gui_fill_rect(&w->r, GUI_FACE);
        gui_bevel2(w->r.x, w->r.y, w->r.w, w->r.h, 1);
        return 0;
    }

    case WM_PAINT: {
        GuiRect r; wnd_client_rect(w, &r);
        for (int i = 0; i < st->m->count; i++) {
            MenuItem* it = &st->m->items[i];
            int y = r.y + popup_item_y(st, i) - 3;
            if (it->flags & MF_SEPARATOR) {
                gui_hline(r.x + 2, y + MI_SEP_H / 2, r.w - 4, GUI_SHADOW);
                gui_hline(r.x + 2, y + MI_SEP_H / 2 + 1, r.w - 4, GUI_LIGHT);
                continue;
            }
            int dis = (it->flags & MF_DISABLED) != 0;
            int hot = (i == st->hot) && !dis;
            if (hot) gui_fill(r.x, y, r.w, MI_H, GUI_SELECT);
            uint32_t tc = dis ? GUI_TEXT_DIM : (hot ? GUI_SELECT_TEXT : GUI_TEXT);
            if (it->flags & MF_CHECKED) draw_check(r.x + 4, y + 3);
            gui_text_amp(it->text, r.x + MI_PADL, y + (MI_H - GUI_FONT_H) / 2, tc);
            if (it->sub) {
                /* Стрілка підменю */
                int ax = r.x + r.w - 14, ay = y + MI_H / 2;
                for (int k = 0; k < 5; k++)
                    gui_vline(ax + k, ay - (4 - k), (4 - k) * 2 + 1, tc);
            }
        }
        return 0;
    }

    case WM_MOUSEMOVE: {
        GuiRect r; wnd_client_rect(w, &r);
        int nh = -1;
        if (a >= 0 && a < r.w) nh = popup_hit(st, (int)b + 3);
        if (nh != st->hot) { st->hot = nh; wnd_invalidate(w); }
        return 0;
    }

    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP: {
        GuiRect r; wnd_client_rect(w, &r);
        int inside = (a >= 0 && b >= 0 && a < r.w && b < r.h);
        if (!inside) {
            if (msg == WM_LBUTTONDOWN) { st->result = 0; st->done = 1; }
            return 0;
        }
        int idx = popup_hit(st, (int)b + 3);
        if (idx < 0) return 0;
        MenuItem* it = &st->m->items[idx];
        if (it->flags & MF_DISABLED) return 0;
        if (msg != WM_LBUTTONUP && !it->sub) return 0;

        if (it->sub) {
            int esc = 0;
            int y = w->r.y + popup_item_y(st, idx) - 1;
            int id = popup_run(it->sub, w->r.x + w->r.w - 3, y, &esc);
            if (id) { st->result = id; st->done = 1; }
            else if (!esc) { st->result = 0; st->done = 1; }
            return 0;
        }
        st->result = it->id;
        st->done = 1;
        return 0;
    }

    case WM_KEYDOWN:
        switch (a) {
        case VK_ESC:
            st->result = 0; st->done = 1; return 0;
        case VK_UP:
        case VK_DOWN: {
            int dir = (a == VK_UP) ? -1 : 1;
            int i = st->hot;
            for (int n = 0; n < st->m->count; n++) {
                i += dir;
                if (i < 0) i = st->m->count - 1;
                if (i >= st->m->count) i = 0;
                MenuItem* it = &st->m->items[i];
                if (!(it->flags & (MF_SEPARATOR | MF_DISABLED))) { st->hot = i; break; }
            }
            wnd_invalidate(w);
            return 0;
        }
        case VK_ENTER:
            if (st->hot >= 0) {
                MenuItem* it = &st->m->items[st->hot];
                if (it->sub) {
                    int esc = 0;
                    int y = w->r.y + popup_item_y(st, st->hot) - 1;
                    int id = popup_run(it->sub, w->r.x + w->r.w - 3, y, &esc);
                    if (id) { st->result = id; st->done = 1; }
                } else {
                    st->result = it->id; st->done = 1;
                }
            }
            return 0;
        default:
            return 0;
        }

    case WM_CHAR: {
        /* Гаряча літера пункту */
        char ch = (char)tolower((unsigned char)a);
        for (int i = 0; i < st->m->count; i++) {
            MenuItem* it = &st->m->items[i];
            if (it->flags & (MF_SEPARATOR | MF_DISABLED)) continue;
            if (gui_text_amp_key(it->text) == ch) {
                if (it->sub) {
                    int esc = 0;
                    int y = w->r.y + popup_item_y(st, i) - 1;
                    int id = popup_run(it->sub, w->r.x + w->r.w - 3, y, &esc);
                    if (id) { st->result = id; st->done = 1; }
                } else {
                    st->result = it->id; st->done = 1;
                }
                return 0;
            }
        }
        return 0;
    }

    default:
        return def_window_proc(w, msg, a, b);
    }
}

static int popup_run(Menu* m, int sx, int sy, int* out_esc) {
    if (!m || m->count == 0) return 0;

    int pw, ph;
    popup_size(m, &pw, &ph);

    /* Не даємо списку вилізти за екран */
    if (sx + pw > gui_width())  sx = gui_width() - pw;
    if (sy + ph > gui_height()) sy = gui_height() - ph;
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;

    PopupState st;
    memset(&st, 0, sizeof(st));
    st.m = m;
    st.hot = -1;
    st.result = 0;
    st.done = 0;

    Window* p = wnd_create("", WS_POPUP | WS_BORDER, sx, sy, pw, ph, popup_proc, &st);
    if (!p) return 0;
    p->min_w = 1; p->min_h = 1;
    wnd_to_top(p);

    Window* prev_modal = wm_set_modal(p);
    wnd_capture(p);

    while (!st.done && !wm_should_quit()) wm_pump();

    wnd_release();
    wm_set_modal(prev_modal);
    wnd_destroy(p);

    if (out_esc) *out_esc = (st.result == 0);
    return st.result;
}

int menu_popup(Menu* m, int sx, int sy) {
    int esc = 0;
    return popup_run(m, sx, sy, &esc);
}

/* ============================================================
 * РЯДОК МЕНЮ
 * ============================================================ */

static int bar_item_x(Window* w, int idx, int* out_w) {
    GuiRect mb; wnd_menubar_rect(w, &mb);
    int x = mb.x + 4;
    for (int i = 0; i < w->menu->count; i++) {
        int iw = gui_text_amp_w(w->menu->items[i].text) + 14;
        if (i == idx) { if (out_w) *out_w = iw; return x; }
        x += iw;
    }
    if (out_w) *out_w = 0;
    return x;
}

void menu_bar_draw(Window* w) {
    if (!w->menu || w->menu->count == 0) return;
    GuiRect mb; wnd_menubar_rect(w, &mb);
    gui_fill_rect(&mb, GUI_FACE);
    gui_hline(mb.x, mb.y + mb.h - 1, mb.w, GUI_SHADOW);

    for (int i = 0; i < w->menu->count; i++) {
        int iw;
        int x = bar_item_x(w, i, &iw);
        int dis = (w->menu->items[i].flags & MF_DISABLED) != 0;
        gui_text_amp(w->menu->items[i].text, x + 7,
                     mb.y + (mb.h - GUI_FONT_H) / 2,
                     dis ? GUI_TEXT_DIM : GUI_TEXT);
    }
}

/* Розкрити список під пунктом рядка меню і віддати вибір вікну */
static void bar_open(Window* w, int idx) {
    if (idx < 0 || idx >= w->menu->count) return;
    MenuItem* it = &w->menu->items[idx];
    if (it->flags & MF_DISABLED) return;

    GuiRect mb; wnd_menubar_rect(w, &mb);
    int iw;
    int x = bar_item_x(w, idx, &iw);

    /* Підсвічуємо відкритий пункт, поки список на екрані.
       Малюємо поза проходом перемальовування, тому обрізання
       треба виставити самим. */
    gui_clip_reset();
    gui_fill(x, mb.y, iw, mb.h - 1, GUI_SELECT);
    gui_text_amp(it->text, x + 7, mb.y + (mb.h - GUI_FONT_H) / 2, GUI_SELECT_TEXT);
    gui_invalidate(x, mb.y, iw, mb.h);

    int id = it->sub ? menu_popup(it->sub, x, mb.y + mb.h)
                     : it->id;
    wnd_invalidate(w);
    if (id) wnd_send(w, WM_COMMAND, id, MN_SELECT);
}

int menu_bar_click(Window* w, int sx, int sy) {
    if (!w->menu || w->menu->count == 0) return 0;
    GuiRect mb; wnd_menubar_rect(w, &mb);
    if (!gui_rect_has(&mb, sx, sy)) return 0;
    for (int i = 0; i < w->menu->count; i++) {
        int iw;
        int x = bar_item_x(w, i, &iw);
        if (sx >= x && sx < x + iw) { bar_open(w, i); return 1; }
    }
    return 1;
}

int menu_bar_key(Window* w, char ch) {
    if (!w || !w->menu || w->menu->count == 0) return 0;
    char c = (char)tolower((unsigned char)ch);
    for (int i = 0; i < w->menu->count; i++)
        if (gui_text_amp_key(w->menu->items[i].text) == c) { bar_open(w, i); return 1; }
    return 0;
}

/* ============================================================
 * ДІАЛОГИ
 * ============================================================ */

/* Спільна процедура: кнопка з ідентифікатором завершує діалог
   цим самим ідентифікатором, Esc — як Cancel. */
static long dlg_common(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_COMMAND:
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

static Window* dlg_frame(const char* title, int w, int h) {
    int x = (gui_width() - w) / 2;
    int y = (gui_height() - h) / 3;
    Window* d = wnd_create(title, WS_DIALOG, x, y, w, h, dlg_common, 0);
    if (d) { d->min_w = 80; d->min_h = 50; }
    return d;
}

/* Те саме назовні. Діалог зі стандартною поведінкою Enter та Esc -
   щоб додатки не переписували її щоразу заново. Наповнюється
   звичайними ctl_*, показується через dlg_modal, прибирається
   через wnd_destroy. */
Window* dlg_create(const char* title, int w, int h) {
    return dlg_frame(title, w, h);
}

/* --- Повідомлення --- */

int msg_box(const char* title, const char* text, int buttons) {
    /* Розкладаємо текст по рядках, щоб порахувати розмір вікна */
    const char* p = text ? text : "";
    int lines = 1, maxw = 0, cur = 0;
    for (const char* s = p; *s; s++) {
        if (*s == '\n') { if (cur > maxw) maxw = cur; cur = 0; lines++; }
        else cur += gui_char_w(*s);
    }
    if (cur > maxw) maxw = cur;

    int nb = (buttons == MB_OK) ? 1 : (buttons == MB_YESNOCANCEL ? 3 : 2);
    int bw = 74, bh = 24, gap = 10;
    int need = nb * bw + (nb - 1) * gap;
    int cw = imax(maxw, need) + 40;
    int ch = 20 + lines * GUI_LINE_H + 18 + bh + 14;

    Window* d = dlg_frame(title, cw, ch + WMET_TITLE + 2);
    if (!d) return IDCANCEL;

    int ty = 14;
    const char* line = p;
    char buf[128];
    for (int i = 0; i < lines; i++) {
        int n = 0;
        while (line[n] && line[n] != '\n' && n < 127) { buf[n] = line[n]; n++; }
        buf[n] = 0;
        ctl_static(d, 900 + i, buf, 16, ty, cw - 32, GUI_LINE_H, SS_LEFT);
        ty += GUI_LINE_H;
        line += n;
        if (*line == '\n') line++;
    }

    int by = ty + 14;
    int bx = (cw - need) / 2 - 4;
    if (buttons == MB_OK) {
        ctl_button(d, IDOK, "OK", bx, by, bw, bh, BS_DEFPUSH);
    } else if (buttons == MB_OKCANCEL) {
        ctl_button(d, IDOK, "OK", bx, by, bw, bh, BS_DEFPUSH);
        ctl_button(d, IDCANCEL, "Cancel", bx + bw + gap, by, bw, bh, BS_PUSH);
    } else if (buttons == MB_YESNO) {
        ctl_button(d, IDYES, "&Yes", bx, by, bw, bh, BS_DEFPUSH);
        ctl_button(d, IDNO, "&No", bx + bw + gap, by, bw, bh, BS_PUSH);
    } else {
        ctl_button(d, IDYES, "&Yes", bx, by, bw, bh, BS_DEFPUSH);
        ctl_button(d, IDNO, "&No", bx + bw + gap, by, bw, bh, BS_PUSH);
        ctl_button(d, IDCANCEL, "Cancel", bx + 2 * (bw + gap), by, bw, bh, BS_PUSH);
    }
    int res = dlg_modal(d);
    wnd_destroy(d);
    return res;
}

/* --- Вибір файлу --- */

#define IDC_FILES 300

static long dlg_open_proc(Window* w, int msg, long a, long b) {
    if (msg == WM_COMMAND && a == IDC_FILES && b == LBN_DBLCLK) {
        dlg_end(w, IDOK);
        return 0;
    }
    return dlg_common(w, msg, a, b);
}

int dlg_open_file(const char* title, char* out, int cap) {
    int dw = 260, dh = 250;
    Window* d = dlg_frame(title ? title : "Open File", dw, dh);
    if (!d) return 0;
    d->proc = dlg_open_proc;

    ctl_static(d, 0, "&File Name:", 12, 10, 120, 12, SS_LEFT);
    Window* lb = ctl_list(d, IDC_FILES, 12, 26, dw - 32, 140);
    ctl_button(d, IDOK, "OK", dw - 190, dh - 62, 74, 24, BS_DEFPUSH);
    ctl_button(d, IDCANCEL, "Cancel", dw - 106, dh - 62, 74, 24, BS_PUSH);

    /* Список каталогу від ядра: "NAME    EXT\n..." */
    char* buf = (char*)malloc(4096);
    if (buf) {
        buf[0] = 0;
        get_file_list(buf, 4096);
        char name[20];
        int n = 0;
        for (char* s = buf; ; s++) {
            if (*s == '\n' || *s == 0) {
                name[n] = 0;
                if (n > 0) list_add(lb, name);
                n = 0;
                if (*s == 0) break;
                continue;
            }
            if (n < 18) name[n++] = *s;
        }
        free(buf);
    }
    if (list_count(lb) > 0) list_set_sel(lb, 0);

    int res = dlg_modal(d);

    /* dlg_modal лише ховає вікно, тому значення ще на місці */
    int ok = 0;
    if (res == IDOK) {
        int sel = list_sel(lb);
        if (sel >= 0) {
            const char* s = list_item(lb, sel);
            int i = 0;
            while (s[i] && i < cap - 1) { out[i] = s[i]; i++; }
            out[i] = 0;
            ok = 1;
        }
    }
    wnd_destroy(d);
    return ok;
}

/* --- Рядок вводу --- */

#define IDC_INPUT 301

int dlg_input(const char* title, const char* prompt, char* buf, int cap) {
    int dw = 280, dh = 130;
    Window* d = dlg_frame(title ? title : "Input", dw, dh);
    if (!d) return 0;

    ctl_static(d, 0, prompt ? prompt : "", 12, 10, dw - 32, 12, SS_LEFT);
    Window* ed = ctl_edit(d, IDC_INPUT, buf, 12, 28, dw - 32, 22, ES_SINGLE, cap);
    ctl_button(d, IDOK, "OK", dw - 178, dh - 62, 74, 24, BS_DEFPUSH);
    ctl_button(d, IDCANCEL, "Cancel", dw - 94, dh - 62, 74, 24, BS_PUSH);
    wnd_focus(ed);

    int res = dlg_modal(d);
    int ok = 0;
    if (res == IDOK) {
        const char* s = edit_get(ed);
        int i = 0;
        while (s[i] && i < cap - 1) { buf[i] = s[i]; i++; }
        buf[i] = 0;
        ok = 1;
    }
    wnd_destroy(d);
    return ok;
}
