// The keys and the pastes on their way to the serial port of the guest
// (src/md/features/linux_shell.md, "The keys"). The receive queue of the
// port holds SERIAL_RECEIVE_BYTES; a paste of the terminal gives up to the
// limit of the clipboard at once. The bytes wait here, and go to the port
// as the guest makes room, so no character of a paste is lost.
package linux_shell

import "modus:contract/guest_os"

// The bytes that wait for room in the port: a whole paste, and the keys
// typed after it.
PENDING_INPUT_BYTES :: 8192

Pending_Input :: struct {
	bytes: [PENDING_INPUT_BYTES]u8, // A queue: count bytes from first, around the end.
	first: int,
	count: int,
}

// pending_room gives the bytes that the queue still takes.
pending_room :: proc "contextless" (pending: ^Pending_Input) -> int {
	return PENDING_INPUT_BYTES - pending.count
}

// pending_push takes the bytes of one key whole, or none of them: a key cut
// in two would send half of a character or of a sequence.
pending_push :: proc "contextless" (pending: ^Pending_Input, bytes: []u8) -> bool {
	if len(bytes) > pending_room(pending) {
		return false
	}
	for value in bytes {
		pending.bytes[(pending.first + pending.count) % PENDING_INPUT_BYTES] = value
		pending.count += 1
	}
	return true
}

// pending_feed gives the serial port of the guest the bytes that wait, as
// many as its receive queue has room for, in order, and gives how many went.
pending_feed :: proc "contextless" (pending: ^Pending_Input, machine: ^guest_os.Linux_Machine) -> (moved: int) {
	for pending.count > 0 {
		room := guest_os.linux_machine_serial_receive_room(machine)
		if room <= 0 {
			break
		}
		run := min(pending.count, room, PENDING_INPUT_BYTES - pending.first)
		taken := guest_os.linux_machine_serial_input(machine, pending.bytes[pending.first:][:run])
		pending.first = (pending.first + taken) % PENDING_INPUT_BYTES
		pending.count -= taken
		moved += taken
		if taken < run {
			break
		}
	}
	return moved
}
