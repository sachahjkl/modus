// Unison-style alpha-normalized BLAKE3 definition hashing
// (src/md/features/codebase_ast.md).
//
// Two definitions with identical structure, types, and referenced definition
// hashes produce the exact same 32-byte BLAKE3 digest regardless of function,
// parameter, or local let-binding names.
package ast_codebase

import "modus:contract/blake3"
import "modus:contract/byte_order"

// Domain separation tag fed before every definition hash so AST digests never
// collide with plain file or module hashes.
HASH_DOMAIN_TAG :: "MODAST1\x00"

// Plan value: maximum simultaneously active lexical bindings during a single
// definition hash walk (parameters + nested let bindings).
@(private = "file")
HASH_SCOPE_CAPACITY :: 256

// Plan value: maximum recursion depth of a hash walk, bounded below stack
// limits even for degenerate chains.
@(private = "file")
HASH_DEPTH_LIMIT :: 256

@(private = "file")
Scope_Binding :: struct {
	raw_slot:       u16,
	canonical_slot: u32,
}

@(private = "file")
Hash_Scope :: struct {
	entries:   [HASH_SCOPE_CAPACITY]Scope_Binding,
	count:     int,
	next_slot: u32,
}

@(private = "file")
scope_push :: proc "contextless" (scope: ^Hash_Scope, raw_slot: u16) -> u32 {
	assigned := scope.next_slot
	scope.next_slot += 1
	if scope.count < HASH_SCOPE_CAPACITY {
		scope.entries[scope.count] = Scope_Binding{raw_slot = raw_slot, canonical_slot = assigned}
		scope.count += 1
	}
	return assigned
}

// scope_lookup walks from innermost to outermost binding so shadowed slots
// resolve to the closest enclosing binder.
@(private = "file")
scope_lookup :: proc "contextless" (scope: ^Hash_Scope, raw_slot: u16) -> (canonical: u32, found: bool) {
	for i := scope.count - 1; i >= 0; i -= 1 {
		if scope.entries[i].raw_slot == raw_slot {
			return scope.entries[i].canonical_slot, true
		}
	}
	return 0, false
}

@(private = "file")
hash_u8 :: proc "contextless" (hasher: ^blake3.Hasher, v: u8) {
	buf := [1]u8{v}
	blake3.hasher_update(hasher, buf[:])
}

@(private = "file")
hash_u16_le :: proc "contextless" (hasher: ^blake3.Hasher, v: u16) {
	buf: [2]u8
	byte_order.write_u16_little_endian(buf[:], 0, v)
	blake3.hasher_update(hasher, buf[:])
}

@(private = "file")
hash_u32_le :: proc "contextless" (hasher: ^blake3.Hasher, v: u32) {
	buf: [4]u8
	byte_order.write_u32_little_endian(buf[:], 0, v)
	blake3.hasher_update(hasher, buf[:])
}

@(private = "file")
hash_i64_le :: proc "contextless" (hasher: ^blake3.Hasher, v: i64) {
	buf: [8]u8
	byte_order.write_u64_little_endian(buf[:], 0, u64(v))
	blake3.hasher_update(hasher, buf[:])
}

// hash_node walks one subtree in canonical pre-order, stripping all parameter,
// variable, and let-binding display names.
@(private = "file")
hash_node :: proc "contextless" (cb: ^Codebase, hasher: ^blake3.Hasher, scope: ^Hash_Scope, id: Node_Id, depth: int) {
	if depth >= HASH_DEPTH_LIMIT {
		hash_u8(hasher, 0xFF)
		return
	}
	node := node_get(cb, id)
	if node == nil {
		hash_u8(hasher, 0xFE)
		return
	}
	hash_u8(hasher, u8(node.kind))
	switch node.kind {
	case .Hole:
		hash_u8(hasher, u8(node.type_hint))
	case .Int_Lit:
		hash_i64_le(hasher, node.int_value)
	case .Bool_Lit:
		hash_u8(hasher, node.bool_value ? 1 : 0)
	case .Text_Lit:
		hash_u32_le(hasher, u32(node.name_len))
		if node.name_len > 0 {
			blake3.hasher_update(hasher, node.name[:node.name_len])
		}
	case .Var:
		if canonical, found := scope_lookup(scope, node.var_slot); found {
			hash_u8(hasher, 1)
			hash_u32_le(hasher, canonical)
		} else {
			// Unresolved variable during editing: distinct marker + raw slot.
			hash_u8(hasher, 0)
			hash_u16_le(hasher, node.var_slot)
		}
	case .Def_Ref:
		blake3.hasher_update(hasher, node.ref_hash[:])
	case .Unary:
		hash_u8(hasher, u8(node.unary_op))
		hash_node(cb, hasher, scope, node.child_a, depth + 1)
	case .Binary:
		hash_u8(hasher, u8(node.bin_op))
		hash_node(cb, hasher, scope, node.child_a, depth + 1)
		hash_node(cb, hasher, scope, node.child_b, depth + 1)
	case .Call:
		hash_node(cb, hasher, scope, node.child_a, depth + 1)
		hash_u16_le(hasher, node.list_count)
		for i in 0 ..< int(node.list_count) {
			arg_id := cb.list_items[int(node.list_start) + i]
			hash_node(cb, hasher, scope, arg_id, depth + 1)
		}
	case .If_Expr:
		hash_node(cb, hasher, scope, node.child_a, depth + 1)
		hash_node(cb, hasher, scope, node.child_b, depth + 1)
		hash_node(cb, hasher, scope, node.child_c, depth + 1)
	case .Let_Stmt:
		// Bound expression is evaluated before introducing the new binding.
		hash_node(cb, hasher, scope, node.child_a, depth + 1)
		assigned := scope_push(scope, node.var_slot)
		hash_u32_le(hasher, assigned)
		if node.child_b != NODE_NONE {
			hash_u8(hasher, 1)
			saved := scope.count
			hash_node(cb, hasher, scope, node.child_b, depth + 1)
			scope.count = saved
		} else {
			hash_u8(hasher, 0)
		}
	case .Return_Stmt:
		hash_node(cb, hasher, scope, node.child_a, depth + 1)
	case .Block:
		saved := scope.count
		hash_u16_le(hasher, node.list_count)
		for i in 0 ..< int(node.list_count) {
			stmt_id := cb.list_items[int(node.list_start) + i]
			hash_node(cb, hasher, scope, stmt_id, depth + 1)
		}
		scope.count = saved
	}
}

// hash_definition computes the alpha-normalized 32-byte BLAKE3 hash of one
// definition. Parameter names, let names, and the definition's own Name_Table
// string are never hashed.
hash_definition :: proc "contextless" (cb: ^Codebase, def_index: int) -> (digest: [32]u8) {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return {}
	}
	def := &cb.defs[def_index]
	hasher := blake3.hasher_make()
	tag := HASH_DOMAIN_TAG
	blake3.hasher_update(&hasher, transmute([]u8)tag)

	scope: Hash_Scope
	hash_u8(&hasher, def.param_count)
	for i in 0 ..< int(def.param_count) {
		hash_u8(&hasher, u8(def.params[i].type))
		_ = scope_push(&scope, u16(i))
	}
	hash_u8(&hasher, u8(def.return_type))
	hash_node(cb, &hasher, &scope, def.root, 0)
	return blake3.hasher_finish(&hasher)
}

// update_def_refs_in_subtree rewrites Def_Ref nodes pointing at old_hash to
// new_hash so callers stay linked when a referenced definition's body changes.
@(private = "file")
update_def_refs_in_subtree :: proc "contextless" (cb: ^Codebase, id: Node_Id, old_hash: [32]u8, new_hash: [32]u8) -> bool {
	node := node_get(cb, id)
	if node == nil {
		return false
	}
	changed := false
	switch node.kind {
	case .Def_Ref:
		if node.ref_hash == old_hash {
			node.ref_hash = new_hash
			changed = true
		}
	case .Hole, .Int_Lit, .Bool_Lit, .Text_Lit, .Var:
	case .Unary, .Return_Stmt:
		if update_def_refs_in_subtree(cb, node.child_a, old_hash, new_hash) {
			changed = true
		}
	case .Binary:
		if update_def_refs_in_subtree(cb, node.child_a, old_hash, new_hash) {
			changed = true
		}
		if update_def_refs_in_subtree(cb, node.child_b, old_hash, new_hash) {
			changed = true
		}
	case .Let_Stmt:
		if update_def_refs_in_subtree(cb, node.child_a, old_hash, new_hash) {
			changed = true
		}
		if node.child_b != NODE_NONE && update_def_refs_in_subtree(cb, node.child_b, old_hash, new_hash) {
			changed = true
		}
	case .If_Expr:
		if update_def_refs_in_subtree(cb, node.child_a, old_hash, new_hash) {
			changed = true
		}
		if update_def_refs_in_subtree(cb, node.child_b, old_hash, new_hash) {
			changed = true
		}
		if update_def_refs_in_subtree(cb, node.child_c, old_hash, new_hash) {
			changed = true
		}
	case .Call:
		if update_def_refs_in_subtree(cb, node.child_a, old_hash, new_hash) {
			changed = true
		}
		for i in 0 ..< int(node.list_count) {
			if update_def_refs_in_subtree(cb, cb.list_items[int(node.list_start) + i], old_hash, new_hash) {
				changed = true
			}
		}
	case .Block:
		for i in 0 ..< int(node.list_count) {
			if update_def_refs_in_subtree(cb, cb.list_items[int(node.list_start) + i], old_hash, new_hash) {
				changed = true
			}
		}
	}
	return changed
}

// codebase_rehash_definition recomputes the hash of def_index, updates its
// Name_Table entry, propagates hash updates to callers referencing the old
// hash, and rehashes any affected callers until fixed point.
codebase_rehash_definition :: proc "contextless" (cb: ^Codebase, def_index: int) -> (old_hash: [32]u8, new_hash: [32]u8) {
	if def_index < 0 || def_index >= int(cb.def_count) || !cb.defs[def_index].active {
		return {}, {}
	}
	old_hash = cb.defs[def_index].hash
	new_hash = hash_definition(cb, def_index)
	if old_hash == new_hash {
		return old_hash, new_hash
	}
	cb.defs[def_index].hash = new_hash
	// Update Name_Table entries attached to this specific definition index.
	for i in 0 ..< int(cb.name_count) {
		if cb.names[i].active && int(cb.names[i].def_index) == def_index {
			cb.names[i].def_hash = new_hash
		}
	}
	// Propagate Def_Ref updates and rehash affected callers up to def_count passes.
	pending_old: [MAX_DEFS][32]u8
	pending_new: [MAX_DEFS][32]u8
	pending_def: [MAX_DEFS]int
	pending_count := 1
	pending_old[0] = old_hash
	pending_new[0] = new_hash
	pending_def[0] = def_index

	for pass := 0; pass < int(cb.def_count) && pending_count > 0; pass += 1 {
		next_old: [MAX_DEFS][32]u8
		next_new: [MAX_DEFS][32]u8
		next_def: [MAX_DEFS]int
		next_count := 0
		for p in 0 ..< pending_count {
			for d in 0 ..< int(cb.def_count) {
				if !cb.defs[d].active || d == pending_def[p] {
					continue
				}
				if update_def_refs_in_subtree(cb, cb.defs[d].root, pending_old[p], pending_new[p]) {
					caller_old := cb.defs[d].hash
					caller_new := hash_definition(cb, d)
					if caller_old != caller_new {
						cb.defs[d].hash = caller_new
						for ni in 0 ..< int(cb.name_count) {
							if cb.names[ni].active && int(cb.names[ni].def_index) == d {
								cb.names[ni].def_hash = caller_new
							}
						}
						if next_count < MAX_DEFS {
							next_old[next_count] = caller_old
							next_new[next_count] = caller_new
							next_def[next_count] = d
							next_count += 1
						}
					}
				}
			}
		}
		pending_old = next_old
		pending_new = next_new
		pending_def = next_def
		pending_count = next_count
	}
	return old_hash, new_hash
}

// codebase_rehash_all recomputes all active definition hashes and synchronizes
// Name_Table caches. Renames keep every hash identical.
codebase_rehash_all :: proc "contextless" (cb: ^Codebase) {
	for pass := 0; pass < int(cb.def_count) + 1; pass += 1 {
		any_changed := false
		for d in 0 ..< int(cb.def_count) {
			if !cb.defs[d].active {
				continue
			}
			old_h := cb.defs[d].hash
			new_h := hash_definition(cb, d)
			if old_h != new_h {
				cb.defs[d].hash = new_h
				for ni in 0 ..< int(cb.name_count) {
					if cb.names[ni].active && int(cb.names[ni].def_index) == d {
						cb.names[ni].def_hash = new_h
					}
				}
				for caller in 0 ..< int(cb.def_count) {
					if cb.defs[caller].active && caller != d {
						_ = update_def_refs_in_subtree(cb, cb.defs[caller].root, old_h, new_h)
					}
				}
				any_changed = true
			}
		}
		if !any_changed {
			break
		}
	}
	for ni in 0 ..< int(cb.name_count) {
		if !cb.names[ni].active {
			continue
		}
		idx := int(cb.names[ni].def_index)
		if idx >= 0 && idx < int(cb.def_count) && cb.defs[idx].active {
			cb.names[ni].def_hash = cb.defs[idx].hash
		} else if found_idx, ok := codebase_find_def_by_hash(cb, cb.names[ni].def_hash); ok {
			cb.names[ni].def_index = u16(found_idx)
		} else {
			cb.names[ni].def_index = DEF_INDEX_NONE
		}
	}
}
