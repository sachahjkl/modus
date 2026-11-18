package disk_process

// The disk grant table of one principal: each row binds a nickname to the
// hash of one module file, and holds the grants of that file
// (docs/MODULE_CONTRACT.md, "The grants of a disk process").
//
// The root service keeps one table for each principal and applies the rules
// of this file; the console checks a nickname and a grant with them before
// it sends a command. The persisted form (`table_encode`, `table_decode`)
// carries a tag of keyed BLAKE2b under a key that only the passphrase of the
// principal gives, so a reader of the disk cannot add a grant.
//
// The table also holds the client keys of `remote` that its principal
// allowed (src/md/features/remote_client_keys.md), so such a grant lasts
// across a restart under the same tag as the grants of the disk processes.
// The client table of the root service is the form of these keys while the
// machine runs.
//
// See [disk grant table](term:disk-grant-table) and [nickname](term:nickname).

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/remote"
import "modus:contract/start_grant"
import blake2 "modus:support/cryptography/_blake2"

// The rows of one table: the disk processes with a grant, of one principal.
ROW_CAPACITY :: 16

// The client keys of `remote` in one table: as many as the client table
// gives one principal, so each key of the table can have its row there.
CLIENT_KEY_CAPACITY :: remote.CLIENT_ROWS_OF_ONE_PRINCIPAL
// The bytes of a client key: an Ed25519 public key.
CLIENT_KEY_SIZE :: 32

// The grants that a command gives to a disk process.
Disk_Grant :: enum u8 {
	Store = 0, // An isolated store of its own, attached to its nickname.
}
Disk_Grants :: bit_set[Disk_Grant;u8]

// The name of each grant, as the console and the log write it.
@(rodata)
disk_grant_names := [Disk_Grant]string {
	.Store = "store",
}

// The prefix of the name of the store of a nickname. The name of a module
// has no byte '-', so no store of a process of the boot image has it.
STORE_PREFIX :: "disk-"

// What a command can do with a start grant (start_grant.Grant), for a disk
// process: the result of `grant_by_command`.
Command_Answer :: enum u8 {
	Given, // A command gives it: `given` is its Disk_Grant.
	Never, // No command ever gives it: it reaches the whole machine, a device, or the principal.
	Not_Built, // A command could give it, and none does yet.
}

// grant_by_command says if a command gives a start grant to a disk process.
// The ring of the root service, a right over the machine or a device, and
// the right to act for the principal are Never: each one is the whole
// machine, or the principal.
grant_by_command :: proc "contextless" (grant: start_grant.Grant) -> (given: Disk_Grant, answer: Command_Answer) {
	switch grant {
	case .Store:
		return .Store, .Given
	case .Root_Ring, .Connect, .Principals, .Tpm, .Debugger, .Inspect, .Stop, .Schedule, .Events, .Counters, .Data_Disk, .Scratch_Disk, .Network_Device, .Sound_Device, .Settings, .Clock, .Replace, .System_Part, .Acts_For_Principal, .Versions_Erase, .Remote_Clients:
		return .Store, .Never
	case .Image, .Log_Records, .Serve, .Terminal, .Replacements, .Network, .History_Store, .Debug_Image, .Palette:
		return .Store, .Not_Built
	}
	return .Store, .Never
}

// nickname_grant_problem checks a nickname that a grant names. It is the
// name of an entry (name_problem), and it has letters, digits, '-' and '_'
// only: a '.' could build the ending ".history" or ".principal.N" of the
// name of another store. offset is the place of the byte of Bad_Byte.
nickname_grant_problem :: proc "contextless" (nickname: string) -> (problem: Name_Problem, offset: int) {
	problem, offset = name_problem(nickname)
	if problem != .None {
		return
	}
	for index in 0 ..< len(nickname) {
		switch nickname[index] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return .Bad_Byte, index
		}
	}
	return .None, 0
}

// store_process_name writes the name that the root service gives the
// storage service for the store of a nickname, before the ending of the
// principal: STORE_PREFIX and the nickname. It fits: 5 + 23 bytes.
store_process_name :: proc "contextless" (out: ^[32]u8, nickname: string) -> string {
	out^ = {}
	count := copy(out^[:], STORE_PREFIX)
	count += copy(out^[count:len(out^) - 1], nickname)
	return string(out^[:count])
}

// How long a row lasts across a restart of the machine.
Persistence :: enum u8 {
	Global  = 0, // The global setting of the table.
	Persist = 1, // An exception: the row persists.
	Forget  = 2, // An exception: the row lasts until the machine stops.
}

// One row: a nickname, the file that it names, and its grants.
Grant_Row :: struct {
	nickname:        [NAME_LIMIT]u8,
	nickname_length: int,
	hash:            [HASH_SIZE]u8, // The BLAKE3 hash of the module file. Never 32 zero bytes.
	grants:          Disk_Grants,
	persistence:     Persistence,
}

// The disk grant table of one principal. The zero table is empty, and its
// global setting is to persist.
Grant_Table :: struct {
	rows:              [ROW_CAPACITY]Grant_Row,
	count:             int,
	forget_by_default: bool, // The global setting: false, each row persists unless its exception says Forget.
	// The client keys of `remote` that the principal allowed, in the order
	// of the allows. Never 32 zero bytes, and never one key two times. They
	// follow the global setting: no key has an exception of its own.
	client_keys:       [CLIENT_KEY_CAPACITY][CLIENT_KEY_SIZE]u8,
	client_key_count:  int,
}

row_nickname :: proc "contextless" (row: ^Grant_Row) -> string {
	return string(row.nickname[:row.nickname_length])
}

// table_find gives the row of a nickname, or nil.
table_find :: proc "contextless" (table: ^Grant_Table, nickname: string) -> ^Grant_Row {
	for &row in table.rows[:table.count] {
		if row_nickname(&row) == nickname {
			return &row
		}
	}
	return nil
}

// Why a start, or a change of a table, is refused.
Table_Problem :: enum u8 {
	None,
	No_File, // The nickname has no row, and the command names no hash.
	Other_File, // The row of the nickname names another file than the command.
	Absent, // The nickname has no row.
	Full, // The table has ROW_CAPACITY rows.
	Not_Held, // The row does not hold the grant.
	Same_File, // The nickname names this file already.
	Zero_Hash, // The hash is 32 zero bytes.
	Zero_Key, // The client key is 32 zero bytes.
}

// start_file decides which file a start of a nickname runs, and with which
// grants. asked is the hash of the command, or 32 zero bytes for the hash of
// the row. Two hashes never share a nickname: a row with another hash
// refuses the start. A nickname with no row runs the hash asked, with no
// grant.
start_file :: proc "contextless" (table: ^Grant_Table, nickname: string, asked: [HASH_SIZE]u8) -> (hash: [HASH_SIZE]u8, grants: Disk_Grants, problem: Table_Problem) {
	row := table_find(table, nickname)
	if row == nil {
		if asked == {} {
			return {}, {}, .No_File
		}
		return asked, {}, .None
	}
	if asked != {} && asked != row.hash {
		return row.hash, {}, .Other_File
	}
	return row.hash, row.grants, .None
}

// table_allow gives a grant to the file that a nickname names: hash is the
// hash of its row, or with no row the hash of the process that runs. A new
// row starts with the global setting.
table_allow :: proc "contextless" (table: ^Grant_Table, nickname: string, hash: [HASH_SIZE]u8, grant: Disk_Grant) -> Table_Problem {
	if hash == {} {
		return .Zero_Hash
	}
	row := table_find(table, nickname)
	if row == nil {
		if table.count == ROW_CAPACITY {
			return .Full
		}
		row = &table.rows[table.count]
		row^ = {hash = hash}
		row.nickname_length = copy(row.nickname[:], nickname)
		table.count += 1
	} else if row.hash != hash {
		return .Other_File
	}
	row.grants += {grant}
	return .None
}

// table_disallow takes a grant from the file of a nickname. The row stays:
// it still binds the nickname to its file.
table_disallow :: proc "contextless" (table: ^Grant_Table, nickname: string, grant: Disk_Grant) -> Table_Problem {
	row := table_find(table, nickname)
	if row == nil {
		return .Absent
	}
	if grant not_in row.grants {
		return .Not_Held
	}
	row.grants -= {grant}
	return .None
}

// table_move points a nickname to another file. Its grants and its
// persistence stay with the nickname, and so does its store, whose name is
// the nickname.
table_move :: proc "contextless" (table: ^Grant_Table, nickname: string, hash: [HASH_SIZE]u8) -> Table_Problem {
	if hash == {} {
		return .Zero_Hash
	}
	row := table_find(table, nickname)
	if row == nil {
		return .Absent
	}
	if row.hash == hash {
		return .Same_File
	}
	row.hash = hash
	return .None
}

// table_persistence_set changes the setting of persistence: of the row of
// a nickname, or with an empty nickname the global setting, which takes
// Persist or Forget only. The row stays: it still binds the nickname to its
// file.
table_persistence_set :: proc "contextless" (table: ^Grant_Table, nickname: string, persistence: Persistence) -> Table_Problem {
	if nickname == "" {
		switch persistence {
		case .Persist:
			table.forget_by_default = false
		case .Forget:
			table.forget_by_default = true
		case .Global:
			return .Not_Held
		}
		return .None
	}
	row := table_find(table, nickname)
	if row == nil {
		return .Absent
	}
	row.persistence = persistence
	return .None
}

// table_client_key_find gives the place of a client key of `remote` in the
// table, or -1.
table_client_key_find :: proc "contextless" (table: ^Grant_Table, key: [CLIENT_KEY_SIZE]u8) -> int {
	for place in 0 ..< clamp(table.client_key_count, 0, CLIENT_KEY_CAPACITY) {
		if table.client_keys[place] == key {
			return place
		}
	}
	return -1
}

// table_client_key_add records a client key of `remote` that the principal
// allowed. A key that the table holds already is no change.
table_client_key_add :: proc "contextless" (table: ^Grant_Table, key: [CLIENT_KEY_SIZE]u8) -> Table_Problem {
	if key == {} {
		return .Zero_Key
	}
	if table_client_key_find(table, key) >= 0 {
		return .None
	}
	if table.client_key_count >= CLIENT_KEY_CAPACITY {
		return .Full
	}
	table.client_keys[table.client_key_count] = key
	table.client_key_count += 1
	return .None
}

// table_client_key_remove takes a client key of `remote` out of the table.
// The keys after it move one place down, so the keys keep the order of the
// allows.
table_client_key_remove :: proc "contextless" (table: ^Grant_Table, key: [CLIENT_KEY_SIZE]u8) -> Table_Problem {
	place := table_client_key_find(table, key)
	if place < 0 {
		return .Absent
	}
	count := clamp(table.client_key_count, 0, CLIENT_KEY_CAPACITY)
	for index in place ..< count - 1 {
		table.client_keys[index] = table.client_keys[index + 1]
	}
	table.client_keys[count - 1] = {}
	table.client_key_count = count - 1
	return .None
}

// table_persisted_client_keys counts the client keys that table_encode
// writes: each one, unless the global setting is to forget.
table_persisted_client_keys :: proc "contextless" (table: ^Grant_Table) -> int {
	if table.forget_by_default {
		return 0
	}
	return clamp(table.client_key_count, 0, CLIENT_KEY_CAPACITY)
}

// table_persisted_rows counts the rows that table_encode writes.
table_persisted_rows :: proc "contextless" (table: ^Grant_Table) -> int {
	count := 0
	for &row in table.rows[:clamp(table.count, 0, ROW_CAPACITY)] {
		if row_persists(table, &row) {
			count += 1
		}
	}
	return count
}

// The text over which the machine key gives the key of the tag of the
// table of principal 0. A key for another use takes another text, so the
// key of the tag reveals nothing of the machine key or of that other key.
TABLE_KEY_TEXT :: "modus disk grant table"

// The text over which the unlock key of a named principal gives the key of
// the tag of its table. It differs from TABLE_KEY_TEXT, so no key of a
// named principal is the key of the table of the machine, even from equal
// secret bytes.
PRINCIPAL_TABLE_KEY_TEXT :: "modus disk grant table of a named principal"

// table_key_derive gives keyed BLAKE2b of a secret key over a text.
@(private)
table_key_derive :: proc "contextless" (secret: ^[KEY_SIZE]u8, text: string) -> (key: [KEY_SIZE]u8) {
	context_of_the_hash: blake2.Blake2b_Context
	configuration := blake2.Blake2_Config {
		size = KEY_SIZE,
		key  = secret^[:],
	}
	blake2.init(&context_of_the_hash, &configuration)
	blake2.update(&context_of_the_hash, transmute([]u8)text)
	blake2.final(&context_of_the_hash, key[:])
	return key
}

// table_key_of_machine_key gives the key of the tag of the disk grant table
// of principal 0: keyed BLAKE2b of the machine key over TABLE_KEY_TEXT. The
// process `unlock` computes it, and gives only this key to the root service
// (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase").
table_key_of_machine_key :: proc "contextless" (machine_key: ^[KEY_SIZE]u8) -> (key: [KEY_SIZE]u8) {
	return table_key_derive(machine_key, TABLE_KEY_TEXT)
}

// table_key_of_principal_key gives the key of the tag of the disk grant
// table of a named principal: keyed BLAKE2b of its secret unlock key
// (X25519) over PRINCIPAL_TABLE_KEY_TEXT. The process `unlock` computes it
// when the passphrase opens the seal, and gives only this key to the root
// service (docs/PRINCIPALS.md, "The disk grant table of a named
// principal"). Each principal has its own unlock key, so a table of one
// principal does not verify in the store of another.
table_key_of_principal_key :: proc "contextless" (unlock_key: ^[KEY_SIZE]u8) -> (key: [KEY_SIZE]u8) {
	return table_key_derive(unlock_key, PRINCIPAL_TABLE_KEY_TEXT)
}

// What the root service does with the answer of the read of a persisted
// table: the result of `table_read_decision`.
Read_Decision :: enum u8 {
	Take, // The table verifies: it becomes the table of the principal.
	Write_Over, // Write the table in memory there: no table, or a table that no key of a record signed.
	Keep, // Refuse the table and keep it: no grant, no write over it, and no change until a table that verifies is there.
}

// table_read_decision decides what a read gives. absent: the store has no
// table. key_new: the key is the key of a passphrase set now, on a machine
// with no record, so no key of a record signed the table on the disk. A
// table that does not verify under a key that opened a record can be a
// good table of another key, or a table that a byte changed: a write over
// it would lose its grants with no sign, so it is kept.
table_read_decision :: proc "contextless" (absent: bool, problem: Table_File_Problem, key_new: bool) -> Read_Decision {
	if absent {
		return .Write_Over
	}
	if problem == .None {
		return .Take
	}
	return key_new ? Read_Decision.Write_Over : Read_Decision.Keep
}

// row_persists says if a row is kept across a restart: its exception, else
// the global setting.
row_persists :: proc "contextless" (table: ^Grant_Table, row: ^Grant_Row) -> bool {
	switch row.persistence {
	case .Persist:
		return true
	case .Forget:
		return false
	case .Global:
	}
	return !table.forget_by_default
}

// The persisted table: the object that the root service keeps in a store
// of the principal. Each number is little-endian.
TABLE_MAGIC :: "DISKGRNT" // The first 8 bytes.
TABLE_FORMAT :: u32(2) // A table of another format number is refused.
KEY_SIZE :: 32 // The bytes of the key of the tag.
TAG_SIZE :: 32 // The bytes of the tag: keyed BLAKE2b with an output of 32 bytes.
TABLE_OFFSET_MAGIC :: 0 // 8 bytes.
TABLE_OFFSET_FORMAT :: 8 // u32.
TABLE_OFFSET_COUNT :: 12 // u8: the rows that follow, ROW_CAPACITY at most.
TABLE_OFFSET_SETTING :: 13 // u8: 1 when the global setting is to forget, else 0.
TABLE_OFFSET_CLIENT_KEY_COUNT :: 14 // u8: the client keys of remote after the rows, CLIENT_KEY_CAPACITY at most.
TABLE_HEADER_SIZE :: 16 // One zero byte after the count of the client keys.
// A row: the length of the nickname (u8), the nickname with zero bytes
// after it (NAME_LIMIT bytes), the hash, the grants (u8), the persistence
// (u8), two zero bytes.
ROW_OFFSET_LENGTH :: 0
ROW_OFFSET_NICKNAME :: 1
ROW_OFFSET_HASH :: ROW_OFFSET_NICKNAME + NAME_LIMIT // 24.
ROW_OFFSET_GRANTS :: ROW_OFFSET_HASH + HASH_SIZE // 56.
ROW_OFFSET_PERSISTENCE :: ROW_OFFSET_GRANTS + 1 // 57.
ROW_SIZE :: 60
// The client keys of remote follow the rows: CLIENT_KEY_SIZE bytes each.
TABLE_OFFSET_CLIENT_KEYS :: TABLE_HEADER_SIZE + ROW_CAPACITY * ROW_SIZE // 976.
// The tag covers each byte before it. The rows after the count of the rows,
// and the keys after the count of the keys, are zero bytes: the table
// always has this size.
TABLE_OFFSET_TAG :: TABLE_OFFSET_CLIENT_KEYS + CLIENT_KEY_CAPACITY * CLIENT_KEY_SIZE // 1104.
TABLE_SIZE :: TABLE_OFFSET_TAG + TAG_SIZE // 1136.
#assert(TABLE_SIZE == 1136)
// The bytes of a table of the format 1, which had no client keys. This
// system does not read it; the size only names it in the log, so that no
// one restores a version that cannot verify.
OLDER_FORMAT_TABLE_SIZE :: 1008
#assert(OLDER_FORMAT_TABLE_SIZE != TABLE_SIZE)
#assert(ROW_OFFSET_PERSISTENCE + 1 <= ROW_SIZE)

// Why `table_decode` refused a table. The sentence of each one is in
// `table_problem_sentences`.
Table_File_Problem :: enum u8 {
	None,
	Wrong_Size, // Not TABLE_SIZE bytes, nor OLDER_FORMAT_TABLE_SIZE.
	Older_Format, // OLDER_FORMAT_TABLE_SIZE bytes: a table of the format 1, which this system does not read.
	Not_Authentic, // The tag does not verify under the key: another key, or a changed byte.
	Wrong_Magic,
	Wrong_Format,
	Too_Many_Rows, // A count over ROW_CAPACITY.
	Bad_Setting, // A global setting other than 0 or 1, or a header byte that is not zero.
	Bad_Row, // A nickname that a grant cannot name, a hash of zero bytes, an unknown grant or persistence, or a byte that must be zero.
	Two_Rows, // Two rows with one nickname.
	Bytes_After_Rows, // A byte after the last row is not zero.
	Bad_Client_Keys, // More than CLIENT_KEY_CAPACITY client keys, a key of zero bytes, one key two times, or a byte after the last key that is not zero.
}

// The sentence of each problem of a persisted table, for the log.
@(rodata)
table_problem_sentences := [Table_File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the table does not have 1136 bytes",
	.Older_Format     = "the table has 1008 bytes: it has the format 1 of an older system, which this system does not read; no version of it can be restored to verify",
	.Not_Authentic    = "its tag does not verify under the key of the principal: another key wrote it, or a byte changed",
	.Wrong_Magic      = "the table does not start with DISKGRNT",
	.Wrong_Format     = "the table has another format number",
	.Too_Many_Rows    = "the table counts more than 16 rows",
	.Bad_Setting      = "the global setting of the table is not 0 or 1, or its header has a byte that is not zero",
	.Bad_Row          = "a row has a nickname that no grant names, a hash of zero bytes, an unknown grant or persistence, or a byte that must be zero",
	.Two_Rows         = "two rows have one nickname",
	.Bytes_After_Rows = "the table has bytes that are not zero after its last row",
	.Bad_Client_Keys  = "the client keys of remote in the table are more than 4, or one is zero bytes, or one comes two times, or a byte after the last key is not zero",
}

// table_problem_is_format says if a refusal is a format that this system
// does not read: a restored version of the table has that format too.
table_problem_is_format :: proc "contextless" (problem: Table_File_Problem) -> bool {
	return problem == .Older_Format || problem == .Wrong_Format
}

// table_tag gives the keyed BLAKE2b of the bytes before the tag.
table_tag :: proc "contextless" (key: ^[KEY_SIZE]u8, bytes: ^[TABLE_SIZE]u8) -> (tag: [TAG_SIZE]u8) {
	context_of_the_hash: blake2.Blake2b_Context
	configuration := blake2.Blake2_Config {
		size = TAG_SIZE,
		key  = key^[:],
	}
	blake2.init(&context_of_the_hash, &configuration)
	blake2.update(&context_of_the_hash, bytes^[:TABLE_OFFSET_TAG])
	blake2.final(&context_of_the_hash, tag[:])
	return tag
}

// tags_equal compares two tags in a time that does not depend on the first
// byte that differs.
@(private)
tags_equal :: proc "contextless" (first, second: [TAG_SIZE]u8) -> bool {
	difference: u8
	for index in 0 ..< TAG_SIZE {
		difference |= first[index] ~ second[index]
	}
	return difference == 0
}


// table_encode writes the persisted table: the global setting, then each
// row that persists (row_persists), then the client keys of remote unless
// the global setting is to forget, then the tag under the key. A row or a
// key that lasts until the machine stops is not written.
table_encode :: proc "contextless" (table: ^Grant_Table, key: ^[KEY_SIZE]u8, out: ^[TABLE_SIZE]u8) {
	out^ = {}
	copy(out^[TABLE_OFFSET_MAGIC:][:8], TABLE_MAGIC)
	byte_order.write_u32_little_endian(out^[TABLE_OFFSET_FORMAT:], 0, TABLE_FORMAT)
	out^[TABLE_OFFSET_SETTING] = table.forget_by_default ? 1 : 0
	count := 0
	for &row in table.rows[:clamp(table.count, 0, ROW_CAPACITY)] {
		if !row_persists(table, &row) {
			continue
		}
		place := out^[TABLE_HEADER_SIZE + count * ROW_SIZE:][:ROW_SIZE]
		length := clamp(row.nickname_length, 0, NAME_LIMIT)
		place[ROW_OFFSET_LENGTH] = u8(length)
		copy(place[ROW_OFFSET_NICKNAME:][:length], row.nickname[:length])
		copy(place[ROW_OFFSET_HASH:][:HASH_SIZE], row.hash[:])
		place[ROW_OFFSET_GRANTS] = transmute(u8)row.grants
		place[ROW_OFFSET_PERSISTENCE] = u8(row.persistence)
		count += 1
	}
	out^[TABLE_OFFSET_COUNT] = u8(count)
	client_key_count := table_persisted_client_keys(table)
	for place in 0 ..< client_key_count {
		copy(out^[TABLE_OFFSET_CLIENT_KEYS + place * CLIENT_KEY_SIZE:][:CLIENT_KEY_SIZE], table.client_keys[place][:])
	}
	out^[TABLE_OFFSET_CLIENT_KEY_COUNT] = u8(client_key_count)
	tag := table_tag(key, out)
	copy(out^[TABLE_OFFSET_TAG:][:TAG_SIZE], tag[:])
}

// table_decode reads a persisted table that a store gave. It copies the
// bytes once and checks the copy: the store is data from the disk. The tag
// is checked first, so no field of a table that the key did not write is
// read.
table_decode :: proc "contextless" (bytes: []u8, key: ^[KEY_SIZE]u8) -> (table: Grant_Table, problem: Table_File_Problem) {
	if len(bytes) == OLDER_FORMAT_TABLE_SIZE {
		return {}, .Older_Format
	}
	if len(bytes) != TABLE_SIZE {
		return {}, .Wrong_Size
	}
	kept: [TABLE_SIZE]u8
	copy(kept[:], bytes)
	stored: [TAG_SIZE]u8
	copy(stored[:], kept[TABLE_OFFSET_TAG:][:TAG_SIZE])
	if !tags_equal(table_tag(key, &kept), stored) {
		return {}, .Not_Authentic
	}
	if string(kept[TABLE_OFFSET_MAGIC:][:8]) != TABLE_MAGIC {
		return {}, .Wrong_Magic
	}
	if byte_order.read_u32_little_endian(kept[TABLE_OFFSET_FORMAT:], 0) != TABLE_FORMAT {
		return {}, .Wrong_Format
	}
	count := int(kept[TABLE_OFFSET_COUNT])
	if count > ROW_CAPACITY {
		return {}, .Too_Many_Rows
	}
	setting := kept[TABLE_OFFSET_SETTING]
	if setting > 1 || kept[TABLE_OFFSET_CLIENT_KEY_COUNT + 1] != 0 {
		return {}, .Bad_Setting
	}
	table.forget_by_default = setting == 1
	for index in 0 ..< count {
		place := kept[TABLE_HEADER_SIZE + index * ROW_SIZE:][:ROW_SIZE]
		length := int(place[ROW_OFFSET_LENGTH])
		if length > NAME_LIMIT {
			return {}, .Bad_Row
		}
		nickname := string(place[ROW_OFFSET_NICKNAME:][:length])
		if problem_of_the_name, _ := nickname_grant_problem(nickname); problem_of_the_name != .None {
			return {}, .Bad_Row
		}
		for after in place[ROW_OFFSET_NICKNAME + length:ROW_OFFSET_HASH] {
			if after != 0 {
				return {}, .Bad_Row
			}
		}
		for after in place[ROW_OFFSET_PERSISTENCE + 1:] {
			if after != 0 {
				return {}, .Bad_Row
			}
		}
		grants := place[ROW_OFFSET_GRANTS]
		known_grants := transmute(u8)Disk_Grants{.Store}
		persistence, persistence_known := enum_word.member_of_word(Persistence, u64(place[ROW_OFFSET_PERSISTENCE]))
		if grants & ~known_grants != 0 || !persistence_known {
			return {}, .Bad_Row
		}
		row := &table.rows[index]
		copy(row.hash[:], place[ROW_OFFSET_HASH:][:HASH_SIZE])
		if row.hash == {} {
			return {}, .Bad_Row
		}
		if table_find(&table, nickname) != nil {
			return {}, .Two_Rows
		}
		row.nickname_length = copy(row.nickname[:], nickname)
		row.grants = transmute(Disk_Grants)grants
		row.persistence = persistence
		table.count = index + 1
	}
	for after in kept[TABLE_HEADER_SIZE + count * ROW_SIZE:TABLE_OFFSET_CLIENT_KEYS] {
		if after != 0 {
			return {}, .Bytes_After_Rows
		}
	}
	client_key_count := int(kept[TABLE_OFFSET_CLIENT_KEY_COUNT])
	if client_key_count > CLIENT_KEY_CAPACITY {
		return {}, .Bad_Client_Keys
	}
	for place in 0 ..< client_key_count {
		client_key: [CLIENT_KEY_SIZE]u8
		copy(client_key[:], kept[TABLE_OFFSET_CLIENT_KEYS + place * CLIENT_KEY_SIZE:][:CLIENT_KEY_SIZE])
		if client_key == ([CLIENT_KEY_SIZE]u8{}) || table_client_key_find(&table, client_key) >= 0 {
			return {}, .Bad_Client_Keys
		}
		table.client_keys[place] = client_key
		table.client_key_count = place + 1
	}
	for after in kept[TABLE_OFFSET_CLIENT_KEYS + client_key_count * CLIENT_KEY_SIZE:TABLE_OFFSET_TAG] {
		if after != 0 {
			return {}, .Bad_Client_Keys
		}
	}
	return table, .None
}
