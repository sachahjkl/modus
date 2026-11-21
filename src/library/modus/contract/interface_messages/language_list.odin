// Language preference lists, RFC 4647 Lookup fallback resolution, and CLDR
// cardinal plural rules (src/md/features/interface_language.md).
//
// This package is a freestanding contract package: it imports base and
// contract packages only, calls no kernel operation, and allocates no memory.
package interface_messages

import "modus:contract/language_tag"

// Maximum number of preferred languages held in one Language_List.
LANGUAGE_LIST_CAPACITY :: 8

// Maximum byte length of a single canonical BCP 47 language tag.
LANGUAGE_TAG_CAPACITY :: language_tag.TAG_CAPACITY

// Closed set of outcomes from building or validating a Language_List.
Language_List_Status :: enum u32 {
	Ok                 = 0,
	Empty_List         = 1,
	Too_Many_Languages = 2,
	Invalid_Tag        = 3,
	Non_Canonical_Tag  = 4,
	Duplicate_Tag      = 5,
}

// One fixed-capacity canonical BCP 47 tag stored inside a Language_List.
Language_Tag_Entry :: struct {
	bytes:  [LANGUAGE_TAG_CAPACITY]u8,
	length: u8,
}

// Ordered list of preferred languages for a principal, holding between 1 and
// LANGUAGE_LIST_CAPACITY distinct canonical BCP 47 tags.
Language_List :: struct {
	count:   u8,
	entries: [LANGUAGE_LIST_CAPACITY]Language_Tag_Entry,
}

// Closed set of CLDR cardinal plural categories (UTS #35 part 3).
Plural_Category :: enum u8 {
	Zero  = 0,
	One   = 1,
	Two   = 2,
	Few   = 3,
	Many  = 4,
	Other = 5,
}

// language_list_build constructs a validated Language_List from canonical
// BCP 47 tags. It refuses empty lists, more than LANGUAGE_LIST_CAPACITY tags,
// malformed tags, non-canonical tags, and duplicate tags.
language_list_build :: proc "contextless" (tags: []string) -> (list: Language_List, status: Language_List_Status, failing_index: int) {
	if len(tags) == 0 {
		return {}, .Empty_List, 0
	}
	if len(tags) > LANGUAGE_LIST_CAPACITY {
		return {}, .Too_Many_Languages, LANGUAGE_LIST_CAPACITY
	}
	for tag, index in tags {
		problem := language_tag.canonical_check(tag)
		switch problem {
		case .None:
		case .Not_Canonical:
			return {}, .Non_Canonical_Tag, index
		case .Empty, .Too_Long, .Not_Ascii, .Empty_Subtag, .Long_Subtag, .Malformed:
			return {}, .Invalid_Tag, index
		}
		for earlier in 0 ..< index {
			if tags[earlier] == tag {
				return {}, .Duplicate_Tag, index
			}
		}
		raw := transmute([]u8)tag
		for byte_index in 0 ..< len(raw) {
			list.entries[index].bytes[byte_index] = raw[byte_index]
		}
		list.entries[index].length = u8(len(raw))
	}
	list.count = u8(len(tags))
	return list, .Ok, 0
}

// language_list_validate checks a Language_List received across a border:
// count in 1..LANGUAGE_LIST_CAPACITY, every active tag canonical with zeroed
// trailing bytes, and no duplicate tags.
language_list_validate :: proc "contextless" (list: ^Language_List) -> (status: Language_List_Status, failing_index: int) {
	if list == nil || list.count == 0 {
		return .Empty_List, 0
	}
	if int(list.count) > LANGUAGE_LIST_CAPACITY {
		return .Too_Many_Languages, LANGUAGE_LIST_CAPACITY
	}
	count := int(list.count)
	for index in 0 ..< count {
		entry := &list.entries[index]
		length := int(entry.length)
		if length == 0 || length > LANGUAGE_TAG_CAPACITY {
			return .Invalid_Tag, index
		}
		for padding_index in length ..< LANGUAGE_TAG_CAPACITY {
			if entry.bytes[padding_index] != 0 {
				return .Invalid_Tag, index
			}
		}
		tag := string(entry.bytes[:length])
		problem := language_tag.canonical_check(tag)
		switch problem {
		case .None:
		case .Not_Canonical:
			return .Non_Canonical_Tag, index
		case .Empty, .Too_Long, .Not_Ascii, .Empty_Subtag, .Long_Subtag, .Malformed:
			return .Invalid_Tag, index
		}
		for earlier in 0 ..< index {
			earlier_entry := &list.entries[earlier]
			earlier_tag := string(earlier_entry.bytes[:earlier_entry.length])
			if earlier_tag == tag {
				return .Duplicate_Tag, index
			}
		}
	}
	return .Ok, 0
}

// language_list_tag returns the canonical tag at index inside list.
language_list_tag :: proc "contextless" (list: ^Language_List, index: int) -> (tag: string, ok: bool) {
	if list == nil || index < 0 || index >= int(list.count) || int(list.count) > LANGUAGE_LIST_CAPACITY {
		return "", false
	}
	length := int(list.entries[index].length)
	if length == 0 || length > LANGUAGE_TAG_CAPACITY {
		return "", false
	}
	return string(list.entries[index].bytes[:length]), true
}

// language_list_resolve resolves a preference list against available_tags
// using RFC 4647 section 3.4 Lookup: for each preferred tag in order, it
// checks the tag and then each shorter prefix produced by lookup_shorter
// before advancing to the next preferred tag. Non-canonical entries in
// available_tags are ignored.
language_list_resolve :: proc "contextless" (list: ^Language_List, available_tags: []string) -> (matched_index: int, matched_tag: string, found: bool) {
	status, _ := language_list_validate(list)
	if status != .Ok || len(available_tags) == 0 {
		return -1, "", false
	}
	count := int(list.count)
	for list_index in 0 ..< count {
		candidate, tag_ok := language_list_tag(list, list_index)
		if !tag_ok {
			continue
		}
		for {
			for available, available_index in available_tags {
				if language_tag.canonical_check(available) != .None {
					continue
				}
				if available == candidate {
					return available_index, available, true
				}
			}
			shorter, has_shorter := language_tag.lookup_shorter(candidate)
			if !has_shorter {
				break
			}
			candidate = shorter
		}
	}
	return -1, "", false
}

// plural_category_from_name parses a CLDR plural category keyword.
plural_category_from_name :: proc "contextless" (name: string) -> (category: Plural_Category, ok: bool) {
	switch name {
	case "zero":
		return .Zero, true
	case "one":
		return .One, true
	case "two":
		return .Two, true
	case "few":
		return .Few, true
	case "many":
		return .Many, true
	case "other":
		return .Other, true
	}
	return .Other, false
}

// plural_category_name returns the canonical CLDR keyword of a Plural_Category.
plural_category_name :: proc "contextless" (category: Plural_Category) -> string {
	switch category {
	case .Zero:
		return "zero"
	case .One:
		return "one"
	case .Two:
		return "two"
	case .Few:
		return "few"
	case .Many:
		return "many"
	case .Other:
		return "other"
	}
	return "other"
}

// primary_language_subtag returns the first subtag of a BCP 47 tag.
primary_language_subtag :: proc "contextless" (locale_tag: string) -> string {
	for index in 0 ..< len(locale_tag) {
		if locale_tag[index] == '-' {
			return locale_tag[:index]
		}
	}
	return locale_tag
}

// region_subtag_of_locale returns the 2-letter or 3-digit region subtag of a
// canonical BCP 47 tag, or "" when no region subtag is present.
@(private = "file")
region_subtag_of_locale :: proc "contextless" (locale_tag: string) -> string {
	start := 0
	subtag_index := 0
	for index := 0; index <= len(locale_tag); index += 1 {
		if index < len(locale_tag) && locale_tag[index] != '-' {
			continue
		}
		subtag := locale_tag[start:index]
		if subtag_index > 0 {
			if len(subtag) == 1 {
				// Extensions and private use stop before any further region.
				return ""
			}
			if len(subtag) == 2 && subtag[0] >= 'A' && subtag[0] <= 'Z' && subtag[1] >= 'A' && subtag[1] <= 'Z' {
				return subtag
			}
			if len(subtag) == 3 && subtag[0] >= '0' && subtag[0] <= '9' && subtag[1] >= '0' && subtag[1] <= '9' && subtag[2] >= '0' && subtag[2] <= '9' {
				return subtag
			}
		}
		subtag_index += 1
		start = index + 1
	}
	return ""
}

// integer_magnitude converts a signed 64-bit integer to its unsigned magnitude
// without overflowing on min(i64).
@(private)
integer_magnitude :: proc "contextless" (value: i64) -> u64 {
	if value < 0 {
		return u64(-(value + 1)) + 1
	}
	return u64(value)
}

// plural_category_for_unsigned evaluates the CLDR cardinal plural rule for an
// unsigned integer under locale_tag (UTS #35 part 3, v = 0). Unknown tags fall
// back to .Other.
plural_category_for_unsigned :: proc "contextless" (locale_tag: string, value: u64) -> Plural_Category {
	if language_tag.canonical_check(locale_tag) != .None {
		return .Other
	}
	language := primary_language_subtag(locale_tag)
	mod10 := value % 10
	mod100 := value % 100

	switch language {
	case "en", "de", "nl", "sv", "da", "no", "nb", "nn", "fi", "et", "el", "hu", "tr", "bg":
		if value == 1 {
			return .One
		}
		return .Other

	case "fr":
		if value == 0 || value == 1 {
			return .One
		}
		if value != 0 && value % 1_000_000 == 0 {
			return .Many
		}
		return .Other

	case "es", "it", "ca":
		if value == 1 {
			return .One
		}
		if value != 0 && value % 1_000_000 == 0 {
			return .Many
		}
		return .Other

	case "pt":
		region := region_subtag_of_locale(locale_tag)
		if region == "PT" {
			if value == 1 {
				return .One
			}
		} else {
			if value == 0 || value == 1 {
				return .One
			}
		}
		if value != 0 && value % 1_000_000 == 0 {
			return .Many
		}
		return .Other

	case "ar":
		if value == 0 {
			return .Zero
		}
		if value == 1 {
			return .One
		}
		if value == 2 {
			return .Two
		}
		if mod100 >= 3 && mod100 <= 10 {
			return .Few
		}
		if mod100 >= 11 && mod100 <= 99 {
			return .Many
		}
		return .Other

	case "ru", "uk", "be":
		if mod10 == 1 && mod100 != 11 {
			return .One
		}
		if mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14) {
			return .Few
		}
		return .Many

	case "pl":
		if value == 1 {
			return .One
		}
		if mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14) {
			return .Few
		}
		return .Many

	case "cs", "sk":
		if value == 1 {
			return .One
		}
		if value >= 2 && value <= 4 {
			return .Few
		}
		return .Other

	case "hr", "sr", "bs":
		if mod10 == 1 && mod100 != 11 {
			return .One
		}
		if mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14) {
			return .Few
		}
		return .Other

	case "ja", "zh", "ko", "vi", "th", "id", "ms":
		return .Other
	}
	return .Other
}

// plural_category_for_integer evaluates the CLDR cardinal plural rule for a
// signed 64-bit integer under locale_tag using its absolute magnitude.
plural_category_for_integer :: proc "contextless" (locale_tag: string, value: i64) -> Plural_Category {
	return plural_category_for_unsigned(locale_tag, integer_magnitude(value))
}

// locale_group_separator returns the thousands group separator string for
// :integer and :number formatting under a canonical BCP 47 locale tag.
@(private)
locale_group_separator :: proc "contextless" (locale_tag: string) -> string {
	language := primary_language_subtag(locale_tag)
	switch language {
	case "fr":
		// Narrow no-break space (U+202F) used by CLDR for French numbers.
		return "\u202f"
	case "ru", "uk", "be", "pl", "cs", "sk", "fi", "sv", "no", "nb", "nn", "et":
		// No-break space (U+00A0).
		return "\u00a0"
	case "de", "es", "it", "pt", "nl", "da", "el", "tr", "hr", "sr", "bs", "ca":
		return "."
	}
	return ","
}
