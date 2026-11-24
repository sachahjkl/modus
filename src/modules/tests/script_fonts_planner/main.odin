// The planner of the machine tests of a script font set that the plan of
// principal 0 names (src/md/features/script_fonts.md, "The chosen form").
// It hashes the font outlines of the boot image that its starter
// mapped, which have the form of a script font set, and applies through
// `plans.apply` a plan of one entry Script_Fonts that names that hash;
// the tool answers the dialog of the trusted display with the keys of a
// principal, and the root service takes the set at the next start of the
// machine.
//
// Two rows of the module table build this source. script_fonts_planner
// names the font outlines whole: the tool writes the same bytes on the data
// disk, and the next start maps them. script_fonts_cut_planner, built with
// SCRIPT_FONTS_PLANNER_NAMES_A_CUT_SET, names the font outlines less their
// last CUT_BYTES: the tool writes those bytes, so the hash is right, and
// the next start refuses their form, as their header gives another size.
// The choice is a setting of the build, not a value of the start, because
// the two machines that need each plan start from the same state: a data
// disk with no plan and no set mapped.
//
// **Start**: `start("script_fonts_planner")` in the console of principal 0.
// **What a reader sees**: no window; "script_fonts_planner: names the
// script font set ...", then "script_fonts_planner: the principal accepted
// the plan: generation 1, ..." or a line "script_fonts_planner: WRONG:
// ...". It stops itself with Done, or Failed after a WRONG line.
package script_fonts_planner

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/powerbox"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "modus:system"

NAMES_A_CUT_SET :: #config(SCRIPT_FONTS_PLANNER_NAMES_A_CUT_SET, false)
// The bytes that the cut set lacks: one word, so the cut set keeps the
// alignment of the whole one.
CUT_BYTES :: 8
// The name of the plan, which the dialog shows: the tool tells the dialogs
// apart by it.
PLAN_NAME :: "the cut font outlines" when NAMES_A_CUT_SET else "the font outlines"
// The time between two polls of the decision of the principal.
POLL_MILLISECONDS :: 20

Plans_Connection :: struct {
	connection:        system.Call_Connection,
	file:              []u8,
	apply_export:      u32,
	poll_export:       u32,
	generation_export: u32,
}

plans: Plans_Connection
// The records of the font outlines: the reader gives the room.
outlines_room: font_outlines.Record_Room

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

@(private = "file")
wrong_call :: proc "contextless" (text: string, status: call_outcome.Call_Outcome, error: errors.Error_Record) -> ! {
	system.log_fact(.Error, Wrong_Call{status = u64(status), error_kind = u64(error.kind), error_unit = u64(error.unit), error_argument = error.argument, error_value = error.value, error_found = error.found}, text)
	system.stop(.Failed)
}

@(private = "file")
bytes_of :: proc "contextless" (value: ^$T) -> []u8 {
	return ([^]u8)(value)[:size_of(T)]
}

// decision_wait reads the decision on ticket until the principal took one,
// and writes the line of the arm time once.
@(private = "file")
decision_wait :: proc "contextless" (ticket: i64, asked_at: u64, generation_row: ^pr.Plan_Generation_Row, error: ^errors.Error_Record) -> (generation: i64, status: call_outcome.Call_Outcome) {
	armed := false
	deadline := asked_at + powerbox.CONSENT_ARM_MILLISECONDS + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		rows: [1]pr.Plan_Generation_Row
		arguments := [1]isolated.Argument{{integer = u64(ticket)}}
		error^ = {}
		generation, status = system.call_isolated(&plans.connection, plans.file, plans.poll_export, arguments[:], error, false, bytes_of(&rows))
		if status != .Succeeded || generation != 0 {
			generation_row^ = rows[0]
			return generation, status
		}
		now := system.time()
		if !armed && now >= asked_at + powerbox.CONSENT_ARM_MILLISECONDS {
			armed = true
			system.log_fact(.Info, Dialog_Armed{ticket = u64(ticket)}, PLAN_NAME)
		}
		if now >= deadline {
			wrong("no decision of the principal came within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		wait := system.wait_begin()
		system.wait_end(&wait, now + POLL_MILLISECONDS)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	outlines, problem := font_outlines.open(&ctx.values, outlines_room[:])
	if problem.kind != .None {
		wrong("the font outlines of the boot image do not open; the problem", u64(problem.kind))
	}
	set := outlines.bytes
	when NAMES_A_CUT_SET {
		set = set[:len(set) - CUT_BYTES]
	}
	hash := blake3.hash(set)
	system.log_fact(.Info, Set_Named{hash = value_kinds.Hash_Field(hash), set_size = value_kinds.Size_In_Bytes(len(set))}, PLAN_NAME)

	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Ok {
		wrong("the boot image does not map; the status word", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	plans.file = system.image_find(image, "plans")
	plans.apply_export = module.export_find(plans.file, "apply")
	plans.poll_export = module.export_find(plans.file, "apply_poll")
	plans.generation_export = module.export_find(plans.file, "current_generation")
	if plans.apply_export == 0 || plans.poll_export == 0 || plans.generation_export == 0 {
		wrong("the module plans lacks apply, apply_poll or current_generation; the size of its file", u64(len(plans.file)))
	}
	requests, ring_status := system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if ring_status != .Ok {
		wrong("no root ring; the status word", u64(ring_status))
	}
	connected: call_outcome.Call_Outcome
	plans.connection, connected = system.service_connection(&requests, 1, role_contract.role_properties(.Plans).name)
	if connected != .Succeeded {
		wrong("the root service gave no connection to the holder of Plans; the call outcome", u64(connected))
	}
	// Each machine of the test starts on a new data disk: no plan is
	// current, so the plan expects none.
	error: errors.Error_Record
	current, current_status := system.call_isolated(&plans.connection, plans.file, plans.generation_export, nil, &error)
	if current_status != .Succeeded || current != 0 {
		wrong("a plan of principal 0 is current at the start; its generation", u64(current))
	}

	row: pr.Plan_Entry_Row
	row.kind_word = i64(pr.Plan_Entry_Kind.Script_Fonts)
	row.module_hash = value_kinds.Hash_Field(hash)
	copy(row.name[:], pr.SCRIPT_FONTS_ENTRY_NAME)
	expected: pr.Plan_Expected
	name := PLAN_NAME
	arguments := [3]isolated.Argument{{text = transmute([]u8)name}, {table = {records = bytes_of(&row), count = 1}}, {record = bytes_of(&expected)}}
	ticket, status := system.call_isolated(&plans.connection, plans.file, plans.apply_export, arguments[:], &error)
	if status != .Succeeded || ticket <= 0 {
		wrong_call("plans.apply refused the plan before its dialog", status, error)
	}
	system.log_fact(.Info, Difference_Shown{ticket = u64(ticket)}, PLAN_NAME)
	generation_row: pr.Plan_Generation_Row
	generation, poll_status := decision_wait(ticket, system.time(), &generation_row, &error)
	if poll_status != .Succeeded || generation <= 0 {
		wrong_call("plans.apply_poll did not commit the accepted plan", poll_status, error)
	}
	if generation_row.generation != generation || generation_row.standing_word != i64(pr.Generation_Standing.Current) {
		wrong("the row of the applied generation does not name it as the current one; its generation", u64(generation_row.generation))
	}
	system.log_fact(.Info, Plan_Accepted{generation = u64(generation), hash = value_kinds.Hash_Field(hash)})
	system.call_connection_end(&plans.connection)
	system.stop(.Done)
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}
