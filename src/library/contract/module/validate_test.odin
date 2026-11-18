#+build !freestanding
package module

import "core:testing"

// The fuzz finding of the target module_file (tools/modustool/fuzz/fuzzing_corpus):
// 80 bytes whose table of segments states 0x04000000 records of no byte.
// The table took no byte of the file, so validate accepted it, then looped
// over 67 million empty segments, and copy_segments did it again: an input
// that did not end in the hang bound of the fuzzing.
@(rodata)
fuzz_finding_of_records_of_no_byte := [80]u8 {
	0x4d, 0x4f, 0x44, 0x55, 0x4c, 0x45, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
}

@(test)
records_of_no_byte_are_refused :: proc(t: ^testing.T) {
	finding := fuzz_finding_of_records_of_no_byte
	testing.expect_value(t, validate(finding[:]), Error.Bad_Table)

	// The same file with each count at its edges: 1 record, and the largest
	// count, both of no byte. Each one is refused.
	for count in ([2]u32{1, max(u32)}) {
		file := fuzz_finding_of_records_of_no_byte
		segments_entry := size_of(Header) + int(Table_Kind.Segments) * size_of(Table_Entry)
		(^u32)(&file[segments_entry + 8])^ = count
		testing.expectf(t, validate(file[:]) == .Bad_Table, "a table of %d records of no byte is not refused", count)
	}

	// A record of one byte bounds the count by the bytes of the file: one
	// record more than the file holds is a table out of the file.
	bounded := fuzz_finding_of_records_of_no_byte
	bounded_entry := size_of(Header) + int(Table_Kind.Segments) * size_of(Table_Entry)
	(^u32)(&bounded[bounded_entry + 8])^ = u32(len(bounded)) + 1
	(^u32)(&bounded[bounded_entry + 12])^ = 1
	testing.expect_value(t, validate(bounded[:]), Error.Bad_Table)
}
