#+build !freestanding
package agent_step

import "core:testing"
import "modus:contract/wide_grants"

@(private = "file")
Fake_Machine :: struct {
	now:        u64,
	tick_step:  u64,
	call_count: int,
}

@(private = "file")
fake_now :: proc "contextless" (user_data: rawptr) -> u64 {
	m := (^Fake_Machine)(user_data)
	return m.now
}

@(private = "file")
set_cell :: proc "contextless" (tbl: ^Step_Table, row, col: int, text: string, has_int := false, iv: i64 = 0) {
	cell := &tbl.cells[row * tbl.column_count + col]
	cell.text_count = u8(copy(cell.text[:], text))
	cell.has_integer = has_int
	cell.integer = iv
}

@(private = "file")
fake_call_export :: proc "contextless" (user_data: rawptr, service, export: string, args: []Step_Arg, out: ^Step_Call_Result) -> bool {
	m := (^Fake_Machine)(user_data)
	m.call_count += 1
	m.now += m.tick_step
	if service == "monitor" && export == "processes" {
		tbl := out.table
		tbl.name_count = u8(copy(tbl.name[:], "Process"))
		tbl.column_count = 3
		tbl.columns[0][0] = 's'; tbl.columns[0][1] = 'l'; tbl.columns[0][2] = 'o'; tbl.columns[0][3] = 't'; tbl.column_lens[0] = 4
		tbl.column_kinds[0] = .Integer
		tbl.column_lens[1] = u8(copy(tbl.columns[1][:], "name"))
		tbl.column_kinds[1] = .Text
		tbl.column_lens[2] = u8(copy(tbl.columns[2][:], "pages"))
		tbl.column_kinds[2] = .Integer
		tbl.row_count = 3
		tbl.total_rows = 3
		set_cell(tbl, 0, 0, "1", true, 1); set_cell(tbl, 0, 1, "root"); set_cell(tbl, 0, 2, "500", true, 500)
		set_cell(tbl, 1, 0, "2", true, 2); set_cell(tbl, 1, 1, "console"); set_cell(tbl, 1, 2, "200", true, 200)
		set_cell(tbl, 2, 0, "3", true, 3); set_cell(tbl, 2, 1, "assistant"); set_cell(tbl, 2, 2, "4648", true, 4648)
		out.kind = .Table
		out.has_table = true
		return true
	}
	if service == "monitor" && export == "count" {
		out.kind = .Integer
		out.integer = len(args) > 0 && args[0].kind == .Integer ? args[0].integer * 10 : 3
		return true
	}
	if service == "manual" && export == "modules" {
		tbl := out.table
		tbl.name_count = u8(copy(tbl.name[:], "Module"))
		tbl.column_count = 1
		tbl.column_lens[0] = u8(copy(tbl.columns[0][:], "name"))
		tbl.column_kinds[0] = .Text
		tbl.row_count = 2
		tbl.total_rows = 2
		set_cell(tbl, 0, 0, "monitor")
		set_cell(tbl, 1, 0, "manual")
		out.kind = .Table
		out.has_table = true
		return true
	}
	return false
}

// Multi-line step binds variables across lines and across steps within one
// request, pipes through where/sort/first/count/column + map/filter, emits
// a valid BLAKE3 act chain, and clears bindings on session_reset_bindings.
@(test)
test_multiline_step_bindings_pipes_and_cross_step_persistence :: proc(t: ^testing.T) {
	session := new(Step_Session)
	defer free(session)
	session_init(session, grant_serial = 9)

	machine := Fake_Machine{now = 1000, tick_step = 5}
	transport := Step_Transport{user_data = &machine, call_export = fake_call_export, now_ms = fake_now}

	step1 := []string{
		`p = monitor.processes()`,
		`big = p |> where(pages > 300)`,
		`big |> count()`,
		`names = column(big, "name")`,
		`slots = filter(column(p, "slot"), (s) => s >= 2)`,
		`map(slots, (s) => monitor.count(s))`,
	}
	out1 := step_run(session, step1, transport)
	testing.expectf(t, out1.ok, "step1 refused: %v at line %d (%s)", out1.refusal, out1.failed_line, string(out1.refused_command[:out1.refused_command_len]))
	testing.expect_value(t, out1.line_count, len(step1))
	testing.expect_value(t, out1.calls_made, 3) // 1x monitor.processes + 2x monitor.count inside map
	testing.expect_value(t, out1.lines[2].integer, i64(2)) // root (500) + assistant (4648)
	testing.expect_value(t, string(out1.lines[5].summary[:out1.lines[5].summary_len]), "[20, 30]")

	// Second step reuses `big` bound in step 1 without calling monitor.processes() again.
	step2 := []string{
		`sorted = big |> sort("name")`,
		`sorted |> first(1) |> count()`,
		`names |> count()`,
	}
	out2 := step_run(session, step2, transport)
	testing.expectf(t, out2.ok, "step2 refused: %v at line %d", out2.refusal, out2.failed_line)
	testing.expect_value(t, out2.calls_made, 0)
	testing.expect_value(t, out2.lines[1].integer, i64(1))
	testing.expect_value(t, out2.lines[2].integer, i64(2))

	// Audit chain must contain step + line + call records and verify whole.
	records := session_act_records(session)
	// step1: 1 step + 6 lines + 3 calls = 10; step2: 1 step + 3 lines + 0 calls = 4 -> total 14.
	testing.expect_value(t, len(records), 14)
	chain_refusal, _ := wide_grants.act_chain_verify(records, 0, wide_grants.GENESIS_PREVIOUS_HASH)
	testing.expect_value(t, chain_refusal, wide_grants.Wide_Grant_Refusal.None)

	// New request clears bindings so `big` is no longer visible.
	session_reset_bindings(session)
	out3 := step_run(session, []string{`big |> count()`}, transport)
	testing.expect(t, !out3.ok)
	testing.expect_value(t, out3.refusal, Step_Refusal.Evaluation_Refused)
}

// Read-only border refuses every unauthorized export and mutating built-in
// with No_Grant and zero machine calls — including calls hidden inside
// map/filter lambdas, let bindings, and nested arguments.
@(test)
test_read_only_border_refuses_unauthorized_calls_everywhere :: proc(t: ^testing.T) {
	session := new(Step_Session)
	defer free(session)
	session_init(session, grant_serial = 11)

	machine := Fake_Machine{now = 1000}
	transport := Step_Transport{user_data = &machine, call_export = fake_call_export, now_ms = fake_now}

	forbidden := []string{
		`plans.apply("home")`,
		`plans.rollback()`,
		`settings.set(.french)`,
		`assistant.act_result(1, 5, "ok")`,
		`compositor.act_ask("plans.apply")`,
		`start("notes")`,
		`stop(1)`,
		`load("x")`,
		`isolate("x")`,
		`revoke(1)`,
		`lock()`,
		`map([1, 2], (x) => plans.apply("home"))`,
		`filter([1, 2], (x) => stop(x))`,
		`let f = (x) => settings.set(x) in f(1)`,
		`monitor.count(plans.apply("home"))`,
	}
	for line in forbidden {
		before_calls := machine.call_count
		out := step_run(session, []string{line}, transport)
		testing.expectf(t, !out.ok && out.refusal == .No_Grant, "%q: expected No_Grant, got ok=%v refusal=%v", line, out.ok, out.refusal)
		testing.expect_value(t, machine.call_count, before_calls)
	}
}

// Step bounds: 0 lines, 17 lines, control byte, 65 export calls, monotonic
// time bound exceeded, and fail-closed Act_Log_Full before execution.
@(test)
test_step_bounds_and_fail_closed_act_log :: proc(t: ^testing.T) {
	session := new(Step_Session)
	defer free(session)
	session_init(session, grant_serial = 12)

	machine := Fake_Machine{now = 1000}
	transport := Step_Transport{user_data = &machine, call_export = fake_call_export, now_ms = fake_now}

	// 0 lines -> Empty_Step.
	testing.expect_value(t, step_run(session, nil, transport).refusal, Step_Refusal.Empty_Step)

	// 17 lines -> Too_Many_Lines.
	too_many: [STEP_LINE_CAPACITY + 1]string
	for i in 0 ..< len(too_many) {
		too_many[i] = "1 + 1"
	}
	testing.expect_value(t, step_run(session, too_many[:], transport).refusal, Step_Refusal.Too_Many_Lines)

	// Control byte in line -> Invalid_Line.
	testing.expect_value(t, step_run(session, []string{"1 +\n1"}, transport).refusal, Step_Refusal.Invalid_Line)

	// 65 export calls in one step -> Call_Limit_Exceeded after exactly 64 calls.
	// Build a 13-element list mapped over 5 lines = 65 calls.
	session_init(session, grant_serial = 13)
	machine.call_count = 0
	call_limit_lines := []string{
		`xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]`,
		`map(xs, (x) => monitor.count(x))`,
		`map(xs, (x) => monitor.count(x))`,
		`map(xs, (x) => monitor.count(x))`,
		`map(xs, (x) => monitor.count(x))`,
		`map(xs, (x) => monitor.count(x))`,
	}
	limit_out := step_run(session, call_limit_lines, transport)
	testing.expect(t, !limit_out.ok)
	testing.expect_value(t, limit_out.refusal, Step_Refusal.Call_Limit_Exceeded)
	testing.expect_value(t, limit_out.calls_made, STEP_CALL_CAPACITY)
	testing.expect_value(t, machine.call_count, STEP_CALL_CAPACITY)

	// Monotonic time bound exceeded -> Time_Bound_Exceeded before running past bound.
	session_init(session, grant_serial = 14, time_bound_ms = 100)
	machine = Fake_Machine{now = 1000, tick_step = 60}
	time_out := step_run(session, []string{`monitor.count(1)`, `monitor.count(2)`, `monitor.count(3)`}, transport)
	testing.expect(t, !time_out.ok)
	testing.expect_value(t, time_out.refusal, Step_Refusal.Time_Bound_Exceeded)
	testing.expect(t, machine.call_count <= 2)

	// Fail-closed act log: capacity 2 allows step record + line 1 record, then
	// refuses export call BEFORE calling transport!
	session_init(session, grant_serial = 15, act_log_capacity = 2)
	machine = Fake_Machine{now = 1000}
	log_out := step_run(session, []string{`monitor.count(1)`}, transport)
	testing.expect(t, !log_out.ok)
	testing.expect_value(t, log_out.refusal, Step_Refusal.Act_Log_Full)
	testing.expect_value(t, machine.call_count, 0)
	chain_refusal, _ := wide_grants.act_chain_verify(session_act_records(session), 0, wide_grants.GENESIS_PREVIOUS_HASH)
	testing.expect_value(t, chain_refusal, wide_grants.Wide_Grant_Refusal.None)
}
