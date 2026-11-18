package fuzz

import "core:fmt"
import "core:os"
import "core:testing"

// A small tree with the three folders of the seed: the tool with a package
// two folders deep, a package of the library, and the kernel with one
// kernel part.
@(private = "file")
seed_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "fuzz_sources_seed_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	for name in ([]string{"tool/package/nested", "library/contract/record", "kernel/part"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	seed_file_write(folder, "tool/main.odin", "package tool\n")
	seed_file_write(folder, "tool/package/nested/deep.odin", "package nested\n")
	seed_file_write(folder, "tool/package/nested/notes.txt", "not a source\n")
	seed_file_write(folder, "library/contract/record/record.odin", "package record\n")
	seed_file_write(folder, "kernel/kernel.odin", "package kernel\n")
	seed_file_write(folder, "kernel/part/part.odin", "package part\n")
	return folder
}

@(private = "file")
seed_file_write :: proc(root, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)
}

@(private = "file")
seed_of_tree :: proc(root: string) -> u64 {
	return fuzz_sources_seed_of_folders(fmt.tprintf("%s/tool", root), fmt.tprintf("%s/library", root), fmt.tprintf("%s/kernel", root))
}

// The seed covers each source of the tool to any depth: a package of the
// tool is a folder under it. A file of the kernel itself and a file that
// is not a source are no input.
@(test)
fuzz_sources_seed_reads_the_tool_to_any_depth :: proc(t: ^testing.T) {
	root := seed_tree_make(t)
	defer os.remove_all(root)
	first := seed_of_tree(root)
	testing.expect_value(t, seed_of_tree(root), first)

	paths := make([dynamic]string, context.temp_allocator)
	fuzz_sources_list(fmt.tprintf("%s/tool", root), &paths)
	testing.expect_value(t, len(paths), 2)

	seed_file_write(root, "tool/package/nested/notes.txt", "another text\n")
	testing.expect_value(t, seed_of_tree(root), first)
	seed_file_write(root, "kernel/kernel.odin", "package kernel\n\nchanged :: 1\n")
	testing.expect_value(t, seed_of_tree(root), first)

	seed_file_write(root, "tool/package/nested/deep.odin", "package nested\n\nchanged :: 1\n")
	after_deep := seed_of_tree(root)
	testing.expect(t, after_deep != first, "a source of a package of the tool two folders deep changes the seed")

	seed_file_write(root, "tool/package/nested/new.odin", "package nested\n")
	after_new := seed_of_tree(root)
	testing.expect(t, after_new != after_deep, "a new source in a package of the tool changes the seed")

	seed_file_write(root, "kernel/part/part.odin", "package part\n\nchanged :: 1\n")
	testing.expect(t, seed_of_tree(root) != after_new, "a source of a kernel part changes the seed")
}
