#+build !freestanding
package use_shaping

import "core:testing"

@(test)
use_shaping_border_words :: proc(t: ^testing.T) {
	_, ok := use_script_of_word(99)
	testing.expect_value(t, ok, false)
	sc, sc_ok := use_script_of_word(u64(Use_Script.Mongolian))
	testing.expect_value(t, sc_ok, true)
	testing.expect_value(t, sc, Use_Script.Mongolian)

	_, ok = use_category_of_word(99)
	testing.expect_value(t, ok, false)
	cat, cat_ok := use_category_of_word(u64(Use_Category.Vowel_Pre))
	testing.expect_value(t, cat_ok, true)
	testing.expect_value(t, cat, Use_Category.Vowel_Pre)

	_, ok = topographical_form_of_word(9)
	testing.expect_value(t, ok, false)
	form, form_ok := topographical_form_of_word(u64(Topographical_Form.Medial))
	testing.expect_value(t, form_ok, true)
	testing.expect_value(t, form, Topographical_Form.Medial)
}

@(test)
use_classify_all_eight_scripts :: proc(t: ^testing.T) {
	Check :: struct {
		cp:  rune,
		sc:  Use_Script,
		cat: Use_Category,
	}
	cases := [?]Check{
		{0x0D9A, .Sinhala,   .Base},      // Sinhala KA
		{0x0DD9, .Sinhala,   .Vowel_Pre}, // Sinhala kombuva
		{0x0DCA, .Sinhala,   .Halant},    // Sinhala al-lakuna
		{0x0E81, .Lao,       .Base},      // Lao KO
		{0x0EC0, .Lao,       .Vowel_Pre}, // Lao vowel sign E
		{0x0EC8, .Lao,       .Tone_Mark}, // Lao mai ek
		{0x1780, .Khmer,     .Base},      // Khmer KA
		{0x17D2, .Khmer,     .Virama},    // Khmer coeng
		{0x17C1, .Khmer,     .Vowel_Pre}, // Khmer vowel sign E
		{0x1000, .Myanmar,   .Base},      // Myanmar KA
		{0x1031, .Myanmar,   .Vowel_Pre}, // Myanmar vowel sign E
		{0x1039, .Myanmar,   .Virama},    // Myanmar virama
		{0x103A, .Myanmar,   .Halant},    // Myanmar asat
		{0x0F40, .Tibetan,   .Base},      // Tibetan KA
		{0x0F90, .Tibetan,   .Vowel_Below}, // Tibetan subjoined KA
		{0x0F72, .Tibetan,   .Vowel_Above}, // Tibetan vowel sign I
		{0xA98F, .Javanese,  .Base},      // Javanese KA
		{0xA9BA, .Javanese,  .Vowel_Pre}, // Javanese taling
		{0xA9C0, .Javanese,  .Halant},    // Javanese pangkon
		{0x1B13, .Balinese,  .Base},      // Balinese KA
		{0x1B3E, .Balinese,  .Vowel_Pre}, // Balinese taling
		{0x1B44, .Balinese,  .Virama},    // Balinese adeg adeg
		{0x1820, .Mongolian, .Base},      // Mongolian A
		{0xA840, .Mongolian, .Base},      // Phags-Pa KA
		{0x200D, .None,      .Joiner},    // ZWJ
	}
	for c in cases {
		sc, cat := use_classify_codepoint(c.cp)
		testing.expect_value(t, sc, c.sc)
		testing.expect_value(t, cat, c.cat)
	}
}

@(test)
use_prebase_vowel_reordering_and_conjuncts :: proc(t: ^testing.T) {
	// Khmer KA + COENG + TA + VOWEL_E (pre-base) -> VOWEL_E moves before KA.
	khmer := [4]rune{0x1780, 0x17D2, 0x178F, 0x17C1}
	glyphs: [8]Use_Glyph_Item
	clusters: [4]Use_Cluster
	gn, cn, ref := use_shape_clusters(khmer[:], glyphs[:], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.None)
	testing.expect_value(t, gn, 4)
	testing.expect_value(t, cn, 1)
	testing.expect_value(t, clusters[0].script, Use_Script.Khmer)
	testing.expect_value(t, clusters[0].base_offset, u16(1))
	testing.expect_value(t, glyphs[0].codepoint, rune(0x17C1))
	testing.expect_value(t, glyphs[1].codepoint, rune(0x1780))
	testing.expect_value(t, glyphs[2].codepoint, rune(0x17D2))
	testing.expect_value(t, glyphs[3].codepoint, rune(0x178F))

	// Myanmar KA + MEDIAL_RA (pre-base) + VOWEL_E (pre-base) keeps both pre-base items in relative order.
	myanmar := [3]rune{0x1000, 0x103C, 0x1031}
	gn, cn, ref = use_shape_clusters(myanmar[:], glyphs[:], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.None)
	testing.expect_value(t, cn, 1)
	testing.expect_value(t, glyphs[0].codepoint, rune(0x103C))
	testing.expect_value(t, glyphs[1].codepoint, rune(0x1031))
	testing.expect_value(t, glyphs[2].codepoint, rune(0x1000))
	testing.expect_value(t, clusters[0].base_offset, u16(2))
}

@(test)
use_topographical_mongolian_and_phags_pa :: proc(t: ^testing.T) {
	// 3 Mongolian letters -> Initial, Medial, Final.
	word := [3]rune{0x1820, 0x1828, 0x1822}
	forms: [8]Topographical_Form
	n, ref := use_resolve_topographical(word[:], forms[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.None)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, forms[0], Topographical_Form.Initial)
	testing.expect_value(t, forms[1], Topographical_Form.Medial)
	testing.expect_value(t, forms[2], Topographical_Form.Final)

	// Single letter -> Isolated; ZWJ forces Initial/Final; ZWNJ breaks join; FVS is transparent.
	single := [1]rune{0x1820}
	n, ref = use_resolve_topographical(single[:], forms[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.None)
	testing.expect_value(t, forms[0], Topographical_Form.Isolated)

	with_zwnj_and_fvs := [5]rune{0x1820, 0x180B, 0x200C, 0x200D, 0xA840}
	n, ref = use_resolve_topographical(with_zwnj_and_fvs[:], forms[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.None)
	testing.expect_value(t, forms[0], Topographical_Form.Isolated) // FVS transparent, then ZWNJ breaks join
	testing.expect_value(t, forms[4], Topographical_Form.Final)    // Preceded by ZWJ -> Final
}

@(test)
use_shaping_refusals_and_zero_mutation :: proc(t: ^testing.T) {
	glyphs: [4]Use_Glyph_Item
	clusters: [4]Use_Cluster
	glyphs[0].codepoint = 'Z'
	clusters[0].count = 77

	// Empty input refused with zero mutation.
	gn, cn, ref := use_shape_clusters({}, glyphs[:], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.Empty_Input)
	testing.expect_value(t, gn, 0)
	testing.expect_value(t, cn, 0)
	testing.expect_value(t, glyphs[0].codepoint, rune('Z'))
	testing.expect_value(t, clusters[0].count, u16(77))

	// Surrogate and out-of-range codepoints refused.
	bad_surr := [1]rune{0xD800}
	_, _, ref = use_shape_clusters(bad_surr[:], glyphs[:], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.Bad_Codepoint)

	bad_high := [1]rune{0x110000}
	_, _, ref = use_shape_clusters(bad_high[:], glyphs[:], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.Bad_Codepoint)

	// Undersized glyph or cluster output buffer refused without mutation.
	two := [2]rune{0x0D9A, 0x0DD9}
	_, _, ref = use_shape_clusters(two[:], glyphs[:1], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.Output_Too_Small)
	testing.expect_value(t, glyphs[0].codepoint, rune('Z'))

	_, _, ref = use_shape_clusters(two[:], glyphs[:], clusters[:0])
	testing.expect_value(t, ref, Use_Shaping_Refusal.Output_Too_Small)
	testing.expect_value(t, glyphs[0].codepoint, rune('Z'))

	// Oversized cluster (> USE_CLUSTER_MAX_ITEMS = 16) refused with zero mutation.
	oversized: [USE_CLUSTER_MAX_ITEMS + 1]rune
	oversized[0] = 0x0F40 // Tibetan KA
	for i in 1 ..< len(oversized) {
		oversized[i] = 0x0F90 // subjoined KA
	}
	big_glyphs: [USE_CLUSTER_MAX_ITEMS + 1]Use_Glyph_Item
	big_glyphs[0].codepoint = 'Q'
	_, _, ref = use_shape_clusters(oversized[:], big_glyphs[:], clusters[:])
	testing.expect_value(t, ref, Use_Shaping_Refusal.Cluster_Too_Large)
	testing.expect_value(t, big_glyphs[0].codepoint, rune('Q'))
}
