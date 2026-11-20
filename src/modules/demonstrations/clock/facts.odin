package clock

// The log facts of the demonstration clock (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its checks of the time page and its
// measures, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence, and the measure record that reads it, read it as before. A
// Text field comes last, and holds its longest text and a zero byte.

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "clock: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}

// The measure of a read of the time from the time page, in a measure run.
@(log_fact = "clock: the time page: {reads_in_one_second} reads in one second, {kernel_entries} kernel entries for one million reads")
Time_Page_Measured :: struct {
	reads_in_one_second: u64,
	kernel_entries:      u64,
}

// The measure of a read of the time through a kernel entry, in a measure
// run.
@(log_fact = "clock: a kernel entry: {reads_in_one_second} reads in one second, {kernel_entries} kernel entries for one million reads")
Kernel_Entry_Measured :: struct {
	reads_in_one_second: u64,
	kernel_entries:      u64,
}

// The check of the reads of the time page, outside a measure run.
@(log_fact = "clock: the check of the time page: {reads} reads, {kernel_entries} kernel entries")
Time_Page_Checked :: struct {
	reads:          u64,
	kernel_entries: u64,
}

// The check of the reads of the time through a kernel entry, outside a
// measure run.
@(log_fact = "clock: the check of a kernel entry: {reads} reads, {kernel_entries} kernel entries")
Kernel_Entry_Checked :: struct {
	reads:          u64,
	kernel_entries: u64,
}

// The time of a kernel entry between two reads of the time page.
@(log_fact = "clock: the time page and a kernel entry: in 1000 pairs of reads of the page with an entry between them, the entry was outside the two reads {outside} times; the two reads were at most {apart_most} ms apart (a measure)")
Page_And_Kernel_Entry :: struct {
	outside:    u64,
	apart_most: u64,
}

// The time page against the cycle counter.
@(log_fact = "clock: the time page and the cycle counter: in {compared} reads the page was {least_behind} to {most_behind} ms behind and at most {most_ahead} ms ahead")
Page_And_Cycle_Counter :: struct {
	compared:     u64,
	least_behind: u64,
	most_behind:  u64,
	most_ahead:   u64,
}
