package fuzz

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/operation_sequence"

// The memory of a machine in the tests of the boot line: a small one, so
// the edges of the range are easy to write.
@(private = "file")
TEST_MEMORY_BYTES :: u64(1 << 20)

@(private = "file")
counters_line :: proc(address: string, count: string) -> string {
	return strings.concatenate({KERNEL_EDGE_COUNTERS_LINE_START, address, KERNEL_EDGE_COUNTERS_LINE_MIDDLE, count, KERNEL_EDGE_COUNTERS_LINE_END, "\n"}, context.temp_allocator)
}

// The boot line of the counted kernel comes from the memory of the
// machine: each number is checked at its edges, a range past the memory is
// refused, and a line in another form is refused with nothing read.
@(test)
the_boot_line_of_the_counters_is_read_through_its_border :: proc(t: ^testing.T) {
	refused := []string {
		counters_line("4096", "0"),
		counters_line("4096", fmt.tprintf("%d", KERNEL_EDGES_MOST + 1)),
		counters_line("4096", "18446744073709551615"),
		counters_line("4096", "18446744073709551616"),
		counters_line("4096", "-1"),
		counters_line("-4096", "1"),
		counters_line("", "1"),
		counters_line("4096", ""),
		counters_line("0x1000", "1"),
		counters_line("+4096", "1"),
		counters_line("4096", "+1"),
		counters_line("04096", "1"),
		counters_line("4096", "01"),
		counters_line("00", "1"),
		counters_line(fmt.tprintf("%d", TEST_MEMORY_BYTES), "1"),
		counters_line(fmt.tprintf("%d", TEST_MEMORY_BYTES - 1), "2"),
		counters_line("18446744073709551615", "1"),
		strings.concatenate({KERNEL_EDGE_COUNTERS_LINE_START, "4096 1 edges\n"}, context.temp_allocator),
		strings.concatenate({KERNEL_EDGE_COUNTERS_LINE_START, "4096, 1\n"}, context.temp_allocator),
	}
	for text in refused {
		address, count, found, problem := kernel_edge_counters_line_read(text, TEST_MEMORY_BYTES)
		testing.expectf(t, found && problem != "", "the line %q is refused", text)
		testing.expectf(t, address == 0 && count == 0, "the refused line %q gives no number", text)
	}
	// No line of the counters: not found, and no problem.
	for text in ([]string{"", "kernel: ok\n", strings.concatenate({"[log] ", counters_line("4096", "1")}, context.temp_allocator)}) {
		_, _, found, problem := kernel_edge_counters_line_read(text, TEST_MEMORY_BYTES)
		testing.expectf(t, !found && problem == "", "the text %q has no line of the counters", text)
	}
	// The edges that are taken: one counter at the last byte of the
	// memory, at its first byte, and the bound of the map, among other
	// lines and with the end of line of a terminal.
	taken := []struct {
		text:    string,
		address: u64,
		count:   int,
	} {
		{counters_line(fmt.tprintf("%d", TEST_MEMORY_BYTES - 1), "1"), TEST_MEMORY_BYTES - 1, 1},
		{counters_line("0", "1"), 0, 1},
		{strings.concatenate({"kernel: ok\n", KERNEL_EDGE_COUNTERS_LINE_START, "4096, ", fmt.tprintf("%d", KERNEL_EDGES_MOST), KERNEL_EDGE_COUNTERS_LINE_END, "\r\nkernel: free memory\n"}, context.temp_allocator), 4096, KERNEL_EDGES_MOST},
	}
	for item in taken {
		address, count, found, problem := kernel_edge_counters_line_read(item.text, TEST_MEMORY_BYTES)
		testing.expectf(t, found && problem == "", "the line %q: %s", item.text, problem)
		testing.expect_value(t, address, item.address)
		testing.expect_value(t, count, item.count)
	}
}

// The map of the features is made for 1 to KERNEL_EDGES_MOST edges, and
// counters of another count change nothing.
@(test)
the_map_of_the_features_has_its_bounds :: proc(t: ^testing.T) {
	for count in ([]int{-1, 0, KERNEL_EDGES_MOST + 1, max(int)}) {
		edges, made := kernel_edge_map_make(count)
		testing.expectf(t, !made && edges.seen == nil, "a map of %d edges is refused", count)
	}
	edges, made := kernel_edge_map_make(KERNEL_EDGES_MOST)
	testing.expect(t, made, "a map of the bound of the edges is made")
	defer kernel_edge_map_destroy(&edges)
	testing.expect_value(t, len(edges.seen), KERNEL_EDGES_MOST * FUZZ_COUNT_CLASSES / 8)
	// Counters of one less and one more than the map: refused, and the map
	// does not change.
	for count in ([]int{0, KERNEL_EDGES_MOST - 1, KERNEL_EDGES_MOST + 1}) {
		counters := make([]u8, count, context.temp_allocator)
		slice.fill(counters, 1)
		fresh, same_count := kernel_edge_features_new(&edges, counters)
		testing.expectf(t, !same_count && fresh == 0, "%d counters for a map of %d edges are taken", count, KERNEL_EDGES_MOST)
		marked, marked_same_count := kernel_edge_features_mark(&edges, counters)
		testing.expectf(t, !marked_same_count && marked == 0, "%d counters for a map of %d edges are marked", count, KERNEL_EDGES_MOST)
	}
	testing.expect_value(t, edges.feature_count, 0)
	testing.expect(t, slice.all_of(edges.seen, 0), "a refused mark changed the map")
	// The last edge of the bound: one feature, then none.
	counters := make([]u8, KERNEL_EDGES_MOST, context.temp_allocator)
	counters[KERNEL_EDGES_MOST - 1] = 1
	fresh, _ := kernel_edge_features_new(&edges, counters)
	testing.expect_value(t, fresh, 1)
	marked, _ := kernel_edge_features_mark(&edges, counters)
	testing.expect_value(t, marked, 1)
	again, _ := kernel_edge_features_new(&edges, counters)
	testing.expect_value(t, again, 0)
}

// An empty map takes no feature from counters of 0; one edge gives one
// feature for each class of its count; a counter that saturates at 255 is
// in the class of 128, so it gives no feature past it.
@(test)
the_map_takes_a_feature_for_each_class_of_a_count :: proc(t: ^testing.T) {
	edges, made := kernel_edge_map_make(1)
	testing.expect(t, made)
	defer kernel_edge_map_destroy(&edges)
	zero := []u8{0}
	fresh, same_count := kernel_edge_features_new(&edges, zero)
	testing.expect(t, same_count && fresh == 0, "a counter of 0 gives a feature")
	testing.expect_value(t, len(kernel_edge_features_of(zero, context.temp_allocator)), 0)
	// One count of each class, in the order of the classes: each one new.
	for count in ([]u8{1, 2, 3, 4, 8, 16, 32, 128}) {
		counter := []u8{count}
		new_count, _ := kernel_edge_features_new(&edges, counter)
		testing.expectf(t, new_count == 1, "the count %d gives %d features", count, new_count)
		_, _ = kernel_edge_features_mark(&edges, counter)
	}
	testing.expect_value(t, edges.feature_count, FUZZ_COUNT_CLASSES)
	// The other counts of each class, and the saturated counter: none new.
	for count in ([]u8{5, 7, 9, 15, 17, 31, 33, 127, 129, 254, 255}) {
		counter := []u8{count}
		new_count, _ := kernel_edge_features_new(&edges, counter)
		testing.expectf(t, new_count == 0, "the count %d gives a feature that its class gave", count)
	}
	saturated := kernel_edge_features_of([]u8{255}, context.temp_allocator)
	testing.expect(t, len(saturated) == 1 && saturated[0] == u32(FUZZ_COUNT_CLASSES - 1), "a saturated counter is the last class of its edge")
}

// The stable part of two runs keeps an edge only where both runs give its
// count the same class; slices of other lengths write nothing.
@(test)
the_stable_part_of_two_runs_keeps_the_classes_that_agree :: proc(t: ^testing.T) {
	first := []u8{0, 1, 2, 4, 7, 255, 128, 0, 3}
	second := []u8{0, 1, 3, 7, 4, 128, 127, 1, 3}
	into := make([]u8, len(first), context.temp_allocator)
	testing.expect(t, kernel_edge_counters_stable(first, second, into))
	testing.expect(t, slice.equal(into, []u8{0, 1, 0, 7, 4, 128, 0, 0, 3}), "the stable part")
	marker := make([]u8, len(first) - 1, context.temp_allocator)
	slice.fill(marker, 0xAA)
	testing.expect(t, !kernel_edge_counters_stable(first, second, marker), "a short slice of the stable part is taken")
	testing.expect(t, slice.all_of(marker, 0xAA), "a refusal wrote")
	testing.expect(t, !kernel_edge_counters_stable(first, second[:len(second) - 1], into[:len(second) - 1]), "a short second run is taken")
}

@(private = "file")
reach_entry :: proc(size: int, features: ..u32) -> Operation_Reach_Entry {
	choices := make([]u8, size, context.temp_allocator)
	for &byte_value, place in choices {
		byte_value = u8(place + 1)
	}
	return {choices = choices, features = slice.clone(features, context.temp_allocator)}
}

// The set of the reach inputs: no entry gives an empty set; for each
// feature the smallest entry that gives it, the earlier at one size; an
// entry whose features the others give leaves.
@(test)
the_reach_inputs_are_the_smallest_set_of_the_features :: proc(t: ^testing.T) {
	testing.expect_value(t, len(operation_reach_cover(nil, context.temp_allocator)), 0)
	no_feature := []Operation_Reach_Entry{reach_entry(4)}
	testing.expect_value(t, len(operation_reach_cover(no_feature, context.temp_allocator)), 0)
	one := []Operation_Reach_Entry{reach_entry(4, 7)}
	testing.expect(t, slice.equal(operation_reach_cover(one, context.temp_allocator), []int{0}), "one entry")
	entries := []Operation_Reach_Entry {
		reach_entry(10, 1, 2, 3), // 0: its features, each smaller elsewhere.
		reach_entry(3, 1), // 1
		reach_entry(3, 2), // 2: the earlier at its size of feature 2.
		reach_entry(3, 2), // 3: the same size, later: never chosen.
		reach_entry(5, 3, 4), // 4: the smallest with 4.
		reach_entry(2, 3), // 5: the smallest with 3, which leaves: 4 gives 3 and stays for 4.
		reach_entry(0, 9), // 6: no byte, one feature.
	}
	cover := operation_reach_cover(entries, context.temp_allocator)
	testing.expectf(t, slice.equal(cover, []int{6, 1, 2, 4}), "the set is %v", cover)
	// A large entry that alone gives a feature stays, and the small ones
	// whose features it gives leave.
	redundant := []Operation_Reach_Entry {
		reach_entry(2, 1), // 0
		reach_entry(2, 2), // 1
		reach_entry(9, 1, 2, 3), // 2: the only one with 3 stays.
		reach_entry(8, 4), // 3
		reach_entry(4, 4, 5), // 4: the smallest with 4 and 5; 3 is never chosen.
	}
	reduced := operation_reach_cover(redundant, context.temp_allocator)
	testing.expectf(t, slice.equal(reduced, []int{4, 2}), "the reduced set is %v", reduced)
}

// The writer of the reach inputs writes in the room that the regression
// inputs leave, smallest first, removes each old file that the new set
// does not hold, and never touches the regression inputs.
@(test)
the_reach_inputs_are_written_in_the_room_of_the_corpus :: proc(t: ^testing.T) {
	folder, error := os.make_directory_temp("", "operation_reach_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	defer os.remove_all(folder)
	regression_folder := strings.concatenate({folder, "/", FUZZ_REGRESSION_PART}, context.temp_allocator)
	reach_folder := strings.concatenate({folder, "/", FUZZ_REACH_PART}, context.temp_allocator)
	// The regression inputs take all the room but two inputs.
	for index in 0 ..< FUZZ_CORPUS_TARGET_INPUT_LIMIT - 2 {
		input := []u8{0xEE, u8(index), u8(index >> 8)}
		_, stored := fuzz_input_write(regression_folder, input)
		testing.expect(t, stored)
	}
	old := []u8{0x01, 0x02, 0x03}
	_, old_stored := fuzz_input_write(reach_folder, old)
	testing.expect(t, old_stored)
	first, second, third := []u8{}, []u8{0x10}, []u8{0x20, 0x21}
	too_long := make([]u8, OPERATION_CHOICE_BYTES + 1, context.temp_allocator)
	written, left_out, ok := operation_reach_inputs_write(folder, [][]u8{first, too_long, second, second, third})
	testing.expect(t, ok)
	testing.expect_value(t, written, 2)
	testing.expect_value(t, left_out, 2)
	reach := fuzz_inputs_read(reach_folder, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for input in reach {
		append(&names, input.name)
	}
	testing.expect_value(t, len(reach), 2)
	testing.expect(t, slice.contains(names[:], fuzz_input_name(first)) && slice.contains(names[:], fuzz_input_name(second)), "the two smallest inputs are written")
	testing.expect(t, !slice.contains(names[:], fuzz_input_name(old)), "an old reach input stays")
	testing.expect(t, !slice.contains(names[:], fuzz_input_name(third)), "an input past the room is written")
	testing.expect_value(t, len(fuzz_inputs_read(regression_folder, context.temp_allocator)), FUZZ_CORPUS_TARGET_INPUT_LIMIT - 2)
	// An empty set removes each reach input.
	emptied_written, emptied_left_out, emptied := operation_reach_inputs_write(folder, nil)
	testing.expect(t, emptied && emptied_written == 0 && emptied_left_out == 0)
	testing.expect_value(t, len(fuzz_inputs_read(reach_folder, context.temp_allocator)), 0)
}

// A choice sequence that the generator read gives the same sequence when it
// is cut after its last read byte, and a mutation never passes
// OPERATION_CHOICE_BYTES.
@(test)
a_reach_input_is_cut_after_its_last_read_choice :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	random := Fuzz_Random{state = 2026}
	whole := make([]u8, OPERATION_CHOICE_BYTES, context.temp_allocator)
	full := new(operation_sequence.Sequence)
	defer free(full)
	cut := new(operation_sequence.Sequence)
	defer free(cut)
	for _ in 0 ..< 64 {
		for &value in whole {
			value = u8(fuzz_random_next(&random))
		}
		read := operation_sequence_of_choices(whole, full)
		testing.expect(t, read >= 0 && read <= len(whole))
		read_again := operation_sequence_of_choices(whole[:read], cut)
		testing.expect_value(t, read_again, read)
		full_bytes, full_accepted := operation_sequence_encode(full, context.temp_allocator)
		cut_bytes, cut_accepted := operation_sequence_encode(cut, context.temp_allocator)
		testing.expect(t, full_accepted && cut_accepted, "check refuses a sequence of the choices")
		testing.expect(t, slice.equal(full_bytes, cut_bytes), "the cut choices give another sequence")
	}
	// No choice at all: the simplest sequence, which check accepts.
	testing.expect_value(t, operation_sequence_of_choices(nil, cut), 0)
	_, empty_accepted := operation_sequence_encode(cut, context.temp_allocator)
	testing.expect(t, empty_accepted)
	// Mutations from an empty input and from the largest one.
	choices := make([dynamic]u8, context.temp_allocator)
	other := make([]u8, OPERATION_CHOICE_BYTES, context.temp_allocator)
	for _ in 0 ..< 4096 {
		operation_choices_mutate(&random, &choices, other)
		testing.expect(t, len(choices) <= OPERATION_CHOICE_BYTES)
		if fuzz_random_one_in(&random, 64) {
			resize(&choices, fuzz_random_one_in(&random, 2) ? 0 : OPERATION_CHOICE_BYTES)
		}
	}
}
