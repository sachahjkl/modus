#+build !freestanding
// The host test of the real C programs: when the flake names the pinned
// source of a recipe (SQLITE_SOURCE, LUA_SOURCE, ZSTD_SOURCE), the test builds
// the module of the recipe with the build of this folder, proves that it
// imports nothing and holds no instruction that reaches the host, then runs
// SQL, Lua scripts and zstd frames through its exports
// (src/md/features/c_compiler.md, "The C programs").
package c_programs

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"

Real_Program :: enum {
	Sqlite,
	Lua,
	Zstd,
}

REAL_PROGRAM_RECIPES := [Real_Program]Recipe_Text {
	.Sqlite = RECIPES[0],
	.Lua    = RECIPES[1],
	.Zstd   = RECIPES[2],
}

// The variable of the environment that names the patched root of the source.
REAL_PROGRAM_SOURCE_VARIABLES := [Real_Program]string {
	.Sqlite = "SQLITE_SOURCE",
	.Lua    = "LUA_SOURCE",
	.Zstd   = "ZSTD_SOURCE",
}

// real_program_plan reads a recipe: the files of the source with the flags,
// the definitions, the include folders and the forced headers of the recipe;
// the adapters with the same flags and no forced header.
real_program_plan :: proc(recipe_text: string, source_root: string, allocator := context.temp_allocator) -> (plan: Module_Plan, problem: string) {
	context.allocator = allocator
	flags := make([dynamic]string)
	compiled := make([dynamic]string)
	adapters := make([dynamic]string)
	forced := make([dynamic]string)
	manifest_path := ""
	include_flags := make([dynamic]string)
	for line in strings.split_lines(recipe_text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		colon := strings.index(trimmed, ": ")
		key, known := recipe_key_of_word(trimmed[:max(colon, 0)])
		if colon <= 0 || !known {
			return {}, fmt.aprintf("the line %q has no known key", trimmed)
		}
		value := trimmed[colon + 2:]
		folder_value := strings.concatenate({folder_of_programs(), "/", value})
		switch key {
		case .Flag:
			append(&flags, value)
		case .Define:
			append(&flags, strings.concatenate({"-D", value}))
		case .Include:
			append(&include_flags, "-I", folder_value)
		case .Force_Include:
			append(&forced, "-include", folder_value)
		case .Compile:
			append(&compiled, strings.concatenate({source_root, "/", value}))
		case .Adapter:
			append(&adapters, folder_value)
		case .Manifest:
			manifest_path = folder_value
		case .Recipe, .Version, .Source, .Source_Hash, .Unpack, .Root, .Patch, .Test:
		}
	}
	// The folders of this folder come before the root of the source, so a
	// header of the thin libc wins over a header of the same name there.
	append(&flags, ..include_flags[:])
	append(&flags, "-I", source_root)
	manifest_text, read_error := os.read_entire_file(manifest_path, allocator)
	if read_error != nil {
		return {}, fmt.aprintf("cannot read the manifest %s", manifest_path)
	}
	source_flags := make([dynamic]string)
	append(&source_flags, ..flags[:])
	append(&source_flags, ..forced[:])
	units := make([dynamic]C_Unit)
	for source in compiled {
		append(&units, C_Unit{source, source_flags[:]})
	}
	for adapter in adapters {
		append(&units, C_Unit{adapter, flags[:]})
	}
	header_folders := make([]string, 2)
	header_folders[0] = folder_of_programs()
	header_folders[1] = source_root
	return {units[:], string(manifest_text), header_folders}, ""
}

Real_Build :: struct {
	once:        sync.Once,
	program:     Real_Program,
	source_root: string, // "" when the flake gave no source.
	built:       Built_Module,
}

@(private = "file")
real_builds: [Real_Program]Real_Build

// real_module builds the module of a program once for the whole run. It
// gives nil when the environment names no source of the program.
real_module :: proc(program: Real_Program) -> ^Built_Module {
	build_of_program := &real_builds[program]
	build_of_program.program = program
	sync.once_do_with_data(&build_of_program.once, proc(data: rawptr) {
		build_of_program := (^Real_Build)(data)
		context.allocator = runtime.heap_allocator()
		root := os.get_env(REAL_PROGRAM_SOURCE_VARIABLES[build_of_program.program], context.allocator)
		build_of_program.source_root = root
		if root == "" {
			return
		}
		plan, problem := real_program_plan(REAL_PROGRAM_RECIPES[build_of_program.program].text, root)
		if problem != "" {
			build_of_program.built.problem = problem
			return
		}
		build_of_program.built = build_module(plan, context.allocator)
	}, build_of_program)
	if build_of_program.source_root == "" {
		return nil
	}
	return &build_of_program.built
}

// load_real_program gives the loaded module, or false with a line in the log
// when the environment names no source: the shells and the host checks of the
// flake name each one.
load_real_program :: proc(t: ^testing.T, program: Real_Program) -> (loaded: Loaded_Module, ok: bool) {
	built := real_module(program)
	if built == nil {
		fmt.printfln("%v: %s is not set; the test of the real program does not run", program, REAL_PROGRAM_SOURCE_VARIABLES[program])
		return
	}
	return load_built_module(t, built)
}

@(test)
real_programs_build_freestanding_with_no_import_and_no_host_instruction :: proc(t: ^testing.T) {
	for program in Real_Program {
		built := real_module(program)
		if built == nil {
			fmt.printfln("%v: %s is not set; its build is not checked", program, REAL_PROGRAM_SOURCE_VARIABLES[program])
			continue
		}
		if !testing.expectf(t, built.problem == "", "%v: the build failed: %s", program, built.problem) {
			continue
		}
		testing.expectf(t, built.undefined_symbols == "", "%v: the object needs symbols that no file defines:\n%s", program, built.undefined_symbols)
		testing.expectf(t, len(built.host_instruction_lines) == 0, "%v: the object holds instructions that reach the host: %v", program, built.host_instruction_lines)
		testing.expectf(t, len(built.headers_outside) == 0, "%v: the compiler read headers outside the source and this folder: %v", program, built.headers_outside)
		testing.expect_value(t, module.validate(built.file), module.Error.None)
		// Record 0 of a table is the empty record: a count of 1 is no import.
		testing.expect_value(t, module.count(built.file, .Imports), u32(1))
		testing.expect(t, module.count(built.file, .Import_Slots) <= 1, "the module has no import slot")
		fmt.printfln("%v: module of %d bytes, %d instructions, %d exports, %d rebase words", program, len(built.file), built.instruction_count, module.count(built.file, .Exports) - 1, module.count(built.file, .Rebases))
	}
}

// ---- SQLite ----------------------------------------------------------------------------

Sqlite_Value_Kind :: enum u8 {
	None      = 0,
	Null      = 1,
	Integer   = 2,
	Real_Bits = 3,
	Text      = 4,
	Blob      = 5,
}

Sqlite_Open_Options :: struct {
	fresh:          u8,
	read_only:      u8,
	reserved:       [2]u8,
	page_size:      u32,
	random_seed:    u64,
	database_bytes: u64,
	heap_bytes:     u32,
	reserved_2:     u32,
}
#assert(size_of(Sqlite_Open_Options) == 32)

Sqlite_Session_Info :: struct {
	version_number: i64,
	database_bytes: u64,
	dirty_pages:    u64,
	page_size:      u32,
	open:           u8,
	read_only:      u8,
	reserved:       [2]u8,
}
#assert(size_of(Sqlite_Session_Info) == 32)

Sqlite_Column_Row :: struct {
	column_index:   u32,
	declared_kind:  u8,
	name_length:    u8,
	name_truncated: u8,
	reserved:       u8,
	name:           [64]u8,
}
#assert(size_of(Sqlite_Column_Row) == 72)

Sqlite_Cell_Row :: struct {
	row_index:       u32,
	column_index:    u32,
	value_kind:      u8,
	truncated:       u8,
	reserved:        [6]u8,
	integer_or_bits: i64,
	payload_offset:  u32,
	payload_length:  u32,
}
#assert(size_of(Sqlite_Cell_Row) == 32)

Sqlite_Query_Summary :: struct {
	column_count:   u32,
	row_count:      u32,
	changes:        i64,
	dirty_pages:    u64,
	database_bytes: u64,
	truncated_rows: u8,
	has_rows:       u8,
	reserved:       [6]u8,
}
#assert(size_of(Sqlite_Query_Summary) == 40)

Sqlite_Dirty_Range_Row :: struct {
	byte_offset: u64,
	byte_length: u64,
}
#assert(size_of(Sqlite_Dirty_Range_Row) == 16)

Sqlite_Text_Slice :: struct {
	address: [^]u8,
	count:   u64,
}
#assert(size_of(Sqlite_Text_Slice) == 16)

Sqlite_Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}
#assert(size_of(Sqlite_Answer) == 16)

sqlite_export_ptr :: proc(loaded: Loaded_Module, name: string) -> rawptr {
	index := module.export_find(loaded.file, name)
	fmt.assertf(index != 0, "sqlite module has no export %s", name)
	address, found := module.export_address(loaded.file, uintptr(raw_data(loaded.memory)), index)
	fmt.assertf(found, "sqlite export %s has no address", name)
	return rawptr(address)
}

sqlite_open_call :: proc(loaded: Loaded_Module, opts: ^Sqlite_Open_Options, db_buf: []u8) -> (ans: Sqlite_Answer, info: Sqlite_Session_Info, err: errors.Error_Record) {
	db_place := module.Table_Place{address = u64(uintptr(raw_data(db_buf))), count = u64(len(db_buf)), capacity = u64(len(db_buf))}
	info_buf: [1]Sqlite_Session_Info
	info_place := module.Table_Place{address = u64(uintptr(&info_buf[0])), count = 0, capacity = 1}
	fn := (proc "c" (^Sqlite_Open_Options, ^module.Table_Place, ^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_open"))
	ans = fn(opts, &db_place, &info_place, &err)
	if info_place.count >= 1 {
		info = info_buf[0]
	}
	return
}

Sqlite_Exec_Result :: struct {
	answer:     Sqlite_Answer,
	err:        errors.Error_Record,
	summary:    Sqlite_Query_Summary,
	columns:    []Sqlite_Column_Row,
	cells:      []Sqlite_Cell_Row,
	payload:    []u8,
	diagnostic: string,
}

sqlite_exec_call :: proc(
	loaded: Loaded_Module,
	sql: string,
	db_buf: []u8,
	col_buf: []Sqlite_Column_Row,
	cell_buf: []Sqlite_Cell_Row,
	payload_buf: []u8,
	diag_buf: []u8,
) -> (res: Sqlite_Exec_Result) {
	sql_slice := Sqlite_Text_Slice{address = raw_data(transmute([]u8)sql), count = u64(len(sql))}
	db_place := module.Table_Place{address = u64(uintptr(raw_data(db_buf))), count = u64(len(db_buf)), capacity = u64(len(db_buf))}
	col_place := module.Table_Place{address = u64(uintptr(raw_data(col_buf))), count = 0, capacity = u64(len(col_buf))}
	cell_place := module.Table_Place{address = u64(uintptr(raw_data(cell_buf))), count = 0, capacity = u64(len(cell_buf))}
	pay_place := module.Table_Place{address = u64(uintptr(raw_data(payload_buf))), count = 0, capacity = u64(len(payload_buf))}
	diag_place := module.Table_Place{address = u64(uintptr(raw_data(diag_buf))), count = 0, capacity = u64(len(diag_buf))}
	sum_buf: [1]Sqlite_Query_Summary
	sum_place := module.Table_Place{address = u64(uintptr(&sum_buf[0])), count = 0, capacity = 1}
	fn := (proc "c" (
		^Sqlite_Text_Slice,
		^module.Table_Place,
		^module.Table_Place,
		^module.Table_Place,
		^module.Table_Place,
		^module.Table_Place,
		^module.Table_Place,
		^errors.Error_Record,
	) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_execute"))
	res.answer = fn(&sql_slice, &db_place, &col_place, &cell_place, &pay_place, &diag_place, &sum_place, &res.err)
	if sum_place.count >= 1 {
		res.summary = sum_buf[0]
	}
	res.columns = col_buf[:min(int(col_place.count), len(col_buf))]
	res.cells = cell_buf[:min(int(cell_place.count), len(cell_buf))]
	res.payload = payload_buf[:min(int(pay_place.count), len(payload_buf))]
	res.diagnostic = string(diag_buf[:min(int(diag_place.count), len(diag_buf))])
	return
}

sqlite_dirty_ranges_call :: proc(loaded: Loaded_Module, out_buf: []Sqlite_Dirty_Range_Row) -> (ans: Sqlite_Answer, ranges: []Sqlite_Dirty_Range_Row, err: errors.Error_Record) {
	place := module.Table_Place{address = u64(uintptr(raw_data(out_buf))), count = 0, capacity = u64(len(out_buf))}
	fn := (proc "c" (^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_dirty_ranges"))
	ans = fn(&place, &err)
	ranges = out_buf[:min(int(place.count), len(out_buf))]
	return
}

sqlite_mark_synced_call :: proc(loaded: Loaded_Module) -> (ans: Sqlite_Answer, err: errors.Error_Record) {
	fn := (proc "c" (^errors.Error_Record) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_mark_synced"))
	ans = fn(&err)
	return
}

sqlite_info_call :: proc(loaded: Loaded_Module) -> (ans: Sqlite_Answer, info: Sqlite_Session_Info, err: errors.Error_Record) {
	buf: [1]Sqlite_Session_Info
	place := module.Table_Place{address = u64(uintptr(&buf[0])), count = 0, capacity = 1}
	fn := (proc "c" (^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_info"))
	ans = fn(&place, &err)
	if place.count >= 1 {
		info = buf[0]
	}
	return
}

sqlite_last_diag_call :: proc(loaded: Loaded_Module, buf: []u8) -> (ans: Sqlite_Answer, text: string, err: errors.Error_Record) {
	place := module.Table_Place{address = u64(uintptr(raw_data(buf))), count = 0, capacity = u64(len(buf))}
	fn := (proc "c" (^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_last_diagnostic"))
	ans = fn(&place, &err)
	text = string(buf[:min(int(place.count), len(buf))])
	return
}

sqlite_close_call :: proc(loaded: Loaded_Module, db_buf: []u8) -> (ans: Sqlite_Answer, err: errors.Error_Record) {
	db_place := module.Table_Place{address = u64(uintptr(raw_data(db_buf))), count = u64(len(db_buf)), capacity = u64(len(db_buf))}
	fn := (proc "c" (^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(sqlite_export_ptr(loaded, "session_close"))
	ans = fn(&db_place, &err)
	return
}

sqlite_cell_text :: proc(cell: Sqlite_Cell_Row, payload: []u8) -> string {
	return string(payload[cell.payload_offset:][:cell.payload_length])
}

sqlite_cell_f64 :: proc(cell: Sqlite_Cell_Row) -> f64 {
	return transmute(f64)u64(cell.integer_or_bits)
}

sqlite_sync_to_store :: proc(t: ^testing.T, loaded: Loaded_Module, db_buf: []u8, store_backing: ^[dynamic]u8, db_bytes: u64) {
	ranges_buf: [256]Sqlite_Dirty_Range_Row
	ans, ranges, _ := sqlite_dirty_ranges_call(loaded, ranges_buf[:])
	testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Succeeded)
	// Every emitted dirty range must be strictly clamped to db_bytes.
	for r in ranges {
		testing.expect(t, r.byte_length > 0, "dirty range has non-zero length")
		testing.expect(t, r.byte_offset <= db_bytes && r.byte_length <= db_bytes - r.byte_offset, "dirty range clamped to database_bytes")
	}
	if u64(len(store_backing^)) < db_bytes {
		resize(store_backing, int(db_bytes))
	}
	for r in ranges {
		copy(store_backing[r.byte_offset:][:r.byte_length], db_buf[r.byte_offset:][:r.byte_length])
	}
	// Simulate atomic storage.set_size + storage.commit.
	resize(store_backing, int(db_bytes))
	mark_ans, _ := sqlite_mark_synced_call(loaded)
	testing.expect_value(t, mark_ans.outcome, call_outcome.Call_Outcome.Succeeded)
}

@(test)
real_sqlite_runs_queries_over_the_modus_vfs :: proc(t: ^testing.T) {
	loaded, ok := load_real_program(t, .Sqlite)
	if !ok {
		return
	}
	defer unload_module(loaded)

	// Verify strict .Read_Only_After_Load segment stays present (Option B RELRO).
	has_relro := false
	for idx in 1 ..< module.count(loaded.file, .Segments) {
		seg, _ := module.record(loaded.file, .Segments, idx, module.Segment)
		if .Read_Only_After_Load in seg.flags {
			has_relro = true
		}
	}
	testing.expect(t, has_relro, "sqlite preserves Read_Only_After_Load segment")
	testing.expect_value(t, call(loaded, "version_number"), i64(3054001))

	db_buf := make([]u8, 4 << 20)
	defer delete(db_buf)
	col_buf := make([]Sqlite_Column_Row, 64)
	defer delete(col_buf)
	cell_buf := make([]Sqlite_Cell_Row, 16384)
	defer delete(cell_buf)
	pay_buf := make([]u8, 256 << 10)
	defer delete(pay_buf)
	diag_buf := make([]u8, 512)
	defer delete(diag_buf)

	// ---- Refusals first (edges before success) ----
	{
		// Closed-state refusals.
		info_ans, info, _ := sqlite_info_call(loaded)
		testing.expect_value(t, info_ans.outcome, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, info.open, u8(0))

		exec_res := sqlite_exec_call(loaded, "SELECT 1;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, exec_res.answer.outcome, call_outcome.Call_Outcome.Wrong_State)

		ranges_buf: [8]Sqlite_Dirty_Range_Row
		dr_ans, _, _ := sqlite_dirty_ranges_call(loaded, ranges_buf[:])
		testing.expect_value(t, dr_ans.outcome, call_outcome.Call_Outcome.Wrong_State)

		ms_ans, _ := sqlite_mark_synced_call(loaded)
		testing.expect_value(t, ms_ans.outcome, call_outcome.Call_Outcome.Wrong_State)

		cl_ans, _ := sqlite_close_call(loaded, db_buf)
		testing.expect_value(t, cl_ans.outcome, call_outcome.Call_Outcome.Wrong_State)

		// Option validation refusals.
		ans: Sqlite_Answer
		err: errors.Error_Record
		bad_fresh := Sqlite_Open_Options{fresh = 2}
		ans, _, err = sqlite_open_call(loaded, &bad_fresh, db_buf)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)

		bad_ro := Sqlite_Open_Options{fresh = 1, read_only = 1}
		ans, _, err = sqlite_open_call(loaded, &bad_ro, db_buf)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)

		bad_page := Sqlite_Open_Options{fresh = 1, page_size = 1024}
		ans, _, err = sqlite_open_call(loaded, &bad_page, db_buf)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)
		testing.expect_value(t, err.kind, i64(errors.Kind.Not_Multiple))

		small_heap := Sqlite_Open_Options{fresh = 1, heap_bytes = 1024}
		ans, _, err = sqlite_open_call(loaded, &small_heap, db_buf)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)
		testing.expect_value(t, err.kind, i64(errors.Kind.Too_Small))

		huge_heap := Sqlite_Open_Options{fresh = 1, heap_bytes = 8 << 20}
		ans, _, err = sqlite_open_call(loaded, &huge_heap, db_buf)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)
		testing.expect_value(t, err.kind, i64(errors.Kind.Too_Long))

		small_db := Sqlite_Open_Options{fresh = 1}
		ans, _, err = sqlite_open_call(loaded, &small_db, db_buf[:1024])
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)
		testing.expect_value(t, err.kind, i64(errors.Kind.Too_Small))

		fresh_with_size := Sqlite_Open_Options{fresh = 1, database_bytes = 4096}
		ans, _, _ = sqlite_open_call(loaded, &fresh_with_size, db_buf)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Argument_Refused)

		// Corrupted database bytes refused on open with Data_Damaged.
		corrupt := make([]u8, 8192)
		defer delete(corrupt)
		for &b, idx in corrupt {
			b = u8((idx * 37 + 13) & 0xFF)
		}
		corrupt_opts := Sqlite_Open_Options{fresh = 0, database_bytes = 8192}
		ans, _, err = sqlite_open_call(loaded, &corrupt_opts, corrupt)
		testing.expect_value(t, ans.outcome, call_outcome.Call_Outcome.Data_Damaged)
		testing.expect_value(t, err.kind, i64(errors.Kind.Damaged))
	}

	// ---- Open fresh database & verify double-open refusal ----
	open_opts := Sqlite_Open_Options{fresh = 1, page_size = 4096}
	open_ans, open_info, _ := sqlite_open_call(loaded, &open_opts, db_buf)
	if !testing.expect_value(t, open_ans.outcome, call_outcome.Call_Outcome.Succeeded) {
		return
	}
	testing.expect_value(t, open_info.open, u8(1))
	testing.expect_value(t, open_info.page_size, u32(4096))

	dup_ans, _, _ := sqlite_open_call(loaded, &open_opts, db_buf)
	testing.expect_value(t, dup_ans.outcome, call_outcome.Call_Outcome.Wrong_State)

	// ---- Typed values: NULL, INTEGER, REAL, TEXT with | and \n, BLOB, long column name ----
	store_backing := make([dynamic]u8)
	defer delete(store_backing)

	res := sqlite_exec_call(loaded, "CREATE TABLE typed(id INTEGER PRIMARY KEY, label TEXT, score REAL, raw BLOB, note TEXT);", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, res.summary.dirty_pages > 0, "CREATE TABLE dirties pages")
	sqlite_sync_to_store(t, loaded, db_buf, &store_backing, res.summary.database_bytes)

	// Text containing pipe, newline, quotes, and UTF-8; binary blob with 0x00 and 0xFF.
	res = sqlite_exec_call(loaded, "INSERT INTO typed(id, label, score, raw, note) VALUES (1, 'a|b\nc\"d''e é', -12.75, X'000102FF7F', NULL), (2, '', 0.0, X'', 'ok');", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, res.summary.changes, i64(2))

	res = sqlite_exec_call(loaded, "SELECT id, label, score, raw, note, 1 AS very_long_column_name_that_definitely_exceeds_sixty_four_utf8_bytes_for_truncation_test FROM typed ORDER BY id;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, res.summary.column_count, u32(6))
	testing.expect_value(t, res.summary.row_count, u32(2))
	testing.expect_value(t, res.summary.has_rows, u8(1))
	testing.expect_value(t, res.summary.truncated_rows, u8(0))
	testing.expect_value(t, len(res.columns), 6)
	testing.expect_value(t, res.columns[0].declared_kind, u8(Sqlite_Value_Kind.Integer))
	testing.expect_value(t, res.columns[1].declared_kind, u8(Sqlite_Value_Kind.Text))
	testing.expect_value(t, res.columns[2].declared_kind, u8(Sqlite_Value_Kind.Real_Bits))
	testing.expect_value(t, res.columns[3].declared_kind, u8(Sqlite_Value_Kind.Blob))
	testing.expect_value(t, res.columns[5].name_length, u8(64))
	testing.expect_value(t, res.columns[5].name_truncated, u8(1))

	// Row 0 checks.
	testing.expect_value(t, res.cells[0].value_kind, u8(Sqlite_Value_Kind.Integer))
	testing.expect_value(t, res.cells[0].integer_or_bits, i64(1))
	testing.expect_value(t, res.cells[1].value_kind, u8(Sqlite_Value_Kind.Text))
	testing.expect_value(t, sqlite_cell_text(res.cells[1], res.payload), "a|b\nc\"d'e é")
	testing.expect_value(t, res.cells[2].value_kind, u8(Sqlite_Value_Kind.Real_Bits))
	testing.expect_value(t, sqlite_cell_f64(res.cells[2]), f64(-12.75))
	testing.expect_value(t, res.cells[3].value_kind, u8(Sqlite_Value_Kind.Blob))
	testing.expect_value(t, res.cells[3].integer_or_bits, i64(5))
	blob_bytes := res.payload[res.cells[3].payload_offset:][:res.cells[3].payload_length]
	testing.expect(t, len(blob_bytes) == 5 && blob_bytes[0] == 0x00 && blob_bytes[3] == 0xFF && blob_bytes[4] == 0x7F, "binary blob passes intact")
	testing.expect_value(t, res.cells[4].value_kind, u8(Sqlite_Value_Kind.Null))

	// Row 1 checks: empty text vs NULL distinction.
	testing.expect_value(t, res.cells[7].value_kind, u8(Sqlite_Value_Kind.Text))
	testing.expect_value(t, res.cells[7].payload_length, u32(0))
	testing.expect_value(t, res.cells[9].value_kind, u8(Sqlite_Value_Kind.Blob))
	testing.expect_value(t, res.cells[9].integer_or_bits, i64(0))

	// ---- Multi-statement last row-producing result semantics ----
	res = sqlite_exec_call(loaded, "SELECT 111 AS a; SELECT 222 AS b, 'second' AS c;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, res.summary.column_count, u32(2))
	testing.expect_value(t, res.summary.row_count, u32(1))
	testing.expect_value(t, res.cells[0].integer_or_bits, i64(222))
	testing.expect_value(t, sqlite_cell_text(res.cells[1], res.payload), "second")

	// ---- Multi-statement error rolls back earlier write via implicit savepoint ----
	sqlite_sync_to_store(t, loaded, db_buf, &store_backing, res.summary.database_bytes)
	bad_sql := "UPDATE typed SET label = 'SHOULD_ROLLBACK' WHERE id = 1;\nSELEC broken;"
	err_res := sqlite_exec_call(loaded, bad_sql, db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, err_res.answer.outcome, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, err_res.err.argument, i64(1))
	testing.expect_value(t, err_res.err.value, i64(strings.index(bad_sql, "SELEC")))
	testing.expect(t, strings.contains(err_res.diagnostic, "syntax error"), "syntax diagnostic populated")
	// session_last_diagnostic returns the same diagnostic text across call boundaries.
	ld_ans, ld_text, _ := sqlite_last_diag_call(loaded, diag_buf)
	testing.expect_value(t, ld_ans.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, strings.contains(ld_text, "syntax error"), "session_last_diagnostic returns diagnostic")
	// Verify row 1 was rolled back cleanly!
	verify_res := sqlite_exec_call(loaded, "SELECT label FROM typed WHERE id = 1;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, verify_res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, sqlite_cell_text(verify_res.cells[0], verify_res.payload), "a|b\nc\"d'e é")

	// ---- Interior NUL byte in SQL refused; explicit SAVEPOINT/RELEASE bypasses wrapper ----
	nul_res := sqlite_exec_call(loaded, "SELECT 1;\x00DROP TABLE typed;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, nul_res.answer.outcome, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, nul_res.err.kind, i64(errors.Kind.Bad_Value))

	sp_res := sqlite_exec_call(loaded, "INSERT INTO typed(id, label, score, raw, note) VALUES (99, 'sp', 1.0, X'', NULL); SAVEPOINT user_sp; DELETE FROM typed WHERE id = 99; RELEASE user_sp;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, sp_res.answer.outcome, call_outcome.Call_Outcome.Succeeded)

	// ---- Wide-column (>64 cols) query caps columns and per-row cells together without row shift ----
	wide_cols: [64]Sqlite_Column_Row
	wide_sql := strings.builder_make()
	defer strings.builder_destroy(&wide_sql)
	strings.write_string(&wide_sql, "WITH r(v) AS (VALUES (100), (200)) SELECT ")
	for c in 0 ..< 65 {
		if c > 0 {
			strings.write_string(&wide_sql, ", ")
		}
		fmt.sbprintf(&wide_sql, "v + %d AS c%d", c, c)
	}
	strings.write_string(&wide_sql, " FROM r ORDER BY v;")
	wide_res := sqlite_exec_call(loaded, strings.to_string(wide_sql), db_buf, wide_cols[:], cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, wide_res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, wide_res.summary.column_count, u32(65))
	testing.expect_value(t, wide_res.summary.row_count, u32(2))
	testing.expect_value(t, len(wide_res.columns), 64)
	testing.expect_value(t, len(wide_res.cells), 128)
	// Row 0 col 0 == 100, Row 1 col 0 == 200 (proving zero column shift!).
	testing.expect_value(t, wide_res.cells[0].integer_or_bits, i64(100))
	testing.expect_value(t, wide_res.cells[64].row_index, u32(1))
	testing.expect_value(t, wide_res.cells[64].column_index, u32(0))
	testing.expect_value(t, wide_res.cells[64].integer_or_bits, i64(200))

	// ---- Atomic row emission (no partial row on cells cap) ----
	small_cells: [5]Sqlite_Cell_Row // 2 columns per row -> fits 2 full rows (4 cells), must NOT emit half of row 3!
	trunc_res := sqlite_exec_call(loaded, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10) SELECT i, i * 10 FROM n;", db_buf, col_buf, small_cells[:], pay_buf, diag_buf)
	testing.expect_value(t, trunc_res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, trunc_res.summary.column_count, u32(2))
	testing.expect_value(t, trunc_res.summary.row_count, u32(2))
	testing.expect_value(t, trunc_res.summary.truncated_rows, u8(1))
	testing.expect_value(t, len(trunc_res.cells), 4)

	// ---- 10,000 rows, delete 9,900, VACUUM shrink + dirty-range clamping ----
	res = sqlite_exec_call(loaded, "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, amount INTEGER); BEGIN; WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000) INSERT INTO item(id, name, amount) SELECT i, 'item-' || i, i * 3 FROM n; COMMIT;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	size_before_vacuum := res.summary.database_bytes
	testing.expect(t, size_before_vacuum > 64 * 1024, "10000 rows grew database past 64 KiB")
	sqlite_sync_to_store(t, loaded, db_buf, &store_backing, size_before_vacuum)

	res = sqlite_exec_call(loaded, "DELETE FROM item WHERE id > 100;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	res = sqlite_exec_call(loaded, "VACUUM;", db_buf, col_buf, cell_buf, pay_buf, diag_buf)
	testing.expect_value(t, res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
	size_after_vacuum := res.summary.database_bytes
	testing.expect(t, size_after_vacuum > 0 && size_after_vacuum < size_before_vacuum / 2, "VACUUM shrank database")
	sqlite_sync_to_store(t, loaded, db_buf, &store_backing, size_after_vacuum)

	// Close and reopen ONLY from store_backing (proving dirty-range incremental sync + shrink is 100% lossless!).
	cl_ans, _ := sqlite_close_call(loaded, db_buf)
	testing.expect_value(t, cl_ans.outcome, call_outcome.Call_Outcome.Succeeded)

	reopen_buf := make([]u8, 256 << 10)
	defer delete(reopen_buf)
	copy(reopen_buf[:len(store_backing)], store_backing[:])

	// Reopen read-only first: SELECT succeeds, INSERT refused with Grant_Or_Right_Missing.
	ro_opts := Sqlite_Open_Options{fresh = 0, read_only = 1, database_bytes = u64(len(store_backing))}
	ro_ans, ro_info, _ := sqlite_open_call(loaded, &ro_opts, reopen_buf)
	if testing.expect_value(t, ro_ans.outcome, call_outcome.Call_Outcome.Succeeded) {
		testing.expect_value(t, ro_info.read_only, u8(1))
		testing.expect_value(t, ro_info.dirty_pages, u64(0))
		chk := sqlite_exec_call(loaded, "PRAGMA integrity_check;", reopen_buf, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, chk.answer.outcome, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, sqlite_cell_text(chk.cells[0], chk.payload), "ok")
		cnt := sqlite_exec_call(loaded, "SELECT count(*) FROM item;", reopen_buf, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, cnt.answer.outcome, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, cnt.cells[0].integer_or_bits, i64(100))
		ro_write := sqlite_exec_call(loaded, "INSERT INTO item(name, amount) VALUES ('ro', 1);", reopen_buf, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, ro_write.answer.outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
		close_ro, _ := sqlite_close_call(loaded, reopen_buf)
		testing.expect_value(t, close_ro.outcome, call_outcome.Call_Outcome.Succeeded)
	}

	// ---- Out-of-budget (memsys5 heap) refusal ----
	tight_opts := Sqlite_Open_Options{fresh = 1, heap_bytes = 64 * 1024}
	tight_buf := make([]u8, 64 * 1024)
	defer delete(tight_buf)
	t_ans, _, _ := sqlite_open_call(loaded, &tight_opts, tight_buf)
	if testing.expect_value(t, t_ans.outcome, call_outcome.Call_Outcome.Succeeded) {
		oom := sqlite_exec_call(loaded, "WITH RECURSIVE n(i, s) AS (SELECT 1, printf('%01000d', 1) UNION ALL SELECT i + 1, s || printf('%01000d', i) FROM n WHERE i < 500) SELECT sum(length(s)) FROM n;", tight_buf, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, oom.answer.outcome, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
		cl_t, _ := sqlite_close_call(loaded, tight_buf)
		testing.expect_value(t, cl_t.outcome, call_outcome.Call_Outcome.Succeeded)
	}

	// ---- Dynamic buffer growth (P14 caller-supplied memory, zero dangling pointers) ----
	grow_small := make([]u8, 12 * 1024)
	defer delete(grow_small)
	grow_opts := Sqlite_Open_Options{fresh = 1}
	g_ans, _, _ := sqlite_open_call(loaded, &grow_opts, grow_small)
	if testing.expect_value(t, g_ans.outcome, call_outcome.Call_Outcome.Succeeded) {
		_ = sqlite_exec_call(loaded, "CREATE TABLE big(x TEXT);", grow_small, col_buf, cell_buf, pay_buf, diag_buf)
		full_res := sqlite_exec_call(loaded, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) INSERT INTO big(x) SELECT printf('%0200d', i) FROM n;", grow_small, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, full_res.answer.outcome, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
		// Grow buffer in caller memory and pass the larger buffer on the next call (zero dangling pointers!).
		grow_big := make([]u8, 256 * 1024)
		defer delete(grow_big)
		copy(grow_big[:len(grow_small)], grow_small)
		ok_res := sqlite_exec_call(loaded, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) INSERT INTO big(x) SELECT printf('%0200d', i) FROM n;", grow_big, col_buf, cell_buf, pay_buf, diag_buf)
		testing.expect_value(t, ok_res.answer.outcome, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, ok_res.summary.changes, i64(200))
		cl_g, _ := sqlite_close_call(loaded, grow_big)
		testing.expect_value(t, cl_g.outcome, call_outcome.Call_Outcome.Succeeded)
	}
	fmt.printfln("sqlite: typed module verified (%d bytes before VACUUM -> %d bytes after VACUUM)", size_before_vacuum, size_after_vacuum)
}

// ---- Lua -------------------------------------------------------------------------------

// The status codes of Lua: the values of lua.h.
Lua_Status :: enum i64 {
	Ok         = 0,
	Error_Run  = 2,
	Error_Syntax = 3,
	Error_Memory = 4,
	Error_Error  = 5,
}

Lua_Run_Request :: struct {
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

Lua_Result :: struct {
	status:     Lua_Status,
	output:     string,
	diagnostic: string,
	live_bytes: i64,
}

lua_run_script :: proc(loaded: Loaded_Module, source: string, arena: []u8) -> Lua_Result {
	output: [8192]u8
	diagnostic: [1024]u8
	request := Lua_Run_Request {
		arena               = raw_data(arena),
		arena_size          = i64(len(arena)),
		source              = strings.clone_to_cstring(source, context.temp_allocator),
		output              = raw_data(output[:]),
		output_capacity     = len(output),
		diagnostic          = raw_data(diagnostic[:]),
		diagnostic_capacity = len(diagnostic),
	}
	status := call(loaded, "script_run", address_of(&request))
	return {
		Lua_Status(status),
		strings.clone(string(output[:request.output_length]), context.temp_allocator),
		strings.clone(string(diagnostic[:request.diagnostic_length]), context.temp_allocator),
		request.live_bytes_after_close,
	}
}

LUA_SCRIPTS := [?][2]string {
	{"print(1 + 2, 7 // 2, 7 % 3, -7 // 2, 2^10, 10 / 4, 3 == 3.0, math.maxinteger + 1 == math.mininteger, 1e15, 2^53, 0x10, 1/0, -1/0)", "3\t3\t1\t-4\t1024.0\t2.5\ttrue\ttrue\t1e+15\t9.007199254741e+15\t16\tinf\t-inf\n"},
	{"local function counter() local n = 0 return function() n = n + 1 return n end end local a, b = counter(), counter() a() a() print(a(), b())", "3\t1\n"},
	{"local t = {5, 3, 9, 1, 7} table.sort(t) print(table.concat(t, ',')) table.sort(t, function(x, y) return x > y end) print(table.concat(t, ',')) local m = {} for i = 1, 1000 do m['k' .. i] = i end local s = 0 for _, v in pairs(m) do s = s + v end print(#t, s, select('#', table.unpack({1, 2, nil, 4}, 1, 4)), table.remove(t), next({}))", "1,3,5,7,9\n9,7,5,3,1\n5\t500500\t4\t1\tnil\n"},
	{"local V = {} V.__index = V V.__add = function(a, b) return setmetatable({x = a.x + b.x}, V) end V.__eq = function(a, b) return a.x == b.x end V.__lt = function(a, b) return a.x < b.x end V.__tostring = function(v) return 'V(' .. v.x .. ')' end V.__call = function(v, k) return v.x * k end V.__len = function() return 42 end function V.double(v) return v.x * 2 end local a, b = setmetatable({x = 1}, V), setmetatable({x = 2}, V) print(tostring(a + b), a + b == setmetatable({x = 3}, V), a < b, a(10), #a, b:double(), rawequal(a, a))", "V(3)\ttrue\ttrue\t10\t42\t4\ttrue\n"},
	{"local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i * i) end return 'done' end) print(gen(), gen(), gen(), gen()) local co = coroutine.create(function(a) local b = coroutine.yield(a + 1) error('inside ' .. b, 0) end) print(coroutine.resume(co, 1)) print(coroutine.resume(co, 'x')) print(coroutine.status(co), coroutine.isyieldable())", "1\t4\t9\tdone\ntrue\t2\nfalse\tinside x\ndead\tfalse\n"},
	{"print(pcall(error, 'boom', 0)) print(pcall(error, {code = 42})) local ok, e = pcall(function() return nil + 1 end) print(ok, e:find('attempt to perform arithmetic') ~= nil) print(select(2, xpcall(function() error('deep', 0) end, function(m) return 'handled ' .. m end))) local depth = 0 local function nest(n) if n == 0 then error('bottom', 0) end local ok2, err = pcall(nest, n - 1) depth = depth + 1 error(err, 0) end print(pcall(nest, 50), depth)", "false\tboom\nfalse\ttable: "},
	{"print(string.format('%5.2f|%d|%s|%q|%x|%g|%-4s|%03d', 3.14159, 42, 'hi', 'a\\nb', 255, 0.1, 'ab', 7)) print(('hello world'):gsub('o', '0')) print(string.find('modus kernel', 'ker'), string.match('key=value', '(%w+)=(%w+)')) local words = {} for w in string.gmatch('one two three', '%a+') do words[#words + 1] = w:upper() end print(table.concat(words, '-'), string.rep('ab', 3, ','), string.byte('A'), string.char(72, 105), ('x'):rep(0) == '', #string.pack('i4', 7), string.unpack('i4', string.pack('i4', -5)))", " 3.14|42|hi|\"a\\\nb\"|ff|0.1|ab  |007\nhell0 w0rld\t2\n7\tkey\tvalue\nONE-TWO-THREE\tab,ab,ab\t65\tHi\ttrue\t4\t-5\t5\n"},
	{"print(math.sqrt(2), math.sin(math.pi / 6), math.cos(0), math.floor(3.7), math.ceil(-3.7), math.huge, math.pi) print(string.format('%.14g', math.exp(1)), math.log(8, 2), math.log(100, 10), math.log(1), math.fmod(7, 3), math.type(1), math.type(1.0), math.type('1'), math.tointeger(3.0), math.abs(math.mininteger), math.ult(1, -1), math.atan(1, 1) * 4 == math.pi, 2^0.5 == math.sqrt(2), 8^(1/3))", "1.4142135623731\t0.5\t1.0\t3\t-3\tinf\t3.1415926535898\n2.718281828459\t3.0\t2.0\t0.0\t1\tinteger\tfloat\tnil\t3\t-9223372036854775808\ttrue\ttrue\ttrue\t2.0\n"},
	{"print(utf8.char(72, 228, 8364, 128512), utf8.len('häé'), #utf8.char(8364)) for p, c in utf8.codes('aé') do print(p, c) end", "Hä€😀\t3\t3\n1\t97\n2\t233\n"},
	{"local t = {} for i = 1, 20000 do t[i] = {i, tostring(i)} end t = nil collectgarbage() local before = collectgarbage('count') local s = {} for i = 1, 1000 do s[#s + 1] = string.rep('x', i % 50) end print(collectgarbage('count') > before, #s, type(collectgarbage('count')))", "true\t1000\tnumber\n"},
}

@(test)
real_lua_runs_scripts_with_its_libraries :: proc(t: ^testing.T) {
	loaded, ok := load_real_program(t, .Lua)
	if !ok {
		return
	}
	defer unload_module(loaded)
	testing.expect_value(t, call(loaded, "script_request_size"), i64(size_of(Lua_Run_Request)))
	arena := make([]u8, 16 << 20)
	defer delete(arena)
	for script, index in LUA_SCRIPTS {
		result := lua_run_script(loaded, script[0], arena)
		testing.expectf(t, result.status == .Ok, "script %d: status %v, %s", index, result.status, result.diagnostic)
		if index == 5 {
			// A table has an address in its name: compare up to it.
			testing.expectf(t, strings.has_prefix(result.output, script[1]), "script %d: the output is %q", index, result.output)
			testing.expectf(t, strings.has_suffix(result.output, "\nfalse\ttrue\nhandled deep\nfalse\t50\n"), "script %d: the output is %q", index, result.output)
		} else {
			testing.expectf(t, result.output == script[1], "script %d: the output is %q, not %q", index, result.output, script[1])
		}
		testing.expectf(t, result.live_bytes == 0, "script %d: lua_close left %d bytes in use", index, result.live_bytes)
	}

	// The refusals: a syntax error, a runtime error with its message, an
	// error object that is not a string, a script that exhausts its arena,
	// an arena too small for a state, and a request with no output.
	result := lua_run_script(loaded, "print('a' ..)", arena)
	testing.expect_value(t, result.status, Lua_Status.Error_Syntax)
	testing.expect(t, strings.contains(result.diagnostic, "unexpected symbol near ')'"), "the message of a syntax error")
	testing.expect_value(t, result.output, "")
	result = lua_run_script(loaded, "print('before') error('stopped here')", arena)
	testing.expect_value(t, result.status, Lua_Status.Error_Run)
	testing.expect_value(t, result.output, "before\n")
	testing.expect(t, strings.has_suffix(result.diagnostic, ":1: stopped here"), "the message of a runtime error has its line")
	result = lua_run_script(loaded, "error({})", arena)
	testing.expect_value(t, result.status, Lua_Status.Error_Run)
	testing.expect_value(t, result.diagnostic, "(an error object that is not a string)")
	result = lua_run_script(loaded, "local t = {} for i = 1, 1e9 do t[i] = ('x'):rep(100) .. i end", arena[:1 << 20])
	testing.expect_value(t, result.status, Lua_Status.Error_Memory)
	testing.expect_value(t, result.live_bytes, i64(0))
	result = lua_run_script(loaded, "print(1)", arena[:512])
	testing.expect_value(t, result.status, Lua_Status.Error_Memory)
	result = lua_run_script(loaded, "print(1)", arena[:0])
	testing.expect_value(t, result.status, Lua_Status.Error_Memory)
	// The libraries that reach the host are not there.
	result = lua_run_script(loaded, "print(io, os, package, require, dofile ~= nil, loadfile ~= nil)", arena)
	testing.expect_value(t, result.output, "nil\tnil\tnil\tnil\ttrue\ttrue\n")
	no_output := Lua_Run_Request{arena = raw_data(arena), arena_size = i64(len(arena)), source = "print(1)"}
	testing.expect_value(t, call(loaded, "script_run", address_of(&no_output)), i64(Lua_Status.Error_Error))
	testing.expect_value(t, call(loaded, "script_run", 0), i64(Lua_Status.Error_Error))
}

// ---- zstd ------------------------------------------------------------------------------

// The codes of zstd that the test reads: the values of zstd_errors.h.
Zstd_Error :: enum i64 {
	Prefix_Unknown     = 10,
	Corruption         = 20,
	Checksum_Wrong     = 22,
	Source_Size_Wrong  = 72,
	Destination_Too_Small = 70,
}

zstd_compress_bytes :: proc(loaded: Loaded_Module, content: []u8, level: i64) -> (frame: []u8, code: i64) {
	bound := call(loaded, "zstd_compress_bound", i64(len(content)))
	frame = make([]u8, bound, context.temp_allocator)
	code = call(loaded, "zstd_compress", address_of(raw_data(content)), i64(len(content)), address_of(raw_data(frame)), bound, level)
	if code < 0 {
		return nil, code
	}
	return frame[:code], code
}

zstd_decompress_bytes :: proc(loaded: Loaded_Module, frame: []u8, capacity: int) -> (content: []u8, code: i64) {
	content = make([]u8, max(capacity, 1), context.temp_allocator)
	code = call(loaded, "zstd_decompress", address_of(raw_data(frame)), i64(len(frame)), address_of(raw_data(content)), i64(capacity))
	if code < 0 {
		return nil, code
	}
	return content[:code], code
}

@(test)
real_zstd_round_trips_frames_and_refuses_damaged_ones :: proc(t: ^testing.T) {
	loaded, ok := load_real_program(t, .Zstd)
	if !ok {
		return
	}
	defer unload_module(loaded)
	testing.expect_value(t, call(loaded, "zstd_version_number"), i64(10507))
	// No heap yet: each call that needs a context is refused.
	testing.expect_value(t, call(loaded, "zstd_heap_live_bytes"), i64(-1))
	empty: [1]u8
	testing.expect(t, call(loaded, "zstd_compress", address_of(&empty), 0, address_of(&empty), 1, 3) < 0, "no heap, no context")
	testing.expect_value(t, call(loaded, "zstd_heap_bind", address_of(&empty), 1), i64(-1))
	arena := make([]u8, 192 << 20)
	defer delete(arena)
	if !testing.expect_value(t, call(loaded, "zstd_heap_bind", address_of(raw_data(arena)), i64(len(arena))), i64(0)) {
		return
	}

	generator := Generator{0x5eed_2057}
	random := make([]u8, 300_000, context.temp_allocator)
	for &value in random {
		value = u8(next_word(&generator))
	}
	// Text that repeats with changes: many matches, over three blocks of
	// 128 KiB.
	text_builder := strings.builder_make(context.temp_allocator)
	for line in 0 ..< 20000 {
		fmt.sbprintf(&text_builder, "line %d of the record: the value is %d\n", line, (line * 7919) % 1000)
	}
	text := transmute([]u8)strings.to_string(text_builder)
	repetitive := make([]u8, 1 << 20, context.temp_allocator)
	for &value, index in repetitive {
		value = u8('a' + index % 7)
	}
	Payload :: struct {
		name:    string,
		content: []u8,
	}
	payloads := [?]Payload{{"empty", nil}, {"one byte", transmute([]u8)string("m")}, {"small", transmute([]u8)string("modus compresses with the zstd of others")}, {"repetitive", repetitive}, {"text", text}, {"random", random}}
	levels := [?]i64{-5, 1, 3, 9, 19}
	for payload in payloads {
		for level in levels {
			frame, code := zstd_compress_bytes(loaded, payload.content, level)
			if !testing.expectf(t, code > 0, "%s at level %d: compress gives %d", payload.name, level, code) {
				continue
			}
			testing.expect_value(t, call(loaded, "zstd_frame_content_size", address_of(raw_data(frame)), i64(len(frame))), i64(len(payload.content)))
			content, decompress_code := zstd_decompress_bytes(loaded, frame, len(payload.content))
			testing.expectf(t, decompress_code == i64(len(payload.content)) && string(content) == string(payload.content), "%s at level %d: the round trip gives %d bytes", payload.name, level, decompress_code)
			if level == 19 {
				fmt.printfln("zstd: %s of %d bytes into a frame of %d bytes at level 19", payload.name, len(payload.content), len(frame))
			}
		}
	}
	testing.expect_value(t, call(loaded, "zstd_heap_live_bytes"), i64(0))

	// The zstd of the host reads the frames of the module, and the module
	// reads the frames of the zstd of the host.
	temp_base, _ := os.temp_dir(context.temp_allocator)
	work := fmt.tprintf("%s/modus_zstd_%d", temp_base if temp_base != "" else "/tmp", os.get_pid())
	_ = os.make_directory_all(work)
	defer _ = os.remove_all(work)
	frame, _ := zstd_compress_bytes(loaded, text, 19)
	frame_path := fmt.tprintf("%s/module.zst", work)
	testing.expect(t, os.write_entire_file(frame_path, frame) == nil)
	state, host_output, host_error, start_error := os.process_exec({command = {"zstd", "-d", "-c", frame_path}}, context.temp_allocator)
	if testing.expectf(t, start_error == nil && state.success, "zstd of the host refused the frame: %v %s", start_error, string(host_error)) {
		testing.expect(t, string(host_output) == string(text), "zstd of the host reads the content of the frame")
	}
	text_path := fmt.tprintf("%s/text", work)
	testing.expect(t, os.write_entire_file(text_path, text) == nil)
	state, host_output, host_error, start_error = os.process_exec({command = {"zstd", "-19", "--check", "-c", text_path}}, context.temp_allocator)
	if testing.expectf(t, start_error == nil && state.success, "zstd of the host failed: %v %s", start_error, string(host_error)) {
		content, code := zstd_decompress_bytes(loaded, host_output, len(text))
		testing.expectf(t, code == i64(len(text)) && string(content) == string(text), "the module reads the frame of the host: %d", code)
	}

	// The refusals of zstd, with its codes.
	frame, _ = zstd_compress_bytes(loaded, text, 3)
	damaged := make([]u8, len(frame), context.temp_allocator)
	copy(damaged, frame)
	damaged[len(damaged) / 2] ~= 0x5a
	_, code := zstd_decompress_bytes(loaded, damaged, len(text))
	testing.expectf(t, code < 0, "a damaged frame is refused: %d", code)
	fmt.printfln("zstd: a damaged frame is refused with the code %d", -code)
	// A change in the checksum itself.
	copy(damaged, frame)
	damaged[len(damaged) - 1] ~= 0x01
	_, code = zstd_decompress_bytes(loaded, damaged, len(text))
	testing.expect_value(t, code, -i64(Zstd_Error.Checksum_Wrong))
	_, code = zstd_decompress_bytes(loaded, frame[:len(frame) - 10], len(text))
	testing.expect_value(t, code, -i64(Zstd_Error.Source_Size_Wrong))
	_, code = zstd_decompress_bytes(loaded, frame, len(text) - 1)
	testing.expect_value(t, code, -i64(Zstd_Error.Destination_Too_Small))
	copy(damaged, frame)
	damaged[0] ~= 0xff
	_, code = zstd_decompress_bytes(loaded, damaged, len(text))
	testing.expect_value(t, code, -i64(Zstd_Error.Prefix_Unknown))
	testing.expect_value(t, call(loaded, "zstd_frame_content_size", address_of(raw_data(damaged)), i64(len(damaged))), -i64(Zstd_Error.Prefix_Unknown))
	// No byte is no frame: zstd gives no content.
	_, code = zstd_decompress_bytes(loaded, frame[:0], len(text))
	testing.expect_value(t, code, i64(0))
	// Bytes too few for a frame header are refused.
	_, code = zstd_decompress_bytes(loaded, frame[:3], len(text))
	testing.expect_value(t, code, -i64(Zstd_Error.Source_Size_Wrong))
	output_small := make([]u8, 8, context.temp_allocator)
	code = call(loaded, "zstd_compress", address_of(raw_data(text)), i64(len(text)), address_of(raw_data(output_small)), 8, 3)
	testing.expect_value(t, code, -i64(Zstd_Error.Destination_Too_Small))
	testing.expect_value(t, call(loaded, "zstd_heap_live_bytes"), i64(0))
}