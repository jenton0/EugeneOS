#include "gui.h"

/* ============================================================
 * EUGENE GUI — НИЖНІЙ ШАР, реалізація
 * ============================================================ */

/* Згенеровано з FontData у kernel.asm — шрифт спільний із ядром,
   тому текст у консолі та у вікнах виглядає однаково.

   Гліфи зсунуто до лівого краю, а ширина кожного порахована
   окремо: так 'i' займає менше місця, ніж 'm', і текст
   виглядає пропорційним, а не як у терміналі. */
static const uint8_t gui_font[95][8] = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /*  32   */
    {0xC0,0xC0,0xC0,0xC0,0xC0,0x00,0xC0,0x00}, /*  33 ! */
    {0x90,0x90,0x90,0x00,0x00,0x00,0x00,0x00}, /*  34 " */
    {0x48,0x48,0xFC,0x48,0xFC,0x48,0x48,0x00}, /*  35 # */
    {0x30,0x78,0xC0,0x78,0x0C,0x78,0x30,0x00}, /*  36 $ */
    {0x66,0xC6,0x18,0x18,0x30,0x66,0x00,0x00}, /*  37 % */
    {0x38,0x6C,0x38,0x76,0xDC,0x00,0x00,0x00}, /*  38 & */
    {0x60,0x60,0xC0,0x00,0x00,0x00,0x00,0x00}, /*  39 ' */
    {0x30,0x60,0xC0,0xC0,0x60,0x30,0x00,0x00}, /*  40 ( */
    {0xC0,0x60,0x30,0x30,0x60,0xC0,0x00,0x00}, /*  41 ) */
    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00}, /*  42 * */
    {0x00,0x30,0x30,0xFC,0x30,0x30,0x00,0x00}, /*  43 + */
    {0x00,0x00,0x00,0x00,0x00,0x60,0x60,0xC0}, /*  44 , */
    {0x00,0x00,0x00,0xFC,0x00,0x00,0x00,0x00}, /*  45 - */
    {0x00,0x00,0x00,0x00,0x00,0xC0,0xC0,0x00}, /*  46 . */
    {0x00,0xC0,0x60,0x30,0x18,0x0C,0x00,0x00}, /*  47 / */
    {0x78,0xCC,0xCC,0xCC,0xCC,0x78,0x00,0x00}, /*  48 0 */
    {0x60,0xE0,0x60,0x60,0x60,0xF0,0x00,0x00}, /*  49 1 */
    {0x78,0xCC,0x18,0x30,0x60,0xFC,0x00,0x00}, /*  50 2 */
    {0x78,0xCC,0x18,0x18,0xCC,0x78,0x00,0x00}, /*  51 3 */
    {0x18,0x38,0x78,0xD8,0xFC,0x18,0x00,0x00}, /*  52 4 */
    {0xFC,0xC0,0x7C,0x0C,0x0C,0x78,0x00,0x00}, /*  53 5 */
    {0x38,0x60,0xC0,0x78,0xCC,0x78,0x00,0x00}, /*  54 6 */
    {0xFC,0x0C,0x18,0x30,0x60,0x60,0x00,0x00}, /*  55 7 */
    {0x78,0xCC,0x78,0xCC,0x78,0x00,0x00,0x00}, /*  56 8 */
    {0x78,0xCC,0x78,0x0C,0x18,0x70,0x00,0x00}, /*  57 9 */
    {0x00,0xC0,0xC0,0x00,0xC0,0xC0,0x00,0x00}, /*  58 : */
    {0x00,0x60,0x60,0x00,0x60,0x60,0xC0,0x00}, /*  59 ; */
    {0x18,0x30,0x60,0xC0,0x60,0x30,0x18,0x00}, /*  60 < */
    {0x00,0x00,0xFC,0x00,0xFC,0x00,0x00,0x00}, /*  61 = */
    {0xC0,0x60,0x30,0x18,0x30,0x60,0xC0,0x00}, /*  62 > */
    {0x78,0xCC,0x18,0x30,0x00,0x30,0x00,0x00}, /*  63 ? */
    {0x78,0xCC,0xDC,0xDC,0xC0,0x7C,0x00,0x00}, /*  64 @ */
    {0x30,0x78,0xCC,0xCC,0xFC,0xCC,0xCC,0x00}, /*  65 A */
    {0xFC,0xCC,0xCC,0xFC,0xCC,0xCC,0xFC,0x00}, /*  66 B */
    {0x78,0xCC,0xC0,0xC0,0xC0,0xCC,0x78,0x00}, /*  67 C */
    {0xF8,0xCC,0xCC,0xCC,0xCC,0xCC,0xF8,0x00}, /*  68 D */
    {0xFC,0xC0,0xC0,0xF0,0xC0,0xC0,0xFC,0x00}, /*  69 E */
    {0xFC,0xC0,0xC0,0xF0,0xC0,0xC0,0xC0,0x00}, /*  70 F */
    {0x78,0xCC,0xC0,0xDC,0xCC,0x78,0x00,0x00}, /*  71 G */
    {0xCC,0xCC,0xCC,0xFC,0xCC,0xCC,0xCC,0x00}, /*  72 H */
    {0xF0,0x60,0x60,0x60,0x60,0x60,0xF0,0x00}, /*  73 I */
    {0x3C,0x0C,0x0C,0x0C,0xCC,0x78,0x00,0x00}, /*  74 J */
    {0xCC,0xD8,0xF0,0xF0,0xD8,0xCC,0x00,0x00}, /*  75 K */
    {0xC0,0xC0,0xC0,0xC0,0xC0,0xC0,0xFC,0x00}, /*  76 L */
    {0xC6,0xEE,0xFE,0xD6,0xC6,0xC6,0x00,0x00}, /*  77 M */
    {0xCC,0xEC,0xFE,0xDC,0xCC,0xCC,0x00,0x00}, /*  78 N */
    {0x78,0xCC,0xCC,0xCC,0xCC,0x78,0x00,0x00}, /*  79 O */
    {0xFC,0xCC,0xCC,0xFC,0xC0,0xC0,0x00,0x00}, /*  80 P */
    {0x78,0xCC,0xCC,0xCC,0xD8,0x6C,0x00,0x00}, /*  81 Q */
    {0xFC,0xCC,0xCC,0xFC,0xD8,0xCC,0x00,0x00}, /*  82 R */
    {0x78,0xC0,0x78,0x0C,0xCC,0x78,0x00,0x00}, /*  83 S */
    {0xFC,0x30,0x30,0x30,0x30,0x30,0x00,0x00}, /*  84 T */
    {0xCC,0xCC,0xCC,0xCC,0xCC,0x78,0x00,0x00}, /*  85 U */
    {0xCC,0xCC,0xCC,0xCC,0x78,0x30,0x00,0x00}, /*  86 V */
    {0xC6,0xC6,0xD6,0xFE,0xEE,0xC6,0x00,0x00}, /*  87 W */
    {0xCC,0xCC,0x78,0x30,0x78,0xCC,0x00,0x00}, /*  88 X */
    {0xCC,0xCC,0x78,0x30,0x30,0x30,0x00,0x00}, /*  89 Y */
    {0xFC,0x0C,0x18,0x30,0x60,0xFC,0x00,0x00}, /*  90 Z */
    {0xF0,0xC0,0xC0,0xC0,0xC0,0xF0,0x00,0x00}, /*  91 [ */
    {0x00,0x0C,0x18,0x30,0x60,0xC0,0x00,0x00}, /*  92 \ */
    {0xF0,0x30,0x30,0x30,0x30,0xF0,0x00,0x00}, /*  93 ] */
    {0x30,0x78,0xCC,0x00,0x00,0x00,0x00,0x00}, /*  94 ^ */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF}, /*  95 _ */
    {0xC0,0x60,0x00,0x00,0x00,0x00,0x00,0x00}, /*  96 ` */
    {0x00,0x00,0x78,0x06,0x7C,0xC6,0x7C,0x00}, /*  97 a */
    {0xC0,0xC0,0xDC,0xE6,0xC6,0xC6,0xF8,0x00}, /*  98 b */
    {0x00,0x00,0x7C,0xC6,0xC0,0xC6,0x7C,0x00}, /*  99 c */
    {0x06,0x06,0x7C,0xC6,0xC6,0xC6,0x7E,0x00}, /* 100 d */
    {0x00,0x00,0x7C,0xC6,0xFE,0xC0,0x7C,0x00}, /* 101 e */
    {0x38,0x64,0x60,0xF8,0x60,0x60,0x60,0x00}, /* 102 f */
    {0x00,0x00,0x7E,0xC6,0x7E,0x06,0x7C,0x00}, /* 103 g */
    {0xC0,0xC0,0xDC,0xE6,0xC6,0xC6,0xC6,0x00}, /* 104 h */
    {0x60,0x00,0xE0,0x60,0x60,0x60,0xF0,0x00}, /* 105 i */
    {0x0C,0x00,0x1C,0x0C,0x0C,0xCC,0x78,0x00}, /* 106 j */
    {0xC0,0xC0,0xCC,0xD8,0xF0,0xD8,0xCC,0x00}, /* 107 k */
    {0xE0,0x60,0x60,0x60,0x60,0x60,0xF0,0x00}, /* 108 l */
    {0x00,0x00,0xD8,0xFE,0xFE,0xD6,0xC6,0x00}, /* 109 m */
    {0x00,0x00,0xDC,0xE6,0xC6,0xC6,0xC6,0x00}, /* 110 n */
    {0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0x00}, /* 111 o */
    {0x00,0x00,0xF8,0xCC,0xF8,0xC0,0xC0,0x00}, /* 112 p */
    {0x00,0x00,0x7C,0xCC,0x7C,0x0C,0x0C,0x00}, /* 113 q */
    {0x00,0x00,0xDC,0xE6,0xC0,0xC0,0xC0,0x00}, /* 114 r */
    {0x00,0x00,0x7C,0xC0,0x7C,0x06,0xFC,0x00}, /* 115 s */
    {0x60,0x60,0xF8,0x60,0x60,0x6C,0x38,0x00}, /* 116 t */
    {0x00,0x00,0xC6,0xC6,0xC6,0xCE,0x76,0x00}, /* 117 u */
    {0x00,0x00,0xC6,0xC6,0xC6,0x6C,0x38,0x00}, /* 118 v */
    {0x00,0x00,0xC6,0xD6,0xFE,0xFE,0x6C,0x00}, /* 119 w */
    {0x00,0x00,0xC6,0x6C,0x38,0x6C,0xC6,0x00}, /* 120 x */
    {0x00,0x00,0xC6,0xC6,0x7E,0x06,0x7C,0x00}, /* 121 y */
    {0x00,0x00,0xFE,0x1C,0x38,0x70,0xFE,0x00}, /* 122 z */
    {0x1C,0x30,0x30,0xE0,0x30,0x30,0x1C,0x00}, /* 123 { */
    {0xC0,0xC0,0xC0,0xC0,0xC0,0xC0,0xC0,0x00}, /* 124 | */
    {0xE0,0x30,0x30,0x0C,0x30,0x30,0xE0,0x00}, /* 125 } */
    {0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00}, /* 126 ~ */
};

static const uint8_t gui_font_w[95] = {
    4,3,5,7,7,8,8,4,5,5,9,7,4,7,3,7,
    7,5,7,7,7,7,7,7,7,7,3,4,6,7,6,7,
    7,7,7,7,7,7,7,7,7,5,7,7,7,8,8,7,
    7,7,7,7,7,7,7,8,7,7,7,5,7,5,7,9,
    4,8,8,8,8,8,7,8,8,5,7,7,5,8,8,8,
    7,7,8,8,7,8,8,8,8,8,8,7,3,7,8,
};

/* --- Стан --- */
static int       g_w = 0, g_h = 0;
static uint32_t *g_fb = 0;          /* буфер кадру */

/* --- Обрізання --- */
static GuiRect g_clip_stack[GUI_CLIP_DEPTH];
static int     g_clip_n = 0;
static GuiRect g_clip;              /* поточне, завжди ∩ екран */

/* --- Брудні ділянки ---
 * Тримаємо невеликий список. Коли він переповнюється, просто
 * зливаємо все в одну ділянку — це гірше за точний облік, але
 * ніколи не втрачає оновлень і не потребує складних структур. */
#define DIRTY_MAX 32
static GuiRect g_dirty[DIRTY_MAX];
static int     g_dirty_n = 0;
static int     g_dirty_all = 0;

int gui_width(void)  { return g_w; }
int gui_height(void) { return g_h; }

int gui_rect_isect(const GuiRect* a, const GuiRect* b, GuiRect* out) {
    int x0 = a->x > b->x ? a->x : b->x;
    int y0 = a->y > b->y ? a->y : b->y;
    int x1 = (a->x + a->w) < (b->x + b->w) ? (a->x + a->w) : (b->x + b->w);
    int y1 = (a->y + a->h) < (b->y + b->h) ? (a->y + a->h) : (b->y + b->h);
    if (x1 <= x0 || y1 <= y0) {
        if (out) { out->x = out->y = 0; out->w = out->h = 0; }
        return 0;
    }
    if (out) { out->x = x0; out->y = y0; out->w = x1 - x0; out->h = y1 - y0; }
    return 1;
}

/* ============================================================
 * ОБРІЗАННЯ
 * ============================================================ */

void gui_clip_reset(void) {
    g_clip_n = 0;
    g_clip.x = 0; g_clip.y = 0; g_clip.w = g_w; g_clip.h = g_h;
}

void gui_clip_get(GuiRect* out) { if (out) *out = g_clip; }

int gui_clip_push(const GuiRect* r) {
    if (g_clip_n >= GUI_CLIP_DEPTH) {
        /* Стек переповнено. Однаково рахуємо цей push, щоб кожен
           gui_clip_pop() лишався парним — інакше pop зняв би чуже
           обрізання і малювання поїхало б по всьому екрану. */
        g_clip_n++;
        return 0;
    }
    g_clip_stack[g_clip_n++] = g_clip;
    GuiRect n;
    if (!gui_rect_isect(&g_clip, r, &n)) {
        g_clip.w = 0; g_clip.h = 0;   /* порожньо: малювання нічого не робить */
        return 0;
    }
    g_clip = n;
    return 1;
}

void gui_clip_pop(void) {
    if (g_clip_n > GUI_CLIP_DEPTH) { g_clip_n--; return; }
    if (g_clip_n > 0) g_clip = g_clip_stack[--g_clip_n];
}

/* Один піксель із перевіркою обрізання. Гаряча точка всього шару,
   тому inline і без зайвих перевірок. */
static inline void px(int x, int y, uint32_t c) {
    if (x < g_clip.x || y < g_clip.y ||
        x >= g_clip.x + g_clip.w || y >= g_clip.y + g_clip.h) return;
    g_fb[(unsigned long)y * g_w + x] = c;
}

static inline void px_xor(int x, int y) {
    if (x < g_clip.x || y < g_clip.y ||
        x >= g_clip.x + g_clip.w || y >= g_clip.y + g_clip.h) return;
    g_fb[(unsigned long)y * g_w + x] ^= 0x00FFFFFF;
}

/* ============================================================
 * ІНІЦІАЛІЗАЦІЯ
 * ============================================================ */

int gui_init(void) {
    uint32_t w = 0, h = 0;
    get_screen_size(&w, &h);
    if (w == 0 || h == 0) { w = 800; h = 600; }
    if (w > 1920) w = 1920;
    if (h > 1200) h = 1200;
    g_w = (int)w;
    g_h = (int)h;

    g_fb = (uint32_t *)malloc((unsigned long)g_w * (unsigned long)g_h * 4u);
    if (!g_fb) return 0;
    memset(g_fb, 0, (unsigned long)g_w * (unsigned long)g_h * 4u);

    gui_clip_reset();
    g_dirty_n = 0;
    g_dirty_all = 1;        /* перший кадр виводимо цілком */

    /* Курсор малюємо ми, а не ядро: інакше ядро запам'ятовує фон,
       ми робимо свій blit поверх, а воно потім «відновлює» вже
       застарілий фон — і на екрані лишається слід. */
    set_cursor_owner(1);
    return 1;
}

/* ============================================================
 * БРУДНІ ДІЛЯНКИ
 * ============================================================ */

static long merge_cost(const GuiRect* a, const GuiRect* b) {
    int x0 = a->x < b->x ? a->x : b->x;
    int y0 = a->y < b->y ? a->y : b->y;
    int x1 = (a->x + a->w) > (b->x + b->w) ? (a->x + a->w) : (b->x + b->w);
    int y1 = (a->y + a->h) > (b->y + b->h) ? (a->y + a->h) : (b->y + b->h);
    long merged = (long)(x1 - x0) * (y1 - y0);
    long sep    = (long)a->w * a->h + (long)b->w * b->h;
    return merged - sep;
}

static void merge_into(GuiRect* a, const GuiRect* b) {
    int x0 = a->x < b->x ? a->x : b->x;
    int y0 = a->y < b->y ? a->y : b->y;
    int x1 = (a->x + a->w) > (b->x + b->w) ? (a->x + a->w) : (b->x + b->w);
    int y1 = (a->y + a->h) > (b->y + b->h) ? (a->y + a->h) : (b->y + b->h);
    a->x = x0; a->y = y0; a->w = x1 - x0; a->h = y1 - y0;
}

void gui_invalidate(int x, int y, int w, int h) {
    if (g_dirty_all) return;
    if (w <= 0 || h <= 0) return;

    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > g_w) w = g_w - x;
    if (y + h > g_h) h = g_h - y;
    if (w <= 0 || h <= 0) return;

    GuiRect r = { x, y, w, h };

    for (int i = 0; i < g_dirty_n; i++) {
        GuiRect* d = &g_dirty[i];
        if (r.x >= d->x && r.y >= d->y &&
            r.x + r.w <= d->x + d->w && r.y + r.h <= d->y + d->h) return;
    }

    if (g_dirty_n < DIRTY_MAX) {
        g_dirty[g_dirty_n++] = r;
        return;
    }

    int best = 0;
    long best_cost = merge_cost(&g_dirty[0], &r);
    for (int i = 1; i < g_dirty_n; i++) {
        long c = merge_cost(&g_dirty[i], &r);
        if (c < best_cost) { best_cost = c; best = i; }
    }
    merge_into(&g_dirty[best], &r);
}

void gui_invalidate_rect(const GuiRect* r) {
    if (r) gui_invalidate(r->x, r->y, r->w, r->h);
}

void gui_invalidate_all(void) {
    g_dirty_all = 1;
    g_dirty_n = 0;
}

int gui_flush(void) {
    if (!g_fb) return 0;

    if (g_dirty_all) {
        blit_buffer(g_fb, 0, 0, (uint32_t)g_w, (uint32_t)g_h);
        g_dirty_all = 0;
        g_dirty_n = 0;
        return 1;
    }

    int shown = 0;
    for (int i = 0; i < g_dirty_n; i++) {
        GuiRect* d = &g_dirty[i];
        if (d->w <= 0 || d->h <= 0) continue;
        /* Передаємо покажчик на початок потрібного рядка і повну
           ширину екрана як крок — це syscall 25. */
        uint32_t* src = g_fb + (unsigned long)d->y * g_w + d->x;
        blit_buffer_stride(src, (uint32_t)d->x, (uint32_t)d->y,
                           (uint32_t)d->w, (uint32_t)d->h, (uint32_t)g_w);
        shown++;
    }
    g_dirty_n = 0;
    return shown;
}

/* ============================================================
 * ПРИМІТИВИ
 * ============================================================ */

void gui_fill(int x, int y, int w, int h, uint32_t color) {
    if (!g_fb || w <= 0 || h <= 0) return;
    int x0 = x, y0 = y, x1 = x + w, y1 = y + h;
    if (x0 < g_clip.x) x0 = g_clip.x;
    if (y0 < g_clip.y) y0 = g_clip.y;
    if (x1 > g_clip.x + g_clip.w) x1 = g_clip.x + g_clip.w;
    if (y1 > g_clip.y + g_clip.h) y1 = g_clip.y + g_clip.h;
    if (x0 >= x1 || y0 >= y1) return;

    for (int iy = y0; iy < y1; iy++) {
        uint32_t* row = g_fb + (unsigned long)iy * g_w;
        for (int ix = x0; ix < x1; ix++) row[ix] = color;
    }
}

void gui_fill_rect(const GuiRect* r, uint32_t color) {
    if (r) gui_fill(r->x, r->y, r->w, r->h, color);
}

void gui_hline(int x, int y, int len, uint32_t color) { gui_fill(x, y, len, 1, color); }
void gui_vline(int x, int y, int len, uint32_t color) { gui_fill(x, y, 1, len, color); }

void gui_frame(int x, int y, int w, int h, uint32_t color) {
    if (w <= 0 || h <= 0) return;
    gui_hline(x, y, w, color);
    gui_hline(x, y + h - 1, w, color);
    gui_vline(x, y, h, color);
    gui_vline(x + w - 1, y, h, color);
}

void gui_line(int x0, int y0, int x1, int y1, uint32_t color) {
    int dx = x1 - x0, dy = y1 - y0;
    int sx = dx < 0 ? -1 : 1, sy = dy < 0 ? -1 : 1;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    int err = dx - dy;
    for (;;) {
        px(x0, y0, color);
        if (x0 == x1 && y0 == y1) break;
        int e2 = err * 2;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 <  dx) { err += dx; y0 += sy; }
    }
}

void gui_bevel(int x, int y, int w, int h, int raised) {
    uint32_t tl = raised ? GUI_LIGHT   : GUI_SHADOW;
    uint32_t br = raised ? GUI_SHADOW  : GUI_LIGHT;
    if (w <= 0 || h <= 0) return;
    gui_hline(x, y, w, tl);
    gui_vline(x, y, h, tl);
    gui_hline(x, y + h - 1, w, br);
    gui_vline(x + w - 1, y, h, br);
}

void gui_bevel2(int x, int y, int w, int h, int raised) {
    /* Дві грані замість однієї. Саме подвійна фаска дає той самий
       «пластиковий» вигляд, що й у Windows 3.1: зовні різкий
       контраст, усередині м'якший. */
    if (w < 4 || h < 4) { gui_bevel(x, y, w, h, raised); return; }
    if (raised) {
        gui_hline(x, y, w, GUI_LIGHT);
        gui_vline(x, y, h, GUI_LIGHT);
        gui_hline(x, y + h - 1, w, GUI_DKSHADOW);
        gui_vline(x + w - 1, y, h, GUI_DKSHADOW);
        gui_hline(x + 1, y + 1, w - 2, GUI_FACE);
        gui_vline(x + 1, y + 1, h - 2, GUI_FACE);
        gui_hline(x + 1, y + h - 2, w - 2, GUI_SHADOW);
        gui_vline(x + w - 2, y + 1, h - 2, GUI_SHADOW);
    } else {
        gui_hline(x, y, w, GUI_SHADOW);
        gui_vline(x, y, h, GUI_SHADOW);
        gui_hline(x, y + h - 1, w, GUI_LIGHT);
        gui_vline(x + w - 1, y, h, GUI_LIGHT);
        gui_hline(x + 1, y + 1, w - 2, GUI_DKSHADOW);
        gui_vline(x + 1, y + 1, h - 2, GUI_DKSHADOW);
        gui_hline(x + 1, y + h - 2, w - 2, GUI_FACE);
        gui_vline(x + w - 2, y + 1, h - 2, GUI_FACE);
    }
}

void gui_dither(int x, int y, int w, int h, uint32_t a, uint32_t b) {
    if (w <= 0 || h <= 0) return;
    for (int iy = y; iy < y + h; iy++)
        for (int ix = x; ix < x + w; ix++)
            px(ix, iy, ((ix ^ iy) & 1) ? b : a);
}

void gui_focus_rect(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    for (int ix = x; ix < x + w; ix += 2) {
        px(ix, y, GUI_DKSHADOW);
        px(ix, y + h - 1, GUI_DKSHADOW);
    }
    for (int iy = y; iy < y + h; iy += 2) {
        px(x, iy, GUI_DKSHADOW);
        px(x + w - 1, iy, GUI_DKSHADOW);
    }
}

void gui_xor_frame(int x, int y, int w, int h, int thick) {
    if (w <= 0 || h <= 0) return;
    if (thick < 1) thick = 1;
    for (int t = 0; t < thick; t++) {
        for (int ix = x + t; ix < x + w - t; ix++) {
            px_xor(ix, y + t);
            px_xor(ix, y + h - 1 - t);
        }
        for (int iy = y + t; iy < y + h - t; iy++) {
            px_xor(x + t, iy);
            px_xor(x + w - 1 - t, iy);
        }
    }
}

void gui_pixel(int x, int y, uint32_t color) { px(x, y, color); }

uint32_t* gui_fb(int* stride) {
    if (stride) *stride = g_w;
    return g_fb;
}

/* ============================================================
 * ТЕКСТ
 * ============================================================ */

int gui_char_w(char c) {
    int i = (unsigned char)c - 32;
    if (i < 0 || i > 94) return 4;
    return gui_font_w[i];
}

int gui_text_w(const char* s) {
    int total = 0;
    if (!s) return 0;
    while (*s) total += gui_char_w(*s++);
    return total;
}

int gui_text_wn(const char* s, int n) {
    int total = 0;
    if (!s) return 0;
    for (int i = 0; i < n && s[i]; i++) total += gui_char_w(s[i]);
    return total;
}

void gui_char(char c, int x, int y, uint32_t color) {
    if (!g_fb) return;
    int idx = (unsigned char)c - 32;
    if (idx < 0 || idx > 94) return;

    for (int cy = 0; cy < 8; cy++) {
        uint8_t bits = gui_font[idx][cy];
        if (!bits) continue;
        int py = y + cy;
        for (int cx = 0; cx < 8; cx++) {
            if (!((bits >> (7 - cx)) & 1)) continue;
            px(x + cx, py, color);
        }
    }
}

void gui_text(const char* s, int x, int y, uint32_t color) {
    if (!s) return;
    int cx = x;
    while (*s) {
        gui_char(*s, cx, y, color);
        cx += gui_char_w(*s);
        s++;
    }
}

void gui_text_clip(const char* s, int x, int y, int right, uint32_t color) {
    if (!s) return;
    int cx = x;
    while (*s) {
        int cw = gui_char_w(*s);
        if (cx + cw > right) break;
        gui_char(*s, cx, y, color);
        cx += cw;
        s++;
    }
}

/* --- Написи з '&': «&Файл» малює Ф підкресленою --- */

int gui_text_amp_w(const char* s) {
    int total = 0;
    if (!s) return 0;
    while (*s) {
        if (*s == '&' && s[1]) { s++; continue; }
        total += gui_char_w(*s++);
    }
    return total;
}

char gui_text_amp_key(const char* s) {
    if (!s) return 0;
    while (*s) {
        if (*s == '&' && s[1] && s[1] != '&') return (char)tolower((unsigned char)s[1]);
        s++;
    }
    return 0;
}

char gui_text_amp(const char* s, int x, int y, uint32_t color) {
    char hot = 0;
    int cx = x;
    if (!s) return 0;
    while (*s) {
        if (*s == '&' && s[1]) {
            s++;
            if (*s != '&') {
                hot = (char)tolower((unsigned char)*s);
                gui_char(*s, cx, y, color);
                gui_hline(cx, y + 9, gui_char_w(*s) - 1, color);
                cx += gui_char_w(*s);
                s++;
                continue;
            }
        }
        gui_char(*s, cx, y, color);
        cx += gui_char_w(*s);
        s++;
    }
    return hot;
}

/* ============================================================
 * ПОДІЇ
 *
 * Стан миші й клавіатури опитується раз за кадр, а різниця зі
 * станом минулого кадру перетворюється на події.
 * ============================================================ */

static int      g_mx = 0, g_my = 0, g_mb = 0;
static int      g_mb_prev = 0;
static uint64_t g_last_tick = 0;
static uint64_t g_ticks = 0;
static int      g_frame_ms = 0;      /* 0 = кадрові події нікому не потрібні */
static uint64_t g_last_frame = 0;

/* Подвійний клік: два натискання ближче ніж DBL_TICKS одне до
   одного і не далі ніж DBL_SLOP пікселів. Ядро цього не рахує,
   бо це питання смаку інтерфейсу, а не драйвера.

   ОДИНИЦЯ ЧАСУ ТУТ - МІЛІСЕКУНДА. Таймер ядра налаштований на
   1000 Гц (дільник PIT 1193), тобто один тік = 1 мс. Спершу тут
   стояло 9 - і подвійний клік був неможливий фізично, через що
   згорнуте вікно не вдавалося відновити взагалі. */
#define DBL_TICKS 400
#define DBL_SLOP  4
static uint64_t g_last_down_t = 0;
static int      g_last_down_x = -999, g_last_down_y = -999;

#define EVQ_MAX 32
static GuiEvent g_evq[EVQ_MAX];
static int      g_evq_head = 0, g_evq_tail = 0;

static void ev_push(const GuiEvent* e) {
    int next = (g_evq_head + 1) % EVQ_MAX;
    if (next == g_evq_tail) return;     /* черга повна — губимо найновішу */
    g_evq[g_evq_head] = *e;
    g_evq_head = next;
}

static void ev_zero(GuiEvent* e) {
    e->type = 0; e->x = g_mx; e->y = g_my;
    e->button = 0; e->buttons = g_mb; e->wheel = 0;
    e->ascii = 0; e->scancode = 0; e->mods = 0;
}

uint64_t gui_ticks(void) { return g_ticks; }

/* Кадровий такт. Чверть секунди, з якою ходить GUI_EV_TICK, обрано
   під миготіння каретки, і рухати її не можна. Відео потребує
   свого темпу, тому воно просить окремий такт і вимикає його,
   коли дограло: поки ніхто не просить, черга подій лишається
   такою ж, як була. */
void gui_frame_events(int ms) {
    g_frame_ms = ms < 0 ? 0 : ms;
    g_last_frame = g_ticks;
}

static void gather(void) {
    GuiEvent e;

    /* --- Миша. Один виклик за кадр: syscall очищає лічильник колеса,
           тому питати двічі не можна — половина прокрутки загубиться. --- */
    uint32_t mx = 0, my = 0, mb = 0;
    int wheel = 0;
    get_mouse_ex(&mx, &my, &mb, &wheel);

    /* Ядро віддає нижні два біти пакета PS/2 як є, тобто це вже
       готова бітова маска: 1 ліва, 2 права, 3 обидві разом.
       GUI_MB_* навмисно збігаються з цими бітами. */
    int nb = (int)(mb & (GUI_MB_LEFT | GUI_MB_RIGHT));

    int nx = (int)mx, ny = (int)my;
    g_ticks = get_ticks();

    if (nx != g_mx || ny != g_my) {
        g_mx = nx; g_my = ny;
        ev_zero(&e);
        e.type = GUI_EV_MOUSE_MOVE;
        ev_push(&e);
    }

    if (nb != g_mb_prev) {
        int pressed  = nb & ~g_mb_prev;
        int released = g_mb_prev & ~nb;

        if (pressed) {
            ev_zero(&e);
            e.buttons = nb;
            e.button  = pressed;

            int dx = nx - g_last_down_x, dy = ny - g_last_down_y;
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            int dbl = (pressed & GUI_MB_LEFT) &&
                      (g_ticks - g_last_down_t) <= DBL_TICKS &&
                      dx <= DBL_SLOP && dy <= DBL_SLOP;

            e.type = dbl ? GUI_EV_MOUSE_DBL : GUI_EV_MOUSE_DOWN;
            ev_push(&e);

            /* Після подвійного скидаємо мітку, інакше третій клік
               поспіль теж рахувався б подвійним. */
            g_last_down_t = dbl ? 0 : g_ticks;
            g_last_down_x = nx;
            g_last_down_y = ny;
        }
        if (released) {
            ev_zero(&e);
            e.buttons = nb;
            e.button  = released;
            e.type    = GUI_EV_MOUSE_UP;
            ev_push(&e);
        }
        g_mb_prev = nb;
    }
    g_mb = nb;

    if (wheel != 0) {
        ev_zero(&e);
        e.type = GUI_EV_WHEEL;
        e.wheel = wheel;
        ev_push(&e);
    }

    /* --- Клавіатура. Ядро віддає готовий ASCII, скан-код і модифікатори. --- */
    KeyEvent k;
    while (get_key_event(&k)) {
        if (k.scancode & 0x80) continue;      /* відпускання нас не цікавить */
        ev_zero(&e);
        e.type = GUI_EV_KEY;
        e.ascii = k.ascii; e.scancode = k.scancode; e.mods = k.mods;
        ev_push(&e);
    }

    /* --- Такт таймера: миготіння каретки, годинник ---
           Раз на чверть секунди. При 1000 Гц таймера прив'язка до
           9 тіків давала 111 подій на секунду: каретка блимала
           так швидко, що зливалася в суцільну лінію. */
    if (g_ticks - g_last_tick >= 250) {
        g_last_tick = g_ticks;
        ev_zero(&e);
        e.type = GUI_EV_TICK;
        ev_push(&e);
    }

    /* --- Кадровий такт: лише на прохання --- */
    if (g_frame_ms > 0 && g_ticks - g_last_frame >= (uint64_t)g_frame_ms) {
        g_last_frame = g_ticks;
        ev_zero(&e);
        e.type = GUI_EV_FRAME;
        ev_push(&e);
    }
}

int gui_poll(GuiEvent* ev) {
    if (g_evq_tail == g_evq_head) {
        gather();
        if (g_evq_tail == g_evq_head) return 0;
    }
    *ev = g_evq[g_evq_tail];
    g_evq_tail = (g_evq_tail + 1) % EVQ_MAX;
    return 1;
}

void gui_mouse(int* x, int* y, int* buttons) {
    if (x) *x = g_mx;
    if (y) *y = g_my;
    if (buttons) *buttons = g_mb;
}

/* ============================================================
 * КУРСОР
 * ============================================================ */

/* Кожна форма — два бітових шари: mask = де взагалі малюємо,
   fill = де саме білий (решта чорна). Так курсор видно і на
   білому полі, і на чорному. */

static const uint16_t cur_arrow_m[19] = {
    0x8000, 0xC000, 0xE000, 0xF000, 0xF800, 0xFC00, 0xFE00, 0xFF00,
    0xFF80, 0xFFC0, 0xFFE0, 0xFE00, 0xEE00, 0xCE00, 0x8700, 0x0700,
    0x0380, 0x0380, 0x0100
};
static const uint16_t cur_arrow_f[19] = {
    0x0000, 0x4000, 0x6000, 0x7000, 0x7800, 0x7C00, 0x7E00, 0x7F00,
    0x7F80, 0x7C00, 0x6C00, 0x4600, 0x0600, 0x0300, 0x0300, 0x0180,
    0x0180, 0x0100, 0x0000
};

static const uint16_t cur_ibeam_m[14] = {
    0x7F00, 0x7F00, 0x1C00, 0x1C00, 0x1C00, 0x1C00, 0x1C00,
    0x1C00, 0x1C00, 0x1C00, 0x1C00, 0x1C00, 0x7F00, 0x7F00
};
static const uint16_t cur_ibeam_f[14] = {
    0x7F00, 0x4100, 0x1400, 0x1400, 0x1400, 0x1400, 0x1400,
    0x1400, 0x1400, 0x1400, 0x1400, 0x1400, 0x4100, 0x7F00
};

static const uint16_t cur_we_m[7] = {
    0x0810, 0x1818, 0x3FFC, 0x7FFE, 0x3FFC, 0x1818, 0x0810
};
static const uint16_t cur_we_f[7] = {
    0x0000, 0x0810, 0x1FF8, 0x3FFC, 0x1FF8, 0x0810, 0x0000
};

static const uint16_t cur_ns_m[14] = {
    0x1000, 0x3800, 0x7C00, 0xFE00, 0x3800, 0x3800, 0x3800,
    0x3800, 0x3800, 0x3800, 0xFE00, 0x7C00, 0x3800, 0x1000
};
static const uint16_t cur_ns_f[14] = {
    0x0000, 0x1000, 0x3800, 0x7C00, 0x1000, 0x1000, 0x1000,
    0x1000, 0x1000, 0x1000, 0x7C00, 0x3800, 0x1000, 0x0000
};

static const uint16_t cur_nwse_m[12] = {
    0xFC00, 0xF800, 0xF000, 0xF800, 0xDC00, 0x8E00,
    0x0710, 0x03B0, 0x01F0, 0x00F0, 0x01F0, 0x03F0
};
static const uint16_t cur_nwse_f[12] = {
    0x7C00, 0x7800, 0x7000, 0x6800, 0x4400, 0x0200,
    0x0100, 0x0120, 0x00E0, 0x0060, 0x00E0, 0x01E0
};

/* Дзеркальні до попередніх, будуються в gui_init: писати їх
   руками вдруге — зайвий шанс помилитись. */
static uint16_t cur_nesw_m[12];
static uint16_t cur_nesw_f[12];

static const uint16_t cur_wait_m[14] = {
    0xFFF0, 0xFFF0, 0x7FE0, 0x3FC0, 0x1F80, 0x0F00, 0x0600,
    0x0600, 0x0F00, 0x1F80, 0x3FC0, 0x7FE0, 0xFFF0, 0xFFF0
};
static const uint16_t cur_wait_f[14] = {
    0x0000, 0x7FE0, 0x3FC0, 0x1F80, 0x0F00, 0x0600, 0x0000,
    0x0000, 0x0600, 0x0F00, 0x1F80, 0x3FC0, 0x0000, 0x0000
};

typedef struct {
    const uint16_t* mask;
    const uint16_t* fill;
    int w, h, hx, hy;       /* hx/hy — гаряча точка */
} GuiCursorDef;

static GuiCursorDef g_cursors[GUI_CUR_COUNT] = {
    { cur_arrow_m, cur_arrow_f, 12, 19, 0, 0 },
    { cur_ibeam_m, cur_ibeam_f,  9, 14, 4, 7 },
    { cur_we_m,    cur_we_f,    16,  7, 8, 3 },
    { cur_ns_m,    cur_ns_f,     7, 14, 3, 7 },
    { cur_nwse_m,  cur_nwse_f,  12, 12, 6, 6 },
    { cur_nesw_m,  cur_nesw_f,  12, 12, 6, 6 },
    { cur_wait_m,  cur_wait_f,  12, 14, 6, 7 },
};

#define CUR_MAXW 16
#define CUR_MAXH 19

static int      g_cur_shape = GUI_CUR_ARROW;
static int      g_cur_x = -1, g_cur_y = -1;
static int      g_cur_drawn_shape = GUI_CUR_ARROW;
static uint32_t g_cur_save[CUR_MAXW * CUR_MAXH];
static int      g_cur_saved = 0;

static uint16_t mirror12(uint16_t v) {
    /* Рядки зберігаються так, що найлівіший піксель — у біті 15.
       Дзеркалимо перші 12 стовпців, решта нулі. */
    uint16_t out = 0;
    for (int i = 0; i < 12; i++)
        if (v & (0x8000 >> i)) out |= (uint16_t)(0x8000 >> (11 - i));
    return out;
}

static void cursors_build(void) {
    for (int i = 0; i < 12; i++) {
        cur_nesw_m[i] = mirror12(cur_nwse_m[i]);
        cur_nesw_f[i] = mirror12(cur_nwse_f[i]);
    }
}

void gui_cursor_set(int shape) {
    if (shape < 0 || shape >= GUI_CUR_COUNT) shape = GUI_CUR_ARROW;
    g_cur_shape = shape;
}

int gui_cursor_get(void) { return g_cur_shape; }

void gui_cursor_draw(void) {
    if (!g_fb || g_cur_saved) return;   /* уже намальований — спершу erase */

    static int built = 0;
    if (!built) { cursors_build(); built = 1; }

    const GuiCursorDef* c = &g_cursors[g_cur_shape];
    g_cur_drawn_shape = g_cur_shape;
    g_cur_x = g_mx - c->hx;
    g_cur_y = g_my - c->hy;

    /* Курсор малюється поверх усього, тому обрізання на час
       малювання знімаємо — інакше він зникав би над вікном,
       яке звузило область. */
    GuiRect keep = g_clip;
    g_clip.x = 0; g_clip.y = 0; g_clip.w = g_w; g_clip.h = g_h;

    for (int cy = 0; cy < c->h; cy++) {
        int py = g_cur_y + cy;
        if (py < 0 || py >= g_h) continue;
        uint32_t* row = g_fb + (unsigned long)py * g_w;
        uint16_t m = c->mask[cy];
        uint16_t f = c->fill[cy];
        for (int cx = 0; cx < c->w; cx++) {
            int pxx = g_cur_x + cx;
            if (pxx < 0 || pxx >= g_w) continue;
            g_cur_save[cy * CUR_MAXW + cx] = row[pxx];   /* запам'ятали тло */
            uint16_t bit = (uint16_t)(0x8000 >> cx);
            if (!(m & bit)) continue;
            row[pxx] = (f & bit) ? 0x00FFFFFF : 0x00000000;
        }
    }

    g_clip = keep;
    g_cur_saved = 1;
    gui_invalidate(g_cur_x, g_cur_y, c->w, c->h);
}

void gui_cursor_erase(void) {
    if (!g_fb || !g_cur_saved) return;
    const GuiCursorDef* c = &g_cursors[g_cur_drawn_shape];

    for (int cy = 0; cy < c->h; cy++) {
        int py = g_cur_y + cy;
        if (py < 0 || py >= g_h) continue;
        uint32_t* row = g_fb + (unsigned long)py * g_w;
        for (int cx = 0; cx < c->w; cx++) {
            int pxx = g_cur_x + cx;
            if (pxx < 0 || pxx >= g_w) continue;
            row[pxx] = g_cur_save[cy * CUR_MAXW + cx];   /* повернули тло */
        }
    }
    gui_invalidate(g_cur_x, g_cur_y, c->w, c->h);
    g_cur_saved = 0;
}
