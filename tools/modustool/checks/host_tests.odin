package checks

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modustool:foundation"

// The host tests of `modustool check` (src/md/infrastructure/full_check.md,
// "The host tests at once"): the `odin test` of each folder of
// HOST_TEST_FOLDERS, each in its own process, several at once, in the
// pool of processes of the parallel build (parallel_build.odin). The pool
// starts at most one process for each processor that the check counts on
// (test_processors_of: the processors of the host, or NIX_BUILD_CORES in
// the sandbox). After a failure it starts no new process; the processes
// that run end.
//
// Each folder has its own log under HOST_TEST_OUTPUT_FOLDER. Each folder of
// the runtime also has its own private temporary folder for its compiler. The compiler names the object of an
// assembly file in its temporary folder by the name of the file and an
// address of its own memory, and the two folders of the runtime assemble
// two files of one name, `memory_for_host_tests.asm`: with one temporary
// folder for all, two compilers at once could write one object. The tests
// of the memory procedures link the object by its path: a library found
// through `-L/` is refused by the linker of the Nix sandbox.

HOST_TEST_OUTPUT_FOLDER :: foundation.BUILD_FOLDER + "/host_tests"

// The lines of the end of the log of a folder whose tests failed that the
// check prints: the summary of the test runner is there. The whole log
// stays in its file.
HOST_TEST_LOG_END_LINES :: 40

// host_test_name gives the name of the files of the host tests of a
// folder: its path with `_` in place of each `/`.
host_test_name :: proc(folder: string) -> string {
	name, _ := strings.replace_all(folder, "/", "_", context.temp_allocator)
	return name
}

// host_test_log_file gives the file that holds the output of the host
// tests of a folder.
host_test_log_file :: proc(folder: string) -> string {
	return foundation.join(HOST_TEST_OUTPUT_FOLDER, "/", host_test_name(folder), ".txt")
}

// host_test_command gives the command of the host tests of a folder, with
// temporary_folder (an absolute path) as the temporary folder of its
// compiler. The kernel parts go only to the folders that import them: a
// host test of the library that names one then fails to compile.
host_test_command :: proc(folder, temporary_folder: string) -> []string {
	command := make([dynamic]string, context.temp_allocator)
	if temporary_folder != "" {
		append(&command, "env", foundation.join("TMPDIR=", temporary_folder))
	}
	append(&command, "odin", "test", folder, "-vet", foundation.SOURCE_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG)
	if foundation.source_folder_takes_kernel_library(folder) {
		append(&command, foundation.KERNEL_LIBRARY_FLAG)
	}
	// A package of the tool imports another one through the source library
	// of the tool.
	if foundation.source_folder_is_of_the_tool(folder) {
		append(&command, foundation.TOOL_LIBRARY_FLAG)
	}
	append(&command, foundation.join("-out:", foundation.BUILD_FOLDER, "/test_", host_test_name(folder)))
	return command[:]
}

// host_test_names_first_repeat gives the first two folders of a list whose
// files have one name, or "": two such folders at once would write one
// log, one test program and one temporary folder.
host_test_names_first_repeat :: proc(folders: []string) -> string {
	for folder, place in folders {
		for other in folders[place + 1:] {
			if host_test_name(folder) == host_test_name(other) {
				return fmt.tprintf("the folders %s and %s have the one name %s", folder, other, host_test_name(folder))
			}
		}
	}
	return ""
}

// host_tests_at_once gives the count of the host test processes at once:
// one for each processor, no more than the folders, and at least one.
host_tests_at_once :: proc(folder_count, processors: int) -> int {
	return max(1, min(folder_count, processors))
}

// text_last_lines gives the last count lines of a text, with their ends of
// line. A text with fewer lines is given whole; a count of 0 or less gives
// nothing.
text_last_lines :: proc(text: string, count: int) -> string {
	if count <= 0 {
		return ""
	}
	// The end of line of the last line does not start another line.
	lines := strings.trim_suffix(text, "\n")
	found := 0
	for end := len(lines); end > 0; {
		start := strings.last_index_byte(lines[:end], '\n')
		if start < 0 {
			break
		}
		found += 1
		if found == count {
			return text[start + 1:]
		}
		end = start
	}
	return text
}

// host_tests_run runs the host tests of each folder, several at once, and
// writes the output of each one to its log. It prints the time of each
// folder as a measure, never as a condition, and the end of the log of
// each folder whose tests failed.
host_tests_run :: proc(folders: []string) -> bool {
	if repeat := host_test_names_first_repeat(folders); repeat != "" {
		fmt.eprintfln("modustool: the host tests: %s, so two processes at once would write one file", repeat)
		return false
	}
	// The logs of an earlier check are not the logs of this one.
	foundation.reset_folder(HOST_TEST_OUTPUT_FOLDER) or_return
	// A temporary folder of its own is a new private folder in the
	// temporary folder of the check.
	commands := make([][]string, len(folders), context.temp_allocator)
	temporary_folders := make([]string, len(folders), context.temp_allocator)
	defer for temporary_folder in temporary_folders {
		if temporary_folder != "" {
			_ = os.remove_all(temporary_folder)
		}
	}
	for folder, place in folders {
		// Only the folders of the runtime assemble the file of one name;
		// every other folder keeps the temporary folder of the check, so
		// the paths of its tests do not grow.
		if !strings.has_prefix(folder, foundation.SOURCE_FOLDER_RUNTIME) {
			commands[place] = host_test_command(folder, "")
			continue
		}
		temporary_folder, temporary_error := os.make_directory_temp("", "host_*", context.temp_allocator)
		if temporary_error != nil {
			fmt.eprintfln("modustool: cannot make a temporary folder for the host tests of %s: %v", folder, temporary_error)
			return false
		}
		temporary_folders[place] = temporary_folder
		commands[place] = host_test_command(folder, temporary_folder)
	}
	processors := foundation.test_processors_of(os.get_processor_core_count(), os.get_env("NIX_BUILD_CORES", context.temp_allocator))
	at_once := host_tests_at_once(len(folders), processors)
	fmt.printfln("modustool: the host tests of %d folders, at most %d at once: %d processors", len(folders), at_once, processors)
	started := time.tick_now()
	outcomes := foundation.build_host_processes_run(commands, at_once, context.temp_allocator)
	whole := time.tick_since(started)
	passed := true
	not_started := 0
	for folder, place in folders {
		outcome := outcomes[place]
		if !outcome.started {
			not_started += 1
			passed = false
			continue
		}
		log_file := host_test_log_file(folder)
		if write_error := os.write_entire_file(log_file, outcome.output); write_error != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", log_file, write_error)
			passed = false
		}
		seconds := time.duration_seconds(outcome.duration)
		if outcome.success {
			fmt.printfln("modustool: measure: the host tests of %s: %.1f s", folder, seconds)
		} else {
			passed = false
			fmt.eprintfln("modustool: the host tests of %s failed after %.1f s; the end of its log, whose whole is %s:", folder, seconds, log_file)
			end_of_log := text_last_lines(string(outcome.output), HOST_TEST_LOG_END_LINES)
			os.write(os.stderr, transmute([]u8)end_of_log)
			if !strings.has_suffix(end_of_log, "\n") {
				fmt.eprintln()
			}
		}
		delete(outcome.output)
	}
	if not_started > 0 {
		fmt.eprintfln("modustool: the host tests of %d folders did not start: the host tests of a folder failed", not_started)
	}
	fmt.printfln("modustool: measure: the host tests of %d folders: %.1f s on the clock, at most %d at once", len(folders), time.duration_seconds(whole), at_once)
	return passed
}

// The folders whose host tests `modustool check` runs: `odin test` on
// each, several at once (host_tests.odin). The pool starts them in this
// order, and reports them in it: the tool comes first, because its
// compile and its tests are the longest, and a long folder that starts
// last makes the whole run longer.
HOST_TEST_FOLDERS :: [?]string {
	foundation.TOOL_SOURCE_FOLDER + "/machine",
	foundation.TOOL_SOURCE_FOLDER,
	foundation.TOOL_SOURCE_FOLDER + "/site",
	foundation.TOOL_SOURCE_FOLDER + "/build",
	foundation.TOOL_SOURCE_FOLDER + "/checks",
	foundation.TOOL_SOURCE_FOLDER + "/fuzz",
	foundation.TOOL_SOURCE_FOLDER + "/resources",
	foundation.TOOL_SOURCE_FOLDER + "/similarity",
	foundation.TOOL_SOURCE_FOLDER + "/cache_server",
	foundation.TOOL_SOURCE_FOLDER + "/foundation",
	foundation.SOURCE_FOLDER_RUNTIME,
	foundation.SOURCE_FOLDER_CONTRACT + "/blake3",
	foundation.SOURCE_FOLDER_CONTRACT + "/module",
	foundation.SOURCE_FOLDER_CONTRACT + "/isolated",
	foundation.SOURCE_FOLDER_CONTRACT + "/pointer_pictures",
	foundation.SOURCE_FOLDER_CONTRACT + "/remote",
	foundation.SOURCE_FOLDER_CONTRACT + "/root_ring",
	foundation.SOURCE_FOLDER_CONTRACT + "/start_list",
	foundation.SOURCE_FOLDER_CONTRACT + "/boot_info",
	foundation.SOURCE_FOLDER_CONTRACT + "/enum_word",
	foundation.SOURCE_FOLDER_SUPPORT + "/sentence",
	foundation.SOURCE_FOLDER_SUPPORT + "/cryptography/vectors",
	foundation.SOURCE_FOLDER_PRIVATE + "/cryptography/cryptography_primitives",
	foundation.SOURCE_FOLDER_SUPPORT + "/quic",
	foundation.SOURCE_FOLDER_CONTRACT + "/date",
	foundation.SOURCE_FOLDER_CONTRACT + "/disk_process_page",
	foundation.SOURCE_FOLDER_KERNEL + "/iommu",
	foundation.SOURCE_FOLDER_CONTRACT + "/bridge_requester",
	foundation.SOURCE_FOLDER_KERNEL + "/debug_exception",
	foundation.SOURCE_FOLDER_KERNEL + "/processor_counters",
	foundation.SOURCE_FOLDER_KERNEL + "/stolen_time",
	foundation.SOURCE_FOLDER_KERNEL + "/time_base",
	foundation.SOURCE_FOLDER_KERNEL + "/delivery_count",
	foundation.SOURCE_FOLDER_PRIVATE + "/storage/storage_mount",
	foundation.SOURCE_FOLDER_PRIVATE + "/storage/storage_object",
	foundation.SOURCE_FOLDER_PRIVATE + "/storage/storage_tree",
	foundation.SOURCE_FOLDER_PRIVATE + "/storage/storage_retention",
	foundation.SOURCE_FOLDER_SUPPORT + "/principals",
	foundation.SOURCE_FOLDER_SUPPORT + "/tpm2",
	foundation.SOURCE_FOLDER_PRIVATE + "/boot_program/firmware_memory_map",
	foundation.SOURCE_FOLDER_PRIVATE + "/boot_program/rescue_entry",
	foundation.SOURCE_FOLDER_SUPPORT + "/disk_process",
	foundation.SOURCE_FOLDER_SUPPORT + "/calendar",
	foundation.SOURCE_FOLDER_SUPPORT + "/line_editor",
	foundation.SOURCE_FOLDER_PRIVATE + "/console/console_language",
	foundation.SOURCE_FOLDER_PRIVATE + "/debugger/debugging",
	foundation.LIBRARY_MODULE_SOURCES + "interface_module",
	foundation.LIBRARY_MODULE_SOURCES + "drawing",
	foundation.DEMONSTRATION_MODULE_SOURCES + "sample",
	foundation.SOURCE_FOLDER_SUPPORT + "/system",
	foundation.SOURCE_FOLDER_SUPPORT + "/twins",
	foundation.SOURCE_FOLDER_PRIVATE + "/kernel_events/kernel_events_rounds",
	foundation.SOURCE_FOLDER_CONTRACT + "/tpm_service",
	foundation.SOURCE_FOLDER_SUPPORT + "/storage",
	foundation.SOURCE_FOLDER_PRIVATE + "/compositor/bar",
	foundation.SOURCE_FOLDER_PRIVATE + "/compositor/palette",
	foundation.SOURCE_FOLDER_PRIVATE + "/compositor/clipboard",
	foundation.SOURCE_FOLDER_PRIVATE + "/compositor/quality",
	foundation.SOURCE_FOLDER_CONTRACT + "/palette_table",
	foundation.SOURCE_FOLDER_SUPPORT + "/bootscreen",
	foundation.SOURCE_FOLDER_SUPPORT + "/bootscreen/image_card",
	foundation.SOURCE_FOLDER_SUPPORT + "/graphics",
	foundation.SOURCE_FOLDER_SUPPORT + "/interface",
	foundation.SOURCE_FOLDER_PRIVATE + "/inspect/addresses",
	foundation.SOURCE_FOLDER_PRIVATE + "/manual/information",
	foundation.SOURCE_FOLDER_SUPPORT + "/vector_font",
	foundation.SOURCE_FOLDER_SUPPORT + "/network",
	foundation.SOURCE_FOLDER_SUPPORT + "/tcp",
	foundation.SOURCE_FOLDER_SUPPORT + "/virtio",
	foundation.SOURCE_FOLDER_SUPPORT + "/bochs_display",
	foundation.SOURCE_FOLDER_SUPPORT + "/web",
	foundation.SOURCE_FOLDER_SUPPORT + "/cryptography/chacha20",
	foundation.SOURCE_FOLDER_SUPPORT + "/random",
	foundation.SOURCE_FOLDER_SUPPORT + "/trigonometry",
	foundation.SOURCE_FOLDER_CONTRACT + "/entropy_service",
	foundation.SOURCE_FOLDER_CONTRACT + "/fixed_addresses",
	foundation.SOURCE_FOLDER_CONTRACT + "/settings",
	foundation.LIBRARY_MODULE_SOURCES + "text_rendering",
	foundation.SOURCE_FOLDER_SUPPORT + "/text_rendering",
	foundation.SOURCE_FOLDER_SUPPORT + "/mark",
	foundation.SOURCE_FOLDER_SUPPORT + "/terminal",
	foundation.SOURCE_FOLDER_CONTRACT + "/cut_mark",
	foundation.SOURCE_FOLDER_CONTRACT + "/reference_screen",
	foundation.SOURCE_FOLDER_CONTRACT + "/scale_factor",
	foundation.SOURCE_FOLDER_CONTRACT + "/text_encoding",
	foundation.SOURCE_FOLDER_RUNTIME + "/without_vector_registers",
	foundation.SOURCE_FOLDER_SUPPORT + "/instruction_sets",
	foundation.SOURCE_FOLDER_CONTRACT + "/system_description",
	foundation.SOURCE_FOLDER_CONTRACT + "/replacement_list",
	foundation.SOURCE_FOLDER_PRIVATE + "/root/replacement_signature",
	foundation.SOURCE_FOLDER_PRIVATE + "/root/start_policy_rules",
	foundation.SOURCE_FOLDER_PRIVATE + "/start_policy/wiring_rows",
	foundation.SOURCE_FOLDER_CONTRACT + "/operation",
	foundation.SOURCE_FOLDER_CONTRACT + "/operation_sequence",
	foundation.SOURCE_FOLDER_CONTRACT + "/debug_object",
	foundation.SOURCE_FOLDER_CONTRACT + "/value_kinds",
	foundation.SOURCE_FOLDER_PRIVATE + "/manual/source_comment_markdown",
	foundation.SOURCE_FOLDER_PRIVATE + "/console/console_results",
	foundation.SOURCE_FOLDER_PRIVATE + "/console/console_condition",
	foundation.SOURCE_FOLDER_PRIVATE + "/console/lex_parser",
	foundation.SOURCE_FOLDER_PRIVATE + "/console/lex_evaluator",
	foundation.SOURCE_FOLDER_PRIVATE + "/console/console_stream",
	foundation.SOURCE_FOLDER_SUPPORT + "/key_path",
	foundation.SOURCE_FOLDER_SUPPORT + "/kind_icons",
	foundation.SOURCE_FOLDER_CONTRACT + "/manual_pages",
	foundation.SOURCE_FOLDER_PRIVATE + "/manual/manual_navigation",
	foundation.SOURCE_FOLDER_PRIVATE + "/edit/text_model",
	foundation.SOURCE_FOLDER_PRIVATE + "/monitor/sample_history",
	foundation.SOURCE_FOLDER_CONTRACT + "/ring",
	foundation.SOURCE_FOLDER_CONTRACT + "/font_characters",
	foundation.SOURCE_FOLDER_CONTRACT + "/datagram",
	foundation.SOURCE_FOLDER_CONTRACT + "/byte_order",
	foundation.SOURCE_FOLDER_CONTRACT + "/timed_stream",
	foundation.SOURCE_FOLDER_CONTRACT + "/output",
	foundation.SOURCE_FOLDER_CONTRACT + "/object_cache",
	foundation.SOURCE_FOLDER_PRIVATE + "/sound/sound_device",
	foundation.SOURCE_FOLDER_KERNEL + "/acpi_processors",
}
