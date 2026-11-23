// The exports of the spaces of the collector: one bounded space of kept
// records for each pair of a source process and a record output
// (src/md/features/module_outputs.md).
//
// The collector serves only a caller that acts for its principal, the
// principal of the starter of each source that it keeps, and never the
// source of a space: the root service writes the name and the principal of
// each caller, so a source cannot read, list or set the terms of its own
// audit. No export removes a record or ends a space.
//
// The audit spaces live in the private store of the collector, as segments
// chained by their hash (modus:contract/wide_grants, collector_segments.odin):
// a record of an audit space is in the store before the call returns its
// serial and before the forward queue takes it, and a start of the
// collector reads each space back and checks each segment.
//
// Each export reads the connection of its call, then hands it to a
// procedure that takes the state of the spaces and the connection as
// arguments: the host tests drive those procedures with the connections of
// a principal, of a stranger and of a source.
package collector_service

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/wide_grants"
import "modus:system"

// The failures of the exports of this file, each with its error record.
ERROR_NO_CALLER :: i64(-1) // No_Grant, Connection: the call came through no connection.
ERROR_NOT_PRINCIPAL :: i64(-2) // No_Grant, Acts_For_Principal: the caller does not act for the principal of the collector, or is the source of the space.
ERROR_SPACE :: i64(-3) // The space refuses the step: the value found is the Space_Refusal.
ERROR_FULL :: i64(-4) // Full, Records: the space or the forward queue is full; the writer sends the record again.
ERROR_STORE :: i64(-5) // Device or Damaged, Store: the private store refused a read or a write, or holds a damaged space.

// The spaces of this collector, and the places where a call is copied
// once out of the call region.
Space_Service :: struct {
	store:              wide_grants.Space_Store,
	copied_space_terms: wide_grants.Space_Terms,
	copied_source_name: [wide_grants.SPACE_NAME_BYTES]u8,
	copied_output_name: [wide_grants.SPACE_NAME_BYTES]u8,
	copied_record:      [wide_grants.SPACE_RECORD_BYTES_MOST]u8,
	read_heads:         [wide_grants.SPACE_RECORDS_MOST]wide_grants.Kept_Record_Head,
	read_bytes:         [wide_grants.SPACE_RECORDS_MOST * wide_grants.SPACE_RECORD_BYTES_MOST]u8,
}

// The spaces of this collector, for its principal: in BSS, off the stack of
// the thread.
space_service: Space_Service

// principal_reader_of gives who calls, as the root service wrote it in the
// grant of the connection, and refuses a caller that does not act for
// principal.
principal_reader_of :: proc "contextless" (principal: u64, connection: ^system.Connection, error: ^errors.Error_Record) -> (reader: wide_grants.Space_Reader, failure: i64, ok: bool) {
	if connection == nil {
		return {}, errors.fail(error, ERROR_NO_CALLER, .No_Grant, .Connection), false
	}
	reader = {
		principal          = isolated.caller_principal(connection.grant),
		acts_for_principal = connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0,
		name               = connection.caller,
	}
	if !reader.acts_for_principal || reader.principal != principal {
		return {}, errors.fail(error, ERROR_NOT_PRINCIPAL, .No_Grant, .Acts_For_Principal), false
	}
	return reader, 0, true
}

// space_refusal_fail writes the error record of a refusal of the spaces,
// with the refusal as the value found.
@(private = "file")
space_refusal_fail :: proc "contextless" (error: ^errors.Error_Record, refusal: wide_grants.Space_Refusal, argument: i64) -> i64 {
	found := i64(refusal)
	switch refusal {
	case .Space_Full, .Forward_Full:
		return errors.fail(error, ERROR_FULL, .Full, .Records, argument, 0, 0, found)
	case .Space_Limit_Reached:
		return errors.fail(error, ERROR_SPACE, .Over_Limit, .Records, argument, 0, wide_grants.SPACE_CAPACITY, found)
	case .Bad_Limit:
		return errors.fail(error, ERROR_SPACE, .Out_Of_Range, .Records, argument, 0, wide_grants.SPACE_RECORDS_MOST, found)
	case .Unknown_Space, .Forward_Empty:
		return errors.fail(error, ERROR_SPACE, .Absent, .Records, argument, 0, 0, found)
	case .Not_Principal, .Own_Space:
		return errors.fail(error, ERROR_NOT_PRINCIPAL, .No_Grant, .Acts_For_Principal, argument, 0, 0, found)
	case .Chain_Broken:
		return errors.fail(error, ERROR_SPACE, .Damaged, .Records, argument, 0, 0, found)
	case .Store_Failed:
		return errors.fail(error, ERROR_STORE, .Device, .Store, argument, 0, 0, found)
	case .Store_Damaged:
		return errors.fail(error, ERROR_STORE, .Damaged, .Store, argument, 0, 0, found)
	case .Space_Held:
		return errors.fail(error, ERROR_SPACE, .Exists, .Records, argument, 0, 0, found)
	case .Memory_Refused:
		// The window of the space: the budget pays no more, or keeps the
		// windows of the act spaces of a wide grant (src/md/features/wide_grants.md,
		// "The memory of the spaces").
		return errors.fail(error, ERROR_SPACE, .Budget, .Pages, argument, 0, wide_grants.SPACE_WINDOW_PAGES, found)
	case .Space_Closed:
		// The record size of the source changed: the space keeps its records
		// and takes no more.
		return errors.fail(error, ERROR_SPACE, .State, .Records, argument, 0, 0, found)
	case .Bad_Bound:
		// The largest bound: SPACE_RECORDS_MOST for a space Keep, which holds
		// its records in memory, SPACE_AUDIT_BOUND_MOST for a space Audit.
		return errors.fail(error, ERROR_SPACE, .Bad_Value, .None, argument, 0, wide_grants.SPACE_AUDIT_BOUND_MOST, found)
	case .None, .Bad_Kind, .Bad_Forwarding, .Bad_Name, .Bad_Record_Size, .Wrong_Size:
		return errors.fail(error, ERROR_SPACE, .Bad_Value, .None, argument, 0, 0, found)
	}
	return errors.fail(error, ERROR_SPACE, .Bad_Value, .None, argument, 0, 0, found)
}

// name_copy copies a Text argument once into place and gives its bytes.
@(private = "file")
name_copy :: proc "contextless" (text: ^string, place: []u8, argument: i64, error: ^errors.Error_Record) -> (name: []u8, failure: i64, ok: bool) {
	if text == nil {
		return nil, errors.fail(error, ERROR_SPACE, .Bad_Address, .None, argument), false
	}
	view := intrinsics.volatile_load(text)
	if len(view) == 0 {
		return nil, errors.fail(error, ERROR_SPACE, .Empty, .Bytes, argument, 0, i64(len(place) - 1)), false
	}
	if len(view) >= len(place) {
		return nil, errors.fail(error, ERROR_SPACE, .Too_Long, .Bytes, argument, i64(len(view)), i64(len(place) - 1)), false
	}
	intrinsics.mem_copy_non_overlapping(&place[0], raw_data(view), len(view))
	return place[:len(view)], 0, true
}

// space_number_valid refuses a space number that names no place of the
// store, before any narrowing to u32.
@(private = "file")
space_number_valid :: proc "contextless" (space: i64) -> bool {
	return space >= 1 && space <= wide_grants.SPACE_CAPACITY
}

space_open_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, source: ^string, output: ^string, terms: ^wide_grants.Space_Terms, error: ^errors.Error_Record) -> i64 {
	reader, failure, ok := principal_reader_of(service.store.principal, connection, error)
	if !ok {
		return failure
	}
	source_name, source_failure, source_ok := name_copy(source, service.copied_source_name[:], 1, error)
	if !source_ok {
		return source_failure
	}
	if allowed := wide_grants.space_open_allowed(&service.store, source_name, &reader); allowed != .None {
		return space_refusal_fail(error, allowed, 1)
	}
	output_name, output_failure, output_ok := name_copy(output, service.copied_output_name[:], 2, error)
	if !output_ok {
		return output_failure
	}
	if terms == nil {
		return errors.fail(error, ERROR_SPACE, .Bad_Address, .None, 3)
	}
	service.copied_space_terms = intrinsics.volatile_load(terms)
	number, refusal := wide_grants.space_open(&service.store, source_name, output_name, service.copied_space_terms)
	if refusal != .None {
		return space_refusal_fail(error, refusal, 3)
	}
	return i64(number)
}

// space_open gives the space of a source and one of its record outputs,
// with its terms. A pair with a space of the same record and terms gives
// that space again. A source never opens a space of its own: the terms of
// an audit are the choice of its starter.
//
// - **source**: the name of the source process.
// - **output**: the name of its record output, or log.
// - **terms**: Keep or Audit, the bound in records, whether the space
//   forwards, and the size of the record.
//
// The result is the number of the space, from 1, or a negative number with
// an error record: ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, or ERROR_SPACE with
// the refusal as the value found.
@(export, link_name = "space_open")
space_open :: proc "c" (source: ^string, output: ^string, terms: ^wide_grants.Space_Terms, error: ^errors.Error_Record) -> i64 {
	return space_open_for(&space_service, system.service_caller(), source, output, terms, error)
}

record_append_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, space: i64, record: ^system.Bytes_To_Read, time_ms: u64, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := principal_reader_of(service.store.principal, connection, error); !ok {
		return failure
	}
	if !space_number_valid(space) {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	if record == nil {
		return errors.fail(error, ERROR_SPACE, .Bad_Address, .None, 2)
	}
	// One read of the count: the caller can change its memory during the
	// call, and the copy must use the count that passed the check.
	count := intrinsics.volatile_load(&record.count)
	if count == 0 || count > wide_grants.SPACE_RECORD_BYTES_MOST || record.bytes == nil {
		return space_refusal_fail(error, .Wrong_Size, 2)
	}
	intrinsics.mem_copy_non_overlapping(&service.copied_record[0], record.bytes, int(count))
	serial, refusal := wide_grants.record_append(&service.store, u32(space), service.copied_record[:count], time_ms)
	if refusal != .None {
		return space_refusal_fail(error, refusal, 2)
	}
	return i64(min(serial, u64(max(i64))))
}

// record_append keeps one record in a space, and queues it for the forward
// when the space forwards: the space keeps the record before the queue
// takes it. A full audit space or a full forward queue refuses the record
// and keeps nothing: its writer waits and sends it again, so no record is
// lost.
//
// A record of an audit space is written into its segment in the private
// store first: a refused write keeps nothing and forwards nothing.
//
// The result is the serial of the record in its space, or a negative number
// with an error record: ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, ERROR_FULL,
// ERROR_STORE, or ERROR_SPACE with the refusal as the value found.
@(export, link_name = "record_append")
record_append :: proc "c" (space: i64, record: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	result := record_append_for(&space_service, system.service_caller(), space, record, system.time(), error)
	if result == ERROR_FULL {
		// One line at the first wait of a space: its counts show the others,
		// and a held writer that retries never floods the log.
		if held := wide_grants.space_of(&space_service.store, u32(space)); held != nil && held.refused_full == 1 {
			system.log_fact(.Warning, Space_Refused_Record{space = u64(space), refusal_code = error != nil ? u64(error.found) : 0})
		}
	}
	return result
}

records_read_for :: proc "contextless" (
	service: ^Space_Service,
	connection: ^system.Connection,
	space: i64,
	after: i64,
	limit: i64,
	heads: ^system.Table_To_Append(wide_grants.Kept_Record_Head),
	bytes: ^system.Bytes_To_Append,
	error: ^errors.Error_Record,
) -> i64 {
	reader, failure, ok := principal_reader_of(service.store.principal, connection, error)
	if !ok {
		return failure
	}
	if !space_number_valid(space) {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	if after < -1 {
		return errors.fail(error, ERROR_SPACE, .Bad_Value, .None, 2, after, -1)
	}
	if limit < 1 || limit > wide_grants.SPACE_RECORDS_MOST {
		return space_refusal_fail(error, .Bad_Limit, 3)
	}
	count, refusal := wide_grants.records_read(&service.store, u32(space), after, int(limit), &reader, service.read_heads[:], service.read_bytes[:])
	if refusal != .None {
		return space_refusal_fail(error, refusal, 1)
	}
	kept := min(count, len(service.read_heads))
	written := 0
	for index in 0 ..< kept {
		head := service.read_heads[index]
		if heads != nil {
			system.table_append(heads, head)
		}
		if bytes != nil {
			system.bytes_append(bytes, service.read_bytes[written:][:head.size])
		}
		written += int(head.size)
	}
	return i64(count)
}

// records_read gives the records of a space whose serial is after after
// (-1 for each record), oldest first, at most limit of them: a head for
// each, and their bytes one after the other. A source never reads its own
// space. A reader that wants more asks again after the last serial that it
// received.
//
// The result is the count of such records, or a negative number with an
// error record: ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, or ERROR_SPACE.
@(export, link_name = "records_read")
records_read :: proc "c" (space: i64, after: i64, limit: i64, heads: ^system.Table_To_Append(wide_grants.Kept_Record_Head), bytes: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> i64 {
	return records_read_for(&space_service, system.service_caller(), space, after, limit, heads, bytes, error)
}

spaces_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, result: ^[]wide_grants.Space_Row, error: ^errors.Error_Record) -> i64 {
	reader, failure, ok := principal_reader_of(service.store.principal, connection, error)
	if !ok {
		return failure
	}
	if result == nil {
		return errors.fail(error, ERROR_SPACE, .Bad_Address, .None, 1)
	}
	count, refusal := wide_grants.space_rows(&service.store, &reader, result^)
	if refusal != .None {
		return space_refusal_fail(error, refusal, 1)
	}
	return i64(count)
}

// spaces gives the state of each space, except the spaces whose source is
// the caller.
//
// The result is the count of such spaces, or a negative number with an
// error record: ERROR_NO_CALLER or ERROR_NOT_PRINCIPAL.
@(export, link_name = "spaces")
spaces :: proc "c" (result: ^[]wide_grants.Space_Row, error: ^errors.Error_Record) -> i64 {
	return spaces_for(&space_service, system.service_caller(), result, error)
}

space_stats_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, space: i64, out: ^wide_grants.Space_Row, error: ^errors.Error_Record) -> i64 {
	reader, failure, ok := principal_reader_of(service.store.principal, connection, error)
	if !ok {
		return failure
	}
	if !space_number_valid(space) {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	if out == nil {
		return errors.fail(error, ERROR_SPACE, .Bad_Address, .None, 2)
	}
	row, refusal := wide_grants.space_stats(&service.store, u32(space), &reader)
	if refusal != .None {
		return space_refusal_fail(error, refusal, 1)
	}
	out^ = row
	return 0
}

// space_stats gives the state of one space: its terms, its counts and its
// last link. A source never reads the state of its own space.
//
// The result is 0, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, or ERROR_SPACE.
@(export, link_name = "space_stats")
space_stats :: proc "c" (space: i64, out: ^wide_grants.Space_Row, error: ^errors.Error_Record) -> i64 {
	return space_stats_for(&space_service, system.service_caller(), space, out, error)
}

space_verify_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, space: i64, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := principal_reader_of(service.store.principal, connection, error); !ok {
		return failure
	}
	if !space_number_valid(space) {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	refusal, failing_serial := wide_grants.space_verify(&service.store, u32(space))
	// A link that breaks is the one refusal with a serial as its value.
	if refusal == .Chain_Broken {
		return errors.fail(error, ERROR_SPACE, .Damaged, .Records, 1, i64(min(failing_serial, u64(max(i64)))), 0, i64(refusal))
	}
	if refusal != .None {
		return space_refusal_fail(error, refusal, 1)
	}
	return 0
}

// space_verify walks the chain of an audit space in memory, then reads each
// of its segments back from the private store and compares it.
//
// The result is 0, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, ERROR_STORE, or ERROR_SPACE with
// Chain_Broken as the value found and the serial of the first broken link,
// or the first serial of the first segment that does not match, as the
// value.
@(export, link_name = "space_verify")
space_verify :: proc "c" (space: i64, error: ^errors.Error_Record) -> i64 {
	return space_verify_for(&space_service, system.service_caller(), space, error)
}

source_count_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := principal_reader_of(service.store.principal, connection, error); !ok {
		return failure
	}
	if ready := wide_grants.space_store_ready(&service.store); ready != .None {
		return space_refusal_fail(error, ready, 0)
	}
	return i64(wide_grants.source_count(&service.store))
}

// source_count gives the sources that have a space.
@(export, link_name = "source_count")
source_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	return source_count_for(&space_service, system.service_caller(), error)
}

record_count_for :: proc "contextless" (service: ^Space_Service, connection: ^system.Connection, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := principal_reader_of(service.store.principal, connection, error); !ok {
		return failure
	}
	if ready := wide_grants.space_store_ready(&service.store); ready != .None {
		return space_refusal_fail(error, ready, 0)
	}
	return i64(min(wide_grants.kept_record_count(&service.store), u64(max(i64))))
}

// record_count gives the records that the spaces keep now.
@(export, link_name = "record_count")
record_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	return record_count_for(&space_service, system.service_caller(), error)
}
