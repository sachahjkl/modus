#+build !freestanding
package collector_service

import "base:intrinsics"
import "core:testing"
import "internal:collector/collector_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import pr "modus:contract/plans_recipes"
import "modus:contract/wide_grants"
import "modus:system"
import "modus:contract/start_list"

// The test runs on the host: the module links src/library/modus/system,
// whose call of an export is an entry of the machine that the host does
// not have. No test here calls an export through the machine: each drives
// the procedure behind an export with a connection that it makes, as the
// root service would write it.
@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

@(private = "file")
PRINCIPAL :: u64(4)

@(private = "file")
connection_of :: proc(principal: u64, acts_for_principal: bool, name: string) -> (connection: system.Connection) {
	copy(connection.caller[:], name)
	connection.grant = isolated.caller_grant_make(0, principal, acts_for_principal)
	return connection
}

// A service and the private store in memory under it. A restart is a new
// service over the same memory.
@(private = "file")
Service_Fixture :: struct {
	memory:  pr.Memory_Private_Store,
	service: Space_Service,
}

@(private = "file")
fixture_make :: proc() -> ^Service_Fixture {
	fixture := new(Service_Fixture)
	fixture.memory.writes_allowed = -1
	fixture_restart(fixture)
	return fixture
}

// fixture_restart starts the service again over the same store, with the
// bound of its writes as it was.
@(private = "file")
fixture_restart :: proc(fixture: ^Service_Fixture) {
	writes_allowed := fixture.memory.writes_allowed
	port := pr.memory_private_store_port(&fixture.memory)
	fixture.memory.writes_allowed = writes_allowed
	fixture.service = {}
	wide_grants.space_store_init(&fixture.service.store, PRINCIPAL, port, wide_grants.space_window_heap_port())
}

@(private = "file")
terms_of :: proc(kind: wide_grants.Collector_Space_Kind, bound: i64, forwarding := wide_grants.Space_Forwarding.Keeps, record_size: i64 = 8) -> wide_grants.Space_Terms {
	return {kind_word = i64(kind), bound_records = bound, forwarding_word = i64(forwarding), record_size = record_size}
}

// open_space opens a space of source and output for the console of the
// principal, and fails the test when the collector refuses it.
@(private = "file")
open_space :: proc(t: ^testing.T, service: ^Space_Service, source, output: string, terms: wide_grants.Space_Terms) -> i64 {
	console := connection_of(PRINCIPAL, true, "console")
	source_text, output_text, held_terms := source, output, terms
	error: errors.Error_Record
	outcome, number := space_open_for(service, &console, &source_text, &output_text, &held_terms, &error)
	testing.expectf(t, outcome == .Succeeded && number >= 1, "the space of %s.%s was refused: %v %v", source, output, outcome, error)
	return number
}

@(private = "file")
append_value :: proc(service: ^Space_Service, connection: ^system.Connection, space: i64, value: u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) {
	bytes := [8]u8{value, value, value, value, value, value, value, value}
	record := system.Bytes_To_Read{bytes = &bytes[0], count = len(bytes), capacity = len(bytes)}
	return record_append_for(service, connection, space, &record, u64(100 + int(value)), error)
}

// The pair of a procedure behind an export, as one value that a check
// reads.
@(private = "file")
Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}

@(private = "file")
answer_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> Answer {
	return {outcome, value}
}

// A refusal gives its outcome, the value 0 and its error record.
@(private = "file")
expect_refusal :: proc(t: ^testing.T, answer: Answer, outcome: call_outcome.Call_Outcome, error: errors.Error_Record, kind: errors.Kind, unit: errors.Unit, location := #caller_location) {
	testing.expect_value(t, answer.outcome, outcome, location)
	testing.expect_value(t, answer.value, 0, location)
	testing.expect_value(t, error.kind, i64(kind), location)
	testing.expect_value(t, error.unit, i64(unit), location)
}

@(private = "file")
expect_answer :: proc(t: ^testing.T, answer: Answer, value: i64, location := #caller_location) {
	testing.expect_value(t, answer.outcome, call_outcome.Call_Outcome.Succeeded, location)
	testing.expect_value(t, answer.value, value, location)
}

@(private = "file")
read_all :: proc(service: ^Space_Service, connection: ^system.Connection, space: i64, heads: []wide_grants.Kept_Record_Head, bytes: []u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) {
	head_table := system.Table_To_Append(wide_grants.Kept_Record_Head){records = raw_data(heads), capacity = u64(len(heads))}
	byte_place := system.Bytes_To_Append{bytes = raw_data(bytes), capacity = u64(len(bytes))}
	return records_read_for(service, connection, space, -1, wide_grants.SPACE_RECORDS_MOST, &head_table, &byte_place, error)
}

// A caller with no connection, a caller of another principal, and a caller
// of the principal that does not act for it each read, list, count, verify,
// open and write nothing: No_Grant with its unit, and nothing changes.
@(test)
a_wrong_principal_reads_and_lists_nothing :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	space := open_space(t, service, "server", "orders", terms_of(.Audit, 4))
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record
	expect_answer(t, answer_of(append_value(service, &console, space, 1, &error)), i64(0))

	stranger := connection_of(PRINCIPAL + 1, true, "console")
	not_acting := connection_of(PRINCIPAL, false, "console")
	machine := connection_of(0, true, "console")
	callers := [?]^system.Connection{nil, &stranger, &not_acting, &machine}
	for caller in callers {
		expected := call_outcome.Call_Outcome.Grant_Or_Right_Missing
		unit := caller == nil ? errors.Unit.Connection : errors.Unit.Acts_For_Principal

		rows: [64]wide_grants.Space_Row
		row_slice := rows[:]
		error = {}
		expect_refusal(t, answer_of(spaces_for(service, caller, &row_slice, &error)), expected, error, .No_Grant, unit)
		testing.expect(t, rows == {}, "a refused caller received a row")

		heads: [4]wide_grants.Kept_Record_Head
		bytes: [32]u8
		error = {}
		expect_refusal(t, answer_of(read_all(service, caller, space, heads[:], bytes[:], &error)), expected, error, .No_Grant, unit)
		testing.expect(t, heads == {} && bytes == {}, "a refused caller received a record")

		row: wide_grants.Space_Row
		error = {}
		expect_refusal(t, answer_of(space_stats_for(service, caller, space, &row, &error)), expected, error, .No_Grant, unit)
		testing.expect(t, row == {}, "a refused caller received the state of a space")

		error = {}
		expect_refusal(t, answer_of(space_verify_for(service, caller, space, &error)), expected, error, .No_Grant, unit)

		source, output, terms := "server", "orders", terms_of(.Keep, 4)
		error = {}
		expect_refusal(t, answer_of(space_open_for(service, caller, &source, &output, &terms, &error)), expected, error, .No_Grant, unit)

		error = {}
		expect_refusal(t, answer_of(append_value(service, caller, space, 9, &error)), expected, error, .No_Grant, unit)
	}
	held := wide_grants.space_of(&service.store, u32(space))
	testing.expect_value(t, held.count, u32(1))
	testing.expect_value(t, held.next_serial, u64(1))
	testing.expect_value(t, wide_grants.space_count(&service.store), 1)
}

// The source of a space acts for the principal and still reads, lists and
// sets the terms of nothing of its own audit; a term that would turn the
// audit into a space that removes records is refused to anyone; the space
// keeps each record through each try.
@(test)
a_source_never_reads_or_erases_its_own_audit :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	space := open_space(t, service, "server", "orders", terms_of(.Audit, 4))
	other := open_space(t, service, "shop", "orders", terms_of(.Audit, 4))
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record
	for value in u8(0) ..< 3 {
		expect_answer(t, answer_of(append_value(service, &console, space, value, &error)), i64(value))
	}
	source := connection_of(PRINCIPAL, true, "server")

	heads: [4]wide_grants.Kept_Record_Head
	bytes: [32]u8
	error = {}
	expect_refusal(t, answer_of(read_all(service, &source, space, heads[:], bytes[:], &error)), .Grant_Or_Right_Missing, error, .No_Grant, .Acts_For_Principal)
	testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Own_Space))
	testing.expect(t, heads == {} && bytes == {}, "the source read its own audit")

	row: wide_grants.Space_Row
	error = {}
	expect_refusal(t, answer_of(space_stats_for(service, &source, space, &row, &error)), .Grant_Or_Right_Missing, error, .No_Grant, .Acts_For_Principal)
	testing.expect(t, row == {}, "the source read the state of its own audit")

	// The source lists the space of another source, never its own.
	rows: [64]wide_grants.Space_Row
	row_slice := rows[:]
	expect_answer(t, answer_of(spaces_for(service, &source, &row_slice, &error)), i64(1))
	testing.expect_value(t, rows[0].space, other)

	// The source cannot set terms for its own pair, even the same ones.
	source_text, output_text := "server", "orders"
	for terms in ([?]wide_grants.Space_Terms{terms_of(.Audit, 4), terms_of(.Keep, 4), terms_of(.Audit, 4, .Keeps, 16)}) {
		held_terms := terms
		error = {}
		expect_refusal(t, answer_of(space_open_for(service, &source, &source_text, &output_text, &held_terms, &error)), .Grant_Or_Right_Missing, error, .No_Grant, .Acts_For_Principal)
	}
	// Terms that would thin the audit are refused to the principal too.
	keep_terms := terms_of(.Keep, 4)
	error = {}
	expect_refusal(t, answer_of(space_open_for(service, &console, &source_text, &output_text, &keep_terms, &error)), .Argument_Refused, error, .Bad_Value, .None)
	testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Bad_Kind))

	testing.expect_value(t, wide_grants.space_count(&service.store), 2)
	expect_answer(t, answer_of(read_all(service, &console, space, heads[:], bytes[:], &error)), i64(3))
	expect_answer(t, answer_of(space_verify_for(service, &console, space, &error)), i64(0))
}

// An audit space takes records up to its bound exactly, then refuses the
// next with Full and keeps nothing of it; a record of no byte, of another
// size, past the largest size, with no bytes, or for a space that does not
// exist is refused; a changed record breaks the chain.
@(test)
an_audit_space_holds_its_bound_and_refuses_each_bad_record :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record

	source_text, output_text := "server", "requests"
	for bound in ([?]i64{min(i64), -1, 0, wide_grants.SPACE_AUDIT_BOUND_MOST + 1, max(i64)}) {
		terms := terms_of(.Audit, bound)
		error = {}
		expect_refusal(t, answer_of(space_open_for(service, &console, &source_text, &output_text, &terms, &error)), .Argument_Refused, error, .Bad_Value, .None)
	}
	testing.expect_value(t, wide_grants.space_count(&service.store), 0)

	space := open_space(t, service, "server", "requests", terms_of(.Audit, 4))
	for value in u8(0) ..< 4 {
		expect_answer(t, answer_of(append_value(service, &console, space, value, &error)), i64(value))
	}
	held := wide_grants.space_of(&service.store, u32(space))
	error = {}
	expect_refusal(t, answer_of(append_value(service, &console, space, 4, &error)), .Callee_Busy, error, .Full, .Records)
	testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Space_Full))
	expect_refusal(t, answer_of(append_value(service, &console, space, 5, &error)), .Callee_Busy, error, .Full, .Records)
	testing.expect_value(t, held.count, u32(4))
	testing.expect_value(t, held.next_serial, u64(4))
	testing.expect_value(t, held.refused_full, u64(2))

	other := open_space(t, service, "server", "log", terms_of(.Audit, 4))
	bytes: [wide_grants.SPACE_RECORD_BYTES_MOST + 1]u8
	cases := [?]system.Bytes_To_Read {
		{bytes = &bytes[0], count = 0, capacity = len(bytes)},
		{bytes = &bytes[0], count = 7, capacity = len(bytes)},
		{bytes = &bytes[0], count = 9, capacity = len(bytes)},
		{bytes = &bytes[0], count = wide_grants.SPACE_RECORD_BYTES_MOST + 1, capacity = len(bytes)},
		{bytes = &bytes[0], count = max(u64), capacity = len(bytes)},
		{bytes = nil, count = 8, capacity = 8},
	}
	for &record in cases {
		error = {}
		outcome, value := record_append_for(service, &console, other, &record, 1, &error)
		testing.expectf(t, outcome == .Argument_Refused && value == 0, "a record of %d bytes was kept: %v", record.count, outcome)
		testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Wrong_Size))
	}
	error = {}
	expect_refusal(t, answer_of(record_append_for(service, &console, other, nil, 1, &error)), .Argument_Refused, error, .Bad_Address, .None)
	places := i64(len(service.store.spaces))
	for number in ([?]i64{min(i64), -1, 0, places + 1, i64(max(u32)), i64(max(u32)) + 1, max(i64)}) {
		error = {}
		expect_refusal(t, answer_of(append_value(service, &console, number, 1, &error)), .Nothing_Has_That_Name, error, .Absent, .Records)
	}
	testing.expect_value(t, wide_grants.space_of(&service.store, u32(other)).next_serial, u64(0))

	// The read limit has the bounds of a space.
	heads: [4]wide_grants.Kept_Record_Head
	head_table := system.Table_To_Append(wide_grants.Kept_Record_Head){records = &heads[0], capacity = len(heads)}
	for limit in ([?]i64{min(i64), -1, 0, wide_grants.SPACE_RECORDS_MOST + 1, max(i64)}) {
		error = {}
		expect_refusal(t, answer_of(records_read_for(service, &console, space, -1, limit, &head_table, nil, &error)), .Argument_Refused, error, .Out_Of_Range, .Records)
	}
	error = {}
	expect_refusal(t, answer_of(records_read_for(service, &console, space, -2, 1, &head_table, nil, &error)), .Argument_Refused, error, .Bad_Value, .None)
	testing.expect_value(t, head_table.count, u64(0))
	expect_answer(t, answer_of(records_read_for(service, &console, space, 1, 1, &head_table, nil, &error)), i64(1))
	testing.expect_value(t, heads[0].serial, i64(2))

	// A record changed in place breaks the chain at its serial.
	expect_answer(t, answer_of(space_verify_for(service, &console, space, &error)), i64(0))
	held.ring.bytes[wide_grants.SPACE_RECORD_BYTES_MOST] ~= 0xFF
	error = {}
	expect_refusal(t, answer_of(space_verify_for(service, &console, space, &error)), .Data_Damaged, error, .Damaged, .Records)
	testing.expect_value(t, error.value, i64(1))
}

// A record of a space that forwards is kept before the forward queue takes
// it: a Paired consumer that takes nothing leaves each kept record in the
// space, a full queue refuses the next record before the space keeps it,
// and a record that the space refuses never reaches the queue.
@(test)
a_record_is_kept_before_it_is_forwarded :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record
	space := open_space(t, service, "shop", "orders", terms_of(.Audit, wide_grants.SPACE_RECORDS_MOST, .Forward))
	held := wide_grants.space_of(&service.store, u32(space))

	for value in u8(0) ..< wide_grants.FORWARD_QUEUE_PER_SPACE_LIMIT {
		expect_answer(t, answer_of(append_value(service, &console, space, value, &error)), i64(value))
		// The newest record in the queue is one that the space holds.
		testing.expect_value(t, held.next_serial, u64(value) + 1)
	}
	error = {}
	expect_refusal(t, answer_of(append_value(service, &console, space, 99, &error)), .Callee_Busy, error, .Full, .Records)
	testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Forward_Full))
	testing.expect_value(t, held.count, u32(wide_grants.FORWARD_QUEUE_PER_SPACE_LIMIT))
	testing.expect_value(t, held.forwarded, u64(0))

	heads: [wide_grants.SPACE_RECORDS_MOST]wide_grants.Kept_Record_Head
	bytes: [wide_grants.SPACE_RECORDS_MOST * 8]u8
	expect_answer(t, answer_of(read_all(service, &console, space, heads[:], bytes[:], &error)), i64(wide_grants.FORWARD_QUEUE_PER_SPACE_LIMIT))

	// Each queued record is a kept one, in order, with the same bytes.
	for expected in u64(0) ..< wide_grants.FORWARD_QUEUE_PER_SPACE_LIMIT {
		item, refusal := wide_grants.forward_peek(&service.store)
		testing.expect_value(t, refusal, wide_grants.Space_Refusal.None)
		testing.expect_value(t, item.serial, expected)
		testing.expect_value(t, i64(item.serial), heads[expected].serial)
		testing.expect_value(t, item.bytes[0], bytes[expected * 8])
		testing.expect_value(t, wide_grants.forward_done(&service.store), wide_grants.Space_Refusal.None)
	}
	testing.expect_value(t, held.forwarded, u64(wide_grants.FORWARD_QUEUE_PER_SPACE_LIMIT))
	testing.expect_value(t, held.count, u32(wide_grants.FORWARD_QUEUE_PER_SPACE_LIMIT))

	// A full audit space that forwards refuses the record, and the queue
	// stays empty.
	small := open_space(t, service, "shop", "returns", terms_of(.Audit, 1, .Forward))
	expect_answer(t, answer_of(append_value(service, &console, small, 1, &error)), i64(0))
	testing.expect_value(t, wide_grants.forward_done(&service.store), wide_grants.Space_Refusal.None)
	error = {}
	expect_refusal(t, answer_of(append_value(service, &console, small, 2, &error)), .Callee_Busy, error, .Full, .Records)
	testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Space_Full))
	_, refusal := wide_grants.forward_peek(&service.store)
	testing.expect_value(t, refusal, wide_grants.Space_Refusal.Forward_Empty)
}

// The collector is the first reader of the act records of a wide grant: it
// refuses a malformed act record with nothing changed, and serves the
// records by grant and by a range of sequences to the principal only.
@(test)
act_records_are_refused_when_malformed_and_read_by_the_principal_only :: proc(t: ^testing.T) {
	manager := new(collector_core.Wide_Grant_Manager)
	defer free(manager)
	testing.expect(t, !collector_core.manager_init(manager, PRINCIPAL, {}), "the all-zero authority key is refused")
	testing.expect(t, collector_core.manager_init(manager, PRINCIPAL, blake3.hash(transmute([]u8)string("unlock-authority-key"))))
	collector := &manager.collector
	kinds := [?]wide_grants.Act_Kind{.Grant_Started, .Key_Injected, .Frame_Read, .Pointer_Clicked, .Grant_Revoked}
	grants := [?]u64{1, 1, 2, 1, 2}
	for kind, index in kinds {
		_, refusal := collector_core.collector_append(collector, grants[index], u64(100 + index), kind, 7)
		testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.None)
	}

	// Each malformed record is refused, and the chain stays as it was.
	next := wide_grants.Act_Record {
		sequence_number  = collector.next_sequence,
		grant_serial     = 1,
		timestamp_ms     = 200,
		act_kind_word    = u64(wide_grants.Act_Kind.Key_Injected),
		target_window_id = 7,
		previous_hash    = collector.head_hash,
	}
	testing.expect_value(t, wide_grants.act_record_seal(&next), wide_grants.Wide_Grant_Refusal.None)
	malformed: [7]wide_grants.Act_Record
	for &record in malformed {
		record = next
	}
	malformed[0].grant_serial = 0
	malformed[1].act_kind_word = 0
	malformed[2].act_kind_word = max(u64)
	malformed[3].sequence_number += 1
	malformed[4].previous_hash[0] ~= 1
	malformed[5].record_hash[31] ~= 1
	malformed[6].timestamp_ms = 0
	for &record, index in malformed {
		refusal := collector_core.collector_append_prebuilt(collector, &record)
		testing.expectf(t, refusal != .None, "the malformed act record %d was kept", index)
	}
	testing.expect_value(t, collector.count, u32(len(kinds)))
	testing.expect_value(t, collector_core.collector_append_prebuilt(collector, &next), wide_grants.Wide_Grant_Refusal.None)
	verified, _ := collector_core.collector_verify(collector)
	testing.expect_value(t, verified, wide_grants.Wide_Grant_Refusal.None)

	staging: [4]wide_grants.Act_Record
	place: [8]wide_grants.Act_Record
	table := system.Table_To_Append(wide_grants.Act_Record){records = &place[0], capacity = len(place)}
	error: errors.Error_Record

	stranger := connection_of(PRINCIPAL + 1, true, "console")
	holder := connection_of(PRINCIPAL, false, "remote")
	for caller in ([?]^system.Connection{nil, &stranger, &holder}) {
		error = {}
		outcome, value := act_records_read_for(manager, PRINCIPAL, caller, 0, 0, max(i64), &table, staging[:], &error)
		testing.expectf(t, outcome == .Grant_Or_Right_Missing && value == 0, "a caller that does not act for the principal read act records: %v", outcome)
		testing.expect_value(t, error.kind, i64(errors.Kind.No_Grant))
	}
	testing.expect_value(t, table.count, u64(0))

	console := connection_of(PRINCIPAL, true, "console")
	bad_ranges := [?][3]i64{{-1, 0, 1}, {0, -1, 1}, {0, 3, 2}, {0, max(i64), min(i64)}}
	for range in bad_ranges {
		error = {}
		expect_refusal(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, range[0], range[1], range[2], &table, staging[:], &error)), .Argument_Refused, error, .Bad_Value, .None)
	}
	error = {}
	expect_refusal(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, 0, 0, 1, nil, staging[:], &error)), .Argument_Refused, error, .Bad_Address, .None)
	testing.expect_value(t, table.count, u64(0))

	// By grant: the records of grant 1, in sequence order.
	expect_answer(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, 1, 0, max(i64), &table, staging[:], &error)), i64(4))
	testing.expect_value(t, table.count, u64(4))
	for sequence, index in ([?]u64{0, 1, 3, 5}) {
		testing.expect_value(t, place[index].sequence_number, sequence)
		testing.expect_value(t, place[index].grant_serial, u64(1))
	}

	// By range: the sequences 1 ..= 3 of each grant, one past the end is no record.
	table.count = 0
	expect_answer(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, 0, 1, 3, &table, staging[:], &error)), i64(3))
	testing.expect_value(t, place[0].sequence_number, u64(1))
	testing.expect_value(t, place[2].sequence_number, u64(3))
	table.count = 0
	expect_answer(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, 0, 6, 6, &table, staging[:], &error)), i64(0))
	expect_answer(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, 3, 0, max(i64), &table, staging[:], &error)), i64(0))
	testing.expect_value(t, table.count, u64(0))

	// The count of the full answer passes what one call holds.
	small := system.Table_To_Append(wide_grants.Act_Record){records = &place[0], capacity = 2}
	expect_answer(t, answer_of(act_records_read_for(manager, PRINCIPAL, &console, 0, 0, max(i64), &small, staging[:], &error)), i64(6))
	testing.expect_value(t, small.count, u64(2))
	testing.expect_value(t, place[1].sequence_number, u64(1))
}

// The records of an audit space that the collector kept, across several
// segments, are each there after a start of the collector over the same
// store, with their serials and their chain; the next record takes the next
// serial; the source and a stranger still read nothing of the space.
@(test)
an_audit_space_survives_a_restart_of_the_collector :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record
	space := open_space(t, service, "server", "orders", terms_of(.Audit, wide_grants.SPACE_RECORDS_MOST))
	kept := u8(wide_grants.SPACE_SEGMENT_RECORDS * 2 + 3)
	for value in u8(0) ..< kept {
		expect_answer(t, answer_of(append_value(service, &console, space, value, &error)), i64(value))
	}
	last_hash := wide_grants.space_of(&service.store, u32(space)).last_hash

	fixture_restart(fixture)
	heads: [wide_grants.SPACE_RECORDS_MOST]wide_grants.Kept_Record_Head
	bytes: [wide_grants.SPACE_RECORDS_MOST * 8]u8
	expect_answer(t, answer_of(read_all(service, &console, space, heads[:], bytes[:], &error)), i64(kept))
	for value in u8(0) ..< kept {
		testing.expect_value(t, heads[value].serial, i64(value))
		testing.expect_value(t, heads[value].time_ms, i64(100 + int(value)))
		testing.expect_value(t, bytes[int(value) * 8], value)
	}
	testing.expect(t, wide_grants.space_of(&service.store, u32(space)).last_hash == last_hash, "the last link changed at the restart")
	expect_answer(t, answer_of(space_verify_for(service, &console, space, &error)), i64(0))
	expect_answer(t, answer_of(record_count_for(service, &console, &error)), i64(kept))
	expect_answer(t, answer_of(source_count_for(service, &console, &error)), i64(1))
	expect_answer(t, answer_of(append_value(service, &console, space, kept, &error)), i64(kept))

	source := connection_of(PRINCIPAL, true, "server")
	stranger := connection_of(PRINCIPAL + 1, true, "console")
	for caller in ([?]^system.Connection{&source, &stranger}) {
		other_heads: [4]wide_grants.Kept_Record_Head
		other_bytes: [32]u8
		error = {}
		expect_refusal(t, answer_of(read_all(service, caller, space, other_heads[:], other_bytes[:], &error)), .Grant_Or_Right_Missing, error, .No_Grant, .Acts_For_Principal)
		testing.expect(t, other_heads == {} && other_bytes == {}, "a refused caller read the audit after the restart")
		row: wide_grants.Space_Row
		error = {}
		expect_refusal(t, answer_of(space_stats_for(service, caller, space, &row, &error)), .Grant_Or_Right_Missing, error, .No_Grant, .Acts_For_Principal)
		testing.expect(t, row == {}, "a refused caller read the state of the audit after the restart")
	}
}

// One changed bit in a stored segment refuses each export of the spaces
// after a start, with Damaged of the unit Store, and serves no record.
@(test)
a_damaged_segment_refuses_each_export_after_a_restart :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record
	space := open_space(t, service, "server", "orders", terms_of(.Audit, wide_grants.SPACE_RECORDS_MOST))
	for value in u8(0) ..< wide_grants.SPACE_SEGMENT_RECORDS + 1 {
		expect_answer(t, answer_of(append_value(service, &console, space, value, &error)), i64(value))
	}
	name_place: [wide_grants.SEGMENT_OBJECT_NAME_BYTES]u8
	places := [?]int{wide_grants.SEGMENT_SPACE_AT, wide_grants.SEGMENT_FIRST_SERIAL_AT, wide_grants.SEGMENT_PREVIOUS_HASH_AT, wide_grants.SEGMENT_HEAD_BYTES + wide_grants.SEGMENT_RECORD_HEAD_BYTES}
	for segment in u64(0) ..< 2 {
		object := pr.memory_private_store_find(&fixture.memory, wide_grants.segment_object_name(&name_place, u32(space), segment))
		testing.expect(t, object != nil, "a segment is missing")
		for place in places {
			object.bytes[place] ~= 0x10
			fixture_restart(fixture)
			heads: [4]wide_grants.Kept_Record_Head
			bytes: [32]u8
			error = {}
			expect_refusal(t, answer_of(read_all(service, &console, space, heads[:], bytes[:], &error)), .Data_Damaged, error, .Damaged, .Store)
			testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Store_Damaged))
			testing.expect(t, heads == {} && bytes == {}, "a damaged store served a record")
			error = {}
			expect_refusal(t, answer_of(append_value(service, &console, space, 1, &error)), .Data_Damaged, error, .Damaged, .Store)
			error = {}
			expect_refusal(t, answer_of(space_verify_for(service, &console, space, &error)), .Data_Damaged, error, .Damaged, .Store)
			error = {}
			expect_refusal(t, answer_of(record_count_for(service, &console, &error)), .Data_Damaged, error, .Damaged, .Store)
			rows: [64]wide_grants.Space_Row
			row_slice := rows[:]
			error = {}
			expect_refusal(t, answer_of(spaces_for(service, &console, &row_slice, &error)), .Data_Damaged, error, .Damaged, .Store)
			source_text, output_text, terms := "shop", "log", terms_of(.Audit, 4)
			error = {}
			expect_refusal(t, answer_of(space_open_for(service, &console, &source_text, &output_text, &terms, &error)), .Data_Damaged, error, .Damaged, .Store)
			object.bytes[place] ~= 0x10
		}
	}
	fixture_restart(fixture)
	expect_answer(t, answer_of(space_verify_for(service, &console, space, &error)), i64(0))
}

// A write that the store refuses returns Device of the unit Store: the
// space keeps nothing, the forward queue takes nothing, and the writer
// sends the record again with the same serial. A collector with no store
// keeps no audit space.
@(test)
a_refused_store_write_keeps_and_forwards_nothing :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	console := connection_of(PRINCIPAL, true, "console")
	error: errors.Error_Record
	space := open_space(t, service, "shop", "orders", terms_of(.Audit, wide_grants.SPACE_RECORDS_MOST, .Forward))
	expect_answer(t, answer_of(append_value(service, &console, space, 0, &error)), i64(0))
	testing.expect_value(t, wide_grants.forward_done(&service.store), wide_grants.Space_Refusal.None)
	held := wide_grants.space_of(&service.store, u32(space))
	snapshot := held^

	fixture.memory.writes_allowed = fixture.memory.writes
	error = {}
	expect_refusal(t, answer_of(append_value(service, &console, space, 1, &error)), .Callee_Unavailable, error, .Device, .Store)
	testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Store_Failed))
	testing.expect(t, held^ == snapshot, "a refused write changed the space")
	_, refusal := wide_grants.forward_peek(&service.store)
	testing.expect_value(t, refusal, wide_grants.Space_Refusal.Forward_Empty)

	fixture.memory.writes_allowed = -1
	expect_answer(t, answer_of(append_value(service, &console, space, 1, &error)), i64(1))
	item, queued := wide_grants.forward_peek(&service.store)
	testing.expect_value(t, queued, wide_grants.Space_Refusal.None)
	testing.expect_value(t, item.serial, u64(1))

	no_store := new(Space_Service)
	defer free(no_store)
	wide_grants.space_store_init(&no_store.store, PRINCIPAL, {}, wide_grants.space_window_heap_port())
	source_text, output_text, terms := "server", "orders", terms_of(.Audit, 4)
	error = {}
	expect_refusal(t, answer_of(space_open_for(no_store, &console, &source_text, &output_text, &terms, &error)), .Callee_Unavailable, error, .Device, .Store)
	testing.expect_value(t, wide_grants.space_count(&no_store.store), 0)
}

// Fresh authority key passed through context value slots verifies a minted
// wide grant in collector_core, while another key, a tampered grant, or a
// zero key is refused. Act outputs of all four producers wire to principal-
// isolated audit spaces at the grant and stop recording on revocation.
@(test)
wide_grant_authority_key_and_act_wiring_in_collector :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service

	fresh_key := blake3.hash(transmute([]u8)string("fresh-start-key-1"))
	other_key := blake3.hash(transmute([]u8)string("fresh-start-key-2"))
	verifier := blake3.hash(transmute([]u8)string("passphrase-verified"))

	auth: wide_grants.Wide_Grant_Authority
	testing.expect(t, wide_grants.authority_init_from_bytes(&auth, fresh_key, .Entropy))
	key_words, words_ok := wide_grants.authority_context_words(&auth)
	testing.expect(t, words_ok)
	collector_key := wide_grants.authority_key_from_words(key_words)

	manager := new(collector_core.Wide_Grant_Manager)
	defer free(manager)
	testing.expect(t, !collector_core.manager_init(manager, PRINCIPAL, {}), "zero key must be refused")
	testing.expect(t, collector_core.manager_init(manager, PRINCIPAL, collector_key))

	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = PRINCIPAL,
		grantee_identity_hash = blake3.hash(transmute([]u8)string("agent-key-1")),
		authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}),
		target_window_count   = 1,
		target_window_ids     = {0 = 101},
		duration_ms           = wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	testing.expect_value(t, wide_grants.wide_grant_terms_seal(&terms), wide_grants.Wide_Grant_Refusal.None)

	// Proof from another key is refused.
	other_auth: wide_grants.Wide_Grant_Authority
	testing.expect(t, wide_grants.authority_init_from_bytes(&other_auth, other_key, .Processor))
	wrong_proof, _ := wide_grants.authority_mint_proof(&other_auth, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 100)
	_, wrong_refusal := collector_core.manager_create_grant(manager, &terms, &wrong_proof, 100, 100 + terms.duration_ms)
	testing.expect_value(t, wrong_refusal, wide_grants.Wide_Grant_Refusal.Invalid_Proof)

	// Proof from fresh key is accepted; tampered proof is refused.
	good_proof, mint_r := wide_grants.authority_mint_proof(&auth, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 200)
	testing.expect_value(t, mint_r, wide_grants.Wide_Grant_Refusal.None)
	tampered := good_proof
	tampered.proof_tag[3] ~= 0x80
	_, tampered_r := collector_core.manager_create_grant(manager, &terms, &tampered, 200, 200 + terms.duration_ms)
	testing.expect_value(t, tampered_r, wide_grants.Wide_Grant_Refusal.Invalid_Proof)

	serial, created_r := collector_core.manager_create_grant(manager, &terms, &good_proof, 200, 200 + terms.duration_ms)
	testing.expect_value(t, created_r, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, serial, u64(1))

	// Wire all four act spaces at grant, verify producer isolation, and revoke.
	router: wide_grants.Grant_Act_Router
	testing.expect_value(t, wide_grants.act_wiring_attach(&router, &service.store, serial, PRINCIPAL, {.View_Screen, .Send_Input}, terms.duration_ms, 200), wide_grants.Act_Wiring_Refusal.None)
	_, emit_r := wide_grants.act_wiring_emit(&router, &service.store, {
		grant_serial     = serial,
		principal_id     = PRINCIPAL,
		timestamp_ms     = 210,
		producer_word    = u64(wide_grants.Act_Producer.Trusted_Display),
		act_kind_word    = u64(wide_grants.Act_Kind.Key_Injected),
		target_window_id = 101,
		detail_word_0    = 3,
	})
	testing.expect_value(t, emit_r, wide_grants.Act_Wiring_Refusal.None)

	// A producer cannot read its own audit space; the principal's reader can.
	compositor_caller := connection_of(PRINCIPAL, true, "compositor")
	principal_reader := connection_of(PRINCIPAL, true, "auditor")
	heads: [4]wide_grants.Kept_Record_Head
	bytes: [4 * size_of(wide_grants.Act_Stream_Record)]u8
	error: errors.Error_Record
	expect_refusal(t, read_all(service, &compositor_caller, i64(router.space_numbers[.Trusted_Display]), heads[:], bytes[:], &error), ERROR_NOT_PRINCIPAL, error, .No_Grant, .Acts_For_Principal)
	testing.expect_value(t, read_all(service, &principal_reader, i64(router.space_numbers[.Trusted_Display]), heads[:], bytes[:], &error), i64(1))

	// Revocation ends recording cleanly.
	testing.expect_value(t, collector_core.manager_revoke_grant(manager, serial, 300, .Principal_Revoked), wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, wide_grants.act_wiring_revoke(&router, &service.store, serial, .Principal_Revoked, 300), wide_grants.Act_Wiring_Refusal.None)
	_, post_revoke := wide_grants.act_wiring_emit(&router, &service.store, {
		grant_serial     = serial,
		principal_id     = PRINCIPAL,
		timestamp_ms     = 310,
		producer_word    = u64(wide_grants.Act_Producer.Remote_Service),
		act_kind_word    = u64(wide_grants.Act_Kind.Frame_Read),
		target_window_id = 101,
	})
	testing.expect_value(t, post_revoke, wide_grants.Act_Wiring_Refusal.Grant_Revoked)
}

// The export space_open opens no act space of a wide grant: a caller that
// acts for the principal, with the terms of the grant or with another
// record size, is refused with No_Grant and the value Act_Space, and the
// act space that the grant opened stays open with its records.
@(test)
the_export_opens_no_act_space :: proc(t: ^testing.T) {
	fixture := fixture_make()
	defer free(fixture)
	service := &fixture.service
	act, opened := wide_grants.space_open(&service.store, transmute([]u8)string("remote"), transmute([]u8)string(wide_grants.ACT_OUTPUT_NAME), wide_grants.act_audit_space_terms())
	testing.expect_value(t, opened, wide_grants.Space_Refusal.None)
	console := connection_of(PRINCIPAL, true, "console")
	for record_size in ([?]i64{i64(size_of(wide_grants.Act_Stream_Record)), 8}) {
		source_text, output_text := "remote", wide_grants.ACT_OUTPUT_NAME
		terms := wide_grants.act_audit_space_terms()
		terms.record_size = record_size
		error: errors.Error_Record
		expect_refusal(t, space_open_for(service, &console, &source_text, &output_text, &terms, &error), ERROR_NOT_PRINCIPAL, error, .No_Grant, .Records)
		testing.expect_value(t, error.found, i64(wide_grants.Space_Refusal.Act_Space))
		testing.expect_value(t, error.argument, i64(2))
	}
	space := wide_grants.space_of(&service.store, act)
	testing.expect(t, space != nil && !space.closed && space.ring != nil, "the act space closed")
	testing.expect_value(t, wide_grants.space_count(&service.store), 1)
}

// The wiring pages that the collector states are the pages of its act
// rings as the start list counts the pages of a wiring row, and the root
// service carves them whatever the collector spent before: the rule of the
// root on a request that states them, one that states more than its pages,
// and one that states none.
@(test)
the_collector_states_the_pages_of_its_act_rings :: proc(t: ^testing.T) {
	row := start_list.wiring_pages_of_row(wide_grants.ACT_RING_CAPACITY, size_of(wide_grants.Act_Stream_Record))
	testing.expect_value(t, COLLECTOR_ACT_RING_PAGES, row)
	testing.expect_value(t, COLLECTOR_ACT_WIRING_PAGES, start_list.WIRING_PAGES_OF_THE_ASKER + u64(wide_grants.ACT_SPACES_RESERVED) * row)
	testing.expect_value(t, MODULE_BUDGET.wiring_pages, COLLECTOR_ACT_WIRING_PAGES)
}
