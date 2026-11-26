// Dion-style fluid text-like structural code editor engine
// (src/md/features/codebase_ast.md).
//
// Projects the active definition into flat Projected_Line and Projected_Token
// arrays whenever the AST changes or a definition is selected, NEVER inside
// draw(). Cursor navigation, inline literal/identifier editing, operator
// wrapping, call wrapping, hole jumping, and O(1) renaming all maintain a
// valid AST at every keystroke.
package ast_codebase

import "modus:graphics"

// Format property: maximum display bytes for one projected token.
TOKEN_TEXT_LIMIT :: 64

// Plan value: maximum projected lines for one active definition.
MAX_PROJECTED_LINES :: 256

// Plan value: maximum projected tokens for one active definition.
MAX_PROJECTED_TOKENS :: 2048

// Plan value: maximum shrink-selection history depth for Alt+Up / Alt+Down.
SHRINK_STACK_CAPACITY :: 32

// Closed set of token roles in a projected AST line.
Edit_Slot :: enum u8 {
	Punctuation = 0,
	Def_Name    = 1,
	Param_Name  = 2,
	Param_Type  = 3,
	Return_Type = 4,
	Hole        = 5,
	Node_Expr   = 6,
	Let_Name    = 7,
	Operator    = 8,
}

// Closed set of editor actions driven by keys or action-bar buttons.
Ast_Edit_Action :: enum u8 {
	Left             = 0,
	Right            = 1,
	Up               = 2,
	Down             = 3,
	Next_Hole        = 4,
	Prev_Hole        = 5,
	Expand_Selection = 6,
	Shrink_Selection = 7,
	Insert_Stmt      = 8,
	Backspace        = 9,
	Begin_Rename     = 10,
	Commit_Inline    = 11,
	Cancel_Inline    = 12,
}

// Closed set of inline text editing targets.
Inline_Target :: enum u8 {
	None       = 0,
	Node_Int   = 1,
	Node_Ident = 2,
	Node_Text  = 3,
	Def_Name   = 4,
	Param_Name = 5,
	Let_Name   = 6,
}

// One projected token with precomputed syntax color class and selection flag
// so draw() performs zero AST traversals.
Projected_Token :: struct {
	text:         [TOKEN_TEXT_LIMIT]u8,
	text_len:     u8,
	col_start:    u16,
	col_end:      u16,
	code_class:   graphics.Code_Class,
	node_id:      Node_Id,
	slot:         Edit_Slot,
	slot_index:   u16,
	interactive:  bool,
	in_selection: bool,
}

// One projected display line referencing a slice of Ast_Editor.tokens.
Projected_Line :: struct {
	token_start: u16,
	token_count: u16,
	indent:      u8,
	total_cols:  u16,
}

// Complete state of the structural editor. Keep in static/module memory.
Ast_Editor :: struct {
	active_def:      int,
	lines:           [MAX_PROJECTED_LINES]Projected_Line,
	line_count:      int,
	tokens:          [MAX_PROJECTED_TOKENS]Projected_Token,
	token_count:     int,
	cursor_line:     int,
	cursor_token:    int, // Index into tokens[] (global token index).
	selected_node:   Node_Id,
	selected_slot:   Edit_Slot,
	selected_index:  u16, // Parameter index when focusing a Param_Name/Param_Type.
	shrink_stack:    [SHRINK_STACK_CAPACITY]Node_Id,
	shrink_depth:    int,
	inline_active:   bool,
	inline_target:   Inline_Target,
	inline_def:      int,
	inline_param:    int,
	inline_node:     Node_Id,
	inline_buf:      [IDENT_LIMIT]u8,
	inline_len:      int,
	last_hash_changed: bool,
}

token_text :: proc "contextless" (tok: ^Projected_Token) -> string {
	return string(tok.text[:tok.text_len])
}

editor_inline_text :: proc "contextless" (ed: ^Ast_Editor) -> string {
	return string(ed.inline_buf[:ed.inline_len])
}

// ast_editor_init initializes the editor on def_index and runs the initial
// projection.
ast_editor_init :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, def_index: int = 0) {
	ed^ = {}
	if int(cb.def_count) == 0 {
		ed.active_def = -1
		return
	}
	ed.active_def = clamp(def_index, 0, int(cb.def_count) - 1)
	ed.selected_node = NODE_NONE
	ed.selected_slot = .Hole
	ast_editor_project(ed, cb)
	// Focus the first hole if one exists, otherwise the first interactive token.
	if !focus_first_hole(ed, cb) {
		focus_first_interactive(ed, cb)
	}
}

// ast_editor_select_def switches the active definition, committing any inline
// edit first, and recomputes projection once.
ast_editor_select_def :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, def_index: int) -> bool {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return false
	}
	if ed.inline_active {
		_ = ast_editor_commit_inline(ed, cb)
	}
	ed.active_def = def_index
	ed.selected_node = NODE_NONE
	ed.selected_slot = .Punctuation
	ed.shrink_depth = 0
	ast_editor_project(ed, cb)
	if !focus_first_hole(ed, cb) {
		focus_first_interactive(ed, cb)
	}
	return true
}

// --- Projection builder ---

@(private = "file")
proj_line_begin :: proc "contextless" (ed: ^Ast_Editor, indent: u8) -> bool {
	if ed.line_count >= MAX_PROJECTED_LINES {
		return false
	}
	line := &ed.lines[ed.line_count]
	line^ = Projected_Line{
		token_start = u16(ed.token_count),
		token_count = 0,
		indent      = indent,
		total_cols  = u16(indent) * 4,
	}
	ed.line_count += 1
	return true
}

@(private = "file")
proj_emit :: proc "contextless" (ed: ^Ast_Editor, text: string, class: graphics.Code_Class, node_id: Node_Id, slot: Edit_Slot, interactive: bool, slot_index: u16 = 0) {
	if ed.line_count == 0 || ed.token_count >= MAX_PROJECTED_TOKENS {
		return
	}
	line := &ed.lines[ed.line_count - 1]
	tok := &ed.tokens[ed.token_count]
	tok^ = {}
	n := min(len(text), TOKEN_TEXT_LIMIT)
	copy(tok.text[:n], text[:n])
	tok.text_len = u8(n)
	tok.col_start = line.total_cols
	tok.col_end = line.total_cols + u16(n)
	tok.code_class = class
	tok.node_id = node_id
	tok.slot = slot
	tok.slot_index = slot_index
	tok.interactive = interactive
	line.total_cols = tok.col_end
	line.token_count += 1
	ed.token_count += 1
}

@(private = "file")
format_i64 :: proc "contextless" (buf: []u8, value: i64) -> string {
	if len(buf) == 0 {
		return ""
	}
	if value == 0 {
		buf[0] = '0'
		return string(buf[:1])
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
	pos := 0
	if neg && pos < len(buf) {
		buf[pos] = '-'
		pos += 1
	}
	for i := tlen - 1; i >= 0 && pos < len(buf); i -= 1 {
		buf[pos] = tmp[i]
		pos += 1
	}
	return string(buf[:pos])
}

@(private = "file")
project_expr :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, id: Node_Id, depth: int) {
	if depth >= 128 {
		proj_emit(ed, "...", .Comment, id, .Punctuation, false)
		return
	}
	node := node_get(cb, id)
	if node == nil {
		proj_emit(ed, "?", .Directive, id, .Hole, true)
		return
	}
	// If inline editing targets this exact node, display the live inline buffer.
	if ed.inline_active && ed.inline_node == id && (ed.inline_target == .Node_Int || ed.inline_target == .Node_Ident || ed.inline_target == .Node_Text) {
		text := editor_inline_text(ed)
		if ed.inline_target == .Node_Text {
			buf: [TOKEN_TEXT_LIMIT]u8
			buf[0] = '"'
			n := min(len(text), TOKEN_TEXT_LIMIT - 2)
			copy(buf[1:1 + n], text[:n])
			buf[1 + n] = '"'
			proj_emit(ed, string(buf[:n + 2]), .Literal, id, .Node_Expr, true)
			return
		}
		class := ed.inline_target == .Node_Int ? graphics.Code_Class.Literal : graphics.Code_Class.None
		if len(text) == 0 {
			proj_emit(ed, "?", .Directive, id, .Hole, true)
		} else {
			proj_emit(ed, text, class, id, .Node_Expr, true)
		}
		return
	}

	switch node.kind {
	case .Hole:
		proj_emit(ed, "?", .Directive, id, .Hole, true)
	case .Int_Lit:
		buf: [24]u8
		proj_emit(ed, format_i64(buf[:], node.int_value), .Literal, id, .Node_Expr, true)
	case .Bool_Lit:
		proj_emit(ed, node.bool_value ? "true" : "false", .Literal, id, .Node_Expr, true)
	case .Text_Lit:
		buf: [TOKEN_TEXT_LIMIT]u8
		buf[0] = '"'
		n := min(int(node.name_len), TOKEN_TEXT_LIMIT - 2)
		copy(buf[1:1 + n], node.name[:n])
		buf[1 + n] = '"'
		proj_emit(ed, string(buf[:n + 2]), .Literal, id, .Node_Expr, true)
	case .Var:
		proj_emit(ed, node_name(node), .None, id, .Node_Expr, true)
	case .Def_Ref:
		if name, found := codebase_find_name_by_hash(cb, node.ref_hash); found {
			proj_emit(ed, name, .Name, id, .Node_Expr, true)
		} else {
			hex_buf: [16]u8
			hex_buf[0] = '#'
			_ = hash_hex_prefix(node.ref_hash, hex_buf[1:], 8)
			proj_emit(ed, string(hex_buf[:9]), .Name, id, .Node_Expr, true)
		}
	case .Unary:
		proj_emit(ed, "(", .Punctuation, id, .Punctuation, false)
		proj_emit(ed, unary_op_text(node.unary_op), .Punctuation, id, .Operator, true)
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, ")", .Punctuation, id, .Punctuation, false)
	case .Binary:
		proj_emit(ed, "(", .Punctuation, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, " ", .None, id, .Punctuation, false)
		proj_emit(ed, bin_op_text(node.bin_op), .Punctuation, id, .Operator, true)
		proj_emit(ed, " ", .None, id, .Punctuation, false)
		project_expr(ed, cb, node.child_b, depth + 1)
		proj_emit(ed, ")", .Punctuation, id, .Punctuation, false)
	case .Call:
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, "(", .Punctuation, id, .Punctuation, false)
		for i in 0 ..< int(node.list_count) {
			if i > 0 {
				proj_emit(ed, ", ", .Punctuation, id, .Punctuation, false)
			}
			project_expr(ed, cb, cb.list_items[int(node.list_start) + i], depth + 1)
		}
		proj_emit(ed, ")", .Punctuation, id, .Punctuation, false)
	case .If_Expr:
		proj_emit(ed, "if ", .Keyword, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, " { ", .Punctuation, id, .Punctuation, false)
		project_expr(ed, cb, node.child_b, depth + 1)
		proj_emit(ed, " } else { ", .Keyword, id, .Punctuation, false)
		project_expr(ed, cb, node.child_c, depth + 1)
		proj_emit(ed, " }", .Punctuation, id, .Punctuation, false)
	case .Let_Stmt:
		proj_emit(ed, "let ", .Keyword, id, .Punctuation, false)
		if ed.inline_active && ed.inline_target == .Let_Name && ed.inline_node == id {
			proj_emit(ed, editor_inline_text(ed), .None, id, .Let_Name, true)
		} else {
			proj_emit(ed, node_name(node), .None, id, .Let_Name, true)
		}
		proj_emit(ed, " = ", .Punctuation, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
		if node.child_b != NODE_NONE {
			proj_emit(ed, " in ", .Keyword, id, .Punctuation, false)
			project_expr(ed, cb, node.child_b, depth + 1)
		}
	case .Return_Stmt:
		proj_emit(ed, "return ", .Keyword, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
	case .Block:
		proj_emit(ed, "{ ... }", .Punctuation, id, .Node_Expr, true)
	}
}

@(private = "file")
project_stmt :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, id: Node_Id, indent: u8, depth: int) {
	node := node_get(cb, id)
	if node == nil || depth >= 128 {
		return
	}
	switch node.kind {
	case .Block:
		for i in 0 ..< int(node.list_count) {
			stmt_id := cb.list_items[int(node.list_start) + i]
			project_stmt(ed, cb, stmt_id, indent, depth + 1)
		}
	case .Let_Stmt:
		if !proj_line_begin(ed, indent) {
			return
		}
		proj_emit(ed, "let ", .Keyword, id, .Punctuation, false)
		if ed.inline_active && ed.inline_target == .Let_Name && ed.inline_node == id {
			proj_emit(ed, editor_inline_text(ed), .None, id, .Let_Name, true)
		} else {
			proj_emit(ed, node_name(node), .None, id, .Let_Name, true)
		}
		proj_emit(ed, " = ", .Punctuation, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, ";", .Punctuation, id, .Punctuation, false)
	case .Return_Stmt:
		if !proj_line_begin(ed, indent) {
			return
		}
		proj_emit(ed, "return ", .Keyword, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, ";", .Punctuation, id, .Punctuation, false)
	case .If_Expr:
		if !proj_line_begin(ed, indent) {
			return
		}
		proj_emit(ed, "if ", .Keyword, id, .Punctuation, false)
		project_expr(ed, cb, node.child_a, depth + 1)
		proj_emit(ed, " {", .Punctuation, id, .Punctuation, false)
		project_stmt(ed, cb, node.child_b, indent + 1, depth + 1)
		if proj_line_begin(ed, indent) {
			proj_emit(ed, "} else {", .Keyword, id, .Punctuation, false)
		}
		project_stmt(ed, cb, node.child_c, indent + 1, depth + 1)
		if proj_line_begin(ed, indent) {
			proj_emit(ed, "}", .Punctuation, id, .Punctuation, false)
		}
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref, .Unary, .Binary, .Call:
		if !proj_line_begin(ed, indent) {
			return
		}
		project_expr(ed, cb, id, depth + 1)
		proj_emit(ed, ";", .Punctuation, id, .Punctuation, false)
	}
}

@(private = "file")
is_descendant_of :: proc "contextless" (cb: ^Codebase, id: Node_Id, ancestor: Node_Id) -> bool {
	if ancestor == NODE_NONE || id == NODE_NONE {
		return false
	}
	cur := id
	for step := 0; step < 256 && cur != NODE_NONE; step += 1 {
		if cur == ancestor {
			return true
		}
		node := node_get(cb, cur)
		if node == nil {
			return false
		}
		cur = node.parent
	}
	return false
}

// ast_editor_project rebuilds all projected lines, tokens, and precomputed
// selection highlights for the active definition. Never called inside draw().
ast_editor_project :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) {
	ed.line_count = 0
	ed.token_count = 0
	if ed.active_def < 0 || ed.active_def >= int(cb.def_count) || !cb.defs[ed.active_def].active {
		ed.cursor_line = 0
		ed.cursor_token = -1
		return
	}
	def := &cb.defs[ed.active_def]

	// Header line: fn <name>(<p0>: <T0>, ...) -> <Ret> {
	if proj_line_begin(ed, 0) {
		proj_emit(ed, "fn ", .Keyword, NODE_NONE, .Punctuation, false)
		def_name := codebase_def_display_name(cb, ed.active_def)
		if ed.inline_active && ed.inline_target == .Def_Name && ed.inline_def == ed.active_def {
			def_name = editor_inline_text(ed)
		}
		if len(def_name) == 0 {
			def_name = "_"
		}
		proj_emit(ed, def_name, .Name, NODE_NONE, .Def_Name, true)
		proj_emit(ed, "(", .Punctuation, NODE_NONE, .Punctuation, false)
		for p in 0 ..< int(def.param_count) {
			if p > 0 {
				proj_emit(ed, ", ", .Punctuation, NODE_NONE, .Punctuation, false)
			}
			pname := param_name(&def.params[p])
			if ed.inline_active && ed.inline_target == .Param_Name && ed.inline_def == ed.active_def && ed.inline_param == p {
				pname = editor_inline_text(ed)
			}
			proj_emit(ed, pname, .None, NODE_NONE, .Param_Name, true, u16(p))
			proj_emit(ed, ": ", .Punctuation, NODE_NONE, .Punctuation, false)
			proj_emit(ed, type_kind_name(def.params[p].type), .Type, NODE_NONE, .Param_Type, false, u16(p))
		}
		proj_emit(ed, ") -> ", .Punctuation, NODE_NONE, .Punctuation, false)
		proj_emit(ed, type_kind_name(def.return_type), .Type, NODE_NONE, .Return_Type, false)
		proj_emit(ed, " {", .Punctuation, NODE_NONE, .Punctuation, false)
	}

	// Body statements.
	root := node_get(cb, def.root)
	if root != nil && root.kind == .Block {
		project_stmt(ed, cb, def.root, 1, 0)
	} else {
		project_stmt(ed, cb, def.root, 1, 0)
	}

	// Closing brace line.
	if proj_line_begin(ed, 0) {
		proj_emit(ed, "}", .Punctuation, NODE_NONE, .Punctuation, false)
	}

	// Re-sync cursor_token & cursor_line to selected_node / selected_slot.
	sync_cursor_from_selection(ed, cb)
}

@(private = "file")
sync_cursor_from_selection :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) {
	matched := -1
	if ed.selected_slot == .Def_Name {
		for i in 0 ..< ed.token_count {
			if ed.tokens[i].slot == .Def_Name {
				matched = i
				break
			}
		}
	} else if ed.selected_slot == .Param_Name {
		for i in 0 ..< ed.token_count {
			if ed.tokens[i].slot == .Param_Name && ed.tokens[i].slot_index == ed.selected_index {
				matched = i
				break
			}
		}
	} else if ed.selected_node != NODE_NONE {
		// Prefer exact slot match first, then any interactive token of the node.
		for i in 0 ..< ed.token_count {
			tok := &ed.tokens[i]
			if tok.node_id == ed.selected_node && tok.interactive && tok.slot == ed.selected_slot {
				matched = i
				break
			}
		}
		if matched < 0 {
			for i in 0 ..< ed.token_count {
				tok := &ed.tokens[i]
				if tok.node_id == ed.selected_node && tok.interactive {
					matched = i
					break
				}
			}
		}
		if matched < 0 {
			// Compound selection (e.g. expanded to Return_Stmt or Binary): focus
			// its operator or first descendant token while keeping selected_node.
			for i in 0 ..< ed.token_count {
				tok := &ed.tokens[i]
				if tok.interactive && is_descendant_of(cb, tok.node_id, ed.selected_node) {
					matched = i
					break
				}
			}
		}
	}
	if matched < 0 {
		for i in 0 ..< ed.token_count {
			if ed.tokens[i].interactive {
				matched = i
				break
			}
		}
	}
	ed.cursor_token = matched
	ed.cursor_line = line_of_token(ed, matched)

	// Precompute in_selection flags for O(1) rendering in draw().
	for i in 0 ..< ed.token_count {
		tok := &ed.tokens[i]
		if ed.selected_node != NODE_NONE {
			tok.in_selection = is_descendant_of(cb, tok.node_id, ed.selected_node)
		} else {
			tok.in_selection = (i == ed.cursor_token)
		}
	}
}

@(private = "file")
line_of_token :: proc "contextless" (ed: ^Ast_Editor, token_idx: int) -> int {
	if token_idx < 0 || token_idx >= ed.token_count {
		return 0
	}
	for l in 0 ..< ed.line_count {
		start := int(ed.lines[l].token_start)
		end := start + int(ed.lines[l].token_count)
		if token_idx >= start && token_idx < end {
			return l
		}
	}
	return 0
}

@(private = "file")
focus_token :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, token_idx: int) {
	if token_idx < 0 || token_idx >= ed.token_count {
		return
	}
	tok := &ed.tokens[token_idx]
	ed.cursor_token = token_idx
	ed.cursor_line = line_of_token(ed, token_idx)
	ed.selected_node = tok.node_id
	ed.selected_slot = tok.slot
	ed.selected_index = tok.slot_index
	ed.shrink_depth = 0
	sync_cursor_from_selection(ed, cb)
}

@(private = "file")
focus_first_hole :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> bool {
	for i in 0 ..< ed.token_count {
		if ed.tokens[i].slot == .Hole {
			focus_token(ed, cb, i)
			return true
		}
	}
	return false
}

@(private = "file")
focus_first_interactive :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) {
	for i in 0 ..< ed.token_count {
		if ed.tokens[i].interactive {
			focus_token(ed, cb, i)
			return
		}
	}
}

// --- Lexical scope resolution for fluid typing ---

@(private = "file")
resolve_local_var_in_def :: proc "contextless" (cb: ^Codebase, def_index: int, name: string, before_node: Node_Id) -> (slot: u16, found: bool) {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return UNRESOLVED_VAR_SLOT, false
	}
	def := &cb.defs[def_index]
	// Walk enclosing blocks upward to check preceding Let_Stmt bindings first.
	cur := before_node
	for step := 0; step < 128 && cur != NODE_NONE; step += 1 {
		node := node_get(cb, cur)
		if node == nil {
			break
		}
		parent_id := node.parent
		parent := node_get(cb, parent_id)
		if parent != nil && parent.kind == .Block {
			for i in 0 ..< int(parent.list_count) {
				stmt_id := cb.list_items[int(parent.list_start) + i]
				if stmt_id == cur {
					break
				}
				stmt := node_get(cb, stmt_id)
				if stmt != nil && stmt.kind == .Let_Stmt && node_name(stmt) == name {
					return stmt.var_slot, true
				}
			}
		} else if parent != nil && parent.kind == .Let_Stmt && parent.child_b == cur {
			if node_name(parent) == name {
				return parent.var_slot, true
			}
		}
		cur = parent_id
	}
	// Check function parameters.
	for p in 0 ..< int(def.param_count) {
		if param_name(&def.params[p]) == name {
			return u16(p), true
		}
	}
	return UNRESOLVED_VAR_SLOT, false
}

// next_free_var_slot finds a fresh local slot number for a new Let_Stmt in def.
@(private = "file")
next_free_var_slot :: proc "contextless" (cb: ^Codebase, def_index: int) -> u16 {
	def := &cb.defs[def_index]
	highest := u16(def.param_count)
	for i in 0 ..< int(cb.node_count) {
		n := &cb.nodes[i]
		if n.kind == .Let_Stmt && n.var_slot != UNRESOLVED_VAR_SLOT && n.var_slot >= highest {
			highest = n.var_slot + 1
		}
	}
	return highest
}

@(private = "file")
parse_i64_digits :: proc "contextless" (s: string) -> (val: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	acc: u64 = 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		digit := u64(ch - '0')
		if acc > (u64(max(i64)) - digit) / 10 {
			return 0, false
		}
		acc = acc * 10 + digit
	}
	return i64(acc), true
}

@(private = "file")
apply_inline_expr_live :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) {
	node := node_get(cb, ed.inline_node)
	if node == nil {
		return
	}
	text := editor_inline_text(ed)
	if len(text) == 0 {
		node.kind = .Hole
		node.name_len = 0
		node.int_value = 0
		return
	}
	switch ed.inline_target {
	case .Node_Int:
		if val, ok := parse_i64_digits(text); ok {
			node.kind = .Int_Lit
			node.int_value = val
			node.type_hint = .Int
		}
	case .Node_Ident:
		if text == "true" {
			node.kind = .Bool_Lit
			node.bool_value = true
			node.type_hint = .Bool
		} else if text == "false" {
			node.kind = .Bool_Lit
			node.bool_value = false
			node.type_hint = .Bool
		} else if slot, found := resolve_local_var_in_def(cb, ed.active_def, text, ed.inline_node); found {
			node.kind = .Var
			node.var_slot = slot
			node.name = {}
			node.name_len = u8(len(text))
			copy(node.name[:len(text)], text)
		} else if name_idx, found_def := codebase_find_name(cb, text); found_def {
			node.kind = .Def_Ref
			node.ref_hash = cb.names[name_idx].def_hash
			node.name_len = 0
		} else {
			node.kind = .Var
			node.var_slot = UNRESOLVED_VAR_SLOT
			node.name = {}
			node.name_len = u8(len(text))
			copy(node.name[:len(text)], text)
		}
	case .Node_Text:
		node.kind = .Text_Lit
		node.name = {}
		node.name_len = u8(len(text))
		copy(node.name[:len(text)], text)
	case .None, .Def_Name, .Param_Name, .Let_Name:
	}
}

// ast_editor_begin_rename starts an inline rename on the focused definition,
// parameter, or let binding.
ast_editor_begin_rename :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> bool {
	if ed.active_def < 0 || ed.active_def >= int(cb.def_count) {
		return false
	}
	if ed.inline_active {
		_ = ast_editor_commit_inline(ed, cb)
	}
	def := &cb.defs[ed.active_def]

	// Determine rename target from current focus.
	if ed.selected_slot == .Param_Name && int(ed.selected_index) < int(def.param_count) {
		pname := param_name(&def.params[ed.selected_index])
		ed.inline_active = true
		ed.inline_target = .Param_Name
		ed.inline_def = ed.active_def
		ed.inline_param = int(ed.selected_index)
		ed.inline_node = NODE_NONE
		ed.inline_buf = {}
		ed.inline_len = len(pname)
		copy(ed.inline_buf[:ed.inline_len], pname)
		ast_editor_project(ed, cb)
		return true
	}

	if node := node_get(cb, ed.selected_node); node != nil {
		if node.kind == .Let_Stmt && ed.selected_slot == .Let_Name {
			lname := node_name(node)
			ed.inline_active = true
			ed.inline_target = .Let_Name
			ed.inline_def = ed.active_def
			ed.inline_node = ed.selected_node
			ed.inline_buf = {}
			ed.inline_len = len(lname)
			copy(ed.inline_buf[:ed.inline_len], lname)
			ast_editor_project(ed, cb)
			return true
		}
		if node.kind == .Var && int(node.var_slot) < int(def.param_count) {
			pname := param_name(&def.params[node.var_slot])
			ed.inline_active = true
			ed.inline_target = .Param_Name
			ed.inline_def = ed.active_def
			ed.inline_param = int(node.var_slot)
			ed.inline_node = NODE_NONE
			ed.selected_slot = .Param_Name
			ed.selected_index = node.var_slot
			ed.selected_node = NODE_NONE
			ed.inline_buf = {}
			ed.inline_len = len(pname)
			copy(ed.inline_buf[:ed.inline_len], pname)
			ast_editor_project(ed, cb)
			return true
		}
		if node.kind == .Def_Ref {
			if target_def, found := codebase_find_def_by_hash(cb, node.ref_hash); found {
				dname := codebase_def_display_name(cb, target_def)
				ed.inline_active = true
				ed.inline_target = .Def_Name
				ed.inline_def = target_def
				ed.inline_node = NODE_NONE
				ed.inline_buf = {}
				ed.inline_len = len(dname)
				copy(ed.inline_buf[:ed.inline_len], dname)
				ast_editor_project(ed, cb)
				return true
			}
		}
	}

	// Default: rename the active definition itself.
	dname := codebase_def_display_name(cb, ed.active_def)
	ed.inline_active = true
	ed.inline_target = .Def_Name
	ed.inline_def = ed.active_def
	ed.inline_node = NODE_NONE
	ed.selected_node = NODE_NONE
	ed.selected_slot = .Def_Name
	ed.inline_buf = {}
	ed.inline_len = len(dname)
	copy(ed.inline_buf[:ed.inline_len], dname)
	ast_editor_project(ed, cb)
	return true
}

// ast_editor_commit_inline applies an active inline edit and re-projects.
// Returns ok=false only if a rename was refused (empty, invalid, or duplicate).
ast_editor_commit_inline :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> (ok: bool) {
	if !ed.inline_active {
		return true
	}
	target := ed.inline_target
	text := editor_inline_text(ed)
	ed.inline_active = false
	ed.inline_target = .None
	ed.last_hash_changed = false

	switch target {
	case .None:
		return true
	case .Def_Name:
		renamed := codebase_rename_definition(cb, ed.inline_def, text)
		ast_editor_project(ed, cb)
		return renamed
	case .Param_Name:
		renamed := codebase_rename_param(cb, ed.inline_def, ed.inline_param, text)
		ast_editor_project(ed, cb)
		return renamed
	case .Let_Name:
		if !ident_valid(text) {
			ast_editor_project(ed, cb)
			return false
		}
		if node := node_get(cb, ed.inline_node); node != nil && node.kind == .Let_Stmt {
			node.name = {}
			node.name_len = u8(len(text))
			copy(node.name[:len(text)], text)
			rename_var_slot_in_subtree(cb, cb.defs[ed.active_def].root, node.var_slot, text)
		}
		ast_editor_project(ed, cb)
		return true
	case .Node_Int, .Node_Ident, .Node_Text:
		old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
		ed.last_hash_changed = old_h != new_h
		ast_editor_project(ed, cb)
		return true
	}
	return true
}

@(private = "file")
wrap_with_binary :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, op: Bin_Op) -> bool {
	if ed.selected_node == NODE_NONE {
		return false
	}
	target := node_get(cb, ed.selected_node)
	if target == nil {
		return false
	}
	// Do not wrap statements or blocks directly with a binary operator.
	if target.kind == .Block || target.kind == .Let_Stmt || target.kind == .Return_Stmt {
		return false
	}
	rhs_hole, ok_hole := ast_add_hole(cb, target.type_hint)
	if !ok_hole {
		return false
	}
	bin_id, ok_bin := node_alloc(cb, Node{kind = .Binary, bin_op = op, child_a = ed.selected_node, child_b = rhs_hole})
	if !ok_bin {
		return false
	}
	if !codebase_replace_child(cb, ed.active_def, ed.selected_node, bin_id) {
		return false
	}
	cb.nodes[ed.selected_node - 1].parent = bin_id
	cb.nodes[rhs_hole - 1].parent = bin_id

	old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
	ed.last_hash_changed = old_h != new_h
	ed.selected_node = rhs_hole
	ed.selected_slot = .Hole
	ed.shrink_depth = 0
	ast_editor_project(ed, cb)
	return true
}

@(private = "file")
wrap_with_unary :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, op: Unary_Op) -> bool {
	if ed.selected_node == NODE_NONE {
		return false
	}
	target := node_get(cb, ed.selected_node)
	if target == nil {
		return false
	}
	inner, ok_hole := ast_add_hole(cb, op == .Not ? .Bool : .Int)
	if !ok_hole {
		return false
	}
	unary_id, ok_un := node_alloc(cb, Node{kind = .Unary, unary_op = op, child_a = inner})
	if !ok_un {
		return false
	}
	if !codebase_replace_child(cb, ed.active_def, ed.selected_node, unary_id) {
		return false
	}
	cb.nodes[inner - 1].parent = unary_id
	old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
	ed.last_hash_changed = old_h != new_h
	ed.selected_node = inner
	ed.selected_slot = .Hole
	ed.shrink_depth = 0
	ast_editor_project(ed, cb)
	return true
}

@(private = "file")
wrap_with_call :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> bool {
	if ed.selected_node == NODE_NONE {
		return false
	}
	target := node_get(cb, ed.selected_node)
	if target == nil || (target.kind != .Def_Ref && target.kind != .Hole) {
		return false
	}
	arg_count := 1
	arg_types: [MAX_PARAMS]Type_Kind
	if target.kind == .Def_Ref {
		if callee_idx, found := codebase_find_def_by_hash(cb, target.ref_hash); found {
			arg_count = int(cb.defs[callee_idx].param_count)
			for i in 0 ..< arg_count {
				arg_types[i] = cb.defs[callee_idx].params[i].type
			}
		}
	}
	args: [MAX_PARAMS]Node_Id
	for i in 0 ..< arg_count {
		h, ok_h := ast_add_hole(cb, arg_types[i])
		if !ok_h {
			return false
		}
		args[i] = h
	}
	start, ok_list := list_alloc(cb, args[:arg_count])
	if !ok_list {
		return false
	}
	call_id, ok_call := node_alloc(cb, Node{kind = .Call, child_a = ed.selected_node, list_start = start, list_count = u16(arg_count)})
	if !ok_call {
		return false
	}
	if !codebase_replace_child(cb, ed.active_def, ed.selected_node, call_id) {
		return false
	}
	cb.nodes[ed.selected_node - 1].parent = call_id
	for i in 0 ..< arg_count {
		cb.nodes[args[i] - 1].parent = call_id
	}
	old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
	ed.last_hash_changed = old_h != new_h
	if target.kind == .Hole {
		ed.selected_node = ed.selected_node
		ed.selected_slot = .Hole
	} else if arg_count > 0 {
		ed.selected_node = args[0]
		ed.selected_slot = .Hole
	} else {
		ed.selected_node = call_id
		ed.selected_slot = .Node_Expr
	}
	ed.shrink_depth = 0
	ast_editor_project(ed, cb)
	return true
}

@(private = "file")
insert_statement_in_block :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> bool {
	if ed.active_def < 0 || ed.active_def >= int(cb.def_count) {
		return false
	}
	// Walk upward from selected_node to find the enclosing Block and statement.
	stmt_id := ed.selected_node
	block_id := NODE_NONE
	for step := 0; step < 128 && stmt_id != NODE_NONE; step += 1 {
		n := node_get(cb, stmt_id)
		if n == nil {
			break
		}
		if n.parent == NODE_NONE {
			if n.kind == .Block {
				block_id = stmt_id
				stmt_id = NODE_NONE
			}
			break
		}
		p := node_get(cb, n.parent)
		if p != nil && p.kind == .Block {
			block_id = n.parent
			break
		}
		stmt_id = n.parent
	}
	if block_id == NODE_NONE {
		root := node_get(cb, cb.defs[ed.active_def].root)
		if root != nil && root.kind == .Block {
			block_id = cb.defs[ed.active_def].root
		} else {
			return false
		}
	}
	block := node_get(cb, block_id)
	if block == nil {
		return false
	}
	old_count := int(block.list_count)
	if old_count + 1 > MAX_LIST_ITEMS || u64(cb.list_count) + u64(old_count + 1) > MAX_LIST_ITEMS {
		return false
	}

	// Build a fresh Let_Stmt with a unique default name and `?` value hole.
	val_hole, ok_h := ast_add_hole(cb, .Int)
	if !ok_h {
		return false
	}
	slot := next_free_var_slot(cb, ed.active_def)
	name_buf: [16]u8
	name_buf[0] = 'v'
	digits := format_i64(name_buf[1:], i64(slot))
	let_name := string(name_buf[:1 + len(digits)])
	new_stmt, ok_let := ast_add_let(cb, slot, let_name, val_hole)
	if !ok_let {
		return false
	}

	// Determine insertion position: before Return_Stmt, else right after stmt_id.
	insert_at := old_count
	for i in 0 ..< old_count {
		if cb.list_items[int(block.list_start) + i] == stmt_id {
			stmt_node := node_get(cb, stmt_id)
			if stmt_node != nil && stmt_node.kind == .Return_Stmt {
				insert_at = i
			} else {
				insert_at = i + 1
			}
			break
		}
	}

	new_start := cb.list_count
	for i in 0 ..< insert_at {
		cb.list_items[int(new_start) + i] = cb.list_items[int(block.list_start) + i]
	}
	cb.list_items[int(new_start) + insert_at] = new_stmt
	for i in insert_at ..< old_count {
		cb.list_items[int(new_start) + i + 1] = cb.list_items[int(block.list_start) + i]
	}
	cb.list_count += u32(old_count + 1)
	block.list_start = new_start
	block.list_count = u16(old_count + 1)
	cb.nodes[new_stmt - 1].parent = block_id

	old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
	ed.last_hash_changed = old_h != new_h
	ed.selected_node = val_hole
	ed.selected_slot = .Hole
	ed.shrink_depth = 0
	ast_editor_project(ed, cb)
	return true
}

@(private = "file")
handle_backspace :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> bool {
	if ed.active_def < 0 || ed.active_def >= int(cb.def_count) {
		return false
	}
	if ed.inline_active {
		if ed.inline_len > 1 {
			ed.inline_len -= 1
			ed.inline_buf[ed.inline_len] = 0
			apply_inline_expr_live(ed, cb)
			if ed.inline_target == .Node_Int || ed.inline_target == .Node_Ident || ed.inline_target == .Node_Text {
				old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
				ed.last_hash_changed = old_h != new_h
			}
			ast_editor_project(ed, cb)
			return true
		}
		// Deleting the last inline character of an expression collapses it back to a `?` Hole.
		if ed.inline_target == .Node_Int || ed.inline_target == .Node_Ident || ed.inline_target == .Node_Text {
			ed.inline_len = 0
			ed.inline_active = false
			ed.inline_target = .None
			if node := node_get(cb, ed.inline_node); node != nil {
				node.kind = .Hole
				node.name_len = 0
				node.int_value = 0
				node.bool_value = false
				node.child_a = NODE_NONE
				node.child_b = NODE_NONE
				node.child_c = NODE_NONE
				node.list_count = 0
			}
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ed.selected_node = ed.inline_node
			ed.selected_slot = .Hole
			ast_editor_project(ed, cb)
			return true
		}
		// Rename buffer: allow clearing to empty while staying in inline mode.
		ed.inline_len = 0
		ed.inline_buf[0] = 0
		ast_editor_project(ed, cb)
		return true
	}

	node := node_get(cb, ed.selected_node)
	if node == nil {
		return false
	}
	switch node.kind {
	case .Hole:
		// If focused on the RHS hole of a Binary, unwrap Binary back to LHS.
		if parent := node_get(cb, node.parent); parent != nil {
			if parent.kind == .Binary && parent.child_b == ed.selected_node {
				lhs := parent.child_a
				if codebase_replace_child(cb, ed.active_def, node.parent, lhs) {
					old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
					ed.last_hash_changed = old_h != new_h
					ed.selected_node = lhs
					ed.selected_slot = cb.nodes[lhs - 1].kind == .Hole ? .Hole : .Node_Expr
					ast_editor_project(ed, cb)
					return true
				}
			} else if parent.kind == .Unary {
				parent.kind = .Hole
				parent.child_a = NODE_NONE
				old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
				ed.last_hash_changed = old_h != new_h
				ed.selected_node = node.parent
				ed.selected_slot = .Hole
				ast_editor_project(ed, cb)
				return true
			}
		}
		return false
	case .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref, .Unary, .Binary, .Call, .If_Expr:
		// Collapse focused expression node cleanly into a `?` Hole.
		node.kind = .Hole
		node.name_len = 0
		node.int_value = 0
		node.bool_value = false
		node.child_a = NODE_NONE
		node.child_b = NODE_NONE
		node.child_c = NODE_NONE
		node.list_count = 0
		old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
		ed.last_hash_changed = old_h != new_h
		ed.selected_slot = .Hole
		ed.shrink_depth = 0
		ast_editor_project(ed, cb)
		return true
	case .Let_Stmt:
		// Remove Let_Stmt from enclosing Block if block has more than 1 statement.
		if parent := node_get(cb, node.parent); parent != nil && parent.kind == .Block && parent.list_count > 1 {
			old_count := int(parent.list_count)
			if u64(cb.list_count) + u64(old_count - 1) > MAX_LIST_ITEMS {
				return false
			}
			new_start := cb.list_count
			out_i := 0
			next_focus := NODE_NONE
			for i in 0 ..< old_count {
				sid := cb.list_items[int(parent.list_start) + i]
				if sid == ed.selected_node {
					continue
				}
				cb.list_items[int(new_start) + out_i] = sid
				if next_focus == NODE_NONE {
					next_focus = sid
				}
				out_i += 1
			}
			cb.list_count += u32(out_i)
			parent.list_start = new_start
			parent.list_count = u16(out_i)
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ed.selected_node = next_focus
			ed.selected_slot = .Node_Expr
			ast_editor_project(ed, cb)
			return true
		}
		return false
	case .Return_Stmt, .Block:
		return false
	}
	return false
}

// ast_editor_action executes a structural navigation or editing command.
ast_editor_action :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, action: Ast_Edit_Action) -> bool {
	if ed.active_def < 0 || ed.active_def >= int(cb.def_count) {
		return false
	}
	ed.last_hash_changed = false
	switch action {
	case .Left:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		for i := ed.cursor_token - 1; i >= 0; i -= 1 {
			if ed.tokens[i].interactive {
				focus_token(ed, cb, i)
				return true
			}
		}
		return false
	case .Right:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		for i := ed.cursor_token + 1; i < ed.token_count; i += 1 {
			if ed.tokens[i].interactive {
				focus_token(ed, cb, i)
				return true
			}
		}
		return false
	case .Up:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		cur_col := ed.cursor_token >= 0 && ed.cursor_token < ed.token_count ? int(ed.tokens[ed.cursor_token].col_start) : 0
		for l := ed.cursor_line - 1; l >= 0; l -= 1 {
			best := closest_interactive_on_line(ed, l, cur_col)
			if best >= 0 {
				focus_token(ed, cb, best)
				return true
			}
		}
		return false
	case .Down:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		cur_col := ed.cursor_token >= 0 && ed.cursor_token < ed.token_count ? int(ed.tokens[ed.cursor_token].col_start) : 0
		for l := ed.cursor_line + 1; l < ed.line_count; l += 1 {
			best := closest_interactive_on_line(ed, l, cur_col)
			if best >= 0 {
				focus_token(ed, cb, best)
				return true
			}
		}
		return false
	case .Next_Hole:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		if jump_hole(ed, cb, 1) {
			return true
		}
		// When all holes are filled, Tab steps focus out to the enclosing
		// expression so fluid chains like `x * 2 <Tab> + 1` produce `((x * 2) + 1)`.
		return step_up_expression(ed, cb)
	case .Prev_Hole:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		return jump_hole(ed, cb, -1)
	case .Expand_Selection:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		node := node_get(cb, ed.selected_node)
		if node == nil || node.parent == NODE_NONE {
			return false
		}
		if ed.shrink_depth < SHRINK_STACK_CAPACITY {
			ed.shrink_stack[ed.shrink_depth] = ed.selected_node
			ed.shrink_depth += 1
		}
		ed.selected_node = node.parent
		ed.selected_slot = .Node_Expr
		sync_cursor_from_selection(ed, cb)
		return true
	case .Shrink_Selection:
		if ed.inline_active {
			_ = ast_editor_commit_inline(ed, cb)
		}
		if ed.shrink_depth <= 0 {
			return false
		}
		ed.shrink_depth -= 1
		ed.selected_node = ed.shrink_stack[ed.shrink_depth]
		ed.selected_slot = .Node_Expr
		sync_cursor_from_selection(ed, cb)
		return true
	case .Insert_Stmt:
		if ed.inline_active {
			return ast_editor_commit_inline(ed, cb)
		}
		return insert_statement_in_block(ed, cb)
	case .Backspace:
		return handle_backspace(ed, cb)
	case .Begin_Rename:
		return ast_editor_begin_rename(ed, cb)
	case .Commit_Inline:
		return ast_editor_commit_inline(ed, cb)
	case .Cancel_Inline:
		if !ed.inline_active {
			return false
		}
		ed.inline_active = false
		ed.inline_target = .None
		ast_editor_project(ed, cb)
		return true
	}
	return false
}

@(private = "file")
closest_interactive_on_line :: proc "contextless" (ed: ^Ast_Editor, line_idx: int, col: int) -> int {
	if line_idx < 0 || line_idx >= ed.line_count {
		return -1
	}
	start := int(ed.lines[line_idx].token_start)
	end := start + int(ed.lines[line_idx].token_count)
	best := -1
	best_dist := int(max(i32))
	for i in start ..< end {
		if !ed.tokens[i].interactive {
			continue
		}
		d := abs(int(ed.tokens[i].col_start) - col)
		if d < best_dist {
			best_dist = d
			best = i
		}
	}
	return best
}

@(private = "file")
jump_hole :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, direction: int) -> bool {
	if ed.token_count == 0 {
		return false
	}
	start := ed.cursor_token >= 0 ? ed.cursor_token : 0
	for step in 1 ..< ed.token_count + 1 {
		idx := (start + direction * step) % ed.token_count
		if idx < 0 {
			idx += ed.token_count
		}
		if ed.tokens[idx].slot == .Hole {
			focus_token(ed, cb, idx)
			return true
		}
	}
	return false
}

@(private = "file")
step_up_expression :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase) -> bool {
	node := node_get(cb, ed.selected_node)
	if node == nil || node.parent == NODE_NONE {
		return false
	}
	parent := node_get(cb, node.parent)
	if parent == nil {
		return false
	}
	switch parent.kind {
	case .Binary, .Unary, .Call, .If_Expr:
		if ed.shrink_depth < SHRINK_STACK_CAPACITY {
			ed.shrink_stack[ed.shrink_depth] = ed.selected_node
			ed.shrink_depth += 1
		}
		ed.selected_node = node.parent
		ed.selected_slot = .Node_Expr
		sync_cursor_from_selection(ed, cb)
		return true
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref, .Let_Stmt, .Return_Stmt, .Block:
		return false
	}
	return false
}

@(private = "file")
char_to_bin_op :: proc "contextless" (ch: rune) -> (op: Bin_Op, ok: bool) {
	switch ch {
	case '+':
		return .Add, true
	case '-':
		return .Sub, true
	case '*':
		return .Mul, true
	case '/':
		return .Div, true
	case '%':
		return .Mod, true
	case '=':
		return .Eq, true
	case '<':
		return .Lt, true
	case '>':
		return .Gt, true
	case '&':
		return .And, true
	case '|':
		return .Or, true
	case '!':
		return .Not_Eq, true
	}
	return .Add, false
}

// ast_editor_type_char handles one typed printable character in fluid text-like
// fashion, updating the AST and re-projecting once.
ast_editor_type_char :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, ch: rune) -> bool {
	if ed.active_def < 0 || ed.active_def >= int(cb.def_count) {
		return false
	}
	if ch < 0x20 || ch > 0x7E {
		return false
	}
	ed.last_hash_changed = false
	b := u8(ch)
	is_digit := b >= '0' && b <= '9'
	is_letter := (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'

	// Active rename or text-literal inline editing.
	if ed.inline_active {
		switch ed.inline_target {
		case .Def_Name, .Param_Name, .Let_Name:
			if (is_letter || is_digit) && ed.inline_len < IDENT_LIMIT {
				ed.inline_buf[ed.inline_len] = b
				ed.inline_len += 1
				ast_editor_project(ed, cb)
				return true
			}
			return false
		case .Node_Text:
			if ch == '"' {
				return ast_editor_commit_inline(ed, cb)
			}
			if ed.inline_len < IDENT_LIMIT {
				ed.inline_buf[ed.inline_len] = b
				ed.inline_len += 1
				apply_inline_expr_live(ed, cb)
				old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
				ed.last_hash_changed = old_h != new_h
				ast_editor_project(ed, cb)
				return true
			}
			return false
		case .Node_Int:
			if is_digit && ed.inline_len < 18 {
				ed.inline_buf[ed.inline_len] = b
				ed.inline_len += 1
				apply_inline_expr_live(ed, cb)
				old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
				ed.last_hash_changed = old_h != new_h
				ast_editor_project(ed, cb)
				return true
			}
			// Non-digit commits the number and falls through to operator handling.
			_ = ast_editor_commit_inline(ed, cb)
		case .Node_Ident:
			if (is_letter || is_digit) && ed.inline_len < IDENT_LIMIT {
				ed.inline_buf[ed.inline_len] = b
				ed.inline_len += 1
				apply_inline_expr_live(ed, cb)
				old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
				ed.last_hash_changed = old_h != new_h
				ast_editor_project(ed, cb)
				return true
			}
			// Non-ident char (such as '*' or '(') commits identifier first!
			_ = ast_editor_commit_inline(ed, cb)
		case .None:
		}
	}

	// Typing directly on Def_Name or Param_Name begins an inline edit smoothly.
	if ed.selected_slot == .Def_Name || ed.selected_slot == .Param_Name || ed.selected_slot == .Let_Name {
		if is_letter {
			if ast_editor_begin_rename(ed, cb) {
				ed.inline_buf = {}
				ed.inline_buf[0] = b
				ed.inline_len = 1
				ast_editor_project(ed, cb)
				return true
			}
		}
		return false
	}

	// Spaces are ignored outside text literals so users can type `x * 2` naturally.
	if ch == ' ' {
		return false
	}

	node := node_get(cb, ed.selected_node)
	if node == nil {
		return false
	}

	// Operator upgrade when focused on a Binary operator token.
	if ed.selected_slot == .Operator && node.kind == .Binary {
		if ch == '=' {
			if node.bin_op == .Lt {
				node.bin_op = .Lt_Eq
			} else if node.bin_op == .Gt {
				node.bin_op = .Gt_Eq
			} else {
				return false
			}
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ast_editor_project(ed, cb)
			return true
		}
		if new_op, ok_op := char_to_bin_op(ch); ok_op {
			node.bin_op = new_op
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ast_editor_project(ed, cb)
			return true
		}
		return false
	}

	// Typing on a `?` Hole starts a literal, identifier, unary op, or call.
	if node.kind == .Hole {
		if is_digit {
			ed.inline_active = true
			ed.inline_target = .Node_Int
			ed.inline_node = ed.selected_node
			ed.inline_buf = {}
			ed.inline_buf[0] = b
			ed.inline_len = 1
			apply_inline_expr_live(ed, cb)
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ed.selected_slot = .Node_Expr
			ast_editor_project(ed, cb)
			return true
		}
		if is_letter {
			ed.inline_active = true
			ed.inline_target = .Node_Ident
			ed.inline_node = ed.selected_node
			ed.inline_buf = {}
			ed.inline_buf[0] = b
			ed.inline_len = 1
			apply_inline_expr_live(ed, cb)
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ed.selected_slot = .Node_Expr
			ast_editor_project(ed, cb)
			return true
		}
		if ch == '"' {
			ed.inline_active = true
			ed.inline_target = .Node_Text
			ed.inline_node = ed.selected_node
			ed.inline_buf = {}
			ed.inline_len = 0
			apply_inline_expr_live(ed, cb)
			ed.selected_slot = .Node_Expr
			ast_editor_project(ed, cb)
			return true
		}
		if ch == '-' {
			return wrap_with_unary(ed, cb, .Neg)
		}
		if ch == '!' {
			return wrap_with_unary(ed, cb, .Not)
		}
		if ch == '(' {
			return wrap_with_call(ed, cb)
		}
		return false
	}

	// Typing '(' on a Def_Ref wraps it in a Call with `?` argument holes.
	if ch == '(' && node.kind == .Def_Ref {
		return wrap_with_call(ed, cb)
	}

	// Typing a binary operator wraps ANY non-hole expression as lhs.
	if op, is_bin := char_to_bin_op(ch); is_bin {
		return wrap_with_binary(ed, cb, op)
	}

	// Typing digits on an existing Int_Lit appends smoothly inline.
	if is_digit && node.kind == .Int_Lit {
		buf: [24]u8
		cur := format_i64(buf[:], node.int_value)
		if len(cur) + 1 <= 18 {
			ed.inline_active = true
			ed.inline_target = .Node_Int
			ed.inline_node = ed.selected_node
			ed.inline_buf = {}
			copy(ed.inline_buf[:len(cur)], cur)
			ed.inline_buf[len(cur)] = b
			ed.inline_len = len(cur) + 1
			apply_inline_expr_live(ed, cb)
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ast_editor_project(ed, cb)
			return true
		}
	}

	// Typing letters on an existing Var appends smoothly inline.
	if (is_letter || is_digit) && node.kind == .Var {
		cur := node_name(node)
		if len(cur) + 1 <= IDENT_LIMIT {
			ed.inline_active = true
			ed.inline_target = .Node_Ident
			ed.inline_node = ed.selected_node
			ed.inline_buf = {}
			copy(ed.inline_buf[:len(cur)], cur)
			ed.inline_buf[len(cur)] = b
			ed.inline_len = len(cur) + 1
			apply_inline_expr_live(ed, cb)
			old_h, new_h := codebase_rehash_definition(cb, ed.active_def)
			ed.last_hash_changed = old_h != new_h
			ast_editor_project(ed, cb)
			return true
		}
	}

	return false
}

// ast_editor_click_at focuses the interactive token at (line, col), committing
// any active inline edit first.
ast_editor_click_at :: proc "contextless" (ed: ^Ast_Editor, cb: ^Codebase, line: int, col: int) -> bool {
	if line < 0 || line >= ed.line_count {
		return false
	}
	if ed.inline_active {
		_ = ast_editor_commit_inline(ed, cb)
	}
	start := int(ed.lines[line].token_start)
	end := start + int(ed.lines[line].token_count)
	for i in start ..< end {
		tok := &ed.tokens[i]
		if tok.interactive && col >= int(tok.col_start) && col < int(tok.col_end) {
			focus_token(ed, cb, i)
			return true
		}
	}
	best := closest_interactive_on_line(ed, line, col)
	if best >= 0 {
		focus_token(ed, cb, best)
		return true
	}
	return false
}
