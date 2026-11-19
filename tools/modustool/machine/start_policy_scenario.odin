package machine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import info "modus:contract/boot_info"
import "modustool:build"
import "modustool:foundation"

// The machines of the rescue start policy (src/md/features/start_policy.md):
//
// 1. the key R, written on the serial line, the console input of the
//    firmware with no screen, until the boot program reads it: the root service
//    starts the rescue start policy in place of the default one, and the
//    rescue makes the machine usable with its console, whose table of the
//    processes is the picture rescue;
// 2. a start list with a row of `shortage`, which this image does not hold,
//    refused with no stop of the machine, and a row of the console that
//    names a module that does not exist: the default start policy stops
//    before Machine_Usable, the root
//    service stops what it asked for, and the rescue takes over, with its
//    line;
// 3. to 5. three machines with one variable store of the firmware: the
//    boot program writes the boot entry "modus (rescue)" in a store that
//    has none; the tool sets BootNext to it with virt-fw-vars, and the next
//    start is the rescue, with no key; the tool then writes the word of the
//    entry to one past the last start request, and the boot program stops
//    with its cause on the boot display.

TEST_OUTPUT_START_POLICY_KEY :: foundation.BUILD_FOLDER + "/test_output_start_policy_key.txt"
TEST_OUTPUT_START_POLICY_MISSING_CONSOLE :: foundation.BUILD_FOLDER + "/test_output_start_policy_missing_console.txt"
TEST_OUTPUT_START_POLICY_ENTRY :: foundation.BUILD_FOLDER + "/test_output_start_policy_entry.txt"
TEST_OUTPUT_START_POLICY_BOOT_NEXT :: foundation.BUILD_FOLDER + "/test_output_start_policy_boot_next.txt"
TEST_OUTPUT_START_POLICY_WRONG_WORD :: foundation.BUILD_FOLDER + "/test_output_start_policy_wrong_word.txt"
// The variable store that the three machines of the boot entry share.
START_POLICY_VARIABLES :: foundation.BUILD_FOLDER + "/start_policy_ovmf_vars.fd"
START_POLICY_VARIABLES_JSON :: foundation.BUILD_FOLDER + "/start_policy_ovmf_vars.json"

// The line of the boot program that the key R gives.
RESCUE_KEY_LINE :: "boot program: the key R is held: the root service starts the rescue start policy"
// The start of the line of the boot program that writes the entry: four
// hexadecimal digits of its number follow.
RESCUE_ENTRY_WRITTEN_LINE :: "boot program: the boot entry modus (rescue) is written as Boot"
// The end of the line of the root service when the rescue makes the
// machine usable.
RESCUE_USABLE_TEXT :: " of the list rescue_list: the budget of this service holds "

@(rodata)
scenario_start_policy_key := [?]Step {
	{kind = .Key_Until, text = "r", expected = RESCUE_KEY_LINE},
	{kind = .Wait, text = RESCUE_KEY_LINE},
	{kind = .Wait, text = "root: the key R was held at the start: the rescue start policy starts in place of the start policy "},
	{kind = .Wait, text = "start_policy: the start list has 4 rows: each starts in its order"},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "start_policy: each needed row runs: the machine is usable", any_order = true},
	// The root service writes its line when it takes Machine_Usable, before or
	// after the line of the start policy: two processes, no fixed order.
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	{kind = .Wait, text = RESCUE_USABLE_TEXT},
	// The console of the rescue looks as the console of each start: the
	// table of the processes is what shows the short rescue list. The
	// call starts monitor on demand, so the table holds its row too, and
	// the picture waits for that row.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "processes()"},
	{kind = .Wait, text = "[console] slot  name"},
	{kind = .Wait, text = "monitor  "},
	{kind = .Shot, text = "rescue"},
	{kind = .Quit},
}

@(rodata)
scenario_start_policy_missing_console := [?]Step {
	{kind = .Wait, text = "start_policy: the start list has 5 rows: each starts in its order"},
	// shortage is not in this image: the root service refuses it before its
	// procedure, which would stop the machine, and the machine runs on.
	{kind = .Wait, text = "start_policy: cannot start shortage: status ", fails_on = "kernel: the machine stops with code"},
	{kind = .Wait, text = "start_policy: cannot start console_missing: status ", fails_on = "kernel: the machine stops with code"},
	{kind = .Wait, text = "start_policy: the machine is not usable without console_missing: the start policy stops before Machine_Usable"},
	{kind = .Wait, text = " stopped before the machine was usable, with the code "},
	{kind = .Wait, text = ": the rescue start policy starts"},
	{kind = .Wait, text = "start_policy: the start list has 4 rows: each starts in its order"},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// The root service writes its line when it takes Machine_Usable, before or
	// after the line of the start policy: two processes, no fixed order.
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	{kind = .Wait, text = RESCUE_USABLE_TEXT},
	{kind = .Quit},
}

@(rodata)
scenario_start_policy_entry := [?]Step {
	{kind = .Wait, text = RESCUE_ENTRY_WRITTEN_LINE},
	// The root service writes its line when it takes Machine_Usable, before or
	// after the line of the start policy: two processes, no fixed order.
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	{kind = .Wait, text = " of the list start_list: the budget of this service holds "},
	{kind = .Quit},
}

@(rodata)
scenario_start_policy_boot_next := [?]Step {
	{kind = .Wait, text = "boot program: the load options of the boot entry ask for the rescue start policy", fails_on = RESCUE_ENTRY_WRITTEN_LINE},
	{kind = .Wait, text = "root: the boot entry modus (rescue) started the machine: the rescue start policy starts in place of the start policy "},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// The root service writes its line when it takes Machine_Usable, before or
	// after the line of the start policy: two processes, no fixed order.
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	// The entry is there: the boot program writes no second one.
	{kind = .Wait, text = RESCUE_USABLE_TEXT, fails_on = RESCUE_ENTRY_WRITTEN_LINE},
	{kind = .Quit},
}

// The word of the entry of the last machine: one past the last start
// request.
RESCUE_ENTRY_WRONG_WORD :: u32(max(info.Start_Request)) + 1

start_policy_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	// The key R on the serial line: the console input of the firmware of a
	// machine with no screen (-display none).
	machine_test(part, scenario_start_policy_key[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_START_POLICY_KEY, exit_status = 0, serial_input = true}) or_return
	machine_test(part, scenario_start_policy_missing_console[:], {volume = build.BOOT_VOLUME_MISSING_CONSOLE, output = TEST_OUTPUT_START_POLICY_MISSING_CONSOLE, exit_status = 0}) or_return
	start_policy_boot_entry_tests_run(part) or_return
	return start_policy_from_disk_tests_run(part)
}

// start_policy_boot_entry_tests_run runs the three machines of the boot
// entry on one variable store, new at its start.
start_policy_boot_entry_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	_ = os.remove(START_POLICY_VARIABLES)
	machine_test(part, scenario_start_policy_entry[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_START_POLICY_ENTRY, exit_status = 0, firmware_variables = START_POLICY_VARIABLES}) or_return
	number, found := rescue_entry_number(TEST_OUTPUT_START_POLICY_ENTRY)
	if !found {
		fmt.eprintfln("modustool: test failed: the log %s has no number after \"%s\"", TEST_OUTPUT_START_POLICY_ENTRY, RESCUE_ENTRY_WRITTEN_LINE)
		return false
	}
	rescue_entry_last_in_the_order(number) or_return
	// A machine test frees the temporary memory after each step: the texts
	// that outlive a machine are in memory of their own.
	boot_next := fmt.aprintf("%02x%02x", number & 0xFF, number >> 8)
	defer delete(boot_next)
	firmware_variables_set([][2]string{{"BootNext", boot_next}}) or_return
	machine_test(part, scenario_start_policy_boot_next[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_START_POLICY_BOOT_NEXT, exit_status = 0, firmware_variables = START_POLICY_VARIABLES}) or_return
	// The entry with a word that names no start request: the boot program
	// is the one writer of the entry, so the tool changes the word of the
	// entry that it wrote.
	entry_name := fmt.tprintf("Boot%04X", number)
	entry, entry_found := firmware_variable_read(entry_name)
	if !entry_found || len(entry) < 8 {
		fmt.eprintfln("modustool: test failed: the variable store has no entry %s", entry_name)
		return false
	}
	word := RESCUE_ENTRY_WRONG_WORD
	changed := fmt.tprintf("%s%02x%02x%02x%02x", entry[:len(entry) - 8], word & 0xFF, word >> 8 & 0xFF, word >> 16 & 0xFF, word >> 24)
	firmware_variables_set([][2]string{{entry_name, changed}, {"BootNext", boot_next}}) or_return
	refusal_line := fmt.aprintf("boot program: the load options hold the tag %s with the word %d, which names no start request", info.LOAD_OPTIONS_TAG, word)
	defer delete(refusal_line)
	wrong_word := [?]Step {
		{kind = .Wait, text = refusal_line},
		{kind = .Wait, text = "boot program: the boot display shows the failure"},
		{kind = .Quit},
	}
	return machine_test(part, wrong_word[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_START_POLICY_WRONG_WORD, exit_status = 0, firmware_variables = START_POLICY_VARIABLES})
}

// rescue_entry_last_in_the_order checks the BootOrder that the first
// machine left: the rescue entry is its last entry, and is there once, so
// the firmware starts it only when the entries before it fail.
rescue_entry_last_in_the_order :: proc(number: u16) -> bool {
	order, found := firmware_variable_read("BootOrder")
	if !found || len(order) == 0 || len(order) % 4 != 0 {
		fmt.eprintfln("modustool: test failed: the variable store has no BootOrder of whole entries: %q", order)
		return false
	}
	count := 0
	last: u16
	for place := 0; place < len(order); place += 4 {
		low, low_ok := strconv.parse_u64_of_base(order[place:][:2], 16)
		high, high_ok := strconv.parse_u64_of_base(order[place + 2:][:2], 16)
		if !low_ok || !high_ok {
			fmt.eprintfln("modustool: test failed: BootOrder %q is not hexadecimal", order)
			return false
		}
		last = u16(low | high << 8)
		if last == number {
			count += 1
		}
	}
	if count != 1 || last != number {
		fmt.eprintfln("modustool: test failed: BootOrder %q holds the rescue entry Boot%04X %d times, and its last entry is Boot%04X", order, number, count, last)
		return false
	}
	foundation.test_passed_print("BootOrder ends with the rescue entry Boot%04X, once", number)
	return true
}

// run_within_the_hang_bound runs a host program, and ends it at the hang
// bound: a program that hangs must not hold the test.
run_within_the_hang_bound :: proc(command: []string) -> bool {
	host_process, start_error := os.process_start({command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_error)
		return false
	}
	state, wait_error := os.process_wait(host_process, foundation.HANG_BOUND)
	if wait_error != nil || !state.exited {
		_ = os.process_kill(host_process)
		_, _ = os.process_wait(host_process)
		fmt.eprintfln("modustool: test failed: %s did not end within %v", command[0], foundation.HANG_BOUND)
		return false
	}
	if !state.success {
		fmt.eprintfln("modustool: test failed: %s failed (code %d)", command[0], state.exit_code)
		return false
	}
	return true
}

// rescue_entry_number reads the number of the entry from the line of the
// boot program in a log.
rescue_entry_number :: proc(output: string) -> (number: u16, found: bool) {
	text, readable := foundation.read_text_file(output)
	if !readable {
		return 0, false
	}
	at := strings.index(text, RESCUE_ENTRY_WRITTEN_LINE)
	if at < 0 || len(text) < at + len(RESCUE_ENTRY_WRITTEN_LINE) + 4 {
		return 0, false
	}
	digits := text[at + len(RESCUE_ENTRY_WRITTEN_LINE):][:4]
	value, parsed := strconv.parse_u64_of_base(digits, 16)
	if !parsed || value > u64(max(u16)) {
		return 0, false
	}
	return u16(value), true
}

// The variable store as virt-fw-vars reads and writes it in JSON.
Firmware_Variables_Json :: struct {
	version:   int,
	variables: []Firmware_Variable_Json,
}
Firmware_Variable_Json :: struct {
	name: string,
	guid: string,
	attr: int,
	data: string, // The bytes, in hexadecimal.
}

// The vendor of the boot variables (EFI_GLOBAL_VARIABLE).
GLOBAL_VARIABLE_GUID_TEXT :: "8be4df61-93ca-11d2-aa0d-00e098032b8c"
// The attributes of a boot variable: non-volatile, and read before and
// after the end of the services of the firmware.
BOOT_VARIABLE_ATTRIBUTES :: 7
// The version of the JSON of virt-fw-vars.
FIRMWARE_VARIABLES_JSON_VERSION :: 2

// firmware_variables_set writes boot variables, each a name and its bytes
// in hexadecimal, into the shared store, with virt-fw-vars, as the build
// enrols the certificate of the firmware signing key.
firmware_variables_set :: proc(variables: [][2]string) -> bool {
	list := make([]Firmware_Variable_Json, len(variables), context.temp_allocator)
	for variable, index in variables {
		list[index] = {name = variable[0], guid = GLOBAL_VARIABLE_GUID_TEXT, attr = BOOT_VARIABLE_ATTRIBUTES, data = variable[1]}
	}
	encoded, marshal_error := json.marshal(Firmware_Variables_Json{version = FIRMWARE_VARIABLES_JSON_VERSION, variables = list}, allocator = context.temp_allocator)
	if marshal_error != nil {
		fmt.eprintfln("modustool: cannot write the variables %v in JSON: %v", variables, marshal_error)
		return false
	}
	if err := os.write_entire_file(START_POLICY_VARIABLES_JSON, encoded); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", START_POLICY_VARIABLES_JSON, err)
		return false
	}
	written := foundation.join(START_POLICY_VARIABLES, ".new")
	run_within_the_hang_bound({"virt-fw-vars", "--input", START_POLICY_VARIABLES, "--output", written, "--set-json", START_POLICY_VARIABLES_JSON}) or_return
	if err := foundation.file_move(written, START_POLICY_VARIABLES); err != nil {
		fmt.eprintfln("modustool: cannot move %s: %v", written, err)
		return false
	}
	return true
}

// firmware_variable_read gives the bytes, in hexadecimal, of one boot
// variable of the shared store.
firmware_variable_read :: proc(name: string) -> (data: string, found: bool) {
	run_within_the_hang_bound({"virt-fw-vars", "--input", START_POLICY_VARIABLES, "--output-json", START_POLICY_VARIABLES_JSON}) or_return
	text := foundation.read_file(START_POLICY_VARIABLES_JSON) or_return
	store: Firmware_Variables_Json
	if json.unmarshal(text, &store, allocator = context.temp_allocator) != nil {
		fmt.eprintfln("modustool: %s is not the JSON of a variable store", START_POLICY_VARIABLES_JSON)
		return "", false
	}
	for variable in store.variables {
		if variable.name == name && strings.to_lower(variable.guid, context.temp_allocator) == GLOBAL_VARIABLE_GUID_TEXT {
			return variable.data, true
		}
	}
	return "", false
}
