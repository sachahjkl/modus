package build

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "core:fmt"
import "core:testing"

// Each shape of a load error (module.Load_Find_Fields and the others) is a
// fact type that the build takes as a distinct type, with the size of the
// shape, no padding, and its enums of the contract as Status fields: the
// stage Read its error of the file, Check its difference, Map its status
// as a word of 8 bytes.
@(test)
the_shapes_of_a_load_error_are_fact_types :: proc(t: ^testing.T) {
	Shape :: struct {
		name: string,
		size: int,
		enum_field: string,
		which: value_kinds.Contract_Enum,
	}
	shapes := [?]Shape {
		{"Load_Find_Fields", size_of(module.Load_Find_Fields), "", .None},
		{"Load_Read_Fields", size_of(module.Load_Read_Fields), "file_error", .Module_Error},
		{"Load_Cycle_Fields", size_of(module.Load_Cycle_Fields), "", .None},
		{"Load_Check_Fields", size_of(module.Load_Check_Fields), "difference", .Load_Difference},
		{"Load_Bind_Fields", size_of(module.Load_Bind_Fields), "", .None},
		{"Load_Memory_Fields", size_of(module.Load_Memory_Fields), "status", .Call_Outcome},
		{"Load_Room_Fields", size_of(module.Load_Room_Fields), "", .None},
	}
	text := "package fact_load_probe\n\nimport \"modus:contract/module\"\n"
	for shape in shapes {
		state: Describe_State
		state.records = make([dynamic]Record_Description, context.temp_allocator)
		state.structs = make(map[string]Struct_Source, context.temp_allocator)
		file, parsed := parse_source("src/modules/tests/fact_load_probe/main.odin", text, &state)
		if !testing.expectf(t, parsed && file != nil && imported_package_read(&state, "module"), "the shapes of %s are not read", shape.name) {
			continue
		}
		number, is_record, ok := struct_record_named(&state, fmt.tprintf("module.%s", shape.name), "Failed", false, no_field_taken = true)
		if !testing.expectf(t, is_record && ok && number > 0, "the shape %s has no description", shape.name) {
			continue
		}
		record := state.records[number - 1]
		testing.expectf(t, int(record.size) == shape.size, "the shape %s has %d bytes in the description, %d in the compiler", shape.name, record.size, shape.size)
		end: u32 = 0
		for item in record.fields {
			testing.expectf(t, item.offset == end, "the shape %s has padding before %s", shape.name, item.name)
			end = item.offset + field_description_size_of(item)
			if item.name == shape.enum_field {
				testing.expectf(t, item.kind == .Status && item.contract_enum == shape.which, "the field %s of %s is not a Status of %v", item.name, shape.name, shape.which)
			}
		}
		testing.expectf(t, end == record.size, "the shape %s has padding after its last field", shape.name)
	}
}

// field_description_size_of gives the bytes of a field of a description.
@(private = "file")
field_description_size_of :: proc(item: Field_Description) -> u32 {
	switch item.type {
	case .Integer:
		return item.detail == 0 ? 8 : item.detail
	case .Handle:
		return 4
	case .Text, .Bytes:
		return item.detail
	case .None, .Record, .Table, .Enum:
	}
	return 0
}
