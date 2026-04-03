#pragma once
#ifndef STDLIB_H
#define STDLIB_H

// ==========================================
// 1. БАЗОВІ ТИПИ
// ==========================================
#define NULL      ((void*)0)
#define TRUE      1
#define FALSE     0
#define EOF       (-1)

typedef unsigned char      uint8_t;
typedef signed char        int8_t;
typedef unsigned short     uint16_t;
typedef signed short       int16_t;
typedef unsigned int       uint32_t;
typedef signed int         int32_t;
typedef unsigned long long uint64_t;
typedef signed long long   int64_t;
typedef unsigned long      size_t;
typedef long               ssize_t;
typedef long               intptr_t;
typedef unsigned long      uintptr_t;   // = розмір вказівника на x86-64
typedef long               off_t;
typedef int                ptrdiff_t;

// Числові межі
#define INT_MAX     2147483647
#define INT_MIN     (-2147483648)
#define UINT_MAX    4294967295U
#define LONG_MAX    9223372036854775807LL
#define LONG_MIN    (-9223372036854775807LL - 1)
#define SIZE_MAX    (~(size_t)0)

// ==========================================
// 2. ФАЙЛОВА СИСТЕМА
// ==========================================
// FILE* зберігається як (FILE*)(uintptr_t)fd
// де fd = 1, 2 або 3..10 (індекс у open_files[])
typedef void FILE;
#define stdin    ((FILE*)0)
#define stdout   ((FILE*)1)
#define stderr   ((FILE*)2)

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

// Прапори open()
#define O_RDONLY  0
#define O_WRONLY  1
#define O_RDWR    2
#define O_CREAT   0x40
#define O_TRUNC   0x200
#define O_APPEND  0x400

// Коди помилок
#define EPERM     1
#define ENOENT    2
#define ENOMEM    12
#define EACCES    13
#define EISDIR    21
#define EINVAL    22
#define ENOSPC    28

// ==========================================
// 3. СИСТЕМНІ ВИКЛИКИ EUGENE OS
// ==========================================

// 2 аргументи: RAX=num, RSI=arg1, R9=arg2
static inline uint64_t _syscall2(uint64_t num, uint64_t a1, uint64_t a2) {
    register uint64_t rax __asm__("rax") = num;
    register uint64_t rsi __asm__("rsi") = a1;
    register uint64_t r9  __asm__("r9")  = a2;
    __asm__ volatile ("int $0x80" : "+r"(rax) : "r"(rsi), "r"(r9) : "memory");
    return rax;
}

// 3 аргументи: RAX=num, RSI=arg1, RDI=arg2, RDX=arg3
// Використовується для syscall 14 (write_file)
static inline uint64_t _syscall3(uint64_t num, uint64_t a1, uint64_t a2, uint64_t a3) {
    register uint64_t rax __asm__("rax") = num;
    register uint64_t rsi __asm__("rsi") = a1;
    register uint64_t rdi __asm__("rdi") = a2;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("int $0x80" : "+r"(rax) : "r"(rsi), "r"(rdi), "r"(rdx) : "memory");
    return rax;
}

// Сумісність зі старим кодом що викликає syscall(num, a1, a2) напряму
#define syscall(num, a1, a2) _syscall2(num, a1, a2)

// --- Публічні обгортки syscalls ---

static inline void sys_exit(void) {
    __asm__ volatile ("xor %%rax, %%rax\nint $0x80\n" ::: "rax", "memory");
}

static inline uint64_t get_key(void)                               { return _syscall2(1, 0, 0); }
static inline void     print(const char* s, uint32_t color)        { _syscall2(2, (uint64_t)s, (uint64_t)color); }
static inline void     clear_screen(void)                          { _syscall2(4, 0, 0); }
static inline uint64_t read_file(const char* name, void* dest)     { return _syscall2(5, (uint64_t)name, (uint64_t)dest); }
static inline void     put_char(char c, uint32_t color)            { _syscall2(6, (uint64_t)(uint8_t)c, (uint64_t)color); }
static inline void     erase_char(void)                            { _syscall2(7, 0, 0); }
static inline void     list_files(void)                            { _syscall2(8, 0, 0); }
static inline uint64_t get_ticks(void)                             { return _syscall2(10, 0, 0); }
static inline void     get_file_list(char* buf)                    { _syscall2(13, (uint64_t)buf, 0); }

// syscall 11 — повертає сирі дані миші одним числом:
//   bits[15:0]  = X
//   bits[31:16] = Y
//   bits[47:32] = click (1=left, 2=right)
//
// УВАГА: навмисно названо sys_get_mouse (а не get_mouse),
// щоб не конфліктувати з власними обгортками у shell.c або gui.c
// які можуть мати іншу сигнатуру.
static inline uint64_t sys_get_mouse(void) {
    return _syscall2(11, 0, 0);
}

// syscall 12 — час RTC:  bits[7:0]=хвилини(BCD), bits[15:8]=години(BCD)
static inline uint64_t sys_get_time(void) {
    return _syscall2(12, 0, 0);
}

// syscall 14 — записати буфер у файл (або створити якщо не існує)
// Повертає кількість байт записаних на диск, 0 = помилка
static inline uint64_t write_file(const char* name, const void* buf, uint64_t size) {
    return _syscall3(14, (uint64_t)name, (uint64_t)buf, size);
}

// BlitArgs для syscall 9
typedef struct {
    uint32_t *buffer;
    uint32_t x, y, w, h;
} BlitArgs;

static inline void blit_buffer(uint32_t *buf, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    BlitArgs a = {buf, x, y, w, h};
    _syscall2(9, (uint64_t)&a, 0);
}

// ==========================================
// 4. ПРОТОТИПИ — реалізація в eugene_libc.c
// ==========================================

// Пам'ять
void  init_heap(void);
void* malloc(size_t size);
void  free(void* ptr);
void* calloc(size_t nitems, size_t size);
void* realloc(void* ptr, size_t size);

// Рядки
unsigned long strlen(const char* s);
int           strcmp(const char* s1, const char* s2);
int           strncmp(const char* s1, const char* s2, unsigned long n);
int           strcasecmp(const char* s1, const char* s2);
int           strncasecmp(const char* s1, const char* s2, unsigned long n);
char*         strcpy(char* dest, const char* src);
char*         strncpy(char* dest, const char* src, unsigned long n);
char*         strcat(char* dest, const char* src);
char*         strncat(char* dest, const char* src, unsigned long n);
char*         strchr(const char* s, int c);
char*         strrchr(const char* s, int c);
char*         strstr(const char* haystack, const char* needle);
char*         strdup(const char* s);

// Пам'ять (mem*)
void* memcpy(void* dest, const void* src, unsigned long n);
void* memset(void* s, int c, unsigned long n);
void* memmove(void* dest, const void* src, size_t n);
int   memcmp(const void* s1, const void* s2, unsigned long n);

// Числа / утиліти
int    atoi(const char* str);
double atof(const char* str);
int    abs(int j);
double fabs(double x);
int    isspace(int c);
int    isdigit(int c);
int    isalpha(int c);
int    isalnum(int c);
int    toupper(int c);
int    tolower(int c);

// Сортування / пошук
void  qsort(void* base, size_t n, size_t size, int (*cmp)(const void*, const void*));
void* bsearch(const void* key, const void* base, size_t n, size_t size,
              int (*cmp)(const void*, const void*));

// Форматований вивід
int printf(const char* format, ...);
int fprintf(FILE* stream, const char* format, ...);
int sprintf(char* str, const char* format, ...);
int snprintf(char* str, size_t size, const char* format, ...);
int vfprintf(FILE* stream, const char* format, void* arg);
int vsnprintf(char* str, size_t size, const char* format, void* args);
int vsprintf(char* str, const char* format, __builtin_va_list args);
int sscanf(const char* str, const char* format, ...);
int fscanf(FILE* stream, const char* format, ...);
int puts(const char* s);
int putchar(int c);
int fflush(FILE* stream);

// Файловий I/O
int           open(const char* pathname, int flags, ...);
int           read(int fd, void* buf, unsigned long count);
int           write(int fd, const void* buf, unsigned long count);
long          lseek(int fd, long offset, int whence);
int           close(int fd);
FILE*         fopen(const char* filename, const char* mode);
unsigned long fread(void* ptr, unsigned long size, unsigned long count, FILE* stream);
size_t        fwrite(const void* ptr, size_t size, size_t count, FILE* stream);
int           fseek(FILE* stream, long offset, int origin);
long          ftell(FILE* stream);
int           fclose(FILE* stream);
int           feof(FILE* stream);
int           ferror(FILE* stream);
void          rewind(FILE* stream);
char*         fgets(char* s, int n, FILE* stream);

// Система
void  exit(int status);
char* getenv(const char* name);
int   system(const char* command);
int   remove(const char* filename);
int   rename(const char* old, const char* newf);
int   mkdir(const char* pathname, int mode);

#endif