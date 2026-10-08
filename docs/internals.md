# EUGENE OS internals

**English** | [Українська](internals.uk.md) · [← README](../README.md)

A reference for anyone changing the code. Bug stories and measurements are in
[devlog.md](devlog.md).

## Contents

- [Memory map](#memory-map)
- [Bootloader](#bootloader)
- [Kernel handoff](#kernel-handoff)
- [Memory and tasks](#memory-and-tasks)
- [System calls](#system-calls)
- [Programs in a window](#programs-in-a-window)
- [File system](#file-system)
- [Networking](#networking)
- [Graphical shell](#graphical-shell)
- [flat assembler port](#flat-assembler-port)
- [Linking user programs](#linking-user-programs)
- [Crash diagnostics](#crash-diagnostics)

---

## Memory map

Memory is identity-mapped: **physical address equals virtual address**,
except for two removed pages and each task's private areas (stack, image,
heap). This keeps DMA simple — a buffer is handed to the network card as is.

| Address | Size | Purpose |
|---|---|---|
| `0x00100000` | ≤ 1 MB | kernel |
| `0x00200000` | — | boot info block from the bootloader (UEFI memory map) |
| `0x00300000` | — | free frame bitmap |
| `0x01000000` | 16 MB | file load buffer (`VideoMemoryBase`) |
| `0x02000000` | 16 MB | directory read buffer |
| `0x03000000` | up to 13 MB | render buffer |
| `0x03D00000` | — | video player line buffer |
| `0x03E00000` | 4 KB | **guard page** below the program stack (unmapped) |
| `0x03FFFFF8` | — | program stack top |
| `0x04000000` | 16 MB | program image (private per task) |
| `0x05000000` | 28 MB | kernel heap |
| `0x07000000` | 24 KB | network card buffers |
| `0x07100000` | 4 MB | editor buffer |
| `0x07500000` | 8 MB | canvas of a windowed task |
| `0x07D00000` | 32 KB | text output of a windowed task |
| `0x07D10000` | 256 KB | TCP receive buffer |
| `0x08000000` | 64 MB | file descriptor buffers (8 × 8 MB) |
| `0x0C000000` | 64 MB | fasm working memory; video file for windowed playback |
| `0x10000000` | 128 MB | program heap (private, demand-paged) |
| `0x18000000` | up to 4 GB | frame allocator pool |

> **The program heap is at 256 MB on purpose.** It used to start at
> `0x8000000`, where the file descriptor buffers live, so a program that
> allocated memory while holding a file open overwrote its own data. The
> value is duplicated in `libc/eugene_libc.c` (`HEAP_START`) — change both.

> **`AppStackTop` is `0x3FFFFF8`, NOT a multiple of 16, on purpose.** The
> SysV ABI requires 16-byte alignment **before** `call`, so on function entry
> `RSP % 16 == 8`. The kernel enters a program with `iretq`, not `call`, so it
> must provide exactly that value. "Fixing" it to `0x3FFFFF0` shifts the stack
> by 8 bytes and every `movaps` on the stack raises `#GP`.

---

## Bootloader

`boot/main.asm` is a UEFI application (`format PE64 EFI`). It sets up GOP,
draws the setup screen straight into the framebuffer (no `ConOut`), collects
CPU, memory and disk information, and shows a menu:

1. `BOOT EUGENE OS CORE` — start the system;
2. `SELECT VIDEO MODE` — list every GOP mode, `SetMode` to the chosen one;
   the chosen resolution is used by the whole OS;
3. `RUN BENCHMARKS` — startup timings (results are in the devlog);
4. `REBOOT SYSTEM`;
5. `SHUTDOWN VM`.

### Offsets in `EFI_BOOT_SERVICES`

The table starts with a 24-byte header, followed by 8-byte function pointers:

| Offset | Function |
|---|---|
| `0x28` | `AllocatePages` |
| `0x38` | `GetMemoryMap` |
| `0x48` | `FreePool` |
| `0x98` | `HandleProtocol` |
| `0xE8` | `ExitBootServices` |
| `320` | `LocateProtocol` |

The code uses named constants (`BS_GET_MEMORY_MAP` and so on). A bare number
here once cost the project an `ExitBootServices` that was never called — see
the devlog.

### Pixel format

`MODE_INFORMATION+12` holds `EFI_GRAPHICS_PIXEL_FORMAT`:

| Value | Format | What we do |
|---|---|---|
| 0 | RGB | swap channels |
| 1 | BGR (`0x00RRGGBB`) | nothing, this is our native order |
| 2 | `PixelBitMask` | channel shifts computed once with `BSF` |
| 3 | `PixelBltOnly` | no linear framebuffer: `FindLinearMode` looks for another mode |

Colors in the code are written as `0x00RRGGBB`, and `MapColor` converts them
to the native order **once per fill or text line**, not per pixel.

### Loading the kernel

1. `HandleProtocol` → `EFI_LOADED_IMAGE` → `EFI_SIMPLE_FILE_SYSTEM`;
2. `OpenVolume`, `Open("kernel.bin")`;
3. `GetInfo` — the real file size;
4. `AllocatePages` (`AllocateAddress`) at `0x100000` — exactly as many pages as needed;
5. `Read`, then compare the bytes read with the file size;
6. `Close`, then the `GetMemoryMap` + `ExitBootServices` loop (up to 16 tries — `MapKey` goes stale on any memory map change).

Every step checks its status. On failure the screen shows the reason and code:

```
*** BOOT FAILURE ***
KERNEL.BIN NOT FOUND ON BOOT VOLUME
EFI STATUS:      14
SYSTEM HALTED. POWER OFF AND RESTART.
```

The bootloader font only covers codes 32–93, so all messages are upper case.

---

## Kernel handoff

| Register | Value |
|---|---|
| `RCX` | framebuffer base address |
| `RDX` | width — how many pixels are **visible** per line |
| `R8` | height |
| `R9` | **stride** — how many pixels to the next line |
| `R10` | boot info block with the UEFI memory map, or 0 |

> **Width and stride are different numbers.** UEFI allows
> `PixelsPerScanLine` to be larger than the width. Width is for clipping and
> centering, stride is for addressing a pixel. If `R9` is smaller than the
> width (an old bootloader), the kernel uses the width as the stride.

---

## Memory and tasks

### Page tables

The kernel builds its own tables instead of using the firmware's: an identity
map of 0–4 GB with 2 MB pages. The range is set not by the amount of RAM but
by the **framebuffer at 2 GB**, in the PCI hole. Gigabytes 2 and 3 are marked
`PCD` (uncached) — that's where device registers are.

### Two unmapped pages

| Address | What it catches | Test |
|---|---|---|
| `0x00000000` | null pointer dereference | `NULLTEST` |
| `0x03E00000` | program stack overflow | — |

To remove a 4 KB page, its 2 MB page has to be replaced by a 512-entry table,
so the program stack is limited to ~2 MB. `PFTEST` reads from 4 GB, the first
address past the mapping. Both test commands crash the system on purpose.

### Frame allocator

Hands out 4 KB pages **above 384 MB** (everything below is assigned by the
memory map). It is built in two passes: mark everything used, then free only
what the firmware reported as usable — erring towards "used" is safe. Frames
are handed out **zeroed**, because garbage in page tables would be taken as
real mappings.

### Demand paging

A program's heap (128 MB), stack and image are created as tables with
**not-present** pages; a frame appears on first access. The `#PF` handler
checks the vector, the present bit, the range and the directory entry, so a
real bug in a program doesn't silently get memory. `TASKS` shows
`HEAP PAGES MAPPED`: the shell touches about a thousand pages (4 MB out of 128).

### Private address space

All programs are linked at `0x4000000`. Each task gets its own `PML4`, `PDPT`
and `PD0`, where only three groups of entries are private — stack, image and
heap. Everything else (kernel, buffers, frame bitmap) is shared.

> **`CR3` and `RSP` are switched by adjacent instructions**, with no stack
> access between them. Otherwise any `push` or interrupt hits a stack that
> doesn't exist in the new space — double fault and reboot. The general rule:
> an action done in one address space but needed in another doesn't work.

A task's memory is fully returned to the pool: pages, tables, directory,
`PDPT`, `PML4`, in that order. Freeing is deferred to the `RUN` handler,
because at exit time the kernel is still running on the task's stack.
`POOL FRAMES FREE` in `MEMMAP` must return to the same number after every run.

### Scheduler

Eight slots. Slot zero belongs to the kernel; the rest go to programs. A task
is created with a fake interrupt frame on its stack (`SS`, `RSP`, `RFLAGS`,
`CS`, `RIP` and 15 zeroed registers); switching means saving `RSP` and loading
another. The timer runs at 1000 Hz and each ready task gets an equal share.
Idle tasks give up their slice: the kernel does `hlt`, the shell calls
`syscall 45`.

FPU/SSE state is not saved, hence `-mgeneral-regs-only`.

---

## System calls

Called with `int 0x80`. `RAX` = number, `RSI` = arg1, `R9` = arg2,
`RDI` = arg3, `RDX` = arg4. The kernel preserves every register except `RAX`.
C wrappers are in `libc/include/stdlib.h`.

Vector `0x80` is an **interrupt gate**: a call runs to completion without
preemption, so two calls can never interleave.

| # | Call | Arguments → result |
|---|---|---|
| 0 | `exit` | — |
| 1 | `get_key` | → scan code |
| 2 | `print` | RSI=string, R9=color |
| 4 | `clear_screen` | — |
| 5 | `read_file` | RSI=name, R9=buffer → bytes (whole clusters) |
| 6 | `put_char` | RSI=char, R9=color |
| 7 | `erase_char` | — |
| 8 | `list_files` | draws the list on screen |
| 9 | `blit_buffer` | RSI=`BlitArgs` |
| 10 | `get_ticks` | → timer ticks |
| 11 | `get_mouse` | → X, Y, buttons, wheel |
| 12 | `get_time` | → hours and minutes (BCD) |
| 13 | `get_file_list` | RSI=buffer, R9=size → names as one string |
| 14 | `write_file` | RSI=name, RDI=buffer, RDX=size |
| 15 | `screen_info` | → (height << 32) \| width (canvas size for a windowed task) |
| 16 | `open` | RSI=name, R9=flags → fd |
| 17 | `read` | RSI=fd, R9=buffer, RDI=count |
| 18 | `write` | RSI=fd, R9=buffer, RDI=count |
| 19 | `lseek` | RSI=fd, R9=offset, RDI=whence |
| 20 | `close` | RSI=fd |
| 21 | `get_args` | RSI=buffer, R9=size |
| 22 | `fill_rect` | RSI=`FillRectArgs` |
| 23 | `cursor_owner` | RSI=1 — the program draws the mouse cursor |
| 24 | `read_file_max` | RSI=name, R9=buffer, RDI=limit → bytes |
| 25 | `blit_stride` | RSI=`BlitArgs` with a stride |
| 26 | `get_key_event` | → ASCII \| scancode<<8 \| modifiers<<16 |
| 28 | `exec` | RSI=program name (a chain, see below) |
| 29 | `chdir` | RSI=directory name or `..` → 1/0 |
| 30 | `getcwd` | RSI=buffer, R9=size |
| 31 | `screen_stride` | → stride in pixels |
| 32 | `unlink` | RSI=name → 1/0 |
| 33 | `mkdir` | RSI=name → 1/0 |
| 34 | `rename` | RSI=old, R9=new → 1/0 |
| 35 | `copy` | RSI=source, R9=destination → 1/0 |
| 36 | `file_type` | RSI=name → `FT_*` (0 unknown, 1 program, 2 text, 3 BMP, 4 sound, 5 video, 6 image, 7 system, 8 directory) |
| 37 | `spawn` | RSI=name — start a program and stay alive |
| 38 | `dir_info` | RSI=array of `FileInfo` (32 bytes), R9=max → count |
| 39 | `video_open` | RSI=name → width \| height<<16 |
| 40 | `video_frame` | RSI=buffer, R9=capacity — next frame, 32 bits per pixel |
| 41 | `spawn_windowed` | RSI=name, R9=(height<<32)\|width → canvas address or 0 |
| 42 | `child_alive` | → 1 while the child is alive or still starting |
| 43 | `keys_to_child` | RSI=1 — keyboard goes to the child |
| 44 | `canvas_seq` | → count of frames drawn into the canvas |
| 45 | `yield` | give up the rest of the time slice |
| 46 | `app_text` | → address of the windowed task's text header (`AppText`) |
| 47 | `kernel_cmd` | RSI=command line → bytes of output (text at the address from 46) |
| 48 | `web_fetch` | RSI="host/path" → bytes of page text, 0 on failure |

Numbers 3 and 27 don't exist.

### The numbering rule

Numbers **1, 5 and 9 are frozen**: there are prebuilt binaries on the disk
(including a DOOM port with no source) that call them in the old form. Once,
arguments were added to them, and old programs started passing stack garbage
as arguments. That's why 24, 25 and 26 exist.

**Never add an argument to an existing number — add a new one.**

### `exec` is a chain

`syscall 28` only records the request; the program exits by itself, the kernel
starts the named one, and when that one ends it brings the previous one back.
Depth is 4 levels (`ExecStack`). To stay alive next to a child, use 37 or 41.

### File descriptors

`open` reads the **whole** file into its own buffer, `read`/`write`/`lseek`
work in memory, `close` writes the buffer back. **Without `close`, changes are
lost.** Up to 8 files of 8 MB each.

### File operations (32–35)

They work in the **current directory** — the system doesn't understand paths,
so there is no `Move`. A directory can't be deleted (the chains of the files
inside would stay allocated) or copied. A copy is limited to 16 MB. Copying a
file onto itself is rejected.

### Shared file system buffers

The FAT layer uses shared buffers (`SectorBuffer`, `FatCacheBuf`, `DirBuffer`
and others). No lock is needed because system calls are not preempted. The
only risky place is loading a program image, which runs in the kernel task
with interrupts enabled. During that time the `FsBusy` flag is set, and the
eighteen disk-related calls wait in the dispatcher. Their list is a single
array next to the check.

---

## Programs in a window

### Canvas

`syscall 41` starts a program with a **canvas** — a buffer that receives its
`blit` and `fill_rect` instead of the framebuffer. The parent keeps running.
The program doesn't need to be rebuilt: the kernel just answers `syscall 9`
and `15` with the canvas size.

- The canvas is provided by the **kernel** at `0x7500000`, in the shared part
  of the address space. A buffer from the shell's heap doesn't work: the heap
  is private, so the child would draw into its own copy.
- The canvas is **screen-sized**, not window-sized: the program centers its
  frame for the "screen" size, and the window scales the finished frame.
- A normal launch gets a zero canvas, so a task never inherits someone else's.
- Reading the image from disk sits between the launch request and the task
  existing; the `SpawnBusy` flag keeps `child_alive` at 1 during that time.

### Keyboard and mouse

There is one keyboard queue. `syscall 43` sends keys to the child while its
window is active. The mouse **always** stays with the shell — that's why
clicking another window takes the keyboard back without killing the program.

### Text

Text calls (`2`, `4`, `6`, `7`) from a task with a canvas don't draw on screen;
they go into a buffer at `0x7D00000` (32 KB). The shell gets its address with
`syscall 46` and reads the length and change counter straight from memory.

The window shows the text **until the program draws its first frame**, then
the canvas. When the buffer is full, the first half is dropped. After the
program exits, the window stays open with its last contents. `syscall 8`
doesn't work in a window — it draws a finished list instead of returning a
string.

### Video in a window

`syscall 39` loads the file into its own area at `0xC000000` (not the shared
`VideoMemoryBase`, which any `bmp_load` would overwrite); `syscall 40` decodes
the next frame into the program's buffer. The shell scales it with
`gui_bitmap_fit`. There is one decoder in the kernel, so there is one video
player window.

### Kernel console in a window

`syscall 47` switches `DrawString` and `NewLine` from drawing to appending to
a buffer and calls the same `ExecuteCommand`. Commands that take over the
screen (`RUN`, `OPEN`, `EDIT`, `WEB`, `WIN`, `REBOOT`, `EXIT`, `CLS`) are
rejected by a single list, `KCmdDenied`. `syscall 48` is the same logic as
`WEB`, but the result stays as text for Notepad (`PAGE.TXT`).

---

## File system

FAT32 with full write support:

- walks the whole directory chain and grows a directory by a new cluster;
- correct FAT handling for any cluster number;
- writes to every FAT copy;
- overwriting a file frees its old chain;
- rolls back when the disk is full, without leaking clusters;
- modification date and time from CMOS (`FatNow`); the creation date is kept on overwrite.

### File type

Native formats start with a 16-byte header with the `EUGN` signature: type,
version, width, height, flags, data size. The signature decides what to do
with the file; the extension is only a second step, and only for foreign
formats.

| Extension | What it is |
|---|---|
| `.EUG` | system file; without a signature — a corruption message |
| `.EVD` | video; also works without a header (320×240) |
| `.BMP` | image |
| `.TXT` | text |
| `.WAV` | sound (stub for now) |
| `.BIN` `.APP` | a program, and only a program; `OPEN` suggests `RUN` |

Program Manager also asks the kernel for the type (`syscall 36`), reading one
sector per file.

### Directory with size and date

`syscall 38` returns 32-byte records: name, attributes, modification date and
time, size, first cluster. Number 13 (names only) can't be changed — prebuilt
binaries expect its format.

### `LoadFAT32Chain`

Reads the chain to its end and ignores the size from the directory entry: if
they disagree, the whole chain is read.

---

## Networking

### QEMU

```
-netdev user,id=n0 -device rtl8139,netdev=n0,mac=52:54:00:12:34:56
-object filter-dump,id=dump0,netdev=n0,file=net.pcap
```

`user` mode is NAT without administrator rights; pinging the guest from the
host is impossible in it (that needs `tap`). `net.pcap` opens in Wireshark,
which checks checksums for you.

If DNS doesn't work: QEMU proxies DNS through the host's resolver. Check
`nslookup` on the host, work around it with `SETDNS 8.8.8.8`. The resolver
has a fallback server, because slirp at `10.0.2.3` doesn't answer in every
QEMU build.

### RTL8139 driver

Uses I/O ports and has a single receive ring buffer instead of descriptor
rings like the e1000.

- **Bus mastering is required** — bit 2 of register `0x04` in the PCI config
  space. Without it the receive buffer is always empty.
- **Slack in the receive buffer.** The card is told 8 KB, 16 KB is reserved:
  with `WRAP=1` it writes a frame past the end of the buffer.
- **`CAPR` gets the position minus 16** — a quirk of the chip.
- **Polling instead of interrupts.** `NetPollBackground` runs in the kernel's main loop.

### Checksums

16-bit words into a 32-bit accumulator, fold the carries, invert. Byte order
doesn't matter — read words as they lie in memory and store the result the
same way. TCP adds a pseudo-header, whose fields are just added to the sum
(UDP sends a zero checksum).

### TCP

Client only, one connection at a time. States:
`CLOSED → SYN_SENT → ESTAB → DONE`.

- Only the exactly-next segment is accepted; the sender will resend the rest.
- Sending is stop-and-wait.
- `SYN` and data are retried up to 5 times, half a second apart (measured in
  time, not loop iterations). `TcpSndNxt` moves only after an acknowledgement.
- Acknowledgements are compared by subtraction — sequence numbers are 32-bit and wrap.
- 256 KB receive buffer in its own area; window ≤ 65535, because the field is 16 bits.
- Deliberately missing: options (MSS, window scaling), reordering, more than one connection.

`TCP <ip> <port>` reports five different failure reasons; `RST` means the
packet arrived and only the port is closed.

### HTTP and `WEB`

HTTP/1.0 with a `Host:` header (without it, name-based hosting such as
Cloudflare answers `403`). The server closes the connection after the
response, so the end of the response is the `FIN`. The host is parsed as an
IP first and only then sent to DNS.

`WEB` adds:
- following `301/302/303/307/308`, up to five times;
- HTML → text with a state machine: tags are dropped, `script` and `style`
  together with their content, entities are decoded, whitespace is collapsed,
  lines wrap by words at 100 columns;
- for `https://`, an honest message that there is no TLS.

---

## Graphical shell

### Layers

Like Windows 3.1, `GDI` is separate from `USER`:

- `gui.c` — pixels, clipping, proportional font, primitives, cursor, event
  queue, partial screen updates;
- `win.c` / `ctl.c` / `menu.c` — windows, controls, menus and dialogs.

### A window is an object

A window's behavior is its procedure. Anything it doesn't handle falls through
to `def_window_proc`, which draws the frame, title, buttons and scroll bars and
handles dragging.

```c
static long console_proc(Window* w, int msg, long a, long b) {
    switch (msg) {
    case WM_PAINT:   ...; return 0;
    case WM_CHAR:    ...; return 0;
    case WM_COMMAND: ...; return 0;
    }
    return def_window_proc(w, msg, a, b);
}
```

A new app is one function plus `wnd_create`. Buttons, edit boxes and lists
are windows too, with the same focus and clipping.

### Painting model

Nobody draws "right now": an area is marked invalid, and once per frame the
manager repaints only the intersection of the invalid area with each window.

```
wm_pump():
  1. remove the cursor from the frame buffer
  2. read events from the kernel and dispatch them to windows
  3. repaint invalid areas, bottom to top
  4. put the cursor back and copy only what changed to the screen
```

Don't swap steps 1 and 3 — the cursor would smear. Windows below the topmost
opaque window that fully covers an area are not painted. Dragging moves an
`XOR` outline, and the new geometry is applied on release.

### Lists with columns

The font is proportional, so columns are aligned with tab stops: a line is
split by `\t`, offsets are given in pixels (like `LBS_USETABSTOPS`), and a
negative offset right-aligns the segment.

### BMP

BMP files are decoded in the program, not in the kernel. Uncompressed,
1/4/8/24/32 bits, with a palette, bottom-up and top-down. RLE isn't supported.

---

## flat assembler port

- **Arguments.** The kernel hands over a single string (`syscall 21`);
  `build_command_line` splits it into words and builds the
  `[count][argv0][argv1]...` array, as on Linux. Options `-m`, `-p`, `-d`,
  `-s` work.
- **Memory.** There is no `brk`/`mmap`: `init_memory` returns a fixed 64 MB
  area at 192 MB.
- **`MODES.INC` redefines `push`/`pop` as 32-bit** — the fasm core is 32-bit.
  So **never write `push rbx` in `SYSTEM.INC`**: save 64-bit registers in
  `r10`–`r15` or in memory.
- **Labels are prefixed with `eug_` and `gp_`** — the fasm core has 3,179 global labels.
- `adapt_path` strips the path down to the name, so fasm can't see programs in subdirectories.

### Limits of self-hosting

The kernel and assembly programs build inside the system. The C part needs
GCC. The bootloader assembles, but there is nowhere to install it:
`EFI\BOOT\BOOTX64.EFI` is in a subdirectory, and neither fasm nor `COPY`
work with subdirectories.

---

## Linking user programs

MinGW's `ld` runs in `i386pep` emulation and **always** performs PE-specific
steps, so `--oformat binary` or `OUTPUT_FORMAT(elf...)` give:

```
cannot perform PE operations on non PE output file
```

The scheme: `ld` produces a normal PE, `objcopy -O binary` strips the headers.
`linker.ld` puts the whole image into a single `.image` section, so `objcopy`
places it at offset 0. `entry.o` must come first; `build.bat` checks the
linker map to make sure `_start` is at `0x4000000`.

---

## Crash diagnostics

On an exception in a program, the kernel kills it and shows the vector and `RIP`:

```
FATAL EXCEPTION: APP KILLED TO PROTECT KERNEL
VECTOR: 000000000000000D
RIP   : 0000000004001A3C
```

| Vector | What it is | Where to look |
|---|---|---|
| `06` | `#UD` | SSE despite `-mgeneral-regs-only` |
| `0D` | `#GP` | stack alignment |
| `0E` | `#PF` | address outside the mapping |
| `08` | `#DF` | corrupted stack |

`RIP` minus `0x4000000` is the offset in the program:
`objdump -d userland/shell.tmp`.
