package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modustool:foundation"

@(private = "file")
bootstrap_test_temp_dir :: proc(t: ^testing.T, label: string) -> string {
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.tprintf("%s/modus_bootstrap_test_%s_%d", strings.trim_right(temp_base, "/"), label, os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "must create bootstrap test temporary directory")
	return dir
}

@(private = "file")
bootstrap_test_run_command :: proc(command: []string, working_dir: string) -> (ok: bool) {
	child, start_err := os.process_start({
		command     = command,
		working_dir = working_dir,
		stdin       = os.stdin,
		stdout      = os.stderr,
		stderr      = os.stderr,
	})
	if start_err != nil {
		return false
	}
	state, wait_err := os.process_wait(child)
	return wait_err == nil && state.success
}

// Adversarial edge cases for binary comparison and exact first-divergence
// byte offset reporting: 0 bytes, 1 byte, first byte, middle byte, last byte,
// and length mismatches in both directions.
@(test)
bootstrap_compare_stage_binaries_edges_and_offsets :: proc(t: ^testing.T) {
	// Empty binaries must always be refused even when both are empty.
	empty_both := bootstrap_compare_stage_binaries(nil, nil)
	testing.expect(t, !empty_both.equal, "two empty binaries must not satisfy fixed point")
	testing.expect_value(t, empty_both.status, Self_Host_Comparison_Status.Empty_Binary)
	testing.expect_value(t, empty_both.first_diverging_byte_offset, 0)

	one_byte := [1]u8{0x7F}
	empty_left := bootstrap_compare_stage_binaries(nil, one_byte[:])
	testing.expect(t, !empty_left.equal)
	testing.expect_value(t, empty_left.status, Self_Host_Comparison_Status.Empty_Binary)

	empty_right := bootstrap_compare_stage_binaries(one_byte[:], nil)
	testing.expect(t, !empty_right.equal)
	testing.expect_value(t, empty_right.status, Self_Host_Comparison_Status.Empty_Binary)

	// Single equal byte succeeds.
	one_equal := bootstrap_compare_stage_binaries(one_byte[:], one_byte[:])
	testing.expect(t, one_equal.equal)
	testing.expect_value(t, one_equal.status, Self_Host_Comparison_Status.Equal)
	testing.expect_value(t, one_equal.first_diverging_byte_offset, -1)
	testing.expect(t, one_equal.stage_one_hash == one_equal.stage_two_hash)

	// First byte divergence (offset 0).
	a := [?]u8{0x01, 0x02, 0x03, 0x04, 0x05}
	b := [?]u8{0xFF, 0x02, 0x03, 0x04, 0x05}
	diff_zero := bootstrap_compare_stage_binaries(a[:], b[:])
	testing.expect(t, !diff_zero.equal)
	testing.expect_value(t, diff_zero.status, Self_Host_Comparison_Status.Byte_Mismatch)
	testing.expect_value(t, diff_zero.first_diverging_byte_offset, 0)
	testing.expect_value(t, diff_zero.stage_one_byte, u8(0x01))
	testing.expect_value(t, diff_zero.stage_two_byte, u8(0xFF))
	testing.expect(t, diff_zero.has_byte_values)

	// Middle byte divergence (offset 2).
	c := [?]u8{0x01, 0x02, 0xAA, 0x04, 0x05}
	diff_mid := bootstrap_compare_stage_binaries(a[:], c[:])
	testing.expect(t, !diff_mid.equal)
	testing.expect_value(t, diff_mid.status, Self_Host_Comparison_Status.Byte_Mismatch)
	testing.expect_value(t, diff_mid.first_diverging_byte_offset, 2)
	testing.expect_value(t, diff_mid.stage_one_byte, u8(0x03))
	testing.expect_value(t, diff_mid.stage_two_byte, u8(0xAA))

	// Last byte divergence (offset 4).
	d := [?]u8{0x01, 0x02, 0x03, 0x04, 0x06}
	diff_last := bootstrap_compare_stage_binaries(a[:], d[:])
	testing.expect(t, !diff_last.equal)
	testing.expect_value(t, diff_last.status, Self_Host_Comparison_Status.Byte_Mismatch)
	testing.expect_value(t, diff_last.first_diverging_byte_offset, 4)

	// Prefix-equal size mismatch (N vs N+1 and N+1 vs N).
	longer := [?]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x00}
	diff_short := bootstrap_compare_stage_binaries(a[:], longer[:])
	testing.expect(t, !diff_short.equal)
	testing.expect_value(t, diff_short.status, Self_Host_Comparison_Status.Size_Mismatch)
	testing.expect_value(t, diff_short.first_diverging_byte_offset, len(a))
	testing.expect(t, !diff_short.has_byte_values)

	diff_long := bootstrap_compare_stage_binaries(longer[:], a[:])
	testing.expect(t, !diff_long.equal)
	testing.expect_value(t, diff_long.status, Self_Host_Comparison_Status.Size_Mismatch)
	testing.expect_value(t, diff_long.first_diverging_byte_offset, len(a))
}

// Closed enum borders must refuse 0 (None), one past the highest member,
// and maximum integer bounds.
@(test)
bootstrap_enum_borders_refuse_invalid_words :: proc(t: ^testing.T) {
	bad_words := [?]u64{0, 4, 255, max(u64)}
	for word in bad_words {
		_, stage_ok := bootstrap_stage_kind_of_word(word)
		testing.expectf(t, !stage_ok, "stage kind %d must be refused", word)
		_, chain_ok := bootstrap_chain_kind_of_word(word)
		testing.expectf(t, !chain_ok, "chain kind %d must be refused", word)
	}
	for word in ([?]u64{0, 3, 255, max(u64)}) {
		_, bind_ok := bootstrap_dependency_binding_of_word(word)
		testing.expectf(t, !bind_ok, "dependency binding %d must be refused", word)
	}
	for valid in ([?]u64{1, 2, 3}) {
		_, stage_ok := bootstrap_stage_kind_of_word(valid)
		testing.expect(t, stage_ok)
		_, chain_ok := bootstrap_chain_kind_of_word(valid)
		testing.expect(t, chain_ok)
	}
	for valid in ([?]u64{1, 2}) {
		_, bind_ok := bootstrap_dependency_binding_of_word(valid)
		testing.expect(t, bind_ok)
	}
}

// Exercises a genuine two-stage Odin self-hosting cycle on a minimal self-hosting
// Odin tool: stage0 builds stage1/mini_tool, executes stage1/mini_tool to build
// stage2/mini_tool in an isolated directory with identical deterministic flags,
// and proves blake3(stage1) == blake3(stage2).
@(test)
bootstrap_real_two_stage_self_host_fixed_point :: proc(t: ^testing.T) {
	temp_root := bootstrap_test_temp_dir(t, "selfhost_mini")
	defer _ = os.remove_all(temp_root)

	source_dir := foundation.join(temp_root, "/mini_tool")
	staging_dir := foundation.join(temp_root, "/staging")
	testing.expect(t, os.make_directory_all(source_dir) == nil, "must create mini_tool source dir")

	mini_tool_source := fmt.tprintf(`package mini_tool

import "core:os"
import "core:strings"

SOURCE_DIR :: %q

main :: proc() {{
	_ = os.unset_env("NIX_LDFLAGS")
	_ = os.set_env("SOURCE_DATE_EPOCH", "0")
	if len(os.args) == 3 && os.args[1] == "--emit-binary" {{
		out_flag := strings.concatenate({{"-out:", os.args[2]}}, context.temp_allocator)
		cmd := [?]string{{
			"odin",
			"build",
			SOURCE_DIR,
			"-vet",
			"-collection:modus=src/library/modus",
			"-collection:internal=src/library/internal",
			"-collection:modulus=src/modulus",
			"-collection:modustool=tools/modustool",
			"-custom-attribute:log_fact,enum_getters,member_texts,parameter_ranges,parameter_choices,parameter_instances",
			"-define:TOOL_BUILDS_ITSELF=false",
			"-source-code-locations:filename",
			"-use-single-module",
			"-extra-linker-flags:-Wl,--build-id=none",
			out_flag,
		}}
		child, start_err := os.process_start({{command = cmd[:], stdin = os.stdin, stdout = os.stderr, stderr = os.stderr}})
		if start_err != nil {{
			os.exit(1)
		}}
		state, wait_err := os.process_wait(child)
		if wait_err != nil || !state.success {{
			os.exit(1)
		}}
		os.exit(0)
	}}
}}
`, source_dir)

	source_file := foundation.join(source_dir, "/main.odin")
	testing.expect(t, os.write_entire_file(source_file, transmute([]u8)mini_tool_source) == nil, "must write mini_tool/main.odin")

	report := bootstrap_self_host_modustool(Self_Host_Options {
		staging_directory = staging_dir,
		source_folder     = source_dir,
		binary_name       = "mini_tool",
	})
	testing.expectf(t, report.ok, "real two-stage Odin self-host must reach fixed point: %s", report.failure_message)
	testing.expect(t, report.comparison.equal)
	testing.expect_value(t, report.comparison.status, Self_Host_Comparison_Status.Equal)
	testing.expect(t, report.comparison.stage_one_size > 0)
	testing.expect_value(t, report.comparison.stage_one_size, report.comparison.stage_two_size)
	testing.expect(t, report.comparison.stage_one_hash == report.comparison.stage_two_hash)
	testing.expect(t, !bootstrap_hash_is_zero(report.comparison.stage_one_hash))

	// Adversarial check: flipping one byte in stage2 must be detected at that exact offset.
	s1_bytes, err1 := os.read_entire_file(report.stage_one_binary_path, context.allocator)
	testing.expect(t, err1 == nil)
	defer delete(s1_bytes)
	s2_bytes, err2 := os.read_entire_file(report.stage_two_binary_path, context.allocator)
	testing.expect(t, err2 == nil)
	defer delete(s2_bytes)

	flip_offset := len(s2_bytes) / 2
	s2_bytes[flip_offset] ~= 0x01
	tampered := bootstrap_compare_stage_binaries(s1_bytes, s2_bytes)
	testing.expect(t, !tampered.equal, "tampered stage2 binary must fail equality")
	testing.expect_value(t, tampered.status, Self_Host_Comparison_Status.Byte_Mismatch)
	testing.expect_value(t, tampered.first_diverging_byte_offset, flip_offset)
}

// Chain A: C compiler (chibicc) 3-stage self-host chain validation and
// adversarial refusal cases (mismatched stage1 != stage2, broken builder
// linkage, tampered seed bytes, non-frozen clock, self-comparison).
@(test)
bootstrap_chain_c_compiler_self_host_valid_and_adversarial :: proc(t: ^testing.T) {
	// Valid chain passes deterministically.
	chain_a := bootstrap_chain_c_compiler_self_host()
	result_a := bootstrap_chain_verify(&chain_a)
	testing.expectf(t, result_a.valid, "valid C self-host chain must pass: %s", result_a.detail)
	testing.expect_value(t, result_a.refusal, Bootstrap_Chain_Refusal.None)
	testing.expect_value(t, result_a.stage_count, 3)
	testing.expect_value(t, result_a.verified_recipes, 2)
	testing.expect_value(t, result_a.verified_guests, 0)
	testing.expect(t, !bootstrap_hash_is_zero(result_a.chain_digest))

	// Repeated verification produces identical chain digest.
	result_repeat := bootstrap_chain_verify(&chain_a)
	testing.expect(t, result_repeat.valid && result_repeat.chain_digest == result_a.chain_digest)

	// Adversarial: stage1 != stage2 fixed-point mismatch.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[2].output_hash[0] ~= 0xFF
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Fixed_Point_Hash_Mismatch)
	}

	// Adversarial: broken builder linkage from stage0 to stage1.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[1].recipe.builder_hash[31] ~= 0x01
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Builder_Linkage_Mismatch)
	}

	// Adversarial: broken builder linkage from stage1 to stage2.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[2].recipe.builder_hash[15] ~= 0x80
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Builder_Linkage_Mismatch)
	}

	// Adversarial: seed bytes do not match declared seed output hash.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[0].seed_bytes = transmute([]u8)string("tampered-seed-bytes")
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Seed_Hash_Mismatch)
	}

	// Adversarial: trivial self-comparison fixed point (stage1 == stage1) refused.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.fixed_point_stage_two = bad.fixed_point_stage_one
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Missing_Fixed_Point_Stage)
	}

	// Adversarial: unfrozen recipe clock refused.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[1].recipe.source_date_unix = 1_700_000_000
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Clock_Not_Frozen)
	}
}

// Chain B: Seed bootstrap via guest builder (hex0 -> stage0_posix -> mescc ->
// tcc -> gcc -> llvm_18 -> odin_fork) validation and adversarial refusal cases.
@(test)
bootstrap_chain_seed_guest_valid_and_adversarial :: proc(t: ^testing.T) {
	chain_b := bootstrap_chain_seed_guest_bootstrap()
	testing.expect(t, len(chain_b.stages[0].seed_bytes) > 0 && len(chain_b.stages[0].seed_bytes) <= BOOTSTRAP_HEX0_SEED_MAX_BYTES)

	result_b := bootstrap_chain_verify(&chain_b)
	testing.expectf(t, result_b.valid, "valid seed guest bootstrap chain must pass: %s", result_b.detail)
	testing.expect_value(t, result_b.refusal, Bootstrap_Chain_Refusal.None)
	testing.expect_value(t, result_b.stage_count, 7)
	testing.expect_value(t, result_b.verified_recipes, 6)
	testing.expect_value(t, result_b.verified_guests, 6)
	testing.expect(t, !bootstrap_hash_is_zero(result_b.chain_digest))

	// Adversarial: network-enabled guest stage must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.stages[3].guest_spec.allow_network = true
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Guest_Network_Enabled)
		testing.expect_value(t, ver.failing_stage_name, "tcc")
	}

	// Adversarial: real wall clock enabled on guest stage must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.stages[4].guest_spec.allow_real_clock = true
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Guest_Real_Clock_Enabled)
	}

	// Adversarial: writable inputs enabled on guest stage must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.stages[2].guest_spec.allow_writable_inputs = true
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Guest_Writable_Inputs_Enabled)
	}

	// Adversarial: non-frozen guest clock epoch must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.stages[5].guest_spec.frozen_epoch_seconds = 1
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Clock_Not_Frozen)
	}

	// Adversarial: broken recipe input hash linkage between stages must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.stages[4].recipe.inputs[0].hash[0] ~= 0x42
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Input_Linkage_Mismatch)
	}

	// Adversarial: broken guest mount hash linkage (while recipe input matches) must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.stages[5].guest_spec.inputs[0].tree_hash[7] ~= 0x01
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Guest_Input_Linkage_Mismatch)
	}

	// Adversarial: final odin_fork output hash disagrees with host build hash.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.expected_host_output_hash[0] ~= 0xAA
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Host_Comparison_Hash_Mismatch)
	}

	// Adversarial: zero host comparison hash must be refused.
	{
		bad := bootstrap_chain_seed_guest_bootstrap()
		bad.expected_host_output_hash = {}
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Host_Comparison_Hash_Mismatch)
	}
}

// Chain C: C-world validation recipes (SQLite, Lua, zstd) with parsed
// language-neutral module manifests and validation test vectors.
@(test)
bootstrap_chain_c_world_validation_valid_and_adversarial :: proc(t: ^testing.T) {
	chain_c := bootstrap_chain_c_world_validation()
	result_c := bootstrap_chain_verify(&chain_c)
	testing.expectf(t, result_c.valid, "valid C-world validation chain must pass: %s", result_c.detail)
	testing.expect_value(t, result_c.refusal, Bootstrap_Chain_Refusal.None)
	testing.expect_value(t, result_c.stage_count, 4)
	testing.expect_value(t, result_c.verified_recipes, 3)
	testing.expect_value(t, result_c.verified_manifests, 3)

	// Confirm each manifest parses as a library module with expected exports.
	for item in ([]struct{text: string, count: int}{
		{BOOTSTRAP_SQLITE_MANIFEST, 4},
		{BOOTSTRAP_LUA_MANIFEST, 3},
		{BOOTSTRAP_ZSTD_MANIFEST, 3},
	}) {
		parsed, problem := manifest_parse(item.text)
		testing.expect_value(t, problem, "")
		testing.expect(t, parsed.library)
		testing.expect_value(t, len(parsed.description.exports), item.count)
	}

	// Adversarial: invalid manifest on SQLite stage is refused.
	{
		bad := bootstrap_chain_c_world_validation()
		bad.stages[1].manifest_text = "module: INVALID-UPPERCASE\nabout: broken\n"
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Invalid_Module_Manifest)
	}

	// Adversarial: missing test vectors on Lua stage is refused.
	{
		bad := bootstrap_chain_c_world_validation()
		bad.stages[2].test_vectors = nil
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Missing_Test_Vectors)
	}

	// Adversarial: empty test vector export name on zstd stage is refused.
	{
		bad := bootstrap_chain_c_world_validation()
		bad_vectors := [1]Bootstrap_Test_Vector{{name = "bad_vec", export_name = ""}}
		bad.stages[3].test_vectors = bad_vectors[:]
		ver := bootstrap_chain_verify(&bad)
		testing.expect(t, !ver.valid)
		testing.expect_value(t, ver.refusal, Bootstrap_Chain_Refusal.Missing_Test_Vectors)
	}
}

// Structural DAG refusals: nil/empty chain, invalid names/duplicates,
// zero output hash, seed with dependency, missing/duplicate dependencies,
// 1/2/3-node cycles, and out-of-order topological sorting.
@(test)
bootstrap_chain_dag_structural_refusals :: proc(t: ^testing.T) {
	// Nil and empty chain.
	testing.expect_value(t, bootstrap_chain_verify(nil).refusal, Bootstrap_Chain_Refusal.Empty_Chain)
	empty := Bootstrap_Chain{name = "empty", kind = .C_Compiler_Self_Host}
	testing.expect_value(t, bootstrap_chain_verify(&empty).refusal, Bootstrap_Chain_Refusal.Empty_Chain)

	// Invalid chain kind.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.kind = .None
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Invalid_Chain_Kind)
	}

	// Invalid stage name and duplicate stage name.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[0].name = ""
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Invalid_Stage_Name)
	}
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[1].name = bad.stages[0].name
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Duplicate_Stage_Name)
	}

	// Zero output hash refused.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		bad.stages[1].output_hash = {}
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Zero_Output_Hash)
	}

	// Seed stage with dependency refused.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		dep := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "chibicc_stage_one", binding = .Builder}}
		bad.stages[0].dependencies = dep[:]
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Seed_Must_Have_No_Dependencies)
	}

	// Missing dependency refused.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		dep := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "nonexistent_stage", binding = .Builder}}
		bad.stages[1].dependencies = dep[:]
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Missing_Dependency)
	}

	// Duplicate dependency refused.
	{
		bad := bootstrap_chain_c_compiler_self_host()
		dup_deps := [2]Bootstrap_Stage_Dependency {
			{upstream_stage_name = "chibicc_host_seed", binding = .Builder},
			{upstream_stage_name = "chibicc_host_seed", binding = .Builder},
		}
		bad.stages[1].dependencies = dup_deps[:]
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Duplicate_Dependency)
	}

	// 1-node self cycle (stage1 -> stage1).
	{
		bad := bootstrap_chain_c_compiler_self_host()
		self_dep := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "chibicc_stage_one", binding = .Builder}}
		bad.stages[1].dependencies = self_dep[:]
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Cyclic_Dependency)
	}

	// 2-node cycle (stage1 -> stage2 -> stage1).
	{
		bad := bootstrap_chain_c_compiler_self_host()
		dep_to_two := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "chibicc_stage_two", binding = .Builder}}
		dep_to_one := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "chibicc_stage_one", binding = .Builder}}
		bad.stages[1].dependencies = dep_to_two[:]
		bad.stages[2].dependencies = dep_to_one[:]
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Cyclic_Dependency)
	}

	// 3-node cycle across three recipe stages (a -> b -> c -> a).
	{
		hash_a := blake3.hash(transmute([]u8)string("cycle-a"))
		hash_b := blake3.hash(transmute([]u8)string("cycle-b"))
		hash_c := blake3.hash(transmute([]u8)string("cycle-c"))
		rec_a, _ := bootstrap_make_recipe_spec(hash_c, .Blob, 0, 64, nil, "a")
		rec_b, _ := bootstrap_make_recipe_spec(hash_a, .Blob, 0, 64, nil, "b")
		rec_c, _ := bootstrap_make_recipe_spec(hash_b, .Blob, 0, 64, nil, "c")
		dep_c := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "stage_c", binding = .Builder}}
		dep_a := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "stage_a", binding = .Builder}}
		dep_b := [1]Bootstrap_Stage_Dependency{{upstream_stage_name = "stage_b", binding = .Builder}}
		stages := [3]Bootstrap_Stage_Spec {
			{name = "stage_a", kind = .Native_Recipe, dependencies = dep_c[:], recipe = rec_a, output_hash = hash_a},
			{name = "stage_b", kind = .Native_Recipe, dependencies = dep_a[:], recipe = rec_b, output_hash = hash_b},
			{name = "stage_c", kind = .Native_Recipe, dependencies = dep_b[:], recipe = rec_c, output_hash = hash_c},
		}
		cyclic := Bootstrap_Chain{name = "three_cycle", kind = .C_Compiler_Self_Host, stages = stages[:]}
		testing.expect_value(t, bootstrap_chain_verify(&cyclic).refusal, Bootstrap_Chain_Refusal.Cyclic_Dependency)
	}

	// Acyclic graph in wrong topological order (dependent appears before upstream).
	{
		bad := bootstrap_chain_c_compiler_self_host()
		// Swap stage 1 and stage 2 so stage 2 (depending on stage 1) appears earlier.
		bad.stages[1], bad.stages[2] = bad.stages[2], bad.stages[1]
		testing.expect_value(t, bootstrap_chain_verify(&bad).refusal, Bootstrap_Chain_Refusal.Invalid_Topological_Order)
	}
}

// Real freestanding multi-file C library compilation test using clang + ld.lld -r
// + convert_elf_with_manifest: compiles two separate C translation units
// (CRC32/Adler32 checksums + a register-stack mini-VM using loops, structs,
// pointers, and cross-TU function calls) into one verified .modus library module
// and proves deterministic byte-for-byte reproducibility across two builds.
@(test)
bootstrap_real_freestanding_multifile_c_to_modus_module :: proc(t: ^testing.T) {
	temp_root := bootstrap_test_temp_dir(t, "c_multifile")
	defer _ = os.remove_all(temp_root)

	header_source := `#ifndef LIBRARY_API_H
#define LIBRARY_API_H

typedef unsigned char uint8_t;
typedef unsigned int uint32_t;
typedef long long int64_t;
typedef unsigned long long uint64_t;

typedef struct {
	uint32_t crc;
	uint32_t adler_a;
	uint32_t adler_b;
	uint32_t steps;
} Checksum_State;

void checksum_state_init(Checksum_State *state, uint32_t seed);
void checksum_state_feed(Checksum_State *state, const uint8_t *bytes, uint32_t count);
uint64_t checksum_state_finalize(const Checksum_State *state);

#endif
`

	checksum_c := `#include "library_api.h"

static uint32_t crc32_step(uint32_t crc, uint8_t byte_value) {
	crc ^= (uint32_t)byte_value;
	for (uint32_t bit = 0; bit < 8; bit += 1) {
		uint32_t mask = -(crc & 1u);
		crc = (crc >> 1) ^ (0xEDB88320u & mask);
	}
	return crc;
}

void checksum_state_init(Checksum_State *state, uint32_t seed) {
	state->crc = ~seed;
	state->adler_a = 1u + (seed & 0xFFFFu);
	state->adler_b = 0u;
	state->steps = 0u;
}

void checksum_state_feed(Checksum_State *state, const uint8_t *bytes, uint32_t count) {
	for (uint32_t i = 0; i < count; i += 1) {
		uint8_t value = bytes[i];
		state->crc = crc32_step(state->crc, value);
		state->adler_a = (state->adler_a + (uint32_t)value) % 65521u;
		state->adler_b = (state->adler_b + state->adler_a) % 65521u;
		state->steps += 1u;
	}
}

uint64_t checksum_state_finalize(const Checksum_State *state) {
	uint32_t crc_out = ~state->crc;
	uint32_t adler_out = (state->adler_b << 16) | state->adler_a;
	return ((uint64_t)crc_out << 32) | (uint64_t)adler_out;
}

int64_t crc32_of_word(int64_t seed, int64_t word) {
	uint8_t buf[8];
	uint64_t u = (uint64_t)word;
	for (uint32_t i = 0; i < 8; i += 1) {
		buf[i] = (uint8_t)((u >> (i * 8u)) & 0xFFu);
	}
	Checksum_State st;
	checksum_state_init(&st, (uint32_t)seed);
	checksum_state_feed(&st, buf, 8u);
	return (int64_t)(~st.crc);
}

int64_t adler32_of_pair(int64_t first, int64_t second) {
	uint8_t buf[16];
	uint64_t a = (uint64_t)first;
	uint64_t b = (uint64_t)second;
	for (uint32_t i = 0; i < 8; i += 1) {
		buf[i] = (uint8_t)((a >> (i * 8u)) & 0xFFu);
		buf[8 + i] = (uint8_t)((b >> (i * 8u)) & 0xFFu);
	}
	Checksum_State st;
	checksum_state_init(&st, 0u);
	checksum_state_feed(&st, buf, 16u);
	return (int64_t)(((uint64_t)st.adler_b << 16) | (uint64_t)st.adler_a);
}
`

	mini_vm_c := `#include "library_api.h"

/* Loader populates this module's 32-byte BLAKE3 identity hash. */
uint8_t modus_own_hash[32];

typedef struct {
	int64_t regs[4];
	uint32_t pc;
} Mini_Vm;

typedef struct {
	uint8_t opcode;
	uint8_t dst;
	uint8_t src;
	int64_t imm;
} Vm_Instruction;

static int64_t run_vm_instructions(Mini_Vm *vm, const Vm_Instruction *code, uint32_t count) {
	for (uint32_t step = 0; step < 64u && vm->pc < count; step += 1) {
		const Vm_Instruction *ins = &code[vm->pc];
		uint8_t d = ins->dst & 3u;
		uint8_t s = ins->src & 3u;
		vm->pc += 1u;
		switch (ins->opcode) {
		case 1: /* LOAD_IMM */
			vm->regs[d] = ins->imm;
			break;
		case 2: /* ADD_REG */
			vm->regs[d] += vm->regs[s];
			break;
		case 3: /* MUL_IMM */
			vm->regs[d] *= ins->imm;
			break;
		case 4: /* XOR_REG */
			vm->regs[d] ^= vm->regs[s];
			break;
		case 5: /* HALT */
			return vm->regs[d];
		default:
			return -1;
		}
	}
	return vm->regs[0];
}

int64_t mini_vm_execute(int64_t base_value, int64_t multiplier) {
	Mini_Vm vm;
	vm.regs[0] = base_value;
	vm.regs[1] = multiplier;
	vm.regs[2] = 0;
	vm.regs[3] = 0;
	vm.pc = 0;

	Vm_Instruction program[5];
	program[0].opcode = 1; program[0].dst = 2; program[0].src = 0; program[0].imm = 7;
	program[1].opcode = 2; program[1].dst = 0; program[1].src = 2; program[1].imm = 0;
	program[2].opcode = 3; program[2].dst = 0; program[2].src = 0; program[2].imm = multiplier;
	program[3].opcode = 4; program[3].dst = 0; program[3].src = 1; program[3].imm = 0;
	program[4].opcode = 5; program[4].dst = 0; program[4].src = 0; program[4].imm = 0;

	int64_t vm_out = run_vm_instructions(&vm, program, 5u);

	uint8_t digest_input[8];
	uint64_t raw = (uint64_t)vm_out;
	for (uint32_t i = 0; i < 8; i += 1) {
		digest_input[i] = (uint8_t)((raw >> (i * 8u)) & 0xFFu);
	}
	Checksum_State st;
	checksum_state_init(&st, (uint32_t)base_value);
	checksum_state_feed(&st, digest_input, 8u);
	return (int64_t)(checksum_state_finalize(&st) ^ (uint64_t)vm_out);
}
`

	manifest_text := `module: c_checksum_vm
about: Freestanding multi-file C checksum and mini-VM validation library.
library: yes

export crc32_of_word
  about: Compute the IEEE CRC32 checksum of an 8-byte word with seed.
  param seed: integer
  param word: integer
  result: integer

export adler32_of_pair
  about: Compute the Adler32 checksum of two 8-byte words.
  param first: integer
  param second: integer
  result: integer

export mini_vm_execute
  about: Execute a deterministic register-VM sequence mixed with CRC32 and Adler32.
  param base_value: integer
  param multiplier: integer
  result: integer
`

	testing.expect(t, os.write_entire_file(foundation.join(temp_root, "/library_api.h"), transmute([]u8)header_source) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(temp_root, "/checksum_core.c"), transmute([]u8)checksum_c) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(temp_root, "/mini_vm.c"), transmute([]u8)mini_vm_c) == nil)

	parsed_manifest, parse_problem := manifest_parse(manifest_text)
	testing.expect_value(t, parse_problem, "")

	compile_and_convert :: proc(t: ^testing.T, work_dir: string, suffix: string, manifest: Module_Manifest) -> (module_bytes: []u8, digest: blake3.Hash) {
		obj_a := fmt.tprintf("checksum_core_%s.o", suffix)
		obj_b := fmt.tprintf("mini_vm_%s.o", suffix)
		combined := fmt.tprintf("combined_%s.o", suffix)

		cc_a := [?]string{
			"clang", "-target", "x86_64-unknown-none-elf",
			"-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-fno-common",
			"-fPIC", "-mno-red-zone", "-fno-asynchronous-unwind-tables", "-O2",
			"-c", "checksum_core.c", "-o", obj_a,
		}
		testing.expect(t, bootstrap_test_run_command(cc_a[:], work_dir), "clang must compile checksum_core.c")

		cc_b := [?]string{
			"clang", "-target", "x86_64-unknown-none-elf",
			"-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-fno-common",
			"-fPIC", "-mno-red-zone", "-fno-asynchronous-unwind-tables", "-O2",
			"-c", "mini_vm.c", "-o", obj_b,
		}
		testing.expect(t, bootstrap_test_run_command(cc_b[:], work_dir), "clang must compile mini_vm.c")

		link_cmd := [?]string{"ld.lld", "-r", "-o", combined, obj_a, obj_b}
		testing.expect(t, bootstrap_test_run_command(link_cmd[:], work_dir), "ld.lld -r must link multi-file ET_REL object")

		combined_bytes, read_err := os.read_entire_file(foundation.join(work_dir, "/", combined), context.allocator)
		testing.expect(t, read_err == nil, "must read combined ET_REL object")
		defer delete(combined_bytes)

		built, ok := convert_elf_with_manifest(combined_bytes, manifest, nil)
		testing.expect(t, ok, "convert_elf_with_manifest must accept multi-file freestanding C ET_REL object")
		testing.expect_value(t, module.validate(built), module.Error.None)
		return built, blake3.hash(built)
	}

	built_one, hash_one := compile_and_convert(t, temp_root, "run1", parsed_manifest)
	defer delete(built_one)
	built_two, hash_two := compile_and_convert(t, temp_root, "run2", parsed_manifest)
	defer delete(built_two)

	// Reproducibility check: two independent multi-file C compiles must give exact same bytes.
	testing.expect(t, hash_one == hash_two, "multi-file freestanding C module build must be byte-for-byte deterministic")
	testing.expect_value(t, len(built_one), len(built_two))

	// Verify header, own-hash slot, and all three described exports.
	// Export index 0 is reserved in the module format, so 3 exports yield count 4.
	_, head_err := module.header(built_one)
	testing.expect_value(t, head_err, module.Error.None)
	own_hash_offset, has_own_hash := module.own_hash_place(built_one)
	testing.expect(t, has_own_hash && own_hash_offset != 0, "modus_own_hash slot must be resolved in writable segment")
	testing.expect_value(t, int(module.count(built_one, .Exports)), 4)

	expected_names := [3]string{"crc32_of_word", "adler32_of_pair", "mini_vm_execute"}
	for expected_name, index in expected_names {
		row, row_ok := module.function(built_one, u32(index + 1))
		testing.expect(t, row_ok)
		name_text := module.string_at(built_one, row.name_offset, row.name_count)
		testing.expect_value(t, name_text, expected_name)
		testing.expect_value(t, int(row.parameter_count), 2)
		testing.expect_value(t, row.result, u8(module.Type.Integer))
	}
}
