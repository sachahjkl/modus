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
nickname_check :: proc "contextless" (nickname: ^string, name_copy: ^[disk_process.NAME_LIMIT]u8, use: disk_process.Nickname_Use, error: ^errors.Error_Record) -> (name: string, failure: i64) {
	nickname_text := nickname^
	name_length := copy(name_copy[:], nickname_text)
	name = string(name_copy[:name_length])
	if refusal := disk_process.nickname_refusal(name, len(nickname_text), 1, use); refusal.kind != 0 {
		error^ = refusal
		return "", ERROR_NAME
	}
	return name, 0
}

// put stores the module file that the caller lends in memory in the store module_files under a nickname.
//
// The service copies the first `size` bytes of the memory object one time, by pieces, writes them as the object
// `nickname` of the root tree of the store `module_files` of its principal in commits of 1 MiB, then gives the 64
// hexadecimal digits of the BLAKE3 hash of the bytes. A file of the same nickname is replaced, and the store keeps the one before as a version.
//
// - **nickname**: the name of the entry, 1 to 23 bytes, with no zero byte and no `/`; not `module_files` and not
//   `grant_table`.
// - **module**: a memory object with the bytes, which the caller lends with Read.
// - **size**: the count of the bytes, 1 byte to 64 MiB, at most the bytes of the memory object.
// - **result**: the 64 hexadecimal digits of the hash.
//
// The caller must act for the principal of the store (**Acts_For_Principal**). The result is 64, or a negative number
// with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal of the store.
// - `Empty`, `Too_Long` or `Bad_Byte` (-2): the nickname; `Exists` (-2): `module_files` or `grant_table`, which the
//   store keeps.
// - `Refused` (-6): the service has no store, or the storage service refused the file.
// - `Out_Of_Range` (-7, argument 3): a size of 0, past 64 MiB, or past the memory object; `Refused` (-7): the memory
//   object does not map.
//
// Example: `module_files.put("hello", module, 4096)`.
@(export, link_name = "put")
put :: proc "c" (nickname: ^string, module: system.Lent({.Read}), size: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	if !caller_allowed() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [disk_process.NAME_LIMIT]u8
	name, name_failure := nickname_check(nickname, &name_copy, .Make, error)
	if name_failure != 0 {
		return name_failure
	}
	pages, size_status := system.memory_size(module.handle)
	if size_status != .Ok {
		pages = 0
	}
	if refusal := disk_process.put_size_refusal(size, pages * system.PAGE_SIZE, 3); refusal.kind != 0 {
		error^ = refusal
		return ERROR_MEMORY
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	address, map_status := system.memory_map(module.handle, {})
	if map_status != .Ok {
		return errors.fail(error, ERROR_MEMORY, .Refused, .None, 2, 0, 0, i64(map_status))
	}
	// Each piece is copied one time, then hashed and written from the
	// copy: the caller can change its memory object during the call, and
	// the hash names the bytes that the store holds.
	count := int(size)
	stream := File_Stream{hasher = blake3.hasher_make()}
	for stream.written < count {
		taken := min(len(piece), count - stream.written)
		intrinsics.mem_copy_non_overlapping(&piece[0], rawptr(uintptr(address) + uintptr(stream.written)), taken)
		if failure := file_stream_piece(&stream, name, piece[:taken], error); failure != 0 {
			system.memory_unmap(address)
			return failure
		}
	}
	system.memory_unmap(address)
	hash, failure := file_stream_end(&stream, name, error)
	if failure != 0 {
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
// - `Empty`, `Too_Long` or `Bad_Byte` (-2): the nickname; `Absent` (-2): `module_files` or `grant_table`, which no
//   module file has.
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
	name, name_failure := nickname_check(nickname, &name_copy, .Read, error)
	if name_failure != 0 {
		return name_failure
	}
	if store_client.ring_memory == 0 || !storage.connected(&store_client) {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	store_error: errors.Error_Record
	object_size, size_status := storage.size(&store_client, storage.ROOT, name, &store_error)
	absent := size_status == .Failed && store_error.kind == i64(errors.Kind.Absent)
	if size_status != .Ok && !absent {
		return store_failure(error, &store_error, size_status, .File, name)
	}
	if refusal := disk_process.stored_file_refusal(object_size, absent, 1); refusal.kind != 0 {
		error^ = refusal
		return ERROR_STORE
	}
	count := int(object_size)
	pages, pages_status := system.memory_size(module.handle)
	if pages_status != .Ok {
		pages = 0
	}
	if refusal := disk_process.read_room_refusal(i64(count), pages * system.PAGE_SIZE, 2); refusal.kind != 0 {
		error^ = refusal
		return ERROR_MEMORY
	}
	address, map_status := system.memory_map(module.handle, {.Write})
	if map_status != .Ok {
		return errors.fail(error, ERROR_MEMORY, .Refused, .None, 2, 0, 0, i64(map_status))
	}
	// The ranges go into the memory of the caller by pieces of this
	// service: the file costs this service no memory of its size.
	received := 0
	for received < count {
		bytes, status := storage.read_range(&store_client, storage.ROOT, name, u64(received), piece[:min(len(piece), count - received)], &store_error)
		// An answer with no byte before the end would come again for ever.
		if status != .Ok || len(bytes) == 0 {
			system.memory_unmap(address)
			return store_failure(error, &store_error, status == .Ok ? .Refused : status, .File, name)
		}
		intrinsics.mem_copy_non_overlapping(rawptr(uintptr(address) + uintptr(received)), raw_data(bytes), len(bytes))
		received += len(bytes)
	}
	system.memory_unmap(address)
	return i64(count)
}

// The write of one file of the store by pieces: the bytes written so far,
// the bytes of the last commit, and the hash of the bytes written.
File_Stream :: struct {
	hasher:    blake3.Hasher,
	written:   int,
	committed: int,
}

// file_stream_piece writes one piece after the bytes written so far, as a
// pending change of the object name, adds it to the hash, and commits the
// pending changes at each COMMIT_STEP_BYTES. The piece is memory of this
// service: the bytes hashed are the bytes written.
file_stream_piece :: proc "contextless" (stream: ^File_Stream, name: string, bytes: []u8, error: ^errors.Error_Record) -> i64 {
	store_error: errors.Error_Record
	for at := 0; at < len(bytes); at += WRITE_PIECE {
		part := bytes[at:min(at + WRITE_PIECE, len(bytes))]
		if _, status := storage.write_range(&store_client, storage.ROOT, name, u64(stream.written), part, &store_error); status != .Ok {
			return store_failure(error, &store_error, status, .File, name)
		}
		blake3.hasher_update(&stream.hasher, part)
		stream.written += len(part)
		if stream.written - stream.committed >= COMMIT_STEP_BYTES {
			if _, status := storage.commit(&store_client, storage.ROOT, name, &store_error); status != .Ok {
				return store_failure(error, &store_error, status, .File, name)
			}
			stream.committed = stream.written
		}
	}
	return 0
}

// file_stream_end sets the size of the object to the bytes written, since
// an older file of the nickname can be longer, commits it, and gives the
// hash of the bytes written.
file_stream_end :: proc "contextless" (stream: ^File_Stream, name: string, error: ^errors.Error_Record) -> (hash: blake3.Hash, failure: i64) {
	store_error: errors.Error_Record
	if status := storage.set_size(&store_client, storage.ROOT, name, u64(stream.written), &store_error); status != .Ok {
		return {}, store_failure(error, &store_error, status, .File, name)
	}
	if _, status := storage.commit(&store_client, storage.ROOT, name, &store_error); status != .Ok {
		return {}, store_failure(error, &store_error, status, .File, name)
	}
	stream.committed = stream.written
	return blake3.hasher_finish(&stream.hasher), 0
}
