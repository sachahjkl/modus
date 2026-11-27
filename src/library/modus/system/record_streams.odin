package system

import "base:intrinsics"
import module "modus:contract/module"
import "modus:contract/output"

// The declarations of the record outputs and the record inputs of a module
// (docs/MODULE_CONTRACT.md, "The record outputs and the record inputs").
//
// A module declares each record output and each record input as a package
// variable of its package, with a documented comment:
//
// ```odin
// // One request that the server answered.
// requests: system.Record_Output(Access_Record)
//
// // The orders to serve.
// orders: system.Record_Input(Order)
// ```
//
// The tool reads these declarations, as it reads the signature of an
// export, and writes the tables Record_Outputs and Record_Inputs of the
// module file. It refuses a declaration that is not a package variable of
// the package of the module, two declarations with one name, a record with
// a byte that no field names or with a Handle field, a generic record output
// in a module with no generic record input or with two, Paired on a record
// output that is not generic, and Many_Types on a record input that is not
// generic (docs/TOOLS.md, "The record outputs and the record inputs of the
// build"). A declaration costs nothing while no wiring names it.

// The record type of a generic declaration: a record output or a record
// input that declares no record type, whose type its wiring fixes.
//
// ```odin
// // The streams to join.
// sources: system.Record_Input(system.Any_Record, .Many)
// ```
Any_Record :: struct {}

// The state of a record output in its variable. Each loader writes the
// index of its row at the place of the variable, its first field
// (module.record_stream_indexes_write): the library finds the ends of the
// variable in the wiring ring by that index. 0: the module file names no
// place, and no end reaches the variable.
//
// One thread writes one record output: the counts below are plain words
// of that thread, with no lock and no atomic, and each queue keeps its one
// writer. A process that writes one record output from several threads
// holds its own lock around each write (src/md/features/module_outputs.md,
// "Subtle points").
// The serial and the counts of the records of one set of rings: the whole
// record output, or the rings of the readers of one principal of a record
// output By_Principal, so no reader learns a count of another principal
// (src/md/features/log_reader_scope.md, "The scope of a principal").
Serial_Counts :: struct {
	next_serial: u32, // The serial of the next record of the record output, in each ring.
	written:     u64, // The records that one ring or more took.
	discarded:   u64, // The records that no ring took: the record output had no reader, the condition of each ring left the record out, or each ring of the pace Never_Holds_Writer was full and counted it in its gap.
	refused:     u64, // The writes refused with Full: no ring took them, and they have no serial.
	held:        u64, // The writes that waited for room in a full ring that holds the writer, once each.
	rings_past_gap: u64, // The rings that the writer closed as their gap reached its largest count (output.gap_after_refused_record).
}

// The principals whose rings a record output By_Principal counts apart:
// plan value, the capacity of principals of the machine
// (principals.PRINCIPAL_CAPACITY), which the log service asserts. A
// principal past it has no rings that take a record.
SCOPED_PRINCIPALS_MOST :: 8

Output_State :: struct {
	index:       u32, // The loader writes it.
	using counts: Serial_Counts, // The whole record output; a record output By_Principal counts in scoped.
	scoped:      [SCOPED_PRINCIPALS_MOST]Serial_Counts, // A record output By_Principal: the counts of the rings of each principal.
	refused_by_readers: u64, // The compartments that a reader refused (output.Completion_Kind.Bad_Record): the writer closes each such ring.
	ended:       bool, // output_end ended the record output.
	last_end:    output.End_Word, // The end word of the last ring that ended by an end word.
	rings_ended: u64, // The rings that ended by an end word: a reader that stopped, its asker, a revocation.
	rings_broken: u64, // The rings that the writer closed for a count of the reader past its own write: no honest reader writes one.
	record_size: u32, // A generic record output: the size of its record, from output_size_set; 0 until then. A record output of a record: 0, as its type gives its size.
}
#assert(offset_of(Output_State, index) == 0)

// The state of a record input in its variable: the index first, as for a
// record output.
Input_State :: struct {
	index: u32, // The loader writes it.
	turn:  u32, // The place of the table of the ends where the next read starts: the ends of the counts Many and Many_Types are read in turn.
	read:  u64, // The records that the readers took.
}
#assert(offset_of(Input_State, index) == 0)

// A record output: a stream of records of the record type Record_Type that
// the module writes, with no known end. With Any_Record, it takes the type
// of the one generic record input of its module; with pairing Paired, one
// ring for each wiring of that record input, of the type of that wiring.
Record_Output :: struct($Record_Type: typeid, $pairing: module.Record_Output_Pairing = module.Record_Output_Pairing.Unpaired) where intrinsics.type_is_struct(Record_Type) {
	using state: Output_State,
}

// A record input with no wiring terms: a stream of records of the record
// type Record_Type that the module reads. wirings says how many wirings it
// takes: One, Many of one type, or Many_Types for a generic record input.
Record_Input :: struct($Record_Type: typeid, $wirings: module.Wiring_Count = module.Wiring_Count.One) where intrinsics.type_is_struct(Record_Type) {
	using state: Input_State,
}

// A record input whose asker gives wiring terms of the record type
// Terms_Type with each wiring, which the reader receives with its end. The
// terms come second: they are what sets this record input apart.
//
// ```odin
// // The records to keep, each source with the terms of its space.
// sources: system.Record_Input_With_Terms(system.Any_Record, Space_Terms, .Many_Types)
//
// // The records that pass a condition.
// source: system.Record_Input_With_Terms(system.Any_Record, Condition)
// ```
Record_Input_With_Terms :: struct($Record_Type: typeid, $Terms_Type: typeid, $wirings: module.Wiring_Count = module.Wiring_Count.One) where intrinsics.type_is_struct(Record_Type) && intrinsics.type_is_struct(Terms_Type) {
	using state: Input_State,
}
