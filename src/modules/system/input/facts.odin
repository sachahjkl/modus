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

// The facts below have no value: their sentence is their template. The
// mouse with and without a wheel are two sentences, so two fact types.

// The ring of the input does not open.
@(log_fact = "input: no ring")
No_Ring :: struct {}

// The machine has no PS/2 controller.
@(log_fact = "input: no PS/2 controller: no keyboard and no mouse")
No_Controller :: struct {}

// No PS/2 controller, and the virtio tablet is ready: the service goes on
// with the pointer of the tablet only.
@(log_fact = "input: no PS/2 controller: no keyboard; the pointer is the virtio tablet")
No_Controller_Tablet_Only :: struct {}

// The service is ready, and the mouse has no wheel.
@(log_fact = "input: ok, the mouse has no wheel")
Ready_Mouse_Without_Wheel :: struct {}

// The service is ready, and the mouse has a wheel.
@(log_fact = "input: ok, the mouse has a wheel")
Ready_Mouse_With_Wheel :: struct {}

// The input ring is full: the controller keeps its bytes.
@(log_fact = "input: the input ring is full: the keyboard controller keeps its bytes")
Input_Ring_Full :: struct {}

// The input ring has room again.
@(log_fact = "input: the input ring has room again")
Input_Ring_Room_Again :: struct {}

// The virtio tablet device is ready alongside the PS/2 fallback.
@(log_fact = "input: virtio tablet ready, a queue of {queue_size}")
Tablet_Ready :: struct {
	queue_size: u64,
}
