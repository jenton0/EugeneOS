#include "stdlib.h"

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
static int alloc_fd(void) {
    for (int i = 0; i < MAX_OPEN_FILES; i++)
        if (!open_files[i]) return i + 3;
    return -1;
}

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
// ВИПРАВЛЕНО: 0x8000000 (128MB) — не конфліктує з DirBuffer ядра (0x2000000)
#define HEAP_START 0x8000000
#define HEAP_SIZE  0x4000000  // 64MB

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

double fabs(double x) { return x < 0 ? -x : x; }

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
    const char* basename = pathname;
    for (const char* p = pathname; *p; p++)
        if (*p == '/' || *p == '\\' || *p == ':') basename = p + 1;

    char upper_name[64];
    int i = 0;
    for (; basename[i] && i < 63; i++) {
        char c = basename[i];
        if (c >= 'a' && c <= 'z') c -= 32;
        upper_name[i] = c;
    }
    upper_name[i] = '\0';

    print(" POSIX OPEN: ", 0x00FFFF00);
    print(upper_name, 0x00FFFF00);
    print("\n", 0x00FFFFFF);

    int fd = alloc_fd();
    if (fd < 0) { print(" ERR: NO FREE FD\n", 0x00FF0000); return -1; }

    unsigned char* temp = (unsigned char*)malloc(64000000);
    if (!temp) { print(" ERR: MALLOC FAIL\n", 0x00FF0000); return -1; }

    uint64_t actual_size = read_file(upper_name, temp);

    char dbg[64];
    sprintf(dbg, " FD=%d SIZE=%d\n", fd, (int)actual_size);
    print(dbg, actual_size > 0 ? 0x0000FF00 : 0x00FF0000);

    if (actual_size == 0) {
        free(temp);
        return -1;
    }

    DOOM_FILE* f = (DOOM_FILE*)malloc(sizeof(DOOM_FILE));
    if (!f) { free(temp); return -1; }
    f->data = temp;
    f->size = (long)actual_size;
    f->pos  = 0;

    open_files[fd - 3] = f;
    return fd;
}

int read(int fd, void *buf, unsigned long count) {
    DOOM_FILE* f = get_file(fd);
    if (!f) return -1;
    long remaining = f->size - f->pos;
    if (remaining <= 0) return 0;
    unsigned long bytes = (count > (unsigned long)remaining) ? (unsigned long)remaining : count;
    memcpy(buf, f->data + f->pos, bytes);
    f->pos += (long)bytes;
    return (int)bytes;
}

int write(int fd, const void* buf, unsigned long count) {
    if (fd == 1 || fd == 2) {
        const char* s = (const char*)buf;
        for (unsigned long i = 0; i < count; i++) put_char(s[i], 0x00FFFFFF);
        return (int)count;
    }
    return -1;
}

long lseek(int fd, long offset, int whence) {
    DOOM_FILE* f = get_file(fd);
    if (!f) return -1;
    if      (whence == SEEK_SET) f->pos = offset;
    else if (whence == SEEK_CUR) f->pos += offset;
    else if (whence == SEEK_END) f->pos = f->size + offset;
    if (f->pos > f->size) f->pos = f->size;
    if (f->pos < 0)       f->pos = 0;
    if (offset > 1000000) {
        char dbg[64];
        sprintf(dbg, " LSEEK fd=%d off=%d pos=%d\n", fd, (int)offset, (int)f->pos);
        print(dbg, 0x00888888);
    }
    return f->pos;
}

int close(int fd) {
    char dbg[32];
    sprintf(dbg, " CLOSE FD=%d\n", fd);
    print(dbg, 0x00FF8800);

    DOOM_FILE* f = get_file(fd);
    if (!f) return -1;
    if (f->data) free(f->data);
    free(f);
    open_files[fd - 3] = 0;
    return 0;
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

    char dbg[64];
    sprintf(dbg, " FREAD fd=%d pos=%ld req=%lu got=%lu\n",
            fd, f->pos, total, result);
    print(dbg, 0x00666666);

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
    __asm__ volatile (
        "xor %%rax, %%rax\n"
        "int $0x80\n"
        ::: "rax", "memory"
    );
    while (1) {}  // якщо ядро чомусь не перервало виконання
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
double atof(const char* str)                  { return 0.0; }
int mkdir(const char* pathname, int mode)     { return 0; }
void* bsearch(const void* key, const void* base, size_t n, size_t size,
              int (*cmp)(const void*, const void*)) { return 0; }
void qsort(void* base, size_t n, size_t size,
           int (*cmp)(const void*, const void*)) {}