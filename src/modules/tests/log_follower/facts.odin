package log_follower

import "modus:contract/value_kinds"

// The log facts of the test module log_follower
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before. A text
// view is the last field. No field has the name of a column of the head of
// facts(): number, time, process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "log_follower: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A command of the root ring was refused: what the test asked, the status
// word, and the seven words of the error record of the completion, since
// several limits of the root service give one status.
@(log_fact = "log_follower: WRONG: {what} {status}; the error record: {error_kind} {error_unit} {error_operation} {error_argument} {error_value} {error_limit} {error_found}")
Wrong_Refused :: struct {
	status:          u64,
	error_kind:      u64,
	error_unit:      u64,
	error_operation: u64,
	error_argument:  u64,
	error_value:     u64,
	error_limit:     u64,
	error_found:     u64,
	what:            value_kinds.Text_View,
}

// The kernel took fewer records of the flood than the test needs within
// the hang bound.
@(log_fact = "log_follower: WRONG: the kernel took fewer than {target} of {written} lines within the hang bound, in milliseconds: {bound_milliseconds}")
Wrong_Flood_Not_Taken :: struct {
	target:             u64,
	written:            u64,
	bound_milliseconds: u64,
}

// One record of the flood: the test counts the records that the kernel
// takes, whatever their form.
@(log_fact = "log_follower: a record of the flood")
Flood_Record :: struct {}

// A read of log.follow gave another status than Ok.
@(log_fact = "log_follower: WRONG: a read of log.follow gave the status word {status_word}, the kind word {kind_word} and the end word {end_word}")
Wrong_Read :: struct {
	status_word: u64,
	kind_word:   u64,
	end_word:    u64,
}

// The gap record does not follow the last row before it.
@(log_fact = "log_follower: WRONG: the gap record of log.follow: the serial {serial} and the count {gap_count} after {rows_before} rows, the last of the serial {last_serial}")
Wrong_Gap :: struct {
	serial:      u64,
	gap_count:   u64,
	rows_before: u64,
	last_serial: u64,
}

// The row after the gap is not the row after the records that the gap
// counts.
@(log_fact = "log_follower: WRONG: after the gap of {gap_count} records from the serial {gap_serial}: the kind word {kind_word}, the serial {serial} and the number {row_number}; the last row before the gap had the number {last_row_number}")
Wrong_After_Gap :: struct {
	gap_count:       u64,
	gap_serial:      u64,
	kind_word:       u64,
	serial:          u64,
	row_number:      i64,
	last_row_number: i64,
}

// log.follow gave the rows in order, one gap record of the records that
// the kernel wrote over, and the row after them.
@(log_fact = "log_follower: log.follow gave {rows_before} rows in order, then one gap record of {gap_count} records that the kernel wrote over, then the row of the number after them, after {written} lines of this process that the kernel took: as it must")
Gap_Read :: struct {
	rows_before: u64,
	gap_count:   u64,
	written:     u64,
}

// A row before the gap is not the next row.
@(log_fact = "log_follower: WRONG: before the gap: the kind word {kind_word}, the serial {serial} and the number {row_number} after the serial {last_serial} and the number {last_row_number}")
Wrong_Before_Gap :: struct {
	kind_word:       u64,
	serial:          u64,
	row_number:      i64,
	last_serial:     u64,
	last_row_number: i64,
}
