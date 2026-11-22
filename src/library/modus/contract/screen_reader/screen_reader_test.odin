#+build !freestanding
package screen_reader

import "core:testing"

@(test)
screen_reader_magnifier_and_braille_end_to_end :: proc(t: ^testing.T) {
	_, bad_f := magnifier_filter_of_word(99)
	testing.expect(t, !bad_f)

	buf: [MAX_ANNOUNCEMENT_BYTES]u8
	n := announce_element(.Button, {.Focusable, .Focused}, .True, .None, .None, transmute([]u8)string("Spleen"), buf[:])
	testing.expect_value(t, string(buf[:n]), "Spleen, button, pressed")

	n2 := announce_element(.Text_Box, {.Protected, .Invalid}, .None, .None, .None, transmute([]u8)string("Passphrase"), buf[:])
	testing.expect_value(t, string(buf[:n2]), "Passphrase, textbox, protected, invalid")

	mag: Magnifier_State
	testing.expect(t, !magnifier_init(&mag, 1920, 1080, 4)) // zoom < 1.5x refused
	testing.expect(t, magnifier_init(&mag, 1920, 1080, 16))
	magnifier_focus_on(&mag, 1800, 900)
	testing.expect_value(t, mag.view_x, i32(960))
	testing.expect_value(t, mag.view_y, i32(540))

	cells: [40]u8
	bn := ascii_to_braille_cells(transmute([]u8)string("Ab1 "), 0, cells[:])
	testing.expect_value(t, bn, 4)
	testing.expect_value(t, cells[0], u8(0x01 | 0x40)) // 'A' = dot1 + dot7
	testing.expect_value(t, cells[1], u8(0x03))        // 'b' = dot1 + dot2
	testing.expect_value(t, cells[2], u8(0x01 | 0x80)) // '1' = dot1 + dot8
	testing.expect_value(t, cells[3], u8(0x00))        // ' ' = blank
}
