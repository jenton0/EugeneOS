; Найпростіший тест самокомпіляції для EUGENE OS.
; Збери прямо в системі:  RUN FASM.BIN HELLO.ASM HELLO.BIN
; Потім запусти:          RUN HELLO.BIN

format binary as 'bin'
use64
org 0x4000000           ; AppMemoryBase — куди ядро вантажить програми

        mov     rax, 2          ; syscall 2 = print
        mov     rsi, msg
        mov     r9,  0x0000FF00 ; зелений
        int     0x80

        xor     rax, rax        ; syscall 0 = exit
        int     0x80

msg     db 'HELLO FROM SELF-HOSTED FASM!', 10, 0
