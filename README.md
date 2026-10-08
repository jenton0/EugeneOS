# EUGENE OS

**English** | [Українська](README.uk.md)

A 64-bit operating system for x86-64, written from scratch in assembly and C.
It boots through UEFI, reads and writes FAT32, has a Windows 3.1–style
graphical shell, its own TCP/IP stack, and it can **rebuild itself**: a port
of flat assembler runs inside the system and assembles its own kernel.

```
EUGENE OS  Version 2.0
(C) 2026 Eugene.  All rights reserved.

Type HELP for a list of commands.

C:\>_
```

## Contents

- [Features](#features)
- [Project layout](#project-layout)
- [Building and running](#building-and-running)
- [Kernel console commands](#kernel-console-commands)
- [Graphical shell](#graphical-shell)
- [Self-hosting](#self-hosting)
- [Known limitations](#known-limitations)
- [Further reading](#further-reading)

## Features

**Boot**
- Custom UEFI bootloader (`format PE64 EFI`) with a graphical setup screen
- Video mode selection through GOP, CPU / RAM / disk info, built-in benchmarks
- Proper `GetMemoryMap` + `ExitBootServices`, readable error screens instead of a hang

**Kernel**
- Long mode (x86-64), screen size taken from GOP at boot
- Exception handlers for vectors 0–31 with a crash report (vector and `RIP`)
- Timer on IRQ0 at 1000 Hz, preemptive scheduler with eight task slots
- Own page tables: identity map of 0–4 GB, uncached MMIO, null page and
  stack guard page unmapped
- Physical frame allocator, demand paging, a private address space per task
  that is fully returned on exit
- PS/2 keyboard and mouse (wheel supported), PC speaker

**File system**
- FAT32 read and write, subdirectories, all FAT copies kept in sync
- File descriptors: `open` / `read` / `write` / `lseek` / `close`
- File type detected by content (`EUGN` signature), extension only as a fallback
- Modification date and time stamped from the CMOS clock

**Networking**
- PCI enumeration, RTL8139 driver
- ARP, IPv4, ICMP (ping both ways), UDP, DHCP client, DNS resolver
- TCP client with retransmission and a 256 KB receive buffer
- HTTP/1.0 with `Host:` and redirects; a text-mode web browser (`WEB`)

**Kernel text console**
- MS-DOS–style command line with about 40 commands
- Built-in text editor (files up to 4 MB, go-to-line, binary files read-only)
- Text viewer, fullscreen BMP and video playback

**Graphical shell** (`GUI.BIN`)
- `libgui`: windows are objects with a message procedure, like `WndProc`
- Move, resize from every edge, minimize to an icon, maximize, system menu
- Buttons, checkboxes, radio buttons, edit boxes, list boxes, scroll bars, menus,
  modal dialogs, clipboard, partial screen updates
- Apps: Program Manager, Console, Notepad, File Manager, image viewer,
  video player, task list, and any program running inside a window

**Development inside the system**
- Port of flat assembler 1.73: `RUN FASM.BIN KERNEL.ASM KERNEL.BIN`
- `INSTALL` swaps in a new kernel and keeps the old one as `KERNEL.BAK`

## Project layout

```
EugeneOS/
├── build.bat              build everything, write to the VHD, start QEMU
├── linker.ld              linker script for user programs
├── boot/
│   ├── main.asm           UEFI bootloader (~2,100 lines)
│   └── OVMF.fd            UEFI firmware for QEMU
├── kernel/
│   └── kernel.asm         the kernel (~17,000 lines)
├── libc/
│   ├── entry.c            program entry point (CRT0)
│   ├── eugene_libc.c      C library
│   └── include/
│       ├── stdlib.h       system call wrappers and prototypes
│       └── syscalls.h     compatibility header for older code
├── libgui/                window library (~4,800 lines)
│   ├── gui.h  gui.c       low level: pixels, clipping, font, cursor, event queue
│   ├── bmp.c              BMP decoding and drawing
│   ├── win.h  win.c       windows, messages, z-order, focus, frames, modal loop
│   ├── ctl.c              controls: buttons, edit boxes, lists, labels
│   └── menu.c             menus and standard dialogs
├── userland/
│   ├── shell.c            the graphical shell
│   └── guidemo.c          demo of the low-level libgui layer
├── fasm_port/             flat assembler port (built separately)
│   ├── BUILD_FASM.bat
│   ├── FASM.ASM           entry point
│   ├── SYSTEM.INC         EUGENE OS platform layer
│   ├── MODES.INC          from fasm's LINUX/X64, unchanged
│   ├── HELLO.ASM          test program
│   └── *.INC              fasm sources (unchanged)
├── run_drive/
│   └── startup.nsh        UEFI shell script that starts the bootloader
└── docs/                  internals and development notes
```

QEMU itself is not in the repository: put `qemu-system-x86_64.exe` into a
`qemu/` folder in the project root (the folder is ignored by git).

## Building and running

The build runs on Windows.

### Requirements

| Tool | Default path |
|---|---|
| flat assembler | `C:\fasm\fasm.exe` |
| MinGW-w64 (gcc, ld, objcopy), GCC 7 or newer | `C:\mingw64\bin\` |
| QEMU | `.\qemu\` |
| Fixed-size VHD formatted as FAT32 | `C:\store\1.vhd`, mounted as `E:` |

All paths are variables at the top of `build.bat`.

### Build

```
build.bat
```

The script:
1. mounts the VHD with `diskpart` (needs administrator rights);
2. assembles the bootloader into `E:\EFI\BOOT\BOOTX64.EFI` and the kernel into `E:\kernel.bin`;
3. compiles `libc`, `libgui` and the shell with GCC;
4. links `GUI.BIN` and `GUIDEMO.BIN` and writes them to the disk;
5. unmounts the VHD and starts QEMU with 512 MB of RAM and an RTL8139 network card.

Network traffic is recorded to `net.pcap`, which opens in Wireshark.

### First steps

When the console appears:

```
HELP            list of commands
RUN GUI.BIN     start the graphical shell
```

To leave the shell, use `File → Exit Windows` in Program Manager.

### Compiler flags — do not change

```
-ffreestanding -fno-pie -m64 -mno-red-zone -mgeneral-regs-only
-mno-stack-arg-probe -fno-stack-protector -fno-exceptions
-fno-asynchronous-unwind-tables -fno-ident -O2
```

- `-mgeneral-regs-only` — no SSE. The scheduler does not save XMM registers.
- `-mno-red-zone` — interrupt handlers write below `RSP`.
- `-mno-stack-arg-probe` — otherwise MinGW calls `___chkstk_ms`, which does not exist here.
- `-fno-stack-protector` — otherwise GCC calls `__stack_chk_fail`.

Linking is done in two steps (`ld` to PE, then `objcopy -O binary`), because
MinGW's `ld` can't write non-PE output. See [docs/internals.md](docs/internals.md#linking-user-programs).

## Kernel console commands

### Files

| Command | Action |
|---|---|
| `LS` | list files with sizes |
| `CD <dir>` | change directory |
| `BACK` | go up one level |
| `MKDIR <dir>` | create a directory |
| `CREATE <file>` | create a file |
| `RM <file>` | delete a file |
| `COPY <src> <dst>` | copy a file |
| `REN <old> <new>` | rename a file or directory |
| `OPEN <file>` | view a file: text, BMP or video, chosen by content |
| `FILE <file>` | show what type the system thinks the file is |
| `EDIT <file>` | edit a file |
| `RUN <program> [args]` | run a program |
| `INSTALL <file>` | install a new kernel, keeping the old one as `KERNEL.BAK` |

### Network

| Command | Action |
|---|---|
| `PCI` | list PCI devices |
| `NETINIT` | initialize the network card, show the MAC |
| `NETTEST` | ARP request to the gateway |
| `DHCP` | get an address automatically |
| `IPCONFIG` | show the current settings |
| `PING` / `PING <ip or host>` | ping the gateway, an address or a name |
| `NSLOOKUP <host>` | resolve a name |
| `SETDNS <ip>` | set the DNS server manually |
| `TCP <ip> <port>` | open and close a connection (handshake test) |
| `GET <host> [path]` | fetch a page over HTTP and print the raw response |
| `WEB <host> [path]` | open a page as text, following redirects |

A typical session: `NETINIT`, `DHCP`, then `WEB example.com`. Only plain
HTTP works; HTTPS sites are reported as such.

### System

| Command | Action |
|---|---|
| `HELP` | list of commands |
| `CLS` | clear the screen |
| `INFO` / `CPUINFO` | system and processor information |
| `TIME` | current time |
| `BEEP` | PC speaker test |
| `MEMMAP` | memory map and free frames |
| `PAGING` | page table state |
| `TASKS` | task slots and demand-paging statistics |
| `WIN` | draw a test window |
| `REBOOT` | restart |
| `PFTEST` / `NULLTEST` | deliberately trigger a page fault / null dereference (needs a reboot) |

### Editor

| Key | Action |
|---|---|
| `F2` | save |
| `F3` | go to line number |
| `ESC` | exit |
| arrows, `PgUp` `PgDn`, `Home` `End` | move the caret |
| `Backspace` / `Delete` | delete before / under the caret |

The title bar shows `LINE`, `COL` and `SIZE`. A file containing a zero byte
opens read-only with a red `BINARY FILE - READ ONLY` bar. The kernel font
covers ASCII only, so Cyrillic text shows as blanks.

## Graphical shell

```
RUN GUI.BIN
```

| Window | What it does |
|---|---|
| Program Manager | icons for everything in the current directory, subdirectories open on double-click |
| Console | `HELP CLS VER TIME LIST CD RUN ECHO WEB EXIT`; any other command goes to the kernel (`MEMMAP`, `TASKS`, `PING`, `GET`…) |
| Notepad | multi-line editor with `File` and `Edit` menus; `WEB <host>` in the Console opens a page here |
| File Manager | name, size and date columns; open, run, copy, rename, delete, create directory, properties |
| Image viewer | BMP in a scrollable window |
| Video player | `.EVD` in a window, scaled to the window size, `Space` pauses |
| Program window | a graphical program (for example DOOM) drawing into a window instead of the whole screen |
| Task List | double-click the desktop: `Switch To` / `End Task` |

Kernel commands that take over the screen (`RUN`, `OPEN`, `EDIT`, `WEB`,
`WIN`, `REBOOT`, `CLS`) can't be run from the GUI Console.

### Controls

| Action | How |
|---|---|
| Move / resize a window | drag the title bar / an edge or corner |
| Minimize / maximize | buttons on the right of the title bar |
| Restore a minimized window | click its icon at the bottom of the screen |
| Close a window | double-click the box on the left, or `Close` in its menu |
| Menus | click, or `Alt` + underlined letter |
| Next / previous control | `Tab` / `Shift+Tab` |
| Select text | mouse, `Shift` + arrows, `Ctrl+A` |
| Clipboard | `Ctrl+C` / `Ctrl+X` / `Ctrl+V` |
| File Manager | `Enter` open, `F8` copy, `Del` delete, `F5` refresh, `Alt+Enter` properties |
| Kill the running program | `Ctrl+Shift+Q` (handled by the kernel) |

### Icons

There is no `.ICO` format. A BMP with the same name as a program becomes its
icon: `APP.BIN` → `APP.BMP`. Uncompressed BMP at 1, 4, 8, 24 and 32 bits per
pixel is supported, up to 128×128 for icons.

## Self-hosting

The system can assemble its own kernel and any assembly program.

### Preparation

1. `fasm_port/` already contains the fasm sources and the platform layer.
2. Run `fasm_port\BUILD_FASM.bat` → `FASM.BIN`.
3. Copy `FASM.BIN` to the root of the VHD.

Do not replace `fasm_port/SYSTEM.INC` with the one from fasm's `SOURCE\` folder:
that one is for Linux, and ours is the EUGENE OS port.

### Usage

```
RUN FASM.BIN HELLO.ASM HELLO.BIN
RUN HELLO.BIN
```

Rebuilding the kernel without leaving the system:

```
EDIT KERNEL.ASM
RUN FASM.BIN KERNEL.ASM K.BIN
INSTALL K.BIN
REBOOT
```

`INSTALL` first saves the current kernel as `KERNEL.BAK`. To roll back from a
working system: `COPY KERNEL.BAK KERNEL.BIN`. If the new kernel doesn't boot,
the old one can only be restored from outside, by mounting the VHD.

A kernel assembled inside the system is byte-for-byte identical to one
assembled with fasm on Windows.

Only assembly code builds inside the system. The C part (`GUI.BIN`) needs GCC
and is built on the host.

## Known limitations

| Limitation | Effect |
|---|---|
| No TLS | HTTPS sites don't open |
| One TCP connection at a time, no TCP options | no window scaling, receive window ≤ 64 KB |
| Network uses polling | wastes CPU cycles, packets may be lost under load |
| File names have no paths | no `Move`: files can only be handled in the current directory |
| Directories can't be deleted or copied | no tree walking yet |
| Opened files are held in memory | 8 MB per file, up to 8 files |
| Only one program window at a time | the kernel can only report "the child is alive" |
| `exec` is a chain | a program that starts another one has to exit first |
| Scheduler doesn't save FPU/SSE state | user code must be built with `-mgeneral-regs-only` |
| No user/kernel mode separation | everything runs in ring 0, NX is off |
| Program stack is 2 MB | limited by the guard page |
| Kernel font is ASCII only | Cyrillic is invisible in the editor |
| BMP without RLE | compressed images don't open |
| Tested in QEMU only | stride ≠ width and non-BGR framebuffers were never seen on real hardware |

## Further reading

- [docs/internals.md](docs/internals.md) — memory map, boot handoff, paging,
  scheduler, system calls, FAT32, networking, GUI architecture, fasm port.
- [docs/devlog.md](docs/devlog.md) — development notes: the bugs that took the
  longest, measurements, and why things are the way they are.
