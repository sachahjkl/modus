package tables

import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of tables (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// The answer of a case is a short text of numbers and words, which a Text
// field holds: the longest answer has under 87 bytes when each number in it
// has at most 10 digits. A hostile case whose answer is an error record
// writes the fields of the record; its template ends with them, so each
// such case has its fact types, the answer shown and the wrong answer.
//
// The start of the call host that fails stays text: its load error is a
// sentence of module.Load_Error, whose names pass the 144 bytes of one
// fact, and no contract form gives a load error as fields.

// The bytes of the Text fields of a case: the name of a case, at most 37
// bytes; the name of a way, at most 11; its answer, at most 87.
CASE_FIELD_BYTES :: 40
WAY_FIELD_BYTES :: 16
ANSWER_FIELD_BYTES :: 88

// The hostile cases whose answer is an error record.
Refusal_Case :: enum u8 {
	None,
	Memory_Object_To_Service,
	Budget_As_Table_Memory,
	Count_Past_Its_Bound,
	Start_That_Wraps,
}

// The context of the process holds no random seed.
@(log_fact = "tables: no random seed in the context")
No_Random_Seed :: struct {}

// A call of a measure was refused: its way, its rows, the call and the
// status of the call, as its number.
@(log_fact = "tables: {way}, {rows} rows: call {call} gave the status {status_word}")
Measure_Call_Refused :: struct {
	rows:        u64,
	call:        u64,
	status_word: u64,
	way:         [32]u8,
}

// A case gave another answer in one way than the one it must give.
@(log_fact = "tables: wrong answer: {case_name}, {call_way}: {answer}")
Answer_Wrong :: struct {
	case_name: [40]u8,
	call_way:  [16]u8,
	answer:    [88]u8,
}

// The answer of a hostile case.
@(log_fact = "tables: {case_name}: {answer}")
Hostile_Answer :: struct {
	case_name: [40]u8,
	answer:    [88]u8,
}

// A hostile case gave another answer than the one it must give.
@(log_fact = "tables: wrong answer: {case_name}: {answer}")
Hostile_Answer_Wrong :: struct {
	case_name: [40]u8,
	answer:    [88]u8,
}

// A memory object given to the service is refused.
@(log_fact = "tables: a memory object to the service: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Memory_Object_To_Service_Refused :: distinct errors.Error_Record_Fact_Fields

// The refusal of a memory object to the service is not the one it must be.
@(log_fact = "tables: wrong answer: a memory object to the service: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Memory_Object_To_Service_Wrong :: distinct errors.Error_Record_Fact_Fields

// A budget given as the memory of a table is refused.
@(log_fact = "tables: a budget as the memory of a table: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Budget_As_Table_Memory_Refused :: distinct errors.Error_Record_Fact_Fields

// The refusal of a budget as the memory of a table is not the one it must
// be.
@(log_fact = "tables: wrong answer: a budget as the memory of a table: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Budget_As_Table_Memory_Wrong :: distinct errors.Error_Record_Fact_Fields

// A count of 2^40 rows is refused.
@(log_fact = "tables: a count of 2^40 rows: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Count_Past_Its_Bound_Refused :: distinct errors.Error_Record_Fact_Fields

// The refusal of a count of 2^40 rows is not the one it must be.
@(log_fact = "tables: wrong answer: a count of 2^40 rows: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Count_Past_Its_Bound_Wrong :: distinct errors.Error_Record_Fact_Fields

// A start of rows that wraps is refused.
@(log_fact = "tables: a start that wraps: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Start_That_Wraps_Refused :: distinct errors.Error_Record_Fact_Fields

// The refusal of a start that wraps is not the one it must be.
@(log_fact = "tables: wrong answer: a start that wraps: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Start_That_Wraps_Wrong :: distinct errors.Error_Record_Fact_Fields

// case_field gives the Text field of the name of a case.
case_field :: proc "contextless" (name: string) -> [CASE_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, CASE_FIELD_BYTES)
}

// answer_field gives the Text field of the answer of a case.
answer_field :: proc "contextless" (answer: ^Answer) -> [ANSWER_FIELD_BYTES]u8 {
	return value_kinds.text_field(answer_text(answer), ANSWER_FIELD_BYTES)
}

// hostile_log writes the fact of a hostile case: its answer, or its wrong
// answer.
hostile_log :: proc "contextless" (item: ^Hostile, wrong: bool) {
	fields := errors.error_record_fact_fields(item.refusal)
	switch item.refusal_case {
	case .None:
		if wrong {
			system.log_fact(.Info, Hostile_Answer_Wrong{case_name = case_field(item.name), answer = answer_field(&item.answer)})
		} else {
			system.log_fact(.Info, Hostile_Answer{case_name = case_field(item.name), answer = answer_field(&item.answer)})
		}
	case .Memory_Object_To_Service:
		if wrong {
			system.log_fact(.Info, Memory_Object_To_Service_Wrong(fields))
		} else {
			system.log_fact(.Info, Memory_Object_To_Service_Refused(fields))
		}
	case .Budget_As_Table_Memory:
		if wrong {
			system.log_fact(.Info, Budget_As_Table_Memory_Wrong(fields))
		} else {
			system.log_fact(.Info, Budget_As_Table_Memory_Refused(fields))
		}
	case .Count_Past_Its_Bound:
		if wrong {
			system.log_fact(.Info, Count_Past_Its_Bound_Wrong(fields))
		} else {
			system.log_fact(.Info, Count_Past_Its_Bound_Refused(fields))
		}
	case .Start_That_Wraps:
		if wrong {
			system.log_fact(.Info, Start_That_Wraps_Wrong(fields))
		} else {
			system.log_fact(.Info, Start_That_Wraps_Refused(fields))
		}
	}
}

// The bytes of the Text field of the state of a way: "ready" or "refused".
WAY_STATE_FIELD_BYTES :: 8
// The bytes of the Text field of the name of a way of a measure: the
// longest, "call host, memory object", has 24 bytes.
MEASURE_WAY_FIELD_BYTES :: 32

// Each way of a call, ready or refused.
@(log_fact = "tables: the ways: direct {direct}, call host {call_host}, service {service}")
Ways_Ready :: struct {
	direct:    [8]u8,
	call_host: [8]u8,
	service:   [8]u8,
}

// The least time of one call of sum_values in one way, for 64, 1024 and
// 65536 rows. A time of 0 is a refused call.
@(log_fact = "tables: sum_values, {way}: {small_table} for 64 rows, {medium_table} for 1024 rows, {large_table} for 65536 rows (0: refused)")
Sum_Values_Measured :: struct {
	small_table:  value_kinds.Time_In_Nanoseconds,
	medium_table: value_kinds.Time_In_Nanoseconds,
	large_table:  value_kinds.Time_In_Nanoseconds,
	way:          [32]u8,
}

// Each case gave its answer in the three ways, and each hostile case its
// refusal.
@(log_fact = "tables: ok, {cases} cases in 3 ways and {hostile_cases} hostile cases")
Cases_Passed :: struct {
	cases:         u64,
	hostile_cases: u64,
}

#assert(size_of(Ways_Ready) == 3 * WAY_STATE_FIELD_BYTES)
#assert(size_of(Sum_Values_Measured) == 24 + MEASURE_WAY_FIELD_BYTES)

// way_state_field gives the Text field of the state of a way.
way_state_field :: proc "contextless" (ready: bool) -> [WAY_STATE_FIELD_BYTES]u8 {
	return value_kinds.text_field(ready ? "ready" : "refused", WAY_STATE_FIELD_BYTES)
}
