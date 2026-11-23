// The distributed builder: a recipe graph realised across the paired
// machines of a principal (src/md/features/recipes.md, "Builds across
// paired machines").
//
// The scheduler takes a graph of at most DAG_RECIPE_CAPACITY recipes, in an
// order where each recipe names only earlier recipes as the producers of its
// inputs, and a pool of paired machines: builders and caches. It realises
// the graph in rounds. A round takes each recipe whose producers are done,
// fills each input that a producer gives with the output hash of that
// producer, after it computed that hash again over the kept bytes, and
// realises the recipe by the mode:
//
// - Cache_First: the local store, then each cache, then a builder, then a
//   build on this machine.
// - Cache_Only: the local store, then each cache; a miss is refused.
// - Build_Only: a build on this machine only: no realisation of another
//   machine is used.
// - Verify: two independent machines build the recipe (two builders, or a
//   builder and this machine); two output hashes are Determinism_Mismatch.
//
// Each realisation that another machine gives is checked before any byte is
// kept: its recipe hash, its output kind, a signer that the policy trusts
// and its Ed25519 signature; then the bytes of the output, whose BLAKE3 hash
// or tree hash must be the output hash of the realisation.
//
// A link that breaks during a call gives Unknown_Outcome: the build can have
// run. A build is a function of its recipe, so the scheduler sends it to the
// next builder, or builds it on this machine, and the builder of the lost
// link takes no more work in this run. A builder that refuses the call (no
// grant of the use, no role) leaves the pool the same way.
//
// The calls go through machine_wire.Mesh_Transport, a transport that
// answers at once: the round gives each ready recipe to a distinct builder
// in turn, and runs the calls one after the other.
//
// This file allocates no memory and calls no kernel operation.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"

DAG_RECIPE_CAPACITY :: 32
DISTRIBUTED_PEER_CAPACITY :: 4
// The bytes of one output at most: an object that one mesh frame carries.
DISTRIBUTED_OUTPUT_LIMIT :: machine_wire.OBJECT_BYTES_LIMIT
// The arguments of a remote build: the head, then each input, then the
// argument record of the recipe.
REMOTE_BUILD_HEADER_SIZE :: blake3.HASH_SIZE + 8 + 8 + 4 + 4 + 4 + 4
REMOTE_BUILD_INPUT_HEADER_SIZE :: 4 + blake3.HASH_SIZE // The name length, the kind, two zero bytes, the hash; the name follows.

// The role whose holder builds and gives realisations for paired machines.
REMOTE_RECIPES_ROLE :: role_contract.Role.Recipes

// The exports of the role Recipes that a paired machine calls.
Remote_Recipes_Export :: enum u32 {
	None               = 0,
	Realisation_Lookup = 1, // The arguments: a recipe hash. The result: the realisation record of the local store.
	Build              = 2, // The arguments: a recipe (remote_build_arguments_write). The result: the realisation record of the build.
}

remote_recipes_export_of_word :: proc "contextless" (word: u32) -> (export: Remote_Recipes_Export, ok: bool) {
	export, ok = enum_word.member_of_word(Remote_Recipes_Export, u64(word))
	if !ok || export == .None {
		return .None, false
	}
	return export, true
}

// Why the scheduler refused a graph, a pool, or one recipe.
Distributed_Refusal :: enum u8 {
	None                       = 0,
	Graph_Full                 = 1, // DAG_RECIPE_CAPACITY recipes are in the graph.
	Producer_Not_Earlier       = 2, // A dependency names this recipe or a later one: the graph must be in order, so it has no cycle.
	Bad_Dependency_Input       = 3, // A dependency names an input past the count, names one input twice, or its kind is not the output kind of its producer.
	Bad_Recipe                 = 4, // The recipe is refused by its validation.
	Pool_Full                  = 5, // DISTRIBUTED_PEER_CAPACITY machines are in the pool.
	Bad_Peer                   = 6, // A zero key, this machine, a key twice, or no purpose.
	Peer_Not_Paired            = 7, // The key has no row of the paired machines.
	Peer_Lacks_Use             = 8, // The plan gives this machine neither the use Roles nor the use Objects of that machine.
	Cache_Miss                 = 9, // Cache_Only, and no source holds the recipe.
	Hash_Mismatch              = 10, // The bytes of an output do not hash to its output hash.
	Untrusted_Realisation      = 11, // The signer of a realisation is not a key of the policy.
	Bad_Signature              = 12, // The signature of a realisation does not verify.
	Malformed_Realisation      = 13, // A realisation that does not decode, or that names another output kind.
	Wrong_Recipe               = 14, // A realisation of another recipe.
	Output_Absent              = 15, // A machine gave a realisation, and not the bytes of its output.
	Output_Too_Large           = 16, // An output over DISTRIBUTED_OUTPUT_LIMIT.
	Determinism_Mismatch       = 17, // Two machines built the recipe, and their output hashes differ.
	No_Builder                 = 18, // No builder took the recipe, and this machine builds nothing.
	Local_Build_Failed         = 19, // The builder of this machine failed, or its sandbox was refused.
	Verify_Needs_Two_Machines  = 20, // Verify, and fewer than two machines could build the recipe.
	Dependency_Failed          = 21, // A producer of an input was refused.
	Bad_Mode                   = 22, // The mode None, or a word that names no mode.
}

// What a machine of the pool is for this run.
Distributed_Peer_Purpose :: enum u8 {
	None    = 0,
	Builder = 1, // Builds a recipe that it receives: the export Build.
	Cache   = 2, // Gives the realisations that it holds: the export Realisation_Lookup.
}

// One machine of the pool: its identity key, and the uses of that machine
// that the plan of the principal gives this machine.
Distributed_Peer :: struct {
	identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	purpose:  Distributed_Peer_Purpose,
	uses:     machine_wire.Machine_Uses,
}

// Where the kept output of a recipe came from.
Distributed_Source :: enum u8 {
	None           = 0,
	Local_Store    = 1,
	Cache_Peer     = 2,
	Remote_Builder = 3,
	Local_Build    = 4,
}

Dag_Phase :: enum u8 {
	Waiting = 0,
	Done    = 1,
	Failed  = 2,
}

// An input of a recipe that an earlier recipe of the graph gives.
Dag_Dependency :: struct {
	producer:    u32, // The index of the producer in the graph: lower than the index of this recipe.
	input_index: u32, // The input of this recipe that takes the output hash of the producer.
}

Dag_Recipe :: struct {
	spec:             pr.Recipe_Spec,
	dependency_count: u32,
	dependencies:     [pr.MAX_RECIPE_INPUTS]Dag_Dependency,
}

// The end of one recipe of the graph.
Dag_Result :: struct {
	phase:              Dag_Phase,
	source:             Distributed_Source,
	refusal:            Distributed_Refusal,
	recipe_hash:        blake3.Hash,
	output_hash:        blake3.Hash,
	output_kind:        object_cache.Cache_Object_Kind,
	output_length:      int,
	machine:            [machine_mesh.PUBLIC_KEY_SIZE]u8, // The machine whose output was kept: a builder, a cache, or this machine.
	second_machine:     [machine_mesh.PUBLIC_KEY_SIZE]u8, // Verify: the second machine that built it.
	second_output_hash: blake3.Hash, // Verify: the output hash of the second machine.
	round:              u32, // The round in which the recipe was realised or refused.
	failovers:          u32, // The builders that this recipe left after a lost link or a refusal.
}

// The rule of one run.
Distributed_Policy :: struct {
	mode:             pr.Build_Mode,
	trusted_signers:  [][object_cache.PUBLIC_KEY_SIZE]u8,
	verify_signature: object_cache.Signature_Verify_Proc,
	// The local store: nil when this run reads none. It is the store of this
	// machine, so its realisation needs no signer; it is still checked: its
	// recipe hash, its output kind, and the hash of its output bytes, before
	// any byte is kept. A local_lookup must read only the store of this
	// machine, never a source of another machine: such a source goes in the
	// pool as a cache, whose realisations need a trusted signer.
	local_lookup:     Cache_Lookup_Proc,
	// The builder of this machine in its sandbox: nil when this machine
	// builds nothing.
	local_builder:    Builder_Invoke_Proc,
	transport:        ^machine_wire.Mesh_Transport,
	bound_ms:         u64, // The bound of each handshake and of each call.
	user_data:        rawptr,
}

Distributed_Counters :: struct {
	rounds:                 u64,
	local_store_hits:       u64,
	cache_hits:             u64,
	cache_untrusted_skips:  u64, // Cache_First: a realisation of a signer that the policy does not trust, passed over.
	cache_faults:           u64, // A cache gave a bad realisation or withheld its output: it left the run.
	remote_builds:          u64,
	local_builds:           u64,
	links_lost:             u64, // Calls that ended Unknown_Outcome or Unreachable.
	builders_refused:       u64, // Calls that the machine refused: no grant of the use, or no role.
	failovers:              u64,
	verify_agreements:      u64,
	determinism_mismatches: u64,
}

// The whole state of one run: in memory of the caller, never a stack.
Distributed_Builder :: struct {
	own_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	recipes:      [DAG_RECIPE_CAPACITY]Dag_Recipe,
	recipe_count: int,
	results:      [DAG_RECIPE_CAPACITY]Dag_Result,
	outputs:      [DAG_RECIPE_CAPACITY][DISTRIBUTED_OUTPUT_LIMIT]u8,
	peers:        [DISTRIBUTED_PEER_CAPACITY]Distributed_Peer,
	peer_count:   int,
	links:        [DISTRIBUTED_PEER_CAPACITY]machine_wire.Mesh_Link,
	peer_out:     [DISTRIBUTED_PEER_CAPACITY]bool, // The machine lost its link or refused a call: it takes no more work in this run.
	cursor:       int, // The next builder of the turn.
	counters:     Distributed_Counters,
	request:      [machine_wire.FRAME_LIMIT]u8,
	answer:       [machine_wire.FRAME_LIMIT]u8,
	arguments:    [machine_wire.ROLE_ARGUMENT_LIMIT]u8,
	staging:      [DISTRIBUTED_OUTPUT_LIMIT]u8,
}

// ---- The arguments of a remote build ----

// remote_build_arguments_write writes a recipe as the arguments of the
// export Build. A recipe that does not fit the arguments of one role call
// is refused with Arguments_Too_Large: it is built on this machine.
remote_build_arguments_write :: proc "contextless" (spec: ^pr.Recipe_Spec, output: []u8) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
	if validation, _ := pr.recipe_validate(spec); validation != .None {
		return nil, validation
	}
	size := REMOTE_BUILD_HEADER_SIZE + int(spec.arguments_length)
	for index in 0 ..< spec.input_count {
		size += REMOTE_BUILD_INPUT_HEADER_SIZE + int(spec.inputs[index].name_length)
	}
	if size > len(output) {
		return nil, .Arguments_Too_Large
	}
	bytes = output[:size]
	for &value in bytes {
		value = 0
	}
	copy(bytes[0:32], spec.builder_hash[:])
	byte_order.write_u64_little_endian(bytes, 32, spec.source_date_unix)
	byte_order.write_u64_little_endian(bytes, 40, spec.output_block_limit)
	byte_order.write_u32_little_endian(bytes, 48, u32(spec.output_kind))
	byte_order.write_u32_little_endian(bytes, 52, spec.input_count)
	byte_order.write_u32_little_endian(bytes, 56, spec.arguments_length)
	offset := REMOTE_BUILD_HEADER_SIZE
	for index in 0 ..< spec.input_count {
		input := &spec.inputs[index]
		bytes[offset] = input.name_length
		bytes[offset + 1] = u8(input.kind)
		copy(bytes[offset + 4:][:blake3.HASH_SIZE], input.hash[:])
		offset += REMOTE_BUILD_INPUT_HEADER_SIZE
		copy(bytes[offset:][:input.name_length], input.name_bytes[:input.name_length])
		offset += int(input.name_length)
	}
	copy(bytes[offset:], spec.arguments[:spec.arguments_length])
	return bytes, .None
}

// remote_build_arguments_read is the border of the arguments of the export
// Build on the machine of the builder: each count is checked against its
// bound and against the bytes, each reserved byte must be zero, and the
// recipe must pass its validation.
remote_build_arguments_read :: proc "contextless" (bytes: []u8, spec: ^pr.Recipe_Spec) -> pr.Recipe_Refusal {
	if spec == nil || len(bytes) < REMOTE_BUILD_HEADER_SIZE {
		return .Malformed_Output
	}
	spec^ = {}
	copy(spec.builder_hash[:], bytes[0:32])
	spec.source_date_unix = byte_order.read_u64_little_endian(bytes, 32)
	spec.output_block_limit = byte_order.read_u64_little_endian(bytes, 40)
	output_kind, output_kind_ok := object_cache.cache_object_kind_of_word(u64(byte_order.read_u32_little_endian(bytes, 48)))
	if !output_kind_ok {
		spec^ = {}
		return .Bad_Output_Kind
	}
	spec.output_kind = output_kind
	input_count := byte_order.read_u32_little_endian(bytes, 52)
	arguments_length := byte_order.read_u32_little_endian(bytes, 56)
	if byte_order.read_u32_little_endian(bytes, 60) != 0 {
		return .Nonzero_Padding
	}
	if input_count > pr.MAX_RECIPE_INPUTS {
		return .Too_Many_Inputs
	}
	if arguments_length > pr.MAX_RECIPE_ARG_BYTES {
		return .Arguments_Too_Large
	}
	offset := REMOTE_BUILD_HEADER_SIZE
	for index in 0 ..< input_count {
		if len(bytes) - offset < REMOTE_BUILD_INPUT_HEADER_SIZE {
			return .Malformed_Output
		}
		name_length := int(bytes[offset])
		if bytes[offset + 2] != 0 || bytes[offset + 3] != 0 {
			return .Nonzero_Padding
		}
		if name_length == 0 || name_length > pr.MAX_ENTRY_NAME_BYTES {
			return .Invalid_Input_Name
		}
		input_kind, input_kind_ok := object_cache.cache_object_kind_of_word(u64(bytes[offset + 1]))
		if !input_kind_ok {
			spec^ = {}
			return .Bad_Input_Kind
		}
		input := &spec.inputs[index]
		input.kind = input_kind
		copy(input.hash[:], bytes[offset + 4:][:blake3.HASH_SIZE])
		offset += REMOTE_BUILD_INPUT_HEADER_SIZE
		if len(bytes) - offset < name_length {
			return .Malformed_Output
		}
		copy(input.name_bytes[:], bytes[offset:][:name_length])
		input.name_length = u8(name_length)
		offset += name_length
	}
	spec.input_count = input_count
	if len(bytes) - offset != int(arguments_length) {
		return .Malformed_Output
	}
	copy(spec.arguments[:], bytes[offset:])
	spec.arguments_length = arguments_length
	refusal, _ := pr.recipe_validate(spec)
	return refusal
}

// ---- The holder of the role Recipes on a builder or a cache ----

// Keeps the bytes of an output where the paired machines fetch it by hash
// (machine_wire.object_publish on the machine of the builder).
Object_Publish_Proc :: #type proc "contextless" (kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, bytes: []u8, user_data: rawptr) -> bool

// What a machine gives the role Recipes for the calls of its paired
// machines. A machine with no builder refuses Build; a machine with no
// lookup refuses Realisation_Lookup.
Remote_Recipes_Host :: struct {
	builder_invoke:   Builder_Invoke_Proc,
	sign_realisation: Sign_Realisation_Proc,
	lookup:           Cache_Lookup_Proc,
	publish:          Object_Publish_Proc,
	user_data:        rawptr,
	spec:             pr.Recipe_Spec,
	sandbox:          pr.Builder_Sandbox_Spec, // The sandbox of the build that runs: too large for the stack.
	staging:          [DISTRIBUTED_OUTPUT_LIMIT]u8,
}

// remote_recipes_serve answers one call of the role Recipes from a paired
// machine, as the role holder of machine_wire.Peer_Services calls it. The
// result is the wire of a realisation record; Refused says that nothing
// ran or that the store holds no such realisation.
remote_recipes_serve :: proc "contextless" (host: ^Remote_Recipes_Host, export_word: u32, arguments: []u8, result: []u8) -> (value: i64, result_count: int, outcome: machine_wire.Role_Outcome) {
	export, known := remote_recipes_export_of_word(export_word)
	if host == nil || !known || len(result) < object_cache.REALISATION_WIRE_SIZE {
		return 0, 0, .Refused
	}
	record: object_cache.Realisation_Record
	switch export {
	case .None:
		return 0, 0, .Refused
	case .Realisation_Lookup:
		if host.lookup == nil || len(arguments) != blake3.HASH_SIZE {
			return 0, 0, .Refused
		}
		recipe_hash: blake3.Hash
		copy(recipe_hash[:], arguments)
		count, found := host.lookup(recipe_hash, &record, host.staging[:], host.user_data)
		if !found || count < 0 || count > len(host.staging) || record.recipe_hash != recipe_hash {
			return 0, 0, .Refused
		}
		if host.publish != nil && !host.publish(record.output_kind, record.output_hash, host.staging[:count], host.user_data) {
			return 0, 0, .Refused
		}
	case .Build:
		if host.builder_invoke == nil || host.sign_realisation == nil || remote_build_arguments_read(arguments, &host.spec) != .None {
			return 0, 0, .Refused
		}
		sandbox_refusal := pr.builder_sandbox_prepare(&host.spec, &host.sandbox)
		if sandbox_refusal != .None || pr.builder_sandbox_validate(&host.sandbox) != .None {
			return 0, 0, .Refused
		}
		sandbox := &host.sandbox
		count, built := host.builder_invoke(sandbox, host.staging[:], host.user_data)
		if !built || count < 0 || count > len(host.staging) {
			return 0, 0, .Refused
		}
		output_hash, hash_refusal := pr.recipe_hash_output(sandbox.output_kind, host.staging[:count])
		if hash_refusal != .None {
			return 0, 0, .Refused
		}
		record = object_cache.Realisation_Record{recipe_hash = sandbox.recipe_hash, output_hash = output_hash, output_kind = sandbox.output_kind}
		signing_bytes, signing_ok := object_cache.realisation_signing_bytes(&record)
		if !signing_ok || !host.sign_realisation(signing_bytes[:], &record.signer_public_key, &record.signature, host.user_data) {
			return 0, 0, .Refused
		}
		// The signing bytes name the signer: sign again over the key that
		// the signer gave, so the record verifies.
		signing_bytes, signing_ok = object_cache.realisation_signing_bytes(&record)
		if !signing_ok || !host.sign_realisation(signing_bytes[:], &record.signer_public_key, &record.signature, host.user_data) {
			return 0, 0, .Refused
		}
		if host.publish == nil || !host.publish(record.output_kind, output_hash, host.staging[:count], host.user_data) {
			return 0, 0, .Refused
		}
	}
	written, wire_refusal := object_cache.encode_realisation_record(&record, result)
	if wire_refusal != .None {
		return 0, 0, .Refused
	}
	return 1, written, .Answered
}

// ---- The graph and the pool ----

// distributed_builder_init empties the run and takes the pool. Each machine
// of the pool must be paired with this machine, and the plan must give this
// machine the uses Roles and Objects of it: a builder and a cache answer by
// a role call, and give the output by its hash.
distributed_builder_init :: proc "contextless" (builder: ^Distributed_Builder, peer: ^machine_wire.Peer, pool: []Distributed_Peer) -> (refusal: Distributed_Refusal, bad_index: int) {
	if builder == nil || peer == nil || !peer.has_identity {
		return .Bad_Peer, 0
	}
	if len(pool) > DISTRIBUTED_PEER_CAPACITY {
		return .Pool_Full, DISTRIBUTED_PEER_CAPACITY
	}
	for item, index in pool {
		if machine_mesh.key_is_zero(item.identity) || machine_mesh.keys_equal_constant_time(item.identity, peer.identity.public_key) {
			return .Bad_Peer, index
		}
		switch item.purpose {
		case .None:
			return .Bad_Peer, index
		case .Builder, .Cache:
		}
		for earlier in pool[:index] {
			if machine_mesh.keys_equal_constant_time(earlier.identity, item.identity) {
				return .Bad_Peer, index
			}
		}
		if _, paired := machine_mesh.paired_machine_find(&peer.paired, item.identity); !paired {
			return .Peer_Not_Paired, index
		}
		if .Roles not_in item.uses || .Objects not_in item.uses {
			return .Peer_Lacks_Use, index
		}
	}
	builder.own_identity = peer.identity.public_key
	builder.recipe_count = 0
	builder.results = {}
	builder.links = {}
	builder.peer_out = {}
	builder.cursor = 0
	builder.counters = {}
	builder.peer_count = len(pool)
	for item, index in pool {
		builder.peers[index] = item
	}
	return .None, 0
}

// dag_recipe_add adds a recipe to the graph, and gives its index. Each
// dependency names an earlier recipe and an input of this recipe, which
// takes the output hash of that recipe when it is done; the hash of that
// input in spec is a placeholder until then.
dag_recipe_add :: proc "contextless" (builder: ^Distributed_Builder, spec: ^pr.Recipe_Spec, dependencies: []Dag_Dependency) -> (index: int, refusal: Distributed_Refusal) {
	if builder == nil || spec == nil {
		return -1, .Bad_Recipe
	}
	if builder.recipe_count >= DAG_RECIPE_CAPACITY {
		return -1, .Graph_Full
	}
	// The count of inputs is checked before any input is read by its index.
	if spec.input_count > pr.MAX_RECIPE_INPUTS || spec.arguments_length > pr.MAX_RECIPE_ARG_BYTES {
		return -1, .Bad_Recipe
	}
	if len(dependencies) > pr.MAX_RECIPE_INPUTS {
		return -1, .Bad_Dependency_Input
	}
	index = builder.recipe_count
	for dependency, position in dependencies {
		if int(dependency.producer) >= index {
			return -1, .Producer_Not_Earlier
		}
		if dependency.input_index >= spec.input_count {
			return -1, .Bad_Dependency_Input
		}
		for earlier in dependencies[:position] {
			if earlier.input_index == dependency.input_index {
				return -1, .Bad_Dependency_Input
			}
		}
	}
	// The placeholders may be zero: the validation sees the input hashes
	// that the producers give later as any non-zero hash.
	check := spec^
	for dependency in dependencies {
		check.inputs[dependency.input_index].hash = blake3.hash(transmute([]u8)string("modus dag placeholder"))
	}
	if validation, _ := pr.recipe_validate(&check); validation != .None {
		return -1, .Bad_Recipe
	}
	slot := &builder.recipes[index]
	slot.spec = spec^
	slot.dependency_count = u32(len(dependencies))
	for dependency, position in dependencies {
		slot.dependencies[position] = dependency
	}
	builder.results[index] = {}
	builder.recipe_count += 1
	return index, .None
}

// dag_output gives the kept bytes of a recipe that is done.
dag_output :: proc "contextless" (builder: ^Distributed_Builder, index: int) -> []u8 {
	if index < 0 || index >= builder.recipe_count || builder.results[index].phase != .Done {
		return nil
	}
	return builder.outputs[index][:builder.results[index].output_length]
}

// ---- The run ----

// distributed_build realises the whole graph. It gives the refusal of the
// first recipe that failed, or None; each result says how its recipe ended.
distributed_build :: proc "contextless" (builder: ^Distributed_Builder, peer: ^machine_wire.Peer, policy: ^Distributed_Policy, now_ms: u64) -> Distributed_Refusal {
	if builder == nil || peer == nil || policy == nil {
		return .Bad_Mode
	}
	mode, mode_ok := pr.build_mode_of_word(u64(policy.mode))
	if !mode_ok {
		return .Bad_Mode
	}
	first_refusal := Distributed_Refusal.None
	round: u32 = 0
	for {
		ready: [DAG_RECIPE_CAPACITY]int
		ready_count := 0
		waiting := 0
		for index in 0 ..< builder.recipe_count {
			if builder.results[index].phase != .Waiting {
				continue
			}
			waiting += 1
			recipe := &builder.recipes[index]
			all_done := true
			failed := false
			for dependency in recipe.dependencies[:recipe.dependency_count] {
				switch builder.results[dependency.producer].phase {
				case .Done:
				case .Waiting:
					all_done = false
				case .Failed:
					failed = true
				}
			}
			if failed {
				builder.results[index].phase = .Failed
				builder.results[index].refusal = .Dependency_Failed
				builder.results[index].round = round
				if first_refusal == .None {
					first_refusal = .Dependency_Failed
				}
				continue
			}
			if all_done {
				ready[ready_count] = index
				ready_count += 1
			}
		}
		if ready_count == 0 {
			// Each recipe names only earlier ones, so the first waiting
			// recipe is ready or was failed in this pass: each pass with no
			// ready recipe fails one at least, and the loop ends.
			if waiting == 0 {
				break
			}
			continue
		}
		round += 1
		builder.counters.rounds += 1
		for index in ready[:ready_count] {
			refusal := recipe_realise(builder, peer, policy, mode, index, now_ms)
			result := &builder.results[index]
			result.round = round
			if refusal != .None {
				result.phase = .Failed
				result.refusal = refusal
				if first_refusal == .None {
					first_refusal = refusal
				}
			} else {
				result.phase = .Done
			}
		}
	}
	return first_refusal
}

// recipe_fill gives each input that a producer gives the output hash of the
// producer, after it computed that hash again over the kept bytes.
@(private = "file")
recipe_fill :: proc "contextless" (builder: ^Distributed_Builder, index: int) -> Distributed_Refusal {
	recipe := &builder.recipes[index]
	for dependency in recipe.dependencies[:recipe.dependency_count] {
		producer := &builder.results[dependency.producer]
		recomputed, refusal := pr.recipe_hash_output(producer.output_kind, builder.outputs[dependency.producer][:producer.output_length])
		if refusal != .None || recomputed != producer.output_hash {
			return .Hash_Mismatch
		}
		input := &recipe.spec.inputs[dependency.input_index]
		if input.kind != producer.output_kind {
			return .Bad_Dependency_Input
		}
		input.hash = producer.output_hash
	}
	return .None
}

@(private = "file")
recipe_realise :: proc "contextless" (builder: ^Distributed_Builder, peer: ^machine_wire.Peer, policy: ^Distributed_Policy, mode: pr.Build_Mode, index: int, now_ms: u64) -> Distributed_Refusal {
	if fill_refusal := recipe_fill(builder, index); fill_refusal != .None {
		return fill_refusal
	}
	spec := &builder.recipes[index].spec
	recipe_hash, hash_refusal := pr.recipe_hash(spec)
	if hash_refusal != .None {
		return .Bad_Recipe
	}
	// recipe_hash refused a spec whose kinds name no member.
	kind := spec.output_kind
	result := &builder.results[index]
	result.recipe_hash = recipe_hash
	result.output_kind = kind

	switch mode {
	case .None:
		return .Bad_Mode
	case .Build_Only:
		return local_realise(builder, policy, index, spec)
	case .Verify:
		return verify_realise(builder, peer, policy, index, spec, recipe_hash, now_ms)
	case .Cache_First, .Cache_Only:
	}

	if policy.local_lookup != nil {
		record: object_cache.Realisation_Record
		count, found := policy.local_lookup(recipe_hash, &record, builder.staging[:], policy.user_data)
		if found && count >= 0 && count <= len(builder.staging) && record.recipe_hash == recipe_hash && record.output_kind == kind {
			if object_cache.verify_object_content(kind, record.output_hash, builder.staging[:count]) == .Trust_By_Hash {
				output_keep(builder, index, .Local_Store, builder.own_identity, record.output_hash, builder.staging[:count])
				builder.counters.local_store_hits += 1
				return .None
			}
		}
	}
	// A cache that gives a bad realisation or withholds the output leaves
	// the run, and the next cache, a builder or this machine gives the
	// output: one faulty cache never stops a build. Cache_Only with no hit
	// names the last fault, which says more than a miss.
	last_fault := Distributed_Refusal.None
	for peer_index in 0 ..< builder.peer_count {
		if builder.peers[peer_index].purpose != .Cache || builder.peer_out[peer_index] {
			continue
		}
		hit, refusal := cache_fetch(builder, peer, policy, mode, peer_index, index, recipe_hash, kind, now_ms)
		if refusal != .None {
			builder.counters.cache_faults += 1
			builder.peer_out[peer_index] = true
			last_fault = refusal
			continue
		}
		if hit {
			builder.counters.cache_hits += 1
			return .None
		}
	}
	if mode == .Cache_Only {
		return last_fault != .None ? last_fault : .Cache_Miss
	}
	_, refusal, built, _ := builders_try(builder, peer, policy, index, false, spec, recipe_hash, kind, {}, now_ms)
	if refusal != .None {
		return refusal
	}
	if built {
		return .None
	}
	if policy.local_builder == nil {
		return .No_Builder
	}
	return local_realise(builder, policy, index, spec)
}

// verify_realise builds the recipe on two independent machines: two
// distinct builders, or one builder and this machine. A machine is never
// compared with itself, and a run that finds one machine only is refused:
// Verify never ends as one build with no comparison. Each remote output
// passed its realisation check (signer and signature) and its hash check in
// builders_try; both outputs are hashed again over their bytes before the
// comparison.
@(private = "file")
verify_realise :: proc "contextless" (builder: ^Distributed_Builder, peer: ^machine_wire.Peer, policy: ^Distributed_Policy, index: int, spec: ^pr.Recipe_Spec, recipe_hash: blake3.Hash, now_ms: u64) -> Distributed_Refusal {
	result := &builder.results[index]
	kind := result.output_kind
	first, first_refusal, first_built, first_count := builders_try(builder, peer, policy, index, false, spec, recipe_hash, kind, {}, now_ms)
	if first_refusal != .None {
		return first_refusal
	}
	if !first_built {
		// No builder built it: this machine alone is one machine.
		return .Verify_Needs_Two_Machines
	}
	first_hash := result.output_hash
	// The second build goes to staging: the kept output stays the first.
	// The first builder is excluded, so the second is another builder.
	second, second_refusal, second_built, second_count := builders_try(builder, peer, policy, index, true, spec, recipe_hash, kind, first, now_ms)
	if second_refusal != .None {
		return second_refusal
	}
	second_hash: blake3.Hash
	if second_built {
		second_hash = builder.results[index].second_output_hash
	} else {
		// No second builder, or it failed during the build: only this
		// machine can be the second, else the recipe is refused.
		if policy.local_builder == nil {
			return .Verify_Needs_Two_Machines
		}
		count, local_refusal := local_build_into(policy, spec, builder.staging[:])
		if local_refusal != .None {
			return local_refusal
		}
		builder.counters.local_builds += 1
		hash, output_refusal := pr.recipe_hash_output(kind, builder.staging[:count])
		if output_refusal != .None {
			return .Local_Build_Failed
		}
		second = builder.own_identity
		second_hash = hash
		second_count = count
	}
	result.second_machine = second
	result.second_output_hash = second_hash
	if machine_mesh.key_is_zero(first) || machine_mesh.keys_equal_constant_time(first, second) {
		return .Verify_Needs_Two_Machines
	}
	// Both outputs are hashed again over the bytes that this machine holds,
	// so the comparison is of bytes, not of what two records claim.
	first_recomputed, first_output_refusal := pr.recipe_hash_output(kind, builder.outputs[index][:first_count])
	second_recomputed, second_output_refusal := pr.recipe_hash_output(kind, builder.staging[:second_count])
	if first_output_refusal != .None || second_output_refusal != .None || first_recomputed != first_hash || second_recomputed != second_hash {
		return .Hash_Mismatch
	}
	if second_hash != first_hash {
		builder.counters.determinism_mismatches += 1
		return .Determinism_Mismatch
	}
	builder.counters.verify_agreements += 1
	return .None
}

// builders_try gives the recipe to the builders in turn, from the cursor,
// and passes over the machine excluded. A builder whose link breaks, or that
// refuses the call, leaves the run, and the recipe goes to the next one.
// A realisation that fails its checks is refused: a fault to read, not a
// lost link. For the second build of Verify, the output goes to staging and
// its hash to the second output hash of the recipe.
@(private = "file")
builders_try :: proc "contextless" (
	builder: ^Distributed_Builder,
	peer: ^machine_wire.Peer,
	policy: ^Distributed_Policy,
	index: int,
	second: bool,
	spec: ^pr.Recipe_Spec,
	recipe_hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
	excluded: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	now_ms: u64,
) -> (machine: [machine_mesh.PUBLIC_KEY_SIZE]u8, refusal: Distributed_Refusal, built: bool, count: int) {
	if policy.transport == nil {
		return {}, .None, false, 0
	}
	arguments, argument_refusal := remote_build_arguments_write(spec, builder.arguments[:])
	if argument_refusal != .None {
		// A recipe too large for one call is built on this machine.
		return {}, .None, false, 0
	}
	for _ in 0 ..< builder.peer_count {
		peer_index := builder.cursor % builder.peer_count
		builder.cursor = (builder.cursor + 1) % builder.peer_count
		item := &builder.peers[peer_index]
		if item.purpose != .Builder || builder.peer_out[peer_index] || machine_mesh.keys_equal_constant_time(item.identity, excluded) {
			continue
		}
		if !link_ready(builder, peer, policy, peer_index, now_ms) {
			builder_leaves(builder, index)
			continue
		}
		call := machine_wire.mesh_call_role(&builder.links[peer_index], policy.transport, REMOTE_RECIPES_ROLE, u32(Remote_Recipes_Export.Build), {.Idempotent}, arguments, now_ms, policy.bound_ms, builder.request[:], builder.answer[:])
		switch call.exchange.outcome {
		case .Answered:
		case .Refused:
			builder.counters.builders_refused += 1
			builder.peer_out[peer_index] = true
			builder_leaves(builder, index)
			continue
		case .None, .Unknown_Outcome, .Unreachable:
			// The build can have run there; it is a function of its recipe,
			// so the next machine builds the same output.
			builder.counters.links_lost += 1
			builder.peer_out[peer_index] = true
			builder_leaves(builder, index)
			continue
		}
		record, record_refusal := realisation_check(policy, call.reply.result, recipe_hash, kind)
		if record_refusal != .None {
			return item.identity, record_refusal, false, 0
		}
		target := second ? builder.staging[:] : builder.outputs[index][:]
		fetched, fetch_refusal, lost := object_fetch(builder, policy, peer_index, kind, record.output_hash, target, now_ms)
		if lost {
			builder.counters.links_lost += 1
			builder.peer_out[peer_index] = true
			builder_leaves(builder, index)
			continue
		}
		if fetch_refusal != .None {
			return item.identity, fetch_refusal, false, 0
		}
		builder.counters.remote_builds += 1
		if second {
			builder.results[index].second_output_hash = record.output_hash
		} else {
			output_record(builder, index, .Remote_Builder, item.identity, record.output_hash, fetched)
		}
		return item.identity, .None, true, fetched
	}
	return {}, .None, false, 0
}

@(private = "file")
builder_leaves :: proc "contextless" (builder: ^Distributed_Builder, index: int) {
	builder.counters.failovers += 1
	builder.results[index].failovers += 1
}

// link_ready connects the link of a machine of the pool when it is not up.
// A machine that cannot be reached leaves the run.
@(private = "file")
link_ready :: proc "contextless" (builder: ^Distributed_Builder, peer: ^machine_wire.Peer, policy: ^Distributed_Policy, peer_index: int, now_ms: u64) -> bool {
	link := &builder.links[peer_index]
	if link.state == .Up {
		return true
	}
	if machine_wire.mesh_connect(link, peer, policy.transport, builder.peers[peer_index].identity, .Paired, now_ms, policy.bound_ms) != .Ok {
		builder.counters.links_lost += 1
		builder.peer_out[peer_index] = true
		return false
	}
	return true
}

// cache_fetch asks one cache for the realisation of a recipe, then for its
// output. hit is true when the output is kept.
@(private = "file")
cache_fetch :: proc "contextless" (
	builder: ^Distributed_Builder,
	peer: ^machine_wire.Peer,
	policy: ^Distributed_Policy,
	mode: pr.Build_Mode,
	peer_index: int,
	index: int,
	recipe_hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
	now_ms: u64,
) -> (hit: bool, refusal: Distributed_Refusal) {
	if policy.transport == nil || !link_ready(builder, peer, policy, peer_index, now_ms) {
		return false, .None
	}
	hash := recipe_hash
	call := machine_wire.mesh_call_role(&builder.links[peer_index], policy.transport, REMOTE_RECIPES_ROLE, u32(Remote_Recipes_Export.Realisation_Lookup), {.Idempotent}, hash[:], now_ms, policy.bound_ms, builder.request[:], builder.answer[:])
	switch call.exchange.outcome {
	case .Answered:
	case .Refused:
		// The cache holds no realisation of the recipe.
		return false, .None
	case .None, .Unknown_Outcome, .Unreachable:
		builder.counters.links_lost += 1
		builder.peer_out[peer_index] = true
		return false, .None
	}
	record, record_refusal := realisation_check(policy, call.reply.result, recipe_hash, kind)
	if record_refusal == .Untrusted_Realisation && mode == .Cache_First {
		builder.counters.cache_untrusted_skips += 1
		return false, .None
	}
	if record_refusal != .None {
		return false, record_refusal
	}
	count, fetch_refusal, lost := object_fetch(builder, policy, peer_index, kind, record.output_hash, builder.outputs[index][:], now_ms)
	if lost {
		builder.counters.links_lost += 1
		builder.peer_out[peer_index] = true
		return false, .None
	}
	if fetch_refusal != .None {
		return false, fetch_refusal
	}
	output_record(builder, index, .Cache_Peer, builder.peers[peer_index].identity, record.output_hash, count)
	return true, .None
}

// realisation_check decodes the realisation that a machine gave, and checks
// its recipe, its output kind, its signer and its signature.
@(private = "file")
realisation_check :: proc "contextless" (policy: ^Distributed_Policy, wire: []u8, recipe_hash: blake3.Hash, kind: object_cache.Cache_Object_Kind) -> (record: object_cache.Realisation_Record, refusal: Distributed_Refusal) {
	decoded, wire_refusal := object_cache.decode_realisation_record(wire)
	if wire_refusal != .None {
		return {}, .Malformed_Realisation
	}
	if decoded.recipe_hash != recipe_hash {
		return {}, .Wrong_Recipe
	}
	if decoded.output_kind != kind {
		return {}, .Malformed_Realisation
	}
	// The mode of the check is Verify: a realisation of another machine is
	// taken only from a signer that the policy names.
	check_policy := object_cache.Substitution_Policy{mode = .Verify, trusted_signers = policy.trusted_signers}
	decision := object_cache.substitution_check(check_policy, object_cache.Substitution_Realisation_Subject{expected_recipe_hash = recipe_hash, realisation = decoded}, policy.verify_signature, policy.user_data)
	switch decision {
	case .Trust_By_Signer:
		return decoded, .None
	case .Refuse_Untrusted_Signer:
		return {}, .Untrusted_Realisation
	case .Refuse_Bad_Signature:
		return {}, .Bad_Signature
	case .Refuse_Hash_Mismatch, .Refuse_Malformed, .Trust_By_Hash:
	}
	return {}, .Malformed_Realisation
}

// object_fetch asks a machine for the bytes of an output, and copies them
// into target only when they hash to the output hash. lost is true when the
// link broke.
@(private = "file")
object_fetch :: proc "contextless" (builder: ^Distributed_Builder, policy: ^Distributed_Policy, peer_index: int, kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, target: []u8, now_ms: u64) -> (count: int, refusal: Distributed_Refusal, lost: bool) {
	request := machine_wire.object_request_write(builder.request[:], kind, hash)
	if request == nil {
		return 0, .Malformed_Realisation, false
	}
	exchange := machine_wire.mesh_exchange(&builder.links[peer_index], policy.transport, request, now_ms, policy.bound_ms, builder.answer[:])
	switch exchange.outcome {
	case .Answered:
	case .Refused:
		return 0, .Output_Absent, false
	case .None, .Unknown_Outcome, .Unreachable:
		return 0, .None, true
	}
	body := exchange.body
	if len(body) < machine_wire.OBJECT_RESPONSE_HEADER_SIZE {
		return 0, .Output_Absent, false
	}
	answer_kind, kind_ok := object_cache.cache_object_kind_of_word(u64(byte_order.read_u32_little_endian(body, 0)))
	length := u64(byte_order.read_u32_little_endian(body, 4))
	answer_hash: blake3.Hash
	copy(answer_hash[:], body[8:machine_wire.OBJECT_RESPONSE_HEADER_SIZE])
	bytes := body[machine_wire.OBJECT_RESPONSE_HEADER_SIZE:]
	if !kind_ok || answer_kind != kind || answer_hash != hash || length != u64(len(bytes)) {
		return 0, .Output_Absent, false
	}
	if len(bytes) > len(target) {
		return 0, .Output_Too_Large, false
	}
	// The hash is computed again before any byte is kept.
	switch object_cache.verify_object_content(kind, hash, bytes) {
	case .Trust_By_Hash:
	case .Refuse_Hash_Mismatch:
		return 0, .Hash_Mismatch, false
	case .Refuse_Malformed, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature, .Trust_By_Signer:
		return 0, .Hash_Mismatch, false
	}
	return copy(target, bytes), .None, false
}

@(private = "file")
local_build_into :: proc "contextless" (policy: ^Distributed_Policy, spec: ^pr.Recipe_Spec, target: []u8) -> (count: int, refusal: Distributed_Refusal) {
	if policy.local_builder == nil {
		return 0, .No_Builder
	}
	sandbox: pr.Builder_Sandbox_Spec
	sandbox_refusal := pr.builder_sandbox_prepare(spec, &sandbox)
	if sandbox_refusal != .None || pr.builder_sandbox_validate(&sandbox) != .None {
		return 0, .Local_Build_Failed
	}
	built, ok := policy.local_builder(&sandbox, target, policy.user_data)
	if !ok || built < 0 || built > len(target) {
		return 0, .Local_Build_Failed
	}
	return built, .None
}

@(private = "file")
local_realise :: proc "contextless" (builder: ^Distributed_Builder, policy: ^Distributed_Policy, index: int, spec: ^pr.Recipe_Spec) -> Distributed_Refusal {
	count, refusal := local_build_into(policy, spec, builder.outputs[index][:])
	if refusal != .None {
		return refusal
	}
	hash, output_refusal := pr.recipe_hash_output(builder.results[index].output_kind, builder.outputs[index][:count])
	if output_refusal != .None {
		return .Local_Build_Failed
	}
	builder.counters.local_builds += 1
	output_record(builder, index, .Local_Build, builder.own_identity, hash, count)
	return .None
}

@(private = "file")
output_keep :: proc "contextless" (builder: ^Distributed_Builder, index: int, source: Distributed_Source, machine: [machine_mesh.PUBLIC_KEY_SIZE]u8, hash: blake3.Hash, bytes: []u8) {
	count := copy(builder.outputs[index][:], bytes)
	output_record(builder, index, source, machine, hash, count)
}

@(private = "file")
output_record :: proc "contextless" (builder: ^Distributed_Builder, index: int, source: Distributed_Source, machine: [machine_mesh.PUBLIC_KEY_SIZE]u8, hash: blake3.Hash, count: int) {
	result := &builder.results[index]
	result.source = source
	result.machine = machine
	result.output_hash = hash
	result.output_length = count
}
