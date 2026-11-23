package build

import debug_object "modus:contract/debug_object"
import "modus:contract/cut_mark"
import "modus:contract/errors"
import "modus:contract/call_outcome"
import "modus:contract/memory_screen"
import module "modus:contract/module"
import "modus:contract/storage_status"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:sentence"
import "core:fmt"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the other system modules against the lines that they
// replaced (src/md/features/log_facts.md, "The facts of the other system
// modules"): the debugger, the start policy, the module file service, the
// date service, the windows boot and pages, the call host, the assembler,
// the C compiler, and the lines that the services of the devices and of
// the network, remote and remote_display wrote as text after the facts of
// their group. The fact types come from the extraction of the tool on the
// sources of each module: a host test does not depend on a build. Each
// sentence is compared with the parts of the old line written by
// sentence.format, at the edges of each field. The helpers are in
// fact_test_helpers_test.odin.

// The edges of a count, and of a time and of a size: the largest that a
// field of a time or of a size holds is max(i64).
@(private = "file")
Edges :: struct {
	counts: [3]u64,
	sizes:  [3]u64,
}

@(private = "file")
edges_make :: proc() -> Edges {
	return {counts = {0, 1, max(u64)}, sizes = {0, 1, u64(max(i64))}}
}

// A failure of the longest that its field holds, and of one byte.
@(private = "file")
failures :: proc() -> [2]string {
	return {strings.repeat("f", 95, context.temp_allocator), "f"}
}

// The most bytes of the text of each Text field of the modules of this
// file that facts_expect_text_fields_last reads, which its field holds
// with a zero byte after it.
@(private = "file")
system_module_text_bytes_most :: proc() -> map[string]u32 {
	most := make(map[string]u32, context.temp_allocator)
	most["debugged_process"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["caller"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["row_process"] = value_kinds.MODULE_NAME_FIELD_BYTES - 1
	most["problem"] = len("the storage service gave more bytes than the object has left")
	most["why"] = len("the debug access was revoked")
	most["stop_kind"] = 28
	most["list_problem"] = len("a row has a mark that is neither needed nor not needed")
	most["missing_part"] = len("disk of the measures")
	most["failure"] = len("no handle of the frame service with the right Read: a wait for the device would have no end")
	most["file_name"] = 64
	most["remote_address"] = len("255.255.255.255")
	most["time_zone"] = len("+08:00")
	most["utc_date"] = 31
	most["module_name"] = module.NAME_SIZE
	most["imported_name"] = module.NAME_SIZE
	most["replacement_name"] = module.NAME_SIZE
	most["subject_name"] = module.NAME_SIZE
	most["export"] = module.NAME_SIZE
	most["nickname"] = 23
	most["refusal_sentence"] = 119
	most["writer_refusal"] = len("Record_Stream_Without_Description")
	most["diagnostic"] = 143
	return most
}

// The folders of the modules of this file whose fact types the check of
// the Text fields reads here: the folders of the device services, remote
// and remote_display are read by device_facts_test.odin.
@(private = "file")
SYSTEM_MODULE_FACT_FOLDERS := [?]string{"debugger", "start_policy", "module_files", "date", "block", "boot", "pages", "host", "assemble", "c_compiler"}

// Each fact type of these modules with a Text field ends with its Text
// fields, and each Text field holds the longest text of its writer and a
// zero byte.
@(test)
the_texts_of_the_system_module_facts_come_last_and_whole :: proc(t: ^testing.T) {
	most := system_module_text_bytes_most()
	for folder in SYSTEM_MODULE_FACT_FOLDERS {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
		if ok {
			facts_expect_text_fields_last(t, file, most)
		}
	}
}

// A record of a fact type whose count of value bytes is not the size of
// its record is refused, one byte short and one byte past, and the buffer
// of the reader keeps its bytes: a reader never writes a sentence from a
// record of another description.
@(test)
a_record_of_another_size_is_refused :: proc(t: ^testing.T) {
	cases := [?]struct {
		folder, package_name, type_name: string,
	}{{"debugger", "debugger", "Thread_Stopped"}, {"start_policy", "start_policy", "Row_Restarted"}, {"date", "date_service", "Date_Read"}, {"c_compiler", "c_compiler", "Text_Written"}, {"network", "network_service", "Payload_Passes_Checked"}}
	for item in cases {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, item.folder}, context.temp_allocator))
		if !ok {
			continue
		}
		key, bytes, made := fact_test_record(t, file, item.package_name, item.type_name, {})
		if !made {
			continue
		}
		longer := make([]u8, len(bytes) + 1, context.temp_allocator)
		wrong_sizes := [2][]u8{bytes[:len(bytes) - 1], longer}
		for values in wrong_sizes {
			buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
			for &byte_value in buffer {
				byte_value = '#'
			}
			count, _, refusal := module.fact_sentence_write(file, key, values, buffer[:], nil)
			testing.expectf(t, refusal == .Value_Count && count == 0, "%s.%s with %d value bytes: %v, %d bytes", item.package_name, item.type_name, len(values), refusal, count)
			untouched := true
			for byte_value in buffer {
				if byte_value != '#' {
					untouched = false
				}
			}
			testing.expectf(t, untouched, "%s.%s: a refused record wrote into the buffer", item.package_name, item.type_name)
		}
	}
}

// Each fact type of the debugger writes the line of before, byte for byte:
// a process name of 31 bytes, the longest that its field holds, and of 1;
// the counts 0, 1 and max(u64); the sizes and times 0 to max(i64); each
// cause of a read that stopped and each end of a session.
@(test)
the_facts_of_the_debugger_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "debugger")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "debugger", type_name, values)
	}
	names := [2]string{strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator), "p"}
	hash, other: [module.HASH_SIZE]u8
	for index in 0 ..< module.HASH_SIZE {
		hash[index] = u8(0xE0 + index)
		other[index] = u8(index)
	}
	problems := [?]string{"the storage service gave no bytes before the deadline", "the storage service refused a read", "the storage service gave no byte before the end", "the storage service gave more bytes than the object has left"}
	ends := [?]string{"the debug access was revoked", "the caller detached", "the process stopped"}
	// The last kind has 28 bytes, the most that the text of an event holds.
	stop_kinds := [?]string{"int3", "step", "int1", "breakpoint 0", "breakpoint 0, watch 1, watch"}
	head :: "debugger: no debug object for "
	counts, edges := edges_make().counts, edges_make().sizes
	for name in names {
		facts_expect_line(t, render(t, file, "Debug_Object_Command_Not_Sent", {{"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the command to the root service was not sent"))
		facts_expect_line(t, render(t, file, "Stop_Report_Not_Mapped", {{"debugged_process", name}}), line_of_before("debugger: no stop report of ", sentence.Module_Name{name}, ": the page of the root service does not map"))
		facts_expect_line(t, render(t, file, "Debug_Object_Connection_Not_Opened", {{"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the connection to the store does not open"))
		facts_expect_line(t, render(t, file, "Late_Attach_Answer_While_Debugging", {{"debugged_process", name}}), line_of_before("debugger: the root service answered an earlier attach to ", sentence.Module_Name{name}, " after the export stopped waiting: its handle is closed, and the debugging that runs stays"))
		facts_expect_line(t, render(t, file, "Late_Attach_Answer", {{"debugged_process", name}}), line_of_before("debugger: the root service answered the attach to ", sentence.Module_Name{name}, " after the export stopped waiting: the debug access is given back"))
		facts_expect_line(t, render(t, file, "Debug_Object_Of_Another_Module", {{"module_hash", hash}, {"named_module", other}, {"debugged_process", name}}), line_of_before("debugger: refused the debug object ", sentence.Hash{hash[:]}, " of ", sentence.Module_Name{name}, ": it names the module ", sentence.Hash{other[:]}, ", not this module"))
		for problem in problems {
			facts_expect_line(t, render(t, file, "Debug_Object_Read_Stopped", {{"debugged_process", name}, {"problem", problem}}), line_of_before(head, sentence.Module_Name{name}, ": ", problem))
		}
		for end in ends {
			facts_expect_line(t, render(t, file, "Debugging_Ended", {{"debugged_process", name}, {"why", end}}), line_of_before("debugger: the debugging of ", sentence.Module_Name{name}, " ended: ", end))
		}
		for count in counts {
			facts_expect_line(t, render(t, file, "Debug_Object_Connection_Refused", {{"status_word", count}, {"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the root service refused the connection to the store, status word ", count))
			facts_expect_line(t, render(t, file, "Debug_Object_Absent", {{"principal", count}, {"module_hash", hash}, {"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the store ", "module_files", " of principal ", count, " has no object ", sentence.Hash{hash[:]}))
			facts_expect_line(t, render(t, file, "Attach_Ambiguous", {{"matches", count}, {"debugged_process", name}}), line_of_before("debugger: ", count, " processes have the name ", sentence.Module_Name{name}, " and the same module: the service cannot tell which one its handle names"))
			facts_expect_line(t, render(t, file, "Attach_Done", {{"threads", count}, {"modules", max(u64) - count}, {"described", count}, {"debugged_process", name}, {"caller", names[1]}}), line_of_before("debugger: attached to ", sentence.Module_Name{name}, " for ", sentence.Module_Name{names[1]}, ": ", count, " threads, ", max(u64) - count, " modules, ", count, " with a debug object"))
			facts_expect_line(t, render(t, file, "Step_Over_Ran_To_End", {{"thread", count}, {"debugged_process", name}}), line_of_before("debugger: the thread ", count, " of ", sentence.Module_Name{name}, " ran a call to its end, for step_over"))
			facts_expect_line(t, render(t, file, "Events_Lost", {{"stops", count}, {"debugged_process", name}}), line_of_before("debugger: ", count, " stops of ", sentence.Module_Name{name}, " found the table of the events full, and have no row"))
			facts_expect_line(t, render(t, file, "Stop_Report_Read", {{"frames", count}, {"named", max(u64) - count}, {"debugged_process", name}}), line_of_before("debugger: the stop report of ", sentence.Module_Name{name}, ": ", count, " frames, ", max(u64) - count, " named by the debug objects of their modules"))
			for stop_kind in stop_kinds {
				facts_expect_line(t, render(t, file, "Thread_Stopped", {{"thread", count}, {"debugged_process", name}, {"stop_kind", stop_kind}}), line_of_before("debugger: the thread ", count, " of ", sentence.Module_Name{name}, " stopped: ", stop_kind))
			}
		}
		for edge in edges {
			facts_expect_line(t, render(t, file, "Debug_Object_Connection_Silent", {{"bound", edge}, {"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the root service gave no connection to the store in ", edge, " ms"))
			facts_expect_line(t, render(t, file, "Debug_Object_Size_Silent", {{"bound", edge}, {"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the storage service gave no size in ", edge, " ms"))
			facts_expect_line(t, render(t, file, "Debug_Object_Size_Refused", {{"size", edge}, {"size_limit", max(u64)}, {"module_hash", hash}, {"debugged_process", name}}), line_of_before(head, sentence.Module_Name{name}, ": the object ", sentence.Hash{hash[:]}, " has ", edge, " bytes, and a debug object has 1 to ", max(u64)))
			facts_expect_line(t, render(t, file, "Debug_Object_Read", {{"principal", max(u64)}, {"size", edge}, {"module_hash", hash}, {"debugged_process", name}}), line_of_before("debugger: read the debug object ", sentence.Hash{hash[:]}, " of ", sentence.Module_Name{name}, " from the store ", "module_files", " of principal ", max(u64), ": ", edge, " bytes, checked whole"))
		}
	}
	for count in counts {
		facts_expect_line(t, render(t, file, "Root_Commands_Full", {{"capacity", count}}), line_of_before("debugger: ", count, " commands wait for the root service: no room for one more"))
	}
}

// Each fact type of the start policy writes the line of before, byte for
// byte: each stop cause, with each outcome for a stop of itself, and a
// cause word that names no member; the restarts 0 and max(u32), and the
// windows max(u32) to 0; each fault
// of a start list and each part of the machine.
@(test)
the_facts_of_the_start_policy_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "start_policy")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "start_policy", type_name, values)
	}
	names := [2]string{strings.repeat("r", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator), "r"}
	restarts := [3]u64{0, 1, u64(max(u32))}
	counts := edges_make().counts
	parts := [?]string{"screen", "data disk", "disk of the measures", "network device", "sound device", "entropy device", "TPM"}
	for name in names {
		for cause in op.Stop_Cause {
			for count in restarts {
				if cause == .Itself {
					for outcome in op.Stop_Outcome {
						stop := []Fact_Test_Field{{"cause", u64(cause)}, {"outcome", u64(outcome)}, {"row_process", name}}
						facts_expect_line(t, render(t, file, "Row_Stopped_Not_Restarted", stop), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], "; it does not start again"))
						facts_expect_line(t, render(t, file, "Row_Stopped_Past_Restarts", {{"restarts", count}, {"cause", u64(cause)}, {"outcome", u64(outcome)}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], "; past its ", count, " restarts, it stays stopped"))
						facts_expect_line(t, render(t, file, "Row_Restarted", {{"restarts_left", count}, {"cause", u64(cause)}, {"outcome", u64(outcome)}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], "; it starts again, ", count, " restarts left"))
					}
					continue
				}
				facts_expect_line(t, render(t, file, "Row_Stopped_Not_Restarted_Without_Outcome", {{"cause", u64(cause)}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], "; it does not start again"))
				facts_expect_line(t, render(t, file, "Row_Stopped_Past_Restarts_Without_Outcome", {{"restarts", count}, {"cause", u64(cause)}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], "; past its ", count, " restarts, it stays stopped"))
				facts_expect_line(t, render(t, file, "Row_Restarted_Without_Outcome", {{"restarts_left", count}, {"cause", u64(cause)}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], "; it starts again, ", count, " restarts left"))
			}
		}
		// A cause word that names no member: the render writes its number,
		// never the words of another member.
		past := u64(max(op.Stop_Cause)) + 1
		facts_expect_line(t, render(t, file, "Row_Restarted_Without_Outcome", {{"restarts_left", u64(1)}, {"cause", past}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " stopped: ", past, "; it starts again, ", u64(1), " restarts left"))
		for part in parts {
			facts_expect_line(t, render(t, file, "Row_Not_Started", {{"row_process", name}, {"missing_part", part}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " is not started: the machine has no ", part))
		}
		for count in restarts {
			facts_expect_line(t, render(t, file, "Needed_Row_Past_Restarts", {{"restarts", count}, {"restart_window_seconds", u64(max(u32)) - count}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " is past its ", count, " restarts in a window of ", u64(max(u32)) - count, " seconds, 0 for the whole run: the machine is not usable without it, and the start policy stops"))
		}
		facts_expect_line(t, render(t, file, "Machine_Not_Usable_Without", {{"row_process", name}}), line_of_before("start_policy: the machine is not usable without ", sentence.Module_Name{name}, ": the start policy stops before Machine_Usable"))
	}
	list_problems := [?]string{"it has no row", "a row has a mark that is neither needed nor not needed"}
	for count in counts {
		for list_problem in list_problems {
			facts_expect_line(t, render(t, file, "Start_List_Refused", {{"row", count}, {"list_problem", list_problem}}), line_of_before("start_policy: the start list is refused: ", list_problem, ", at its row ", count, ": no row starts"))
		}
		facts_expect_line(t, render(t, file, "Start_List_Read", {{"rows", count}}), line_of_before("start_policy: the start list has ", count, " rows: each starts in its order"))
		facts_expect_line(t, render(t, file, "Completion_Tag_Refused", {{"tag", count}}), line_of_before("start_policy: refused a completion of the tag ", count, ", which names no command in flight"))
		facts_expect_line(t, render(t, file, "Completion_Status_Refused", {{"outcome_word", count}}), line_of_before("start_policy: refused a completion of the root service that it cannot read: the outcome word ", count))
	}
}

// Each fact type of the module file service writes the line of before,
// byte for byte: an object name of 64 bytes, the longest of the store, and
// of 1; the longest address and a short one; the sizes 0 to max(i64).
@(test)
the_facts_of_the_module_file_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "module_files")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "module_files", type_name, values)
	}
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0xE0 + index)
	}
	file_names := [2]string{strings.repeat("m", 64, context.temp_allocator), "m"}
	counts, edges := edges_make().counts, edges_make().sizes
	addresses := [2]string{"255.255.255.255", "10.0.2.100"}
	failure_texts := failures()
	for failure in failure_texts {
		facts_expect_line(t, render(t, file, "Service_Failed", {{"failure", failure}}), line_of_before("module_files: ", failure))
	}
	for file_name in file_names {
		for size in edges {
			facts_expect_line(t, render(t, file, "File_Hashed", {{"size", size}, {"file_hash", hash}, {"file_name", file_name}}), line_of_before("module_files: the file ", sentence.Module_Name{file_name}, ", ", size, " bytes, the BLAKE3 hash of its bytes ", sentence.Hash{hash[:]}))
			facts_expect_line(t, render(t, file, "File_Not_Hashed", {{"size", size}, {"file_name", file_name}}), line_of_before("module_files: the file ", sentence.Module_Name{file_name}, ", ", size, " bytes, has no hash: its bytes did not come, or pass the 4194304 bytes of a module file"))
		}
	}
	for count in counts {
		facts_expect_line(t, render(t, file, "Files_Listed", {{"files", count}}), line_of_before("module_files: listed ", count, " module files of the store module_files, each hash computed on its bytes"))
		facts_expect_line(t, render(t, file, "Listing_Not_Ended", {{"listing_pages", count}}), line_of_before("module_files: the listing of the store module_files did not end after ", count, " pages"))
		for address in addresses {
			facts_expect_line(t, render(t, file, "Serving", {{"principal", count}, {"remote_port", max(u64) - count}, {"remote_address", address}}), line_of_before("module_files: serves the store module_files of principal ", count, ": a file from the web server ", address, " port ", max(u64) - count, ", and the list of the files with the hash of their bytes"))
		}
	}
}

// Each fact type of the date service writes the line of before, byte for
// byte: a zone of each sign; the times 0 to max(i64), and a negative move
// down to min(i64); one read and several.
@(test)
the_facts_of_the_date_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "date")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "date_service", type_name, values)
	}
	zones := [?]string{"+08:00", "-12:45", "+00:00"}
	for zone in zones {
		facts_expect_line(t, render(t, file, "Time_Zone_Written", {{"time_zone", zone}}), line_of_before("date: the time zone of the date page is ", zone, ", from the setting ", "time_zone"))
	}
	edges := edges_make().sizes
	moves := [?]i64{min(i64), -1, 0, 1, max(i64)}
	dates := [2]string{strings.repeat("9", 31, context.temp_allocator), "1970-01-01T00:00:00"}
	many_reads := [2]u64{2, max(u64)}
	for edge in edges {
		for move in moves {
			// The time since the start goes the other way, down to min(i64).
			back := move == min(i64) ? move : -move
			for utc_date in dates {
				facts_expect_line(t, render(t, file, "Date_Read", {{"seconds", signed_bits(move)}, {"clock_edge", edge}, {"start_time", edge}, {"utc_date", utc_date}}), line_of_before("date: ok, ", utc_date, " UTC, seconds since 1970 ", move, ", from the real-time clock at the time ", edge, " ms of the system; the date of the time 0 in ", edge, " us"))
			}
			facts_expect_line(t, render(t, file, "Clock_Read_Again_Once", {{"clock_edge", edge}, {"moved", signed_bits(move)}, {"since_start", signed_bits(back)}, {"reads", u64(1)}}), line_of_before("date: the clock read again at the time ", edge, " ms of the system: the date moved by ", move, " ms; ", back, " ms since the start, ", u64(1), " read", " after the first"))
			for reads in many_reads {
				facts_expect_line(t, render(t, file, "Clock_Read_Again", {{"clock_edge", edge}, {"moved", signed_bits(move)}, {"since_start", signed_bits(move)}, {"reads", reads}}), line_of_before("date: the clock read again at the time ", edge, " ms of the system: the date moved by ", move, " ms; ", move, " ms since the start, ", reads, " reads", " after the first"))
			}
		}
	}
}

// Each fact type of the windows boot and pages, of the call host, of the
// assembler and of the C compiler writes the line of before, byte for
// byte, at the counts 0, 1 and max(u64) and the sizes 0 to max(i64), and
// a word of the C entry down to min(i64).
@(test)
the_facts_of_the_small_modules_write_the_lines_of_before :: proc(t: ^testing.T) {
	files: [5][]u8
	folders := [5]string{"boot", "pages", "host", "assemble", "c_compiler"}
	counts, edges := edges_make().counts, edges_make().sizes
	words := [?]i64{min(i64), -1, 0, 1, max(i64)}
	for folder, index in folders {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
		if !ok {
			return
		}
		files[index] = file
	}
	for count in counts {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, files[0], "boot", "Boot_Shown", {{"stages", count}, {"memory_ranges", other}, {"processes", count}}), line_of_before("boot: ok, ", count, " stages, ", other, " memory ranges, ", count, " processes"))
		facts_expect_line(t, fact_test_render(t, files[2], "host", "Ready", {{"exports", count}}), line_of_before("host: ready, ", count, " exports"))
		for size in edges {
			facts_expect_line(t, fact_test_render(t, files[1], "pages", "Kernel_Half_Read", {{"mapped", size}, {"runs", count}, {"write_execute_pages", other}, {"guard_pages", count}, {"guards_expected", other}}), line_of_before("pages: the kernel half: ", size, " pages in ", count, " runs, ", other, " write and execute, ", count, " guard pages of ", other))
			facts_expect_line(t, fact_test_render(t, files[1], "pages", "Process_Half_Read", {{"mapped", size}, {"runs", count}, {"write_execute_pages", other}}), line_of_before("pages: this process: ", size, " pages in ", count, " runs, ", other, " write and execute"))
			facts_expect_line(t, fact_test_render(t, files[3], "assemble", "Module_File_Written", {{"size", size}, {"exports", count}}), line_of_before("assemble: a module file of ", size, " bytes with ", count, " exports"))
			facts_expect_line(t, fact_test_render(t, files[4], "c_compiler", "Text_Written", {{"size", size}}), line_of_before("c_compiler: a text of ", size, " bytes"))
		}
	}
	for word in words {
		facts_expect_line(t, fact_test_render(t, files[4], "c_compiler", "Entry_Word_Refused", {{"word", signed_bits(word)}}), line_of_before("c_compiler: the C entry gave the word ", word, ", which names no result"))
	}
}

// Each fact type that the services of the devices and of the network,
// remote and remote_display wrote as text after the facts of their group
// writes the line of before, byte for byte: a failure of the longest that
// its field holds and of one byte; the counts 0, 1 and max(u64); the sizes
// and times 0 to max(i64); each case of a sentence.
@(test)
the_late_facts_of_the_device_services_write_the_lines_of_before :: proc(t: ^testing.T) {
	Late_Module :: struct {
		folder, package_name, head: string,
	}
	modules := [?]Late_Module{{"tpm", "tpm_device_service", "tpm: "}, {"remote_display", "remote_display_service", "remote_display: "}, {"remote", "remote_service", "remote: "}, {"sound", "sound_device_service", "sound: "}, {"network", "network_service", "network: "}, {"block", "block_service", "block: "}, {"entropy", "entropy_device_service", "entropy: "}, {"frame", "frame_service", "frame: "}}
	files: [len(modules)][]u8
	failure_texts := failures()
	counts, edges := edges_make().counts, edges_make().sizes
	protocols := [2]string{"TCP", "UDP"}
	interface_addresses := [2]string{"255.255.255.255/24 ff:ff:ff:ff:ff:ff", "10.0.2.15/24 52:54:00:12:34:56"}
	for item, index in modules {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, item.folder}, context.temp_allocator))
		if !ok {
			return
		}
		files[index] = file
		for failure in failure_texts {
			facts_expect_line(t, fact_test_render(t, file, item.package_name, "Service_Failed", {{"failure", failure}}), line_of_before(item.head, failure))
		}
	}
	tpm, remote_display, remote, sound, network, block, frame := files[0], files[1], files[2], files[3], files[4], files[5], files[7]
	key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	owners := [2]string{strings.repeat("o", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator), "o"}
	facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Public_Key_Made", {{"public_key", key}}), line_of_before("remote_display: the public key of this service: ", key))
	facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Public_Key_Made", {{"public_key", key}}), line_of_before("remote: the public key of this service: ", key))
	for count in counts {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, tpm, "tpm_device_service", "Count_Limits", {{"lockout_failures", count}, {"forgive_interval_seconds", other}, {"counted_failures", count}, {"lockout_recovery_seconds", other}}), line_of_before("tpm: the count limits of the TPM: a lockout after ", count, " wrong authorization values, one forgiven each ", other, " seconds; ", count, " counted now; the lockout hierarchy waits ", other, " seconds after a wrong value of its own"))
		for word in status_words() {
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Budget_Answer_Refused", {{"status", word}}), line_of_before("remote_display: the root service refused a command of the budgets of the screen of memory: status ", status_text(word)))
		}
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Budget_Not_Taken", {{"width", count}, {"height", other}}), line_of_before("remote_display: closed an extra budget for ", count, " x ", other, " with no use: it has no number, or two are held already"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Change_Reverted", {{"width", count}, {"height", other}, {"back_width", other}, {"back_height", count}}), line_of_before("remote_display: no copies of the screen of ", count, " x ", other, ": the screen goes back to ", other, " x ", count))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Changed", {{"width", count}, {"height", other}, {"viewers", count}}), line_of_before("remote_display: the screen is now ", count, " x ", other, ": ", count, " viewers receive its size and the whole screen"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Size_Refusal_Refused", {{"width", count}, {"height", other}, {"refusal_word", count}}), line_of_before("remote_display: refused an answer of the compositor: a refusal of ", count, " x ", other, " with the word ", count, ", which no ask in flight names or which names no cause"))
		for cause in memory_screen.RESIZE_REFUSAL_SENTENCES {
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Size_Ask_Refused", {{"width", count}, {"height", other}, {"viewer_key_head", "0123456789abcdef"}, {"resize_refusal", cause}}), line_of_before("remote_display: refused the screen of ", count, " x ", other, " that the viewer 0123456789abcdef asked: ", cause))
		}
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Past_Largest", {{"width", count}, {"height", other}}), line_of_before("remote_display: the screen of ", count, "x", other, " is past the largest screen of the protocol, 7680x4320: no capture face"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Face_Opened", {{"width", count}, {"height", other}}), line_of_before("remote_display: the capture face is open: a copy of ", count, "x", other))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Viewers_Ended_With_No_Screen", {{"viewers", count}}), line_of_before("remote_display: ended ", count, " viewers with the code Screen_Not_Held: the capture face of the screen in force was refused"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Face_Closed", {{"pictures", count}}), line_of_before("remote_display: no viewer: the capture face is closed, after ", count, " pictures of the compositor"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Listening", {{"listen_port", count}, {"viewer_capacity", other}}), line_of_before("remote_display: listening on the UDP port ", count, ", for the host 10.0.2.2 only, and for the viewer keys that a principal allowed: ", other, " viewers at one time"))
		facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Listening", {{"listen_port", count}, {"connection_capacity", other}, {"calls_per_connection", count}}), line_of_before("remote: listening on the UDP port ", count, ", for the host 10.0.2.2 only, and for the client keys that a principal allowed: ", other, " connections, each with ", count, " calls at one time"))
		for edge in edges {
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Whole_Screen_Measured", {{"width", count}, {"height", other}, {"screen_pieces", count}, {"piece_bytes", edge}, {"pixel_bytes", edge}, {"coded_time", edge}, {"taken_time", edge}}), line_of_before("remote_display: a measure: the whole screen of ", count, "x", other, " in one viewer frame: ", count, " screen pieces, ", edge, " bytes of screen pieces for ", edge, " bytes of pixels, coded in ", edge, " us, taken by the viewer ", edge, " us after its start"))
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Small_Damage_Measured", {{"pixels", count}, {"frames", other}, {"median_size", edge}, {"median_time", edge}, {"least_size", edge}, {"least_time", edge}}), line_of_before("remote_display: a measure: viewer frames of a small damage (at most ", count, " pixels), the median of ", other, ": ", edge, " bytes of screen pieces, ", edge, " us from Viewer_Frame_Start in the stream to Viewer_Frame_Taken; the least ", edge, " bytes and ", edge, " us"))
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Memory_Refused", {{"width", count}, {"height", other}, {"pages", edge}}), line_of_before("remote_display: no capture face for the screen of ", count, "x", other, ": its two pictures and its copy need ", edge, " pages, which the budget of this process does not give"))
			facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Window_Drawn", {{"picture_time", edge}}), line_of_before("remote: the window drew one picture in ", edge, " us"))
			facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Interface_Measured", {{"records", count}, {"damage_rectangles", other}, {"build_time", edge}, {"difference_time", edge}, {"draw_time", edge}}), line_of_before("remote: the interface: ", count, " records, ", other, " damage rectangles; build ", edge, " us, difference ", edge, " us, draw ", edge, " us"))
			facts_expect_line(t, fact_test_render(t, sound, "sound_device_service", "Stream_Started", {{"frame_zero_time", edge}, {"held_time", edge}}), line_of_before("sound: the stream started: the frame 0 plays at ", edge, " ns of the system clock; the service holds ", edge, " ns"))
			facts_expect_line(t, fact_test_render(t, network, "network_service", "Headers_Measured", {{"payload_size", edge}, {"header_time", edge}}), line_of_before("network: the headers of IPv4 and Ethernet of a frame with a payload of ", edge, " bytes: ", edge, " ns, in this process (no checksum of the payload)"))
			facts_expect_line(t, fact_test_render(t, frame, "frame_service", "Read_Region_Added", {{"region_size", edge}, {"place", count}}), line_of_before("frame: a read region of ", edge, " pages at the place ", count, ", held with the right Read only: the device reads the data of the frames to send there"))
			facts_expect_line(t, fact_test_render(t, block, "block_service", "Ready_With_Flush", {{"disk_size", edge}, {"queue_size", count}, {"requests_in_flight", other}}), line_of_before("block: ok, ", edge, " blocks of 4096 bytes, a queue of ", count, ", ", other, " requests in flight at most, flush: ", "yes"))
			facts_expect_line(t, fact_test_render(t, block, "block_service", "Ready_Without_Flush", {{"disk_size", edge}, {"queue_size", count}, {"requests_in_flight", other}}), line_of_before("block: ok, ", edge, " blocks of 4096 bytes, a queue of ", count, ", ", other, " requests in flight at most, flush: ", "no"))
			for owner in owners {
				for protocol in protocols {
					head := []sentence.Part{"network: the endpoint of ", owner, ", ", protocol, ": this service read each payload byte one time on receive, for the copy, and on send only the ", edge, " bytes of each header that it checks, and ", edge, " bytes of the data; it computed no checksum"}
					facts_expect_line(t, fact_test_render(t, network, "network_service", "Payload_Passes_Checked", {{"header_bytes", edge}, {"data_bytes_read", edge}, {"owner", owner}, {"protocol", protocol}}), line_of_before(..append_parts(head, ": as it must")))
					facts_expect_line(t, fact_test_render(t, network, "network_service", "Payload_Passes_Wrong", {{"header_bytes", edge}, {"data_bytes_read", edge}, {"owner", owner}, {"protocol", protocol}}), line_of_before(..append_parts(head, " (WRONG)")))
				}
			}
		}
		for address in interface_addresses {
			facts_expect_line(t, fact_test_render(t, network, "network_service", "Ready_Link_Up", {{"receive_places", count}, {"interface_address", address}}), line_of_before("network: ok, the address ", address, ", the gateway 10.0.2.2, the link is ", "up", ", ", count, " places for frames that arrive"))
			facts_expect_line(t, fact_test_render(t, network, "network_service", "Ready_Link_Down", {{"receive_places", count}, {"interface_address", address}}), line_of_before("network: ok, the address ", address, ", the gateway 10.0.2.2, the link is ", "down", ", ", count, " places for frames that arrive"))
		}
	}
}

// append_parts gives the parts of a line and one more part after them.
@(private = "file")
append_parts :: proc(parts: []sentence.Part, last: sentence.Part) -> []sentence.Part {
	joined := make([]sentence.Part, len(parts) + 1, context.temp_allocator)
	copy(joined, parts)
	joined[len(parts)] = last
	return joined
}

// A fact type with no field of the modules of this file, and the line that
// its writer wrote before.
@(private = "file")
Line_Without_Value :: struct {
	folder, package_name, type_name, line: string,
}

// Each fact type with no field writes the line of before, byte for byte:
// its sentence is its template, and a record of one byte is refused.
@(test)
the_facts_with_no_value_write_the_lines_of_before :: proc(t: ^testing.T) {
	lines := [?]Line_Without_Value {
		{"tpm", "tpm_device_service", "Shutdown_Done", "tpm: TPM2_Shutdown after the use of an authorization value: a stop of the machine now makes the TPM count no failure"},
		{"tpm", "tpm_device_service", "Unseal_Creation_Data_Refused", "tpm: refused the unseal: the creation data does not name PCR 7 and PCR 11 with a digest"},
		{"tpm", "tpm_device_service", "Unseal_Policy_Refused", "tpm: refused the unseal: the policy of the object is not the policy of the PCR values of its creation, or its attributes are not the attributes of a sealed object"},
		{"tpm", "tpm_device_service", "Unsealed_With_Authorization", "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right"},
		{"tpm", "tpm_device_service", "Unsealed", "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal"},
		{"tpm", "tpm_device_service", "No_Rate_Limit", "tpm: the TPM limits no rate of the wrong authorization values: its lockout interval is 0"},
		{"tpm", "tpm_device_service", "Lockout_Not_Checked", "tpm: the lockout hierarchy is not checked: another system can reset the count of the TPM while its value is empty"},
		{"tpm", "tpm_device_service", "Lockout_Authorization_Found", "tpm: the lockout hierarchy has an authorization value: an earlier start of this system set it, or another system did; this service keeps no copy of it and leaves it"},
		{"tpm", "tpm_device_service", "Lockout_Kept_Empty_Without_Seed", "tpm: the lockout hierarchy keeps its empty authorization value: this process has no seed, and another system can reset the count of the TPM"},
		{"tpm", "tpm_device_service", "Lockout_Kept_Empty_Weak_Seed", "tpm: the lockout hierarchy keeps its empty authorization value: the seed of this process is too weak for a key, and another system can reset the count of the TPM"},
		{"tpm", "tpm_device_service", "Lockout_Change_Answer_Malformed", "tpm: the answer of the TPM to TPM2_HierarchyChangeAuth of the lockout hierarchy does not have its form: the next start reads the state of the hierarchy again"},
		{"tpm", "tpm_device_service", "Lockout_Authorization_Set", "tpm: the lockout hierarchy had an empty authorization value: this service set a random one and kept no copy, so no system resets the count of the TPM or changes its limits"},
		{"tpm", "tpm_device_service", "No_Measure_Ring", "tpm: no measure ring: no start policy is measured into PCR 12"},
		{"tpm", "tpm_device_service", "Completion_Lost", "tpm: the completion queue of a ring of the TPM service is full: a completion is lost"},
		{"debugger", "debugger", "No_Service_Ring", "debugger: no service ring"},
		{"debugger", "debugger", "Serving", "debugger: serves its exports"},
		{"storage", "storage_service", "No_Seed", "storage: no seed in the context of the process"},
		{"storage", "storage_service", "No_Service_Ring", "storage: no service ring"},
		{"storage", "storage_service", "No_Block_Ring", "storage: no block ring"},
		{"storage", "storage_service", "No_Block_Service_Handle", "storage: no handle of the block service with the right Read: a wait for the disk would have no end"},
		{"storage", "storage_service", "No_Data_Region", "storage: no data region"},
		{"storage", "storage_service", "Data_Region_Refused", "storage: the block service refused the data region"},
		{"storage", "storage_service", "No_Valid_Root", "storage: no valid root on the disk: the service keeps the disk as it is, and serves nothing"},
		{"storage", "storage_service", "First_Root_Cut", "storage: the first root of the disk has a wrong check and no commit followed it: a format that a stop cut; the service formats again"},
		{"storage", "storage_service", "Newest_Root_Refused", "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used"},
		{"start_policy", "start_policy", "No_Start_List", "start_policy: the context names no start list: no row starts"},
		{"start_policy", "start_policy", "Machine_Parts_Page_Refused", "start_policy: the machine parts page is refused: no row starts"},
		{"start_policy", "start_policy", "Machine_Usable", "start_policy: each needed row runs: the machine is usable"},
		{"remote_display", "remote_display_service", "Screen_Budget_Release_Not_Sent", "remote_display: the root ring has no room for the release of the extra budget of the screen of memory: its pages return at the stop of this process"},
		{"remote_display", "remote_display_service", "Screen_Budget_Release_Not_Sent", "remote_display: the root ring has no room for the release of the extra budget of the screen of memory: its pages return at the stop of this process"},
		{"remote_display", "remote_display_service", "Capture_Memory_Not_Given", "remote_display: the memory of the capture face does not map, or the compositor does not take it"},
		{"remote", "remote_service", "Seed_Weak", "remote: the random seed of this process is weak: it makes no key, and listens on nothing"},
		{"module_files", "module_files", "Listing_Store_Answer_Refused", "module_files: the store module_files refused the listing of its root tree: the storage service gave no answer that its export allows"},
		{"module_files", "module_files", "Listing_Entry_Name_Refused", "module_files: the store module_files refused the listing of its root tree: an entry has a name out of its page: the storage service gave no answer that its export allows"},
		{"module_files", "module_files", "Listing_Entry_Kind_Refused", "module_files: the store module_files refused the listing of its root tree: an entry has a kind that names no kind: the storage service gave no answer that its export allows"},
		{"sound", "sound_device_service", "First_Hold", "sound: the first hold: the device took the periods faster than their time; the service gives the next one when the time comes, and counts each hold"},
		{"sound", "sound_device_service", "First_Underrun", "sound: the first underrun: the device took each period before the next one came; the next frame plays now, and each completion counts the underruns"},
		{"network", "network_service", "Frame_Ring_Full", "network: the frame ring is full"},
		{"input", "input", "No_Ring", "input: no ring"},
		{"input", "input", "No_Controller", "input: no PS/2 controller: no keyboard and no mouse"},
		{"input", "input", "Ready_Mouse_Without_Wheel", "input: ok, the mouse has no wheel"},
		{"input", "input", "Ready_Mouse_With_Wheel", "input: ok, the mouse has a wheel"},
		{"input", "input", "Input_Ring_Full", "input: the input ring is full: the keyboard controller keeps its bytes"},
		{"input", "input", "Input_Ring_Room_Again", "input: the input ring has room again"},
		{"host", "host", "No_Call_Ring_Or_Region", "host: no call ring or no call region"},
		{"host", "host", "Call_Region_Without_Size", "host: the call region has no size"},
		{"date", "date_service", "No_Date_Page_Or_Clock", "date: no date page or no ports of the clock: the system has no date"},
		{"date", "date_service", "Clock_Date_Not_Valid", "date: the real-time clock gives no valid date: the system has no date"},
		{"pages", "pages", "Rules_Kept", "pages: ok, the page tables keep the rules"},
		{"pages", "pages", "Rules_Not_Kept", "pages: failed, the page tables do not keep the rules"},
		{"pages", "pages", "Kernel_Guard_Present", "pages: the processor refuses the memory of processes to the kernel"},
		{"pages", "pages", "Kernel_Guard_Absent", "pages: the processor has no guard for the memory of processes"},
		{"c_compiler", "c_compiler", "Second_Source_Refused", "c_compiler: a call host compiles one source: unload the module and isolate it again"},
	}
	for item in lines {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, item.folder}, context.temp_allocator))
		if !ok {
			continue
		}
		facts_expect_line(t, fact_test_render(t, file, item.package_name, item.type_name, {}), item.line)
		// One value byte where the record has none: the reader refuses it.
		key := fact_key(item.package_name, item.type_name)
		one_byte := [1]u8{0}
		buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
		count, _, refusal := module.fact_sentence_write(file, key, one_byte[:], buffer[:], nil)
		testing.expectf(t, refusal == .Value_Count && count == 0, "%s.%s with one value byte: %v, %d bytes", item.package_name, item.type_name, refusal, count)
	}
}

// status_words gives the words of a status of the kernel: each member, and
// one word past the last member, which a reader writes as its number.
@(private = "file")
status_words :: proc() -> []u64 {
	words := make([dynamic]u64, context.temp_allocator)
	for status in op.Status {
		append(&words, u64(status))
	}
	append(&words, u64(max(op.Status)) + 1)
	return words[:]
}

// status_text gives the words of a status in a sentence: the name of its
// member, or its number for a word that names no member.
@(private = "file")
status_text :: proc(word: u64) -> string {
	if name, named := module.contract_enum_member_name(.Status, word); named {
		return name
	}
	return fmt.tprintf("%d", word)
}

// Each fact type of a status of the kernel writes the status by the name
// of its member, where the line wrote its number: each member, and a word
// that names no member, which stays its number.
@(test)
the_facts_of_a_status_write_the_name_of_its_member :: proc(t: ^testing.T) {
	folders := [?]string{"debugger", "start_policy", "sound", "entropy"}
	files: [len(folders)][]u8
	for folder, index in folders {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
		if !ok {
			return
		}
		files[index] = file
	}
	debugger, start_policy, sound, entropy := files[0], files[1], files[2], files[3]
	name := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	// The refusals of the root service that the start policy writes: the
	// outcome by its name, or the number of a word that names none.
	for outcome_word in ([3]u64{u64(min(call_outcome.Call_Outcome)), u64(max(call_outcome.Call_Outcome)), u64(max(call_outcome.Call_Outcome)) + 1}) {
		outcome_text := line_of_before(outcome_word)
		if outcome_name, named := module.contract_enum_member_name(.Call_Outcome, outcome_word); named {
			outcome_text = outcome_name
		}
		facts_expect_line(t, fact_test_render(t, start_policy, "start_policy", "Machine_Usable_Refused", {{"outcome", outcome_word}}), line_of_before("start_policy: the root service refused Machine_Usable: outcome ", outcome_text))
		facts_expect_line(t, fact_test_render(t, start_policy, "start_policy", "Row_Start_Refused", {{"outcome", outcome_word}, {"row_process", name}}), line_of_before("start_policy: cannot start ", sentence.Module_Name{name}, ": outcome ", outcome_text))
		facts_expect_line(t, fact_test_render(t, start_policy, "start_policy", "Row_List_Page_Refused", {{"outcome", outcome_word}, {"row_process", name}}), line_of_before("start_policy: ", sentence.Module_Name{name}, " does not start: the root service refused its list page with the outcome ", outcome_text))
	}
	edges := edges_make().sizes
	words := status_words()
	for word in words {
		other := words[len(words) - 1 - int(word % u64(len(words)))]
		status, other_status := status_text(word), status_text(other)
		for size in edges {
			facts_expect_line(t, fact_test_render(t, debugger, "debugger", "Debug_Object_Memory_Refused", {{"size", size}, {"status", word}, {"debugged_process", name}}), line_of_before("debugger: no debug object for ", sentence.Module_Name{name}, ": no memory for its ", size, " bytes: status ", status))
		}
		facts_expect_line(t, fact_test_render(t, debugger, "debugger", "Debug_Object_Map_Refused", {{"status", word}, {"debugged_process", name}}), line_of_before("debugger: no debug object for ", sentence.Module_Name{name}, ": its memory does not map: status ", status))
		facts_expect_line(t, fact_test_render(t, start_policy, "start_policy", "Root_Ring_Refused", {{"status", word}}), line_of_before("start_policy: the root ring does not open: status ", status))
		facts_expect_line(t, fact_test_render(t, sound, "sound_device_service", "Queues_Not_Mapped", {{"map_status", word}, {"address_status", other}}), line_of_before("sound: the map of the queues gave the status ", status, ", their device address the status ", other_status))
		facts_expect_line(t, fact_test_render(t, sound, "sound_device_service", "Periods_Memory_Refused", {{"status", word}}), line_of_before("sound: the memory of the periods gave the status ", status))
		facts_expect_line(t, fact_test_render(t, sound, "sound_device_service", "Periods_Not_Mapped", {{"map_status", word}, {"address_status", other}}), line_of_before("sound: the map of the periods gave the status ", status, ", their device address the status ", other_status))
		facts_expect_line(t, fact_test_render(t, entropy, "entropy_device_service", "Queue_Not_Mapped", {{"map_status", word}, {"address_status", other}}), line_of_before("entropy: the map of the queue gave the status ", status, ", its device address the status ", other_status))
	}
	// A word of 8 bytes past every member of u32 stays its number too.
	far := u64(max(u32)) + 1
	facts_expect_line(t, fact_test_render(t, debugger, "debugger", "Debug_Object_Map_Refused", {{"status", far}, {"debugged_process", name}}), line_of_before("debugger: no debug object for ", sentence.Module_Name{name}, ": its memory does not map: status ", far))
}

// error_record_text gives the words of the fields of an error record, as
// the fact of an error record writes them after the words of its module.
@(private = "file")
error_record_text :: proc(record: errors.Error_Record) -> string {
	kind := record.kind >= 0 && record.kind <= i64(max(errors.Kind)) ? errors.KIND_NAMES[errors.Kind(record.kind)] : fmt.tprintf("%d", u64(record.kind))
	unit := record.unit >= 0 && record.unit <= i64(max(errors.Unit)) ? errors.UNIT_MEMBER_NAMES[errors.Unit(record.unit)] : fmt.tprintf("%d", u64(record.unit))
	return fmt.tprintf("kind %s, unit %s, operation %d, argument %d, value %d, limit %d, found %d", kind, unit, record.operation, record.argument, record.value, record.limit, record.found)
}

// The values of an error record as the fields of a fact.
@(private = "file")
error_record_fields :: proc(record: errors.Error_Record) -> [7]Fact_Test_Field {
	return {{"kind", u64(record.kind)}, {"unit", u64(record.unit)}, {"operation", u64(record.operation)}, {"argument", u64(record.argument)}, {"value", u64(record.value)}, {"limit", u64(record.limit)}, {"found", u64(record.found)}}
}

// Each fact of an error record writes the words of its module, then the
// values of the record with the kind and the unit by the names of their
// members: the records of the waits of the remote test, a record at the
// edges of each value, and a kind and a unit that name no member, which
// stay their numbers.
@(test)
the_facts_of_an_error_record_write_its_fields :: proc(t: ^testing.T) {
	folders := [?]string{"storage", "remote", "module_files"}
	files: [len(folders)][]u8
	for folder, index in folders {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
		if !ok {
			return
		}
		files[index] = file
	}
	storage, remote, module_files := files[0], files[1], files[2]
	records := [?]errors.Error_Record {
		{kind = i64(errors.Kind.Too_Small), unit = i64(errors.Unit.Bytes), value = 20, limit = 104},
		{kind = i64(errors.Kind.Bad_Value), argument = 1, value = 9, limit = 1},
		{kind = i64(errors.Kind.No_Grant), unit = i64(errors.Unit.Connection), argument = 3},
		{kind = i64(max(errors.Kind)), unit = i64(max(errors.Unit)), operation = max(i64), argument = min(i64), value = -1, limit = max(i64), found = min(i64)},
		{kind = i64(max(errors.Kind)) + 1, unit = i64(max(errors.Unit)) + 1},
		{kind = -1, unit = -1},
	}
	nicknames := [2]string{strings.repeat("n", 23, context.temp_allocator), "n"}
	for record in records {
		fields := error_record_fields(record)
		words := error_record_text(record)
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Block_Request_Refused", fields[:]), strings.concatenate({"storage: the block service refused a request: ", words}, context.temp_allocator))
		facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Request_Refused", fields[:]), strings.concatenate({"remote: refused a request: ", words}, context.temp_allocator))
		facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Request_Refused_Last_Logged", fields[:]), strings.concatenate({"remote: refused a request, and counts the next refusals only: ", words}, context.temp_allocator))
		facts_expect_line(t, fact_test_render(t, module_files, "module_files", "Listing_Store_Refused", fields[:]), strings.concatenate({"module_files: the store module_files refused the listing of its root tree: ", words}, context.temp_allocator))
		for nickname in nicknames {
			with_name := make([dynamic]Fact_Test_Field, context.temp_allocator)
			append(&with_name, ..fields[:])
			append(&with_name, Fact_Test_Field{"nickname", nickname})
			facts_expect_line(t, fact_test_render(t, module_files, "module_files", "File_Store_Refused", with_name[:]), strings.concatenate({"module_files: the store module_files refused the file ", nickname, ": ", words}, context.temp_allocator))
		}
	}
	// The words of the waits of the remote test, written out.
	too_small, no_grant := error_record_fields(records[0]), error_record_fields(records[2])
	facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Request_Refused", too_small[:]), "remote: refused a request: kind Too_Small, unit Bytes, operation 0, argument 0, value 20, limit 104, found 0")
	facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Request_Refused", no_grant[:]), "remote: refused a request: kind No_Grant, unit Connection, operation 0, argument 3, value 0, limit 0, found 0")
	for nickname in nicknames {
		facts_expect_line(t, fact_test_render(t, module_files, "module_files", "File_Store_Answer_Refused", {{"nickname", nickname}}), line_of_before("module_files: the store module_files refused ", "the file ", sentence.Module_Name{nickname}, ": ", "the storage service gave no answer that its export allows"))
	}
}

// Each fact type of a line with a response code of the TPM, an address, a
// fault of a debug object, a code of a connection, a measure in
// hundredths, a refusal of the assembler and a line of the C compiler
// writes the line of before, byte for byte.
@(test)
the_late_facts_of_round_two_write_the_lines_of_before :: proc(t: ^testing.T) {
	folders := [?]string{"tpm", "debugger", "storage", "remote", "network", "assemble", "c_compiler"}
	files: [len(folders)][]u8
	for folder, index in folders {
		file, ok := facts_file_of_folder(t, strings.concatenate({foundation.SYSTEM_MODULE_SOURCES, folder}, context.temp_allocator))
		if !ok {
			return
		}
		files[index] = file
	}
	tpm, debugger, storage, remote, network, assemble, c_compiler := files[0], files[1], files[2], files[3], files[4], files[5], files[6]
	counts, edges := edges_make().counts, edges_make().sizes
	codes := [3]u64{0, 0x922, max(u64)}
	all_properties := [2]string{"the state of the hierarchies", "p"}
	peers := [2]string{"255.255.255.255 port 65535", "10.0.2.2 port 7100"}
	reasons := [?]string{"the handshake deadline", "the idle timeout", "closed by the host", "closed by this service"}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, code: u64) -> string {
		return fact_test_render(t, file, "tpm_device_service", type_name, {{"response_code", code}})
	}
	for code in codes {
		hex := sentence.Hex(code)
		facts_expect_line(t, render(t, tpm, "Shutdown_Refused", code), line_of_before("tpm: the TPM refused TPM2_Shutdown after a use of an authorization value (response code ", hex, "); the next start of the TPM can count one failure"))
		facts_expect_line(t, render(t, tpm, "Unseal_Ticket_Refused", code), line_of_before("tpm: refused the unseal: the TPM refuses the creation ticket of the object (response code ", hex, "): this TPM did not make it so"))
		facts_expect_line(t, render(t, tpm, "Unseal_Pcr_Values_Refused", code), line_of_before("tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal (response code ", hex, ")"))
		facts_expect_line(t, render(t, tpm, "Unseal_Authorization_Wrong", code), line_of_before("tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code ", hex, ")"))
		facts_expect_line(t, render(t, tpm, "Unseal_Locked_Out", code), line_of_before("tpm: the TPM refuses the unseal: it counted too many wrong authorization values, and refuses each try for now (response code ", hex, ")"))
		facts_expect_line(t, render(t, tpm, "Extend_Refused", code), line_of_before("tpm: the TPM refused the extend of PCR 12 (response code ", hex, ")"))
		facts_expect_line(t, render(t, tpm, "Extend_Read_Back_Refused", code), line_of_before("tpm: extended PCR 12, and its read back gave no value of PCR 12 of SHA-256 (response code ", hex, ")"))
		facts_expect_line(t, render(t, tpm, "Lockout_Authorization_Refused", code), line_of_before("tpm: the TPM refused a lockout authorization value (response code ", hex, "): the lockout hierarchy keeps its empty one until the next start, and another system can reset the count of the TPM"))
		for properties in all_properties {
			facts_expect_line(t, fact_test_render(t, tpm, "tpm_device_service", "Capability_Refused", {{"response_code", code}, {"properties", properties}}), line_of_before("tpm: the TPM refused TPM2_GetCapability of ", properties, " (response code ", hex, ")"))
		}
		for size in edges {
			facts_expect_line(t, fact_test_render(t, tpm, "tpm_device_service", "Ready", {{"registers_address", code}, {"buffer_size", size}}), line_of_before("tpm: ok, the CRB interface at ", hex, ", a buffer of ", size, " bytes; it seals to PCR 7 and PCR 11"))
		}
		// A code of a connection of remote, of each kind of its close.
		for peer in peers {
			for reason in reasons {
				for size in edges {
					values := []Fact_Test_Field{{"close_code", code}, {"bytes_in", size}, {"bytes_out", size}, {"peer", peer}, {"end_reason", reason}}
					facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Connection_Ended", values), line_of_before("remote: ", peer, " ended (", reason, ", the code ", hex, "", "): in ", size, " bytes, out ", size, " bytes"))
					facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Connection_Ended_By_Application", values), line_of_before("remote: ", peer, " ended (", reason, ", the code ", hex, " of the application", "): in ", size, " bytes, out ", size, " bytes"))
				}
			}
		}
	}

	// A refused debug object: the sentence of each fault of its check.
	name := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0xE0 + index)
	}
	for fault in debug_object.Fault {
		if fault == .None {
			continue
		}
		type_name := fmt.tprintf("Debug_Object_Refused_%v", fault)
		facts_expect_line(t, fact_test_render(t, debugger, "debugger", type_name, {{"module_hash", hash}, {"debugged_process", name}}), line_of_before("debugger: refused the debug object ", sentence.Hash{hash[:]}, " of ", sentence.Module_Name{name}, ": ", debug_object.fault_sentences[fault]))
	}
	// The status of the client of the storage service, a contract enum: each
	// member by its name, and a word past the last member by its number.
	storage_words := make([dynamic]u64, context.temp_allocator)
	for status in storage_status.Status {
		append(&storage_words, u64(status))
	}
	append(&storage_words, u64(max(storage_status.Status)) + 1, u64(max(u8)))
	for word in storage_words {
		status, named := module.contract_enum_member_name(.Storage_Status, word)
		if !named {
			status = fmt.tprintf("%d", word)
		}
		facts_expect_line(t, fact_test_render(t, debugger, "debugger", "Debug_Object_Size_Status_Refused", {{"status", word}, {"module_hash", hash}, {"debugged_process", name}}), line_of_before("debugger: no debug object for ", sentence.Module_Name{name}, ": the storage service refused the size of ", sentence.Hash{hash[:]}, ", status ", status))
	}

	// The fault of the engine and the erase of versions of the storage
	// service.
	store := strings.repeat("s", 31, context.temp_allocator)
	object := strings.repeat("o", 64, context.temp_allocator)
	for count in counts {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Engine_Fault_In_One_Store", {{"named_twice", count}, {"named_by_two_stores", other}, {"reference_overflow", count}, {"faulty_stores", u64(1)}}), line_of_before("storage: a fault of the engine: ", count, " blocks of one name named two times, ", other, " blocks named from two stores, ", count, " counts of names that pass their limit; the service makes no change in the ", u64(1), " store", " with such a block, and gives their objects"))
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Engine_Fault", {{"named_twice", count}, {"named_by_two_stores", other}, {"reference_overflow", count}, {"faulty_stores", other}}), line_of_before("storage: a fault of the engine: ", count, " blocks of one name named two times, ", other, " blocks named from two stores, ", count, " counts of names that pass their limit; the service makes no change in the ", other, " stores", " with such a block, and gives their objects"))
		head := []sentence.Part{"storage: the versions of ", object, " in the store ", store, " are ended at the generation ", count}
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Versions_Ended_Second_Root_Dropped", {{"generation", count}, {"store", store}, {"object", object}}), line_of_before(..append_parts(head, ", and the read back of the second root found other bytes: the disk did not keep it; no block is written with zeros, and the old bytes stay in free blocks until a commit takes them")))
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Versions_Ended_Second_Root_Failed", {{"generation", count}, {"store", store}, {"object", object}}), line_of_before(..append_parts(head, ", and the write or the read back of the second root failed on the device: it is not taken, the open of the next start decides, and the service makes no change until then; no block is written with zeros, and the old bytes stay in free blocks until a commit takes them")))
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Versions_Ended_Zeros_Failed", {{"generation", count}, {"zeroed", other}, {"not_zeroed", count}, {"store", store}, {"object", object}}), line_of_before("storage: the versions of ", object, " in the store ", store, " are ended at the generation ", count, ", and a write, the Flush or the read back of the zeros failed: ", other, " blocks read back as zeros and ", count, " with other bytes; the others were not read back, and can keep their old bytes until a commit takes them"))
		facts_expect_line(t, fact_test_render(t, storage, "storage_service", "Versions_Ended_Zeros_Dropped", {{"generation", count}, {"not_zeroed", other}, {"store", store}, {"object", object}}), line_of_before("storage: the versions of ", object, " in the store ", store, " are ended at the generation ", count, ", and the read back of the zeros found ", other, " blocks with other bytes: the disk did not keep those writes, and their old bytes stay in free blocks until a commit takes them"))
	}

	// The measure of the passes of the network service: the hundredths as
	// the line wrote them, value / 100, a dot and two digits.
	hundredths_values := [?]u64{0, 5, 100, 105, 12345, u64(max(i64))}
	owners := [2]string{strings.repeat("o", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator), "o"}
	for value in hundredths_values {
		fraction := value % 100
		text := fmt.tprintf("%d.%s%d", value / 100, fraction < 10 ? "0" : "", fraction)
		for owner in owners {
			for count in counts {
				values := []Fact_Test_Field{{"receive_passes", value}, {"received_bytes", count}, {"received_units", count}, {"send_passes", value}, {"sent_bytes", count}, {"sent_units", count}, {"data_bytes_read", count}, {"owner", owner}}
				tail :: "the payload is the datagram or the segment with its header; the bytes of the data that this service read on send: "
				facts_expect_line(t, fact_test_render(t, network, "network_service", "Tcp_Passes_Measured", values), line_of_before("network: a measure: the endpoint of ", owner, ", ", "TCP", ": the passes of this service over the data for each payload byte: ", text, " on receive (", count, " bytes in ", count, " segments), ", text, " on send (", count, " bytes in ", count, " segments), ", tail, count))
				facts_expect_line(t, fact_test_render(t, network, "network_service", "Udp_Passes_Measured", values), line_of_before("network: a measure: the endpoint of ", owner, ", ", "UDP", ": the passes of this service over the data for each payload byte: ", text, " on receive (", count, " bytes in ", count, " datagrams), ", text, " on send (", count, " bytes in ", count, " datagrams), ", tail, count))
			}
		}
	}

	// A refusal of the assembler keeps its number, as the line wrote it,
	// beside the words of its sentence.
	sentences := [2]string{strings.repeat("r", 119, context.temp_allocator), "no instruction of the subset and no directive has this name"}
	places := [3]u64{0, 1, u64(max(u32))}
	for place in places {
		for refusal_sentence in sentences {
			facts_expect_line(t, fact_test_render(t, assemble, "assemble", "Source_Refused", {{"line", place}, {"column", place}, {"value", max(u64)}, {"refusal", place}, {"refusal_sentence", refusal_sentence}}), line_of_before("assemble: line ", place, ", column ", place, ": ", refusal_sentence, " (refusal ", place, ", value ", max(u64), ")"))
		}
	}
	// A refusal of the writer of module files is the name of its member: the
	// longest name, and a short one, at the edges of the index.
	writer_refusals := [3]string{"Record_Stream_Without_Description", "Segment_Written_And_Executed", "None"}
	indexes := [3]u64{0, 1, max(u64)}
	for writer_refusal in writer_refusals {
		for index in indexes {
			facts_expect_line(t, fact_test_render(t, assemble, "assemble", "Parts_Refused", {{"index", index}, {"writer_refusal", writer_refusal}}), line_of_before("assemble: the module file writer refused the parts: refusal ", writer_refusal, ", index ", index))
			facts_expect_line(t, fact_test_render(t, assemble, "assemble", "File_Refused", {{"index", index}, {"writer_refusal", writer_refusal}}), line_of_before("assemble: the module file writer refused the file: refusal ", writer_refusal, ", index ", index))
		}
	}

	// A line of the diagnostic of the compiler, of the most bytes that the
	// field holds and of one byte.
	diagnostics := [2]string{strings.repeat("d", 143, context.temp_allocator), "d"}
	for diagnostic in diagnostics {
		facts_expect_line(t, fact_test_render(t, c_compiler, "c_compiler", "Diagnostic_Line", {{"diagnostic", diagnostic}}), line_of_before("c_compiler: ", diagnostic))
	}
}

// fact_test_render_texts gives the sentence of a fact type whose last
// fields are text views, with the values of its other fields and one text
// for each view, which it writes into the views and the out-of-line area
// as system.log_fact writes them: a text of at most
// value_kinds.TEXT_VIEW_INLINE_BYTES_MOST bytes in its view, a longer one
// in the area, cut with the cut mark when the area has no room for it.
@(private = "file")
fact_test_render_texts :: proc(t: ^testing.T, file: []u8, package_name, type_name: string, values: []Fact_Test_Field, texts: []string) -> string {
	key, record, made := fact_test_record(t, file, package_name, type_name, values)
	if !made {
		return ""
	}
	whole := make([]u8, len(record) + op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	copy(whole, record)
	views_start := len(record) - len(texts) * value_kinds.TEXT_VIEW_BYTES
	if !testing.expectf(t, views_start >= 0, "the fact type %s has fewer views than %d texts", type_name, len(texts)) {
		return ""
	}
	area := whole[len(record):]
	area_count := 0
	for text, index in texts {
		view := whole[views_start + index * value_kinds.TEXT_VIEW_BYTES:][:value_kinds.TEXT_VIEW_BYTES]
		length := len(text)
		if length <= value_kinds.TEXT_VIEW_INLINE_BYTES_MOST {
			copy(view[4:], text)
		} else {
			room := area[area_count:]
			length = copy(room, text)
			if length < len(text) {
				length, _, _ = cut_mark.apply(room, length, len(text) - length)
			}
			copy(view[4:8], room[:value_kinds.TEXT_VIEW_PREFIX_BYTES])
			offset := u64(area_count)
			for place in 0 ..< 8 {
				view[8 + place] = u8(offset >> (8 * u64(place)))
			}
			area_count += length
		}
		for place in 0 ..< 4 {
			view[place] = u8(u32(length) >> (8 * u32(place)))
		}
	}
	sentence, rendered := fact_values_render(file, key, whole[:len(record) + area_count])
	testing.expectf(t, rendered, "the fact %s.%s with its texts is refused", package_name, type_name)
	return sentence
}

// The paths that the views of these tests take: 0 bytes, 12 (the most of a
// view alone), 13 (the least of the area), 200 (PATH_LIMIT), and past the
// area, which the write cuts with the cut mark.
@(private = "file")
view_texts :: proc() -> [5]string {
	return {"", "/abcdefghijk", "/abcdefghijkl", strings.repeat("p", 200, context.temp_allocator), strings.repeat("q", op.LOG_FACT_TEXT_AREA_BYTES_MOST + 300, context.temp_allocator)}
}

// view_text_written gives a text as a view holds it: whole when the area
// has room for it, else its first bytes and the cut mark.
@(private = "file")
view_text_written :: proc(text: string) -> string {
	if len(text) <= op.LOG_FACT_TEXT_AREA_BYTES_MOST {
		return text
	}
	buffer := make([]u8, op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	given := copy(buffer, text)
	count, _, _ := cut_mark.apply(buffer, given, len(text) - given)
	return string(buffer[:count])
}

// Each fact type of module_files with the path of a request writes the
// line of before, the path in a text view: a path of 0, 12, 13 and 200
// bytes whole, and a path past the area cut with its mark, never whole.
@(test)
the_facts_of_a_path_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "module_files")
	if !ok {
		return
	}
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0xE0 + index)
	}
	problems := [2]string{"the answer has no Content-Length of 1 to 4194304 bytes", "no answer before the deadline"}
	nicknames := [2]string{strings.repeat("n", 23, context.temp_allocator), "n"}
	sizes := edges_make().sizes
	paths := view_texts()
	for path in paths {
		written := view_text_written(path)
		if len(path) > op.LOG_FACT_TEXT_AREA_BYTES_MOST {
			testing.expect(t, len(written) <= op.LOG_FACT_TEXT_AREA_BYTES_MOST && written != path[:len(written)])
		}
		texts := [1]string{path}
		for problem in problems {
			facts_expect_line(t, fact_test_render_texts(t, file, "module_files", "Get_Failed", {{"problem", problem}}, texts[:]), line_of_before("module_files: GET ", written, ": ", problem, ": nothing is stored"))
		}
		for nickname in nicknames {
			for size in sizes {
				facts_expect_line(t, fact_test_render_texts(t, file, "module_files", "File_Stored", {{"size", size}, {"file_hash", hash}, {"nickname", nickname}}, texts[:]), line_of_before("module_files: stored ", sentence.Module_Name{nickname}, " from ", written, ": ", size, " bytes, the BLAKE3 hash of its bytes ", sentence.Hash{hash[:]}))
			}
		}
	}
}

// hash_head_text gives the head of a hash as a field of the kind Hash_Head
// writes it.
@(private = "file")
hash_head_text :: proc(hash: [module.HASH_SIZE]u8) -> string {
	return fmt.tprintf("%02x%02x%02x%02x%s", hash[0], hash[1], hash[2], hash[3], value_kinds.HASH_HEAD_MARK)
}

// load_fields_render gives the sentence of a fact type of a load error of
// the call host, from the shape of its stage, whose bytes are the record.
@(private = "file")
load_fields_render :: proc(t: ^testing.T, file: []u8, type_name: string, fields: $T) -> string {
	bytes := transmute([size_of(T)]u8)fields
	sentence, rendered := fact_values_render(file, fact_key("host", type_name), bytes[:])
	testing.expectf(t, rendered, "the fact host.%s is refused", type_name)
	return sentence
}

// Each stage of a load error is a fact of the call host with the fields of
// its stage: names of 31 bytes and empty, a hash and no hash, each member
// of what failed and a word past them, and the edges of a number.
@(test)
the_facts_of_a_load_error_write_the_fields_of_each_stage :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "host")
	if !ok {
		return
	}
	HEAD :: "host: cannot load the module: "
	names := [2]string{strings.repeat("m", module.NAME_SIZE - 1, context.temp_allocator), ""}
	hashes: [2][module.HASH_SIZE]u8
	for index in 0 ..< module.HASH_SIZE {
		hashes[0][index] = u8(0xA0 + index)
	}
	numbers := [3]u32{0, 1, max(u32)}
	for name in names {
		for hash in hashes {
			error: module.Load_Error
			module.name_set(&error.module.name, name)
			module.name_set(&error.imported.name, "imported")
			module.name_set(&error.replacement.name, "replacement")
			module.name_set(&error.export, name)
			error.module.hash = hash
			error.imported.hash = hash
			head := hash_head_text(hash)

			find := module.load_find_fact_fields(&error)
			facts_expect_line(t, load_fields_render(t, file, "Load_Find_Failed", find), fmt.tprintf("%sthe load of %s (%s) found no file of its import imported (%s)", HEAD, name, head, head))
			cycle := module.load_cycle_fact_fields(&error)
			facts_expect_line(t, load_fields_render(t, file, "Load_Cycle_Failed", cycle), fmt.tprintf("%san import cycle: %s imports imported, and imported still loads its imports", HEAD, name))
			room := module.load_room_fact_fields(&error)
			facts_expect_line(t, load_fields_render(t, file, "Load_Room_Failed", room), fmt.tprintf("%sno room for %s (%s): a process has 16 modules at most, a module 8 imports, a table of prepared modules 64 parts, and its modules fit below the fixed ranges of the system", HEAD, name, head))

			// Read: each member of module.Error, and a word past them.
			for word in 0 ..= u64(max(module.Error)) + 1 {
				error.file_error = u32(word)
				read := module.load_read_fact_fields(&error)
				file_error, named := module.contract_enum_member_name(.Module_Error, word)
				if !named {
					file_error = fmt.tprintf("%d", word)
				}
				// The stage concerns the import when the error names one, else
				// the module itself.
				subject := hash != {} ? "imported" : name
				facts_expect_line(t, load_fields_render(t, file, "Load_Read_Failed", read), fmt.tprintf("%sthe file of %s (%s) is refused: %s", HEAD, subject, head, file_error))
			}
			// Check: each member of module.Difference, at the edges of the
			// parameter.
			for word in 0 ..= u64(max(module.Difference)) + 1 {
				for number in numbers {
					error.difference = u32(word)
					error.parameter = number
					check := module.load_check_fact_fields(&error)
					difference, named := module.contract_enum_member_name(.Load_Difference, word)
					if !named {
						difference = fmt.tprintf("%d", word)
					}
					facts_expect_line(t, load_fields_render(t, file, "Load_Check_Failed", check), fmt.tprintf("%s%s imports imported, and the export %s of its replacement fails the check: %s, parameter %d", HEAD, name, name, difference, number))
				}
			}
			// Bind: the edges of the import slot.
			for number in numbers {
				error.import_slot = number
				bind := module.load_bind_fact_fields(&error)
				facts_expect_line(t, load_fields_render(t, file, "Load_Bind_Failed", bind), fmt.tprintf("%simport slot %d of %s cannot be bound: export %s of imported", HEAD, number, name, name))
			}
			// Map and Unmap: each status of the kernel, and a word past them.
			for word in status_words() {
				error.status = u32(word)
				memory := module.load_memory_fact_fields(&error)
				status := status_text(word)
				facts_expect_line(t, load_fields_render(t, file, "Load_Map_Failed", memory), fmt.tprintf("%sthe kernel refused to map %s (%s): status %s", HEAD, name, head, status))
				facts_expect_line(t, load_fields_render(t, file, "Load_Unmap_Failed", memory), fmt.tprintf("%sthe kernel refused to remove %s (%s): status %s", HEAD, name, head, status))
			}
		}
	}
	facts_expect_line(t, fact_test_render(t, file, "host", "Load_Failed_Without_Stage", {}), "host: cannot load the module: the load error names no stage")
}
