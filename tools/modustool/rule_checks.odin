package modustool

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Two rules of the system that a reader had to trust, as checks
// (docs/TOOLS.md, "The rules that a check holds").
//
// 1. The count of the kernel operations. docs/PROPERTIES.md states it, and
//    the contract of the operations declares them: a new operation with no
//    change of the property is refused.
// 2. No source of the system calls an allocator. A program has no heap: its
//    memory is a mapping that it asks the kernel for, or a variable of its
//    module. The compiler gets `-default-to-nil-allocator`, which turns a
//    call of an allocator into a failure when the program runs; this check
//    refuses the call when the tool builds.

// The file that declares the operations, and the document that states
// their count.
OPERATION_SOURCE :: SOURCE_FOLDER_CONTRACT + "/operation/operation.odin"
OPERATION_PROPERTY_DOCUMENT :: "docs/PROPERTIES.md"
// The sentence of the document that states the count: the number is
// between these two parts.
OPERATION_PROPERTY_BEFORE :: "The kernel has "
OPERATION_PROPERTY_AFTER :: " operations"

// operation_count_of_source counts the members of `Operation :: enum` in
// the source of the contract, without `None`, which is no operation. false:
// the source has no such enumeration, or no end of it.
operation_count_of_source :: proc(source: string) -> (count: int, ok: bool) {
	rest := source
	inside := false
	for line in strings.split_lines_iterator(&rest) {
		text := strings.trim_space(line)
		if !inside {
			inside = strings.has_prefix(text, "Operation :: enum")
			continue
		}
		if text == "}" {
			return count, true
		}
		if comment := strings.index(text, "//"); comment >= 0 {
			text = strings.trim_space(text[:comment])
		}
		// A member is `Name = number,`.
		equal := strings.index(text, "=")
		if equal <= 0 {
			continue
		}
		if strings.trim_space(text[:equal]) != "None" {
			count += 1
		}
	}
	return 0, false
}

// operation_count_of_document reads the count that the document states.
// false: the document has no such sentence, or its number is no number.
operation_count_of_document :: proc(document: string) -> (count: int, ok: bool) {
	start := strings.index(document, OPERATION_PROPERTY_BEFORE)
	for start >= 0 {
		after := document[start + len(OPERATION_PROPERTY_BEFORE):]
		end := strings.index(after, OPERATION_PROPERTY_AFTER)
		if end > 0 {
			if number, number_ok := strconv.parse_int(after[:end], 10); number_ok {
				return number, true
			}
		}
		next := strings.index(after, OPERATION_PROPERTY_BEFORE)
		if next < 0 {
			break
		}
		start += len(OPERATION_PROPERTY_BEFORE) + next
	}
	return 0, false
}

// operation_count_check compares the two counts.
operation_count_check :: proc() -> bool {
	source, source_ok := site_read_quiet(OPERATION_SOURCE)
	document, document_ok := site_read_quiet(OPERATION_PROPERTY_DOCUMENT)
	if !source_ok || !document_ok {
		fmt.eprintfln("modustool: test failed: cannot read %s or %s", OPERATION_SOURCE, OPERATION_PROPERTY_DOCUMENT)
		return false
	}
	declared, declared_ok := operation_count_of_source(source)
	stated, stated_ok := operation_count_of_document(document)
	if !declared_ok {
		fmt.eprintfln("modustool: test failed: %s has no enumeration Operation that the tool can count", OPERATION_SOURCE)
		return false
	}
	if !stated_ok {
		fmt.eprintfln("modustool: test failed: %s has no sentence \"%s<number>%s\"", OPERATION_PROPERTY_DOCUMENT, OPERATION_PROPERTY_BEFORE, OPERATION_PROPERTY_AFTER)
		return false
	}
	if declared != stated {
		fmt.eprintfln("modustool: test failed: %s declares %d kernel operations, and %s states %d: a new operation changes the property first, with its reason", OPERATION_SOURCE, declared, OPERATION_PROPERTY_DOCUMENT, stated)
		return false
	}
	test_passed_print("%s declares %d kernel operations, the count that %s states", OPERATION_SOURCE, declared, OPERATION_PROPERTY_DOCUMENT)
	return true
}

// The folders whose sources call no allocator: each source that becomes
// the system.
ALLOCATOR_CHECKED_FOLDERS :: [?]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_BOOT, SOURCE_FOLDER_PROGRAMS, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_LIBRARY}

// The calls and the names of an allocator. A call is the name, then "(",
// with no letter, digit, "_" or "." before the name: `caller_grant_make(`
// and `ring.make(` are procedures of the system, not the built-in `make`.
ALLOCATOR_CALLS :: [?]string{"make", "new", "new_clone", "delete", "free", "free_all"}
ALLOCATOR_NAMES :: [?]string{"context.allocator", "context.temp_allocator", "[dynamic]"}

// One place of a source that calls or names an allocator.
Allocator_Use :: struct {
	file: string,
	line: int,
	what: string, // The call or the name that the line holds.
}

// source_is_a_test says if a file is compiled for a host test only: the
// compiler builds it for no module of the system.
source_is_a_test :: proc(file: string) -> bool {
	name := file
	if slash := strings.last_index(file, "/"); slash >= 0 {
		name = file[slash + 1:]
	}
	return strings.contains(name, "_test")
}

// code_of_line gives a line without its comment and without the text of
// its string literals: a sentence of a log that says "make" is not a call.
code_of_line :: proc(line: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	quote: u8
	for index := 0; index < len(line); index += 1 {
		character := line[index]
		switch {
		case quote != 0:
			if character == '\\' && quote != '`' {
				index += 1
			} else if character == quote {
				quote = 0
			}
		case character == '"' || character == '`':
			quote = character
			strings.write_byte(&b, ' ')
		case character == '/' && index + 1 < len(line) && line[index + 1] == '/':
			return strings.to_string(b)
		case:
			strings.write_byte(&b, character)
		}
	}
	return strings.to_string(b)
}

// allocator_uses_of_source finds each line of a source that calls or names
// an allocator.
allocator_uses_of_source :: proc(file, source: string) -> []Allocator_Use {
	list := make([dynamic]Allocator_Use, context.temp_allocator)
	rest := source
	number := 0
	calls := ALLOCATOR_CALLS
	names := ALLOCATOR_NAMES
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		code := code_of_line(line)
		for name in names {
			if strings.contains(code, name) {
				append(&list, Allocator_Use{file = file, line = number, what = name})
			}
		}
		for call in calls {
			search := code
			offset := 0
			for {
				found := strings.index(search, call)
				if found < 0 {
					break
				}
				at := offset + found
				end := at + len(call)
				before_is_a_name := at > 0 && (code[at - 1] == '_' || code[at - 1] == '.' || is_name_byte(code[at - 1]))
				if !before_is_a_name && end < len(code) && code[end] == '(' {
					append(&list, Allocator_Use{file = file, line = number, what = strings.concatenate({call, "("}, context.temp_allocator)})
					break
				}
				offset = end
				search = code[end:]
			}
		}
	}
	return list[:]
}

// is_name_byte says if a byte is a letter or a digit of a name.
is_name_byte :: proc(character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9')
}

// allocator_uses_of_tree reads each source of the system that is not a
// test, from the folder `root` ("": the folder of the repository).
allocator_uses_of_tree :: proc(root: string) -> (uses: []Allocator_Use, file_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := ALLOCATOR_CHECKED_FOLDERS
	for folder in folders {
		source_files_of_a_folder(root == "" ? folder : join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	list := make([dynamic]Allocator_Use, context.temp_allocator)
	for file in files {
		if source_is_a_test(file) {
			continue
		}
		source, read_ok := site_read_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, false
		}
		file_count += 1
		append(&list, ..allocator_uses_of_source(file, source))
	}
	return list[:], file_count, true
}

// allocator_check refuses a source of the system that calls an allocator.
allocator_check :: proc() -> bool {
	uses, file_count, ok := allocator_uses_of_tree("")
	if !ok {
		return false
	}
	for use in uses {
		fmt.eprintfln("modustool: %s:%d: %s: a source of the system calls no allocator: its memory is a mapping that it asks the kernel for, or a variable of its module", use.file, use.line, use.what)
	}
	if len(uses) > 0 {
		fmt.eprintfln("modustool: test failed: %d places of the sources of the system call or name an allocator", len(uses))
		return false
	}
	test_passed_print("none of the %d source files of the system that are not tests calls or names an allocator", file_count)
	return true
}

// The command rule-checks: the two checks alone.
run_rule_checks :: proc(args: []string) -> int {
	return operation_count_check() && allocator_check() ? 0 : EXIT_FAILURE
}
