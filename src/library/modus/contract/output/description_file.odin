package output

import "base:intrinsics"
import "modus:contract/module"

// The description of the record of a wiring, for its reader
// (src/md/features/module_outputs.md, "How an end reaches a process"). A
// process has no copy of its own module file, so the root service gives
// each reader end a description file: a module file that holds the one
// record of the wiring at the index 1 of its table Records, its fields
// and their names, and no other table. The reader takes it with
// module.record_stream_type(file, 1) and checks each compartment against
// it with record_of_compartment. The root service writes it from the
// module file of the writer, after the type check: the reader checks
// against the description that the root service compared, never against a
// description that the writer sends.

// The index of the record in a description file.
DESCRIPTION_RECORD_INDEX :: 1

// The most bytes of a description file: the header, the directory, two
// records, the fields of the largest record and their names.
DESCRIPTION_FILE_BYTES_MOST :: 2 * module.PAGE_SIZE

// description_file_write writes the description file of the record index
// of file into into, and gives its size. It refuses a record that
// module.record_stream_type refuses, and a file that does not fit into.
// It reads file once for each part, which the caller checked with
// module.validate.
description_file_write :: proc "contextless" (into: []u8, file: []u8, index: u32) -> (size: int, ok: bool) {
	described := module.record_stream_type(file, index) or_return
	directory_end := size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry)
	records_at := directory_end
	fields_at := records_at + 2 * size_of(module.Record)
	strings_at := fields_at + (int(described.field_count) + 1) * size_of(module.Field)
	// The names: the record, then each field, after one zero byte.
	strings_count := 1 + int(described.name_count)
	for number in 0 ..< described.field_count {
		item := module.field(file, described, number) or_return
		strings_count += int(item.name_count)
	}
	size = strings_at + strings_count
	if size > len(into) {
		return 0, false
	}
	intrinsics.mem_zero(raw_data(into), size)
	cursor := u32(1)
	name := module.string_at(file, described.name_offset, described.name_count)
	if len(name) != int(described.name_count) {
		return 0, false
	}
	copy(into[strings_at + int(cursor):], name)
	record := module.Record{name_offset = cursor, name_count = described.name_count, size = described.size, first_field = 1, field_count = described.field_count}
	cursor += described.name_count
	intrinsics.mem_copy_non_overlapping(&into[records_at + size_of(module.Record)], &record, size_of(record))
	for number in 0 ..< described.field_count {
		item := module.field(file, described, number) or_return
		field_name := module.string_at(file, item.name_offset, item.name_count)
		if len(field_name) != int(item.name_count) {
			return 0, false
		}
		copy(into[strings_at + int(cursor):], field_name)
		item.name_offset = cursor
		cursor += item.name_count
		intrinsics.mem_copy_non_overlapping(&into[fields_at + (int(number) + 1) * size_of(module.Field)], &item, size_of(item))
	}
	directory: [module.TABLE_COUNT]module.Table_Entry
	directory[module.Table_Kind.Records] = {offset = u64(records_at), count = 2, record_size = size_of(module.Record)}
	directory[module.Table_Kind.Fields] = {offset = u64(fields_at), count = described.field_count + 1, record_size = size_of(module.Field)}
	directory[module.Table_Kind.Strings] = {offset = u64(strings_at), count = u32(strings_count), record_size = 1}
	header := module.Header{magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	intrinsics.mem_copy_non_overlapping(raw_data(into), &header, size_of(header))
	intrinsics.mem_copy_non_overlapping(&into[size_of(module.Header)], &directory, size_of(directory))
	return size, true
}
