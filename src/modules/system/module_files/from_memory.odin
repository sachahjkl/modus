package module_files

// The module files that a caller gives in memory, and reads back
// (src/md/features/program_loop.md, "Why each part is where it is"): the
// console builds a module with the service recipes and puts it in the store
// module_files with no network, then reads it back to run it. The service
// stays the one writer of the module files of the store.

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:storage"
import "modus:system"

// The failure of a memory object that the caller lent.
ERROR_MEMORY :: -7

// nickname_check copies a nickname of a call one time, then checks the copy:
// the caller can change its call region during the call. It gives the
// name, in the place of the caller, or a failure with its error record.
nickname_check :: proc "contextless" (nickname: ^string, name_copy: ^[disk_process.NAME_LIMIT]u8, error: ^errors.Error_Record) -> (name: string, failure: i64) {
	nickname_text := nickname^
	name_length := copy(name_copy[:], nickname_text)
	if len(nickname_text) > disk_process.NAME_LIMIT {
		return "", errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, 1, i64(len(nickname_text)), disk_process.NAME_LIMIT)
	}
	name = string(name_copy[:name_length])
	problem, offset := disk_process.name_problem(name)
	switch problem {
	case .None:
	case .Empty:
		return "", errors.fail(error, ERROR_NAME, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT)
	case .Too_Long:
		return "", errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, 1, i64(name_length), disk_process.NAME_LIMIT)
	case .Bad_Byte:
		return "", errors.fail(error, ERROR_NAME, .Bad_Byte, .Bytes, 1, i64(offset), 0, i64(name_copy[offset]))
	case .Store_Name, .Table_Name:
		// The disk grant table of the principal is an object of this
		// store: no file is written over it, and none is read as a module.
		return "", errors.fail(error, ERROR_NAME, .Reserved, .None, 1)
	}
	return name, 0
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
// The caller must act for the principal of the store (**Acts_For_Principal**). The result is 64, or a negative number
// with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long`, `Bad_Byte` or `Reserved` (-2): the nickname.
// - `Refused` (-6): the service has no store, or the storage service refused the file.
// - `Out_Of_Range` (-7, argument 3): a size of 0, past 4 MiB, or past the memory object; `Refused` (-7): the memory
//   object does not map.
//
// Example: `module_files.put("hello", module, 4096)`.
@(export, link_name = "put")
put :: proc "c" (nickname: ^string, module: system.Lent({.Read}), size: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	if !caller_allowed() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [disk_process.NAME_LIMIT]u8
	name, name_failure := nickname_check(nickname, &name_copy, error)
	if name_failure != 0 {
		return name_failure
	}
	if size < 1 || size > disk_process.FILE_BYTES_LIMIT {
		return errors.fail(error, ERROR_MEMORY, .Out_Of_Range, .Bytes, 3, size, disk_process.FILE_BYTES_LIMIT)
	}
	pages, size_status := system.memory_size(module.handle)
	if size_status != .Ok || u64(size) > pages * system.PAGE_SIZE {
		return errors.fail(error, ERROR_MEMORY, .Out_Of_Range, .Bytes, 3, size, i64(min(pages * system.PAGE_SIZE, u64(max(i64)))))
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	address, map_status := system.memory_map(module.handle, {})
	if map_status != .Ok {
		return errors.fail(error, ERROR_MEMORY, .Refused, .None, 2, 0, 0, i64(map_status))
	}
	// One copy: the caller can change its memory object during the call,
	// and the hash names the bytes that the store holds.
	intrinsics.mem_copy_non_overlapping(raw_data(file), address, int(size))
	system.memory_unmap(address)
	count := int(size)
	hash := blake3.hash(file[:count])
	if failure := file_write(name, count, error); failure != 0 {
		return failure
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, hash)
	system.log_fact(.Info, File_Put{size = value_kinds.Size_In_Bytes(count), file_hash = value_kinds.Hash_Field(hash), nickname = value_kinds.module_name_field(name)})
	copy(result^, digits[:])
	return disk_process.HASH_DIGITS
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
// a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long`, `Bad_Byte` or `Reserved` (-2): the nickname.
// - `Absent` (-6): no object of the nickname; `Refused` (-6): the service has no store, or the storage service refused
//   the read.
// - `Too_Small` (-7, argument 2): the memory object holds fewer bytes than the file; `Refused` (-7): it does not map.
//
// Example: `module_files.read("hello", module)`.
@(export, link_name = "read")
read :: proc "c" (nickname: ^string, module: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
	if !caller_allowed() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [disk_process.NAME_LIMIT]u8
	name, name_failure := nickname_check(nickname, &name_copy, error)
	if name_failure != 0 {
		return name_failure
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	store_error: errors.Error_Record
	object_size, size_status := storage.size(&store_client, storage.ROOT, name, &store_error)
	if size_status != .Ok {
		if size_status == .Failed && store_error.kind == i64(errors.Kind.Absent) {
			return errors.fail(error, ERROR_STORE, .Absent, .Objects, 1)
		}
		return store_failure(error, &store_error, size_status, .File, name)
	}
	if object_size <= 0 || object_size > disk_process.FILE_BYTES_LIMIT {
		return errors.fail(error, ERROR_STORE, .Out_Of_Range, .Bytes, 1, object_size, disk_process.FILE_BYTES_LIMIT)
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
	if pages_status != .Ok || u64(count) > pages * system.PAGE_SIZE {
		return errors.fail(error, ERROR_MEMORY, .Too_Small, .Bytes, 2, i64(min(pages * system.PAGE_SIZE, u64(max(i64)))), i64(count))
	}
	address, map_status := system.memory_map(module.handle, {.Write})
	if map_status != .Ok {
		return errors.fail(error, ERROR_MEMORY, .Refused, .None, 2, 0, 0, i64(map_status))
	}
	intrinsics.mem_copy_non_overlapping(address, raw_data(file), count)
	system.memory_unmap(address)
	return i64(count)
}

// file_write writes the first count bytes of file as the object name, in
// pieces, sets its size and commits it: one commit for the whole file.
@(private = "file")
file_write :: proc "contextless" (name: string, count: int, error: ^errors.Error_Record) -> i64 {
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
	return 0
}
