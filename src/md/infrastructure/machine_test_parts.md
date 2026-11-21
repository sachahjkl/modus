# The parts of the machine test

The machine test is a list of parts. A part is one or more machines that share a disk, a TPM state or a value from one machine to the next. Two parts share nothing. This file records why the parts are one table, and how several parts run at once.

## Purpose

- `modustool test <part>` runs one part alone, for the work on it, and builds only the boot volumes of that part.
- `modustool test` runs every part, several at once, and ends when the last part ends.
- In the full check, each part is a derivation of the flake of its own, which Nix takes from the store when the bytes of the build and the tool did not change ([full_check.md](full_check.md), "The derivations of the check").
- A new part is one row. No other place of the tool, of the flake or of the guide names the parts.

## Constraints

- A part that runs alone and the same part in the whole test must do the same work. So a part starts from a new data disk of its own, in both cases.
- A test never depends on the speed of the hardware ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). This is the rule that makes parallel parts admissible: a loaded host changes no result. A part that fails only when another part runs beside it is a fault of a wait of that part, read to its cause.
- A bound of a hang holds only while the host runs the machine. A host that swaps the memory of a machine can give it no processor for minutes, and a step then ends at its bound with no fault of the system. So the parts at once must fit in the memory of the host, and a failed wait must say what the host gave the machine.
- The machines of one part run in their order: a later machine reads the disk, the TPM state, the remembered values or the screen text of the one before.
- A measure of a rate runs alone on the host. The test measures no rate, so no part needs to run alone. The measure runs of `modustool screenshots` run after the test, one machine at a time ([full_check.md](full_check.md)).

## The chosen form

**One table, `test_parts` in `tools/modustool/machine/test_parts.odin`.** A row is a `Test_Part`: its name, the sentence of the guide, its procedure, the procedures whose volumes a host test checks, and its boot volumes. Everything else derives from the rows:

- The refusal of `test <word>` lists the names of the rows.
- `boot_volumes_of_test` gives the volumes of a row; the whole test builds every volume.
- The whole test is the list of the rows. Each part of the old chain has its row, also the ones that had none: `fails`, `self_tests`, `persist` and `host_modules` (the loader and the descriptions on the host). The test of the debug objects against the linked files left the parts: the linked files are no test inputs, so `check` runs it after its build.
- The table of the guide, [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The parts of the machine test", is checked line by line against `test_part_guide_row`: the name, the sentence and the short names of the boot volumes. A host test prints the line that it expected, so the guide follows the table.

**The run of a part, `Test_Part_Run`.** What the machines of one part share lives in one record, and each machine reaches it through its machine record (`Machine.part`): the data disk of the part, the values of the steps Remember, the texts of the steps Screen_Text, and the times of its machines and steps. A command that starts machines outside the test (`measure`, `film`) makes one run with its own name.

**The files of a machine are beside its log.** The picture of the screen that QEMU writes, the disk of the measures, the copy of the variable store of the firmware, the frames of QEMU user networking and the sockets of a software TPM each have the name of the log with a suffix (`machine_file`); the machine removes the disk, the picture and the store at its end. A host test reads the constants of the logs and of the disks of the parts and refuses two that name one file. `run` keeps the fixed names: it has no log file.

**The boot volume is shared, and read only.** Many parts boot the main volume, and two boot `secure_boot` and `other_system`, at the same time. QEMU takes a lock for writing on each image that it opens for writing, so the drive of the boot volume has `snapshot=on`: QEMU reads the volume with a shared lock, and keeps any write of the machine in a temporary file of its own. No process of the system writes its boot volume, and no part reads a write to it; `snapshot=on` and not `readonly=on`, because the firmware is not code of the system, and a write that it makes must not fail the start.

**The names of the pictures.** The pictures of all the parts go to one folder. A part that saves a name that another part of the run saved fails its step, with the name of the other part (`picture_name_claim`): two parts would leave the picture of whichever part ended last. A static check of the table cannot hold this: several scenarios are built by code. In the flake each part runs in a process of its own, so `test_join` holds the same rule when it joins their pictures, and refuses a log name that two parts wrote.

**A part on a given build.** `modustool test <part> from <folder>` runs one part on the test inputs of a folder and builds nothing: the command of a part derivation. It links each boot volume and boot image of the folder into `build/`, copies every other file, and notes the volumes of the part as ready, so a machine starts only from a volume that the folder holds. A volume of the part that the folder lacks is refused before the first machine. At its end it writes the count of its checks in `build/checks_passed.txt`, which `test_join` adds up.

**Some steps of a part.** `modustool test <part> steps <first> to <last>` runs the boot steps, the setup steps and a range of one machine of the part, then ends the part ([scenario_fault_loop.md](scenario_fault_loop.md), "A step range"). The range lives in the run of the part (`Test_Part_Run.step_range`), so the machines before the named one run whole and none after it starts.

**The ports of the loopback.** What is guaranteed, and what is not:

- The UDP port of the peer for the machine is never free: the peer binds it, connects it to its own port, and QEMU gets a copy of that socket at its start (`-netdev dgram,local.type=fd`). The copy is open in the tool only from the command of QEMU to its start; a host process that another thread starts in that time inherits it, holds the port of that machine until it ends, and never reads it.
- The software TPM alone of a part has Unix sockets in the folder of its output: no port.
- The port of hostfwd is the one port that QEMU binds itself: hostfwd takes no socket. `free_port` keeps the list of the ports that it gave, so two machines never get one port from it. Any other socket that binds port 0 between the close of the tool and the bind of QEMU (a socket of the tool on another thread, or another program of the host) can still take the number. QEMU then ends at its start; `machine_test` starts it again with a new port, at most `MACHINE_START_TRIES` times in all, and a QEMU that ends at each try fails the machine.

**The pool.** `test_parts_run` gives the rows to worker threads, one row at a time, in the order of the table. The table starts with the longest parts (the measured time of each part is in `build/test_times.txt`), so the last part to end starts early. After a failure no new part starts; the parts that run end, and the pool waits for them. The summary says "not started" for a part that no worker took, not "failed". The count of the parts at once (`test_parts_at_once`) is the smaller of two bounds, at least one, and never more than the parts:

- **By processors**: the processors that the test counts on (the processors of the host, or `NIX_BUILD_CORES` when the sandbox of Nix gives fewer), divided by `MACHINE_PROCESSOR_COUNT`, the `-smp` of each machine.
- **By memory**: `MemAvailable` of `/proc/meminfo` at the start, less `HOST_MEMORY_MARGIN_MIB` (4 GiB), divided by the memory of the largest part. A part holds one machine at a time, so its memory is `MACHINE_MEMORY_MIB`, the `-m` of each machine; a row with `starts_no_machine` holds none.

The reason of the bound by memory: one failed run of the full check ran about sixteen machines of 1 GiB at once on a host of 16 processors and 32 GB. The host swapped, a machine got no processor for two minutes, and its step failed at its bound with no fault of the system (below, the share of the host). The margin keeps the memory of QEMU beside its guest, the tool, Nix and the desktop of the developer. `MemAvailable` and not `MemFree`: the cache of the host's files is memory that the host gives back with no swap. One part runs even when it is larger than the memory: a part alone is the case that a developer runs, and a test with no part would prove nothing. A host with no readable `MemAvailable` has no bound by memory, and the line of the bound says so.

The pool is the path of `modustool test` on a host. The full check does not use it: Nix runs the part derivations at once, and `screenshots` gives Nix the same bound as its `max-jobs`.

**The share of the host.** At the start of each step Wait, the tool reads the counters of the host for the QEMU of the machine: utime plus stime of each of its threads (`/proc/<pid>/task/<tid>/stat`), run_delay of each (`schedstat`, the time that a thread was ready and waited for a processor), and the total of the line `full` of `/proc/pressure/memory` (the time in which every task of the host waited for memory). A wait that ends at its bound reads them again, and its failure line says the difference: "the host ran the machine for 400 ms of the 120.0 s of the wait; its threads waited 118000 ms in all for a processor; every task of the host waited for memory for 3000 ms". When the machine ran for at most a tenth of the wait, the line ends with the verdict: the host starved it when the wait for a processor and the memory stall make half of the wait or more, else the machine was idle, its processors halted on an event that did not come. When it ran for more, the line says that the machine had the processor. A counter that cannot be read, or that went backwards (a thread of QEMU ended between two reads, and the sum fell), is "unknown" with its reason, and the line gives no verdict that rests on it. The processors report also prints the run state of QEMU (`status` of `query-status`): a machine that QEMU stopped itself, on a write error of a disk for example, is not `running`.

**The times.** Each part keeps its own times. The report joins them in the order of the table, writes `build/test_times.txt` with the part of each machine, and prints the time of each part, the longest first, as a measure.

## Refused forms

- **The state in the machine record.** The values that a step Remember keeps are compared by the step Distinct of a later machine of the same part, and a later machine types the screen text that an earlier one read. The record of one machine cannot hold them; the record of the part can.
- **A thread-local current part.** It hides the dependence of a scenario procedure on its part. A parameter states it, and the compiler checks each call.
- **One process for each part in `modustool test`.** The tool would start itself again for each part, and the times, the count of the checks and the pictures would cross a process border. Threads share the build that the process made, and the temporary memory of Odin is already of each thread. The full check pays that border once, in `test_join`, because a derivation for each part is what lets Nix keep a part whose inputs did not change.
- **The longest part split into sections.** The main machine holds about a quarter of the machine time and bounds the whole test. Its scenario in named sections, each a machine, is the next step; it changes the scenario, not the engine.
- **A data disk shared by the parts.** The old whole test made one disk at its start, and each part wrote on the disk of the part before it. A part then saw data that it does not see when it runs alone.
- **No bound on the memory of the host.** This was the form before, with the reason that the bound by processors keeps the count of machines at a few. It held for `modustool test`, not for the check of the flake, where Nix ran up to its own `max-jobs` of part derivations: the host swapped and a step failed with no fault of the system.
- **A field of memory in each row.** QEMU reads one `-m` for every machine, `MACHINE_MEMORY_MIB`. A number in each row would be a second place of the same fact, which no QEMU reads; the row says only whether the part starts a machine.
- **The memory of each part, summed, in place of the largest part times the count.** The pool takes the parts in the order of the table, and a worker that ends a small part takes the next one, whatever its size: the bound must hold for any choice of parts at once.
- **The processor time alone as the proof of a starvation.** A system that waits for an event that never comes also uses almost no processor: its processors halt. The time that the threads of QEMU were ready and waited for a processor, and the memory stall of the host, separate the two.
- **A second picture of the registers after a delay, to see if the processors move.** It waits a fixed time, and a starved machine moves as little as an idle one.

## Subtle points

- `context.temp_allocator` is of each thread in Odin, so the rule "the tool frees it after each step" holds on each worker. The texts that a machine keeps past one step are in memory of their own, as before.
- The list of the given ports and the table of the names of the pictures outlive the caller that fills them first, so their memory is the heap of the process, never the allocator of a caller. Each procedure takes the list or the table as an argument; the machines pass the one of the process, and a host test passes its own. The test runner of Odin frees the allocator of a host test when the test ends and gives that memory to the next test: a list that took its memory from a test made a later port a write into the operation sequences of another test, which then differed for one seed.
- The list of the boot volumes that the build made is read by every part and changed by the part `trusted_boot` (the disk of the release image): a lock holds it. The cache of the interface font is read once under a lock.
- The lines of two parts that run at once are mixed on the terminal. Each line is whole. The end of the log of a machine that failed is one write, with the name of its log. The line of the end of each part names the part.
- The data disk of a part that failed stays in `build/`; the disks of the parts that passed are removed.
- `nix flake check` runs one part in each part derivation, and Nix runs the part derivations at once, bounded by its `max-jobs`.
- The times of a part derivation are those of that part alone: `test_join` keeps the file of the times of each part as `test_times_<part>.txt`, and no file holds the whole test.
- Parts at once load the host, so a compositor that starts takes its input later. Two faults of the tool that a part alone never showed then came out. The input service joined the moves of the pointer that found its ring full, so the push to the corner and the move to a button became one move, and the edge of the screen cut it to the corner: the place that the tool summed was wrong, and its press missed the menu. A step `Front` also opened the menu of the windows after the line of the surface and before the first picture, when the menu does not list the window yet. Both now wait for a fact of the compositor: the place of each press, and the line of the first picture of a window ([../../../docs/TOOLS.md](../../../docs/TOOLS.md), the rule of the pointer of a machine test).
- A panic of the tool on one worker ends the process; the QEMU of the other parts that run then stay as orphans until a kill.
- The bound by memory acts only where the tool starts the parts or Nix: `modustool test` and `screenshots`. A developer who runs `nix flake check` gives Nix its `max-jobs` by hand, and the default of Nix can be far above the bound.
- The verdict of the share of the host counts the memory stall of the whole host, not of one QEMU: a stall that hit other programs only still counts. A wait for a processor of a thread is of that QEMU alone. A thread of a processor that blocks on memory is not ready, so it is in the memory stall and not in run_delay.
- `schedstat` exists when the kernel of the host has the scheduler statistics (`CONFIG_SCHED_INFO`), which the kernels of the usual distributions have. Without it, the wait for a processor is unknown and the line gives no verdict.
- The clock ticks of `stat` are the `USER_HZ` of the Linux interface, 100 on x86-64, whatever the tick of the kernel of the host.

## State

Built: the table, the derived refusal, volumes and guide check, the run of a part, the files beside the log, the shared boot volume, the names of the pictures, the ports, the pool with its bound by processors and by memory, the share of the host in the line of a failed wait, the run state of QEMU in the processors report, the times of each part, a part on a given build, a step range of one machine of a part, and a derivation of the flake for each part.

Left: a way for `nix flake check` to take the bound by memory, which today only `modustool test` and `screenshots` apply; the main scenario in named sections, so that its sections run as parts at once; the host test folders of `modustool check` through the process pool of the build; a binary of the tool for each part, so that a change of the scenario of one part runs that part only ([full_check.md](full_check.md), "State").
