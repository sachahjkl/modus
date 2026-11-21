// A language tag of BCP 47 (RFC 5646): the language of a text, with its
// script and its region when they matter: `en`, `fr-CA`, `zh-Hant-TW`,
// `sr-Latn`. The languages are an open set, thousands of them with their
// regions and scripts, so a tag is a text that keeps a syntax, not a member
// of an enum (src/md/features/enum_parameters.md, "The display text of a
// member").
//
// This package checks the syntax of a well-formed tag (RFC 5646, section
// 2.1), gives its canonical case (section 2.1.1), and gives the shorter
// tag that the Lookup of RFC 4647 (section 3.4) tries next. It reads no
// registry: a well-formed tag that names no language is taken, as RFC 5646
// lets a reader do.
package language_tag

TAG_CAPACITY :: 35 // The bytes of a tag at most: a language, an extended language, a script, a region and two variants fit.
SUBTAG_CAPACITY :: 8 // The characters of a subtag at most.

// What problem refuses in a tag.
Tag_Problem :: enum u8 {
	None         = 0, // The tag is well-formed.
	Empty        = 1, // The tag has no byte.
	Too_Long     = 2, // The tag has more than TAG_CAPACITY bytes.
	Not_Ascii    = 3, // A byte that is no ASCII letter, no digit and no '-'.
	Empty_Subtag = 4, // A '-' at the start, at the end, or after another '-'.
	Long_Subtag  = 5, // A subtag of more than SUBTAG_CAPACITY characters.
	Malformed    = 6, // The subtags keep no form of RFC 5646, section 2.1: a language first, then an extended language, a script, a region, variants, extensions and a private use, each of its form, or a private use alone.
	Not_Canonical = 7, // A stored tag that is not in the canonical case of RFC 5646, section 2.1.1 (canonical_check).
}

// The kind of a byte of a tag.
@(private)
letter :: proc "contextless" (character: u8) -> bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z'
}

@(private)
digit :: proc "contextless" (character: u8) -> bool {
	return character >= '0' && character <= '9'
}

@(private)
all_letters :: proc "contextless" (subtag: string) -> bool {
	for index in 0 ..< len(subtag) {
		if !letter(subtag[index]) {
			return false
		}
	}
	return true
}

@(private)
all_digits :: proc "contextless" (subtag: string) -> bool {
	for index in 0 ..< len(subtag) {
		if !digit(subtag[index]) {
			return false
		}
	}
	return true
}

// Where a parse is, in the order of RFC 5646: each part can come only
// after the parts before it.
@(private)
Part :: enum u8 {
	Language,
	Extended_Language,
	Script,
	Region,
	Variant,
	Extension,
	Private_Use,
}

// problem says if a tag is well-formed (RFC 5646, section 2.1), in any
// case: a language of 2 or 3 letters with up to three extended languages of
// 3 letters, or a language of 4 to 8 letters; then a script of 4 letters, a
// region of 2 letters or 3 digits, variants of 5 to 8 letters and digits or
// of a digit and 3 letters and digits, extensions (a singleton other than
// x, then subtags of 2 to 8 letters and digits), and a private use (x, then
// subtags of 1 to 8 letters and digits). A tag of a private use alone,
// `x-private`, is well-formed too. The grandfathered tags of the registry
// (`i-klingon`, `en-GB-oed`) are refused: each has a preferred tag of the
// common form.
problem :: proc "contextless" (tag: string) -> Tag_Problem {
	switch {
	case len(tag) == 0:
		return .Empty
	case len(tag) > TAG_CAPACITY:
		return .Too_Long
	}
	for index in 0 ..< len(tag) {
		character := tag[index]
		if !letter(character) && !digit(character) && character != '-' {
			return .Not_Ascii
		}
	}
	part := Part.Language
	extended := 0 // The extended languages so far.
	after_singleton := false // The subtag before was a singleton: this one is the first of its extension or its private use.
	first := true
	start := 0
	for start <= len(tag) {
		end := start
		for end < len(tag) && tag[end] != '-' {
			end += 1
		}
		subtag := tag[start:end]
		if len(subtag) == 0 {
			return .Empty_Subtag
		}
		if len(subtag) > SUBTAG_CAPACITY {
			return .Long_Subtag
		}
		is_singleton := len(subtag) == 1
		switch {
		case first:
			first = false
			switch {
			case is_singleton && (subtag == "x" || subtag == "X"):
				part, after_singleton = .Private_Use, true
			case all_letters(subtag) && (len(subtag) == 2 || len(subtag) == 3):
				part = .Language
			case all_letters(subtag) && len(subtag) >= 4:
				// A language of 4 to 8 letters takes no extended language.
				part, extended = .Language, 3
			case:
				return .Malformed
			}
		case part == .Private_Use:
			// Any subtag of 1 to 8 letters and digits.
			after_singleton = false
		case after_singleton:
			// The first subtag of an extension: 2 to 8 characters.
			if len(subtag) < 2 {
				return .Malformed
			}
			after_singleton = false
		case is_singleton:
			// A singleton starts an extension, or the private use with x.
			if subtag == "x" || subtag == "X" {
				part = .Private_Use
			} else {
				part = .Extension
			}
			after_singleton = true
		case part == .Extension:
			// Another subtag of the extension: 2 to 8 characters.
			if len(subtag) < 2 {
				return .Malformed
			}
		case part <= .Language && extended < 3 && len(subtag) == 3 && all_letters(subtag):
			part = .Extended_Language
			extended += 1
		case part == .Extended_Language && extended < 3 && len(subtag) == 3 && all_letters(subtag):
			extended += 1
		case part < .Script && len(subtag) == 4 && all_letters(subtag):
			part = .Script
		case part < .Region && (len(subtag) == 2 && all_letters(subtag) || len(subtag) == 3 && all_digits(subtag)):
			part = .Region
		case part <= .Variant && (len(subtag) >= 5 || len(subtag) == 4 && digit(subtag[0])):
			part = .Variant
		case:
			return .Malformed
		}
		start = end + 1
		if end == len(tag) {
			break
		}
	}
	// A singleton with no subtag after it: `en-x`, `x`, `en-a`.
	if after_singleton {
		return .Malformed
	}
	return .None
}

// canonical writes the canonical case of a well-formed tag in buffer
// (RFC 5646, section 2.1.1): lower case, with a script in title case
// (`Hant`) and a region of 2 letters in upper case (`CA`), except in an
// extension and in the private use, which stay in lower case. ok is false
// for a tag that is not well-formed or that buffer does not hold.
canonical :: proc "contextless" (tag: string, buffer: []u8) -> (form: string, ok: bool) {
	if problem(tag) != .None || len(tag) > len(buffer) {
		return "", false
	}
	lower :: proc "contextless" (character: u8) -> u8 {
		return character >= 'A' && character <= 'Z' ? character + ('a' - 'A') : character
	}
	upper :: proc "contextless" (character: u8) -> u8 {
		return character >= 'a' && character <= 'z' ? character - ('a' - 'A') : character
	}
	after_singleton := false
	start := 0
	for index := 0; index <= len(tag); index += 1 {
		if index < len(tag) && tag[index] != '-' {
			continue
		}
		subtag := tag[start:index]
		for place in start ..< index {
			buffer[place] = lower(tag[place])
		}
		switch {
		case start == 0 || after_singleton:
		case len(subtag) == 1:
			after_singleton = true
		case len(subtag) == 2:
			buffer[start] = upper(tag[start])
			buffer[start + 1] = upper(tag[start + 1])
		case len(subtag) == 4 && all_letters(subtag):
			buffer[start] = upper(tag[start])
		}
		if start == 0 && len(subtag) == 1 {
			after_singleton = true
		}
		if index < len(tag) {
			buffer[index] = '-'
		}
		start = index + 1
	}
	return string(buffer[:len(tag)]), true
}

// canonical_check says why a stored tag is refused: its problem, or
// Not_Canonical when it is well-formed and not in its canonical case. A
// file stores each tag in its canonical case, so two tags are equal when
// their bytes are.
canonical_check :: proc "contextless" (tag: string) -> Tag_Problem {
	if found := problem(tag); found != .None {
		return found
	}
	buffer: [TAG_CAPACITY]u8
	form, _ := canonical(tag, buffer[:])
	if form != tag {
		return .Not_Canonical
	}
	return .None
}

// equal says if two tags are one tag: RFC 5646 compares tags with no
// regard to case.
equal :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for index in 0 ..< len(a) {
		x, y := a[index], b[index]
		if x >= 'A' && x <= 'Z' {
			x += 'a' - 'A'
		}
		if y >= 'A' && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

// lookup_shorter gives the tag that the Lookup of RFC 4647 (section 3.4)
// tries after a tag that has no text: the tag with its last subtag
// removed, and with a singleton that is then last removed too
// (`zh-Hant-TW` gives `zh-Hant`, then `zh`; `en-a-bbb-x-c` gives
// `en-a-bbb`, then `en`). ok is false for a tag of one subtag, after which
// the Lookup tries the next tag of its list.
lookup_shorter :: proc "contextless" (tag: string) -> (shorter: string, ok: bool) {
	end := len(tag)
	for end > 0 && tag[end - 1] != '-' {
		end -= 1
	}
	if end == 0 {
		return "", false
	}
	shorter = tag[:end - 1]
	// A singleton left last is removed with its dash; a singleton alone
	// (`x` of `x-c`) leaves no tag.
	if len(shorter) >= 2 && shorter[len(shorter) - 2] == '-' {
		shorter = shorter[:len(shorter) - 2]
	}
	if len(shorter) <= 1 {
		return "", false
	}
	return shorter, true
}
