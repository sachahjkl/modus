# A guest

A process runs another system on the processor, with the virtualization support of the processor. The kernel holds the mechanism: the nested page table, the state of the guest processor, the entry and the exit. The process holds the policy: the memory that the guest gets, and the answer to each exit. The terms are in [`docs/glossary/access.md`](../../../docs/glossary/access.md), "Guest". The guide is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "A guest". Why a foreign system runs whole in a guest is in [foreign_systems.md](foreign_systems.md).

## Constraints

- **The kernel holds mechanism only** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). No device model, no emulation of an instruction, no firmware is in the kernel.
- **A guest holds only what its process was granted** (property 2, and "Objective"). It reaches the memory objects that its process mapped into it, and nothing else of the machine.
- **Each new kernel operation has its reason.** The bound of [foreign_systems.md](foreign_systems.md) is three to five new operations for the whole of the guest support. The guest support uses one: `Guest_Run`. Each later capability is a field of its record, an argument, or a flag of an existing operation.
- **The test host is an AMD processor.** Nested virtualization of KVM gives a test machine the form of the host processor only: on this host, the AMD form (SVM). The form of Intel (VMX) cannot be tested here.

## The chosen form

### A guest is a process whose page table is the nested page table

A guest is a process that `Process_Create` made and that no thread ever ran. Its page table becomes the nested page table of the guest: a guest physical address is an address of that process. `Memory_Map` with the process handle puts a memory object at a guest physical address; `Memory_Unmap` removes it; `Handle_Revoke` of the memory handle ends the mapping, as in any process. A page on first use gets its frame when the guest first touches it.

Two forms of `Memory_Map` exist for guest memory only, into another process that no thread ran:

- `At_Address_Zero` puts the mapping at the address 0, the guest physical address 0. The address argument 0 keeps its meaning "the kernel chooses".
- `Write` with `Execute` and `No_Access` makes a mapping whose pages get `Write` or `Execute` in turn: `Memory_Protect` with the process handle switches the whole mapping. No page table entry is ever writable and executable.

`Process_Start` refuses a process that holds such a mapping (`Bad_State`): a thread there would run with no fault at the address 0, or on pages that it writes and then executes.

The reasons:

- One page table structure of the kernel serves a process, a guest and, later, a device. The format of the long mode page table is the format of the nested page table: each entry of a process has the bit User, which a nested walk needs.
- The mapping, the revocation, the budget of the page tables, the origin tree and the shoot-down exist and are tested. A second address space object would copy each of them.
- The guest is visible as a process in each report: its name, its mapped pages, its stop.

The first run makes the process a guest, under its process lock: the kernel removes the time page and clears the kernel half of the top table. After it, `Process_Start` of that process gives `Bad_State`: a thread with the page table of a guest would run with no kernel half. The first run of each guest processor takes two pages from the budget of the process: its control block and its extended state.

### One operation: `Guest_Run`

`Guest_Run(process, registers, processor)` runs one guest processor of a process on the calling thread until an exit that the kernel does not handle itself. The completion record of the operation is the exit: a record on the kernel ring of the thread. The reason for a new operation: the instructions that enter a guest are privileged, and no existing operation runs code of another address space on the calling thread.

- `registers` is a `Guest_Registers` record in the memory of the caller: the general registers, `rip`, `rflags`, `cr0`, `cr3`, `cr4` and `efer` of the guest processor. The kernel copies it before the entry and writes it back after the exit. The process answers an exit by a change of the record: the value of a port read in `rax`, the next instruction in `rip`, the new value of a write of `EFER` in `efer`.
- `processor` is the index of the guest processor, from 0 to `GUEST_PROCESSOR_CAPACITY - 1` (4 guest processors).
- The segments, the descriptor tables and the extended state of the guest processor stay in the kernel between two runs.
- A guest processor starts in 16-bit real mode, with each segment at base 0.

The record holds two requests of one run. The kernel serves each one before the first entry of the operation, and clears it in the record that it writes back:

- `mode_load` (`Guest_Mode_Load`): `Real_16`, `Protected_32` or `Long_64` loads the segments of that mode and the privilege level 0, with the selectors of the record. `Keep` (0) loads nothing. A process starts a system in long mode with one run, then passes back the record that it got.
- The event (`inject_kind`, `inject_vector`, `inject_error_code_valid`, `inject_error_code`): an external interrupt, the non-maskable interrupt, an exception or a software interrupt, which the processor delivers through the interrupt table of the guest at the entry (AMD `EVENTINJ`).

The run is an operation of the calling thread, not a thread state of its own. The thread is the guest processor while the operation runs; its process pays the time, as for any instruction of the thread. A process that wants several guest processors runs several threads, each with its own index.

### The exits

The kernel handles one exit itself: a nested page fault on a page on first use of a mapping that allows the access. It gives the page its frame and enters the guest again.

Each other exit ends the operation with an exit record (`Guest_Exit_Kind`):

| Exit | What the process gets |
|---|---|
| `Port_Write`, `Port_Read` | The port, the size, the value of a write, the address of the next instruction |
| `Halt` | The address of the next instruction |
| `Cpuid` | The registers hold the leaf; the process writes the answer |
| `Memory` | The guest physical address and the access: no mapping there, or a mapping that refuses the access |
| `Interrupted` | An interrupt of the machine ended the run: nothing to answer, run again |
| `Shutdown` | The guest processor stopped on a triple fault |
| `Refused_State` | The processor refused the state of the guest |
| `Other` | Another intercepted instruction or exception, with the exit code of the processor |

The guest intercepts each port, each model-specific register, `rdpmc`, `cpuid`, `hlt`, the instructions of virtualization, `xsetbv`, `invd`, `wbinvd`, `monitor`, `mwait` and each access to a debug register. Each of these touches a state that the guest processor shares with the kernel or with other processes (`rdpmc` reads the performance counters of the machine), or a device of the machine: the kernel does not run it on behalf of a guest.

The guest also intercepts two exceptions of its own: the debug exception (`#DB`, exit code 0x41) and the alignment check (`#AC`, 0x51). A guest that owns its interrupt table and its stack can make the delivery of one of them raise it again: the processor then loops inside the delivery, takes no interrupt, never exits, and each processor that waits for it stops too. Each arrives as an exit `Other`, with no kind of its own. The process gives the exception back to the guest with an event of the kind `Exception` at the next run: a guest that needs single steps or the alignment check keeps them, and a loop in the delivery still exits at each step. The instruction `int1` (icebp) raises a debug exception that the exception intercept does not cover: it has an intercept of its own, which the kernel sets, and arrives as an exit `Other` with the exit code 0x88; `guest_demo` checks it.

A nested page fault with the reserved bit set ends the run with the exit `Memory` and one line of the log; it does not stop the machine. A guest may cause it with an address past the width of the nested table, and no exit that a guest can cause stops the machine.

### The run, step by step

1. Under the lock of the caller: the handle with **Control**, the copy of the registers record. Then the checks of the record (`guest_registers_check`) and of the index of the guest processor, with no lock.
2. Under the lock of the guest process: its state (`Created`, no thread), the setup of the first run of the process and of the guest processor, the flag `running` of the guest processor, and one hold of the process, as a thread on a processor holds its process.
3. With no lock, once: the mode load and the event in the control block. The flag `running` gives the run its guest processor alone.
4. With no lock: the save of the extended state of the thread, the restore of the extended state of the guest, the entry, the exit, the save of the guest and the restore of the thread. Interrupts of the machine are on during the guest, so that a timer tick, a wake and a shoot-down end the run at once.
5. A nested page fault on a page on first use: the kernel gives the page under the guest lock, and goes back to step 4.
6. The served requests leave the record. Under the guest lock, the flag `running` clears. The hold ends: a stop of the guest process during the run cleans the process up here, as the last processor of a stopped process does.
7. Under the lock of the caller: the copy of the registers back, and the exit in the completion record.

### A machine with no support

A processor with no SVM, no nested paging, SVM turned off by the firmware, or fewer than two address space identifiers gives `Bad_Operation` with the error kind `Unsupported` for each `Guest_Run`. A process learns it from its first run. The log of the boot says which.

## Refused forms

- **Intel VMX first.** It cannot run on the test host: KVM on AMD gives a guest SVM only. A form that no test runs is not built first. VMX is the next form, with the same operation and the same records.
- **A hypervisor in the kernel with device models** (the form of KVM with its emulated devices, or of a type-1 hypervisor). It puts the code of the devices, which a guest drives with hostile values, in the kernel. Property 7 forbids drivers in the kernel; a device model is a driver of the other side.
- **A type-2 hypervisor in a process with no kernel help.** A process cannot run the privileged instructions of virtualization; the only form left is an emulator of the instructions, two orders of magnitude slower, which the processor support makes needless.
- **A Guest object kind with its own handle.** A second kind of address space would copy the mapping, the revocation and the reports of a process. The process is the address space; the guest processor is its state.
- **One operation to create a guest.** The first run makes the guest. A creation operation would add a kernel operation for one setup that has no other argument.
- **The exits on a ring of their own.** The completion record of the operation is already a record of a ring, and the thread that runs the guest waits for nothing else while it runs.
- **The guest processor as a thread state that the scheduler runs.** It puts the entry of a guest on the path of the scheduler, and a second kind of thread in each strategy. The thread that calls `Guest_Run` is the guest processor; the scheduler sees one thread.
- **A mode that each run loads.** A field of the mode that the kernel applies at each run writes the segments again at each run, over the segments that the guest loaded itself: a guest in real mode changes `ds` all the time, and a guest in protected mode has segments that the kernel cannot read from its descriptor table. The load is a request of one run; `Keep` is its zero.
- **The control registers that stay in the kernel only.** The guest writes them itself, but the process must answer a write of `EFER`, which exits, and must start a guest in long mode. A record that carries them in and out does both with no new operation; the cost is 48 bytes of record.
- **Pages that are writable and executable for a guest.** Property 11 says that a page of code that a process writes is never writable and executable at once. A guest mapping switches between `Write` and `Execute` with `Memory_Protect`; each write to a page in `Execute` exits as `Memory`, and the process switches the mapping. The cost is one exit at each switch.
- **The address of `Memory_Map` with one more meaning.** The address 0 means "the kernel chooses" for each process. A flag, `At_Address_Zero`, names the address 0 with no change of that meaning.
- **An operation for each new capability** (an operation to inject, one to load a mode, one to make a guest processor). Each is a field of the record or an argument of `Guest_Run`: the operation count does not change.

## Subtle points

- **The extended state.** The kernel has no vector instruction, and the registers of a thread stay live through each kernel entry. A guest changes them. So the run saves the thread and restores the guest before the entry, and the reverse after the exit, with the three procedures that may name those registers. The save of the guest uses `xsave`, not `xsaveopt`: the guest can run `xrstor` at any address, and `xsaveopt` trusts the address of the last `xrstor`.
- **The state that the exit does not restore.** The exit gives back the control registers, the segment table and the stack, not `fs`, `gs`, the task register, the system call registers and the debug registers. `vmsave` and `vmload` keep the first four; the guest cannot write a debug register (each access exits), and the kernel writes the debug control register again after the exit, with the breakpoints of the thread when it has some.
- **The shoot-down.** A processor that runs a guest uses the nested page table of the guest process, not the table in its `cr3`. The kernel writes that table in a word of the processor before the entry, and `processors_with_table` reads it: an unmap in the guest process sends its interrupt to the processor that runs the guest, whose run ends at once. Each entry flushes the translations of the guest address space identifier, so no translation outlives an unmap.
- **One address space identifier.** Nested KVM gives 8 identifiers; the kernel uses one for every guest and flushes it at each entry. The cost is a cold translation cache after each exit. A generation of the nested table would keep it (not built: no measure asks for it yet).
- **The stop of a guest process.** `Process_Stop` of a guest process keeps the contract of a stop: when it returns, no instruction of the guest runs. `process_stop` adds each processor whose word of the running nested table names the table of the process to the processors that run its threads: each one gets the wake interrupt, which ends the run at once, and the stop waits for the hold of the run, as for a thread on a processor. A run that writes its word after the stop read it sees the state `Stopped` before its entry, and does not enter: each side writes, then reads the word of the other side.
- **An event that an exit interrupts.** An exit can come while the guest delivers an event: a page on first use of its interrupt table or of its stack, or an interrupt of the machine during the delivery. The processor gives that event in `EXITINTINFO`; the kernel copies it to `EVENTINJ` after each exit, and the next entry delivers it, in the same run or in the next `Guest_Run`. An event of an instruction (`int n`, `int3`, `into`) is not copied: the guest is still at that instruction, which runs again.
- **What a guest still sees of the machine.** `rdtscp` and `rdpid` give the processor number that the kernel wrote in `TSC_AUX`: a guest learns on which processor it runs, as a process does. A guest can turn on protection keys in its own `cr4` and write `PKRU`; the kernel does not save `PKRU` (it is not in `XCR0`), so the next guest on that processor can read it: a channel of 32 bits between two guests of one processor. A process has no such channel, because the kernel never turns protection keys on for a process. A clear of `PKRU` at each exit would close it (not built).
- **Long mode.** Each write of a model-specific register exits as `Other` (exit code 0x7C). The process answers a write of `EFER` with the new value in `efer` of the record and the next instruction in `rip`; the guest then turns paging on itself, and the processor sets LMA. A process that starts a system in long mode at once gives a record with `mode_load` `Long_64` and the control registers of long mode. The kernel always sets SVME in `EFER` and the extension type in `cr0`: the processor refuses a guest without them.
- **The checks of the record.** `guest_registers_check` refuses a bit that no processor defines in `cr0`, `cr3`, `cr4` and `efer`, an inconsistent long mode (LMA without LME, PG and PAE; LME and PG without LMA), and a non-canonical `rip` in long mode. The processor checks the rest at its entry, and refuses it with `Refused_State`: the kernel checks first only what gives a clearer refusal. The record that the kernel writes back is masked to the same bits, so that a process can always pass it back.
- **An injected event that an exit interrupts.** A nested page fault on the interrupt table or the stack of the guest can interrupt the delivery of an injected event. The guest processor keeps the injected word and the address of the injection (`Pending_Injection`) until the guest has received it. After each exit, an event in `EXITINTINFO` with the type and the vector of that word, with the guest still at that address, goes to the next entry again, whatever its type. The same event from an `int n`, `int3` or `into` of the guest is not delivered again: the guest is at that instruction, which runs again.
- **The return address of an injected software interrupt.** With NRIPS, the delivery of a software interrupt, `int3` or `into` pushes the address in `CONTROL_NEXT_INSTRUCTION`, which each exit overwrites. Before each entry that delivers such an injected event, the kernel writes the address of the injection there, so that the guest returns to `rip` of the record. Without NRIPS, the processor pushes `rip`.
- **An event waits behind an interrupted event.** After an exit that interrupted a delivery, the control block holds that event for the next entry. A request of the process then waits: the kernel enters with the interrupted event, and leaves the request in the record. After `Refused_State`, the kernel drops the event that it wrote, and the request stays in the record too.
- **The process checks that the guest accepts the event.** The processor delivers an injected event with no check of the interrupt flag of the guest or of its interrupt shadow. The process reads the interrupt flag in `rflags`. The interrupt shadow (after `sti` or `mov ss`) is not in the record, and no exit says that the guest opened its interrupt window (not built).
- **The injection of a machine check.** `Guest_Inject_Kind.Exception` refuses the vector 18: the kernel takes a machine check of a guest as a fault of the machine and stops it, and an event of the process must not do that.
- **Several guest processors.** Each one has its control block and its extended state, and its flag `running` under the lock of the guest process: one thread runs it at a time, and other threads run the other guest processors of the same guest at once. They share the nested page table and the address space identifier, which each entry flushes on its processor: two guest processors on two processors keep no translation that an unmap left. A stop and an unmap reach each processor whose word of the running nested table names the table of the guest, so they reach each running guest processor. A guest processor that a process never ran costs nothing. An interrupt between guest processors (an IPI of the guest) is a write that exits to the process, which injects the event in the other guest processor.
- **The check of the build.** `vmrun`, `vmload` and `vmsave` start with `v`, like the vector instructions that the check of the kernel refuses (`tools/modustool/build/vector_check.odin`). The check lets them through by the name of the procedure: in `guest_enter` only, and refuses them anywhere else.
- **No page is writable and executable.** The rule of a process holds in a guest. A guest mapping made with `Write`, `Execute` and `No_Access` gets `Write` or `Execute` in turn from `Memory_Protect` with the process handle, for the whole mapping: a part of a mapping takes away from its mapping only. A system that writes code beside its data in one mapping switches the whole mapping at each exit; a process that maps the code of the guest apart switches less (not measured yet).
- **Page 0 of a guest.** `Memory_Map` with `At_Address_Zero` maps at the guest physical address 0. `guest_demo` still starts at 0x1000.
- **Guest memory before the first run.** The two forms of guest memory need a process that no thread ran, not a process that is a guest already: a process loads the memory of its guest before the first run. `Process_Start` refuses a process with such a mapping, so a process with guest memory never gets a thread.

## State

Built: the AMD form, the exits of the table above, the page on first use, the test part `guest` with the process `guest_demo`. Built and checked by host tests only: up to four guest processors for each guest process, the injection of an event by the process, the control registers in the record and the load of a mode (long mode), the memory at the address 0, and guest memory that switches between `Write` and `Execute`. Left: a machine test that runs a guest in long mode on two guest processors with an injected interrupt, the interrupt window of a guest, the 64-bit system state that the record does not carry (`STAR`, `LSTAR`, `SFMASK`, the bases of `fs` and `gs`, `KERNEL_GS_BASE`: each access to a model-specific register exits, and the process has no way to write them in the guest processor), the Intel form, and Linux in a guest (`ROADMAP.md`).
