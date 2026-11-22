package console

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import "modus:contract/language_tag"
import "modus:contract/settings"

// The console is the border of the text of the principal for a language
// tag (src/md/features/interface_language.md, "1. The identity of a
// language"): language(text) reads the tag once, with
// language_tag.tag_read, and gives the record. A line then passes the
// record to an export, as settings.set_languages([language("fr-CA"),
// language("en")]), and no process reads the text of the tag again.

// The description of the record is the description that the tool writes
// for language_tag.Locale: the same name, the same fields in the same
// order, sizes and signs. An export takes a record only when the two
// descriptions are equal (module.records_equal), so the console copies the
// bytes of the record and describes them in the form of the tool.
LOCALE_RECORD_NAME :: "Locale"

#assert(offset_of(language_tag.Locale, language) == 0 && offset_of(language_tag.Locale, script) == 8 && offset_of(language_tag.Locale, region) == 12)
#assert(offset_of(language_tag.Locale, variant_first) == 16 && offset_of(language_tag.Locale, variant_second) == 24)
#assert(offset_of(language_tag.Locale, calendar) == 32 && offset_of(language_tag.Locale, collation) == 37)
#assert(offset_of(language_tag.Locale, region_override) == 38 && offset_of(language_tag.Locale, reserved) == 44)
#assert(size_of(language_tag.Calendar) == 1 && size_of(language_tag.Numbering_System) == 1 && size_of(language_tag.First_Day) == 1)
#assert(size_of(language_tag.Hour_Cycle) == 1 && size_of(language_tag.Measurement_System) == 1 && size_of(language_tag.Collation) == 1)

// locale_byte_column gives the column of a keyword of the record: the tool
// describes an enum of u8 as an unsigned Integer of 1 byte.
locale_byte_column :: proc "contextless" (name: string) -> Column {
	return {name = name, type = .Integer, detail = 1, unsigned = true}
}

// locale_value gives the Record value of a locale.
locale_value :: proc "contextless" (locale: language_tag.Locale) -> Value {
	columns := [13]Column {
		text_column("language", u32(size_of(language_tag.Locale{}.language))),
		text_column("script", u32(size_of(language_tag.Locale{}.script))),
		text_column("region", u32(size_of(language_tag.Locale{}.region))),
		text_column("variant_first", u32(size_of(language_tag.Locale{}.variant_first))),
		text_column("variant_second", u32(size_of(language_tag.Locale{}.variant_second))),
		locale_byte_column("calendar"),
		locale_byte_column("numbering_system"),
		locale_byte_column("first_day"),
		locale_byte_column("hour_cycle"),
		locale_byte_column("measurement_system"),
		locale_byte_column("collation"),
		text_column("region_override", u32(size_of(language_tag.Locale{}.region_override))),
		{name = "reserved", type = .Integer, detail = u32(size_of(language_tag.Locale{}.reserved)), unsigned = true},
	}
	table, made := made_table(LOCALE_RECORD_NAME, columns[:])
	// A size other than the size of the record is a fault of the columns
	// above: the bytes would mean other fields.
	if !made || table.size != size_of(language_tag.Locale) {
		return fail("language: the line has no room for the record")
	}
	row := made_row(&table)
	if row != nil {
		copied := locale
		intrinsics.mem_copy_non_overlapping(raw_data(row), &copied, size_of(copied))
	}
	return made_record(&table, "language")
}

// first_language gives the first language of the language list of the
// settings page, or the source language when the console maps no settings
// page, when the page is refused, or when the list is empty: a principal
// with no list reads the source language.
first_language :: proc "contextless" () -> language_tag.Locale {
	if .Settings_Page not_in fixed_addresses.ranges_mapped(&ctx.values) {
		return language_tag.source_locale()
	}
	choice, ok := settings.read((^settings.Page)(uintptr(settings.PAGE_ADDRESS)))
	if !ok || choice.languages.count == 0 {
		return language_tag.source_locale()
	}
	return choice.languages.locales[0]
}

// language_command reads a language tag into its record. With no argument,
// or an empty text, it gives the first language of the principal.
language_command :: proc "contextless" (arguments: []Value) -> Value {
	text := len(arguments) > 0 ? arguments[0].text : ""
	if text == "" {
		return locale_value(first_language())
	}
	locale, problem, place := language_tag.tag_read(text)
	if problem != .None {
		// A text past the capacity is not quoted: the sentence has room for
		// the reason, not for the whole text.
		if len(text) > language_tag.LOCALE_TEXT_CAPACITY {
			return fail("language: the tag of ", i64(len(text)), " bytes is refused at byte ", i64(place), ": ", language_tag.locale_problem_text(problem))
		}
		return fail("language: the tag \"", text, "\" is refused at byte ", i64(place), ": ", language_tag.locale_problem_text(problem))
	}
	return locale_value(locale)
}
