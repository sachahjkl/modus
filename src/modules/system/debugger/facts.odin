package debugger

import "modus:contract/value_kinds"
import "modus:support/disk_process"

// The log facts of the debugger (src/md/features/log_facts.md): the debug
// objects that it reads from the store or refuses, the sessions that it
// attaches and ends, and the stops of the threads that it debugs, as
// records of fields. Each fact template is the sentence that the line wrote
// before it was a fact, so a wait of a machine test on that sentence reads
// it as before. A line whose sentence differs by its case is one fact type
// for each case: the template has no condition. No field has the name of a
// column of the head of facts(): number, time, process, level.
//
// The process that the debugger debugs is the Text field
// debugged_process. A cause from a closed set of sentences is a Text
// field. A Text field is the last field, and is [N]u8 with N written out,
// as the tool reads it.

// The bytes of the Text field of the cause of a read of a debug object
// that stopped: the longest, "the storage service gave more bytes than the
// object has left", has 59 bytes, and a zero byte.
READ_PROBLEM_FIELD_BYTES :: 64
// The bytes of the Text field of why a debugging ended: the longest, "the
// debug access was revoked", has 28 bytes.
SESSION_END_FIELD_BYTES :: 32
// The bytes of the Text field of the kind of a stop: the text of an event
// has at most 28 bytes.
STOP_KIND_FIELD_BYTES :: 32

// The template names the store by its words: the name of the store is a
// constant of the system, not a value of the line.
#assert(disk_process.STORE_NAME == "module_files")

// The command to the root service for the store was not sent.
@(log_fact = "debugger: no debug object for {debugged_process}: the command to the root service was not sent")
Debug_Object_Command_Not_Sent :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// The root service gave no connection to the store in its bound.
@(log_fact = "debugger: no debug object for {debugged_process}: the root service gave no connection to the store in {bound}")
Debug_Object_Connection_Silent :: struct {
	bound:            value_kinds.Time_In_Milliseconds,
	debugged_process: value_kinds.Module_Name_Field,
}

// The root service refused the connection to the store: the word of its
// completion keeps its number, as the line wrote it.
@(log_fact = "debugger: no debug object for {debugged_process}: the root service refused the connection to the store, status word {status_word}")
Debug_Object_Connection_Refused :: struct {
	status_word:      u64,
	debugged_process: value_kinds.Module_Name_Field,
}

// The stop report that the root service kept does not map.
@(log_fact = "debugger: no stop report of {debugged_process}: the page of the root service does not map")
Stop_Report_Not_Mapped :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// The connection to the store does not open.
@(log_fact = "debugger: no debug object for {debugged_process}: the connection to the store does not open")
Debug_Object_Connection_Not_Opened :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// The storage service gave no size of the debug object in its bound.
@(log_fact = "debugger: no debug object for {debugged_process}: the storage service gave no size in {bound}")
Debug_Object_Size_Silent :: struct {
	bound:            value_kinds.Time_In_Milliseconds,
	debugged_process: value_kinds.Module_Name_Field,
}

// The store has no debug object of the module.
@(log_fact = "debugger: no debug object for {debugged_process}: the store module_files of principal {principal} has no object {module_hash}")
Debug_Object_Absent :: struct {
	principal:        u64,
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store has a size that a debug object cannot
// have.
@(log_fact = "debugger: no debug object for {debugged_process}: the object {module_hash} has {size}, and a debug object has 1 to {size_limit}")
Debug_Object_Size_Refused :: struct {
	size:             value_kinds.Size_In_Bytes,
	size_limit:       u64,
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The read of the bytes of a debug object stopped.
@(log_fact = "debugger: no debug object for {debugged_process}: {problem}")
Debug_Object_Read_Stopped :: struct {
	debugged_process: value_kinds.Module_Name_Field,
	problem:          [64]u8,
}

// The debug object of the store names another module.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: it names the module {named_module}, not this module")
Debug_Object_Of_Another_Module :: struct {
	module_hash:      value_kinds.Hash_Field,
	named_module:     value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// A debug object read whole from the store, and checked.
@(log_fact = "debugger: read the debug object {module_hash} of {debugged_process} from the store module_files of principal {principal}: {size}, checked whole")
Debug_Object_Read :: struct {
	principal:        u64,
	size:             value_kinds.Size_In_Bytes,
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// Several processes have the name and the module of the attach.
@(log_fact = "debugger: {matches} processes have the name {debugged_process} and the same module: the service cannot tell which one its handle names")
Attach_Ambiguous :: struct {
	matches:          u64,
	debugged_process: value_kinds.Module_Name_Field,
}

// An attach done, for a caller.
@(log_fact = "debugger: attached to {debugged_process} for {caller}: {threads} threads, {modules} modules, {described} with a debug object")
Attach_Done :: struct {
	threads:          u64,
	modules:          u64,
	described:        u64,
	debugged_process: value_kinds.Module_Name_Field,
	caller:           value_kinds.Module_Name_Field,
}

// A thread ran through the call of a step_over, and did not stop in it.
@(log_fact = "debugger: the thread {thread} of {debugged_process} ran a call to its end, for step_over")
Step_Over_Ran_To_End :: struct {
	thread:           u64,
	debugged_process: value_kinds.Module_Name_Field,
}

// Stops that found the table of the events full.
@(log_fact = "debugger: {stops} stops of {debugged_process} found the table of the events full, and have no row")
Events_Lost :: struct {
	stops:            u64,
	debugged_process: value_kinds.Module_Name_Field,
}

// The commands to the root service fill their table.
@(log_fact = "debugger: {capacity} commands wait for the root service: no room for one more")
Root_Commands_Full :: struct {
	capacity: u64,
}

// The root service answered an earlier attach after the export stopped
// waiting, while a debugging runs.
@(log_fact = "debugger: the root service answered an earlier attach to {debugged_process} after the export stopped waiting: its handle is closed, and the debugging that runs stays")
Late_Attach_Answer_While_Debugging :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// The root service answered an attach after the export stopped waiting.
@(log_fact = "debugger: the root service answered the attach to {debugged_process} after the export stopped waiting: the debug access is given back")
Late_Attach_Answer :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// The debugging of a process ended.
@(log_fact = "debugger: the debugging of {debugged_process} ended: {why}")
Debugging_Ended :: struct {
	debugged_process: value_kinds.Module_Name_Field,
	why:              [32]u8,
}

// A thread of the debugged process stopped: an event.
@(log_fact = "debugger: the thread {thread} of {debugged_process} stopped: {stop_kind}")
Thread_Stopped :: struct {
	thread:           u64,
	debugged_process: value_kinds.Module_Name_Field,
	stop_kind:        [32]u8,
}

// The stop report of a process, with the frames that the debug objects
// name.
@(log_fact = "debugger: the stop report of {debugged_process}: {frames} frames, {named} named by the debug objects of their modules")
Stop_Report_Read :: struct {
	frames:           u64,
	named:            u64,
	debugged_process: value_kinds.Module_Name_Field,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Debug_Object_Read_Stopped) == value_kinds.MODULE_NAME_FIELD_BYTES + READ_PROBLEM_FIELD_BYTES)
#assert(size_of(Debugging_Ended) == value_kinds.MODULE_NAME_FIELD_BYTES + SESSION_END_FIELD_BYTES)
#assert(size_of(Thread_Stopped) == 8 + value_kinds.MODULE_NAME_FIELD_BYTES + STOP_KIND_FIELD_BYTES)
