# A Linux shell in a window

A principal starts `linux` from the start menu and gets a shell of Linux in a terminal window of the system. The process `linux` runs a Linux kernel of 64 bits in a guest ([guest.md](guest.md)), with the machine of [foreign_systems.md](foreign_systems.md), "The machine of a Linux guest". The virtio console of the guest, the terminal `hvc0` of Linux, is the console of the shell: the bytes that the shell writes become the lines of the terminal, and the keys of the terminal become the bytes that the shell reads. The serial port carries the log of the kernel to the log of the system. `poweroff` in the guest ends the process.

This is the smallest end-to-end form of the work "Linux in a guest" of `ROADMAP.md`: one guest processor, the virtio console, the serial log, the timer and the interrupt window. Disks, the network and a screen of the guest come after it.

## Constraints

- **A guest image is data in a store** ([foreign_systems.md](foreign_systems.md), "The scoping rule"). The kernel and the initial archive are not modules and not in the boot image: no system image depends on them.
- **A foreign concept stays inside the guest** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective"). No process of the system reads an escape sequence of Linux as a command: the process `linux` turns the bytes of the guest into the records of its terminal, and the terminal knows no escape sequence.
- **No new kernel operation.** The process uses `Guest_Run`, `Memory_Map` and `Memory_Protect`, as the guest builder does.
- **A test never depends on the speed of the hardware.** The machine test waits for lines, each with the hang bound only.

## The chosen form

### The guest image in the private store of `linux`

`linux` has the grants **Terminal** and **Store**. Its private store holds two objects: `kernel` (a bzImage or a vmlinux) and `initial_archive` (a cpio archive in the form `newc`). At its start, `linux` reads the kernel into the top of the memory of the guest, parses it, and reads the archive to the place that the boot gives it. A store that lacks one of them, an object too large for the memory of the guest, and a kernel that the parse refuses each give one line of the log and one line of the terminal, and the process stops with `Refused`.

The machine test writes the two objects on the data disk (`modustool test linux`). A way for a principal to put an image in the store is a later work.

The reasons:

- The store is the one place of the data of a principal, and it checks each block that it reads.
- The kernel of Nixpkgs is 13 MB: in the boot image, each machine would load it, and the boot image would hold a foreign binary.

### The initial archive of the test

The tool writes a cpio archive with a static `busybox` of Nixpkgs (`MODUS_LINUX_GUEST_BUSYBOX`), the nodes `/dev/console` and `/dev/ttyS0`, and `/init`, a link to `busybox`, so that Linux runs the `init` of busybox. Its `/etc/inittab` installs the links of the applets, mounts `/proc` and `/sys`, loads the virtio modules, writes `modus-guest-ready` on the console, which is the serial port, and runs a shell on `hvc0`, the node of the first virtio console (229, 0).

### The virtio modules

The kernel of Nixpkgs builds `virtio_ring`, `virtio`, `virtio_mmio`, `virtio_console` and `virtio_blk` as loadable modules, not into the kernel: without them the devices that the command line declares (`virtio_mmio.device=4K@...`) have no driver. The flake gives the five modules decompressed (`MODUS_LINUX_GUEST_MODULES`), and the archive holds them in `/lib/modules`. The script `/etc/modules.sh` loads them with `insmod` in the order of their dependencies, and gives `virtio_mmio` the words `virtio_mmio.device=` of `/proc/cmdline` as its parameters: the command line that the machine writes is the one place of the windows of the devices. Refused: a kernel built for the guest, with the modules in it. It is a second kernel to build and to trust, for five modules that the kernel of the distribution has. `/sbin/poweroff` is a script that runs `halt` ("The end of the guest").

### The machine

- **The memory of the guest comes from the budget.** At its start, `linux` reads the pages that its granted budget holds, keeps a reserve of 1 920 pages for its terminal, its store client and the records of the guest process, and gives the rest to the guest less its nested page table, in whole MiB. The least is 128 MiB: the bzImage of Nixpkgs unpacks into about 56 MiB above its place at 16 MiB, and the initial archive and the copy of the image wait above it. Below the least, the guest does not start, and the window says so. The stated budget asks for the least; a larger grant gives a larger guest. A machine resource is a value of the plan of principal 0; the plan gives no page of such values yet, so the granted budget is that value.
- **The memory switches page by page.** The kernel switches each page of the memory of the guest between `Write` and `Execute` at its fault ([guest.md](guest.md), "The switch of a page"), so the process maps the memory once and gives no access in its loop.
- **One guest processor.** The controllers 8259 give the interrupts, and Linux runs on one processor with no local APIC. The kernel takes 32 guest processors for each guest ([guest.md](guest.md)), but the machine of `linux` cannot start a second one: Linux brings up another processor through the local APIC, which the machine does not have. The count of the processors comes from the threads of the budget once the machine has the APIC (`ROADMAP.md`).
- **The shell is on the virtio console.** The driver of the guest posts buffers in the receive queue of the console; `linux_machine_console_input` writes the keys into them and raises the line of the device. The transmit queue gives the bytes of the shell to a capture that `linux_machine_console_output_take` empties at each exit, in order.
- **The serial port carries the log of the kernel.** `serial_output_take` gives the bytes that the kernel wrote since the last call; `linux` writes each line as the log fact `linux: guest: <line>`, and the window does not show it. Its early messages and its panics are there: the serial port needs no module. The port 8250 still takes input, as a machine of a build needs no keys.
- **An idle guest waits for the time of the machine.** The guest builder jumps the clock of the guest to the next tick at `hlt`, so a build never waits. A shell must wait for the keys of the principal. With `waits_for_input`, the machine gives the step `Waiting` at a `hlt` with the interrupt flag set and no interrupt waiting. `linux` then waits for a key, or until the next tick of the timer of the guest in the time of the machine, whichever comes first. It gives the time that passed to `linux_machine_resume`, which moves the clock of the guest, at most to that tick, and raises the lines. So an idle guest uses no processor, and its clock follows the time of the machine while it waits; while it runs, its clock moves at each exit, as in a build.
- **The interrupts of the guest.** The machine asks for each interrupt of a line ([guest.md](guest.md), "The interrupt window"): a key typed while the guest runs with its interrupts off reaches it at its next `sti`.
- **Each port that no device has** reads as all ones and takes each write: the probes of Linux for a keyboard controller and for other legacy devices then find nothing.

### The console line

`guest_os.Console_Line` turns the bytes of a console of the guest into lines. `linux` keeps one for the virtio console, which the window shows, and one for the serial port, which goes to the log. A line keeps what the guest writes now, with a cursor:

- a printable byte writes at the cursor and moves it; `\r` puts the cursor at the start; `\b` moves it back one place; a tab moves it to the next multiple of 8;
- `\n` ends the line: `linux` writes a line of the shell to the terminal and as the log fact `linux: shell: <line>`, and a line of the kernel as the log fact `linux: guest: <line>`;
- the sequences `ESC [ <number> K`, `C` and `D` erase to the end of the line and move the cursor; each other sequence is read whole and does nothing; each other control byte does nothing;
- a byte of 128 or more becomes `?`: a byte of the guest never makes a sequence of UTF-8 that the terminal or the log reads;
- a line ends at once, as if `\n` came, when it reaches the width of the window: the columns of the terminal, at most `CONSOLE_LINE_BYTES` (192).

The line that does not end yet (the prompt of the shell and what the principal types) is the edit line of the terminal, with its cursor.

### The keys

A character key gives its UTF-8 bytes. Enter gives `\r`, Backspace `0x7F`, Tab `\t`, Escape `0x1B`, and Control with a letter the control byte of that letter. The four arrows give `ESC [ A` to `ESC [ D`, Home `ESC [ H`, End `ESC [ F` and Delete `ESC [ 3 ~`, for the line editing of the shell. Each other key gives nothing.

### A paste

A paste of the terminal gives up to the limit of its clipboard at once, and the virtio console takes what the buffers that its driver posted hold. The bytes of the keys wait in a queue of `linux` (`PENDING_INPUT_BYTES`, 8 KiB) and go to the guest as it posts buffers, in order, the run past the end of the queue after the run before it. A key goes into that queue whole or waits in the ring of the terminal: no character is cut in two and none is dropped.

### A resize of the window

The terminal gives `linux` the columns and the rows of the window at each resize. `linux` gives them to two places:

- the console line takes the columns as its width, so a long line of the guest wraps at the edge of the window;
- the virtio console takes the columns and the rows in its configuration, and raises its configuration interrupt when the driver of the guest negotiated `VIRTIO_CONSOLE_F_SIZE`. Linux then gives the size to the terminal `hvc0`, and the program in the foreground of the shell gets `SIGWINCH`.

The fact `Window_Resized` says only what the machine took: the width of the line and the size of the device. That the shell got the size, the shell says: the machine test runs a program that prints `stty size` at its `SIGWINCH`.

### The status line

The status line of the window says "Linux starts" until the shell writes its first byte on `hvc0`, then it is empty. A guest that halts before its shell started says so, and the log of the kernel holds why. Each line that refuses the start says what did not happen ("The guest did not start"), the cause, and what a principal can do when `linux` knows it, as `docs/WRITING.md` asks.

### The end of the guest

- **`poweroff` halts the guest.** With `acpi=off`, Linux has no way to turn the machine off: its power off returns, `init` exits, and Linux panics. Its halt runs `hlt` with the interrupts off, which the machine reads as `Halted`. So the initial archive gives `poweroff` the form of `halt`. `linux` writes "Linux halted. The guest ended." in the window and the fact `linux: the guest halted after ...` in the log, ends the guest and stops with `Done`.
- **A guest that fails** (a triple fault, an instruction that the decode refuses, a state that the processor refuses) gives one line with the failure of the machine, and the process stops with `Failed`.
- **A machine with no guest support** gives one line, and the process stops with `Refused`.
- **The close of the window** stops the process; the close of its last handle to the guest process stops the guest.

## Refused forms

- **The kernel and the archive in the boot image.** A foreign binary in the system description, against the scoping rule, and 13 MB more for each machine.
- **An emulator of a terminal of Linux written for `linux`, or in the terminal of the system.** The terminal draws records, not escape sequences; an emulator in it puts a foreign concept in a process of the system. The console line reads the few sequences that the line editing of the shell writes, inside `linux`, and drops the rest. A program of the guest that draws a whole screen (an editor) needs a VT engine: the later form is the engine of [ghostty_vt.md](ghostty_vt.md) behind a terminal holder, not a second emulator.
- **The shell on the serial port.** A serial port carries no size: a resize of the window never reaches the shell. The serial port keeps the log of the kernel, which needs no module and holds the early messages and the panics.
- **Keys sent to the shell to set its size** (`stty rows ... cols ...` typed by `linux`). They would write in the line that the principal edits, and in the input of the program that runs.
- **The clock of the guest that jumps at an idle `hlt`.** The guest then runs its timer as fast as the processor goes and never waits for a key: a processor is busy for an idle shell.
- **A device that turns the machine off** (ACPI). ACPI needs the tables of a firmware and their interpreter in Linux; the halt gives the same end with no table.

## Subtle points

- **The bytes of the guest are hostile.** The console line bounds the line and the number of a sequence; a sequence of any length costs no memory and writes nothing. No byte of the guest reaches the terminal unchecked.
- **The time while the guest waits.** The wait ends at the next tick in the time of the machine, and `linux_machine_resume` moves the clock by the time that passed, at most to that tick, so a late wake gives the guest one tick, not a burst of them.
- **A key while the guest runs** goes to the buffers of the virtio console before the next `Guest_Run`, and the line of the device rises at once.
- **The memory of the guest switches page by page.** The kernel gives each page of the memory of the guest `Write` or `Execute` at the fault that asks for it ([guest.md](guest.md), "The switch of a page"). Switched by regions of 2 MiB, the decompressor of the bzImage never completed an instruction: it executes and writes its data in one region. Linux also patches its own text with `memcpy` at its start (`text_poke_early`), and `memcpy` writes the page that holds it: the machine does that write for it (the exit `Writes_Own_Page`) when it is a `mov` of 64-bit code at the address of the exit. A `rep movs` or another instruction there stops the guest with the line `linux: the guest stopped: the instruction at ... writes the page that holds it ...`.
- **Two answers of the machine that Linux needs.** Linux writes the debug registers (`mov dr7`): each access exits, and the machine keeps their values, so no breakpoint of the guest reaches the processor. Its one-shot tick uses the mode 4 of the timer 8254: a strobe at the end of the count, which raises the line once for each count, as the mode 0 does.
- **The command line takes two words for a virtual clock.** `printk.time=0`, so the lines of the kernel read the same in each run and the test names them; `initcall_blacklist=jent_mod_init`, because the jitter entropy source measures a clock with no jitter and reads it millions of times ([foreign_systems.md](foreign_systems.md), "The chosen form").

## State

Built and checked by host tests: the console line and its width, the queue of a paste and its wrap, the input and the output of the virtio console, its size and its interrupt, the memory of the guest from the budget, the wait of an idle guest, the keys, the debug registers and the mode 4 of the timer of the machine, the write of an instruction that writes its own page, and the archive of the test. Built and checked by the machine test part `linux`: the bzImage of Nixpkgs boots from the store to the shell of busybox, the virtio modules load, the test types a command in the terminal window and reads its output on `hvc0`, starts a program that waits for `SIGWINCH`, resizes the window and reads the size that the program prints, and `poweroff` ends the process. Left: several guest processors, which need a local APIC in the machine, the virtio disks and network for a principal, a screen of the guest, and a way to put a guest image in the store (`ROADMAP.md`).
