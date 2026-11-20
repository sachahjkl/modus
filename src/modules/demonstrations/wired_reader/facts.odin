package wired_reader

// The log facts of the reader of the demonstration pair
// (src/md/features/log_facts.md).

// No writer came within the hang bound: the start policy did not start
// wired_writer, or the root service refused its wiring row.
@(log_fact = "wired_reader: no writer came within {milliseconds} ms: the start list did not start wired_writer with its wiring row")
No_Writer_Came :: struct {
	milliseconds: u64,
}
