## Running code

### Process

A process is a module that runs: the realisation of that module in time, from its start to its stop.

A process holds its own address space, its own handles and its threads. Its starter makes it with `Process_Create`, maps its module, gives it handles, and starts its first thread with `Process_Start`. With the process handle, the starter stops the process and reads its stop report. When the last handle closes, the kernel stops the process. A process of this system has no parent that it inherits from, no fork, no global number and no ambient environment. It has only the handles that its starter gave it.

The design: `src/md/api/process.md`; `docs/ARCHITECTURE.md`, "K1. Handle table"; `docs/PROPERTIES.md`, "2. Sandbox by default".

Do not use: program, task, application, app.

### Process slot

A process slot is the place of a process in the table of the processes of the kernel: the index that `Inspect` with the kind `Process` takes, and that `Process_State` gives for a process handle.

A process slot serves a new process after the last handle of the process before it closes. So the slot alone does not name one process: with its process serial (`Process_Report.process_serial`), a number that changes for each new process in the slot, it does. The monitor and the inspect tool name a process by the two numbers; the disk process page names each disk process so.

A process slot is not a global number: no process names another process by it, and no operation acts on a process by its slot.

Do not use: process ID, PID, process number, program number.

### Stop cause

A stop cause is the fact that the kernel records of who or what stopped a process (`op.Stop_Cause`): the process itself, a holder of its process handle, a fault, the end of its last thread or the close of its last handle.

No process can forge it: the kernel decides it at each stop, and the first stop keeps it. A holder with Read reads it with `Process_State`, and `monitor.processes()` shows it in its column `cause`. It names no other process. For a fault, the vector and the stack trace are in the stop report. It is not the stop outcome, which the process chooses. Example: the console writes "the process calendar stopped: a fault, page fault".

The design: `src/md/api/process_stop.md`.

Do not use: exit reason, termination reason, signal, stop code.

### Stop outcome

A stop outcome is what a process says about its work when it stops itself (`op.Stop_Outcome`): done, failed, refused, or stopped on request.

The process passes it to `system.stop`, as in `system.stop(.Done)`. The kernel records it only with the stop cause `Itself`, and refuses an outcome from a holder, so `outcome == .Done` alone checks a clean stop. `monitor.processes()` shows it in its column `outcome`, and a start policy starts no row again after `Done` or `Refused`. It is a claim of the process about itself, not a proof of its work. A failed stop gives its reason in the log.

The design: `src/md/api/process_stop.md`.

Do not use: exit code, exit status, return code, stop code.

### Thread

A thread is one flow of execution inside a process: a register state, a thread record and a kernel ring.

The threads of a process share its memory and its handles. `Thread_Create` makes a thread: a budget pays for its slot and its thread area, and the call gives the entry address, the stack, one parameter and its thread schedule. The thread starts at the entry with the parameter in its first register. It asks the kernel for work through its own kernel ring, and waits with the word wait. It ends with `Thread_Stop`, by its own return, or by a stop of its process. A thread handle with Control ends it from another thread.

The design: `docs/ARCHITECTURE.md`, "K3. Scheduler".

Do not use: fiber, task.

### Thread record

The thread record is the page that a thread can read about itself (`op.Thread_Record`): its own address, the parameter of its entry, its number, its event word, and the fault ring when the thread is a fault handler.

The `gs` register of the thread holds the address of the record, and the first word of the record is that address, so `mov rax, [gs:0]` gives it on any stack. The kernel ring of the thread is one page after the record. The kernel writes the record when the thread starts; after that it only adds to the event word and writes the fault ring.

The record holds no data of a module: the system has no thread-local storage, and `fs` is free for the process.

The rule: `docs/MODULE_CONTRACT.md`, "Closed rules".

Do not use: thread-local storage, TLS, TEB.

### Word wait

The word wait is the one way for a thread to wait for something else than a time: the thread waits while each 32-bit word of a list holds a given value.

`Word_Wait` takes a list of words, each with the value that it holds while the thread waits, and a deadline. Another thread changes a word, then calls `Word_Wake` on it. If a word does not hold its value when the thread enters the wait, the wait ends at once, so no wake is lost. Two processes that map one memory object wait on one word. Every wait of the system uses it: a ring waits on its counters, a lock on its word, a thread on its event word.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait".

Do not use: futex.

### Lock

A lock is one word of memory that one thread holds at a time (`system.Lock`).

A lock takes no kernel entry when it is free: one compare-and-exchange takes it. A thread enters the kernel only to wait for a lock that another thread holds, with the word wait, and the thread that frees it wakes one waiter. A zero lock is free. A lock in shared memory works between two processes.

A lock of a process is not a lock of the kernel: the kernel has its own locks, which are words of the kernel that one processor holds.

Do not use: mutex, critical section, semaphore.

### Event word

The event word is a word of the thread record that the kernel adds 1 to when an event of the thread arrives.

The events are: an interrupt of the process, the stop of a process whose handle the process holds, and the end of another thread of the process. The thread reads the word, reads the state that it needs, then waits on the word with the value that it read first: an event between the read and the wait ends the wait at once. `system.wait_begin` starts each wait list with the event word.

An event word replaces signals: the kernel never runs code of the process in the middle of other code.

Do not use: signal, notification.

### Processor

A processor is one unit of the machine that executes instructions, and runs one thread at a time.

A machine has several processors. The kernel keeps one processor record and one run queue for each, and its locks are made so that the processors work in parallel. The first machine is QEMU with 4 processors in the machine test.

Do not use: core, CPU, hart.

### Processor record

The processor record is the record that the kernel keeps for one processor: its kernel stack, its current thread, its page table, its frame cache, its counts and its observed kinds.

Most fields of a processor record are written only by its own processor, so they need no lock. Other processors read some fields with atomic loads, and set a few flags (`pending`, `preempt`) to ask the processor for work.

The design: `docs/ARCHITECTURE.md`, "The data of the kernel".

Do not use: per-CPU data.

### Switch of threads

A switch of threads is the moment when a processor leaves one thread and takes another one, or the same one again, from a run queue (`schedule`).

A processor leaves a thread when the thread waits, when its turn ends, at a preemption or at a stop. The kernel saves the extended state of the thread that it leaves and restores the extended state of the thread that it takes there, and nowhere else: a kernel entry saves no vector register, because the kernel has no vector code. A kernel event `Switch` records each switch for a process with the right Events.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: context switch, task switch.

### Extended state

The extended state is the registers of a thread that are not general registers and that the processor saves and restores as a block: the x87 registers, the SSE registers and `MXCSR`, and, when the kernel enables them, the AVX and AVX-512 registers.

The kernel saves each state component that it enables, and sets `XCR0` itself: a kernel that keeps the setting of the firmware lets a process read the AVX registers of another thread. It saves the state only at a switch of threads. Thread control reads and writes the extended state of a held thread. It is not the general registers, which the frame of the thread holds.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: FPU state, floating-point state, vector state, XSAVE state.

### State component

A state component is one part of the extended state that one bit of `XCR0` enables and that the processor saves as one unit.

The kernel enables x87 (bit 0) and SSE (bit 1) always, AVX (bit 2) when the processor has it, and the three parts of AVX-512 (bits 5 to 7: the opmask registers, the high halves of zmm0 to zmm15, and zmm16 to zmm31) when the processor has AVX-512 F. It enables no component that it does not save: MPX, PKRU and AMX stay off. Every processor of the machine must have the same components at the same offsets, else it stays stopped.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: XSAVE feature, xfeature.

### Extended state area

The extended state area is the memory where the kernel saves the extended state of one thread: a fixed field of 2688 bytes, aligned on 64 bytes, in the entry of the thread in the thread table of the kernel.

The area is complete while the thread is on no processor; while the thread runs, its state is in the registers. Only the kernel reads and writes it, and no process maps it. It is part of the slot of the thread, which the budget pays with its `threads` amount: 256 slots cost 672 KiB of kernel memory.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: FPU area, XSAVE area, save area.

### Usable instruction set

A usable instruction set is a group of instructions of the processor (SSE4.2, AVX2, AVX-512 F, BMI2, ...) that the processor has and whose registers the kernel saves.

A process reads the sets once with `src/library/support/instruction_sets`, from `CPUID` and `XCR0`, with no kernel operation. A set that the processor has but whose state the kernel does not save is not usable: an instruction of it stops the process with an invalid opcode.

Do not use: CPU feature, ISA extension.

### Start state

The start state is the content of the extended state area of a new thread: the x87 control word `0x037F`, `MXCSR` `0x1F80`, every register zero, and a header that says that only x87 and SSE are in the area.

A new thread receives no state of the thread that had its slot before: the kernel writes the start state at each creation.

Do not use: init state (for this), initial FPU state.

### Stage

A stage is one part of the start of the machine, with a start time and a duration: the firmware, two parts of the boot program, and four parts of the kernel.

The boot record holds the stages; the boot display and the card of the start show them with their measured time.

Do not use: phase.

### Step of the start

A step of the start is one point on the path of the start that the boot display shows (`bootscreen.Step`): ten points from the firmware to the desktop.

The steps are Firmware, Kernel_Module, Boot_Image, Memory_Map, Kernel, Processors, Root, Input, Compositor and Desktop. The process that draws says which step the machine does now. A step has no time; a stage is a part with a measured time.

Do not use: phase, progress.

### Start policy

The start policy is the one process that the root service starts to start the machine: it decides which processes start, in which order, and when the machine is usable.

The root service keeps the mechanism: the checks of trust, the seed, the parts of the system that only it holds, and the start of one start policy with the start grant `Start_Policy`. That grant gives a root ring for `Start`, `Stop` and `Machine_Usable`, and the machine parts page, and nothing else. The default start policy is the module `start_policy`, which reads a start list in its order; principal 0 can choose a chosen start policy from the disk in its place. A start policy that fails gives way to the rescue start policy.

The design: `src/md/features/start_policy.md`.

Do not use: init, init system, service manager, boot script, startup sequence.

### Start list

A start list is a resource of the boot image that the default start policy reads: a header, then start rows of a fixed size, in the order of the start.

The list is data, signed and measured with the system as each module is. The tool writes it from its table, reads it back through the border of the contract `start_list`, and refuses at each build a list that the border refuses or that names no module of the image. It has no graph and no dependency: its order is the order of the start. Each boot image holds two lists: `start_list` and `rescue_list`.

Do not use: unit file, target, runlevel, boot order (for this).

### Start row

A start row is one row of a start list: the name of a module, the parts of the machine that it needs, what an absent part does, the mark `Needed`, and the count of its restarts.

An absent part gives no start with one line, or a start anyway. A row with the mark `Needed` must run, or be left out for an absent part, before the start policy sends `Machine_Usable`. The restarts count for the whole run of the machine, not for a period of time. The border of the contract refuses a word of a row that names no member.

Do not use: unit, service entry, job.

### Rescue start policy

The rescue start policy is the module `start_policy` with the list `rescue_list` of the boot image: the start policy that the root service starts when the chosen one fails.

The root service starts it when the chosen start policy is absent or does not start, stops before `Machine_Usable`, or sends none within the hang bound; it first stops each process that the failed policy asked for, and writes one line with the cause. The key R and the boot entry "modus (rescue)" ask for it at one start. One module serves both policies, so the code of the rescue runs at each start.

Do not use: safe mode, recovery mode, single user mode.

### Chosen start policy

A chosen start policy is a module of the store `module_files` that principal 0 chose as the start policy of the next start of the machine.

Principal 0 chooses it with `start_policy_choose(nickname, hash)`: one row of its disk grant table, with the disk grant `Start_Policy` and nothing else. The root service reads the choice before any start policy runs, so only a machine whose machine key opens with no passphrase can choose. It loads the file, checks its hash, measures it into PCR 12, and starts it with the start grant `Start_Policy` only. A failure starts the rescue start policy. Its row gives it no other grant.

Do not use: custom init, boot policy.

### Machine parts page

The machine parts page is one page that the root service writes once, before the start policy starts, and maps read-only in it: which parts of the machine are present.

Each part is a member of the closed enum `Machine_Part`: a screen with its size, the data disk, the disk of the measures, the network device, the sound device, the entropy device and the TPM. A part that the root service did not check is absent, never present by default. The input service, not the page, reads an absent PS/2 controller. A start row names the parts that it needs from the same enum.

Do not use: hardware list, device tree, inventory.

### Card

A card is the frame of one subject in a display: a title in its accent, a caption that names its record, and its content.

The boot display, the monitor and the site draw their facts in cards, so that each subject has one place and one color.

The rules: `docs/DESIGN.md`, "10. Elements".

Do not use: panel, box, widget.

### Tile

A tile is a rectangle that stands for one thing of a set, with its name inside; its width can show a size.

Example: the card of the boot image shows a tile for each file of the image.

The rules: `docs/DESIGN.md`, "12. The card of the boot image".

Do not use: chip, badge.

### Size strip

A size strip is a bar of one row in which each file of a set is a part as wide as its share of the bytes, with a least width.

The parts fill the bar exactly and carry no name. The card of the boot image starts with one, so the eye sees at once which files are large.

The rules: `docs/DESIGN.md`, "12. The card of the boot image".

Do not use: treemap, histogram, size bar.

### Accent

An accent is the color of the concept that a card is about.

One concept keeps one accent on every display, so a reader finds the same subject by its color.

The rules: `docs/DESIGN.md`, "4. Color".

Do not use: theme color.

### Boot record

The boot record is the record that the kernel keeps of how the machine started (`op.Boot_Report`): the stages, the memory ranges, the firmware, the framebuffer, the sizes of the kernel and of the boot image, and the trust record of the boot program.

A process with the machine handle and the right Inspect reads it. The boot display and the monitor show it.

Do not use: boot log, dmesg.

### Guard page

A guard page is a page of addresses with no memory, next to a stack: a use of it is a page fault, not a write on other memory.

The kernel puts a guard page before and after each kernel stack and each interrupt stack. The loader leaves one page with no memory between two modules. A stack that overflows into a guard page stops at once, at the instruction that overflowed.

Do not use: red zone, canary.

### Interrupt stack

An interrupt stack is a stack of one processor that the processor itself loads for one kind of exception, at any privilege, from the task state.

Some exceptions can come when no stack is safe: the kernel stack is full, or the stack pointer is still the one that a process chose. So the gate of each such exception names an interrupt stack, and the processor switches to it also when it already runs in the kernel. Each processor has one for the double fault, the debug exception, the non-maskable interrupt and the machine check, each between guard pages. It is not the kernel stack, where the kernel runs an entry.

The design: `docs/ARCHITECTURE.md`, "The return to a process".

Do not use: IST, exception stack, NMI stack.

### Kernel stack

A kernel stack is the stack of 16 pages of one processor where the kernel runs each entry from a process, each interrupt that it takes and each operation.

Each entry from a process starts at its top, and no entry continues an earlier one. A guard page is before it and after it. The build measures the deepest chain of calls on it and fails when less than 4 pages stay free. It is not an interrupt stack: those hold the frames of the exceptions that can come when no stack is safe.

The design: `src/md/infrastructure/kernel_stack_depth.md`; `docs/TOOLS.md`, "The deepest stack of the kernel".

Do not use: thread stack (for this), system stack.

### Deepest chain

The deepest chain is the chain of calls of the kernel that uses the most bytes of a kernel stack, from a place where the kernel starts on it.

The tool computes it at each build from the frame of each procedure that `llc` writes, the calls of the listing of the linked kernel, and the scan of the stack pointer. Stated rules cover what the listing cannot show, such as the targets of the indirect calls and the bounded recursions. Each build prints the chain, procedure by procedure, in a measure line. It is a bound, not a measure of a run: a chain of the graph can be a chain that no input runs.

The design: `src/md/infrastructure/kernel_stack_depth.md`.

Do not use: stack depth (for the chain), call stack (for this), worst-case stack.

### Cycle break

A cycle break is a stated rule of the measure of the kernel stack: below one procedure, no chain runs a named other procedure again, so a cycle of calls through them has a depth.

The listing of the kernel shows a cycle when a procedure can reach itself through others, and a cycle has no depth. A state of the kernel can cut it: `lock_order_broken` logs, and the log takes a lock, but it starts the report of a fault first, and from then the log takes no lock. The row names the two procedures and its reason in the source of the tool; the measure takes the depth of the first with the second left out, and a cycle with no row stops the build.

The design: `src/md/infrastructure/kernel_stack_depth.md`.

Do not use: cycle exception, recursion bound (for this).

### Scan of the stack pointer

The scan of the stack pointer is the part of the measure of the kernel stack that follows the bytes on the stack through each compiled procedure of the listing, path by path.

The scan counts each `push`, `pop`, and constant `sub` or `add` on `%rsp`. At a call the count can be above the frame from `llc`: the arguments that `llc` pushed before the call are outside the frame, and the measure adds them under the callee. A jump through a register with the count 0 is an indirect tail call, which needs a stated rule that names its targets. Each `ret` and each tail call must find 0, else the build stops. The scan does not replace the frame from `llc`.

The design: `src/md/infrastructure/kernel_stack_depth.md`.

Do not use: stack tracking, stack pointer analysis, push depth.

### Direct map

The direct map is the part of the kernel half of the addresses that shows all physical memory.

The kernel reads and writes any frame through it: a thread record, an event ring, a page table. It is never executable, so no write of data can become code of the kernel.

Do not use: physmap, identity map.

### Run

A run is a set of pages that follow each other in a page table with one protection (`Mapping_Run`).

The report `Inspect` of kind `Mappings` (`op.Mapping_Report`) gives the runs of the kernel half or of the half of the process that asks: one record for each run, not one for each page, so its size follows the mappings and not the memory.

Do not use: extent, VMA.

### Self test

A self test is a boot of the machine in which the kernel does one thing that the processor must refuse, to prove that the processor refuses it.

Six tests are of the page tables: a stack overflow, a write to the code of the kernel and to its view in the direct map, a run of data, and a read and a run of memory of a process from the kernel. The expected fault stops the machine with its report, and the machine test checks that report. The seventh is a register trial that writes an address that is not canonical to `IA32_KERNEL_GS_BASE`: the kernel goes on after the refusal and stops the machine with the code 0. It needs KVM: QEMU with TCG takes that write.

Do not use: negative test, lkdtm.

### Log record

A log record is one entry of the log of the kernel (`op.Log_Record`, 256 bytes): a number, a time, a process (its name, its process slot and its process serial), the own number of the record among the records of its process, a thread, a level, its record form, and then a text with its value runs or one log fact.

A process writes a record with the kernel operation `Log` and a log handle with Write. The kernel sets the number, the time, the process and the thread, so no process writes in the name of another. A reader chooses records by process and by level. A long text continues in the next record. The log service serves the records as a table, `log.records(after)`, to each caller in its log scope. It is not a line of the serial port, which the serial writer prints from the record.

The design: `docs/TOOLS.md`, "The log".

Do not use: log line, message, log channel, facility, category, logger.

### Serial writer

The serial writer is the one processor that writes the serial port at a time: the drain of the log at the tick of any processor or in a long wait for a lock, the flush before the machine stops, or the report of a fault of the kernel.

The operation `Log` writes the records of the log only. At a tick, a processor writes the lines that the serial port does not have yet, for a bounded time. So a `Log` never waits for the lines of other processes, and its time tells it nothing of what they wrote. In a flood the serial port loses lines, and one line gives their count. A processor takes the serial writer with a compare-and-exchange: the tick does not wait for it. It is not a lock of the lock order.

The design: `src/md/features/log_side_channels.md`.

Do not use: serial lock, console driver, printk.

### Value run

A value run is a part of the text of a log record that is one value: a start, a length and its value kind.

A writer states the kind of each part of a line of the log (`system.Size`, `system.Duration`, `system.Module_Name`, a number), and the record keeps the runs beside its text. A reader draws each run in the color of its kind; a reader that ignores the runs reads the same text. A run gives a color, never text: runs that do not fit their text leave the record plain. It is not a run of code, which is a part of a line of the console, with a code kind.

The design: `docs/TOOLS.md`, "The log".

Do not use: span (for this), token, highlight range.

### Log fact

A log fact is a log record that carries the values of one record type of its writer, with no text: the hash of the writer's module, a fact key, and the value bytes.

Its fact type is the record type with its fact template, named by the package and the record (`storage.Bad_Block`). The module file describes both, so a reader writes the sentence (`module.fact_sentence_write`) and filters by field (`facts(t, storage.Bad_Block) |> where(block = 12)`), and a machine test waits for a fact and its fields. A log fact is diagnostics: the kernel log can lose it, and only a wired record output `log` keeps each one. It is not a record output of the work of a module. Example: `system.log_fact(.Warning, Bad_Block{block = 12, ...})`.

The design: `src/md/features/log_facts.md`.

Do not use: log event, structured log, log message.

### Fact template

A fact template is the sentence of a log fact, with the name of each field of its record in braces: `"storage: the block {block} has a wrong check {check}"`.

The source gives it as an attribute of the record type, `@(log_fact = "...")`, which the compiler ignores; the tool reads it and writes it in the fact table of the module file. It refuses a template that leaves a field out, names a field that the record lacks, names a field twice, or holds a format in the braces: the kind of the field in the record description decides how a reader writes the value. A reader with no module file shows the value bytes raw.

The design: `src/md/features/log_facts.md`.

Do not use: format string, pattern, message template.

### Fact key

A fact key is the number of 64 bits that names one fact type inside one module: SipHash-2-4, with a fixed key, of `<package name>::<type name>`.

In Odin it is the typeid of the record type, `typeid_of(T)`, an immediate in the code; the tool computes the same number from the source and checks it in the IR of the module. A log fact carries the module hash and the fact key, and a reader finds its row in the fact table of that module. The tool refuses two fact types of one module with one key or one key tag, and a key of 0. A key is no border: any writer can write any key.

The design: `src/md/features/log_facts.md`.

Do not use: event index, event identifier, message number.

### Module tag

A module tag is the first 4 bytes of the hash of a module file, which the serial line of a log fact writes in place of the whole hash.

The tool finds the module of a line by its tag among the module files of its build, and refuses a build where two files share one tag. A tag names; it does not identify: a reader of the system finds the module of a record by its whole hash. It is not the hash prefix, the 8 bytes that a menu shows. Example: `#1a2b3c4d:fa0adf`, where `1a2b3c4d` is the module tag.

The design: `src/md/features/log_facts.md`, "The serial port".

Do not use: short hash, module head.

### Key tag

A key tag is the first 3 bytes of a fact key, from its high byte, which the serial line of a log fact writes in place of the whole key.

The tool finds the fact type of a line by its tag among the fact types of the module of the line, and refuses a module where two fact types share one tag. Example: `#1a2b3c4d:fa0adf`, where `fa0adf` is the key tag of the key `0xfa0adf38a559f4d1`. In code, `op.log_fact_key_tag` gives it.

The design: `src/md/features/log_facts.md`, "The serial port".

Do not use: key prefix, short key.

### Fact table

The fact table is the flat table of a module file that holds one row for each fact type of the module: its fact key, its record description, its fact template and the package that declares it.

The tool writes it from the record types with the attribute `log_fact` that the calls of `system.log_fact` name, in the packages that the module compiles in, sorted by fact key. A reader of the log finds the module by the hash in a log fact, then the row by the key. The record descriptions stay in the table `Records`, which the exports also use: the fact table adds the template and the key only.

The design: `src/md/features/log_facts.md`.

Do not use: event table, message catalog, log schema.

### Record form

A record form is what the bytes of a log record after the name of its process hold: a text with its value runs (`Text`), or one log fact (`Fact`).

It is one byte of the head of the record, `op.Log_Record_Form`, which the kernel writes from the last argument of `Log`. A reader takes the byte through one border, which refuses a byte that names no form: it then shows the head of the record only. A zero record is a text record. A new form is a new member of the enum, so the record has no version number.

The design: `src/md/features/log_facts.md`, "The record".

Do not use: log format, record variant.

### Own-hash place

The own-hash place is 32 bytes in the writable data of a module where each loader writes the hash of the module file before the first instruction.

A module file cannot hold its own hash, and the kernel does not know which module of a process calls `Log`. So the module file names the place in its table `Own_Hash`, and `system.log_fact` copies those bytes into each log fact. The loader of the support package `system` writes it for each module that it loads, the kernel for the root service. A place of zero names no module. The hash is a claim of the writer, as the fact key is.

The design: `src/md/features/log_facts.md`, "The record".

Do not use: self hash, module identity place.

### Integer unit

An integer unit is what an Integer parameter of a command or of an export, or an Integer field of a record, counts: a value kind, Size or Time, and one unit of that kind, such as pages or milliseconds.

The palette shows the unit after the number of a field, `buffer(count: 4 pages)`, so the principal types the number in the unit that the command reads. An export states the unit in its description, from a type of the contract such as `value_kinds.Size_In_Bytes`, so the check of a replacement refuses another unit. A plain count, such as the number of a thread, has no integer unit.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions". The format: `docs/MODULE_CONTRACT.md`, "The unit of an Integer parameter" and "The unit of an Integer field".

Do not use: dimension, measure (for this).

### Field kind

A field kind is how a reader writes the value of one field of a record description, a member of `value_kinds.Field_Kind`.

The source states it with a type of the contract: `value_kinds.Hexadecimal_32`, a contract enum such as `operation.Log_Level`, `value_kinds.Hash_Head_Field`, `value_kinds.Hundredths`. Each reader takes its byte through one border that refuses a byte that names no kind. A reader writes a hexadecimal Integer after `0x`, a Status by the name of its member, the head of a hash as `1a2b3c4d…`, hundredths as `1.05`, each in the color of its value kind. It is not an integer unit.

The design: `src/md/features/console_value_colors.md`. The format: `docs/MODULE_CONTRACT.md`, "The kind of a field".

Do not use: field format, display hint, field style.

### Contract enum

A contract enum is an enumeration of the contract whose members a field of the kind Status holds, named in the closed list `value_kinds.Contract_Enum`, as `operation.Status`, `errors.Kind` or `module.Load_Stage`.

Each reader compiles the contract in, so it writes the name of a member (`module.contract_enum_member_name`), and the number of a word that names no member. A condition names a member (`level = Warning`). The sentence of a log fact writes the words of a member (`contract_enum_member_words`): the name, or for a stop the words of a reader, `itself`, `done`. An enumeration of a module is no contract enum: the module file holds no names of its members, so its field stays a plain Integer.

The design: `src/md/features/console_value_colors.md`.

Do not use: status type, named enum, enum table.

### Word type

A word type is a distinct integer of a contract package that holds a word of one contract enum as it came, at its own size.

A field of a word type is a Status field of that enum: a reader writes the name of the member, or the number of a word that names none. A writer copies a word of another party into it with no cast to the enum, and a word type of 8 bytes leaves no padding beside fields of 8 bytes. `value_kinds.CONTRACT_ENUM_TYPES` names it. Examples: `operation.Status_Word`, `errors.Kind_Word`, `errors.Unit_Word`. The design: `src/md/features/log_facts.md`, "Field kinds".

Do not use: raw enum, enum word field.

### Text view

A text view is a field of 16 bytes of a log fact that holds a text of any length up to a bound: its length, its first 4 bytes, and the rest of a short text or the offset of a long one.

A text of at most 12 bytes is whole in its view; a longer one is in the out-of-line area of its fact, after the fixed record, which the records after the first carry. A writer gives a string, and the write copies its bytes: no address crosses the log. A condition compares the length and the prefix before any out-of-line byte. It is the German string of Umbra and CedarDB. Example: `path: value_kinds.Text_View`. The design: `src/md/features/log_facts.md`, "Text views".

Do not use: tail text, string field, long text field.

### Log body

A log body is a field of 192 bytes of the field kind `Log_Body`: the bytes of a log record from its value runs to its end, which the form of the same record says how to read.

A text record holds its value runs and its text there; a fact record holds its module hash, its fact key, its part and its values. A record description has no union, so one field holds both forms, and a reader takes it through the border of the form (`output.log_output_text`, `output.log_output_fact`). A reader with no border writes its bytes as hexadecimal digits. Example: the field `body` of `output.Log_Output_Record`. The design: `src/md/features/log_facts.md`, "The record output `log`".

Do not use: payload, log data, union field.

### Cut mark

A cut mark is the end of a text that a place of a fixed size does not hold: the start of the text, cut after a whole character, then "... and N bytes more" (`modus:contract/cut_mark`).

N counts each byte that the place does not hold, so the reader knows what is missing. It is the one form of a cut text in the system: a text is written whole, cut with this mark, or refused; never cut in silence. `modustool check` refuses a source that sets the count of a writer by hand.

The rule: `docs/ARCHITECTURE.md`, "A text is never cut in silence".

Do not use: ellipsis, truncation, "..." (alone).

### Level

A level says how much a log record matters: Info, Debug, Warning or Error.

Info is 0, the default. Debug is for the reader who looks for a fault.

Do not use: severity, priority.

### Own records

The own records of a process are the log records that the kernel wrote for the `Log` operations of that process: the records with its process slot and its process serial.

The kernel sets the slot and the serial of each record, so a process cannot write a record in the name of another one. The two numbers together name one process: a new process in the same slot has another serial, and does not read the records of the process before it. A record that another process wrote about this process, such as the line "root: started log_reader" of the root service, is not one of its own records. A caller of the log service that does not act for the principal receives its own records only.

The design: `src/md/features/log_reader_scope.md`.

Do not use: my log, private log, log of a program (for this).

### Own number

The own number of a log record is its place among the records of its process: 0 for the first record that the process wrote, 1 for the next one (`op.Log_Record.own_number`).

The kernel counts the records of each process and writes the count in each record. A reader of its own records receives the own number as the number of each row, and gives `after` in own numbers. Its count `lost` is a gap in its own numbers, so it learns no number or count of the records of other processes. A reader of the whole log receives the number of the record in the whole log. The own number wraps after 2^32 records.

The design: `src/md/features/log_reader_scope.md`.

Do not use: local sequence, private number, cursor (for this).

### Own log ring

The own log ring of a process is the ring of its last 64 log records that the kernel keeps beside the whole log, and that only its own records fill (`op.OWN_LOG_RECORD_CAPACITY`).

The kernel writes each record of a process in the whole log and in its own log ring. A log storm of another process pushes records out of the whole log, never out of this ring, so a reader of its own records learns nothing of how many records the others wrote. The budget of the process pays the ring. Only the log service reads a ring, with the kernel operation `Log_Read`. It is not a copy that the process maps.

The design: `src/md/features/own_log_ring.md`.

Do not use: per-program buffer, log buffer, log mailbox.

### Log scope

The log scope of a connection to the log service is the set of log records that its caller receives from `log.records(after)` and `log.value_runs(after)`: the whole log, or its own records.

The root service writes it in the grant of the connection, and the log service chooses the records; the reader never maps the memory of the log. A caller that acts for the principal, such as the console, receives the whole log; each other caller receives its own records. A starter reads the records of a child with `log.process_records(process, after)`, where it lends the process handle of the child.

The design: `src/md/features/log_reader_scope.md`.

Do not use: log permission, log view, log access level.

### Lock of the kernel

A lock of the kernel is a word that one processor holds at a time, to change one kind of data of the kernel.

The kernel has no lock for the whole kernel: each lock protects a table or a part of a table, and each kind of lock has its place in the lock order. Interrupts are off in the kernel, so a processor never takes a lock again in an interrupt. The lock count of each kind is in the system report, and a kernel event `Lock_Wait` records each wait. A lock of the kernel is not the lock of a process, which is a word of the process.

The design: `docs/ARCHITECTURE.md`, "Locks of the kernel".

Do not use: spinlock, mutex (for this).

### Lock order

The lock order is the order of the kinds of locks of the kernel: control, process, origin, region, frame, cache, log, wait, run.

A processor takes a lock only if it holds no lock of a later kind. A cycle of waits needs a processor that waits for an earlier kind while it holds a later one, which the order forbids: so no deadlock exists. The test build checks the order at each take and stops the machine with a report if it is broken.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: lock hierarchy, lock ranking.

### Control lock

The control lock is the one lock of the kernel for the paths that cross processes or end objects that several processes name: start, stop, give to another process, revoke.

These paths touch a set of processes with no bound: a revocation follows the origins through any process, and a stop closes handles that stop other processes. One lock makes each of them atomic for the others. They are rare (a process does them when it starts, stops or gives access, not in its work), and the measures show that the hot paths do not take it.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: big kernel lock, giant lock, kernel lock.

### Process lock

The process lock is the lock of one process: its handles, its mappings and its page table.

A kernel operation of a process takes its own process lock, so two processes work in parallel. A processor holds two process locks only under the control lock.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: address space lock, mmap lock.

### Frame lock

The frame lock is the lock of the page frames, the reserved pages, the pages of the budgets and the slots of the memory objects.

Each move of pages between a budget, the reserved pages and the frame table is one section under the frame lock, so the sum of the frames holds whenever it is free. The frame cache of each processor keeps most first uses away from it.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: zone lock, page allocator lock.

### Run queue

A run queue is the threads that are ready and that no processor runs, of one processor: its home threads.

Its run lock protects it and the scheduling state of these threads. A new thread goes to the queue of the processor that created it; a woken thread goes to the queue of its home. A processor with less work takes threads from a queue with more, so the ready threads spread over the processors. The strategy of the machine orders each queue.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct", and `docs/SCHEDULING.md`, "2. What this system takes".

Do not use: runqueue, ready list.

### Strategy

A strategy is the rule that orders the ready threads of each run queue: six procedures of the kernel over fixed fields of the thread and of the run queue.

The machine has one strategy at a time: round robin, fair or EEVDF. The kernel calls a strategy through a `switch` with a direct call in each case, because the strategies are a closed set. A strategy owns no memory: its state is fields of the thread and of the queue. A process with the right Schedule changes the strategy while the system runs (`Strategy_Set`); the principal does it through the process `scheduler`, for example with `strategy("eevdf")`. The limit of a budget is not a strategy: it holds under each one.

The design: `docs/SCHEDULING.md`, "2. What this system takes".

Do not use: scheduler class, policy, scheduling algorithm, governor.

### Turn

A turn is the time that a thread runs on a processor from its pick to the moment when it leaves: it waits, its budget has no time, or its strategy ends the turn.

A turn is not a state of a thread: a wake preemption ends a turn, and the thread stays ready.

Do not use: quantum, timeslice (for this).

### Time slice

The time slice is the longest turn under each strategy: 10 ticks.

At the end of a time slice the processor passes through the balance between the processors. So each processor that has a thread looks at the other queues at least each 10 ms. Under round robin each turn has this length.

The design: `docs/SCHEDULING.md`, "The time slice is the longest turn".

Do not use: quantum.

### Weight

A weight is a number from 1 to 1024 of a thread: its share of a processor against the other threads of its queue, under a strategy with weights.

The weight is set when the thread is created. The weight 0 gives the new-thread weight limit of the creating thread or of its process: 1024, the full weight, unless it was lowered. A write of the thread schedule changes the weight while the thread lives: a process only lowers it, and only the holder of the right **Schedule** on the machine raises it. The processor limit of the budget holds under any weight.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation" and "The schedule of a live thread".

Do not use: priority, nice value, shares.

### Virtual time

The virtual time of a thread is its run time in weighted cycles: a run of c cycles adds c * 1024 / weight.

The fair strategy runs the thread whose virtual time is least; EEVDF runs an eligible thread with the earliest virtual deadline. A thread with half the weight gains virtual time twice as fast, so it runs half as much. Two virtual times are compared by the sign of their difference, so the counter can wrap.

The design: `docs/SCHEDULING.md`, "Integer arithmetic and the overflow argument".

Do not use: vruntime, virtual runtime.

### Queue clock

The queue clock is the virtual time of a run queue that never goes back: the least virtual time of its ready threads, as the kernel last saw it.

A thread that wakes or moves is placed against it. The kernel keeps each queued thread within a bound under the clock, so a thread that did not run for a while does not take the processor for a long time when it comes back.

Do not use: min_vruntime.

### Lag

The lag of a thread, under EEVDF, is the average virtual time of its queue minus its own virtual time: what the thread is owed.

A positive lag makes the thread eligible. The lag is kept across a wait, within a bound of two requests (at least one tick), so a thread that slept is neither punished nor paid for its sleep without limit.

Do not use: debt, credit.

### Eligible

A thread is eligible, under EEVDF, when its lag is zero or more.

Only an eligible thread can be picked, when one exists: a thread that ran more than its share waits until the others caught up.

Do not use: runnable (for this).

### Request

A request is the processor time that a thread asks for at each turn under EEVDF, in microseconds: 1 to 100 000, and 0 is 3000.

The request sets the virtual deadline, not the share: a short request makes the thread run sooner and more often, for shorter turns. Its cost, more switches, is in the time of the thread, which its budget pays. A write of the thread schedule changes it while the thread lives: a process only lowers it, and the holder of the right **Schedule** on the machine also raises it.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation".

Do not use: slice (for this), quantum.

### Thread schedule

A thread schedule is the weight, the request, the weight limit and the new-thread weight limit of one thread: the values that are set for it for the scheduling strategies (`op.Thread_Schedule`).

A process holds its policy of scheduling as these values: it chooses them, and the kernel applies them at each tick. `Thread_Create` gives the first thread schedule, and thread control reads and writes it. A process and a holder of a thread handle only lower the values; only the holder of the machine handle with **Schedule** and **Inspect** raises them and writes the two limits. Example: `{weight = 256, request = 500}` gives a quarter of the full share, in turns of 500 microseconds. It is not the thread placement.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: scheduling parameters, scheduling attributes, priority.

### Process schedule

A process schedule is the new-thread weight limit of one process: the value that bounds each thread that any thread of the process creates (`op.Process_Schedule`).

Only the holder of the machine handle with **Schedule** and **Inspect** reads and writes it, with two commands of thread control. One write bounds all the new threads of a process at one moment, which one write for each thread cannot do: a thread can create a thread between the read of the report and its own write. Example: the share policy writes `{new_thread_weight_limit = 32}` to a process of the process weight 1024. It is not a thread schedule, which holds the values of one thread.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread"; `src/md/features/scheduling_policy.md`.

Do not use: program priority, program limit.

### Weight limit

A weight limit is the most that the weight of one thread can be: a number from 1 to 1024, and 1024, the full weight, for a thread that nobody limited.

It makes a lowered weight last across the creation of threads: without it, a process leaves a lowered weight by a new thread. Only a write through the machine handle with **Schedule** and **Inspect** sets it. A new thread gets the new-thread weight limit of its creator as its weight limit. Example: the machine handle writes `{weight_limit = 256}` for a thread; its weight becomes 256, and its own write of 1024 is refused. It is not a share for a process, and not the new-thread weight limit.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: maximum priority, weight cap, ceiling.

### New-thread weight limit

A new-thread weight limit is the weight limit that one thread, or all the threads of one process, give to each thread that they create: a number from 1 to 1024, and for a thread at most its weight limit.

A thread has one in its thread schedule, a process in its process schedule. A creation takes the smaller of the two, and the new thread gets it as its weight limit and as its own new-thread weight limit. Only the machine handle with **Schedule** and **Inspect** sets it. Example: the share policy writes `{new_thread_weight_limit = 32}` to a process and its one thread; that thread keeps the weight 1024, and each thread that it creates has the weight 32. It is not the weight limit of the thread itself.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread"; `src/md/features/scheduling_policy.md`.

Do not use: child weight, inherited weight, creation weight.

### Process weight

A process weight is a number from 32 to 1024 that the share policy divides between the threads of one process: the share of processor time of that process against the other processes.

The principal sets it for the processes with one name: `scheduler.share("paint", 256)`. A process with no setting has 1024. It is a setting of the process `scheduler`: the kernel knows the weight of each thread only. The least value is 32 because a process has at most 32 threads, so each thread has a weight of 1 or more. It has an effect only while the share policy is on. Example: with the process weight 1024, the 8 threads of a process that compute have the weight 128 each.

The design: `docs/SCHEDULING.md`, "A share for each process".

Do not use: program priority, group weight, program share.

### Share policy

The share policy is the rule of the process `scheduler` that gives each process one process weight, whatever its count of threads: each round, it writes to each thread the process weight divided by the count of the threads of its process that count.

A thread counts when it is ready or ran since the last round. Each process and each of its threads also get a new-thread weight limit, so a thread created between two rounds has a small part. The kernel has no part of the rule. The policy is off until the principal turns it on (`scheduler.policy(1)`). It is not a strategy, which orders the threads of a queue. Example: a process with 8 threads that compute and a process with one have the same weight in all, 1024.

The design: `docs/SCHEDULING.md`, "A share for each process"; `src/md/features/scheduling_policy.md`.

Do not use: group scheduling, fair share scheduler, cgroup.

### Thread placement

A thread placement is the set of the processors that can run one thread, and the limit of that set (`op.Thread_Placement`).

A set has one bit for each processor of the processor report. A thread with no placement can run on every processor. A process and a holder of a thread handle only narrow the set; only the holder of the machine handle with **Schedule** and **Inspect** widens it and writes the limit. New threads get the limit of their creator, so a process stays inside it. The holder uses it to keep two processes off the same processors, against side channels. Example: `{processors = 0b0100}` keeps a thread on the processor 2.

The design: `docs/SCHEDULING.md`, "The placement of a thread".

Do not use: affinity, affinity mask, CPU set, pinning, cpuset.

### Machine number

A machine number is the number that names one thread among all the threads of the machine (`op.Thread_Report.machine_number`).

A thread number names a thread inside its process only. The machine handle with **Schedule** needs a name for any thread: the thread report of `Inspect` gives the machine number of each thread, and thread control takes it for the commands of the thread schedule. Its high bits change for each new thread in the same place of the thread table, so the number of a thread that ended names no later thread, and the kernel gives `Bad_State` for it. It is not a handle: it gives no right.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: thread identifier, TID, global thread number.

### Virtual deadline

The virtual deadline of a thread, under EEVDF, is its virtual time plus its request in weighted cycles.

Among the eligible threads, the one with the earliest virtual deadline runs. A thread with a short request gets an early deadline, and so a short delay.

Do not use: deadline (alone: the deadline of a wait).

### Wake preemption

A wake preemption is the end of the turn of the thread that runs on a processor because a thread that woke must run first, by the rule of the strategy.

When the processor of the woken thread is the waker's own, the waker ends the turn itself. On another processor, the waker sets a flag of that processor and sends it an interrupt. A thread of another process preempts one processor at most once in each millisecond: without this limit, a process with threads that wake each other makes other processes pay for the interrupts. Round robin has no wake preemption.

The design: `docs/SCHEDULING.md`, "Wake preemption, also on another processor".

Do not use: wakeup preemption, preempt-on-wake.

### Spinner

A spinner is a thread of the process `scheduler` that computes with no end, and counts its work.

The process `scheduler` runs spinners with different weights and requests, and compares their counts under each strategy.

Do not use: busy loop, hog, load generator.

### Serial

A serial is a number of a slot of a kernel table (a thread, a process, a memory object) that changes for each new object in the slot.

A slot serves many objects in time. A path that names a slot across a wait for a lock keeps the serial and checks it after the wait: the slot can hold another object then. The kernel events and the reports give the serial of a process with its slot, so a reader does not mix two processes of one slot. The generation of a handle is the same idea for the handles of one process.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: generation (for handles only), epoch, version.

### Wait table

The wait table is the threads that wait on words, in buckets chosen by the physical address of the word, each bucket with its wait lock.

A thread registers each word of its wait in the bucket of the word, after it compared the value. A waker changes the word before it enters the kernel, so either the waker finds the entry, or the thread finds the new value.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: futex hash table.

### Locker

A locker is a process that the process `locks` starts several times, to measure the locks of the kernel.

A locker works only on its own objects, so it waits for another locker only when the kernel makes it wait. The lock counts of the kernel then count what the lockers do.

Do not use: load generator, stress worker.

### Frame cache

The frame cache is the stack of at most 256 free page frames of one processor, in its processor record, with its cache lock.

A page on first use takes its frame from the frame cache of its processor, under the cache lock only. The end of a memory object puts its frames there. The stack takes and gives frames to the frame table by batches of 128, under the frame lock. So most first uses do not take the frame lock that all processors share.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: per-CPU page list, magazine, pcp list.

### Cache lock

The cache lock is the lock of the frame cache of one processor.

Its processor takes it at each take and each put; another processor takes it only to read or empty the stack. It comes after the frame lock in the lock order.

Do not use: per-CPU lock.

### Lock count

A lock count is what the kernel counts for one kind of lock, on all the processors: the times that a processor took it, and the times that it had to wait for it (`Lock_Count` in the system report).

The process `locks` reads the counts, so a measure shows which lock the work waits for.

Do not use: lock statistics, contention counter.

### Thread area

A thread area is the memory that the kernel makes for one thread in the address space of its process: the thread record, the kernel ring of the thread, and one page with no memory.

Each thread needs a place where the kernel and the process share its state with no call: the thread record, which the process reads, and the kernel ring, through which the thread sends its kernel operations. The areas are at fixed addresses from `THREAD_AREA_BASE`, so a thread finds its own area from its number. The last page has no memory: a write past the ring faults. The budget pays for each area with its thread. A page fault in a thread area is never given to a fault handler: the kernel stops the process.

The design: `docs/ARCHITECTURE.md`, "Kernel systems".

### Kernel event

A kernel event is a fact of the kernel that the kernel writes as an event record when a rule of the event table accepts it: one kernel operation with its duration, a switch of threads, a fault of a process, or a wait for a lock of the kernel.

Kernel events let a process see the work of the kernel as it happens, with no code of the process in the kernel. A rule is data, not code, so its cost has a bound; with no rule, an event point costs one branch. The process reads the records in the event rings with no kernel entry. It needs the right Events on the machine, because the records are a precise clock over the work of other processes.

The design: `docs/ARCHITECTURE.md`, "Kernel events".

Do not use: tracepoint, probe, perf event, eBPF program.

### Event point

An event point is a fixed place in the code of the kernel where a kernel event can be recorded.

The kernel has four: each command of a kernel entry, the switch of threads, a fault of a process, and a lock taken after a wait. With no rule of its kind, an event point costs one load of the observed kinds and one branch. An event point never faults, takes no lock, never waits and uses no address of a process.

Do not use: hook, probe, tracepoint, instrumentation point.

### Observed kinds

The observed kinds are a word of the processor record: the set of the kinds of kernel events that have a rule in the event table now.

An event point reads it first. It is 0 when no event table exists. The kernel changes it only under the control lock, and synchronizes the other processors before it frees an old table.

Do not use: trace mask, enabled events.

### Event rule

An event rule is one record of the event table (`op.Event_Rule`, 64 bytes): a kind of kernel event, a process or every process, a detail to match, a least duration, and "one in N".

The kernel applies the rule; it is data, not code. A rule that names a process needs a process handle with Read; a rule for every process needs only the right Events. "One in N" is a count, not a random choice.

Do not use: filter, predicate, eBPF program.

### Event table

The event table is the rules (at most 16) that one process with the right Events gave to the kernel with `Events_Set`, with the memory object of its event rings.

The machine has one event table at most. The process that gave it owns it: the table ends when that process ends, when it gives the memory 0, or when its last machine handle with Events closes or is revoked. So a revocation takes back what the right gave.

Do not use: trace session, perf session, ftrace instance.

### Event ring

An event ring is the part of the memory object of the event table that belongs to one processor: a head that the kernel writes, a word that the process writes, and the event records.

Only the kernel of that processor writes its records, so it takes no lock. The kernel indexes with its own counts and reads only the word `read` of the process: a false word loses records of that process and nothing else. A full ring drops the record and adds 1 to the lost count.

Do not use: trace buffer, perf ring buffer, per-CPU buffer.

### Event record

An event record is one record of an event ring (`op.Event_Record`, 64 bytes): the cycle counter, the kind, the processor, the process and its serial, the thread, a detail and two values.

For an operation the detail is the operation number and the first value its duration in cycles. For a fault the address of a page fault is given only to a rule that names the process.

Do not use: trace record, sample.

### Lost count

The lost count is the count of the records of one event ring that the kernel did not write because the ring was full.

The kernel never waits for a place and never writes over a record that the process did not read: a full ring loses the record, and the count says so.

Do not use: dropped events, overrun count.

### Performance counter

A performance counter is a register of the processor that counts one event of the processor, such as the cycles, the retired instructions or the cache misses.

The kernel programs four of them (the general counters 0 to 3) for a thread that asks, as the thread counters, and counts in user mode only. The plan of each vendor comes from `CPUID` at boot, each processor takes the trial of their registers at its start, and the line of the boot names the plan and the trial. An event record carries the cycle counter only, not a performance counter.

The design: `docs/ARCHITECTURE.md`, "The counters of a thread".

Do not use: PMC, PMU counter.

### Register trial

A register trial is one access of the kernel to a model-specific register that the processor can refuse with a protection fault, after which the kernel goes on and knows of the refusal.

A hypervisor can list a register in `CPUID` and refuse each access to it, and any other protection fault of the kernel stops the machine. So at the start of each processor, the kernel takes each access of the counter plan once as a register trial. A protection fault at that one instruction goes on at a refusal label, which gives false. A refused register is an outcome: the machine then has no thread counters. Only the kernel makes a register trial; no process asks for one.

The design: `docs/ARCHITECTURE.md`, "The counters of a thread".

Do not use: safe MSR access, rdmsr_safe, exception fixup.

### Stolen time

Stolen time is the time in which the host ran no code of a processor of the machine, while the cycle counter of that processor went on.

Under KVM, each processor registers the steal-time record of KVM at its start, and the host writes there the nanoseconds that it took from that processor. The kernel subtracts the stolen time of a run from the processor time that it charges to the thread, to its budgets and to its strategy, never below 0. A real machine has none. It is not the idle time of a processor: a processor that waits for an interrupt has no thread to charge.

The design: `src/md/features/stolen_time.md`.

Do not use: hypervisor overhead, wasted time.

### Time base

The time base is the clock against which the first processor measures the timer of its interrupt controller and the frequency of the cycle counter at the start.

It is the 8254 when the machine has one. With no 8254, it is the frequency of the cycle counter that `CPUID` leaf 0x15 or 0x16 of a processor of Intel states, and the timer is measured against the cycle counter. With neither, the kernel cannot keep time: it writes its line and stops with the code 1. The choice is the kernel part `time_base`. It is not the clock of the date, which the root service reads.

The design: `src/md/features/missing_hardware.md`.

Do not use: clock source, timebase, reference clock.

### Thread counters

The thread counters are the counts of four events of the processor for the code of one thread, in user mode only, since its last start (`op.Thread_Counters`): the instructions retired, the cycles, the cache misses and the branch misses.

A developer measures with them the cost of a data layout, and not only its time. The calling thread starts and reads them with thread control, through the machine handle with the right **Counters**, which the root service gives by a start grant. The kernel keeps the counts of a thread when it leaves a processor, so no count of another thread reaches it. A machine with no counters gives `Unsupported`. Example: `system.thread_counters_start(machine)`, a loop, then `system.thread_counters_read(machine)`.

The design: `docs/ARCHITECTURE.md`, "The counters of a thread".

Do not use: perf counters, hardware counters, PMU sample.

### Service

A service is a process that other processes call through rings, and that has no privilege of its own.

A service is not part of the kernel and is not trusted more than another process: it has the handles that the root service gave it. A caller reaches a service through a connection that the root service makes. A service acts only on the handles that the caller sends with the request, never on its own access in the name of the caller. Examples: the storage service, the network service, the manual, the monitor, the compositor.

The design: `docs/ARCHITECTURE.md`, "The whole system".

Do not use: daemon, server, driver.

### Device service

A device service is a service that owns the queues of one device class: block, network card, display, input.

The kernel contains no device code. It maps the registers and the queues of a device into one device service, and turns each interrupt into an event. The service translates between the protocol of the device and the ring of its class; for virtio this translation is thin.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `docs/PROPERTIES.md`, "7. No drivers in the kernel, and fixed hardware first".

Do not use: driver.

### Input service

The input service is the device service of the keyboard and the mouse.

It reads the virtio input devices and sends key and pointer events to the compositor, which gives them to the window that has the focus.

Do not use: input driver.

### Root service

The root service is the first process: the kernel gives it every handle that exists at boot, and it gives them out.

The root service is the only process that creates access from nothing: every other handle came from it, directly or through a chain. It checks the boot image against the system description, starts the services with only the handles that each needs, and makes the connections between callers and services. A process asks it for a start or a connection through its root ring; the console has `start`, `stop`, `connect`, `grants` and `revoke`. The root service has no privilege in the kernel: its power is the handles that it holds.

The design: `docs/ARCHITECTURE.md`, "U2. Root service".

Do not use: init, PID 1, system manager.

### Context

The context is the one typed record that a process receives when it starts: 20 handles and 24 values of 64 bits (`op.Context`).

The context replaces `argv`, the environment and inherited files. The index of each handle is its role, which the starter fixes; the system fixes the roles of the handles from 14 and of some values (the seed of the process, the mapped ranges). It holds no text. A process with an all-zero context can compute and stop, and reach nothing. Example: a call host receives its call ring at role 0.

The design: `docs/MODULE_CONTRACT.md`, "6. The context", and `docs/PROPERTIES.md`, "19. A command is a function: no text between processes".

Do not use: argv, argc, environment (for this), arguments.

### Context slot

A context slot is one place of the context, a handle or a value, with the role that the starter and its process agree on.

The context slots of a process that the root service starts are one table: the `GRANT_` constants of `src/library/support/system/grants.odin`. The root service writes each handle with `system.grant_put`, which refuses a context slot that holds a handle already, so a process never starts with a handle lost. A context slot is not a slot of a module, which holds the address of an export.

Example: the handle 7 is the call ring of the private store; the text region of a terminal is the handle 4.

The design: `docs/MODULE_CONTRACT.md`, "6. The context", and `src/md/api/root_ring.md`.

Do not use: argument index, environment slot.

### Kernel

The kernel is the code that runs with processor privilege: it isolates the processes, schedules the processors, owns the handle tables and grants access to memory and devices.

The kernel has five systems: the handle table, memory, the scheduler, rings and wait, and the device grant. It has no file system, no network protocol, no device driver, no loader and no names. It is a module, which the boot program checks against the system description and loads. Its interface is a short list of kernel operations, counted in `docs/PROPERTIES.md`.

The kernel is the control plane: it checks a right once and maps memory, and data then moves between processes with no kernel entry.

The design: `docs/ARCHITECTURE.md`, "Kernel systems", and `docs/PROPERTIES.md`, "1. Small kernel with a small, counted interface".

Do not use: core, supervisor.

### Kernel operation

A kernel operation is one request that a process makes to the kernel: a command record in the kernel ring of its thread.

The kernel has a counted list of operations (`op.Operation`), and only a change of `docs/PROPERTIES.md` changes the count. A thread writes several commands in its kernel ring, then enters the kernel once with `syscall`; the kernel runs them in order and writes one completion record for each: a status, and the results or an error record. The entry can also wait until a wake or a time. A kernel operation needs a handle for each object that it acts on.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait", and `docs/PROPERTIES.md`, "1. Small kernel with a small, counted interface".

Do not use: system call, syscall.

### Boot program

The boot program is the UEFI program that checks, measures and loads the system, then starts the kernel.

It holds the kernel module, the boot image and the public key of the principal that signs the system. It verifies the signature of the system description, compares each module and resource with it, asks the firmware to measure the description into the TPM, loads the kernel module, and gives the kernel the memory map, the framebuffer and the trust record in one record. A failed check stops the boot with the file and the two hashes on the screen.

The design: `docs/ARCHITECTURE.md`, "U1. Boot program", and `docs/PROPERTIES.md`, "17. Trusted boot: UEFI program, Secure Boot, TPM".

Do not use: boot loader, bootloader.

### Fixed range

A fixed range is an address and a span of the address space of a process where the system places one mapping that it gives: the settings page, the font outlines, the date page, the disk process page, the fresh bytes page, the files of a module.

Each fixed range is one member of the enumeration `Fixed_Range` of `src/library/contract/fixed_addresses`, one slot of 1 TiB of the band from `BAND_START`. So no two ranges overlap, and the compiler checks that the band holds every member. Each written value is the slot and the bit of the range. The slots of the ranges that left name no member, and the border refuses their bits. A mapping that a process places by its own choice is outside the band, from `OWN_CHOICE_START`. `modustool check` refuses an address of the band written another way.

Do not use: well-known address, fixed mapping.

### Mapped ranges

The mapped ranges are the fixed ranges that the starter of a process mapped for it: a set of bits, bit n for the member n of `Fixed_Range`, in the value 20 of its context.

A process reads nothing at a range whose bit is clear (`fixed_addresses.ranges_mapped`).

Do not use: mapping flags, present mask.
