#+build !freestanding
#+build !modus
package interface_messages

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

// Helper to reseal a mutated MODLANG1 pack's BLAKE3 trailer so tests exercise
// structural and semantic validation past the digest check.
@(private = "file")
reseal_pack_digest :: proc(pack_bytes: []u8) {
	digest_offset := len(pack_bytes) - PACK_DIGEST_SIZE
	digest := blake3.hash(pack_bytes[:digest_offset])
	copy(pack_bytes[digest_offset:], digest[:])
}

// Language preference lists refuse 0 tags, >8 tags, non-canonical tags,
// malformed tags, duplicate tags, and corrupt border records, and accept
// 1..8 distinct canonical BCP 47 tags.
@(test)
language_list_edges_and_refusals :: proc(t: ^testing.T) {
	// Edge 0: empty list is refused.
	_, status, failing := language_list_build(nil)
	testing.expect_value(t, status, Language_List_Status.Empty_List)
	testing.expect_value(t, failing, 0)

	// Edge 1: single canonical tag succeeds.
	one_list, one_status, _ := language_list_build([]string{"en"})
	testing.expect_value(t, one_status, Language_List_Status.Ok)
	testing.expect_value(t, one_list.count, u8(1))
	tag0, ok0 := language_list_tag(&one_list, 0)
	testing.expect(t, ok0 && tag0 == "en")
	// Out-of-range index edges.
	_, ok_neg := language_list_tag(&one_list, -1)
	testing.expect(t, !ok_neg)
	_, ok_past := language_list_tag(&one_list, 1)
	testing.expect(t, !ok_past)
	_, ok_nil := language_list_tag(nil, 0)
	testing.expect(t, !ok_nil)

	// Edge 8 (the bound): eight distinct canonical tags succeed.
	eight_tags := [8]string{"fr-CA", "fr", "en", "ar", "ru", "pl", "ja", "zh-Hant-TW"}
	eight_list, eight_status, _ := language_list_build(eight_tags[:])
	testing.expect_value(t, eight_status, Language_List_Status.Ok)
	testing.expect_value(t, eight_list.count, u8(LANGUAGE_LIST_CAPACITY))
	val_status, _ := language_list_validate(&eight_list)
	testing.expect_value(t, val_status, Language_List_Status.Ok)

	// Edge 9 (one past bound): refused with Too_Many_Languages.
	nine_tags := [9]string{"fr-CA", "fr", "en", "ar", "ru", "pl", "ja", "zh-Hant-TW", "de"}
	_, nine_status, nine_idx := language_list_build(nine_tags[:])
	testing.expect_value(t, nine_status, Language_List_Status.Too_Many_Languages)
	testing.expect_value(t, nine_idx, LANGUAGE_LIST_CAPACITY)

	// Duplicate tags are refused with exact failing index.
	_, dup_status, dup_idx := language_list_build([]string{"fr-CA", "en", "fr-CA"})
	testing.expect_value(t, dup_status, Language_List_Status.Duplicate_Tag)
	testing.expect_value(t, dup_idx, 2)

	// Non-canonical tags are refused with Non_Canonical_Tag.
	for bad_case in ([]string{"EN-us", "fr-ca", "zh-hant-TW", "EN"}) {
		_, nc_status, nc_idx := language_list_build([]string{"en", bad_case})
		testing.expectf(t, nc_status == .Non_Canonical_Tag && nc_idx == 1, "%q gave %v at %d", bad_case, nc_status, nc_idx)
	}

	// Malformed tags are refused with Invalid_Tag.
	for bad_tag in ([]string{"", "fr_CA", "fr--CA", "en-x", "12", "en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd"}) {
		_, inv_status, inv_idx := language_list_build([]string{bad_tag})
		testing.expectf(t, inv_status == .Invalid_Tag && inv_idx == 0, "%q gave %v at %d", bad_tag, inv_status, inv_idx)
	}

	// Border validation catches tampered Language_List fields.
	empty_record: Language_List
	v_empty, _ := language_list_validate(&empty_record)
	testing.expect_value(t, v_empty, Language_List_Status.Empty_List)

	over_record := eight_list
	over_record.count = LANGUAGE_LIST_CAPACITY + 1
	v_over, _ := language_list_validate(&over_record)
	testing.expect_value(t, v_over, Language_List_Status.Too_Many_Languages)

	bad_padding := one_list
	bad_padding.entries[0].bytes[LANGUAGE_TAG_CAPACITY - 1] = 'X'
	v_pad, v_pad_idx := language_list_validate(&bad_padding)
	testing.expect_value(t, v_pad, Language_List_Status.Invalid_Tag)
	testing.expect_value(t, v_pad_idx, 0)

	bad_len := one_list
	bad_len.entries[0].length = LANGUAGE_TAG_CAPACITY + 1
	v_len, _ := language_list_validate(&bad_len)
	testing.expect_value(t, v_len, Language_List_Status.Invalid_Tag)

	tampered_case := one_list
	tampered_case.entries[0].bytes[0] = 'E'
	v_case, _ := language_list_validate(&tampered_case)
	testing.expect_value(t, v_case, Language_List_Status.Non_Canonical_Tag)

	tampered_dup := eight_list
	tampered_dup.count = 2
	tampered_dup.entries[1] = tampered_dup.entries[0]
	v_dup, v_dup_idx := language_list_validate(&tampered_dup)
	testing.expect_value(t, v_dup, Language_List_Status.Duplicate_Tag)
	testing.expect_value(t, v_dup_idx, 1)
}

// RFC 4647 Lookup fallback across the language preference list resolves exact
// tags, shorter prefixes, multi-subtag chains, singleton removal, and ignores
// non-canonical available tags.
@(test)
language_list_rfc4647_fallback_resolution :: proc(t: ^testing.T) {
	list, status, _ := language_list_build([]string{"fr-CA", "en"})
	testing.expect_value(t, status, Language_List_Status.Ok)

	// fr-CA -> fr matches available "fr" before falling through to "en".
	idx, tag, found := language_list_resolve(&list, []string{"de", "fr", "en"})
	testing.expect(t, found && idx == 1 && tag == "fr")

	// fr-CA -> fr missing -> falls through to second preference "en".
	idx, tag, found = language_list_resolve(&list, []string{"de", "en"})
	testing.expect(t, found && idx == 1 && tag == "en")

	// Exact match wins over parent.
	idx, tag, found = language_list_resolve(&list, []string{"fr", "fr-CA", "en"})
	testing.expect(t, found && idx == 1 && tag == "fr-CA")

	// Multi-subtag chain: zh-Hant-TW -> zh-Hant -> zh.
	zh_list, zh_status, _ := language_list_build([]string{"zh-Hant-TW", "en"})
	testing.expect_value(t, zh_status, Language_List_Status.Ok)

	idx, tag, found = language_list_resolve(&zh_list, []string{"zh", "zh-Hant"})
	testing.expect(t, found && idx == 1 && tag == "zh-Hant")

	idx, tag, found = language_list_resolve(&zh_list, []string{"zh", "en"})
	testing.expect(t, found && idx == 0 && tag == "zh")

	// Singleton stripping: en-a-bbb-x-c -> en-a-bbb -> en.
	ext_list, ext_status, _ := language_list_build([]string{"en-a-bbb-x-c"})
	testing.expect_value(t, ext_status, Language_List_Status.Ok)
	idx, tag, found = language_list_resolve(&ext_list, []string{"en"})
	testing.expect(t, found && idx == 0 && tag == "en")

	// Non-canonical available tags are never matched.
	idx, tag, found = language_list_resolve(&list, []string{"FR", "FR-ca", "EN"})
	testing.expect(t, !found && idx == -1 && tag == "")

	// Empty available list or invalid preference list fails cleanly.
	idx, tag, found = language_list_resolve(&list, nil)
	testing.expect(t, !found && idx == -1 && tag == "")

	invalid_list: Language_List
	idx, tag, found = language_list_resolve(&invalid_list, []string{"en"})
	testing.expect(t, !found && idx == -1 && tag == "")
}

// MF2 parser refuses malformed syntax, unterminated expressions, stray closing
// braces, invalid escapes, unknown functions, bad options, missing * fallback,
// duplicate variant keys, key mismatches, duplicate declarations, invalid UTF-8
// or control characters, and exceeded bounds.
@(test)
mf2_parser_refusals_and_bounds :: proc(t: ^testing.T) {
	Case :: struct {
		source:   string,
		expected: Message_Status,
	}
	cases := [?]Case {
		// Unterminated expressions and patterns.
		{"Hello {$name", .Unterminated_Expression},
		{"{", .Unterminated_Expression},
		{"{$a :integer", .Unterminated_Expression},
		{"{|unterminated}", .Unterminated_Expression},
		{"{{unclosed quoted pattern", .Unterminated_Expression},
		{".input {$c :integer} {{Hello {$c}", .Unterminated_Expression},

		// Stray closing braces.
		{"Hello } world", .Unexpected_Close_Brace},
		{"}", .Unexpected_Close_Brace},
		{"{{Hello } world}}", .Unexpected_Close_Brace},

		// Invalid escapes.
		{"Bad \\n escape", .Invalid_Escape},
		{"Bad \\a escape", .Invalid_Escape},
		{"Trailing \\", .Invalid_Escape},
		{"{{Bad \\x escape}}", .Invalid_Escape},
		{"{|bad \\q| :string}", .Invalid_Escape},

		// Unknown functions.
		{"{$count :bogus}", .Unknown_Function},
		{"{$when :date}", .Unknown_Function},
		{"{$value :custom:fn}", .Unknown_Function},

		// Syntax errors.
		{"{}", .Syntax_Error},
		{"{:integer}", .Syntax_Error},
		{"{$name:integer}", .Syntax_Error},
		{"{$123}", .Syntax_Error},
		{".unknown {{text}}", .Syntax_Error},
		{".input {42 :integer} {{text}}", .Syntax_Error},
		{".match {{no selectors}}", .Syntax_Error},
		{"{{ok}} trailing", .Syntax_Error},

		// Invalid options.
		{"{$x :integer bogus=1}", .Invalid_Option},
		{"{$x :integer select=ordinal}", .Invalid_Option},
		{"{$x :integer useGrouping=sometimes}", .Invalid_Option},
		{"{$x :integer minimumIntegerDigits=0}", .Invalid_Option},
		{"{$x :integer minimumIntegerDigits=21}", .Invalid_Option},
		{"{$x :integer useGrouping=never useGrouping=auto}", .Invalid_Option},
		{"{$x :string select=exact}", .Invalid_Option},

		// Nested expressions refused.
		{"Hello {{$name}}", .Nesting_Too_Deep},
		{"{{Hello {{$name}}}}", .Nesting_Too_Deep},
		{"{ {$name} }", .Nesting_Too_Deep},

		// Missing mandatory catch-all * variant.
		{".match $c 0 {{none}} one {{one}}", .Missing_Fallback_Variant},
		{".match $a $b 0 * {{a}} * 0 {{b}}", .Missing_Fallback_Variant},

		// Duplicate variant keys (including unquoted vs quoted equivalence).
		{".match $c one {{a}} one {{b}} * {{c}}", .Duplicate_Variant_Key},
		{".match $c one {{a}} |one| {{b}} * {{c}}", .Duplicate_Variant_Key},
		{".match $c * {{a}} * {{b}}", .Duplicate_Variant_Key},
		{".match $a $b 0 * {{a}} |0| * {{b}} * * {{c}}", .Duplicate_Variant_Key},

		// Variant key count mismatch.
		{".match $a $b 0 {{missing second}} * * {{ok}}", .Variant_Key_Mismatch},
		{".match $a 0 1 {{too many}} * {{ok}}", .Variant_Key_Mismatch},

		// Duplicate declarations.
		{".input {$x :integer} .input {$x :integer} {{ok}}", .Duplicate_Declaration},
		{".input {$x :integer} .local $x = {$x :integer} {{ok}}", .Duplicate_Declaration},
		{".local $a = {1 :integer} .local $a = {2 :integer} {{ok}}", .Duplicate_Declaration},

		// Invalid UTF-8, control characters, and hidden BiDi overrides.
		{"Hello\x00world", .Invalid_Utf8},
		{"Line1\nLine2", .Invalid_Utf8},
		{"Tab\there", .Invalid_Utf8},
		{"{{Newline\ninside}}", .Invalid_Utf8},
		{"Bad\x80utf8", .Invalid_Utf8},
		{"Overlong\xc0\x80utf8", .Invalid_Utf8},
		{"Surrogate\xed\xa0\x80utf8", .Invalid_Utf8},
		{"Hidden\u202ebidi", .Invalid_Utf8},
		{"Zero\u200bwidth", .Invalid_Utf8},
	}

	for item in cases {
		_, status, _ := message_parse(item.source)
		testing.expectf(t, status == item.expected, "%q gave %v, expected %v", item.source, status, item.expected)
	}

	// Pattern length edges: exact bound passes, bound + 1 is refused.
	at_bound := strings.repeat("a", MESSAGE_PATTERN_MAX_BYTES, context.temp_allocator)
	_, ok_bound_status, _ := message_parse(at_bound)
	testing.expect_value(t, ok_bound_status, Message_Status.Ok)

	past_bound := strings.repeat("a", MESSAGE_PATTERN_MAX_BYTES + 1, context.temp_allocator)
	_, past_bound_status, _ := message_parse(past_bound)
	testing.expect_value(t, past_bound_status, Message_Status.Pattern_Too_Long)

	// .local nesting chain: depth 4 passes, depth 5 is refused.
	depth4 := ".local $a = {$x :integer} .local $b = {$a} .local $c = {$b} .local $d = {$c} {{{$d}}}"
	_, d4_status, _ := message_parse(depth4)
	testing.expect_value(t, d4_status, Message_Status.Ok)

	depth5 := ".local $a = {$x :integer} .local $b = {$a} .local $c = {$b} .local $d = {$c} .local $e = {$d} {{{$e}}}"
	_, d5_status, _ := message_parse(depth5)
	testing.expect_value(t, d5_status, Message_Status.Nesting_Too_Deep)

	// Too many declarations (17 > 16).
	b := strings.builder_make(context.temp_allocator)
	for index in 0 ..< MESSAGE_MAX_DECLARATIONS + 1 {
		strings.write_string(&b, ".local $v")
		strings.write_byte(&b, u8('a' + index))
		strings.write_string(&b, " = {1 :integer} ")
	}
	strings.write_string(&b, "{{ok}}")
	_, decl_over_status, _ := message_parse(strings.to_string(b))
	testing.expect_value(t, decl_over_status, Message_Status.Too_Many_Declarations)

	// Too many selectors (5 > 4).
	_, sel_over_status, _ := message_parse(".match $a $b $c $d $e * * * * * {{ok}}")
	testing.expect_value(t, sel_over_status, Message_Status.Too_Many_Selectors)

	// Too many variants (33 > 32).
	vb := strings.builder_make(context.temp_allocator)
	strings.write_string(&vb, ".match $c ")
	for index in 0 ..< MESSAGE_MAX_VARIANTS {
		strings.write_byte(&vb, u8('a' + index / 26))
		strings.write_byte(&vb, u8('a' + index % 26))
		strings.write_string(&vb, " {{v}} ")
	}
	strings.write_string(&vb, "* {{fallback}}")
	_, var_over_status, _ := message_parse(strings.to_string(vb))
	testing.expect_value(t, var_over_status, Message_Status.Too_Many_Variants)

	// Too many parts (65 > 64).
	pb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< MESSAGE_MAX_PARTS + 1 {
		strings.write_string(&pb, "{$a}")
	}
	_, part_over_status, _ := message_parse(strings.to_string(pb))
	testing.expect_value(t, part_over_status, Message_Status.Too_Many_Parts)

	// Too many options (9 > 8).
	_, opt_over_status, _ := message_parse("{$x :integer a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8 i=9}")
	testing.expect_value(t, opt_over_status, Message_Status.Too_Many_Options)

	// Wildcard * vs quoted literal |*| are distinct and both allowed.
	_, star_lit_status, _ := message_parse(".match $s |*| {{literal star}} * {{fallback}}")
	testing.expect_value(t, star_lit_status, Message_Status.Ok)
}

// Runtime evaluation refuses missing variables, type mismatches, invalid
// locales, invalid UTF-8 arguments, duplicate argument names, and output
// buffer overflows cleanly.
@(test)
mf2_runtime_refusals_and_buffer_edges :: proc(t: ^testing.T) {
	buffer: [128]u8

	// Missing variable in simple pattern.
	written, status := message_format("Hello, {$name}!", "en", nil, buffer[:])
	testing.expect_value(t, status, Message_Status.Missing_Variable)
	testing.expect_value(t, written, 0)

	// Missing variable in .input declaration.
	written, status = message_format(".input {$count :integer} .match $count * {{{$count}}}", "en", nil, buffer[:])
	testing.expect_value(t, status, Message_Status.Missing_Variable)
	testing.expect_value(t, written, 0)

	// Nil union value in argument treated as missing.
	written, status = message_format("Hello, {$name}!", "en", []Message_Argument{{name = "name"}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Missing_Variable)
	testing.expect_value(t, written, 0)

	// Type mismatch: Text passed to :integer or :number.
	written, status = message_format("Count: {$n :integer}", "en", []Message_Argument{{name = "n", value = Text("abc")}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Type_Mismatch)
	testing.expect_value(t, written, 0)

	written, status = message_format("Count: {$n :number}", "en", []Message_Argument{{name = "n", value = Text("123")}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Type_Mismatch)
	testing.expect_value(t, written, 0)

	// Invalid locale tag.
	written, status = message_format("Hello", "EN-us", nil, buffer[:])
	testing.expect_value(t, status, Message_Status.Invalid_Locale)
	testing.expect_value(t, written, 0)

	// Invalid UTF-8 or control characters in Text argument.
	written, status = message_format("Hi {$u}", "en", []Message_Argument{{name = "u", value = Text("bad\nline")}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Invalid_Utf8)
	testing.expect_value(t, written, 0)

	written, status = message_format("Hi {$u}", "en", []Message_Argument{{name = "u", value = Text("bad\u202erlo")}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Invalid_Utf8)
	testing.expect_value(t, written, 0)

	// Duplicate argument names refused.
	written, status = message_format("Hi {$u}", "en", []Message_Argument{{name = "u", value = Text("a")}, {name = "u", value = Text("b")}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Duplicate_Declaration)
	testing.expect_value(t, written, 0)

	// Output buffer edges: 0 bytes, exact - 1 bytes, exact bytes.
	args := []Message_Argument{{name = "name", value = Text("modus")}}
	// Expected output is "Hello, modus!" (13 bytes).
	written, status = message_format("Hello, {$name}!", "en", args, nil)
	testing.expect_value(t, status, Message_Status.Buffer_Too_Small)
	testing.expect_value(t, written, 0)

	small_buf: [12]u8
	written, status = message_format("Hello, {$name}!", "en", args, small_buf[:])
	testing.expect_value(t, status, Message_Status.Buffer_Too_Small)
	testing.expect_value(t, written, 0)

	exact_buf: [13]u8
	written, status = message_format("Hello, {$name}!", "en", args, exact_buf[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, written, 13)
	testing.expect_value(t, string(exact_buf[:written]), "Hello, modus!")

	// Empty message succeeds even with a 0-byte buffer.
	written, status = message_format("", "en", nil, nil)
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, written, 0)
}

// Simple patterns, escapes, built-in functions (:integer, :number, :string),
// .local declarations, options, and extreme 64-bit integer values format cleanly.
@(test)
mf2_simple_patterns_functions_and_integer_edges :: proc(t: ^testing.T) {
	buffer: [256]u8

	// Simple pattern with escapes.
	written, status := message_format("Hello, {$name}! Braces: \\{ \\} \\\\ \\|", "en", []Message_Argument{{name = "name", value = Text("Alice")}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "Hello, Alice! Braces: { } \\ |")

	// Quoted complex pattern allowing leading dot.
	written, status = message_format("{{.config ready}}", "en", nil, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), ".config ready")

	// :integer and :number locale grouping vs useGrouping=never vs plain.
	written, status = message_format("plain={$n} en={$n :integer} nogrp={$n :integer useGrouping=never} pad={$small :number minimumIntegerDigits=4 useGrouping=never}", "en", []Message_Argument{
		{name = "n", value = Integer(1234567)},
		{name = "small", value = Integer(7)},
	}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "plain=1234567 en=1,234,567 nogrp=1234567 pad=0007")

	// French grouping uses narrow no-break space U+202F.
	written, status = message_format("{$n :number}", "fr", []Message_Argument{{name = "n", value = Integer(1234)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "1\u202f234")

	// :string formats text and numbers without grouping.
	written, status = message_format("{$a :string}-{$b :string}-{$c :string}", "en", []Message_Argument{
		{name = "a", value = Text("ok")},
		{name = "b", value = Integer(-1234)},
		{name = "c", value = Unsigned(5678)},
	}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "ok--1234-5678")

	// Extreme 64-bit bounds: min(i64), max(i64), max(u64).
	written, status = message_format("{$lo}|{$hi}|{$umax}", "en", []Message_Argument{
		{name = "lo", value = Integer(min(i64))},
		{name = "hi", value = Integer(max(i64))},
		{name = "umax", value = Unsigned(max(u64))},
	}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "-9223372036854775808|9223372036854775807|18446744073709551615")

	// .local declaration aliasing and literal binding.
	local_msg := ".local $tag = {|disk0| :string}\n.local $free_fmt = {$free :integer useGrouping=never}\n{{{$tag}: {$free_fmt} blocks}}"
	written, status = message_format(local_msg, "en", []Message_Argument{{name = "free", value = Unsigned(4096)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "disk0: 4096 blocks")

	// Multi-selector priority: exact match beats plural category beats wildcard,
	// broken left-to-right.
	multi_msg := `
.input {$a :integer}
.input {$b :integer}
.match $a $b
0   *   {{a-zero}}
*   0   {{b-zero}}
one one {{both-one}}
*   *   {{other}}`
	written, status = message_format(multi_msg, "en", []Message_Argument{{name = "a", value = Integer(0)}, {name = "b", value = Integer(0)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "a-zero")

	written, status = message_format(multi_msg, "en", []Message_Argument{{name = "a", value = Integer(5)}, {name = "b", value = Integer(0)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "b-zero")

	written, status = message_format(multi_msg, "en", []Message_Argument{{name = "a", value = Integer(1)}, {name = "b", value = Integer(1)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "both-one")

	written, status = message_format(multi_msg, "en", []Message_Argument{{name = "a", value = Integer(2)}, {name = "b", value = Integer(3)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "other")

	// select=exact suppresses plural category matching so only exact or * matches.
	exact_only := ".input {$n :integer select=exact}\n.match $n\n1 {{exact one}}\none {{plural one}}\n* {{fallback}}"
	written, status = message_format(exact_only, "en", []Message_Argument{{name = "n", value = Integer(1)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "exact one")

	exact_no_one := ".input {$n :integer select=exact}\n.match $n\none {{plural one}}\n* {{fallback}}"
	written, status = message_format(exact_no_one, "en", []Message_Argument{{name = "n", value = Integer(1)}}, buffer[:])
	testing.expect_value(t, status, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:written]), "fallback")
}

// Multi-language CLDR cardinal plural formatting across English, French,
// Russian, Polish, Czech, Arabic, and Japanese/Chinese/Korean.
@(test)
mf2_multilanguage_cldr_plurals :: proc(t: ^testing.T) {
	buffer: [256]u8

	// English: 1 -> one, 0/2 -> other; exact 0 overrides other when present.
	en_files := `
.input {$count :integer}
.match $count
one {{{$count} file}}
*   {{{$count} files}}`

	en_cases := [?]struct {
		count:    i64,
		expected: string,
	}{
		{0, "0 files"},
		{1, "1 file"},
		{2, "2 files"},
		{-1, "-1 file"},
		{1000, "1,000 files"},
	}
	for item in en_cases {
		written, status := message_format(en_files, "en", []Message_Argument{{name = "count", value = Integer(item.count)}}, buffer[:])
		testing.expect_value(t, status, Message_Status.Ok)
		testing.expectf(t, string(buffer[:written]) == item.expected, "en %d: got %q, want %q", item.count, string(buffer[:written]), item.expected)
	}

	// English exact key 0 beats category/wildcard.
	en_disk := `
.input {$free :integer}
.match $free
0   {{The disk is full.}}
one {{The disk has {$free} free block.}}
*   {{The disk has {$free} free blocks.}}`
	w0, s0 := message_format(en_disk, "en", []Message_Argument{{name = "free", value = Unsigned(0)}}, buffer[:])
	testing.expect_value(t, s0, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:w0]), "The disk is full.")

	// French: 0 and 1 are both 'one'; 2 is 'other'; 1_000_000 is 'many'.
	fr_files := `
.input {$count :integer}
.match $count
one  {{{$count} fichier}}
many {{{$count} de fichiers}}
*    {{{$count} fichiers}}`
	fr_cases := [?]struct {
		count:    i64,
		expected: string,
	}{
		{0, "0 fichier"},
		{1, "1 fichier"},
		{2, "2 fichiers"},
		{1_000_000, "1\u202f000\u202f000 de fichiers"},
	}
	for item in fr_cases {
		written, status := message_format(fr_files, "fr-CA", []Message_Argument{{name = "count", value = Integer(item.count)}}, buffer[:])
		testing.expect_value(t, status, Message_Status.Ok)
		testing.expectf(t, string(buffer[:written]) == item.expected, "fr %d: got %q, want %q", item.count, string(buffer[:written]), item.expected)
	}

	// Russian: 1/21 -> one, 2/3/4/22 -> few, 0/5/11/12/14/25 -> many.
	ru_files := `
.input {$count :integer}
.match $count
one  {{{$count} файл}}
few  {{{$count} файла}}
many {{{$count} файлов}}
*    {{{$count} файлов}}`
	ru_cases := [?]struct {
		count:    i64,
		expected: string,
	}{
		{0, "0 файлов"},
		{1, "1 файл"},
		{2, "2 файла"},
		{4, "4 файла"},
		{5, "5 файлов"},
		{11, "11 файлов"},
		{12, "12 файлов"},
		{14, "14 файлов"},
		{21, "21 файл"},
		{22, "22 файла"},
		{25, "25 файлов"},
	}
	for item in ru_cases {
		written, status := message_format(ru_files, "ru", []Message_Argument{{name = "count", value = Integer(item.count)}}, buffer[:])
		testing.expect_value(t, status, Message_Status.Ok)
		testing.expectf(t, string(buffer[:written]) == item.expected, "ru %d: got %q, want %q", item.count, string(buffer[:written]), item.expected)
	}

	// Polish vs Russian distinction: 21 is 'many' in Polish, 'one' in Russian.
	testing.expect_value(t, plural_category_for_unsigned("pl", 1), Plural_Category.One)
	testing.expect_value(t, plural_category_for_unsigned("pl", 2), Plural_Category.Few)
	testing.expect_value(t, plural_category_for_unsigned("pl", 5), Plural_Category.Many)
	testing.expect_value(t, plural_category_for_unsigned("pl", 21), Plural_Category.Many)
	testing.expect_value(t, plural_category_for_unsigned("pl", 22), Plural_Category.Few)
	testing.expect_value(t, plural_category_for_unsigned("cs", 1), Plural_Category.One)
	testing.expect_value(t, plural_category_for_unsigned("cs", 3), Plural_Category.Few)
	testing.expect_value(t, plural_category_for_unsigned("cs", 5), Plural_Category.Other)

	// Arabic: all six CLDR categories (0 zero, 1 one, 2 two, 3..10 few, 11..99 many, 100 other).
	ar_msg := `
.input {$count :integer}
.match $count
zero {{zero:{$count}}}
one  {{one:{$count}}}
two  {{two:{$count}}}
few  {{few:{$count}}}
many {{many:{$count}}}
*    {{other:{$count}}}`
	ar_cases := [?]struct {
		count:    u64,
		expected: string,
	}{
		{0, "zero:0"},
		{1, "one:1"},
		{2, "two:2"},
		{3, "few:3"},
		{10, "few:10"},
		{11, "many:11"},
		{99, "many:99"},
		{100, "other:100"},
		{101, "other:101"},
		{102, "other:102"},
		{103, "few:103"},
		{111, "many:111"},
	}
	for item in ar_cases {
		written, status := message_format(ar_msg, "ar", []Message_Argument{{name = "count", value = Unsigned(item.count)}}, buffer[:])
		testing.expect_value(t, status, Message_Status.Ok)
		testing.expectf(t, string(buffer[:written]) == item.expected, "ar %d: got %q, want %q", item.count, string(buffer[:written]), item.expected)
	}

	// Japanese, Chinese, Korean: all integers select 'other'.
	ja_msg := `
.input {$count :integer}
.match $count
one {{unexpected}}
*   {{{$count}件のファイル}}`
	for count in ([]u64{0, 1, 2, 5, 100}) {
		testing.expect_value(t, plural_category_for_unsigned("ja", count), Plural_Category.Other)
		testing.expect_value(t, plural_category_for_unsigned("zh-Hans", count), Plural_Category.Other)
		testing.expect_value(t, plural_category_for_unsigned("ko", count), Plural_Category.Other)
	}
	w_ja, s_ja := message_format(ja_msg, "ja", []Message_Argument{{name = "count", value = Unsigned(1)}}, buffer[:])
	testing.expect_value(t, s_ja, Message_Status.Ok)
	testing.expect_value(t, string(buffer[:w_ja]), "1件のファイル")
}

// MODLANG1 binary language pack encode, validate, and O(log N) lookup across
// 0, 1, and multiple entries, plus end-to-end formatting.
@(test)
binary_pack_encode_validate_lookup_and_format :: proc(t: ^testing.T) {
	pack_buf: [4096]u8

	// Edge 0: empty pack (96 bytes: 64-byte header + 32-byte BLAKE3 digest).
	written, enc_status := pack_encode("en", nil, pack_buf[:])
	testing.expect_value(t, enc_status, Pack_Status.Ok)
	testing.expect_value(t, written, PACK_MIN_SIZE)

	header, val_status := pack_validate(pack_buf[:written])
	testing.expect_value(t, val_status, Pack_Status.Ok)
	testing.expect_value(t, header.version, PACK_FORMAT_VERSION)
	testing.expect_value(t, header.entry_count, u32(0))
	testing.expect_value(t, pack_language_tag(&header), "en")

	_, miss_status := pack_lookup(pack_buf[:written], "greeting")
	testing.expect_value(t, miss_status, Pack_Status.Not_Found)

	// Edge 1: single entry pack.
	single := [1]Pack_Entry_Input{{message_id = "greeting", message_pattern = "Bonjour, {$name} !"}}
	written, enc_status = pack_encode("fr", single[:], pack_buf[:])
	testing.expect_value(t, enc_status, Pack_Status.Ok)

	header, val_status = pack_validate(pack_buf[:written])
	testing.expect_value(t, val_status, Pack_Status.Ok)
	testing.expect_value(t, header.entry_count, u32(1))
	testing.expect_value(t, pack_language_tag(&header), "fr")

	pattern, look_status := pack_lookup(pack_buf[:written], "greeting")
	testing.expect_value(t, look_status, Pack_Status.Ok)
	testing.expect_value(t, pattern, "Bonjour, {$name} !")

	// Multi-entry pack encoded from arbitrary order is sorted and looked up in O(log N).
	entries := [?]Pack_Entry_Input {
		{message_id = "settings.title", message_pattern = "Paramètres"},
		{message_id = "storage.files", message_pattern = ".input {$count :integer}\n.match $count\none {{{$count} fichier}}\n* {{{$count} fichiers}}"},
		{message_id = "system.greeting", message_pattern = "Bienvenue, {$user}."},
		{message_id = "network.status", message_pattern = "Connecté"},
		{message_id = "console.prompt", message_pattern = "Prêt"},
	}
	exact_size, size_status := pack_encoded_size(entries[:])
	testing.expect_value(t, size_status, Pack_Status.Ok)

	// Buffer exact_size - 1 is refused and leaves destination untouched.
	sentinel_buf: [4096]u8
	for &b in sentinel_buf {
		b = 0xA5
	}
	w_small, s_small := pack_encode("fr-CA", entries[:], sentinel_buf[:exact_size - 1])
	testing.expect_value(t, s_small, Pack_Status.Buffer_Too_Small)
	testing.expect_value(t, w_small, 0)
	for b in sentinel_buf[:exact_size] {
		testing.expect_value(t, b, u8(0xA5))
	}

	written, enc_status = pack_encode("fr-CA", entries[:], pack_buf[:exact_size])
	testing.expect_value(t, enc_status, Pack_Status.Ok)
	testing.expect_value(t, written, exact_size)

	header, val_status = pack_validate(pack_buf[:written])
	testing.expect_value(t, val_status, Pack_Status.Ok)
	testing.expect_value(t, header.entry_count, u32(len(entries)))
	testing.expect_value(t, pack_language_tag(&header), "fr-CA")

	for entry in entries {
		found_pat, found_status := pack_lookup(pack_buf[:written], entry.message_id)
		testing.expectf(t, found_status == .Ok && found_pat == entry.message_pattern, "lookup %q: status=%v pat=%q", entry.message_id, found_status, found_pat)
	}
	_, not_found := pack_lookup(pack_buf[:written], "does.not.exist")
	testing.expect_value(t, not_found, Pack_Status.Not_Found)

	// End-to-end pack lookup + MF2 formatting in the pack's language (fr-CA).
	out_buf: [128]u8
	out_len, p_stat, m_stat := pack_format_message(pack_buf[:written], "storage.files", []Message_Argument{{name = "count", value = Integer(0)}}, out_buf[:])
	testing.expect_value(t, p_stat, Pack_Status.Ok)
	testing.expect_value(t, m_stat, Message_Status.Ok)
	testing.expect_value(t, string(out_buf[:out_len]), "0 fichier")

	out_len, p_stat, m_stat = pack_format_message(pack_buf[:written], "storage.files", []Message_Argument{{name = "count", value = Integer(2)}}, out_buf[:])
	testing.expect_value(t, p_stat, Pack_Status.Ok)
	testing.expect_value(t, m_stat, Message_Status.Ok)
	testing.expect_value(t, string(out_buf[:out_len]), "2 fichiers")
}

// Adversarial tests for MODLANG1 encoding and validation: bad magic, bad
// version, non-zero reserved, non-canonical tag, size mismatch, bit-flipped
// BLAKE3 digest, unsorted IDs, duplicate IDs, truncated offsets, overlapping
// offsets, payload gaps, and corrupted MF2 payloads are all refused.
@(test)
binary_pack_adversarial_refusals :: proc(t: ^testing.T) {
	// Encode-time refusals leave destination untouched.
	dest: [512]u8
	for &b in dest {
		b = 0x5A
	}
	valid_entries := [2]Pack_Entry_Input{
		{message_id = "alpha", message_pattern = "Alpha"},
		{message_id = "beta", message_pattern = "Beta"},
	}

	// Non-canonical tag refused at encode.
	_, s := pack_encode("FR-ca", valid_entries[:], dest[:])
	testing.expect_value(t, s, Pack_Status.Invalid_Language_Tag)
	testing.expect_value(t, dest[0], u8(0x5A))

	// Duplicate IDs refused at encode.
	dup_entries := [2]Pack_Entry_Input{
		{message_id = "alpha", message_pattern = "One"},
		{message_id = "alpha", message_pattern = "Two"},
	}
	_, s = pack_encode("en", dup_entries[:], dest[:])
	testing.expect_value(t, s, Pack_Status.Duplicate_Entry)
	testing.expect_value(t, dest[0], u8(0x5A))

	// Invalid message ID refused at encode.
	bad_id_entries := [1]Pack_Entry_Input{{message_id = "bad id with space", message_pattern = "Hello"}}
	_, s = pack_encode("en", bad_id_entries[:], dest[:])
	testing.expect_value(t, s, Pack_Status.Invalid_Message_Id)

	empty_id_entries := [1]Pack_Entry_Input{{message_id = "", message_pattern = "Hello"}}
	_, s = pack_encode("en", empty_id_entries[:], dest[:])
	testing.expect_value(t, s, Pack_Status.Invalid_Message_Id)

	// Invalid MF2 syntax refused at encode.
	bad_mf2_entries := [1]Pack_Entry_Input{{message_id = "alpha", message_pattern = "Broken {$name"}}
	_, s = pack_encode("en", bad_mf2_entries[:], dest[:])
	testing.expect_value(t, s, Pack_Status.Corrupted_Payload)
	testing.expect_value(t, dest[0], u8(0x5A))

	// Build a valid 2-entry baseline pack to mutate adversarially.
	baseline_buf: [512]u8
	written, enc_status := pack_encode("en", valid_entries[:], baseline_buf[:])
	testing.expect_value(t, enc_status, Pack_Status.Ok)
	baseline := baseline_buf[:written]

	// Too short: 0 bytes and PACK_MIN_SIZE - 1 bytes.
	_, s = pack_validate(nil)
	testing.expect_value(t, s, Pack_Status.Too_Short)
	_, s = pack_validate(baseline[:PACK_MIN_SIZE - 1])
	testing.expect_value(t, s, Pack_Status.Too_Short)

	// Bad magic.
	mut: [512]u8
	copy(mut[:written], baseline)
	mut[7] = '2'
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Bad_Magic)

	// Unsupported version (0 and 2).
	copy(mut[:written], baseline)
	byte_order.write_u32_little_endian(mut[:], 8, 2)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Unsupported_Version)

	copy(mut[:written], baseline)
	byte_order.write_u32_little_endian(mut[:], 8, 0)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Unsupported_Version)

	// Non-zero reserved field.
	copy(mut[:written], baseline)
	byte_order.write_u32_little_endian(mut[:], 60, 1)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Non_Zero_Reserved)

	// Non-canonical language tag in header.
	copy(mut[:written], baseline)
	mut[25] = 'E'
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Invalid_Language_Tag)

	// Non-zero padding byte in language tag field.
	copy(mut[:written], baseline)
	mut[25 + 10] = 'x'
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Invalid_Language_Tag)

	// Size mismatch: trailing extra byte or truncated byte.
	copy(mut[:written], baseline)
	mut[written] = 0
	_, s = pack_validate(mut[:written + 1])
	testing.expect_value(t, s, Pack_Status.Size_Mismatch)
	_, s = pack_validate(baseline[:written - 1])
	testing.expect_value(t, s, Pack_Status.Size_Mismatch)

	// Bit-flipped BLAKE3 digest (last bit flipped).
	copy(mut[:written], baseline)
	mut[written - 1] ~= 0x01
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Bad_Digest)

	// Bit-flipped payload byte without updating BLAKE3 digest.
	copy(mut[:written], baseline)
	payload_start := int(byte_order.read_u32_little_endian(mut[:], 16))
	mut[payload_start] ~= 0x01
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Bad_Digest)

	// Unsorted index table (swap entry 0 and entry 1, reseal BLAKE3).
	copy(mut[:written], baseline)
	for byte_index in 0 ..< PACK_ENTRY_SIZE {
		tmp := mut[PACK_HEADER_SIZE + byte_index]
		mut[PACK_HEADER_SIZE + byte_index] = mut[PACK_HEADER_SIZE + PACK_ENTRY_SIZE + byte_index]
		mut[PACK_HEADER_SIZE + PACK_ENTRY_SIZE + byte_index] = tmp
	}
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Unsorted_Entries)

	// Duplicate message_id_hash in index table (copy hash 0 to slot 1, reseal BLAKE3).
	copy(mut[:written], baseline)
	hash0 := byte_order.read_u64_little_endian(mut[:], PACK_HEADER_SIZE)
	byte_order.write_u64_little_endian(mut[:], PACK_HEADER_SIZE + PACK_ENTRY_SIZE, hash0)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Duplicate_Entry)

	// Overlapping offsets: make entry 1 start at offset 0 (inside entry 0), reseal BLAKE3.
	copy(mut[:written], baseline)
	byte_order.write_u32_little_endian(mut[:], PACK_HEADER_SIZE + PACK_ENTRY_SIZE + 8, 0)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Overlapping_Payload)

	// Truncated payload offset/length past payload_length, reseal BLAKE3.
	copy(mut[:written], baseline)
	byte_order.write_u32_little_endian(mut[:], PACK_HEADER_SIZE + PACK_ENTRY_SIZE + 12, 999)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Truncated_Payload)

	// Unreferenced gap in payload (entry 0 length shortened by 1), reseal BLAKE3.
	copy(mut[:written], baseline)
	len0 := byte_order.read_u32_little_endian(mut[:], PACK_HEADER_SIZE + 12)
	byte_order.write_u32_little_endian(mut[:], PACK_HEADER_SIZE + 12, len0 - 1)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Corrupted_Payload)

	// Corrupted MF2 payload (unclosed '{' patched in + resealed BLAKE3).
	copy(mut[:written], baseline)
	mut[payload_start] = '{'
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Corrupted_Payload)

	// Corrupted UTF-8 byte in payload (invalid continuation byte 0x80 + resealed BLAKE3).
	copy(mut[:written], baseline)
	mut[payload_start] = 0x80
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Corrupted_Payload)

	// Lookup with invalid message_id refuses cleanly.
	_, s = pack_lookup(baseline, "")
	testing.expect_value(t, s, Pack_Status.Invalid_Message_Id)
	_, s = pack_lookup(baseline, "has space")
	testing.expect_value(t, s, Pack_Status.Invalid_Message_Id)

	// entry_count past PACK_MAX_ENTRIES is refused.
	copy(mut[:written], baseline)
	byte_order.write_u32_little_endian(mut[:], 12, PACK_MAX_ENTRIES + 1)
	reseal_pack_digest(mut[:written])
	_, s = pack_validate(mut[:written])
	testing.expect_value(t, s, Pack_Status.Too_Many_Entries)

	// pack_lookup on a truncated or corrupt pack refuses cleanly.
	_, s = pack_lookup(baseline[:10], "alpha")
	testing.expect_value(t, s, Pack_Status.Too_Short)
	copy(mut[:written], baseline)
	mut[0] = 'X'
	_, s = pack_lookup(mut[:written], "alpha")
	testing.expect_value(t, s, Pack_Status.Bad_Magic)
}

// End-to-end pipeline: language preference list + RFC 4647 fallback +
// validated MODLANG1 packs + MF2 multi-language formatting.
@(test)
end_to_end_language_list_and_pack_resolution :: proc(t: ^testing.T) {
	en_entries := [1]Pack_Entry_Input{
		{message_id = "files.count", message_pattern = ".input {$count :integer}\n.match $count\none {{{$count} file}}\n* {{{$count} files}}"},
	}
	fr_entries := [1]Pack_Entry_Input{
		{message_id = "files.count", message_pattern = ".input {$count :integer}\n.match $count\none {{{$count} fichier}}\n* {{{$count} fichiers}}"},
	}
	ru_entries := [1]Pack_Entry_Input{
		{message_id = "files.count", message_pattern = ".input {$count :integer}\n.match $count\none {{{$count} файл}}\nfew {{{$count} файла}}\n* {{{$count} файлов}}"},
	}
	ar_entries := [1]Pack_Entry_Input{
		{message_id = "files.count", message_pattern = ".input {$count :integer}\n.match $count\nzero {{0}}\none {{1}}\ntwo {{2}}\nfew {{few:{$count}}}\nmany {{many:{$count}}}\n* {{other:{$count}}}"},
	}
	ja_entries := [1]Pack_Entry_Input{
		{message_id = "files.count", message_pattern = ".input {$count :integer}\n.match $count\n* {{{$count}件}}"},
	}

	en_buf, fr_buf, ru_buf, ar_buf, ja_buf: [512]u8
	en_len, en_st := pack_encode("en", en_entries[:], en_buf[:])
	fr_len, fr_st := pack_encode("fr", fr_entries[:], fr_buf[:])
	ru_len, ru_st := pack_encode("ru", ru_entries[:], ru_buf[:])
	ar_len, ar_st := pack_encode("ar", ar_entries[:], ar_buf[:])
	ja_len, ja_st := pack_encode("ja", ja_entries[:], ja_buf[:])
	testing.expect(t, en_st == .Ok && fr_st == .Ok && ru_st == .Ok && ar_st == .Ok && ja_st == .Ok)

	packs := [5][]u8{en_buf[:en_len], fr_buf[:fr_len], ru_buf[:ru_len], ar_buf[:ar_len], ja_buf[:ja_len]}
	available_tags: [5]string
	for pack_bytes, index in packs {
		header, val_st := pack_validate(pack_bytes)
		testing.expect_value(t, val_st, Pack_Status.Ok)
		available_tags[index] = strings.clone(pack_language_tag(&header), context.temp_allocator)
	}

	// Preference ["fr-CA", "en"] resolves to the "fr" pack via RFC 4647 Lookup.
	prefs, pref_st, _ := language_list_build([]string{"fr-CA", "en"})
	testing.expect_value(t, pref_st, Language_List_Status.Ok)
	matched_idx, matched_tag, found := language_list_resolve(&prefs, available_tags[:])
	testing.expect(t, found && matched_idx == 1 && matched_tag == "fr")

	out: [128]u8
	n, ps, ms := pack_format_message(packs[matched_idx], "files.count", []Message_Argument{{name = "count", value = Integer(1)}}, out[:])
	testing.expect(t, ps == .Ok && ms == .Ok && string(out[:n]) == "1 fichier")

	// Dynamic variable option: minimumIntegerDigits=$pad.
	dyn_n, dyn_st := message_format("{$v :integer minimumIntegerDigits=$pad useGrouping=never}", "en", []Message_Argument{
		{name = "v", value = Integer(7)},
		{name = "pad", value = Integer(3)},
	}, out[:])
	testing.expect(t, dyn_st == .Ok && string(out[:dyn_n]) == "007")
}
