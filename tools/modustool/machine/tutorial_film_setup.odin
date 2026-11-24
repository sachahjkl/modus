// Preparation and teardown of the deterministic data disk and local signed
// QUIC object cache for `modustool film tutorial` (docs/TOOLS.md, "The film").
//
// Builds real outside modules (sqlite.module, db_browser.module,
// store_explorer.module), seeds an initial 4 KiB-page SQLite main.db by
// executing sqlite.module in memory, writes a multi-store STORAGE7 data disk
// (collatz, db_browser, store_explorer, disk-db_browser), starts an ephemeral
// host QUIC cache-serve on 127.0.0.1:0 with deterministic Ed25519 keys, and
// expands scenario_tutorial_film placeholders with the computed 64-hex hashes.
package machine

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"
import "modus:cryptography/ed25519"
import "modus:disk_process"
import "modus:lex_evaluator"
import "modustool:build"
import "modustool:cache_server"
import "modustool:foundation"

TUTORIAL_COLLATZ_DIR :: "src/outside/projects/collatz"
TUTORIAL_DB_BROWSER_DIR :: "src/outside/projects/db_browser"
TUTORIAL_STORE_EXPLORER_DIR :: "src/outside/projects/store_explorer"
TUTORIAL_C_PROGRAMS_DIR :: "src/outside/c_programs"
TUTORIAL_SQLITE_RECIPE :: "src/outside/c_programs/recipes/sqlite.recipe"

// Deterministic seed SQL that creates generation v1 of main.db before the
// interactive INSERT in the tutorial film creates v2.
TUTORIAL_INITIAL_DB_SQL :: "CREATE TABLE tasks (id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL); INSERT INTO tasks (title, done) VALUES ('build kernel', 1), ('verify cache', 1);"

// Deterministic test-only Ed25519 seeds for the ephemeral local tutorial cache
// (bound to 127.0.0.1:0, destroyed when the film ends).
@(private = "file")
tutorial_ed25519_seed :: proc(base: u8) -> (seed: [32]u8) {
	for i in 0 ..< 32 {
		seed[i] = base + u8(i * 13 + 7)
	}
	return seed
}

Tutorial_Film_Bindings :: struct {
	cache_server_key:  string,
	cache_signer_key:  string,
	collatz_here:      string,
	db_browser_here:   string,
	db_browser_recipe: string,
	db_browser_output: string,
	db_browser_hash:   string,
}

Tutorial_Film_Fixture :: struct {
	work_dir:             string,
	data_disk_path:       string,
	cache_server_state:   cache_server.Cache_Server,
	cache_server_open:    bool,
	cache_quic:           ^cache_server.Cache_Quic_Running,
	cache_endpoint:       net.Endpoint,
	bindings:             Tutorial_Film_Bindings,
	db_browser_bytes:     []u8,
	fact_outside_modules: [1]build.Fact_Catalog_Module,
}

// tutorial_hex_of formats a 32-byte digest or public key as 64 lowercase hex digits.
tutorial_hex_of :: proc(value: [32]u8, allocator := context.allocator) -> string {
	digits: [64]u8
	disk_process.hash_write(&digits, value)
	return strings.clone(string(digits[:]), allocator)
}

// tutorial_film_expand_text replaces all tutorial template placeholders in text.
@(private = "file")
tutorial_film_expand_text :: proc(text: string, bindings: Tutorial_Film_Bindings, allocator := context.allocator) -> (expanded: string, ok: bool) {
	if !strings.contains_rune(text, '{') {
		return strings.clone(text, allocator), true
	}
	pairs := [?][2]string{
		{"{cache_server_key}", bindings.cache_server_key},
		{"{cache_signer_key}", bindings.cache_signer_key},
		{"{collatz_here}", bindings.collatz_here},
		{"{db_browser_here}", bindings.db_browser_here},
		{"{db_browser_recipe}", bindings.db_browser_recipe},
		{"{db_browser_output}", bindings.db_browser_output},
		{"{db_browser_hash}", bindings.db_browser_hash},
	}
	current := strings.clone(text, context.temp_allocator)
	for pair in pairs {
		if strings.contains(current, pair[0]) {
			if len(pair[1]) == 0 {
				return "", false
			}
			current, _ = strings.replace_all(current, pair[0], pair[1], context.temp_allocator)
		}
	}
	// Refuse any leftover unexpanded tutorial placeholder (while allowing
	// scenario_run's own runtime marks if ever present).
	for pair in pairs {
		if strings.contains(current, pair[0]) {
			return "", false
		}
	}
	return strings.clone(current, allocator), true
}

// tutorial_film_expand_steps clones template and expands all tutorial placeholders.
// Refuses empty required bindings or unexpanded placeholders.
tutorial_film_expand_steps :: proc(template: []Step, bindings: Tutorial_Film_Bindings, allocator := context.allocator) -> (steps: []Step, ok: bool) {
	out := make([]Step, len(template), allocator)
	defer if !ok {
		tutorial_film_steps_free(out, allocator)
	}
	for step, index in template {
		copied := step
		copied.text = tutorial_film_expand_text(step.text, bindings, allocator) or_return
		copied.expected = tutorial_film_expand_text(step.expected, bindings, allocator) or_return
		copied.fails_on = tutorial_film_expand_text(step.fails_on, bindings, allocator) or_return
		out[index] = copied
	}
	return out, true
}

tutorial_film_steps_free :: proc(steps: []Step, allocator := context.allocator) {
	for step in steps {
		delete(step.text, allocator)
		delete(step.expected, allocator)
		delete(step.fails_on, allocator)
	}
	delete(steps, allocator)
}

// tutorial_tree_hash_of computes the canonical MODTREE2 BLAKE3 hash matching
// console/recipes_wiring.odin:recipes_ingest_place over objects and nested trees.
tutorial_tree_hash_of :: proc(objects: []build.Module_File, trees: []build.Data_Disk_Tree) -> (hash: blake3.Hash, ok: bool) {
	Entry_Ref :: struct {
		name:    string,
		is_tree: bool,
		index:   int,
	}
	total := len(objects) + len(trees)
	refs := make([]Entry_Ref, total, context.temp_allocator)
	at := 0
	for obj, index in objects {
		refs[at] = {name = obj.name, is_tree = false, index = index}
		at += 1
	}
	for sub, index in trees {
		refs[at] = {name = sub.name, is_tree = true, index = index}
		at += 1
	}
	slice.sort_by(refs, proc(a, b: Entry_Ref) -> bool {
		return a.name < b.name
	})

	entries := make([]tree_hash.Tree_Entry, total, context.temp_allocator)
	for ref, index in refs {
		entry_hash: blake3.Hash
		entry_kind: tree_hash.Tree_Entry_Kind
		if ref.is_tree {
			sub := trees[ref.index]
			entry_hash = tutorial_tree_hash_of(sub.objects, sub.trees) or_return
			entry_kind = .Tree
		} else {
			entry_hash = blake3.hash(objects[ref.index].bytes)
			entry_kind = .Object
		}
		made, refusal := tree_hash.tree_entry_make(entry_kind, ref.name, entry_hash)
		if refusal != .None {
			return {}, false
		}
		entries[index] = made
	}
	encoded := make([]u8, tree_hash.tree_encoded_size(entries), context.temp_allocator)
	written, enc_ref := tree_hash.tree_encode(entries, encoded)
	if enc_ref != .None {
		return {}, false
	}
	digest, hash_ref := tree_hash.tree_hash(encoded[:written])
	if hash_ref != .None {
		return {}, false
	}
	return digest, true
}

// tutorial_read_project_tree recursively loads a project directory into
// Data_Disk_Store objects/trees (skipping hidden entries and any local build/
// directory) and returns its canonical MODTREE2 here() hash.
tutorial_read_project_tree :: proc(dir: string, allocator := context.allocator) -> (objects: []build.Module_File, trees: []build.Data_Disk_Tree, here_hash: blake3.Hash, ok: bool) {
	handle, open_err := os.open(dir)
	if open_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot open project folder %s: %v", dir, open_err)
		return nil, nil, {}, false
	}
	defer os.close(handle)

	infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot list project folder %s: %v", dir, read_err)
		return nil, nil, {}, false
	}
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	obj_list := make([dynamic]build.Module_File, allocator)
	tree_list := make([dynamic]build.Data_Disk_Tree, allocator)
	defer if !ok {
		tutorial_free_project_tree(obj_list[:], tree_list[:], allocator)
		delete(obj_list)
		delete(tree_list)
	}

	for info in infos {
		if len(info.name) == 0 || info.name[0] == '.' || info.name == "build" {
			continue
		}
		full_path := strings.concatenate({dir, "/", info.name}, context.temp_allocator)
		if info.type == .Directory {
			sub_objs, sub_trees, _, sub_ok := tutorial_read_project_tree(full_path, allocator)
			if !sub_ok {
				return nil, nil, {}, false
			}
			if len(sub_objs) == 0 && len(sub_trees) == 0 {
				delete(sub_objs, allocator)
				delete(sub_trees, allocator)
				continue
			}
			append(&tree_list, build.Data_Disk_Tree{
				name    = strings.clone(info.name, allocator),
				objects = sub_objs,
				trees   = sub_trees,
			})
		} else if info.type == .Regular {
			bytes, file_err := os.read_entire_file(full_path, allocator)
			if file_err != nil {
				fmt.eprintfln("modustool: tutorial: cannot read %s: %v", full_path, file_err)
				return nil, nil, {}, false
			}
			if len(bytes) == 0 {
				delete(bytes, allocator)
				continue
			}
			append(&obj_list, build.Module_File{
				name  = strings.clone(info.name, allocator),
				bytes = bytes,
			})
		}
	}

	here_hash, ok = tutorial_tree_hash_of(obj_list[:], tree_list[:])
	if !ok {
		return nil, nil, {}, false
	}
	return obj_list[:], tree_list[:], here_hash, true
}

tutorial_free_project_tree :: proc(objects: []build.Module_File, trees: []build.Data_Disk_Tree, allocator := context.allocator) {
	for obj in objects {
		delete(obj.name, allocator)
		delete(obj.bytes, allocator)
	}
	delete(objects, allocator)
	for sub in trees {
		delete(sub.name, allocator)
		tutorial_free_project_tree(sub.objects, sub.trees, allocator)
	}
	delete(trees, allocator)
}

// tutorial_evaluate_project_recipe evaluates outputs.default of project_lex
// with here_hash and catalog_lex, returning the exact recipe hash that
// declaration_eval produces inside modus.
tutorial_evaluate_project_recipe :: proc(project_lex: string, here_hash: blake3.Hash, catalog_lex: string) -> (recipe_hash: blake3.Hash, ok: bool) {
	workspace := new(lex_evaluator.Declaration_Workspace)
	defer free(workspace)
	pools := lex_evaluator.declaration_pools_of_scale(0)
	memory, alloc_err := mem.alloc_bytes(lex_evaluator.declaration_workspace_bytes(pools), 64)
	if alloc_err != nil {
		return {}, false
	}
	defer delete(memory)
	lex_evaluator.declaration_workspace_carve(workspace, memory, pools)
	bindings := [1]lex_evaluator.Declaration_Binding{
		{name = "catalog", kind = .Lex_Source, source = catalog_lex},
	}
	config := lex_evaluator.Declaration_Config{
		bindings    = bindings[:],
		has_here    = true,
		here_hash   = here_hash,
		stack_bytes = 2 * 1024 * 1024,
	}
	result := lex_evaluator.declaration_evaluate(workspace, project_lex, "outputs.default", config)
	if !result.ok || result.value.kind != .Recipe_Ref {
		fmt.eprintfln("modustool: tutorial: project.lex outputs.default did not evaluate to a recipe (%v)", result)
		return {}, false
	}
	return workspace.evaluation.recipes[int(result.value.data)].recipe_hash, true
}

// tutorial_build_sqlite_module compiles src/outside/c_programs/recipes/sqlite.recipe
// against SQLITE_SOURCE and converts the linked object with sqlite.manifest.
tutorial_build_sqlite_module :: proc(work_dir: string, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	sqlite_root := os.get_env("SQLITE_SOURCE", context.temp_allocator)
	if sqlite_root == "" {
		fmt.eprintln("modustool: tutorial: SQLITE_SOURCE is not set in the environment (run inside `nix develop`)")
		return nil, false
	}
	recipe_bytes, recipe_err := os.read_entire_file(TUTORIAL_SQLITE_RECIPE, context.temp_allocator)
	if recipe_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot read %s: %v", TUTORIAL_SQLITE_RECIPE, recipe_err)
		return nil, false
	}
	flags := make([dynamic]string, context.temp_allocator)
	include_flags := make([dynamic]string, context.temp_allocator)
	sources := make([dynamic]string, context.temp_allocator)
	manifest_path := ""

	for line in strings.split_lines(string(recipe_bytes), context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		colon := strings.index(trimmed, ": ")
		if colon <= 0 {
			continue
		}
		key := trimmed[:colon]
		value := trimmed[colon + 2:]
		switch key {
		case "flag":
			append(&flags, value)
		case "define":
			append(&flags, strings.concatenate({"-D", value}, context.temp_allocator))
		case "include":
			append(&include_flags, "-I", strings.concatenate({TUTORIAL_C_PROGRAMS_DIR, "/", value}, context.temp_allocator))
		case "compile":
			append(&sources, strings.concatenate({sqlite_root, "/", value}, context.temp_allocator))
		case "adapter":
			append(&sources, strings.concatenate({TUTORIAL_C_PROGRAMS_DIR, "/", value}, context.temp_allocator))
		case "manifest":
			manifest_path = strings.concatenate({TUTORIAL_C_PROGRAMS_DIR, "/", value}, context.temp_allocator)
		}
	}
	append(&flags, ..include_flags[:])
	append(&flags, "-I", sqlite_root)

	obj_dir := foundation.join(work_dir, "/sqlite_build")
	foundation.reset_folder(obj_dir) or_return

	objects := make([dynamic]string, context.temp_allocator)
	for source, index in sources {
		obj := fmt.tprintf("%s/unit_%d.o", obj_dir, index)
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "clang")
		append(&cmd, ..flags[:])
		append(&cmd, "-c", "-o", obj, source)
		foundation.run(cmd[:]) or_return
		append(&objects, obj)
	}
	combined := foundation.join(obj_dir, "/combined.o")
	link_cmd := make([dynamic]string, context.temp_allocator)
	append(&link_cmd, "ld.lld", "-r", "-o", combined)
	append(&link_cmd, ..objects[:])
	foundation.run(link_cmd[:]) or_return

	elf, elf_err := os.read_entire_file(combined, context.temp_allocator)
	if elf_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot read %s: %v", combined, elf_err)
		return nil, false
	}
	manifest_bytes, man_err := os.read_entire_file(manifest_path, context.temp_allocator)
	if man_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot read %s: %v", manifest_path, man_err)
		return nil, false
	}
	manifest, man_problem := build.manifest_parse(string(manifest_bytes))
	if man_problem != "" {
		fmt.eprintfln("modustool: tutorial: sqlite.manifest refused: %s", man_problem)
		return nil, false
	}
	mod_file, converted := build.convert_elf_with_manifest(elf, manifest, nil)
	defer delete(mod_file)
	if !converted || module.validate(mod_file) != .None {
		fmt.eprintln("modustool: tutorial: sqlite.module conversion or validation failed")
		return nil, false
	}
	return slice.clone(mod_file, allocator), true
}

// ABI records matching src/outside/c_programs/sqlite/sqlite.manifest for
// host-side seeding of main.db directly through the built sqlite.module.
@(private = "file")
Tutorial_Sqlite_Open_Options :: struct {
	fresh:          u8,
	read_only:      u8,
	reserved:       [2]u8,
	page_size:      u32,
	random_seed:    u64,
	database_bytes: u64,
	heap_bytes:     u32,
	reserved_2:     u32,
}
#assert(size_of(Tutorial_Sqlite_Open_Options) == 32)

@(private = "file")
Tutorial_Sqlite_Session_Info :: struct {
	version_number: i64,
	database_bytes: u64,
	dirty_pages:    u64,
	page_size:      u32,
	open:           u8,
	read_only:      u8,
	reserved:       [2]u8,
}
#assert(size_of(Tutorial_Sqlite_Session_Info) == 32)

@(private = "file")
Tutorial_Sqlite_Column_Row :: struct {
	column_index:   u32,
	declared_kind:  u8,
	name_length:    u8,
	name_truncated: u8,
	reserved:       u8,
	name:           [64]u8,
}
#assert(size_of(Tutorial_Sqlite_Column_Row) == 72)

@(private = "file")
Tutorial_Sqlite_Cell_Row :: struct {
	row_index:       u32,
	column_index:    u32,
	value_kind:      u8,
	truncated:       u8,
	reserved:        [6]u8,
	integer_or_bits: i64,
	payload_offset:  u32,
	payload_length:  u32,
}
#assert(size_of(Tutorial_Sqlite_Cell_Row) == 32)

@(private = "file")
Tutorial_Sqlite_Query_Summary :: struct {
	column_count:   u32,
	row_count:      u32,
	changes:        i64,
	dirty_pages:    u64,
	database_bytes: u64,
	truncated_rows: u8,
	has_rows:       u8,
	reserved:       [6]u8,
}
#assert(size_of(Tutorial_Sqlite_Query_Summary) == 40)

@(private = "file")
Tutorial_Sqlite_Slice :: struct {
	address: [^]u8,
	count:   u64,
}
#assert(size_of(Tutorial_Sqlite_Slice) == 16)

@(private = "file")
Tutorial_Sqlite_Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}
#assert(size_of(Tutorial_Sqlite_Answer) == 16)

// tutorial_build_initial_main_db loads sqlite_module in memory on x86-64 and
// runs TUTORIAL_INITIAL_DB_SQL to generate an authentic 4 KiB-page SQLite
// database file (version v1 before the film's interactive INSERT creates v2).
tutorial_build_initial_main_db :: proc(sqlite_module: []u8, allocator := context.allocator) -> (db_bytes: []u8, ok: bool) {
	when ODIN_ARCH != .amd64 {
		fmt.eprintln("modustool: tutorial: initial main.db seeding requires x86-64 host")
		return nil, false
	} else {
		if module.validate(sqlite_module) != .None {
			return nil, false
		}
		head, _ := module.header(sqlite_module)
		memory, mem_err := virtual.reserve_and_commit(uint(head.memory_size))
		if mem_err != nil {
			return nil, false
		}
		defer virtual.release(raw_data(memory), uint(head.memory_size))
		module.copy_segments(sqlite_module, memory)
		if module.rebase(sqlite_module, memory, uintptr(raw_data(memory))) != .None {
			return nil, false
		}
		for index in 1 ..< module.count(sqlite_module, .Segments) {
			segment, _ := module.record(sqlite_module, .Segments, index, module.Segment)
			if .Execute in segment.flags && !virtual.protect(&memory[segment.memory_offset], uint(segment.memory_size), {.Read, .Execute}) {
				return nil, false
			}
		}

		open_addr, open_found := module.export_address(sqlite_module, uintptr(raw_data(memory)), module.export_find(sqlite_module, "session_open"))
		exec_addr, exec_found := module.export_address(sqlite_module, uintptr(raw_data(memory)), module.export_find(sqlite_module, "session_execute"))
		close_addr, close_found := module.export_address(sqlite_module, uintptr(raw_data(memory)), module.export_find(sqlite_module, "session_close"))
		if !open_found || !exec_found || !close_found {
			return nil, false
		}

		Open_Proc :: proc "c" (opts: ^Tutorial_Sqlite_Open_Options, db: ^module.Table_Place, info: ^module.Table_Place, err: ^errors.Error_Record) -> Tutorial_Sqlite_Answer
		Exec_Proc :: proc "c" (sql: ^Tutorial_Sqlite_Slice, db: ^module.Table_Place, cols: ^module.Table_Place, cells: ^module.Table_Place, payload: ^module.Table_Place, diag: ^module.Table_Place, summary: ^module.Table_Place, err: ^errors.Error_Record) -> Tutorial_Sqlite_Answer
		Close_Proc :: proc "c" (db: ^module.Table_Place, err: ^errors.Error_Record) -> Tutorial_Sqlite_Answer

		fn_open := Open_Proc(rawptr(open_addr))
		fn_exec := Exec_Proc(rawptr(exec_addr))
		fn_close := Close_Proc(rawptr(close_addr))

		db_buf := make([]u8, 64 * 1024, context.temp_allocator)
		db_place := module.Table_Place{address = u64(uintptr(raw_data(db_buf))), count = u64(len(db_buf)), capacity = u64(len(db_buf))}
		info_row: [1]Tutorial_Sqlite_Session_Info
		info_place := module.Table_Place{address = u64(uintptr(&info_row[0])), count = 0, capacity = 1}
		opts := Tutorial_Sqlite_Open_Options{fresh = 1, page_size = 4096, random_seed = 0x5475746F7269616C, heap_bytes = 2 * 1024 * 1024}
		err: errors.Error_Record
		ans := fn_open(&opts, &db_place, &info_place, &err)
		if ans.outcome != .Succeeded {
			fmt.eprintfln("modustool: tutorial: sqlite session_open failed (%v)", ans.outcome)
			return nil, false
		}
		defer {
			close_err: errors.Error_Record
			_ = fn_close(&db_place, &close_err)
		}

		sql_text := TUTORIAL_INITIAL_DB_SQL
		sql_slice := Tutorial_Sqlite_Slice{address = raw_data(sql_text), count = u64(len(sql_text))}
		cols_buf: [8]Tutorial_Sqlite_Column_Row
		cells_buf: [32]Tutorial_Sqlite_Cell_Row
		payload_buf: [4096]u8
		diag_buf: [512]u8
		summary_buf: [1]Tutorial_Sqlite_Query_Summary
		cols_place := module.Table_Place{address = u64(uintptr(&cols_buf[0])), count = 0, capacity = len(cols_buf)}
		cells_place := module.Table_Place{address = u64(uintptr(&cells_buf[0])), count = 0, capacity = len(cells_buf)}
		payload_place := module.Table_Place{address = u64(uintptr(&payload_buf[0])), count = 0, capacity = len(payload_buf)}
		diag_place := module.Table_Place{address = u64(uintptr(&diag_buf[0])), count = 0, capacity = len(diag_buf)}
		summary_place := module.Table_Place{address = u64(uintptr(&summary_buf[0])), count = 0, capacity = 1}

		exec_ans := fn_exec(&sql_slice, &db_place, &cols_place, &cells_place, &payload_place, &diag_place, &summary_place, &err)
		if exec_ans.outcome != .Succeeded || summary_place.count < 1 || summary_buf[0].database_bytes == 0 || summary_buf[0].database_bytes > u64(len(db_buf)) {
			fmt.eprintfln("modustool: tutorial: sqlite seed SQL failed (%v, bytes %d)", exec_ans.outcome, summary_buf[0].database_bytes)
			return nil, false
		}
		return slice.clone(db_buf[:summary_buf[0].database_bytes], allocator), true
	}
}

// tutorial_build_outside_module invokes `modustool module-build` on project_dir
// and reads the validated <module_name>.module bytes.
@(private = "file")
tutorial_build_outside_module :: proc(project_dir, module_name, work_dir: string, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	tool_path := foundation.tool_executable_path() or_return
	system_dir, dir_err := os.get_working_directory(context.temp_allocator)
	if dir_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot read working directory: %v", dir_err)
		return nil, false
	}
	out_dir := foundation.join(work_dir, "/out_", module_name)
	foundation.reset_folder(out_dir) or_return
	foundation.run({tool_path, "module-build", project_dir, "--system", system_dir, "--out", out_dir}) or_return
	mod_path := foundation.join(out_dir, "/", module_name, ".module")
	mod_bytes, read_err := os.read_entire_file(mod_path, allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: tutorial: cannot read %s: %v", mod_path, read_err)
		return nil, false
	}
	if module.validate(mod_bytes) != .None {
		delete(mod_bytes, allocator)
		fmt.eprintfln("modustool: tutorial: built %s is not a valid module", mod_path)
		return nil, false
	}
	return mod_bytes, true
}

// tutorial_film_prepare builds the outside modules, seeds main.db, writes the
// multi-store STORAGE7 tutorial data disk, and starts an ephemeral local
// signed QUIC object cache on 127.0.0.1:0.
tutorial_film_prepare :: proc() -> (fixture: ^Tutorial_Film_Fixture, ok: bool) {
	work_dir := fmt.aprintf("%s/tutorial_film_%d", foundation.BUILD_FOLDER, os.get_pid())
	if !foundation.reset_folder(work_dir) {
		delete(work_dir)
		return nil, false
	}
	fixture = new(Tutorial_Film_Fixture)
	fixture.work_dir = work_dir
	defer if !ok {
		tutorial_film_teardown(fixture)
		fixture = nil
	}

	// 1. Build sqlite.module, seed initial main.db, and build db_browser + store_explorer.
	sqlite_bytes := tutorial_build_sqlite_module(work_dir) or_return
	defer delete(sqlite_bytes)
	main_db_bytes := tutorial_build_initial_main_db(sqlite_bytes) or_return
	defer delete(main_db_bytes)
	db_browser_bytes := tutorial_build_outside_module(TUTORIAL_DB_BROWSER_DIR, "db_browser", work_dir) or_return
	fixture.db_browser_bytes = db_browser_bytes
	fixture.fact_outside_modules[0] = {hash = blake3.hash(db_browser_bytes), file = db_browser_bytes}
	store_explorer_bytes := tutorial_build_outside_module(TUTORIAL_STORE_EXPLORER_DIR, "store_explorer", work_dir) or_return
	defer delete(store_explorer_bytes)

	host_bytes, host_ok := foundation.read_file(foundation.module_path("host"))
	if !host_ok {
		return nil, false
	}
	catalog_bytes, catalog_ok := foundation.read_file(build.CATALOG_FILE)
	if !catalog_ok {
		return nil, false
	}
	catalog_lex := string(catalog_bytes)

	// 2. Read project trees and compute canonical here() + recipe hashes.
	collatz_objs, collatz_trees, collatz_here := tutorial_read_project_tree(TUTORIAL_COLLATZ_DIR) or_return
	defer tutorial_free_project_tree(collatz_objs, collatz_trees)
	db_objs, db_trees, db_here := tutorial_read_project_tree(TUTORIAL_DB_BROWSER_DIR) or_return
	defer tutorial_free_project_tree(db_objs, db_trees)
	se_objs, se_trees, se_here := tutorial_read_project_tree(TUTORIAL_STORE_EXPLORER_DIR) or_return
	defer tutorial_free_project_tree(se_objs, se_trees)

	db_project_lex, db_lex_err := os.read_entire_file(TUTORIAL_DB_BROWSER_DIR + "/project.lex", context.temp_allocator)
	if db_lex_err != nil {
		return nil, false
	}
	se_project_lex, se_lex_err := os.read_entire_file(TUTORIAL_STORE_EXPLORER_DIR + "/project.lex", context.temp_allocator)
	if se_lex_err != nil {
		return nil, false
	}
	db_recipe := tutorial_evaluate_project_recipe(string(db_project_lex), db_here, catalog_lex) or_return
	se_recipe := tutorial_evaluate_project_recipe(string(se_project_lex), se_here, catalog_lex) or_return

	// 3. Write the multi-store STORAGE7 tutorial data disk.
	fixture.data_disk_path = fmt.aprintf("%s/tutorial_data_disk.img", work_dir)
	disk_db_objects := [?]build.Module_File{
		{name = "host.module", bytes = host_bytes},
		{name = "main.db", bytes = main_db_bytes},
		{name = "sqlite.module", bytes = sqlite_bytes},
	}
	stores := [?]build.Data_Disk_Store{
		{name = "collatz", limit = 1024, objects = collatz_objs, trees = collatz_trees},
		{name = "db_browser", limit = 2048, objects = db_objs, trees = db_trees},
		{name = "store_explorer", limit = 2048, objects = se_objs, trees = se_trees},
		{name = "disk-db_browser", limit = disk_process.PRIVATE_STORE_BLOCKS_LIMIT, objects = disk_db_objects[:]},
	}
	if !build.data_disk_write_stores(fixture.data_disk_path, stores[:], build.DATA_DISK_SIZE) {
		return nil, false
	}

	// 4. Start the ephemeral signed QUIC object cache on 127.0.0.1:0.
	signer_seed := tutorial_ed25519_seed(0x41)
	quic_seed := tutorial_ed25519_seed(0x73)
	signer_priv: ed25519.Private_Key
	defer ed25519.private_key_clear(&signer_priv)
	if !ed25519.private_key_set_bytes(&signer_priv, signer_seed[:]) {
		return nil, false
	}
	signer_pub: [object_cache.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&signer_priv, signer_pub[:])

	cache_dir := foundation.join(work_dir, "/cache")
	server, opened := cache_server.cache_server_open(cache_dir, [][32]u8{signer_pub})
	if !opened {
		fmt.eprintln("modustool: tutorial: cannot open local cache server")
		return nil, false
	}
	fixture.cache_server_state = server
	fixture.cache_server_open = true

	// 5. Seed signed blobs, single-entry module output trees, and Tree
	// realisations through the cache server handler (every recipe produced by
	// recipe_spec_of_arguments has output_kind = .Tree with entry "module").
	_, sqlite_seeded := cache_server.cache_server_seed_object(&fixture.cache_server_state, .Blob, sqlite_bytes, signer_seed)
	db_blob_hash, db_seeded := cache_server.cache_server_seed_object(&fixture.cache_server_state, .Blob, db_browser_bytes, signer_seed)
	se_blob_hash, se_seeded := cache_server.cache_server_seed_object(&fixture.cache_server_state, .Blob, store_explorer_bytes, signer_seed)
	db_tree_bytes, db_tree_encoded := tutorial_module_output_tree(db_blob_hash, context.temp_allocator)
	se_tree_bytes, se_tree_encoded := tutorial_module_output_tree(se_blob_hash, context.temp_allocator)
	if !db_tree_encoded || !se_tree_encoded {
		fmt.eprintln("modustool: tutorial: cannot encode canonical module output trees")
		return nil, false
	}
	db_out_hash, db_tree_seeded := cache_server.cache_server_seed_object(&fixture.cache_server_state, .Tree, db_tree_bytes, signer_seed)
	se_out_hash, se_tree_seeded := cache_server.cache_server_seed_object(&fixture.cache_server_state, .Tree, se_tree_bytes, signer_seed)
	_, db_real_seeded := cache_server.cache_server_seed_realisation(&fixture.cache_server_state, db_recipe, db_out_hash, .Tree, signer_seed)
	_, se_real_seeded := cache_server.cache_server_seed_realisation(&fixture.cache_server_state, se_recipe, se_out_hash, .Tree, signer_seed)
	if !sqlite_seeded || !db_seeded || !se_seeded || !db_tree_seeded || !se_tree_seeded || !db_real_seeded || !se_real_seeded {
		fmt.eprintln("modustool: tutorial: failed to seed signed objects or realisations into local cache")
		return nil, false
	}

	running, quic_err := cache_server.cache_quic_start(&fixture.cache_server_state, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	if quic_err != "" || running == nil {
		fmt.eprintfln("modustool: tutorial: cannot start local QUIC cache: %s", quic_err)
		return nil, false
	}
	fixture.cache_quic = running
	fixture.cache_endpoint = running.bound_endpoint

	fixture.bindings = {
		cache_server_key  = tutorial_hex_of(running.public_key),
		cache_signer_key  = tutorial_hex_of(signer_pub),
		collatz_here      = tutorial_hex_of(collatz_here),
		db_browser_here   = tutorial_hex_of(db_here),
		db_browser_recipe = tutorial_hex_of(db_recipe),
		db_browser_output = tutorial_hex_of(db_out_hash),
		db_browser_hash   = tutorial_hex_of(db_blob_hash),
	}
	return fixture, true
}

// tutorial_module_output_tree encodes a canonical MODTREE2 tree containing one
// Object entry named "module" pointing to module_hash.
tutorial_module_output_tree :: proc(module_hash: blake3.Hash, allocator := context.allocator) -> (encoded: []u8, ok: bool) {
	entry, entry_ref := tree_hash.tree_entry_make(.Object, "module", module_hash)
	if entry_ref != .None {
		return nil, false
	}
	entries := [1]tree_hash.Tree_Entry{entry}
	buf := make([]u8, tree_hash.tree_encoded_size(entries[:]), allocator)
	written, enc_ref := tree_hash.tree_encode(entries[:], buf)
	if enc_ref != .None {
		delete(buf, allocator)
		return nil, false
	}
	return buf[:written], true
}

tutorial_film_teardown :: proc(fixture: ^Tutorial_Film_Fixture) {
	if fixture == nil {
		return
	}
	if fixture.cache_quic != nil {
		cache_server.cache_quic_stop(fixture.cache_quic)
		fixture.cache_quic = nil
	}
	if fixture.cache_server_open {
		cache_server.cache_server_destroy(&fixture.cache_server_state)
		fixture.cache_server_open = false
	}
	delete(fixture.bindings.cache_server_key)
	delete(fixture.bindings.cache_signer_key)
	delete(fixture.bindings.collatz_here)
	delete(fixture.bindings.db_browser_here)
	delete(fixture.bindings.db_browser_recipe)
	delete(fixture.bindings.db_browser_output)
	delete(fixture.bindings.db_browser_hash)
	delete(fixture.db_browser_bytes)
	delete(fixture.data_disk_path)
	if fixture.work_dir != "" {
		_ = os.remove_all(fixture.work_dir)
		delete(fixture.work_dir)
	}
	free(fixture)
}
