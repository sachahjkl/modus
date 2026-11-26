#+build !freestanding
package ast_codebase

import "core:strings"
import "core:testing"
import "modus:contract/byte_order"

@(test)
alpha_equivalence_and_structural_sensitivity :: proc(t: ^testing.T) {
	cb := new(Codebase)
	defer free(cb)

	// fn add(x: Int, y: Int) -> Int { return x + y; }
	px, ok_px := param_make("x", .Int)
	py, ok_py := param_make("y", .Int)
	testing.expect(t, ok_px && ok_py, "params x, y must construct")
	vx, _ := ast_add_var(cb, 0, "x")
	vy, _ := ast_add_var(cb, 1, "y")
	add_expr, _ := ast_add_binary(cb, .Add, vx, vy)
	ret1, _ := ast_add_return(cb, add_expr)
	s1 := [1]Node_Id{ret1}
	b1, _ := ast_add_block(cb, s1[:])
	p1 := [2]Param{px, py}
	def_add, ok_add := codebase_add_definition(cb, "add", p1[:], .Int, b1)
	testing.expect(t, ok_add, "add definition must register")

	// fn sum(a: Int, b: Int) -> Int { return a + b; }
	pa, _ := param_make("a", .Int)
	pb, _ := param_make("b", .Int)
	va, _ := ast_add_var(cb, 0, "a")
	vb, _ := ast_add_var(cb, 1, "b")
	sum_expr, _ := ast_add_binary(cb, .Add, va, vb)
	ret2, _ := ast_add_return(cb, sum_expr)
	s2 := [1]Node_Id{ret2}
	b2, _ := ast_add_block(cb, s2[:])
	p2 := [2]Param{pa, pb}
	def_sum, ok_sum := codebase_add_definition(cb, "sum", p2[:], .Int, b2)
	testing.expect(t, ok_sum, "sum definition must register")

	testing.expect(t, cb.defs[def_add].hash == cb.defs[def_sum].hash, "alpha-equivalent definitions add and sum must share exact 32-byte BLAKE3 hash")

	// Changing + to * must change the hash.
	vx3, _ := ast_add_var(cb, 0, "x")
	vy3, _ := ast_add_var(cb, 1, "y")
	mul_expr, _ := ast_add_binary(cb, .Mul, vx3, vy3)
	ret3, _ := ast_add_return(cb, mul_expr)
	s3 := [1]Node_Id{ret3}
	b3, _ := ast_add_block(cb, s3[:])
	def_mul, ok_mul := codebase_add_definition(cb, "mul", p1[:], .Int, b3)
	testing.expect(t, ok_mul, "mul definition must register")
	testing.expect(t, cb.defs[def_add].hash != cb.defs[def_mul].hash, "changing + to * must produce a distinct hash")

	// Swapping x - y vs y - x must change the hash.
	vx4, _ := ast_add_var(cb, 0, "x")
	vy4, _ := ast_add_var(cb, 1, "y")
	sub_xy, _ := ast_add_binary(cb, .Sub, vx4, vy4)
	ret4, _ := ast_add_return(cb, sub_xy)
	s4 := [1]Node_Id{ret4}
	b4, _ := ast_add_block(cb, s4[:])
	def_sub1, _ := codebase_add_definition(cb, "sub_xy", p1[:], .Int, b4)

	vy5, _ := ast_add_var(cb, 1, "y")
	vx5, _ := ast_add_var(cb, 0, "x")
	sub_yx, _ := ast_add_binary(cb, .Sub, vy5, vx5)
	ret5, _ := ast_add_return(cb, sub_yx)
	s5 := [1]Node_Id{ret5}
	b5, _ := ast_add_block(cb, s5[:])
	def_sub2, _ := codebase_add_definition(cb, "sub_yx", p1[:], .Int, b5)

	testing.expect(t, cb.defs[def_sub1].hash != cb.defs[def_sub2].hash, "swapping x - y vs y - x must produce distinct hashes")

	// Alpha-equivalent let bindings with different raw slot numbers and names.
	v_p1, _ := ast_add_var(cb, 0, "x")
	one1, _ := ast_add_int(cb, 1)
	l_expr1, _ := ast_add_binary(cb, .Add, v_p1, one1)
	let1, _ := ast_add_let(cb, 7, "temp", l_expr1)
	v_l1, _ := ast_add_var(cb, 7, "temp")
	ret_l1, _ := ast_add_return(cb, v_l1)
	ls1 := [2]Node_Id{let1, ret_l1}
	lb1, _ := ast_add_block(cb, ls1[:])
	p_one := [1]Param{px}
	def_let1, _ := codebase_add_definition(cb, "inc_a", p_one[:], .Int, lb1)

	v_p2, _ := ast_add_var(cb, 0, "a")
	one2, _ := ast_add_int(cb, 1)
	l_expr2, _ := ast_add_binary(cb, .Add, v_p2, one2)
	let2, _ := ast_add_let(cb, 2, "result", l_expr2)
	v_l2, _ := ast_add_var(cb, 2, "result")
	ret_l2, _ := ast_add_return(cb, v_l2)
	ls2 := [2]Node_Id{let2, ret_l2}
	lb2, _ := ast_add_block(cb, ls2[:])
	p_one_a := [1]Param{pa}
	def_let2, _ := codebase_add_definition(cb, "inc_b", p_one_a[:], .Int, lb2)

	testing.expect(t, cb.defs[def_let1].hash == cb.defs[def_let2].hash, "alpha-equivalent let bindings with different names and raw slots must match")
}

@(test)
rename_preserves_hashes_and_refuses_bad_names :: proc(t: ^testing.T) {
	cb := new(Codebase)
	defer free(cb)
	ed := new(Ast_Editor)
	defer free(ed)

	testing.expect(t, codebase_seed_sample(cb), "seed sample must succeed")
	square_hash_before := cb.defs[0].hash
	main_hash_before := cb.defs[1].hash

	// Refusals first: empty, bad syntax, duplicate, out-of-range index.
	testing.expect(t, !codebase_rename_definition(cb, 0, ""), "empty def name must be refused")
	testing.expect(t, !codebase_rename_definition(cb, 0, "1bad"), "leading digit def name must be refused")
	testing.expect(t, !codebase_rename_definition(cb, 0, "main"), "duplicate def name must be refused")
	testing.expect(t, !codebase_rename_definition(cb, 99, "ok_name"), "out-of-range def index must be refused")
	testing.expect(t, !codebase_rename_param(cb, 0, 0, ""), "empty param name must be refused")
	testing.expect(t, !codebase_rename_param(cb, 0, 5, "n"), "out-of-range param index must be refused")
	testing.expect_value(t, codebase_def_display_name(cb, 0), "square")

	// Valid O(1) definition rename: square -> sq.
	testing.expect(t, codebase_rename_definition(cb, 0, "sq"), "rename square -> sq must succeed")
	testing.expect_value(t, codebase_def_display_name(cb, 0), "sq")
	// Valid parameter rename: x -> n.
	testing.expect(t, codebase_rename_param(cb, 0, 0, "n"), "rename param x -> n must succeed")
	testing.expect_value(t, param_name(&cb.defs[0].params[0]), "n")

	// Rehash everything and prove BOTH square/sq and caller main kept exact 32-byte hashes.
	codebase_rehash_all(cb)
	testing.expect(t, cb.defs[0].hash == square_hash_before, "renaming definition and parameter must preserve its 32-byte hash")
	testing.expect(t, cb.defs[1].hash == main_hash_before, "renaming callee must preserve caller main 32-byte hash")

	// Projected text reflects the new names immediately.
	ast_editor_init(ed, cb, 0)
	found_sq := false
	found_n := false
	for i in 0 ..< ed.token_count {
		txt := token_text(&ed.tokens[i])
		if txt == "sq" && ed.tokens[i].slot == .Def_Name {
			found_sq = true
		}
		if txt == "n" && ed.tokens[i].slot == .Param_Name {
			found_n = true
		}
	}
	testing.expect(t, found_sq && found_n, "projected tokens must display renamed sq and n")
}

@(test)
modast1_codec_refusals_and_roundtrip :: proc(t: ^testing.T) {
	cb := new(Codebase)
	defer free(cb)
	cb2 := new(Codebase)
	defer free(cb2)
	wire := make([]u8, 65536)
	defer delete(wire)
	bad_buf := make([]u8, 65536)
	defer delete(bad_buf)

	testing.expect(t, codebase_seed_sample(cb), "seed sample must succeed")

	// Encode refusal: buffer too small (0 bytes, header-1 bytes, mid-stream).
	_, err_zero := codebase_encode(cb, nil)
	testing.expect_value(t, err_zero, Codec_Error.Buffer_Too_Small)
	small: [23]u8
	_, err_hdr := codebase_encode(cb, small[:])
	testing.expect_value(t, err_hdr, Codec_Error.Buffer_Too_Small)

	n_bytes, err_enc := codebase_encode(cb, wire)
	testing.expect_value(t, err_enc, Codec_Error.Ok)
	testing.expect(t, n_bytes > MODAST_HEADER_BYTES, "encoded payload must exceed header size")

	// Exact 1-byte-short encode refusal.
	_, err_short_enc := codebase_encode(cb, wire[:n_bytes - 1])
	testing.expect_value(t, err_short_enc, Codec_Error.Buffer_Too_Small)

	// Re-encode clean copy.
	n_bytes, err_enc = codebase_encode(cb, wire)
	testing.expect_value(t, err_enc, Codec_Error.Ok)

	// Decode refusals: empty, truncated, bad magic, bad version, bad flags, trailing bytes.
	testing.expect_value(t, codebase_decode(nil, cb2), Codec_Error.Truncated)
	testing.expect_value(t, codebase_decode(wire[:10], cb2), Codec_Error.Truncated)
	testing.expect_value(t, codebase_decode(wire[:n_bytes - 1], cb2), Codec_Error.Truncated)

	// Bad magic.
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	bad_buf[0] = 'X'
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes], cb2), Codec_Error.Bad_Magic)

	// Bad version.
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	byte_order.write_u16_little_endian(bad_buf, 8, 99)
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes], cb2), Codec_Error.Bad_Version)

	// Non-zero flags.
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	byte_order.write_u16_little_endian(bad_buf, 10, 1)
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes], cb2), Codec_Error.Bad_Flags)

	// Unknown Node_Kind enum byte (first node starts at offset MODAST_HEADER_BYTES).
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	bad_buf[MODAST_HEADER_BYTES] = 250
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes], cb2), Codec_Error.Unknown_Enum)

	// Out-of-range Node_Id in child_a of first node.
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	byte_order.write_u32_little_endian(bad_buf, MODAST_HEADER_BYTES + 16, 9999)
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes], cb2), Codec_Error.Node_Out_Of_Range)

	// Unused-field smuggling: non-zero child_a on leaf Var (first node of sample is Var "x").
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	byte_order.write_u32_little_endian(bad_buf, MODAST_HEADER_BYTES + 16, 1)
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes], cb2), Codec_Error.Node_Out_Of_Range)

	// Trailing garbage bytes.
	copy(bad_buf[:n_bytes], wire[:n_bytes])
	bad_buf[n_bytes] = 0xAA
	testing.expect_value(t, codebase_decode(bad_buf[:n_bytes + 1], cb2), Codec_Error.Trailing_Bytes)

	// Tampered Definition.hash must fail with Hash_Mismatch.
	tampered := new(Codebase)
	defer free(tampered)
	tampered^ = cb^
	tampered.defs[0].hash[0] ~= 0xFF
	t_len, t_err := codebase_encode(tampered, bad_buf)
	testing.expect_value(t, t_err, Codec_Error.Ok)
	testing.expect_value(t, codebase_decode(bad_buf[:t_len], cb2), Codec_Error.Hash_Mismatch)

	// Tampered Name_Entry.def_hash (while Definition.hash stays valid) must fail with Hash_Mismatch.
	tampered^ = cb^
	tampered.names[0].def_hash[0] ~= 0xFF
	t_len, t_err = codebase_encode(tampered, bad_buf)
	testing.expect_value(t, t_err, Codec_Error.Ok)
	testing.expect_value(t, codebase_decode(bad_buf[:t_len], cb2), Codec_Error.Hash_Mismatch)

	// Duplicate Name_Entry names in wire bytes must fail with Duplicate_Name.
	tampered^ = cb^
	tampered.names[1].name = tampered.names[0].name
	tampered.names[1].name_len = tampered.names[0].name_len
	t_len, t_err = codebase_encode(tampered, bad_buf)
	testing.expect_value(t, t_err, Codec_Error.Ok)
	testing.expect_value(t, codebase_decode(bad_buf[:t_len], cb2), Codec_Error.Duplicate_Name)

	// AST cycle refusal: construct a 1-node self-cycling Unary node directly in MODAST1 wire bytes.
	cyc: [128]u8
	magic := MODAST_MAGIC
	copy(cyc[0:8], magic[:])
	byte_order.write_u16_little_endian(cyc[:], 8, MODAST_VERSION)
	byte_order.write_u16_little_endian(cyc[:], 10, 0)
	byte_order.write_u32_little_endian(cyc[:], 12, 1) // 1 node
	byte_order.write_u32_little_endian(cyc[:], 16, 0) // 0 list items
	byte_order.write_u16_little_endian(cyc[:], 20, 0) // 0 defs
	byte_order.write_u16_little_endian(cyc[:], 22, 0) // 0 names
	cyc[24 + 0] = u8(Node_Kind.Unary)
	cyc[24 + 1] = 0
	cyc[24 + 2] = u8(Unary_Op.Neg)
	cyc[24 + 3] = 0
	cyc[24 + 4] = u8(Type_Kind.Int)
	cyc[24 + 5] = 0
	byte_order.write_u32_little_endian(cyc[:], 24 + 16, 1) // child_a = 1 (self-cycle!)
	testing.expect_value(t, codebase_decode(cyc[:24 + MODAST_NODE_FIXED_BYTES], cb2), Codec_Error.Cycle_Detected)

	// Valid round-trip.
	testing.expect_value(t, codebase_decode(wire[:n_bytes], cb2), Codec_Error.Ok)
	testing.expect_value(t, cb2.node_count, cb.node_count)
	testing.expect_value(t, cb2.def_count, cb.def_count)
	testing.expect_value(t, cb2.name_count, cb.name_count)
	testing.expect(t, cb2.defs[0].hash == cb.defs[0].hash, "round-trip def 0 hash must match")
	testing.expect(t, cb2.defs[1].hash == cb.defs[1].hash, "round-trip def 1 hash must match")
	testing.expect_value(t, codebase_def_display_name(cb2, 0), "square")
	testing.expect_value(t, codebase_def_display_name(cb2, 1), "main")
}

@(test)
dion_fluid_editing_and_backspace_collapse :: proc(t: ^testing.T) {
	cb := new(Codebase)
	defer free(cb)
	cb2 := new(Codebase)
	defer free(cb2)
	ed := new(Ast_Editor)
	defer free(ed)
	wire := make([]u8, 65536)
	defer delete(wire)

	// Start from empty `fn f(x: Int) -> Int { return ?; }`
	px, _ := param_make("x", .Int)
	hole_id, _ := ast_add_hole(cb, .Int)
	ret_id, _ := ast_add_return(cb, hole_id)
	stmts := [1]Node_Id{ret_id}
	body_id, _ := ast_add_block(cb, stmts[:])
	params := [1]Param{px}
	def_idx, ok_def := codebase_add_definition(cb, "f", params[:], .Int, body_id)
	testing.expect(t, ok_def, "f definition must register")

	ast_editor_init(ed, cb, def_idx)
	testing.expect_value(t, ed.selected_slot, Edit_Slot.Hole)

	// Type: x -> * -> 2 -> Tab -> + -> 1
	testing.expect(t, ast_editor_type_char(ed, cb, 'x'), "type x")
	testing.expect(t, ast_editor_type_char(ed, cb, '*'), "wrap with *")
	testing.expect(t, ast_editor_type_char(ed, cb, '2'), "type 2")
	testing.expect(t, ast_editor_action(ed, cb, .Next_Hole), "Tab expands to (x * 2) when no holes remain")
	testing.expect(t, ast_editor_type_char(ed, cb, '+'), "wrap (x * 2) with +")
	testing.expect(t, ast_editor_type_char(ed, cb, '1'), "type 1")
	testing.expect(t, ast_editor_commit_inline(ed, cb), "commit inline 1")

	// Verify emitted C contains exact expression `return ((x * 2) + 1);`.
	c_buf: [2048]u8
	c_len, c_ok := ast_emit_c(cb, c_buf[:])
	testing.expect(t, c_ok, "C emission must succeed")
	c_text := string(c_buf[:c_len])
	testing.expect(t, strings.contains(c_text, "long f(long x)"), "emitted C must declare long f(long x)")
	testing.expect(t, strings.contains(c_text, "return ((x * 2) + 1);"), "emitted C must contain return ((x * 2) + 1);")

	// Backspace on `1` collapses it cleanly back to a `?` Hole without corrupting AST.
	testing.expect(t, ast_editor_action(ed, cb, .Backspace), "Backspace on 1 collapses to Hole")
	testing.expect_value(t, ed.selected_slot, Edit_Slot.Hole)
	collapsed := node_get(cb, ed.selected_node)
	testing.expect(t, collapsed != nil && collapsed.kind == .Hole, "focused node must now be a valid Hole")

	// Round-trip the edited AST through MODAST1 to prove tree integrity.
	enc_len, enc_err := codebase_encode(cb, wire)
	testing.expect_value(t, enc_err, Codec_Error.Ok)
	testing.expect_value(t, codebase_decode(wire[:enc_len], cb2), Codec_Error.Ok)
}

@(test)
emit_c_and_lex_and_refusals :: proc(t: ^testing.T) {
	cb := new(Codebase)
	defer free(cb)
	wire := make([]u8, 65536)
	defer delete(wire)

	testing.expect(t, codebase_seed_sample(cb), "seed sample must succeed")

	// Refusals: empty buffer, tiny buffer, out-of-range def index for Lex.
	_, ok_c0 := ast_emit_c(cb, nil)
	testing.expect(t, !ok_c0, "ast_emit_c must refuse nil buffer")
	tiny: [8]u8
	_, ok_c_tiny := ast_emit_c(cb, tiny[:])
	testing.expect(t, !ok_c_tiny, "ast_emit_c must refuse too-small buffer")

	_, ok_l0 := ast_emit_lex(cb, 0, nil)
	testing.expect(t, !ok_l0, "ast_emit_lex must refuse nil buffer")
	_, ok_l_bad := ast_emit_lex(cb, 99, wire)
	testing.expect(t, !ok_l_bad, "ast_emit_lex must refuse out-of-range def index")
	_, ok_l_tiny := ast_emit_lex(cb, 0, tiny[:])
	testing.expect(t, !ok_l_tiny, "ast_emit_lex must refuse too-small buffer")

	// Valid C emission.
	c_len, c_ok := ast_emit_c(cb, wire)
	testing.expect(t, c_ok, "ast_emit_c must succeed on sample codebase")
	c_str := string(wire[:c_len])
	testing.expect(t, strings.contains(c_str, "long square(long x)"), "C output must contain square signature")
	testing.expect(t, strings.contains(c_str, "return (x * x);"), "C output must contain square body")
	testing.expect(t, strings.contains(c_str, "long n = square(7);"), "C output must resolve Def_Ref via Name_Table")

	// Valid Lex emission.
	lex_buf: [1024]u8
	l_len, l_ok := ast_emit_lex(cb, 0, lex_buf[:])
	testing.expect(t, l_ok, "ast_emit_lex must succeed on def 0")
	l_str := string(lex_buf[:l_len])
	testing.expect(t, strings.contains(l_str, "fn square(x: Int) -> Int"), "Lex output must contain fn header")
	testing.expect(t, strings.contains(l_str, "return (x * x)"), "Lex output must contain return expression")
}
