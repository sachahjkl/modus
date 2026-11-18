#+build !freestanding
package disk_process

import "core:testing"
import "modus:contract/root_ring"
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
// name the store of another module or of another principal.
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
		{"module_files", .Store_Name, 0},
		{"grant_table", .Table_Name, 0},
		{"twenty_four_bytes_long__", .Too_Long, 0},
	}
	for item in cases {
		problem, offset := nickname_grant_problem(item.nickname)
		testing.expectf(t, problem == item.problem && offset == item.offset, "the nickname %q: %v at %d, expected %v at %d", item.nickname, problem, offset, item.problem, item.offset)
	}
	buffer: [32]u8
	testing.expect_value(t, store_process_name(&buffer, "visitor"), "disk-visitor")
	testing.expect_value(t, store_process_name(&buffer, "twenty_three_bytes_long"), "disk-twenty_three_bytes_long")
}

// Only the store is given by a command; the ring of the root service, the
// machine, a device and the principal are never given.
@(test)
the_grants_that_no_command_gives :: proc(t: ^testing.T) {
	given, answer := grant_by_command(.Store)
	testing.expect(t, answer == .Given && given == .Store)
	for grant in ([]start_grant.Grant{.Root_Ring, .Connect, .Principals, .Tpm, .Debugger, .Inspect, .Stop, .Schedule, .Events, .Counters, .Data_Disk, .Scratch_Disk, .Network_Device, .Sound_Device, .Acts_For_Principal, .System_Part, .Versions_Erase, .Remote_Clients, .Start_Policy}) {
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
	testing.expect_value(t, table_persisted_rows(&table), 1)
}

// The setting of persistence: a row takes each value, the global setting
// takes Persist or Forget, and a nickname with no row is refused. The
// count of the rows written follows.
@(test)
the_setting_of_persistence :: proc(t: ^testing.T) {
	table: Grant_Table
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	testing.expect_value(t, table_allow(&table, "other", hash_of(9), .Store), Table_Problem.None)
	testing.expect_value(t, table_persisted_rows(&table), 2)
	testing.expect_value(t, table_persistence_set(&table, "visitor", .Forget), Table_Problem.None)
	testing.expect_value(t, table_persisted_rows(&table), 1)
	testing.expect_value(t, table_persistence_set(&table, "", .Forget), Table_Problem.None)
	testing.expect_value(t, table_persisted_rows(&table), 0)
	testing.expect_value(t, table_persistence_set(&table, "other", .Persist), Table_Problem.None)
	testing.expect_value(t, table_persisted_rows(&table), 1)
	testing.expect_value(t, table_persistence_set(&table, "", .Global), Table_Problem.Not_Held)
	testing.expect_value(t, table_persistence_set(&table, "nobody", .Persist), Table_Problem.Absent)
	testing.expect_value(t, table_persistence_set(&table, "visitor", .Global), Table_Problem.None)
	testing.expect_value(t, table_persistence_set(&table, "", .Persist), Table_Problem.None)
	testing.expect_value(t, table_persisted_rows(&table), 2)
	// The row stays with its grants: the setting changes how long it lasts.
	_, grants, problem := start_file(&table, "visitor", {})
	testing.expect(t, problem == .None && grants == {.Store})
}

// A table that does not verify is written over only under the key of a new
// passphrase; under the key of a record it is kept. A table that verifies is
// taken, and no table is written.
@(test)
the_decision_of_a_read :: proc(t: ^testing.T) {
	testing.expect_value(t, table_read_decision(true, .None, false), Read_Decision.Write_Over)
	testing.expect_value(t, table_read_decision(true, .None, true), Read_Decision.Write_Over)
	testing.expect_value(t, table_read_decision(false, .None, false), Read_Decision.Take)
	testing.expect_value(t, table_read_decision(false, .None, true), Read_Decision.Take)
	for problem in Table_File_Problem {
		if problem == .None {
			continue
		}
		testing.expectf(t, table_read_decision(false, problem, false) == .Keep, "%v under the key of a record", problem)
		testing.expectf(t, table_read_decision(false, problem, true) == .Write_Over, "%v under the key of a new passphrase", problem)
	}
	// A forged table on the disk: refused, and kept under the key of a
	// record.
	table: Grant_Table
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	forged_key, machine_key := key_of(0), key_of(5)
	key := table_key_of_machine_key(&machine_key)
	bytes: [TABLE_SIZE]u8
	table_encode(&table, &forged_key, &bytes)
	_, problem := table_decode(bytes[:], &key)
	testing.expect_value(t, table_read_decision(false, problem, false), Read_Decision.Keep)
}

// The key of the tag comes from the machine key, and from nothing else: two
// machine keys give two keys, one machine key gives one key, and the key of
// the tag is not the machine key. A table that one machine signed does not
// verify under the key of another machine.
@(test)
the_key_of_the_tag_of_the_machine :: proc(t: ^testing.T) {
	first_machine, second_machine := key_of(3), key_of(4)
	first := table_key_of_machine_key(&first_machine)
	testing.expect(t, first == table_key_of_machine_key(&first_machine))
	testing.expect(t, first != table_key_of_machine_key(&second_machine))
	testing.expect(t, first != first_machine)
	testing.expect(t, first != {})
	second := table_key_of_machine_key(&second_machine)
	table: Grant_Table
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	bytes: [TABLE_SIZE]u8
	table_encode(&table, &first, &bytes)
	_, problem := table_decode(bytes[:], &second)
	testing.expect_value(t, problem, Table_File_Problem.Not_Authentic)
	read: Grant_Table
	read, problem = table_decode(bytes[:], &first)
	testing.expect(t, problem == .None && read.count == 1)
}

// The key of the tag of a named principal comes from its unlock key, over
// another text than the key of the machine: one secret gives two other keys
// for the two uses, two principals give two keys, and a table of one
// principal, or of the machine, does not verify under the key of another.
@(test)
the_key_of_the_tag_of_a_named_principal :: proc(t: ^testing.T) {
	first_unlock_key, second_unlock_key := key_of(6), key_of(7)
	first := table_key_of_principal_key(&first_unlock_key)
	second := table_key_of_principal_key(&second_unlock_key)
	testing.expect(t, first == table_key_of_principal_key(&first_unlock_key))
	testing.expect(t, first != second)
	testing.expect(t, first != first_unlock_key)
	testing.expect(t, first != {})
	testing.expect(t, first != table_key_of_machine_key(&first_unlock_key))
	table: Grant_Table
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	bytes: [TABLE_SIZE]u8
	table_encode(&table, &first, &bytes)
	_, problem := table_decode(bytes[:], &second)
	testing.expect_value(t, problem, Table_File_Problem.Not_Authentic)
	machine := table_key_of_machine_key(&first_unlock_key)
	_, problem = table_decode(bytes[:], &machine)
	testing.expect_value(t, problem, Table_File_Problem.Not_Authentic)
	read: Grant_Table
	read, problem = table_decode(bytes[:], &first)
	testing.expect(t, problem == .None && read.count == 1)
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
	// A table of the format 1 is named so, and a restore cannot help it.
	_, problem = table_decode(good[:OLDER_FORMAT_TABLE_SIZE], &key)
	testing.expect_value(t, problem, Table_File_Problem.Older_Format)
	testing.expect(t, table_problem_is_format(.Older_Format) && table_problem_is_format(.Wrong_Format))
	testing.expect(t, !table_problem_is_format(.Not_Authentic) && !table_problem_is_format(.Wrong_Size))
	// Fields that the key signed and that break a rule: the tag is made
	// again after the change, as a holder of the key would make it.
	Change :: struct {
		offset:  int,
		value:   u8,
		problem: Table_File_Problem,
	}
	changes := [?]Change {
		{TABLE_OFFSET_MAGIC, 'X', .Wrong_Magic},
		{TABLE_OFFSET_FORMAT, u8(TABLE_FORMAT + 1), .Wrong_Format},
		{TABLE_OFFSET_COUNT, ROW_CAPACITY + 1, .Too_Many_Rows},
		{TABLE_OFFSET_SETTING, 2, .Bad_Setting},
		{TABLE_OFFSET_CLIENT_KEY_COUNT + 1, 1, .Bad_Setting},
		{TABLE_OFFSET_CLIENT_KEY_COUNT, CLIENT_KEY_CAPACITY + 1, .Bad_Client_Keys},
		{TABLE_OFFSET_CLIENT_KEYS, 1, .Bad_Client_Keys},
		{TABLE_OFFSET_TAG - 1, 1, .Bad_Client_Keys},
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

// The client keys of remote: a key of zero bytes is refused, a key that
// the table holds is no change, the table holds CLIENT_KEY_CAPACITY keys,
// and a removal keeps the order of the others.
@(test)
the_client_keys_of_a_table :: proc(t: ^testing.T) {
	table: Grant_Table
	testing.expect_value(t, table_client_key_add(&table, {}), Table_Problem.Zero_Key)
	for index in 0 ..< CLIENT_KEY_CAPACITY {
		testing.expect_value(t, table_client_key_add(&table, hash_of(u8(10 * index + 1))), Table_Problem.None)
	}
	testing.expect_value(t, table_client_key_add(&table, hash_of(1)), Table_Problem.None)
	testing.expect_value(t, table.client_key_count, CLIENT_KEY_CAPACITY)
	testing.expect_value(t, table_client_key_add(&table, hash_of(200)), Table_Problem.Full)
	testing.expect_value(t, table_client_key_remove(&table, hash_of(200)), Table_Problem.Absent)
	testing.expect_value(t, table_client_key_remove(&table, hash_of(11)), Table_Problem.None)
	testing.expect_value(t, table.client_key_count, CLIENT_KEY_CAPACITY - 1)
	testing.expect_value(t, table_client_key_find(&table, hash_of(11)), -1)
	testing.expect_value(t, table_client_key_find(&table, hash_of(1)), 0)
	testing.expect_value(t, table_client_key_find(&table, hash_of(21)), 1)
	testing.expect(t, table.client_keys[CLIENT_KEY_CAPACITY - 1] == ([CLIENT_KEY_SIZE]u8{}))
	// The place that the removal freed takes a key again.
	testing.expect_value(t, table_client_key_add(&table, hash_of(200)), Table_Problem.None)
	testing.expect_value(t, table_client_key_find(&table, hash_of(200)), CLIENT_KEY_CAPACITY - 1)
}

// The client keys go through the persisted form with the rows, under the
// same tag, and come back in their order. The global setting to forget
// writes none, as it writes no row that has no exception.
@(test)
client_keys_through_the_persisted_form :: proc(t: ^testing.T) {
	table: Grant_Table
	key := key_of(7)
	testing.expect_value(t, table_allow(&table, "visitor", hash_of(1), .Store), Table_Problem.None)
	testing.expect_value(t, table_client_key_add(&table, hash_of(40)), Table_Problem.None)
	testing.expect_value(t, table_client_key_add(&table, hash_of(80)), Table_Problem.None)
	bytes: [TABLE_SIZE]u8
	table_encode(&table, &key, &bytes)
	testing.expect_value(t, int(bytes[TABLE_OFFSET_CLIENT_KEY_COUNT]), 2)
	read, problem := table_decode(bytes[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.None)
	testing.expect_value(t, read.count, 1)
	testing.expect_value(t, read.client_key_count, 2)
	testing.expect(t, read.client_keys[0] == hash_of(40) && read.client_keys[1] == hash_of(80))
	// A key of the table is under the tag: one bit of it changed is
	// refused.
	changed := bytes
	changed[TABLE_OFFSET_CLIENT_KEYS + CLIENT_KEY_SIZE] ~= 1
	_, problem = table_decode(changed[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.Not_Authentic)
	// A key of zero bytes, and one key two times, that the key of the tag
	// signed: refused.
	zero := bytes
	for &byte in zero[TABLE_OFFSET_CLIENT_KEYS:][:CLIENT_KEY_SIZE] {
		byte = 0
	}
	tag := table_tag(&key, &zero)
	copy(zero[TABLE_OFFSET_TAG:], tag[:])
	_, problem = table_decode(zero[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.Bad_Client_Keys)
	twice := bytes
	copy(twice[TABLE_OFFSET_CLIENT_KEYS + CLIENT_KEY_SIZE:][:CLIENT_KEY_SIZE], bytes[TABLE_OFFSET_CLIENT_KEYS:][:CLIENT_KEY_SIZE])
	tag = table_tag(&key, &twice)
	copy(twice[TABLE_OFFSET_TAG:], tag[:])
	_, problem = table_decode(twice[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.Bad_Client_Keys)
	// The global setting to forget: no key on the disk, and the table in
	// memory keeps its keys.
	table.forget_by_default = true
	testing.expect_value(t, table_persisted_client_keys(&table), 0)
	table_encode(&table, &key, &bytes)
	read, problem = table_decode(bytes[:], &key)
	testing.expect(t, problem == .None && read.client_key_count == 0)
	testing.expect_value(t, table.client_key_count, 2)
}

// No command gives a disk process a start grant of a root ring: each grant
// of ROOT_RING_GRANTS is Never, and each grant that a command gives now or
// could give later is outside them. A disk process then has no root ring,
// whatever its nickname, and sends no command of the root ring.
@(test)
no_command_gives_a_disk_process_a_root_ring :: proc(t: ^testing.T) {
	for grant in root_ring.ROOT_RING_GRANTS {
		_, answer := grant_by_command(grant)
		testing.expectf(t, answer == .Never, "a command can give a disk process the grant %v of a root ring: %v", grant, answer)
	}
	given_by_a_command: bit_set[start_grant.Grant]
	for grant in start_grant.Grant {
		if _, answer := grant_by_command(grant); answer != .Never {
			testing.expectf(t, grant not_in root_ring.ROOT_RING_GRANTS, "a command can give a disk process the grant %v of a root ring", grant)
			given_by_a_command += {grant}
		}
	}
	testing.expect(t, !root_ring.root_ring_given(given_by_a_command))
	testing.expect(t, .Store in given_by_a_command)
}
