// The isolated call: a process calls an export of a module that runs in
// another process. A command is a function, and its arguments are typed
// records, never text (docs/MODULE_CONTRACT.md, sections 4 and 5).
//
// The caller starts a call host: a process that loads one module and serves
// its exports. The call host receives two memory objects:
//
//   the call ring     a ring (package ring). One command record is one call.
//   the call region   memory that the two processes share. The caller writes
//                     the argument record and the bytes of its slices in it.
//
// The command record:
//   kind        the index of the export
//   tag         a number that the caller chooses; the completion record has it
//   values[0]   the offset of the argument record in the call region
//   values[1]   the size of the argument record, in bytes
//
// The completion record (src/md/api/call_outcome.md, "The borders of the
// isolated call"):
//   kind        the word of the call outcome (call_outcome.Call_Outcome):
//               of the export, or of the receiver that refused the call
//   values      with Succeeded, values[0] is the value of the export; with
//               any other outcome, the seven values are the error record
//               (errors.completion_values)
//
// The argument record is derived from the description of the export
// (module.Function). It has one field per parameter, in order:
//   Integer   8 bytes: the value.
//   Text      16 bytes: a Slice. In a direct call the argument holds the
//             address of a slice record. An address has no meaning in another
//             process, so the field holds the slice record itself, and the
//             slice holds an offset in the call region.
//   Record    8 bytes: the offset of the bytes of the record in the call
//             region. The description gives the size. The receiver copies
//             the record to private memory before the call: the caller
//             cannot change it while the export runs.
//   Handle    8 bytes: the handle, as the receiver names it. Before the
//             call, the caller gives a copy of its handle to the receiver
//             through the call ring, with the rights of the description
//             (the kernel operation Handle_Give, with the memory of the call
//             ring as the target). A Handle field of a Record parameter
//             holds such a handle too. The receiver proves each handle
//             (Handle_State) and closes it when the export returns. 0 is
//             "no handle".
//
//   Table, Bytes  32 bytes: a Table_Field (tables.odin): the records in the
//             call region, or in a lent memory object.
//
// An export with a Record result has one more field after the parameters:
// the offset of the place of the result in the call region. The export
// writes the record in private memory of the receiver, and the receiver
// copies it to that place.
//
// An export with a Text result has one more field after the parameters, and
// one more argument in the direct call: a buffer, {start, capacity}. The
// caller owns the buffer; the callee writes the text in it and gives the
// count of bytes of the full text as its integer result. For an isolated
// call the buffer is in the call region: the callee writes the result where
// the caller reads it, with no copy between.
//
// An export with a Table result has one more field after the parameters,
// and one more argument in the direct call: a buffer, {start, capacity},
// where the capacity is a count of records. In an isolated call the buffer
// is the rest of the call region, from a multiple of 8 bytes. The callee
// gives the count of records of the full table as its integer result.
//
// An export with an error record (module.Function.error_record) has no
// field for it: the record is private to the receiver. In the direct call it
// is one more argument, after the buffer of a result; the receiver gives the
// export the address of its own record (Call.error_record), and copies the
// record into the completion when the export fails. A caller reads no record
// from the call region.
//
// The receiver trusts nothing in the call region. It copies the argument
// record to private memory, and it checks each offset and each count
// against the size of the call region (decode).
//
// This package allocates no memory and calls no kernel operation.
//
// Who uses it: `src/library/modus/system` on the side of the caller (`system.call_isolated`
// and the connections to services) and on the side of the receiver (the
// call host `src/modules/system/host` and each service that serves its own exports).
// The parts:
//
// - `encode` and `decode`: the argument record, on each side.
// - `Argument`, `Slice`, `Call`, `Lent`: what the two sides hold.
// - `Table_Field`, `Table_Argument`, `table_encode`, `tables_return`: the
//   tables and the bytes (`tables.odin`).
// - `answer_completion` and `answer_of_completion`: the completion of a
//   call, on each side.
// - `Service_Command` and the `CALLER_` constants: how the root service
//   connects a caller to a service.
// - `GRANT_RING`, `GRANT_REGION`, the `VALUE_` constants: the context of a
//   call host.
//
// See [isolated call](term:isolated-call) and [call host](term:call-host).
package isolated

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import module "modus:contract/module"
import "modus:contract/ring"
import "base:intrinsics"

// The roles of the context of a call host.
GRANT_RING :: 0 // Memory: the call ring.
GRANT_REGION :: 1 // Memory: the call region.
// The files of a call host: the caller maps them read-only at FILE_ADDRESS,
// in the form of the boot image. Entry 1 is the module; the other entries
// are its imports, and the modules of the replacements that apply to them.
// The replacement records (module.Replacement) are on the first page, after
// the entries.
VALUE_FILE_ADDRESS :: 0 // Where the caller mapped the files.
VALUE_FILE_SIZE :: 1 // The size of the files, in bytes, from FILE_ADDRESS.
VALUE_REPLACEMENT_OFFSET :: 2 // The offset of the replacement records, from FILE_ADDRESS.
VALUE_REPLACEMENT_COUNT :: 3 // The count of the replacement records, at most `system.REPLACEMENT_CAPACITY`.

FILE_ADDRESS :: fixed_addresses.MODULE_FILES_ADDRESS // Where a caller maps the files of the module in the call host.
// Where a receiver maps the memory object of table parameter n for the
// time of one export: TABLE_ADDRESS + n * TABLE_SPAN. The same addresses at
// each call: the kernel gives a new address to each mapping that does not
// choose one, and each new range of addresses costs page tables.
TABLE_ADDRESS :: fixed_addresses.MODULE_TABLES_ADDRESS
TABLE_SPAN :: u64(16) << 30 // The most bytes of one table in a memory object: 16 GiB.
#assert(module.PARAMETER_CAPACITY * TABLE_SPAN <= fixed_addresses.RANGE_SPAN)
// The pages of the call region that a caller makes for one connection: 64
// KiB, for the argument record, the bytes of its texts and a result.
REGION_PAGES :: 16

// A service that serves its own exports receives calls in the same form. It
// has one connection for each caller: one call ring and one call region.
// The root service names each connection on the service ring of the
// process, as a command record:
//   kind        a Service_Command
//   values[0]   the handle of the call ring, in the service
//   values[1]   the handle of the call region, in the service
//   values[2..5] Connect: the name of the caller, as the root service names
//               it: 32 bytes, zero bytes after the name. A process that the
//               root service starts again has the same name.
//   values[6]   Connect and Grant: what the root service grants to the
//               caller in this service. The caller cannot change it.
//               Bits 0 to 45 (CALLER_AMOUNT_MASK): an amount; the service
//               gives it a meaning, for example a limit of blocks. 0: no
//               amount.
//               Bit 46 (CALLER_ERASES_VERSIONS): the storage service lets
//               the caller erase the versions of the objects of its private
//               store (the start grant Versions_Erase). Another service
//               ignores it.
//               Bit 47 (CALLER_READS_ONLY): the connection reads only; the
//               service refuses each call that changes what it keeps. The
//               root service sets it on the connection through which the
//               debugger service reads the debug object of a disk process.
//               Bits 48 to 62 (CALLER_PRINCIPAL_MASK): the number of the
//               principal whose session the caller belongs to
//               (docs/PRINCIPALS.md): 0 is the machine, 1 and more a named
//               principal. It is a fact of the connection, not a grant: a
//               service can name it in what it records.
//               Bit 63 (CALLER_ACTS_FOR_PRINCIPAL): the caller acts for that
//               principal, and can see what the service holds for all
//               callers. A caller without it sees what is its own only.
// The callers of one service at one time: tools, consoles, agents through
// `remote` and other services. A service waits on the call ring of each
// one, two words of a wait each, and keeps half of a wait of the kernel
// (op.WORD_WAIT_CAPACITY) for its other words.
SERVICE_CONNECTION_CAPACITY :: 48
// The connections that the root service holds at one time: each client of
// each service. Stated once here, so the table of remote is sized from the
// share that the root service gives it (remote.SERVICE_CONNECTIONS).
ROOT_CONNECTION_CAPACITY :: 256
// The places of each service that a caller for a client of another machine
// (a connection of `remote` for a row of its client table) never takes:
// the clients that a principal allowed cannot fill a service, and a local
// console, a window or another service still connects.
SERVICE_CONNECTION_LOCAL_RESERVE :: 16
#assert(SERVICE_CONNECTION_LOCAL_RESERVE < SERVICE_CONNECTION_CAPACITY)

// connection_place_open says if a new connection can take a place: of a
// service that holds service_count callers, in a table of table_capacity
// places of which table_used are taken, remote_used of them for clients of
// other machines. A connection for a client of another machine takes at
// most remote_share places of the table and leaves
// SERVICE_CONNECTION_LOCAL_RESERVE places of each service; a local caller
// takes any free place.
connection_place_open :: proc "contextless" (for_remote_client: bool, service_count, table_used, remote_used, table_capacity, remote_share: int) -> bool {
	if table_used >= table_capacity || service_count >= SERVICE_CONNECTION_CAPACITY {
		return false
	}
	if for_remote_client {
		return remote_used < remote_share && service_count < SERVICE_CONNECTION_CAPACITY - SERVICE_CONNECTION_LOCAL_RESERVE
	}
	return true
}
CALLER_AMOUNT_MASK :: u64(1) << 46 - 1 // The bits of the amount in values[6]: bits 0 to 45.
CALLER_ERASES_VERSIONS :: u64(1) << 46 // The bit of values[6] set when the caller may erase the versions of its objects.
CALLER_READS_ONLY :: u64(1) << 47 // The bit of values[6] set when the connection reads only.
CALLER_PRINCIPAL_SHIFT :: 48 // The first bit of the number of the principal in values[6].
CALLER_PRINCIPAL_LIMIT :: u64(1) << 15 // The numbers of principals that the field holds: 0 to 32767.
CALLER_PRINCIPAL_MASK :: (CALLER_PRINCIPAL_LIMIT - 1) << CALLER_PRINCIPAL_SHIFT // The bits of the number of the principal in values[6]: bits 48 to 62.
CALLER_ACTS_FOR_PRINCIPAL :: u64(1) << 63 // The bit of values[6] set when the caller acts for its principal.

// caller_principal gives the number of the principal that a grant of
// values[6] names.
caller_principal :: proc "contextless" (grant: u64) -> u64 {
	return (grant & CALLER_PRINCIPAL_MASK) >> CALLER_PRINCIPAL_SHIFT
}

// caller_grant_make gives values[6] from its three parts. An amount or a
// number of a principal out of its field is cut to the field: the root
// service, the one writer, never gives one.
//
// Example: `caller_grant_make(4096, 1, false)` is the grant of 4096 (blocks,
// for the storage service) to a caller of the principal 1 that does not act
// for that principal.
caller_grant_make :: proc "contextless" (amount: u64, principal: u64, acts_for_principal: bool) -> u64 {
	grant := amount & CALLER_AMOUNT_MASK | (principal & (CALLER_PRINCIPAL_LIMIT - 1)) << CALLER_PRINCIPAL_SHIFT
	if acts_for_principal {
		grant |= CALLER_ACTS_FOR_PRINCIPAL
	}
	return grant
}

// What the root service tells a service about one connection, as the kind of
// a command record of the service ring. The service answers each one with a
// completion; the values of the command are in the comment above
// `SERVICE_CONNECTION_CAPACITY`.
Service_Command :: enum u32 {
	None       = 0, // Not a command: the service refuses it.
	Connect    = 1, // The service maps the two memory objects, and serves the calls of the call ring.
	Disconnect = 2, // The service unmaps them and closes the two handles.
	Grant      = 3, // The grant of the connection of the call ring changes to values[6]: a revocation, for example.
}

// In the call region, `start` is an offset. In a process, it is an address.
//
// It is the form of a Text argument in the argument record, and of the
// buffer of a Text or Table result. A receiver checks that `start + count`
// is inside the call region before it reads a byte (`decode`). 16 bytes.
Slice :: struct {
	start: u64, // An offset in the call region, or an address in a process.
	count: u64, // Bytes; for the buffer of a Table result, records.
}
#assert(size_of(Slice) == 16)

// One argument of a call, before it is encoded. The type of the parameter
// says which field has the value.
Argument :: struct {
	integer: u64, // An Integer. A Handle: the handle, as the receiver names it.
	text:    []u8, // A Text: the bytes, which `encode` copies into the call region.
	record:  []u8, // The bytes of a Record: the size of its description.
	table:   Table_Argument, // A Table or Bytes.
}

// A handle that the caller lent for a call, as the argument record names
// it. The receiver trusts no part of it before Handle_State.
Lent :: struct {
	handle: u32, // In the receiver.
	rights: u32, // The rights that the description asks: op.Rights.
}

// What decode gives: the arguments of the call form, and the private
// memory that they name. export_call puts the first 6 in registers and the
// others on the stack.
Call :: struct {
	arguments:  [module.PARAMETER_CAPACITY]u64, // Argument n of the call form: the value of parameter n, then the buffer or the place of a result, then the error record.
	slices:     [module.PARAMETER_CAPACITY]Slice, // slices[n]: the slice record of a Text.
	records:    [module.PARAMETER_CAPACITY][module.RECORD_SIZE_LIMIT / 8]u64, // records[n]: the copy of a Record.
	lent:       [module.HANDLE_CAPACITY]Lent, // The handles to prove before the call, and to close after it.
	lent_count: int, // The entries of `lent` in use.
	result:     Slice, // A Record result: its place in the call region, as offsets.
	error_record: errors.Error_Record, // The record that the export writes when it fails: private to the receiver, which copies it into the completion.
	places:        [module.PARAMETER_CAPACITY]module.Table_Place, // places[n]: the table place of a Table or Bytes, in memory of the receiver.
	count_offsets: [module.PARAMETER_CAPACITY]u64, // An Append place: the offset of its count in the call region.
	mappings:      [module.PARAMETER_CAPACITY]Table_Mapping, // The memory objects to map before the call.
	mapping_count: int, // The entries of `mappings` in use.
}

// The largest argument record: a table field for each argument of the call
// form, and a buffer. The buffer takes an argument of the call form, so this
// bounds each valid description.
ARGUMENT_RECORD_LIMIT :: module.PARAMETER_CAPACITY * size_of(Table_Field) + size_of(Slice)

ERROR_RECORD_SIZE :: 56 // src/library/modus/contract/errors: Error_Record, a record of a table of error details.

// field_size gives the bytes of the field of one parameter type in the
// argument record: 8 for an Integer, a Record and a Handle, 16 for a Text
// (a `Slice`), 32 for a Table and Bytes (a `Table_Field`). 0: a type that has
// no field, and a byte that names no type, which `record_size` refuses.
field_size :: proc "contextless" (word: u8) -> u64 {
	type, type_ok := module.type_of_word(word)
	if !type_ok {
		return 0
	}
	switch type {
	case .Integer, .Record, .Handle, .Enum:
		return 8
	case .Text:
		return size_of(Slice)
	case .Table, .Bytes:
		return size_of(Table_Field)
	case .None:
	}
	return 0
}

// result_field_size gives the bytes of the field of a result in the
// argument record. ok is false for a type that is no result (Handle,
// Bytes), and for a byte of the description that names no type.
@(private)
result_field_size :: proc "contextless" (word: u8) -> (size: u64, ok: bool) {
	type := module.type_of_word(word) or_return
	switch type {
	case .None, .Integer, .Enum:
		return 0, true
	case .Text, .Table:
		return size_of(Slice), true
	case .Record:
		return 8, true
	case .Handle, .Bytes:
	}
	return 0, false
}

// record_size gives the size of the argument record of an export.
// ok is false when the description has a type that this code does not know.
record_size :: proc "contextless" (function: module.Function) -> (size: u64, ok: bool) {
	function := function
	// The buffer of a result and the error record are arguments of the call
	// form too: an export whose parameters fit can still have no argument
	// free for them.
	if function.parameter_count > module.PARAMETER_CAPACITY || module.call_argument_count(int(function.parameter_count), function.result, function.error_record != 0) > module.PARAMETER_CAPACITY || !directions_valid(function) {
		return 0, false
	}
	for word in function.parameters[:function.parameter_count] {
		field := field_size(word)
		if field == 0 {
			return 0, false
		}
		size += field
	}
	result_field := result_field_size(function.result) or_return
	size += result_field
	return size, true
}

// store writes a value at an offset of the call region, with no alignment.
// The caller checked that the bytes are inside the region.
@(private)
store :: proc "contextless" (region: []u8, offset: u64, value: $T) {
	value := value
	intrinsics.mem_copy_non_overlapping(raw_data(region[offset:]), &value, size_of(T))
}

// load reads a value at an offset of the call region, with no alignment.
// The caller checked that the bytes are inside the region.
@(private)
load :: proc "contextless" (region: []u8, offset: u64, $T: typeid) -> (value: T) {
	intrinsics.mem_copy_non_overlapping(&value, raw_data(region[offset:]), size_of(T))
	return value
}

// encode writes the argument record of a call at the start of the call
// region, and the bytes of each Text after it. The caller owns the call
// region: one call uses it at a time.
// For a Text result, the buffer is the part of the call region after the
// arguments: `result` names it. For a Record result, `result` names the
// place of the record.
// file is the module of the export: it has the descriptions of the records.
// ok is false when the arguments do not agree with the description, or when
// the call region is too small.
// A Table or Bytes argument: see table_encode. encode writes region_start
// in the argument: keep the arguments for tables_return.
encode :: proc "contextless" (file: []u8, function: module.Function, arguments: []Argument, region: []u8) -> (offset, size: u64, result: Slice, ok: bool) {
	function := function
	size = record_size(function) or_return
	if len(arguments) != int(function.parameter_count) || size > u64(len(region)) {
		return 0, 0, {}, false
	}
	field := u64(0)
	next := size // Where the bytes of the next Text go.
	for word, index in function.parameters[:function.parameter_count] {
		// record_size refused each byte that names no type; the border
		// reads the byte again.
		type, type_ok := module.type_of_word(word)
		if !type_ok {
			return 0, 0, {}, false
		}
		switch type {
		case .None:
			// record_size refused a parameter of no type.
		case .Integer, .Enum:
			// An Enum is the value of its member: the export checks it at
			// its border (enum_word.member_of_argument).
			store(region, field, arguments[index].integer)
		case .Text:
			text := arguments[index].text
			if u64(len(text)) > u64(len(region)) - next {
				return 0, 0, {}, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(text), len(text))
			store(region, field, Slice{start = next, count = u64(len(text))})
			next += u64(len(text))
		case .Record:
			described := module.record_type(file, function.parameter_details[index]) or_return
			bytes := arguments[index].record
			next = (next + 7) &~ 7
			if len(bytes) != int(described.size) || next > u64(len(region)) || u64(len(bytes)) > u64(len(region)) - next {
				return 0, 0, {}, false
			}
			intrinsics.mem_copy_non_overlapping(raw_data(region[next:]), raw_data(bytes), len(bytes))
			store(region, field, next)
			next += u64(len(bytes))
		case .Handle:
			if arguments[index].integer >> 32 != 0 {
				return 0, 0, {}, false
			}
			store(region, field, arguments[index].integer)
		case .Table, .Bytes:
			direction, direction_ok := module.direction_of_word(function.parameter_directions[index])
			if !direction_ok {
				return 0, 0, {}, false
			}
			next = table_encode(file, word, function.parameter_details[index], direction, &arguments[index].table, region, field, next) or_return
		}
		field += field_size(word)
	}
	result_type, result_type_ok := module.function_result_type(function)
	if !result_type_ok {
		return 0, 0, {}, false
	}
	switch result_type {
	case .None, .Integer, .Enum:
		// No buffer: the result is in the completion.
	case .Handle, .Bytes:
		// record_size refused these results.
	case .Text:
		result = {start = next, count = u64(len(region)) - next}
		store(region, field, result)
		field += size_of(Slice)
	case .Table:
		described := module.record_type(file, function.result_detail) or_return
		next = (next + 7) &~ 7
		if next > u64(len(region)) || described.size == 0 {
			return 0, 0, {}, false
		}
		result = {start = next, count = (u64(len(region)) - next) / u64(described.size)}
		store(region, field, result)
		field += size_of(Slice)
	case .Record:
		described := module.record_type(file, function.result_detail) or_return
		next = (next + 7) &~ 7
		if next > u64(len(region)) || u64(described.size) > u64(len(region)) - next {
			return 0, 0, {}, false
		}
		result = {start = next, count = u64(described.size)}
		intrinsics.mem_zero(raw_data(region[next:]), int(described.size))
		store(region, field, next)
	}
	return 0, size, result, true
}

// result_record gives the Record result of a call: the bytes at the place
// that encode named. The caller copies them out of the call region, then
// reads them.
result_record :: proc "contextless" (region: []u8, result: Slice, record: []u8) -> bool {
	if result.start > u64(len(region)) || result.count > u64(len(region)) - result.start || u64(len(record)) < result.count {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(record), raw_data(region[result.start:]), int(result.count))
	return true
}

// result_text gives the Text result of a call: the bytes that the callee
// wrote in the buffer. `count` is the number that the callee gave: the
// caller does not trust it. complete is false when the text did not fit.
result_text :: proc "contextless" (region: []u8, result: Slice, count: u64) -> (text: []u8, complete: bool) {
	if result.start > u64(len(region)) || result.count > u64(len(region)) - result.start {
		return nil, false
	}
	return region[result.start:][:min(count, result.count)], count <= result.count
}

// result_table gives the Table result of a call: the records that the
// callee wrote in the buffer, as bytes. `count` is the number that the
// callee gave, and `size` the size of a record of the description: the
// caller trusts neither the count nor the buffer that the region holds.
// complete is false when the table did not fit.
result_table :: proc "contextless" (region: []u8, result: Slice, count: u64, size: u64) -> (records: []u8, complete: bool) {
	if size == 0 || result.start > u64(len(region)) || result.count > (u64(len(region)) - result.start) / size {
		return nil, false
	}
	kept := min(count, result.count)
	return region[result.start:][:kept * size], count <= result.count
}

// decode reads the argument record of a call from the call region, and gives
// the integer arguments of the call form (Call).
//   Integer: the argument has the value.
//   Text:    the argument has the address of call.slices[n]: the address of
//            the bytes in the call region, and their count. The buffer of a
//            Text result is one more Text, after the last parameter.
//   Record:  the argument has the address of call.records[n], a copy.
//   Handle:  the argument has the handle. call.lent has it, and each
//            handle of each record: the receiver proves them.
//   A Record result: the argument after the last parameter has the address
//   of call.records of that place, all zero. After the call, result_store
//   copies it to the call region.
// file is the module of the export. ok is false when a part of the argument
// record is not in the call region, or when two ranges of the call region
// overlap and one of them is written. Then the receiver must not call the
// export, and `refusal` (it can be nil) has an error record that says which
// argument and why, so that the caller learns the cause of each refusal:
// the receiver gives it
// to the caller in the completion record.
decode :: proc "contextless" (file: []u8, function: module.Function, offset, size: u64, region: []u8, call: ^Call, refusal: ^errors.Error_Record = nil) -> (ok: bool) {
	function := function
	expected, described := record_size(function)
	if !described {
		return refuse(refusal, .Bad_Value, .Region, 0, 0, 0)
	}
	limit := u64(len(region))
	if size != expected {
		return refuse(refusal, .Bad_Value, .Region, 0, size, expected)
	}
	if offset > limit || size > limit - offset {
		return refuse(refusal, .Out_Of_Range, .Region, 0, offset + min(size, limit), limit)
	}
	call.lent_count = 0
	call.mapping_count = 0
	call.result = {}
	ranges: Region_Ranges
	// The receiver writes the counts of Append places back into the
	// argument record: no table of the call region overlaps it.
	region_range_add(&ranges, {offset, offset + size, true, 0}, refusal) or_return
	// One copy: the other process can change the call region at any time.
	record: [ARGUMENT_RECORD_LIMIT]u8
	intrinsics.mem_copy_non_overlapping(&record, raw_data(region[offset:]), int(size))
	field := u64(0)
	for word, index in function.parameters[:function.parameter_count] {
		argument := i64(index + 1)
		// record_size refused each byte that names no type; the border
		// reads the byte again.
		type, type_ok := module.type_of_word(word)
		if !type_ok {
			return refuse(refusal, .Bad_Value, .Region, argument, u64(word), 0)
		}
		switch type {
		case .None:
			// record_size refused a parameter of no type.
		case .Integer, .Enum:
			call.arguments[index] = load(record[:], field, u64)
		case .Text:
			slice := load(record[:], field, Slice)
			if slice.start > limit || slice.count > limit - slice.start {
				return refuse(refusal, .Out_Of_Range, .Region, argument, slice.start + min(slice.count, limit), limit)
			}
			region_range_add(&ranges, {slice.start, slice.start + slice.count, false, argument}, refusal) or_return
			call.slices[index] = {
				start = u64(uintptr(raw_data(region))) + slice.start,
				count = slice.count,
			}
			call.arguments[index] = u64(uintptr(&call.slices[index]))
		case .Record:
			described_record, valid := module.record_type(file, function.parameter_details[index])
			if !valid {
				return refuse(refusal, .Bad_Value, .Region, argument, u64(function.parameter_details[index]), 0)
			}
			start := load(record[:], field, u64)
			if start > limit || u64(described_record.size) > limit - start {
				return refuse(refusal, .Out_Of_Range, .Region, argument, start + min(u64(described_record.size), limit), limit)
			}
			call.records[index] = {}
			intrinsics.mem_copy_non_overlapping(&call.records[index], raw_data(region[start:]), int(described_record.size))
			for number in 0 ..< described_record.field_count {
				item, has_field := module.field(file, described_record, number)
				if has_field && item.type == u8(module.Type.Handle) {
					handle := (^u32)(uintptr(&call.records[index]) + uintptr(item.offset))^
					if !lent_handle_add(call, u64(handle), item.detail) {
						return refuse(refusal, .Too_Long, .Lent_Handles, argument, 0, len(call.lent))
					}
				}
			}
			call.arguments[index] = u64(uintptr(&call.records[index]))
		case .Handle:
			call.arguments[index] = load(record[:], field, u64)
			if !lent_handle_add(call, call.arguments[index], function.parameter_details[index]) {
				return refuse(refusal, call.arguments[index] >> 32 != 0 ? .Handle_Absent : .Too_Long, .Lent_Handles, argument, call.arguments[index], len(call.lent))
			}
		case .Table, .Bytes:
			direction, direction_ok := module.direction_of_word(function.parameter_directions[index])
			if !direction_ok {
				return refuse(refusal, .Bad_Value, .Region, argument, u64(function.parameter_directions[index]), u64(max(module.Direction)))
			}
			table_decode(file, word, function.parameter_details[index], direction, index, load(record[:], field, Table_Field), offset + field, region, call, &ranges, refusal) or_return
		}
		field += field_size(word)
	}
	index := function.parameter_count
	result_type, result_type_ok := module.function_result_type(function)
	if !result_type_ok {
		return refuse(refusal, .Bad_Value, .Region, 0, u64(function.result), 0)
	}
	switch result_type {
	case .None, .Integer, .Enum:
		// No buffer: the result is in the completion.
	case .Handle, .Bytes:
		// record_size refused these results.
	case .Text:
		slice := load(record[:], field, Slice)
		if slice.start > limit || slice.count > limit - slice.start {
			return refuse(refusal, .Out_Of_Range, .Region, 0, slice.start + min(slice.count, limit), limit)
		}
		region_range_add(&ranges, {slice.start, slice.start + slice.count, true, 0}, refusal) or_return
		call.slices[index] = {
			start = u64(uintptr(raw_data(region))) + slice.start,
			count = slice.count,
		}
		call.arguments[index] = u64(uintptr(&call.slices[index]))
	case .Table:
		described_record, valid := module.record_type(file, function.result_detail)
		slice := load(record[:], field, Slice)
		if !valid || described_record.size == 0 {
			return refuse(refusal, .Bad_Value, .Region, 0, u64(function.result_detail), 0)
		}
		if slice.start > limit || slice.count > (limit - slice.start) / u64(described_record.size) {
			return refuse(refusal, .Out_Of_Range, .Region, 0, bytes_reached(slice.start, slice.count, u64(described_record.size)), limit)
		}
		region_range_add(&ranges, {slice.start, slice.start + slice.count * u64(described_record.size), true, 0}, refusal) or_return
		call.slices[index] = {
			start = u64(uintptr(raw_data(region))) + slice.start,
			count = slice.count,
		}
		call.arguments[index] = u64(uintptr(&call.slices[index]))
	case .Record:
		described_record, valid := module.record_type(file, function.result_detail)
		if !valid {
			return refuse(refusal, .Bad_Value, .Region, 0, u64(function.result_detail), 0)
		}
		start := load(record[:], field, u64)
		if start > limit || u64(described_record.size) > limit - start {
			return refuse(refusal, .Out_Of_Range, .Region, 0, start + min(u64(described_record.size), limit), limit)
		}
		region_range_add(&ranges, {start, start + u64(described_record.size), true, 0}, refusal) or_return
		call.records[index] = {}
		call.result = {start = start, count = u64(described_record.size)}
		call.arguments[index] = u64(uintptr(&call.records[index]))
	}
	// The error record: private to the receiver, so the caller chooses no
	// place of it and reads no record from the call region. The export
	// writes it only when it fails.
	call.error_record = {}
	if function.error_record != 0 {
		error_argument := u64(function.parameter_count) + u64(result_type == .Text || result_type == .Table || result_type == .Record)
		call.arguments[error_argument] = u64(uintptr(&call.error_record))
	}
	return true
}

// lent_handle_add adds a handle of the argument record to the handles
// that the receiver proves before the call and closes after it.
@(private)
lent_handle_add :: proc "contextless" (call: ^Call, handle: u64, rights: u32) -> bool {
	if handle == 0 {
		return true
	}
	if handle >> 32 != 0 || call.lent_count == len(call.lent) {
		return false
	}
	call.lent[call.lent_count] = {u32(handle), rights}
	call.lent_count += 1
	return true
}

// completion_value gives the value of the completion of a call from the
// result register of its export. An Integer and an Enum are the value
// itself: the caller reads the low bytes of an Enum by its description. A
// Text and a Table give their count, whose bytes are in the call region.
// No result, and a Record result, whose bytes are in the call region, give
// 0; so does a byte that names no type, which record_size refused before.
// export_answer reads the two integer result registers of an export
// (src/md/api/call_outcome.md, "Where the outcome is"): an export that can
// fail (function.error_record != 0) gives the outcome word first and its
// value second; another gives its value alone. The value of an outcome
// that is not Succeeded is 0: the bytes of the completion are then the
// same at each run, and no word of the export passes by accident.
export_answer :: proc "contextless" (function: module.Function, registers: [2]u64) -> (value: u64, outcome_word: u64) {
	if function.error_record == 0 {
		return completion_value(function, registers[0]), 0
	}
	if registers[0] != 0 {
		return 0, registers[0]
	}
	return completion_value(function, registers[1]), 0
}

// answer_completion gives the completion of a call that the export
// answered: the outcome word in `kind`; with Succeeded, the value in
// values[0]; with another outcome, the error record of the export in the
// seven values, its `operation` the export, and no value. outcome_word is
// the word that the export gave: the receiver passes it on unread, and the
// reader takes it through its border.
answer_completion :: proc "contextless" (tag: u32, export: u32, value: u64, outcome_word: u64, record: errors.Error_Record) -> ring.Record {
	if outcome_word == 0 {
		return {kind = 0, tag = tag, values = {0 = value}}
	}
	named := record
	// A failure with no record still says that it failed: Refused explains
	// each outcome (call_outcome.KINDS_OF).
	if named.kind == 0 {
		named = errors.error_make(.Refused)
	}
	named.operation = i64(export)
	// A word past 32 bits names no outcome: the kind keeps it unreadable.
	kind := outcome_word > u64(max(u32)) ? max(u32) : u32(outcome_word)
	return {kind = kind, tag = tag, values = errors.completion_values(named)}
}

// refusal_completion gives the completion of a call that the receiver
// refused before the export ran: Argument_Refused for a call record that it
// refuses, Operation_Unsupported for an export that it does not have.
refusal_completion :: proc "contextless" (tag: u32, outcome: call_outcome.Call_Outcome, record: errors.Error_Record) -> ring.Record {
	return {kind = u32(outcome), tag = tag, values = errors.completion_values(record)}
}

// answer_of_completion is the one border of the completion of an isolated
// call, which the other process writes: the value and the outcome, and the
// error record of a failure. A kind that names no outcome, and a failure
// whose record names no kind or no unit, give Answer_Unreadable with a
// record that says what was unreadable, and the value 0: the reader trusts
// nothing of such an answer.
answer_of_completion :: proc "contextless" (completion: ring.Record) -> (value: i64, outcome: call_outcome.Call_Outcome, record: errors.Error_Record) {
	outcome, record = call_outcome.completion_outcome(completion.kind, completion.values)
	if outcome == .Succeeded {
		return i64(completion.values[0]), .Succeeded, {}
	}
	return 0, outcome, record
}

completion_value :: proc "contextless" (function: module.Function, register: u64) -> u64 {
	type, type_ok := module.type_of_word(function.result)
	if !type_ok {
		return 0
	}
	switch type {
	case .Integer, .Enum, .Text, .Table:
		return register
	case .None, .Record, .Handle, .Bytes:
	}
	return 0
}

// result_store copies the Record result of a call to its place in the call
// region. Call it after the export returned.
result_store :: proc "contextless" (function: module.Function, call: ^Call, region: []u8) {
	if function.result == u8(module.Type.Record) {
		intrinsics.mem_copy_non_overlapping(raw_data(region[call.result.start:]), &call.records[function.parameter_count], int(call.result.count))
	}
}
