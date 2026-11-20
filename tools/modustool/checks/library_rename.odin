// The command rename-library: the moves and the rewrites of the step of the
// two source libraries, as a command that each branch runs after its merge
// of master (src/md/infrastructure/branch_batches.md; docs/TOOLS.md, "The
// rename of the library").
//
//   modustool rename-library
//
// It is idempotent: a second run moves and rewrites nothing. The moves and
// the reads of git go through a Library_Rename_Host, so the host tests run
// the command on a temporary tree with no git.
//
// This file names the old forms in its own table, and not through the
// constants of the folders of the tool: the step changes those by hand, and
// the command must read the same before and after. The command reads
// neither this file nor its test.
package checks

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// An old form and its new form.
Library_Rename_Rule :: struct {
	old, new: string,
}

// The folders, in the order of their moves: a file keeps its place under
// its folder.
LIBRARY_RENAME_FOLDERS :: [?]Library_Rename_Rule {
	{"src/library/support", "src/library/modus"},
	{"src/library/contract", "src/library/modus/contract"},
	{"src/library/private", "src/library/internal"},
}

// The start of the path of an import line. An import of a contract
// package does not change.
LIBRARY_RENAME_IMPORTS :: [?]Library_Rename_Rule {
	{"modus:support/", "modus:"},
	{"modus:private/", "internal:"},
}

// The forms of a text: a document, or a comment of a source.
LIBRARY_RENAME_TEXT_RULES :: [?]Library_Rename_Rule {
	{"modus:support/", "modus:"},
	{"modus:private/", "internal:"},
	{"src/library/support", "src/library/modus"},
	{"src/library/contract", "src/library/modus/contract"},
	{"src/library/private", "src/library/internal"},
}

// The files that hold the old forms on purpose: the designs of the step
// and of the SDK, the design of this command, and this command.
LIBRARY_RENAME_KEPT_FILES :: [?]string {
	"src/md/infrastructure/branch_batches.md",
	"src/md/infrastructure/repository_layout.md",
	"src/md/infrastructure/sdk.md",
	foundation.TOOL_SOURCE_FOLDER + "/checks/library_rename.odin",
	foundation.TOOL_SOURCE_FOLDER + "/checks/library_rename_test.odin",
}

// The folders of the records of their time: a news entry, a fragment of
// the changelog. The README.md of each is a guide, and is read.
LIBRARY_RENAME_RECORD_FOLDERS :: [?]string{NEWS_FOLDER, FRAGMENT_FOLDER}

// How the command reads a file.
Library_Rename_File_Kind :: enum {
	Not_Read,
	Odin_Source, // The import lines and the comments.
	Document, // The whole text.
}

library_rename_file_kind :: proc(path: string) -> Library_Rename_File_Kind {
	kept := LIBRARY_RENAME_KEPT_FILES
	if slice.contains(kept[:], path) || path == CHANGELOG_FILE || strings.has_prefix(path, MEASURE_RECORD_FOLDER + "/") {
		return .Not_Read
	}
	records := LIBRARY_RENAME_RECORD_FOLDERS
	for folder in records {
		if strings.has_prefix(path, folder) && len(path) > len(folder) && path[len(folder)] == '/' && path[len(folder) + 1:] != "README.md" {
			return .Not_Read
		}
	}
	switch {
	case strings.has_suffix(path, ".odin"):
		return .Odin_Source
	case strings.has_suffix(path, ".md") || strings.has_suffix(path, ".txt") || strings.has_suffix(path, ".manifest"):
		return .Document
	}
	return .Not_Read
}

// library_rename_name_byte tells whether a byte continues a name: an old
// form that such a byte touches is a part of another name.
library_rename_name_byte :: proc(character: u8) -> bool {
	switch character {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		return true
	}
	return false
}

// library_rename_text rewrites each old form of a text, and counts them. A
// form starts after a byte that is no byte of a name, and a form with no
// "/" at its end ends before such a byte: a relative link that ends with an
// old folder is rewritten, a longer name is not.
library_rename_text :: proc(text: string) -> (rewritten: string, count: int) {
	rules := LIBRARY_RENAME_TEXT_RULES
	builder := strings.builder_make(context.temp_allocator)
	copied := 0
	position := 0
	scan: for position < len(text) {
		if position == 0 || !library_rename_name_byte(text[position - 1]) {
			for rule in rules {
				end := position + len(rule.old)
				if !strings.has_prefix(text[position:], rule.old) {
					continue
				}
				if !strings.has_suffix(rule.old, "/") && end < len(text) && library_rename_name_byte(text[end]) {
					continue
				}
				strings.write_string(&builder, text[copied:position])
				strings.write_string(&builder, rule.new)
				position = end
				copied = end
				count += 1
				continue scan
			}
		}
		position += 1
	}
	if count == 0 {
		return text, 0
	}
	strings.write_string(&builder, text[copied:])
	return strings.to_string(builder), count
}

// library_rename_import_path rewrites the path of an import line.
library_rename_import_path :: proc(path: string) -> (rewritten: string, count: int) {
	rules := LIBRARY_RENAME_IMPORTS
	for rule in rules {
		if strings.has_prefix(path, rule.old) {
			return strings.concatenate({rule.new, path[len(rule.old):]}, context.temp_allocator), 1
		}
	}
	return path, 0
}

Library_Rename_Part_Kind :: enum {
	Comment,
	Import_Path, // The text between the quotes of the path of an import line.
}

// A part of an Odin source that the command rewrites: a byte range.
Library_Rename_Part :: struct {
	kind:       Library_Rename_Part_Kind,
	start, end: int,
}

// library_rename_line_is_import tells whether a line of code is an import
// line: its first word is `import`, after its attributes (`@(require)`).
library_rename_line_is_import :: proc(rest_of_source: string) -> bool {
	line := rest_of_source
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	line = strings.trim_left(line, " \t")
	for strings.has_prefix(line, "@") {
		line = line[1:]
		if strings.has_prefix(line, "(") {
			depth := 0
			end := 0
			for end < len(line) {
				if line[end] == '(' {
					depth += 1
				} else if line[end] == ')' {
					depth -= 1
					if depth == 0 {
						break
					}
				}
				end += 1
			}
			if end >= len(line) {
				return false
			}
			line = line[end + 1:]
		} else {
			end := 0
			for end < len(line) && library_rename_name_byte(line[end]) {
				end += 1
			}
			line = line[end:]
		}
		line = strings.trim_left(line, " \t")
	}
	if !strings.has_prefix(line, "import") || len(line) == len("import") {
		return false
	}
	after := line[len("import")]
	return after == ' ' || after == '\t' || after == '"'
}

// library_rename_odin_parts gives the comments of an Odin source and the
// path of each import line. It reads the strings, the raw strings and the
// rune literals of the code, so a "//" in a string is no comment, and a line
// of a raw string that starts with "import" is no import line.
library_rename_odin_parts :: proc(source: string) -> []Library_Rename_Part {
	parts := make([dynamic]Library_Rename_Part, context.temp_allocator)
	position := 0
	import_line := library_rename_line_is_import(source)
	for position < len(source) {
		character := source[position]
		next := position + 1 < len(source) ? source[position + 1] : 0
		switch {
		case character == '\n':
			position += 1
			import_line = library_rename_line_is_import(source[position:])
		case character == '/' && next == '/':
			end := strings.index_byte(source[position:], '\n')
			end = end < 0 ? len(source) : position + end
			append(&parts, Library_Rename_Part{kind = .Comment, start = position, end = end})
			position = end
		case character == '/' && next == '*':
			// Block comments nest in Odin.
			depth := 1
			end := position + 2
			for end < len(source) && depth > 0 {
				if strings.has_prefix(source[end:], "/*") {
					depth += 1
					end += 2
				} else if strings.has_prefix(source[end:], "*/") {
					depth -= 1
					end += 2
				} else {
					end += 1
				}
			}
			append(&parts, Library_Rename_Part{kind = .Comment, start = position, end = end})
			position = end
			import_line = false
		case character == '"' || character == '\'':
			// A string or a rune: on one line, with its escapes.
			end := position + 1
			for end < len(source) && source[end] != character && source[end] != '\n' {
				end += source[end] == '\\' ? 2 : 1
			}
			end = min(end, len(source))
			if character == '"' && import_line {
				append(&parts, Library_Rename_Part{kind = .Import_Path, start = position + 1, end = end})
			}
			import_line = false
			position = end < len(source) && source[end] == character ? end + 1 : end
		case character == '`':
			end := strings.index_byte(source[position + 1:], '`')
			position = end < 0 ? len(source) : position + 1 + end + 1
			import_line = false
		case:
			position += 1
		}
	}
	return parts[:]
}

// library_rename_odin rewrites the import lines and the comments of an Odin
// source. A string of the code stays: it is a text that a process draws or
// an example of a test, which a developer changes by hand.
library_rename_odin :: proc(source: string) -> (rewritten: string, count: int) {
	builder := strings.builder_make(context.temp_allocator)
	copied := 0
	for part in library_rename_odin_parts(source) {
		piece := source[part.start:part.end]
		new_piece: string
		changes: int
		switch part.kind {
		case .Comment:
			new_piece, changes = library_rename_text(piece)
		case .Import_Path:
			new_piece, changes = library_rename_import_path(piece)
		}
		if changes == 0 {
			continue
		}
		strings.write_string(&builder, source[copied:part.start])
		strings.write_string(&builder, new_piece)
		copied = part.end
		count += changes
	}
	if count == 0 {
		return source, 0
	}
	strings.write_string(&builder, source[copied:])
	return strings.to_string(builder), count
}

// library_rename_file rewrites a file by its kind.
library_rename_file :: proc(kind: Library_Rename_File_Kind, text: string) -> (rewritten: string, count: int) {
	switch kind {
	case .Not_Read:
		return text, 0
	case .Odin_Source:
		return library_rename_odin(text)
	case .Document:
		return library_rename_text(text)
	}
	return text, 0
}

// library_rename_leftovers gives each line of a file that still holds an old
// form: "<path>:<line>: <text>".
library_rename_leftovers :: proc(path, text: string) -> []string {
	leftovers := make([dynamic]string, context.temp_allocator)
	for line, index in foundation.lines_of_text(text) {
		if _, count := library_rename_text(line); count > 0 {
			append(&leftovers, fmt.tprintf("%s:%d: %s", path, index + 1, strings.trim_space(line)))
		}
	}
	return leftovers[:]
}

// One move of a folder or of a file, from the root of the repository.
Library_Move :: struct {
	from, to: string,
}

// library_path_occupied tells whether a tracked file is at a path or under it.
library_path_occupied :: proc(present: []string, path: string) -> bool {
	for file in present {
		if file == path || (strings.has_prefix(file, path) && len(file) > len(path) && file[len(path)] == '/') {
			return true
		}
	}
	return false
}

// library_path_under_a_file tells whether a folder on the way to a path is a
// tracked file: no file can go there.
library_path_under_a_file :: proc(present: []string, path: string) -> bool {
	for place in 0 ..< len(path) {
		if path[place] == '/' && slice.contains(present, path[:place]) {
			return true
		}
	}
	return false
}

// library_paths_move gives each tracked file at or under `from` its place
// under `to`.
library_paths_move :: proc(present: []string, from, to: string) {
	for &file in present {
		if file == from || (strings.has_prefix(file, from) && len(file) > len(from) && file[len(from)] == '/') {
			file = strings.concatenate({to, file[len(from):]}, context.temp_allocator)
		}
	}
}

// library_rename_moves gives the moves of the tracked files of the old
// folders, and a sentence for each file that cannot move. A move takes the
// largest folder on the way to a file whose new place holds no tracked
// file: the whole old folder on a tree before the rename, a package or a
// file that a branch added at an old place after it.
library_rename_moves :: proc(tracked: []string) -> (moves: []Library_Move, collisions: []string) {
	present := slice.clone(tracked, context.temp_allocator)
	slice.sort(present)
	move_list := make([dynamic]Library_Move, context.temp_allocator)
	collision_list := make([dynamic]string, context.temp_allocator)
	folders := LIBRARY_RENAME_FOLDERS
	for rule in folders {
		old_start := strings.concatenate({rule.old, "/"}, context.temp_allocator)
		under := make([dynamic]string, context.temp_allocator)
		for file in present {
			if strings.has_prefix(file, old_start) {
				append(&under, file)
			}
		}
		for file in under {
			// A folder that moved before took the file with it.
			if !slice.contains(present, file) {
				continue
			}
			relative := file[len(old_start):]
			// The candidates, from the largest: the whole old folder (-1),
			// each folder on the way, then the file.
			candidate_end := -1
			for {
				from, to := rule.old, rule.new
				if candidate_end >= 0 {
					from = strings.concatenate({old_start, relative[:candidate_end]}, context.temp_allocator)
					to = strings.concatenate({rule.new, "/", relative[:candidate_end]}, context.temp_allocator)
				}
				if library_path_under_a_file(present, to) {
					append(&collision_list, fmt.tprintf("%s: a folder on the way to %s is a file", file, to))
					break
				}
				if !library_path_occupied(present, to) {
					append(&move_list, Library_Move{from = from, to = to})
					library_paths_move(present, from, to)
					break
				}
				if candidate_end == len(relative) {
					append(&collision_list, fmt.tprintf("%s: %s is a tracked file already; keep one of the two by hand", file, to))
					break
				}
				next := strings.index_byte(relative[candidate_end + 1:], '/')
				candidate_end = next < 0 ? len(relative) : candidate_end + 1 + next
			}
		}
	}
	return move_list[:], collision_list[:]
}

// The steps of the command that reach git.
Library_Rename_Host :: struct {
	data:          rawptr,
	// Each tracked file, from the root.
	tracked_files: proc(data: rawptr) -> (files: []string, ok: bool),
	// Moves a tracked folder or file; the folder above `to` exists.
	move:          proc(data: rawptr, from, to: string) -> bool,
}

// A file that the command rewrote.
Library_Rename_Change :: struct {
	path:  string,
	count: int,
}

Library_Rename_Report :: struct {
	moves:      []Library_Move,
	changes:    []Library_Rename_Change,
	leftovers:  []string, // The lines that still hold an old form, for a hand change.
	files_left: []string, // The files that git does not track, left in an old folder.
}

library_rename_join :: proc(root, path: string) -> string {
	return strings.concatenate({root, "/", path}, context.temp_allocator)
}

// library_folder_empty_remove removes each empty folder under a folder,
// the folder too when it ends empty, and gives each file that is left.
library_folder_empty_remove :: proc(folder: string, left: ^[dynamic]string) {
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return
	}
	for entry in entries {
		path := library_rename_join(folder, entry.name)
		if entry.type == .Directory {
			library_folder_empty_remove(path, left)
		} else {
			append(left, path)
		}
	}
	remaining, remaining_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if remaining_error == nil && len(remaining) == 0 {
		_ = os.remove(folder)
	}
}

// library_rename_run moves the old folders under `root`, then rewrites the
// files. It changes nothing when a move cannot be made.
library_rename_run :: proc(root: string, host: Library_Rename_Host) -> (report: Library_Rename_Report, ok: bool) {
	tracked, tracked_ok := host.tracked_files(host.data)
	if !tracked_ok {
		fmt.eprintln("modustool: rename-library: git cannot list the tracked files; nothing changed")
		return {}, false
	}
	moves, collisions := library_rename_moves(tracked)
	refusals := make([dynamic]string, context.temp_allocator)
	append(&refusals, ..collisions)
	for move in moves {
		if os.exists(library_rename_join(root, move.to)) {
			append(&refusals, fmt.tprintf("%s: %s exists, and git tracks no file in it; move it away", move.from, move.to))
		}
	}
	if len(refusals) > 0 {
		for refusal in refusals {
			fmt.eprintfln("modustool: rename-library: %s", refusal)
		}
		fmt.eprintln("modustool: rename-library: nothing changed")
		return {}, false
	}
	for move, place in moves {
		target := library_rename_join(root, move.to)
		parent := target[:strings.last_index_byte(target, '/')]
		// The folder above a move exists already when its error is "exists".
		folder_made := os.make_directory_all(parent) == nil || os.is_dir(parent)
		if !folder_made || !host.move(host.data, move.from, move.to) {
			fmt.eprintfln("modustool: rename-library: the move of %s to %s failed after %d of %d moves; `git status` shows them", move.from, move.to, place, len(moves))
			return {}, false
		}
		fmt.printfln("modustool: rename-library: moved %s to %s", move.from, move.to)
	}
	files_left := make([dynamic]string, context.temp_allocator)
	folders := LIBRARY_RENAME_FOLDERS
	for rule in folders {
		library_folder_empty_remove(library_rename_join(root, rule.old), &files_left)
	}
	tracked_after, tracked_after_ok := host.tracked_files(host.data)
	if !tracked_after_ok {
		fmt.eprintln("modustool: rename-library: git cannot list the tracked files after the moves; no text was rewritten")
		return {}, false
	}
	changes := make([dynamic]Library_Rename_Change, context.temp_allocator)
	leftovers := make([dynamic]string, context.temp_allocator)
	for path in tracked_after {
		kind := library_rename_file_kind(path)
		if kind == .Not_Read {
			continue
		}
		file_path := library_rename_join(root, path)
		content, read_error := os.read_entire_file(file_path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: rename-library: cannot read %s: %v", path, read_error)
			return {}, false
		}
		rewritten, count := library_rename_file(kind, string(content))
		if count > 0 {
			if write_error := os.write_entire_file(file_path, rewritten); write_error != nil {
				fmt.eprintfln("modustool: rename-library: cannot write %s: %v", path, write_error)
				return {}, false
			}
			append(&changes, Library_Rename_Change{path = path, count = count})
		}
		append(&leftovers, ..library_rename_leftovers(path, rewritten))
	}
	return {moves = moves, changes = changes[:], leftovers = leftovers[:], files_left = files_left[:]}, true
}

// The host of git: the paths are from the root of the repository, where
// the tool runs.

library_rename_git_tracked_files :: proc(data: rawptr) -> (files: []string, ok: bool) {
	output := command_output(command_words("git", "ls-files", "-z")) or_return
	list := make([dynamic]string, context.temp_allocator)
	for file in strings.split(output, "\x00", context.temp_allocator) {
		if file != "" {
			append(&list, file)
		}
	}
	return list[:], true
}

library_rename_git_move :: proc(data: rawptr, from, to: string) -> bool {
	return foundation.run(command_words("git", "mv", from, to))
}

run_rename_library :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("modustool: rename-library takes no argument")
		return foundation.EXIT_USAGE
	}
	// A file in conflict holds the text of both sides: resolve it first.
	unmerged, unmerged_ok := command_output(command_words("git", "ls-files", "-u"))
	if !unmerged_ok || strings.trim_space(unmerged) != "" {
		fmt.eprintln("modustool: rename-library: the tree has files in conflict, or git cannot list them: resolve the merge first; nothing changed")
		return foundation.EXIT_FAILURE
	}
	report, ok := library_rename_run(".", {tracked_files = library_rename_git_tracked_files, move = library_rename_git_move})
	if !ok {
		return foundation.EXIT_FAILURE
	}
	total := 0
	for change in report.changes {
		fmt.printfln("modustool: rename-library: rewrote %s: %d forms", change.path, change.count)
		total += change.count
	}
	for file in report.files_left {
		fmt.printfln("modustool: rename-library: left %s: git does not track it, so it stays in an old folder", file)
	}
	for leftover in report.leftovers {
		fmt.printfln("modustool: rename-library: an old form in a string, for a hand change: %s", leftover)
	}
	fmt.printfln("modustool: rename-library: %d moves, %d forms in %d files, %d lines left for a hand change", len(report.moves), total, len(report.changes), len(report.leftovers))
	return 0
}
