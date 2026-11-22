#+build !freestanding
package rtl_bidi

import "core:testing"

@(test)
bidi_detects_direction_and_reorders_arabic_hebrew_and_numbers :: proc(t: ^testing.T) {
	_, bad_dir := paragraph_direction_of_word(99)
	testing.expect(t, !bad_dir)

	// Hebrew "שלום" (Shalom) -> RTL.
	hebrew := "שלום"
	testing.expect_value(t, base_direction_detect(hebrew), Paragraph_Direction.Right_To_Left)
	// Arabic "مرحبا 123" -> RTL, with embedded LTR number "123" kept left-to-right!
	arabic_num := "مرحبا 123"
	testing.expect_value(t, base_direction_detect(arabic_num), Paragraph_Direction.Right_To_Left)

	slots: [64]Visual_Slot
	n, ok := bidi_reorder_line(hebrew, .Right_To_Left, slots[:])
	testing.expect(t, ok && n == 4)
	// Visual left-to-right order reverses the 4 Hebrew letters: ם ו ל ש.
	testing.expect_value(t, slots[0].character, rune('ם'))
	testing.expect_value(t, slots[3].character, rune('ש'))

	// RTL line with embedded ASCII digits "123": digits stay '1','2','3' visually on the left.
	n2, ok2 := bidi_reorder_line(arabic_num, .Right_To_Left, slots[:])
	testing.expect(t, ok2 && n2 == 9)
	testing.expect_value(t, slots[0].character, rune('1'))
	testing.expect_value(t, slots[1].character, rune('2'))
	testing.expect_value(t, slots[2].character, rune('3'))

	// Brackets mirror in RTL context.
	n3, ok3 := bidi_reorder_line("(שלום)", .Right_To_Left, slots[:])
	testing.expect(t, ok3 && n3 == 6)
	testing.expect_value(t, slots[0].character, rune('('))
	testing.expect_value(t, slots[5].character, rune(')'))

	// Invalid UTF-8 refused.
	bad_bytes := [1]u8{0xFF}
	_, bad_ok := bidi_reorder_line(string(bad_bytes[:]), .Left_To_Right, slots[:])
	testing.expect(t, !bad_ok)
}

@(test)
layout_mirroring_flips_x_symmetrically_in_rtl :: proc(t: ^testing.T) {
	r := Layout_Rect{x = 20, y = 10, width = 100, height = 32}
	ltr, ok1 := mirror_rect_for_direction(800, r, .Left_To_Right)
	testing.expect(t, ok1 && ltr == r)
	rtl, ok2 := mirror_rect_for_direction(800, r, .Right_To_Left)
	testing.expect(t, ok2)
	testing.expect_value(t, rtl, Layout_Rect{x = 680, y = 10, width = 100, height = 32})
	// Mirroring twice returns the exact original rect.
	back, ok3 := mirror_rect_for_direction(800, rtl, .Right_To_Left)
	testing.expect(t, ok3 && back == r)
	// Zero/negative container refused.
	_, bad := mirror_rect_for_direction(0, r, .Right_To_Left)
	testing.expect(t, !bad)
}
