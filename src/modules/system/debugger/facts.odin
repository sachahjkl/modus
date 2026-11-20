package debugger

import debug_object "modus:contract/debug_object"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/disk_process"
import "modus:contract/storage_status"
import "modus:support/system"

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

// The storage service refused the size of the debug object. The status of
// the client is a contract enum, which a reader writes by the name of its
// member.
@(log_fact = "debugger: no debug object for {debugged_process}: the storage service refused the size of {module_hash}, status {status}")
Debug_Object_Size_Status_Refused :: struct {
	status:           storage_status.Status,
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The kernel gave no memory for the bytes of the debug object.
@(log_fact = "debugger: no debug object for {debugged_process}: no memory for its {size}: status {status}")
Debug_Object_Memory_Refused :: struct {
	size:             value_kinds.Size_In_Bytes,
	status:           op.Status_Word,
	debugged_process: value_kinds.Module_Name_Field,
}

// The memory of the debug object does not map.
@(log_fact = "debugger: no debug object for {debugged_process}: its memory does not map: status {status}")
Debug_Object_Map_Refused :: struct {
	status:           op.Status_Word,
	debugged_process: value_kinds.Module_Name_Field,
}

// The service has no service ring.
@(log_fact = "debugger: no service ring")
No_Service_Ring :: struct {}

// The service serves its exports.
@(log_fact = "debugger: serves its exports")
Serving :: struct {}

// debug_object_refused_log writes the fact of a debug object that the
// store gave and that does not describe this module: a fault of its
// check, or no fault and another module that it names.
debug_object_refused_log :: proc "contextless" (fault: debug_object.Fault, named, module_hash: [32]u8, name: string) {
	hash := value_kinds.Hash_Field(module_hash)
	process := value_kinds.module_name_field(name)
	switch fault {
	case .None:
		system.log_fact(.Info, Debug_Object_Of_Another_Module{module_hash = hash, named_module = value_kinds.Hash_Field(named), debugged_process = process})
	case .Too_Small:
		system.log_fact(.Info, Debug_Object_Refused_Too_Small{module_hash = hash, debugged_process = process})
	case .Not_A_Debug_Object:
		system.log_fact(.Info, Debug_Object_Refused_Not_A_Debug_Object{module_hash = hash, debugged_process = process})
	case .Version:
		system.log_fact(.Info, Debug_Object_Refused_Version{module_hash = hash, debugged_process = process})
	case .Too_Many:
		system.log_fact(.Info, Debug_Object_Refused_Too_Many{module_hash = hash, debugged_process = process})
	case .Size_Differs:
		system.log_fact(.Info, Debug_Object_Refused_Size_Differs{module_hash = hash, debugged_process = process})
	case .Procedure_Order:
		system.log_fact(.Info, Debug_Object_Refused_Procedure_Order{module_hash = hash, debugged_process = process})
	case .Procedure_Name:
		system.log_fact(.Info, Debug_Object_Refused_Procedure_Name{module_hash = hash, debugged_process = process})
	case .Procedure_Package:
		system.log_fact(.Info, Debug_Object_Refused_Procedure_Package{module_hash = hash, debugged_process = process})
	case .File_Zero:
		system.log_fact(.Info, Debug_Object_Refused_File_Zero{module_hash = hash, debugged_process = process})
	case .File_Path:
		system.log_fact(.Info, Debug_Object_Refused_File_Path{module_hash = hash, debugged_process = process})
	case .Line_Order:
		system.log_fact(.Info, Debug_Object_Refused_Line_Order{module_hash = hash, debugged_process = process})
	case .Line_File:
		system.log_fact(.Info, Debug_Object_Refused_Line_File{module_hash = hash, debugged_process = process})
	case .Line_End:
		system.log_fact(.Info, Debug_Object_Refused_Line_End{module_hash = hash, debugged_process = process})
	case .Type_Zero:
		system.log_fact(.Info, Debug_Object_Refused_Type_Zero{module_hash = hash, debugged_process = process})
	case .Type_Form:
		system.log_fact(.Info, Debug_Object_Refused_Type_Form{module_hash = hash, debugged_process = process})
	case .Field_Form:
		system.log_fact(.Info, Debug_Object_Refused_Field_Form{module_hash = hash, debugged_process = process})
	case .Value_Name:
		system.log_fact(.Info, Debug_Object_Refused_Value_Name{module_hash = hash, debugged_process = process})
	case .Global_Order:
		system.log_fact(.Info, Debug_Object_Refused_Global_Order{module_hash = hash, debugged_process = process})
	case .Global_Form:
		system.log_fact(.Info, Debug_Object_Refused_Global_Form{module_hash = hash, debugged_process = process})
	case .Variable_Order:
		system.log_fact(.Info, Debug_Object_Refused_Variable_Order{module_hash = hash, debugged_process = process})
	case .Reserved:
		system.log_fact(.Info, Debug_Object_Refused_Reserved{module_hash = hash, debugged_process = process})
	case .Variable_Range:
		system.log_fact(.Info, Debug_Object_Refused_Variable_Range{module_hash = hash, debugged_process = process})
	case .Variable_Form:
		system.log_fact(.Info, Debug_Object_Refused_Variable_Form{module_hash = hash, debugged_process = process})
	}
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Debug_Object_Size_Status_Refused) == size_of(storage_status.Status) + 64)
#assert(size_of(Debug_Object_Read_Stopped) == value_kinds.MODULE_NAME_FIELD_BYTES + READ_PROBLEM_FIELD_BYTES)
#assert(size_of(Debugging_Ended) == value_kinds.MODULE_NAME_FIELD_BYTES + SESSION_END_FIELD_BYTES)
#assert(size_of(Thread_Stopped) == 8 + value_kinds.MODULE_NAME_FIELD_BYTES + STOP_KIND_FIELD_BYTES)

// A refused debug object: one fact type for each fault of its check, since
// the sentences of the faults pass the 144 bytes of a fact beside the hash
// and the name of the process, and a template has no condition. The
// sentence of each is the sentence of its fault (debug_object.fault_sentences).

// The debug object of the store is refused: its check found the fault Too_Small.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the debug object is shorter than its header")
Debug_Object_Refused_Too_Small :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Not_A_Debug_Object.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the file is not a debug object")
Debug_Object_Refused_Not_A_Debug_Object :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Version.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the debug object has another version")
Debug_Object_Refused_Version :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Too_Many.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a table of the debug object has more records than a reader takes")
Debug_Object_Refused_Too_Many :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Size_Differs.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the size of the debug object is not the size of its tables")
Debug_Object_Refused_Size_Differs :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Procedure_Order.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a procedure does not start after the end of the one before it")
Debug_Object_Refused_Procedure_Order :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Procedure_Name.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the name of a procedure is outside the strings, or has a byte that is not a visible character")
Debug_Object_Refused_Procedure_Name :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Procedure_Package.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the package of a procedure is not followed by \"::\"")
Debug_Object_Refused_Procedure_Package :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault File_Zero.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the file 0 of the debug object is not all zero")
Debug_Object_Refused_File_Zero :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault File_Path.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the path of a file is outside the strings, has a byte that is not a visible character, or has a part \"..\"")
Debug_Object_Refused_File_Path :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Line_Order.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a row of the line table does not come after the row before it")
Debug_Object_Refused_Line_Order :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Line_File.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a row of the line table names a file that the table does not have")
Debug_Object_Refused_Line_File :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Line_End.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the last row of the line table names a file")
Debug_Object_Refused_Line_End :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Type_Zero.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the type 0 of the debug object is not all zero")
Debug_Object_Refused_Type_Zero :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Type_Form.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a type has a kind that the format does not have, a name outside the strings, or an element, fields or values that the tables do not have")
Debug_Object_Refused_Type_Form :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Field_Form.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a field has a name outside the strings, or a type that the table does not have")
Debug_Object_Refused_Field_Form :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Value_Name.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the name of an enumeration value is outside the strings, or has a byte that is not printable")
Debug_Object_Refused_Value_Name :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Global_Order.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a global variable has an address below the one before it")
Debug_Object_Refused_Global_Order :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Global_Form.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a global variable has a name outside the strings, or a type that the table does not have")
Debug_Object_Refused_Global_Form :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Variable_Order.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a variable has no range, or its ranges are not in their order")
Debug_Object_Refused_Variable_Order :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Reserved.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a reserved field of the debug object is not zero")
Debug_Object_Refused_Reserved :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Variable_Range.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: the range of a variable is empty or outside its procedure")
Debug_Object_Refused_Variable_Range :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

// The debug object of the store is refused: its check found the fault Variable_Form.
@(log_fact = "debugger: refused the debug object {module_hash} of {debugged_process}: a variable has a name outside the strings, a type that the table does not have, or a variable location that the format does not have")
Debug_Object_Refused_Variable_Form :: struct {
	module_hash:      value_kinds.Hash_Field,
	debugged_process: value_kinds.Module_Name_Field,
}

