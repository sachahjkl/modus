// filter keeps the records of one stream that pass one condition
// (src/md/features/module_outputs.md, "Generic record inputs and the
// utility modules"). Its record input `source` is generic, of the count
// One, and takes the wiring terms `output.Condition_Terms`: one field of
// the record, one comparison and one value, the form of the condition of a
// row of a wiring list. Its record output `kept` takes the record of
// `source`.
//
// At the wiring of `source` it checks the condition against the record of
// that wiring (output.writer_condition_of_terms, the one border of a
// condition): a field that the record does not have, a value of another
// kind than the field, or any other refusal ends `kept` at once with that
// error record, and nothing passes. Then it writes into `kept` each record
// that passes (output.writer_condition_holds, the one test of a
// condition). A gap record of `source` becomes a gap record of `kept` with
// the same count, and a joined record that is not 0 a gap of its count.
// The end of `source` ends `kept` with the same error record; an end word
// gives the record State of the unit Wirings, whose value is the end word.
// Two conditions are two filters.
//
// **Start**: in a wiring list whose row to `filter.source` carries the
// terms. **What a reader sees**: no window; the records that pass, in
// `kept`. It stops itself with Done when `kept` ended.
package filter

import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/output"
import "modus:system"

// The stream to filter, with its condition as wiring terms.
source: system.Record_Input_With_Terms(system.Any_Record, output.Condition_Terms)

// The records of source that pass the condition.
kept: system.Record_Output(system.Any_Record)

// One record, as large as a record description allows.
record: [module.RECORD_SIZE_LIMIT]u8

// kept_end ends kept with an error record, and stops: no record passes a
// condition that does not hold, and nothing else is left to do.
@(private = "file")
kept_end :: proc "contextless" (error: errors.Error_Record) -> ! {
	system.output_end(&kept, error)
	system.stop(.Done)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The end of source: in the wiring ring before the first instruction
	// for a wiring of the start, or later for a Wire.
	for !system.input_has_writer(&source) {
		system.wiring_wait(system.WAIT_FOREVER)
	}
	file, description, described := system.input_description(&source)
	terms: output.Condition_Terms
	if !described || !system.input_terms(&source, &terms) {
		// The root service gives a record input with terms its terms and
		// its description with each end: a ring with neither comes from no
		// root service.
		system.stop(.Failed)
	}
	if !system.output_size_set(&kept, description.size) {
		system.stop(.Failed)
	}
	terms_bytes := transmute([size_of(output.Condition_Terms)]u8)terms
	condition, refusal, condition_ok := output.writer_condition_of_terms(terms_bytes[:], file, description)
	if !condition_ok {
		kept_end(refusal)
	}
	condition_bytes := transmute([size_of(output.Writer_Condition)]u8)condition
	checked, checked_ok := output.writer_condition_check(condition_bytes[:], description.size)
	if !checked_ok {
		kept_end(errors.error_make(.Bad_Value, .Wiring_Terms, i64(output.Condition_Terms_Field.Whole), 0, 0))
	}
	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		item, status := system.input_read_any(&source, record[:])
		switch status {
		case .Ok:
			switch item.kind {
			case .Joined:
				if item.serial != 0 {
					system.output_gap(&kept, item.serial)
				}
			case .Gap:
				system.output_gap(&kept, item.gap_count)
			case .Record:
				bytes := record[:item.record_size]
				if output.writer_condition_holds(checked, bytes) {
					system.output_write_any(&kept, bytes)
				}
			case .End:
			}
		case .Ended:
			if item.end_word != .None {
				kept_end(errors.error_make(.State, .Wirings, 0, i64(item.end_word), 0, i64(item.tag)))
			}
			kept_end(item.error)
		case .Bad_Record:
			kept_end(item.refusal)
		case .No_Writer:
			// The library closed the one ring of source with no end:
			// nothing more comes.
			kept_end(errors.error_make(.State, .Wirings, 0, 0, 0, 0))
		case .Full, .No_Reader, .No_Record:
			// No read gives them with no deadline.
		}
	}
}

// The tool counts the module and thread stack; working memory holds the wiring
// ring mappings and tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256}
