#+build !freestanding
package disk_program

import "core:testing"

// scan_hash_of gives a hash whose bytes are all one value.
@(private = "file")
scan_hash_of :: proc(value: u8) -> (hash: [HASH_SIZE]u8) {
	for &byte in hash {
		byte = value
	}
	return hash
}

// Each entry is read one time, in the order of the list, and the scan ends
// when each wanted hash has its bytes: the entries after it are not read.
@(test)
a_scan_reads_each_entry_once_and_ends_when_found :: proc(t: ^testing.T) {
	scan: Import_Scan
	testing.expect_value(t, scan_next(&scan), -1) // Nothing wanted: no read.
	testing.expect_value(t, scan_want(&scan, scan_hash_of(2), -1, 1), Want_Answer.Added)
	testing.expect_value(t, scan_want(&scan, scan_hash_of(2), -1, 1), Want_Answer.Present)
	for name in ([]string{"first", "second", "third"}) {
		testing.expect(t, scan_entry_add(&scan, name, 100))
	}
	testing.expect_value(t, scan_next(&scan), 0)
	testing.expect_value(t, scan_read_done(&scan, 0, scan_hash_of(1)), -1)
	testing.expect_value(t, scan_next(&scan), 1)
	testing.expect_value(t, scan_read_done(&scan, 1, scan_hash_of(2)), 0)
	testing.expect(t, scan.wanted[0].found && scan.wanted[0].entry == 1 && scan.entries[1].kept)
	testing.expect_value(t, scan_missing(&scan), -1)
	testing.expect_value(t, scan_next(&scan), -1)
	testing.expect_value(t, scan.reads, 2)
}

// An entry read before its hash was wanted is read one time more: the
// import of a module that the scan kept can be a file that it read before.
@(test)
an_entry_read_before_it_was_wanted_is_read_again :: proc(t: ^testing.T) {
	scan: Import_Scan
	scan_want(&scan, scan_hash_of(2), -1, 1)
	scan_entry_add(&scan, "library_of_the_library", 10)
	scan_entry_add(&scan, "library", 10)
	testing.expect_value(t, scan_read_done(&scan, scan_next(&scan), scan_hash_of(3)), -1)
	kept := scan_read_done(&scan, scan_next(&scan), scan_hash_of(2))
	testing.expect_value(t, kept, 0)
	// The kept file imports the hash of the first entry.
	testing.expect_value(t, scan_want(&scan, scan_hash_of(3), 1, 2), Want_Answer.Added)
	testing.expect_value(t, scan.wanted[1].importer, 1)
	testing.expect_value(t, scan_next(&scan), 0)
	testing.expect_value(t, scan_read_done(&scan, 0, scan_hash_of(3)), 1)
	testing.expect_value(t, scan_next(&scan), -1)
}

// A file whose bytes do not have the wanted hash is never kept, and the
// hash stays missing: the start is refused.
@(test)
bytes_with_another_hash_are_not_kept :: proc(t: ^testing.T) {
	scan: Import_Scan
	scan_want(&scan, scan_hash_of(2), -1, 1)
	scan_entry_add(&scan, "library", 10)
	testing.expect_value(t, scan_read_done(&scan, scan_next(&scan), scan_hash_of(9)), -1)
	testing.expect_value(t, scan_next(&scan), -1)
	testing.expect_value(t, scan_missing(&scan), 0)
	testing.expect(t, !scan.entries[0].kept)
}

// The entries that the scan does not note: a name that no disk program
// has, the disk grant table, an object with no byte or over the limit; and
// past the capacity, with the mark that says so.
@(test)
the_entries_that_a_scan_does_not_note :: proc(t: ^testing.T) {
	scan: Import_Scan
	testing.expect(t, !scan_entry_add(&scan, TABLE_OBJECT_NAME, 10))
	testing.expect(t, !scan_entry_add(&scan, "a/b", 10))
	testing.expect(t, !scan_entry_add(&scan, "empty", 0))
	testing.expect(t, !scan_entry_add(&scan, "large", FILE_BYTES_LIMIT + 1))
	testing.expect(t, !scan_entry_add(&scan, "negative", -1))
	testing.expect_value(t, scan.entry_count, 0)
	for _ in 0 ..< SCAN_ENTRY_CAPACITY {
		testing.expect(t, scan_entry_add(&scan, "file", 1))
	}
	testing.expect(t, !scan.entries_left_out)
	testing.expect(t, !scan_entry_add(&scan, "file", 1))
	testing.expect(t, scan.entries_left_out)
	testing.expect_value(t, scan_entry_name(&scan, 0), "file")
}

// The bounds of the wanted hashes: a zero hash, a level past the limit, and
// a hash past the capacity are not noted, and the last two mark the scan.
@(test)
the_bounds_of_the_wanted_hashes :: proc(t: ^testing.T) {
	scan: Import_Scan
	testing.expect_value(t, scan_want(&scan, {}, -1, 1), Want_Answer.Zero)
	testing.expect(t, !scan.bound_passed)
	testing.expect_value(t, scan_want(&scan, scan_hash_of(1), -1, SCAN_DEPTH_LIMIT + 1), Want_Answer.Too_Deep)
	testing.expect(t, scan.bound_passed)
	scan = {}
	for value in 1 ..= SCAN_WANTED_CAPACITY {
		testing.expect_value(t, scan_want(&scan, scan_hash_of(u8(value)), -1, 1), Want_Answer.Added)
	}
	testing.expect_value(t, scan_want(&scan, scan_hash_of(200), -1, 1), Want_Answer.Full)
	testing.expect(t, scan.bound_passed)
}

// A skipped entry is never read again: its bytes did not come once.
@(test)
a_skipped_entry_is_not_read_again :: proc(t: ^testing.T) {
	scan: Import_Scan
	scan_want(&scan, scan_hash_of(5), -1, 1)
	scan_entry_add(&scan, "gone", 10)
	scan_skip(&scan, scan_next(&scan))
	testing.expect_value(t, scan_next(&scan), -1)
	testing.expect_value(t, scan.reads, 1)
}

// A storage service that gives other bytes at each read: the scan ends
// after SCAN_READ_LIMIT reads whatever it gives.
@(test)
a_scan_ends_after_its_read_limit :: proc(t: ^testing.T) {
	scan: Import_Scan
	for value in 1 ..= SCAN_WANTED_CAPACITY {
		scan_want(&scan, scan_hash_of(u8(value)), -1, 1)
	}
	scan_entry_add(&scan, "changing", 10)
	reads := 0
	for index := scan_next(&scan); index >= 0; index = scan_next(&scan) {
		// Each read gives the hash that the scan asks for next, then
		// another: it is kept only when it matches, so it changes again.
		scan.entries[index].kept = false
		scan_read_done(&scan, index, scan_hash_of(u8(100 + reads % 2)))
		scan.entries[index].hash = scan_hash_of(u8(1 + reads % SCAN_WANTED_CAPACITY))
		reads += 1
		if reads > SCAN_READ_LIMIT {
			break
		}
	}
	testing.expect(t, reads <= SCAN_READ_LIMIT)
}
