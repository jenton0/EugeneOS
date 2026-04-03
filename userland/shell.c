#include "stdlib.h"
// === 1. СИСТЕМНІ ВИКЛИКИ ===
static inline void get_mouse(uint32_t* x, uint32_t* y, uint32_t* click) {
    // Викликаємо 11-й сискол через твою ж готову обгортку
    uint64_t res = syscall(11, 0, 0); 
    
    // Розпаковуємо дані з єдиного регістра RAX
    *x = (uint32_t)(res & 0xFFFF);
    *y = (uint32_t)((res >> 16) & 0xFFFF);
    *click = (uint32_t)((res >> 32) & 0xFFFF);
}

// Функція для отримання реального часу (Syscall 12)
void update_clock(char* time_str) {
    register uint64_t rax __asm__("rax") = 12;
    uint64_t rtc_time;
    __asm__ volatile ("int $0x80" : "=a"(rtc_time) : "r"(rax) : "memory");
    
    uint8_t hours = (rtc_time >> 8) & 0xFF;
    uint8_t mins = rtc_time & 0xFF;
    
    int h1 = hours >> 4; int h2 = hours & 0x0F;
    int m1 = mins >> 4;  int m2 = mins & 0x0F;
    
    time_str[0] = '0' + h1;
    time_str[1] = '0' + h2;
    time_str[2] = ':';
    time_str[3] = '0' + m1;
    time_str[4] = '0' + m2;
    time_str[5] = '\0';
}

// === 2. БАЗОВИЙ ШРИФТ 8x8 ===
const uint8_t font8x8[64][8] = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 32 Space */
    {0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00}, /* 33 ! */
    {0x24,0x24,0x24,0x00,0x00,0x00,0x00,0x00}, /* 34 " */
    {0x24,0x24,0x7E,0x24,0x7E,0x24,0x24,0x00}, /* 35 # */
    {0x18,0x3C,0x60,0x3C,0x06,0x3C,0x18,0x00}, /* 36 $ */
    {0x66,0xC6,0x18,0x18,0x30,0x66,0x00,0x00}, /* 37 % */
    {0x38,0x6C,0x38,0x76,0xDC,0x00,0x00,0x00}, /* 38 & */
    {0x18,0x18,0x30,0x00,0x00,0x00,0x00,0x00}, /* 39 ' */
    {0x0C,0x18,0x30,0x30,0x18,0x0C,0x00,0x00}, /* 40 ( */
    {0x30,0x18,0x0C,0x0C,0x18,0x30,0x00,0x00}, /* 41 ) */
    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00}, /* 42 * */
    {0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00}, /* 43 + */
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30}, /* 44 , */
    {0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00}, /* 45 - */
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00}, /* 46 . */
    {0x00,0x60,0x30,0x18,0x0C,0x06,0x00,0x00}, /* 47 / */
    {0x3C,0x66,0x66,0x66,0x66,0x3C,0x00,0x00}, /* 48 0 */
    {0x18,0x38,0x18,0x18,0x18,0x3C,0x00,0x00}, /* 49 1 */
    {0x3C,0x66,0x0C,0x18,0x30,0x7E,0x00,0x00}, /* 50 2 */
    {0x3C,0x66,0x0C,0x0C,0x66,0x3C,0x00,0x00}, /* 51 3 */
    {0x0C,0x1C,0x3C,0x6C,0x7E,0x0C,0x00,0x00}, /* 52 4 */
    {0x7E,0x60,0x3E,0x06,0x06,0x3C,0x00,0x00}, /* 53 5 */
    {0x1C,0x30,0x60,0x3C,0x66,0x3C,0x00,0x00}, /* 54 6 */
    {0x7E,0x06,0x0C,0x18,0x30,0x30,0x00,0x00}, /* 55 7 */
    {0x3C,0x66,0x3C,0x66,0x3C,0x00,0x00,0x00}, /* 56 8 */
    {0x3C,0x66,0x3C,0x06,0x0C,0x38,0x00,0x00}, /* 57 9 */
    {0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00}, /* 58 : */
    {0x00,0x18,0x18,0x00,0x18,0x18,0x30,0x00}, /* 59 ; */
    {0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00}, /* 60 < */
    {0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00}, /* 61 = */
    {0x60,0x30,0x18,0x0C,0x18,0x30,0x60,0x00}, /* 62 > */
    {0x3C,0x66,0x0C,0x18,0x00,0x18,0x00,0x00}, /* 63 ? */
    {0x3C,0x66,0x6E,0x6E,0x60,0x3E,0x00,0x00}, /* 64 @ */
    {0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00}, /* 65 A */
    {0x7E,0x66,0x66,0x7E,0x66,0x66,0x7E,0x00}, /* 66 B */
    {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00}, /* 67 C */
    {0x7C,0x66,0x66,0x66,0x66,0x66,0x7C,0x00}, /* 68 D */
    {0x7E,0x60,0x60,0x78,0x60,0x60,0x7E,0x00}, /* 69 E */
    {0x7E,0x60,0x60,0x78,0x60,0x60,0x60,0x00}, /* 70 F */
    {0x3C,0x66,0x60,0x6E,0x66,0x3C,0x00,0x00}, /* 71 G */
    {0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00}, /* 72 H */
    {0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00}, /* 73 I */
    {0x1E,0x06,0x06,0x06,0x66,0x3C,0x00,0x00}, /* 74 J */
    {0x66,0x6C,0x78,0x78,0x6C,0x66,0x00,0x00}, /* 75 K */
    {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00}, /* 76 L */
    {0x63,0x77,0x7F,0x6B,0x63,0x63,0x00,0x00}, /* 77 M */
    {0x66,0x76,0x7F,0x6E,0x66,0x66,0x00,0x00}, /* 78 N */
    {0x3C,0x66,0x66,0x66,0x66,0x3C,0x00,0x00}, /* 79 O */
    {0x7E,0x66,0x66,0x7E,0x60,0x60,0x00,0x00}, /* 80 P */
    {0x3C,0x66,0x66,0x66,0x6C,0x36,0x00,0x00}, /* 81 Q */
    {0x7E,0x66,0x66,0x7E,0x6C,0x66,0x00,0x00}, /* 82 R */
    {0x3C,0x60,0x3C,0x06,0x66,0x3C,0x00,0x00}, /* 83 S */
    {0x7E,0x18,0x18,0x18,0x18,0x18,0x00,0x00}, /* 84 T */
    {0x66,0x66,0x66,0x66,0x66,0x3C,0x00,0x00}, /* 85 U */
    {0x66,0x66,0x66,0x66,0x3C,0x18,0x00,0x00}, /* 86 V */
    {0x63,0x63,0x6B,0x7F,0x77,0x63,0x00,0x00}, /* 87 W */
    {0x66,0x66,0x3C,0x18,0x3C,0x66,0x00,0x00}, /* 88 X */
    {0x66,0x66,0x3C,0x18,0x18,0x18,0x00,0x00}, /* 89 Y */
    {0x7E,0x06,0x0C,0x18,0x30,0x7E,0x00,0x00}, /* 90 Z */
    {0x3C,0x30,0x30,0x30,0x30,0x3C,0x00,0x00}, /* 91 [ */
    {0x00,0x06,0x0C,0x18,0x30,0x60,0x00,0x00}, /* 92 \ */
    {0x3C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00,0x00}, /* 93 ] */
    {0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00}, /* 94 _ */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}  /* 95 Space/Err */
};

const char scancodes[128] = {
    0, 0, '1','2','3','4','5','6','7','8','9','0','-','=', 0, 0,
    'Q','W','E','R','T','Y','U','I','O','P','[',']', 0, 0,
    'A','S','D','F','G','H','J','K','L',';','\'','`', 0, '\\',
    'Z','X','C','V','B','N','M',',','.','/', 0, '*', 0, ' '
};

char my_toupper(char c) {
    if (c >= 'a' && c <= 'z') return c - 32;
    return c;
}

// === 3. ВІКОННА ПІДСИСТЕМА РЕНДЕРУ ===
#define WIN_W 1024
#define WIN_H 768
uint32_t* win_buffer;

void win_draw_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t color) {
    for (uint32_t iy = y; iy < y + h; iy++)
        for (uint32_t ix = x; ix < x + w; ix++)
            if (ix < WIN_W && iy < WIN_H) win_buffer[iy * WIN_W + ix] = color;
}

void win_draw_char(char c, uint32_t x, uint32_t y, uint32_t color) {
    int idx = my_toupper(c) - 32;
    if (idx < 0 || idx > 63) idx = 0;
    for (int cy = 0; cy < 8; cy++) {
        uint8_t row = font8x8[idx][cy];
        for (int cx = 0; cx < 8; cx++)
            if ((row >> (7 - cx)) & 1)
                if (x + cx < WIN_W && y + cy < WIN_H)
                    win_buffer[(y + cy) * WIN_W + (x + cx)] = color;
    }
}

void win_draw_string(char* text, uint32_t x, uint32_t y, uint32_t color) {
    uint32_t cx = x;
    for (int i = 0; text[i] != '\0'; i++) {
        win_draw_char(text[i], cx, y, color);
        cx += 9;
    }
}

// === 4. АРХІТЕКТУРА БАГАТОВІКОННОСТІ ===
#define MAX_WINDOWS 5
#define APP_CONSOLE  1
#define APP_EDITOR   2
#define APP_EXPLORER 3

typedef struct {
    int is_open;
    int is_minimized;
    uint32_t x, y, w, h;
    char title[32];
    int app_type;
    char text_buffer[2048];
    int text_len;
} Window;

Window windows[MAX_WINDOWS];
int active_window_idx = 0;

char* my_strcpy(char* dest, const char* src) {
    char* d = dest;
    while ((*d++ = *src++) != '\0');
    return dest;
}

char* my_strcat(char* dest, const char* src) {
    char* d = dest;
    while (*d != '\0') d++;
    while ((*d++ = *src++) != '\0');
    return dest;
}

int my_strcmp(const char* s1, const char* s2) {
    while (*s1 && (*s1 == *s2)) { s1++; s2++; }
    return *(const unsigned char*)s1 - *(const unsigned char*)s2;
}

// Порівняння перших N символів
int my_strncmp(const char* s1, const char* s2, int n) {
    for (int i = 0; i < n; i++) {
        if (s1[i] != s2[i]) return (unsigned char)s1[i] - (unsigned char)s2[i];
        if (s1[i] == '\0') return 0;
    }
    return 0;
}

// Довжина рядка
int my_strlen(const char* s) {
    int i = 0;
    while (s[i]) i++;
    return i;
}

// Конвертуємо число в рядок (десяткова)
void num_to_dec(int val, char* buf) {
    if (val == 0) { buf[0] = '0'; buf[1] = '\0'; return; }
    char tmp[16];
    int i = 0;
    int neg = 0;
    if (val < 0) { neg = 1; val = -val; }
    while (val > 0) { tmp[i++] = '0' + (val % 10); val /= 10; }
    if (neg) tmp[i++] = '-';
    int j = 0;
    for (int k = i - 1; k >= 0; k--) buf[j++] = tmp[k];
    buf[j] = '\0';
}

int create_window(char* title, int type, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (!windows[i].is_open) {
            windows[i].is_open = 1;
            windows[i].is_minimized = 0;
            windows[i].x = x; windows[i].y = y;
            windows[i].w = w; windows[i].h = h;
            my_strcpy(windows[i].title, title);
            windows[i].app_type = type;
            windows[i].text_len = 0;
            windows[i].text_buffer[0] = '\0';
            active_window_idx = i;
            return i;
        }
    }
    return -1;
}

// === 5. СИСТЕМА ЛОГІВ КОНСОЛІ ===
#define MAX_LINES 15
char history_log[MAX_LINES][100] = {0};
int log_count = 0;

void add_log(char* text) {
    if (log_count >= MAX_LINES) {
        for(int i = 0; i < MAX_LINES - 1; i++) my_strcpy(history_log[i], history_log[i+1]);
        log_count = MAX_LINES - 1;
    }
    my_strcpy(history_log[log_count++], text);
}

// === ГЛОБАЛЬНІ ДАНІ ПРОВІДНИКА ===
char expl_files[50][16];
int expl_count = 0;
int expl_refresh = 1;
int expl_selected = -1;   // ← НОВЕ: індекс виділеного файлу

// === ГЛОБАЛЬНІ ДАНІ РЕДАКТОРА ===
int editor_cursor = 0;    // ← НОВЕ: позиція курсору в тексті

// Форматуємо FAT-ім'я ("TEST    TXT" → "TEST.TXT")
void format_fat_name(char* fat_name, char* normal_name) {
    int d = 0;
    for(int i=0; i<8; i++)
        if (fat_name[i] != ' ' && fat_name[i] != '\\') normal_name[d++] = fat_name[i];
    if (fat_name[8] != ' ' && fat_name[8] != '\\') {
        normal_name[d++] = '.';
        for(int i=8; i<11; i++)
            if (fat_name[i] != ' ') normal_name[d++] = fat_name[i];
    }
    normal_name[d] = '\0';
}

// Знаходимо вікно за типом (або -1)
int find_window(int app_type) {
    for (int i = 0; i < MAX_WINDOWS; i++)
        if (windows[i].is_open && windows[i].app_type == app_type) return i;
    return -1;
}

// Фокусуємо вікно: розгортаємо + ставимо активним
void focus_window(int idx) {
    if (idx < 0) return;
    windows[idx].is_minimized = 0;
    active_window_idx = idx;
}

// Завантажуємо файл у редактор (викликається з Провідника або команди OPEN)
void load_file_into_editor(char* fat_name) {
    int eidx = find_window(APP_EDITOR);
    if (eidx < 0) return;

    char normal_name[16];
    format_fat_name(fat_name, normal_name);

    my_strcpy(windows[eidx].title, "TXT REDAKT - ");
    my_strcat(windows[eidx].title, normal_name);

    uint64_t size = read_file(fat_name, windows[eidx].text_buffer);
    if (size > 0 && size < 2048) {
        windows[eidx].text_len = (int)size;
        windows[eidx].text_buffer[size] = '\0';
    } else {
        my_strcpy(windows[eidx].text_buffer, "ERROR: FILE TOO LARGE OR NOT FOUND");
        windows[eidx].text_len = 34;
    }
    editor_cursor = 0;
    focus_window(eidx);
}

// === 6. ТОЧКА ВХОДУ (GUI EVENT LOOP) ===
void gui_main() {
    clear_screen();
    init_heap();

    win_buffer = (uint32_t*)malloc(WIN_W * WIN_H * 4);
    if (win_buffer == 0) {
        print("\nFATAL ERROR: OUT OF MEMORY!\n", 0x00FF0000);
        while(1);
    }

    for(int i=0; i<MAX_WINDOWS; i++) windows[i].is_open = 0;

    create_window("C-SHELL CONSOLE", APP_CONSOLE,  50,  50, 400, 350);
    create_window("TXT REDAKT",      APP_EDITOR,  150, 100, 450, 300);
    create_window("PROVIDNYK",       APP_EXPLORER,500, 200, 400, 400);

    uint32_t mx, my, mclick;
    int is_dragging  = 0;
    uint32_t drag_off_x = 0, drag_off_y = 0;

    char cmd_buffer[80] = {0};
    int cmd_len = 0;
    int text_changed = 1;
    int win_moved    = 1;

    char time_str[10] = "00:00";
    uint64_t last_ticks = 0;

    add_log("=== EUGENE OS GUI SHELL ===");
    add_log("TYPE 'HELP' FOR COMMANDS.");

    while (1) {
        // --- ГОДИННИК ---
        uint64_t ticks = get_ticks();
        if (ticks - last_ticks > 50) {
            update_clock(time_str);
            win_moved = 1;
            last_ticks = ticks;
        }

        // --- ОБРОБКА МИШІ ---
        // --- ОБРОБКА МИШІ ---
        static uint32_t old_mclick = 0; // Додаємо збереження попереднього стану
        get_mouse(&mx, &my, &mclick);
        
        // Флаг одноразового кліку (спрацює лише 1 раз при натисканні)
        int is_click = (mclick == 1 && old_mclick == 0);

        if (mclick == 1) {
            // --- ОДНОРАЗОВІ ДІЇ ПРИ КЛІКУ ---
            if (is_click) {
                // 1. Клік по панелі завдань
                if (my >= WIN_H - 30) {
                    uint32_t btn_x = 65;
                    for (int i = 0; i < MAX_WINDOWS; i++) {
                        if (windows[i].is_open) {
                            if (mx >= btn_x && mx <= btn_x + 120) {
                                windows[i].is_minimized = !windows[i].is_minimized;
                                if (!windows[i].is_minimized) active_window_idx = i;
                                win_moved = 1;
                            }
                            btn_x += 125;
                        }
                    }
                }
                // 2. Кліки по Провіднику (тільки якщо активний і не згорнутий)
                else if (windows[active_window_idx].app_type == APP_EXPLORER && !windows[active_window_idx].is_minimized) {
                    Window* exp = &windows[active_window_idx];
                    if (mx >= exp->x + 10 && mx <= exp->x + exp->w - 20 &&
                        my >= exp->y + 55 && my <= exp->y + exp->h - 10) {

                        int clicked_idx = (my - (exp->y + 60)) / 15;
                        if (clicked_idx >= 0 && clicked_idx < expl_count) {
                            expl_selected = clicked_idx;
                            win_moved = 1;
                            char* cfn = expl_files[clicked_idx];
                            if (cfn[8] == 'T' && cfn[9] == 'X' && cfn[10] == 'T') {
                                load_file_into_editor(cfn);
                            }
                        }
                    }
                }
                
                // 3. Зміна фокусу та кнопки вікна
                if (my < WIN_H - 30) {
                    int hit_idx = -1;
                    
                    // Спочатку перевіряємо активне вікно (воно завжди нагорі)
                    if (!windows[active_window_idx].is_minimized && windows[active_window_idx].is_open) {
                        Window* w = &windows[active_window_idx];
                        if (mx >= w->x && mx <= w->x + w->w && my >= w->y && my <= w->y + w->h) {
                            hit_idx = active_window_idx;
                        }
                    }
                    
                    // Якщо клікнули повз активне, перевіряємо інші
                    if (hit_idx == -1) {
                        for (int i = 0; i < MAX_WINDOWS; i++) {
                            if (!windows[i].is_open || windows[i].is_minimized || i == active_window_idx) continue;
                            Window* w = &windows[i];
                            if (mx >= w->x && mx <= w->x + w->w && my >= w->y && my <= w->y + w->h) {
                                hit_idx = i;
                            }
                        }
                    }

                    // Обробляємо клік по знайденому вікну
                    if (hit_idx != -1) {
                        if (hit_idx != active_window_idx) {
                            active_window_idx = hit_idx;
                            win_moved = 1;
                        }
                        
                        Window* act = &windows[active_window_idx];
                        // Перевірка шапки вікна (закриття або драг)
                        if (my >= act->y && my <= act->y + 24) {
                            if (mx >= act->x + act->w - 24 && mx <= act->x + act->w - 4) {
                                act->is_open = 0; // Закрити
                                win_moved = 1;
                            } else {
                                is_dragging = 1;  // Почати перетягування
                                drag_off_x = mx - act->x;
                                drag_off_y = my - act->y;
                            }
                        }
                    }
                }
            }
            
            // --- БЕЗПЕРЕРВНІ ДІЇ (Утримання кнопки) ---
            if (is_dragging && !windows[active_window_idx].is_minimized) {
                windows[active_window_idx].x = mx - drag_off_x;
                windows[active_window_idx].y = my - drag_off_y;
                win_moved = 1;
            }

        } else {
            is_dragging = 0; // Відпустили мишу
        }
        old_mclick = mclick; // Зберігаємо стан для наступного кадру

        // ===================================================
        // --- ОБРОБКА КЛАВІАТУРИ ---
        // ===================================================
        uint64_t key = get_key();
        if (key > 0 && key < 0x80 && !windows[active_window_idx].is_minimized) {
            Window* act = &windows[active_window_idx];

            // -----------------------------------------------
            // КОНСОЛЬ
            // -----------------------------------------------
            if (act->app_type == APP_CONSOLE) {
                if (key == 0x1C) { // ENTER
                    cmd_buffer[cmd_len] = '\0';
                    char full_cmd[100] = "C-SHELL:/> ";
                    my_strcat(full_cmd, cmd_buffer);
                    add_log(full_cmd);

                    // ---------- ДОПОМОГА ----------
                    if (my_strcmp(cmd_buffer, "HELP") == 0) {
                        add_log("HELP  CLEAR/CLS  TIME  VER");
                        add_log("ECHO <text>  LIST  OPEN <name>");
                        add_log("EDIT  BROWSE  BENCHMARK  EXIT");
                    }
                    // ---------- CLEAR / CLS ----------
                    else if (my_strcmp(cmd_buffer, "CLEAR") == 0 ||
                             my_strcmp(cmd_buffer, "CLS") == 0) {
                        log_count = 0;
                    }
                    // ---------- TIME ----------
                    else if (my_strcmp(cmd_buffer, "TIME") == 0) {
                        char msg[30] = "CURRENT TIME: ";
                        my_strcat(msg, time_str);
                        add_log(msg);
                    }
                    // ---------- VER ----------
                    else if (my_strcmp(cmd_buffer, "VER") == 0) {
                        add_log("EUGENE OS v0.1 (C-SHELL 1.0)");
                        add_log("BUILD: GUI MULTITASK MODE");
                    }
                    // ---------- ECHO ----------
                    else if (my_strncmp(cmd_buffer, "ECHO ", 5) == 0) {
                        add_log(cmd_buffer + 5); // Виводимо все після "ECHO "
                    }
                    // ---------- LIST (список файлів) ----------
                    else if (my_strcmp(cmd_buffer, "LIST") == 0) {
                        // Оновлюємо кеш провідника
                        expl_refresh = 1;
                        // Рахуємо файли
                        char files_buf[2048];
                        syscall(13, (uint64_t)files_buf, 0);
                        int count = 0;
                        for (int f = 0; files_buf[f] != '\0'; f++)
                            if (files_buf[f] == '\n') count++;
                        char msg[50] = "FILES IN DIR: ";
                        char num[8];
                        num_to_dec(count, num);
                        my_strcat(msg, num);
                        add_log(msg);
                        add_log("(SEE EXPLORER WINDOW)");
                    }
                    // ---------- OPEN <filename> ----------
                    else if (my_strncmp(cmd_buffer, "OPEN ", 5) == 0) {
                        char* fname = cmd_buffer + 5;
                        // Шукаємо у списку файлів
                        int found = 0;
                        for (int f = 0; f < expl_count; f++) {
                            char normal[16];
                            format_fat_name(expl_files[f], normal);
                            if (my_strcmp(normal, fname) == 0) {
                                load_file_into_editor(expl_files[f]);
                                add_log("FILE OPENED IN EDITOR.");
                                found = 1;
                                break;
                            }
                        }
                        if (!found) {
                            char msg[60] = "FILE NOT FOUND: ";
                            my_strcat(msg, fname);
                            add_log(msg);
                        }
                        win_moved = 1;
                    }
                    // ---------- EDIT (фокус на редактор) ----------
                    else if (my_strcmp(cmd_buffer, "EDIT") == 0) {
                        int idx = find_window(APP_EDITOR);
                        if (idx >= 0) { focus_window(idx); add_log("SWITCHED TO EDITOR."); }
                        else add_log("EDITOR NOT OPEN.");
                    }
                    // ---------- BROWSE (фокус на провідник) ----------
                    else if (my_strcmp(cmd_buffer, "BROWSE") == 0) {
                        int idx = find_window(APP_EXPLORER);
                        if (idx >= 0) { focus_window(idx); add_log("SWITCHED TO EXPLORER."); }
                        else add_log("EXPLORER NOT OPEN.");
                    }
                    // ---------- BENCHMARK ----------
                    else if (my_strcmp(cmd_buffer, "BENCHMARK") == 0) {
                        add_log("BENCHMARK: VFS NOT LINKED YET");
                    }
                    // ---------- EXIT ----------
                    else if (my_strcmp(cmd_buffer, "EXIT") == 0) {
                        clear_screen();
                        syscall(0,0,0);
                    }
                    else if (cmd_len > 0) {
                        char msg[80] = "UNKNOWN CMD: ";
                        my_strcat(msg, cmd_buffer);
                        add_log(msg);
                    }

                    cmd_len = 0;
                    cmd_buffer[0] = '\0';
                    text_changed = 1;
                    win_moved = 1;

                } else if (key == 0x0E) { // BACKSPACE
                    if (cmd_len > 0) { cmd_buffer[--cmd_len] = '\0'; text_changed = 1; win_moved = 1; }
                } else {
                    char c = scancodes[key];
                    if (c != 0 && cmd_len < 60) {
                        cmd_buffer[cmd_len++] = c;
                        cmd_buffer[cmd_len]   = '\0';
                        text_changed = 1; win_moved = 1;
                    }
                }
            }

            // -----------------------------------------------
            // ← НОВЕ: РЕДАКТОР — повноцінне редагування
            // -----------------------------------------------
            else if (act->app_type == APP_EDITOR) {
                if (key == 0x1C) { // ENTER → вставляємо \n
                    if (act->text_len < 2046) {
                        for (int i = act->text_len; i > editor_cursor; i--)
                            act->text_buffer[i] = act->text_buffer[i-1];
                        act->text_buffer[editor_cursor] = '\n';
                        act->text_len++;
                        act->text_buffer[act->text_len] = '\0';
                        editor_cursor++;
                        text_changed = 1; win_moved = 1;
                    }
                } else if (key == 0x0E) { // BACKSPACE
                    if (editor_cursor > 0 && act->text_len > 0) {
                        for (int i = editor_cursor - 1; i < act->text_len - 1; i++)
                            act->text_buffer[i] = act->text_buffer[i+1];
                        act->text_len--;
                        act->text_buffer[act->text_len] = '\0';
                        editor_cursor--;
                        text_changed = 1; win_moved = 1;
                    }
                } else if (key == 0x4B) { // СТРІЛКА ЛІВОРУЧ
                    if (editor_cursor > 0) { editor_cursor--; win_moved = 1; }
                } else if (key == 0x4D) { // СТРІЛКА ПРАВОРУЧ
                    if (editor_cursor < act->text_len) { editor_cursor++; win_moved = 1; }
                } else if (key == 0x48) { // СТРІЛКА ВГОРУ (переходимо на рядок вище)
                    // Знаходимо попередній \n
                    int pos = editor_cursor - 1;
                    while (pos > 0 && act->text_buffer[pos] != '\n') pos--;
                    if (pos > 0) editor_cursor = pos;
                    else editor_cursor = 0;
                    win_moved = 1;
                } else if (key == 0x50) { // СТРІЛКА ВНИЗ (переходимо на рядок нижче)
                    int pos = editor_cursor;
                    while (pos < act->text_len && act->text_buffer[pos] != '\n') pos++;
                    if (pos < act->text_len) editor_cursor = pos + 1;
                    else editor_cursor = act->text_len;
                    win_moved = 1;
                } else { // Звичайний символ → вставляємо у позицію курсору
                    char c = scancodes[key];
                    if (c != 0 && act->text_len < 2046) {
                        for (int i = act->text_len; i > editor_cursor; i--)
                            act->text_buffer[i] = act->text_buffer[i-1];
                        act->text_buffer[editor_cursor] = c;
                        act->text_len++;
                        act->text_buffer[act->text_len] = '\0';
                        editor_cursor++;
                        text_changed = 1; win_moved = 1;
                    }
                }
            }

            // -----------------------------------------------
            // ← НОВЕ: ПРОВІДНИК — навігація клавіатурою
            // -----------------------------------------------
            else if (act->app_type == APP_EXPLORER) {
                if (key == 0x48) { // СТРІЛКА ВГОРУ
                    if (expl_selected > 0) { expl_selected--; win_moved = 1; }
                } else if (key == 0x50) { // СТРІЛКА ВНИЗ
                    if (expl_selected < expl_count - 1) { expl_selected++; win_moved = 1; }
                } else if (key == 0x1C) { // ENTER — відкрити виділений файл
                    if (expl_selected >= 0 && expl_selected < expl_count) {
                        char* cfn = expl_files[expl_selected];
                        if (cfn[8] == 'T' && cfn[9] == 'X' && cfn[10] == 'T') {
                            load_file_into_editor(cfn);
                            win_moved = 1;
                        }
                    }
                }
            }
        }

        // ===================================================
        // --- РЕНДЕР (тільки якщо щось змінилося) ---
        // ===================================================
        if (win_moved || text_changed) {
            // Шпалери
            win_draw_rect(0, 0, WIN_W, WIN_H, 0x00105050);

            // Відмальовка вікон (Z-Index: неактивні спочатку, активне зверху)
            for (int z = 0; z < 2; z++) {
                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (!windows[i].is_open || windows[i].is_minimized) continue;
                    if ((z == 0 && i == active_window_idx) || (z == 1 && i != active_window_idx)) continue;

                    Window* w = &windows[i];
                    uint32_t header_color = (i == active_window_idx) ? 0x000000AA : 0x00808080;

                    win_draw_rect(w->x,   w->y,   w->w,   w->h,   0x00000000); // Рамка
                    win_draw_rect(w->x+2, w->y+2, w->w-4, w->h-4, 0x00C0C0C0); // Фон
                    win_draw_rect(w->x+2, w->y+2, w->w-4, 24,     header_color); // Заголовок
                    win_draw_string(w->title, w->x + 10, w->y + 8, 0x00FFFFFF);

                    // Кнопка [X]
                    win_draw_rect(w->x + w->w - 24, w->y + 4, 20, 18, 0x00AA0000);
                    win_draw_string("X", w->x + w->w - 18, w->y + 8, 0x00FFFFFF);

                    // ==========================================
                    // КОНСОЛЬ
                    // ==========================================
                    if (w->app_type == APP_CONSOLE) {
                        win_draw_rect(w->x+4, w->y+28, w->w-8, w->h-32, 0x00000000);
                        uint32_t text_y = w->y + 35;
                        for (int l = 0; l < log_count; l++) {
                            win_draw_string(history_log[l], w->x + 10, text_y, 0x00CCCCCC);
                            text_y += 20;
                        }
                        // Рядок вводу з курсором
                        char prompt[100] = "C-SHELL:/> ";
                        my_strcat(prompt, cmd_buffer);
                        win_draw_string(prompt, w->x + 10, text_y, 0x0000FF00);
                        // Курсор-мигалка (завжди показуємо)
                        int prompt_len = my_strlen(prompt);
                        win_draw_rect(w->x + 10 + prompt_len * 9, text_y, 2, 10, 0x0000FF00);
                    }

                    // ==========================================
                    // ← ОНОВЛЕНО: РЕДАКТОР з курсором
                    // ==========================================
                    else if (w->app_type == APP_EDITOR) {
                        win_draw_rect(w->x+10, w->y+35, w->w-20, w->h-45, 0x00FFFFFF); // Біле поле

                        uint32_t tx = w->x + 15;
                        uint32_t ty = w->y + 40;

                        if (w->text_len > 0 || (i == active_window_idx)) {
                            for (int ci = 0; ci <= w->text_len; ci++) {
                                // Малюємо курсор у поточній позиції
                                if (ci == editor_cursor && i == active_window_idx) {
                                    win_draw_rect(tx, ty, 2, 12, 0x00FF0000); // Червоний курсор
                                }
                                if (ci == w->text_len) break;

                                char ch = w->text_buffer[ci];
                                if (ch == '\n' || ch == '\r') {
                                    if (ch == '\n') { tx = w->x + 15; ty += 14; }
                                } else if (ch >= 32) {
                                    // Перенос якщо дійшли до краю
                                    if (tx > w->x + w->w - 20) { tx = w->x + 15; ty += 14; }
                                    win_draw_char(ch, tx, ty, 0x00000000);
                                    tx += 9;
                                }
                                if (ty > w->y + w->h - 20) break;
                            }
                        } else {
                            // Порожній редактор — підказка + курсор
                            win_draw_string("TUT BUDE TEXT...", w->x+15, w->y+40, 0x00AAAAAA);
                            win_draw_rect(w->x + 15, w->y + 40, 2, 12, 0x00FF0000);
                        }

                        // Статус-рядок унизу редактора
                        win_draw_rect(w->x+10, w->y + w->h - 18, w->w - 20, 14, 0x00AAAAAA);
                        char stat[40] = "LEN:";
                        char num[8]; num_to_dec(w->text_len, num);
                        my_strcat(stat, num);
                        my_strcat(stat, " CUR:");
                        num_to_dec(editor_cursor, num);
                        my_strcat(stat, num);
                        win_draw_string(stat, w->x + 14, w->y + w->h - 16, 0x00000000);
                    }

                    // ==========================================
                    // ← ОНОВЛЕНО: ПРОВІДНИК з підсвічуванням
                    // ==========================================
                    else if (w->app_type == APP_EXPLORER) {
                        win_draw_rect(w->x+10, w->y+35, w->w-20, w->h-45, 0x00FFFFFF);
                        win_draw_string("CURRENT DIRECTORY:", w->x+15, w->y+40, 0x00000055);

                        // Оновлюємо кеш файлів якщо треба
                        if (expl_refresh) {
                            char files_buf[2048];
                            syscall(13, (uint64_t)files_buf, 0);
                            expl_count = 0;
                            int t_idx = 0;
                            for (int f = 0; files_buf[f] != '\0'; f++) {
                                if (files_buf[f] == '\n') {
                                    expl_files[expl_count][t_idx] = '\0';
                                    expl_count++;
                                    t_idx = 0;
                                    if (expl_count >= 50) break;
                                } else {
                                    if (t_idx < 15) expl_files[expl_count][t_idx++] = files_buf[f];
                                }
                            }
                            expl_refresh = 0;
                            expl_selected = -1; // Скидаємо виділення після оновлення
                        }

                        // Малюємо файли
                        uint32_t fy = w->y + 60;
                        for (int f = 0; f < expl_count; f++) {
                            if (fy + 15 > w->y + w->h - 20) break;

                            // ← НОВЕ: підсвічування вибраного рядка
                            if (f == expl_selected) {
                                win_draw_rect(w->x + 12, fy - 1, w->w - 24, 14, 0x000000AA);
                                win_draw_string(expl_files[f], w->x+15, fy, 0x00FFFFFF);
                            } else {
                                // Папки — темно-жовті, файли — сині
                                char* cfn = expl_files[f];
                                int is_dir = (cfn[8] == ' ' || cfn[8] == '\\');
                                uint32_t fc = is_dir ? 0x00886600 : 0x000000CC;
                                win_draw_string(cfn, w->x+15, fy, fc);
                            }
                            fy += 15;
                        }

                        // Статус-рядок провідника
                        win_draw_rect(w->x+10, w->y + w->h - 20, w->w - 20, 14, 0x00AAAAAA);
                        char stat[30] = "FILES: ";
                        char num[8]; num_to_dec(expl_count, num);
                        my_strcat(stat, num);
                        if (expl_selected >= 0) {
                            my_strcat(stat, "  SEL: ");
                            my_strcat(stat, expl_files[expl_selected]);
                        }
                        win_draw_string(stat, w->x + 14, w->y + w->h - 18, 0x00000000);
                    }
                }
            }

            // --- ПАНЕЛЬ ЗАВДАНЬ ---
            win_draw_rect(0, WIN_H - 30, WIN_W, 30, 0x00C0C0C0);
            win_draw_rect(0, WIN_H - 30, WIN_W, 2,  0x00FFFFFF);

            win_draw_rect(4, WIN_H - 26, 56, 22, 0x00AAAAAA);
            win_draw_string("ESP", 15, WIN_H - 20, 0x00000000);

            uint32_t btn_x = 65;
            for (int i = 0; i < MAX_WINDOWS; i++) {
                if (windows[i].is_open) {
                    uint32_t btn_col = (i == active_window_idx && !windows[i].is_minimized)
                                       ? 0x00888888 : 0x00AAAAAA;
                    win_draw_rect(btn_x, WIN_H - 26, 120, 22, btn_col);
                    win_draw_string(windows[i].title, btn_x + 8, WIN_H - 20, 0x00000000);
                    btn_x += 125;
                }
            }

            // Годинник
            win_draw_rect(WIN_W - 70, WIN_H - 26, 60, 22, 0x00888888);
            win_draw_string(time_str, WIN_W - 60, WIN_H - 20, 0x00000000);

            blit_buffer(win_buffer, 0, 0, WIN_W, WIN_H);
            win_moved    = 0;
            text_changed = 0;
        }
    }
}