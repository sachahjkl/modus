# The counters of a thread

A program counts what the processor does for its own code: the instructions retired, the cycles, the cache misses and the branch misses. A developer then measures the cost of a data layout, and not only its time. The kernel holds the mechanism: it programs the performance counters of the processor for one thread, keeps the counts of that thread when it leaves a processor, and gives them back. The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Performance counter" and "Thread counters". The guide is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The counters of a thread".

## Constraints

- **The count of kernel operations.** A new operation needs a capability that no operation can carry ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). `Thread_Control` already names a thread and acts on its state.
- **No ambient access** (property 20). A count of cache misses is a measure of the caches that a thread shares with other programs: line 17 of the table, side channels, says that a precise clock is a grant. A program with no grant counts nothing.
- **The counts of a thread are its own.** No count of the kernel, of another thread or of another program reaches a thread.
- **One fixed machine first** (property 7). The host of the tests is an AMD Zen 3 processor under KVM. Intel has another form of the same counters, which the test machine cannot show.
- **A test never asserts a count.** A count depends on the processor, the hypervisor and the cache state. The test checks a lower bound that the code fixes, and prints the counts as a measure ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests").

## The chosen form

### Four events, one set on each processor

The thread counters are four counts, in this order (`op.Thread_Counters`):

| Count | Intel (architectural event) | AMD Zen (core counter) |
|---|---|---|
| `instructions_retired` | 0xC0, mask 0x00 | 0xC0, mask 0x00 |
| `cycles` | 0x3C, mask 0x00: core cycles, not halted | 0x76, mask 0x00: cycles, not halted |
| `cache_misses` | 0x2E, mask 0x41: misses of the last level cache | 0x64, mask 0x09: misses of the L2 cache, from the data cache and the instruction cache |
| `branch_misses` | 0xC5, mask 0x00: branches mispredicted, retired | 0xC3, mask 0x00: branches mispredicted, retired |

These are the four events that each vendor names for the same four questions, and the events that Linux takes for its generic events on these processors. No fifth event is given: a program that wants a model-specific event names a fact of one processor, and the set would then differ on each machine.

The kernel uses the general counters 0 to 3, one for each count, with the same select bits on both vendors: the event, the mask, User (bit 16) and Enable (bit 22). Operating System (bit 17) is clear, so the processor counts only in user mode. Interrupt (bit 20) is clear: no counter interrupts, and an overflow of a counter of 48 bits in one turn of 10 ms is not reachable.

The kernel finds the set from `CPUID` at boot, once (`processor_counters.plan_of_identification`, with host tests):

- **Intel**: leaf 0xA, version 1 or more, at least 4 general counters, and each of the four events present (its bit of `EBX` clear, inside the length of `EBX`). The select registers are `IA32_PERFEVTSEL0` to 3 (0x186), the counters `IA32_PMC0` to 3 (0xC1). From version 2, the kernel turns on the counters 0 to 3 in `IA32_PERF_GLOBAL_CTRL` (0x38F) on each processor at its start: a firmware can leave them off.
- **AMD**: the core counter extension (`CPUID` 0x80000001, `ECX` bit 23), and a family of Zen (0x17 or more). The select registers are 0xC0010200 + 2n, the counters 0xC0010201 + 2n. With the monitoring version 2 (`CPUID` 0x80000022, `EAX` bit 0) and 4 counters or more, the kernel turns on the counters 0 to 3 in `PerfCntrGlobalCtl` (0xC0000301) on each processor at its start.
- **Else** no set: the machine has no thread counters.

### Three commands of `Thread_Control`, on the calling thread

`Start_Counters`, `Read_Counters` and `Stop_Counters` are commands of `Thread_Control`, not a new operation. They act on a state of a thread, as the other commands do, and the count of kernel operations stays.

- `Start_Counters`: the calling thread counts from 0 from now on. A thread that counts already starts again from 0.
- `Read_Counters`: writes the `Thread_Counters` of the calling thread at the address; the thread goes on counting. A thread that does not count gives `Bad_State`.
- `Stop_Counters`: the thread stops counting. Its switches then cost nothing more. It reads no handle and needs no right (below).

The three commands act only on the calling thread. The counts of a thread that runs now are in the registers of its processor. The calling thread runs on the processor of its kernel entry, so its counts are there, and the kernel reads them with no interrupt to another processor and no hold. Another thread of the program would need a hold, or an interrupt that reads the registers of its processor; a program that measures its own code needs neither.

### The grant: the right `Counters` of the machine handle

For `Start_Counters` and `Read_Counters`, `thread` is the machine handle with the right `Counters`; `number` is not read. The root service gives the right to a program by its role (the start grant `Counters`), and a revocation of the grant `machine` takes it back. Today only the test program `counters` has it.

`Stop_Counters` needs no handle and no right, and gives `Ok` on each machine. It only takes a capability away and gives nothing. With the right, a thread whose right was revoked would read no more counts but could not stop counting either, and each of its switches would keep paying the writes of the counter registers (an exit of each one under KVM).

The reason is the side channel. A count of the misses of a cache that other programs share is a measure of what those programs do, with less noise than a clock: property 20, line 17, makes a precise clock a grant, and this measure is finer for that use. The right costs one bit of the machine handle, and no check on the switch.

### The switch of threads

A thread that counts has the flag `counting` in the hot line of its record, beside `has_breakpoints`. A switch to a thread with no counters tests that byte and writes no register.

- When a processor takes a thread that counts, it writes 0 in the four counters, then the four select values.
- When a processor leaves a thread that counts, it writes 0 in the four select registers, reads the four counters, and adds each to the total of the thread (a word of 64 bits).
- `Read_Counters` gives the totals plus the four counters of this processor now.

So the counters never count for another thread: the selects are off from the leave to the next take. A counter starts at 0 at each take, so the kernel never writes a count back: on Intel a write of a counter keeps only 32 bits, unless the processor has the full-width writes, and the totals of 64 bits have no such limit.

Only the processor that runs the thread reads or writes its flag and its totals: the thread itself in its kernel entry, or `schedule` at the leave and at the take. The release of the run lock at the leave orders the totals before the take of another processor, as for the extended state.

### A machine with no counters

On a machine with no set, `Start_Counters` and `Read_Counters` give `Bad_Operation`, with the error kind `Unsupported` (the value: the operation `Thread_Control`). The line of the boot says why: "kernel: performance counters: ...: none that the kernel uses". The test machine with KVM has the set; QEMU with TCG has no counters. The tool decides which outcome a machine test checks from that boot line of the test machine, and not from the host: QEMU falls back to TCG when it cannot use KVM, and a hypervisor below the host can hide the counters that the host lists. The host only explains the outcome.

## Refused forms

- **A new kernel operation.** The three commands name a thread and act on its state, which `Thread_Control` does already.
- **`rdpmc` in user mode** (the bit PCE of `cr4`). A read with no kernel entry is a clock of the caches, at each instruction, that the kernel cannot take back: a revocation of the right would not stop it while the thread lives. A read through the kernel costs one entry at each end of a measure, not inside it.
- **The counts of another thread, or of another program.** A profiler of another program needs them, with the hold of a thread. It is not this capability; the commands keep `number` unread so that a later form can name a thread of the program.
- **The counters in the event records.** An event record is a fact of the kernel; its counts would be counts of kernel code, which a program does not see. The events carry the cycle counter only.
- **No grant.** Linux lets a process count its own user code with no privilege (`perf_event_paranoid` 2). Here the property makes a precise measure of shared state a grant, and the cost of the grant is one right.
- **A list of events that the program chooses.** The four events of the table are the same questions on each vendor; a free event number would be a fact of one processor in a program.
- **A write of the count back at each take.** It needs the full-width writes on Intel, and a counter that starts at 0 needs none.
- **The bits Host Only and Guest Only of AMD.** With SVM off they stop the counter on some processors; the kernel leaves both clear, so a thread that runs a guest also counts the user code of its guest. That code is code that the thread runs.

## Subtle points

- **User mode only.** A kernel entry of the thread is not counted, nor an interrupt, nor the code of the kernel at a switch. The `syscall` instruction itself retires in user mode: a measure between two kernel entries counts one or two instructions of the entries.
- **The cache misses are of one level of one vendor.** Intel counts the last level cache, AMD the L2 cache. A count compares two layouts on one machine; it is not a number to compare between two machines.
- **A virtual processor.** Under KVM the counts are those of the host counters while the virtual processor runs the thread. A guest counter of KVM is a pinned event of the host: it counts in full, or not at all when the host has no free counter. The test then fails with its counts on the line: a host with other users of its counters is not a host of this test.
- **The family check of AMD.** The event 0x64 with the mask 0x09 is the cache miss of Zen; a processor before Zen has other encodings, and the kernel gives it no set.
- **A thread that ends while it counts.** The leave of its processor turns the selects off. A new thread in the same slot starts with the flag clear: the kernel clears each thread record at its creation.

## State

Built: the four events on Intel and on AMD Zen, the three commands on the calling thread, the right `Counters` and the start grant `Counters`, the save at the switch, the line of the boot, the host tests of the plan, and the program `counters` in the test part `kernel_events`, which counts the instructions of a loop of known length. Left: the counts of another thread with a hold (a profiler); the Intel form on a test machine; a machine whose hypervisor lists counters and refuses their registers (a protection fault at boot stops it today), and a counter that the firmware left on, which the kernel turns off where it could refuse the counters (`ROADMAP.md`).
