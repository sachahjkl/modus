package build

import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:contract/call_outcome"
import "modus:contract/memory_screen"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/plan_values"
import "modus:contract/replacement_list"
import "modus:contract/start_grant"
import "modus:contract/system_description"
import "modus:contract/value_kinds"
import "internal:root/replacement_signature"
import "modus:sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the root service that its lines of the starts, the
// budgets, the devices, the debugging, the disk grant tables, the client
// keys, the principals, the trust and the start policy became
// (src/md/features/log_facts.md), against the lines that they replaced.
// The fact types come from the extraction of the tool on the sources of
// root: a host test does not depend on a build. Each sentence is compared
// with the parts of the old line written by sentence.format, at the edges
// of each field. The helpers are in fact_test_helpers_test.odin.

// The name of the store of the module files, which the old lines wrote
// from disk_process.STORE_NAME and the templates write as a word. The tool
// does not compile that support package.
@(private = "file")
STORE_NAME :: "module_files"

// The texts that the writers put in the Text fields of a closed set, each
// the way the root service writes it.
@(private = "file")
BUDGET_PARTS := [?]string{"pages", "processes", "threads"}
@(private = "file")
RING_WRITERS := [?]string{"the entropy service", "the network service", "the powerbox", "the collector", "the wiring service", "the TPM service", "the compositor", "the disk processes service", "the principals service", "the devices service"}
@(private = "file")
PAYING_BUDGETS := [?]string{"this service", "the disk processes", "a disk process"}
@(private = "file")
MAPPINGS := [?]string{"the date page", "the debug image", "the disk process page", "the fresh bytes page", "the settings page and the font outlines", "the script font set", "the file of the storage service", "the file of the service", "the machine parts page", "the start list"}
@(private = "file")
NETWORK_CAUSES := [?]string{"the network service did not start", "the network service stopped"}
@(private = "file")
DISK_GRANT_NAMES := [?]string{"store", "start_policy"}
@(private = "file")
TABLE_KEYS := [?]string{"the machine key", "the key of the principal"}
@(private = "file")
CLIENT_USES := [?]string{"calls, view and input", "calls and view", "view and input", "view", "calls", "no use"}
@(private = "file")
UNLOCK_MODES := [?]string{"an unlock", "the creation of a principal", "the machine passphrase that is set", "the machine key that the TPM seals", "a change of the passphrase", "a new recovery key", "the machine key before the start policy", "a mode that names no member"}
@(private = "file")
CHANGE_ENDS := [?]string{"unlock stopped before the end: the old or the new secret opens", "the passphrase is changed", "the change is cancelled: nothing changed"}
@(private = "file")
FAILURE_CAUSES := [?]string{"the rescue start policy is absent from the boot image", "the rescue start policy did not start", "the rescue start policy stopped before the machine was usable", "the rescue start policy stopped after the machine was usable", "the rescue start policy sent no Machine_Usable within the hang bound"}

// The longest text of a list: the most bytes of a Text field that writes
// one of them.
longest :: proc(texts: []string) -> u32 {
	most: u32 = 0
	for text in texts {
		most = max(most, u32(len(text)))
	}
	return most
}

// The most bytes of the text of each Text field of the root service, which
// its field holds with a zero byte after it.
@(private = "file")
root_text_bytes_most :: proc() -> map[string]u32 {
	most := make(map[string]u32, context.temp_allocator)
	name_most := u32(value_kinds.MODULE_NAME_FIELD_BYTES - 1)
	for name in ([?]string{"started_process", "stopped_process", "refused_process", "loaded_process", "window_process", "service", "caller", "holder", "debugger", "target", "importer", "receiver", "provider", "nickname", "stop_report_name", "replaced", "replacement", "checked_entry", "held_process", "ready_process"}) {
		most[name] = name_most
	}
	// A principal name has at most principals.NAME_LIMIT bytes, a store
	// name 31, a file of the store disk_process.NAME_LIMIT, and a resource
	// the name of an entry of the boot image.
	most["principal_name"] = 23
	for refusal in memory_screen.GROW_REFUSAL_SENTENCES {
		most["grow_refusal"] = max(most["grow_refusal"], u32(len(refusal)))
	}
	most["store"] = 31
	most["file"] = 23
	most["resource"] = 31
	most["client_key"] = 16
	most["public_key_head"] = 16
	grants := make([dynamic]string, context.temp_allocator)
	for name in start_grant.GRANT_NAMES {
		append(&grants, name)
	}
	append(&grants, ..DISK_GRANT_NAMES[:])
	most["grant"] = longest(grants[:])
	most["budget_part"] = longest(BUDGET_PARTS[:])
	most["paying_budget"] = longest(PAYING_BUDGETS[:])
	most["ring_writer"] = longest(RING_WRITERS[:])
	most["mapping"] = longest(MAPPINGS[:])
	most["network_cause"] = longest(NETWORK_CAUSES[:])
	most["table_key"] = longest(TABLE_KEYS[:])
	most["uses"] = longest(CLIENT_USES[:])
	most["unlock_mode"] = longest(UNLOCK_MODES[:])
	most["change_end"] = longest(CHANGE_ENDS[:])
	most["failure_cause"] = longest(FAILURE_CAUSES[:])
	reasons := make([dynamic]string, context.temp_allocator)
	for reason in replacement_signature.decision_sentences {
		append(&reasons, reason)
	}
	for reason in replacement_list.list_problem_sentences {
		append(&reasons, reason)
	}
	most["reason"] = longest(reasons[:])
	problems := make([dynamic]string, context.temp_allocator)
	for problem in font_outlines.problem_sentences {
		append(&problems, problem)
	}
	most["problem"] = longest(problems[:])
	set_problems := make([dynamic]string, context.temp_allocator)
	for name in plan_values.SET_PROBLEM_NAMES {
		append(&set_problems, name)
	}
	most["set_problem"] = longest(set_problems[:])
	most["failure"] = ROOT_FAILURE_MOST
	most["call_failure"] = longest(TABLE_CALL_FAILURES[:])
	most["table_problem"] = longest(TABLE_PROBLEMS_IN_A_FIELD[:])
	most["new_record"] = longest(NEW_RECORDS[:])
	most["persistence"] = longest(PERSISTENCES[:])
	most["start_policy_words"] = longest(START_POLICY_WORDS[:])
	most["tpm_status"] = longest(TPM_STATUS_WORDS[:])
	most["machine_part"] = longest(MACHINE_PARTS[:])
	most["strength"] = longest(SEED_STRENGTHS[:])
	most["rdseed_presence"] = longest(PRESENCES[:])
	most["rdrand_presence"] = longest(PRESENCES[:])
	// The names of a load error: a name of a module, at most NAME_SIZE - 1
	// bytes, in a field of module.LOAD_NAME_FIELD_BYTES.
	for name in ([?]string{"module_name", "imported_name", "replacement_name", "subject_name", "export"}) {
		most[name] = module.NAME_SIZE - 1
	}
	most["appearance_in_force"] = longest(APPEARANCE_WORDS[:])
	most["appearance_setting"] = longest(APPEARANCE_WORDS[:])
	return most
}

// The names of the appearance in force and of the values of the setting
// appearance: auto, dark, light.
@(private = "file")
APPEARANCE_WORDS := [?]string{"auto", "dark", "light"}

// The texts of the Text fields of the second part of the root service,
// each the way the root service writes it. The tool does not compile the
// support packages disk_process, principals and start_list, so their
// sentences are written here; a change of one of them fails the test of
// its line.
@(private = "file")
TABLE_CALL_FAILURES := [?]string{"no connection to the storage service", "the call ring and the call region of the storage service do not map", "the storage service took no call", "the storage service stopped", "the storage service gave no answer in time", "the storage service refused the call", "the principals service does not run", "the principals service stopped", "the principals service gave no answer in time", "the principals service took no handle", "the principals service gave a table that does not decode", "the principals service gave an answer that names no cause", "the principals service holds no key of the table", "the principals service refused the call"}
// The sentences of disk_process.table_problem_sentences that a Text field
// holds; the three longer ones have a fact type each.
@(private = "file")
TABLE_PROBLEMS_IN_A_FIELD := [?]string{"the table does not have 2288 bytes", "its tag does not verify under the key of the principal: another key wrote it, or a byte changed", "the table does not start with DISKGRNT", "the table has another format number", "the table counts more than 16 rows", "the global setting of the table is not 0 or 1, or its header has a byte that is not zero", "two rows have one nickname", "two rows hold the grant start_policy", "the table of a named principal holds the grant start_policy, which only principal 0 gives", "the table has bytes that are not zero after its last row"}
@(private = "file")
TABLE_PROBLEM_OLDER_FORMAT_CAUSE :: "it has the format of an older system (1008, 1136 or 1168 bytes), and no version of it can be restored to verify"
TABLE_OLDER_FORMAT_TO_DO :: "to use a client again, pair it again with remote_allow, or remote_display_allow for a viewer, from a console of the principal; give each disk process its grants again"
@(private = "file")
TABLE_PROBLEM_BAD_ROW :: "a row has a nickname that no grant names, a hash of zero bytes, an unknown grant or persistence, the grant start_policy with another grant, or a byte that must be zero"
@(private = "file")
TABLE_PROBLEM_BAD_CLIENT_KEYS :: "the client keys of remote in the table are more than 32, or one is zero bytes, or one comes two times, or a byte after the last key is not zero"
@(private = "file")
NEW_RECORDS := [?]string{"the new machine passphrase", "the new principal"}
@(private = "file")
PERSISTENCES := [?]string{"the global setting", "persist across a restart", "last until the machine stops"}
// The list words of the start policy, and the words of a chosen one: its
// nickname of disk_process.NAME_LIMIT bytes in parentheses.
@(private = "file")
START_POLICY_WORDS := [?]string{"of the list start_list", "of the list rescue_list", "chosen by principal 0, from the disk", "(nickname \"nnnnnnnnnnnnnnnnnnnnnnn\")"}
@(private = "file")
TPM_STATUS_WORDS := [?]string{"Argument_Refused", "Wrong_State", "Data_Damaged", "Callee_Busy", "Budget_Or_Capacity_Exhausted", "Callee_Unavailable"}
@(private = "file")
MACHINE_PARTS := [?]string{"screen", "data disk", "disk of the measures", "network device", "sound device", "entropy device", "TPM"}
@(private = "file")
SEED_STRENGTHS := [?]string{"none", "weak (the cycle counter only)", "processor (rdrand)", "entropy (rdseed)"}
@(private = "file")
PRESENCES := [?]string{"present", "absent"}
// The failure of the root service: a sentence of this service, at most
// 73 bytes, or the sentence of a fault of the check of the boot image,
// which names an entry for a fault of one entry: at most 2 + 110 bytes for
// a fault of the whole image (system_description.fault_sentences).
@(private = "file")
ROOT_FAILURE_MOST :: 112

@(private = "file")
root_service_facts_file :: proc(t: ^testing.T) -> (file: []u8, ok: bool) {
	return facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "root")
}

expect :: facts_expect_line

@(private = "file")
render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
	return fact_test_render(t, file, "root", type_name, values)
}

// Each fact type of the root service with a Text field ends with its Text
// fields, and each Text field holds the longest text of its writer and a
// zero byte. The fact types of the step before are in it too.
@(test)
the_texts_of_the_root_facts_come_last_and_whole :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if ok {
		facts_expect_text_fields_last(t, file, root_text_bytes_most())
	}
}

// The facts of the starts, the budgets, the mappings, the devices, the
// debugging, the resources and the replacements write the lines of
// before: the counts 0, 1 and max(u64); a size or a time of max(i64), the
// largest that its field holds; a name of 31 bytes; each text of a closed
// set.
@(test)
the_start_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	other := strings.repeat("o", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	third := strings.repeat("c", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	resource := strings.repeat("r", 31, context.temp_allocator)
	largest_size := u64(max(i64))
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0xC0 + index)
	}
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		for part in BUDGET_PARTS {
			{
				expect(t, render(t, file, "Screen_Budget_Grown", {{"width", count}, {"height", max(u64) - count}, {"growth", max(u64) - count}, {"compositor_pages", min(count, u64(max(i64)))}, {"service_pages", u64(max(i64)) - min(count, u64(max(i64)))}}), line_of_before("root: the budgets of the screen of memory grow for ", count, " x ", max(u64) - count, ", growth ", max(u64) - count, ": an extra budget of ", sentence.Size{min(count, u64(max(i64))), .Pages}, " for the compositor and of ", sentence.Size{u64(max(i64)) - min(count, u64(max(i64))), .Pages}, " for remote_display"))
				for refusal in memory_screen.GROW_REFUSAL_SENTENCES {
					expect(t, render(t, file, "Screen_Budget_Refused", {{"width", count}, {"height", max(u64) - count}, {"grow_refusal", refusal}}), line_of_before("root: refused to grow the budgets of the screen of memory for ", count, " x ", max(u64) - count, ": ", refusal))
				}
				expect(t, render(t, file, "Screen_Budget_Released", {{"growth", count}, {"holder", process}}), line_of_before("root: ", sentence.Module_Name{process}, " gave back its extra budget of growth ", count, " of the screen of memory: its pages return when no object of it is left"))
				expect(t, render(t, file, "Screen_Budget_Release_Refused", {{"growth", count}, {"holder", process}}), line_of_before("root: refused the release of the extra budget of growth ", count, " of the screen of memory from ", sentence.Module_Name{process}, ", which holds none of it"))
				expect(t, render(t, file, "Screen_Budget_Ended_At_Stop", {{"holder", process}}), line_of_before("root: ", sentence.Module_Name{process}, " stopped with an extra budget of the screen of memory: its pages return"))
				expect(t, render(t, file, "Compositor_On_Screen_Of_Memory", {{"width", count}, {"height", max(u64) - count}}), line_of_before("root: the compositor starts on a screen of memory of ", count, " x ", max(u64) - count, ": the machine has no screen"))
			}
			for holder in PAYING_BUDGETS {
				expect(t, render(t, file, "Start_Refused_Budget_Part", {{"needed", count}, {"held", max(u64) - count}, {"refused_process", process}, {"budget_part", part}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": it gets ", count, " ", part, ", and the budget of ", holder, " holds ", max(u64) - count))
			}
		}
		for holder in PAYING_BUDGETS {
			expect(t, render(t, file, "Start_Refused_Log_Records", {{"log_records", count}, {"held_log_records", max(u64) - count}, {"refused_process", process}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": it gets ", count, " log records of each second, and the budget of ", holder, " holds ", max(u64) - count))
			expect(t, render(t, file, "Start_Refused_Processor_Time", {{"processor", count}, {"processor_limit", max(u64) - count}, {"refused_process", process}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": it gets ", count, " microseconds of processor time in each second, and the limit of the budget of ", holder, " is ", max(u64) - count))
		}
		for holder in PAYING_BUDGETS {
			expect(t, render(t, file, "Start_Refused_Floor", {{"floor", min(count, largest_size)}, {"held", largest_size - min(count, largest_size)}, {"refused_process", process}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": its floor is ", sentence.Size{min(count, largest_size), .Pages}, ", and ", holder, " can give ", sentence.Size{largest_size - min(count, largest_size), .Pages}))
		}
		expect(t, render(t, file, "Start_Refused_No_Floor", {{"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": its module file gives no floor"))
		expect(t, render(t, file, "Budget_Peak_At_Ready", {{"peak_pages", count}, {"floor_pages", max(u64) - count}, {"ready_process", process}}), line_of_before("root: ", sentence.Module_Name{process}, " reached its first state of work with a peak of ", count, " pages, for a floor of ", max(u64) - count, " pages"))
		expect(t, render(t, file, "Budget_Floor_Passed", {{"peak_pages", count}, {"floor_pages", max(u64) - count}, {"ready_process", process}}), line_of_before("root: ", sentence.Module_Name{process}, " passed its floor before its first state of work: a peak of ", count, " pages, for a floor of ", max(u64) - count, " pages"))
		expect(t, render(t, file, "Ready_Ring_Write_With_No_Record", {{"ready_process", process}}), line_of_before("root: the ready ring of ", sentence.Module_Name{process}, " counts a record that it does not hold: it ends, and the floor is not checked"))
		for writer in RING_WRITERS {
			expect(t, render(t, file, "Ring_Counters_Refused", {{"ring_writer", writer}}), line_of_before("root: the ring of ", writer, " counts more records than it holds: its records are dropped"))
		}
		expect(t, render(t, file, "Ready_Ring_Counters_Refused", {{"ready_process", process}}), line_of_before("root: the ready ring of ", sentence.Module_Name{process}, " counts more records than it holds: it ends, and the floor is not checked"))
		expect(t, render(t, file, "Root_Ring_Counters_Refused", {{"caller", process}}), line_of_before("root: the root ring of ", sentence.Module_Name{process}, " counts more records than it holds: it ends, and no command of it is read"))
		expect(t, render(t, file, "Ready_Record_Refused", {{"kind", count}, {"ready_process", process}}), line_of_before("root: ", sentence.Module_Name{process}, " sent the record ", count, " on its ready ring, which carries Ready alone: its floor is not checked"))
		expect(t, render(t, file, "Disk_Processes_Budget_Made", {{"pages", largest_size}, {"processes", count}, {"threads", count}}), line_of_before("root: the disk processes share one budget of ", sentence.Size{largest_size, .Pages}, ", ", count, " processes and ", count, " threads"))
		expect(t, render(t, file, "Disk_Processes_Budget_Refused_Reserved", {{"needed", min(count, largest_size)}, {"held", largest_size - min(count, largest_size)}, {"reserved", min(count, largest_size)}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": the budget of the disk processes needs ", sentence.Size{min(count, largest_size), .Pages}, ", and this service can give ", sentence.Size{largest_size - min(count, largest_size), .Pages}, " because the start-list reserves hold ", sentence.Size{min(count, largest_size), .Pages}))
		expect(t, render(t, file, "Start_Refused_Budget_Too_Small", {{"pages", min(count, largest_size)}, {"processes", count}, {"threads", count}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": its budget of ", sentence.Size{min(count, largest_size), .Pages}, ", ", count, " processes and ", count, " threads is too small for its load: the module asks for too little"))
		// A slot is the word of the starter: a negative slot writes its
		// bits, as u64(slot) did.
		expect(t, render(t, file, "Start_Refused_Context_Handle", {{"slot", count}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": two grants of its start grant set take the handle ", count, " of its context, and a handle would be lost"))
		expect(t, render(t, file, "Start_Refused_Context_Value", {{"value_place", count}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": two parts of its start write the value ", count, " of its context, and a value would be lost"))
		for mapping in MAPPINGS {
			expect(t, render(t, file, "Mapping_Dropped", {{"capacity", count}, {"mapping", mapping}}), line_of_before("root: no room for ", mapping, " in the mappings of a start, which holds ", count, ": the process starts without it"))
			expect(t, render(t, file, "Mapping_Needed", {{"capacity", count}, {"refused_process", process}, {"mapping", mapping}}), line_of_before("root: no room for ", mapping, " in the mappings of a start, which holds ", count, ": the start of ", sentence.Module_Name{process}, " fails"))
		}
		expect(t, render(t, file, "Debug_Image_Found", {{"debug_image_size", min(count, largest_size)}}), line_of_before("root: the debug image has ", sentence.Size{min(count, largest_size), .Bytes}))
		expect(t, render(t, file, "Stop_Report_Kept", {{"principal", count}, {"stopped_process", process}, {"stop_report_name", process}}), line_of_before("root: kept the stop report of ", sentence.Module_Name{process}, ", a disk process of principal ", count, ": stop_report(\"", sentence.Module_Name{process}, "\") names its frames"))
		expect(t, render(t, file, "Debug_Store_Given", {{"principal", count}, {"debugger", process}, {"target", other}}), line_of_before("root: gave ", sentence.Module_Name{process}, " a connection that reads only to the store ", STORE_NAME, " of principal ", count, ", for the debug object of ", sentence.Module_Name{other}))
		expect(t, render(t, file, "Debug_Stop_Report_Given", {{"principal", count}, {"debugger", process}, {"target", other}, {"caller", third}}), line_of_before("root: gave ", sentence.Module_Name{process}, " the kept stop report of ", sentence.Module_Name{other}, " and a connection that reads only to the store ", STORE_NAME, " of principal ", count, ", for ", sentence.Module_Name{third}))
		expect(t, render(t, file, "Store_Name_Too_Long", {{"principal", count}, {"caller", process}}), line_of_before("root: the name of the store of ", sentence.Module_Name{process}, " for principal ", count, " has more than 31 bytes: no connection"))
		expect(t, render(t, file, "Resource_Given", {{"resource_size", min(count, largest_size)}, {"resource", resource}, {"receiver", process}}), line_of_before("root: the resource ", resource, " (", sentence.Size{min(count, largest_size), .Bytes}, ") is given to ", sentence.Module_Name{process}, ", read-only"))
		expect(t, render(t, file, "Import_Scan_Started", {{"imports", count}, {"loaded_process", process}}), line_of_before("root: ", sentence.Module_Name{process}, " imports ", count, " modules that the boot image does not hold: the import scan reads the store ", STORE_NAME, " to find them by the hash of their bytes"))
		font_problems := font_outlines.problem_sentences
		for problem in font_problems {
			expect(t, render(t, file, "Font_Outlines_Refused", {{"problem_value", count}, {"problem", problem}}), line_of_before("root: the font outlines are refused: ", problem, ", value ", count, ": they are not given"))
		}
		expect(t, render(t, file, "Log_Scope_Refused", {{"slot", count}, {"serial", max(u64) - count}, {"caller", process}}), line_of_before("root: the process slot ", count, " or the process serial ", max(u64) - count, " of ", sentence.Module_Name{process}, " does not fit the grant of the log service: it reads no record"))
		expect(t, render(t, file, "Machine_Stop_Codes_Refused", {{"first_code", count}, {"second_code", max(u64)}, {"code_limit", u64(op.MACHINE_STOP_CODE_MOST)}}), line_of_before("root: Machine_Stop refused the codes ", count, " and ", max(u64), " with Bad_Operation and the record Bad_Value of the code, limit ", u64(op.MACHINE_STOP_CODE_MOST), ", and the machine runs on: as it must"))
		expect(t, render(t, file, "Root_Ready", {{"image_modules", count}}), line_of_before("root: ok", ", ", count, " modules in the boot image"))
		expect(t, render(t, file, "Compositor_Record_Unknown", {{"record_kind", count}}), line_of_before("root: refused a record of the compositor of the kind ", count, ", which names no control"))
		expect(t, render(t, file, "Compositor_Record_Not_Taken", {{"record_kind", count}}), line_of_before("root: refused a record of the compositor of the kind ", count, ", which this service sends and does not take"))
		expect(t, render(t, file, "Bridge_Devices_Too_Many", {{"device_limit", count}, {"bus", max(u64) - count}}), line_of_before("root: more than ", count, " devices behind the conventional bridge in front of the bus ", max(u64) - count, ": no service for them"))
		expect(t, render(t, file, "Virtio_Device_Absent", {{"device", count}, {"service", process}}), line_of_before("root: no virtio device for ", sentence.Module_Name{process}, " at the place ", count, " of the bus"))
		expect(t, render(t, file, "Virtio_Device_Absent_Behind_Bridge", {{"device", count}, {"bus", max(u64) - count}, {"service", process}}), line_of_before("root: no virtio device for ", sentence.Module_Name{process}, " at the place ", count, " of the bus ", max(u64) - count, ", behind a bridge"))
		expect(t, render(t, file, "Bridge_Registers_Held", {{"bus", count}, {"other_devices", max(u64) - count}, {"service", process}}), line_of_before("root: ", sentence.Module_Name{process}, " also holds the registers of each other device behind the conventional bridge in front of the bus ", count, ", which shares its requester; other devices: ", max(u64) - count))
		expect(t, render(t, file, "Standard_Vga_Absent", {{"device", count}}), line_of_before("root: no standard VGA at the place ", count, " of the bus: the compositor writes the screen page that the display shows"))
		expect(t, render(t, file, "Entropy_Device_Absent", {{"device", count}}), line_of_before("root: no entropy device at the place ", count, " of the bus: the random seed of the system has the sources of the processor only"))
		expect(t, render(t, file, "Entropy_Start_Bytes", {{"bytes_given", min(count, largest_size)}, {"start_reads", count}, {"bytes_mixed", min(count, largest_size)}, {"refused_start_reads", max(u64) - count}}), line_of_before("root: the entropy device gave ", min(count, largest_size), " bytes in ", count, " reads: ", min(count, largest_size), " bytes mixed into the random generator of the system; refused reads: ", max(u64) - count))
	}

	// The names of the processes and of the texts of a closed set.
	expect(t, render(t, file, "Start_Refused_Sound_Device_Busy", {{"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": the sound device plays for another process; one process plays at a time"))
	expect(t, render(t, file, "Console_Renderer_Refused_Holder", {{"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, " as the terminal of the console: it is not the renderer that the boot image chose; it gets no serial port and no screen"))
	expect(t, render(t, file, "Console_Renderer_Refused_Running", {{"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, " as the terminal of the console: a renderer runs already; one process at a time holds the serial port or the screen"))
	// The old line wrote the name as a plain text: the same bytes.
	expect(t, render(t, file, "Window_Start_Not_Measured", {{"window_process", process}}), line_of_before("root: the control ring of the compositor is full: the start of the window of ", process, " is not measured"))
	expect(t, render(t, file, "Debugging_Ended", {{"debugger", process}, {"target", other}, {"caller", third}}), line_of_before("root: ", sentence.Module_Name{process}, " ended the debugging of ", sentence.Module_Name{other}, " for ", sentence.Module_Name{third}))
	for grant in start_grant.GRANT_NAMES {
		expect(t, render(t, file, "Debug_Access_Refused", {{"caller", process}, {"target", other}, {"grant", grant}}), line_of_before("root: refused ", sentence.Module_Name{process}, " the debug access to ", sentence.Module_Name{other}, ": the grant ", grant, " of the process refuses it"))
	}
	expect(t, render(t, file, "Debugging_Ended_After_Revocation", {{"target", process}, {"caller", other}}), line_of_before("root: ended the debugging of ", sentence.Module_Name{process}, " for ", sentence.Module_Name{other}, ": the rule no longer gives the debug access, after a revocation"))
	expect(t, render(t, file, "Acts_For_Principal_Revocation_Refused", {{"holder", process}, {"service", other}}), line_of_before("root: refused the revocation of acts_for_principal of ", sentence.Module_Name{process}, ": the service ", sentence.Module_Name{other}, " has no room for the new grants; nothing changed"))
	expect(t, render(t, file, "Palette_Provider_Set", {{"provider", process}}), line_of_before("root: ", sentence.Module_Name{process}, " is the palette provider"))
	expect(t, render(t, file, "Import_Found", {{"hash", hash}, {"loaded_process", process}, {"importer", other}, {"file", "fffffffffffffffffffffff"}}), line_of_before("root: ", sentence.Module_Name{process}, ": the import ", sentence.Hash{hash[:]}, " of ", sentence.Module_Name{other}, " is the file ", sentence.Module_Name{"fffffffffffffffffffffff"}, " of the store ", STORE_NAME, ", checked on its bytes"))
	reasons := make([dynamic]string, context.temp_allocator)
	for reason in replacement_signature.decision_sentences {
		append(&reasons, reason)
	}
	for reason in replacement_list.list_problem_sentences {
		append(&reasons, reason)
	}
	for reason in reasons {
		expect(t, render(t, file, "Replacement_Refused", {{"replaced", process}, {"replacement", other}, {"reason", reason}}), line_of_before("root: refused the replacement of ", sentence.Module_Name{process}, " by ", sentence.Module_Name{other}, ": ", reason))
	}
	expect(t, render(t, file, "Replacement_Ended", {{"replaced", process}}), line_of_before("root: no replacement of ", sentence.Module_Name{process}))
	expect(t, render(t, file, "Replacement_Made", {{"replacement", process}, {"replaced", other}}), line_of_before("root: ", sentence.Module_Name{process}, " replaces ", sentence.Module_Name{other}, " in each load that follows"))
	for cause in NETWORK_CAUSES {
		expect(t, render(t, file, "Network_Refused", {{"network_cause", cause}}), line_of_before("root: ", cause, ": no process with an endpoint of the network starts until the machine starts again; the other processes start"))
	}
}

// The facts of the disk processes, of the disk grant tables and of the
// client keys write the lines of before: the principals 0, 1 and
// max(u64); the counts 0, 1 and max(u64); a nickname of 31 bytes; each
// grant name; each text of a closed set.
@(test)
the_disk_grant_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	nickname := strings.repeat("k", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	key_head := "0123456789abcdef"
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0xA0 + index)
	}
	grants := make([dynamic]string, context.temp_allocator)
	for name in start_grant.GRANT_NAMES {
		append(&grants, name)
	}
	append(&grants, ..DISK_GRANT_NAMES[:])
	for grant in grants {
		expect(t, render(t, file, "Disk_Grant_Refused_Never", {{"nickname", nickname}, {"grant", grant}}), line_of_before("root: refused the grant ", grant, " to the nickname ", sentence.Module_Name{nickname}, ": no command gives it to a disk process, as it reaches the whole machine or the principal"))
		expect(t, render(t, file, "Disk_Grant_Refused_Not_Built", {{"nickname", nickname}, {"grant", grant}}), line_of_before("root: refused the grant ", grant, " to the nickname ", sentence.Module_Name{nickname}, ": a command gives a disk process the grant Store only"))
		expect(t, render(t, file, "Disk_Grant_Refused_Nickname_Characters", {{"nickname", nickname}, {"grant", grant}}), line_of_before("root: refused the grant ", grant, " to the nickname ", sentence.Module_Name{nickname}, ": a nickname with a grant has letters, digits, '-' and '_' only"))
		expect(t, render(t, file, "Disk_Grant_Refused_Reserved_Name", {{"nickname", nickname}, {"grant", grant}}), line_of_before("root: refused the grant ", grant, " to the nickname ", sentence.Module_Name{nickname}, ": the store of the module files keeps this name for itself"))
		expect(t, render(t, file, "Disk_Grant_Refused_Start_Policy", {{"nickname", nickname}, {"grant", grant}}), line_of_before("root: refused the grant ", grant, " to the nickname ", sentence.Module_Name{nickname}, ": it names the chosen start policy, which holds the grant Start_Policy and nothing else"))
	}
	expect(t, render(t, file, "Nickname_Move_Refused_Start_Policy", {{"nickname", nickname}}), line_of_before("root: refused the move of the nickname ", sentence.Module_Name{nickname}, ": it names the chosen start policy; start_policy_choose names another file"))
	expect(t, render(t, file, "Nickname_Move_Announced", {{"hash", hash}, {"nickname", nickname}}), line_of_before("root: the file ", sentence.Hash{hash[:]}, " will get the data of ", sentence.Module_Name{nickname}))
	expect(t, render(t, file, "Persistence_Refused_Start_Policy", {{"nickname", nickname}}), line_of_before("root: refused the setting of persistence of the nickname ", sentence.Module_Name{nickname}, ": it names the chosen start policy, which persists until start_policy_default ends the choice"))

	principals := [3]u64{0, 1, max(u64)}
	for principal in principals {
		other := max(u64) - principal
		expect(t, render(t, file, "Disk_Load_Started", {{"principal", principal}, {"loaded_process", nickname}}), line_of_before("root: reads ", sentence.Module_Name{nickname}, " from the store ", STORE_NAME, " of the storage service, for principal ", principal))
		expect(t, render(t, file, "Disk_Grant_Refused_No_Row", {{"principal", principal}, {"nickname", nickname}, {"grant", "start_policy"}}), line_of_before("root: refused the grant ", "start_policy", " to the nickname ", sentence.Module_Name{nickname}, ": it has no row in the disk grant table of principal ", principal, ", and no disk process of that nickname runs; start it by its hash first"))
		expect(t, render(t, file, "Disk_Grant_Refused_Store_Name", {{"principal", principal}, {"nickname", nickname}}), line_of_before("root: refused the grant store to the nickname ", sentence.Module_Name{nickname}, ": the name of its store for principal ", principal, " has more than 31 bytes"))
		expect(t, render(t, file, "Nickname_Move_Refused_No_Row", {{"principal", principal}, {"nickname", nickname}}), line_of_before("root: refused the move of the nickname ", sentence.Module_Name{nickname}, ": it has no row in the disk grant table of principal ", principal))
		expect(t, render(t, file, "Persistence_Refused_No_Row", {{"principal", principal}, {"nickname", nickname}}), line_of_before("root: refused the setting of persistence of the nickname ", sentence.Module_Name{nickname}, ": it has no row in the disk grant table of principal ", principal))
		expect(t, render(t, file, "Unlock_Refused_New_Key", {{"principal", principal}}), line_of_before("root: refused the unlock of principal ", principal, ": its key comes as the key of a new principal, and its record was not created since the machine started"))
		expect(t, render(t, file, "Unlock_Refused_Other_Key", {{"principal", principal}}), line_of_before("root: refused the unlock of principal ", principal, ": the key of its disk grant table differs from the key of its first unlock since the machine started"))
		expect(t, render(t, file, "Table_Change_Refused_Session_Locked", {{"principal", principal}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": its session is locked"))
		expect(t, render(t, file, "Table_Change_Refused_No_Key", {{"principal", principal}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": unlock gave no key for it"))
		expect(t, render(t, file, "Table_Change_Refused_Reading", {{"principal", principal}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": its read from the store module_files runs"))
		expect(t, render(t, file, "Table_Change_Refused_Unread", {{"principal", principal}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": the store module_files did not give it, so a write could lose it"))
		expect(t, render(t, file, "Table_Change_Refused_Format", {{"principal", principal}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": the table on the disk has a format that this system does not read, and it is kept; do not restore a version of it, as no version has a format that this system reads"))
		expect(t, render(t, file, "Table_Change_Refused_Unwritten", {{"principal", principal}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": its last change is not on the disk; start the machine again"))
		expect(t, render(t, file, "Table_Writes_Restarted_By_Revocation", {{"principal", principal}}), line_of_before("root: a revocation of a client key of remote starts the writes of the disk grant table of principal ", principal, " again"))
		expect(t, render(t, file, "Client_Key_Revocation_Not_Written", {{"principal", principal}, {"client_key", key_head}}), line_of_before("root: the revocation of the client key ", key_head, " of remote is not written in the disk grant table of principal ", principal, ", which takes no change now: the key can come back at the next start of the machine"))
		expect(t, render(t, file, "Table_Absent_Written", {{"principal", principal}}), line_of_before("root: the store module_files holds no disk grant table of principal ", principal, ": the table of this machine is written there"))
		expect(t, render(t, file, "Table_Revoked_Keys_Kept", {{"principal", principal}, {"revoked_keys", other}}), line_of_before("root: the disk grant table of principal ", principal, " held ", other, " client keys of remote revoked before its read: they stay revoked, and the table is written again"))
		for table_key in TABLE_KEYS {
			expect(t, render(t, file, "Table_Change_Refused_Not_Verified", {{"principal", principal}, {"table_key", table_key}}), line_of_before("root: refused a change of the disk grant table of principal ", principal, ": the table on the disk does not verify under ", table_key, ", and it is kept; restore a version of it that verifies, then start the machine again"))
			expect(t, render(t, file, "Table_Read_Replacing", {{"principal", principal}, {"rows", other}, {"client_keys", principal}, {"replaced_rows", other}, {"table_key", table_key}}), line_of_before("root: read the disk grant table of principal ", principal, " from the store module_files: ", other, " rows, with the tag of ", table_key, "; ", principal, " client keys of remote; it replaces ", other, " rows made before the key came"))
			expect(t, render(t, file, "Table_Read", {{"principal", principal}, {"rows", other}, {"client_keys", principal}, {"table_key", table_key}}), line_of_before("root: read the disk grant table of principal ", principal, " from the store module_files: ", other, " rows, with the tag of ", table_key, "; ", principal, " client keys of remote"))
			expect(t, render(t, file, "Table_Written", {{"principal", principal}, {"rows", other}, {"client_keys", principal}, {"table_key", table_key}}), line_of_before("root: the disk grant table of principal ", principal, " is written in the store module_files: ", other, " rows, with the tag of ", table_key, "; ", principal, " client keys of remote"))
		}
		for uses in CLIENT_USES {
			expect(t, render(t, file, "Client_Key_Uses_Added", {{"principal", principal}, {"client_key", key_head}, {"uses", uses}}), line_of_before("root: principal ", principal, " gave the client key ", key_head, " more uses: ", uses))
			expect(t, render(t, file, "Client_Key_Allowed_For_Display", {{"principal", principal}, {"client_key", key_head}, {"uses", uses}}), line_of_before("root: principal ", principal, " allowed the client key ", key_head, " for the remote display: ", uses))
			expect(t, render(t, file, "Client_Key_Restored_For_Display", {{"principal", principal}, {"client_key", key_head}, {"uses", uses}}), line_of_before("root: the client key ", key_head, " of the remote display holds again for principal ", principal, ", from its disk grant table: ", uses))
			expect(t, render(t, file, "Client_Key_Revoked", {{"principal", principal}, {"connections_ended", other}, {"client_key", key_head}, {"uses", uses}}), line_of_before("root: principal ", principal, " revoked the client key ", key_head, " (", uses, "): connections to services ended: ", other))
		}
		expect(t, render(t, file, "Client_Key_Revoked_Contested", {{"principal", principal}, {"client_key", key_head}}), line_of_before("root: principal ", principal, " revoked the client key ", key_head, " of remote, which was contested: connections to services ended: 0"))
		expect(t, render(t, file, "Client_Key_Restored", {{"principal", principal}, {"client_key", key_head}}), line_of_before("root: the client key ", key_head, " of remote holds again for principal ", principal, ", from its disk grant table: each call of that client acts for it"))
		expect(t, render(t, file, "Client_Table_Full", {{"principal", principal}, {"client_key", key_head}}), line_of_before("root: the client table of remote has no free row for the client key ", key_head, " of principal ", principal, ": the key holds for no principal"))
		expect(t, render(t, file, "Client_Key_Contest_Ended", {{"principal", principal}, {"revoking_principal", other}, {"client_key", key_head}}), line_of_before("root: the client key ", key_head, " of remote holds again for principal ", principal, ": principal ", other, " revoked it, so it is no longer contested"))
		expect(t, render(t, file, "Client_Key_Not_In_Table", {{"principal", principal}, {"connections_ended", other}, {"client_key", key_head}}), line_of_before("root: the client key ", key_head, " of remote, which principal ", principal, " allowed before its disk grant table was read, is not in that table: its grant ends; connections to services ended: ", other))
		expect(t, render(t, file, "Client_Key_View_Paused", {{"principal", principal}, {"front_principal", other}, {"connections_ended", principal}, {"client_key", key_head}}), line_of_before("root: the client key ", key_head, " of principal ", principal, " loses the view and the input while the session of principal ", other, " is in front; connections to services ended: ", principal))
		expect(t, render(t, file, "Client_Key_View_Back", {{"principal", principal}, {"client_key", key_head}}), line_of_before("root: the client key ", key_head, " of principal ", principal, " has the view again: the session of its principal is in front"))
		expect(t, render(t, file, "Remote_Connection_Refused_Contested", {{"principal", principal}, {"other_principal", other}, {"client_key", key_head}}), line_of_before("root: refused a connection of remote for the client key ", key_head, ": it is contested between principal ", principal, " and principal ", other, ", and acts for neither"))
	}
}

// The facts of the principals, of the trust and of the start policy write
// the lines of before: the principals and the counts 0, 1 and max(u64); a
// time of max(i64); a principal name of 23 bytes, the longest; a nickname
// of 31 bytes; two hashes of different bytes; each text of a closed set.
@(test)
the_principal_and_start_policy_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	principal_name := strings.repeat("n", 23, context.temp_allocator)
	nickname := strings.repeat("k", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	key_head := "0123456789abcdef"
	largest_time := u64(max(i64))
	hash, named_hash: [module.HASH_SIZE]u8
	for index in 0 ..< module.HASH_SIZE {
		hash[index] = u8(0x10 + index)
		named_hash[index] = u8(0xF0 - index)
	}

	expect(t, render(t, file, "Principal_Creation_Started", {{"principal_name", principal_name}}), line_of_before("root: the principal \"", principal_name, "\" is created in the window of unlock"))
	expect(t, render(t, file, "Principal_Recorded", {{"principal_name", principal_name}, {"public_key_head", key_head}}), line_of_before("root: principal 1 \"", principal_name, "\" is recorded, its public key ", key_head, "...; its session is locked"))
	for mode in UNLOCK_MODES {
		expect(t, render(t, file, "Unlock_Stopped_By_Lock", {{"unlock_mode", mode}}), line_of_before("root: the lock stops the window of unlock, which ran for ", mode, "; unlock asks for the passphrase when it stopped"))
	}
	for end in CHANGE_ENDS {
		expect(t, render(t, file, "Principal_Change_Ended", {{"change_end", end}}), line_of_before("root: the change in the window of unlock ends: ", end))
	}
	expect(t, render(t, file, "Change_End_Not_Delivered", {{"caller", process}}), line_of_before("root: the completion ring of ", sentence.Module_Name{process}, " is full: the end of the change does not reach it, and its line waits until Escape"))
	expect(t, render(t, file, "Chosen_Start_Policy_Name_Reserved", {{"nickname", nickname}}), line_of_before("root: the chosen start policy \"", nickname, "\" is not read: the root service gives this name a grant, or a module of the boot image has it: the rescue start policy starts"))
	expect(t, render(t, file, "Chosen_Start_Policy_Load_Busy", {{"nickname", nickname}}), line_of_before("root: the chosen start policy \"", nickname, "\" is not read: another load from the disk runs: the rescue start policy starts"))
	expect(t, render(t, file, "Chosen_Start_Policy_Not_Mapped", {{"nickname", nickname}}), line_of_before("root: the chosen start policy \"", nickname, "\" is not read: the call ring and the call region of the storage service do not map: the rescue start policy starts"))
	expect(t, render(t, file, "Chosen_Start_Policy_No_Service", {{"nickname", nickname}}), line_of_before("root: the chosen start policy \"", nickname, "\" is not read: the disk processes service does not run: the rescue start policy starts"))
	expect(t, render(t, file, "Chosen_Start_Policy_Read", {{"hash", hash}, {"nickname", nickname}}), line_of_before("root: reads the chosen start policy \"", nickname, "\", the file ", sentence.Hash{hash[:]}, ", from the store ", STORE_NAME, " of principal 0"))
	expect(t, render(t, file, "Chosen_Start_Policy_Unmeasured", {{"nickname", nickname}}), line_of_before("root: the chosen start policy \"", nickname, "\" does not run unmeasured: it is not started"))
	expect(t, render(t, file, "Start_Policy_Refused_Reserved_Name", {{"nickname", nickname}}), line_of_before("root: refused the start policy ", sentence.Module_Name{nickname}, ": the root service gives this name a grant, or a module of the boot image has it, and the start policy runs under its nickname"))
	expect(t, render(t, file, "Start_Policy_Refused_No_Row", {{"nickname", nickname}}), line_of_before("root: refused the start policy ", sentence.Module_Name{nickname}, ": the nickname names no module, as it has no row in the disk grant table of principal 0; name the hash of its file"))
	expect(t, render(t, file, "Start_Policy_Refused_Other_File", {{"named_hash", named_hash}, {"hash", hash}, {"nickname", nickname}}), line_of_before("root: refused the start policy ", sentence.Module_Name{nickname}, ": the nickname names the file ", sentence.Hash{named_hash[:]}, ", and the command names the file ", sentence.Hash{hash[:]}))
	expect(t, render(t, file, "Start_Policy_Refused_Holds_Store", {{"nickname", nickname}}), line_of_before("root: refused the start policy ", sentence.Module_Name{nickname}, ": its row holds the grant store, and a start policy holds the grant Start_Policy and nothing else"))
	expect(t, render(t, file, "Start_Policy_Chosen", {{"hash", hash}, {"nickname", nickname}}), line_of_before("root: principal 0 chose the start policy ", sentence.Module_Name{nickname}, ", the file ", sentence.Hash{hash[:]}, ": it runs at the next start of the machine, with the grant Start_Policy only; the machine key keeps the choice on the disk"))
	for cause in FAILURE_CAUSES {
		expect(t, render(t, file, "No_Start_Policy", {{"failure_cause", cause}}), line_of_before("root: no start policy at all: ", cause, "; this service serves the root ring of each process that runs, and starts nothing more"))
	}

	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		other := max(u64) - count
		expect(t, render(t, file, "Machine_Principal_Measured", {{"measure_register", count}, {"measure_value", hash}}), line_of_before("root: principal 0 is the machine: the system is measured, PCR ", count, " = ", sentence.Hash{hash[:]}, "; its key, the attestation key of the TPM, is not built"))
		expect(t, render(t, file, "Session_Started", {{"principal", count}, {"principal_name", principal_name}}), line_of_before("root: the session of principal ", count, " \"", principal_name, "\" starts: the desktop starts each process in it"))
		expect(t, render(t, file, "Session_Ended", {{"principal", count}, {"stopped_processes", other}, {"principal_name", principal_name}}), line_of_before("root: the session of principal ", count, " \"", principal_name, "\" ends: ", other, " processes stopped"))
		expect(t, render(t, file, "Unlock_Restarts_Given_Up", {{"restart_limit", count}}), line_of_before("root: unlock stopped ", count, " times while a principal is locked, with no stop that the root service asked: it starts no more until the machine starts again"))
		expect(t, render(t, file, "Passphrase_Change_Started", {{"principal", count}, {"principal_name", principal_name}}), line_of_before("root: the passphrase of principal ", count, " \"", principal_name, "\" changes in the window of unlock"))
		expect(t, render(t, file, "Recovery_Key_Change_Started", {{"principal", count}, {"principal_name", principal_name}}), line_of_before("root: a new recovery key of principal ", count, " \"", principal_name, "\" is made in the window of unlock"))
		time := min(count, largest_time)
		expect(t, render(t, file, "Boot_Image_Agrees", {{"checked_entries", count}, {"check_time", time}}), line_of_before("root: the boot image agrees with the system description that the boot program verified: ", count, " modules and resources checked in ", sentence.Duration{time, .Microseconds}, "; the kernel was checked by the boot program only"))
		expect(t, render(t, file, "Boot_Program_Check_Time", {{"check_time", time}}), line_of_before("root: the boot program checked the signature and every hash in ", sentence.Duration{time, .Microseconds}))
		expect(t, render(t, file, "System_Description_Measured", {{"measure_register", count}, {"measure_tries", other}, {"measure_value", hash}}), line_of_before("root: measured: PCR ", count, " = ", sentence.Hash{hash[:]}, ", at try ", other))
		expect(t, render(t, file, "Tpm_Floors", {{"key_floor", count}, {"key_number", other}, {"version_floor", count}, {"security_version", other}}), line_of_before("root: the TPM floors before this start: the key floor ", count, " for the key number ", other, ", the version floor of that key number ", count, " for the security version ", other))
		expect(t, render(t, file, "Floor_State_Unknown", {{"floor_state", count}}), line_of_before("root: the boot record names the floor state ", count, ", which names no state"))
		// A bound of time: the line wrote the number and " ms".
		expect(t, render(t, file, "Unlock_Machine_Key_Late", {{"bound", time}}), line_of_before("root: unlock gave no machine key within the hang bound of ", time, " ms: the choice of principal 0 is not read, and unlock is stopped"))
		expect(t, render(t, file, "Unlock_Stop_Late", {{"bound", time}}), line_of_before("root: unlock did not stop within the hang bound of ", time, " ms after its stop was asked: the start policy starts, and its row unlock does not start while it runs"))
		expect(t, render(t, file, "Machine_Table_Read_Late", {{"bound", time}}), line_of_before("root: the read of the disk grant table of principal 0 did not end within the hang bound of ", time, " ms: the choice of principal 0 is not read"))
		expect(t, render(t, file, "Plan_At_Start_Waiting", {{"bound", time}}), line_of_before("root: the plans service reads the plan of principal 0 before the start policy, within the hang bound of ", time, " ms"))
		expect(t, render(t, file, "Plan_At_Start_Late", {{"bound", time}}), line_of_before("root: the plans service did not read the plan of principal 0 within the hang bound of ", time, " ms: the start policy starts with the roles in force"))
		expect(t, render(t, file, "Start_Policy_Processes_Late", {{"left_processes", count}, {"bound", time}}), line_of_before("root: ", count, " processes of the failed start policy did not stop within the hang bound of ", time, " ms: the rescue start policy starts beside them"))
		expect(t, render(t, file, "Start_Policy_Choice_Refused_Principal", {{"principal", count}}), line_of_before("root: refused a choice of a start policy: the caller acts for principal ", count, ", and only principal 0 chooses the start policy of the machine"))
		expect(t, render(t, file, "Start_Request_Refused", {{"start_request", count}, {"start_request_source", other}}), line_of_before("root: the boot record names the start request ", count, " with the source ", other, ", which the border refuses: the rescue start policy starts"))
		expect(t, render(t, file, "Start_Policy_Restart_Refused", {{"restart_limit", count}, {"counted_names", other}, {"refused_process", process}}), line_of_before("root: refused a start of ", sentence.Module_Name{process}, " by the start policy from the disk: past its ", count, " restarts, or past the ", other, " names whose starts the root service counts, it stays stopped"))
	}
}

// A fact type of the root service with no field, and the line that it
// replaced: its template is the whole sentence.
@(private = "file")
Fact_Without_Field :: struct {
	type_name: string,
	line:      string,
}

// Each fact type with no field writes the line of before, word for word.
@(test)
the_facts_with_no_field_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	lines := [?]Fact_Without_Field {
		{"Debug_Image_Absent", "root: no debug image: a stop report names each frame by its module and its offset"},
		{"Standard_Vga_Without_Framebuffer", "root: the standard VGA does not hold the framebuffer of the firmware and its display registers: the compositor writes the screen page that the display shows"},
		{"Standard_Vga_Mode_Unknown", "root: the display registers of the standard VGA do not say the mode of the framebuffer of the firmware with two screen pages: the compositor writes the screen page that the display shows"},
		{"Entropy_Service_Stopped", "root: the entropy service stopped: no more fresh bytes for the running processes"},
		{"Failure_Shown", "root: the boot display shows the failure"},
		{"No_Screen", "root: no screen: a console and windows only on a screen of memory that the start list gives; the other services start"},
		{"Compositor_Stopped", "root: the compositor stopped: no screen; a start of a window or a terminal is refused from now on"},
		{"Console_Renderer_Serial", "root: no compositor in the boot image: the console writes to the second serial port through serial_terminal"},
		{"Console_Renderer_Grid", "root: no compositor in the boot image: the console draws a text grid on the screen through grid_terminal"},
		{"Console_Renderer_Dom", "root: no compositor in the boot image: the console writes lines for a page to the second serial port through dom_terminal"},
		{"Palette_Provider_Absent", "root: no palette provider"},
		{"Machine_Passphrase_Refused_Unreadable", "root: refused a machine passphrase: the record of the machine passphrase cannot be read, and a new one would replace a key that can be good"},
		{"Machine_Passphrase_Refused_Exists", "root: refused a machine passphrase: the machine has one, and a change is not built"},
		{"Machine_Passphrase_Refused_Unlock_Runs", "root: refused a machine passphrase: unlock runs; it is set when unlock stopped"},
		{"Machine_Passphrase_Setting_Started", "root: the machine passphrase is set in the window of unlock"},
		{"Machine_Key_Seal_Refused_No_Tpm", "root: refused a machine key sealed by the TPM: no TPM service runs, as the system is not measured into a TPM"},
		{"Machine_Key_Seal_Refused_Not_Verified", "root: refused a machine key sealed by the TPM: the firmware did not verify the boot program (Secure Boot is off), so a seal would trust a boot program that nothing verified"},
		{"Machine_Key_Seal_Refused_Exists", "root: refused a machine key sealed by the TPM: the machine has a record of its machine key, and a change is not built"},
		{"Machine_Key_Seal_Refused_Unlock_Runs", "root: refused a machine key sealed by the TPM: unlock runs; it is made when unlock stopped"},
		{"Machine_Key_Seal_Started", "root: the machine key is sealed by the TPM in the window of unlock"},
		{"Machine_Key_Sealed_Grants_Wait", "root: the machine key is sealed by the TPM: the disk grants of principal 0 wait for the unseal, and the machine runs"},
		{"Machine_Passphrase_Grants_Wait", "root: the machine has a passphrase: the disk grants of principal 0 wait for it, and the machine runs"},
		{"Machine_Passphrase_Record_Unreadable", "root: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and no change and no new passphrase is taken"},
		{"Machine_Table_Change_Refused_Not_Typed", "root: refused a change of the disk grant table of principal 0: the machine passphrase is not typed; type it in the window of unlock"},
		{"Machine_Table_Change_Refused_Record_Unreadable", "root: refused a change of the disk grant table of principal 0: the record of the machine passphrase cannot be read, so nothing is written over the table on the disk"},
		{"Machine_Principal_Unmeasured", "root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built"},
		{"Passphrase_Change_Refused_No_Session", "root: refused a change of the passphrase: the caller runs in no session of a named principal"},
		{"Passphrase_Change_Refused_Unlock_Runs", "root: refused a change of the passphrase: unlock runs; it is made when unlock stopped"},
		{"Start_Policy_Choice_Unread_No_Tpm", "root: no choice of a start policy is read: no TPM service runs, so no machine key opens with no passphrase"},
		{"Start_Policy_Choice_Unread_No_Disk", "root: no choice of a start policy is read: the machine has no data disk"},
		{"Unlock_Reads_Machine_Key", "root: unlock reads the machine key with no window, before the start policy: the choice of principal 0 is in its disk grant table"},
		{"Plan_At_Start_Unread_Rescue", "root: the plan of principal 0 is not read before the rescue start policy: the roles of the boot image hold"},
		{"Plan_At_Start_Unread_No_Disk", "root: the plan of principal 0 is not read before the start policy: the machine has no data disk"},
		{"Plan_At_Start_Unread_No_Plans_Module", "root: the plan of principal 0 is not read before the start policy: the boot image has no holder of the role Plans"},
		{"Plan_At_Start_Unread_No_Storage_Module", "root: the plan of principal 0 is not read before the start policy: the boot image has no holder of the role Storage"},
		{"Plan_At_Start_No_Plan", "root: principal 0 has no plan stored: the roles of the boot image hold"},
		{"Plan_At_Start_Plan_Refused", "root: the boot image cannot hold the roles of the stored plan of principal 0: the roles of the boot image hold"},
		{"Plan_At_Start_Store_Unread", "root: the plans service cannot read the plan of principal 0 from its store: the roles of the boot image hold"},
		{"Plan_At_Start_Core_Unread", "root: the plans service did not read the roles in force: the roles of the boot image hold"},
		{"Plan_At_Start_Holder_Stopped", "root: the plans service stopped before it read the plan of principal 0: the roles of the boot image hold"},
		{"Machine_Table_Unread_Before_Start_Policy", "root: the disk grant table of principal 0 is not read before the start policy: no choice of principal 0 is known"},
		{"Start_Policy_Choice_Refused_Empty_Nickname", "root: refused a choice of a start policy: a nickname of no byte ends the choice, and the command names a hash"},
		{"Start_Policy_Choice_Refused_No_Machine_Key", "root: refused a choice of a start policy: the machine has no machine key, so the disk grant table of principal 0 lasts until the machine stops, and no choice reaches the next start; machine_seal() makes a machine key"},
		{"Start_Policy_Choice_Refused_Passphrase", "root: refused a choice of a start policy: the machine key opens with the machine passphrase, and the root service reads the choice before a passphrase can be typed"},
		{"Start_Policy_Choice_Absent", "root: principal 0 has chosen no start policy: the default start policy runs at the next start"},
		{"Start_Policy_Choice_Ended", "root: principal 0 ended its choice of a start policy: the default start policy runs at the next start of the machine"},
		{"Start_Policy_Absent", "root: the start policy is absent from the boot image: the rescue start policy starts"},
		{"Font_Outlines_Absent", "root: the boot image has no valid font outlines: the text of the system is Spleen 8x16"},
		{"Tpm_Service_Absent_Unmeasured", "root: no TPM service: the system is not measured into a TPM, so no key is sealed to its measure"},
		{"Tpm_Service_Absent_Table_Full", "root: no TPM service: the table of the processes is full"},
		{"Tpm_Service_Stopped", "root: the TPM service stopped: no key is sealed or unsealed until the machine starts again"},
		{"Description_Signed_By_Test_Key", "root: the system description is signed by the test signing key, whose private key is published: this system is not trusted"},
		{"Verified_By_Boot_Program", "root: verified by the boot program, which the firmware did not verify"},
		{"Verified_By_Firmware", "root: verified by the firmware (Secure Boot), then by the boot program"},
		{"Description_Unmeasured_No_Tpm", "root: the system description is not measured into the TPM: the firmware has no TPM"},
		{"Measure_Not_Tried", "root: the boot program did not try the measure"},
		{"Tpm_Floor_Foreign", "root: an index of a TPM floor was not a floor that the boot program could read: another system defined or planted it, or PCR 7 changed; the boot program took it as 0, and replaced it with Secure Boot on"},
		// The start policy of the boot image that a rescue replaces, when
		// the boot image has no module of it.
		{"Rescue_By_Key_Of_No_Module", "root: the key R was held at the start: the rescue start policy starts in place of the start policy of no module"},
		{"Rescue_By_Boot_Entry_Of_No_Module", "root: the boot entry modus (rescue) started the machine: the rescue start policy starts in place of the start policy of no module"},
		{"Rescue_By_Refused_Record_Of_No_Module", "root: the rescue start policy starts in place of the start policy of no module: the boot record asks for it with words that the border refuses"},
		// The machine parts page wrote "no part" in a list; its parts are
		// one fact each now.
		{"Machine_Parts_None", "root: the machine parts page holds no part"},
	}
	for item in lines {
		expect(t, render(t, file, item.type_name, {}), item.line)
	}
}

// A fact type whose line wrote a status of the kernel as its number, and
// the words around it: the field writes the name of the member now.
@(private = "file")
Status_Line :: struct {
	type_name: string,
	before:    string,
	after:     string,
}

// The status of a kernel operation is the name of its member: the edges
// are the first member, the last member, and a word past the last member,
// which the render writes as its number, never as the name of another
// member. Each line of a status with a name, a hash or a size writes those
// fields at their edges.
@(test)
the_statuses_of_the_root_service_are_the_names_of_their_members :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	lines := [?]Status_Line {
		{"Disk_Processes_Budget_Refused", "root: cannot make the budget of the disk processes: status ", ""},
		{"Entropy_Configuration_Unread", "root: cannot read the configuration of the bus for the entropy device: status ", ": the random seed of the system has the sources of the processor only"},
		{"Entropy_Service_Start_Failed", "root: cannot start the entropy service: status ", ": the random seed of the system has the sources of the processor only"},
		{"Entropy_Ring_Open_Failed", "root: cannot open the entropy ring: status ", ": the random seed of the system has the sources of the processor only"},
		{"Fresh_Bytes_Pages_Failed", "root: cannot create the fresh bytes pages: status ", ": a running process mixes no new bytes into its generator"},
		{"Shortage_Start_Failed", "root: cannot start shortage: status ", ""},
		{"Operation_Fuzzing_Start_Failed", "root: cannot start operation_fuzzing: status ", ""},
		{"Input_Start_Failed", "root: cannot start input: status ", ""},
		{"Input_Tablet_Arm_Failed", "root: cannot give the virtio tablet to input: status ", ": the pointer is the PS/2 mouse only"},
		{"Compositor_Control_Ring_Failed", "root: cannot start the compositor: no control ring: status ", ""},
		{"Compositor_Service_Ring_Failed", "root: cannot start the compositor: no service ring: status ", ""},
		{"Compositor_Start_Failed", "root: cannot start the compositor: status ", ""},
		{"Machine_Parts_Page_Failed", "root: cannot create the machine parts page: status ", ""},
		{"Tpm_Service_Start_Failed", "root: cannot start the TPM service: status ", ""},
		{"Devices_Service_Start_Failed", "root: cannot start the devices service: status ", ""},
		{"Bus_Configuration_Unread", "root: cannot read the configuration of the bus: status ", ": no device service starts"},
		{"Principals_Service_Start_Failed", "root: cannot start the principals service: status ", ""},
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	failure := strings.repeat("f", ROOT_FAILURE_MOST, context.temp_allocator)
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0x5A + index)
	}
	status_words := [3]u64{u64(min(op.Status)), u64(max(op.Status)), u64(max(op.Status)) + 1}
	for word in status_words {
		// The words of the status: its name, or the number of a word that
		// names no member.
		status_text := line_of_before(word)
		if name, named := module.contract_enum_member_name(.Status, word); named {
			status_text = name
		}
		for item in lines {
			expect(t, render(t, file, item.type_name, {{"status", word}}), line_of_before(item.before, status_text, item.after))
		}
		expect(t, render(t, file, "Root_Failed", {{"status", word}, {"failure", failure}}), line_of_before("root: ", failure, ": status ", status_text))
		expect(t, render(t, file, "Start_Failed", {{"status", word}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": status ", status_text))
		expect(t, render(t, file, "Tpm_Registers_Refused", {{"registers", u64(0xFED4_0000)}, {"status", word}}), line_of_before("root: no TPM service: the registers of the TPM at ", sentence.Hex(0xFED4_0000), " are refused: status ", status_text))
		expect(t, render(t, file, "Disk_Processes_Service_Start_Failed", {{"status", word}}), line_of_before("root: cannot start the disk processes service: status ", status_text))
		expect(t, render(t, file, "Disk_Load_Refused_No_Memory", {{"object_bytes", max(u64)}, {"status", word}, {"refused_process", process}}), line_of_before("root: refused ", sentence.Module_Name{process}, " from the disk: no memory for its ", max(u64), " bytes: status ", status_text))
		expect(t, render(t, file, "Disk_Load_Refused_Import_No_Memory", {{"object_bytes", u64(0)}, {"status", word}, {"refused_process", process}, {"file", "fffffffffffffffffffffff"}}), line_of_before("root: refused ", sentence.Module_Name{process}, " from the disk: no memory in the budget of the disk processes for the ", u64(0), " bytes of the file ", sentence.Module_Name{"fffffffffffffffffffffff"}, " of the store ", STORE_NAME, ": status ", status_text))
	}
	// The facts of a start that the root service refused: the outcome that
	// the refusal named, by its name, or the number of a word that names
	// none.
	outcome_lines := [?]Status_Line {
		{"Unlock_Start_Failed", "root: unlock did not start (outcome ", "): no named principal can be created or unlocked"},
		{"Start_Policy_Choice_Unread_Unlock_Failed", "root: no choice of a start policy is read: unlock did not start, with the outcome ", ""},
		{"Settings_Boot_Pass_Failed", "root: the boot pass of settings did not start (outcome ", "): the settings are the defaults"},
		{"Settings_Due_Start_Failed", "root: the start of settings that waited for its pass did not start (outcome ", ")"},
		{"Appearance_Next_Not_Started", "root: the next appearance of the Control Center did not start settings (outcome ", ")"},
		{"Start_Policy_Not_Started_Of_No_Module", "root: the start policy of no module did not start, with the outcome ", ": the rescue start policy starts"},
		{"Plan_At_Start_Start_Failed", "root: the plans service did not start to read the plan of principal 0: outcome ", "; the roles of the boot image hold"},
	}
	outcome_words := [3]u64{u64(min(call_outcome.Call_Outcome)), u64(max(call_outcome.Call_Outcome)), u64(max(call_outcome.Call_Outcome)) + 1}
	for word in outcome_words {
		outcome_text := line_of_before(word)
		if name, named := module.contract_enum_member_name(.Call_Outcome, word); named {
			outcome_text = name
		}
		for item in outcome_lines {
			expect(t, render(t, file, item.type_name, {{"outcome", word}}), line_of_before(item.before, outcome_text, item.after))
		}
		expect(t, render(t, file, "Chosen_Start_Policy_No_Connection", {{"outcome", word}, {"nickname", process}}), line_of_before("root: the chosen start policy \"", process, "\" is not read: no connection to the storage service, outcome ", outcome_text, ": the rescue start policy starts"))
		expect(t, render(t, file, "Chosen_Start_Policy_Not_Started", {{"outcome", word}, {"nickname", process}}), line_of_before("root: the chosen start policy \"", process, "\" is not started, with the outcome ", outcome_text, ": the rescue start policy starts"))
		expect(t, render(t, file, "Start_Policy_Not_Started", {{"start_policy_hash", hash}, {"outcome", word}}), line_of_before("root: the start policy ", sentence.Hash{hash[:4]}, "…", " did not start, with the outcome ", outcome_text, ": the rescue start policy starts"))
		expect(t, render(t, file, "Disk_Load_Refused_No_Connection", {{"outcome", word}, {"refused_process", process}}), line_of_before("root: refused ", sentence.Module_Name{process}, " from the disk: no connection to the storage service: outcome ", outcome_text))
		expect(t, render(t, file, "Disk_Load_Refused_Not_Started", {{"outcome", word}, {"refused_process", process}}), line_of_before("root: refused ", sentence.Module_Name{process}, " from the disk: it does not start: outcome ", outcome_text))
	}
}

// An error record that a line wrote as the sentence of the console is the
// fact of its fields: the kind and the unit by the names of their members,
// the other values with their sign. The edges: the first and the last
// member, a word of a kind or a unit that names no member (its number),
// and the values 0, -1 and the largest.
@(test)
the_error_records_of_the_root_service_are_facts_of_their_fields :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	heads := [?][2]string {
		{"Entropy_Read_Refused", "root: the entropy service refused a read: "},
		{"Network_Control_Command_Refused", "root: the network service refused a command of its control ring: "},
		{"Table_Call_Refused", "root: the storage service refused the call of a disk grant table: "},
		{"Disk_Load_Read_Refused", "root: the storage service refused the read of a disk process: "},
	}
	kinds := [3]u64{u64(min(errors.Kind)), u64(max(errors.Kind)), u64(max(errors.Kind)) + 1}
	units := [3]u64{u64(min(errors.Unit)), u64(max(errors.Unit)), u64(max(errors.Unit)) + 1}
	values := [3]i64{0, -1, max(i64)}
	for head in heads {
		for index in 0 ..< 3 {
			kind_text := line_of_before(kinds[index])
			if errors.Kind(kinds[index]) <= max(errors.Kind) {
				kind_text = errors.KIND_NAMES[errors.Kind(kinds[index])]
			}
			unit_text := line_of_before(units[index])
			if errors.Unit(units[index]) <= max(errors.Unit) {
				unit_text = errors.UNIT_MEMBER_NAMES[errors.Unit(units[index])]
			}
			value := values[index]
			written := render(t, file, head[0], {{"kind", kinds[index]}, {"unit", units[index]}, {"operation", signed_bits(value)}, {"argument", signed_bits(value)}, {"value", signed_bits(value)}, {"limit", signed_bits(value)}, {"found", signed_bits(value)}})
			expect(t, written, line_of_before(head[1], "kind ", kind_text, ", unit ", unit_text, ", operation ", value, ", argument ", value, ", value ", value, ", limit ", value, ", found ", value))
		}
	}
}

// The facts of the start policy, of its measure and of the trust write the
// lines of before: a hash of 32 different bytes, whose head is its first 4
// bytes and "…"; a stop of itself with each outcome, and each other cause;
// the bounds 0 and max(i64); each text of a closed set; each fault of the
// check of the boot image, with an entry of 31 bytes and with none.
@(test)
the_start_policy_and_trust_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	hash, other_hash: [module.HASH_SIZE]u8
	for index in 0 ..< module.HASH_SIZE {
		hash[index] = u8(0x10 + index)
		other_hash[index] = u8(0xC0 + index)
	}
	head := line_of_before(sentence.Hash{hash[:4]}, "…")
	expect(t, render(t, file, "Rescue_By_Key", {{"replaced_hash", hash}}), line_of_before("root: the key R was held at the start: the rescue start policy starts in place of the start policy ", head))
	expect(t, render(t, file, "Rescue_By_Boot_Entry", {{"replaced_hash", hash}}), line_of_before("root: the boot entry modus (rescue) started the machine: the rescue start policy starts in place of the start policy ", head))
	expect(t, render(t, file, "Rescue_By_Refused_Record", {{"replaced_hash", hash}}), line_of_before("root: the rescue start policy starts in place of the start policy ", head, ": the boot record asks for it with words that the border refuses"))
	for cause in op.Stop_Cause {
		if cause == .Itself {
			for outcome in op.Stop_Outcome {
				stop := line_of_before(op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome])
				fields := []Fact_Test_Field{{"start_policy_hash", hash}, {"cause", u64(cause)}, {"outcome", u64(outcome)}}
				expect(t, render(t, file, "Rescue_Stopped_Before_Usable", fields), line_of_before("root: the rescue start policy ", head, " stopped before the machine was usable: ", stop))
				expect(t, render(t, file, "Start_Policy_Stopped_Before_Usable", fields), line_of_before("root: the start policy ", head, " stopped before the machine was usable: ", stop, "; the rescue start policy starts"))
				expect(t, render(t, file, "Start_Policy_Stopped_After_Usable", fields), line_of_before("root: the start policy ", head, " stopped: ", stop, ", after the machine was usable; the rescue start policy starts"))
				expect(t, render(t, file, "Rescue_Stopped_After_Usable", fields), line_of_before("root: the rescue start policy ", head, " stopped: ", stop, ", after the machine was usable"))
			}
			continue
		}
		stop := op.STOP_CAUSE_TEXTS[cause]
		fields := []Fact_Test_Field{{"start_policy_hash", hash}, {"cause", u64(cause)}}
		expect(t, render(t, file, "Rescue_Stopped_Before_Usable_Without_Outcome", fields), line_of_before("root: the rescue start policy ", head, " stopped before the machine was usable: ", stop))
		expect(t, render(t, file, "Start_Policy_Stopped_Before_Usable_Without_Outcome", fields), line_of_before("root: the start policy ", head, " stopped before the machine was usable: ", stop, "; the rescue start policy starts"))
		expect(t, render(t, file, "Start_Policy_Stopped_After_Usable_Without_Outcome", fields), line_of_before("root: the start policy ", head, " stopped: ", stop, ", after the machine was usable; the rescue start policy starts"))
		expect(t, render(t, file, "Rescue_Stopped_After_Usable_Without_Outcome", fields), line_of_before("root: the rescue start policy ", head, " stopped: ", stop, ", after the machine was usable"))
	}
	bounds := [2]u64{0, u64(max(i64))}
	for bound in bounds {
		expect(t, render(t, file, "Rescue_Not_Usable_In_Time", {{"bound", bound}, {"start_policy_hash", hash}}), line_of_before("root: the rescue start policy ", head, " sent no Machine_Usable within the hang bound of ", bound, " ms"))
		expect(t, render(t, file, "Start_Policy_Not_Usable_In_Time", {{"bound", bound}, {"start_policy_hash", hash}}), line_of_before("root: the start policy ", head, " sent no Machine_Usable within the hang bound of ", bound, " ms: the rescue start policy starts"))
	}
	for words in START_POLICY_WORDS {
		pages := [2]u64{0, max(u64)}
		expect(t, render(t, file, "Machine_Usable", {{"free_pages", pages[1]}, {"lowest_free_pages", pages[0]}, {"start_policy_hash", hash}, {"start_policy_words", words}}), line_of_before("root: the machine is usable, by the start policy ", head, " ", words, ": the budget of this service holds ", pages[1], " free pages, ", pages[0], " at the lowest"))
		measure := []Fact_Test_Field{{"start_policy_hash", hash}, {"start_policy_words", words}}
		expect(t, render(t, file, "Start_Policy_Unmeasured_Tpm_Stopped_Earlier", measure), line_of_before("root: the start policy ", head, " ", words, " is not measured: the TPM service stopped earlier in this run"))
		expect(t, render(t, file, "Start_Policy_Unmeasured_No_Tpm", measure), line_of_before("root: the start policy ", head, " ", words, " is not measured: the system is not measured into a TPM"))
		expect(t, render(t, file, "Start_Policy_Unmeasured_No_Measure_Ring", measure), line_of_before("root: the start policy ", head, " ", words, " is not measured: the TPM service has no measure ring"))
		expect(t, render(t, file, "Start_Policy_Unmeasured_Measure_Ring_Full", measure), line_of_before("root: the start policy ", head, " ", words, " is not measured: the measure ring of the TPM service is full"))
		expect(t, render(t, file, "Start_Policy_Unmeasured_Tpm_Stopped_During", measure), line_of_before("root: the start policy ", head, " ", words, " is not measured: the TPM service stopped during the measure"))
		expect(t, render(t, file, "Start_Policy_Unmeasured_Unknown_Status", {{"outcome_word", max(u64)}, {"start_policy_hash", hash}, {"start_policy_words", words}}), line_of_before("root: the start policy ", head, " ", words, " is not measured: the TPM service gave a completion that the root service cannot read, the outcome word ", max(u64)))
		expect(t, render(t, file, "Start_Policy_Unmeasured_No_Answer", {{"bound", u64(30_000)}, {"start_policy_hash", hash}, {"start_policy_words", words}}), line_of_before("root: the start policy ", head, " ", words, " is not measured: the TPM service gave no answer within ", u64(30_000), " ms"))
		expect(t, render(t, file, "Start_Policy_Measured", {{"start_policy_hash", hash}, {"measure_value", other_hash}, {"start_policy_words", words}}), line_of_before("root: the start policy ", head, " ", words, " is measured into PCR 12: PCR 12 = ", sentence.Hash{other_hash[:]}))
		for status_words in TPM_STATUS_WORDS {
			expect(t, render(t, file, "Start_Policy_Measure_Failed", {{"answer_value", u64(0)}, {"start_policy_hash", hash}, {"start_policy_words", words}, {"tpm_status", status_words}}), line_of_before("root: the measure of the start policy ", head, " ", words, " into PCR 12 failed: the TPM service answered ", status_words, ", value ", u64(0)))
		}
	}
	for part in MACHINE_PARTS {
		expect(t, render(t, file, "Machine_Part_Present", {{"machine_part", part}}), line_of_before("root: the machine parts page holds ", part))
	}

	// The trust: a word of the TPM in 16 digits with no "0x".
	tpm_words := [3]u64{0, 0x922, max(u64)}
	for word in tpm_words {
		expect(t, render(t, file, "Tpm_Service_Started", {{"registers", word}}), line_of_before("root: started tpm for the TPM at ", sentence.Hex(word), ": unlock seals keys to the measure of the system with it"))
		expect(t, render(t, file, "Description_Measure_Refused", {{"measure_status", word}, {"measure_tries", word}, {"measure_register", u64(11)}}), line_of_before("root: the TPM refused the measure of the system description: status ", sentence.Hex(word), ", after ", word, " tries: PCR ", u64(11), " does not hold it"))
		expect(t, render(t, file, "Description_Register_Unread", {{"measure_register", word}, {"measure_status", word}}), line_of_before("root: the system description is measured, but the read of PCR ", word, " failed: status ", sentence.Hex(word)))
		expect(t, render(t, file, "Tpm_Floor_Unread", {{"floor_status", word}}), line_of_before("root: the boot program could not read a TPM floor: status ", sentence.Hex(word), "; it took it as 0"))
	}
	fault_types := [system_description.Check_Fault]string {
		.None                = "",
		.Not_Valid           = "Image_Check_Failed_Not_Valid",
		.Image_Not_Valid     = "Image_Check_Failed_Image_Not_Valid",
		.Count_Differs       = "Image_Check_Failed_Count_Differs",
		.Name_Differs        = "Image_Check_Failed_Name_Differs",
		.Kind_Differs        = "Image_Check_Failed_Kind_Differs",
		.Size_Differs        = "Image_Check_Failed_Size_Differs",
		.Hash_Differs        = "Image_Check_Failed_Hash_Differs",
		.Stated_Hash_Differs = "Image_Check_Failed_Stated_Hash_Differs",
		.Outside_Image       = "Image_Check_Failed_Outside_Image",
	}
	entries := [2]string{"", strings.repeat("e", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)}
	for fault in system_description.Check_Fault {
		if fault == .None {
			continue
		}
		for entry in entries {
			expect(t, render(t, file, fault_types[fault], {{"expected_hash", hash}, {"found_hash", other_hash}, {"checked_entry", entry}}), line_of_before("root: ", entry, ": ", system_description.fault_sentences[fault], ": expected ", sentence.Hash{hash[:]}, ", found ", sentence.Hash{other_hash[:]}))
		}
	}
	// The failure of the root service holds the longest sentence of the
	// check of the boot image whole.
	longest_fault := 0
	for fault in system_description.Check_Fault {
		longest_fault = max(longest_fault, len(system_description.fault_sentences[fault]))
	}
	testing.expectf(t, len(": ") + longest_fault <= ROOT_FAILURE_MOST, "the failure of a fault of the whole image has %d bytes, more than %d", len(": ") + longest_fault, ROOT_FAILURE_MOST)
}

// The facts of the refusals of a start from the disk write the lines of
// before: a name of 24 bytes, the most that the command holds; the counts
// 0, 1 and max(u64); two hashes of different bytes.
@(test)
the_disk_refusal_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	name := strings.repeat("d", 24, context.temp_allocator)
	importer := strings.repeat("i", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	entry := strings.repeat("f", 23, context.temp_allocator)
	hash, other_hash: [module.HASH_SIZE]u8
	for index in 0 ..< module.HASH_SIZE {
		hash[index] = u8(0x20 + index)
		other_hash[index] = u8(0xA0 + index)
	}
	refused := []Fact_Test_Field{{"refused_process", name}}
	causes := [?][2]string {
		{"Disk_Load_Refused_Name_Empty", "the name has no byte"},
		{"Disk_Load_Refused_Name_Not_A_Process_Name", "the name is no name of a process: visible characters of ASCII, no \"/\", not \".\" or \"..\""},
		{"Disk_Load_Refused_Name_Of_Module_Store", "the name is the name of the store of the module files"},
		{"Disk_Load_Refused_Name_Of_Grant_Table", "the name is the name of the object of the disk grant table"},
		{"Disk_Load_Refused_Name_In_Grant_Table", "the grant table of the root service names it, and a disk process takes no grant by its name"},
		{"Disk_Load_Refused_Name_In_Boot_Image", "a module of the boot image has this name"},
		{"Disk_Load_Refused_Asker_Without_Principal", "the asker has no principal with a record"},
		{"Disk_Load_Refused_Load_Busy", "another load from the disk runs"},
		{"Disk_Load_Refused_Not_Mapped", "the call ring and the call region of the storage service do not map"},
		{"Disk_Load_Refused_Call_Not_Taken", "the storage service took no call"},
		{"Disk_Load_Refused_Asker_Stopped", "the process that asked for it stopped"},
		{"Disk_Load_Refused_Storage_Stopped", "the storage service stopped"},
		{"Disk_Load_Refused_No_Service", "the disk processes service does not run"},
		{"Disk_Load_Refused_Service_Stopped", "the disk processes service stopped"},
		{"Disk_Load_Refused_Service_Answer_Not_Allowed", "the disk processes service gave an answer that its contract does not allow"},
		{"Disk_Load_Refused_No_Object", "the store " + STORE_NAME + " has no object with this name"},
		{"Disk_Load_Refused_Read_Refused", "the storage service refused the read"},
		{"Disk_Load_Refused_Answer_Not_Allowed", "the storage service gave no answer that the description of its export allows"},
		{"Disk_Load_Refused_Object_Empty", "the object has no byte"},
		{"Disk_Load_Refused_Principal_Without_Record", "its principal has no record"},
		{"Disk_Load_Refused_Import_Entry_Name_Outside", "the storage service listed an entry whose name is out of its page"},
		{"Disk_Load_Refused_Import_Entry_Kind_Unknown", "the storage service listed an entry whose kind names no kind"},
	}
	for cause in causes {
		expect(t, render(t, file, cause[0], refused), line_of_before("root: refused ", sentence.Module_Name{name}, " from the disk: ", cause[1]))
	}
	before := line_of_before("root: refused ", sentence.Module_Name{name}, " from the disk: ")
	expect(t, render(t, file, "Disk_Load_Refused_Nickname_Other_File", {{"named_hash", hash}, {"hash", other_hash}, {"refused_process", name}}), line_of_before(before, "the nickname names the file ", sentence.Hash{hash[:]}, ", and the command names the file ", sentence.Hash{other_hash[:]}, "; nickname_move points it to another file"))
	expect(t, render(t, file, "Disk_Load_Refused_Hash_Differs", {{"found_hash", hash}, {"hash", other_hash}, {"refused_process", name}}), line_of_before(before, "its bytes have the hash ", sentence.Hash{hash[:]}, ", and the hash asked is ", sentence.Hash{other_hash[:]}))
	expect(t, render(t, file, "Disk_Load_Refused_Nickname_Moved", {{"named_hash", hash}, {"found_hash", other_hash}, {"refused_process", name}}), line_of_before(before, "the nickname names the file ", sentence.Hash{hash[:]}, " since the command, and the bytes have the hash ", sentence.Hash{other_hash[:]}))
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		other := max(u64) - count
		expect(t, render(t, file, "Disk_Load_Refused_Name_Too_Long", {{"name_limit", count}, {"refused_process", name}}), line_of_before(before, "the name has more than ", count, " bytes"))
		expect(t, render(t, file, "Disk_Load_Refused_Nickname_Without_Row", {{"principal", count}, {"refused_process", name}}), line_of_before(before, "the nickname has no row in the disk grant table of principal ", count, ": name the hash of its file"))
		bound := min(count, u64(max(i64)))
		expect(t, render(t, file, "Disk_Load_Refused_No_Answer", {{"bound", bound}, {"refused_process", name}}), line_of_before(before, "the storage service gave no answer in ", bound, " ms"))
		expect(t, render(t, file, "Disk_Load_Refused_Object_Too_Large", {{"object_bytes", count}, {"file_bytes_limit", other}, {"refused_process", name}}), line_of_before(before, "the object has ", count, " bytes, and the module file of a disk process has at most ", other))
		expect(t, render(t, file, "Disk_Load_Refused_No_Byte_At", {{"received_bytes", count}, {"object_bytes", other}, {"refused_process", name}}), line_of_before(before, "the storage service gave no byte at the byte ", count, " of ", other))
		expect(t, render(t, file, "Disk_Load_Refused_Too_Many_Bytes", {{"given_bytes", count}, {"left_bytes", other}, {"refused_process", name}}), line_of_before(before, "the storage service gave ", count, " bytes where the file has ", other, " left"))
		expect(t, render(t, file, "Disk_Load_Refused_Import_No_Byte_At", {{"received_bytes", count}, {"object_bytes", other}, {"refused_process", name}, {"file", entry}}), line_of_before(before, "the storage service gave no byte at the byte ", count, " of ", other, " of the file ", sentence.Module_Name{entry}))
		expect(t, render(t, file, "Disk_Load_Refused_Import_Too_Many_Bytes", {{"given_bytes", count}, {"left_bytes", other}, {"refused_process", name}, {"file", entry}}), line_of_before(before, "the storage service gave ", count, " bytes where the file ", sentence.Module_Name{entry}, " has ", other, " left"))
		expect(t, render(t, file, "Disk_Load_Refused_Import_Missing", {{"hash", hash}, {"scan_reads", count}, {"refused_process", name}, {"importer", importer}}), line_of_before(before, sentence.Module_Name{importer}, " imports ", sentence.Hash{hash[:]}, ", and no file of the boot image or of the store ", STORE_NAME, " has bytes with this hash; the import scan read ", count, " files"))
		expect(t, render(t, file, "Disk_Load_Refused_Import_Missing_Entries_Left_Out", {{"hash", hash}, {"scan_reads", count}, {"refused_process", name}, {"importer", importer}}), line_of_before(before, sentence.Module_Name{importer}, " imports ", sentence.Hash{hash[:]}, ", and no file of the boot image or of the store ", STORE_NAME, " has bytes with this hash; the import scan read ", count, " files", "; the store has more entries than the 64 that the scan notes"))
		expect(t, render(t, file, "Disk_Load_Refused_Import_Bounds", {{"wanted_capacity", count}, {"depth_limit", other}, {"refused_process", name}}), line_of_before(before, "its imports outside the boot image pass the bounds of the import scan: ", count, " modules of the store, ", other, " levels"))
	}
}

// The facts of the disk grant tables whose line had a free part write the
// lines of before: each cause of a call that failed, each problem of a
// table, each case of how long a table and a key last, each text of a
// closed set; the principals 0, 1 and max(u64); a nickname of 31 bytes.
@(test)
the_table_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	nickname := strings.repeat("k", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	key_head := "0123456789abcdef"
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0x33 + index)
	}
	table_lastings := [?][2]string {
		{"_Until_Stop", "; principal 0 has no passphrase, so its disk grant table lasts until the machine stops"},
		{"_Kept_By_Machine_Passphrase", "; the machine passphrase keeps the disk grant table of principal 0 on the disk"},
		{"_Kept_By_Passphrase", "; the passphrase of the principal keeps its disk grant table on the disk"},
	}
	key_lastings := [?][2]string {
		{"Client_Key_Allowed_Until_Stop", "; principal 0 has no passphrase, so the key lasts until the machine stops"},
		{"Client_Key_Allowed_Until_Stop_Forgotten", "; the disk grant table of the principal keeps nothing across a restart (disk_persistence), so the key lasts until the machine stops"},
		{"Client_Key_Allowed_Kept", "; the disk grant table of the principal keeps the key across a restart"},
	}
	long_problems := [?][2]string {
		{"Bad_Row", TABLE_PROBLEM_BAD_ROW},
		{"Bad_Client_Keys", TABLE_PROBLEM_BAD_CLIENT_KEYS},
	}
	principals := [3]u64{0, 1, max(u64)}
	for principal in principals {
		other := max(u64) - principal
		for failure in TABLE_CALL_FAILURES {
			expect(t, render(t, file, "Table_Not_Read", {{"principal", principal}, {"absent_grants_principal", principal}, {"call_failure", failure}}), line_of_before("root: the disk grant table of principal ", principal, " is not read: ", failure, "; the disk grants of principal ", principal, " stay absent until the machine starts again"))
			expect(t, render(t, file, "Table_Write_Tried_Again", {{"principal", principal}, {"try_number", other}, {"try_limit", principal}, {"call_failure", failure}}), line_of_before("root: the disk grant table of principal ", principal, " is not written: ", failure, "; try ", other, " of ", principal))
			expect(t, render(t, file, "Table_Write_Given_Up", {{"principal", principal}, {"try_limit", other}, {"call_failure", failure}}), line_of_before("root: the disk grant table of principal ", principal, " is not written after ", other, " tries: ", failure, "; the disk keeps an older table, so a grant taken since can come back at the next start, and no change is taken"))
		}
		for record in NEW_RECORDS {
			for problem in TABLE_PROBLEMS_IN_A_FIELD {
				expect(t, render(t, file, "Table_Refused_Written_Over", {{"principal", principal}, {"new_record", record}, {"table_problem", problem}}), line_of_before("root: refused the disk grant table of principal ", principal, " from the store module_files: ", problem, "; it gives no grant, and the table of ", record, " is written over it"))
			}
			for problem in long_problems {
				expect(t, render(t, file, strings.concatenate({"Table_Refused_", problem[0], "_Written_Over"}, context.temp_allocator), {{"principal", principal}, {"new_record", record}}), line_of_before("root: refused the disk grant table of principal ", principal, " from the store module_files: ", problem[1], "; it gives no grant, and the table of ", record, " is written over it"))
			}
		}
		// A table of an older format: the problem, its cause, and what the
		// principal does to use its clients again.
		for record in NEW_RECORDS {
			expect(t, render(t, file, "Table_Refused_Older_Format_Written_Over", {{"principal", principal}, {"new_record", record}}), line_of_before("root: the disk grant table of principal ", principal, " in the store module_files was not read: ", TABLE_PROBLEM_OLDER_FORMAT_CAUSE, "; its client keys and disk grants do not hold, and the table of ", record, " is written over it; ", TABLE_OLDER_FORMAT_TO_DO))
		}
		expect(t, render(t, file, "Table_Refused_Older_Format_Kept", {{"principal", principal}}), line_of_before("root: the disk grant table of principal ", principal, " in the store module_files was not read: ", TABLE_PROBLEM_OLDER_FORMAT_CAUSE, "; its client keys and disk grants do not hold, and the table is kept: no change is written over it; ", TABLE_OLDER_FORMAT_TO_DO))
		for problem in TABLE_PROBLEMS_IN_A_FIELD {
			expect(t, render(t, file, "Table_Refused_Kept", {{"principal", principal}, {"table_problem", problem}}), line_of_before("root: refused the disk grant table of principal ", principal, " from the store module_files: ", problem, "; it gives no grant, and it is kept: no change is written over it"))
		}
		for problem in long_problems {
			expect(t, render(t, file, strings.concatenate({"Table_Refused_", problem[0], "_Kept"}, context.temp_allocator), {{"principal", principal}}), line_of_before("root: refused the disk grant table of principal ", principal, " from the store module_files: ", problem[1], "; it gives no grant, and it is kept: no change is written over it"))
		}
		for lasting in table_lastings {
			for grant in DISK_GRANT_NAMES {
				grant_fields := []Fact_Test_Field{{"hash", hash}, {"principal", principal}, {"nickname", nickname}, {"grant", grant}}
				expect(t, render(t, file, strings.concatenate({"Grant_Lost", lasting[0]}, context.temp_allocator), grant_fields), line_of_before("root: the nickname ", sentence.Module_Name{nickname}, ", the file ", sentence.Hash{hash[:]}, ", lost the grant ", grant, " for principal ", principal, ", from its next start; its store stays on the disk", lasting[1]))
				expect(t, render(t, file, strings.concatenate({"Grant_Given", lasting[0]}, context.temp_allocator), grant_fields), line_of_before("root: the nickname ", sentence.Module_Name{nickname}, ", the file ", sentence.Hash{hash[:]}, ", has the grant ", grant, " for principal ", principal, ", from its next start", lasting[1]))
			}
			expect(t, render(t, file, strings.concatenate({"Nickname_Moved", lasting[0]}, context.temp_allocator), {{"hash", hash}, {"nickname", nickname}}), line_of_before("root: the nickname ", sentence.Module_Name{nickname}, " names the file ", sentence.Hash{hash[:]}, ", with its grants and its store", lasting[1]))
			for persistence in PERSISTENCES {
				expect(t, render(t, file, strings.concatenate({"Table_Persistence_Set", lasting[0]}, context.temp_allocator), {{"principal", principal}, {"persistence", persistence}}), line_of_before("root: each row of the disk grant table of principal ", principal, " with no exception will ", persistence, lasting[1]))
				expect(t, render(t, file, strings.concatenate({"Row_Persistence_Set", lasting[0]}, context.temp_allocator), {{"principal", principal}, {"nickname", nickname}, {"persistence", persistence}}), line_of_before("root: the row of the nickname ", sentence.Module_Name{nickname}, " in the disk grant table of principal ", principal, " has the setting: ", persistence, lasting[1]))
			}
		}
		for lasting in key_lastings {
			expect(t, render(t, file, lasting[0], {{"principal", principal}, {"client_key", key_head}}), line_of_before("root: principal ", principal, " allowed the client key ", key_head, " of remote: each call of that client acts for it", lasting[1]))
		}
		expect(t, render(t, file, "Client_Key_Contested", {{"principal", principal}, {"other_principal", other}, {"connections_ended", principal}, {"client_key", key_head}}), line_of_before("root: the client key ", key_head, " of remote is contested: principal ", principal, " allowed it since the machine started, and the disk grant table of principal ", other, " holds it; it acts for neither until one of them revokes it; connections to services ended: ", principal))
	}
}

// The lines of the entropy at the start and of the random seed write the
// lines of before: the counts 0, 1 and max(u64); a size of max(i64); each
// strength of the seed; present and absent.
@(test)
the_seed_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		size := min(count, u64(max(i64)))
		expect(t, render(t, file, "First_Fresh_Bytes", {{"device_bytes", size}, {"stream_bytes", size}, {"receiving_processes", count}, {"period_seconds", count}}), line_of_before("root: the first fresh bytes: ", size, " bytes of the entropy device mixed into the random generator of the system, then ", size, " bytes of its stream in the fresh bytes page of each of ", count, " processes; a read every ", count, " seconds after this one, with no line"))
		for strength in op.seed_strength_names {
			for presence in PRESENCES {
				written := render(t, file, "Random_Seed_Made", {{"rdseed_good", count}, {"rdseed_refused", count}, {"rdrand_good", count}, {"rdrand_refused", count}, {"jitter_samples", count}, {"jitter_distinct", count}, {"strength", strength}, {"rdseed_presence", presence}, {"rdrand_presence", presence}})
				expect(t, written, line_of_before("root: the random seed of the system, strength ", strength, ": rdseed ", presence, ", ", count, " good values, ", count, " refused; rdrand ", presence, ", ", count, " good, ", count, " refused; the cycle counter, ", count, " samples, ", count, " distinct low bytes"))
			}
		}
	}
}

// The facts of a load that the loader refused: the line of the start, then
// the fact of the stage of the load error, in the form of its fields. Each
// stage, with names of 31 bytes, and with no import (an empty name and a
// zero hash, whose head is eight zeros); each member of the enum of a stage
// and a word that names no member.
@(test)
the_load_error_facts_of_the_root_service_write_the_fields_of_each_stage :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	expect(t, render(t, file, "Compositor_Load_Refused", {}), "root: cannot load the compositor: the loader refused it")
	expect(t, render(t, file, "Terminal_Load_Refused", {}), "root: cannot load the terminal: the loader refused it")
	expect(t, render(t, file, "Start_Refused_By_Loader", {{"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": the loader refused it"))
	expect(t, render(t, file, "Disk_Load_Refused_By_Loader", {{"refused_process", process}}), line_of_before("root: refused ", sentence.Module_Name{process}, " from the disk: the loader refused its file"))

	name := strings.repeat("m", module.NAME_SIZE - 1, context.temp_allocator)
	imported := strings.repeat("i", module.NAME_SIZE - 1, context.temp_allocator)
	export := strings.repeat("e", module.NAME_SIZE - 1, context.temp_allocator)
	hash, zero: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0x70 + index)
	}
	head := line_of_before(sentence.Hash{hash[:4]}, "…")
	zero_head := line_of_before(sentence.Hash{zero[:4]}, "…")
	imports := [2]string{imported, ""}
	for import_name in imports {
		import_hash := import_name == "" ? zero : hash
		import_head := import_name == "" ? zero_head : head
		expect(t, render(t, file, "Load_Find_Failed", {{"module_hash", hash}, {"imported_hash", import_hash}, {"module_name", name}, {"imported_name", import_name}}), line_of_before("root: the load source has no file of the import ", import_name, " (", import_head, ") of ", name, " (", head, ")"))
		expect(t, render(t, file, "Load_Cycle_Failed", {{"module_name", name}, {"imported_name", import_name}, {"replacement_name", export}}), line_of_before("root: ", name, " imports itself through ", import_name, ", by the replacement ", export))
	}
	words_of :: proc(which: value_kinds.Contract_Enum, word: u64) -> string {
		if name, named := module.contract_enum_member_name(which, word); named {
			return name
		}
		return line_of_before(word)
	}
	for word in 0 ..= u64(max(module.Error)) + 1 {
		expect(t, render(t, file, "Load_Read_Failed", {{"file_error", word}, {"subject_hash", hash}, {"subject_name", name}}), line_of_before("root: the file of ", name, " (", head, ") is not a valid module, or not the file of its hash: ", words_of(.Module_Error, word)))
	}
	for word in 0 ..= u64(max(module.Difference)) + 1 {
		expect(t, render(t, file, "Load_Check_Failed", {{"difference", word}, {"parameter", u64(max(u32))}, {"module_name", name}, {"imported_name", imported}, {"export", export}}), line_of_before("root: the replacement of the import ", imported, " of ", name, " differs in its export ", export, ": ", words_of(.Load_Difference, word), ", parameter ", u64(max(u32))))
	}
	import_slots := [3]u64{0, 1, u64(max(u32))}
	for import_slot in import_slots {
		expect(t, render(t, file, "Load_Bind_Failed", {{"import_slot", import_slot}, {"module_name", name}, {"imported_name", imported}, {"export", export}}), line_of_before("root: the import slot ", import_slot, " of ", name, " names no import or no export, or is not in writable data: the import ", imported, ", the export ", export))
	}
	statuses := [3]u64{u64(min(op.Status)), u64(max(op.Status)), u64(max(op.Status)) + 1}
	for word in statuses {
		expect(t, render(t, file, "Load_Map_Failed", {{"status", word}, {"module_hash", hash}, {"module_name", name}}), line_of_before("root: the map of the memory of ", name, " (", head, ") failed: status ", words_of(.Status, word)))
		expect(t, render(t, file, "Load_Unmap_Failed", {{"status", word}, {"module_hash", hash}, {"module_name", name}}), line_of_before("root: the removal of ", name, " (", head, ") failed: status ", words_of(.Status, word)))
	}
	expect(t, render(t, file, "Load_Room_Failed", {{"module_hash", hash}, {"module_name", name}}), line_of_before("root: no room for ", name, " (", head, "): the module space, the imports of one module or the table of the loader is full"))

	// The procedures of the contract fill each shape from a load error of
	// its stage: the fact of the stage holds the names that the error names.
	error: module.Load_Error
	module.name_set(&error.module.name, name)
	error.module.hash = hash
	module.name_set(&error.imported.name, imported)
	error.imported.hash = hash
	module.name_set(&error.export, export)
	find := module.load_find_fact_fields(&error)
	testing.expect(t, string(find.module_name[:len(name)]) == name && find.module_name[len(name)] == 0 && string(find.imported_name[:len(imported)]) == imported)
	bind := module.load_bind_fact_fields(&error)
	testing.expect(t, string(bind.export[:len(export)]) == export && bind.export[len(export)] == 0)
}

// The facts of the tables of this service, of the wait of its loop and of
// the bridge to the delegated wiring service write the lines of before:
// the counts 0, 1 and max(u64), a name of 31 bytes. The status of a start
// of the wiring service stays its number, as the line wrote it.
@(test)
the_table_wait_and_wiring_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	capacity := u64(op.MAPPING_REPORT_CAPACITY)
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		other := max(u64) - count
		expect(t, render(t, file, "Own_Tables_Measured", {{"handles", count}, {"prepared_parts", other}, {"mappings", count}, {"capacity", capacity}, {"stopped_process", process}}), line_of_before("root: the tables of this service after the stop of ", sentence.Module_Name{process}, ": ", count, " handles, ", other, " of them prepared parts, and ", count, " mappings, of ", capacity, " each"))
		expect(t, render(t, file, "Own_Tables_Full", {{"mappings", count}, {"handles", other}, {"prepared_parts", count}, {"capacity", capacity}, {"started_process", process}}), line_of_before("root: the start of ", sentence.Module_Name{process}, " found a table full: this service holds ", count, " mappings and ", other, " handles, ", count, " of them prepared parts, of ", capacity, " each"))
		expect(t, render(t, file, "Root_Wait_Full", {{"word_capacity", count}}), line_of_before("root: the wait of the loop holds more words than ", count, ": the kernel gave no wait room for them, so each wait ends at its deadline"))
		expect(t, render(t, file, "Wiring_Service_Started", {{"starts", count}, {"start_limit", other}}), line_of_before("root: started delegated wiring service (start ", count, " of ", other, ")"))
		expect(t, render(t, file, "Disk_Processes_Service_Started", {{"starts", count}, {"start_limit", other}}), line_of_before("root: started the disk processes service (start ", count, " of ", other, ")"))
		expect(t, render(t, file, "Wirings_Revoked", {{"ended", count}, {"target", process}}), line_of_before("root: revoked the grant wirings of ", sentence.Module_Name{process}, ", wirings ended: ", count))
	}
	for status in op.Status {
		expect(t, render(t, file, "Wiring_Service_Start_Failed", {{"status_number", u64(status)}}), line_of_before("root: cannot start wiring service: status ", status))
	}
	expect(t, render(t, file, "Own_Tables_Full_Unreported", {{"started_process", process}}), line_of_before("root: the start of ", sentence.Module_Name{process}, " found a table full; the kernel gives no report of the tables of this service"))
	expect(t, render(t, file, "Wiring_Service_Stopped", {}), "root: delegated wiring service stopped")
	expect(t, render(t, file, "Disk_Processes_Service_Stopped", {}), "root: the disk processes service stopped")
	expect(t, render(t, file, "Disk_Processes_Service_Faulted", {}), "root: the disk processes service broke its contract: it is stopped, and the next load starts it again")
	for bound in ([?]u64{0, 1, 2000}) {
		expect(t, render(t, file, "Disk_Processes_Cancel_Late", {{"bound", bound}}), line_of_before("root: the disk processes service did not give back the memory of an ended load in ", bound, " ms: it is stopped"))
	}
	// The measure record finds the line by the start of its template.
	measured := render(t, file, "Own_Tables_Measured", {{"handles", u64(1)}, {"prepared_parts", u64(0)}, {"mappings", u64(1)}, {"capacity", capacity}, {"stopped_process", "output_wiring"}})
	testing.expectf(t, strings.has_prefix(measured, "root: the tables of this service after the stop of output_wiring: "), "the measure record does not find %q", measured)
}

// The facts of the bridges to the delegated devices and principals
// services write their sentences: the counts and the words 0, 1 and
// max(u64), and the facts with no field.
@(test)
the_devices_and_principals_bridge_facts_of_the_root_service_write_their_lines :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		other := max(u64) - count
		expect(t, render(t, file, "Devices_Service_Started", {{"starts", count}, {"start_limit", other}}), line_of_before("root: started the delegated devices service (start ", count, " of ", other, ")"))
		expect(t, render(t, file, "Devices_Service_Silent", {{"starts", count}}), line_of_before("root: the devices service gave no answer for a device of the bus (start ", count, "): it is stopped"))
		expect(t, render(t, file, "Bus_Classified", {{"classified", count}, {"looked_up", other}}), line_of_before("root: the devices service classified ", count, " of the ", other, " devices of the bus"))
		expect(t, render(t, file, "Devices_Service_Absent", {{"start_limit", count}}), line_of_before("root: the devices service did not classify the bus in ", count, " starts: no device service starts, so the machine has no data disk, no network device, no sound device and no entropy device"))
		expect(t, render(t, file, "Classified_Devices_Full", {{"capacity", count}}), line_of_before("root: the bus holds more than ", count, " devices of a known class: the devices past them get no device service"))
		expect(t, render(t, file, "Device_Unclassified", {{"device", count}, {"bus", other}, {"service", process}}), line_of_before("root: no devices service classified the bus: ", sentence.Module_Name{process}, " does not start for the device ", count, " of the bus ", other))
		expect(t, render(t, file, "Devices_Answer_Refused", {{"status_word", count}}), line_of_before("root: the devices service answered with the status word ", count, ", which names no status"))
		expect(t, render(t, file, "Devices_Notice_Refused", {{"status_word", count}, {"first_value", other}, {"second_value", count}}), line_of_before("root: the devices service refused a notice of a binding: status word ", count, ", values ", other, " and ", count))
		expect(t, render(t, file, "Principals_Service_Started", {{"starts", count}, {"start_limit", other}}), line_of_before("root: started the delegated principals service (start ", count, " of ", other, ")"))
		expect(t, render(t, file, "Principals_Service_Absent", {{"start_limit", count}}), line_of_before("root: the principals service did not start in ", count, " starts: the root service keeps the principals, their disk grant tables and the client keys with no mirror"))
		expect(t, render(t, file, "Principals_Answer_Refused", {{"status_word", count}, {"tag", other}}), line_of_before("root: the principals service answered with the status word ", count, " and the tag ", other, ", which name no status or no command in flight"))
		expect(t, render(t, file, "Principals_Command_Refused", {{"command_word", count}, {"status_word", other}, {"first_value", count}, {"second_value", other}}), line_of_before("root: the principals service refused the command ", count, ": status word ", other, ", values ", count, " and ", other))
		expect(t, render(t, file, "Principals_Rows_Unsent", {{"principal", count}}), line_of_before("root: the disk grant table of principal ", count, " does not pass the border of the principals service: its rows are not sent"))
		expect(t, render(t, file, "Plan_Roles_Replaced", {{"generation", count}, {"serial", other}, {"overrides", count}, {"rollback", other}}), line_of_before("root: the roles of the plan of generation ", count, " are in force: ", count, " overrides, serial ", other, ", rollback ", other))
		expect(t, render(t, file, "Plan_At_Start_Applied", {{"generation", count}, {"serial", other}, {"overrides", count}}), line_of_before("root: the roles of generation ", count, " of the plan of principal 0 hold from the start: ", count, " overrides, serial ", other))
		expect(t, render(t, file, "Plan_Roles_Refused", {{"refusal_code", count}, {"override_index", other}, {"generation", count}, {"serial", other}}), line_of_before("root: refused the roles of the plan of generation ", count, ": refusal ", count, " at the override ", other, "; the serial ", other, " stays in force"))
	}
	expect(t, render(t, file, "Devices_Service_Stopped", {}), "root: the delegated devices service stopped")
	expect(t, render(t, file, "Principals_Service_Stopped", {}), "root: the delegated principals service stopped")
	expect(t, render(t, file, "Principals_Service_Silent", {}), "root: the principals service gave no answer to the call of a disk grant table in time: it is stopped, and it starts again with no key until the next unlock")
}

// The facts of the script font set (src/md/features/script_fonts.md): each
// line at the edges of its fields, the hashes whole, the size of a set of
// 0 bytes and of the largest size, each status by the name of its member
// or by its number past the members, and each sentence of a problem of the
// font outlines.
@(test)
the_script_font_facts_of_the_root_service_write_their_lines :: proc(t: ^testing.T) {
	file, ok := root_service_facts_file(t)
	if !ok {
		return
	}
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0x3C + index)
	}
	none := "Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph"
	expect(t, render(t, file, "Script_Fonts_Unnamed", {}), line_of_before("root: no plan and no resource of the boot image names a script font set: ", none))
	expect(t, render(t, file, "Script_Fonts_Without_Data_Disk", {}), line_of_before("root: the machine has no data disk, so it holds no script font set: ", none))
	expect(t, render(t, file, "Script_Fonts_Named_By_Image", {{"hash", hash}}), line_of_before("root: the boot image names the script font set ", sentence.Hash{hash[:]}))
	expect(t, render(t, file, "Script_Fonts_Named_By_Plan", {{"hash", hash}}), line_of_before("root: the plan of principal 0 names the script font set ", sentence.Hash{hash[:]}))
	expect(t, render(t, file, "Script_Fonts_Next_Start", {{"hash", hash}}), line_of_before("root: the plan of principal 0 names the script font set ", sentence.Hash{hash[:]}, ": it holds at the next start of the machine"))
	expect(t, render(t, file, "Script_Fonts_Back_To_Image", {{"hash", hash}}), line_of_before("root: the plan of principal 0 names no script font set: the set ", sentence.Hash{hash[:]}, " of the boot image is the set of this start again"))
	expect(t, render(t, file, "Script_Fonts_Back_To_Image_Next_Start", {{"hash", hash}}), line_of_before("root: the plan of principal 0 names no script font set: the set ", sentence.Hash{hash[:]}, " of the boot image holds at the next start of the machine"))
	expect(t, render(t, file, "Script_Fonts_Reading", {{"hash", hash}}), line_of_before("root: reads the script font set ", sentence.Hash{hash[:]}, " from the store script_fonts of the machine"))
	expect(t, render(t, file, "Script_Fonts_Not_On_Disk", {{"hash", hash}}), line_of_before("root: the data disk holds no script font set ", sentence.Hash{hash[:]}, ": ", none))
	for size in ([?]u64{0, 1, 35_772_620, u64(max(i64))}) {
		for count in ([?]u64{0, 5, max(u64)}) {
			expect(t, render(t, file, "Script_Fonts_Mapped", {{"hash", hash}, {"set_size", size}, {"fonts", count}}), line_of_before("root: the script font set ", sentence.Hash{hash[:]}, " (", sentence.Size{size, .Bytes}, ", ", count, " fonts) is checked: each process that starts from now maps it, read-only"))
		}
		expect(t, render(t, file, "Script_Fonts_Name_Refused", {{"name_bytes", size}}), line_of_before("root: the resource script_fonts_name holds ", sentence.Size{size, .Bytes}, ", not one hash of 32 bytes: it names no script font set"))
	}
	for problem in font_outlines.problem_sentences {
		for value in ([?]u64{0, max(u64)}) {
			expect(t, render(t, file, "Script_Fonts_Refused_Form", {{"problem_value", value}, {"problem", problem}}), line_of_before("root: the script font set is refused: ", problem, ", value ", value, ": ", none, " until the next start"))
		}
	}
	for word in ([3]u64{u64(min(call_outcome.Call_Outcome)), u64(max(call_outcome.Call_Outcome)), u64(max(call_outcome.Call_Outcome)) + 1}) {
		outcome_text := line_of_before(word)
		if name, named := module.contract_enum_member_name(.Call_Outcome, word); named {
			outcome_text = name
		}
		expect(t, render(t, file, "Script_Fonts_Not_Read", {{"outcome", word}}), line_of_before("root: the script font set was not read: ", outcome_text, ": ", none, " until the next start"))
	}
	for size in ([?]u64{0, max(u64)}) {
		for limit in ([?]u64{0, max(u64)}) {
			expect(t, render(t, file, "Script_Fonts_Refused_Too_Large", {{"object_bytes", size}, {"set_bytes_limit", limit}}), line_of_before("root: refused the script font set: the object has ", size, " bytes, and a script font set has at most ", limit))
		}
	}
}
