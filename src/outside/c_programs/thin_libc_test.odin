#+build !freestanding
// The host tests of the thin libc of the C programs: its output and its
// reading of numbers against the C library of the host, its heap under
// random work, its sort, its jumps, its memory streams and its math.
package c_programs

import "core:c/libc"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

DOUBLE_FORMATS := [?]string{"%.14g", "%.17g", "%g", "%e", "%.3e", "%f", "%.0f", "%.20f", "%10.3f", "%-12.4g|", "%+.2e", "%#.0f", "%#g", "%G", "%E", "%.0e", "%.1g", "%08.2f", "% f", "%.30g", "%.0g", "%#.3g", "%-+9.1f|", "%.400f", "%F"}

double_edges :: proc() -> []u64 {
	values := [?]f64{0, 1, 0.5, 0.1, 1e-300, 2.2250738585072014e-308, 1.7976931348623157e308, 123456789012345678, 9.5, 0.125, 2.5, 3.5, 1e21, 1e-5, 0.0001, 123.456, 999999.5, 1e15, 1e16, 0.05, 0.15, 0.25, 0.35, 1.5e-7, 9.999999999999999e22, 5e-5, 99.995, 0.000123456789}
	edges := make([dynamic]u64, context.temp_allocator)
	for value in values {
		append(&edges, transmute(u64)value, transmute(u64)value | (1 << 63))
	}
	// The least subnormal, the largest subnormal, the infinities and NaNs.
	append(&edges, 1, 0x000fffffffffffff, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0xfff8000000000000, 0x8000000000000000)
	return edges[:]
}

@(test)
thin_libc_formats_doubles_as_the_c_library_of_the_host :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	generator := Generator{0x5eed_0001}
	values := make([dynamic]u64, context.temp_allocator)
	append(&values, ..double_edges())
	for _ in 0 ..< 1500 {
		bits := next_word(&generator)
		if (bits >> 52) & 0x7ff == 0x7ff {
			continue
		}
		append(&values, bits)
	}
	expected: [2048]u8
	found: [2048]u8
	mismatches := 0
	for format in DOUBLE_FORMATS {
		format_c := strings.clone_to_cstring(format, context.temp_allocator)
		for bits in values {
			value := transmute(f64)bits
			expected_count := libc.snprintf(raw_data(expected[:]), len(expected), format_c, value)
			found_count := call(loaded, "call_format_double", address_of(raw_data(found[:])), len(found), address_of(rawptr(format_c)), i64(bits))
			expected_text := string(cstring(raw_data(expected[:])))
			found_text := string(cstring(raw_data(found[:])))
			// glibc writes no zero after the point of "%#g" when the rounding
			// carries into a new digit ("1.e+06"); C keeps the zeros of the
			// precision with "#", and the thin libc writes them.
			if format == "%#g" && strings.contains(expected_text, ".e") {
				fixed, _ := strings.replace(expected_text, ".e", ".00000e", 1, context.temp_allocator)
				testing.expectf(t, found_text == fixed, "format %%#g of %x: the thin libc gives %q, C asks %q", bits, found_text, fixed)
				continue
			}
			if i64(expected_count) != found_count || expected_text != found_text {
				mismatches += 1
				if mismatches < 10 {
					testing.expectf(t, false, "format %s of %x: the host gives %q (%d), the thin libc %q (%d)", format, bits, expected_text, expected_count, found_text, found_count)
				}
			}
		}
	}
	testing.expect_value(t, mismatches, 0)
}

// The values of errno of glibc on x86-64, which the thin libc takes too.
ERRNO_INVALID_ARGUMENT :: 22

Integer_Format_Kind :: enum {
	Signed_Int,
	Unsigned_Int,
	Signed_Long_Long,
	Unsigned_Long_Long,
}

@(test)
thin_libc_formats_integers_as_the_c_library_of_the_host :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	Integer_Format :: struct {
		text: string,
		kind: Integer_Format_Kind,
	}
	formats := [?]Integer_Format {
		{"%d", .Signed_Int}, {"%5d", .Signed_Int}, {"%-5d|", .Signed_Int}, {"%05d", .Signed_Int}, {"%+d", .Signed_Int}, {"% d", .Signed_Int},
		{"%.0d", .Signed_Int}, {"%.3d", .Signed_Int}, {"%hhd", .Signed_Int}, {"%hd", .Signed_Int}, {"%i", .Signed_Int}, {"%+.0i|", .Signed_Int},
		{"%u", .Unsigned_Int}, {"%x", .Unsigned_Int}, {"%X", .Unsigned_Int}, {"%#x", .Unsigned_Int}, {"%o", .Unsigned_Int}, {"%#o", .Unsigned_Int},
		{"%#.0o", .Unsigned_Int}, {"%hhu", .Unsigned_Int}, {"%hx", .Unsigned_Int}, {"%#08x", .Unsigned_Int},
		{"%lld", .Signed_Long_Long}, {"%ld", .Signed_Long_Long}, {"%+20lld|", .Signed_Long_Long}, {"%zd", .Signed_Long_Long},
		{"%llx", .Unsigned_Long_Long}, {"%#llX", .Unsigned_Long_Long}, {"%llu", .Unsigned_Long_Long}, {"%-24llo|", .Unsigned_Long_Long}, {"%jx", .Unsigned_Long_Long},
	}
	values := [?]i64{0, 1, -1, 7, -7, 42, 255, 256, -128, -129, 65535, 65536, 0x7fffffff, -0x80000000, 4294967295, 4294967296, max(i64), min(i64), 1234567890123}
	expected: [128]u8
	found: [128]u8
	for format in formats {
		format_c := strings.clone_to_cstring(format.text, context.temp_allocator)
		for value in values {
			expected_count: i32
			switch format.kind {
			case .Signed_Int:
				expected_count = i32(libc.snprintf(raw_data(expected[:]), len(expected), format_c, i32(value)))
			case .Unsigned_Int:
				expected_count = i32(libc.snprintf(raw_data(expected[:]), len(expected), format_c, u32(value)))
			case .Signed_Long_Long:
				expected_count = i32(libc.snprintf(raw_data(expected[:]), len(expected), format_c, value))
			case .Unsigned_Long_Long:
				expected_count = i32(libc.snprintf(raw_data(expected[:]), len(expected), format_c, u64(value)))
			}
			found_count := call(loaded, "call_format_integer", address_of(raw_data(found[:])), len(found), address_of(rawptr(format_c)), value)
			testing.expectf(t, i64(expected_count) == found_count && string(cstring(raw_data(expected[:]))) == string(cstring(raw_data(found[:]))), "format %s of %d: the host gives %q, the thin libc %q", format.text, value, string(cstring(raw_data(expected[:]))), string(cstring(raw_data(found[:]))))
		}
	}
}

@(test)
thin_libc_refuses_unknown_conversions_and_cuts_at_the_capacity :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	buffer: [16]u8
	// A conversion that the thin libc does not know is refused whole.
	for format in ([?]string{"%k", "%a", "%n", "%5", "%.99999999999d", "%l"}) {
		testing.expectf(t, call(loaded, "call_format_integer", address_of(raw_data(buffer[:])), len(buffer), text_address(format), 1) == -1, "the format %q must be refused", format)
	}
	// The count is the count of the whole text; the buffer holds what fits
	// and its terminating zero, and no byte past the capacity changes.
	for &byte in buffer {
		byte = 0xaa
	}
	count := call(loaded, "call_format_integer", address_of(raw_data(buffer[:])), 5, text_address("%d"), 1234567)
	testing.expect_value(t, count, 7)
	testing.expect_value(t, string(cstring(raw_data(buffer[:]))), "1234")
	testing.expect_value(t, buffer[5], 0xaa)
	// A capacity of 0 writes nothing.
	count = call(loaded, "call_format_integer", address_of(raw_data(buffer[:])), 0, text_address("%d"), 99)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, buffer[0], u8('1'))
	// A capacity of 1 holds the terminating zero only.
	count = call(loaded, "call_format_integer", address_of(raw_data(buffer[:])), 1, text_address("%d"), 99)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, buffer[0], 0)
	testing.expect_value(t, buffer[1], u8('2'))
}

double_texts :: proc(generator: ^Generator) -> []string {
	texts := make([dynamic]string, context.temp_allocator)
	fixed := [?]string {
		"", " ", "+", "-", ".", "e5", "1e", "1e+", "1e-x", "0x", "0x.p1", "0xg", "inf", "-Infinity", "INFINITY", "infinit", "nan", "-NaN", "nan(123)", "nan(", "nan()",
		"1.5e309", "-1.5e309", "1e-400", "4.9406564584124654e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "2.2250738585072011e-308",
		"2.2250738585072014e-308", "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308", "  -0.0", "1e100000", "1e-100000",
		"0x1p-1074", "0x1p-1075", "0x1.8p-1075", "0x1.fffffffffffff8p1023", "0x1.fffffffffffff7p1023", "0x1p1024", "9007199254740993", "9007199254740995",
		"0x1.00000000000008p0", "0x1.000000000000081p0", "0x1.0000000000000800000000001p0", "1_000", "42.", ".5", "0.", "00012", "-.75e2",
		"123456789012345678901234567890", "0.000000000000000000000000000001", "1e23", "8.98846567431158e307", "3.14159265358979323846264338327950288",
		"0x.8p1", "0X1P+2", "0x1p", "0x1p+", "1e+5x", "\t\n 7", "0.1", "0.3", "1.0000000000000002", "0.30000000000000004", "0x0p0", "-0x0.0p99999",
		"0x123456789abcdef0123p-80", "0x0.0000000000001p-1022", "0x1.fffffffffffffp-1023", "0x1.ffffffffffffep-1023",
	}
	append(&texts, ..fixed[:])
	append(&texts, strings.concatenate({"1", strings.repeat("0", 1000, context.temp_allocator)}, context.temp_allocator))
	append(&texts, strings.concatenate({"0.", strings.repeat("0", 400, context.temp_allocator), "1"}, context.temp_allocator))
	append(&texts, strings.concatenate({strings.repeat("9", 900, context.temp_allocator), "e-600"}, context.temp_allocator))
	buffer: [128]u8
	for _ in 0 ..< 2000 {
		bits := next_word(generator)
		value := transmute(f64)bits
		switch next_below(generator, 5) {
		case 0:
			libc.snprintf(raw_data(buffer[:]), len(buffer), "%.17g", value)
		case 1:
			libc.snprintf(raw_data(buffer[:]), len(buffer), "%.25e", value)
		case 2:
			libc.snprintf(raw_data(buffer[:]), len(buffer), "%a", value)
		case 3:
			// The exact middle of two neighbour doubles: a tie that rounds to
			// even, and the same tie with one more digit, which rounds up.
			if (bits >> 52) & 0x7ff >= 0x7fe {
				continue
			}
			low := transmute(f64)(bits & ~u64(1 << 63))
			middle := strings.builder_make(context.temp_allocator)
			libc.snprintf(raw_data(buffer[:]), len(buffer), "%a", low)
			// low has 53 bits; low + half an ulp needs one more bit, which
			// the hexadecimal form of %a shows when written with one more digit.
			text := string(cstring(raw_data(buffer[:])))
			p := strings.index_byte(text, 'p')
			if p < 0 {
				continue
			}
			mantissa := text[:p]
			if strings.index_byte(mantissa, '.') < 0 {
				mantissa = strings.concatenate({mantissa, "."}, context.temp_allocator)
			}
			fraction_digits := len(mantissa) - strings.index_byte(mantissa, '.') - 1
			strings.write_string(&middle, mantissa)
			strings.write_string(&middle, strings.repeat("0", 13 - fraction_digits, context.temp_allocator))
			strings.write_string(&middle, "8")
			if next_below(generator, 2) == 0 {
				strings.write_string(&middle, "0000001")
			}
			strings.write_string(&middle, text[p:])
			append(&texts, strings.to_string(middle))
			continue
		case 4:
			digits := next_below(generator, 30) + 1
			builder := strings.builder_make(context.temp_allocator)
			for _ in 0 ..< digits {
				strings.write_byte(&builder, u8('0' + next_below(generator, 10)))
			}
			fmt.sbprintf(&builder, "e%d", i64(next_below(generator, 700)) - 350)
			append(&texts, strings.to_string(builder))
			continue
		}
		append(&texts, strings.clone(string(cstring(raw_data(buffer[:]))), context.temp_allocator))
	}
	return texts[:]
}

@(test)
thin_libc_reads_doubles_as_the_c_library_of_the_host :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	generator := Generator{0x5eed_0002}
	mismatches := 0
	for text in double_texts(&generator) {
		text_c := strings.clone_to_cstring(text, context.temp_allocator)
		end: [^]u8
		libc.errno()^ = 0
		expected := libc.strtod(text_c, &end)
		expected_errno := libc.errno()^
		expected_end := i64(uintptr(rawptr(end)) - uintptr(rawptr(text_c)))
		found_end, found_errno: i64
		found_bits := u64(call(loaded, "call_parse_double", address_of(rawptr(text_c)), address_of(&found_end), address_of(&found_errno)))
		expected_bits := transmute(u64)expected
		same_bits := found_bits == expected_bits || (expected != expected && (found_bits >> 52) & 0x7ff == 0x7ff && found_bits & 0xfffffffffffff != 0 && found_bits >> 63 == expected_bits >> 63)
		same_errno := i64(expected_errno) == found_errno
		if !same_bits || found_end != expected_end || !same_errno {
			mismatches += 1
			if mismatches < 12 {
				testing.expectf(t, false, "strtod of %q: the host gives %x, end %d, errno %d; the thin libc %x, end %d, errno %d", text, expected_bits, expected_end, expected_errno, found_bits, found_end, found_errno)
			}
		}
	}
	testing.expect_value(t, mismatches, 0)
}

@(test)
thin_libc_reads_integers_as_the_c_library_of_the_host :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	texts := [?]string{"0", "-0", "123", "-123", " +42", "0x1f", "0X1F", "0x", "0xg", "077", "08", "1z", "z", "", "  ", "-", "+-1", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "18446744073709551615", "18446744073709551616", "-18446744073709551615", "-18446744073709551616", "-1", "zz", "ZZ", "1010", "0b101", "99999999999999999999999999", "\t\v\f\r\n 5", "-0x8000000000000000", "-0x8000000000000001"}
	bases := [?]i64{0, 2, 8, 10, 16, 36, 1, 37, -1}
	for text in texts {
		text_c := strings.clone_to_cstring(text, context.temp_allocator)
		for base in bases {
			end: [^]u8
			libc.errno()^ = 0
			expected_signed := libc.strtoll(text_c, &end, i32(base))
			expected_signed_errno := libc.errno()^
			expected_signed_end := i64(uintptr(rawptr(end)) - uintptr(rawptr(text_c)))
			libc.errno()^ = 0
			expected_unsigned := libc.strtoull(text_c, &end, i32(base))
			expected_unsigned_errno := libc.errno()^
			expected_unsigned_end := i64(uintptr(rawptr(end)) - uintptr(rawptr(text_c)))

			if expected_signed_errno == ERRNO_INVALID_ARGUMENT {
				expected_signed_end = 0
			}
			found_end, found_errno: i64
			found_signed := call(loaded, "call_parse_integer", address_of(rawptr(text_c)), base, address_of(&found_end), address_of(&found_errno))
			testing.expectf(t, found_signed == i64(expected_signed) && found_end == expected_signed_end && found_errno == i64(expected_signed_errno), "strtoll(%q, %d): the host gives %d end %d errno %d; the thin libc %d end %d errno %d", text, base, expected_signed, expected_signed_end, expected_signed_errno, found_signed, found_end, found_errno)
			found_unsigned := u64(call(loaded, "call_parse_unsigned", address_of(rawptr(text_c)), base, address_of(&found_end), address_of(&found_errno)))
			// glibc leaves the end unwritten for a base that it refuses; the
			// thin libc puts it at the text.
			if expected_unsigned_errno == ERRNO_INVALID_ARGUMENT {
				expected_unsigned_end = 0
			}
			testing.expectf(t, found_unsigned == u64(expected_unsigned) && found_end == expected_unsigned_end && found_errno == i64(expected_unsigned_errno), "strtoull(%q, %d): the host gives %d end %d errno %d; the thin libc %d end %d errno %d", text, base, expected_unsigned, expected_unsigned_end, expected_unsigned_errno, found_unsigned, found_end, found_errno)
		}
	}
}

// The layout of Modus_Heap in thin_libc/modus_thin_libc.h.
Heap_Record :: struct {
	start:            uintptr,
	capacity:         uint,
	top:              uint,
	free_blocks:      uintptr,
	live_bytes:       uint,
	peak_bytes:       uint,
	refused_requests: uint,
	refused_releases: uint,
}

Heap_Fault :: enum i64 {
	None                  = 0,
	Not_Initialized       = 1,
	Damaged_Header        = 2,
	Block_Past_Top        = 3,
	Free_List_Disorder    = 4,
	Adjacent_Free_Blocks  = 5,
	Live_Count_Mismatch   = 6,
	Free_Block_At_Top     = 7,
}

heap_fault :: proc(loaded: Loaded_Module, heap: ^Heap_Record) -> Heap_Fault {
	return Heap_Fault(call(loaded, "call_heap_check", address_of(heap)))
}

@(test)
thin_libc_heap_refuses_bad_arenas_and_bad_releases :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	testing.expect_value(t, call(loaded, "call_heap_record_size"), i64(size_of(Heap_Record)))
	heap: Heap_Record
	storage := make([]u8, 4096 + 32)
	defer delete(storage)
	arena := storage[(16 - uintptr(raw_data(storage)) % 16) % 16:][:4096 + 16]
	aligned := uintptr(raw_data(arena))
	testing.expect(t, aligned % 16 == 0)

	// Edges of an arena: none, too small, one past too small.
	testing.expect_value(t, call(loaded, "call_heap_init", address_of(&heap), 0, 4096), -1)
	testing.expect_value(t, call(loaded, "call_heap_init", 0, address_of(raw_data(arena)), 4096), -1)
	// The smallest heap holds one block of 32 bytes and a map of 16 bytes.
	for size in ([?]i64{0, 1, 16, 31, 32, 47}) {
		testing.expectf(t, call(loaded, "call_heap_init", address_of(&heap), address_of(raw_data(arena)), size) == -1, "an arena of %d bytes holds no block", size)
	}
	testing.expect_value(t, call(loaded, "call_heap_init", address_of(&heap), address_of(raw_data(arena)), 48), 0)
	// One byte past an aligned start: the heap starts 15 bytes later.
	testing.expect_value(t, call(loaded, "call_heap_init", address_of(&heap), address_of(raw_data(arena[1:])), 62), -1)
	testing.expect_value(t, call(loaded, "call_heap_init", address_of(&heap), address_of(raw_data(arena[1:])), 63), 0)
	testing.expect_value(t, heap.start, aligned + 16)
	testing.expect_value(t, heap.capacity, uint(32))
	// The one block of the smallest size, then nothing.
	first := call(loaded, "call_heap_allocate", address_of(&heap), 0)
	testing.expect(t, first != 0, "a request of 0 bytes gives a block")
	testing.expect_value(t, call(loaded, "call_heap_allocate", address_of(&heap), 1), 0)
	testing.expect_value(t, heap.refused_requests, uint(1))

	// 4096 bytes: 32 bytes of map, 4064 bytes of blocks.
	testing.expect_value(t, call(loaded, "call_heap_init", address_of(&heap), address_of(raw_data(arena)), 4096), 0)
	testing.expect_value(t, heap.capacity, uint(4064))
	testing.expect_value(t, call(loaded, "call_heap_allocate", address_of(&heap), 4097), 0)
	testing.expect_value(t, call(loaded, "call_heap_allocate", address_of(&heap), max(i64)), 0)
	testing.expect_value(t, call(loaded, "call_heap_allocate", address_of(&heap), -1), 0)
	testing.expect_value(t, call(loaded, "call_heap_allocate", address_of(&heap), 4064 - 15), 0)
	whole := call(loaded, "call_heap_allocate", address_of(&heap), 4064 - 16)
	testing.expect(t, whole != 0, "the arena pays one block of its whole size")
	testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), whole), 0)
	testing.expect_value(t, heap.top, uint(0))

	a := call(loaded, "call_heap_allocate", address_of(&heap), 100)
	b := call(loaded, "call_heap_allocate", address_of(&heap), 100)
	testing.expect(t, a != 0 && b != 0 && a % 16 == 0 && b % 16 == 0)
	// Releases that name no block in use: refused, counted, nothing changes.
	before := heap
	// a + 16 holds the header that an older block left there: the map of
	// the starts refuses it all the same.
	(^u64)(uintptr(a + 8))^ = (^u64)(uintptr(a - 8))^
	bad := [?]i64{a + 1, a + 16, a - 16, b + 112, b + 96, address_of(raw_data(arena)), address_of(&heap), 16, max(i64) - 15}
	for pointer in bad {
		testing.expectf(t, call(loaded, "call_heap_release", address_of(&heap), pointer) == -1, "the release of %x must be refused", pointer)
	}
	testing.expect_value(t, heap.refused_releases, before.refused_releases + len(bad))
	testing.expect_value(t, heap.live_bytes, before.live_bytes)
	testing.expect_value(t, heap.top, before.top)
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	// The release of 0 is no release.
	testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), 0), 0)
	testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), a), 0)
	// A second release of one block is refused, as a resize of it is.
	testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), a), -1)
	testing.expect_value(t, call(loaded, "call_heap_resize", address_of(&heap), a, 10), 0)
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), b), 0)
	testing.expect_value(t, heap.top, uint(0))
	testing.expect_value(t, heap.live_bytes, uint(0))
	testing.expect_value(t, heap.free_blocks, uintptr(0))

	// A damaged header is found by the check, and its block is not released.
	c := call(loaded, "call_heap_allocate", address_of(&heap), 64)
	(^u64)(uintptr(c - 8))^ = 0x1234
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.Damaged_Header)
	testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), c), -1)
	// A heap that was never made is refused.
	empty: Heap_Record
	testing.expect_value(t, heap_fault(loaded, &empty), Heap_Fault.Not_Initialized)
	testing.expect_value(t, call(loaded, "call_heap_allocate", address_of(&empty), 8), 0)
}

@(test)
thin_libc_heap_keeps_contents_under_random_work :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	heap: Heap_Record
	arena := make([]u8, 1 << 20)
	defer delete(arena)
	testing.expect_value(t, call(loaded, "call_heap_init", address_of(&heap), address_of(raw_data(arena)), i64(len(arena))), 0)
	Block :: struct {
		address: i64,
		size:    i64,
		pattern: u8,
	}
	blocks := make([dynamic]Block)
	defer delete(blocks)
	generator := Generator{0x5eed_0003}
	refused := 0
	for step in 0 ..< 20000 {
		choice := next_below(&generator, 10)
		if choice < 5 || len(blocks) == 0 {
			size := i64(next_below(&generator, 3000))
			address := call(loaded, "call_heap_allocate", address_of(&heap), size)
			if address == 0 {
				refused += 1
				continue
			}
			pattern := u8(next_word(&generator))
			slice.fill(([^]u8)(uintptr(address))[:size], pattern)
			append(&blocks, Block{address, size, pattern})
			continue
		}
		index := int(next_below(&generator, u64(len(blocks))))
		block := blocks[index]
		for byte in ([^]u8)(uintptr(block.address))[:block.size] {
			if byte != block.pattern {
				testing.expectf(t, false, "step %d: a block lost its content", step)
				return
			}
		}
		if choice < 8 {
			testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), block.address), 0)
			unordered_remove(&blocks, index)
		} else {
			size := i64(next_below(&generator, 6000))
			moved := call(loaded, "call_heap_resize", address_of(&heap), block.address, size)
			if moved == 0 {
				refused += 1
				continue
			}
			moved_bytes := ([^]u8)(uintptr(moved))[:size]
			for byte in moved_bytes[:min(size, block.size)] {
				if byte != block.pattern {
					testing.expectf(t, false, "step %d: a resize lost the content of a block", step)
					return
				}
			}
			slice.fill(moved_bytes, block.pattern)
			blocks[index] = Block{moved, size, block.pattern}
		}
		if step % 97 == 0 {
			fault := heap_fault(loaded, &heap)
			if fault != .None {
				testing.expectf(t, false, "step %d: the check of the heap gives %v", step, fault)
				return
			}
		}
	}
	for block in blocks {
		testing.expect_value(t, call(loaded, "call_heap_release", address_of(&heap), block.address), 0)
	}
	testing.expect_value(t, heap_fault(loaded, &heap), Heap_Fault.None)
	testing.expect_value(t, heap.live_bytes, uint(0))
	testing.expect_value(t, heap.top, uint(0))
	testing.expect_value(t, heap.refused_releases, uint(0))
	fmt.printfln("c_programs: heap of 1 MiB, 20000 steps, peak %d bytes, %d refused requests", heap.peak_bytes, refused)
}

@(test)
thin_libc_sorts_as_the_reference :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	generator := Generator{0x5eed_0004}
	for count in ([?]int{0, 1, 2, 3, 10, 1000, 4097}) {
		for shape in 0 ..< 4 {
			values := make([]i64, count, context.temp_allocator)
			for &value, index in values {
				switch shape {
				case 0:
					value = i64(next_word(&generator))
				case 1:
					value = i64(next_below(&generator, 4)) - 2
				case 2:
					value = i64(index)
				case 3:
					value = i64(count - index)
				}
			}
			if count > 1 {
				values[count / 2] = min(i64)
				values[0] = max(i64)
			}
			expected := slice.clone(values, context.temp_allocator)
			slice.sort(expected)
			testing.expect_value(t, call(loaded, "call_sort_integers", address_of(raw_data(values)), i64(count)), 0)
			testing.expectf(t, slice.equal(values, expected), "qsort of %d values of shape %d", count, shape)
		}
	}
}

@(test)
thin_libc_jumps_back_through_frames :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	for depth in ([?]i64{0, 1, 2, 17, 500, 5000}) {
		testing.expectf(t, call(loaded, "call_jump", depth, 5) == 5000, "longjmp from %d frames down", depth)
	}
	// longjmp with 0 makes setjmp give 1, as C asks.
	testing.expect_value(t, call(loaded, "call_jump", 3, 0), 1000)
	testing.expect_value(t, call(loaded, "call_jump", 3, -2), -2000)
	// The module still runs after the jumps: its stack and its registers are whole.
	testing.expect_value(t, call(loaded, "call_jump", 1, 9), 9000)
}

@(test)
thin_libc_memory_streams_hold_their_bounds :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	buffer: [16]u8
	for &byte in buffer {
		byte = 0xaa
	}
	testing.expect_value(t, call(loaded, "call_stream_write", address_of(raw_data(buffer[:])), 10, text_address("abc"), 3), 18)
	testing.expect_value(t, string(buffer[:9]), "abcabcabc")
	// A write past the capacity writes what fits and sets the error.
	testing.expect_value(t, call(loaded, "call_stream_write", address_of(raw_data(buffer[:])), 10, text_address("abc"), 4), 21)
	testing.expect_value(t, string(buffer[:10]), "abcabcabca")
	testing.expect_value(t, buffer[10], 0xaa)
	testing.expect_value(t, call(loaded, "call_stream_write", address_of(raw_data(buffer[:])), 0, text_address("abc"), 1), 1)
	testing.expect_value(t, call(loaded, "call_stream_write", address_of(raw_data(buffer[:])), 10, text_address(""), 5), 0)

	text := "hello\nworld\n\na line of more than fifteen bytes\nlast"
	sum: i64
	for byte in transmute([]u8)text {
		sum += i64(byte)
	}
	lines: i64
	testing.expect_value(t, call(loaded, "call_stream_read_lines", text_address(text), i64(len(text)), address_of(&lines)), sum)
	testing.expect_value(t, lines, 4)
	testing.expect_value(t, call(loaded, "call_stream_read_lines", text_address(""), 0, address_of(&lines)), 0)
	testing.expect_value(t, lines, 0)
	// A null buffer with bytes is refused.
	testing.expect_value(t, call(loaded, "call_stream_read_lines", 0, 5, address_of(&lines)), -1)
	// A program has no path: each name is refused.
	for name in ([?]string{"source.c", "", "/etc/passwd", "include/stddef.h"}) {
		testing.expectf(t, call(loaded, "call_open_by_name", text_address(name)) == 1, "fopen(%q) must be refused with ENOENT", name)
	}
}

Math_Operation :: enum i64 {
	Floor          = 1,
	Ceil           = 2,
	Trunc          = 3,
	Fabs           = 4,
	Fmod           = 5,
	Sqrt           = 6,
	Ldexp          = 7,
	Frexp_Fraction = 8,
	Frexp_Exponent = 9,
	Exp            = 10,
	Log            = 11,
	Log2           = 12,
	Log10          = 13,
	Pow            = 14,
	Sin            = 15,
	Cos            = 16,
	Tan            = 17,
	Asin           = 18,
	Acos           = 19,
	Atan           = 20,
	Atan2          = 21,
}

@(test)
thin_libc_math_matches_the_c_library_of_the_host :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	generator := Generator{0x5eed_0005}
	values := make([dynamic]u64, context.temp_allocator)
	append(&values, ..double_edges())
	for _ in 0 ..< 3000 {
		append(&values, next_word(&generator))
	}
	same :: proc(expected: f64, found_bits: u64) -> bool {
		if expected != expected {
			return (found_bits >> 52) & 0x7ff == 0x7ff && found_bits & 0xfffffffffffff != 0
		}
		return transmute(u64)expected == found_bits
	}
	Check :: struct {
		operation: Math_Operation,
		right:     i64,
		expected:  f64,
	}
	for bits, index in values {
		value := transmute(f64)bits
		other_bits := values[(index * 7 + 3) % len(values)]
		other := transmute(f64)other_bits
		exponent := i64(next_below(&generator, 2300)) - 1150
		frexp_exponent: i32
		frexp_fraction := libc.frexp(value, &frexp_exponent)
		checks := [?]Check {
			{.Floor, 0, libc.floor(value)},
			{.Ceil, 0, libc.ceil(value)},
			{.Trunc, 0, libc.trunc(value)},
			{.Fabs, 0, libc.fabs(value)},
			{.Fmod, i64(other_bits), libc.fmod(value, other)},
			{.Sqrt, 0, libc.sqrt(value)},
			{.Ldexp, exponent, libc.ldexp(value, i32(exponent))},
			{.Frexp_Fraction, 0, frexp_fraction},
		}
		for check in checks {
			found := u64(call(loaded, "call_math", i64(check.operation), i64(bits), check.right))
			testing.expectf(t, same(check.expected, found), "%v of %x (%x): the host gives %x, the thin libc %x", check.operation, bits, check.right, transmute(u64)check.expected, found)
		}
		if value == value && value - value == 0 {
			testing.expect_value(t, call(loaded, "call_math", i64(Math_Operation.Frexp_Exponent), i64(bits), 0), i64(frexp_exponent))
		}
	}
	// fmod with a large ratio and with subnormals is exact.
	pairs := [?][2]f64{{1e300, 3}, {-1e300, 3}, {5e-324, 3e-324}, {1.7976931348623157e308, 4.9e-324}, {7, -2}, {-7, 2}, {0, 1}, {1, 1e-300}}
	for pair in pairs {
		found := u64(call(loaded, "call_math", i64(Math_Operation.Fmod), i64(transmute(u64)pair[0]), i64(transmute(u64)pair[1])))
		testing.expectf(t, same(libc.fmod(pair[0], pair[1]), found), "fmod(%v, %v)", pair[0], pair[1])
	}
	// A word that names no operation is refused.
	for word in ([?]i64{0, 22, -1, max(i64)}) {
		testing.expect_value(t, u64(call(loaded, "call_math", word, 0, 0)), u64(0x7ff8dead00000000))
	}
}
