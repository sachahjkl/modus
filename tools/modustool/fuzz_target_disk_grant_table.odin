package modustool

import "core:fmt"
import "core:slice"
import "modus:support/disk_program"

// The fuzz target of the disk grant table (src/md/infrastructure/fuzzing.md,
// "The subtle points"): the root service reads the persisted table of a
// principal from a store. The tag is
// checked first, so the target holds the key of the tag, as a key holder
// does: with the seal bit, it writes the tag of the bytes, and the decoder
// behind the tag reads them. A fault after the tag is a fault of a key
// holder, and the decoder must still refuse it.

// The key of the tag in the target: any fixed key gives the decoder the
// same work.
@(rodata)
fuzz_grant_table_key := [disk_program.KEY_SIZE]u8{0 = 0x4B, 7 = 0x01, 31 = 0xA5}

// The first byte of an input: bit 0 says that the target writes the tag of
// the key over the last bytes of the table.
FUZZ_GRANT_TABLE_SEAL :: 1

// fuzz_grant_table_seal writes the tag of the key over a table of
// TABLE_SIZE bytes; another size stays as it is.
@(private = "file")
fuzz_grant_table_seal :: proc(bytes: []u8) {
	if len(bytes) != disk_program.TABLE_SIZE {
		return
	}
	key := fuzz_grant_table_key
	table := (^[disk_program.TABLE_SIZE]u8)(raw_data(bytes))
	tag := disk_program.table_tag(&key, table)
	copy(bytes[disk_program.TABLE_OFFSET_TAG:], tag[:])
}

// fuzz_grant_table_persisted gives the table that table_encode keeps of a
// table: each row that persists, in order, and the client keys unless the
// global setting is to forget.
@(private = "file")
fuzz_grant_table_persisted :: proc(table: ^disk_program.Grant_Table) -> (kept: disk_program.Grant_Table) {
	kept.forget_by_default = table.forget_by_default
	for &row in table.rows[:table.count] {
		if disk_program.row_persists(table, &row) {
			kept.rows[kept.count] = row
			kept.count += 1
		}
	}
	kept.client_key_count = disk_program.table_persisted_client_keys(table)
	copy(kept.client_keys[:kept.client_key_count], table.client_keys[:kept.client_key_count])
	return kept
}

// fuzz_disk_grant_table_execute: a table that table_decode accepts holds
// rows and keys by its rules, encodes to a table that decodes to its
// persisted part, and to its own bytes when each row and key persists. A
// refusal gives the zero table and changes no byte.
fuzz_disk_grant_table_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if len(input) == 0 {
		return FUZZ_PASSED
	}
	bytes := slice.clone(input[1:], context.temp_allocator)
	if input[0] & FUZZ_GRANT_TABLE_SEAL != 0 {
		fuzz_grant_table_seal(bytes)
	}
	before := slice.clone(bytes, context.temp_allocator)
	key := fuzz_grant_table_key
	table, problem := disk_program.table_decode(bytes, &key)
	if !slice.equal(before, bytes) {
		return fuzz_broken(.Contract, "table_decode changed the bytes of the table")
	}
	if problem > max(disk_program.Table_File_Problem) {
		return fuzz_broken(.Contract, "table_decode gives a problem out of its enumeration: %d", u8(problem))
	}
	if problem != .None {
		if table != (disk_program.Grant_Table{}) {
			return fuzz_broken(.Contract, "table_decode refuses with %v and gives rows", problem)
		}
		if disk_program.table_read_decision(false, problem, false) != .Keep {
			return fuzz_broken(.Contract, "a refused table is not kept")
		}
		return FUZZ_PASSED
	}
	if verdict := fuzz_grant_table_rules(&table); verdict.oracle != .None {
		return verdict
	}
	encoded: [disk_program.TABLE_SIZE]u8
	disk_program.table_encode(&table, &key, &encoded)
	again, again_problem := disk_program.table_decode(encoded[:], &key)
	if again_problem != .None {
		return fuzz_broken(.Round_Trip, "table_decode refuses what table_encode wrote: %v", again_problem)
	}
	if again != fuzz_grant_table_persisted(&table) {
		return fuzz_broken(.Round_Trip, "the table read again differs from the part of the table that persists")
	}
	all_persist := disk_program.table_persisted_rows(&table) == table.count && disk_program.table_persisted_client_keys(&table) == table.client_key_count
	if all_persist && !slice.equal(encoded[:], bytes) {
		return fuzz_broken(.Round_Trip, "a table whose rows and keys all persist encodes to other bytes")
	}
	return FUZZ_PASSED
}

// fuzz_grant_table_rules checks the rules of a table that table_decode
// accepted: the counts in their bounds, each nickname a nickname of a
// grant and once, no zero hash, the client keys not zero and once.
@(private = "file")
fuzz_grant_table_rules :: proc(table: ^disk_program.Grant_Table) -> Fuzz_Verdict {
	if table.count < 0 || table.count > disk_program.ROW_CAPACITY || table.client_key_count < 0 || table.client_key_count > disk_program.CLIENT_KEY_CAPACITY {
		return fuzz_broken(.Contract, "the table has %d rows and %d keys", table.count, table.client_key_count)
	}
	for &row, index in table.rows[:table.count] {
		nickname := disk_program.row_nickname(&row)
		if problem, _ := disk_program.nickname_grant_problem(nickname); problem != .None {
			return fuzz_broken(.Contract, "the row %d has the nickname %q: %v", index, nickname, problem)
		}
		if row.hash == ([disk_program.HASH_SIZE]u8{}) || row.persistence > max(disk_program.Persistence) {
			return fuzz_broken(.Contract, "the row %d has a zero hash or the persistence %d", index, u8(row.persistence))
		}
		if disk_program.table_find(table, nickname) != &row {
			return fuzz_broken(.Contract, "the nickname %q has two rows", nickname)
		}
	}
	for item, index in table.client_keys[:table.client_key_count] {
		if item == ([disk_program.CLIENT_KEY_SIZE]u8{}) || disk_program.table_client_key_find(table, item) != index {
			return fuzz_broken(.Contract, "the client key %d is zero or comes two times", index)
		}
	}
	return FUZZ_PASSED
}

// fuzz_disk_grant_table_seeds gives tables that the writer of the root
// service writes, sealed, then the edges: a table that is not sealed, the
// size of the older format, and one byte short.
fuzz_disk_grant_table_seeds :: proc(seeds: ^[dynamic][]u8) {
	key := fuzz_grant_table_key
	tables := make([dynamic]disk_program.Grant_Table, context.temp_allocator)
	append(&tables, disk_program.Grant_Table{})
	several: disk_program.Grant_Table
	hash: [disk_program.HASH_SIZE]u8
	for index in 0 ..< 3 {
		hash[0] = u8(index + 1)
		_ = disk_program.table_allow(&several, fmt.tprintf("program_%d", index), hash, .Store)
	}
	_ = disk_program.table_persistence_set(&several, "program_1", .Forget)
	client_key: [disk_program.CLIENT_KEY_SIZE]u8
	client_key[5] = 9
	_ = disk_program.table_client_key_add(&several, client_key)
	append(&tables, several)
	forgetting := several
	forgetting.forget_by_default = true
	_ = disk_program.table_persistence_set(&forgetting, "program_2", .Persist)
	append(&tables, forgetting)
	full: disk_program.Grant_Table
	for index in 0 ..< disk_program.ROW_CAPACITY {
		hash[0], hash[31] = u8(index), 0xFF
		_ = disk_program.table_allow(&full, fmt.tprintf("a-very-long-nickname-%02d", index), hash, .Store)
	}
	for index in 0 ..< disk_program.CLIENT_KEY_CAPACITY {
		client_key[0] = u8(index + 1)
		_ = disk_program.table_client_key_add(&full, client_key)
	}
	append(&tables, full)
	for &table in tables {
		encoded: [disk_program.TABLE_SIZE]u8
		disk_program.table_encode(&table, &key, &encoded)
		seed := make([]u8, 1 + disk_program.TABLE_SIZE)
		seed[0] = FUZZ_GRANT_TABLE_SEAL
		copy(seed[1:], encoded[:])
		append(seeds, seed)
	}
	unsealed := slice.clone(seeds[len(seeds) - 1])
	unsealed[0] = 0
	unsealed[1 + disk_program.TABLE_OFFSET_COUNT] += 1
	append(seeds, unsealed, make([]u8, 1 + disk_program.OLDER_FORMAT_TABLE_SIZE), make([]u8, disk_program.TABLE_SIZE))
}
