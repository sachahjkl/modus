package disk_process

// The borders of the module files that a caller gives in memory and reads
// back (module_files.put and module_files.read,
// src/md/features/program_loop.md): each check of a value that the caller
// chose, as an error record that is empty when the value is accepted. They
// read no state, so a host test gives them each edge.

import "modus:contract/errors"

// What a call does with a nickname: it decides the refusal of the two names
// that the store keeps for itself.
Nickname_Use :: enum u8 {
	Make, // The call makes an object or a store of the name: those exist already.
	Read, // The call reads the module file of the name: no module file has it.
}

// nickname_refusal checks a nickname that the service copied out of the
// call: argument is the place of the nickname in the call. given_length is
// the length that the caller gave, before the copy cut it to NAME_LIMIT.
nickname_refusal :: proc "contextless" (name: string, given_length: int, argument: i64, use: Nickname_Use) -> errors.Error_Record {
	if given_length > NAME_LIMIT {
		return errors.error_make(.Too_Long, .Bytes, argument, i64(given_length), NAME_LIMIT)
	}
	problem, offset := name_problem(name)
	switch problem {
	case .None:
		return {}
	case .Empty:
		return errors.error_make(.Empty, .Bytes, argument, 0, NAME_LIMIT)
	case .Too_Long:
		return errors.error_make(.Too_Long, .Bytes, argument, i64(len(name)), NAME_LIMIT)
	case .Bad_Byte:
		return errors.error_make(.Bad_Byte, .Bytes, argument, i64(offset), 0, i64(name[offset]))
	case .Store_Name, .Table_Name:
		// The store module_files and its disk grant table exist already: no
		// file is written over the table, and it is read as no module.
		switch use {
		case .Make:
			return errors.error_make(.Exists, .None, argument)
		case .Read:
			return errors.error_make(.Absent, .Objects, argument)
		}
	}
	return {}
}

// put_size_refusal checks the count of bytes of a file that the caller
// lends in a memory object of memory_bytes: 1 to FILE_BYTES_LIMIT, and no
// byte past the memory object.
put_size_refusal :: proc "contextless" (size: i64, memory_bytes: u64, argument: i64) -> errors.Error_Record {
	if size < 1 || size > FILE_BYTES_LIMIT {
		return errors.error_make(.Out_Of_Range, .Bytes, argument, size, FILE_BYTES_LIMIT)
	}
	if u64(size) > memory_bytes {
		return errors.error_make(.Out_Of_Range, .Bytes, argument, size, i64(min(memory_bytes, u64(max(i64)))))
	}
	return {}
}

// stored_file_refusal checks the object of a nickname that the store gave
// for a read: absent, or a size that no module file has.
stored_file_refusal :: proc "contextless" (object_size: i64, absent: bool, argument: i64) -> errors.Error_Record {
	if absent {
		return errors.error_make(.Absent, .Objects, argument)
	}
	if object_size < 1 || object_size > FILE_BYTES_LIMIT {
		return errors.error_make(.Out_Of_Range, .Bytes, argument, object_size, FILE_BYTES_LIMIT)
	}
	return {}
}

// read_room_refusal checks that the memory object of memory_bytes that the
// caller lends holds the whole file of file_bytes.
read_room_refusal :: proc "contextless" (file_bytes: i64, memory_bytes: u64, argument: i64) -> errors.Error_Record {
	if u64(file_bytes) > memory_bytes {
		return errors.error_make(.Too_Small, .Bytes, argument, i64(min(memory_bytes, u64(max(i64)))), file_bytes)
	}
	return {}
}
