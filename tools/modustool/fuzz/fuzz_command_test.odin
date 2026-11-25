package fuzz

import "core:fmt"
import "core:os"
import "core:strings"
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
	seed_file_write(root, "tool/package/nested/deep_test.odin", "package nested\n")
	seed_file_write(root, "tool/package/nested/deep_test_amd64.odin", "package nested\n")
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

// The count of the children of the check at once: at least one, at most
// one for each processor, one for each target and the limit. The edges
// first: no processor, a negative count, no target.
@(test)
fuzz_check_children_at_once_is_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, fuzz_check_children_at_once(40, 0), 1)
	testing.expect_value(t, fuzz_check_children_at_once(40, -3), 1)
	testing.expect_value(t, fuzz_check_children_at_once(0, 16), 1)
	testing.expect_value(t, fuzz_check_children_at_once(1, 16), 1)
	testing.expect_value(t, fuzz_check_children_at_once(3, 16), 3)
	testing.expect_value(t, fuzz_check_children_at_once(40, 1), 1)
	testing.expect_value(t, fuzz_check_children_at_once(40, FUZZ_CHECK_CHILDREN_LIMIT - 1), FUZZ_CHECK_CHILDREN_LIMIT - 1)
	testing.expect_value(t, fuzz_check_children_at_once(40, FUZZ_CHECK_CHILDREN_LIMIT), FUZZ_CHECK_CHILDREN_LIMIT)
	testing.expect_value(t, fuzz_check_children_at_once(40, FUZZ_CHECK_CHILDREN_LIMIT + 1), FUZZ_CHECK_CHILDREN_LIMIT)
	testing.expect_value(t, fuzz_check_children_at_once(40, max(int)), FUZZ_CHECK_CHILDREN_LIMIT)
}

// A child of the check that writes the state Done into its mailbox, as the
// real child does at its end, unless the name of its target says that it
// fails: then it exits with no record. It prints one line to its standard
// output.
@(private = "file")
check_child_script_make :: proc(t: ^testing.T, folder: string) -> string {
	path := fmt.tprintf("%s/child.sh", folder)
	done := u32(Fuzz_Child_State.Done)
	text := fmt.tprintf(
		"#!/bin/sh\necho \"the child of $3\"\ncase \"$3\" in *fails*) exit 1;; esac\nprintf '\\%03o\\%03o\\%03o\\%03o' | dd of=\"$4\" bs=1 seek=%d conv=notrunc 2>/dev/null\n",
		done & 0xff,
		(done >> 8) & 0xff,
		(done >> 16) & 0xff,
		(done >> 24) & 0xff,
		offset_of(Fuzz_Mailbox, state),
	)
	testing.expect_value(t, os.write_entire_file(path, text), nil)
	testing.expect_value(t, os.change_mode(path, os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}), nil)
	return path
}

// The children of the check run at once, and a failure of one child ends
// no other one: each target gets its own verdict and its own output, in
// the order of the targets, for each count at once from one to more than
// the targets. A child that cannot start keeps started false. The
// failures come first in the list, so a pool that stopped after one would
// leave the later targets with no outcome.
@(test)
fuzz_check_children_run_gives_each_target_its_own_verdict :: proc(t: ^testing.T) {
	folder, folder_error := os.make_directory_temp("", "fuzz_check_children_test_*", context.temp_allocator)
	testing.expect_value(t, folder_error, nil)
	defer os.remove_all(folder)
	script := check_child_script_make(t, folder)
	names := [?]string{"check_children_test_fails_a", "check_children_test_b", "check_children_test_fails_c", "check_children_test_d", "check_children_test_e"}
	targets: [len(names)]Fuzz_Target
	for name, place in names {
		targets[place] = {name = name}
	}
	defer for name in names {
		_ = os.remove_all(fuzz_target_folder(name))
	}
	for at_once in ([]int{1, 2, len(names), len(names) + 3}) {
		runs: [len(names)]Fuzz_Check_Child
		for &target, place in targets {
			runs[place] = {target = &target, executions = 1, output_path = fmt.tprintf("%s/output_%d_%d.txt", folder, at_once, place)}
		}
		fuzz_check_children_run(script, runs[:], 7, at_once)
		for run in runs {
			name := run.target.name
			testing.expectf(t, run.started, "%d at once: the child of %s started", at_once, name)
			testing.expectf(t, run.child.ended, "%d at once: the child of %s ended", at_once, name)
			fails := strings.contains(name, "fails")
			if fails {
				testing.expectf(t, run.outcome.state != .Done && run.outcome.oracle == .Fault, "%d at once: %s ended with no record, a failure, not %v %v", at_once, name, run.outcome.state, run.outcome.oracle)
				testing.expectf(t, run.outcome.signature == "fault: the child ended with no record", "%d at once: %s: the signature %s", at_once, name, run.outcome.signature)
			} else {
				testing.expectf(t, run.outcome.state == .Done && run.outcome.oracle == .None, "%d at once: %s passed, not %v %v", at_once, name, run.outcome.state, run.outcome.oracle)
			}
			output, read_error := os.read_entire_file(run.output_path, context.temp_allocator)
			testing.expectf(t, read_error == nil, "%d at once: the output of %s: %v", at_once, name, read_error)
			testing.expect_value(t, string(output), fmt.tprintf("the child of %s\n", name))
		}
	}
	// A binary that does not exist starts no child, and the others are not
	// started in its place.
	runs: [2]Fuzz_Check_Child
	for &run, place in runs {
		run = {target = &targets[place + 1], executions = 1}
	}
	fuzz_check_children_run(fmt.tprintf("%s/no_such_binary", folder), runs[:], 7, 2)
	for run in runs {
		testing.expectf(t, !run.started, "the child of %s did not start", run.target.name)
	}
}

// fuzz_shard_targets refuses out-of-range shard bounds and partitions targets
// in strided order (index % total == shard - 1) with no overlap and no gap.
@(test)
fuzz_shard_targets_partitions_deterministically :: proc(t: ^testing.T) {
	all := fuzz_targets()
	testing.expect(t, len(all) >= 4, "fuzz target table holds at least four targets")

	// Refusal cases first: 0, negative, and shard > total.
	for bad in ([][2]int{{0, 4}, {1, 0}, {0, 0}, {-1, 4}, {1, -4}, {5, 4}, {2, 1}}) {
		selected, ok := fuzz_shard_targets(all, bad[0], bad[1])
		testing.expectf(t, !ok && len(selected) == 0, "shard %d/%d must be refused", bad[0], bad[1])
	}

	// Single shard returns every target in order.
	whole, whole_ok := fuzz_shard_targets(all, 1, 1)
	testing.expect(t, whole_ok)
	testing.expect_value(t, len(whole), len(all))
	for target, index in whole {
		testing.expect_value(t, target.name, all[index].name)
	}

	// Four shards cover every target exactly once in strided order.
	seen := make(map[string]int, context.temp_allocator)
	sum := 0
	for shard in 1 ..= 4 {
		slice, ok := fuzz_shard_targets(all, shard, 4)
		testing.expectf(t, ok, "shard %d/4 succeeds", shard)
		sum += len(slice)
		expected_pos := shard - 1
		for target in slice {
			testing.expect_value(t, target.name, all[expected_pos].name)
			seen[target.name] += 1
			expected_pos += 4
		}
	}
	testing.expect_value(t, sum, len(all))
	for target in all {
		testing.expect_value(t, seen[target.name], 1)
	}

	// Valid shard past len(all) returns an empty slice cleanly.
	beyond, beyond_ok := fuzz_shard_targets(all, len(all) + 1, len(all) + 1)
	testing.expect(t, beyond_ok)
	testing.expect_value(t, len(beyond), 0)

	// Strict positive-decimal parsing for fuzz_runner CLI matches check fuzz.
	for bad_text in ([][2]string{{"0", "4"}, {"1", "0"}, {"5", "4"}, {"+1", "4"}, {"1_0", "10"}, {"-1", "4"}, {" 1", "4"}, {"a", "4"}, {"1", "b"}, {"", "4"}}) {
		_, _, parsed_ok := fuzz_parse_shard_args(bad_text[0], bad_text[1])
		testing.expectf(t, !parsed_ok, "shard args %q %q must be refused", bad_text[0], bad_text[1])
	}
	shard, total, good_ok := fuzz_parse_shard_args("2", "4")
	testing.expect(t, good_ok && shard == 2 && total == 4)
}
