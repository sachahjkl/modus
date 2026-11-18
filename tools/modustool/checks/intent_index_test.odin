package checks

import "core:strings"
import "core:testing"

@(private = "file")
GOOD_INTENT_README :: `# The intent

An overview. A guide: [` + "`docs/CONSOLE.md`" + `](../../docs/CONSOLE.md), "The palette provider".

` + "```" + `
## File Index
- [in/a/fence.md](in/a/fence.md): an example, not an entry
` + "```" + `

## File Index

- [features/palette.md](features/palette.md): the palette and its provider
- [infrastructure/build.md](infrastructure/build.md): the build of a module
`

@(private = "file")
GOOD_INTENT_FILE :: `# The palette

The build is in [infrastructure/build.md](../infrastructure/build.md#the-key).
A site: [the standard](https://srcmd.org). A place of this file: [below](#below).
A code span is not a link: ` + "`[text](nowhere.md)`" + `.
`

// The one document outside the intent folder that the test tree has.
@(private = "file")
test_outside_exists :: proc(path: string) -> bool {
	return path == "docs/CONSOLE.md"
}

@(private = "file")
good_intent_files :: proc() -> []Intent_File {
	files := make([]Intent_File, 3, context.temp_allocator)
	files[0] = {path = "README.md", content = GOOD_INTENT_README}
	files[1] = {path = "features/palette.md", content = GOOD_INTENT_FILE}
	files[2] = {path = "infrastructure/build.md", content = "# The build\n\nText.\n"}
	return files
}

// An index that lists each other file once, with links that name files,
// has no fault. An entry inside a fence of code is an example.
@(test)
intent_index_of_a_good_folder :: proc(t: ^testing.T) {
	problems := intent_index_problems(good_intent_files(), test_outside_exists)
	testing.expectf(t, len(problems) == 0, "%v", problems)
}

// Each fault of the folder is named, one at a time.
@(test)
intent_index_names_each_fault :: proc(t: ^testing.T) {
	Case :: struct {
		change: proc(files: []Intent_File) -> []Intent_File,
		words:  string,
	}
	cases := [?]Case {
		{proc(files: []Intent_File) -> []Intent_File {
				return files[1:]
			}, "does not exist"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content, _ = strings.replace_all(files[0].content, "\n## File Index\n\n-", "\n## Files\n\n-", context.temp_allocator)
				return files
			}, "has 0 headings"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content, _ = strings.replace_all(files[0].content, "- [infrastructure/build.md](infrastructure/build.md): the build of a module\n", "", context.temp_allocator)
				return files
			}, "infrastructure/build.md is not in the file index"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [features/palette.md](features/palette.md): a second time\n"}, context.temp_allocator)
				return files
			}, "features/palette.md is 2 times in the file index"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [data/absent.md](data/absent.md): a file that is not there\n"}, context.temp_allocator)
				return files
			}, "the entry data/absent.md names no file"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [features/palette.md](features/palette.md)\n"}, context.temp_allocator)
				return files
			}, "one link and a description"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [README.md](README.md): the index itself\n"}, context.temp_allocator)
				return files
			}, "not itself"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [../../docs/CONSOLE.md](../../docs/CONSOLE.md): a guide\n"}, context.temp_allocator)
				return files
			}, "is not a path from the intent folder"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[2].content = "## The build\n\nText.\n"
				return files
			}, "infrastructure/build.md: the first heading of the file is not a heading of level 1"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[1].content = strings.concatenate({files[1].content, "See [the scheduler](scheduler.md).\n"}, context.temp_allocator)
				return files
			}, "features/palette.md, line 6: the link to scheduler.md names no file"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[1].content = strings.concatenate({files[1].content, "See [a guide](../../docs/ABSENT.md).\n"}, context.temp_allocator)
				return files
			}, "the link to ../../docs/ABSENT.md names no file"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[1].content = strings.concatenate({files[1].content, "See [outside](../../../other/file.md).\n"}, context.temp_allocator)
				return files
			}, "the link to ../../../other/file.md names no file"},
	}
	for test_case, case_index in cases {
		problems := intent_index_problems(test_case.change(good_intent_files()), test_outside_exists)
		found := false
		for problem in problems {
			found ||= strings.contains(problem, test_case.words)
		}
		testing.expectf(t, found, "case %d: no problem with the words %q in %v", case_index, test_case.words, problems)
	}
}

// The path that a relative link names, from the root of the repository.
@(test)
intent_link_paths :: proc(t: ^testing.T) {
	Case :: struct {
		file, target, path: string,
		ok:                 bool,
	}
	cases := [?]Case {
		{"src/md/README.md", "features/palette.md", "src/md/features/palette.md", true},
		{"src/md/features/palette.md", "../infrastructure/build.md", "src/md/infrastructure/build.md", true},
		{"src/md/features/palette.md", "./form.md", "src/md/features/form.md", true},
		{"src/md/features/palette.md", "../../../docs/CONSOLE.md", "docs/CONSOLE.md", true},
		{"src/md/README.md", "../../../outside.md", "", false},
		{"src/md/README.md", "/etc/hosts", "", false},
	}
	for test_case in cases {
		path, ok := intent_link_path(test_case.file, test_case.target)
		testing.expectf(t, path == test_case.path && ok == test_case.ok, "%s from %s: %q, %v", test_case.target, test_case.file, path, ok)
	}
}

// The intent folder of the repository passes its check.
@(test)
intent_index_of_the_repository :: proc(t: ^testing.T) {
	files, read_ok := intent_files_read()
	testing.expect(t, read_ok, "the intent folder cannot be read")
	problems := intent_index_problems(files, intent_repository_path_exists)
	testing.expectf(t, len(problems) == 0, "%d faults: %v", len(problems), problems)
}
