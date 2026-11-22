#+build !freestanding
package bar

import "core:testing"

// attach refuses each kind word that names no member, None, an empty, long,
// damaged or control nickname, and a full registry; each refusal changes
// nothing.
@(test)
assistive_attach_refuses_each_bad_input :: proc(t: ^testing.T) {
	for word in u64(0) ..= 255 {
		kind, ok := assistive_holder_kind_of_word(word)
		if word <= u64(max(Assistive_Holder_Kind)) {
			testing.expectf(t, ok && u64(kind) == word, "kind word %d refused", word)
		} else {
			testing.expectf(t, !ok, "kind word %d accepted as %v", word, kind)
		}
	}
	_, largest_ok := assistive_holder_kind_of_word(max(u64))
	testing.expect(t, !largest_ok, "the largest word must name no kind")

	registry: Assistive_Registry
	long_name := "abcdefghijklmnopqrstuvwxyz012345" // 32 bytes: one past the bound.
	cases := [?]struct {
		nickname: string,
		kind:     Assistive_Holder_Kind,
		refusal:  Assistive_Attach_Refusal,
	}{
		{"reader", .None, .Kind_None},
		{"", .Screen_Reader, .Empty_Nickname},
		{long_name, .Screen_Reader, .Nickname_Too_Long},
		{"bad\x00name", .Screen_Reader, .Nickname_Invalid},
		{"line\nbreak", .Screen_Reader, .Nickname_Invalid},
		{"delete\x7f", .Screen_Reader, .Nickname_Invalid},
		{"a\xC3", .Screen_Reader, .Nickname_Invalid},
		{"\xFF\xFE", .Magnifier, .Nickname_Invalid},
	}
	for c in cases {
		id, refusal := assistive_attach(&registry, c.nickname, c.kind)
		testing.expectf(t, id == 0 && refusal == c.refusal, "%q %v: id %d refusal %v, want %v", c.nickname, c.kind, id, refusal, c.refusal)
		testing.expect_value(t, registry.count, 0)
		testing.expect_value(t, registry.last_id, u64(0))
	}

	// The bound: 31 bytes are taken, and the fifth holder is refused.
	id, refusal := assistive_attach(&registry, long_name[:ASSISTIVE_NICKNAME_BYTES], .Screen_Reader)
	testing.expect(t, id == 1 && refusal == .None, "a nickname of 31 bytes must be taken")
	for index in 1 ..< ASSISTIVE_HOLDER_LIMIT {
		_, refusal = assistive_attach(&registry, "switch", .Switch_Input)
		testing.expectf(t, refusal == .None, "holder %d refused: %v", index, refusal)
	}
	before := registry
	id, refusal = assistive_attach(&registry, "keyboard", .Switch_Input)
	testing.expect(t, id == 0 && refusal == .Full, "a full registry must refuse")
	testing.expect(t, registry == before, "a refusal must change nothing")
}

// A magnifier and a screen reader hold the role together; detach refuses
// 0, an unknown number and a number detached already, and the mark goes
// only with the last holder.
@(test)
assistive_holders_run_together_and_detach_cleanly :: proc(t: ^testing.T) {
	registry: Assistive_Registry
	testing.expect(t, !assistive_mark_shown(&registry), "no holder: no mark")

	magnifier, magnifier_refusal := assistive_attach(&registry, "magnifier", .Magnifier)
	reader, reader_refusal := assistive_attach(&registry, "screen_reader", .Screen_Reader)
	testing.expect(t, magnifier_refusal == .None && reader_refusal == .None, "two holders must run together")
	testing.expect(t, magnifier != reader && magnifier != 0 && reader != 0, "each holder has its own number")
	testing.expect_value(t, registry.count, 2)
	testing.expect(t, assistive_mark_shown(&registry), "a holder shows the mark")

	for bad in ([?]u64{0, 99, max(u64)}) {
		before := registry
		_, ok := assistive_detach(&registry, bad)
		testing.expectf(t, !ok, "detach of %d must be refused", bad)
		testing.expect(t, registry == before, "a refused detach must change nothing")
	}

	detached, ok := assistive_detach(&registry, magnifier)
	testing.expect(t, ok && detached.kind == .Magnifier && assistive_holder_nickname(&detached) == "magnifier", "detach gives the holder")
	_, again := assistive_detach(&registry, magnifier)
	testing.expect(t, !again, "a holder detached once is gone")
	testing.expect(t, assistive_mark_shown(&registry), "the reader still reads: the mark stays")
	testing.expect_value(t, assistive_find(&registry, reader), 1)

	// A new holder takes the free slot and a new number: the number of a
	// detached holder never names the new one.
	next, _ := assistive_attach(&registry, "magnifier", .Magnifier)
	testing.expect(t, next != magnifier && assistive_find(&registry, next) == 0, "a new holder takes slot 0 with a new number")

	_, ok = assistive_detach(&registry, reader)
	testing.expect(t, ok, "detach of the reader")
	_, ok = assistive_detach(&registry, next)
	testing.expect(t, ok, "detach of the last holder")
	testing.expect(t, !assistive_mark_shown(&registry), "no holder left: no mark")
	testing.expect_value(t, registry.count, 0)
}

// The mark says the word and the nickname; the marks go from the right in
// the order of the slots; a mark with no room is the square, never absent.
@(test)
assistive_marks_place_from_the_right_and_never_vanish :: proc(t: ^testing.T) {
	registry: Assistive_Registry
	none := assistive_marks_place(&registry, {}, 900, 400)
	testing.expect(t, none.count == 0 && none.left == 900, "no holder: no mark, no room taken")

	reader, _ := assistive_attach(&registry, "orca", .Screen_Reader)
	_, _ = assistive_attach(&registry, "zoom", .Magnifier)
	buffer: [ASSISTIVE_MARK_TEXT_BYTES]u8
	testing.expect_value(t, assistive_mark_text(&registry.holders[0], &buffer), "assistive orca")
	testing.expect_value(t, assistive_mark_text(&registry.holders[1], &buffer), "assistive zoom")

	widths := [ASSISTIVE_HOLDER_LIMIT]int{100, 120, 0, 0}
	layout := assistive_marks_place(&registry, widths, 900, 400)
	testing.expect_value(t, layout.count, 2)
	testing.expect(t, layout.marks[0] == Assistive_Mark{slot = 0, x = 900 - 116, width = 116}, "the first holder is at the right")
	testing.expect(t, layout.marks[1] == Assistive_Mark{slot = 1, x = 900 - 116 - ASSISTIVE_MARK_GAP - 136, width = 136}, "the second is at its left")
	testing.expect_value(t, layout.left, layout.marks[1].x)

	// No room for the words of the second: it is the square.
	tight := assistive_marks_place(&registry, widths, 900, 900 - 116 - ASSISTIVE_MARK_GAP - 135)
	testing.expect(t, !tight.marks[0].square && tight.marks[1].square && tight.marks[1].width == ASSISTIVE_MARK_SQUARE, "a mark with no room is the square")

	// No room at all: each mark is the square, and none is left out.
	none_room := assistive_marks_place(&registry, widths, 10, 1000)
	testing.expect(t, none_room.count == 2 && none_room.marks[0].square && none_room.marks[1].square, "with no room each holder keeps its square")

	// A damaged width never makes a mark narrower than its padding.
	negative := assistive_marks_place(&registry, {-50, -1, 0, 0}, 900, 0)
	testing.expect(t, negative.marks[0].width == 2 * PADDING && negative.marks[1].width == 2 * PADDING, "a negative width counts as 0")

	_, _ = assistive_detach(&registry, reader)
	after := assistive_marks_place(&registry, widths, 900, 400)
	testing.expect(t, after.count == 1 && after.marks[0].slot == 1, "the mark of a detached holder goes")
}

// magnify refuses with no holder, a factor past each bound, an empty
// rectangle and a rectangle off the screen, at each edge and near the
// largest i64.
@(test)
assistive_magnify_check_refuses_each_edge :: proc(t: ^testing.T) {
	registry: Assistive_Registry
	testing.expect_value(t, assistive_magnify_check(&registry, 0, 0, 10, 10, 16, 800, 600), Assistive_Magnify_Refusal.No_Holder)
	_, _ = assistive_attach(&registry, "zoom", .Magnifier)

	Case :: struct {
		left, top, width, height, factor: i64,
		refusal:                          Assistive_Magnify_Refusal,
	}
	cases := [?]Case{
		{0, 0, 10, 10, 11, .Factor_Out_Of_Range},
		{0, 0, 10, 10, 65, .Factor_Out_Of_Range},
		{0, 0, 10, 10, 0, .Factor_Out_Of_Range},
		{0, 0, 10, 10, -16, .Factor_Out_Of_Range},
		{0, 0, 10, 10, max(i64), .Factor_Out_Of_Range},
		{0, 0, 0, 10, 16, .Empty_Rectangle},
		{0, 0, 10, 0, 16, .Empty_Rectangle},
		{0, 0, -1, 10, 16, .Empty_Rectangle},
		{-1, 0, 10, 10, 16, .Outside_Screen},
		{0, -1, 10, 10, 16, .Outside_Screen},
		{791, 0, 10, 10, 16, .Outside_Screen},
		{0, 591, 10, 10, 16, .Outside_Screen},
		{0, 0, 801, 10, 16, .Outside_Screen},
		{1, 1, max(i64), max(i64), 16, .Outside_Screen},
		{max(i64), max(i64), 1, 1, 16, .Outside_Screen},
		{min(i64), 0, 10, 10, 16, .Outside_Screen},
		{0, 0, 10, 10, 12, .None},
		{0, 0, 10, 10, 64, .None},
		{790, 590, 10, 10, 16, .None},
		{0, 0, 800, 600, 16, .None},
	}
	for c in cases {
		got := assistive_magnify_check(&registry, c.left, c.top, c.width, c.height, c.factor, 800, 600)
		testing.expectf(t, got == c.refusal, "%v: got %v", c, got)
	}
}
