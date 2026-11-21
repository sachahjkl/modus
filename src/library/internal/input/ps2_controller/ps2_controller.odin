// The status port of the PS/2 controller, and the decision of each read of
// the drain at the start of the input service: a pure part, which the host
// tests (src/md/features/missing_hardware.md).
package ps2_controller

STATUS_OUTPUT_FULL :: 1 << 0 // A byte waits in the data port.
STATUS_INPUT_FULL :: 1 << 1 // The controller has not taken the last byte written to it.
STATUS_MOUSE :: 1 << 5 // The byte that waits comes from the mouse.
// A port with no device behind it reads all ones. No controller gives this
// status: each of its bits would be set at once, the parity error and the
// time-out with them. The i8042 driver of Linux finds an absent controller
// the same way.
STATUS_NO_CONTROLLER :: 0xFF
// The reads of the status port before a wait for the controller ends, and
// the bytes that the drain takes before it calls the controller absent: a
// bound on a device that does not answer, not a time. A controller holds 16
// bytes at most.
CONTROLLER_POLLS :: 100000

// What the drain does after one read of the status port.
Drain_Step :: enum {
	Done, // No byte waits: the controller is empty.
	Read_Byte, // A byte waits: read it from the data port and drop it.
	No_Controller, // The status names no controller, or the bytes do not end.
}

// drain_step decides one step of the drain from the status that the port
// gave and the count of the bytes that the drain read before it.
drain_step :: proc "contextless" (status: u8, bytes_read: u64) -> Drain_Step {
	if status == STATUS_NO_CONTROLLER || bytes_read >= CONTROLLER_POLLS {
		return .No_Controller
	}
	if status & STATUS_OUTPUT_FULL == 0 {
		return .Done
	}
	return .Read_Byte
}
