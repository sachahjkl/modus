// Content-addressed AST codebase model (src/md/features/codebase_ast.md).
//
// Definitions are stored as flat node pools with 1-based Node_Id indices so
// zero-initialized records are valid and never alias node 1. Human-readable
// names live in a separate Name_Table mapping names to 32-byte BLAKE3 hashes
// so renaming is O(1) and never alters content identity.
package ast_codebase

// Node_Id indexes a node in Codebase.nodes using 1-based numbering.
// NODE_NONE (0) means no node.
Node_Id :: u32
NODE_NONE :: Node_Id(0)

// Sentinel slot for an identifier that has not yet resolved to a parameter or
// local let binding during inline typing.
UNRESOLVED_VAR_SLOT :: u16(0xFFFF)

// Sentinel definition index for an unlinked Name_Entry cache slot.
DEF_INDEX_NONE :: u16(0xFFFF)

// Format property: maximum byte length of an identifier or short text literal
// in MODAST1 binary records.
IDENT_LIMIT :: 48

// Plan value: maximum parameters per definition for the in-OS editor budget.
MAX_PARAMS :: 8

// Plan value: fixed AST node pool capacity for the in-OS editor budget.
MAX_NODES :: 4096

// Plan value: fixed child-list item pool for Block statements and Call args.
MAX_LIST_ITEMS :: 2048

// Plan value: fixed definition table capacity for the in-OS codebase budget.
MAX_DEFS :: 128

// Plan value: fixed name table capacity mapping display names to hashes.
MAX_NAMES :: 128

// Closed set of AST node kinds with explicit MODAST1 contract values.
Node_Kind :: enum u8 {
	Hole        = 0,
	Int_Lit     = 1,
	Bool_Lit    = 2,
	Text_Lit    = 3,
	Var         = 4,
	Def_Ref     = 5,
	Unary       = 6,
	Binary      = 7,
	Call        = 8,
	If_Expr     = 9,
	Let_Stmt    = 10,
	Return_Stmt = 11,
	Block       = 12,
}

// Closed set of AST value types with explicit MODAST1 contract values.
Type_Kind :: enum u8 {
	Unknown = 0,
	Int     = 1,
	Bool    = 2,
	Text    = 3,
	Void    = 4,
}

// Closed set of binary operators with explicit MODAST1 contract values.
Bin_Op :: enum u8 {
	Add    = 0,
	Sub    = 1,
	Mul    = 2,
	Div    = 3,
	Mod    = 4,
	Eq     = 5,
	Not_Eq = 6,
	Lt     = 7,
	Lt_Eq  = 8,
	Gt     = 9,
	Gt_Eq  = 10,
	And    = 11,
	Or     = 12,
}

// Closed set of unary operators with explicit MODAST1 contract values.
Unary_Op :: enum u8 {
	Neg = 0,
	Not = 1,
}

// One function parameter: its display name is excluded from content hashing.
Param :: struct {
	name:     [IDENT_LIMIT]u8,
	name_len: u8,
	type:     Type_Kind,
}

// One AST node in the fixed pool.
//
// Child slots by Node_Kind:
// - Hole:        none (type_hint records expected type)
// - Int_Lit:     int_value
// - Bool_Lit:    bool_value
// - Text_Lit:    name[:name_len] holds text bytes
// - Var:         var_slot (lexical slot), name[:name_len] (display name)
// - Def_Ref:     ref_hash (32-byte BLAKE3 hash of referenced definition)
// - Unary:       unary_op, child_a (operand)
// - Binary:      bin_op, child_a (lhs), child_b (rhs)
// - Call:        child_a (callee), list_items[list_start : list_start+list_count] (args)
// - If_Expr:     child_a (cond), child_b (then), child_c (else)
// - Let_Stmt:    var_slot, name[:name_len], child_a (bound value), child_b (optional body)
// - Return_Stmt: child_a (returned expression)
// - Block:       list_items[list_start : list_start+list_count] (statements)
Node :: struct {
	kind:       Node_Kind,
	bin_op:     Bin_Op,
	unary_op:   Unary_Op,
	bool_value: bool,
	type_hint:  Type_Kind,
	name_len:   u8,
	var_slot:   u16,
	int_value:  i64,
	child_a:    Node_Id,
	child_b:    Node_Id,
	child_c:    Node_Id,
	list_start: u32,
	list_count: u16,
	parent:     Node_Id,
	ref_hash:   [32]u8,
	name:       [IDENT_LIMIT]u8,
}

// One content-addressed definition. Its human-readable name lives only in
// Name_Table so renames never alter Definition.hash.
Definition :: struct {
	root:        Node_Id,
	param_count: u8,
	params:      [MAX_PARAMS]Param,
	return_type: Type_Kind,
	hash:        [32]u8,
	active:      bool,
}

// One entry of the Name Table mapping a human name to a definition hash.
Name_Entry :: struct {
	name:      [IDENT_LIMIT]u8,
	name_len:  u8,
	def_hash:  [32]u8,
	def_index: u16, // Cache updated on load and edit.
	active:    bool,
}

// Complete fixed-capacity AST codebase. Allocate statically or in module
// memory, never on a small thread stack.
Codebase :: struct {
	nodes:      [MAX_NODES]Node,
	node_count: u32,
	list_items: [MAX_LIST_ITEMS]Node_Id,
	list_count: u32,
	defs:       [MAX_DEFS]Definition,
	def_count:  u16,
	names:      [MAX_NAMES]Name_Entry,
	name_count: u16,
}

// ident_valid reports whether s is a non-empty ASCII identifier within
// IDENT_LIMIT bytes (starts with a letter or '_', followed by letters, digits,
// or '_').
ident_valid :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || len(s) > IDENT_LIMIT {
		return false
	}
	first := s[0]
	if !((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') || first == '_') {
		return false
	}
	for i in 1 ..< len(s) {
		ch := s[i]
		ok_ch := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
		if !ok_ch {
			return false
		}
	}
	return true
}

// text_literal_valid reports whether s fits IDENT_LIMIT and contains no NUL or
// ASCII control characters.
text_literal_valid :: proc "contextless" (s: string) -> bool {
	if len(s) > IDENT_LIMIT {
		return false
	}
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < 0x20 || ch == 0x7F {
			return false
		}
	}
	return true
}

// param_make builds a Param if name is a valid identifier.
param_make :: proc "contextless" (name: string, kind: Type_Kind) -> (param: Param, ok: bool) {
	if !ident_valid(name) {
		return {}, false
	}
	param.name_len = u8(len(name))
	copy(param.name[:len(name)], name)
	param.type = kind
	return param, true
}

param_name :: proc "contextless" (param: ^Param) -> string {
	return string(param.name[:param.name_len])
}

node_name :: proc "contextless" (node: ^Node) -> string {
	return string(node.name[:node.name_len])
}

name_entry_text :: proc "contextless" (entry: ^Name_Entry) -> string {
	return string(entry.name[:entry.name_len])
}

// node_get returns a pointer to node `id`, or nil if id is NODE_NONE or out of
// range.
node_get :: proc "contextless" (cb: ^Codebase, id: Node_Id) -> ^Node {
	if id == NODE_NONE || id > cb.node_count {
		return nil
	}
	return &cb.nodes[id - 1]
}

// node_valid reports whether id names an existing node in cb.
node_valid :: proc "contextless" (cb: ^Codebase, id: Node_Id) -> bool {
	return id != NODE_NONE && id <= cb.node_count
}

@(private = "package")
node_alloc :: proc "contextless" (cb: ^Codebase, init: Node) -> (id: Node_Id, ok: bool) {
	if cb.node_count >= MAX_NODES {
		return NODE_NONE, false
	}
	cb.nodes[cb.node_count] = init
	cb.node_count += 1
	return Node_Id(cb.node_count), true
}

@(private = "package")
list_alloc :: proc "contextless" (cb: ^Codebase, items: []Node_Id) -> (start: u32, ok: bool) {
	if len(items) == 0 {
		return 0, true
	}
	if u64(cb.list_count) + u64(len(items)) > MAX_LIST_ITEMS {
		return 0, false
	}
	for item in items {
		if !node_valid(cb, item) {
			return 0, false
		}
	}
	start = cb.list_count
	for item, idx in items {
		cb.list_items[int(start) + idx] = item
	}
	cb.list_count += u32(len(items))
	return start, true
}

ast_add_hole :: proc "contextless" (cb: ^Codebase, type_hint: Type_Kind = .Unknown) -> (Node_Id, bool) {
	return node_alloc(cb, Node{kind = .Hole, type_hint = type_hint})
}

ast_add_int :: proc "contextless" (cb: ^Codebase, value: i64) -> (Node_Id, bool) {
	return node_alloc(cb, Node{kind = .Int_Lit, int_value = value, type_hint = .Int})
}

ast_add_bool :: proc "contextless" (cb: ^Codebase, value: bool) -> (Node_Id, bool) {
	return node_alloc(cb, Node{kind = .Bool_Lit, bool_value = value, type_hint = .Bool})
}

ast_add_text :: proc "contextless" (cb: ^Codebase, text: string) -> (Node_Id, bool) {
	if !text_literal_valid(text) {
		return NODE_NONE, false
	}
	node := Node{kind = .Text_Lit, name_len = u8(len(text)), type_hint = .Text}
	copy(node.name[:len(text)], text)
	return node_alloc(cb, node)
}

ast_add_var :: proc "contextless" (cb: ^Codebase, var_slot: u16, name: string) -> (Node_Id, bool) {
	if !ident_valid(name) {
		return NODE_NONE, false
	}
	node := Node{kind = .Var, var_slot = var_slot, name_len = u8(len(name))}
	copy(node.name[:len(name)], name)
	return node_alloc(cb, node)
}

ast_add_def_ref :: proc "contextless" (cb: ^Codebase, ref_hash: [32]u8) -> (Node_Id, bool) {
	return node_alloc(cb, Node{kind = .Def_Ref, ref_hash = ref_hash})
}

ast_add_unary :: proc "contextless" (cb: ^Codebase, op: Unary_Op, operand: Node_Id) -> (Node_Id, bool) {
	if !node_valid(cb, operand) {
		return NODE_NONE, false
	}
	id, ok := node_alloc(cb, Node{kind = .Unary, unary_op = op, child_a = operand})
	if !ok {
		return NODE_NONE, false
	}
	cb.nodes[operand - 1].parent = id
	return id, true
}

ast_add_binary :: proc "contextless" (cb: ^Codebase, op: Bin_Op, lhs: Node_Id, rhs: Node_Id) -> (Node_Id, bool) {
	if !node_valid(cb, lhs) || !node_valid(cb, rhs) || lhs == rhs {
		return NODE_NONE, false
	}
	id, ok := node_alloc(cb, Node{kind = .Binary, bin_op = op, child_a = lhs, child_b = rhs})
	if !ok {
		return NODE_NONE, false
	}
	cb.nodes[lhs - 1].parent = id
	cb.nodes[rhs - 1].parent = id
	return id, true
}

ast_add_call :: proc "contextless" (cb: ^Codebase, callee: Node_Id, args: []Node_Id) -> (Node_Id, bool) {
	if !node_valid(cb, callee) {
		return NODE_NONE, false
	}
	if len(args) > int(max(u16)) {
		return NODE_NONE, false
	}
	start, list_ok := list_alloc(cb, args)
	if !list_ok {
		return NODE_NONE, false
	}
	id, ok := node_alloc(cb, Node{kind = .Call, child_a = callee, list_start = start, list_count = u16(len(args))})
	if !ok {
		cb.list_count -= u32(len(args))
		return NODE_NONE, false
	}
	cb.nodes[callee - 1].parent = id
	for arg in args {
		cb.nodes[arg - 1].parent = id
	}
	return id, true
}

ast_add_if :: proc "contextless" (cb: ^Codebase, cond: Node_Id, then_branch: Node_Id, else_branch: Node_Id) -> (Node_Id, bool) {
	if !node_valid(cb, cond) || !node_valid(cb, then_branch) || !node_valid(cb, else_branch) {
		return NODE_NONE, false
	}
	id, ok := node_alloc(cb, Node{kind = .If_Expr, child_a = cond, child_b = then_branch, child_c = else_branch})
	if !ok {
		return NODE_NONE, false
	}
	cb.nodes[cond - 1].parent = id
	cb.nodes[then_branch - 1].parent = id
	cb.nodes[else_branch - 1].parent = id
	return id, true
}

ast_add_let :: proc "contextless" (cb: ^Codebase, var_slot: u16, name: string, value: Node_Id, body: Node_Id = NODE_NONE) -> (Node_Id, bool) {
	if !ident_valid(name) || !node_valid(cb, value) {
		return NODE_NONE, false
	}
	if body != NODE_NONE && !node_valid(cb, body) {
		return NODE_NONE, false
	}
	node := Node{kind = .Let_Stmt, var_slot = var_slot, name_len = u8(len(name)), child_a = value, child_b = body}
	copy(node.name[:len(name)], name)
	id, ok := node_alloc(cb, node)
	if !ok {
		return NODE_NONE, false
	}
	cb.nodes[value - 1].parent = id
	if body != NODE_NONE {
		cb.nodes[body - 1].parent = id
	}
	return id, true
}

ast_add_return :: proc "contextless" (cb: ^Codebase, value: Node_Id) -> (Node_Id, bool) {
	if !node_valid(cb, value) {
		return NODE_NONE, false
	}
	id, ok := node_alloc(cb, Node{kind = .Return_Stmt, child_a = value})
	if !ok {
		return NODE_NONE, false
	}
	cb.nodes[value - 1].parent = id
	return id, true
}

ast_add_block :: proc "contextless" (cb: ^Codebase, stmts: []Node_Id) -> (Node_Id, bool) {
	if len(stmts) > int(max(u16)) {
		return NODE_NONE, false
	}
	start, list_ok := list_alloc(cb, stmts)
	if !list_ok {
		return NODE_NONE, false
	}
	id, ok := node_alloc(cb, Node{kind = .Block, list_start = start, list_count = u16(len(stmts))})
	if !ok {
		cb.list_count -= u32(len(stmts))
		return NODE_NONE, false
	}
	for stmt in stmts {
		cb.nodes[stmt - 1].parent = id
	}
	return id, true
}

codebase_find_name :: proc "contextless" (cb: ^Codebase, target: string) -> (index: int, found: bool) {
	for i in 0 ..< int(cb.name_count) {
		if cb.names[i].active && name_entry_text(&cb.names[i]) == target {
			return i, true
		}
	}
	return -1, false
}

codebase_find_name_for_def :: proc "contextless" (cb: ^Codebase, def_index: int) -> (index: int, found: bool) {
	if def_index < 0 || def_index >= int(cb.def_count) {
		return -1, false
	}
	for i in 0 ..< int(cb.name_count) {
		if cb.names[i].active && int(cb.names[i].def_index) == def_index {
			return i, true
		}
	}
	return -1, false
}

codebase_def_display_name :: proc "contextless" (cb: ^Codebase, def_index: int) -> string {
	if idx, ok := codebase_find_name_for_def(cb, def_index); ok {
		return name_entry_text(&cb.names[idx])
	}
	return ""
}

codebase_find_name_by_hash :: proc "contextless" (cb: ^Codebase, target_hash: [32]u8) -> (name: string, found: bool) {
	for i in 0 ..< int(cb.name_count) {
		if cb.names[i].active && cb.names[i].def_hash == target_hash {
			return name_entry_text(&cb.names[i]), true
		}
	}
	return "", false
}

codebase_find_def_by_hash :: proc "contextless" (cb: ^Codebase, target_hash: [32]u8) -> (def_index: int, found: bool) {
	for i in 0 ..< int(cb.def_count) {
		if cb.defs[i].active && cb.defs[i].hash == target_hash {
			return i, true
		}
	}
	return -1, false
}

// codebase_add_definition registers a new definition and its Name_Table entry,
// computes its alpha-normalized BLAKE3 hash, and links parent pointers.
codebase_add_definition :: proc "contextless" (cb: ^Codebase, name: string, params: []Param, return_type: Type_Kind, root: Node_Id) -> (def_index: int, ok: bool) {
	if !ident_valid(name) || len(params) > MAX_PARAMS || !node_valid(cb, root) {
		return -1, false
	}
	if int(cb.def_count) >= MAX_DEFS || int(cb.name_count) >= MAX_NAMES {
		return -1, false
	}
	if _, exists := codebase_find_name(cb, name); exists {
		return -1, false
	}
	for &p in params {
		if !ident_valid(string(p.name[:p.name_len])) {
			return -1, false
		}
	}
	idx := int(cb.def_count)
	def := &cb.defs[idx]
	def^ = {}
	def.root = root
	def.param_count = u8(len(params))
	for p, pi in params {
		def.params[pi] = p
	}
	def.return_type = return_type
	def.active = true
	cb.def_count += 1

	cb.nodes[root - 1].parent = NODE_NONE
	rebuild_parents_subtree(cb, root, NODE_NONE)
	def.hash = hash_definition(cb, idx)

	name_idx := int(cb.name_count)
	entry := &cb.names[name_idx]
	entry^ = {}
	entry.name_len = u8(len(name))
	copy(entry.name[:len(name)], name)
	entry.def_hash = def.hash
	entry.def_index = u16(idx)
	entry.active = true
	cb.name_count += 1
	return idx, true
}

// codebase_rename_definition performs an O(1) Name_Table rename. Neither the
// renamed definition's hash nor any caller's hash changes.
codebase_rename_definition :: proc "contextless" (cb: ^Codebase, def_index: int, new_name: string) -> bool {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return false
	}
	if !ident_valid(new_name) {
		return false
	}
	name_idx, found := codebase_find_name_for_def(cb, def_index)
	if !found {
		return false
	}
	if existing, exists := codebase_find_name(cb, new_name); exists && existing != name_idx {
		return false
	}
	entry := &cb.names[name_idx]
	entry.name = {}
	entry.name_len = u8(len(new_name))
	copy(entry.name[:len(new_name)], new_name)
	return true
}

// codebase_rename_param renames a parameter and updates the display strings of
// local Var references targeting that parameter slot. Content hash stays exact.
codebase_rename_param :: proc "contextless" (cb: ^Codebase, def_index: int, param_index: int, new_name: string) -> bool {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return false
	}
	def := &cb.defs[def_index]
	if param_index < 0 || param_index >= int(def.param_count) {
		return false
	}
	if !ident_valid(new_name) {
		return false
	}
	param := &def.params[param_index]
	param.name = {}
	param.name_len = u8(len(new_name))
	copy(param.name[:len(new_name)], new_name)
	rename_var_slot_in_subtree(cb, def.root, u16(param_index), new_name)
	return true
}

// rename_var_slot_in_subtree updates display strings of Var nodes matching slot.
@(private = "package")
rename_var_slot_in_subtree :: proc "contextless" (cb: ^Codebase, id: Node_Id, slot: u16, new_name: string) {
	node := node_get(cb, id)
	if node == nil {
		return
	}
	switch node.kind {
	case .Var:
		if node.var_slot == slot {
			node.name = {}
			node.name_len = u8(len(new_name))
			copy(node.name[:len(new_name)], new_name)
		}
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Def_Ref:
	case .Unary, .Return_Stmt:
		rename_var_slot_in_subtree(cb, node.child_a, slot, new_name)
	case .Binary:
		rename_var_slot_in_subtree(cb, node.child_a, slot, new_name)
		rename_var_slot_in_subtree(cb, node.child_b, slot, new_name)
	case .Let_Stmt:
		rename_var_slot_in_subtree(cb, node.child_a, slot, new_name)
		if node.child_b != NODE_NONE {
			rename_var_slot_in_subtree(cb, node.child_b, slot, new_name)
		}
	case .If_Expr:
		rename_var_slot_in_subtree(cb, node.child_a, slot, new_name)
		rename_var_slot_in_subtree(cb, node.child_b, slot, new_name)
		rename_var_slot_in_subtree(cb, node.child_c, slot, new_name)
	case .Call:
		rename_var_slot_in_subtree(cb, node.child_a, slot, new_name)
		for i in 0 ..< int(node.list_count) {
			rename_var_slot_in_subtree(cb, cb.list_items[int(node.list_start) + i], slot, new_name)
		}
	case .Block:
		for i in 0 ..< int(node.list_count) {
			rename_var_slot_in_subtree(cb, cb.list_items[int(node.list_start) + i], slot, new_name)
		}
	}
}

@(private = "package")
rebuild_parents_subtree :: proc "contextless" (cb: ^Codebase, id: Node_Id, parent: Node_Id) {
	node := node_get(cb, id)
	if node == nil {
		return
	}
	node.parent = parent
	switch node.kind {
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref:
	case .Unary, .Return_Stmt:
		rebuild_parents_subtree(cb, node.child_a, id)
	case .Binary:
		rebuild_parents_subtree(cb, node.child_a, id)
		rebuild_parents_subtree(cb, node.child_b, id)
	case .Let_Stmt:
		rebuild_parents_subtree(cb, node.child_a, id)
		if node.child_b != NODE_NONE {
			rebuild_parents_subtree(cb, node.child_b, id)
		}
	case .If_Expr:
		rebuild_parents_subtree(cb, node.child_a, id)
		rebuild_parents_subtree(cb, node.child_b, id)
		rebuild_parents_subtree(cb, node.child_c, id)
	case .Call:
		rebuild_parents_subtree(cb, node.child_a, id)
		for i in 0 ..< int(node.list_count) {
			rebuild_parents_subtree(cb, cb.list_items[int(node.list_start) + i], id)
		}
	case .Block:
		for i in 0 ..< int(node.list_count) {
			rebuild_parents_subtree(cb, cb.list_items[int(node.list_start) + i], id)
		}
	}
}

// codebase_rebuild_parents repairs every parent pointer across active definitions.
codebase_rebuild_parents :: proc "contextless" (cb: ^Codebase) {
	for i in 0 ..< int(cb.node_count) {
		cb.nodes[i].parent = NODE_NONE
	}
	for d in 0 ..< int(cb.def_count) {
		if cb.defs[d].active && node_valid(cb, cb.defs[d].root) {
			rebuild_parents_subtree(cb, cb.defs[d].root, NODE_NONE)
		}
	}
}

// codebase_replace_child replaces `old_id` with `new_id` inside its parent or
// as the definition root, and updates parent pointers.
codebase_replace_child :: proc "contextless" (cb: ^Codebase, def_index: int, old_id: Node_Id, new_id: Node_Id) -> bool {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return false
	}
	old_node := node_get(cb, old_id)
	new_node := node_get(cb, new_id)
	if old_node == nil || new_node == nil {
		return false
	}
	parent_id := old_node.parent
	if parent_id == NODE_NONE {
		if cb.defs[def_index].root != old_id {
			return false
		}
		cb.defs[def_index].root = new_id
		new_node.parent = NODE_NONE
		return true
	}
	parent := node_get(cb, parent_id)
	if parent == nil {
		return false
	}
	replaced := false
	switch parent.kind {
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref:
	case .Unary, .Return_Stmt:
		if parent.child_a == old_id {
			parent.child_a = new_id
			replaced = true
		}
	case .Binary:
		if parent.child_a == old_id {
			parent.child_a = new_id
			replaced = true
		} else if parent.child_b == old_id {
			parent.child_b = new_id
			replaced = true
		}
	case .Let_Stmt:
		if parent.child_a == old_id {
			parent.child_a = new_id
			replaced = true
		} else if parent.child_b == old_id {
			parent.child_b = new_id
			replaced = true
		}
	case .If_Expr:
		if parent.child_a == old_id {
			parent.child_a = new_id
			replaced = true
		} else if parent.child_b == old_id {
			parent.child_b = new_id
			replaced = true
		} else if parent.child_c == old_id {
			parent.child_c = new_id
			replaced = true
		}
	case .Call:
		if parent.child_a == old_id {
			parent.child_a = new_id
			replaced = true
		} else {
			for i in 0 ..< int(parent.list_count) {
				if cb.list_items[int(parent.list_start) + i] == old_id {
					cb.list_items[int(parent.list_start) + i] = new_id
					replaced = true
					break
				}
			}
		}
	case .Block:
		for i in 0 ..< int(parent.list_count) {
			if cb.list_items[int(parent.list_start) + i] == old_id {
				cb.list_items[int(parent.list_start) + i] = new_id
				replaced = true
				break
			}
		}
	}
	if replaced {
		new_node.parent = parent_id
	}
	return replaced
}

// codebase_seed_sample populates a fresh codebase with two working definitions:
// `square(x: Int) -> Int` and `main() -> Int` calling `square(7)`.
codebase_seed_sample :: proc "contextless" (cb: ^Codebase) -> bool {
	cb^ = {}
	px, ok := param_make("x", .Int)
	if !ok {
		return false
	}
	x1, ok1 := ast_add_var(cb, 0, "x")
	x2, ok2 := ast_add_var(cb, 0, "x")
	if !ok1 || !ok2 {
		return false
	}
	mul_id, ok_mul := ast_add_binary(cb, .Mul, x1, x2)
	if !ok_mul {
		return false
	}
	ret_sq, ok_rsq := ast_add_return(cb, mul_id)
	if !ok_rsq {
		return false
	}
	sq_stmts := [1]Node_Id{ret_sq}
	sq_body, ok_sqb := ast_add_block(cb, sq_stmts[:])
	if !ok_sqb {
		return false
	}
	sq_params := [1]Param{px}
	sq_idx, ok_sq := codebase_add_definition(cb, "square", sq_params[:], .Int, sq_body)
	if !ok_sq {
		return false
	}

	sq_ref, ok_ref := ast_add_def_ref(cb, cb.defs[sq_idx].hash)
	seven, ok_7 := ast_add_int(cb, 7)
	if !ok_ref || !ok_7 {
		return false
	}
	call_args := [1]Node_Id{seven}
	call_sq, ok_call := ast_add_call(cb, sq_ref, call_args[:])
	if !ok_call {
		return false
	}
	let_n, ok_let := ast_add_let(cb, 0, "n", call_sq)
	if !ok_let {
		return false
	}
	var_n, ok_vn := ast_add_var(cb, 0, "n")
	one, ok_1 := ast_add_int(cb, 1)
	if !ok_vn || !ok_1 {
		return false
	}
	add_id, ok_add := ast_add_binary(cb, .Add, var_n, one)
	if !ok_add {
		return false
	}
	ret_main, ok_rm := ast_add_return(cb, add_id)
	if !ok_rm {
		return false
	}
	main_stmts := [2]Node_Id{let_n, ret_main}
	main_body, ok_mb := ast_add_block(cb, main_stmts[:])
	if !ok_mb {
		return false
	}
	_, ok_main := codebase_add_definition(cb, "main", nil, .Int, main_body)
	return ok_main
}

// hash_hex_prefix formats the first `hex_chars` lowercase hex characters of
// digest into out without using core:fmt.
hash_hex_prefix :: proc "contextless" (digest: [32]u8, out: []u8, hex_chars: int) -> string {
	hex_digits := "0123456789abcdef"
	count := min(hex_chars, len(out), 64)
	for i in 0 ..< count {
		b := digest[i / 2]
		nibble := (i & 1) == 0 ? (b >> 4) : (b & 0x0F)
		out[i] = hex_digits[nibble]
	}
	return string(out[:count])
}

type_kind_name :: proc "contextless" (kind: Type_Kind) -> string {
	switch kind {
	case .Unknown:
		return "Any"
	case .Int:
		return "Int"
	case .Bool:
		return "Bool"
	case .Text:
		return "Text"
	case .Void:
		return "Void"
	}
	return "Any"
}

bin_op_text :: proc "contextless" (op: Bin_Op) -> string {
	switch op {
	case .Add:
		return "+"
	case .Sub:
		return "-"
	case .Mul:
		return "*"
	case .Div:
		return "/"
	case .Mod:
		return "%"
	case .Eq:
		return "=="
	case .Not_Eq:
		return "!="
	case .Lt:
		return "<"
	case .Lt_Eq:
		return "<="
	case .Gt:
		return ">"
	case .Gt_Eq:
		return ">="
	case .And:
		return "&&"
	case .Or:
		return "||"
	}
	return "+"
}

unary_op_text :: proc "contextless" (op: Unary_Op) -> string {
	switch op {
	case .Neg:
		return "-"
	case .Not:
		return "!"
	}
	return "-"
}
