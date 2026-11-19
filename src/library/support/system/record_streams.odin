package system

import "base:intrinsics"
import module "modus:contract/module"

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

// A record output: a stream of records of the record type Record_Type that
// the module writes, with no known end. With Any_Record, it takes the type
// of the one generic record input of its module; with pairing Paired, one
// ring for each wiring of that record input, of the type of that wiring.
Record_Output :: struct($Record_Type: typeid, $pairing: module.Record_Output_Pairing = module.Record_Output_Pairing.Unpaired) where intrinsics.type_is_struct(Record_Type) {}

// A record input with no wiring terms: a stream of records of the record
// type Record_Type that the module reads. wirings says how many wirings it
// takes: One, Many of one type, or Many_Types for a generic record input.
Record_Input :: struct($Record_Type: typeid, $wirings: module.Wiring_Count = module.Wiring_Count.One) where intrinsics.type_is_struct(Record_Type) {}

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
Record_Input_With_Terms :: struct($Record_Type: typeid, $Terms_Type: typeid, $wirings: module.Wiring_Count = module.Wiring_Count.One) where intrinsics.type_is_struct(Record_Type) && intrinsics.type_is_struct(Terms_Type) {}
