// The keys and the pastes on their way to the virtio console of the guest
// (src/md/features/linux_shell.md, "A paste"). The guest takes what the
// receive buffers that its driver posted hold; a paste of the terminal
// gives up to the limit of the clipboard at once. The bytes wait here, and
// go to the guest as it posts buffers, so no character of a paste is lost.
package linux_shell

import "modus:contract/guest_os"

// The bytes that wait for room in the guest: a whole paste, and the keys
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

// Input_Taker gives bytes to the guest and gives how many it took.
Input_Taker :: #type proc "contextless" (machine: ^guest_os.Linux_Machine, bytes: []u8) -> (taken: int)

// pending_feed gives the guest the bytes that wait, in order, as many as it
// takes, and gives how many went. The bytes past the end of the queue go
// in a second run.
pending_feed :: proc "contextless" (pending: ^Pending_Input, machine: ^guest_os.Linux_Machine, take: Input_Taker = guest_os.linux_machine_console_input) -> (moved: int) {
	for pending.count > 0 {
		run := min(pending.count, PENDING_INPUT_BYTES - pending.first)
		taken := clamp(take(machine, pending.bytes[pending.first:][:run]), 0, run)
		pending.first = (pending.first + taken) % PENDING_INPUT_BYTES
		pending.count -= taken
		moved += taken
		if taken < run {
			break
		}
	}
	return moved
}
