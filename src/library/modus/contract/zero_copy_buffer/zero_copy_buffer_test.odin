#+build !freestanding
package zero_copy_buffer

import "core:testing"

@(test)
zero_copy_handoff_and_large_page_split :: proc(t: ^testing.T) {
	_, bad := buffer_state_of_word(99)
	testing.expect(t, !bad)

	// 4K RGBA framebuffer: 3840 * 2160 * 4 = 33,177,600 bytes -> 15 large pages + 432 small pages.
	lp, sp, ok := pages_for_buffer(3840 * 2160 * 4)
	testing.expect(t, ok)
	testing.expect_value(t, lp, u32(15))
	testing.expect_value(t, sp, u32(432))

	p: Buffer_Pool
	pool_init(&p)
	id, r1 := pool_acquire_for_write(&p, writer_stage = 10, byte_size = 3840 * 2160 * 4)
	testing.expect_value(t, r1, Buffer_Refusal.None)

	// Wrong writer cannot seal.
	testing.expect_value(t, pool_seal_to_readers(&p, id, writer_stage = 99, reader_count = 2), Buffer_Refusal.Wrong_Owner)
	// Real writer seals for 2 downstream zero-copy readers (compositor + remote_display).
	testing.expect_value(t, pool_seal_to_readers(&p, id, writer_stage = 10, reader_count = 2), Buffer_Refusal.None)

	f1, r2 := pool_reader_release(&p, id)
	testing.expect_value(t, r2, Buffer_Refusal.None)
	testing.expect(t, !f1)
	f2, r3 := pool_reader_release(&p, id)
	testing.expect_value(t, r3, Buffer_Refusal.None)
	testing.expect(t, f2)
}
