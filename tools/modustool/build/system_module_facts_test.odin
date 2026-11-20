package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/sentence"
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
// cause word that names no member; the restarts 0 and max(u32); each fault
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
		facts_expect_line(t, render(t, file, "Machine_Not_Usable_Without", {{"row_process", name}}), line_of_before("start_policy: the machine is not usable without ", sentence.Module_Name{name}, ": the start policy stops before Machine_Usable"))
	}
	list_problems := [?]string{"it has no row", "a row has a mark that is neither needed nor not needed"}
	for count in counts {
		for list_problem in list_problems {
			facts_expect_line(t, render(t, file, "Start_List_Refused", {{"row", count}, {"list_problem", list_problem}}), line_of_before("start_policy: the start list is refused: ", list_problem, ", at its row ", count, ": no row starts"))
		}
		facts_expect_line(t, render(t, file, "Start_List_Read", {{"rows", count}}), line_of_before("start_policy: the start list has ", count, " rows: each starts in its order"))
		facts_expect_line(t, render(t, file, "Completion_Tag_Refused", {{"tag", count}}), line_of_before("start_policy: refused a completion of the tag ", count, ", which names no command in flight"))
		facts_expect_line(t, render(t, file, "Completion_Status_Refused", {{"status_word", count}}), line_of_before("start_policy: refused a completion whose status word ", count, " names no status"))
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
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Screen_Past_Reference", {{"width", count}, {"height", other}}), line_of_before("remote_display: the screen of ", count, "x", other, " is past the reference screen of the protocol: no capture face"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Face_Opened", {{"width", count}, {"height", other}}), line_of_before("remote_display: the capture face is open: a copy of ", count, "x", other))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Face_Closed", {{"pictures", count}}), line_of_before("remote_display: no viewer: the capture face is closed, after ", count, " pictures of the compositor"))
		facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Listening", {{"listen_port", count}, {"viewer_capacity", other}}), line_of_before("remote_display: listening on the UDP port ", count, ", for the host 10.0.2.2 only, and for the viewer keys that a principal allowed: ", other, " viewers at one time"))
		facts_expect_line(t, fact_test_render(t, remote, "remote_service", "Listening", {{"listen_port", count}, {"connection_capacity", other}, {"calls_per_connection", count}}), line_of_before("remote: listening on the UDP port ", count, ", for the host 10.0.2.2 only, and for the client keys that a principal allowed: ", other, " connections, each with ", count, " calls at one time"))
		for edge in edges {
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Whole_Screen_Measured", {{"width", count}, {"height", other}, {"screen_pieces", count}, {"piece_bytes", edge}, {"pixel_bytes", edge}, {"coded_time", edge}, {"taken_time", edge}}), line_of_before("remote_display: a measure: the whole screen of ", count, "x", other, " in one viewer frame: ", count, " screen pieces, ", edge, " bytes of screen pieces for ", edge, " bytes of pixels, coded in ", edge, " us, taken by the viewer ", edge, " us after its start"))
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Small_Damage_Measured", {{"pixels", count}, {"frames", other}, {"median_size", edge}, {"median_time", edge}, {"least_size", edge}, {"least_time", edge}}), line_of_before("remote_display: a measure: viewer frames of a small damage (at most ", count, " pixels), the median of ", other, ": ", edge, " bytes of screen pieces, ", edge, " us from Viewer_Frame_Start in the stream to Viewer_Frame_Taken; the least ", edge, " bytes and ", edge, " us"))
			facts_expect_line(t, fact_test_render(t, remote_display, "remote_display_service", "Capture_Memory_Refused", {{"pages", edge}}), line_of_before("remote_display: no memory for the capture face: ", edge, " pages"))
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
