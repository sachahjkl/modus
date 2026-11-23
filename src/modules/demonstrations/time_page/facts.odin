package time_page

import "modus:contract/value_kinds"

// The log facts of the demonstration time_page (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its checks of the time page and its
// measures, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence, and the measure record that reads it, read it as before. A
// Text field comes last, and holds its longest text and a zero byte.

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "time_page: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}

// The measure of a read of the time from the time page, in a measure run.
@(log_fact = "time_page: the time page: {reads_in_one_second} reads in one second, {kernel_entries} kernel entries for one million reads")
Time_Page_Measured :: struct {
	reads_in_one_second: u64,
	kernel_entries:      u64,
}

// The measure of a read of the time through a kernel entry, in a measure
// run.
@(log_fact = "time_page: a kernel entry: {reads_in_one_second} reads in one second, {kernel_entries} kernel entries for one million reads")
Kernel_Entry_Measured :: struct {
	reads_in_one_second: u64,
	kernel_entries:      u64,
}

// The check of the reads of the time page, outside a measure run.
@(log_fact = "time_page: the check of the time page: {reads} reads, {kernel_entries} kernel entries")
Time_Page_Checked :: struct {
	reads:          u64,
	kernel_entries: u64,
}

// The check of the reads of the time through a kernel entry, outside a
// measure run.
@(log_fact = "time_page: the check of a kernel entry: {reads} reads, {kernel_entries} kernel entries")
Kernel_Entry_Checked :: struct {
	reads:          u64,
	kernel_entries: u64,
}

// The time of a kernel entry between two reads of the time page.
@(log_fact = "time_page: the time page and a kernel entry: in 1000 pairs of reads of the page with an entry between them, the entry was outside the two reads {outside} times; the two reads were at most {apart_most} ms apart (a measure)")
Page_And_Kernel_Entry :: struct {
	outside:    u64,
	apart_most: u64,
}

// Each check of the time held.
@(log_fact = "time_page: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page")
Clock_Held :: struct {}

// A check of the time did not hold.
@(log_fact = "time_page: wrong: the time went back {went_back} times, a kernel entry was outside two reads of the page {outside} times, the page changed {page_changes} times and is at least {least_behind} ms behind and {most_ahead} ms ahead of the cycle counter, the kernel {removal} to remove the time page")
Time_Wrong :: struct {
	went_back:    u64,
	outside:      u64,
	page_changes: u64,
	least_behind: u64,
	most_ahead:   u64,
	removal:      [24]u8,
}

// The mean time of one picture of the window, over 10 pictures.
@(log_fact = "time_page: the window drew one picture in {picture_time}, the mean of 10")
Picture_Measured :: struct {
	picture_time: value_kinds.Nanoseconds_As_Microseconds,
}

// One frame of the interface where one number changed: its records, its
// damage, and the time of each part.
@(log_fact = "time_page: the interface: {records} records, {damage_rectangles} damage rectangles; build {build_time}, difference {difference_time}, draw {draw_time}")
Interface_Measured :: struct {
	records:           u64,
	damage_rectangles: u64,
	build_time:        value_kinds.Nanoseconds_As_Microseconds,
	difference_time:   value_kinds.Nanoseconds_As_Microseconds,
	draw_time:         value_kinds.Nanoseconds_As_Microseconds,
}

// The time page against the cycle counter.
@(log_fact = "time_page: the time page and the cycle counter: in {compared} reads the page was {least_behind} to {most_behind} ms behind and at most {most_ahead} ms ahead")
Page_And_Cycle_Counter :: struct {
	compared:     u64,
	least_behind: u64,
	most_behind:  u64,
	most_ahead:   u64,
}
