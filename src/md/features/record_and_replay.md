# Record and replay of a process

## Purpose

A fault that a machine test shows once, under a loaded host, and never again is the most costly fault of this project. The roadmap has one today: the console line that took its keys and never ran. The log tells what the process wrote; it does not tell what the process read.

This design lets the kernel write each process input of one process into an input history while the process runs. A replay then runs the same module again, alone, with each input from the history, and reaches the same instructions with the same values. The debugger then steps back from a fault, and finds the last write of a value. A machine test that fails keeps the history of the process that failed, and a developer replays that failure on the host as many times as needed.

Property 24 is the rule that makes this possible: no input reaches a process except through a channel that can be recorded ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "24. Every input of a process passes through a channel that can be recorded"). This file holds the audit of the channels, the chosen form of each record, the replay, its uses, and the layers of the work.

The terms are in [`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md): process input, input point, input history, recorded process, point copy, shared writer, replay, divergence, branch count.

## Constraints

- **The kernel sees each input.** A record that only a library of the process writes misses the process that reads shared memory without the library. A read of shared memory twice is the kind of fault that a replay must show, so the record is in the kernel.
- **No new operation** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). The record and the replay are commands of operations that exist.
- **No new authority** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 2). A history holds each byte that a process received: its keys, its documents. So a recording needs the right `Debug` on the process handle, as the debugger does.
- **A process that nobody records pays nothing measurable.** The cycle counter stays free, `cpuid` runs, and the threads run on any processor.
- **Memory supplied by the recorder** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller"). The history is memory of the recorder, and its budget pays the point copies.
- **No silent loss.** A history with a gap is worth nothing: a full history holds the recorded thread, it never drops an input.
- **A recording does not take a process that the recorder does not hold.** A shared writer can wait, with a bound; its placement and its share never change.

## The audit of the process inputs

Each way a value reaches a process today, read from the kernel (`src/modulus`), the library (`src/library/modus/system`, `src/library/modus/random`) and the modules. "Today" is the state of the code; "the record" is the chosen form below.

| Channel | What reaches the process | Can it be recorded today? | The record |
|---|---|---|---|
| The context | 20 handles and 24 values, the seed of the generator among them, written by the starter before the first instruction | Yes: it is memory at a fixed place, before the start | Once, in the head of the history |
| The modules and the resources of the image | Code and data mapped read-only, named by their hash | Yes: they never change | Their hashes, never their bytes |
| The completions of the kernel ring | The answer of each command, written by the kernel during an entry of the thread | Yes: only the own thread writes its kernel ring, and only the kernel writes the completions, during that entry ([kernel_ring_completion_room.md](../api/kernel_ring_completion_room.md)) | Each completion of the entry |
| The return value of an entry | The time in milliseconds, in `rax` | Yes: one value at each entry | With the entry |
| The results of a kernel operation in memory of the caller | A report, a register image, the bytes of `Read_Memory`, the records of `Log_Read`, an error record | Yes: the kernel writes them through one copy procedure, `user_copy`, during the entry | Each range that the copy writes |
| Wakes | The end of a `Word_Wait` | Yes: the wait ends inside an entry, so the wake is the completion and the time of that entry. A wake changes no byte | With the entry |
| The faults that a handler of the process takes | A fault record in the fault ring of the handler thread | Yes: the kernel writes it at the fault of a thread of the process ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The fault ring") | The record and the answer |
| The writes of a debugger | The registers and the extended state of a held thread | Yes: the thread is held, so the write takes effect at its next input point | The written image, at that point |
| The time page | The milliseconds since boot, which the kernel writes at each tick on the first processor | No: the value changes under the reader at any instruction | A point copy |
| The date page, the settings page, the fresh bytes page, the disk process page, the machine parts page, the end page of a wiring | A page that another process writes (`date`, `settings`, the root service), mapped read-only | No: the page changes under the reader at any instruction | A point copy |
| A budget | What a budget can still pay | Yes: no page holds it; `Budget_Read` is a kernel operation | Its completion |
| Memory shared with Write on both sides: a ring, a call region, a surface, a text region, an event in shared memory | Records, counters and bytes that another process writes | No: the peer writes at any instruction, on another processor | The shared writer waits for an input point (below) |
| Memory that a device writes | The data region of the block service, the frame region of the network service | No: the device writes by DMA at any instruction, and no hold of a process stops it | First exception of property 24 |
| Device memory and ports | The registers of a device | No: each read is an act on the device | First exception of property 24 |
| The event word of a thread | The count of the interrupts of a device of the process | No: an interrupt on another processor writes it | First exception: only a process that holds an interrupt has it |
| The changes of the address space by another process | A mapping, an unmap, a protection that the creator or a revocation makes | No: the change takes effect at a shoot-down, at any instruction | A change of the creator waits for the next input point of the recorded thread; a revocation ends the history at once ("Subtle points and hazards") |
| The cycle counter (`rdtsc`, `rdtscp`) | The count of cycles, with no kernel entry (`system.cycles`, under `system.nanoseconds`, in 55 source files) | No: the kernel never sets `CR4.TSD` | A fault at each read while recorded |
| `cpuid` | The features and the identity of the processor | No: it runs in the process with no fault | A fault at each run while recorded (CPUID faulting) |
| The number of the processor (`rdpid`, and `rdtscp` in `rcx`) | The value that the kernel wrote in `TSC_AUX` ([guest.md](guest.md)) | No: it changes when the thread moves | One fixed value while a recorded thread runs |
| `rdrand`, `rdseed` | Random values from the processor | No: no fault exists for them outside a hypervisor | Hidden by the answer of `cpuid`; the code of the system runs them only in the root service |
| A transaction of the processor (`xbegin`) | An abort at a moment that the cache sets | No | Hidden by the answer of `cpuid` |
| `umwait`, `tpause` | An end of the wait at a time of the cycle counter | No | Hidden by the answer of `cpuid` |
| The other instructions that read the machine | `rdpmc`, `rdfsbase`, `rdpkru`, `sgdt` and the four others that UMIP covers | Yes: each one already faults in a process (`CR4.PCE`, `CR4.FSGSBASE` and `CR4.PKE` clear; UMIP set when the processor has it). On a processor with no UMIP, `sgdt` and the four others read places of the kernel with no fault: an input that a record on such a processor cannot catch | Nothing to add |
| `xgetbv` | The state components that the kernel turned on | Yes: one value for the machine, set at boot | In the head of the history; a replay refuses a machine with another value |
| A new page | Zeros (property 13, "Zero is initialization") | Yes | Nothing to add |
| An address that the kernel chooses | The place of a mapping | Yes: it is in the completion | With the completion; the replay maps at the same address |
| The order of the threads of the process | Which thread runs, and where another thread stopped | No: two threads run at once on two processors | One thread at a time; a switch at an input point |
| The timing of the process itself | How long its work took, and the state of the caches | Only through a channel above: a clock, a counter of the processor (`Read_Counters`, a kernel operation) | Through that channel |

### The hard cases, and the choices

**The cycle counter.** Three forms were possible: trap it for every process, read the time through the time page only, or trap it for a recorded process only. The choice is the third. The kernel sets `CR4.TSD` at the switch to a thread of a recorded process, and clears it at the switch to any other thread: one flag of the thread, tested at the switch, as the debug registers are. A read is then a `General_Protection` fault, which the kernel takes itself and never gives to a handler: it reads the bytes at the instruction (`0F 31` or `0F 01 F9`), reads the counter, writes `edx:eax` (and `ecx` for `rdtscp`), moves the instruction address past it, and writes the value into the history. In a replay the same fault takes the value from the history. With the time page only, every process loses its time under 1 ms, which `system.nanoseconds` gives to 55 source files today. So the kernel traps the cycle counter for a recorded process only. Whether a precise clock becomes a grant for every process, with the same trap for each process that does not hold it, is a decision of property 20, line 17, not of this property. It is decided later, with a measure of the cost of the trap: the time of one trapped read, and the count of reads of the processes of the system in a run.

**`cpuid`, and through it `rdrand` and `rdseed`.** The processor faults on `rdrand` and `rdseed` only under a hypervisor that asks for it. So no form catches them in a process. What can be done: the CPUID faulting of the processor (`MSR_PLATFORM_INFO` bit 31, `MSR_MISC_FEATURES_ENABLES` bit 0) makes `cpuid` fault in user mode. The kernel turns it on at the switch to a recorded thread, answers each `cpuid` itself, and writes the answer in the history. The answer clears the bits of `rdrand`, `rdseed`, `rdpid`, the transactions, `waitpkg` and each feature of the processor that a replay on another machine can lack. Code that asks `cpuid` first then never runs these instructions while it is recorded. Code that does not ask runs them anyway: that is the fourth exception of property 24, and the replay finds it as a divergence. The code of the system runs `rdrand` and `rdseed` only in `random.entropy_gather`, in the seed of the root service; a check of the tool refuses them in any other source of `src/`, by the intrinsics that the LLVM IR names. KVM gives CPUID faulting to its guests on Intel and on AMD, because each `cpuid` of a guest leaves to KVM; the kernel tries the registers at the start of each processor, as it tries the counters ([processor_counters.md](processor_counters.md)), and a machine that refuses them cannot record.

**Memory that a peer writes.** This is the hard case, and the answer depends on the rights of the mapping:

- **The recorded process maps the page without Write.** The kernel maps a point copy in its place: one page of the budget of the recorder. At each input point of the recorded process, the kernel compares the shared page with the point copy, writes each changed range into the history, and copies it. The writer is never held. The pages of this kind are the date page, the settings page, the fresh bytes page, the disk process page, the machine parts page, the end page of a wiring, and the time page, which the kernel writes. Each is one page with a change counter, so a torn copy is a state that the reader already handles, and the history holds it as it was.
- **Both map the page with Write.** A point copy cannot serve: with it, the writes of the recorded process reach the peer only at the next input point, and the peer reads a stale wait flag of a ring and never wakes the recorded process. So the peer writes the real page, and the kernel keeps it away from the moments when the recorded process can read: a shared writer runs only while each thread of the recorded process is at an input point (inside a kernel entry, or held at a fault). A shared writer that the scheduler picks while a recorded thread is between two points does not run: it waits for that point. At the start of a kernel entry of a recorded thread, the kernel keeps a copy of each shared page that a writer can change; before the entry returns, it waits until no shared writer is on a processor, then writes each changed range into the history. A thread that waits in `Word_Wait` is at an input point for the whole wait, so a peer that serves it runs freely.
- **The bound.** A recorded thread that stays between two points for one whole stint while a shared writer waits ends the history, with one line of the log, and the writer runs. So a writer waits at most one stint, and a recording never holds another process for ever. The second layer removes the bound with the branch count.
- **Pinned writers, refused.** Writers on the processor of the recorded process also stay apart from it, but that changes the placement of processes that the recorder holds no handle to.

**The order of the threads.** One thread of a recorded process runs at a time: the kernel narrows the placement of the process to one processor, which the right `Debug` allows (it is the full power over that process). In the first layer a thread leaves the processor to a sibling only at an input point; a thread that runs one stint with no entry while a sibling is ready ends the history, as above. In the second layer an interrupt is an input point too.

## The chosen form

### The input points

An input point is a place in the run of a thread where an input can enter: a kernel entry, a fault, or, in the second layer, an interrupt. A recorded process reads nothing new between two points. Each point has a number in the history; the replay reaches the same points in the same order.

A kernel entry and a fault are at an instruction that the code of the thread fixes, so their place needs no count. An interrupt comes at any instruction. rr places it by a count of retired conditional branches and the instruction address: the count tells how far the thread went, the address and the registers tell the instruction inside a loop with no branch. The kernel counts the branches of the user code of the recorded thread with a counter of the processor (event `0xC4` mask `0x01` on Intel, `0xD1` on AMD Zen), in the counter plan that the thread counters already read ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The counters of a thread"). In a replay the kernel programs the counter to stop the thread a few branches before the count, then runs it to the instruction with a breakpoint. This is the second layer.

### What an input history holds

The history is a ring of fixed entries of 64 bytes in a memory object of the recorder, as the event ring of the kernel events is: the kernel writes through the direct map, keeps its own count, and reads only the count of the reader ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Kernel events"). An entry with a range of bytes takes the entries that follow its head. The format is a contract package, `input_history`, with a border that refuses an entry of an unknown kind.

- **The head**: the version, the module hash, the context, the answers of `cpuid` that the record gave, `xgetbv`, the frequency of the cycle counter, the hashes of the mapped resources, and the first content of each point copy.
- **An entry**: the commands of the kernel ring (they are outputs, but the replay compares them, and the debugger shows what the process asked), its completions, its time, and each range that `user_copy` wrote.
- **A fault**: the fault record and the answer.
- **A changed range**: of a point copy or of a page of a shared writer, at its point.
- **A trapped instruction**: the value of the cycle counter, or the leaf and the answer of `cpuid`.
- **A switch**: the thread that leaves and the thread that comes, at a point.
- **A write of a debugger**: the image, at the point where the thread resumes.
- **A change of the address space by another process**: the mapping, the unmap or the protection, at a point.
- **The check of each point**: the instruction address and the stack pointer of the thread, and in the second layer its branch count.
- **The end**: the stop of the process, the end that the recorder asked, or the bound of the first layer, with its reason.

A full ring holds the recorded thread at its next point until the recorder reads, as a stop of a debugger holds it. No entry is ever dropped.

### Who records, and the commands

The recorder holds the process handle with `Debug`: the debugger service, by the rule of the root service ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "Who can debug which process"), or the creator of the process. Two commands of `Thread_Control` through that handle, as the commands of the debugger are, so the count of operations does not change:

- `Record_Start`: a contiguous memory object with Write for the history. A process with no instruction run yet is recorded from its start; the first layer records only such a process.
- `Record_End`: the kernel writes the end entry and leaves the record mode. The end of the handle, of the recorder or of the process ends the record the same way.

The kernel refuses `Record_Start` for a process of the exceptions (a device, memory declared to a device, a guest), on a machine with no CPUID faulting, and for a process that another recorder records. Each refusal is an error record with its unit.

### The replay

A replay runs one process alone. The replayer, the debugger service, creates a process from the same module hash, writes the context of the head, and gives the history with a third command, `Replay_Start`, before the first instruction. The kernel then runs that process in replay mode:

- **A kernel entry.** The kernel compares the commands that the thread wrote with the commands of the history: a difference is a divergence. A command that builds the address space or the threads (`Memory_Create`, `Memory_Map`, `Memory_Commit`, `Memory_Protect`, `Memory_Unmap`, `Thread_Create`, `Thread_Stop`, `Process_Stop`) runs for real, paid by the budget of the replayer, at the address of the history, and its status must be the status of the history. Each other command runs not at all: the kernel writes its completion, its time and its bytes from the history.
- **The handles.** A handle of the history names a memory object or a thread of the replay, or no object at all. A replay holds no connection, no ring to another process, and no right of the machine, so it sends nothing to any process: a write to a ring reaches nobody.
- **The other channels.** The point copies and the shared pages are memory of the replay; the kernel writes each changed range of the history at its point. The cycle counter and `cpuid` fault, and take their values from the history. The threads run one at a time, and switch at the points of the history.
- **The divergence.** At each point the kernel compares the instruction address and the stack pointer with the history. A difference stops the replay with the number of the point and the two values. The usual causes: an instruction of the fourth exception, a fault of the kernel, or a history of another build.
- **Another machine.** The head names the answers of `cpuid` and `xgetbv`. A machine that lacks a feature that the history let the process use refuses the replay with the feature.

A replay is a process for the debugger as any other: breakpoints, watches, steps, the stack and the variables work as in a live run.

### The debugger: step back, and a watch back

The replay is deterministic, so a past state is a state that a replay reaches again. The debugger service keeps checkpoints: at a point, a copy of each memory object of the replay and of each thread (registers and extended state), with the number of the point. In replay mode the kernel gives the replayer a handle with Read to each memory object that the replay creates, so a checkpoint is a copy, not a fork (property 16). A checkpoint becomes a new replay process.

- **A step back** goes to the checkpoint before the target, then forward to the target: to its point, then by single steps that the debugger counts (first layer), or by the branch count (second layer).
- **A watch back** answers "who wrote these bytes last": the debugger runs forward from the checkpoint before now with a data breakpoint, keeps the place of each hit, and stops at the last one before now. With no hit, it tries the checkpoint before.
- **The rate of the checkpoints** is a decision point: a measure of the cost of a copy and of a replay forward decides it.

The exports and the console names are in "The frequent tasks".

### The machine tests

A row of the start list of a test machine can mark its process "recorded". The root service of the test machine records it from its start, with a history in memory that the test start policy pays. The kernel fuzzing already reads memory of the machine through the memory file of QEMU ([kernel_fuzzing.md](../infrastructure/kernel_fuzzing.md)); the tool copies each history the same way, at the end of the part and at a failure, into the outputs of the part derivation. `modustool failed_parts` then lists it beside the log ([scenario_fault_loop.md](../infrastructure/scenario_fault_loop.md)).

`modustool replay <part> <process>` boots a machine of one processor with the debugger, the module files of the history by their hash, and the history, and replays to the end of the history. A developer then attaches with `modustool call <key> "debugger.attach(...)"`, as today, and steps back from the failure.

A recording changes the timing of the processes that it touches. A failure that needs one exact timing can vanish while recorded. rr has a chaos mode that changes the order of the threads on purpose to find such failures; it is a later step.

## The size and the cost

No number is measured yet. Each number below is a measure to take on the test machine, with the condition stated; the choices that a number decides are named.

| Measure | How | Decides |
|---|---|---|
| The cost of a switch when nobody records | The rate of kernel entries of the load child of `kernel_events`, with and without the flag test | That the property costs nothing measurable when it is off |
| One trapped read of the cycle counter | `system.nanoseconds` in a loop, recorded and not | The cost of `nanoseconds` in a recorded process |
| One trapped `cpuid` | The same, with `cpuid` | Whether a process reads `cpuid` once at its start |
| The bytes of history in one second | `clock` (idle with a window), `flow` (one million records), the console with a typed line, `tables` | The size of the ring of the recorder and of a kept history |
| The slowdown of a recorded process | The records of `flow` in one second, recorded and not | Whether the machine tests record each process or only the named ones |
| The wait of a shared writer | The most and the median of the wait of the compositor while `clock` is recorded | The bound of the first layer |
| The speed of a replay | The time of a replay of each history above, against the run | The rate of the checkpoints |
| The size and the time of a checkpoint | The copy of the memory of `clock` and of the console | The rate of the checkpoints |

The numbers of rr are not estimates for this system. The modus form records more shared memory than rr does (rr refuses memory shared with a process that it does not record) and no code (a module is a hash). Only the measures above decide.

## The frequent tasks

Each one is one expression (property 22). The exports are of the debugger service; the console has each under the same name. The first eight exist; the others are a proposal.

| Task | Expression |
|---|---|
| Record the debugged process | `record_start()`, which gives the row of the record |
| End a record and keep its history | `record_end()`, which gives the row of the record with its end |
| See the record, also after the kernel ended it | `replay_status()` |
| Keep a checkpoint at the last input point | `replay_checkpoint(0)`, with the thread 0 held |
| Find the way back by input points | `replay_step_back(1)`: the nearest checkpoint, and the points that a replay runs from it |
| Start a process recorded from its first instruction | `record("clock")` |
| Replay the history and see where it ended | `replay_start()`, then `replay_status()` |
| Find the last input that wrote some bytes | `watch_back(4206608, 8)`: the input point, what wrote, the values, and the checkpoint before it |
| Go back one instruction, one line | `step_back(0)`, `step_back_line(0)` |
| Find the last write of a variable, by the process too | `watch_back("clock::seconds", 8)` |
| Replay the failure of a part of the full check | `modustool replay <part> <process>` |

**The record of the debugger service today.** `record_start` makes a contiguous history of 16 pages of the service, maps it without Write, and calls `Record_Start` with the process handle of the attach. The service never writes the history: it reads its header through `history_reader_open`, which copies the header once and then checks it, because the kernel writes the header during each kernel entry of the recorded thread. The kernel records only a process that did not run yet, and an attach names a process that runs, so the kernel refuses `record_start` after an attach with the record `State`, `Processes`: the refusal is the export result, not a silent success.

**The start held at the first instruction.** `record("clock")` asks the root service for a start held before the first instruction, with the command `Debug_Start` of the root ring. Its step `Start_Held` starts the module for the caller as `Start` does, keeps the process before `Process_Start` (`system.process_start` with `held_entry`), and gives the debugger the handle with `Debug` under the rule of `Debug`. The service attaches, calls `Record_Start` on a process that is still `Created`, then sends the step `Release`, and the root service calls `Process_Start`. The step `Abandon` stops a held process that no export waits for any more. The end of the debug access lets a held process run, as a detach lets each held thread run. The debugger holds no right to start a process and no right `Control` on it: the start stays in the root service, so no new authority comes with the record.

**The replay of the debugger service today.** `replay_start` sends the step `Start_Replay`: the root service starts the module of the history with no start grant and no window, held. The service compares the hash of the module with the hash of the head, calls `Replay_Start` with its history, and sends `Release`. The head of the history holds the context page as its first `Page_Delta` from the zero page; `Replay_Start` zeroes the context page of the replay and writes that delta, so the replay reads the handles, the values and the seed of the record. A handle of the record names nothing in the replay but its own memory and threads: a command that maps memory that the record received from another process fails there with another status, which is a divergence. So today a replay runs to its end only for a process that maps no memory that it received. The history stays in the service after the end of the debugging, for its caller only, until the next record or the end of the connection of that caller; `replay_status` reads it with no attach. A replay shows `replaying`, then `replayed` with why it ended and the input point of a divergence. A checkpoint keeps the input point, the bytes before it, and `rip` and `rsp` of a held thread; it copies no memory yet. The position of a checkpoint is the last input point of the history, because the first layer counts no instruction between two points. `replay_step_back` gives the plan of `step_back_to_position_plan`; no replay runs it yet.

**The watch back over the history today.** An input history holds each byte that entered the process from outside: the changed ranges of its point copies and shared pages (`Page_Delta`), and the bytes that a kernel entry copied into it (`Kernel_Completion`). So `watch_back(address, size)` answers "which input wrote these bytes last" with a scan of the history and no replay (`history_find_last_write`). The scan reads the records in order through the border of the contract and keeps the last one whose written range shares a byte with the watched range. A record that fails the border, or an input point that does not grow, refuses the whole history: a scan that skipped a record could name a write that a later one hid. The row pairs the write with the newest checkpoint strictly before its point (`checkpoint_plan_for_target`), because a checkpoint at that point holds the state after the write. A write by an instruction of the process is not an input, so the scan cannot see it: that answer needs the replay to a point with a data breakpoint, which `watch_back_plan` plans and no export runs yet. The console has no hexadecimal number, so the address is decimal; a place by the name of a global waits for that replay, which has the debug object of the replayed module.

## Prior art

- **rr** (Mozilla), <https://rr-project.org/>, and its paper, "Engineering Record And Replay For Deployability" (USENIX ATC 2017), <https://arxiv.org/abs/1705.05937>. It records a tree of Linux processes from outside, with `ptrace` and a filter of `seccomp`, runs one thread at a time, places a signal and a switch by the count of retired conditional branches, traps `rdtsc` (`PR_SET_TSC`), hides `rdrand` and the transactions with CPUID faulting, and steps back by a replay from checkpoints made with `fork`. On AMD Zen its count is exact only when the host turns off one speculation of the processor (<https://github.com/rr-debugger/rr/wiki/Zen>). **Taken**: one thread at a time, the branch count for an interrupt, the trap of `rdtsc`, CPUID faulting, the step back by replay from checkpoints. **Refused**: a recorder outside the kernel that stops the process at each system call (modus has one kernel entry and records there, with no switch to a recorder), the buffer of system calls inside the process, and the refusal of memory shared with a process that is not recorded (on modus all communication is shared memory, so the record must keep it).
- **Pernosco**, <https://pernos.co/>. It reads an rr trace, replays it, and builds a database of each write and each call of the run, so a developer asks where a value came from with no step at all. **Taken**: the direction, a history as a table that the console queries (property 12, property 19). **Refused for now**: a database of every write, whose size and cost wait for the measures of a history.
- **Windows Time Travel Debugging**, <https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/time-travel-debugging-overview>. It records one process by running its code under an instrumentation engine in the process, each thread apart, with points of order at its synchronisations, and gives queries over the trace (the calls, the memory accesses). **Taken**: the queries over a history. **Refused**: the instrumentation of each instruction, with its cost of many times the run, and threads recorded apart, which leaves a data race between them without one order.
- **The record and replay of QEMU**, <https://www.qemu.org/docs/master/devel/replay.html>. It records a whole machine at its border: the inputs of its devices, its clocks, its interrupts, placed by a count of instructions (`icount`), with TCG only, and steps back with snapshots of the machine. **Taken**: a record at the border where inputs enter, which is the input point of a process here. **Refused** as the mechanism: TCG only, the whole machine, a speed far under KVM, and no use on the machine of a principal. It stays a candidate tool for a fault of the kernel itself, which this design does not record.
- **Deterministic simulation**: FoundationDB (<https://apple.github.io/foundationdb/testing.html>) and TigerBeetle (<https://docs.tigerbeetle.com/>, its simulator VOPR). The code reaches the time, the network, the disk and the randomness through one interface, which a test replaces with a simulation from a seed, so each failure comes again from its seed. **Taken**: the rule that every source of change goes through one interface; property 24 is that rule for every process of the system, and the sandbox of a builder already gives a seed and a frozen date page ([recipes.md](recipes.md)). **Refused**: a program model of one thread over a simulator, as the rule for each process. Modus records the real run of a process that has threads, rather than ask each process to run in a simulator.

## Refused forms

- **A record in a library of the process.** A process that reads shared memory without the library escapes, and a read of shared memory twice, the fault that a replay must show, is outside the library by definition.
- **A recorder outside the kernel, through the fault ring and `Thread_Control`.** With it, each trap of the cycle counter is a round trip to another process with two switches, and no fault tells a recorder what a kernel entry wrote.
- **The record of the order of the synchronisation between threads.** It needs each access between threads to be a known synchronisation; a data race is not one, and its order is lost. One thread at a time keeps a race too.
- **Deterministic multithreading for every process** (an order of the threads fixed by the system at all times). It changes how each process runs when nobody records.
- **A point copy of a page that both sides write.** The writes of the recorded process reach the peer late; a ring then waits on a stale flag and never wakes.
- **Pinned shared writers.** They run on the processor of the recorded process, so the record changes the placement of processes that the recorder holds no handle to.
- **The cycle counter trapped for each process, by this property.** It is the decision of property 20, line 17, not of this property. That decision waits for a measure of the cost of the trap; the flag of this design makes it possible with no new mechanism.
- **The time page as the only clock while recorded.** A recorded process then loses each time under 1 ms, and takes another path than it takes when it is not recorded.
- **A replay inside a guest of the replayer.** The process then runs in another mode than it ran in, with a stub kernel for its kernel ring, and its replay proves another run.
- **A checkpoint by `fork`.** The system has no `fork` (property 16); a checkpoint is a copy of the memory objects that the replay holds.
- **A record of a whole tree of processes as one history**, as rr records. The unit of the rule is one process, with the rest of the system as its inputs. Several histories that a replay joins are a later step.
- **The whole machine recorded in QEMU as the mechanism.** See "Prior art".

## Subtle points and hazards

- **A history is as secret as the process.** The context holds the seed of the generator of the process, and the history holds each byte that the process read. It belongs to the principal of the session of the process, and stays in a store of that principal.
- **A recorded process sees fewer features of the processor.** The answer of `cpuid` hides `rdrand`, `rdseed`, `rdpid`, the transactions and `waitpkg`. Code that tests a feature then takes another path while recorded. rr has the same effect.
- **The time does not move between two points in the first layer.** A recorded thread that waits for `system.time()` in a loop with no kernel entry reads its point copy, which changes only at its next point: it reaches the bound, and the history ends there. `system.nanoseconds` traps, so it moves.
- **A history that ends at the bound is still a history.** A replay reaches its end exactly; only what came after is missing.
- **A torn page is recorded as it was.** A point copy made while its writer is in the middle of a change holds an odd change counter; the reader gives up as it does with no record, and the replay gives up the same way.
- **The replay of a handle.** The replay never holds the object of a handle of the history but memory and threads, so a command that names another handle must never run for real in replay mode: the kernel answers it from the history, or it is a divergence.
- **A change of the address space by the creator** takes effect at a shoot-down, at any instruction. In the first layer the kernel delays it to the next point of the recorded thread: the creator waits for that point, with the bound of one stint, as a shared writer does.
- **A revocation never waits for a record.** A revocation that ends a mapping of a recorded process takes effect at once, as it does with no record, and ends the input history with its reason. A record never delays the end of an access.
- **The branch count on AMD Zen** is exact only when the host turns off one speculation of the processor, which a guest cannot do. On the test host the second layer can give a divergence that is a fault of the count and not of the process. A trial at the start, as the counters have, must find it.
- **QEMU with TCG has no counters**: only the first layer records there.
- **The kernel itself is not recorded.** A fault of the kernel shows in a replay as a divergence or as a replay that does not reach the failure; the record of QEMU is the tool for it.
- **A refused leave stays asked.** A recorded thread that wants to leave its input point while a writer runs waits; if a processor could take another writer, or the same one again, at that moment, the thread would wait for ever. So its leave stays asked in the gate (`leave_requested`), and no writer begins a new run until the thread left. The bound counts that wait too.
- **A writer that ran before the record.** A processor that took a thread of a writer before `Record_Start` runs it with no count of the gate. The leave of the recorded thread also reads the count of the processors that run the writer process (`holds`), and waits for 0, with an interrupt to each such processor.
- **The wait of the leave answers the other processors.** While a writer is on a processor, the recorded thread passes through `schedule` and tries its leave again. Each try answers `processor_sync` and opens one interrupt window with no thread and no lock held: a writer can itself wait in `processor_sync` for this processor, and the tick of the first processor, which keeps the time and the bound, must go on.
- **Short entries do not move the bound.** At each kernel entry the kernel marks each writer that has a ready thread as waiting, while the recorded thread is still outside its point. The gate keeps the first start of a wait until a writer runs, and the tick decides from that start: a thread that enters and leaves again before any processor takes the writer cannot hold the writer past one stint. A writer that became ready while the thread ran its own instructions waits from the last leave of the thread.
- **The set of writers is whole.** `Record_Start` marks the mappings of the target and counts the record before it looks at the other processes: a process that maps a page of the target with Write, or gives itself Write with `Memory_Protect`, after the look at it is refused, and one that did it before is seen. A failure takes the mark back.
- **A thread that ends leaves the gate.** `thread_finish` removes the recorded thread from the gate under the process lock, so its writers are not held by a thread that no longer runs. A thread that the gate cannot hold ends the history.
- **The pick passes over a waiting writer.** A writer that the gate holds goes back to its queue; the strategies pass over it, as over a thread whose budget is spent, by one hint (`writers_held` of the record), so a processor does not take it again and again. The hint is set under the lock of the recorded process before the gate refuses, and the gate decides under that lock.
- **The root service and the compositor are shared writers of most processes.** Each process with a root ring or a window shares a ring with Write with one of them. A record holds them at most one stint at a time, and a writer writes for one record only: a second record whose process shares a writer with a record that runs is refused with `State`, `Processes`.
- **A new writer is refused while a record runs.** A mapping with Write, or a `Memory_Protect` that gives Write, of memory that a recorded process maps, by a process that is not recorded, gives `Bad_State`: that writer would write outside the gate.

## The layers

Each layer adds one capability to a system that works.

1. **The record and the replay of one thread at its kernel entries.** The contract `input_history` with its border and its host tests; `Record_Start`, `Record_End` and `Replay_Start`; the trap of the cycle counter and of `cpuid`; the point copies; one thread at a time; the end at the bound; the check of the tool against `rdrand` and `rdseed` in the code of the system; a test module, recorded then replayed to the same end, and the same module with a planted `rdrand` that the replay finds as a divergence; the measures of "The size and the cost". A process with a shared writer is refused in this layer.
2. **Shared writers.** A shared writer waits for an input point, with the bound; the changes of the address space by the creator wait the same way. The console, a window process and `flow` can then be recorded.
3. **The debugger replays.** The exports of "The frequent tasks", the checkpoints, the step back and the watch back, and their keys in the window of the debugger.
4. **The machine tests record, and the tool replays a failed part.** The mark of a row, the copy of each history through the memory file, `modustool replay`.
5. **Interrupts as input points, placed by the branch count.** It removes the bound of one stint and lets a thread switch anywhere, on a machine with exact counters.

Later, with no order: a record that starts on a running process, with a checkpoint at the start; the record of a service that maps memory that a device writes, by a copy that its device service makes while it is recorded; the record of a guest; several histories joined in one replay; a history as tables that the console queries; a chaos mode.

## State

Layer 1 kernel, contract, test module, and tool check are built:

- Contract `src/library/modus/contract/input_history` defines the fixed-layout input history header, record headers, payloads (`Kernel_Completion`, `Cycle_Counter`, `Processor_Identification`, `Page_Delta`, `History_End`), strict border readers/writers, page-delta encoder/validator/applier, and the pure divergence comparator `replay_step_check`, with host tests.
- Pure kernel part `src/modulus/replay_filter` decodes trapped `rdtsc` (`0F 31`), `rdtscp` (`0F 01 F9`), and `cpuid` (`0F A2`), filters unrecordable CPUID feature bits (`rdrand`, `rdseed`, `rdpid`, `HLE`/`RTM`, `waitpkg`), and classifies operations for replay, with host tests.
- `Thread_Control` adds `Record_Start`, `Record_End`, and `Replay_Start` under the `Debug` right without adding a kernel operation (35 operations unchanged). The kernel probes CPUID faulting via register trials at processor start, toggles `CR4.TSD` and `MSR_MISC_FEATURES_ENABLES` bit 0 only for recorded/replayed threads, emulates trapped `rdtsc`/`rdtscp`/`cpuid` in `#GP`, maintains point copies for read-only shared pages, pins recorded/replayed processes to one processor, enforces the one-stint bound, ends history immediately on revocation, and stops replay on divergence.
- Test module `src/modules/tests/replay_probe` exercises deterministic arithmetic, `system.nanoseconds`, `cpuid`, and opt-in divergence modes.
- Tool check `tools/modustool/checks/processor_random_check.odin` refuses `rdrand` and `rdseed` anywhere in `src/` outside `random.entropy_gather` (`src/library/modus/random/entropy.odin`).

Layer 2 is built in the kernel:

- The kernel takes memory that the recorded process and another process both map with Write: `Record_Start` makes the gate (`replay_filter.Shared_Writer_Gate`) of its writers, keeps a baseline frame of each such page (64 pages at most, paid by the budget of the history), and records its first bytes. The kernel entry of the recorded thread copies the baselines and lets the writers run; its return to its own instructions waits until no writer is on a processor, then writes each changed range as a `Page_Delta` at that point. The pick of a processor asks the gate before a thread of a writer runs, and the leave of the processor ends that run. The tick of the first processor ends the history with `Stint_Bound_Reached` when a writer waited one stint (`TIME_SLICE`). The cleanup of a writer that stops removes it from the gate; a revocation ends the history at once.
- The replay writes a `Page_Delta` of a page that is no point copy into the page that the replay maps with Write at that address.
- The context page is in the head of the history, and the replay writes it back.
- The debugger records a process from its first instruction (`record("clock")`) and replays a history (`replay_start()`), through the command `Debug_Start` of the root service.

Layer 2 and Layer 3 pure engines are built:

- Pure kernel part `src/modulus/replay_filter/shared_writer.odin` implements the explicit `Shared_Writer_Gate` state machine (`add_shared_writer`, `recorded_thread_enter_input_point`, `recorded_thread_leave_input_point`, `shared_writer_may_run`, `shared_writer_begin_run`, `shared_writer_end_run`, `shared_writer_stint_expired`, `shared_writer_revoke_immediately`), enforcing that shared writers run only while every recorded thread is at an input point, preventing recorded threads from leaving while a shared writer executes on a processor, ending history cleanly with `Stint_Bound_Reached` at the one-stint bound, and ending immediately with `Revocation` on revocation override, with adversarial host tests.
- Contract `src/library/modus/contract/input_history/debugger_replay.odin` implements the fixed-capacity `Checkpoint_Ring` and pure reverse-execution planners `step_back_plan` and `watch_back_plan`, selecting the nearest prior checkpoint, computing exact forward replay point and single-step counts, validating hardware data watchpoints, and walking backward across checkpoint windows to locate the last prior write overlapping a watched address, with adversarial host tests.

Layer 3 is wired into the debugger service for the record: the exports `record_start`, `record_end`, `replay_status`, `replay_checkpoint`, `replay_step_back` and `watch_back` (`src/modules/system/debugger/replay_wiring.odin`, `src/modules/system/debugger/exports.odin`), with the console commands of the same names ("The frequent tasks"). `watch_back` finds the last input of the history that wrote a range (`src/library/modus/contract/input_history/watch_back.odin`), with adversarial host tests.

The gate in the kernel is concurrent kernel code: it waits for its machine test and an independent review before it counts as done. A thread held at a fault, or stopped by the debugger between two points, is not an input point for the writers yet: they wait, and the bound ends the history. A mapping into the recorded process of memory that another process holds is refused while a record runs (`record_replay_map_conflict`), not delayed to the next point.

Left: the machine test of a module recorded then replayed to the same end, of the same module with a planted `rdrand` found as a divergence, and of a recorded window process with its shared writers, with the measures of "The size and the cost" (layers 1 and 2); a thread held at a fault as an input point for the writers; the private copy of memory that the record received, so that a replay of a process with a window runs to its end; the replay from a checkpoint, the step back by instructions and lines, the watch back of a write by the process itself, and their keys in the window of the debugger (layer 3); machine-test recording and `modustool replay` (layer 4); and branch-count interrupts (layer 5). The planned work is in `ROADMAP.md`.
