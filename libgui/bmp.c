#include "gui.h"

/* ============================================================
 * EUGENE GUI — РАСТРОВІ ЗОБРАЖЕННЯ (BMP)
 *
 * Ядро вміє показувати .BMP лише командою OPEN і лише на весь
 * екран. Вікну ж потрібна картинка як ДАНІ: щоб намалювати її
 * у своїй робочій області, обрізати по межах і масштабувати.
 *
 * Тому формат розбирається тут, у програмі. Нових системних
 * викликів не знадобилося: розмір беремо з самого заголовка BMP,
 * тобто читаємо файл двічі — спершу 54 байти шапки, потім рівно
 * стільки, скільки з неї випливає.
 *
 * Підтримано звичайний нестиснений BMP: 1, 4, 8, 24 і 32 біти на
 * піксель. Стиснення RLE не підтримується — його майже ніхто не
 * використовує, а розбір коштував би вдвічі більше коду.
 * ============================================================ */

#define BMP_HDR   54          /* BITMAPFILEHEADER + BITMAPINFOHEADER */
#define BMP_MAXPX (4096 * 4096)

static uint32_t rd32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd16(const uint8_t* p) {
    return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8));
}
static int rdi32(const uint8_t* p) { return (int)rd32(p); }

typedef struct {
    int      w, h;            /* h < 0 означає, що рядки йдуть зверху вниз */
    int      bpp;
    uint32_t comp;
    uint32_t data_off;
    uint32_t dib_size;
    uint32_t pal_count;
} BmpInfo;

static int bmp_head(const uint8_t* f, BmpInfo* i) {
    if (f[0] != 'B' || f[1] != 'M') return 0;
    i->data_off = rd32(f + 10);
    i->dib_size = rd32(f + 14);
    if (i->dib_size < 40) return 0;          /* старий BITMAPCOREHEADER не беремо */
    i->w   = rdi32(f + 18);
    i->h   = rdi32(f + 22);
    i->bpp = rd16(f + 28);
    i->comp = rd32(f + 30);
    i->pal_count = rd32(f + 46);
    if (i->w <= 0 || i->h == 0) return 0;
    if (i->bpp != 1 && i->bpp != 4 && i->bpp != 8 &&
        i->bpp != 24 && i->bpp != 32) return 0;
    /* 0 = без стиснення, 3 = BI_BITFIELDS (для 32 біт це ті самі сирі пікселі) */
    if (i->comp != 0 && !(i->comp == 3 && i->bpp == 32)) return 0;
    return 1;
}

static int bmp_stride(int w, int bpp) {
    return ((w * bpp + 31) / 32) * 4;
}

static int bmp_abs(int v) { return v < 0 ? -v : v; }

GuiBitmap* bmp_load(const char* filename) {
    uint8_t head[BMP_HDR];
    memset(head, 0, sizeof(head));
    if (read_file_max(filename, head, BMP_HDR) < BMP_HDR) return 0;

    BmpInfo bi;
    if (!bmp_head(head, &bi)) return 0;

    int h = bmp_abs(bi.h);
    if ((long)bi.w * h > BMP_MAXPX) return 0;

    int stride = bmp_stride(bi.w, bi.bpp);
    unsigned long need = (unsigned long)bi.data_off + (unsigned long)stride * h;

    uint8_t* raw = (uint8_t*)malloc(need);
    if (!raw) return 0;
    memset(raw, 0, need);
    if (read_file_max(filename, raw, need) < (uint64_t)bi.data_off) {
        free(raw);
        return 0;
    }

    GuiBitmap* b = (GuiBitmap*)malloc(sizeof(GuiBitmap));
    if (!b) { free(raw); return 0; }
    b->w = bi.w;
    b->h = h;
    b->px = (uint32_t*)malloc((unsigned long)bi.w * h * 4u);
    if (!b->px) { free(b); free(raw); return 0; }

    /* Палітра лежить одразу за заголовком DIB, по 4 байти BGRX */
    const uint8_t* pal = raw + 14 + bi.dib_size;
    int pal_n = (int)bi.pal_count;
    if (pal_n == 0 && bi.bpp <= 8) pal_n = 1 << bi.bpp;

    int top_down = (bi.h < 0);

    for (int y = 0; y < h; y++) {
        /* У BMP рядки зазвичай знизу вгору; від'ємна висота означає навпаки */
        const uint8_t* src = raw + bi.data_off +
                             (unsigned long)stride * (top_down ? y : (h - 1 - y));
        uint32_t* dst = b->px + (unsigned long)y * bi.w;

        for (int x = 0; x < bi.w; x++) {
            uint32_t c = 0;
            if (bi.bpp == 24) {
                const uint8_t* p = src + x * 3;
                c = ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
            } else if (bi.bpp == 32) {
                const uint8_t* p = src + x * 4;
                c = ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
            } else {
                int idx;
                if (bi.bpp == 8)      idx = src[x];
                else if (bi.bpp == 4) idx = (x & 1) ? (src[x >> 1] & 0x0F)
                                                    : (src[x >> 1] >> 4);
                else                  idx = (src[x >> 3] >> (7 - (x & 7))) & 1;
                if (idx < pal_n) {
                    const uint8_t* p = pal + idx * 4;
                    c = ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
                }
            }
            dst[x] = c;
        }
    }

    free(raw);
    return b;
}

void bmp_free(GuiBitmap* b) {
    if (!b) return;
    if (b->px) free(b->px);
    free(b);
}

/* ============================================================
 * ВИВЕДЕННЯ
 *
 * Обрізання рахується один раз на весь виклик, а далі рядки
 * копіюються суцільно. Перевіряти обрізання на кожен піксель на
 * повноекранній картинці — це мільйон зайвих порівнянь на кадр.
 * ============================================================ */

static int clip_dst(int x, int y, int w, int h, GuiRect* out) {
    GuiRect want = { x, y, w, h };
    GuiRect clip;
    gui_clip_get(&clip);
    return gui_rect_isect(&want, &clip, out);
}

void gui_bitmap(const GuiBitmap* b, int x, int y) {
    if (!b || !b->px) return;
    GuiRect d;
    if (!clip_dst(x, y, b->w, b->h, &d)) return;

    int stride;
    uint32_t* fb = gui_fb(&stride);
    if (!fb) return;

    for (int iy = 0; iy < d.h; iy++) {
        const uint32_t* s = b->px + (unsigned long)(d.y - y + iy) * b->w + (d.x - x);
        uint32_t* t = fb + (unsigned long)(d.y + iy) * stride + d.x;
        for (int ix = 0; ix < d.w; ix++) t[ix] = s[ix];
    }
}

void gui_bitmap_key(const GuiBitmap* b, int x, int y, uint32_t key) {
    if (!b || !b->px) return;
    GuiRect d;
    if (!clip_dst(x, y, b->w, b->h, &d)) return;

    int stride;
    uint32_t* fb = gui_fb(&stride);
    if (!fb) return;

    key &= 0x00FFFFFF;
    for (int iy = 0; iy < d.h; iy++) {
        const uint32_t* s = b->px + (unsigned long)(d.y - y + iy) * b->w + (d.x - x);
        uint32_t* t = fb + (unsigned long)(d.y + iy) * stride + d.x;
        for (int ix = 0; ix < d.w; ix++)
            if ((s[ix] & 0x00FFFFFF) != key) t[ix] = s[ix];
    }
}

/* Стовпчики рахуємо ОДИН раз на виклик, а не на кожен піксель.
   Поки цим масштабували значки 32x30, ділення в найтіснішому циклі
   нічого не важило. Полотно програми має розмір екрана, і те саме
   ділення стало коштувати сотні тисяч операцій на кадр. */
#define FIT_MAXW 2048
static int s_fit_col[FIT_MAXW];

void gui_bitmap_fit(const GuiBitmap* b, int x, int y, int w, int h) {
    if (!b || !b->px || w <= 0 || h <= 0) return;
    GuiRect d;
    if (!clip_dst(x, y, w, h, &d)) return;

    int stride;
    uint32_t* fb = gui_fb(&stride);
    if (!fb) return;

    int nw = d.w;
    if (nw > FIT_MAXW) nw = FIT_MAXW;
    for (int ix = 0; ix < nw; ix++) {
        int sx = (d.x - x + ix) * b->w / w;
        if (sx < 0) sx = 0;
        if (sx >= b->w) sx = b->w - 1;
        s_fit_col[ix] = sx;
    }

    for (int iy = 0; iy < d.h; iy++) {
        int sy = (d.y - y + iy) * b->h / h;
        if (sy < 0) sy = 0;
        if (sy >= b->h) sy = b->h - 1;
        const uint32_t* s = b->px + (unsigned long)sy * b->w;
        uint32_t* t = fb + (unsigned long)(d.y + iy) * stride + d.x;
        for (int ix = 0; ix < nw; ix++) t[ix] = s[s_fit_col[ix]];
    }
}
