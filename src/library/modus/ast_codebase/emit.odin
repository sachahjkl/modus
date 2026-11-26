// Lowering from content-addressed AST definitions to freestanding C and Lex
// (src/md/features/codebase_ast.md).
package ast_codebase

@(private = "file")
Emit_Writer :: struct {
	buf:      []u8,
	pos:      int,
	overflow: bool,
}

@(private = "file")
ew_put :: proc "contextless" (w: ^Emit_Writer, text: string) {
	if w.overflow || len(text) == 0 {
		return
	}
	if w.pos + len(text) > len(w.buf) {
		w.overflow = true
		return
	}
	copy(w.buf[w.pos:w.pos + len(text)], text)
	w.pos += len(text)
}

@(private = "file")
ew_indent :: proc "contextless" (w: ^Emit_Writer, level: int) {
	for _ in 0 ..< level {
		ew_put(w, "    ")
	}
}

@(private = "file")
ew_i64 :: proc "contextless" (w: ^Emit_Writer, value: i64) {
	if w.overflow {
		return
	}
	if value == 0 {
		ew_put(w, "0")
		return
	}
	neg := value < 0
	mag := neg ? u64(-(value + 1)) + 1 : u64(value)
	tmp: [24]u8
	tlen := 0
	for mag > 0 && tlen < len(tmp) {
		tmp[tlen] = u8('0' + (mag % 10))
		mag /= 10
		tlen += 1
	}
	if neg {
		ew_put(w, "-")
	}
	out_buf: [24]u8
	for i in 0 ..< tlen {
		out_buf[i] = tmp[tlen - 1 - i]
	}
	ew_put(w, string(out_buf[:tlen]))
}

@(private = "file")
c_type_text :: proc "contextless" (kind: Type_Kind) -> string {
	switch kind {
	case .Unknown, .Int:
		return "long"
	case .Bool:
		return "int"
	case .Text:
		return "const char *"
	case .Void:
		return "void"
	}
	return "long"
}

@(private = "file")
emit_c_escaped_text :: proc "contextless" (w: ^Emit_Writer, text: string) {
	ew_put(w, "\"")
	for i in 0 ..< len(text) {
		ch := text[i]
		if ch == '"' || ch == '\\' {
			ew_put(w, "\\")
		}
		one := [1]u8{ch}
		ew_put(w, string(one[:]))
	}
	ew_put(w, "\"")
}

@(private = "file")
emit_def_ref_name :: proc "contextless" (w: ^Emit_Writer, cb: ^Codebase, ref_hash: [32]u8) {
	if name, found := codebase_find_name_by_hash(cb, ref_hash); found {
		ew_put(w, name)
		return
	}
	hex: [16]u8
	ew_put(w, "fn_")
	ew_put(w, hash_hex_prefix(ref_hash, hex[:], 8))
}

@(private = "file")
emit_c_expr :: proc "contextless" (w: ^Emit_Writer, cb: ^Codebase, id: Node_Id, depth: int) {
	if w.overflow || depth >= 128 {
		return
	}
	node := node_get(cb, id)
	if node == nil {
		ew_put(w, "0")
		return
	}
	switch node.kind {
	case .Hole:
		ew_put(w, "0 /* ? */")
	case .Int_Lit:
		ew_i64(w, node.int_value)
	case .Bool_Lit:
		ew_put(w, node.bool_value ? "1" : "0")
	case .Text_Lit:
		emit_c_escaped_text(w, node_name(node))
	case .Var:
		ew_put(w, node_name(node))
	case .Def_Ref:
		emit_def_ref_name(w, cb, node.ref_hash)
	case .Unary:
		ew_put(w, "(")
		ew_put(w, unary_op_text(node.unary_op))
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, ")")
	case .Binary:
		ew_put(w, "(")
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, " ")
		ew_put(w, bin_op_text(node.bin_op))
		ew_put(w, " ")
		emit_c_expr(w, cb, node.child_b, depth + 1)
		ew_put(w, ")")
	case .Call:
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, "(")
		for i in 0 ..< int(node.list_count) {
			if i > 0 {
				ew_put(w, ", ")
			}
			emit_c_expr(w, cb, cb.list_items[int(node.list_start) + i], depth + 1)
		}
		ew_put(w, ")")
	case .If_Expr:
		ew_put(w, "(")
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, " ? ")
		emit_c_expr(w, cb, node.child_b, depth + 1)
		ew_put(w, " : ")
		emit_c_expr(w, cb, node.child_c, depth + 1)
		ew_put(w, ")")
	case .Let_Stmt, .Return_Stmt, .Block:
		ew_put(w, "0")
	}
}

@(private = "file")
emit_c_stmt :: proc "contextless" (w: ^Emit_Writer, cb: ^Codebase, id: Node_Id, indent: int, depth: int) {
	if w.overflow || depth >= 128 {
		return
	}
	node := node_get(cb, id)
	if node == nil {
		return
	}
	switch node.kind {
	case .Block:
		for i in 0 ..< int(node.list_count) {
			emit_c_stmt(w, cb, cb.list_items[int(node.list_start) + i], indent, depth + 1)
		}
	case .Let_Stmt:
		ew_indent(w, indent)
		ew_put(w, "long ")
		ew_put(w, node_name(node))
		ew_put(w, " = ")
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, ";\n")
	case .Return_Stmt:
		ew_indent(w, indent)
		ew_put(w, "return ")
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, ";\n")
	case .If_Expr:
		ew_indent(w, indent)
		ew_put(w, "if (")
		emit_c_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, ") {\n")
		emit_c_stmt(w, cb, node.child_b, indent + 1, depth + 1)
		ew_indent(w, indent)
		ew_put(w, "} else {\n")
		emit_c_stmt(w, cb, node.child_c, indent + 1, depth + 1)
		ew_indent(w, indent)
		ew_put(w, "}\n")
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref, .Unary, .Binary, .Call:
		ew_indent(w, indent)
		emit_c_expr(w, cb, id, depth + 1)
		ew_put(w, ";\n")
	}
}

@(private = "file")
emit_c_signature :: proc "contextless" (w: ^Emit_Writer, cb: ^Codebase, def_index: int) {
	def := &cb.defs[def_index]
	ew_put(w, c_type_text(def.return_type))
	if def.return_type != .Text {
		ew_put(w, " ")
	}
	name := codebase_def_display_name(cb, def_index)
	if len(name) > 0 {
		ew_put(w, name)
	} else {
		hex: [16]u8
		ew_put(w, "fn_")
		ew_put(w, hash_hex_prefix(def.hash, hex[:], 8))
	}
	ew_put(w, "(")
	if def.param_count == 0 {
		ew_put(w, "void")
	} else {
		for p in 0 ..< int(def.param_count) {
			if p > 0 {
				ew_put(w, ", ")
			}
			ew_put(w, c_type_text(def.params[p].type))
			if def.params[p].type != .Text {
				ew_put(w, " ")
			}
			ew_put(w, param_name(&def.params[p]))
		}
	}
	ew_put(w, ")")
}

// ast_emit_c lowers the entire AST codebase to freestanding C using display
// names from Name_Table. Returns (0, false) if out cannot hold the output.
ast_emit_c :: proc "contextless" (cb: ^Codebase, out: []u8) -> (written: int, ok: bool) {
	if len(out) == 0 {
		return 0, false
	}
	w := Emit_Writer{buf = out}
	active_defs := 0
	for d in 0 ..< int(cb.def_count) {
		if cb.defs[d].active {
			active_defs += 1
		}
	}
	// Forward declarations when there are multiple definitions.
	if active_defs > 1 {
		for d in 0 ..< int(cb.def_count) {
			if !cb.defs[d].active {
				continue
			}
			emit_c_signature(&w, cb, d)
			ew_put(&w, ";\n")
		}
		ew_put(&w, "\n")
	}
	emitted := 0
	for d in 0 ..< int(cb.def_count) {
		if !cb.defs[d].active {
			continue
		}
		if emitted > 0 {
			ew_put(&w, "\n")
		}
		emit_c_signature(&w, cb, d)
		ew_put(&w, " {\n")
		emit_c_stmt(&w, cb, cb.defs[d].root, 1, 0)
		ew_put(&w, "}\n")
		emitted += 1
	}
	if w.overflow {
		return 0, false
	}
	return w.pos, true
}

@(private = "file")
emit_lex_expr :: proc "contextless" (w: ^Emit_Writer, cb: ^Codebase, id: Node_Id, depth: int) {
	if w.overflow || depth >= 128 {
		return
	}
	node := node_get(cb, id)
	if node == nil {
		ew_put(w, "?")
		return
	}
	switch node.kind {
	case .Hole:
		ew_put(w, "?")
	case .Int_Lit:
		ew_i64(w, node.int_value)
	case .Bool_Lit:
		ew_put(w, node.bool_value ? "true" : "false")
	case .Text_Lit:
		emit_c_escaped_text(w, node_name(node))
	case .Var:
		ew_put(w, node_name(node))
	case .Def_Ref:
		emit_def_ref_name(w, cb, node.ref_hash)
	case .Unary:
		ew_put(w, "(")
		ew_put(w, unary_op_text(node.unary_op))
		emit_lex_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, ")")
	case .Binary:
		ew_put(w, "(")
		emit_lex_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, " ")
		ew_put(w, bin_op_text(node.bin_op))
		ew_put(w, " ")
		emit_lex_expr(w, cb, node.child_b, depth + 1)
		ew_put(w, ")")
	case .Call:
		emit_lex_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, "(")
		for i in 0 ..< int(node.list_count) {
			if i > 0 {
				ew_put(w, ", ")
			}
			emit_lex_expr(w, cb, cb.list_items[int(node.list_start) + i], depth + 1)
		}
		ew_put(w, ")")
	case .If_Expr:
		ew_put(w, "if ")
		emit_lex_expr(w, cb, node.child_a, depth + 1)
		ew_put(w, " { ")
		emit_lex_expr(w, cb, node.child_b, depth + 1)
		ew_put(w, " } else { ")
		emit_lex_expr(w, cb, node.child_c, depth + 1)
		ew_put(w, " }")
	case .Let_Stmt:
		ew_put(w, "let ")
		ew_put(w, node_name(node))
		ew_put(w, " = ")
		emit_lex_expr(w, cb, node.child_a, depth + 1)
	case .Return_Stmt:
		ew_put(w, "return ")
		emit_lex_expr(w, cb, node.child_a, depth + 1)
	case .Block:
		ew_put(w, "{\n")
		for i in 0 ..< int(node.list_count) {
			ew_indent(w, 1)
			emit_lex_expr(w, cb, cb.list_items[int(node.list_start) + i], depth + 1)
			ew_put(w, "\n")
		}
		ew_put(w, "}")
	}
}

// ast_emit_lex lowers one AST definition to readable Lex syntax.
ast_emit_lex :: proc "contextless" (cb: ^Codebase, def_index: int, out: []u8) -> (written: int, ok: bool) {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active || len(out) == 0 {
		return 0, false
	}
	w := Emit_Writer{buf = out}
	def := &cb.defs[def_index]
	ew_put(&w, "fn ")
	name := codebase_def_display_name(cb, def_index)
	if len(name) > 0 {
		ew_put(&w, name)
	} else {
		hex: [16]u8
		ew_put(&w, "fn_")
		ew_put(&w, hash_hex_prefix(def.hash, hex[:], 8))
	}
	ew_put(&w, "(")
	for p in 0 ..< int(def.param_count) {
		if p > 0 {
			ew_put(&w, ", ")
		}
		ew_put(&w, param_name(&def.params[p]))
		ew_put(&w, ": ")
		ew_put(&w, type_kind_name(def.params[p].type))
	}
	ew_put(&w, ") -> ")
	ew_put(&w, type_kind_name(def.return_type))
	ew_put(&w, " ")
	emit_lex_expr(&w, cb, def.root, 0)
	ew_put(&w, "\n")
	if w.overflow {
		return 0, false
	}
	return w.pos, true
}
