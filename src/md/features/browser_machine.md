# modus in a web page: the browser machine

A browser machine is a machine that a page of a web browser gives: the kernel of modus built for WebAssembly, its processors as workers on one shared memory, and its devices played by the code of the page. The modules of the system run on it as they are built today, with the same hashes. This file records why the browser machine exists, the form of each part, the forms that were refused, and the order of the work. The terms are in [`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md), "Browser machine" and "Software processor", in [`docs/glossary/devices.md`](../../../docs/glossary/devices.md), "Device model", and in [`docs/glossary/network.md`](../../../docs/glossary/network.md), "Link relay".

## Why, and for whom

- **A reader tries modus in one click.** Today a reader who wants to see the system builds it, or downloads the release image and starts QEMU. A page of the site that starts the system in the browser shows the desktop, the console and the properties at work, with nothing to install.
- **A developer embeds it.** A guide shows a console of modus beside its text, and the reader types the command that the guide explains. A page of another site embeds a machine in an `iframe`.
- **A demonstration on the site.** A news entry or a release links to a page that starts that release, so a reader sees the change on the system itself and not on a picture.

The browser machine is not a machine for production. A principal who keeps documents keeps them on a real machine or under QEMU: the browser can erase the storage of a page ("The subtle points").

## The constraints

- **The real system, in one serious form.** The browser machine runs the kernel of modus, its root service and its modules, with the same rules. A slow emulation of a whole PC is not this design ("The refused forms").
- **The same list of hashes.** A system is a list of hashes ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). The browser machine runs the modules of the boot image with their hashes. Only the kernel and the boot program differ, because only they meet the hardware.
- **No change above the kernel.** The handles, the rings, the root service, the loader, the device services and every module see a machine, not a page.
- **The interface thread of the browser never blocks.** No processor and no device model runs on the thread that holds the document. That thread only reads the events of the document, shows the screen and starts the sound.
- **Each layer works alone.** Each layer of "The order of the work" adds one capability to a browser machine that works.

## What others did

- **unkernel** ([github.com/pithings/unkernel](https://github.com/pithings/unkernel), [unkernel.dev](https://unkernel.dev)) runs Linux 7.3 compiled to WebAssembly as `arch/wasm`, with a real MMU in software. User programs are unmodified aarch64 binaries on kwemu, an emulator in Zig linked into the kernel. kwemu walks the page tables of the kernel straight out of the linear memory and never writes an entry. It runs blocks decoded once into ops, and compiles hot blocks to WebAssembly modules at run time. JSPI (`WebAssembly.Suspending`) switches the tasks of the kernel, each on its own stack. Small paravirtual devices talk to a JavaScript host: block on IndexedDB, network through a Wisp proxy and a TCP/IP stack in JavaScript, a framebuffer, input and sound. Its numbers, measured by the project (README, 2026-11-14 to 2026-11-18): the kernel reaches `/init` about 70 ms after its start and the Alpine prompt appears 0.3 s after `node` starts, with a download of about 10 MB; `getppid` takes about 170 ns, against 110 ns natively and 1.7 µs under `qemu-system`; the interpreter runs 250 to 300 million guest instructions each second under Node, and the compiled tier makes real work 1.6 to 2.3 times as fast. Its notes (`.agents/kernel.md`, `.agents/kernel/smp.md`, `.agents/kwemu.md`) name its limits: a task moves to another processor only where its JSPI stack can be dropped, several processors cannot be suspended, and a trap of the kernel ends the session.
- **Kernarium** ([github.com/imxieyi/Kernarium](https://github.com/imxieyi/Kernarium)) gave unkernel the idea: User-mode Linux compiled to native arm64 code on iOS, and the user programs on an emulator of the iSH kind, with a JIT. The kernel runs natively, and only the user code is emulated.
- **linux-wasm** ([github.com/joelseverin/linux-wasm](https://github.com/joelseverin/linux-wasm)) gave unkernel its first `arch/wasm`. It builds Linux with no MMU: the programs are compiled to WebAssembly, and `fork` and shared mappings are lost. Its README names the MMU as future work.
- **QEMU** builds for WebAssembly: QEMU 10.1 with its interpreter of TCG for 32-bit guests, and the configure script of its master branch takes `--cpu=wasm64` for 64-bit guests. A backend that compiles hot translation blocks to WebAssembly modules, with the interpreter for the other blocks, was at its fourth series of patches on the mailing list in January 2026 ([PATCH v4 00/33](https://lists.libreplanet.org/archive/html/qemu-devel/2026-01/msg04985.html)). The whole machine is emulated: the kernel, each kernel entry and each page fault too.

What this design takes: the kernel compiled to WebAssembly, the user code on a software processor that walks the page tables of the kernel, the compiled tier for hot blocks, and devices that the code of the page plays. What differs: the kernel of modus needs no stack for each thread, so it needs no JSPI to switch threads ("The switch of threads, with no JSPI"); the devices of the page play the virtio devices that the device services already drive, so no module changes ("The devices of the page").

## The chosen form

1. **The kernel** is built for WebAssembly once, with its own hash, at entry 0 of the system description of the browser machine. Every other entry is the hash of the boot image of today.
2. **The processes** run their x86-64 code, as the build writes it today, on the software processor: a part of the kernel of the browser machine that decodes, runs and compiles their instructions, and that translates each address through the page tables that the kernel writes, in the format of x86-64.
3. **The processors** are workers of the browser on one shared memory: one instance of the kernel in each worker, and the memory as the physical memory of the machine.
4. **The devices** are device models in the code of the page: virtio devices at the fixed places of the bus of the test machine, the standard VGA display, the PS/2 keyboard, the virtio tablet, the serial port and the clock of the machine.
5. **The boot** is a build of the checks of the boot program for WebAssembly, which the page runs before the kernel.

## The kernel for WebAssembly

### What Odin gives

The Odin compiler of the flake (`dev-2026-11` of the fork) lists these targets of WebAssembly: `freestanding_wasm32`, `js_wasm32`, `wasi_wasm32`, `orca_wasm32`, `freestanding_wasm64p32`, `js_wasm64p32` and `wasi_wasm64p32` (`odin build . -target:?`). `wasm64p32` has 32-bit pointers and a 64-bit `int`; the Odin project states that it is not `wasm64`, and Odin has no target with 64-bit memory addresses (memory64). `js_` gives a runtime in JavaScript and an allocator; `wasi_` gives the system interface of WASI; `freestanding_` gives neither.

The kernel is built for `freestanding_wasm64p32`, with the features `atomics` and `bulk-memory`, and linked by `wasm-ld` with a shared memory that the page creates and gives. Today the build gives `bulk-memory` only (`BROWSER_MACHINE_KERNEL_TARGET_FEATURES`): the memory is not shared yet, and the idle wait with `atomics` waits on a shared memory only.

- **Why `bulk-memory` from the first build.** With no feature, each copy that the compiler writes calls the `memcpy` of the runtime of Odin, a loop of one byte. The software processor copies its register file (128 bytes) before each instruction, so that a fault gives back the registers of before. In Node, under a loaded host, that copy took 60 % of the time of the start of the console image, and the image check of the root service took 43 s for 3.4 MB. With `bulk-memory`, each copy is one `memory.copy`: the console prompt came at 12.9 s in place of 76.6 s, on the same host at the same load.

- **Freestanding**, because the kernel is freestanding on hardware too: `"contextless"`, no allocator, no runtime of JavaScript. Its imports from the page are a few procedures that the arch layer declares.
- **A 64-bit `int`**, so a record of a contract with `int` fields keeps its layout. A contract holds no pointer: an address in a record is a `u64` ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Assumptions").
- **32-bit pointers inside the kernel.** The physical memory of a browser machine is below 4 GiB, and the kernel addresses it with no translation: a physical address is an offset in the linear memory. A pointer of the kernel to its own tables is 4 bytes; no process and no record sees one. This touches the assumption "64 bits only" ("The contradictions").
- **Memory64 refused for now.** Safari has no memory64, and Chrome and Firefox limit it to 16 GiB. A browser machine needs no more than 4 GiB of physical memory.

The modules are not built for WebAssembly: they stay `freestanding_amd64_sysv`, with SSE2 as their one vector form ([`docs/SIMD.md`](../../../docs/SIMD.md), "2. One form: SSE2").

### What the arch layer becomes

The kernel keeps its code above the arch layer. Each part below has a file `*_amd64.odin` and a file `*_wasm64p32.odin`, by the suffix rule of Odin; the assembly files of `nasm` are in the build of hardware only.

| Part on hardware | On a browser machine |
|---|---|
| `syscall` and the kernel entry, `iretq` and `resume` | An exit of the software processor of the kind `Enter`; the return is the next run of the software processor with the frame of the thread |
| The frame of a thread, the extended state area | The register file of the software processor: the same `Frame` record, and the SSE registers and `MXCSR` in the area |
| `cr3`, `invlpg`, `processor_sync` | The table of the software processor of this processor, and the flush of its translation cache and of its decoded blocks ("Coherence") |
| The direct map | No translation: `direct(physical)` is the offset in the linear memory |
| The protection of the kernel by its own page tables | WebAssembly: the code of the kernel is not in the linear memory, so nothing writes it or executes data |
| The kernel stacks with their guard pages | One shadow stack in the linear memory for each processor, and the stack of the engine ("The subtle points") |
| The APIC timer, the 8254, `rdtsc` | A deadline word of each processor and the clock of the page ("The timer and the cycle counter") |
| The interrupts and their vectors | A controller in software for each processor: one bit for each vector that waits, set by the device models and the other processors, and a word that wakes its idle wait |
| `hlt` in the idle wait | `memory.atomic.wait32` on the word of the processor, with the next deadline as its bound |
| The IOMMU, `Guest_Run`, the steal time | None: the paths of a machine with no IOMMU, no virtualization and no steal-time record ([missing_hardware.md](missing_hardware.md), [guest.md](guest.md)) |
| The processor counters | `Unsupported`, as on a machine with no counters ([processor_counters.md](processor_counters.md)) |
| The ACPI table of the processors | The count of processors that the page gives |
| The I/O ports and the device memory | A request to the device models ("Ports and registers") |

The kernel reads and writes process memory (the kernel ring of a thread, a table that a command names) by its virtual address, through `user_copy_from_process` and `user_copy_to_process`. On a browser machine that access walks the page table of the process in software, with the checks of the hardware: present, user, write. A page that the walk does not find gives the same fault as on hardware.

### The arch layer as it is

`odin check` and `odin build` of `src/modulus` pass for `freestanding_wasm64p32` and for `freestanding_amd64_sysv`, from the same source. The build for WebAssembly links with no `env` import: its only imports are the procedures of the page in the module `modus_page`.

- **One name, two files.** Each procedure of the border has the same name and signature on both targets, so no file above the border changes:
  - `instructions_amd64.odin` holds the instruction templates, `cpuid` (`processor_identification_read`) and `rdtsc` (`cycles_now`). `instructions_wasm64p32.odin` holds the register file of the processor of the instance: the control, debug and model-specific registers. A write of `cr3` and `invlpg` reach the translation cache of the software processor.
  - `processor_assembly_amd64.odin` declares each name of `processor.asm`. `processor_loop_wasm64p32.odin` defines the same names: `resume`, `stack_switch`, the idle wait, the extended state in the software processor, the register trials and the labels.
  - `processors_start_amd64.odin` holds the start code of the other processors and its reset and start messages. `processors_start_wasm64p32.odin` starts no worker yet.
- **The direct map.** `boot_info.DIRECT_MAP_POINTER_BASE` is the pointer of the kernel to physical address 0: the direct map on x86-64, and 0 on WebAssembly. `DIRECT_MAP_BASE` and `KERNEL_BASE` stay the addresses of the page tables of x86-64, with no type, so a kernel with 32-bit pointers still writes the same tables.
- **The answer of `cpuid`.** It names x87, SSE, SSE2, `syscall`, no-execute and long mode, and nothing else. So the kernel takes, with no code of its own, the paths of a machine with no APIC in x2APIC mode, no `xsave`, no SVM, no processor counters and no hypervisor. A `Guest_Run` gives `Unsupported`: `guest_enter` stops the instance, and no path reaches it.
- **The exit of the software processor.** The kernel part `software_exit`, with host tests, gives the event that a processor of x86-64 gives for each outcome of the software processor. A `syscall` is the kernel entry, an exception keeps its vector, its error code and the address of a page fault, and the end of a slice is no event of the thread. `hlt` of a process is a protection fault. The export `modus_processor_loop_run` builds the frame from that exit and calls `kernel_interrupt`, as the stubs of `processor.asm` do. At the end of a slice, and before the first instruction of each call, it gives the thread the highest interrupt that waits; with none, it returns `Slice_Ended` and the thread goes on at the next call.
- **The ports of a process.** A process runs with IOPL 0, so the permission map of the task state of its processor decides each `in` and `out`, as on the processor: `ports_switch` opens in it the ports of the ports handles of the process. The software processor reads that map before the device sees the access: one closed port of the access, or a bit past the end of the map, gives a protection fault with error code 0, and no register changes. An open port goes to `port_read_8` and `port_write_8`, the imports of the page; an access of 2 or 4 bytes is that many accesses of one byte, the lowest port first, because the devices of the page have registers of one byte. The string forms `ins` and `outs` stay an invalid instruction: `modus:system` gives a process no routine that runs them.
- **The copy with the memory of a process.** `user_copy_from_process` and `user_copy_to_process` take the address of the process as a `u64`. On x86-64 they are the copy of `rep movsb` of today. On a browser machine they call the kernel part `process_memory`, with host tests, which walks the table of `cr3` through the walk of the software processor with the checks of a user access, and checks each page of the range before the first byte moves. The caller checked the range under the process lock (`user_range`), so a refused walk is a fault of the kernel, and the instance stops, as a page fault of the kernel in its copy stops a processor.
- **The interrupt controller.** `apic_amd64.odin` holds the local APIC, the 8254 and the search of the processors; `apic_wasm64p32.odin` gives the same procedures over the kernel part `virtual_interrupt_controller`, with host tests. Each processor has one bit for each vector that waits, which a sender sets with an atomic OR and its processor takes, the highest first, and a periodic deadline of the timer on the clock of the page. Deadlines that the processor missed give one tick, as the one bit of the APIC, and the next deadline is one period after the clock. `apic_send` sets the bit, then the word of the idle wait of the target, and notifies it; a start command or a processor that does not exist is refused and counted. The end of an interrupt clears nothing: a vector leaves the controller when the processor takes it. The device lines come from the page: where the first processor checks its timer, it calls the import `page_interrupt_lines_take`, which gives the lines of the 8259 that the models raised since the last call, one bit each, and clears them. Line n waits as the vector 32 + n, as the 8259 of the kernel programs it, and the kernel signals it to the process that holds the line: the keyboard is line 1, the mouse line 12. Line 0 and each bit past line 15 name no device of the kernel: the kernel drops them and writes their count on the log at each doubling. A poll, not an export that the page calls: an interrupt that comes during the idle wait of a build with no atomics waits for the bound of the wait, at most one tick, and no call enters the kernel while the kernel runs. `acpi.odin` holds the walk of the ACPI tables, which both targets compile: a browser machine has no ACPI root.
- **The exports.** The kernel exports `entry`, `modus_processor_loop_run`, its memory and `__stack_pointer`, the global of its shadow stack, and nothing else. The page needs the global: WebAssembly gives no other way to drop the frames that a throw skipped ("The loop"). The demonstration page of the software processor has its own package, `software_machine_demonstration`, so its procedures `modus_vm_*` are not in the kernel. `modustool check` runs `odin check` of the kernel for `freestanding_wasm64p32`, since no build of the image compiles it.
- **A start in an engine.** The host of the page ("The page and its host") starts the kernel in Node through the root service: the root service is built from the boot image, and its first thread runs on the software processor. With no boot image, the start stops after the mark `kernel: ok` with its line. With a boot image, `modustool browser-machine boot` waits for `root: the machine is usable`, types `help()` and Enter on the PS/2 keyboard of the host (scan code set 1, the layout United States), and requires the line of `help()` for `shutdown` from the console, written by the input service, the compositor and the console through line 1, and a framebuffer with pixels that are not black. The run then ends, with the times of the typed line and of the answer as measures.
- **One instance for each worker.** The linear memory is shared, so a global of Odin is in the memory of every worker. The register file and the software processor are thread-locals. The word that the idle wait waits on is in the shared memory, one for each processor.
- **The idle wait.** It clears the word of its processor, delivers each interrupt that waits, and returns when one came, as `hlt` returns after one. Else a build with the feature `atomics` waits with `memory.atomic.wait32` on that word until the deadline of the timer, at most one tick. A build with no atomics has one processor and calls the import `page_idle_wait`, which suspends the worker. `interrupt_window` delivers each interrupt that waits, as the window between `sti` and `cli` does.

These parts are not done yet, and each one stops the instance or stays inactive in place of a wrong result:

- **The shared memory.** The build links its own memory. A build for several workers needs `--import-memory` and `--shared-memory` at the link.
- **The counted kernel** (`KERNEL_EDGE_COUNTERS`) is a build for x86-64 only. The build for WebAssembly refuses it with an `#assert`.

### The page and its host

The page of a browser machine is four static files, which the site writes and `modustool browser-machine` writes beside the kernel and the boot image of the page (`build/browser_machine/`). They are in `tools/modustool/build/browser_machine/`.

- **`browser_machine_host.js`, the host.** One ES module with no document: it is the one place of the border of the page. It gives the seven imports of `modus_page`, writes the boot record and its memory map, plays the ports, and drives the processor loop. The worker imports it, and `modustool browser-machine boot` runs it in Node. So Node is not a second set of models ("The refused forms"): it runs the same models as the page.
- **`browser_machine_worker.js`, the processor.** A module worker: it compiles the kernel, fetches the boot image, starts the machine, and runs the loop in slices of 8 ms. Between two slices it yields to its event loop, so it receives the keys, the pointer and the requests of frames. It sends the stages of the start (`{kind: "stage"}`, "The boot stages of the page"), the lines of the serial port and a copy of the framebuffer.
- **`browser_machine_page.js` and `browser_machine.html`, the document.** It starts the worker, draws the stages of the start on the canvas until the first frame of the compositor, then asks one frame at each animation frame, draws it on a canvas 2D with `putImageData` (blue first in the framebuffer, red first in `ImageData`), shows the serial port, and sends each key and each move of the pointer of the canvas to the worker. It runs no processor and no model.
- **`browser_machine_console.html`, the console document.** It starts the same worker with the console image and no framebuffer. The worker sends the lines of COM2 in batches, one message for each slice (`{kind: "console", lines}`), and the document draws them ([console_renderers.md](console_renderers.md), "Variant C: dom_terminal"). Each key and each paste of the document goes to the worker as text (`{kind: "console_type", text}`), which the worker types on COM2. So the document never runs the kernel: a long slice never delays a key, a scroll or a frame of the page.
- **The trust of the description, beside the image.** The page has no BLAKE3, so the tool writes the hash of the system description of each signed boot image of the page beside it: `boot.image.trust` and `console.image.trust`, 64 hexadecimal digits and a line feed. The worker fetches `<image>.trust` and gives the hash to the host, which writes it in the trust of the boot record, as `modustool browser-machine boot` does from the image in Node. With no file, the machine starts with no trust and says so on the serial port. A file that is not one hash stops the start: a damaged trust is not an absent one. The file proves no origin: the server of the image serves it too ("The boot", "What the check proves").

The physical memory of the machine is the linear memory of the kernel. The host grows it to its size (512 MiB in the page) and places, from offset 0:

| Range | What | In the memory map |
|---|---|---|
| From 0 to the end of the memory that the kernel links | The data and the shadow stack of the kernel | None |
| One page | The boot record | `Boot` |
| One page | The memory map: two ranges | `Boot` |
| The boot image, to a page | The boot image of the page ("The boot image of the page") | `Boot` |
| The framebuffer, to a page | 1280 × 800 pixels, blue first, one line of 1280 pixels | None: device memory, as on QEMU |
| The rest | The free page frames | `Free` |

- **The clock of the machine** counts from the creation of the machine, as the cycle counter counts from a reset. So the stage "firmware" of the boot is the time of the page before the kernel, not the time since the start of the computer.
- **The loop.** `entry` ends in the throw of its stack switch. The host then calls `modus_processor_loop_run` with a budget of 100 000 instructions. `Kernel_Returned` and `Slice_Ended` both mean "call again": the thread goes on at the next call. After each throw of the loop, the host sets the exported `__stack_pointer` back to its value before the first call: the throw skipped the end of each frame, and without the reset each throw leaks those frames. With the boot image of the build, 572 throws took the pointer from the top of the stack, 1 MiB, to 2720, and the next frame wrote below address 0, a trap of WebAssembly. `Idle` waits one millisecond. `Budget_Refused` is a fault of the host, and stops the machine. `page_processor_stop` and a trap of WebAssembly end the machine.
- **The idle wait.** In Node, and in a worker of a page with cross-origin isolation, `page_idle_wait` sleeps with `Atomics.wait` until the deadline. In a page with no isolation it returns at once, the kernel waits for its deadline in its idle loop, and the messages of the page wait for the next run of a thread. A suspension with JSPI is the form that keeps the events of the page during the wait ("Several processors as workers").
- **The ports.** The host plays the devices that the kernel and the first services reach through ports: the serial port COM1 (`0x3F8` to `0x3FF`: a line for each line feed, the transmitter always empty), the PS/2 controller with its keyboard and its mouse (`0x60`, `0x64`: the answers of a reset and of an identification, the keys as scan code set 1 from `KeyboardEvent.code`, and packets of 3 bytes for the mouse; each byte that comes to the head of its queue raises line 1 or line 12 when the configuration byte turns that line on, as the output buffer of the controller does), the clock of the machine (`0x70`, `0x71`: the date of the page in UTC) and the exit device of QEMU (`0xF4`: the stop code). Another port reads all ones and is counted.
- **The device models in JavaScript.** "The devices of the page" places the models in a worker of their own, in Odin. These four ports are the exception: a port is a synchronous call of the processor, and these devices hold a few bytes of state, so they run in the host, in the worker of the processor. The virtio devices stay models in Odin in their own worker.
- **The interactive check is not the page.** The Node run types the keys in the host, between two slices of the loop; the worker of the page sends them from the events of the document the same way. No part of the machine test runs on the page yet ("The machine tests").
- **The check of the border.** `modustool browser-machine` reads the import section and the export section of the file that it builds, and refuses an import that the host does not give, a missing import, an import twice, and an export that is not one of the four. A host test compares each offset of the boot record in the host with `offset_of` of `Boot_Info`, so a field moved in `boot_info.odin` fails in the tool, not in a page.

### The boot stages of the page

A start on the software processor takes seconds, and the screen of the machine stays black until the first frame of the compositor. So each page shows the stage of the start until its end: the canvas of the desktop page draws the list of the stages, and the console page writes the stage in its header.

- **The stages.** The download of the kernel and of the boot image (with its bytes), the start of the kernel and of the root service, the image check of the root service, the start of the services, then the start of the compositor (desktop) or of the console (console). The start ends at the first frame of the compositor, or at the first line of the prompt on COM2.
- **Where the page reads them.** The worker knows the download. The other stages come from the lines of the serial port, which the host reads with `BootStageTracker`: the kernel line of the start of the root service, then three log facts by their key tag (`root.Boot_Image_Agrees`, `root.Process_Started` of `compositor` or `root.Process_Started_With_Terminal` of `console`, `compositor.First_Frame`). A key tag is a fixed function of the name of the fact type ([log_facts.md](log_facts.md), "The serial port"), so the host holds the tags, and a host test of the tool computes each one from its fact type and finds the type in its module.
- **Refused: a stage record of the kernel or of the root service for the page.** The page reads what the system already writes; a record for the page alone is a second log.
- **Refused: the module tag in the match.** It changes at each build; the key tag and the process name in the line are enough.
- **The order.** A stage comes once, and a line of an earlier stage changes nothing: a fact that a later start writes again (a restart by the rescue start policy) does not move the page back.
- `modustool browser-machine boot` prints the time of each stage as a measure.

### The boot image of the page

The root service hashes each file of the boot image at its start, and the software processor runs that work. It hashes each file once: its loads and the resources that it gives take the hash of the entry that the image check verified ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "Layer 1: the signed system description"). Before, each start hashed its module and each import again, and each resource at each give: on the desktop image, the start of the compositor hashed its two pointer themes (2.1 MB) again, and the start took longer than the hang bound of the start policy, so the rescue start policy stopped the desktop before its first frame. The boot image of the build holds each module that a machine test starts, most of them for a test only. So `modustool browser-machine` writes the boot image of the page from the boot image of the build:

- **Its modules.** The modules of `BROWSER_MACHINE_PAGE_MODULES` (`tools/modustool/build/browser_machine.odin`) and their imports in the module table: the services of the start, the holder of each role of the root service, the module of each row of the start list and of the rescue list, the libraries of the windows and the applications of the desktop. A module of the list that the boot image of the build does not hold stops the tool: the page would start a machine with no holder for a role.
- **Its resources.** Each resource of the boot image of the build: the fonts, the pointers, the pages of the manual, the start list and the rescue list.
- **Its signature.** The tool signs it as the image of a boot volume: a new replacement list, a system description of its files and the description signature (`system_description.odin`). The page gives the hash of that description to the kernel as the trust of the boot record.
- **A refused form: one image for both.** The boot image of the build stays whole: a machine test starts its test modules from it, and the page needs none of them.
- **`browser-machine boot <boot image>`** runs the image that it names as it is, so a measure of the whole image stays possible.

### The processor loop

On hardware, `schedule` and `run` never return: `resume` ends in `iretq`, and `schedule_on_a_fresh_stack` switches to the top of the kernel stack. WebAssembly has no instruction that drops the frames of the stack. So each worker runs one loop, an export of the kernel:

1. Run the software processor on the current thread of the processor, until it exits: a kernel entry, a fault, an interrupt, or the end of its slice.
2. Call the kernel path of that exit, as the stubs of `processor.asm` call it today.
3. When that path returns, go to step 1 with the same thread.

A path that ends in `resume` or in a fresh stack calls one import of the page, which throws. The worker catches it, sets the shadow stack pointer back to the top of the stack of the processor, and enters the loop again. A switch of threads costs one throw through the frames of the kernel; a kernel entry that returns to its thread, the frequent path, costs none. The cost of the throw is a measure ("The size and the speed").

### The switch of threads, with no JSPI

The kernel of modus has one kernel stack for each processor, not one for each thread. A thread is its frame and its extended state area: memory of the kernel. The kernel never waits on a kernel stack; a thread that waits leaves its frame, and `schedule` starts on a fresh stack. So a switch of threads on a browser machine is a change of the register file that the software processor runs. No stack of the engine holds a thread, and the kernel needs no JSPI to switch threads.

This differs from unkernel, where each task of Linux has a kernel stack, so JSPI parks the stack of each task. It keeps what unkernel lost:

- **A thread moves between processors at any switch**, as on hardware. In unkernel a JSPI stack belongs to the worker that made it.
- **The control of a thread, the debugger and the fault ring work.** They read and write the frame of a held thread, which is memory.
- **A thread is preempted at any instruction**: the software processor counts the instructions of a slice.

JSPI has one use: the idle wait of a browser machine with no shared memory ("The open questions"). There the worker must return to its event loop to get a message of the page, so its idle wait is an import that suspends until a message or the deadline. With shared memory, the idle wait is `memory.atomic.wait32`, which a worker can run and the thread of the document cannot.

### The timer and the cycle counter

- **The clock.** The kernel reads one import of the page: `performance.timeOrigin + performance.now()`, in nanoseconds. Each worker has its own `performance.now()` origin, so the sum is the one clock of all the processors. The kernel part `time_base` gets a third source beside the 8254 and `CPUID`: the clock of the page, at 1 GHz, with its resolution on the log.
- **The resolution.** The engine coarsens this clock ([High Resolution Time](https://www.w3.org/TR/hr-time-3/): 5 µs when the page is cross-origin isolated, 100 µs otherwise). The charge of processor time at a switch is then a multiple of that step. A budget holds its limit over a period of 100 ms, so the step changes a stint, not the limit ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Processor time").
- **The timer.** A periodic deadline in the controller of the processor, one tick long. The processor loop reads the clock at each call and at the end of each slice of instructions; a deadline that passed is the interrupt of the timer. The idle wait takes the deadline as its bound. A slice is a count of instructions, and each exit costs a part of it, so a loop of cheap kernel entries still sees its tick (unkernel found the same need: `.agents/kernel.md`, "IRQs and time").
- **No interrupt inside the kernel.** An interrupt waits for the next call of the processor loop, the next end of a slice, the idle wait or a window of interrupts of the kernel. The kernel runs each entry to its end, as with interrupts off. A spin of the kernel that waits for another processor reads the words of the other processor; it never waits for an interrupt.

### Several processors as workers

Each processor is a worker with an instance of the kernel on one `WebAssembly.Memory` that is shared. The processor record, the current thread and the shadow stack pointer are globals of the instance, so each worker has its own. A message of one processor to another (a wake, a shoot-down) writes the word of the target and calls `memory.atomic.notify`. The software processor reads that word at the end of each block.

The limits of the browsers:

- **Shared memory needs cross-origin isolation:** the headers `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`. A page in an `iframe` is isolated only when the page above it is isolated and allows `cross-origin-isolated`.
- **A page with no cross-origin isolation runs one processor.** Most pages that embed another one set no isolation, so they get no shared memory. The machine then runs one processor in one worker, the device models in the same worker, and its idle wait suspends with JSPI, so the worker gives the browser its events while the machine waits. An embed does not require isolation: the page reads `crossOriginIsolated` at its start and takes this form when it is false.
- **The count.** unkernel starts half the threads of the device, at most 4 on a desktop, 2 in Firefox and 1 on a phone and in Safari (README, "Try it in the browser"). The page takes the same rule until a measure of modus gives another.
- **The memory is fixed at the start.** The page creates the shared memory with its size and its maximum, and the memory map of the boot gives that size. The memory of a machine never grows, so this matches the model of modus.
- **The data of the kernel is written once.** With a shared memory, each new instance runs the start function that writes the passive data segments, unless a flag says that it is done. The second worker must see that flag before its start (unkernel: `.agents/kernel/smp.md`, "The data-segment flag").

## The software MMU

### The ways compared

| | (a) The x86-64 code of the modules on a software processor | (b) The modules compiled to WebAssembly, each access rewritten | (c) One memory of WebAssembly for each process |
|---|---|---|---|
| **The module** | The same file, the same hash | A second build of each module, a second hash, a second signed list | A second build, a second hash |
| **One module format** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module") | Kept | A second code form in each module, or a second kind of module | A second code form |
| **The modules that the system writes** (`assemble`, `c_compiler`) | Run: they write x86-64 | Do not run: their output is x86-64 | Do not run |
| **A thread** | A frame in memory: it moves, the debugger reads it, it stops at any instruction | A stack of the engine: JSPI for each thread, no move between workers, no register for the debugger, a poll at each loop for a preemption | The same as (b) |
| **The loader** | Unchanged: it maps segments | The page must compile a WebAssembly module for each process: a path outside the loader of the system | The same as (b) |
| **Shared memory and rings** | The page tables of the kernel, as on hardware | The page tables of the kernel, read by the rewritten accesses | No mapping of one memory object at an address of two processes: the rings break ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "6. One communication mechanism between processes") |
| **The order of memory between processors** | Each access of a process is an atomic of WebAssembly ("The subtle points") | The atomics of the source become atomics of WebAssembly | The same as (b) |
| **The speed of computation** | Slowest: an interpreter, then compiled blocks | Faster: native WebAssembly, with a translation at each load and store | Fastest |
| **The work** | A software processor of x86-64 for the user mode, SSE2 included, and its compiled tier | A pass over WebAssembly in the tool, a target of the build, JSPI threads, a new path of the loader, a debugger of WebAssembly | (b), and a new model of memory |
| **The isolation** | Each access goes through the walk and its checks; a fault of the compiled tier can reach the whole memory | Each access goes through the rewritten translation; a missed access in the pass reaches the whole memory | The engine isolates each memory |

Other ways that were weighed:

- **(d) A translation ahead of time.** The tool translates the x86-64 code of each module to WebAssembly at the build, as a cache named by the hash of the module and the hash of the translator. The module keeps its hash. It is an addition to (a), not a way of its own: code that the system writes, and a module from the disk, still need the software processor. It waits for a measure of the start of the large modules ("The order of the work").
- **(e) The MMU of the engine.** The memory-control proposal of WebAssembly can one day give a protection of pages in the engine. It is at an early phase and no engine ships it. When an engine gives the map of one memory at an offset of another, (b) and (c) change; (a) does not depend on it.

### The choice: the software processor

The recommended form is (a). The reasons, in their order of weight:

1. **One system, one list of hashes.** The browser machine runs the boot image of the release. The system description of the browser machine differs only at entry 0, the kernel. A security fix is the same query on both machines. With (b), every module has a second hash, and every release a second signed list.
2. **A thread stays its frame.** The scheduler, the control of a thread, the fault ring, the debugger and the stop of a thread work with no change. With (b) each of them needs a new design for a thread that is a stack of the engine.
3. **The system writes x86-64.** The assembler module and the C compiler write modules of x86-64, on the machine. Under (b) the browser machine cannot run what the system builds.
4. **The loader and the module format do not change.** Under (b) a process needs code that the page compiles, outside the memory that the loader maps.

The cost of (a) is the speed of computation, and the work of a software processor. The cost is bounded: the user mode only, the instructions that LLVM writes for the baseline of x86-64 with SSE2, and no instruction that only the kernel runs. The tool checks that bound ("The instruction set, checked").

### What stays exactly as on hardware

- **The page tables:** the same format of x86-64 in four levels, written by the same code of `src/modulus`, with the counts in bits 52 to 62 and the large pages of 2 MiB ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The page tables of a process").
- **The handles, the budgets and the memory objects**, and each kernel operation: the count of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface", does not change.
- **The rings:** the kernel ring of each thread and the rings between processes, in the same shared memory.
- **The root service, the start policy, the loader, the device services and every module**, at their hashes.
- **The protection and the shoot-down:** `Memory_Protect` and the unmap still make each processor forget its old translations before they return ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Protection and the shoot-down").

### How the software processor works

The software processor is a kernel part, a pure package in a folder of its own under `src/modulus`, with host tests. On a browser machine the kernel calls it; on the host its tests call it.

- **The walk.** It walks the table that the kernel names, as the processor does: present, write, user, no execute, large pages. It sets the bit Accessed, and Dirty on a write, with an atomic OR, as the hardware does: the counts of the kernel in the same entries change with atomic additions, and they stay right. A walk that fails gives a page fault with the error code and the address of the hardware.
- **The translation cache.** A direct-mapped table of 256 entries for each processor, indexed by the bits 12 to 19 of the address, holds the frames of the recent pages for a read, a write and an execute. A flush of the kernel empties it. Beside it, the page of the last instruction fetch serves each next byte of the same page with one read of its frame and no lookup, as the TLB of instructions of a processor; it holds only a translation that the walk allowed for an execute, and each flush, `invlpg` of any address and each write of `cr3` empty it.
- **The copies of whole pages.** `mmu_read_bytes` and `mmu_write_bytes` check each page of the range, then move each page chunk in one copy. A run of `rep movsb` and `rep stosb` with the direction flag clear moves, in one copy or one fill, the iterations whose bytes stay inside the page of the first one, and counts each of them as a step: the copies of the system library use `rep movsb` from 2 KiB to 1 MiB, and the hash of the files of the image and the fills of the screen use those copies. The run stops at the budget, at the end of a page, and where a destination starts inside its source above it (each iteration then reads a byte that an earlier one wrote, so the run moves only the bytes before that one). A fault, a backward copy and a single step take the path of one iteration, so a fault leaves the exact `rcx`, `rsi` and `rdi`. The run and the steps one by one leave the same state, as the fuzz target `software_machine` and the host tests check.
- **The blocks.** The software processor decodes a run of instructions once into a compact form, and runs it again from its cache, keyed by the address and the frame. It counts each instruction of a slice exactly, so a preemption and a fault give an exact frame.
- **A fault is precise.** A fault leaves the frame of before its instruction: no register, no flag and no byte changes. A read-modify-write form computes its flags before its write to memory, so the step keeps the registers and the flags of before the instruction and gives them back on a fault, in one place for every form: a new form cannot forget it. A `cmpxchg` whose compare fails writes its destination back with its own value, as the processor does, so a destination that the user cannot write faults in both cases. The fuzz target `software_machine` checks this after each step ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)).
- **The compiled tier.** A block that runs often is compiled to a module of WebAssembly. A worker of the page compiles it with `WebAssembly.compile`, so no processor waits; the processor runs the decoded form until the compiled form is in its table. A compiled module can be sent to every worker, which makes its own instance. Blocks are grouped into larger modules: an engine slows down with thousands of small modules, and QEMU and unkernel group their blocks for that reason.
- **Coherence.** The kernel refuses a mapping that is writable and executable, but one frame can be writable in one mapping and executable in another. So the software processor marks each frame that holds decoded code, in a table of the machine. A write to a marked frame, by a process on any processor, by the kernel or by a device model, ends the blocks of that frame before the next block runs. This is the rule of x86-64 for code that another processor changes.
- **Ports and registers.** An `in` or an `out` of a process is checked against the I/O permission map that the kernel keeps for the process. An access to device memory that is a register is a request to the device models: the processor writes the request into its mailbox in the shared memory, notifies the models, and waits on the answer with `memory.atomic.wait32`. The memory of the screen and of the virtio queues is ordinary memory, never a request.
- **The other instructions.** `cpuid` gives a fixed answer: the baseline of x86-64 with SSE2, and no set that the kernel does not save. `rdtsc` reads the clock of the page. `rdrand` and `rdseed` read `crypto.getRandomValues`. `int3`, the trap flag and the four data breakpoints work, so the debugger works.

### The vector instructions

The modules are built for the baseline of x86-64 with SSE2 ([`docs/SIMD.md`](../../../docs/SIMD.md), "2. One form: SSE2"), and the compiler uses the vector registers for copies, comparisons of bytes and every floating-point value. So the software processor runs all of SSE and SSE2 that a process can run: the moves, the integer instructions of the 66 map, the arithmetic, comparisons and conversions of singles and doubles, `ldmxcsr`, `stmxcsr`, `fxsave`, `fxrstor`, the fences and `clflush`. A census of the instructions of every module of the build names each form that the modules use, and each SSE and SSE2 form that it names is here. Only the module `extended_state`, which tests the extended state of the processor, uses x87 and AVX forms; the software processor gives it an invalid instruction for them. The register file holds the sixteen registers and MXCSR, and the extended state of a thread saves both, at the offsets of `fxsave`.

- **Precise faults.** A vector form reads its operands, computes its result in locals, and writes its register or its memory as its last action. So a fault leaves the vector registers and MXCSR as they were, as the fuzz target checks after each step. A form with 16 bytes of memory checks their alignment first, as the processor does, but `movups`, `movupd` and `movdqu`.
- **The NaN of x86-64, not the one of the host.** WebAssembly does not fix the sign and the payload of a NaN that an operation gives. So no NaN comes from the host: a NaN operand gives the quiet form of the first one, an invalid operation gives the indefinite, a conversion keeps the sign and the high payload, and `minsd` and `maxsd` give their second operand, as the Intel SDM states.
- **Singles through doubles.** An operation of two singles runs in double precision and rounds once more to a single. The result is the correctly rounded single for the four operations and the square root, because a double has more than twice the bits of a single plus two.
- **The exceptions.** The invalid operation, the denormal operand, the division by zero and the overflow set their flags in MXCSR. An exception that MXCSR does not mask ends the instruction with vector 19: its flag is set and no destination changes. The underflow is raised with flush-to-zero, or when it is not masked; the precision flag is raised with an overflow or a flush.
- **What the processor does not do, and says.** MXCSR takes no denormals-are-zero: the mask that `fxsave` writes lacks it, and `ldmxcsr` refuses it with a protection fault, as on a processor that lacks it. The rounding control applies to the conversions to integers; the arithmetic rounds to nearest in each mode. The precision flag is not raised for a result that is rounded without an overflow or a flush. `popf` changes the arithmetic flags and the direction only: the processor runs no trap flag. These limits are entries of `ROADMAP.md`.
- **One answer of `cpuid`.** The software processor holds the answer, and the kernel of a browser machine gives the same one, so a process and the kernel see one machine. It names no MMX register, no SSE3 and no BMI1: `tzcnt` and `lzcnt` run as `bsf` and `bsr`, as on a processor without them, and an MMX form is an invalid instruction. `rdtsc` reads the cycle counter of the kernel, the clock of the page.

### The instruction set, checked

The tool reads the code of each module of the image and lists its instructions. A module with an instruction that the software processor does not run is a fault of the check, with the module, the place and the instruction. So the software processor never meets an unknown instruction in a module of the image. A module from the disk, or code that the system writes, can still hold one: the software processor gives the process the fault of an invalid opcode, as a processor does.

## The devices of the page

### The border: the virtio queue, not the class ring

The device models play the devices of the test machine, at the same fixed places of the bus. The device services of today drive them with no change. The class protocols (the block ring, the frame ring, the input records, the timed stream) stay between processes of the system, as on hardware.

A model of the page that writes the class ring itself, in place of a device service, was refused ("The refused forms"). The virtio queue is the lower border: below it, even the device services see no change.

The models run in a worker of their own, never in a processor and never on the thread of the document. They are Odin code built for `freestanding_wasm64p32`, which reads the virtio records of `modus:virtio`. The JavaScript of the page holds only the calls of the browser: the canvas, the events, the audio, the storage and the network.

| Device | Model | What the system sees |
|---|---|---|
| The data disk | virtio-blk on the origin private file system (OPFS), through a synchronous access handle in the worker of the models; a `Flush` is `flush()` of the handle | The block service and the storage service, unchanged. The page asks the browser to keep the storage (`navigator.storage.persist()`) |
| The network | virtio-net; each frame crosses a datagram of WebTransport to the link relay that the embedding page names, or a message of WebSocket where the engine has no WebTransport. With no relay named, the machine has no network device | The frame service and the network service, unchanged; the TCP and QUIC of the system end to end. With no relay, the paths of a machine with no network device |
| The screen | The standard VGA of QEMU: its video memory in the shared memory, its display registers through ports | The compositor and its page flip, unchanged ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)) |
| The keys | The PS/2 controller with the keyboard: `KeyboardEvent.code` to the bytes of the keyboard | The input service, its layout and its path of the keys, unchanged |
| The pointer | The virtio tablet: the place of the pointer in the canvas, as the roadmap entry "An absolute pointer in a virtual machine" makes it on QEMU | The absolute pointer record of the input service |
| The sound | virtio-snd; an `AudioWorklet` reads the periods from a ring of the shared memory | The sound service and its timed stream, unchanged |
| The entropy | virtio-rng over `crypto.getRandomValues` | The entropy service, unchanged |
| The date | The clock of the machine (two ports) from `Date`, in UTC | The process `date`, unchanged |
| The log | The serial port: each line goes to the page and, in a test, to the tool | The serial writer, unchanged |
| The object cache | Read-only `fetch()` of objects by hash from the HTTPS object cache that the page names ("The object cache of the page"). With no cache named, the machine has no object cache device | The objects and the realisations that the system checks itself, by hash and by signer |

### The object cache of the page

An object needs no trust: it checks itself against its hash, and a realisation against its signer ([recipes.md](recipes.md), "The object cache and its protocol"). So the page can take objects from any server that serves them, through the `fetch()` of the browser, with no relay and no TCP, TLS or QUIC of the system. The general network of the system stays the link relay ("The network" in the table above).

- **What the device reads.** Two kinds, by their hash only: `<cache>/blobs/<hash>` gives the bytes of a blob, and `<cache>/realisations/<recipe hash>` gives one realisation record of `REALISATION_WIRE_SIZE` bytes. The hash is 64 lowercase hexadecimal digits and never all zero. The device writes nothing, lists nothing and names no other path. Trees and release pointers wait for a reader that needs them.
- **The cache that the page names.** `cacheBaseUrl` of the host, empty by default: no cache, and each request gives `Not_Configured`. The console page takes it from `?cache=<address>`. The host takes only an address of `http:` or `https:` with no user, no password, no query and no fragment; it drops a final `/`. The server must allow the origin of the page by CORS. A page that sets `connect-src` names the cache there, as it names a link relay ("The trust").
- **The page is a pipe that nobody trusts.** `ObjectCacheBridge` of `browser_machine_host.js` builds the address from the kind and the hash, fetches with no credentials, no referrer and no redirect, and stops a body at the bound of its kind (`BROWSER_CACHE_OBJECT_LIMIT` for a blob, `REALISATION_WIRE_SIZE` for a realisation) before it holds more. It checks no hash: the system checks each byte, so a page that lies gives a refusal and never a wrong object.
- **The check of the system.** `modus:contract/object_cache`, `browser_cache.odin`: `browser_cache_url_path` writes the one path of a kind and a hash, `browser_cache_verify_blob` compares the BLAKE3 hash of the bytes in constant time, and `browser_cache_verify_realisation` decodes the record and requires its recipe hash, the signer that the caller trusts and a valid Ed25519 signature (`substitution_check`). Each status is a member of `Browser_Cache_Status`; the host names the same numbers, and a host test of the tool compares them.
- **Why the image stays small.** A console image of about 3.5 MiB needs no network service, no TLS and no relay to take a module or an output by its hash: the browser carries the bytes, and the system keeps the trust.

### The display and the scale

- **The size.** The screen has the size of the canvas in device pixels, read with `ResizeObserver` and its `devicePixelContentBoxSize`, so one pixel of the system is one pixel of the display, with no blur.
- **The scale factor** is the eighth of the system nearest to `devicePixelRatio` among the scales that exist ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"). A ratio of 2 gives the largest scale until the scales past 1.375 exist.
- **A resize of the canvas after the start** is a change of the mode of the display, which the class protocol of the display gives ([device_services.md](device_services.md), "The open points"). A fixed size at the start is not enough: a page that the reader resizes, or turns on a phone, then shows a screen of the wrong size. So the browser machine comes after the class protocol of the display, and each resize of the canvas is a change of the mode.
- **The present.** At each animation frame, the thread of the document copies the screen page that the display registers name into a texture of WebGL2, and a shader swaps the blue and the red. The copy is whole: the display has no damage. Its cost is a measure. The first page draws the framebuffer of the boot record on a canvas 2D, and swaps the bytes in JavaScript ("The page and its host").

### The trust

The system trusts the page no more than it trusts QEMU: the page holds the whole memory of the machine, as QEMU does. The rules of today hold at the border of each device: a device service copies, then checks, each record of its device. The browser machine has no IOMMU, so each device model reaches all memory, as each device of a machine with no IOMMU does, and the root service refuses each device service from the disk, as it does there ([device_services.md](device_services.md), "No IOMMU, no third party").

The page sets the policy of its own document: `Content-Security-Policy` with `script-src 'self' 'wasm-unsafe-eval'` (the compiled tier makes modules), `worker-src 'self'`, and a `connect-src` that names the link relay and the object cache of the embedding page, when it names them. A page to embed sets `frame-ancestors` to the sites that can embed it. The headers of the site of today forbid both ([`docs/SITE.md`](../../../docs/SITE.md), "How the site is published"): the path of the browser machine gets its own rule.

## The boot

- **The boot image and its signature.** The page fetches the system description of the browser machine, its signature, the kernel of WebAssembly and the boot image. The boot image is the one of the release; the description is the description of the release with entry 0 changed, signed by the same release signing key.
- **The boot program becomes the boot of the page.** The checks of the boot program (the signature of the description, the hash of the kernel and of each file of the image) are built for `freestanding_wasm64p32` and run in the worker of the first processor, before the page instantiates the kernel. The firmware part leaves: the memory map is the shared memory, the screen is the video memory of the model, the seed comes from `crypto.getRandomValues`. A failed check draws the boot display with the same code, and the kernel does not start ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "4. What a failure shows").
- **What the check proves.** It finds a damaged or swapped file, or a mirror that serves another file. It does not prove the origin: the server that sends the kernel also sends the boot of the page and its key. This is the state of a machine with Secure Boot off ([`docs/TRUSTED_BOOT.md`](../../../docs/TRUSTED_BOOT.md), "2. What each layer protects, and what it does not"). A page that embeds the machine can pin the hash of the boot of the page with the `integrity` attribute of its script: that is the nearest form of Secure Boot that a page has.
- **No TPM, and the system says so.** The browser machine has no TPM, no measure and no TPM floors. The system takes the paths of a machine with no TPM: the machine key under the machine passphrase, no seal, no rollback floor. A TPM in software inside the page is refused ("The refused forms").
- **The rescue start policy** is a choice of the page before the boot (an element of the page, or a parameter of its address), which sets the flag of the boot record as the boot entry "modus (rescue)" does.

## The size and the speed

These are targets that the first measures check; none is a claim. Each measure is a line on the log, which the tool keeps in the measure record, as for the test machine ([measure_history.md](measure_history.md)).

| Measure | From | To | First target |
|---|---|---|---|
| The download | The first request of the page | The last byte of the kernel, the boot of the page, the models and the boot image | Below 10 MB with compression, for the first visit; nothing on a later visit, from the cache by hash |
| The boot | The start of the navigation | The line "the machine is usable", and the first frame of the desktop | Below 1 s after the download, on a desktop computer |
| The time of a frame | The measure line of the compositor, unchanged | | Below 16.7 ms in its damage, at the size of the canvas |
| A key to the screen | The `timeStamp` of the event of the document | The animation frame that shows the flip that names the key | Below 50 ms |
| The software processor | Instructions in each second, decoded and compiled, by the process `processor_frame` and its four lines | | A ratio to the same lines under KVM, followed over the releases |
| A switch of threads | The throw of the processor loop | | A measure, to decide whether the throw stays |

The processor profile of the browser machine comes from these measures, as the processor profile of the test machine came from its first measure ([desktop_to_browser.md](desktop_to_browser.md), "The thresholds of the processor profile"). The compositor writes the profile that it chose on the log.

## The machine tests

The tool runs the scenarios of the machine test on a browser machine, through a headless browser that it starts, with no window on the desktop of the developer.

- **The tool serves the page** from a server on the loopback, with the headers of isolation, and starts Chromium with `--headless=new` on its address. A second engine, Firefox in its headless mode, runs the same parts. A part also runs with no headers of isolation, on one processor.
- **Safari is not tested, and it is accepted.** Safari runs only on macOS, and the hosts of the tests run Linux. The page runs on Safari with the features that it has, and the page of the site says that no test runs on Safari.
- **The page connects back to the tool** by a WebSocket of the loopback. Through it the tool does what it does to QEMU through its monitor: it sends keys and pointer moves to the models, it reads the lines of the serial port, and it takes a picture of the video memory. No protocol of browser automation is needed: the page is the machine, and its models are its QEMU.
- **The data disk is the disk of the tool.** The model of the disk reads and writes the disk of the run through that WebSocket, so the tool knows each write and each flush, and the tests of a stop of the machine run as they run today ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "U5. Storage service").
- **The network is the peer of the tool.** The model of the network sends its frames over the same WebSocket to the peer of the tool.
- **The proof of the port.** A part runs on QEMU and on the browser machine, and the settled pictures of each step are equal, outside the clock of the bar and the rectangle of the pointer.
- **The bounds.** A wait has the hang bound and no fixed delay; the times are measures, never tests ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests").

## The order of the work

Each layer adds one capability to a system that works. Each layer is an entry of `ROADMAP.md`, in "Later". The browser machine comes after the class protocol of the display, so that the desktop in a page follows each resize of the page.

1. **The software processor on the host.** The kernel part, with host tests, the fuzz target that runs random runs of instructions on it and on the processor of the host and compares the registers, the flags and the memory, and the check of the instructions of each module. It works alone: the tool proves that every module of the image runs on it.
2. **The kernel in a page, on one processor.** The arch layer for WebAssembly, the processor loop, the boot of the page with the signed description of the browser machine, the serial port, the bus, the clock and the entropy device, with no disk and no screen: the paths of a machine that lacks them. The tool runs a part with no screen on it, through the headless browser. It works alone: modus starts in a page to "the machine is usable".
3. **The desktop in a page.** The display and its scale, the change of its mode at each resize, the keys and the tablet. It needs the absolute pointer on QEMU and the class protocol of the display first. The parts with pictures run on the browser machine, and their pictures equal the pictures of QEMU.
4. **A disk that survives a reload.** The data disk on OPFS. A principal finds its documents after a reload of the page.
5. **The compiled tier.** Hot blocks as modules of WebAssembly. The measures of the software processor improve.
6. **The demonstration on the site.** The page of the release, with its headers, and a guide that embeds a console.
7. **Several processors.** The workers on one shared memory.
8. **The sound of the page.** virtio-snd to an `AudioWorklet`.
9. **The network of the page.** virtio-net and the link relay that the embedding page names.

## The refused forms

- **QEMU compiled to WebAssembly as a first step.** It needs no port: the image of today, on QEMU in a page. It was refused. A slow emulation of the whole machine shows modus at its worst: each kernel entry and each page fault is emulated too, where the design of modus makes them the fast path (unkernel measured `getppid` at 1.7 µs under `qemu-system` against 170 ns with a kernel in WebAssembly, and `fork` 20 times slower). And its work leads nowhere toward the real port: no part of a page for QEMU becomes a part of the browser machine.
- **The modules compiled to WebAssembly (b), and a memory for each process (c).** See "The ways compared".
- **JSPI to switch threads.** It binds each thread to a worker and hides its registers. The kernel of modus needs no stack for each thread ("The switch of threads, with no JSPI").
- **The class ring written by the page, with no device service.** It needs a new path in the root service to give a ring to something that is not a process, and the image of the browser machine then holds other device services than the release. The virtio queue gives the same "no change" one layer lower, and a model of virtio can be tested against the behaviour of QEMU.
- **A Wisp proxy and a TCP/IP stack in JavaScript.** Wisp carries streams, so the page needs its own TCP/IP stack to end the TCP of the system, and the stacks of the system no longer reach the network. A link relay carries frames: the page is a wire. The object cache of the page is not this form: it reads objects that check themselves, so it needs no stack of the system and gives the page no trust ("The object cache of the page").
- **A relay for the object cache, or a cache that the page trusts.** A relay adds a server that the project or the embedding page must run, for bytes that the browser fetches itself. A page that checks the hashes for the system moves the trust into the page, which the system never trusts ("The trust"); the system checks each object.
- **IndexedDB for the disk.** It stores objects with asynchronous calls. A synchronous access handle of OPFS reads and writes at an offset and flushes, which is a disk.
- **A processor or a device model on the thread of the document.** That thread cannot wait, and a long run there freezes the page.
- **A TPM in software in the page.** Its keys are in the same memory as everything else, so a seal protects nothing, and the system claims a measure that nobody can check.
- **Node as a second runtime of the page.** A second runtime is a second set of models. A headless browser runs the tests as easily.
- **A kernel built for memory64.** See "What Odin gives".
- **An embed that requires cross-origin isolation.** Most pages that embed set no isolation, so with this rule most readers get no machine.
- **A link relay that the project runs.** A relay is a router of the internet: it needs a policy against abuse, and its operator answers for each machine that uses it. The embedding page names its own relay, and the site of the project runs none, so a browser machine of the site has no network.
- **A fixed size of the screen at the start.** A resize of the page or a turn of a phone then leaves a screen of the wrong size, centered in a canvas that no longer fits it.

## The contradictions

- **The assumption "64 bits only"** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Assumptions"). The kernel of the browser machine has 32-bit pointers to its own tables. Every address that crosses a border (a record, a register of a process, a ring) stays a `u64`, and every process stays 64-bit. The nearest form that keeps the text as it is: a target `wasm64` with memory64 in the fork of Odin, which Safari cannot run today. The owner decides between that target and a text that binds the addresses that cross a border ("The open questions").
- **Property 1, a small kernel.** The software processor is a large part, and the kernel of the browser machine holds it, as a processor holds its decoder. It adds no kernel operation, and the kernel of the hardware does not hold it.
- **Property 10, one module format.** The kernel of the browser machine is a binary of WebAssembly at entry 0, not a module file, as the boot program is a UEFI program and not a module. No process loads either.
- **Property 11, code compiled at run time.** The compiled tier is the translation of the processor, as the cache of decoded instructions of a processor is. It is outside the linear memory, so no process reads or writes it, and it has the identity of the code that it translates.
- **Property 17, trusted boot.** The browser machine has no Secure Boot and no TPM. The system already runs on such a machine, and says so on its log ("The boot").

## The subtle points

- **The shadow stack after a throw.** A throw skips the end of each procedure, so the shadow stack pointer stays where the deepest frame left it. The processor loop sets it to the top of the stack of its processor at each entry.
- **No guard page under a kernel stack.** The shadow stack has none, and a deep chain writes over the memory below it. The measure of the deepest chain ([../infrastructure/kernel_stack_depth.md](../infrastructure/kernel_stack_depth.md)) must also measure the build of WebAssembly, whose frames differ. An overflow of the stack of the engine is a trap, which stops the machine.
- **A trap stops the machine.** A trap of WebAssembly in the kernel (an access out of bounds, `unreachable`) ends its worker. The page shows the last lines of the log and the cause, as a stop of the machine does.
- **The clock of each worker.** `performance.now()` starts at the time origin of its worker; only the sum with `performance.timeOrigin` is one clock.
- **The order of the memory, in the kernel.** The shared memory of WebAssembly orders its atomic operations, and gives no order between processors to its plain accesses. The kernel already uses atomics where two processors meet; a plain access that the kernel relies on as ordered by the hardware (the total store order of x86-64) must become an atomic in the arch files.
- **The order of the memory, in a process.** The code of a module was compiled for x86-64, where an atomic load or store of the source is a plain `mov`: the order comes from the hardware. The software processor cannot tell such a `mov` from another one. With one processor, the order of execution is the order. With several, each load and store of a process runs as an atomic of WebAssembly, and the locked instructions and `mfence` too, so a ring between two processes keeps its order on a computer whose processor orders less (an ARM phone). Its cost is a measure of layer 7, which decides whether a frame that only one thread maps can skip it.
- **The fast paths of the kernel.** The budgets in cache lines of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "13. Data-oriented kernel internals", are checked for each target: 32-bit pointers change the layout of the tables of the kernel.
- **The storage of a page can go.** A browser can erase the storage of an origin under pressure unless it granted persistence, and a principal can clear it. A disk that vanished is a blank disk to the storage service: the page says so before the first boot.
- **The storage of an embedded page is partitioned.** A machine in an `iframe` keeps its disk under the site that embeds it, so two sites never share a disk.
- **The size of a frame on the link.** A datagram of WebTransport has a smaller payload than a frame of 1514 bytes. The model of the network states its MTU in the field of virtio-net, and the network service must read it ([../infrastructure/network_data_path.md](../infrastructure/network_data_path.md)).
- **The sound before the first gesture.** A browser starts no audio before an action of the reader. The model of the sound takes the periods at their time and drops them until then, so the timed stream never waits ([timed_stream.md](timed_stream.md)).
- **The keys that the browser keeps.** Some keys never reach the page (Control+W, Control+T) unless the page is in full screen with the keyboard lock of the browser. The key super of the palette must have a key that a page receives.
- **The link relay is a router of the internet.** Each machine that uses it reaches the network through its address. It needs the origins that it accepts, a rate bound for each machine, and a policy against abuse. So the embedding page brings its own relay and its rules; without one, a browser machine has no network.

## The open questions

1. **The pointers of the kernel.** `wasm64p32` and a text of the assumption that binds the addresses that cross a border, or a target `wasm64` with memory64 in the fork, which Safari does not run today.
2. **The translation ahead of time.** Is it wanted at all, or does the compiled tier suffice? It waits for a measure of the start of the large modules.

## State

Layer 1 foundation and the WebAssembly runtime export bridge are built in `src/library/modus/contract/software_machine` with the browser runner harness in `tools/modustool/site`: the freestanding Software MMU (4-level x86-64 page-table walker matching `modulus` bits including 2 MiB large pages, canonical-address checks, W^X/NX enforcement, physical RAM bounds, atomic page-straddling reads and writes, and a direct-mapped software TLB with full and single-page invalidation), the freestanding x86-64 user-mode software processor (general-purpose integer instructions, `gs:` base reads, `syscall`/`int3`/`ud2`, step-budgeted `rep movsb`/`rep stosb`, and core SSE2 vector operations), the browser machine configuration border (single-worker fallback without cross-origin isolation, engine-capped multi-worker mode with isolation, and optional bring-your-own link relay URL validation), the zero-allocation WebAssembly C-ABI export bridge (the package `software_machine_demonstration`, beside `software_machine`: static 2 MiB guest RAM, bounded RGBA framebuffer up to 640x400 mapped RW NX in guest virtual memory, bounded keyboard/pointer input rings, serial console output ring, and strict border validation on `modus_vm_init`, `modus_vm_load_bytes`, `modus_vm_step_budget`, `modus_vm_framebuffer_ptr`, `modus_vm_framebuffer_bytes`, `modus_vm_push_key`, `modus_vm_push_pointer`, `modus_vm_pop_serial`, and `modus_vm_state_word`), and the browser runner assets in `tools/modustool/build/browser_machine/browser_machine.html` (and the demonstration asset emitted by `site_browser_machine.odin`, with canvas framebuffer blit, keyboard/pointer forwarding, serial console output, single-processor fallback without cross-origin isolation, and an optional blank-by-default bring-your-own link relay field). Freestanding `amd64_sysv`, `wasm32`, and `wasm64p32` builds and adversarial host tests pass. The arch layer of the kernel is in "The arch layer as it is". What remains: the module instruction-set check, differential fuzzing against the host processor, the boot of the page, the virtio device models, the compiled tier, and the headless browser machine tests.

The console page runs its machine in `browser_machine_worker.js`, with the trust of its description from `console.image.trust`. Both pages show the stages of the start ("The boot stages of the page"); the decoded blocks of the software processor are not built, and the image check of the root service is most of a start in a page. The object cache of the page has its check in the system (`browser_cache.odin`, with host tests) and its fetch in the host (`ObjectCacheBridge`). What remains of it: the device through which a process of the system asks the host for an object and reads its bytes, and the service that gives those objects to `recipes` and to the loader.
