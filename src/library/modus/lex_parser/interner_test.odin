#+build !freestanding
#+build !modus
package lex_parser

import "core:fmt"
import "core:testing"
import "modus:hash_table"

@(test)
interner_refuses_bad_buffers_and_capacity :: proc(t: ^testing.T) {
	// ZII interner safely refuses lookup and intern.
	empty: String_Interner
	_, found := intern_lookup(&empty, "foo")
	testing.expect(t, !found)
	_, ok := intern(&empty, "foo")
	testing.expect(t, !ok)
	testing.expect_value(t, sym_text(&empty, Sym_Id(1)), "")

	controls: [hash_table.GROUP_WIDTH]u8
	refs: [hash_table.GROUP_WIDTH]u32
	spans: [16]Sym_Span
	bytes: [32]u8

	// Refuse < 2 spans or bad slice index buffers.
	_, ok_small_spans := interner_init(controls[:], refs[:], spans[:1], bytes[:])
	testing.expect(t, !ok_small_spans)
	_, ok_bad_ctrl := interner_init(controls[:15], refs[:], spans[:], bytes[:])
	testing.expect(t, !ok_bad_ctrl)

	// Valid init with capacity 14 in hash table, 15 span slots, 32 bytes.
	in1, init_ok := interner_init(controls[:], refs[:], spans[:], bytes[:], 0x1234)
	testing.expect(t, init_ok)

	s1, ok1 := intern(&in1, "alpha")
	testing.expect(t, ok1 && s1 == Sym_Id(1))
	s1_again, ok1_again := intern(&in1, "alpha")
	testing.expect(t, ok1_again && s1_again == s1)
	testing.expect_value(t, sym_text(&in1, s1), "alpha")
	testing.expect_value(t, sym_text(&in1, NO_SYM), "")
	testing.expect_value(t, sym_text(&in1, Sym_Id(99)), "")

	// Empty string is valid and distinct from NO_SYM.
	s_empty, ok_empty := intern(&in1, "")
	testing.expect(t, ok_empty && s_empty == Sym_Id(2))
	testing.expect_value(t, sym_text(&in1, s_empty), "")

	// Byte buffer exhaustion leaves state clean.
	_, ok_huge := intern(&in1, "this_string_exceeds_32_bytes_easily_0123456789")
	testing.expect(t, !ok_huge)
	testing.expect_value(t, in1.sym_count, u32(2))
}

@(test)
interner_dedup_and_clear :: proc(t: ^testing.T) {
	GROUPS :: 32
	controls: [GROUPS * hash_table.GROUP_WIDTH]u8
	refs: [GROUPS * hash_table.GROUP_WIDTH]u32
	spans: [512]Sym_Span
	bytes: [8192]u8

	in1, ok := interner_init(controls[:], refs[:], spans[:], bytes[:], 0xCAFEBABE)
	testing.expect(t, ok)

	ids: [400]Sym_Id
	for i in 0 ..< 400 {
		name := fmt.tprintf("field_%04d", i)
		id, ok_i := intern(&in1, name)
		testing.expect(t, ok_i)
		ids[i] = id
	}
	testing.expect_value(t, in1.sym_count, u32(400))

	// Lookup and re-intern must return identical Sym_Id and exact UTF-8 bytes.
	for i in 0 ..< 400 {
		name := fmt.tprintf("field_%04d", i)
		id, ok_i := intern(&in1, name)
		testing.expect(t, ok_i && id == ids[i])
		looked, found := intern_lookup(&in1, name)
		testing.expect(t, found && looked == ids[i])
		testing.expect_value(t, sym_text(&in1, id), name)
	}
	_, missing := intern_lookup(&in1, "does_not_exist")
	testing.expect(t, !missing)

	interner_clear(&in1)
	testing.expect_value(t, in1.sym_count, u32(0))
	_, after_clear := intern_lookup(&in1, "field_0000")
	testing.expect(t, !after_clear)
}
