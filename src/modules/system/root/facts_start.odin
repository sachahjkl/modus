package root

import "modus:contract/errors"
import "modus:contract/value_kinds"

// The log facts of the starts, the budgets, the mappings, the devices, the
// debugging and the other lines of the root service that are not about the
// disk grant tables, the principals or the start policy
// (src/md/features/log_facts.md). Each fact template is the sentence that
// the line wrote before it was a fact. The Integer fields come first and
// the Text fields last: the serial line of a fact stops at its last byte
// that is not zero, so the zeros after a short name cost no byte.
//
// A field of a name holds the bytes of the name and a zero byte after it.
// A Text field is [N]u8 with N written out, as the tool reads it, and N is
// a multiple of 8, so the record has no padding.

// A process gets less of one part of its budget than its module asks for:
// the starter gives it the largest budget of that part.
@(log_fact = "root: {started_process} asks for {asked} {budget_part}, and {largest_of} gets at most {largest}: it starts with {granted}")
Budget_Part_Limited :: struct {
	asked:           u64,
	largest:         u64,
	granted:         u64,
	started_process: value_kinds.Module_Name_Field,
	budget_part:     [16]u8,
	largest_of:      [16]u8,
}

// The one budget of the disk processes, made at the first of them.
@(log_fact = "root: the disk processes share one budget of {pages}, {processes} processes and {threads} threads")
Disk_Processes_Budget_Made :: struct {
	pages:     value_kinds.Size_In_Pages,
	processes: u64,
	threads:   u64,
}

// A start refused: the budget that pays holds less of one part than the
// process gets.
@(log_fact = "root: cannot start {refused_process}: it gets {needed} {budget_part}, and the budget of {paying_budget} holds {held}")
Start_Refused_Budget_Part :: struct {
	needed:          u64,
	held:            u64,
	refused_process: value_kinds.Module_Name_Field,
	budget_part:     [16]u8,
	paying_budget:   [24]u8,
}

// A start refused: the budget that pays holds fewer log records of each
// second than the process gets.
@(log_fact = "root: cannot start {refused_process}: it gets {log_records} log records of each second, and the budget of {paying_budget} holds {held_log_records}")
Start_Refused_Log_Records :: struct {
	log_records:      u64,
	held_log_records: u64,
	refused_process:  value_kinds.Module_Name_Field,
	paying_budget:    [24]u8,
}

// A start refused: the limit of processor time of the budget that pays is
// under what the process gets. The line wrote the word "microseconds"
// after the count, which a Time field does not write.
@(log_fact = "root: cannot start {refused_process}: it gets {processor} microseconds of processor time in each second, and the limit of the budget of {paying_budget} is {processor_limit}")
Start_Refused_Processor_Time :: struct {
	processor:       u64,
	processor_limit: u64,
	refused_process: value_kinds.Module_Name_Field,
	paying_budget:   [24]u8,
}

// A start refused: the budget that pays holds each part, so the budget of
// the process itself was too small for its own load.
@(log_fact = "root: cannot start {refused_process}: its budget of {pages}, {processes} processes and {threads} threads is too small for its load: the module asks for too little")
Start_Refused_Budget_Too_Small :: struct {
	pages:           value_kinds.Size_In_Pages,
	processes:       u64,
	threads:         u64,
	refused_process: value_kinds.Module_Name_Field,
}

// A start refused: two grants of the start grant set of the process take one handle
// slot of its context. The slot is the word of the starter, which can be
// negative: the line wrote its bits as an unsigned number.
@(log_fact = "root: cannot start {refused_process}: two grants of its start grant set take the handle {slot} of its context, and a handle would be lost")
Start_Refused_Context_Handle :: struct {
	slot:            u64,
	refused_process: value_kinds.Module_Name_Field,
}

// A start refused: two parts of the start write one value of the context.
@(log_fact = "root: cannot start {refused_process}: two parts of its start write the value {value_place} of its context, and a value would be lost")
Start_Refused_Context_Value :: struct {
	value_place:     u64,
	refused_process: value_kinds.Module_Name_Field,
}

// A start refused: the sound device plays for another process.
@(log_fact = "root: cannot start {refused_process}: the sound device plays for another process; one process plays at a time")
Start_Refused_Sound_Device_Busy :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

// A mapping that a start drops, as the list of its mappings is full: the
// process starts without it.
@(log_fact = "root: no room for {mapping} in the mappings of a start, which holds {capacity}: the process starts without it")
Mapping_Dropped :: struct {
	capacity: u64,
	mapping:  [40]u8,
}

// A mapping that a process cannot start without, and that the full list of
// the mappings of its start cannot take: the start fails.
@(log_fact = "root: no room for {mapping} in the mappings of a start, which holds {capacity}: the start of {refused_process} fails")
Mapping_Needed :: struct {
	capacity:        u64,
	refused_process: value_kinds.Module_Name_Field,
	mapping:         [40]u8,
}

// The control ring of the compositor was full when a window started: the
// start of that window has no measure.
@(log_fact = "root: the control ring of the compositor is full: the start of the window of {window_process} is not measured")
Window_Start_Not_Measured :: struct {
	window_process: value_kinds.Module_Name_Field,
}

// The size of the debug image of the boot image.
@(log_fact = "root: the debug image has {debug_image_size}")
Debug_Image_Found :: struct {
	debug_image_size: value_kinds.Size_In_Bytes,
}

// The stop report of a disk process kept for its principal. The name comes
// twice in the sentence, and a template names a field once: the second
// field holds the same name, as the argument of stop_report.
@(log_fact = "root: kept the stop report of {stopped_process}, a disk process of principal {principal}: stop_report(\"{stop_report_name}\") names its frames")
Stop_Report_Kept :: struct {
	principal:        u64,
	stopped_process:  value_kinds.Module_Name_Field,
	stop_report_name: value_kinds.Module_Name_Field,
}

// The debugger service got a connection that reads only the store of the
// module files of a principal, for the debug object of a disk process.
@(log_fact = "root: gave {debugger} a connection that reads only to the store module_files of principal {principal}, for the debug object of {target}")
Debug_Store_Given :: struct {
	principal: u64,
	debugger:  value_kinds.Module_Name_Field,
	target:    value_kinds.Module_Name_Field,
}

// The debugger service got the kept stop report of a disk process and a
// connection that reads only the store of the module files, for a caller.
@(log_fact = "root: gave {debugger} the kept stop report of {target} and a connection that reads only to the store module_files of principal {principal}, for {caller}")
Debug_Stop_Report_Given :: struct {
	principal: u64,
	debugger:  value_kinds.Module_Name_Field,
	target:    value_kinds.Module_Name_Field,
	caller:    value_kinds.Module_Name_Field,
}

// The debugger service ended the debugging of a process for a caller.
@(log_fact = "root: {debugger} ended the debugging of {target} for {caller}")
Debugging_Ended :: struct {
	debugger: value_kinds.Module_Name_Field,
	target:   value_kinds.Module_Name_Field,
	caller:   value_kinds.Module_Name_Field,
}

// A caller refused the debug access to a process, by a grant of that
// process.
@(log_fact = "root: refused {caller} the debug access to {target}: the grant {grant} of the process refuses it")
Debug_Access_Refused :: struct {
	caller: value_kinds.Module_Name_Field,
	target: value_kinds.Module_Name_Field,
	grant:  [24]u8,
}

// A debugging ended because a revocation took away the rule that gave the
// debug access.
@(log_fact = "root: ended the debugging of {target} for {caller}: the rule no longer gives the debug access, after a revocation")
Debugging_Ended_After_Revocation :: struct {
	target: value_kinds.Module_Name_Field,
	caller: value_kinds.Module_Name_Field,
}

// A revocation of acts_for_principal refused: a service has no room for
// the grants that the revocation gives.
@(log_fact = "root: refused the revocation of acts_for_principal of {holder}: the service {service} has no room for the new grants; nothing changed")
Acts_For_Principal_Revocation_Refused :: struct {
	holder:  value_kinds.Module_Name_Field,
	service: value_kinds.Module_Name_Field,
}

// A process became the palette provider.
@(log_fact = "root: {provider} is the palette provider")
Palette_Provider_Set :: struct {
	provider: value_kinds.Module_Name_Field,
}

// The name of the store of a caller does not fit the 31 bytes of a name.
@(log_fact = "root: the name of the store of {caller} for principal {principal} has more than 31 bytes: no connection")
Store_Name_Too_Long :: struct {
	principal: u64,
	caller:    value_kinds.Module_Name_Field,
}

// A resource of the boot image whose bytes do not have the hash of its
// entry: it is not given.
@(log_fact = "root: the resource {resource} does not have the hash of its entry: not given")
Resource_Hash_Wrong :: struct {
	resource: [32]u8,
}

// A resource of the boot image given read-only, after the check of its
// hash.
@(log_fact = "root: the resource {resource} ({resource_size}, its hash checked in {check_time}) is given to {receiver}, read-only")
Resource_Given :: struct {
	resource_size: value_kinds.Size_In_Bytes,
	check_time:    value_kinds.Time_In_Microseconds,
	resource:      [32]u8,
	receiver:      value_kinds.Module_Name_Field,
}

// A replacement of a module refused, with the sentence of its cause: a
// closed set of sentences of the replacement list and of its signature.
@(log_fact = "root: refused the replacement of {replaced} by {replacement}: {reason}")
Replacement_Refused :: struct {
	replaced:    value_kinds.Module_Name_Field,
	replacement: value_kinds.Module_Name_Field,
	reason:      [80]u8,
}

// A replacement of a module ended: the module loads as itself.
@(log_fact = "root: no replacement of {replaced}")
Replacement_Ended :: struct {
	replaced: value_kinds.Module_Name_Field,
}

// A module replaces another in each load that follows.
@(log_fact = "root: {replacement} replaces {replaced} in each load that follows")
Replacement_Made :: struct {
	replacement: value_kinds.Module_Name_Field,
	replaced:    value_kinds.Module_Name_Field,
}

// The disk process imports modules that the boot image does not hold: the
// import scan reads the store of the module files.
@(log_fact = "root: {loaded_process} imports {imports} modules that the boot image does not hold: the import scan reads the store module_files to find them by the hash of their bytes")
Import_Scan_Started :: struct {
	imports:        u64,
	loaded_process: value_kinds.Module_Name_Field,
}

// An import of a disk process found in a file of the store of the module
// files, by the hash of its bytes.
@(log_fact = "root: {loaded_process}: the import {hash} of {importer} is the file {file} of the store module_files, checked on its bytes")
Import_Found :: struct {
	hash:           value_kinds.Hash_Field,
	loaded_process: value_kinds.Module_Name_Field,
	importer:       value_kinds.Module_Name_Field,
	file:           [24]u8,
}

// The network is refused from now on: its service did not start, or
// stopped.
@(log_fact = "root: {network_cause}: no process with an endpoint of the network starts until the machine starts again; the other processes start")
Network_Refused :: struct {
	network_cause: [40]u8,
}

// The font outlines of the boot image are refused, with the sentence of
// the problem and the value that the resource has.
@(log_fact = "root: the font outlines are refused: {problem}, value {problem_value}: they are not given")
Font_Outlines_Refused :: struct {
	problem_value: u64,
	problem:       [80]u8,
}

// The process slot or the process serial of a caller does not fit the
// grant of the log service: it reads no record.
@(log_fact = "root: the process slot {slot} or the process serial {serial} of {caller} does not fit the grant of the log service: it reads no record")
Log_Scope_Refused :: struct {
	slot:   u64,
	serial: u64,
	caller: value_kinds.Module_Name_Field,
}

// The kernel refused two stop codes past one byte, and the machine runs
// on: a case of the start that ends with "as it must".
@(log_fact = "root: Machine_Stop refused the codes {first_code} and {second_code} with Bad_Operation and the record Bad_Value of the code, limit {code_limit}, and the machine runs on: as it must")
Machine_Stop_Codes_Refused :: struct {
	first_code:  u64,
	second_code: u64,
	code_limit:  u64,
}

// The root service is ready: the count of the modules of the boot image.
// A machine test waits for the words "root: ok" of its sentence.
@(log_fact = "root: ok, {image_modules} modules in the boot image")
Root_Ready :: struct {
	image_modules: u64,
}

// A record of the compositor whose kind names no control.
@(log_fact = "root: refused a record of the compositor of the kind {record_kind}, which names no control")
Compositor_Record_Unknown :: struct {
	record_kind: u64,
}

// A record of the compositor of a control that this service sends and
// does not take.
@(log_fact = "root: refused a record of the compositor of the kind {record_kind}, which this service sends and does not take")
Compositor_Record_Not_Taken :: struct {
	record_kind: u64,
}

// More devices behind a conventional bridge than one device service holds.
@(log_fact = "root: more than {device_limit} devices behind the conventional bridge in front of the bus {bus}: no service for them")
Bridge_Devices_Too_Many :: struct {
	device_limit: u64,
	bus:          u64,
}

// No virtio device of the kind of a service at its place of the bus 0.
@(log_fact = "root: no virtio device for {service} at the place {device} of the bus")
Virtio_Device_Absent :: struct {
	device:  u64,
	service: value_kinds.Module_Name_Field,
}

// No virtio device of the kind of a service at its place behind a bridge.
@(log_fact = "root: no virtio device for {service} at the place {device} of the bus {bus}, behind a bridge")
Virtio_Device_Absent_Behind_Bridge :: struct {
	device:  u64,
	bus:     u64,
	service: value_kinds.Module_Name_Field,
}

// A device service behind a conventional bridge also holds the registers
// of each other device behind it, which share its requester.
@(log_fact = "root: {service} also holds the registers of each other device behind the conventional bridge in front of the bus {bus}, which shares its requester; other devices: {other_devices}")
Bridge_Registers_Held :: struct {
	bus:           u64,
	other_devices: u64,
	service:       value_kinds.Module_Name_Field,
}

// No standard VGA at its place of the bus: the compositor writes the
// screen page that the display shows.
@(log_fact = "root: no standard VGA at the place {device} of the bus: the compositor writes the screen page that the display shows")
Standard_Vga_Absent :: struct {
	device: u64,
}

// No entropy device at its place of the bus.
@(log_fact = "root: no entropy device at the place {device} of the bus: the random seed of the system has the sources of the processor only")
Entropy_Device_Absent :: struct {
	device: u64,
}

// The reads of the entropy device at the start, and what they mixed in.
@(log_fact = "root: the entropy device gave {bytes_given} in {start_reads} reads: {bytes_mixed} mixed into the random generator of the system; refused reads: {refused_start_reads}")
Entropy_Start_Bytes :: struct {
	bytes_given:         value_kinds.Size_In_Bytes,
	start_reads:         u64,
	bytes_mixed:         value_kinds.Size_In_Bytes,
	refused_start_reads: u64,
}

// The first fresh bytes given to the running processes; the reads after it
// write no line.
@(log_fact = "root: the first fresh bytes: {device_bytes} of the entropy device mixed into the random generator of the system, then {stream_bytes} of its stream in the fresh bytes page of each of {receiving_processes} processes; a read every {period_seconds} seconds after this one, with no line")
First_Fresh_Bytes :: struct {
	device_bytes:        value_kinds.Size_In_Bytes,
	stream_bytes:        value_kinds.Size_In_Bytes,
	receiving_processes: u64,
	period_seconds:      u64,
}

// The random seed of the system and the facts of each source of the
// processor. A strength and a presence are words of a closed set.
@(log_fact = "root: the random seed of the system, strength {strength}: rdseed {rdseed_presence}, {rdseed_good} good values, {rdseed_refused} refused; rdrand {rdrand_presence}, {rdrand_good} good, {rdrand_refused} refused; the cycle counter, {jitter_samples} samples, {jitter_distinct} distinct low bytes")
Random_Seed_Made :: struct {
	rdseed_good:     u64,
	rdseed_refused:  u64,
	rdrand_good:     u64,
	rdrand_refused:  u64,
	jitter_samples:  u64,
	jitter_distinct: u64,
	strength:        [32]u8,
	rdseed_presence: [8]u8,
	rdrand_presence: [8]u8,
}

// The entropy service refused a read: the fields of its error record.
@(log_fact = "root: the entropy service refused a read: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Entropy_Read_Refused :: distinct errors.Error_Record_Fact_Fields

// The network service refused a command of its control ring: the fields
// of its error record.
@(log_fact = "root: the network service refused a command of its control ring: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Network_Control_Command_Refused :: distinct errors.Error_Record_Fact_Fields


