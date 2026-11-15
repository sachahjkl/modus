package root

// The connection through which the debugger service reads the debug object
// of a disk program
// (docs/MODULE_CONTRACT.md, "The debug object of a disk program").
// The debug object is an object of the store `programs`, beside
// the module file, named by the hash of the module. The debugger service
// holds no store: this service gives it a connection that reads only, to
// the store `programs` of the principal of the program, as a part of the
// debug access to that program for one caller. The connection ends with
// the debug access (debug_end).

import "modus:contract/errors"
import "modus:support/disk_program"
import "modus:support/system"

// The caller record of that connection. This service is no row of its own
// table of started programs, so the connection has this record as its
// caller, as the read of a module file has disk_reader: its name is the
// name of the store, and grant_for gives it the limit of that store, the
// flag that it reads only, and no grant to act for a principal.
debug_store_reader: Started

// The one connection of the debugger service to the store. The service
// debugs one program at a time, so one connection is enough: a new one
// ends the one before.
Debug_Store :: struct {
	connection: ^Connection, // nil: none.
	target:     ^Started, // The disk program whose debug access the connection is a part of.
}

debug_store: Debug_Store

// debug_store_open runs the command Debug_Store of the debugger service
// `holder`: a connection that reads only to the store `programs` of the
// principal of the disk program with a name, for the debugging of that
// program for the caller of the connection with the call ring
// `connection_ring`. values is the completion: the storage service, the
// call ring and the call region, each a handle of the debugger service; a
// refusal writes its error record there. With `end`, the service read the
// object: the connection ends now, so it holds no connection place of the
// storage service for the rest of the debugging.
//
// Bad_Handle: the ring names no connection of the service. Bad_State: this
// service did not give the service the debug access to a program with
// that name for that caller, or the program is not a disk program: the
// debug image holds the debug object of a module of the boot image.
debug_store_open :: proc "contextless" (holder: ^Started, name: string, connection_ring: u64, end: bool, values: ^[7]u64) -> system.Status {
	kind := u32(system.Root_Command.Debug_Store)
	caller: ^Started
	for &connection in connections {
		if connection.caller != nil && connection.service == holder && !connection.history && u64(connection.ring) == connection_ring {
			caller = connection.caller
		}
	}
	if caller == nil {
		values^ = errors.ring_fail(kind, .Absent, .Connections, 2)
		return .Bad_Handle
	}
	// The connection is a part of a debug access that this service gave:
	// the rule of that access was applied to this caller (debug). The
	// program is found by that access and by its name, never by its name
	// alone: two principals can run disk programs of one nickname.
	target: ^Started
	for &item in started {
		if item.program != 0 && item.debugger == holder && item.debug_for == caller && system.name_of(item.name[:]) == name {
			target = &item
		}
	}
	if target == nil {
		values^ = errors.ring_fail(kind, .Absent, .Debugged_Programs, 1)
		return .Bad_State
	}
	if end {
		debug_store_end(target)
		return .Ok
	}
	if !target.from_disk {
		values^ = errors.ring_fail(kind, .Absent, .Debug_Objects, 1)
		return .Bad_State
	}
	if debug_store.connection != nil {
		disconnect(debug_store.connection)
	}
	debug_store = {}
	// The store `programs` of the principal of the program: the debug
	// access needs the caller to act for that principal, so it is the
	// principal of the caller too.
	debug_store_reader = {}
	copy(debug_store_reader.name[:len(debug_store_reader.name) - 1], disk_program.STORE_NAME)
	debug_store_reader.principal = target.principal
	connection, service, ring_memory, region_memory, status := connection_open(&debug_store_reader, "storage")
	if status != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		return status
	}
	// The debugger service receives the handles through its ring to this
	// service; this service keeps none of the memory.
	defer system.close(ring_memory)
	defer system.close(region_memory)
	given: [3]system.Handle
	given[0], status = system.give(holder.requests_memory, service.program, {.Read})
	if status == .Ok {
		given[1], status = system.give(holder.requests_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		given[2], status = system.give(holder.requests_memory, region_memory, {.Read, .Write})
	}
	if status != .Ok {
		disconnect(connection)
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		return status
	}
	debug_store = {connection = connection, target = target}
	values^ = {u64(given[0]), u64(given[1]), u64(given[2]), 0, 0, 0, 0}
	system.log_in("programs", .Info, "root: gave ", system.Module_Name{system.name_of(holder.name[:])}, " a connection that reads only to the store ", disk_program.STORE_NAME, " of principal ", target.principal, ", for the debug object of ", system.Module_Name{name})
	return .Ok
}

// debug_store_end ends the connection of the debug object of a program:
// when the debugger service read the object, and in any case when the
// debug access to that program ends. The storage service then answers no
// call of it.
debug_store_end :: proc "contextless" (target: ^Started) {
	if debug_store.connection == nil || debug_store.target != target {
		return
	}
	// disconnect forgets the connection here.
	disconnect(debug_store.connection)
	debug_store = {}
}
