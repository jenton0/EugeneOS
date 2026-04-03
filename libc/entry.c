// entry.c
extern void gui_main(); // Вказуємо правильну назву!

__attribute__((naked)) void _start() {
    __asm__ volatile (
        "call gui_main\n"    // Викликаємо gui_main замість main
        "mov $0, %%rax\n"    // Syscall 0 (Exit)
        "int $0x80\n"        // Повертаємося в ядро
        ::: "memory"
    );
}