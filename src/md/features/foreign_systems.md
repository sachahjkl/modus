# Foreign systems: processes of Linux and of NT

The system implements no foreign interface. A foreign system runs whole inside a guest that holds only its grants ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective"). This file records the comparison that led to that rule, and the forms that were refused. The guest support that it asks for is in [guest.md](guest.md).

The rule is in [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective". The terms are in [`docs/glossary/access.md`](../../../docs/glossary/access.md), "Guest".

## The problem

The request was a layer for Linux processes, a layer for NT processes, and the access to a GPU (see [gpu_access.md](gpu_access.md)). The objective of the system said "no compatibility goal". The two could not both stand.

A layer for Linux presents `fork`, signals, a tree of files that all processes see, `/proc`, `ioctl`, `argv`, standard streams and user identifiers. A layer for NT adds a registry. The properties forbid each of these as a concept of the system.

## The scoping rule

The contradiction ends with one rule: foreign semantics exist only inside one foreign instance. The properties hold at the border of the instance and between instances.

- One instance for each launch. An instance holds only its grants.
- No native process sees a foreign interface. No native contract gets a foreign concept.
- Inside the instance the holes reopen: a child inherits, a global name exists, an install script runs with full access. Between two instances, and between an instance and the system, they stay closed.
- A foreign binary or a guest image is data in a store. It is not in the system description, and it runs only in a sandbox.
- Code of 32 bits runs only inside a guest. No contract of the system gets a form of 32 bits.

One reading of an older rule had to be corrected first. The rule "no backward compatibility" speaks of the older formats of the system itself. It does not forbid a foreign system in a guest.

## The forms for Linux

| Form | What it is | What the kernel needs that it does not have |
|---|---|---|
| A library in the same process | The layer is a module in the process. It loads one binary and serves its system calls with ring commands | The delivery of a foreign system call as a record; faults of every kind as records; a base register for each thread; a copy-on-write clone of a memory object; storage at the size of a tree of files |
| A layer in a separate process | The guest process holds no handle; the layer holds Control on it and the grants | The same, plus the control of the threads of another process and a pager for another process |
| A Linux kernel in a guest | A real Linux kernel, with its own processes, on the processor | Guest support: a second form of address space that the kernel builds from memory objects, virtual processors that run as threads, exits as records of a ring |

### The chosen form: a guest

- It needs no concept of the kernel that is specific to Linux. It needs guest support, and guest support also serves NT and the GPU.
- The two other forms write again about 200 system calls: tens of thousands of lines of layer code, and the upkeep of an interface that grows with each release of Linux.
- The size of guest support is known from a small hypervisor of the literature: a few thousand lines in the kernel, and the rest in the process that runs the guest.

### The refused form: a layer for one binary

A layer for one binary gives Linux binaries the place of first-class processes with typed grants. It is not planned. It is the only form that needs the foreign system call as a record, and binary rewriting does not replace that: the usual technique puts a trampoline at address 0, and this system cannot map address 0.

## The forms for NT

- **Wine as a Linux process, inside the Linux guest: chosen.** It needs no NT code in the system, so it adds nothing to the trusted code or to the interface.
- **A native NT layer: refused.** The system must write the side of Wine that meets the host: the system call dispatcher, the window layer over surfaces and input, a service in the place of the server of Wine, the registry. It is the largest work of the three.
- **Loading a Windows driver: refused.** A Windows graphics driver needs an NT kernel around it: an executive, a hardware layer, the device manager and the graphics kernel. One free NT system has a graphics kernel of about 128 000 lines alone. Display output from a vendor driver outside Windows was shown. No source shows 3D acceleration from one.
- **Windows, or a free NT system, as a whole guest**: the answer for a process that Wine does not run. It needs no mechanism past the guest and a firmware for it.

## One abstraction for three requests

A second address space is a page table that the kernel builds from memory objects, read by a guest processor (nested paging) or by a device (the IOMMU). One structure of the kernel then serves a guest and a device. The mapping operation that exists maps memory objects into it, and the exits of a guest arrive as records of a ring, as the faults do. This is the reason for the bound of three to five new kernel operations, each with its recorded reason.

## The subtle points

- **The network of a guest is not a raw frame grant.** A raw grant gives the guest the whole network identity of the machine. The process that runs the guest translates the TCP and the UDP of the guest to the grants of the instance.
- **The disk of a guest changes inside the guest.** It is data of the process that runs the guest, not a list of modules. The identity by hash stops at the image.
- **A guest that draws** gets a surface: its scanout becomes a surface of the compositor. No native process sees a foreign graphics interface.
- **The files that cross** between a guest and the system are the slow part of this form in other systems. They cross as granted objects.
- **The test host is an AMD processor.** Nested virtualization gives the test machine the AMD form of guest support, so that form comes first.
- **Three primitives are gaps of the native system too**: faults of every kind as records, the control of a thread with its registers, and storage at the size of a tree of files. They were built first, because each is useful with no foreign system.

## The machine of a Linux guest

A Linux kernel of 64 bits runs in a guest of [guest.md](guest.md), and the process that runs it answers each exit. The answers are pure code in `modus:contract/guest_os`, with no kernel operation, so a host test drives them with exits that it writes itself. The process `guest_builder` wires them to `Guest_Run` (`src/modules/system/guest_builder`).

### The chosen form

- **The 64-bit boot protocol of Linux, with no firmware** (`linux_boot.odin`). The process checks the image first: a bzImage of protocol 2.12 or later with a 64-bit entry, or a vmlinux (ELF64 for x86-64 whose segments name their physical addresses). It copies the kernel to its place, writes the zero page (the setup header of the image, the memory map, the command line), a page table that maps the first 4 GiB at their own address and the first 2 GiB again at `0xFFFF_FFFF_8000_0000`, and the descriptors of the protocol at the guest physical address 0. It enters the kernel in long mode with `rsi` at the zero page. A new guest processor already has its descriptor table at 0 with the limit 0xFFFF, so the descriptors need no field of the record.
- **Legacy devices that a kernel finds with no table** (`legacy_devices.odin`): the serial port 8250 at 0x3F8 (the console), the two interrupt controllers 8259, and the interval timer 8254. `cpuid` offers no local APIC, so Linux takes its interrupts through the controllers 8259 and its tick from the timer.
- **virtio over MMIO, version 2** (`virtio_mmio.odin`): a console, a read-only disk of inputs and a writable disk of outputs, at 0xD000_0000, 0xD000_1000 and 0xD000_2000, with the lines 5, 10 and 11. The command line names them (`virtio_mmio.device=`), so the kernel needs no PCI. No network device exists.
- **The decode of the instruction of a device access** (`instruction_decode.odin`). A memory exit gives the guest physical address and the access, not the instruction. The process reads the instruction at `rip` through the page table of the guest, decodes the forms of `mov` that a driver uses on a register of a device (88, 89, 8A, 8B, C6, C7, 0F B6, 0F B7), and writes the register with the rules of the processor. It refuses each other instruction, and an instruction whose access is not the access of the exit: the guest stops.
- **The model-specific registers** (`linux_machine.odin`). `EFER`, `STAR`, `LSTAR`, `SFMASK` and the three bases go to the record, so the kernel loads them in the guest processor. `CSTAR` and the `SYSENTER` registers stay in the machine. Each other register, the local APIC base, and each value that the processor refuses give a general protection fault, as a processor gives it: a change of `EFER.LME` while `cr0.PG` is set is one of them.
- **A virtual clock.** The time of the guest is a count of ticks of the timer that the process moves: a fixed step at each exit, and a jump to the next tick at `hlt`. The process injects the interrupt that the controllers give when the guest takes interrupts: the interrupt flag is set in `rflags` and the guest is out of its interrupt shadow.
- **The time stamp counter of the virtual clock.** `rdtsc` and `rdtscp` exit ([guest.md](guest.md)), and the machine answers with the clock times `LINUX_TIME_STAMP_COUNTS_PER_TICK` (1000: a counter of about 1.19 GHz that Linux calibrates against the timer), `rcx` 0 for `rdtscp`, and the next instruction. Each exit moves the clock, so two reads never give one value, and the count never goes back.
- **Memory in regions that switch.** The memory of the guest is one memory object, mapped in the guest in regions of 2 MiB (more for a memory past 120 regions) that are each writable or executable, never both. A write to a region in `Execute` exits, and the process gives the region `Write`, and the reverse.

### Refused forms

- **An emulator of the whole instruction set for device accesses.** A driver reaches a register of a device with a few forms of `mov`. Each form that the process decodes is a form that a host test checks; a form that it does not decode stops the guest, with no guess.
- **The local APIC and an I/O APIC.** Linux needs a table of the firmware (MP or ACPI) to use them, and an emulation of each. The controllers 8259 need neither, and a build runs on one guest processor.
- **PCI.** A bus to probe, configuration space, and its interrupts, for three devices whose places the command line can give.
- **One mapping of the whole memory.** Each switch between `Write` and `Execute` then changes the whole memory, and code that writes its stack switches at each instruction.

### Subtle points

- **The bytes of a guest are hostile.** Each descriptor, each ring index and each address that a driver gives is checked against the memory before a byte moves, with no overflow. A chain longer than its queue (a loop), an indirect descriptor (not offered), a readable buffer after a writable one, or more available chains than the ring holds ends the device: it sets `DEVICE_NEEDS_RESET` and serves nothing until a reset.
- **The read-only disk refuses each write.** The device offers `VIRTIO_BLK_F_RO`, answers each write with `IOERR`, changes no byte, and counts it. The builder takes the first refused write as a violation of the sandbox, and refuses the build.
- **The kernel image is hashed in the memory of the guest.** The builder copies the image once to the top of the guest memory, hashes that copy, parses it, loads the kernel below it, and clears the copy before the first run.
- **The time of a guest is not the time of a build.** The virtual clock moves at each exit, and the exits `Interrupted` come from the timer of the machine: their count depends on the machine. The time stamp counter follows the virtual clock, so the guest reads no time of the machine, but the count of exits still does. The output of a build must not depend on time, and only a comparison of two builds checks it ([recipes.md](recipes.md), "Subtle points and hazards").
- **An interrupt waits for the end of the shadow.** After an exit inside the shadow of `sti` or `mov ss` (an exit `Interrupted`, with `rip` unchanged), the machine injects nothing, and the interrupt comes at the next exit out of the shadow. An exit whose instruction the machine completes (it moves `rip`) clears the shadow, as the processor does: `sti; hlt` gets its tick at once.
- **The cost of the switch of a region.** Code and data in one region switch it at each change of access. The kernel of Linux aligns its text and its data on 2 MiB, so they fall in different regions; the processes of the guest share regions. No measure exists yet.

## The order

The primitives, then the IOMMU (a device reaches only the memory that its service was granted; the properties already require it on real hardware), then guest support, then Linux in a guest, then Wine in that guest, then the GPU. The order of the work is in `ROADMAP.md`.

## State

The three primitives are built, and the IOMMU of Intel. Guest support is built in its AMD form, with one new kernel operation: a guest is a process whose page table is the nested page table, and the exits arrive as completion records ([guest.md](guest.md)). The machine of a Linux guest above is built and checked by host tests only: no machine test boots a Linux kernel yet. Linux in a guest is the next step of this order.
