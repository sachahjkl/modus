#+build !freestanding
package store_encryption

import "core:fmt"
import "core:testing"
import "core:time"
import "modus:contract/store"

// The cost of the encryption of a store on the host, as a measure: it is
// printed, never a bound of a test (src/md/features/store_encryption.md,
// "Vector XChaCha20 and the measure"). Opt-in: odin test with -define:STORE_ENCRYPTION_MEASURE=true.
STORE_ENCRYPTION_MEASURE :: #config(STORE_ENCRYPTION_MEASURE, false)
MEASURE_BLOCKS :: 4096 // 16 MiB of blocks: enough runs that one block is a small part of the time.
MEASURE_RUNS :: 21 // The median of 21 runs, as the measure runs of the system.

@(test)
the_cost_of_the_encryption_of_a_block :: proc(t: ^testing.T) {
	when !STORE_ENCRYPTION_MEASURE {
		return
	}
	keys := test_measure_keys()
	block := new(Block)
	defer free(block)
	copy_target := new(Block)
	defer free(copy_target)
	for index in 0 ..< BLOCK_SIZE {
		block[index] = u8(index * 13)
	}
	leaf := new(Block)
	defer free(leaf)
	hdr := (^store.Tree_Header)(leaf)
	hdr^ = {level = 0, count = store.LEAF_CAPACITY, magic = store.NODE_MAGIC}
	stride :: size_of(store.Entry_Name) + size_of(store.Entry)
	for i in 0 ..< store.LEAF_CAPACITY {
		base := store.TREE_HEADER_SIZE + i * stride
		(^store.Entry_Name)(&leaf[base])^ = store.entry_name("measured-entry-name")
		(^store.Entry)(&leaf[base + size_of(store.Entry_Name)])^ = {
			kind    = u64(store.Entry_Kind.Object),
			size    = 4096,
			pointer = {block = u64(10 + i), check = u64(100 + i)},
		}
	}
	median :: proc(runs: ^[MEASURE_RUNS]time.Duration) -> time.Duration {
		for i in 1 ..< MEASURE_RUNS {
			for j := i; j > 0 && runs[j] < runs[j - 1]; j -= 1 {
				runs[j], runs[j - 1] = runs[j - 1], runs[j]
			}
		}
		return runs[MEASURE_RUNS / 2]
	}
	copies, data, nodes: [MEASURE_RUNS]time.Duration
	for run in 0 ..< MEASURE_RUNS {
		start := time.tick_now()
		for number in u64(0) ..< MEASURE_BLOCKS {
			copy_target^ = block^
			copy_target[0] ~= u8(number)
		}
		copies[run] = time.tick_since(start)
		start = time.tick_now()
		for number in u64(0) ..< MEASURE_BLOCKS {
			_ = data_block_encrypt(&keys, number, number, block)
		}
		data[run] = time.tick_since(start)
		start = time.tick_now()
		for number in u64(0) ..< MEASURE_BLOCKS {
			check, _ := tree_node_seal(&keys, number, leaf)
			_ = tree_node_open(&keys, number, check, leaf)
		}
		nodes[run] = time.tick_since(start)
	}
	per_block :: proc(duration: time.Duration) -> f64 {
		return f64(time.duration_nanoseconds(duration)) / f64(MEASURE_BLOCKS)
	}
	fmt.printfln("store encryption on the host, median of %d runs of %d blocks of %d bytes: a copy %.0f ns, a block of data (encrypt+check) %.0f ns, a full tree leaf (seal+open) %.0f ns", MEASURE_RUNS, MEASURE_BLOCKS, BLOCK_SIZE, per_block(median(&copies)), per_block(median(&data)), per_block(median(&nodes)))
}

@(private = "file")
test_measure_keys :: proc() -> Store_Keys {
	storage: Key
	identifier: [32]u8
	salt: Salt
	for index in 0 ..< 32 {
		storage[index] = u8(index + 1)
		identifier[index] = u8(index + 40)
		salt[index] = u8(index + 90)
	}
	keys, _ := store_keys_of(storage, identifier, salt)
	return keys
}
