// Canonical MODAST1 binary serialization and strict validation border
// (src/md/features/codebase_ast.md).
//
// Format layout (all integers little-endian):
//   Header (24 bytes):
//     [0..8)   magic = "MODAST1\x00"
//     [8..10)  version = 1 (u16)
//     [10..12) flags = 0 (u16)
//     [12..16) node_count (u32, <= MAX_NODES)
//     [16..20) list_count (u32, <= MAX_LIST_ITEMS)
//     [20..22) def_count (u16, <= MAX_DEFS)
//     [22..24) name_count (u16, <= MAX_NAMES)
//   Nodes (node_count variable-length records)
//   List items (list_count * 4 bytes)
//   Definitions (def_count variable-length records)
//   Name Table (name_count variable-length records)
package ast_codebase

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: 8-byte MODAST1 binary magic header.
MODAST_MAGIC :: [8]u8{'M', 'O', 'D', 'A', 'S', 'T', '1', 0}

// Format property: current MODAST1 wire version and header byte size.
MODAST_VERSION :: u16(1)
MODAST_HEADER_BYTES :: 24
MODAST_NODE_FIXED_BYTES :: 36

// Closed set of codec outcomes with explicit contract values.
Codec_Error :: enum u8 {
	Ok                 = 0,
	Buffer_Too_Small   = 1,
	Bad_Magic          = 2,
	Bad_Version        = 3,
	Bad_Flags          = 4,
	Truncated          = 5,
	Trailing_Bytes     = 6,
	Count_Out_Of_Range = 7,
	Unknown_Enum       = 8,
	Node_Out_Of_Range  = 9,
	List_Out_Of_Range  = 10,
	Bad_Name           = 11,
	Duplicate_Name     = 12,
	Cycle_Detected     = 13,
	Hash_Mismatch      = 14,
}

// codebase_encode writes the canonical MODAST1 binary representation of cb
// into out. Returns (0, .Buffer_Too_Small) if out cannot hold the whole stream.
codebase_encode :: proc "contextless" (cb: ^Codebase, out: []u8) -> (written: int, err: Codec_Error) {
	if len(out) < MODAST_HEADER_BYTES {
		return 0, .Buffer_Too_Small
	}
	magic := MODAST_MAGIC
	copy(out[0:8], magic[:])
	byte_order.write_u16_little_endian(out, 8, MODAST_VERSION)
	byte_order.write_u16_little_endian(out, 10, 0)
	byte_order.write_u32_little_endian(out, 12, cb.node_count)
	byte_order.write_u32_little_endian(out, 16, cb.list_count)
	byte_order.write_u16_little_endian(out, 20, cb.def_count)
	byte_order.write_u16_little_endian(out, 22, cb.name_count)
	pos := MODAST_HEADER_BYTES

	// Encode nodes.
	for i in 0 ..< int(cb.node_count) {
		node := &cb.nodes[i]
		extra_hash := node.kind == .Def_Ref ? 32 : 0
		need := MODAST_NODE_FIXED_BYTES + extra_hash + int(node.name_len)
		if pos + need > len(out) {
			return 0, .Buffer_Too_Small
		}
		out[pos + 0] = u8(node.kind)
		out[pos + 1] = node.kind == .Binary ? u8(node.bin_op) : 0
		out[pos + 2] = node.kind == .Unary ? u8(node.unary_op) : 0
		out[pos + 3] = node.kind == .Bool_Lit && node.bool_value ? 1 : 0
		out[pos + 4] = u8(node.type_hint)
		out[pos + 5] = node.name_len
		byte_order.write_u16_little_endian(out, pos + 6, node.var_slot)
		byte_order.write_u64_little_endian(out, pos + 8, u64(node.int_value))
		byte_order.write_u32_little_endian(out, pos + 16, u32(node.child_a))
		byte_order.write_u32_little_endian(out, pos + 20, u32(node.child_b))
		byte_order.write_u32_little_endian(out, pos + 24, u32(node.child_c))
		byte_order.write_u32_little_endian(out, pos + 28, node.list_start)
		byte_order.write_u16_little_endian(out, pos + 32, node.list_count)
		byte_order.write_u16_little_endian(out, pos + 34, 0)
		pos += MODAST_NODE_FIXED_BYTES
		if node.kind == .Def_Ref {
			copy(out[pos:pos + 32], node.ref_hash[:])
			pos += 32
		}
		if node.name_len > 0 {
			copy(out[pos:pos + int(node.name_len)], node.name[:node.name_len])
			pos += int(node.name_len)
		}
	}

	// Encode list items.
	if pos + int(cb.list_count) * 4 > len(out) {
		return 0, .Buffer_Too_Small
	}
	for i in 0 ..< int(cb.list_count) {
		byte_order.write_u32_little_endian(out, pos, u32(cb.list_items[i]))
		pos += 4
	}

	// Encode definitions.
	for d in 0 ..< int(cb.def_count) {
		def := &cb.defs[d]
		if pos + 40 > len(out) {
			return 0, .Buffer_Too_Small
		}
		byte_order.write_u32_little_endian(out, pos + 0, u32(def.root))
		out[pos + 4] = def.param_count
		out[pos + 5] = u8(def.return_type)
		byte_order.write_u16_little_endian(out, pos + 6, 0)
		copy(out[pos + 8:pos + 40], def.hash[:])
		pos += 40
		for p in 0 ..< int(def.param_count) {
			param := &def.params[p]
			need := 2 + int(param.name_len)
			if pos + need > len(out) {
				return 0, .Buffer_Too_Small
			}
			out[pos + 0] = u8(param.type)
			out[pos + 1] = param.name_len
			copy(out[pos + 2:pos + need], param.name[:param.name_len])
			pos += need
		}
	}

	// Encode Name Table.
	for n in 0 ..< int(cb.name_count) {
		entry := &cb.names[n]
		need := 36 + int(entry.name_len)
		if pos + need > len(out) {
			return 0, .Buffer_Too_Small
		}
		copy(out[pos:pos + 32], entry.def_hash[:])
		byte_order.write_u16_little_endian(out, pos + 32, entry.def_index)
		out[pos + 34] = entry.name_len
		out[pos + 35] = 0
		copy(out[pos + 36:pos + need], entry.name[:entry.name_len])
		pos += need
	}

	return pos, .Ok
}

// detect_ast_cycle performs an iterative 3-color DFS across all nodes in cb to
// refuse any cycle (including self-edges) without recursion stack overflow.
@(private = "file")
detect_ast_cycle :: proc "contextless" (cb: ^Codebase) -> bool {
	// 0 = unvisited, 1 = on stack (visiting), 2 = finished.
	color: [MAX_NODES + 1]u8
	// Iterative frame stack: node_id and next child step index.
	stack_node: [MAX_NODES]u16
	stack_step: [MAX_NODES]u16

	for start_idx in 1 ..< int(cb.node_count) + 1 {
		if color[start_idx] != 0 {
			continue
		}
		top := 0
		stack_node[0] = u16(start_idx)
		stack_step[0] = 0
		color[start_idx] = 1
		top = 1

		for top > 0 {
			cur_id := Node_Id(stack_node[top - 1])
			step := int(stack_step[top - 1])
			node := &cb.nodes[cur_id - 1]
			next_child := NODE_NONE
			has_next := false

			switch node.kind {
			case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var, .Def_Ref:
			case .Unary, .Return_Stmt:
				if step == 0 {
					next_child = node.child_a
					has_next = true
				}
			case .Binary:
				if step == 0 {
					next_child = node.child_a
					has_next = true
				} else if step == 1 {
					next_child = node.child_b
					has_next = true
				}
			case .Let_Stmt:
				if step == 0 {
					next_child = node.child_a
					has_next = true
				} else if step == 1 && node.child_b != NODE_NONE {
					next_child = node.child_b
					has_next = true
				}
			case .If_Expr:
				if step == 0 {
					next_child = node.child_a
					has_next = true
				} else if step == 1 {
					next_child = node.child_b
					has_next = true
				} else if step == 2 {
					next_child = node.child_c
					has_next = true
				}
			case .Call:
				if step == 0 {
					next_child = node.child_a
					has_next = true
				} else if step - 1 < int(node.list_count) {
					next_child = cb.list_items[int(node.list_start) + (step - 1)]
					has_next = true
				}
			case .Block:
				if step < int(node.list_count) {
					next_child = cb.list_items[int(node.list_start) + step]
					has_next = true
				}
			}

			if !has_next {
				color[cur_id] = 2
				top -= 1
				continue
			}

			stack_step[top - 1] = u16(step + 1)
			if next_child == NODE_NONE {
				continue
			}
			c := color[next_child]
			if c == 1 {
				return true
			}
			if c == 0 {
				if top >= MAX_NODES {
					return true
				}
				color[next_child] = 1
				stack_node[top] = u16(next_child)
				stack_step[top] = 0
				top += 1
			}
		}
	}
	return false
}

// codebase_decode strictly validates and decodes a MODAST1 binary buffer into
// cb. On any refusal, cb is cleared to zero so partial state never leaks.
codebase_decode :: proc "contextless" (data: []u8, cb: ^Codebase) -> Codec_Error {
	cb^ = {}
	if len(data) < MODAST_HEADER_BYTES {
		return .Truncated
	}
	magic := MODAST_MAGIC
	for i in 0 ..< 8 {
		if data[i] != magic[i] {
			return .Bad_Magic
		}
	}
	version := byte_order.read_u16_little_endian(data, 8)
	if version != MODAST_VERSION {
		return .Bad_Version
	}
	flags := byte_order.read_u16_little_endian(data, 10)
	if flags != 0 {
		return .Bad_Flags
	}
	node_count := byte_order.read_u32_little_endian(data, 12)
	list_count := byte_order.read_u32_little_endian(data, 16)
	def_count := byte_order.read_u16_little_endian(data, 20)
	name_count := byte_order.read_u16_little_endian(data, 22)
	if node_count > MAX_NODES || list_count > MAX_LIST_ITEMS || def_count > MAX_DEFS || name_count > MAX_NAMES {
		return .Count_Out_Of_Range
	}
	cb.node_count = node_count
	cb.list_count = list_count
	cb.def_count = def_count
	cb.name_count = name_count
	pos := MODAST_HEADER_BYTES

	// Decode and validate nodes.
	for i in 0 ..< int(node_count) {
		if pos + MODAST_NODE_FIXED_BYTES > len(data) {
			cb^ = {}
			return .Truncated
		}
		kind, kind_ok := enum_word.member_of_word(Node_Kind, u64(data[pos + 0]))
		bin_op, bin_ok := enum_word.member_of_word(Bin_Op, u64(data[pos + 1]))
		unary_op, unary_ok := enum_word.member_of_word(Unary_Op, u64(data[pos + 2]))
		bool_byte := data[pos + 3]
		type_hint, type_ok := enum_word.member_of_word(Type_Kind, u64(data[pos + 4]))
		if !kind_ok || !bin_ok || !unary_ok || !type_ok || bool_byte > 1 {
			cb^ = {}
			return .Unknown_Enum
		}
		name_len := data[pos + 5]
		if int(name_len) > IDENT_LIMIT {
			cb^ = {}
			return .Bad_Name
		}
		var_slot := byte_order.read_u16_little_endian(data, pos + 6)
		int_value := i64(byte_order.read_u64_little_endian(data, pos + 8))
		child_a := Node_Id(byte_order.read_u32_little_endian(data, pos + 16))
		child_b := Node_Id(byte_order.read_u32_little_endian(data, pos + 20))
		child_c := Node_Id(byte_order.read_u32_little_endian(data, pos + 24))
		list_start := byte_order.read_u32_little_endian(data, pos + 28)
		node_list_count := byte_order.read_u16_little_endian(data, pos + 32)
		reserved := byte_order.read_u16_little_endian(data, pos + 34)
		if reserved != 0 {
			cb^ = {}
			return .Bad_Flags
		}
		if child_a > node_count || child_b > node_count || child_c > node_count {
			cb^ = {}
			return .Node_Out_Of_Range
		}
		if u64(list_start) + u64(node_list_count) > u64(list_count) {
			cb^ = {}
			return .List_Out_Of_Range
		}
		pos += MODAST_NODE_FIXED_BYTES

		node := &cb.nodes[i]
		node^ = Node{
			kind       = kind,
			bin_op     = bin_op,
			unary_op   = unary_op,
			bool_value = bool_byte == 1,
			type_hint  = type_hint,
			name_len   = name_len,
			var_slot   = var_slot,
			int_value  = int_value,
			child_a    = child_a,
			child_b    = child_b,
			child_c    = child_c,
			list_start = list_start,
			list_count = node_list_count,
		}
		if kind == .Def_Ref {
			if pos + 32 > len(data) {
				cb^ = {}
				return .Truncated
			}
			copy(node.ref_hash[:], data[pos:pos + 32])
			pos += 32
		}
		if name_len > 0 {
			if pos + int(name_len) > len(data) {
				cb^ = {}
				return .Truncated
			}
			copy(node.name[:name_len], data[pos:pos + int(name_len)])
			pos += int(name_len)
		}

		// Per-kind structural constraints (refuse missing required children and
		// any dangling child/list pointers in unused fields).
		switch kind {
		case .Hole, .Int_Lit, .Bool_Lit, .Def_Ref:
			if child_a != NODE_NONE || child_b != NODE_NONE || child_c != NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
		case .Text_Lit:
			if child_a != NODE_NONE || child_b != NODE_NONE || child_c != NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
			if !text_literal_valid(string(node.name[:name_len])) {
				cb^ = {}
				return .Bad_Name
			}
		case .Var:
			if child_a != NODE_NONE || child_b != NODE_NONE || child_c != NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
			if !ident_valid(string(node.name[:name_len])) {
				cb^ = {}
				return .Bad_Name
			}
		case .Unary, .Return_Stmt:
			if child_a == NODE_NONE || child_b != NODE_NONE || child_c != NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
		case .Binary:
			if child_a == NODE_NONE || child_b == NODE_NONE || child_c != NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
		case .Call:
			if child_a == NODE_NONE || child_b != NODE_NONE || child_c != NODE_NONE {
				cb^ = {}
				return .Node_Out_Of_Range
			}
		case .If_Expr:
			if child_a == NODE_NONE || child_b == NODE_NONE || child_c == NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
		case .Let_Stmt:
			if child_a == NODE_NONE || child_c != NODE_NONE || node_list_count != 0 {
				cb^ = {}
				return .Node_Out_Of_Range
			}
			if !ident_valid(string(node.name[:name_len])) {
				cb^ = {}
				return .Bad_Name
			}
		case .Block:
			if child_a != NODE_NONE || child_b != NODE_NONE || child_c != NODE_NONE {
				cb^ = {}
				return .Node_Out_Of_Range
			}
		}
	}

	// Decode and validate list items.
	if pos + int(list_count) * 4 > len(data) {
		cb^ = {}
		return .Truncated
	}
	for i in 0 ..< int(list_count) {
		item := Node_Id(byte_order.read_u32_little_endian(data, pos))
		pos += 4
		if item == NODE_NONE || item > node_count {
			cb^ = {}
			return .Node_Out_Of_Range
		}
		cb.list_items[i] = item
	}

	// Decode and validate definitions.
	for d in 0 ..< int(def_count) {
		if pos + 40 > len(data) {
			cb^ = {}
			return .Truncated
		}
		root := Node_Id(byte_order.read_u32_little_endian(data, pos + 0))
		param_count := data[pos + 4]
		ret_type, ret_ok := enum_word.member_of_word(Type_Kind, u64(data[pos + 5]))
		reserved := byte_order.read_u16_little_endian(data, pos + 6)
		if !ret_ok {
			cb^ = {}
			return .Unknown_Enum
		}
		if reserved != 0 {
			cb^ = {}
			return .Bad_Flags
		}
		if root == NODE_NONE || root > node_count {
			cb^ = {}
			return .Node_Out_Of_Range
		}
		if param_count > MAX_PARAMS {
			cb^ = {}
			return .Count_Out_Of_Range
		}
		def := &cb.defs[d]
		def.root = root
		def.param_count = param_count
		def.return_type = ret_type
		copy(def.hash[:], data[pos + 8:pos + 40])
		def.active = true
		pos += 40

		for p in 0 ..< int(param_count) {
			if pos + 2 > len(data) {
				cb^ = {}
				return .Truncated
			}
			p_type, p_ok := enum_word.member_of_word(Type_Kind, u64(data[pos + 0]))
			if !p_ok {
				cb^ = {}
				return .Unknown_Enum
			}
			p_len := data[pos + 1]
			pos += 2
			if p_len == 0 || int(p_len) > IDENT_LIMIT {
				cb^ = {}
				return .Bad_Name
			}
			if pos + int(p_len) > len(data) {
				cb^ = {}
				return .Truncated
			}
			param := &def.params[p]
			param.type = p_type
			param.name_len = p_len
			copy(param.name[:p_len], data[pos:pos + int(p_len)])
			pos += int(p_len)
			if !ident_valid(string(param.name[:p_len])) {
				cb^ = {}
				return .Bad_Name
			}
		}
	}

	// Decode and validate Name Table.
	for n in 0 ..< int(name_count) {
		if pos + 36 > len(data) {
			cb^ = {}
			return .Truncated
		}
		entry := &cb.names[n]
		copy(entry.def_hash[:], data[pos:pos + 32])
		entry.def_index = byte_order.read_u16_little_endian(data, pos + 32)
		entry.name_len = data[pos + 34]
		reserved := data[pos + 35]
		pos += 36
		if reserved != 0 {
			cb^ = {}
			return .Bad_Flags
		}
		if entry.def_index >= def_count {
			cb^ = {}
			return .Count_Out_Of_Range
		}
		if entry.name_len == 0 || int(entry.name_len) > IDENT_LIMIT {
			cb^ = {}
			return .Bad_Name
		}
		if pos + int(entry.name_len) > len(data) {
			cb^ = {}
			return .Truncated
		}
		copy(entry.name[:entry.name_len], data[pos:pos + int(entry.name_len)])
		pos += int(entry.name_len)
		name_str := string(entry.name[:entry.name_len])
		if !ident_valid(name_str) {
			cb^ = {}
			return .Bad_Name
		}
		for prev in 0 ..< n {
			if name_entry_text(&cb.names[prev]) == name_str {
				cb^ = {}
				return .Duplicate_Name
			}
		}
		entry.active = true
	}

	if pos != len(data) {
		cb^ = {}
		return .Trailing_Bytes
	}

	if detect_ast_cycle(cb) {
		cb^ = {}
		return .Cycle_Detected
	}

	codebase_rebuild_parents(cb)

	// Verify stored definition hashes match canonical alpha-normalized hashes.
	for d in 0 ..< int(def_count) {
		expected := hash_definition(cb, d)
		if cb.defs[d].hash != expected {
			cb^ = {}
			return .Hash_Mismatch
		}
	}

	// Verify every Name_Entry hash agrees with its linked definition.
	for n in 0 ..< int(name_count) {
		if cb.names[n].def_hash != cb.defs[cb.names[n].def_index].hash {
			cb^ = {}
			return .Hash_Mismatch
		}
	}

	return .Ok
}
