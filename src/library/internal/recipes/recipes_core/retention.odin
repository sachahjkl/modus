// The retention of the private store of the recipes service
// (src/md/features/recipes.md, "The retention of the store"). The objects
// that a guest build keeps and that put keeps are named blob_<hash>; one
// pass removes each of them that nothing names: no realisation of the
// store, no recipe of the store or of the registry, and no put of this run
// of the service. A pass that cannot read all that it must, or whose marks
// pass their bound, removes nothing.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/byte_order"
import gb "modus:contract/guest_builder"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// The hashes that one pass can mark: the objects that the realisations and
// the recipes of the store name, to the leaves of their trees.
RETENTION_MARKS_MOST :: 16384
// The depth of the trees that a pass walks. A deeper tree ends the pass
// with nothing removed.
RETENTION_DEPTH_MOST :: 16
// The names of one page of a list of the store.
RETENTION_PAGE_NAMES :: 64

// The bytes of a hash that a name of the store holds (its first 52
// hexadecimal digits): two objects whose hashes share them share a name.
RETENTION_NAME_HASH_BYTES :: pr.REALISATION_NAME_HASH_DIGITS / 2

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
	marks:      [RETENTION_MARKS_MOST][RETENTION_NAME_HASH_BYTES]u8, // Open addressing; all zero: free.
	mark_count: int,
	names:      [RETENTION_PAGE_NAMES]pr.Private_Object_Name,
	object:     [pr.REALISATION_OBJECT_HEAD_SIZE + MAX_OBJECT_BYTES]u8,
	nodes:      [RETENTION_DEPTH_MOST][tree_hash.MAX_ENCODED_TREE_BYTES]u8,
	recipe:     pr.Recipe_Spec,
}

// What one pass did.
Retention_Result :: struct {
	refusal: Retention_Refusal,
	marked:  int,
	kept:    int, // The objects blob_ that something names.
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

// retention_mark adds a hash: fresh is false when it was marked already.
// A zero key is never marked: a zero hash names nothing.
@(private = "file")
retention_mark :: proc "contextless" (workspace: ^Retention_Workspace, key: [RETENTION_NAME_HASH_BYTES]u8) -> (fresh: bool, refusal: Retention_Refusal) {
	zero: [RETENTION_NAME_HASH_BYTES]u8
	if key == zero {
		return false, .None
	}
	start := retention_start(key)
	for step in 0 ..< RETENTION_MARKS_MOST {
		place := (start + step) % RETENTION_MARKS_MOST
		if workspace.marks[place] == key {
			return false, .None
		}
		if workspace.marks[place] == zero {
			// One place stays free, so a search for an absent key ends.
			if workspace.mark_count >= RETENTION_MARKS_MOST - 1 {
				return false, .Marks_Full
			}
			workspace.marks[place] = key
			workspace.mark_count += 1
			return true, .None
		}
	}
	return false, .Marks_Full
}

@(private = "file")
retention_marked :: proc "contextless" (workspace: ^Retention_Workspace, key: [RETENTION_NAME_HASH_BYTES]u8) -> bool {
	zero: [RETENTION_NAME_HASH_BYTES]u8
	start := retention_start(key)
	for step in 0 ..< RETENTION_MARKS_MOST {
		place := (start + step) % RETENTION_MARKS_MOST
		if workspace.marks[place] == key {
			return true
		}
		if workspace.marks[place] == zero {
			return false
		}
	}
	return false
}

// retention_mark_object marks an object and, for a tree, each object under
// it that the store holds. A tree that the store lacks names nothing more:
// the store has nothing under it to keep.
@(private = "file")
retention_mark_object :: proc "contextless" (workspace: ^Retention_Workspace, port: ^pr.Private_Store_Port, kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, depth: int) -> Retention_Refusal {
	fresh, refusal := retention_mark(workspace, retention_key(hash))
	if refusal != .None || !fresh || kind != .Tree {
		return refusal
	}
	if depth >= RETENTION_DEPTH_MOST {
		return .Too_Deep
	}
	name := pr.blob_object_name(hash)
	bytes, status := pr.private_store_read_large(port, pr.private_object_name_text(&name), workspace.nodes[depth][:])
	switch status {
	case .Ok:
	case .Absent:
		return .None
	case .Too_Large, .Failed:
		return .Store_Failed
	}
	return retention_mark_tree(workspace, port, bytes, depth)
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
		kind := object_cache.Cache_Object_Kind.Blob
		switch entry.kind {
		case .Object:
			kind = .Blob
		case .Tree:
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
		if refusal := retention_mark_object(workspace, port, input.kind, input.hash, 0); refusal != .None {
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

// retention_name_key gives the hash bytes that a name blob_<digits> holds.
@(private = "file")
retention_name_key :: proc "contextless" (text: string) -> (key: [RETENTION_NAME_HASH_BYTES]u8, ok: bool) {
	PREFIX :: "blob_"
	if len(text) != len(PREFIX) + 2 * RETENTION_NAME_HASH_BYTES || text[:len(PREFIX)] != PREFIX {
		return {}, false
	}
	digit :: proc "contextless" (value: u8) -> (number: u8, ok: bool) {
		switch value {
		case '0' ..= '9':
			return value - '0', true
		case 'a' ..= 'f':
			return value - 'a' + 10, true
		}
		return 0, false
	}
	for index in 0 ..< RETENTION_NAME_HASH_BYTES {
		high := digit(text[len(PREFIX) + 2 * index]) or_return
		low := digit(text[len(PREFIX) + 2 * index + 1]) or_return
		key[index] = high << 4 | low
	}
	return key, true
}

// retention_collect runs one pass over the private store of state: it
// marks what each realisation object and each recipe object of the store,
// each recipe of registry and each hash of extra names, then removes each
// object blob_ that is not marked. extra holds the objects that put kept
// in this run of the service, which a recipe may name later.
retention_collect :: proc "contextless" (state: ^Recipes_State, registry: ^Recipe_Registry, extra: []blake3.Hash, workspace: ^Retention_Workspace) -> (result: Retention_Result) {
	workspace.marks = {}
	workspace.mark_count = 0
	port := &state.store
	for hash in extra {
		if _, refusal := retention_mark(workspace, retention_key(hash)); refusal != .None {
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
	after: pr.Private_Object_Name
	for {
		page, status := pr.private_store_list(port, pr.private_object_name_text(&after), workspace.names[:])
		if status != .Ok {
			result.refusal = .Store_Failed
			return result
		}
		if len(page) == 0 {
			break
		}
		after = page[len(page) - 1]
		for &name in page {
			text := pr.private_object_name_text(&name)
			is_realisation := len(text) > 12 && text[:12] == "realisation_"
			is_recipe := len(text) > 7 && text[:7] == "recipe_"
			if !is_realisation && !is_recipe {
				continue
			}
			bytes, read_status := pr.private_store_read_large(port, text, workspace.object[:])
			if read_status != .Ok {
				result.refusal = .Store_Failed
				return result
			}
			if is_recipe {
				if pr.decode_recipe_object(bytes, &workspace.recipe) == .None {
					if refusal := retention_mark_recipe(workspace, port, &workspace.recipe); refusal != .None {
						result.refusal = refusal
						return result
					}
				}
				continue
			}
			// A realisation names its output, and its output tree names the
			// rest. A damaged realisation names nothing: no build takes it.
			if len(bytes) < pr.REALISATION_OBJECT_HEAD_SIZE {
				continue
			}
			recipe_hash: blake3.Hash
			copy(recipe_hash[:], bytes[8:][:blake3.HASH_SIZE])
			kind, kind_ok := object_cache.cache_object_kind_of_word(byte_order.read_u64_little_endian(bytes, 8 + 2 * blake3.HASH_SIZE))
			if !kind_ok {
				continue
			}
			record, _, payload, decode_refusal := pr.decode_realisation_object(bytes, recipe_hash, kind)
			if decode_refusal != .None {
				continue
			}
			if _, refusal := retention_mark(workspace, retention_key(record.output_hash)); refusal != .None {
				result.refusal = refusal
				return result
			}
			if kind == .Tree {
				if refusal := retention_mark_tree(workspace, port, payload, 0); refusal != .None {
					result.refusal = refusal
					return result
				}
			}
		}
	}
	result.marked = workspace.mark_count

	// The sweep: each object blob_ that nothing names. The removes change
	// no name before the last one read, so the next page starts after it.
	after = {}
	for {
		page, status := pr.private_store_list(port, pr.private_object_name_text(&after), workspace.names[:])
		if status != .Ok {
			result.refusal = .Store_Failed
			return result
		}
		if len(page) == 0 {
			break
		}
		after = page[len(page) - 1]
		for &name in page {
			text := pr.private_object_name_text(&name)
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
