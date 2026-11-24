// The retention of the private store of the recipes service
// (src/md/features/recipes.md, "The retention and garbage collection of the store"). The content-addressed
// objects kept by builds, cache fetches, and puts are named by their exact
// 64 lowercase hexadecimal BLAKE3 hash; one pass removes each of them that
// nothing names: no realisation of the store, no recipe of the store or of
// the registry, and no put of this run of the service. A pass that cannot read
// all that it must, or whose marks pass their bound, removes nothing.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/byte_order"
import gb "modus:contract/guest_builder"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// Plan value: default output block limit for a builder whose recipe sets
// output_block_limit = 0 (16 384 blocks of 4 KiB = 64 MiB, matching
// OUTPUT_BYTES_MOST).
DEFAULT_BUILDER_OUTPUT_BLOCK_LIMIT :: u64(16_384)

// Plan value: minimum blocks kept in reserve for the parent recipes store when
// computing a builder's output share limit (metadata, freeze_tree, realisations)
// when the store limit exceeds 2 * BUILDER_STORE_RESERVE_MIN_BLOCKS.
BUILDER_STORE_RESERVE_MIN_BLOCKS :: u64(16)

// Plan value: fraction (1/8) of the parent store kept as headroom below its
// limit so a builder never drives the parent store into version thinning.
BUILDER_STORE_RESERVE_DIVISOR :: u64(8)

// builder_output_block_limit computes the block cap for a builder's writable
// "out" share from the recipe's requested output_block_limit and recipes's
// store usage and limit. Returns 0 when no headroom remains.
builder_output_block_limit :: proc "contextless" (recipe_block_limit: u64, store_limit: u64, store_used: u64) -> u64 {
	if store_limit == 0 || store_used >= store_limit {
		return 0
	}
	headroom := store_limit - store_used
	reserve: u64 = 0
	if store_limit > 2 * BUILDER_STORE_RESERVE_MIN_BLOCKS {
		reserve = max(store_limit / BUILDER_STORE_RESERVE_DIVISOR, BUILDER_STORE_RESERVE_MIN_BLOCKS)
	}
	if headroom <= reserve {
		return 0
	}
	available := headroom - reserve
	desired := recipe_block_limit > 0 ? recipe_block_limit : DEFAULT_BUILDER_OUTPUT_BLOCK_LIMIT
	return min(desired, available)
}

// The hashes that one pass can mark: the objects that the realisations and
// the recipes of the store name, to the leaves of their trees.
RETENTION_MARKS_MOST :: 16384
// The depth of the trees that a pass walks. A deeper tree ends the pass
// with nothing removed.
RETENTION_DEPTH_MOST :: 16
// The names of one page of a list of the store.
RETENTION_PAGE_NAMES :: 64

// The bytes of a hash that a name of the store holds: all 32 bytes (64
// lowercase hexadecimal digits), matching storage.freeze_tree and
// plans_recipes.blob_object_name.
RETENTION_NAME_HASH_BYTES :: blake3.HASH_SIZE

// Why a pass removed nothing.
Retention_Refusal :: enum u8 {
	None         = 0,
	Marks_Full   = 1, // More objects are named than the marks hold.
	Too_Deep     = 2, // A tree is deeper than RETENTION_DEPTH_MOST.
	Store_Failed = 3, // A list or a read of the store failed.
}

// The memory of one pass, kept by the caller: the marks, a page of names,
// and the bytes of one object.
Retention_Workspace :: struct {
	marks:      [RETENTION_MARKS_MOST]Retention_Mark, // Open addressing; a zero key: free.
	mark_count: int,
	rows:       [RETENTION_PAGE_NAMES]pr.Private_Store_Entry,
	name_bytes: [RETENTION_PAGE_NAMES * tree_hash.ENTRY_NAME_CAPACITY]u8,
	after:      [tree_hash.ENTRY_NAME_CAPACITY]u8, // The last name of the page before.
	object:     [max(pr.REALISATION_OBJECT_HEAD_SIZE, pr.MAX_RECIPE_OBJECT_BYTES)]u8,
	nodes:      [RETENTION_DEPTH_MOST][tree_hash.MAX_ENCODED_TREE_BYTES]u8,
	recipe:     pr.Recipe_Spec,
}

// One marked object: the bytes of its hash, and whether the pass walked it
// as a tree. Marked and walked are apart: an object that a put marked
// first is still walked when a recipe names it as a tree, so the children
// of a tree are kept whatever named it first.
Retention_Mark :: struct {
	key:    [RETENTION_NAME_HASH_BYTES]u8,
	walked: bool,
}

// What a namer says of the kind of an object: a put names an object of any
// kind, which the pass reads to know if it is a tree.
Retention_Kind :: enum u8 {
	Blob    = 0,
	Tree    = 1,
	Unknown = 2,
}

// What one pass did.
Retention_Result :: struct {
	refusal: Retention_Refusal,
	marked:  int,
	kept:    int, // The content-addressed objects that something names.
	removed: int,
}

@(private = "file")
retention_key :: proc "contextless" (hash: blake3.Hash) -> (key: [RETENTION_NAME_HASH_BYTES]u8) {
	hash := hash
	copy(key[:], hash[:RETENTION_NAME_HASH_BYTES])
	return key
}

// retention_start gives the first place of a key in the marks.
@(private = "file")
retention_start :: proc "contextless" (key: [RETENTION_NAME_HASH_BYTES]u8) -> int {
	return int(u32(key[0]) | u32(key[1]) << 8 | u32(key[2]) << 16 | u32(key[3]) << 24) % RETENTION_MARKS_MOST
}

// retention_mark adds a hash and gives its place. A zero key is never
// marked: a zero hash names nothing.
@(private = "file")
retention_mark :: proc "contextless" (workspace: ^Retention_Workspace, key: [RETENTION_NAME_HASH_BYTES]u8) -> (mark: ^Retention_Mark, refusal: Retention_Refusal) {
	zero: [RETENTION_NAME_HASH_BYTES]u8
	if key == zero {
		return nil, .None
	}
	start := retention_start(key)
	for step in 0 ..< RETENTION_MARKS_MOST {
		place := &workspace.marks[(start + step) % RETENTION_MARKS_MOST]
		if place.key == key {
			return place, .None
		}
		if place.key == zero {
			// One place stays free, so a search for an absent key ends.
			if workspace.mark_count >= RETENTION_MARKS_MOST - 1 {
				return nil, .Marks_Full
			}
			place.key = key
			workspace.mark_count += 1
			return place, .None
		}
	}
	return nil, .Marks_Full
}

@(private = "file")
retention_marked :: proc "contextless" (workspace: ^Retention_Workspace, key: [RETENTION_NAME_HASH_BYTES]u8) -> bool {
	zero: [RETENTION_NAME_HASH_BYTES]u8
	start := retention_start(key)
	for step in 0 ..< RETENTION_MARKS_MOST {
		place := &workspace.marks[(start + step) % RETENTION_MARKS_MOST]
		if place.key == key {
			return true
		}
		if place.key == zero {
			return false
		}
	}
	return false
}

// retention_mark_object marks an object and, for a tree, each object under
// it that the store holds. A tree that the store lacks names nothing more:
// the store has nothing under it to keep.
@(private = "file")
retention_mark_object :: proc "contextless" (workspace: ^Retention_Workspace, port: ^pr.Private_Store_Port, kind: Retention_Kind, hash: blake3.Hash, depth: int) -> Retention_Refusal {
	mark, refusal := retention_mark(workspace, retention_key(hash))
	if refusal != .None || mark == nil || mark.walked || kind == .Blob {
		return refusal
	}
	if depth >= RETENTION_DEPTH_MOST {
		return .Too_Deep
	}
	name := pr.blob_object_name(hash)
	bytes, status := pr.private_store_read(port, pr.private_object_name_text(&name), workspace.nodes[depth][:])
	switch status {
	case .Ok:
	case .Absent:
		return .None
	case .Too_Large:
		// An object larger than a node of a tree is a blob: a put of it
		// names nothing more. A namer that says Tree names a damaged one.
		return kind == .Unknown ? .None : .Store_Failed
	case .Failed:
		return .Store_Failed
	}
	if kind == .Unknown {
		if _, tree_refusal := tree_hash.tree_validate(bytes); tree_refusal != .None {
			return .None
		}
	}
	mark.walked = true
	return retention_mark_tree(workspace, port, bytes, depth)
}

// retention_page_after keeps the last name of a page, from which the next
// page starts: the names of the page go when the next page is read.
@(private = "file")
retention_page_after :: proc "contextless" (workspace: ^Retention_Workspace, page: []pr.Private_Store_Entry) -> (after_length: int, status: pr.Private_Store_Status) {
	last := page[len(page) - 1]
	if last.name_count > len(workspace.after) {
		return 0, .Failed
	}
	return copy(workspace.after[:], workspace.name_bytes[last.name_offset:][:last.name_count]), .Ok
}

@(private = "file")
retention_mark_tree :: proc "contextless" (workspace: ^Retention_Workspace, port: ^pr.Private_Store_Port, tree_bytes: []u8, depth: int) -> Retention_Refusal {
	count, tree_refusal := tree_hash.tree_validate(tree_bytes)
	if tree_refusal != .None {
		return .None // Not a tree: it names nothing.
	}
	for index in 0 ..< count {
		entry, ok := tree_hash.tree_entry_at(tree_bytes, index)
		if !ok {
			return .None
		}
		kind := Retention_Kind.Blob
		switch entry.kind {
		case .Object:
			kind = .Blob
		case .Tree, .Part: // A part is a node of a tree: it and its entries are kept.
			kind = .Tree
		}
		if refusal := retention_mark_object(workspace, port, kind, entry.hash, depth + 1); refusal != .None {
			return refusal
		}
	}
	return .None
}

// retention_mark_recipe marks what a recipe names: its inputs, and for a
// recipe of the guest builder the kernel and the initial archive of its
// spec.
@(private = "file")
retention_mark_recipe :: proc "contextless" (workspace: ^Retention_Workspace, port: ^pr.Private_Store_Port, spec: ^pr.Recipe_Spec) -> Retention_Refusal {
	for index in 0 ..< min(spec.input_count, pr.MAX_RECIPE_INPUTS) {
		input := &spec.inputs[index]
		kind: Retention_Kind = input.kind == .Tree ? .Tree : .Blob
		if refusal := retention_mark_object(workspace, port, kind, input.hash, 0); refusal != .None {
			return refusal
		}
	}
	if spec.builder_hash == pr.guest_builder_hash() {
		guest, guest_refusal := gb.decode_build_spec(spec.arguments[:min(spec.arguments_length, pr.MAX_RECIPE_ARG_BYTES)])
		if guest_refusal == .None {
			for hash in ([2]blake3.Hash{guest.kernel_hash, guest.initial_archive_hash}) {
				if _, refusal := retention_mark(workspace, retention_key(hash)); refusal != .None {
					return refusal
				}
			}
		}
	}
	return .None
}

// retention_name_key gives the full 32-byte hash that a 64-hex content-addressed
// object name holds. Prefixed entries (realisation_*, recipe_*) and temporary
// directories (build) do not match.
@(private = "file")
retention_name_key :: proc "contextless" (text: string) -> (key: [RETENTION_NAME_HASH_BYTES]u8, ok: bool) {
	hash, parsed := pr.hash_of_blob_object_name(text)
	if !parsed {
		return {}, false
	}
	return hash, true
}

// retention_collect runs one pass over the private store of state: it
// marks what each realisation object and each recipe object of the store,
// each recipe of registry, the active build (state.building), each hash of
// extra (recent puts), each explicit pin in pins, and each queued/running
// build of queue names, then removes each content-addressed object that is
// not marked. Any failure or bound overflow removes nothing.
retention_collect :: proc "contextless" (state: ^Recipes_State, registry: ^Recipe_Registry, extra: []blake3.Hash, workspace: ^Retention_Workspace, queue: ^Guest_Queue = nil, pins: []blake3.Hash = nil) -> (result: Retention_Result) {
	workspace.marks = {}
	workspace.mark_count = 0
	port := &state.store
	// An active build on state protects its inputs and guest images.
	if state.building != nil {
		if refusal := retention_mark_recipe(workspace, port, state.building); refusal != .None {
			result.refusal = refusal
			return result
		}
	}
	// Each build of the queue names its inputs, its kernel and its archive:
	// a build that waits must find them when it runs. A build of the ring
	// holds its spec; another build names a recipe of the registry.
	if queue != nil {
		for &job in queue.jobs {
			spec: ^pr.Recipe_Spec
			switch job.state {
			case .Free:
			case .Waiting, .Running:
				spec = job.from_ring ? &job.spec : (registry != nil ? registered_recipe(registry, job.recipe_hash) : nil)
			}
			if spec != nil {
				if refusal := retention_mark_recipe(workspace, port, spec); refusal != .None {
					result.refusal = refusal
					return result
				}
			}
		}
	}
	// Explicit pins (e.g. active outputs or principal-pinned roots) keep their
	// object and recursive tree closure alive.
	for hash in pins {
		if refusal := retention_mark_object(workspace, port, .Unknown, hash, 0); refusal != .None {
			result.refusal = refusal
			return result
		}
	}
	// A put names an object of any kind: a tree is walked, so its children
	// stay while the put stays.
	for hash in extra {
		if refusal := retention_mark_object(workspace, port, .Unknown, hash, 0); refusal != .None {
			result.refusal = refusal
			return result
		}
	}
	if registry != nil {
		for &item in registry.recipes {
			if item.active {
				if refusal := retention_mark_recipe(workspace, port, &item.spec); refusal != .None {
					result.refusal = refusal
					return result
				}
			}
		}
	}
	// The realisations and the recipes of the store.
	after_length := 0
	for {
		page, status := pr.private_store_list(port, string(workspace.after[:after_length]), workspace.rows[:], workspace.name_bytes[:])
		if status != .Ok {
			result.refusal = .Store_Failed
			return result
		}
		if len(page) == 0 {
			break
		}
		if after_length, status = retention_page_after(workspace, page); status != .Ok {
			result.refusal = .Store_Failed
			return result
		}
		for row in page {
			text := string(workspace.name_bytes[row.name_offset:][:row.name_count])
			is_realisation := len(text) > 12 && text[:12] == "realisation_"
			is_recipe := len(text) > 7 && text[:7] == "recipe_"
			if !is_realisation && !is_recipe {
				continue
			}
			bytes, read_status := pr.private_store_read(port, text, workspace.object[:])
			if read_status != .Ok {
				result.refusal = .Store_Failed
				return result
			}
			if is_recipe {
				if _, decode_refusal := pr.recipe_object_decode(bytes, &workspace.recipe); decode_refusal == .None {
					if refusal := retention_mark_recipe(workspace, port, &workspace.recipe); refusal != .None {
						result.refusal = refusal
						return result
					}
				}
				continue
			}
			// A realisation names its output object under its exact 64-hex hash.
			// hash, and its output tree names the rest. A damaged realisation
			// names nothing: no build takes it.
			if len(bytes) < pr.REALISATION_OBJECT_HEAD_SIZE {
				continue
			}
			recipe_hash: blake3.Hash
			copy(recipe_hash[:], bytes[8:][:blake3.HASH_SIZE])
			kind, kind_ok := object_cache.cache_object_kind_of_word(byte_order.read_u64_little_endian(bytes, 8 + 2 * blake3.HASH_SIZE))
			if !kind_ok {
				continue
			}
			record, _, _, decode_refusal := pr.decode_realisation_object(bytes, recipe_hash, kind)
			if decode_refusal != .None {
				continue
			}
			output_kind: Retention_Kind = kind == .Tree ? .Tree : .Blob
			if refusal := retention_mark_object(workspace, port, output_kind, record.output_hash, 0); refusal != .None {
				result.refusal = refusal
				return result
			}
		}
	}
	result.marked = workspace.mark_count

	// The sweep: each content-addressed object that nothing names. The removes change
	// no name before the last one read, so the next page starts after it.
	after_length = 0
	for {
		page, status := pr.private_store_list(port, string(workspace.after[:after_length]), workspace.rows[:], workspace.name_bytes[:])
		if status != .Ok {
			result.refusal = .Store_Failed
			return result
		}
		if len(page) == 0 {
			break
		}
		if after_length, status = retention_page_after(workspace, page); status != .Ok {
			result.refusal = .Store_Failed
			return result
		}
		for row in page {
			text := string(workspace.name_bytes[row.name_offset:][:row.name_count])
			key, is_blob := retention_name_key(text)
			if !is_blob {
				continue
			}
			if retention_marked(workspace, key) {
				result.kept += 1
				continue
			}
			if pr.private_store_remove(port, text) == .Ok {
				result.removed += 1
			}
		}
	}
	return result
}
