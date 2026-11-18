package modustool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import "modustool:foundation"

// The corpus of the fuzz targets (docs/glossary/project.md, "Corpus";
// src/md/infrastructure/fuzzing.md, "Fuzz findings, minimization and the
// corpus"): one folder for each target, with its regression inputs and its
// reach inputs, one file for each input, named by the BLAKE3 hash of its
// bytes. The repository reviews them as code, so they have bounds.

FUZZ_CORPUS_FOLDER :: foundation.TOOL_SOURCE_FOLDER + "/fuzzing_corpus"
FUZZ_REGRESSION_PART :: "regression" // The inputs of the fuzz findings after their fix: never removed.
FUZZ_REACH_PART :: "reach" // The smallest set of inputs that gives each edge class that the long runs reached.

FUZZ_CORPUS_TARGET_INPUT_LIMIT :: 512 // The inputs of one target.
FUZZ_CORPUS_TARGET_BYTE_LIMIT :: 1 << 20 // The bytes of the inputs of one target.
FUZZ_CORPUS_BYTE_LIMIT :: 16 << 20 // The bytes of the whole corpus.

// The folders of a run, which git ignores: the inputs that a long run kept,
// and the fuzz findings.
FUZZING_BUILD_FOLDER :: foundation.BUILD_FOLDER + "/fuzzing"
FUZZ_KEPT_PART :: "kept"
FUZZ_FINDINGS_PART :: "findings"

// fuzz_input_name gives the name of an input: the 64 hexadecimal digits of
// the BLAKE3 hash of its bytes, in the temporary memory.
fuzz_input_name :: proc(input: []u8) -> string {
	hash := blake3.hash(input)
	digits := "0123456789abcdef"
	name := make([]u8, 2 * len(hash), context.temp_allocator)
	for value, index in hash {
		name[2 * index] = digits[value >> 4]
		name[2 * index + 1] = digits[value & 0x0F]
	}
	return string(name)
}

fuzz_corpus_folder :: proc(target_name, part: string) -> string {
	return strings.concatenate({FUZZ_CORPUS_FOLDER, "/", target_name, "/", part}, context.temp_allocator)
}

fuzz_run_folder :: proc(target_name, part: string) -> string {
	return strings.concatenate({FUZZING_BUILD_FOLDER, "/", target_name, "/", part}, context.temp_allocator)
}

// One input that a folder holds, with its name.
Fuzz_Stored_Input :: struct {
	name:  string,
	bytes: []u8,
}

// fuzz_inputs_read reads each file of a folder, in the order of their
// names, in the allocator. A folder that does not exist holds no input.
fuzz_inputs_read :: proc(folder: string, allocator := context.allocator) -> []Fuzz_Stored_Input {
	inputs := make([dynamic]Fuzz_Stored_Input, allocator)
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return inputs[:]
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.type != .Regular {
			continue
		}
		bytes, read_error := os.read_entire_file(entry.fullpath, allocator)
		if read_error != nil {
			continue
		}
		append(&inputs, Fuzz_Stored_Input{name = strings.clone(entry.name, allocator), bytes = bytes})
	}
	return inputs[:]
}

// fuzz_input_write writes an input to a folder under its name, and gives
// its path in the temporary memory.
fuzz_input_write :: proc(folder: string, input: []u8) -> (path: string, ok: bool) {
	if !foundation.make_folder(folder) {
		return "", false
	}
	path = strings.concatenate({folder, "/", fuzz_input_name(input)}, context.temp_allocator)
	if os.exists(path) {
		return path, true
	}
	if error := os.write_entire_file(path, input); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, error)
		return "", false
	}
	return path, true
}

// fuzz_corpus_problems gives each fault of the form of a corpus folder: a
// folder that names no target, a part that is not regression or reach, a
// file whose name is not the hash of its bytes, an input over the limit of
// its target, and the bounds of a target and of the whole corpus. The
// texts are in the temporary memory.
fuzz_corpus_problems :: proc(root: string, targets: []Fuzz_Target) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	target_folders, error := os.read_all_directory_by_path(root, context.temp_allocator)
	if error != nil {
		return problems[:] // No corpus yet: no fault.
	}
	total := 0
	for folder in target_folders {
		// The corpus of the kernel operations has the form of the corpus
		// of a target, the bound of its own inputs, and the checks of their
		// content (operation_corpus.odin).
		is_operations := folder.name == OPERATION_CORPUS_NAME
		target, found := fuzz_target_find(targets, folder.name)
		if (!found && !is_operations) || folder.type != .Directory {
			append(&problems, fmt.tprintf("%s/%s names no fuzz target", root, folder.name))
			continue
		}
		input_limit := OPERATION_REGRESSION_BYTES_MOST
		if !is_operations {
			input_limit = target.input_limit
		} else {
			operation_corpus_problems(folder.fullpath, &problems)
		}
		parts, _ := os.read_all_directory_by_path(folder.fullpath, context.temp_allocator)
		target_inputs, target_bytes := 0, 0
		for part in parts {
			if part.type != .Directory || (part.name != FUZZ_REGRESSION_PART && part.name != FUZZ_REACH_PART) {
				append(&problems, fmt.tprintf("%s/%s is neither %s nor %s", folder.fullpath, part.name, FUZZ_REGRESSION_PART, FUZZ_REACH_PART))
				continue
			}
			inputs := fuzz_inputs_read(part.fullpath, context.temp_allocator)
			for input in inputs {
				if input.name != fuzz_input_name(input.bytes) {
					append(&problems, fmt.tprintf("%s/%s is not named by the BLAKE3 hash of its bytes", part.fullpath, input.name))
				}
				if len(input.bytes) > input_limit {
					append(&problems, fmt.tprintf("%s/%s has %d bytes, over the limit %d of its target", part.fullpath, input.name, len(input.bytes), input_limit))
				}
				target_inputs += 1
				target_bytes += len(input.bytes)
			}
		}
		if target_inputs > FUZZ_CORPUS_TARGET_INPUT_LIMIT {
			append(&problems, fmt.tprintf("the corpus of %s has %d inputs, over the bound %d", folder.name, target_inputs, FUZZ_CORPUS_TARGET_INPUT_LIMIT))
		}
		if target_bytes > FUZZ_CORPUS_TARGET_BYTE_LIMIT {
			append(&problems, fmt.tprintf("the corpus of %s has %d bytes, over the bound %d", folder.name, target_bytes, FUZZ_CORPUS_TARGET_BYTE_LIMIT))
		}
		total += target_bytes
	}
	if total > FUZZ_CORPUS_BYTE_LIMIT {
		append(&problems, fmt.tprintf("the corpus has %d bytes, over the bound %d", total, FUZZ_CORPUS_BYTE_LIMIT))
	}
	return problems[:]
}

// fuzz_corpus_check prints each fault of the corpus of the repository.
fuzz_corpus_check :: proc() -> bool {
	problems := fuzz_corpus_problems(FUZZ_CORPUS_FOLDER, fuzz_targets())
	for problem in problems {
		fmt.eprintfln("modustool: test failed: %s", problem)
	}
	if len(problems) > 0 {
		return false
	}
	foundation.test_passed_print("the corpus of the fuzz targets in %s has its form and its bounds", FUZZ_CORPUS_FOLDER)
	return true
}
