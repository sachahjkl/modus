package module

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The load error as log facts (src/md/features/log_facts.md, "The load
// error as facts"). A Load_Error has four names with their hashes, an
// export, and two descriptions: far past one record. Each stage names a
// part of it only, so each stage has one shape here, with the fields that
// its sentence names: the names of the modules as Text fields of
// LOAD_NAME_FIELD_BYTES, their hashes as heads of a whole hash, and the
// enums of the contract that say what failed. A module declares its fact
// type of a stage as a distinct type of the shape, with its own template,
// and writes it with the procedure of the shape:
//
// ```odin
// @(log_fact = "host: the load of {module_name} ({module_hash}) found no file of its import {imported_name} ({imported_hash})")
// Load_Find_Failed :: distinct module.Load_Find_Fields
//
// switch error.stage {
// case .Find:
// 	system.log_fact(.Warning, Load_Find_Failed(module.load_find_fact_fields(&error)))
// ...
// }
// ```
//
// The two descriptions of the stage Check are not in its fact: the fact
// says the difference and the number of the parameter, and the module
// files of the two modules hold the descriptions.

// The bytes of a Text field of the name of a module or of an export in a
// fact of a load: NAME_SIZE bytes, a zero byte, and the rest of 8 bytes.
LOAD_NAME_FIELD_BYTES :: 40
#assert(LOAD_NAME_FIELD_BYTES > NAME_SIZE && LOAD_NAME_FIELD_BYTES % 8 == 0)

// Find: the load source has no file with the hash of the import, or of the
// module itself (no import: imported is zero).
Load_Find_Fields :: struct {
	module_hash:   value_kinds.Hash_Head_Field,
	imported_hash: value_kinds.Hash_Head_Field,
	module_name:   [40]u8,
	imported_name: [40]u8,
}

// Read: the file of the module that the stage concerns does not have the
// hash that names it (file_error None), or is not a valid module.
Load_Read_Fields :: struct {
	file_error:   Error,
	subject_hash: value_kinds.Hash_Head_Field,
	subject_name: [40]u8,
}

// Cycle: a module imports itself through its imports, by a replacement.
Load_Cycle_Fields :: struct {
	module_name:      [40]u8,
	imported_name:    [40]u8,
	replacement_name: [40]u8,
}

// Check: an export that an import slot uses differs in the module of the
// replacement: the difference, and the parameter for a difference of one.
Load_Check_Fields :: struct {
	difference:    Difference,
	parameter:     u32,
	module_name:   [40]u8,
	imported_name: [40]u8,
	export:        [40]u8,
}

// Bind: an import slot names no import or no export, or is not in writable data.
Load_Bind_Fields :: struct {
	import_slot:   u32,
	module_name:   [40]u8,
	imported_name: [40]u8,
	export:        [40]u8,
}

// Map and Unmap: a kernel operation on the memory of a module failed.
Load_Memory_Fields :: struct {
	status:      op.Status_Word,
	module_hash: value_kinds.Hash_Head_Field,
	module_name: [40]u8,
}

// Room: the module space, the imports of one module, or the table of the
// loader has no room for one more.
Load_Room_Fields :: struct {
	module_hash: value_kinds.Hash_Head_Field,
	module_name: [40]u8,
}

// The shapes have no padding, which a fact refuses, and fit one record.
#assert(size_of(Load_Find_Fields) == 2 * value_kinds.HASH_FIELD_BYTES + 2 * LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Read_Fields) == 4 + value_kinds.HASH_FIELD_BYTES + LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Cycle_Fields) == 3 * LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Check_Fields) == 8 + 3 * LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Bind_Fields) == 4 + 3 * LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Memory_Fields) == 8 + value_kinds.HASH_FIELD_BYTES + LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Room_Fields) == value_kinds.HASH_FIELD_BYTES + LOAD_NAME_FIELD_BYTES)
#assert(size_of(Load_Find_Fields) <= op.LOG_FACT_VALUE_CAPACITY && size_of(Load_Check_Fields) <= op.LOG_FACT_VALUE_CAPACITY)

// load_name_field gives the Text field of a name of a load error: its
// bytes, then zero bytes.
@(private = "file")
load_name_field :: proc "contextless" (name: [NAME_SIZE]u8) -> (field: [LOAD_NAME_FIELD_BYTES]u8) {
	own := name
	copy(field[:NAME_SIZE], own[:])
	return
}

// load_find_fact_fields gives the fields of a load error of the stage Find.
load_find_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Find_Fields {
	return {
		module_hash   = value_kinds.Hash_Head_Field(error.module.hash),
		imported_hash = value_kinds.Hash_Head_Field(error.imported.hash),
		module_name   = load_name_field(error.module.name),
		imported_name = load_name_field(error.imported.name),
	}
}

// load_read_fact_fields gives the fields of a load error of the stage Read:
// the module that the stage concerns, the import or the module itself.
load_read_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Read_Fields {
	subject := error.imported.hash != {} ? &error.imported : &error.module
	return {file_error = error.file_error, subject_hash = value_kinds.Hash_Head_Field(subject.hash), subject_name = load_name_field(subject.name)}
}

// load_cycle_fact_fields gives the fields of a load error of the stage
// Cycle: the replacement, or the import when no replacement is named.
load_cycle_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Cycle_Fields {
	replacement := error.replacement.hash != {} ? &error.replacement : &error.imported
	return {module_name = load_name_field(error.module.name), imported_name = load_name_field(error.imported.name), replacement_name = load_name_field(replacement.name)}
}

// load_check_fact_fields gives the fields of a load error of the stage Check.
load_check_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Check_Fields {
	return {difference = error.difference, parameter = error.parameter, module_name = load_name_field(error.module.name), imported_name = load_name_field(error.imported.name), export = load_name_field(error.export)}
}

// load_bind_fact_fields gives the fields of a load error of the stage Bind.
load_bind_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Bind_Fields {
	return {import_slot = error.import_slot, module_name = load_name_field(error.module.name), imported_name = load_name_field(error.imported.name), export = load_name_field(error.export)}
}

// load_memory_fact_fields gives the fields of a load error of the stage
// Map or Unmap: the status of the kernel operation. A status word that
// names no member stays its word, which a reader writes as its number.
load_memory_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Memory_Fields {
	return {status = op.Status_Word(error.status), module_hash = value_kinds.Hash_Head_Field(error.module.hash), module_name = load_name_field(error.module.name)}
}

// load_room_fact_fields gives the fields of a load error of the stage Room.
load_room_fact_fields :: proc "contextless" (error: ^Load_Error) -> Load_Room_Fields {
	return {module_hash = value_kinds.Hash_Head_Field(error.module.hash), module_name = load_name_field(error.module.name)}
}
