#+build !freestanding
package bochs_display

import "core:testing"

TEST_WIDTH :: 1024
TEST_HEIGHT :: 768

// The display registers as the firmware leaves them on the standard VGA of
// QEMU with 16 MiB of video memory: the mode of the screen, and the lines
// that the video memory holds, which QEMU computes.
registers_of_the_firmware :: proc() -> (registers: [Register]u16) {
	registers[.Identity] = IDENTITY_LAST
	registers[.Width] = TEST_WIDTH
	registers[.Height] = TEST_HEIGHT
	registers[.Bits_Per_Pixel] = BITS_PER_PIXEL
	registers[.Enable] = ENABLED | LINEAR_FRAMEBUFFER
	registers[.Virtual_Width] = TEST_WIDTH
	registers[.Virtual_Height] = (16 << 20) / (TEST_WIDTH * BITS_PER_PIXEL / 8)
	return
}

// The mode of the firmware with room for two screens gives two pages.
@(test)
the_mode_of_the_firmware_gives_two_screen_pages :: proc(t: ^testing.T) {
	registers := registers_of_the_firmware()
	testing.expect_value(t, screen_pages(&registers[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH), PAGE_COUNT)
}

// Each fact that a page needs, broken one at a time, gives one page: the
// display would show a part of two screens, or a screen of another mode.
@(test)
a_mode_that_differs_from_the_framebuffer_gives_one_page :: proc(t: ^testing.T) {
	Change :: struct {
		register: Register,
		value:    u16,
	}
	changes := [?]Change {
		{.Identity, IDENTITY_FIRST - 1},
		{.Identity, IDENTITY_LAST + 1},
		{.Enable, ENABLED},
		{.Enable, LINEAR_FRAMEBUFFER},
		{.Bits_Per_Pixel, BITS_PER_PIXEL - 8},
		{.Width, TEST_WIDTH + 8},
		{.Height, TEST_HEIGHT + 8},
		{.Virtual_Width, TEST_WIDTH + 8},
		{.Offset_X, 8},
		{.Offset_Y, TEST_HEIGHT},
		{.Virtual_Height, PAGE_COUNT * TEST_HEIGHT - 1},
	}
	for change in changes {
		registers := registers_of_the_firmware()
		registers[change.register] = change.value
		testing.expectf(t, screen_pages(&registers[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH) == 1, "the register %v with %d gives two pages", change.register, change.value)
	}
	// A framebuffer of the firmware whose line is longer than the line of
	// the video memory.
	registers := registers_of_the_firmware()
	testing.expect_value(t, screen_pages(&registers[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH + 8), 1)
	// Exactly two screens of lines is enough.
	registers[.Virtual_Height] = PAGE_COUNT * TEST_HEIGHT
	testing.expect_value(t, screen_pages(&registers[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH), PAGE_COUNT)
}

// A flip writes the first line of the page, and reads it back: plain
// memory keeps it, as the device keeps a page that fits.
@(test)
a_flip_writes_the_first_line_of_the_page :: proc(t: ^testing.T) {
	registers := registers_of_the_firmware()
	testing.expect(t, page_show(&registers[.Identity], 1, TEST_HEIGHT))
	testing.expect_value(t, registers[.Offset_Y], u16(TEST_HEIGHT))
	testing.expect(t, page_show(&registers[.Identity], 0, TEST_HEIGHT))
	testing.expect_value(t, registers[.Offset_Y], u16(0))
	testing.expect_value(t, registers[.Offset_X], u16(0))
}
