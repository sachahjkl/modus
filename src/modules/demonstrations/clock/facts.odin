package clock

import "modus:contract/errors"

// The log facts of the clock application (src/md/features/log_facts.md).
// A Text field comes last, and holds its longest text and a zero byte.

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "clock: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}

// The first frame is on the screen: a machine test waits for it before it
// presses a section.
@(log_fact = "clock: ok, the first frame is drawn")
First_Frame_Drawn :: struct {}

// The machine has no date page, or the page has no date: the window says
// so in place of a time.
@(log_fact = "clock: the system has no date: the window shows no time of day")
No_Date :: struct {}

// The stopwatch started, by its button or by the key Space.
@(log_fact = "clock: the stopwatch started")
Stopwatch_Started :: struct {}

// The stopwatch stopped: its elapsed time, a measure that no test bounds.
@(log_fact = "clock: the stopwatch stopped at {elapsed_milliseconds} ms")
Stopwatch_Stopped :: struct {
	elapsed_milliseconds: u64,
}

// The countdown timer reached 0.
@(log_fact = "clock: the timer of {duration_seconds} s ended")
Timer_Ended :: struct {
	duration_seconds: u64,
}

// The compositor took the notification of the end of the timer.
@(log_fact = "clock: the notification {identifier} of the end of the timer is on the desktop")
Notification_Posted :: struct {
	identifier: u64,
}

// The root service gave no connection to the compositor, or the boot image
// has no export notify: the window alone shows the end.
@(log_fact = "clock: no notification of the end of the timer: {cause}")
Notification_Not_Connected :: struct {
	cause: [80]u8,
}

// The compositor refused the call notify: the window alone shows the end.
@(log_fact = "clock: the compositor refused the notification of the end of the timer: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Notification_Refused :: distinct errors.Error_Record_Fact_Fields
