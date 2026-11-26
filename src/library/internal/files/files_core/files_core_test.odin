#+build !freestanding
package files_core

import "core:strings"
import "core:testing"
import "modus:ast_codebase"
import "modus:contract/blake3"
import "modus:contract/root_ring"
import box_layout "modus:layout"
import "modus:text_model"

@(test)
entry_name_validation_refuses_disallowed_inputs :: proc(t: ^testing.T) {
	testing.expect(t, !validate_entry_name(""), "empty name refused")
	testing.expect(t, !validate_entry_name("bad/slash"), "slash in name refused")
	testing.expect(t, !validate_entry_name("bad\x00nul"), "NUL byte refused")
	testing.expect(t, !validate_entry_name("bad\nline"), "control byte refused")
	bad_utf8 := [2]u8{0xFF, 0xFE}
	testing.expect(t, !validate_entry_name(string(bad_utf8[:])), "invalid UTF-8 refused")

	too_long: [ENTRY_NAME_MAX_BYTES + 1]u8
	for &b in too_long {
		b = 'a'
	}
	testing.expect(t, !validate_entry_name(string(too_long[:])), "256-byte name refused")

	max_ok: [ENTRY_NAME_MAX_BYTES]u8
	for &b in max_ok {
		b = 'x'
	}
	testing.expect(t, validate_entry_name(string(max_ok[:])), "255-byte name accepted")
	testing.expect(t, validate_entry_name("main.db"), "normal object name accepted")
	testing.expect(t, validate_entry_name("notes-café"), "UTF-8 name accepted")
}

@(test)
off_thread_filtering_orders_trees_first_and_folds_ascii_case :: proc(t: ^testing.T) {
	snap := new(Explorer_Snapshot, context.temp_allocator)
	add_entry :: proc(s: ^Explorer_Snapshot, name: string, kind: Entry_Kind, size: i64) {
		e := &s.entries[s.entry_count]
		e^ = {kind = kind, size = size, name_len = u16(len(name))}
		copy(e.name[:len(name)], name)
		s.entry_count += 1
	}
	add_entry(snap, "alpha.txt", .Object, 120)
	add_entry(snap, "Docs", .Tree, 3)
	add_entry(snap, "notes.db", .Object, 4096)
	add_entry(snap, "drafts", .Tree, 1)

	filter_entries_off_thread(snap, "")
	testing.expect_value(t, snap.filtered_count, 4)
	e0, _ := snapshot_filtered_entry(snap, 0)
	e1, _ := snapshot_filtered_entry(snap, 1)
	e2, _ := snapshot_filtered_entry(snap, 2)
	testing.expect_value(t, string(e0.name[:e0.name_len]), "Docs")
	testing.expect_value(t, string(e1.name[:e1.name_len]), "drafts")
	testing.expect_value(t, string(e2.name[:e2.name_len]), "alpha.txt")

	// Case-insensitive match on "D" matches Docs, drafts, notes.db.
	filter_entries_off_thread(snap, "D")
	testing.expect_value(t, snap.filtered_count, 3)
	e0, _ = snapshot_filtered_entry(snap, 0)
	e2, _ = snapshot_filtered_entry(snap, 2)
	testing.expect_value(t, string(e0.name[:e0.name_len]), "Docs")
	testing.expect_value(t, string(e2.name[:e2.name_len]), "notes.db")

	// Unmatched filter clears selection.
	filter_entries_off_thread(snap, "zzzz")
	testing.expect_value(t, snap.filtered_count, 0)
	testing.expect_value(t, snap.selected_entry, -1)
}

@(test)
hex_inspector_and_streaming_blake3_handle_large_and_binary_objects :: proc(t: ^testing.T) {
	// Format canonical 16-byte hex row.
	sample := [18]u8{'H', 'e', 'l', 'l', 'o', 0x00, 0x7F, 0xFF, ' ', 'm', 'o', 'd', 'u', 's', '!', '\n', 0x41, 0x42}
	row_buf: [96]u8
	r0 := format_hex_row(sample[:], 0, row_buf[:])
	testing.expect(t, strings.has_prefix(r0, "00000000  48 65 6c 6c 6f 00 7f ff  20 6d 6f 64 75 73 21 0a  |Hello... modus!.|"), "canonical row 0 hex format")
	r1 := format_hex_row(sample[:], 1, row_buf[:])
	testing.expect(t, strings.has_prefix(r1, "00000010  41 42"), "partial final hex row")
	testing.expect(t, strings.has_suffix(r1, "|AB|"), "partial final ASCII column")
	testing.expect_value(t, format_hex_row(sample[:], -1, row_buf[:]), "")
	testing.expect_value(t, format_hex_row(sample[:], 2, row_buf[:]), "")

	// Stream an object larger than PREVIEW_MAX_BYTES (80 KiB) and verify exact full BLAKE3 hash + preview truncation.
	big := make([]u8, PREVIEW_MAX_BYTES + 16384, context.temp_allocator)
	for i in 0 ..< len(big) {
		big[i] = u8('a' + (i % 26))
		if i % 64 == 63 {
			big[i] = '\n'
		}
	}
	Mock_Reader :: struct {
		data:           []u8,
		overrun_attack: bool,
	}
	reader_proc :: proc "contextless" (ud: rawptr, offset: u64, dst: []u8) -> ([]u8, Problem_Kind) {
		m := (^Mock_Reader)(ud)
		if m.overrun_attack {
			// Return slice longer than remaining size to test upper-bound guard.
			return m.data, .None
		}
		if offset >= u64(len(m.data)) {
			return nil, .None
		}
		n := min(u64(len(dst)), u64(len(m.data)) - offset)
		copy(dst[:n], m.data[offset:][:n])
		return dst[:n], .None
	}

	snap := new(Explorer_Snapshot, context.temp_allocator)
	chunk: [8192]u8
	mock := Mock_Reader{data = big}
	prob := inspect_object_stream(snap, "big.txt", i64(len(big)), 7, reader_proc, &mock, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.None)
	testing.expect(t, snap.has_hash && snap.object_hash == blake3.hash(big), "full BLAKE3 hash matches entire 80 KiB object")
	testing.expect_value(t, snap.preview_len, PREVIEW_MAX_BYTES)
	testing.expect(t, snap.preview_truncated, "preview_truncated set when object exceeds PREVIEW_MAX_BYTES")
	testing.expect(t, snap.preview_is_utf8 && snap.preview_line_count > 100, "UTF-8 preview lines pre-indexed")

	// Binary detection flips preview_is_utf8 to false.
	bin := [4]u8{0x89, 0x50, 0x4E, 0x00}
	mock_bin := Mock_Reader{data = bin[:]}
	prob = inspect_object_stream(snap, "img.bin", 4, 2, reader_proc, &mock_bin, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.None)
	testing.expect(t, !snap.preview_is_utf8, "binary object detected as non-UTF-8")

	// Hostile/overrun chunk refused as Object_Damaged.
	mock_bad := Mock_Reader{data = big, overrun_attack = true}
	prob = inspect_object_stream(snap, "bad.bin", 4, 1, reader_proc, &mock_bad, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.Object_Damaged)

	// Refusal & edge cases: size 0, negative size, 0-byte short read, nil read_fn, empty chunk_buf.
	empty_reader := Mock_Reader{data = nil}
	prob = inspect_object_stream(snap, "empty.txt", 0, 1, reader_proc, &empty_reader, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.None)
	testing.expect(t, snap.has_hash && snap.object_hash == blake3.hash(nil) && snap.preview_len == 0 && snap.preview_is_utf8)

	prob = inspect_object_stream(snap, "neg", -1, 1, reader_proc, &empty_reader, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.Object_Unreadable)

	prob = inspect_object_stream(snap, "short", 10, 1, reader_proc, &empty_reader, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.Object_Damaged)

	prob = inspect_object_stream(snap, "nil_fn", 4, 1, nil, nil, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.Object_Unreadable)

	prob = inspect_object_stream(snap, "empty_buf", 4, 1, reader_proc, &mock_bin, nil)
	testing.expect_value(t, prob, Problem_Kind.Object_Unreadable)

	// Multi-byte UTF-8 character ("€" = E2 82 AC) straddling PREVIEW_MAX_BYTES boundary stays valid UTF-8 text.
	split_utf8 := make([]u8, PREVIEW_MAX_BYTES + 16, context.temp_allocator)
	for i in 0 ..< len(split_utf8) {
		split_utf8[i] = 'a'
	}
	split_utf8[PREVIEW_MAX_BYTES - 1] = 0xE2
	split_utf8[PREVIEW_MAX_BYTES] = 0x82
	split_utf8[PREVIEW_MAX_BYTES + 1] = 0xAC
	mock_split := Mock_Reader{data = split_utf8}
	prob = inspect_object_stream(snap, "utf8_edge.txt", i64(len(split_utf8)), 3, reader_proc, &mock_split, chunk[:])
	testing.expect_value(t, prob, Problem_Kind.None)
	testing.expect(t, snap.preview_is_utf8, "UTF-8 character split across PREVIEW_MAX_BYTES boundary must trim cleanly")
	testing.expect_value(t, snap.preview_len, PREVIEW_MAX_BYTES - 1)
	testing.expect(t, snap.object_hash == blake3.hash(split_utf8), "full BLAKE3 hash still covers untrimmed bytes")
}

@(test)
syntax_carries_precompute_off_thread_for_c_lex_and_odin :: proc(t: ^testing.T) {
	snap := new(Explorer_Snapshot, context.temp_allocator)
	// Odin nested block comments and raw backtick strings carry cleanly across lines.
	odin_src := "/* outer\n/* nested */\nstill comment */\nx := `raw\nline`\nreturn 0\n"
	snap.object_name_len = u16(copy(snap.object_name[:], "main.odin"))
	snap.preview_len = copy(snap.preview_bytes[:], odin_src)
	index_preview_lines(snap)
	testing.expect_value(t, snap.preview_language, text_model.Syntax_Language.Odin)
	testing.expect_value(t, snap.preview_line_count, 6)
	testing.expect_value(t, snap.preview_line_carries[0], text_model.Syntax_Carry(0))
	testing.expect_value(t, snap.preview_line_carries[1] & text_model.SYNTAX_CARRY_DEPTH_MASK, text_model.Syntax_Carry(1))
	testing.expect_value(t, snap.preview_line_carries[2] & text_model.SYNTAX_CARRY_DEPTH_MASK, text_model.Syntax_Carry(1))
	testing.expect_value(t, snap.preview_line_carries[3], text_model.Syntax_Carry(0))
	testing.expect(t, (snap.preview_line_carries[4] & text_model.SYNTAX_CARRY_BACKTICK) != 0, "line 4 starts inside raw backtick string")
	testing.expect_value(t, snap.preview_line_carries[5], text_model.Syntax_Carry(0))

	// C and Lex detection; plain text stays .Plain.
	snap.object_name_len = u16(copy(snap.object_name[:], "driver.c"))
	snap.preview_len = copy(snap.preview_bytes[:], "/* comment\nline */\nint x = 1;\n")
	index_preview_lines(snap)
	testing.expect_value(t, snap.preview_language, text_model.Syntax_Language.C)
	testing.expect_value(t, snap.preview_line_carries[1] & text_model.SYNTAX_CARRY_DEPTH_MASK, text_model.Syntax_Carry(1))
	testing.expect_value(t, snap.preview_line_carries[2], text_model.Syntax_Carry(0))

	snap.object_name_len = u16(copy(snap.object_name[:], "build.recipe"))
	snap.preview_len = copy(snap.preview_bytes[:], "recipe { name = \"app\" }\n")
	index_preview_lines(snap)
	testing.expect_value(t, snap.preview_language, text_model.Syntax_Language.Lex)

	snap.object_name_len = u16(copy(snap.object_name[:], "readme.txt"))
	index_preview_lines(snap)
	testing.expect_value(t, snap.preview_language, text_model.Syntax_Language.Plain)
}

@(test)
edit_target_store_and_path_resolution_handles_edges :: proc(t: ^testing.T) {
	snap := new(Explorer_Snapshot, context.temp_allocator)
	store_buf: [STORE_NAME_MAX_BYTES]u8
	path_buf: [root_ring.EDIT_TARGET_PATH_LIMIT]u8

	// Nil snapshot refused.
	testing.expect_value(t, resolve_edit_store_name(nil, store_buf[:]), "")
	_, ok := build_edit_object_path(nil, path_buf[:])
	testing.expect(t, !ok)

	// Private store (index 0) with no other stores resolves to "files".
	snap.stores[0].name_len = u8(copy(snap.stores[0].name[:], "private"))
	snap.store_count = 1
	snap.active_store = 0
	testing.expect_value(t, resolve_edit_store_name(snap, store_buf[:]), "files")

	// Named principal inferred from another listed store before files commits.
	snap.stores[1].name_len = u8(copy(snap.stores[1].name[:], "notes.principal.3"))
	snap.store_count = 2
	testing.expect_value(t, resolve_edit_store_name(snap, store_buf[:]), "files.principal.3")

	// Explicit files.principal.3 store in listing is returned directly.
	snap.stores[2].name_len = u8(copy(snap.stores[2].name[:], "files.principal.3"))
	snap.store_count = 3
	testing.expect_value(t, resolve_edit_store_name(snap, store_buf[:]), "files.principal.3")

	// Active store > 0 returns its exact canonical name.
	snap.active_store = 1
	testing.expect_value(t, resolve_edit_store_name(snap, store_buf[:]), "notes.principal.3")

	// No selected entry -> path build refused.
	snap.selected_entry = -1
	_, ok = build_edit_object_path(snap, path_buf[:])
	testing.expect(t, !ok)

	// Selected tree -> path build refused (only objects open in edit).
	snap.entries[0] = {kind = .Tree}
	snap.entries[0].name_len = u16(copy(snap.entries[0].name[:], "src"))
	snap.entries[1] = {kind = .Object}
	snap.entries[1].name_len = u16(copy(snap.entries[1].name[:], "main.c"))
	snap.entry_count = 2
	filter_entries_off_thread(snap, "")
	snap.selected_entry = 0 // "src" tree
	_, ok = build_edit_object_path(snap, path_buf[:])
	testing.expect(t, !ok, "tree entry must be refused for Start_Edit")

	// Selected object at root -> "main.c".
	snap.selected_entry = 1 // "main.c" object
	path, built := build_edit_object_path(snap, path_buf[:])
	testing.expect(t, built && path == "main.c")

	// Selected object inside nested trees -> "src/app/main.c".
	snap.path[0].name_len = u16(copy(snap.path[0].name[:], "src"))
	snap.path[1].name_len = u16(copy(snap.path[1].name[:], "app"))
	snap.path_depth = 2
	path, built = build_edit_object_path(snap, path_buf[:])
	testing.expect(t, built && path == "src/app/main.c")

	// Undersized output buffer refused.
	tiny: [4]u8
	_, built = build_edit_object_path(snap, tiny[:])
	testing.expect(t, !built)

	// Path exceeding EDIT_TARGET_PATH_LIMIT refused.
	snap.path[0].name_len = u16(200)
	for i in 0 ..< 200 {
		snap.path[0].name[i] = 'a'
	}
	snap.path[1].name_len = u16(100)
	for i in 0 ..< 100 {
		snap.path[1].name[i] = 'b'
	}
	_, built = build_edit_object_path(snap, path_buf[:])
	testing.expect(t, !built, "path past EDIT_TARGET_PATH_LIMIT must be refused")
}

@(test)
stores_listing_parser_and_formatters_work :: proc(t: ^testing.T) {
	listing := "disk: 1048576 blocks\nnotes: 12 blocks, 4 objects\ndb_browser: 32 blocks, 1 object\nbadline_without_colon\n"
	stores: [8]Store_Item
	n := parse_stores_listing(transmute([]u8)listing, stores[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, string(stores[0].name[:stores[0].name_len]), "notes")
	testing.expect_value(t, string(stores[1].name[:stores[1].name_len]), "db_browser")

	// Edge & refusal cases for parse_stores_listing: empty, header-only, >32-byte name, invalid UTF-8, full out slice.
	testing.expect_value(t, parse_stores_listing(nil, stores[:]), 0)
	testing.expect_value(t, parse_stores_listing(transmute([]u8)string("disk: 1024 blocks\n"), stores[:]), 0)
	overlong := "disk: 1024 blocks\nthis_store_name_is_far_longer_than_thirty_two_bytes: 1 block\nok: 2 blocks\n"
	testing.expect_value(t, parse_stores_listing(transmute([]u8)overlong, stores[:]), 1)
	testing.expect_value(t, string(stores[0].name[:stores[0].name_len]), "ok")

	bad_utf8_listing := [?]u8{'d', '\n', 0xFF, 0xFE, ':', ' ', '1', '\n', 'a', ':', ' ', '2', '\n'}
	testing.expect_value(t, parse_stores_listing(bad_utf8_listing[:], stores[:]), 1)
	testing.expect_value(t, string(stores[0].name[:stores[0].name_len]), "a")

	small_out: [1]Store_Item
	testing.expect_value(t, parse_stores_listing(transmute([]u8)listing, small_out[:]), 1)

	buf: [128]u8
	usage := Usage_Info{objects = 5, trees = 2, versions = 11, blocks = 48, limit = 1024, has_usage = true}
	testing.expect_value(t, format_usage_summary(usage, false, buf[:]), "48/1024 blocks · 5 objects · 11 versions")
	testing.expect_value(t, format_usage_summary(usage, true, buf[:]), "48/1024 blocks · 5 objects · 11 versions · read only")

	diffs := [2]Diff_Range{{first = 0, count = 512}, {first = 4096, count = 512}}
	testing.expect_value(t, format_diff_summary(diffs[:], buf[:]), "2 changed ranges (1 KiB)")
	testing.expect_value(t, format_diff_summary(nil, buf[:]), "Matches current version")
}

@(test)
layout_spec_never_overlaps_across_all_window_sizes :: proc(t: ^testing.T) {
	tree := new(box_layout.Box_Tree, context.temp_allocator)
	_, ok := compute_layout(tree, LEAST_WIDTH - 1, LEAST_HEIGHT, DEFAULT_SPLIT_RATIOS, 180)
	testing.expect(t, !ok, "width below LEAST_WIDTH refused")
	_, ok = compute_layout(tree, LEAST_WIDTH, LEAST_HEIGHT - 1, DEFAULT_SPLIT_RATIOS, 180)
	testing.expect(t, !ok, "height below LEAST_HEIGHT refused")

	sizes := [3][2]i32{
		{LEAST_WIDTH, LEAST_HEIGHT},
		{DEFAULT_WIDTH, DEFAULT_HEIGHT},
		{LARGEST_WIDTH, LARGEST_HEIGHT},
	}
	extreme := [3]Split_Ratios{
		{sidebar_ratio = 0, list_ratio = 0},
		DEFAULT_SPLIT_RATIOS,
		{sidebar_ratio = 10_000, list_ratio = 10_000},
	}
	for sz in sizes {
		for r in extreme {
			lay, solved := compute_layout(tree, sz[0], sz[1], r, 240)
			testing.expect(t, solved, "valid size must solve")
			testing.expect(t, lay.sidebar.width >= SIDEBAR_MIN_WIDTH)
			testing.expect(t, lay.right_column.width >= RIGHT_MIN_WIDTH)
			testing.expect(t, lay.list_pane.height >= LIST_MIN_HEIGHT)
			testing.expect(t, lay.inspector_pane.height >= INSPECTOR_MIN_HEIGHT)
			testing.expect(t, lay.status.height == STATUS_HEIGHT)
			testing.expect(t, lay.action_bar.height == ACTION_BAR_HEIGHT)

			regions := [7]box_layout.Rect{
				lay.sidebar_stores,
				lay.sidebar_path,
				lay.sidebar_divider,
				lay.list_pane,
				lay.middle_divider,
				lay.inspector_pane,
				lay.status,
			}
			for i in 0 ..< len(regions) {
				for j in i + 1 ..< len(regions) {
					testing.expect(t, !rects_overlap(regions[i], regions[j]), "sibling panes must never overlap")
				}
			}
			testing.expect(t, !rects_overlap(lay.status, lay.action_bar))
			testing.expect(t, !rects_overlap(lay.list_header, lay.list_body))
			testing.expect(t, !rects_overlap(lay.list_body, lay.list_scroll))
			testing.expect(t, !rects_overlap(lay.inspector_header, lay.inspector_body))
			testing.expect(t, !rects_overlap(lay.inspector_body, lay.inspector_scroll))
		}
	}
}

@(test)
session_state_and_writing_rules_hold :: proc(t: ^testing.T) {
	s: Session_State
	session_init(&s)

	s1 := session_next_serial(&s)
	s2 := session_next_serial(&s)
	testing.expect(t, session_accept_serial(&s, s2))
	testing.expect(t, !session_accept_serial(&s, s1), "stale serial dropped")
	testing.expect(t, !session_accept_serial(&s, 0), "zero serial dropped")

	// Queue overflow refusal and Open_In_Editor request round-trip.
	q: Ring_Queue(Worker_Request)
	for i in 0 ..< QUEUE_CAPACITY {
		req := Worker_Request{kind = .Open_In_Editor, serial = u64(i + 1)}
		testing.expect(t, queue_push(&q, &req))
	}
	extra := Worker_Request{kind = .Open_In_Editor, serial = 99}
	testing.expect(t, !queue_push(&q, &extra), "full queue must refuse push")
	popped: Worker_Request
	testing.expect(t, queue_pop(&q, &popped) && popped.kind == .Open_In_Editor && popped.serial == 1)

	// Revocation forces read-only and blocks restore.
	snap := new(Explorer_Snapshot, context.temp_allocator)
	snap.version_count = 2
	snap.versions[0] = {generation = 1, current = false}
	snap.versions[1] = {generation = 2, current = true}
	snap.version_chosen = 0
	s.mode = .Versions
	s.store_connected = true
	testing.expect(t, session_can_restore(&s, snap))
	session_mark_revoked(&s)
	testing.expect(t, !s.store_connected && s.read_only)
	testing.expect(t, !session_can_restore(&s, snap))

	// UTF-8 prompt input, whole-rune backspace, 255-byte capacity, and control refusal.
	session_prompt_open(&s, .New_Object)
	testing.expect(t, !session_prompt_push_rune(&s, '\n'), "control rune refused in prompt")
	testing.expect(t, session_prompt_push_rune(&s, 'c'))
	testing.expect(t, session_prompt_push_rune(&s, 'a'))
	testing.expect(t, session_prompt_push_rune(&s, 'f'))
	testing.expect(t, session_prompt_push_rune(&s, 'é'))
	testing.expect(t, session_prompt_push_rune(&s, '€'))
	testing.expect_value(t, session_prompt_text(&s), "café€")
	testing.expect(t, session_prompt_backspace(&s))
	testing.expect_value(t, session_prompt_text(&s), "café")
	testing.expect(t, session_prompt_backspace(&s))
	testing.expect_value(t, session_prompt_text(&s), "caf")

	long_name: [ENTRY_NAME_MAX_BYTES]u8
	for &b in long_name {
		b = 'z'
	}
	session_prompt_open(&s, .Confirm_Remove, string(long_name[:]))
	testing.expect_value(t, len(session_prompt_text(&s)), ENTRY_NAME_MAX_BYTES)
	testing.expect(t, !session_prompt_push_rune(&s, 'x'), "256th byte refused")

	// docs/WRITING.md audit on every Problem_Kind sentence (including Edit_Open_Refused).
	testing.expect(t, len(PROBLEM_SENTENCES[.Edit_Open_Refused]) > 0)
	forbidden := [?]string{"invalid", "illegal", "fatal", "please", "sorry", "failed", "Error", "n't", "can't", "won't"}
	for kind in Problem_Kind {
		sentence := PROBLEM_SENTENCES[kind]
		lower := strings.to_lower(sentence, context.temp_allocator)
		for bad in forbidden {
			check := bad == "Error" ? sentence : lower
			testing.expectf(t, !strings.contains(check, bad), "Problem_Kind.%v violates docs/WRITING.md with %q: %q", kind, bad, sentence)
		}
	}
}

@(test)
modast1_binary_object_renders_ast_preview_and_refuses_corrupt :: proc(t: ^testing.T) {
	cb := new(ast_codebase.Codebase)
	defer free(cb)
	scratch := new(ast_codebase.Codebase)
	defer free(scratch)
	snap := new(Explorer_Snapshot)
	defer free(snap)
	wire := make([]u8, 65536)
	defer delete(wire)
	text_buf := make([]u8, PREVIEW_MAX_BYTES)
	defer delete(text_buf)
	chunk := make([]u8, 4096)
	defer delete(chunk)

	testing.expect(t, ast_codebase.codebase_seed_sample(cb), "seed sample must succeed")
	enc_len, enc_err := ast_codebase.codebase_encode(cb, wire)
	testing.expect_value(t, enc_err, ast_codebase.Codec_Error.Ok)

	Slice_Ctx :: struct {
		data: []u8,
	}
	read_slice :: proc "contextless" (ud: rawptr, offset: u64, dst: []u8) -> ([]u8, Problem_Kind) {
		sc := (^Slice_Ctx)(ud)
		if offset >= u64(len(sc.data)) {
			return nil, .Object_Unreadable
		}
		n := min(len(dst), len(sc.data) - int(offset))
		copy(dst[:n], sc.data[int(offset):][:n])
		return dst[:n], .None
	}

	// Refusal first: corrupt MODAST1 payload falls back cleanly to binary Hex mode.
	corrupt := make([]u8, enc_len)
	defer delete(corrupt)
	copy(corrupt, wire[:enc_len])
	corrupt[enc_len - 1] ~= 0xFF
	bad_ctx := Slice_Ctx{data = corrupt}
	testing.expect_value(t, inspect_object_stream(snap, "broken.ast", i64(len(corrupt)), 1, read_slice, &bad_ctx, chunk, scratch, text_buf), Problem_Kind.None)
	testing.expect(t, !snap.preview_is_utf8, "corrupt MODAST1 blob must stay binary for Hex inspection")

	// Valid MODAST1 payload decodes to C syntax-highlighted preview with BLAKE3 hashes.
	good_ctx := Slice_Ctx{data = wire[:enc_len]}
	testing.expect_value(t, inspect_object_stream(snap, "codebase.ast", i64(enc_len), 2, read_slice, &good_ctx, chunk, scratch, text_buf), Problem_Kind.None)
	testing.expect(t, snap.preview_is_utf8, "valid MODAST1 blob must render decoded UTF-8 preview")
	testing.expect_value(t, snap.preview_language, text_model.Syntax_Language.C)
	testing.expect(t, snap.preview_line_count > 0, "decoded MODAST1 preview must index lines")
	rendered := string(snap.preview_bytes[:snap.preview_len])
	testing.expect(t, strings.contains(rendered, "MODAST1 AST codebase:"), "preview must include MODAST1 header")
	testing.expect(t, strings.contains(rendered, "blake3:"), "preview must include definition BLAKE3 digests")
	testing.expect(t, strings.contains(rendered, "long square(long x)"), "preview must include emitted C code")
}
