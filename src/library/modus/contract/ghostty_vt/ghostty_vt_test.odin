#+build !freestanding
package ghostty_vt

import "core:testing"

@(test)
ghostty_vt_options_and_fixed_arena_allocator :: proc(t: ^testing.T) {
	_, bad_ref := vt_refusal_of_word(99)
	testing.expect(t, !bad_ref)

	testing.expect_value(t, terminal_options_validate({0, 24, 0}), Vt_Refusal.Invalid_Cols)
	testing.expect_value(t, terminal_options_validate({MAX_COLS + 1, 24, 0}), Vt_Refusal.Invalid_Cols)
	testing.expect_value(t, terminal_options_validate({80, 0, 0}), Vt_Refusal.Invalid_Rows)
	testing.expect_value(t, terminal_options_validate({80, 24, MAX_SCROLLBACK_BYTES + 1}), Vt_Refusal.Scrollback_Limit)
	testing.expect_value(t, terminal_options_validate({80, 24, 1024 * 1024}), Vt_Refusal.None)

	backing: [4096]u8
	arena: Fixed_Arena
	testing.expect_value(t, fixed_arena_init(&arena, backing[:16]), Vt_Refusal.Arena_Too_Small)
	testing.expect_value(t, fixed_arena_init(&arena, backing[:]), Vt_Refusal.None)
	vtable := fixed_arena_allocator(&arena)

	// Zero-size and excessive alignment refused cleanly.
	testing.expect(t, vtable.alloc(vtable.ctx, 0, 0, 0) == nil)
	testing.expect(t, vtable.alloc(vtable.ctx, 16, 7, 0) == nil)

	// Aligned 64-byte allocation succeeds and honors alignment.
	p1 := vtable.alloc(vtable.ctx, 128, 6, 0)
	testing.expect(t, p1 != nil)
	testing.expect_value(t, arena.live_bytes, uint(128))
	p1[0] = 0xAB
	p1[127] = 0xCD

	// Tail grow in-place works; shrink works.
	testing.expect(t, vtable.resize(vtable.ctx, p1, 128, 6, 256, 0))
	testing.expect_value(t, arena.live_bytes, uint(256))
	testing.expect(t, vtable.resize(vtable.ctx, p1, 256, 6, 64, 0))
	testing.expect_value(t, arena.live_bytes, uint(64))

	// Allocate p2 after p1; p1 cannot grow in place, so remap moves it preserving bytes.
	p2 := vtable.alloc(vtable.ctx, 64, 4, 0)
	testing.expect(t, p2 != nil)
	testing.expect(t, !vtable.resize(vtable.ctx, p1, 64, 6, 128, 0))
	p1_moved := vtable.remap(vtable.ctx, p1, 64, 6, 128, 0)
	testing.expect(t, p1_moved != nil && p1_moved[0] == 0xAB)

	// OOM refused cleanly without corrupting live blocks.
	testing.expect(t, vtable.alloc(vtable.ctx, 10_000, 3, 0) == nil)
	testing.expect(t, arena.failed_allocs > 0)

	// Free all rewinds cursor back to 0 and double-free is a safe no-op.
	vtable.free(vtable.ctx, p1_moved, 128, 6, 0)
	vtable.free(vtable.ctx, p1_moved, 128, 6, 0)
	vtable.free(vtable.ctx, p2, 64, 4, 0)
	testing.expect_value(t, arena.live_bytes, uint(0))
	testing.expect_value(t, arena.cursor, uint(0))
	testing.expect_value(t, arena.active_blocks, 0)
}
