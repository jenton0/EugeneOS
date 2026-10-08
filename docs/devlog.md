# EUGENE OS development notes

**English** | [Українська](devlog.uk.md) · [← README](../README.md)

Bug stories, measurements, and why things are done the way they are. How
everything works today is in [internals.md](internals.md).

## Contents

- [The `ExitBootServices` that was never called](#the-exitbootservices-that-was-never-called)
- [Video modes and channel order](#video-modes-and-channel-order)
- [Bootloader measurements](#bootloader-measurements)
- [Loading the kernel: how it used to be](#loading-the-kernel-how-it-used-to-be)
- [The editor: from typewriter to editor](#the-editor-from-typewriter-to-editor)
- [Why the graphical shell was rebuilt](#why-the-graphical-shell-was-rebuilt)
- [Programs in a window: where the time went](#programs-in-a-window-where-the-time-went)
- [Program text in a window](#program-text-in-a-window)
- [TCP: hunting the bugs](#tcp-hunting-the-bugs)
- [Self-hosting: test protocol](#self-hosting-test-protocol)
- [FAT32: checked against a model](#fat32-checked-against-a-model)

---

## The `ExitBootServices` that was never called

The longest bug in the project. It shows well why a UEFI bug can go years
without a single symptom.

**Symptom.** The setup screen always said `RAM SIZE : UNKNOWN`, even though
the CPU and disk size were detected correctly. A small thing nobody looked at
for half a year.

**Hypothesis.** `GetRamInfo` leaves through `test rax, rax / jnz .done`, so
the call returns a non-zero status. The code had a bare `[rax + 0x28]`, which
was assumed to be `GetMemoryMap`. If that assumption was wrong, the neighboring
function sits at that offset — `AllocatePages`.

**Method.** A probe was built into a copy of the bootloader: both offsets are
called with `GetMemoryMap` arguments, and the status and `DescriptorSize` are
printed on screen. The image is written to a copy of the VHD, run in QEMU with
`snapshot=on`, and the screen is captured with the monitor's `screendump`.

**Evidence.**

```
BS+28 ST/DS: 2/0     <- AllocatePages: status 2, DescriptorSize not filled in
BS+38 ST/DS: 0/48    <- GetMemoryMap:  status 0, DescriptorSize 48
```

Status 2 is `EFI_INVALID_PARAMETER`. 48 bytes is the canonical size of
`EFI_MEMORY_DESCRIPTOR`. So the offsets in the code were shifted by exactly
one function.

**Consequences.** The first one was that same `RAM SIZE : UNKNOWN`. The second
was far more serious: the exit loop called `GetMemoryMap` at offset `0x38`
instead of `ExitBootServices`, so **boot services were never shut down once
in the whole history of the project**. The kernel started on top of live
firmware.

**Why it never showed.** The kernel immediately installs its own GDT and IDT
and reprograms the interrupt controller. The firmware stayed formally alive
but inert: its handlers were disconnected and its watchdog had no way to fire.

**What it really cost.** The memory map was never read, so the kernel placed
its heap at fixed addresses blindly. In QEMU nothing collided. This is exactly
the kind of defect that works in an emulator and fails on real hardware.

**Fix.** Correct offsets as named constants; a `GetMemoryMap` +
`ExitBootServices` loop with retries (because `MapKey` goes stale on any map
change) capped at 16 tries; a status check at every step.

**Confirmation.**

| Scenario | Expected | Actual |
|---|---|---|
| Setup screen | real amount of RAM | `RAM SIZE : 448 MB` |
| Kernel boot | OS console | `C:/>` prompt |
| `RUN GUI.BIN` | graphical shell | Program Manager + Console |
| `KERNEL.BIN` renamed | a clear failure | `EFI STATUS: 14` (`EFI_NOT_FOUND`) |

**Takeaway.** UEFI has no protection against this: a wrong offset gives a
valid pointer to another function, it returns an error code, and nobody
checks the code. That's why the fix is not just the right numbers but named
constants and mandatory status checks, so next time the defect screams instead
of staying silent.

---

## Video modes and channel order

**What the mode list showed in QEMU.** 30 modes from 640×480 to 2560×1600.
In all of them the stride equals the width, and the pixel format is 1 (BGRA).
This confirms two assumptions the drawing code silently relied on, and explains
why a stride bug could never show up here: QEMU never pads lines.

```
[ 0 ] 1280X800   STRIDE 1280  FMT 1  <-- ACTIVE
[ 1 ] 640X480    STRIDE 640   FMT 1
[ 2 ] 800X480    STRIDE 800   FMT 1
...
[ 29 ] 2560X1600 STRIDE 2560  FMT 1
```

**How RGB was tested when QEMU only offers BGR.** The format was forced to 0
in a copy of the bootloader, and the result on screen was checked:

| Intended `0x00RRGGBB` | Normal (BGR) | Forced RGB |
|---|---|---|
| `0x0000AA` background | blue | `#AA0000` red |
| `0xFFFF00` yellow | yellow | `#00FFFF` cyan |
| `0xFF0000` red | red | `#0000FF` blue |
| `0x00FF00` green | green | `#00FF00` unchanged |
| `0xFFFFFF`, `0xAAAAAA`, `0x555555` | grays | unchanged |

Red and blue swap, green and the gray scale stay put — the swap happens
exactly where it should.

---

## Bootloader measurements

Menu item `[ 3 ] RUN BENCHMARKS`. The clock is `RDTSC`, the only one available
both before and after `ExitBootServices`. It is calibrated once against a
100 ms `Stall()`. Each measurement is repeated and averaged.

**Test setup:** QEMU 10.2, TCG, OVMF, 1280×800, kernel 78,712 bytes.

| What | Time |
|---|---|
| Calibration | 2689 ticks per microsecond |
| `LocateProtocol` + reading the mode | 107 µs |
| Listing 30 modes (`QueryMode` × 30) | 203 µs |
| CPU, memory and disk info | 306 µs |
| Drawing the setup screen | 1889 µs |
| **Total to the first screen** | **2508 µs** |
| Screen fill, direct write | 1630 µs |
| Screen fill, `Blt` `EfiBltVideoFill` | 1376 µs |
| `Open` + `GetInfo` + `Read` of the kernel | 7773 µs |

**What follows from this.**

- *GOP is almost free:* ~7 µs per `QueryMode`, 12 % of the time to the first
  screen in total. Listing modes on every boot is justified.
- *Drawing is the main cost:* 75 % of startup, of which 1630 µs is just the
  background fill and ~260 µs is all the text.
- *Reading the kernel costs more than everything else combined:* ~10 MB/s
  through `SimpleFileSystem`. From power-on to the kernel handoff takes about 10 ms.

**Direct write vs `Blt`.** `Blt` came out 16 % faster, but this number can't
be trusted. Under TCG the framebuffer is ordinary emulator memory, so two
generated loops are being compared, not two paths to video memory. The real
result is that **this question can't be settled on an emulator**.

**What this setup can't measure:** direct write vs `Blt`; stride ≠ width;
non-BGR formats; other vendors' mode tables.

**Compared with other bootloaders** — not by speed, but by how the framebuffer
reaches the kernel:

| Bootloader | What it does with graphics |
|---|---|
| `systemd-boot` | doesn't touch graphics, hands control to the EFI stub |
| GRUB2 | its own video subsystem with GOP as one driver; the framebuffer is passed as a Multiboot2 tag |
| Limine | sets the mode itself and describes it in its own protocol structure |
| EugeneOS | sets the mode itself with `SetMode` and passes base, width, height and stride in registers |

---

## Loading the kernel: how it used to be

No status was checked: the size requested was "a megabyte and hope", the
address `0x100000` was taken on faith without reserving it, and a missing
`kernel.bin` meant a jump to whatever happened to be at that address. Instead
of `jmp $` on a black screen, there is now a screen with the reason and the code.

---

## The editor: from typewriter to editor

The editor buffer used to be a static 32 KB array inside the kernel image,
and a larger file was **silently truncated**: `kernel.asm` (over 280 KB) opened
at 11 %, and saving destroyed the rest. The length was found by searching for
a zero byte, so a zero inside a file also cut it short.

Worse: `EditorCursor` was both the write position and the end of the text.
Characters could only be appended, `Backspace` only erased the last one, and
the arrows moved the **screen**, not the caret. It wasn't an editor, it was a
typewriter with scrolling.

Now the length (`EdLen`) and the caret are separate, insertion and deletion
work anywhere, and the 4 MB buffer lives in its own area at `0x7100000` — which
made the kernel 32 KB smaller.

Once files started loading in full, protection was needed: without the
`BINARY FILE - READ ONLY` mode, `EDIT KERNEL.BIN` would open the kernel for
editing, where one stray key and `F2` would ruin it for good.

`F3` (go to line) exists because FASM reports errors by line number.

---

## Why the graphical shell was rebuilt

At first there were two window systems, written three months apart:

- `libgui/gui.c` — a new layer with partial screen updates, a proportional
  font and an event queue. Only the demo used it;
- `userland/shell.c` — the real shell, with its own 64-glyph font (upper case
  only), its own frame buffer, and a full-screen redraw every frame.

A window's behavior in the shell was an `if/else` branch **inside the render loop**:

```c
if (w->app_type == APP_CONSOLE)       { ...draw the console... }
else if (w->app_type == APP_EDITOR)   { ...draw the editor... }
else if (w->app_type == APP_EXPLORER) { ...draw the explorer... }
```

Every new app meant editing the renderer, and the shell never got the partial
updates. The two layers were merged into one, split the way Windows 3.1 does it.

---

## Programs in a window: where the time went

The first working run of DOOM in a window gave about ten frames per second.
Three things ate the time, and none of them was the game.

**Two of three tasks did nothing.** The scheduler splits time between *ready*
tasks, and three were ready: the kernel polled flags in a loop, and the shell
spun `wm_pump()` with no events. The game got a third. Now the kernel does
`hlt`, and the shell calls `syscall 45` when a loop iteration had nothing to do.

**Hidden things were painted under the window.** `paint_pass` painted the
desktop and every window bottom to top over the whole dirty rectangle — twenty
times per second. Now everything under the topmost window that fully covers the
rectangle is skipped.

**A division per pixel.** `gui_bitmap_fit` divided for every pixel. For 32×30
icons that didn't matter; on a screen-sized canvas it was hundreds of thousands
of divisions per frame. Now columns are computed once per call.

Three more traps:

- **A 640×400 canvas** made the game draw off-center: DOOM centers its frame
  for the "screen" size, and everything that didn't fit was cut off. Now the
  canvas is screen-sized.
- **A canvas from the shell's heap** left the window black: `PagingCloneSpace`
  makes the heap private, so the child drew into its own copy. Now the kernel
  provides the canvas in the shared part of the address space.
- **The window closed while the game was loading**: the shell asked "is the
  child alive" in the gap between the launch request and the task existing.
  Hence `SpawnBusy`.

---

## Program text in a window

Text calls draw straight into the framebuffer, bypassing blit. At first they
worked as before — and DOOM's startup log landed on top of the whole shell.
Then they were disabled for tasks with a canvas — and text just vanished: a
program that only prints showed nothing in its window. The launch dialog would
have had to ask "window or fullscreen", making the user know whether a program
draws graphics or prints text.

The fix is a text buffer and one rule: show the text until the first frame is
drawn. The question in the dialog disappeared by itself.

At first the window closed together with the program — and `HELLO`, which
prints and exits within milliseconds, disappeared before it was ever drawn.
Now a window with a result is closed by hand.

---

## TCP: hunting the bugs

Three different problems looked the same — "could not connect".

1. `ParseIp` saves and **restores** RSI, so the port was parsed from the start
   of the line: `80` became `10`.
2. One message for every case explained nothing. The reasons were split into
   five, and the most important is `RST`: the packet **arrived**, the protocol
   works, only the port is closed.
3. A counter of received segments showed that `10.0.2.2:80` was silent not
   because of our bug — nothing was listening on the host, and the firewall
   dropped packets silently. The test against `1.1.1.1` worked on the first try.

The first version of `GET` didn't send `Host:` — and Cloudflare answered `403`
with code `1003` ("direct IP access not allowed"). With the header, the same
command gets `200 OK`.

---

## Self-hosting: test protocol

Recorded on a copy of the disk in QEMU:

| Step | Result |
|---|---|
| `EDIT KERNEL.ASM` on a 302,746-byte source | opened in full, `SIZE 302746` in the title |
| `F3` → line 4745 | `LINE 4745 COL 1` |
| 39 × `→`, `Delete`, type `3` | `Version 2.0` → `Version 3.0` **in the middle of the file** |
| `F2` | saved, size unchanged |
| `RUN FASM.BIN KERNEL.ASM K.BIN` | `4 passes, 47960 bytes` |
| `INSTALL K.BIN` | `INSTALLED. PREVIOUS KERNEL SAVED AS KERNEL.BAK` |
| `REBOOT` | the system started with `EUGENE OS  Version 3.0` |
| `KERNEL.BAK` vs reference | byte-for-byte identical to the previous kernel |

The same source assembled inside the OS and with fasm on Windows gives
byte-for-byte identical files (`cmp` is silent over 78,712 bytes).

Known gap: the backup only helps while the system still boots. A bootloader
menu entry to start `KERNEL.BAK` would close it.

---

## FAT32: checked against a model

Before being ported to assembly, the algorithm was tested with a C model
(`fat32_model.c`, structured one-to-one with the assembly) against images made
by third-party code, and read back by an independent implementation, `pyfatfs`.
Images were checked with `fat32_fsck.py` (cluster leaks, cross-links, FAT copy
mismatch, size vs chain length; fixed-size VHD only).

```
files of 0/1/511/512/513/4096/24424/150000/300000 bytes  — bit-exact
overwrite 300000 → 1000 → 300000 → 512 → 0 → 65536       — no leaks
30 write/delete cycles of 200 KB                         — FAT returns to its initial state
300 files (directory grows past one cluster)             — 0 errors
512-byte and 4 KB clusters                               — both geometries clean
disk overflow (70 MB onto 64 MB)                         — fsck clean
```

> Neither tool has been added to the repository yet.
