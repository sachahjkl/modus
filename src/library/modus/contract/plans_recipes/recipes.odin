// Recipes and sandboxed builder contract: canonical recipe specifications,
// domain-separated BLAKE3 recipe hashing, substitution policy verification,
// sandbox configuration, and build results (src/md/features/recipes.md).
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package plans_recipes

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"

// Domain separation context string passed to blake3.derive_key so recipe
// hashes are cryptographically separated from objects, trees, and plans.
RECIPE_HASH_DOMAIN :: "modus recipe v1"

// Structural bounds on recipes and deterministic builder arguments: the
// link step of a real program names hundreds of objects, and a release
// recipe carries a long argument record. A record of the largest bounds is
// about 90 KiB: a holder keeps it in its memory, never on a stack, and the
// recipe hash reads it in pieces with no canonical buffer.
MAX_RECIPE_INPUTS :: 256
MAX_RECIPE_ARG_BYTES :: 64 * 1024

// Context slots for the delegated recipes service.
RECIPES_SERVICE_RING_SLOT :: 10
RECIPES_SERVICE_REGION_SLOT :: 11

// Closed set of recipe build modes (maps directly to object_cache.Substitution_Mode).
// Zero means unset and is refused at the border.
Build_Mode :: enum u8 {
	None         = 0,
	Prefer_Cache = 1,
	Build_Only   = 2,
	Cache_Only   = 3,
	Verify       = 4,
}

// Closed set of build result classifications returned by recipes.build.
Recipe_Build_Outcome :: enum u8 {
	None          = 0,
	From_Cache    = 1,
	Built_Locally = 2,
	Refused       = 3,
	Building      = 4, // A guest build runs on the build thread of the service: the history gives its end.
}

// Closed set of refusal reasons for recipe validation, cache verification,
// and sandboxed builds.
Recipe_Refusal :: enum u8 {
	None                  = 0,
	Zero_Builder_Hash     = 1,
	Bad_Output_Kind       = 2,
	Bad_Build_Mode        = 3,
	Too_Many_Inputs       = 4,
	Invalid_Input_Name    = 5,
	Zero_Input_Hash       = 6,
	Duplicate_Input       = 7,
	Bad_Input_Kind        = 8,
	Arguments_Too_Large   = 9,
	Nonzero_Padding       = 10,
	Buffer_Too_Small      = 11,
	Cache_Miss            = 12,
	Untrusted_Realisation = 13,
	Hash_Mismatch         = 14,
	Bad_Signature         = 15,
	Malformed_Output      = 16,
	Builder_Failed        = 17,
	Verify_Disagreement   = 18,
	Sandbox_Violation     = 19,
	Store_Full            = 20,
	Bad_Head_Value        = 21,
	Unknown_Recipe        = 22,
	Recipe_Limit_Reached  = 23,
	Builder_Needs_Sandbox = 24,
	Store_Failed          = 25, // The private store did not take the realisation: nothing was recorded.
	Store_Damaged         = 26, // A realisation of the private store does not decode, or its output does not match its hash.
	Untyped_Hash          = 27, // The arguments of a recipe hold a bare hash: it names no kind, so it names no input.
	Nested_Input          = 28, // A tree or a module file below the first level of the arguments: its input would have no name.
	Not_A_Recipe          = 29, // The value is not a recipe, or its arguments are not a record.
	Damaged_Recipe        = 30, // The recipe does not decode, or its written hash is not the hash of its record.
	Unsupported_Argument  = 31, // An argument of a kind that a recipe does not take: a recipe, a follow, a store, a plan, a project, or a negative source_date.
	Builder_Absent        = 32, // No module of the boot image has the hash of the builder.
	Input_Absent          = 33, // An object of an input is not in the place of the objects of the service: no build gave it.
	Builder_Timed_Out     = 34, // The builder gave no answer within builder.BUILD_TIME_BOUND_MILLISECONDS: the service ended it.
	Input_Too_Large       = 35, // The inputs of one build hold more objects than builder.MAX_INPUT_OBJECTS, or a tree nested deeper than the bound.
	Output_Too_Large      = 36, // The output passes the size bound of the recipe.
	Builder_Busy          = 37, // The guest builds that the service holds are as many as it runs and queues: a build waits for room.
	Memory_Past_Bound     = 38, // The guest build needs more memory than the budget of the service has left.
	Put_Quota_Reached     = 39, // The principal put as many objects in the hour as a principal may keep while no recipe names them.
	Build_Cancelled       = 40, // The principal that queued the guest build cancelled it.
}

// recipe_refusal_of_word is the one border of a refusal word that crosses
// a call: the value found of an error record of the service recipes. A
// word that names no refusal is refused, and so is None, which is no
// refusal.
recipe_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Recipe_Refusal, ok: bool) {
	member := enum_word.member_of_word(Recipe_Refusal, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// The words of each refusal of a recipe, for the failure of an evaluation
// that names one.
@(rodata)
recipe_refusal_words := [Recipe_Refusal]string {
	.None                  = "no refusal",
	.Zero_Builder_Hash     = "the builder has a zero hash",
	.Bad_Output_Kind       = "the output kind is no kind",
	.Bad_Build_Mode        = "the build mode is no mode",
	.Too_Many_Inputs       = "more inputs than a recipe holds",
	.Invalid_Input_Name    = "an input has a name that a tree refuses",
	.Zero_Input_Hash       = "an input has a zero hash",
	.Duplicate_Input       = "two inputs have one name",
	.Bad_Input_Kind        = "an input kind is no kind",
	.Arguments_Too_Large   = "the arguments pass the bytes of a recipe",
	.Nonzero_Padding       = "the padding of the record is not zero",
	.Buffer_Too_Small      = "the buffer is too small",
	.Cache_Miss            = "no cache has the realisation",
	.Untrusted_Realisation = "the realisation has no trusted signer",
	.Hash_Mismatch         = "the output does not have its hash",
	.Bad_Signature         = "the signature of the realisation is wrong",
	.Malformed_Output      = "the output does not decode",
	.Builder_Failed        = "the builder failed",
	.Verify_Disagreement   = "two builds gave two outputs",
	.Sandbox_Violation     = "the builder left its sandbox",
	.Store_Full            = "the store is full",
	.Bad_Head_Value        = "a value of the head is wrong",
	.Unknown_Recipe        = "no recipe has this hash",
	.Recipe_Limit_Reached  = "the registry holds no more recipes",
	.Builder_Needs_Sandbox = "the builder needs the sandbox",
	.Store_Failed          = "the store did not take the realisation",
	.Store_Damaged         = "the realisation of the store is damaged",
	.Untyped_Hash          = "a bare hash names no input: use here() or module(...)",
	.Nested_Input          = "a tree or a module below the first level of the arguments",
	.Not_A_Recipe          = "the value is not a recipe",
	.Damaged_Recipe        = "the recipe does not decode",
	.Unsupported_Argument  = "an argument of a kind that a recipe does not take",
	.Builder_Absent        = "no module of the boot image is the builder",
	.Input_Absent          = "an input is not an output of a build of this machine",
	.Builder_Timed_Out     = "the builder gave no answer within the bound of a build",
	.Input_Too_Large       = "the inputs hold more objects than one build takes",
	.Output_Too_Large      = "the output passes the size bound of the recipe",
	.Builder_Busy          = "the guest builds of the service are full",
	.Memory_Past_Bound     = "the guest build needs more memory than the service has",
	.Put_Quota_Reached     = "the principal kept as many objects in the hour as it may",
	.Build_Cancelled       = "the principal cancelled the build",
}

// Closed set of commands accepted on the recipes service ring.
Recipes_Ring_Command :: enum u32 {
	None             = 0,
	Build_Recipe     = 1,
	Query_Provenance = 2,
	Query_Counts     = 3,
}

// One named content-addressed input tree or object passed to a builder.
Recipe_Input :: struct {
	name_bytes:  [MAX_ENTRY_NAME_BYTES]u8,
	name_length: u8,
	kind:        object_cache.Cache_Object_Kind, // A border that takes a word refuses one that names no kind.
	hash:        blake3.Hash,
}

// Complete deterministic recipe specification. Two specs with the same
// builder, output kind, source date, input set (regardless of order), and
// canonical arguments produce the same recipe_hash.
Recipe_Spec :: struct {
	builder_hash:       blake3.Hash,
	output_kind:        object_cache.Cache_Object_Kind, // A border that takes a word refuses one that names no kind.
	source_date_unix:   u64,
	output_block_limit: u64,
	input_count:        u32,
	inputs:             [MAX_RECIPE_INPUTS]Recipe_Input,
	arguments_length:   u32,
	arguments:          [MAX_RECIPE_ARG_BYTES]u8,
}

// Sandboxed builder execution environment derived from a validated Recipe_Spec.
// A builder always receives read-only inputs, an empty output store, frozen
// date, deterministic seed equal to recipe_hash, zero network, and no root ring.
Builder_Sandbox_Spec :: struct {
	recipe_hash:        blake3.Hash,
	builder_hash:       blake3.Hash,
	output_kind:        object_cache.Cache_Object_Kind,
	random_seed:        blake3.Hash,
	frozen_date_unix:   u64,
	output_block_limit: u64,
	allow_network:      bool,
	allow_root_ring:    bool,
	inputs_read_only:   bool,
	output_store_empty: bool,
	input_count:        u32,
	inputs:             [MAX_RECIPE_INPUTS]Recipe_Input,
	arguments_length:   u32,
	arguments:          [MAX_RECIPE_ARG_BYTES]u8,
}

// Result returned by recipes.build, including provenance and Verify comparison.
Recipe_Build_Result :: struct {
	outcome:               Recipe_Build_Outcome,
	refusal:               Recipe_Refusal,
	recipe_hash:           blake3.Hash,
	output_hash:           blake3.Hash,
	local_output_hash:     blake3.Hash,
	output_kind:           object_cache.Cache_Object_Kind,
	signer_public_key:     [object_cache.PUBLIC_KEY_SIZE]u8,
	verified_reproducible: bool,
}

// Single borders converting transport words into closed enum members.

build_mode_of_word :: proc "contextless" (word: u64) -> (mode: Build_Mode, ok: bool) {
	member := enum_word.member_of_word(Build_Mode, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

recipes_ring_command_of_word :: proc "contextless" (word: u32) -> (command: Recipes_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Recipes_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// build_mode_to_substitution_mode converts a Build_Mode to the matching
// object_cache.Substitution_Mode member.
build_mode_to_substitution_mode :: proc "contextless" (mode: Build_Mode) -> (sub_mode: object_cache.Substitution_Mode, ok: bool) {
	checked, mode_ok := build_mode_of_word(u64(mode))
	if !mode_ok {
		return {}, false
	}
	switch checked {
	case .None:
		return {}, false
	case .Prefer_Cache:
		return .Prefer_Cache, true
	case .Build_Only:
		return .Build_Only, true
	case .Cache_Only:
		return .Cache_Only, true
	case .Verify:
		return .Verify, true
	}
	return {}, false
}

// recipe_input_make constructs a validated Recipe_Input with zero-padded name bytes.
recipe_input_make :: proc "contextless" (name: string, kind: object_cache.Cache_Object_Kind, hash: blake3.Hash) -> (input: Recipe_Input, refusal: Recipe_Refusal) {
	if _, kind_ok := object_cache.cache_object_kind_of_word(u64(kind)); !kind_ok {
		return {}, .Bad_Input_Kind
	}
	if hash_is_zero(hash) {
		return {}, .Zero_Input_Hash
	}
	raw := transmute([]u8)name
	if tree_hash.tree_name_validate(raw) != .None {
		return {}, .Invalid_Input_Name
	}
	copy(input.name_bytes[:len(raw)], raw)
	input.name_length = u8(len(raw))
	input.kind = kind
	input.hash = hash
	return input, .None
}

// recipe_validate checks every field of spec at the border before hashing or
// building. Refuses zero builder hash, invalid output or input kinds, invalid
// or duplicate input names, zero input hashes, oversized arguments, and
// non-zero trailing padding bytes.
recipe_validate :: proc "contextless" (spec: ^Recipe_Spec) -> (refusal: Recipe_Refusal, bad_index: u32) {
	if spec == nil || hash_is_zero(spec.builder_hash) {
		return .Zero_Builder_Hash, 0
	}
	// The zero value of a spec names no kind.
	if _, out_ok := object_cache.cache_object_kind_of_word(u64(spec.output_kind)); !out_ok {
		return .Bad_Output_Kind, 0
	}
	if spec.input_count > MAX_RECIPE_INPUTS {
		return .Too_Many_Inputs, 0
	}
	if spec.arguments_length > MAX_RECIPE_ARG_BYTES {
		return .Arguments_Too_Large, 0
	}
	for pad in spec.arguments[spec.arguments_length:] {
		if pad != 0 {
			return .Nonzero_Padding, 0
		}
	}

	for index in u32(0) ..< spec.input_count {
		input := &spec.inputs[index]
		if int(input.name_length) == 0 || int(input.name_length) > MAX_ENTRY_NAME_BYTES {
			return .Invalid_Input_Name, index
		}
		if tree_hash.tree_name_validate(input.name_bytes[:input.name_length]) != .None {
			return .Invalid_Input_Name, index
		}
		for pad in input.name_bytes[input.name_length:] {
			if pad != 0 {
				return .Nonzero_Padding, index
			}
		}
		if _, kind_ok := object_cache.cache_object_kind_of_word(u64(input.kind)); !kind_ok {
			return .Bad_Input_Kind, index
		}
		if hash_is_zero(input.hash) {
			return .Zero_Input_Hash, index
		}
		for earlier in u32(0) ..< index {
			prev := &spec.inputs[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], input.name_bytes[:input.name_length]) {
				return .Duplicate_Input, index
			}
		}
	}
	return .None, 0
}

@(private = "file")
sort_recipe_input_indices :: proc "contextless" (spec: ^Recipe_Spec, order: ^[MAX_RECIPE_INPUTS]u32) {
	for index in u32(0) ..< spec.input_count {
		order[index] = index
	}
	for i in u32(1) ..< spec.input_count {
		key_index := order[i]
		key_name := spec.inputs[key_index].name_bytes[:spec.inputs[key_index].name_length]
		j := int(i) - 1
		for j >= 0 {
			cur := &spec.inputs[order[j]]
			if compare_bytes(cur.name_bytes[:cur.name_length], key_name) <= 0 {
				break
			}
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key_index
	}
}

// recipe_hash validates spec and computes its canonical, input-order-independent
// domain-separated BLAKE3 digest under RECIPE_HASH_DOMAIN ("modus recipe v1").
// The canonical bytes go to the incremental hash in the order of their
// form, so no buffer holds them whole: the builder hash, the output kind,
// the source date and the output block limit, then the count and each input
// in the order of its name (its name with a length of 4 bytes, its kind,
// its hash), then the arguments with a length of 4 bytes. Each number is
// little endian.
recipe_hash :: proc "contextless" (spec: ^Recipe_Spec) -> (digest: blake3.Hash, refusal: Recipe_Refusal) {
	validation_refusal, _ := recipe_validate(spec)
	if validation_refusal != .None {
		return {}, validation_refusal
	}

	order: [MAX_RECIPE_INPUTS]u32
	sort_recipe_input_indices(spec, &order)

	hasher := blake3.hasher_make_derive_key(RECIPE_HASH_DOMAIN)
	blake3.hasher_update(&hasher, spec.builder_hash[:])
	hash_byte(&hasher, u8(spec.output_kind))
	hash_u64(&hasher, spec.source_date_unix)
	hash_u64(&hasher, spec.output_block_limit)
	hash_u32(&hasher, spec.input_count)
	for pos in u32(0) ..< spec.input_count {
		input := &spec.inputs[order[pos]]
		hash_u32(&hasher, u32(input.name_length))
		blake3.hasher_update(&hasher, input.name_bytes[:input.name_length])
		hash_byte(&hasher, u8(input.kind))
		blake3.hasher_update(&hasher, input.hash[:])
	}
	hash_u32(&hasher, spec.arguments_length)
	blake3.hasher_update(&hasher, spec.arguments[:spec.arguments_length])
	return blake3.hasher_finish(&hasher), .None
}

@(private = "file")
hash_byte :: proc "contextless" (hasher: ^blake3.Hasher, value: u8) {
	bytes := [1]u8{value}
	blake3.hasher_update(hasher, bytes[:])
}

@(private = "file")
hash_u32 :: proc "contextless" (hasher: ^blake3.Hasher, value: u32) {
	bytes := transmute([4]u8)u32le(value)
	blake3.hasher_update(hasher, bytes[:])
}

@(private = "file")
hash_u64 :: proc "contextless" (hasher: ^blake3.Hasher, value: u64) {
	bytes := transmute([8]u8)u64le(value)
	blake3.hasher_update(hasher, bytes[:])
}

// The bytes of the canonical form of the largest recipe, which recipe_hash
// hashes: its head, each input with the longest name, and the largest
// arguments.
MAX_RECIPE_CANONICAL_BYTES :: blake3.HASH_SIZE + 1 + 8 + 8 + 4 + MAX_RECIPE_INPUTS * (4 + MAX_ENTRY_NAME_BYTES + 1 + blake3.HASH_SIZE) + 4 + MAX_RECIPE_ARG_BYTES

// The magic of a recipe object: a blob that holds a recipe
// (src/md/infrastructure/cache_browser.md, "A realisation and its recipe").
RECIPE_OBJECT_MAGIC :: [8]u8{'M', 'O', 'D', 'R', 'C', 'P', '0', '1'}

// The largest recipe object: the magic and the largest canonical bytes.
MAX_RECIPE_OBJECT_BYTES :: len(RECIPE_OBJECT_MAGIC) + MAX_RECIPE_CANONICAL_BYTES

// recipe_canonical_size gives the bytes of the canonical form of a valid
// spec.
@(private = "file")
recipe_canonical_size :: proc "contextless" (spec: ^Recipe_Spec) -> int {
	size := blake3.HASH_SIZE + 1 + 8 + 8 + 4
	for index in 0 ..< int(spec.input_count) {
		size += 4 + int(spec.inputs[index].name_length) + 1 + blake3.HASH_SIZE
	}
	return size + 4 + int(spec.arguments_length)
}

// recipe_object_encode writes the recipe object of spec: the magic, then
// the canonical bytes over which recipe_hash is computed. So the recipe
// hash of an object is computed from the object alone.
recipe_object_encode :: proc "contextless" (spec: ^Recipe_Spec, output: []u8) -> (written: int, refusal: Recipe_Refusal) {
	validation_refusal, _ := recipe_validate(spec)
	if validation_refusal != .None {
		return 0, validation_refusal
	}
	magic := RECIPE_OBJECT_MAGIC
	// The size is known before the first byte, so a refused call writes no
	// byte of output, and no copy of the canonical bytes takes the stack.
	size := len(magic) + recipe_canonical_size(spec)
	if len(output) < size {
		return 0, .Buffer_Too_Small
	}
	order: [MAX_RECIPE_INPUTS]u32
	sort_recipe_input_indices(spec, &order)
	copy(output[:len(magic)], magic[:])
	encoder := Canonical_Encoder{buffer = output[len(magic):size]}
	encoder_raw_bytes(&encoder, spec.builder_hash[:])
	encoder_byte(&encoder, u8(spec.output_kind))
	encoder_u64(&encoder, spec.source_date_unix)
	encoder_u64(&encoder, spec.output_block_limit)
	encoder_u32(&encoder, spec.input_count)
	for pos in u32(0) ..< spec.input_count {
		input := &spec.inputs[order[pos]]
		encoder_bytes(&encoder, input.name_bytes[:input.name_length])
		encoder_byte(&encoder, u8(input.kind))
		encoder_raw_bytes(&encoder, input.hash[:])
	}
	encoder_bytes(&encoder, spec.arguments[:spec.arguments_length])
	if encoder.overflow || encoder.position != size - len(magic) {
		return 0, .Buffer_Too_Small
	}
	return size, .None
}

// recipe_object_decode reads a recipe object into spec and gives its recipe
// hash. It refuses bytes with no magic, a field past its bound, an input
// kind or an output kind that names no kind, bytes after the arguments, and
// bytes that are not the canonical form: the inputs out of the order of
// their names. So one recipe has one object.
recipe_object_decode :: proc "contextless" (input: []u8, spec: ^Recipe_Spec) -> (digest: blake3.Hash, refusal: Recipe_Refusal) {
	magic := RECIPE_OBJECT_MAGIC
	if spec == nil || len(input) < len(magic) || len(input) > MAX_RECIPE_OBJECT_BYTES {
		return {}, .Damaged_Recipe
	}
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Damaged_Recipe
		}
	}
	canonical := input[len(magic):]
	spec^ = {}
	position := 0
	take :: proc "contextless" (canonical: []u8, position: ^int, count: int) -> (bytes: []u8, ok: bool) {
		if count < 0 || len(canonical) - position^ < count {
			return nil, false
		}
		bytes = canonical[position^:position^ + count]
		position^ += count
		return bytes, true
	}
	builder, builder_ok := take(canonical, &position, blake3.HASH_SIZE)
	if !builder_ok {
		return {}, .Damaged_Recipe
	}
	copy(spec.builder_hash[:], builder)
	head, head_ok := take(canonical, &position, 1 + 8 + 8 + 4)
	if !head_ok {
		return {}, .Damaged_Recipe
	}
	output_kind, output_kind_ok := object_cache.cache_object_kind_of_word(u64(head[0]))
	if !output_kind_ok {
		return {}, .Bad_Output_Kind
	}
	spec.output_kind = output_kind
	spec.source_date_unix = byte_order.read_u64_little_endian(head, 1)
	spec.output_block_limit = byte_order.read_u64_little_endian(head, 9)
	input_count := byte_order.read_u32_little_endian(head, 17)
	if input_count > MAX_RECIPE_INPUTS {
		return {}, .Too_Many_Inputs
	}
	spec.input_count = input_count
	for index in 0 ..< int(input_count) {
		length_bytes, length_ok := take(canonical, &position, 4)
		if !length_ok {
			return {}, .Damaged_Recipe
		}
		name_length := byte_order.read_u32_little_endian(length_bytes, 0)
		if name_length == 0 || name_length > MAX_ENTRY_NAME_BYTES {
			return {}, .Invalid_Input_Name
		}
		name, name_ok := take(canonical, &position, int(name_length))
		kind_and_hash, rest_ok := take(canonical, &position, 1 + blake3.HASH_SIZE)
		if !name_ok || !rest_ok {
			return {}, .Damaged_Recipe
		}
		input_kind, input_kind_ok := object_cache.cache_object_kind_of_word(u64(kind_and_hash[0]))
		if !input_kind_ok {
			return {}, .Bad_Input_Kind
		}
		item := &spec.inputs[index]
		copy(item.name_bytes[:], name)
		item.name_length = u8(name_length)
		item.kind = input_kind
		copy(item.hash[:], kind_and_hash[1:])
	}
	arguments_length_bytes, arguments_length_ok := take(canonical, &position, 4)
	if !arguments_length_ok {
		return {}, .Damaged_Recipe
	}
	arguments_length := byte_order.read_u32_little_endian(arguments_length_bytes, 0)
	if arguments_length > MAX_RECIPE_ARG_BYTES {
		return {}, .Arguments_Too_Large
	}
	arguments, arguments_ok := take(canonical, &position, int(arguments_length))
	if !arguments_ok || position != len(canonical) {
		return {}, .Damaged_Recipe
	}
	copy(spec.arguments[:], arguments)
	spec.arguments_length = arguments_length
	// The inputs must be in the order of their names: inputs in another
	// order give the same recipe hash and are not its object.
	if validation, _ := recipe_validate(spec); validation != .None {
		return {}, validation
	}
	for index in 1 ..< int(input_count) {
		previous := &spec.inputs[index - 1]
		current := &spec.inputs[index]
		if compare_bytes(previous.name_bytes[:previous.name_length], current.name_bytes[:current.name_length]) >= 0 {
			return {}, .Damaged_Recipe
		}
	}
	return blake3.derive_key(RECIPE_HASH_DOMAIN, canonical), .None
}

// builder_sandbox_prepare derives the deterministic, zero-network sandbox
// configuration for executing a validated Recipe_Spec into sandbox, which
// the caller holds: a sandbox of the largest bounds is about 90 KiB, too
// large for a value on a stack. On a refusal sandbox is zero.
builder_sandbox_prepare :: proc "contextless" (spec: ^Recipe_Spec, sandbox: ^Builder_Sandbox_Spec) -> Recipe_Refusal {
	if sandbox == nil {
		return .Buffer_Too_Small
	}
	intrinsics.mem_zero(sandbox, size_of(Builder_Sandbox_Spec))
	rhash, hash_refusal := recipe_hash(spec)
	if hash_refusal != .None {
		return hash_refusal
	}
	order: [MAX_RECIPE_INPUTS]u32
	sort_recipe_input_indices(spec, &order)

	sandbox.recipe_hash = rhash
	sandbox.builder_hash = spec.builder_hash
	sandbox.output_kind = spec.output_kind
	sandbox.random_seed = rhash
	sandbox.frozen_date_unix = spec.source_date_unix
	sandbox.output_block_limit = spec.output_block_limit
	sandbox.allow_network = false
	sandbox.allow_root_ring = false
	sandbox.inputs_read_only = true
	sandbox.output_store_empty = true
	sandbox.input_count = spec.input_count
	sandbox.arguments_length = spec.arguments_length
	for pos in u32(0) ..< spec.input_count {
		sandbox.inputs[pos] = spec.inputs[order[pos]]
	}
	if spec.arguments_length > 0 {
		copy(sandbox.arguments[:spec.arguments_length], spec.arguments[:spec.arguments_length])
	}
	return .None
}

// builder_sandbox_validate verifies every sandbox isolation invariant before
// starting a builder process: read-only inputs, empty output store, zero
// network, no root ring, and deterministic seed equal to recipe_hash.
builder_sandbox_validate :: proc "contextless" (sandbox: ^Builder_Sandbox_Spec) -> Recipe_Refusal {
	if sandbox == nil || hash_is_zero(sandbox.recipe_hash) || hash_is_zero(sandbox.builder_hash) {
		return .Sandbox_Violation
	}
	if sandbox.allow_network || sandbox.allow_root_ring || !sandbox.inputs_read_only || !sandbox.output_store_empty {
		return .Sandbox_Violation
	}
	if sandbox.random_seed != sandbox.recipe_hash {
		return .Sandbox_Violation
	}
	if _, out_ok := object_cache.cache_object_kind_of_word(u64(sandbox.output_kind)); !out_ok {
		return .Bad_Output_Kind
	}
	if sandbox.input_count > MAX_RECIPE_INPUTS || sandbox.arguments_length > MAX_RECIPE_ARG_BYTES {
		return .Sandbox_Violation
	}
	return .None
}

// recipe_verify_cache_realisation strictly verifies a remote cache realisation
// and its payload bytes against spec and policy using object_cache.substitution_check.
// Refuses untrusted signers, invalid signatures, wrong recipe hash, mismatched
// output kind, malformed trees, or any single tampered byte in payload.
recipe_verify_cache_realisation :: proc "contextless" (
	spec: ^Recipe_Spec,
	policy: object_cache.Substitution_Policy,
	realisation: ^object_cache.Realisation_Record,
	payload: []u8,
	verify_signature: object_cache.Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> (output_hash: blake3.Hash, refusal: Recipe_Refusal) {
	if realisation == nil {
		return {}, .Malformed_Output
	}
	rhash, hash_refusal := recipe_hash(spec)
	if hash_refusal != .None {
		return {}, hash_refusal
	}
	if realisation.output_kind != spec.output_kind {
		return {}, .Malformed_Output
	}

	realisation_decision := object_cache.substitution_check(
		policy,
		object_cache.Substitution_Realisation_Subject{expected_recipe_hash = rhash, realisation = realisation^},
		verify_signature,
		user_data,
	)
	switch realisation_decision {
	case .Trust_By_Signer:
		// Signature and trusted signer verified.
	case .Refuse_Untrusted_Signer:
		return {}, .Untrusted_Realisation
	case .Refuse_Bad_Signature:
		return {}, .Bad_Signature
	case .Refuse_Hash_Mismatch:
		return {}, .Hash_Mismatch
	case .Refuse_Malformed, .Trust_By_Hash:
		return {}, .Malformed_Output
	}

	object_decision := object_cache.substitution_check(
		policy,
		object_cache.Substitution_Object_Subject{
			expected_hash = realisation.output_hash,
			object_kind   = realisation.output_kind,
			payload       = payload,
		},
	)
	switch object_decision {
	case .Trust_By_Hash:
		return realisation.output_hash, .None
	case .Refuse_Hash_Mismatch:
		return {}, .Hash_Mismatch
	case .Refuse_Malformed, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature, .Trust_By_Signer:
		return {}, .Malformed_Output
	}
	return {}, .Malformed_Output
}

// The bytes of the output of a recipe that the recipes service keeps and
// gives: one object of a cache, as a realisation is shared through a
// cache. The protocol of the cache carries an object of any size up to
// this bound in frames of 1 MiB checked against its BLAKE3 root
// (src/md/features/recipes.md, "The local store").
RECIPE_OUTPUT_BYTES_MOST :: object_cache.MAX_OBJECT_BYTES

// recipe_hash_output computes the content-addressed digest of a builder's
// output bytes according to output_kind (domain-separated tree_hash for Tree,
// plain BLAKE3 for Blob).
recipe_hash_output :: proc "contextless" (output_kind: object_cache.Cache_Object_Kind, payload: []u8) -> (output_hash: blake3.Hash, refusal: Recipe_Refusal) {
	checked_kind, kind_ok := object_cache.cache_object_kind_of_word(u64(output_kind))
	if !kind_ok {
		return {}, .Bad_Output_Kind
	}
	switch checked_kind {
	case .Blob:
		if u64(len(payload)) > object_cache.MAX_OBJECT_BYTES {
			return {}, .Malformed_Output
		}
		return blake3.hash(payload), .None
	case .Tree:
		digest, tree_refusal := tree_hash.tree_hash(payload)
		if tree_refusal != .None {
			return {}, .Malformed_Output
		}
		return digest, .None
	}
	return {}, .Bad_Output_Kind
}
