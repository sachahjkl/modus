package isolated

// The ready completion of a call ring (src/md/api/call_ring_ready.md): the
// first completion that the serving side sends, once it maps the ring with
// the consent to receive handles. A caller sends its first call only after
// it; until then the kernel has no receiver for a lent handle.

import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/ring"

// The tag of the first completion of a call ring. No call has it: a caller
// numbers its calls from 1.
READY_TAG :: 0

// What the first completion of a call ring says.
Ready_Reading :: enum u8 {
	Ready       = 0, // The serving side maps the ring with consent: the caller can call and lend.
	Load_Failed = 1, // A call host did not load its module: the call region starts with its load error.
	Refused     = 2, // Not a first completion: the caller ends the connection.
}

// ready_record gives the ready completion that the serving side sends: the
// outcome Succeeded.
ready_record :: proc "contextless" () -> ring.Record {
	return {kind = u32(call_outcome.Call_Outcome.Succeeded), tag = READY_TAG}
}

// The kind of the record of a failed load, for each stage: what broke the
// rule of the load. The stage None is no failure: its record is one that
// the border refuses.
@(rodata)
LOAD_STAGE_KINDS := [module.Load_Stage]errors.Kind {
	.None  = .Refused,
	.Find  = .Absent,
	.Read  = .Malformed,
	.Cycle = .Malformed,
	.Check = .Refused,
	.Bind  = .Absent,
	.Map   = .Refused,
	.Room  = .Too_Long,
	.Unmap = .Refused,
}

// load_failed_record gives the first completion of a call host that did not
// load its module: Nothing_Has_That_Name when the load source holds no
// module or import that the load names (the stage Find), else
// Argument_Refused, since the file or its imports break a rule. The record
// has the kind of its stage, the unit Modules and the stage as the value
// found; the module.Load_Error in the call region holds the detail.
load_failed_record :: proc "contextless" (stage: module.Load_Stage) -> ring.Record {
	outcome := stage == .Find ? call_outcome.Call_Outcome.Nothing_Has_That_Name : .Argument_Refused
	record := errors.error_make(LOAD_STAGE_KINDS[stage], .Modules, 0, 0, 0, i64(stage))
	return {kind = u32(outcome), tag = READY_TAG, values = errors.completion_values(record)}
}

// ready_of_first_completion is the border of the first completion of a
// call ring, which the other process writes. It refuses a tag other than
// READY_TAG (no call was sent, so no answer of a call comes first), an
// outcome other than those of ready_record and load_failed_record, a ready
// completion with values that are not zero, and a failed load whose record
// is not the record of a stage.
ready_of_first_completion :: proc "contextless" (record: ring.Record) -> Ready_Reading {
	if record.tag != READY_TAG {
		return .Refused
	}
	if record == ready_record() {
		return .Ready
	}
	// A failed load: its record names a stage, and is the record of that
	// stage, word for word.
	found := errors.completion_record(record.values).found
	if found < 0 || found > i64(max(u32)) {
		return .Refused
	}
	stage, known := module.load_stage_of_word(u32(found))
	if !known || stage == .None || record != load_failed_record(stage) {
		return .Refused
	}
	return .Load_Failed
}
