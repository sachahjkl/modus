package machine

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "modustool:foundation"
import "modustool:build"
import "modustool:checks"

// The parts of the machine test (src/md/infrastructure/machine_test_parts.md).
// One table holds each part: `test <part>` finds its row, the whole test
// runs every row, the build reads the boot volumes of a row, and a host test
// checks the table of docs/TOOLS.md, "The parts of the machine test",
// against it.

// One part of the machine test.
Test_Part :: struct {
	name:              string,
	does:              string, // The cell of the table of the guide: what the part checks.
	run:               proc(part: ^Test_Part_Run) -> bool,
	// Each procedure of the tool that starts a machine of the part, or that
	// reads what the build of its volumes gives: a host test checks that each
	// volume that one of them names is in volumes (boot_volumes_test.odin).
	procedures:        []string,
	volumes:           []string, // The paths of the boot volumes that its machines boot: `test <part>` builds these only.
	self_test_volumes: bool, // The volumes of the self tests of the kernel too, one for each row of self_tests.
}

// What one run of a part keeps across its machines. Two parts that run at
// the same time share none of it: each machine of a part reaches it through
// its machine record. A command that starts machines outside the test
// (`measure`, `film`) has one too, with the name of the command.
Test_Part_Run :: struct {
	name:               string,
	data_disk:          string, // The data disk of the machines of the part, new at its start.
	remembered_values:  [dynamic]string, // The values that the steps Remember kept: the step Distinct compares them.
	screen_text_kept:   string, // The text that the last step Screen_Text read: a later machine of the part types it.
	screen_text_before: string, // The text that the step Screen_Text before the last one read.
	times:              Test_Times,
	started:            bool, // A worker took the part: after a failure, the parts that no worker took did not start.
	passed:             bool,
	duration:           time.Duration, // A measure: from the start of its first machine to the end of its last one.
}

// The rows are in the order of the start of the whole test: the longest
// parts first, so that the last part to end starts early. The time of each
// part is in build/test_times.txt.
test_parts := [?]Test_Part {
	{name = "main", does = "The main machine: the desktop, the console, the processes and the developer tools", run = main_tests_run, procedures = {"main_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "tcp", does = "The two machines of TCP", run = tcp_tests_run, procedures = {"tcp_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "random", does = "The three machines of the randomness: the first has the entropy device (`virtio-rng-pci`), the other two have none", run = random_tests_run, procedures = {"random_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "quic", does = "The machine of QUIC through the network service", run = quic_tests_run, procedures = {"quic_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "network", does = "The machine of the network service, then a machine with no network device, which refuses the processes with an endpoint and runs the rest", run = network_tests_run, procedures = {"network_tests_run", "no_network_device_run"}, volumes = {build.BOOT_VOLUME}},
	// The machines of the keys sealed by the TPM too: the signed main
	// volume, whose build writes the variable store of Secure Boot, and the
	// other system, signed.
	{
		name = "principals",
		does = "The two machines of the principals, then the ten machines of the keys sealed by the TPM, with a software TPM whose state they share: nine with Secure Boot on, on the volumes `secure_boot` and `other_system`, and one with Secure Boot off, where the seal is refused (`PRINCIPALS.md`, \"8. The tests\")",
		run = principals_tests_run,
		procedures = {"principals_tests_run", "principals_tpm_tests_run", "principals_tpm_principal_tests_run", "principals_tpm_machine_passphrase_tests_run", "principal_change_with_a_dropped_zero_run", "tpm_key_machine_run"},
		volumes = {build.BOOT_VOLUME, build.BOOT_VOLUME_SECURE_BOOT, build.BOOT_VOLUME_OTHER_SYSTEM},
	},
	{
		name = "disk_processes",
		does = "The six machines of the disk processes: a module that the boot image does not hold starts from the store `module_files`, gets the store of its nickname, and finds its data after a restart; the module file service stores the same file from the network and lists the hash of the bytes of each file; a process calls a library module that the root service found in the store by the hash of its bytes, and is refused when the file of the library has other bytes; with the machine passphrase, its grant survives the restart, and a table that another key signed gives no grant and is not written over; a grant and a client key of `remote` that a console of the session of the named principal alice gives survive the restart and her unlock (\"The disk of the disk processes\")",
		run = disk_processes_tests_run,
		procedures = {"disk_processes_tests_run", "disk_processes_named_principal_tests_run"},
		volumes = {build.BOOT_VOLUME},
	},
	// The machines of a part that the machine lacks.
	{
		name = "missing_devices",
		does = "The three machines of a part that the machine lacks, each with its line and a later step that works: a machine with no display device (`-vga none`) starts no compositor and no console, and the boot pass of `settings` through the storage service, then `unlock`, run; a machine with no PS/2 controller (`i8042=off`) stops the input service and shows the desktop; an entropy device whose source never answers (`rng-egd` with no client) passes the deadline of its reads, which count as refused",
		run = missing_devices_tests_run,
		procedures = {"missing_devices_tests_run", "missing_devices_silent_entropy_run"},
		volumes = {build.BOOT_VOLUME},
	},
	// The two machines of the measure boot the main volume and the other
	// system.
	{
		name = "trusted_boot",
		does = "The volumes of the trusted boot: the five refusals of the boot program, a kernel that asks more memory than the machine has, whose stop stays on the boot display, the two machines of the measure with a software TPM, and the three machines of Secure Boot; then the release image: the volume of Secure Boot packaged as the files of a release, verified, decompressed and started from its GPT disk; then the six machines of the TPM floors, with one software TPM: a newer system raises the floors, swtpm alone plants an index with an authorization value and a foreign index, which the next start removes, the older system and the older key are then refused, and with Secure Boot off each floor is foreign",
		run = trusted_boot_tests_run,
		procedures = {"trusted_boot_tests_run", "release_image_machine_run", "floor_tests_run"},
		volumes = {build.BOOT_VOLUME, build.BOOT_VOLUME_CHANGED_MODULE, build.BOOT_VOLUME_WRONG_SIGNATURE, build.BOOT_VOLUME_OTHER_SYSTEM, build.BOOT_VOLUME_CHANGED_KERNEL, build.BOOT_VOLUME_WITHOUT_DESCRIPTION, build.BOOT_VOLUME_STATED_HASH, build.BOOT_VOLUME_KERNEL_MEMORY_RAISED, build.BOOT_VOLUME_SECURE_BOOT, build.BOOT_VOLUME_SECURE_BOOT_CHANGED, build.BOOT_VOLUME_NEWER_SYSTEM, build.BOOT_VOLUME_NEWER_KEY},
	},
	{name = "hierarchy", does = "The machines of the hierarchy of storage", run = hierarchy_tests_run, procedures = {"hierarchy_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "power", does = "The loss of power: of the storage, of the settings, of the ranges, the write that the disk drops, and the disk that stops to answer", run = power_tests_run, procedures = {"power_tests_run", "power_loss_run", "power_loss_sequence", "power_loss_settings_run", "power_loss_ranges_run", "dropped_write_run", "silent_disk_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "persist", does = "The eight machines of the persistence of the storage on one disk, which the tool cuts and damages between two machines", run = persistence_run, procedures = {"persistence_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "extended_state", does = "The three machines of the extended state", run = extended_state_tests_run, procedures = {"extended_state_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "return_fault", does = "The machine of the return to a process", run = return_fault_tests_run, procedures = {"return_fault_tests_run"}, volumes = {build.BOOT_VOLUME, build.BOOT_VOLUME_WITHOUT_RETURN_CHECK}},
	{
		name = "kernel_events",
		does = "The machine of the kernel events, then the thread counters on the same machine: `counters` counts a loop of 1 000 000 turns (at least one instruction retired for each turn, the one count that the test checks) and the same reads of 2 MiB in order and by page, as measures. After the machine, the tool reads the last boot line \"kernel: performance counters\" of the test machine; a line with counters must say that the first processor passed the trial of the registers. When the kernel found no counters, or a processor refused their trial, it checks only that the commands gave `Unsupported`, and it writes what the host gives as the explanation (`ARCHITECTURE.md`, \"The counters of a thread\")",
		run = kernel_events_tests_run,
		procedures = {"kernel_events_tests_run"},
		volumes = {build.BOOT_VOLUME},
	},
	{name = "self_tests", does = "The machines of the self tests of the kernel: each one does one thing that the processor must refuse, from its own boot volume", run = self_tests_run, procedures = {"self_tests_run"}, self_test_volumes = true},
	{name = "debugger", does = "The two machines of the debugger: the contract of the kernel, then the commands of the service `debugger`", run = debugger_tests_run, procedures = {"debugger_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "ranges", does = "The machines of the ranges of storage", run = ranges_tests_run, procedures = {"ranges_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "quic-real", does = "The QUIC client of OpenSSL against `quic_echo`, through the UDP relay of the peer", run = quic_real_tests_run, procedures = {"quic_real_tests_run"}, volumes = {build.BOOT_VOLUME}},
	// No machine starts: the part needs the built modules, which the build
	// of a volume gives.
	{name = "outside_module", does = "No machine: the build of the examples of a module outside the sources, as a developer types it", run = outside_module_tests_run, procedures = {"outside_module_tests_run", "outside_module_examples_check"}, volumes = {build.BOOT_VOLUME}},
	{name = "host_modules", does = "No machine: the loader, the descriptions of the exports and the debug objects of the build, on the host", run = host_modules_tests_run, procedures = {"host_modules_tests_run", "test_modules", "test_descriptions", "test_debug_objects"}, volumes = {build.BOOT_VOLUME}},
	{
		name = "iommu_amd",
		does = "The machine with the IOMMU of AMD with interrupt remapping (`amd-iommu,dma-remap=on,intremap=on`, `kernel-irqchip=split`), with the disk of the measures and an entropy device behind a conventional bridge (`i82801b11-bridge`) at the place 28 of bus 0: the system with translation and interrupt remapping on, then the test device service `iommu_device` on that disk, which also holds the registers of the entropy device, so the kernel gives both one domain of the requester of the bridge; its message interrupt arrives through the interrupt table of that requester, and its device does not reach a page that it did not declare, with the line of the DMA fault from the event log; QEMU records no event for a refused message, so no line of a refused interrupt is waited for; without the registers of the entropy device, its declaration is refused, with the line of the kernel, and a read of the disk into a page that it declared before does not end: the tool stops the machine (which ends each read that QEMU took), gives the disk a new size with `block_resize` and starts it again, and the service then finds its page as it was and no interrupt of the device, the configuration interrupt of the new size too; then `net` through a device window",
		run = iommu_amd_tests_run,
		procedures = {"iommu_amd_tests_run"},
		volumes = {build.BOOT_VOLUME},
	},
	{
		name = "iommu",
		does = "The machine with the IOMMU of Intel with interrupt remapping (`intel-iommu,intremap=on`, `kernel-irqchip=split`), with the disk of the measures behind a root port of PCI Express and the entropy device: the system with translation and interrupt remapping on, the two reads of the entropy device through the unit, then the test device service `iommu_device` on that disk, whose message interrupt arrives through its entry, whose messages to entries that it was not given are refused with a line, and whose device does not reach a page that it did not declare, then `net`, whose datagram region the network device reads through a device window (`ARCHITECTURE.md`, \"K5. Device grant and interrupts\")",
		run = iommu_tests_run,
		procedures = {"iommu_tests_run"},
		volumes = {build.BOOT_VOLUME},
	},
	{name = "fault_ring", does = "The machine of the fault ring", run = fault_ring_tests_run, procedures = {"fault_ring_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "sound", does = "The machine of sound, with a virtio sound device (`virtio-sound-pci`) whose output goes to a wave file: `tone` plays a tone of 440 Hz at 500 ms after the frame 0 of its stream and checks eight refusals of the sound service, a second `tone` is refused, and the tool finds the tone in the file by its start, with the crossings of zero of 440 Hz and its 24 000 frames, and checks its place against the frame that `tone` names (`SOUND.md`, \"4. The test\")", run = sound_tests_run, procedures = {"sound_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "crypto", does = "The machine of the module `cryptography`", run = cryptography_tests_run, procedures = {"cryptography_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{
		name = "guest",
		does = "The machine of a guest: `guest_demo` runs seven bytes of 16-bit code in a guest, receives its port write of 42 to the port 0x80 as an exit record, sees its `hlt`, and gets its `int1` as an exit `Other` with the exit code 0x88 (icebp). The tool reads the host first: on a host that gives the test machine no SVM, the machine checks only that `Guest_Run` gives `Unsupported`, and the tool writes that no guest ran, and why (`ARCHITECTURE.md`, \"A guest\")",
		run = guest_tests_run,
		procedures = {"guest_tests_run"},
		volumes = {build.BOOT_VOLUME},
	},
	{name = "no_pit", does = "The machine with no time base: no 8254 (`-machine q35,pit=off`) and a processor whose CPUID states no frequency of its cycle counter; the kernel writes its line and stops with the code 1", run = no_pit_tests_run, procedures = {"no_pit_tests_run"}, volumes = {build.BOOT_VOLUME}},
	{name = "fails", does = "The machine of a start that fails: a boot image with no start policy, so the rescue start policy is absent too, and the boot display shows the cause", run = fails_tests_run, procedures = {"fails_tests_run"}, volumes = {build.BOOT_VOLUME_FAILS}},
	{
		name = "start_policy",
		does = "The eight machines of the start policy (`ARCHITECTURE.md`, \"The start policy\"): the key R on the serial line, the console input of the firmware with no screen; a start list whose row of the console names a module that does not exist, so the rescue takes over; three machines with one variable store: the boot program writes the boot entry `modus (rescue)`, `BootNext` to that entry starts the rescue, and the entry with a word that names no start request stops the boot program; then three machines with a software TPM and Secure Boot on: principal 0 chooses a start policy from the disk, the next start runs it and PCR 12 holds its hash, and a chosen start policy that fails gives way to the rescue, with PCR 12 after two extends",
		run = start_policy_tests_run,
		procedures = {"start_policy_tests_run", "start_policy_boot_entry_tests_run", "start_policy_from_disk_tests_run"},
		volumes = {build.BOOT_VOLUME, build.BOOT_VOLUME_MISSING_CONSOLE, build.BOOT_VOLUME_SECURE_BOOT},
	},
	{name = "shortage", does = "The machine of the shortage of frames", run = shortage_tests_run, procedures = {"shortage_tests_run"}, volumes = {build.BOOT_VOLUME_SHORTAGE}},
	{name = "operation_sequences", does = "The machine of the operation sequences, with the kernel that ships and one processor: the tool writes the seed sequences in the mailbox of `operation_fuzzing` through the memory file of the machine, and checks each answer against the statuses of the reference, the forms of the operations and the budget of the sequence (\"The operation sequences\")", run = operation_sequences_tests_run, procedures = {"operation_sequences_tests_run"}, volumes = {build.BOOT_VOLUME_OPERATION_SEQUENCES}},
}

// test_part_find gives the row of a part by its name.
test_part_find :: proc(name: string) -> (part: ^Test_Part, found: bool) {
	for &row in test_parts {
		if row.name == name {
			return &row, true
		}
	}
	return nil, false
}

// test_part_names gives the names of the parts, in the order of the table,
// separated by ", ".
test_part_names :: proc() -> string {
	names := make([]string, len(test_parts), context.temp_allocator)
	for row, index in test_parts {
		names[index] = row.name
	}
	return strings.join(names, ", ", context.temp_allocator)
}

// test_arguments_problem gives the refusal of the arguments of `test`, or
// "" when they name the whole test or one part. A word that is not a part
// is refused: the whole test in its place takes minutes and passes, and the
// reader believes that the part passed.
test_arguments_problem :: proc(args: []string) -> string {
	if len(args) == 0 {
		return ""
	}
	if len(args) == 1 {
		if _, found := test_part_find(args[0]); found {
			return ""
		}
	}
	given := strings.join(args, " ", context.temp_allocator)
	return fmt.tprintf("test does not know the part `%s`; the parts: %s; with no argument, the whole test", given, test_part_names())
}

// test_part_volumes_of gives the paths of the boot volumes of one part, in
// the temporary memory: the paths of the self test volumes are made there.
test_part_volumes_of :: proc(part: Test_Part) -> []string {
	volumes := make([dynamic]string, context.temp_allocator)
	append(&volumes, ..part.volumes)
	if part.self_test_volumes {
		for test in build.self_tests {
			append(&volumes, fmt.tprintf(build.BOOT_VOLUME_SELF_TEST, test.number))
		}
	}
	return volumes[:]
}

// boot_volumes_of_test gives the volumes that `test` with these arguments
// boots: those of the row of its part. nil is every volume: the whole test,
// and a name that is no part (test_arguments_problem refuses it first).
boot_volumes_of_test :: proc(args: []string) -> []string {
	if len(args) == 0 {
		return nil
	}
	part, found := test_part_find(args[0])
	if !found {
		return nil
	}
	return test_part_volumes_of(part^)
}

// test_part_guide_row gives the line of the table of the guide for a part:
// its name, what it checks, and the short names of its boot volumes. The
// host test compares the guide with these lines, and prints the line that
// it expected.
test_part_guide_row :: proc(part: Test_Part) -> string {
	volume_names := make([dynamic]string, context.temp_allocator)
	for path in test_part_volumes_of(part) {
		append(&volume_names, fmt.tprintf("`%s`", build.boot_volume_name(path)))
	}
	return fmt.tprintf("| `%s` | %s | %s |", part.name, part.does, strings.join(volume_names[:], ", ", context.temp_allocator))
}

// test_part_run_make makes the run of one part, or of a command that starts
// machines outside the test. Its texts are in memory of its own: a scenario
// frees the temporary memory after each step.
test_part_run_make :: proc(name: string) -> Test_Part_Run {
	return {name = strings.clone(name), data_disk = fmt.aprintf("%s/test_data_disk_%s.img", foundation.BUILD_FOLDER, name)}
}

// test_part_run_start makes the new data disk of the part: a part starts
// from no data that another part wrote, as it does when it runs alone.
test_part_run_start :: proc(part: ^Test_Part_Run) -> bool {
	return disk_prepare(part.data_disk, build.DATA_DISK_SIZE, true)
}

test_part_run_free :: proc(part: ^Test_Part_Run) {
	remembered_values_forget(part)
	delete(part.remembered_values)
	screen_text_forget(part)
	test_times_free(&part.times)
	// The disk of a part that failed stays for the reader of the failure;
	// the disks of the parts that passed would fill the build folder.
	if part.passed {
		_ = os.remove(part.data_disk)
	}
	delete(part.data_disk)
	delete(part.name)
	part^ = {}
}

// remembered_values_forget forgets the values that the steps Remember of a
// part kept.
remembered_values_forget :: proc(part: ^Test_Part_Run) {
	for value in part.remembered_values {
		delete(value)
	}
	clear(&part.remembered_values)
}

// The processors of each test machine: the -smp of machine_command. The
// whole test starts at most one part for each MACHINE_PROCESSOR_COUNT
// processors of the host, so that each machine can have its processors.
// A part runs its machines one after the other.
test_parts_at_once :: proc(part_count: int, processors: int) -> int {
	return max(1, min(part_count, processors / MACHINE_PROCESSOR_COUNT))
}

// The pictures that the parts of this run saved, by name, with the part of
// each: all go to one folder, so two parts that save one name would leave
// the picture of whichever part ended last. The table outlives the caller
// that claims first, so its map and its names are memory of the heap of
// the process, never of the allocator of a caller: the allocator of a host
// test is freed when the test ends.
Picture_Names :: struct {
	lock:  sync.Mutex,
	parts: map[string]string, // The name of a picture -> the name of its part.
}

// The table of the process, which the machines use. A host test gives its
// own table.
picture_names: Picture_Names

// picture_name_claim takes a name of a picture for a part. It refuses a
// name that another part of the run took, and gives that part; the same
// part can save one name again (a later picture replaces the earlier one).
picture_name_claim :: proc(names: ^Picture_Names, part: string, picture: string) -> (owner: string, ok: bool) {
	sync.mutex_lock(&names.lock)
	defer sync.mutex_unlock(&names.lock)
	if owner_part, taken := names.parts[picture]; taken {
		return owner_part, owner_part == part
	}
	if names.parts == nil {
		names.parts = make(map[string]string, runtime.heap_allocator())
	}
	names.parts[strings.clone(picture, runtime.heap_allocator())] = strings.clone(part, runtime.heap_allocator())
	return part, true
}

// picture_names_forget forgets the names of an earlier run.
picture_names_forget :: proc(names: ^Picture_Names) {
	sync.mutex_lock(&names.lock)
	defer sync.mutex_unlock(&names.lock)
	for picture, part in names.parts {
		delete(picture, runtime.heap_allocator())
		delete(part, runtime.heap_allocator())
	}
	clear(&names.parts)
}

// picture_names_free frees a table that a host test gave.
picture_names_free :: proc(names: ^Picture_Names) {
	picture_names_forget(names)
	sync.mutex_lock(&names.lock)
	defer sync.mutex_unlock(&names.lock)
	delete(names.parts)
	names.parts = nil
}

// The parts that the worker threads of the whole test share.
Test_Parts_Pool :: struct {
	parts:  []Test_Part,
	runs:   []Test_Part_Run, // By place in parts.
	start:  proc(part: ^Test_Part_Run) -> bool, // What a part needs before its first machine.
	next:   int, // The next place in parts to take (atomic).
	failed: bool, // A part failed: no new part starts (atomic).
}

// test_parts_run runs each part of a list, at most `at_once` at the same
// time, each on a worker thread of its own. After a failure no new part
// starts; the parts that run end. It prints the time of each part as a
// measure. start prepares a part before its first machine: its new data
// disk. The caller frees the runs, which have the order of the parts.
test_parts_run :: proc(parts: []Test_Part, at_once: int, start: proc(part: ^Test_Part_Run) -> bool = test_part_run_start) -> (runs: []Test_Part_Run, passed: bool) {
	pool := Test_Parts_Pool {
		parts = parts,
		runs  = make([]Test_Part_Run, len(parts)),
		start = start,
	}
	for part, place in parts {
		pool.runs[place] = test_part_run_make(part.name)
	}
	if at_once <= 1 {
		test_parts_worker(&pool)
	} else {
		workers := make([]^thread.Thread, min(at_once, len(parts)), context.temp_allocator)
		for &worker in workers {
			worker = thread.create_and_start_with_data(&pool, test_parts_worker_of_thread)
		}
		thread.join_multiple(..workers)
		for worker in workers {
			thread.destroy(worker)
		}
	}
	passed = !sync.atomic_load(&pool.failed)
	for part_run in pool.runs {
		passed = passed && part_run.passed
	}
	return pool.runs, passed
}

@(private = "file")
test_parts_worker_of_thread :: proc(data: rawptr) {
	test_parts_worker((^Test_Parts_Pool)(data))
}

// test_parts_worker takes the parts of a pool one at a time and runs each.
@(private = "file")
test_parts_worker :: proc(pool: ^Test_Parts_Pool) {
	for {
		place := sync.atomic_add(&pool.next, 1)
		if place >= len(pool.parts) || sync.atomic_load(&pool.failed) {
			return
		}
		part := pool.parts[place]
		part_run := &pool.runs[place]
		part_run.started = true
		started := time.tick_now()
		part_run.passed = pool.start(part_run) && part.run(part_run)
		part_run.duration = time.tick_since(started)
		free_all(context.temp_allocator)
		fmt.printfln("modustool: measure: the part %s %s, %d machines, %.1f s", part.name, part_run.passed ? "passed" : "failed", len(part_run.times.machines), time.duration_seconds(part_run.duration))
		if !part_run.passed {
			sync.atomic_store(&pool.failed, true)
		}
	}
}

// The procedures of the parts whose machines no other file runs.

main_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario[:], {volume = build.BOOT_VOLUME, output = checks.TEST_OUTPUT, exit_status = build.MACHINE_STOP_OK})
}

network_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_network[:], {volume = build.BOOT_VOLUME, output = checks.TEST_OUTPUT_NETWORK, exit_status = build.MACHINE_STOP_OK}) && no_network_device_run(part)
}

shortage_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_shortage[:], {volume = build.BOOT_VOLUME_SHORTAGE, output = TEST_OUTPUT_SHORTAGE, exit_status = build.MACHINE_STOP_OK})
}

// A start that fails ends when the tool ends QEMU: status 0.
fails_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_fails[:], {volume = build.BOOT_VOLUME_FAILS, output = TEST_OUTPUT_FAILS, exit_status = 0})
}

power_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return power_loss_run(part) && power_loss_settings_run(part) && power_loss_ranges_run(part) && dropped_write_run(part) && silent_disk_run(part)
}

outside_module_tests_run :: proc(_: ^Test_Part_Run) -> bool {
	return build.outside_module_examples_check()
}

host_modules_tests_run :: proc(_: ^Test_Part_Run) -> bool {
	return build.test_modules() && build.test_descriptions() && test_debug_objects()
}
