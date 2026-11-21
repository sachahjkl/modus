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

The kernel is built for `freestanding_wasm64p32`, with the features `atomics` and `bulk-memory`, and linked by `wasm-ld` with a shared memory that the page creates and gives:

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
| The interrupts and their vectors | One word of pending vectors for each processor, written by the device models and the other processors |
| `hlt` in the idle wait | `memory.atomic.wait32` on the word of the processor, with the next deadline as its bound |
| The IOMMU, `Guest_Run`, the steal time | None: the paths of a machine with no IOMMU, no virtualization and no steal-time record ([missing_hardware.md](missing_hardware.md), [guest.md](guest.md)) |
| The processor counters | `Unsupported`, as on a machine with no counters ([processor_counters.md](processor_counters.md)) |
| The ACPI table of the processors | The count of processors that the page gives |
| The I/O ports and the device memory | A request to the device models ("Ports and registers") |

The kernel reads and writes process memory (the kernel ring of a thread, a table that a command names) by its virtual address. On a browser machine that access walks the page table of the process in software, with the checks of the hardware: present, user, write. A page that the walk does not find gives the same fault as on hardware.

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
- **The resolution.** The engine coarsens this clock ([High Resolution Time](https://www.w3.org/TR/hr-time-3/): 5 µs when the page is cross-origin isolated, 100 µs otherwise). The charge of processor time at a switch is then a multiple of that step. A budget holds its limit over a period of 100 ms, so the step changes a turn, not the limit ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Processor time").
- **The timer.** A one-shot deadline in the processor record. The software processor reads the clock at the end of each slice of instructions and at each exit; a deadline that passed is the interrupt of the timer. The idle wait takes the deadline as its bound. A slice is a count of instructions, and each exit costs a part of it, so a loop of cheap kernel entries still sees its tick (unkernel found the same need: `.agents/kernel.md`, "IRQs and time").
- **No interrupt inside the kernel.** An interrupt waits for the next exit or the next end of a slice. The kernel runs each entry to its end, as with interrupts off. A spin of the kernel that waits for another processor reads the words of the other processor; it never waits for an interrupt.

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

- **The page tables:** the same format of x86-64 in four levels, written by the same code of `src/kernel`, with the counts in bits 52 to 62 and the large pages of 2 MiB ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The page tables of a process").
- **The handles, the budgets and the memory objects**, and each kernel operation: the count of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface", does not change.
- **The rings:** the kernel ring of each thread and the rings between processes, in the same shared memory.
- **The root service, the start policy, the loader, the device services and every module**, at their hashes.
- **The protection and the shoot-down:** `Memory_Protect` and the unmap still make each processor forget its old translations before they return ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Protection and the shoot-down").

### How the software processor works

The software processor is a kernel part, a pure package in a folder of its own under `src/kernel`, with host tests. On a browser machine the kernel calls it; on the host its tests call it.

- **The walk.** It walks the table that the kernel names, as the processor does: present, write, user, no execute, large pages. It sets the bit Accessed, and Dirty on a write, with an atomic OR, as the hardware does: the counts of the kernel in the same entries change with atomic additions, and they stay right. A walk that fails gives a page fault with the error code and the address of the hardware.
- **The translation cache.** A small table of each processor holds the frames of the recent pages for a read, a write and an execute. A flush of the kernel empties it.
- **The blocks.** The software processor decodes a run of instructions once into a compact form, and runs it again from its cache, keyed by the address and the frame. It counts each instruction of a slice exactly, so a preemption and a fault give an exact frame.
- **The compiled tier.** A block that runs often is compiled to a module of WebAssembly. A worker of the page compiles it with `WebAssembly.compile`, so no processor waits; the processor runs the decoded form until the compiled form is in its table. A compiled module can be sent to every worker, which makes its own instance. Blocks are grouped into larger modules: an engine slows down with thousands of small modules, and QEMU and unkernel group their blocks for that reason.
- **Coherence.** The kernel refuses a mapping that is writable and executable, but one frame can be writable in one mapping and executable in another. So the software processor marks each frame that holds decoded code, in a table of the machine. A write to a marked frame, by a process on any processor, by the kernel or by a device model, ends the blocks of that frame before the next block runs. This is the rule of x86-64 for code that another processor changes.
- **Ports and registers.** An `in` or an `out` of a process is checked against the I/O permission map that the kernel keeps for the process. An access to device memory that is a register is a request to the device models: the processor writes the request into its mailbox in the shared memory, notifies the models, and waits on the answer with `memory.atomic.wait32`. The memory of the screen and of the virtio queues is ordinary memory, never a request.
- **The other instructions.** `cpuid` gives a fixed answer: the baseline of x86-64 with SSE2, and no set that the kernel does not save. `rdtsc` reads the clock of the page. `rdrand` and `rdseed` read `crypto.getRandomValues`. `int3`, the trap flag and the four data breakpoints work, so the debugger works.

### The instruction set, checked

The tool reads the code of each module of the image and lists its instructions. A module with an instruction that the software processor does not run is a fault of the check, with the module, the place and the instruction. So the software processor never meets an unknown instruction in a module of the image. A module from the disk, or code that the system writes, can still hold one: the software processor gives the process the fault of an invalid opcode, as a processor does.

## The devices of the page

### The border: the virtio queue, not the class ring

The device models play the devices of the test machine, at the same fixed places of the bus. The device services of today drive them with no change. The class protocols (the block ring, the frame ring, the input records, the timed stream) stay between processes of the system, as on hardware.

A model of the page that writes the class ring itself, in place of a device service, was refused ("The refused forms"). The virtio queue is the lower border: below it, even the device services see no change.

The models run in a worker of their own, never in a processor and never on the thread of the document. They are Odin code built for `freestanding_wasm64p32`, which reads the virtio records of `modus:support/virtio`. The JavaScript of the page holds only the calls of the browser: the canvas, the events, the audio, the storage and the network.

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

### The display and the scale

- **The size.** The screen has the size of the canvas in device pixels, read with `ResizeObserver` and its `devicePixelContentBoxSize`, so one pixel of the system is one pixel of the display, with no blur.
- **The scale factor** is the eighth of the system nearest to `devicePixelRatio` among the scales that exist ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"). A ratio of 2 gives the largest scale until the scales past 1.375 exist.
- **A resize of the canvas after the start** is a change of the mode of the display, which the class protocol of the display gives ([device_services.md](device_services.md), "The open points"). A fixed size at the start is not enough: a page that the reader resizes, or turns on a phone, then shows a screen of the wrong size. So the browser machine comes after the class protocol of the display, and each resize of the canvas is a change of the mode.
- **The present.** At each animation frame, the thread of the document copies the screen page that the display registers name into a texture of WebGL2, and a shader swaps the blue and the red. The copy is whole: the display has no damage. Its cost is a measure.

### The trust

The system trusts the page no more than it trusts QEMU: the page holds the whole memory of the machine, as QEMU does. The rules of today hold at the border of each device: a device service copies, then checks, each record of its device. The browser machine has no IOMMU, so each device model reaches all memory, as each device of a machine with no IOMMU does, and the root service refuses each device service from the disk, as it does there ([device_services.md](device_services.md), "No IOMMU, no third party").

The page sets the policy of its own document: `Content-Security-Policy` with `script-src 'self' 'wasm-unsafe-eval'` (the compiled tier makes modules), `worker-src 'self'`, and a `connect-src` that names the link relay of the embedding page, when it names one. A page to embed sets `frame-ancestors` to the sites that can embed it. The headers of the site of today forbid both ([`docs/SITE.md`](../../../docs/SITE.md), "How the site is published"): the path of the browser machine gets its own rule.

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
- **A Wisp proxy and a TCP/IP stack in JavaScript.** Wisp carries streams, so the page needs its own TCP/IP stack to end the TCP of the system, and the stacks of the system no longer reach the network. A link relay carries frames: the page is a wire.
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

Designed, not built. Nothing of the browser machine exists: no build of the kernel for WebAssembly, no software processor, no device model, no boot of the page and no test back end. The absolute pointer through the virtio tablet, on which layer 3 depends, is an entry of `ROADMAP.md`, "Next".
