// Strict BCP 47 syntax parser, pinned CLDR validity tables, and canonical
// alias mapping (src/md/features/interface_language.md).
package interface_language_pack

import "modus:contract/enum_word"

// Format property: canonical BCP 47 tags handled by modus stay within 64 ASCII bytes.
CLDR_TAG_TEXT_LIMIT :: 64
// Format property: fixed-width subtag fields matching language_tag.Locale.
CLDR_LANGUAGE_BYTES :: 8
CLDR_SCRIPT_BYTES :: 4
CLDR_REGION_BYTES :: 4
CLDR_VARIANT_BYTES :: 8
// Format property: at most two variant subtags per locale record.
CLDR_VARIANT_CAPACITY :: 2

// Closed refusal set for BCP 47 / CLDR language tag validation.
Tag_Refusal :: enum u8 {
	None                = 0,
	Empty               = 1,
	Too_Long            = 2,
	Bad_Character       = 3,
	Bad_Language        = 4,
	Bad_Script          = 5,
	Bad_Region          = 6,
	Unknown_Subtag      = 7,
	Duplicate_Variant   = 8,
	Too_Many_Variants   = 9,
	Private_Use_Refused = 10,
	Extension_Refused   = 11,
	Non_Canonical       = 12,
	Buffer_Too_Small    = 13,
}

tag_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Tag_Refusal, ok: bool) {
	return enum_word.member_of_word(Tag_Refusal, word)
}

// Canonicalized BCP 47 / CLDR language tag record (zero-initialized is `und`).
Cldr_Language_Tag :: struct {
	language:      [CLDR_LANGUAGE_BYTES]u8,
	script:        [CLDR_SCRIPT_BYTES]u8,
	region:        [CLDR_REGION_BYTES]u8,
	variants:      [CLDR_VARIANT_CAPACITY][CLDR_VARIANT_BYTES]u8,
	variant_count: u8,
	reserved:      [3]u8,
}
#assert(size_of(Cldr_Language_Tag) == 36)

@(private = "file")
Tag_Alias :: struct {
	deprecated: string,
	canonical:  string,
}

// Pinned CLDR 49 / RFC 5646 deprecated primary language aliases.
@(private = "file", rodata)
LANGUAGE_ALIASES := [?]Tag_Alias{
	{deprecated = "iw", canonical = "he"},
	{deprecated = "in", canonical = "id"},
	{deprecated = "ji", canonical = "yi"},
	{deprecated = "mo", canonical = "ro"},
	{deprecated = "jw", canonical = "jv"},
	{deprecated = "tl", canonical = "fil"},
}

// Pinned CLDR 49 deprecated region aliases.
@(private = "file", rodata)
REGION_ALIASES := [?]Tag_Alias{
	{deprecated = "BU", canonical = "MM"},
	{deprecated = "DD", canonical = "DE"},
	{deprecated = "YU", canonical = "RS"},
	{deprecated = "ZR", canonical = "CD"},
	{deprecated = "TP", canonical = "TL"},
}

// Pinned CLDR 49 valid primary language subtags supported by modus packs.
@(private = "file", rodata)
VALID_LANGUAGES := [?]string{
	"ar", "bn", "de", "el", "en", "es", "fil", "fr", "gu", "he", "hi",
	"id", "it", "ja", "jv", "km", "kn", "ko", "ml", "my", "nl", "or",
	"pa", "pl", "pt", "ro", "ru", "sr", "sv", "ta", "te", "th", "tr",
	"uk", "und", "vi", "yi", "zh",
}

// Pinned CLDR 49 valid ISO 15924 script subtags.
@(private = "file", rodata)
VALID_SCRIPTS := [?]string{
	"Arab", "Bali", "Beng", "Cyrl", "Deva", "Grek", "Gujr", "Guru",
	"Hang", "Hani", "Hans", "Hant", "Hebr", "Java", "Khmr", "Knda",
	"Latn", "Mlym", "Mymr", "Orya", "Sund", "Taml", "Telu", "Thai",
	"Tibt",
}

// Pinned CLDR 49 valid ISO 3166-1 / UN M.49 region subtags.
@(private = "file", rodata)
VALID_REGIONS := [?]string{
	"001", "419", "BE", "BR", "CA", "CD", "CH", "CN", "DE", "EG", "ES",
	"FR", "GB", "HK", "ID", "IL", "IN", "IT", "JP", "KR", "MM", "MX",
	"NL", "PL", "PT", "RO", "RS", "RU", "SA", "SE", "SG", "TH", "TL",
	"TR", "TW", "UA", "US", "VN",
}

@(private = "file")
is_ascii_alpha :: proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private = "file")
is_ascii_digit :: proc "contextless" (ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

@(private = "file")
ascii_lower :: proc "contextless" (ch: u8) -> u8 {
	return (ch >= 'A' && ch <= 'Z') ? ch + ('a' - 'A') : ch
}

@(private = "file")
ascii_upper :: proc "contextless" (ch: u8) -> u8 {
	return (ch >= 'a' && ch <= 'z') ? ch - ('a' - 'A') : ch
}

@(private = "file")
slice_trimmed_zero :: proc "contextless" (buf: []u8) -> string {
	count := 0
	for count < len(buf) && buf[count] != 0 {
		count += 1
	}
	return string(buf[:count])
}

@(private = "file")
in_list :: proc "contextless" (needle: string, list: []string) -> bool {
	for item in list {
		if item == needle {
			return true
		}
	}
	return false
}

@(private = "file")
canonicalize_language :: proc "contextless" (lang: string) -> string {
	for alias in LANGUAGE_ALIASES {
		if alias.deprecated == lang {
			return alias.canonical
		}
	}
	return lang
}

@(private = "file")
canonicalize_region :: proc "contextless" (region: string) -> string {
	for alias in REGION_ALIASES {
		if alias.deprecated == region {
			return alias.canonical
		}
	}
	return region
}

@(private = "file")
is_deprecated_language :: proc "contextless" (lang: string) -> bool {
	for alias in LANGUAGE_ALIASES {
		if alias.deprecated == lang {
			return true
		}
	}
	return false
}

@(private = "file")
is_deprecated_region :: proc "contextless" (region: string) -> bool {
	for alias in REGION_ALIASES {
		if alias.deprecated == region {
			return true
		}
	}
	return false
}

@(private = "file")
variant_compare :: proc "contextless" (a, b: [CLDR_VARIANT_BYTES]u8) -> int {
	for i in 0 ..< CLDR_VARIANT_BYTES {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

// cldr_tag_parse parses a BCP 47 tag, maps pinned CLDR aliases (`iw`->`he`,
// `in`->`id`, `ji`->`yi`, `mo`->`ro`, etc.), normalizes subtag casing, and
// refuses malformed or unknown subtags.
cldr_tag_parse :: proc "contextless" (text: string) -> (tag: Cldr_Language_Tag, refusal: Tag_Refusal) {
	if len(text) == 0 {
		return {}, .Empty
	}
	if len(text) > CLDR_TAG_TEXT_LIMIT {
		return {}, .Too_Long
	}

	// Split hyphen-separated subtags without allocating.
	// Format property: a valid 64-byte tag holds at most 8 subtags.
	SUBTAG_LIMIT :: 8
	subtags: [SUBTAG_LIMIT]string
	subtag_count := 0
	start := 0
	for index := 0; index <= len(text); index += 1 {
		at_end := index == len(text)
		if !at_end {
			ch := text[index]
			if ch != '-' && !is_ascii_alpha(ch) && !is_ascii_digit(ch) {
				return {}, .Bad_Character
			}
		}
		if at_end || text[index] == '-' {
			if index == start {
				return {}, .Bad_Character
			}
			if subtag_count >= SUBTAG_LIMIT {
				return {}, .Too_Long
			}
			subtags[subtag_count] = text[start:index]
			subtag_count += 1
			start = index + 1
		}
	}

	// Subtag 0: primary language (2..3 or 5..8 ASCII letters; reject `x` private-use).
	lang_raw := subtags[0]
	if len(lang_raw) == 1 && (lang_raw[0] == 'x' || lang_raw[0] == 'X') {
		return {}, .Private_Use_Refused
	}
	if len(lang_raw) < 2 || len(lang_raw) > CLDR_LANGUAGE_BYTES || len(lang_raw) == 4 {
		return {}, .Bad_Language
	}
	lang_buf: [CLDR_LANGUAGE_BYTES]u8
	for i in 0 ..< len(lang_raw) {
		if !is_ascii_alpha(lang_raw[i]) {
			return {}, .Bad_Language
		}
		lang_buf[i] = ascii_lower(lang_raw[i])
	}
	lang_canon := canonicalize_language(string(lang_buf[:len(lang_raw)]))
	valid_langs := VALID_LANGUAGES
	if !in_list(lang_canon, valid_langs[:]) {
		return {}, .Unknown_Subtag
	}
	if lang_canon != "und" {
		for i in 0 ..< len(lang_canon) {
			tag.language[i] = lang_canon[i]
		}
	}

	cursor := 1
	// Optional script subtag: 4 ASCII letters, normalized to Titlecase.
	if cursor < subtag_count && len(subtags[cursor]) == 4 {
		all_alpha := true
		for i in 0 ..< 4 {
			if !is_ascii_alpha(subtags[cursor][i]) {
				all_alpha = false
				break
			}
		}
		if all_alpha {
			script_buf: [CLDR_SCRIPT_BYTES]u8
			script_buf[0] = ascii_upper(subtags[cursor][0])
			for i in 1 ..< 4 {
				script_buf[i] = ascii_lower(subtags[cursor][i])
			}
			valid_scripts := VALID_SCRIPTS
			if !in_list(string(script_buf[:]), valid_scripts[:]) {
				return {}, .Bad_Script
			}
			tag.script = script_buf
			cursor += 1
		}
	}

	// Optional region subtag: 2 ASCII letters or 3 ASCII digits.
	if cursor < subtag_count {
		reg_raw := subtags[cursor]
		if len(reg_raw) == 2 && is_ascii_alpha(reg_raw[0]) && is_ascii_alpha(reg_raw[1]) {
			reg_buf: [CLDR_REGION_BYTES]u8
			reg_buf[0] = ascii_upper(reg_raw[0])
			reg_buf[1] = ascii_upper(reg_raw[1])
			reg_canon := canonicalize_region(string(reg_buf[:2]))
			valid_regions := VALID_REGIONS
			if !in_list(reg_canon, valid_regions[:]) {
				return {}, .Bad_Region
			}
			tag.region[0] = reg_canon[0]
			tag.region[1] = reg_canon[1]
			cursor += 1
		} else if len(reg_raw) == 3 && is_ascii_digit(reg_raw[0]) && is_ascii_digit(reg_raw[1]) && is_ascii_digit(reg_raw[2]) {
			valid_regions := VALID_REGIONS
			if !in_list(reg_raw, valid_regions[:]) {
				return {}, .Bad_Region
			}
			tag.region[0] = reg_raw[0]
			tag.region[1] = reg_raw[1]
			tag.region[2] = reg_raw[2]
			cursor += 1
		}
	}

	// Remaining subtags: variants (5..8 alnum, or 4 alnum starting with digit).
	// Singletons (`x`, `t`, `u`, etc.) are refused explicitly.
	for cursor < subtag_count {
		sub := subtags[cursor]
		if len(sub) == 1 {
			if sub[0] == 'x' || sub[0] == 'X' {
				return {}, .Private_Use_Refused
			}
			return {}, .Extension_Refused
		}
		is_variant := (len(sub) >= 5 && len(sub) <= CLDR_VARIANT_BYTES) || (len(sub) == 4 && is_ascii_digit(sub[0]))
		if !is_variant {
			return {}, .Unknown_Subtag
		}
		if int(tag.variant_count) >= CLDR_VARIANT_CAPACITY {
			return {}, .Too_Many_Variants
		}
		var_buf: [CLDR_VARIANT_BYTES]u8
		for i in 0 ..< len(sub) {
			var_buf[i] = ascii_lower(sub[i])
		}
		for prev in 0 ..< int(tag.variant_count) {
			if tag.variants[prev] == var_buf {
				return {}, .Duplicate_Variant
			}
		}
		tag.variants[tag.variant_count] = var_buf
		tag.variant_count += 1
		cursor += 1
	}

	// Keep variants in canonical byte order.
	if tag.variant_count == 2 && variant_compare(tag.variants[0], tag.variants[1]) > 0 {
		tag.variants[0], tag.variants[1] = tag.variants[1], tag.variants[0]
	}

	return tag, .None
}

// cldr_tag_format writes the canonical BCP 47 representation of tag into out.
cldr_tag_format :: proc "contextless" (tag: Cldr_Language_Tag, out: []u8) -> (written: int, refusal: Tag_Refusal) {
	append_text :: proc "contextless" (dst: []u8, pos: ^int, part: string) -> bool {
		if len(part) > len(dst) - pos^ {
			return false
		}
		for i in 0 ..< len(part) {
			dst[pos^ + i] = part[i]
		}
		pos^ += len(part)
		return true
	}

	lang_arr := tag.language
	script_arr := tag.script
	region_arr := tag.region
	lang := slice_trimmed_zero(lang_arr[:])
	if len(lang) == 0 {
		lang = "und"
	}
	pos := 0
	if !append_text(out, &pos, lang) {
		return 0, .Buffer_Too_Small
	}
	script := slice_trimmed_zero(script_arr[:])
	if len(script) > 0 {
		if !append_text(out, &pos, "-") || !append_text(out, &pos, script) {
			return 0, .Buffer_Too_Small
		}
	}
	region := slice_trimmed_zero(region_arr[:])
	if len(region) > 0 {
		if !append_text(out, &pos, "-") || !append_text(out, &pos, region) {
			return 0, .Buffer_Too_Small
		}
	}
	for i in 0 ..< int(min(tag.variant_count, u8(CLDR_VARIANT_CAPACITY))) {
		var_arr := tag.variants[i]
		variant := slice_trimmed_zero(var_arr[:])
		if len(variant) > 0 {
			if !append_text(out, &pos, "-") || !append_text(out, &pos, variant) {
				return 0, .Buffer_Too_Small
			}
		}
	}
	return pos, .None
}

// cldr_tag_record_valid checks a Cldr_Language_Tag received across a border:
// refuses non-canonical casing, deprecated aliases, unsorted variants, or non-zero padding.
cldr_tag_record_valid :: proc "contextless" (tag: Cldr_Language_Tag) -> Tag_Refusal {
	if tag.variant_count > CLDR_VARIANT_CAPACITY || tag.reserved != {} {
		return .Non_Canonical
	}
	lang_arr := tag.language
	lang := slice_trimmed_zero(lang_arr[:])
	for i in len(lang) ..< CLDR_LANGUAGE_BYTES {
		if tag.language[i] != 0 {
			return .Non_Canonical
		}
	}
	if len(lang) > 0 {
		if lang == "und" || is_deprecated_language(lang) {
			return .Non_Canonical
		}
		for i in 0 ..< len(lang) {
			if lang[i] < 'a' || lang[i] > 'z' {
				return .Non_Canonical
			}
		}
		valid_langs := VALID_LANGUAGES
		if !in_list(lang, valid_langs[:]) {
			return .Unknown_Subtag
		}
	}

	script_arr := tag.script
	script := slice_trimmed_zero(script_arr[:])
	for i in len(script) ..< CLDR_SCRIPT_BYTES {
		if tag.script[i] != 0 {
			return .Non_Canonical
		}
	}
	if len(script) > 0 {
		valid_scripts := VALID_SCRIPTS
		if len(script) != 4 || !in_list(script, valid_scripts[:]) {
			return .Bad_Script
		}
	}

	region_arr := tag.region
	region := slice_trimmed_zero(region_arr[:])
	for i in len(region) ..< CLDR_REGION_BYTES {
		if tag.region[i] != 0 {
			return .Non_Canonical
		}
	}
	if len(region) > 0 {
		valid_regions := VALID_REGIONS
		if is_deprecated_region(region) || !in_list(region, valid_regions[:]) {
			return .Bad_Region
		}
	}

	for i in int(tag.variant_count) ..< CLDR_VARIANT_CAPACITY {
		if tag.variants[i] != {} {
			return .Non_Canonical
		}
	}
	if tag.variant_count == 2 && variant_compare(tag.variants[0], tag.variants[1]) >= 0 {
		return .Non_Canonical
	}
	return .None
}
