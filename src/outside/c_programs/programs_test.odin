#+build !freestanding
// The host tests of the test programs of the adapters: the codec over the
// configuration of zstd, the scripting language over the configuration of
// Lua, and the VFS of SQLite with the key-value store that uses it.
package c_programs

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:testing"

// ---- The codec over the configuration of zstd ------------------------------------------------

Codec_Refusal :: enum i64 {
	Bad_Argument      = -1,
	Truncated         = -2,
	Bad_Magic         = -3,
	Bad_Offset        = -4,
	Size_Mismatch     = -5,
	Bad_Checksum      = -6,
	Output_Too_Small  = -7,
	Out_Of_Memory     = -8,
	Input_Too_Large   = -9,
}

CODEC_HEADER_SIZE :: 12

@(private = "file")
make_heap :: proc(loaded: Loaded_Module, heap: ^Heap_Record, size: int) -> []u8 {
	arena := make([]u8, size)
	fmt.assertf(call(loaded, "call_heap_init", address_of(heap), address_of(raw_data(arena)), i64(size)) == 0, "a heap of %d bytes", size)
	return arena
}

@(private = "file")
codec_inputs :: proc(generator: ^Generator) -> [][]u8 {
	inputs := make([dynamic][]u8, context.temp_allocator)
	single := make([]u8, 1, context.temp_allocator)
	single[0] = 7
	append(&inputs, []u8{}, single, transmute([]u8)string("abcde"), transmute([]u8)string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
	random := make([]u8, 100_000, context.temp_allocator)
	for &byte in random {
		byte = u8(next_word(generator))
	}
	append(&inputs, random)
	text := strings.repeat("the store keeps each module by its hash; ", 4000, context.temp_allocator)
	append(&inputs, transmute([]u8)text)
	// Runs, and a repeat at a distance past the largest offset of a match.
	runs := make([]u8, 300_000, context.temp_allocator)
	for &byte, index in runs {
		byte = u8((index / 1000) % 7)
	}
	append(&inputs, runs)
	far := make([]u8, 140_000, context.temp_allocator)
	copy(far, random[:70_000])
	copy(far[70_000:], random[:70_000])
	append(&inputs, far)
	return inputs[:]
}

@(test)
codec_round_trips_and_checks_its_frames :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 16)
	defer delete(arena)
	generator := Generator{0x5eed_0006}
	for input, index in codec_inputs(&generator) {
		testing.expect_value(t, u32(call(loaded, "call_codec_crc32", address_of(raw_data(input)), i64(len(input)))), hash.crc32(input))
		capacity := len(input) + len(input) / 128 + 64
		frame := make([]u8, capacity, context.temp_allocator)
		frame_size := call(loaded, "call_codec_compress", address_of(&heap), address_of(raw_data(input)), i64(len(input)), address_of(raw_data(frame)), i64(capacity))
		if !testing.expectf(t, frame_size > 0, "input %d: the compression gives %v", index, Codec_Refusal(frame_size)) {
			continue
		}
		testing.expect_value(t, heap.live_bytes, uint(0))
		output := make([]u8, len(input) + 1, context.temp_allocator)
		output_size := call(loaded, "call_codec_decompress", address_of(raw_data(frame)), frame_size, address_of(raw_data(output)), i64(len(output)))
		testing.expectf(t, output_size == i64(len(input)) && slice.equal(output[:len(input)], input), "input %d of %d bytes: the round trip gives %d bytes", index, len(input), output_size)
		fmt.printfln("c_programs: codec input %d: %d bytes to %d bytes", index, len(input), frame_size)
		// A capacity one byte too small is refused before any write.
		if len(input) > 0 {
			testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_decompress", address_of(raw_data(frame)), frame_size, address_of(raw_data(output)), i64(len(input) - 1))), Codec_Refusal.Output_Too_Small)
		}
	}
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	repetitive := codec_inputs(&generator)[5]
	frame := make([]u8, len(repetitive), context.temp_allocator)
	size := call(loaded, "call_codec_compress", address_of(&heap), address_of(raw_data(repetitive)), i64(len(repetitive)), address_of(raw_data(frame)), i64(len(frame)))
	testing.expectf(t, size > 0 && size * 20 < i64(len(repetitive)), "a repetitive text compresses to less than 5 percent: %d of %d", size, len(repetitive))
}

@(test)
codec_refuses_damaged_frames :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 16)
	defer delete(arena)
	input := transmute([]u8)strings.repeat("modus keeps one store; abcdefghij 0123456789 ", 20, context.temp_allocator)
	frame := make([]u8, 2048, context.temp_allocator)
	frame_size := call(loaded, "call_codec_compress", address_of(&heap), address_of(raw_data(input)), i64(len(input)), address_of(raw_data(frame)), i64(len(frame)))
	testing.expect(t, frame_size > CODEC_HEADER_SIZE)
	frame = frame[:frame_size]
	output := make([]u8, len(input) + 64, context.temp_allocator)
	// Each shorter prefix of the frame is refused.
	for length in 0 ..< len(frame) {
		result := call(loaded, "call_codec_decompress", address_of(raw_data(frame)), i64(length), address_of(raw_data(output)), i64(len(output)))
		testing.expectf(t, result < 0, "a prefix of %d of %d bytes must be refused, not give %d", length, len(frame), result)
	}
	// Each change of one byte is refused: the checksum covers the content,
	// and the header and the sequences are checked before any write.
	damaged := slice.clone(frame, context.temp_allocator)
	for index in 0 ..< len(frame) {
		for flip in ([?]u8{0x01, 0x80, 0xff}) {
			copy(damaged, frame)
			damaged[index] ~= flip
			canary := make([]u8, len(input) + 64, context.temp_allocator)
			slice.fill(canary, 0x5a)
			result := call(loaded, "call_codec_decompress", address_of(raw_data(damaged)), i64(len(damaged)), address_of(raw_data(canary)), i64(len(input)))
			testing.expectf(t, result < 0, "a change of byte %d by %x must be refused, not give %d", index, flip, result)
			for byte in canary[len(input):] {
				if byte != 0x5a {
					testing.expectf(t, false, "a damaged frame wrote past the capacity")
					return
				}
			}
		}
	}
	// The named refusals.
	bad_magic := slice.clone(frame, context.temp_allocator)
	bad_magic[0] = 'X'
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_decompress", address_of(raw_data(bad_magic)), i64(len(bad_magic)), address_of(raw_data(output)), i64(len(output)))), Codec_Refusal.Bad_Magic)
	// A match at offset 0, and a match before the first byte.
	handmade := [?]u8{'M', 'C', 'Z', '1', 8, 0, 0, 0, 0, 0, 0, 0, 0x10, 'a', 0, 0, 0x00}
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_decompress", address_of(&handmade), len(handmade), address_of(raw_data(output)), i64(len(output)))), Codec_Refusal.Bad_Offset)
	handmade[14] = 2
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_decompress", address_of(&handmade), len(handmade), address_of(raw_data(output)), i64(len(output)))), Codec_Refusal.Bad_Offset)
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_decompress", 0, 20, address_of(raw_data(output)), i64(len(output)))), Codec_Refusal.Bad_Argument)
	// A compression with no room or no memory is refused.
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_compress", address_of(&heap), address_of(raw_data(input)), i64(len(input)), address_of(raw_data(output)), CODEC_HEADER_SIZE)), Codec_Refusal.Output_Too_Small)
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_compress", address_of(&heap), address_of(raw_data(input)), i64(len(input)), address_of(raw_data(output)), 40)), Codec_Refusal.Output_Too_Small)
	small: Heap_Record
	small_arena := make_heap(loaded, &small, 1024)
	defer delete(small_arena)
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_compress", address_of(&small), address_of(raw_data(input)), i64(len(input)), address_of(raw_data(output)), i64(len(output)))), Codec_Refusal.Out_Of_Memory)
	testing.expect_value(t, Codec_Refusal(call(loaded, "call_codec_compress", 0, address_of(raw_data(input)), i64(len(input)), address_of(raw_data(output)), i64(len(output)))), Codec_Refusal.Bad_Argument)
	testing.expect_value(t, heap.live_bytes, uint(0))
}

// ---- The scripting language over the configuration of Lua -----------------------------------

Script_Status :: enum i64 {
	Done            = 0,
	Syntax_Error    = -1,
	Runtime_Error   = -2,
	Out_Of_Memory   = -3,
	Step_Limit      = -4,
	Output_Overflow = -5,
	Bad_Argument    = -6,
}

// The layout of Script_Request in programs/entry.c.
Script_Request :: struct {
	source:              rawptr,
	source_count:        i64,
	output:              rawptr,
	output_capacity:     i64,
	diagnostic:          rawptr,
	diagnostic_capacity: i64,
	heap:                rawptr,
	output_length:       i64,
	diagnostic_length:   i64,
}

Script_Result :: struct {
	status:     Script_Status,
	output:     string,
	diagnostic: string,
}

@(private = "file")
run_script :: proc(loaded: Loaded_Module, heap: ^Heap_Record, source: string, output_capacity := 4096) -> Script_Result {
	output := make([]u8, output_capacity, context.temp_allocator)
	diagnostic := make([]u8, 512, context.temp_allocator)
	// The source is lent without a terminating zero: the language reads its
	// count of bytes only.
	source_bytes := slice.clone(transmute([]u8)source, context.temp_allocator)
	request := Script_Request {
		source              = raw_data(source_bytes),
		source_count        = i64(len(source)),
		output              = raw_data(output),
		output_capacity     = i64(output_capacity),
		diagnostic          = raw_data(diagnostic),
		diagnostic_capacity = i64(len(diagnostic)),
		heap                = heap,
	}
	status := Script_Status(call(loaded, "call_script_run", address_of(&request)))
	return {status, string(output[:request.output_length]), string(diagnostic[:request.diagnostic_length])}
}

@(test)
script_runs_programs_with_the_numbers_of_lua :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 20)
	defer delete(arena)
	Case :: struct {
		source: string,
		output: string,
	}
	cases := [?]Case {
		{"print(1+2)", "3\n"},
		{"", ""},
		{"-- a comment\nprint(1)", "1\n"},
		{"print(7//2, 7%3, -7//2, -7%3, 7/2)", "3\t1\t-4\t2\t3.5\n"},
		{"print(7.5//2, -7.5%2, 5.25 % -2)", "3.0\t0.5\t-0.75\n"},
		{"print(0.1+0.2, 1e100, 1/3, 3.0, -0.0, 1e15)", "0.3\t1e+100\t0.33333333333333\t3.0\t-0.0\t1e+15\n"},
		{"print(1/0, -1/0)", "inf\t-inf\n"},
		{"print(9223372036854775807 + 1, -9223372036854775807 - 2)", "-9223372036854775808\t9223372036854775807\n"},
		{"print(9223372036854775808, 0x10, 0xff, 1e2, .5, 3.)", "9.2233720368548e+18\t16\t255\t100.0\t0.5\t3.0\n"},
		{"local m = -9223372036854775807 - 1 print(m // -1, m % -1, 0x7fffffffffffffff + 1, 0xffffffffffffffff)", "-9223372036854775808\t0\t-9223372036854775808\t-1\n"},
		{"local s = 0 local i = 1 while i <= 100 do s = s + i i = i + 1 end print(s)", "5050\n"},
		{"local a = 0 local b = 1 local n = 0 while n < 90 do local c = a + b a = b b = c n = n + 1 end print(a)", "2880067194370816120\n"},
		{"local s = \"a\" .. 1 .. 2.5 print(s, \"x\" .. \"y\" .. \"z\")", "a12.5\txyz\n"},
		{"print(nil or 5, false and 1, 1 and 2, nil and nil, false or nil)", "5\tfalse\t2\tnil\tnil\n"},
		{"print(1 < 2, 2 <= 1, 1 == 1.0, \"a\" == \"a\", 1 ~= 2, \"abc\" < \"abd\", not nil)", "true\tfalse\ttrue\ttrue\ttrue\ttrue\ttrue\n"},
		{"if 1 > 2 then print(1) else print(2) end if nil then print(3) end print(4)", "2\n4\n"},
		{"local x = 1 if true then local x = 2 print(x) end print(x)", "2\n1\n"},
		{"local s = \"\" local i = 0 while i < 200 do s = s .. \"ab\" i = i + 1 end print(s == s, 0 == 0.0)", "true\ttrue\n"},
	}
	for test_case in cases {
		result := run_script(loaded, &heap, test_case.source)
		testing.expectf(t, result.status == .Done && result.output == test_case.output, "%q gives %v %q %q, not %q", test_case.source, result.status, result.output, result.diagnostic, test_case.output)
		testing.expect_value(t, heap.live_bytes, uint(0))
		testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	}
}

@(test)
script_refuses_bad_programs_with_their_line :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 20)
	defer delete(arena)
	Case :: struct {
		source:     string,
		status:     Script_Status,
		diagnostic: string,
	}
	deep := strings.concatenate({"print(", strings.repeat("(1+", 300, context.temp_allocator), "1", strings.repeat(")", 300, context.temp_allocator), ")"}, context.temp_allocator)
	cases := [?]Case {
		{"print(1//0)", .Runtime_Error, "line 1: attempt to perform 'n//0'\n"},
		{"\n\nprint(1%0)", .Runtime_Error, "line 3: attempt to perform 'n%0'\n"},
		{"error(\"boom\")", .Runtime_Error, "line 1: boom\n"},
		{"error(42)", .Runtime_Error, "line 1: 42\n"},
		{"print(", .Syntax_Error, "line 1: unexpected token\n"},
		{"x = 1", .Syntax_Error, "line 1: unknown variable\n"},
		{"local 5 = 3", .Syntax_Error, "line 1: name expected\n"},
		{"print(\"abc)", .Syntax_Error, "line 1: unfinished string\n"},
		{"print(1 +)", .Syntax_Error, "line 1: unexpected token\n"},
		{"print(1 $ 2)", .Syntax_Error, "line 1: unexpected symbol\n"},
		{"print(2^3)", .Syntax_Error, "line 1: unexpected symbol\n"},
		{"print(1e)", .Syntax_Error, "line 1: malformed number\n"},
		{"end", .Syntax_Error, "line 1: statement expected\n"},
		{"while true do", .Syntax_Error, "line 1: 'end' expected\n"},
		{"print(1 < \"a\")", .Runtime_Error, "line 1: attempt to compare two values of different kinds\n"},
		{"print(\"a\" + 1)", .Runtime_Error, "line 1: attempt to perform arithmetic on a non-number value\n"},
		{"print(nil .. \"a\")", .Runtime_Error, "line 1: attempt to concatenate a value that is no string\n"},
		{"print(-nil)", .Runtime_Error, "line 1: attempt to perform arithmetic on a non-number value\n"},
		{"while true do end", .Step_Limit, "line 1: step limit reached\n"},
		{deep, .Runtime_Error, "line 1: stack overflow\n"},
	}
	for test_case in cases {
		result := run_script(loaded, &heap, test_case.source)
		testing.expectf(t, result.status == test_case.status && result.diagnostic == test_case.diagnostic, "%q gives %v %q, not %v %q", test_case.source[:min(len(test_case.source), 40)], result.status, result.diagnostic, test_case.status, test_case.diagnostic)
		testing.expect_value(t, heap.live_bytes, uint(0))
		testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	}
	// The output that does not fit is cut at its capacity and refused.
	result := run_script(loaded, &heap, "print(\"hello\")", 4)
	testing.expect_value(t, result.status, Script_Status.Output_Overflow)
	testing.expect_value(t, result.output, "hell")
	// A program that takes the whole heap ends with Out_Of_Memory, and its
	// memory comes back.
	small: Heap_Record
	small_arena := make_heap(loaded, &small, 96 * 1024)
	defer delete(small_arena)
	result = run_script(loaded, &small, "local s = \"abcdefgh\" while true do s = s .. s end")
	testing.expect_value(t, result.status, Script_Status.Out_Of_Memory)
	testing.expect_value(t, small.live_bytes, uint(0))
	testing.expect_value(t, heap_fault(loaded, &small), Heap_Fault.None)
	tiny: Heap_Record
	tiny_arena := make_heap(loaded, &tiny, 1024)
	defer delete(tiny_arena)
	testing.expect_value(t, run_script(loaded, &tiny, "print(1)").status, Script_Status.Out_Of_Memory)
	// No source, or no heap.
	request := Script_Request{}
	testing.expect_value(t, Script_Status(call(loaded, "call_script_run", address_of(&request))), Script_Status.Bad_Argument)
}

// ---- The VFS of SQLite --------------------------------------------------------------------------

SQLITE_OK :: 0
SQLITE_BUSY :: 5
SQLITE_FULL :: 13
SQLITE_CANTOPEN :: 14
SQLITE_MISUSE :: 21
SQLITE_IOERR_READ :: 10 | (1 << 8)
SQLITE_IOERR_SHORT_READ :: 10 | (2 << 8)
SQLITE_IOERR_WRITE :: 10 | (3 << 8)
SQLITE_IOERR_TRUNCATE :: 10 | (6 << 8)
SQLITE_IOERR_UNLOCK :: 10 | (8 << 8)
SQLITE_IOERR_DELETE :: 10 | (10 << 8)
SQLITE_IOERR_ACCESS :: 10 | (13 << 8)
SQLITE_IOERR_LOCK :: 10 | (15 << 8)
SQLITE_IOERR_DELETE_NOENT :: 10 | (23 << 8)
SQLITE_OPEN_READONLY :: 0x1
SQLITE_OPEN_READWRITE :: 0x2
SQLITE_OPEN_CREATE :: 0x4
SQLITE_OPEN_DELETEONCLOSE :: 0x8
SQLITE_OPEN_EXCLUSIVE :: 0x10
SQLITE_OPEN_MAIN_DB :: 0x100

Lock_Level :: enum i64 {
	None      = 0,
	Shared    = 1,
	Reserved  = 2,
	Pending   = 3,
	Exclusive = 4,
}

// The place of the size of the first file in a Modus_Vfs_Store: after its
// name of 64 bytes, its address and its capacity (sqlite/modus_vfs.h).
FIRST_SLOT_SIZE_OFFSET :: 64 + 8 + 8

Vfs_Fixture :: struct {
	loaded:     Loaded_Module,
	store:      []u8,
	vfs:        []u8,
	bytes:      []u8,
	file_size:  int,
}

@(private = "file")
vfs_fixture :: proc(t: ^testing.T, loaded: Loaded_Module, capacities: []i64, seed: i64 = 1) -> (fixture: Vfs_Fixture, ok: bool) {
	sizes: [3]i64
	call(loaded, "call_vfs_record_sizes", address_of(&sizes))
	fixture.loaded = loaded
	fixture.store = make([]u8, sizes[0], context.temp_allocator)
	fixture.vfs = make([]u8, sizes[1], context.temp_allocator)
	fixture.file_size = int(sizes[2])
	total: i64
	for capacity in capacities {
		total += capacity
	}
	fixture.bytes = make([]u8, total, context.temp_allocator)
	code := call(loaded, "call_vfs_store_init", address_of(raw_data(fixture.store)), address_of(raw_data(fixture.bytes)), total, address_of(raw_data(capacities)), i64(len(capacities)), seed)
	if !testing.expect_value(t, code, SQLITE_OK) {
		return
	}
	testing.expect_value(t, call(loaded, "call_vfs_make", address_of(raw_data(fixture.vfs)), address_of(raw_data(fixture.store))), address_of(raw_data(fixture.vfs)))
	return fixture, true
}

@(private = "file")
new_file :: proc(fixture: Vfs_Fixture) -> i64 {
	return address_of(raw_data(make([]u8, fixture.file_size, context.temp_allocator)))
}

@(private = "file")
open_file :: proc(fixture: Vfs_Fixture, name: string, flags: i64) -> (file: i64, code: i64) {
	file = new_file(fixture)
	name_address := name == "\x00" ? 0 : text_address(name)
	code = call(fixture.loaded, "call_vfs_open", address_of(raw_data(fixture.vfs)), name_address, file, flags)
	return
}

@(private = "file")
file_size :: proc(fixture: Vfs_Fixture, file: i64) -> i64 {
	size: i64 = -1
	fmt.assertf(call(fixture.loaded, "call_file_size", file, address_of(&size)) == SQLITE_OK, "xFileSize")
	return size
}

@(test)
vfs_refuses_bad_stores_and_bad_opens :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	sizes: [3]i64
	call(loaded, "call_vfs_record_sizes", address_of(&sizes))
	store := make([]u8, sizes[0], context.temp_allocator)
	bytes := make([]u8, 4096, context.temp_allocator)
	capacities := [?]i64{2048, 2048, 1, 1, 1, 1, 1, 1, 1}
	init :: proc(loaded: Loaded_Module, store, bytes: []u8, byte_count: i64, capacities: []i64) -> i64 {
		return call(loaded, "call_vfs_store_init", address_of(raw_data(store)), address_of(raw_data(bytes)), byte_count, address_of(raw_data(capacities)), i64(len(capacities)), 7)
	}
	testing.expect_value(t, init(loaded, store, bytes, 4096, capacities[:0]), SQLITE_MISUSE)
	testing.expect_value(t, init(loaded, store, bytes, 4096, capacities[:9]), SQLITE_MISUSE)
	testing.expect_value(t, init(loaded, store, bytes, 4095, capacities[:2]), SQLITE_MISUSE)
	testing.expect_value(t, init(loaded, store, bytes, -1, capacities[:2]), SQLITE_MISUSE)
	zero := [?]i64{2048, 0}
	testing.expect_value(t, init(loaded, store, bytes, 4096, zero[:]), SQLITE_MISUSE)
	negative := [?]i64{2048, -2048}
	testing.expect_value(t, init(loaded, store, bytes, 4096, negative[:]), SQLITE_MISUSE)
	huge := [?]i64{max(i64), 1}
	testing.expect_value(t, init(loaded, store, bytes, 4096, huge[:]), SQLITE_MISUSE)
	testing.expect_value(t, call(loaded, "call_vfs_store_init", address_of(raw_data(store)), 0, 4096, address_of(&capacities), 2, 7), SQLITE_MISUSE)
	testing.expect_value(t, init(loaded, store, bytes, 4096, capacities[:2]), SQLITE_OK)

	slots := [?]i64{32768, 16384, 16384}
	fixture, made := vfs_fixture(t, loaded, slots[:])
	if !made {
		return
	}
	Open_Case :: struct {
		name:  string,
		flags: i64,
	}
	refused := [?]Open_Case {
		{"main.db", SQLITE_OPEN_READWRITE},
		{"main.db", 0},
		{"main.db", SQLITE_OPEN_READONLY | SQLITE_OPEN_READWRITE},
		{"main.db", SQLITE_OPEN_READONLY | SQLITE_OPEN_CREATE},
		{"", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE},
		{strings.repeat("n", 64, context.temp_allocator), SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE},
		{"\x00", SQLITE_OPEN_READONLY},
	}
	for open_case in refused {
		file, code := open_file(fixture, open_case.name, open_case.flags)
		testing.expectf(t, code == SQLITE_CANTOPEN, "the open of %q with %x gives %d", open_case.name, open_case.flags, code)
		// A failed open leaves no methods, so SQLite calls no xClose.
		testing.expect_value(t, (^u64)(uintptr(file))^, 0)
	}
	longest, code := open_file(fixture, strings.repeat("n", 63, context.temp_allocator), SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	testing.expect_value(t, code, SQLITE_OK)
	main_file, main_code := open_file(fixture, "main.db", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MAIN_DB)
	testing.expect_value(t, main_code, SQLITE_OK)
	_, exclusive_code := open_file(fixture, "main.db", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE)
	testing.expect_value(t, exclusive_code, SQLITE_CANTOPEN)
	third, third_code := open_file(fixture, "third", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	testing.expect_value(t, third_code, SQLITE_OK)
	// Each slot is taken: a fourth name finds no room.
	_, full_code := open_file(fixture, "fourth", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	testing.expect_value(t, full_code, SQLITE_CANTOPEN)
	// The first file took the first slot: the largest.
	data := make([]u8, 32768, context.temp_allocator)
	testing.expect_value(t, call(loaded, "call_file_write", longest, address_of(raw_data(data)), 32768, 0), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_write", main_file, address_of(raw_data(data)), 16385, 0), SQLITE_FULL)
	for file in ([?]i64{longest, main_file, third}) {
		testing.expect_value(t, call(loaded, "call_file_close", file), SQLITE_OK)
	}
	// A closed file still exists and keeps its slot until it is deleted.
	_, still_full := open_file(fixture, "fourth", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	testing.expect_value(t, still_full, SQLITE_CANTOPEN)
	testing.expect_value(t, call(loaded, "call_vfs_delete", address_of(raw_data(fixture.vfs)), text_address("third")), SQLITE_OK)
	// A temporary file has a name of its own and goes at its close.
	temporary, temporary_code := open_file(fixture, "\x00", SQLITE_OPEN_READWRITE)
	testing.expect_value(t, temporary_code, SQLITE_OK)
	exists: i64
	testing.expect_value(t, call(loaded, "call_file_write", temporary, text_address("x"), 1, 0), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_vfs_access", address_of(raw_data(fixture.vfs)), text_address("modus-temporary-0"), 0, address_of(&exists)), SQLITE_OK)
	testing.expect_value(t, exists, 1)
	testing.expect_value(t, call(loaded, "call_file_close", temporary), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_vfs_access", address_of(raw_data(fixture.vfs)), text_address("modus-temporary-0"), 0, address_of(&exists)), SQLITE_OK)
	testing.expect_value(t, exists, 0)
}

@(test)
vfs_reads_writes_and_truncates_within_the_slot :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	slots := [?]i64{4096, 4096}
	fixture, made := vfs_fixture(t, loaded, slots[:])
	if !made {
		return
	}
	file, code := open_file(fixture, "main.db", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	testing.expect_value(t, code, SQLITE_OK)
	testing.expect_value(t, file_size(fixture, file), 0)
	pattern := make([]u8, 100, context.temp_allocator)
	for &byte, index in pattern {
		byte = u8(index + 1)
	}
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 100, 0), SQLITE_OK)
	read := make([]u8, 200, context.temp_allocator)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), 100, 0), SQLITE_OK)
	testing.expect(t, slice.equal(read[:100], pattern))
	// A read past the end gives zeros and SQLITE_IOERR_SHORT_READ.
	slice.fill(read, 0xee)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), 10, 95), SQLITE_IOERR_SHORT_READ)
	testing.expect(t, slice.equal(read[:5], pattern[95:]))
	testing.expect(t, slice.all_of(read[5:10], 0))
	testing.expect_value(t, read[10], 0xee)
	slice.fill(read, 0xee)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), 50, 5000), SQLITE_IOERR_SHORT_READ)
	testing.expect(t, slice.all_of(read[:50], 0))
	// A write after the end leaves a hole that reads as zeros.
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 10, 1000), SQLITE_OK)
	testing.expect_value(t, file_size(fixture, file), 1010)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), 200, 100), SQLITE_OK)
	testing.expect(t, slice.all_of(read[:200], 0))
	// The edges of the capacity: up to it, and one byte past it.
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 10, 4086), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 11, 4086), SQLITE_FULL)
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 1, 4096), SQLITE_FULL)
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 1, max(i64)), SQLITE_FULL)
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), 1, -1), SQLITE_IOERR_WRITE)
	testing.expect_value(t, call(loaded, "call_file_write", file, address_of(raw_data(pattern)), -1, 0), SQLITE_IOERR_WRITE)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), -1, 0), SQLITE_IOERR_READ)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), 1, -1), SQLITE_IOERR_READ)
	testing.expect_value(t, file_size(fixture, file), 4096)
	// A truncate that shrinks, then grows: the old bytes read as zeros.
	testing.expect_value(t, call(loaded, "call_file_truncate", file, 50), SQLITE_OK)
	testing.expect_value(t, file_size(fixture, file), 50)
	testing.expect_value(t, call(loaded, "call_file_truncate", file, 200), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_read", file, address_of(raw_data(read)), 200, 0), SQLITE_OK)
	testing.expect(t, slice.equal(read[:50], pattern[:50]))
	testing.expect(t, slice.all_of(read[50:200], 0))
	testing.expect_value(t, call(loaded, "call_file_truncate", file, 4097), SQLITE_FULL)
	testing.expect_value(t, call(loaded, "call_file_truncate", file, -1), SQLITE_IOERR_TRUNCATE)
	testing.expect_value(t, file_size(fixture, file), 200)
	// A file opened to read refuses each change.
	reader, reader_code := open_file(fixture, "main.db", SQLITE_OPEN_READONLY)
	testing.expect_value(t, reader_code, SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_write", reader, address_of(raw_data(pattern)), 1, 0), SQLITE_IOERR_WRITE)
	testing.expect_value(t, call(loaded, "call_file_truncate", reader, 0), SQLITE_IOERR_TRUNCATE)
	testing.expect_value(t, file_size(fixture, reader), 200)
	// The neighbour slot is untouched by each write of the first.
	testing.expect(t, slice.all_of(fixture.bytes[4096:], 0))
	testing.expect_value(t, call(loaded, "call_file_close", reader), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_close", file), SQLITE_OK)
}

@(test)
vfs_locks_as_sqlite_describes_them :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	slots := [?]i64{4096}
	fixture, made := vfs_fixture(t, loaded, slots[:])
	if !made {
		return
	}
	flags := i64(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	a, _ := open_file(fixture, "main.db", flags)
	b, _ := open_file(fixture, "main.db", flags)
	c, _ := open_file(fixture, "main.db", flags)
	lock :: proc(loaded: Loaded_Module, file: i64, level: Lock_Level) -> i64 {
		return call(loaded, "call_file_lock", file, i64(level))
	}
	unlock :: proc(loaded: Loaded_Module, file: i64, level: Lock_Level) -> i64 {
		return call(loaded, "call_file_unlock", file, i64(level))
	}
	reserved :: proc(loaded: Loaded_Module, file: i64) -> i64 {
		result: i64 = -1
		fmt.assertf(call(loaded, "call_file_reserved", file, address_of(&result)) == SQLITE_OK, "xCheckReservedLock")
		return result
	}
	// RESERVED and EXCLUSIVE need SHARED first; PENDING is never asked.
	testing.expect_value(t, lock(loaded, a, .Reserved), SQLITE_IOERR_LOCK)
	testing.expect_value(t, lock(loaded, a, .Exclusive), SQLITE_IOERR_LOCK)
	testing.expect_value(t, lock(loaded, a, .Pending), SQLITE_IOERR_LOCK)
	// A word that names no level is refused.
	for word in ([?]i64{5, -1, 1 << 31 - 1}) {
		testing.expect_value(t, call(loaded, "call_file_lock", a, word), SQLITE_IOERR_LOCK)
		testing.expect_value(t, call(loaded, "call_file_unlock", a, word), SQLITE_IOERR_UNLOCK)
	}
	testing.expect_value(t, lock(loaded, a, .Shared), SQLITE_OK)
	testing.expect_value(t, lock(loaded, b, .Shared), SQLITE_OK)
	testing.expect_value(t, reserved(loaded, b), 0)
	testing.expect_value(t, lock(loaded, a, .Reserved), SQLITE_OK)
	testing.expect_value(t, reserved(loaded, b), 1)
	testing.expect_value(t, lock(loaded, b, .Reserved), SQLITE_BUSY)
	// A writer waits for the readers: PENDING keeps new readers out.
	testing.expect_value(t, lock(loaded, a, .Exclusive), SQLITE_BUSY)
	testing.expect_value(t, lock(loaded, c, .Shared), SQLITE_BUSY)
	testing.expect_value(t, unlock(loaded, b, .None), SQLITE_OK)
	testing.expect_value(t, lock(loaded, a, .Exclusive), SQLITE_OK)
	testing.expect_value(t, lock(loaded, c, .Shared), SQLITE_BUSY)
	// An unlock goes to SHARED or NONE only.
	testing.expect_value(t, unlock(loaded, a, .Reserved), SQLITE_IOERR_UNLOCK)
	testing.expect_value(t, unlock(loaded, a, .Exclusive), SQLITE_IOERR_UNLOCK)
	testing.expect_value(t, unlock(loaded, a, .Shared), SQLITE_OK)
	testing.expect_value(t, reserved(loaded, c), 0)
	testing.expect_value(t, lock(loaded, c, .Shared), SQLITE_OK)
	testing.expect_value(t, lock(loaded, c, .Reserved), SQLITE_OK)
	// A close releases each lock of the file.
	testing.expect_value(t, call(loaded, "call_file_close", c), SQLITE_OK)
	testing.expect_value(t, reserved(loaded, a), 0)
	testing.expect_value(t, lock(loaded, a, .Reserved), SQLITE_OK)
	testing.expect_value(t, lock(loaded, a, .Exclusive), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_close", a), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_file_close", b), SQLITE_OK)
}

@(test)
vfs_names_access_randomness_and_time :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	slots := [?]i64{4096, 4096}
	fixture, made := vfs_fixture(t, loaded, slots[:], 42)
	if !made {
		return
	}
	vfs := address_of(raw_data(fixture.vfs))
	file, _ := open_file(fixture, "main.db", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
	result: i64
	// An empty file exists for READWRITE, not for EXISTS: no hot journal.
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("main.db"), 0, address_of(&result)), SQLITE_OK)
	testing.expect_value(t, result, 0)
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("main.db"), 1, address_of(&result)), SQLITE_OK)
	testing.expect_value(t, result, 1)
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("main.db"), 3, address_of(&result)), SQLITE_IOERR_ACCESS)
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("main.db"), -1, address_of(&result)), SQLITE_IOERR_ACCESS)
	testing.expect_value(t, call(loaded, "call_file_write", file, text_address("x"), 1, 0), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("main.db"), 0, address_of(&result)), SQLITE_OK)
	testing.expect_value(t, result, 1)
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("other"), 2, address_of(&result)), SQLITE_OK)
	testing.expect_value(t, result, 0)
	// A file that is open is not deleted; a name that names nothing is refused.
	testing.expect_value(t, call(loaded, "call_vfs_delete", vfs, text_address("main.db")), SQLITE_IOERR_DELETE)
	testing.expect_value(t, call(loaded, "call_vfs_delete", vfs, text_address("other")), SQLITE_IOERR_DELETE_NOENT)
	testing.expect_value(t, call(loaded, "call_vfs_delete", vfs, 0), SQLITE_IOERR_DELETE)
	testing.expect_value(t, call(loaded, "call_file_close", file), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_vfs_delete", vfs, text_address("main.db")), SQLITE_OK)
	testing.expect_value(t, call(loaded, "call_vfs_access", vfs, text_address("main.db"), 1, address_of(&result)), SQLITE_OK)
	testing.expect_value(t, result, 0)
	// A full path is the name itself, and the room for it is checked.
	out: [16]u8
	testing.expect_value(t, call(loaded, "call_vfs_full_pathname", vfs, text_address("main.db"), 8, address_of(&out)), SQLITE_OK)
	testing.expect_value(t, string(cstring(raw_data(out[:]))), "main.db")
	testing.expect_value(t, call(loaded, "call_vfs_full_pathname", vfs, text_address("main.db"), 7, address_of(&out)), SQLITE_CANTOPEN)
	testing.expect_value(t, call(loaded, "call_vfs_full_pathname", vfs, text_address("main.db"), 0, address_of(&out)), SQLITE_CANTOPEN)
	testing.expect_value(t, call(loaded, "call_vfs_full_pathname", vfs, text_address(strings.repeat("p", 64, context.temp_allocator)), 128, address_of(raw_data(make([]u8, 128, context.temp_allocator)))), SQLITE_CANTOPEN)
	// The bytes of randomness come from the seed: one seed, one sequence.
	first := make([]u8, 64, context.temp_allocator)
	second := make([]u8, 64, context.temp_allocator)
	testing.expect_value(t, call(loaded, "call_vfs_randomness", vfs, 64, address_of(raw_data(first))), 64)
	same_seed, _ := vfs_fixture(t, loaded, slots[:], 42)
	testing.expect_value(t, call(loaded, "call_vfs_randomness", address_of(raw_data(same_seed.vfs)), 64, address_of(raw_data(second))), 64)
	testing.expect(t, slice.equal(first, second))
	other_seed, _ := vfs_fixture(t, loaded, slots[:], 43)
	testing.expect_value(t, call(loaded, "call_vfs_randomness", address_of(raw_data(other_seed.vfs)), 64, address_of(raw_data(second))), 64)
	testing.expect(t, !slice.equal(first, second))
	testing.expect_value(t, call(loaded, "call_vfs_randomness", vfs, 0, address_of(raw_data(first))), 0)
	testing.expect_value(t, call(loaded, "call_vfs_randomness", vfs, -5, address_of(raw_data(first))), 0)
	// A program reads no clock: its time is the start of the epoch.
	milliseconds: i64
	testing.expect_value(t, call(loaded, "call_vfs_current_time", vfs, address_of(&milliseconds)), SQLITE_OK)
	testing.expect_value(t, milliseconds, 210866760000000)
}

// ---- The key-value store over the VFS ---------------------------------------------------------

Kv_Status :: enum i64 {
	Ok          = 0,
	Not_Found   = 1,
	Busy        = -1,
	Io_Error    = -2,
	Full        = -3,
	Corrupt     = -4,
	Misuse      = -5,
	No_Memory   = -6,
	Interrupted = -7,
}

Kv :: struct {
	loaded: Loaded_Module,
	store:  i64,
}

@(private = "file")
kv_open :: proc(fixture: Vfs_Fixture, heap: ^Heap_Record, name := "main.db") -> (kv: Kv, status: Kv_Status) {
	kv.loaded = fixture.loaded
	status = Kv_Status(call(fixture.loaded, "call_kv_open", address_of(&kv.store), address_of(heap), address_of(raw_data(fixture.vfs)), text_address(name)))
	return
}

@(private = "file")
kv_call :: proc(kv: Kv, name: string, arguments: ..i64) -> Kv_Status {
	all := make([dynamic]i64, context.temp_allocator)
	append(&all, kv.store)
	append(&all, ..arguments)
	return Kv_Status(call(kv.loaded, name, ..all[:]))
}

@(private = "file")
kv_sum :: proc(kv: Kv, low, high: i64) -> (sum: i64, count: i64, status: Kv_Status) {
	status = kv_call(kv, "call_kv_sum", low, high, address_of(&sum), address_of(&count))
	return
}

@(private = "file")
reference_sum :: proc(reference: map[i64]i64, low, high: i64) -> (sum: i64, count: i64) {
	for key, value in reference {
		if key >= low && key <= high {
			sum = i64(u64(sum) + u64(value))
			count += 1
		}
	}
	return
}

@(private = "file")
kv_records :: proc(kv: Kv) -> (records: i64, status: Kv_Status) {
	status = kv_call(kv, "call_kv_check", address_of(&records))
	return
}

@(test)
kv_store_keeps_records_through_commits_and_rollbacks :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	slots := [?]i64{256 * 1024, 128 * 1024}
	fixture, made := vfs_fixture(t, loaded, slots[:])
	if !made {
		return
	}
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 20)
	defer delete(arena)
	kv, status := kv_open(fixture, &heap)
	if !testing.expect_value(t, status, Kv_Status.Ok) {
		return
	}
	reference := make(map[i64]i64)
	defer delete(reference)
	generator := Generator{0x5eed_0007}
	// Puts outside a transaction are refused.
	testing.expect_value(t, kv_call(kv, "call_kv_put", 1, 1), Kv_Status.Misuse)
	testing.expect_value(t, kv_call(kv, "call_kv_commit", -1), Kv_Status.Misuse)
	testing.expect_value(t, kv_call(kv, "call_kv_rollback"), Kv_Status.Misuse)
	for round in 0 ..< 6 {
		testing.expect_value(t, kv_call(kv, "call_kv_begin"), Kv_Status.Ok)
		testing.expect_value(t, kv_call(kv, "call_kv_begin"), Kv_Status.Misuse)
		pending := make(map[i64]i64, context.temp_allocator)
		for _ in 0 ..< 600 {
			key := i64(next_below(&generator, 5000)) - 2500
			if round == 0 && len(pending) == 0 {
				key = min(i64)
			}
			value := i64(next_word(&generator))
			testing.expect_value(t, kv_call(kv, "call_kv_put", key, value), Kv_Status.Ok)
			pending[key] = value
		}
		if round % 3 == 2 {
			testing.expect_value(t, kv_call(kv, "call_kv_rollback"), Kv_Status.Ok)
		} else {
			testing.expect_value(t, kv_call(kv, "call_kv_commit", -1), Kv_Status.Ok)
			for key, value in pending {
				reference[key] = value
			}
		}
		records, check := kv_records(kv)
		testing.expect_value(t, check, Kv_Status.Ok)
		testing.expect_value(t, records, i64(len(reference)))
	}
	for key, value in reference {
		found: i64
		testing.expect_value(t, kv_call(kv, "call_kv_get", key, address_of(&found)), Kv_Status.Ok)
		testing.expect_value(t, found, value)
	}
	found: i64
	testing.expect_value(t, kv_call(kv, "call_kv_get", 999_999, address_of(&found)), Kv_Status.Not_Found)
	for range in ([?][2]i64{{-2500, 2500}, {0, 0}, {-100, 100}, {min(i64), max(i64)}, {2400, 9999}}) {
		sum, count, sum_status := kv_sum(kv, range[0], range[1])
		expected_sum, expected_count := reference_sum(reference, range[0], range[1])
		testing.expect_value(t, sum_status, Kv_Status.Ok)
		testing.expectf(t, sum == expected_sum && count == expected_count, "sum of [%d, %d]: %d of %d records, not %d of %d", range[0], range[1], sum, count, expected_sum, expected_count)
	}
	_, _, bad_range := kv_sum(kv, 5, 4)
	testing.expect_value(t, bad_range, Kv_Status.Misuse)
	// The journal is gone after each commit and each rollback.
	exists: i64
	call(loaded, "call_vfs_access", address_of(raw_data(fixture.vfs)), text_address("main.db-journal"), 0, address_of(&exists))
	testing.expect_value(t, exists, 0)
	testing.expect_value(t, kv_call(kv, "call_kv_close"), Kv_Status.Ok)
	testing.expect_value(t, heap.live_bytes, uint(0))
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	// The records stay in the store: a new open reads them back.
	again, again_status := kv_open(fixture, &heap)
	testing.expect_value(t, again_status, Kv_Status.Ok)
	records, _ := kv_records(again)
	testing.expect_value(t, records, i64(len(reference)))
	sum, count, _ := kv_sum(again, min(i64), max(i64))
	expected_sum, expected_count := reference_sum(reference, min(i64), max(i64))
	testing.expect(t, sum == expected_sum && count == expected_count)
	testing.expect_value(t, kv_call(again, "call_kv_close"), Kv_Status.Ok)
	fmt.printfln("c_programs: key-value store of %d records in %d bytes of database", len(reference), (^i64)(raw_data(fixture.store[FIRST_SLOT_SIZE_OFFSET:]))^)
}

@(test)
kv_store_plays_back_the_journal_of_a_stopped_commit :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	slots := [?]i64{256 * 1024, 128 * 1024}
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 20)
	defer delete(arena)
	for limit in ([?]i64{0, 1, 3, 10, 40}) {
		fixture, made := vfs_fixture(t, loaded, slots[:])
		if !made {
			return
		}
		kv, status := kv_open(fixture, &heap)
		testing.expect_value(t, status, Kv_Status.Ok)
		testing.expect_value(t, kv_call(kv, "call_kv_begin"), Kv_Status.Ok)
		for key in i64(0) ..< 1000 {
			kv_call(kv, "call_kv_put", key, key * 3)
		}
		testing.expect_value(t, kv_call(kv, "call_kv_commit", -1), Kv_Status.Ok)
		before := slice.clone(fixture.bytes[:256 * 1024], context.temp_allocator)

		// A second transaction changes most pages, then the machine stops in
		// the middle of its commit.
		testing.expect_value(t, kv_call(kv, "call_kv_begin"), Kv_Status.Ok)
		for key in i64(0) ..< 3000 {
			kv_call(kv, "call_kv_put", key * 7 % 3001, -key)
		}
		testing.expect_value(t, kv_call(kv, "call_kv_commit", limit), Kv_Status.Interrupted)
		kv_call(kv, "call_kv_abandon")
		exists: i64
		call(loaded, "call_vfs_access", address_of(raw_data(fixture.vfs)), text_address("main.db-journal"), 0, address_of(&exists))
		testing.expect_value(t, exists, 1)

		// The next open finds the hot journal and puts the old pages back.
		recovered, recovered_status := kv_open(fixture, &heap)
		testing.expectf(t, recovered_status == .Ok, "the open after a commit stopped after %d pages gives %v", limit, recovered_status)
		records, check := kv_records(recovered)
		testing.expect_value(t, check, Kv_Status.Ok)
		testing.expect_value(t, records, 1000)
		sum, count, _ := kv_sum(recovered, 0, 999)
		testing.expect_value(t, sum, 3 * 999 * 1000 / 2)
		testing.expect_value(t, count, 1000)
		call(loaded, "call_vfs_access", address_of(raw_data(fixture.vfs)), text_address("main.db-journal"), 0, address_of(&exists))
		testing.expect_value(t, exists, 0)
		testing.expectf(t, slice.equal(fixture.bytes[:len(before)], before), "after a stop after %d pages, the database holds the bytes of the last commit", limit)
		testing.expect_value(t, kv_call(recovered, "call_kv_close"), Kv_Status.Ok)
		testing.expect_value(t, heap.live_bytes, uint(0))
	}
}

@(test)
kv_store_refuses_a_second_writer_a_full_store_and_a_damaged_file :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	heap: Heap_Record
	arena := make_heap(loaded, &heap, 1 << 20)
	defer delete(arena)
	slots := [?]i64{8 * 512, 64 * 1024}
	fixture, made := vfs_fixture(t, loaded, slots[:])
	if !made {
		return
	}
	first, first_status := kv_open(fixture, &heap)
	testing.expect_value(t, first_status, Kv_Status.Ok)
	second, second_status := kv_open(fixture, &heap)
	testing.expect_value(t, second_status, Kv_Status.Ok)
	testing.expect_value(t, kv_call(first, "call_kv_begin"), Kv_Status.Ok)
	// One writer at a time: the second waits for the first.
	testing.expect_value(t, kv_call(second, "call_kv_begin"), Kv_Status.Busy)
	for key in i64(0) ..< 400 {
		kv_call(first, "call_kv_put", key, key)
	}
	// The commit waits for the reader of the second store to leave.
	testing.expect_value(t, kv_call(first, "call_kv_commit", -1), Kv_Status.Busy)
	testing.expect_value(t, kv_call(second, "call_kv_close"), Kv_Status.Ok)
	// The database slot holds 8 pages: the commit of more is refused, and the
	// rollback keeps the records of before.
	commit := kv_call(first, "call_kv_commit", -1)
	testing.expectf(t, commit == .Full, "a commit past the capacity of the slot gives %v", commit)
	testing.expect_value(t, kv_call(first, "call_kv_rollback"), Kv_Status.Ok)
	records, check := kv_records(first)
	testing.expect_value(t, check, Kv_Status.Ok)
	testing.expect_value(t, records, 0)
	testing.expect_value(t, kv_call(first, "call_kv_close"), Kv_Status.Ok)
	second, second_status = kv_open(fixture, &heap)
	testing.expect_value(t, second_status, Kv_Status.Ok)
	testing.expect_value(t, kv_call(second, "call_kv_begin"), Kv_Status.Ok)
	testing.expect_value(t, kv_call(second, "call_kv_put", 5, 50), Kv_Status.Ok)
	testing.expect_value(t, kv_call(second, "call_kv_commit", -1), Kv_Status.Ok)
	testing.expect_value(t, kv_call(second, "call_kv_close"), Kv_Status.Ok)

	// A damaged magic, a size that is no count of pages, and a root past the
	// end: each open is refused, and its memory comes back.
	header := fixture.bytes[:512]
	saved := slice.clone(header, context.temp_allocator)
	header[0] ~= 0xff
	_, damaged := kv_open(fixture, &heap)
	testing.expect_value(t, damaged, Kv_Status.Corrupt)
	copy(header, saved)
	header[8] = 0xff
	_, damaged = kv_open(fixture, &heap)
	testing.expect_value(t, damaged, Kv_Status.Corrupt)
	copy(header, saved)
	slot_size := (^i64)(raw_data(fixture.store[FIRST_SLOT_SIZE_OFFSET:]))
	slot_size^ -= 1
	_, damaged = kv_open(fixture, &heap)
	testing.expect_value(t, damaged, Kv_Status.Corrupt)
	slot_size^ += 1
	testing.expect_value(t, heap.live_bytes, uint(0))
	// A leaf whose keys lose their order is found by the check.
	kv, status := kv_open(fixture, &heap)
	testing.expect_value(t, status, Kv_Status.Ok)
	testing.expect_value(t, kv_call(kv, "call_kv_begin"), Kv_Status.Ok)
	testing.expect_value(t, kv_call(kv, "call_kv_put", 9, 90), Kv_Status.Ok)
	testing.expect_value(t, kv_call(kv, "call_kv_commit", -1), Kv_Status.Ok)
	testing.expect_value(t, kv_call(kv, "call_kv_close"), Kv_Status.Ok)
	leaf := fixture.bytes[512:1024]
	// Keys 5 and 9: swap the first key to 10, after 9.
	leaf[8] = 10
	kv, status = kv_open(fixture, &heap)
	testing.expect_value(t, status, Kv_Status.Ok)
	_, check = kv_records(kv)
	testing.expect_value(t, check, Kv_Status.Corrupt)
	testing.expect_value(t, kv_call(kv, "call_kv_close"), Kv_Status.Ok)
	// Names that the store refuses.
	_, bad_name := kv_open(fixture, &heap, "")
	testing.expect_value(t, bad_name, Kv_Status.Misuse)
	_, bad_name = kv_open(fixture, &heap, strings.repeat("n", 56, context.temp_allocator))
	testing.expect_value(t, bad_name, Kv_Status.Misuse)
	testing.expect_value(t, heap.live_bytes, uint(0))
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
}
