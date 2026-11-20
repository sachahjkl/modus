package checks

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// The old and the new forms, from the tables of the command: a line of this
// file never starts as an import line of an old form.
@(private = "file")
OLD_SUPPORT_IMPORT :: "modus:support/"
@(private = "file")
OLD_PRIVATE_IMPORT :: "modus:private/"
@(private = "file")
OLD_SUPPORT :: "src/library/support"
@(private = "file")
OLD_CONTRACT :: "src/library/contract"
@(private = "file")
OLD_PRIVATE :: "src/library/private"
@(private = "file")
NEW_MODUS :: "src/library/modus"
@(private = "file")
NEW_INTERNAL :: "src/library/internal"

@(test)
rename_rewrites_each_old_form_of_a_text :: proc(t: ^testing.T) {
	Case :: struct {
		before, after: string,
		count:         int,
	}
	cases := []Case {
		{"", "", 0},
		{"no form here", "no form here", 0},
		{"`" + OLD_SUPPORT_IMPORT + "system`", "`modus:system`", 1},
		{"`" + OLD_PRIVATE_IMPORT + "storage/storage_tree`", "`internal:storage/storage_tree`", 1},
		{"`" + "modus:contract/ring`", "`modus:contract/ring`", 0},
		{OLD_SUPPORT + "/system/system.odin", NEW_MODUS + "/system/system.odin", 1},
		{OLD_CONTRACT + "/release/release.odin", NEW_MODUS + "/contract/release/release.odin", 1},
		{OLD_PRIVATE + "/console/bar", NEW_INTERNAL + "/console/bar", 1},
		// A folder alone, at the end of a sentence and of the text.
		{"in " + OLD_SUPPORT + ".", "in " + NEW_MODUS + ".", 1},
		{OLD_PRIVATE, NEW_INTERNAL, 1},
		// A relative link.
		{"[x](../../../" + OLD_SUPPORT + "/mark/mark.odin)", "[x](../../../" + NEW_MODUS + "/mark/mark.odin)", 1},
		// Longer names are other names.
		{OLD_SUPPORT + "ing/x", OLD_SUPPORT + "ing/x", 0},
		{OLD_CONTRACT + "_list", OLD_CONTRACT + "_list", 0},
		{OLD_PRIVATE + "-parts", OLD_PRIVATE + "-parts", 0},
		{"x" + OLD_SUPPORT + "/a", "x" + OLD_SUPPORT + "/a", 0},
		{"my_" + OLD_SUPPORT_IMPORT + "a", "my_" + OLD_SUPPORT_IMPORT + "a", 0},
		{"2" + OLD_PRIVATE_IMPORT + "a", "2" + OLD_PRIVATE_IMPORT + "a", 0},
		// Several forms in one text, at its two ends.
		{OLD_SUPPORT_IMPORT + "a and " + OLD_CONTRACT, "modus:a and " + NEW_MODUS + "/contract", 2},
	}
	for each in cases {
		after, count := library_rename_text(each.before)
		testing.expectf(t, after == each.after && count == each.count, "%q gave %q with %d forms, not %q with %d", each.before, after, count, each.after, each.count)
		// A second run changes nothing.
		again, again_count := library_rename_text(after)
		testing.expectf(t, again == after && again_count == 0, "%q changed again to %q", after, again)
	}
}

@(test)
rename_reads_the_import_lines_and_the_comments_of_a_source_only :: proc(t: ^testing.T) {
	source := strings.concatenate({
		"package p\n\n",
		"import \"" + OLD_SUPPORT_IMPORT + "system\"\n",
		"import storage_tree \"" + OLD_PRIVATE_IMPORT + "storage/storage_tree\"\n",
		"@(require) import crypto \"" + OLD_SUPPORT_IMPORT + "cryptography/compatibility_crypto\"\n",
		"\t@(require)\timport\t\"" + OLD_SUPPORT_IMPORT + "graphics\"\n",
		"import ring \"modus:contract/ring\"\n",
		"foreign import library \"system:c\"\n",
		"// The page of " + OLD_SUPPORT + "/system, and " + OLD_PRIVATE_IMPORT + "console/bar.\n",
		"/* A block /* nested " + OLD_CONTRACT + " */ still " + OLD_SUPPORT + " */\n",
		"QUOTE :: '\"' // after a rune: " + OLD_PRIVATE + "\n",
		"ESCAPE :: '\\'' // " + OLD_SUPPORT + "\n",
		"TEXT :: \"a // " + OLD_SUPPORT + " \\\" " + OLD_SUPPORT_IMPORT + "x\"\n",
		"RAW :: `\nimport \"" + OLD_SUPPORT_IMPORT + "absent\"\n// " + OLD_SUPPORT + "\n`\n",
		"imported := \"" + OLD_SUPPORT_IMPORT + "drawn\"\n",
	}, context.temp_allocator)
	expected := strings.concatenate({
		"package p\n\n",
		"import \"modus:system\"\n",
		"import storage_tree \"internal:storage/storage_tree\"\n",
		"@(require) import crypto \"modus:cryptography/compatibility_crypto\"\n",
		"\t@(require)\timport\t\"modus:graphics\"\n",
		"import ring \"modus:contract/ring\"\n",
		"foreign import library \"system:c\"\n",
		"// The page of " + NEW_MODUS + "/system, and internal:console/bar.\n",
		"/* A block /* nested " + NEW_MODUS + "/contract */ still " + NEW_MODUS + " */\n",
		"QUOTE :: '\"' // after a rune: " + NEW_INTERNAL + "\n",
		"ESCAPE :: '\\'' // " + NEW_MODUS + "\n",
		"TEXT :: \"a // " + OLD_SUPPORT + " \\\" " + OLD_SUPPORT_IMPORT + "x\"\n",
		"RAW :: `\nimport \"" + OLD_SUPPORT_IMPORT + "absent\"\n// " + OLD_SUPPORT + "\n`\n",
		"imported := \"" + OLD_SUPPORT_IMPORT + "drawn\"\n",
	}, context.temp_allocator)
	rewritten, count := library_rename_odin(source)
	testing.expect_value(t, rewritten, expected)
	// Four import lines, two forms in the line comment, two in the block
	// comment, one after each rune.
	testing.expect_value(t, count, 10)
	again, again_count := library_rename_odin(rewritten)
	testing.expect_value(t, again, rewritten)
	testing.expect_value(t, again_count, 0)
	// The strings that keep an old form are left for a hand change.
	leftovers := library_rename_leftovers("p.odin", rewritten)
	testing.expect_value(t, len(leftovers), 4)
	if len(leftovers) == 4 {
		testing.expect(t, strings.has_prefix(leftovers[0], "p.odin:13: TEXT"))
		testing.expect(t, strings.has_prefix(leftovers[3], "p.odin:18: imported"))
	}
	// A source that ends inside a string, a rune, a raw string or a block
	// comment ends its part at its end.
	for unfinished in ([]string{"x := \"" + OLD_SUPPORT, "x := '", "x := `" + OLD_SUPPORT, "/* " + OLD_SUPPORT, "// " + OLD_SUPPORT, "import \"" + OLD_SUPPORT_IMPORT + "a", "@(", "import"}) {
		_, _ = library_rename_odin(unfinished)
	}
	testing.expect(t, !library_rename_line_is_import("imported := 1"))
	testing.expect(t, !library_rename_line_is_import("@(require"))
	testing.expect(t, !library_rename_line_is_import("// import \"x\""))
	testing.expect(t, library_rename_line_is_import("import\"x\""))
	testing.expect(t, library_rename_line_is_import("@private @(require) import x \"y\""))
}

@(test)
rename_reads_the_files_of_each_kind_and_skips_the_records :: proc(t: ^testing.T) {
	Case :: struct {
		path: string,
		kind: Library_Rename_File_Kind,
	}
	cases := []Case {
		{"src/kernel/enter.odin", .Odin_Source},
		{"docs/TOOLS.md", .Document},
		{"README.md", .Document},
		{OLD_SUPPORT + "/cryptography/origin.manifest", .Document},
		{OLD_SUPPORT + "/cryptography/LICENSE.odin.txt", .Document},
		{NEWS_FOLDER + "/README.md", .Document},
		{FRAGMENT_FOLDER + "/README.md", .Document},
		{"docs/" + NEWS_FOLDER + "/x.md", .Document},
		{NEWS_FOLDER + "/2026-11-20-the-editor-edit.md", .Not_Read},
		{FRAGMENT_FOLDER + "/20261120-130000-c-compiler.md", .Not_Read},
		{FRAGMENT_FOLDER + "/a/README.md", .Not_Read},
		{CHANGELOG_FILE, .Not_Read},
		{MEASURE_RECORD_FILE, .Not_Read},
		{MEASURE_RECORD_FOLDER + "/README.md", .Not_Read},
		{NEWS_FOLDER + "x/y.md", .Document},
		{"flake.nix", .Not_Read},
		{"docs/screenshots/console.png", .Not_Read},
		{"src/md/infrastructure/repository_layout.md", .Not_Read},
		{"src/md/infrastructure/branch_batches.md", .Not_Read},
		{"tools/modustool/checks/library_rename.odin", .Not_Read},
		{"tools/modustool/checks/library_rename_test.odin", .Not_Read},
		{"tools/modustool/checks/merge_queue.odin", .Odin_Source},
		{"", .Not_Read},
	}
	for each in cases {
		kind := library_rename_file_kind(each.path)
		testing.expectf(t, kind == each.kind, "%q is read as %v, not %v", each.path, kind, each.kind)
	}
}

@(private = "file")
rename_moves_text :: proc(moves: []Library_Move) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	for move in moves {
		append(&lines, fmt.tprintf("%s>%s", move.from, move.to))
	}
	return strings.join(lines[:], " ", context.temp_allocator)
}

@(test)
rename_moves_the_largest_folders_that_are_free :: proc(t: ^testing.T) {
	// A tree before the rename: three whole folders.
	before := []string{OLD_SUPPORT + "/system/system.odin", OLD_SUPPORT + "/cryptography/sha2/sha2.odin", OLD_CONTRACT + "/ring/ring.odin", OLD_PRIVATE + "/storage/storage_tree/tree.odin", OLD_SUPPORT + "ing/x.odin", "src/kernel/enter.odin"}
	moves, collisions := library_rename_moves(before)
	testing.expect_value(t, len(collisions), 0)
	testing.expect_value(t, rename_moves_text(moves), OLD_SUPPORT + ">" + NEW_MODUS + " " + OLD_CONTRACT + ">" + NEW_MODUS + "/contract " + OLD_PRIVATE + ">" + NEW_INTERNAL)
	// A tree after the rename: nothing moves.
	after := []string{NEW_MODUS + "/system/system.odin", NEW_MODUS + "/contract/ring/ring.odin", NEW_INTERNAL + "/storage/storage_tree/tree.odin"}
	moves, collisions = library_rename_moves(after)
	testing.expect_value(t, len(moves) + len(collisions), 0)
	moves, collisions = library_rename_moves(nil)
	testing.expect_value(t, len(moves) + len(collisions), 0)
	// A branch that merged master after the rename: a new package moves
	// whole, a new file of a package that moved goes alone, a new part of a
	// module with no internal part moves whole.
	branch := []string{NEW_MODUS + "/system/system.odin", NEW_MODUS + "/contract/ring/ring.odin", NEW_INTERNAL + "/storage/storage_tree/tree.odin", OLD_SUPPORT + "/sound/sound.odin", OLD_SUPPORT + "/sound/sound_test.odin", OLD_SUPPORT + "/system/added.odin", OLD_CONTRACT + "/ring/more/more.odin", OLD_PRIVATE + "/console/line/line.odin", OLD_PRIVATE + "/storage/storage_tree/added.odin"}
	moves, collisions = library_rename_moves(branch)
	testing.expect_value(t, len(collisions), 0)
	testing.expect_value(t, rename_moves_text(moves), OLD_SUPPORT + "/sound>" + NEW_MODUS + "/sound " + OLD_SUPPORT + "/system/added.odin>" + NEW_MODUS + "/system/added.odin " + OLD_CONTRACT + "/ring/more>" + NEW_MODUS + "/contract/ring/more " + OLD_PRIVATE + "/console>" + NEW_INTERNAL + "/console " + OLD_PRIVATE + "/storage/storage_tree/added.odin>" + NEW_INTERNAL + "/storage/storage_tree/added.odin")
}

@(test)
rename_refuses_a_file_that_has_no_free_place :: proc(t: ^testing.T) {
	// The same file at both places.
	both := []string{NEW_MODUS + "/system/system.odin", OLD_SUPPORT + "/system/system.odin", OLD_SUPPORT + "/system/free.odin"}
	moves, collisions := library_rename_moves(both)
	testing.expect_value(t, len(collisions), 1)
	testing.expect(t, len(collisions) == 1 && strings.has_prefix(collisions[0], OLD_SUPPORT + "/system/system.odin: "))
	testing.expect_value(t, len(moves), 1)
	// A file of the old folder where the new folder holds a folder.
	folder := []string{NEW_MODUS + "/a/inner.odin", OLD_SUPPORT + "/a"}
	_, collisions = library_rename_moves(folder)
	testing.expect_value(t, len(collisions), 1)
	// A folder of the old folder where the new folder holds a file.
	file := []string{NEW_MODUS + "/a", OLD_SUPPORT + "/a/inner.odin"}
	_, collisions = library_rename_moves(file)
	testing.expect_value(t, len(collisions), 1)
	testing.expect(t, len(collisions) == 1 && strings.contains(collisions[0], "is a file"))
	// The new folder is a file.
	whole := []string{NEW_MODUS, OLD_SUPPORT + "/a.odin"}
	_, collisions = library_rename_moves(whole)
	testing.expect_value(t, len(collisions), 1)
}

// A host of the command with no git: each file of the tree is tracked, and
// a move is a rename.
@(private = "file")
rename_test_tracked_files :: proc(data: rawptr) -> (files: []string, ok: bool) {
	root := (^string)(data)^
	list := make([dynamic]string, context.temp_allocator)
	rename_test_walk(root, "", &list)
	slice.sort(list[:])
	return list[:], true
}

@(private = "file")
rename_test_walk :: proc(root, relative: string, list: ^[dynamic]string) {
	folder := relative == "" ? root : strings.concatenate({root, "/", relative}, context.temp_allocator)
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return
	}
	for entry in entries {
		path := relative == "" ? strings.clone(entry.name, context.temp_allocator) : strings.concatenate({relative, "/", entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			rename_test_walk(root, path, list)
		} else {
			append(list, path)
		}
	}
}

@(private = "file")
rename_test_move :: proc(data: rawptr, from, to: string) -> bool {
	root := (^string)(data)^
	return os.rename(strings.concatenate({root, "/", from}, context.temp_allocator), strings.concatenate({root, "/", to}, context.temp_allocator)) == nil
}

@(private = "file")
rename_test_write :: proc(root, path, text: string) {
	full := strings.concatenate({root, "/", path}, context.temp_allocator)
	_ = os.make_directory_all(full[:strings.last_index_byte(full, '/')])
	_ = os.write_entire_file(full, text)
}

@(private = "file")
rename_test_read :: proc(root, path: string) -> string {
	content, error := os.read_entire_file(strings.concatenate({root, "/", path}, context.temp_allocator), context.temp_allocator)
	if error != nil {
		return "<absent>"
	}
	return string(content)
}

// rename_test_snapshot gives each file of the tree and its text, in order.
@(private = "file")
rename_test_snapshot :: proc(root: string, host: Library_Rename_Host) -> string {
	files, _ := host.tracked_files(host.data)
	builder := strings.builder_make(context.temp_allocator)
	for file in files {
		fmt.sbprintf(&builder, "%s\n%s\n", file, rename_test_read(root, file))
	}
	return strings.to_string(builder)
}

@(test)
rename_on_a_tree_is_idempotent_and_safe_on_a_branch :: proc(t: ^testing.T) {
	made, error := os.make_directory_temp("", "library_rename_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	if error != nil {
		return
	}
	root := made
	defer os.remove_all(root)
	host := Library_Rename_Host {
		data          = &root,
		tracked_files = rename_test_tracked_files,
		move          = rename_test_move,
	}
	support_source := "package system\n\n// See " + OLD_CONTRACT + "/ring.\nimport ring \"modus:contract/ring\"\nimport \"" + OLD_SUPPORT_IMPORT + "graphics\"\nNAME :: \"" + OLD_SUPPORT_IMPORT + "system\"\n"
	rename_test_write(root, OLD_SUPPORT + "/system/system.odin", support_source)
	rename_test_write(root, OLD_SUPPORT + "/cryptography/origin.manifest", OLD_SUPPORT + "/cryptography/sha2/sha2.odin core/crypto/sha2/sha2.odin 00\n")
	rename_test_write(root, OLD_CONTRACT + "/ring/ring.odin", "package ring\n")
	rename_test_write(root, OLD_PRIVATE + "/storage/storage_tree/tree.odin", "package storage_tree\n\nimport \"" + OLD_SUPPORT_IMPORT + "system\"\n")
	rename_test_write(root, "src/modules/system/storage/main.odin", "package storage\n\nimport \"" + OLD_PRIVATE_IMPORT + "storage/storage_tree\"\n")
	rename_test_write(root, "docs/GUIDE.md", "Read `" + OLD_SUPPORT + "/system/system.odin` and `" + OLD_PRIVATE_IMPORT + "storage/storage_tree`.\n")
	rename_test_write(root, NEWS_FOLDER + "/2026-11-20-a.md", "It was `" + OLD_SUPPORT + "/system`.\n")
	rename_test_write(root, FRAGMENT_FOLDER + "/20261120-130000-a.md", "type: Added\n\n**A**: `" + OLD_SUPPORT + "/system`.\n")
	rename_test_write(root, FRAGMENT_FOLDER + "/README.md", "Never edit `" + OLD_CONTRACT + "/release/release.odin`.\n")
	rename_test_write(root, "src/md/infrastructure/repository_layout.md", "From `" + OLD_SUPPORT_IMPORT + "` to `modus:`.\n")
	// An empty folder moves with its old folder.
	_ = os.make_directory_all(strings.concatenate({root, "/", OLD_SUPPORT, "/empty/inner"}, context.temp_allocator))

	report, ok := library_rename_run(root, host)
	testing.expect(t, ok)
	testing.expect_value(t, len(report.moves), 3)
	testing.expect_value(t, len(report.files_left), 0)
	for old in ([]string{OLD_SUPPORT, OLD_CONTRACT, OLD_PRIVATE}) {
		testing.expectf(t, !os.exists(strings.concatenate({root, "/", old}, context.temp_allocator)), "%s is still there", old)
	}
	testing.expect_value(t, rename_test_read(root, NEW_MODUS + "/system/system.odin"), "package system\n\n// See " + NEW_MODUS + "/contract/ring.\nimport ring \"modus:contract/ring\"\nimport \"modus:graphics\"\nNAME :: \"" + OLD_SUPPORT_IMPORT + "system\"\n")
	testing.expect_value(t, rename_test_read(root, NEW_MODUS + "/cryptography/origin.manifest"), NEW_MODUS + "/cryptography/sha2/sha2.odin core/crypto/sha2/sha2.odin 00\n")
	testing.expect_value(t, rename_test_read(root, NEW_MODUS + "/contract/ring/ring.odin"), "package ring\n")
	testing.expect_value(t, rename_test_read(root, NEW_INTERNAL + "/storage/storage_tree/tree.odin"), "package storage_tree\n\nimport \"modus:system\"\n")
	testing.expect_value(t, rename_test_read(root, "src/modules/system/storage/main.odin"), "package storage\n\nimport \"internal:storage/storage_tree\"\n")
	testing.expect_value(t, rename_test_read(root, "docs/GUIDE.md"), "Read `" + NEW_MODUS + "/system/system.odin` and `internal:storage/storage_tree`.\n")
	testing.expect_value(t, rename_test_read(root, FRAGMENT_FOLDER + "/README.md"), "Never edit `" + NEW_MODUS + "/contract/release/release.odin`.\n")
	// The records and the design keep their old forms.
	testing.expect_value(t, rename_test_read(root, NEWS_FOLDER + "/2026-11-20-a.md"), "It was `" + OLD_SUPPORT + "/system`.\n")
	testing.expect_value(t, rename_test_read(root, FRAGMENT_FOLDER + "/20261120-130000-a.md"), "type: Added\n\n**A**: `" + OLD_SUPPORT + "/system`.\n")
	testing.expect_value(t, rename_test_read(root, "src/md/infrastructure/repository_layout.md"), "From `" + OLD_SUPPORT_IMPORT + "` to `modus:`.\n")
	// The string of the source is left, and named.
	testing.expect_value(t, len(report.leftovers), 1)
	testing.expect(t, len(report.leftovers) == 1 && strings.has_prefix(report.leftovers[0], NEW_MODUS + "/system/system.odin:6: NAME"))

	// A second run changes no byte.
	snapshot := rename_test_snapshot(root, host)
	second, second_ok := library_rename_run(root, host)
	testing.expect(t, second_ok)
	testing.expect_value(t, len(second.moves), 0)
	testing.expect_value(t, len(second.changes), 0)
	testing.expect_value(t, len(second.leftovers), 1)
	testing.expect_value(t, rename_test_snapshot(root, host), snapshot)

	// A branch that merged master adds files at the old places.
	rename_test_write(root, OLD_SUPPORT + "/sound/sound.odin", "package sound\n\nimport \"" + OLD_SUPPORT_IMPORT + "system\"\n")
	rename_test_write(root, OLD_SUPPORT + "/system/added.odin", "package system\n// In " + OLD_SUPPORT + "/system.\n")
	rename_test_write(root, OLD_PRIVATE + "/console/line/line.odin", "package line\n")
	branch, branch_ok := library_rename_run(root, host)
	testing.expect(t, branch_ok)
	testing.expect_value(t, len(branch.moves), 3)
	testing.expect_value(t, rename_test_read(root, NEW_MODUS + "/sound/sound.odin"), "package sound\n\nimport \"modus:system\"\n")
	testing.expect_value(t, rename_test_read(root, NEW_MODUS + "/system/added.odin"), "package system\n// In " + NEW_MODUS + "/system.\n")
	testing.expect_value(t, rename_test_read(root, NEW_INTERNAL + "/console/line/line.odin"), "package line\n")
	testing.expect(t, !os.exists(strings.concatenate({root, "/", OLD_SUPPORT}, context.temp_allocator)))

	// A file at an old place whose new place is taken: refused, and no byte
	// changes, the free file of the same run included.
	rename_test_write(root, OLD_SUPPORT + "/system/system.odin", "package system\n")
	rename_test_write(root, OLD_SUPPORT + "/free/free.odin", "package free\n// " + OLD_SUPPORT + "\n")
	refused_snapshot := rename_test_snapshot(root, host)
	_, refused_ok := library_rename_run(root, host)
	testing.expect(t, !refused_ok)
	testing.expect_value(t, rename_test_snapshot(root, host), refused_snapshot)
	_ = os.remove_all(strings.concatenate({root, "/", OLD_SUPPORT}, context.temp_allocator))

	// A new place that exists on the disk with no tracked file: refused.
	rename_test_write(root, OLD_PRIVATE + "/editor/text/text.odin", "package text\n")
	_ = os.make_directory_all(strings.concatenate({root, "/", NEW_INTERNAL, "/editor"}, context.temp_allocator))
	untracked_snapshot := rename_test_snapshot(root, host)
	_, untracked_ok := library_rename_run(root, host)
	testing.expect(t, !untracked_ok)
	testing.expect_value(t, rename_test_snapshot(root, host), untracked_snapshot)
}
