package flow

// The log facts of the demonstration flow (src/md/features/log_facts.md,
// "The facts of the demonstrations"): each ring and the end, as records of
// fields. Each fact template is the sentence that the line wrote before it
// was a fact, so a wait of a machine test on that sentence reads it as
// before. A Text field comes last, and holds its longest text and a zero
// byte. The field `waiting` holds how the reader waits: "wait at once" or
// "read the counters then wait".

// A ring of a measure run: its rate in one second.
@(log_fact = "flow: capacity {capacity}, {waiting}: {records_in_one_second} records in one second, {kernel_entries} kernel entries for one million records, {lost_records} lost")
Ring_Measured :: struct {
	capacity:              u64,
	records_in_one_second: u64,
	kernel_entries:        u64,
	lost_records:          u64,
	waiting:               [32]u8,
}

// A ring of a check, outside a measure run.
@(log_fact = "flow: capacity {capacity}, {waiting}: {read_records} records read in order, {lost_records} lost, {kernel_entries} kernel entries for one million records")
Ring_Checked :: struct {
	capacity:       u64,
	read_records:   u64,
	lost_records:   u64,
	kernel_entries: u64,
	waiting:        [32]u8,
}

// A ring lost records.
@(log_fact = "flow: wrong: {lost_records} records lost")
Flow_Wrong :: struct {
	lost_records: u64,
}

// Each ring lost no record.
@(log_fact = "flow: ok, {rings} rings, 0 records lost")
Flow_Held :: struct {
	rings: u64,
}
