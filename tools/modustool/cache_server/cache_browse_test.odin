// Host tests for the cache browser (src/md/infrastructure/cache_browser.md):
// path parsing refusals, tree paging and escaping, blob classification, module
// metadata, raw download headers, realisation verification and recipe objects,
// release pointers, and bounded prefix search.
package cache_server

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "modus:contract/blake3"
import "modus:contract/module"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modus:cryptography/ed25519"

// make_minimal_valid_module constructs a valid modus module file with one
// export, documentation, and a requested budget for blob inspection tests.
@(private = "file")
make_minimal_valid_module :: proc(allocator := context.temp_allocator) -> []u8 {
	str_buf := strings.builder_make(context.temp_allocator)
	strings.write_byte(&str_buf, 0) // offset 0 unused
	add_str :: proc(b: ^strings.Builder, s: string) -> (offset: u32, count: u32) {
		offset = u32(strings.builder_len(b^))
		strings.write_string(b, s)
		return offset, u32(len(s))
	}
	fn_name_off, fn_name_len := add_str(&str_buf, "hello")
	param_name_off, param_name_len := add_str(&str_buf, "count")
	fn_about_off, fn_about_len := add_str(&str_buf, "Returns a greeting for <reader>.")
	doc_about_off, doc_about_len := add_str(&str_buf, "Sample library module.")
	doc_text_off, doc_text_len := add_str(&str_buf, "Detailed documentation for sample library.")
	str_bytes := transmute([]u8)strings.to_string(str_buf)

	table_count :: u32(module.Table_Kind.Budget) + 1
	header_size := size_of(module.Header)
	dir_size := int(table_count) * size_of(module.Table_Entry)
	exports_off := header_size + dir_size
	exports_size := 2 * size_of(module.Export)
	funcs_off := exports_off + exports_size
	funcs_size := 2 * size_of(module.Function)
	strings_off := funcs_off + funcs_size
	strings_size := len(str_bytes)
	docs_off := strings_off + strings_size
	docs_size := 2 * size_of(module.Documentation)
	budget_off := docs_off + docs_size
	budget_size := 2 * size_of(module.Budget_Request)
	total := budget_off + budget_size

	out := make([]u8, total, allocator)

	hdr := module.Header {
		magic        = module.MAGIC,
		version      = module.VERSION,
		header_size  = u32(header_size),
		machine      = .X86_64,
		table_count  = table_count,
		memory_size  = module.PAGE_SIZE,
		entry_export = 1,
		category     = .Library,
	}
	mem.copy(raw_data(out), &hdr, size_of(hdr))

	dir := ([^]module.Table_Entry)(raw_data(out[header_size:]))
	dir[module.Table_Kind.Exports] = {offset = u64(exports_off), count = 2, record_size = size_of(module.Export)}
	dir[module.Table_Kind.Functions] = {offset = u64(funcs_off), count = 2, record_size = size_of(module.Function)}
	dir[module.Table_Kind.Strings] = {offset = u64(strings_off), count = u32(strings_size), record_size = 1}
	dir[module.Table_Kind.Documentation] = {offset = u64(docs_off), count = 2, record_size = size_of(module.Documentation)}
	dir[module.Table_Kind.Budget] = {offset = u64(budget_off), count = 2, record_size = size_of(module.Budget_Request)}

	exports := ([^]module.Export)(raw_data(out[exports_off:]))
	exports[1] = {code_offset = 0, function = 1}

	funcs := ([^]module.Function)(raw_data(out[funcs_off:]))
	fn := module.Function {
		name_offset     = fn_name_off,
		name_count      = fn_name_len,
		about_offset    = fn_about_off,
		about_count     = fn_about_len,
		parameter_count = 1,
		result          = u8(module.Type.Text),
	}
	fn.parameters[0] = u8(module.Type.Integer)
	fn.parameter_names[0] = param_name_off
	fn.parameter_name_counts[0] = u8(param_name_len)
	funcs[1] = fn

	copy(out[strings_off:], str_bytes)

	docs := ([^]module.Documentation)(raw_data(out[docs_off:]))
	docs[1] = {
		about_offset = doc_about_off,
		about_count  = doc_about_len,
		text_offset  = doc_text_off,
		text_count   = doc_text_len,
	}

	budgets := ([^]module.Budget_Request)(raw_data(out[budget_off:]))
	budgets[1] = {pages = 16, processes = 1, threads = 2}

	return out
}

// Every refused path form, hash edge, page number edge, and search query edge.
@(test)
browse_path_parser_refuses_hostile_and_bad_targets :: proc(t: ^testing.T) {
	good := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	upper := "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"
	short63 := good[:63]
	long65 := strings.concatenate({good, "0"}, context.temp_allocator)
	bad_targets := [?]string {
		"/tree/",
		"/blob/",
		"/realisation/",
		strings.concatenate({"/tree/", short63}, context.temp_allocator),
		strings.concatenate({"/tree/", long65}, context.temp_allocator),
		strings.concatenate({"/tree/", upper}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "/"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "/extra"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=0"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=1"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=02"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=-1"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=abc"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page="}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=10000"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=999999999999"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?p=2"}, context.temp_allocator),
		strings.concatenate({"/tree/", good, "?page=2&x=1"}, context.temp_allocator),
		"/tree/../objects",
		"/tree/%2e%2e/objects",
		strings.concatenate({"/blob/", short63}, context.temp_allocator),
		strings.concatenate({"/blob/", upper}, context.temp_allocator),
		strings.concatenate({"/blob/", good, "/"}, context.temp_allocator),
		strings.concatenate({"/blob/", good, "/raw/"}, context.temp_allocator),
		strings.concatenate({"/blob/", good, "/raw/extra"}, context.temp_allocator),
		strings.concatenate({"/blob/", good, "?x=1"}, context.temp_allocator),
		strings.concatenate({"/blob/", good, "/raw?x=1"}, context.temp_allocator),
		strings.concatenate({"/blob/", short63, "/raw"}, context.temp_allocator),
		strings.concatenate({"/realisation/", short63}, context.temp_allocator),
		strings.concatenate({"/realisation/", upper}, context.temp_allocator),
		strings.concatenate({"/realisation/", good, "/"}, context.temp_allocator),
		strings.concatenate({"/realisation/", good, "?x=1"}, context.temp_allocator),
		"/releases/",
		"/releases?page=2",
		"/search/",
		"/search?",
		"/search?q=ab",
		"/search?h=ab&x=1",
	}
	for target in bad_targets {
		_, ok := status_target_parse(target)
		testing.expectf(t, !ok, "target %q must be refused", target)
	}

	// Accepted forms.
	req, ok := status_target_parse(strings.concatenate({"/tree/", good}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Tree)
	testing.expect_value(t, req.page, 1)

	req, ok = status_target_parse(strings.concatenate({"/tree/", good, "?page=6"}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Tree)
	testing.expect_value(t, req.page, 6)

	req, ok = status_target_parse(strings.concatenate({"/blob/", good}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Blob)

	req, ok = status_target_parse(strings.concatenate({"/blob/", good, "/raw"}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Blob_Raw)

	req, ok = status_target_parse(strings.concatenate({"/realisation/", good}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Realisation)

	req, ok = status_target_parse("/releases")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Releases)

	req, ok = status_target_parse("/search")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Search)
	testing.expect_value(t, req.prefix_state, Search_Prefix_State.None)

	req, ok = status_target_parse("/search?h=")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Search)
	testing.expect_value(t, req.prefix_state, Search_Prefix_State.None)

	req, ok = status_target_parse("/search?h=0a9f")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, Status_Path.Search)
	testing.expect_value(t, req.prefix_state, Search_Prefix_State.Valid)
	testing.expect_value(t, req.prefix.count, 4)
	testing.expect_value(t, req.prefix.digits[0], u8(0))
	testing.expect_value(t, req.prefix.digits[1], u8(10))
	testing.expect_value(t, req.prefix.digits[2], u8(9))
	testing.expect_value(t, req.prefix.digits[3], u8(15))

	// Refused prefix values stay on /search with .Refused (no echo).
	for refused_q in ([?]string{"/search?h=ABC", "/search?h=<script>", strings.concatenate({"/search?h=", long65}, context.temp_allocator)}) {
		r, rok := status_target_parse(refused_q)
		testing.expect(t, rok)
		testing.expect_value(t, r.path, Status_Path.Search)
		testing.expect_value(t, r.prefix_state, Search_Prefix_State.Refused)
	}
}

// Tree pages: absent, empty, HTML in entry name, 512-entry paging, damaged
// bytes on disk, and wrong-kind redirect page.
@(test)
browse_tree_pages_escaping_damage_and_wrong_kind :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	private_key, public_key, _ := make_test_keypair(0x51)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	server, opened := cache_server_open(dir, authorized[:])
	testing.expect(t, opened)
	defer cache_server_destroy(&server)
	settings := Cache_Page_Settings{endpoint = "cache.example:5010", site_address = DEFAULT_SITE_ADDRESS}

	// Absent tree -> 404 HTML page.
	missing_hash := blake3.hash(transmute([]u8)string("absent tree"))
	absent_ans := cache_browse_tree(&server, settings, missing_hash, 1)
	testing.expect_value(t, absent_ans.status, Status_Answer.Not_Found)
	testing.expect(t, strings.contains(string(absent_ans.body), "Tree not found"))

	// Empty tree -> 200 on page 1, 404 on page 2.
	empty_buf: [tree_hash.HEADER_SIZE]u8
	_, empty_ref := tree_hash.tree_encode(nil, empty_buf[:])
	testing.expect_value(t, empty_ref, tree_hash.Tree_Refusal.None)
	empty_hash, _ := tree_hash.tree_hash(empty_buf[:])
	put_empty := make_signed_put_object_request(.Tree, empty_hash, empty_buf[:], &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_empty), object_cache.Cache_Response_Status.Ok)
	empty_p1 := cache_browse_tree(&server, settings, empty_hash, 1)
	testing.expect_value(t, empty_p1.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(empty_p1.body), "no entries"))
	empty_p2 := cache_browse_tree(&server, settings, empty_hash, 2)
	testing.expect_value(t, empty_p2.status, Status_Answer.Not_Found)

	// Put one held blob, and build a tree with HTML in a name plus an absent entry.
	held_payload := transmute([]u8)string("held blob bytes")
	held_hash := blake3.hash(held_payload)
	put_held := make_signed_put_object_request(.Blob, held_hash, held_payload, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_held), object_cache.Cache_Response_Status.Ok)

	unheld_hash := blake3.hash(transmute([]u8)string("not uploaded"))
	e1, _ := tree_hash.tree_entry_make(.Object, "<script>alert(1)</script>", held_hash)
	e2, _ := tree_hash.tree_entry_make(.Object, "absent_file", unheld_hash)
	entries2 := [2]tree_hash.Tree_Entry{e1, e2}
	tree2_buf := make([]u8, tree_hash.tree_encoded_size(2), context.temp_allocator)
	_, t2_ref := tree_hash.tree_encode(entries2[:], tree2_buf)
	testing.expect_value(t, t2_ref, tree_hash.Tree_Refusal.None)
	tree2_hash, _ := tree_hash.tree_hash(tree2_buf)
	put_tree2 := make_signed_put_object_request(.Tree, tree2_hash, tree2_buf, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_tree2), object_cache.Cache_Response_Status.Ok)

	tree2_ans := cache_browse_tree(&server, settings, tree2_hash, 1)
	testing.expect_value(t, tree2_ans.status, Status_Answer.Ok)
	tree2_html := string(tree2_ans.body)
	testing.expect(t, !strings.contains(tree2_html, "<script>"))
	testing.expect(t, strings.contains(tree2_html, "&lt;script&gt;alert(1)&lt;/script&gt;"))
	held_hex := hash_to_hex(held_hash)
	unheld_hex := hash_to_hex(unheld_hash)
	testing.expect(t, strings.contains(tree2_html, strings.concatenate({"/blob/", string(held_hex[:])}, context.temp_allocator)))
	testing.expect(t, strings.contains(tree2_html, "not held"))
	testing.expect(t, !strings.contains(tree2_html, strings.concatenate({"/blob/", string(unheld_hex[:])}, context.temp_allocator)))

	// Huge tree: 512 entries (MAX_TREE_ENTRIES) -> 6 pages, page 7 is 404.
	big_entries := make([]tree_hash.Tree_Entry, tree_hash.MAX_TREE_ENTRIES, context.temp_allocator)
	for idx in 0 ..< tree_hash.MAX_TREE_ENTRIES {
		name := fmt.tprintf("entry_%03d", idx)
		big_entries[idx], _ = tree_hash.tree_entry_make(.Object, name, held_hash)
	}
	big_buf := make([]u8, tree_hash.tree_encoded_size(tree_hash.MAX_TREE_ENTRIES), context.temp_allocator)
	_, big_ref := tree_hash.tree_encode(big_entries, big_buf)
	testing.expect_value(t, big_ref, tree_hash.Tree_Refusal.None)
	big_hash, _ := tree_hash.tree_hash(big_buf)
	put_big := make_signed_put_object_request(.Tree, big_hash, big_buf, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_big), object_cache.Cache_Response_Status.Ok)

	big_p1 := cache_browse_tree(&server, settings, big_hash, 1)
	testing.expect_value(t, big_p1.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(big_p1.body), "entry_000"))
	testing.expect(t, strings.contains(string(big_p1.body), "entry_099"))
	testing.expect(t, !strings.contains(string(big_p1.body), "entry_100"))
	testing.expect(t, strings.contains(string(big_p1.body), "Page 1 of 6"))
	testing.expect(t, strings.contains(string(big_p1.body), "?page=2"))
	testing.expect(t, !strings.contains(string(big_p1.body), "Previous page"))

	big_p2 := cache_browse_tree(&server, settings, big_hash, 2)
	testing.expect_value(t, big_p2.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(big_p2.body), "entry_100"))
	testing.expect(t, strings.contains(string(big_p2.body), "Previous page"))
	testing.expect(t, !strings.contains(string(big_p2.body), "?page=1"))

	big_p6 := cache_browse_tree(&server, settings, big_hash, 6)
	testing.expect_value(t, big_p6.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(big_p6.body), "entry_500"))
	testing.expect(t, strings.contains(string(big_p6.body), "entry_511"))
	testing.expect(t, !strings.contains(string(big_p6.body), "Next page"))

	big_p7 := cache_browse_tree(&server, settings, big_hash, 7)
	testing.expect_value(t, big_p7.status, Status_Answer.Not_Found)

	// Wrong kind: /tree/<blob hash> links to /blob/<blob hash>.
	wrong_kind := cache_browse_tree(&server, settings, held_hash, 1)
	testing.expect_value(t, wrong_kind.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(wrong_kind.body), "Blob, not a tree"))
	testing.expect(t, strings.contains(string(wrong_kind.body), strings.concatenate({"/blob/", string(held_hex[:])}, context.temp_allocator)))

	// Mutate tree2 on disk -> damaged page shows none of its bytes.
	t2_hex := hash_to_hex(tree2_hash)
	t2_path, _ := store_path_for_hex(dir, .Objects, string(t2_hex[:]))
	tree2_buf[len(tree2_buf) - 1] ~= 0xFF
	testing.expect_value(t, os.write_entire_file(t2_path, tree2_buf), nil)
	damaged_ans := cache_browse_tree(&server, settings, tree2_hash, 1)
	testing.expect_value(t, damaged_ans.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(damaged_ans.body), "damaged"))
	testing.expect(t, !strings.contains(string(damaged_ans.body), "absent_file"))
}

// Blob pages and /raw: valid module, unparseable module, PNG, UTF-8 text (with
// HTML and multi-byte truncation), control bytes -> hex, empty blob, damaged
// blob, and wrong kind (/blob/<tree>).
@(test)
browse_blob_kinds_module_preview_raw_and_damage :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	private_key, public_key, _ := make_test_keypair(0x52)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	server, opened := cache_server_open(dir, authorized[:])
	testing.expect(t, opened)
	defer cache_server_destroy(&server)
	settings := Cache_Page_Settings{endpoint = "cache.example:5010", site_address = DEFAULT_SITE_ADDRESS}

	put_blob :: proc(t: ^testing.T, server: ^Cache_Server, key: ^ed25519.Private_Key, pub: [32]u8, payload: []u8) -> blake3.Hash {
		h := blake3.hash(payload)
		req := make_signed_put_object_request(.Blob, h, payload, key, pub)
		testing.expect_value(t, put_frame(t, server, &req), object_cache.Cache_Response_Status.Ok)
		return h
	}

	// 1. Valid modus module.
	mod_bytes := make_minimal_valid_module()
	testing.expect_value(t, module.validate(mod_bytes), module.Error.None)
	mod_hash := put_blob(t, &server, &private_key, public_key, mod_bytes)
	mod_page := cache_browse_blob(&server, settings, mod_hash)
	testing.expect_value(t, mod_page.status, Status_Answer.Ok)
	mod_html := string(mod_page.body)
	testing.expect(t, strings.contains(mod_html, "modus module"))
	testing.expect(t, strings.contains(mod_html, "Sample library module."))
	testing.expect(t, strings.contains(mod_html, "16 pages"))
	testing.expect(t, strings.contains(mod_html, "hello(count: Integer) -&gt; Text"))
	testing.expect(t, strings.contains(mod_html, "Returns a greeting for &lt;reader&gt;."))
	mod_raw := cache_browse_blob_raw(&server, mod_hash)
	testing.expect_value(t, mod_raw.status, Status_Answer.Ok)
	testing.expect_value(t, mod_raw.content_type, "application/octet-stream")
	testing.expect(t, strings.contains(mod_raw.content_disposition, ".module\""))
	testing.expect_value(t, mod_raw.security_policy, "default-src 'none'; sandbox")

	// 2. Module that does not parse.
	bad_mod := [16]u8{'M', 'O', 'D', 'U', 'L', 'E', 0, 0, 99, 0, 0, 0, 0, 0, 0, 0}
	bad_mod_hash := put_blob(t, &server, &private_key, public_key, bad_mod[:])
	bad_mod_page := cache_browse_blob(&server, settings, bad_mod_hash)
	testing.expect_value(t, bad_mod_page.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(bad_mod_page.body), "validation refused it"))
	testing.expect(t, strings.contains(string(bad_mod_page.body), "No module metadata is shown"))

	// 3. PNG image.
	png_bytes := [16]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 'I', 'E', 'N', 'D'}
	png_hash := put_blob(t, &server, &private_key, public_key, png_bytes[:])
	png_page := cache_browse_blob(&server, settings, png_hash)
	testing.expect_value(t, png_page.status, Status_Answer.Ok)
	png_hex := hash_to_hex(png_hash)
	testing.expect(t, strings.contains(string(png_page.body), strings.concatenate({"<img class=\"blob-image\" src=\"/blob/", string(png_hex[:]), "/raw\""}, context.temp_allocator)))
	png_raw := cache_browse_blob_raw(&server, png_hash)
	testing.expect_value(t, png_raw.status, Status_Answer.Ok)
	testing.expect_value(t, png_raw.content_type, "image/png")
	testing.expect(t, strings.contains(png_raw.content_disposition, ".png\""))

	// 4. UTF-8 text with HTML + long text straddling BROWSE_TEXT_PREVIEW_BYTES.
	text_html_payload := transmute([]u8)string("<b>hello & world</b>\n\tsecond line\n")
	text_hash := put_blob(t, &server, &private_key, public_key, text_html_payload)
	text_page := cache_browse_blob(&server, settings, text_hash)
	testing.expect_value(t, text_page.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(text_page.body), "&lt;b&gt;hello &amp; world&lt;/b&gt;"))
	testing.expect(t, !strings.contains(string(text_page.body), "<b>hello"))
	text_raw := cache_browse_blob_raw(&server, text_hash)
	testing.expect_value(t, text_raw.status, Status_Answer.Ok)
	testing.expect_value(t, text_raw.content_type, "text/plain; charset=utf-8")
	testing.expect_value(t, text_raw.security_policy, "default-src 'none'; sandbox")

	// Multi-byte UTF-8 character ('é' = 2 bytes) straddling byte 4096.
	long_text := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< BROWSE_TEXT_PREVIEW_BYTES - 1 {
		strings.write_byte(&long_text, 'a')
	}
	strings.write_string(&long_text, "éend")
	long_hash := put_blob(t, &server, &private_key, public_key, transmute([]u8)strings.to_string(long_text))
	long_page := cache_browse_blob(&server, settings, long_hash)
	testing.expect_value(t, long_page.status, Status_Answer.Ok)
	testing.expect(t, utf8.valid_string(string(long_page.body)))
	testing.expect(t, strings.contains(string(long_page.body), "Showing the first 4095 of"))

	// 5. Text with control bytes -> NOT text, hex preview, octet-stream.
	for ctrl in ([3][]u8{transmute([]u8)string("hello\x07world"), transmute([]u8)string("hello\x00world"), transmute([]u8)string("hello\x7fworld")}) {
		ch := put_blob(t, &server, &private_key, public_key, ctrl)
		cp := cache_browse_blob(&server, settings, ch)
		testing.expect_value(t, cp.status, Status_Answer.Ok)
		testing.expect(t, strings.contains(string(cp.body), "<dt>Detected kind</dt><dd>bytes</dd>"))
		testing.expect(t, strings.contains(string(cp.body), "0000  68 65 6c 6c 6f"))
		cr := cache_browse_blob_raw(&server, ch)
		testing.expect_value(t, cr.content_type, "application/octet-stream")
	}

	// 6. Damaged blob: mutate on disk -> page says damaged, /raw returns 404.
	text_hex := hash_to_hex(text_hash)
	text_path, _ := store_path_for_hex(dir, .Objects, string(text_hex[:]))
	testing.expect_value(t, os.write_entire_file(text_path, transmute([]u8)string("tampered secret payload")), nil)
	dmg_page := cache_browse_blob(&server, settings, text_hash)
	testing.expect_value(t, dmg_page.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(dmg_page.body), "damaged"))
	testing.expect(t, !strings.contains(string(dmg_page.body), "tampered secret"))
	dmg_raw := cache_browse_blob_raw(&server, text_hash)
	testing.expect_value(t, dmg_raw.status, Status_Answer.Not_Found)
	testing.expect_value(t, len(dmg_raw.body), 0)

	// 7. Wrong kind: /blob/<tree> links to /tree/<tree>, /raw is 404.
	empty_tree: [tree_hash.HEADER_SIZE]u8
	_, _ = tree_hash.tree_encode(nil, empty_tree[:])
	th, _ := tree_hash.tree_hash(empty_tree[:])
	put_t := make_signed_put_object_request(.Tree, th, empty_tree[:], &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_t), object_cache.Cache_Response_Status.Ok)
	wrong := cache_browse_blob(&server, settings, th)
	testing.expect_value(t, wrong.status, Status_Answer.Ok)
	testing.expect(t, strings.contains(string(wrong.body), "Tree, not a blob"))
	wrong_raw := cache_browse_blob_raw(&server, th)
	testing.expect_value(t, wrong_raw.status, Status_Answer.Not_Found)
}

// Realisation page: with indexed recipe object, without recipe object,
// unauthorised signer, bad signature, damaged realisation, and damaged recipe.
@(test)
browse_realisation_with_and_without_recipe_and_signature_states :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	private_key, public_key, _ := make_test_keypair(0x53)
	stranger_key, stranger_pub, _ := make_test_keypair(0x54)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	server, opened := cache_server_open(dir, authorized[:])
	testing.expect(t, opened)
	defer cache_server_destroy(&server)
	settings := Cache_Page_Settings{endpoint = "cache.example:5010", site_address = DEFAULT_SITE_ADDRESS}

	// Absent realisation -> 404.
	absent := cache_browse_realisation(&server, settings, blake3.hash(transmute([]u8)string("missing")))
	testing.expect_value(t, absent.status, Status_Answer.Not_Found)

	// Put input, recipe object (auto-indexed into recipes/), output, and realisation.
	input_bytes := transmute([]u8)string("recipe input bytes")
	input_hash := blake3.hash(input_bytes)
	put_in := make_signed_put_object_request(.Blob, input_hash, input_bytes, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_in), object_cache.Cache_Response_Status.Ok)

	output_bytes := transmute([]u8)string("recipe output bytes")
	output_hash := blake3.hash(output_bytes)
	put_out := make_signed_put_object_request(.Blob, output_hash, output_bytes, &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_out), object_cache.Cache_Response_Status.Ok)

	spec := new(plans_recipes.Recipe_Spec, context.temp_allocator)
	spec.builder_hash = blake3.hash(transmute([]u8)string("builder"))
	spec.output_kind = .Blob
	spec.source_date_unix = 1_700_000_000
	spec.output_block_limit = 32
	spec.inputs[0], _ = plans_recipes.recipe_input_make("src_in", .Blob, input_hash)
	spec.input_count = 1
	copy(spec.arguments[:], "arg1")
	spec.arguments_length = 4
	recipe_digest, _ := plans_recipes.recipe_hash(spec)

	recipe_buf: [plans_recipes.MAX_RECIPE_OBJECT_BYTES]u8
	recipe_len, _ := plans_recipes.recipe_object_encode(spec, recipe_buf[:])
	recipe_blob_hash := blake3.hash(recipe_buf[:recipe_len])
	put_rcp := make_signed_put_object_request(.Blob, recipe_blob_hash, recipe_buf[:recipe_len], &private_key, public_key)
	testing.expect_value(t, put_frame(t, &server, &put_rcp), object_cache.Cache_Response_Status.Ok)

	record := make_signed_realisation_record(recipe_digest, output_hash, .Blob, &private_key, public_key)
	put_real := object_cache.Cache_Request{kind = .Put_Realisation, realisation = record}
	testing.expect_value(t, put_frame(t, &server, &put_real), object_cache.Cache_Response_Status.Ok)

	page := cache_browse_realisation(&server, settings, recipe_digest)
	testing.expect_value(t, page.status, Status_Answer.Ok)
	html := string(page.body)
	in_hex := hash_to_hex(input_hash)
	out_hex := hash_to_hex(output_hash)
	testing.expect(t, strings.contains(html, "Verified by this host against the signer key above, which is an authorised upload key"))
	testing.expect(t, strings.contains(html, strings.concatenate({"/blob/", string(out_hex[:])}, context.temp_allocator)))
	testing.expect(t, strings.contains(html, "src_in"))
	testing.expect(t, strings.contains(html, strings.concatenate({"/blob/", string(in_hex[:])}, context.temp_allocator)))
	testing.expect(t, strings.contains(html, "1700000000"))

	// Corrupt the recipe file on disk -> recipe section says damaged and hides bytes.
	rcp_hex := hash_to_hex(recipe_digest)
	rcp_path, _ := store_path_for_hex(dir, .Recipes, string(rcp_hex[:]))
	testing.expect_value(t, os.write_entire_file(rcp_path, transmute([]u8)string("corrupt recipe")), nil)
	corrupt_rcp_page := cache_browse_realisation(&server, settings, recipe_digest)
	testing.expect(t, strings.contains(string(corrupt_rcp_page.body), "recipe object stored for this hash is damaged"))
	testing.expect(t, !strings.contains(string(corrupt_rcp_page.body), "src_in"))

	// Realisation without a recipe object, signed by an unauthorised key on disk.
	r2_hash := blake3.hash(transmute([]u8)string("recipe without object"))
	r2_rec := make_signed_realisation_record(r2_hash, output_hash, .Blob, &stranger_key, stranger_pub)
	r2_wire: [object_cache.REALISATION_WIRE_SIZE]u8
	_, _ = object_cache.encode_realisation_record(&r2_rec, r2_wire[:])
	r2_hex := hash_to_hex(r2_hash)
	r2_path, _ := store_path_for_hex(dir, .Realisations, string(r2_hex[:]))
	testing.expect_value(t, os.write_entire_file(r2_path, r2_wire[:]), nil)
	unauth_page := cache_browse_realisation(&server, settings, r2_hash)
	testing.expect(t, strings.contains(string(unauth_page.body), "not in the authorised upload keys"))
	testing.expect(t, strings.contains(string(unauth_page.body), "not the recipe object"))

	// Flip a signature byte on disk -> signature check did not pass.
	r2_wire[object_cache.REALISATION_WIRE_SIZE - 1] ~= 0x01
	testing.expect_value(t, os.write_entire_file(r2_path, r2_wire[:]), nil)
	bad_sig_page := cache_browse_realisation(&server, settings, r2_hash)
	testing.expect(t, strings.contains(string(bad_sig_page.body), "Signature check did not pass"))

	// Truncate the realisation file on disk -> damaged realisation page.
	testing.expect_value(t, os.write_entire_file(r2_path, r2_wire[:20]), nil)
	dmg_real_page := cache_browse_realisation(&server, settings, r2_hash)
	testing.expect(t, strings.contains(string(dmg_real_page.body), "Damaged realisation"))
}

// Release pointers (protocol, monotonicity, restart rescan, /releases page) and
// bounded prefix search + end-to-end HTTP loopback checks.
@(test)
browse_releases_protocol_search_and_http :: proc(t: ^testing.T) {
	private_key, public_key, _ := make_test_keypair(0x55)
	stranger_key, _, _ := make_test_keypair(0x56)
	authorized := [1][object_cache.PUBLIC_KEY_SIZE]u8{public_key}
	test := status_test_start(t, authorized[:])
	defer status_test_stop(test)

	// Put a tree so /releases links to it.
	tbuf: [tree_hash.HEADER_SIZE]u8
	_, _ = tree_hash.tree_encode(nil, tbuf[:])
	t_hash, _ := tree_hash.tree_hash(tbuf[:])
	put_t := make_signed_put_object_request(.Tree, t_hash, tbuf[:], &private_key, public_key)
	testing.expect_value(t, put_frame(t, &test.server, &put_t), object_cache.Cache_Response_Status.Ok)

	// Unauthorised publisher refused.
	stranger_ptr, _ := cache_client_release_pointer_sign(&stranger_key, "release", 1, t_hash)
	put_stranger := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = stranger_ptr}
	testing.expect_value(t, put_frame(t, &test.server, &put_stranger), object_cache.Cache_Response_Status.Unauthorized)

	// Bad signature refused.
	p10, _ := cache_client_release_pointer_sign(&private_key, "release", 10, t_hash)
	bad_sig := p10
	bad_sig.signature[0] ~= 0x01
	put_bad := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = bad_sig}
	testing.expect_value(t, put_frame(t, &test.server, &put_bad), object_cache.Cache_Response_Status.Bad_Signature)

	// Put number 10 -> Ok; exact repeat -> Ok; lower (9) -> Refused; same number different tree -> Refused; higher (11) -> Ok.
	put_10 := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = p10}
	testing.expect_value(t, put_frame(t, &test.server, &put_10), object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, put_frame(t, &test.server, &put_10), object_cache.Cache_Response_Status.Ok)

	p9, _ := cache_client_release_pointer_sign(&private_key, "release", 9, t_hash)
	put_9 := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = p9}
	testing.expect_value(t, put_frame(t, &test.server, &put_9), object_cache.Cache_Response_Status.Refused)

	other_tree := blake3.hash(transmute([]u8)string("other tree"))
	p10_other, _ := cache_client_release_pointer_sign(&private_key, "release", 10, other_tree)
	put_10_other := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = p10_other}
	testing.expect_value(t, put_frame(t, &test.server, &put_10_other), object_cache.Cache_Response_Status.Refused)

	p11, _ := cache_client_release_pointer_sign(&private_key, "release", 11, other_tree)
	put_11 := object_cache.Cache_Request{kind = .Put_Release_Pointer, release_pointer = p11}
	testing.expect_value(t, put_frame(t, &test.server, &put_11), object_cache.Cache_Response_Status.Ok)

	// Get_Release_Pointer returns 11.
	highest, found := cache_status_release_pointer_highest(&test.server.status, public_key, "release")
	testing.expect(t, found)
	testing.expect_value(t, highest.number, u64(11))

	// HTTP /releases shows both 11 and 10 and links the held tree.
	rel_ans := status_exchange(t, test, head_bytes("GET /releases HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(rel_ans), "HTTP/1.1 200 OK")
	rel_body := answer_body(rel_ans)
	t_hex := hash_to_hex(t_hash)
	testing.expect(t, strings.contains(rel_body, strings.concatenate({"/tree/", string(t_hex[:])}, context.temp_allocator)))
	testing.expect(t, strings.contains(rel_body, ">11<"))
	testing.expect(t, strings.contains(rel_body, ">10<"))

	// HTTP /search with matching prefix finds the tree with a /tree/ link.
	search_req := fmt.tprintf("GET /search?h=%s HTTP/1.1\r\n\r\n", string(t_hex[:8]))
	search_ans := status_exchange(t, test, head_bytes(search_req))
	testing.expect_value(t, answer_line(search_ans), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer_body(search_ans), strings.concatenate({"/tree/", string(t_hex[:])}, context.temp_allocator)))

	// HTTP /search with refused prefix does not echo the input.
	bad_search := status_exchange(t, test, head_bytes("GET /search?h=ZZZ_NO_ECHO HTTP/1.1\r\n\r\n"))
	testing.expect_value(t, answer_line(bad_search), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(answer_body(bad_search), "lowercase hexadecimal digits"))
	testing.expect(t, !strings.contains(answer_body(bad_search), "ZZZ_NO_ECHO"))

	// HTTP /tree/<t_hash> over loopback returns 200 OK.
	tree_req := fmt.tprintf("GET /tree/%s HTTP/1.1\r\n\r\n", string(t_hex[:]))
	tree_ans := status_exchange(t, test, head_bytes(tree_req))
	testing.expect_value(t, answer_line(tree_ans), "HTTP/1.1 200 OK")
	testing.expect(t, strings.contains(tree_ans, "img-src 'self'"))
	testing.expect(t, strings.contains(tree_ans, "form-action 'self'"))

	// Prefix search bound: insert 30 hashes sharing prefix 0xab -> returns 20 shown of 30 total.
	bound_status: Cache_Status
	defer cache_status_destroy(&bound_status)
	for index in 0 ..< 30 {
		h: blake3.Hash
		h[0] = 0xAB
		h[1] = u8(index)
		sorted_names_insert(&bound_status.object_names, h)
	}
	ab_prefix := Hash_Prefix{digits = {0 = 10, 1 = 11}, count = 2}
	bounded := cache_status_search(&bound_status, ab_prefix)
	testing.expect_value(t, bounded.object_count, 30)
	testing.expect_value(t, bounded.objects_shown, BROWSE_SEARCH_ROWS)

	// Release number parsing edges.
	num_ok_val, num_ok := release_number_value("0.97.0")
	testing.expect(t, num_ok)
	testing.expect_value(t, num_ok_val, u64(97_000))
	for bad_ver in ([?]string{"", "0.0.0", "0.1000.0", "0.0.1000", "01.0.0", "1.2", "1.2.3.4", "a.b.c"}) {
		_, ok_v := release_number_value(bad_ver)
		testing.expectf(t, !ok_v, "release number %q must be refused", bad_ver)
	}

	// Reopening the store rescans release_pointers/ and ignores a damaged file.
	dmg_ptr_path, _ := store_path_for_hex(test.directory, .Release_Pointers, "0000000000000000000000000000000000000000000000000000000000000001")
	testing.expect_value(t, os.write_entire_file(dmg_ptr_path, transmute([]u8)string("not a release pointer")), nil)
	reopened, reopen_ok := cache_server_open(test.directory, authorized[:])
	testing.expect(t, reopen_ok)
	defer cache_server_destroy(&reopened)
	reopen_rows := cache_status_release_rows(&reopened.status)
	testing.expect_value(t, reopen_rows.total, 2)
}
