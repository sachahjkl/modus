#+build !freestanding
package store_encryption

import "core:fmt"
import "core:testing"
import "core:time"

// The cost of the encryption of a store on the host, as a measure: it is
// printed, never a bound of a test (src/md/features/store_encryption.md,
// "The measure"). Opt-in: odin test with -define:STORE_ENCRYPTION_MEASURE=true.
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
			data_encrypt(&keys, number, number, block)
		}
		data[run] = time.tick_since(start)
		start = time.tick_now()
		for number in u64(0) ..< MEASURE_BLOCKS {
			check := node_seal(&keys, number, block)
			_ = node_open(&keys, number, check, block)
		}
		nodes[run] = time.tick_since(start)
	}
	per_block :: proc(duration: time.Duration) -> f64 {
		return f64(time.duration_nanoseconds(duration)) / f64(MEASURE_BLOCKS)
	}
	fmt.printfln("store encryption on the host, median of %d runs of %d blocks of %d bytes: a copy %.0f ns, a block of data %.0f ns, a node sealed and opened %.0f ns", MEASURE_RUNS, MEASURE_BLOCKS, BLOCK_SIZE, per_block(median(&copies)), per_block(median(&data)), per_block(median(&nodes)))
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
