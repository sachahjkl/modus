#+build !freestanding
package system

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "core:strings"
import "core:testing"

// The unit of an Integer parameter is part of the meaning of an export
// (docs/MODULE_CONTRACT.md, "The unit of an Integer parameter"): the check
// of a replacement refuses a module whose export counts in another unit,
// and its sentence names both units.

// A module with one export: one Integer parameter with the given detail.
@(private = "file")
module_with_one_integer :: proc(storage: []u8, detail: u32) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	// Index 0 of each table is the empty record.
	directory[module.Table_Kind.Exports] = {offset = offset, count = 2, record_size = size_of(module.Export)}
	(^module.Export)(&storage[offset + size_of(module.Export)])^ = {code_offset = 0, function = 1}
	offset += 2 * size_of(module.Export)
	directory[module.Table_Kind.Functions] = {offset = offset, count = 2, record_size = size_of(module.Function)}
	function := (^module.Function)(&storage[offset + size_of(module.Function)])
	function.parameter_count, function.parameters[0], function.parameter_details[0], function.result = 1, .Integer, detail, .Integer
	offset += 2 * size_of(module.Function)
	(^module.Header)(&storage[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&storage[size_of(module.Header)])^ = directory
	return storage[:offset]
}

// The same unit agrees; another unit, and no unit where the import states
// one, are a Parameter_Detail of the first parameter.
@(test)
a_replacement_in_another_unit_fails_the_check :: proc(t: ^testing.T) {
	pages := value_kinds.integer_unit_detail(value_kinds.size_in(.Pages))
	bytes := value_kinds.integer_unit_detail(value_kinds.size_in(.Bytes))
	imported_storage, same_storage, other_storage, plain_storage: [1024]u8
	imported := module_with_one_integer(imported_storage[:], pages)
	same := module_with_one_integer(same_storage[:], pages)
	other := module_with_one_integer(other_storage[:], bytes)
	plain := module_with_one_integer(plain_storage[:], 0)

	difference, _, _, _ := module.functions_compare(imported, 1, same, 1)
	testing.expect_value(t, difference, module.Difference.None)
	replacements := [2][]u8{other, plain}
	for replacement in replacements {
		parameter: u32
		difference, parameter, _, _ = module.functions_compare(imported, 1, replacement, 1)
		testing.expect_value(t, difference, module.Difference.Parameter_Detail)
		testing.expect_value(t, parameter, 1)
	}

	// The sentence of the loader names the two units.
	error := module.Load_Error{stage = .Check}
	error.difference, error.parameter, error.expected, error.found = module.functions_compare(imported, 1, other, 1)
	module.name_set(&error.module.name, "importer")
	module.name_set(&error.imported.name, "pager")
	module.name_set(&error.replacement.name, "pager_in_bytes")
	module.name_set(&error.export, "reserve")
	buffer: [512]u8
	writer := Writer{buffer = buffer[:]}
	load_error_text(&writer, &error)
	text := written(&writer)
	testing.expectf(t, strings.contains(text, "export reserve of pager_in_bytes: parameter 1 is Integer in bytes, pager has Integer in pages"), "the sentence is: %s", text)
}
