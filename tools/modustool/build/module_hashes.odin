// The record of the hashes of the modules of a build, and the comparison
// of a build with such a record
// (docs/TOOLS.md, "The hashes of the modules of two builds").
// The hash of a module file is its identity. A change
// that must not change the system (a move of the sources, a new name of a
// folder, a change of the tool) is proved by it: each module of the build
// after the change has the hash of the build before.
package build

import "modus:contract/blake3"
import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

MODULE_FILE_SUFFIX :: ".module"
MODULE_HASHES_FIRST_LINE :: "module hashes, form 1"
MODULE_HASH_DIGITS :: 2 * size_of(blake3.Hash)
MODULE_HASHES_USAGE :: "modustool: module-hashes write <file> | compare <file>"

// The hash of the file of one module.
Module_Hash :: struct {
	name: string,
	hash: blake3.Hash,
}

// A module whose file has two hashes in two builds.
Module_Hash_Difference :: struct {
	name:   string,
	before: blake3.Hash,
	now:    blake3.Hash,
}

// What two lists of hashes have in common, and where they differ.
Module_Hashes_Comparison :: struct {
	equal_count: int, // The modules with the same hash in both.
	different:   []Module_Hash_Difference,
	only_before: []string, // The modules of the record that the build does not have.
	only_now:    []string, // The modules of the build that the record does not have.
}

// module_hashes_of_folder hashes the file of each named module of a folder
// of modules, in the order of the names.
module_hashes_of_folder :: proc(folder: string, names: []string) -> (hashes: []Module_Hash, ok: bool) {
	list := make([dynamic]Module_Hash, context.temp_allocator)
	for name in names {
		file := foundation.read_file(foundation.join(folder, "/", name, MODULE_FILE_SUFFIX)) or_return
		append(&list, Module_Hash{name = name, hash = blake3.hash(file)})
	}
	return list[:], true
}

// module_hashes_record_text gives the text of a record: its first line,
// then one line for each module, the hash in hexadecimal and the name.
module_hashes_record_text :: proc(hashes: []Module_Hash) -> string {
	text := strings.builder_make(context.temp_allocator)
	strings.write_string(&text, MODULE_HASHES_FIRST_LINE + "\n")
	for item in hashes {
		fmt.sbprintf(&text, "%s %s\n", hash_as_hexadecimal(item.hash), item.name)
	}
	return strings.to_string(text)
}

// module_hashes_record_parse reads the text of a record. A text that does
// not have the form of a record gives a sentence, and no list.
module_hashes_record_parse :: proc(text: string) -> (hashes: []Module_Hash, problem: string) {
	list := make([dynamic]Module_Hash, context.temp_allocator)
	first_line_read := false
	for line, line_index in foundation.site_lines(text) {
		if !first_line_read {
			if line != MODULE_HASHES_FIRST_LINE {
				return nil, fmt.tprintf("line 1 is not \"%s\"", MODULE_HASHES_FIRST_LINE)
			}
			first_line_read = true
			continue
		}
		if line == "" {
			continue
		}
		if len(line) < MODULE_HASH_DIGITS + 2 || line[MODULE_HASH_DIGITS] != ' ' {
			return nil, fmt.tprintf("line %d is not a hash of %d hexadecimal digits, a space and the name of a module", line_index + 1, MODULE_HASH_DIGITS)
		}
		hash, is_hash := hash_from_hexadecimal(line[:MODULE_HASH_DIGITS])
		if !is_hash {
			return nil, fmt.tprintf("line %d does not start with %d hexadecimal digits", line_index + 1, MODULE_HASH_DIGITS)
		}
		name := line[MODULE_HASH_DIGITS + 1:]
		for known in list {
			if known.name == name {
				return nil, fmt.tprintf("line %d names the module %s a second time", line_index + 1, name)
			}
		}
		append(&list, Module_Hash{name = name, hash = hash})
	}
	if !first_line_read {
		return nil, "the record is empty"
	}
	return list[:], ""
}

// module_hashes_compare compares the hashes of a record with those of a
// build, by the name of the module.
module_hashes_compare :: proc(before, now: []Module_Hash) -> Module_Hashes_Comparison {
	comparison: Module_Hashes_Comparison
	different := make([dynamic]Module_Hash_Difference, context.temp_allocator)
	only_before := make([dynamic]string, context.temp_allocator)
	only_now := make([dynamic]string, context.temp_allocator)
	for recorded in before {
		found := false
		for built in now {
			if built.name != recorded.name {
				continue
			}
			found = true
			if built.hash == recorded.hash {
				comparison.equal_count += 1
			} else {
				append(&different, Module_Hash_Difference{name = recorded.name, before = recorded.hash, now = built.hash})
			}
			break
		}
		if !found {
			append(&only_before, recorded.name)
		}
	}
	for built in now {
		in_record := false
		for recorded in before {
			in_record ||= recorded.name == built.name
		}
		if !in_record {
			append(&only_now, built.name)
		}
	}
	comparison.different = different[:]
	comparison.only_before = only_before[:]
	comparison.only_now = only_now[:]
	return comparison
}

// module_hashes_comparison_is_equal tells whether two builds have the same
// modules with the same hashes.
module_hashes_comparison_is_equal :: proc(comparison: Module_Hashes_Comparison) -> bool {
	return len(comparison.different) == 0 && len(comparison.only_before) == 0 && len(comparison.only_now) == 0
}

// module_hashes_of_the_build hashes the file of each module of the table,
// in the folder of the modules of the build. The command builds nothing:
// it reads the build that is there.
module_hashes_of_the_build :: proc() -> (hashes: []Module_Hash, ok: bool) {
	names := make([dynamic]string, context.temp_allocator)
	for build in foundation.module_builds {
		if !os.exists(foundation.module_path(build.name)) {
			fmt.eprintfln("modustool: %s is not there: run `modustool build` first", foundation.module_path(build.name))
			return nil, false
		}
		append(&names, build.name)
	}
	return module_hashes_of_folder(foundation.MODULE_BUILD_FOLDER, names[:])
}

run_module_hashes :: proc(args: []string) -> int {
	if len(args) != 2 || (args[0] != "write" && args[0] != "compare") {
		fmt.eprintln(MODULE_HASHES_USAGE)
		return foundation.EXIT_USAGE
	}
	file := args[1]
	now, hashed := module_hashes_of_the_build()
	if !hashed {
		return foundation.EXIT_FAILURE
	}
	if args[0] == "write" {
		if err := os.write_entire_file(file, module_hashes_record_text(now)); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", file, err)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: wrote %s: the hashes of the %d modules of %s", file, len(now), foundation.MODULE_BUILD_FOLDER)
		return 0
	}
	record, readable := foundation.read_file(file)
	if !readable {
		return foundation.EXIT_FAILURE
	}
	before, problem := module_hashes_record_parse(string(record))
	if problem != "" {
		fmt.eprintfln("modustool: %s is not a record of the hashes of the modules: %s", file, problem)
		return foundation.EXIT_FAILURE
	}
	comparison := module_hashes_compare(before, now)
	for difference in comparison.different {
		fmt.printfln("modustool: the module %s has another hash: %s in %s, %s in %s", difference.name, hash_as_hexadecimal(difference.before), file, hash_as_hexadecimal(difference.now), foundation.MODULE_BUILD_FOLDER)
	}
	for name in comparison.only_before {
		fmt.printfln("modustool: the module %s is in %s, and the build does not have it", name, file)
	}
	for name in comparison.only_now {
		fmt.printfln("modustool: the module %s is in the build, and %s does not have it", name, file)
	}
	fmt.printfln("modustool: %d modules of %s have the hash of %s; %d have another hash; %d are in one of the two only", comparison.equal_count, foundation.MODULE_BUILD_FOLDER, file, len(comparison.different), len(comparison.only_before) + len(comparison.only_now))
	return module_hashes_comparison_is_equal(comparison) ? 0 : foundation.EXIT_FAILURE
}
