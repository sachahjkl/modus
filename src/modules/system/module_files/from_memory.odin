package module_files

// The module files that a caller gives in memory, and reads back
// (src/md/features/program_loop.md, "Why each part is where it is"): the
// console builds a module with the service recipes and puts it in the store
// module_files with no network, then reads it back to run it. The service
// stays the one writer of the module files of the store.

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:storage"
import "modus:system"

// nickname_check copies a nickname of a call one time, then checks the copy:
// the caller can change its call region during the call. It gives the
// name, in the place of the caller, or the outcome of the refusal with its
// error record. A name that the store keeps for itself exists already: a
// file of that name is never made, and none is read.
nickname_check :: proc "contextless" (nickname: ^string, name_copy: ^[disk_process.NAME_LIMIT]u8, use: disk_process.Nickname_Use, error: ^errors.Error_Record) -> (name: string, outcome: call_outcome.Call_Outcome) {
	nickname_text := nickname^
	name_length := copy(name_copy[:], nickname_text)
	name = string(name_copy[:name_length])
	refusal := disk_process.nickname_refusal(name, len(nickname_text), 1, use)
	if refusal.kind == 0 {
		return name, .Succeeded
	}
	error^ = refusal
	switch refusal.kind {
	case i64(errors.Kind.Exists):
		return "", .Name_Already_Taken
	case i64(errors.Kind.Absent):
		return "", .Nothing_Has_That_Name
	}
	return "", .Argument_Refused
}

// memory_failure gives the outcome of a memory object that the caller lent
// and that the kernel did not map: the argument is wrong, and nothing
// changed.
@(private = "file")
memory_failure :: proc "contextless" (error: ^errors.Error_Record, argument: i64, status: system.Status) -> (call_outcome.Call_Outcome, i64) {
	return call_outcome.fail(error, .Argument_Refused, .Refused, .Kernel_Status, argument, 0, 0, i64(status))
}

// put stores the module file that the caller lends in memory in the store module_files under a nickname.
//
// The service copies the first `size` bytes of the memory object one time, writes them as the object `nickname` of the
// root tree of the store `module_files` of its principal in one commit, then gives the 64 hexadecimal digits of the
// BLAKE3 hash of the bytes. A file of the same nickname is replaced, and the store keeps the one before as a version.
//
// - **nickname**: the name of the entry, 1 to 23 bytes, with no zero byte and no `/`; not `module_files` and not
//   `grant_table`.
// - **module**: a memory object with the bytes, which the caller lends with Read.
// - **size**: the count of the bytes, 1 to 4 MiB, at most the bytes of the memory object.
// - **result**: the 64 hexadecimal digits of the hash.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The result is 64, or a failure with its
// call outcome and an error record:
//
// - `No_Grant` (Grant_Or_Right_Missing): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, argument 1): the nickname; `Exists` (Name_Already_Taken):
//   `module_files` or `grant_table`, which the store keeps.
// - `Out_Of_Range` (Argument_Refused, argument 3): a size of 0, past 4 MiB, or past the memory object; `Refused`
//   (Argument_Refused, argument 2): the memory object does not map.
// - `Refused` (Callee_Unavailable): the service has no store, or the storage service refused the file.
//
// Example: `module_files.put("hello", module, 4096)`.
@(export, link_name = "put")
put :: proc "c" (nickname: ^string, module: system.Lent({.Read}), size: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !caller_allowed() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [disk_process.NAME_LIMIT]u8
	name, name_failure := nickname_check(nickname, &name_copy, .Make, error)
	if name_failure != .Succeeded {
		return name_failure, 0
	}
	pages, size_status := system.memory_size(module.handle)
	if size_status != .Ok {
		pages = 0
	}
	if refusal := disk_process.put_size_refusal(size, pages * system.PAGE_SIZE, 3); refusal.kind != 0 {
		error^ = refusal
		return .Argument_Refused, 0
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	address, map_status := system.memory_map(module.handle, {})
	if map_status != .Ok {
		return memory_failure(error, 2, map_status)
	}
	// One copy: the caller can change its memory object during the call,
	// and the hash names the bytes that the store holds.
	intrinsics.mem_copy_non_overlapping(raw_data(file), address, int(size))
	system.memory_unmap(address)
	count := int(size)
	hash := blake3.hash(file[:count])
	if written, _ := file_write(name, count, error); written != .Succeeded {
		return written, 0
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, hash)
	system.log_fact(.Info, File_Put{size = value_kinds.Size_In_Bytes(count), file_hash = value_kinds.Hash_Field(hash), nickname = value_kinds.module_name_field(name)})
	copy(result^, digits[:])
	return .Succeeded, disk_process.HASH_DIGITS
}

// read gives the bytes of the module file of a nickname of the store module_files in a memory object that the caller lends.
//
// The service reads the object `nickname` of the root tree whole, copies it into the memory object, and gives the
// count of its bytes. The caller computes the hash of the bytes that it received: the hash of an entry of the store is
// no proof of its bytes.
//
// - **nickname**: as for `put`.
// - **module**: a memory object that the caller lends with Read and Write.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The result is the count of the bytes, or
// a failure with its call outcome and an error record:
//
// - `No_Grant` (Grant_Or_Right_Missing): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, argument 1): the nickname; `Absent` (Nothing_Has_That_Name):
//   `module_files` or `grant_table`, which no module file has, or no object of the nickname.
// - `Out_Of_Range` (Argument_Refused, argument 1): the object of the nickname is larger than a module file.
// - `Too_Small` (Argument_Refused, argument 2): the memory object holds fewer bytes than the file; `Refused`
//   (Argument_Refused, argument 2): it does not map.
// - `Refused` (Callee_Unavailable): the service has no store, or the storage service refused the read.
//
// Example: `module_files.read("hello", module)`.
@(export, link_name = "read")
read :: proc "c" (nickname: ^string, module: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !caller_allowed() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [disk_process.NAME_LIMIT]u8
	name, name_failure := nickname_check(nickname, &name_copy, .Read, error)
	if name_failure != .Succeeded {
		return name_failure, 0
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	store_error: errors.Error_Record
	object_size, size_status := storage.size(&store_client, storage.ROOT, name, &store_error)
	absent := size_status == .Failed && store_error.kind == i64(errors.Kind.Absent)
	if size_status != .Ok && !absent {
		return store_failure(error, &store_error, size_status, .File, name)
	}
	if refusal := disk_process.stored_file_refusal(object_size, absent, 1); refusal.kind != 0 {
		error^ = refusal
		return absent ? .Nothing_Has_That_Name : .Argument_Refused, 0
	}
	count := int(object_size)
	received := 0
	for received < count {
		bytes, status := storage.read_range(&store_client, storage.ROOT, name, u64(received), file[received:count], &store_error)
		// An answer with no byte before the end would come again for ever.
		if status != .Ok || len(bytes) == 0 {
			return store_failure(error, &store_error, status == .Ok ? .Refused : status, .File, name)
		}
		received += len(bytes)
	}
	pages, pages_status := system.memory_size(module.handle)
	if pages_status != .Ok {
		pages = 0
	}
	if refusal := disk_process.read_room_refusal(i64(count), pages * system.PAGE_SIZE, 2); refusal.kind != 0 {
		error^ = refusal
		return .Argument_Refused, 0
	}
	address, map_status := system.memory_map(module.handle, {.Write})
	if map_status != .Ok {
		return memory_failure(error, 2, map_status)
	}
	intrinsics.mem_copy_non_overlapping(address, raw_data(file), count)
	system.memory_unmap(address)
	return .Succeeded, i64(count)
}

// file_write writes the first count bytes of file as the object name, in
// pieces, sets its size and commits it: one commit for the whole file.
@(private = "file")
file_write :: proc "contextless" (name: string, count: int, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	store_error: errors.Error_Record
	for piece_start := 0; piece_start < count; piece_start += WRITE_PIECE {
		piece := file[piece_start:min(piece_start + WRITE_PIECE, count)]
		if _, status := storage.write_range(&store_client, storage.ROOT, name, u64(piece_start), piece, &store_error); status != .Ok {
			return store_failure(error, &store_error, status, .File, name)
		}
	}
	// An older file of the nickname can be longer.
	if status := storage.set_size(&store_client, storage.ROOT, name, u64(count), &store_error); status != .Ok {
		return store_failure(error, &store_error, status, .File, name)
	}
	if _, status := storage.commit(&store_client, storage.ROOT, name, &store_error); status != .Ok {
		return store_failure(error, &store_error, status, .File, name)
	}
	return .Succeeded, 0
}
