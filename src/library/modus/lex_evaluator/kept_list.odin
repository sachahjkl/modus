package lex_evaluator

import "modus:contract/errors"

// A list that a host keeps past the line that made it: a variable of the
// console (src/md/features/declarations.md, "The functions of layer 4 as
// built"). The line forced the list whole, so its items are values: a copy
// keeps them as Host_Values in caller memory and replays them into later lines.

// The items of one kept list, the items of its nested lists included.
KEPT_LIST_ITEM_CAPACITY :: LIST_ITEM_CAPACITY

// The bytes of the texts and the records of the items of one kept list.
KEPT_LIST_BYTE_CAPACITY :: 1024 * 1024

// Staging copy of a list before committing into host variable memory.
List_Keeping :: struct {
	items:      [KEPT_LIST_ITEM_CAPACITY]Host_Value,
	item_count: int,
	bytes:      [KEPT_LIST_BYTE_CAPACITY]u8,
	byte_count: int,
}

// Why a list was not kept.
List_Keep_Refusal :: enum u8 {
	None                = 0,
	Items_Full          = 1,
	Bytes_Full          = 2,
	Function            = 3,
	Table               = 4,
	Hash                = 5,
	Description_Of_Line = 6,
	Kind                = 7,
}

List_Keep_Result :: struct {
	refusal: List_Keep_Refusal,
	kind:    Kind,
	record:  errors.Error_Record,
}

// list_keep copies a List of an evaluation into keeping, emptying keeping first.
list_keep :: proc "contextless" (keeping: ^List_Keeping, evaluation: ^Evaluation, value: Host_Value, description_of_line: proc "contextless" (file: []u8) -> bool = nil) -> List_Keep_Result {
	keeping.item_count, keeping.byte_count = 0, 0
	vm_val := value.vm_value.kind == .List ? value.vm_value : Value{kind = .List, data = u64(value.integer), meta = value.detail}
	_, result := list_keep_items(keeping, evaluation, vm_val, description_of_line)
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
		hv := value_to_host(evaluation, item)
		hv.vm_value = {}
		switch hv.kind {
		case .Integer, .Boolean, .Handle, .Enum:
		case .Text:
			bytes, kept := kept_bytes_add(keeping, transmute([]u8)hv.text, 1)
			if !kept {
				return 0, kept_bytes_refusal(keeping, len(hv.text))
			}
			hv.text = string(bytes)
		case .Record:
			if description_of_line != nil && description_of_line(hv.file) {
				return 0, {refusal = .Description_Of_Line, kind = .Record}
			}
			bytes, kept := kept_bytes_add(keeping, hv.record, 8)
			if !kept {
				return 0, kept_bytes_refusal(keeping, len(hv.record))
			}
			hv.record = bytes
		case .List:
			nested, nested_result := list_keep_items(keeping, evaluation, item, description_of_line)
			if nested_result.refusal != .None {
				return 0, nested_result
			}
			hv.integer = i64(nested)
			hv.detail = item.meta
		case .Function:
			return 0, {refusal = .Function, kind = .Function}
		case .Table:
			return 0, {refusal = .Table, kind = .Table}
		case .Hash:
			return 0, {refusal = .Hash, kind = .Hash}
		case .None, .Bytes, .Stream, .Record_Input, .Record_Literal, .Member, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
			return 0, {refusal = .Kind, kind = hv.kind}
		}
		keeping.items[first + index] = hv
	}
	return first, {}
}

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

// list_keeping_commit moves the staged list into host variable memory.
list_keeping_commit :: proc "contextless" (keeping: ^List_Keeping, items: []Host_Value, bytes: []u8) -> int {
	if len(items) < keeping.item_count || len(bytes) < keeping.byte_count {
		return 0
	}
	destination := bytes[:keeping.byte_count]
	copy(destination, keeping.bytes[:keeping.byte_count])
	base := uintptr(&keeping.bytes[0])
	count := copy(items, keeping.items[:keeping.item_count])
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

// kept_list_read restores a kept list into an evaluation's list item pool.
kept_list_read :: proc "contextless" (evaluation: ^Evaluation, items: []Host_Value, top_count: u32) -> (value: Host_Value, record: errors.Error_Record, ok: bool) {
	if len(items) > len(evaluation.list_items) - evaluation.list_item_count {
		return {}, errors.error_make(.Over_Limit, .None, 0, i64(evaluation.list_item_count + len(items)), i64(len(evaluation.list_items))), false
	}
	first := evaluation.list_item_count
	for hv, idx in items {
		if hv.kind == .List {
			evaluation.list_items[first + idx] = {kind = .List, data = u64(first) + u64(hv.integer), meta = hv.detail}
		} else {
			v, v_ok := host_to_value(evaluation, hv)
			if !v_ok {
				return {}, errors.error_make(.Over_Limit, .None, 0, i64(evaluation.list_item_count + len(items)), i64(len(evaluation.list_items))), false
			}
			evaluation.list_items[first + idx] = v
		}
	}
	evaluation.list_item_count += len(items)
	vm_list := Value{kind = .List, data = u64(first), meta = top_count}
	return {kind = .List, integer = i64(first), detail = top_count, vm_value = vm_list}, {}, true
}
