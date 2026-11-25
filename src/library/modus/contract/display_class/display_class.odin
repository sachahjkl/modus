// Display class protocol and mode/scale selection contract
// (src/md/features/device_services.md and src/md/features/desktop_to_browser.md).
//
// Pure freestanding validation and mode/scale selection for display class
// device services and the compositor. Every procedure is contextless, performs
// checked arithmetic, converts enum words at the border, and leaves caller
// state untouched on any refusal.
package display_class

import "modus:contract/enum_word"

// Format property: 16K scanout bound keeps row stride (<= 65536 bytes) and
// total 32-bit RGBA framebuffer size (<= 1 GiB) within checked u32/u64 math.
DISPLAY_MAX_DIMENSION :: u32(16384)

// Format property: physical display refresh envelope in millihertz (1 Hz to 1000 Hz).
DISPLAY_REFRESH_MIN_MHZ :: u32(1_000)
DISPLAY_REFRESH_MAX_MHZ :: u32(1_000_000)

// Plan value: smallest usable logical workspace so the bar and settings window
// remain reachable at any selected resolution and scale.
DISPLAY_MIN_LOGICAL_WIDTH :: u32(320)
DISPLAY_MIN_LOGICAL_HEIGHT :: u32(240)

// Plan value: integer/quarter-step scale percentages from 100% to 400%.
DISPLAY_SCALE_MIN_PERCENT :: u16(100)
DISPLAY_SCALE_MAX_PERCENT :: u16(400)
DISPLAY_SCALE_STEP_PERCENT :: u16(25)

// Inline capacity: common EDID and virtual GPU mode lists carry up to 16 modes;
// 32 entries hold full multi-refresh tables without heap allocation.
DISPLAY_MODE_TABLE_CAPACITY :: 32

// Closed refusal set returned by every display class contract procedure.
Display_Class_Refusal :: enum u8 {
	None                    = 0,
	Zero_Dimension          = 1,
	Dimension_Too_Large     = 2,
	Unknown_Pixel_Format    = 3,
	Stride_Too_Small        = 4,
	Stride_Unaligned        = 5,
	Invalid_Refresh_Rate    = 6,
	Scale_Out_Of_Range      = 7,
	Scale_Invalid_Step      = 8,
	Empty_Mode_Table        = 9,
	Mode_Table_Full         = 10,
	Mode_Index_Out_Of_Range = 11,
	Duplicate_Mode          = 12,
	Logical_Too_Small       = 13,
	Arithmetic_Overflow     = 14,
}

// Closed scanout pixel formats crossing the display class border.
Display_Pixel_Format :: enum u8 {
	Blue_Green_Red_X_8888  = 1,
	Red_Green_Blue_X_8888  = 2,
	Blue_Green_Red_A_8888  = 3,
	Red_Green_Blue_A_8888  = 4,
	Red_Green_Blue_1010102 = 5,
}

// One physical scanout mode exposed by a display device service.
Display_Mode :: struct {
	width:        u32,
	height:       u32,
	refresh_mhz:  u32,
	stride_bytes: u32,
	format:       Display_Pixel_Format,
}

// Quarter-step scale factor in percent (100..=400 in steps of 25).
Display_Scale :: struct {
	percent: u16,
}

// Fixed-capacity table of validated display modes advertised by one output.
Display_Mode_Table :: struct {
	modes: [DISPLAY_MODE_TABLE_CAPACITY]Display_Mode,
	count: int,
}

// Logical workspace dimensions derived from a physical mode and scale factor.
Display_Logical_Size :: struct {
	width:  u32,
	height: u32,
}

// A validated pair of mode and scale together with its computed logical size.
Display_Selection :: struct {
	mode_index: int,
	mode:       Display_Mode,
	scale:      Display_Scale,
	logical:    Display_Logical_Size,
}

// Active display mode/scale state tracking monotonic resize generations.
Display_Resize_State :: struct {
	active:      Display_Selection,
	serial:      u64,
	initialized: bool,
}

// display_pixel_format_of_word converts a wire word at the contract border.
display_pixel_format_of_word :: proc "contextless" (word: u64) -> (format: Display_Pixel_Format, ok: bool) {
	return enum_word.member_of_word(Display_Pixel_Format, word)
}

// display_pixel_format_bytes_per_pixel gives the exact byte width of one pixel
// for a validated format, or 0 for an invalid enum word.
display_pixel_format_bytes_per_pixel :: proc "contextless" (format: Display_Pixel_Format) -> u32 {
	checked, ok := enum_word.member_of_word(Display_Pixel_Format, u64(format))
	if !ok {
		return 0
	}
	switch checked {
	case .Blue_Green_Red_X_8888, .Red_Green_Blue_X_8888, .Blue_Green_Red_A_8888, .Red_Green_Blue_A_8888, .Red_Green_Blue_1010102:
		return 4
	}
	return 0
}

// display_scale_validate verifies that scale is within 100..=400 percent on a
// 25-percent quarter step.
display_scale_validate :: proc "contextless" (scale: Display_Scale) -> Display_Class_Refusal {
	if scale.percent < DISPLAY_SCALE_MIN_PERCENT || scale.percent > DISPLAY_SCALE_MAX_PERCENT {
		return .Scale_Out_Of_Range
	}
	if (scale.percent - DISPLAY_SCALE_MIN_PERCENT) % DISPLAY_SCALE_STEP_PERCENT != 0 {
		return .Scale_Invalid_Step
	}
	return .None
}

// display_mode_validate checks dimensions, pixel format, refresh rate, row
// stride alignment, and framebuffer byte-size overflow.
display_mode_validate :: proc "contextless" (mode: Display_Mode) -> Display_Class_Refusal {
	if mode.width == 0 || mode.height == 0 {
		return .Zero_Dimension
	}
	if mode.width > DISPLAY_MAX_DIMENSION || mode.height > DISPLAY_MAX_DIMENSION {
		return .Dimension_Too_Large
	}
	bpp := display_pixel_format_bytes_per_pixel(mode.format)
	if bpp == 0 {
		return .Unknown_Pixel_Format
	}
	if mode.refresh_mhz < DISPLAY_REFRESH_MIN_MHZ || mode.refresh_mhz > DISPLAY_REFRESH_MAX_MHZ {
		return .Invalid_Refresh_Rate
	}
	row_bytes := u64(mode.width) * u64(bpp)
	if u64(mode.stride_bytes) < row_bytes {
		return .Stride_Too_Small
	}
	if mode.stride_bytes % bpp != 0 {
		return .Stride_Unaligned
	}
	total_bytes := u64(mode.stride_bytes) * u64(mode.height)
	if total_bytes > u64(max(u32)) {
		return .Arithmetic_Overflow
	}
	return .None
}

// display_mode_equal reports whether two modes describe the exact same scanout
// geometry, refresh rate, stride, and pixel format.
display_mode_equal :: proc "contextless" (a, b: Display_Mode) -> bool {
	return a.width == b.width &&
		a.height == b.height &&
		a.refresh_mhz == b.refresh_mhz &&
		a.stride_bytes == b.stride_bytes &&
		a.format == b.format
}

// display_mode_table_add appends a validated unique mode to table. A refusal
// leaves table unchanged.
display_mode_table_add :: proc "contextless" (table: ^Display_Mode_Table, mode: Display_Mode) -> Display_Class_Refusal {
	if table == nil || table.count < 0 || table.count > DISPLAY_MODE_TABLE_CAPACITY {
		return .Mode_Index_Out_Of_Range
	}
	if refusal := display_mode_validate(mode); refusal != .None {
		return refusal
	}
	for index in 0 ..< table.count {
		if display_mode_equal(table.modes[index], mode) {
			return .Duplicate_Mode
		}
	}
	if table.count >= DISPLAY_MODE_TABLE_CAPACITY {
		return .Mode_Table_Full
	}
	table.modes[table.count] = mode
	table.count += 1
	return .None
}

// display_logical_size_of_mode computes the logical workspace dimensions for
// mode at scale using rounded half-up checked u64 arithmetic, refusing any
// logical screen smaller than DISPLAY_MIN_LOGICAL_WIDTH x DISPLAY_MIN_LOGICAL_HEIGHT.
display_logical_size_of_mode :: proc "contextless" (mode: Display_Mode, scale: Display_Scale) -> (size: Display_Logical_Size, refusal: Display_Class_Refusal) {
	if mode_refusal := display_mode_validate(mode); mode_refusal != .None {
		return {}, mode_refusal
	}
	if scale_refusal := display_scale_validate(scale); scale_refusal != .None {
		return {}, scale_refusal
	}
	percent := u64(scale.percent)
	half := percent / 2
	logical_w := (u64(mode.width) * 100 + half) / percent
	logical_h := (u64(mode.height) * 100 + half) / percent
	if logical_w > u64(max(u32)) || logical_h > u64(max(u32)) {
		return {}, .Arithmetic_Overflow
	}
	if u32(logical_w) < DISPLAY_MIN_LOGICAL_WIDTH || u32(logical_h) < DISPLAY_MIN_LOGICAL_HEIGHT {
		return {}, .Logical_Too_Small
	}
	return Display_Logical_Size{width = u32(logical_w), height = u32(logical_h)}, .None
}

// display_select_mode_and_scale validates table[mode_index] and scale and
// returns the complete selection without mutating any caller state.
display_select_mode_and_scale :: proc "contextless" (
	table: ^Display_Mode_Table,
	mode_index: int,
	scale: Display_Scale,
) -> (
	selection: Display_Selection,
	refusal: Display_Class_Refusal,
) {
	if table == nil || table.count <= 0 || table.count > DISPLAY_MODE_TABLE_CAPACITY {
		return {}, .Empty_Mode_Table
	}
	if mode_index < 0 || mode_index >= table.count {
		return {}, .Mode_Index_Out_Of_Range
	}
	mode := table.modes[mode_index]
	logical, logical_refusal := display_logical_size_of_mode(mode, scale)
	if logical_refusal != .None {
		return {}, logical_refusal
	}
	return Display_Selection {
		mode_index = mode_index,
		mode       = mode,
		scale      = scale,
		logical    = logical,
	}, .None
}

// display_resize_apply transitions state to the validated mode and scale and
// increments state.serial. On any refusal, state is not modified.
display_resize_apply :: proc "contextless" (
	state: ^Display_Resize_State,
	table: ^Display_Mode_Table,
	mode_index: int,
	scale: Display_Scale,
) -> Display_Class_Refusal {
	if state == nil {
		return .Mode_Index_Out_Of_Range
	}
	selection, refusal := display_select_mode_and_scale(table, mode_index, scale)
	if refusal != .None {
		return refusal
	}
	if state.serial == max(u64) {
		return .Arithmetic_Overflow
	}
	state.active = selection
	state.serial += 1
	state.initialized = true
	return .None
}
