#+build !freestanding
package c_builder

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"

@(private = "file")
encode_record_with_path :: proc(buf: []u8, field_name: string, path_value: string) -> []u8 {
	w := declaration_eval.Output_Writer{buffer = buf}
	rec_tag := [1]u8{u8(declaration_eval.Value_Tag.Record)}
	txt_tag := [1]u8{u8(declaration_eval.Value_Tag.Text)}
	declaration_eval.output_write_bytes(&w, rec_tag[:])
	declaration_eval.output_write_u32(&w, 1)
	declaration_eval.output_write_string(&w, field_name)
	declaration_eval.output_write_bytes(&w, txt_tag[:])
	declaration_eval.output_write_string(&w, path_value)
	return buf[:w.written]
}

@(test)
argument_path_refusals_and_valid_paths :: proc(t: ^testing.T) {
	buf: [512]u8

	// Refusals: empty, truncated, non-record, missing path, traversal, leading/trailing/double slash.
	_, ok_empty := argument_path(nil)
	testing.expect(t, !ok_empty)

	for bad in ([]string{"", "/", "/collatz.c", "collatz.c/", "a//b.c", "..", "../collatz.c", "a/../b.c", "."}) {
		encoded := encode_record_with_path(buf[:], "path", bad)
		_, ok := argument_path(encoded)
		testing.expectf(t, !ok, "path %q must be refused", bad)
	}

	// Wrong field name refused.
	wrong_field := encode_record_with_path(buf[:], "file", "collatz.c")
	_, ok_wrong := argument_path(wrong_field)
	testing.expect(t, !ok_wrong)

	// Valid single-file and nested paths accepted.
	for good in ([]string{"collatz.c", "src/collatz.c", "a/b/c/main.c"}) {
		encoded := encode_record_with_path(buf[:], "path", good)
		got, ok := argument_path(encoded)
		testing.expect(t, ok)
		testing.expect_value(t, got, good)
	}

	// Trailing bytes after a valid record must be refused.
	encoded_good := encode_record_with_path(buf[:], "path", "collatz.c")
	buf[len(encoded_good)] = 0xAA
	_, ok_trailing := argument_path(buf[:len(encoded_good) + 1])
	testing.expect(t, !ok_trailing)

	// Duplicate "path" field must be refused.
	w := declaration_eval.Output_Writer{buffer = buf[:]}
	rec_tag := [1]u8{u8(declaration_eval.Value_Tag.Record)}
	txt_tag := [1]u8{u8(declaration_eval.Value_Tag.Text)}
	declaration_eval.output_write_bytes(&w, rec_tag[:])
	declaration_eval.output_write_u32(&w, 2)
	declaration_eval.output_write_string(&w, "path")
	declaration_eval.output_write_bytes(&w, txt_tag[:])
	declaration_eval.output_write_string(&w, "a.c")
	declaration_eval.output_write_string(&w, "path")
	declaration_eval.output_write_bytes(&w, txt_tag[:])
	declaration_eval.output_write_string(&w, "b.c")
	_, ok_dup := argument_path(buf[:w.written])
	testing.expect(t, !ok_dup)
}

@(test)
input_row_find_checks_name_kind_and_nonzero_hash :: proc(t: ^testing.T) {
	h1 := blake3.hash(transmute([]u8)string("compiler"))
	h2 := blake3.hash(transmute([]u8)string("source"))
	rows := [3]pr.Recipe_Input_Row {
		{kind = pr.Recipe_Object_Kind_Word(object_cache.Cache_Object_Kind.Blob), hash = value_kinds.Hash_Field(h1)},
		{kind = pr.Recipe_Object_Kind_Word(object_cache.Cache_Object_Kind.Tree), hash = value_kinds.Hash_Field(h2)},
		{kind = pr.Recipe_Object_Kind_Word(object_cache.Cache_Object_Kind.Blob), hash = {}},
	}
	copy(rows[0].name[:], "compiler")
	copy(rows[1].name[:], "source")
	copy(rows[2].name[:], "zero")

	// Wrong kind and zero hash refused.
	_, wrong_kind := input_row_find(rows[:], "compiler", .Tree)
	testing.expect(t, !wrong_kind)
	_, zero_found := input_row_find(rows[:], "zero", .Blob)
	testing.expect(t, !zero_found)
	_, absent := input_row_find(rows[:], "assembler", .Blob)
	testing.expect(t, !absent)

	// Valid lookups succeed.
	got1, ok1 := input_row_find(rows[:], "compiler", .Blob)
	testing.expect(t, ok1 && got1 == h1)
	got2, ok2 := input_row_find(rows[:], "source", .Tree)
	testing.expect(t, ok2 && got2 == h2)
}

@(private = "file")
Test_Field :: struct {
	name:    string,
	is_list: bool,
	text:    string,
	items:   []string,
}

@(private = "file")
encode_multi_record :: proc(buf: []u8, fields: []Test_Field) -> []u8 {
	w := declaration_eval.Output_Writer{buffer = buf}
	declaration_eval.output_write_u8(&w, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&w, u32(len(fields)))
	for field in fields {
		declaration_eval.output_write_string(&w, field.name)
		if field.is_list {
			declaration_eval.output_write_u8(&w, u8(declaration_eval.Value_Tag.List))
			declaration_eval.output_write_u32(&w, u32(len(field.items)))
			for item in field.items {
				declaration_eval.output_write_text(&w, item)
			}
		} else {
			declaration_eval.output_write_text(&w, field.text)
		}
	}
	return buf[:w.written]
}

@(test)
arguments_parse_multi_unit_refusals_and_valid :: proc(t: ^testing.T) {
	buf: [2048]u8
	parsed: Build_Arguments

	// Refusals: mixing path and units; empty units; duplicate unit; traversal in headers; exports with path; non-list units.
	mixed := encode_multi_record(buf[:], {
		{name = "path", text = "a.c"},
		{name = "units", is_list = true, items = {"a.c", "b.c"}},
	})
	testing.expect(t, !arguments_parse(mixed, &parsed), "mixing path and units must be refused")

	empty_units := encode_multi_record(buf[:], {
		{name = "units", is_list = true, items = {}},
	})
	testing.expect(t, !arguments_parse(empty_units, &parsed), "empty units must be refused")

	wrong_tag_units := encode_multi_record(buf[:], {
		{name = "units", text = "chibicc/parse.c"},
	})
	testing.expect(t, !arguments_parse(wrong_tag_units, &parsed), "non-list units must be refused")

	dup_units := encode_multi_record(buf[:], {
		{name = "units", is_list = true, items = {"chibicc/parse.c", "chibicc/parse.c"}},
	})
	testing.expect(t, !arguments_parse(dup_units, &parsed), "duplicate unit paths must be refused")

	bad_header := encode_multi_record(buf[:], {
		{name = "headers", is_list = true, items = {"../escape.h"}},
		{name = "units", is_list = true, items = {"chibicc/parse.c"}},
	})
	testing.expect(t, !arguments_parse(bad_header, &parsed), "parent traversal in headers must be refused")

	path_with_exports := encode_multi_record(buf[:], {
		{name = "exports", text = "main"},
		{name = "path", text = "a.c"},
	})
	testing.expect(t, !arguments_parse(path_with_exports, &parsed), "exports in single-unit mode must be refused")

	// Valid multi-unit record in canonical sorted field order (chibicc self-host shape).
	valid := encode_multi_record(buf[:], {
		{name = "assembly", is_list = true, items = {"chibicc/self_host/jump.s"}},
		{name = "exports", text = "compile_record_at"},
		{name = "headers", is_list = true, items = {"chibicc/chibicc.h", "libc/include/stdio.h"}},
		{name = "units", is_list = true, items = {"chibicc/codegen.c", "chibicc/compile.c", "chibicc/parse.c"}},
	})
	testing.expect(t, arguments_parse(valid, &parsed), "valid multi-unit record must parse")
	testing.expect_value(t, parsed.mode, Build_Mode.Multi_Unit)
	testing.expect_value(t, parsed.unit_count, 3)
	testing.expect_value(t, parsed.units[0], "chibicc/codegen.c")
	testing.expect_value(t, parsed.units[2], "chibicc/parse.c")
	testing.expect_value(t, parsed.assembly_count, 1)
	testing.expect_value(t, parsed.assembly[0], "chibicc/self_host/jump.s")
	testing.expect_value(t, parsed.header_count, 2)
	testing.expect_value(t, parsed.headers[1], "libc/include/stdio.h")
	testing.expect_value(t, parsed.exports, "compile_record_at")
}
