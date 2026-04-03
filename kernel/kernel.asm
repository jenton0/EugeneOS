format binary as 'bin'      
use64                       
org 0x100000                

; ==========================================================
; КАРТА ПАМ'ЯТІ ЯДРА
; ==========================================================
VideoMemoryBase equ 0x1000000  ; 16 МБ: Буфер для завантаження файлів з диска
DirBuffer       equ 0x2000000  ; 32 МБ: Буфер для читання папок (VFS)
BackBufferBase  equ 0x3000000  ; 48 МБ: Буфер для рендеру відео/кадрів
AppMemoryBase   equ 0x4000000  ; 64 МБ: Адреса, куди вантажаться .APP/.BIN програми
AppStackTop     equ 0x3FFFFF8  ; 65 МБ: Вершина стеку для зовнішніх програм
HeapBase        equ 0x5000000  ; 80 МБ: Початок динамічної пам'яті (Купи)
HeapSize        equ 0x1400000  ; Розмір купи: 20 МБ (для майбутнього GUI)

; ==========================================================
; 1. ІНІЦІАЛІЗАЦІЯ ЯДРА (ТОЧКА ВХОДУ)
; ==========================================================
start:
    cli                         ; Вимикаємо переривання до повного налаштування
    cld                         ; Встановлюємо напрямок копіювання рядків (вперед)
    
    ; Отримуємо параметри екрана від UEFI-завантажувача
    mov     [ScreenBase], rcx   ; Базова адреса фреймбуфера
    mov     [ScreenWidth], edx  ; Ширина екрана (в пікселях)
    mov     [ScreenHeight], r8d ; Висота екрана (в пікселях)

    call    ClearScreen         ; Очищаємо екран
    call    DrawTaskbar         ; Малюємо верхню панель задач
    
    ; Ініціалізація підсистем ОС
    call    InitFAT32           ; Запускаємо файлову систему FAT32
    call    InitMouse
    call    InitHeap            ; Ініціалізуємо менеджер пам'яті
    call    InitTask1           ; Створюємо фоновий процес
    call    InitInterrupts      ; Налаштовуємо IDT (переривання та таймер)

    ; Виводимо привітання
    mov     rcx, 20             
    mov     rdx, 20             
    lea     r8,  [MsgName]      
    mov     r9d, 0x00FFFFFF     
    call    DrawString

    mov     rcx, 20
    mov     rdx, 50
    lea     r8,  [MsgHelpList]
    mov     r9d, 0x00FFFF00
    call    DrawString

    ; Встановлюємо початкову позицію курсора консолі
    mov     [CursorX], 20
    mov     [CursorY], 100
    call    PrintPrompt         

; ==========================================================
; 2. ГОЛОВНИЙ ЦИКЛ ЯДРА (MAIN LOOP)
; ==========================================================
kernel_loop:
    call    CheckKeyboard       ; Перевіряємо, чи натиснута клавіша
    mov     rcx, 10000          ; Штучна затримка, щоб не перегрівати CPU
.delay:
    dec     rcx
    jnz     .delay
    jmp     kernel_loop         

; Заморозка системи (при критичних помилках)
hang:                           
    cli                         
    hlt                         
    jmp     hang

; ==========================================================
; 3. КОМАНДНА ОБОЛОНКА (SHELL)
; ==========================================================
ExecuteCommand:
    mov     rbx, [BufferLen]
    mov     byte [CmdBuffer + rbx], 0   ; Ставимо 0 у кінці рядка (Null-terminated)
    call    NewLine             

    ; --- Диспетчер команд (Шукаємо збіги) ---
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdLS]
    call    StrCmp              
    test    rax, rax
    jz      .run_ls             

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCD]
    call    StrPrefix           
    test    rax, rax
    jz      .run_cd

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdOpen]
    call    StrPrefix           
    test    rax, rax
    jz      .run_open

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdEdit]
    call    StrPrefix
    test    rax, rax
    jz      .run_edit
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCreate]
    call    StrPrefix
    test    rax, rax
    jz      .run_create
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdRM]
    call    StrPrefix
    test    rax, rax
    jz      .run_rm

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdTime]
    call    StrCmp
    test    rax, rax
    jz      .run_time

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdInfo]
    call    StrCmp
    test    rax, rax
    jz      .run_info

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdBeep]
    call    StrCmp
    test    rax, rax
    jz      .run_beep

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdHelp]
    call    StrCmp
    test    rax, rax
    jz      .run_help
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdWin]
    call    StrCmp
    test    rax, rax
    jz      .run_win

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdCLS]
    call    StrCmp
    test    rax, rax
    jz      .run_cls

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdBack]
    call    StrCmp
    test    rax, rax
    jz      .run_back

    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdReboot]
    call    StrCmp
    test    rax, rax
    jz      .run_reboot
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdRun]
    call    StrPrefix
    test    rax, rax
    jz      .run_app
    
    lea     rsi, [CmdBuffer]
    lea     rdi, [CmdMkdir]
    call    StrPrefix
    test    rax, rax
    jz      .run_mkdir

    ; Якщо жодна команда не підійшла - виводимо помилку
    cmp     [BufferLen], 0
    je      .finish

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgUnknown]
    mov     r9d, 0x000000FF     ; Червоний колір
    call    DrawString
    call    NewLine
    jmp     .finish

; --- Обробник CLS (Очищення екрана) ---
.run_cls:
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    jmp     .finish

; --- Обробник WIN (Тест GUI вікна) ---
.run_win:
    ; Малюємо тестове вікно посеред екрана
    mov     rcx, 150       ; X координата
    mov     rdx, 150       ; Y координата
    mov     r8,  400       ; Ширина
    mov     r9,  200       ; Висота
    call    DrawWindow

    ; Текст у заголовку вікна
    mov     rcx, 155
    mov     rdx, 155
    lea     r8,  [MsgWinTitle]      
    mov     r9d, 0x00FFFFFF     ; Білий текст
    call    DrawString

    ; Текст у тілі вікна
    mov     rcx, 170
    mov     rdx, 200
    lea     r8,  [MsgWinBody]      
    mov     r9d, 0x00000000     ; Чорний текст
    call    DrawString

    ; Опускаємо курсор консолі нижче вікна, щоб не писати поверх нього
    mov     qword [CursorX], 20
    mov     qword [CursorY], 380
    jmp     .finish

; --- Обробник CD (Зміна папки) ---
.run_cd:
    lea     rsi, [CmdBuffer + 3]        
    cmp     byte [rsi], '.'
    jne     .normal_cd
    cmp     byte [rsi+1], '.'
    jne     .normal_cd
    
    ; Якщо це "CD .."
    lea     rdi, [ParsedFileName]
    mov     rax, 0x2020202020202E2E    
    mov     qword [rdi], rax           
    mov     dword [rdi+8], 0x00202020  
    jmp     .do_cd_find

.normal_cd:
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    
.do_cd_find:
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .not_found_msg
    
    test    dl, 0x10            
    jz      .not_a_dir          

    test    eax, eax
    jnz     .set_cd
    mov     eax, [RootCluster]
    
.set_cd:
    ; Зберігаємо стару папку в історію
    push    rbx
    mov     ebx, [DirHistoryIndex]
    cmp     ebx, 63                 
    jge     .skip_history
    mov     ecx, [CurrentDirCluster]
    mov     dword [DirHistoryStack + ebx*4], ecx
    inc     dword [DirHistoryIndex]
.skip_history:
    pop     rbx
    mov     [CurrentDirCluster], eax

    ; Оновлюємо рядок шляху для промпту
    cmp     byte [CmdBuffer + 3], '.'   
    je      .cd_dotdot
    lea     rsi, [CmdBuffer + 3]        
    call    AppendPath
    jmp     .finish
.cd_dotdot:
    call    RemoveLastPath
    jmp     .finish

.not_a_dir:                     
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNotDir]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish

; --- Обробник OPEN (Диспетчер файлів) ---
.run_open:
    lea     rsi, [CmdBuffer + 5]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name

    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .not_found_msg

    test    dl, 0x10            
    jnz     .not_a_dir

    mov     [LoadedFileSize], ebx
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain
    
    mov     eax, dword [ParsedFileName + 8]
    and     eax, 0x00FFFFFF     

    cmp     eax, 0x00505041     ; 'APP'
    je      .open_app
    cmp     eax, 0x004E4942     ; 'BIN'
    je      .open_app
    cmp     eax, 0x00504D42     ; 'BMP'
    je      .open_bmp
    cmp     eax, 0x00545854     ; 'TXT'
    je      .open_txt
    cmp     eax, 0x00564157     ; 'WAV'
    je      .open_wav

    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgUnknownExt]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish

.open_app:
    call    RunBadApplePlayer
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgVideoDone]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    jmp     .finish

.open_bmp:
    mov     r9, VideoMemoryBase
    call    DrawBMP
.wait_esc_bmp:
    in      al, 0x64
    test    al, 1
    jz      .wait_esc_bmp
    in      al, 0x60
    cmp     al, 0x01
    jne     .wait_esc_bmp
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    jmp     .finish

.open_txt:
    mov     rsi, VideoMemoryBase
    mov     ebx, [LoadedFileSize]
    mov     byte [rsi + rbx], 0 
    mov     rcx, 20
    mov     rdx, [CursorY]
    mov     r8,  rsi
    mov     r9d, 0x00FFFFFF
    call    DrawString
    mov     [CursorY], rdx
    call    NewLine
    jmp     .finish

.open_wav:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgAudio]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    mov     rax, 311
    call    PlaySound
    call    BeepDelay
    call    StopSound
    jmp     .finish

.not_found_msg:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgReadErr]
    mov     r9d, 0x000000FF
    call    DrawString
    call    NewLine
    jmp     .finish
    
; --- Обробник RUN (Запуск сторонніх програм) ---
.run_app:
    lea     rsi, [CmdBuffer + 4]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name

    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .not_found_msg              

    mov     [LoadedFileSize], ebx
    mov     r9, AppMemoryBase
    call    LoadFAT32Chain
    
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgRun]
    mov     r9d, 0x00FF00FF             
    call    DrawString
    call    NewLine
    
    call    SpawnAppTask
    
.wait_for_app:                      
    call    CheckKeyboard           
    cmp     byte [AppRunning], 1
    je      .wait_for_app           

    call    ClearScreen             
    call    DrawTaskbar             
    mov     qword [CursorX], 20     
    mov     qword [CursorY], 100
    jmp     .finish                 

; --- Обробник BACK (Крок назад по історії папок) ---
.run_back:
    mov     ebx, [DirHistoryIndex]
    test    ebx, ebx                
    jz      .no_history             
    dec     ebx                     
    mov     [DirHistoryIndex], ebx
    mov     eax, dword [DirHistoryStack + ebx*4]  
    mov     [CurrentDirCluster], eax              
    call    RemoveLastPath          
    jmp     .finish

.no_history:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgNoHistory]
    mov     r9d, 0x000000FF         
    call    DrawString
    call    NewLine
    jmp     .finish

; --- Інші команди ОС ---
.run_ls:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgLS]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    call    ListFilesFAT32      
    jmp     .finish

.run_info:                      
    xor     eax, eax
    cpuid                       
    mov     dword [VendorID], ebx
    mov     dword [VendorID + 4], edx
    mov     dword [VendorID + 8], ecx
    lea     rsi, [VendorID]
    mov     rcx, 12
.to_upper:
    cmp     byte [rsi], 'a'
    jb      .skip_char
    cmp     byte [rsi], 'z'
    ja      .skip_char
    sub     byte [rsi], 32
.skip_char:
    inc     rsi
    dec     rcx
    jnz     .to_upper
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgCPU]
    mov     r9d, 0x0000FF00     
    call    DrawString
    add     rcx, 110
    lea     r8,  [VendorID]
    mov     r9d, 0x00FFFFFF     
    call    DrawString
    call    NewLine
    jmp     .finish

.run_time:
    call    GetRTC
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgTime]
    mov     r9d, 0x00AAAAAA
    call    DrawString
    add     rcx, 90
    lea     r8,  [TimeStr]
    mov     r9d, 0x0000FF00
    call    DrawString
    call    NewLine
    jmp     .finish

.run_beep:
    mov     rax, 311            
    call    PlaySound
    call    BeepDelay
    mov     rax, 233            
    call    PlaySound
    call    BeepDelay
    mov     rax, 261            
    call    PlaySound
    call    BeepDelay
    call    StopSound
    call    NewLine
    jmp     .finish

.run_help:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgHelpList]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    call    NewLine
    jmp     .finish
    
.run_mkdir:
    lea     rsi, [CmdBuffer + 6]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name             
    lea     r8, [ParsedFileName]
    call    CreateDirFAT32              
    jc      .disk_err_msg                   
    
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgDirCreated]
    mov     r9d, 0x0000FF00
    call    DrawString
    add     rcx, 150
    lea     r8,  [ParsedFileName]
    call    DrawString                  
    call    NewLine
    jmp     .finish

.run_create:
    lea     rsi, [CmdBuffer + 7]        
    lea     rdi, [ParsedFileName]       
    call    FormatFAT32Name             
    lea     r8, [ParsedFileName]
    call    CreateFileFAT32             
    jc      .disk_err_msg                   
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgCreated]
    mov     r9d, 0x0000FF00
    call    DrawString
    add     rcx, 120
    lea     r8,  [ParsedFileName]
    call    DrawString                  
    call    NewLine
    jmp     .finish

.run_rm:
    lea     rsi, [CmdBuffer + 3]        
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name
    lea     r8, [ParsedFileName]
    call    DeleteFileFAT32
    jc      .disk_err_msg                     
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgDeleted]
    mov     r9d, 0x0000FF00             
    call    DrawString
    call    NewLine
    jmp     .finish

.disk_err_msg:
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [MsgWriteErr]
    mov     r9d, 0x000000FF             
    call    DrawString
    call    NewLine
    jmp     .finish

.run_reboot:
    in      al, 0x64
    test    al, 2
    jnz     .run_reboot
    mov     al, 0xFE            
    out     0x64, al
    jmp     hang

; --- ІЗОЛЬОВАНА ПІДСИСТЕМА РЕДАКТОРА ---
.run_edit:
    lea     rsi, [CmdBuffer + 5]
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name

    lea     rdi, [EditorBuffer]
    mov     rcx, 512
    xor     al, al
    cld
    rep     stosb
    mov     qword [EditorCursor], 0

    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .ui_init            
    mov     [LoadedFileSize], ebx
    mov     r9, VideoMemoryBase
    call    LoadFAT32Chain

    lea     rsi, [VideoMemoryBase]
    lea     rdi, [EditorBuffer]
    mov     rcx, 512
    cld
    rep     movsb

    lea     rsi, [EditorBuffer]
    xor     rcx, rcx
.find_len:
    cmp     rcx, 511
    jge     .set_cursor
    mov     al, [rsi+rcx]
    test    al, al
    jz      .set_cursor
    inc     rcx
    jmp     .find_len
.set_cursor:
    mov     [EditorCursor], rcx

.ui_init:
    call    ClearScreen
    mov     rdi, [ScreenBase]
    movsxd  rcx, dword [ScreenWidth]
    imul    rcx, 20
    mov     eax, 0x000000AA
    cld
    rep     stosd

    mov     rcx, 20
    mov     rdx, 0
    lea     r8,  [MsgEditor]
    mov     r9d, 0x00FFFFFF
    call    DrawString

    mov     qword [CursorX], 20
    mov     qword [CursorY], 40

    cmp     qword [EditorCursor], 0
    je      .editor_loop

    lea     rsi, [EditorBuffer]
    mov     rcx, [EditorCursor]
.draw_loaded:
    movzx   r8, byte [rsi]
    push    rcx
    push    rsi
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r9d, 0x00FFFFFF
    call    DrawChar_Safe
    add     qword [CursorX], 9
    pop     rsi
    pop     rcx
    inc     rsi
    dec     rcx
    jnz     .draw_loaded

.editor_loop:
    call    DrawCursor
    in      al, 0x64
    test    al, 1
    jz      .editor_loop
    in      al, 0x60
    test    al, 0x80
    jnz     .editor_loop

    cmp     al, 0x01            ; ESC
    je      .exit_editor
    cmp     al, 0x3C            ; F2
    je      .save_editor
    cmp     al, 0x0E            ; Backspace
    je      .bs_editor

    lea     rbx, [ScanCodes]
    xlatb
    test    al, al
    jz      .editor_loop

    mov     rbx, [EditorCursor]
    cmp     rbx, 510
    jge     .editor_loop
    
    mov     [EditorBuffer + rbx], al
    inc     qword [EditorCursor]
    
    call    EraseCursor
    movzx   r8, al
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r9d, 0x00FFFFFF
    call    DrawChar_Safe
    add     qword [CursorX], 9
    jmp     .editor_loop

.bs_editor:
    cmp     qword [EditorCursor], 0
    je      .editor_loop
    call    EraseCursor
    dec     qword [EditorCursor]
    mov     rbx, [EditorCursor]
    mov     byte [EditorBuffer + rbx], 0
    sub     qword [CursorX], 9
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    call    EraseChar
    call    DrawCursor
    jmp     .editor_loop

.save_editor:
    lea     r8, [ParsedFileName]
    call    SaveFileFAT32
    jnc     .save_ok
    lea     r8, [ParsedFileName]
    call    CreateFileFAT32
    lea     r8, [ParsedFileName]
    call    SaveFileFAT32
    jc      .save_fail
.save_ok:
    mov     rcx, 450
    mov     rdx, 0
    lea     r8,  [MsgSaved]
    mov     r9d, 0x0000FF00
    call    DrawString
    jmp     .editor_loop
.save_fail:
    mov     rcx, 450
    mov     rdx, 0
    lea     r8,  [MsgErrFat]
    mov     r9d, 0x000000FF
    call    DrawString
    jmp     .editor_loop

.exit_editor:
    call    ClearScreen
    call    DrawTaskbar
    mov     qword [CursorX], 20
    mov     qword [CursorY], 100
    jmp     .finish

.finish:
    mov     qword [BufferLen], 0        
    call    PrintPrompt                 
    ret

; ==========================================================
; 4. СИСТЕМНІ УТИЛІТИ 
; ==========================================================
PrintPrompt:
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    lea     r8,  [CurrentPath]
    mov     r9d, 0x0000FF00             
    call    DrawString
    
    lea     rsi, [CurrentPath]
    xor     rax, rax
.len_loop:
    cmp     byte [rsi+rax], 0
    je      .len_done
    inc     rax
    jmp     .len_loop
.len_done:
    imul    rax, 9
    add     qword [CursorX], rax        
    
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r8,  '>'
    mov     r9d, 0x0000FF00
    call    DrawChar_Safe
    add     qword [CursorX], 18
    
    call    DrawCursor                  
    ret

AppendPath:
    lea     rdi, [CurrentPath]
.find_end:
    cmp     byte [rdi], 0
    je      .copy_name
    inc     rdi
    jmp     .find_end
.copy_name:
    mov     al, [rsi]
    test    al, al
    jz      .add_slash
    cmp     al, ' '
    je      .add_slash
    cmp     al, 'a'
    jb      .store
    cmp     al, 'z'
    ja      .store
    sub     al, 32
.store:
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     .copy_name
.add_slash:
    mov     word [rdi], 0x002F          
    ret

RemoveLastPath:
    lea     rdi, [CurrentPath]
.find_end_rm:
    cmp     byte [rdi], 0
    je      .found_end
    inc     rdi
    jmp     .find_end_rm
.found_end:
    dec     rdi                         
    lea     rbx, [CurrentPath + 5]      
    cmp     rdi, rbx
    jle     .done                       

    dec     rdi                         
.scan_back:
    cmp     rdi, rbx
    jle     .set_root
    cmp     byte [rdi], '/'             
    je      .cut
    dec     rdi
    jmp     .scan_back
.set_root:
    lea     rdi, [CurrentPath + 4]      
.cut:
    inc     rdi
    mov     byte [rdi], 0               
.done:
    ret

NewLine:
    mov     qword [CursorX], 20         
    mov     rax, [CursorY]
    add     rax, 20                     
    movsxd  r10, dword [ScreenHeight]
    sub     r10, 20                     
    cmp     rax, r10
    jge     .scroll_needed
    mov     [CursorY], rax              
    ret
.scroll_needed:
    call    ScrollScreen                
    ret

StrCmp:
    push    rsi
    push    rdi
    push    rbx
.loop:
    mov     al, [rsi]
    mov     bl, [rdi]
    cmp     al, bl
    jne     .ne
    test    al, al
    jz      .eq
    inc     rsi
    inc     rdi
    jmp     .loop
.ne:
    pop     rbx
    pop     rdi
    pop     rsi
    mov     rax, 1
    ret
.eq:
    pop     rbx
    pop     rdi
    pop     rsi
    xor     rax, rax
    ret

StrPrefix:
    push    rsi
    push    rdi
    push    rbx
.loop:
    mov     bl, [rdi]
    test    bl, bl
    jz      .match
    mov     al, [rsi]
    cmp     al, bl
    jne     .ne
    inc     rsi
    inc     rdi
    jmp     .loop
.match:
    pop     rbx
    pop     rdi
    pop     rsi
    xor     rax, rax
    ret
.ne:
    pop     rbx
    pop     rdi
    pop     rsi
    mov     rax, 1
    ret

FormatFAT32Name:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     rdx, rdi            
    mov     rcx, 11
    mov     al, ' '
    cld
    rep stosb                   
    
    mov     rdi, rdx            
    mov     rcx, 8              
.copy_n:
    lodsb
    test    al, al
    jz      .done
    cmp     al, '.'
    je      .do_ext
    cmp     al, 'a'
    jb      .st_n
    cmp     al, 'z'
    ja      .st_n
    sub     al, 32
.st_n:
    stosb
    loop    .copy_n
.skip:
    lodsb
    test    al, al
    jz      .done
    cmp     al, '.'
    jne     .skip
.do_ext:
    mov     rdi, rdx
    add     rdi, 8              
    mov     rcx, 3
.copy_e:
    lodsb
    test    al, al
    jz      .done
    cmp     al, 'a'
    jb      .st_e
    cmp     al, 'z'
    ja      .st_e
    sub     al, 32
.st_e:
    stosb
    loop    .copy_e
.done:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

CheckKeyboard:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    r8
    push    r9
.poll_loop:
    in      al, 0x64
    test    al, 1               ; Чи є дані в буфері?
    jz      .exit
    
    test    al, 0x20            ; Біт 5 == 1 означає, що це дані від МИШІ!
    jnz     .handle_mouse

.handle_kbd:
    in      al, 0x60            ; Читаємо скан-код клавіатури
    cmp     byte [AppRunning], 1
    jne     .check_release      

    ; --- ФІКС ДЛЯ DOOM (Запис у FIFO чергу) ---
    movzx   ebx, byte [KbdHead]
    mov     [KbdBuffer + ebx], al
    inc     bl
    mov     [KbdHead], bl
    jmp     .poll_loop          ; Читаємо порт далі, щоб нічого не пропустити

.check_release:
    test    al, 0x80            
    jnz     .poll_loop

.normal_kbd:
    cmp     al, 0x1C    
    je      .enter
    cmp     al, 0x0E            
    je      .bs
    lea     rbx, [ScanCodes]    
    xlatb                       
    test    al, al
    jz      .poll_loop               
    mov     rbx, [BufferLen]
    cmp     rbx, 60             
    jge     .poll_loop
    call    EraseCursor
    mov     [CmdBuffer + rbx], al
    inc     qword [BufferLen]
    movzx   r8, al
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r9d, 0x00FFFFFF
    call    DrawChar_Safe
    add     qword [CursorX], 9  
    call    DrawCursor
    jmp     .poll_loop
.bs:                            
    cmp     qword [BufferLen], 0
    je      .poll_loop               
    call    EraseCursor
    dec     qword [BufferLen]
    sub     qword [CursorX], 9  
    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    call    EraseChar           
    call    DrawCursor
    jmp     .poll_loop
.enter:
    call    EraseCursor
    call    ExecuteCommand      
    jmp     .poll_loop

.handle_mouse:
    in      al, 0x60            ; Читаємо байт пакета миші
    movzx   ebx, byte [MouseState]

    ; Просто записуємо байти по черзі, без параноїдальних перевірок бітів
    mov     [MousePacket + ebx], al
    inc     bl
    cmp     bl, 3
    jne     .save_m_state

    ; --- Зібрали 3 байти! ---
    xor     bl, bl              ; Скидаємо стан для наступного пакета

    ; 1. ЧИТАЄМО КЛІКИ (Для майбутнього C GUI)
    mov     al, [MousePacket]
    and     al, 3               ; Виділяємо нижні 2 біти (0=нічого, 1=ліва, 2=права)
    mov     [MouseClick], al

    ; 2. ВІДНОВЛЮЄМО ФОН (стираємо старий курсор)
    call    RestoreMouseCursor

    ; 3. ОНОВЛЮЄМО КООРДИНАТИ X
    movsx   ecx, byte [MousePacket + 1]  
    mov     edx, [MouseX]
    add     edx, ecx
    cmp     edx, 0
    jge     .x_ok
    xor     edx, edx
.x_ok:
    mov     eax, [ScreenWidth]
    sub     eax, 5              ; Віднімаємо розмір курсору
    cmp     edx, eax
    jl      .x_set
    mov     edx, eax
.x_set:
    mov     [MouseX], edx

    ; 4. ОНОВЛЮЄМО КООРДИНАТИ Y (у PS/2 він інвертований)
    movsx   ecx, byte [MousePacket + 2]  
    mov     edx, [MouseY]
    sub     edx, ecx
    cmp     edx, 0
    jge     .y_ok
    xor     edx, edx
.y_ok:
    mov     eax, [ScreenHeight]
    sub     eax, 5
    cmp     edx, eax
    jl      .y_set
    mov     edx, eax
.y_set:
    mov     [MouseY], edx

    ; 5. ЗБЕРІГАЄМО НОВИЙ ФОН ТА МАЛЮЄМО КУРСОР
    call    SaveMouseCursor
    call    DrawMouseCursor
    
.save_m_state:
    mov     [MouseState], bl
    jmp     .poll_loop

.exit:
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

InitMouse:
    push    rax
    push    rbx

    ; --- 1. Очищаємо буфер від старого сміття ---
.flush:
    in      al, 0x64
    test    al, 1
    jz      .done_flush
    in      al, 0x60
    jmp     .flush
.done_flush:

    ; --- 2. Налаштування миші ---
    mov     al, 0xA8            ; Дозволяємо AUX пристрій (мишу)
    out     0x64, al

    mov     al, 0x20            
    out     0x64, al
    call    WaitKbdOut
    in      al, 0x60
    or      al, 2               ; Вмикаємо переривання миші
    and     al, 0xDF            ; ФІКС: Примусово знімаємо біт "Disable Mouse"!
    mov     bl, al

    mov     al, 0x60            
    out     0x64, al
    call    WaitKbdIn
    mov     al, bl
    out     0x60, al

    mov     al, 0xD4            
    out     0x64, al
    call    WaitKbdIn
    mov     al, 0xF6            ; Встановлюємо дефолтні налаштування
    out     0x60, al
    call    WaitKbdOut
    in      al, 0x60            ; Читаємо ACK

    mov     al, 0xD4            
    out     0x64, al
    call    WaitKbdIn
    mov     al, 0xF4            ; Вмикаємо передачу даних пакетів
    out     0x60, al
    call    WaitKbdOut
    in      al, 0x60            ; Читаємо ACK
    
    pop     rbx
    pop     rax
    ret

WaitKbdIn:
    in      al, 0x64
    test    al, 2
    jnz     WaitKbdIn
    ret

WaitKbdOut:
    in      al, 0x64
    test    al, 1
    jz      WaitKbdOut
    ret
GetRTC:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    lea     rdi, [TimeStr]
    mov     al, 4               
    call    ReadRTC
    call    FormatBCD
    mov     [rdi], ax
    mov     al, 2               
    call    ReadRTC
    call    FormatBCD
    mov     [rdi + 3], ax
    mov     al, 0               
    call    ReadRTC
    call    FormatBCD
    mov     [rdi + 6], ax
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

ReadRTC:
    out     0x70, al
    in      al, 0x71
    ret

FormatBCD:
    mov     ah, al
    shr     ah, 4
    and     al, 0x0F
    add     ah, '0'
    add     al, '0'
    xchg    al, ah              
    ret

PlaySound:
    push    rax
    push    rcx
    push    rdx
    mov     rcx, rax
    mov     rax, 1193180
    xor     rdx, rdx
    div     rcx                 
    mov     rcx, rax
    mov     al, 0xB6            
    out     0x43, al
    mov     al, cl              
    out     0x42, al
    mov     al, ch              
    out     0x42, al
    in      al, 0x61            
    or      al, 3
    out     0x61, al
    pop     rdx
    pop     rcx
    pop     rax
    ret

StopSound:
    push    rax
    in      al, 0x61
    and     al, 0xFC            
    out     0x61, al
    pop     rax
    ret

BeepDelay:
    push    rcx
    mov     rcx, 0x07FFFFFF     
.loop_d:
    dec     rcx
    jnz     .loop_d
    pop     rcx
    ret

; ==========================================================
; 13. МЕНЕДЖЕР ДИНАМІЧНОЇ ПАМ'ЯТІ (HEAP)
; ==========================================================
InitHeap:
    mov     rax, HeapBase
    mov     qword [rax], HeapSize - 24  
    mov     qword [rax + 8], 0          
    mov     qword [rax + 16], 0         
    ret

kmalloc:
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    
    add     rcx, 7
    and     rcx, 0xFFFFFFFFFFFFFFF8
    mov     rax, HeapBase
.find_block:
    test    rax, rax
    jz      .out_of_memory      

    cmp     qword [rax + 16], 0         
    jne     .next_block
    cmp     qword [rax], rcx            
    jb      .next_block

    mov     rbx, qword [rax]            
    sub     rbx, rcx                    
    cmp     rbx, 32                     
    jl      .take_whole_block

    mov     qword [rax], rcx            
    
    lea     rdi, [rax + 24 + rcx]       
    sub     rbx, 24                     
    mov     qword [rdi], rbx            
    mov     rdx, qword [rax + 8]        
    mov     qword [rdi + 8], rdx        
    mov     qword [rdi + 16], 0         
    mov     qword [rax + 8], rdi        

.take_whole_block:
    mov     qword [rax + 16], 1         
    add     rax, 24                     
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

.next_block:
    mov     rax, qword [rax + 8]        
    jmp     .find_block

.out_of_memory:
    xor     rax, rax                    
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

kfree:
    test    rcx, rcx
    jz      .done                       
    sub     rcx, 24                     
    mov     qword [rcx + 16], 0         
.done:
    ret

; ==========================================================
; 5. ФАЙЛОВА СИСТЕМА (FAT32 & VFS)
; ==========================================================
InitFAT32:
    xor     eax, eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    mov     eax, dword [SectorBuffer + 0x1BE + 8] 
    test    eax, eax
    jnz     .vbr
    xor     eax, eax
.vbr:
    mov     [VolumeStartLBA], eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    movzx   ebx, word [SectorBuffer + 0x0E]  
    movzx   ecx, byte [SectorBuffer + 0x10]  
    mov     edx, dword [SectorBuffer + 0x24] 
    mov     al, byte [SectorBuffer + 0x0D]
    mov     [SectorsPerCluster], al
    mov     eax, ebx
    add     eax, [VolumeStartLBA]
    mov     [FAT1LBA], eax
    imul    edx, ecx
    add     ebx, edx
    add     ebx, [VolumeStartLBA]
    mov     [DataRegionLBA], ebx
    mov     eax, dword [SectorBuffer + 0x2C]
    mov     [RootCluster], eax
    mov     [CurrentDirCluster], eax
    ret

GetNextFAT32Cluster:
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    mov     ebx, eax
    shl     ebx, 2
    mov     eax, ebx
    shr     eax, 9                  
    add     eax, [FAT1LBA]          
    and     ebx, 511                
    push    rax
    lea     rdi, [FATSectorBuffer]
    call    ReadSectorATA
    pop     rax
    mov     eax, dword [FATSectorBuffer + rbx]
    and     eax, 0x0FFFFFFF         
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

FindFAT32Entry:
    push    rcx
    push    rsi
    push    rdi
    push    r9
    mov     eax, [CurrentDirCluster]

.search_cluster:
    cmp     eax, 0x0FFFFFF8
    jae     .not_found
    
    push    rax                         
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    
    mov     r9, DirBuffer       
    movzx   ecx, byte [SectorsPerCluster]
.read_dir_sec:
    push    rax
    push    rcx
    mov     rdi, r9
    call    ReadSectorATA
    add     r9, 512
    pop     rcx
    pop     rax
    inc     eax
    dec     ecx
    jnz     .read_dir_sec
    
    lea     rsi, [DirBuffer]    
    movzx   ecx, byte [SectorsPerCluster]
    shl     ecx, 4              

.check_entry:
    mov     al, [rsi]
    test    al, al
    jz      .not_found_pop_rax          
    cmp     al, 0xE5
    je      .next_entry
    
    push    rcx
    push    rsi
    mov     rdi, r8
    mov     rcx, 11
    cld
    repe cmpsb
    pop     rsi
    pop     rcx
    je      .found

.next_entry:
    add     rsi, 32
    dec     rcx
    jnz     .check_entry
    
    pop     rax                         
    call    GetNextFAT32Cluster
    jmp     .search_cluster

.found:
    pop     rax                         
    movzx   eax, word [rsi + 0x14]
    shl     eax, 16
    mov     ax, word [rsi + 0x1A]
    test    eax, eax
    jnz     .get_size
    mov     eax, [RootCluster]  
.get_size:
    mov     ebx, dword [rsi + 0x1C]
    mov     dl, byte [rsi + 0x0B]
    clc
    pop     r9
    pop     rdi
    pop     rsi
    pop     rcx
    ret

.not_found_pop_rax:                     
    pop     rax

.not_found:
    stc
    pop     r9
    pop     rdi
    pop     rsi
    pop     rcx
    ret

LoadFAT32Chain:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    r8
    xor     r8, r8              
.load_loop:
    cmp     eax, 0x0FFFFFF8
    jae     .done
    push    rax
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    movzx   ecx, byte [SectorsPerCluster]
.read_sec:
    push    rax
    push    rcx
    mov     rdi, r9
    call    ReadSectorATA
    add     r9, 512
    add     r8, 512
    pop     rcx
    pop     rax
    inc     eax
    dec     ecx
    jnz     .read_sec
    pop     rax
    call    GetNextFAT32Cluster
    jmp     .load_loop
.done:
    mov     rbx, r8
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

ListFilesFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     eax, [CurrentDirCluster]
    mov     r9, DirBuffer       
    call    LoadFAT32Chain
    mov     rsi, DirBuffer      
.parse:
    mov     al, [rsi]
    test    al, al
    jz      .done
    cmp     al, 0xE5
    je      .next
    mov     dl, [rsi + 0x0B]
    cmp     dl, 0x0F            
    je      .next
    test    dl, 0x08            
    jnz     .next
    push    rsi
    lea     rdi, [FileNameBuf]
    mov     rcx, 11
    cld
    rep movsb
    mov     byte [rdi], 0
    pop     rsi
    mov     rcx, 20
    mov     rdx, [CursorY]
    lea     r8,  [FileNameBuf]
    mov     r9d, 0x00FFFFFF
    call    DrawString
    test    byte [rsi + 0x0B], 0x10
    jz      .no_dir_tag
    add     rcx, 120
    lea     r8, [DirTag]
    mov     r9d, 0x00AAAAAA
    call    DrawString
.no_dir_tag:
    call    NewLine
.next:
    add     rsi, 32
    jmp     .parse
.done:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

CreateFileFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     eax, [CurrentDirCluster]
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    mov     [TempSector], eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    lea     rsi, [SectorBuffer]
    mov     rcx, 16
.find_empty:
    mov     al, [rsi]
    test    al, al
    jz      .found_empty                
    cmp     al, 0xE5
    je      .found_empty                
    add     rsi, 32
    dec     rcx
    jnz     .find_empty
    stc
    jmp     .done_c                     
.found_empty:
    push    rcx
    push    rsi
    push    rdi
    mov     rdi, rsi
    mov     rsi, r8          
    mov     rcx, 11
    cld
    rep movsb
    pop     rdi
    pop     rsi
    pop     rcx
    mov     byte [rsi+11], 0x20         
    push    rdi
    lea     rdi, [rsi+12]
    mov     rcx, 20
    xor     al, al
    cld
    rep stosb
    pop     rdi
    mov     eax, [TempSector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    clc                                 
.done_c:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

CreateDirFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi

    call    AllocateFATCluster
    jc      .exit_mkdir_err
    mov     ebx, eax                

    mov     eax, [CurrentDirCluster]
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    mov     [TempSector], eax
    
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA

    lea     rsi, [SectorBuffer]
    mov     rcx, 16
.find_empty_dir:
    mov     al, [rsi]
    test    al, al
    jz      .found_slot
    cmp     al, 0xE5
    je      .found_slot
    add     rsi, 32
    dec     rcx
    jnz     .find_empty_dir
    stc
    jmp     .exit_mkdir

.found_slot:
    push    rsi
    mov     rdi, rsi
    mov     rsi, r8                  
    mov     rcx, 11
    cld
    rep movsb
    pop     rsi

    mov     byte [rsi+11], 0x10     
    
    push    rdi
    lea     rdi, [rsi+12]
    mov     rcx, 20
    xor     al, al
    cld
    rep stosb                        
    pop     rdi

    mov     edx, ebx
    mov     word [rsi+26], dx        
    shr     edx, 16
    mov     word [rsi+20], dx        

    mov     eax, [TempSector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA          

    lea     rdi, [SectorBuffer]
    mov     rcx, 512
    xor     al, al
    cld
    rep stosb                        

    lea     rsi, [SectorBuffer]
    
    mov     dword [rsi],   0x2020202E   
    mov     dword [rsi+4], 0x20202020   
    mov     dword [rsi+8], 0x10202020   
    mov     edx, ebx
    mov     word [rsi+26], dx
    shr     edx, 16
    mov     word [rsi+20], dx

    add     rsi, 32
    mov     dword [rsi],   0x20202E2E   
    mov     dword [rsi+4], 0x20202020   
    mov     dword [rsi+8], 0x10202020   
    
    mov     edx, dword [CurrentDirCluster]
    cmp     edx, [RootCluster]
    jne     .not_root_parent
    xor     edx, edx                
.not_root_parent:
    mov     word [rsi+26], dx
    shr     edx, 16
    mov     word [rsi+20], dx

    mov     eax, ebx
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA

    clc                             
    jmp     .exit_mkdir

.exit_mkdir_err:
    stc                             
.exit_mkdir:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

DeleteFileFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     eax, [CurrentDirCluster]
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    mov     [TempSector], eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    lea     rsi, [SectorBuffer]
    mov     rcx, 16
.find_del:
    mov     al, [rsi]
    test    al, al
    jz      .not_found_del              
    cmp     al, 0xE5
    je      .next_del
    push    rcx
    push    rsi
    mov     rdi, r8
    mov     rcx, 11
    cld
    repe cmpsb
    pop     rsi
    pop     rcx
    je      .found_del
.next_del:
    add     rsi, 32
    dec     rcx
    jnz     .find_del
.not_found_del:
    stc                                 
    jmp     .exit_del
.found_del:
    mov     byte [rsi], 0xE5
    mov     eax, [TempSector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    clc                                 
.exit_del:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

AllocateFATCluster:
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     eax, [FAT1LBA]
    lea     rdi, [FileBuffer]
    call    ReadSectorATA
    lea     rsi, [FileBuffer + 8]        
    mov     rcx, 126
    mov     ebx, 2                      
.scan_fat:
    mov     eax, dword [rsi]
    and     eax, 0x0FFFFFFF
    test    eax, eax
    jz      .found_free                 
    add     rsi, 4
    inc     ebx
    dec     rcx
    jnz     .scan_fat
    stc                                 
    jmp     .exit_alloc
.found_free:
    mov     dword [rsi], 0x0FFFFFFF     
    mov     eax, [FAT1LBA]
    lea     rdi, [FileBuffer]
    call    WriteSectorATA              
    mov     eax, ebx                    
    clc
.exit_alloc:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

SaveFileFAT32:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    mov     eax, [CurrentDirCluster]
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    mov     [TempSector], eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA
    lea     rsi, [SectorBuffer]
    mov     rcx, 16
.find_s:
    mov     al, [rsi]
    test    al, al
    jz      .err_s
    cmp     al, 0xE5
    je      .next_s
    push    rcx
    push    rsi
    mov     rdi, r8
    mov     rcx, 11
    cld
    repe cmpsb
    pop     rsi
    pop     rcx
    je      .found_s
.next_s:
    add     rsi, 32
    dec     rcx
    jnz     .find_s
.err_s:
    stc
    jmp     .exit_s
.found_s:
    movzx   eax, word [rsi + 0x14]
    shl     eax, 16
    mov     ax, word [rsi + 0x1A]
    test    eax, eax
    jnz     .update_size
    push    rsi
    call    AllocateFATCluster
    pop     rsi
    jc      .exit_s
    mov     edx, eax
    mov     word [rsi + 0x1A], dx
    shr     edx, 16
    mov     word [rsi + 0x14], dx
.update_size:
    mov     edx, dword [EditorCursor]
    mov     dword [rsi + 0x1C], edx
    push    rax                         
    mov     eax, [TempSector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA              
    pop     rax                         
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    lea     rdi, [EditorBuffer]
    call    WriteSectorATA
    clc
.exit_s:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; WriteFileFAT32Generic
; Вхід: R8  = ParsedFileName (11 байт, FAT-формат, вже відформатовано)
;        R9  = вказівник на буфер даних
;        RBX = розмір даних у байтах
; Вихід: CF=0 OK, CF=1 помилка
; ==========================================================
WriteFileFAT32Generic:
    push    rax
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r10
    push    r11
    push    r12

    ; --- Крок 1: Знаходимо запис файлу в поточній директорії ---
    mov     eax, [CurrentDirCluster]
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]
    mov     [TempSector], eax
    lea     rdi, [SectorBuffer]
    call    ReadSectorATA

    lea     rsi, [SectorBuffer]
    mov     rcx, 16
.wfg_find:
    mov     al, [rsi]
    test    al, al
    jz      .wfg_err
    cmp     al, 0xE5
    je      .wfg_next
    push    rcx
    push    rsi
    mov     rdi, r8
    mov     rcx, 11
    cld
    repe    cmpsb
    pop     rsi
    pop     rcx
    je      .wfg_found
.wfg_next:
    add     rsi, 32
    dec     rcx
    jnz     .wfg_find
.wfg_err:
    stc
    jmp     .wfg_exit

.wfg_found:
    ; --- Крок 2: Якщо кластер не виділений, алоцюємо перший ---
    movzx   eax, word [rsi + 0x14]
    shl     eax, 16
    mov     ax,  word [rsi + 0x1A]
    test    eax, eax
    jnz     .wfg_have_cluster
    push    rsi
    call    AllocateFATCluster
    pop     rsi
    jc      .wfg_err
    mov     edx, eax
    mov     word [rsi + 0x1A], dx
    shr     edx, 16
    mov     word [rsi + 0x14], dx
.wfg_have_cluster:
    movzx   eax, word [rsi + 0x14]
    shl     eax, 16
    mov     ax,  word [rsi + 0x1A]   ; EAX = стартовий кластер
    
    ; --- Оновлюємо розмір у директорії ---
    mov     dword [rsi + 0x1C], ebx  ; розмір файлу
    push    rax                       ; зберігаємо стартовий кластер
    mov     eax, [TempSector]
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    pop     rax                       ; відновлюємо стартовий кластер
    jc      .wfg_err

    ; --- Крок 3: Пишемо дані посекторно ---
    mov     r10, r9         ; r10 = поточний вказівник у буфері
    mov     r11, rbx        ; r11 = залишилося байт
    mov     r12d, eax       ; r12d = поточний кластер

.wfg_write_sector:
    test    r11, r11
    jle     .wfg_ok

    ; Обчислюємо LBA кластера
    mov     eax, r12d
    sub     eax, 2
    movzx   ecx, byte [SectorsPerCluster]
    imul    eax, ecx
    add     eax, [DataRegionLBA]

    ; Копіюємо до 512 байт у SectorBuffer
    lea     rdi, [SectorBuffer]
    cmp     r11, 512
    jge     .wfg_full
    ; Частковий сектор: спочатку заповнюємо нулями
    push    rcx
    mov     rcx, 512
    xor     al, al
    cld
    rep     stosb
    pop     rcx
    lea     rdi, [SectorBuffer]
    mov     rcx, r11
    jmp     .wfg_copy
.wfg_full:
    mov     rcx, 512
.wfg_copy:
    push    rdi
    push    rsi
    mov     rsi, r10
    cld
    rep     movsb
    pop     rsi
    pop     rdi

    push    r10
    push    r11
    push    r12
    lea     rdi, [SectorBuffer]
    call    WriteSectorATA
    pop     r12
    pop     r11
    pop     r10
    jc      .wfg_err

    add     r10, 512
    sub     r11, 512

    ; Якщо ще є дані — алоцюємо наступний кластер і зв'язуємо ланцюг
    test    r11, r11
    jle     .wfg_ok

    push    r10
    push    r11
    push    r12
    call    AllocateFATCluster      ; новий кластер у EAX
    pop     r12
    pop     r11
    pop     r10
    jc      .wfg_err

    ; Зв'язуємо r12d → eax у FAT
    push    rax
    push    r10
    push    r11
    mov     eax, [FAT1LBA]
    lea     rdi, [FileBuffer]
    call    ReadSectorATA
    pop     r11
    pop     r10
    pop     rax

    ; Записуємо посилання: FAT[r12d] = новий_кластер
    ; (спрощено: перший сектор FAT, якщо кластер < 128)
    lea     rdi, [FileBuffer]
    mov     ecx, r12d
    lea     rdi, [rdi + rcx*4]
    mov     dword [rdi], eax        ; посилання на наступний кластер
    mov     r12d, eax               ; переходимо до нового кластера

    push    rax
    push    r10
    push    r11
    push    r12
    mov     eax, [FAT1LBA]
    lea     rdi, [FileBuffer]
    call    WriteSectorATA
    pop     r12
    pop     r11
    pop     r10
    pop     rax
    jc      .wfg_err
    jmp     .wfg_write_sector

.wfg_ok:
    clc
.wfg_exit:
    pop     r12
    pop     r11
    pop     r10
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ==========================================================
; 6. АПАРАТНИЙ РІВЕНЬ ДИСКА (ATA PIO)
; ==========================================================
ReadSectorATA:
    push    rdx
    push    rcx
    push    rbx
    push    rax
    mov     ebx, eax
    mov     edx, 0x1F6
    shr     eax, 24
    or      al, 0xE0            
    out     dx, al
    mov     edx, 0x1F2
    mov     al, 1                
    out     dx, al
    mov     edx, 0x1F3
    mov     eax, ebx            
    out     dx, al
    mov     edx, 0x1F4
    mov     eax, ebx            
    shr     eax, 8
    out     dx, al
    mov     edx, 0x1F5
    mov     eax, ebx            
    shr     eax, 16
    out     dx, al
    mov     edx, 0x1F7
    mov     al, 0x20
    out     dx, al
.wait_ready:
    in      al, dx
    test    al, 8                
    jz      .wait_ready
    mov     edx, 0x1F0
    mov     rcx, 256
    cld
    rep insw                    
    pop     rax
    pop     rbx
    pop     rcx
    pop     rdx
    ret

WriteSectorATA:
    push    rdx
    push    rcx
    push    rbx
    push    rax
    mov     ebx, eax
    mov     edx, 0x1F6
    shr     eax, 24
    or      al, 0xE0
    out     dx, al
    mov     edx, 0x1F2
    mov     al, 1
    out     dx, al
    mov     edx, 0x1F3
    mov     eax, ebx
    out     dx, al
    mov     edx, 0x1F4
    mov     eax, ebx
    shr     eax, 8
    out     dx, al
    mov     edx, 0x1F5
    mov     eax, ebx
    shr     eax, 16
    out     dx, al
    mov     edx, 0x1F7
    mov     al, 0x30
    out     dx, al
.wait_bsy:
    in      al, dx
    test    al, 0x80            
    jnz     .wait_bsy
.wait_drq:
    in      al, dx
    test    al, 0x01            
    jnz     .disk_error
    test    al, 0x08            
    jz      .wait_drq
    mov     edx, 0x1F0
    mov     rcx, 256
    mov     rsi, rdi            
    cld
    rep outsw
    mov     edx, 0x1F7
    mov     al, 0xE7            
    out     dx, al
.wait_flush:
    in      al, dx
    test    al, 0x80
    jnz     .wait_flush
    clc                         
    jmp     .exit_w
.disk_error:
    stc                         
.exit_w:
    pop     rax
    pop     rbx
    pop     rcx
    pop     rdx
    ret

; ==========================================================
; 7. ГРАФІКА ТА ВІДЕОПАМ'ЯТЬ
; ==========================================================
DrawTaskbar:
    mov     rdi, [ScreenBase]            
    movsxd  rax, dword [ScreenWidth]    
    imul    rax, 80                     
    mov     rcx, rax                    
    mov     eax, 0x00202020             ; Темно-сірий колір панелі
    cld
    rep     stosd                       
    ret

ScrollScreen:
    push    rdi
    push    rsi
    push    rax
    push    rcx
    push    rdx
    push    r10
    mov     rdi, [ScreenBase]            
    movsxd  r10, dword [ScreenWidth]
    imul    r10, 20                     
    mov     rsi, rdi
    lea     rsi, [rsi + r10 * 4]        
    movsxd  rcx, dword [ScreenHeight]
    sub     rcx, 20                     
    movsxd  rax, dword [ScreenWidth]    
    imul    rcx, rax                    
    cld
    rep     movsd                       
    mov     rcx, r10                    
    xor     eax, eax                    
    rep     stosd                       
    pop     r10
    pop     rdx
    pop     rcx
    pop     rax
    pop     rsi
    pop     rdi
    ret

ClearScreen:
    mov     rdi, [ScreenBase]
    movsxd  rcx, dword [ScreenWidth]
    movsxd  rdx, dword [ScreenHeight]
    imul    rcx, rdx
    xor     eax, eax            
    cld                         
    rep     stosd
    ret

DrawString:
    push    rsi
    push    rax
    push    rbx
    push    r10
    mov     rsi, r8              
.next_char:
    lodsb                       
    test    al, al
    jz      .str_done            
    
    cmp     al, 10              
    je      .do_newline
    cmp     al, 13              
    je      .next_char          
    
    movzx   r8, al
    push    rcx
    push    rdx
    push    r9
    call    DrawChar_Safe        
    pop     r9
    pop     rdx
    pop     rcx
    add     rcx, 9              
    
    movsxd  r10, dword [ScreenWidth]
    sub     r10, 20
    cmp     rcx, r10
    jge     .do_newline
    jmp     .next_char

.do_newline:
    mov     rcx, 20             
    add     rdx, 20             
    
    movsxd  r10, dword [ScreenHeight]
    sub     r10, 20
    cmp     rdx, r10
    jl      .next_char          
    
    push    rcx
    push    rdx
    call    ScrollScreen        
    pop     rdx
    pop     rcx
    sub     rdx, 20             
    jmp     .next_char

.str_done:
    pop     r10
    pop     rbx
    pop     rax
    pop     rsi
    ret                         

DrawChar_Safe:
    push    rdi
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rax
    mov     rax, r8                     

    cmp     al, 'a'
    jb      .check_limit
    cmp     al, 'z'
    ja      .check_limit
    sub     al, 32
    
.check_limit:
    cmp     al, 32
    jl      .draw_space
    cmp     al, 93
    jg      .draw_space
    jmp     .calc_offset
    
.draw_space:
    mov     al, 32

.calc_offset:
    movzx   rbx, al
    sub     rbx, 32                     
    imul    rbx, 8                      
    lea     rsi, [FontData + rbx + 7]   
    mov     rax, rdx
    movsxd  r10, dword [ScreenWidth]
    imul    rax, r10
    add     rax, rcx
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    mov     rcx, 8                      
.ln:
    mov     al, [rsi]
    dec     rsi
    push    rcx
    mov     rcx, 8                      
.px:
    shl     al, 1                       
    jnc     .sk
    mov     [rdi], r9d                  
.sk:
    add     rdi, 4                      
    dec     rcx
    jnz     .px
    pop     rcx
    movsxd  r10, dword [ScreenWidth]    
    shl     r10, 2
    sub     r10, 32
    add     rdi, r10
    dec     rcx
    jnz     .ln
    pop     rax
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rdi
    ret

EraseChar:  
    push    rdi
    push    rcx
    push    rdx
    push    rax
    mov     rax, rdx
    movsxd  r10, dword [ScreenWidth]
    imul    rax, r10
    add     rax, rcx
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    xor     eax, eax        
    mov     rcx, 8
.el:
    push    rcx
    mov     rcx, 8
.ep:
    mov     [rdi], eax
    add     rdi, 4
    dec     rcx
    jnz     .ep
    pop     rcx
    movsxd  r10, dword [ScreenWidth]
    shl     r10, 2
    sub     r10, 32
    add     rdi, r10
    dec     rcx
    jnz     .el
    pop     rax
    pop     rdx
    pop     rcx
    pop     rdi
    ret

DrawCursor:
    push    rdi
    push    rax
    push    rcx
    push    rdx
    push    r10
    mov     rax, [CursorY]
    movsxd  r10, dword [ScreenWidth]
    imul    rax, r10
    add     rax, [CursorX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    movsxd  r10, dword [ScreenWidth]
    imul    r10, 7
    shl     r10, 2
    add     rdi, r10
    mov     eax, 0x00AAAAAA     
    mov     rcx, 8              
    cld
    rep     stosd
    pop     r10
    pop     rdx
    pop     rcx
    pop     rax
    pop     rdi
    ret

EraseCursor:
    push    rdi
    push    rax
    push    rcx
    push    rdx
    push    r10
    mov     rax, [CursorY]
    movsxd  r10, dword [ScreenWidth]
    imul    rax, r10
    add     rax, [CursorX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    movsxd  r10, dword [ScreenWidth]
    imul    r10, 7
    shl     r10, 2
    add     rdi, r10
    xor     eax, eax            
    mov     rcx, 8
    cld
    rep     stosd
    pop     r10
    pop     rdx
    pop     rcx
    pop     rax
    pop     rdi
    ret

; --- ВІДНОВЛЕННЯ СТАРОГО ФОНУ ПІД МИШЕЮ ---
RestoreMouseCursor:
    cmp     byte [MouseDrawn], 0
    je      .skip                   ; Якщо ще не малювали - нічого не відновлюємо
    push    rax rbx rcx rdx rdi rsi r8 r9
    mov     eax, [OldMouseY]
    movsxd  rbx, dword [ScreenWidth]
    imul    rax, rbx
    add     eax, [OldMouseX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax                ; Куди пишемо (екран)
    lea     rsi, [MouseBg]          ; Звідки беремо (наш буфер)
    mov     r8, 5                   ; Висота 5
.row:
    mov     rcx, 5                  ; Ширина 5
    push    rdi
    cld
    rep     movsd
    pop     rdi
    movsxd  rbx, dword [ScreenWidth]
    shl     rbx, 2
    add     rdi, rbx
    dec     r8
    jnz     .row
    pop     r9 r8 rsi rdi rdx rcx rbx rax
.skip:
    ret

; --- ЗБЕРЕЖЕННЯ НОВОГО ФОНУ ПІД МИШЕЮ ---
SaveMouseCursor:
    push    rax rbx rcx rdx rdi rsi r8 r9
    mov     byte [MouseDrawn], 1    ; Ставимо прапорець
    mov     eax, [MouseY]
    mov     [OldMouseY], eax        ; Запам'ятовуємо, де ми зараз
    mov     eax, [MouseX]
    mov     [OldMouseX], eax

    mov     eax, [MouseY]
    movsxd  rbx, dword [ScreenWidth]
    imul    rax, rbx
    add     eax, [MouseX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rsi, rax                ; Звідки беремо (екран)
    lea     rdi, [MouseBg]          ; Куди пишемо (буфер)
    mov     r8, 5
.row_s:
    mov     rcx, 5
    push    rsi
    cld
    rep     movsd
    pop     rsi
    movsxd  rbx, dword [ScreenWidth]
    shl     rbx, 2
    add     rsi, rbx
    dec     r8
    jnz     .row_s
    pop     r9 r8 rsi rdi rdx rcx rbx rax
    ret

; --- МАЛЮВАННЯ САМОГО КУРСОРУ (Червоний квадрат 5х5) ---
DrawMouseCursor:
    push    rax rbx rcx rdx rdi r8 r9 r10
    mov     eax, [MouseY]
    movsxd  rbx, dword [ScreenWidth]
    imul    rax, rbx
    add     eax, [MouseX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    mov     r10d, 0x00FF0000        ; Колір курсору (Червоний)
    mov     r8, 5
.row_d:
    mov     rcx, 5
    push    rdi
    mov     eax, r10d
    cld
    rep     stosd
    pop     rdi
    movsxd  rbx, dword [ScreenWidth]
    shl     rbx, 2
    add     rdi, rbx
    dec     r8
    jnz     .row_d
    pop     r10 r9 r8 rdi rdx rcx rbx rax
    ret
; ==========================================================
; 14. ГРАФІЧНА ОБОЛОНКА (GUI ВІКНА)
; ==========================================================

; Малює зафарбований прямокутник
; Виклик: RCX=X, RDX=Y, R8=Ширина, R9=Висота, R10d=Колір
DrawRect:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    
    ; Обчислюємо початкову адресу: ScreenBase + (Y * ScreenWidth + X) * 4
    mov     rax, rdx
    movsxd  rbx, dword [ScreenWidth]
    imul    rax, rbx
    add     rax, rcx
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax

    mov     eax, r10d           ; Колір
    mov     r11, r8             ; Зберігаємо ширину

.row_loop:
    test    r9, r9
    jz      .done
    
    mov     rcx, r11            ; Кількість пікселів у рядку
    push    rdi
    cld
    rep     stosd               ; Малюємо 1 лінію
    pop     rdi
    
    ; Переходимо рівно на один рядок екрана вниз
    movsxd  rbx, dword [ScreenWidth]
    shl     rbx, 2
    add     rdi, rbx            
    
    dec     r9
    jmp     .row_loop

.done:
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; Малює вікно у стилі Windows 95
; Виклик: RCX=X, RDX=Y, R8=Ширина, R9=Висота
DrawWindow:
    push    rcx
    push    rdx
    push    r8
    push    r9
    push    r10
    
    ; 1. Основний фон вікна (Світло-сірий)
    mov     r10d, 0x00C0C0C0
    call    DrawRect

    ; 2. Заголовок вікна (Синій) - висота 24 пікселі
    push    r9
    mov     r9, 24
    mov     r10d, 0x000000AA
    call    DrawRect
    pop     r9

    ; 3. Малюємо рамки вікна (Чорні, товщина 2 пікселі)
    ; Верхня лінія
    push    r9
    mov     r9, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r9
    
    ; Нижня лінія
    push    rcx
    push    rdx
    push    r9
    add     rdx, r9
    sub     rdx, 2          
    mov     r9, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r9
    pop     rdx
    pop     rcx

    ; Ліва лінія
    push    r8
    mov     r8, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r8
    
    ; Права лінія
    push    rcx
    push    r8
    add     rcx, r8
    sub     rcx, 2
    mov     r8, 2
    mov     r10d, 0x00000000
    call    DrawRect
    pop     r8
    pop     rcx

    pop     r10
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    ret

; ==========================================================
; 8. МЕДІА РУШІЇ (ВІДЕО ТА ФОТО)
; ==========================================================
RunBadApplePlayer:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    
    mov     rcx, VideoMemoryBase
    mov     eax, [LoadedFileSize]
    add     rcx, rax
    mov     [VideoEOFPtr], rcx

    mov     qword [VideoDataPtr], VideoMemoryBase
    mov     dword [RLE_Count], 0
    mov     dword [FramesRendered], 0

    mov     eax, [ScreenWidth]
    sub     eax, 320
    shr     eax, 1
    mov     [StartX], eax

    mov     eax, [ScreenHeight]
    sub     eax, 240
    shr     eax, 1
    mov     [StartY], eax

    call    ClearScreen

.playback_loop:
    in      al, 0x64
    test    al, 1
    jz      .no_key
    in      al, 0x60
    cmp     al, 0x01                
    je      .exit_ok
.no_key:
    mov     rax, [VideoDataPtr]
    cmp     rax, [VideoEOFPtr]
    jae     .exit_ok

    call    StartFrameTimer         
    call    DecodeFrameToBackBuffer 
    call    BlitBackBufferToScreen  
    call    WaitFrameTimer          

    inc     dword [FramesRendered]
    jmp     .playback_loop
.exit_ok:
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

DecodeFrameToBackBuffer:
    push    rax
    push    rcx
    push    rdi
    push    rsi
    mov     rdi, BackBufferBase
    mov     rcx, 320 * 240     
.px_loop:
    cmp     dword [RLE_Count], 0
    ja      .draw_px
    mov     rsi, [VideoDataPtr]
    lodsb
    test    al, al
    jz      .black_px
    mov     eax, 0x00FFFFFF    
    jmp     .save_color
.black_px:
    mov     eax, 0x00000000    
.save_color:
    mov     [RLE_Color], eax
    lodsd
    mov     [RLE_Count], eax
    mov     [VideoDataPtr], rsi
.draw_px:
    mov     eax, [RLE_Color]
    stosd
    dec     dword [RLE_Count]
    dec     rcx
    jnz     .px_loop
    pop     rsi
    pop     rdi
    pop     rcx
    pop     rax
    ret

BlitBackBufferToScreen:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    rsi
    push    r10
    mov     rsi, BackBufferBase
    mov     r10, 240            
    mov     ecx, dword [StartY]     
.line_loop:
    mov     rax, rcx
    movsxd  rdx, dword [ScreenWidth]
    imul    rax, rdx
    add     eax, [StartX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax
    push    rcx
    mov     rcx, 160            
    cld
    rep     movsq
    pop     rcx
    inc     rcx                
    dec     r10
    jnz     .line_loop
    pop     r10
    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

StartFrameTimer:
    push    rax
    mov     rax, [SystemTicks]
    add     rax, 41                 
    mov     [FrameTargetTick], rax
    pop     rax
    ret

WaitFrameTimer:
    push    rax
.wait:
    mov     rax, [SystemTicks]
    cmp     rax, [FrameTargetTick]
    jl      .wait                   
    pop     rax
    ret

FrameTargetTick dq 0                

DrawBMP:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r10
    push    r11
    push    r12
    cmp     word [r9], 0x4D42
    jne     .err
    cmp     word [r9 + 0x1C], 24
    jne     .err
    mov     r10d, dword [r9 + 0x12]     
    mov     r11d, dword [r9 + 0x16]     
    mov     eax, dword [r9 + 0x0A]      
    lea     rsi, [r9 + rax]             
    mov     eax, r10d
    imul    eax, 3                      
    mov     ebx, eax
    add     eax, 3
    and     eax, 0xFFFFFFFC             
    sub     eax, ebx                    
    mov     r12d, eax                   
    mov     eax, [ScreenWidth]
    sub     eax, r10d                   
    shr     eax, 1
    mov     [StartX], eax
    mov     eax, [ScreenHeight]
    sub     eax, r11d                   
    shr     eax, 1
    mov     [StartY], eax
    call    ClearScreen
    mov     r8d, r11d
    dec     r8d                         
.row_loop:
    mov     eax, [StartY]
    add     eax, r8d
    movsxd  rdx, dword [ScreenWidth]
    imul    rax, rdx
    add     eax, [StartX]
    shl     rax, 2
    add     rax, [ScreenBase]
    mov     rdi, rax                    
    mov     rcx, r10                    
.pixel_loop:
    movzx   eax, byte [rsi]             
    movzx   ebx, byte [rsi+1]           
    shl     ebx, 8
    or      eax, ebx
    movzx   ebx, byte [rsi+2]           
    shl     ebx, 16
    or      eax, ebx
    stosd                               
    add     rsi, 3                      
    dec     rcx
    jnz     .pixel_loop
    add     rsi, r12
    dec     r8d
    js      .done                       
    jmp     .row_loop
.done:
    clc                                 
    pop     r12
    pop     r11
    pop     r10
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret
.err:
    stc                                 
    pop     r12
    pop     r11
    pop     r10
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    ret

; ==========================================================
; 9. ДАНІ ТА ЗМІННІ ЯДРА
; ==========================================================
ScreenBase      dq 0
ScreenWidth     dd 0
ScreenHeight    dd 0
CursorX         dq 0
CursorY         dq 0

CmdBuffer       rb 64            
BufferLen       dq 0

; Список команд
CmdWin          db 'WIN', 0
CmdHelp         db 'HELP', 0
CmdInfo         db 'INFO', 0
CmdReboot       db 'REBOOT', 0
CmdCLS          db 'CLS', 0
CmdLS           db 'LS', 0
CmdCD           db 'CD ', 0
CmdOpen         db 'OPEN ', 0
CmdEdit         db 'EDIT ', 0
CmdCreate       db 'CREATE ', 0
CmdRM           db 'RM ', 0
CmdTime         db 'TIME', 0
CmdBeep         db 'BEEP', 0
CmdMkdir        db 'MKDIR ', 0          
CmdBack         db 'BACK', 0
CmdRun          db 'RUN ', 0        

; Тексти і повідомлення
MsgName         db 'EUGENE OS V2.0 (VFS ENABLED)', 0
MsgHelpList     db 'COMMANDS: HELP, CLS, REBOOT, LS, CD <dir>, OPEN <f>, EDIT <f>, CREATE <f>, RM <f>, MKDIR <d>, RUN <app>, WIN, INFO, TIME, BEEP', 0
MsgWinTitle     db 'System Status', 0
MsgWinBody      db 'GUI Window System works!', 0
MsgCPU          db 'CPU DETECTED:', 0
CurrentPath     db 'SYS:\', 0
                times 250 db 0      
MsgUnknown      db 'UNKNOWN COMMAND', 0
MsgLS           db 'FILES IN CURRENT DIRECTORY:', 0
MsgCreated      db 'FILE CREATED: ', 0
MsgDirCreated   db 'DIRECTORY CREATED: ', 0
MsgDeleted      db 'FILE DELETED', 0
MsgTime         db 'RTC TIME: ', 0
TimeStr         db '00:00:00', 0
MsgWriteErr     db 'DISK WRITE ERROR (READ-ONLY?)', 0
MsgReadErr      db 'FILE OR DIRECTORY NOT FOUND', 0
MsgNotDir       db 'ERROR: NOT A DIRECTORY', 0
MsgUnknownExt   db 'ERROR: NO APP ASSIGNED FOR THIS EXTENSION', 0
MsgAudio        db 'AUDIO PLAYBACK STUB (PC SPEAKER)', 0
MsgVideoDone    db 'PLAYBACK FINISHED', 0
DirTag          db '<DIR>', 0
MsgEditor       db '=== EUGENE OS EDITOR | F2: SAVE | ESC: EXIT ===', 0
MsgSaved        db '[ SAVED ]', 0
MsgErrFat       db '[ FAT ERROR ]', 0
MsgRun          db 'LAUNCHING EXTERNAL APP...', 0
AppRunning      db 0            
; --- Клавіатурний FIFO буфер (для Doom) ---
KbdBuffer       rb 256
KbdHead         db 0
KbdTail         db 0

; --- Змінні PS/2 Миші ---
MouseState      db 0
MousePacket     rb 3
MouseX          dd 400
MouseY          dd 300   
; --- Змінні для відмальовки курсору ---
OldMouseX    dd 400
OldMouseY    dd 300
MouseDrawn   db 0        ; Прапорець: чи малювали ми вже курсор
MouseBg      rd 25       ; Буфер на 25 пікселів (5x5) для збереження фону 

MouseClick      db 0    ; 0 - не натиснуто, 1 - лівий клік, 2 - правий

SectorBuffer    rb 512          
FATSectorBuffer rb 512          
FileBuffer      rb 512          
FileNameBuf     rb 12           
ParsedFileName  rb 12           

VolumeStartLBA  dd 0
DataRegionLBA   dd 0
SectorsPerCluster db 0
FAT1LBA         dd 0
RootCluster     dd 0
CurrentDirCluster dd 2          
TempSector      dd 0

; --- СИСТЕМА ПЕРЕРИВАНЬ ТА БАГАТОЗАДАЧНОСТІ ---
align 8
IDT:
    times 256 dq 0, 0           
IDTR:
    dw 256 * 16 - 1             
    dq 0                        

SystemTicks     dq 0            
CodeSegment     dw 0            

MAX_TASKS       equ 2
align 8
TaskRSP         dq 0, 0                 
CurrentTask     dq 0                    

; --- СТЕК ІСТОРІЇ ПАПОК ---
DirHistoryIndex   dd 0                  
DirHistoryStack:  times 64 dd 0         
MsgNoHistory      db 'NO HISTORY TO GO BACK', 0

LoadedFileSize  dd 0            

RLE_Color       dd 0
RLE_Count       dd 0
VideoDataPtr    dq 0
VideoEOFPtr     dq 0
StartX          dd 0
StartY          dd 0
FramesRendered  dd 0

VendorID        db '            ', 0  

EditorBuffer    rb 512
EditorCursor    dq 0

; ==========================================================
; 11. ПЛАНУВАЛЬНИК ТА ПЕРЕРИВАННЯ (SCHEDULER & IDT)
; ==========================================================
InitInterrupts:
    mov     ax, cs
    mov     [CodeSegment], ax

    lea     rax, [IDT]
    mov     qword [IDTR + 2], rax

    mov     rcx, 0                  
    lea     rsi, [ExceptionVectors] 
.register_exceptions:
    mov     rdx, [rsi + rcx*8]      
    call    SetIDTGate              
    inc     rcx
    cmp     rcx, 32                 
    jl      .register_exceptions

    mov     rcx, 32
    lea     rdx, [TimerHandler]
    call    SetIDTGate

    mov     rcx, 128
    lea     rdx, [SyscallHandler]
    call    SetIDTGate

    lidt    [IDTR]

    mov     al, 0x11
    out     0x20, al
    out     0xA0, al
    mov     al, 0x20            
    out     0x21, al
    mov     al, 0x28            
    out     0xA1, al
    mov     al, 4
    out     0x21, al
    mov     al, 2
    out     0xA1, al
    mov     al, 1
    out     0x21, al
    out     0xA1, al

    mov     al, 11111110b       
    out     0x21, al
    mov     al, 11111111b
    out     0xA1, al

    mov     al, 00110100b       
    out     0x43, al
    mov     ax, 1193            
    out     0x40, al
    mov     al, ah
    out     0x40, al

    sti                         
    ret

SetIDTGate:
    push    rax
    push    rbx
    shl     rcx, 4              
    lea     rbx, [IDT + rcx]
    
    mov     rax, rdx
    mov     word [rbx], ax      
    
    mov     ax, [CodeSegment]
    mov     word [rbx + 2], ax  
    
    mov     word [rbx + 4], 0x8E00 
    
    shr     rdx, 16
    mov     word [rbx + 6], dx  
    
    shr     rdx, 16
    mov     dword [rbx + 8], edx 
    mov     dword [rbx + 12], 0  
    
    pop     rbx
    pop     rax
    ret

align 16
TimerHandler:
    push    rax
    push    rbx
    push    rcx
    push    rdx
    push    rbp
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rax, [CurrentTask]
    mov     [TaskRSP + rax*8], rsp

    inc     qword [SystemTicks]
    mov     rax, [SystemTicks]
    and     rax, 0x100
    jz      .draw_black
    mov     eax, 0x00FF0000
    jmp     .draw_dot
.draw_black:
    mov     eax, 0x00000000
.draw_dot:
    mov     rdi, [ScreenBase]
    stosd

    mov     al, 0x20
    out     0x20, al

    mov     rax, [CurrentTask]
    inc     rax                     
    cmp     rax, MAX_TASKS          
    jl      .check_task
    xor     rax, rax                
    jmp     .set_task
.check_task:
    cmp     byte [AppRunning], 1
    je      .set_task
    xor     rax, rax                
.set_task:
    mov     [CurrentTask], rax    

    mov     rsp, [TaskRSP + rax*8]

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax

    iretq                           

align 16
SyscallHandler:
    cmp     rax, 0                  
    je      .sys_exit

    push    rcx
    push    rdx
    push    rbx
    push    rbp
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15

    cmp     rax, 1                  
    je      .sys_getkey
    cmp     rax, 2
    je      .sys_print 
    cmp     rax, 4                  
    je      .sys_clear              
    cmp     rax, 5                  
    je      .sys_readfile           
    cmp     rax, 6                  
    je      .sys_putchar
    cmp     rax, 7                  
    je      .sys_erasechar
    cmp     rax, 8                  
    je      .sys_ls                 
    cmp     rax, 9                  
    je      .sys_blit               
    cmp     rax, 10                 
    je      .sys_getticks
    cmp     rax, 10                 
    je      .sys_getticks           
    cmp     rax, 11                 ; НОВИЙ ВИКЛИК: Отримати мишу
    je      .sys_getmouse           
    cmp     rax, 12
    je      .sys_get_time
    cmp     rax, 13
    je      .sys_get_file_list
    cmp     rax, 14
    je      .sys_writefile

    jmp     .syscall_end        

.sys_getkey:
    mov     al, [KbdTail]
    cmp     al, [KbdHead]       ; Чи є нові дані в буфері?
    je      .no_key
    movzx   ebx, al
    movzx   rax, byte [KbdBuffer + ebx] ; Читаємо найстаріший байт
    inc     bl                  ; Зсуваємо хвіст черги
    mov     [KbdTail], bl
    jmp     .syscall_end
.no_key:
    xor     rax, rax            ; Повертаємо 0, якщо клавіш не було
    jmp     .syscall_end

.sys_print:
    mov     rcx, [CursorX]      
    mov     rdx, [CursorY]      
    mov     r8,  rsi            
    call    DrawString          
    mov     [CursorX], rcx      
    mov     [CursorY], rdx      
    jmp     .syscall_end        
    
.sys_clear:                         
    call    ClearScreen
    mov     qword [CursorX], 20     
    mov     qword [CursorY], 40
    jmp     .syscall_end    

.sys_readfile:
    push    r9                          
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name             
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    jc      .read_fail_pop
    test    dl, 0x10
    jnz     .read_fail_pop
    pop     r9                          
    call    LoadFAT32Chain
    mov     rax, rbx
    jmp     .syscall_end

.read_fail_pop:
    pop     r9
    xor     rax, rax
    jmp     .syscall_end

.sys_putchar:
    cmp     rsi, 10             
    je      .putchar_newline
    cmp     rsi, 13             
    je      .syscall_end

    mov     rcx, [CursorX]
    mov     rdx, [CursorY]
    mov     r8, rsi              
    call    DrawChar_Safe        
    add     qword [CursorX], 9  
    jmp     .syscall_end
.putchar_newline:
    call    NewLine
    jmp     .syscall_end

.sys_erasechar:
    mov     rcx, [CursorX]
    cmp     rcx, 20             
    jle     .syscall_end
    
    sub     rcx, 9              
    mov     [CursorX], rcx
    mov     rdx, [CursorY]
    call    EraseChar           
    jmp     .syscall_end
    
.sys_ls:
    call    ListFilesFAT32          
    jmp     .syscall_end

.sys_blit:
    mov     r8, [rsi+0]          
    mov     r9d, dword [rsi+8]  
    mov     r10d, dword [rsi+12]
    mov     r11d, dword [rsi+16]
    mov     r12d, dword [rsi+20]
    
    test    r11d, r11d
    jle     .syscall_end
    test    r12d, r12d
    jle     .syscall_end

    mov     r13d, 0              
.blit_row:
    cmp     r13d, r12d
    jge     .syscall_end        

    mov     eax, r10d
    add     eax, r13d
    cmp     eax, [ScreenHeight] 
    jge     .skip_row           

    movsxd  rax, eax
    movsxd  rbx, dword [ScreenWidth]
    imul    rax, rbx
    movsxd  rbx, r9d
    add     rax, rbx
    shl     rax, 2              
    add     rax, [ScreenBase]
    mov     rdi, rax            

    movsxd  rax, r13d
    movsxd  rbx, r11d
    imul    rax, rbx
    shl     rax, 2
    add     rax, r8
    mov     rsi, rax            

    movsxd  rcx, r11d            
    cld
    rep     movsd                

.skip_row:
    inc     r13d
    jmp     .blit_row

.sys_getticks:
    mov     rax, [SystemTicks]      
    jmp     .syscall_end            

.sys_getmouse:
    xor     rax, rax
    mov     al, byte [MouseClick]
    shl     rax, 16
    mov     ax, word [MouseY]
    shl     rax, 16
    mov     ax, word [MouseX]
    jmp     .syscall_end

.sys_get_time:
    ; Читаємо Хвилини (регістр 0x02)
    mov al, 0x02
    out 0x70, al
    in al, 0x71
    mov cl, al      ; Тимчасово кладемо хвилини в CL

    ; Читаємо Години (регістр 0x04)
    mov al, 0x04
    out 0x70, al
    in al, 0x71
    mov ch, al      ; Години в CH

    ; Формуємо результат у RAX
    xor rax, rax    ; Очищаємо RAX від сміття!
    mov ah, ch
    mov al, cl
    
    jmp .syscall_end ; ПРАВИЛЬНИЙ ВИХІД З СИСКОЛУ!

    .sys_get_file_list:
    ; RCX = адреса буфера з C-коду (куди писати імена)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rdi, rsi            ; RDI тепер вказує на наш C-буфер

    ; 1. Завантажуємо директорію в DirBuffer (використовуємо твою функцію!)
    mov eax, [CurrentDirCluster]
    mov r9, DirBuffer       
    call LoadFAT32Chain

    ; 2. Починаємо парсити DirBuffer
    mov rsi, DirBuffer      
.parse_dir:
    mov al, [rsi]
    test al, al             ; 0x00 = кінець директорії
    jz .done_dir
    cmp al, 0xE5            ; 0xE5 = видалений файл
    je .next_dir_entry

    mov dl, [rsi + 0x0B]    ; Читаємо атрибути
    cmp dl, 0x0F            ; Пропускаємо довгі імена (LFN)
    je .next_dir_entry
    test dl, 0x08           ; Пропускаємо мітку тому (Volume Label)
    jnz .next_dir_entry

    ; 3. Копіюємо 11 символів імені (8 ім'я + 3 розширення) у C-буфер
    push rsi
    mov rcx, 11
.copy_name:
    mov al, [rsi]
    mov [rdi], al           ; Пишемо букву в буфер
    inc rdi
    inc rsi
    dec rcx
    jnz .copy_name
    pop rsi

    ; 4. Якщо це папка, додаємо слеш '/' для краси
    test byte [rsi + 0x0B], 0x10
    jz .is_file
    mov byte [rdi], '/'
    inc rdi
.is_file:

    ; 5. Додаємо символ нового рядка '\n' (щоб розділяти файли)
    mov byte [rdi], 10      ; 10 = ASCII код для \n
    inc rdi

.next_dir_entry:
    add rsi, 32             ; Переходимо до наступного 32-байтного запису FAT32
    jmp .parse_dir

.done_dir:
    mov byte [rdi], 0       ; Нуль-термінатор, щоб C-код зрозумів, де кінець тексту

    ; Відновлюємо регістри
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    xor rax, rax            ; Очищаємо RAX від сміття
    jmp .syscall_end        ; Правильний вихід з сисколу!

.sys_writefile:
    ; RSI = вказівник на ім'я файлу (звичайний рядок, форматується тут)
    ; RDI = вказівник на буфер даних
    ; RDX = розмір у байтах
    push    rdi
    push    rdx
    lea     rdi, [ParsedFileName]
    call    FormatFAT32Name         ; форматуємо ім'я з RSI → ParsedFileName
    pop     rdx
    pop     rdi

    ; Якщо файл не існує — спочатку створюємо
    push    rdi
    push    rdx
    lea     r8, [ParsedFileName]
    call    FindFAT32Entry
    pop     rdx
    pop     rdi
    jnc     .wf_exists
    ; Файл не знайдено — створюємо
    push    rdi
    push    rdx
    lea     r8, [ParsedFileName]
    call    CreateFileFAT32
    pop     rdx
    pop     rdi
    jc      .wf_fail

.wf_exists:
    lea     r8, [ParsedFileName]
    mov     r9, rdi                 ; буфер даних
    mov     rbx, rdx               ; розмір
    call    WriteFileFAT32Generic
    jc      .wf_fail
    mov     rax, rdx               ; повертаємо кількість записаних байт
    jmp     .syscall_end

.wf_fail:
    xor     rax, rax               ; 0 = помилка
    jmp     .syscall_end

.syscall_end:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rbx
    pop     rdx
    pop     rcx
    iretq                       

.sys_exit:
    cli                             
    mov     byte [AppRunning], 0    
    mov     qword [CurrentTask], 0  
    
    mov     rsp, [TaskRSP]          
    pop     r15                     
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    iretq

align 16
BackgroundTask:
    mov     rcx, 1000               
    mov     rdx, 10                 
    mov     r8, 'B'                 
    mov     r9d, 0x00FFFF00         
    call    DrawChar_Safe
    jmp     BackgroundTask          

InitTask1:
    push    rax
    push    rcx             

    mov     rax, Task1_StackTop 
    
    xor     rcx, rcx
    mov     cx, ss              
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], Task1_StackTop 
    
    sub     rax, 8
    mov     qword [rax], 0x202  
    
    xor     rcx, rcx
    mov     cx, cs              
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], BackgroundTask 

    mov     rcx, 15
.push_regs:
    sub     rax, 8
    mov     qword [rax], 0      
    loop    .push_regs

    mov     [TaskRSP + 8], rax  

    pop     rcx
    pop     rax             
    ret
    
SpawnAppTask:
    cli                         
    mov     byte [AppRunning], 1    
    mov     rax, AppStackTop 
    
    xor     rcx, rcx
    mov     cx, ss
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], AppStackTop 
    
    sub     rax, 8
    mov     qword [rax], 0x202  
    
    xor     rcx, rcx
    mov     cx, cs
    sub     rax, 8
    mov     qword [rax], rcx    
    
    sub     rax, 8
    mov     qword [rax], AppMemoryBase 

    mov     rcx, 15
.push_regs_app:
    sub     rax, 8
    mov     qword [rax], 0      
    loop    .push_regs_app

    mov     rdi, [ScreenBase]
    mov     [rax + 64], rdi      
    
    mov     rsi, 0
    mov     esi, [ScreenWidth]
    mov     [rax + 72], rsi      

    mov     [TaskRSP + 8], rax  
    
    sti                         
    ret

; ==========================================================
; ДАНІ ТА СТЕКИ
; ==========================================================

; === Виділяємо стек для фонової задачі в ядрі ===
align 16
Task1_Stack     rb 4096
Task1_StackTop:

; ==========================================================
; 12. ОБРОБНИКИ АПАРАТНИХ ВИНЯТКІВ (EXCEPTIONS 0-31)
; ==========================================================

macro isr_no_err vector {
    align 8
    isr_#vector:
        cli
        push    0           
        push    vector      
        jmp     isr_common_stub
}

macro isr_err vector {
    align 8
    isr_#vector:
        cli
        push    vector      
        jmp     isr_common_stub
}

isr_no_err 0   ; Divide by zero
isr_no_err 1   ; Debug
isr_no_err 2   ; NMI
isr_no_err 3   ; Breakpoint
isr_no_err 4   ; Overflow
isr_no_err 5   ; Bound Range Exceeded
isr_no_err 6   ; Invalid Opcode
isr_no_err 7   ; Device Not Available
isr_err    8   ; Double Fault 
isr_no_err 9   ; Coprocessor Segment Overrun
isr_err    10  ; Invalid TSS 
isr_err    11  ; Segment Not Present 
isr_err    12  ; Stack-Segment Fault 
isr_err    13  ; General Protection Fault 
isr_err    14  ; Page Fault 
isr_no_err 15  ; Reserved
isr_no_err 16  ; x87 Floating-Point Exception
isr_err    17  ; Alignment Check 
isr_no_err 18  ; Machine Check
isr_no_err 19  ; SIMD Floating-Point Exception
isr_no_err 20  ; Virtualization Exception
isr_err    21  ; Control Protection Exception 
isr_no_err 22
isr_no_err 23
isr_no_err 24
isr_no_err 25
isr_no_err 26
isr_no_err 27
isr_no_err 28
isr_no_err 29
isr_err    30  ; Security Exception 
isr_no_err 31

align 8
ExceptionVectors:
    dq isr_0, isr_1, isr_2, isr_3, isr_4, isr_5, isr_6, isr_7
    dq isr_8, isr_9, isr_10, isr_11, isr_12, isr_13, isr_14, isr_15
    dq isr_16, isr_17, isr_18, isr_19, isr_20, isr_21, isr_22, isr_23
    dq isr_24, isr_25, isr_26, isr_27, isr_28, isr_29, isr_30, isr_31

align 16
isr_common_stub:
    mov     rcx, 20
    mov     rdx, 20
    lea     r8,  [MsgCrash]
    mov     r9d, 0x000000FF     
    call    DrawString

    cmp     qword [CurrentTask], 0
    je      .kernel_panic       

.kill_app:
    mov     byte [AppRunning], 0
    mov     qword [CurrentTask], 0
    mov     rsp, [TaskRSP]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rdx
    pop     rcx
    pop     rbx
    pop     rax
    
    call    ClearScreen             
    call    DrawTaskbar             
    mov     qword [CursorX], 20     
    mov     qword [CursorY], 100
    call    PrintPrompt

    iretq                       

.kernel_panic:
    cli
    hlt
    jmp     .kernel_panic

MsgCrash db 'FATAL EXCEPTION: APP KILLED TO PROTECT KERNEL', 0

ScanCodes:
    db 0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, 9
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', 13, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', 39, '`', 0, '\'
    db 'Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/', 0, '*', 0, ' '
    times 100 db 0 

align 8
FontData:
    dq 0
    dq 0x1818181818001800, 0x2424240000000000, 0x24247E247E242400, 0x183C603C063C1800
    dq 0x66C6181830660000, 0x386C3876DC000000, 0x1818300000000000, 0x0C183030180C0000
    dq 0x30180C0C18300000, 0x00663CFF3C660000, 0x0018187E18180000, 0x0000000000181830
    dq 0x0000007E00000000, 0x0000000000181800, 0x006030180C060000
    dq 0x3C666666663C0000, 0x18381818183C0000, 0x3C660C18307E0000, 0x3C660C0C663C0000
    dq 0x0C1C3C6C7E0C0000, 0x7E603E06063C0000, 0x1C30603C663C0000, 0x7E060C1830300000
    dq 0x3C663C663C000000, 0x3C663C060C380000
    dq 0x0018180018180000, 0x0018180018183000, 0x060C1830180C0600, 0x00007E007E000000
    dq 0x6030180C18306000, 0x3C660C1800180000, 0x3C666E6E603E0000
    dq 0x183C66667E666600, 0x7E66667E66667E00, 0x3C66606060663C00, 0x7C66666666667C00
    dq 0x7E60607860607E00, 0x7E60607860606000, 0x3C66606E663C0000, 0x6666667E66666600
    dq 0x3C18181818183C00, 0x1E060606663C0000, 0x666C78786C660000, 0x6060606060607E00
    dq 0x63777F6B63630000, 0x66767F6E66660000, 0x3C666666663C0000
    dq 0x7E66667E60600000, 0x3C6666666C360000, 0x7E66667E6C660000, 0x3C603C06663C0000
    dq 0x7E18181818180000, 0x66666666663C0000, 0x666666663C180000, 0x63636B7F77630000
    dq 0x66663C183C660000, 0x66663C1818180000, 0x7E060C18307E0000
    dq 0x3C303030303C0000, 0x00060C1830600000, 0x3C0C0C0C0C3C0000