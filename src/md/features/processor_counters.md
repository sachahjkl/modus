# The counters of a thread

A process counts what the processor does for its own code: the instructions retired, the cycles, the cache misses and the branch misses. A developer then measures the cost of a data layout, and not only its time. The kernel holds the mechanism: it programs the performance counters of the processor for one thread, keeps the counts of that thread when it leaves a processor, and gives them back. The terms are in [`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md), "Performance counter" and "Thread counters". The guide is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The counters of a thread".

## Constraints

- **The count of kernel operations.** A new operation needs a capability that no operation can carry ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). `Thread_Control` already names a thread and acts on its state.
- **No ambient access** (property 20). A count of cache misses is a measure of the caches that a thread shares with other processes: line 17 of the table, side channels, says that a precise clock is a grant. A process with no grant counts nothing.
- **The counts of a thread are its own.** No count of the kernel, of another thread or of another process reaches a thread.
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

These are the four events that each vendor names for the same four questions, and the events that Linux takes for its generic events on these processors. No fifth event is given: a process that wants a model-specific event names a fact of one processor, and the set would then differ on each machine.

The kernel uses the general counters 0 to 3, one for each count, with the same select bits on both vendors: the event, the mask, User (bit 16) and Enable (bit 22). Operating System (bit 17) is clear, so the processor counts only in user mode. Interrupt (bit 20) is clear: no counter interrupts, and an overflow of a counter of 48 bits in one turn of 10 ms is not reachable.

The kernel finds the set from `CPUID` at boot, once (`processor_counters.plan_of_identification`, with host tests):

- **Intel**: leaf 0xA, version 1 or more, at least 4 general counters, and each of the four events present (its bit of `EBX` clear, inside the length of `EBX`). The select registers are `IA32_PERFEVTSEL0` to 3 (0x186), the counters `IA32_PMC0` to 3 (0xC1). From version 2, the kernel turns on the counters 0 to 3 in `IA32_PERF_GLOBAL_CTRL` (0x38F) on each processor at its start: a firmware can leave them off.
- **AMD**: the core counter extension (`CPUID` 0x80000001, `ECX` bit 23), and a family of Zen (0x17 or more). The select registers are 0xC0010200 + 2n, the counters 0xC0010201 + 2n. With the monitoring version 2 (`CPUID` 0x80000022, `EAX` bit 0) and 4 counters or more, the kernel turns on the counters 0 to 3 in `PerfCntrGlobalCtl` (0xC0000301) on each processor at its start.
- **Else** no set: the machine has no thread counters.

### The trial of the registers at the start of each processor

`CPUID` lists the counters; it does not prove that the processor takes an access to their registers. A hypervisor can list them and refuse each `rdmsr` and `wrmsr` with a protection fault, or take the writes and keep nothing. A protection fault of the kernel stops the machine, so such a machine stopped at its boot. And a firmware can leave a counter on: then another user counts with it.

So each processor, at its start and before any thread runs, takes a trial of the registers of the plan (`processor_counters.trial_steps_of_plan`, with host tests). The trial is a list of register trials ([`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md), "Register trial"), in this order:

1. A read of each select. A select with Enable set is on: another user (the firmware, or the hypervisor) counts with it.
2. For each counter: a write of `TRIAL_COUNTER_VALUE` (0xABCD) to the counter, a read that must give it back, a write of 0; then a write of the select value of the plan, then a write of 0 to the select. These are the writes of the switch. The select value turns the counter on in user mode only, and the kernel runs, so nothing counts.
3. With a global control: a read of it, and a write of it with the bits of the counters 0 to 3 added.

A register trial is one `rdmsr` or `wrmsr` in an assembly procedure of `processor.asm`. `kernel_interrupt` knows the address of that one instruction: a protection fault there goes on at the refusal label of the procedure, which gives false. A protection fault of the kernel at any other address stops the machine, as before.

The first step that fails ends the trial, and its register is named (`processor_counters.trial_step_outcome`): the processor refused it (`Register_Refused`), a select was on (`Counter_In_Use`), or a counter did not keep the value (`Counter_Not_Kept`). The machine then has no plan: each command of the thread counters gives `Unsupported`, as on a machine with no counters in `CPUID`. When a select is on, the kernel writes no register: the counter stays with its other user.

The first processor writes its outcome in the line of the boot. Another processor whose trial fails turns the plan off for the machine and writes a line of its own: "kernel: performance counters: none that the kernel uses: on the processor 3, ...". No thread runs before every processor took its trial, so no thread ever counts on a plan that a processor refuses.

### Three commands of `Thread_Control`, on the calling thread

`Start_Counters`, `Read_Counters` and `Stop_Counters` are commands of `Thread_Control`, not a new operation. They act on a state of a thread, as the other commands do, and the count of kernel operations stays.

- `Start_Counters`: the calling thread counts from 0 from now on. A thread that counts already starts again from 0.
- `Read_Counters`: writes the `Thread_Counters` of the calling thread at the address; the thread goes on counting. A thread that does not count gives `Bad_State`.
- `Stop_Counters`: the thread stops counting. Its switches then cost nothing more. It reads no handle and needs no right (below).

The three commands act only on the calling thread. The counts of a thread that runs now are in the registers of its processor. The calling thread runs on the processor of its kernel entry, so its counts are there, and the kernel reads them with no interrupt to another processor and no hold. Another thread of the process would need a hold, or an interrupt that reads the registers of its processor; a process that measures its own code needs neither.

### The grant: the right `Counters` of the machine handle

For `Start_Counters` and `Read_Counters`, `thread` is the machine handle with the right `Counters`; `number` is not read. The root service gives the right to a process by its role (the start grant `Counters`), and a revocation of the grant `machine` takes it back. Today only the test module `counters` has it.

`Stop_Counters` needs no handle and no right, and gives `Ok` on each machine. It only takes a capability away and gives nothing. With the right, a thread whose right was revoked would read no more counts but could not stop counting either, and each of its switches would keep paying the writes of the counter registers (an exit of each one under KVM).

The reason is the side channel. A count of the misses of a cache that other processes share is a measure of what those processes do, with less noise than a clock: property 20, line 17, makes a precise clock a grant, and this measure is finer for that use. The right costs one bit of the machine handle, and no check on the switch.

### The switch of threads

A thread that counts has the flag `counting` in the hot line of its record, beside `has_breakpoints`. A switch to a thread with no counters tests that byte and writes no register.

- When a processor takes a thread that counts, it writes 0 in the four counters, then the four select values.
- When a processor leaves a thread that counts, it writes 0 in the four select registers, reads the four counters, and adds each to the total of the thread (a word of 64 bits).
- `Read_Counters` gives the totals plus the four counters of this processor now.

So the counters never count for another thread: the selects are off from the leave to the next take. A counter starts at 0 at each take, so the kernel never writes a count back: on Intel a write of a counter keeps only 32 bits, unless the processor has the full-width writes, and the totals of 64 bits have no such limit.

Only the processor that runs the thread reads or writes its flag and its totals: the thread itself in its kernel entry, or `schedule` at the leave and at the take. The release of the run lock at the leave orders the totals before the take of another processor, as for the extended state.

### A machine with no counters

On a machine with no set, or whose trial failed, `Start_Counters` and `Read_Counters` give `Bad_Operation`, with the error kind `Unsupported` (the value: the operation `Thread_Control`). The line of the boot says why: "kernel: performance counters: ...: none that the kernel uses". The test machine with KVM has the set; QEMU with TCG has no counters. The tool decides which outcome a machine test checks from that boot line of the test machine, and not from the host: QEMU falls back to TCG when it cannot use KVM, and a hypervisor below the host can hide the counters that the host lists. The host only explains the outcome.

## Refused forms

- **A new kernel operation.** The three commands name a thread and act on its state, which `Thread_Control` does already.
- **`rdpmc` in user mode** (the bit PCE of `cr4`). A read with no kernel entry is a clock of the caches, at each instruction, that the kernel cannot take back: a revocation of the right would not stop it while the thread lives. A read through the kernel costs one entry at each end of a measure, not inside it.
- **The counts of another thread, or of another process.** A profiler of another process needs them, with the hold of a thread. It is not this capability; the commands keep `number` unread so that a later form can name a thread of the process.
- **The counters in the event records.** An event record is a fact of the kernel; its counts would be counts of kernel code, which a process does not see. The events carry the cycle counter only.
- **No grant.** Linux lets a process count its own user code with no privilege (`perf_event_paranoid` 2). Here the property makes a precise measure of shared state a grant, and the cost of the grant is one right.
- **A list of events that the process chooses.** The four events of the table are the same questions on each vendor; a free event number would be a fact of one processor in a process.
- **A write of the count back at each take.** It needs the full-width writes on Intel, and a counter that starts at 0 needs none.
- **A list of hypervisors that refuse the counters.** The kernel would trust a name in `CPUID` 0x40000000, which a hypervisor writes as it wants, and a new hypervisor would stop the machine again. The trial asks the processor itself.
- **A recovery from each protection fault of the kernel.** A fault at any address would then hide a fault of the kernel. Only the instruction of a register trial goes on, and only the kernel calls a register trial: at the start of a processor, and in its self test.
- **A trial at the first use of a counter.** A refusal would then come in the kernel entry of a process, with a thread that already asked, and the outcome of a command would depend on the order of the processes. At the start, the plan is decided before any thread runs.
- **A select that was on turned off.** The kernel turned off each select at the start before. A select that is on has another user: the firmware or the hypervisor counts with it, and a write of the kernel would take its counter, or mix two counts in one. Linux finds the same fault at its start, and names it.
- **The trial on the first processor only.** A thread can run on any processor, and the switch writes the registers of the processor that takes it. A processor that refuses would stop the machine at the first switch of a thread that counts.
- **The bits Host Only and Guest Only of AMD.** With SVM off they stop the counter on some processors; the kernel leaves both clear, so a thread that runs a guest also counts the user code of its guest. That code is code that the thread runs.

## Subtle points

- **User mode only.** A kernel entry of the thread is not counted, nor an interrupt, nor the code of the kernel at a switch. The `syscall` instruction itself retires in user mode: a measure between two kernel entries counts one or two instructions of the entries.
- **The cache misses are of one level of one vendor.** Intel counts the last level cache, AMD the L2 cache. A count compares two layouts on one machine; it is not a number to compare between two machines.
- **A virtual processor.** Under KVM the counts are those of the host counters while the virtual processor runs the thread. A guest counter of KVM is a pinned event of the host: it counts in full, or not at all when the host has no free counter. The test then fails with its counts on the line: a host with other users of its counters is not a host of this test.
- **The family check of AMD.** The event 0x64 with the mask 0x09 is the cache miss of Zen; a processor before Zen has other encodings, and the kernel gives it no set.
- **A thread that ends while it counts.** The leave of its processor turns the selects off. A new thread in the same slot starts with the flag clear: the kernel clears each thread record at its creation.
- **The value of the trial.** 0xABCD has bit 31 clear: on Intel with no full-width writes, a write to a counter keeps only 32 bits and extends bit 31, and the value still reads back the same.
- **The plan written by another processor.** A processor that refuses writes the plan while the first processor waits for it to start, and the other processors wait in the scheduler with no thread. The root service starts after the last processor: its threads read the plan after it.
- **The stack of a refusal.** The protection fault pushes its frame and runs `kernel_interrupt` on the stack of the trial. The measure of the kernel stack computes that chain, prints it as its own line, and checks it with the margin ([infrastructure/kernel_stack_depth.md](../infrastructure/kernel_stack_depth.md)).
- **A select that the trial turned on.** A trial can fail after its write of the select value and before its write of 0, and with no plan no later code turns that select off. So after each failed trial but `Counter_In_Use`, the kernel writes 0 to each select of the plan again, as a register trial whose refusal changes nothing more. No process reads a counter (`rdpmc` is off in user mode), so a select left on is no channel, but the kernel leaves no register on that it turned on.
- **The clear of the plan.** The kernel clears the vendor of the plan first, in its own store, then the rest. Each reader tests the vendor first, so a plan whose clear a reset cut (the first processor resets a processor that does not start in time) reads as no plan.
- **The self test.** No test machine lists counters and refuses them: KVM gives the counters of the host, and QEMU with TCG lists none. So a self test of the kernel proves the way back from a refusal: the kernel writes an address that is not canonical (bit 63 alone) to `IA32_KERNEL_GS_BASE` through the same register trial. Intel and AMD refuse it with a protection fault, and so does KVM. QEMU with TCG takes it, and that self test then fails: the self tests need KVM. So the check of the flake (`bootTest` in `flake.nix`) has `requiredSystemFeatures = ["kvm"]`: Nix gives its sandbox `/dev/kvm`, and a builder with no KVM refuses the check, in place of a check that fails on TCG. The tool does not skip the self test on a host with no KVM: the host would then decide an outcome. The host tests prove the order of the trial and each outcome.

## State

Built: the four events on Intel and on AMD Zen, the three commands on the calling thread, the right `Counters` and the start grant `Counters`, the save at the switch, the trial of the registers on each processor with its refusal, the line of the boot, the host tests of the plan and of the trial, the self test of a refused register, and the process `counters` in the test part `kernel_events`, which counts the instructions of a loop of known length. Left: the counts of another thread with a hold (a profiler); the Intel form on a test machine.
