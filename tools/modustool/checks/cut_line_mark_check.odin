package checks

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// A reading tool of an agent shows a long line cut, with this mark at the
// cut. A file written back from such a read loses the end of each long line
// in silence: two intent files lost the end of a paragraph that way. This
// check refuses the mark in each file of the folders that the check of the
// flake copies, where no .git lists the tracked files. The mark is built from
// two parts, so that this source and its test do not hold it.
CUT_LINE_MARK :: "(line truncated " + "to "
CUT_LINE_MARK_FOLDERS :: [?]string{"docs", "src", "tools", "changelog.d", "news", ".project"}
CUT_LINE_MARK_ROOT_FILES :: [?]string{"README.md", "AGENTS.md", "CHANGELOG.md", "ROADMAP.md", "CONTRIBUTING.md", "flake.nix"}

cut_line_mark_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	root_files := CUT_LINE_MARK_ROOT_FILES
	append(&files, ..root_files[:])
	folders := CUT_LINE_MARK_FOLDERS
	for folder in folders {
		files_of_a_folder(folder, &files) or_return
	}
	found := 0
	for path in files {
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: test failed: cannot read %s: %v", path, read_error)
			return false
		}
		for line in cut_line_mark_problems(string(bytes)) {
			fmt.eprintfln("modustool: test failed: %s:%d holds the mark %q of a line that a reading tool cut: take the whole line from the history (git log -p), and write the file with exact edits, never back from a cut read", path, line, CUT_LINE_MARK)
			found += 1
		}
	}
	if found > 0 {
		return false
	}
	foundation.test_passed_print("no file holds the mark of a line cut by a reading tool (%d files read)", len(files))
	return true
}

// cut_line_mark_problems gives the numbers, from 1, of the lines of a text
// that hold the mark, one number for each line.
cut_line_mark_problems :: proc(text: string) -> [dynamic]int {
	lines := make([dynamic]int, context.temp_allocator)
	rest := text
	number := 0
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		if strings.contains(line, CUT_LINE_MARK) {
			append(&lines, number)
		}
	}
	return lines
}

// files_of_a_folder appends the path of each file under a folder, of any
// kind: a mark in a text of another extension is the same fault.
@(private = "file")
files_of_a_folder :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: test failed: cannot list %s: %v", folder, err)
		return false
	}
	for entry in entries {
		path := foundation.join(folder, "/", entry.name)
		switch {
		case entry.type == .Directory:
			files_of_a_folder(path, files) or_return
		case entry.type == .Regular:
			append(files, path)
		}
	}
	return true
}
