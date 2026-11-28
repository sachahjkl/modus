package machine

import "core:encoding/endian"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "modus:contract/store"

@(test)
root_blocks_older_format_detection_edges :: proc(t: ^testing.T) {
	u64_bytes :: proc(v: u64) -> [8]u8 {
		b: [8]u8
		endian.put_u64(b[:], .Little, v)
		return b
	}

	// Empty, short, blank, unrecognized, and out-of-range magics must not reset.
	short := [7]u8{'S', 'T', 'O', 'R', 'A', 'G', 'E'}
	testing.expect(t, !root_blocks_have_older_format(nil, nil))
	testing.expect(t, !root_blocks_have_older_format(short[:], nil))
	testing.expect(t, !root_blocks_have_older_format(short[:], short[:]))

	zero := u64_bytes(0)
	testing.expect(t, !root_blocks_have_older_format(zero[:], zero[:]))

	random := [8]u8{0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04}
	testing.expect(t, !root_blocks_have_older_format(random[:], random[:]))

	storage0 := u64_bytes(0x30454741524F5453) // "STORAGE0"
	storage8 := u64_bytes(0x38454741524F5453) // "STORAGE8"
	testing.expect(t, !root_blocks_have_older_format(storage0[:], zero[:]))
	testing.expect(t, !root_blocks_have_older_format(storage8[:], zero[:]))

	// Current format on either root block must never reset, even beside an older block.
	current := u64_bytes(store.ROOT_MAGIC)
	older6 := u64_bytes(store.OLDER_ROOT_MAGIC)
	testing.expect(t, !root_blocks_have_older_format(current[:], zero[:]))
	testing.expect(t, !root_blocks_have_older_format(zero[:], current[:]))
	testing.expect(t, !root_blocks_have_older_format(current[:], current[:]))
	testing.expect(t, !root_blocks_have_older_format(current[:], older6[:]))
	testing.expect(t, !root_blocks_have_older_format(older6[:], current[:]))

	// Older formats ("STORAGE1" to "STORAGE6") on block 0, block 1, or both trigger reset.
	older1 := u64_bytes(0x31454741524F5453) // "STORAGE1"
	older4 := u64_bytes(0x34454741524F5453) // "STORAGE4"
	testing.expect(t, root_blocks_have_older_format(older1[:], zero[:]))
	testing.expect(t, root_blocks_have_older_format(zero[:], older4[:]))
	testing.expect(t, root_blocks_have_older_format(older6[:], older6[:]))
	testing.expect(t, root_blocks_have_older_format(older6[:], nil))
}

@(test)
run_data_disk_prepare_resets_only_older_storage_disks :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "modus-data-disk-test-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer os.remove_all(dir)
	defer delete(dir)

	disk_size :: 4 * store.BLOCK_SIZE

	// Absent file is created zeroed.
	absent_path, _ := filepath.join({dir, "absent.img"}, context.temp_allocator)
	testing.expect(t, run_data_disk_prepare(absent_path, disk_size))
	absent_bytes, read_err := os.read_entire_file(absent_path, context.temp_allocator)
	testing.expect(t, read_err == nil && len(absent_bytes) == disk_size)
	for b in absent_bytes {
		testing.expect_value(t, b, u8(0))
	}

	// Current STORAGE7 disk is preserved untouched.
	current_path, _ := filepath.join({dir, "current.img"}, context.temp_allocator)
	current_buf := make([]u8, disk_size, context.temp_allocator)
	endian.put_u64(current_buf[:8], .Little, store.ROOT_MAGIC)
	current_buf[2 * store.BLOCK_SIZE] = 0x5A
	testing.expect(t, os.write_entire_file(current_path, current_buf) == nil)
	testing.expect(t, run_data_disk_prepare(current_path, disk_size))
	after_current, err2 := os.read_entire_file(current_path, context.temp_allocator)
	testing.expect(t, err2 == nil && len(after_current) == disk_size)
	testing.expect_value(t, after_current[2 * store.BLOCK_SIZE], u8(0x5A))

	// Unrecognized non-storage disk is preserved untouched.
	unknown_path, _ := filepath.join({dir, "unknown.img"}, context.temp_allocator)
	unknown_buf := make([]u8, disk_size, context.temp_allocator)
	copy(unknown_buf[:8], "NOTSTORE")
	testing.expect(t, os.write_entire_file(unknown_path, unknown_buf) == nil)
	testing.expect(t, run_data_disk_prepare(unknown_path, disk_size))
	after_unknown, err3 := os.read_entire_file(unknown_path, context.temp_allocator)
	testing.expect(t, err3 == nil && string(after_unknown[:8]) == "NOTSTORE")

	// Older STORAGE6 disk (on block 1 only) is replaced with a fresh zeroed disk.
	older_path, _ := filepath.join({dir, "older.img"}, context.temp_allocator)
	older_buf := make([]u8, disk_size, context.temp_allocator)
	endian.put_u64(older_buf[store.BLOCK_SIZE:store.BLOCK_SIZE + 8], .Little, store.OLDER_ROOT_MAGIC)
	older_buf[2 * store.BLOCK_SIZE] = 0xA5
	testing.expect(t, os.write_entire_file(older_path, older_buf) == nil)
	testing.expect(t, run_data_disk_prepare(older_path, disk_size))
	after_older, err4 := os.read_entire_file(older_path, context.temp_allocator)
	testing.expect(t, err4 == nil && len(after_older) == disk_size)
	for b in after_older {
		testing.expect_value(t, b, u8(0))
	}
}
