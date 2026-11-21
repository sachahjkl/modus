#+build !freestanding
package hash_table

import "core:fmt"
import "core:testing"
import "core:time"

// The measure of a lookup, printed and never asserted: the Swiss table
// against the table that the private glyph cache had before it: places
// that hold the first entry of a chain, a link in each entry of 40 bytes,
// the place from the key times the golden ratio of 64 bits, and twice as
// many places as entries. A lookup gives the number of an entry in both.
// Two forms of keys: the keys of the glyph cache (a glyph index that
// counts up, which the golden ratio spreads with no collision), and random
// keys. Build with -o:speed -define:MEASURE=true for a number that means
// something (docs/SIMD.md, "9. The 16-tag group match").

// An entry of the size and the form of the entry of the glyph cache.
Chained_Entry :: struct {
	key:        u64,
	frame:      u64,
	glyph:      [12]u8,
	neighbours: [2]u16,
	next:       u32, // The next entry of the chain, plus one: 32 bits, to reach 100 000 entries in the same 40 bytes.
	rest:       [4]u8,
}
#assert(size_of(Chained_Entry) == 40)

Chained_Table :: struct($ENTRY_CAPACITY: int, $PLACE_BITS: uint) {
	entries: [ENTRY_CAPACITY]Chained_Entry,
	places:  [1 << PLACE_BITS]u32, // The first entry of each chain, plus one.
	used:    int,
}

chained_place :: #force_inline proc(key: u64, $PLACE_BITS: uint) -> int {
	return int((key * 0x9E37_79B9_7F4A_7C15) >> (64 - PLACE_BITS))
}

chained_insert :: proc(table: ^Chained_Table($E, $B), key: u64) {
	index := table.used
	table.used += 1
	place := &table.places[chained_place(key, B)]
	table.entries[index] = {key = key, next = place^}
	place^ = u32(index + 1)
}

chained_find :: proc(table: ^Chained_Table($E, $B), key: u64) -> int #no_bounds_check {
	next := table.places[chained_place(key, B)]
	for next != 0 {
		entry := &table.entries[next - 1]
		if entry.key == key {
			return int(next - 1)
		}
		next = entry.next
	}
	return -1
}

Key_Form :: enum {
	Glyph, // The keys of the glyph cache: face 1, font 0, a glyph index that counts up, a text size, the position across a pixel.
	Random, // Keys with no structure.
}

// key_of_number gives the key number of a form; a miss key is a key of the
// same form that no insert gave.
key_of_number :: #force_inline proc(form: Key_Form, number: int, miss: bool) -> u64 {
	switch form {
	case .Glyph:
		return 1 | u64(number & 0xFFFF) << 8 | u64(1024 + number >> 16) << 24 | (miss ? 1 : 0) << 40
	case .Random:
		z := u64(number) * 0x9E37_79B9_7F4A_7C15 + (miss ? 0x5555 : 0)
		z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
		z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
		return z ~ (z >> 31)
	}
	return 0
}

// The measures of time of this package run only with -define:MEASURE=true:
// a test that measures time is opt-in, and a normal run prints no time.
MEASURE :: #config(MEASURE, false)

ROUNDS :: 15

measure_size :: proc(t: ^testing.T, form: Key_Form, swiss: ^$S/Hash_Table(u64, $V, $N), chained: ^$C/Chained_Table($E, $B), count: int) {
	// The keys first, so the loops read a key and look it up, the same
	// work for both tables: the order jumps across the table.
	keys := make([]u64, 2 * count, context.temp_allocator)
	for place in 0 ..< count {
		number := (place * 40503) % count
		keys[place] = key_of_number(form, number, false)
		keys[count + place] = key_of_number(form, number, true)
	}
	for number in 0 ..< count {
		insert(swiss, key_of_number(form, number, false), V(number))
		chained_insert(chained, key_of_number(form, number, false))
	}
	lookups := max(count, 100_000)
	names := [2]string{"hit", "miss"}
	for miss in 0 ..< 2 {
		looked_up := keys[miss * count:][:count]
		swiss_least, chained_least := max(i64), max(i64)
		swiss_found, chained_found := 0, 0
		for _ in 0 ..< ROUNDS {
			swiss_found, chained_found = 0, 0
			start := time.tick_now()
			for lookup in 0 ..< lookups {
				if _, found := find(swiss, looked_up[lookup % count]); found {
					swiss_found += 1
				}
			}
			swiss_least = min(swiss_least, time.duration_nanoseconds(time.tick_since(start)))
			start = time.tick_now()
			for lookup in 0 ..< lookups {
				if chained_find(chained, looked_up[lookup % count]) >= 0 {
					chained_found += 1
				}
			}
			chained_least = min(chained_least, time.duration_nanoseconds(time.tick_since(start)))
		}
		wanted := miss == 0 ? lookups : 0
		testing.expectf(t, swiss_found == wanted && chained_found == wanted, "%d entries, %s: the Swiss table found %d, the chained table %d; wanted %d", count, names[miss], swiss_found, chained_found, wanted)
		swiss_nanoseconds := f64(swiss_least) / f64(lookups)
		chained_nanoseconds := f64(chained_least) / f64(lookups)
		fmt.printfln("hash_table: %v keys, %6d entries, %s: Swiss table %.2f ns (%.0f million lookups a second), chained table %.2f ns (%.0f million)", form, count, names[miss], swiss_nanoseconds, 1000 / swiss_nanoseconds, chained_nanoseconds, 1000 / chained_nanoseconds)
	}
}

@(test)
lookup_cost_against_the_chained_table :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	for form in Key_Form {
		{
			swiss := new(Hash_Table(u64, u16, 2), context.temp_allocator)
			chained := new(Chained_Table(16, 5), context.temp_allocator)
			measure_size(t, form, swiss, chained, 16)
		}
		{
			swiss := new(Hash_Table(u64, u16, 128), context.temp_allocator)
			chained := new(Chained_Table(1000, 11), context.temp_allocator)
			measure_size(t, form, swiss, chained, 1000)
		}
		{
			// The size of the private glyph cache: 4096 entries.
			swiss := new(Hash_Table(u64, u16, 512), context.temp_allocator)
			chained := new(Chained_Table(4096, 13), context.temp_allocator)
			measure_size(t, form, swiss, chained, 4096)
		}
		{
			swiss := new(Hash_Table(u64, u32, 8192), context.temp_allocator)
			chained := new(Chained_Table(100_000, 18), context.temp_allocator)
			measure_size(t, form, swiss, chained, 100_000)
		}
	}
}
