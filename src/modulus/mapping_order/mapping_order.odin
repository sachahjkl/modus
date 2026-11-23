// The mappings of a process in the order of their addresses
// (src/md/data/table_sizes.md, "The mappings of a process in the order of
// their addresses"). The kernel keeps the mappings in a table of places,
// and beside it the places of the live mappings, sorted by their first
// address. A lookup by an address is a binary search; a search of a free
// range walks the order once from its start; an insert and a remove move
// the places after them by one. The mappings never overlap, so their ends
// are in the same order as their starts.
//
// The procedures take the table of the items: any record with the fields
// `address` (the first byte) and `page_count`.
//
// This package allocates no memory and calls no kernel operation.
package mapping_order

PAGE_SIZE :: 4096

// end_of gives the first byte after an item.
end_of :: #force_inline proc "contextless" (item: $T) -> u64 {
	return item.address + item.page_count * PAGE_SIZE
}

// first_ending_after gives the first position of the order whose item ends
// after address, or len(order).
first_ending_after :: proc "contextless" (order: []u16, items: []$T, address: u64) -> int {
	low, high := 0, len(order)
	for low < high {
		middle := low + (high - low) / 2
		if end_of(items[order[middle]]) > address {
			high = middle
		} else {
			low = middle + 1
		}
	}
	return low
}

// first_starting_after gives the first position of the order whose item
// starts after address, or len(order).
@(private = "file")
first_starting_after :: proc "contextless" (order: []u16, items: []$T, address: u64) -> int {
	low, high := 0, len(order)
	for low < high {
		middle := low + (high - low) / 2
		if items[order[middle]].address > address {
			high = middle
		} else {
			low = middle + 1
		}
	}
	return low
}

// containing gives the place of the item that holds an address.
containing :: proc "contextless" (order: []u16, items: []$T, address: u64) -> (place: u16, found: bool) {
	position := first_ending_after(order, items, address)
	if position < len(order) && items[order[position]].address <= address {
		return order[position], true
	}
	return 0, false
}

// overlaps says if an item meets the range of size bytes from address.
overlaps :: proc "contextless" (order: []u16, items: []$T, address: u64, size: u64) -> bool {
	position := first_ending_after(order, items, address)
	return position < len(order) && items[order[position]].address < address + size
}

// insert puts the place of a new item in the order, at the place of its
// address. order is the whole room; count is the places in use. false: no
// room, and nothing changed.
insert :: proc "contextless" (order: []u16, count: ^int, items: []$T, place: u16) -> bool {
	if count^ >= len(order) {
		return false
	}
	position := first_starting_after(order[:count^], items, items[place].address)
	copy(order[position + 1:count^ + 1], order[position:count^])
	order[position] = place
	count^ += 1
	return true
}

// remove takes the place of an item out of the order, before the item
// changes. false: the place is not in the order, and nothing changed.
remove :: proc "contextless" (order: []u16, count: ^int, items: []$T, place: u16) -> bool {
	position := first_ending_after(order[:count^], items, items[place].address)
	if position >= count^ || order[position] != place {
		return false
	}
	copy(order[position:count^ - 1], order[position + 1:count^])
	count^ -= 1
	return true
}

// align_up gives the first multiple of alignment at value or after it.
align_up :: #force_inline proc "contextless" (value: u64, alignment: u64) -> u64 {
	return (value + alignment - 1) / alignment * alignment
}

// free_range gives the lowest address at from or after it, a multiple of
// alignment, where size bytes fit with guard bytes and no item before and
// after them. It walks the order once from the first item that can meet
// the range: each item that it meets moves the address past it, and it
// never meets that item again.
free_range :: proc "contextless" (order: []u16, items: []$T, from: u64, size: u64, alignment: u64, guard: u64) -> u64 {
	candidate := align_up(from, alignment)
	position := first_ending_after(order, items, candidate - min(candidate, guard))
	for ; position < len(order); position += 1 {
		item := &items[order[position]]
		if item.address >= candidate + size + guard {
			break
		}
		candidate = align_up(end_of(item^) + guard, alignment)
	}
	return candidate
}
