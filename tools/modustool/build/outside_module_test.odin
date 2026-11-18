package build

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// A module build file with each key gives each field of a row.
@(test)
module_build_file_with_each_key :: proc(t: ^testing.T) {
	file, problem := module_build_file_parse("name: my_process\nimports: drawing  cryptography\n\ndefines: DRAWING_THROUGH_MODULE=true SIZE=4\nlibrary: yes\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, file.name, "my_process")
	testing.expect(t, slice.equal(file.imports, []string{"drawing", "cryptography"}), "the imports keep their order")
	testing.expect(t, slice.equal(file.defines, []string{"DRAWING_THROUGH_MODULE=true", "SIZE=4"}), "the defines keep their order")
	testing.expect(t, file.library)
}

// The name alone is a whole file: no import, no setting, not a library
// module. An empty value of a list is an empty list.
@(test)
module_build_file_with_the_name_alone :: proc(t: ^testing.T) {
	file, problem := module_build_file_parse("name: tally\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, file.name, "tally")
	testing.expect_value(t, len(file.imports), 0)
	testing.expect_value(t, len(file.defines), 0)
	testing.expect(t, !file.library)
	file, problem = module_build_file_parse("imports:\r\nname: tally\r\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(file.imports), 0)
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
	}
	for item in cases {
		_, problem := module_build_file_parse(item.text)
		testing.expectf(t, strings.contains(problem, item.problem), "%q gives %q, not a sentence with %q", item.text, problem, item.problem)
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
	library_folder :: "/home/someone/modus/src/library"
	compiler_folder :: "/nix/store/odin/share"
	place :: proc(path: string) -> bool {
		return outside_module_source_has_a_place(path, module_folder, library_folder, compiler_folder)
	}
	testing.expect(t, place("/home/someone/projects/my_process/main.odin"))
	testing.expect(t, place("/home/someone/projects/my_process/parts/draw.odin"))
	testing.expect(t, place("/home/someone/modus/src/library/support/system/system.odin"))
	testing.expect(t, place("/nix/store/odin/share/base/runtime/core.odin"))
	// A relative import that leaves the folder of the module.
	testing.expect(t, !place("/home/someone/projects/shared/text.odin"))
	// A folder beside the folder of the module whose name starts with it.
	testing.expect(t, !place("/home/someone/projects/my_process_tools/main.odin"))
	// A folder of the system that is not its library.
	testing.expect(t, !place("/home/someone/modus/src/kernel/enter.odin"))
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
	_, is_outside = outside_source_path("/home/someone/modus/src/library/support/system/system.odin", "/home/someone/projects/my_process")
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
