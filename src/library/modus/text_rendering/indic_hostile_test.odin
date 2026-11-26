#+build !freestanding
#+build !modus
package text_rendering

import "core:strings"
import "core:testing"
import "modus:contract/text_encoding"
import "modus:vector_font"

// The shaper of the scripts of India against hostile text: each character
// of the text draws, the work stays inside the budget of the call, and the
// count of glyphs inside its bound.

// syllables_cover reads a text syllable by syllable: each syllable ends
// past its start, holds 1 to INDIC_SYLLABLE_LIMIT characters, and the last
// ends at the end of the text; it gives the count of syllables.
@(private = "file")
syllables_cover :: proc(t: ^testing.T, text: []u8) -> (count: int) {
	place := 0
	for place < len(text) {
		syllable, read := indic_syllable_read(text, place)
		if !read {
			// A character that no syllable takes: one cluster of its own.
			_, length, _ := text_encoding.character_decode(text, place)
			place += max(length, 1)
			count += 1
			continue
		}
		testing.expectf(t, syllable.end > place && syllable.count >= 1 && syllable.count <= INDIC_SYLLABLE_LIMIT, "the syllable at %d: %d characters, its end %d", place, syllable.count, syllable.end)
		if syllable.end <= place {
			return count
		}
		place = syllable.end
		count += 1
	}
	testing.expect_value(t, place, len(text))
	return count
}

// The bounds of a syllable: (क्) seven times and क with ि is 16
// characters, one syllable; a modifier after them is the 17th, which starts
// a syllable of its own on the dotted circle. A consonant whose nukta form
// splits in two (क़) after 15 characters does not fit: the syllable ends
// before its virama, and the next syllable holds both of its parts; no
// character is passed. ra and a virama at the end of a text, and ra, a
// virama and a joiner with no consonant after them, make no reph and draw.
@(test)
a_syllable_meets_its_bounds :: proc(t: ^testing.T) {
	sixteen := strings.concatenate({strings.repeat("क्", 7, context.temp_allocator), "कि"}, context.temp_allocator)
	syllable, read := indic_syllable_read(transmute([]u8)sixteen, 0)
	testing.expectf(t, read && syllable.count == INDIC_SYLLABLE_LIMIT && syllable.end == len(sixteen), "16 characters: %d, the end %d of %d", syllable.count, syllable.end, len(sixteen))
	seventeen := strings.concatenate({sixteen, "ं"}, context.temp_allocator)
	syllable, read = indic_syllable_read(transmute([]u8)seventeen, 0)
	testing.expect(t, read && syllable.count == INDIC_SYLLABLE_LIMIT && syllable.end == len(sixteen))
	after, after_read := indic_syllable_read(transmute([]u8)seventeen, len(sixteen))
	testing.expect(t, after_read && after.characters[0] == DOTTED_CIRCLE && after.count == 2 && after.end == len(seventeen))
	split := strings.concatenate({strings.repeat("क्", 7, context.temp_allocator), "क्", "क़"}, context.temp_allocator)
	testing.expect_value(t, syllables_cover(t, transmute([]u8)split), 2)
	first, _ := indic_syllable_read(transmute([]u8)split, 0)
	second, second_read := indic_syllable_read(transmute([]u8)split, first.end)
	testing.expectf(t, second_read && second.count == 2 && second.characters[0] == 0x0915 && second.characters[1] == 0x093C, "the split consonant: %v", second.characters[:second.count])
	for text in ([?]string{"कर्", "र्‍", "र्‌", "र्"}) {
		syllable, read = indic_syllable_read(transmute([]u8)text, 0)
		testing.expect(t, read)
		testing.expectf(t, syllables_cover(t, transmute([]u8)text) >= 1, "%q", text)
	}
}

// 10 000 viramas, 10 000 bindus and 10 000 joiners after a consonant, and
// 10 000 consonants of eight scripts in turn: each shapes with no fault,
// each syllable holds at most 16 characters, the work stays inside the
// budget of the call, and the count of placed glyphs is at least one for
// each syllable and at most the glyphs of a Shaped for each.
@(test)
hostile_text_of_the_scripts_of_india :: proc(t: ^testing.T) {
	test_state_take()
	names := [2]string{"noto_sans_devanagari", "noto_sans_telugu"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	mixed := make([dynamic]u8, context.temp_allocator)
	for index in 0 ..< 10_000 {
		character := rune(0x0915 + 0x80 * rune(index % 8))
		bytes: [4]u8
		length := text_encoding.character_encode(character, bytes[:])
		append(&mixed, ..bytes[:length])
	}
	texts := [?]string{
		strings.concatenate({"क", strings.repeat("्", 10_000, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({"क", strings.repeat("ं", 10_000, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({"क्", strings.repeat("‍", 10_000, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({"త", strings.repeat("్ర", 5_000, context.temp_allocator)}, context.temp_allocator),
		string(mixed[:]),
	}
	placed := make([]Placed_Glyph, 1 << 17, context.temp_allocator)
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	for text in texts {
		bytes := transmute([]u8)text
		syllables := syllables_cover(t, bytes)
		count, width, ok := shape(&spacing, bytes, placed)
		testing.expectf(t, ok && count >= syllables && count <= (1 + CLUSTER_MARK_LIMIT) * syllables, "%d bytes: %d glyphs for %d syllables", len(bytes), count, syllables)
		measured, _ := text_width(&spacing, bytes)
		testing.expect_value(t, measured, width)
		shaper := shaper_of(&spacing, bytes)
		testing.expect(t, shaper.budget.limit == vector_font.LAYOUT_WORK_FLOOR + len(bytes) * vector_font.LAYOUT_WORK_PER_BYTE)
	}
}

// A budget that a call spends: the syllables after it draw as the plain
// glyphs of their characters, each character a glyph, and nothing faults.
@(test)
a_spent_budget_draws_the_plain_glyphs :: proc(t: ^testing.T) {
	test_state_take()
	names := [1]string{"noto_sans_devanagari"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	text := transmute([]u8)string("क्षि")
	shaper := shaper_of(&spacing, text)
	shaper.budget.work = shaper.budget.limit
	shaped: Shaped
	count := 0
	for shaper_next(&shaper, &shaped) {
		testing.expect(t, !shaped.syllable)
		count += 1 + shaped.mark_count
	}
	testing.expect_value(t, count, 4)
}
