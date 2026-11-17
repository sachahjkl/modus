package modustool

import "core:mem"
import "core:slice"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/remote"

// The fuzz targets of the remote protocol (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the remote service reads a call
// request from a client that the handshake admitted, the host reads the
// answer, the root service and the remote service share the client table,
// and a receiver reads each call region with `isolated.decode`.

// fuzz_error_record_named says if a record of a refusal names a kind and a
// unit of the contract of the errors, as each reader of a record needs.
fuzz_error_record_named :: proc(record: errors.Error_Record) -> bool {
	_, kind_known := errors.kind_of_word(record.kind)
	_, unit_known := errors.unit_of_word(record.unit)
	return kind_known && unit_known && record.kind != 0
}

// ---------------------------------------------------------------------
// The call request.

// The call region of the remote service, where it copies the arguments of
// a request: details_bytes reads the error details there.
@(private = "file")
fuzz_remote_region: [remote.REGION_SIZE]u8

// fuzz_remote_request_execute: a request that request_check accepts keeps
// each place in the call region and writes again to its own bytes; a
// refusal names a field of the request and changes no byte.
fuzz_remote_request_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	request, arguments, error, ok := remote.request_check(input, remote.REGION_SIZE)
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "request_check changed the bytes of the request")
	}
	if !ok {
		if !fuzz_error_record_named(error) || error.argument < 0 || error.argument > i64(len(remote.REQUEST_FIELD_NAMES)) {
			return fuzz_broken(.Contract, "a refusal of request_check names no kind, no unit or no field: %v", error)
		}
		return FUZZ_PASSED
	}
	region_size := u64(remote.REGION_SIZE)
	switch {
	case request.kind != .Call:
		return fuzz_broken(.Contract, "request_check accepts the kind %d", u32(request.kind))
	case u64(len(arguments)) != u64(request.arguments) || len(input) != remote.REQUEST_SIZE + len(arguments):
		return fuzz_broken(.Contract, "the arguments are %d bytes, the request names %d", len(arguments), request.arguments)
	case len(arguments) > 0 && raw_data(arguments) != &input[remote.REQUEST_SIZE]:
		return fuzz_broken(.Contract, "the arguments are not the bytes after the header")
	case request.record_size > request.arguments:
		return fuzz_broken(.Contract, "the argument record passes the arguments")
	case u64(request.result_start) + u64(request.result_count) > region_size:
		return fuzz_broken(.Contract, "the place of the result passes the call region")
	case request.error_start != 0 && (request.error_start % 8 != 0 || u64(request.error_start) + isolated.ERROR_RECORD_SIZE > region_size):
		return fuzz_broken(.Contract, "the place of the error record is %d", request.error_start)
	case request.details_end != 0 && request.details_end > request.record_size:
		return fuzz_broken(.Contract, "the table of the error details ends past the argument record")
	}
	values := [?]i64{min(i64), -1, 0, 1, i64(request.result_count), i64(request.result_count) + 1, max(i64)}
	for value in values {
		count := remote.result_bytes(request, value)
		if count > u64(request.result_count) || request.result_unit != 0 && count % u64(request.result_unit) != 0 {
			return fuzz_broken(.Contract, "result_bytes gives %d bytes for the value %d", count, value)
		}
	}
	// The details come from the call region after the call: the service
	// wrote it, so its words are the words of the request here.
	mem.zero_slice(fuzz_remote_region[:])
	copy(fuzz_remote_region[:], arguments)
	details, _ := remote.details_bytes(request, fuzz_remote_region[:])
	if len(details) % isolated.ERROR_RECORD_SIZE != 0 {
		return fuzz_broken(.Contract, "details_bytes gives %d bytes, not whole records", len(details))
	}
	if len(details) > 0 {
		low, high := uintptr(&fuzz_remote_region[0]), uintptr(&fuzz_remote_region[0]) + len(fuzz_remote_region)
		start := uintptr(raw_data(details))
		if start < low || start + uintptr(len(details)) > high {
			return fuzz_broken(.Contract, "details_bytes gives bytes outside the call region")
		}
	}
	out := make([]u8, remote.REQUEST_LIMIT, context.temp_allocator)
	written, write_ok := remote.request_write(out, request, arguments)
	if !write_ok || !slice.equal(written, input) {
		return fuzz_broken(.Round_Trip, "request_write of a request that request_check accepted gives other bytes")
	}
	return FUZZ_PASSED
}

// fuzz_remote_request_seeds gives a request of each form that the host
// sends, and one with each place at the edge of the call region.
fuzz_remote_request_seeds :: proc(seeds: ^[dynamic][]u8) {
	Seed :: struct {
		request:   remote.Request,
		arguments: int,
	}
	error_last := u32(remote.REGION_SIZE - isolated.ERROR_RECORD_SIZE)
	list := [?]Seed {
		{request = {kind = .Call}, arguments = 0},
		{request = {kind = .Call, export = 3, record_size = 16, result_start = 16, result_count = 64, result_unit = 1}, arguments = 16},
		{request = {kind = .Call, export = 1, record_size = 40, result_start = 64, result_count = 96, result_unit = 24, error_start = 160, details_end = 40}, arguments = 64},
		{request = {kind = .Call, record_size = 8, result_start = remote.REGION_SIZE, error_start = error_last}, arguments = 8},
		{request = {kind = .None}, arguments = 0},
	}
	for item in list {
		request := item.request
		_ = remote.name_set(&request.service, "terminal")
		arguments := make([]u8, item.arguments)
		for &value, index in arguments {
			value = u8(index)
		}
		out := make([]u8, remote.REQUEST_SIZE + item.arguments)
		written, _ := remote.request_write(out, request, arguments)
		append(seeds, written)
	}
	// One byte short of a header, and an empty request.
	append(seeds, make([]u8, remote.REQUEST_SIZE - 1), make([]u8, 0))
}

// ---------------------------------------------------------------------
// The call answer.

// fuzz_remote_answer_execute: an answer that answer_check accepts names a
// status, carries its total, shows no more details than it holds, and
// writes again to its own bytes.
fuzz_remote_answer_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	header, result, ok := remote.answer_check(input)
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "answer_check changed the bytes of the answer")
	}
	if !ok {
		return FUZZ_PASSED
	}
	if _, known := enum_word.member_of_word(remote.Status, u64(header.status)); !known {
		return fuzz_broken(.Contract, "answer_check accepts the status %d, which names no status", u32(header.status))
	}
	if u64(len(result)) != u64(header.total) || len(input) != remote.ANSWER_SIZE + len(result) {
		return fuzz_broken(.Contract, "the result is %d bytes, the answer names %d", len(result), header.total)
	}
	shown, sound := remote.details_shown(header, u64(len(result)))
	if shown > u64(header.details) || shown * isolated.ERROR_RECORD_SIZE > u64(len(result)) {
		return fuzz_broken(.Contract, "details_shown shows %d records of %d bytes", shown, len(result))
	}
	if sound && u64(len(result)) % isolated.ERROR_RECORD_SIZE != 0 {
		return fuzz_broken(.Contract, "details_shown says that %d bytes are whole records", len(result))
	}
	out := make([]u8, remote.ANSWER_LIMIT, context.temp_allocator)
	written, write_ok := remote.answer_write(out, header, result)
	if !write_ok || !slice.equal(written, input) {
		return fuzz_broken(.Round_Trip, "answer_write of an answer that answer_check accepted gives other bytes")
	}
	return FUZZ_PASSED
}

fuzz_remote_answer_seeds :: proc(seeds: ^[dynamic][]u8) {
	results := [?]int{0, 5, isolated.ERROR_RECORD_SIZE, 2 * isolated.ERROR_RECORD_SIZE}
	for count, index in results {
		header := remote.Answer {
			status  = index == 0 ? remote.Status.Refused : remote.Status.Ok,
			value   = index == 3 ? -1 : i64(count),
			details = index == 3 ? 2 : 0,
		}
		if index == 0 {
			header.error = errors.error_make(.Bad_Value, .None, remote.FIELD_KIND, 0, 1)
		}
		result := make([]u8, count)
		out := make([]u8, remote.ANSWER_SIZE + count)
		written, _ := remote.answer_write(out, header, result)
		append(seeds, written)
	}
	// A status that names no member.
	header := remote.Answer{}
	out := make([]u8, remote.ANSWER_SIZE)
	written, _ := remote.answer_write(out, header, nil)
	fuzz_word_write(written, int(offset_of(remote.Answer, status)), 4, u64(max(remote.Status)) + 1, false)
	append(seeds, written)
}

// ---------------------------------------------------------------------
// The client table.

// The input: the bytes of a client table, then a key of 32 bytes and a
// principal of 8 bytes. The version is made even: an odd version is a
// write in progress, which the reader waits for, and the writer of the
// table is the root service, never this input.
fuzz_remote_client_table_execute :: proc(input: []u8) -> Fuzz_Verdict {
	table: remote.Client_Table
	key: [32]u8
	principal: u64
	rest := input
	rest = rest[copy(mem.ptr_to_bytes(&table), rest):]
	rest = rest[copy(key[:], rest):]
	copy(mem.ptr_to_bytes(&principal), rest)
	table.version &~= 1
	clients: [remote.CLIENT_CAPACITY]remote.Client
	remote.client_table_read(&table, &clients)
	if clients != table.clients {
		return fuzz_broken(.Two_Readers, "client_table_read gives other clients than the table holds")
	}
	// The writer: each client written again, then a place that names no
	// row, which changes nothing.
	written: remote.Client_Table
	for client, place in clients {
		remote.client_table_write(&written, place, client)
	}
	version := written.version
	remote.client_table_write(&written, -1, {serial = 1})
	remote.client_table_write(&written, remote.CLIENT_CAPACITY, {serial = 1})
	if written.version != version || version != 2 * remote.CLIENT_CAPACITY {
		return fuzz_broken(.Contract, "a write of a place that names no row changed the table, or the version is %d", written.version)
	}
	again: [remote.CLIENT_CAPACITY]remote.Client
	remote.client_table_read(&written, &again)
	if again != clients {
		return fuzz_broken(.Round_Trip, "the clients written and read again differ")
	}
	keys := make([dynamic][32]u8, context.temp_allocator)
	append(&keys, key, [32]u8{})
	for client in clients {
		append(&keys, client.key)
	}
	for item in keys {
		place := remote.client_find(&clients, item)
		switch {
		case place < -1 || place >= remote.CLIENT_CAPACITY:
			return fuzz_broken(.Contract, "client_find gives the place %d", place)
		case place >= 0 && (clients[place].serial == 0 || clients[place].key != item || item == ([32]u8{})):
			return fuzz_broken(.Contract, "client_find gives a row that does not hold the key")
		case place == -1:
			for client in clients {
				if item != ([32]u8{}) && client.serial != 0 && client.key == item {
					return fuzz_broken(.Contract, "client_find misses a row that holds the key")
				}
			}
		}
		action, at := remote.client_restore_decision(&clients, item, principal)
		switch action {
		case .Holds:
			if at != place || clients[at].principal != principal {
				return fuzz_broken(.Contract, "Holds names a row of another principal")
			}
		case .Contest, .Contested:
			if at != place || clients[at].principal == principal || (clients[at].contested == 0) != (action == .Contest) {
				return fuzz_broken(.Contract, "%v names the wrong row", action)
			}
		case .Take_Row:
			if place != -1 || at < 0 || at >= remote.CLIENT_CAPACITY || clients[at].serial != 0 {
				return fuzz_broken(.Contract, "Take_Row names a row that is not free")
			}
		case .No_Free_Row:
			for client in clients {
				if client.serial == 0 && place == -1 {
					return fuzz_broken(.Contract, "No_Free_Row with a free row")
				}
			}
		}
	}
	for client, place in clients {
		holds := remote.client_grant_holds(&clients, place, client.serial)
		if holds != (client.serial != 0 && client.session_locked == 0 && client.contested == 0) {
			return fuzz_broken(.Contract, "client_grant_holds of the row %d is %v", place, holds)
		}
	}
	if remote.client_grant_holds(&clients, -1, 1) || remote.client_grant_holds(&clients, remote.CLIENT_CAPACITY, 1) {
		return fuzz_broken(.Contract, "client_grant_holds holds for a place that names no row")
	}
	return FUZZ_PASSED
}

fuzz_remote_client_table_seeds :: proc(seeds: ^[dynamic][]u8) {
	table: remote.Client_Table
	for place in 0 ..< remote.CLIENT_CAPACITY / 2 {
		client := remote.Client{principal = u64(place % 2), serial = u64(place + 1), session_locked = u64(place == 2 ? 1 : 0), contested = u64(place == 3 ? 1 : 0)}
		client.key[0], client.key[31] = u8(place + 1), 0x5A
		table.clients[place] = client
	}
	seed := make([]u8, size_of(remote.Client_Table) + 32 + 8)
	copy(seed, mem.ptr_to_bytes(&table))
	// The key of the row 1, for the principal 0.
	copy(seed[size_of(remote.Client_Table):], table.clients[1].key[:])
	append(seeds, seed)
	full: remote.Client_Table
	for &client, place in full.clients {
		client = {serial = max(u64) - u64(place), principal = max(u64)}
		client.key[0] = u8(place + 1)
	}
	append(seeds, slice.clone(mem.ptr_to_bytes(&full)))
}

// ---------------------------------------------------------------------
// The reader of a call region.

// The module of the descriptions of the target: record 1 is {handle at 0,
// integer at 8}, 16 bytes; record 2 is {name: Text of 16 bytes at 0,
// integer at 16}, 24 bytes. A Record or Table parameter names one of them.
@(private = "file")
fuzz_call_module: [512]u8
@(private = "file")
fuzz_call_module_size: int

fuzz_isolated_call_start :: proc() -> bool {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	file := fuzz_call_module[:]
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [3]module.Record{1 = {size = 16, first_field = 1, field_count = 2}, 2 = {size = 24, first_field = 3, field_count = 2}}
	fields := [5]module.Field {
		1 = {offset = 0, type = .Handle, detail = 6},
		2 = {offset = 8, type = .Integer},
		3 = {offset = 0, type = .Text, detail = 16},
		4 = {offset = 16, type = .Integer},
	}
	directory[module.Table_Kind.Records] = {offset = offset, count = len(records), record_size = size_of(module.Record)}
	copy(file[offset:], mem.ptr_to_bytes(&records))
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = len(fields), record_size = size_of(module.Field)}
	copy(file[offset:], mem.ptr_to_bytes(&fields))
	offset += size_of(fields)
	header := module.Header{magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	copy(file, mem.ptr_to_bytes(&header))
	copy(file[size_of(module.Header):], mem.ptr_to_bytes(&directory))
	fuzz_call_module_size = int(offset)
	return true
}

// The bytes of the description at the start of an input, then the place
// of the argument record, then the call region.
FUZZ_CALL_DESCRIPTION_SIZE :: 2 + 2 * module.PARAMETER_CAPACITY + 4 * module.PARAMETER_CAPACITY + 8 + 1 + 2
// The most bytes of the call region of one input: the call region of a
// connection, so a place at its end is in reach.
FUZZ_CALL_REGION_LIMIT :: 4 << 10

// fuzz_call_function reads a description from the choices: types and
// directions that the module format names, as module.validate gives them
// to the receiver; the counts and the details are any word.
fuzz_call_function :: proc(choices: ^Fuzz_Choices) -> (function: module.Function) {
	type_count := int(max(module.Type)) + 1
	direction_count := int(max(module.Direction)) + 1
	function.parameter_count = u8(fuzz_choice_below(choices, module.PARAMETER_CAPACITY + 2))
	function.result = module.Type(fuzz_choice_below(choices, type_count))
	for &type in function.parameters {
		type = module.Type(fuzz_choice_below(choices, type_count))
	}
	for &direction in function.parameter_directions {
		direction = module.Direction(fuzz_choice_below(choices, direction_count))
	}
	for &detail in function.parameter_details {
		detail = u32(fuzz_choice_word(choices, 4))
	}
	function.result_detail = u32(fuzz_choice_word(choices, 4))
	function.error_record = u32(fuzz_choice_word(choices, 4))
	return function
}

// fuzz_isolated_call_execute: decode of a description and a call region
// gives only slices inside the call region, keeps its counts in their
// arrays, and a refusal names a kind of the errors.
fuzz_isolated_call_execute :: proc(input: []u8) -> Fuzz_Verdict {
	choices := fuzz_choices_of(input[:min(len(input), FUZZ_CALL_DESCRIPTION_SIZE)])
	function := fuzz_call_function(&choices)
	size, described := isolated.record_size(function)
	// Mostly the size of the description, at times any size.
	if fuzz_choice_rare(&choices, 8) {
		size = u64(fuzz_choice_word(&choices, 2))
	}
	offset := u64(fuzz_choice_word(&choices, 2))
	region := make([]u8, clamp(len(input) - FUZZ_CALL_DESCRIPTION_SIZE, 0, FUZZ_CALL_REGION_LIMIT), context.temp_allocator)
	if len(input) > FUZZ_CALL_DESCRIPTION_SIZE {
		copy(region, input[FUZZ_CALL_DESCRIPTION_SIZE:])
	}
	call := new(isolated.Call, context.temp_allocator)
	refusal: errors.Error_Record
	file := fuzz_call_module[:fuzz_call_module_size]
	if !isolated.decode(file, function, offset, size, region, call, &refusal) {
		if !fuzz_error_record_named(refusal) {
			return fuzz_broken(.Contract, "a refusal of decode names no kind or no unit: %v", refusal)
		}
		return FUZZ_PASSED
	}
	if !described {
		return fuzz_broken(.Contract, "decode accepts a description that record_size refuses")
	}
	if call.lent_count < 0 || call.lent_count > module.HANDLE_CAPACITY || call.mapping_count < 0 || call.mapping_count > module.PARAMETER_CAPACITY {
		return fuzz_broken(.Contract, "decode gives %d lent handles and %d mappings", call.lent_count, call.mapping_count)
	}
	low := u64(uintptr(raw_data(region)))
	high := low + u64(len(region))
	types := function.parameters
	count := int(function.parameter_count)
	if count > module.PARAMETER_CAPACITY {
		return fuzz_broken(.Contract, "decode accepts %d parameters", count)
	}
	if function.result == .Text && count < module.PARAMETER_CAPACITY {
		// The buffer of a Text result is one more slice.
		types[count] = .Text
		count += 1
	}
	for type, index in types[:count] {
		if type != .Text {
			continue
		}
		item := call.slices[index]
		if call.arguments[index] != u64(uintptr(&call.slices[index])) {
			return fuzz_broken(.Contract, "the argument %d of a Text is not the address of its slice", index)
		}
		if item.count > 0 && (item.start < low || item.start > high || item.count > high - item.start) {
			return fuzz_broken(.Contract, "the slice of the argument %d is outside the call region", index)
		}
	}
	if function.result == .Record && (call.result.start > u64(len(region)) || call.result.count > u64(len(region)) - call.result.start) {
		return fuzz_broken(.Contract, "the place of the Record result is outside the call region")
	}
	if call.error.count > 0 && (call.error.start > u64(len(region)) || call.error.count > u64(len(region)) - call.error.start) {
		return fuzz_broken(.Contract, "the place of the error record is outside the call region")
	}
	isolated.result_store(function, call, region)
	return FUZZ_PASSED
}

// fuzz_isolated_call_seeds gives a call of each type of parameter, encoded
// by the writer of the caller.
fuzz_isolated_call_seeds :: proc(seeds: ^[dynamic][]u8) {
	_ = fuzz_isolated_call_start()
	// The choices of fuzz_call_function, in its order.
	Seed :: struct {
		types:  []module.Type,
		result: module.Type,
	}
	list := [?]Seed {
		{types = {.Integer, .Text, .Integer}, result = .Integer},
		{types = {.Text}, result = .Text},
		{types = {.Record, .Handle}, result = .Record},
		{types = {}, result = .None},
	}
	for item in list {
		function: module.Function
		function.parameter_count = u8(len(item.types))
		function.result = item.result
		copy(function.parameters[:], item.types)
		for type, index in item.types {
			if type == .Record {
				function.parameter_details[index] = 1
			}
		}
		if item.result == .Record {
			function.result_detail = 2
		}
		arguments := make([]isolated.Argument, len(item.types), context.temp_allocator)
		record := make([]u8, 16, context.temp_allocator)
		for type, index in item.types {
			switch type {
			case .Integer:
				arguments[index].integer = u64(index + 7)
			case .Text:
				arguments[index].text = transmute([]u8)string("the text")
			case .Record:
				arguments[index].record = record
			case .Handle:
				arguments[index].integer = 5
			case .None, .Table, .Bytes:
				// The seeds name no such parameter.
			}
		}
		region := make([]u8, 256)
		offset, _, _, _, encoded := isolated.encode(fuzz_call_module[:fuzz_call_module_size], function, arguments, region)
		if !encoded {
			continue
		}
		seed := make([dynamic]u8)
		append(&seed, u8(len(item.types)), u8(item.result))
		for type in function.parameters {
			append(&seed, u8(type))
		}
		for _ in function.parameter_directions {
			append(&seed, 0)
		}
		for detail in function.parameter_details {
			append(&seed, u8(detail), u8(detail >> 8), u8(detail >> 16), u8(detail >> 24))
		}
		append(&seed, u8(function.result_detail), 0, 0, 0, 0, 0, 0, 0)
		// No rare size, then the offset of the record.
		append(&seed, 0, u8(offset), u8(offset >> 8))
		assert(len(seed) == FUZZ_CALL_DESCRIPTION_SIZE)
		append(&seed, ..region)
		append(seeds, seed[:])
	}
}
