@echo off
chcp 65001 > nul
color 0E

echo ========================================================
echo         ЗБІРКА EUGENE OS (ВИПРАВЛЕНА ВЕРСІЯ)
echo ========================================================

cd /d "%~dp0"
set "WORK_DIR=%CD%"

REM === НАЛАШТУВАННЯ ШЛЯХІВ ===
set "FASM=C:\fasm\fasm.exe"
set "GCC=C:\mingw64\bin\gcc.exe"
set "LD=C:\mingw64\bin\ld.exe"
set "OBJCOPY=C:\mingw64\bin\objcopy.exe"
set "QEMU=%WORK_DIR%\qemu\qemu-system-x86_64.exe"
set "BIOS=%WORK_DIR%\boot\OVMF.fd"
set "DISK_FILE=C:\store\1.vhd"
set "VHD_DRIVE=E:"

REM ========================================================
REM  ПРАПОРЦІ КОМПІЛЯЦІЇ - НЕ ПРИБИРАТИ НІЧОГО З ЦЬОГО:
REM
REM  -mgeneral-regs-only
REM      Забороняє GCC використовувати SSE/x87. Без цього на -O2
REM      генеруються movaps по стеку, а планувальник ядра не зберігає
REM      стан XMM при перемиканні задач. Саме SSE-інструкція на
REM      невирівняному стеку і давала #GP -> triple fault -> ребут.
REM
REM  -mno-red-zone
REM      Обробники переривань пишуть нижче RSP. Без цього таймер
REM      затирає локальні змінні програми.
REM
REM  -mno-stack-arg-probe
REM      MinGW інакше вставляє виклики ___chkstk_ms для великих кадрів
REM      стеку, а такої функції в нас немає -> undefined reference.
REM
REM  -fno-stack-protector
REM      Інакше GCC кличе __stack_chk_fail, якого теж немає.
REM ========================================================
set "CFLAGS=-ffreestanding -fno-pie -m64 -mno-red-zone -mgeneral-regs-only -mno-stack-arg-probe -fno-stack-protector -fno-exceptions -fno-asynchronous-unwind-tables -fno-ident -I libc/include -O2 -Wall"

REM === МОНТУВАННЯ VHD ===
echo.
echo [1/7] Монтування віртуального диска (%DISK_FILE%)...
echo select vdisk file="%DISK_FILE%" > mount_vhd.txt
echo attach vdisk >> mount_vhd.txt
diskpart /s mount_vhd.txt > nul
del mount_vhd.txt

ping 127.0.0.1 -n 3 > nul

if not exist %VHD_DRIVE%\ (
    color 0C
    echo [ПОМИЛКА] Диск %VHD_DRIVE% не змонтувався! Перевір букву.
    goto :cleanup_and_stop
)
echo [ОК] Диск %VHD_DRIVE% підключено.

if not exist %VHD_DRIVE%\EFI\BOOT mkdir %VHD_DRIVE%\EFI\BOOT

REM === КОМПІЛЯЦІЯ FASM (ЯДРО ТА БУТЛОАДЕР) ===
echo.
echo [2/7] Компіляція системного коду (FASM)...

echo - Збірка Bootloader...
"%FASM%" boot\main.asm %VHD_DRIVE%\EFI\BOOT\BOOTX64.EFI
if %errorlevel% neq 0 goto :fasm_error

echo - Збірка Kernel...
"%FASM%" kernel\kernel.asm %VHD_DRIVE%\kernel.bin
if %errorlevel% neq 0 goto :fasm_error

REM === КОМПІЛЯЦІЯ C (USERLAND) ===
echo.
echo [3/7] Компіляція коду користувача (GCC)...

echo - libc/entry.c...
"%GCC%" %CFLAGS% -c libc/entry.c -o libc/entry.o
if %errorlevel% neq 0 goto :gcc_error

echo - libc/eugene_libc.c...
"%GCC%" %CFLAGS% -c libc/eugene_libc.c -o libc/eugene_libc.o
if %errorlevel% neq 0 goto :gcc_error

echo - libgui/gui.c...
"%GCC%" %CFLAGS% -I libgui -c libgui/gui.c -o libgui/gui.o
if %errorlevel% neq 0 goto :gcc_error

echo - libgui/bmp.c...
"%GCC%" %CFLAGS% -I libgui -c libgui/bmp.c -o libgui/bmp.o
if %errorlevel% neq 0 goto :gcc_error

echo - libgui/win.c...
"%GCC%" %CFLAGS% -I libgui -c libgui/win.c -o libgui/win.o
if %errorlevel% neq 0 goto :gcc_error

echo - libgui/ctl.c...
"%GCC%" %CFLAGS% -I libgui -c libgui/ctl.c -o libgui/ctl.o
if %errorlevel% neq 0 goto :gcc_error

echo - libgui/menu.c...
"%GCC%" %CFLAGS% -I libgui -c libgui/menu.c -o libgui/menu.o
if %errorlevel% neq 0 goto :gcc_error

echo - userland/shell.c...
"%GCC%" %CFLAGS% -I libgui -c userland/shell.c -o userland/shell.o
if %errorlevel% neq 0 goto :gcc_error

echo - userland/guidemo.c...
"%GCC%" %CFLAGS% -I libgui -c userland/guidemo.c -o userland/guidemo.o
if %errorlevel% neq 0 goto :gcc_error

REM ========================================================
REM  ЛІНКОВКА - ДВА КРОКИ, І ЦЕ ПРИНЦИПОВО
REM
REM  MinGW-ний ld працює в емуляції i386pep і виконує PE-специфічні
REM  дії над вихідним файлом ЗАВЖДИ. Тому будь-яка спроба зробити
REM  не-PE вивід (--oformat binary, OUTPUT_FORMAT(elf...)) дає:
REM      "cannot perform PE operations on non PE output file"
REM
REM  Отже: ld робить звичайний PE, а objcopy зрізає заголовки.
REM  linker.ld збирає ВЕСЬ образ в ОДНУ секцію .image, тому
REM  objcopy кладе її на зміщення 0 і PE-заголовки не заважають.
REM
REM  entry.o ЗАВЖДИ ПЕРШИМ. У кінці linker.ld стоїть ASSERT,
REM  який зупинить лінковку, якщо _start поїде з 0x4000000.
REM
REM  Якщо твій ld раптом не знає --image-base - просто прибери
REM  цей рядок, на результат він не впливає (секція одна).
REM ========================================================
echo.
echo [4/7] Лінковка (крок 1: ld -^> PE)...
"%LD%" -T linker.ld -e _start -nostdlib ^
    --image-base 0x4000000 ^
    -Map userland\shell.map ^
    -o userland\shell.tmp ^
    libc/entry.o libc/eugene_libc.o ^
    libgui/gui.o libgui/bmp.o libgui/win.o libgui/ctl.o libgui/menu.o userland/shell.o
if %errorlevel% neq 0 goto :link_error

REM --- САНІТАРНА ПЕРЕВІРКА ЗА МАПОЮ ЛІНКЕРА ---
findstr /C:"0x0000000004000000                _start" userland\shell.map > nul
if %errorlevel% neq 0 (
    color 0C
    echo [ПОМИЛКА] _start НЕ на адресі 0x4000000!
    echo Дивись userland\shell.map та порядок .o файлів.
    goto :cleanup_and_stop
)
echo [ОК] _start на 0x4000000.
findstr /C:"__bss_start" userland\shell.map
findstr /C:"__bss_end"   userland\shell.map

echo.
echo [5/7] Лінковка (крок 2: objcopy -^> плоский бінарник)...
"%OBJCOPY%" -O binary userland\shell.tmp %VHD_DRIVE%\GUI.BIN
if %errorlevel% neq 0 goto :link_error
if not exist %VHD_DRIVE%\GUI.BIN goto :link_error
echo [ОК] GUI.BIN записано на %VHD_DRIVE%.

REM --- Демонстрація нового шару рендеру ---
"%LD%" -T linker.ld -e _start -nostdlib ^
    --image-base 0x4000000 ^
    -o userland\guidemo.tmp ^
    libc/entry.o libc/eugene_libc.o libgui/gui.o libgui/bmp.o userland/guidemo.o
if %errorlevel% neq 0 goto :link_error
"%OBJCOPY%" -O binary userland\guidemo.tmp %VHD_DRIVE%\GUIDEMO.BIN
echo [ОК] GUIDEMO.BIN записано.

REM === ВІДМОНТУВАННЯ VHD ===
echo.
echo [6/7] Відключення диска...
echo select vdisk file="%DISK_FILE%" > unmount_vhd.txt
echo detach vdisk >> unmount_vhd.txt
diskpart /s unmount_vhd.txt > nul
del unmount_vhd.txt
echo [ОК] Диск безпечно відключено.

REM === ЗАПУСК QEMU ===
echo.
color 0A
echo [7/7] УСПІХ! Запускаю QEMU...
echo.
echo   У консолі ОС набери:  RUN GUI.BIN
echo   (НЕ "OPEN GUI.BIN" - там .BIN обробляється як відео!)
echo.
REM ========================================================
REM  МЕРЕЖА
REM  Було -net none, тобто мережевої карти в машині не існувало.
REM  Тепер додаємо RTL8139 - його простіше програмувати, ніж e1000:
REM  він працює через порти вводу-виводу і має один суцільний
REM  кільцевий буфер прийому замість дескрипторних кілець.
REM
REM  netdev user - режим NAT: не потребує прав адміністратора,
REM  назовні пінг і DHCP працюють. Пінг З хоста В гостя в цьому
REM  режимі неможливий (для нього потрібен tap).
REM
REM  filter-dump пише ВЕСЬ трафік у net.pcap - відкривається
REM  у Wireshark. Це головний інструмент налагодження: видно
REM  точно, які байти карта відправила і що прийшло у відповідь.
REM ========================================================
set "NETOPT=-netdev user,id=n0 -device rtl8139,netdev=n0,mac=52:54:00:12:34:56"
set "NETDUMP=-object filter-dump,id=dump0,netdev=n0,file=net.pcap"

"%QEMU%" -m 512M -drive if=pflash,format=raw,readonly=on,file="%BIOS%" %NETOPT% %NETDUMP% -vga std -drive file="%DISK_FILE%",format=vpc -boot menu=on

echo.
echo QEMU завершив роботу.
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
echo [ПОМИЛКА] Помилка компіляції С-коду!
echo Якщо лається на -mgeneral-regs-only - у тебе застарий GCC,
echo цей прапорець з'явився у GCC 7. Онови MinGW.
goto :cleanup_and_stop

:link_error
color 0C
echo.
echo [ПОМИЛКА] Помилка лінковки! Найімовірніші причини:
echo   "cannot perform PE operations"      -^> у linker.ld повернувся
echo                                          OUTPUT_FORMAT або десь
echo                                          лишився --oformat binary
echo   "undefined reference ___chkstk_ms"  -^> нема -mno-stack-arg-probe
echo   "unrecognized option --image-base"  -^> прибери цей рядок з ld
echo   "FATAL: _start ne na 0x4000000"     -^> зламаний порядок секцій
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