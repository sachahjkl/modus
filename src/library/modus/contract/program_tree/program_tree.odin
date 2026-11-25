// Canonical MODTREE2 program tree contract
// (src/md/features/program_trees.md).
//
// A program with helper modules or read-only static assets is a plain MODTREE2
// tree (modus:contract/tree_hash) with a closed top-level schema:
//   - "module"  (required, Object, non-zero BLAKE3 hash): entry module binary.
//   - "modules" (optional, Tree,   non-zero tree hash):   helper modules.
//   - "assets"  (optional, Tree,   non-zero tree hash):   read-only asset tree.
//
// This contract package imports no support or host package and allocates no
// memory.
package program_tree

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/tree_hash"

// Canonical top-level entry names of a MODTREE2 program tree.
ENTRY_MODULE_NAME :: "module"
MODULES_SUBTREE_NAME :: "modules"
ASSETS_SUBTREE_NAME :: "assets"

// Format/contract bound: matches builder and storage maximum nested tree depth.
ASSET_PATH_MAX_DEPTH :: 32

// Format/contract bound: bounded relative UTF-8 asset path across nested
// MODTREE2 subtrees.
ASSET_PATH_MAX_BYTES :: 1024

// Closed set of refusals returned by program tree validation and lookup.
Program_Tree_Refusal :: enum u8 {
	None                  = 0,
	Malformed_Tree        = 1,
	Missing_Entry_Module  = 2,
	Invalid_Entry_Module  = 3,
	Invalid_Modules_Entry = 4,
	Invalid_Assets_Entry  = 5,
	Unexpected_Entry      = 6,
	Invalid_Helper_Name   = 7,
	Invalid_Asset_Path    = 8,
	Subtree_Read_Failed   = 9,
	Not_Found             = 10,
}

// Validated top-level summary of a MODTREE2 program tree.
Program_Tree_Summary :: struct {
	entry_module_hash: blake3.Hash,
	modules_tree_hash: blake3.Hash,
	assets_tree_hash:  blake3.Hash,
	has_modules:       bool,
	has_assets:        bool,
}

// Callback used by program_tree_lookup_asset to fetch intermediate MODTREE2
// subtrees by hash into caller-owned scratch memory. The contract recomputes
// tree_hash.tree_hash on every returned slice before descending.
Subtree_Read_Proc :: #type proc "contextless" (
	tree_digest: blake3.Hash,
	scratch: []u8,
	user_data: rawptr,
) -> (encoded_tree: []u8, ok: bool)

// program_tree_refusal_of_word is the single border converting a raw transport
// word into a Program_Tree_Refusal member. Unknown values are refused.
program_tree_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Program_Tree_Refusal, ok: bool) {
	return enum_word.member_of_word(Program_Tree_Refusal, word)
}

@(private = "file")
hash_is_zero :: proc "contextless" (hash: blake3.Hash) -> bool {
	accumulated: u8 = 0
	for value in hash {
		accumulated |= value
	}
	return accumulated == 0
}

// program_tree_validate checks that encoded_tree is a valid non-part MODTREE2
// root conforming to the closed program tree schema ("module" Object required;
// optional "modules" Tree and "assets" Tree; no other top-level entries; no
// zero hashes). On any refusal, summary is zero.
program_tree_validate :: proc "contextless" (encoded_tree: []u8) -> (summary: Program_Tree_Summary, refusal: Program_Tree_Refusal) {
	count, tree_ref := tree_hash.tree_validate(encoded_tree)
	if tree_ref != .None || tree_hash.tree_holds_parts(encoded_tree) {
		return {}, .Malformed_Tree
	}

	has_entry := false
	offset := tree_hash.HEADER_SIZE
	for _ in 0 ..< count {
		entry, next_offset, ok := tree_hash.tree_entry_next(encoded_tree, offset)
		if !ok {
			return {}, .Malformed_Tree
		}
		offset = next_offset
		name := tree_hash.tree_entry_name(&entry)
		switch name {
		case ENTRY_MODULE_NAME:
			if entry.kind != .Object || hash_is_zero(entry.hash) {
				return {}, .Invalid_Entry_Module
			}
			has_entry = true
			summary.entry_module_hash = entry.hash
		case MODULES_SUBTREE_NAME:
			if entry.kind != .Tree || hash_is_zero(entry.hash) {
				return {}, .Invalid_Modules_Entry
			}
			summary.has_modules = true
			summary.modules_tree_hash = entry.hash
		case ASSETS_SUBTREE_NAME:
			if entry.kind != .Tree || hash_is_zero(entry.hash) {
				return {}, .Invalid_Assets_Entry
			}
			summary.has_assets = true
			summary.assets_tree_hash = entry.hash
		case:
			return {}, .Unexpected_Entry
		}
	}

	if !has_entry {
		return {}, .Missing_Entry_Module
	}
	return summary, .None
}

// program_tree_lookup_helper looks up a helper module by name inside a
// canonical MODTREE2 "modules" subtree. Returns found = false when the tree is
// malformed or holds parts, when name is invalid or absent, or when the entry
// is not an Object with a non-zero hash.
program_tree_lookup_helper :: proc "contextless" (
	encoded_modules_tree: []u8,
	name: string,
) -> (hash: blake3.Hash, found: bool) {
	if _, tree_ref := tree_hash.tree_validate(encoded_modules_tree); tree_ref != .None || tree_hash.tree_holds_parts(encoded_modules_tree) {
		return {}, false
	}
	entry, ok, lookup_ref := tree_hash.tree_lookup(encoded_modules_tree, name)
	if lookup_ref != .None || !ok || entry.kind != .Object || hash_is_zero(entry.hash) {
		return {}, false
	}
	return entry.hash, true
}

// program_tree_lookup_asset resolves a relative '/'-separated path inside a
// canonical MODTREE2 "assets" subtree. Validates every segment with
// tree_hash.tree_name_validate, enforces ASSET_PATH_MAX_BYTES and
// ASSET_PATH_MAX_DEPTH, and verifies the MODTREE2 tree_hash of every
// intermediate subtree returned by read_subtree before descending.
program_tree_lookup_asset :: proc "contextless" (
	encoded_assets_tree: []u8,
	path: string,
	read_subtree: Subtree_Read_Proc,
	scratch: []u8,
	user_data: rawptr = nil,
) -> (hash: blake3.Hash, kind: tree_hash.Tree_Entry_Kind, refusal: Program_Tree_Refusal) {
	if _, tree_ref := tree_hash.tree_validate(encoded_assets_tree); tree_ref != .None || tree_hash.tree_holds_parts(encoded_assets_tree) {
		return {}, {}, .Malformed_Tree
	}
	if len(path) == 0 || len(path) > ASSET_PATH_MAX_BYTES {
		return {}, {}, .Invalid_Asset_Path
	}
	path_bytes := transmute([]u8)path
	if path_bytes[0] == '/' || path_bytes[len(path_bytes) - 1] == '/' {
		return {}, {}, .Invalid_Asset_Path
	}

	// Pass 1: validate every segment and enforce depth bound before invoking any callback.
	depth := 0
	seg_start := 0
	for index := 0; index <= len(path_bytes); index += 1 {
		if index == len(path_bytes) || path_bytes[index] == '/' {
			segment := path_bytes[seg_start:index]
			if len(segment) == 0 || tree_hash.tree_name_validate(segment) != .None {
				return {}, {}, .Invalid_Asset_Path
			}
			depth += 1
			if depth > ASSET_PATH_MAX_DEPTH {
				return {}, {}, .Invalid_Asset_Path
			}
			seg_start = index + 1
		}
	}

	// Pass 2: walk from encoded_assets_tree segment by segment, re-hashing each subtree.
	current := encoded_assets_tree
	seg_start = 0
	for index := 0; index <= len(path_bytes); index += 1 {
		if index != len(path_bytes) && path_bytes[index] != '/' {
			continue
		}
		segment := string(path_bytes[seg_start:index])
		is_last := index == len(path_bytes)
		seg_start = index + 1

		entry, found, lookup_ref := tree_hash.tree_lookup(current, segment)
		if lookup_ref != .None {
			return {}, {}, .Malformed_Tree
		}
		if !found {
			return {}, {}, .Not_Found
		}
		if hash_is_zero(entry.hash) {
			return {}, {}, .Malformed_Tree
		}
		if is_last {
			switch entry.kind {
			case .Object, .Tree:
				return entry.hash, entry.kind, .None
			case .Part:
				return {}, {}, .Malformed_Tree
			}
			return {}, {}, .Malformed_Tree
		}

		// Intermediate segment must name a Tree subtree whose bytes hash back to entry.hash.
		switch entry.kind {
		case .Object:
			return {}, {}, .Not_Found
		case .Part:
			return {}, {}, .Malformed_Tree
		case .Tree:
		}
		if read_subtree == nil {
			return {}, {}, .Subtree_Read_Failed
		}
		next_tree, read_ok := read_subtree(entry.hash, scratch, user_data)
		if !read_ok {
			return {}, {}, .Subtree_Read_Failed
		}
		recomputed, hash_ref := tree_hash.tree_hash(next_tree)
		if hash_ref != .None || recomputed != entry.hash || tree_hash.tree_holds_parts(next_tree) {
			return {}, {}, .Subtree_Read_Failed
		}
		current = next_tree
	}

	return {}, {}, .Invalid_Asset_Path
}
