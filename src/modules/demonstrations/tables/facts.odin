package tables

import "modus:contract/value_kinds"

// The log facts of tables (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// Lines stay text: the lines that write a status of the kernel as its
// number, which a field of a status writes by its name; the answers of the
// cases, sentences of an error record of up to 240 bytes, which pass the
// values of one fact; and the line with no value.

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
