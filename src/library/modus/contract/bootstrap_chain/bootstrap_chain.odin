// Shared contract for seed-to-Odin and C compiler self-hosting bootstrap
// recipe graphs (src/md/features/bootstrap.md and src/md/features/c_compiler.md).
//
// Pure freestanding contract package: no kernel calls, no host imports, and
// no dynamic allocation. Validates acyclic stage DAGs, hex0 seed size audit
// bounds, multi-file C self-host workspace bounds, and constant-time host
// equivalence hash verification across the full bootstrap chain.
package bootstrap_chain

import "modus:contract/blake3"
import "modus:contract/enum_word"

// Format property: bootstrap stage identifier maximum UTF-8 length.
STAGE_NAME_BYTES :: 48

// Plan value: maximum direct upstream stage dependencies per bootstrap stage.
STAGE_MAX_DEPS :: 8

// Plan value: maximum source file hashes recorded on a multi-file C self-host
// or library build stage (covers chibicc's 14 sources plus assembly/headers).
STAGE_MAX_SOURCES :: 32

// Plan value: maximum stages in one bootstrap chain (covers hex0 ->
// live-bootstrap -> odin_fork and c_compiler -> chibicc -> sqlite/lua/zstd).
CHAIN_MAX_STAGES :: 32

// Format property: audit bound on a Seed_Hex0 bootstrap seed so a human reader
// can inspect every byte of the root of trust (at most 1024 bytes).
HEX0_SEED_MAX_BYTES :: 1024

// Format property: minimum assembler/compiler workspace required to self-host
// chibicc (295 KiB program size per src/md/features/bootstrap.md).
CHIBICC_WORKSPACE_MIN_BYTES :: 295 * 1024

// Closed set of bootstrap recipe stage kinds. Values cross borders explicitly.
Bootstrap_Stage_Kind :: enum u8 {
	Seed_Hex0           = 1,
	Live_Bootstrap_Tool = 2,
	C_Self_Host_Stage   = 3,
	Odin_Fork_Stage     = 4,
	Library_Build_Stage = 5,
}

// Closed set of outcomes returned by bootstrap chain construction, DAG
// validation, and host equivalence verification.
Bootstrap_Refusal :: enum u8 {
	None                  = 0,
	Null_Chain            = 1,
	Empty_Chain           = 2,
	Capacity_Full         = 3,
	Duplicate_Stage       = 4,
	Empty_Stage_Name      = 5,
	Name_Too_Long         = 6,
	Bad_Stage_Kind        = 7,
	Zero_Hash             = 8,
	Unknown_Dependency    = 9,
	Cycle_Detected        = 10,
	Seed_Too_Large        = 11,
	Seed_Has_Dependencies = 12,
	Workspace_Too_Small   = 13,
	Missing_Sources       = 14,
	Host_Mismatch         = 15,
	Output_Count_Mismatch = 16,
	Self_Dependency       = 17,
	Bad_Control_Byte      = 18,
	Output_Too_Small      = 19,
	Duplicate_Dependency  = 20,
}

// Descriptor of one stage in a bootstrap chain DAG.
Bootstrap_Stage_Spec :: struct {
	name:                 [STAGE_NAME_BYTES]u8,
	name_len:             u16,
	kind:                 Bootstrap_Stage_Kind,
	dep_indices:          [STAGE_MAX_DEPS]u16,
	dep_count:            u8,
	input_recipe_hash:    blake3.Hash,
	expected_output_hash: blake3.Hash,
	seed_bytes:           u32,
	source_hashes:        [STAGE_MAX_SOURCES]blake3.Hash,
	source_count:         u8,
	workspace_bytes:      u32,
}

// Directed acyclic graph of bootstrap stages from seed to compiler/libraries.
Bootstrap_Chain :: struct {
	stages: [CHAIN_MAX_STAGES]Bootstrap_Stage_Spec,
	count:  u16,
}

// Result of verifying observed stage output hashes against host reference hashes.
Host_Equivalence_Report :: struct {
	verified_stages:      u16,
	first_mismatch_stage: u16,
	matched:              bool,
	refusal:              Bootstrap_Refusal,
}

// bootstrap_stage_kind_of_word converts a transport word into Bootstrap_Stage_Kind
// at a border, refusing any word that names no member.
bootstrap_stage_kind_of_word :: proc "contextless" (word: u64) -> (kind: Bootstrap_Stage_Kind, ok: bool) {
	return enum_word.member_of_word(Bootstrap_Stage_Kind, word)
}

// bootstrap_stage_name returns the stage name slice of `stage`.
bootstrap_stage_name :: proc "contextless" (stage: ^Bootstrap_Stage_Spec) -> string {
	if stage == nil || int(stage.name_len) > STAGE_NAME_BYTES {
		return ""
	}
	return string(stage.name[:stage.name_len])
}

// bootstrap_stage_make builds one validated Bootstrap_Stage_Spec header.
bootstrap_stage_make :: proc "contextless" (
	name: string,
	kind: Bootstrap_Stage_Kind,
	input_recipe_hash: blake3.Hash,
	expected_output_hash: blake3.Hash,
) -> (stage: Bootstrap_Stage_Spec, refusal: Bootstrap_Refusal) {
	if _, ok := enum_word.member_of_argument(kind); !ok {
		return {}, .Bad_Stage_Kind
	}
	if len(name) == 0 {
		return {}, .Empty_Stage_Name
	}
	if len(name) > STAGE_NAME_BYTES {
		return {}, .Name_Too_Long
	}
	if !stage_name_clean(name) {
		return {}, .Bad_Control_Byte
	}
	if hash_is_zero(input_recipe_hash) || hash_is_zero(expected_output_hash) {
		return {}, .Zero_Hash
	}

	out := Bootstrap_Stage_Spec{
		name_len             = u16(len(name)),
		kind                 = kind,
		input_recipe_hash    = input_recipe_hash,
		expected_output_hash = expected_output_hash,
	}
	copy(out.name[:len(name)], name)
	return out, .None
}

// bootstrap_stage_add_dep appends an upstream stage index dependency, refusing
// duplicates and capacity overflow without mutating `stage`.
bootstrap_stage_add_dep :: proc "contextless" (stage: ^Bootstrap_Stage_Spec, dep_index: u16) -> Bootstrap_Refusal {
	if stage == nil {
		return .Null_Chain
	}
	if stage.kind == .Seed_Hex0 {
		return .Seed_Has_Dependencies
	}
	if int(stage.dep_count) >= STAGE_MAX_DEPS {
		return .Capacity_Full
	}
	for i in 0 ..< int(stage.dep_count) {
		if stage.dep_indices[i] == dep_index {
			return .Duplicate_Dependency
		}
	}
	stage.dep_indices[stage.dep_count] = dep_index
	stage.dep_count += 1
	return .None
}

// bootstrap_stage_add_source appends one pinned source BLAKE3 hash to `stage`.
bootstrap_stage_add_source :: proc "contextless" (stage: ^Bootstrap_Stage_Spec, source_hash: blake3.Hash) -> Bootstrap_Refusal {
	if stage == nil {
		return .Null_Chain
	}
	if hash_is_zero(source_hash) {
		return .Zero_Hash
	}
	if int(stage.source_count) >= STAGE_MAX_SOURCES {
		return .Capacity_Full
	}
	stage.source_hashes[stage.source_count] = source_hash
	stage.source_count += 1
	return .None
}

// bootstrap_chain_add_stage appends `stage` to `chain` after validating its
// identity and checking for duplicate stage names or capacity exhaustion.
bootstrap_chain_add_stage :: proc "contextless" (
	chain: ^Bootstrap_Chain,
	stage: Bootstrap_Stage_Spec,
) -> (index: u16, refusal: Bootstrap_Refusal) {
	if chain == nil {
		return 0, .Null_Chain
	}
	local_stage := stage
	if err := validate_stage_fields(&local_stage); err != .None {
		return 0, err
	}
	if int(chain.count) >= CHAIN_MAX_STAGES {
		return 0, .Capacity_Full
	}
	new_name := string(local_stage.name[:local_stage.name_len])
	for i in 0 ..< int(chain.count) {
		if bootstrap_stage_name(&chain.stages[i]) == new_name {
			return 0, .Duplicate_Stage
		}
	}
	idx := chain.count
	chain.stages[idx] = local_stage
	chain.count += 1
	return idx, .None
}

// bootstrap_chain_validate checks every stage invariant, verifies all upstream
// dependencies resolve inside the chain with no self-edges or cycles, and
// writes the deterministic topological order into `topo_order_out` when non-nil.
// On any refusal, `topo_order_out` is not modified.
bootstrap_chain_validate :: proc "contextless" (
	chain: ^Bootstrap_Chain,
	topo_order_out: []u16 = nil,
) -> (topo_count: int, refusal: Bootstrap_Refusal) {
	if chain == nil {
		return 0, .Null_Chain
	}
	if chain.count == 0 {
		return 0, .Empty_Chain
	}
	if int(chain.count) > CHAIN_MAX_STAGES {
		return 0, .Capacity_Full
	}
	n := int(chain.count)
	if topo_order_out != nil && len(topo_order_out) < n {
		return 0, .Output_Too_Small
	}

	// Validate each stage and check name uniqueness and dependency edges.
	in_degree: [CHAIN_MAX_STAGES]u8
	for i in 0 ..< n {
		st := &chain.stages[i]
		if err := validate_stage_fields(st); err != .None {
			return 0, err
		}
		for j in i + 1 ..< n {
			if bootstrap_stage_name(st) == bootstrap_stage_name(&chain.stages[j]) {
				return 0, .Duplicate_Stage
			}
		}
		if int(st.dep_count) > STAGE_MAX_DEPS {
			return 0, .Capacity_Full
		}
		for d in 0 ..< int(st.dep_count) {
			dep := int(st.dep_indices[d])
			if dep == i {
				return 0, .Self_Dependency
			}
			if dep >= n {
				return 0, .Unknown_Dependency
			}
			for prev in 0 ..< d {
				if int(st.dep_indices[prev]) == dep {
					return 0, .Duplicate_Dependency
				}
			}
			in_degree[i] += 1
		}
	}

	// Deterministic Kahn topological sort (lowest stage index first).
	order: [CHAIN_MAX_STAGES]u16
	visited: [CHAIN_MAX_STAGES]bool
	processed := 0
	for processed < n {
		picked := -1
		for i in 0 ..< n {
			if !visited[i] && in_degree[i] == 0 {
				picked = i
				break
			}
		}
		if picked < 0 {
			return 0, .Cycle_Detected
		}
		visited[picked] = true
		order[processed] = u16(picked)
		processed += 1

		// Decrement in-degree of every stage depending on `picked`.
		for downstream in 0 ..< n {
			if visited[downstream] {
				continue
			}
			ds := &chain.stages[downstream]
			for d in 0 ..< int(ds.dep_count) {
				if int(ds.dep_indices[d]) == picked {
					in_degree[downstream] -= 1
				}
			}
		}
	}

	if topo_order_out != nil {
		copy(topo_order_out[:n], order[:n])
	}
	return n, .None
}

// hashes_equal_constant_time compares two 32-byte BLAKE3 hashes without
// data-dependent early exit.
hashes_equal_constant_time :: proc "contextless" (a, b: blake3.Hash) -> bool {
	diff: u8 = 0
	for i in 0 ..< blake3.HASH_SIZE {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}

// bootstrap_chain_verify_host_equivalence validates the chain DAG and checks
// every stage's observed output hash against its expected host reference hash
// in topological order using constant-time hash comparison.
bootstrap_chain_verify_host_equivalence :: proc "contextless" (
	chain: ^Bootstrap_Chain,
	observed_outputs: []blake3.Hash,
) -> Host_Equivalence_Report {
	order: [CHAIN_MAX_STAGES]u16
	topo_n, ref := bootstrap_chain_validate(chain, order[:])
	if ref != .None {
		return {refusal = ref}
	}
	if len(observed_outputs) != topo_n {
		return {refusal = .Output_Count_Mismatch}
	}

	verified: u16 = 0
	for k in 0 ..< topo_n {
		stage_idx := order[k]
		expected := chain.stages[stage_idx].expected_output_hash
		if !hashes_equal_constant_time(observed_outputs[stage_idx], expected) {
			return {
				verified_stages      = verified,
				first_mismatch_stage = stage_idx,
				matched              = false,
				refusal              = .Host_Mismatch,
			}
		}
		verified += 1
	}
	return {
		verified_stages = verified,
		matched         = true,
		refusal         = .None,
	}
}

// ---- Private helpers.

@(private = "file")
hash_is_zero :: proc "contextless" (h: blake3.Hash) -> bool {
	acc: u8 = 0
	for b in h {
		acc |= b
	}
	return acc == 0
}

@(private = "file")
stage_name_clean :: proc "contextless" (name: string) -> bool {
	for i in 0 ..< len(name) {
		b := name[i]
		if b < 0x20 || b == 0x7F {
			return false
		}
	}
	return true
}

@(private = "file")
validate_stage_fields :: proc "contextless" (st: ^Bootstrap_Stage_Spec) -> Bootstrap_Refusal {
	if _, ok := enum_word.member_of_argument(st.kind); !ok {
		return .Bad_Stage_Kind
	}
	if st.name_len == 0 {
		return .Empty_Stage_Name
	}
	if int(st.name_len) > STAGE_NAME_BYTES {
		return .Name_Too_Long
	}
	if !stage_name_clean(string(st.name[:st.name_len])) {
		return .Bad_Control_Byte
	}
	if hash_is_zero(st.input_recipe_hash) || hash_is_zero(st.expected_output_hash) {
		return .Zero_Hash
	}
	if int(st.source_count) > STAGE_MAX_SOURCES {
		return .Capacity_Full
	}
	for s in 0 ..< int(st.source_count) {
		if hash_is_zero(st.source_hashes[s]) {
			return .Zero_Hash
		}
	}

	switch st.kind {
	case .Seed_Hex0:
		if st.seed_bytes == 0 || st.seed_bytes > HEX0_SEED_MAX_BYTES {
			return .Seed_Too_Large
		}
		if st.dep_count > 0 {
			return .Seed_Has_Dependencies
		}
	case .C_Self_Host_Stage:
		if st.workspace_bytes < CHIBICC_WORKSPACE_MIN_BYTES {
			return .Workspace_Too_Small
		}
		if st.source_count == 0 {
			return .Missing_Sources
		}
	case .Live_Bootstrap_Tool, .Odin_Fork_Stage, .Library_Build_Stage:
	}
	return .None
}
