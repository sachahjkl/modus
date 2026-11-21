# Stolen time

The kernel does not charge a thread for the time in which the host ran no code of its processor. On a machine under KVM, each processor registers the steal-time record of KVM at its start, and the kernel subtracts the stolen time of a run from the processor time that it charges to the thread, to each budget above it and to its strategy.

## The fault that made it

The kernel charges processor time with the cycle counter, from the moment when a processor takes a thread to the moment when it leaves it (`budget_charge`, [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Processor time"). Under KVM the cycle counter goes on while the host runs another task on the physical processor. Those cycles went to the thread that ran when the host took the processor away. A full check ran while other builds loaded the host to a load average of 47 to 58 on 16 threads, and the process `limits` read 327 ms used by two budgets with a limit of 50 ms and of 200 ms in one second. The budgets had not run that long: the host had. So the measure depended on the load of the host, which the rule of the tests forbids ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests").

## Constraints

- A real machine has no stolen time. It must charge exactly what it charged before.
- The charge runs at each tick and at each switch of threads. It takes no lock, makes no kernel entry, and reads no memory outside the processor record but the global `cycle_frequency`, which the first processor writes once at boot.
- No new kernel operation and no change of a contract: the time that a budget used (`Budget_Read`) only stops to count time that no thread used.
- A charge is never negative, whatever the host writes.

## The chosen form

**The source.** The Linux documentation, `Documentation/virt/kvm/x86/msr.rst` ("MSR_KVM_STEAL_TIME") and `Documentation/virt/kvm/x86/cpuid.rst` ("KVM_FEATURE_STEAL_TIME"):

- The machine is a hypervisor guest when bit 31 of ECX of `CPUID` leaf 1 is set. The leaves of a hypervisor start at `0x4000_0000`; with another interface of a hypervisor in front, the KVM leaves can start at a later multiple of `0x100`, up to `0x4001_0000`, as Linux searches. A base whose EBX, ECX and EDX give `KVMKVMKVM\0\0\0` is the base of KVM. EAX of the base is the highest leaf of KVM: the leaf of the features, the base plus 1, exists only when EAX is 0 (an old KVM) or at least the base plus 1, as `hypervisor_cpuid_base` of Linux decides, and the kernel reads it only then. EAX of that leaf holds the features; bit 5 is the steal time. The kernel stops at the first base with the signature; Linux goes on to a later base when the highest leaf is too low, a case that no KVM gives.
- The register `MSR_KVM_STEAL_TIME` (`0x4B56_4D03`) takes the physical address of a record of 64 bytes, aligned on 64 bytes, in the memory of the guest, plus the enable bit 0. The guest zeroes the record before the write. One write for each processor is enough: the host fills the record of that processor until a write with bit 0 clear.
- The record is `steal: u64` (the nanoseconds in which this processor did not run; the idle time of a processor that waits is not steal), `version: u32`, `flags: u32` (always 0), `preempted: u8`, then padding to 64 bytes.
- The version is a sequence counter. A reader reads the version, then `steal`, then the version again. The two values must be equal and even; an odd version is an update in progress.

The record, the constants, the decision from `CPUID` and the arithmetic are the kernel part `stolen_time` (`src/kernel/stolen_time`), pure code with host tests. The kernel holds the reads of `CPUID`, the register write and the loads of the record. The version protocol is the pure procedure `stolen_time.read_steal`, which takes a load procedure: the kernel gives one that makes volatile loads of the record of its processor, and a host test gives one that plays a series of versions. A kernel part may not make a volatile load itself. `read_steal` is inlined and the load procedure of the kernel is a constant, so the optimized kernel calls no procedure value; an indirect call that stayed would fail the measure of the kernel stack, which refuses an indirect call that its table does not state.

**The registration.** The first processor reads `CPUID` once and decides if the machine offers steal time. Each processor, before any thread runs, zeroes the record in its processor record and writes its address with a register trial ([`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md), "Register trial"). A refused write leaves that processor without steal time; the other processors keep it. The first processor registers after its setup. Another processor registers only after the first processor accepted its start (`Processor.start_accepted`): it counts itself in `started_count`, waits for the acceptance, then registers. A processor that started after the time-out of the first processor never gets the acceptance; the first processor resets it, then frees its processor record, so the host never gets the address of a record in freed memory. This was chosen over a write of 0 to the register: only the processor itself can write its register, and a late processor does not know that it is late. After the start of the processors, the first processor waits until each accepted processor ended its setup of the steal time, then writes one line: the count of the processors that registered, or the reason for none.

**The read.** At each charge the kernel reads the record with the version protocol, at most `READ_ATTEMPT_LIMIT` times. The host writes the record of a processor only when that processor enters the guest again, so the processor that reads its own record does not see a write in progress, and the bound only closes a hang. A read that fails subtracts nothing and keeps the last value. The next charge that reads the counter subtracts at most its own run, so the stolen time of the failed run beyond that is lost: the thread pays too much, never too little.

**The arithmetic** (`stolen_time.charge_without_stolen`):

- The stolen nanoseconds since the last charge become cycles with the frequency that the kernel measured at boot. Seconds and the rest are converted apart, as `milliseconds_now` does, and a product past 64 bits gives the largest value.
- The stolen cycles are at most the cycles of the run: the charge is the run minus the stolen time, never below 0.
- A steal counter below the last value is refused: the charge is the whole run, as on a real machine, and the counter is taken as the new last value, so the next charges are right.

**Where it applies.** `budget_charge` gives the charge without the stolen time. The budget of the thread and each budget above it count that charge, and the strategy charges the same value to the virtual time of the thread. At the pick of a thread, the kernel takes the counter as the start of the run, as it takes the cycle counter: the stolen time while the processor had no thread goes to no thread.

## What does not change

- **The length of a stint and of a period.** A stint ends by the cycle counter since the pick, and a period by the cycle counter since its start. Both are time of the machine, not time of a thread: a stint is a bound of latency for the other threads, and a period is the time against which a limit holds. A stint in which the host took the processor away is shorter for the thread, and it is right for the other threads.
- **The run time in ticks.** `Thread_Report.run_time` and `Process_Report.run_time` count the ticks in which a thread ran. A processor that the host does not run gets no tick, so this count already holds no stolen time; it holds the share that the host gives each processor, which is what the check of the share policy still meets (`ROADMAP.md`).

## The deadline of a limit

A thread that reaches its limit stops at the next tick, 1 ms later at most when the host runs the processor. A one-shot timer at the time left would stop it closer. The cost: the timer of each processor goes to the TSC deadline mode, and each interrupt writes the next deadline, the earlier of the next tick and the end of the budget of the thread. The time left is the least among the budgets of the chain, and the threads of other processors spend the same budgets, so the deadline is only a bound; the tick still checks. Under KVM each write of the deadline is an exit to the host. The gain is at most one tick in each period of 100 ms, which the next period takes back already ("What a budget used above its part of a period, it has less in the next period", `src/kernel/limit.odin`). The change touches the tick of every processor and the idle pause for a gain that no test needs, so it is not built: it is an entry of `## Maybe` in `ROADMAP.md`.

## Refused forms

- **The paravirtual clock of KVM** (`MSR_KVM_SYSTEM_TIME_NEW`) as the base of the charge. It is a time of the host, which goes on while the processor does not run, as the cycle counter does. It removes no stolen time.
- **The flag `preempted`** of the record. It says that the processor is out now, which only another processor can read, and it gives no amount.
- **A record in a page of its own.** The processor record is in the direct map, aligned on a page, and the record of 64 bytes in it does not cross a page. A page of its own is one more allocation for each processor for no gain.
- **The excess carried to the next charge.** Stolen time above the run belongs to time when the processor had no thread, or to a run that the host reported late; a carry would take it from the next thread.
- **A trial of the host load in the test.** No test asserts a load or a duration. The test reads that the kernel registered, or why it did not.
- **A list of hypervisors.** The kernel reads the feature from `CPUID`, never the name of a host model.
- **A stop of the machine at a counter that goes back.** The host is trusted with all the memory of the guest already; a wrong counter gives the whole charge, the behavior of a real machine.

## Subtle points

- **The drain of the serial port.** The tick moves `charged_from` past the time of its drain of the serial port, so no budget pays for it. Stolen time during the drain is subtracted from the next charge, which can then be smaller than the time that the thread ran by that stolen time. The error is at most the stolen time of one drain.
- **TCG.** QEMU without KVM has no steal time: the line says so, and every cycle of a run is charged, as before.
- **No bound against a host that reports too much.** The kernel sets no cap on the stolen time. The host can already stop the machine or change its memory, so a host that reports false steal time is outside what the kernel can defend. A cap would also refuse the true stolen time of a heavily loaded host, the case that this work fixes. The real bound: one false jump of the counter costs at most one run, because the excess is not carried to the next charge; a host that raises the counter by at least the run at each charge makes each charge 0, with no bound. A host test states this behaviour (`a_host_that_reports_false_steal_time`).
- **The first processor registers before the timer is measured.** The conversion reads `cycle_frequency` at each charge, and no charge runs before the timer starts.

## State

Built: the kernel part `stolen_time` with its host tests, the registration at the start of each processor, the read at each charge and at each pick, the boot line, and its wait in the main machine test. Left: the deadline of a limit (`ROADMAP.md`, `## Maybe`).
