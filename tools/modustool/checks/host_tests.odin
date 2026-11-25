package checks

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
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
	// Source packages keep ODIN_TEST_THREADS=1 so process-global caches
	// (such as the glyph cache single-drawer guard) never race; heavy pure
	// tool packages (build, site, machine, checks) run multi-threaded so
	// they do not bottleneck the parallel pool tail (measured: site 116s -> 32s,
	// build 159s -> 103s).
	threads_flag := "-define:ODIN_TEST_THREADS=1"
	if folder == foundation.TOOL_SOURCE_FOLDER + "/build" ||
	   folder == foundation.TOOL_SOURCE_FOLDER + "/site" ||
	   folder == foundation.TOOL_SOURCE_FOLDER + "/machine" ||
	   folder == foundation.TOOL_SOURCE_FOLDER + "/checks" {
		threads_flag = "-define:ODIN_TEST_THREADS=8"
	}
	append(&command, "odin", "test", folder, "-vet", threads_flag, foundation.SOURCE_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG)
	if foundation.source_folder_takes_internal_library(folder) {
		append(&command, foundation.INTERNAL_LIBRARY_FLAG)
	}
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

// host_test_passed_count extracts the number of passed tests from an `odin test`
// output summary line ("Finished N test(s) in ... All tests were successful.").
// Returns 0 when the log does not confirm that all tests succeeded.
host_test_passed_count :: proc(output: string) -> int {
	rest := output
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "Finished ") || !strings.has_suffix(trimmed, "All tests were successful.") {
			continue
		}
		after := trimmed[len("Finished "):]
		space := strings.index_byte(after, ' ')
		if space <= 0 {
			continue
		}
		count, ok := strconv.parse_int(after[:space])
		if !ok || count <= 0 {
			continue
		}
		return count
	}
	return 0
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
	host_tests_passed := 0
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
			folder_passed := host_test_passed_count(string(outcome.output))
			host_tests_passed += folder_passed
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
	if passed && host_tests_passed > 0 {
		sync.atomic_add(&foundation.test_passed_count, host_tests_passed)
	}
	fmt.printfln("modustool: measure: the host tests of %d folders (%d tests): %.1f s on the clock, at most %d at once", len(folders), host_tests_passed, time.duration_seconds(whole), at_once)
	return passed
}

// host_test_folders_for_scope returns the folders of HOST_TEST_FOLDERS that
// belong to scope, preserving heaviest-first order.
host_test_folders_for_scope :: proc(scope: Host_Tests_Scope, allocator := context.temp_allocator) -> []string {
	all := HOST_TEST_FOLDERS
	selected := make([dynamic]string, allocator)
	for folder in all {
		is_tool := foundation.source_folder_is_of_the_tool(folder)
		switch scope {
		case .All:
			append(&selected, folder)
		case .System:
			if !is_tool {
				append(&selected, folder)
			}
		case .Tool:
			if is_tool {
				append(&selected, folder)
			}
		}
	}
	return selected[:]
}

// The heaviest folders of HOST_TEST_FOLDERS, from the longest: a compile
// of the tool and the tests that run the longest. They lead the list.
HOST_TEST_HEAVIEST_FOLDERS :: [?]string {
	foundation.TOOL_SOURCE_FOLDER + "/site",
	foundation.TOOL_SOURCE_FOLDER + "/build",
	foundation.TOOL_SOURCE_FOLDER + "/checks",
	foundation.TOOL_SOURCE_FOLDER + "/resources",
	foundation.TOOL_SOURCE_FOLDER + "/machine",
}

// The folders whose host tests `modustool check` runs: `odin test` on
// each, several at once (host_tests.odin). The pool starts them in this
// order, and reports them in it. The longest folder starts first (the
// longest processing time first): a long folder that starts last runs
// alone at the end and makes the whole run longer, while the many short
// folders fill the processors around the long ones.
HOST_TEST_FOLDERS :: [?]string {
	foundation.TOOL_SOURCE_FOLDER + "/site",
	foundation.TOOL_SOURCE_FOLDER + "/build",
	foundation.TOOL_SOURCE_FOLDER + "/checks",
	foundation.TOOL_SOURCE_FOLDER + "/resources",
	foundation.TOOL_SOURCE_FOLDER + "/machine",
	foundation.TOOL_SOURCE_FOLDER,
	foundation.TOOL_SOURCE_FOLDER + "/fuzz",
	foundation.TOOL_SOURCE_FOLDER + "/similarity",
	foundation.TOOL_SOURCE_FOLDER + "/cache_server",
	foundation.TOOL_SOURCE_FOLDER + "/agent_bridge",
	foundation.TOOL_SOURCE_FOLDER + "/agent_runner",
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
	foundation.SOURCE_FOLDER_PUBLIC + "/sentence",
	foundation.SOURCE_FOLDER_PUBLIC + "/cryptography/vectors",
	foundation.SOURCE_FOLDER_PUBLIC + "/cryptography_primitives",
	foundation.SOURCE_FOLDER_PUBLIC + "/quic",
	foundation.SOURCE_FOLDER_CONTRACT + "/date",
	foundation.SOURCE_FOLDER_CONTRACT + "/disk_process_page",
	foundation.SOURCE_FOLDER_KERNEL + "/iommu",
	foundation.SOURCE_FOLDER_CONTRACT + "/bridge_requester",
	foundation.SOURCE_FOLDER_KERNEL + "/debug_exception",
	foundation.SOURCE_FOLDER_KERNEL + "/processor_counters",
	foundation.SOURCE_FOLDER_KERNEL + "/extended_switch",
	foundation.SOURCE_FOLDER_KERNEL + "/guest_rules",
	foundation.SOURCE_FOLDER_KERNEL + "/page_attributes",
	foundation.SOURCE_FOLDER_KERNEL + "/stolen_time",
	foundation.SOURCE_FOLDER_KERNEL + "/time_base",
	foundation.SOURCE_FOLDER_KERNEL + "/delivery_count",
	foundation.SOURCE_FOLDER_KERNEL + "/slot_set",
	foundation.SOURCE_FOLDER_KERNEL + "/table_sizes",
	foundation.SOURCE_FOLDER_KERNEL + "/mapping_order",
	foundation.SOURCE_FOLDER_KERNEL + "/weighted_average",
	foundation.SOURCE_FOLDER_KERNEL + "/word_table",
	foundation.SOURCE_FOLDER_KERNEL + "/replay_filter",
	foundation.SOURCE_FOLDER_KERNEL + "/software_exit",
	foundation.SOURCE_FOLDER_KERNEL + "/process_memory",
	foundation.SOURCE_FOLDER_KERNEL + "/virtual_interrupt_controller",
	foundation.SOURCE_FOLDER_CONTRACT + "/input_history",
	foundation.SOURCE_FOLDER_INTERNAL + "/compositor/capture_filter",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/session_budgets",
	foundation.SOURCE_FOLDER_INTERNAL + "/network/dhcp_client",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/storage_mount",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/storage_object",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/storage_tree",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/storage_retention",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/share_quota",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/store_encryption",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/store_reclaim",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/principal_keys",
	foundation.SOURCE_FOLDER_PUBLIC + "/principals",
	foundation.SOURCE_FOLDER_PUBLIC + "/tpm2",
	foundation.SOURCE_FOLDER_INTERNAL + "/boot_program/firmware_memory_map",
	foundation.SOURCE_FOLDER_INTERNAL + "/boot_program/rescue_entry",
	foundation.SOURCE_FOLDER_PUBLIC + "/disk_process",
	foundation.SOURCE_FOLDER_PUBLIC + "/calendar",
	foundation.SOURCE_FOLDER_PUBLIC + "/line_editor",
	foundation.SOURCE_FOLDER_PUBLIC + "/console_language",
	foundation.SOURCE_FOLDER_INTERNAL + "/c_compiler/program_files",
	foundation.SOURCE_FOLDER_INTERNAL + "/serial_terminal/ansi_terminal",
	foundation.SOURCE_FOLDER_INTERNAL + "/grid_terminal/grid_renderer",
	foundation.SOURCE_FOLDER_INTERNAL + "/dom_terminal/dom_protocol",
	foundation.SOURCE_FOLDER_INTERNAL + "/debugger/debugging",
	foundation.SOURCE_FOLDER_INTERNAL + "/assistant/agent_step",
	foundation.SOURCE_FOLDER_INTERNAL + "/grants/grants_model",
	foundation.LIBRARY_MODULE_SOURCES + "interface_module",
	foundation.LIBRARY_MODULE_SOURCES + "drawing",
	foundation.DEMONSTRATION_MODULE_SOURCES + "sample",
	foundation.DEMONSTRATION_MODULE_SOURCES + "browser",
	foundation.SYSTEM_MODULE_SOURCES + "console",
	foundation.SYSTEM_MODULE_SOURCES + "monitor",
	foundation.SYSTEM_MODULE_SOURCES + "settings",
	foundation.SYSTEM_MODULE_SOURCES + "manual",
	foundation.APPLICATION_MODULE_SOURCES + "assistant",
	foundation.APPLICATION_MODULE_SOURCES + "grants",
	foundation.SYSTEM_MODULE_SOURCES + "collector",
	foundation.SYSTEM_MODULE_SOURCES + "guest_builder",
	foundation.SYSTEM_MODULE_SOURCES + "linux",
	foundation.SOURCE_FOLDER_PUBLIC + "/guest_regions",
	foundation.SOURCE_FOLDER_PUBLIC + "/system",
	foundation.SOURCE_FOLDER_PUBLIC + "/twins",
	foundation.SOURCE_FOLDER_INTERNAL + "/kernel_events/kernel_events_rounds",
	foundation.SOURCE_FOLDER_CONTRACT + "/tpm_service",
	foundation.SOURCE_FOLDER_PUBLIC + "/storage",
	foundation.SOURCE_FOLDER_INTERNAL + "/compositor/bar",
	foundation.SOURCE_FOLDER_INTERNAL + "/compositor/palette",
	foundation.SOURCE_FOLDER_INTERNAL + "/compositor/clipboard",
	foundation.SOURCE_FOLDER_INTERNAL + "/compositor/quality",
	foundation.SOURCE_FOLDER_CONTRACT + "/palette_table",
	foundation.SOURCE_FOLDER_PUBLIC + "/bootscreen",
	foundation.SOURCE_FOLDER_PUBLIC + "/bootscreen/image_card",
	foundation.SOURCE_FOLDER_PUBLIC + "/graphics",
	foundation.SOURCE_FOLDER_PUBLIC + "/interface",
	foundation.SOURCE_FOLDER_PUBLIC + "/layout",
	foundation.SOURCE_FOLDER_INTERNAL + "/inspect/addresses",
	foundation.SOURCE_FOLDER_INTERNAL + "/manual/information",
	foundation.SOURCE_FOLDER_PUBLIC + "/vector_font",
	foundation.SOURCE_FOLDER_PUBLIC + "/network",
	foundation.SOURCE_FOLDER_PUBLIC + "/tcp",
	foundation.SOURCE_FOLDER_PUBLIC + "/virtio",
	foundation.SOURCE_FOLDER_PUBLIC + "/bochs_display",
	foundation.SOURCE_FOLDER_PUBLIC + "/web",
	foundation.SOURCE_FOLDER_PUBLIC + "/cryptography/chacha20",
	foundation.SOURCE_FOLDER_PUBLIC + "/random",
	foundation.SOURCE_FOLDER_PUBLIC + "/trigonometry",
	foundation.SOURCE_FOLDER_CONTRACT + "/entropy_service",
	foundation.SOURCE_FOLDER_CONTRACT + "/fixed_addresses",
	foundation.SOURCE_FOLDER_CONTRACT + "/settings",
	foundation.LIBRARY_MODULE_SOURCES + "text_rendering",
	foundation.SOURCE_FOLDER_PUBLIC + "/text_rendering",
	foundation.SOURCE_FOLDER_PUBLIC + "/mark",
	foundation.SOURCE_FOLDER_PUBLIC + "/terminal",
	foundation.SOURCE_FOLDER_CONTRACT + "/cut_mark",
	foundation.SOURCE_FOLDER_CONTRACT + "/reference_screen",
	foundation.SOURCE_FOLDER_CONTRACT + "/scale_factor",
	foundation.SOURCE_FOLDER_CONTRACT + "/text_encoding",
	foundation.SOURCE_FOLDER_RUNTIME + "/without_vector_registers",
	foundation.SOURCE_FOLDER_PUBLIC + "/instruction_sets",
	foundation.SOURCE_FOLDER_CONTRACT + "/system_description",
	foundation.SOURCE_FOLDER_CONTRACT + "/replacement_list",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/replacement_signature",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/start_policy_rules",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/screen_budgets",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/wide_grant_flow",
	foundation.SOURCE_FOLDER_INTERNAL + "/compositor/wide_grant_view",
	foundation.SOURCE_FOLDER_INTERNAL + "/start_policy/wiring_rows",
	foundation.SOURCE_FOLDER_CONTRACT + "/operation",
	foundation.SOURCE_FOLDER_CONTRACT + "/operation_sequence",
	foundation.SOURCE_FOLDER_CONTRACT + "/debug_object",
	foundation.SOURCE_FOLDER_CONTRACT + "/value_kinds",
	foundation.SOURCE_FOLDER_INTERNAL + "/manual/source_comment_markdown",
	foundation.SOURCE_FOLDER_PUBLIC + "/console_results",
	foundation.SOURCE_FOLDER_PUBLIC + "/console_condition",
	foundation.SOURCE_FOLDER_PUBLIC + "/lex_parser",
	foundation.SOURCE_FOLDER_PUBLIC + "/lex_evaluator",
	foundation.SOURCE_FOLDER_INTERNAL + "/console/console_stream",
	foundation.SOURCE_FOLDER_PUBLIC + "/kept_choices",
	foundation.SOURCE_FOLDER_INTERNAL + "/console/plan_reader",
	foundation.SOURCE_FOLDER_PUBLIC + "/key_path",
	foundation.SOURCE_FOLDER_PUBLIC + "/kind_icons",
	foundation.SOURCE_FOLDER_CONTRACT + "/manual_pages",
	foundation.SOURCE_FOLDER_INTERNAL + "/manual/manual_navigation",
	foundation.SOURCE_FOLDER_INTERNAL + "/manual/module_list",
	foundation.SOURCE_FOLDER_PUBLIC + "/text_model",
	foundation.SOURCE_FOLDER_INTERNAL + "/notes/note_list",
	foundation.SOURCE_FOLDER_INTERNAL + "/notes/store_work",
	foundation.SOURCE_FOLDER_INTERNAL + "/notes/note_session",
	foundation.SOURCE_FOLDER_INTERNAL + "/monitor/sample_history",
	foundation.SOURCE_FOLDER_INTERNAL + "/clock/clock_model",
	foundation.SOURCE_FOLDER_INTERNAL + "/paint/paint_model",
	foundation.SOURCE_FOLDER_CONTRACT + "/ring",
	foundation.SOURCE_FOLDER_CONTRACT + "/font_characters",
	foundation.SOURCE_FOLDER_CONTRACT + "/datagram",
	foundation.SOURCE_FOLDER_CONTRACT + "/byte_order",
	foundation.SOURCE_FOLDER_CONTRACT + "/timed_stream",
	foundation.SOURCE_FOLDER_CONTRACT + "/sound_mixer",
	foundation.SOURCE_FOLDER_CONTRACT + "/output",
	foundation.SOURCE_FOLDER_CONTRACT + "/wiring_service",
	foundation.SOURCE_FOLDER_INTERNAL + "/wiring/wiring_core",
	foundation.SOURCE_FOLDER_CONTRACT + "/declaration_eval",
	foundation.SOURCE_FOLDER_CONTRACT + "/tree_hash",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/immutable_tree",
	foundation.SOURCE_FOLDER_INTERNAL + "/storage/module_gc",
	foundation.SOURCE_FOLDER_CONTRACT + "/object_cache",
	foundation.SOURCE_FOLDER_CONTRACT + "/draw_record",
	foundation.SOURCE_FOLDER_CONTRACT + "/accessibility",
	foundation.SOURCE_FOLDER_CONTRACT + "/speech_output",
	foundation.SOURCE_FOLDER_INTERNAL + "/sound/sound_device",
	foundation.SOURCE_FOLDER_KERNEL + "/acpi_processors",
	foundation.SOURCE_FOLDER_KERNEL + "/frame_runs",
	foundation.SOURCE_FOLDER_KERNEL + "/memory_wx",
	foundation.SOURCE_FOLDER_CONTRACT + "/role_contract",
	foundation.SOURCE_FOLDER_CONTRACT + "/supervision",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/role_policy",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/budget_growth",
	foundation.TEST_MODULE_SOURCES + "display_conformance",
	foundation.SOURCE_FOLDER_CONTRACT + "/powerbox",
	foundation.SOURCE_FOLDER_CONTRACT + "/chosen_values",
	foundation.SOURCE_FOLDER_CONTRACT + "/display_choices",
	foundation.SOURCE_FOLDER_CONTRACT + "/plan_values",
	foundation.SOURCE_FOLDER_CONTRACT + "/root_plan_values",
	foundation.SOURCE_FOLDER_INTERNAL + "/powerbox/powerbox_core",
	foundation.SOURCE_FOLDER_INTERNAL + "/scheduler/share_order",
	foundation.SOURCE_FOLDER_CONTRACT + "/plans_recipes",
	foundation.SOURCE_FOLDER_INTERNAL + "/plans/plans_core",
	foundation.SOURCE_FOLDER_INTERNAL + "/recipes/recipes_core",
	foundation.SOURCE_FOLDER_INTERNAL + "/projects/projects_core",
	foundation.SOURCE_FOLDER_CONTRACT + "/work_budget",
	foundation.TEST_MODULE_SOURCES + "work_accounting_probe",
	foundation.SOURCE_FOLDER_CONTRACT + "/wide_grants",
	foundation.SOURCE_FOLDER_INTERNAL + "/collector/collector_core",
	foundation.SOURCE_FOLDER_CONTRACT + "/lz4",
	foundation.SOURCE_FOLDER_CONTRACT + "/xor_filter",
	foundation.SOURCE_FOLDER_CONTRACT + "/store_search",
	foundation.SOURCE_FOLDER_CONTRACT + "/interface_messages",
	foundation.SOURCE_FOLDER_CONTRACT + "/virtio_input",
	foundation.SOURCE_FOLDER_INTERNAL + "/input/tablet",
	foundation.SOURCE_FOLDER_CONTRACT + "/remote_display",
	foundation.SOURCE_FOLDER_CONTRACT + "/guest_builder",
	foundation.SOURCE_FOLDER_CONTRACT + "/machine_mesh",
	foundation.SOURCE_FOLDER_CONTRACT + "/data_evolution",
	foundation.SOURCE_FOLDER_CONTRACT + "/agent_bridge",
	foundation.SOURCE_FOLDER_CONTRACT + "/assistant",
	foundation.SOURCE_FOLDER_INTERNAL + "/assistant/conversation",
	foundation.SOURCE_FOLDER_INTERNAL + "/assistant/result_lines",
	foundation.SOURCE_FOLDER_CONTRACT + "/software_machine",
	foundation.SOURCE_FOLDER_CONTRACT + "/software_machine_demonstration",
	foundation.SOURCE_FOLDER_CONTRACT + "/virtio_gpu",
	foundation.SOURCE_FOLDER_CONTRACT + "/webgpu_subset",
	foundation.SOURCE_FOLDER_CONTRACT + "/root_delegation",
	foundation.SOURCE_FOLDER_INTERNAL + "/disk_processes/disk_processes_core",
	foundation.SOURCE_FOLDER_INTERNAL + "/devices/devices_core",
	foundation.SOURCE_FOLDER_INTERNAL + "/principals/principals_core",
	foundation.SOURCE_FOLDER_INTERNAL + "/settings/appearance",
	foundation.SOURCE_FOLDER_CONTRACT + "/venus_vulkan",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/device_stop",
	foundation.SOURCE_FOLDER_INTERNAL + "/root/principal_unlock_flow",
	foundation.SOURCE_FOLDER_INTERNAL + "/log/scope_rules",
	foundation.SOURCE_FOLDER_PUBLIC + "/quic_server",
	foundation.SOURCE_FOLDER_PUBLIC + "/ssh_client",
	foundation.SOURCE_FOLDER_INTERNAL + "/terminal/grid_resize",
	foundation.SOURCE_FOLDER_CONTRACT + "/memory_screen",
	foundation.SOURCE_FOLDER_CONTRACT + "/image_decode",
	foundation.SOURCE_FOLDER_PUBLIC + "/tls_tcp",
	foundation.SOURCE_FOLDER_CONTRACT + "/http_client",
	foundation.SOURCE_FOLDER_CONTRACT + "/html_css",
	foundation.SOURCE_FOLDER_CONTRACT + "/tpm_attestation",
	foundation.SOURCE_FOLDER_CONTRACT + "/nvme",
	foundation.SOURCE_FOLDER_CONTRACT + "/store_history",
	foundation.SOURCE_FOLDER_CONTRACT + "/desktop_layout",
	foundation.SOURCE_FOLDER_CONTRACT + "/unicode_latin",
	foundation.SOURCE_FOLDER_CONTRACT + "/usb_hid",
	foundation.SOURCE_FOLDER_CONTRACT + "/wasm_runtime",
	foundation.SOURCE_FOLDER_CONTRACT + "/ime_cjk",
	foundation.SOURCE_FOLDER_CONTRACT + "/vnc_rdp_gateway",
	foundation.SOURCE_FOLDER_CONTRACT + "/document_picker",
	foundation.SOURCE_FOLDER_CONTRACT + "/ghostty_vt",
	foundation.SOURCE_FOLDER_CONTRACT + "/layout_measure",
	foundation.SOURCE_FOLDER_CONTRACT + "/video_codec",
	foundation.SOURCE_FOLDER_CONTRACT + "/processor_profiler",
	foundation.SOURCE_FOLDER_CONTRACT + "/driver_domain",
	foundation.SOURCE_FOLDER_CONTRACT + "/notifications",
	foundation.SOURCE_FOLDER_CONTRACT + "/blur_filter",
	foundation.SOURCE_FOLDER_CONTRACT + "/zero_copy_buffer",
	foundation.SOURCE_FOLDER_CONTRACT + "/screen_reader",
	foundation.SOURCE_FOLDER_CONTRACT + "/locale_cldr",
	foundation.SOURCE_FOLDER_CONTRACT + "/pci_topology",
	foundation.SOURCE_FOLDER_CONTRACT + "/kernel_fault_isolation",
	foundation.SOURCE_FOLDER_CONTRACT + "/machine_sync",
	foundation.SOURCE_FOLDER_CONTRACT + "/machine_wire",
	foundation.SOURCE_FOLDER_CONTRACT + "/browser_vm_runtime",
	foundation.SOURCE_FOLDER_CONTRACT + "/guest_os",
	foundation.SOURCE_FOLDER_CONTRACT + "/rich_toolkit",
	foundation.SOURCE_FOLDER_CONTRACT + "/serial_ring",
	foundation.SOURCE_FOLDER_CONTRACT + "/console_prompt",
	foundation.SOURCE_FOLDER_CONTRACT + "/desktop_shell",
}
