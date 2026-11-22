#+build !freestanding
package unicode_latin

import "core:testing"

@(test)
nfc_check_refuses_nfd_and_normalizes_latin :: proc(t: ^testing.T) {
	// Precomposed NFC French words pass.
	testing.expect(t, is_nfc_latin("école"))
	testing.expect(t, is_nfc_latin("été"))
	testing.expect(t, is_nfc_latin("façade"))
	testing.expect(t, is_nfc_latin(""))

	// Decomposed NFD ("e" + U+0301) looks identical to "é" and must be refused by is_nfc_latin.
	nfd_ecole := "e\u0301cole"
	testing.expect(t, !is_nfc_latin(nfd_ecole))

	// normalize_nfc_latin composes NFD -> NFC identically to "école".
	buf: [64]u8
	n, ok := normalize_nfc_latin(nfd_ecole, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(buf[:n]), "école")
	testing.expect(t, is_nfc_latin(string(buf[:n])))

	// Too-small output buffer refused cleanly.
	tiny: [2]u8
	_, small_ok := normalize_nfc_latin(nfd_ecole, tiny[:])
	testing.expect(t, !small_ok)

	// Invalid UTF-8 refused.
	bad_bytes := [2]u8{0xFF, 0xFE}
	bad := string(bad_bytes[:])
	testing.expect(t, !is_nfc_latin(bad))
	_, bad_ok := normalize_nfc_latin(bad, buf[:])
	testing.expect(t, !bad_ok)
}

@(test)
grapheme_stepper_keeps_combining_marks_and_crlf_together :: proc(t: ^testing.T) {
	// "e" + combining acute is 3 bytes (1 + 2), stepped as one grapheme cluster.
	s := "e\u0301a\r\nb"
	p1 := grapheme_next(s, 0)
	testing.expect_value(t, p1, 3)
	p2 := grapheme_next(s, p1)
	testing.expect_value(t, p2, 4) // 'a'
	p3 := grapheme_next(s, p2)
	testing.expect_value(t, p3, 6) // "\r\n" as one cluster
	p4 := grapheme_next(s, p3)
	testing.expect_value(t, p4, 7) // 'b'

	// Reverse stepping returns exact starts.
	testing.expect_value(t, grapheme_prev(s, p4), p3)
	testing.expect_value(t, grapheme_prev(s, p3), p2)
	testing.expect_value(t, grapheme_prev(s, p2), p1)
	testing.expect_value(t, grapheme_prev(s, p1), 0)
	testing.expect_value(t, grapheme_prev(s, 0), 0)
}

@(test)
line_break_wraps_on_spaces_hyphens_and_newlines :: proc(t: ^testing.T) {
	s := "hello world\nnext-line here"
	e1, k1 := line_break_next(s, 0, 8)
	testing.expect_value(t, k1, Line_Break_Kind.Soft)
	testing.expect_value(t, s[:e1], "hello ")

	e2, k2 := line_break_next(s, e1, 8)
	testing.expect_value(t, k2, Line_Break_Kind.Mandatory)
	testing.expect_value(t, s[e1:e2], "world\n")

	e3, k3 := line_break_next(s, e2, 7)
	testing.expect_value(t, k3, Line_Break_Kind.Soft)
	testing.expect_value(t, s[e2:e3], "next-")

	// Forced break on long unbroken word.
	word := "supercalifragilistic"
	ef, kf := line_break_next(word, 0, 5)
	testing.expect_value(t, kf, Line_Break_Kind.Forced)
	testing.expect_value(t, word[:ef], "super")
}

@(test)
french_and_english_collation_orders_accented_words :: proc(t: ^testing.T) {
	_, bad_loc := collation_locale_of_word(99)
	testing.expect(t, !bad_loc)
	loc, ok_loc := collation_locale_of_word(u64(Collation_Locale.French))
	testing.expect(t, ok_loc && loc == .French)

	// French reader order: ecole < école < écouter < été < zèbre (raw UTF-8 puts 'é' after 'z'!).
	testing.expect(t, collate_latin("ecole", "école", .French) < 0)
	testing.expect(t, collate_latin("école", "écouter", .French) < 0)
	testing.expect(t, collate_latin("écouter", "été", .French) < 0)
	testing.expect(t, collate_latin("été", "zèbre", .French) < 0)

	// French backwards secondary difference: last differing accent wins ("côte" < "coté").
	testing.expect(t, collate_latin("côte", "coté", .French) < 0)
	// English forwards secondary difference: first differing accent wins ("coté" < "côte").
	testing.expect(t, collate_latin("coté", "côte", .English) < 0)
	// Identical strings compare equal in both locales.
	testing.expect_value(t, collate_latin("élève", "élève", .French), 0)
}
