package fuzz

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/operation_sequence"

// The engine of the kernel operations guided by the counted kernel
// (src/md/infrastructure/kernel_fuzzing.md, "The engine guided by the
// counters"), in its parts that run with no machine: the boot line that
// names the counters, the map of the features that the kept inputs gave,
// the stable part of two runs, the mutations of a choice sequence, and the
// reach inputs of the corpus. The loop that reaches a machine is in
// tools/modustool/machine/operation_fuzzing.odin.

// The most edges of a counted kernel: 256 KiB of counters in the kernel and
// 256 KiB of the bits of the map in the tool. A kernel past it is an error
// of the build: the bound changes in the design first.
KERNEL_EDGES_MOST :: 1 << 18

// The boot line of the counted kernel: the physical address of its
// counters, then their count, in decimal
// (src/modulus/edge_counters.odin, TEST_BUILD_LINE_EDGE_COUNTERS).
KERNEL_EDGE_COUNTERS_LINE_START :: "kernel: TEST BUILD: edge counters at "
KERNEL_EDGE_COUNTERS_LINE_MIDDLE :: ", "
KERNEL_EDGE_COUNTERS_LINE_END :: " edges"

// The mutations of one new input, at most: 1, 2, 4 or 8.
OPERATION_MUTATIONS_MOST :: 8

// The bytes that one mutation inserts, at most.
OPERATION_INSERTED_BYTES_MOST :: 16

// decimal_read reads a number of decimal digits only, as the log of the
// kernel writes one: no sign, no prefix, no leading zero but the number 0,
// no empty text, and no value past the largest u64.
@(private = "file")
decimal_read :: proc(text: string) -> (value: u64, ok: bool) {
	if len(text) == 0 || (len(text) > 1 && text[0] == '0') {
		return 0, false
	}
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return 0, false
		}
		digit := u64(character - '0')
		if value > (max(u64) - digit) / 10 {
			return 0, false
		}
		value = value * 10 + digit
	}
	return value, true
}

// kernel_edge_counters_line_read finds the boot line of the counted kernel
// in a text of whole lines, and reads its two numbers. The numbers come
// from the memory of the machine, so each one is checked: the count is 1
// to KERNEL_EDGES_MOST, and the range of the counters is inside the memory
// of the machine, memory_bytes. found is false when no line starts with
// the text; problem is not "" for a line that is found and refused.
kernel_edge_counters_line_read :: proc(text: string, memory_bytes: u64) -> (address: u64, count: int, found: bool, problem: string) {
	rest := text
	for whole_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(whole_line, "\r")
		if !strings.has_prefix(line, KERNEL_EDGE_COUNTERS_LINE_START) {
			continue
		}
		numbers := line[len(KERNEL_EDGE_COUNTERS_LINE_START):]
		if !strings.has_suffix(numbers, KERNEL_EDGE_COUNTERS_LINE_END) {
			return 0, 0, true, fmt.tprintf("the line \"%s\" does not end with \"%s\"", line, KERNEL_EDGE_COUNTERS_LINE_END)
		}
		numbers = numbers[:len(numbers) - len(KERNEL_EDGE_COUNTERS_LINE_END)]
		middle := strings.index(numbers, KERNEL_EDGE_COUNTERS_LINE_MIDDLE)
		if middle < 0 {
			return 0, 0, true, fmt.tprintf("the line \"%s\" has no count after its address", line)
		}
		read_address, address_read := decimal_read(numbers[:middle])
		read_count, count_read := decimal_read(numbers[middle + len(KERNEL_EDGE_COUNTERS_LINE_MIDDLE):])
		if !address_read || !count_read {
			return 0, 0, true, fmt.tprintf("the line \"%s\" does not hold two numbers in decimal", line)
		}
		if read_count < 1 || read_count > KERNEL_EDGES_MOST {
			return 0, 0, true, fmt.tprintf("the counted kernel says %d edges, and the tool takes 1 to %d", read_count, KERNEL_EDGES_MOST)
		}
		if read_count > memory_bytes || read_address > memory_bytes - read_count {
			return 0, 0, true, fmt.tprintf("the %d counters at %d are not inside the %d bytes of the memory of the machine", read_count, read_address, memory_bytes)
		}
		return read_address, int(read_count), true, ""
	}
	return 0, 0, false, ""
}

// The features that the kept inputs gave: one bit for each edge and class
// of its count (fuzz_count_class).
Kernel_Edge_Map :: struct {
	edge_count:    int, // The count of the boot line.
	seen:          []u8,
	feature_count: int,
}

// kernel_edge_map_make gives an empty map for a count of edges: false for a
// count of 0 or less, or past KERNEL_EDGES_MOST.
kernel_edge_map_make :: proc(edge_count: int, allocator := context.allocator) -> (edges: Kernel_Edge_Map, ok: bool) {
	if edge_count < 1 || edge_count > KERNEL_EDGES_MOST {
		return {}, false
	}
	edges.edge_count = edge_count
	edges.seen = make([]u8, (edge_count * FUZZ_COUNT_CLASSES + 7) / 8, allocator)
	return edges, true
}

kernel_edge_map_destroy :: proc(edges: ^Kernel_Edge_Map, allocator := context.allocator) {
	delete(edges.seen, allocator)
	edges^ = {}
}

// kernel_edge_feature_of gives the feature of an edge and its counter;
// false for a counter of 0, which gives none.
@(private = "file")
kernel_edge_feature_of :: proc(edge: int, counter: u8) -> (feature: int, ok: bool) {
	class := fuzz_count_class(counter)
	if class == 0 {
		return 0, false
	}
	return edge * FUZZ_COUNT_CLASSES + class - 1, true
}

@(private = "file")
kernel_edge_feature_seen :: proc(edges: ^Kernel_Edge_Map, feature: int) -> bool {
	return edges.seen[feature / 8] & (1 << u8(feature % 8)) != 0
}

// kernel_edge_features_new counts the features of the counters that the
// map does not hold. ok is false, and the count 0, for counters of another
// count than the map: they come from another kernel.
kernel_edge_features_new :: proc(edges: ^Kernel_Edge_Map, counters: []u8) -> (count: int, ok: bool) {
	if len(counters) != edges.edge_count {
		return 0, false
	}
	for counter, edge in counters {
		if feature, has_feature := kernel_edge_feature_of(edge, counter); has_feature && !kernel_edge_feature_seen(edges, feature) {
			count += 1
		}
	}
	return count, true
}

// kernel_edge_features_mark adds the features of the counters to the map,
// and counts those that it did not hold. Counters of another count change
// nothing.
kernel_edge_features_mark :: proc(edges: ^Kernel_Edge_Map, counters: []u8) -> (marked: int, ok: bool) {
	if len(counters) != edges.edge_count {
		return 0, false
	}
	for counter, edge in counters {
		feature, has_feature := kernel_edge_feature_of(edge, counter)
		if !has_feature || kernel_edge_feature_seen(edges, feature) {
			continue
		}
		edges.seen[feature / 8] |= 1 << u8(feature % 8)
		edges.feature_count += 1
		marked += 1
	}
	return marked, true
}

// kernel_edge_features_of lists the features of counters, one for each
// edge that ran, in the order of the edges.
kernel_edge_features_of :: proc(counters: []u8, allocator := context.allocator) -> []u32 {
	list := make([dynamic]u32, allocator)
	for counter, edge in counters {
		if feature, has_feature := kernel_edge_feature_of(edge, counter); has_feature {
			append(&list, u32(feature))
		}
	}
	return list[:]
}

// kernel_edge_counters_stable writes into `into` the part of two runs of
// one sequence that agree: the counter of the second run where both give
// its edge the same class, else 0. false, with nothing written, for three
// slices of different lengths.
kernel_edge_counters_stable :: proc(first, second, into: []u8) -> bool {
	if len(first) != len(second) || len(into) != len(first) {
		return false
	}
	for edge in 0 ..< len(first) {
		into[edge] = fuzz_count_class(first[edge]) == fuzz_count_class(second[edge]) ? second[edge] : 0
	}
	return true
}

// operation_sequence_of_choices builds the sequence of choice bytes with
// the generator of the fuzz target operation_sequence_generated, then
// changes each protected process name, as the loop with no counters does.
// read is the count of the bytes that the generator read: the bytes up to
// it give the same sequence, because past the end it reads zeros.
operation_sequence_of_choices :: proc(choice_bytes: []u8, sequence: ^operation_sequence.Sequence) -> (read: int) {
	choices := fuzz_choices_of(choice_bytes)
	fuzz_operation_sequence_generate(&choices, sequence)
	_ = operation_protected_names_changed(sequence)
	return min(choices.place, len(choice_bytes))
}

// operation_choices_mutate changes a choice sequence one time: a bit, a
// byte, a word at a boundary value, a range copied from another kept
// input, random bytes inserted, or the end cut. The bytes never pass
// OPERATION_CHOICE_BYTES.
operation_choices_mutate :: proc(random: ^Fuzz_Random, choices: ^[dynamic]u8, other: []u8) {
	if len(choices^) == 0 {
		inserted := 1 + fuzz_random_below(random, OPERATION_INSERTED_BYTES_MOST)
		for _ in 0 ..< inserted {
			append(choices, u8(fuzz_random_next(random)))
		}
		return
	}
	place := fuzz_random_below(random, len(choices^))
	switch fuzz_random_below(random, 6) {
	case 0:
		choices^[place] ~= 1 << u8(fuzz_random_below(random, 8))
	case 1:
		choices^[place] = u8(fuzz_random_next(random))
	case 2:
		size := 1 << uint(fuzz_random_below(random, 4))
		if place + size <= len(choices^) {
			fuzz_word_write(choices^[:], place, size, fuzz_boundary_value(random, size), fuzz_random_one_in(random, 2))
		}
	case 3:
		if len(other) > 0 {
			from := fuzz_random_below(random, len(other))
			count := 1 + fuzz_random_below(random, len(other) - from)
			for index in 0 ..< count {
				at := place + index
				if at >= OPERATION_CHOICE_BYTES {
					break
				}
				if at < len(choices^) {
					choices^[at] = other[from + index]
				} else {
					append(choices, other[from + index])
				}
			}
		}
	case 4:
		inserted := min(1 + fuzz_random_below(random, OPERATION_INSERTED_BYTES_MOST), OPERATION_CHOICE_BYTES - len(choices^))
		for _ in 0 ..< inserted {
			inject_at(choices, place, u8(fuzz_random_next(random)))
		}
	case 5:
		resize(choices, place)
	}
}

// One kept input of the guided engine: its choice bytes and the features
// of its stable part.
Operation_Reach_Entry :: struct {
	choices:  []u8,
	features: []u32,
}

@(private = "file")
Reach_Order :: struct {
	index: int,
	size:  int,
}

// operation_reach_cover gives the places of the smallest set of the
// entries that gives each feature of them all, smallest first, the earlier
// one at the same size: for each feature the smallest entry that gives it,
// then, from the largest to the smallest, each of those whose features the
// others give leaves the set.
operation_reach_cover :: proc(entries: []Operation_Reach_Entry, allocator := context.allocator) -> []int {
	smallest := make(map[u32]int, allocator = context.temp_allocator)
	for entry, index in entries {
		for feature in entry.features {
			if held, found := smallest[feature]; !found || len(entry.choices) < len(entries[held].choices) {
				smallest[feature] = index
			}
		}
	}
	in_set := make([]bool, len(entries), context.temp_allocator)
	for _, index in smallest {
		in_set[index] = true
	}
	givers := make(map[u32]int, allocator = context.temp_allocator)
	order := make([dynamic]Reach_Order, context.temp_allocator)
	for entry, index in entries {
		if !in_set[index] {
			continue
		}
		append(&order, Reach_Order{index = index, size = len(entry.choices)})
		for feature in entry.features {
			givers[feature] = givers[feature] + 1
		}
	}
	slice.sort_by(order[:], proc(a, b: Reach_Order) -> bool {
		return a.size > b.size || (a.size == b.size && a.index > b.index)
	})
	for item in order {
		redundant := true
		for feature in entries[item.index].features {
			if givers[feature] <= 1 {
				redundant = false
				break
			}
		}
		if !redundant {
			continue
		}
		in_set[item.index] = false
		for feature in entries[item.index].features {
			givers[feature] = givers[feature] - 1
		}
	}
	kept := make([dynamic]int, allocator)
	#reverse for item in order {
		if in_set[item.index] {
			append(&kept, item.index)
		}
	}
	return kept[:]
}

// operation_reach_inputs_write writes the reach inputs of the corpus of the
// kernel operations into corpus_folder/reach, in their order, in the room
// that the regression inputs leave in the bounds of the corpus of a target.
// An input past that room, or longer than OPERATION_CHOICE_BYTES, is left
// out. After the writes, each file of the folder that is not a written
// input is removed: a write that fails leaves the old set. ok is false when
// a file cannot be written or removed.
operation_reach_inputs_write :: proc(corpus_folder: string, inputs: [][]u8) -> (written: int, left_out: int, ok: bool) {
	room_inputs := FUZZ_CORPUS_TARGET_INPUT_LIMIT
	room_bytes := FUZZ_CORPUS_TARGET_BYTE_LIMIT
	for regression in fuzz_inputs_read(strings.concatenate({corpus_folder, "/", FUZZ_REGRESSION_PART}, context.temp_allocator), context.temp_allocator) {
		room_inputs -= 1
		room_bytes -= len(regression.bytes)
	}
	reach_folder := strings.concatenate({corpus_folder, "/", FUZZ_REACH_PART}, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for input in inputs {
		name := fuzz_input_name(input)
		if slice.contains(names[:], name) {
			continue
		}
		if len(input) > OPERATION_CHOICE_BYTES || room_inputs < 1 || len(input) > room_bytes {
			left_out += 1
			continue
		}
		if _, stored := fuzz_input_write(reach_folder, input); !stored {
			return written, left_out, false
		}
		append(&names, name)
		room_inputs -= 1
		room_bytes -= len(input)
		written += 1
	}
	for old in fuzz_inputs_read(reach_folder, context.temp_allocator) {
		if slice.contains(names[:], old.name) {
			continue
		}
		path := strings.concatenate({reach_folder, "/", old.name}, context.temp_allocator)
		if error := os.remove(path); error != nil {
			fmt.eprintfln("modustool: cannot remove %s: %v", path, error)
			return written, left_out, false
		}
	}
	return written, left_out, true
}
