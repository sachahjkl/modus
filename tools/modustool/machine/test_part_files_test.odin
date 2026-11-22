#+feature dynamic-literals
package machine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// The manifest of the scenario files of the parts (test_part_files.json)
// against the table of the parts and against the sources of this folder.
// The flake builds the binary of the tool of a part from the core and the
// files that the manifest names for that part, and only the run that a
// file of that binary registers can run there. A host test reads the
// sources here; the compile of each binary in the flake proves that the
// core and the files of each part compile alone.

// The text of a call that registers the run of a part, before its name.
TEST_PART_REGISTER_CALL :: "test_part_scenario_register(\""

// test_part_files_of_json reads a manifest: an object whose keys are the
// names of the parts and whose values are arrays of file names. Its memory
// is of the temporary allocator.
test_part_files_of_json :: proc(text: string) -> (manifest: map[string][]string, problem: string) {
	value, parse_error := json.parse_string(text, allocator = context.temp_allocator)
	if parse_error != .None {
		return nil, fmt.tprintf("the manifest is no JSON: %v", parse_error)
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return nil, "the manifest is no JSON object"
	}
	manifest = make(map[string][]string, allocator = context.temp_allocator)
	for name, entry in object {
		array, is_array := entry.(json.Array)
		if !is_array {
			return nil, fmt.tprintf("the entry of %s is no array", name)
		}
		files := make([]string, len(array), context.temp_allocator)
		for item, place in array {
			file, is_text := item.(json.String)
			if !is_text {
				return nil, fmt.tprintf("the entry of %s holds an item that is no text", name)
			}
			files[place] = file
		}
		manifest[name] = files
	}
	return manifest, ""
}

// test_part_registrations_of_source gives the names of the parts whose run
// a source registers, in the order of the source.
test_part_registrations_of_source :: proc(text: string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	rest := text
	for {
		at := strings.index(rest, TEST_PART_REGISTER_CALL)
		if at < 0 {
			break
		}
		rest = rest[at + len(TEST_PART_REGISTER_CALL):]
		end := strings.index_byte(rest, '"')
		if end < 0 {
			append(&names, rest)
			break
		}
		append(&names, rest[:end])
		rest = rest[end:]
	}
	return names[:]
}

// scenario_file_name_valid says if a name of the manifest can name a source
// of the binary of a part: a file of this folder, of Odin, that is no test.
@(private = "file")
scenario_file_name_valid :: proc(name: string) -> bool {
	if name == "" || strings.contains_any(name, "/\\ ") || !strings.has_suffix(name, ".odin") || name == ".odin" {
		return false
	}
	return !source_is_test(name)
}

// source_is_test says if a file name is that of a host test: the binary
// of the tool holds none (flake.nix, sourcesOfOdin).
@(private = "file")
source_is_test :: proc(name: string) -> bool {
	stem := strings.trim_suffix(name, ".odin")
	return strings.has_suffix(stem, "_test") || strings.contains(stem, "_test_")
}

@(private = "file")
list_add :: proc(lists: ^map[string][]string, key, item: string) {
	list := make([dynamic]string, context.temp_allocator)
	append(&list, ..lists[key])
	append(&list, item)
	lists[key] = list[:]
}

// test_part_files_problems gives the faults of a manifest against a table
// of parts and the sources of the folder (file name -> text, with no host
// test):
//   - a part of the table that the manifest lacks, and an entry that names
//     no part;
//   - a file name that is no source of the binary, that a part names twice,
//     or that the folder lacks;
//   - a run that no file registers, or that two files register, or that a
//     file registers for a part that is no row of the table;
//   - a file of some parts that registers another part: the binary of those
//     parts would hold the run of a part whose files it lacks;
//   - a part with files whose run a file of the core registers, or a part
//     with no file whose run a file of another part registers: in both, the
//     binary of the part would not hold its own run, or would not be the core
//     alone.
test_part_files_problems :: proc(manifest: map[string][]string, parts: []Test_Part, sources: map[string]string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	part_names := make([dynamic]string, context.temp_allocator)
	for part in parts {
		append(&part_names, part.name)
		if part.name not_in manifest {
			append(&problems, fmt.tprintf("the manifest has no entry of the test part %s", part.name))
		}
	}
	// The file -> the parts that name it.
	listed_by := make(map[string][]string, allocator = context.temp_allocator)
	for name, files in manifest {
		if !slice.contains(part_names[:], name) {
			append(&problems, fmt.tprintf("the manifest names %s, which is no test part", name))
			continue
		}
		seen := make(map[string]bool, allocator = context.temp_allocator)
		for file in files {
			switch {
			case !scenario_file_name_valid(file):
				append(&problems, fmt.tprintf("the test part %s names %q, which is no source of Odin of this folder or is a host test", name, file))
			case seen[file]:
				append(&problems, fmt.tprintf("the test part %s names %s twice", name, file))
			case file not_in sources:
				append(&problems, fmt.tprintf("the test part %s names %s, which the folder lacks", name, file))
			case:
				seen[file] = true
				list_add(&listed_by, file, name)
			}
		}
	}
	// The part -> the files that register its run.
	registered_in := make(map[string][]string, allocator = context.temp_allocator)
	for file, text in sources {
		for registered in test_part_registrations_of_source(text) {
			list_add(&registered_in, registered, file)
			if listing, is_part_file := listed_by[file]; is_part_file && !slice.contains(listing, registered) {
				append(&problems, fmt.tprintf("the file %s of the test parts %v registers the test part %s, which does not name it", file, listing, registered))
			}
		}
	}
	for name, files in registered_in {
		if !slice.contains(part_names[:], name) {
			append(&problems, fmt.tprintf("the files %v register %s, which is no test part", files, name))
		}
	}
	for part in parts {
		files := registered_in[part.name]
		switch {
		case len(files) == 0:
			append(&problems, fmt.tprintf("no file registers the run of the test part %s", part.name))
		case len(files) > 1:
			append(&problems, fmt.tprintf("the files %v register the run of the test part %s, and one must", files, part.name))
		case:
			own := manifest[part.name]
			file := files[0]
			if len(own) > 0 && !slice.contains(own, file) {
				append(&problems, fmt.tprintf("the test part %s names the files %v, and the file %s, which is not one of them, registers its run", part.name, own, file))
			}
			if listing, is_part_file := listed_by[file]; len(own) == 0 && is_part_file {
				append(&problems, fmt.tprintf("the test part %s names no file, so its binary is the core alone, and the file %s of the test parts %v registers its run", part.name, file, listing))
			}
		}
	}
	return problems[:]
}

// The sources of the binary in the folder of the machine test, by name.
@(private = "file")
machine_folder_sources :: proc(t: ^testing.T) -> map[string]string {
	manifest_path: string = TEST_PART_FILES_MANIFEST
	folder := manifest_path[:strings.last_index_byte(manifest_path, '/')]
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	testing.expectf(t, list_error == nil, "cannot list %s: %v", folder, list_error)
	sources := make(map[string]string, allocator = context.temp_allocator)
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") || source_is_test(entry.name) {
			continue
		}
		bytes, read_error := os.read_entire_file(entry.fullpath, context.temp_allocator)
		testing.expectf(t, read_error == nil, "cannot read %s: %v", entry.fullpath, read_error)
		sources[strings.clone(entry.name, context.temp_allocator)] = string(bytes)
	}
	return sources
}

// The manifest of the repository fits the table and the sources, and the
// scenario that the proof of the cache changes is a file of its part alone:
// else the command part_cache would expect a change of the wrong part.
@(test)
the_manifest_of_the_scenario_files_fits_the_table_and_the_sources :: proc(t: ^testing.T) {
	text, read := os.read_entire_file(TEST_PART_FILES_MANIFEST, context.temp_allocator)
	testing.expectf(t, read == nil, "cannot read %s: %v", TEST_PART_FILES_MANIFEST, read)
	manifest, problem := test_part_files_of_json(string(text))
	testing.expectf(t, problem == "", "%s: %s", TEST_PART_FILES_MANIFEST, problem)
	sources := machine_folder_sources(t)
	testing.expect(t, len(sources) > 0, "the folder of the machine test has no source")
	for fault in test_part_files_problems(manifest, test_parts[:], sources) {
		testing.expectf(t, false, "%s: %s", TEST_PART_FILES_MANIFEST, fault)
	}
	scenario_path: string = PART_CACHE_SCENARIO
	scenario := scenario_path[strings.last_index_byte(scenario_path, '/') + 1:]
	testing.expectf(t, PART_CACHE_SCENARIO_PART in manifest, "the manifest has no entry of %s, the part of the proof of the cache", PART_CACHE_SCENARIO_PART)
	for name, files in manifest {
		names_it := slice.contains(files, scenario)
		testing.expectf(t, names_it == (name == PART_CACHE_SCENARIO_PART), "the test part %s %s %s, and the proof of the cache expects a change of %s alone", name, names_it ? "names" : "does not name", scenario, PART_CACHE_SCENARIO_PART)
	}
}

// The binary of the whole tool, which holds every file, holds the run of
// every part; a table that lacks runs names each of them, in its order.
@(test)
each_part_without_run_is_named :: proc(t: ^testing.T) {
	testing.expect_value(t, test_parts_without_run(test_parts[:]), "")
	parts := []Test_Part{{name = "a"}, {name = "b", run = fails_tests_run}, {name = "c"}}
	testing.expect_value(t, test_parts_without_run(parts), "a, c")
	testing.expect_value(t, test_parts_without_run(parts[1:2]), "")
	testing.expect_value(t, test_parts_without_run(nil), "")
}

@(test)
test_part_files_of_json_refuses_each_other_form :: proc(t: ^testing.T) {
	for text in ([]string{"", "[]", "\"a\"", "{", "{\"a\": \"b.odin\"}", "{\"a\": [1]}", "{\"a\": [\"b.odin\", null]}", "{\"a\": {}}"}) {
		_, problem := test_part_files_of_json(text)
		testing.expectf(t, problem != "", "the manifest %q is refused", text)
	}
	manifest, problem := test_part_files_of_json("{\"a\": [], \"b\": [\"b.odin\", \"c.odin\"]}")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(manifest), 2)
	testing.expect_value(t, len(manifest["a"]), 0)
	testing.expect(t, slice.equal(manifest["b"], []string{"b.odin", "c.odin"}), "the files of a part keep their order")
}

@(test)
test_part_registrations_of_source_reads_each_call :: proc(t: ^testing.T) {
	testing.expect_value(t, len(test_part_registrations_of_source("")), 0)
	testing.expect_value(t, len(test_part_registrations_of_source("test_part_scenario_register :: proc \"contextless\" (name: string)")), 0)
	names := test_part_registrations_of_source("\ttest_part_scenario_register(\"a\", a_run)\n\ttest_part_scenario_register(\"quic-real\", b_run)\n")
	testing.expect(t, slice.equal(names, []string{"a", "quic-real"}), "two calls give two names, in order")
	// A call cut before the end of its name still names a part, which the
	// check then refuses.
	testing.expect(t, slice.equal(test_part_registrations_of_source("test_part_scenario_register(\"cut"), []string{"cut"}), "a cut call gives its text")
}

// The register calls of parts in a source, as a scenario file writes them.
@(private = "file")
register_source :: proc(names: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for name in names {
		fmt.sbprintf(&b, "\ttest_part_scenario_register(\"%s\", %s_run)\n", name, name)
	}
	return strings.to_string(b)
}

@(private = "file")
expect_refused :: proc(t: ^testing.T, what: string, manifest: map[string][]string, parts: []Test_Part, sources: map[string]string) {
	problems := test_part_files_problems(manifest, parts, sources)
	testing.expectf(t, len(problems) > 0, "%s is refused", what)
}

// Each fault of a manifest is refused, the edges first: no part, no file,
// one file of two parts, a name past the folder.
@(test)
test_part_files_problems_refuses_each_fault :: proc(t: ^testing.T) {
	parts := []Test_Part{{name = "a"}, {name = "b"}, {name = "c"}}
	// a has one file, b two, one of which it shares with c, c registers in
	// that shared file, and core.odin holds no part file.
	valid_manifest := map[string][]string{"a" = {"a.odin"}, "b" = {"b.odin", "shared.odin"}, "c" = {"shared.odin"}}
	defer delete(valid_manifest)
	valid_sources := map[string]string{"a.odin" = register_source("a"), "b.odin" = register_source("b"), "shared.odin" = register_source("c"), "core.odin" = ""}
	defer delete(valid_sources)

	// No manifest: each part lacks its entry.
	testing.expect_value(t, len(test_part_files_problems(nil, parts, valid_sources)), 3)
	// A table with no part: each entry and each register call names no part.
	testing.expect(t, len(test_part_files_problems(valid_manifest, nil, valid_sources)) >= 6, "a manifest with no table is refused")

	lacking := map[string][]string{"a" = {"a.odin"}, "b" = {"b.odin", "shared.odin"}}
	defer delete(lacking)
	expect_refused(t, "a part that the manifest lacks", lacking, parts, valid_sources)

	unknown := map[string][]string{"a" = {"a.odin"}, "b" = {"b.odin", "shared.odin"}, "c" = {"shared.odin"}, "netwrok" = {}}
	defer delete(unknown)
	expect_refused(t, "an entry that names no part", unknown, parts, valid_sources)

	for bad in ([]string{"", ".odin", "../a.odin", "sub/a.odin", "a\\b.odin", "a.json", "a.odin ", "a_test.odin", "a_test_linux.odin", "/a.odin"}) {
		bad_name := map[string][]string{"a" = {"a.odin", bad}, "b" = {"b.odin", "shared.odin"}, "c" = {"shared.odin"}}
		defer delete(bad_name)
		expect_refused(t, fmt.tprintf("the file name %q", bad), bad_name, parts, valid_sources)
	}

	twice := map[string][]string{"a" = {"a.odin", "a.odin"}, "b" = {"b.odin", "shared.odin"}, "c" = {"shared.odin"}}
	defer delete(twice)
	expect_refused(t, "a file that a part names twice", twice, parts, valid_sources)

	absent := map[string][]string{"a" = {"a.odin", "gone.odin"}, "b" = {"b.odin", "shared.odin"}, "c" = {"shared.odin"}}
	defer delete(absent)
	expect_refused(t, "a file that the folder lacks", absent, parts, valid_sources)

	silent := map[string]string{"a.odin" = "", "b.odin" = register_source("b"), "shared.odin" = register_source("c")}
	defer delete(silent)
	expect_refused(t, "a run that no file registers", valid_manifest, parts, silent)

	double := map[string]string{"a.odin" = register_source("a"), "b.odin" = register_source("b"), "shared.odin" = register_source("c"), "core.odin" = register_source("a")}
	defer delete(double)
	expect_refused(t, "a run that two files register", valid_manifest, parts, double)

	stray := map[string]string{"a.odin" = register_source("a"), "b.odin" = register_source("b"), "shared.odin" = register_source("c"), "core.odin" = register_source("netwrok")}
	defer delete(stray)
	expect_refused(t, "a register call of a part that is no row", valid_manifest, parts, stray)

	// The file of a registers b: the binary of a would hold the run of b.
	crossed := map[string]string{"a.odin" = register_source("a", "b"), "b.odin" = "", "shared.odin" = register_source("c")}
	defer delete(crossed)
	expect_refused(t, "a file of one part that registers another part", valid_manifest, parts, crossed)

	in_core := map[string]string{"a.odin" = "", "b.odin" = register_source("b"), "shared.odin" = register_source("c"), "core.odin" = register_source("a")}
	defer delete(in_core)
	expect_refused(t, "a part with files whose run the core registers", valid_manifest, parts, in_core)

	no_files := map[string][]string{"a" = {}, "b" = {"b.odin", "shared.odin"}, "c" = {"shared.odin"}}
	defer delete(no_files)
	moved := map[string]string{"b.odin" = register_source("b"), "shared.odin" = register_source("c", "a")}
	defer delete(moved)
	expect_refused(t, "a part with no file whose run a part file registers", no_files, parts, moved)

	// The forms that pass come last: files of one part, a file of two
	// parts, a file of two parts that registers both, as the scenario of the
	// two IOMMU parts does, and a part with no file whose run the core
	// registers.
	testing.expect_value(t, len(test_part_files_problems(valid_manifest, parts, valid_sources)), 0)
	both_manifest := map[string][]string{"a" = {"a.odin"}, "b" = {"shared.odin"}, "c" = {"shared.odin"}}
	defer delete(both_manifest)
	both_sources := map[string]string{"a.odin" = register_source("a"), "shared.odin" = register_source("b", "c")}
	defer delete(both_sources)
	testing.expect_value(t, len(test_part_files_problems(both_manifest, parts, both_sources)), 0)
	core_manifest := map[string][]string{"a" = {}, "b" = {"b.odin"}, "c" = {"c.odin"}}
	defer delete(core_manifest)
	core_sources := map[string]string{"core.odin" = register_source("a"), "b.odin" = register_source("b"), "c.odin" = register_source("c")}
	defer delete(core_sources)
	testing.expect_value(t, len(test_part_files_problems(core_manifest, parts, core_sources)), 0)
}

// A change of the scenario of one part must change the derivation of that
// part, and of no other: no change of that part, a change of another part
// too, and a part of the change that is no row are refused.
@(test)
part_derivations_compare_takes_the_change_of_one_part :: proc(t: ^testing.T) {
	names := []string{"main", "tcp"}
	before := map[string]string{"main" = "/nix/store/a-main.drv", "tcp" = "/nix/store/a-tcp.drv"}
	defer delete(before)
	tcp_changed := map[string]string{"main" = "/nix/store/a-main.drv", "tcp" = "/nix/store/b-tcp.drv"}
	defer delete(tcp_changed)
	both_changed := map[string]string{"main" = "/nix/store/b-main.drv", "tcp" = "/nix/store/b-tcp.drv"}
	defer delete(both_changed)
	build_before :: "/nix/store/a-build.drv"
	build_after :: "/nix/store/b-build.drv"

	testing.expect_value(t, len(part_derivations_compare(before, before, names, build_before, build_after, "a change", "tcp")), 1)
	testing.expect_value(t, len(part_derivations_compare(before, both_changed, names, build_before, build_after, "a change", "tcp")), 1)
	testing.expect_value(t, len(part_derivations_compare(before, tcp_changed, names, build_before, build_after, "a change", "netwrok")), 2)
	testing.expect_value(t, len(part_derivations_compare(before, tcp_changed, names, build_before, build_after, "a change", "main")), 2)
	testing.expect_value(t, len(part_derivations_compare(before, tcp_changed, names, build_before, build_before, "a change", "tcp")), 1)
	testing.expect_value(t, len(part_derivations_compare(before, tcp_changed, names, build_before, build_after, "a change", "tcp")), 0)
}
