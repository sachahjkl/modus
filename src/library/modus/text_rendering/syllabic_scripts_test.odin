#+build !freestanding
package text_rendering

import "core:fmt"
import "core:testing"
import "modus:contract/text_encoding"
import "modus:vector_font"

// The shapers of Khmer, Myanmar and USE (khmer.odin, myanmar.odin,
// universal.odin) against HarfBuzz. The expected glyphs come from HarfBuzz
// 12.3.0, through uharfbuzz 0.53.2 of nixpkgs, on the files of noto-fonts
// 2026.05.01 that the script font set holds, with the buffer flag
// REMOVE_DEFAULT_IGNORABLES: the shaper draws no glyph for a joiner. For
// each word, each glyph index, its advance and its offset, in units of the
// font. The clusters are not compared: HarfBuzz merges more of them.

@(private = "file")
Syllabic_Glyph :: struct {
	glyph, advance, x_offset, y_offset: i32,
}

@(private = "file")
Syllabic_Word :: struct {
	word:   string,
	glyphs: []Syllabic_Glyph,
}

@(private = "file")
Syllabic_Words :: struct {
	font:  string,
	words: []Syllabic_Word,
}

@(private = "file")
expected_syllabic_scripts := [?]Syllabic_Words {
	{"noto_sans_khmer", {
		{"ក", {{25, 636, 0, 0}}},
		{"កា", {{212, 924, 0, 0}}},
		{"កិ", {{25, 636, 0, 0}, {81, 0, -23, -29}}},
		{"កុ", {{25, 636, 0, 0}, {91, 0, -22, -26}}},
		{"កើ", {{107, 288, 0, 0}, {25, 636, 0, 0}, {85, 0, -23, -29}}},
		{"កៀ", {{107, 288, 0, 0}, {25, 636, 0, 0}, {103, 288, 0, 0}}},
		{"កោ", {{107, 288, 0, 0}, {212, 924, 0, 0}}},
		{"កៅ", {{107, 288, 0, 0}, {213, 924, 0, 0}}},
		{"កែ", {{108, 288, 0, 0}, {25, 636, 0, 0}}},
		{"ក្ក", {{25, 636, 0, 0}, {159, 0, -2, -26}}},
		{"ក្រ", {{196, 287, 0, 0}, {25, 636, 0, 0}}},
		{"ក្រុ", {{196, 287, 0, 0}, {25, 636, 0, 0}, {92, 0, 127, -26}}},
		{"ស្ត្រី", {{196, 287, 0, 0}, {59, 928, 0, 0}, {180, 0, 14, -26}, {85, 0, -32, -29}}},
		{"ខ្មែរ", {{108, 288, 0, 0}, {26, 635, 0, 0}, {192, 0, 22, -26}, {54, 288, 0, 0}}},
		{"ភាសា", {{262, 923, 0, 0}, {278, 1216, 0, 0}}},
		{"កម្ពុជា", {{25, 636, 0, 0}, {52, 635, 0, 0}, {189, 0, -1, -26}, {91, 0, -22, -296}, {226, 923, 0, 0}}},
		{"ព្រះ", {{196, 287, 0, 0}, {50, 635, 0, 0}, {115, 386, 0, 0}}},
		{"ញ៉ាំ", {{230, 1240, 0, 0}, {91, 0, -461, -260}, {113, 0, 47, -29}}},
		{"ប៊ី", {{46, 635, 0, 0}, {120, 0, -46, -29}, {85, 0, -46, 113}}},
		{"កំ", {{25, 636, 0, 0}, {113, 0, -23, -29}}},
		{"ការ", {{212, 924, 0, 0}, {54, 288, 0, 0}}},
		{"សួស្តី", {{59, 928, 0, 0}, {95, 0, -6, -26}, {59, 928, 0, 0}, {180, 0, 14, -26}, {85, 0, -32, -29}}},
		{"ិ", {{360, 635, 0, 0}, {81, 0, -20, -84}}},
		{"្ក", {{360, 635, 0, 0}, {159, 0, 0, -26}}},
		{"ក៍", {{25, 636, 0, 0}, {126, 0, -23, -29}}},
		{"ស្រ្តី", {{196, 287, 0, 0}, {59, 928, 0, 0}, {180, 0, 14, -26}, {85, 0, -32, -29}}},
		{"ក្សត្រ", {{25, 636, 0, 0}, {203, 302, 0, 0}, {196, 287, 0, 0}, {41, 635, 0, 0}}},
		{"នេះ", {{107, 288, 0, 0}, {45, 635, 0, 0}, {115, 386, 0, 0}}},
		{"ឆ្នាំ", {{224, 923, 0, 0}, {185, 0, -296, -26}, {113, 0, 47, -29}}},
		{"\u1780\u200d\u17b6", {{25, 636, 0, 0}, {360, 635, 0, 0}, {80, 288, 0, 0}}},
	}},
	{"noto_sans_myanmar", {
		{"က", {{4, 1124, 0, 0}}},
		{"ကာ", {{4, 1124, 0, 0}, {368, 455, 0, 0}}},
		{"ကိ", {{4, 1124, 0, 0}, {369, 0, -27, 0}}},
		{"ကု", {{4, 1124, 0, 0}, {209, 0, -5, 0}}},
		{"ကေ", {{372, 618, 0, 0}, {4, 1124, 0, 0}}},
		{"ကော", {{372, 618, 0, 0}, {4, 1124, 0, 0}, {368, 455, 0, 0}}},
		{"ကို", {{4, 1124, 0, 0}, {369, 0, -27, 0}, {209, 0, -5, 0}}},
		{"ကြ", {{198, 229, 0, 0}, {4, 1124, 0, 0}}},
		{"ကျ", {{4, 1124, 0, 0}, {382, 257, 0, 0}}},
		{"ကွ", {{4, 1124, 0, 0}, {48, 0, -4, 0}}},
		{"ကှ", {{4, 1124, 0, 0}, {384, 0, -12, 0}}},
		{"ကျွ", {{4, 1124, 0, 0}, {366, 257, 0, 0}}},
		{"မြန်မာ", {{47, 229, 0, 0}, {29, 676, 0, 0}, {24, 570, 0, 0}, {381, 0, 43, 0}, {29, 676, 0, 0}, {368, 455, 0, 0}}},
		{"မင်္ဂလာ", {{29, 676, 0, 0}, {6, 668, 0, 0}, {189, 0, -4, 0}, {32, 1126, 0, 0}, {368, 455, 0, 0}}},
		{"သွား", {{34, 1127, 0, 0}, {48, 0, -18, 0}, {368, 455, 0, 0}, {379, 346, 0, 0}}},
		{"ပြော", {{372, 618, 0, 0}, {47, 229, 0, 0}, {25, 676, 0, 0}, {368, 455, 0, 0}}},
		{"ကောင်း", {{372, 618, 0, 0}, {4, 1124, 0, 0}, {368, 455, 0, 0}, {8, 650, 0, 0}, {381, 0, -7, 0}, {379, 346, 0, 0}}},
		{"ဿ", {{49, 1584, 0, 0}}},
		{"ာ", {{388, 594, 0, 0}, {368, 455, 0, 0}}},
		{"်", {{388, 594, 0, 0}, {381, 0, 9, -42}}},
		{"ကျွန်ုပ်", {{4, 1124, 0, 0}, {366, 257, 0, 0}, {262, 630, 0, 0}, {381, 0, 22, 0}, {209, 0, 6, 0}, {25, 676, 0, 0}, {381, 0, -36, 0}}},
		{"နိုင်ငံ", {{262, 630, 0, 0}, {369, 0, 22, 0}, {209, 0, 6, 0}, {8, 650, 0, 0}, {381, 0, -7, 0}, {8, 650, 0, 0}, {377, 0, -7, 0}}},
		{"ရှ", {{277, 679, 0, 0}, {384, 0, -79, 0}}},
		{"ကြို", {{200, 229, 0, 0}, {4, 1124, 0, 0}, {369, 0, -27, 0}, {210, 261, 0, 0}, {610, 0, 0, 0}}},
		{"ကျော်", {{372, 618, 0, 0}, {4, 1124, 0, 0}, {382, 257, 0, 0}, {368, 455, 0, 0}, {381, 0, -36, 0}}},
		{"ဥ", {{41, 661, 0, 0}}},
		{"ဦ", {{41, 661, 0, 0}, {370, 0, 0, 0}}},
		{"ပြည်", {{47, 229, 0, 0}, {25, 676, 0, 0}, {14, 1109, 0, 0}, {381, 0, -7, 0}}},
		{"စာ", {{9, 674, 0, 0}, {368, 455, 0, 0}}},
		{"ကံ့", {{4, 1124, 0, 0}, {377, 0, -27, 0}, {378, 0, -2, 0}}},
	}},
	{"noto_serif_tibetan", {
		{"ཀ", {{6, 704, 0, 0}}},
		{"ཀི", {{6, 704, 0, 0}, {1328, 0, -614, 0}}},
		{"ཀུ", {{157, 704, 0, 0}}},
		{"ཀེ", {{6, 704, 0, 0}, {1337, 0, -599, 0}}},
		{"ཀོ", {{6, 704, 0, 0}, {1341, 0, -712, 0}}},
		{"ཀྐ", {{158, 704, 0, 0}}},
		{"སྐ", {{1088, 675, 0, 0}}},
		{"བསྒྲུབས", {{27, 641, 0, 0}, {1103, 675, 0, 0}, {27, 641, 0, 0}, {43, 675, 0, 0}}},
		{"རྒྱ", {{849, 704, 0, 0}}},
		{"ཧཱུྃ", {{1180, 562, 0, 0}, {1351, 0, -511, 0}}},
		{"ཨོཾ", {{135, 801, 0, 0}, {1342, 0, -770, 0}}},
		{"བོད་", {{27, 641, 0, 0}, {1341, 0, -681, 0}, {22, 579, 0, 0}, {1261, 210, 0, 0}}},
		{"ཀཱ", {{155, 704, 0, 0}}},
		{"ཀྵ", {{46, 704, 0, 0}}},
		{"ཀ༹", {{6, 704, 0, 0}, {1324, 0, -103, 0}}},
		{"ཀྃ", {{6, 704, 0, 0}, {1351, 0, -567, 0}}},
		{"ༀ", {{135, 801, 0, 0}, {1342, 0, -770, 0}}},
		{"ི", {{1282, 550, 0, 0}, {1328, 0, -652, 0}}},
		{"ྐ", {{1282, 550, 0, 0}, {1443, 0, -651, -234}}},
		{"བཀྲ་ཤིས", {{27, 641, 0, 0}, {180, 704, 0, 0}, {1261, 140, 0, 0}, {41, 632, 0, 0}, {1328, 0, -614, 0}, {43, 675, 0, 0}}},
		{"སྐྱབས", {{1092, 675, 0, 0}, {27, 641, 0, 0}, {43, 675, 0, 0}}},
		{"ཀིུ", {{157, 704, 0, 0}, {1328, 0, -614, 0}}},
		{"ཀཱི", {{155, 704, 0, 0}, {1328, 0, -614, 0}}},
		{"ཀྲྀ", {{180, 704, 0, 0}, {1347, 0, -665, 0}}},
		{"ཀཱུ", {{156, 704, 0, 0}}},
		{"ཏོ", {{20, 568, 0, 0}, {1341, 0, -648, 0}}},
		{"ལྷ", {{1013, 686, 0, 0}}},
		{"ཟླ", {{817, 599, 0, 0}}},
		{"གྱི", {{234, 704, 0, 0}, {1328, 0, -614, 0}}},
	}},
	{"noto_sans_balinese", {
		{"ᬅ", {{9, 1110, 0, 0}}},
		{"ᬓ", {{23, 1205, 0, 0}}},
		{"ᬓᬵ", {{242, 1450, 0, 0}}},
		{"ᬓᬶ", {{23, 1205, 0, 0}, {59, 0, -369, -22}}},
		{"ᬓᬸ", {{23, 1205, 0, 0}, {61, 0, 0, 0}}},
		{"ᬓᬾ", {{67, 523, 0, 0}, {23, 1205, 0, 0}}},
		{"ᬓᭀ", {{67, 523, 0, 0}, {242, 1450, 0, 0}}},
		{"ᬓ᭄ᬓ", {{23, 1205, 0, 0}, {171, 0, 0, 0}}},
		{"ᬩᬲ", {{46, 1205, 0, 0}, {55, 982, 0, 0}}},
		{"ᬩᬮᬶ", {{46, 1205, 0, 0}, {51, 1214, 0, 0}, {59, 0, -300, -22}}},
		{"ᬓᬂ", {{23, 1205, 0, 0}, {6, 0, -504, -12}}},
		{"ᬓᬃ", {{23, 1205, 0, 0}, {7, 0, -359, -5}}},
		{"ᬓ᭄ᬭ", {{302, 1471, 0, 0}}},
		{"ᬳᬦᬘᬭᬓ", {{56, 1098, 0, 0}, {43, 1001, 0, 0}, {28, 985, 0, 0}, {50, 882, 0, 0}, {23, 1205, 0, 0}}},
		{"ᬶ", {{131, 594, 0, 0}, {59, 0, 65, 90}}},
		{"ᬓᬼ", {{23, 1205, 0, 0}, {233, 0, 0, 0}, {71, 0, -413, -14}}},
		{"ᬆ", {{10, 1352, 0, 0}}},
		{"ᬓᬄ", {{23, 1205, 0, 0}, {8, 379, 0, 0}}},
		{"ᬓ᭄ᬱ", {{23, 1205, 0, 0}, {219, 735, 0, 0}}},
		{"ᬓ᭄ᬭᬶ", {{302, 1471, 0, 0}, {59, 0, 0, 0}}},
		{"ᬓᭂ", {{23, 1205, 0, 0}, {71, 0, -413, -14}}},
		{"ᬓᭃ", {{242, 1450, 0, 0}, {71, 0, -513, -14}}},
		{"ᬓ᭄", {{23, 1205, 0, 0}, {73, 288, 0, 0}}},
	}},
	{"noto_sans_javanese", {
		{"ꦄ", {{13, 1338, 0, 0}}},
		{"ꦏ", {{24, 1221, 0, 0}}},
		{"ꦏꦶ", {{24, 1221, 0, 0}, {80, 0, -42, 10}}},
		{"ꦏꦸ", {{24, 1221, 0, 0}, {88, 0, -1, 0}}},
		{"ꦏꦺ", {{92, 677, 0, 0}, {24, 1221, 0, 0}}},
		{"ꦏꦺꦴ", {{92, 677, 0, 0}, {24, 1221, 0, 0}, {78, 413, 0, 0}}},
		{"ꦏ꧀ꦏ", {{24, 1221, 0, 0}, {257, 0, -1, 0}}},
		{"ꦏꦿ", {{162, 1465, 0, 0}}},
		{"ꦏꦾ", {{24, 1221, 0, 0}, {100, 376, 0, 0}}},
		{"ꦗꦮ", {{32, 991, 0, 0}, {57, 967, 0, 0}}},
		{"ꦲꦤꦕꦫꦏ", {{61, 1195, 0, 0}, {47, 989, 0, 0}, {30, 1043, 0, 0}, {54, 915, 0, 0}, {24, 1221, 0, 0}}},
		{"ꦏꦂ", {{24, 1221, 0, 0}, {11, 0, -250, 10}}},
		{"ꦏꦁ", {{24, 1221, 0, 0}, {10, 0, -301, 10}}},
		{"ꦧꦱꦗꦮ", {{50, 1207, 0, 0}, {60, 1088, 0, 0}, {32, 991, 0, 0}, {57, 967, 0, 0}}},
		{"ꦶ", {{8, 594, 0, 0}, {80, 0, 237, 10}}},
		{"ꦏ꧀", {{24, 1221, 0, 0}, {112, 391, 0, 0}}},
		{"ꦏꦾꦺ", {{92, 677, 0, 0}, {24, 1221, 0, 0}, {100, 376, 0, 0}}},
		{"ꦏꦿꦺꦴ", {{92, 677, 0, 0}, {162, 1465, 0, 0}, {78, 413, 0, 0}}},
		{"ꦱ꧀ꦠ", {{60, 1088, 0, 0}, {275, 0, 0, 0}}},
		{"ꦏꦼ", {{24, 1221, 0, 0}, {94, 0, -39, 10}}},
		{"ꦏꦃ", {{24, 1221, 0, 0}, {12, 353, 0, 0}}},
		{"ꦥꦼꦂ", {{48, 963, 0, 0}, {97, 0, -118, 10}}},
	}},
	{"noto_sans_sundanese", {
		{"ᮃ", {{10, 871, 0, 0}}},
		{"ᮊ", {{17, 793, 0, 0}}},
		{"ᮊᮤ", {{17, 793, 0, 0}, {46, 0, -136, 30}}},
		{"ᮊᮥ", {{17, 793, 0, 0}, {48, 0, 86, 0}}},
		{"ᮊᮦ", {{49, 375, 0, 0}, {17, 793, 0, 0}}},
		{"ᮊᮬ", {{17, 793, 0, 0}, {57, 0, 76, 0}}},
		{"ᮊ᮪ᮊ", {{17, 793, 0, 0}, {55, 264, 0, 0}, {17, 793, 0, 0}}},
		{"ᮞᮥᮔ᮪ᮓ", {{37, 797, 0, 0}, {48, 0, 63, 0}, {27, 721, 0, 0}, {55, 264, 0, 0}, {26, 712, 0, 0}}},
		{"ᮊᮁ", {{17, 793, 0, 0}, {8, 0, -170, 30}}},
		{"ᮊᮀ", {{17, 793, 0, 0}, {7, 0, -180, 30}}},
		{"ᮊᮭ", {{17, 793, 0, 0}, {58, 0, 76, 0}}},
		{"ᮊᮢ", {{17, 793, 0, 0}, {42, 0, -149, 0}}},
		{"ᮤ", {{88, 594, 0, 0}, {46, 0, -35, -151}}},
		{"ᮊᮧ", {{17, 793, 0, 0}, {50, 375, 0, 0}}},
		{"ᮊᮨ", {{17, 793, 0, 0}, {51, 0, -160, 30}}},
		{"ᮊᮩ", {{17, 793, 0, 0}, {53, 0, -160, 30}}},
		{"ᮊᮂ", {{17, 793, 0, 0}, {9, 387, 0, 0}}},
	}},
}

// syllabic_word_shape shapes a word syllable by syllable with a font, as
// shape does, with the pair across two syllables.
@(private = "file")
syllabic_word_shape :: proc(file: ^vector_font.Font_File, text: []u8, budget: ^vector_font.Layout_Budget) -> (got: [dynamic]Syllabic_Glyph, read_whole: bool) {
	got = make([dynamic]Syllabic_Glyph, context.temp_allocator)
	place := 0
	for place < len(text) {
		window, read := syllabic_window_read(text, place, file)
		if !read {
			// A joiner before a syllable is a cluster of its own, which
			// draws nothing.
			character, length, valid := text_encoding.character_decode(text, place)
			if length == 0 || !valid || !is_syllabic_hidden(character) {
				break
			}
			place += length
			continue
		}
		buffer: vector_font.Engine_Buffer
		syllabic_shape(file, &window, &buffer, budget)
		if len(got) > 0 && buffer.count > 0 {
			tag := syllabic_script_rows[window.script].tag
			got[len(got) - 1].advance += indic_pair_units(file, tag, int(got[len(got) - 1].glyph), int(buffer.glyphs[0].glyph), budget)
		}
		for glyph in buffer.glyphs[:buffer.count] {
			append(&got, Syllabic_Glyph{i32(glyph.glyph), glyph.x_advance, glyph.x_offset, glyph.y_offset})
		}
		if window.end <= place {
			break
		}
		place = window.end
	}
	return got, place == len(text)
}

// Each word, shaped syllable by syllable with the font of its script,
// gives the glyphs, the advances and the offsets of HarfBuzz.
@(test)
the_syllabic_scripts_shape_as_harfbuzz :: proc(t: ^testing.T) {
	test_state_take()
	names := make([]string, len(expected_syllabic_scripts), context.temp_allocator)
	for script, index in expected_syllabic_scripts {
		names[index] = script.font
	}
	words, script_words, missing := script_set_open(t, names)
	defer delete(words)
	defer delete(script_words)
	failed := 0
	most_per_byte := 0
	for script in expected_syllabic_scripts {
		font := Outline_Font.None
		for each in Outline_Font {
			if outline_font_name(each) == script.font {
				font = each
			}
		}
		testing.expectf(t, font != .None && font not_in missing, "%s is open", script.font)
		file := &font_at(&state.font_set, font).file
		for expected in script.words {
			text := transmute([]u8)expected.word
			budget := vector_font.layout_budget_of_text(len(text))
			got, whole := syllabic_word_shape(file, text, &budget)
			same := whole && len(got) == len(expected.glyphs)
			for glyph, index in got {
				if same && glyph != expected.glyphs[index] {
					same = false
				}
			}
			if !same {
				failed += 1
			}
			testing.expectf(t, same, "%s %s: %v, HarfBuzz: %v", script.font, expected.word, got[:], expected.glyphs)
			testing.expectf(t, !vector_font.layout_budget_spent(&budget), "%s %s: the budget is spent", script.font, expected.word)
			most_per_byte = max(most_per_byte, budget.work / max(len(text), 1))
		}
	}
	testing.expect_value(t, failed, 0)
	fmt.printfln("text_rendering: the work of the words of Khmer, Myanmar and USE: at most %d units for a byte, of a budget of %d for a byte", most_per_byte, vector_font.LAYOUT_WORK_PER_BYTE)
}

@(test)
syllable_script_and_sara_am_predicates_cover_every_script_range :: proc(t: ^testing.T) {
	in_syllable := [?]rune{
		0x0900, 0x0915, 0x0D7F, // Indic blocks
		0x0F00, 0x0FC0, 0x0FFF, // Tibetan (including Dril Bu U+0FC0)
		0x1000, 0x109F, 0xA9E0, 0xA9FF, 0xAA60, 0xAA7F, // Myanmar
		0x1780, 0x17FF, 0x19E0, 0x19FF, // Khmer
		0x1B00, 0x1B7F, // Balinese
		0x1B80, 0x1BBF, 0x1CC0, 0x1CCF, // Sundanese
		0xA980, 0xA9DF, // Javanese
	}
	for ch in in_syllable {
		testing.expectf(t, is_syllable_script(ch), "U+%04X must be a syllable script character", ch)
	}
	outside := [?]rune{
		'A', '0', 0x00E9, 0x03A9, 0x0416, 0x08FF, 0x0D80, 0x0EFF,
		0x10A0, 0x177F, 0x1800, 0x19DF, 0x1A00, 0x1AFF, 0x1BC0,
		0x1CBF, 0x1CD0, 0xA97F, 0xAA00, 0xAA5F, 0xAA80,
	}
	for ch in outside {
		testing.expectf(t, !is_syllable_script(ch), "U+%04X must not be a syllable script character", ch)
	}
	testing.expect(t, is_sara_am(SARA_AM_THAI))
	testing.expect(t, is_sara_am(SARA_AM_LAO))
	testing.expect(t, !is_sara_am(SARA_AM_THAI - 1))
	testing.expect(t, !is_sara_am(SARA_AM_THAI + 1))
	testing.expect(t, !is_sara_am(SARA_AM_LAO - 1))
	testing.expect(t, !is_sara_am(SARA_AM_LAO + 1))
}
