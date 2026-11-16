// The contract of the entropy service: what the program `entropy` and its
// one client, the root service, agree on (src/md/features/entropy_device.md).
//
// The entropy service is the device service of the entropy device of the
// machine (virtio-rng). It reads bytes from the device; the root service
// mixes them into its random generator, as one more source beside the
// processor, never as the only one.
//
// The client and the service share one memory object, which the root
// service makes:
//
//   the entropy ring   a ring (package ring). One command record is one
//                      read of the device. Its completion carries the
//                      bytes in its values, so the ring needs no region.
//
// The service answers the commands in order, one at a time.
//
// This package allocates no memory and calls no kernel operation.
//
// See [entropy service](term:entropy-service).
package entropy_service

import "modus:contract/ring"

// The role of the entropy ring in the context of the entropy service.
SERVICE_RING :: 0
// The capacity of the entropy ring: the smallest ring.
RING_CAPACITY :: ring.CAPACITY

// The most bytes of one read: the six values of a completion after the
// count, 8 bytes each.
READ_BYTES_LIMIT :: 6 * 8

// A command of the client, as the kind of a command record.
Command :: enum u32 {
	None = 0, // Not a command: Bad_Command.
	// values[0]: the bytes asked, 1 to READ_BYTES_LIMIT. The completion:
	// values[0] the bytes that the device gave, at most the bytes asked
	// (0 when it gave none); values[1] to values[6] the bytes in order, 8
	// in each value, the first byte in the low bits (bytes_pack).
	Read = 1,
}

// The status of a command: the kind of its completion record. When it is
// not Ok, the values of the completion are an error record
// (errors.completion_record).
Status :: enum u32 {
	Ok           = 0, // The values are the bytes of the read.
	Bad_Command  = 1, // The command is not known, or its count is 0 or above READ_BYTES_LIMIT.
	Device_Error = 2, // The device needs a reset: it makes no more reads.
}

// bytes_pack gives the values of a completion of Read: the count, then the
// bytes. It takes READ_BYTES_LIMIT bytes at most.
bytes_pack :: proc "contextless" (bytes: []u8) -> (values: [7]u64) {
	count := min(len(bytes), READ_BYTES_LIMIT)
	values[0] = u64(count)
	for index in 0 ..< count {
		values[1 + index / 8] |= u64(bytes[index]) << (8 * uint(index % 8))
	}
	return
}

// bytes_unpack writes the bytes of the values of a completion of Read, and
// gives their count. The count comes from the service: a count above
// READ_BYTES_LIMIT gives READ_BYTES_LIMIT bytes.
bytes_unpack :: proc "contextless" (values: [7]u64, bytes: ^[READ_BYTES_LIMIT]u8) -> (count: int) {
	count = int(min(values[0], READ_BYTES_LIMIT))
	for index in 0 ..< count {
		bytes[index] = u8(values[1 + index / 8] >> (8 * uint(index % 8)))
	}
	return
}

// The names of the commands and of their values, for the sentence of the
// error record of a completion (errors.completion_record).
@(rodata)
COMMAND_NAMES := [Command]string {
	.None = "None",
	.Read = "Read",
}

// command_name gives the name of a command from an error record, or "an
// unknown command" for a number out of `Command`.
command_name :: proc "contextless" (command: i64) -> string {
	return command >= 0 && command <= i64(max(Command)) ? COMMAND_NAMES[Command(command)] : "an unknown command"
}

// argument_name gives the name of a value of a command, from 1.
argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	if Command(command) == .Read && argument == 1 {
		return "count"
	}
	return ""
}
