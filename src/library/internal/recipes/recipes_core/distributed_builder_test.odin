#+build !freestanding
package recipes_core

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/byte_order"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import "modus:contract/tree_hash"

// A simulation of four machines of one principal: laptop A, which runs the
// scheduler; builders B and C; cache D. Each machine is a machine_wire.Peer;
// the network carries each frame to the machine of the pinned key, and can
// lose an answer, drop a machine, or change one bit in transit.

@(private = "file")
Builder_Behaviour :: enum u8 {
	Honest            = 0, // The output is a function of the recipe.
	Non_Deterministic = 1, // The output gains one byte: another hash for the same recipe.
}

@(private = "file")
Sim_Machine :: struct {
	peer:            machine_wire.Peer,
	private_key:     ed25519.Private_Key,
	signer_key:      ed25519.Private_Key, // The key that signs its realisations.
	signer_public:   [32]u8,
	seed:            u8,
	counter:         u64,
	behaviour:       Builder_Behaviour,
	builds:          int, // The builds that this machine ran.
	host:            Remote_Recipes_Host,
	cache_record:    object_cache.Realisation_Record,
	cache_payload:   [256]u8,
	cache_length:    int,
	has_cache:       bool,
}

@(private = "file")
sim_key :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_key: [32]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte ~ u8(index * 13 + 5)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_key[:])
	return private_key, public_key
}

@(private = "file")
sim_verify :: proc "contextless" (public_key: [32]u8, message: []u8, signature: [64]u8, _: rawptr) -> bool {
	context = runtime.default_context()
	key, signature_copy := public_key, signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, key[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, signature_copy[:])
}

@(private = "file")
sim_random :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	machine := (^Sim_Machine)(user_data)
	machine.counter += 1
	input: [9]u8
	input[0] = machine.seed
	byte_order.write_u64_little_endian(input[:], 1, machine.counter)
	derived := blake3.derive_key("modus distributed builder test random", input[:])
	for index in 0 ..< len(bytes) {
		bytes[index] = derived[index % 32]
	}
	return true
}

// The builder of the simulation: a blob of the recipe hash and its input
// hashes, or a tree with one entry named "out".
@(private = "file")
sim_build :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, output: []u8, user_data: rawptr) -> (int, bool) {
	machine := (^Sim_Machine)(user_data)
	machine.builds += 1
	context = runtime.default_context()
	digest_input: [blake3.HASH_SIZE * (1 + pr.MAX_RECIPE_INPUTS) + 1]u8
	copy(digest_input[:32], sandbox.recipe_hash[:])
	length := 32
	for index in 0 ..< sandbox.input_count {
		copy(digest_input[length:][:32], sandbox.inputs[index].hash[:])
		length += 32
	}
	if machine.behaviour == .Non_Deterministic {
		digest_input[length] = u8(machine.builds)
		length += 1
	}
	digest := blake3.hash(digest_input[:length])
	switch sandbox.output_kind {
	case .Blob:
		text := "built "
		count := copy(output, text)
		count += copy(output[count:], digest[:])
		return count, true
	case .Tree:
		entry, refusal := tree_hash.tree_entry_make(.Object, "out", digest)
		if refusal != .None {
			return 0, false
		}
		entries := [1]tree_hash.Tree_Entry{entry}
		written, encode_refusal := tree_hash.tree_encode(entries[:], output)
		return written, encode_refusal == .None
	}
	return 0, false
}

@(private = "file")
sim_sign :: proc "contextless" (signing_bytes: []u8, public_key: ^[object_cache.PUBLIC_KEY_SIZE]u8, signature: ^[object_cache.SIGNATURE_SIZE]u8, user_data: rawptr) -> bool {
	machine := (^Sim_Machine)(user_data)
	context = runtime.default_context()
	public_key^ = machine.signer_public
	ed25519.sign(&machine.signer_key, signing_bytes, signature[:])
	return true
}

@(private = "file")
sim_publish :: proc "contextless" (kind: object_cache.Cache_Object_Kind, hash: blake3.Hash, bytes: []u8, user_data: rawptr) -> bool {
	machine := (^Sim_Machine)(user_data)
	status := machine_wire.object_publish(&machine.peer, kind, hash, bytes)
	return status == .Stored || status == .Already_Stored
}

@(private = "file")
sim_lookup :: proc "contextless" (recipe_hash: blake3.Hash, record: ^object_cache.Realisation_Record, payload: []u8, user_data: rawptr) -> (int, bool) {
	machine := (^Sim_Machine)(user_data)
	if !machine.has_cache || machine.cache_record.recipe_hash != recipe_hash {
		return 0, false
	}
	record^ = machine.cache_record
	return copy(payload, machine.cache_payload[:machine.cache_length]), true
}

@(private = "file")
sim_role_holder :: proc "contextless" (role: role_contract.Role, export: u32, arguments: []u8, result: []u8, user_data: rawptr) -> (i64, int, call_outcome.Call_Outcome) {
	machine := (^Sim_Machine)(user_data)
	if role != REMOTE_RECIPES_ROLE {
		return 0, 0, .Operation_Unsupported
	}
	return remote_recipes_serve(&machine.host, export, arguments, result)
}

@(private = "file")
sim_machine_make :: proc(seed: u8, builder: bool) -> ^Sim_Machine {
	machine := new(Sim_Machine)
	machine.seed = seed
	public_key: [32]u8
	machine.private_key, public_key = sim_key(seed)
	machine.signer_key, machine.signer_public = sim_key(seed + 0x80)
	ok := machine_wire.peer_init(&machine.peer, public_key, machine_wire.Peer_Services{signature_verify = sim_verify, fill_random = sim_random, role_holder = sim_role_holder, user_data = machine})
	assert(ok)
	machine.host = Remote_Recipes_Host{lookup = sim_lookup, publish = sim_publish, user_data = machine}
	if builder {
		machine.host.builder_invoke = sim_build
		machine.host.sign_realisation = sim_sign
	}
	return machine
}

@(private = "file")
identity :: proc(machine: ^Sim_Machine) -> [32]u8 {
	return machine.peer.identity.public_key
}

@(private = "file")
Sim_Network :: struct {
	client:        ^Sim_Machine,
	machines:      [5]^Sim_Machine,
	count:         int,
	now_ms:        u64,
	down:          [32]u8, // A machine that is down.
	lose_build_of: [32]u8, // A builder that runs a build and loses its answer.
	flip_object_of: [32]u8, // A machine whose object answers lose one bit in transit.
	output:        [machine_wire.FRAME_LIMIT]u8,
	calls:         [5][dag_round_limit]int, // The build calls of each machine in each round.
	round:         int,
}

@(private = "file")
dag_round_limit :: 8

@(private = "file")
sim_find :: proc "contextless" (network: ^Sim_Network, key: [32]u8) -> (^Sim_Machine, int) {
	for machine, index in network.machines[:network.count] {
		if machine.peer.identity.public_key == key {
			return machine, index
		}
	}
	return nil, -1
}

@(private = "file")
sim_connect :: proc "contextless" (pinned: [32]u8, _: u64, user_data: rawptr) -> ([32]u8, bool) {
	network := (^Sim_Network)(user_data)
	machine, _ := sim_find(network, pinned)
	if machine == nil || (!machine_mesh.key_is_zero(network.down) && network.down == pinned) {
		return {}, false
	}
	return pinned, true
}

@(private = "file")
sim_round_trip :: proc "contextless" (pinned: [32]u8, request: []u8, answer_buffer: []u8, _: u64, user_data: rawptr) -> (int, machine_wire.Mesh_Delivery) {
	network := (^Sim_Network)(user_data)
	machine, _ := sim_find(network, pinned)
	if machine == nil || (!machine_mesh.key_is_zero(network.down) && network.down == pinned) {
		return 0, .Not_Connected
	}
	client := network.client.peer.identity.public_key
	serve_context := machine_wire.Serve_Context {
		peer_identity   = client,
		channel_binding = machine_wire.channel_binding_of_identities(pinned, client),
		now_ms          = network.now_ms,
	}
	frame, _ := machine_wire.frame_decode(request)
	is_build := false
	if frame.message == .Role_Call {
		call, read_ok := machine_wire.role_call_read(frame.body)
		is_build = read_ok && call.export == u32(Remote_Recipes_Export.Build)
	}
	answer := machine_wire.serve(&machine.peer, &serve_context, request, network.output[:])
	if is_build && !machine_mesh.key_is_zero(network.lose_build_of) && network.lose_build_of == pinned {
		// The build ran; the link broke before its answer.
		return 0, .Link_Broken
	}
	count := copy(answer_buffer, answer)
	answer_frame, status := machine_wire.frame_decode(answer_buffer[:count])
	if status == .Ok && answer_frame.message == .Object_Response && !machine_mesh.key_is_zero(network.flip_object_of) && network.flip_object_of == pinned {
		answer_buffer[count - 1] ~= 0x01
	}
	return count, .Answered
}

@(private = "file")
Sim_Buffers :: struct {
	request: [machine_wire.FRAME_LIMIT]u8,
	answer:  [machine_wire.FRAME_LIMIT]u8,
}

// sim_pair pairs the laptop with another machine through the outbound link
// of the laptop, and gives the laptop the uses of the plan on it.
@(private = "file")
sim_pair :: proc(t: ^testing.T, laptop, other: ^Sim_Machine, network: ^Sim_Network, uses: machine_wire.Machine_Uses, roles: machine_wire.Role_Set) {
	random_bytes := [8]u8{other.seed, laptop.seed, 3, 4, 5, 6, 7, 8}
	code, offer_status := machine_mesh.pairing_offer(&other.peer.pairing, identity(other), random_bytes, network.now_ms)
	testing.expect_value(t, offer_status, machine_mesh.Pairing_Status.Ok)
	other.peer.pairing_uses = {.Calls}
	laptop.peer.pairing_uses = {.Calls}
	testing.expect_value(t, machine_mesh.pairing_join(&laptop.peer.pairing, identity(laptop), code[:], network.now_ms), machine_mesh.Pairing_Status.Ok)
	transport := machine_wire.Mesh_Transport{connect = sim_connect, round_trip = sim_round_trip, user_data = network}
	link: machine_wire.Mesh_Link
	testing.expect_value(t, machine_wire.mesh_connect(&link, &laptop.peer, &transport, identity(other), .Pairing, network.now_ms, 1_000), machine_wire.Mesh_Client_Status.Ok)
	buffers := new(Sim_Buffers)
	defer free(buffers)
	joined := machine_wire.mesh_pair_join(&laptop.peer, &link, &transport, network.now_ms, 1_000, buffers.request[:], buffers.answer[:])
	testing.expect_value(t, joined.pairing, machine_mesh.Pairing_Status.Ok)
	if uses != {} {
		testing.expect(t, machine_wire.machine_grant_set(&other.peer, identity(laptop), uses, roles))
	}
}

// The world of a test: the laptop, B, C, D, and E that is never paired.
@(private = "file")
World :: struct {
	laptop, b, c, d, e: ^Sim_Machine,
	network:            ^Sim_Network,
	transport:          machine_wire.Mesh_Transport,
	scheduler:          ^Distributed_Builder,
	trusted:            [3][32]u8,
	local_builds:       int,
}

@(private = "file")
world_make :: proc(t: ^testing.T, grant_b_roles := true) -> ^World {
	world := new(World)
	world.laptop = sim_machine_make(0x10, true)
	world.b = sim_machine_make(0x20, true)
	world.c = sim_machine_make(0x30, true)
	world.d = sim_machine_make(0x40, false)
	world.e = sim_machine_make(0x50, true)
	world.network = new(Sim_Network)
	world.network.client = world.laptop
	world.network.now_ms = 100_000
	world.network.machines = {world.b, world.c, world.d, world.e, world.laptop}
	world.network.count = 4
	world.transport = machine_wire.Mesh_Transport{connect = sim_connect, round_trip = sim_round_trip, user_data = world.network}
	b_uses := grant_b_roles ? machine_wire.Machine_Uses{.Roles, .Objects} : machine_wire.Machine_Uses{.Objects}
	b_roles := grant_b_roles ? machine_wire.Role_Set{.Recipes} : machine_wire.Role_Set{}
	sim_pair(t, world.laptop, world.b, world.network, b_uses, b_roles)
	sim_pair(t, world.laptop, world.c, world.network, {.Roles, .Objects}, {.Recipes})
	sim_pair(t, world.laptop, world.d, world.network, {.Roles, .Objects}, {.Recipes})
	world.trusted = {world.b.signer_public, world.c.signer_public, world.d.signer_public}
	world.scheduler = new(Distributed_Builder)
	return world
}

@(private = "file")
world_free :: proc(world: ^World) {
	free(world.laptop)
	free(world.b)
	free(world.c)
	free(world.d)
	free(world.e)
	free(world.network)
	free(world.scheduler)
	free(world)
}

@(private = "file")
world_pool :: proc(world: ^World) -> [3]Distributed_Peer {
	return {
		{identity = identity(world.b), purpose = .Builder, uses = {.Roles, .Objects}},
		{identity = identity(world.c), purpose = .Builder, uses = {.Roles, .Objects}},
		{identity = identity(world.d), purpose = .Cache, uses = {.Roles, .Objects}},
	}
}

@(private = "file")
world_local_build :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, output: []u8, user_data: rawptr) -> (int, bool) {
	world := (^World)(user_data)
	world.local_builds += 1
	return sim_build(sandbox, output, world.laptop)
}

@(private = "file")
world_policy :: proc(world: ^World, mode: pr.Build_Mode, local := true) -> Distributed_Policy {
	policy := Distributed_Policy {
		mode             = mode,
		trusted_signers  = world.trusted[:],
		verify_signature = sim_verify,
		transport        = &world.transport,
		bound_ms         = 1_000,
		user_data        = world,
	}
	if local {
		policy.local_builder = world_local_build
	}
	return policy
}

@(private = "file")
spec_make :: proc(name: string, kind: object_cache.Cache_Object_Kind, inputs: []string, argument: u8) -> (spec: pr.Recipe_Spec) {
	spec.builder_hash = blake3.hash(transmute([]u8)string("modus test builder"))
	spec.output_kind = kind
	spec.source_date_unix = 1_700_000_000
	spec.output_block_limit = 64
	for input_name, index in inputs {
		source := blake3.hash(transmute([]u8)input_name)
		input, refusal := pr.recipe_input_make(input_name, .Blob, source)
		assert(refusal == .None)
		spec.inputs[index] = input
	}
	spec.input_count = u32(len(inputs))
	spec.arguments[0] = argument
	spec.arguments_length = 1
	_ = name
	return spec
}

// cache_prepare gives cache D the realisation of a recipe, signed by signer,
// with its output.
@(private = "file")
cache_prepare :: proc(world: ^World, spec: ^pr.Recipe_Spec, signer: ^Sim_Machine) {
	cache_prepare_on(world.d, spec, signer)
}

// cache_prepare_on gives a machine that serves as a cache the realisation
// of a recipe, signed by signer, with its output.
@(private = "file")
cache_prepare_on :: proc(cache: ^Sim_Machine, spec: ^pr.Recipe_Spec, signer: ^Sim_Machine) {
	sandbox, refusal := pr.builder_sandbox_prepare(spec)
	assert(refusal == .None)
	builds := cache.builds
	count, ok := sim_build(&sandbox, cache.cache_payload[:], cache)
	assert(ok)
	cache.builds = builds
	cache.cache_length = count
	output_hash, _ := pr.recipe_hash_output(sandbox.output_kind, cache.cache_payload[:count])
	cache.cache_record = object_cache.Realisation_Record{recipe_hash = sandbox.recipe_hash, output_hash = output_hash, output_kind = sandbox.output_kind, signer_public_key = signer.signer_public}
	signing_bytes, _ := object_cache.realisation_signing_bytes(&cache.cache_record)
	ed25519.sign(&signer.signer_key, signing_bytes[:], cache.cache_record.signature[:])
	cache.has_cache = true
}

// ---- The tests ----

@(test)
distributed_dag_runs_across_builders_and_cache :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	pool := world_pool(world)
	refusal, _ := distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	testing.expect_value(t, refusal, Distributed_Refusal.None)

	// Six recipes: three leaves, two recipes of the second level, one of
	// the third. D holds the realisation of the leaf gamma.
	alpha := spec_make("alpha", .Blob, {"source"}, 1)
	beta := spec_make("beta", .Tree, {"source"}, 2)
	gamma := spec_make("gamma", .Blob, {"source"}, 3)
	cache_prepare(world, &gamma, world.d)
	join := spec_make("join", .Blob, {"alpha", "beta"}, 4)
	join.inputs[1].kind = .Tree
	single := spec_make("single", .Blob, {"gamma"}, 5)
	top := spec_make("top", .Blob, {"join", "single"}, 6)

	index_alpha, _ := dag_recipe_add(world.scheduler, &alpha, nil)
	index_beta, _ := dag_recipe_add(world.scheduler, &beta, nil)
	index_gamma, _ := dag_recipe_add(world.scheduler, &gamma, nil)
	index_join, _ := dag_recipe_add(world.scheduler, &join, {{producer = u32(index_alpha), input_index = 0}, {producer = u32(index_beta), input_index = 1}})
	index_single, _ := dag_recipe_add(world.scheduler, &single, {{producer = u32(index_gamma), input_index = 0}})
	index_top, add_refusal := dag_recipe_add(world.scheduler, &top, {{producer = u32(index_join), input_index = 0}, {producer = u32(index_single), input_index = 1}})
	testing.expect_value(t, add_refusal, Distributed_Refusal.None)
	testing.expect_value(t, index_top, 5)

	policy := world_policy(world, .Cache_First)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	results := &world.scheduler.results

	// The independent leaves went to B and to C in the first round; gamma
	// came from D, with no build anywhere.
	testing.expect(t, results[index_alpha].source == .Remote_Builder && results[index_alpha].machine == identity(world.b))
	testing.expect(t, results[index_beta].source == .Remote_Builder && results[index_beta].machine == identity(world.c))
	testing.expect(t, results[index_alpha].round == 1 && results[index_beta].round == 1 && results[index_gamma].round == 1)
	testing.expect(t, results[index_gamma].source == .Cache_Peer && results[index_gamma].machine == identity(world.d))
	testing.expect_value(t, results[index_gamma].output_hash, world.d.cache_record.output_hash)
	testing.expect_value(t, world.d.builds, 0)
	// The dependent recipes waited for their producers.
	testing.expect_value(t, results[index_join].round, 2)
	testing.expect_value(t, results[index_single].round, 2)
	testing.expect_value(t, results[index_top].round, 3)
	testing.expect_value(t, world.scheduler.counters.rounds, 3)
	// Each input of a producer holds the output hash of the producer, and
	// each kept output hashes to its output hash.
	testing.expect_value(t, world.scheduler.recipes[index_join].spec.inputs[0].hash, results[index_alpha].output_hash)
	testing.expect_value(t, world.scheduler.recipes[index_join].spec.inputs[1].hash, results[index_beta].output_hash)
	testing.expect_value(t, world.scheduler.recipes[index_top].spec.inputs[1].hash, results[index_single].output_hash)
	for index in 0 ..< 6 {
		testing.expect_value(t, results[index].phase, Dag_Phase.Done)
		recomputed, _ := pr.recipe_hash_output(results[index].output_kind, dag_output(world.scheduler, index))
		testing.expect_value(t, recomputed, results[index].output_hash)
	}
	testing.expect_value(t, results[index_beta].output_kind, object_cache.Cache_Object_Kind.Tree)
	testing.expect_value(t, world.b.builds + world.c.builds, 5)
	testing.expect_value(t, world.local_builds, 0)
	testing.expect_value(t, world.scheduler.counters.cache_hits, 1)
	testing.expect_value(t, world.scheduler.counters.remote_builds, 5)
	testing.expect_value(t, world.scheduler.counters.failovers, 0)
}

@(test)
distributed_cache_refuses_a_tampered_byte_and_an_untrusted_signer :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	pool := world_pool(world)
	gamma := spec_make("gamma", .Blob, {"source"}, 3)

	// One bit of the output changes between D and the laptop.
	cache_prepare(world, &gamma, world.d)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	world.network.flip_object_of = identity(world.d)
	policy := world_policy(world, .Cache_Only)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Hash_Mismatch)
	testing.expect_value(t, world.scheduler.results[0].phase, Dag_Phase.Failed)
	testing.expect(t, dag_output(world.scheduler, 0) == nil)
	testing.expect_value(t, world.scheduler.results[0].output_length, 0)
	world.network.flip_object_of = {}

	// A signer that the policy does not name: E signed the realisation.
	cache_prepare(world, &gamma, world.e)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Untrusted_Realisation)
	// Cache_First passes over it and builds the recipe instead.
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	policy = world_policy(world, .Cache_First)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Remote_Builder)
	testing.expect_value(t, world.scheduler.counters.cache_untrusted_skips, 1)

	// A signature that does not verify: one bit of it changed.
	cache_prepare(world, &gamma, world.d)
	world.d.cache_record.signature[5] ~= 0x10
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	policy = world_policy(world, .Cache_Only)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Bad_Signature)

	// A cache that holds nothing: Cache_Only refuses the miss.
	world.d.has_cache = false
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Cache_Miss)
}

@(test)
distributed_build_fails_over_when_a_builder_link_breaks :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	pool := world_pool(world)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	alpha := spec_make("alpha", .Blob, {"source"}, 1)
	beta := spec_make("beta", .Blob, {"source"}, 2)
	join := spec_make("join", .Blob, {"alpha", "beta"}, 4)
	dag_recipe_add(world.scheduler, &alpha, nil)
	dag_recipe_add(world.scheduler, &beta, nil)
	dag_recipe_add(world.scheduler, &join, {{producer = 0, input_index = 0}, {producer = 1, input_index = 1}})

	// B runs the build of alpha, and its link breaks before the answer.
	world.network.lose_build_of = identity(world.b)
	policy := world_policy(world, .Cache_First, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	results := &world.scheduler.results
	testing.expect_value(t, world.b.builds, 1)
	testing.expect_value(t, results[0].machine, identity(world.c))
	testing.expect_value(t, results[0].failovers, 1)
	// B takes no more work in this run: C built the three recipes.
	testing.expect_value(t, results[1].machine, identity(world.c))
	testing.expect_value(t, results[2].machine, identity(world.c))
	testing.expect_value(t, world.scheduler.counters.links_lost, 1)
	testing.expect_value(t, world.scheduler.links[0].state, machine_wire.Mesh_Link_State.Broken)
	for index in 0 ..< 3 {
		testing.expect_value(t, results[index].phase, Dag_Phase.Done)
	}

	// Both builders down: this machine builds the graph.
	world.network.lose_build_of = {}
	world.network.down = identity(world.b)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	world.network.lose_build_of = identity(world.c)
	policy = world_policy(world, .Cache_First)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, results[0].source, Distributed_Source.Local_Build)
	testing.expect_value(t, results[0].machine, identity(world.laptop))
	testing.expect_value(t, results[0].failovers, 2)
	testing.expect_value(t, world.local_builds, 1)

	// With no builder of this machine, the recipe is refused, and its
	// dependents with it.
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	dag_recipe_add(world.scheduler, &join, {{producer = 0, input_index = 0}})
	policy = world_policy(world, .Cache_First, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.No_Builder)
	testing.expect_value(t, results[1].refusal, Distributed_Refusal.Dependency_Failed)
	testing.expect(t, dag_output(world.scheduler, 1) == nil)
}

@(test)
distributed_verify_compares_two_machines :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	pool := world_pool(world)
	alpha := spec_make("alpha", .Blob, {"source"}, 1)

	// B and C give the same output.
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	policy := world_policy(world, .Verify, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	result := &world.scheduler.results[0]
	testing.expect(t, result.machine == identity(world.b) && result.second_machine == identity(world.c))
	testing.expect_value(t, result.second_output_hash, result.output_hash)
	testing.expect_value(t, world.scheduler.counters.verify_agreements, 1)

	// C is not deterministic: its output hash differs.
	world.c.behaviour = .Non_Deterministic
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Determinism_Mismatch)
	testing.expect_value(t, result.refusal, Distributed_Refusal.Determinism_Mismatch)
	testing.expect(t, result.output_hash != result.second_output_hash)
	testing.expect_value(t, result.machine, identity(world.b))
	testing.expect_value(t, result.second_machine, identity(world.c))
	testing.expect_value(t, world.scheduler.counters.determinism_mismatches, 1)
	world.c.behaviour = .Honest

	// One builder down: B and this machine compare.
	world.network.down = identity(world.c)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	policy = world_policy(world, .Verify)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, result.second_machine, identity(world.laptop))
	testing.expect_value(t, result.second_output_hash, result.output_hash)

	// One machine only: Verify refuses.
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	policy = world_policy(world, .Verify, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Verify_Needs_Two_Machines)
}

@(test)
distributed_verify_never_compares_one_machine_with_itself :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	alpha := spec_make("alpha", .Blob, {"source"}, 1)

	// A pool that names one builder twice is refused before any work.
	twice := [2]Distributed_Peer{{identity = identity(world.b), purpose = .Builder, uses = {.Roles, .Objects}}, {identity = identity(world.b), purpose = .Builder, uses = {.Roles, .Objects}}}
	refusal, bad_index := distributed_builder_init(world.scheduler, &world.laptop.peer, twice[:])
	testing.expect(t, refusal == .Bad_Peer && bad_index == 1)

	// One builder and no builder on this machine: refused, with no kept
	// output, and B built once only.
	single := [1]Distributed_Peer{{identity = identity(world.b), purpose = .Builder, uses = {.Roles, .Objects}}}
	refusal, _ = distributed_builder_init(world.scheduler, &world.laptop.peer, single[:])
	testing.expect_value(t, refusal, Distributed_Refusal.None)
	dag_recipe_add(world.scheduler, &alpha, nil)
	policy := world_policy(world, .Verify, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Verify_Needs_Two_Machines)
	testing.expect_value(t, world.scheduler.results[0].phase, Dag_Phase.Failed)
	testing.expect(t, dag_output(world.scheduler, 0) == nil)
	testing.expect_value(t, world.b.builds, 1)
	testing.expect_value(t, world.scheduler.counters.verify_agreements, 0)

	// The second builder runs the build and its link breaks: with no
	// builder on this machine, the recipe is refused, never kept unverified.
	pool := world_pool(world)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	world.network.lose_build_of = identity(world.c)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Verify_Needs_Two_Machines)
	testing.expect(t, dag_output(world.scheduler, 0) == nil)
	testing.expect_value(t, world.c.builds, 1)

	// With a builder on this machine, B and this machine compare.
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	policy = world_policy(world, .Verify)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	result := &world.scheduler.results[0]
	testing.expect_value(t, result.machine, identity(world.b))
	testing.expect_value(t, result.second_machine, identity(world.laptop))
	testing.expect(t, result.machine != result.second_machine)
	testing.expect_value(t, world.local_builds, 1)
	world.network.lose_build_of = {}

	// A changed bit of the second output in transit: refused before the
	// comparison, so no agreement is counted.
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	world.network.flip_object_of = identity(world.c)
	policy = world_policy(world, .Verify, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Hash_Mismatch)
	testing.expect_value(t, world.scheduler.counters.verify_agreements, 0)
	testing.expect(t, dag_output(world.scheduler, 0) == nil)
}

@(test)
distributed_pool_refuses_unpaired_and_ungranted_machines :: proc(t: ^testing.T) {
	world := world_make(t, grant_b_roles = false)
	defer world_free(world)
	scheduler := world.scheduler
	peer := &world.laptop.peer

	stranger := [1]Distributed_Peer{{identity = identity(world.e), purpose = .Builder, uses = {.Roles, .Objects}}}
	refusal, bad_index := distributed_builder_init(scheduler, peer, stranger[:])
	testing.expect(t, refusal == .Peer_Not_Paired && bad_index == 0)
	lacking := [2]Distributed_Peer{{identity = identity(world.c), purpose = .Builder, uses = {.Roles, .Objects}}, {identity = identity(world.d), purpose = .Cache, uses = {.Objects}}}
	refusal, bad_index = distributed_builder_init(scheduler, peer, lacking[:])
	testing.expect(t, refusal == .Peer_Lacks_Use && bad_index == 1)
	no_objects := [1]Distributed_Peer{{identity = identity(world.c), purpose = .Builder, uses = {.Roles}}}
	refusal, _ = distributed_builder_init(scheduler, peer, no_objects[:])
	testing.expect_value(t, refusal, Distributed_Refusal.Peer_Lacks_Use)
	bad := [?]Distributed_Peer {
		{identity = {}, purpose = .Builder, uses = {.Roles, .Objects}},
		{identity = identity(world.laptop), purpose = .Builder, uses = {.Roles, .Objects}},
		{identity = identity(world.c), purpose = .None, uses = {.Roles, .Objects}},
	}
	for item in bad {
		single := [1]Distributed_Peer{item}
		refusal, _ = distributed_builder_init(scheduler, peer, single[:])
		testing.expect_value(t, refusal, Distributed_Refusal.Bad_Peer)
	}
	twice := [2]Distributed_Peer{{identity = identity(world.c), purpose = .Builder, uses = {.Roles, .Objects}}, {identity = identity(world.c), purpose = .Cache, uses = {.Roles, .Objects}}}
	refusal, bad_index = distributed_builder_init(scheduler, peer, twice[:])
	testing.expect(t, refusal == .Bad_Peer && bad_index == 1)
	full: [DISTRIBUTED_PEER_CAPACITY + 1]Distributed_Peer
	refusal, _ = distributed_builder_init(scheduler, peer, full[:])
	testing.expect_value(t, refusal, Distributed_Refusal.Pool_Full)

	// B is paired, and its plan gives this machine no use Roles: B refuses
	// the call before it runs, leaves the run, and C builds.
	pool := world_pool(world)
	refusal, _ = distributed_builder_init(scheduler, peer, pool[:])
	testing.expect_value(t, refusal, Distributed_Refusal.None)
	alpha := spec_make("alpha", .Blob, {"source"}, 1)
	dag_recipe_add(scheduler, &alpha, nil)
	policy := world_policy(world, .Cache_First, local = false)
	testing.expect_value(t, distributed_build(scheduler, peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.b.builds, 0)
	testing.expect_value(t, scheduler.results[0].machine, identity(world.c))
	testing.expect_value(t, scheduler.counters.builders_refused, 1)
}

@(test)
distributed_graph_refuses_each_bad_edge :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	scheduler := world.scheduler
	pool := world_pool(world)
	distributed_builder_init(scheduler, &world.laptop.peer, pool[:])
	alpha := spec_make("alpha", .Blob, {"source"}, 1)
	join := spec_make("join", .Blob, {"alpha", "beta"}, 4)

	// A producer that is this recipe or a later one: the graph has no cycle.
	_, refusal := dag_recipe_add(scheduler, &join, {{producer = 0, input_index = 0}})
	testing.expect_value(t, refusal, Distributed_Refusal.Producer_Not_Earlier)
	dag_recipe_add(scheduler, &alpha, nil)
	_, refusal = dag_recipe_add(scheduler, &join, {{producer = 1, input_index = 0}})
	testing.expect_value(t, refusal, Distributed_Refusal.Producer_Not_Earlier)
	_, refusal = dag_recipe_add(scheduler, &join, {{producer = 0, input_index = 2}})
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Dependency_Input)
	_, refusal = dag_recipe_add(scheduler, &join, {{producer = 0, input_index = 0}, {producer = 0, input_index = 0}})
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Dependency_Input)
	broken := join
	broken.builder_hash = {}
	_, refusal = dag_recipe_add(scheduler, &broken, {{producer = 0, input_index = 0}})
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Recipe)
	// A placeholder hash of zero is allowed for an input that a producer fills.
	placeholder := join
	placeholder.inputs[0].hash = {}
	_, refusal = dag_recipe_add(scheduler, &placeholder, {{producer = 0, input_index = 0}})
	testing.expect_value(t, refusal, Distributed_Refusal.None)
	testing.expect_value(t, scheduler.recipe_count, 2)

	// The input of a producer whose output kind is not the kind of the input.
	tree := spec_make("tree", .Tree, {"source"}, 7)
	tree_index, _ := dag_recipe_add(scheduler, &tree, nil)
	wrong_kind := spec_make("wrong", .Blob, {"tree"}, 8)
	dag_recipe_add(scheduler, &wrong_kind, {{producer = u32(tree_index), input_index = 0}})
	policy := world_policy(world, .Cache_First)
	testing.expect_value(t, distributed_build(scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Bad_Dependency_Input)
	testing.expect_value(t, scheduler.results[3].refusal, Distributed_Refusal.Bad_Dependency_Input)
	testing.expect_value(t, scheduler.results[1].phase, Dag_Phase.Done)

	// The graph holds DAG_RECIPE_CAPACITY recipes, and not one more.
	distributed_builder_init(scheduler, &world.laptop.peer, pool[:])
	for index in 0 ..< DAG_RECIPE_CAPACITY {
		leaf := spec_make("leaf", .Blob, {"source"}, u8(index))
		_, add_refusal := dag_recipe_add(scheduler, &leaf, nil)
		testing.expect_value(t, add_refusal, Distributed_Refusal.None)
	}
	_, refusal = dag_recipe_add(scheduler, &alpha, nil)
	testing.expect_value(t, refusal, Distributed_Refusal.Graph_Full)
	// A bad mode builds nothing: the builds are still the three of alpha,
	// join and tree above.
	policy = world_policy(world, .None)
	testing.expect_value(t, distributed_build(scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Bad_Mode)
	testing.expect_value(t, world.b.builds + world.c.builds, 3)
}

// The local store of the tests: one realisation, whose bytes a test can damage.
@(private = "file")
Local_Store_Fixture :: struct {
	record:  object_cache.Realisation_Record,
	payload: [256]u8,
	length:  int,
}

@(private = "file")
local_store_fixture: Local_Store_Fixture

@(private = "file")
fixture_lookup :: proc "contextless" (recipe_hash: blake3.Hash, record: ^object_cache.Realisation_Record, payload: []u8, _: rawptr) -> (int, bool) {
	if local_store_fixture.record.recipe_hash != recipe_hash {
		return 0, false
	}
	record^ = local_store_fixture.record
	return copy(payload, local_store_fixture.payload[:local_store_fixture.length]), true
}

@(test)
distributed_graph_refuses_bad_counts_and_checks_the_local_store :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	alpha := spec_make("alpha", .Blob, {"source"}, 1)
	_, refusal := dag_recipe_add(nil, &alpha, nil)
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Recipe)
	_, refusal = dag_recipe_add(world.scheduler, nil, nil)
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Recipe)
	pool := world_pool(world)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	// A count of inputs past its bound is refused before any input is read,
	// also with a dependency that names an input under the bound.
	too_many := alpha
	too_many.input_count = pr.MAX_RECIPE_INPUTS + 1
	_, refusal = dag_recipe_add(world.scheduler, &too_many, nil)
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Recipe)
	too_many.input_count = max(u32)
	_, refusal = dag_recipe_add(world.scheduler, &too_many, nil)
	testing.expect_value(t, refusal, Distributed_Refusal.Bad_Recipe)
	testing.expect_value(t, world.scheduler.recipe_count, 0)

	// The local store answers with no build when its bytes hash to the
	// output hash of its realisation.
	sandbox, _ := pr.builder_sandbox_prepare(&alpha)
	local_store_fixture.length, _ = sim_build(&sandbox, local_store_fixture.payload[:], world.laptop)
	output_hash, _ := pr.recipe_hash_output(.Blob, local_store_fixture.payload[:local_store_fixture.length])
	local_store_fixture.record = object_cache.Realisation_Record{recipe_hash = sandbox.recipe_hash, output_hash = output_hash, output_kind = .Blob}
	dag_recipe_add(world.scheduler, &alpha, nil)
	policy := world_policy(world, .Cache_First, local = false)
	policy.local_lookup = fixture_lookup
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Local_Store)
	testing.expect_value(t, world.b.builds + world.c.builds, 0)

	// A damaged byte of the local store is never kept: the recipe is built.
	local_store_fixture.payload[0] ~= 1
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &alpha, nil)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Remote_Builder)
	testing.expect_value(t, world.scheduler.results[0].output_hash, output_hash)
	testing.expect_value(t, world.scheduler.counters.local_store_hits, 0)
}

@(test)
remote_build_arguments_cross_whole_and_refuse_damage :: proc(t: ^testing.T) {
	spec := spec_make("join", .Tree, {"alpha", "beta", "gamma"}, 9)
	buffer: [machine_wire.ROLE_ARGUMENT_LIMIT]u8
	bytes, refusal := remote_build_arguments_write(&spec, buffer[:])
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	decoded: pr.Recipe_Spec
	testing.expect_value(t, remote_build_arguments_read(bytes, &decoded), pr.Recipe_Refusal.None)
	original_hash, _ := pr.recipe_hash(&spec)
	decoded_hash, _ := pr.recipe_hash(&decoded)
	testing.expect_value(t, decoded_hash, original_hash)

	// Each damage: one byte short, one byte more, a reserved byte, a count
	// past its bound, an empty name, a name past the bytes.
	testing.expect(t, remote_build_arguments_read(bytes[:len(bytes) - 1], &decoded) != .None)
	longer: [machine_wire.ROLE_ARGUMENT_LIMIT + 1]u8
	copy(longer[:], bytes)
	testing.expect(t, remote_build_arguments_read(longer[:len(bytes) + 1], &decoded) != .None)
	testing.expect(t, remote_build_arguments_read(bytes[:REMOTE_BUILD_HEADER_SIZE - 1], &decoded) != .None)
	damaged: [machine_wire.ROLE_ARGUMENT_LIMIT]u8
	copy(damaged[:], bytes)
	damaged[60] = 1
	testing.expect_value(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded), pr.Recipe_Refusal.Nonzero_Padding)
	copy(damaged[:], bytes)
	byte_order.write_u32_little_endian(damaged[:], 52, pr.MAX_RECIPE_INPUTS + 1)
	testing.expect_value(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded), pr.Recipe_Refusal.Too_Many_Inputs)
	copy(damaged[:], bytes)
	byte_order.write_u32_little_endian(damaged[:], 56, pr.MAX_RECIPE_ARG_BYTES + 1)
	testing.expect_value(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded), pr.Recipe_Refusal.Arguments_Too_Large)
	copy(damaged[:], bytes)
	damaged[REMOTE_BUILD_HEADER_SIZE] = 0
	testing.expect_value(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded), pr.Recipe_Refusal.Invalid_Input_Name)
	copy(damaged[:], bytes)
	damaged[REMOTE_BUILD_HEADER_SIZE + 2] = 1
	testing.expect_value(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded), pr.Recipe_Refusal.Nonzero_Padding)
	copy(damaged[:], bytes)
	damaged[REMOTE_BUILD_HEADER_SIZE] = 200
	testing.expect(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded) != .None)
	copy(damaged[:], bytes)
	damaged[48] = 7
	testing.expect_value(t, remote_build_arguments_read(damaged[:len(bytes)], &decoded), pr.Recipe_Refusal.Bad_Output_Kind)

	// A recipe whose arguments do not fit one call is refused here; the
	// scheduler builds it on this machine.
	large := spec
	large.arguments_length = machine_wire.ROLE_ARGUMENT_LIMIT
	_, refusal = remote_build_arguments_write(&large, buffer[:])
	testing.expect_value(t, refusal, pr.Recipe_Refusal.Arguments_Too_Large)
	world := world_make(t)
	defer world_free(world)
	pool := world_pool(world)
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	large_leaf := spec_make("large", .Blob, {"source"}, 1)
	large_leaf.arguments_length = machine_wire.ROLE_ARGUMENT_LIMIT
	dag_recipe_add(world.scheduler, &large_leaf, nil)
	policy := world_policy(world, .Cache_First)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Local_Build)

	// The holder refuses an export that names nothing, and a lookup of
	// another size than a hash.
	result: [object_cache.REALISATION_WIRE_SIZE]u8
	_, _, outcome := remote_recipes_serve(&world.b.host, 0, nil, result[:])
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Operation_Unsupported)
	_, _, outcome = remote_recipes_serve(&world.b.host, 3, nil, result[:])
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Operation_Unsupported)
	_, _, outcome = remote_recipes_serve(&world.b.host, u32(Remote_Recipes_Export.Realisation_Lookup), []u8{1, 2}, result[:])
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Argument_Refused)
	_, _, outcome = remote_recipes_serve(&world.d.host, u32(Remote_Recipes_Export.Build), bytes, result[:])
	testing.expectf(t, call_outcome.effect_group_of(outcome) == .Nothing_Changed, "the build of d gives %v", outcome)
	// A result with no room for a record.
	_, _, outcome = remote_recipes_serve(&world.b.host, u32(Remote_Recipes_Export.Realisation_Lookup), nil, result[:1])
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Argument_Refused)
}

// One faulty cache never stops a build. Refused first: a cache that
// withholds the output, a cache whose output changes in transit, and a
// cache whose signature does not verify; each leaves the run and the next
// source gives the output. Cache_Only with every cache faulty names the
// last fault. Last: a second, honest cache gives the output after the
// faulty one.
@(test)
distributed_cache_first_skips_a_faulty_cache_peer :: proc(t: ^testing.T) {
	world := world_make(t)
	defer world_free(world)
	gamma := spec_make("gamma", .Blob, {"source"}, 3)
	cache_uses := machine_wire.Machine_Uses{.Roles, .Objects}

	// D gives the realisation and withholds the output: the builders of
	// the pool build the recipe.
	pool := world_pool(world)
	cache_prepare(world, &gamma, world.d)
	world.d.host.publish = nil
	distributed_builder_init(world.scheduler, &world.laptop.peer, pool[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	policy := world_policy(world, .Cache_First, local = false)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Remote_Builder)
	testing.expect_value(t, world.scheduler.counters.cache_faults, 1)
	testing.expect_value(t, world.scheduler.counters.cache_hits, 0)
	testing.expect(t, world.scheduler.peer_out[2], "the faulty cache leaves the run")
	world.d.host.publish = sim_publish

	// A pool with the faulty cache alone: this machine builds the recipe,
	// whatever the fault of the cache.
	only_cache := [1]Distributed_Peer{{identity = identity(world.d), purpose = .Cache, uses = cache_uses}}
	for fault in 0 ..< 3 {
		cache_prepare(world, &gamma, world.d)
		switch fault {
		case 0:
			world.d.host.publish = nil
		case 1:
			world.network.flip_object_of = identity(world.d)
		case 2:
			world.d.cache_record.signature[7] ~= 0x01
		}
		local_builds := world.local_builds
		distributed_builder_init(world.scheduler, &world.laptop.peer, only_cache[:])
		dag_recipe_add(world.scheduler, &gamma, nil)
		policy = world_policy(world, .Cache_First)
		testing.expectf(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000) == .None, "fault %d stopped the build", fault)
		testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Local_Build)
		testing.expect_value(t, world.local_builds, local_builds + 1)
		testing.expect_value(t, world.scheduler.counters.cache_faults, 1)
		world.d.host.publish = sim_publish
		world.network.flip_object_of = {}
	}

	// Cache_Only, and the one cache is faulty: the refusal names the fault.
	cache_prepare(world, &gamma, world.d)
	world.d.cache_record.signature[7] ~= 0x01
	distributed_builder_init(world.scheduler, &world.laptop.peer, only_cache[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	policy = world_policy(world, .Cache_Only)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.Bad_Signature)
	testing.expect(t, dag_output(world.scheduler, 0) == nil)

	// Last: D is faulty and C is an honest cache after it. Cache_Only takes
	// the output from C, and no machine builds.
	cache_prepare_on(world.c, &gamma, world.c)
	two_caches := [2]Distributed_Peer{{identity = identity(world.d), purpose = .Cache, uses = cache_uses}, {identity = identity(world.c), purpose = .Cache, uses = cache_uses}}
	builds := world.b.builds + world.c.builds + world.local_builds
	distributed_builder_init(world.scheduler, &world.laptop.peer, two_caches[:])
	dag_recipe_add(world.scheduler, &gamma, nil)
	testing.expect_value(t, distributed_build(world.scheduler, &world.laptop.peer, &policy, 100_000), Distributed_Refusal.None)
	testing.expect_value(t, world.scheduler.results[0].source, Distributed_Source.Cache_Peer)
	testing.expect_value(t, world.scheduler.results[0].machine, identity(world.c))
	testing.expect_value(t, world.scheduler.results[0].output_hash, world.c.cache_record.output_hash)
	testing.expect_value(t, world.scheduler.counters.cache_faults, 1)
	testing.expect_value(t, world.scheduler.counters.cache_hits, 1)
	testing.expect_value(t, world.b.builds + world.c.builds + world.local_builds, builds)
}
