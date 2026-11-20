package input

// The log facts of the input service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the bytes and the
// records that the service lost, as records of fields. Each fact template
// is the sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. No field has the name
// of a column of the head of facts(): number, time, process, level.

// Bytes of the keyboard came while the service started the mouse, and are
// lost.
@(log_fact = "input: {keyboard_bytes} bytes of the keyboard came during the start of the mouse and are lost")
Keyboard_Bytes_Lost_At_Start :: struct {
	keyboard_bytes: u64,
}

// The input ring refused a key record that had a place: the count of the
// key records lost since the start.
@(log_fact = "input: the input ring refused a key record that had a place: {key_records} key records are lost")
Key_Records_Lost :: struct {
	key_records: u64,
}

// No entry of the backlog took a change of a button of the pointer: the
// count of the pointer records lost since the start.
@(log_fact = "input: no entry for a change of a button of the pointer: {pointer_records} pointer records are lost")
Pointer_Records_Lost :: struct {
	pointer_records: u64,
}
