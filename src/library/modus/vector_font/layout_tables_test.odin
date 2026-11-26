#+build !freestanding
#+build !modus
package vector_font

import "core:math/rand"
import "core:testing"

// The anchors of the marks (positioning.odin) and the multiple
// substitution (substitution.odin) on the script fonts, then on their
// tables cut and changed: a hostile table gives a refusal or another
// answer, never a read out of the file, a glyph past the font, or a
// sequence past its memory.

// Noto Sans Arabic makes beh, teh and noon a body and one mark of dots by
// ccmp, and each form of each body has an anchor for its dots; a fatha
// sits on the dots of teh by mkmk. A glyph with no anchor, a mark that the
// coverage lacks, and a font with no GPOS give none. A memory of one glyph
// keeps the body alone.
@(test)
the_anchors_and_the_sequences_of_arabic :: proc(t: ^testing.T) {
	// A budget that the test never spends: it checks the answers.
	test_budget := Layout_Budget{limit = LAYOUT_WORK_CAP}
	bytes := script_font_bytes(t, "noto_sans_arabic")
	defer delete(bytes)
	font, ok := script_font_open(t, bytes)
	if !ok {
		return
	}
	testing.expect(t, font.gpos.length > 0)
	arab := Feature_Tag{'a', 'r', 'a', 'b'}
	forms := [3]Feature_Tag{{'i', 'n', 'i', 't'}, {'m', 'e', 'd', 'i'}, {'f', 'i', 'n', 'a'}}
	for character in ([?]rune{0x0628, 0x062A, 0x0646}) {
		plain, _ := glyph_of(&font, character)
		parts: [SEQUENCE_LIMIT]int
		count, problem := script_substitution(&font, arab, {'c', 'c', 'm', 'p'}, plain, parts[:], &test_budget)
		testing.expectf(t, problem == .None && count == 2 && parts[0] != plain, "U+%04X is a body and its dots: %v", int(character), parts[:count])
		for form in forms {
			formed: [SEQUENCE_LIMIT]int
			formed_count, form_problem := script_substitution(&font, arab, form, parts[0], formed[:], &test_budget)
			testing.expect(t, form_problem == .None && formed_count >= 1 && formed[0] > 0 && formed[0] < font.glyph_count)
			_, _, found, anchor_problem := mark_anchor_offset(&font, arab, .Base, formed[0], parts[1], &test_budget)
			testing.expectf(t, anchor_problem == .None && found, "U+%04X %v: its dots have an anchor", int(character), form)
		}
		one: [1]int
		kept, kept_problem := script_substitution(&font, arab, {'c', 'c', 'm', 'p'}, plain, one[:], &test_budget)
		testing.expect(t, kept_problem == .None && kept == 1 && one[0] == parts[0])
		_, empty_problem := script_substitution(&font, arab, {'c', 'c', 'm', 'p'}, plain, nil, &test_budget)
		testing.expect_value(t, empty_problem, Font_Problem.Too_Short)
	}
	teh, _ := glyph_of(&font, 0x062A)
	fatha, _ := glyph_of(&font, 0x064E)
	parts: [SEQUENCE_LIMIT]int
	script_substitution(&font, arab, {'c', 'c', 'm', 'p'}, teh, parts[:], &test_budget)
	_, dy, found, _ := mark_anchor_offset(&font, arab, .Mark, parts[1], fatha, &test_budget)
	testing.expect(t, found && dy > 0, "the fatha sits above the dots of teh")
	// No anchor: a body as the mark, which no coverage of marks holds, and
	// a glyph past the font.
	_, _, found, _ = mark_anchor_offset(&font, arab, .Base, parts[0], parts[0], &test_budget)
	testing.expect(t, !found)
	_, _, found, _ = mark_anchor_offset(&font, arab, .Base, parts[0], font.glyph_count + 5, &test_budget)
	testing.expect(t, !found)
	no_gpos := font
	no_gpos.gpos = {}
	_, _, found_without, problem_without := mark_anchor_offset(&no_gpos, arab, .Base, parts[0], parts[1], &test_budget)
	testing.expect(t, !found_without && problem_without == .None)
}

// The tables GSUB and GPOS of Noto Sans Arabic and Noto Sans Hebrew, cut
// at each 97 bytes and changed at random bytes (a fixed seed): each answer
// is a refusal or a glyph of the font, and a sequence within its memory.
@(test)
hostile_layout_tables :: proc(t: ^testing.T) {
	generator := rand.create(0x5C41_F047)
	context.random_generator = rand.default_random_generator(&generator)
	for name in ([?]string{"noto_sans_arabic", "noto_sans_hebrew"}) {
		original := script_font_bytes(t, name)
		defer delete(original)
		font, ok := script_font_open(t, original)
		if !ok {
			continue
		}
		bytes := make([]u8, len(original))
		defer delete(bytes)
		script := name == "noto_sans_arabic" ? Feature_Tag{'a', 'r', 'a', 'b'} : Feature_Tag{'h', 'e', 'b', 'r'}
		characters := name == "noto_sans_arabic" ? []rune{0x0628, 0x062A, 0x0646, 0x064A, 0x0644} : []rune{0x05D1, 0x05E9, 0x05DC}
		marks := name == "noto_sans_arabic" ? []rune{0x064E, 0x0650, 0x0651} : []rune{0x05B8, 0x05BC, 0x05C1}
		try :: proc(t: ^testing.T, font: ^Font_File, script: Feature_Tag, characters, marks: []rune) {
			// One budget for one try, as for one call: past it, each read is
			// refused, which is an answer that the test takes.
			test_budget := Layout_Budget{limit = LAYOUT_WORK_CAP}
			for character in characters {
				plain, _ := glyph_of(font, character)
				for tag in ([?]Feature_Tag{{'c', 'c', 'm', 'p'}, {'i', 'n', 'i', 't'}, {'f', 'i', 'n', 'a'}}) {
					out: [SEQUENCE_LIMIT]int
					count, problem := script_substitution(font, script, tag, plain, out[:], &test_budget)
					if problem == .None {
						testing.expect(t, count >= 1 && count <= len(out))
						for glyph in out[:count] {
							testing.expect(t, glyph >= 0 && glyph < font.glyph_count)
						}
					}
				}
				for mark in marks {
					mark_glyph, _ := glyph_of(font, mark)
					for attachment in Mark_Attachment {
						_, _, _, _ = mark_anchor_offset(font, script, attachment, plain, mark_glyph, &test_budget)
					}
				}
			}
		}
		for table in ([2]Table{font.gsub, font.gpos}) {
			if table.length == 0 {
				continue
			}
			// Cut: the table ends early.
			for cut := 0; cut < table.length; cut += 97 {
				cut_font := font
				if table == font.gsub {
					cut_font.gsub.length = cut
				} else {
					cut_font.gpos.length = cut
				}
				try(t, &cut_font, script, characters, marks)
			}
			// Changed: 64 random bytes of the table, 32 times.
			for _ in 0 ..< 32 {
				copy(bytes, original)
				for _ in 0 ..< 64 {
					bytes[table.offset + rand.int_max(table.length)] = u8(rand.int_max(256))
				}
				changed_font := font
				changed_font.bytes = bytes
				try(t, &changed_font, script, characters, marks)
			}
		}
	}
}
