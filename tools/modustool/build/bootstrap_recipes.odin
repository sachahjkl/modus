// Canonical reproducible bootstrap and C-world recipe catalog
// (src/md/features/bootstrap.md; src/md/features/recipes.md).
//
// Defines typed, content-addressed plans_recipes.Recipe_Spec and
// guest_builder.Guest_Build_Spec entries for:
//   - chibicc_stage1 and chibicc_stage2 (self-hosting C compiler with
//     Stage 1 == Stage 2 fixed-point hash verification);
//   - sqlite (amalgamation build plus SQLite self-test recipe);
//   - lua (Lua VM build plus Lua test suite recipe);
//   - zstd (zstd codec build plus round-trip verification recipe);
//   - live_bootstrap_chain (hex0 -> M2-Planet -> mes -> tcc -> gcc -> odin
//     guest-builder stage graph with topological dependency verification).
package build

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/guest_builder"
import "modus:contract/plans_recipes"

// Domain separation key for hashing a validated bootstrap recipe catalog.
BOOTSTRAP_RECIPE_CATALOG_DOMAIN :: "modus bootstrap recipe catalog v1"

// Number of stages in the canonical live-bootstrap guest chain.
LIVE_BOOTSTRAP_STAGE_COUNT :: 6

// Total canonical entries in the bootstrap recipe catalog.
BOOTSTRAP_RECIPE_CATALOG_COUNT :: 11

// Closed set of canonical bootstrap and C-world recipe identifiers.
Bootstrap_Recipe_Id :: enum u32 {
	None                     = 0,
	Chibicc_Stage1           = 1,
	Chibicc_Stage2           = 2,
	Sqlite                   = 3,
	Lua                      = 4,
	Zstd                     = 5,
	Live_Bootstrap_Hex0      = 6,
	Live_Bootstrap_M2_Planet = 7,
	Live_Bootstrap_Mes       = 8,
	Live_Bootstrap_Tcc       = 9,
	Live_Bootstrap_Gcc       = 10,
	Live_Bootstrap_Odin      = 11,
}

// Closed set of refusals returned when validating the recipe catalog or
// comparing two self-hosted compiler stages.
Bootstrap_Recipe_Catalog_Refusal :: enum u8 {
	None                          = 0,
	Empty_Catalog                 = 1,
	Invalid_Recipe_Id             = 2,
	Duplicate_Recipe_Id           = 3,
	Invalid_Recipe_Spec           = 4,
	Sandbox_Violation             = 5,
	Clock_Not_Frozen              = 6,
	Invalid_Guest_Spec            = 7,
	Guest_Network_Enabled         = 8,
	Guest_Real_Clock_Enabled      = 9,
	Guest_Writable_Inputs_Enabled = 10,
	Invalid_Self_Test_Recipe      = 11,
	Topological_Order_Violation   = 12,
	Zero_Stage_Hash               = 13,
	Fixed_Point_Mismatch          = 14,
}

// One canonical reproducible recipe entry in the bootstrap catalog.
Bootstrap_Recipe_Entry :: struct {
	id:                   Bootstrap_Recipe_Id,
	name:                 string,
	upstream_stage:       Bootstrap_Recipe_Id,
	recipe:               plans_recipes.Recipe_Spec,
	expected_output_hash: blake3.Hash,
	has_guest_spec:       bool,
	guest_spec:           guest_builder.Guest_Build_Spec,
	has_self_test_recipe: bool,
	self_test_recipe:     plans_recipes.Recipe_Spec,
}

// Single border converting a raw transport word into a Bootstrap_Recipe_Id.
bootstrap_recipe_id_from_word :: proc "contextless" (word: u64) -> (id: Bootstrap_Recipe_Id, ok: bool) {
	member := enum_word.member_of_word(Bootstrap_Recipe_Id, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

@(private = "file")
bootstrap_recipe_seed_hash :: proc "contextless" (label: string) -> blake3.Hash {
	return blake3.derive_key("modus bootstrap recipe input v1", transmute([]u8)label)
}

// bootstrap_verify_chibicc_fixed_point enforces the Stage 1 == Stage 2
// fixed-point hash equality invariant for self-hosting chibicc.
bootstrap_verify_chibicc_fixed_point :: proc "contextless" (stage1_output_hash, stage2_output_hash: blake3.Hash) -> Bootstrap_Recipe_Catalog_Refusal {
	if bootstrap_hash_is_zero(stage1_output_hash) || bootstrap_hash_is_zero(stage2_output_hash) {
		return .Zero_Stage_Hash
	}
	if stage1_output_hash != stage2_output_hash {
		return .Fixed_Point_Mismatch
	}
	return .None
}

// bootstrap_recipe_chibicc_self_host constructs the canonical Stage 1 and
// Stage 2 reproducible Recipe_Spec definitions for self-hosting chibicc.
bootstrap_recipe_chibicc_self_host :: proc() -> (stage1: Bootstrap_Recipe_Entry, stage2: Bootstrap_Recipe_Entry, ok: bool) {
	host_chibicc_hash := bootstrap_recipe_seed_hash("builder:chibicc-host-seed-v1")
	fixed_point_hash := bootstrap_recipe_seed_hash("output:chibicc-fixed-point-v1")
	chibicc_source_hash := bootstrap_recipe_seed_hash("source:chibicc-c-tree-v1")
	thin_libc_hash := bootstrap_recipe_seed_hash("source:modus-thin-libc-v1")
	assembler_hash := bootstrap_recipe_seed_hash("module:assemble-x86_64-v1")

	src_in, r0 := plans_recipes.recipe_input_make("chibicc_source", .Tree, chibicc_source_hash)
	libc_in, r1 := plans_recipes.recipe_input_make("thin_libc", .Tree, thin_libc_hash)
	asm_in, r2 := plans_recipes.recipe_input_make("assembler", .Blob, assembler_hash)
	if r0 != .None || r1 != .None || r2 != .None {
		return {}, {}, false
	}

	inputs := [3]plans_recipes.Recipe_Input{src_in, libc_in, asm_in}
	spec1, ok1 := bootstrap_make_recipe_spec(
		host_chibicc_hash,
		.Blob,
		0,
		4096,
		inputs[:],
		"target=modus-x86_64;stage=chibicc_stage1;date=epoch;verify_fixed_point=true",
	)
	spec2, ok2 := bootstrap_make_recipe_spec(
		fixed_point_hash,
		.Blob,
		0,
		4096,
		inputs[:],
		"target=modus-x86_64;stage=chibicc_stage2;date=epoch;verify_fixed_point=true",
	)
	if !ok1 || !ok2 {
		return {}, {}, false
	}

	stage1 = Bootstrap_Recipe_Entry {
		id                   = .Chibicc_Stage1,
		name                 = "chibicc_stage1",
		upstream_stage       = .None,
		recipe               = spec1,
		expected_output_hash = fixed_point_hash,
	}
	stage2 = Bootstrap_Recipe_Entry {
		id                   = .Chibicc_Stage2,
		name                 = "chibicc_stage2",
		upstream_stage       = .Chibicc_Stage1,
		recipe               = spec2,
		expected_output_hash = fixed_point_hash,
	}
	return stage1, stage2, true
}

// bootstrap_recipe_sqlite constructs the canonical reproducible SQLite
// amalgamation build recipe and its companion SQLite self-test recipe.
bootstrap_recipe_sqlite :: proc() -> (entry: Bootstrap_Recipe_Entry, ok: bool) {
	builder_hash := bootstrap_recipe_seed_hash("output:chibicc-fixed-point-v1")
	test_runner_hash := bootstrap_recipe_seed_hash("builder:modus-module-test-runner-v1")
	amalgamation_hash := bootstrap_recipe_seed_hash("source:sqlite-3.49-amalgamation")
	thin_libc_hash := bootstrap_recipe_seed_hash("source:modus-thin-libc-v1")
	sqlite_output_hash := bootstrap_recipe_seed_hash("output:sqlite.modus-v1")

	src_in, r0 := plans_recipes.recipe_input_make("sqlite_amalgamation", .Tree, amalgamation_hash)
	libc_in, r1 := plans_recipes.recipe_input_make("thin_libc", .Tree, thin_libc_hash)
	mod_in, r2 := plans_recipes.recipe_input_make("sqlite_module", .Blob, sqlite_output_hash)
	if r0 != .None || r1 != .None || r2 != .None {
		return {}, false
	}

	build_inputs := [2]plans_recipes.Recipe_Input{src_in, libc_in}
	build_spec, ok_build := bootstrap_make_recipe_spec(
		builder_hash,
		.Blob,
		0,
		16384,
		build_inputs[:],
		"recipe=sqlite;amalgamation=sqlite3.c;defines=SQLITE_OS_OTHER=1,SQLITE_THREADSAFE=0,SQLITE_OMIT_LOAD_EXTENSION=1",
	)
	test_inputs := [1]plans_recipes.Recipe_Input{mod_in}
	test_spec, ok_test := bootstrap_make_recipe_spec(
		test_runner_hash,
		.Blob,
		0,
		2048,
		test_inputs[:],
		"suite=sqlite_self_test;vectors=create_insert_select_sum,transaction_rollback,btree_index_scan",
	)
	if !ok_build || !ok_test {
		return {}, false
	}

	return Bootstrap_Recipe_Entry {
		id                   = .Sqlite,
		name                 = "sqlite",
		upstream_stage       = .Chibicc_Stage2,
		recipe               = build_spec,
		expected_output_hash = sqlite_output_hash,
		has_self_test_recipe = true,
		self_test_recipe     = test_spec,
	}, true
}

// bootstrap_recipe_lua constructs the canonical reproducible Lua VM build
// recipe and its companion Lua test suite recipe.
bootstrap_recipe_lua :: proc() -> (entry: Bootstrap_Recipe_Entry, ok: bool) {
	builder_hash := bootstrap_recipe_seed_hash("output:chibicc-fixed-point-v1")
	test_runner_hash := bootstrap_recipe_seed_hash("builder:modus-module-test-runner-v1")
	lua_source_hash := bootstrap_recipe_seed_hash("source:lua-5.4.7-freestanding")
	thin_libc_hash := bootstrap_recipe_seed_hash("source:modus-thin-libc-v1")
	lua_output_hash := bootstrap_recipe_seed_hash("output:lua.modus-v1")

	src_in, r0 := plans_recipes.recipe_input_make("lua_source", .Tree, lua_source_hash)
	libc_in, r1 := plans_recipes.recipe_input_make("thin_libc", .Tree, thin_libc_hash)
	mod_in, r2 := plans_recipes.recipe_input_make("lua_module", .Blob, lua_output_hash)
	if r0 != .None || r1 != .None || r2 != .None {
		return {}, false
	}

	build_inputs := [2]plans_recipes.Recipe_Input{src_in, libc_in}
	build_spec, ok_build := bootstrap_make_recipe_spec(
		builder_hash,
		.Blob,
		0,
		8192,
		build_inputs[:],
		"recipe=lua;defines=LUA_USE_C89=1,LUA_32BITS=0",
	)
	test_inputs := [1]plans_recipes.Recipe_Input{mod_in}
	test_spec, ok_test := bootstrap_make_recipe_spec(
		test_runner_hash,
		.Blob,
		0,
		2048,
		test_inputs[:],
		"suite=lua_test_suite;vectors=closures,coroutines,metatables,gc_cycle,integer_arithmetic",
	)
	if !ok_build || !ok_test {
		return {}, false
	}

	return Bootstrap_Recipe_Entry {
		id                   = .Lua,
		name                 = "lua",
		upstream_stage       = .Chibicc_Stage2,
		recipe               = build_spec,
		expected_output_hash = lua_output_hash,
		has_self_test_recipe = true,
		self_test_recipe     = test_spec,
	}, true
}

// bootstrap_recipe_zstd constructs the canonical reproducible zstd codec build
// recipe and its companion round-trip verification recipe.
bootstrap_recipe_zstd :: proc() -> (entry: Bootstrap_Recipe_Entry, ok: bool) {
	builder_hash := bootstrap_recipe_seed_hash("output:chibicc-fixed-point-v1")
	test_runner_hash := bootstrap_recipe_seed_hash("builder:modus-module-test-runner-v1")
	zstd_source_hash := bootstrap_recipe_seed_hash("source:zstd-1.5.7-freestanding")
	thin_libc_hash := bootstrap_recipe_seed_hash("source:modus-thin-libc-v1")
	zstd_output_hash := bootstrap_recipe_seed_hash("output:zstd.modus-v1")

	src_in, r0 := plans_recipes.recipe_input_make("zstd_source", .Tree, zstd_source_hash)
	libc_in, r1 := plans_recipes.recipe_input_make("thin_libc", .Tree, thin_libc_hash)
	mod_in, r2 := plans_recipes.recipe_input_make("zstd_module", .Blob, zstd_output_hash)
	if r0 != .None || r1 != .None || r2 != .None {
		return {}, false
	}

	build_inputs := [2]plans_recipes.Recipe_Input{src_in, libc_in}
	build_spec, ok_build := bootstrap_make_recipe_spec(
		builder_hash,
		.Blob,
		0,
		8192,
		build_inputs[:],
		"recipe=zstd;defines=ZSTD_STATIC_LINKING_ONLY=1,ZSTD_NO_ASM=1",
	)
	test_inputs := [1]plans_recipes.Recipe_Input{mod_in}
	test_spec, ok_test := bootstrap_make_recipe_spec(
		test_runner_hash,
		.Blob,
		0,
		2048,
		test_inputs[:],
		"suite=zstd_round_trip;vectors=empty,single_byte,compressible_4k,incompressible_4k,corrupt_frame_refusal",
	)
	if !ok_build || !ok_test {
		return {}, false
	}

	return Bootstrap_Recipe_Entry {
		id                   = .Zstd,
		name                 = "zstd",
		upstream_stage       = .Chibicc_Stage2,
		recipe               = build_spec,
		expected_output_hash = zstd_output_hash,
		has_self_test_recipe = true,
		self_test_recipe     = test_spec,
	}, true
}

// bootstrap_recipe_live_bootstrap_chain builds the 6-stage guest-builder graph:
//   hex0 -> M2-Planet -> mes -> tcc -> gcc -> odin
// with verified topological dependency order, read-only input mounts, zero
// network, and frozen epoch timestamp.
bootstrap_recipe_live_bootstrap_chain :: proc() -> (entries: [LIVE_BOOTSTRAP_STAGE_COUNT]Bootstrap_Recipe_Entry, ok: bool) {
	guest_kernel_hash := bootstrap_recipe_seed_hash("guest:linux-kernel-v1")
	guest_root_hash := bootstrap_recipe_seed_hash("guest:minimal-rootfs-v1")
	guest_builder_hash := bootstrap_recipe_seed_hash("module:guest-builder-v1")

	Stage_Def :: struct {
		id:           Bootstrap_Recipe_Id,
		name:         string,
		upstream:     Bootstrap_Recipe_Id,
		prev_input:   string,
		source_label: string,
		command:      string,
		memory_pages: u64,
		output_bound: u64,
	}

	stage_defs := [LIVE_BOOTSTRAP_STAGE_COUNT]Stage_Def {
		{
			id           = .Live_Bootstrap_Hex0,
			name         = "live_bootstrap_hex0",
			upstream     = .None,
			prev_input   = "",
			source_label = "source:hex0-seed-v1",
			command      = "/bin/hex0 /inputs/source/hex0_x86_64.hex0 /out/hex0",
			memory_pages = 2048,
			output_bound = 1 * 1024 * 1024,
		},
		{
			id           = .Live_Bootstrap_M2_Planet,
			name         = "live_bootstrap_m2_planet",
			upstream     = .Live_Bootstrap_Hex0,
			prev_input   = "hex0",
			source_label = "source:m2-planet-v1",
			command      = "/inputs/hex0/hex0 --build-m2-planet /inputs/source /out/m2-planet",
			memory_pages = 8192,
			output_bound = 4 * 1024 * 1024,
		},
		{
			id           = .Live_Bootstrap_Mes,
			name         = "live_bootstrap_mes",
			upstream     = .Live_Bootstrap_M2_Planet,
			prev_input   = "m2_planet",
			source_label = "source:mes-v1",
			command      = "/inputs/m2_planet/M2-Planet --build-mes /inputs/source /out/mes",
			memory_pages = 16384,
			output_bound = 8 * 1024 * 1024,
		},
		{
			id           = .Live_Bootstrap_Tcc,
			name         = "live_bootstrap_tcc",
			upstream     = .Live_Bootstrap_Mes,
			prev_input   = "mes",
			source_label = "source:tcc-v1",
			command      = "/inputs/mes/mescc --build-tcc /inputs/source /out/tcc",
			memory_pages = 16384,
			output_bound = 8 * 1024 * 1024,
		},
		{
			id           = .Live_Bootstrap_Gcc,
			name         = "live_bootstrap_gcc",
			upstream     = .Live_Bootstrap_Tcc,
			prev_input   = "tcc",
			source_label = "source:gcc-v1",
			command      = "/inputs/tcc/tcc --build-gcc /inputs/source /out/gcc",
			memory_pages = 131072,
			output_bound = 32 * 1024 * 1024,
		},
		{
			id           = .Live_Bootstrap_Odin,
			name         = "live_bootstrap_odin",
			upstream     = .Live_Bootstrap_Gcc,
			prev_input   = "gcc",
			source_label = "source:odin-fork-v1",
			command      = "/inputs/gcc/g++ --build-odin /inputs/source /out/odin",
			memory_pages = 262144,
			output_bound = 64 * 1024 * 1024,
		},
	}

	prev_output_hash: blake3.Hash
	for def, index in stage_defs {
		src_hash := bootstrap_recipe_seed_hash(def.source_label)
		src_in, r_src := plans_recipes.recipe_input_make("source", .Tree, src_hash)
		if r_src != .None {
			return {}, false
		}

		recipe_inputs: [2]plans_recipes.Recipe_Input
		recipe_input_count := 1
		recipe_inputs[0] = src_in

		mounts: [2]struct{path: string, hash: blake3.Hash}
		mount_count := 1
		mounts[0] = {path = "inputs/source", hash = src_hash}

		if def.prev_input != "" {
			prev_in, r_prev := plans_recipes.recipe_input_make(def.prev_input, .Tree, prev_output_hash)
			if r_prev != .None {
				return {}, false
			}
			recipe_inputs[1] = prev_in
			recipe_input_count = 2
			mounts[1] = {path = def.prev_input, hash = prev_output_hash}
			mount_count = 2
		}

		recipe, ok_rec := bootstrap_make_recipe_spec(
			guest_builder_hash,
			.Tree,
			0,
			def.output_bound / 4096,
			recipe_inputs[:recipe_input_count],
			def.command,
		)
		guest_spec, ok_guest := bootstrap_make_guest_spec(
			guest_kernel_hash,
			guest_root_hash,
			0,
			def.memory_pages,
			def.output_bound,
			def.command,
			mounts[:mount_count],
		)
		if !ok_rec || !ok_guest {
			return {}, false
		}

		stage_out_hash := bootstrap_recipe_seed_hash(def.name)
		entries[index] = Bootstrap_Recipe_Entry {
			id                   = def.id,
			name                 = def.name,
			upstream_stage       = def.upstream,
			recipe               = recipe,
			expected_output_hash = stage_out_hash,
			has_guest_spec       = true,
			guest_spec           = guest_spec,
		}
		prev_output_hash = stage_out_hash
	}

	return entries, true
}

// bootstrap_recipe_catalog returns all canonical bootstrap and C-world recipes
// in strict topological dependency order.
bootstrap_recipe_catalog :: proc() -> (entries: [BOOTSTRAP_RECIPE_CATALOG_COUNT]Bootstrap_Recipe_Entry, ok: bool) {
	ch1, ch2, ok_ch := bootstrap_recipe_chibicc_self_host()
	sq, ok_sq := bootstrap_recipe_sqlite()
	lu, ok_lu := bootstrap_recipe_lua()
	zs, ok_zs := bootstrap_recipe_zstd()
	chain, ok_chain := bootstrap_recipe_live_bootstrap_chain()
	if !ok_ch || !ok_sq || !ok_lu || !ok_zs || !ok_chain {
		return {}, false
	}

	entries[0] = ch1
	entries[1] = ch2
	entries[2] = sq
	entries[3] = lu
	entries[4] = zs
	for stage, idx in chain {
		entries[5 + idx] = stage
	}
	return entries, true
}

// bootstrap_recipe_catalog_verify validates every recipe entry in the catalog:
// closed enum ids, uniqueness, topological dependency ordering, frozen clock,
// plans_recipes.recipe_hash and Builder_Sandbox_Spec invariants, companion
// self-test recipes, and guest_builder sandbox invariants.
bootstrap_recipe_catalog_verify :: proc(entries: []Bootstrap_Recipe_Entry) -> (catalog_digest: blake3.Hash, refusal: Bootstrap_Recipe_Catalog_Refusal) {
	if len(entries) == 0 {
		return {}, .Empty_Catalog
	}

	// Pass 1: Validate every closed recipe identifier and reject duplicates
	// before checking topological dependencies.
	for entry, index in entries {
		checked_id, id_ok := bootstrap_recipe_id_from_word(u64(entry.id))
		if !id_ok {
			return {}, .Invalid_Recipe_Id
		}
		for earlier in 0 ..< index {
			if entries[earlier].id == checked_id {
				return {}, .Duplicate_Recipe_Id
			}
		}
	}

	digest_material := make([dynamic]u8, context.temp_allocator)

	// Pass 2: Enforce topological dependency order, frozen clock, recipe hash
	// validity, sandbox invariants, guest specs, and companion test recipes.
	for &entry, index in entries {
		checked_id, _ := bootstrap_recipe_id_from_word(u64(entry.id))
		if entry.upstream_stage != .None {
			found_earlier := false
			for earlier in 0 ..< index {
				if entries[earlier].id == entry.upstream_stage {
					found_earlier = true
					break
				}
			}
			if !found_earlier {
				return {}, .Topological_Order_Violation
			}
		}
		if bootstrap_hash_is_zero(entry.expected_output_hash) {
			return {}, .Zero_Stage_Hash
		}
		if entry.recipe.source_date_unix != 0 {
			return {}, .Clock_Not_Frozen
		}
		if rec_refusal, _ := plans_recipes.recipe_validate(&entry.recipe); rec_refusal != .None {
			return {}, .Invalid_Recipe_Spec
		}
		rec_hash, hash_refusal := plans_recipes.recipe_hash(&entry.recipe)
		if hash_refusal != .None {
			return {}, .Invalid_Recipe_Spec
		}
		sandbox, prep_refusal := plans_recipes.builder_sandbox_prepare(&entry.recipe)
		if prep_refusal != .None || plans_recipes.builder_sandbox_validate(&sandbox) != .None {
			return {}, .Sandbox_Violation
		}
		if sandbox.random_seed != rec_hash || !sandbox.inputs_read_only || sandbox.allow_network || sandbox.frozen_date_unix != 0 {
			return {}, .Sandbox_Violation
		}

		append(&digest_material, u8(checked_id))
		append(&digest_material, ..rec_hash[:])
		append(&digest_material, ..entry.expected_output_hash[:])

		if entry.has_guest_spec {
			if entry.guest_spec.allow_network {
				return {}, .Guest_Network_Enabled
			}
			if entry.guest_spec.allow_real_clock {
				return {}, .Guest_Real_Clock_Enabled
			}
			if entry.guest_spec.allow_writable_inputs {
				return {}, .Guest_Writable_Inputs_Enabled
			}
			if entry.guest_spec.frozen_epoch_seconds != 0 {
				return {}, .Clock_Not_Frozen
			}
			guest_hash, guest_refusal := guest_builder.build_spec_hash(&entry.guest_spec)
			if guest_refusal != .None {
				return {}, .Invalid_Guest_Spec
			}
			append(&digest_material, ..guest_hash[:])
		}

		if entry.has_self_test_recipe {
			if entry.self_test_recipe.source_date_unix != 0 {
				return {}, .Clock_Not_Frozen
			}
			test_hash, test_refusal := plans_recipes.recipe_hash(&entry.self_test_recipe)
			if test_refusal != .None {
				return {}, .Invalid_Self_Test_Recipe
			}
			test_sandbox, test_prep := plans_recipes.builder_sandbox_prepare(&entry.self_test_recipe)
			if test_prep != .None || plans_recipes.builder_sandbox_validate(&test_sandbox) != .None {
				return {}, .Sandbox_Violation
			}
			append(&digest_material, ..test_hash[:])
		}
	}

	return blake3.derive_key(BOOTSTRAP_RECIPE_CATALOG_DOMAIN, digest_material[:]), .None
}
