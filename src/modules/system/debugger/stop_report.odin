package debugger

// The stop report of a disk process that stopped on a fault, named with no
// attach (src/md/features/debug_object_of_a_disk_process.md). The root
// service holds the only handle of a disk process and closes it at the
// reap: the kernel forgets the report then, and no process can attach to a
// process that stopped. The root service keeps a copy of the report, with
// each value that can be a word of the memory of the process taken out,
// and gives it to this service with the connection that reads the debug
// object of its module.

import debug_object "modus:contract/debug_object"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/disk_process"
import "modus:support/system"

// One frame of the stop report of a disk process: stop_report(). 256
// bytes, the most that a row of a described record has.
Stop_Frame_Row :: struct {
	frame:     i64, // 0: the instruction of the fault. Each next one: a caller.
	module:    [32]u8, // The name of the module in the boot image, or the nickname of the process for its own module.
	procedure: [80]u8, // From the debug object of the module. Empty: no object, or no procedure holds the address.
	offset:    i64, // The offset in the procedure of the instruction (frame 0) or of the return address; in the module with no procedure.
	file:      [80]u8,
	line:      i64, // The line of the instruction, or of the call. 0: no source line.
	stop:      [40]u8, // Frame 0: what stopped the process. A frame whose value the root service hid: "hidden". Else empty.
}
#assert(size_of(Stop_Frame_Row) == 256)

// stop_report gives one row for each frame of the stop report of a disk process that stopped on a fault: the module, the procedure and its offset, the file and the line. It needs no attach.
//
// The root service keeps the stop report of each disk process that stops
// on a fault, 8 of them and 4 for one principal, until a run of the
// nickname ends with no fault: a process that stopped can be attached
// to by no debugger. This export asks the root service for the report, and
// reads the debug object of the module from the store `module_files`, as
// `attach` does. The report holds only the frames that a module record
// holds, as `Inspect` gives them: the root service hid each other value,
// which can be a word of the memory of the process.
//
// - **process**: the nickname of the disk process, at most 31 bytes.
//
// **Errors**:
//
// - `No_Grant`, `Acts_For_Principal` (-1): the caller does not act for the
//   principal.
// - (-4) the record of the root service: `Absent`, `Stop_Reports` when no
//   disk process of the principal of the caller with this nickname stopped
//   on a fault, or 8 newer reports took its place; `No_Grant`,
//   `Debug_Access` when the grant `debug` of the caller was revoked;
//   `No_Answer` when the root service did not answer in 1500 ms;
//   `Refused` with the status of the kernel.
// - `Too_Long`, `Bytes` (-15): the name has no byte or more than 31.
//
// ```
// connect("debugger")
// debugger.stop_report("visitor")
// ```
@(export, link_name = "stop_report")
stop_report :: proc "c" (process: ^string, result: ^[]Stop_Frame_Row, error: ^errors.Error_Record) -> i64 {
	caller := system.service_caller()
	if caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	buffer: [PROCESS_NAME_LIMIT]u8
	name, fits := text_copy(buffer[:], process)
	if !fits || name == "" {
		return errors.fail(error, ERROR_TEXT, .Too_Long, .Bytes, 1, i64(len(process^)), PROCESS_NAME_LIMIT)
	}
	kept: disk_process.Kept_Stop_Report
	// The object of the module lives for this export: it is read again at
	// the next one, as the store can hold another object since.
	read_object: Disk_Debug_Object
	defer held_object_forget(&read_object)
	completion, answered, received := store_debug_object_read(name, caller.ring_memory, &read_object, 0, &kept)
	if !answered {
		return errors.fail(error, ERROR_REFUSED, .No_Answer, .Milliseconds, 0, 0, DISK_DEBUG_OBJECT_MILLISECONDS)
	}
	if system.Status(completion.kind) != .Ok {
		if error != nil {
			error^ = errors.completion_record(completion.values)
		}
		return ERROR_REFUSED
	}
	if !received {
		return refused(error, .Bad_Handle)
	}
	// The object of the module: the one read here, or the one of the
	// session when the service debugs the same module from the store of
	// the same principal (store_debug_object_read did not read then).
	module_object := read_object.object
	if module_object == nil && disk_debug_object.object != nil && disk_debug_object.module_hash == kept.module_hash && disk_debug_object.principal == completion.values[4] {
		module_object = disk_debug_object.object
	}
	report := &kept.report
	frame_count := int(min(report.frame_count, op.STOP_FRAME_CAPACITY))
	named := 0
	for index in 0 ..< frame_count {
		if index >= len(result^) {
			break
		}
		frame := report.frames[index]
		row := &result[index]
		row^ = {frame = i64(index)}
		if index == 0 {
			stop_cause_write(row.stop[:], report)
		}
		if frame.base == 0 || frame.address < frame.base {
			if index > 0 {
				system.format(row.stop[:], "hidden")
			}
			continue
		}
		offset := frame.address - frame.base
		// A return address is the instruction after the call: the
		// procedure and the line are those of the byte before it.
		looked := index > 0 && offset > 0 ? offset - 1 : offset
		frame_object: []u8
		module_text := ""
		if frame.hash == kept.module_hash {
			frame_object = module_object
			module_text = name
		} else {
			frame_object = system.debug_object_of(&debug_names, frame.hash)
			if entry := system.image_entry_of(image, frame.hash); entry != nil {
				module_text = system.name_of(entry.name[:])
			}
		}
		system.format(row.module[:], module_text)
		place: debug_object.Place
		if frame_object != nil {
			place = debug_object.place_of(frame_object, looked)
		}
		if place.procedure == "" {
			row.offset = i64(offset)
			continue
		}
		system.format(row.procedure[:], place.procedure)
		row.offset = i64(place.offset_in_procedure + (offset - looked))
		system.format(row.file[:], place.file)
		row.line = i64(place.line)
		named += 1
	}
	system.log_fact(.Info, Stop_Report_Read{frames = u64(frame_count), named = u64(named), debugged_process = value_kinds.module_name_field(name)})
	return i64(frame_count)
}

// stop_cause_write writes what stopped the process: "page fault at 0x0",
// or the vector of another fault.
stop_cause_write :: proc "contextless" (column: []u8, report: ^op.Stop_Report) {
	writer := system.Writer{buffer = column}
	if report.vector == 14 {
		system.write_part(&writer, "page fault at ")
		system.write_number(&writer, report.address)
	} else {
		system.write_part(&writer, "fault, vector ")
		system.write_part(&writer, u64(report.vector))
	}
	system.written(&writer)
}
