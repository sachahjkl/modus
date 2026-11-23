#+build !freestanding
package program_files

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
list_of :: proc(files: []File) -> []u8 {
	list := make([]u8, int(file_list_size(files)), context.temp_allocator)
	size, ok := file_list_write(files, list)
	assert(ok && size == u64(len(list)))
	return list
}

@(private = "file")
expect_list_refusal :: proc(t: ^testing.T, list: []u8, source_name: string, refusal: Refusal, offset: u64, value: u64, loc := #caller_location) {
	files: [FILES_MOST]File
	count, record := file_list_read(list, source_name, files[:])
	testing.expectf(t, record.refusal == refusal, "the refusal is %v, not %v", record.refusal, refusal, loc = loc)
	testing.expectf(t, record.offset == offset, "the offset is %d, not %d", record.offset, offset, loc = loc)
	testing.expectf(t, record.value == value, "the value is %d, not %d", record.value, value, loc = loc)
	testing.expectf(t, count == 0, "a refused list gives no file", loc = loc)
}

// Each break of the form of a file list is refused at its byte, before
// the C part reads a file.
@(test)
file_lists_that_break_their_form_are_refused :: proc(t: ^testing.T) {
	good := list_of({{name = "chibicc/chibicc.h", content = transmute([]u8)string("int x;\n")}})
	// A head cut at each of its 8 bytes.
	for cut in 1 ..< RECORD_HEAD_BYTES {
		expect_list_refusal(t, good[:cut], "chibicc/main.c", .Head_Cut, 0, RECORD_HEAD_BYTES)
	}
	// A name or a content cut: the value is the end that the head names.
	expect_list_refusal(t, good[:RECORD_HEAD_BYTES], "chibicc/main.c", .Content_Cut, 0, u64(len(good)))
	expect_list_refusal(t, good[:len(good) - 1], "chibicc/main.c", .Content_Cut, 0, u64(len(good)))
	// A second record cut after a whole first one.
	two := strings.concatenate({string(good), string(good[:3])}, context.temp_allocator)
	expect_list_refusal(t, transmute([]u8)two, "chibicc/main.c", .Head_Cut, u64(len(good)), u64(len(good)) + RECORD_HEAD_BYTES)
	// The largest sizes of a head: the sum does not wrap, and the record
	// passes the end.
	largest := [RECORD_HEAD_BYTES]u8{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
	expect_list_refusal(t, largest[:], "a.c", .Content_Cut, 0, RECORD_HEAD_BYTES + 2 * u64(max(u32)))
	// An empty name, a name of 256 bytes, and a byte 0 in a name or a content.
	expect_list_refusal(t, list_of({{name = "", content = nil}}), "a.c", .Name_Empty, RECORD_HEAD_BYTES, 0)
	long_name := strings.repeat("n", NAME_BYTES_MOST + 1, context.temp_allocator)
	expect_list_refusal(t, list_of({{name = long_name}}), "a.c", .Name_Too_Long, RECORD_HEAD_BYTES, NAME_BYTES_MOST + 1)
	expect_list_refusal(t, list_of({{name = "a\x00.h"}}), "a.c", .Byte_Zero, RECORD_HEAD_BYTES + 1, 0)
	expect_list_refusal(t, list_of({{name = "a.h", content = transmute([]u8)string("int\x00")}}), "a.c", .Byte_Zero, RECORD_HEAD_BYTES + 3 + 3, 0)
	// A name twice, and a file with the name of the source.
	twice := list_of({{name = "a.h"}, {name = "b.h"}, {name = "a.h"}})
	expect_list_refusal(t, twice, "a.c", .Name_Twice, 2 * (RECORD_HEAD_BYTES + 3) + RECORD_HEAD_BYTES, 0)
	expect_list_refusal(t, list_of({{name = "a.c"}}), "a.c", .Name_Twice, RECORD_HEAD_BYTES, 0)
	// One more file than the bound, and than the room of the caller.
	many := make([]File, FILES_MOST + 1, context.temp_allocator)
	for index in 0 ..< len(many) {
		many[index] = {name = fmt.aprintf("h%d.h", index, allocator = context.temp_allocator)}
	}
	many_list := list_of(many)
	files: [FILES_MOST]File
	count, record := file_list_read(many_list, "a.c", files[:])
	testing.expect_value(t, record.refusal, Refusal.Too_Many_Files)
	testing.expect_value(t, record.value, u64(FILES_MOST + 1))
	testing.expect_value(t, count, 0)
	count, record = file_list_read(list_of(many[:FILES_MOST]), "a.c", files[:])
	testing.expect_value(t, record.refusal, Refusal.None)
	testing.expect_value(t, count, FILES_MOST)
	count, record = file_list_read(list_of(many[:3]), "a.c", files[:2])
	testing.expect_value(t, record.refusal, Refusal.Too_Many_Files)
	testing.expect_value(t, record.value, u64(3))
	// A list past its bound is refused before a record is read.
	too_long := make([]u8, LIST_BYTES_MOST + 1, context.temp_allocator)
	expect_list_refusal(t, too_long, "a.c", .List_Too_Long, 0, LIST_BYTES_MOST + 1)
}

// A list that file_list_write writes, file_list_read reads to the same
// files: the names and the contents are views of the list.
@(test)
a_written_file_list_reads_back :: proc(t: ^testing.T) {
	files := []File {
		{name = "chibicc/chibicc.h", content = transmute([]u8)string("#include <stdio.h>\n")},
		{name = "libc/include/stdio.h", content = nil},
		{name = strings.repeat("n", NAME_BYTES_MOST, context.temp_allocator), content = transmute([]u8)string("x")},
	}
	list := list_of(files)
	testing.expect_value(t, len(list), 3 * RECORD_HEAD_BYTES + 17 + 19 + 20 + NAME_BYTES_MOST + 1)
	read: [FILES_MOST]File
	count, refusal := file_list_read(list, "chibicc/main.c", read[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	if testing.expect_value(t, count, 3) {
		for file, index in files {
			testing.expect_value(t, read[index].name, file.name)
			testing.expect_value(t, string(read[index].content), string(file.content))
		}
	}
	// The empty list has no file.
	count, refusal = file_list_read(nil, "a.c", read[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, count, 0)
	// A writer refuses an output one byte short, and writes nothing.
	short := make([]u8, len(list) - 1, context.temp_allocator)
	size, ok := file_list_write(files, short)
	testing.expect(t, !ok, "an output one byte short is refused")
	testing.expect_value(t, size, u64(0))
	for byte_value in short {
		if byte_value != 0 {
			testing.expect(t, false, "a refused write writes no byte")
			break
		}
	}
}

@(test)
export_lists_are_read_and_their_breaks_refused :: proc(t: ^testing.T) {
	names: [EXPORTS_MOST]string
	count, refusal := export_list_read("", names[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, count, 0)
	count, refusal = export_list_read(" \n\t ", names[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, count, 0)
	count, refusal = export_list_read("compile_record_at\n main\tother ", names[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	if testing.expect_value(t, count, 3) {
		testing.expect_value(t, names[0], "compile_record_at")
		testing.expect_value(t, names[1], "main")
		testing.expect_value(t, names[2], "other")
	}
	// A name twice, a byte 0, a name of 256 bytes.
	count, refusal = export_list_read("f g f", names[:])
	testing.expect_value(t, refusal.refusal, Refusal.Name_Twice)
	testing.expect_value(t, refusal.offset, u64(4))
	testing.expect_value(t, count, 0)
	count, refusal = export_list_read("f g\x00", names[:])
	testing.expect_value(t, refusal.refusal, Refusal.Byte_Zero)
	testing.expect_value(t, refusal.offset, u64(3))
	long_name := strings.repeat("e", NAME_BYTES_MOST + 1, context.temp_allocator)
	count, refusal = export_list_read(long_name, names[:])
	testing.expect_value(t, refusal.refusal, Refusal.Name_Too_Long)
	testing.expect_value(t, refusal.value, u64(NAME_BYTES_MOST + 1))
	count, refusal = export_list_read(long_name[:NAME_BYTES_MOST], names[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, count, 1)
	// The bound of the exports, and one past it.
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< EXPORTS_MOST + 1 {
		fmt.sbprintf(&builder, "x%d ", index)
	}
	all := strings.to_string(builder)
	count, refusal = export_list_read(all, names[:])
	testing.expect_value(t, refusal.refusal, Refusal.Too_Many_Names)
	testing.expect_value(t, refusal.value, u64(EXPORTS_MOST + 1))
	testing.expect_value(t, count, 0)
	last_space := strings.last_index(strings.trim_right(all, " "), " ")
	count, refusal = export_list_read(all[:last_space], names[:])
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, count, EXPORTS_MOST)
}

@(test)
names_of_a_source_break_their_rule :: proc(t: ^testing.T) {
	testing.expect_value(t, name_check("", 5).refusal, Refusal.Name_Empty)
	testing.expect_value(t, name_check("", 5).offset, u64(5))
	testing.expect_value(t, name_check("a", 0).refusal, Refusal.None)
	testing.expect_value(t, name_check(strings.repeat("a", NAME_BYTES_MOST, context.temp_allocator), 0).refusal, Refusal.None)
	testing.expect_value(t, name_check(strings.repeat("a", NAME_BYTES_MOST + 1, context.temp_allocator), 0).refusal, Refusal.Name_Too_Long)
	testing.expect_value(t, name_check("\x00", 0).refusal, Refusal.Byte_Zero)
	testing.expect_value(t, name_check("ab\x00", 10).offset, u64(12))
}
