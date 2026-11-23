// The contract of a builder (src/md/features/recipes.md, "The builder"):
// the slots of the context of a builder, the places of the stores of one
// build in the private store of the service recipes, the name of the
// export, and the bound of one build. The service recipes and each builder
// agree on it; a host test checks the context that the service makes.
package builder

import "modus:contract/blake3"
import "modus:contract/isolated"
import op "modus:contract/operation"

// The slots of the context of a builder. The call host takes the call
// ring and the call region, as each call host; the two stores are shares
// of the storage service, opened with storage.open_handles.
GRANT_CALL_RING :: isolated.GRANT_RING // Memory: the call ring of the call host.
GRANT_CALL_REGION :: isolated.GRANT_REGION // Memory: the call region of the call host.
GRANT_INPUT_RING :: 2 // Memory: the call ring of the input store, a share that reads only.
GRANT_INPUT_REGION :: 3 // Memory: the call region of the input store.
GRANT_OUTPUT_RING :: 4 // Memory: the call ring of the store "out", a share that changes.
GRANT_OUTPUT_REGION :: 5 // Memory: the call region of the store "out".
GRANT_STORAGE_SERVICE :: 6 // The storage service, with Read: its state.
GRANT_LOG :: op.CONTEXT_LOG // The log, with Write.

// The value of the size of the file of the storage service, which the
// service recipes maps at storage.FILE_ADDRESS. The call host reads the
// values 0 to 3 (isolated), so this one comes after them.
VALUE_STORAGE_FILE_SIZE :: 4
#assert(VALUE_STORAGE_FILE_SIZE > isolated.VALUE_FILE_ADDRESS && VALUE_STORAGE_FILE_SIZE > isolated.VALUE_FILE_SIZE)
#assert(VALUE_STORAGE_FILE_SIZE > isolated.VALUE_REPLACEMENT_OFFSET && VALUE_STORAGE_FILE_SIZE > isolated.VALUE_REPLACEMENT_COUNT)
#assert(VALUE_STORAGE_FILE_SIZE < op.CONTEXT_VALUE_SEED)

// The export of a builder: build(inputs: Table(Recipe_Input_Row, Read),
// arguments: Bytes) -> Integer.
BUILD_EXPORT :: "build"

// The most time of one build, from the call of build: past it, the
// service ends the call host and refuses the build with Builder_Timed_Out.
BUILD_TIME_BOUND_MILLISECONDS :: 60_000

// The places of the private store of the service recipes.
OBJECTS_PLACE :: "objects" // Each object of each output, under its hexadecimal hash.
BUILD_PLACE :: "build" // The place of the one build that runs.
INPUT_PLACE :: "in" // Under BUILD_PLACE: the objects of the inputs, the root of the input store.
OUTPUT_PLACE :: "out" // Under BUILD_PLACE: the root of the store "out".

// The most objects of the inputs of one build: each is one clone.
MAX_INPUT_OBJECTS :: 256

// The parts of the context of a builder: each holds a handle, and no other
// slot does.
Context_Slot :: enum u8 {
	Call_Ring,
	Call_Region,
	Input_Ring,
	Input_Region,
	Output_Ring,
	Output_Region,
	Storage_Service,
	Log,
}

// The index of each part in the handles of the context.
@(rodata)
CONTEXT_SLOT_INDEX := [Context_Slot]int {
	.Call_Ring       = GRANT_CALL_RING,
	.Call_Region     = GRANT_CALL_REGION,
	.Input_Ring      = GRANT_INPUT_RING,
	.Input_Region    = GRANT_INPUT_REGION,
	.Output_Ring     = GRANT_OUTPUT_RING,
	.Output_Region   = GRANT_OUTPUT_REGION,
	.Storage_Service = GRANT_STORAGE_SERVICE,
	.Log             = GRANT_LOG,
}

// Why a context is no context of a builder.
Context_Refusal :: enum u8 {
	None          = 0,
	Missing_Slot  = 1, // A part of the context holds no handle.
	Extra_Slot    = 2, // A slot that is no part of the context holds a handle: a network, a root ring, a store of another kind.
	Wrong_Seed    = 3, // The seed is not the recipe hash.
	Wrong_Strength = 4, // The strength of the seed is not None: the seed is public.
	Extra_Value   = 5, // A value that the context of a builder does not hold is not 0.
}

// seed_values gives the four values of the seed of a builder: the recipe
// hash, in the order of its bytes.
seed_values :: proc "contextless" (recipe_hash: blake3.Hash) -> (values: [op.CONTEXT_VALUE_SEED_COUNT]u64) {
	return transmute([op.CONTEXT_VALUE_SEED_COUNT]u64)recipe_hash
}

// context_check checks the context that a starter gives a builder, before
// its start: holds[i] says that the slot i holds a handle. The call host
// writes the values of its files (isolated) itself, so values holds the
// size of the file of the storage service, the seed and its strength, and
// nothing else. slot is the index of the slot or the value that is refused.
context_check :: proc "contextless" (holds: [op.CONTEXT_HANDLES]bool, values: [op.CONTEXT_VALUES]u64, recipe_hash: blake3.Hash) -> (refusal: Context_Refusal, slot: int) {
	expected: [op.CONTEXT_HANDLES]bool
	for index in CONTEXT_SLOT_INDEX {
		expected[index] = true
	}
	for index in 0 ..< op.CONTEXT_HANDLES {
		if expected[index] && !holds[index] {
			return .Missing_Slot, index
		}
		if holds[index] && !expected[index] {
			return .Extra_Slot, index
		}
	}
	seed := seed_values(recipe_hash)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		if values[op.CONTEXT_VALUE_SEED + index] != seed[index] {
			return .Wrong_Seed, op.CONTEXT_VALUE_SEED + index
		}
	}
	if values[op.CONTEXT_VALUE_SEED_STRENGTH] != u64(op.Seed_Strength.None) {
		return .Wrong_Strength, op.CONTEXT_VALUE_SEED_STRENGTH
	}
	for index in 0 ..< op.CONTEXT_VALUES {
		is_seed := index >= op.CONTEXT_VALUE_SEED && index < op.CONTEXT_VALUE_SEED + op.CONTEXT_VALUE_SEED_COUNT
		if is_seed || index == op.CONTEXT_VALUE_SEED_STRENGTH || index == VALUE_STORAGE_FILE_SIZE {
			continue
		}
		if values[index] != 0 {
			return .Extra_Value, index
		}
	}
	return .None, 0
}
