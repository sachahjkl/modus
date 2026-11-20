package output

import "modus:contract/module"

// The rules of the generic record inputs and outputs
// (src/md/features/module_outputs.md, "The decisions of the generic record
// inputs"). The root service reads
// the facts from its tables, and these pure procedures decide, with host
// tests.

// What the type check of a wiring compares on the side of its reader.
Generic_Reader_Step :: enum u8 {
	Compare_Declared = 0, // A record input of a record: the record of the writer against its own.
	Fix              = 1, // A generic record input of the count One or Many with no fixed type: this wiring fixes it, and passes.
	Compare_Fixed    = 2, // A generic record input of the count One or Many whose type is fixed: the record of the writer against that type.
	Take_Each        = 3, // A generic record input of the count Many_Types: each wiring keeps its own type, and passes.
}

// generic_reader_step_of gives the type check of the reader side of one
// wiring: record is the record of the record input in its module file, 0
// for a generic one, wirings its count, and fixed whether a wiring fixed
// its type already, in the process or earlier in the same list.
//
// Example: the second source of merge.sources, a generic record input of
// the count Many that the first source fixed, gives Compare_Fixed.
generic_reader_step_of :: proc "contextless" (record: u32, wirings: module.Wiring_Count, fixed: bool) -> Generic_Reader_Step {
	if record != 0 {
		return .Compare_Declared
	}
	if wirings == .Many_Types {
		return .Take_Each
	}
	return fixed ? .Compare_Fixed : .Fix
}

// generic_reader_keeps says if a wiring of a reader step keeps the type of
// its generic record input once it reached its reader: the row that fixed
// it and each row that compared with it. A list is whole or refused, but
// a row can still end at its delivery (a give that fails); each delivered
// row of the type keeps it, so a reader that reads records of a type
// always has that type kept, whichever row was delivered.
generic_reader_keeps :: proc "contextless" (step: Generic_Reader_Step) -> bool {
	return step == .Fix || step == .Compare_Fixed
}

// generic_type_room_of says if a process that keeps kept types can keep one
// more, beside the other_listed types that other rows of the same list fix
// for its other generic record inputs, under the bound most.
//
// Example: with the bound 4, a process that keeps 3 has room for one; one
// that keeps 3 while another row of the list fixes a fourth has none.
generic_type_room_of :: proc "contextless" (kept: int, other_listed: int, most: int) -> bool {
	if kept < 0 || other_listed < 0 || kept >= most {
		return false
	}
	// No sum: a count past the bound must not wrap into room.
	return other_listed < most - kept
}

// What the type check of a wiring takes on the side of its writer.
Generic_Writer_Step :: enum u8 {
	Declared    = 0, // A record output of a record: its own.
	Fixed_Type  = 1, // A generic record output, Unpaired, whose generic record input has a fixed type: that type.
	Not_Fixed   = 2, // A generic record output whose generic record input has no fixed type, or the count Many_Types: refused with Not_Fixed.
	Paired_Later = 3, // A generic record output Paired: refused with Unsupported until the collector, its one user.
}

// generic_writer_step_of gives the record of the writer side of one
// wiring: record is the record of the record output, 0 for a generic one,
// pairing its mark, input_wirings the count of the one generic record
// input of its module, and fixed whether that record input has a fixed
// type.
generic_writer_step_of :: proc "contextless" (record: u32, pairing: module.Record_Output_Pairing, input_wirings: module.Wiring_Count, fixed: bool) -> Generic_Writer_Step {
	if record != 0 {
		return .Declared
	}
	switch pairing {
	case .Paired:
		return .Paired_Later
	case .Unpaired:
	}
	if input_wirings == .Many_Types || !fixed {
		return .Not_Fixed
	}
	return .Fixed_Type
}

// The words of one wait of a reader (system.input_read and its forms):
// the event word, the wiring ring and its flag, the word that ends a read
// of the console, and the completion queue of the words Closed and its
// flag; then, for each ring, its counter write, the flag of that counter,
// and its end word.
READER_WAIT_WORDS_BESIDE_RINGS :: 6
READER_WAIT_WORDS_OF_A_RING :: 3

// reader_wait_words gives the words of one wait of a reader of rings
// rings: the library checks at compile time that the ends of a process fit
// op.WORD_WAIT_CAPACITY, as a list that overflows ends its wait at once.
reader_wait_words :: proc "contextless" (rings: int) -> int {
	return READER_WAIT_WORDS_BESIDE_RINGS + READER_WAIT_WORDS_OF_A_RING * rings
}

// ring_turn_next gives the place where the next read of a reader of
// several rings starts: the place after the ring that gave the last
// compartment, in a table of count places. A fast ring then cannot keep a
// slow one out. A count of 0 gives 0, and a place past the table starts
// again at 0.
ring_turn_next :: proc "contextless" (given: int, count: int) -> int {
	if count <= 0 || given < 0 || given >= count - 1 {
		return 0
	}
	return given + 1
}
