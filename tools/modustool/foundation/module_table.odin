// The table of the modules of the system, and the folders of the module
// files of a build, which a command sets for its process. The build, the
// machine tests and the site each read it
// (src/md/infrastructure/repository_layout.md, "The tool in packages").
package foundation

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
	// starts. The roles of the root service name each such module of the
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
	{name = "root", source = SYSTEM_MODULE_SOURCES + "root", entry = true, image = true},
	{name = "input", source = SYSTEM_MODULE_SOURCES + "input", entry = true, image = true},
	// The drawing of a window, for each module below that imports it.
	{name = DRAWING_MODULE, source = LIBRARY_MODULE_SOURCES + "drawing", image = true, library = true},
	// It draws its screen in parts, one call of the drawing module for each
	// part (src/md/api/picture.md).
	{name = "compositor", source = SYSTEM_MODULE_SOURCES + "compositor", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "console", source = SYSTEM_MODULE_SOURCES + "console", entry = true, image = true},
	{name = "monitor", source = SYSTEM_MODULE_SOURCES + "monitor", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "plasma", source = DEMONSTRATION_MODULE_SOURCES + "plasma", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "life", source = DEMONSTRATION_MODULE_SOURCES + "life", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "paint", source = DEMONSTRATION_MODULE_SOURCES + "paint", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "fault", source = DEMONSTRATION_MODULE_SOURCES + "fault", entry = true, image = true},
	{name = "hall_of_fame", source = DEMONSTRATION_MODULE_SOURCES + "hall_of_fame", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "heron", source = DEMONSTRATION_MODULE_SOURCES + "heron", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "node", source = DEMONSTRATION_MODULE_SOURCES + "node", entry = true, image = true},
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
	{name = "manual", source = SYSTEM_MODULE_SOURCES + "manual", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "clock", source = DEMONSTRATION_MODULE_SOURCES + "clock", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "processor_frame", source = DEMONSTRATION_MODULE_SOURCES + "processor_frame", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "randomness", source = DEMONSTRATION_MODULE_SOURCES + "randomness", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "extended_state", source = DEMONSTRATION_MODULE_SOURCES + "extended_state", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "return_fault", source = DEMONSTRATION_MODULE_SOURCES + "return_fault", entry = true, image = true},
	{name = "fault_ring", source = DEMONSTRATION_MODULE_SOURCES + "fault_ring", entry = true, image = true},
	{name = "debugged", source = DEMONSTRATION_MODULE_SOURCES + "debugged", entry = true, image = true},
	{name = "debugger", source = SYSTEM_MODULE_SOURCES + "debugger", entry = true, image = true},
	{name = "debug_target", source = TEST_MODULE_SOURCES + "debug_target", entry = true, image = true},
	{name = "kernel_events", source = DEMONSTRATION_MODULE_SOURCES + "kernel_events", entry = true, image = true},
	{name = "guest_demo", source = DEMONSTRATION_MODULE_SOURCES + "guest_demo", entry = true, image = true},
	{name = "counters", source = DEMONSTRATION_MODULE_SOURCES + "counters", entry = true, image = true},
	{name = "terminal", source = SYSTEM_MODULE_SOURCES + "terminal", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "flood", source = TEST_MODULE_SOURCES + "flood", entry = true, image = true},
	{name = "hostile_terminal", source = TEST_MODULE_SOURCES + "hostile_terminal", entry = true, image = true},
	{name = "arena", source = TEST_MODULE_SOURCES + "arena", entry = true, image = true},
	{name = "processors", source = DEMONSTRATION_MODULE_SOURCES + "processors", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "boot", source = SYSTEM_MODULE_SOURCES + "boot", entry = true, image = true},
	{name = "pages", source = SYSTEM_MODULE_SOURCES + "pages", entry = true, image = true},
	{name = "frames", source = DEMONSTRATION_MODULE_SOURCES + "frames", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "twin", source = DEMONSTRATION_MODULE_SOURCES + "twin", entry = true, image = true},
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
	{name = "locker", source = DEMONSTRATION_MODULE_SOURCES + "locker", entry = true, image = true},
	{name = "log", source = SYSTEM_MODULE_SOURCES + "log", entry = true, image = true},
	{name = "log_reader", source = TEST_MODULE_SOURCES + "log_reader", entry = true, image = true},
	{name = "block", source = SYSTEM_MODULE_SOURCES + "block", entry = true, image = true},
	{name = "frame", source = SYSTEM_MODULE_SOURCES + "frame", entry = true, image = true},
	{name = "iommu_device", source = TEST_MODULE_SOURCES + "iommu_device", entry = true, image = true},
	{name = "tpm", source = SYSTEM_MODULE_SOURCES + "tpm", entry = true, image = true},
	{name = "entropy", source = SYSTEM_MODULE_SOURCES + "entropy", entry = true, image = true},
	{name = "sound", source = SYSTEM_MODULE_SOURCES + "sound", entry = true, image = true},
	{name = "tone", source = DEMONSTRATION_MODULE_SOURCES + "tone", entry = true, image = true},
	{name = "iommu", source = TEST_MODULE_SOURCES + "iommu", entry = true, image = true},
	{name = "network", source = SYSTEM_MODULE_SOURCES + "network", entry = true, image = true},
	{name = "net", source = DEMONSTRATION_MODULE_SOURCES + "net", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "server", source = DEMONSTRATION_MODULE_SOURCES + "server", entry = true, image = true},
	{name = "fetch", source = DEMONSTRATION_MODULE_SOURCES + "fetch", entry = true, image = true},
	{name = "module_files", source = SYSTEM_MODULE_SOURCES + "module_files", entry = true, image = true},
	{name = "inspect", source = SYSTEM_MODULE_SOURCES + "inspect", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "debugger_window", source = SYSTEM_MODULE_SOURCES + "debugger_window", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "disk", source = DEMONSTRATION_MODULE_SOURCES + "disk", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "storage", source = SYSTEM_MODULE_SOURCES + "storage", entry = true, image = true},
	{name = "notes", source = DEMONSTRATION_MODULE_SOURCES + "notes", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "edit", source = SYSTEM_MODULE_SOURCES + "edit", entry = true, imports = {DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "hierarchy", source = TEST_MODULE_SOURCES + "hierarchy", entry = true, image = true},
	{name = "ranges", source = TEST_MODULE_SOURCES + "ranges", entry = true, image = true},
	{name = "host", source = SYSTEM_MODULE_SOURCES + "host", entry = true, image = true},
	{name = "probe", source = TEST_MODULE_SOURCES + "probe", image = true},
	{name = "math", source = LIBRARY_MODULE_SOURCES + "math", image = true},
	{name = "cryptography", source = LIBRARY_MODULE_SOURCES + "cryptography", image = true},
	{name = "cryptography_vectors", source = DEMONSTRATION_MODULE_SOURCES + "cryptography_vectors", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "quic_echo", source = DEMONSTRATION_MODULE_SOURCES + "quic_echo", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "remote", source = SYSTEM_MODULE_SOURCES + "remote", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "remote_display", source = SYSTEM_MODULE_SOURCES + "remote_display", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "unlock", source = SYSTEM_MODULE_SOURCES + "unlock", entry = true, imports = {"cryptography", DRAWING_MODULE}, defines = {DRAWING_THROUGH_MODULE}, image = true},
	{name = "sample", source = DEMONSTRATION_MODULE_SOURCES + "sample", image = true},
	{name = "hostile_exports", source = TEST_MODULE_SOURCES + "hostile_exports", image = true},
	{name = "calendar", source = LIBRARY_MODULE_SOURCES + "calendar", image = true},
	{name = "calendar_fixed", source = TEST_MODULE_SOURCES + "calendar_fixed", image = true},
	{name = "calendar_changed", source = TEST_MODULE_SOURCES + "calendar_changed", image = true},
	{name = "agenda", source = DEMONSTRATION_MODULE_SOURCES + "agenda", imports = {"calendar"}, image = true},
	// Its import is not in the boot image: a loader refuses it.
	{name = "lonely", source = TEST_MODULE_SOURCES + "lonely", imports = {"test_callee"}, image = true},
	{name = "imports", source = DEMONSTRATION_MODULE_SOURCES + "imports", entry = true, imports = {"calendar"}, image = true},
	{name = "errors", source = DEMONSTRATION_MODULE_SOURCES + "errors", entry = true, image = true},
	{name = "interface_elements", source = DEMONSTRATION_MODULE_SOURCES + "interface_elements", entry = true, image = true},
	{name = "tables", source = DEMONSTRATION_MODULE_SOURCES + "tables", entry = true, image = true},
	{name = "interface_module", source = LIBRARY_MODULE_SOURCES + "interface_module", image = true},
	// It compares the package compiled in with the two modules, so it has
	// no setting: its window layer is its own code.
	{name = "interface_through_module", source = DEMONSTRATION_MODULE_SOURCES + "interface_through_module", entry = true, imports = {"interface_module", DRAWING_MODULE}, image = true},
	{name = "text_rendering", source = LIBRARY_MODULE_SOURCES + "text_rendering", image = true},
	{name = "vector_glyphs", source = DEMONSTRATION_MODULE_SOURCES + "vector_glyphs", entry = true, image = true},
	{name = "interface_font", source = DEMONSTRATION_MODULE_SOURCES + "interface_font", entry = true, image = true},
	{name = "pointers", source = DEMONSTRATION_MODULE_SOURCES + "pointers", entry = true, image = true},
	{name = "settings", source = SYSTEM_MODULE_SOURCES + "settings", entry = true, image = true},
	{name = "date", source = SYSTEM_MODULE_SOURCES + "date", entry = true, image = true},
	// The default start policy and the rescue start policy: one module that
	// reads the list that the root service maps (src/md/features/start_policy.md).
	{name = START_POLICY_MODULE, source = SYSTEM_MODULE_SOURCES + START_POLICY_MODULE, entry = true, image = true},
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

SYSTEM_LIBRARY_FOLDER :: SOURCE_FOLDER_SUPPORT + "/system"

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

OPERATION_FUZZING_MODULE :: "operation_fuzzing"

// The module of the start policy, which the boot image of a start that
// fails leaves out, and whose source the tool checks (start_lists.odin).
START_POLICY_MODULE :: "start_policy"

OPERATION_SEQUENCE_RUNNER_MODULE :: "operation_sequence_runner"

// The drawing module, and the setting of a module that draws its window
// through it (src/library/support/interface, window_drawing.odin). A module with the
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
