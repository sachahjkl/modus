// The disk grant tables of the principals in the store module_files of each
// principal (src/md/api/root_service_split.md, "State").
//
// This service holds the key of the tag of each table, which the core
// passes on from unlock and does not keep. For each call the core makes a
// connection to the store of the principal and gives its handles through
// the ring; this service calls the storage service, adds the tag to a table
// to write, and checks the tag of a table that it reads. The core decides
// each grant: it checks again each table that this service read, with the
// decoder of the disk.
package principals_service

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/storage_status"
import "modus:disk_process"
import "modus:principals"
import "modus:storage"
import "modus:system"

#assert(rd.TABLE_BYTES == disk_process.TABLE_SIZE)

// The key of the tag of the table of each principal, in this run of the
// service. A service that starts again holds none until the core gives it
// again.
Table_Key :: struct {
	held: bool,
	key:  [disk_process.KEY_SIZE]u8,
}

table_keys: [principals.PRINCIPAL_CAPACITY]Table_Key

// The boot image, read-only: the file of the storage service.
image: []u8

// The input of the call, copied once out of the transfer region, and the
// bytes of a table that a write sends.
copied_table_input: rd.Table_Call_Input
table_bytes: [disk_process.TABLE_SIZE]u8

// The answer of a table command: its status and its values.
Table_Answer :: struct {
	status: rd.Principals_Ring_Status,
	values: [7]u64,
}

// table_answer_failure is the answer of a call that did not end.
@(private = "file")
table_answer_failure :: proc "contextless" (failure: rd.Table_Call_Failure) -> Table_Answer {
	return {status = .Refused, values = {0 = u64(failure)}}
}

// table_key_take keeps the key of a table that the core gave in the values
// of its command, then erases the slot of the ring and the copy of the
// record: the key stays in this service only.
table_key_take :: proc "contextless" (command: ^ring.Record) -> Table_Answer {
	defer {
		ring_slot_erase(&service_ring.commands)
		for &value in command.values {
			intrinsics.volatile_store(&value, 0)
		}
	}
	principal, key, failure := rd.table_key_check(command.values, principals.PRINCIPAL_CAPACITY)
	defer for &item in key {
		intrinsics.volatile_store(&item, 0)
	}
	if failure != .None {
		return table_answer_failure(failure)
	}
	table_keys[principal] = {held = true, key = key}
	return {status = .Ok, values = {0 = principal}}
}

// ring_slot_erase writes 0 over the values of the record of the command
// ring that this service read last. The mask is the private mask of this
// service, so a false counter of the core names a slot of the ring and
// nothing else.
@(private = "file")
ring_slot_erase :: proc "contextless" (queue: ^ring.Queue) {
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	slot := &queue.records[(read - 1) & queue.mask]
	for &value in slot.values {
		intrinsics.volatile_store(&value, 0)
	}
}

// handle_proof says if a word names a handle that came through the ring of
// the core, of a kind and with rights.
@(private = "file")
handle_proof :: proc "contextless" (word: u64, kind: op.Object_Kind, needed: system.Rights) -> bool {
	found_kind, rights, through := system.handle_state(system.Handle(word), service_ring_memory)
	return through && found_kind == kind && needed <= rights
}

// table_handles_close closes the handles of a call that came through the
// ring and that no client holds.
@(private = "file")
table_handles_close :: proc "contextless" (values: [7]u64) {
	for index in 0 ..< 3 {
		kind := index == 0 ? op.Object_Kind.Process : op.Object_Kind.Memory
		if handle_proof(values[index], kind, {}) {
			system.close(system.Handle(values[index]))
		}
	}
}

// table_client_end gives back what a call held: the mappings and the
// handles of the connection.
@(private = "file")
table_client_end :: proc "contextless" (client: ^storage.Client, service: system.Handle) {
	if client.calls.head != nil {
		system.ring_close(&client.calls)
	}
	if client.region != nil {
		system.memory_unmap(raw_data(client.region))
	}
	for handle in ([3]system.Handle{client.ring_memory, client.region_memory, service}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	client^ = {}
}

// table_call runs a Table_Read or a Table_Write: the border of its handles
// and its input, the call of the storage service within the deadline of a
// load, then the answer. The call ring of the storage service is the one
// wait of this service while the call runs.
table_call :: proc "contextless" (command: ring.Record, write: bool) -> Table_Answer {
	valid := handle_proof(command.values[0], .Process, {.Read}) && handle_proof(command.values[1], .Memory, {.Read, .Write}) && handle_proof(command.values[2], .Memory, {.Read, .Write})
	offset := command.values[3]
	if !valid || command.values[4] != 0 || command.values[5] != 0 || command.values[6] != 0 || !region_range_valid(offset, size_of(rd.Table_Call_Input)) {
		table_handles_close(command.values)
		return table_answer_failure(.Bad_Input)
	}
	intrinsics.mem_copy_non_overlapping(&copied_table_input, &service_region_base[offset], size_of(rd.Table_Call_Input))
	if failure := rd.table_call_input_check(&copied_table_input, principals.PRINCIPAL_CAPACITY); failure != .None {
		table_handles_close(command.values)
		return table_answer_failure(failure)
	}
	principal := copied_table_input.principal
	if !table_keys[principal].held {
		table_handles_close(command.values)
		return table_answer_failure(.No_Key)
	}
	storage_module := string(copied_table_input.storage_module[:copied_table_input.storage_module_length])
	file := system.image_find(image, storage_module)
	service := system.Handle(command.values[0])
	client: storage.Client
	opened := false
	if module.validate(file) == .None {
		client, opened = storage.open_handles(system.Handle(command.values[1]), system.Handle(command.values[2]), service, file)
	}
	if !opened {
		table_handles_close(command.values)
		return table_answer_failure(.Not_Mapped)
	}
	defer table_client_end(&client, service)

	arguments: [3]isolated.Argument
	arguments[0].integer = u64(storage.ROOT)
	// The name is a constant: its bytes stay after this procedure returns.
	object_name := disk_process.TABLE_OBJECT_NAME
	arguments[1].text = transmute([]u8)object_name
	argument_count := 2
	export := "read"
	if write {
		table_bytes = copied_table_input.table
		disk_process.table_tag_put(&table_keys[principal].key, &table_bytes)
		arguments[2].text = table_bytes[:]
		argument_count = 3
		export = "write"
	}
	sent, send_status := storage.call_send(&client, export, arguments[:argument_count])
	if send_status != .Ok {
		return table_answer_failure(.Call_Not_Taken)
	}
	limit := system.time() + disk_process.LOAD_DEADLINE_MILLISECONDS
	for {
		error: errors.Error_Record
		value, text, status, answered := storage.call_answer(&client, &sent, arguments[:argument_count], &error)
		if answered {
			return table_answer_of(principal, write, value, text, status, &error, offset)
		}
		if !storage.connected(&client) {
			return table_answer_failure(.Storage_Stopped)
		}
		if system.time() >= limit {
			return table_answer_failure(.No_Answer)
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &client.calls.completions)
		system.wait_end(&wait, limit)
	}
}

// table_answer_of gives the answer of a call that the storage service
// answered. A read writes the table that verified in the place of its input.
@(private = "file")
table_answer_of :: proc "contextless" (principal: u64, write: bool, value: i64, text: []u8, status: storage_status.Status, error: ^errors.Error_Record, offset: u64) -> Table_Answer {
	if write {
		if status != .Ok {
			return {status = .Storage_Refused, values = transmute([7]u64)error^}
		}
		return {status = .Ok}
	}
	if storage.export_failed_with(status, value, .Absent) {
		return {status = .Ok, values = {0 = u64(rd.Table_Read_Outcome.Absent)}}
	}
	if status != .Ok {
		return {status = .Storage_Refused, values = transmute([7]u64)error^}
	}
	// The bytes are copied once out of the call region, which the storage
	// service can write at any time: the tag is verified on that copy, and
	// only that copy goes to the place of the core.
	_, problem := disk_process.table_decode_kept(text, &table_keys[principal].key, &table_bytes)
	if problem == .None {
		place := &service_region_base[offset + u64(offset_of(rd.Table_Call_Input, table))]
		intrinsics.mem_copy_non_overlapping(place, &table_bytes, disk_process.TABLE_SIZE)
	}
	return {status = .Ok, values = {0 = u64(rd.Table_Read_Outcome.Decoded), 1 = u64(problem)}}
}
