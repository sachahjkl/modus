# Fuzzing of the kernel operations

## Purpose

The kernel operations are the widest border of the system: each program writes command records, and the kernel reads their arguments and the records at their addresses. The hostile cases of the machine test are the cases that their writers thought of. This file records how the tool fuzzes that border: a test machine runs operation sequences that the tool builds from the forms of the 35 operations, a test kernel tells the tool which kernel edges each sequence reached, and the oracles are the checks of the kernel, the form table and the budgets.

The engine, the mutators, the minimizer and the corpus format are the ones of the host targets ([fuzzing.md](fuzzing.md)). This file records what the machine adds.

## Constraints

- **No new kernel operation and no new grant in the system that ships** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). What the fuzzing needs in the kernel is in a test kernel, under a define that each other build passes as false.
- **No program of the system reads the edge counters** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). Which code of the kernel ran tells what other programs do. Only the tool reads the counters, from outside the machine.
- **A test kernel never ships** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). The release refuses it by its hash, by its signature and by its bytes.
- **A test checks a condition, never a speed** ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). Each oracle is a count or a state. A time only ends a hang. A run is a count of executions, and a count of 0 is refused.
- **A count, an offset or a length from another party is copied, then checked.** The memory that the tool writes is hostile for the programs of the machine, and the memory of the machine is hostile for the tool.
- **The confirmation runs on the kernel that ships.** A finding is real when the kernel module of the release, byte for byte, shows it too.

## The chosen form

### The machine

The machine of the kernel fuzzing has one processor. Its boot image, `boot_operation_sequences.image`, holds each module of the boot image and the two modules that no other image holds: the program `operation_fuzzing` and the module `operation_sequence_runner` (the field `only_in_image` of their rows in the table of the modules). When the boot image holds `operation_fuzzing`, the root service starts it and nothing else, as it starts only `shortage` on the machine of the shortage of frames. The machine keeps the devices of a test machine, which no program of this image drives. Two boot volumes hold that image:

- `operation_fuzzing`, with the counted kernel `kernel_edge_counters`;
- `operation_sequences`, with the module `kernel`: the bytes of the release kernel, with its checks of the lock order, of the frame sums and of the placement, which the release build keeps.

QEMU runs the machine with its memory in a file of the host: `memory-backend-file` with `share=on`, below the hole of PCI, so that an offset in the file is a physical address. The tool reads and writes the file at an offset (`pread` and `pwrite`), and writes the count of a new sequence after the sequence itself. This one file carries the counters of the kernel and the mailbox of the machine, so the fuzzing adds no device to the machine.

One processor makes a sequence give the same edges at each run: no second processor changes the order of two commands, and no lock waits. Two threads on two processors are a later layer (see "State").

### The test kernel

**The counter form: `trace-pc-guard` with a callback in assembly.** The tool builds the module `kernel_edge_counters` from the sources of the kernel with `-define:KERNEL_EDGE_COUNTERS=true`. Each other build of the kernel passes `-define:KERNEL_EDGE_COUNTERS=false`, so the default of the source never decides, as for the other test checks. Between the compile and `llc`, the tool runs `opt -passes=sancov-module` on the one IR file of the kernel with `-sanitizer-coverage-level=3` and `-sanitizer-coverage-trace-pc-guard`. The pass gives each edge a guard word of 4 bytes in the section `__sancov_guards` and a call of `__sanitizer_cov_trace_pc_guard` with the address of the guard.

The callback is in the assembly file `edge_counters.asm`, which only this module links. In order, it:

1. returns when the counting flag of the processor is 0;
2. computes the edge number as the place of the guard in its section, from the symbol `__start___sancov_guards` that `ld.lld` defines;
3. adds one to the byte of that edge in the array of the counters, and stops at 255.

The array is in the same file, in `.bss`, with the size of the count of guards. The tool counts the guards in the instrumented IR, then gives the count to `nasm` as a define: `nasm` runs after `opt`. The pass also adds a constructor that would call `__sanitizer_cov_trace_pc_guard_init`. The kernel runs no constructor, so the tool removes `@llvm.global_ctors` from the IR after the pass, as it already removes the time of the compile.

**The counted program.** The test kernel counts only the kernel code that runs for a counted program, as KCOV of Linux counts the system calls of one task:

- `Program_Create` marks a program as counted when its name is `operation_sequence_runner`, or when its creator is counted. The children that a sequence makes are a part of the sequence. The root service and `operation_fuzzing` are never counted.
- The kernel sets the counting flag of the processor when it starts the records of a thread of a counted program, and when it takes an exception from the user mode of such a thread. It clears the flag before the scheduler and the wait, and before the return to the program.
- Interrupts are off in the kernel, so no interrupt runs while the flag is set. An interrupt from the user mode of a counted thread does not set it.

The flag is a field of the processor record at a fixed offset. The assembly reads it through `gs`, and an assertion of the compiler on the Odin side checks the offset. Before the first processor has its record, the kernel has no `gs`: a global word `edge_counters_ready`, which the start sets after the record, is the first test of the callback.

**Where the tool reads them.** At its start the test kernel checks that the array is in one run of physical pages. It then writes one boot line on the serial port: `kernel: TEST BUILD: edge counters at <physical address>, <count> edges`. If the run is not whole, the kernel stops with `Start_Failed`. The tool reads the line, maps that range of the memory file, reads the counters after each sequence, and writes zeros there before the next one. The table of the edges (the address of each call, from the listing of the linked kernel) gives the procedure of an edge for the report.

**The stack.** The callback adds a call at each edge. The measure of the deepest stack runs on this kernel too ([kernel_stack_depth.md](kernel_stack_depth.md)). The callback gets its row in the table of the assembly frames: no frame, no push.

**The release refuses it**, three times:

- The module has its own name and its own build folder. The description of a release volume must name the hash of the module `kernel` of the build ([release_image.md](release_image.md), "What the release command refuses").
- The volume `operation_fuzzing` is signed by the test signing key, which the release refuses.
- The packaging refuses a kernel module that holds the text `TEST BUILD: edge counters`: a check of the bytes, as the check of the license of a pointer theme. A test kernel under another name is still refused.

### The programs in the machine

**`operation_fuzzing`** is the program that runs the sequences. Its row of the table of the roles names no start grant, and the log with Give, which it gives to each runner. The root service starts it itself, with the machine handle with the right Physical only, the boot image and the log: no other right of the machine is given, and a command Start gives it nothing. The release refuses each image that holds the module, and refuses a boot image of the build that holds it, so the row grants nothing in a system that ships. A disk program never gets a role. At its start, the program:

1. creates a contiguous memory object, the mailbox;
2. gets its physical address with `Memory_Physical`;
3. writes the line `operation_fuzzing: mailbox at <physical address>` on the log.

The tool reads the line and maps that range of the memory file.

For each sequence, `operation_fuzzing`:

1. copies the sequence from the mailbox into its own memory, then checks it with `operation_sequence.check`;
2. creates the budget of the sequence from its own budget, with fixed amounts, and reads it with `Budget_Read`;
3. creates the runner program, `operation_sequence_runner`, with that budget, and maps the code of the runner, which it loads one time and shares between the runners. It maps a new data segment and the areas of the sequence;
4. starts the runner with the start handles in its context, and waits for the stop of the runner, which ends the wait of its starter, as in the loop of the root service;
5. reads the budget again, then copies the results and the budget amounts into the mailbox;
6. writes the end line `operation_fuzzing: sequence <number> ended` on the log, with the count of executions after this one, then adds one to that count.

**The end line names the sequence of each line of the kernel.** The log is a queue: the kernel writes it to the serial port at the ticks of the first processor, so a line of the kernel that a sequence caused (`kernel: program root stopped`) can reach the file of the log after the count of that sequence, while the tool waits for the next one. The end line passes through the same queue after each line that the sequence caused, so after each count the tool waits for the end line of that sequence, within `HANG_BOUND`, and reads only the lines up to it. Each line then belongs to the sequence that caused it, and the minimization does not depend on the time of the drain. A stop of QEMU while the tool waits for a count or an end line belongs to that sequence: the end line of the one before came. An end line that does not come is a stall with its own signature. The line costs one record of the log of `operation_fuzzing` for each sequence, from its 1000 records in each second; a faster rate would lose end lines, and gives stalls in place of findings.

**The start handles** are the handles that a sequence names by their place in the context:

- the budget of the sequence, with Spend, Read and Give;
- the log, with Write;
- each area of the sequence, with every right of a memory object;
- no machine handle: the start handle `Machine` is 0.

The service holds the machine with Physical only, and with no Give, so it gives the runner no machine handle. A step that names the machine is refused with `Bad_Handle`, and that refusal is fuzzed. The runner never holds Stop, Devices, Physical, Schedule or Events: Stop ends the machine with a code that is no fault, Devices and Physical reach a device, which the kernel does not check, and Schedule and Events change the whole machine past the end of the sequence. Inspect and Counters for the runner wait for a second machine handle of the service, which is a later decision.

The budget of a sequence pays for the runner, its areas, its result object and the copy of its sequence. The service closes each of its own handles to these objects once the runner holds them, and unmaps its view of the results before it reads the budget again: no handle of the service keeps an amount out of the budget.

**`operation_sequence_runner`** is a small module with no import past the system library. Its thread runs the steps in order. For each step, it:

1. converts each argument into a word: a value, a start handle, the handle or the value that an earlier step gave back, or an address in an area;
2. writes the command record in its kernel ring, with the bit `COMMAND_NAMES_ERROR_DETAILS` and a table of error details that it filled with a known pattern, unless the step has the flag `No_Error_Details` or the operation takes no table (`Log`, `Guest_Run`): the kernel refuses the bit there with `Unsupported`, and such a step would never reach the operation;
3. enters the kernel with a deadline of 0;
4. writes into the result area the words of the arguments, the completion record, the count of error details and the records of the table.

The operation word passes as it is, so a word that names no operation reaches the kernel. Before each kernel entry, the runner writes the number of its first step into the result area, so that a stop or a hang names its step. After the last step, it stops itself with the stop code `RUNNER_END_CODE`, and the stop of the runner ends the wait of the service. The kernel then frees its objects in a counted command. The objects of the runner are at fixed addresses of its own choice, after `OWN_CHOICE_START`, mapped by the service with no handle in the runner.

The runner holds the handles of a sequence in one array of the results by step: a handle argument names a step and a value of its completion, never a handle number. So a sequence does not depend on the handle numbers of one run. The runner does not know the kinds. The tool knows them from the reference comment of each operation (`-> memory handle`), and the generator chooses a step of the right kind for most handle arguments and a step of another kind for some.

**The areas.** An address argument is an area and an offset, which the runner converts:

- the areas of the sequence, each one with an unmapped page after it;
- the table of the thread entries of the runner (wait on a word, return, read address 0), the only code that a `Thread_Create` of a sequence names;
- a mapping that an earlier step made;
- the fixed forms: 0, the first address of the kernel half, an address that is not canonical.

The ring, the copy of the sequence and the result area are in no area. A sequence then names them only through a plain value that hits them by chance. The run of each new kept input twice finds that case as unstable.

### The sequence format and the grammar

The format is the contract package `operation_sequence`. The tool writes it, and `operation_fuzzing` and the runner read it. In this file, a step is a sequence step (`docs/glossary/project.md`). A sequence has a header (the magic, the format, the count of steps, at most `STEPS_MOST`, which is 64, and the count of sequence areas, at most 8), then a record for each area, then the steps, then the content of the areas. An area has 1 to 16 pages and the bytes of its start, at most 4096 for all the areas together. A step has:

- the operation word, as it passes to the kernel;
- its flags: no table of error details, or the same kernel entry as the step before, which tests several records of one entry;
- seven arguments, each one an `Argument_Source` and three words whose meaning the source gives.

The sources are a plain value, a start handle (the budget, the log, the machine, the memory object of an area), an address in an area with an offset, a thread entry of the runner, and the result of an earlier step with the place of its value in the completion and an offset. The offset of a result makes a mapping that an earlier step gave an address of the sequence, as an area is. The fixed addresses (0, the kernel half, an address that is not canonical) are plain values.

`check` reads the bytes into a `Sequence` of the caller and is the one border of the words: it refuses an argument source, a thread entry or a flag that names no member, with its problem, its step and its argument. It also refuses a count past its bound, a size that is not the records and the contents exactly, a word that its source does not use and that is not 0, an area that the sequence does not have, an offset past its area and the page with no access after it, a result of the same step, of a later step or of a step of the same kernel entry, and the operation word with the bit `COMMAND_NAMES_ERROR_DETAILS`, because the flag says that fact. A refused sequence leaves the `Sequence` zero. `write` refuses only a count that does not fit its record, so a test writes a sequence that `check` must refuse.

The operation word is not checked: a word that names no operation reaches the kernel, which must refuse it with `Bad_Operation`. With a table of error details, the runner writes the place of the table into the seventh value, so the seventh argument of the step does not pass: `Log` is fuzzed on its seventh parameter only with the flag "no table of error details".

The grammar is `OPERATIONS` of `forms.odin`, and the kind of the first result of each operation, which the tool reads from the reference comment (`-> memory handle`; `-> address` for the mapping of `Memory_Map`) with the reader of the site. The reference is in the binary of the tool (`#load`), so a fuzz child reads no file. The generator of the tool reads one choice for each decision of the form of each parameter: a handle of the kind and the rights of the form, of another kind, 0, or a value that names nothing; a count of 0, 1, the limit, the limit plus one, or the largest value; a subset of the known flags, then one unknown bit; each choice up to the largest, then the largest plus one; an address at the start, at the last byte, across the end of an area, or in a fixed form. An address that an operation reads as a record gets a record of its type ("The records at the addresses"). The tool keeps one table of these records, with one row for each address parameter of `OPERATIONS`, and refuses a parameter with no row. A new operation then stops the generator until its records are described. A row can say "plain bytes" until its record type is described.

The generator also plants the steps that some oracles read:

- after a step that gives a handle, a `Handle_State` of that handle;
- before and after a step with a value that its form refuses, a `Budget_Read` of the budget of the sequence. The generator knows that it chose such a value; a step that the kernel refuses for another reason gets none.

These steps are steps like the others: the mutator can remove them, and an oracle checks only the pattern that it finds. A choice decides each planted step, and the zero choice plants it.

The zero choices give the simplest sequence: one area of one page, and no step. Each sequence that the generator builds is one that `check` accepts and reads back whole; a host test and the fuzz target `operation_sequence_generated` check this. A row of the table of the address parameters also says whether the address is code: for the entry of `Thread_Create`, the zero choice names a thread entry of the runner.

### The records at the addresses

Plain bytes where an operation reads a structured record stop most sequences at the first check of that record, so the code after it never runs. The generator therefore writes a record of the right type at such an address, in the content of the area that the address names. The row of the address parameter names what the address reads:

- **Plain bytes**: the bytes that the choices gave the area.
- **A table of `Page_Range`** (the ranges of `Memory_Commit`): as many ranges as the count of the next argument, which the check of the table requires to be a count.
- **The record of the command of `Thread_Control`**: a register image for `Write_Registers`, a breakpoint image for `Write_Breakpoints`, the legacy part and the header of an extended state area for `Write_Extended_State`, and plain bytes for each other command. The type depends on the command, so the row names the command argument and not one type.

The other addresses that read a record stay plain bytes until their writers come: the event rules of `Events_Set`, the guest registers of `Guest_Run`, the schedules and the placements of `Thread_Control`, and the address ranges of `Memory_Protect`. An address range names a mapping, and the addresses of the mappings and of the areas are a choice of the runner at run time, which the bytes of a sequence do not hold.

**The writers run after the arguments of the step.** A record depends on other arguments: the count of a table, the command, the pages of the memory object. The writer reads them as the generator chose them, and writes only where it can: a plain count from 1 to `RANGE_TABLE_CAPACITY`, a plain command that names a member, and an address in an area. An address in no area, or in the page with no access after its area, gets no record. The pages of the object are the pages of its area, or the plain count of the `Memory_Create` that gave the handle, or `AREA_PAGES_MOST` when the sequence does not say them.

**The mix of each record.** The writer first chooses the form of the whole record. Of 16 records:

- 12 are valid: each field holds a value that its contract takes, from the contract types and constants (the selectors and the allowed flags of a thread, an address below `USER_END`, a member of `Thread_Breakpoint_Kind` with a length that the kind takes and an aligned address, the reset values of the control words with some exception flags of MXCSR, the components x87 and SSE, increasing ranges with no overlap inside the object).
- 3 hold one edge value in one field: 0, 1, a bound or one past a bound (`USER_END − 1` and `USER_END`, the last page of the object and the page after it, the largest kind and one past it, the length 8 and 9, the first address of the kernel half as a stack).
- 1 holds a word that names nothing in one field: the largest word, a kind of the largest `u32`, bit 63 of the components, which XCR0 reserves, a stack address that is not canonical.

The zero choice gives a valid record. One broken field in a record that is valid besides makes the refusal name that field, as a fault of a real program does; a record whose fields each break with a small chance is valid too rarely for 5 checked fields. A table of more ranges than its object has pages cannot be valid: its last ranges go past the object, and the writer counts it as an edge.

**The commands of `Thread_Control`.** The choice of the command alone names each of the three write commands about once in 57 steps of `Thread_Control`. So half of these steps name one of the three, with the start of an area as the address and the bytes of the area as the size; the zero choice keeps the arguments of their forms.

**The room.** The content of the areas holds at most `CONTENT_BYTES_MOST` bytes. A record past the content of its area grows that content with zero bytes, and the content of each later area moves after it. A record stops at the end of its area and at the end of the room, so it can be cut: a cut record reaches the check of its length or the page with no access, as an edge does. The room is for all the areas together, so a record can start past what its area can still hold; it then gets no byte, and the content does not change. The extended state area is written up to its header, 576 bytes: the rest of the area of the processor is in the zero pages of the area, and a component with zero bytes is valid. A later record of the sequence can write over an earlier one, or over the name of a `Program_Create`; the generator stays a function of its choices.

**The oracles do not change.** A refused record must get a status of its reference and an error record that the forms allow; a refusal changes nothing in the budget. The tool does not predict the refusal of a record: the answer of the kernel to it is the subject of the test.

### The oracles

The oracles run in the tool, on the host. They take the results that the mailbox holds and the procedures of the contract that the kernel uses too. A machine stop is read from the exit code of the debug exit port and from the serial port.

**A machine stop or a hang.**

- The kernel stops with `Fault`: a page fault or another exception in the kernel. Its report is on the serial port.
- The kernel stops with `Invariant_Broken`: the lock order, the frame sums, the counts of the page tables, the placement, or the control lock taken twice.
- `operation_fuzzing` or the root service stops: a sequence of the runner reached a program whose handle it did not hold. This is a fault of isolation.
- A stall: the count of executions in the mailbox stays still for `HANG_BOUND`. A step that waits is no hang, because the runner enters with a deadline of 0. So a stall is a command that does not return, or a lost wake of the stop. `operation_fuzzing` writes its own report before that bound: the runner did not stop within `system.TEST_HANG_BOUND_MILLISECONDS`, at the step that the result area names.

**The signature of a fault of the kernel.** Two runs of one fault give one signature, so each signature is kept one time. A signature holds no number that changes from one run to the next: an address, a count, a slot, a hash. Each kind starts with its own word:

- **A stop**: `stop <reason>: <procedure>: <report>`. The reason is the stop code of the kernel, from the exit status of QEMU (the code twice, plus one); a status that names no reason of the kernel gives its status in place of the reason. The report is the last line of the log that starts with `kernel: `, but the line that says that the line above is cut. The procedure is the one that holds the address after ` at ` in the report, from the debug object of the kernel of the volume, at the address less `KERNEL_BASE`. In the report, each word that holds a decimal digit becomes `#`, and so does each word of 16 hexadecimal digits: the kernel writes a value in hexadecimal as 16 digits with no prefix, and such a value can hold letters only (`ffffffffffffffff`).
- **A stall**: `hang: <operation>`, the operation of the step that the runner started, from the result area. The stall of the tool and the report of `operation_fuzzing` give one signature. A count with no end line within `HANG_BOUND` gives `hang: the end line of the sequence did not come`.
- **A fault of isolation**: `isolation: <line>`, the line of the kernel that says that `operation_fuzzing` or the root service stopped, with its numbers removed as in a report.
- **A broken mailbox**: `mailbox: …`, one signature. The counts of the mailbox are not the counts that the tool wrote: the machine wrote them, so a sequence changed the memory of `operation_fuzzing`.
- **An oracle**: `oracle <oracle>: <operation>`, the first oracle that broke and the operation of its step; for an oracle of the whole sequence, the outcome. The texts of the oracles have the values, and are not a part of it.

**An error of the tool is no fault of the kernel.** A read or a write of the memory file that fails, a sequence larger than its place in the mailbox, or a file of a finding that the tool cannot write ends the run with an error and keeps no finding.

**The protected names.** The kernel writes `kernel: program <name> stopped` for a program that a fault stopped, so a child named `root` or `operation_fuzzing` would give the line of a fault of isolation. After the generator builds a sequence, the tool writes `_` over the first byte of each name of a `Program_Create` that is one of these names in the content of its area. The rule reads the sequence only, so a seed still gives one sequence. A name that a step writes in memory at run time is not seen: it can still give a false fault of isolation, which its minimized life shows.

**A status or an error record against the form table.** For each step whose operation word names an `Operation`, with the argument words that the runner wrote:

- The status is in the list "**Statuses**" of the reference comment, or it is `Ok`. The list ends at the next heading: a line that starts with `**` at its first column. A line of an item that goes on is indented, so a bold word at its start is no heading.
- A word that names no operation, 0 included, gives `Bad_Operation` with the error record `Unknown_Operation`: its value is the kind that the runner sent, with the bit of a table, and its limit is the last operation. The kernel writes no table for such a kind, so a table holds its pattern unchanged.
- For each argument that `argument_is_read` says the operation reads: when `argument_value_problem` names a problem, the status is not `Ok`. The check is sound by its contract, so each value that it refuses, the operation must refuse.
- After a refusal, the details table holds at most `ERROR_DETAILS_MOST` records. Its first record is the error record of the completion. Each detail names an argument that the operation reads. Each argument whose value the form refuses has a detail with that problem and its limit.
- After an `Ok`, the details table holds its pattern unchanged.
- The planted `Handle_State` gives the kind that the reference says the step gives back.
- Between two planted `Budget_Read` steps with only refusals between them, the amounts are the same: a refusal changes nothing.

**The budget after the sequence.** The amounts that `operation_fuzzing` reads after the stop of the runner are its amounts at the start: pages, programs and threads. The log records are not compared, because their amount returns each second. Each program that a sequence made has its last handle in the runner, or in a program that the runner made. So the stop of the runner ends them all. On one processor, the threads of the stopped programs left the processor when `operation_fuzzing` runs again, so the contract of `Program_Stop` says that their memory ended. An amount that is short is a leak of the kernel. The frame sums of the kernel check the whole machine; this oracle names the sequence.

### The loop and the speed

**One execution.** The tool writes a sequence into the mailbox and adds one to the count of sequences. `operation_fuzzing` polls that count in a loop with a kernel entry of deadline 0 between two reads. It then runs the sequence and adds one to the count of executions. The tool waits for that count, reads the results, reads the counters, writes their zeros, and decides what to keep by the classes of the host engine.

**The rate is not measured yet.** One execution costs:

- the program, the budget and the areas of the runner;
- at most 64 kernel entries and their planted steps;
- the stop and the reads;
- two waits across the border of the machine.

The loop with no counters prints the executions in one second as a measure. If the measure shows that the waits across the border cost more than the sequence, the next layer gives the counted kernel a ring of counter sets: the tool writes several sequences ahead, and each counted runner counts into the next set. Before a measure, the design keeps one sequence at a time.

**The life of a machine and its restart.** A machine life is the sequences that one machine runs, from its boot to its end. A machine runs at most `OPERATION_MACHINE_SEQUENCES_MOST` sequences, 1024, then the tool ends it and boots a new one. The state that the kernel keeps between two sequences (the generations of the slots, the frame caches) then stays short, and a finding that needs earlier sequences has a short prefix to search. A fault of the kernel of any kind ends the life: after a stop the machine is gone, and after a stall or a broken oracle its state is not known. Before a life ends with no fault, at its bound or at the end of the run, the tool reads the log for `OPERATION_LOG_DRAIN_BOUND`, 1 second, or until QEMU ends: a line of isolation or a stop that comes after the end line of the last sequence belongs to that sequence. No line is a state that the tool can wait for, so this bound ends the look; the kernel writes the queue of the log at each tick, many times in one second, and a line past the bound is lost with the life. The drain costs 1 second for each life, and for each try of a minimization. The tool keeps the life with the finding and boots a new machine with a new memory file. The fuzzing does not use a snapshot of QEMU: a boot is the one restart, and a fault is rare once the first findings are fixed. If the tool boots a machine and the machine does not reach the line of the mailbox, two times in a row, the run ends with an error of the build, not with a finding.

**The findings.** Each finding is a folder `build/fuzzing/operations/<seed>/<name>/`, where the seed is the seed of the run and the name is the start of the BLAKE3 hash of its signature. A run never mixes its findings with those of another seed; a run of the same seed writes the same findings again over them. The folder holds `finding.txt` (the signature, the text, the seed, the number of the execution, the boots of the minimization and why it ended), `life/` (the life up to the fault, one file for each sequence, in their order), `minimized/` (the minimized life), and `machine_log.txt` (the log of the machine at the fault). The repository never holds them: after its fix, a finding enters the corpus with `fuzz regression operations` (below).

**The minimization.** It runs tries, each on a new machine, and a try holds when its last sequence gives the fault with the same signature. A fault at an earlier sequence does not hold, even with the same signature: the last sequence stays the one of the fault.

1. The last sequence alone, then the whole life. If neither holds, the fault does not come back on a new machine: the tool keeps the life whole and says so.
2. The sequences before the last: remove a range of them, from half of them down to one, while a try holds.
3. The steps of the last sequence, in the same way. A removed step whose result a later step names gives that argument the plain value 0, and the new first step and the step after the removed range lose the flag of the same kernel entry, so a smaller entry passes `check` more often. A candidate that `check` refuses is not run.

At most `OPERATION_MINIMIZE_BOOTS_MOST` boots, 256, serve one finding. A try boots once, or twice when the first boot does not reach the mailbox, and gets only the boots that are left; with none left no try runs, so the result is the smallest life found so far.

**The time of one finding.** A boot ends within `BOOT_HANG_BOUND`, 180 seconds, a sequence within `HANG_BOUND`, 120 seconds, and the drain within 1 second. A hang whose last sequence alone holds costs at most one boot, one hang and one drain for each boot: 256 × 301 seconds, 21.4 hours, for one finding, and 171 hours for a run that ends at its 8 findings, plus its executions. A try that keeps earlier sequences adds their time: each ended within 60 seconds, the bound of `operation_fuzzing`, on the machine of the run. These are bounds, not measures: the boot and the sequences are not measured yet. The minimization depends only on the life and on the answers of the machines: with a machine that gives the same answer to the same life, it gives the same result. A host test runs it on a fake machine that breaks for a sequence that holds a given pair of steps.

**The bounds of a run.** `modustool fuzz operations <executions> [<seed>]` runs that count of executions, from the seed, or from the hash of the sources and the clock. A count of 0, a negative count, a count that is not a number, and no count are refused: a forgotten argument never starts a run with no end, and no default count exists, because each life boots a machine. One machine runs at a time; the host can run other machines beside it. Several machines that share kept inputs wait for the counted kernel, because with no counters the tool keeps no input but the findings. The run ends at its count, at `OPERATION_FINDINGS_MOST` findings, 8, because each one costs up to 256 boots and a kernel with that many faults is fixed first, or at an error of the build or of the tool. Each finding is kept one time for each signature; a later fault with the same signature is counted and not kept. The run prints the executions in one second of the sequences, and of the whole run with the boots and the minimizations, as measures.

### The corpus of the operations

The corpus is in `tools/modustool/fuzzing_corpus/operations/`, with the layout of the corpus of the host targets ([fuzzing.md](fuzzing.md), "Fuzz findings, minimization and the corpus"): `regression/` and `reach/`, one file for each input, named by the BLAKE3 hash of its bytes, within the bounds of a target. The folder names no fuzz target, and the check of the corpus knows it by its name.

- **A regression input** is one minimized life, in the sequence format of the contract, and the answer of each step of its last sequence on the kernel that ships after the fix: the status and, for a refusal, the kind and the argument of the error record and each record of the table of error details, in order. It also keeps the signature of its finding, for its reader. A regression input then means the same after a change of the generator, and the test part checks the refusal itself, not only the oracles. An answer of `Ok` names only its status: its values hold handles and addresses of one run.
- **A reach input** is a choice sequence of the generator. Only the engine guided by the counters chooses one, so the folder stays empty until the counted kernel, and `fuzz corpus operations` comes with it.

**The format of a regression input** is a part of the tool, not a contract: no program reads it. It has a header (the magic `OPERREGR`, the format, the count of sequences, 1 to `OPERATION_REGRESSION_SEQUENCES_MOST`, which is 16, the bytes of the signature, at most 512, and the count of answers, at most the steps of the last sequence), then the signature, then each sequence with its count of bytes, each part padded to 8 bytes, then one record of fixed size for each answer. Its reader is the one border of its words: it refuses a short file, the magic, the format, each count past its bound, a size that is not the parts exactly, a sequence that `check` refuses, a status, a kind of a record or of a detail that names no member, a count of details past `ERROR_DETAILS_MOST`, a detail past the count that is not zero, and an answer `Ok` with a record or a detail. A refused input gives nothing, so no caller runs a part of it.

**`modustool fuzz regression operations <finding>`** takes a finding folder of `build/fuzzing/operations/<seed>/<name>/`: its minimized life and the first line of `finding.txt`, the signature. It runs the life on a new machine of the volume `operation_sequences`, with every oracle and the drain, and refuses a life that still breaks one: the fault is fixed first. It then keeps the answers of the last sequence, writes the input into `regression/`, and prints each answer, which the developer reads before the commit: they are the answers that the fix gives. The command uses the same machine as `fuzz operations`.

**The answers are exact.** A later change of the kernel that changes an answer on purpose, as a better error record, fails the test part. The commit of that change writes the input again with the command and removes the old file: the finding stays in the corpus, with its new answer. Refused: an answer of a regression input that the developer writes by hand, which can name a refusal that the kernel never gave; the oracles alone, which an answer that changes but stays in the forms passes.

**Seed cases and regression inputs.** A regression input holds a minimized finding exactly, as the machine gave it: one form of the fault. The variants of that fault that no finding holds are seed cases of the code, each with the answers that its comment names (`Operation_Seed_Expectation`: the status, the record, one detail that must be there, and an argument that must have no detail). A variant is a case of its own, not a copy of the finding: the finding of the word 0 is one step in one form, and the word 0 in the other form of the table of error details, or the word past the last operation, reaches other code of the dispatch. A case that a regression input holds exactly is never a seed too. Today the seed cases are the word 0 and the word past the last operation, each with and without the table; the commit with the detail of its budget of 0 and the detail of its count; and the decommit with the detail of its count and no detail of its budget. The regression inputs are the three findings of the first long run. A seed case names a few answers by hand, so it is the smaller form for a case that no machine wrote; a regression input holds every answer, so it is the form for a finding.

`modustool check` checks both kinds on the host: the reader accepts each regression input, and the generator builds from each reach input a sequence that `check` accepts. A file of `regression/` that the reader refuses fails the check and the test part: no input stays unrun.

### The confirmation on the kernel that ships

`modustool fuzz replay operations <file>` runs a finding, or a regression input, on a new machine of the volume `operation_sequences`, through the same mailbox and the same oracles. Only the kernel differs, and it is the module `kernel` that the release packages. If the signature is the same, the finding is confirmed. If not, the tool reports it as "seen only on the counted kernel". The callback changes the code and the depth of the stack, so such a finding can still be a fault of the kernel, and it is read to its cause.

After the fix, `modustool fuzz regression operations <finding>` writes the life with its answers into the regression inputs ("The corpus of the operations"). The test part `operation_sequences` of the machine test boots that volume, runs a fixed seed sequence for each operation and the seed cases, then each regression input, each sequence of its life with every oracle, and the answers of its last sequence, so each later change of the kernel runs them. The seeds hold no minimized finding, only its variants ("The corpus of the operations"). A regression input holds the right answer of each step, so a finding needs no named case in a test program for it.

## The refused forms

**For the counters:**

- **Inline 8-bit counters, as on the host.** They count every edge that runs: the tick, the scheduler, the commands of the root service and of `operation_fuzzing`. These edges differ from one run to the next, so the engine keeps inputs that reached nothing new. One array for each processor does not separate them. A filter needs a callback.
- **A callback in Odin.** The pass instruments each procedure of the IR file, so the callback would call itself unless it is in an ignore list. An ignore list names procedures by patterns of their link names, which a rename of the compiler changes. The callback in assembly has no IR.
- **`trace-pc`, a list of the addresses in the order of their run (the KCOV form).** The engine of the tool works on counts of edges by class, and a list of addresses needs a buffer whose size depends on the sequence and a hash on the host. The guards give the edge number directly.
- **The initialization of the guards by the constructor.** The kernel runs no constructor. The place of the guard in its section is a number that is the same at each start, with no write.
- **The counters of the kernel in a memory object of a program.** A program that reads which code of the kernel ran learns what other programs do. A grant that gives it is a grant that the system has, even in a test volume.
- **A plugin of TCG.** It needs QEMU with no KVM, and it sees each program and each interrupt.
- **Snapshot fuzzing (Nyx, kAFL), or a snapshot of QEMU after the boot.** The first needs a patched KVM, an Intel processor with PT and its own QEMU. The second makes the restart faster, and a restart happens only after a stop. Measure the boot first.

**For the path of the sequences into the machine:**

- **A disk.** The block service, its queues and the storage service are on the path of each sequence. Their faults and their commands mix with the faults of the kernel, and each sequence pays several rings and a device.
- **The serial port.** No program reads the serial port: the kernel owns it. The kernel would need a reader of input that a program reaches, which is a new path in the kernel that ships.
- **The remote service.** QUIC, TLS, the network service, the device of the network and a key of a principal are on the path of each sequence: thousands of lines and several programs. A fault of the kernel operations then needs the whole network stack to show.
- **A device `ivshmem` of QEMU.** It gives a shared file too, but it is a second device and a device service, beside the memory file that the counters need already.
- **A scan of the memory file for a tag.** It needs no grant. But the tag is in the boot image, which is in the same memory, and a copy of the tag on a stack gives a second match.
- **The sequences in a resource of the boot image for the test part.** The machine test then has a second path, which the fuzzing does not use. One mailbox serves the long run, the replay and the test part.

**For the records at the addresses:**

- **The type of the record as a `typeid` in the row.** The record of `Thread_Control` depends on its command, so one type per row cannot name it; and a type gives a size and fields, not their contract values.
- **The field mutator of the host engine on the records.** It changes the records of the sequence format after the generator, not the content of an area, and a random byte in a field breaks most records whole.
- **A chance for each field to break.** A register image has 5 checked fields: with a chance for each, too few records are valid, and a refused record names one field less often than a fault of a real program does.
- **An oracle that predicts the refusal of a record.** The refusal depends on the machine (XCR0, the mask of MXCSR, the layout of the area) and on the state of the thread. The oracles of the statuses, of the error details and of the budget already check each refusal against the contract.
- **A record for each address, whatever its form.** An address in no area has no byte in the sequence, and a record there would need a write of the runner at run time.

**For the programs and the oracles:**

- **The sequence run by `operation_fuzzing` itself.** A sequence that unmaps its code or stops its program would end the fuzzing, and its objects would mix with the objects of the service, so no budget would name the leak of one sequence.
- **One runner for many sequences.** It is faster, but the second sequence starts from the handles and the mappings of the first. The budget oracle then names no sequence.
- **The oracles inside the machine.** They would be a second copy of the reading of the reference comments, in a program. The tool already reads them with `core:odin/parser` and imports the contract.
- **A deadline other than 0 in the sequence.** A wait of a step would then end only by time, and a stall would be a wait that the sequence asked for. With 0, a stall is a fault.
- **A test kernel that knows the program by a slot or a serial.** These depend on the order of the start. The name and the creator are facts that the kernel holds.
- **A run bounded by a time.** A loaded host would run fewer sequences with no fault. The count decides, and the rate is printed.

## The subtle points

- **The counted kernel is another kernel.** The callback adds a call to each edge. A fault that comes from the order of the instructions or from the depth of the stack can show only there, and a fault of the kernel that the callback hides can show only on the kernel that ships. The test part runs the kernel that ships for this reason.
- **The teardown is counted only in part.** The runner stops itself, so the teardown runs in a counted command. A part of the free of the frames happens when the last thread leaves its processor, in the scheduler, and that part is not counted. The budget oracle sees its faults, and the counters do not guide toward them.
- **State between sequences.** Two runs of one sequence in one machine can give other edges, because the generations of the slots and the caches of frames moved. The engine runs each new kept input twice and keeps only a stable one. A finding that needs the state of earlier sequences is found by the replay of the life.
- **A program that holds a handle to itself.** If a sequence gives a child a handle to its own program, the stop of the runner does not end the last handle of the child. Property 14 and row 16 of property 20 say that the budget of a program comes back. Such a program that outlives the stop of its runner is a fault of the kernel, and the budget oracle reports it.
- **The documented statuses are a contract.** A status that the kernel gives and the reference does not list is a fault of one of the two. The finding does not say which.
- **The soundness of `argument_value_problem` is the claim under test.** The diagnosis of the kernel calls the same procedure, so an oracle that compares a detail with it checks the diagnosis against the operation, not the procedure against itself. A fault of the procedure shows as an `Ok` that it refuses, or as a refusal that it does not name.
- **A regression input runs after the seeds.** The command keeps the answers on a new machine, and the test part checks them on its machine, after the seeds and the inputs before it. Each sequence has a new runner and a new budget, and an answer names no handle or address, so the sequences before change no answer. An answer that differs only there depends on the state that the kernel keeps between sequences, which is a finding of its own, read to its cause.
- **A valid record is not a reached record.** The code behind the check of a record runs only when the other arguments pass too: a held thread for the registers and the extended state, the program handle with Debug of the debugger for the breakpoints. Such steps are rare in a sequence with no guide; the counted kernel keeps the sequences that reach them.
- **The memory file is a border.** The tool reads counts and records that a broken kernel can write. The tool checks the count of the details against `ERROR_DETAILS_MOST` and each number of a step against the count of the steps before it uses them.

## Check against the properties

The design contradicts no property:

- It adds no kernel operation (property 1).
- No program reads the counters. The runner holds only its start handles, and the machine handle among them has no right that reaches a device or the whole machine (properties 2 and 20).
- The counted kernel never reaches a release (properties 11 and 17).
- The counters are a fixed array in the static memory of a test kernel, which no program fills (properties 13 and 14).
- The machine has no added device (property 7).
- The tool and the machine talk through shared memory that each side copies, then checks (property 6).

One cost stays in the system that ships: the root service of the release has the role row of `operation_fuzzing` and its start, which gives the machine with Physical, as it has the rows of the other test programs. Both act only in a boot image that holds the module, and the release refuses such an image.

## State

Built: the host engine, its corpus format, the forms and the error details of the kernel, and the first layer: the sequence format and the generator, on the host. The contract package `operation_sequence` has its check, its writer and its host tests of each refusal. The generator reads `OPERATIONS` and the kind of each result from the reference comments, and its table of the address parameters has a row for each address parameter. The fuzz targets `operation_sequence` (raw: `check` and the round trip through `write`) and `operation_sequence_generated` (each sequence of the generator passes `check`) run in `modustool check`.

Built after it, the machine with the kernel that ships: `operation_fuzzing` and the runner in the image `boot_operation_sequences.image` only, the start of `operation_fuzzing` by the root service with the machine with Physical only, the volume `operation_sequences`, the memory file and the mailbox (the contract part `mailbox.odin`), the statuses read from the reference comments, the oracles of the outcome, of the budget, of the statuses, of the forms and of the error details, and of the planted steps, the seed sequences, the test part `operation_sequences`, `fuzz replay operations`, and the refusal of an image that holds one of the two modules by the release. The runner holds no machine handle.

Built after it, the loop with no counters: `fuzz operations <executions> [<seed>]` with generated sequences on `operation_sequences`, one machine at a time, the life of a machine and its restart after a fault, the signature of each kind of fault, the minimization by lives and by steps within 256 boots, the findings in `build/fuzzing/operations/<seed>/`, and the rate printed as a measure. `operation_fuzzing` writes the end line of each sequence, and the tool reads the lines of the kernel of a sequence up to its end line, then drains the log after the last sequence of a life. Each word of 16 hexadecimal digits leaves a signature, an error of the tool ends a run and is never a finding, and the generator writes no protected program name. Host tests check the refusals of the arguments, that two runs of one fault give one signature, the procedure from a debug object, the end line and a line of the kernel one sequence late, the whole lines of a log read in parts, and the minimization and the loop on a fake machine: the bound of the boots, a fault at the drain, a try at an earlier sequence or with another signature, an error of the tool, and a kept fault past the free of the temporary memory. The rate is not measured yet: no run has printed it.

The first long run, `fuzz operations 5000`, found 14 faults with 3 signatures. The minimization made each one a sequence of one step. Each is a regression input of the corpus now:

- **`oracle Unknown_Operation`: the kernel.** The dispatch answered `Ok` to the kind 0, while the contract of the errors, the diagnosis of the kernel and the oracle say that 0 names no operation. The kernel now refuses it with `Bad_Operation` and the record `Unknown_Operation`. The case of a full completion queue of the program `errors`, which filled its queue with the kind 0, now reads these refusals.
- **`oracle Details_Argument: Memory_Commit`: the forms.** The table gave the budget of `Memory_Commit` the form `Handle_Or_Zero`, so `argument_is_read` said that a budget of 0 is not read. A commit reads its budget whatever its value, and the kernel rightly gives a detail of a budget of 0. The form is now `Handle`; a decommit still reads no budget.
- **`oracle Status_Not_Listed: Thread_Control`: the reader of the tool.** The reference lists `Bad_State`, but the reader of the list "**Statuses**" stopped at a line of an item that starts with `**Counters**`, and lost `Bad_State` and `Bad_Address`. The list now ends only at a heading at the first column.

Built after them, the corpus of the operations: the folder `fuzzing_corpus/operations/` in the check of the corpus, the format of a regression input with its reader and its writer, the answers of the last sequence kept from a machine and checked by the test part after the seeds, and `fuzz regression operations <finding>`. The three findings of the first run are regression inputs, which the test part reads from the corpus; their variants that no finding holds stay seed cases with their answers. Host tests check each refusal of the reader, the bounds of the writer, the check of the answers and their reading through the borders of their words, the read of a finding folder, the form of the corpus folder, and that the test part reads each file of `regression/`, so no input stays unrun. The reach inputs wait for the counted kernel.

Built after it, the records at the addresses: the rows of the table of the address parameters name the table of `Page_Range` of `Memory_Commit` and the record of the command of `Thread_Control`, whose writers give a register image, a breakpoint image and the legacy part and the header of an extended state area, valid in 12 of 16 records. The check of the table refuses a table of ranges with no count after it and the records of `Thread_Control` on another operation. Host tests check that each record of the writers is what its form says against the procedures of the contract (`thread_registers_refusal`, `thread_breakpoints_refusal`, `extended_state_refusal`, the rules of the ranges), that each record of a generated sequence is in the content of its area and decodes as its type, that each sequence passes `check`, that one seed gives the same bytes and the same records twice, that each type appears whole and valid within 50 000 sequences of a fixed seed, the bounds of the room of a record, and each case where a step gets no record. No kernel code changed. The other records stay plain bytes ("The records at the addresses").

Left, in this order. Each layer adds one capability to a fuzzing that works:

1. **The counted kernel.** The define, the pass in the build of one module, the callback and the array in assembly, the counted program, the counting flag, the boot line, the refusal of the release, the row of the stack measure, the volume `operation_fuzzing`, the engine guided by the counters of the kernel, and the reach inputs of the corpus with `fuzz corpus operations`. This layer changes kernel code, under the define only, and gets the independent review of kernel code.
2. **The ring of counter sets**, only if the measure of the loop and of the counted kernel shows that the waits across the border cost more than the sequences. This layer changes kernel code, under the define only.
3. **Two processors and several threads of one sequence.** The lock order and the lost wakes between processors, with sequences that give other edges by the order of the processors. The oracles read a state, then, not an order. This layer changes kernel code, under the define only.

Each fault that a layer finds is a fix of the kernel, with its regression input, and not a layer.
