// Applies a plan of principal 0 that sets Role.Display to panel_display so the
// next boot starts panel_display in place of compositor
// (src/md/features/roles_and_contracts.md).
package display_role_planner

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "modus:system"

HOLDER_MODULE :: "panel_display"
PLAN_NAME :: "panel display"
POLL_MILLISECONDS :: 100

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

@(private = "file")
wrong_call :: proc "contextless" (text: string, outcome: call_outcome.Call_Outcome, error: errors.Error_Record) -> ! {
	system.log_fact(.Error, Wrong_Call{outcome = call_outcome.Call_Outcome_Word(outcome), error_kind = u64(error.kind), error_unit = u64(error.unit), error_argument = error.argument, error_value = error.value, error_found = error.found}, text)
	system.stop(.Failed)
}

@(private = "file")
bytes_of :: proc "contextless" (value: ^$T) -> []u8 {
	return ([^]u8)(value)[:size_of(T)]
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Succeeded {
		wrong("the boot image does not map; status", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	holder_file := system.image_find(image, HOLDER_MODULE)
	if len(holder_file) == 0 {
		wrong("the boot image lacks panel_display; size", 0)
	}
	plans_file := system.image_find(image, "plans")
	apply_export := module.export_find(plans_file, "apply")
	poll_export := module.export_find(plans_file, "apply_poll")
	if apply_export == 0 || poll_export == 0 {
		wrong("the module plans lacks apply or apply_poll; size", u64(len(plans_file)))
	}
	requests, ring_status := system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if ring_status != .Succeeded {
		wrong("no root ring; status", u64(ring_status))
	}
	connection, connected := system.service_connection(&requests, 1, role_contract.role_properties(.Plans).name)
	if connected != .Succeeded {
		wrong("the root service gave no connection to the holder of Plans; outcome", u64(connected))
	}
	defer system.call_connection_end(&connection)

	row: pr.Plan_Entry_Row
	row.kind_word = i64(pr.Plan_Entry_Kind.Role_Holder)
	row.role_word = i64(role_contract.Role.Display)
	row.module_hash = value_kinds.Hash_Field(blake3.hash(holder_file))
	copy(row.name[:], HOLDER_MODULE)

	expected: pr.Plan_Expected
	error: errors.Error_Record
	name := PLAN_NAME
	rows := [1]pr.Plan_Entry_Row{0 = row}
	arguments := [3]isolated.Argument {
		{text = transmute([]u8)name},
		{table = {records = ([^]u8)(raw_data(rows[:]))[:size_of(pr.Plan_Entry_Row)], count = 1}},
		{record = bytes_of(&expected)},
	}
	ticket, applied := system.call_isolated(&connection, plans_file, apply_export, arguments[:], &error)
	if applied != .Succeeded || ticket <= 0 {
		wrong_call("plans.apply refused the display role plan", applied, error)
	}
	system.log_fact(.Info, Difference_Shown{ticket = u64(ticket)}, PLAN_NAME)

	asked_at := system.time()
	armed := false
	deadline := asked_at + powerbox.CONSENT_ARM_MILLISECONDS + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		gen_rows: [1]pr.Plan_Generation_Row
		poll_args := [1]isolated.Argument{{integer = u64(ticket)}}
		error = {}
		generation, polled := system.call_isolated(&connection, plans_file, poll_export, poll_args[:], &error, false, bytes_of(&gen_rows))
		if polled != .Succeeded {
			wrong_call("plans.apply_poll refused the accepted display role plan", polled, error)
		}
		if generation != 0 {
			if gen_rows[0].generation != generation || gen_rows[0].standing != .Current {
				wrong("the applied generation row is not current; generation", u64(gen_rows[0].generation))
			}
			system.log_fact(.Info, Plan_Accepted{generation = u64(generation)})
			system.stop(.Done)
		}
		now := system.time()
		if !armed && now >= asked_at + powerbox.CONSENT_ARM_MILLISECONDS {
			armed = true
			system.log_fact(.Info, Dialog_Armed{ticket = u64(ticket)}, PLAN_NAME)
		}
		if now >= deadline {
			wrong("no decision of the principal came within the hang bound, in milliseconds", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		wait := system.wait_begin()
		system.wait_end(&wait, now + POLL_MILLISECONDS)
	}
}
