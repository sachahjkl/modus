#+build !freestanding
#+build !modus
package terminal_records

import "core:testing"
import "modus:contract/ring"
import "modus:system"

// A terminal of the test on host memory, and the intake that reads what
// it wrote: each record of the commands goes through the intake, as a
// renderer reads them.
@(private = "file")
Test_Pair :: struct {
	ring_memory: []u8,
	region:      []u8,
	sender:      Terminal,
	intake:      Renderer_Intake,
}

@(private = "file")
test_pair_make :: proc(t: ^testing.T) -> ^Test_Pair {
	pair := new(Test_Pair)
	pair.ring_memory = make([]u8, int(ring.pages(64)) * system.PAGE_SIZE)
	pair.region = make([]u8, 1 << 16)
	opened, ok := ring.open(raw_data(pair.ring_memory), ring.pages(64))
	testing.expect(t, ok)
	pair.sender = Terminal{ring = opened, text = pair.region}
	pair.intake = renderer_intake_make(pair.region)
	return pair
}

@(private = "file")
test_pair_free :: proc(pair: ^Test_Pair) {
	delete(pair.ring_memory)
	delete(pair.region)
	free(pair)
}

// test_pair_read gives each record to the intake, and the step of the last.
@(private = "file")
test_pair_read :: proc(pair: ^Test_Pair) -> (last: Renderer_Step) {
	for {
		record, ok := ring.pop(&pair.sender.ring.commands)
		if !ok {
			return last
		}
		last = renderer_intake_take(&pair.intake, record).step
	}
}

@(private = "file")
test_line :: proc(length: int) -> string {
	bytes := make([]u8, length)
	for &value in bytes {
		value = 'a'
	}
	return string(bytes)
}

// A run past the byte 256 of a line, and a run that crosses the border of
// two Edit_Part records (the first part ends at the byte 256), keep their
// kinds at each byte; a byte outside each run has none.
@(test)
an_edit_line_keeps_its_code_runs_past_one_record :: proc(t: ^testing.T) {
	pair := test_pair_make(t)
	defer test_pair_free(pair)
	line := test_line(600)
	defer delete(line)
	runs := [?]Code_Run{
		{start = 250, length = 12, kind = u8(Code_Kind.Function)}, // Across the border at 256.
		{start = 300, length = 10, kind = u8(Code_Kind.Number)},
		{start = 590, length = 10, kind = u8(Code_Kind.Text)}, // To the last byte.
	}
	code_runs_send(&pair.sender, .Edit, 0, runs[:])
	edit(&pair.sender, line, 3)
	testing.expect_value(t, test_pair_read(pair), Renderer_Step.Edit)
	edit_line := &pair.intake.edit
	testing.expect_value(t, edit_line.length, 600)
	testing.expect_value(t, edit_line.code.count, 3)
	testing.expect_value(t, pair.intake.runs_refused, u64(0))
	Expected :: struct {
		place: int,
		kind:  Code_Kind,
	}
	expected := [?]Expected{{249, .None}, {250, .Function}, {255, .Function}, {256, .Function}, {261, .Function}, {262, .None}, {299, .None}, {300, .Number}, {309, .Number}, {310, .None}, {589, .None}, {590, .Text}, {599, .Text}}
	cursor := 0
	for item in expected {
		kind := code_runs_kind_at(&edit_line.code, item.place, &cursor)
		testing.expectf(t, kind == item.kind, "the byte %d: %v", item.place, kind)
	}
}

// More runs than one record: they go in several Code_Runs records, and the
// Edit record takes all of them, in order. The next line with no runs is
// plain: the runs of a line never color the line after it.
@(test)
an_edit_line_takes_the_runs_of_several_records :: proc(t: ^testing.T) {
	pair := test_pair_make(t)
	defer test_pair_free(pair)
	line := test_line(1000)
	defer delete(line)
	runs: [3 * CODE_RUN_LIMIT]Code_Run
	for &run, index in runs {
		run = {start = u16(index * 5), length = 3, kind = u8(Code_Kind.Operator)}
	}
	code_runs_send(&pair.sender, .Edit, 0, runs[:])
	edit(&pair.sender, line, NO_CURSOR)
	testing.expect_value(t, test_pair_read(pair), Renderer_Step.Edit)
	testing.expect_value(t, pair.intake.edit.code.count, len(runs))
	testing.expect_value(t, pair.intake.edit.code.runs[len(runs) - 1].start, u16((len(runs) - 1) * 5))

	edit(&pair.sender, line, NO_CURSOR)
	testing.expect_value(t, test_pair_read(pair), Renderer_Step.Edit)
	testing.expect_value(t, pair.intake.edit.code.count, 0)
}

// A run past the end of the line refuses all the runs: the line is plain
// and whole. Runs past EDIT_CODE_RUN_LIMIT are not kept, and the add says
// so; the runs before stay.
@(test)
edit_code_runs_refused_past_the_line_and_past_the_limit :: proc(t: ^testing.T) {
	pair := test_pair_make(t)
	defer test_pair_free(pair)
	line := test_line(300)
	defer delete(line)
	runs := [?]Code_Run{{start = 10, length = 2, kind = u8(Code_Kind.Number)}, {start = 299, length = 2, kind = u8(Code_Kind.Text)}}
	code_runs_send(&pair.sender, .Edit, 0, runs[:])
	edit(&pair.sender, line, NO_CURSOR)
	testing.expect_value(t, test_pair_read(pair), Renderer_Step.Edit)
	testing.expect_value(t, pair.intake.edit.length, 300)
	testing.expect_value(t, pair.intake.edit.code.count, 0)
	testing.expect_value(t, pair.intake.runs_refused, u64(1))

	pending := new(Edit_Code_Runs)
	defer free(pending)
	one := [1]Code_Run{{start = 1, length = 1, kind = u8(Code_Kind.Number)}}
	bytes := ([^]u8)(&one)[:size_of(Code_Run)]
	pending.count = EDIT_CODE_RUN_LIMIT - 1
	testing.expect(t, edit_code_runs_add(pending, bytes, nil))
	testing.expect_value(t, pending.count, EDIT_CODE_RUN_LIMIT)
	testing.expect(t, !edit_code_runs_add(pending, bytes, nil))
	testing.expect_value(t, pending.count, EDIT_CODE_RUN_LIMIT)
	// A count damaged in the memory of the reader is brought back.
	pending.count = -3
	testing.expect(t, edit_code_runs_add(pending, bytes, nil))
	testing.expect_value(t, pending.count, 1)
	// Bytes that are not a whole count of runs.
	testing.expect(t, !edit_code_runs_add(pending, bytes[:3], nil))
	testing.expect_value(t, pending.count, 1)
}
