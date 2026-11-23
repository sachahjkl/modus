// The frame contract: what a process and a frame service agree on. A frame
// service is the device service of one network device. The first one drives
// a virtio network device (src/modules/system/frame); a driver of another device class
// serves the same contract.
//
// A frame is one Ethernet frame, from the destination address to the end of
// the data, with no check sequence: FRAME_LIMIT bytes at most. The client and
// the frame service share two memory objects:
//
//   the frame ring     a ring (package ring). One command record is one
//                      request: send a frame, or give a place for a frame
//                      that the device receives.
//   the frame region   memory of the client. The device reads and writes the
//                      bytes of the frames there, with no copy: a request
//                      names a place in the region, never an address.
//
// The client gives the frame region to the frame service with the command
// Attach: the handle goes through the memory of the frame ring (the kernel
// operation Handle_Give). The frame service proves that it came through the
// ring (Handle_State), as for a lent handle. The region is contiguous: the
// device uses one physical address for each place.
//
// A frame to send can have a second part: bytes of a read region. A read
// region is a contiguous memory object that the client gives with the
// right Read only (Read_Region_Add), at one of READ_REGION_CAPACITY places;
// the device reads it and never writes it. The network service gives the
// datagram region of each endpoint as a read region, so the device reads
// the data of a datagram where the process wrote it, and the network
// service writes only the headers in its frame region
// (src/md/infrastructure/network_data_path.md). The frame service keeps
// its handle of a read region until the last Send that reads it is
// complete: the memory object, and its declaration to the device, outlive
// the client's own handle while the device reads it.
//
// Many requests are in flight at the same time. A Receive stays in flight
// until a frame arrives in its place: the client gives the places for the
// frames before they arrive (the client supplies the memory: the service
// allocates none for it), and the device drops a frame when
// no place waits. A completion record has the tag of its command. The frame
// service takes a command only when the completion queue has room for its
// completion: a client that does not read its completions stops the
// requests of its own ring, and nothing else. A client with a full command
// queue waits for room (back-pressure).
//
// The frame service does not read the frames: it checks no address and
// computes no check. The client builds and checks each frame.
//
// This package allocates no memory and calls no kernel operation.
package frame

FRAME_LIMIT :: 1514 // An Ethernet frame with 1500 bytes of data, with no check sequence.
FRAME_LEAST :: 60 // The device adds zero bytes to a shorter frame that it sends.
PLACE_SIZE :: 2048 // A Receive with less room than FRAME_LIMIT can lose a frame.
RING_CAPACITY :: 256 // The capacity of the frame ring.
READ_REGION_CAPACITY :: 96 // The places of read regions of one client: one for each endpoint of the network service.

// The role of the frame ring in the context of a frame service.
SERVICE_RING :: 0
// The role of the frame ring in the context of a client of a frame service.
GRANT_RING :: 6
// The role of the frame service in the context of its client: the process,
// with the right Read. Its stop ends a wait of the client for a completion.
GRANT_SERVICE :: 10

// A command of a client, as the kind of a command record of the frame ring.
Command :: enum u32 {
	None       = 0, // Not a command: Operation_Unsupported.
	// values[0]: the handle of the frame region, as the frame service names
	// it. A new Attach replaces the region of the one before: send it when no
	// request is in flight.
	Attach     = 1,
	// The completion: values[0] the hardware address of the device (6 bytes,
	// the first byte in the low bits), values[1] 1 if the link is up,
	// values[2] the most bytes of a frame, values[3] the most Receive in
	// flight, values[4] the most Send in flight.
	Info       = 2,
	// values[0]: the place of the frame in the frame region, in bytes.
	// values[1]: its count of bytes there, 14 at least. values[2], values[3]:
	// the offset and the count of bytes of the second part of the frame, in
	// the read region at the place values[4]; a count of 0 is a frame with
	// one part, and values[2] and values[4] are not read. The two counts
	// together are FRAME_LIMIT at most. The completion comes when the device
	// read the frame: the client can then write both parts again.
	Send       = 3,
	// values[0]: the place in the frame region, in bytes. values[1]: the room
	// there, in bytes. The completion comes when a frame arrives: values[0]
	// is its count of bytes.
	Receive    = 4,
	// The completion: values[0] the frames sent, values[1] the frames
	// received, values[2] the kernel entries of the frame service, values[3]
	// the interrupts that it received, values[4] the bytes sent, values[5]
	// the bytes received, all since it started.
	Statistics = 5,
	// values[0]: the handle of a read region, as the frame service names it:
	// a contiguous memory object with Read and without Write, given through
	// the frame ring. values[1]: its place, under READ_REGION_CAPACITY. A
	// place whose Read_Region_Remove still waits for its sends makes the
	// command wait for them; a place that holds a region gives Argument_Refused.
	Read_Region_Add    = 6,
	// values[0]: the place of a read region. The completion comes when no
	// Send that reads the region is in flight: the frame service has then
	// closed its handle, and the device no longer reaches the region.
	Read_Region_Remove = 7,
}

// The kind of a completion record is the word of its call outcome
// (call_outcome.completion_outcome is its border). With Succeeded the
// values are the results of the request; with any other outcome they are
// an error record (errors.completion_record), whose kind keeps the detail:
// Out_Of_Range for a byte outside the frame region or the read region,
// Absent for a place with no region, Device for an error of the device.

// hardware gives the 6 bytes of a hardware address in values[0] of Info.
hardware :: proc "contextless" (value: u64) -> (address: [6]u8) {
	for &byte, index in address {
		byte = u8(value >> (8 * uint(index)))
	}
	return address
}

// The names of the commands and of their values, for the sentence of the
// error record of a completion (errors.completion_record).
@(rodata)
COMMAND_NAMES := [Command]string {
	.None = "None",
	.Attach = "Attach",
	.Info = "Info",
	.Send = "Send",
	.Receive = "Receive",
	.Statistics = "Statistics",
	.Read_Region_Add = "Read_Region_Add",
	.Read_Region_Remove = "Read_Region_Remove",
}

// The names of the values of each command, from value 1. A command with
// no named value has none.
@(rodata)
ARGUMENT_NAMES := [Command][]string {
	.None               = {},
	.Attach             = {"region"},
	.Info               = {},
	.Send               = {"place", "count", "data offset", "data count", "read region"},
	.Receive            = {"place", "room"},
	.Statistics         = {},
	.Read_Region_Add    = {"region", "place"},
	.Read_Region_Remove = {"place"},
}

// command_of_ring_word is the border of the kind of a command record of the
// frame ring: the command, or false for a word that names no command, None
// included. The service answers a refusal with Operation_Unsupported and
// the record Unsupported. It reads and changes no state.
command_of_ring_word :: proc "contextless" (word: u32) -> (command: Command, ok: bool) {
	for member in Command {
		if u32(member) == word && member != .None {
			return member, true
		}
	}
	return .None, false
}

// command_of_word is the border of the command word of a record or of an
// error record: the member, or false for a word that names none.
command_of_word :: proc "contextless" (word: i64) -> (command: Command, ok: bool) {
	for member in Command {
		if i64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// command_name gives the name of a command from an error record, or "an
// unknown command" for a number out of `Command`.
command_name :: proc "contextless" (command: i64) -> string {
	member, ok := command_of_word(command)
	return ok ? COMMAND_NAMES[member] : "an unknown command"
}

// argument_name gives the name of a value of a command, from 1, or "" for
// a command or a value that has no name.
argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	member, ok := command_of_word(command)
	if !ok {
		return ""
	}
	names := ARGUMENT_NAMES[member]
	return argument >= 1 && argument <= i64(len(names)) ? names[argument - 1] : ""
}
