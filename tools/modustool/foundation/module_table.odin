// The table of the modules of the system, and the folders of the module
// files of a build, which a command sets for its process. The build, the
// machine tests and the site each read it
// (src/md/infrastructure/repository_layout.md, "The tool in packages").
package foundation

import "core:fmt"
import module "modus:contract/module"

// The modules of the project, each one after its imports.
//   source:  the folder of the Odin package, and of its .asm files.
// The exports of a module and their descriptions come from the source
// (describe.odin).
//   kernel:  the module runs in kernel mode: interrupts use its stack.
//   image:   the module is in the boot image.
Module_Build :: struct {
	name:    string,
	source:  string,
	imports: []string,
	kernel:  bool,
	// A module with an entry function, which the root service
	// starts. The start grant sets of the root service name each such module of the
	// boot image, the site shows it as a module with an entry, and a host test checks that
	// its source has the entry. A module of any group can be one: a module
	// group says what a module is for, not whether it starts.
	entry:   bool,
	image:   bool,
	// Settings of the compiler for this module only (-define): a kernel
	// for one machine of the test, and each module that draws its window
	// through the drawing module (DRAWING_THROUGH_MODULE).
	defines: []string,
	// A library module (docs/MODULE_CONTRACT.md, "A library as a module"):
	// many processes import it, each at another address. The conversion
	// refuses a segment that is read-only after the load: with none, the
	// module is one shared copy at each address, and takes one place in the
	// table of prepared modules of a starter, not one for each importer.
	library: bool,
	// A module that a disk holds: it is built as each module with an
	// entry, with the system library, and no boot image gets its file
	// (disk_processes.odin).
	disk:    bool,
	// The one boot image of a test that holds the module, and no other
	// image: the modules of the operation sequences. "": the module is in
	// each boot image of the build. A release refuses an image that holds
	// such a module (release_test_module_problem).
	only_in_image: string,
	// The C files of a work of others that the module compiles in, at a
	// pinned commit with the patches of the system. The zero record: the
	// module has no C part (src/md/infrastructure/outside_source.md).
	c_source:      Outside_Source,
	// What the module is to a reader, written in the header of its file
	// (module_category_of_row). A row states it only when its module group
	// allows more than one category: a row of system is a service, a
	// system tool or a developer tool. Each other row takes the one
	// category of its group, so the folder and the category cannot
	// disagree.
	category:      module.Module_Category,
	// What the module is about: the words that the manual filters on.
	tags:          module.Module_Tags,
	// Whether the start menu has a line for the module, when its category
	// is one that the menu lists (src/md/features/desktop_shell_look.md,
	// "The start menu"). A row that is not Listed says why in a comment.
	menu:          Menu_Presence,
}

// Menu_Presence says whether the start menu lists a module of a category
// that the menu lists. The zero value lists it: a new module is in the menu
// unless its row says why not.
Menu_Presence :: enum u8 {
	Listed       = 0, // A principal starts it alone, and sees or hears it.
	Partner_Only = 1, // Another process, or the tool, starts it as a part of its own work: alone it does nothing.
	Log_Only     = 2, // It opens no window: its result is lines of the log, which the console shows.
}

// MODULE_GROUP_CATEGORIES gives the categories that a module of each group
// can have: the first is the category of a row that states none.
MODULE_GROUP_CATEGORIES :: [Module_Group][]module.Module_Category {
	.System         = {.Service, .System_Tool, .Developer_Tool},
	.Applications   = {.Application},
	.Libraries      = {.Library},
	.Demonstrations = {.Demonstration},
	.Tests          = {.Test},
}

// module_category_of_row gives the category that the file of a row states.
// A row of a group with one category takes it, a row of system states its
// own, and a kernel, which is in no group, states none. problem: a row
// states a category that its group does not allow, or a row of system
// states none.
module_category_of_row :: proc(row: Module_Build) -> (category: module.Module_Category, problem: string) {
	group, found := module_group_of_source(row.source)
	if !found {
		if row.category != .None {
			return .None, fmt.tprintf("the row %s is in no module group and states the category %v: only a module of a group has one", row.name, row.category)
		}
		return .None, ""
	}
	allowed := MODULE_GROUP_CATEGORIES
	choices := allowed[group]
	if row.category == .None {
		if len(choices) > 1 {
			return .None, fmt.tprintf("the row %s of the group %v states no category: a module of that group is one of %v", row.name, group, choices)
		}
		return choices[0], ""
	}
	for choice in choices {
		if choice == row.category {
			return row.category, ""
		}
	}
	return .None, fmt.tprintf("the row %s of the group %v states the category %v: a module of that group is one of %v", row.name, group, row.category, choices)
}


// A work of others in C whose source is not in the repository. The flake
// fetches its source at one commit, applies the patches of `folder`, copies
// the files of the system of `folder` beside it, and sets `variable` to that
// folder of the store in each shell and in the check. The tool reads the
// folder of the store only through the variable.
Outside_Source :: struct {
	work:     string, // The name of the work: the folder of its C files in a message and in `__FILE__`.
	folder:   string, // The folder of the repository: LICENSE, patches, system, libc, self_host.
	variable: string, // The environment variable that names the folder of the store.
}

// chibicc, the C compiler of the module c_compiler
// (src/md/features/c_compiler.md).
CHIBICC :: Outside_Source {
	work     = "chibicc",
	folder   = SOURCE_FOLDER_OUTSIDE + "/chibicc",
	variable = "CHIBICC_SOURCE",
}

// outside_sources lists each outside source of the module table once: the
// reuse list names each one.
outside_sources :: proc(allocator := context.temp_allocator) -> []Outside_Source {
	sources := make([dynamic]Outside_Source, allocator)
	for build in module_builds {
		if build.c_source.folder == "" {
			continue
		}
		known := false
		for earlier in sources {
			known ||= earlier.folder == build.c_source.folder
		}
		if !known {
			append(&sources, build.c_source)
		}
	}
	return sources[:]
}

// The source of a row starts with the constant of its group
// (source_folders.odin): module_group_of_source reads the group from it.
module_builds := [?]Module_Build {
	{name = "test_callee", source = TEST_MODULE_SOURCES + "test_callee"},
	{name = "test_caller", source = TEST_MODULE_SOURCES + "test_caller", imports = {"test_callee"}},
	{name = "kernel", source = SOURCE_FOLDER_KERNEL, kernel = true},
	// The same kernel with the check of the instruction address before a
	// return to a process skipped, for one machine of `test return_fault`
	// only: its boot volume is BOOT_VOLUME_WITHOUT_RETURN_CHECK, and
	// machine_test refuses the line of this kernel in every other machine.
	{name = "kernel_without_return_check", source = SOURCE_FOLDER_KERNEL, kernel = true, defines = {"TEST_BUILD_SKIPS_THE_INSTRUCTION_ADDRESS_CHECK=true"}},
	// The counted kernel: an edge counter at each edge, which counts the
	// code of the runner of the operation sequences, for `fuzz operations`
	// only. Its boot volume is BOOT_VOLUME_OPERATION_FUZZING
	// (src/md/infrastructure/kernel_fuzzing.md, "The test kernel").
	{name = KERNEL_EDGE_COUNTERS_MODULE, source = SOURCE_FOLDER_KERNEL, kernel = true, defines = {KERNEL_EDGE_COUNTERS_DEFINE}},
	{name = "root", source = SYSTEM_MODULE_SOURCES + "root", category = .Service, entry = true, image = true},
	{name = "input", source = SYSTEM_MODULE_SOURCES + "input", category = .Service, entry = true, image = true},
	// The drawing of a window, for each module below that imports it.
	{name = DRAWING_MODULE, source = LIBRARY_MODULE_SOURCES + "drawing", image = true, library = true},
	// It draws its screen in parts, one call of the drawing module for each
	// part (src/md/api/picture.md).
	{name = "compositor", source = SYSTEM_MODULE_SOURCES + "compositor", category = .Service, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "console", source = SYSTEM_MODULE_SOURCES + "console", category = .System_Tool, entry = true, image = true},
	{name = "monitor", source = SYSTEM_MODULE_SOURCES + "monitor", category = .System_Tool, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "plasma", source = DEMONSTRATION_MODULE_SOURCES + "plasma", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "life", source = DEMONSTRATION_MODULE_SOURCES + "life", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "paint", source = DEMONSTRATION_MODULE_SOURCES + "paint", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "fault", source = DEMONSTRATION_MODULE_SOURCES + "fault", entry = true, image = true},
	{name = "hall_of_fame", source = DEMONSTRATION_MODULE_SOURCES + "hall_of_fame", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "heron", source = DEMONSTRATION_MODULE_SOURCES + "heron", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	// Partner_Only: rings starts six nodes and gives each its rings.
	{name = "node", source = DEMONSTRATION_MODULE_SOURCES + "node", entry = true, image = true, menu = .Partner_Only},
	{name = "rings", source = DEMONSTRATION_MODULE_SOURCES + "rings", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "threads", source = DEMONSTRATION_MODULE_SOURCES + "threads", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "workers", source = DEMONSTRATION_MODULE_SOURCES + "workers", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "rights", source = DEMONSTRATION_MODULE_SOURCES + "rights", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "origin", source = DEMONSTRATION_MODULE_SOURCES + "origin", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "limits", source = DEMONSTRATION_MODULE_SOURCES + "limits", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "budget", source = DEMONSTRATION_MODULE_SOURCES + "budget", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "flow", source = DEMONSTRATION_MODULE_SOURCES + "flow", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "crowd", source = DEMONSTRATION_MODULE_SOURCES + "crowd", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "tally", source = DEMONSTRATION_MODULE_SOURCES + "tally", entry = true, image = true},
	{name = "manual", source = SYSTEM_MODULE_SOURCES + "manual", category = .System_Tool, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "clock", source = DEMONSTRATION_MODULE_SOURCES + "clock", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "time_page", source = DEMONSTRATION_MODULE_SOURCES + "time_page", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	// Log_Only: no window; modustool measure starts it and reads its measures.
	{name = "processor_frame", source = DEMONSTRATION_MODULE_SOURCES + "processor_frame", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true, menu = .Log_Only},
	{name = "randomness", source = DEMONSTRATION_MODULE_SOURCES + "randomness", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "extended_state", source = DEMONSTRATION_MODULE_SOURCES + "extended_state", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "return_fault", source = DEMONSTRATION_MODULE_SOURCES + "return_fault", entry = true, image = true},
	{name = "fault_ring", source = DEMONSTRATION_MODULE_SOURCES + "fault_ring", entry = true, image = true},
	// Log_Only: no window; it debugs its own children, and the console shows its cases.
	{name = "debugged", source = DEMONSTRATION_MODULE_SOURCES + "debugged", entry = true, image = true, menu = .Log_Only},
	{name = "debugger", source = SYSTEM_MODULE_SOURCES + "debugger", category = .Service, entry = true, image = true},
	{name = "debug_target", source = TEST_MODULE_SOURCES + "debug_target", entry = true, image = true},
	{name = "replay_probe", source = TEST_MODULE_SOURCES + "replay_probe", entry = true, image = true},
	{name = "kernel_events", source = DEMONSTRATION_MODULE_SOURCES + "kernel_events", entry = true, image = true},
	// Log_Only: no window; the console shows what its guest did.
	{name = "guest_demo", source = DEMONSTRATION_MODULE_SOURCES + "guest_demo", entry = true, image = true, menu = .Log_Only},
	// Log_Only: no window; the console shows its cases.
	{name = "counters", source = DEMONSTRATION_MODULE_SOURCES + "counters", entry = true, image = true, menu = .Log_Only},
	{name = "terminal", source = SYSTEM_MODULE_SOURCES + "terminal", category = .Service, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "serial_terminal", source = SYSTEM_MODULE_SOURCES + "serial_terminal", category = .Service, entry = true, image = true},
	{name = "grid_terminal", source = SYSTEM_MODULE_SOURCES + "grid_terminal", category = .Service, entry = true, image = true},
	{name = "dom_terminal", source = SYSTEM_MODULE_SOURCES + "dom_terminal", category = .Service, entry = true, image = true},
	{name = "flood", source = TEST_MODULE_SOURCES + "flood", entry = true, image = true},
	// The test builder and the driver of the machine test of the builders
	// (src/md/features/recipes.md, "The builder"): recipes starts
	// builder_probe as a call host, so it has no entry.
	{name = "builder_probe", source = TEST_MODULE_SOURCES + "builder_probe", image = true},
	{name = "build_check", source = TEST_MODULE_SOURCES + "build_check", entry = true, image = true},
	{name = "hostile_terminal", source = TEST_MODULE_SOURCES + "hostile_terminal", entry = true, image = true},
	{name = "arena", source = TEST_MODULE_SOURCES + "arena", entry = true, image = true},
	{name = "output_wiring", source = TEST_MODULE_SOURCES + "output_wiring", entry = true, image = true},
	{name = "output_writer", source = TEST_MODULE_SOURCES + "output_writer", entry = true, image = true},
	{name = "log_flood", source = TEST_MODULE_SOURCES + "log_flood", entry = true, image = true},
	{name = "generic_wiring", source = TEST_MODULE_SOURCES + "generic_wiring", entry = true, image = true},
	{name = "generic_source", source = TEST_MODULE_SOURCES + "generic_source", entry = true, image = true},
	{name = "audit_asker", source = TEST_MODULE_SOURCES + "audit_asker", entry = true, image = true, only_in_image = BOOT_IMAGE_PLAN_AND_AUDIT},
	{name = "plan_applier", source = TEST_MODULE_SOURCES + "plan_applier", entry = true, image = true, only_in_image = BOOT_IMAGE_PLAN_AND_AUDIT},
	{name = "settings_stand_in", source = TEST_MODULE_SOURCES + "settings_stand_in", entry = true, image = true, only_in_image = BOOT_IMAGE_PLAN_AND_AUDIT},
	{name = "log_follower", source = TEST_MODULE_SOURCES + "log_follower", entry = true, image = true},
	{name = "notify_border_of_the_compositor", source = TEST_MODULE_SOURCES + "notify_border_of_the_compositor", entry = true, image = true},
	{name = "output_reader", source = TEST_MODULE_SOURCES + "output_reader", entry = true, image = true},
	{name = "output_side", source = TEST_MODULE_SOURCES + "output_side", entry = true, image = true},
	{name = "output_counter", source = TEST_MODULE_SOURCES + "output_counter", entry = true, image = true},
	{name = "output_count_reader", source = TEST_MODULE_SOURCES + "output_count_reader", entry = true, image = true},
	{name = "output_liar", source = TEST_MODULE_SOURCES + "output_liar", entry = true, image = true},
	{name = "requests_pace", source = TEST_MODULE_SOURCES + "requests_pace", entry = true, image = true},
	{name = "requests_reader", source = TEST_MODULE_SOURCES + "requests_reader", entry = true, image = true},
	{name = "output_measure", source = TEST_MODULE_SOURCES + "output_measure", entry = true, image = true},
	{name = "output_measure_writer", source = TEST_MODULE_SOURCES + "output_measure_writer", entry = true, image = true},
	{name = "output_measure_reader", source = TEST_MODULE_SOURCES + "output_measure_reader", entry = true, image = true},
	{name = "processors", source = DEMONSTRATION_MODULE_SOURCES + "processors", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "boot", source = SYSTEM_MODULE_SOURCES + "boot", category = .Developer_Tool, entry = true, image = true},
	{name = "pages", source = SYSTEM_MODULE_SOURCES + "pages", category = .Developer_Tool, entry = true, image = true},
	{name = "frames", source = DEMONSTRATION_MODULE_SOURCES + "frames", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	// Partner_Only: frames starts its twins to share pages with them.
	{name = "twin", source = DEMONSTRATION_MODULE_SOURCES + "twin", entry = true, image = true, menu = .Partner_Only},
	{name = "locks", source = DEMONSTRATION_MODULE_SOURCES + "locks", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	// It takes nearly every page of the machine and stops the machine at its
	// end: only the image of its test holds it, so no start policy of
	// another image can start it.
	{name = "shortage", source = TEST_MODULE_SOURCES + "shortage", entry = true, image = true, only_in_image = BOOT_IMAGE_SHORTAGE},
	// The two rows of the test of the restarts of a start policy: each stops
	// itself at once, one with Refused and one with Failed. Only the image
	// of that test holds them.
	{name = "stops_refused", source = TEST_MODULE_SOURCES + "stops_refused", entry = true, image = true, only_in_image = BOOT_IMAGE_MISSING_CONSOLE},
	{name = "stops_failed", source = TEST_MODULE_SOURCES + "stops_failed", entry = true, image = true, only_in_image = BOOT_IMAGE_MISSING_CONSOLE},
	{name = "scheduler", source = DEMONSTRATION_MODULE_SOURCES + "scheduler", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "address_space", source = DEMONSTRATION_MODULE_SOURCES + "address_space", entry = true, image = true},
	// Partner_Only: locks starts the lockers that load the kernel.
	{name = "locker", source = DEMONSTRATION_MODULE_SOURCES + "locker", entry = true, image = true, menu = .Partner_Only},
	{name = "log", source = SYSTEM_MODULE_SOURCES + "log", category = .System_Tool, entry = true, image = true},
	{name = "log_reader", source = TEST_MODULE_SOURCES + "log_reader", entry = true, image = true},
	{name = "block", source = SYSTEM_MODULE_SOURCES + "block", category = .Service, entry = true, image = true},
	{name = "frame", source = SYSTEM_MODULE_SOURCES + "frame", category = .Service, entry = true, image = true},
	{name = "iommu_device", source = TEST_MODULE_SOURCES + "iommu_device", entry = true, image = true},
	{name = "tpm", source = SYSTEM_MODULE_SOURCES + "tpm", category = .Service, entry = true, image = true},
	{name = "wiring", source = SYSTEM_MODULE_SOURCES + "wiring", category = .Service, entry = true, image = true},
	{name = "entropy", source = SYSTEM_MODULE_SOURCES + "entropy", category = .Service, entry = true, image = true},
	{name = "sound", source = SYSTEM_MODULE_SOURCES + "sound", category = .Service, entry = true, image = true},
	{name = "tone", source = DEMONSTRATION_MODULE_SOURCES + "tone", entry = true, image = true},
	{name = "iommu", source = TEST_MODULE_SOURCES + "iommu", entry = true, image = true},
	{name = "network", source = SYSTEM_MODULE_SOURCES + "network", category = .Service, entry = true, image = true},
	{name = "net", source = DEMONSTRATION_MODULE_SOURCES + "net", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "server", source = DEMONSTRATION_MODULE_SOURCES + "server", entry = true, image = true},
	// Partner_Only: its server is the listener of the tool in the test of TCP.
	{name = "fetch", source = DEMONSTRATION_MODULE_SOURCES + "fetch", entry = true, image = true, menu = .Partner_Only},
	{name = "module_files", source = SYSTEM_MODULE_SOURCES + "module_files", category = .Service, entry = true, image = true},
	{name = "inspect", source = SYSTEM_MODULE_SOURCES + "inspect", category = .Developer_Tool, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "debugger_window", source = SYSTEM_MODULE_SOURCES + "debugger_window", category = .Developer_Tool, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "disk", source = DEMONSTRATION_MODULE_SOURCES + "disk", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "storage", source = SYSTEM_MODULE_SOURCES + "storage", category = .Service, entry = true, image = true},
	{name = "notes", source = APPLICATION_MODULE_SOURCES + "notes", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "assistant", source = APPLICATION_MODULE_SOURCES + "assistant", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "persistence_check", source = TEST_MODULE_SOURCES + "persistence_check", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "browser", source = DEMONSTRATION_MODULE_SOURCES + "browser", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "edit", source = SYSTEM_MODULE_SOURCES + "edit", category = .System_Tool, entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "hierarchy", source = TEST_MODULE_SOURCES + "hierarchy", entry = true, image = true},
	{name = "ranges", source = TEST_MODULE_SOURCES + "ranges", entry = true, image = true},
	{name = "host", source = SYSTEM_MODULE_SOURCES + "host", category = .Service, entry = true, image = true},
	// The assembler: the console calls it in a call host
	// (src/md/features/assembler.md).
	{name = "assemble", source = SYSTEM_MODULE_SOURCES + "assemble", category = .Service, image = true},
	// The C compiler: chibicc, ported. The console calls it in a call
	// host, and gives its text to assemble (src/md/features/c_compiler.md).
	{name = "c_compiler", source = SYSTEM_MODULE_SOURCES + "c_compiler", category = .Service, image = true, c_source = CHIBICC},
	// The sandboxed declaration evaluator: evaluates .lex files lazily with
	// zero grants in a call host (src/md/features/declarations.md).
	{name = "declaration_eval", source = SYSTEM_MODULE_SOURCES + "declaration_eval", category = .Service, image = true},
	{name = "probe", source = TEST_MODULE_SOURCES + "probe", image = true},
	{name = "math", source = LIBRARY_MODULE_SOURCES + "math", image = true},
	{name = "cryptography", source = LIBRARY_MODULE_SOURCES + "cryptography", image = true},
	{name = "tls_tcp", source = LIBRARY_MODULE_SOURCES + "tls_tcp", image = true},
	{name = "ssh_client", source = LIBRARY_MODULE_SOURCES + "ssh_client", image = true},
	{name = "ghostty_vt", source = LIBRARY_MODULE_SOURCES + "ghostty_vt", image = true},
	{name = "web_engine", source = LIBRARY_MODULE_SOURCES + "web_engine", image = true},
	{name = "cryptography_vectors", source = DEMONSTRATION_MODULE_SOURCES + "cryptography_vectors", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "quic_echo", source = DEMONSTRATION_MODULE_SOURCES + "quic_echo", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "remote", source = SYSTEM_MODULE_SOURCES + "remote", category = .System_Tool, entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "remote_display", source = SYSTEM_MODULE_SOURCES + "remote_display", category = .Service, entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "unlock", source = SYSTEM_MODULE_SOURCES + "unlock", category = .Service, entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "sample", source = DEMONSTRATION_MODULE_SOURCES + "sample", image = true},
	{name = "hostile_exports", source = DEMONSTRATION_MODULE_SOURCES + "hostile_exports", image = true},
	{name = "calendar", source = LIBRARY_MODULE_SOURCES + "calendar", image = true},
	{name = "calendar_fixed", source = DEMONSTRATION_MODULE_SOURCES + "calendar_fixed", image = true},
	{name = "calendar_changed", source = DEMONSTRATION_MODULE_SOURCES + "calendar_changed", image = true},
	{name = "agenda", source = DEMONSTRATION_MODULE_SOURCES + "agenda", imports = {"calendar"}, image = true},
	// Its import is not in the boot image: a loader refuses it.
	{name = "lonely", source = DEMONSTRATION_MODULE_SOURCES + "lonely", imports = {"test_callee"}, image = true},
	{name = "imports", source = DEMONSTRATION_MODULE_SOURCES + "imports", entry = true, imports = {"calendar"}, image = true},
	{name = "errors", source = DEMONSTRATION_MODULE_SOURCES + "errors", entry = true, image = true},
	{name = "interface_elements", source = DEMONSTRATION_MODULE_SOURCES + "interface_elements", entry = true, image = true},
	{name = "tables", source = DEMONSTRATION_MODULE_SOURCES + "tables", entry = true, image = true},
	{name = "interface_module", source = LIBRARY_MODULE_SOURCES + "interface_module", image = true},
	// It compares the package compiled in with the two modules, so it has
	// no setting: its window layer is its own code.
	{name = "interface_through_module", source = DEMONSTRATION_MODULE_SOURCES + "interface_through_module", entry = true, imports = {"interface_module", DRAWING_MODULE}, image = true},
	{name = "text_rendering", source = LIBRARY_MODULE_SOURCES + "text_rendering", image = true},
	// The utility modules of the record streams: each one runs as a
	// process, with a generic record input and a generic record output
	// (src/md/features/module_outputs.md, "Generic record inputs and the
	// utility modules").
	{name = "merge", source = LIBRARY_MODULE_SOURCES + "merge", entry = true, image = true},
	{name = "filter", source = LIBRARY_MODULE_SOURCES + "filter", entry = true, image = true},
	// The demonstration pair of the start list: the default start list
	// starts the reader, then the writer, whose start carries the wiring
	// row between them (src/md/features/module_outputs.md, "The wiring rows
	// of a start list").
	// Partner_Only: the start list wires it to wired_writer.
	{name = "wired_reader", source = DEMONSTRATION_MODULE_SOURCES + "wired_reader", entry = true, image = true, menu = .Partner_Only},
	// Partner_Only: the start list wires it to wired_reader.
	{name = "wired_writer", source = DEMONSTRATION_MODULE_SOURCES + "wired_writer", entry = true, image = true, menu = .Partner_Only},
	{name = "vector_glyphs", source = DEMONSTRATION_MODULE_SOURCES + "vector_glyphs", entry = true, image = true},
	{name = "interface_font", source = DEMONSTRATION_MODULE_SOURCES + "interface_font", entry = true, image = true},
	{name = "pointers", source = DEMONSTRATION_MODULE_SOURCES + "pointers", entry = true, image = true},
	{name = "settings", source = SYSTEM_MODULE_SOURCES + "settings", category = .System_Tool, entry = true, image = true},
	{name = "date", source = SYSTEM_MODULE_SOURCES + "date", category = .Service, entry = true, image = true},
	// The default start policy and the rescue start policy: one module that
	// reads the list that the root service maps (src/md/features/start_policy.md).
	{name = START_POLICY_MODULE, source = SYSTEM_MODULE_SOURCES + START_POLICY_MODULE, category = .Service, entry = true, image = true},
	// The module of the operation sequences and its runner: only the boot
	// image of the operation sequences holds them, and the root service
	// starts nothing else there.
	{name = OPERATION_SEQUENCE_RUNNER_MODULE, source = TEST_MODULE_SOURCES + OPERATION_SEQUENCE_RUNNER_MODULE, entry = true, image = true, only_in_image = BOOT_IMAGE_OPERATION_SEQUENCES},
	{name = OPERATION_FUZZING_MODULE, source = TEST_MODULE_SOURCES + OPERATION_FUZZING_MODULE, entry = true, image = true, only_in_image = BOOT_IMAGE_OPERATION_SEQUENCES},
	// It is not in the boot image: the tool writes its file in the store
	// `module_files` of a data disk, and the root service starts it from there
	// (disk_processes.odin).
	{name = DISK_MODULE_NAME, source = TEST_MODULE_SOURCES + DISK_MODULE_NAME, entry = true, image = true, disk = true},
	// A library module and a process that imports it, both in the store
	// `module_files` only: the root service finds the import by the hash of
	// its bytes (disk_processes.odin).
	{name = STORE_LIBRARY_MODULE, source = TEST_MODULE_SOURCES + STORE_LIBRARY_MODULE, image = true, library = true, disk = true},
	{name = STORE_IMPORTER_MODULE, source = TEST_MODULE_SOURCES + STORE_IMPORTER_MODULE, entry = true, imports = {STORE_LIBRARY_MODULE}, image = true, disk = true},
	// A start policy in the store `module_files` only: principal 0 chooses
	// it, and the next start runs it (src/md/features/start_policy.md).
	{name = DISK_START_POLICY_MODULE, source = TEST_MODULE_SOURCES + DISK_START_POLICY_MODULE, entry = true, image = true, disk = true},
	// The conformance suite for any holder of Role.Display
	// (src/md/features/roles_and_contracts.md).
	{name = "display_conformance", source = TEST_MODULE_SOURCES + "display_conformance"},
	// The delegated powerbox service implementing Role.Powerbox
	// (src/md/features/powerbox.md).
	{name = "powerbox", source = SYSTEM_MODULE_SOURCES + "powerbox", category = .Service, entry = true, image = true},
	// The delegated plans, recipes, and projects services implementing
	// Role.Plans, Role.Recipes, and Role.Projects
	// (src/md/features/declarations.md; src/md/features/recipes.md).
	{name = "plans", source = SYSTEM_MODULE_SOURCES + "plans", category = .Service, entry = true, image = true},
	{name = "recipes", source = SYSTEM_MODULE_SOURCES + "recipes", category = .Service, entry = true, image = true},
	{name = "projects", source = SYSTEM_MODULE_SOURCES + "projects", category = .Service, entry = true, image = true},
	// The probe module for client-funded work budgets and per-connection work
	// threads (src/md/features/work_accounting.md).
	{name = "work_accounting_probe", source = TEST_MODULE_SOURCES + "work_accounting_probe", image = true},
	// The delegated collector and wide-grant audit service
	// (src/md/features/module_outputs.md, src/md/features/wide_grants.md).
	{name = "collector", source = SYSTEM_MODULE_SOURCES + "collector", category = .Service, entry = true, image = true},
	// The sandboxed guest builder: runs a deterministic, zero-network guest
	// with a read-only input disk and a blank writable output disk
	// (src/md/features/recipes.md).
	{name = "guest_builder", source = SYSTEM_MODULE_SOURCES + "guest_builder", category = .Service, image = true},
	// A shell of Linux in a terminal window: a guest that boots the kernel of
	// its private store (src/md/features/linux_shell.md).
	{name = "linux", source = SYSTEM_MODULE_SOURCES + "linux", category = .System_Tool, entry = true, image = true},
	// The VirtIO-GPU device service: 2D scanout setup and Venus capability
	// probing over the VirtIO-GPU 1.2 control queue (src/md/features/gpu_access.md).
	{name = "gpu_device", source = SYSTEM_MODULE_SOURCES + "gpu_device", category = .Service, entry = true, image = true},
	// The delegated disk_processes, devices, and principals services split out
	// of the root service (src/md/api/root_service_split.md).
	{name = "disk_processes", source = SYSTEM_MODULE_SOURCES + "disk_processes", category = .Service, entry = true, image = true},
	{name = "devices", source = SYSTEM_MODULE_SOURCES + "devices", category = .Service, entry = true, image = true},
	{name = "principals", source = SYSTEM_MODULE_SOURCES + "principals", category = .Service, entry = true, image = true},
}

// The counted kernel and its setting. Each other kernel gets the setting
// false (build/modules.odin, module_compile_command).
KERNEL_EDGE_COUNTERS_MODULE :: "kernel_edge_counters"
KERNEL_EDGE_COUNTERS_SETTING :: "KERNEL_EDGE_COUNTERS"
KERNEL_EDGE_COUNTERS_DEFINE :: KERNEL_EDGE_COUNTERS_SETTING + "=true"

// module_counts_kernel_edges says if a module of the table is a counted
// kernel: a kernel with the setting of the edge counters.
module_counts_kernel_edges :: proc(build: Module_Build) -> bool {
	if !build.kernel {
		return false
	}
	for define in build.defines {
		if define == KERNEL_EDGE_COUNTERS_DEFINE {
			return true
		}
	}
	return false
}

// module_in_boot_image says if the boot image holds the file of a module.
module_in_boot_image :: proc(build: Module_Build) -> bool {
	return build.image && !build.disk && build.only_in_image == ""
}

// module_in_a_boot_image says if some boot image of the build holds the
// file of a module: the boot image, or the one image of a test.
module_in_a_boot_image :: proc(build: Module_Build) -> bool {
	return module_in_boot_image(build) || build.image && !build.disk && build.only_in_image != ""
}

module_path :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, ".module")
}

// module_import_path gives the path of the module file of an import.
module_import_path :: proc(name: string) -> string {
	if module_import_folder == "" {
		return module_path(name)
	}
	return join(module_import_folder, "/", name, ".module")
}

// The folder of the modules of this build, and whether the compiler writes
// debug information: a module process receives both from its command.
module_build_folder := MODULE_BUILD_FOLDER

// The folder of the module file of each import of a module. "": the folder
// of the modules of this build, where the import was written before its
// importer. A module from a source outside the repository is written to a
// folder of its developer, and its imports are modules of the system, in
// the folder of the build of the system (outside_module.odin).
module_import_folder := ""

MODULE_BUILD_FOLDER :: BUILD_FOLDER + "/modules"

SYSTEM_LIBRARY_FOLDER :: SOURCE_FOLDER_PUBLIC + "/system"

// The boot image of the operation sequences: the modules of the boot image,
// and the two modules that only it holds (src/md/infrastructure/kernel_fuzzing.md).
BOOT_IMAGE_OPERATION_SEQUENCES :: BUILD_FOLDER + "/boot_operation_sequences.image"

// The boot image of the shortage of frames: no input service, and the
// module shortage, which only it holds.
BOOT_IMAGE_SHORTAGE :: BUILD_FOLDER + "/boot_shortage.image"

// The boot image of the test of the rescue and of the restarts: the
// modules of the boot image, and the two modules of the test of the
// restarts, which only it holds.
BOOT_IMAGE_MISSING_CONSOLE :: BUILD_FOLDER + "/boot_missing_console.image"

// The boot image of the test of the plan of principal 0 and of the audit of
// the collector: the modules of the boot image, and the three test modules
// of that test, which only it holds, so a release never holds a plan
// applier, a stand-in holder of Settings or their grants.
BOOT_IMAGE_PLAN_AND_AUDIT :: BUILD_FOLDER + "/boot_plan_and_audit.image"

OPERATION_FUZZING_MODULE :: "operation_fuzzing"

// The module that holds the role Display in each boot image: the row of
// the role in the table of the root service (src/modules/system/root,
// role_holder_names). A start list names the role "display", and the check
// of a list finds this module in the image in its place.
DISPLAY_HOLDER_MODULE :: "compositor"

// The module of the start policy, which the boot image of a start that
// fails leaves out, and whose source the tool checks (start_lists.odin).
START_POLICY_MODULE :: "start_policy"

OPERATION_SEQUENCE_RUNNER_MODULE :: "operation_sequence_runner"

// The drawing module, and the setting of a module that draws its window
// through it (src/library/modus/interface, window_drawing.odin). A module with the
// setting imports the module: a host test checks it
// (import_declarations_test.odin).
DRAWING_MODULE :: "drawing"

DRAWING_THROUGH_MODULE :: "DRAWING_THROUGH_MODULE=true"

// The module that the tool writes on the disk of the test: a row of the
// module table that is not in the boot image.
DISK_MODULE_NAME :: "visitor"

// A library module and a module that imports it: two rows of the module
// table that are not in the boot image. The root service finds the import
// in the store `module_files` by the hash of its bytes.
STORE_LIBRARY_MODULE :: "store_library"

STORE_IMPORTER_MODULE :: "store_importer"

// The start policy that the tool writes in the store `module_files` of the
// disk of the start policy from the disk: a row of the module table that is
// not in the boot image.
DISK_START_POLICY_MODULE :: "disk_start_policy"
