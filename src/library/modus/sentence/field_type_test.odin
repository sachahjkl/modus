#+build !freestanding
package sentence

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "core:testing"

// field_type_text writes the type of one field, as the console and the
// manual show it.
@(private = "file")
field_type_text :: proc(buffer: []u8, item: module.Field) -> string {
	writer := Writer {
		buffer = buffer,
	}
	write_field_type(&writer, nil, item)
	return written(&writer)
}

// A kind byte or an enum byte that names nothing is "?", never the name of
// a kind or of an enum. Each kind then writes its name, a Status the name
// of its enum, and a plain Integer its sign and its size as before.
@(test)
the_type_of_a_field_names_its_kind :: proc(t: ^testing.T) {
	buffer: [64]u8
	unknown_kind := module.Field{type = u8(module.Type.Integer), kind = u8(max(value_kinds.Field_Kind)) + 1}
	testing.expect_value(t, field_type_text(buffer[:], unknown_kind), "?")
	unknown_enum := module.Field{type = u8(module.Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = max(u8)}
	testing.expect_value(t, field_type_text(buffer[:], unknown_enum), "Status(?)")
	Case :: struct {
		item: module.Field,
		text: string,
	}
	cases := [?]Case {
		{{type = u8(module.Type.Integer), detail = 4, unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)}, "Hexadecimal(4)"},
		{{type = u8(module.Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)}, "Hexadecimal"},
		{{type = u8(module.Type.Integer), detail = 1, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)}, "Status(Log_Level)"},
		{{type = u8(module.Type.Text), detail = value_kinds.MODULE_NAME_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Module_Name)}, "Module_Name(32)"},
		{{type = u8(module.Type.Bytes), detail = value_kinds.HASH_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Hash)}, "Hash(32)"},
		{{type = u8(module.Type.Integer), detail = 1, unsigned = true}, "Unsigned(1)"},
		{{type = u8(module.Type.Integer)}, "Integer"},
		{{type = u8(module.Type.Text), detail = 16}, "Text(16)"},
	}
	for item in cases {
		testing.expect_value(t, field_type_text(buffer[:], item.item), item.text)
	}
}
