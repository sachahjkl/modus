#+build !freestanding
package principal_keys

import "core:testing"
import "modus:contract/isolated"
import format "modus:contract/store"
import "modus:principals"

@(private = "file")
words_of :: proc(first: u64) -> [7]u64 {
	return {first, first + 1, first + 2, first + 3, 1, 0, 0}
}

// take_checked takes a command, and checks that its words are erased,
// whatever the outcome.
@(private = "file")
take_checked :: proc(t: ^testing.T, table: ^Table, command: isolated.Service_Command, values: [7]u64) -> (outcome: Outcome, other_identity: bool) {
	words := values
	outcome, other_identity = take(table, command, &words)
	testing.expect(t, words == {}, "a command of the keys left its words")
	return
}

// The border of the keys of a principal: each command that names no named
// slot, breaks the order or holds zero bytes is refused, and changes no key.
// The accepted order last, then the lock that erases each key.
@(test)
the_keys_of_a_principal_cross_their_border :: proc(t: ^testing.T) {
	table: Table
	outcome, _ := take_checked(t, &table, .Principal_Storage_Key, words_of(100))
	testing.expect_value(t, outcome, Outcome.Refused)
	for slot in ([?]u64{principals.MACHINE, principals.PRINCIPAL_CAPACITY, max(u64)}) {
		values := words_of(7)
		values[4] = slot
		outcome, _ = take_checked(t, &table, .Principal_Identity, values)
		testing.expect_value(t, outcome, Outcome.Refused)
	}
	for place in 5 ..< 7 {
		trailing := words_of(7)
		trailing[place] = 1
		outcome, _ = take_checked(t, &table, .Principal_Identity, trailing)
		testing.expect_value(t, outcome, Outcome.Refused)
	}
	outcome, _ = take_checked(t, &table, .Principal_Identity, {4 = 1})
	testing.expect_value(t, outcome, Outcome.Refused)
	outcome, _ = take_checked(t, &table, .Connect, words_of(7))
	testing.expect_value(t, outcome, Outcome.Refused)
	testing.expect(t, table == Table{}, "a refused command changed the table")

	outcome, _ = take_checked(t, &table, .Principal_Identity, words_of(7))
	testing.expect_value(t, outcome, Outcome.Identity_Taken)
	testing.expect(t, held(&table, 1) == nil, "an identity alone opens a store")
	outcome, _ = take_checked(t, &table, .Principal_Storage_Key, {4 = 1})
	testing.expect_value(t, outcome, Outcome.Refused)
	outcome, _ = take_checked(t, &table, .Principal_Storage_Key, words_of(100))
	testing.expect_value(t, outcome, Outcome.Key_Taken)
	keys := held(&table, 1)
	testing.expect(t, keys != nil && keys.name_key != keys.storage_key)
	testing.expect(t, held(&table, 0) == nil && held(&table, principals.PRINCIPAL_CAPACITY) == nil)

	// A second key while one is held: refused, the first one stays.
	before := table
	outcome, _ = take_checked(t, &table, .Principal_Storage_Key, words_of(200))
	testing.expect_value(t, outcome, Outcome.Refused)
	testing.expect(t, table == before, "a second key replaced the held one")

	other: bool
	outcome, other = take_checked(t, &table, .Principal_Identity, words_of(9))
	testing.expect(t, outcome == .Identity_Taken && other)
	testing.expect(t, held(&table, 1) == nil, "the key of another principal stayed in the slot")
	_, _ = take_checked(t, &table, .Principal_Storage_Key, words_of(100))
	outcome, _ = take_checked(t, &table, .Principal_Locked, {4 = 1})
	testing.expect_value(t, outcome, Outcome.Erased)
	testing.expect(t, table == Table{}, "the lock left a byte of a key")
	// After the lock, a key of the next unlock is taken again.
	_, _ = take_checked(t, &table, .Principal_Identity, words_of(7))
	outcome, _ = take_checked(t, &table, .Principal_Storage_Key, words_of(300))
	testing.expect_value(t, outcome, Outcome.Key_Taken)
}

@(private = "file")
keys_of_slot :: proc(table: ^Table, identifier_first, key_first: u64) -> ^Principal_Storage {
	_, _ = take(table, .Principal_Identity, &[7]u64{identifier_first, identifier_first + 1, identifier_first + 2, identifier_first + 3, 1, 0, 0})
	_, _ = take(table, .Principal_Storage_Key, &[7]u64{key_first, key_first + 1, key_first + 2, key_first + 3, 1, 0, 0})
	return held(table, 1)
}

// The owner fields of a store bind it to its principal and to its cell: the
// keys of another principal, a changed byte of each field, the cell of
// another store of the same principal, and bytes past the name are each
// refused, with zeros in the buffer. The store and its own cell last.
@(test)
a_cell_opens_its_own_store_block_only :: proc(t: ^testing.T) {
	table: Table
	keys := keys_of_slot(&table, 7, 100)
	salt := [format.OWNER_FIELD_SIZE]u8{0 = 1, 31 = 2}
	_, too_long := owner_seal(keys, string(make([]u8, format.OWNER_FIELD_SIZE, context.temp_allocator)), salt)
	testing.expect(t, !too_long, "a name with no zero after it was sealed")
	_, empty := owner_seal(keys, "", salt)
	testing.expect(t, !empty, "an empty name was sealed")
	owner, sealed := owner_seal(keys, "notes", salt)
	testing.expect(t, sealed)
	testing.expect(t, string(owner.name_sealed[:5]) != "notes", "the name is in clear")
	cell, cell_ok := cell_field(keys, "notes")
	testing.expect(t, cell_ok)
	other_owner, _ := owner_seal(keys, "photos", [format.OWNER_FIELD_SIZE]u8{0 = 3})
	other_cell, _ := cell_field(keys, "photos")
	buffer: [format.OWNER_FIELD_SIZE]u8

	// The cell of another store of the same principal on this block, and
	// this cell on the block of the other store.
	_, ok := owner_open(keys, &owner, other_cell, &buffer)
	testing.expect(t, !ok && buffer == {}, "a cell opened the store block of another store")
	_, ok = owner_open(keys, &other_owner, cell, &buffer)
	testing.expect(t, !ok && buffer == {}, "a cell opened the store block of another store")
	// A cell with no mark: a store of principal 0.
	unmarked := cell
	unmarked[0] = 'n'
	_, ok = owner_open(keys, &owner, unmarked, &buffer)
	testing.expect(t, !ok)
	// One flipped bit of each field.
	for field in 0 ..< 4 {
		for at in ([?]int{0, 31}) {
			changed := owner
			bytes: ^[format.OWNER_FIELD_SIZE]u8
			switch field {
			case 0: bytes = &changed.owner
			case 1: bytes = &changed.salt
			case 2: bytes = &changed.key_check
			case 3: bytes = &changed.name_sealed
			}
			bytes[at] ~= 1
			_, ok = owner_open(keys, &changed, cell, &buffer)
			testing.expectf(t, !ok && buffer == {}, "a flipped bit %d of the field %d opened the store", at, field)
		}
	}
	// The keys of another principal in the slot.
	other_table: Table
	other_keys := keys_of_slot(&other_table, 9, 100)
	_, ok = owner_open(other_keys, &owner, cell, &buffer)
	testing.expect(t, !ok && buffer == {}, "another principal opened the store")
	// Another storage key with the same identifier.
	wrong_table: Table
	wrong_keys := keys_of_slot(&wrong_table, 7, 200)
	_, ok = owner_open(wrong_keys, &owner, cell, &buffer)
	testing.expect(t, !ok && buffer == {}, "another key opened the store")

	name, opened := owner_open(keys, &owner, cell, &buffer)
	testing.expect(t, opened)
	testing.expect_value(t, name, "notes")
}
