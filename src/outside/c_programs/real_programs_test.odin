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

// The result codes of SQLite that the test reads: the values of sqlite3.h.
Sqlite_Code :: enum i64 {
	Ok             = 0,
	Error          = 1,
	Nomem          = 7,
	Toobig         = 18,
	Misuse         = 21,
	Constraint_Unique = 2067, // SQLITE_CONSTRAINT | (8 << 8)
}

Sqlite_Session :: struct {
	loaded: Loaded_Module,
	output: []u8,
}

sqlite_execute :: proc(session: Sqlite_Session, sql: string) -> (code: i64, rows: string) {
	code = call(session.loaded, "sqlite_session_execute", text_address(sql), address_of(raw_data(session.output)), i64(len(session.output)))
	return code, strings.clone(string(cstring(raw_data(session.output))), context.temp_allocator)
}

@(test)
real_sqlite_runs_queries_over_the_modus_vfs :: proc(t: ^testing.T) {
	loaded, ok := load_real_program(t, .Sqlite)
	if !ok {
		return
	}
	defer unload_module(loaded)
	arena := make([]u8, 8 << 20)
	defer delete(arena)
	store := make([]u8, 8 << 20)
	defer delete(store)
	output := make([]u8, 1 << 16)
	defer delete(output)
	session := Sqlite_Session{loaded, output}
	open :: proc(session: Sqlite_Session, arena, store: []u8, fresh: i64) -> i64 {
		return call(session.loaded, "sqlite_session_open", address_of(raw_data(arena)), i64(len(arena)), address_of(raw_data(store)), i64(len(store)), fresh)
	}
	expect_rows :: proc(t: ^testing.T, session: Sqlite_Session, sql: string, expected: string, location := #caller_location) {
		code, rows := sqlite_execute(session, sql)
		testing.expectf(t, code == i64(Sqlite_Code.Ok), "%s: code %d, %s", sql, code, rows, loc = location)
		testing.expectf(t, rows == expected, "%s: the rows are %q, not %q", sql, rows, expected, loc = location)
	}

	// The refusals come first: an arena or a store too small, and a query
	// with no open database.
	testing.expect_value(t, open(session, arena[:1024], store, 1), i64(Sqlite_Code.Misuse))
	testing.expect_value(t, open(session, arena, store[:0], 1), i64(Sqlite_Code.Misuse))
	testing.expect_value(t, open(session, arena, store[:4096], 1), i64(Sqlite_Code.Misuse))
	code, _ := sqlite_execute(session, "SELECT 1;")
	testing.expect_value(t, code, i64(Sqlite_Code.Misuse))
	testing.expect_value(t, call(loaded, "sqlite_session_close"), i64(Sqlite_Code.Misuse))

	testing.expect_value(t, call(loaded, "sqlite_version_number"), i64(3054001))
	if !testing.expect_value(t, open(session, arena, store, 1), i64(Sqlite_Code.Ok)) {
		return
	}
	// A second open while one is open is refused.
	testing.expect_value(t, open(session, arena, store, 1), i64(Sqlite_Code.Misuse))
	expect_rows(t, session, "SELECT sqlite_version();", "3.54.1\n")
	expect_rows(t, session, "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, amount INTEGER, ratio REAL);", "")

	// 10000 rows in one transaction, by a recursive query of SQLite itself.
	expect_rows(t, session, "BEGIN; WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000) INSERT INTO item(id, name, amount, ratio) SELECT i, 'item-' || i, i * 3, i / 4.0 FROM n; COMMIT;", "")
	testing.expect_value(t, call(loaded, "sqlite_session_changes"), i64(10000))
	expected_sum := 0
	for i in 1 ..= 10000 {
		expected_sum += i * 3
	}
	expect_rows(t, session, "SELECT count(*), sum(amount), min(name), max(id) FROM item;", fmt.tprintf("10000|%d|item-1|10000\n", expected_sum))
	expect_rows(t, session, "SELECT name, amount, ratio FROM item WHERE id IN (1, 2, 9999) ORDER BY id;", "item-1|3|0.25\nitem-2|6|0.5\nitem-9999|29997|2499.75\n")
	expect_rows(t, session, "SELECT round(avg(ratio), 3), typeof(ratio), 2 * 3.5, 7 / 2, 7 % 3, abs(-4), length('modus'), upper('modus'), hex('AB') FROM item;", "1250.125|real|7.0|3|1|4|5|MODUS|4142\n")
	expect_rows(t, session, "PRAGMA integrity_check;", "ok\n")

	expect_rows(t, session, "UPDATE item SET amount = amount + 1 WHERE id % 2 = 0;", "")
	testing.expect_value(t, call(loaded, "sqlite_session_changes"), i64(5000))
	expect_rows(t, session, "DELETE FROM item WHERE id > 9000;", "")
	testing.expect_value(t, call(loaded, "sqlite_session_changes"), i64(1000))
	expect_rows(t, session, "SELECT count(*), sum(amount) FROM item;", fmt.tprintf("9000|%d\n", 3 * (9000 * 9001 / 2) + 4500))
	expect_rows(t, session, "CREATE INDEX item_amount ON item(amount); SELECT id FROM item WHERE amount = 31;", "10\n")
	expect_rows(t, session, "PRAGMA integrity_check;", "ok\n")

	// A transaction that rolls back leaves the rows of the last commit.
	expect_rows(t, session, "BEGIN; DELETE FROM item; INSERT INTO item(name) VALUES ('ghost'); SELECT count(*) FROM item; ROLLBACK;", "1\n")
	expect_rows(t, session, "SELECT count(*), sum(amount) FROM item;", fmt.tprintf("9000|%d\n", 3 * (9000 * 9001 / 2) + 4500))
	expect_rows(t, session, "SELECT count(*) FROM item WHERE name = 'ghost';", "0\n")
	expect_rows(t, session, "PRAGMA integrity_check;", "ok\n")

	// The refusals of SQLite, with its codes and its messages.
	rows: string
	code, rows = sqlite_execute(session, "SELEC 1;")
	testing.expect_value(t, code, i64(Sqlite_Code.Error))
	testing.expect_value(t, rows, "near \"SELEC\": syntax error")
	code, rows = sqlite_execute(session, "INSERT INTO item(name) VALUES ('item-1');")
	testing.expect_value(t, code, i64(Sqlite_Code.Constraint_Unique))
	testing.expect_value(t, rows, "UNIQUE constraint failed: item.name")
	code, rows = sqlite_execute(session, "SELECT * FROM missing;")
	testing.expect_value(t, code, i64(Sqlite_Code.Error))
	testing.expect_value(t, rows, "no such table: missing")
	small := Sqlite_Session{loaded, output[:16]}
	code, _ = sqlite_execute(small, "SELECT name FROM item;")
	testing.expect_value(t, code, i64(Sqlite_Code.Toobig))
	expect_rows(t, session, "PRAGMA integrity_check;", "ok\n")

	// Close, open again over the same store: the bytes of the store are the file.
	size := call(loaded, "sqlite_session_database_size")
	testing.expect(t, size > 0 && size % 4096 == 0, "the database has whole pages in the store")
	testing.expect_value(t, call(loaded, "sqlite_session_close"), i64(Sqlite_Code.Ok))
	if !testing.expect_value(t, open(session, arena, store, 0), i64(Sqlite_Code.Ok)) {
		return
	}
	expect_rows(t, session, "SELECT count(*), sum(amount), max(id) FROM item;", fmt.tprintf("9000|%d|9000\n", 3 * (9000 * 9001 / 2) + 4500))
	expect_rows(t, session, "PRAGMA integrity_check;", "ok\n")
	testing.expect_value(t, call(loaded, "sqlite_session_close"), i64(Sqlite_Code.Ok))
	fmt.printfln("sqlite: database of %d bytes in the store", size)
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