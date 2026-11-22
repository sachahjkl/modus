// The exports of the spaces of the collector: one bounded space of kept
// records for each pair of a source process and a record output
// (src/md/features/module_outputs.md, "The collector" and "The audit").
//
// The collector serves only a caller that acts for its principal, the
// principal of the starter of each source that it keeps, and never the
// source of a space: the root service writes the name and the principal of
// each caller, so a source cannot read or change its own audit.
package collector_service

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/wide_grants"
import "modus:system"

// The failures of the exports of this file, each with its error record.
ERROR_NO_CALLER :: i64(-1) // No_Grant, Connection: the call came through no connection.
ERROR_NOT_PRINCIPAL :: i64(-2) // No_Grant, Acts_For_Principal: the caller does not act for the principal of the collector.
ERROR_SPACE :: i64(-3) // The space refuses the step: the value found is the Space_Refusal.
ERROR_FULL :: i64(-4) // Full, Records: the space or the forward queue is full; the writer sends the record again.

// The spaces of this collector, for its principal.
space_store: wide_grants.Space_Store

// The parts of the call, copied once out of the call region.
copied_space_terms: wide_grants.Space_Terms
copied_source_name: [wide_grants.SPACE_NAME_BYTES]u8
copied_output_name: [wide_grants.SPACE_NAME_BYTES]u8
copied_record: [wide_grants.SPACE_RECORD_BYTES_MOST]u8
read_heads: [wide_grants.SPACE_RECORDS_MOST]wide_grants.Kept_Record_Head
read_bytes: [wide_grants.SPACE_RECORDS_MOST * wide_grants.SPACE_RECORD_BYTES_MOST]u8

// space_reader gives who calls, as the root service wrote it, and refuses a
// caller that does not act for the principal of the collector.
@(private = "file")
space_reader :: proc "contextless" (error: ^errors.Error_Record) -> (reader: wide_grants.Space_Reader, failure: i64, ok: bool) {
	connection := system.service_caller()
	if connection == nil {
		return {}, errors.fail(error, ERROR_NO_CALLER, .No_Grant, .Connection), false
	}
	reader = {
		principal          = isolated.caller_principal(connection.grant),
		acts_for_principal = connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0,
		name               = connection.caller,
	}
	if !reader.acts_for_principal || reader.principal != space_store.principal {
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
	case .Space_Limit_Reached, .Bound_Past_Room:
		return errors.fail(error, ERROR_SPACE, .Over_Limit, .Records, argument, 0, wide_grants.SPACE_ROOM_RECORDS, found)
	case .Unknown_Space, .Forward_Empty:
		return errors.fail(error, ERROR_SPACE, .Absent, .Records, argument, 0, 0, found)
	case .Not_Principal, .Own_Space:
		return errors.fail(error, ERROR_NOT_PRINCIPAL, .No_Grant, .Acts_For_Principal, argument, 0, 0, found)
	case .Chain_Broken:
		return errors.fail(error, ERROR_SPACE, .Damaged, .Records, argument, 0, 0, found)
	case .None, .Bad_Kind, .Bad_Forwarding, .Bad_Bound, .Bad_Name, .Bad_Record_Size, .Wrong_Size:
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

// space_open gives the space of a source and one of its record outputs,
// with its terms. A pair with a space of the same record and terms gives
// that space again.
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
	if _, failure, ok := space_reader(error); !ok {
		return failure
	}
	source_name, source_failure, source_ok := name_copy(source, copied_source_name[:], 1, error)
	if !source_ok {
		return source_failure
	}
	output_name, output_failure, output_ok := name_copy(output, copied_output_name[:], 2, error)
	if !output_ok {
		return output_failure
	}
	if terms == nil {
		return errors.fail(error, ERROR_SPACE, .Bad_Address, .None, 3)
	}
	copied_space_terms = intrinsics.volatile_load(terms)
	number, refusal := wide_grants.space_open(&space_store, source_name, output_name, copied_space_terms)
	if refusal != .None {
		return space_refusal_fail(error, refusal, 3)
	}
	return i64(number)
}

// record_append keeps one record in a space, and queues it for the forward
// when the space forwards. A full audit space or a full forward queue
// refuses the record and keeps nothing: its writer waits and sends it again,
// so no record is lost.
//
// The result is the serial of the record in its space, or a negative number
// with an error record: ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, ERROR_FULL, or
// ERROR_SPACE with the refusal as the value found.
@(export, link_name = "record_append")
record_append :: proc "c" (space: i64, record: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := space_reader(error); !ok {
		return failure
	}
	if space < 1 || space > wide_grants.SPACE_CAPACITY {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	if record == nil {
		return errors.fail(error, ERROR_SPACE, .Bad_Address, .None, 2)
	}
	count := intrinsics.volatile_load(&record.count)
	if count == 0 || count > wide_grants.SPACE_RECORD_BYTES_MOST {
		return space_refusal_fail(error, .Wrong_Size, 2)
	}
	intrinsics.mem_copy_non_overlapping(&copied_record[0], record.bytes, int(count))
	serial, refusal := wide_grants.record_append(&space_store, u32(space), copied_record[:count], system.time())
	if refusal != .None {
		// One line at the first wait of a space: its counts show the others,
		// and a held writer that retries never floods the log.
		if refusal == .Space_Full || refusal == .Forward_Full {
			if held := wide_grants.space_of(&space_store, u32(space)); held != nil && held.refused_full == 1 {
				system.log_fact(.Warning, Space_Refused_Record{space = u64(space), refusal_code = u64(refusal)})
			}
		}
		return space_refusal_fail(error, refusal, 2)
	}
	return i64(min(serial, u64(max(i64))))
}

// records_read gives the records of a space whose serial is after after
// (-1 for each record), oldest first: a head for each, and their bytes one
// after the other. A source never reads its own space.
//
// The result is the count of such records, or a negative number with an
// error record: ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, or ERROR_SPACE.
@(export, link_name = "records_read")
records_read :: proc "c" (space: i64, after: i64, heads: ^system.Table_To_Append(wide_grants.Kept_Record_Head), bytes: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> i64 {
	reader, failure, ok := space_reader(error)
	if !ok {
		return failure
	}
	if space < 1 || space > wide_grants.SPACE_CAPACITY {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	if after < -1 {
		return errors.fail(error, ERROR_SPACE, .Bad_Value, .None, 2, after, -1)
	}
	count, refusal := wide_grants.records_read(&space_store, u32(space), after, &reader, read_heads[:], read_bytes[:])
	if refusal != .None {
		return space_refusal_fail(error, refusal, 1)
	}
	kept := min(count, len(read_heads))
	written := 0
	for index in 0 ..< kept {
		head := read_heads[index]
		if heads != nil {
			system.table_append(heads, head)
		}
		if bytes != nil {
			system.bytes_append(bytes, read_bytes[written:][:head.size])
		}
		written += int(head.size)
	}
	return i64(count)
}

// spaces gives the state of each space.
//
// The result is the count of spaces, or a negative number with an error
// record: ERROR_NO_CALLER or ERROR_NOT_PRINCIPAL.
@(export, link_name = "spaces")
spaces :: proc "c" (result: ^[]wide_grants.Space_Row, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := space_reader(error); !ok {
		return failure
	}
	count := 0
	for &space, index in space_store.spaces {
		if !space.active {
			continue
		}
		if count < len(result^) {
			result[count] = wide_grants.space_row_of(&space, u32(index + 1))
		}
		count += 1
	}
	return i64(count)
}

// space_verify walks the chain of an audit space.
//
// The result is 0, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_NOT_PRINCIPAL, or ERROR_SPACE with Chain_Broken as
// the value found and the serial of the first broken link as the value.
@(export, link_name = "space_verify")
space_verify :: proc "c" (space: i64, error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := space_reader(error); !ok {
		return failure
	}
	if space < 1 || space > wide_grants.SPACE_CAPACITY {
		return space_refusal_fail(error, .Unknown_Space, 1)
	}
	refusal, failing_serial := wide_grants.space_verify(&space_store, u32(space))
	if refusal == .Chain_Broken {
		return errors.fail(error, ERROR_SPACE, .Damaged, .Records, 1, i64(min(failing_serial, u64(max(i64)))), 0, i64(refusal))
	}
	if refusal != .None {
		return space_refusal_fail(error, refusal, 1)
	}
	return 0
}

// source_count gives the sources that have a space.
@(export, link_name = "source_count")
source_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := space_reader(error); !ok {
		return failure
	}
	return i64(wide_grants.source_count(&space_store))
}

// record_count gives the records that the spaces keep now.
@(export, link_name = "record_count")
record_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if _, failure, ok := space_reader(error); !ok {
		return failure
	}
	return i64(min(wide_grants.kept_record_count(&space_store), u64(max(i64))))
}
