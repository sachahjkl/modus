# From the desktop of today to a light web browser

The desktop of today has windows of a fixed size, programs with fixed tables, a draw table on the processor, and a network stack with TCP and QUIC. This file records the path from there to a light web browser, and to the run of two programs of other projects in Odin: `gui_toolkit`, a toolkit of immediate-mode interfaces, and `wren`, a web browser built on it. It gives each phase, what it depends on, and why the phases come in this order. The entries of the work are in `ROADMAP.md`; this file holds the reasons and the order.

## The constraints

- Each phase adds a capability to a system that works. No phase replaces a part that works with a part that does not work yet.
- Each phase keeps the properties of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md). Where a phase pulls against a property, the section "Where the path pulls against a property" names it.
- A browser reads hostile data from the network: HTML, CSS, pictures, fonts. Each reader of such data is a confined program or module with fuzz targets ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)).

## The order and its reasons

| Phase | What it gives | Depends on |
|---|---|---|
| A. The desktop foundations | Data with no known bound, windows that change size, a resolution, a window manager, the clipboard | Nothing new |
| B. Data in and out | Documents, drag and drop, pictures, notifications, buffers that pass from program to program with no copy | A |
| C. The draw table | Alpha, paths, clips, one text kind | Nothing new; it runs beside A and B |
| D. The web network | TLS over TCP, HTTP, cookies and a cache | A (arenas for the answers) |
| E. A light browser | HTML, a subset of CSS, links, forms, one program for each origin | A, B, C, D |
| F. 3D | A rasterizer on the processor, then the virtual GPU, then WebGPU | C |
| G. A real machine | USB, NVMe, sound, device services for real devices | A for the display modes |
| H. `gui_toolkit` and `wren` | The applications of the toolkit, then the browser `wren` | A, B, C, G for `wren` on a real machine |

The reasons:

- **A comes first** because each later phase needs it. A page of the web has no known size, so a browser needs arenas before its first parser. A browser in a window of a fixed size cannot show a page at the width that its reader chooses.
- **C runs beside A and B.** The steps of the draw table are decided and touch only the drawing; they do not wait for the desktop. A browser needs alpha, clips and paths, so E waits for C.
- **D comes before E** because a browser with no HTTPS reads almost no page of the web of today.
- **E is light on purpose.** It is the smallest browser that reads a page of documents: no script, a subset of CSS. It tests every phase before it with real data.
- **F comes after C** because 3D draws into a picture that the draw table shows.
- **G is late** because the test machine is virtual (property 7). A real machine is a goal, not a condition of the earlier phases.
- **H is last** because it needs the most: the system as a target of the core library of Odin, and for `wren` a large part of the web stack.

## A. The desktop foundations

- **Memory with no known bound.** Arenas paid by the budget: [memory_without_a_bound.md](memory_without_a_bound.md).
- **Layout with intrinsic sizes.** The interface package measures each element first, then places it: a label is as wide as its text, a column as wide as its widest child. Today a window places its elements at sizes that its code states. A window that changes size needs elements that know their size.
- **Windows that change size.** The principal drags an edge of a window. The compositor makes a new surface of the new size, gives it to the program, and sends the event `Resized`; the program draws its next frame into the new surface, and the compositor shows the old one until that frame comes. The program pays for the new surface, and a budget that cannot pay keeps the old size, with one line. A program never draws into a surface that the compositor resized under it.
- **A resolution that the principal chooses.** The compositor sets a mode of the display, then a scale factor for the interface: an element of 16 pixels at scale 1 is 32 pixels at scale 2. The glyph caches already exist at several scales ([glyphs_on_demand.md](glyphs_on_demand.md)).
- **A window manager.** Maximize, minimize, snap to a half of the screen, and global shortcuts that the compositor keeps. One key combination always goes to the system (property 20, line 8).
- **The clipboard.** A copy gives the compositor a read-only handle to a memory object of the program that copies. A paste of the principal gives the program that pastes a read-only handle to that object, at that paste only (property 20, line 5). No program reads the clipboard when the principal does not paste.

## B. Data in and out

- **The document service with the picker.** Already in `ROADMAP.md`, "A document service with a picker". A browser saves a page and reads a file of the principal through it.
- **Drag and drop** gives the program under the pointer a read-only handle to what was dropped, at the drop only: a grant that follows from an action ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users", the forms of concession).
- **Picture decoders.** PNG first, then JPEG. Each decoder is a module that runs in a call host with no handle but the bytes that it reads and the picture that it writes, and each has fuzz targets. A wrong file stops the call host, never the program that asked.
- **Notifications.** A program asks the compositor to show a short text. The compositor draws it in a place that a program cannot imitate (property 20, line 8), and a notification never takes the focus.
- **Buffers that pass from hand to hand with no copy.** See the next section.

### Chains with no copy across several programs

A browser moves large buffers through several programs: the bytes of a picture arrive from the network, a decoder makes pixels of them, and the compositor shows the pixels. Each copy of a picture of 8 MiB costs time and memory. The aim: a buffer passes from hand to hand through successive lends of its memory handle, with no copy.

What exists today:

- **The lend of a handle for one call** (`system.lend`, `system.lend_end`; [`docs/glossary/access.md`](../../../docs/glossary/access.md), "Lent handle"). The caller makes a copy of its handle with the rights of the description of the export, gives the callee a handle from that copy, and revokes the copy after the call. A table parameter in a memory object is lent with the rights of its direction, so a callee that only reads a table gets no Write. A revocation reaches each handle and each mapping that came from the copy, through each chain of gifts ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", the revocation).
- **The datagram region with no copy on send** ([../infrastructure/network_data_path.md](../infrastructure/network_data_path.md), "The send with no copy"). The device reads the data to send from the datagram region of the program; the network service copies and checks 8 bytes of the header only. On receive, the network service still copies each datagram once into the region of the program, and that copy is irreducible with one receive queue.
- **The surfaces of the windows.** A program makes the memory of its surface and gives the compositor a handle with Read only (`display.open`). The compositor reads the pixels in place, with no copy through a ring.

What is missing for a chain:

- **A lend that passes on to a third program.** A lent handle has only the rights of the description, with no Give, so a callee cannot lend the buffer on: the decoder cannot pass the pixels that it wrote to the compositor. The chain needs a description that lets a callee lend a handle on, with at most the rights that it received, and a `lend_end` of the first hand that ends each later hand too. The kernel already revokes through the chain; the form of the description and of the library is what is missing.
- **The read-only narrowing at each hand.** Each hand must pass the buffer on with Read only, and the hand before must lose its Write before the next hand reads, or the next hand must copy before it checks (property 6, "copy, then validate"). Today a program cannot take Write away from an object that another program maps: `Memory_Protect` acts only on an object that this program alone names. The missing part is a narrowing of an object for each holder: after it, no holder writes the object, and a reader can check the bytes in place.

The design of these two parts is not written. It needs a new intent file before any code.

### Large pages for large buffers

A large page maps 2 MiB with one entry of the page table, so a program that reads a large buffer misses the translation cache less ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Large pages").

What exists today:

- The flag `Large_Pages` of `Memory_Create`: the object is contiguous, its frames are one run aligned on 2 MiB, and its count of pages is a multiple of 512, or `Memory_Create` refuses it. `Memory_Map` uses a large page for each aligned 2 MiB of the mapping.
- A protection change must cover the whole mapping, and a decommit of such an object is refused, because it is contiguous.
- `Uncommitted` with any other flag is refused, so an uncommitted object never has large pages.
- The program `address_space` tests the flag and measures random reads over 64 MiB with large pages and with 4 KiB pages.

What is missing:

- **The surfaces.** `display.open` makes each surface with 4 KiB pages. A surface of 1920 × 1080 with two pictures is 16 MiB, eight large pages.
- **The decoded pictures and the frames of a video.** No program asks for large pages for them.
- **The arenas.** An arena is an uncommitted object ([memory_without_a_bound.md](memory_without_a_bound.md)), and the kernel refuses large pages for it. Large pages in an arena need a commit by whole runs of 2 MiB, which is a change of the kernel.
- **A measure.** The gain is measured for random reads only. A surface is mostly written and read in rows, where the gain can be small. The use for surfaces and pictures waits for a measure of a frame of the compositor with both forms. A contiguous run of 2 MiB can also fail on a fragmented machine, where 4 KiB pages succeed, so each use needs its refusal path.

## C. The draw table

The seven steps of the draw table, already in `ROADMAP.md`, "Next": [../api/draw_table.md](../api/draw_table.md). A browser needs alpha for its colors, paths for its borders and its icons, and the clip stack for its scroll boxes.

## D. The web network

- **TLS 1.3 over TCP.** The handshake and the record layer of the TLS of QUIC, over a TCP connection of the TCP library. One TLS code for both.
- **HTTP/1.1 and HTTP/3.** HTTP/1.1 over TLS over TCP, and HTTP/3 over QUIC. HTTP/2 is not planned: HTTP/3 serves the servers that offer it, and HTTP/1.1 serves each other server.
- **Cookies and a cache for each principal.** In the private store of the browser, for the principal of its session, so two principals share no cookie and no cache.

## E. A light browser

- **An HTML tokenizer and parser** after the algorithm of the WHATWG, with fuzz targets: the parser reads hostile bytes, so it runs with no handle but its input and its output.
- **A subset of CSS.** Block layout first, then inline layout, then flex. No grid, no animation.
- **Text layout** with the shaping that exists ([glyphs_on_demand.md](glyphs_on_demand.md)).
- **Painting into the draw table.** The boxes of a page become draw records; the browser draws no pixel itself.
- **Links, a history and forms.**
- **One program for each origin.** Each origin runs in its own program, with the network grant of that origin only (property 20, line 3). A page of one origin reads nothing of another. The program of the window holds the address bar and starts the program of each origin.
- **JavaScript** is a separate decision, in `ROADMAP.md`, "Maybe".

## F. 3D

1. **A rasterizer of triangles on the processor**, with a depth buffer, as a library module. It draws into a picture memory of the program, and a picture record of the draw table shows it, so the draw table stays the one 2D interface (property 18).
2. **The virtual GPU for the 2D scanout**: the compositor shows its screen through virtio-gpu in place of the standard VGA.
3. **3D through WebGPU**, on the virtual GPU, then on a real GPU through a driver domain: already in `ROADMAP.md`, "Acceleration by the virtual GPU of the test machine" and "Acceleration by a real GPU" ([gpu_access.md](gpu_access.md)).

## G. A real machine

- **USB**: a device service of the xHCI controller, then the USB keyboard and the USB pointer.
- **NVMe disks**, served through the block ring.
- **The display of the firmware**: the compositor already shows the framebuffer of the firmware; the page flip on a real display is in `ROADMAP.md`, "A whole frame on the display of a real machine".
- **Sound** through virtio-snd, with a class protocol of sound.
- **Device services for real devices**, their trust and their restart: [device_services.md](device_services.md).

## H. Running `gui_toolkit` and `wren`

`gui_toolkit` is an immediate-mode toolkit in Odin. On Linux it draws through WebGPU on Vulkan, with a Rust library for text; its packages `platform`, `render` and `font` meet the operating system, and most of the others are pure Odin. `wren` is a web browser in Odin on `gui_toolkit`: Lexbor in C for HTML, Rust libraries for the network, the pictures and the text, and Wasmtime as its one engine of execution.

1. **A target "modus" for the core library of Odin**, for ported programs only. `core:os` reads and writes the objects of the private store and of the handles that the program was given; `core:thread` runs on `Thread_Create`; `core:time` reads the clock of the system; `core:sync` waits on `Word_Wait`; the allocators of the language run on arenas. The code of the system keeps its rule: no allocator, and no package of the core library.
2. **A `gt:platform` back end for modus**: the surface, the input, the drawing, the fonts and the clipboard. Each application of `gui_toolkit` then runs. Its `render` draws through the draw table; what the draw table does not have (a blur, a blend mode, a transform) is drawn by `gt:paint` on the processor into a picture memory, which a picture record shows.
3. **`wren` by stages.**
   - Its Odin code first.
   - Lexbor, with a small library of C on the same target.
   - Its Rust libraries, through a Rust target for modus, or replaced by Odin code.
   - Wasmtime compiles code, writes it, then runs it. The kernel refuses a page that is Write and Execute together. Wasmtime needs an explicit switch of a page from Write to Execute, which needs a design of its own, or a Wasm interpreter first.
   - Drawing through the draw table, then WebGPU when the GPU layers exist.
4. **A fast path.** `wren` whole, in a Linux guest, through the driver domain of the GPU. It needs no port, and it waits for "Linux in a guest" ([foreign_systems.md](foreign_systems.md)).

The `interface` package of the system and `gui_toolkit` solve the same problem: elements, layout, focus, themes. They can converge one day. That convergence is not decided: it pulls against the properties, as the next section says.

## Where the path pulls against a property

- **Property 18, "uses no existing toolkit".** Property 18 says that graphical code is a program of this system and uses no existing toolkit, and that the project ports no wgpu, Dawn or Skia. A ported application of `gui_toolkit` is graphical code that uses an existing toolkit, and `wren` uses wgpu for WebGL. The nearest form that keeps the property: a ported program is a program of a third party, not code of the system; it draws through the draw table only, and its own effects become pixels in a picture memory. The property text must then say that its rule binds the code of the system and not a program of a third party. wgpu is not ported: `wren` on modus draws WebGL through the WebGPU of the system, when it exists.
- **The convergence of `interface` and `gui_toolkit`.** It contradicts property 18 ("uses no existing toolkit"), the rule that a source of `src/` imports `base:` and `modus:` packages only, and the refused form "an import of gui_toolkit" of [../infrastructure/release_image.md](../infrastructure/release_image.md). It stays an open question, not a plan.
- **The objective, "no foreign interface", and property 19.** `core:os` has paths, the arguments of a command line, environment variables and standard streams: concepts that the system removed. The nearest form that keeps them: the target is a binding of the language over the concepts of the system, inside the ported program. A path names an object of the private store or of a given handle, never a global tree; the arguments and the environment are empty; a write to the standard output is a line of the log of the program, which no program reads as input.
- **Property 11, code named by its hash.** Code that Wasmtime writes at run time has no hash and is no module. The guest already needs memory that it writes and then executes (`ROADMAP.md`, "A guest that runs a whole system"). The design of the switch must say who may hold such pages, and that a program with them is not a module of the system description.
- **Property 7, "support for hardware that nobody on the project owns".** A device service from the disk serves hardware that the project does not own. The system adds no support: a principal grants a module of a third party for one device. The property text must say that its forbid binds the boot image, not a disk program that a principal grants.

## State

Not built. The draw table, phase C, is the next work of `ROADMAP.md`; arenas, windows that change size and the clipboard come next.
