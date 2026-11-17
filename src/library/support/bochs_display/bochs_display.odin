// The display registers of Bochs on the standard VGA of QEMU: what the root
// service and the compositor need to show one screen page or the other
// (src/md/infrastructure/whole_frame.md).
//
// The q35 machine of QEMU has its standard VGA at the place 1 of bus 0. Its
// base address register 0 is its video memory; the framebuffer of the
// firmware is its start. Its base address register 2 holds the display
// registers, 16-bit words, at DISPLAY_REGISTERS_OFFSET. The firmware sets the
// mode with them before the boot program runs.
//
// The register Offset_Y names the first line of the video memory that the
// display shows. A screen page is one screen in the video memory: the page n
// starts at the line n times the height of the screen. A write of Offset_Y is
// a page flip. QEMU sets the offset to 0 when the page does not fit in the
// video memory, so a reader of the register knows if the flip took.
//
// The procedures take the address of the display registers, where the
// caller mapped them: the first register, Identity, is there. A host test
// gives plain memory.
//
// See [screen page](term:screen-page) and [page flip](term:page-flip).
package bochs_display

import "base:intrinsics"

// The standard VGA of QEMU on the bus.
VENDOR :: 0x1234
DEVICE :: 0x1111
PLACE_DEVICE :: 0x01 // Its place on bus 0 in the q35 machine of QEMU.
VIDEO_MEMORY_BAR :: 0 // The base address register of the video memory.
REGISTERS_BAR :: 2 // The base address register of the registers of the VGA.
DISPLAY_REGISTERS_OFFSET :: 0x500 // The display registers of Bochs in the memory of REGISTERS_BAR.

// A display register: its number. Register n is the 16-bit word at the
// byte 2 n.
Register :: enum u32 {
	Identity       = 0, // IDENTITY_FIRST to IDENTITY_LAST: the version of the interface.
	Width          = 1, // The screen, in pixels.
	Height         = 2, // The screen, in lines.
	Bits_Per_Pixel = 3,
	Enable         = 4, // ENABLED and LINEAR_FRAMEBUFFER while the mode of the firmware holds.
	Bank           = 5,
	Virtual_Width  = 6, // The pixels of a line of the video memory.
	Virtual_Height = 7, // The lines that the video memory holds: QEMU computes it from its size.
	Offset_X       = 8, // The first pixel of a line that the display shows.
	Offset_Y       = 9, // The first line that the display shows: the start of the shown screen page.
	Video_Memory_Blocks = 10, // The size of the video memory, in VIDEO_MEMORY_BLOCK. Read only.
}

VIDEO_MEMORY_BLOCK :: 64 * 1024 // The unit of Video_Memory_Blocks, in bytes.

IDENTITY_FIRST :: 0xB0C0
IDENTITY_LAST :: 0xB0C5
ENABLED :: 0x01
LINEAR_FRAMEBUFFER :: 0x40
BITS_PER_PIXEL :: 32 // The one format that the system draws.
PAGE_COUNT :: 2 // The screen pages that the compositor flips between.

// read gives a display register.
read :: proc "contextless" (registers: rawptr, register: Register) -> u16 {
	return intrinsics.volatile_load(&([^]u16)(registers)[u32(register)])
}

// write writes a display register. On the device, the write takes effect
// when it returns.
write :: proc "contextless" (registers: rawptr, register: Register, value: u16) {
	intrinsics.volatile_store(&([^]u16)(registers)[u32(register)], value)
}

// screen_pages gives the count of whole screen pages that the display
// shows with Offset_Y alone: PAGE_COUNT when the registers say the mode of
// the screen that the firmware gave, the display shows the page 0, and the
// video memory holds PAGE_COUNT screens, else 1. width, height and
// pixels_per_line are the framebuffer of the firmware. A page of another
// layout would show a part of two screens, so each fact is checked. The
// size of the video memory comes from the registers, not from a size of
// its base address register, which would turn the screen off
// (src/md/infrastructure/whole_frame.md): Video_Memory_Blocks and
// Virtual_Height must each hold the pages.
screen_pages :: proc "contextless" (registers: rawptr, width, height, pixels_per_line: u64) -> int {
	identity := read(registers, .Identity)
	enable := read(registers, .Enable)
	switch {
	case identity < IDENTITY_FIRST || identity > IDENTITY_LAST:
		return 1
	case enable & (ENABLED | LINEAR_FRAMEBUFFER) != ENABLED | LINEAR_FRAMEBUFFER:
		return 1
	case u64(read(registers, .Bits_Per_Pixel)) != BITS_PER_PIXEL:
		return 1
	case u64(read(registers, .Width)) != width || u64(read(registers, .Height)) != height:
		return 1
	case u64(read(registers, .Virtual_Width)) != pixels_per_line || read(registers, .Offset_X) != 0:
		return 1
	case read(registers, .Offset_Y) != 0:
		// The display must show the page 0, the framebuffer of the
		// firmware: the caller takes it as the shown page, and writes the
		// other one first.
		return 1
	case height == 0 || u64(read(registers, .Virtual_Height)) < PAGE_COUNT * height:
		return 1
	case u64(read(registers, .Video_Memory_Blocks)) * VIDEO_MEMORY_BLOCK < PAGE_COUNT * height * pixels_per_line * BITS_PER_PIXEL / 8:
		return 1
	}
	return PAGE_COUNT
}

// page_show makes the display show the screen page `page`, and says if the
// device took it: QEMU sets the offset to 0 for a page past its video
// memory, and reads it back so.
page_show :: proc "contextless" (registers: rawptr, page: int, height: int) -> bool {
	// Each write of a pixel of the page reaches the device before the
	// display shows the page: a volatile store orders no other store, and
	// a memory type that is not "no cache" can keep the pixels in the
	// processor.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	line := u16(page * height)
	write(registers, .Offset_Y, line)
	return read(registers, .Offset_Y) == line
}
