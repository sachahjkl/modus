# A whole frame: a window never shows a picture that is being drawn

A picture of a window reaches the screen whole, or it does not reach it. This is a rule of the system, for every window. It lives in the package `display` and in the window layer of the interface package. A process writes no code for it.

How a process opens a surface and presents a picture is in [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "2.1 Draw record" and "2.2 Damage by difference". This file records why the rule has this form.

## The purpose

- The compositor composes a frame of the screen at any time. It must never read pixels that a process writes at that time.
- A process that moves a large form each frame, and a process that changes one number a second, follow the same rule with the same code.
- The display must never read a frame of the compositor that the compositor writes at that time ("The screen: two screen pages and a page flip", below).

The fault that made the rule: a surface had one picture. The window layer paints a damage rectangle with the background, then draws its records. The compositor read the rectangle between the two, and the screen showed the head of a form with no body ([features/heron_module.md](../features/heron_module.md)).

## The constraints

- **A process cannot hold the compositor.** The compositor never waits for a process, and never does work that a process can make longer without a bound.
- **The process pays.** The memory of a picture comes from the budget of its process, never from the budget of the compositor.
- **No code in each process.** A rule that 51 processes must each write is a rule that one of them forgets.
- **The compositor cannot hold a service.** A process that serves other processes must not stop for a time with no bound because the compositor does not read.
- **The damage stays small.** A frame that changes one number draws a few rectangles, not the window.

## The chosen form

**Every surface has two pictures.** `display.open` creates the memory of two pictures, always. The process draws in one picture. `Present` names the picture that is complete, and the compositor reads only that one from then on. The next frame is drawn in the other picture. The compositor refuses a surface whose memory does not hold two pictures.

- The compositor shows the surface of a window only after its first `Present`. Until then the window has its frame and the background color: the first picture is whole too.
- The option `two_pictures` of `display.open` is removed. A surface with one picture does not exist.

**The window layer keeps the debt of each picture.** A picture holds the frame of two frames before. The window layer keeps one table, the table of the last frame that it presented, and for each picture the rectangles where that picture differs from that table: its debt. A frame draws the difference with the last table and the debt of its picture, and presents the difference with the last table. After the `Present`, the debt of the drawn picture is empty, and the difference joins the debt of the other picture.

- A process gives the window layer two tables, as before the rule: the table that it builds and the table of the last frame. It gives no table for the second picture. The three processes that gave one no longer do.
- The damage of a frame is the damage of two steps. A window that changes one number draws that number two times. It is still a few rectangles.
- A picture whose state is not known (the first frame of each picture, a new font, a `Present` that the full ring refused) is drawn whole.

**The process draws only when the compositor took the last `Present`.** Until then the compositor can still read the picture that the process would draw in. `display.canvas_free` says it: the count of the records that the compositor read from the ring of the window passed the last `Present`.

- `display.canvas_wait` is the wait of the system. The thread waits on the count of the records that the compositor read, a word of the ring of the window. The compositor wakes the thread when it has read the ring. The wait has no fixed step.
- The wait has a bound, and the bound only ends a hang: it is the hang bound of the tests, 60 s. When it ends, the window writes one line on the log, and it waits no more: each frame is then left out at once, until the compositor reads again. A compositor that is stopped costs a process one bound, one time.
- The window layer calls `display.canvas_wait` at the end of each frame. A frame that is left out changes no state: the next frame is compared with the last frame that was presented.
- A process that serves other processes in the thread of its window asks `display.canvas_free` before it builds a frame, and never waits. When the answer is no, the wait of its loop (`display.wait_events`) ends when the compositor has read. `heron`, `manual`, `terminal`, `remote`, `server`, `log` and `quic_echo` do this.
- A process that draws by hand in the canvas calls `display.canvas_wait` before it draws, and draws the whole canvas: the canvas holds the frame of two frames before.

**The proof is two counts of the compositor.** The compositor cannot see a write. It sees which picture each `Present` names. A process that draws in the picture on the screen must name that picture again, because it has no other complete picture to name. So the compositor counts, for each window, the `Present` records that named the picture that it already showed (`pictures_drawn_again`), and the frames that it composed from a picture of the window (`frames`). The export `windows` gives both. The main test types one line in the console and waits for 0 windows with a picture drawn again.

## The screen: two screen pages and a page flip

The rule holds for the frame of the compositor too: the screen shows each frame of the compositor whole. The compositor composes a frame in its own memory, then puts the damage rectangles on the screen. The display reads the screen while the compositor writes it, so a frame that changed in many rectangles, or a large rectangle, could show the top of the new frame over the bottom of the frame before.

**The device of the test machine.** The q35 machine of QEMU has its standard VGA at the place 1 of bus 0. The firmware sets its mode with the display registers of Bochs, and the framebuffer of the firmware is the start of its video memory, 16 MiB, in its base address register 0. The display registers are 16-bit words at 0x500 in its base address register 2. The register `Offset_Y` names the first line that the display shows. The [reference screen](../../../docs/glossary/desktop.md) of 1920 by 1080 pixels is 8 294 400 bytes, so the 16 MiB hold two [screen pages](../../../docs/glossary/desktop.md) with 188 416 bytes to spare, and `Virtual_Height` is 2184 lines, 24 more than two screens. The machine command passes no option for it: with `-global VGA.vgamem_mb=16` the firmware gave no graphics output. The tool names the amount of QEMU with no option (`MACHINE_VIDEO_MEMORY_MIB`), and the compiler checks that two pages of the reference screen fit in it: a larger screen fails the build of the tool, not a machine test.

**The chosen form: a page flip.** The compositor writes the screen page that the display does not show, then writes the line of its start in `Offset_Y`: a [page flip](../../../docs/glossary/desktop.md). The display then shows the new page in one step. The next frame goes into the other page.

- **The debt of each screen page.** A screen page holds the frame of two frames before. The compositor keeps, for each page, the rectangles where it differs from its frame in memory, with the procedures of the window layer (`interface.Picture_Debts`): a frame copies its damage rectangles and the debt of the hidden page, then the shown page owes the damage of that frame. A page whose state is not known (at the start, after a refused flip) is copied whole. The rule and its tests are the ones of the pictures of a surface.
- **The root service finds the device.** It holds the configuration of the bus. It checks the identity of the device (vendor 0x1234, device 0x1111), that the framebuffer of the firmware starts at its base address register 0, that the registers say 32 bits a pixel, the size of the screen and a line as long as the line of the framebuffer, and that the video memory holds two pages. Then it gives the compositor the memory of the two pages and the page of the display registers, in place of the framebuffer of the firmware. Else it gives the framebuffer of the firmware, as before, and no registers.
- **The root service never sizes the base address registers of the VGA.** A size of a base address register is a write of all ones into it with the memory of the device off. The video memory is the screen that the display shows at that time, and the boot display of the root service is on it. Under KVM, QEMU then deletes the memory slot of the video memory, and KVM throws away every nested page table entry of the machine: every page of every processor faults again, and a debug exception whose delivery faults that way gave one `int1` two times on an AMD host. While the memory is off, a write to the screen is lost and a read gives ones. So the root service reads the two addresses only, with no write, checks that the device answers its memory, and takes the size of the video memory from the display registers: `Video_Memory_Blocks` (in units of 64 KiB) and `Virtual_Height` must each hold two screens. Refused: a size before the boot display, which still turns off the framebuffer that the firmware and the boot program gave; a size of the length of the framebuffer, which the firmware does not give.
- **The memory of the two pages keeps the cache rule of the framebuffer of the firmware.** `Device_Create` of the kind `Memory` maps registers with no cache, which is right for a register and slow for 8 MB of pixels: on a processor of AMD the hypervisor follows that page attribute. The kind `Display_Memory` makes the same device memory with the page attribute of the framebuffer of the firmware. It is an argument of an existing operation, not a new operation.
  - The kernel accepts it only for a range that holds the address of the framebuffer of the firmware, which the boot record gives; else `Bad_Operation`, with an error record of the kind `Bad_Value` whose limit is that address. Over registers, a cached type lets the processor read a register ahead of the process, and a read of a register has an effect. Over frames that another handle maps with no cache, two memory types for the same frames are undefined for the processor. Refused: the rule in the contract alone, which the kernel does not hold. A second display is a later decision.
  - The object has no requester for the IOMMU. Pixels process no access of the device, and a requester would add the lines of a device that no unit covers to the log, and refuse a map into another process for no reason.
  - The memory type is the default entry of the page attribute table, which the kernel does not process, so the memory type ranges (MTRR) of the firmware decide it, as for the framebuffer of the firmware before. Under KVM the video memory is memory of the host: the type is fast and right. On a real machine the firmware usually makes the range "no cache": right, with no gain. A firmware that leaves device memory as write-back makes the pixels stay in the processor until an eviction.
- **The display shows the page 0 at the start.** `bochs_display.screen_pages` gives two pages only when `Offset_Y` is 0: the compositor takes the page 0 as the shown page and writes the page 1 first. A display that shows another page gives one screen page.
- **A fence before each flip.** `page_show` runs a full memory fence before its write of `Offset_Y`. A volatile store orders no other store, and with a memory type that is not "no cache" the pixels of the page could still be in the processor when the display shows it. It costs one fence for each frame.
- **The compositor reads `Offset_Y` back after each flip.** QEMU sets the offset to 0 when the page does not fit in the video memory. A value other than the one written is a refused flip: the compositor writes one line, shows the page 0 again, and copies each later frame into the page 0, as with no device. `frames_on_the_shown_page` in the row of `compositor.screen()` counts the frames written into the page that the display showed.
- **A failure of the start shows the page 0.** The root service draws the failure on the framebuffer of the firmware, which is the page 0. It stops the compositor, then writes 0 in `Offset_Y`.

**The proof is two counts of the compositor.** `page_flips` counts the flips, and `frames_on_the_shown_page` the frames that it wrote with no flip. The main test asks the console for the count of the rows of `compositor.screen()` whose `frames_on_the_shown_page` is not 0, and waits for 0. The compositor writes one line at its start that says which form holds.

### The refused forms of the screen

- **A wait for the vertical blank.** QEMU has none: the retrace bit of the VGA changes at each read of the status register, and the display of QEMU reads the video memory at the refresh time of its interface, which the machine does not know. A wait on that bit waits for nothing.
- **The page flip of the firmware.** The graphics output protocol of UEFI has no page flip and no vertical blank, and its services end before the kernel starts.
- **A faster copy.** It makes the cut shorter, not absent.
- **The virtual GPU for the test machines.** The machine of `modustool run` shows the screen through the scanout of the virtual GPU ("The screen through the scanout of the virtual GPU", below). The machines of the tests keep the standard VGA and its flip, which the main test checks; the part `gpu_scanout` checks the scanout.
- **A device service for the display.** The compositor owns the display, as it owns the framebuffer. A service between them adds one message at each frame for one register write.
- **Three screen pages.** A flip on this device takes effect when the write returns (see the subtle points), so the compositor never waits for a page.

### The subtle points of the screen

- **A flip on this device ends when its write returns.** A register write of the device takes the lock of QEMU that the display update holds while it reads the video memory. The write waits for an update that reads, and each later update reads the new page. So the page that the display showed before is free at once. A real device latches the new start at its next vertical blank: there, the compositor must wait for that blank before it writes the old page. This form does not hold on such a device.
- **A picture that QEMU takes can still read a page that the compositor writes.** The `screendump` of QEMU reads the shown page after an update, and the lock of QEMU can be free between the two. A flip in that time lets the picture read the page that the compositor writes next. The machine test takes a picture of a settled screen, which draws no frame.
- **A flip costs the display of the host a redraw of the whole screen.** QEMU redraws the whole screen at its first refresh after a change of `Offset_Y`, whatever the damage of the frame. Measured on the machine of `modustool run` (KVM, 1920 × 1080, the GTK display in Xvfb, pointer moves at 125 each second): the compositor drew 56 to 60 frames each second, and QEMU gave GTK about 50 updates each second of about 1.3 million pixels each, against 2 each second at rest. With one screen page, QEMU redraws only the lines that the frame wrote. The cost is on the host and not on the machine; a display of the host with no GPU scaling pays it at each frame. The scanout of the virtual GPU removes it ("The screen through the scanout of the virtual GPU").
- **The first frame is copied whole into the page 1.** The page 0 shows the boot display of the root service until that flip.
- **The other devices that the root service sizes are not in use.** `driver_start` sizes the base address registers of each virtio device before it starts its service. The firmware resets those devices when it ends its services, and no process uses one yet; their registers are device memory with no memory slot of RAM in QEMU, so a size of them throws away no nested page table. The video memory is the one device memory that a process and the display use when the root service finds it. The other devices behind a conventional bridge are not sized either: their service only holds the first page of one register to name each of them for the IOMMU ([iommu.md](iommu.md)).
- **The registers page holds the other registers of the VGA too.** The compositor could change the mode of the display. It owns the display: a change harms the screen only, which it already writes.

## The screen through the scanout of the virtual GPU

On a machine with a VirtIO-GPU, the compositor puts each frame on the screen through the 2D scanout of the device, with the damage rectangles of the frame. The host then redraws only what changed, and each frame stays whole.

**The device of `modustool run`.** QEMU gives it as `virtio-vga` (`-vga virtio`): a VirtIO-GPU with the VGA of QEMU inside. The firmware and the boot program draw on its VGA part, whose video memory is its base address register 0, as on the standard VGA. The display of QEMU shows the VGA part until a driver sets a scanout, then the scanout. `virtio-gpu-pci` with no VGA was refused: its graphics output in OVMF has no framebuffer (base 0, 1280 × 800 only, measured), so the boot program, the root service and the compositor get no screen.

**The chosen form: one resource on the scanout, one batch for each frame.**

- **One resource, one screen memory.** At its start, the compositor creates its screen memory: physically contiguous, the pixels of the screen and one page after them for the damage rectangles. It gives it to `gpu_device` (`Attach_Framebuffer`), which creates one 2D resource with that memory as its backing and sets it on the scanout, once. The host keeps its own copy of the resource; a transfer copies a rectangle of the backing into it, and a flush shows a rectangle of it.
- **One batch for each frame.** The compositor copies the damage rectangles of a frame from its frame in memory into the screen memory, writes their list in the last page, and sends one `Present_Frame`. `gpu_device` copies the list out of that page, checks each rectangle against the resource, and gives the device, for each rectangle, a `TRANSFER_TO_HOST_2D` then a `RESOURCE_FLUSH`, all in one batch: each request is in the queue before one publish of the index of the driver and one notice. It answers when the device used every request.
- **Why the batch keeps the frame whole.** The display of the host shows the host copy at each flush. QEMU takes each request that a notice made visible in one bottom half of its main loop, and its display draws in another turn of that loop: no draw comes between two requests of one batch. With one exchange for each request, QEMU could draw after the flush of the first rectangle and before the transfer of the second.
- **The compositor writes the screen memory only when no present is in flight.** The device reads the screen memory during the transfers. While a `Present_Frame` waits for its answer, the damage of each new frame joins the damage that waits (`interface.Damage`), and the compositor draws on in its frame in memory. When the answer comes, it copies the damage that waits and sends it. A slow host merges frames; it never holds the compositor, which never waits for the answer. `frames_merged` in the row of `compositor.gpu_info()` counts the frames whose damage waited.
- **No debt.** The host copy holds each frame whole, and the screen memory holds each rectangle that the compositor copied: a frame transfers its own damage only.
- **At most `PRESENT_RECTANGLE_CAPACITY` rectangles a batch** (15): a rectangle is two requests of two descriptors each, and the control queue of the service has 64 descriptors. A frame keeps at most 8 damage rectangles, and the damage that waits merges into 8, so the bound never binds; the service refuses a longer list.
- **The first present is the whole screen.** The host copy of a new resource is black.

**The root service never sizes the base address registers of the GPU that holds the framebuffer of the firmware.** A size turns the memory of the device off, so it would turn off the screen of the firmware and delete the memory slot of the video memory under KVM ("The root service never sizes the base address registers of the VGA", above). When a base address register of the GPU holds the address of the framebuffer of the boot record, the root service takes the size of the memory of each other base address register from the capabilities of the device, with no write: the extent of each virtio structure (`virtio.register_extents`) and of the MSI-X table and its pending bits. The register of the video memory gets no handle: `gpu_device` never reads it.

**The proof.** `gpu_device` writes the binding of the scanout and its first batch; the compositor writes one line at its start that says that the screen is the scanout, and gives `presents` and `frames_merged` in the row of `compositor.gpu_info()`. The part `gpu_scanout` boots the machine of `modustool run` with a display of VNC, checks these lines, and compares the screen that a viewer of `remote_display` rebuilds from the frame of the compositor with a picture of QEMU of the same moment.

### The refused forms of the scanout

- **Two resources and a `SET_SCANOUT` at each flip.** It keeps the frame whole as a flip does, but QEMU 10.2 replaces the surface of its display at each `SET_SCANOUT` that names other pixels (`virtio_gpu_do_set_scanout` calls `dpy_gfx_replace_surface`), and the display then redraws the whole screen: the cost of the flip of the standard VGA, at each frame.
- **The frame in memory as the backing.** No copy, but the device would read the frame while the compositor draws the next one, or the compositor would wait for each answer.
- **One exchange for each request.** It was the first wiring: a draw of the host can come between two rectangles of one frame, and the compositor waited for each answer.
- **The compositor as the driver of the device.** It saves the message of each frame, but the device has one driver, and `gpu_device` also holds the Venus context of the GPU ([features/gpu_access.md](../features/gpu_access.md)).
- **`virtio-gpu-pci` and `-vga none`.** The firmware gives no framebuffer (above).
- **The hardware pointer of the device.** The cursor queue would move the pointer with no frame. It is a later step: the pointer is a part of the frame today, and of the capture of the screen.

### The subtle points of the scanout

- **The whole frame rests on the bottom half of QEMU.** A device that draws between two requests of one notice would show a part of a frame. The VirtIO specification says only that a flush updates the display; the batch is the strongest form that it allows.
- **A refused present ends the scanout.** A `Present_Frame` that the service refuses, or no answer in the hang bound, writes one line; the compositor then copies each frame into the framebuffer of the firmware, which the display no longer shows on `virtio-vga`. The machine of `modustool run` is the only machine with the scanout, and the part `gpu_scanout` fails on that line.
- **A picture of QEMU reads the host copy.** `screendump` of the console of the GPU reads the copy that the transfers wrote, after the last batch: a settled screen gives the frame of the compositor.

## What a stopped or hostile process shows

- **A process that stops in the middle of a draw**: the screen keeps the last picture that the process presented, whole. The picture that was being drawn was never named.
- **A process that never presents**: its window has its frame and the background color.
- **A hostile process** holds the right to write both pictures: it can write the picture that the compositor reads. The screen then shows a mix in the window of that process, and nowhere else. The compositor reads the surface as pixels only, waits for nothing, and checks each number of a `Present` against the size of the surface. No rule of the compositor can stop this write, so the rule does not try: the count `pictures_drawn_again` says it for a process that presents, and a process that harms only its own window harms no other process.

## The memory

A window of 1024 by 720 pixels is 720 pages for a picture: the second picture adds 2.8 MiB. The 51 processes with a window add about 76 MiB in all when each of them runs, by a count of their window sizes. How many run at one time in the main test is not counted here: the measure of the root service gives the margin of a run. The budget of a process moves pages from the root service when the process starts, so the cost is in the budget of each process:

- A process with the usual budget of 2048 pages and no other large memory has room for a second picture.
- The budgets of the processes that had less room than a second picture, or a room that no count gives, are larger by 1024 pages: `kernel_events`, `extended_state`, `scheduler`, `errors`, `quic_echo`, `server`, `address_space`, `rings`, `pointers` and `vector_glyphs`. The budget of `budget` is larger by 256 pages.

## The refused forms

- **Two pictures as an option of the process.** It was the form before: three processes asked for two pictures, 48 did not, and each of the 48 could show a mix. A rule that a process must ask for is not a rule of the system.
- **Two pictures only in the window layer, and the processes that draw by hand apart.** The 11 processes that draw by hand then keep one picture, or need a second form of the rule. One form in `display` covers both.
- **One picture, and a word that says "the process draws".** The compositor then skips the window or copies it while the word is clear. A process that always draws, or that stops in the middle of a draw, keeps the word set: the compositor shows an old frame for ever, or it reads a picture that is being drawn. A copy by the compositor is also work of the compositor for each window, paid by its budget, and its length is chosen by the process.
- **One picture, and the compositor waits for the process.** A process must not hold the compositor.
- **Three pictures, so that the process never waits.** It is one picture more for each window, and the process still needs to know which picture the compositor reads: the same count of the ring.
- **A table for each picture, in the memory of the process.** It was the form of the three processes with two pictures. Each process must give the memory of a third table and of its text, and the 48 other processes would each change. The debt of a picture is 8 rectangles in the window layer.
- **A copy of the changed rectangles from the shown picture into the drawn one.** It needs no debt, but the drawing module draws in the canvas of the caller, and a copy is a second way to bring a picture up to date. The debt uses the one draw.
- **A wait of 1 ms, then a new look.** It was the form of the three processes. It is a fixed delay: the frame is late by up to 1 ms for nothing, and a thread wakes with no cause.
- **A wait with no bound in the window layer.** A compositor that is stopped by a debugger would stop each process with a window, among them a service.
- **A line of the log for each window that says "two pictures".** It is 51 lines in a bounded log, and it proves the option, not the behavior. The counts of the compositor are one check.

## The subtle points

- `canvas_free` reads a count that the compositor writes when it takes a record, before it changes the picture that it reads. Both are in one turn of the one loop of the compositor, with no frame between them, so the count is enough.
- The compositor wakes a thread that waits for the canvas with the flag of the ring that says "the writer waits". It enters the kernel for that wake only when the flag is set.
- **The wait is on a value that was read.** The compositor adds 1 to the count of the records read for each record of any kind, not only for a `Present`. So the wait list holds the count with the value that the thread read, and only when that value says "not free". Each record that the compositor takes after that read changes the count and ends the wait, and the thread asks again. The proof that no wake is lost: the thread sets the flag "the writer waits", then the kernel reads the count; the compositor writes the count, then reads the flag. One of the two sees the other.
- **When the canvas is free at that read, the list gets no word.** The list is marked full, which ends the wait at once with no kernel entry. The form that was refused: a wait on the count plus 1, "a value that the count does not have". The compositor can take one record more (a pointer shape that the process sent after its `Present`) before the thread sleeps. The count then has that value, the flag was not set when the compositor read it, and the thread sleeps with no wake to come.
- **One "no", one wake.** A process that asked `canvas_free` and got no has a mark in its window. `display.wait_events` adds the event of the surface while the mark is set, and the mark is cleared when the wait finds the canvas free. A process that does not ask again then sleeps in its next wait: it does not turn with no sleep.
- **One thread owns a window.** The flag of the ring is cleared after a wait, so a second thread that waits on the same window would lose its wake.
- **A turn of the compositor has a bound.** The compositor takes from the ring of a window the records that the ring holds at the start of the turn, at most its capacity, and no more (`system.records_of_turn`). A process that writes as fast as the compositor reads then cannot keep it from the frame, the input and the other windows.
- **The wake costs the compositor one kernel entry, and the process chooses it.** The flag is in memory that the process writes. A process that sets it at each turn costs one wake for each turn in which it also sent a record: the cost has the bound of the sends of that process.
- **A `Present` with a picture number that names no picture is refused and counted** (`presents_refused` in the export `windows`). It changes no picture and no damage, and it is not a first `Present`: a window shows only a picture that its process named.
- A frame that is equal to the last table draws nothing and presents nothing, also when its picture has a debt: the screen shows the other picture, which has none.
- The time of a wait for the canvas is not in the measure of a picture: `display.canvas_wait` moves the start of the measure by the time that it waited.
- A process that draws over the frame of the window layer by hand (`interface_font`, `vector_glyphs`) ends its frame with `window_frame_end_into_picture`: the window layer draws the frame whole into the hand picture of the window and presents nothing, the process draws over it, then shows the picture with `hand_picture_show`, which ends a frame of its own with `window_frame_end`.
- `interface.window_events` says that an event came when a frame was left out and the canvas is free again: a process that draws only after an event then draws the frame.

## The state

Built: the screen through the scanout of the virtual GPU (the batch of each frame in `gpu_device`, the present that never holds the compositor, the BARs of the GPU of the screen with no size, `-vga virtio` for `modustool run`, the part `gpu_scanout`, and the host tests of the present list and of the extents of the registers); two pictures for every surface, the debt of each picture, `display.canvas_wait`, the first picture after the first `Present`, the bound of a turn of the compositor, the three counts in the export `windows`, the step of the main test, the host tests of the debt rule, of the procedures of `window_frame_end` on a window in plain memory, and of the bound of a turn. The root service writes one measure when the console is started: the free pages of its budget, now and at the lowest. The two screen pages of the standard VGA, the page flip, the debt of each screen page, the read back of each flip, the kind `Display_Memory`, the two counts in the export `screen`, its step of the main test, and the host tests of the checks of the display registers and of a flip on registers in plain memory.

Left:

- No page flip on a display with no registers of Bochs and no VirtIO-GPU: a real device. A real device also needs the wait for its vertical blank before the old page is written.
- The hardware pointer of the VirtIO-GPU: the pointer still moves by frames.
- The memory type of the screen pages and of the framebuffer of the firmware: their mappings select the entry 0 of the page attribute table, so the type is the type of the memory type ranges (MTRR) of the firmware, which is write-back on a firmware that leaves device memory so. The kernel now writes write-combining at the entry 1 of the table on each processor at its start, for device memory of the kind `Memory` ([gpu_access.md](../features/gpu_access.md), "Write-combining device memory"). The fix for the long term is that `Display_Memory` and the framebuffer of the firmware use that entry too.
- The page tables of the two screen pages are paid by the budget of the compositor: its stated working memory is larger by 4 pages. Large pages for device memory would remove them.
- No host test of the copy of the debt of a screen page in the compositor: the procedures of the debt have their tests in the window layer, and the copy writes the device memory.

- No host test of the wait itself (`canvas_wait` while the canvas is not free, the wake of the compositor): it enters the kernel. No host test of `window_frame_end_into_picture`, which reads the clock, nor of a difference or a draw that the drawing module refuses.
- The measure of the root service is written at the end of the start. The lowest count of a whole test, with the processes that the console starts later, is not written: the log of the main test has little room for more lines.

- A process that draws only after a change of its own, and reads its events with `display.next_event`, does not draw a frame that was left out when the compositor reads again. It draws it at its next change. This needs a compositor that did not read for the whole bound.
- No check reads the pixels of the screen for a mix. The counts say what each process named, not what it wrote.
- The budgets were raised from a count of the pages of each process, not from a measure of a run.
