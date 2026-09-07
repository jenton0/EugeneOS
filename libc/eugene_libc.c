#include "stdlib.h"

/* ============================================================
 * ВИПРАВЛЕННЯ В ЦЬОМУ ФАЙЛІ:
 *  1) malloc() вирівнює блоки на 16 байт — інакше movaps/SSE по
 *     виділеній пам'яті падає з #GP;
 *  2) прибрано fabs()/atof() (повертали double -> несумісно з
 *     -mgeneral-regs-only, а планувальник ядра не зберігає стан FPU);
 *  3) open() більше не з'їдає 64 МБ купи з 64 МБ наявних;
 *  4) read_file() тепер викликається з лімітом розміру буфера;
 *  5) діагностичний друк схований за LIBC_DEBUG (був увімкнений
 *     завжди і засмічував екран на кожному fread).
 * ============================================================ */
#define LIBC_DEBUG 0
#if LIBC_DEBUG
  #define DBG(buf, col) print((buf), (col))
#else
  #define DBG(buf, col) ((void)0)
#endif

// ==========================================
// 1. СТРУКТУРИ ФАЙЛОВОЇ СИСТЕМИ
// ==========================================
typedef struct {
    unsigned char* data;
    long size;
    long pos;
} DOOM_FILE;

#define MAX_OPEN_FILES 8
static DOOM_FILE* open_files[MAX_OPEN_FILES] = {0};

// fd 3..10 → індекс 0..7
/* alloc_fd() прибрано: розподілом дескрипторів тепер керує ядро */

static DOOM_FILE* get_file(int fd) {
    int idx = fd - 3;
    if (idx < 0 || idx >= MAX_OPEN_FILES) return 0;
    return open_files[idx];
}

// Хелпери для FILE* <-> int без -Wpointer-to-int-cast / -Wint-to-pointer-cast.
// Юніон дозволяє компілятору бачити це як реінтерпретацію, а не небезпечний каст.
static inline FILE* _fd_to_FILE(int fd) {
    union { void* p; unsigned long u; } c;
    c.u = (unsigned long)(unsigned int)fd;
    return (FILE*)c.p;
}

static inline int _FILE_to_fd(FILE* f) {
    union { void* p; unsigned long u; } c;
    c.p = (void*)f;
    return (int)(unsigned int)c.u;
}

// ==========================================
// 2. МЕНЕДЖЕР ПАМ'ЯТІ
// ==========================================
/* КРИТИЧНО: адреса мусить збігатися з UserHeapBase у kernel.asm.
 *
 * Раніше тут стояло 0x8000000 — рівно там, де ядро тримає буфери
 * файлових дескрипторів (FileDataBase, 64 МБ). Купа й буфери
 * повністю накладалися: програма, яка виділяла пам'ять і водночас
 * тримала відкритий файл, затирала власні дані.
 *
 * Тепер купа лежить вище за все інше — на 256 МБ. */
#define HEAP_START 0x10000000  /* 256 МБ */
#define HEAP_SIZE  0x8000000   /* 128 МБ */

typedef struct Block {
    uint32_t size;
    uint32_t free;
    struct Block *next;
} Block;

static Block *heap_list = (Block*)HEAP_START;

void init_heap(void) {
    heap_list->size = HEAP_SIZE - sizeof(Block);
    heap_list->free = 1;
    heap_list->next = 0;
}

void* malloc(size_t size) {
    if (size == 0) return 0;
    /* ВИПРАВЛЕНО: округлюємо до 16 байт, щоб КОЖЕН наступний блок
       теж був вирівняний. Інакше другий malloc() повертає адресу,
       кратну 8, і будь-який movaps по ній = #GP. */
    size = (size + 15u) & ~(size_t)15u;
    Block *curr = heap_list;
    while (curr) {
        if (curr->free && curr->size >= size) {
            if (curr->size > size + sizeof(Block) + 16) {
                Block *nb = (Block*)((char*)curr + sizeof(Block) + size);
                nb->size = curr->size - size - sizeof(Block);
                nb->free = 1;
                nb->next = curr->next;
                curr->next = nb;
                curr->size = size;
            }
            curr->free = 0;
            return (void*)(curr + 1);
        }
        curr = curr->next;
    }
    return 0;
}

void free(void* ptr) {
    if (!ptr) return;
    Block *b = (Block*)ptr - 1;
    b->free = 1;
    while (b->next && b->next->free) {
        b->size += sizeof(Block) + b->next->size;
        b->next = b->next->next;
    }
}

// ==========================================
// 3. РЯДКИ ТА УТИЛІТИ
// ==========================================
int toupper(int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }
int tolower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
int abs(int j)     { return j < 0 ? -j : j; }
int isspace(int c) { return (c==' '||c=='\t'||c=='\n'||c=='\v'||c=='\f'||c=='\r'); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isalpha(int c) { return (c>='a'&&c<='z')||(c>='A'&&c<='Z'); }
int isalnum(int c) { return isdigit(c) || isalpha(c); }

int atoi(const char *str) {
    int res = 0, sign = 1, i = 0;
    while (isspace((unsigned char)str[i])) i++;
    if (str[i] == '-') { sign = -1; i++; }
    else if (str[i] == '+') i++;
    for (; str[i] >= '0' && str[i] <= '9'; ++i)
        res = res * 10 + str[i] - '0';
    return sign * res;
}

void* memcpy(void* dest, const void* src, unsigned long n) {
    unsigned char* d = (unsigned char*)dest;
    const unsigned char* s = (const unsigned char*)src;
    for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    return dest;
}

void* memset(void* str, int c, unsigned long n) {
    unsigned char* s = (unsigned char*)str;
    for (unsigned long i = 0; i < n; i++) s[i] = (unsigned char)c;
    return str;
}

int memcmp(const void* s1, const void* s2, unsigned long n) {
    const unsigned char* a = (const unsigned char*)s1;
    const unsigned char* b = (const unsigned char*)s2;
    for (unsigned long i = 0; i < n; i++)
        if (a[i] != b[i]) return a[i] - b[i];
    return 0;
}

unsigned long strlen(const char *s) {
    unsigned long len = 0;
    while (s[len]) len++;
    return len;
}

int strcmp(const char* s1, const char* s2) {
    while (*s1 && (*s1 == *s2)) { s1++; s2++; }
    return *(unsigned char*)s1 - *(unsigned char*)s2;
}

int strncmp(const char *s1, const char *s2, unsigned long n) {
    while (n && *s1 && (*s1 == *s2)) { ++s1; ++s2; --n; }
    if (n == 0) return 0;
    return (*(unsigned char*)s1 - *(unsigned char*)s2);
}

int strcasecmp(const char *s1, const char *s2) {
    while (*s1 && tolower(*s1) == tolower(*s2)) { s1++; s2++; }
    return tolower((unsigned char)*s1) - tolower((unsigned char)*s2);
}

int strncasecmp(const char *s1, const char *s2, unsigned long n) {
    if (n == 0) return 0;
    while (n--) {
        int d = tolower((unsigned char)*s1) - tolower((unsigned char)*s2);
        if (d || !*s1) return d;
        s1++; s2++;
    }
    return 0;
}

char* strcpy(char* dest, const char* src) {
    char* d = dest;
    while ((*d++ = *src++));
    return dest;
}

char* strncpy(char* dest, const char* src, unsigned long n) {
    unsigned long i;
    for (i = 0; i < n && src[i] != '\0'; i++) dest[i] = src[i];
    for (; i < n; i++) dest[i] = '\0';
    return dest;
}

char* strcat(char* dest, const char* src) {
    char* d = dest + strlen(dest);
    while ((*d++ = *src++));
    return dest;
}

char* strncat(char* dest, const char* src, unsigned long n) {
    char* d = dest + strlen(dest);
    while (n-- && *src) *d++ = *src++;
    *d = '\0';
    return dest;
}

char* strchr(const char* s, int c) {
    while (*s != (char)c) { if (!*s++) return 0; }
    return (char*)s;
}

char* strrchr(const char* s, int c) {
    char* ret = 0;
    do { if (*s == (char)c) ret = (char*)s; } while (*s++);
    return ret;
}

char* strstr(const char* haystack, const char* needle) {
    if (!*needle) return (char*)haystack;
    unsigned long nlen = strlen(needle);
    while (*haystack) {
        if (strncmp(haystack, needle, nlen) == 0) return (char*)haystack;
        haystack++;
    }
    return 0;
}

char* strdup(const char* s) {
    size_t len = strlen(s);
    char* dup = (char*)malloc(len + 1);
    if (dup) memcpy(dup, s, len + 1);
    return dup;
}

void* memmove(void* dest, const void* src, size_t n) {
    unsigned char* d = (unsigned char*)dest;
    const unsigned char* s = (const unsigned char*)src;
    if (d < s) { while (n--) *d++ = *s++; }
    else        { d += n; s += n; while (n--) *--d = *--s; }
    return dest;
}

// ==========================================
// 4. ФОРМАТУВАННЯ РЯДКІВ
// ==========================================
static int int_to_str(char* buf, long val, int base, int uppercase) {
    if (val == 0) { buf[0] = '0'; buf[1] = '\0'; return 1; }
    char tmp[32];
    int neg = 0, len = 0;
    if (val < 0 && base == 10) { neg = 1; val = -val; }
    const char* digits = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";
    unsigned long uval = (unsigned long)val;
    while (uval > 0) { tmp[len++] = digits[uval % base]; uval /= base; }
    if (neg) tmp[len++] = '-';
    int out = 0;
    for (int i = len - 1; i >= 0; i--) buf[out++] = tmp[i];
    buf[out] = '\0';
    return out;
}

static int do_vsnprintf(char* str, unsigned long maxlen, const char* format, __builtin_va_list args) {
    unsigned long pos = 0;
    int limited = (str != 0 && maxlen != (unsigned long)-1);

#define PUTC(c) do { \
    if (str) { if (!limited || pos < maxlen - 1) str[pos] = (c); } \
    pos++; \
} while(0)

    const char* f = format;
    while (*f) {
        if (*f != '%') { PUTC(*f++); continue; }
        f++;

        int flag_zero = 0, flag_left = 0;
        while (*f == '0' || *f == '-' || *f == '+' || *f == ' ') {
            if (*f == '0') flag_zero = 1;
            if (*f == '-') flag_left = 1;
            f++;
        }

        int width = 0;
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');

        int precision = -1;
        if (*f == '.') {
            f++; precision = 0;
            while (*f >= '0' && *f <= '9') precision = precision * 10 + (*f++ - '0');
        }

        int is_long = 0;
        if (*f == 'l') { is_long = 1; f++; }
        if (*f == 'l') { is_long = 2; f++; }

        char spec = *f++;
        char tmp[64];
        const char* src = tmp;
        int slen = 0;

        if (spec == 'd' || spec == 'i') {
            long val = (is_long >= 1) ? __builtin_va_arg(args, long) : (long)__builtin_va_arg(args, int);
            slen = int_to_str(tmp, val, 10, 0);
        } else if (spec == 'u') {
            unsigned long val = (is_long >= 1) ? __builtin_va_arg(args, unsigned long) : (unsigned long)__builtin_va_arg(args, unsigned int);
            slen = int_to_str(tmp, (long)val, 10, 0);
        } else if (spec == 'x') {
            unsigned long val = (is_long >= 1) ? __builtin_va_arg(args, unsigned long) : (unsigned long)__builtin_va_arg(args, unsigned int);
            slen = int_to_str(tmp, (long)val, 16, 0);
        } else if (spec == 'X') {
            unsigned long val = (is_long >= 1) ? __builtin_va_arg(args, unsigned long) : (unsigned long)__builtin_va_arg(args, unsigned int);
            slen = int_to_str(tmp, (long)val, 16, 1);
        } else if (spec == 'o') {
            unsigned long val = (unsigned long)__builtin_va_arg(args, unsigned int);
            slen = int_to_str(tmp, (long)val, 8, 0);
        } else if (spec == 'p') {
            // ВИПРАВЛЕНО: void* → unsigned long через юніон, без -Wpointer-to-int-cast
            union { void* p; unsigned long u; } pu;
            pu.p = __builtin_va_arg(args, void*);
            tmp[0] = '0'; tmp[1] = 'x';
            slen = 2 + int_to_str(tmp + 2, (long)pu.u, 16, 0);
        } else if (spec == 'c') {
            tmp[0] = (char)__builtin_va_arg(args, int);
            tmp[1] = '\0'; slen = 1;
        } else if (spec == 's') {
            const char* s = __builtin_va_arg(args, const char*);
            if (!s) s = "(null)";
            src = s;
            slen = (int)strlen(s);
            if (precision >= 0 && slen > precision) slen = precision;
        } else if (spec == '%') {
            PUTC('%'); continue;
        } else {
            PUTC('%'); PUTC(spec); continue;
        }

        int pad = width - slen;
        if (!flag_left) {
            char pc = flag_zero ? '0' : ' ';
            for (int i = 0; i < pad; i++) PUTC(pc);
        }
        for (int i = 0; i < slen; i++) PUTC(src[i]);
        if (flag_left) for (int i = 0; i < pad; i++) PUTC(' ');
    }

    if (str) {
        if (limited) str[pos < maxlen ? pos : maxlen - 1] = '\0';
        else str[pos] = '\0';
    }
    return (int)pos;
#undef PUTC
}

int sprintf(char* str, const char* format, ...) {
    __builtin_va_list args;
    __builtin_va_start(args, format);
    int r = do_vsnprintf(str, (unsigned long)-1, format, args);
    __builtin_va_end(args);
    return r;
}

int snprintf(char* str, size_t size, const char* format, ...) {
    __builtin_va_list args;
    __builtin_va_start(args, format);
    int r = do_vsnprintf(str, size, format, args);
    __builtin_va_end(args);
    return r;
}

int vsnprintf(char* str, size_t size, const char* format, void* args) {
    __builtin_va_list* vap = (__builtin_va_list*)args;
    return do_vsnprintf(str, size, format, *vap);
}

int vsprintf(char* str, const char* format, __builtin_va_list args) {
    return do_vsnprintf(str, (unsigned long)-1, format, args);
}

int printf(const char* format, ...) {
    char buf[1024];
    __builtin_va_list args;
    __builtin_va_start(args, format);
    int r = do_vsnprintf(buf, sizeof(buf), format, args);
    __builtin_va_end(args);
    print(buf, 0x00FFFFFF);
    return r;
}

int fprintf(FILE* stream, const char* format, ...) {
    char buf[1024];
    __builtin_va_list args;
    __builtin_va_start(args, format);
    int r = do_vsnprintf(buf, sizeof(buf), format, args);
    __builtin_va_end(args);
    print(buf, 0x00FFFFFF);
    return r;
}

int vfprintf(FILE* stream, const char* format, void* arg) {
    char buf[1024];
    __builtin_va_list* vap = (__builtin_va_list*)arg;
    int r = do_vsnprintf(buf, sizeof(buf), format, *vap);
    print("\nFATAL ERROR: ", 0x00FF0000);
    print(buf, 0x00FF0000);
    print("\n", 0x00FF0000);
    return r;
}

// ==========================================
// 5. sscanf
// ==========================================
int sscanf(const char* str, const char* format, ...) {
    __builtin_va_list args;
    __builtin_va_start(args, format);
    int matched = 0;
    const char* s = str;
    const char* f = format;

    while (*f && *s) {
        if (isspace((unsigned char)*f)) {
            while (isspace((unsigned char)*s)) s++;
            while (isspace((unsigned char)*f)) f++;
            continue;
        }
        if (*f != '%') {
            if (*f != *s) break;
            f++; s++; continue;
        }
        f++;

        int width = 0;
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        int is_long = 0;
        if (*f == 'l') { is_long = 1; f++; }
        char spec = *f++;

        if (spec != 'c') while (isspace((unsigned char)*s)) s++;

        if (spec == 'd' || spec == 'i') {
            if (!*s) break;
            int neg = 0;
            if (*s == '-') { neg = 1; s++; }
            else if (*s == '+') s++;
            if (!isdigit((unsigned char)*s)) break;
            long val = 0; int cnt = 0;
            while (isdigit((unsigned char)*s) && (width == 0 || cnt < width))
                { val = val * 10 + (*s++ - '0'); cnt++; }
            if (neg) val = -val;
            if (is_long) *(long*)  __builtin_va_arg(args, long*)  = val;
            else         *(int*)   __builtin_va_arg(args, int*)   = (int)val;
            matched++;
        } else if (spec == 'u') {
            if (!isdigit((unsigned char)*s)) break;
            unsigned long val = 0; int cnt = 0;
            while (isdigit((unsigned char)*s) && (width == 0 || cnt < width))
                { val = val * 10 + (*s++ - '0'); cnt++; }
            if (is_long) *(unsigned long*) __builtin_va_arg(args, unsigned long*) = val;
            else         *(unsigned int*)  __builtin_va_arg(args, unsigned int*)  = (unsigned int)val;
            matched++;
        } else if (spec == 'x' || spec == 'X') {
            if (!*s) break;
            if (s[0]=='0' && (s[1]=='x'||s[1]=='X')) s += 2;
            unsigned long val = 0; int cnt = 0;
            while ((*s>='0'&&*s<='9')||(*s>='a'&&*s<='f')||(*s>='A'&&*s<='F')) {
                if (width > 0 && cnt >= width) break;
                int d = isdigit((unsigned char)*s) ? *s-'0' :
                        ((*s>='a') ? *s-'a'+10 : *s-'A'+10);
                val = val * 16 + d; s++; cnt++;
            }
            *(unsigned int*)__builtin_va_arg(args, unsigned int*) = (unsigned int)val;
            matched++;
        } else if (spec == 's') {
            if (!*s) break;
            char* dst = __builtin_va_arg(args, char*);
            int cnt = 0;
            while (*s && !isspace((unsigned char)*s) && (width == 0 || cnt < width))
                { *dst++ = *s++; cnt++; }
            *dst = '\0';
            if (cnt > 0) matched++;
        } else if (spec == 'c') {
            char* dst = __builtin_va_arg(args, char*);
            int cnt = (width > 0) ? width : 1;
            while (cnt-- && *s) *dst++ = *s++;
            matched++;
        } else if (spec == '%') {
            if (*s == '%') s++;
        }
    }

    __builtin_va_end(args);
    return matched;
}

int fscanf(FILE* stream, const char* format, ...) { return -1; }

// ==========================================
// 6. POSIX I/O
// ==========================================
int open(const char *pathname, int flags, ...) {
    /* ПЕРЕПИСАНО: раніше файл цілком читався у malloc-буфер прямо тут,
       а write() у файл взагалі не працював (повертав -1). Тепер усе
       робить ядро через syscalls 16-20, тому файли реально зберігаються. */
    const char* basename = pathname;
    for (const char* p = pathname; *p; p++)
        if (*p == '/' || *p == '\\' || *p == ':') basename = p + 1;

    char upper_name[64];
    int i = 0;
    for (; basename[i] && i < 63; i++) {
        char c = basename[i];
        upper_name[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
    }
    upper_name[i] = '\0';

    return sys_open(upper_name, flags);
}

int read(int fd, void *buf, unsigned long count) {
    return (int)sys_read_fd(fd, buf, count);
}

int write(int fd, const void* buf, unsigned long count) {
    /* fd 1 і 2 лишаються екраном */
    if (fd == 1 || fd == 2) {
        const char* s = (const char*)buf;
        for (unsigned long i = 0; i < count; i++) put_char(s[i], 0x00FFFFFF);
        return (int)count;
    }
    return (int)sys_write_fd(fd, buf, count);
}

long lseek(int fd, long offset, int whence) {
    return sys_lseek_fd(fd, offset, whence);
}

int close(int fd) {
    if (fd == 1 || fd == 2) return 0;
    return sys_close_fd(fd);
}

// ==========================================
// 7. FILE* I/O
// ВИПРАВЛЕНО: всі касти FILE* <-> int через _fd_to_FILE / _FILE_to_fd
// ==========================================
FILE* fopen(const char* filename, const char* mode) {
    int fd = open(filename, 0);
    if (fd < 0) return 0;
    return _fd_to_FILE(fd);  // без -Wint-to-pointer-cast
}

unsigned long fread(void* ptr, unsigned long size, unsigned long count, FILE* stream) {
    if (!stream || size == 0) return 0;
    int fd = _FILE_to_fd(stream);  // без -Wpointer-to-int-cast
    DOOM_FILE* f = get_file(fd);
    if (!f) return 0;

    unsigned long total = size * count;
    int bytes = read(fd, ptr, total);
    if (bytes <= 0) return 0;

    unsigned long result = (unsigned long)bytes / size;

#if LIBC_DEBUG
    {
        char dbg[64];
        sprintf(dbg, " FREAD fd=%d pos=%ld req=%lu got=%lu\n",
                fd, f->pos, total, result);
        print(dbg, 0x00666666);
    }
#else
    (void)total;
#endif

    return result;
}

int fseek(FILE* stream, long offset, int origin) {
    if (!stream) return -1;
    return (lseek(_FILE_to_fd(stream), offset, origin) < 0) ? -1 : 0;
}

long ftell(FILE* stream) {
    DOOM_FILE* f = get_file(_FILE_to_fd(stream));
    if (!f) return -1;
    return f->pos;
}

int fclose(FILE* stream) {
    if (!stream) return -1;
    return close(_FILE_to_fd(stream));
}

int feof(FILE* stream) {
    DOOM_FILE* f = get_file(_FILE_to_fd(stream));
    if (!f) return 1;
    return f->pos >= f->size ? 1 : 0;
}

int ferror(FILE* stream) { return 0; }
void rewind(FILE* stream) { if (stream) fseek(stream, 0, SEEK_SET); }

char* fgets(char* s, int n, FILE* stream) {
    DOOM_FILE* f = get_file(_FILE_to_fd(stream));
    if (!f || !s || n <= 0 || f->pos >= f->size) return 0;
    int i = 0;
    while (i < n - 1 && f->pos < f->size) {
        char c = (char)f->data[f->pos++];
        s[i++] = c;
        if (c == '\n') break;
    }
    s[i] = '\0';
    return (i > 0) ? s : 0;
}

// ==========================================
// 8. РЕШТА ФУНКЦІЙ
// ==========================================

// ВИПРАВЛЕНО: exit() тепер справжній syscall 0, а не нескінченний цикл
void exit(int status) {
    (void)status;
    sys_exit();          /* syscall 0; ядро сюди вже не повернеться */
    while (1) {}
}

void* calloc(size_t nitems, size_t size) {
    if (!nitems || !size) return 0;
    void* ptr = malloc(nitems * size);
    if (ptr) memset(ptr, 0, nitems * size);
    return ptr;
}

void* realloc(void* ptr, size_t size) {
    if (!ptr) return malloc(size);
    if (!size) { free(ptr); return 0; }
    void* np = malloc(size);
    if (np) { memcpy(np, ptr, size); free(ptr); }
    return np;
}

int putchar(int c)  { put_char((char)c, 0x00FFFFFF); return c; }
int puts(const char* s) { print(s, 0x00FFFFFF); print("\n", 0x00FFFFFF); return 0; }
int fflush(FILE* stream) { return 0; }
size_t fwrite(const void* ptr, size_t size, size_t count, FILE* stream) { return count; }
char* getenv(const char* name)                { return 0; }
int system(const char* command)               { return 0; }
int remove(const char* filename)              { return 0; }
int rename(const char* old, const char* newf) { return 0; }
int mkdir(const char* pathname, int mode)     { return 0; }
void* bsearch(const void* key, const void* base, size_t n, size_t size,
              int (*cmp)(const void*, const void*)) { return 0; }
void qsort(void* base, size_t n, size_t size,
           int (*cmp)(const void*, const void*)) {}