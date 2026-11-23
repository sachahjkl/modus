#+build !freestanding
package bar

import "core:testing"
import "modus:contract/scale_factor"
import "modus:contract/settings"

// A page that the read refuses keeps the scale in force: the all-zero page,
// a page whose writer is in its change (an odd count), and a page whose
// scale word is one past the range. Each gives its defaults, 1.25 for
// the scale among them, and the desktop at 1.375 stays at 1.375. The page
// that the read takes comes last.
@(test)
a_refused_page_keeps_the_scale :: proc(t: ^testing.T) {
	in_force := scale_factor.Scale.Eleven_Eighths
	page: settings.Page
	choice, read_ok := settings.read(&page)
	testing.expect(t, !read_ok)
	testing.expect_value(t, scale_after_read(in_force, choice.scale, read_ok), in_force)

	written := settings.choice_default()
	settings.write(&page, written, 0, .Dark)
	page.change_count += 1 // A writer left in its change.
	choice, read_ok = settings.read(&page)
	testing.expect(t, !read_ok)
	testing.expect_value(t, scale_after_read(in_force, choice.scale, read_ok), in_force)

	page = {}
	settings.write(&page, written, 0, .Dark)
	page.values[settings.Setting.Scale] = u32(max(scale_factor.Scale)) + 1
	choice, read_ok = settings.read(&page)
	testing.expect(t, !read_ok)
	testing.expect_value(t, scale_after_read(in_force, choice.scale, read_ok), in_force)

	page = {}
	settings.write(&page, written, 0, .Dark)
	choice, read_ok = settings.read(&page)
	testing.expect(t, read_ok)
	testing.expect_value(t, scale_after_read(in_force, choice.scale, read_ok), scale_factor.DEFAULT)
}

@(private = "file")
BORDER_OF_TEST :: 2
@(private = "file")
TITLE_OF_TEST :: 24
@(private = "file")
PAGE_OF_TEST :: 4096

// A Surface_Create that the compositor takes: a window of 560 x 592
// logical pixels at 1.25, 700 x 740 pixels of the screen.
@(private = "file")
create_of_test :: proc() -> Surface_Create_Facts {
	return {is_memory = true, readable = true, memory_bytes = 700 * 740 * SURFACE_BYTES_FOR_EACH_PIXEL, scale_word = u64(scale_factor.Scale.Ten_Eighths), width = 560, height = 592}
}

// The sizes of Surface_Create. Each refusal first: no memory, no Read, a
// logical side of 0, one past the limit, 4096 and the largest word; a scale
// word of no member: 0, 7 and 17; memory one byte short
// of the pixels at the scale of the record. Then the edges that hold: 1 x 1,
// and the limit at each scale of the range, whose pixels of the screen
// are 2048 at 1, 2560 at 1.25, 2816 at 1.375 and 4096 at 2.
@(test)
surface_create_refusal_refuses_each_broken_rule :: proc(t: ^testing.T) {
	Case :: struct {
		facts:   Surface_Create_Facts,
		refusal: Surface_Create_Refusal,
	}
	cases: [12]Case
	for &each in cases {
		each.facts = create_of_test()
	}
	cases[0].facts.is_memory, cases[0].refusal = false, .Not_Memory
	cases[1].facts.readable, cases[1].refusal = false, .No_Read
	cases[2].facts.width, cases[2].refusal = 0, .Size_Out_Of_Range
	cases[3].facts.height, cases[3].refusal = 0, .Size_Out_Of_Range
	cases[4].facts.width, cases[4].refusal = WINDOW_LOGICAL_LIMIT + 1, .Size_Out_Of_Range
	cases[5].facts.height, cases[5].refusal = 4096, .Size_Out_Of_Range
	cases[6].facts.width, cases[6].refusal = max(u64), .Size_Out_Of_Range
	cases[7].facts.scale_word, cases[7].refusal = 0, .No_Scale
	cases[8].facts.scale_word, cases[8].refusal = scale_factor.EIGHTHS_OF_ONE - 1, .No_Scale
	cases[9].facts.scale_word, cases[9].refusal = u64(max(scale_factor.Scale)) + 1, .No_Scale
	cases[10].facts.scale_word, cases[10].refusal = max(u64), .No_Scale
	cases[11].facts.memory_bytes, cases[11].refusal = 700 * 740 * SURFACE_BYTES_FOR_EACH_PIXEL - 1, .Too_Small
	for each, index in cases {
		refusal, _, screen_width, screen_height := surface_create_refusal(each.facts)
		testing.expectf(t, refusal == each.refusal, "case %d gives %v, not %v", index, refusal, each.refusal)
		testing.expectf(t, screen_width == 0 && screen_height == 0, "case %d gives a size", index)
	}
	// The memory of the pixels at 1.25 does not hold the pixels at 1.375.
	facts := create_of_test()
	facts.scale_word = u64(scale_factor.Scale.Eleven_Eighths)
	refusal, _, _, _ := surface_create_refusal(facts)
	testing.expect_value(t, refusal, Surface_Create_Refusal.Too_Small)

	facts = create_of_test()
	scale: scale_factor.Scale
	screen_width, screen_height: u64
	refusal, scale, screen_width, screen_height = surface_create_refusal(facts)
	testing.expect(t, refusal == .None && scale == .Ten_Eighths && screen_width == 700 && screen_height == 740)
	facts.width, facts.height, facts.memory_bytes = 1, 1, SURFACE_BYTES_FOR_EACH_PIXEL
	refusal, _, screen_width, screen_height = surface_create_refusal(facts)
	testing.expect(t, refusal == .None && screen_width == 1 && screen_height == 1)
	for limit in ([?][2]u64{{u64(scale_factor.Scale.Eight_Eighths), 2048}, {u64(scale_factor.Scale.Ten_Eighths), 2560}, {u64(scale_factor.Scale.Eleven_Eighths), 2816}, {u64(scale_factor.Scale.Sixteen_Eighths), 4096}}) {
		facts = {is_memory = true, readable = true, memory_bytes = limit[1] * limit[1] * SURFACE_BYTES_FOR_EACH_PIXEL, scale_word = limit[0], width = WINDOW_LOGICAL_LIMIT, height = WINDOW_LOGICAL_LIMIT}
		refusal, _, screen_width, screen_height = surface_create_refusal(facts)
		testing.expectf(t, refusal == .None && screen_width == limit[1] && screen_height == limit[1], "the limit at %d eighths gives %v, %d", limit[0], refusal, screen_width)
	}
}

// Each logical size up to the limit, at each scale of the range, gives
// pixels of the screen that give it back: the compositor keeps the logical
// size of the record and the pixels of the rule, so a surface never has
// pixels that no logical size gives (1252 at 1.25 is one: 1001 gives 1251,
// 1002 gives 1253).
@(test)
each_logical_size_gives_its_pixels_back :: proc(t: ^testing.T) {
	for scale in scale_factor.Scale {
		for logical in i32(1) ..= WINDOW_LOGICAL_LIMIT {
			pixels := scale_factor.screen_pixel_of_logical_pixel(logical, scale)
			back := scale_factor.logical_pixel_of_screen_pixel(i32(pixels), scale)
			if back != i64(logical) {
				testing.expectf(t, false, "%d at %v gives %d pixels, which give %d", logical, scale, pixels, back)
				return
			}
		}
	}
	testing.expect_value(t, scale_factor.screen_pixel_of_logical_pixel(1001, .Ten_Eighths), 1251)
	testing.expect_value(t, scale_factor.screen_pixel_of_logical_pixel(1002, .Ten_Eighths), 1253)
}

// A Surface_Rescale that the compositor takes: a window of 1000 x 704
// logical pixels, released at the serial 4, offers the serial 5 at 1.375,
// 1375 x 968 pixels of the screen.
@(private = "file")
rescale_of_test :: proc() -> Surface_Rescale_Facts {
	return {
		gift            = true,
		is_memory       = true,
		readable        = true,
		memory_bytes    = 1375 * 968 * SURFACE_BYTES_FOR_EACH_PIXEL,
		width           = 1375,
		height          = 968,
		scale_word      = u64(scale_factor.Scale.Eleven_Eighths),
		serial          = 5,
		created         = true,
		released        = true,
		released_serial = 4,
		scale           = .Eleven_Eighths,
		window_width    = 1000,
		window_height   = 704,
	}
}

// The refusals of Surface_Rescale. Each refusal first: a size one pixel
// off on each axis, each way; memory one page short and one byte short;
// no Read; a handle that is no gift; no memory; a request of the principal
// that waits; a surface that waits for its Present; a window that still
// shows its surface; a window before Surface_Create; a serial that is not
// the next one; a scale word of no member, past the bound, or not the scale
// of the compositor. The procedure is pure: a refusal changes nothing, and
// the compositor answers Rescale_Refused. The case that holds comes last.
@(test)
surface_rescale_refusal_refuses_each_broken_rule :: proc(t: ^testing.T) {
	Case :: struct {
		facts:   Surface_Rescale_Facts,
		refusal: Surface_Rescale_Refusal,
	}
	cases: [22]Case
	for &each in cases {
		each.facts = rescale_of_test()
	}
	cases[0].facts.width, cases[0].refusal = 1374, .Other_Size
	cases[1].facts.width, cases[1].refusal = 1376, .Other_Size
	cases[2].facts.height, cases[2].refusal = 967, .Other_Size
	cases[3].facts.height, cases[3].refusal = 969, .Other_Size
	cases[4].facts.width, cases[4].refusal = 0, .Other_Size
	cases[5].facts.memory_bytes, cases[5].refusal = 1375 * 968 * SURFACE_BYTES_FOR_EACH_PIXEL - PAGE_OF_TEST, .Too_Small
	cases[6].facts.memory_bytes, cases[6].refusal = 1375 * 968 * SURFACE_BYTES_FOR_EACH_PIXEL - 1, .Too_Small
	cases[7].facts.readable, cases[7].refusal = false, .No_Read
	cases[8].facts.gift, cases[8].refusal = false, .Not_A_Gift
	cases[9].facts.is_memory, cases[9].refusal = false, .Not_Memory
	cases[10].facts.asked, cases[10].refusal = true, .Asked
	cases[11].facts.pending, cases[11].refusal = true, .Pending
	cases[12].facts.released, cases[12].refusal = false, .Not_Released
	cases[13].facts.created, cases[13].refusal = false, .No_Window
	cases[14].facts.serial, cases[14].refusal = 4, .Other_Serial
	cases[15].facts.serial, cases[15].refusal = 6, .Other_Serial
	cases[16].facts.serial, cases[16].refusal = 0, .Other_Serial
	cases[17].facts.scale_word, cases[17].refusal = 0, .Other_Scale
	cases[18].facts.scale_word, cases[18].refusal = u64(max(scale_factor.Scale)) + 1, .Other_Scale
	cases[19].facts.scale_word, cases[19].refusal = u64(scale_factor.Scale.Ten_Eighths), .Other_Scale
	cases[20].facts.window_width, cases[20].refusal = WINDOW_LOGICAL_LIMIT + 1, .Other_Size
	cases[21].facts.window_height, cases[21].refusal = 0, .Other_Size
	for each, index in cases {
		refusal := surface_rescale_refusal(each.facts)
		testing.expectf(t, refusal == each.refusal, "case %d gives %v, not %v", index, refusal, each.refusal)
	}
	// The surface of the right size at 1.25 for a compositor at 1.375 is
	// the scale that the window read before the change: refused.
	facts := rescale_of_test()
	facts.width, facts.height, facts.scale_word = 1250, 880, u64(scale_factor.Scale.Ten_Eighths)
	testing.expect_value(t, surface_rescale_refusal(facts), Surface_Rescale_Refusal.Other_Scale)
	// The case that holds, and memory larger than needed.
	facts = rescale_of_test()
	testing.expect_value(t, surface_rescale_refusal(facts), Surface_Rescale_Refusal.None)
	facts.memory_bytes += PAGE_OF_TEST
	testing.expect_value(t, surface_rescale_refusal(facts), Surface_Rescale_Refusal.None)
}

// The largest grid that the seam test paints: a window of up to 64 logical
// pixels at a corner up to 16, at 1.375.
@(private = "file")
GRID_SIDE :: 160

@(private = "file")
grid_paint :: proc(grid: ^[GRID_SIDE][GRID_SIDE]bool, box: Screen_Box) {
	for y in max(box.top, 0) ..< min(box.bottom, GRID_SIDE) {
		for x in max(box.left, 0) ..< min(box.right, GRID_SIDE) {
			grid[y][x] = true
		}
	}
}

@(private = "file")
box_inside :: proc(inner, outer: Screen_Box) -> bool {
	return inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom
}

// The seam between the frame and the surface, at each corner of 0 to 15
// logical pixels and odd sizes, at 1.25 and at 1.375: the frame parts and
// the surface, cut to the interior, cover each pixel of the screen box of
// the frame, and nothing outside it. A surface of the size of the rule can
// be one pixel smaller than the interior on the screen, whose edges round
// on their own: the border that reaches one logical pixel under the
// interior covers that pixel.
@(test)
the_frame_and_the_surface_meet_with_no_gap :: proc(t: ^testing.T) {
	for scale in ([?]scale_factor.Scale{.Ten_Eighths, .Eleven_Eighths}) {
		for corner_x in 0 ..< 16 {
			for corner_y in 0 ..< 16 {
				for size in ([?][2]int{{1, 1}, {7, 3}, {13, 29}, {64, 63}}) {
					width, height := size[0], size[1]
					outer := screen_box_of({corner_x, corner_y, corner_x + width + 2 * BORDER_OF_TEST, corner_y + height + TITLE_OF_TEST + BORDER_OF_TEST}, scale)
					interior := screen_box_of({corner_x + BORDER_OF_TEST, corner_y + TITLE_OF_TEST, corner_x + BORDER_OF_TEST + width, corner_y + TITLE_OF_TEST + height}, scale)
					surface := surface_clip(interior.left, interior.top, int(scale_factor.screen_pixel_of_logical_pixel(i32(width), scale)), int(scale_factor.screen_pixel_of_logical_pixel(i32(height), scale)), interior)
					grid: [GRID_SIDE][GRID_SIDE]bool
					grid_paint(&grid, surface)
					testing.expect(t, box_inside(surface, interior))
					parts := frame_parts(corner_x, corner_y, width, height, BORDER_OF_TEST, TITLE_OF_TEST)
					for part in parts {
						on_screen := screen_box_of(part, scale)
						testing.expectf(t, box_inside(on_screen, outer), "a frame part %v is outside %v", on_screen, outer)
						grid_paint(&grid, on_screen)
					}
					for y in 0 ..< GRID_SIDE {
						for x in 0 ..< GRID_SIDE {
							inside := x >= outer.left && x < outer.right && y >= outer.top && y < outer.bottom
							if grid[y][x] != inside {
								testing.expectf(t, false, "at %v, the window %v at %d,%d: the pixel %d,%d is %v", scale, size, corner_x, corner_y, x, y, grid[y][x] ? "covered outside the frame" : "a gap")
								return
							}
						}
					}
				}
			}
		}
	}
}

// The overflow of a change 1.375 to 1.25: the surface of 1.375, larger than
// the interior at 1.25, is cut to the interior, so no pixel of it lands
// outside the frame, over the background or another window; the other way,
// the surface of 1.25 in an interior at 1.375 leaves a part that the
// compositor fills with the background.
@(test)
a_surface_of_another_scale_stays_inside_its_window :: proc(t: ^testing.T) {
	for size in ([?][2]int{{1, 1}, {560, 592}, {1000, 704}, {WINDOW_LOGICAL_LIMIT, WINDOW_LOGICAL_LIMIT}}) {
		for corner in ([?][2]int{{0, 0}, {3, 7}, {-5, 33}, {1535, 863}}) {
			larger_width := int(scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), .Eleven_Eighths))
			larger_height := int(scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), .Eleven_Eighths))
			interior := screen_box_of({corner[0] + BORDER_OF_TEST, corner[1] + TITLE_OF_TEST, corner[0] + BORDER_OF_TEST + size[0], corner[1] + TITLE_OF_TEST + size[1]}, .Ten_Eighths)
			box := surface_clip(interior.left, interior.top, larger_width, larger_height, interior)
			testing.expect(t, box_inside(box, interior))
			// From 8 logical pixels, the surface of 1.375 is at least one
			// pixel larger than the interior at 1.25, whose edges round on
			// their own: it fills it, and its overflow is cut.
			if size[0] >= 8 {
				testing.expectf(t, box == interior, "the surface of 1.375 of %v at %v covers %v, not the interior %v", size, corner, box, interior)
			}
			smaller_width := int(scale_factor.screen_pixel_of_logical_pixel(i32(size[0]), .Ten_Eighths))
			smaller_height := int(scale_factor.screen_pixel_of_logical_pixel(i32(size[1]), .Ten_Eighths))
			wider := screen_box_of({corner[0] + BORDER_OF_TEST, corner[1] + TITLE_OF_TEST, corner[0] + BORDER_OF_TEST + size[0], corner[1] + TITLE_OF_TEST + size[1]}, .Eleven_Eighths)
			box = surface_clip(wider.left, wider.top, smaller_width, smaller_height, wider)
			testing.expect(t, box_inside(box, wider))
			if size[0] > 8 {
				testing.expectf(t, box != wider, "the surface of 1.25 of %v fills the interior at 1.375", size)
			}
		}
	}
	// A surface of 0 pixels covers nothing.
	empty := surface_clip(10, 10, 0, 0, {10, 10, 20, 20})
	testing.expect(t, empty.right <= empty.left && empty.bottom <= empty.top)
}
// A Surface_Declined is taken only in place of the offer that the window
// owes: each broken rule first, each with the one fact that breaks it, the
// scale words of no member (0, 7, 17, the largest) and another member of
// the range; the decline that holds comes last.
@(test)
surface_declined_refusal_refuses_each_broken_rule :: proc(t: ^testing.T) {
	held :: proc() -> Surface_Declined_Facts {
		return {scale_word = u64(scale_factor.Scale.Sixteen_Eighths), serial = 5, created = true, released = true, released_serial = 4, scale = .Sixteen_Eighths}
	}
	Case :: struct {
		facts:   Surface_Declined_Facts,
		refusal: Surface_Declined_Refusal,
	}
	cases: [10]Case
	for &each in cases {
		each.facts = held()
	}
	cases[0].facts.created, cases[0].refusal = false, .No_Window
	cases[1].facts.pending, cases[1].refusal = true, .Pending
	cases[2].facts.released, cases[2].refusal = false, .Not_Released
	cases[3].facts.serial, cases[3].refusal = 4, .Other_Serial
	cases[4].facts.serial, cases[4].refusal = 6, .Other_Serial
	cases[5].facts.serial, cases[5].refusal = max(u64), .Other_Serial
	cases[6].facts.scale_word, cases[6].refusal = 0, .Other_Scale
	cases[7].facts.scale_word, cases[7].refusal = scale_factor.EIGHTHS_OF_ONE - 1, .Other_Scale
	cases[8].facts.scale_word, cases[8].refusal = u64(max(scale_factor.Scale)) + 1, .Other_Scale
	cases[9].facts.scale_word, cases[9].refusal = u64(scale_factor.Scale.Fifteen_Eighths), .Other_Scale
	for each, index in cases {
		testing.expectf(t, surface_declined_refusal(each.facts) == each.refusal, "case %d gives %v, not %v", index, surface_declined_refusal(each.facts), each.refusal)
	}
	testing.expect_value(t, surface_declined_refusal({scale_word = max(u64), serial = 5, created = true, released = true, released_serial = 4, scale = .Sixteen_Eighths}), Surface_Declined_Refusal.Other_Scale)
	testing.expect_value(t, surface_declined_refusal(held()), Surface_Declined_Refusal.None)
}

// A window that declines the scale in force again, at the next serial,
// is taken (the serial moved), and is no news: the compositor writes no
// second fact. A decline of a new scale is news again.
@(test)
a_second_decline_at_the_same_scale_is_no_news :: proc(t: ^testing.T) {
	facts := Surface_Declined_Facts{scale_word = u64(scale_factor.Scale.Sixteen_Eighths), serial = 5, created = true, released = true, released_serial = 4, scale = .Sixteen_Eighths}
	testing.expect(t, surface_decline_is_news(false, .Eight_Eighths, facts.scale))
	// The compositor took it: the released serial is the serial of the decline.
	facts.released_serial, facts.serial = 5, 6
	testing.expect_value(t, surface_declined_refusal(facts), Surface_Declined_Refusal.None)
	testing.expect(t, !surface_decline_is_news(true, .Sixteen_Eighths, facts.scale))
	for scale in scale_factor.Scale {
		testing.expect_value(t, surface_decline_is_news(true, scale, .Sixteen_Eighths), scale != .Sixteen_Eighths)
	}
}

// The release of a fixed window answers its clamp only: a release with no
// request, the request of a resizable window, a request that is no clamp,
// and a window with a pending surface end the request with no new size.
// Each refusal of one fact comes first; the case that holds comes last.
@(test)
a_release_answers_the_clamp_of_a_fixed_window_only :: proc(t: ^testing.T) {
	testing.expect(t, !release_answers_clamp(false, true, false, false))
	testing.expect(t, !release_answers_clamp(true, true, true, false))
	testing.expect(t, !release_answers_clamp(true, false, false, false))
	testing.expect(t, !release_answers_clamp(true, true, false, true))
	testing.expect(t, !release_answers_clamp(false, false, true, true))
	testing.expect(t, release_answers_clamp(true, true, false, false))
}

// The offer after a clamp: interface_elements, 816 x 560, opened at 2 and
// clamped to 816 x 482, released at the serial 1. The compositor took the
// clamped size as its logical size, so an offer at the size before, one
// pixel off on each axis, or of the old scale is refused; the offer of
// 1632 x 964 at 2 is taken, in memory of that surface and no more.
@(test)
the_offer_after_a_clamp_has_the_clamped_size :: proc(t: ^testing.T) {
	clamped := Surface_Rescale_Facts {
		gift            = true,
		is_memory       = true,
		readable        = true,
		memory_bytes    = 1632 * 964 * SURFACE_BYTES_FOR_EACH_PIXEL,
		width           = 1632,
		height          = 964,
		scale_word      = u64(scale_factor.Scale.Sixteen_Eighths),
		serial          = 2,
		created         = true,
		released        = true,
		released_serial = 1,
		scale           = .Sixteen_Eighths,
		window_width    = 816,
		window_height   = 482,
	}
	before := clamped
	before.height, before.memory_bytes = 1120, 1632 * 1120 * SURFACE_BYTES_FOR_EACH_PIXEL
	testing.expect_value(t, surface_rescale_refusal(before), Surface_Rescale_Refusal.Other_Size)
	for step in ([?][2]i64{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
		off := clamped
		off.width, off.height = u64(i64(off.width) + step[0]), u64(i64(off.height) + step[1])
		testing.expectf(t, surface_rescale_refusal(off) == .Other_Size, "%v is taken", step)
	}
	old_scale := clamped
	old_scale.scale_word = u64(scale_factor.Scale.Ten_Eighths)
	testing.expect_value(t, surface_rescale_refusal(old_scale), Surface_Rescale_Refusal.Other_Scale)
	short := clamped
	short.memory_bytes -= 1
	testing.expect_value(t, surface_rescale_refusal(short), Surface_Rescale_Refusal.Too_Small)
	testing.expect_value(t, surface_rescale_refusal(clamped), Surface_Rescale_Refusal.None)
}

// The serial released after a refused offer: the next serial of a released
// window with no pending surface moves it; a serial past it, the same
// serial, an older one, a window that is not released, one with a pending
// surface, and the largest serial move nothing. A second refused offer then
// moves it again, so the window that offers again after each refusal meets
// the serial that the compositor expects.
@(test)
a_refused_offer_moves_the_serial_released :: proc(t: ^testing.T) {
	testing.expect_value(t, serial_after_refused_offer(true, false, 6, 8), 6)
	testing.expect_value(t, serial_after_refused_offer(true, false, 6, 6), 6)
	testing.expect_value(t, serial_after_refused_offer(true, false, 6, 5), 6)
	testing.expect_value(t, serial_after_refused_offer(false, false, 6, 7), 6)
	testing.expect_value(t, serial_after_refused_offer(true, true, 6, 7), 6)
	testing.expect_value(t, serial_after_refused_offer(true, false, max(u64), 0), max(u64))
	first := serial_after_refused_offer(true, false, 6, 7)
	testing.expect_value(t, first, 7)
	testing.expect_value(t, serial_after_refused_offer(true, false, first, 8), 8)
	facts := Surface_Rescale_Facts{gift = true, is_memory = true, readable = true, memory_bytes = 1500 * 993 * SURFACE_BYTES_FOR_EACH_PIXEL, width = 1500, height = 993, scale_word = u64(scale_factor.Scale.Twelve_Eighths), serial = 8, created = true, released = true, released_serial = first, scale = .Twelve_Eighths, window_width = 1000, window_height = 662}
	testing.expect_value(t, surface_rescale_refusal(facts), Surface_Rescale_Refusal.None)
}
