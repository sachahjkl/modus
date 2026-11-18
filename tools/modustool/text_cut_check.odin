package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// A text is never cut in silence (docs/ARCHITECTURE.md): the writer of
// src/library/support/sentence counts the bytes that its buffer does not hold, and its
// text (written) ends with the cut mark. A source that sets the count of a
// writer by hand keeps the count of the dropped bytes of the text before;
// a source that reads the buffer of a writer by hand reads a text with no
// mark. This check refuses both, outside src/library/support/sentence, for a variable
// named `writer`: the name that each source of the system gives to its
// writer today. It cannot see a writer of another name: it reads text, not
// types.
TEXT_CUT_CHECKED_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_KERNEL, foundation.SOURCE_FOLDER_CONTRACT, foundation.SOURCE_FOLDER_SUPPORT, foundation.SOURCE_FOLDER_PRIVATE, foundation.SOURCE_FOLDER_MODULES}
TEXT_CUT_WRITER_FOLDER :: foundation.SOURCE_FOLDER_SUPPORT + "/sentence"

text_cut_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	folders := TEXT_CUT_CHECKED_FOLDERS
	for folder in folders {
		foundation.source_files_of_a_folder(folder, &files) or_return
	}
	found := 0
	for path in files {
		if strings.has_prefix(path, TEXT_CUT_WRITER_FOLDER + "/") || strings.has_suffix(path, "_test.odin") {
			continue
		}
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: test failed: cannot read %s: %v", path, read_error)
			return false
		}
		for line in text_cut_problems(string(bytes)) {
			fmt.eprintfln("modustool: test failed: %s:%d sets the count of a writer or reads its buffer by hand: use writer_reset and written, so that a cut text keeps its mark", path, line)
			found += 1
		}
	}
	if found > 0 {
		return false
	}
	foundation.test_passed_print("no source sets the count of a writer or reads its buffer by hand (%d files read)", len(files))
	return true
}

// text_cut_problems gives the numbers, from 1, of the lines of a source
// that set `writer.count` (an assignment, not a comparison) or read
// `writer.buffer[`.
text_cut_problems :: proc(text: string) -> [dynamic]int {
	lines := make([dynamic]int, context.temp_allocator)
	rest := text
	number := 0
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		code := line
		if comment := strings.index(code, "//"); comment >= 0 {
			code = code[:comment]
		}
		if name_place(code, "writer.buffer[", 0) >= 0 || count_assigned(code) {
			append(&lines, number)
		}
	}
	return lines
}

// name_place gives the place of the first `text` at or after `from` that
// starts a name: the variable `writer`, not a longer name that ends with
// it, such as `command_writer`. -1: none.
@(private = "file")
name_place :: proc(code: string, text: string, from: int) -> int {
	at := from
	for at <= len(code) {
		index := strings.index(code[at:], text)
		if index < 0 {
			return -1
		}
		place := at + index
		if place == 0 {
			return place
		}
		before := code[place - 1]
		if !(before == '_' || before >= 'a' && before <= 'z' || before >= 'A' && before <= 'Z' || before >= '0' && before <= '9') {
			return place
		}
		at = place + len(text)
	}
	return -1
}

// count_assigned says if a line assigns to writer.count: "=", "+=", "-="
// after it, not "==".
@(private = "file")
count_assigned :: proc(code: string) -> bool {
	at := 0
	for {
		place := name_place(code, "writer.count", at)
		if place < 0 {
			return false
		}
		after := strings.trim_left_space(code[place + len("writer.count"):])
		if strings.has_prefix(after, "=") && !strings.has_prefix(after, "==") || strings.has_prefix(after, "+=") || strings.has_prefix(after, "-=") {
			return true
		}
		at = place + len("writer.count")
	}
}
