#+build !freestanding
#+build !modus
package output

import "core:testing"
import "modus:contract/module"
import op "modus:contract/operation"

// The writer side: a generic record output Paired takes the type of the
// source of its pair, whatever its record input says. The refusals: one
// whose record input has no fixed type; one
// whose record input keeps a type for each wiring, fixed or not. A record
// output of a record, and a generic one whose record input has a fixed
// type, pass last.
@(test)
a_generic_record_output_takes_only_a_fixed_type :: proc(t: ^testing.T) {
	for wirings in module.Wiring_Count {
		for fixed in ([?]bool{false, true}) {
			testing.expectf(t, generic_writer_step_of(0, .Paired, wirings, fixed) == .Paired_Source, "Paired with %v, fixed %v", wirings, fixed)
		}
	}
	testing.expect_value(t, generic_writer_step_of(0, .Unpaired, .One, false), Generic_Writer_Step.Not_Fixed)
	testing.expect_value(t, generic_writer_step_of(0, .Unpaired, .Many, false), Generic_Writer_Step.Not_Fixed)
	testing.expect_value(t, generic_writer_step_of(0, .Unpaired, .Many_Types, false), Generic_Writer_Step.Not_Fixed)
	testing.expect_value(t, generic_writer_step_of(0, .Unpaired, .Many_Types, true), Generic_Writer_Step.Not_Fixed)
	// A record output of a record: its own record, whatever the rest says.
	for record in ([?]u32{1, max(u32)}) {
		testing.expect_value(t, generic_writer_step_of(record, .Unpaired, .Many_Types, false), Generic_Writer_Step.Declared)
	}
	testing.expect_value(t, generic_writer_step_of(0, .Unpaired, .One, true), Generic_Writer_Step.Fixed_Type)
	testing.expect_value(t, generic_writer_step_of(0, .Unpaired, .Many, true), Generic_Writer_Step.Fixed_Type)
}

// The reader side: a fixed type is compared, never fixed again; the count
// Many_Types never fixes and never compares; a declared record is
// compared whatever the facts of a generic one say.
@(test)
a_generic_record_input_fixes_its_type_once :: proc(t: ^testing.T) {
	testing.expect_value(t, generic_reader_step_of(0, .Many, true), Generic_Reader_Step.Compare_Fixed)
	testing.expect_value(t, generic_reader_step_of(0, .One, true), Generic_Reader_Step.Compare_Fixed)
	testing.expect_value(t, generic_reader_step_of(0, .Many_Types, true), Generic_Reader_Step.Take_Each)
	testing.expect_value(t, generic_reader_step_of(0, .Many_Types, false), Generic_Reader_Step.Take_Each)
	for wirings in module.Wiring_Count {
		testing.expect_value(t, generic_reader_step_of(7, wirings, false), Generic_Reader_Step.Compare_Declared)
		testing.expect_value(t, generic_reader_step_of(7, wirings, true), Generic_Reader_Step.Compare_Declared)
	}
	testing.expect_value(t, generic_reader_step_of(0, .Many, false), Generic_Reader_Step.Fix)
	testing.expect_value(t, generic_reader_step_of(0, .One, false), Generic_Reader_Step.Fix)
}

// Which delivered row keeps the type: the row that compared with the fixed
// type keeps it as the row that fixed it does, so a list whose fixing row
// ended at its delivery still leaves the type of the records that its
// reader reads. A declared record and Many_Types keep none.
@(test)
each_delivered_row_of_a_fixed_type_keeps_it :: proc(t: ^testing.T) {
	testing.expect(t, !generic_reader_keeps(.Compare_Declared))
	testing.expect(t, !generic_reader_keeps(.Take_Each))
	testing.expect(t, generic_reader_keeps(.Compare_Fixed))
	testing.expect(t, generic_reader_keeps(.Fix))
	// The scenario: row 1 fixes, row 2 compares; row 1 ends at its
	// delivery, row 2 reaches its reader and must keep the type.
	first := generic_reader_step_of(0, .Many, false)
	second := generic_reader_step_of(0, .Many, true)
	testing.expect(t, first == .Fix && second == .Compare_Fixed && generic_reader_keeps(second))
}

// The bound of the types that a process keeps: refusals first, at the
// bound and past it, a negative count, a bound of 0; then the room under
// the bound.
@(test)
the_types_of_a_process_have_a_bound :: proc(t: ^testing.T) {
	MOST :: 4
	testing.expect(t, !generic_type_room_of(4, 0, MOST))
	testing.expect(t, !generic_type_room_of(5, 0, MOST))
	testing.expect(t, !generic_type_room_of(3, 1, MOST))
	testing.expect(t, !generic_type_room_of(0, 4, MOST))
	testing.expect(t, !generic_type_room_of(0, 0, 0))
	testing.expect(t, !generic_type_room_of(-1, 0, MOST))
	testing.expect(t, !generic_type_room_of(0, -1, MOST))
	testing.expect(t, !generic_type_room_of(max(int), max(int), MOST))
	testing.expect(t, generic_type_room_of(3, 0, MOST))
	testing.expect(t, generic_type_room_of(0, 3, MOST))
	testing.expect(t, generic_type_room_of(0, 0, MOST))
	testing.expect(t, generic_type_room_of(1, 2, MOST))
}

// The wait of a reader: the words beside the rings, then 3 for each ring;
// the most rings that the largest wait of the kernel holds, and one past
// them, which does not fit.
@(test)
the_rings_of_a_reader_fit_one_wait :: proc(t: ^testing.T) {
	testing.expect_value(t, reader_wait_words(0), READER_WAIT_WORDS_BESIDE_RINGS)
	testing.expect_value(t, reader_wait_words(1), READER_WAIT_WORDS_BESIDE_RINGS + READER_WAIT_WORDS_OF_A_RING)
	most := (op.WORD_WAIT_MOST - READER_WAIT_WORDS_BESIDE_RINGS) / READER_WAIT_WORDS_OF_A_RING
	testing.expect(t, reader_wait_words(most) <= op.WORD_WAIT_MOST)
	testing.expect(t, reader_wait_words(most + 1) > op.WORD_WAIT_MOST)
}

// The turn of a reader of several rings: a place outside the table and an
// empty table start again at 0; each place gives the next one, and the
// last one the first. No place is skipped, so no ring is kept out.
@(test)
the_turn_of_a_reader_visits_each_ring :: proc(t: ^testing.T) {
	testing.expect_value(t, ring_turn_next(-1, 4), 0)
	testing.expect_value(t, ring_turn_next(4, 4), 0)
	testing.expect_value(t, ring_turn_next(max(int), 4), 0)
	testing.expect_value(t, ring_turn_next(0, 0), 0)
	testing.expect_value(t, ring_turn_next(0, -3), 0)
	testing.expect_value(t, ring_turn_next(0, 1), 0)
	seen: [4]int
	place := 0
	for _ in 0 ..< 8 {
		seen[place] += 1
		place = ring_turn_next(place, 4)
	}
	testing.expect_value(t, seen, [4]int{2, 2, 2, 2})
}
