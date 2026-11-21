#+build !freestanding
package bochs_display

import "core:testing"
import "modus:contract/reference_screen"

TEST_WIDTH :: reference_screen.WIDTH
TEST_HEIGHT :: reference_screen.HEIGHT
// The video memory of QEMU with no option, which a test machine states
// (tools/modustool/machine/machine_command.odin, MACHINE_VIDEO_MEMORY_MIB).
TEST_VIDEO_MEMORY_BYTES :: 16 << 20

// The display registers as the firmware leaves them on the standard VGA of
// QEMU with 16 MiB of video memory: the mode of a screen, and the lines
// that the video memory holds, which QEMU computes.
registers_of_the_firmware :: proc(width: u16 = TEST_WIDTH, height: u16 = TEST_HEIGHT) -> (registers: [Register]u16) {
	registers[.Identity] = IDENTITY_LAST
	registers[.Width] = width
	registers[.Height] = height
	registers[.Bits_Per_Pixel] = BITS_PER_PIXEL
	registers[.Enable] = ENABLED | LINEAR_FRAMEBUFFER
	registers[.Virtual_Width] = width
	registers[.Virtual_Height] = u16(TEST_VIDEO_MEMORY_BYTES / (int(width) * BITS_PER_PIXEL / 8))
	registers[.Video_Memory_Blocks] = TEST_VIDEO_MEMORY_BYTES / VIDEO_MEMORY_BLOCK
	return
}

// The bytes of two screens of the test, and the blocks of video memory
// that hold them: two screens of the reference screen are not a whole
// count of blocks, so the count rounds up.
TWO_SCREEN_BYTES :: PAGE_COUNT * TEST_HEIGHT * TEST_WIDTH * BITS_PER_PIXEL / 8
TWO_SCREEN_BLOCKS :: (TWO_SCREEN_BYTES + VIDEO_MEMORY_BLOCK - 1) / VIDEO_MEMORY_BLOCK
#assert(TWO_SCREEN_BYTES % VIDEO_MEMORY_BLOCK != 0, "the test of the block that is one short needs two screens that end inside a block")

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
		{.Video_Memory_Blocks, 0},
		{.Video_Memory_Blocks, TWO_SCREEN_BLOCKS - 1},
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
	// Exactly two screens of lines and of blocks is enough.
	registers[.Virtual_Height] = PAGE_COUNT * TEST_HEIGHT
	registers[.Video_Memory_Blocks] = TWO_SCREEN_BLOCKS
	testing.expect_value(t, screen_pages(&registers[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH), PAGE_COUNT)
}

// The reference screen in the video memory of a test machine: the 16 MiB
// hold two pages, with 24 lines to spare, and a video memory that ends one
// block before the end of the second page, though the lines of the
// register say that two pages fit, gives one page. A screen of 1920 by
// 2160, whose second page would end past the video memory, gives one.
@(test)
the_reference_screen_fits_two_pages_in_the_video_memory :: proc(t: ^testing.T) {
	registers := registers_of_the_firmware()
	testing.expect_value(t, int(registers[.Virtual_Height]), PAGE_COUNT * TEST_HEIGHT + 24)
	testing.expect(t, TWO_SCREEN_BYTES <= TEST_VIDEO_MEMORY_BYTES)

	short := registers_of_the_firmware()
	short[.Video_Memory_Blocks] = TWO_SCREEN_BLOCKS - 1
	testing.expect_value(t, screen_pages(&short[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH), 1)
	testing.expect_value(t, short[.Offset_Y], u16(0))

	// The block that holds the end of the second page is the last one that
	// the video memory needs: 254 blocks give two pages.
	#assert(TWO_SCREEN_BLOCKS == 254)
	exact := registers_of_the_firmware()
	exact[.Video_Memory_Blocks] = TWO_SCREEN_BLOCKS
	exact[.Virtual_Height] = PAGE_COUNT * TEST_HEIGHT
	testing.expect_value(t, screen_pages(&exact[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH), PAGE_COUNT)

	tall := registers_of_the_firmware(TEST_WIDTH, 2 * TEST_HEIGHT)
	testing.expect_value(t, screen_pages(&tall[.Identity], TEST_WIDTH, 2 * TEST_HEIGHT, TEST_WIDTH), 1)

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

// The mode of the firmware with room for two screens gives two pages, at
// the reference screen and at a screen of 1024 by 768.
@(test)
the_mode_of_the_firmware_gives_two_screen_pages :: proc(t: ^testing.T) {
	registers := registers_of_the_firmware()
	testing.expect_value(t, screen_pages(&registers[.Identity], TEST_WIDTH, TEST_HEIGHT, TEST_WIDTH), PAGE_COUNT)
	smaller := registers_of_the_firmware(1024, 768)
	testing.expect_value(t, screen_pages(&smaller[.Identity], 1024, 768, 1024), PAGE_COUNT)
}
