#+build !freestanding
package interface_module

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:display"
import "modus:interface"
import "modus:system"
import "modus:text_rendering"

// The pair of an export, as one value that a test compares.
@(private = "file")
Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}

@(private = "file")
answer_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> Answer {
	return {outcome, value}
}

// A capacity over the largest int, as a hostile caller gives it: the
// capacity is refused with an error record of the draw table, and a table
// of 4 places takes the two records.
@(test)
hostile_capacity_is_refused :: proc(t: ^testing.T) {
	memory: [4]interface.Draw_Record
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 1 << 63}
	area := Area{0, 0, 8, 8}
	error: errors.Error_Record
	testing.expect_value(t, answer_of(draw_background(&drawn, &area, &error)), Answer{.Argument_Refused, 0})
	testing.expect_value(t, error.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, error.unit, i64(errors.Unit.Records))
	testing.expect_value(t, error.argument, ARGUMENT_DRAWN)
	testing.expect_value(t, error.value, max(i64)) // The capacity, past the largest i64.
	testing.expect_value(t, error.limit, i64(TABLE_LIMIT))
	drawn = {records = &memory[0], count = 0, capacity = 4}
	testing.expect_value(t, answer_of(draw_background(&drawn, &area, nil)), Answer{.Succeeded, 2})
}

// A text table past 2^32 bytes: a text record names its bytes with a u32,
// so the call refuses it with Out_Of_Range of the text table, and appends
// nothing.
@(test)
text_table_past_two_to_the_32_is_refused :: proc(t: ^testing.T) {
	memory: [4]interface.Draw_Record
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 4}
	text_memory: [8]u8
	text := system.Bytes_To_Append{bytes = &text_memory[0], count = u64(max(u32)), capacity = 4}
	cell := Area{0, 0, 64, 16}
	words := "abc"
	error: errors.Error_Record
	testing.expect_value(t, answer_of(draw_cell_text(&drawn, &text, &cell, &words, 0, 0, &error)), Answer{.Argument_Refused, 0})
	testing.expect_value(t, error.kind, i64(errors.Kind.Out_Of_Range))
	testing.expect_value(t, error.unit, i64(errors.Unit.Bytes))
	testing.expect_value(t, error.argument, ARGUMENT_TEXT)
	testing.expect_value(t, error.value, i64(max(u32)) + i64(len(words)))
	testing.expect_value(t, error.limit, i64(max(u32)))
	testing.expect_value(t, drawn.count, 0)
}

// The Append rule across calls (docs/MODULE_CONTRACT.md, "Did not fit,
// across calls"): the counts are the counts of the full answer, also
// after a call that did not fit and a call that appends nothing; nothing
// is written at or after a capacity.
@(test)
counts_of_the_full_answer_across_calls :: proc(t: ^testing.T) {
	memory: [4]interface.Draw_Record // 3 places, then a guard record.
	memory[3] = {element = 0xA5A5_A5A5}
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 3}
	text_memory: [8]u8
	text_memory[4] = 0xA5
	text := system.Bytes_To_Append{bytes = &text_memory[0], count = 0, capacity = 4}
	area := Area{0, 0, 8, 8}
	testing.expect_value(t, answer_of(draw_background(&drawn, &area, nil)), Answer{.Succeeded, 2}) // A rectangle and the grid.
	testing.expect_value(t, answer_of(draw_background(&drawn, &area, nil)), Answer{.Succeeded, 4}) // 1 of 2 fits.
	// A cell wide enough for the six characters: a text is cut to its cell,
	// and this test is about the counts, not about the cut.
	wide := Area{0, 0, 64, 16}
	empty := ""
	testing.expect_value(t, answer_of(draw_cell_text(&drawn, &text, &wide, &empty, 0, 0, nil)), Answer{.Succeeded, 4}) // Appends nothing.
	words := "abcdef"
	testing.expect_value(t, answer_of(draw_cell_text(&drawn, &text, &wide, &words, 0, 0, nil)), Answer{.Succeeded, 5})
	testing.expect_value(t, text.count, 6) // The 6 bytes of the full answer; 4 fit.
	testing.expect_value(t, string(text_memory[:4]), "abcd")
	testing.expect_value(t, text_memory[4], 0xA5)
	testing.expect_value(t, memory[3].element, 0xA5A5_A5A5)
}

@(private = "file")
test_places_ready: bool
@(private = "file")
test_places_boot: []u8
@(private = "file")
test_places_calls: u32

@(private = "file")
test_places_stub :: proc "contextless" () -> (boot_bytes, scripts_bytes: []u8, ok: bool) {
	intrinsics.atomic_add_explicit(&test_places_calls, 1, .Acq_Rel)
	if !intrinsics.atomic_load_explicit(&test_places_ready, .Acquire) {
		return nil, nil, false
	}
	return test_places_boot, nil, true
}

// Before the host process calls process_fonts_open, interface_font_resolve
// returns nil without latching None permanently; once places become available,
// concurrent callers serialize via the Opening CAS so outlines load once.
@(test)
interface_font_unlatched_retry_and_concurrency :: proc(t: ^testing.T) {
	fonts := [4]font_outlines.Font_Input {
		{"b612", #load("../../../../resources/fonts/b612.ttf")},
		{"b612_bold", #load("../../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", #load("../../../../resources/fonts/paper_mono.ttf")},
		{"paper_mono_semibold", #load("../../../../resources/fonts/paper_mono_semibold.ttf")},
	}
	size := font_outlines.resource_size(fonts[:])
	words := make([]u64, (size + 7) / 8, runtime.heap_allocator())
	defer delete(words, runtime.heap_allocator())
	outlines_bytes := ([^]u8)(raw_data(words))[:size]
	_, written := font_outlines.resource_write(fonts[:], outlines_bytes)
	testing.expect(t, written)

	// Reset module font state before and after the test.
	defer {
		intrinsics.atomic_store_explicit(&module_interface_font_state, .Unchecked, .Release)
		module_interface_font = {}
		text_rendering.state = {}
		test_places_boot = nil
		intrinsics.atomic_store_explicit(&test_places_ready, false, .Release)
	}
	intrinsics.atomic_store_explicit(&module_interface_font_state, .Unchecked, .Seq_Cst)
	module_interface_font = {}
	text_rendering.state = {}
	test_places_boot = outlines_bytes
	intrinsics.atomic_store_explicit(&test_places_ready, false, .Seq_Cst)
	intrinsics.atomic_store_explicit(&test_places_calls, 0, .Seq_Cst)

	// Not ready yet: returns nil and stays Unchecked (never latches None).
	testing.expect(t, interface_font_resolve(test_places_stub) == nil)
	testing.expect_value(t, intrinsics.atomic_load_explicit(&module_interface_font_state, .Seq_Cst), Interface_Font_State.Unchecked)
	testing.expect_value(t, intrinsics.atomic_load_explicit(&test_places_calls, .Seq_Cst), u32(1))

	// Now make places available and race 4 threads against interface_font_resolve.
	intrinsics.atomic_store_explicit(&test_places_ready, true, .Seq_Cst)
	intrinsics.atomic_store_explicit(&test_places_calls, 0, .Seq_Cst)

	Worker :: struct {
		barrier: ^sync.Barrier,
		result:  ^display.Interface_Font,
	}
	WORKERS :: 4
	barrier: sync.Barrier
	sync.barrier_init(&barrier, WORKERS)
	workers: [WORKERS]Worker
	threads: [WORKERS]^thread.Thread
	for i in 0 ..< WORKERS {
		workers[i] = {barrier = &barrier}
		threads[i] = thread.create_and_start_with_data(&workers[i], proc(data: rawptr) {
			w := (^Worker)(data)
			sync.barrier_wait(w.barrier)
			w.result = interface_font_resolve(test_places_stub)
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, intrinsics.atomic_load_explicit(&module_interface_font_state, .Acquire), Interface_Font_State.Given)
	testing.expect_value(t, intrinsics.atomic_load_explicit(&test_places_calls, .Acquire), u32(1))
	for w in workers {
		testing.expect(t, w.result == &module_interface_font, "every racing thread receives the opened interface font")
	}
}
