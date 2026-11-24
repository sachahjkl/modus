package fuzz

import "core:testing"

// fuzz_shaping_plain must return false whenever a text contains a character
// shaped by a syllable shaper (Indic, Khmer, Myanmar, Tibetan, Balinese,
// Javanese, Sundanese), Thai/Lao SARA AM, combining marks, RTL, Arabic
// joining, or invisible format controls, and true on plain text.
@(test)
text_shaping_plain_excludes_syllable_scripts_and_sara_am :: proc(t: ^testing.T) {
	non_plain := [?]string{
		"\u0FC0", // Tibetan Symbol Dril Bu (finding from seed 9182121319585591620)
		"abc\u0FC0def",
		"\u1780", // Khmer Letter Ka
		"\u1000", // Myanmar Letter Ka
		"\u1B05", // Balinese Letter Akara
		"\uA984", // Javanese Letter A
		"\u1B83", // Sundanese Letter A
		"\u0915", // Devanagari Letter Ka
		"a\u0E33", // Thai SARA AM
		"a\u0EB3", // Lao SARA AM
		"e\u0301", // Combining acute accent
		"\u05D0", // Hebrew Alef (RTL)
		"\u0628", // Arabic Beh (joining)
		"a\u200Db", // Zero Width Joiner
	}
	for sample in non_plain {
		testing.expectf(t, !fuzz_shaping_plain(transmute([]u8)sample), "%q must not be classified as plain text", sample)
	}

	plain := [?]string{
		"",
		"Hello, world! 0123456789",
		"AV To Wa \xC3\xA9 \xCE\xA9 \xD0\x96 \xE2\x94\x8C\xE2\x94\x80",
		"bad\xFF\xFEutf8",
	}
	for sample in plain {
		testing.expectf(t, fuzz_shaping_plain(transmute([]u8)sample), "%q must be classified as plain text", sample)
	}
}
