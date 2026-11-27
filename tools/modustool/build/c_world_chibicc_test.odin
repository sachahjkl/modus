#+build !freestanding
package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import "modustool:foundation"

// Lua ABI matching src/outside/c_programs/lua/modus_lua_entry.c.
@(private = "file")
Test_Lua_Run_Request :: struct {
	arena:                  rawptr,
	arena_size:             i64,
	source:                 cstring,
	output:                 [^]u8,
	output_capacity:        i64,
	diagnostic:             [^]u8,
	diagnostic_capacity:    i64,
	status:                 i64,
	output_length:          i64,
	diagnostic_length:      i64,
	live_bytes_after_close: i64,
}
#assert(size_of(Test_Lua_Run_Request) == 11 * 8)

// SQLite typed ABI matching src/outside/c_programs/sqlite/sqlite.manifest.
@(private = "file")
Test_Sqlite_Open_Options :: struct {
	fresh:          u8,
	read_only:      u8,
	reserved:       [2]u8,
	page_size:      u32,
	random_seed:    u64,
	database_bytes: u64,
	heap_bytes:     u32,
	reserved_2:     u32,
}
#assert(size_of(Test_Sqlite_Open_Options) == 32)

@(private = "file")
Test_Sqlite_Session_Info :: struct {
	version_number: i64,
	database_bytes: u64,
	dirty_pages:    u64,
	page_size:      u32,
	open:           u8,
	read_only:      u8,
	reserved:       [2]u8,
}
#assert(size_of(Test_Sqlite_Session_Info) == 32)

@(private = "file")
Test_Sqlite_Column_Row :: struct {
	column_index:   u32,
	declared_kind:  u8,
	name_length:    u8,
	name_truncated: u8,
	reserved:       u8,
	name:           [64]u8,
}
#assert(size_of(Test_Sqlite_Column_Row) == 72)

@(private = "file")
Test_Sqlite_Cell_Row :: struct {
	row_index:       u32,
	column_index:    u32,
	value_kind:      u8,
	truncated:       u8,
	reserved:        [6]u8,
	integer_or_bits: i64,
	payload_offset:  u32,
	payload_length:  u32,
}
#assert(size_of(Test_Sqlite_Cell_Row) == 32)

@(private = "file")
Test_Sqlite_Query_Summary :: struct {
	column_count:   u32,
	row_count:      u32,
	changes:        i64,
	dirty_pages:    u64,
	database_bytes: u64,
	truncated_rows: u8,
	has_rows:       u8,
	reserved:       [6]u8,
}
#assert(size_of(Test_Sqlite_Query_Summary) == 40)

@(private = "file")
Test_Sqlite_Text_Slice :: struct {
	address: [^]u8,
	count:   u64,
}
#assert(size_of(Test_Sqlite_Text_Slice) == 16)

@(private = "file")
Test_Sqlite_Table_Place :: struct {
	address:  rawptr,
	count:    u64,
	capacity: u64,
}
#assert(size_of(Test_Sqlite_Table_Place) == 24)

@(private = "file")
Test_Sqlite_Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}
#assert(size_of(Test_Sqlite_Answer) == 16)

@(private = "file")
c_world_test_run_lua :: proc(lua_mod: []u8, script: cstring) -> (status: i64, output: string, diag: string, live_bytes: i64, ok: bool) {
	if module.validate(lua_mod) != .None {
		return -1, "", "invalid lua module", -1, false
	}
	head, _ := module.header(lua_mod)
	memory, mem_err := virtual.reserve_and_commit(uint(head.memory_size))
	if mem_err != nil {
		return -1, "", "oom", -1, false
	}
	defer virtual.release(raw_data(memory), uint(head.memory_size))
	module.copy_segments(lua_mod, memory)
	if module.rebase(lua_mod, memory, uintptr(raw_data(memory))) != .None {
		return -1, "", "rebase failed", -1, false
	}
	for index in 1 ..< module.count(lua_mod, .Segments) {
		segment, _ := module.record(lua_mod, .Segments, index, module.Segment)
		if .Execute in segment.flags && !virtual.protect(&memory[segment.memory_offset], uint(segment.memory_size), {.Read, .Execute}) {
			return -1, "", "mprotect failed", -1, false
		}
	}
	base := uintptr(raw_data(memory))
	run_idx := module.export_find(lua_mod, "script_run")
	size_idx := module.export_find(lua_mod, "script_request_size")
	run_addr, run_ok := module.export_address(lua_mod, base, run_idx)
	size_addr, size_ok := module.export_address(lua_mod, base, size_idx)
	if !run_ok || !size_ok {
		return -1, "", "missing exports", -1, false
	}
	script_request_size := (proc "c" () -> i64)(rawptr(size_addr))
	if script_request_size() != size_of(Test_Lua_Run_Request) {
		return -1, "", "request size mismatch", -1, false
	}
	script_run := (proc "c" (req: i64) -> i64)(rawptr(run_addr))

	heap := make([]u8, 4 << 20)
	defer delete(heap)
	out_buf := make([]u8, 4096)
	defer delete(out_buf)
	diag_buf := make([]u8, 4096)
	defer delete(diag_buf)

	req := Test_Lua_Run_Request{
		arena               = raw_data(heap),
		arena_size          = i64(len(heap)),
		source              = script,
		output              = raw_data(out_buf),
		output_capacity     = i64(len(out_buf)),
		diagnostic          = raw_data(diag_buf),
		diagnostic_capacity = i64(len(diag_buf)),
	}
	st := script_run(i64(uintptr(&req)))
	return st, strings.clone(string(out_buf[:max(req.output_length, 0)]), context.temp_allocator), strings.clone(string(diag_buf[:max(req.diagnostic_length, 0)]), context.temp_allocator), req.live_bytes_after_close, true
}

@(private = "file")
c_world_test_run_sqlite :: proc(sqlite_mod: []u8) -> (version: i64, query_sum: i64, integrity: string, ok: bool) {
	if module.validate(sqlite_mod) != .None {
		return 0, 0, "invalid sqlite module", false
	}
	head, _ := module.header(sqlite_mod)
	memory, mem_err := virtual.reserve_and_commit(uint(head.memory_size))
	if mem_err != nil {
		return 0, 0, "oom", false
	}
	defer virtual.release(raw_data(memory), uint(head.memory_size))
	module.copy_segments(sqlite_mod, memory)
	if module.rebase(sqlite_mod, memory, uintptr(raw_data(memory))) != .None {
		return 0, 0, "rebase failed", false
	}
	for index in 1 ..< module.count(sqlite_mod, .Segments) {
		segment, _ := module.record(sqlite_mod, .Segments, index, module.Segment)
		if .Execute in segment.flags && !virtual.protect(&memory[segment.memory_offset], uint(segment.memory_size), {.Read, .Execute}) {
			return 0, 0, "mprotect failed", false
		}
	}
	base := uintptr(raw_data(memory))
	find_fn :: proc(file: []u8, b: uintptr, name: string) -> (addr: uintptr, found: bool) {
		idx := module.export_find(file, name)
		if idx == 0 {
			return 0, false
		}
		return module.export_address(file, b, idx)
	}
	ver_addr := find_fn(sqlite_mod, base, "version_number") or_return
	open_addr := find_fn(sqlite_mod, base, "session_open") or_return
	exec_addr := find_fn(sqlite_mod, base, "session_execute") or_return
	close_addr := find_fn(sqlite_mod, base, "session_close") or_return

	version_fn := (proc "c" () -> i64)(rawptr(ver_addr))
	open_fn := (proc "c" (options: ^Test_Sqlite_Open_Options, database: ^Test_Sqlite_Table_Place, info: ^Test_Sqlite_Table_Place, err: ^errors.Error_Record) -> Test_Sqlite_Answer)(rawptr(open_addr))
	exec_fn := (proc "c" (sql: ^Test_Sqlite_Text_Slice, database: ^Test_Sqlite_Table_Place, columns: ^Test_Sqlite_Table_Place, cells: ^Test_Sqlite_Table_Place, payload: ^Test_Sqlite_Table_Place, diag: ^Test_Sqlite_Table_Place, summary: ^Test_Sqlite_Table_Place, err: ^errors.Error_Record) -> Test_Sqlite_Answer)(rawptr(exec_addr))
	close_fn := (proc "c" (database: ^Test_Sqlite_Table_Place, err: ^errors.Error_Record) -> Test_Sqlite_Answer)(rawptr(close_addr))

	version = version_fn()
	if version != 3054001 {
		return version, 0, "wrong version", false
	}

	db_buf := make([]u8, 256 * 1024)
	defer delete(db_buf)
	db_place := Test_Sqlite_Table_Place{address = raw_data(db_buf), count = u64(len(db_buf)), capacity = u64(len(db_buf))}
	info_rows: [2]Test_Sqlite_Session_Info
	info_place := Test_Sqlite_Table_Place{address = &info_rows[0], count = 0, capacity = len(info_rows)}
	opts := Test_Sqlite_Open_Options{fresh = 1, page_size = 4096, random_seed = 42, heap_bytes = 2 * 1024 * 1024}
	err_rec: errors.Error_Record
	open_ans := open_fn(&opts, &db_place, &info_place, &err_rec)
	if open_ans.outcome != .Succeeded {
		return version, 0, fmt.tprintf("open failed outcome=%v kind=%d arg=%d val=%d lim=%d found=%d", open_ans.outcome, err_rec.kind, err_rec.argument, err_rec.value, err_rec.limit, err_rec.found), false
	}

	cols: [16]Test_Sqlite_Column_Row
	cells: [64]Test_Sqlite_Cell_Row
	payload_buf := make([]u8, 4096)
	defer delete(payload_buf)
	diag_buf := make([]u8, 1024)
	defer delete(diag_buf)
	summaries: [4]Test_Sqlite_Query_Summary

	run_sql :: proc(
		exec_fn: proc "c" (sql: ^Test_Sqlite_Text_Slice, database: ^Test_Sqlite_Table_Place, columns: ^Test_Sqlite_Table_Place, cells: ^Test_Sqlite_Table_Place, payload: ^Test_Sqlite_Table_Place, diag: ^Test_Sqlite_Table_Place, summary: ^Test_Sqlite_Table_Place, err: ^errors.Error_Record) -> Test_Sqlite_Answer,
		text: string,
		db_place: ^Test_Sqlite_Table_Place,
		cols: []Test_Sqlite_Column_Row,
		cells: []Test_Sqlite_Cell_Row,
		payload_buf: []u8,
		diag_buf: []u8,
		summaries: []Test_Sqlite_Query_Summary,
	) -> (ans: Test_Sqlite_Answer, cell_count: u64, payload_len: u64) {
		sql_slice := Test_Sqlite_Text_Slice{address = raw_data(text), count = u64(len(text))}
		col_p := Test_Sqlite_Table_Place{address = raw_data(cols), capacity = u64(len(cols))}
		cell_p := Test_Sqlite_Table_Place{address = raw_data(cells), capacity = u64(len(cells))}
		pay_p := Test_Sqlite_Table_Place{address = raw_data(payload_buf), capacity = u64(len(payload_buf))}
		diag_p := Test_Sqlite_Table_Place{address = raw_data(diag_buf), capacity = u64(len(diag_buf))}
		sum_p := Test_Sqlite_Table_Place{address = raw_data(summaries), capacity = u64(len(summaries))}
		err_r: errors.Error_Record
		ans = exec_fn(&sql_slice, db_place, &col_p, &cell_p, &pay_p, &diag_p, &sum_p, &err_r)
		return ans, cell_p.count, pay_p.count
	}

	ddl_ans, _, _ := run_sql(exec_fn, "CREATE TABLE items(k INTEGER PRIMARY KEY, v INTEGER); INSERT INTO items VALUES(1, 10),(2, 32);", &db_place, cols[:], cells[:], payload_buf, diag_buf, summaries[:])
	if ddl_ans.outcome != .Succeeded {
		return version, 0, "ddl/insert failed", false
	}

	sel_ans, sel_cells, _ := run_sql(exec_fn, "SELECT SUM(v) FROM items;", &db_place, cols[:], cells[:], payload_buf, diag_buf, summaries[:])
	if sel_ans.outcome != .Succeeded || sel_cells != 1 {
		return version, 0, "select failed", false
	}
	query_sum = cells[0].integer_or_bits

	ic_ans, ic_cells, _ := run_sql(exec_fn, "PRAGMA integrity_check;", &db_place, cols[:], cells[:], payload_buf, diag_buf, summaries[:])
	if ic_ans.outcome != .Succeeded || ic_cells != 1 {
		return version, query_sum, "integrity_check failed", false
	}
	ic_off := int(cells[0].payload_offset)
	ic_len := int(cells[0].payload_length)
	if ic_off + ic_len <= len(payload_buf) {
		integrity = strings.clone(string(payload_buf[ic_off:ic_off + ic_len]), context.temp_allocator)
	}

	close_ans := close_fn(&db_place, &err_rec)
	if close_ans.outcome != .Succeeded {
		return version, query_sum, "close failed", false
	}
	return version, query_sum, integrity, true
}

@(test)
chibicc_compiles_upstream_c_libraries_and_refuses_bad_inputs :: proc(t: ^testing.T) {
	// Adversarial refusals first: invalid compiler module and empty assembly text.
	_, bad_comp_rep, bad_comp_ok := c_world_build_recipe_with_chibicc(nil, .Lua)
	testing.expect(t, !bad_comp_ok, "nil compiler module must be refused")
	testing.expect(t, len(bad_comp_rep.diagnostic) > 0)

	_, _, empty_asm_ok := c_world_assemble_with_manifest("empty", "", {})
	testing.expect(t, !empty_asm_ok, "empty assembly text must be refused")

	chibicc_folder := os.get_env(foundation.CHIBICC.variable, context.temp_allocator)
	if chibicc_folder == "" {
		return
	}
	temp_base, _ := os.temp_dir(context.temp_allocator)
	work := fmt.aprintf("%s/modus_chibicc_libs_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	defer delete(work)
	_ = os.remove_all(work)
	defer os.remove_all(work)

	// Build self-hosted Stage 1 chibicc so upstream C libraries are compiled
	// by chibicc itself (not host clang).
	program, prog_ok := c_self_host_program(chibicc_folder)
	if !testing.expect(t, prog_ok, "must load chibicc program") {
		return
	}
	stage_zero, s0_ok := c_self_host_stage_zero(work)
	if !testing.expect(t, s0_ok, "must build chibicc stage 0") {
		return
	}
	defer delete(stage_zero)
	texts_zero, tz_ok := c_stage_build(stage_zero, .Zero, program, foundation.join(work, "/s0_texts"))
	if !testing.expect(t, tz_ok, "stage 0 must compile chibicc") {
		return
	}
	stage_one, s1_ok := c_program_assemble(texts_zero, program)
	if !testing.expect(t, s1_ok, "assembler must assemble stage 1 chibicc") {
		return
	}
	defer delete(stage_one)

	// 1. Lua 5.4.7 compiled with self-hosted Stage 1 chibicc + modus assembler.
	if os.get_env("LUA_SOURCE", context.temp_allocator) != "" {
		lua_mod, lua_rep, lua_ok := c_world_build_recipe_with_chibicc(stage_one, .Lua)
		testing.expectf(t, lua_ok, "chibicc must compile Lua 5.4.7 (unit=%s): %s", lua_rep.failing_unit, lua_rep.diagnostic)
		if lua_ok {
			defer delete(lua_mod)
			fmt.printfln("chibicc built lua 5.4.7: %d units, %d B asm, %d B module, hash %s", lua_rep.unit_count, lua_rep.assembly_bytes, lua_rep.module_size, hash_as_hexadecimal(lua_rep.module_hash))
			st, out, diag, live, ran := c_world_test_run_lua(lua_mod, `
local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end
local ok, err = pcall(function() error("boom") end)
local root = math.floor(math.sqrt(144) + 0.5)
print(fib(10), ok, root, utf8.len("modus"))
`)
			testing.expectf(t, ran && st == 0, "chibicc-built Lua script failed (st=%d, diag=%q)", st, diag)
			testing.expect_value(t, out, "55\tfalse\t12\t5\n")
			testing.expect_value(t, live, i64(0))
			// Syntax error refusal must return LUA_ERRSYNTAX (3) and zero leaked heap.
			bad_st, _, _, bad_live, bad_ran := c_world_test_run_lua(lua_mod, "function broken( end")
			testing.expect(t, bad_ran && bad_st == 3, "chibicc-built Lua must refuse syntax error with status 3")
			testing.expect_value(t, bad_live, i64(0))
		}
	}

	// 2. zstd 1.5.7 compiled with self-hosted Stage 1 chibicc + modus assembler.
	if os.get_env("ZSTD_SOURCE", context.temp_allocator) != "" {
		zstd_mod, zstd_rep, zstd_ok := c_world_build_recipe_with_chibicc(stage_one, .Zstd)
		testing.expectf(t, zstd_ok, "chibicc must compile zstd 1.5.7 (unit=%s): %s", zstd_rep.failing_unit, zstd_rep.diagnostic)
		if zstd_ok {
			defer delete(zstd_mod)
			fmt.printfln("chibicc built zstd 1.5.7: %d units, %d B asm, %d B module, hash %s", zstd_rep.unit_count, zstd_rep.assembly_bytes, zstd_rep.module_size, hash_as_hexadecimal(zstd_rep.module_hash))
			comp_sz, frame_hash, ref_ok := c_world_zstd_reference_frame(zstd_mod)
			testing.expect(t, ref_ok, "chibicc-built zstd must compress and decompress losslessly with zero leak")
			// Compare compressed frame hash against host clang-built zstd!
			clang_zstd, cz_ok := c_world_build_recipe_module(.Zstd, work)
			if testing.expect(t, cz_ok, "clang reference zstd builds") {
				defer delete(clang_zstd)
				clang_sz, clang_hash, cref_ok := c_world_zstd_reference_frame(clang_zstd)
				testing.expect(t, cref_ok)
				testing.expect_value(t, comp_sz, clang_sz)
				testing.expect_value(t, frame_hash, clang_hash)
			}
		}
	}

	// 3. SQLite 3.54.1 compiled with self-hosted Stage 1 chibicc + modus assembler.
	if os.get_env("SQLITE_SOURCE", context.temp_allocator) != "" {
		sqlite_mod, sqlite_rep, sqlite_ok := c_world_build_recipe_with_chibicc(stage_one, .Sqlite)
		testing.expectf(t, sqlite_ok, "chibicc must compile SQLite 3.54.1 (unit=%s): %s", sqlite_rep.failing_unit, sqlite_rep.diagnostic)
		if sqlite_ok {
			defer delete(sqlite_mod)
			fmt.printfln("chibicc built sqlite 3.54.1: %d units, %d B asm, %d B module, hash %s", sqlite_rep.unit_count, sqlite_rep.assembly_bytes, sqlite_rep.module_size, hash_as_hexadecimal(sqlite_rep.module_hash))
			testing.expect_value(t, module.validate(sqlite_mod), module.Error.None)
			testing.expect(t, sqlite_rep.module_hash != blake3.Hash{})
			ver, qsum, ic, sq_ok := c_world_test_run_sqlite(sqlite_mod)
			testing.expectf(t, sq_ok, "chibicc-built SQLite must execute SQL and PRAGMA integrity_check (ver=%d, sum=%d, ic=%q)", ver, qsum, ic)
			testing.expect_value(t, ver, i64(3054001))
			testing.expect_value(t, qsum, i64(42))
			testing.expect_value(t, ic, "ok")
		}
	}
}
