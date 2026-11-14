#+build !freestanding
package disk_program

import "core:testing"
import "modus:contract/start_grant"

@(private = "file")
hash_of :: proc(first: u8) -> (hash: [HASH_SIZE]u8) {
	for &byte, index in hash {
		byte = first + u8(index)
	}
	return
}

@(private = "file")
key_of :: proc(value: u8) -> (key: [KEY_SIZE]u8) {
	for &byte in key {
		byte = value
	}
	return
}

// Two hashes never share a nickname: a row with another hash refuses the
// start, and the empty hash takes the hash of the row.
@(test)
the_nickname_names_one_file :: proc(t: ^testing.T) {
	table: Grant_Table
	first, second := hash_of(1), hash_of(100)
	// No row: the hash asked runs, with no grant; no hash is refused.
	hash, grants, problem := start_file(&table, "visitor", first)
	testing.expect(t, problem == .None && hash == first && grants == {})
	_, _, problem = start_file(&table, "visitor", {})
	testing.expect_value(t, problem, Table_Problem.No_File)
	testing.expect_value(t, table_allow(&table, "visitor", first, .Store), Table_Problem.None)
	hash, grants, problem = start_file(&table, "visitor", {})
	testing.expect(t, problem == .None && hash == first && grants == {.Store})
	hash, grants, problem = start_file(&table, "visitor", second)
	testing.expect(t, problem == .Other_File && hash == first && grants == {})
	// A grant for the nickname with another file is refused too.
	testing.expect_value(t, table_allow(&table, "visitor", second, .Store), Table_Problem.Other_File)
	// One file under a second nickname: a row of its own, with no grant.
	hash, grants, problem = start_file(&table, "copy", first)
	testing.expect(t, problem == .None && hash == first && grants == {})
}

// A move points the nickname to another file, and its grants follow.
@(test)
a_move_keeps_the_grants :: proc(t: ^testing.T) {
	table: Grant_Table
	first, second := hash_of(1), hash_of(100)
	testing.expect_value(t, table_move(&table, "visitor", second), Table_Problem.Absent)
	testing.expect_value(t, table_allow(&table, "visitor", first, .Store), Table_Problem.None)
	testing.expect_value(t, table_move(&table, "visitor", first), Table_Problem.Same_File)
	testing.expect_value(t, table_move(&table, "visitor", {}), Table_Problem.Zero_Hash)
	testing.expect_value(t, table_move(&table, "visitor", second), Table_Problem.None)
	hash, grants, problem := start_file(&table, "visitor", {})
	testing.expect(t, problem == .None && hash == second && grants == {.Store})
	_, _, problem = start_file(&table, "visitor", first)
	testing.expect_value(t, problem, Table_Problem.Other_File)
	// A disallow keeps the row: the nickname still names its file.
	testing.expect_value(t, table_disallow(&table, "visitor", .Store), Table_Problem.None)
	testing.expect_value(t, table_disallow(&table, "visitor", .Store), Table_Problem.Not_Held)
	hash, grants, problem = start_file(&table, "visitor", {})
	testing.expect(t, problem == .None && hash == second && grants == {})
	testing.expect_value(t, table_disallow(&table, "nobody", .Store), Table_Problem.Absent)
}

// The table has 16 rows; a 17th nickname is refused, and an existing one
// still takes a grant.
@(test)
a_full_table :: proc(t: ^testing.T) {
	table: Grant_Table
	names := [ROW_CAPACITY + 1]string{"a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "b0", "b1", "b2", "b3", "b4", "b5", "b6"}
	for name, index in names[:ROW_CAPACITY] {
		testing.expect_value(t, table_allow(&table, name, hash_of(u8(index + 1)), .Store), Table_Problem.None)
	}
	testing.expect_value(t, table_allow(&table, names[ROW_CAPACITY], hash_of(200), .Store), Table_Problem.Full)
	testing.expect_value(t, table_allow(&table, "a3", hash_of(4), .Store), Table_Problem.None)
	testing.expect_value(t, table.count, ROW_CAPACITY)
}

// A nickname with a store has letters, digits, '-' and '_' only: a '.' could
// name the store of another program or of another principal.
@(test)
nicknames_that_a_grant_refuses :: proc(t: ^testing.T) {
	cases := [?]struct {
		nickname: string,
		problem:  Name_Problem,
		offset:   int,
	} {
		{"visitor", .None, 0},
		{"my-tool_2", .None, 0},
		{"notes.principal.1", .Bad_Byte, 5},
		{"console.history", .Bad_Byte, 7},
		{"a b", .Bad_Byte, 1},
		{"", .Empty, 0},
		{"programs", .Store_Name, 0},
		{"twenty_four_bytes_long__", .Too_Long, 0},
	}
	for item in cases {
		problem, offset := nickname_grant_problem(item.nickname)
		testing.expectf(t, problem == item.problem && offset == item.offset, "the nickname %q: %v at %d, expected %v at %d", item.nickname, problem, offset, item.problem, item.offset)
	}
	buffer: [32]u8
	testing.expect_value(t, store_program_name(&buffer, "visitor"), "disk-visitor")
	testing.expect_value(t, store_program_name(&buffer, "twenty_three_bytes_long"), "disk-twenty_three_bytes_long")
}

// Only the store is given by a command; the ring of the root service, the
// machine, a device and the principal are never given.
@(test)
the_grants_that_no_command_gives :: proc(t: ^testing.T) {
	given, answer := grant_by_command(.Store)
	testing.expect(t, answer == .Given && given == .Store)
	for grant in ([]start_grant.Grant{.Root_Ring, .Connect, .Principals, .Debugger, .Inspect, .Stop, .Schedule, .Events, .Data_Disk, .Scratch_Disk, .Network_Device, .Acts_For_Principal, .System_Part}) {
		_, answer = grant_by_command(grant)
		testing.expectf(t, answer == .Never, "the grant %v: %v, expected Never", grant, answer)
	}
	_, answer = grant_by_command(.Network)
	testing.expect_value(t, answer, Command_Answer.Not_Built)
}

// A table goes through its persisted form and comes back; a row that does
// not persist is not written.
@(test)
a_table_through_its_persisted_form :: proc(t: ^testing.T) {
	table: Grant_Table
	key := key_of(7)
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	testing.expect_value(t, table_allow(&table, "scratch", hash_of(50), .Store), Table_Problem.None)
	testing.expect_value(t, table_allow(&table, "kept", hash_of(90), .Store), Table_Problem.None)
	scratch := table_find(&table, "scratch")
	scratch.persistence = .Forget
	bytes: [TABLE_SIZE]u8
	table_encode(&table, &key, &bytes)
	read, problem := table_decode(bytes[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.None)
	testing.expect_value(t, read.count, 2)
	testing.expect(t, table_find(&read, "scratch") == nil)
	row := table_find(&read, "visitor")
	testing.expect(t, row != nil && row.hash == hash_of(1) && row.grants == {.Store} && row.persistence == .Global)
	testing.expect(t, table_find(&read, "kept") != nil)
	// The global setting to forget keeps the exceptions that persist only.
	table.forget_by_default = true
	kept := table_find(&table, "kept")
	kept.persistence = .Persist
	table_encode(&table, &key, &bytes)
	read, problem = table_decode(bytes[:], &key)
	testing.expect(t, problem == .None && read.count == 1 && read.forget_by_default && table_find(&read, "kept") != nil)
}

// A reader of the disk with no key cannot add a grant: a table with one
// byte changed, a table of another key, and a table that the key signed
// with a field out of its rules are each refused.
@(test)
hostile_tables :: proc(t: ^testing.T) {
	table: Grant_Table
	key := key_of(7)
	other_key := key_of(8)
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	good: [TABLE_SIZE]u8
	table_encode(&table, &key, &good)
	// Each byte, changed by one bit, is refused by the tag.
	for index in 0 ..< TABLE_SIZE {
		changed := good
		changed[index] ~= 1
		_, refusal := table_decode(changed[:], &key)
		testing.expectf(t, refusal == .Not_Authentic, "the byte %d changed: %v", index, refusal)
	}
	_, problem := table_decode(good[:], &other_key)
	testing.expect_value(t, problem, Table_File_Problem.Not_Authentic)
	_, problem = table_decode(good[:TABLE_SIZE - 1], &key)
	testing.expect_value(t, problem, Table_File_Problem.Wrong_Size)
	// Fields that the key signed and that break a rule: the tag is made
	// again after the change, as a holder of the key would make it.
	Change :: struct {
		offset:  int,
		value:   u8,
		problem: Table_File_Problem,
	}
	changes := [?]Change {
		{TABLE_OFFSET_MAGIC, 'X', .Wrong_Magic},
		{TABLE_OFFSET_FORMAT, 2, .Wrong_Format},
		{TABLE_OFFSET_COUNT, ROW_CAPACITY + 1, .Too_Many_Rows},
		{TABLE_OFFSET_SETTING, 2, .Bad_Setting},
		{TABLE_HEADER_SIZE + ROW_OFFSET_LENGTH, NAME_LIMIT + 1, .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_OFFSET_NICKNAME, '.', .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_OFFSET_NICKNAME + 20, 'x', .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_OFFSET_GRANTS, 2, .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_OFFSET_PERSISTENCE, 3, .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_SIZE - 1, 1, .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_SIZE, 1, .Bytes_After_Rows},
	}
	for change in changes {
		changed := good
		changed[change.offset] = change.value
		remade := table_tag(&key, &changed)
		copy(changed[TABLE_OFFSET_TAG:], remade[:])
		_, found := table_decode(changed[:], &key)
		testing.expectf(t, found == change.problem, "the byte %d set to %d: %v, expected %v", change.offset, change.value, found, change.problem)
	}
	// A hash of zero bytes, and two rows with one nickname.
	zero := good
	for &byte in zero[TABLE_HEADER_SIZE + ROW_OFFSET_HASH:][:HASH_SIZE] {
		byte = 0
	}
	tag := table_tag(&key, &zero)
	copy(zero[TABLE_OFFSET_TAG:], tag[:])
	_, problem = table_decode(zero[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.Bad_Row)
	twice := good
	copy(twice[TABLE_HEADER_SIZE + ROW_SIZE:][:ROW_SIZE], good[TABLE_HEADER_SIZE:][:ROW_SIZE])
	twice[TABLE_OFFSET_COUNT] = 2
	tag = table_tag(&key, &twice)
	copy(twice[TABLE_OFFSET_TAG:], tag[:])
	_, problem = table_decode(twice[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.Two_Rows)
}
