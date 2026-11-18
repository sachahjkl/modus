# The parts of the machine test

The machine test is a list of parts. A part is one or more machines that share a disk, a TPM state or a value from one machine to the next. Two parts share nothing. This file records why the parts are one table, and how several parts run at once.

## Purpose

- `modustool test <part>` runs one part alone, for the work on it, and builds only the boot volumes of that part.
- `modustool test` runs every part, several at once, and ends when the last part ends.
- A new part is one row. No other place of the tool or of the guide names the parts.

## Constraints

- A part that runs alone and the same part in the whole test must do the same work. So a part starts from a new data disk of its own, in both cases.
- A test never depends on the speed of the hardware ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). This is the rule that makes parallel parts admissible: a loaded host changes no result. A part that fails only when another part runs beside it is a fault of a wait of that part, read to its cause.
- The machines of one part run in their order: a later machine reads the disk, the TPM state, the remembered values or the screen text of the one before.
- A measure of a rate runs alone on the host. The test measures no rate, so no part needs to run alone. The measure runs of `modustool screenshots` run after the test, one machine at a time ([full_check.md](full_check.md)).

## The chosen form

**One table, `test_parts` in `tools/modustool/test_parts.odin`.** A row is a `Test_Part`: its name, the sentence of the guide, its procedure, the procedures whose volumes a host test checks, and its boot volumes. Everything else derives from the rows:

- The refusal of `test <word>` lists the names of the rows.
- `boot_volumes_of_test` gives the volumes of a row; the whole test builds every volume.
- The whole test is the list of the rows. Each part of the old chain has its row, also the ones that had none: `fails`, `self_tests`, `persist` and `host_modules` (the loader, the descriptions and the debug objects on the host).
- The table of the guide, [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The parts of the machine test", is checked line by line against `test_part_guide_row`: the name, the sentence and the short names of the boot volumes. A host test prints the line that it expected, so the guide follows the table.

**The run of a part, `Test_Part_Run`.** What the machines of one part share lives in one record, and each machine reaches it through its machine record (`Machine.part`): the data disk of the part, the values of the steps Remember, the texts of the steps Screen_Text, and the times of its machines and steps. A command that starts machines outside the test (`measure`, `film`) makes one run with its own name.

**The files of a machine are beside its log.** The picture of the screen that QEMU writes, the disk of the measures, the copy of the variable store of the firmware, the frames of QEMU user networking and the sockets of a software TPM each have the name of the log with a suffix (`machine_file`); the machine removes the disk, the picture and the store at its end. A host test reads the constants of the logs and of the disks of the parts and refuses two that name one file. `run` keeps the fixed names: it has no log file.

**The boot volume is shared, and read only.** Many parts boot the main volume, and two boot `secure_boot` and `other_system`, at the same time. QEMU takes a lock for writing on each image that it opens for writing, so the drive of the boot volume has `snapshot=on`: QEMU reads the volume with a shared lock, and keeps any write of the machine in a temporary file of its own. No process of the system writes its boot volume, and no part reads a write to it; `snapshot=on` and not `readonly=on`, because the firmware is not code of the system, and a write that it makes must not fail the start.

**The names of the pictures.** The pictures of all the parts go to one folder. A part that saves a name that another part of the run saved fails its step, with the name of the other part (`picture_name_claim`): two parts would leave the picture of whichever part ended last. A static check of the table cannot hold this: several scenarios are built by code.

**The ports of the loopback.** What is guaranteed, and what is not:

- The UDP port of the peer for the machine is never free: the peer binds it, connects it to its own port, and QEMU gets a copy of that socket at its start (`-netdev dgram,local.type=fd`). The copy is open in the tool only from the command of QEMU to its start; a process that another thread starts in that time inherits it, holds the port of that machine until it ends, and never reads it.
- The software TPM alone of a part has Unix sockets in the folder of its output: no port.
- The port of hostfwd is the one port that QEMU binds itself: hostfwd takes no socket. `free_port` keeps the list of the ports that it gave, so two machines never get one port from it. Any other socket that binds port 0 between the close of the tool and the bind of QEMU (a socket of the tool on another thread, or another program of the host) can still take the number. QEMU then ends at its start; `machine_test` starts it again with a new port, at most `MACHINE_START_TRIES` times in all, and a QEMU that ends at each try fails the machine.

**The pool.** `test_parts_run` gives the rows to worker threads, one row at a time, in the order of the table. The table starts with the longest parts (the measured time of each part is in `build/test_times.txt`), so the last part to end starts early. After a failure no new part starts; the parts that run end, and the pool waits for them. The summary says "not started" for a part that no worker took, not "failed". At most one part runs for each `MACHINE_PROCESSOR_COUNT` processors: the processors of the host, or `NIX_BUILD_CORES` when the sandbox of Nix gives fewer.

**The times.** Each part keeps its own times. The report joins them in the order of the table, writes `build/test_times.txt` with the part of each machine, and prints the time of each part, the longest first, as a measure.

## Refused forms

- **The state in the machine record.** The values that a step Remember keeps are compared by the step Distinct of a later machine of the same part, and a later machine types the screen text that an earlier one read. The record of one machine cannot hold them; the record of the part can.
- **A thread-local current part.** It hides the dependence of a scenario procedure on its part. A parameter states it, and the compiler checks each call.
- **One process for each part.** The tool would start itself again for each part, and the times, the count of the checks and the pictures would cross a process border. Threads share the build that the process made, and the temporary memory of Odin is already of each thread.
- **The longest part split into sections.** The main machine holds about a quarter of the machine time and bounds the whole test. Its scenario in named sections, each a machine, is the next step; it changes the scenario, not the engine.
- **A data disk shared by the parts.** The old whole test made one disk at its start, and each part wrote on the disk of the part before it. A part then saw data that it does not see when it runs alone.
- **A bound on the memory of the host.** Each machine has 1 GiB; the bound by processors keeps the count of machines at a few. A host with many processors and little memory is not a host of the test.

## Subtle points

- `context.temp_allocator` is of each thread in Odin, so the rule "the tool frees it after each step" holds on each worker. The texts that a machine keeps past one step are in memory of their own, as before.
- The list of the boot volumes that the build made is read by every part and changed by the part `trusted_boot` (the disk of the release image): a lock holds it. The cache of the interface font is read once under a lock.
- The lines of two parts that run at once are mixed on the terminal. Each line is whole. The end of the log of a machine that failed is one write, with the name of its log. The line of the end of each part names the part.
- The data disk of a part that failed stays in `build/`; the disks of the parts that passed are removed.
- `nix flake check` gives the sandbox the processors of the host, so the parts run at once there too, bounded by `NIX_BUILD_CORES`.
- Parts at once load the host, so a compositor that starts takes its input later. Two faults of the tool that a part alone never showed then came out. The input service joined the moves of the pointer that found its ring full, so the push to the corner and the move to a button became one move, and the edge of the screen cut it to the corner: the place that the tool summed was wrong, and its press missed the menu. A step `Front` also opened the menu of the windows after the line of the surface and before the first picture, when the menu does not list the window yet. Both now wait for a fact of the compositor: the place of each press, and the line of the first picture of a window ([../../../docs/TOOLS.md](../../../docs/TOOLS.md), the rule of the pointer of a machine test).
- A panic of the tool on one worker ends the process; the QEMU of the other parts that run then stay as orphans until a kill.

## State

Built: the table, the derived refusal, volumes and guide check, the run of a part, the files beside the log, the shared boot volume, the names of the pictures, the ports, the pool, the times of each part.

Left: the main scenario in named sections, so that its sections run as parts at once; the host test folders of `modustool check` through the process pool of the build.
