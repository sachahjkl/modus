package lex_evaluator

import "modus:contract/errors"

// A list that a host keeps past the line that made it: a variable of the
// console (src/md/features/declarations.md, "The functions of layer 4 as
// built"). The line forced the list whole, so its items are values: a copy
// keeps them. The host keeps the items and the bytes of their texts and
// records in its own memory, and gives them back to each later line that
// reads them, as a list of that line.

// The items of one kept list, the items of its nested lists included.
KEPT_LIST_ITEM_CAPACITY :: 64

// The bytes of the texts and the records of the items of one kept list.
KEPT_LIST_BYTE_CAPACITY :: 32 * 1024

// The copy of a list before it goes into the memory of the host: the host
// keeps its old list until the whole new one fits, and `x = map(x, f)`
// reads the old items of x while the new ones are copied.
List_Keeping :: struct {
	items:      [KEPT_LIST_ITEM_CAPACITY]Value,
	item_count: int,
	bytes:      [KEPT_LIST_BYTE_CAPACITY]u8,
	byte_count: int,
}

// Why a list was not kept. The values are fixed: a test names the member.
List_Keep_Refusal :: enum u8 {
	None                = 0,
	Items_Full          = 1, // More than KEPT_LIST_ITEM_CAPACITY items in all: record Over_Limit.
	Bytes_Full          = 2, // More than KEPT_LIST_BYTE_CAPACITY bytes of texts and records: record Over_Limit, unit Bytes.
	Function            = 3, // A function reads the thunks of its line, which end with the line.
	Table               = 4, // A table keeps its rows in a memory of its own, whole.
	Hash                = 5, // A hash lives in the hash pool of the evaluation of its line.
	Description_Of_Line = 6, // A record whose description the host made in the memory of the line.
	Kind                = 7, // A value that no list keeps: kind names it.
}

// The outcome of list_keep: the refusal, the kind of the refused item, and
// the error record of a bound.
List_Keep_Result :: struct {
	refusal: List_Keep_Refusal,
	kind:    Kind,
	record:  errors.Error_Record,
}

// list_keep copies a List of an evaluation into keeping, which it empties
// first: the items of the list, then the items of each nested list after
// them, and the bytes of each Text and Record. A nested List names its first
// item in keeping. description_of_line says if the description of a record
// lives in the memory of the line; nil: none does. The depth is bounded:
// each nested list is an item, and the items are bounded.
list_keep :: proc "contextless" (keeping: ^List_Keeping, evaluation: ^Evaluation, value: Value, description_of_line: proc "contextless" (file: []u8) -> bool = nil) -> List_Keep_Result {
	keeping.item_count, keeping.byte_count = 0, 0
	_, result := list_keep_items(keeping, evaluation, value, description_of_line)
	return result
}

@(private)
list_keep_items :: proc "contextless" (keeping: ^List_Keeping, evaluation: ^Evaluation, value: Value, description_of_line: proc "contextless" (file: []u8) -> bool) -> (first: int, result: List_Keep_Result) {
	items := list_items_of(evaluation, value)
	if len(items) > KEPT_LIST_ITEM_CAPACITY - keeping.item_count {
		count := i64(keeping.item_count + len(items))
		return 0, {refusal = .Items_Full, record = errors.error_make(.Over_Limit, .None, 0, count, KEPT_LIST_ITEM_CAPACITY)}
	}
	first = keeping.item_count
	keeping.item_count += len(items)
	for item, index in items {
		copied := item
		switch item.kind {
		case .Integer, .Boolean, .Handle, .Enum:
			// The value holds no memory of the line. An Enum names the module
			// file of its enum, which stays while the module does.
		case .Text:
			bytes, kept := kept_bytes_add(keeping, transmute([]u8)item.text, 1)
			if !kept {
				return 0, kept_bytes_refusal(keeping, len(item.text))
			}
			copied.text = string(bytes)
		case .Record:
			if description_of_line != nil && description_of_line(item.file) {
				return 0, {refusal = .Description_Of_Line, kind = .Record}
			}
			bytes, kept := kept_bytes_add(keeping, item.record, 8)
			if !kept {
				return 0, kept_bytes_refusal(keeping, len(item.record))
			}
			copied.record = bytes
		case .List:
			nested, nested_result := list_keep_items(keeping, evaluation, item, description_of_line)
			if nested_result.refusal != .None {
				return 0, nested_result
			}
			copied.integer = i64(nested)
		case .Function:
			return 0, {refusal = .Function, kind = .Function}
		case .Table:
			return 0, {refusal = .Table, kind = .Table}
		case .Hash:
			return 0, {refusal = .Hash, kind = .Hash}
		case .None, .Bytes, .Stream, .Record_Input, .Record_Literal, .Member, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
			// The evaluator refuses an untyped item and an item with no value
			// before; the others have no place in a list of the console.
			return 0, {refusal = .Kind, kind = item.kind}
		}
		keeping.items[first + index] = copied
	}
	return first, {}
}

// kept_bytes_add copies bytes into keeping at a place of the alignment.
@(private)
kept_bytes_add :: proc "contextless" (keeping: ^List_Keeping, bytes: []u8, alignment: int) -> (kept: []u8, ok: bool) {
	start := (keeping.byte_count + alignment - 1) &~ (alignment - 1)
	if start > len(keeping.bytes) || len(bytes) > len(keeping.bytes) - start {
		return nil, false
	}
	keeping.byte_count = start + len(bytes)
	kept = keeping.bytes[start:keeping.byte_count]
	copy(kept, bytes)
	return kept, true
}

@(private)
kept_bytes_refusal :: proc "contextless" (keeping: ^List_Keeping, size: int) -> List_Keep_Result {
	count := i64(keeping.byte_count + size)
	return {refusal = .Bytes_Full, record = errors.error_make(.Over_Limit, .Bytes, 0, count, KEPT_LIST_BYTE_CAPACITY)}
}

// list_keeping_commit moves the list that list_keep copied into the memory
// of the host: its items, and its bytes, where each text and record of an
// item then points. items holds KEPT_LIST_ITEM_CAPACITY values and bytes
// KEPT_LIST_BYTE_CAPACITY bytes at least. It gives the count of the items.
list_keeping_commit :: proc "contextless" (keeping: ^List_Keeping, items: []Value, bytes: []u8) -> int {
	if len(items) < keeping.item_count || len(bytes) < keeping.byte_count {
		return 0
	}
	destination := bytes[:keeping.byte_count]
	copy(destination, keeping.bytes[:keeping.byte_count])
	base := uintptr(&keeping.bytes[0])
	count := copy(items, keeping.items[:keeping.item_count])
	// Only a Text and a Record of an item point into the bytes.
	for &item in items[:count] {
		if item.kind == .Text && len(item.text) > 0 {
			offset := int(uintptr(raw_data(item.text)) - base)
			item.text = string(destination[offset:][:len(item.text)])
		}
		if item.kind == .Record && len(item.record) > 0 {
			offset := int(uintptr(raw_data(item.record)) - base)
			item.record = destination[offset:][:len(item.record)]
		}
	}
	return count
}

// kept_list_read gives a kept list as a List of the evaluation: its items
// copied after the items of the lists of the evaluation, with each nested
// list moved to its new place. top_count is the count of the items of the
// top list, the first ones. ok false: the items do not fit in the
// evaluation, and record is Over_Limit with the count that the line needs.
kept_list_read :: proc "contextless" (evaluation: ^Evaluation, items: []Value, top_count: u32) -> (value: Value, record: errors.Error_Record, ok: bool) {
	first, added := list_items_add(evaluation, items)
	if !added {
		return {}, errors.error_make(.Over_Limit, .None, 0, i64(evaluation.list_item_count + len(items)), i64(len(evaluation.active_list_items))), false
	}
	for &item in evaluation.active_list_items[first:][:len(items)] {
		if item.kind == .List {
			item.integer += i64(first)
		}
	}
	return {kind = .List, integer = i64(first), detail = top_count}, {}, true
}
