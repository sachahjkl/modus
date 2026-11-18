package modustool

import "core:strings"
import "core:testing"

// The folders of the sources of a small tree, at the root.
@(private = "file")
TREE_FOLDERS_AT_THE_ROOT :: [?]string{"kernel", "processes", "modules", "support"}

// The same folders after a move under one folder.
@(private = "file")
TREE_FOLDERS_MOVED :: [?]string{"src/kernel", "src/processes", "src/modules", "src/library/support"}

// The files and the folders of the small tree, before the move.
@(private = "file")
tree_at_the_root_exists :: proc(path: string) -> bool {
	switch path {
	case "kernel", "kernel/enter.odin", "processes", "processes/console", "processes/console/main.odin", "modules", "support", "support/system":
		return true
	}
	return false
}

// The files and the folders of the small tree, after the move.
@(private = "file")
tree_moved_exists :: proc(path: string) -> bool {
	switch path {
	case "src", "src/kernel", "src/kernel/enter.odin", "src/processes", "src/processes/console", "src/library", "src/library/support", "src/library/support/system":
		return true
	}
	return false
}

@(private = "file")
problems_at_the_root :: proc(content: string) -> ([]string, int) {
	folders := TREE_FOLDERS_AT_THE_ROOT
	return source_path_problems("docs/GUIDE.md", content, folders[:], tree_at_the_root_exists)
}

// A path that exists has no fault: a file, a folder, a folder with its
// "/", a path with a line number, and a path before words.
@(test)
source_path_that_exists_has_no_fault :: proc(t: ^testing.T) {
	problems, count := problems_at_the_root("# A guide\n\nThe entry is `kernel/enter.odin`, in `kernel/`. The console is `processes/console`.\nThe line is `kernel/enter.odin:34`. The package `support/system` and `processes/console/main.odin, the first line`.\n")
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, count, 6)
}

// A path that names nothing is a fault, with the document, the line and
// the span. A line number does not hide it.
@(test)
source_path_that_does_not_exist_is_a_fault :: proc(t: ^testing.T) {
	problems, count := problems_at_the_root("# A guide\n\nGood: `kernel/enter.odin`.\nGone: `kernel/gone.odin`.\n\nGone with a line: `processes/console/gone.odin:12`.\n## A heading with `support/gone`\n")
	testing.expect_value(t, count, 4)
	if !testing.expect_value(t, len(problems), 3) {
		return
	}
	testing.expect(t, strings.contains(problems[0], "docs/GUIDE.md, line 4") && strings.contains(problems[0], "`kernel/gone.odin`"), problems[0])
	testing.expect(t, strings.contains(problems[1], "line 6") && strings.contains(problems[1], "names processes/console/gone.odin,"), problems[1])
	testing.expect(t, strings.contains(problems[2], "line 7") && strings.contains(problems[2], "support/gone"), problems[2])
}

// The name of a source folder inside a longer path, inside a word, alone,
// or in an import line is not the start of a source path: the span is not
// read, whatever it names.
@(test)
source_path_inside_a_longer_path_is_not_read :: proc(t: ^testing.T) {
	problems, count := problems_at_the_root("The output is `build/modules/gone`, the pages are in `docs/reference/modules/`.\nRun `modustool check`. The module `kernel`. An import: `\"modus:support/gone\"`, or `modus:support/gone`.\nA path of the host: `/kernel/gone`, and `./kernel/gone`.\n")
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, count, 0)
}

// A pattern and a name that is not written out end the path at the folder
// before them: that folder must exist.
@(test)
source_path_with_a_pattern_names_its_folder :: proc(t: ^testing.T) {
	problems, count := problems_at_the_root("Each process: `processes/*/main.odin`, `processes/<name>/main.odin`, `processes/console/*_test.odin`, `kernel/enter_*.odin`.\n")
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, count, 4)
	problems, count = problems_at_the_root("Gone: `processes/gone/*.odin` and `modules/gone/<name>`.\n")
	testing.expect_value(t, count, 2)
	if testing.expect_value(t, len(problems), 2) {
		testing.expect(t, strings.contains(problems[0], "names processes/gone,"), problems[0])
		testing.expect(t, strings.contains(problems[1], "names modules/gone,"), problems[1])
	}
}

// A fence of code is not read: it holds a tree or a log.
@(test)
source_path_in_a_fence_is_not_read :: proc(t: ^testing.T) {
	problems, count := problems_at_the_root("Text.\n\n```\n`kernel/gone.odin`\n```\n\nAfter the fence: `kernel/gone.odin`.\n")
	testing.expect_value(t, count, 1)
	if testing.expect_value(t, len(problems), 1) {
		testing.expect(t, strings.contains(problems[0], "line 7"), problems[0])
	}
}

// After a move, a span that still starts with the old name of a folder is
// read and refused, and the sentence gives the new path. A path under the
// new folder is read. A path under the first part of a new folder that is
// not a folder of the sources is not read: a design names there a folder
// of a later state or of a refused form.
@(test)
source_path_of_before_a_move_is_refused :: proc(t: ^testing.T) {
	folders := TREE_FOLDERS_MOVED
	problems, count := source_path_problems("README.md", "Old: `kernel/enter.odin` and `support/system`.\nNew: `src/kernel/enter.odin`, `src/library/support/system`.\nGone: `src/kernel/gone.odin`, `kernel/gone.odin`.\nNot a folder of the sources: `src/md/gone.md`, `src/modus/contract`, `src/library`.\n", folders[:], tree_moved_exists)
	testing.expect_value(t, count, 6)
	if !testing.expect_value(t, len(problems), 4) {
		return
	}
	testing.expect(t, strings.contains(problems[0], "line 1") && strings.contains(problems[0], "which is now src/kernel/enter.odin"), problems[0])
	testing.expect(t, strings.contains(problems[1], "which is now src/library/support/system"), problems[1])
	testing.expect(t, strings.contains(problems[2], "line 3") && strings.contains(problems[2], "names src/kernel/gone.odin,") && strings.contains(problems[2], "no such file"), problems[2])
	testing.expect(t, strings.contains(problems[3], "names kernel/gone.odin,") && strings.contains(problems[3], "no such file"), problems[3])
}

// The starts of a source path: each folder and its last part, one time
// each.
@(test)
source_path_starts_of_the_folders :: proc(t: ^testing.T) {
	folders := TREE_FOLDERS_MOVED
	starts := source_path_starts(folders[:])
	testing.expect_value(t, strings.join(starts, " ", context.temp_allocator), "src/kernel/ kernel/ src/processes/ processes/ src/modules/ modules/ src/library/support/ support/")
	at_the_root := TREE_FOLDERS_AT_THE_ROOT
	testing.expect_value(t, strings.join(source_path_starts(at_the_root[:]), " ", context.temp_allocator), "kernel/ processes/ modules/ support/")
}

// The files of a small tree of the tool.
@(private = "file")
tree_of_the_tool_exists :: proc(path: string) -> bool {
	switch path {
	case "tools", "tools/modustool", "tools/modustool/main.odin", "tools/modustool/build", "tools/modustool/build/modules.odin":
		return true
	}
	return false
}

// A span that names a file of the tool is read: a file that is gone, also
// one that moved into a package of the tool, is refused. A span with the
// name of the tool inside a longer path or alone is not read.
@(test)
source_path_of_a_file_of_the_tool_is_read :: proc(t: ^testing.T) {
	folders := [?]string{TOOLS_FOLDER}
	problems, count := source_path_problems("docs/TOOLS.md", "Good: `tools/modustool/main.odin`, `tools/modustool/build/modules.odin`, `tools/modustool/*_scenario.odin`, `tools/modustool`.\nGone: `tools/modustool/modules.odin`, `tools/modustool/gone/*.odin`.\nNot read: `modustool check`, `build/tools/gone`, `./tools/gone`.\n", folders[:], tree_of_the_tool_exists)
	testing.expect_value(t, count, 6)
	if !testing.expect_value(t, len(problems), 2) {
		return
	}
	testing.expect(t, strings.contains(problems[0], "line 2") && strings.contains(problems[0], "names tools/modustool/modules.odin,") && strings.contains(problems[0], "no such file"), problems[0])
	testing.expect(t, strings.contains(problems[1], "names tools/modustool/gone,"), problems[1])
}

// The check of the repository reads the spans of the files of the tool,
// and each one names a file or a folder that exists.
@(test)
source_paths_of_the_tool_in_the_documents_of_the_repository :: proc(t: ^testing.T) {
	folders := [?]string{TOOLS_FOLDER}
	problems, span_count, _, read := source_path_problems_of_the_documents(folders[:])
	if !testing.expect(t, read, "the documents are read") {
		return
	}
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}
	testing.expect(t, span_count > 100, "the documents hold too few spans of the tool: the check reads none")
	checked := source_path_checked_folders()
	testing.expect_value(t, checked[len(checked) - 1], TOOLS_FOLDER)
}

// The documents of the repository name sources that exist.
@(test)
source_paths_of_the_documents_of_the_repository :: proc(t: ^testing.T) {
	problems, span_count, document_count, read := source_path_problems_of_the_repository()
	if !testing.expect(t, read, "the documents are read") {
		return
	}
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}
	testing.expect(t, span_count > 100, "the documents hold too few source paths: the check reads nothing")
	testing.expect(t, document_count > 10, "the check reads too few documents")
}
