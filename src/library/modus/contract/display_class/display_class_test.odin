#+build !freestanding
#+build !modus
package display_class

import "core:testing"

@(private = "file")
valid_1080p :: proc() -> Display_Mode {
	return Display_Mode {
		width        = 1920,
		height       = 1080,
		refresh_mhz  = 120_000,
		stride_bytes = 1920 * 4,
		format       = .Blue_Green_Red_X_8888,
	}
}

@(test)
display_mode_validate_refuses_every_border_fault :: proc(t: ^testing.T) {
	// Zero dimensions.
	m := valid_1080p()
	m.width = 0
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Zero_Dimension)
	m = valid_1080p()
	m.height = 0
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Zero_Dimension)

	// Past DISPLAY_MAX_DIMENSION.
	m = valid_1080p()
	m.width = DISPLAY_MAX_DIMENSION + 1
	m.stride_bytes = m.width * 4
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Dimension_Too_Large)
	m = valid_1080p()
	m.height = DISPLAY_MAX_DIMENSION + 1
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Dimension_Too_Large)

	// Unknown pixel format enum words.
	for bad_word in ([]u64{0, 6, 255, max(u64)}) {
		_, ok := display_pixel_format_of_word(bad_word)
		testing.expect(t, !ok)
	}
	for bad_fmt in ([]u8{0, 6, 255}) {
		m = valid_1080p()
		m.format = Display_Pixel_Format(bad_fmt)
		testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Unknown_Pixel_Format)
		testing.expect_value(t, display_pixel_format_bytes_per_pixel(m.format), u32(0))
	}

	// Stride too small and stride unaligned.
	m = valid_1080p()
	m.stride_bytes = m.width * 4 - 4
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Stride_Too_Small)
	m.stride_bytes = 0
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Stride_Too_Small)
	m.stride_bytes = m.width * 4 + 1
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Stride_Unaligned)
	m.stride_bytes = m.width * 4 + 2
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Stride_Unaligned)

	// Refresh rate bounds.
	for bad_hz in ([]u32{0, 1, DISPLAY_REFRESH_MIN_MHZ - 1, DISPLAY_REFRESH_MAX_MHZ + 1, max(u32)}) {
		m = valid_1080p()
		m.refresh_mhz = bad_hz
		testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Invalid_Refresh_Rate)
	}

	// Framebuffer size overflow past max(u32).
	m = valid_1080p()
	m.height = DISPLAY_MAX_DIMENSION
	m.stride_bytes = 0x100000 // 1 MiB * 16384 > 4 GiB
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.Arithmetic_Overflow)

	// Valid mode passes, including padded aligned stride.
	m = valid_1080p()
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.None)
	m.stride_bytes = m.width * 4 + 256
	testing.expect_value(t, display_mode_validate(m), Display_Class_Refusal.None)
}

@(test)
display_scale_and_logical_size_refuse_invalid_and_compute_exact :: proc(t: ^testing.T) {
	// Out-of-range scales.
	for bad in ([]u16{0, 50, 75, 99, 401, 425, 1000, max(u16)}) {
		testing.expect_value(t, display_scale_validate({percent = bad}), Display_Class_Refusal.Scale_Out_Of_Range)
	}
	// Non-quarter-step scales within 100..400.
	for bad in ([]u16{101, 110, 124, 126, 133, 151, 199, 251, 399}) {
		testing.expect_value(t, display_scale_validate({percent = bad}), Display_Class_Refusal.Scale_Invalid_Step)
	}
	// Every valid quarter-step passes.
	for p: u16 = DISPLAY_SCALE_MIN_PERCENT; p <= DISPLAY_SCALE_MAX_PERCENT; p += DISPLAY_SCALE_STEP_PERCENT {
		testing.expect_value(t, display_scale_validate({percent = p}), Display_Class_Refusal.None)
	}

	// Logical size too small: 640x480 at 400% -> 160x120 < 320x240.
	small_mode := Display_Mode {
		width        = 640,
		height       = 480,
		refresh_mhz  = 60_000,
		stride_bytes = 640 * 4,
		format       = .Red_Green_Blue_X_8888,
	}
	_, refusal := display_logical_size_of_mode(small_mode, {percent = 400})
	testing.expect_value(t, refusal, Display_Class_Refusal.Logical_Too_Small)

	// Exact reference screen calculations: 1920x1080 at 100%, 125%, 150%, 200%.
	mode_1080 := valid_1080p()
	cases := [?]struct {
		percent: u16,
		w, h:    u32,
	}{
		{100, 1920, 1080},
		{125, 1536, 864},
		{150, 1280, 720},
		{200, 960, 540},
		{300, 640, 360},
		{400, 480, 270},
	}
	for c in cases {
		logical, r := display_logical_size_of_mode(mode_1080, {percent = c.percent})
		testing.expect_value(t, r, Display_Class_Refusal.None)
		testing.expect_value(t, logical.width, c.w)
		testing.expect_value(t, logical.height, c.h)
	}
}

@(test)
display_mode_table_and_resize_transitions_preserve_state_on_refusal :: proc(t: ^testing.T) {
	table: Display_Mode_Table
	// Empty table refuses selection.
	_, refusal := display_select_mode_and_scale(&table, 0, {percent = 100})
	testing.expect_value(t, refusal, Display_Class_Refusal.Empty_Mode_Table)

	// Invalid mode leaves count at 0.
	bad := valid_1080p()
	bad.width = 0
	testing.expect_value(t, display_mode_table_add(&table, bad), Display_Class_Refusal.Zero_Dimension)
	testing.expect_value(t, table.count, 0)

	// Add 1080p and 4K modes; refuse duplicate.
	mode_1080 := valid_1080p()
	mode_4k := Display_Mode {
		width        = 3840,
		height       = 2160,
		refresh_mhz  = 60_000,
		stride_bytes = 3840 * 4,
		format       = .Red_Green_Blue_1010102,
	}
	testing.expect_value(t, display_mode_table_add(&table, mode_1080), Display_Class_Refusal.None)
	testing.expect_value(t, display_mode_table_add(&table, mode_1080), Display_Class_Refusal.Duplicate_Mode)
	testing.expect_value(t, display_mode_table_add(&table, mode_4k), Display_Class_Refusal.None)
	testing.expect_value(t, table.count, 2)

	// Resize state transitions: initial valid apply -> serial 1.
	state: Display_Resize_State
	testing.expect_value(t, display_resize_apply(&state, &table, 0, {percent = 125}), Display_Class_Refusal.None)
	testing.expect(t, state.initialized)
	testing.expect_value(t, state.serial, u64(1))
	testing.expect_value(t, state.active.logical.width, u32(1536))
	testing.expect_value(t, state.active.logical.height, u32(864))

	// Refused resize transitions must NOT mutate active selection or serial.
	before := state
	testing.expect_value(t, display_resize_apply(&state, &table, -1, {percent = 100}), Display_Class_Refusal.Mode_Index_Out_Of_Range)
	testing.expect_value(t, state, before)
	testing.expect_value(t, display_resize_apply(&state, &table, 2, {percent = 100}), Display_Class_Refusal.Mode_Index_Out_Of_Range)
	testing.expect_value(t, state, before)
	testing.expect_value(t, display_resize_apply(&state, &table, 1, {percent = 133}), Display_Class_Refusal.Scale_Invalid_Step)
	testing.expect_value(t, state, before)

	// Valid transition to 4K at 200% -> 1920x1080 logical, serial 2.
	testing.expect_value(t, display_resize_apply(&state, &table, 1, {percent = 200}), Display_Class_Refusal.None)
	testing.expect_value(t, state.serial, u64(2))
	testing.expect_value(t, state.active.mode_index, 1)
	testing.expect_value(t, state.active.logical.width, u32(1920))
	testing.expect_value(t, state.active.logical.height, u32(1080))

	// Fill table up to DISPLAY_MODE_TABLE_CAPACITY and refuse one past capacity.
	for i in 2 ..< DISPLAY_MODE_TABLE_CAPACITY {
		extra := mode_1080
		extra.refresh_mhz = u32(60_000 + i * 1_000)
		testing.expect_value(t, display_mode_table_add(&table, extra), Display_Class_Refusal.None)
	}
	overflow := mode_1080
	overflow.refresh_mhz = 240_000
	testing.expect_value(t, display_mode_table_add(&table, overflow), Display_Class_Refusal.Mode_Table_Full)
	testing.expect_value(t, table.count, DISPLAY_MODE_TABLE_CAPACITY)
}
