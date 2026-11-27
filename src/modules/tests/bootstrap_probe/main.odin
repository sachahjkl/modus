// Live QEMU verification of chibicc self-hosting (Stage 0 -> Stage 1 -> Stage 2)
// and freestanding C library modules (SQLite 3.54.1, Lua 5.4.7, zstd 1.5.7)
// running natively on modus (src/md/features/bootstrap.md).
//
// Phase 1 runs chibicc self-hosting completely on modus:
//   - Stage 0 invokes boot-image `c_compiler.compile_unit` in fresh zero-grant
//     `No_Clock` call hosts on all 14 chibicc C sources plus the packed header
//     list, then joins the 14 assembly units and `self_host/jump.s` through
//     `assemble.assemble_program` (exercising dynamic workspace scaling past
//     128 KiB) to produce Stage 1 (`stage1.modus`).
//   - Stage 1 is loaded live via `system.module_space_load` (strict W^X),
//     checked on a broken C input to exercise `self_host/jump.s`, then invoked
//     on all 14 C sources via `compile_record_at`, verifying byte-for-byte
//     assembly equality against Stage 0 before assembling Stage 2 via
//     `assemble.assemble_program` and asserting `blake3(stage1) == blake3(stage2)`.
//
// Phase 2 loads and executes the compiled freestanding `sqlite.module`,
// `lua.module`, and `zstd.module` from the private store via
// `system.module_space_load`, checking refusal edges first and verifying real
// SQL queries, Lua scripts, and zstd compression frame hashes against the host.
package bootstrap_probe

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:storage"
import "modus:system"

// Plan value: 24576 pages (96 MiB) floor covers Stage 0/1 joined assembly
// buffers (~16 MiB), one 32 MiB c_compiler/assemble call host or Stage 1
// compile arena at a time, and module/heap buffers for SQLite, Lua, and zstd.
// Needs 2 processes and 2 threads to spawn one isolated call host at a time.
MODULE_BUDGET :: system.Stated_Budget{
	working_memory_pages = 24576,
	processes            = 2,
	threads              = 2,
}

// Plan value: 56 KiB chunk size for storage.read_range inside the 64 KiB call
// region, leaving 8 KiB headroom for isolated call framing metadata.
STORE_CHUNK_BYTES :: u64(57_344)

// Plan value: 32 MiB budget for one c_compiler or assemble call host (parse.c
// takes ~13 MiB arena and chibicc assembly takes ~8 MiB workspace + text).
CALL_HOST_BUDGET_PAGES :: u64(8192)

// Plan value: 32 MiB arena reservation for Stage 1 in-process compile_record_at.
STAGE_ONE_ARENA_PAGES :: u64(8192)

// Plan value: 8 MiB joined assembly buffer per stage (14 chibicc units + jump.s
// produce ~4.5 MiB of AT&T assembly text).
JOINED_ASM_PAGES :: u64(2048)

// Plan value: 4 MiB output buffer for a single c_compiler.compile_unit call.
UNIT_ASM_PAGES :: u64(1024)

// Plan value: 2 MiB output buffer for an assembled chibicc stage module (~355 KiB).
STAGE_MODULE_PAGES :: u64(512)

// Plan value: 4 MiB arena for Lua and zstd freestanding heaps.
LIB_HEAP_BYTES :: u64(4 << 20)

// Format property: chibicc self-host has 14 C units and 1 assembly unit; cap
// inline manifest slots generously for multi-unit C programs.
MAX_MANIFEST_UNITS :: 64
MAX_HEADER_FILES :: 256
MAX_NAME_BYTES :: 128

// Format property: deterministic 16 KiB zstd vector shared with host
// (tools/modustool/build/c_world_recipes.odin).
ZSTD_VECTOR_BYTES :: 16384
ZSTD_VECTOR_LEVEL :: i64(3)
ZSTD_VECTOR_PHRASE :: "modus bootstrap zstd vector "

// Format property: Compile_Call ABI matching src/outside/chibicc/system/compile.c.
C_Readable_File :: struct {
	name:  cstring,
	bytes: [^]u8,
	size:  u64,
}
#assert(size_of(C_Readable_File) == 3 * 8)

C_Compile_Call :: struct {
	source:                  [^]u8,
	source_size:             u64,
	memory_provider:         proc "c" (provider_context: rawptr, size: u64, alignment: u64) -> rawptr,
	memory_provider_context: rawptr,
	diagnostic:              [^]u8,
	diagnostic_capacity:     u64,
	source_name:             cstring,
	program_files:           [^]C_Readable_File,
	program_file_count:      u64,
	export_names:            [^]cstring,
	export_name_count:       u64,
	text:                    [^]u8,
	text_size:               u64,
	error_offset:            i64,
	diagnostic_size:         u64,
}
#assert(size_of(C_Compile_Call) == 15 * 8)

C_Compile_Result :: enum i64 {
	Done    = 0,
	Refused = 1,
}

Manifest_Unit :: struct {
	obj_name:     [MAX_NAME_BYTES]u8,
	obj_name_len: int,
	logical:      [MAX_NAME_BYTES]u8,
	logical_len:  int,
}

Unit_Span :: struct {
	offset: u64,
	length: u64,
}

Owned_Buffer :: struct {
	handle: system.Handle,
	bytes:  []u8,
}

// SQLite typed ABI matching src/outside/c_programs/sqlite/sqlite.manifest.
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

// Lua ABI matching src/outside/c_programs/lua/modus_lua_entry.c.
Lua_Status :: enum i64 {
	Ok           = 0,
	Error_Run    = 2,
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
#assert(size_of(Lua_Run_Request) == 11 * 8)

// Static BSS state so large tables stay off the process stack.
store_client: storage.Client
image_handle: system.Handle
image_bytes: []u8
compiler_file: []u8
assembler_file: []u8
compile_unit_export: u32
assemble_program_export: u32

c_units: [MAX_MANIFEST_UNITS]Manifest_Unit
c_unit_count: int
asm_units: [MAX_MANIFEST_UNITS]Manifest_Unit
asm_unit_count: int
stage0_spans: [MAX_MANIFEST_UNITS]Unit_Span

parsed_headers: [MAX_HEADER_FILES]C_Readable_File
parsed_header_count: int
header_name_storage: [MAX_HEADER_FILES * 128]u8
header_name_used: int

stage1_diagnostic: [4096]u8
stage1_arena: system.Arena

// Scratch tables for SQLite execution in BSS.
sqlite_cols: [16]Sqlite_Column_Row
sqlite_cells: [64]Sqlite_Cell_Row
sqlite_payload: [4096]u8
sqlite_diag: [512]u8
sqlite_dirty: [64]Sqlite_Dirty_Range_Row

// Scratch buffers for Lua and zstd execution in BSS.
lua_output: [4096]u8
lua_diagnostic: [512]u8
zstd_payload: [ZSTD_VECTOR_BYTES]u8
zstd_restored: [ZSTD_VECTOR_BYTES]u8

@(private = "file")
wrong :: proc "contextless" (what: string, got: u64, expected: u64) -> ! {
	system.log_fact(.Error, Wrong{got = got, expected = expected}, what)
	system.stop(.Failed)
}

@(private = "file")
buffer_alloc :: proc "contextless" (pages: u64) -> Owned_Buffer {
	handle, status := system.memory_create(pages)
	if status != .Succeeded {
		wrong("memory_create failed", u64(status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	address, map_status := system.memory_map(handle, {.Write})
	if map_status != .Succeeded {
		system.close(handle)
		wrong("memory_map failed", u64(map_status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	return {handle = handle, bytes = ([^]u8)(address)[:pages * system.PAGE_SIZE]}
}

@(private = "file")
buffer_free :: proc "contextless" (buf: ^Owned_Buffer) {
	if raw_data(buf.bytes) != nil {
		system.memory_unmap(raw_data(buf.bytes))
	}
	if buf.handle != 0 {
		system.close(buf.handle)
	}
	buf^ = {}
}

@(private = "file")
store_read_object :: proc "contextless" (name: string) -> (buf: Owned_Buffer, length: u64) {
	err: errors.Error_Record
	obj_size, size_status := storage.size(&store_client, storage.ROOT, name, &err)
	if size_status != .Ok || obj_size <= 0 {
		wrong("store object missing or unreadable", u64(size_status), 0)
	}
	pages := (u64(obj_size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	buf = buffer_alloc(pages)
	read_total := u64(0)
	for read_total < u64(obj_size) {
		want := min(STORE_CHUNK_BYTES, u64(obj_size) - read_total)
		chunk, read_status := storage.read_range(&store_client, storage.ROOT, name, read_total, buf.bytes[read_total:read_total + want], &err)
		if read_status != .Ok || len(chunk) == 0 {
			buffer_free(&buf)
			wrong("store read_range failed", u64(read_status), 0)
		}
		read_total += u64(len(chunk))
	}
	return buf, read_total
}

@(private = "file")
seed_values_of :: proc "contextless" (label: string) -> (values: [op.CONTEXT_VALUES]u64) {
	digest := blake3.hash(transmute([]u8)label)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		word: u64
		for b in 0 ..< 8 {
			word |= u64(digest[index * 8 + b]) << (8 * uint(b))
		}
		values[op.CONTEXT_VALUE_SEED + index] = word
	}
	values[op.CONTEXT_VALUE_SEED_STRENGTH] = u64(op.Seed_Strength.Weak)
	return values
}

@(private = "file")
call_host_open :: proc "contextless" (file: []u8, name: string, pages: u64) -> system.Call_Connection {
	load_error: module.Load_Error
	added := system.Call_Host_Context{pages = pages, no_clock = true}
	conn, status := system.call_host_start(image_bytes, image_handle, file, name, seed_values_of(name), &load_error, added = &added)
	if status != .Succeeded {
		wrong("call_host_start failed", u64(status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	return conn
}

@(private = "file")
check_refusals :: proc "contextless" () {
	// 1. c_compiler.compile_unit refuses an empty source name before running chibicc.
	{
		conn := call_host_open(compiler_file, "c_compiler", CALL_HOST_BUDGET_PAGES)
		defer system.call_connection_end(&conn)
		out_buf := buffer_alloc(1)
		defer buffer_free(&out_buf)
		src := "int x(void) { return 1; }"
		args := [5]isolated.Argument{
			{text = nil},
			{table = {records = transmute([]u8)src, count = u64(len(src))}},
			{table = {records = nil, count = 0}},
			{text = nil},
			{integer = u64(out_buf.handle)},
		}
		err: errors.Error_Record
		_, outcome := system.call_isolated(&conn, compiler_file, compile_unit_export, args[:], &err)
		if outcome != .Argument_Refused || err.kind != i64(errors.Kind.Empty) {
			wrong("compile_unit must refuse empty name with Empty", u64(outcome), u64(call_outcome.Call_Outcome.Argument_Refused))
		}
	}

	// 2. assemble.assemble_program refuses a hash buffer smaller than 32 bytes.
	{
		conn := call_host_open(assembler_file, "assemble", CALL_HOST_BUDGET_PAGES)
		defer system.call_connection_end(&conn)
		out_buf := buffer_alloc(1)
		defer buffer_free(&out_buf)
		small_hash: [16]u8
		asm_text := "export one() -> Integer\none: mov $1, %rax\nret\n"
		args := [3]isolated.Argument{
			{table = {records = transmute([]u8)asm_text, count = u64(len(asm_text))}},
			{integer = u64(out_buf.handle)},
			{table = {records = small_hash[:], count = 0}},
		}
		err: errors.Error_Record
		_, outcome := system.call_isolated(&conn, assembler_file, assemble_program_export, args[:], &err)
		if outcome != .Argument_Refused || err.kind != i64(errors.Kind.Too_Small) || err.limit != blake3.HASH_SIZE {
			wrong("assemble_program must refuse 16-byte hash buffer with Too_Small", u64(outcome), u64(call_outcome.Call_Outcome.Argument_Refused))
		}
	}

	system.log_fact(.Info, Refusals_Checked{})
}

@(private = "file")
manifest_parse :: proc "contextless" (data: []u8) {
	c_unit_count = 0
	asm_unit_count = 0
	pos := 0
	for pos < len(data) {
		line_start := pos
		for pos < len(data) && data[pos] != '\n' {
			pos += 1
		}
		line := data[line_start:pos]
		if pos < len(data) {
			pos += 1
		}
		if len(line) < 5 {
			continue
		}
		kind := line[0]
		if line[1] != ' ' {
			wrong("malformed chibicc_manifest line", u64(line[1]), u64(' '))
		}
		sp := 2
		for sp < len(line) && line[sp] != ' ' {
			sp += 1
		}
		if sp >= len(line) - 1 {
			wrong("malformed chibicc_manifest separator", u64(sp), u64(len(line)))
		}
		obj := line[2:sp]
		logical := line[sp + 1:]
		if len(obj) == 0 || len(obj) >= MAX_NAME_BYTES || len(logical) == 0 || len(logical) >= MAX_NAME_BYTES {
			wrong("manifest unit name out of bounds", u64(len(logical)), MAX_NAME_BYTES)
		}
		entry: Manifest_Unit
		copy(entry.obj_name[:], obj)
		entry.obj_name_len = len(obj)
		copy(entry.logical[:], logical)
		entry.logical_len = len(logical)
		switch kind {
		case 'C':
			if c_unit_count >= MAX_MANIFEST_UNITS {
				wrong("too many C units in manifest", u64(c_unit_count), MAX_MANIFEST_UNITS)
			}
			c_units[c_unit_count] = entry
			c_unit_count += 1
		case 'S':
			if asm_unit_count >= MAX_MANIFEST_UNITS {
				wrong("too many S units in manifest", u64(asm_unit_count), MAX_MANIFEST_UNITS)
			}
			asm_units[asm_unit_count] = entry
			asm_unit_count += 1
		case:
			wrong("unknown manifest unit kind", u64(kind), u64('C'))
		}
	}
	if c_unit_count == 0 || asm_unit_count == 0 {
		wrong("empty chibicc_manifest", u64(c_unit_count), 14)
	}
}

@(private = "file")
headers_parse :: proc "contextless" (blob: []u8) {
	parsed_header_count = 0
	header_name_used = 0
	pos := 0
	for pos < len(blob) {
		if len(blob) - pos < 8 {
			wrong("truncated chibicc_headers entry header", u64(len(blob) - pos), 8)
		}
		name_len := int(u32(blob[pos]) | u32(blob[pos + 1]) << 8 | u32(blob[pos + 2]) << 16 | u32(blob[pos + 3]) << 24)
		content_len := int(u32(blob[pos + 4]) | u32(blob[pos + 5]) << 8 | u32(blob[pos + 6]) << 16 | u32(blob[pos + 7]) << 24)
		pos += 8
		if name_len <= 0 || pos + name_len + content_len > len(blob) {
			wrong("truncated chibicc_headers entry body", u64(pos + name_len + content_len), u64(len(blob)))
		}
		if parsed_header_count >= MAX_HEADER_FILES || header_name_used + name_len + 1 > len(header_name_storage) {
			wrong("header table capacity exceeded", u64(parsed_header_count), MAX_HEADER_FILES)
		}
		name_start := header_name_used
		copy(header_name_storage[name_start:name_start + name_len], blob[pos:pos + name_len])
		header_name_storage[name_start + name_len] = 0
		header_name_used += name_len + 1
		pos += name_len
		content_ptr := content_len > 0 ? &blob[pos] : nil
		parsed_headers[parsed_header_count] = {
			name  = cstring(&header_name_storage[name_start]),
			bytes = content_ptr,
			size  = u64(content_len),
		}
		parsed_header_count += 1
		pos += content_len
	}
}

@(private = "file")
stage1_memory_provide :: proc "c" (provider_context: rawptr, size: u64, alignment: u64) -> rawptr {
	arena := (^system.Arena)(provider_context)
	refusal: errors.Error_Record
	address, status := system.arena_push(arena, size, alignment, &refusal)
	if status != .Succeeded {
		return nil
	}
	return address
}

@(private = "file")
assemble_stage :: proc "contextless" (asm_buf: ^Owned_Buffer, asm_len: u64, out_buf: ^Owned_Buffer) -> (size: u64, digest: blake3.Hash) {
	conn := call_host_open(assembler_file, "assemble", CALL_HOST_BUDGET_PAGES)
	defer system.call_connection_end(&conn)
	hash_out: [blake3.HASH_SIZE]u8
	args := [3]isolated.Argument{
		{table = {records = asm_buf.bytes[:asm_len], count = asm_len, memory_handle = u64(asm_buf.handle)}},
		{integer = u64(out_buf.handle)},
		{table = {records = hash_out[:], count = 0}},
	}
	err: errors.Error_Record
	written, outcome := system.call_isolated(&conn, assembler_file, assemble_program_export, args[:], &err, keep_memory_objects = true)
	if outcome != .Succeeded || written <= 0 || u64(written) > u64(len(out_buf.bytes)) {
		wrong("assemble_program failed", u64(outcome), u64(call_outcome.Call_Outcome.Succeeded))
	}
	if args[2].table.count != blake3.HASH_SIZE {
		wrong("assemble_program did not return 32-byte BLAKE3 hash", args[2].table.count, blake3.HASH_SIZE)
	}
	size = u64(written)
	copy(digest[:], hash_out[:])
	if problem := module.validate(out_buf.bytes[:size]); problem != .None {
		wrong("assembled chibicc stage failed module.validate", u64(problem), 0)
	}
	if blake3.hash(out_buf.bytes[:size]) != digest {
		wrong("assemble_program returned hash disagrees with blake3.hash", 0, 1)
	}
	return size, digest
}

@(private = "file")
bytes_contains :: proc "contextless" (haystack: []u8, needle: string) -> bool {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			if haystack[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

@(private = "file")
bytes_equal :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private = "file")
run_chibicc_self_host :: proc "contextless" () {
	manifest_buf, manifest_len := store_read_object("chibicc_manifest")
	manifest_parse(manifest_buf.bytes[:manifest_len])
	buffer_free(&manifest_buf)

	headers_buf, headers_len := store_read_object("chibicc_headers")
	defer buffer_free(&headers_buf)
	headers_parse(headers_buf.bytes[:headers_len])

	stage0_asm := buffer_alloc(JOINED_ASM_PAGES)
	defer buffer_free(&stage0_asm)
	stage0_asm_used := u64(0)

	// Stage 0: compile every C unit through boot-image c_compiler.compile_unit.
	unit_out := buffer_alloc(UNIT_ASM_PAGES)
	for index in 0 ..< c_unit_count {
		obj_name := string(c_units[index].obj_name[:c_units[index].obj_name_len])
		logical_name := string(c_units[index].logical[:c_units[index].logical_len])
		src_buf, src_len := store_read_object(obj_name)
		conn := call_host_open(compiler_file, "c_compiler", CALL_HOST_BUDGET_PAGES)
		exports_text := "compile_record_at"
		args := [5]isolated.Argument{
			{text = transmute([]u8)logical_name},
			{table = {records = src_buf.bytes[:src_len], count = src_len, memory_handle = u64(src_buf.handle)}},
			{table = {records = headers_buf.bytes[:headers_len], count = headers_len, memory_handle = u64(headers_buf.handle)}},
			{text = transmute([]u8)exports_text},
			{integer = u64(unit_out.handle)},
		}
		err: errors.Error_Record
		written, outcome := system.call_isolated(&conn, compiler_file, compile_unit_export, args[:], &err, keep_memory_objects = true)
		system.call_connection_end(&conn)
		buffer_free(&src_buf)
		if outcome != .Succeeded || written <= 0 || stage0_asm_used + u64(written) > u64(len(stage0_asm.bytes)) {
			wrong("stage 0 compile_unit failed", u64(index), u64(outcome))
		}
		stage0_spans[index] = {offset = stage0_asm_used, length = u64(written)}
		intrinsics.mem_copy_non_overlapping(&stage0_asm.bytes[stage0_asm_used], raw_data(unit_out.bytes), int(written))
		stage0_asm_used += u64(written)
	}
	buffer_free(&unit_out)

	// Append assembly units (self_host/jump.s) to Stage 0 joined text.
	for index in 0 ..< asm_unit_count {
		obj_name := string(asm_units[index].obj_name[:asm_units[index].obj_name_len])
		asm_buf, asm_len := store_read_object(obj_name)
		if stage0_asm_used + asm_len > u64(len(stage0_asm.bytes)) {
			buffer_free(&asm_buf)
			wrong("stage 0 joined assembly overflow", stage0_asm_used + asm_len, u64(len(stage0_asm.bytes)))
		}
		intrinsics.mem_copy_non_overlapping(&stage0_asm.bytes[stage0_asm_used], raw_data(asm_buf.bytes), int(asm_len))
		stage0_asm_used += asm_len
		buffer_free(&asm_buf)
	}

	// Assemble Stage 1 module via assemble.assemble_program.
	stage1_mod := buffer_alloc(STAGE_MODULE_PAGES)
	defer buffer_free(&stage1_mod)
	stage1_size, stage1_hash := assemble_stage(&stage0_asm, stage0_asm_used, &stage1_mod)
	system.log_fact(.Info, Chibicc_Stage_Built{stage = 1, size = stage1_size, hash = value_kinds.Hash_Field(stage1_hash)})

	// Stage 1 refusal check: run broken C syntax through live Stage 1 module
	// to prove self_host/jump.s setjmp/longjmp works cleanly on modus.
	export_names := [1]cstring{"compile_record_at"}
	{
		space := system.Module_Space{next = op.MODULE_BASE}
		load_err: module.Load_Error
		place, loaded := system.module_space_load(&space, stage1_mod.bytes[:stage1_size], &load_err)
		if !loaded {
			wrong("stage 1 module_space_load failed on refusal check", u64(load_err.stage), 0)
		}
		exp_idx := module.export_find(stage1_mod.bytes[:stage1_size], "compile_record_at")
		exp_addr, exp_found := module.export_address(stage1_mod.bytes[:stage1_size], uintptr(space.modules[place].base), exp_idx)
		if !exp_found {
			wrong("stage 1 missing export compile_record_at", 0, 1)
		}
		arena_refusal: errors.Error_Record
		arena_status: call_outcome.Call_Outcome
		stage1_arena, arena_status = system.arena_create(STAGE_ONE_ARENA_PAGES, 0, &arena_refusal)
		if arena_status != .Succeeded {
			wrong("stage 1 refusal arena_create failed", u64(arena_status), u64(call_outcome.Call_Outcome.Succeeded))
		}
		broken := "int f( {"
		call := C_Compile_Call{
			source                  = raw_data(broken),
			source_size             = u64(len(broken)),
			memory_provider         = stage1_memory_provide,
			memory_provider_context = &stage1_arena,
			diagnostic              = &stage1_diagnostic[0],
			diagnostic_capacity     = len(stage1_diagnostic),
			source_name             = "chibicc/broken.c",
			program_files           = &parsed_headers[0],
			program_file_count      = u64(parsed_header_count),
			export_names            = &export_names[0],
			export_name_count       = 1,
			error_offset            = -1,
		}
		entry_fn := (proc "c" (record_address: i64) -> i64)(rawptr(exp_addr))
		word := entry_fn(i64(uintptr(&call)))
		system.arena_end(&stage1_arena)
		_ = system.module_space_release(&space, place, &load_err)
		diag_len := min(int(call.diagnostic_size), len(stage1_diagnostic))
		if word != i64(C_Compile_Result.Refused) || !bytes_contains(stage1_diagnostic[:diag_len], "chibicc/broken.c:1:") {
			wrong("stage 1 failed to refuse broken C source through jump.s", u64(word), u64(C_Compile_Result.Refused))
		}
	}

	// Stage 1 -> Stage 2: compile all 14 C units using live Stage 1 module
	// loaded fresh per unit (strict W^X), assert exact assembly text equality
	// against Stage 0 on every single unit, then assemble Stage 2.
	stage1_asm := buffer_alloc(JOINED_ASM_PAGES)
	defer buffer_free(&stage1_asm)
	stage1_asm_used := u64(0)

	for index in 0 ..< c_unit_count {
		obj_name := string(c_units[index].obj_name[:c_units[index].obj_name_len])
		logical_cstr_buf: [MAX_NAME_BYTES]u8
		copy(logical_cstr_buf[:], c_units[index].logical[:c_units[index].logical_len])
		logical_cstr_buf[c_units[index].logical_len] = 0

		src_buf, src_len := store_read_object(obj_name)
		space := system.Module_Space{next = op.MODULE_BASE}
		load_err: module.Load_Error
		place, loaded := system.module_space_load(&space, stage1_mod.bytes[:stage1_size], &load_err)
		if !loaded {
			buffer_free(&src_buf)
			wrong("stage 1 module_space_load failed", u64(index), u64(load_err.stage))
		}
		exp_idx := module.export_find(stage1_mod.bytes[:stage1_size], "compile_record_at")
		exp_addr, exp_found := module.export_address(stage1_mod.bytes[:stage1_size], uintptr(space.modules[place].base), exp_idx)
		if !exp_found {
			_ = system.module_space_release(&space, place, &load_err)
			buffer_free(&src_buf)
			wrong("stage 1 export lookup failed", u64(index), 1)
		}
		arena_refusal: errors.Error_Record
		arena_status: call_outcome.Call_Outcome
		stage1_arena, arena_status = system.arena_create(STAGE_ONE_ARENA_PAGES, 0, &arena_refusal)
		if arena_status != .Succeeded {
			_ = system.module_space_release(&space, place, &load_err)
			buffer_free(&src_buf)
			wrong("stage 1 arena_create failed", u64(index), u64(arena_status))
		}
		call := C_Compile_Call{
			source                  = raw_data(src_buf.bytes),
			source_size             = src_len,
			memory_provider         = stage1_memory_provide,
			memory_provider_context = &stage1_arena,
			diagnostic              = &stage1_diagnostic[0],
			diagnostic_capacity     = len(stage1_diagnostic),
			source_name             = cstring(&logical_cstr_buf[0]),
			program_files           = &parsed_headers[0],
			program_file_count      = u64(parsed_header_count),
			export_names            = &export_names[0],
			export_name_count       = 1,
			error_offset            = -1,
		}
		entry_fn := (proc "c" (record_address: i64) -> i64)(rawptr(exp_addr))
		word := entry_fn(i64(uintptr(&call)))
		if word != i64(C_Compile_Result.Done) || call.text == nil || call.text_size == 0 {
			system.arena_end(&stage1_arena)
			_ = system.module_space_release(&space, place, &load_err)
			buffer_free(&src_buf)
			wrong("stage 1 compile_record_at failed", u64(index), u64(word))
		}
		unit_text := call.text[:call.text_size]
		expected_span := stage0_spans[index]
		expected_text := stage0_asm.bytes[expected_span.offset:expected_span.offset + expected_span.length]
		if !bytes_equal(unit_text, expected_text) {
			system.arena_end(&stage1_arena)
			_ = system.module_space_release(&space, place, &load_err)
			buffer_free(&src_buf)
			wrong("stage 1 assembly text diverged from stage 0", u64(index), u64(len(unit_text)))
		}
		if stage1_asm_used + call.text_size > u64(len(stage1_asm.bytes)) {
			system.arena_end(&stage1_arena)
			_ = system.module_space_release(&space, place, &load_err)
			buffer_free(&src_buf)
			wrong("stage 1 joined assembly overflow", stage1_asm_used + call.text_size, u64(len(stage1_asm.bytes)))
		}
		intrinsics.mem_copy_non_overlapping(&stage1_asm.bytes[stage1_asm_used], call.text, int(call.text_size))
		stage1_asm_used += call.text_size
		system.arena_end(&stage1_arena)
		if !system.module_space_release(&space, place, &load_err) {
			buffer_free(&src_buf)
			wrong("stage 1 module_space_release failed", u64(index), 0)
		}
		buffer_free(&src_buf)
	}

	for index in 0 ..< asm_unit_count {
		obj_name := string(asm_units[index].obj_name[:asm_units[index].obj_name_len])
		asm_buf, asm_len := store_read_object(obj_name)
		if stage1_asm_used + asm_len > u64(len(stage1_asm.bytes)) {
			buffer_free(&asm_buf)
			wrong("stage 1 joined assembly overflow", stage1_asm_used + asm_len, u64(len(stage1_asm.bytes)))
		}
		intrinsics.mem_copy_non_overlapping(&stage1_asm.bytes[stage1_asm_used], raw_data(asm_buf.bytes), int(asm_len))
		stage1_asm_used += asm_len
		buffer_free(&asm_buf)
	}

	stage2_mod := buffer_alloc(STAGE_MODULE_PAGES)
	defer buffer_free(&stage2_mod)
	stage2_size, stage2_hash := assemble_stage(&stage1_asm, stage1_asm_used, &stage2_mod)
	system.log_fact(.Info, Chibicc_Stage_Built{stage = 2, size = stage2_size, hash = value_kinds.Hash_Field(stage2_hash)})

	if stage1_size != stage2_size || stage1_hash != stage2_hash || !bytes_equal(stage1_mod.bytes[:stage1_size], stage2_mod.bytes[:stage2_size]) {
		wrong("stage 1 and stage 2 chibicc modules disagree", stage2_size, stage1_size)
	}
	system.log_fact(.Info, Chibicc_Self_Host_Verified{units = u64(c_unit_count), size = stage1_size, hash = value_kinds.Hash_Field(stage1_hash)})
}

@(private = "file")
module_export_ptr :: proc "contextless" (file: []u8, base: u64, name: string) -> rawptr {
	idx := module.export_find(file, name)
	if idx == 0 {
		wrong("module missing expected export", 0, 1)
	}
	addr, ok := module.export_address(file, uintptr(base), idx)
	if !ok {
		wrong("module export has no address", u64(idx), 1)
	}
	return rawptr(addr)
}

@(private = "file")
run_sqlite_live :: proc "contextless" () {
	mod_buf, mod_len := store_read_object("sqlite.module")
	defer buffer_free(&mod_buf)
	file := mod_buf.bytes[:mod_len]
	mod_hash := blake3.hash(file)

	space := system.Module_Space{next = op.MODULE_BASE}
	load_err: module.Load_Error
	place, loaded := system.module_space_load(&space, file, &load_err)
	if !loaded {
		wrong("sqlite.module load failed", u64(load_err.stage), 0)
	}
	defer {
		_ = system.module_space_release(&space, place, &load_err)
	}
	base := space.modules[place].base

	version_fn := (proc "c" () -> i64)(module_export_ptr(file, base, "version_number"))
	open_fn := (proc "c" (^Sqlite_Open_Options, ^module.Table_Place, ^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(module_export_ptr(file, base, "session_open"))
	exec_fn := (proc "c" (^Sqlite_Text_Slice, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(module_export_ptr(file, base, "session_execute"))
	dirty_fn := (proc "c" (^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(module_export_ptr(file, base, "session_dirty_ranges"))
	synced_fn := (proc "c" (^errors.Error_Record) -> Sqlite_Answer)(module_export_ptr(file, base, "session_mark_synced"))
	close_fn := (proc "c" (^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer)(module_export_ptr(file, base, "session_close"))

	version := version_fn()
	if version != 3054001 {
		wrong("unexpected sqlite version", u64(version), 3054001)
	}

	// Plan value: 512 KiB database buffer covers SQLite test tables and indexes.
	db_buf := buffer_alloc(128)
	defer buffer_free(&db_buf)

	// Refusals first: execute while closed -> Wrong_State; invalid page_size -> Argument_Refused.
	{
		sql := "SELECT 1;"
		sql_slice := Sqlite_Text_Slice{address = raw_data(sql), count = u64(len(sql))}
		db_place := module.Table_Place{address = u64(uintptr(raw_data(db_buf.bytes))), count = u64(len(db_buf.bytes)), capacity = u64(len(db_buf.bytes))}
		col_place := module.Table_Place{address = u64(uintptr(&sqlite_cols[0])), count = 0, capacity = len(sqlite_cols)}
		cell_place := module.Table_Place{address = u64(uintptr(&sqlite_cells[0])), count = 0, capacity = len(sqlite_cells)}
		pay_place := module.Table_Place{address = u64(uintptr(&sqlite_payload[0])), count = 0, capacity = len(sqlite_payload)}
		diag_place := module.Table_Place{address = u64(uintptr(&sqlite_diag[0])), count = 0, capacity = len(sqlite_diag)}
		sum_buf: [1]Sqlite_Query_Summary
		sum_place := module.Table_Place{address = u64(uintptr(&sum_buf[0])), count = 0, capacity = 1}
		err: errors.Error_Record
		ans := exec_fn(&sql_slice, &db_place, &col_place, &cell_place, &pay_place, &diag_place, &sum_place, &err)
		if ans.outcome != .Wrong_State {
			wrong("sqlite session_execute before open must return Wrong_State", u64(ans.outcome), u64(call_outcome.Call_Outcome.Wrong_State))
		}

		bad_opts := Sqlite_Open_Options{fresh = 1, page_size = 1024}
		info_buf: [1]Sqlite_Session_Info
		info_place := module.Table_Place{address = u64(uintptr(&info_buf[0])), count = 0, capacity = 1}
		ans = open_fn(&bad_opts, &db_place, &info_place, &err)
		if ans.outcome != .Argument_Refused || err.kind != i64(errors.Kind.Not_Multiple) {
			wrong("sqlite bad page_size must return Argument_Refused", u64(ans.outcome), u64(call_outcome.Call_Outcome.Argument_Refused))
		}
	}

	// Open fresh database and run SQL + integrity_check + dirty ranges + close.
	open_opts := Sqlite_Open_Options{fresh = 1, page_size = 4096}
	db_place := module.Table_Place{address = u64(uintptr(raw_data(db_buf.bytes))), count = u64(len(db_buf.bytes)), capacity = u64(len(db_buf.bytes))}
	info_buf: [1]Sqlite_Session_Info
	info_place := module.Table_Place{address = u64(uintptr(&info_buf[0])), count = 0, capacity = 1}
	err: errors.Error_Record
	ans := open_fn(&open_opts, &db_place, &info_place, &err)
	if ans.outcome != .Succeeded || info_place.count != 1 || info_buf[0].open != 1 {
		wrong("sqlite session_open failed", u64(ans.outcome), u64(call_outcome.Call_Outcome.Succeeded))
	}

	exec_sql :: proc "contextless" (
		exec_fn: proc "c" (^Sqlite_Text_Slice, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^module.Table_Place, ^errors.Error_Record) -> Sqlite_Answer,
		sql: string,
		db_bytes: []u8,
	) -> (summary: Sqlite_Query_Summary, cells_count: u64) {
		sql_slice := Sqlite_Text_Slice{address = raw_data(sql), count = u64(len(sql))}
		db_p := module.Table_Place{address = u64(uintptr(raw_data(db_bytes))), count = u64(len(db_bytes)), capacity = u64(len(db_bytes))}
		col_p := module.Table_Place{address = u64(uintptr(&sqlite_cols[0])), count = 0, capacity = len(sqlite_cols)}
		cell_p := module.Table_Place{address = u64(uintptr(&sqlite_cells[0])), count = 0, capacity = len(sqlite_cells)}
		pay_p := module.Table_Place{address = u64(uintptr(&sqlite_payload[0])), count = 0, capacity = len(sqlite_payload)}
		diag_p := module.Table_Place{address = u64(uintptr(&sqlite_diag[0])), count = 0, capacity = len(sqlite_diag)}
		sum_buf: [1]Sqlite_Query_Summary
		sum_p := module.Table_Place{address = u64(uintptr(&sum_buf[0])), count = 0, capacity = 1}
		e: errors.Error_Record
		a := exec_fn(&sql_slice, &db_p, &col_p, &cell_p, &pay_p, &diag_p, &sum_p, &e)
		if a.outcome != .Succeeded || sum_p.count != 1 {
			wrong("sqlite session_execute failed", u64(a.outcome), u64(call_outcome.Call_Outcome.Succeeded))
		}
		return sum_buf[0], cell_p.count
	}

	_, _ = exec_sql(exec_fn, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, score INTEGER); INSERT INTO items VALUES (1, 'alpha', 10), (2, 'beta', 32);", db_buf.bytes)
	sum_res, cells_n := exec_sql(exec_fn, "SELECT sum(score), count(*) FROM items;", db_buf.bytes)
	if sum_res.row_count != 1 || cells_n != 2 || sqlite_cells[0].value_kind != u8(Sqlite_Value_Kind.Integer) || sqlite_cells[0].integer_or_bits != 42 || sqlite_cells[1].integer_or_bits != 2 {
		wrong("sqlite SELECT sum/count mismatch", u64(sqlite_cells[0].integer_or_bits), 42)
	}

	_, chk_n := exec_sql(exec_fn, "PRAGMA integrity_check;", db_buf.bytes)
	if chk_n != 1 || sqlite_cells[0].value_kind != u8(Sqlite_Value_Kind.Text) {
		wrong("sqlite integrity_check did not return text", chk_n, 1)
	}
	chk_text := sqlite_payload[sqlite_cells[0].payload_offset:][:sqlite_cells[0].payload_length]
	if !bytes_equal(chk_text, transmute([]u8)string("ok")) {
		wrong("sqlite integrity_check was not ok", u64(len(chk_text)), 2)
	}

	dirty_place := module.Table_Place{address = u64(uintptr(&sqlite_dirty[0])), count = 0, capacity = len(sqlite_dirty)}
	dirty_ans := dirty_fn(&dirty_place, &err)
	if dirty_ans.outcome != .Succeeded || dirty_place.count == 0 {
		wrong("sqlite session_dirty_ranges returned no dirty ranges", dirty_place.count, 1)
	}
	sync_ans := synced_fn(&err)
	if sync_ans.outcome != .Succeeded {
		wrong("sqlite session_mark_synced failed", u64(sync_ans.outcome), u64(call_outcome.Call_Outcome.Succeeded))
	}
	close_ans := close_fn(&db_place, &err)
	if close_ans.outcome != .Succeeded {
		wrong("sqlite session_close failed", u64(close_ans.outcome), u64(call_outcome.Call_Outcome.Succeeded))
	}

	system.log_fact(.Info, Sqlite_Verified{version = u64(version), sum = 42, rows = 2, module_hash = value_kinds.Hash_Field(mod_hash)})
}

@(private = "file")
run_lua_live :: proc "contextless" () {
	mod_buf, mod_len := store_read_object("lua.module")
	defer buffer_free(&mod_buf)
	file := mod_buf.bytes[:mod_len]
	mod_hash := blake3.hash(file)

	space := system.Module_Space{next = op.MODULE_BASE}
	load_err: module.Load_Error
	place, loaded := system.module_space_load(&space, file, &load_err)
	if !loaded {
		wrong("lua.module load failed", u64(load_err.stage), 0)
	}
	defer {
		_ = system.module_space_release(&space, place, &load_err)
	}
	base := space.modules[place].base

	req_size_fn := (proc "c" () -> i64)(module_export_ptr(file, base, "script_request_size"))
	run_fn := (proc "c" (request_address: i64) -> i64)(module_export_ptr(file, base, "script_run"))
	if req_size_fn() != size_of(Lua_Run_Request) {
		wrong("lua script_request_size ABI mismatch", u64(req_size_fn()), size_of(Lua_Run_Request))
	}

	heap_buf := buffer_alloc(LIB_HEAP_BYTES / system.PAGE_SIZE)
	defer buffer_free(&heap_buf)

	// Refusal first: syntax error must return Error_Syntax and zero leaked bytes.
	{
		bad_src := cstring("print('a' ..)")
		req := Lua_Run_Request{
			arena               = raw_data(heap_buf.bytes),
			arena_size          = i64(len(heap_buf.bytes)),
			source              = bad_src,
			output              = &lua_output[0],
			output_capacity     = len(lua_output),
			diagnostic          = &lua_diagnostic[0],
			diagnostic_capacity = len(lua_diagnostic),
		}
		status := run_fn(i64(uintptr(&req)))
		if status != i64(Lua_Status.Error_Syntax) || req.live_bytes_after_close != 0 {
			wrong("lua syntax error refusal failed", u64(status), u64(Lua_Status.Error_Syntax))
		}
	}

	// Real Lua script exercising closures, tables, coroutines, math, string, and utf8.
	script := cstring("local function acc(s) return function(x) s = s + x return s end end local a = acc(10) local t = {a(5), a(27)} local co = coroutine.wrap(function() coroutine.yield(t[1] + t[2]) end) print(string.format('%d|%d|%d|%d', t[1], t[2], co(), math.floor(math.sqrt(144)) + utf8.len('modus')))")
	expected := "15|42|57|17\n"
	req := Lua_Run_Request{
		arena               = raw_data(heap_buf.bytes),
		arena_size          = i64(len(heap_buf.bytes)),
		source              = script,
		output              = &lua_output[0],
		output_capacity     = len(lua_output),
		diagnostic          = &lua_diagnostic[0],
		diagnostic_capacity = len(lua_diagnostic),
	}
	status := run_fn(i64(uintptr(&req)))
	if status != i64(Lua_Status.Ok) || req.live_bytes_after_close != 0 {
		wrong("lua script execution failed or leaked heap", u64(status), u64(Lua_Status.Ok))
	}
	got := lua_output[:min(int(req.output_length), len(lua_output))]
	if !bytes_equal(got, transmute([]u8)expected) {
		wrong("lua script output mismatch", u64(len(got)), u64(len(expected)))
	}

	system.log_fact(.Info, Lua_Verified{output_bytes = u64(len(got)), module_hash = value_kinds.Hash_Field(mod_hash)})
}

@(private = "file")
run_zstd_live :: proc "contextless" () {
	mod_buf, mod_len := store_read_object("zstd.module")
	defer buffer_free(&mod_buf)
	file := mod_buf.bytes[:mod_len]
	mod_hash := blake3.hash(file)

	space := system.Module_Space{next = op.MODULE_BASE}
	load_err: module.Load_Error
	place, loaded := system.module_space_load(&space, file, &load_err)
	if !loaded {
		wrong("zstd.module load failed", u64(load_err.stage), 0)
	}
	defer {
		_ = system.module_space_release(&space, place, &load_err)
	}
	base := space.modules[place].base

	version_fn := (proc "c" () -> i64)(module_export_ptr(file, base, "zstd_version_number"))
	bind_fn := (proc "c" (arena, size: i64) -> i64)(module_export_ptr(file, base, "zstd_heap_bind"))
	live_fn := (proc "c" () -> i64)(module_export_ptr(file, base, "zstd_heap_live_bytes"))
	bound_fn := (proc "c" (count: i64) -> i64)(module_export_ptr(file, base, "zstd_compress_bound"))
	comp_fn := (proc "c" (src, count, dst, cap, level: i64) -> i64)(module_export_ptr(file, base, "zstd_compress"))
	decomp_fn := (proc "c" (src, count, dst, cap: i64) -> i64)(module_export_ptr(file, base, "zstd_decompress"))
	content_size_fn := (proc "c" (src, count: i64) -> i64)(module_export_ptr(file, base, "zstd_frame_content_size"))

	version := version_fn()
	if version != 10507 {
		wrong("unexpected zstd version", u64(version), 10507)
	}

	heap_buf := buffer_alloc(LIB_HEAP_BYTES / system.PAGE_SIZE)
	defer buffer_free(&heap_buf)
	if bind_fn(i64(uintptr(raw_data(heap_buf.bytes))), i64(len(heap_buf.bytes))) != 0 {
		wrong("zstd_heap_bind failed", 1, 0)
	}

	// Refusal first: decompressing invalid magic bytes returns negative error.
	bad_frame := [8]u8{'B', 'A', 'D', '!', 0, 0, 0, 0}
	if bad_res := decomp_fn(i64(uintptr(&bad_frame[0])), len(bad_frame), i64(uintptr(&zstd_restored[0])), ZSTD_VECTOR_BYTES); bad_res >= 0 {
		wrong("zstd must refuse invalid magic frame", u64(bad_res), 0)
	}

	// Fill deterministic 16 KiB payload matching tools/modustool/build/c_world_recipes.odin.
	phrase := ZSTD_VECTOR_PHRASE
	for i in 0 ..< ZSTD_VECTOR_BYTES {
		zstd_payload[i] = phrase[i % len(phrase)] ~ u8((i / len(phrase)) & 0x1F)
	}

	cap_bytes := bound_fn(ZSTD_VECTOR_BYTES)
	if cap_bytes <= 0 {
		wrong("zstd_compress_bound failed", 0, 1)
	}
	comp_pages := (u64(cap_bytes) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	comp_buf := buffer_alloc(comp_pages)
	defer buffer_free(&comp_buf)

	comp_len := comp_fn(i64(uintptr(&zstd_payload[0])), ZSTD_VECTOR_BYTES, i64(uintptr(raw_data(comp_buf.bytes))), cap_bytes, ZSTD_VECTOR_LEVEL)
	if comp_len <= 0 || comp_len > cap_bytes {
		wrong("zstd_compress failed", u64(comp_len), u64(cap_bytes))
	}
	if declared := content_size_fn(i64(uintptr(raw_data(comp_buf.bytes))), comp_len); declared != ZSTD_VECTOR_BYTES {
		wrong("zstd_frame_content_size mismatch", u64(declared), ZSTD_VECTOR_BYTES)
	}
	decomp_len := decomp_fn(i64(uintptr(raw_data(comp_buf.bytes))), comp_len, i64(uintptr(&zstd_restored[0])), ZSTD_VECTOR_BYTES)
	if decomp_len != ZSTD_VECTOR_BYTES || !bytes_equal(zstd_restored[:], zstd_payload[:]) {
		wrong("zstd round-trip mismatch", u64(decomp_len), ZSTD_VECTOR_BYTES)
	}
	if live := live_fn(); live != 0 {
		wrong("zstd leaked heap bytes", u64(live), 0)
	}

	frame_hash := blake3.hash(comp_buf.bytes[:comp_len])
	system.log_fact(.Info, Zstd_Verified{
		version          = u64(version),
		compressed_bytes = u64(comp_len),
		frame_hash       = value_kinds.Hash_Field(frame_hash),
		module_hash      = value_kinds.Hash_Field(mod_hash),
	})
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	opened, store_ok := storage.open(ctx)
	if !store_ok {
		wrong("missing private store grant", 0, 1)
	}
	store_client = opened

	image_handle = ctx.handles[system.GRANT_IMAGE]
	image_addr, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Succeeded {
		wrong("cannot map boot image", u64(map_status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	image_bytes = ([^]u8)(image_addr)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	compiler_file = system.image_find(image_bytes, "c_compiler")
	assembler_file = system.image_find(image_bytes, "assemble")
	if len(compiler_file) == 0 || len(assembler_file) == 0 {
		wrong("boot image lacks c_compiler or assemble", u64(len(compiler_file)), 1)
	}
	compile_unit_export = module.export_find(compiler_file, "compile_unit")
	assemble_program_export = module.export_find(assembler_file, "assemble_program")
	if compile_unit_export == 0 || assemble_program_export == 0 {
		wrong("missing compile_unit or assemble_program export", u64(compile_unit_export), 1)
	}

	check_refusals()
	run_chibicc_self_host()
	run_sqlite_live()
	run_lua_live()
	run_zstd_live()

	storage.close(&store_client)
	system.log_fact(.Info, Probe_Passed{})
	system.stop(.Done)
}
