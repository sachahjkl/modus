package build

import "modus:contract/font_outlines"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/replacement_list"
import "modus:contract/start_grant"
import "modus:contract/value_kinds"
import "modus:private/root/replacement_signature"
import "modus:support/sentence"
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
LARGEST_OF := [?]string{"a process", "a disk process"}
@(private = "file")
PAYING_BUDGETS := [?]string{"this service", "the disk processes"}
@(private = "file")
MAPPINGS := [?]string{"the date page", "the debug image", "the disk process page", "the fresh bytes page", "the settings page and the font outlines", "the file of the storage service", "the file of the service", "the machine parts page", "the start list"}
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
FAILURE_CAUSES := [?]string{"the rescue start policy is absent from the boot image", "the rescue start policy did not start", "the rescue start policy stopped before the machine was usable", "the rescue start policy sent no Machine_Usable within the hang bound"}

// The longest text of a list.
@(private = "file")
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
	for name in ([?]string{"started_process", "stopped_process", "refused_process", "loaded_process", "window_process", "service", "caller", "holder", "debugger", "target", "importer", "receiver", "provider", "nickname", "stop_report_name", "replaced", "replacement"}) {
		most[name] = name_most
	}
	// A principal name has at most principals.NAME_LIMIT bytes, a store
	// name 31, a file of the store disk_process.NAME_LIMIT, and a resource
	// the name of an entry of the boot image.
	most["principal_name"] = 23
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
	most["largest_of"] = longest(LARGEST_OF[:])
	most["paying_budget"] = longest(PAYING_BUDGETS[:])
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
	return most
}

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
			for who in LARGEST_OF {
				expect(t, render(t, file, "Budget_Part_Limited", {{"asked", count}, {"largest", max(u64) - count}, {"granted", count}, {"started_process", process}, {"budget_part", part}, {"largest_of", who}}), line_of_before("root: ", sentence.Module_Name{process}, " asks for ", count, " ", part, ", and ", who, " gets at most ", max(u64) - count, ": it starts with ", count))
			}
			for holder in PAYING_BUDGETS {
				expect(t, render(t, file, "Start_Refused_Budget_Part", {{"needed", count}, {"held", max(u64) - count}, {"refused_process", process}, {"budget_part", part}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": it gets ", count, " ", part, ", and the budget of ", holder, " holds ", max(u64) - count))
			}
		}
		for holder in PAYING_BUDGETS {
			expect(t, render(t, file, "Start_Refused_Log_Records", {{"log_records", count}, {"held_log_records", max(u64) - count}, {"refused_process", process}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": it gets ", count, " log records of each second, and the budget of ", holder, " holds ", max(u64) - count))
			expect(t, render(t, file, "Start_Refused_Processor_Time", {{"processor", count}, {"processor_limit", max(u64) - count}, {"refused_process", process}, {"paying_budget", holder}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": it gets ", count, " microseconds of processor time in each second, and the limit of the budget of ", holder, " is ", max(u64) - count))
		}
		expect(t, render(t, file, "Disk_Processes_Budget_Made", {{"pages", largest_size}, {"processes", count}, {"threads", count}}), line_of_before("root: the disk processes share one budget of ", sentence.Size{largest_size, .Pages}, ", ", count, " processes and ", count, " threads"))
		expect(t, render(t, file, "Start_Refused_Budget_Too_Small", {{"pages", min(count, largest_size)}, {"processes", count}, {"threads", count}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": its budget of ", sentence.Size{min(count, largest_size), .Pages}, ", ", count, " processes and ", count, " threads is too small for its load: the module asks for too little"))
		// A slot is the word of the starter: a negative slot writes its
		// bits, as u64(slot) did.
		expect(t, render(t, file, "Start_Refused_Context_Handle", {{"slot", count}, {"refused_process", process}}), line_of_before("root: cannot start ", sentence.Module_Name{process}, ": two grants of its role take the handle ", count, " of its context, and a handle would be lost"))
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
		expect(t, render(t, file, "Resource_Given", {{"resource_size", min(count, largest_size)}, {"check_time", min(count, largest_size)}, {"resource", resource}, {"receiver", process}}), line_of_before("root: the resource ", resource, " (", sentence.Size{min(count, largest_size), .Bytes}, ", its hash checked in ", sentence.Duration{min(count, largest_size), .Microseconds}, ") is given to ", sentence.Module_Name{process}, ", read-only"))
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
	// The old line wrote the name as a plain text: the same bytes.
	expect(t, render(t, file, "Window_Start_Not_Measured", {{"window_process", process}}), line_of_before("root: the control ring of the compositor is full: the start of the window of ", process, " is not measured"))
	expect(t, render(t, file, "Debugging_Ended", {{"debugger", process}, {"target", other}, {"caller", third}}), line_of_before("root: ", sentence.Module_Name{process}, " ended the debugging of ", sentence.Module_Name{other}, " for ", sentence.Module_Name{third}))
	for grant in start_grant.GRANT_NAMES {
		expect(t, render(t, file, "Debug_Access_Refused", {{"caller", process}, {"target", other}, {"grant", grant}}), line_of_before("root: refused ", sentence.Module_Name{process}, " the debug access to ", sentence.Module_Name{other}, ": the grant ", grant, " of the process refuses it"))
	}
	expect(t, render(t, file, "Debugging_Ended_After_Revocation", {{"target", process}, {"caller", other}}), line_of_before("root: ended the debugging of ", sentence.Module_Name{process}, " for ", sentence.Module_Name{other}, ": the rule no longer gives the debug access, after a revocation"))
	expect(t, render(t, file, "Acts_For_Principal_Revocation_Refused", {{"holder", process}, {"service", other}}), line_of_before("root: refused the revocation of acts_for_principal of ", sentence.Module_Name{process}, ": the service ", sentence.Module_Name{other}, " has no room for the new grants; nothing changed"))
	expect(t, render(t, file, "Palette_Provider_Set", {{"provider", process}}), line_of_before("root: ", sentence.Module_Name{process}, " is the palette provider"))
	expect(t, render(t, file, "Resource_Hash_Wrong", {{"resource", resource}}), line_of_before("root: the resource ", resource, " does not have the hash of its entry: not given"))
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
			expect(t, render(t, file, "Client_Key_Allowed_For_Display", {{"principal", principal}, {"client_key", key_head}, {"uses", uses}}), line_of_before("root: principal ", principal, " allowed the client key ", key_head, " for the remote display: ", uses, "; the uses of the remote display last until the machine stops"))
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
		expect(t, render(t, file, "Start_Policy_Processes_Late", {{"left_processes", count}, {"bound", time}}), line_of_before("root: ", count, " processes of the failed start policy did not stop within the hang bound of ", time, " ms: the rescue start policy starts beside them"))
		expect(t, render(t, file, "Start_Policy_Choice_Refused_Principal", {{"principal", count}}), line_of_before("root: refused a choice of a start policy: the caller acts for principal ", count, ", and only principal 0 chooses the start policy of the machine"))
		expect(t, render(t, file, "Start_Request_Refused", {{"start_request", count}, {"start_request_source", other}}), line_of_before("root: the boot record names the start request ", count, " with the source ", other, ", which the border refuses: the rescue start policy starts"))
		expect(t, render(t, file, "Start_Policy_Restart_Refused", {{"restart_limit", count}, {"counted_names", other}, {"refused_process", process}}), line_of_before("root: refused a start of ", sentence.Module_Name{process}, " by the start policy from the disk: past its ", count, " restarts, or past the ", other, " names whose starts the root service counts, it stays stopped"))
	}
}
