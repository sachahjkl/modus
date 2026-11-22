package output_measure

import "modus:contract/value_kinds"

// The log facts of the test module output_measure (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_measure: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A command of the root ring was refused: what the test asked, the status
// word, and the seven words of the error record of the completion, since
// several limits of the root service give one status.
@(log_fact = "output_measure: WRONG: {what} {status}; the error record: {error_kind} {error_unit} {error_operation} {error_argument} {error_value} {error_limit} {error_found}")
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

// A record of the log of the writer is not the next one.
@(log_fact = "output_measure: WRONG: the log of the writer: the record {record_serial} came as the status word {status_word}, the kind word {kind_word} and the serial {serial}")
Wrong_Log_Record :: struct {
	record_serial: u64,
	status_word:   u64,
	kind_word:     u64,
	serial:        u64,
}

// The log of the writer did not end with the stop of the writer.
@(log_fact = "output_measure: WRONG: the log of the writer ended with the end word {end_word} and the stop outcome {stop_outcome} after {records} records")
Wrong_Log_End :: struct {
	end_word:     u64,
	stop_outcome: u64,
	records:      u64,
}

// The wired log of the writer held each of its records, in order.
@(log_fact = "output_measure: the log of the writer, wired: {records} records in order, then its stop")
Log_Read :: struct {
	records: u64,
}

// Each run of the measure read each record in order.
@(log_fact = "output_measure: the writer with 1, 2, 4 and 8 readers, each record read in order by each reader, and with its log wired, each log record read in order: as it must")
Measured :: struct {}
