#+build !freestanding
#+build !modus
package locale_cldr

import "core:testing"

@(test)
cldr_locales_plurals_messages_and_azerty_keyboard :: proc(t: ^testing.T) {
	_, bad_l := locale_id_of_word(99)
	testing.expect(t, !bad_l)
	_, bad_k := keyboard_layout_of_word(99)
	testing.expect(t, !bad_k)

	en := locale_data(.En_US)
	fr := locale_data(.Fr_FR)
	testing.expect_value(t, en.months[1], "February")
	testing.expect_value(t, fr.months[1], "février")
	testing.expect_value(t, fr.numbers.decimal_sep, u8(','))

	// CLDR cardinal plurals: 0 is .Other in English, .One in French; 2_000_000 is .Many in French.
	testing.expect_value(t, cldr_cardinal_plural(.En_US, 0), Plural_Category.Other)
	testing.expect_value(t, cldr_cardinal_plural(.Fr_FR, 0), Plural_Category.One)
	testing.expect_value(t, cldr_cardinal_plural(.Fr_FR, 2_000_000), Plural_Category.Many)

	testing.expect_value(t, message_text(.En_US, .Powerbox_Allow), "Allow")
	testing.expect_value(t, message_text(.Fr_FR, .Powerbox_Allow), "Autoriser")

	// Physical Q key (0x14) produces 'q' on QWERTY and 'a' on AZERTY; '2' (0x1F) produces 'é'.
	testing.expect_value(t, cldr_key_rune(.En_US_Qwerty, 0x14, false), rune('q'))
	testing.expect_value(t, cldr_key_rune(.Fr_FR_Azerty, 0x14, false), rune('a'))
	testing.expect_value(t, cldr_key_rune(.Fr_FR_Azerty, 0x1F, false), rune('é'))
}
