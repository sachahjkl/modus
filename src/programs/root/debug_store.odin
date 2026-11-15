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
//
// The same connection serves the stop report of a disk program that
// stopped on a fault. This service holds the only handle of a disk program
// and closes it at the reap, so the kernel forgets the report then: this
// service keeps a copy (stop_report_keep), and gives it with the
// connection to a caller that acts for the principal of the program, with
// no debug access (src/md/features/debug_object_of_a_disk_program.md).

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
// debugs one program at a time, and reads one object at a time, so one
// connection is enough: a new one ends the one before.
Debug_Store :: struct {
	connection: ^Connection, // nil: none.
	target:     ^Started, // The disk program whose debug access the connection is a part of. nil for a kept stop report.
	// A connection for a kept stop report: the caller of the debugger
	// service that asked for it, and that service. nil for a debug access.
	report_for: ^Started,
	holder:     ^Started,
}

debug_store: Debug_Store

// The stop reports of the disk programs that stopped on a fault.
kept_stop_reports: disk_program.Kept_Stop_Reports

// The page that carries a kept stop report to the debugger service.
#assert(size_of(disk_program.Kept_Stop_Report) <= system.PAGE_SIZE)

// stop_report_keep keeps the stop report of a disk program that stopped,
// before the reap closes its handle. A stop with no fault has no report:
// it removes the report of an older fault of that nickname, so that a
// kept report always tells how the last run of the nickname ended. The
// values that can be words of the memory of the program are taken out
// first: a reader of the kept report holds no debug access.
stop_report_keep :: proc "contextless" (item: ^Started) {
	if !item.from_disk || item.program == 0 {
		return
	}
	report := system.program_stop_report(item.program)
	name := system.name_of(item.name[:])
	if report.code == 0 {
		disk_program.kept_stop_report_forget(&kept_stop_reports, item.principal, name)
		return
	}
	disk_program.stop_report_hide(&report)
	if disk_program.kept_stop_report_keep(&kept_stop_reports, item.principal, name, item.hash, &report) {
		system.log_in("programs", .Info, "root: kept the stop report of ", system.Module_Name{name}, ", a disk program of principal ", item.principal, ": stop_report(\"", system.Module_Name{name}, "\") names its frames")
	}
}

// debug_store_open runs the command Debug_Store of the debugger service
// `holder`: a connection that reads only to the store `programs` of the
// principal of the disk program with a name, for the caller of the
// connection with the call ring `connection_ring`. values is the
// completion: the storage service, the call ring and the call region, each
// a handle of the debugger service; a refusal writes its error record
// there. With `end`, the service read the object: the connection ends now,
// so it holds no connection place of the storage service for the rest of
// the debugging.
//
// Without `kept`, the connection is for the debugging of that program for
// that caller. With `kept`, it is for the stop report that this service
// kept of the disk program of the principal of the caller with that
// nickname: the completion adds the page of the report and the principal.
//
// Bad_Handle: the ring names no connection of the service. Bad_State: this
// service did not give the service the debug access to a program with
// that name for that caller, or the program is not a disk program: the
// debug image holds the debug object of a module of the boot image.
debug_store_open :: proc "contextless" (holder: ^Started, name: string, connection_ring: u64, end: bool, kept: bool, values: ^[7]u64) -> system.Status {
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
	if kept {
		return debug_store_open_for_report(holder, caller, name, end, values)
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
	given: [3]system.Handle
	status := debug_store_connection_give(holder, target.principal, &given)
	if status != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		return status
	}
	debug_store.target = target
	values^ = {u64(given[0]), u64(given[1]), u64(given[2]), 0, 0, 0, 0}
	system.log_in("programs", .Info, "root: gave ", system.Module_Name{system.name_of(holder.name[:])}, " a connection that reads only to the store ", disk_program.STORE_NAME, " of principal ", target.principal, ", for the debug object of ", system.Module_Name{name})
	return .Ok
}

// debug_store_open_for_report gives the debugger service the kept stop
// report of the disk program of the principal of `caller` with a nickname,
// and the connection to read the debug object of its module. The rule is
// the rule of the report, not of the debug access: the report holds no
// byte of the memory of the program, and the caller, which acts for that
// principal, can read the store `programs` anyway.
//
// Bad_Operation: the caller does not act for its principal. No_Right: the
// grant `debug` of the caller was revoked. Bad_State: no kept report has
// that nickname for that principal.
@(private = "file")
debug_store_open_for_report :: proc "contextless" (holder: ^Started, caller: ^Started, name: string, end: bool, values: ^[7]u64) -> system.Status {
	kind := u32(system.Root_Command.Debug_Store)
	if end {
		if debug_store.report_for == caller && debug_store.holder == holder {
			debug_store_report_end()
		}
		return .Ok
	}
	if .Debug in caller.revoked {
		values^ = errors.ring_fail(kind, .No_Grant, .Debug_Access, 1)
		return .No_Right
	}
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .Bad_Operation
	}
	report := disk_program.kept_stop_report_find(&kept_stop_reports, caller.principal, name)
	if report == nil {
		values^ = errors.ring_fail(kind, .Absent, .Stop_Reports, 1)
		return .Bad_State
	}
	// The page of the report: memory of this service, given with the
	// right Read only, and closed here once given.
	page, created := system.memory_create(1)
	if created != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(created))
		return created
	}
	defer system.close(page)
	address, mapped := system.memory_map(page)
	if mapped != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(mapped))
		return mapped
	}
	(^disk_program.Kept_Stop_Report)(address)^ = report^
	system.memory_unmap(address)
	given_page, page_status := system.give(holder.requests_memory, page, {.Read})
	if page_status != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(page_status))
		return page_status
	}
	given: [3]system.Handle
	status := debug_store_connection_give(holder, caller.principal, &given)
	if status != .Ok {
		// The page is in the ring memory of the service already: the
		// service closes a handle that a refusal names in no value.
		system.handle_revoke(page, holder.program)
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		return status
	}
	debug_store.report_for = caller
	debug_store.holder = holder
	values^ = {u64(given[0]), u64(given[1]), u64(given[2]), u64(given_page), caller.principal, 0, 0}
	system.log_in("programs", .Info, "root: gave ", system.Module_Name{system.name_of(holder.name[:])}, " the kept stop report of ", system.Module_Name{name}, " and a connection that reads only to the store ", disk_program.STORE_NAME, " of principal ", caller.principal, ", for ", system.Module_Name{system.name_of(caller.name[:])})
	return .Ok
}

// debug_store_connection_give opens the connection that reads only to the
// store `programs` of a principal, and gives its three handles to the
// debugger service `holder`. It ends a connection that the service had
// before: one at a time.
@(private = "file")
debug_store_connection_give :: proc "contextless" (holder: ^Started, principal: u64, given: ^[3]system.Handle) -> system.Status {
	if debug_store.connection != nil {
		disconnect(debug_store.connection)
	}
	debug_store = {}
	debug_store_reader = {}
	copy(debug_store_reader.name[:len(debug_store_reader.name) - 1], disk_program.STORE_NAME)
	debug_store_reader.principal = principal
	connection, service, ring_memory, region_memory, status := connection_open(&debug_store_reader, "storage")
	if status != .Ok {
		return status
	}
	// The debugger service receives the handles through its ring to this
	// service; this service keeps none of the memory.
	defer system.close(ring_memory)
	defer system.close(region_memory)
	sources := [3]system.Handle{service.program, ring_memory, region_memory}
	given_rights := [3]system.Rights{{.Read}, {.Read, .Write}, {.Read, .Write}}
	given_count := 0
	for source, index in sources {
		given[index], status = system.give(holder.requests_memory, source, given_rights[index])
		if status != .Ok {
			break
		}
		given_count += 1
	}
	if status != .Ok {
		// A refusal names no handle, so the service closes none: the
		// handles given before the failure are revoked here, as the page
		// of a report is.
		for source in sources[:given_count] {
			system.handle_revoke(source, holder.program)
		}
		disconnect(connection)
		return status
	}
	debug_store.connection = connection
	return .Ok
}

// debug_store_end ends the connection of the debug object of a program:
// when the debugger service read the object, and in any case when the
// debug access to that program ends. The storage service then answers no
// call of it.
debug_store_end :: proc "contextless" (target: ^Started) {
	if debug_store.connection == nil || target == nil || debug_store.target != target {
		return
	}
	// disconnect forgets the connection here.
	disconnect(debug_store.connection)
	debug_store = {}
}

// debug_store_report_end ends the connection of a kept stop report.
@(private = "file")
debug_store_report_end :: proc "contextless" () {
	if debug_store.connection != nil {
		// disconnect forgets the connection here.
		disconnect(debug_store.connection)
	}
	debug_store = {}
}

// debug_store_release ends the connection of a kept stop report when the
// caller that asked for it, or the debugger service, stops: no end comes
// then.
debug_store_release :: proc "contextless" (item: ^Started) {
	if debug_store.report_for != nil && (debug_store.report_for == item || debug_store.holder == item) {
		debug_store_report_end()
	}
}
