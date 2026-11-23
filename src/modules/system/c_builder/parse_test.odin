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
}

@(test)
input_row_find_checks_name_kind_and_nonzero_hash :: proc(t: ^testing.T) {
	h1 := blake3.hash(transmute([]u8)string("compiler"))
	h2 := blake3.hash(transmute([]u8)string("source"))
	rows := [3]pr.Recipe_Input_Row {
		{kind_word = i64(object_cache.Cache_Object_Kind.Blob), hash = value_kinds.Hash_Field(h1)},
		{kind_word = i64(object_cache.Cache_Object_Kind.Tree), hash = value_kinds.Hash_Field(h2)},
		{kind_word = i64(object_cache.Cache_Object_Kind.Blob), hash = {}},
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
