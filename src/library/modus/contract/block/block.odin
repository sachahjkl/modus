// The block contract: what a process and a block service agree on. A block
// service is the device service of one disk. The first one drives a virtio
// block device (src/modules/system/block); a driver of another device class (NVMe)
// serves the same contract.
//
// A disk is a row of blocks of BLOCK_SIZE bytes, numbered from 0. The client
// and the block service share two memory objects:
//
//   the block ring    a ring (package ring). One command record is one
//                     request: read, write or flush of blocks.
//   the data region   memory of the client. The device reads and writes the
//                     bytes of the blocks there, with no copy: a request
//                     names a place in the region, never an address.
//
// The client gives the data region to the block service with the command
// Attach: the handle goes through the memory of the block ring (the kernel
// operation Handle_Give). The block service proves that it came through the
// ring (Handle_State), as for a lent handle.
//
// Many requests are in flight at the same time: the device does them in any
// order, and a completion record has the tag of its command. The block
// service takes a command only when the completion queue has room for its
// completion: a client that does not read its completions stops the
// requests of its own ring, and nothing else. A client with a full command
// queue waits for room (back-pressure).
//
// A write is in the memory of the device when its completion arrives. It is
// on the disk after a Flush that the client sent after that completion. The
// order of two requests in flight is not fixed: a client that needs an order
// waits for the completion of the first one.
//
// This package allocates no memory and calls no kernel operation.
package block

import "modus:contract/call_outcome"
import "modus:contract/errors"

BLOCK_SIZE :: 4096 // The bytes of one block: the unit of each request.
RING_CAPACITY :: 256 // The capacity of the block ring.

// The role of the block ring in the context of a block service.
SERVICE_RING :: 0
// The role of the block ring in the context of a client of a block service.
GRANT_RING :: 6
// The role of the block service in the context of its client: the process,
// with the right Read. Its stop ends a wait of the client for a completion.
GRANT_SERVICE :: 10

// A command of a client, as the kind of a command record of the block ring.
Command :: enum u32 {
	None       = 0, // Not a command: Operation_Unsupported.
	// values[0]: the handle of the data region, as the block service names
	// it. A new Attach replaces the region of the one before: send it when
	// no request is in flight.
	Attach     = 1,
	// The completion: values[0] the count of blocks of the disk, values[1]
	// the most blocks of one request, values[2] 1 if the disk keeps writes in
	// a cache that Flush empties.
	Info       = 2,
	// values[0]: the first block. values[1]: the count of blocks.
	// values[2]: the place in the data region, in bytes: a multiple of
	// BLOCK_SIZE.
	Read       = 3,
	Write      = 4, // The values of Read: the blocks are written from the data region.
	// The writes that completed before this command are on the disk when
	// its completion arrives.
	Flush      = 5,
	// The completion: values[0] the requests done, values[1] the blocks read
	// and written, values[2] the kernel entries of the block service, values[3]
	// the interrupts that it received, all since it started.
	Statistics = 6,
}

// The kind of a completion record is the word of its call outcome
// (call_outcome.completion_outcome is its border). With Succeeded the
// values are the results of the request; with any other outcome they are
// an error record (errors.completion_record), whose kind keeps the detail:
//
//   Operation_Unsupported  Unsupported: the command is not known, or the
//                          device cannot do it.
//   Argument_Refused       Too_Small, Too_Long, Bad_Value: a count or a
//                          place that the command refuses. Out_Of_Range: a
//                          block is not on the disk, or a byte is not in
//                          the data region. Absent, unit Region: no data
//                          region. Refused: the handle of Attach did not
//                          come through the block ring.
//   Callee_Busy            Busy: an Attach with requests in flight.
//   Callee_Unavailable     Device or No_Answer: the device failed a request
//                          that changes nothing on the disk.
//   Stopped_After_A_Partial_Change  Device or No_Answer: the device failed
//                          a Write or a Flush, and some blocks can be on
//                          the disk (device_failure_outcome).

// The bound of a wait for the device, in milliseconds: the hang bound of a
// process (system.ANSWER_BOUND_MILLISECONDS, which the block service checks
// against it), never a measure of a disk. It is the limit of the record of
// a request that the device did not answer.
NO_ANSWER_BOUND_MILLISECONDS :: 60_000

// device_failure_outcome gives the outcome of a request that the device
// failed: a Write or a Flush can have put some blocks on the disk, so the
// caller learns that the disk changed in part; another request changed
// nothing.
device_failure_outcome :: proc "contextless" (command: Command) -> call_outcome.Call_Outcome {
	switch command {
	case .Write, .Flush:
		return .Stopped_After_A_Partial_Change
	case .None, .Attach, .Info, .Read, .Statistics:
		return .Callee_Unavailable
	}
	return .Callee_Unavailable
}

// no_answer_values gives the values of a completion of a
// request that the device did not answer by its deadline, or that it will
// never answer: the record No_Answer, with the device as what did not
// answer. The block service gives it to each request in flight when it
// stops, and the storage service reads it with device_did_not_answer.
no_answer_values :: proc "contextless" (command: Command) -> [7]u64 {
	return errors.ring_fail(u32(command), .No_Answer, .Milliseconds, 0, 0, NO_ANSWER_BOUND_MILLISECONDS, i64(errors.Unanswered.Device))
}

// device_did_not_answer is the border of a completion that says that the
// device did not answer: the outcome of a failed device
// (device_failure_outcome) and the record No_Answer with the device as what
// did not answer. The words come from the block service: each one goes
// through its border, and a word that names no member gives false. It
// reads and changes no state.
device_did_not_answer :: proc "contextless" (completion_kind: u32, values: [7]u64) -> bool {
	outcome, record := call_outcome.completion_outcome(completion_kind, values)
	if outcome != .Callee_Unavailable && outcome != .Stopped_After_A_Partial_Change {
		return false
	}
	kind, kind_known := errors.kind_of_word(record.kind)
	if !kind_known || kind != .No_Answer {
		return false
	}
	unanswered, unanswered_known := errors.unanswered_of_word(record.found)
	return unanswered_known && unanswered == .Device
}

// The names of the commands and of their values, for the sentence of the
// error record of a completion (errors.completion_record).
@(rodata)
COMMAND_NAMES := [Command]string {
	.None = "None",
	.Attach = "Attach",
	.Info = "Info",
	.Read = "Read",
	.Write = "Write",
	.Flush = "Flush",
	.Statistics = "Statistics",
}

// The names of the values of each command, from value 1. A command with
// no named value has none.
@(rodata)
ARGUMENT_NAMES := [Command][]string {
	.None       = {},
	.Attach     = {"region"},
	.Info       = {},
	.Read       = {"first", "count", "place"},
	.Write      = {"first", "count", "place"},
	.Flush      = {},
	.Statistics = {},
}

// command_of_ring_word is the border of the kind of a command record of the
// block ring: the command, or false for a word that names no command, None
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
