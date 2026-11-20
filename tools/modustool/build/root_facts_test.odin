package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the root service against the lines that they replaced
// (src/md/features/log_facts.md, "The facts of the root service"). The test
// reads the fact types with the extraction of the tool on the sources of
// root, and makes a module file of their table: a host test does not
// depend on a build, or on the age of a module file that a build left.
// Each sentence is compared with the parts of the old line written by
// sentence.format, at the edges of each field. The helpers are in
// fact_test_helpers_test.odin.

// root_facts_file gives a module file with the table Facts of the root
// service, made from the extraction of its sources.
@(private = "file")
root_facts_file :: proc(t: ^testing.T) -> (file: []u8, ok: bool) {
	return facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "root")
}

// root_fact_render gives the sentence of the fact type root.<type_name>
// with the values of its fields.
@(private = "file")
root_fact_render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
	return fact_test_render(t, file, "root", type_name, values)
}

// root_old_line gives the line that the root service wrote before the
// fact, with the parts of its call of system.log.
root_old_line :: line_of_before

// Each fact type of the root service writes the line of before, byte for
// byte, at the edges of its fields: a process name of 31 bytes, the
// longest that its field holds with its zero byte; a principal name of 23
// bytes; the principal max(u64); each stop cause; each grant name; a store
// name of 31 bytes; a hash of 32 different bytes.
@(test)
the_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_facts_file(t)
	if !ok {
		return
	}
	expect_line :: proc(t: ^testing.T, written, old: string, loc := #caller_location) {
		testing.expectf(t, written == old, "the fact writes %q, the line of before was %q", written, old, loc = loc)
	}
	process := strings.repeat("p", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	service := strings.repeat("s", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	principal_name := strings.repeat("n", 23, context.temp_allocator)
	store := strings.repeat("d", 31, context.temp_allocator)
	key_head := "0123456789abcdef"
	// Typed names: a union field takes a typed value.
	unlock_name := "unlock"
	remote_name := "remote"
	principal := max(u64)
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(0xE0 + index)
	}

	// The stops: each cause, with each outcome for a stop of itself.
	for cause in op.Stop_Cause {
		if cause == .Itself {
			for outcome in op.Stop_Outcome {
				written := root_fact_render(t, file, "Process_Stopped", {{"stopped_process", process}, {"cause", u64(cause)}, {"outcome", u64(outcome)}})
				expect_line(t, written, root_old_line("root: ", sentence.Module_Name{process}, " stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome]))
				unlock := root_fact_render(t, file, "Unlock_Without_Window_Stopped", {{"stopped_process", unlock_name}, {"cause", u64(cause)}, {"outcome", u64(outcome)}})
				expect_line(t, unlock, root_old_line("root: unlock read the machine key with no window and stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome]))
			}
			continue
		}
		written := root_fact_render(t, file, "Process_Stopped_Without_Outcome", {{"stopped_process", process}, {"cause", u64(cause)}})
		expect_line(t, written, root_old_line("root: ", sentence.Module_Name{process}, " stopped: ", op.STOP_CAUSE_TEXTS[cause]))
		unlock := root_fact_render(t, file, "Unlock_Without_Window_Stopped_Without_Outcome", {{"stopped_process", unlock_name}, {"cause", u64(cause)}})
		expect_line(t, unlock, root_old_line("root: unlock read the machine key with no window and stopped: ", op.STOP_CAUSE_TEXTS[cause]))
	}
	// A cause word that names no member: the render writes its number,
	// never the words of another member.
	past := u64(max(op.Stop_Cause)) + 1
	past_written := root_fact_render(t, file, "Process_Stopped_Without_Outcome", {{"stopped_process", process}, {"cause", past}})
	expect_line(t, past_written, root_old_line("root: ", sentence.Module_Name{process}, " stopped: ", past))

	// The starts.
	expect_line(t, root_fact_render(t, file, "Process_Started", {{"started_process", process}}), root_old_line("root: started ", sentence.Module_Name{process}))
	expect_line(t, root_fact_render(t, file, "Process_Started_With_Terminal", {{"started_process", process}}), root_old_line("root: started ", sentence.Module_Name{process}, ", with a terminal"))
	expect_line(t, root_fact_render(t, file, "Process_Started_In_Session", {{"started_process", process}, {"principal", principal}, {"principal_name", principal_name}}), root_old_line("root: started ", sentence.Module_Name{process}, ", in the session of principal ", principal, " \"", principal_name, "\""))
	expect_line(t, root_fact_render(t, file, "Process_Started_With_Terminal_In_Session", {{"started_process", process}, {"principal", principal}, {"principal_name", principal_name}}), root_old_line("root: started ", sentence.Module_Name{process}, ", with a terminal", ", in the session of principal ", principal, " \"", principal_name, "\""))
	pages := u64(max(i64))
	expect_line(t, root_fact_render(t, file, "Process_Started_With_Budget", {{"started_process", process}, {"pages", pages}}), root_old_line("root: started ", sentence.Module_Name{process}, " with ", sentence.Size{pages, .Pages}))
	expect_line(t, root_fact_render(t, file, "Chosen_Start_Policy_Started", {{"started_process", principal_name}, {"hash", hash}}), root_old_line("root: started the chosen start policy \"", principal_name, "\" from the disk, hash ", sentence.Hash{hash[:]}, ", with the grant Start_Policy only"))
	expect_line(t, root_fact_render(t, file, "Device_Service_Started", {{"service", process}, {"device", max(u64)}}), root_old_line("root: started ", sentence.Module_Name{process}, " for the device at the place ", max(u64), " of the bus"))
	expect_line(t, root_fact_render(t, file, "Device_Service_Started_Behind_Bridge", {{"service", process}, {"device", u64(0)}, {"bus", max(u64)}}), root_old_line("root: started ", sentence.Module_Name{process}, " for the device at the place ", u64(0), " of the bus ", max(u64), ", behind a bridge"))
	expect_line(t, root_fact_render(t, file, "Disk_Process_Started", {{"started_process", process}, {"hash", hash}}), root_old_line("root: started ", sentence.Module_Name{process}, " from the disk, hash ", sentence.Hash{hash[:]}, ", with no grant"))
	expect_line(t, root_fact_render(t, file, "Disk_Process_Started_With_Store", {{"started_process", process}, {"hash", hash}, {"store", store}}), root_old_line("root: started ", sentence.Module_Name{process}, " from the disk, hash ", sentence.Hash{hash[:]}, ", with the grant store: the store ", store))
	expect_line(t, root_fact_render(t, file, "Disk_Process_Started_In_Session", {{"started_process", process}, {"hash", hash}, {"principal", principal}, {"principal_name", principal_name}}), root_old_line("root: started ", sentence.Module_Name{process}, " from the disk, hash ", sentence.Hash{hash[:]}, ", with no grant", ", in the session of principal ", principal, " \"", principal_name, "\""))
	expect_line(t, root_fact_render(t, file, "Disk_Process_Started_With_Store_In_Session", {{"started_process", process}, {"hash", hash}, {"store", store}, {"principal", principal}, {"principal_name", principal_name}}), root_old_line("root: started ", sentence.Module_Name{process}, " from the disk, hash ", sentence.Hash{hash[:]}, ", with the grant store: the store ", store, ", in the session of principal ", principal, " \"", principal_name, "\""))

	// The connections.
	expect_line(t, root_fact_render(t, file, "Connected", {{"caller", process}, {"service", service}, {"principal", principal}}), root_old_line("root: connected ", sentence.Module_Name{process}, " to the service ", sentence.Module_Name{service}, ", for principal ", principal))
	expect_line(t, root_fact_render(t, file, "Connected_Acting", {{"caller", process}, {"service", service}, {"principal", principal}}), root_old_line("root: connected ", sentence.Module_Name{process}, " to the service ", sentence.Module_Name{service}, ", acting for principal ", principal))
	expect_line(t, root_fact_render(t, file, "Connected_With_Client_Key", {{"caller", process}, {"service", service}, {"principal", principal}, {"client_key", key_head}}), root_old_line("root: connected ", sentence.Module_Name{process}, " to the service ", sentence.Module_Name{service}, ", for principal ", principal, ", for the client key ", key_head))
	expect_line(t, root_fact_render(t, file, "Connected_Acting_With_Client_Key", {{"caller", process}, {"service", service}, {"principal", principal}, {"client_key", key_head}}), root_old_line("root: connected ", sentence.Module_Name{process}, " to the service ", sentence.Module_Name{service}, ", acting for principal ", principal, ", for the client key ", key_head))
	limit := u64(max(i64))
	expect_line(t, root_fact_render(t, file, "Connected_History", {{"caller", process}, {"service", service}, {"limit", limit}, {"principal", principal}}), root_old_line("root: connected ", sentence.Module_Name{process}, " to the store of its line history in the service ", sentence.Module_Name{service}, ", ", sentence.Size{limit, .Blocks}, ", for principal ", principal))
	expect_line(t, root_fact_render(t, file, "Disconnected", {{"caller", process}, {"service", service}}), root_old_line("root: disconnected ", sentence.Module_Name{process}, " from the service ", sentence.Module_Name{service}))

	// The grants: each grant name, with the count of its kind.
	connection_grants := [?]string{"store", "acts_for_principal", "history"}
	for grant in connection_grants {
		expect_line(t, root_fact_render(t, file, "Grant_Revoked_Connections", {{"holder", process}, {"grant", grant}, {"connections", max(u64)}}), root_old_line("root: revoked the grant ", grant, " of ", sentence.Module_Name{process}, ", connections changed: ", max(u64)))
	}
	expect_line(t, root_fact_render(t, file, "Grant_Revoked_Endpoints", {{"holder", process}, {"endpoints", u64(0)}}), root_old_line("root: revoked the grant network of ", sentence.Module_Name{process}, ", endpoints changed: ", u64(0)))
	holding_grants := [?]string{"log", "machine", "image", "log_records", "debug", "palette"}
	for grant in holding_grants {
		expect_line(t, root_fact_render(t, file, "Grant_Revoked_Holdings", {{"holder", process}, {"grant", grant}, {"holdings", u64(1)}}), root_old_line("root: revoked the grant ", grant, " of ", sentence.Module_Name{process}, ", holdings ended: ", u64(1)))
	}
	expect_line(t, root_fact_render(t, file, "Debug_Right_Given", {{"debugger", process}, {"target", service}, {"caller", remote_name}, {"principal", principal}}), root_old_line("root: gave ", sentence.Module_Name{process}, " the right to debug ", sentence.Module_Name{service}, " for ", sentence.Module_Name{remote_name}, ", for principal ", principal))
}

// Each fact type of the entropy lines of the root service writes the line
// of before, byte for byte: the counts 0, 1 and max(u64), and the deadline
// of 60 seconds that the reads have.
@(test)
the_entropy_facts_of_the_root_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := root_facts_file(t)
	if !ok {
		return
	}
	counts := [3]u64{0, 1, max(u64)}
	for count in counts {
		facts_expect_line(t, root_fact_render(t, file, "Entropy_Answer_Out_Of_Order", {{"answered_read", count}, {"tagged_read", max(u64) - count}}), line_of_before("root: the entropy service answered the read ", count, " with the tag of the read ", max(u64) - count, ": the answer adds nothing"))
		facts_expect_line(t, root_fact_render(t, file, "Entropy_Reads_Late", {{"deadline_seconds", u64(60)}, {"late_reads", count}}), line_of_before("root: the entropy device did not answer a read in ", u64(60), " seconds: ", count, " reads count as refused, and the entropy service stops: no more bytes of the device"))
		facts_expect_line(t, root_fact_render(t, file, "Entropy_Reads_Late", {{"deadline_seconds", count}, {"late_reads", u64(2)}}), line_of_before("root: the entropy device did not answer a read in ", count, " seconds: ", u64(2), " reads count as refused, and the entropy service stops: no more bytes of the device"))
		facts_expect_line(t, root_fact_render(t, file, "Fresh_Bytes_Reads_Refused_In_A_Row", {{"refused_reads", count}}), line_of_before("root: the entropy device gave ", count, " refused reads in a row: no more fresh bytes for the running processes"))
		facts_expect_line(t, root_fact_render(t, file, "Fresh_Bytes_Read_Added_Nothing", {{"refused_reads", count}}), line_of_before("root: a read of the entropy device for the fresh bytes added nothing: the pages keep their bytes; refused reads in a row: ", count))
		facts_expect_line(t, root_fact_render(t, file, "Entropy_Service_Stopped_Early", {{"answered_reads", count}, {"start_reads", u64(2)}}), line_of_before("root: the entropy service stopped after ", count, " of ", u64(2), " reads: the random seed of the system has the bytes of those reads only"))
	}
}
