#ifndef SYSCALLS_H
#define SYSCALLS_H

typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;

// Внутрішня функція для виклику переривання
static inline uint64_t syscall(uint64_t num, uint64_t arg1, uint64_t arg2) {
    uint64_t result;
    __asm__ volatile (
        "mov %1, %%rax\n"
        "mov %2, %%rsi\n"
        "mov %3, %%r9\n"
        "int $0x80"
        : "=a" (result)
        : "r"(num), "r"(arg1), "r"(arg2)
        : "rsi", "r9"
    );
    return result;
}

// Наші системні функції
void exit() { syscall(0, 0, 0); }
uint64_t get_key() { return syscall(1, 0, 0); }
void print(char* text, uint32_t color) { syscall(2, (uint64_t)text, (uint64_t)color); }

#endif