@echo off
chcp 65001 > nul
REM ========================================================
REM   Збірка FASM.BIN для EUGENE OS
REM
REM   ПІДГОТОВКА (один раз):
REM   1) Завантаж вихідники fasm: https://flatassembler.net
REM      або https://github.com/tgrysztar/fasm
REM   2) Скопіюй УСІ .INC з папки SOURCE\ сюди, поруч із цим файлом:
REM        ASSEMBLE.INC  AVX.INC     ERRORS.INC    EXPRCALC.INC
REM        EXPRPARS.INC  FORMATS.INC MESSAGES.INC  PARSER.INC
REM        PREPROCE.INC  SYMBDUMP.INC TABLES.INC   VARIABLE.INC
REM        VERSION.INC   X86_64.INC
REM   3) MODES.INC уже лежить тут (узятий з SOURCE\LINUX\X64\)
REM   4) SYSTEM.INC тут — це НАШ порт, не бери його з SOURCE\
REM ========================================================

REM ВАЖЛИВО: запуск "від імені адміністратора" ставить робочу теку
REM у C:\Windows\System32, і скрипт не бачить жодного .INC поруч із собою.
REM Цей рядок переходить у теку самого файлу — без нього перевірка
REM нижче показує "ВІДСУТНІЙ" для всіх файлів, хоч вони й на місці.
cd /d "%~dp0"

set "FASM=C:\fasm\fasm.exe"
set "VHD_DRIVE=E:"

echo Перевірка наявності вихідників fasm...
set MISSING=0
for %%F in (ASSEMBLE.INC AVX.INC ERRORS.INC EXPRCALC.INC EXPRPARS.INC ^
            FORMATS.INC MESSAGES.INC PARSER.INC PREPROCE.INC SYMBDUMP.INC ^
            TABLES.INC VARIABLE.INC VERSION.INC X86_64.INC MODES.INC SYSTEM.INC) do (
    if not exist "%%F" (
        echo   ВІДСУТНІЙ: %%F
        set MISSING=1
    )
)
if "%MISSING%"=="1" (
    color 0C
    echo.
    echo Скопіюй відсутні .INC з папки SOURCE вихідників fasm.
    pause
    exit /b 1
)

echo Збірка FASM.BIN...
"%FASM%" FASM.ASM FASM.BIN
if %errorlevel% neq 0 (
    color 0C
    echo [ПОМИЛКА] Збірка не вдалася.
    pause
    exit /b 1
)

color 0A
echo [ОК] FASM.BIN зібрано.
dir FASM.BIN | find "FASM"
echo.
echo Тепер скопіюй FASM.BIN у корінь віртуального диска (%VHD_DRIVE%\)
echo і запусти в EUGENE OS:  RUN FASM.BIN HELLO.ASM HELLO.BIN
pause