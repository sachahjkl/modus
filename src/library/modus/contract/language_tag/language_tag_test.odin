#+build !freestanding
package language_tag

import "core:testing"

// Each tag that is not well-formed is refused with its problem: no byte,
// one byte past the bound, a byte outside ASCII or a sign, an empty
// subtag at the start, at the end and in the middle, a subtag of 9
// characters, a singleton with nothing after it, and each part out of its
// form or its order. A grandfathered tag is refused too.
@(test)
a_tag_that_is_not_well_formed_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		tag:     string,
		problem: Tag_Problem,
	}
	cases := [?]Case {
		{"", .Empty},
		{"en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd", .Too_Long},
		{"é", .Not_Ascii},
		{"fr_CA", .Not_Ascii},
		{"fr CA", .Not_Ascii},
		{"fr-\x00", .Not_Ascii},
		{"-fr", .Empty_Subtag},
		{"fr-", .Empty_Subtag},
		{"fr--CA", .Empty_Subtag},
		{"-", .Empty_Subtag},
		{"x-", .Empty_Subtag},
		{"en-abcdefghi", .Long_Subtag},
		{"abcdefghi", .Long_Subtag},
		{"x", .Malformed},
		{"en-x", .Malformed},
		{"en-a", .Malformed},
		{"en-a-b", .Malformed},
		{"en-a-bb-c", .Malformed},
		{"e", .Malformed},
		{"i-klingon", .Malformed},
		{"12", .Malformed},
		{"en-Latn-Latn", .Malformed},
		{"en-CA-Latn", .Malformed},
		{"en-CA-US", .Malformed},
		{"en-1996-Latn", .Malformed},
		{"en-abc-def-ghi-jkl", .Malformed},
		{"english-fra", .Malformed},
		{"en-ab1", .Malformed},
		{"en-12", .Malformed},
		{"en-1234a5678", .Long_Subtag},
	}
	#assert(len("en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd") == TAG_CAPACITY + 1)
	for item in cases {
		found := problem(item.tag)
		testing.expectf(t, found == item.problem, "%q gives %v, not %v", item.tag, found, item.problem)
	}
	// A stored tag in another case than its canonical one is refused, and
	// a tag that is not well-formed keeps its own problem.
	for tag in ([]string{"EN", "fr-ca", "zh-hant-TW", "sr-LATN-rs", "en-X-PRIVATE", "en-Latn-ca"}) {
		testing.expectf(t, canonical_check(tag) == .Not_Canonical, "%q is taken as canonical", tag)
	}
	testing.expect_value(t, canonical_check("fr--CA"), Tag_Problem.Empty_Subtag)
	// The canonical case of a tag that is not well-formed is no tag.
	buffer: [TAG_CAPACITY]u8
	_, ok := canonical("fr_CA", buffer[:])
	testing.expect(t, !ok)
	_, ok = canonical("fr-CA", buffer[:2])
	testing.expect(t, !ok)
}

// The well-formed tags: a language, a region, a script, an extended
// language, a variant, an extension, a private use, a private use alone, a
// language of 8 letters, a tag at the bound. Each one has its canonical
// case, and compares with no regard to case.
@(test)
a_well_formed_tag_and_its_canonical_case :: proc(t: ^testing.T) {
	Case :: struct {
		tag:       string,
		canonical: string,
	}
	cases := [?]Case {
		{"en", "en"},
		{"EN", "en"},
		{"fr-CA", "fr-CA"},
		{"fr-ca", "fr-CA"},
		{"zh-Hant-TW", "zh-Hant-TW"},
		{"ZH-HANT-tw", "zh-Hant-TW"},
		{"sr-Latn-RS", "sr-Latn-RS"},
		{"de-CH-1996", "de-CH-1996"},
		{"en-x-private", "en-x-private"},
		{"EN-X-PRIVATE-AB", "en-x-private-ab"},
		{"x-whatever", "x-whatever"},
		{"es-419", "es-419"},
		{"zh-yue-HK", "zh-yue-HK"},
		{"en-u-ca-gregory", "en-u-ca-gregory"},
		{"en-US-u-NU-latn-x-AB", "en-US-u-nu-latn-x-ab"},
		{"sl-rozaj-biske", "sl-rozaj-biske"},
		{"abcdefgh", "abcdefgh"},
		{"en-aaaaaaa-bbbbbbbb-cccccccc-dddddd", "en-aaaaaaa-bbbbbbbb-cccccccc-dddddd"},
	}
	#assert(len("en-aaaaaaa-bbbbbbbb-cccccccc-dddddd") == TAG_CAPACITY)
	for item in cases {
		found := problem(item.tag)
		buffer: [TAG_CAPACITY]u8
		form, ok := canonical(item.tag, buffer[:])
		testing.expectf(t, found == .None && ok && form == item.canonical, "%q: %v, %q, not %q", item.tag, found, form, item.canonical)
		testing.expectf(t, canonical_check(item.canonical) == .None, "%q is not taken as canonical", item.canonical)
		testing.expectf(t, equal(item.tag, item.canonical), "%q and %q are not equal", item.tag, item.canonical)
	}
	testing.expect(t, !equal("fr-CA", "fr-CB") && !equal("fr", "fr-CA") && !equal("", "en"))
}

// The Lookup of RFC 4647 shortens a tag by one subtag, with a singleton
// that is then last; a tag of one subtag, and a private use alone, end the
// chain.
@(test)
the_lookup_shortens_a_tag :: proc(t: ^testing.T) {
	for tag in ([]string{"en", "", "x-c", "fr"}) {
		_, ok := lookup_shorter(tag)
		testing.expectf(t, !ok, "%q gives a shorter tag", tag)
	}
	chains := [?][]string {
		{"zh-Hant-TW", "zh-Hant", "zh"},
		{"fr-CA", "fr"},
		{"en-a-bbb-x-c", "en-a-bbb", "en"},
		{"de-CH-1996", "de-CH", "de"},
	}
	for chain in chains {
		tag := chain[0]
		for expected in chain[1:] {
			shorter, ok := lookup_shorter(tag)
			testing.expectf(t, ok && shorter == expected, "%q gives %q, not %q", tag, shorter, expected)
			tag = shorter
		}
		_, ok := lookup_shorter(tag)
		testing.expectf(t, !ok, "%q gives a shorter tag", tag)
	}
}
