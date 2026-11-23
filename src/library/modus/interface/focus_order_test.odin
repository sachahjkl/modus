#+build !freestanding
package interface

import "core:testing"
import "modus:display"

// Unbacked Interface_State keeps 64 focusable elements inline and counts any
// past 64 in focus_overflow without mutating the 64 kept entries.
@(test)
focus_order_inline_tier_and_overflow_tier :: proc(t: ^testing.T) {
	Grow_State :: struct {
		backing: [dynamic]Element_Identity,
		limit:   int,
	}
	grow_focus :: proc "contextless" (user_data: rawptr, current: []Element_Identity, minimum_count: int) -> (grown: []Element_Identity, ok: bool) {
		ctx := (^Grow_State)(user_data)
		if minimum_count > ctx.limit {
			return nil, false
		}
		size := min(ctx.limit, max(minimum_count, max(len(current) * 2, FOCUS_ORDER_CAPACITY + 32)))
		return ctx.backing[:size], true
	}

	records: [256]Draw_Record
	text: [1024]u8
	table := Draw_Table{records = records[:], text = text[:]}
	input: Input
	base := identity("item")

	// Unbacked state: 64 stay inline, 65th increments focus_overflow.
	unbacked: Interface_State
	frame := frame_begin(&table, &unbacked, &input)
	for i in 0 ..< FOCUS_ORDER_CAPACITY + 2 {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	testing.expect_value(t, frame.focus_count, FOCUS_ORDER_CAPACITY)
	testing.expect_value(t, frame.focus_overflow, 2)
	testing.expect(t, !frame.focus_in_overflow)
	frame_end(&frame)
	testing.expect_value(t, len(state_focus_order(&unbacked)), FOCUS_ORDER_CAPACITY)

	// Backed state crossing 64 -> 65 -> 130 elements with Tab and Shift+Tab.
	state: Interface_State
	grow_ctx := Grow_State{limit = 140}
	resize(&grow_ctx.backing, 140)
	defer delete(grow_ctx.backing)
	interface_state_set_focus_overflow(&state, nil, grow_focus, &grow_ctx)

	// Frame 1: exactly 64 stays inline (zero overflow moves).
	frame = frame_begin(&table, &state, &input)
	for i in 0 ..< FOCUS_ORDER_CAPACITY {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	testing.expect(t, !frame.focus_in_overflow)
	testing.expect_value(t, state.focus_overflow_moves, u64(0))
	frame_end(&frame)

	// Frame 2: 65 elements crosses into the overflow tier; Tab reaches #65 and wraps.
	COUNT_65 :: FOCUS_ORDER_CAPACITY + 1
	frame = frame_begin(&table, &state, &input)
	for i in 0 ..< COUNT_65 {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	testing.expect(t, frame.focus_in_overflow)
	testing.expect_value(t, frame.focus_count, COUNT_65)
	testing.expect_value(t, frame.focus_overflow, 0)
	testing.expect_value(t, state.focus_overflow_moves, u64(1))
	frame_end(&frame)
	testing.expect(t, state.focus_in_overflow)
	testing.expect_value(t, len(state_focus_order(&state)), COUNT_65)

	// Focus at #64 -> Tab moves to #65 (index 64) -> Tab wraps to #1 (index 0).
	state.focus = identity_with(base, FOCUS_ORDER_CAPACITY - 1)
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, pressed = true, code = KEY_TAB})
	frame = frame_begin(&table, &state, &input)
	testing.expect_value(t, state.focus, identity_with(base, FOCUS_ORDER_CAPACITY))
	frame_end(&frame)

	// Shift+Tab from index 0 wraps backward to the last element (index 64).
	state.focus = identity_with(base, 0)
	// Rebuild 65 elements so state holds them again.
	input_clear(&input)
	frame = frame_begin(&table, &state, &input)
	for i in 0 ..< COUNT_65 {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, pressed = true, code = KEY_TAB, modifiers = display.MODIFIER_SHIFT})
	frame = frame_begin(&table, &state, &input)
	testing.expect_value(t, state.focus, identity_with(base, FOCUS_ORDER_CAPACITY))

	// Grow past first overflow slice (130 elements) and check collision detection past 64.
	for i in 0 ..< 130 {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	// Duplicate of index 120 must be detected by identity_collisions.
	_ = element_interact(&frame, identity_with(base, 120), {0, 0, 20, 8}, .Button)
	testing.expect_value(t, frame.identity_collisions, 1)
	testing.expect_value(t, frame.focus_count, 131)
	testing.expect(t, state.focus_overflow_moves >= 2)
	// Exceed grow_ctx.limit (140): extra elements increment focus_overflow cleanly.
	for i in 131 ..< 145 {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	testing.expect_value(t, frame.focus_count, 140)
	testing.expect_value(t, frame.focus_overflow, 5)
	frame_end(&frame)

	// Frame returning to <= 64 elements drops back to inline while keeping overflow_moves.
	moves_before := state.focus_overflow_moves
	input_clear(&input)
	frame = frame_begin(&table, &state, &input)
	for i in 0 ..< 10 {
		_ = element_interact(&frame, identity_with(base, i), {0, i * 10, 20, 8}, .Button)
	}
	frame_end(&frame)
	testing.expect(t, !state.focus_in_overflow)
	testing.expect_value(t, state.focus_count, 10)
	testing.expect_value(t, state.focus_overflow_moves, moves_before)
}
