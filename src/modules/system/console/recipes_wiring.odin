// Console wiring for recipes tree ingestion, project evaluation/building,
// provenance queries, and module delivery into module_files
// (src/md/features/recipes.md and src/md/features/application_projects.md).
//
// Exposes only dotted service commands (recipes.ingest_tree,
// recipes.build_project, recipes.provenance, recipes.deliver_module); no bare
// install command exists.
package console

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import module "modus:contract/module"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/release"
import "modus:contract/system_description"
import "modus:contract/tree_hash"
import "modus:disk_process"
import "modus:storage"
import "modus:system"

// Inline capacity / format bounds for console project ingestion and bundling.
// Format property: tree_hash allows at most 4096 entries per directory node.
RECIPES_INGEST_POOL_CAPACITY :: tree_hash.MAX_TREE_ENTRIES
// Format property: matches storage.freeze_tree maximum directory nesting depth.
RECIPES_TREE_DEPTH_MOST :: 32
// Inline capacity: one storage.list page per directory scan step.
RECIPES_LIST_PAGE_ROWS :: 64
RECIPES_LIST_PAGE_NAMES :: 4096
// Inline capacity for console project declaration_eval bundles.
RECIPES_BUNDLE_ENTRIES_MOST :: 64
RECIPES_BUNDLE_BYTES_MOST :: 256 * 1024
RECIPES_CATALOG_BYTES_MOST :: 64 * 1024
RECIPES_LEX_ARENA_BYTES :: 192 * 1024
// Format property: boot image holds at most 256 module entries.
RECIPES_CATALOG_MODULES_MOST :: 256
// Inline capacity for console declaration_eval output staging.
RECIPES_EVAL_OUTPUT_FIRST_PAGES :: 16
RECIPES_EVAL_OUTPUT_BYTES_MOST :: u64(256 * 1024)

@(private = "file")
recipes_entry_pool: [RECIPES_INGEST_POOL_CAPACITY]tree_hash.Tree_Entry
@(private = "file")
recipes_entry_pool_used: int

@(private = "file")
recipes_tree_encode_buf: [tree_hash.MAX_ENCODED_TREE_BYTES]u8
@(private = "file")
recipes_bundle_buf: [RECIPES_BUNDLE_BYTES_MOST]u8
@(private = "file")
recipes_catalog_buf: [RECIPES_CATALOG_BYTES_MOST]u8
@(private = "file")
recipes_lex_arena: [RECIPES_LEX_ARENA_BYTES]u8
@(private = "file")
recipes_bundle_entries: [RECIPES_BUNDLE_ENTRIES_MOST]declaration_eval.Bundle_Input_Entry

// recipes_build_mode_of_text parses the optional build mode text argument of
// recipes.build_project. Empty text selects Prefer_Cache.
recipes_build_mode_of_text :: proc "contextless" (text: string) -> (mode: pr.Build_Mode, ok: bool) {
	switch text {
	case "", "prefer_cache":
		return .Prefer_Cache, true
	case "build_only":
		return .Build_Only, true
	case "cache_only":
		return .Cache_Only, true
	case "verify":
		return .Verify, true
	}
	return .None, false
}

// recipes_storage_borrow ensures the console is connected to the storage
// service and returns a storage.Client view backed by that sandbox connection.
// Call recipes_storage_release after using the client to keep call tags in sync.
@(private = "file")
recipes_storage_borrow :: proc "contextless" () -> (client: storage.Client, sandbox: ^Sandbox, ok: bool) {
	for &item in sandboxes {
		if item.service && item.name == "storage" && item.process != 0 {
			sandbox = &item
			break
		}
	}
	if sandbox == nil {
		connect_args := [1]Value{{kind = .Text, text = "storage"}}
		_ = connect_service(connect_args[:])
		if failed {
			return {}, nil, false
		}
		for &item in sandboxes {
			if item.service && item.name == "storage" && item.process != 0 {
				sandbox = &item
				break
			}
		}
	}
	if sandbox == nil {
		_ = fail("recipes: the storage service is not connected")
		return {}, nil, false
	}
	storage_file, _, has_file := image_module_file("storage")
	if !has_file {
		_ = fail("recipes: the boot image has no module storage")
		return {}, nil, false
	}
	client = storage.Client {
		ring_memory   = sandbox.ring_memory,
		region_memory = sandbox.region_memory,
		service       = sandbox.process,
		calls         = sandbox.ring,
		region        = sandbox.region,
		file          = storage_file,
		tag           = sandbox.calls,
	}
	return client, sandbox, true
}

@(private = "file")
recipes_storage_sync :: proc "contextless" (client: ^storage.Client, sandbox: ^Sandbox) {
	if sandbox != nil {
		sandbox.calls = client.tag
	}
}

// recipes_put_memory_bytes uploads a byte slice into recipes via
// recipes.put_memory (enforcing principal quotas and the 75% retention guard)
// and verifies the returned content hash.
@(private = "file")
recipes_put_memory_bytes :: proc "contextless" (kind: object_cache.Cache_Object_Kind, data: []u8, expected_hash: blake3.Hash) -> bool {
	if len(data) == 0 {
		_ = fail("recipes: cannot ingest an empty object")
		return false
	}
	pages := (u64(len(data)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	mem, mem_ok := program_memory(pages, data)
	if !mem_ok {
		_ = fail("recipes: the budget of the console cannot pay for ", i64(pages * system.PAGE_SIZE), " bytes to ingest an object")
		return false
	}
	defer system.close(mem)
	args := [3]Value{
		{kind = .Integer, integer = i64(kind)},
		{kind = .Handle, integer = i64(mem)},
		{kind = .Integer, integer = i64(len(data))},
	}
	row_table := call_run("recipes.put_memory", args[:])
	if failed {
		return false
	}
	table, has_table := table_of(row_table)
	if !has_table || table.rows < 1 || len(row_table.record) < size_of(pr.Recipe_Reference) {
		_ = fail("recipes.put_memory: did not return a hash row")
		return false
	}
	ref := (^pr.Recipe_Reference)(raw_data(table_row(table, row_table, 0)))^
	if blake3.Hash(ref.recipe_hash) != expected_hash {
		_ = fail("recipes.put_memory: returned a different hash than the ingested bytes")
		return false
	}
	return true
}

// recipes_ingest_object reads one file object from a storage place into a lent
// memory object, hashes it, and uploads it into recipes via recipes.put_memory.
@(private = "file")
recipes_ingest_object :: proc "contextless" (client: ^storage.Client, sandbox: ^Sandbox, place: storage.Place, name: string) -> (digest: blake3.Hash, ok: bool) {
	size, sz_status := storage.size(client, place, name)
	recipes_storage_sync(client, sandbox)
	if sz_status != .Ok {
		_ = fail("recipes.ingest_tree: cannot read size of ", name)
		return {}, false
	}
	if size <= 0 {
		_ = fail("recipes.ingest_tree: the file ", name, " is empty; recipes does not accept 0-byte objects")
		return {}, false
	}
	if u64(size) > u64(pr.C_SOURCE_BYTES_LIMIT) {
		_ = fail("recipes.ingest_tree: the file ", name, " exceeds the 64 MiB ingestion bound")
		return {}, false
	}
	pages := (u64(size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	mem, mem_ok := program_memory(pages, nil)
	if !mem_ok {
		_ = fail("recipes.ingest_tree: the budget of the console cannot pay for ", size, " bytes for ", name)
		return {}, false
	}
	defer system.close(mem)
	addr, map_status := system.memory_map(mem, {.Write})
	if map_status != .Succeeded {
		_ = fail("recipes.ingest_tree: cannot map memory for ", name)
		return {}, false
	}
	defer system.memory_unmap(addr)

	dst := ([^]u8)(addr)[:size]
	offset: i64 = 0
	for offset < size {
		piece, rd_status := storage.read_range(client, place, name, u64(offset), dst[offset:])
		recipes_storage_sync(client, sandbox)
		if rd_status != .Ok || len(piece) == 0 {
			_ = fail("recipes.ingest_tree: cannot read ", name)
			return {}, false
		}
		offset += i64(len(piece))
	}
	digest = blake3.hash(dst)

	args := [3]Value{
		{kind = .Integer, integer = i64(object_cache.Cache_Object_Kind.Blob)},
		{kind = .Handle, integer = i64(mem)},
		{kind = .Integer, integer = size},
	}
	row_table := call_run("recipes.put_memory", args[:])
	if failed {
		return {}, false
	}
	table, has_table := table_of(row_table)
	if !has_table || table.rows < 1 || len(row_table.record) < size_of(pr.Recipe_Reference) {
		_ = fail("recipes.put_memory: did not return a hash row for ", name)
		return {}, false
	}
	ref := (^pr.Recipe_Reference)(raw_data(table_row(table, row_table, 0)))^
	if blake3.Hash(ref.recipe_hash) != digest {
		_ = fail("recipes.put_memory: hash mismatch for ", name)
		return {}, false
	}
	return digest, true
}

// recipes_ingest_place recursively walks a storage tree in ascending byte
// order, uploads each leaf object and canonical MODTREE2 node into recipes
// through recipes.put_memory, and returns the canonical tree hash.
@(private = "file")
recipes_ingest_place :: proc "contextless" (client: ^storage.Client, sandbox: ^Sandbox, place: storage.Place, depth: int) -> (root_hash: blake3.Hash, ok: bool) {
	if depth > RECIPES_TREE_DEPTH_MOST {
		_ = fail("recipes.ingest_tree: directory nesting exceeds ", i64(RECIPES_TREE_DEPTH_MOST), " levels")
		return {}, false
	}
	base := recipes_entry_pool_used
	defer recipes_entry_pool_used = base

	rows: [RECIPES_LIST_PAGE_ROWS]storage.Listed
	names: [RECIPES_LIST_PAGE_NAMES]u8
	after_buf: [tree_hash.ENTRY_NAME_CAPACITY]u8
	after_len := 0

	// First pass: collect sorted entries of this directory into the flat pool
	// so recursive subtrees cannot alias the current directory's slice.
	for {
		page, list_status := storage.list(client, place, string(after_buf[:after_len]), rows[:], names[:])
		recipes_storage_sync(client, sandbox)
		if list_status != .Ok {
			_ = fail("recipes.ingest_tree: cannot list entries of the store")
			return {}, false
		}
		if len(page) == 0 {
			break
		}
		for row in page {
			if row.name_offset < 0 || row.name_count <= 0 || row.name_offset + row.name_count > i64(len(names)) {
				_ = fail("recipes.ingest_tree: storage returned an out-of-range entry name")
				return {}, false
			}
			entry_name := string(names[row.name_offset : row.name_offset + row.name_count])
			entry_kind, kind_ok := storage.entry_kind_of_word(row.kind)
			if !kind_ok {
				_ = fail("recipes.ingest_tree: storage returned an unknown entry kind")
				return {}, false
			}
			if recipes_entry_pool_used >= RECIPES_INGEST_POOL_CAPACITY {
				_ = fail("recipes.ingest_tree: tree exceeds ", i64(RECIPES_INGEST_POOL_CAPACITY), " entries")
				return {}, false
			}
			t_kind: tree_hash.Tree_Entry_Kind
			switch entry_kind {
			case .Object:
				t_kind = .Object
			case .Tree:
				t_kind = .Tree
			case .Release:
				_ = fail("recipes.ingest_tree: release entries are not supported in source trees")
				return {}, false
			case .None:
				_ = fail("recipes.ingest_tree: storage returned entry kind None")
				return {}, false
			}
			entry, make_ref := tree_hash.tree_entry_make(t_kind, entry_name, {})
			if make_ref != .None {
				_ = fail("recipes.ingest_tree: entry name ", entry_name, " is refused by tree_hash")
				return {}, false
			}
			recipes_entry_pool[recipes_entry_pool_used] = entry
			recipes_entry_pool_used += 1

			if len(entry_name) > len(after_buf) {
				_ = fail("recipes.ingest_tree: entry name exceeds bound")
				return {}, false
			}
			copy(after_buf[:], entry_name)
			after_len = len(entry_name)
		}
	}

	local_end := recipes_entry_pool_used
	for index in base ..< local_end {
		entry := &recipes_entry_pool[index]
		name := string(entry.name[:entry.name_length])
		switch entry.kind {
		case .Object:
			digest, obj_ok := recipes_ingest_object(client, sandbox, place, name)
			if !obj_ok {
				return {}, false
			}
			entry.hash = digest
		case .Tree:
			sub_place, open_status := storage.open_tree(client, place, name)
			recipes_storage_sync(client, sandbox)
			if open_status != .Ok {
				_ = fail("recipes.ingest_tree: cannot open subtree ", name)
				return {}, false
			}
			sub_hash, sub_ok := recipes_ingest_place(client, sandbox, sub_place, depth + 1)
			_ = storage.close_tree(client, sub_place)
			recipes_storage_sync(client, sandbox)
			if !sub_ok {
				return {}, false
			}
			entry.hash = sub_hash
		case .Part:
			_ = fail("recipes.ingest_tree: unexpected Part entry")
			return {}, false
		}
	}

	written, enc_ref := tree_hash.tree_encode(recipes_entry_pool[base:local_end], recipes_tree_encode_buf[:])
	if enc_ref != .None {
		_ = fail("recipes.ingest_tree: cannot encode canonical tree node")
		return {}, false
	}
	tree_digest, hash_ref := tree_hash.tree_hash(recipes_tree_encode_buf[:written])
	if hash_ref != .None {
		_ = fail("recipes.ingest_tree: cannot hash canonical tree node")
		return {}, false
	}
	if !recipes_put_memory_bytes(.Tree, recipes_tree_encode_buf[:written], tree_digest) {
		return {}, false
	}
	return tree_digest, true
}

// recipes_ingest_store opens the named store of the principal and ingests its
// complete directory tree into recipes's content-addressed object store.
@(private = "file")
recipes_ingest_store :: proc "contextless" (store_name: string) -> (here_hash: blake3.Hash, ok: bool) {
	if len(store_name) == 0 {
		_ = fail("recipes.ingest_tree: the store name is empty")
		return {}, false
	}
	client, sandbox, borrowed := recipes_storage_borrow()
	if !borrowed {
		return {}, false
	}
	root_place, open_status := storage.open_store(&client, store_name)
	recipes_storage_sync(&client, sandbox)
	if open_status != .Ok {
		_ = fail("recipes.ingest_tree: cannot open store ", store_name)
		return {}, false
	}
	defer {
		_ = storage.close_tree(&client, root_place)
		recipes_storage_sync(&client, sandbox)
	}
	return recipes_ingest_place(&client, sandbox, root_place, 0)
}

// recipes_ingest_tree_command runs recipes.ingest_tree(store_name) and returns
// the 64-hex canonical BLAKE3 tree hash for here().
recipes_ingest_tree_command :: proc "contextless" (arguments: []Value) -> Value {
	here_hash, ok := recipes_ingest_store(arguments[0].text)
	if !ok {
		return {}
	}
	return {kind = .Text, text = hex_text(here_hash[:])}
}

// recipes_catalog_generate renders the canonical catalog.lex declaration from
// the live boot image (matching tools/modustool/build/system_catalog.odin).
@(private = "file")
recipes_catalog_generate :: proc "contextless" (dst: []u8) -> (text: string, ok: bool) {
	entries := system.image_entries(image)
	if len(entries) == 0 || len(entries) > RECIPES_CATALOG_MODULES_MOST {
		_ = fail("recipes.build_project: the boot image has no module catalog")
		return "", false
	}
	order: [RECIPES_CATALOG_MODULES_MOST]int
	count := len(entries)
	for i in 0 ..< count {
		order[i] = i
	}
	// Deterministic ascending byte-order sort by module name.
	for i in 1 ..< count {
		key := order[i]
		key_name := system_description.name_of(&entries[key].name)
		j := i - 1
		for j >= 0 && system_description.name_of(&entries[order[j]].name) > key_name {
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key
	}

	c_builder_hash, c_compiler_hash, assemble_hash, host_hash: blake3.Hash
	has_c_builder, has_c_compiler, has_assemble, has_host: bool
	for i in 0 ..< count {
		entry := &entries[order[i]]
		name := system_description.name_of(&entry.name)
		switch name {
		case "c_builder":
			c_builder_hash = entry.hash
			has_c_builder = true
		case "c_compiler":
			c_compiler_hash = entry.hash
			has_c_compiler = true
		case "assemble":
			assemble_hash = entry.hash
			has_assemble = true
		case "host":
			host_hash = entry.hash
			has_host = true
		}
	}
	if !has_c_builder || !has_c_compiler || !has_assemble || !has_host {
		_ = fail("recipes.build_project: the boot image lacks c_builder, c_compiler, assemble, or host")
		return "", false
	}

	writer := system.Writer{buffer = dst}
	system.write_part(&writer, "// Catalog declaration of modus ")
	system.write_part(&writer, release.RELEASE_NUMBER)
	system.write_part(&writer, ".\n{\n  release = \"")
	system.write_part(&writer, release.RELEASE_NUMBER)
	system.write_part(&writer, "\",\n  modules = {\n")
	hex_buf: [64]u8
	for i in 0 ..< count {
		entry := &entries[order[i]]
		name := system_description.name_of(&entry.name)
		disk_process.hash_write(&hex_buf, entry.hash)
		system.write_part(&writer, "    ")
		system.write_part(&writer, name)
		system.write_part(&writer, " = module(blake3:")
		system.write_part(&writer, string(hex_buf[:]))
		system.write_part(&writer, "),\n")
	}
	system.write_part(&writer, "  },\n  c = {\n    builder = module(blake3:")
	disk_process.hash_write(&hex_buf, c_builder_hash)
	cb_hex := hex_buf
	system.write_part(&writer, string(cb_hex[:]))
	system.write_part(&writer, "),\n    compiler = module(blake3:")
	disk_process.hash_write(&hex_buf, c_compiler_hash)
	cc_hex := hex_buf
	system.write_part(&writer, string(cc_hex[:]))
	system.write_part(&writer, "),\n    assembler = module(blake3:")
	disk_process.hash_write(&hex_buf, assemble_hash)
	as_hex := hex_buf
	system.write_part(&writer, string(as_hex[:]))
	system.write_part(&writer, "),\n    module = (path) => recipe(module(blake3:")
	system.write_part(&writer, string(cb_hex[:]))
	system.write_part(&writer, "), {\n      assembler = module(blake3:")
	system.write_part(&writer, string(as_hex[:]))
	system.write_part(&writer, "),\n      compiler = module(blake3:")
	system.write_part(&writer, string(cc_hex[:]))
	system.write_part(&writer, "),\n      host = module(blake3:")
	disk_process.hash_write(&hex_buf, host_hash)
	system.write_part(&writer, string(hex_buf[:]))
	system.write_part(&writer, "),\n      path = path,\n      source = here(),\n    }),\n  },\n}\n")
	written := system.written(&writer)
	if len(written) == len(dst) {
		_ = fail("recipes.build_project: generated catalog.lex exceeds buffer")
		return "", false
	}
	return written, true
}

// recipes_read_small_store_file reads one .lex file from a store place into
// the provided arena slice.
@(private = "file")
recipes_read_small_store_file :: proc "contextless" (client: ^storage.Client, sandbox: ^Sandbox, place: storage.Place, name: string, arena: []u8, used: ^int) -> (text: string, ok: bool) {
	size, sz_status := storage.size(client, place, name)
	recipes_storage_sync(client, sandbox)
	if sz_status != .Ok || size <= 0 {
		return "", false
	}
	if used^ + int(size) > len(arena) {
		_ = fail("recipes.build_project: declaration files exceed bundle arena")
		return "", false
	}
	dst := arena[used^ : used^ + int(size)]
	offset: i64 = 0
	for offset < size {
		piece, rd_status := storage.read_range(client, place, name, u64(offset), dst[offset:])
		recipes_storage_sync(client, sandbox)
		if rd_status != .Ok || len(piece) == 0 {
			_ = fail("recipes.build_project: cannot read ", name)
			return "", false
		}
		offset += i64(len(piece))
	}
	used^ += int(size)
	return string(dst), true
}

// recipes_collect_lex_entries recursively gathers all .lex files under place
// (root and nested subdirectories) into recipes_bundle_entries, failing if the
// project exceeds RECIPES_BUNDLE_ENTRIES_MOST - 1 files or arena space.
@(private = "file")
recipes_collect_lex_entries :: proc "contextless" (
	client: ^storage.Client,
	sandbox: ^Sandbox,
	place: storage.Place,
	prefix: string,
	depth: int,
	bundle_count: ^int,
	lex_used: ^int,
	has_catalog: ^bool,
) -> bool {
	if depth > RECIPES_TREE_DEPTH_MOST {
		_ = fail("recipes.build_project: directory nesting exceeds ", i64(RECIPES_TREE_DEPTH_MOST), " levels")
		return false
	}
	rows: [RECIPES_LIST_PAGE_ROWS]storage.Listed
	names: [RECIPES_LIST_PAGE_NAMES]u8
	after_buf: [tree_hash.ENTRY_NAME_CAPACITY]u8
	after_len := 0
	for {
		page, list_status := storage.list(client, place, string(after_buf[:after_len]), rows[:], names[:])
		recipes_storage_sync(client, sandbox)
		if list_status != .Ok {
			_ = fail("recipes.build_project: cannot list entries of the project store")
			return false
		}
		if len(page) == 0 {
			break
		}
		for row in page {
			if row.name_offset < 0 || row.name_count <= 0 || row.name_offset + row.name_count > i64(len(names)) {
				continue
			}
			entry_name := string(names[row.name_offset : row.name_offset + row.name_count])
			if len(entry_name) <= len(after_buf) {
				copy(after_buf[:], entry_name)
				after_len = len(entry_name)
			}
			entry_kind, kind_ok := storage.entry_kind_of_word(row.kind)
			if !kind_ok {
				continue
			}
			rel_len := len(prefix) > 0 ? len(prefix) + 1 + len(entry_name) : len(entry_name)
			switch entry_kind {
			case .Tree:
				if rel_len > declaration_eval.DECLARATION_PATH_LIMIT {
					continue
				}
				sub_path_buf: [declaration_eval.DECLARATION_PATH_LIMIT]u8
				at := 0
				if len(prefix) > 0 {
					copy(sub_path_buf[:], prefix)
					at = len(prefix)
					sub_path_buf[at] = '/'
					at += 1
				}
				copy(sub_path_buf[at:], entry_name)
				at += len(entry_name)
				sub_place, open_status := storage.open_tree(client, place, entry_name)
				recipes_storage_sync(client, sandbox)
				if open_status != .Ok {
					_ = fail("recipes.build_project: cannot open subtree ", string(sub_path_buf[:at]))
					return false
				}
				sub_ok := recipes_collect_lex_entries(client, sandbox, sub_place, string(sub_path_buf[:at]), depth + 1, bundle_count, lex_used, has_catalog)
				_ = storage.close_tree(client, sub_place)
				recipes_storage_sync(client, sandbox)
				if !sub_ok {
					return false
				}
			case .Object:
				if len(prefix) == 0 && entry_name == "project.lex" {
					continue
				}
				if rel_len > declaration_eval.DECLARATION_PATH_LIMIT {
					continue
				}
				if lex_used^ + rel_len > len(recipes_lex_arena) {
					_ = fail("recipes.build_project: declaration files exceed bundle arena")
					return false
				}
				path_slice := recipes_lex_arena[lex_used^ : lex_used^ + rel_len]
				at := 0
				if len(prefix) > 0 {
					copy(path_slice[:], prefix)
					at = len(prefix)
					path_slice[at] = '/'
					at += 1
				}
				copy(path_slice[at:], entry_name)
				path_kept := string(path_slice)
				if !declaration_eval.declaration_path_valid(path_kept) {
					continue
				}
				if bundle_count^ >= RECIPES_BUNDLE_ENTRIES_MOST - 1 {
					_ = fail("recipes.build_project: project has more than ", i64(RECIPES_BUNDLE_ENTRIES_MOST - 1), " .lex files")
					return false
				}
				lex_used^ += rel_len
				content, read_ok := recipes_read_small_store_file(client, sandbox, place, entry_name, recipes_lex_arena[:], lex_used)
				if !read_ok {
					return false
				}
				recipes_bundle_entries[bundle_count^] = {
					kind    = .File_Path,
					path    = path_kept,
					content = content,
				}
				bundle_count^ += 1
				if path_kept == "catalog.lex" {
					has_catalog^ = true
				}
			case .Release, .None:
			}
		}
	}
	return true
}

// recipes_build_project_command evaluates a project's project.lex (with here()
// ingested into recipes's object store) through the isolated zero-grant
// declaration_eval call host, registers the evaluation with recipes, and runs
// recipes.build_stored in the requested build mode.
recipes_build_project_command :: proc "contextless" (arguments: []Value) -> Value {
	project := arguments[0].text
	mode_text := len(arguments) > 1 ? arguments[1].text : ""
	mode, mode_ok := recipes_build_mode_of_text(mode_text)
	if !mode_ok {
		return fail("recipes.build_project: unknown build mode \"", mode_text, "\"; use prefer_cache, build_only, cache_only, or verify")
	}

	// 1. Freeze and ingest the project's source tree into recipes so here()
	//    resolves to verified content-addressed objects.
	here_hash, ingested := recipes_ingest_store(project)
	if !ingested {
		return {}
	}

	// 2. Read project.lex and all .lex imports from the project store (root and nested).
	client, sandbox, borrowed := recipes_storage_borrow()
	if !borrowed {
		return {}
	}
	root_place, open_status := storage.open_store(&client, project)
	recipes_storage_sync(&client, sandbox)
	if open_status != .Ok {
		return fail("recipes.build_project: cannot open store ", project)
	}
	defer {
		_ = storage.close_tree(&client, root_place)
		recipes_storage_sync(&client, sandbox)
	}

	lex_used := 0
	project_lex, has_project := recipes_read_small_store_file(&client, sandbox, root_place, "project.lex", recipes_lex_arena[:], &lex_used)
	if !has_project {
		return failed ? {} : fail("recipes.build_project: store ", project, " has no project.lex")
	}

	bundle_count := 0
	has_catalog := false
	if !recipes_collect_lex_entries(&client, sandbox, root_place, "", 0, &bundle_count, &lex_used, &has_catalog) {
		return {}
	}

	if !has_catalog {
		catalog_text, cat_ok := recipes_catalog_generate(recipes_catalog_buf[:])
		if !cat_ok {
			return {}
		}
		recipes_bundle_entries[bundle_count] = {
			kind    = .File_Path,
			path    = "catalog.lex",
			content = catalog_text,
		}
		bundle_count += 1
	}

	bundle_len, bundle_ref := declaration_eval.bundle_write(recipes_bundle_buf[:], recipes_bundle_entries[:bundle_count], has_here = true, here_hash = here_hash)
	if bundle_ref != .None {
		return fail("recipes.build_project: cannot encode declaration_eval bundle")
	}

	// 3. Evaluate outputs.default inside a zero-grant declaration_eval call host.
	if command_find("evaluate") != nil {
		unload_args := [1]Value{{kind = .Text, text = "declaration_eval"}}
		_ = call_run("unload", unload_args[:])
	}
	iso_args := [1]Value{{kind = .Text, text = "declaration_eval"}}
	if r := isolate_module(iso_args[:]); r.kind == .None || failed {
		return {}
	}
	defer {
		unload_args := [1]Value{{kind = .Text, text = "declaration_eval"}}
		_ = call_run("unload", unload_args[:])
	}

	eval_args := [4]Value{
		{kind = .Text, text = project_lex},
		{kind = .Text, text = "outputs.default"},
		{kind = .Bytes, record = recipes_bundle_buf[:bundle_len]},
		{},
	}
	eval_len_val, eval_mem, eval_ok := program_call_with_room("evaluate", eval_args[:], 3, RECIPES_EVAL_OUTPUT_FIRST_PAGES, RECIPES_EVAL_OUTPUT_BYTES_MOST)
	if !eval_ok {
		return {}
	}
	defer system.close(eval_mem)
	if eval_len_val.integer <= 0 || u64(eval_len_val.integer) > RECIPES_EVAL_OUTPUT_BYTES_MOST {
		return fail("recipes.build_project: declaration_eval returned an out-of-range byte count")
	}

	eval_addr, map_status := system.memory_map(eval_mem, {})
	if map_status != .Succeeded {
		return fail("recipes.build_project: cannot map declaration_eval output")
	}
	defer system.memory_unmap(eval_addr)
	eval_bytes := ([^]u8)(eval_addr)[:eval_len_val.integer]
	header, _, hdr_ref := declaration_eval.output_read_header(eval_bytes)
	if hdr_ref != .None {
		return fail("recipes.build_project: declaration_eval output header is damaged")
	}
	if header.status != .Ok {
		return fail("recipes.build_project: project.lex evaluation refused at line ", i64(header.line), ", column ", i64(header.column))
	}

	// 4. Register the evaluated recipe with recipes and build it.
	reg_args := [1]Value{{kind = .Bytes, record = eval_bytes}}
	reg_table_val := call_run("recipes.register_evaluation", reg_args[:])
	if failed {
		return {}
	}
	reg_table, has_reg := table_of(reg_table_val)
	if !has_reg || reg_table.rows < 1 || len(reg_table_val.record) < size_of(pr.Recipe_Reference) {
		return fail("recipes.register_evaluation: did not return a recipe hash")
	}
	ref := (^pr.Recipe_Reference)(raw_data(table_row(reg_table, reg_table_val, 0)))^
	recipe_hex_buf: [64]u8
	disk_process.hash_write(&recipe_hex_buf, blake3.Hash(ref.recipe_hash))

	build_args := [2]Value{
		{kind = .Text, text = string(recipe_hex_buf[:])},
		{kind = .Integer, integer = i64(mode)},
	}
	build_table_val := call_run("recipes.build_stored", build_args[:])
	if failed {
		return {}
	}
	build_table, has_build := table_of(build_table_val)
	if !has_build || build_table.rows < 1 || len(build_table_val.record) < size_of(pr.Recipe_Build_Row) {
		return fail("recipes.build_stored: did not return a build result row")
	}
	row := (^pr.Recipe_Build_Row)(raw_data(table_row(build_table, build_table_val, 0)))^
	if row.outcome_word < 0 {
		return fail("recipes.build_project: recipes.build_stored returned an unknown build outcome")
	}
	build_outcome, outcome_ok := pr.recipe_build_outcome_of_word(u64(row.outcome_word))
	if !outcome_ok {
		return fail("recipes.build_project: recipes.build_stored returned an unknown build outcome")
	}
	outcome_label: string
	switch build_outcome {
	case .Built_Locally:
		outcome_label = "built"
	case .From_Cache:
		outcome_label = "cached"
	case .Building:
		outcome_label = "building"
	case .Refused, .None:
		return fail("recipes.build_project: build was refused")
	}
	out_hex_buf: [64]u8
	disk_process.hash_write(&out_hex_buf, blake3.Hash(row.output_hash))
	return {kind = .Text, text = scratch_text(outcome_label, ": recipe ", string(recipe_hex_buf[:]), " output ", string(out_hex_buf[:]))}
}

// recipes_provenance_command queries recipes.realisations() for the named
// 64-hex recipe hash and formats its origin, output hash, and signer key.
recipes_provenance_command :: proc "contextless" (arguments: []Value) -> Value {
	hex_arg := arguments[0].text
	target_hash, hash_ok := pr.hash_of_hexadecimal(transmute([]u8)hex_arg)
	if !hash_ok {
		return fail("recipes.provenance: expected 64 lowercase hexadecimal digits for the recipe hash")
	}
	table_val := call_run("recipes.realisations", nil)
	if failed {
		return {}
	}
	table, has_table := table_of(table_val)
	if !has_table {
		return fail("recipes.provenance: recipes.realisations did not return a table")
	}
	for index in 0 ..< table.rows {
		raw := table_row(table, table_val, index)
		if len(raw) < size_of(pr.Realisation_Row) {
			continue
		}
		row := (^pr.Realisation_Row)(raw_data(raw))^
		if blake3.Hash(row.recipe_hash) != target_hash {
			continue
		}
		if row.origin_word < 0 {
			return fail("recipes.provenance: realisation row carries an unknown origin")
		}
		origin, origin_ok := pr.provenance_origin_of_word(u64(row.origin_word))
		if !origin_ok {
			return fail("recipes.provenance: realisation row carries an unknown origin")
		}
		origin_label: string
		switch origin {
		case .Local_Build:
			origin_label = "local_build"
		case .Remote_Cache:
			origin_label = "remote_cache"
		case .None:
			return fail("recipes.provenance: realisation row carries origin None")
		}
		out_hex, signer_hex: [64]u8
		disk_process.hash_write(&out_hex, blake3.Hash(row.output_hash))
		disk_process.hash_write(&signer_hex, blake3.Hash(row.signer_public_key))
		return {kind = .Text, text = scratch_text("recipe ", hex_arg, " output ", string(out_hex[:]), " origin ", origin_label, " signer ", string(signer_hex[:]))}
	}
	return fail("recipes.provenance: no realisation exists for recipe ", hex_arg)
}

// recipes_deliver_module_command reads a verified output module from recipes
// (either a direct blob when entry_name is empty or a named entry of a
// verified Tree output, such as "module"), validates its module format, and
// stores it into module_files under nickname so start_from_disk or plans.apply
// can launch it by hash.
recipes_deliver_module_command :: proc "contextless" (arguments: []Value) -> Value {
	output_hex := arguments[0].text
	entry_name := arguments[1].text
	nickname := arguments[2].text
	if _, hash_ok := pr.hash_of_hexadecimal(transmute([]u8)output_hex); !hash_ok {
		return fail("recipes.deliver_module: argument 1 must be 64 lowercase hexadecimal digits")
	}
	if refusal := disk_process.nickname_refusal(nickname, len(nickname), 3, .Make); refusal.kind != 0 {
		return fail("recipes.deliver_module: \"", nickname, "\" is not a valid module nickname")
	}
	read_args := [3]Value{
		{kind = .Text, text = output_hex},
		{kind = .Text, text = entry_name},
		{},
	}
	size_val, mod_mem, read_ok := program_call_with_room("recipes.read_output", read_args[:], 2, PROGRAM_MODULE_FIRST_PAGES, PROGRAM_MODULE_BYTES_MOST)
	if !read_ok {
		return {}
	}
	defer system.close(mod_mem)
	if size_val.integer <= 0 || u64(size_val.integer) > PROGRAM_MODULE_BYTES_MOST {
		return fail("recipes.deliver_module: output size is out of range")
	}
	addr, map_status := system.memory_map(mod_mem, {})
	if map_status != .Succeeded {
		return fail("recipes.deliver_module: cannot map output module memory")
	}
	valid := module.validate(([^]u8)(addr)[:size_val.integer]) == .None
	system.memory_unmap(addr)
	if !valid {
		return fail("recipes.deliver_module: output bytes are not a valid modus module")
	}
	put_args := [3]Value{
		{kind = .Text, text = nickname},
		{kind = .Handle, integer = i64(mod_mem)},
		size_val,
	}
	digits := call_run("module_files.put", put_args[:])
	if failed {
		return {}
	}
	return digits
}

// Mirror of recipes_service.Collect_Result for decoding recipes.collect_garbage.
@(private = "file")
Recipes_Collect_Row :: struct {
	marked:  i64,
	kept:    i64,
	removed: i64,
}
#assert(size_of(Recipes_Collect_Row) == 24)

// recipes_collect_garbage_command runs mark-and-sweep garbage collection over
// recipes's private store and reports marked, kept, and removed counts.
recipes_collect_garbage_command :: proc "contextless" (_: []Value) -> Value {
	row_table := call_run("recipes.collect_garbage", nil)
	if failed {
		return {}
	}
	table, has_table := table_of(row_table)
	if !has_table || table.rows < 1 {
		return fail("recipes.collect_garbage: did not return a collection summary row")
	}
	raw := table_row(table, row_table, 0)
	if len(raw) < size_of(Recipes_Collect_Row) {
		return fail("recipes.collect_garbage: collection summary row is truncated")
	}
	row := (^Recipes_Collect_Row)(raw_data(raw))^
	return {kind = .Text, text = scratch_text("marked ", row.marked, " kept ", row.kept, " removed ", row.removed)}
}
