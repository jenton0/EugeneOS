@echo off
chcp 65001 > nul
color 0E

echo ========================================================
echo         ЗБІРКА EUGENE OS (НОВА СТРУКТУРА)
echo ========================================================

cd /d "%~dp0"
set "WORK_DIR=%CD%"

REM === НАЛАШТУВАННЯ ШЛЯХІВ ===
set "FASM=D:\fasm\fasm.exe"
set "GCC=D:\mingw64\bin\gcc.exe"
set "LD=D:\mingw64\bin\ld.exe"
set "OBJCOPY=D:\mingw64\bin\objcopy.exe"
set "QEMU=%WORK_DIR%\qemu\qemu-system-x86_64.exe"
set "BIOS=%WORK_DIR%\boot\OVMF.fd"
set "DISK_FILE=D:\store\1.vhd"
set "VHD_DRIVE=F:"

REM === МОНТУВАННЯ VHD ===
echo.
echo [1/5] Монтування віртуального диска (%DISK_FILE%)...
echo select vdisk file="%DISK_FILE%" > mount_vhd.txt
echo attach vdisk >> mount_vhd.txt
diskpart /s mount_vhd.txt > nul
del mount_vhd.txt

REM Чекаємо, поки Windows роздуплиться і підключить букву
ping 127.0.0.1 -n 3 > nul

if not exist %VHD_DRIVE%\ (
    color 0C
    echo [ПОМИЛКА] Диск %VHD_DRIVE% не змонтувався! Перевір букву.
    goto :cleanup_and_stop
)
echo [ОК] Диск %VHD_DRIVE% підключено.

REM Створюємо папку для EFI, якщо її немає
if not exist %VHD_DRIVE%\EFI\BOOT mkdir %VHD_DRIVE%\EFI\BOOT

REM === КОМПІЛЯЦІЯ FASM (ЯДРО ТА БУТЛОАДЕР) ===
echo.
echo [2/5] Компіляція системного коду (FASM)...

echo - Збірка Bootloader...
"%FASM%" boot\main.asm %VHD_DRIVE%\EFI\BOOT\BOOTX64.EFI
if %errorlevel% neq 0 goto :fasm_error

echo - Збірка Kernel...
"%FASM%" kernel\kernel.asm %VHD_DRIVE%\kernel.bin
if %errorlevel% neq 0 goto :fasm_error

REM === КОМПІЛЯЦІЯ C (USERLAND) ===
echo.
echo [3/5] Компіляція коду користувача (GCC)...

REM 1. Компілюємо CRT0 (Точка входу для C)
echo - Компіляція libc/entry.c...
"%GCC%" -ffreestanding -fno-pie -m64 -mno-red-zone -fno-exceptions -fno-asynchronous-unwind-tables -I libc/include -O2 -c libc/entry.c -o libc/entry.o
if %errorlevel% neq 0 goto :gcc_error

REM 2. Компілюємо саму бібліотеку libc (ОСЬ ЦЬОГО БРАКУВАЛО)
echo - Компіляція libc/eugene_libc.c...
"%GCC%" -ffreestanding -fno-pie -m64 -mno-red-zone -fno-exceptions -fno-asynchronous-unwind-tables -I libc/include -O2 -c libc/eugene_libc.c -o libc/eugene_libc.o
if %errorlevel% neq 0 goto :gcc_error

REM 3. Компілюємо оболонку (Shell)
echo - Компіляція userland/shell.c...
"%GCC%" -ffreestanding -fno-pie -m64 -mno-red-zone -fno-exceptions -fno-asynchronous-unwind-tables -I libc/include -O2 -c userland/shell.c -o userland/shell.o
if %errorlevel% neq 0 goto :gcc_error

REM 4. Лінковка (Збираємо все до купи: Точка входу + Бібліотека + Програма)
echo - Лінковка GUI.BIN...
"%LD%" -T linker.ld -e _start libc/entry.o libc/eugene_libc.o userland/shell.o -o userland/shell.tmp
if %errorlevel% neq 0 goto :gcc_error

REM 5. Створення плоского бінарника (Flat Binary)
"%OBJCOPY%" -O binary userland/shell.tmp %VHD_DRIVE%\GUI.BIN
if %errorlevel% neq 0 goto :gcc_error

echo [ОК] Userland скомпільовано.

REM === ВІДМОНТУВАННЯ VHD ===
echo.
echo [4/5] Відключення диска...
echo select vdisk file="%DISK_FILE%" > unmount_vhd.txt
echo detach vdisk >> unmount_vhd.txt
diskpart /s unmount_vhd.txt > nul
del unmount_vhd.txt
echo [ОК] Диск безпечно відключено.

REM === ЗАПУСК QEMU ===
echo.
color 0A
echo [5/5] УСПІХ! Запускаю QEMU...
"%QEMU%" -m 512M -drive if=pflash,format=raw,readonly=on,file="%BIOS%" -net none -vga std -drive file="%DISK_FILE%",format=vpc -boot menu=on

echo.
echo QEMU завершив роботу. Дивись помилку вище ^^^
pause
exit

REM === ОБРОБНИКИ ПОМИЛОК ===
:fasm_error
color 0C
echo.
echo [ПОМИЛКА] Синтаксична помилка в Assembly коді!
goto :cleanup_and_stop

:gcc_error
color 0C
echo.
echo [ПОМИЛКА] Помилка компіляції або лінковки С-коду!
goto :cleanup_and_stop

:cleanup_and_stop
echo.
echo ========================================================
echo КОМПІЛЯЦІЮ ПЕРЕРВАНО ЧЕРЕЗ ПОМИЛКУ.
echo ========================================================
echo [ОЧИЩЕННЯ] Аварійне відключення VHD диска...
echo select vdisk file="%DISK_FILE%" > unmount_vhd.txt
echo detach vdisk >> unmount_vhd.txt
diskpart /s unmount_vhd.txt > nul
del unmount_vhd.txt
pause
exit