package machine

import "core:testing"
import format "modus:contract/store"

// The test disk drops the first write of zeros over the block that holds
// the marker, counts each other block of zeros that it keeps, and takes the
// count of the batch of the drop at the next flush
// (src/md/features/version_erase.md).
@(test)
the_test_disk_drops_one_write_of_zeros_and_counts_the_zeros_that_it_keeps :: proc(t: ^testing.T) {
	DISK_BLOCKS :: 8
	MARKED_BLOCK :: 5
	server: Network_Block_Device
	server.current = make([]u8, DISK_BLOCKS * format.BLOCK_SIZE)
	defer delete(server.current)
	zeros := make([]u8, 4 * format.BLOCK_SIZE)
	defer delete(zeros)
	marker := [4]u8{0xA1, 0xB2, 0xC3, 0xD4}
	copy(server.current[MARKED_BLOCK * format.BLOCK_SIZE + 100:], marker[:])

	// With no marker the disk drops nothing and counts nothing.
	testing.expect_value(t, zero_drop_decide(&server, MARKED_BLOCK * format.BLOCK_SIZE, zeros[:format.BLOCK_SIZE]), -1)
	testing.expect_value(t, server.zero_blocks_since_flush, 0)
	server.zero_drop_bytes = marker[:]

	// A block of zeros over a block with no marker is kept and counted; a
	// flush before the drop only starts a new count.
	testing.expect_value(t, zero_drop_decide(&server, ROOT_BLOCK_PLACES * format.BLOCK_SIZE, zeros[:format.BLOCK_SIZE]), -1)
	testing.expect_value(t, server.zero_blocks_since_flush, 1)
	zero_drop_flush(&server)
	testing.expect_value(t, server.zero_drop_state, Zero_Drop_State.Armed)
	testing.expect_value(t, server.zero_blocks_since_flush, 0)
	testing.expect_value(t, server.zero_blocks_kept_with_drop, 0)

	// One write of four blocks of zeros, from block 3: the third block
	// holds the marker and is dropped, the three others are kept.
	FIRST_BLOCK :: MARKED_BLOCK - 2
	testing.expect_value(t, zero_drop_decide(&server, FIRST_BLOCK * format.BLOCK_SIZE, zeros[:]), (MARKED_BLOCK - FIRST_BLOCK) * format.BLOCK_SIZE)
	testing.expect_value(t, server.zero_drop_state, Zero_Drop_State.Dropped)
	testing.expect_value(t, server.zero_dropped_block, u64(MARKED_BLOCK))
	testing.expect_value(t, server.zero_blocks_since_flush, 3)

	// A block that is not zeros is no write of zeros, even over the marker.
	other := make([]u8, format.BLOCK_SIZE)
	defer delete(other)
	other[0] = 1
	testing.expect_value(t, zero_drop_decide(&server, MARKED_BLOCK * format.BLOCK_SIZE, other), -1)
	testing.expect_value(t, server.zero_blocks_since_flush, 3)

	// Only the first write of zeros over a marker is dropped.
	copy(server.current[(DISK_BLOCKS - 1) * format.BLOCK_SIZE:], marker[:])
	testing.expect_value(t, zero_drop_decide(&server, (DISK_BLOCKS - 1) * format.BLOCK_SIZE, zeros[:format.BLOCK_SIZE]), -1)
	testing.expect_value(t, server.zero_blocks_since_flush, 4)

	// The flush after the drop takes the count of its batch.
	zero_drop_flush(&server)
	testing.expect_value(t, server.zero_drop_state, Zero_Drop_State.Flushed)
	testing.expect_value(t, server.zero_blocks_kept_with_drop, 4)
	testing.expect_value(t, server.zero_blocks_since_flush, 0)
	zero_drop_flush(&server)
	testing.expect_value(t, server.zero_blocks_kept_with_drop, 4)

	// A write of a root, and a write that is not aligned to a block, are
	// not writes of the storage service over its blocks.
	testing.expect_value(t, zero_drop_decide(&server, 0, zeros[:format.BLOCK_SIZE]), -1)
	testing.expect_value(t, zero_drop_decide(&server, ROOT_BLOCK_PLACES * format.BLOCK_SIZE + 512, zeros[:format.BLOCK_SIZE]), -1)
	testing.expect_value(t, server.zero_blocks_since_flush, 0)
}
