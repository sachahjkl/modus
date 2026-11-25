#+build !freestanding
// Adversarial host tests for modus:contract/interface_language_pack:
// BCP 47 / CLDR tags & aliases, compiled W3C MF2 message tables, and
// content-addressed language / script-font pack manifests.
package interface_language_pack

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

@(test)
cldr_tags_refuse_malformed_and_canonicalize_aliases :: proc(t: ^testing.T) {
	// Malformed tags refused before any call runs.
	_, ref := cldr_tag_parse("")
	testing.expect_value(t, ref, Tag_Refusal.Empty)

	_, ref = cldr_tag_parse(strings.repeat("a", CLDR_TAG_TEXT_LIMIT + 1, context.temp_allocator))
	testing.expect_value(t, ref, Tag_Refusal.Too_Long)

	_, ref = cldr_tag_parse("en_US")
	testing.expect_value(t, ref, Tag_Refusal.Bad_Character)

	_, ref = cldr_tag_parse("en-")
	testing.expect_value(t, ref, Tag_Refusal.Bad_Character)

	_, ref = cldr_tag_parse("zz")
	testing.expect_value(t, ref, Tag_Refusal.Unknown_Subtag)

	_, ref = cldr_tag_parse("x-private")
	testing.expect_value(t, ref, Tag_Refusal.Private_Use_Refused)

	_, ref = cldr_tag_parse("en-x-custom")
	testing.expect_value(t, ref, Tag_Refusal.Private_Use_Refused)

	_, ref = cldr_tag_parse("en-t-fr")
	testing.expect_value(t, ref, Tag_Refusal.Extension_Refused)

	_, ref = cldr_tag_parse("en-1996-1996")
	testing.expect_value(t, ref, Tag_Refusal.Duplicate_Variant)

	_, ref = cldr_tag_parse("en-1996-1997-1998")
	testing.expect_value(t, ref, Tag_Refusal.Too_Many_Variants)

	// Canonical alias mappings (`iw`->`he`, `in`->`id`, `ji`->`yi`, `mo`->`ro`, `sr-YU`->`sr-RS`, `FR-latn-ca`->`fr-Latn-CA`).
	cases := [?][2]string{
		{"iw", "he"},
		{"in", "id"},
		{"ji", "yi"},
		{"mo", "ro"},
		{"sr-YU", "sr-RS"},
		{"FR-latn-ca", "fr-Latn-CA"},
		{"en-1997-1996", "en-1996-1997"},
	}
	buf: [CLDR_TAG_TEXT_LIMIT]u8
	for pair in cases {
		parsed, ok_ref := cldr_tag_parse(pair[0])
		testing.expect_value(t, ok_ref, Tag_Refusal.None)
		testing.expect_value(t, cldr_tag_record_valid(parsed), Tag_Refusal.None)
		n, fmt_ref := cldr_tag_format(parsed, buf[:])
		testing.expect_value(t, fmt_ref, Tag_Refusal.None)
		testing.expect_value(t, string(buf[:n]), pair[1])
	}

	// Border record validator refuses deprecated alias or non-canonical uppercase language.
	bad_rec: Cldr_Language_Tag
	bad_rec.language[0] = 'i'
	bad_rec.language[1] = 'w'
	testing.expect_value(t, cldr_tag_record_valid(bad_rec), Tag_Refusal.Non_Canonical)

	upper_rec: Cldr_Language_Tag
	upper_rec.language[0] = 'E'
	upper_rec.language[1] = 'N'
	testing.expect_value(t, cldr_tag_record_valid(upper_rec), Tag_Refusal.Non_Canonical)
}

@(test)
compiled_english_mf2_messages_format_plurals_and_refuse_faults :: proc(t: ^testing.T) {
	table_buf: [2048]u8
	written, enc_ref := english_system_messages_encode(table_buf[:])
	testing.expect_value(t, enc_ref, Message_Resource_Refusal.None)
	table := table_buf[:written]

	// Plural edge cases: 0, 1, 2, max(u64).
	out: [128]u8
	cases := [?]struct {
		count:    u64,
		expected: string,
	}{
		{0, "0 blocks"},
		{1, "1 block"},
		{2, "2 blocks"},
		{max(u64), "18446744073709551615 blocks"},
	}
	for c in cases {
		args := [1]Message_Arg{{kind = .Unsigned, unsigned_value = c.count}}
		n, fmt_ref := message_table_format(table, u32(English_Message_Id.Disk_Blocks_Free), args[:], out[:])
		testing.expect_value(t, fmt_ref, Message_Resource_Refusal.None)
		testing.expect_value(t, string(out[:n]), c.expected)
	}

	// Typed text variable formatting.
	grant_args := [1]Message_Arg{{kind = .Text, text_value = "store"}}
	n, g_ref := message_table_format(table, u32(English_Message_Id.Grant_Refused), grant_args[:], out[:])
	testing.expect_value(t, g_ref, Message_Resource_Refusal.None)
	testing.expect_value(t, string(out[:n]), "grant store refused")

	// Refusals: missing message ID, missing arg, wrong arg kind, short output buffer.
	_, err := message_table_format(table, 999, nil, out[:])
	testing.expect_value(t, err, Message_Resource_Refusal.Message_Not_Found)

	_, err = message_table_format(table, u32(English_Message_Id.Disk_Blocks_Free), nil, out[:])
	testing.expect_value(t, err, Message_Resource_Refusal.Variable_Out_Of_Range)

	wrong_args := [1]Message_Arg{{kind = .Text, text_value = "oops"}}
	_, err = message_table_format(table, u32(English_Message_Id.Disk_Blocks_Free), wrong_args[:], out[:])
	testing.expect_value(t, err, Message_Resource_Refusal.Variable_Kind_Mismatch)

	tiny_out: [3]u8
	_, err = message_table_format(table, u32(English_Message_Id.Grant_Refused), grant_args[:], tiny_out[:])
	testing.expect_value(t, err, Message_Resource_Refusal.Output_Too_Small)

	// Hostile table corruption: bad magic, unsupported version, truncated slice.
	corrupt := make([]u8, written)
	defer delete(corrupt)
	copy(corrupt, table)
	corrupt[0] = '!'
	_, v_err := message_table_validate(corrupt)
	testing.expect_value(t, v_err, Message_Resource_Refusal.Bad_Magic)

	copy(corrupt, table)
	byte_order.write_u32_little_endian(corrupt, 8, 99)
	_, v_err = message_table_validate(corrupt)
	testing.expect_value(t, v_err, Message_Resource_Refusal.Unsupported_Version)

	_, v_err = message_table_validate(table[:MESSAGE_TABLE_HEADER_SIZE - 1])
	testing.expect_value(t, v_err, Message_Resource_Refusal.Buffer_Too_Small)
}

@(test)
content_addressed_language_and_script_font_manifests_round_trip_and_refuse_faults :: proc(t: ^testing.T) {
	fr_tag, fr_ref := cldr_tag_parse("fr")
	testing.expect_value(t, fr_ref, Tag_Refusal.None)
	ja_tag, ja_ref := cldr_tag_parse("ja")
	testing.expect_value(t, ja_ref, Tag_Refusal.None)

	hash_fr := blake3.hash(transmute([]u8)string("fr-pack-v1"))
	hash_ja := blake3.hash(transmute([]u8)string("ja-pack-v1"))
	hash_arab := blake3.hash(transmute([]u8)string("noto-arabic-v1"))
	hash_cjk := blake3.hash(transmute([]u8)string("noto-cjk-v1"))

	// Refuse zero hash and zero byte size.
	bad_lang: Language_Pack_Manifest
	bad_lang.cldr_version = 49
	bad_lang.entry_count = 1
	bad_lang.entries[0] = {tag = fr_tag, object_hash = {}, byte_size = 1024}
	wire: [4096]u8
	_, ref := language_pack_manifest_encode(&bad_lang, wire[:])
	testing.expect_value(t, ref, Pack_Manifest_Refusal.Zero_Hash)

	bad_lang.entries[0].object_hash = hash_fr
	bad_lang.entries[0].byte_size = 0
	_, ref = language_pack_manifest_encode(&bad_lang, wire[:])
	testing.expect_value(t, ref, Pack_Manifest_Refusal.Zero_Byte_Size)

	// Duplicate language tag refused.
	bad_lang.entries[0].byte_size = 32768
	bad_lang.entries[1] = {tag = fr_tag, object_hash = hash_ja, byte_size = 16384}
	bad_lang.entry_count = 2
	_, ref = language_pack_manifest_encode(&bad_lang, wire[:])
	testing.expect_value(t, ref, Pack_Manifest_Refusal.Duplicate_Entry)

	// Valid two-pack language manifest round-trip and truncation refusal.
	bad_lang.entries[1].tag = ja_tag
	lang_len, l_ref := language_pack_manifest_encode(&bad_lang, wire[:])
	testing.expect_value(t, l_ref, Pack_Manifest_Refusal.None)

	decoded_lang: Language_Pack_Manifest
	testing.expect_value(t, language_pack_manifest_decode(wire[:lang_len - 1], &decoded_lang), Pack_Manifest_Refusal.Bad_Length)
	testing.expect_value(t, language_pack_manifest_decode(wire[:lang_len], &decoded_lang), Pack_Manifest_Refusal.None)
	testing.expect_value(t, decoded_lang.cldr_version, u32(49))
	testing.expect_value(t, decoded_lang.entry_count, u32(2))

	// Script font manifest round-trip and unknown Script_Code refusal.
	font_manifest: Script_Font_Pack_Manifest
	font_manifest.unicode_version = 18
	font_manifest.entry_count = 2
	font_manifest.entries[0] = {script = .Arabic, object_hash = hash_arab, byte_size = 682836}
	font_manifest.entries[1] = {script = .Han_Cjk, object_hash = hash_cjk, byte_size = 32682580}

	font_wire: [2048]u8
	font_len, f_ref := script_font_manifest_encode(&font_manifest, font_wire[:])
	testing.expect_value(t, f_ref, Pack_Manifest_Refusal.None)

	// Corrupt script enum byte to unknown value 99.
	corrupt_font := font_wire
	corrupt_font[PACK_MANIFEST_HEADER_SIZE] = 99
	decoded_font: Script_Font_Pack_Manifest
	testing.expect_value(t, script_font_manifest_decode(corrupt_font[:font_len], &decoded_font), Pack_Manifest_Refusal.Unknown_Enum_Word)
	testing.expect_value(t, script_font_manifest_decode(font_wire[:font_len], &decoded_font), Pack_Manifest_Refusal.None)

	// Selective fetch collects ONLY the hashes requested by the plan (fr + Han_Cjk, not ja or Arabic).
	wanted_langs := [1]Cldr_Language_Tag{fr_tag}
	wanted_scripts := [1]Script_Code{.Han_Cjk}
	fetch_hashes: [4]blake3.Hash
	n_fetch, p_ref := plan_fetch_hashes_collect(&decoded_lang, wanted_langs[:], &decoded_font, wanted_scripts[:], fetch_hashes[:])
	testing.expect_value(t, p_ref, Pack_Manifest_Refusal.None)
	testing.expect_value(t, n_fetch, 2)
	testing.expect_value(t, fetch_hashes[0], hash_fr)
	testing.expect_value(t, fetch_hashes[1], hash_cjk)
}
