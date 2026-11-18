// The generation of an operation sequence and of its records, on the host:
// the bytes that the fuzzing of the kernel operations writes into the
// mailbox of a machine (src/md/infrastructure/kernel_fuzzing.md). No machine
// runs here.
package fuzz

import "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modustool:foundation"

// The choices that the generator reads for one sequence: more than the
// largest sequence reads, so the bytes never run out in a normal draw.
OPERATION_CHOICE_BYTES :: 4096

// The byte that replaces the first byte of a protected process name in a
// generated sequence.
OPERATION_PROTECTED_NAME_CHANGE :: '_'

// The module of the root service.
OPERATION_ROOT_MODULE :: "root"

// The processes that a sequence must never reach. The generator never names
// a child with one of these names, so the line of a fault of a child is
// never the line of a fault of isolation.
@(rodata)
operation_protected_names := [?]string{foundation.OPERATION_FUZZING_MODULE, OPERATION_ROOT_MODULE}

// operation_sequence_encode writes a sequence, then reads the bytes back
// with check: the bytes are what a machine gets, and a sequence that check
// refuses gives none.
operation_sequence_encode :: proc(sequence: ^operation_sequence.Sequence, allocator := context.allocator) -> (bytes: []u8, accepted: bool) {
	size, sized := operation_sequence.size(sequence)
	if !sized {
		return nil, false
	}
	bytes = make([]u8, size, allocator)
	read_back := new(operation_sequence.Sequence)
	defer free(read_back)
	if _, written := operation_sequence.write(bytes, sequence); !written || operation_sequence.check(bytes, read_back).problem != .None {
		delete(bytes, allocator)
		return nil, false
	}
	return bytes, true
}

// operation_parameter_place gives the place of a parameter of an operation
// by its name in OPERATIONS, or -1.
operation_parameter_place :: proc(chosen: operation.Operation, name: string) -> int {
	for parameter, place in operation.OPERATIONS[chosen].parameters {
		if parameter.name == name {
			return place
		}
	}
	return -1
}

// operation_protected_names_changed changes the first byte of each name of
// a Process_Create that is the name of a protected process, in the content
// of the area that the step names: a child with that name would make the
// line of its fault the line of a fault of isolation. The rule reads only
// the sequence, so a seed still gives one sequence. A name that is not in
// the content of its area, or whose length is not a plain value, stays.
operation_protected_names_changed :: proc(sequence: ^operation_sequence.Sequence) -> (changed: int) {
	name_place := operation_parameter_place(.Process_Create, "name")
	length_place := operation_parameter_place(.Process_Create, "name_length")
	if name_place < 0 || length_place < 0 {
		return 0
	}
	for &item in sequence.steps[:sequence.step_count] {
		if item.operation != u32(operation.Operation.Process_Create) {
			continue
		}
		name, length := item.arguments[name_place], item.arguments[length_place]
		if name.source != .Area_Address || length.source != .Value || name.area < 0 || name.area >= sequence.area_count {
			continue
		}
		content := operation_sequence.area_content(sequence, name.area)
		if name.offset > u64(len(content)) || length.value == 0 || length.value > u64(len(content)) - name.offset {
			continue
		}
		bytes := content[name.offset:][:length.value]
		for protected in operation_protected_names {
			if string(bytes) == protected {
				bytes[0] = OPERATION_PROTECTED_NAME_CHANGE
				changed += 1
				break
			}
		}
	}
	return changed
}

// operation_sequence_generate_random_written is the same, and `written`
// receives each record that the generator wrote, for a host test.
operation_sequence_generate_random_written :: proc(random: ^Fuzz_Random, sequence: ^operation_sequence.Sequence, written: ^[dynamic]Fuzz_Record_Written) {
	choice_bytes: [OPERATION_CHOICE_BYTES]u8
	for place := 0; place < len(choice_bytes); place += 8 {
		word := fuzz_random_next(random)
		for index in 0 ..< 8 {
			choice_bytes[place + index] = u8(word >> (8 * u64(index)))
		}
	}
	choices := fuzz_choices_of(choice_bytes[:])
	fuzz_operation_sequence_generate(&choices, sequence, written)
	_ = operation_protected_names_changed(sequence)
}
