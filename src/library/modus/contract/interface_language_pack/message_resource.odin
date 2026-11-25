// Compiled W3C MessageFormat 2 binary/flat message table with typed variables
// and English cardinal plural rules (src/md/features/interface_language.md).
//
// Zero runtime template parsing: build tools compile `.mf2` files into sorted
// flat binary tables (`MODMF201`), and processes validate and format messages
// directly from immutable bytes.
package interface_language_pack

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: 8-byte signature for compiled MessageFormat 2 table v1.
MESSAGE_TABLE_MAGIC :: [8]u8{'M', 'O', 'D', 'M', 'F', '2', '0', '1'}
MESSAGE_TABLE_VERSION :: u32(1)
MESSAGE_TABLE_HEADER_SIZE :: 48
MESSAGE_ENTRY_SIZE :: 16
MESSAGE_VARIANT_SIZE :: 24
MESSAGE_PART_SIZE :: 16

// Closed CLDR plural categories used by compiled MF2 selectors.
Plural_Category :: enum u8 {
	Zero  = 1,
	One   = 2,
	Two   = 3,
	Few   = 4,
	Many  = 5,
	Other = 6,
}

// Closed typed variable kinds accepted by compiled MF2 messages.
Message_Var_Kind :: enum u8 {
	Integer  = 1,
	Unsigned = 2,
	Text     = 3,
}

// Closed part kinds inside one compiled MF2 variant pattern.
Message_Part_Kind :: enum u8 {
	Literal  = 1,
	Variable = 2,
}

// Closed selector matching modes for a compiled MF2 variant.
Variant_Match_Kind :: enum u8 {
	Default         = 1, // Fallback `*` variant.
	Plural_Category = 2, // Matches Plural_Category word.
	Exact_Unsigned  = 3, // Matches exact u64 value (e.g., `0`).
}

// Closed refusal reasons for compiled message table validation and formatting.
Message_Resource_Refusal :: enum u8 {
	None                   = 0,
	Buffer_Too_Small       = 1,
	Bad_Magic              = 2,
	Unsupported_Version    = 3,
	Section_Out_Of_Bounds  = 4,
	Unknown_Enum_Word      = 5,
	Message_Not_Found      = 6,
	Variable_Out_Of_Range  = 7,
	Variable_Kind_Mismatch = 8,
	Unsorted_Ids           = 9,
	Duplicate_Id           = 10,
	Output_Too_Small       = 11,
}

plural_category_of_word :: proc "contextless" (word: u64) -> (cat: Plural_Category, ok: bool) {
	return enum_word.member_of_word(Plural_Category, word)
}

message_var_kind_of_word :: proc "contextless" (word: u64) -> (kind: Message_Var_Kind, ok: bool) {
	return enum_word.member_of_word(Message_Var_Kind, word)
}

message_part_kind_of_word :: proc "contextless" (word: u64) -> (kind: Message_Part_Kind, ok: bool) {
	return enum_word.member_of_word(Message_Part_Kind, word)
}

variant_match_kind_of_word :: proc "contextless" (word: u64) -> (kind: Variant_Match_Kind, ok: bool) {
	return enum_word.member_of_word(Variant_Match_Kind, word)
}

// english_cardinal_plural implements the CLDR English cardinal rule:
// i = 1 and v = 0 -> one; everything else (including 0 and 2..max(u64)) -> other.
english_cardinal_plural :: proc "contextless" (count: u64) -> Plural_Category {
	return count == 1 ? .One : .Other
}

// Typed runtime argument passed into message_table_format.
Message_Arg :: struct {
	kind:           Message_Var_Kind,
	signed_value:   i64,
	unsigned_value: u64,
	text_value:     string,
}

// One compiled message entry sorted by message_id.
Compiled_Message_Entry :: struct {
	message_id:     u32,
	selector_var:   u32, // 0xFFFF_FFFF when message has no selector.
	first_variant:  u32,
	variant_count:  u32,
}
#assert(size_of(Compiled_Message_Entry) == MESSAGE_ENTRY_SIZE)

// Sentinel indicating a message has no selector variable.
MESSAGE_NO_SELECTOR :: u32(0xFFFF_FFFF)

// One compiled variant pattern belonging to a message.
Compiled_Message_Variant :: struct {
	match_kind_word: u32,
	first_part:      u32,
	part_count:      u32,
	reserved:        u32,
	match_value:     u64, // Plural_Category word or exact u64 match value.
}
#assert(size_of(Compiled_Message_Variant) == MESSAGE_VARIANT_SIZE)

// One compiled pattern part: literal text slice or typed variable reference.
Compiled_Message_Part :: struct {
	part_kind_word: u32,
	var_kind_word:  u32, // Variable: Message_Var_Kind; Literal: 0.
	offset_or_var:  u32, // Literal: string pool offset; Variable: arg index.
	length:         u32, // Literal: byte length; Variable: 0.
}
#assert(size_of(Compiled_Message_Part) == MESSAGE_PART_SIZE)

Message_Table_Header :: struct {
	magic:           [8]u8,
	version:         u32,
	total_bytes:     u32,
	entries_offset:  u32,
	entries_count:   u32,
	variants_offset: u32,
	variants_count:  u32,
	parts_offset:    u32,
	parts_count:     u32,
	strings_offset:  u32,
	strings_bytes:   u32,
}
#assert(size_of(Message_Table_Header) == MESSAGE_TABLE_HEADER_SIZE)

Message_Table_Input :: struct {
	entries:  []Compiled_Message_Entry,
	variants: []Compiled_Message_Variant,
	parts:    []Compiled_Message_Part,
	strings:  []u8,
}

// Standard English message IDs compiled by english_system_messages_encode.
English_Message_Id :: enum u32 {
	Disk_Blocks_Free  = 1,
	Processes_Running = 2,
	Grant_Refused     = 3,
}

// message_table_encode validates and encodes a compiled W3C MF2 message table.
message_table_encode :: proc "contextless" (input: Message_Table_Input, out: []u8) -> (written: int, refusal: Message_Resource_Refusal) {
	entries_bytes := u64(len(input.entries)) * MESSAGE_ENTRY_SIZE
	variants_bytes := u64(len(input.variants)) * MESSAGE_VARIANT_SIZE
	parts_bytes := u64(len(input.parts)) * MESSAGE_PART_SIZE
	strings_bytes := u64(len(input.strings))
	total := u64(MESSAGE_TABLE_HEADER_SIZE) + entries_bytes + variants_bytes + parts_bytes + strings_bytes
	if total > u64(len(out)) || total > u64(max(u32)) {
		return 0, .Buffer_Too_Small
	}

	// Validate entries are strictly sorted with unique IDs and valid variant spans.
	for entry, idx in input.entries {
		if idx > 0 {
			prev := input.entries[idx - 1].message_id
			if entry.message_id == prev {
				return 0, .Duplicate_Id
			}
			if entry.message_id < prev {
				return 0, .Unsorted_Ids
			}
		}
		if entry.variant_count == 0 || u64(entry.first_variant) + u64(entry.variant_count) > u64(len(input.variants)) {
			return 0, .Section_Out_Of_Bounds
		}
	}
	for variant in input.variants {
		if variant.reserved != 0 {
			return 0, .Section_Out_Of_Bounds
		}
		mk, mk_ok := variant_match_kind_of_word(u64(variant.match_kind_word))
		if !mk_ok {
			return 0, .Unknown_Enum_Word
		}
		if mk == .Plural_Category {
			if _, pk_ok := plural_category_of_word(variant.match_value); !pk_ok {
				return 0, .Unknown_Enum_Word
			}
		}
		if u64(variant.first_part) + u64(variant.part_count) > u64(len(input.parts)) {
			return 0, .Section_Out_Of_Bounds
		}
	}
	for part in input.parts {
		pk, pk_ok := message_part_kind_of_word(u64(part.part_kind_word))
		if !pk_ok {
			return 0, .Unknown_Enum_Word
		}
		switch pk {
		case .Literal:
			if part.var_kind_word != 0 || u64(part.offset_or_var) + u64(part.length) > strings_bytes {
				return 0, .Section_Out_Of_Bounds
			}
		case .Variable:
			if _, vk_ok := message_var_kind_of_word(u64(part.var_kind_word)); !vk_ok {
				return 0, .Unknown_Enum_Word
			}
			if part.length != 0 {
				return 0, .Section_Out_Of_Bounds
			}
		}
	}

	cursor := u32(MESSAGE_TABLE_HEADER_SIZE)
	entries_off := len(input.entries) > 0 ? cursor : 0
	for entry in input.entries {
		at := int(cursor)
		byte_order.write_u32_little_endian(out, at + 0, entry.message_id)
		byte_order.write_u32_little_endian(out, at + 4, entry.selector_var)
		byte_order.write_u32_little_endian(out, at + 8, entry.first_variant)
		byte_order.write_u32_little_endian(out, at + 12, entry.variant_count)
		cursor += MESSAGE_ENTRY_SIZE
	}
	variants_off := len(input.variants) > 0 ? cursor : 0
	for variant in input.variants {
		at := int(cursor)
		byte_order.write_u32_little_endian(out, at + 0, variant.match_kind_word)
		byte_order.write_u32_little_endian(out, at + 4, variant.first_part)
		byte_order.write_u32_little_endian(out, at + 8, variant.part_count)
		byte_order.write_u32_little_endian(out, at + 12, 0)
		byte_order.write_u64_little_endian(out, at + 16, variant.match_value)
		cursor += MESSAGE_VARIANT_SIZE
	}
	parts_off := len(input.parts) > 0 ? cursor : 0
	for part in input.parts {
		at := int(cursor)
		byte_order.write_u32_little_endian(out, at + 0, part.part_kind_word)
		byte_order.write_u32_little_endian(out, at + 4, part.var_kind_word)
		byte_order.write_u32_little_endian(out, at + 8, part.offset_or_var)
		byte_order.write_u32_little_endian(out, at + 12, part.length)
		cursor += MESSAGE_PART_SIZE
	}
	strings_off := len(input.strings) > 0 ? cursor : 0
	if len(input.strings) > 0 {
		copy(out[int(cursor):int(cursor) + len(input.strings)], input.strings)
		cursor += u32(len(input.strings))
	}

	magic := MESSAGE_TABLE_MAGIC
	for i in 0 ..< 8 {
		out[i] = magic[i]
	}
	byte_order.write_u32_little_endian(out, 8, MESSAGE_TABLE_VERSION)
	byte_order.write_u32_little_endian(out, 12, cursor)
	byte_order.write_u32_little_endian(out, 16, entries_off)
	byte_order.write_u32_little_endian(out, 20, u32(len(input.entries)))
	byte_order.write_u32_little_endian(out, 24, variants_off)
	byte_order.write_u32_little_endian(out, 28, u32(len(input.variants)))
	byte_order.write_u32_little_endian(out, 32, parts_off)
	byte_order.write_u32_little_endian(out, 36, u32(len(input.parts)))
	byte_order.write_u32_little_endian(out, 40, strings_off)
	byte_order.write_u32_little_endian(out, 44, u32(len(input.strings)))
	return int(cursor), .None
}

@(private = "file")
read_entry :: proc "contextless" (bytes: []u8, header: Message_Table_Header, index: u32) -> Compiled_Message_Entry {
	at := int(header.entries_offset) + int(index) * MESSAGE_ENTRY_SIZE
	return Compiled_Message_Entry{
		message_id    = byte_order.read_u32_little_endian(bytes, at + 0),
		selector_var  = byte_order.read_u32_little_endian(bytes, at + 4),
		first_variant = byte_order.read_u32_little_endian(bytes, at + 8),
		variant_count = byte_order.read_u32_little_endian(bytes, at + 12),
	}
}

@(private = "file")
read_variant :: proc "contextless" (bytes: []u8, header: Message_Table_Header, index: u32) -> Compiled_Message_Variant {
	at := int(header.variants_offset) + int(index) * MESSAGE_VARIANT_SIZE
	return Compiled_Message_Variant{
		match_kind_word = byte_order.read_u32_little_endian(bytes, at + 0),
		first_part      = byte_order.read_u32_little_endian(bytes, at + 4),
		part_count      = byte_order.read_u32_little_endian(bytes, at + 8),
		reserved        = byte_order.read_u32_little_endian(bytes, at + 12),
		match_value     = byte_order.read_u64_little_endian(bytes, at + 16),
	}
}

@(private = "file")
read_part :: proc "contextless" (bytes: []u8, header: Message_Table_Header, index: u32) -> Compiled_Message_Part {
	at := int(header.parts_offset) + int(index) * MESSAGE_PART_SIZE
	return Compiled_Message_Part{
		part_kind_word = byte_order.read_u32_little_endian(bytes, at + 0),
		var_kind_word  = byte_order.read_u32_little_endian(bytes, at + 4),
		offset_or_var  = byte_order.read_u32_little_endian(bytes, at + 8),
		length         = byte_order.read_u32_little_endian(bytes, at + 12),
	}
}

// message_table_validate verifies an untrusted compiled MF2 message table.
message_table_validate :: proc "contextless" (bytes: []u8) -> (header: Message_Table_Header, refusal: Message_Resource_Refusal) {
	if len(bytes) < MESSAGE_TABLE_HEADER_SIZE {
		return {}, .Buffer_Too_Small
	}
	for i in 0 ..< 8 {
		header.magic[i] = bytes[i]
	}
	if header.magic != MESSAGE_TABLE_MAGIC {
		return {}, .Bad_Magic
	}
	header.version = byte_order.read_u32_little_endian(bytes, 8)
	if header.version != MESSAGE_TABLE_VERSION {
		return {}, .Unsupported_Version
	}
	header.total_bytes = byte_order.read_u32_little_endian(bytes, 12)
	header.entries_offset = byte_order.read_u32_little_endian(bytes, 16)
	header.entries_count = byte_order.read_u32_little_endian(bytes, 20)
	header.variants_offset = byte_order.read_u32_little_endian(bytes, 24)
	header.variants_count = byte_order.read_u32_little_endian(bytes, 28)
	header.parts_offset = byte_order.read_u32_little_endian(bytes, 32)
	header.parts_count = byte_order.read_u32_little_endian(bytes, 36)
	header.strings_offset = byte_order.read_u32_little_endian(bytes, 40)
	header.strings_bytes = byte_order.read_u32_little_endian(bytes, 44)

	if header.total_bytes < MESSAGE_TABLE_HEADER_SIZE || u64(header.total_bytes) > u64(len(bytes)) {
		return {}, .Section_Out_Of_Bounds
	}
	total := u64(header.total_bytes)
	check_range :: proc "contextless" (off, count: u32, elem: u64, limit: u64) -> bool {
		if count == 0 {
			return off == 0
		}
		if off < MESSAGE_TABLE_HEADER_SIZE {
			return false
		}
		size := u64(count) * elem
		return size <= limit && u64(off) <= limit - size
	}
	if !check_range(header.entries_offset, header.entries_count, MESSAGE_ENTRY_SIZE, total) ||
		!check_range(header.variants_offset, header.variants_count, MESSAGE_VARIANT_SIZE, total) ||
		!check_range(header.parts_offset, header.parts_count, MESSAGE_PART_SIZE, total) ||
		!check_range(header.strings_offset, header.strings_bytes, 1, total) {
		return {}, .Section_Out_Of_Bounds
	}

	for idx in u32(0) ..< header.entries_count {
		entry := read_entry(bytes, header, idx)
		if idx > 0 {
			prev := read_entry(bytes, header, idx - 1).message_id
			if entry.message_id == prev {
				return {}, .Duplicate_Id
			}
			if entry.message_id < prev {
				return {}, .Unsorted_Ids
			}
		}
		if entry.variant_count == 0 || u64(entry.first_variant) + u64(entry.variant_count) > u64(header.variants_count) {
			return {}, .Section_Out_Of_Bounds
		}
	}
	for idx in u32(0) ..< header.variants_count {
		variant := read_variant(bytes, header, idx)
		if variant.reserved != 0 {
			return {}, .Section_Out_Of_Bounds
		}
		mk, mk_ok := variant_match_kind_of_word(u64(variant.match_kind_word))
		if !mk_ok {
			return {}, .Unknown_Enum_Word
		}
		if mk == .Plural_Category {
			if _, pk_ok := plural_category_of_word(variant.match_value); !pk_ok {
				return {}, .Unknown_Enum_Word
			}
		}
		if u64(variant.first_part) + u64(variant.part_count) > u64(header.parts_count) {
			return {}, .Section_Out_Of_Bounds
		}
	}
	for idx in u32(0) ..< header.parts_count {
		part := read_part(bytes, header, idx)
		pk, pk_ok := message_part_kind_of_word(u64(part.part_kind_word))
		if !pk_ok {
			return {}, .Unknown_Enum_Word
		}
		switch pk {
		case .Literal:
			if part.var_kind_word != 0 || u64(part.offset_or_var) + u64(part.length) > u64(header.strings_bytes) {
				return {}, .Section_Out_Of_Bounds
			}
		case .Variable:
			if _, vk_ok := message_var_kind_of_word(u64(part.var_kind_word)); !vk_ok {
				return {}, .Unknown_Enum_Word
			}
			if part.length != 0 {
				return {}, .Section_Out_Of_Bounds
			}
		}
	}
	return header, .None
}

@(private = "file")
write_u64_decimal :: proc "contextless" (dst: []u8, pos: ^int, value: u64) -> bool {
	// Format property: largest u64 needs 20 decimal digits.
	digits: [20]u8
	count := 0
	v := value
	for {
		digits[count] = u8('0' + (v % 10))
		count += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	if count > len(dst) - pos^ {
		return false
	}
	for i in 0 ..< count {
		dst[pos^ + i] = digits[count - 1 - i]
	}
	pos^ += count
	return true
}

@(private = "file")
write_i64_decimal :: proc "contextless" (dst: []u8, pos: ^int, value: i64) -> bool {
	if value < 0 {
		if pos^ >= len(dst) {
			return false
		}
		dst[pos^] = '-'
		pos^ += 1
		mag := u64(-(value + 1)) + 1
		return write_u64_decimal(dst, pos, mag)
	}
	return write_u64_decimal(dst, pos, u64(value))
}

// message_table_format selects the matching variant and formats message_id
// directly into out with zero runtime template parsing or heap allocation.
message_table_format :: proc "contextless" (table_bytes: []u8, message_id: u32, args: []Message_Arg, out: []u8) -> (written: int, refusal: Message_Resource_Refusal) {
	header, val_ref := message_table_validate(table_bytes)
	if val_ref != .None {
		return 0, val_ref
	}
	// Binary search sorted message entries.
	low := u32(0)
	high := header.entries_count
	found := false
	entry: Compiled_Message_Entry
	for low < high {
		mid := low + (high - low) / 2
		cand := read_entry(table_bytes, header, mid)
		if cand.message_id == message_id {
			entry = cand
			found = true
			break
		}
		if cand.message_id < message_id {
			low = mid + 1
		} else {
			high = mid
		}
	}
	if !found {
		return 0, .Message_Not_Found
	}

	// Select variant: Exact_Unsigned wins over Plural_Category, which wins over Default.
	chosen_variant: Compiled_Message_Variant
	chosen_priority := 0
	has_selector := entry.selector_var != MESSAGE_NO_SELECTOR
	selector_u64 := u64(0)
	selector_plural := Plural_Category.Other
	if has_selector {
		if int(entry.selector_var) >= len(args) {
			return 0, .Variable_Out_Of_Range
		}
		sel_arg := args[entry.selector_var]
		switch sel_arg.kind {
		case .Unsigned:
			selector_u64 = sel_arg.unsigned_value
		case .Integer:
			selector_u64 = sel_arg.signed_value < 0 ? u64(-(sel_arg.signed_value + 1)) + 1 : u64(sel_arg.signed_value)
		case .Text:
			return 0, .Variable_Kind_Mismatch
		}
		selector_plural = english_cardinal_plural(selector_u64)
	}

	for v_idx in entry.first_variant ..< entry.first_variant + entry.variant_count {
		variant := read_variant(table_bytes, header, v_idx)
		mk, _ := variant_match_kind_of_word(u64(variant.match_kind_word))
		switch mk {
		case .Exact_Unsigned:
			if has_selector && variant.match_value == selector_u64 && chosen_priority < 3 {
				chosen_variant = variant
				chosen_priority = 3
			}
		case .Plural_Category:
			if has_selector && variant.match_value == u64(selector_plural) && chosen_priority < 2 {
				chosen_variant = variant
				chosen_priority = 2
			}
		case .Default:
			if chosen_priority < 1 {
				chosen_variant = variant
				chosen_priority = 1
			}
		}
	}
	if chosen_priority == 0 {
		return 0, .Message_Not_Found
	}

	pos := 0
	for p_idx in chosen_variant.first_part ..< chosen_variant.first_part + chosen_variant.part_count {
		part := read_part(table_bytes, header, p_idx)
		pk, _ := message_part_kind_of_word(u64(part.part_kind_word))
		switch pk {
		case .Literal:
			if int(part.length) > len(out) - pos {
				return 0, .Output_Too_Small
			}
			src_start := int(header.strings_offset) + int(part.offset_or_var)
			copy(out[pos : pos + int(part.length)], table_bytes[src_start : src_start + int(part.length)])
			pos += int(part.length)
		case .Variable:
			if int(part.offset_or_var) >= len(args) {
				return 0, .Variable_Out_Of_Range
			}
			arg := args[part.offset_or_var]
			want_kind, _ := message_var_kind_of_word(u64(part.var_kind_word))
			if arg.kind != want_kind {
				return 0, .Variable_Kind_Mismatch
			}
			switch want_kind {
			case .Unsigned:
				if !write_u64_decimal(out, &pos, arg.unsigned_value) {
					return 0, .Output_Too_Small
				}
			case .Integer:
				if !write_i64_decimal(out, &pos, arg.signed_value) {
					return 0, .Output_Too_Small
				}
			case .Text:
				if len(arg.text_value) > len(out) - pos {
					return 0, .Output_Too_Small
				}
				for i in 0 ..< len(arg.text_value) {
					out[pos + i] = arg.text_value[i]
				}
				pos += len(arg.text_value)
			}
		}
	}
	return pos, .None
}

// english_system_messages_encode writes the baseline compiled English W3C MF2
// message table into out (disk_blocks_free: "1 block" / "N blocks",
// processes_running: "1 process" / "N processes", grant_refused: "grant <name> refused").
english_system_messages_encode :: proc "contextless" (out: []u8) -> (written: int, refusal: Message_Resource_Refusal) {
	// String pool slices:
	//  0..6   " block"      (6)
	//  6..13  " blocks"     (7)
	// 13..21  " process"    (8)
	// 21..31  " processes"  (10)
	// 31..37  "grant "      (6)
	// 37..45  " refused"    (8)
	pool := " block blocks process processesgrant  refused"
	parts := [?]Compiled_Message_Part{
		// Disk_Blocks_Free one: {$0} " block"
		{part_kind_word = u32(Message_Part_Kind.Variable), var_kind_word = u32(Message_Var_Kind.Unsigned), offset_or_var = 0},
		{part_kind_word = u32(Message_Part_Kind.Literal), offset_or_var = 0, length = 6},
		// Disk_Blocks_Free other: {$0} " blocks"
		{part_kind_word = u32(Message_Part_Kind.Variable), var_kind_word = u32(Message_Var_Kind.Unsigned), offset_or_var = 0},
		{part_kind_word = u32(Message_Part_Kind.Literal), offset_or_var = 6, length = 7},
		// Processes_Running one: {$0} " process"
		{part_kind_word = u32(Message_Part_Kind.Variable), var_kind_word = u32(Message_Var_Kind.Unsigned), offset_or_var = 0},
		{part_kind_word = u32(Message_Part_Kind.Literal), offset_or_var = 13, length = 8},
		// Processes_Running other: {$0} " processes"
		{part_kind_word = u32(Message_Part_Kind.Variable), var_kind_word = u32(Message_Var_Kind.Unsigned), offset_or_var = 0},
		{part_kind_word = u32(Message_Part_Kind.Literal), offset_or_var = 21, length = 10},
		// Grant_Refused default: "grant " {$0} " refused"
		{part_kind_word = u32(Message_Part_Kind.Literal), offset_or_var = 31, length = 6},
		{part_kind_word = u32(Message_Part_Kind.Variable), var_kind_word = u32(Message_Var_Kind.Text), offset_or_var = 0},
		{part_kind_word = u32(Message_Part_Kind.Literal), offset_or_var = 37, length = 8},
	}
	variants := [?]Compiled_Message_Variant{
		{match_kind_word = u32(Variant_Match_Kind.Plural_Category), first_part = 0, part_count = 2, match_value = u64(Plural_Category.One)},
		{match_kind_word = u32(Variant_Match_Kind.Default), first_part = 2, part_count = 2},
		{match_kind_word = u32(Variant_Match_Kind.Plural_Category), first_part = 4, part_count = 2, match_value = u64(Plural_Category.One)},
		{match_kind_word = u32(Variant_Match_Kind.Default), first_part = 6, part_count = 2},
		{match_kind_word = u32(Variant_Match_Kind.Default), first_part = 8, part_count = 3},
	}
	entries := [?]Compiled_Message_Entry{
		{message_id = u32(English_Message_Id.Disk_Blocks_Free), selector_var = 0, first_variant = 0, variant_count = 2},
		{message_id = u32(English_Message_Id.Processes_Running), selector_var = 0, first_variant = 2, variant_count = 2},
		{message_id = u32(English_Message_Id.Grant_Refused), selector_var = MESSAGE_NO_SELECTOR, first_variant = 4, variant_count = 1},
	}
	return message_table_encode({
		entries  = entries[:],
		variants = variants[:],
		parts    = parts[:],
		strings  = transmute([]u8)pool,
	}, out)
}
