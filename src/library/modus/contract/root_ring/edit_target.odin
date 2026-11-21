package root_ring

import "modus:contract/store"
import "modus:contract/text_encoding"

// The target of an editor started with edit(store, name)
// (src/md/features/editor.md). The root service writes one Edit_Target
// into a read-only page mapped at fixed_addresses.EDIT_TARGET_PAGE_ADDRESS
// before `edit` starts.

EDIT_TARGET_STORE_CAPACITY :: store.NAME_CAPACITY // 32 bytes: 1..31 bytes + NUL.
EDIT_TARGET_STORE_LIMIT :: EDIT_TARGET_STORE_CAPACITY - 1
EDIT_TARGET_PATH_LIMIT :: 256 // Most bytes of an object path (e.g. "src/modulus/enter.odin").

Edit_Target :: struct {
	store_length: u32, // 1..EDIT_TARGET_STORE_LIMIT.
	path_length:  u32, // 1..EDIT_TARGET_PATH_LIMIT.
	store:        [EDIT_TARGET_STORE_CAPACITY]u8,
	path:         [EDIT_TARGET_PATH_LIMIT]u8,
}
#assert(size_of(Edit_Target) <= 4096)

// Why a store name of edit(store, name) is refused.
Edit_Store_Refusal :: enum u8 {
	None     = 0,
	Empty    = 1,
	Too_Long = 2, // Past EDIT_TARGET_STORE_LIMIT bytes.
	Bad_Byte = 3, // NUL, '/', or invalid UTF-8 / control character.
}

// Why an object path of edit(store, name) is refused.
Edit_Path_Refusal :: enum u8 {
	None        = 0,
	Empty       = 1,
	Too_Long    = 2, // Past EDIT_TARGET_PATH_LIMIT bytes.
	Too_Deep    = 3, // More than store.NESTING_LIMIT + 1 components.
	Bad_Segment = 4, // An empty component (leading/trailing/'//'), ".", "..", > 64 bytes, control or invalid UTF-8.
}

// edit_store_validate checks the store name of edit(store, name).
edit_store_validate :: proc "contextless" (name: string) -> (refusal: Edit_Store_Refusal, offset: int) {
	if len(name) == 0 {
		return .Empty, 0
	}
	if len(name) > EDIT_TARGET_STORE_LIMIT {
		return .Too_Long, 0
	}
	for index in 0 ..< len(name) {
		if name[index] == 0 || name[index] == '/' {
			return .Bad_Byte, index
		}
	}
	if place, found := text_encoding.invalid_sequence_find(transmute([]u8)name); found {
		return .Bad_Byte, place
	}
	return .None, 0
}

// edit_path_validate checks the object path of edit(store, name): one or
// more valid store entry names separated by '/', at most
// store.NESTING_LIMIT + 1 segments and EDIT_TARGET_PATH_LIMIT bytes.
edit_path_validate :: proc "contextless" (path: string) -> (refusal: Edit_Path_Refusal, offset: int) {
	if len(path) == 0 {
		return .Empty, 0
	}
	if len(path) > EDIT_TARGET_PATH_LIMIT {
		return .Too_Long, 0
	}
	segments := 0
	start := 0
	for {
		end := start
		for end < len(path) && path[end] != '/' {
			end += 1
		}
		segments += 1
		if segments > store.NESTING_LIMIT + 1 {
			return .Too_Deep, start
		}
		segment := path[start:end]
		seg_refusal, seg_offset, _ := store.name_refusal(segment)
		if seg_refusal != .None {
			return .Bad_Segment, start + seg_offset
		}
		if end == len(path) {
			break
		}
		start = end + 1
	}
	return .None, 0
}

// edit_target_read reads and validates an Edit_Target page at the border
// of `edit`. Copies lengths once before validation.
edit_target_read :: proc "contextless" (page: ^Edit_Target) -> (store_name: string, path: string, ok: bool) {
	if page == nil {
		return "", "", false
	}
	store_length := page.store_length
	path_length := page.path_length
	if store_length == 0 || store_length > EDIT_TARGET_STORE_LIMIT || path_length == 0 || path_length > EDIT_TARGET_PATH_LIMIT {
		return "", "", false
	}
	store_name = string(page.store[:store_length])
	path = string(page.path[:path_length])
	if store_refusal, _ := edit_store_validate(store_name); store_refusal != .None {
		return "", "", false
	}
	if path_refusal, _ := edit_path_validate(path); path_refusal != .None {
		return "", "", false
	}
	return store_name, path, true
}

// edit_path_next_segment yields the next '/'-separated component of a
// validated path starting at byte index `start`.
edit_path_next_segment :: proc "contextless" (path: string, start: int) -> (segment: string, next_start: int, is_last: bool) {
	end := start
	for end < len(path) && path[end] != '/' {
		end += 1
	}
	if end >= len(path) {
		return path[start:end], len(path), true
	}
	return path[start:end], end + 1, false
}
