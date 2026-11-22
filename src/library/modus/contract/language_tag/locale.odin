// The locale: a language tag read once into a typed record
// (src/md/features/interface_language.md, "1. The identity of a
// language"). A tag crosses a border as this record, never as text, so no
// reader parses the tag that another wrote. tag_read is the one border of
// the text; tag_write gives the canonical text of a record: the canonical
// Unicode locale identifier of UTS #35 part 1, with the case of each
// subtag, the preferred language of a deprecated one, the variants in
// order and the keywords in the order of their keys.
//
// The record is 48 bytes, and all zeros is the root locale `und`, so a
// page and a record that hold no locale keep their zero.
//
// What the record refuses: an extended language subtag (`zh-yue`: the
// record has no field for it, and its preferred form is the extended
// language alone), a private use (`-x-`), an extension other than `u`,
// an attribute of `u`, a keyword of `u` outside `ca`, `co`, `fw`, `hc`,
// `ms`, `nu` and `rg`, a third variant, a repeated variant or keyword.
package language_tag

import "modus:contract/enum_word"

LOCALE_TEXT_CAPACITY :: 128 // The bytes of the text of a locale at most: its longest canonical text is 117 bytes.
LANGUAGE_BYTES :: 8 // A language subtag of 2 to 8 letters.
SCRIPT_BYTES :: 4 // A script subtag of 4 letters.
REGION_BYTES :: 4 // A region of 2 letters or 3 digits.
VARIANT_BYTES :: 8 // A variant of 4 to 8 letters and digits.
REGION_OVERRIDE_BYTES :: 6 // The value of `rg`: a region of 2 letters and a suffix of 1 to 4 letters and digits (`uszzzz`).

// Locale: a language tag as a record. Each text field is lower case ASCII
// (the script in title case, the region in upper case), then zeros. The
// sizes of the text fields are numbers, not the constants above: the tool
// reads a Text field of a record as [N]u8 with a number N.
Locale :: struct {
	language:           [8]u8, // 2 or 3 letters, or 5 to 8; zeros: the root locale, `und`.
	script:             [4]u8, // `Latn`, or zeros.
	region:             [4]u8, // `CA` or `419`, or zeros.
	variant_first:      [8]u8, // The first variant in the order of their bytes, or zeros.
	variant_second:     [8]u8, // The second variant, after the first, or zeros.
	calendar:           Calendar, // The keyword `ca`.
	numbering_system:   Numbering_System, // The keyword `nu`.
	first_day:          First_Day, // The keyword `fw`.
	hour_cycle:         Hour_Cycle, // The keyword `hc`.
	measurement_system: Measurement_System, // The keyword `ms`.
	collation:          Collation, // The keyword `co`.
	region_override:    [6]u8, // The keyword `rg`, or zeros.
	reserved:           u32, // 0.
}
#assert(size_of(Locale) == 48)
#assert(size_of(Locale{}.language) == LANGUAGE_BYTES && size_of(Locale{}.script) == SCRIPT_BYTES && size_of(Locale{}.region) == REGION_BYTES)
#assert(size_of(Locale{}.variant_first) == VARIANT_BYTES && size_of(Locale{}.variant_second) == VARIANT_BYTES && size_of(Locale{}.region_override) == REGION_OVERRIDE_BYTES)

// Why tag_read refuses a text, or locale_valid a record.
Locale_Problem :: enum u8 {
	None                  = 0, // The text or the record names a locale.
	Empty                 = 1, // The text has no byte.
	Too_Long              = 2, // The text has more than LOCALE_TEXT_CAPACITY bytes.
	Not_Ascii             = 3, // A byte that is no ASCII letter, no digit and no '-'.
	Empty_Subtag          = 4, // A '-' at the start, at the end, or after another '-'.
	Long_Subtag           = 5, // A subtag of more than SUBTAG_CAPACITY characters.
	Malformed             = 6, // The subtags keep no form of RFC 5646, section 2.1, or of UTS #35 part 1.
	Extended_Language     = 7, // An extended language subtag: `zh-yue`.
	Private_Use           = 8, // A private use: `en-x-twain`.
	Extension_Not_U       = 9, // An extension other than `u`: `en-t-ja`.
	Third_Variant         = 10, // More than two variants.
	Duplicate_Variant     = 11, // One variant twice.
	Attribute             = 12, // An attribute of the extension `u`: `en-u-foo-ca-roc`.
	Unknown_Keyword       = 13, // A key of `u` that the record has no field for: `en-u-tz-usnyc`.
	Keyword_Without_Value = 14, // A key of `u` with no value: `en-u-ca`.
	Duplicate_Keyword     = 15, // One key of `u` twice.
	Unknown_Value         = 16, // A value that names no member of the enum of its key: `en-u-ca-julian`.
	Bad_Region_Override   = 17, // A value of `rg` that is not 2 letters and 1 to 4 letters or digits.
	Bad_Language          = 18, // A record: its language is not 2, 3 or 5 to 8 lower case letters and zeros, or is a deprecated language.
	Bad_Script            = 19, // A record: its script is not a capital and 3 lower case letters, or zeros.
	Bad_Region            = 20, // A record: its region is not 2 capitals or 3 digits, then zeros.
	Bad_Variant           = 21, // A record: a variant of a wrong form, a second variant with no first, or two variants out of order.
	Bad_Keyword_Word      = 22, // A record: a byte of a keyword that names no member of its enum.
	Reserved_Not_Zero     = 23, // A record: its reserved bytes are not zero.
}

// The keys of the extension `u` that the record holds, in the order of
// their keys: the order of the canonical text.
@(private)
Keyword :: enum u8 {
	Calendar,
	Collation,
	First_Day,
	Hour_Cycle,
	Measurement_System,
	Numbering_System,
	Region_Override,
}

@(private)
keyword_key :: proc "contextless" (keyword: Keyword) -> string {
	switch keyword {
	case .Calendar:
		return "ca"
	case .Collation:
		return "co"
	case .First_Day:
		return "fw"
	case .Hour_Cycle:
		return "hc"
	case .Measurement_System:
		return "ms"
	case .Numbering_System:
		return "nu"
	case .Region_Override:
		return "rg"
	}
	return ""
}

// language_preferred gives the preferred language of a deprecated one of
// the registry of RFC 5646 (`iw` is `he`). The other aliases of CLDR come
// with its validity data.
@(private)
language_preferred :: proc "contextless" (language: string) -> (preferred: string, deprecated: bool) {
	switch language {
	case "in":
		return "id", true
	case "iw":
		return "he", true
	case "ji":
		return "yi", true
	case "jw":
		return "jv", true
	case "mo":
		return "ro", true
	}
	return language, false
}

@(private)
lower_letter :: proc "contextless" (character: u8) -> bool {
	return character >= 'a' && character <= 'z'
}

@(private)
upper_letter :: proc "contextless" (character: u8) -> bool {
	return character >= 'A' && character <= 'Z'
}

@(private)
lower_of :: proc "contextless" (character: u8) -> u8 {
	return upper_letter(character) ? character + ('a' - 'A') : character
}

@(private)
upper_of :: proc "contextless" (character: u8) -> u8 {
	return lower_letter(character) ? character - ('a' - 'A') : character
}

// field_text gives the text of a field: its bytes before the first zero.
field_text :: proc "contextless" (field: []u8) -> string {
	for index in 0 ..< len(field) {
		if field[index] == 0 {
			return string(field[:index])
		}
	}
	return string(field)
}

// field_tail_zero says if each byte of a field after its text is zero: a
// record holds no byte of unknown value.
@(private)
field_tail_zero :: proc "contextless" (field: []u8) -> bool {
	for index in len(field_text(field)) ..< len(field) {
		if field[index] != 0 {
			return false
		}
	}
	return true
}

@(private)
field_put :: proc "contextless" (field: []u8, text: string) {
	for index in 0 ..< len(field) {
		field[index] = index < len(text) ? text[index] : 0
	}
}

// member_named gives the member of a keyword enum whose word is value.
@(private)
member_named :: proc "contextless" ($Enum: typeid, value: string, word_of: proc "contextless" (member: Enum) -> string) -> (Enum, bool) {
	for member in Enum {
		if u8(member) != 0 && word_of(member) == value {
			return member, true
		}
	}
	absent: Enum
	return absent, false
}

// variant_form says if a subtag in lower case has the form of a variant:
// 5 to 8 letters and digits, or a digit and 3 letters and digits.
@(private)
variant_form :: proc "contextless" (subtag: string) -> bool {
	if len(subtag) < 4 || len(subtag) > VARIANT_BYTES || len(subtag) == 4 && !digit(subtag[0]) {
		return false
	}
	for index in 0 ..< len(subtag) {
		if !lower_letter(subtag[index]) && !digit(subtag[index]) {
			return false
		}
	}
	return true
}

// region_override_form says if a value in lower case has the form of the
// value of `rg` that the record holds.
@(private)
region_override_form :: proc "contextless" (value: string) -> bool {
	if len(value) < 3 || len(value) > REGION_OVERRIDE_BYTES || !lower_letter(value[0]) || !lower_letter(value[1]) {
		return false
	}
	for index in 2 ..< len(value) {
		if !lower_letter(value[index]) && !digit(value[index]) {
			return false
		}
	}
	return true
}

// The value of one keyword while tag_read reads it: its subtags, joined
// by '-'.
@(private)
Keyword_Value :: struct {
	keyword: Keyword,
	open:    bool, // A key was read, and its value is not set on the record yet.
	place:   int, // The offset of the key in the text.
	bytes:   [LOCALE_TEXT_CAPACITY]u8,
	count:   int,
}

// keyword_set sets the value of an open keyword on the record.
@(private)
keyword_set :: proc "contextless" (locale: ^Locale, value: ^Keyword_Value) -> Locale_Problem {
	if !value.open {
		return .None
	}
	value.open = false
	if value.count == 0 {
		return .Keyword_Without_Value
	}
	text := string(value.bytes[:value.count])
	ok := false
	switch value.keyword {
	case .Calendar:
		locale.calendar, ok = member_named(Calendar, text, calendar_word)
	case .Collation:
		locale.collation, ok = member_named(Collation, text, collation_word)
	case .First_Day:
		locale.first_day, ok = member_named(First_Day, text, first_day_word)
	case .Hour_Cycle:
		locale.hour_cycle, ok = member_named(Hour_Cycle, text, hour_cycle_word)
	case .Measurement_System:
		locale.measurement_system, ok = member_named(Measurement_System, text, measurement_system_word)
	case .Numbering_System:
		locale.numbering_system, ok = member_named(Numbering_System, text, numbering_system_word)
	case .Region_Override:
		if !region_override_form(text) {
			return .Bad_Region_Override
		}
		field_put(locale.region_override[:], text)
		ok = true
	}
	return ok ? .None : .Unknown_Value
}

// tag_read reads the text of a language tag into its record, in any case:
// `fr`, `fr-CA`, `zh-Hant-TW`, `ar-EG-u-nu-latn`. On a refusal the record
// is all zeros, and place is the offset of the byte or of the subtag at
// fault. `und` alone is the root locale.
tag_read :: proc "contextless" (text: string) -> (locale: Locale, problem: Locale_Problem, place: int) {
	switch {
	case len(text) == 0:
		return {}, .Empty, 0
	case len(text) > LOCALE_TEXT_CAPACITY:
		return {}, .Too_Long, LOCALE_TEXT_CAPACITY
	}
	for index in 0 ..< len(text) {
		character := text[index]
		if !letter(character) && !digit(character) && character != '-' {
			return {}, .Not_Ascii, index
		}
	}
	part := Part.Language
	first := true
	in_extension := false // After `-u-`: the subtags are keys and values.
	variant_count := 0
	keywords_seen: bit_set[Keyword]
	value: Keyword_Value
	start := 0
	for start <= len(text) {
		end := start
		for end < len(text) && text[end] != '-' {
			end += 1
		}
		if end == start {
			return {}, .Empty_Subtag, start
		}
		if end - start > SUBTAG_CAPACITY {
			return {}, .Long_Subtag, start
		}
		lowered: [SUBTAG_CAPACITY]u8
		for index in start ..< end {
			lowered[index - start] = lower_of(text[index])
		}
		subtag := string(lowered[:end - start])
		switch {
		case first:
			first = false
			switch {
			case subtag == "x":
				return {}, .Private_Use, start
			case all_letters(subtag) && (len(subtag) == 2 || len(subtag) == 3 || len(subtag) >= 5):
				if subtag != "und" {
					preferred, _ := language_preferred(subtag)
					field_put(locale.language[:], preferred)
				}
			case:
				return {}, .Malformed, start
			}
		case in_extension:
			switch {
			case len(subtag) == 1:
				if found := keyword_set(&locale, &value); found != .None {
					return {}, found, value.place
				}
				switch subtag {
				case "x":
					return {}, .Private_Use, start
				case "u":
					return {}, .Malformed, start
				}
				return {}, .Extension_Not_U, start
			case len(subtag) == 2:
				if !letter(subtag[1]) {
					return {}, .Malformed, start
				}
				if found := keyword_set(&locale, &value); found != .None {
					return {}, found, value.place
				}
				keyword: Keyword
				known := false
				for each in Keyword {
					if keyword_key(each) == subtag {
						keyword, known = each, true
					}
				}
				if !known {
					return {}, .Unknown_Keyword, start
				}
				if keyword in keywords_seen {
					return {}, .Duplicate_Keyword, start
				}
				keywords_seen += {keyword}
				value = {keyword = keyword, open = true, place = start}
			case !value.open && value.count == 0 && keywords_seen == {}:
				// A subtag of 3 to 8 characters before the first key.
				return {}, .Attribute, start
			case !value.open:
				// A value after a key whose value was already set: no
				// key of the record takes it.
				return {}, .Malformed, start
			case:
				if value.count > 0 {
					value.bytes[value.count] = '-'
					value.count += 1
				}
				value.count += copy(value.bytes[value.count:], subtag)
			}
		case len(subtag) == 1:
			switch subtag {
			case "x":
				return {}, .Private_Use, start
			case "u":
				in_extension = true
				part = .Extension
			case:
				return {}, .Extension_Not_U, start
			}
		case part == .Language && len(subtag) == 3 && all_letters(subtag):
			return {}, .Extended_Language, start
		case part < .Script && len(subtag) == 4 && all_letters(subtag):
			part = .Script
			locale.script = {upper_of(subtag[0]), subtag[1], subtag[2], subtag[3]}
		case part < .Region && (len(subtag) == 2 && all_letters(subtag) || len(subtag) == 3 && all_digits(subtag)):
			part = .Region
			for index in 0 ..< len(subtag) {
				locale.region[index] = upper_of(subtag[index])
			}
		case part <= .Variant && variant_form(subtag):
			part = .Variant
			switch variant_count {
			case 0:
				field_put(locale.variant_first[:], subtag)
			case 1:
				if field_text(locale.variant_first[:]) == subtag {
					return {}, .Duplicate_Variant, start
				}
				field_put(locale.variant_second[:], subtag)
			case:
				return {}, .Third_Variant, start
			}
			variant_count += 1
		case:
			return {}, .Malformed, start
		}
		if end == len(text) {
			break
		}
		start = end + 1
	}
	if in_extension {
		// `en-u`: a singleton with no keyword after it.
		if keywords_seen == {} {
			return {}, .Malformed, len(text)
		}
		if found := keyword_set(&locale, &value); found != .None {
			return {}, found, value.place
		}
	}
	// The canonical form holds the variants in the order of their bytes.
	if variant_count == 2 && field_text(locale.variant_second[:]) < field_text(locale.variant_first[:]) {
		locale.variant_first, locale.variant_second = locale.variant_second, locale.variant_first
	}
	return locale, .None, 0
}

// locale_valid is the border of a record that another process wrote: a
// record of a settings page, of a kept record, of a table argument. It
// says why the record names no locale in its canonical form, or None.
locale_valid :: proc "contextless" (locale: Locale) -> Locale_Problem {
	record := locale
	text_fields := [?][]u8{record.language[:], record.script[:], record.region[:], record.variant_first[:], record.variant_second[:], record.region_override[:]}
	text_problems := [?]Locale_Problem{.Bad_Language, .Bad_Script, .Bad_Region, .Bad_Variant, .Bad_Variant, .Bad_Region_Override}
	for field, index in text_fields {
		if !field_tail_zero(field) {
			return text_problems[index]
		}
	}
	language := field_text(record.language[:])
	if len(language) != 0 {
		if len(language) < 2 || len(language) == 4 {
			return .Bad_Language
		}
		for index in 0 ..< len(language) {
			if !lower_letter(language[index]) {
				return .Bad_Language
			}
		}
		if _, deprecated := language_preferred(language); deprecated || language == "und" {
			return .Bad_Language
		}
	}
	script := field_text(record.script[:])
	if len(script) != 0 && (len(script) != SCRIPT_BYTES || !upper_letter(script[0]) || !lower_letter(script[1]) || !lower_letter(script[2]) || !lower_letter(script[3])) {
		return .Bad_Script
	}
	region := field_text(record.region[:])
	switch len(region) {
	case 0:
	case 2:
		if !upper_letter(region[0]) || !upper_letter(region[1]) {
			return .Bad_Region
		}
	case 3:
		if !all_digits(region) {
			return .Bad_Region
		}
	case:
		return .Bad_Region
	}
	variant_first, variant_second := field_text(record.variant_first[:]), field_text(record.variant_second[:])
	if len(variant_first) != 0 && !variant_form(variant_first) || len(variant_second) != 0 && (len(variant_first) == 0 || !variant_form(variant_second) || variant_second <= variant_first) {
		return .Bad_Variant
	}
	if override := field_text(record.region_override[:]); len(override) != 0 && !region_override_form(override) {
		return .Bad_Region_Override
	}
	// A byte of the record can hold any value: each keyword goes through
	// the border of its enum.
	_, calendar_ok := enum_word.member_of_word(Calendar, u64(transmute(u8)record.calendar))
	_, numbering_ok := enum_word.member_of_word(Numbering_System, u64(transmute(u8)record.numbering_system))
	_, first_day_ok := enum_word.member_of_word(First_Day, u64(transmute(u8)record.first_day))
	_, hour_cycle_ok := enum_word.member_of_word(Hour_Cycle, u64(transmute(u8)record.hour_cycle))
	_, measurement_ok := enum_word.member_of_word(Measurement_System, u64(transmute(u8)record.measurement_system))
	_, collation_ok := enum_word.member_of_word(Collation, u64(transmute(u8)record.collation))
	if !calendar_ok || !numbering_ok || !first_day_ok || !hour_cycle_ok || !measurement_ok || !collation_ok {
		return .Bad_Keyword_Word
	}
	if record.reserved != 0 {
		return .Reserved_Not_Zero
	}
	return .None
}

// The bytes of a text that tag_write builds.
@(private)
Text_Writer :: struct {
	buffer: []u8,
	count:  int,
	fits:   bool,
}

@(private)
text_put :: proc "contextless" (writer: ^Text_Writer, text: string) {
	if !writer.fits || len(text) > len(writer.buffer) - writer.count {
		writer.fits = false
		return
	}
	writer.count += copy(writer.buffer[writer.count:], text)
}

@(private)
keyword_put :: proc "contextless" (writer: ^Text_Writer, keyword: Keyword, value: string, extension_started: ^bool) {
	if value == "" {
		return
	}
	if !extension_started^ {
		text_put(writer, "-u")
		extension_started^ = true
	}
	text_put(writer, "-")
	text_put(writer, keyword_key(keyword))
	text_put(writer, "-")
	text_put(writer, value)
}

// tag_write writes the canonical text of a record in buffer: `fr-CA`,
// `und` for the root locale, the keywords of `u` in the order of their
// keys. ok is false for a record that locale_valid refuses, or a buffer
// that does not hold the text; a buffer of LOCALE_TEXT_CAPACITY bytes
// holds each text.
tag_write :: proc "contextless" (locale: Locale, buffer: []u8) -> (text: string, ok: bool) {
	if locale_valid(locale) != .None {
		return "", false
	}
	record := locale
	writer := Text_Writer{buffer = buffer, fits = true}
	language := field_text(record.language[:])
	text_put(&writer, language == "" ? "und" : language)
	subtags := [?]string{field_text(record.script[:]), field_text(record.region[:]), field_text(record.variant_first[:]), field_text(record.variant_second[:])}
	for subtag in subtags {
		if subtag != "" {
			text_put(&writer, "-")
			text_put(&writer, subtag)
		}
	}
	started := false
	keyword_put(&writer, .Calendar, calendar_word(record.calendar), &started)
	keyword_put(&writer, .Collation, collation_word(record.collation), &started)
	keyword_put(&writer, .First_Day, first_day_word(record.first_day), &started)
	keyword_put(&writer, .Hour_Cycle, hour_cycle_word(record.hour_cycle), &started)
	keyword_put(&writer, .Measurement_System, measurement_system_word(record.measurement_system), &started)
	keyword_put(&writer, .Numbering_System, numbering_system_word(record.numbering_system), &started)
	keyword_put(&writer, .Region_Override, field_text(record.region_override[:]), &started)
	if !writer.fits {
		return "", false
	}
	return string(buffer[:writer.count]), true
}

// locale_language, locale_script and locale_region give the text of a
// subtag of a record: "" when the record has none.
locale_language :: proc "contextless" (locale: ^Locale) -> string {
	return field_text(locale.language[:])
}

locale_script :: proc "contextless" (locale: ^Locale) -> string {
	return field_text(locale.script[:])
}

locale_region :: proc "contextless" (locale: ^Locale) -> string {
	return field_text(locale.region[:])
}
