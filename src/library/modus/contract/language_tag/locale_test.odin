#+build !freestanding
package language_tag

import "core:testing"

// read_written reads a text, and gives the canonical text of its record.
@(private = "file")
read_written :: proc(t: ^testing.T, text: string, buffer: []u8) -> (written: string, locale: Locale) {
	problem: Locale_Problem
	locale, problem, _ = tag_read(text)
	testing.expectf(t, problem == .None, "tag_read(%q) refuses: %v", text, problem)
	ok: bool
	written, ok = tag_write(locale, buffer)
	testing.expectf(t, ok, "tag_write of %q refuses", text)
	testing.expectf(t, locale_valid(locale) == .None, "the record of %q is refused: %v", text, locale_valid(locale))
	return written, locale
}

@(test)
tag_read_refuses_each_text_out_of_the_record :: proc(t: ^testing.T) {
	long: [LOCALE_TEXT_CAPACITY + 1]u8
	for &character in long {
		character = 'a'
	}
	for index := 2; index < len(long); index += 3 {
		long[index] = '-'
	}
	Refusal :: struct {
		text:    string,
		problem: Locale_Problem,
		place:   int,
	}
	refusals := [?]Refusal {
		{"", .Empty, 0},
		{string(long[:]), .Too_Long, LOCALE_TEXT_CAPACITY},
		{"en_US", .Not_Ascii, 2},
		{"fr-é", .Not_Ascii, 3},
		{"en--US", .Empty_Subtag, 3},
		{"-en", .Empty_Subtag, 0},
		{"en-", .Empty_Subtag, 3},
		{"en-abcdefghi", .Long_Subtag, 3},
		{"e", .Malformed, 0},
		{"abcd", .Malformed, 0},
		{"i-klingon", .Malformed, 0},
		{"1en", .Malformed, 0},
		{"en-US-CA", .Malformed, 6},
		{"en-Latn-Cyrl", .Malformed, 8},
		{"zh-yue", .Extended_Language, 3},
		{"x-private", .Private_Use, 0},
		{"en-x-twain", .Private_Use, 3},
		{"en-u-ca-roc-x-a", .Private_Use, 12},
		{"en-t-ja", .Extension_Not_U, 3},
		{"en-a-bbb", .Extension_Not_U, 3},
		{"en-u-ca-roc-t-ja", .Extension_Not_U, 12},
		{"en-u-ca-roc-u-hc-h23", .Malformed, 12},
		{"de-1901-1996-1997", .Third_Variant, 13},
		{"de-1901-1901", .Duplicate_Variant, 8},
		{"en-u", .Malformed, 4},
		{"en-u-foo-ca-roc", .Attribute, 5},
		{"en-u-tz-usnyc", .Unknown_Keyword, 5},
		{"en-u-1a-roc", .Unknown_Keyword, 5},
		{"en-u-a1-roc", .Malformed, 5},
		{"en-u-ca", .Keyword_Without_Value, 5},
		{"en-u-ca-hc-h23", .Keyword_Without_Value, 5},
		{"en-u-ca-roc-ca-roc", .Duplicate_Keyword, 12},
		{"en-u-ca-julian", .Unknown_Value, 5},
		{"en-u-ca-gregory-extra", .Unknown_Value, 5},
		{"en-u-ms-imperial", .Unknown_Value, 5},
		{"en-u-rg-u", .Keyword_Without_Value, 5},
		{"en-u-rg-us", .Keyword_Without_Value, 5},
		{"en-u-rg-uszzzzz", .Bad_Region_Override, 5},
		{"en-u-rg-123zzz", .Bad_Region_Override, 5},
	}
	for refusal in refusals {
		locale, problem, place := tag_read(refusal.text)
		testing.expectf(t, problem == refusal.problem && place == refusal.place, "tag_read(%q) gives %v at %d, not %v at %d", refusal.text, problem, place, refusal.problem, refusal.place)
		testing.expectf(t, locale == Locale{}, "tag_read(%q) refuses and gives a record", refusal.text)
	}
}

@(test)
tag_read_gives_the_canonical_form :: proc(t: ^testing.T) {
	buffer: [LOCALE_TEXT_CAPACITY]u8
	Form :: struct {
		text, canonical: string,
	}
	forms := [?]Form {
		{"und", "und"},
		{"UND", "und"},
		{"fr", "fr"},
		{"FR-ca", "fr-CA"},
		{"zh-hant-tw", "zh-Hant-TW"},
		{"es-419", "es-419"},
		{"und-Latn", "und-Latn"},
		{"iw", "he"},
		{"IN-id", "id-ID"},
		{"sl-rozaj-biske", "sl-biske-rozaj"},
		{"de-CH-1996", "de-CH-1996"},
		{"ar-EG-U-NU-LATN", "ar-EG-u-nu-latn"},
		{"en-u-nu-latn-ca-gregory", "en-u-ca-gregory-nu-latn"},
		{"en-u-rg-uszzzz-hc-h23-fw-mon", "en-u-fw-mon-hc-h23-rg-uszzzz"},
		{"ar-u-ca-islamic-umalqura", "ar-u-ca-islamic-umalqura"},
		{"de-u-co-phonebk-ms-uksystem", "de-u-co-phonebk-ms-uksystem"},
		{"abcdefgh", "abcdefgh"},
	}
	for form in forms {
		written, _ := read_written(t, form.text, buffer[:])
		testing.expectf(t, written == form.canonical, "%q writes %q, not %q", form.text, written, form.canonical)
		// The canonical text reads to the same text.
		again, _ := read_written(t, written, buffer[:])
		testing.expect_value(t, again, written)
	}
	root, problem, _ := tag_read("und")
	testing.expect_value(t, problem, Locale_Problem.None)
	testing.expect(t, root == Locale{}, "und is the record of all zeros")
	_, locale := read_written(t, "zh-Hant-TW", buffer[:])
	testing.expect_value(t, locale_language(&locale), "zh")
	testing.expect_value(t, locale_script(&locale), "Hant")
	testing.expect_value(t, locale_region(&locale), "TW")
}

@(test)
tag_write_holds_the_longest_text_and_refuses_a_short_buffer :: proc(t: ^testing.T) {
	buffer: [LOCALE_TEXT_CAPACITY]u8
	longest := "abcdefgh-Latn-419-1abcdefg-2abcdefg-u-ca-islamic-umalqura-co-searchjl-fw-mon-hc-h23-ms-uksystem-nu-mathsans-rg-uszzzz"
	written, _ := read_written(t, longest, buffer[:])
	testing.expect_value(t, written, longest)
	testing.expect_value(t, len(longest), 117)
	locale, _, _ := tag_read(longest)
	_, fits := tag_write(locale, buffer[:len(longest) - 1])
	testing.expect(t, !fits, "a buffer one byte short holds no text")
	_, fits = tag_write(locale, nil)
	testing.expect(t, !fits, "no buffer holds no text")
}

@(test)
each_keyword_member_reads_and_writes_its_word :: proc(t: ^testing.T) {
	buffer: [LOCALE_TEXT_CAPACITY]u8
	text: [LOCALE_TEXT_CAPACITY]u8
	check :: proc(t: ^testing.T, key, word: string, text, buffer: []u8) -> Locale {
		count := copy(text, "en-u-")
		count += copy(text[count:], key)
		count += copy(text[count:], "-")
		count += copy(text[count:], word)
		written, locale := read_written(t, string(text[:count]), buffer)
		testing.expect_value(t, written, string(text[:count]))
		return locale
	}
	for member in Calendar {
		if member != .Absent {
			testing.expect_value(t, check(t, "ca", calendar_word(member), text[:], buffer[:]).calendar, member)
		}
	}
	for member in Collation {
		if member != .Absent {
			testing.expect_value(t, check(t, "co", collation_word(member), text[:], buffer[:]).collation, member)
		}
	}
	for member in First_Day {
		if member != .Absent {
			testing.expect_value(t, check(t, "fw", first_day_word(member), text[:], buffer[:]).first_day, member)
		}
	}
	for member in Hour_Cycle {
		if member != .Absent {
			testing.expect_value(t, check(t, "hc", hour_cycle_word(member), text[:], buffer[:]).hour_cycle, member)
		}
	}
	for member in Measurement_System {
		if member != .Absent {
			testing.expect_value(t, check(t, "ms", measurement_system_word(member), text[:], buffer[:]).measurement_system, member)
		}
	}
	for member in Numbering_System {
		if member != .Absent {
			testing.expect_value(t, check(t, "nu", numbering_system_word(member), text[:], buffer[:]).numbering_system, member)
		}
	}
}

@(test)
locale_valid_refuses_each_damaged_record :: proc(t: ^testing.T) {
	testing.expect_value(t, locale_valid({}), Locale_Problem.None)
	good, _, _ := tag_read("fr-Latn-CA-1694acad-1606nict-u-ca-gregory-rg-frzzzz")
	testing.expect_value(t, locale_valid(good), Locale_Problem.None)
	Damage :: struct {
		damage:  proc(locale: ^Locale),
		problem: Locale_Problem,
	}
	damages := [?]Damage {
		{proc(locale: ^Locale) {locale.language[0] = 'F'}, .Bad_Language},
		{proc(locale: ^Locale) {locale.language[5] = 'x'}, .Bad_Language},
		{proc(locale: ^Locale) {locale.language = {'f', 'r', 'a', 'n', 0, 0, 0, 0}}, .Bad_Language},
		{proc(locale: ^Locale) {locale.language = {'f', 0, 0, 0, 0, 0, 0, 0}}, .Bad_Language},
		{proc(locale: ^Locale) {locale.language = {'i', 'w', 0, 0, 0, 0, 0, 0}}, .Bad_Language},
		{proc(locale: ^Locale) {locale.language = {'u', 'n', 'd', 0, 0, 0, 0, 0}}, .Bad_Language},
		{proc(locale: ^Locale) {locale.language = {'f', '1', 0, 0, 0, 0, 0, 0}}, .Bad_Language},
		{proc(locale: ^Locale) {locale.script = {'l', 'a', 't', 'n'}}, .Bad_Script},
		{proc(locale: ^Locale) {locale.script = {'L', 'a', 't', 0}}, .Bad_Script},
		{proc(locale: ^Locale) {locale.region = {'c', 'a', 0, 0}}, .Bad_Region},
		{proc(locale: ^Locale) {locale.region = {'C', 'A', 'N', 0}}, .Bad_Region},
		{proc(locale: ^Locale) {locale.region = {'C', 0, 0, 'A'}}, .Bad_Region},
		{proc(locale: ^Locale) {locale.region = {'1', '2', '3', '4'}}, .Bad_Region},
		{proc(locale: ^Locale) {locale.variant_first = {}}, .Bad_Variant},
		{proc(locale: ^Locale) {locale.variant_second = locale.variant_first}, .Bad_Variant},
		{proc(locale: ^Locale) {locale.variant_second = {'1', '0', '0', '0', 0, 0, 0, 0}}, .Bad_Variant},
		{proc(locale: ^Locale) {locale.variant_first = {'a', 'b', 'c', 'd', 0, 0, 0, 0}}, .Bad_Variant},
		{proc(locale: ^Locale) {locale.region_override = {'f', 'r', 0, 0, 0, 0}}, .Bad_Region_Override},
		{proc(locale: ^Locale) {locale.region_override = {'1', '2', '3', 'z', 'z', 'z'}}, .Bad_Region_Override},
		{proc(locale: ^Locale) {(^u8)(&locale.calendar)^ = u8(max(Calendar)) + 1}, .Bad_Keyword_Word},
		{proc(locale: ^Locale) {(^u8)(&locale.collation)^ = 255}, .Bad_Keyword_Word},
		{proc(locale: ^Locale) {(^u8)(&locale.first_day)^ = u8(max(First_Day)) + 1}, .Bad_Keyword_Word},
		{proc(locale: ^Locale) {(^u8)(&locale.hour_cycle)^ = u8(max(Hour_Cycle)) + 1}, .Bad_Keyword_Word},
		{proc(locale: ^Locale) {(^u8)(&locale.measurement_system)^ = u8(max(Measurement_System)) + 1}, .Bad_Keyword_Word},
		{proc(locale: ^Locale) {(^u8)(&locale.numbering_system)^ = u8(max(Numbering_System)) + 1}, .Bad_Keyword_Word},
		{proc(locale: ^Locale) {locale.reserved = 1}, .Reserved_Not_Zero},
	}
	buffer: [LOCALE_TEXT_CAPACITY]u8
	for damage, index in damages {
		damaged := good
		damage.damage(&damaged)
		testing.expectf(t, locale_valid(damaged) == damage.problem, "damage %d gives %v, not %v", index, locale_valid(damaged), damage.problem)
		_, written := tag_write(damaged, buffer[:])
		testing.expectf(t, !written, "tag_write writes the damaged record %d", index)
	}
}
