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
// sentence.format, at the edges of each field.

// A value of one field of a fact for these tests: an integer, a text of a
// name, or a whole hash.
@(private = "file")
Root_Fact_Value :: union {
	u64,
	string,
	[module.HASH_SIZE]u8,
}

@(private = "file")
Root_Fact_Field :: struct {
	name:  string,
	value: Root_Fact_Value,
}

// root_facts_file gives a module file with the table Facts of the root
// service, made from the extraction of its sources.
@(private = "file")
root_facts_file :: proc(t: ^testing.T) -> (file: []u8, ok: bool) {
	paths, listed := foundation.files_with_suffix(foundation.SYSTEM_MODULE_SOURCES + "root", ".odin")
	if !testing.expect(t, listed, "the sources of root cannot be listed") {
		return nil, false
	}
	sources := make([dynamic]Fact_Source, context.temp_allocator)
	for path in paths {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source, readable := foundation.read_file(path)
		if !testing.expectf(t, readable, "the source %s cannot be read", path) {
			return nil, false
		}
		append(&sources, Fact_Source{path = path, source = string(source)})
	}
	facts, extracted := facts_of_sources(sources[:])
	if !testing.expect(t, extracted && len(facts) > 0, "the extraction gives no fact type of root") {
		return nil, false
	}
	description: Module_Description
	if !testing.expect(t, facts_merge(&description, facts), "the fact types of root do not merge") {
		return nil, false
	}
	return facts_module_file(description), true
}

// facts_module_file writes the tables Records, Fields, Facts and Strings of
// a description, as the conversion writes them: the row 0 of each table is
// empty, and the facts are sorted by key (facts_merge).
@(private = "file")
facts_module_file :: proc(description: Module_Description) -> []u8 {
	TABLES :: module.TABLE_COUNT
	file := make([dynamic]u8, size_of(module.Header) + TABLES * size_of(module.Table_Entry), context.temp_allocator)
	directory: [TABLES]module.Table_Entry
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	put :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	records := make([dynamic]module.Record, context.temp_allocator)
	fields := make([dynamic]module.Field, context.temp_allocator)
	facts := make([dynamic]module.Fact, context.temp_allocator)
	append(&records, module.Record{})
	append(&fields, module.Field{})
	append(&facts, module.Fact{})
	for record in description.records {
		row := module.Record{size = record.size, first_field = u32(len(fields)), field_count = u32(len(record.fields))}
		row.name_offset, row.name_count = put(&strings_table, record.name)
		append(&records, row)
		for item in record.fields {
			field := module.Field{offset = item.offset, type = u8(item.type), unsigned = item.unsigned, integer_unit = item.integer_unit, detail = item.detail, kind = u8(item.kind), contract_enum = u8(item.contract_enum)}
			field.name_offset, field.name_count = put(&strings_table, item.name)
			append(&fields, field)
		}
	}
	for fact in description.facts {
		row := module.Fact{key = fact.key, record = fact.record_index}
		row.template_offset, row.template_count = put(&strings_table, fact.template)
		row.package_offset, row.package_count = put(&strings_table, fact.package_name)
		append(&facts, row)
	}
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, ([^]u8)(raw_data(records[:]))[:len(records) * size_of(module.Record)], u32(len(records)), size_of(module.Record))
	add(&file, &directory, .Fields, ([^]u8)(raw_data(fields[:]))[:len(fields) * size_of(module.Field)], u32(len(fields)), size_of(module.Field))
	add(&file, &directory, .Facts, ([^]u8)(raw_data(facts[:]))[:len(facts) * size_of(module.Fact)], u32(len(facts)), size_of(module.Fact))
	add(&file, &directory, .Strings, strings_table[:], u32(len(strings_table)), 1)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = TABLES}
	(^[TABLES]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

// root_fact_render gives the sentence of the fact type root.<type_name>
// with the values of its fields, by the one render of the contract. A
// field that the test names and the record does not have, a value of
// another form than its field, and a refused render fail the test.
@(private = "file")
root_fact_render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Root_Fact_Field) -> string {
	key := fact_key("root", type_name)
	_, _, description, found := module.fact_find(file, key)
	if !testing.expectf(t, found, "the root service has no fact type %s", type_name) {
		return ""
	}
	bytes := make([]u8, description.size, context.temp_allocator)
	for value in values {
		item: module.Field
		has_field := false
		for number in 0 ..< description.field_count {
			candidate, candidate_ok := module.field(file, description, number)
			if candidate_ok && module.string_at(file, candidate.name_offset, candidate.name_count) == value.name {
				item, has_field = candidate, true
			}
		}
		if !testing.expectf(t, has_field, "the fact type %s has no field %s", type_name, value.name) {
			return ""
		}
		place := bytes[item.offset:][:module.field_size(item)]
		switch written in value.value {
		case u64:
			for index in 0 ..< len(place) {
				place[index] = u8(written >> (8 * u64(index)))
			}
		case string:
			testing.expectf(t, item.type == u8(module.Type.Text) && len(written) <= len(place), "the field %s of %s takes no text of %d bytes", value.name, type_name, len(written))
			copy(place, written)
		case [module.HASH_SIZE]u8:
			hash := written
			testing.expectf(t, len(place) == len(hash), "the field %s of %s takes no hash", value.name, type_name)
			copy(place, hash[:])
		}
	}
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	count, _, refusal := module.fact_sentence_write(file, key, bytes, buffer[:], nil)
	testing.expectf(t, refusal == .None, "the fact %s is refused: %v", type_name, refusal)
	return strings.clone(string(buffer[:count]), context.temp_allocator)
}

// root_old_line gives the line that the root service wrote before the
// fact, with the parts of its call of system.log.
@(private = "file")
root_old_line :: proc(parts: ..sentence.Part) -> string {
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	return strings.clone(sentence.format(buffer[:], ..parts), context.temp_allocator)
}

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
