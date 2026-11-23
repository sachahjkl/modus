// Caller-owned L1 compile cache and L2 incremental evaluation cache for Lex v2
// (src/md/features/declarations.md, "Lex v2 engine").
//
// Strictly caller-owned and freestanding (zero host I/O, zero ambient state).
// `declaration_eval` never accepts cache entries from untrusted wire input;
// callers (`projects`, `recipes`, `modustool`, `console`) supply backing memory
// via `query_cache_bytes` and `query_cache_carve`.
//
// Soundness invariants:
// - L1 caches parsed AST slices keyed by full 32-byte BLAKE3 source hash.
// - L2 caches canonical serialized query outputs keyed by (field_path, bindings,
//   here_hash) plus recorded import dependencies, per-field canonical BLAKE3
//   hashes, and Record_Shape shape hashes (negative dependencies for `has`,
//   `fields`, `values`, `with`, `extend`, `merge_deep`, destructuring, and
//   record serialization).
// - Closure exports disable early cutoff and fall back to file-hash matching.
// - Any evaluation that executed `trace(...)` opts out of L2 caching.
package lex_evaluator

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:hash_table"
import "modus:lex_parser"

// Caller-supplied sizing for a Query_Cache.
Query_Cache_Pools :: struct {
	l1_entries:      int,
	l1_nodes:        int,
	l1_extra:        int,
	l1_int_consts:   int,
	l2_entries:      int,
	l2_deps:         int,
	l2_field_deps:   int,
	l2_bytes:        int,
	tracker_imports: int,
	tracker_fields:  int,
}

// Default sizing for a multi-hundred-file project graph (caller may pass
// smaller or larger counts to fit its memory budget).
QUERY_CACHE_DEFAULT_POOLS :: Query_Cache_Pools {
	l1_entries      = 1024,
	l1_nodes        = 256 * 1024,
	l1_extra        = 256 * 1024,
	l1_int_consts   = 16 * 1024,
	l2_entries      = 1024,
	l2_deps         = 8 * 1024,
	l2_field_deps   = 32 * 1024,
	l2_bytes        = 2 * 1024 * 1024,
	tracker_imports = 1024,
	tracker_fields  = 8 * 1024,
}

// Inline cap on distinct tracked field names per single imported module before
// widening that dependency to whole-record tracking (inline capacity: past 32
// distinct fields accessed on one module, track the whole record instead of
// growing per-import field lists).
@(private = "file")
TRACKER_FIELDS_PER_IMPORT_LIMIT :: 32

@(private = "file")
QC_ALIGNMENT :: 64

@(private = "file")
qc_align_up :: #force_inline proc "contextless" (offset: int, size: int) -> int {
	return (offset + size + QC_ALIGNMENT - 1) &~ (QC_ALIGNMENT - 1)
}

@(private = "file")
qc_carve_slice :: proc "contextless" ($T: typeid, base: [^]u8, at: ^int, count: int) -> []T {
	out := ([^]T)(&base[at^])[:count]
	at^ = qc_align_up(at^, count * size_of(T))
	return out
}

@(private = "file")
hash_u64_prefix :: #force_inline proc "contextless" (h: blake3.Hash) -> u64 {
	return u64(h[0]) | (u64(h[1]) << 8) | (u64(h[2]) << 16) | (u64(h[3]) << 24) |
		(u64(h[4]) << 32) | (u64(h[5]) << 40) | (u64(h[6]) << 48) | (u64(h[7]) << 56)
}

@(private = "file")
L1_Entry :: struct {
	source_hash:     blake3.Hash,
	source_len:      u32,
	nodes_off:       u32,
	node_count:      u32,
	extra_off:       u32,
	extra_count:     u32,
	int_consts_off:  u32,
	int_const_count: u32,
	root:            lex_parser.Node_Index,
}

@(private = "file")
L2_Field_Dep :: struct {
	name_off:   u32,
	name_len:   u32,
	value_hash: blake3.Hash,
}

@(private = "file")
L2_Dep :: struct {
	by_hash:         bool,
	whole_accessed:  bool,
	shape_inspected: bool,
	has_closure:     bool,
	path_off:        u32,
	path_len:        u32,
	target_hash:     blake3.Hash, // Used when by_hash == true.
	file_hash:       blake3.Hash, // BLAKE3 of imported source bytes.
	root_shape_hash: u64,
	whole_hash:      blake3.Hash,
	fields_off:      u32,
	field_count:     u32,
}

@(private = "file")
L2_Entry :: struct {
	query_key:  blake3.Hash,
	root_hash:  blake3.Hash,
	output_off: u32,
	output_len: u32,
	deps_off:   u32,
	dep_count:  u32,
	valid:      bool,
}

@(private = "file")
Tracker_Import :: struct {
	whole_accessed:  bool,
	shape_inspected: bool,
	root_shape_hash: u64,
	field_count:     u16,
	fields:          [TRACKER_FIELDS_PER_IMPORT_LIMIT]lex_parser.Sym_Id,
}

// Caller-owned incremental cache handle. All pools are carved from caller
// memory via `query_cache_carve`.
Query_Cache :: struct {
	seed:            u64,
	// L1 parse cache
	l1_index:        hash_table.Slice_Hash_Index(u32),
	l1_entries:      []L1_Entry,
	l1_entry_count:  int,
	l1_nodes:        []lex_parser.Ast_Node,
	l1_nodes_used:   int,
	l1_extra:        []lex_parser.Node_Index,
	l1_extra_used:   int,
	l1_int_consts:   []i64,
	l1_ints_used:    int,
	// L2 incremental query cache
	l2_index:        hash_table.Slice_Hash_Index(u32),
	l2_entries:      []L2_Entry,
	l2_entry_count:  int,
	l2_deps:         []L2_Dep,
	l2_deps_used:    int,
	l2_field_deps:   []L2_Field_Dep,
	l2_fields_used:  int,
	l2_bytes:        []u8,
	l2_bytes_used:   int,
	// Active dependency tracker scratch (used during one L2 miss evaluation)
	tracker_imports: []Tracker_Import,
	tracker_count:   int,
	tracker_overflow: bool,
}

query_cache_bytes :: proc "contextless" (pools: Query_Cache_Pools) -> int {
	l1_e := max(pools.l1_entries, 16)
	l2_e := max(pools.l2_entries, 16)
	l1_slots := hash_table.slice_index_groups_for_entries(l1_e) * hash_table.GROUP_WIDTH
	l2_slots := hash_table.slice_index_groups_for_entries(l2_e) * hash_table.GROUP_WIDTH
	tr_imp := max(pools.tracker_imports, 64)
	at := 0
	at = qc_align_up(at, l1_slots * size_of(u8))
	at = qc_align_up(at, l1_slots * size_of(u32))
	at = qc_align_up(at, l1_e * size_of(L1_Entry))
	at = qc_align_up(at, max(pools.l1_nodes, 256) * size_of(lex_parser.Ast_Node))
	at = qc_align_up(at, max(pools.l1_extra, 256) * size_of(lex_parser.Node_Index))
	at = qc_align_up(at, max(pools.l1_int_consts, 64) * size_of(i64))
	at = qc_align_up(at, l2_slots * size_of(u8))
	at = qc_align_up(at, l2_slots * size_of(u32))
	at = qc_align_up(at, l2_e * size_of(L2_Entry))
	at = qc_align_up(at, max(pools.l2_deps, 64) * size_of(L2_Dep))
	at = qc_align_up(at, max(pools.l2_field_deps, 128) * size_of(L2_Field_Dep))
	at = qc_align_up(at, max(pools.l2_bytes, 4096))
	at = qc_align_up(at, tr_imp * size_of(Tracker_Import))
	return at
}

query_cache_carve :: proc "contextless" (cache: ^Query_Cache, memory: []u8, pools: Query_Cache_Pools, seed: u64 = 0) -> bool {
	if cache == nil || len(memory) < query_cache_bytes(pools) || uintptr(raw_data(memory)) & (QC_ALIGNMENT - 1) != 0 {
		return false
	}
	l1_e := max(pools.l1_entries, 16)
	l2_e := max(pools.l2_entries, 16)
	l1_slots := hash_table.slice_index_groups_for_entries(l1_e) * hash_table.GROUP_WIDTH
	l2_slots := hash_table.slice_index_groups_for_entries(l2_e) * hash_table.GROUP_WIDTH
	tr_imp := max(pools.tracker_imports, 64)

	base := raw_data(memory)
	at := 0

	l1_ctrl := qc_carve_slice(u8, base, &at, l1_slots)
	l1_refs := qc_carve_slice(u32, base, &at, l1_slots)
	l1_idx, ok1 := hash_table.slice_index_init(u32, l1_ctrl, l1_refs, seed)
	if !ok1 {
		return false
	}
	cache.l1_index = l1_idx
	cache.l1_entries = qc_carve_slice(L1_Entry, base, &at, l1_e)
	cache.l1_nodes = qc_carve_slice(lex_parser.Ast_Node, base, &at, max(pools.l1_nodes, 256))
	cache.l1_extra = qc_carve_slice(lex_parser.Node_Index, base, &at, max(pools.l1_extra, 256))
	cache.l1_int_consts = qc_carve_slice(i64, base, &at, max(pools.l1_int_consts, 64))

	l2_ctrl := qc_carve_slice(u8, base, &at, l2_slots)
	l2_refs := qc_carve_slice(u32, base, &at, l2_slots)
	l2_idx, ok2 := hash_table.slice_index_init(u32, l2_ctrl, l2_refs, seed)
	if !ok2 {
		return false
	}
	cache.l2_index = l2_idx
	cache.l2_entries = qc_carve_slice(L2_Entry, base, &at, l2_e)
	cache.l2_deps = qc_carve_slice(L2_Dep, base, &at, max(pools.l2_deps, 64))
	cache.l2_field_deps = qc_carve_slice(L2_Field_Dep, base, &at, max(pools.l2_field_deps, 128))
	cache.l2_bytes = qc_carve_slice(u8, base, &at, max(pools.l2_bytes, 4096))
	cache.tracker_imports = qc_carve_slice(Tracker_Import, base, &at, tr_imp)
	cache.seed = seed

	query_cache_clear(cache)
	return true
}

query_cache_clear :: proc "contextless" (cache: ^Query_Cache) {
	if cache == nil {
		return
	}
	l1_clear(cache)
	l2_clear(cache)
}

@(private = "file")
l1_clear :: proc "contextless" (cache: ^Query_Cache) {
	hash_table.slice_index_clear(&cache.l1_index)
	cache.l1_entry_count = 0
	cache.l1_nodes_used = 0
	cache.l1_extra_used = 0
	cache.l1_ints_used = 0
}

@(private = "file")
l2_clear :: proc "contextless" (cache: ^Query_Cache) {
	hash_table.slice_index_clear(&cache.l2_index)
	cache.l2_entry_count = 0
	cache.l2_deps_used = 0
	cache.l2_fields_used = 0
	cache.l2_bytes_used = 0
}

// ---- L1 Parse Cache (keyed by full 32-byte BLAKE3 source hash).

@(private = "file")
l1_hash_of_ref :: proc "contextless" (owner: rawptr, ref: u64) -> u64 {
	c := (^Query_Cache)(owner)
	return hash_table.slice_index_hash_word(&c.l1_index, hash_u64_prefix(c.l1_entries[int(ref)].source_hash))
}

@(private)
l1_cache_lookup_into :: proc "contextless" (cache: ^Query_Cache, ws: ^Declaration_Workspace, source: string, tree: ^lex_parser.Syntax_Tree) -> bool {
	if cache == nil || cache.l1_entry_count == 0 {
		return false
	}
	src_hash := blake3.hash(transmute([]u8)source)
	h := hash_table.slice_index_hash_word(&cache.l1_index, hash_u64_prefix(src_hash))
	probe := hash_table.slice_index_search_begin(&cache.l1_index, h)
	for {
		ref, _, ok := hash_table.slice_index_search_next(&cache.l1_index, &probe)
		if !ok {
			return false
		}
		if int(ref) >= cache.l1_entry_count {
			continue
		}
		e := &cache.l1_entries[ref]
		if int(e.source_len) != len(source) || e.source_hash != src_hash {
			continue
		}
		nc := int(e.node_count)
		ec := int(e.extra_count)
		ic := int(e.int_const_count)
		if ws.nodes_used + nc > ws.node_limit ||
		   ws.extra_used + ec > len(ws.extra_children) ||
		   ws.int_consts_used + ic > len(ws.int_consts) {
			return false
		}
		dst_nodes := ws.nodes[ws.nodes_used:ws.nodes_used + nc]
		dst_extra := ws.extra_children[ws.extra_used:ws.extra_used + ec]
		dst_ints := ws.int_consts[ws.int_consts_used:ws.int_consts_used + ic]
		copy(dst_nodes, cache.l1_nodes[int(e.nodes_off):int(e.nodes_off) + nc])
		copy(dst_extra, cache.l1_extra[int(e.extra_off):int(e.extra_off) + ec])
		copy(dst_ints, cache.l1_int_consts[int(e.int_consts_off):int(e.int_consts_off) + ic])
		tree^ = {
			text            = source,
			nodes           = dst_nodes,
			node_count      = nc,
			extra_children  = dst_extra,
			extra_count     = ec,
			int_consts      = dst_ints,
			int_const_count = ic,
			root            = e.root,
			refusal         = {},
		}
		return true
	}
}

@(private)
l1_cache_store :: proc "contextless" (cache: ^Query_Cache, source: string, tree: ^lex_parser.Syntax_Tree) {
	if cache == nil || tree == nil || tree.refusal.refusal != .None {
		return
	}
	nc := tree.node_count
	ec := tree.extra_count
	ic := tree.int_const_count
	if nc > len(cache.l1_nodes) || ec > len(cache.l1_extra) || ic > len(cache.l1_int_consts) || len(cache.l1_entries) == 0 {
		return
	}
	if cache.l1_entry_count >= len(cache.l1_entries) ||
	   cache.l1_nodes_used + nc > len(cache.l1_nodes) ||
	   cache.l1_extra_used + ec > len(cache.l1_extra) ||
	   cache.l1_ints_used + ic > len(cache.l1_int_consts) {
		l1_clear(cache)
	}
	src_hash := blake3.hash(transmute([]u8)source)
	idx := u32(cache.l1_entry_count)
	noff := u32(cache.l1_nodes_used)
	eoff := u32(cache.l1_extra_used)
	ioff := u32(cache.l1_ints_used)
	copy(cache.l1_nodes[int(noff):int(noff) + nc], tree.nodes[:nc])
	copy(cache.l1_extra[int(eoff):int(eoff) + ec], tree.extra_children[:ec])
	copy(cache.l1_int_consts[int(ioff):int(ioff) + ic], tree.int_consts[:ic])
	cache.l1_entries[idx] = {
		source_hash     = src_hash,
		source_len      = u32(len(source)),
		nodes_off       = noff,
		node_count      = u32(nc),
		extra_off       = eoff,
		extra_count     = u32(ec),
		int_consts_off  = ioff,
		int_const_count = u32(ic),
		root            = tree.root,
	}
	h := hash_table.slice_index_hash_word(&cache.l1_index, hash_u64_prefix(src_hash))
	if !hash_table.slice_index_insert(&cache.l1_index, h, idx, cache, l1_hash_of_ref) {
		l1_clear(cache)
		idx = 0
		noff = 0
		eoff = 0
		ioff = 0
		copy(cache.l1_nodes[:nc], tree.nodes[:nc])
		copy(cache.l1_extra[:ec], tree.extra_children[:ec])
		copy(cache.l1_int_consts[:ic], tree.int_consts[:ic])
		cache.l1_entries[0] = {
			source_hash     = src_hash,
			source_len      = u32(len(source)),
			nodes_off       = 0,
			node_count      = u32(nc),
			extra_off       = 0,
			extra_count     = u32(ec),
			int_consts_off  = 0,
			int_const_count = u32(ic),
			root            = tree.root,
		}
		if !hash_table.slice_index_insert(&cache.l1_index, h, 0, cache, l1_hash_of_ref) {
			return
		}
		cache.l1_entry_count = 1
		cache.l1_nodes_used = nc
		cache.l1_extra_used = ec
		cache.l1_ints_used = ic
		return
	}
	cache.l1_entry_count += 1
	cache.l1_nodes_used += nc
	cache.l1_extra_used += ec
	cache.l1_ints_used += ic
}

// ---- Streaming canonical BLAKE3 value hashing (zero scratch buffer cap).

@(private = "file")
hasher_put_u8 :: #force_inline proc "contextless" (h: ^blake3.Hasher, b: u8) {
	buf := [1]u8{b}
	blake3.hasher_update(h, buf[:])
}

@(private = "file")
hasher_put_u32 :: #force_inline proc "contextless" (h: ^blake3.Hasher, v: u32) {
	buf := [4]u8{u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	blake3.hasher_update(h, buf[:])
}

@(private = "file")
hasher_put_u64 :: #force_inline proc "contextless" (h: ^blake3.Hasher, v: u64) {
	buf := [8]u8{u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24), u8(v >> 32), u8(v >> 40), u8(v >> 48), u8(v >> 56)}
	blake3.hasher_update(h, buf[:])
}

@(private = "file")
hasher_put_str :: #force_inline proc "contextless" (h: ^blake3.Hasher, s: string) {
	hasher_put_u32(h, u32(len(s)))
	if len(s) > 0 {
		blake3.hasher_update(h, transmute([]u8)s)
	}
}

@(private = "file")
hash_value_stream :: proc "contextless" (ws: ^Declaration_Workspace, h: ^blake3.Hasher, value: Value, depth: int) -> (ok: bool, is_closure: bool) {
	if depth >= declaration_eval.OUTPUT_DEPTH_LIMIT {
		return false, false
	}
	if !charge_steps(&ws.evaluation, 1, 0, lex_parser.NO_NODE) {
		return false, false
	}
	switch value.kind {
	case .Integer:
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Integer))
		hasher_put_u64(h, u64(value_integer(value)))
		return true, false
	case .Boolean:
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Boolean))
		hasher_put_u8(h, value_boolean(value) ? 1 : 0)
		return true, false
	case .Text:
		txt := value_text(&ws.evaluation, value)
		if !charge_steps(&ws.evaluation, u32(len(txt) / 64), 0, lex_parser.NO_NODE) {
			return false, false
		}
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Text))
		hasher_put_str(h, txt)
		return true, false
	case .Hash:
		hv, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return false, false
		}
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Hash))
		blake3.hasher_update(h, hv[:])
		return true, false
	case .Member:
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Member))
		hasher_put_str(h, member_name_of(&ws.evaluation, value))
		return true, false
	case .Module_Ref:
		hv, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return false, false
		}
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Module_Ref))
		blake3.hasher_update(h, hv[:])
		return true, false
	case .Tree_Ref:
		hv, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return false, false
		}
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Tree_Ref))
		blake3.hasher_update(h, hv[:])
		return true, false
	case .Follow_Ref:
		hv, hok := hash_of(&ws.evaluation, value)
		if !hok {
			return false, false
		}
		fname := value_follow_name(&ws.evaluation, value)
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Follow_Ref))
		blake3.hasher_update(h, hv[:])
		hasher_put_str(h, fname)
		return true, false
	case .Store_Ref:
		sname := value_store_name(&ws.evaluation, value)
		rights := list_items_of(&ws.evaluation, value)
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Store_Ref))
		hasher_put_str(h, sname)
		hasher_put_u32(h, u32(len(rights)))
		for right in rights {
			hasher_put_str(h, member_name_of(&ws.evaluation, right))
		}
		return true, false
	case .Recipe_Ref:
		idx := int(value.data)
		if idx < 0 || idx >= ws.evaluation.recipe_count {
			return false, false
		}
		rec := ws.evaluation.recipes[idx]
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Recipe_Ref))
		rh := rec.recipe_hash
		bh := rec.builder_hash
		blake3.hasher_update(h, rh[:])
		blake3.hasher_update(h, bh[:])
		return hash_value_stream(ws, h, rec.arguments, depth + 1)
	case .List:
		items := list_items_of(&ws.evaluation, value)
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.List))
		hasher_put_u32(h, u32(len(items)))
		for item in items {
			iok, icl := hash_value_stream(ws, h, item, depth + 1)
			if !iok {
				return false, icl
			}
		}
		return true, false
	case .Record_Literal, .Record_With:
		shape_id, sok := lazy_record_base_shape(&ws.evaluation, value)
		if !sok {
			return false, false
		}
		shape := &ws.evaluation.shapes[shape_id]
		fcount := int(shape.field_count)
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Record))
		hasher_put_u32(h, u32(fcount))
		for i in 0 ..< fcount {
			sym := ws.evaluation.shape_fields[int(shape.fields_off) + i]
			hasher_put_str(h, lex_parser.sym_text(&ws.evaluation.interner, sym))
			tref, found := lazy_record_lookup_thunk(&ws.evaluation, value, sym)
			if !found {
				return false, false
			}
			fval, fok := vm_force_thunk(&ws.evaluation, tref, 0, lex_parser.NO_NODE)
			if !fok {
				return false, false
			}
			iok, icl := hash_value_stream(ws, h, fval, depth + 1)
			if !iok {
				return false, icl
			}
		}
		return true, false
	case .Plan_Value:
		idx := int(value.data)
		if idx < 0 || idx >= ws.evaluation.tagged_record_count {
			return false, false
		}
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Plan))
		return hash_value_stream(ws, h, ws.evaluation.tagged_records[idx], depth + 1)
	case .Project_Value:
		idx := int(value.data)
		if idx < 0 || idx >= ws.evaluation.tagged_record_count {
			return false, false
		}
		hasher_put_u8(h, u8(declaration_eval.Value_Tag.Project))
		return hash_value_stream(ws, h, ws.evaluation.tagged_records[idx], depth + 1)
	case .Function:
		return false, true
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum:
		return false, false
	}
	return false, false
}

@(private = "file")
hash_value_canonical :: proc "contextless" (ws: ^Declaration_Workspace, value: Value) -> (hash: blake3.Hash, ok: bool, is_closure: bool) {
	hasher := blake3.hasher_make_derive_key("modus lex value v2")
	ok, is_closure = hash_value_stream(ws, &hasher, value, 0)
	if !ok {
		return {}, false, is_closure
	}
	return blake3.hasher_finish(&hasher), true, false
}

// ---- Query key computation (field_path + bindings + here_hash).

@(private = "file")
compute_query_key :: proc "contextless" (field_path: string, config: Declaration_Config) -> blake3.Hash {
	h := blake3.hasher_make_derive_key("modus lex query v2")
	hasher_put_str(&h, field_path)
	hasher_put_u8(&h, config.has_here ? 1 : 0)
	if config.has_here {
		hh := config.here_hash
		blake3.hasher_update(&h, hh[:])
	}
	hasher_put_u32(&h, u32(len(config.bindings)))
	for b in config.bindings {
		hasher_put_str(&h, b.name)
		hasher_put_u8(&h, u8(b.kind))
		switch b.kind {
		case .Integer:
			hasher_put_u64(&h, u64(b.integer))
		case .Boolean:
			hasher_put_u8(&h, b.boolean ? 1 : 0)
		case .Text:
			hasher_put_str(&h, b.text)
		case .Hash, .Module_Ref:
			bh := b.hash
			blake3.hasher_update(&h, bh[:])
		case .Lex_Source:
			sh := blake3.hash(transmute([]u8)b.source)
			blake3.hasher_update(&h, sh[:])
		}
	}
	return blake3.hasher_finish(&h)
}

// ---- Dependency tracker callbacks attached during one L2 miss evaluation.

@(private = "file")
tracker_ensure :: proc "contextless" (cache: ^Query_Cache, import_owner: int) -> ^Tracker_Import {
	if import_owner < 0 {
		return nil
	}
	if import_owner >= len(cache.tracker_imports) {
		cache.tracker_overflow = true
		return nil
	}
	for cache.tracker_count <= import_owner {
		cache.tracker_imports[cache.tracker_count] = {}
		cache.tracker_count += 1
	}
	return &cache.tracker_imports[import_owner]
}

@(private = "file")
tracker_on_shape_dep :: proc "contextless" (data: rawptr, import_owner: int, shape_hash: u64) {
	c := (^Query_Cache)(data)
	ti := tracker_ensure(c, import_owner)
	if ti == nil {
		return
	}
	ti.shape_inspected = true
	ti.root_shape_hash = shape_hash
}

@(private = "file")
tracker_on_record_field :: proc "contextless" (data: rawptr, import_owner: int, sym: lex_parser.Sym_Id) {
	c := (^Query_Cache)(data)
	ti := tracker_ensure(c, import_owner)
	if ti == nil || ti.whole_accessed {
		return
	}
	cnt := int(ti.field_count)
	for i in 0 ..< cnt {
		if ti.fields[i] == sym {
			return
		}
	}
	if cnt >= TRACKER_FIELDS_PER_IMPORT_LIMIT {
		ti.whole_accessed = true
		return
	}
	ti.fields[cnt] = sym
	ti.field_count = u16(cnt + 1)
}

@(private = "file")
tracker_on_record_whole :: proc "contextless" (data: rawptr, import_owner: int) {
	c := (^Query_Cache)(data)
	ti := tracker_ensure(c, import_owner)
	if ti == nil {
		return
	}
	ti.whole_accessed = true
}

// ---- L2 lookup, validation (with early cutoff), and insertion.

@(private = "file")
l2_hash_of_ref :: proc "contextless" (owner: rawptr, ref: u64) -> u64 {
	c := (^Query_Cache)(owner)
	return hash_table.slice_index_hash_word(&c.l2_index, hash_u64_prefix(c.l2_entries[int(ref)].query_key))
}

@(private = "file")
l2_find_entry :: proc "contextless" (cache: ^Query_Cache, query_key: blake3.Hash) -> (idx: int, found: bool) {
	if cache.l2_entry_count == 0 {
		return -1, false
	}
	h := hash_table.slice_index_hash_word(&cache.l2_index, hash_u64_prefix(query_key))
	probe := hash_table.slice_index_search_begin(&cache.l2_index, h)
	for {
		ref, _, ok := hash_table.slice_index_search_next(&cache.l2_index, &probe)
		if !ok {
			return -1, false
		}
		if int(ref) < cache.l2_entry_count && cache.l2_entries[ref].valid && cache.l2_entries[ref].query_key == query_key {
			return int(ref), true
		}
	}
}

@(private = "file")
dep_path_text :: #force_inline proc "contextless" (cache: ^Query_Cache, dep: L2_Dep) -> string {
	return string(cache.l2_bytes[int(dep.path_off):int(dep.path_off) + int(dep.path_len)])
}

@(private = "file")
field_dep_name :: #force_inline proc "contextless" (cache: ^Query_Cache, fdep: L2_Field_Dep) -> string {
	return string(cache.l2_bytes[int(fdep.name_off):int(fdep.name_off) + int(fdep.name_len)])
}

@(private = "file")
entry_contains_import :: proc "contextless" (cache: ^Query_Cache, entry: ^L2_Entry, by_hash: bool, path: string, target_hash: blake3.Hash) -> bool {
	deps := cache.l2_deps[int(entry.deps_off):int(entry.deps_off) + int(entry.dep_count)]
	for d in deps {
		if d.by_hash != by_hash {
			continue
		}
		if by_hash {
			if d.target_hash == target_hash {
				return true
			}
		} else {
			if dep_path_text(cache, d) == path {
				return true
			}
		}
	}
	return false
}

// Validates all dependencies of `entry`. When a dependency file's content hash
// changed, performs Salsa-style early-cutoff verification against that module's
// accessed field hashes and Record_Shape shape hash.
@(private = "file")
l2_entry_validate :: proc "contextless" (
	cache: ^Query_Cache,
	ws: ^Declaration_Workspace,
	entry: ^L2_Entry,
	config: Declaration_Config,
) -> bool {
	deps := cache.l2_deps[int(entry.deps_off):int(entry.deps_off) + int(entry.dep_count)]
	for &dep in deps {
		src: string
		found: bool
		if dep.by_hash {
			if config.loader.load_hash == nil {
				return false
			}
			src, found = config.loader.load_hash(config.loader.data, dep.target_hash)
		} else {
			if config.loader.load_path == nil {
				return false
			}
			src, found = config.loader.load_path(config.loader.data, dep_path_text(cache, dep))
		}
		if !found {
			return false
		}
		cur_hash := blake3.hash(transmute([]u8)src)
		if cur_hash == dep.file_hash {
			continue
		}
		// File changed: closure exports cannot early-cutoff.
		if dep.has_closure {
			return false
		}
		verify_cfg := config
		verify_cfg.compile_cache = cache
		verify_cfg.trace_log = nil
		vres := declaration_evaluate(ws, src, "", verify_cfg)
		if !vres.ok || vres.traced {
			return false
		}
		if dep.shape_inspected {
			if !is_lazy_record(vres.value.kind) {
				return false
			}
			sid, sok := lazy_record_base_shape(&ws.evaluation, vres.value)
			if !sok || ws.evaluation.shapes[sid].shape_hash != dep.root_shape_hash {
				return false
			}
		}
		if dep.whole_accessed {
			wh, wok, wcl := hash_value_canonical(ws, vres.value)
			if !wok || wcl || wh != dep.whole_hash {
				return false
			}
		} else {
			fdeps := cache.l2_field_deps[int(dep.fields_off):int(dep.fields_off) + int(dep.field_count)]
			for fd in fdeps {
				fname := field_dep_name(cache, fd)
				fval, fok := field_force(&ws.evaluation, vres.value, fname, 0, lex_parser.NO_NODE)
				if !fok {
					return false
				}
				fh, hok, fcl := hash_value_canonical(ws, fval)
				if !hok || fcl || fh != fd.value_hash {
					return false
				}
			}
		}
		// Check AFTER forcing accessed fields so lazy imports inside fields are
		// caught: if the edited module introduced any new import not already
		// tracked by this query entry, invalidate conservatively so it is recorded.
		if ws.evaluation.traced {
			return false
		}
		for i in 0 ..< ws.import_count {
			imp := ws.imports[i]
			if !entry_contains_import(cache, entry, imp.by_hash, imp.path, imp.hash) {
				return false
			}
		}
		// Early cutoff succeeded for this module: advance stored file_hash so
		// subsequent queries hit the O(1) file-hash fast path.
		dep.file_hash = cur_hash
	}
	return true
}

@(private = "file")
l2_alloc_bytes :: proc "contextless" (cache: ^Query_Cache, data: []u8) -> (off: u32, ok: bool) {
	if len(data) > len(cache.l2_bytes) - cache.l2_bytes_used {
		return 0, false
	}
	off = u32(cache.l2_bytes_used)
	copy(cache.l2_bytes[int(off):int(off) + len(data)], data)
	cache.l2_bytes_used += len(data)
	return off, true
}

@(private = "file")
l2_store_entry :: proc "contextless" (
	cache: ^Query_Cache,
	ws: ^Declaration_Workspace,
	query_key: blake3.Hash,
	root_hash: blake3.Hash,
	output_bytes: []u8,
	existing_idx: int,
) -> bool {
	if cache.tracker_overflow || len(output_bytes) > len(cache.l2_bytes) || ws.import_count > len(cache.l2_deps) || len(cache.l2_entries) == 0 {
		return false
	}
	// Estimate space needed; if pools cannot fit, reset L2 cache cleanly.
	need_bytes := len(output_bytes)
	need_fields := 0
	for i in 0 ..< ws.import_count {
		imp := ws.imports[i]
		if !imp.by_hash {
			need_bytes += len(imp.path)
		}
		if i < cache.tracker_count {
			ti := &cache.tracker_imports[i]
			if !ti.whole_accessed {
				for fi in 0 ..< int(ti.field_count) {
					need_bytes += len(lex_parser.sym_text(&ws.evaluation.interner, ti.fields[fi]))
					need_fields += 1
				}
			}
		}
	}
	if need_bytes > len(cache.l2_bytes) || need_fields > len(cache.l2_field_deps) {
		return false
	}
	slot := existing_idx
	need_new_slot := slot < 0
	if (need_new_slot && cache.l2_entry_count >= len(cache.l2_entries)) ||
	   cache.l2_deps_used + ws.import_count > len(cache.l2_deps) ||
	   cache.l2_fields_used + need_fields > len(cache.l2_field_deps) ||
	   cache.l2_bytes_used + need_bytes > len(cache.l2_bytes) {
		l2_clear(cache)
		slot = -1
		need_new_slot = true
	}

	out_off, out_ok := l2_alloc_bytes(cache, output_bytes)
	if !out_ok {
		return false
	}
	deps_off := u32(cache.l2_deps_used)
	for i in 0 ..< ws.import_count {
		imp := ws.imports[i]
		dep := L2_Dep {
			by_hash     = imp.by_hash,
			target_hash = imp.hash,
			file_hash   = blake3.hash(transmute([]u8)imp.source),
		}
		if !imp.by_hash {
			poff, pok := l2_alloc_bytes(cache, transmute([]u8)imp.path)
			if !pok {
				return false
			}
			dep.path_off = poff
			dep.path_len = u32(len(imp.path))
		}
		// Check whether this import's root value is a directly owned Lazy_Record.
		owns_record := false
		if imp.root_value.kind == .Record_Literal {
			ridx := int(imp.root_value.data)
			if ridx >= 0 && ridx < ws.evaluation.record_count && ws.evaluation.records[ridx].flags == u16(i + 1) {
				owns_record = true
			}
		}
		if !owns_record {
			// Non-record import or re-exported record from another module: track whole value.
			dep.whole_accessed = true
			if is_lazy_record(imp.root_value.kind) {
				if sid, sok := lazy_record_base_shape(&ws.evaluation, imp.root_value); sok {
					dep.shape_inspected = true
					dep.root_shape_hash = ws.evaluation.shapes[sid].shape_hash
				}
			}
		} else if i < cache.tracker_count {
			ti := &cache.tracker_imports[i]
			dep.whole_accessed = ti.whole_accessed
			dep.shape_inspected = ti.shape_inspected
			dep.root_shape_hash = ti.root_shape_hash
		}

		if dep.whole_accessed {
			wh, wok, wcl := hash_value_canonical(ws, imp.root_value)
			if wcl || !wok {
				dep.has_closure = true
			} else {
				dep.whole_hash = wh
			}
		} else if i < cache.tracker_count {
			ti := &cache.tracker_imports[i]
			dep.fields_off = u32(cache.l2_fields_used)
			fcount := int(ti.field_count)
			for fi in 0 ..< fcount {
				sym := ti.fields[fi]
				fname := lex_parser.sym_text(&ws.evaluation.interner, sym)
				tref, found := lazy_record_lookup_thunk(&ws.evaluation, imp.root_value, sym)
				if !found {
					dep.has_closure = true
					break
				}
				fval, fok := vm_force_thunk(&ws.evaluation, tref, 0, lex_parser.NO_NODE)
				if !fok {
					dep.has_closure = true
					break
				}
				fh, hok, fcl := hash_value_canonical(ws, fval)
				if fcl || !hok {
					dep.has_closure = true
					break
				}
				noff, nok := l2_alloc_bytes(cache, transmute([]u8)fname)
				if !nok {
					return false
				}
				cache.l2_field_deps[cache.l2_fields_used] = {
					name_off   = noff,
					name_len   = u32(len(fname)),
					value_hash = fh,
				}
				cache.l2_fields_used += 1
				dep.field_count += 1
			}
		}
		cache.l2_deps[cache.l2_deps_used] = dep
		cache.l2_deps_used += 1
	}

	if need_new_slot {
		slot = cache.l2_entry_count
		cache.l2_entries[slot] = {
			query_key  = query_key,
			root_hash  = root_hash,
			output_off = out_off,
			output_len = u32(len(output_bytes)),
			deps_off   = deps_off,
			dep_count  = u32(ws.import_count),
			valid      = true,
		}
		h := hash_table.slice_index_hash_word(&cache.l2_index, hash_u64_prefix(query_key))
		if !hash_table.slice_index_insert(&cache.l2_index, h, u32(slot), cache, l2_hash_of_ref) {
			l2_clear(cache)
			return false
		}
		cache.l2_entry_count += 1
	} else {
		cache.l2_entries[slot] = {
			query_key  = query_key,
			root_hash  = root_hash,
			output_off = out_off,
			output_len = u32(len(output_bytes)),
			deps_off   = deps_off,
			dep_count  = u32(ws.import_count),
			valid      = true,
		}
	}
	return true
}

// query_cache_evaluate_to_buffer evaluates `source` (and optional `field_path`)
// through the caller-owned L1/L2 incremental Query_Cache, writing the exact
// canonical `declaration_eval` output buffer into `output`.
//
// Produces byte-identical results to `declaration_evaluate_to_buffer`, while
// skipping unchanged subtrees (and triggering early cutoff when an edited
// module's accessed field values and shape hash stay identical).
query_cache_evaluate_to_buffer :: proc "contextless" (
	cache: ^Query_Cache,
	ws: ^Declaration_Workspace,
	source: string,
	field_path: string,
	config: Declaration_Config,
	output: []u8,
) -> (written: int, ok: bool) {
	if cache == nil {
		return declaration_evaluate_to_buffer(ws, source, field_path, config, output)
	}
	query_key := compute_query_key(field_path, config)
	root_hash := blake3.hash(transmute([]u8)source)

	existing_idx, found := l2_find_entry(cache, query_key)
	if found {
		entry := &cache.l2_entries[existing_idx]
		if entry.root_hash == root_hash && l2_entry_validate(cache, ws, entry, config) {
			n := int(entry.output_len)
			if n > len(output) {
				return 0, false
			}
			copy(output[:n], cache.l2_bytes[int(entry.output_off):int(entry.output_off) + n])
			if config.profile != nil {
				config.profile.cache_l2_hits += 1
			}
			return n, true
		}
	}

	if config.profile != nil {
		config.profile.cache_l2_misses += 1
	}

	// Reset tracker and attach hooks for this miss evaluation.
	cache.tracker_count = 0
	cache.tracker_overflow = false
	ws.dep_data = cache
	ws.on_shape_dep = tracker_on_shape_dep
	ws.on_record_field = tracker_on_record_field
	ws.on_record_whole = tracker_on_record_whole

	run_cfg := config
	run_cfg.compile_cache = cache
	res := declaration_evaluate(ws, source, field_path, run_cfg)
	if !res.ok {
		ws.dep_data = nil
		ws.on_shape_dep = nil
		ws.on_record_field = nil
		ws.on_record_whole = nil
		return declaration_eval.output_write_refusal(output, res.failure_kind, res.steps_taken, res.line, res.column, res.detail)
	}
	writer := declaration_eval.output_writer_start(output, {
		status       = .Ok,
		failure_kind = .None,
		steps_taken  = ws.evaluation.steps,
	})
	ser_err := serialize_value_into(ws, &writer, res.value, 0)
	// Detach hooks right after serialization (before hashing deps).
	ws.dep_data = nil
	ws.on_shape_dep = nil
	ws.on_record_field = nil
	ws.on_record_whole = nil
	ws.evaluation.dep_data = nil
	ws.evaluation.on_shape_dep = nil
	ws.evaluation.on_record_field = nil
	ws.evaluation.on_record_whole = nil

	if ser_err != .None {
		if ws.host_failure_kind != .None || refused(&ws.evaluation) {
			err_res := decl_result_from_refusal(ws)
			return declaration_eval.output_write_refusal(output, err_res.failure_kind, err_res.steps_taken, err_res.line, err_res.column, err_res.detail)
		}
		return declaration_eval.output_write_refusal(output, ser_err, ws.evaluation.steps, 0, 0, "")
	}
	if writer.overflow {
		return 0, false
	}
	_ = declaration_eval.output_writer_start(output[:declaration_eval.OUTPUT_HEADER_BYTES], {
		status       = .Ok,
		failure_kind = .None,
		steps_taken  = ws.evaluation.steps,
	})

	// Opt out of L2 caching when `trace(...)` ran so diagnostics always fire.
	if !res.traced {
		// Re-lookup existing_idx in case anything changed (safety).
		slot_idx := existing_idx
		if slot_idx >= cache.l2_entry_count || (slot_idx >= 0 && cache.l2_entries[slot_idx].query_key != query_key) {
			slot_idx = -1
		}
		l2_store_entry(cache, ws, query_key, root_hash, output[:writer.written], slot_idx)
	}
	return writer.written, true
}
