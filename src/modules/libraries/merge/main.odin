// merge joins several streams of one record into one
// (src/md/features/module_outputs.md, "Generic record inputs and the
// utility modules"). Its record input `sources` is generic, of the count
// Many: the first wiring fixes its record, and each later source must have
// the same one, which the root service checks. Its record output `merged`
// takes that record.
//
// It writes each record of each source in the order in which it reads
// them: the rings are read in turn, each in its own order, and no order
// across sources is given. `merged` has serials of its own:
//
// - a gap record of a source becomes a gap record of `merged` with the
//   same count;
// - a joined record of a source that is not 0 becomes a gap record of its
//   count, so the reader of `merged` knows what the sources lacked;
// - when each source ended, `merged` ends: clean when each source ended
//   with a clean end record, else with the first error record. A source
//   that ended by an end word (its writer stopped, a revocation) or that
//   the library refused gives the record State of the unit Wirings, whose
//   value is that end word, or the refusal of the record.
//
// It waits for room in each ring of `merged`: a slow reader of `merged`
// holds merge, and the pace of each source then says whether that source
// waits or loses records with a gap. merge never waits for a time.
//
// **Start**: in a wiring list, `start("merge", wire(alpha.out,
// merge.sources) + wire(beta.out, merge.sources))`, then read
// `merge.merged`. **What a reader sees**: no window; the records of the
// sources in `merged`. It stops itself with Done when `merged` ended.
package merge

import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/output"
import "modus:support/system"

// The streams to join, each of the record that the first one fixed.
sources: system.Record_Input(system.Any_Record, .Many)

// The records of each source, in the order in which merge read them.
merged: system.Record_Output(system.Any_Record)

// One record, as large as a record description allows.
record: [module.RECORD_SIZE_LIMIT]u8

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	first_error: errors.Error_Record
	ended_with_error := false
	seen := false
	for {
		item, status := system.input_read_any(&sources, record[:])
		switch status {
		case .No_Writer:
			// No source holds a ring now: before the first one, wait for a
			// wiring; after one, each source ended.
			if seen {
				system.output_end(&merged, first_error)
				system.stop(.Done)
			}
			system.wiring_wait(system.WAIT_FOREVER)
			continue
		case .Ok:
			seen = true
			if !system.output_size_set(&merged, item.record_size) {
				// The root service fixed one record for each source: a
				// ring of another size comes from no root service.
				if !ended_with_error {
					first_error = errors.error_make(.Bad_Value, .Record_Types, 0, i64(item.record_size), i64(merged.record_size), i64(item.tag))
					ended_with_error = true
				}
				continue
			}
			switch item.kind {
			case .Joined:
				if item.serial != 0 {
					system.output_gap(&merged, item.serial)
				}
			case .Gap:
				system.output_gap(&merged, item.gap_count)
			case .Record:
				system.output_write_any(&merged, record[:item.record_size])
			case .End:
			}
		case .Ended:
			seen = true
			// An end record with its error record, or an end word.
			error := item.error
			if item.end_word != .None {
				error = errors.error_make(.State, .Wirings, 0, i64(item.end_word), 0, i64(item.tag))
			}
			if error != {} && !ended_with_error {
				first_error, ended_with_error = error, true
			}
		case .Bad_Record:
			seen = true
			if !ended_with_error {
				first_error, ended_with_error = item.refusal, true
			}
		case .Full, .No_Reader, .No_Record:
			// No read gives them with no deadline.
		}
	}
}
