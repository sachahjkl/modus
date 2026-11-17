package modustool

import "base:runtime"

// The mutators of the engine (src/md/infrastructure/fuzzing.md, "The
// mutators"): each one changes the input of the next execution,
// engine.mutated, in place. They act on bytes, so they serve a raw target
// and the choices of a generated target alike.

Fuzz_Mutation :: enum u8 {
	Flip_Bit, // One bit.
	Byte_Boundary, // One byte to a boundary value.
	Word_Boundary, // A word of 2, 4 or 8 bytes, in one of the two orders, to a boundary value.
	Word_Add, // A small number added to, or taken from, a word.
	Insert_Random, // Bytes from the generator of the engine.
	Erase_Range, // A range of bytes removed.
	Copy_Range, // A range of the input written at another place of it.
	Repeat_Range, // A range of the input inserted again after itself.
	Splice, // A range of another kept input, inserted, or the end of the input replaced by the end of the other.
	Dictionary_Insert, // A word of the dictionary inserted.
	Dictionary_Overwrite, // A word of the dictionary written over bytes.
	Compared_Value, // One value of a traced comparison written where the other one is.
	Record_Field, // One field of a record of a region to a value that its type makes interesting.
	Truncate, // The end of the input cut.
}

// The most leaves of one record that the field mutator considers.
FUZZ_LEAF_CAPACITY :: 256

// fuzz_mutate applies one mutation to engine.mutated. A mutation that
// cannot act on this input (an empty input, no dictionary, no region)
// inserts bytes instead, so each call changes the input.
fuzz_mutate :: proc(engine: ^Fuzz_Engine) {
	random := &engine.random
	mutation := Fuzz_Mutation(fuzz_random_below(random, len(Fuzz_Mutation)))
	done := false
	switch mutation {
	case .Flip_Bit:
		done = fuzz_mutate_flip_bit(engine)
	case .Byte_Boundary:
		done = fuzz_mutate_word_boundary(engine, 1)
	case .Word_Boundary:
		done = fuzz_mutate_word_boundary(engine, 1 << uint(1 + fuzz_random_below(random, 3)))
	case .Word_Add:
		done = fuzz_mutate_word_add(engine)
	case .Insert_Random:
		done = fuzz_mutate_insert_random(engine)
	case .Erase_Range:
		done = fuzz_mutate_erase_range(engine)
	case .Copy_Range:
		done = fuzz_mutate_copy_range(engine)
	case .Repeat_Range:
		done = fuzz_mutate_repeat_range(engine)
	case .Splice:
		done = fuzz_mutate_splice(engine)
	case .Dictionary_Insert:
		done = fuzz_mutate_dictionary(engine, insert = true)
	case .Dictionary_Overwrite:
		done = fuzz_mutate_dictionary(engine, insert = false)
	case .Compared_Value:
		done = fuzz_mutate_compared_value(engine)
	case .Record_Field:
		done = fuzz_mutate_record_field(engine)
	case .Truncate:
		done = fuzz_mutate_truncate(engine)
	}
	if !done {
		fuzz_mutate_insert_random(engine)
	}
	if len(engine.mutated) > engine.target.input_limit {
		resize(&engine.mutated, engine.target.input_limit)
	}
}

fuzz_mutate_flip_bit :: proc(engine: ^Fuzz_Engine) -> bool {
	if len(engine.mutated) == 0 {
		return false
	}
	place := fuzz_random_below(&engine.random, len(engine.mutated))
	engine.mutated[place] ~= 1 << u8(fuzz_random_below(&engine.random, 8))
	return true
}

// fuzz_boundary_value gives a value at an edge of a word of `size` bytes:
// 0, 1, the largest, one less, the largest signed number, the smallest
// signed number, or a power of two and its two neighbours.
fuzz_boundary_value :: proc(random: ^Fuzz_Random, size: int) -> u64 {
	bits := u64(8 * clamp(size, 1, 8))
	largest := bits == 64 ? max(u64) : (u64(1) << bits) - 1
	switch fuzz_random_below(random, 7) {
	case 0:
		return 0
	case 1:
		return 1
	case 2:
		return largest
	case 3:
		return largest - 1
	case 4:
		return largest >> 1
	case 5:
		return (largest >> 1) + 1
	}
	power := u64(1) << u64(fuzz_random_below(random, int(bits)))
	return power + u64(fuzz_random_below(random, 3)) - 1
}

// fuzz_word_write writes the low `size` bytes of a value at a place, in
// little-endian order or in big-endian order. The caller checks the room.
fuzz_word_write :: proc(bytes: []u8, place: int, size: int, value: u64, big_endian: bool) {
	for index in 0 ..< size {
		shift := big_endian ? u64(size - 1 - index) : u64(index)
		bytes[place + index] = u8(value >> (8 * shift))
	}
}

// fuzz_word_read reads a word of `size` bytes at a place.
fuzz_word_read :: proc(bytes: []u8, place: int, size: int, big_endian: bool) -> (value: u64) {
	for index in 0 ..< size {
		shift := big_endian ? u64(size - 1 - index) : u64(index)
		value |= u64(bytes[place + index]) << (8 * shift)
	}
	return value
}

fuzz_mutate_word_boundary :: proc(engine: ^Fuzz_Engine, size: int) -> bool {
	if len(engine.mutated) < size {
		return false
	}
	place := fuzz_random_below(&engine.random, len(engine.mutated) - size + 1)
	value := fuzz_boundary_value(&engine.random, size)
	fuzz_word_write(engine.mutated[:], place, size, value, size > 1 && fuzz_random_one_in(&engine.random, 2))
	return true
}

fuzz_mutate_word_add :: proc(engine: ^Fuzz_Engine) -> bool {
	size := 1 << uint(fuzz_random_below(&engine.random, 4))
	if len(engine.mutated) < size {
		return false
	}
	place := fuzz_random_below(&engine.random, len(engine.mutated) - size + 1)
	big_endian := size > 1 && fuzz_random_one_in(&engine.random, 2)
	value := fuzz_word_read(engine.mutated[:], place, size, big_endian)
	change := u64(1 + fuzz_random_below(&engine.random, 16))
	value = fuzz_random_one_in(&engine.random, 2) ? value + change : value - change
	fuzz_word_write(engine.mutated[:], place, size, value, big_endian)
	return true
}

fuzz_mutate_insert_random :: proc(engine: ^Fuzz_Engine) -> bool {
	room := engine.target.input_limit - len(engine.mutated)
	if room <= 0 {
		return fuzz_mutate_flip_bit(engine)
	}
	count := min(1 + fuzz_random_below(&engine.random, 16), room)
	place := fuzz_random_below(&engine.random, len(engine.mutated) + 1)
	bytes: [16]u8
	for index in 0 ..< count {
		// A zero byte, a byte of a boundary or any byte.
		switch fuzz_random_below(&engine.random, 3) {
		case 0:
			bytes[index] = 0
		case 1:
			bytes[index] = u8(fuzz_boundary_value(&engine.random, 1))
		case:
			bytes[index] = u8(fuzz_random_next(&engine.random))
		}
	}
	inject_at_elems(&engine.mutated, place, ..bytes[:count])
	return true
}

// fuzz_random_range gives a range of an input of `length` bytes, from 1
// byte to half of it, at most `largest`.
fuzz_random_range :: proc(random: ^Fuzz_Random, length: int, largest: int) -> (first, count: int) {
	count = 1 + fuzz_random_below(random, min(max(length / 2, 1), largest))
	count = min(count, length)
	first = fuzz_random_below(random, length - count + 1)
	return first, count
}

fuzz_mutate_erase_range :: proc(engine: ^Fuzz_Engine) -> bool {
	if len(engine.mutated) == 0 {
		return false
	}
	first, count := fuzz_random_range(&engine.random, len(engine.mutated), 256)
	remove_range(&engine.mutated, first, first + count)
	return true
}

fuzz_mutate_copy_range :: proc(engine: ^Fuzz_Engine) -> bool {
	if len(engine.mutated) < 2 {
		return false
	}
	first, count := fuzz_random_range(&engine.random, len(engine.mutated), 256)
	to := fuzz_random_below(&engine.random, len(engine.mutated) - count + 1)
	// The two ranges can overlap: copy moves the bytes as memmove does.
	copy(engine.mutated[to:][:count], engine.mutated[first:][:count])
	return true
}

fuzz_mutate_repeat_range :: proc(engine: ^Fuzz_Engine) -> bool {
	if len(engine.mutated) == 0 {
		return false
	}
	first, count := fuzz_random_range(&engine.random, len(engine.mutated), 256)
	count = min(count, engine.target.input_limit - len(engine.mutated))
	if count <= 0 {
		return false
	}
	repeated := make([]u8, count, context.temp_allocator)
	copy(repeated, engine.mutated[first:][:count])
	inject_at_elems(&engine.mutated, first + count, ..repeated)
	return true
}

fuzz_mutate_splice :: proc(engine: ^Fuzz_Engine) -> bool {
	if len(engine.entries) < 2 {
		return false
	}
	other := engine.entries[fuzz_random_below(&engine.random, len(engine.entries))].input
	if len(other) == 0 {
		return false
	}
	if fuzz_random_one_in(&engine.random, 2) {
		// The end of the input from the other one.
		cut := fuzz_random_below(&engine.random, len(engine.mutated) + 1)
		from := fuzz_random_below(&engine.random, len(other))
		resize(&engine.mutated, cut)
		append(&engine.mutated, ..other[from:])
		return true
	}
	first, count := fuzz_random_range(&engine.random, len(other), 512)
	count = min(count, engine.target.input_limit - len(engine.mutated))
	if count <= 0 {
		return false
	}
	place := fuzz_random_below(&engine.random, len(engine.mutated) + 1)
	inject_at_elems(&engine.mutated, place, ..other[first:][:count])
	return true
}

fuzz_mutate_dictionary :: proc(engine: ^Fuzz_Engine, insert: bool) -> bool {
	if len(engine.dictionary) == 0 {
		return false
	}
	word := engine.dictionary[fuzz_random_below(&engine.random, len(engine.dictionary))]
	if insert {
		if len(engine.mutated) + len(word) > engine.target.input_limit {
			return false
		}
		place := fuzz_random_below(&engine.random, len(engine.mutated) + 1)
		inject_at_elems(&engine.mutated, place, ..word)
		return true
	}
	if len(engine.mutated) < len(word) {
		return false
	}
	place := fuzz_random_below(&engine.random, len(engine.mutated) - len(word) + 1)
	copy(engine.mutated[place:], word)
	return true
}

// fuzz_mutate_compared_value takes one comparison of the last execution:
// where the input holds one of its two values, in one of the two orders of
// bytes, the mutator writes the other one. A magic value, a format number
// or a length that the reader compares with a byte of the input then
// passes in a few executions.
fuzz_mutate_compared_value :: proc(engine: ^Fuzz_Engine) -> bool {
	recorded := min(fuzz_compare_count, FUZZ_COMPARE_CAPACITY)
	if recorded == 0 || len(engine.mutated) == 0 {
		return false
	}
	traced := fuzz_compares[fuzz_random_below(&engine.random, recorded)]
	size := int(traced.size)
	if size == 0 || size > len(engine.mutated) {
		return false
	}
	from, to := traced.first, traced.second
	if fuzz_random_one_in(&engine.random, 2) {
		from, to = to, from
	}
	big_endian := size > 1 && fuzz_random_one_in(&engine.random, 2)
	positions := len(engine.mutated) - size + 1
	start := fuzz_random_below(&engine.random, positions)
	for distance in 0 ..< positions {
		place := (start + distance) % positions
		if fuzz_word_read(engine.mutated[:], place, size, big_endian) == from {
			fuzz_word_write(engine.mutated[:], place, size, to, big_endian)
			return true
		}
	}
	// The value is nowhere in the input: the reader transformed it. Write
	// the other value at any place, one time in four.
	if fuzz_random_one_in(&engine.random, 4) {
		fuzz_word_write(engine.mutated[:], start, size, to, big_endian)
		return true
	}
	return false
}

fuzz_mutate_truncate :: proc(engine: ^Fuzz_Engine) -> bool {
	if len(engine.mutated) == 0 {
		return false
	}
	resize(&engine.mutated, fuzz_random_below(&engine.random, len(engine.mutated)))
	return true
}

// One field of a record that the field mutator can write: an integer, an
// enumerated value, a bit set or a boolean, at its offset in the record.
Fuzz_Leaf :: struct {
	offset: int,
	size:   int,
	info:   ^runtime.Type_Info, // The type of the field, with its names removed.
}

// fuzz_record_leaves lists the leaves of a type, from the type information
// of the compiler: the offsets and the sizes are the compiler's, not a
// second description of the record.
fuzz_record_leaves :: proc(info: ^runtime.Type_Info, offset: int, leaves: ^[dynamic]Fuzz_Leaf) {
	if info == nil || len(leaves^) >= FUZZ_LEAF_CAPACITY {
		return
	}
	base := runtime.type_info_base(info)
	#partial switch variant in base.variant {
	case runtime.Type_Info_Struct:
		for index in 0 ..< int(variant.field_count) {
			fuzz_record_leaves(variant.types[index], offset + int(variant.offsets[index]), leaves)
		}
	case runtime.Type_Info_Array:
		// A long array (a name, a hash) is bytes: its first elements are
		// enough for the mutator, the byte mutators reach the others.
		for index in 0 ..< min(variant.count, 16) {
			fuzz_record_leaves(variant.elem, offset + index * variant.elem_size, leaves)
		}
	case runtime.Type_Info_Enumerated_Array:
		for index in 0 ..< min(variant.count, 16) {
			fuzz_record_leaves(variant.elem, offset + index * variant.elem_size, leaves)
		}
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum, runtime.Type_Info_Bit_Set, runtime.Type_Info_Boolean:
		if base.size >= 1 && base.size <= 8 {
			append(leaves, Fuzz_Leaf{offset = offset, size = base.size, info = base})
		}
	}
}

// fuzz_leaf_value gives a value for a leaf that its type makes
// interesting.
fuzz_leaf_value :: proc(engine: ^Fuzz_Engine, leaf: Fuzz_Leaf, current: u64) -> u64 {
	random := &engine.random
	#partial switch variant in leaf.info.variant {
	case runtime.Type_Info_Enum:
		// Each named value, or one past the largest.
		if len(variant.values) > 0 && !fuzz_random_one_in(random, 4) {
			return u64(variant.values[fuzz_random_below(random, len(variant.values))])
		}
		largest: i64
		for value in variant.values {
			largest = max(largest, i64(value))
		}
		return u64(largest + 1)
	case runtime.Type_Info_Bit_Set:
		if fuzz_random_one_in(random, 3) {
			// One bit past the members of the set, when the set has room.
			bit := u64(variant.upper - variant.lower + 1)
			if bit < u64(8 * leaf.size) {
				return current | (u64(1) << bit)
			}
		}
		return fuzz_random_next(random)
	case runtime.Type_Info_Boolean:
		return u64(fuzz_random_below(random, 3))
	}
	// An integer: a boundary value, the size of the input, an offset or a
	// count of another region, or a small change.
	switch fuzz_random_below(random, 5) {
	case 0, 1:
		return fuzz_boundary_value(random, leaf.size)
	case 2:
		return u64(len(engine.mutated) + fuzz_random_below(random, 3) - 1)
	case 3:
		if len(engine.regions) > 0 {
			other := engine.regions[fuzz_random_below(random, len(engine.regions))]
			switch fuzz_random_below(random, 3) {
			case 0:
				return u64(other.offset)
			case 1:
				return u64(other.count)
			}
			return u64(other.count + 1)
		}
	}
	return current + u64(fuzz_random_below(random, 33)) - 16
}

fuzz_mutate_record_field :: proc(engine: ^Fuzz_Engine) -> bool {
	if engine.target.regions == nil {
		return false
	}
	clear(&engine.regions)
	engine.target.regions(engine.mutated[:], &engine.regions)
	if len(engine.regions) == 0 {
		return false
	}
	region := engine.regions[fuzz_random_below(&engine.random, len(engine.regions))]
	info := type_info_of(region.type)
	if info == nil || info.size <= 0 || region.count <= 0 {
		return false
	}
	leaves := make([dynamic]Fuzz_Leaf, context.temp_allocator)
	fuzz_record_leaves(info, 0, &leaves)
	if len(leaves) == 0 {
		return false
	}
	element := fuzz_random_below(&engine.random, region.count)
	leaf := leaves[fuzz_random_below(&engine.random, len(leaves))]
	place := region.offset + element * info.size + leaf.offset
	if place < 0 || place > len(engine.mutated) - leaf.size {
		return false
	}
	current := fuzz_word_read(engine.mutated[:], place, leaf.size, false)
	fuzz_word_write(engine.mutated[:], place, leaf.size, fuzz_leaf_value(engine, leaf, current), false)
	return true
}
