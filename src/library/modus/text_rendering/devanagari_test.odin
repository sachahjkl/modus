#+build !freestanding
package text_rendering

import "core:testing"
import "modus:vector_font"

// The shaper of Devanagari (indic.odin) against HarfBuzz. The expected
// glyphs come from HarfBuzz 12.3.0, through uharfbuzz 0.53.2 of nixpkgs, on
// the file NotoSansDevanagari.ttf of noto-fonts 2026.05.01, the file of
// the script font set: for each word, each glyph index, its advance and
// its offset, in units of the font. The clusters are not compared:
// HarfBuzz merges the clusters of a syllable, the shaper gives each glyph
// the byte of its first character.

@(private = "file")
Expected_Glyph :: struct {
	glyph, advance, x_offset, y_offset: i32,
}

@(private = "file")
Expected_Word :: struct {
	word:   string,
	glyphs: []Expected_Glyph,
}

@(private = "file")
expected_words := [?]Expected_Word {
	{"क", {{56, 768, 0, 0}}},
	{"कि", {{545, 259, 0, 0}, {56, 768, 0, 0}}},
	{"का", {{56, 768, 0, 0}, {31, 259, 0, 0}}},
	{"कु", {{56, 768, 0, 0}, {34, 0, -221, 0}}},
	{"के", {{56, 768, 0, 0}, {40, 0, -221, 0}}},
	{"कं", {{56, 768, 0, 0}, {100, 0, -221, 0}}},
	{"कः", {{56, 768, 0, 0}, {102, 202, 0, 0}}},
	{"र्क", {{56, 768, 0, 0}, {506, 0, -221, 0}}},
	{"र्का", {{56, 768, 0, 0}, {31, 259, 0, 0}, {506, 0, 0, 0}}},
	{"र्कि", {{590, 259, 0, 0}, {56, 768, 0, 0}, {785, 0, 0, 0}}},
	{"र्कं", {{56, 768, 0, 0}, {510, 0, -221, 0}}},
	{"क्ष", {{90, 717, 0, 0}}},
	{"क्षि", {{551, 259, 0, 0}, {90, 717, 0, 0}}},
	{"स्ति", {{553, 259, 0, 0}, {256, 389, 0, 0}, {71, 570, 0, 0}}},
	{"स्त्र", {{256, 389, 0, 0}, {304, 552, 0, 0}}},
	{"प्र", {{309, 569, 0, 0}}},
	{"क्र", {{295, 768, 0, 0}}},
	{"ट्र", {{66, 504, 0, 0}, {508, 0, -34, 0}}},
	{"कृ", {{56, 768, 0, 0}, {36, 0, -221, 0}}},
	{"हिन्दी", {{544, 259, 0, 0}, {88, 531, 0, 0}, {245, 309, 0, 0}, {73, 531, 0, 0}, {33, 259, 0, 0}}},
	{"नमस्ते", {{75, 555, 0, 0}, {80, 598, 0, 0}, {256, 389, 0, 0}, {71, 570, 0, 0}, {40, 0, 0, 0}}},
	{"शक्ति", {{85, 680, 0, 0}, {555, 259, 0, 0}, {232, 536, 0, 0}, {71, 570, 0, 0}}},
	{"द्ध", {{448, 799, 0, 0}}},
	{"श्री", {{317, 708, 0, 0}, {33, 259, 0, 0}}},
	{"ज्ञ", {{91, 641, 0, 0}}},
	{"त्र", {{304, 552, 0, 0}}},
	{"क्क", {{232, 545, 0, 0}, {56, 768, 0, 0}}},
	{"क्", {{56, 768, 0, 0}, {103, 0, -221, 0}}},
	{"ड़", {{225, 535, 0, 0}}},
	{"ॐ", {{126, 912, 0, 0}}},
	{"ि", {{32, 259, 0, 0}, {789, 510, 0, 0}}},
	{"्", {{789, 510, 0, 0}, {103, 0, -5, -21}}},
	{"हिंदी", {{559, 259, 0, 0}, {88, 531, 0, 0}, {785, 0, 0, 0}, {73, 531, 0, 0}, {33, 259, 0, 0}}},
	{"प्रिं", {{561, 259, 0, 0}, {309, 569, 0, 0}, {785, 0, 0, 0}}},
}

// Each word, shaped syllable by syllable, gives the glyphs, the advances
// and the offsets of HarfBuzz.
@(test)
devanagari_words_shape_as_harfbuzz :: proc(t: ^testing.T) {
	test_state_take()
	names := [1]string{"noto_sans_devanagari"}
	words, script_words, missing := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect(t, .Noto_Sans_Devanagari not_in missing)
	testing.expect_value(t, font_of(.Interface, 0x0915), Outline_Font.Noto_Sans_Devanagari)
	file := &font_at(&state.font_set, Outline_Font.Noto_Sans_Devanagari).file
	for expected in expected_words {
		text := transmute([]u8)expected.word
		got := make([dynamic]Expected_Glyph, context.temp_allocator)
		place := 0
		for {
			syllable, read := indic_syllable_read(text, place)
			if !read {
				break
			}
			buffer: vector_font.Engine_Buffer
			indic_shape(file, &syllable, &buffer)
			for glyph in buffer.glyphs[:buffer.count] {
				append(&got, Expected_Glyph{i32(glyph.glyph), glyph.x_advance, glyph.x_offset, glyph.y_offset})
			}
			place = syllable.end
		}
		testing.expectf(t, place == len(text), "%s: every syllable is Devanagari", expected.word)
		same := len(got) == len(expected.glyphs)
		for glyph, index in got {
			if same && glyph != expected.glyphs[index] {
				same = false
			}
		}
		testing.expectf(t, same, "%s: %v, HarfBuzz: %v", expected.word, got[:], expected.glyphs)
	}
}

// A syllable on a line: its glyphs in the order of the shaper, the first
// at the byte of the syllable; the reph of र्क is anchored over ka; a fit
// never cuts a syllable; a grid of cells does not shape it.
@(test)
devanagari_syllables_on_a_line :: proc(t: ^testing.T) {
	test_state_take()
	names := [1]string{"noto_sans_devanagari"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	placed: [16]Placed_Glyph
	count, width := shape_text(t, .Interface, "कि", placed[:])
	testing.expectf(t, count == 2 && placed[0].glyph == direct_glyph(.Noto_Sans_Devanagari, 545) && placed[1].glyph == direct_glyph(.Noto_Sans_Devanagari, 56), "ki: %v", placed[:count])
	testing.expect(t, placed[0].cluster == 0 && placed[1].x == placed[0].x + placed[0].advance && placed[1].placement == .Base)
	testing.expect_value(t, width, i64(placed[0].advance) + i64(placed[1].advance))
	count, _ = shape_text(t, .Interface, "र्क", placed[:])
	testing.expectf(t, count == 2 && placed[0].glyph == direct_glyph(.Noto_Sans_Devanagari, 56) && placed[1].glyph == direct_glyph(.Noto_Sans_Devanagari, 506), "rka: %v", placed[:count])
	testing.expectf(t, placed[1].placement == .Anchored && placed[1].x > placed[0].x && placed[1].x < placed[0].x + placed[0].advance, "the reph over ka: %v", placed[:count])
	// Two syllables, then Latin after them.
	count, _ = shape_text(t, .Interface, "नमस्ते a", placed[:])
	testing.expectf(t, count == 7 && placed[2].cluster == 6, "namaste: %v", placed[:count])
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	text := transmute([]u8)string("स्ति")
	full, _ := text_width(&spacing, text)
	testing.expect_value(t, text_fit(&spacing, text, full - 1), 0)
	testing.expect_value(t, text_fit(&spacing, text, full), len(text))
	cells := cell_spacing(8)
	count, _, _ = shape(&cells, text, placed[:])
	testing.expect_value(t, count, 4)
	// A mark with no base stands on the dotted circle of the font.
	count, _ = shape_text(t, .Interface, "ि", placed[:])
	testing.expectf(t, count == 2 && placed[1].glyph == direct_glyph(.Noto_Sans_Devanagari, 789), "a lone matra: %v", placed[:count])
}

// The reader of syllables refuses its bounds: a syllable stops at
// INDIC_SYLLABLE_LIMIT characters, and the characters after it start the
// next one; a text cut inside a character ends the syllable.
@(test)
devanagari_syllables_are_bounded :: proc(t: ^testing.T) {
	long := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 20 {
		append(&long, ..transmute([]u8)string("क्"))
	}
	append(&long, ..transmute([]u8)string("क"))
	place, syllables := 0, 0
	for {
		syllable, read := indic_syllable_read(long[:], place)
		if !read {
			break
		}
		testing.expect(t, syllable.count >= 1 && syllable.count <= INDIC_SYLLABLE_LIMIT && syllable.end > place)
		place = syllable.end
		syllables += 1
	}
	testing.expect_value(t, place, len(long))
	testing.expect(t, syllables > 1)
	cut := transmute([]u8)string("कि")
	syllable, read := indic_syllable_read(cut[:4], 0)
	testing.expect(t, read && syllable.count == 1 && syllable.end == 3)
	_, read = indic_syllable_read(transmute([]u8)string("a"), 0)
	testing.expect(t, !read)
	_, read = indic_syllable_read(nil, 0)
	testing.expect(t, !read)
}
