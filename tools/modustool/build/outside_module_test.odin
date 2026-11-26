package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// A module build file with each key gives each field of a row.
@(test)
module_build_file_with_each_key :: proc(t: ^testing.T) {
	file, problem := module_build_file_parse("name: my_process\nimports: drawing  cryptography\n\ndefines: DRAWING_THROUGH_MODULE=true SIZE=4\nlibrary: yes\ntarget: modus\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, file.name, "my_process")
	testing.expect(t, slice.equal(file.imports, []string{"drawing", "cryptography"}), "the imports keep their order")
	testing.expect(t, slice.equal(file.defines, []string{"DRAWING_THROUGH_MODULE=true", "SIZE=4"}), "the defines keep their order")
	testing.expect(t, file.library)
	testing.expect_value(t, file.target, Module_Target.Modus)
}

// The name alone is a whole file: no import, no setting, not a library
// module, and target defaults to Freestanding. An empty value of a list
// is an empty list.
@(test)
module_build_file_with_the_name_alone :: proc(t: ^testing.T) {
	file, problem := module_build_file_parse("name: tally\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, file.name, "tally")
	testing.expect_value(t, len(file.imports), 0)
	testing.expect_value(t, len(file.defines), 0)
	testing.expect(t, !file.library)
	testing.expect_value(t, file.target, Module_Target.Freestanding)
	file, problem = module_build_file_parse("imports:\r\nname: tally\r\ntarget: freestanding\r\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(file.imports), 0)
	testing.expect_value(t, file.target, Module_Target.Freestanding)
	file, problem = module_build_file_parse("name: core_probe\ntarget: modus\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, file.target, Module_Target.Modus)
}

// Each line that the reader does not know is a fault with its line: the
// tool guesses no field.
@(test)
module_build_file_faults :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		problem: string, // A part of the sentence.
	}
	cases := [?]Case {
		{"imports: drawing\n", "the key name is absent"},
		{"", "the key name is absent"},
		{"name: tally\nkernel: yes\n", "line 2: the key kernel is not known"},
		{"name: tally\nname: other\n", "line 2: the key name is written two times"},
		{"name: tally\n# a note\n", "line 2 is not `key: value`"},
		{"name tally\n", "line 1 is not `key: value`"},
		{"name: Tally\n", "line 1: Tally is not a name of a module"},
		{"name:\n", "is not a name of a module"},
		{"name: a_name_of_more_than_thirty_one_bytes\n", "is not a name of a module"},
		{"name: tally\nimports: ../calendar\n", "line 2: ../calendar is not a name of a module"},
		{"name: tally\nimports: calendar calendar\n", "line 2: the import calendar is written two times"},
		{"name: tally\ndefines: CHECKS\n", "line 2: CHECKS is not a setting of the compiler"},
		{"name: tally\ndefines: =true\n", "is not a setting of the compiler"},
		{"name: tally\nlibrary: true\n", "line 2: the value of library is yes or no, not true"},
		{"name: tally\ntarget:\n", "line 2: the value of target is freestanding or modus"},
		{"name: tally\ntarget:   \n", "line 2: the value of target is freestanding or modus"},
		{"name: tally\ntarget: linux\n", "line 2: the value of target is freestanding or modus, not linux"},
		{"name: tally\ntarget: Modus\n", "line 2: the value of target is freestanding or modus, not Modus"},
		{"name: tally\ntarget: freestanding_amd64_sysv\n", "line 2: the value of target is freestanding or modus"},
		{"name: tally\ntarget: freestanding\ntarget: modus\n", "line 3: the key target is written two times"},
		{"name: tally\ntarget: modus\ntarget: modus\n", "line 3: the key target is written two times"},
	}
	for item in cases {
		_, problem := module_build_file_parse(item.text)
		testing.expectf(t, strings.contains(problem, item.problem), "%q gives %q, not a sentence with %q", item.text, problem, item.problem)
	}
}

// Every Module_Target member maps to its exact word and parses back; any other
// word is refused at the border.
@(test)
module_target_words_and_refusals :: proc(t: ^testing.T) {
	for target in Module_Target {
		word := foundation.module_target_word(target)
		testing.expect(t, word != "", "each Module_Target has a word")
		parsed, ok := foundation.module_target_of_word(word)
		testing.expect(t, ok, "the word of a target parses back")
		testing.expect_value(t, parsed, target)
	}
	testing.expect_value(t, foundation.module_target_word(.Freestanding), "freestanding")
	testing.expect_value(t, foundation.module_target_word(.Modus), "modus")
	for bad in ([]string{"", "Freestanding", "Modus", "MODUS", "linux", "modus_amd64", "freestanding_amd64_sysv", "modus ", " modus", "core"}) {
		_, ok := foundation.module_target_of_word(bad)
		testing.expectf(t, !ok, "unknown target word `%s` is refused", bad)
	}
}

// The module build file of each example of the check says what the row
// of its module says in the module table: the check compares the module
// of the copy with the module of that row.
@(test)
outside_module_examples_follow_the_module_table :: proc(t: ^testing.T) {
	examples := OUTSIDE_MODULE_EXAMPLES
	folders := foundation.SOURCE_FOLDERS
	for folder in folders {
		testing.expectf(t, !strings.has_prefix(THIRD_PARTY_EXAMPLE_FOLDER, folder), "%s is under %s", THIRD_PARTY_EXAMPLE_FOLDER, folder)
	}
	with_an_import := 0
	for example in examples {
		testing.expect(t, os.is_dir(example.source), example.source)
		file, problem := module_build_file_parse(example.build_file)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, file.name, example.name)
		found := false
		for row in foundation.module_builds {
			if row.name != example.name {
				continue
			}
			found = true
			testing.expect_value(t, row.source, example.source)
			testing.expect(t, slice.equal(row.imports, file.imports), example.name)
			testing.expect(t, slice.equal(row.defines, file.defines), example.name)
			testing.expect_value(t, row.library, file.library)
			// An outside module links the system library and never runs in
			// kernel mode: the example is such a row.
			testing.expect(t, row.image && !row.kernel, example.name)
		}
		testing.expect(t, found, example.name)
		with_an_import += len(file.imports) > 0 ? 1 : 0
	}
	testing.expect(t, with_an_import > 0, "no example has an import: the folder of the imports is not proved")
}

// A source of an outside module is in the folder of the module or under
// it, in the source library, or in the libraries of the compiler.
@(test)
outside_module_source_places :: proc(t: ^testing.T) {
	module_folder :: "/home/someone/projects/my_process"
	library_folder :: "/home/someone/modus/src/library/modus"
	compiler_folder :: "/nix/store/odin/share"
	place :: proc(path: string) -> bool {
		return outside_module_source_has_a_place(path, module_folder, library_folder, compiler_folder)
	}
	testing.expect(t, place("/home/someone/projects/my_process/main.odin"))
	testing.expect(t, place("/home/someone/projects/my_process/parts/draw.odin"))
	testing.expect(t, place("/home/someone/modus/src/library/modus/system/system.odin"))
	testing.expect(t, !place("/home/someone/modus/src/library/internal/storage/storage_tree/storage_tree.odin"))
	testing.expect(t, place("/nix/store/odin/share/base/runtime/core.odin"))
	// A relative import that leaves the folder of the module.
	testing.expect(t, !place("/home/someone/projects/shared/text.odin"))
	// A folder beside the folder of the module whose name starts with it.
	testing.expect(t, !place("/home/someone/projects/my_process_tools/main.odin"))
	// A folder of the system that is not its library.
	testing.expect(t, !place("/home/someone/modus/src/modulus/enter.odin"))
	testing.expect(t, !place("/home/someone/modus/src/processes/tally/main.odin"))
	// With no answer of the compiler, the layout of its installation.
	testing.expect(t, outside_module_source_has_a_place("/nix/store/other/share/core/fmt/fmt.odin", module_folder, library_folder, ""))
	testing.expect(t, !outside_module_source_has_a_place("/home/someone/projects/shared/text.odin", module_folder, library_folder, ""))
}

// The path of a source of an outside module in a debug object has the
// name of the folder of the module, and no folder above it.
@(test)
outside_module_source_path_in_a_debug_object :: proc(t: ^testing.T) {
	recorded, is_outside := outside_source_path("/home/someone/projects/my_process/main.odin", "/home/someone/projects/my_process")
	testing.expect(t, is_outside)
	testing.expect_value(t, recorded, "my_process/main.odin")
	recorded, is_outside = outside_source_path("/home/someone/projects/my_process/parts/draw.odin", "/home/someone/projects/my_process")
	testing.expect(t, is_outside)
	testing.expect_value(t, recorded, "my_process/parts/draw.odin")
	// A folder at the root of the file system.
	recorded, is_outside = outside_source_path("/my_process/main.odin", "/my_process")
	testing.expect(t, is_outside)
	testing.expect_value(t, recorded, "my_process/main.odin")
	// A source of the system, and a build of a module of the system.
	_, is_outside = outside_source_path("/home/someone/modus/src/library/modus/system/system.odin", "/home/someone/projects/my_process")
	testing.expect(t, !is_outside)
	_, is_outside = outside_source_path("/home/someone/projects/my_process/main.odin", "")
	testing.expect(t, !is_outside)
	_, is_outside = outside_source_path("/home/someone/projects/my_process_tools/main.odin", "/home/someone/projects/my_process")
	testing.expect(t, !is_outside)
}

// A name of a module: what an entry of a boot image holds.
@(test)
module_names :: proc(t: ^testing.T) {
	testing.expect(t, module_name_is_valid("tally"))
	testing.expect(t, module_name_is_valid("quic_echo2"))
	testing.expect(t, module_name_is_valid(strings.repeat("a", MODULE_NAME_BYTES_MOST, context.temp_allocator)))
	testing.expect(t, !module_name_is_valid(strings.repeat("a", MODULE_NAME_BYTES_MOST + 1, context.temp_allocator)))
	testing.expect(t, !module_name_is_valid(""))
	testing.expect(t, !module_name_is_valid("my-process"))
	testing.expect(t, !module_name_is_valid("my process"))
	testing.expect(t, !module_name_is_valid("../tally"))
}

// Compiler flag construction produces distinct flags for Freestanding vs Modus,
// shares one helper between checkout and SDK builds, and keeps kernels on
// Freestanding.
@(test)
module_compile_flags_for_freestanding_and_modus :: proc(t: ^testing.T) {
	freestanding_row := foundation.Module_Build {
		name    = "hello_freestanding",
		source  = "/tmp/hello_freestanding",
		defines = {"SAMPLE=1"},
		target  = .Freestanding,
	}
	modus_row := foundation.Module_Build {
		name    = "core_probe",
		source  = "/tmp/core_probe",
		defines = {"SAMPLE=1"},
		target  = .Modus,
	}
	modus_lib_row := foundation.Module_Build {
		name    = "core_lib",
		source  = "/tmp/core_lib",
		library = true,
		target  = .Modus,
	}
	kernel_row := foundation.Module_Build {
		name   = "kernel",
		source = foundation.SOURCE_FOLDER_KERNEL,
		kernel = true,
		target = .Modus,
	}

	free_cmd := module_compile_command(freestanding_row, .Speed)
	testing.expect(t, slice.contains(free_cmd, "-target:freestanding_amd64_sysv"), "Freestanding uses freestanding_amd64_sysv")
	testing.expect(t, slice.contains(free_cmd, "-no-entry-point"), "Freestanding passes -no-entry-point")
	testing.expect(t, slice.contains(free_cmd, "-default-to-nil-allocator"), "Freestanding passes -default-to-nil-allocator")
	testing.expect(t, !slice.contains(free_cmd, "-no-crt"), "Freestanding does not pass -no-crt")

	modus_cmd := module_compile_command(modus_row, .Speed)
	testing.expect(t, slice.contains(modus_cmd, "-target:modus_amd64"), "Modus uses modus_amd64")
	testing.expect(t, slice.contains(modus_cmd, "-no-crt"), "Modus passes -no-crt")
	testing.expect(t, !slice.contains(modus_cmd, "-no-entry-point"), "Modus executable compiles runtime entry and main()")
	testing.expect(t, !slice.contains(modus_cmd, "-default-to-nil-allocator"), "Modus uses runtime heap allocator")
	testing.expect(t, !slice.contains(modus_cmd, "-target:freestanding_amd64_sysv"), "Modus does not pass freestanding target")

	// Under Optimization_Mode.None, Modus omits -no-thread-local so any stray
	// @(thread_local) fails module conversion rather than becoming a racy global.
	modus_none_cmd := module_compile_command(modus_row, .None)
	testing.expect(t, slice.contains(modus_none_cmd, "-o:none"), "Modus None passes -o:none")
	testing.expect(t, slice.contains(modus_none_cmd, "-use-single-module"), "Modus None passes -use-single-module")
	testing.expect(t, !slice.contains(modus_none_cmd, "-no-thread-local"), "Modus None never passes -no-thread-local")

	// Library modules targeting Modus have no main() and pass -no-entry-point.
	modus_lib_cmd := module_compile_command(modus_lib_row, .Speed)
	testing.expect(t, slice.contains(modus_lib_cmd, "-target:modus_amd64"), "Modus library uses modus_amd64")
	testing.expect(t, slice.contains(modus_lib_cmd, "-no-crt"), "Modus library passes -no-crt")
	testing.expect(t, slice.contains(modus_lib_cmd, "-no-entry-point"), "Modus library passes -no-entry-point")
	testing.expect(t, !slice.contains(modus_lib_cmd, "-default-to-nil-allocator"), "Modus library uses runtime allocator")

	// SDK builds call the same flag builder with no internal collection.
	sdk_cmd := odin_module_compile_command({
		source                   = "/tmp/core_probe",
		target                   = .Modus,
		library                  = false,
		optimization             = .Speed,
		dependency_file          = "/tmp/work/dependencies.json",
		public_library_folder    = "/tmp/sdk/library/modus",
		llvm_ir_folder           = "/tmp/work/llvm_ir",
		include_internal_library = false,
		with_debug_info          = true,
		defines                  = {"SAMPLE=1"},
	})
	testing.expect(t, slice.contains(sdk_cmd[:], "-target:modus_amd64"), "SDK Modus uses modus_amd64")
	testing.expect(t, slice.contains(sdk_cmd[:], "-no-crt"), "SDK Modus passes -no-crt")
	testing.expect(t, !slice.contains(sdk_cmd[:], "-no-entry-point"), "SDK Modus executable omits -no-entry-point")
	testing.expect(t, !slice.contains(sdk_cmd[:], foundation.INTERNAL_LIBRARY_FLAG), "SDK never passes internal collection")
	testing.expect(t, slice.contains(sdk_cmd[:], "-collection:modus=/tmp/sdk/library/modus"), "SDK passes public modus collection")

	// A kernel row always resolves to Freestanding even if target was set.
	kernel_cmd := module_compile_command(kernel_row, .Speed)
	testing.expect(t, slice.contains(kernel_cmd, "-target:freestanding_amd64_sysv"), "kernel always stays freestanding")
	testing.expect(t, !slice.contains(kernel_cmd, "-target:modus_amd64"), "kernel never targets modus")
}

// Compiler-owned base/ and core/ files are allowed for outside modules
// targeting Modus while vendor/ is refused and src/ system modules still
// strictly forbid core: imports.
@(test)
compiler_libraries_and_source_boundary_for_modus :: proc(t: ^testing.T) {
	module_folder :: "/home/someone/projects/core_probe"
	library_folder :: "/home/someone/modus/src/library/modus"
	compiler_folder :: "/nix/store/odin/share"

	// Compiler library classification.
	testing.expect_value(t, compiler_source_library_of_path("/nix/store/odin/share/base/runtime/entry_modus.odin", compiler_folder), Compiler_Source_Library.Base)
	testing.expect_value(t, compiler_source_library_of_path("/nix/store/odin/share/core/os/os.odin", compiler_folder), Compiler_Source_Library.Core)
	testing.expect_value(t, compiler_source_library_of_path("/nix/store/odin/share/vendor/sdl2/sdl2.odin", compiler_folder), Compiler_Source_Library.None)
	testing.expect_value(t, compiler_source_library_of_path("/nix/store/other/share/base/runtime/core.odin", ""), Compiler_Source_Library.Base)
	testing.expect_value(t, compiler_source_library_of_path("/nix/store/other/share/core/sync/mutex.odin", ""), Compiler_Source_Library.Core)
	testing.expect_value(t, compiler_source_library_of_path("/nix/store/other/share/vendor/glfw/glfw.odin", ""), Compiler_Source_Library.None)

	// Outside module targeting Modus accepts base/ and core/, refuses vendor/ and internal/.
	testing.expect(t, outside_module_source_has_a_place("/nix/store/odin/share/base/runtime/entry_modus.odin", module_folder, library_folder, compiler_folder, .Modus))
	testing.expect(t, outside_module_source_has_a_place("/nix/store/odin/share/core/os/os.odin", module_folder, library_folder, compiler_folder, .Modus))
	testing.expect(t, !outside_module_source_has_a_place("/nix/store/odin/share/vendor/sdl2/sdl2.odin", module_folder, library_folder, compiler_folder, .Modus))
	testing.expect(t, !outside_module_source_has_a_place("/nix/store/odin/share/vendor/sdl2/sdl2.odin", module_folder, library_folder, compiler_folder, .Freestanding))
	testing.expect(t, !outside_module_source_has_a_place("/home/someone/modus/src/library/internal/storage/storage_tree/storage_tree.odin", module_folder, library_folder, compiler_folder, .Modus))
	testing.expect(t, !outside_module_source_has_a_place("/home/someone/modus/src/modulus/enter.odin", module_folder, library_folder, compiler_folder, .Modus))

	// System, kernel, and contract sources under src/ still strictly forbid core:.
	testing.expect(t, !library_import_is_allowed("core:os", {kind = .System}), "src/ system module forbids core:os")
	testing.expect(t, !library_import_is_allowed("core:fmt", {kind = .System}), "src/ system module forbids core:fmt")
	testing.expect(t, !library_import_is_allowed("core:time", {kind = .Kernel}), "src/modulus kernel forbids core:time")
	testing.expect(t, !library_import_is_allowed("core:sync", {kind = .Contract}), "src/library/modus/contract forbids core:sync")

	// facts_of_sources skips compiler-owned base/ and core/ files without parsing them.
	compiler_sources := []Fact_Source {
		{path = "/nix/store/odin/share/base/runtime/entry_modus.odin", source = "package runtime\n// contains log_fact text but is compiler-owned\n"},
		{path = "/nix/store/odin/share/core/os/os.odin", source = "package os\n// not valid @log_fact syntax: @(\n"},
	}
	facts, ok := facts_of_sources(compiler_sources, compiler_folder)
	testing.expect(t, ok, "compiler-owned base/ and core/ sources are skipped cleanly by facts_of_sources")
	testing.expect_value(t, len(facts), 0)
}

// Target Modus synthesizes the runtime `entry` export for non-library modules
// with `main :: proc()`, refuses missing `main` or manual `@(export) entry`,
// and leaves library and Freestanding packages unchanged.
@(test)
describe_package_target_modus_entry_synthesis_and_refusals :: proc(t: ^testing.T) {
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	root_dir := fmt.tprintf("%s/modus_target_describe_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(root_dir)
	defer _ = os.remove_all(root_dir)

	write_pkg :: proc(t: ^testing.T, dir, source: string) {
		testing.expect(t, os.make_directory_all(dir) == nil, "create temp package dir")
		testing.expect(t, os.write_entire_file(foundation.join(dir, "/main.odin"), source) == nil, "write temp main.odin")
	}

	// Refusal 1: Modus executable missing main :: proc().
	missing_main_dir := foundation.join(root_dir, "/missing_main")
	write_pkg(t, missing_main_dir, "// Probe missing main.\npackage probe\n\nimport \"core:fmt\"\n\nhelper :: proc() { _ = fmt.tprint }\n")
	_, missing_ok := describe_package_for_target(missing_main_dir, .Modus, library = false)
	testing.expect(t, !missing_ok, "Modus non-library package without main is refused")

	// Refusal 2: Modus executable with colliding manual @(export) entry.
	manual_entry_dir := foundation.join(root_dir, "/manual_entry")
	write_pkg(t, manual_entry_dir, "// Probe with manual entry.\npackage probe\n\nmain :: proc() {}\n\n@(export, link_name = \"entry\")\nentry :: proc \"c\" (_: rawptr) -> ! { for {} }\n")
	_, manual_ok := describe_package_for_target(manual_entry_dir, .Modus, library = false)
	testing.expect(t, !manual_ok, "Modus non-library package exporting entry manually is refused")

	// Edge: Freestanding package without entry succeeds with description_has_entry == false.
	free_no_entry_dir := foundation.join(root_dir, "/free_no_entry")
	write_pkg(t, free_no_entry_dir, "// Freestanding library.\npackage probe\n\n// add returns the sum.\n@(export, link_name = \"add\")\nadd :: proc \"c\" (a, b: i64) -> i64 { return a + b }\n")
	free_desc, free_ok := describe_package_for_target(free_no_entry_dir, .Freestanding, library = false)
	testing.expect(t, free_ok, "Freestanding package without entry is described")
	testing.expect(t, !description_has_entry(free_desc), "Freestanding does not synthesize entry")
	testing.expect_value(t, len(free_desc.exports), 1)

	// Edge: Modus library module without main succeeds and synthesizes no entry.
	modus_lib_dir := foundation.join(root_dir, "/modus_lib")
	write_pkg(t, modus_lib_dir, "// Modus library using core.\npackage probe\n\nimport \"core:strings\"\n\n// count returns zero.\n@(export, link_name = \"count\")\ncount :: proc \"c\" () -> i64 { _ = strings.clone; return 0 }\n")
	lib_desc, lib_ok := describe_package_for_target(modus_lib_dir, .Modus, library = true)
	testing.expect(t, lib_ok, "Modus library package without main is described")
	testing.expect(t, !description_has_entry(lib_desc), "Modus library does not synthesize entry")
	testing.expect_value(t, len(lib_desc.exports), 1)

	// Success: Modus executable with core: imports and main :: proc() synthesizes entry.
	modus_exec_dir := foundation.join(root_dir, "/modus_exec")
	write_pkg(t, modus_exec_dir, "// Core probe module.\npackage core_probe\n\nimport \"core:fmt\"\nimport \"core:os\"\nimport \"core:sync\"\n\n// ping returns one.\n@(export, link_name = \"ping\")\nping :: proc \"c\" () -> i64 { return 1 }\n\nmain :: proc() {\n\t_ = fmt.println\n\t_ = os.stdout\n\t_ = sync.Mutex{}\n}\n")
	exec_desc, exec_ok := describe_package_for_target(modus_exec_dir, .Modus, library = false)
	testing.expect(t, exec_ok, "Modus executable package with main and core: imports is described")
	testing.expect(t, description_has_entry(exec_desc), "Modus executable synthesizes entry export")
	testing.expect_value(t, len(exec_desc.exports), 2)
	if len(exec_desc.exports) == 2 {
		testing.expect_value(t, exec_desc.exports[0].name, "ping")
		testing.expect_value(t, exec_desc.exports[1].name, ENTRY_NAME)
	}
}
