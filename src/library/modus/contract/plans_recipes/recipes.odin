// Recipes and sandboxed builder contract: canonical recipe specifications,
// domain-separated BLAKE3 recipe hashing, substitution policy verification,
// sandbox configuration, and build results (src/md/features/recipes.md).
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package plans_recipes

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/object_cache"
import "modus:contract/tree_hash"

// Domain separation context string passed to blake3.derive_key so recipe
// hashes are cryptographically separated from objects, trees, and plans.
RECIPE_HASH_DOMAIN :: "modus recipe v1"

// Structural bounds on recipes and deterministic builder arguments.
MAX_RECIPE_INPUTS :: 32
MAX_RECIPE_ARG_BYTES :: 4096
MAX_RECIPE_CANONICAL_BYTES :: 8192

// Context slots for the delegated recipes service.
RECIPES_SERVICE_RING_SLOT :: 10
RECIPES_SERVICE_REGION_SLOT :: 11

// Closed set of recipe build modes (maps directly to object_cache.Substitution_Mode).
// Zero means unset and is refused at the border.
Build_Mode :: enum u8 {
	None        = 0,
	Cache_First = 1,
	Build_Only  = 2,
	Cache_Only  = 3,
	Verify      = 4,
}

// Closed set of build result classifications returned by recipes.build.
Recipe_Build_Outcome :: enum u8 {
	None          = 0,
	From_Cache    = 1,
	Built_Locally = 2,
	Refused       = 3,
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
	Output_Too_Large      = 32, // The output passes the size bound of the recipe.
	Build_Timed_Out       = 33, // The builder reached its hang bound.
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
	.Output_Too_Large      = "the output passes the size bound of the recipe",
	.Build_Timed_Out       = "the builder reached its hang bound",
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
	case .Cache_First:
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
recipe_hash :: proc "contextless" (spec: ^Recipe_Spec) -> (digest: blake3.Hash, refusal: Recipe_Refusal) {
	validation_refusal, _ := recipe_validate(spec)
	if validation_refusal != .None {
		return {}, validation_refusal
	}

	order: [MAX_RECIPE_INPUTS]u32
	sort_recipe_input_indices(spec, &order)

	canonical_buffer: [MAX_RECIPE_CANONICAL_BYTES]u8
	encoder := Canonical_Encoder{buffer = canonical_buffer[:]}
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
	if encoder.overflow {
		return {}, .Buffer_Too_Small
	}
	return blake3.derive_key(RECIPE_HASH_DOMAIN, canonical_buffer[:encoder.position]), .None
}

// builder_sandbox_prepare derives the deterministic, zero-network sandbox
// configuration for executing a validated Recipe_Spec.
builder_sandbox_prepare :: proc "contextless" (spec: ^Recipe_Spec) -> (sandbox: Builder_Sandbox_Spec, refusal: Recipe_Refusal) {
	rhash, hash_refusal := recipe_hash(spec)
	if hash_refusal != .None {
		return {}, hash_refusal
	}
	order: [MAX_RECIPE_INPUTS]u32
	sort_recipe_input_indices(spec, &order)

	sandbox = {
		recipe_hash        = rhash,
		builder_hash       = spec.builder_hash,
		output_kind        = spec.output_kind,
		random_seed        = rhash,
		frozen_date_unix   = spec.source_date_unix,
		output_block_limit = spec.output_block_limit,
		allow_network      = false,
		allow_root_ring    = false,
		inputs_read_only   = true,
		output_store_empty = true,
		input_count        = spec.input_count,
		arguments_length   = spec.arguments_length,
	}
	for pos in u32(0) ..< spec.input_count {
		sandbox.inputs[pos] = spec.inputs[order[pos]]
	}
	if spec.arguments_length > 0 {
		copy(sandbox.arguments[:spec.arguments_length], spec.arguments[:spec.arguments_length])
	}
	return sandbox, .None
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
		if len(payload) > object_cache.MAX_OBJECT_PAYLOAD_BYTES {
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
