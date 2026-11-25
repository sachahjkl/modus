// One-step human console frontend for plans.apply and plans.rollback
// (src/md/features/declarations.md, "The apply as built").
//
// The plans service keeps its low-level two-step RPCs (apply / apply_poll and
// rollback / rollback_to / rollback_poll) so programmatic clients never block.
// In the interactive console, lines run on the background run_lines thread
// (never the UI thread), so plans.apply and plans.rollback open the trusted
// display consent dialog, poll on the worker thread with Escape cancellation
// until the principal decides, and return the committed Plan_Generation_Row
// table directly.
package console

import "base:intrinsics"
import "internal:console/plan_reader"
import module "modus:contract/module"
import pr "modus:contract/plans_recipes"
import "modus:sentence"
import "modus:system"

// Plan value: poll interval while the trusted display consent dialog is open.
// Escape wakes the wait immediately via work.cancel.
PLANS_POLL_INTERVAL_MILLISECONDS :: 25

// Plan value: generous wait bound (5 minutes) for a principal reading a plan
// difference on the trusted display before ending a hung wait.
PLANS_DECISION_BOUND_MILLISECONDS :: 5 * 60 * 1000

// plans_commands_attach_types sets parameter names on the built-in plans.apply
// and plans.rollback commands and binds the Plan_Expected record description
// from the boot-image plans module so record literals like `{}` type-check.
plans_commands_attach_types :: proc "contextless" () {
	if item := command_find("plans.apply"); item != nil {
		item.parameter_names[0] = "plan_name"
		item.parameter_names[1] = "rows"
		item.parameter_names[2] = "expected"
		if plans_file, _, has_plans := image_module_file("plans"); has_plans {
			if apply_export := module.export_find(plans_file, "apply"); apply_export != 0 {
				if fn, ok := module.function(plans_file, apply_export); ok && fn.parameter_count >= 3 {
					item.file = plans_file
					item.function.parameter_details[2] = fn.parameter_details[2]
				}
			}
		}
	}
	if item := command_find("plans.rollback"); item != nil {
		item.parameter_names[0] = "generation"
	}
}

// plans_ensure_connected connects to the plans service when not already
// connected and returns its sandbox number (1-based) and module file.
@(private = "file")
plans_ensure_connected :: proc "contextless" () -> (sandbox_number: int, plans_file: []u8, ok: bool) {
	for &item, index in sandboxes {
		if item.service && item.name == "plans" && item.process != 0 {
			sandbox_number = index + 1
			break
		}
	}
	if sandbox_number == 0 {
		connect_args := [1]Value{{kind = .Text, text = "plans"}}
		_ = connect_service(connect_args[:])
		if failed {
			return 0, nil, false
		}
		for &item, index in sandboxes {
			if item.service && item.name == "plans" && item.process != 0 {
				sandbox_number = index + 1
				break
			}
		}
	}
	if sandbox_number == 0 {
		_ = fail("plans: the plans service is not connected")
		return 0, nil, false
	}
	file, _, has_file := image_module_file("plans")
	if !has_file {
		_ = fail("plans: the boot image has no module plans")
		return 0, nil, false
	}
	return sandbox_number, file, true
}

// plans_export_command builds a temporary Command descriptor for invoking one
// low-level export of the connected plans service through call_isolated.
@(private = "file")
plans_export_command :: proc "contextless" (sandbox_number: int, plans_file: []u8, export_name: string, display_name: string) -> (cmd: Command, ok: bool) {
	export_index := module.export_find(plans_file, export_name)
	if export_index == 0 || !export_command_make(&cmd, plans_file, export_index) {
		_ = fail(display_name, ": the plans service does not export ", export_name)
		return {}, false
	}
	cmd.name = display_name
	cmd.sandbox = sandbox_number
	return cmd, true
}

// plans_validate_name checks the plan display name before contacting plans.
plans_validate_name :: proc "contextless" (plan_name: string) -> bool {
	if len(plan_name) == 0 {
		_ = fail("plans.apply: the plan name is empty; it must have 1 to ", i64(pr.PLAN_DISPLAY_NAME_BYTES), " bytes")
		return false
	}
	if len(plan_name) > pr.PLAN_DISPLAY_NAME_BYTES {
		_ = fail("plans.apply: the plan name has ", i64(len(plan_name)), " bytes; it can have at most ", i64(pr.PLAN_DISPLAY_NAME_BYTES), " bytes")
		return false
	}
	return true
}

// plans_rows_from_argument converts either a `plan { ... }` value or a Table of
// Plan_Entry_Row into validated row bytes before opening any consent dialog.
@(private = "file")
plans_rows_from_argument :: proc "contextless" (argument: Value) -> (rows_bytes: []u8, ok: bool) {
	if argument.kind == .Plan_Value {
		rows := ([^]pr.Plan_Entry_Row)(raw_data(plan_rows_bytes[:]))[:PLAN_ROWS_OF_A_CALL]
		count, refusal := plan_reader.read(&line_evaluation, argument, console_image_of_plans(), rows)
		if refusal.problem != .None {
			writer := sentence.Writer{buffer = scratch[scratch_count:]}
			plan_reader.refusal_write(&writer, refusal)
			text := sentence.written(&writer)
			scratch_count += len(text)
			_ = fail("plans.apply: ", text)
			return nil, false
		}
		bytes := scratch_bytes(count * size_of(pr.Plan_Entry_Row))
		if bytes == nil && count != 0 {
			_ = fail("the line has too many records")
			return nil, false
		}
		copy(bytes, plan_rows_bytes[:count * size_of(pr.Plan_Entry_Row)])
		return bytes, true
	}
	if argument.kind == .Table {
		if !plan_reader.rows_layout_matches(argument.file, argument.detail) {
			_ = fail("plans.apply: argument 2 is no table of the rows of a plan")
			return nil, false
		}
		return argument.record, true
	}
	_ = fail("plans.apply: argument 2 must be a plan or a Table of Plan_Entry_Row, not ", type_text(argument.file, argument.kind, argument.detail))
	return nil, false
}

// plans_poll_until_decided polls apply_poll or rollback_poll on the console's
// background worker thread until the principal accepts or refuses on the
// trusted display, Escape cancels, or PLANS_DECISION_BOUND_MILLISECONDS elapses.
//
// apply_poll and rollback_poll return the committed generation number (1, 2, ...)
// while writing the single committed Plan_Generation_Row into result[0]. We
// trim the returned table value to that single row so generations past 1 never
// show trailing zero rows.
@(private = "file")
plans_poll_until_decided :: proc "contextless" (command_name: string, sandbox_number: int, plans_file: []u8, poll_export: string, ticket: i64) -> Value {
	poll_cmd, poll_ok := plans_export_command(sandbox_number, plans_file, poll_export, command_name)
	if !poll_ok {
		return {}
	}
	call_stoppable_enter()
	defer call_stoppable_leave()
	deadline := system.time() + PLANS_DECISION_BOUND_MILLISECONDS
	for {
		if intrinsics.atomic_load_explicit(&work.cancel, .Relaxed) != 0 {
			return fail(command_name, ": stopped before a decision was made on the trusted display")
		}
		saved_table_used := table_used
		saved_scratch_count := scratch_count
		poll_args := [1]Value{{kind = .Integer, integer = ticket}}
		result := call_isolated(&poll_cmd, poll_args[:])
		if failed {
			return {}
		}
		if len(result.record) >= size_of(pr.Plan_Generation_Row) {
			// Keep only the single committed generation row written at result[0].
			result.record = result.record[:size_of(pr.Plan_Generation_Row)]
			table_used = saved_table_used + size_of(pr.Plan_Generation_Row)
			return result
		}
		// Still waiting on the trusted display: reclaim temporary scratch/table space.
		table_used = saved_table_used
		scratch_count = saved_scratch_count
		now := system.time()
		if now >= deadline {
			return fail(command_name, ": no decision arrived from the trusted display before the wait limit")
		}
		wait := system.wait_begin()
		system.wait_word(&wait, &work.cancel, 0)
		system.wait_end(&wait, min(now + PLANS_POLL_INTERVAL_MILLISECONDS, deadline))
	}
}

// plans_apply_command validates the plan up front, connects plans when needed,
// opens the trusted display consent dialog via plans.apply, waits on the
// console worker thread until the principal decides, and returns the committed
// Plan_Generation_Row table.
plans_apply_command :: proc "contextless" (arguments: []Value) -> Value {
	plan_name := arguments[0].text
	if !plans_validate_name(plan_name) {
		return {}
	}
	rows_bytes, rows_ok := plans_rows_from_argument(arguments[1])
	if !rows_ok {
		return {}
	}
	expected_bytes: [size_of(pr.Plan_Expected)]u8
	if len(arguments) == 3 {
		if arguments[2].kind != .Record || len(arguments[2].record) != size_of(pr.Plan_Expected) {
			return fail("plans.apply: argument 3 must be a Plan_Expected record")
		}
		copy(expected_bytes[:], arguments[2].record)
	}
	sandbox_number, plans_file, connected := plans_ensure_connected()
	if !connected {
		return {}
	}
	apply_cmd, apply_ok := plans_export_command(sandbox_number, plans_file, "apply", "plans.apply")
	if !apply_ok {
		return {}
	}
	apply_args := [3]Value{
		{kind = .Text, text = plan_name},
		{kind = .Table, record = rows_bytes, file = plans_file, detail = apply_cmd.function.parameter_details[1]},
		{kind = .Record, record = expected_bytes[:], file = plans_file, detail = apply_cmd.function.parameter_details[2]},
	}
	ticket_val := call_isolated(&apply_cmd, apply_args[:])
	if failed {
		return {}
	}
	if ticket_val.kind != .Integer || ticket_val.integer <= 0 {
		return fail("plans.apply: the plans service did not return a consent ticket")
	}
	return plans_poll_until_decided("plans.apply", sandbox_number, plans_file, "apply_poll", ticket_val.integer)
}

// plans_rollback_command connects plans when needed, opens the trusted display
// consent dialog for the previous generation (0 arguments) or a specific
// generation (1 argument), waits on the console worker thread until the
// principal decides, and returns the committed Plan_Generation_Row table.
plans_rollback_command :: proc "contextless" (arguments: []Value) -> Value {
	has_target := len(arguments) == 1
	target_generation: i64 = 0
	if has_target {
		target_generation = arguments[0].integer
		if target_generation < 1 {
			return fail("plans.rollback: the generation must be at least 1, not ", target_generation)
		}
	}
	sandbox_number, plans_file, connected := plans_ensure_connected()
	if !connected {
		return {}
	}
	ticket_val: Value
	if has_target {
		rb_cmd, rb_ok := plans_export_command(sandbox_number, plans_file, "rollback_to", "plans.rollback")
		if !rb_ok {
			return {}
		}
		rb_args := [1]Value{{kind = .Integer, integer = target_generation}}
		ticket_val = call_isolated(&rb_cmd, rb_args[:])
	} else {
		rb_cmd, rb_ok := plans_export_command(sandbox_number, plans_file, "rollback", "plans.rollback")
		if !rb_ok {
			return {}
		}
		ticket_val = call_isolated(&rb_cmd, nil)
	}
	if failed {
		return {}
	}
	if ticket_val.kind != .Integer || ticket_val.integer <= 0 {
		return fail("plans.rollback: the plans service did not return a consent ticket")
	}
	return plans_poll_until_decided("plans.rollback", sandbox_number, plans_file, "rollback_poll", ticket_val.integer)
}
