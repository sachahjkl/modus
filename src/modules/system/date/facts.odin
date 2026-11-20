package date_service

import "modus:contract/settings"
import "modus:contract/value_kinds"

// The log facts of the date service (src/md/features/log_facts.md): the
// time zone that it writes in the date page, the first date of the
// real-time clock and each read of the clock after it, as records of
// fields. Each fact template is the sentence that the line wrote before it
// was a fact, so a wait of a machine test on that sentence reads it as
// before. A line whose sentence differs by its case is one fact type for
// each case: the template has no condition. No field has the name of a
// column of the head of facts(): number, time, process, level.
//
// A time zone and a date in the form of ISO 8601 are Text fields, and the
// last fields. A Text field is [N]u8 with N written out, as the tool reads
// it.

// The bytes of the Text field of a time zone: "+08:00", 6 bytes, and a
// zero byte, on 8 bytes.
ZONE_FIELD_BYTES :: 8
// The bytes of the Text field of a date in the form of ISO 8601: the
// buffer of the writer has 32 bytes, so at most 31, and a zero byte.
DATE_FIELD_BYTES :: 32

// The template names the setting by its words: the name of the setting is
// a constant of the contract, not a value of the line.
#assert(settings.TIME_ZONE_NAME == "time_zone")
#assert(settings.ZONE_TEXT_SIZE < ZONE_FIELD_BYTES)

// The time zone of the date page changed, from the setting.
@(log_fact = "date: the time zone of the date page is {time_zone}, from the setting time_zone")
Time_Zone_Written :: struct {
	time_zone: [8]u8,
}

// The first date that the real-time clock gave.
@(log_fact = "date: ok, {utc_date} UTC, seconds since 1970 {seconds}, from the real-time clock at the time {clock_edge} of the system; the date of the time 0 in {start_time}")
Date_Read :: struct {
	seconds:    i64,
	clock_edge: value_kinds.Time_In_Milliseconds,
	start_time: value_kinds.Time_In_Microseconds,
	utc_date:   [32]u8,
}

// The first read of the clock after the first date: the drift of the time
// of the system against the clock.
@(log_fact = "date: the clock read again at the time {clock_edge} of the system: the date moved by {moved}; {since_start} since the start, {reads} read after the first")
Clock_Read_Again_Once :: struct {
	clock_edge:  value_kinds.Time_In_Milliseconds,
	moved:       value_kinds.Time_In_Milliseconds,
	since_start: value_kinds.Time_In_Milliseconds,
	reads:       u64,
}

// A later read of the clock: the drift of the time of the system against
// the clock.
@(log_fact = "date: the clock read again at the time {clock_edge} of the system: the date moved by {moved}; {since_start} since the start, {reads} reads after the first")
Clock_Read_Again :: struct {
	clock_edge:  value_kinds.Time_In_Milliseconds,
	moved:       value_kinds.Time_In_Milliseconds,
	since_start: value_kinds.Time_In_Milliseconds,
	reads:       u64,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Time_Zone_Written) == ZONE_FIELD_BYTES)
#assert(size_of(Date_Read) == 24 + DATE_FIELD_BYTES)
