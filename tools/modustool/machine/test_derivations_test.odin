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
