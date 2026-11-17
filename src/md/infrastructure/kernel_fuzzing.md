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

The machine of the kernel fuzzing has one processor, no network, no disk and no display. Its boot image holds the root service, the program `operation_fuzzing` and the module `operation_sequence_runner`. Two boot volumes hold that image:

- `operation_fuzzing`, with the counted kernel `kernel_edge_counters`;
- `operation_sequences`, with the module `kernel`: the bytes of the release kernel, with its checks of the lock order, of the frame sums and of the placement, which the release build keeps.

QEMU runs the machine with its memory in a file of the host: `memory-backend-file` with `share=on`, below the hole of PCI, so that an offset in the file is a physical address. The tool maps the file. This one file carries the counters of the kernel and the mailbox of the machine, so the fuzzing adds no device to the machine.

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

**`operation_fuzzing`** is the program that runs the sequences. Its role in the root service gives it the machine handle with the right Physical only. No other right of the machine is given. The role is a row of the table of the roles, as the roles of the other test programs. A boot image that does not hold the module grants nothing, and a disk program never gets a role. At its start, the program:

1. creates a contiguous memory object, the mailbox;
2. gets its physical address with `Memory_Physical`;
3. writes the line `operation_fuzzing: mailbox at <physical address>` on the log.

The tool reads the line and maps that range of the memory file.

For each sequence, `operation_fuzzing`:

1. copies the sequence from the mailbox into its own memory, then checks it with `operation_sequence.check`;
2. creates the budget of the sequence from its own budget, with fixed amounts, and reads it with `Budget_Read`;
3. creates the runner program, `operation_sequence_runner`, with that budget, and maps the code of the runner, which it loads one time and shares between the runners. It maps a new data segment and the areas of the sequence;
4. starts the runner with the start handles in its context, and waits for the stop of the runner, which ends the wait of its starter, as in the loop of the root service;
5. reads the budget again, then copies the results and the budget amounts into the mailbox, and adds one to the count of executions.

**The start handles** are the handles that a sequence names by their place in the context:

- the budget of the sequence, with Spend, Read and Give;
- the log, with Write;
- each area of the sequence, with every right of a memory object;
- the machine handle with Inspect and Counters.

The machine handle does not have Stop, Devices, Physical, Schedule or Events. Stop ends the machine with a code that is no fault. Devices and Physical reach a device, which the kernel does not check. Schedule and Events change the whole machine past the end of the sequence. A sequence still names these operations: the kernel then refuses them with `No_Right`, and that refusal is fuzzed.

**`operation_sequence_runner`** is a small module with no import past the system library. Its thread runs the steps in order. For each step, it:

1. converts each argument into a word: a value, a start handle, the handle or the value that an earlier step gave back, or an address in an area;
2. writes the command record in its kernel ring, with the bit `COMMAND_NAMES_ERROR_DETAILS` and a table of error details that it filled with a known pattern;
3. enters the kernel with a deadline of 0;
4. writes into the result area the words of the arguments, the completion record, the count of error details and the records of the table.

The operation word passes as it is, so a word that names no operation reaches the kernel. Before each step, the runner writes the number of the step into the result area, so that a stop or a hang names its step. After the last step, it wakes the word of the end and stops itself with `Program_Stop` of 0. The kernel then frees its objects in a counted command.

The runner holds the handles of a sequence in one array of the results by step: a handle argument names a step and a value of its completion, never a handle number. So a sequence does not depend on the handle numbers of one run. The runner does not know the kinds. The tool knows them from the reference comment of each operation (`-> memory handle`), and the generator chooses a step of the right kind for most handle arguments and a step of another kind for some.

**The areas.** An address argument is an area and an offset, which the runner converts:

- the areas of the sequence, each one with an unmapped page after it;
- the table of the thread entries of the runner (wait on a word, return, read address 0), the only code that a `Thread_Create` of a sequence names;
- a mapping that an earlier step made;
- the fixed forms: 0, the first address of the kernel half, an address that is not canonical.

The ring, the copy of the sequence and the result area are in no area. A sequence then names them only through a plain value that hits them by chance. The run of each new kept input twice finds that case as unstable.

### The sequence format and the grammar

The format is the new contract package `operation_sequence`. The tool writes it, and `operation_fuzzing` and the runner read it. A sequence has a head (the magic, the format, the count of steps, at most `OPERATION_SEQUENCE_STEPS_MOST`, which is 64) and its steps. A step has:

- the operation word;
- its flags: no table of error details, or the same kernel entry as the step before, which tests a batch of records;
- seven arguments, each one an `Argument_Source` with its fields.

`Argument_Source` is an enum, and `check` refuses a word that names no member, at the one border. `check` also refuses a step that names a later step, or a step of the same batch, and an area outside the list.

The grammar is `OPERATIONS` of `forms.odin`. The generator of the tool reads one choice for each decision of the form of each parameter: a handle of the kind and the rights of the form, of another kind, 0, or a value that names nothing; a count of 0, 1, the limit, the limit plus one, or the largest value; a subset of the known flags, then one unknown bit; each choice up to the largest, then the largest plus one; an address at the start, at the last byte, across the end of an area, or in a fixed form. An address that an operation reads as a record (a `Page_Range` table, a register image, a breakpoint image, an extended state area) gets the bytes of that record from the field mutator, by its type. The tool keeps one table of these records, with one row for each address parameter of `OPERATIONS`, and refuses a parameter with no row. A new operation then stops the generator until its records are described. A row can say "plain bytes" until its record type is described.

The generator also plants the steps that some oracles read:

- after a step that gives a handle, a `Handle_State` of that handle;
- after some refused steps, a `Budget_Read` of the budget of the sequence.

These steps are steps like the others: the mutator can remove them, and an oracle checks only the pattern that it finds.

### The oracles

The oracles run in the tool, on the host. They take the results that the mailbox holds and the procedures of the contract that the kernel uses too. A machine stop is read from the exit code of the debug exit port and from the serial port.

**A machine stop or a hang.**

- The kernel stops with `Fault`: a page fault or another exception in the kernel. Its report is on the serial port.
- The kernel stops with `Invariant_Broken`: the lock order, the frame sums, the counts of the page tables, the placement, or the control lock taken twice.
- `operation_fuzzing` or the root service stops: a sequence of the runner reached a program whose handle it did not hold. This is a fault of isolation.
- A stall: the count of executions in the mailbox stays still for `HANG_BOUND`. A step that waits is no hang, because the runner enters with a deadline of 0. So a stall is a command that does not return, or a lost wake of the stop. `operation_fuzzing` writes its own report before that bound: the runner did not stop within `system.TEST_HANG_BOUND_MILLISECONDS`, at the step that the result area names.

The signature of a stop is its reason, the procedure of its address from the stack trace of the report (the debug object of the kernel of the run), and the first line `kernel:` of the report with its numbers removed. The signature of a stall is the operation of the step where it stopped.

**A status or an error record against the form table.** For each step whose operation word names an `Operation`, with the argument words that the runner wrote:

- The status is in the list "**Statuses**" of the reference comment, or it is `Ok`.
- A word that names no operation gives `Bad_Operation`.
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

The first layer that runs sequences prints the executions in one second as a measure. If the measure shows that the waits across the border cost more than the sequence, the next layer gives the counted kernel a ring of counter sets: the tool writes several sequences ahead, and each counted runner counts into the next set. Before a measure, the design keeps one sequence at a time.

**The life of a machine and its restart.** A machine runs at most `OPERATION_MACHINE_SEQUENCES_MOST` sequences, 1024, then the tool stops it and boots a new one. The state that the kernel keeps between two sequences (the generations of the slots, the frame caches) then stays short, and a finding that needs earlier sequences has a short prefix to search. The tool keeps the sequences of the life of each machine, in their order, in `build/fuzzing/operations/`. A stop ends the machine; the tool reads the reason, keeps the life with the finding, and boots a new machine with a new memory file. The fuzzing does not use a snapshot of QEMU: a boot is the one restart, and a stop is rare once the first findings are fixed. If the tool boots a machine and the machine does not reach the line of the mailbox, two times in a row, the run ends with an error of the build, not with a finding.

**The minimization.** For a finding, the tool first runs the last sequence alone on a new machine, then the whole life, then it halves the life while the signature stays. It then minimizes the steps of the last sequence with the passes of the host engine. Each try is a new machine.

**The bounds of a run.** `modustool fuzz operations <executions> [machines]` runs that count of executions. With several machines, each machine has its own memory file, and the machines share the kept inputs. A count of 0 and a machine count of 0 are refused: a forgotten argument never starts a run with no end. The run ends at its count, or at an error of the build. Each finding is kept one time for each signature.

**The corpus** is in `tools/modustool/fuzzing_corpus/operations/`, with the bounds of the host corpus:

- The reach inputs are choice sequences of the generator, which the long runs keep.
- The regression inputs are sequence lists in the contract format (one life, minimized; most of them hold one sequence). A regression input then means the same after a change of the generator.

`modustool check` checks both kinds on the host: the generator reads each reach input with no fault, and `operation_sequence.check` accepts each regression input.

### The confirmation on the kernel that ships

`modustool fuzz replay operations <file>` runs a finding, or a regression input, on a new machine of the volume `operation_sequences`, through the same mailbox and the same oracles. Only the kernel differs, and it is the module `kernel` that the release packages. If the signature is the same, the finding is confirmed. If not, the tool reports it as "seen only on the counted kernel". The callback changes the code and the depth of the stack, so such a finding can still be a fault of the kernel, and it is read to its cause.

After the fix, `modustool fuzz regression operations <file>` writes the sequence list into the regression inputs. The command refuses a list that still breaks an oracle on `operation_sequences`. The test part `operation_sequences` of the machine test boots that volume, runs a fixed seed sequence for each operation, then each regression input, with every oracle, so each later change of the kernel runs them. When the right answer is more than "no stop" (a refusal with a named error record), `modustool fuzz show operations <file>` prints the steps with the forms and the results, and the developer writes a named case in a test program with the expected status.

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
- **A program that holds a handle to itself.** If a sequence gives a child a handle to its own program, the stop of the runner does not end the last handle of the child. Property 14 and row 16 of property 20 say that the budget of a program comes back. The oracle reports such a case as a leak, and the contract of `Handle_Give` and of `Program_Stop` then decides whether the kernel or the oracle is wrong.
- **The documented statuses are a contract.** A status that the kernel gives and the reference does not list is a fault of one of the two. The finding does not say which.
- **The soundness of `argument_value_problem` is the claim under test.** The diagnosis of the kernel calls the same procedure, so an oracle that compares a detail with it checks the diagnosis against the operation, not the procedure against itself. A fault of the procedure shows as an `Ok` that it refuses, or as a refusal that it does not name.
- **The memory file is a border.** The tool reads counts and records that a broken kernel can write. The tool checks the count of the details against `ERROR_DETAILS_MOST` and each number of a step against the count of the steps before it uses them.

## Check against the properties

The design contradicts no property:

- It adds no kernel operation (property 1).
- No program reads the counters. The runner holds only its start handles, and the machine handle among them has no right that reaches a device or the whole machine (properties 2 and 20).
- The counted kernel never reaches a release (properties 11 and 17).
- The counters are a fixed array in the static memory of a test kernel, which no program fills (properties 13 and 14).
- The machine has no added device (property 7).
- The tool and the machine talk through shared memory that each side copies, then checks (property 6).

One cost stays in the system that ships: the root service of the release has the role row of `operation_fuzzing`, as it has the rows of the other test programs. That row grants nothing in a boot image that does not hold the module.

## State

Built: nothing of the machine. The host engine, its corpus format, and the forms and the error details of the kernel are built.

Left, in this order. Each layer adds one capability to a fuzzing that works:

1. **The sequence format and the generator, on the host.** The contract package `operation_sequence` with its check and its host tests of each refusal. The generator from `OPERATIONS`, with the result kinds and the statuses read from the reference comments, and the table of the address parameters. A host fuzz target of `check`. No kernel code.
2. **The machine with the kernel that ships.** `operation_fuzzing`, the runner, the boot image, the volume `operation_sequences`, the memory file and the mailbox, the oracles of the statuses, of the error details and of the budget, the seed sequences, the test part `operation_sequences` and `fuzz replay operations`. No kernel code.
3. **The loop with no counters.** `fuzz operations` with generated sequences on `operation_sequences`: the life of a machine, the restart after a stop, the signatures, the minimization by lives and by steps, the rate printed as a measure. No kernel code.
4. **The counted kernel.** The define, the pass in the build of one module, the callback and the array in assembly, the counted program, the counting flag, the boot line, the refusal of the release, the row of the stack measure, the volume `operation_fuzzing`, and the engine guided by the counters of the kernel. This layer changes kernel code, under the define only, and gets the independent review of kernel code.
5. **The corpus of the operations.** The reach inputs, the regression inputs as sequence lists, `fuzz regression operations` and `fuzz corpus operations`, and their checks in `modustool check`. No kernel code.
6. **The records at the addresses.** The rows of the table of the address parameters with their record types, for the field mutator. No kernel code.
7. **The ring of counter sets**, only if the measure of the third and fourth layers shows that the waits across the border cost more than the sequences. This layer changes kernel code, under the define only.
8. **Two processors and several threads of one sequence.** The lock order and the lost wakes between processors, with sequences that give other edges by the order of the processors. The oracles read a state, then, not an order. This layer changes kernel code, under the define only.

Each fault that a layer finds is a fix of the kernel, with its regression input, and not a layer.
