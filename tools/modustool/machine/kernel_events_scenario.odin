package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"
import "modustool:build"

// Kernel events (docs/ARCHITECTURE.md, "Kernel events"): one machine. The
// process kernel_events gives event tables to the kernel and reads the
// rings: a copy of the machine handle with no right is refused, and so is a
// seventeenth rule; 1000 operations of one child are 1000 records, and 100
// with "one in 10"; a thread that sleeps 20 times has at least 20 switches;
// a child that faults once has one record of a fault that stopped it; a
// full ring of 16 records counts each lost record; a table taken away
// writes no more records; the address of a fault is 0 for a rule for every
// process and given for a rule that names the child; 1000 gives and ends of
// a table under a load on each processor leave a pattern whole after each
// end. The cost of an entry in four rounds (no rule, a rule that names
// another process, a rule for every process that matches nothing, a rule
// that accepts each operation), with records + lost that agree with the
// count of the loop of the child, is a line of the log, for the
// coordinator.
//
// Then the two ends of a table that the process does not ask for. The tool
// stops kernel_events while its table is given: the kernel ends the table
// with its owner; the second run of kernel_events gives its first table
// with Ok (a table that the kernel had kept, of another process now, would
// be refused). In the second run, the scenario revokes the grant machine in
// the console: the table ends with the right, no record comes after, and
// Events_Set is refused.
//
// Then the thread counters on the same machine (scenario_thread_counters),
// which the tool chooses from what the host gives the test machine.

TEST_OUTPUT_KERNEL_EVENTS :: foundation.BUILD_FOLDER + "/test_output_kernel_events.txt"

@(rodata)
scenario_kernel_events := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"kernel_events\")"},
	{kind = .Wait, text = "kernel_events: no grant: Events_Set with a copy of the machine handle with no right gave Grant_Or_Right_Missing: as it must"},
	{kind = .Wait, text = "kernel: process kernel_events gave the event table: 16 rules, 8192 records in the ring of each of "},
	{kind = .Wait, text = "kernel_events: a seventeenth rule: 16 rules Succeeded, 17 rules Argument_Refused: as it must"},
	{kind = .Wait, text = "kernel_events: 1000 operations Memory_Size of one process: 1000 records, 0 lost: as it must"},
	{kind = .Wait, text = "kernel_events: a thread that sleeps 20 times: "},
	{kind = .Wait, text = "kernel_events: a child that faults once: 1 record of a fault that stopped it, vector 14, address 0000000000001000, stopped: a fault: as it must"},
	{kind = .Wait, text = "kernel_events: one in 10: 100 records of 1000 operations: as it must"},
	{kind = .Wait, text = "kernel_events: a full ring of 16 records: "},
	{kind = .Wait, text = "kernel_events: the table taken away: 0 records after it; a second take gave Wrong_State: as it must"},
	{kind = .Wait, text = "kernel_events: the address of a fault: a rule for every process: "},
	{kind = .Wait, text = "kernel_events: 1000 gives and ends under load: 1000 ends with "},
	{kind = .Wait, text = "kernel_events: kernel entries in one second of the load child (its own count and time): no rule "},
	{kind = .Wait, text = "kernel_events: kernel entries in one second of the load child (its own count and time): a rule that names another process "},
	{kind = .Wait, text = "kernel_events: kernel entries in one second of the load child (its own count and time): a rule for every process that matches nothing "},
	{kind = .Wait, text = "kernel_events: kernel entries in one second of the load child (its own count and time): a rule that accepts each of its operations "},
	{kind = .Wait, text = "kernel_events: in 200 ms while this process sleeps, every process: "},
	// A later stop by a holder keeps the first stop cause.
	{kind = .Wait, text = "kernel_events: the child that faults, stopped again by this process: its stop cause stays a fault: as it must"},
	{kind = .Wait, text = "kernel_events: the table is given; waiting for the revocation of the grant machine"},
	// The end of the table with its owner.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"kernel_events\")"},
	{kind = .Wait, text = "kernel: the event table of process kernel_events ended: its process stopped; "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"kernel_events\")"},
	{kind = .Wait, text = "kernel_events: a seventeenth rule: 16 rules Succeeded, 17 rules Argument_Refused: as it must"},
	{kind = .Wait, text = "kernel_events: the table is given; waiting for the revocation of the grant machine"},
	// The end of the table with its right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "revoke(\"kernel_events\", \"machine\")"},
	{kind = .Wait, text = "kernel: the event table of process kernel_events ended: its right Events ended; ", any_order = true},
	{kind = .Wait, text = "root: revoked the grant machine of kernel_events, holdings ended: 1", any_order = true},
	{kind = .Wait, text = "kernel_events: the right revoked: 1000 records of 1000 before it; 0 records after it; Events_Set after it gave Argument_Refused: as it must"},
	{kind = .Wait, text = "kernel_events: ok, 12 cases: each count of the rings was exact, each refusal came, and each child gave back every page and every thread"},
	{kind = .Front, text = "kernel_events"},
	{kind = .Shot, text = "kernel_events"},
}

// The thread counters (docs/ARCHITECTURE.md, "The counters of a thread"),
// on the same machine: the program counters counts a loop of known length,
// and the same reads of memory in two orders. A count is never a condition
// of the test but one: the loop retires at least one instruction for each
// turn. The four counts are measures on the log.
//
// The machine runs the process to its end with either outcome. After the
// machine, the tool reads the last boot line "kernel: performance counters"
// of that machine, which says what the kernel found and whether its
// registers passed their trial, and checks the lines of that outcome
// (thread_counters_outcome_check). The host is read only to
// explain an outcome: QEMU can fall back to TCG, and a hypervisor below
// the host can hide its counters, so the host does not decide.
@(rodata)
scenario_thread_counters := [?]Step {
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"counters\")"},
	{kind = .Wait, text = "counters: Start_Counters with a copy of the machine handle with no right gave Grant_Or_Right_Missing: as it must", fails_on = "counters: failed: "},
	{kind = .Wait, text = "counters: ok", fails_on = "counters: failed: "},
}

// The boot line of the kernel that names its counter plan, the part of it
// that says that the machine has none, and the part that says that the
// first processor passed the trial of its registers
// (src/modulus/thread_counters.odin). A processor whose trial fails writes a
// later line with the same start: the last one decides.
THREAD_COUNTERS_BOOT_LINE :: "kernel: performance counters"
THREAD_COUNTERS_NONE :: ": none that the kernel uses: "
THREAD_COUNTERS_TRIAL_PASSED :: "; the first processor passed the trial of the registers"

// The lines of the program counters on a machine with a counter plan, in
// their order.
@(rodata)
thread_counters_lines_counted := [?]string {
	"counters: Read_Counters before Start_Counters gave Wrong_State: as it must",
	" instructions: as it must",
	"counters: the loop (a measure): ",
	"counters: a second read gave no count below the first: as it must",
	" pages, in order and by page, read the same words: as it must",
	"counters: the reads in order (a measure): ",
	"counters: the reads by page (a measure): ",
	"counters: Stop_Counters with no handle gave Succeeded, and Read_Counters after it gave Wrong_State: as it must",
}

// The lines on a machine with no counter plan.
@(rodata)
thread_counters_lines_unsupported := [?]string {
	"counters: Read_Counters and Start_Counters gave Operation_Unsupported with the error kind Unsupported: the processors of this machine have no counters that the kernel uses: as it must",
}

// thread_counters_outcome_check reads the log of the machine: the last boot
// line of the counter plan decides the outcome, and each line of that
// outcome must come, in its order. A plan needs the trial of the first
// processor in its line. It gives the outcome for the message of the tool,
// and the first line that did not come.
thread_counters_outcome_check :: proc(log: string) -> (counted: bool, missing: string, ok: bool) {
	boot_at := strings.last_index(log, THREAD_COUNTERS_BOOT_LINE)
	if boot_at < 0 {
		return false, THREAD_COUNTERS_BOOT_LINE, false
	}
	boot_line := log[boot_at:]
	if end := strings.index_byte(boot_line, '\n'); end >= 0 {
		boot_line = boot_line[:end]
	}
	counted = !strings.contains(boot_line, THREAD_COUNTERS_NONE)
	if counted && !strings.contains(boot_line, THREAD_COUNTERS_TRIAL_PASSED) {
		return counted, THREAD_COUNTERS_TRIAL_PASSED, false
	}
	lines := counted ? thread_counters_lines_counted[:] : thread_counters_lines_unsupported[:]
	rest := log[boot_at:]
	for line in lines {
		at := strings.index(rest, line)
		if at < 0 {
			return counted, line, false
		}
		rest = rest[at + len(line):]
	}
	return counted, "", true
}

@(rodata)
scenario_kernel_events_end := [?]Step {
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// host_gives_thread_counters says if the test machine of this host can
// have the counters that the kernel uses, and why: an explanation of the
// outcome that the kernel reports, never the outcome. QEMU with TCG gives a machine no
// performance counters. KVM gives the counters of the host processor when
// its module has enable_pmu: the core counter extension on AMD
// (perfctr_core), the architectural monitoring on Intel (arch_perfmon).
host_gives_thread_counters :: proc() -> (gives: bool, reason: string) {
	if !os.exists("/dev/kvm") {
		return false, "QEMU emulates the processor (no KVM), and its emulation has no performance counters"
	}
	bytes, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	if err != nil {
		return false, "the tool cannot read /proc/cpuinfo"
	}
	text := string(bytes)
	counters_flag := false
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "flags") {
			continue
		}
		flags := line
		for flag in strings.fields_iterator(&flags) {
			counters_flag = counters_flag || flag == "perfctr_core" || flag == "arch_perfmon"
		}
		break
	}
	if !counters_flag {
		return false, "the host processor has neither the core counter extension of AMD (perfctr_core) nor the architectural monitoring of Intel (arch_perfmon)"
	}
	enabled, enabled_err := os.read_entire_file("/sys/module/kvm/parameters/enable_pmu", context.temp_allocator)
	if enabled_err != nil {
		// The build sandbox of Nix hides /sys: the boot line of the kernel
		// shows what the test machine gets.
		if !os.exists("/sys/module") {
			return true, "KVM, in a sandbox that hides /sys: the kernel reads the counters of the test machine"
		}
		return false, "the host has no module kvm with the parameter enable_pmu (/sys/module/kvm/parameters/enable_pmu)"
	}
	value := strings.trim_space(string(enabled))
	if value != "1" && value != "Y" {
		return false, "the module kvm of the host has enable_pmu off"
	}
	return true, "KVM with enable_pmu, on a host processor with the counters that the kernel uses"
}

kernel_events_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	// The heap, not the temporary allocator: the tool frees that one after
	// each step of the machine test.
	steps := make([dynamic]Step, 0, len(scenario_kernel_events) + len(scenario_thread_counters) + len(scenario_kernel_events_end))
	defer delete(steps)
	append(&steps, ..scenario_kernel_events[:])
	append(&steps, ..scenario_thread_counters[:])
	append(&steps, ..scenario_kernel_events_end[:])
	if !machine_test(part, steps[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_KERNEL_EVENTS, exit_status = build.MACHINE_STOP_OK}) {
		return false
	}
	// The lines of the process counters are facts: the check reads their
	// sentences, which the module files of the build render.
	log, rendered := log_file_rendered(TEST_OUTPUT_KERNEL_EVENTS)
	if !rendered {
		return false
	}
	counted, missing, ok := thread_counters_outcome_check(log)
	gives, reason := host_gives_thread_counters()
	if !ok {
		fmt.eprintfln("modustool: the thread counters: the line \"%s\" did not come (the kernel %s; the host: %s)", missing, counted ? "found its counters" : "found no counters", reason)
		return false
	}
	if counted {
		fmt.printfln("modustool: the part kernel_events counted with the thread counters (the host: %s)", reason)
	} else {
		fmt.printfln("modustool: the part kernel_events counted NOTHING with the thread counters: the kernel of the test machine found no counters, and the machine checked only that the commands give Unsupported (the host: %s%s)", reason, gives ? "; the host has counters, so QEMU or a hypervisor below it did not give them" : "")
	}
	return true
}

// A binary of the tool runs the test part kernel_events only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
kernel_events_test_part_register :: proc "contextless" () {
	test_part_scenario_register("kernel_events", kernel_events_tests_run)
}
