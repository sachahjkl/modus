package crowd

// The log facts of the demonstration crowd (src/md/features/log_facts.md,
// "The facts of the demonstrations"): each run of the queue and the end, as
// records of fields. Each fact template is the sentence that the line wrote
// before it was a fact, so a wait of a machine test on that sentence reads
// it as before. A Text field comes last, and holds its longest text and a
// zero byte. The field `queue` holds the kind of the queue: "shared queue"
// or "queue with a lock".

// A run of a measure run: its rate in one second.
@(log_fact = "crowd: {queue}, {writers} writers, {readers} readers: {records_in_one_second} records in one second, {kernel_entries} kernel entries for one million records, {written_records} written, {read_records} read, {wrong_records} wrong")
Run_Measured :: struct {
	writers:               u64,
	readers:               u64,
	records_in_one_second: u64,
	kernel_entries:        u64,
	written_records:       u64,
	read_records:          u64,
	wrong_records:         u64,
	queue:                 [24]u8,
}

// A run of a check, outside a measure run.
@(log_fact = "crowd: {queue}, {writers} writers, {readers} readers: {written_records} written, {read_records} read, {wrong_records} wrong, {kernel_entries} kernel entries for one million records")
Run_Checked :: struct {
	writers:         u64,
	readers:         u64,
	written_records: u64,
	read_records:    u64,
	wrong_records:   u64,
	kernel_entries:  u64,
	queue:           [24]u8,
}

// A run lost a record, read one in disorder or read one two times.
@(log_fact = "crowd: wrong: {wrong_records} records lost, in disorder or read two times")
Crowd_Wrong :: struct {
	wrong_records: u64,
}

// Each run read each record one time.
@(log_fact = "crowd: ok, {runs} runs, each record written is read one time, each event started all the threads")
Crowd_Held :: struct {
	runs: u64,
}
