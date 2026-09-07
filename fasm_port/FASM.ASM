; flat assembler for EUGENE OS (x86-64)
; Порт на основі SOURCE/LINUX/X64/FASM.ASM
; Copyright (c) 1999-2022, Tomasz Grysztar. All rights reserved.
;
; ==========================================================
; ЗБІРКА (на Windows, звичайним fasm):
;     fasm FASM.ASM FASM.BIN
; Поруч мають лежати: EUGENE.INC, MODES.INC і всі .INC з SOURCE/
;
; ЗАПУСК в EUGENE OS:
;     RUN FASM.BIN HELLO.ASM HELLO.BIN
;
; ==========================================================
; ГОЛОВНІ ВІДМІННОСТІ ВІД LINUX-ВЕРСІЇ
;
; 1) Плоский бінарник за адресою AppMemoryBase (0x4000000),
;    а не ELF. Ядро вантажить його туди і стрибає на початок.
;
; 2) Командний рядок. У Linux argv лежить на стеку, і get_params
;    читає його як масив вказівників. У нас ядро віддає ОДИН рядок
;    через syscall 21, тому на старті ми самі ріжемо його на слова
;    і будуємо такий самий масив — після цього весь код розбору
;    параметрів працює без змін.
;
; 3) Таймінг через syscall 10 (такти таймера), а не gettimeofday.
;
; 4) Неініціалізовані буфери зануляються вручну: objcopy/binary
;    не зберігає їх у файлі, а пам'ять після попередньої програми
;    брудна.
; ==========================================================

        format  binary as 'bin'
        org     0x4000000               ; = AppMemoryBase у kernel.asm

        ; ПОРЯДОК ВАЖЛИВИЙ: use64 тут НЕ ставимо.
        ; modes.inc наприкінці сам робить use32, а той усередині
        ; перевизначає push/pop/jmp/call і вже потім викликає use64.
        ; Якщо написати use64 до include, спрацює справжня директива,
        ; а не макрос — саме так робить і оригінальний Linux-порт.
        include 'modes.inc'

; ----------------------------------------------------------
; ТОЧКА ВХОДУ
; ----------------------------------------------------------
start:
        ; --- Занулюємо всі робочі буфери (див. п.4 вище) ---
        mov     rdi,eug_bss_start
        mov     rcx,eug_bss_end-eug_bss_start
        xor     al,al
        cld
        rep     stosb

        mov     [con_handle],1
        mov     esi,_logo
        call    display_string

        ; --- Будуємо argv з рядка, який дало ядро ---
        call    build_command_line
        mov     [environment],0         ; змінних оточення в нас немає

        call    get_params
        jc      information

        call    init_memory

        mov     esi,_memory_prefix
        call    display_string
        mov     eax,[memory_end]
        sub     eax,[memory_start]
        add     eax,[additional_memory_end]
        sub     eax,[additional_memory]
        shr     eax,10
        call    display_number
        mov     esi,_memory_suffix
        call    display_string

        ; --- Час старту: такти таймера замість gettimeofday ---
        mov     rax,SYS_GETTICKS
        xor     rsi,rsi
        xor     r9,r9
        int     0x80
        mov     [start_time],eax

        and     [preprocessing_done],0
        call    preprocessor
        or      [preprocessing_done],-1
        call    parser
        call    assembler
        call    formatter

        call    display_user_messages
        movzx   eax,[current_pass]
        inc     eax
        call    display_number
        mov     esi,_passes_suffix
        call    display_string

        mov     rax,SYS_GETTICKS
        xor     rsi,rsi
        xor     r9,r9
        int     0x80
        sub     eax,[start_time]        ; такти, а не мілісекунди
        call    display_number
        mov     esi,_ticks_suffix
        call    display_string

        mov     eax,[written_size]
        call    display_number
        mov     esi,_bytes_suffix
        call    display_string
        xor     al,al
        jmp     exit_program

information:
        mov     esi,_usage
        call    display_string
        mov     al,1
        jmp     exit_program

; ----------------------------------------------------------
; build_command_line
;
; Ядро віддає хвіст командного рядка одним рядком, наприклад
; "HELLO.ASM HELLO.BIN". Тут ми ріжемо його на слова (замінюючи
; пробіли нулями) і будуємо масив у форматі, який очікує get_params:
;
;     [qword count][qword argv0][qword argv1]...
;
; argv0 — це умовне ім'я програми, get_params його пропускає.
; ----------------------------------------------------------
; УВАГА ПРО push/pop У ЦЬОМУ ФАЙЛІ:
; modes.inc перевизначає push і pop як 32-БІТНІ (макрос pushD) — це
; і є весь його сенс: ядро fasm 32-бітне, і його "push eax" має класти
; 4 байти. Тому 'push rbx' тут НЕ ЗБИРАЄТЬСЯ:
;     error: operand sizes do not match
; 64-бітні регістри зберігаємо вручну через змінні.
build_command_line:
        mov     [save_rbx],rbx
        mov     [save_rsi],rsi
        mov     [save_rdi],rdi

        ; забираємо рядок аргументів у cmdline_raw
        mov     rax,SYS_GETARGS
        mov     rsi,cmdline_raw
        mov     r9,255
        int     0x80

        ; argv[0] — умовне ім'я самої програми
        mov     rbx,argv_array
        mov     qword [rbx+8],_self_name
        mov     ecx,1                   ; лічильник аргументів

        mov     rsi,cmdline_raw
      eug_cl_skip_spaces:
        mov     al,[rsi]
        test    al,al
        jz      eug_cl_done
        cmp     al,' '
        jne     eug_cl_word
        inc     rsi
        jmp     eug_cl_skip_spaces

      eug_cl_word:
        ; знайшли початок чергового слова
        cmp     ecx,MAX_ARGS
        jae     eug_cl_done
        mov     [rbx+8+rcx*8],rsi
        inc     ecx
      eug_cl_scan:
        mov     al,[rsi]
        test    al,al
        jz      eug_cl_done
        cmp     al,' '
        je      eug_cl_terminate
        inc     rsi
        jmp     eug_cl_scan
      eug_cl_terminate:
        mov     byte [rsi],0            ; ріжемо слово
        inc     rsi
        jmp     eug_cl_skip_spaces

      eug_cl_done:
        mov     [rbx],rcx               ; count
        mov     [command_line],rbx

        mov     rdi,[save_rdi]
        mov     rsi,[save_rsi]
        mov     rbx,[save_rbx]
        ret

SYS_GETTICKS = 10
MAX_ARGS     = 16


; ==========================================================
; РОЗБІР ПАРАМЕТРІВ
;
; get_params не входить до ядра fasm — кожен порт має свою копію
; у власному FASM.ASM. Узято з LINUX/X64 дослівно: працює поверх
; масиву [count][argv0][argv1]..., який будує build_command_line,
; тому змінювати нічого не довелося.
;
; Локальні мітки отримали префікс gp_, щоб не зіткнутися ні з
; ядром fasm (3179 глобальних міток), ні з нашими eug_*.
; ==========================================================
get_params:
        mov        rbx,[command_line]
        mov        [input_file],0
        mov        [output_file],0
        mov        [symbols_file],0
        mov        [memory_setting],0
        mov        [passes_limit],100
        mov        rcx,[rbx]
        add        rbx,8*2
        dec        rcx
        jz        gp_bad_params
        mov        [definitions_pointer],predefinitions
        mov        [path_pointer],paths
      gp_get_param:
        mov        rsi,[rbx]
        mov        al,[rsi]
        cmp        al,'-'
        je        gp_option_param
        cmp        [input_file],0
        jne        gp_get_output_file
        call        collect_path
        mov        [input_file],edx
        jmp        gp_next_param
      gp_get_output_file:
        cmp        [output_file],0
        jne        gp_bad_params
        call        collect_path
        mov        [output_file],edx
        jmp        gp_next_param
      gp_option_param:
        inc        rsi
        lodsb
        cmp        al,'m'
        je        gp_memory_option
        cmp        al,'M'
        je        gp_memory_option
        cmp        al,'p'
        je        gp_passes_option
        cmp        al,'P'
        je        gp_passes_option
        cmp        al,'d'
        je        gp_definition_option
        cmp        al,'D'
        je        gp_definition_option
        cmp        al,'s'
        je        gp_symbols_option
        cmp        al,'S'
        je        gp_symbols_option
      gp_bad_params:
        stc
        ret
      gp_memory_option:
        cmp        byte [rsi],0
        jne        gp_get_memory_setting
        dec        rcx
        jz        gp_bad_params
        add        rbx,8
        mov        rsi,[rbx]
      gp_get_memory_setting:
        call        gp_get_option_value
        or        edx,edx
        jz        gp_bad_params
        cmp        edx,1 shl (32-10)
        jae        gp_bad_params
        mov        [memory_setting],edx
        jmp        gp_next_param
      gp_passes_option:
        cmp        byte [rsi],0
        jne        gp_get_passes_setting
        dec        rcx
        jz        gp_bad_params
        add        rbx,8
        mov        rsi,[rbx]
      gp_get_passes_setting:
        call        gp_get_option_value
        or        edx,edx
        jz        gp_bad_params
        cmp        edx,10000h
        ja        gp_bad_params
        mov        [passes_limit],dx
      gp_next_param:
        add        rbx,8
        dec        rcx
        jnz        gp_get_param
        cmp        [input_file],0
        je        gp_bad_params
        mov        eax,[definitions_pointer]
        mov        byte [eax],0
        mov        [initial_definitions],predefinitions
        clc
        ret
      gp_definition_option:
        cmp        byte [rsi],0
        jne        gp_get_definition
        dec        rcx
        jz        gp_bad_params
        add        rbx,8
        mov        rsi,[rbx]
      gp_get_definition:
        mov        r12d,edi
        mov        edi,[definitions_pointer]
        call        gp_convert_definition_option
        mov        [definitions_pointer],edi
        mov        edi,r12d
        jc        gp_bad_params
        jmp        gp_next_param
      gp_symbols_option:
        cmp        byte [rsi],0
        jne        gp_get_symbols_setting
        dec        rcx
        jz        gp_bad_params
        add        rbx,8
        mov        rsi,[rbx]
      gp_get_symbols_setting:
        call        collect_path
        mov        [symbols_file],edx
        jmp        gp_next_param
      gp_get_option_value:
        xor        eax,eax
        mov        edx,eax
      gp_get_option_digit:
        lodsb
        cmp        al,20h
        je        gp_option_value_ok
        or        al,al
        jz        gp_option_value_ok
        sub        al,30h
        jc        gp_invalid_option_value
        cmp        al,9
        ja        gp_invalid_option_value
        imul        edx,10
        jo        gp_invalid_option_value
        add        edx,eax
        jc        gp_invalid_option_value
        jmp        gp_get_option_digit
      gp_option_value_ok:
        dec        rsi
        clc
        ret
      gp_invalid_option_value:
        stc
        ret
      gp_convert_definition_option:
        mov        edx,edi
        cmp        edi,predefinitions+1000h
        jae        gp_bad_definition_option
        xor        al,al
        stosb
      gp_copy_definition_name:
        lodsb
        cmp        al,'='
        je        gp_copy_definition_value
        cmp        al,20h
        je        gp_bad_definition_option
        or        al,al
        jz        gp_bad_definition_option
        cmp        edi,predefinitions+1000h
        jae        gp_bad_definition_option
        stosb
        inc        byte [edx]
        jnz        gp_copy_definition_name
      gp_bad_definition_option:
        stc
        ret
      gp_copy_definition_value:
        lodsb
        cmp        al,20h
        je        gp_definition_value_end
        or        al,al
        jz        gp_definition_value_end
        cmp        edi,predefinitions+1000h
        jae        gp_bad_definition_option
        stosb
        jmp        gp_copy_definition_value
      gp_definition_value_end:
        dec        rsi
        cmp        edi,predefinitions+1000h
        jae        gp_bad_definition_option
        xor        al,al
        stosb
        clc
        ret
collect_path:
        mov        edi,[path_pointer]
        mov        edx,edi
     gp_copy_path_to_low_memory:
        lodsb
        stosb
        test        al,al
        jnz        gp_copy_path_to_low_memory
        mov        [path_pointer],edi
        ret

; ----------------------------------------------------------
; ЯДРО FASM — без жодних змін
; ----------------------------------------------------------
        include 'system.inc'            ; наш EUGENE.INC, перейменований
        include 'version.inc'

_logo           db 'flat assembler  version ',VERSION_STRING,' (EUGENE OS)',0Ah,0
_self_name      db 'FASM.BIN',0

_usage          db 'usage: RUN FASM.BIN <source> [output]',0Ah
                db 'optional settings:',0Ah
                db '  -m <limit>    set the limit in kilobytes for memory',0Ah
                db '  -p <limit>    set the maximum allowed number of passes',0Ah
                db '  -d <name=value>  define symbolic variable',0Ah,0

_memory_prefix  db ' (',0
_memory_suffix  db ' kilobytes memory)',0Ah,0
_passes_suffix  db ' passes, ',0
_ticks_suffix   db ' ticks, ',0
_bytes_suffix   db ' bytes.',0Ah,0
_no_low_memory  db 'failed to allocate memory',0


        include 'errors.inc'
        include 'symbdump.inc'
        include 'preproce.inc'
        include 'parser.inc'
        include 'exprpars.inc'
        include 'assemble.inc'
        include 'exprcalc.inc'
        include 'x86_64.inc'
        include 'avx.inc'
        include 'formats.inc'
        include 'tables.inc'
        include 'messages.inc'

; ----------------------------------------------------------
; ДАНІ, ЯКІ ЗБЕРІГАЮТЬСЯ У ФАЙЛІ
; ----------------------------------------------------------
        include 'variable.inc'

align 4

; ----------------------------------------------------------
; НЕІНІЦІАЛІЗОВАНА ОБЛАСТЬ
; Зануляється на старті циклом у start. У плоскому бінарнику
; ці байти теж присутні (fasm доповнює нулями), але покладатись
; на це не можна: після попередньої програми пам'ять брудна.
; ----------------------------------------------------------
eug_bss_start:

; Точний перелік з SOURCE/LINUX/X64/FASM.ASM — жодної змінної
; не можна пропустити, бо на них посилається ядро fasm.
command_line        dq ?
memory_setting      dd ?
path_pointer        dd ?
definitions_pointer dd ?
environment         dq ?
timestamp           dq ?
start_time          dd ?
con_handle          dd ?
displayed_count     dd ?
last_displayed      db ?
character           db ?
preprocessing_done  db ?

align 8
; --- Наше, чого немає в Linux-версії ---
save_rbx            dq ?                ; modes.inc робить push 32-бітним,
save_rsi            dq ?                ; тому 64-бітні регістри зберігаємо
save_rdi            dq ?                ; вручну через пам'ять
argv_array          rq MAX_ARGS+2       ; [count][argv0][argv1]...
cmdline_raw         rb 256              ; сирий рядок від syscall 21

align 4
buffer              rb 1000h
predefinitions      rb 1000h
paths               rb 10000h

eug_bss_end: