package boot_info

import "modus:contract/enum_word"

// Browser machine live viewport resize control page (src/md/features/browser_machine.md).
//
// Placed in one trailing 4 KiB page right after BROWSER_RESIZE_MAX_BYTES of the
// browser machine framebuffer memory object. On real hardware and QEMU, no such
// magic page exists and the compositor ignores it completely.

// Format property: maximum live browser machine viewport size (1920x1200x32-bit
// BGRA = 9,216,000 bytes = 2250 4 KiB pages) plus one trailing control page.
BROWSER_RESIZE_MAX_WIDTH :: 1920
BROWSER_RESIZE_MAX_HEIGHT :: 1200
BROWSER_RESIZE_MIN_WIDTH :: 640
BROWSER_RESIZE_MIN_HEIGHT :: 400
BROWSER_RESIZE_MAX_BYTES :: BROWSER_RESIZE_MAX_WIDTH * BROWSER_RESIZE_MAX_HEIGHT * 4
BROWSER_RESIZE_MAX_PAGES :: BROWSER_RESIZE_MAX_BYTES / 4096
BROWSER_RESIZE_TOTAL_PAGES :: BROWSER_RESIZE_MAX_PAGES + 1

// Format property: little-endian ASCII "MODVRES1" magic identifying the live
// browser viewport resize control page.
BROWSER_RESIZE_MAGIC :: u64(0x3153_4552_5644_4F4D)

// Closed set of keyboard layout hints published by the browser host in
// Browser_Resize_Page. Values cross the shared control page, so they are
// explicit; browser_keyboard_layout_hint_of_word is their single border.
Browser_Keyboard_Layout_Hint :: enum u32 {
	None          = 0,
	United_States = 1,
	French        = 2,
}

// browser_keyboard_layout_hint_of_word converts the raw word from the browser
// control page into its enum member and refuses unknown values.
browser_keyboard_layout_hint_of_word :: proc "contextless" (word: u32) -> (hint: Browser_Keyboard_Layout_Hint, ok: bool) {
	return enum_word.member_of_word(Browser_Keyboard_Layout_Hint, u64(word))
}

Browser_Resize_Page :: struct {
	magic:                u64, // 0:  BROWSER_RESIZE_MAGIC ("MODVRES1").
	max_width:            u32, // 8:  Maximum pixel width backed by the framebuffer.
	max_height:           u32, // 12: Maximum pixel height backed by the framebuffer.
	req_width:            u32, // 16: Requested viewport width from the browser host.
	req_height:           u32, // 20: Requested viewport height from the browser host.
	req_seq:              u32, // 24: Monotonic sequence incremented by the browser host.
	ack_width:            u32, // 28: Active compositor width after full redraw.
	ack_height:           u32, // 32: Active compositor height after full redraw.
	ack_seq:              u32, // 36: Sequence written with .Release after screen.pixels is painted.
	frame_seq:            u32, // 40: Monotonic frame counter written with .Release after every draw().
	dirty_x:              u32, // 44: Left X of the bounding box painted in this frame.
	dirty_y:              u32, // 48: Top Y of the bounding box painted in this frame.
	dirty_w:              u32, // 52: Width of the bounding box painted in this frame.
	dirty_h:              u32, // 56: Height of the bounding box painted in this frame.
	desktop_width:        u32, // 60: Active compositor logical desktop width (for 1:1 pointer mapping).
	desktop_height:       u32, // 64: Active compositor logical desktop height (for 1:1 pointer mapping).
	keyboard_layout_hint: u32, // 68: Browser_Keyboard_Layout_Hint word written by the browser host.
	keyboard_layout_seq:  u32, // 72: Monotonic sequence written with .Release when keyboard_layout_hint updates.
}

#assert(size_of(Browser_Resize_Page) == 80)
#assert(offset_of(Browser_Resize_Page, magic) == 0)
#assert(offset_of(Browser_Resize_Page, max_width) == 8)
#assert(offset_of(Browser_Resize_Page, max_height) == 12)
#assert(offset_of(Browser_Resize_Page, req_width) == 16)
#assert(offset_of(Browser_Resize_Page, req_height) == 20)
#assert(offset_of(Browser_Resize_Page, req_seq) == 24)
#assert(offset_of(Browser_Resize_Page, ack_width) == 28)
#assert(offset_of(Browser_Resize_Page, ack_height) == 32)
#assert(offset_of(Browser_Resize_Page, ack_seq) == 36)
#assert(offset_of(Browser_Resize_Page, frame_seq) == 40)
#assert(offset_of(Browser_Resize_Page, dirty_x) == 44)
#assert(offset_of(Browser_Resize_Page, dirty_y) == 48)
#assert(offset_of(Browser_Resize_Page, dirty_w) == 52)
#assert(offset_of(Browser_Resize_Page, dirty_h) == 56)
#assert(offset_of(Browser_Resize_Page, desktop_width) == 60)
#assert(offset_of(Browser_Resize_Page, desktop_height) == 64)
#assert(offset_of(Browser_Resize_Page, keyboard_layout_hint) == 68)
#assert(offset_of(Browser_Resize_Page, keyboard_layout_seq) == 72)
