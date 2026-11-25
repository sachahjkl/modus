#+build !freestanding
package program_tree

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/tree_hash"

@(private = "file")
sample_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'p', 'r', 'g', tag}
	return blake3.hash(data[:])
}

@(private = "file")
encode_test_tree :: proc(t: ^testing.T, entries: []tree_hash.Tree_Entry, out: []u8) -> (bytes: []u8, digest: blake3.Hash) {
	written, ref := tree_hash.tree_encode(entries, out)
	testing.expect_value(t, ref, tree_hash.Tree_Refusal.None)
	bytes = out[:written]
	h, h_ref := tree_hash.tree_hash(bytes)
	testing.expect_value(t, h_ref, tree_hash.Tree_Refusal.None)
	return bytes, h
}

@(private = "file")
Asset_Subtree_Store :: struct {
	hashes:     [8]blake3.Hash,
	payloads:   [8][]u8,
	count:      int,
	tamper_idx: int, // -1 for no tamper
}

@(private = "file")
test_read_subtree :: proc "contextless" (
	tree_digest: blake3.Hash,
	scratch: []u8,
	user_data: rawptr,
) -> (encoded_tree: []u8, ok: bool) {
	store := (^Asset_Subtree_Store)(user_data)
	if store == nil {
		return nil, false
	}
	for i in 0 ..< store.count {
		if store.hashes[i] == tree_digest {
			src := store.payloads[i]
			if len(src) > len(scratch) {
				return nil, false
			}
			copy(scratch[:len(src)], src)
			if i == store.tamper_idx && len(src) > tree_hash.HEADER_SIZE {
				scratch[len(src) - 1] ~= 0x01
			}
			return scratch[:len(src)], true
		}
	}
	return nil, false
}

@(test)
program_tree_refusal_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for member in Program_Tree_Refusal {
		got, ok := program_tree_refusal_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	for bad in ([?]u64{11, 255, max(u64)}) {
		_, ok := program_tree_refusal_of_word(bad)
		testing.expectf(t, !ok, "word %d must not map to Program_Tree_Refusal", bad)
	}
}

@(test)
program_tree_validate_refuses_every_malformed_and_illegal_layout :: proc(t: ^testing.T) {
	buf: [1024]u8

	// Empty / truncated / bad magic -> Malformed_Tree.
	sum, ref := program_tree_validate(nil)
	testing.expect_value(t, ref, Program_Tree_Refusal.Malformed_Tree)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	garbage := [16]u8{0 = 'B', 1 = 'A', 2 = 'D', 3 = '!'}
	sum, ref = program_tree_validate(garbage[:])
	testing.expect_value(t, ref, Program_Tree_Refusal.Malformed_Tree)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// Empty MODTREE2 tree -> Missing_Entry_Module.
	empty_tree, _ := encode_test_tree(t, nil, buf[:])
	sum, ref = program_tree_validate(empty_tree)
	testing.expect_value(t, ref, Program_Tree_Refusal.Missing_Entry_Module)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// Part node -> Malformed_Tree.
	p1, _ := tree_hash.tree_entry_make(.Part, "a", sample_hash(1))
	part_tree, _ := encode_test_tree(t, []tree_hash.Tree_Entry{p1}, buf[:])
	sum, ref = program_tree_validate(part_tree)
	testing.expect_value(t, ref, Program_Tree_Refusal.Malformed_Tree)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// Only "assets" without "module" -> Missing_Entry_Module.
	assets_only, _ := tree_hash.tree_entry_make(.Tree, "assets", sample_hash(2))
	t_no_mod, _ := encode_test_tree(t, []tree_hash.Tree_Entry{assets_only}, buf[:])
	sum, ref = program_tree_validate(t_no_mod)
	testing.expect_value(t, ref, Program_Tree_Refusal.Missing_Entry_Module)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// "module" as Tree or zero hash -> Invalid_Entry_Module.
	mod_as_tree, _ := tree_hash.tree_entry_make(.Tree, "module", sample_hash(3))
	t_bad_mod, _ := encode_test_tree(t, []tree_hash.Tree_Entry{mod_as_tree}, buf[:])
	sum, ref = program_tree_validate(t_bad_mod)
	testing.expect_value(t, ref, Program_Tree_Refusal.Invalid_Entry_Module)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	mod_zero, _ := tree_hash.tree_entry_make(.Object, "module", {})
	t_zero_mod, _ := encode_test_tree(t, []tree_hash.Tree_Entry{mod_zero}, buf[:])
	sum, ref = program_tree_validate(t_zero_mod)
	testing.expect_value(t, ref, Program_Tree_Refusal.Invalid_Entry_Module)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// "modules" as Object or zero hash -> Invalid_Modules_Entry.
	good_mod, _ := tree_hash.tree_entry_make(.Object, "module", sample_hash(4))
	mods_as_obj, _ := tree_hash.tree_entry_make(.Object, "modules", sample_hash(5))
	t_bad_mods, _ := encode_test_tree(t, []tree_hash.Tree_Entry{good_mod, mods_as_obj}, buf[:])
	sum, ref = program_tree_validate(t_bad_mods)
	testing.expect_value(t, ref, Program_Tree_Refusal.Invalid_Modules_Entry)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	mods_zero, _ := tree_hash.tree_entry_make(.Tree, "modules", {})
	t_zero_mods, _ := encode_test_tree(t, []tree_hash.Tree_Entry{good_mod, mods_zero}, buf[:])
	sum, ref = program_tree_validate(t_zero_mods)
	testing.expect_value(t, ref, Program_Tree_Refusal.Invalid_Modules_Entry)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// "assets" as Object or zero hash -> Invalid_Assets_Entry.
	assets_as_obj, _ := tree_hash.tree_entry_make(.Object, "assets", sample_hash(6))
	t_bad_assets, _ := encode_test_tree(t, []tree_hash.Tree_Entry{assets_as_obj, good_mod}, buf[:])
	sum, ref = program_tree_validate(t_bad_assets)
	testing.expect_value(t, ref, Program_Tree_Refusal.Invalid_Assets_Entry)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	assets_zero, _ := tree_hash.tree_entry_make(.Tree, "assets", {})
	t_zero_assets, _ := encode_test_tree(t, []tree_hash.Tree_Entry{assets_zero, good_mod}, buf[:])
	sum, ref = program_tree_validate(t_zero_assets)
	testing.expect_value(t, ref, Program_Tree_Refusal.Invalid_Assets_Entry)
	testing.expect_value(t, sum, Program_Tree_Summary{})

	// Unexpected top-level entry -> Unexpected_Entry.
	extra, _ := tree_hash.tree_entry_make(.Object, "readme", sample_hash(7))
	t_extra, _ := encode_test_tree(t, []tree_hash.Tree_Entry{good_mod, extra}, buf[:])
	sum, ref = program_tree_validate(t_extra)
	testing.expect_value(t, ref, Program_Tree_Refusal.Unexpected_Entry)
	testing.expect_value(t, sum, Program_Tree_Summary{})
}

@(test)
program_tree_validate_accepts_minimal_and_full_layouts :: proc(t: ^testing.T) {
	buf: [1024]u8

	mod_hash := sample_hash(10)
	mods_hash := sample_hash(11)
	assets_hash := sample_hash(12)

	// Minimal: "module" only.
	e_mod, _ := tree_hash.tree_entry_make(.Object, "module", mod_hash)
	minimal, _ := encode_test_tree(t, []tree_hash.Tree_Entry{e_mod}, buf[:])
	sum, ref := program_tree_validate(minimal)
	testing.expect_value(t, ref, Program_Tree_Refusal.None)
	testing.expect_value(t, sum.entry_module_hash, mod_hash)
	testing.expect(t, !sum.has_modules && !sum.has_assets)
	testing.expect_value(t, sum.modules_tree_hash, blake3.Hash{})
	testing.expect_value(t, sum.assets_tree_hash, blake3.Hash{})

	// Full: "assets", "module", "modules" (sorted UTF-8 order).
	e_assets, _ := tree_hash.tree_entry_make(.Tree, "assets", assets_hash)
	e_mods, _ := tree_hash.tree_entry_make(.Tree, "modules", mods_hash)
	full, _ := encode_test_tree(t, []tree_hash.Tree_Entry{e_assets, e_mod, e_mods}, buf[:])
	sum, ref = program_tree_validate(full)
	testing.expect_value(t, ref, Program_Tree_Refusal.None)
	testing.expect_value(t, sum.entry_module_hash, mod_hash)
	testing.expect(t, sum.has_modules && sum.has_assets)
	testing.expect_value(t, sum.modules_tree_hash, mods_hash)
	testing.expect_value(t, sum.assets_tree_hash, assets_hash)
}

@(test)
program_tree_lookup_helper_checks_object_kind_hash_and_malformed_tree :: proc(t: ^testing.T) {
	buf: [1024]u8
	helper_hash := sample_hash(20)
	e_helper, _ := tree_hash.tree_entry_make(.Object, "codec", helper_hash)
	e_sub, _ := tree_hash.tree_entry_make(.Tree, "nested", sample_hash(21))
	e_zero, _ := tree_hash.tree_entry_make(.Object, "zero", {})
	mods_tree, _ := encode_test_tree(t, []tree_hash.Tree_Entry{e_helper, e_sub, e_zero}, buf[:])

	// Valid helper lookup succeeds.
	got, found := program_tree_lookup_helper(mods_tree, "codec")
	testing.expect(t, found)
	testing.expect_value(t, got, helper_hash)

	// Non-object entry, zero hash entry, absent name, invalid name, and malformed tree each return false.
	_, found = program_tree_lookup_helper(mods_tree, "nested")
	testing.expect(t, !found)
	_, found = program_tree_lookup_helper(mods_tree, "zero")
	testing.expect(t, !found)
	_, found = program_tree_lookup_helper(mods_tree, "absent")
	testing.expect(t, !found)
	_, found = program_tree_lookup_helper(mods_tree, "a/b")
	testing.expect(t, !found)
	_, found = program_tree_lookup_helper(mods_tree, "")
	testing.expect(t, !found)
	_, found = program_tree_lookup_helper(mods_tree[:8], "codec")
	testing.expect(t, !found)
}

@(test)
program_tree_lookup_asset_walks_nested_trees_and_refuses_bad_paths_or_tamper :: proc(t: ^testing.T) {
	leaf_buf: [512]u8
	mid_buf: [512]u8
	root_buf: [512]u8
	scratch: [512]u8

	font_hash := sample_hash(30)
	icon_hash := sample_hash(31)

	e_font, _ := tree_hash.tree_entry_make(.Object, "mono.ttf", font_hash)
	fonts_bytes, fonts_hash := encode_test_tree(t, []tree_hash.Tree_Entry{e_font}, leaf_buf[:])

	e_fonts, _ := tree_hash.tree_entry_make(.Tree, "fonts", fonts_hash)
	ui_bytes, ui_hash := encode_test_tree(t, []tree_hash.Tree_Entry{e_fonts}, mid_buf[:])

	e_icon, _ := tree_hash.tree_entry_make(.Object, "icon.png", icon_hash)
	e_ui, _ := tree_hash.tree_entry_make(.Tree, "ui", ui_hash)
	assets_bytes, _ := encode_test_tree(t, []tree_hash.Tree_Entry{e_icon, e_ui}, root_buf[:])

	store := Asset_Subtree_Store{tamper_idx = -1}
	store.hashes[0] = ui_hash
	store.payloads[0] = ui_bytes
	store.hashes[1] = fonts_hash
	store.payloads[1] = fonts_bytes
	store.count = 2

	// Bad paths refused before any callback invocation.
	for bad in ([?]string{"", "/", "/icon.png", "icon.png/", "ui//fonts", ".", "..", "ui/../icon.png", "ui/./fonts"}) {
		_, _, ref := program_tree_lookup_asset(assets_bytes, bad, test_read_subtree, scratch[:], &store)
		testing.expectf(t, ref == .Invalid_Asset_Path, "bad path %q expected Invalid_Asset_Path, got %v", bad, ref)
	}

	// Path exceeding ASSET_PATH_MAX_DEPTH (33 segments) refused.
	deep_builder := strings.builder_make(context.temp_allocator)
	for i in 0 ..< ASSET_PATH_MAX_DEPTH + 1 {
		if i > 0 {
			strings.write_byte(&deep_builder, '/')
		}
		strings.write_byte(&deep_builder, 'a')
	}
	_, _, deep_ref := program_tree_lookup_asset(assets_bytes, strings.to_string(deep_builder), test_read_subtree, scratch[:], &store)
	testing.expect_value(t, deep_ref, Program_Tree_Refusal.Invalid_Asset_Path)

	// Path exceeding ASSET_PATH_MAX_BYTES refused.
	long_builder := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 5 {
		if i > 0 {
			strings.write_byte(&long_builder, '/')
		}
		for _ in 0 ..< 210 {
			strings.write_byte(&long_builder, 'x')
		}
	}
	_, _, long_ref := program_tree_lookup_asset(assets_bytes, strings.to_string(long_builder), test_read_subtree, scratch[:], &store)
	testing.expect_value(t, long_ref, Program_Tree_Refusal.Invalid_Asset_Path)

	// Top-level object lookup succeeds without needing callback.
	h, k, ref := program_tree_lookup_asset(assets_bytes, "icon.png", nil, nil)
	testing.expect_value(t, ref, Program_Tree_Refusal.None)
	testing.expect_value(t, k, tree_hash.Tree_Entry_Kind.Object)
	testing.expect_value(t, h, icon_hash)

	// Nested lookup across 3 levels succeeds.
	h, k, ref = program_tree_lookup_asset(assets_bytes, "ui/fonts/mono.ttf", test_read_subtree, scratch[:], &store)
	testing.expect_value(t, ref, Program_Tree_Refusal.None)
	testing.expect_value(t, k, tree_hash.Tree_Entry_Kind.Object)
	testing.expect_value(t, h, font_hash)

	// Lookup of nested Tree directory returns Tree kind and its hash.
	h, k, ref = program_tree_lookup_asset(assets_bytes, "ui/fonts", test_read_subtree, scratch[:], &store)
	testing.expect_value(t, ref, Program_Tree_Refusal.None)
	testing.expect_value(t, k, tree_hash.Tree_Entry_Kind.Tree)
	testing.expect_value(t, h, fonts_hash)

	// Traversing through a leaf object or absent entry -> Not_Found.
	_, _, ref = program_tree_lookup_asset(assets_bytes, "icon.png/child", test_read_subtree, scratch[:], &store)
	testing.expect_value(t, ref, Program_Tree_Refusal.Not_Found)
	_, _, ref = program_tree_lookup_asset(assets_bytes, "ui/fonts/missing.ttf", test_read_subtree, scratch[:], &store)
	testing.expect_value(t, ref, Program_Tree_Refusal.Not_Found)

	// Nil callback on nested path -> Subtree_Read_Failed.
	_, _, ref = program_tree_lookup_asset(assets_bytes, "ui/fonts/mono.ttf", nil, scratch[:])
	testing.expect_value(t, ref, Program_Tree_Refusal.Subtree_Read_Failed)

	// Tampered intermediate subtree returned by callback -> Subtree_Read_Failed (tree_hash mismatch).
	store.tamper_idx = 0
	_, _, ref = program_tree_lookup_asset(assets_bytes, "ui/fonts/mono.ttf", test_read_subtree, scratch[:], &store)
	testing.expect_value(t, ref, Program_Tree_Refusal.Subtree_Read_Failed)
}
