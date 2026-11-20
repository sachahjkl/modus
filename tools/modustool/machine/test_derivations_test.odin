#+feature dynamic-literals
package machine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// A file of the build that names the compiler in the store, or the time of
// one build, is no test input, nor is a path that leaves the folder. The
// file name of a refused folder at the end of a path is a file, which stays.
@(test)
test_inputs_refuse_what_names_the_store :: proc(t: ^testing.T) {
	refused_suffixes := TEST_INPUT_REFUSED_SUFFIXES
	for suffix in refused_suffixes {
		path := strings.concatenate({"modules/kernel", suffix}, context.temp_allocator)
		testing.expectf(t, !test_input_kept(path), "%s is refused", path)
	}
	refused_folders := TEST_INPUT_REFUSED_FOLDERS
	for folder in refused_folders {
		at_the_top := strings.concatenate({folder, "/kernel.module"}, context.temp_allocator)
		below := strings.concatenate({"modules/kernel/", folder, "/kernel.module"}, context.temp_allocator)
		testing.expectf(t, !test_input_kept(at_the_top), "%s is refused", at_the_top)
		testing.expectf(t, !test_input_kept(below), "%s is refused", below)
	}
	for path in ([]string{"", "/boot_volume.img", "../boot_volume.img", "modules/../boot_volume.img", "modules//kernel.module", "./boot_volume.img", "modules/", "boot_volume.img.txt"}) {
		testing.expectf(t, !test_input_kept(path), "%q is refused", path)
	}
	for path in ([]string{"boot_volume.img", "boot_volume.img.signed_by", "boot.image", "modules/kernel.module", "modules/kernel.debug", "fonts/font_outlines.bin", "pointers/system.pointers", "objects", "modules/tool.module"}) {
		testing.expectf(t, test_input_kept(path), "%s is kept", path)
	}
}

// Only a boot volume of a part and a boot image are links: the signature
// beside a volume, and a disk that is no boot volume of a part, are copies
// that a part can write.
@(test)
test_inputs_link_the_volumes_only :: proc(t: ^testing.T) {
	volume_paths := test_parts_volume_paths()
	testing.expect(t, len(volume_paths) > 0, "the parts have boot volumes")
	for path in ([]string{"boot_volume.img.signed_by", "img", "boot_volume.img/x", "modules/kernel.module", "boot.images", "scratch_disk.img", "build/boot_volume.img"}) {
		testing.expectf(t, !test_input_is_linked(path, volume_paths), "%s is a copy", path)
	}
	testing.expect(t, !test_input_is_linked("boot_volume.img", nil), "with no volume, a volume file is a copy")
	for path in ([]string{"boot_volume.img", "boot_volume_self_test_7.img", "boot_volume_fails.img", "boot.image"}) {
		testing.expectf(t, test_input_is_linked(path, volume_paths), "%s is a link", path)
	}
}

// The count of the checks of an output: one number of 0 or more. A sign, a
// space, a second number and an empty file are refused.
@(test)
checks_passed_of_text_refuses_what_is_no_count :: proc(t: ^testing.T) {
	for text in ([]string{"", "\n", "-1\n", "+1\n", " 1\n", "1 2\n", "1\t\n", "x\n", "1x\n", "1_0\n", "0x10\n", "9223372036854775808\n"}) {
		_, ok := checks_passed_of_text(text)
		testing.expectf(t, !ok, "%q is refused", text)
	}
	for row in ([]struct {
			text:  string,
			count: int,
		}{{"0\n", 0}, {"1\n", 1}, {"42", 42}, {"9223372036854775807\n", 9223372036854775807}}) {
		count, ok := checks_passed_of_text(row.text)
		testing.expectf(t, ok && count == row.count, "%q gives %d", row.text, row.count)
	}
}

// An argument of the join names a part of the table and a folder; each
// other form is refused.
@(test)
test_join_argument_refuses_each_other_form :: proc(t: ^testing.T) {
	for argument in ([]string{"", "main", "=x", "main=", "=", "netwrok=x", "Main=x", "main x"}) {
		_, problem := test_join_argument_read(argument)
		testing.expectf(t, problem != "", "%q is refused", argument)
	}
	joined, problem := test_join_argument_read("main=/nix/store/a-machine-test-main")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, joined.part, "main")
	testing.expect_value(t, joined.folder, "/nix/store/a-machine-test-main")
	with_equals, equals_problem := test_join_argument_read("tcp=folder=x")
	testing.expect_value(t, equals_problem, "")
	testing.expect_value(t, with_equals.folder, "folder=x")
}

// A join holds each part of the table once: it refuses no part, a part
// that lacks, a part twice and a part that the table does not have.
@(test)
test_join_refuses_a_join_that_is_not_the_whole_test :: proc(t: ^testing.T) {
	names := []string{"main", "tcp", "random"}
	whole := []Joined_Output{{part = "main"}, {part = "tcp"}, {part = "random"}}
	testing.expect(t, strings.contains(test_join_parts_problem(nil, names), "no output of the test part main"))
	testing.expect(t, strings.contains(test_join_parts_problem(whole[:2], names), "no output of the test part random"))
	twice := []Joined_Output{{part = "main"}, {part = "tcp"}, {part = "random"}, {part = "tcp"}}
	testing.expect(t, strings.contains(test_join_parts_problem(twice, names), "the test part tcp 2 times"))
	extra := []Joined_Output{{part = "main"}, {part = "tcp"}, {part = "random"}, {part = "netwrok"}}
	testing.expect(t, strings.contains(test_join_parts_problem(extra, names), "netwrok, which is no test part"))
	testing.expect_value(t, test_join_parts_problem(whole, names), "")
}

// The names of the parts that the flake reads are those of the table, in
// its order, as a JSON array.
@(test)
test_parts_names_text_is_the_table :: proc(t: ^testing.T) {
	text := test_parts_names_text(test_parts[:])
	value, parse_error := json.parse_string(text, allocator = context.temp_allocator)
	testing.expect_value(t, parse_error, json.Error.None)
	array, is_array := value.(json.Array)
	testing.expect(t, is_array, "the names are a JSON array")
	testing.expect_value(t, len(array), len(test_parts))
	for part, place in test_parts {
		if place >= len(array) {
			break
		}
		name, is_text := array[place].(json.String)
		testing.expectf(t, is_text && name == part.name, "the place %d is the part %s", place, part.name)
	}
	testing.expect_value(t, test_parts_names_text(nil), "[]\n")
}

// The form `test <part> from <folder>`: a part of the table, the word, and
// a folder. Each other form is refused.
@(test)
test_from_a_folder_of_test_inputs :: proc(t: ^testing.T) {
	for arguments in ([][]string{{"main", "from"}, {"main", "from", ""}, {"main", "to", "x"}, {"netwrok", "from", "x"}, {"main", "from", "x", "y"}, {"from", "main", "x"}}) {
		testing.expectf(t, test_arguments_problem(arguments) != "", "%v is refused", arguments)
	}
	_, given_for_one := test_arguments_give_inputs([]string{"main"})
	testing.expect(t, !given_for_one, "one part alone names no folder")
	arguments := []string{"main", TEST_FROM_WORD, "/nix/store/a-modus-test-inputs"}
	testing.expect_value(t, test_arguments_problem(arguments), "")
	folder, given := test_arguments_give_inputs(arguments)
	testing.expect(t, given, "a part from a folder names it")
	testing.expect_value(t, folder, "/nix/store/a-modus-test-inputs")
}

// The file of the times of a part takes the name of its part in the join;
// the file of the times of the host checks, and each other file, keep
// their names.
@(test)
joined_file_names_keep_each_part_apart :: proc(t: ^testing.T) {
	testing.expect_value(t, joined_file_name("main", "test_times.txt"), "test_times_main.txt")
	testing.expect_value(t, joined_file_name("", "test_times.txt"), "test_times.txt")
	testing.expect_value(t, joined_file_name("main", "test_output.txt"), "test_output.txt")
	testing.expect_value(t, joined_file_name("main", "test_times.txt.old"), "test_times.txt.old")
}

JOIN_TEST_FOLDER :: foundation.BUILD_FOLDER + "/test_derivations_join_test"

@(private = "file")
join_test_output_write :: proc(t: ^testing.T, folder, count_text: string, logs, pictures: []string) {
	for sub_folder in ([2]string{JOINED_LOG_FOLDER_NAME, JOINED_PICTURE_FOLDER_NAME}) {
		testing.expect(t, foundation.make_folder(strings.concatenate({folder, "/", sub_folder}, context.temp_allocator)))
	}
	if count_text != "" {
		path := strings.concatenate({folder, "/", JOINED_LOG_FOLDER_NAME, "/", CHECKS_PASSED_FILE_NAME}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, count_text) == nil)
	}
	for log in logs {
		path := strings.concatenate({folder, "/", JOINED_LOG_FOLDER_NAME, "/", log}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, folder) == nil)
	}
	for picture in pictures {
		path := strings.concatenate({folder, "/", JOINED_PICTURE_FOLDER_NAME, "/", picture}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, folder) == nil)
	}
}

// The join refuses a target that exists, an output with no count of its
// checks, and two outputs that write one picture or one log; then it joins
// the logs and the pictures of each output, with the file of the times of
// each part under its name, and the sum of the counts.
@(test)
outputs_join_refuses_two_writers_of_one_file :: proc(t: ^testing.T) {
	_ = os.remove_all(JOIN_TEST_FOLDER)
	defer {
		_ = os.remove_all(JOIN_TEST_FOLDER)
	}
	host := JOIN_TEST_FOLDER + "/host"
	first := JOIN_TEST_FOLDER + "/first"
	second := JOIN_TEST_FOLDER + "/second"
	no_count := JOIN_TEST_FOLDER + "/no_count"
	bad_count := JOIN_TEST_FOLDER + "/bad_count"
	same_picture := JOIN_TEST_FOLDER + "/same_picture"
	same_log := JOIN_TEST_FOLDER + "/same_log"
	join_test_output_write(t, host, "3\n", {"reproducible_build.txt"}, nil)
	join_test_output_write(t, first, "5\n", {"test_output.txt", "test_times.txt"}, {"console.png"})
	join_test_output_write(t, second, "0\n", {"test_output_tcp_1.txt", "test_times.txt"}, {"tcp.png"})
	join_test_output_write(t, no_count, "", {"test_output_x.txt"}, nil)
	join_test_output_write(t, bad_count, "-2\n", {"test_output_y.txt"}, nil)
	join_test_output_write(t, same_picture, "1\n", {"test_output_z.txt"}, {"console.png"})
	join_test_output_write(t, same_log, "1\n", {"test_output.txt"}, nil)

	refused := [][]Joined_Output {
		{{folder = host}, {part = "main", folder = first}, {part = "tcp", folder = no_count}},
		{{folder = host}, {part = "main", folder = first}, {part = "tcp", folder = bad_count}},
		{{folder = host}, {part = "main", folder = first}, {part = "tcp", folder = same_picture}},
		{{folder = host}, {part = "main", folder = first}, {part = "tcp", folder = same_log}},
	}
	for refused_outputs, place in refused {
		refused_target := fmt.tprintf("%s/refused_%d", JOIN_TEST_FOLDER, place)
		_, refused_ok := outputs_join(refused_target, refused_outputs)
		testing.expectf(t, !refused_ok, "the join %d is refused", place)
	}

	target :: JOIN_TEST_FOLDER + "/joined"
	outputs := []Joined_Output{{folder = host}, {part = "main", folder = first}, {part = "tcp", folder = second}}
	counts, ok := outputs_join(target, outputs)
	testing.expect(t, ok, "the join of distinct files passes")
	testing.expect_value(t, counts.checks_passed, 8)
	testing.expect_value(t, counts.pictures, 2)
	testing.expect_value(t, counts.logs, 5)
	for name in ([]string{"reproducible_build.txt", "test_output.txt", "test_output_tcp_1.txt", "test_times_main.txt", "test_times_tcp.txt"}) {
		testing.expectf(t, os.exists(strings.concatenate({target, "/", JOINED_LOG_FOLDER_NAME, "/", name}, context.temp_allocator)), "the join holds %s", name)
	}
	testing.expect(t, !os.exists(target + "/" + JOINED_LOG_FOLDER_NAME + "/test_times.txt"), "no file of the times of the whole test")
	count_text, count_read := foundation.read_text_file_quiet(target + "/" + JOINED_LOG_FOLDER_NAME + "/" + CHECKS_PASSED_FILE_NAME)
	testing.expect(t, count_read, "the join writes the count of its checks")
	testing.expect_value(t, count_text, "8\n")
	_, again := outputs_join(target, outputs)
	testing.expect(t, !again, "a join into a folder that exists is refused")
}

// A change that must leave the parts alone is refused when a part has
// another derivation, when a tree lacks a part or has one more, and when the
// change did not reach the whole build: such a check would prove nothing.
@(test)
part_derivations_compare_refuses_each_difference :: proc(t: ^testing.T) {
	names := []string{"main", "tcp"}
	before := map[string]string{"main" = "/nix/store/a-main.drv", "tcp" = "/nix/store/a-tcp.drv"}
	defer delete(before)
	same := map[string]string{"main" = "/nix/store/a-main.drv", "tcp" = "/nix/store/a-tcp.drv"}
	defer delete(same)
	other := map[string]string{"main" = "/nix/store/a-main.drv", "tcp" = "/nix/store/b-tcp.drv"}
	defer delete(other)
	lacking := map[string]string{"main" = "/nix/store/a-main.drv"}
	defer delete(lacking)
	more := map[string]string{"main" = "/nix/store/a-main.drv", "tcp" = "/nix/store/a-tcp.drv", "netwrok" = "/nix/store/a-netwrok.drv"}
	defer delete(more)
	empty := map[string]string{"main" = "", "tcp" = ""}
	defer delete(empty)

	testing.expect(t, len(part_derivations_compare(before, same, names, "/nix/store/a-build.drv", "/nix/store/a-build.drv", "a change")) == 1, "the same whole build proves nothing")
	testing.expect(t, len(part_derivations_compare(before, same, names, "", "", "a change")) == 1, "no whole build proves nothing")
	testing.expect(t, len(part_derivations_compare(before, other, names, "/nix/store/a-build.drv", "/nix/store/b-build.drv", "a change")) == 1, "another derivation of a part is refused")
	testing.expect(t, len(part_derivations_compare(before, lacking, names, "/nix/store/a-build.drv", "/nix/store/b-build.drv", "a change")) == 1, "a part that lacks is refused")
	testing.expect(t, len(part_derivations_compare(before, more, names, "/nix/store/a-build.drv", "/nix/store/b-build.drv", "a change")) == 1, "a part that the table does not have is refused")
	testing.expect(t, len(part_derivations_compare(empty, empty, names, "/nix/store/a-build.drv", "/nix/store/b-build.drv", "a change")) == 2, "an empty derivation is refused")
	testing.expect(t, len(part_derivations_compare(before, same, nil, "/nix/store/a-build.drv", "/nix/store/b-build.drv", "a change")) == 4, "with no part, each part of each tree is one more")
	testing.expect(t, len(part_derivations_compare(before, same, names, "/nix/store/a-build.drv", "/nix/store/b-build.drv", "a change")) == 0, "the same derivations after a change of the build pass")
}

// The reader of the attribute sets that Nix prints takes an object of texts
// only.
@(test)
text_map_of_json_takes_an_object_of_texts :: proc(t: ^testing.T) {
	for text in ([]string{"", "[]", "\"x\"", "{\"main\": 1}", "{\"main\": [\"x\"]}", "{\"main\": \"x\"", "null"}) {
		_, ok := text_map_of_json(text)
		testing.expectf(t, !ok, "%q is refused", text)
	}
	texts, ok := text_map_of_json("{\"main\": \"/nix/store/a\", \"tcp\": \"/nix/store/b\"}")
	testing.expect(t, ok, "an object of texts is read")
	testing.expect_value(t, len(texts), 2)
	testing.expect_value(t, texts["main"], "/nix/store/a")
	testing.expect_value(t, texts["tcp"], "/nix/store/b")
}

// The kinds of files that the test inputs keep, and those that they drop:
// the linked file and the list of the compiler name the compiler in the
// store, and a build record holds the time of one build.
@(test)
build_file_kinds_kept_and_dropped :: proc(t: ^testing.T) {
	dropped := Build_File_Kinds{.Linked_File, .Dependency_List, .Build_Record}
	for kind in Build_File_Kind {
		testing.expectf(t, build_file_kind_is_test_input(kind) == (kind not_in dropped), "the %v of a module is a test input: %v", kind, kind not_in dropped)
		testing.expectf(t, build_file_of_module(kind, "kernel") != "", "the %v of a module is in the build folder", kind)
	}
	testing.expect_value(t, build_file_of_module(.Module_Source_List, "kernel"), "modules/kernel/sources.list")
	testing.expect_value(t, build_file_of_module(.Reached_Fact_List, "kernel"), "modules/kernel/reached_facts.list")
	testing.expect_value(t, build_file_of_module(.Dependency_List, "kernel"), "modules/kernel/dependencies.json")
}

// A part that declares a kind of file that the test inputs drop is refused
// before any machine, with its name; each part of the table passes.
@(test)
test_part_reads_problem_refuses_a_dropped_kind :: proc(t: ^testing.T) {
	for kind in ([]Build_File_Kind{.Linked_File, .Dependency_List, .Build_Record}) {
		reader := Test_Part{name = "reader"}
		reader.reads += {kind}
		problem := test_part_reads_problem(reader)
		testing.expectf(t, strings.contains(problem, "the test part reader reads"), "a part that reads the %v is refused: %q", kind, problem)
	}
	both := Test_Part{name = "both", reads = {.Module_Source_List, .Linked_File}}
	testing.expect(t, test_part_reads_problem(both) != "", "one dropped kind among kept ones is refused")
	for part in test_parts {
		testing.expect_value(t, test_part_reads_problem(part), "")
	}
}

// The inputs must hold each file of each kind that a part reads, for each
// module of the table: a missing file, no file, and a dropped kind whose
// files the folder holds anyway are refused; the whole set passes.
@(test)
test_part_build_files_problem_refuses_a_missing_file :: proc(t: ^testing.T) {
	part, found := test_part_find("host_modules")
	testing.expect(t, found, "the table has the part host_modules")
	if !found {
		return
	}
	empty := make(map[string]bool, allocator = context.temp_allocator)
	testing.expect(t, test_part_build_files_problem(part^, empty) != "", "no file is refused")
	held := make(map[string]bool, allocator = context.temp_allocator)
	for kind in Build_File_Kind {
		for module_build in foundation.module_builds {
			held[build_file_of_module(kind, module_build.name)] = true
		}
	}
	missing := build_file_of_module(.Reached_Fact_List, foundation.module_builds[len(foundation.module_builds) - 1].name)
	held[missing] = false
	problem := test_part_build_files_problem(part^, held)
	testing.expectf(t, strings.contains(problem, missing), "the missing %s is named: %q", missing, problem)
	held[missing] = true
	linked := Test_Part{name = "linked", reads = {.Linked_File}}
	testing.expect(t, test_part_build_files_problem(linked, held) != "", "a dropped kind is refused even when the folder holds its files")
	testing.expect_value(t, test_part_build_files_problem(part^, held), "")
}

@(private = "file")
Named_Build_File :: struct {
	procedure: string,
	kind:      Build_File_Kind,
}

@(private = "file")
byte_of_an_identifier :: proc(character: u8) -> bool {
	return character == '_' || (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9')
}

// build_files_named_in_source adds each kind of file that a procedure of
// the top level of a source names, by the markers of the kinds. A comment
// and a table outside a procedure name nothing.
@(private = "file")
build_files_named_in_source :: proc(source: string, named: ^[dynamic]Named_Build_File) {
	procedure := ""
	rest := source
	for whole_line in strings.split_lines_iterator(&rest) {
		if whole_line == "}" {
			procedure = ""
			continue
		}
		line := whole_line
		if comment := strings.index(line, "//"); comment >= 0 {
			line = line[:comment]
		}
		if declaration := strings.index(line, " :: proc"); declaration > 0 && byte_of_an_identifier(line[0]) {
			procedure = line[:declaration]
			continue
		}
		if procedure == "" {
			continue
		}
		for markers, kind in build_file_kind_markers {
			for marker in markers {
				if strings.contains(line, marker) {
					append(named, Named_Build_File{procedure = procedure, kind = kind})
					break
				}
			}
		}
	}
}

// The procedures that name a kind of file that the test inputs drop: each
// is a step of the build, of the build of an outside module in its own
// folder, or of `check`, which runs where the build is, and no test part
// runs it. A new reader of such a file must come into this list, or into
// none: then a part would read a file that its inputs lack.
@(private = "file")
dropped_file_readers := [?]string {
	// The build of the modules, of the boot volumes and of the tool.
	"boot_program_compile_command",
	"boot_volume_dependency_file",
	"boot_volume_record_path",
	"boot_volume_record_write",
	"boot_volumes_build",
	"boot_volumes_kept",
	"module_compile",
	"module_compile_command",
	"module_convert",
	"module_dependency_file",
	"module_linked_file",
	"module_records_write",
	"module_source_list_write",
	"module_steps_of",
	"tool_build",
	"tool_build_current",
	// The build of an outside module, by its own compiler, in its folder.
	"outside_module_sources_hold",
	// The path of each kind, which reads no file.
	"build_file_of_module",
	// A test of the build that `check` runs after its build.
	"test_debug_objects",
}

// undeclared_reads_problems gives, for the rows of a table of parts and the
// files that the sources name, each procedure of a row that reads a kind
// that its row does not declare, each procedure of a row that reads a kind
// that the test inputs drop, and each reader of a dropped kind that is not
// in the list of such readers.
@(private = "file")
undeclared_reads_problems :: proc(rows: []Test_Part, named: []Named_Build_File, readers: []string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for item in named {
		if !build_file_kind_is_test_input(item.kind) && !slice_holds(readers, item.procedure) {
			append(&problems, fmt.tprintf("%s reads the %v, which the test inputs drop, and is not in the list of such readers", item.procedure, item.kind))
		}
		for row in rows {
			if !slice_holds(row.procedures, item.procedure) {
				continue
			}
			if !build_file_kind_is_test_input(item.kind) {
				append(&problems, fmt.tprintf("the procedure %s of the part %s reads the %v, which the test inputs drop", item.procedure, row.name, item.kind))
			} else if item.kind not_in test_part_reads(row) {
				append(&problems, fmt.tprintf("the procedure %s of the part %s reads the %v, which its row does not declare in reads", item.procedure, row.name, item.kind))
			}
		}
	}
	return problems[:]
}

@(private = "file")
slice_holds :: proc(texts: []string, text: string) -> bool {
	for item in texts {
		if item == text {
			return true
		}
	}
	return false
}

// The check of the sources refuses a procedure of a part that reads a file
// that the test inputs drop, and one that reads a kind that its row does
// not declare; a reader of a dropped file outside the list is refused too.
@(test)
undeclared_reads_are_refused :: proc(t: ^testing.T) {
	source := "fake_reader :: proc() {\n\tlist := module_dependency_file(\"a\")\n}\n\nfake_lister :: proc() {\n\tlist := module_source_list_read(\"a\")\n}\n\n// fake_comment :: proc() names module_linked_file( in a comment only\n"
	named := make([dynamic]Named_Build_File, context.temp_allocator)
	build_files_named_in_source(source, &named)
	testing.expect_value(t, len(named), 2)
	dropped_reader := []Test_Part{{name = "fake", procedures = {"fake_reader"}}}
	testing.expect(t, len(undeclared_reads_problems(dropped_reader, named[:], {"fake_reader"})) == 1, "a part that runs a reader of a dropped file is refused")
	testing.expect(t, len(undeclared_reads_problems(nil, named[:], nil)) == 1, "a reader of a dropped file outside the list is refused")
	undeclared := []Test_Part{{name = "fake", procedures = {"fake_lister"}}}
	testing.expect(t, len(undeclared_reads_problems(undeclared, named[:], {"fake_reader"})) == 1, "a kind that the row does not declare is refused")
	declared := []Test_Part{{name = "fake", procedures = {"fake_lister"}, reads = {.Module_Source_List}}}
	testing.expect(t, len(undeclared_reads_problems(declared, named[:], {"fake_reader"})) == 0, "a declared kind of a test input passes")
}

// Each part declares the kinds of files that the procedures of its row
// read, each of them a test input, and each reader of a dropped file is a
// step of the build or of `check`. The test reads the sources of the tool,
// from the root of the repository.
@(test)
each_part_declares_the_build_files_that_its_procedures_read :: proc(t: ^testing.T) {
	listed_paths := make([dynamic]string, context.temp_allocator)
	listed := foundation.source_files_of_a_folder(foundation.TOOL_SOURCE_FOLDER, &listed_paths)
	testing.expect(t, listed, "the test runs from the root of the repository")
	named := make([dynamic]Named_Build_File, context.temp_allocator)
	for path in listed_paths {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source, error := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, error == nil, "%s can be read", path)
		build_files_named_in_source(string(source), &named)
	}
	testing.expect(t, len(named) > 20, "the sources of the tool name the files of the modules")
	for problem in undeclared_reads_problems(test_parts[:], named[:], dropped_file_readers[:]) {
		testing.expectf(t, false, "%s", problem)
	}
	// No name of the list is stale: each one reads a dropped kind.
	for reader in dropped_file_readers {
		reads_a_dropped_kind := false
		for item in named {
			reads_a_dropped_kind = reads_a_dropped_kind || (item.procedure == reader && !build_file_kind_is_test_input(item.kind))
		}
		testing.expectf(t, reads_a_dropped_kind, "%s, in the list of the readers of dropped files, reads none", reader)
	}
}
