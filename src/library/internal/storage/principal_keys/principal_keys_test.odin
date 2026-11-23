#+build !freestanding
package principal_keys

import "core:testing"
import "modus:principals"

@(private = "file")
words_of :: proc(first: u64) -> [7]u64 {
	return {first, first + 1, first + 2, first + 3, 1, 0, 0}
}

// The border of the keys of a principal: each command that names no named
// slot, breaks the order or holds zero bytes is refused, and changes no key.
// The accepted order last, then the lock that erases each key.
@(test)
the_keys_of_a_principal_cross_their_border :: proc(t: ^testing.T) {
	table: Table
	outcome, _ := take(&table, .Principal_Storage_Key, words_of(100))
	testing.expect_value(t, outcome, Outcome.Refused)
	for slot in ([?]u64{principals.MACHINE, principals.PRINCIPAL_CAPACITY, max(u64)}) {
		values := words_of(7)
		values[4] = slot
		outcome, _ = take(&table, .Principal_Identity, values)
		testing.expect_value(t, outcome, Outcome.Refused)
	}
	for place in 5 ..< 7 {
		trailing := words_of(7)
		trailing[place] = 1
		outcome, _ = take(&table, .Principal_Identity, trailing)
		testing.expect_value(t, outcome, Outcome.Refused)
	}
	outcome, _ = take(&table, .Principal_Identity, {4 = 1})
	testing.expect_value(t, outcome, Outcome.Refused)
	outcome, _ = take(&table, .Connect, words_of(7))
	testing.expect_value(t, outcome, Outcome.Refused)
	testing.expect(t, table == Table{}, "a refused command changed the table")

	outcome, _ = take(&table, .Principal_Identity, words_of(7))
	testing.expect_value(t, outcome, Outcome.Identity_Taken)
	testing.expect(t, held(&table, 1) == nil, "an identity alone opens a store")
	outcome, _ = take(&table, .Principal_Storage_Key, {4 = 1})
	testing.expect_value(t, outcome, Outcome.Refused)
	outcome, _ = take(&table, .Principal_Storage_Key, words_of(100))
	testing.expect_value(t, outcome, Outcome.Key_Taken)
	keys := held(&table, 1)
	testing.expect(t, keys != nil && keys.name_key != keys.storage_key)
	testing.expect(t, held(&table, 0) == nil && held(&table, principals.PRINCIPAL_CAPACITY) == nil)

	other: bool
	outcome, other = take(&table, .Principal_Identity, words_of(9))
	testing.expect(t, outcome == .Identity_Taken && other)
	testing.expect(t, held(&table, 1) == nil, "the key of another principal stayed in the slot")
	_, _ = take(&table, .Principal_Storage_Key, words_of(100))
	outcome, _ = take(&table, .Principal_Locked, {4 = 1})
	testing.expect_value(t, outcome, Outcome.Erased)
	testing.expect(t, table == Table{}, "the lock left a byte of a key")
}
