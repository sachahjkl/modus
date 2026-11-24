#+build !freestanding
package storage_object

import "core:testing"
import "modus:contract/blake3"
import "internal:storage/store_encryption"

@(private = "file")
Enc_Disk :: struct {
	blocks:  [dynamic]Block,
	keys:    store_encryption.Store_Keys,
	source:  Source,
	counter: Counter,
}

@(private = "file")
enc_disk_make :: proc() -> ^Enc_Disk {
	disk := new(Enc_Disk)
	append(&disk.blocks, Block{})
	append(&disk.blocks, Block{})
	storage: store_encryption.Key
	id: [32]u8
	salt: store_encryption.Salt
	for i in 0 ..< 32 {
		storage[i] = u8(i + 5)
		id[i] = u8(i + 41)
		salt[i] = u8(i + 77)
	}
	disk.keys, _ = store_encryption.store_keys_of(storage, id, salt)
	disk.source = {
		read_node            = enc_read_node,
		read_block           = enc_read_block_unused,
		read_encrypted_block = enc_read_data,
		data                 = disk,
		encrypted            = true,
	}
	disk.counter = {
		name       = proc "contextless" (^Counter, u64) {},
		release    = proc "contextless" (^Counter, Child, int) {},
		write_node = enc_write_node,
		write_data = enc_write_data,
		data       = disk,
	}
	return disk
}

@(private = "file")
enc_disk_free :: proc(disk: ^Enc_Disk) {
	delete(disk.blocks)
	free(disk)
}

@(private = "file")
enc_read_node :: proc "contextless" (source: ^Source, pointer: Pointer, into: ^Block) -> Read {
	disk := (^Enc_Disk)(source.data)
	if pointer.block < 2 || pointer.block >= u64(len(disk.blocks)) {
		return .Wrong
	}
	into^ = disk.blocks[pointer.block]
	if !store_encryption.object_node_open(&disk.keys, pointer.block, pointer.check, (^Node)(into)) {
		return .Wrong
	}
	return .Good
}

@(private = "file")
enc_read_block_unused :: proc "contextless" (^Source, u64, ^Block) -> Read {
	return .Wrong
}

@(private = "file")
enc_read_data :: proc "contextless" (source: ^Source, pointer: Pointer, data_check: u64, into: ^Block) -> Read {
	disk := (^Enc_Disk)(source.data)
	if pointer.block < 2 || pointer.block >= u64(len(disk.blocks)) {
		return .Wrong
	}
	into^ = disk.blocks[pointer.block]
	if !store_encryption.data_block_decrypt(&disk.keys, pointer.block, pointer.check, data_check, into) {
		return .Wrong
	}
	return .Good
}

@(private = "file")
enc_write_node :: proc "contextless" (counter: ^Counter, bytes: ^Block) -> Pointer {
	disk := (^Enc_Disk)(counter.data)
	context = {}
	block_num := u64(len(disk.blocks))
	sealed := bytes^
	check, ok := store_encryption.object_node_seal(&disk.keys, block_num, (^Node)(&sealed))
	if !ok {
		return {}
	}
	append(&disk.blocks, sealed)
	return {block = block_num, check = check}
}

@(private = "file")
enc_write_data :: proc "contextless" (counter: ^Counter, bytes: ^Block, data_check: u64) -> Pointer {
	disk := (^Enc_Disk)(counter.data)
	context = {}
	block_num := u64(len(disk.blocks))
	sealed := bytes^
	cipher_check := store_encryption.data_block_encrypt(&disk.keys, block_num, data_check, &sealed)
	append(&disk.blocks, sealed)
	return {block = block_num, check = cipher_check}
}

// Encrypted object lifecycle: 1-block write/read, growth 1 -> 2 blocks,
// cut 2 -> 1 block preserving data_check, and tamper refusal erasing buffer.
@(test)
encrypted_object_single_multi_resize_cut_and_tamper :: proc(t: ^testing.T) {
	disk := enc_disk_make()
	defer enc_disk_free(disk)
	work := new(Work)
	defer free(work)
	page := new(Slot_Page)
	defer free(page)
	pages := [1]^Slot_Page{page}

	b0, b1, out: Block
	for i in 0 ..< BLOCK_SIZE {
		b0[i] = u8(i * 3 + 1)
		b1[i] = u8(i * 5 + 2)
	}

	// 1. Write a 1-block encrypted object.
	changes1 := [1]Change{{index = 0, bytes = &b0}}
	work_begin(work, &disk.source, &disk.counter, {}, changes1[:], pages[:])
	work_resize(work, 1000)
	work_change(work, 0)
	res1 := work_finish(work)
	testing.expect_value(t, work.failure, Failure.None)
	testing.expect(t, res1.root.block >= 2)
	testing.expect(t, res1.data_check != 0)
	testing.expect(t, disk.blocks[res1.root.block] != b0, "data block on disk must be ciphertext")

	state1 := State{root = res1.root, size = 1000, data_check = res1.data_check, hash = blake3.hash(b0[:1000]), has_hash = true}
	scratch_node: Node
	testing.expect_value(t, block_read(&disk.source, state1, 0, &out, &scratch_node), Read.Good)
	testing.expect(t, out == b0)

	// Tampered 256-bit Entry.hash on 1-block read with matching data_check must fail and erase out.
	bad_hash_state := state1
	bad_hash_state.hash[31] ~= 0x01
	testing.expect_value(t, block_read(&disk.source, bad_hash_state, 0, &out, &scratch_node), Read.Wrong)
	testing.expect(t, out == Block{}, "failed 1-block hash check must erase output buffer")

	// Wrong data_check on 1-block read must fail and erase out.
	bad_state := State{root = res1.root, size = 1000, data_check = res1.data_check ~ 1}
	testing.expect_value(t, block_read(&disk.source, bad_state, 0, &out, &scratch_node), Read.Wrong)
	testing.expect(t, out == Block{}, "failed encrypted block_read must erase output buffer")

	// 2. Grow from 1 block to 2 blocks (level 0 -> level 1, calling root_complete on encrypted block 0).
	changes2 := [1]Change{{index = 1, bytes = &b1}}
	work_begin(work, &disk.source, &disk.counter, state1, changes2[:], pages[:])
	work_resize(work, BLOCK_SIZE + 500)
	work_change(work, 0)
	res2 := work_finish(work)
	testing.expect_value(t, work.failure, Failure.None)
	testing.expect_value(t, res2.data_check, u64(0))
	state2 := State{root = res2.root, size = BLOCK_SIZE + 500}

	testing.expect_value(t, block_read(&disk.source, state2, 0, &out, &scratch_node), Read.Good)
	testing.expect(t, out == b0)
	testing.expect_value(t, block_read(&disk.source, state2, 1, &out, &scratch_node), Read.Good)
	testing.expect(t, out == b1)

	// 3. Cut back from 2 blocks to 1 block without changing block 0: data_check must be preserved.
	work_begin(work, &disk.source, &disk.counter, state2, nil, pages[:])
	work_resize(work, 1000)
	res3 := work_finish(work)
	testing.expect_value(t, work.failure, Failure.None)
	testing.expect_value(t, res3.root, res1.root)
	testing.expect_value(t, res3.data_check, res1.data_check)

	state3 := State{root = res3.root, size = 1000, data_check = res3.data_check}
	testing.expect_value(t, block_read(&disk.source, state3, 0, &out, &scratch_node), Read.Good)
	testing.expect(t, out == b0)

	// 4. Tamper a ciphertext byte on disk: read must refuse and erase buffer.
	disk.blocks[res1.root.block][7] ~= 0x40
	out[0] = 0xFF
	testing.expect_value(t, block_read(&disk.source, state3, 0, &out, &scratch_node), Read.Wrong)
	testing.expect(t, out == Block{})
}
