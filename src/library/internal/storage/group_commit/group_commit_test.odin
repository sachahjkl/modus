#+build !freestanding
package group_commit

import "core:testing"
import format "modus:contract/store"
import "internal:storage/store_encryption"

@(private = "file")
make_test_keys :: proc(t: ^testing.T, seed: u8) -> store_encryption.Store_Keys {
	storage_key: [32]u8
	owner: [32]u8
	salt: [32]u8
	for i in 0 ..< 32 {
		storage_key[i] = seed + u8(i)
		owner[i] = (seed ~ 0x5A) + u8(i)
		salt[i] = (seed ~ 0xA5) + u8(i)
	}
	keys, ok := store_encryption.store_keys_of(storage_key, owner, salt)
	testing.expect(t, ok, "store_keys_of succeeds for non-zero key")
	return keys
}

@(private = "file")
fill_block :: proc(b: ^Block, tag: u8) {
	for i in 0 ..< len(b) {
		b[i] = tag ~ u8(i & 0xFF)
	}
}

@(test)
group_commit_mixed_success_and_refusal_isolates_stores :: proc(t: ^testing.T) {
	b := new(Batch)
	defer free(b)

	// Store A (store_index = 2) stages cleanly.
	blk_a: Block
	fill_block(&blk_a, 0x11)
	input_a := Store_Input {
		store_index = 2,
		cell        = {limit = 100, used = 5, store = {block = 50, check = 0xAA}},
		store_name  = "store_a",
	}
	writes_a := [1]Write_Input{{number = 50, bytes = &blk_a}}
	taken_a := [1]u64{50}
	deltas_a := [2]Delta{{number = 50, change = 1}, {number = 10, change = -1}}
	later_a := [1]Later_Input{{pointer = {block = 50, check = 0xAA}, bytes = &blk_a}}

	slot_a, ok_a := batch_stage_store(b, &input_a, writes_a[:], taken_a[:], deltas_a[:], later_a[:], nil, nil, nil)
	testing.expect(t, ok_a)
	testing.expect_value(t, slot_a, 0)
	testing.expect(t, batch_has_store(b, 2))
	testing.expect(t, batch_block_taken(b, 50))
	testing.expect(t, !batch_block_taken(b, 10))

	owner_50, found_50 := batch_owner_of(b, 50)
	testing.expect(t, found_50)
	testing.expect_value(t, owner_50, u16(3)) // store_index 2 -> owner 3

	// Duplicate store A must be refused with Flush_First without mutating batch.
	testing.expect_value(t, batch_can_stage(b, 2, 1, 1, 1, 0, 0), Stage_Decision.Flush_First)
	_, ok_dup := batch_stage_store(b, &input_a, writes_a[:], taken_a[:], deltas_a[:], nil, nil, nil, nil)
	testing.expect(t, !ok_dup)
	testing.expect_value(t, b.store_count, 1)
	testing.expect_value(t, b.write_count, 1)

	// Encrypted store with nil keys is refused cleanly without touching Store A.
	bad_enc := Store_Input{store_index = 4, encrypted = true, store_keys = nil, store_name = "bad_enc"}
	_, ok_bad := batch_stage_store(b, &bad_enc, writes_a[:], taken_a[:], deltas_a[:], nil, nil, nil, nil)
	testing.expect(t, !ok_bad)
	testing.expect_value(t, b.store_count, 1)
	testing.expect_value(t, b.write_count, 1)
	testing.expect_value(t, b.blocks[0], blk_a)
}

@(test)
group_commit_multi_principal_key_isolation :: proc(t: ^testing.T) {
	b := new(Batch)
	defer free(b)

	k1 := make_test_keys(t, 0x31)
	k2 := make_test_keys(t, 0x77)

	plain_clear: Block
	plain_p1: Block
	plain_p2: Block
	fill_block(&plain_clear, 0x20)
	fill_block(&plain_p1, 0x40)
	fill_block(&plain_p2, 0x60)

	dc_p1 := format.check(plain_p1[:])
	dc_p2 := format.check(plain_p2[:])

	// Stage clear store (principal 0), encrypted store P1, and encrypted store P2 into ONE batch.
	in_clear := Store_Input{store_index = 1, store_name = "clear_store"}
	in_p1 := Store_Input{store_index = 5, encrypted = true, owner_slot = 0, store_keys = &k1, store_name = "p1_store"}
	in_p2 := Store_Input{store_index = 9, encrypted = true, owner_slot = 1, store_keys = &k2, store_name = "p2_store"}

	w_clear := [1]Write_Input{{number = 100, bytes = &plain_clear}}
	w_p1 := [1]Write_Input{{number = 101, bytes = &plain_p1, encrypted_data = true, data_check = dc_p1}}
	w_p2 := [1]Write_Input{{number = 102, bytes = &plain_p2, encrypted_data = true, data_check = dc_p2}}

	t_clear := [1]u64{100}
	t_p1 := [1]u64{101}
	t_p2 := [1]u64{102}

	d_clear := [1]Delta{{number = 100, change = 1}}
	d_p1 := [1]Delta{{number = 101, change = 1}}
	d_p2 := [1]Delta{{number = 102, change = 1}}

	_, ok0 := batch_stage_store(b, &in_clear, w_clear[:], t_clear[:], d_clear[:], nil, nil, nil, nil)
	_, ok1 := batch_stage_store(b, &in_p1, w_p1[:], t_p1[:], d_p1[:], nil, nil, nil, nil)
	_, ok2 := batch_stage_store(b, &in_p2, w_p2[:], t_p2[:], d_p2[:], nil, nil, nil, nil)
	testing.expect(t, ok0 && ok1 && ok2)
	testing.expect_value(t, b.store_count, 3)

	// Clear store stayed in clear; plaintext source buffers were NOT mutated in place.
	testing.expect_value(t, b.blocks[0], plain_clear)
	testing.expect(t, b.blocks[1] != plain_p1, "P1 staged block must be encrypted")
	testing.expect(t, b.blocks[2] != plain_p2, "P2 staged block must be encrypted")

	// Verify P1 ciphertext decrypts ONLY with K1; K2 yields garbage failing data_check.
	cipher_check_1 := format.check(b.blocks[1][:])
	dec_1 := b.blocks[1]
	testing.expect(t, store_encryption.data_block_decrypt(&k1, 101, cipher_check_1, dc_p1, &dec_1))
	testing.expect_value(t, dec_1, plain_p1)
	testing.expect_value(t, format.check(dec_1[:]), dc_p1)
	wrong_1 := b.blocks[1]
	_ = store_encryption.data_block_decrypt(&k2, 101, cipher_check_1, dc_p1, &wrong_1)
	testing.expect(t, wrong_1 != plain_p1, "K2 must not recover P1 plaintext")
	testing.expect(t, format.check(wrong_1[:]) != dc_p1, "K2 output must fail P1 data_check")

	// Verify P2 ciphertext decrypts ONLY with K2; K1 yields garbage failing data_check.
	cipher_check_2 := format.check(b.blocks[2][:])
	dec_2 := b.blocks[2]
	testing.expect(t, store_encryption.data_block_decrypt(&k2, 102, cipher_check_2, dc_p2, &dec_2))
	testing.expect_value(t, dec_2, plain_p2)
	testing.expect_value(t, format.check(dec_2[:]), dc_p2)
	wrong_2 := b.blocks[2]
	_ = store_encryption.data_block_decrypt(&k1, 102, cipher_check_2, dc_p2, &wrong_2)
	testing.expect(t, wrong_2 != plain_p2, "K1 must not recover P2 plaintext")
	testing.expect(t, format.check(wrong_2[:]) != dc_p2, "K1 output must fail P2 data_check")

	// Verify exact per-block owners across all 3 stores.
	o0, f0 := batch_owner_of(b, 100)
	o1, f1 := batch_owner_of(b, 101)
	o2, f2 := batch_owner_of(b, 102)
	testing.expect(t, f0 && f1 && f2)
	testing.expect_value(t, o0, u16(2))
	testing.expect_value(t, o1, u16(6))
	testing.expect_value(t, o2, u16(10))

	// Reset volatile-zeroes staged blocks and store keys.
	batch_reset(b)
	zero_block: Block
	zero_keys: store_encryption.Store_Keys
	testing.expect_value(t, b.blocks[0], zero_block)
	testing.expect_value(t, b.blocks[1], zero_block)
	testing.expect_value(t, b.blocks[2], zero_block)
	testing.expect_value(t, b.stores[1].store_keys, zero_keys)
	testing.expect_value(t, b.stores[2].store_keys, zero_keys)
	testing.expect(t, !batch_block_taken(b, 101))
}

@(test)
group_commit_merges_shared_and_distinct_store_table_pages :: proc(t: ^testing.T) {
	b := new(Batch)
	defer free(b)

	// Store 0 and Store 5 live on page 0; Store 63 lives on page 1.
	existing: [2]format.Store_Table_Page
	existing[0].magic = format.STORE_TABLE_MAGIC
	existing[0].cells[2].limit = 999 // Untouched neighbor cell on page 0.
	existing[1].magic = format.STORE_TABLE_MAGIC
	existing[1].cells[1].limit = 777 // Untouched neighbor cell on page 1.

	blk: Block
	s0 := Store_Input{store_index = 0, cell = {limit = 10, used = 2, store = {block = 20, check = 1}}}
	s5 := Store_Input{store_index = 5, cell = {limit = 20, used = 4, store = {block = 21, check = 2}}}
	s63 := Store_Input{store_index = format.STORES_OF_A_PAGE, cell = {limit = 30, used = 6, store = {block = 22, check = 3}}}

	w0 := [1]Write_Input{{number = 20, bytes = &blk}}
	w5 := [1]Write_Input{{number = 21, bytes = &blk}}
	w63 := [1]Write_Input{{number = 22, bytes = &blk}}
	t0 := [1]u64{20}
	t5 := [1]u64{21}
	t63 := [1]u64{22}

	_, ok0 := batch_stage_store(b, &s0, w0[:], t0[:], nil, nil, nil, nil, nil)
	_, ok5 := batch_stage_store(b, &s5, w5[:], t5[:], nil, nil, nil, nil, nil)
	_, ok63 := batch_stage_store(b, &s63, w63[:], t63[:], nil, nil, nil, nil, nil)
	testing.expect(t, ok0 && ok5 && ok63)

	batch_merge_store_pages(b, 2, existing[:])
	testing.expect_value(t, b.page_count, 2)
	testing.expect_value(t, b.page_indices[0], 0)
	testing.expect_value(t, b.page_indices[1], 1)

	// Page 0 holds BOTH Store 0 and Store 5 updates plus untouched cell 2.
	testing.expect_value(t, b.pages[0].cells[0].store.block, u64(20))
	testing.expect_value(t, b.pages[0].cells[5].store.block, u64(21))
	testing.expect_value(t, b.pages[0].cells[2].limit, u64(999))

	// Page 1 holds Store 63 update plus untouched cell 1.
	testing.expect_value(t, b.pages[1].cells[0].store.block, u64(22))
	testing.expect_value(t, b.pages[1].cells[1].limit, u64(777))
}

@(test)
group_commit_dropped_write_abort_rolls_back_all_stores :: proc(t: ^testing.T) {
	b := new(Batch)
	defer free(b)

	k1 := make_test_keys(t, 0x99)
	blk: Block
	fill_block(&blk, 0xEE)

	for s_idx in 0 ..< 3 {
		in_s := Store_Input {
			store_index = s_idx + 1,
			encrypted   = s_idx == 1,
			owner_slot  = 0,
			store_keys  = s_idx == 1 ? &k1 : nil,
		}
		base := u64(500 + s_idx * 10)
		ws := [2]Write_Input{
			{number = base, bytes = &blk},
			{number = base + 1, bytes = &blk, encrypted_data = s_idx == 1, data_check = 0x1234},
		}
		ts := [2]u64{base, base + 1}
		ds := [2]Delta{{number = base, change = 1}, {number = base + 1, change = 1}}
		_, ok := batch_stage_store(b, &in_s, ws[:], ts[:], ds[:], nil, nil, nil, nil)
		testing.expect(t, ok)
	}
	testing.expect_value(t, b.taken_count, 6)

	Freed_Log :: struct {
		numbers: [16]u64,
		count:   int,
	}
	freed: Freed_Log
	free_cb :: proc "contextless" (ctx: rawptr, number: u64) {
		log := (^Freed_Log)(ctx)
		if log.count < len(log.numbers) {
			log.numbers[log.count] = number
		}
		log.count += 1
	}

	batch_abort(b, free_cb, &freed)
	testing.expect_value(t, freed.count, 6)
	expected := [6]u64{500, 501, 510, 511, 520, 521}
	for i in 0 ..< 6 {
		testing.expect_value(t, freed.numbers[i], expected[i])
	}
	testing.expect_value(t, b.store_count, 0)
	testing.expect_value(t, b.write_count, 0)
	testing.expect_value(t, b.taken_count, 0)
	testing.expect_value(t, b.delta_count, 0)
	zero_keys: store_encryption.Store_Keys
	testing.expect_value(t, b.stores[1].store_keys, zero_keys)
}

@(test)
group_commit_capacity_bounds :: proc(t: ^testing.T) {
	b := new(Batch)
	defer free(b)

	// Invalid store indices and negative counts are refused.
	testing.expect_value(t, batch_can_stage(b, -1, 1, 1, 1, 0, 0), Stage_Decision.Flush_First)
	testing.expect_value(t, batch_can_stage(b, format.STORE_CAPACITY, 1, 1, 1, 0, 0), Stage_Decision.Flush_First)
	testing.expect_value(t, batch_can_stage(b, 0, -1, 0, 0, 0, 0), Stage_Decision.Flush_First)

	// Exact WRITE_CAPACITY accepted; one past WRITE_CAPACITY returns Flush_First.
	testing.expect_value(t, batch_can_stage(b, 0, WRITE_CAPACITY, 0, 0, 0, 0), Stage_Decision.Can_Stage)
	testing.expect_value(t, batch_can_stage(b, 0, WRITE_CAPACITY + 1, 0, 0, 0, 0), Stage_Decision.Flush_First)

	// Exact DELTA_CAPACITY accepted; one past returns Flush_First.
	testing.expect_value(t, batch_can_stage(b, 0, 0, 0, DELTA_CAPACITY, 0, 0), Stage_Decision.Can_Stage)
	testing.expect_value(t, batch_can_stage(b, 0, 0, 0, DELTA_CAPACITY + 1, 0, 0), Stage_Decision.Flush_First)

	// Exact LATER_CAPACITY and HASH_ENTRY_CAPACITY accepted; one past returns Flush_First.
	testing.expect_value(t, batch_can_stage(b, 0, 0, 0, 0, LATER_CAPACITY, 0), Stage_Decision.Can_Stage)
	testing.expect_value(t, batch_can_stage(b, 0, 0, 0, 0, LATER_CAPACITY + 1, 0), Stage_Decision.Flush_First)
	testing.expect_value(t, batch_can_stage(b, 0, 0, 0, 0, 0, HASH_ENTRY_CAPACITY), Stage_Decision.Can_Stage)
	testing.expect_value(t, batch_can_stage(b, 0, 0, 0, 0, 0, HASH_ENTRY_CAPACITY + 1), Stage_Decision.Flush_First)

	// Fill STORE_CAPACITY stores exactly; the (STORE_CAPACITY + 1)th returns Flush_First.
	blk: Block
	for i in 0 ..< STORE_CAPACITY {
		in_s := Store_Input{store_index = i}
		ws := [1]Write_Input{{number = u64(10 + i), bytes = &blk}}
		ts := [1]u64{u64(10 + i)}
		_, ok := batch_stage_store(b, &in_s, ws[:], ts[:], nil, nil, nil, nil, nil)
		testing.expect(t, ok)
	}
	testing.expect_value(t, b.store_count, STORE_CAPACITY)
	testing.expect_value(t, batch_can_stage(b, STORE_CAPACITY, 1, 1, 0, 0, 0), Stage_Decision.Flush_First)
}
