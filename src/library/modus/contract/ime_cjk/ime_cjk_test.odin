#+build !freestanding
package ime_cjk

import "core:testing"

@(test)
cjk_ime_candidates_and_double_width_cells :: proc(t: ^testing.T) {
	_, bad := ime_mode_of_word(99)
	testing.expect(t, !bad)

	// UAX #11 East Asian widths.
	testing.expect_value(t, east_asian_cell_width('A'), 1)
	testing.expect_value(t, east_asian_cell_width('é'), 1)
	testing.expect_value(t, east_asian_cell_width('中'), 2)
	testing.expect_value(t, east_asian_cell_width('あ'), 2)
	testing.expect_value(t, east_asian_cell_width('한'), 2)
	testing.expect_value(t, east_asian_cell_width(0x0301), 0)

	// Pinyin composition & candidate commit.
	s: Ime_State
	testing.expect_value(t, ime_init(&s, .Pinyin), Ime_Refusal.None)
	testing.expect_value(t, ime_push_ascii(&s, '1'), Ime_Refusal.Invalid_Char)
	testing.expect_value(t, ime_push_ascii(&s, 'n'), Ime_Refusal.None)
	testing.expect_value(t, ime_push_ascii(&s, 'i'), Ime_Refusal.None)
	testing.expect_value(t, s.candidate_count, 3)

	// Out-of-range index & tiny buffer refused without clearing preedit.
	buf: [32]u8
	_, r_idx := ime_commit_candidate(&s, 3, buf[:])
	testing.expect_value(t, r_idx, Ime_Refusal.Invalid_Index)
	tiny: [1]u8
	_, r_buf := ime_commit_candidate(&s, 0, tiny[:])
	testing.expect_value(t, r_buf, Ime_Refusal.Buffer_Too_Small)
	testing.expect_value(t, s.preedit_len, 2)

	// Valid commit outputs "你" and clears preedit.
	n, r_ok := ime_commit_candidate(&s, 0, buf[:])
	testing.expect_value(t, r_ok, Ime_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "你")
	testing.expect_value(t, s.preedit_len, 0)

	// Romaji-to-Kana & backspace/cancel.
	testing.expect_value(t, ime_init(&s, .Romaji_Kana), Ime_Refusal.None)
	_ = ime_push_ascii(&s, 'k')
	_ = ime_push_ascii(&s, 'a')
	n2, r2 := ime_commit_candidate(&s, 0, buf[:])
	testing.expect_value(t, r2, Ime_Refusal.None)
	testing.expect_value(t, string(buf[:n2]), "か")
}
