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

// The budgets of a screen of memory grew for a size that a viewer asked
// (src/md/features/screen_of_memory.md, "The growth of the budgets").
@(log_fact = "root: the budgets of the screen of memory grow for {width} x {height}, growth {growth}: an extra budget of {compositor_pages} for the compositor and of {service_pages} for remote_display")
Screen_Budget_Grown :: struct {
	width:            u64,
	height:           u64,
	growth:           u64,
	compositor_pages: value_kinds.Size_In_Pages,
	service_pages:    value_kinds.Size_In_Pages,
}

// A growth of the budgets of a screen of memory was refused: nothing was
// made.
@(log_fact = "root: refused to grow the budgets of the screen of memory for {width} x {height}: {grow_refusal}")
Screen_Budget_Refused :: struct {
	width:        u64,
	height:       u64,
	grow_refusal: [96]u8,
}

// A process closed its extra budget of a growth of a screen of memory: this
// service closed its own handle.
@(log_fact = "root: {holder} gave back its extra budget of growth {growth} of the screen of memory: its pages return when no object of it is left")
Screen_Budget_Released :: struct {
	growth: u64,
	holder: value_kinds.Module_Name_Field,
}

// A release of an extra budget of a growth that the process does not hold.
@(log_fact = "root: refused the release of the extra budget of growth {growth} of the screen of memory from {holder}, which holds none of it")
Screen_Budget_Release_Refused :: struct {
	growth: u64,
	holder: value_kinds.Module_Name_Field,
}

// A process stopped with its extra budget of a screen of memory open.
@(log_fact = "root: {holder} stopped with an extra budget of the screen of memory: its pages return")
Screen_Budget_Ended_At_Stop :: struct {
	holder: value_kinds.Module_Name_Field,
}

// The holder of Display starts on a machine with no screen, on the screen
// of memory that its start row gives (src/md/features/screen_of_memory.md).
@(log_fact = "root: the compositor starts on a screen of memory of {width} x {height}: the machine has no screen")
Compositor_On_Screen_Of_Memory :: struct {
	width:  u64,
	height: u64,
}

// A start refused: the module file gives no floor that can start a
// process (no table Floor, no process or no thread, more pictures of the
// screen than a module may hold, a file that is not valid). No page moved.
@(log_fact = "root: cannot start {refused_process}: its module file gives no floor")
Start_Refused_No_Floor :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

// A start refused: the floor of its start is more than the budget that pays
// can give it, past the floors that it keeps for the start list. No page
// moved (src/md/features/module_budget_request.md, "The size, part by
// part").
@(log_fact = "root: cannot start {refused_process}: its floor is {floor}, and {paying_budget} can give {held}")
Start_Refused_Floor :: struct {
	floor:           value_kinds.Size_In_Pages,
	held:            value_kinds.Size_In_Pages,
	refused_process: value_kinds.Module_Name_Field,
	paying_budget:   [24]u8,
}

// The peak of the budget of a process at its first state of work, with the
// floor of its start: a measure of each build, which a reader follows over
// the releases (src/md/features/module_budget_request.md, "The peak of a
// budget").
// The pages are counts, not sizes, so that `modustool floors measured`
// reads them whole from the line.
@(log_fact = "root: {ready_process} reached its first state of work with a peak of {peak_pages} pages, for a floor of {floor_pages} pages")
Budget_Peak_At_Ready :: struct {
	peak_pages:    u64,
	floor_pages:   u64,
	ready_process: value_kinds.Module_Name_Field,
}

// A process paid more than its floor before its first state of work: the
// floor that its module states is wrong. The machine test stops on this
// line (tools/modustool/machine/floor_check.odin).
@(log_fact = "root: {ready_process} passed its floor before its first state of work: a peak of {peak_pages} pages, for a floor of {floor_pages} pages")
Budget_Floor_Passed :: struct {
	peak_pages:    u64,
	floor_pages:   u64,
	ready_process: value_kinds.Module_Name_Field,
}

// The counters of the ready ring of a process say more records than it
// holds: the ring ends, and the floor of the process is not checked.
@(log_fact = "root: the ready ring of {ready_process} counts more records than it holds: it ends, and the floor is not checked")
Ready_Ring_Counters_Refused :: struct {
	ready_process: value_kinds.Module_Name_Field,
}

// The counters of the root ring of a process say more records than it
// holds: the ring ends, and the process sends no more command.
@(log_fact = "root: the root ring of {caller} counts more records than it holds: it ends, and no command of it is read")
Root_Ring_Counters_Refused :: struct {
	caller: value_kinds.Module_Name_Field,
}

// The ready ring of a process carried another record than Ready: the ring
// ends, and the floor of the process is not checked.
@(log_fact = "root: {ready_process} sent the record {kind} on its ready ring, which carries Ready alone: its floor is not checked")
Ready_Record_Refused :: struct {
	kind:          u64,
	ready_process: value_kinds.Module_Name_Field,
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

// A renderer of the terminal refused: the holder of Terminal is not the
// module of the renderer that the image chose.
@(log_fact = "root: cannot start {refused_process} as the terminal of the console: it is not the renderer that the boot image chose; it gets no serial port and no screen")
Console_Renderer_Refused_Holder :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

// A renderer of the terminal refused: one runs already.
@(log_fact = "root: cannot start {refused_process} as the terminal of the console: a renderer runs already; one process at a time holds the serial port or the screen")
Console_Renderer_Refused_Running :: struct {
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

// The root service started a process held before its first instruction,
// for the debugger service and one of its callers (Debug_Start).
@(log_fact = "root: started {held_process} held before its first instruction for the debugger of {caller}")
Process_Held_For_Debugger :: struct {
	held_process: value_kinds.Module_Name_Field,
	caller:       value_kinds.Module_Name_Field,
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

// A resource of the boot image given read-only, after its bytes agreed with
// its entry.
@(log_fact = "root: the resource {resource} ({resource_size}) is given to {receiver}, read-only")
Resource_Given :: struct {
	resource_size: value_kinds.Size_In_Bytes,
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


