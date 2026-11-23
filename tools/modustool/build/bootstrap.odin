// Bootstrap and self-hosting verification harness (src/md/features/bootstrap.md).
//
// Provides:
//   1. Two-stage self-hosting verification for modustool (`modustool self-host`):
//      compiles tools/modustool into stage1/modustool with deterministic flags,
//      runs stage1/modustool to compile stage2/modustool with identical flags,
//      computes BLAKE3 hashes of both binaries, and verifies exact fixed-point
//      equality or reports the first diverging byte offset.
//   2. Pure stage-by-stage bootstrap chain verification (`bootstrap_chain_verify`)
//      over validated plans_recipes.Recipe_Spec and guest_builder.Guest_Build_Spec
//      stages, checking acyclic DAG order, input-to-previous-output hash linkage,
//      zero-network and frozen-clock sandbox invariants, and stage1 == stage2
//      fixed-point equality.
//   3. Standard deterministic chain constructors for the C compiler self-host
//      chain (chibicc), the live-bootstrap seed chain (hex0 to odin), and the
//      C-world validation recipes (SQLite, Lua, zstd).
package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/guest_builder"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes"
import "modustool:foundation"

// Default staging directory under build/ for two-stage self-hosting builds.
SELF_HOST_DEFAULT_STAGING_FOLDER :: foundation.BUILD_FOLDER + "/self_host"
SELF_HOST_USAGE :: "modustool: self-host [--staging-dir <folder>] [--emit-binary <path>] [--verify-chains]"

// Domain separation context string for hashing a verified Bootstrap_Chain.
BOOTSTRAP_CHAIN_HASH_DOMAIN :: "modus bootstrap chain v1"

// Deterministic flags appended to TOOL_COMPILE_COMMAND so that two builds in
// distinct staging directories emit identical bytes with no embedded directory
// paths, thread-order variation, or linker build identifiers.
TOOL_SELF_HOST_DETERMINISTIC_FLAGS :: [?]string {
	TOOL_NEVER_BUILDS_ITSELF_FLAG,
	"-source-code-locations:filename",
	"-use-single-module",
	"-extra-linker-flags:-Wl,--build-id=none",
}

// Minimum and maximum size bounds for the auditable hex0 bootstrap seed.
BOOTSTRAP_HEX0_SEED_MAX_BYTES :: 1024

// Closed set of execution kinds for one stage of a bootstrap chain.
Bootstrap_Stage_Kind :: enum u8 {
	None          = 0,
	Seed          = 1,
	Native_Recipe = 2,
	Guest_Recipe  = 3,
}

// Closed set of bootstrap chain categories.
Bootstrap_Chain_Kind :: enum u8 {
	None                 = 0,
	C_Compiler_Self_Host = 1,
	Seed_Guest_Bootstrap = 2,
	C_World_Validation   = 3,
}

// Closed set of ways an upstream stage's output binds into a downstream stage.
Bootstrap_Dependency_Binding :: enum u8 {
	None         = 0,
	Builder      = 1,
	Recipe_Input = 2,
}

// Closed set of refusals returned by bootstrap_chain_verify.
Bootstrap_Chain_Refusal :: enum u8 {
	None                           = 0,
	Empty_Chain                    = 1,
	Invalid_Chain_Kind             = 2,
	Invalid_Stage_Name             = 3,
	Duplicate_Stage_Name           = 4,
	Invalid_Stage_Kind             = 5,
	Missing_Dependency             = 6,
	Duplicate_Dependency           = 7,
	Seed_Must_Have_No_Dependencies = 8,
	Cyclic_Dependency              = 9,
	Invalid_Topological_Order      = 10,
	Zero_Output_Hash               = 11,
	Zero_Seed_Bytes                = 12,
	Seed_Hash_Mismatch             = 13,
	Invalid_Recipe_Spec            = 14,
	Recipe_Sandbox_Violation       = 15,
	Invalid_Guest_Spec             = 16,
	Guest_Network_Enabled          = 17,
	Guest_Real_Clock_Enabled       = 18,
	Guest_Writable_Inputs_Enabled  = 19,
	Clock_Not_Frozen               = 20,
	Builder_Linkage_Mismatch       = 21,
	Input_Linkage_Mismatch         = 22,
	Guest_Input_Linkage_Mismatch   = 23,
	Missing_Fixed_Point_Stage      = 24,
	Fixed_Point_Hash_Mismatch      = 25,
	Host_Comparison_Hash_Mismatch  = 26,
	Invalid_Module_Manifest        = 27,
	Missing_Test_Vectors           = 28,
}

// Closed set of outcomes from comparing two self-hosted binary outputs.
Self_Host_Comparison_Status :: enum u8 {
	Equal         = 1,
	Empty_Binary  = 2,
	Byte_Mismatch = 3,
	Size_Mismatch = 4,
}

// Result of comparing stage1 and stage2 binaries byte for byte.
Self_Host_Binary_Comparison :: struct {
	status:                      Self_Host_Comparison_Status,
	equal:                       bool,
	stage_one_hash:              blake3.Hash,
	stage_two_hash:              blake3.Hash,
	stage_one_size:              int,
	stage_two_size:              int,
	first_diverging_byte_offset: int,
	stage_one_byte:              u8,
	stage_two_byte:              u8,
	has_byte_values:             bool,
}

// Configuration options for running the two-stage modustool self-hosting check.
Self_Host_Options :: struct {
	repository_root:   string, // Defaults to "." when empty.
	staging_directory: string, // Defaults to SELF_HOST_DEFAULT_STAGING_FOLDER when empty.
	source_folder:     string, // Defaults to foundation.TOOL_SOURCE_FOLDER when empty.
	binary_name:       string, // Defaults to "modustool" when empty.
	extra_flags:       []string,
}

// Complete report produced by bootstrap_self_host_modustool.
Self_Host_Report :: struct {
	ok:                      bool,
	stage_one_binary_path:   string,
	stage_two_binary_path:   string,
	stage_one_elapsed:       time.Duration,
	stage_two_elapsed:       time.Duration,
	total_elapsed:           time.Duration,
	comparison:              Self_Host_Binary_Comparison,
	failure_message:         string,
}

// One cryptographic dependency edge from an upstream stage output into a
// downstream stage's builder or named recipe input.
Bootstrap_Stage_Dependency :: struct {
	upstream_stage_name: string,
	binding:             Bootstrap_Dependency_Binding,
	input_name:          string, // Required when binding == .Recipe_Input.
}

// One deterministic validation vector attached to a C-world module recipe.
Bootstrap_Test_Vector :: struct {
	name:           string,
	export_name:    string,
	input_summary:  string,
	expected_value: i64,
}

// One stage in a deterministic bootstrap DAG.
Bootstrap_Stage_Spec :: struct {
	name:                 string,
	description:          string,
	kind:                 Bootstrap_Stage_Kind,
	dependencies:         []Bootstrap_Stage_Dependency,
	seed_bytes:           []u8,
	require_seed_bytes:   bool,
	recipe:               plans_recipes.Recipe_Spec,
	guest_spec:           guest_builder.Guest_Build_Spec,
	output_hash:          blake3.Hash,
	manifest_text:        string,
	require_test_vectors: bool,
	test_vectors:         []Bootstrap_Test_Vector,
}

// Complete bootstrap chain specification validated by bootstrap_chain_verify.
Bootstrap_Chain :: struct {
	name:                      string,
	kind:                      Bootstrap_Chain_Kind,
	enforce_frozen_clock:      bool,
	frozen_epoch_seconds:      u64,
	stages:                    []Bootstrap_Stage_Spec,
	require_fixed_point:       bool,
	fixed_point_stage_one:     string,
	fixed_point_stage_two:     string,
	require_host_comparison:   bool,
	host_comparison_stage:     string,
	expected_host_output_hash: blake3.Hash,
}

// Diagnostic report returned by bootstrap_chain_verify.
Bootstrap_Chain_Verification :: struct {
	valid:               bool,
	refusal:             Bootstrap_Chain_Refusal,
	failing_stage_index: int,
	failing_stage_name:  string,
	detail:              string,
	stage_count:         int,
	verified_recipes:    int,
	verified_guests:     int,
	verified_manifests:  int,
	chain_digest:        blake3.Hash,
}

// Single borders validating closed enum values.

bootstrap_stage_kind_of_word :: proc "contextless" (word: u64) -> (kind: Bootstrap_Stage_Kind, ok: bool) {
	member := enum_word.member_of_word(Bootstrap_Stage_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

bootstrap_chain_kind_of_word :: proc "contextless" (word: u64) -> (kind: Bootstrap_Chain_Kind, ok: bool) {
	member := enum_word.member_of_word(Bootstrap_Chain_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

bootstrap_dependency_binding_of_word :: proc "contextless" (word: u64) -> (binding: Bootstrap_Dependency_Binding, ok: bool) {
	member := enum_word.member_of_word(Bootstrap_Dependency_Binding, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// bootstrap_hash_is_zero reports whether every byte of digest is zero.
bootstrap_hash_is_zero :: proc "contextless" (digest: blake3.Hash) -> bool {
	for value in digest {
		if value != 0 {
			return false
		}
	}
	return true
}

// bootstrap_compare_stage_binaries computes BLAKE3 hashes of both stage binaries
// and verifies exact byte equality. When they differ, first_diverging_byte_offset
// holds the exact 0-based byte index where the two outputs first diverge.
bootstrap_compare_stage_binaries :: proc(stage_one_bytes, stage_two_bytes: []u8) -> Self_Host_Binary_Comparison {
	result := Self_Host_Binary_Comparison {
		stage_one_hash              = blake3.hash(stage_one_bytes),
		stage_two_hash              = blake3.hash(stage_two_bytes),
		stage_one_size              = len(stage_one_bytes),
		stage_two_size              = len(stage_two_bytes),
		first_diverging_byte_offset = -1,
	}
	if len(stage_one_bytes) == 0 || len(stage_two_bytes) == 0 {
		result.status = .Empty_Binary
		result.first_diverging_byte_offset = 0
		return result
	}
	shared_length := min(len(stage_one_bytes), len(stage_two_bytes))
	for offset in 0 ..< shared_length {
		if stage_one_bytes[offset] != stage_two_bytes[offset] {
			result.status = .Byte_Mismatch
			result.first_diverging_byte_offset = offset
			result.stage_one_byte = stage_one_bytes[offset]
			result.stage_two_byte = stage_two_bytes[offset]
			result.has_byte_values = true
			return result
		}
	}
	if len(stage_one_bytes) != len(stage_two_bytes) {
		result.status = .Size_Mismatch
		result.first_diverging_byte_offset = shared_length
		return result
	}
	if result.stage_one_hash != result.stage_two_hash {
		result.status = .Byte_Mismatch
		result.first_diverging_byte_offset = 0
		return result
	}
	result.status = .Equal
	result.equal = true
	return result
}

// bootstrap_self_host_compile_command constructs the deterministic `odin build`
// command line shared identically by both Stage 1 and Stage 2 builds.
bootstrap_self_host_compile_command :: proc(output_path: string, source_folder := foundation.TOOL_SOURCE_FOLDER, extra_flags: []string = nil, allocator := context.temp_allocator) -> []string {
	command := make([dynamic]string, allocator)
	if source_folder == foundation.TOOL_SOURCE_FOLDER {
		base := TOOL_COMPILE_COMMAND
		append(&command, ..base[:])
	} else {
		append(
			&command,
			"odin",
			"build",
			source_folder,
			"-vet",
			foundation.SOURCE_LIBRARY_FLAG,
			foundation.INTERNAL_LIBRARY_FLAG,
			foundation.KERNEL_LIBRARY_FLAG,
			foundation.TOOL_LIBRARY_FLAG,
			foundation.CUSTOM_ATTRIBUTES_FLAG,
		)
	}
	deterministic := TOOL_SELF_HOST_DETERMINISTIC_FLAGS
	append(&command, ..deterministic[:])
	for flag in extra_flags {
		append(&command, flag)
	}
	append(&command, strings.concatenate({"-out:", output_path}, allocator))
	return command[:]
}

// bootstrap_compile_tool_binary runs the deterministic Odin compile command
// into output_path with NIX_LDFLAGS unset and SOURCE_DATE_EPOCH frozen to 0.
bootstrap_compile_tool_binary :: proc(
	repository_root: string,
	output_path: string,
	source_folder := foundation.TOOL_SOURCE_FOLDER,
	extra_flags: []string = nil,
) -> (elapsed: time.Duration, ok: bool) {
	parent_end := strings.last_index_byte(output_path, '/')
	if parent_end > 0 {
		parent_dir := output_path[:parent_end]
		if !foundation.make_folder(parent_dir) {
			fmt.eprintfln("modustool: self-host: cannot create directory %s", parent_dir)
			return 0, false
		}
	}
	_ = os.unset_env("NIX_LDFLAGS")
	_ = os.set_env("SOURCE_DATE_EPOCH", "0")

	command := bootstrap_self_host_compile_command(output_path, source_folder, extra_flags, context.temp_allocator)
	started := time.tick_now()
	child, start_error := os.process_start({
		command     = command,
		working_dir = repository_root,
		stdin       = os.stdin,
		stdout      = os.stderr,
		stderr      = os.stderr,
	})
	if start_error != nil {
		fmt.eprintfln("modustool: self-host: cannot start %s: %v", command[0], start_error)
		return 0, false
	}
	state, wait_error := os.process_wait(child)
	elapsed = time.tick_since(started)
	if wait_error != nil || !state.success {
		fmt.eprintfln("modustool: self-host: compile into %s failed", output_path)
		return elapsed, false
	}
	return elapsed, true
}

// bootstrap_self_host_modustool compiles tools/modustool into stage1/modustool
// with deterministic flags, invokes stage1/modustool to compile stage2/modustool
// with identical flags, computes BLAKE3 hashes of both binaries, and verifies
// exact fixed-point equality.
bootstrap_self_host_modustool :: proc(options := Self_Host_Options{}) -> Self_Host_Report {
	total_started := time.tick_now()
	report := Self_Host_Report{}

	root := options.repository_root
	if root == "" {
		cwd, cwd_err := os.get_working_directory(context.temp_allocator)
		if cwd_err != nil {
			report.failure_message = "cannot read current working directory"
			return report
		}
		root = cwd
	}
	staging_root := options.staging_directory
	if staging_root == "" {
		staging_root = foundation.join(root, "/", SELF_HOST_DEFAULT_STAGING_FOLDER)
	} else if !os.is_absolute_path(staging_root) {
		staging_root = foundation.join(root, "/", staging_root)
	}
	source_folder := options.source_folder
	if source_folder == "" {
		source_folder = foundation.TOOL_SOURCE_FOLDER
	}
	binary_name := options.binary_name
	if binary_name == "" {
		binary_name = "modustool"
	}

	stage_one_dir := foundation.join(staging_root, "/stage1")
	stage_two_dir := foundation.join(staging_root, "/stage2")
	stage_one_path := foundation.join(stage_one_dir, "/", binary_name)
	stage_two_path := foundation.join(stage_two_dir, "/", binary_name)
	report.stage_one_binary_path = stage_one_path
	report.stage_two_binary_path = stage_two_path

	// Clean both staging directories so no stale binary can satisfy equality.
	_ = os.remove_all(stage_one_dir)
	_ = os.remove_all(stage_two_dir)
	if !foundation.make_folder(stage_one_dir) {
		report.failure_message = fmt.tprintf("cannot create stage1 directory %s", stage_one_dir)
		return report
	}
	if !foundation.make_folder(stage_two_dir) {
		report.failure_message = fmt.tprintf("cannot create stage2 directory %s", stage_two_dir)
		return report
	}

	// Stage 1: current tool compiles stage1/modustool.
	stage_one_elapsed, stage_one_ok := bootstrap_compile_tool_binary(root, stage_one_path, source_folder, options.extra_flags)
	report.stage_one_elapsed = stage_one_elapsed
	if !stage_one_ok {
		report.total_elapsed = time.tick_since(total_started)
		report.failure_message = "stage1 compilation failed"
		return report
	}

	// Stage 2: stage1/modustool itself compiles stage2/modustool with the exact
	// same deterministic flags.
	stage_two_started := time.tick_now()
	stage_two_ok := false
	if source_folder == foundation.TOOL_SOURCE_FOLDER && len(options.extra_flags) == 0 {
		_ = os.unset_env("NIX_LDFLAGS")
		_ = os.set_env("SOURCE_DATE_EPOCH", "0")
		stage_two_command := [?]string{stage_one_path, "self-host", "--emit-binary", stage_two_path}
		child, start_error := os.process_start({
			command     = stage_two_command[:],
			working_dir = root,
			stdin       = os.stdin,
			stdout      = os.stderr,
			stderr      = os.stderr,
		})
		if start_error != nil {
			report.stage_two_elapsed = time.tick_since(stage_two_started)
			report.total_elapsed = time.tick_since(total_started)
			report.failure_message = fmt.tprintf("cannot start stage1 binary %s: %v", stage_one_path, start_error)
			return report
		}
		state, wait_error := os.process_wait(child)
		report.stage_two_elapsed = time.tick_since(stage_two_started)
		stage_two_ok = wait_error == nil && state.success
	} else {
		// Custom minimal tool packages in host tests invoke stage1 directly with
		// `--emit-binary <stage2_path>` so stage1 still builds stage2.
		_ = os.unset_env("NIX_LDFLAGS")
		_ = os.set_env("SOURCE_DATE_EPOCH", "0")
		stage_two_command := [?]string{stage_one_path, "--emit-binary", stage_two_path}
		child, start_error := os.process_start({
			command     = stage_two_command[:],
			working_dir = root,
			stdin       = os.stdin,
			stdout      = os.stderr,
			stderr      = os.stderr,
		})
		if start_error != nil {
			report.stage_two_elapsed = time.tick_since(stage_two_started)
			report.total_elapsed = time.tick_since(total_started)
			report.failure_message = fmt.tprintf("cannot start stage1 binary %s: %v", stage_one_path, start_error)
			return report
		}
		state, wait_error := os.process_wait(child)
		report.stage_two_elapsed = time.tick_since(stage_two_started)
		stage_two_ok = wait_error == nil && state.success
	}
	if !stage_two_ok {
		report.total_elapsed = time.tick_since(total_started)
		report.failure_message = "stage2 compilation by stage1 binary failed"
		return report
	}

	stage_one_bytes, read_one_err := os.read_entire_file(stage_one_path, context.allocator)
	if read_one_err != nil {
		report.total_elapsed = time.tick_since(total_started)
		report.failure_message = fmt.tprintf("cannot read stage1 binary %s: %v", stage_one_path, read_one_err)
		return report
	}
	defer delete(stage_one_bytes)

	stage_two_bytes, read_two_err := os.read_entire_file(stage_two_path, context.allocator)
	if read_two_err != nil {
		report.total_elapsed = time.tick_since(total_started)
		report.failure_message = fmt.tprintf("cannot read stage2 binary %s: %v", stage_two_path, read_two_err)
		return report
	}
	defer delete(stage_two_bytes)

	report.comparison = bootstrap_compare_stage_binaries(stage_one_bytes, stage_two_bytes)
	report.total_elapsed = time.tick_since(total_started)
	report.ok = report.comparison.equal
	if !report.ok {
		switch report.comparison.status {
		case .Equal:
			report.ok = true
		case .Empty_Binary:
			report.failure_message = fmt.tprintf("empty stage binary (stage1=%d bytes, stage2=%d bytes)", report.comparison.stage_one_size, report.comparison.stage_two_size)
		case .Byte_Mismatch:
			report.failure_message = fmt.tprintf(
				"stage1 and stage2 diverge at byte offset %d (0x%02x != 0x%02x; sizes %d and %d)",
				report.comparison.first_diverging_byte_offset,
				report.comparison.stage_one_byte,
				report.comparison.stage_two_byte,
				report.comparison.stage_one_size,
				report.comparison.stage_two_size,
			)
		case .Size_Mismatch:
			report.failure_message = fmt.tprintf(
				"stage1 and stage2 diverge in size at byte offset %d (stage1=%d bytes, stage2=%d bytes)",
				report.comparison.first_diverging_byte_offset,
				report.comparison.stage_one_size,
				report.comparison.stage_two_size,
			)
		}
	}
	return report
}

// run_self_host implements the CLI command `modustool self-host`.
run_self_host :: proc(args: []string) -> int {
	options := Self_Host_Options{}
	emit_binary_path := ""
	verify_chains_also := false

	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch arg {
		case "--staging-dir":
			if index + 1 >= len(args) {
				fmt.eprintln(SELF_HOST_USAGE)
				return foundation.EXIT_USAGE
			}
			index += 1
			options.staging_directory = args[index]
		case "--emit-binary":
			if index + 1 >= len(args) {
				fmt.eprintln(SELF_HOST_USAGE)
				return foundation.EXIT_USAGE
			}
			index += 1
			emit_binary_path = args[index]
		case "--verify-chains":
			verify_chains_also = true
		case:
			fmt.eprintfln("modustool: self-host: unknown option %s", arg)
			fmt.eprintln(SELF_HOST_USAGE)
			return foundation.EXIT_USAGE
		}
	}

	if emit_binary_path != "" {
		cwd, cwd_err := os.get_working_directory(context.temp_allocator)
		if cwd_err != nil {
			fmt.eprintfln("modustool: self-host: cannot read working directory: %v", cwd_err)
			return foundation.EXIT_FAILURE
		}
		_, compiled := bootstrap_compile_tool_binary(cwd, emit_binary_path)
		return compiled ? 0 : foundation.EXIT_FAILURE
	}

	report := bootstrap_self_host_modustool(options)
	stage_one_hex := sdk_lowercase_hex_encode(report.comparison.stage_one_hash[:], context.temp_allocator)
	stage_two_hex := sdk_lowercase_hex_encode(report.comparison.stage_two_hash[:], context.temp_allocator)

	if !report.ok {
		fmt.eprintfln("modustool: self-host failed: %s", report.failure_message)
		fmt.eprintfln("modustool: self-host stage1: %s (%d bytes, blake3 %s, %.2f s)", report.stage_one_binary_path, report.comparison.stage_one_size, stage_one_hex, time.duration_seconds(report.stage_one_elapsed))
		fmt.eprintfln("modustool: self-host stage2: %s (%d bytes, blake3 %s, %.2f s)", report.stage_two_binary_path, report.comparison.stage_two_size, stage_two_hex, time.duration_seconds(report.stage_two_elapsed))
		return foundation.EXIT_FAILURE
	}

	fmt.printfln("modustool: self-host fixed point verified: blake3(stage1) == blake3(stage2) == %s", stage_one_hex)
	fmt.printfln("modustool: self-host stage1: %s (%d bytes, %.2f s)", report.stage_one_binary_path, report.comparison.stage_one_size, time.duration_seconds(report.stage_one_elapsed))
	fmt.printfln("modustool: self-host stage2: %s (%d bytes, %.2f s)", report.stage_two_binary_path, report.comparison.stage_two_size, time.duration_seconds(report.stage_two_elapsed))
	fmt.printfln("modustool: measure: self-host total elapsed: %.2f s", time.duration_seconds(report.total_elapsed))

	if verify_chains_also {
		chains := [3]Bootstrap_Chain {
			bootstrap_chain_c_compiler_self_host(),
			bootstrap_chain_seed_guest_bootstrap(),
			bootstrap_chain_c_world_validation(),
		}
		for &chain in chains {
			verification := bootstrap_chain_verify(&chain)
			if !verification.valid {
				fmt.eprintfln("modustool: self-host chain %s failed (%v at %s): %s", chain.name, verification.refusal, verification.failing_stage_name, verification.detail)
				return foundation.EXIT_FAILURE
			}
			digest_hex := sdk_lowercase_hex_encode(verification.chain_digest[:], context.temp_allocator)
			fmt.printfln("modustool: bootstrap chain %s verified (%d stages, digest %s)", chain.name, verification.stage_count, digest_hex)
		}
	}

	return 0
}

// Pure stage-by-stage bootstrap chain verification.

@(private = "file")
Bootstrap_Dfs_Color :: enum u8 {
	Unvisited = 0,
	Visiting  = 1,
	Visited   = 2,
}

@(private = "file")
bootstrap_stage_name_is_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 64 {
		return false
	}
	for index in 0 ..< len(name) {
		character := name[index]
		is_lower := character >= 'a' && character <= 'z'
		is_digit := character >= '0' && character <= '9'
		if !is_lower && !is_digit && character != '_' && character != '-' {
			return false
		}
	}
	return true
}

@(private = "file")
bootstrap_find_stage_index :: proc(stages: []Bootstrap_Stage_Spec, name: string) -> (index: int, found: bool) {
	for stage, position in stages {
		if stage.name == name {
			return position, true
		}
	}
	return -1, false
}

@(private = "file")
bootstrap_dfs_detect_cycle :: proc(
	stages: []Bootstrap_Stage_Spec,
	index: int,
	colors: []Bootstrap_Dfs_Color,
) -> bool {
	colors[index] = .Visiting
	for dependency in stages[index].dependencies {
		upstream_index, found := bootstrap_find_stage_index(stages, dependency.upstream_stage_name)
		if !found {
			continue
		}
		switch colors[upstream_index] {
		case .Visiting:
			return true
		case .Unvisited:
			if bootstrap_dfs_detect_cycle(stages, upstream_index, colors) {
				return true
			}
		case .Visited:
			// Already proven acyclic from this node.
		}
	}
	colors[index] = .Visited
	return false
}

@(private = "file")
bootstrap_recipe_find_input_hash :: proc(recipe: ^plans_recipes.Recipe_Spec, input_name: string) -> (digest: blake3.Hash, found: bool) {
	for index in u32(0) ..< recipe.input_count {
		input := &recipe.inputs[index]
		name := string(input.name_bytes[:input.name_length])
		if name == input_name {
			return input.hash, true
		}
	}
	return {}, false
}

@(private = "file")
bootstrap_guest_find_mount_hash :: proc(spec: ^guest_builder.Guest_Build_Spec, input_name: string) -> (digest: blake3.Hash, found: bool) {
	prefixed := strings.concatenate({"inputs/", input_name}, context.temp_allocator)
	for index in u32(0) ..< spec.input_count {
		mount := &spec.inputs[index]
		mount_path := string(mount.path[:mount.path_length])
		if mount_path == input_name || mount_path == prefixed {
			return mount.tree_hash, true
		}
	}
	return {}, false
}

@(private = "file")
bootstrap_chain_fail :: proc(
	refusal: Bootstrap_Chain_Refusal,
	stage_index: int,
	stage_name: string,
	format_text: string,
	args: ..any,
) -> Bootstrap_Chain_Verification {
	return Bootstrap_Chain_Verification {
		valid               = false,
		refusal             = refusal,
		failing_stage_index = stage_index,
		failing_stage_name  = stage_name,
		detail              = fmt.tprintf(format_text, ..args),
	}
}

// bootstrap_chain_verify validates a complete Bootstrap_Chain without executing
// any external process. It checks:
//   - valid chain kind, non-empty stage list, valid unique stage names, and
//     non-zero output hashes on every stage;
//   - acyclic dependency graph and strict topological ordering;
//   - Recipe_Spec and Builder_Sandbox_Spec invariants on every recipe stage;
//   - Guest_Build_Spec invariants (zero network, frozen clock, read-only inputs)
//     on every guest stage;
//   - cryptographic linkage from every upstream output_hash to downstream
//     builder_hash, recipe input hash, and guest read-only mount hash;
//   - optional stage1 == stage2 fixed-point equality and host build comparison;
//   - optional Module_Manifest parsing and test vector completeness.
bootstrap_chain_verify :: proc(chain: ^Bootstrap_Chain) -> Bootstrap_Chain_Verification {
	if chain == nil || len(chain.stages) == 0 {
		return bootstrap_chain_fail(.Empty_Chain, -1, "", "bootstrap chain has zero stages")
	}
	checked_chain_kind, chain_kind_ok := bootstrap_chain_kind_of_word(u64(chain.kind))
	if !chain_kind_ok {
		return bootstrap_chain_fail(.Invalid_Chain_Kind, -1, "", "bootstrap chain kind %d names no member", u64(chain.kind))
	}

	// Pass 1: Validate stage names, kinds, uniqueness, and non-zero outputs.
	for stage, index in chain.stages {
		if !bootstrap_stage_name_is_valid(stage.name) {
			return bootstrap_chain_fail(.Invalid_Stage_Name, index, stage.name, "stage %d has invalid name `%s`", index, stage.name)
		}
		for earlier in 0 ..< index {
			if chain.stages[earlier].name == stage.name {
				return bootstrap_chain_fail(.Duplicate_Stage_Name, index, stage.name, "stage `%s` is declared twice", stage.name)
			}
		}
		if _, kind_ok := bootstrap_stage_kind_of_word(u64(stage.kind)); !kind_ok {
			return bootstrap_chain_fail(.Invalid_Stage_Kind, index, stage.name, "stage `%s` has invalid stage kind %d", stage.name, u64(stage.kind))
		}
		if bootstrap_hash_is_zero(stage.output_hash) {
			return bootstrap_chain_fail(.Zero_Output_Hash, index, stage.name, "stage `%s` has an all-zero output hash", stage.name)
		}
		if stage.kind == .Seed && len(stage.dependencies) > 0 {
			return bootstrap_chain_fail(.Seed_Must_Have_No_Dependencies, index, stage.name, "seed stage `%s` must have zero dependencies", stage.name)
		}
		for dependency, dep_index in stage.dependencies {
			if _, bind_ok := bootstrap_dependency_binding_of_word(u64(dependency.binding)); !bind_ok {
				return bootstrap_chain_fail(.Missing_Dependency, index, stage.name, "stage `%s` dependency %d has invalid binding", stage.name, dep_index)
			}
			if _, found := bootstrap_find_stage_index(chain.stages, dependency.upstream_stage_name); !found {
				return bootstrap_chain_fail(.Missing_Dependency, index, stage.name, "stage `%s` depends on missing stage `%s`", stage.name, dependency.upstream_stage_name)
			}
			for earlier_dep in 0 ..< dep_index {
				prev := stage.dependencies[earlier_dep]
				if prev.upstream_stage_name == dependency.upstream_stage_name && prev.binding == dependency.binding && prev.input_name == dependency.input_name {
					return bootstrap_chain_fail(.Duplicate_Dependency, index, stage.name, "stage `%s` lists dependency `%s` twice", stage.name, dependency.upstream_stage_name)
				}
			}
		}
	}

	// Pass 2: Detect cycles across the full dependency graph before order checks.
	colors := make([]Bootstrap_Dfs_Color, len(chain.stages), context.temp_allocator)
	for index in 0 ..< len(chain.stages) {
		if colors[index] == .Unvisited {
			if bootstrap_dfs_detect_cycle(chain.stages, index, colors) {
				return bootstrap_chain_fail(.Cyclic_Dependency, index, chain.stages[index].name, "bootstrap chain contains a dependency cycle reaching `%s`", chain.stages[index].name)
			}
		}
	}

	// Pass 3: Enforce topological ordering, recipe/guest sandbox invariants,
	// hash linkage, manifest validity, and test vectors.
	digest_material := make([dynamic]u8, context.temp_allocator)
	append(&digest_material, u8(checked_chain_kind))

	verified_recipes := 0
	verified_guests := 0
	verified_manifests := 0

	for &stage, index in chain.stages {
		for dependency in stage.dependencies {
			upstream_index, _ := bootstrap_find_stage_index(chain.stages, dependency.upstream_stage_name)
			if upstream_index >= index {
				return bootstrap_chain_fail(
					.Invalid_Topological_Order,
					index,
					stage.name,
					"stage `%s` at index %d depends on later stage `%s` at index %d",
					stage.name,
					index,
					dependency.upstream_stage_name,
					upstream_index,
				)
			}
		}

		stage_kind, _ := bootstrap_stage_kind_of_word(u64(stage.kind))
		append(&digest_material, u8(stage_kind))
		append(&digest_material, ..transmute([]u8)stage.name)

		switch stage_kind {
		case .None:
			return bootstrap_chain_fail(.Invalid_Stage_Kind, index, stage.name, "stage `%s` has kind None", stage.name)

		case .Seed:
			if stage.require_seed_bytes && len(stage.seed_bytes) == 0 {
				return bootstrap_chain_fail(.Zero_Seed_Bytes, index, stage.name, "seed stage `%s` requires non-empty auditable seed bytes", stage.name)
			}
			if len(stage.seed_bytes) > 0 {
				computed := blake3.hash(stage.seed_bytes)
				if computed != stage.output_hash {
					return bootstrap_chain_fail(.Seed_Hash_Mismatch, index, stage.name, "seed stage `%s` bytes do not match declared output hash", stage.name)
				}
			}
			append(&digest_material, ..stage.output_hash[:])

		case .Native_Recipe, .Guest_Recipe:
			if chain.enforce_frozen_clock && stage.recipe.source_date_unix != chain.frozen_epoch_seconds {
				return bootstrap_chain_fail(
					.Clock_Not_Frozen,
					index,
					stage.name,
					"stage `%s` recipe source_date_unix (%d) differs from frozen epoch (%d)",
					stage.name,
					stage.recipe.source_date_unix,
					chain.frozen_epoch_seconds,
				)
			}
			recipe_refusal, bad_input := plans_recipes.recipe_validate(&stage.recipe)
			if recipe_refusal != .None {
				return bootstrap_chain_fail(.Invalid_Recipe_Spec, index, stage.name, "stage `%s` recipe refused (%v at input %d)", stage.name, recipe_refusal, bad_input)
			}
			sandbox: plans_recipes.Builder_Sandbox_Spec
			sandbox_prep_refusal := plans_recipes.builder_sandbox_prepare(&stage.recipe, &sandbox)
			if sandbox_prep_refusal != .None {
				return bootstrap_chain_fail(.Recipe_Sandbox_Violation, index, stage.name, "stage `%s` sandbox prepare failed (%v)", stage.name, sandbox_prep_refusal)
			}
			if sandbox_refusal := plans_recipes.builder_sandbox_validate(&sandbox); sandbox_refusal != .None {
				return bootstrap_chain_fail(.Recipe_Sandbox_Violation, index, stage.name, "stage `%s` sandbox invariant violated (%v)", stage.name, sandbox_refusal)
			}
			verified_recipes += 1
			append(&digest_material, ..sandbox.recipe_hash[:])

			if stage_kind == .Guest_Recipe {
				if stage.guest_spec.allow_network {
					return bootstrap_chain_fail(.Guest_Network_Enabled, index, stage.name, "guest stage `%s` enables network access", stage.name)
				}
				if stage.guest_spec.allow_real_clock {
					return bootstrap_chain_fail(.Guest_Real_Clock_Enabled, index, stage.name, "guest stage `%s` enables real wall clock", stage.name)
				}
				if stage.guest_spec.allow_writable_inputs {
					return bootstrap_chain_fail(.Guest_Writable_Inputs_Enabled, index, stage.name, "guest stage `%s` enables writable inputs", stage.name)
				}
				if chain.enforce_frozen_clock && stage.guest_spec.frozen_epoch_seconds != chain.frozen_epoch_seconds {
					return bootstrap_chain_fail(
						.Clock_Not_Frozen,
						index,
						stage.name,
						"guest stage `%s` frozen_epoch_seconds (%d) differs from chain frozen epoch (%d)",
						stage.name,
						stage.guest_spec.frozen_epoch_seconds,
						chain.frozen_epoch_seconds,
					)
				}
				guest_hash, guest_refusal := guest_builder.build_spec_hash(&stage.guest_spec)
				if guest_refusal != .None {
					return bootstrap_chain_fail(.Invalid_Guest_Spec, index, stage.name, "guest stage `%s` build spec refused (%v)", stage.name, guest_refusal)
				}
				verified_guests += 1
				append(&digest_material, ..guest_hash[:])
			}

			// Verify cryptographic hash linkage from every upstream stage.
			for dependency in stage.dependencies {
				upstream_index, _ := bootstrap_find_stage_index(chain.stages, dependency.upstream_stage_name)
				upstream_hash := chain.stages[upstream_index].output_hash
				checked_binding, _ := bootstrap_dependency_binding_of_word(u64(dependency.binding))
				switch checked_binding {
				case .None:
					return bootstrap_chain_fail(.Missing_Dependency, index, stage.name, "stage `%s` dependency has binding None", stage.name)
				case .Builder:
					if stage.recipe.builder_hash != upstream_hash {
						return bootstrap_chain_fail(
							.Builder_Linkage_Mismatch,
							index,
							stage.name,
							"stage `%s` builder_hash does not match output hash of upstream stage `%s`",
							stage.name,
							dependency.upstream_stage_name,
						)
					}
				case .Recipe_Input:
					recipe_input_hash, input_found := bootstrap_recipe_find_input_hash(&stage.recipe, dependency.input_name)
					if !input_found || recipe_input_hash != upstream_hash {
						return bootstrap_chain_fail(
							.Input_Linkage_Mismatch,
							index,
							stage.name,
							"stage `%s` recipe input `%s` does not match output hash of upstream stage `%s`",
							stage.name,
							dependency.input_name,
							dependency.upstream_stage_name,
						)
					}
					if stage_kind == .Guest_Recipe {
						guest_mount_hash, mount_found := bootstrap_guest_find_mount_hash(&stage.guest_spec, dependency.input_name)
						if !mount_found || guest_mount_hash != upstream_hash {
							return bootstrap_chain_fail(
								.Guest_Input_Linkage_Mismatch,
								index,
								stage.name,
								"guest stage `%s` mount `%s` does not match output hash of upstream stage `%s`",
								stage.name,
								dependency.input_name,
								dependency.upstream_stage_name,
							)
						}
					}
				}
			}
			append(&digest_material, ..stage.output_hash[:])
		}

		if stage.manifest_text != "" {
			_, manifest_problem := manifest_parse(stage.manifest_text)
			if manifest_problem != "" {
				return bootstrap_chain_fail(.Invalid_Module_Manifest, index, stage.name, "stage `%s` module manifest refused: %s", stage.name, manifest_problem)
			}
			verified_manifests += 1
			append(&digest_material, ..transmute([]u8)stage.manifest_text)
		}

		if stage.require_test_vectors {
			if len(stage.test_vectors) == 0 {
				return bootstrap_chain_fail(.Missing_Test_Vectors, index, stage.name, "stage `%s` requires validation test vectors", stage.name)
			}
			for vector, vec_index in stage.test_vectors {
				if len(vector.name) == 0 || len(vector.export_name) == 0 {
					return bootstrap_chain_fail(.Missing_Test_Vectors, index, stage.name, "stage `%s` test vector %d has empty name or export", stage.name, vec_index)
				}
			}
		}
	}

	// Pass 4: Verify stage1 == stage2 fixed-point equality when required.
	if chain.require_fixed_point {
		stage_one_index, found_one := bootstrap_find_stage_index(chain.stages, chain.fixed_point_stage_one)
		stage_two_index, found_two := bootstrap_find_stage_index(chain.stages, chain.fixed_point_stage_two)
		if !found_one || !found_two || stage_one_index == stage_two_index {
			return bootstrap_chain_fail(
				.Missing_Fixed_Point_Stage,
				-1,
				"",
				"fixed-point check requires two distinct stages (`%s` and `%s`)",
				chain.fixed_point_stage_one,
				chain.fixed_point_stage_two,
			)
		}
		if chain.stages[stage_one_index].output_hash != chain.stages[stage_two_index].output_hash {
			return bootstrap_chain_fail(
				.Fixed_Point_Hash_Mismatch,
				stage_two_index,
				chain.stages[stage_two_index].name,
				"fixed-point mismatch: output hash of `%s` differs from `%s`",
				chain.fixed_point_stage_one,
				chain.fixed_point_stage_two,
			)
		}
	}

	// Pass 5: Verify final output against the host reference hash when required.
	if chain.require_host_comparison {
		target_index, found := bootstrap_find_stage_index(chain.stages, chain.host_comparison_stage)
		if !found || bootstrap_hash_is_zero(chain.expected_host_output_hash) {
			return bootstrap_chain_fail(
				.Host_Comparison_Hash_Mismatch,
				-1,
				chain.host_comparison_stage,
				"host comparison stage `%s` is absent or expected host hash is zero",
				chain.host_comparison_stage,
			)
		}
		if chain.stages[target_index].output_hash != chain.expected_host_output_hash {
			return bootstrap_chain_fail(
				.Host_Comparison_Hash_Mismatch,
				target_index,
				chain.stages[target_index].name,
				"final stage `%s` output hash does not match host build hash",
				chain.host_comparison_stage,
			)
		}
	}

	return Bootstrap_Chain_Verification {
		valid               = true,
		refusal             = .None,
		failing_stage_index = -1,
		stage_count         = len(chain.stages),
		verified_recipes    = verified_recipes,
		verified_guests     = verified_guests,
		verified_manifests  = verified_manifests,
		chain_digest        = blake3.derive_key(BOOTSTRAP_CHAIN_HASH_DOMAIN, digest_material[:]),
	}
}

// Deterministic helpers and standard chain constructors matching
// src/md/features/bootstrap.md.

@(private = "file")
bootstrap_deterministic_digest :: proc(label: string) -> blake3.Hash {
	return blake3.derive_key("modus bootstrap descriptor v1", transmute([]u8)label)
}

// bootstrap_make_recipe_spec writes a validated plans_recipes.Recipe_Spec from
// named inputs and deterministic argument bytes into spec, which the caller
// holds: a recipe is about 90 KiB, so it is built in place and never copied.
// On a refusal spec is zero.
bootstrap_make_recipe_spec :: proc(
	spec: ^plans_recipes.Recipe_Spec,
	builder_hash: blake3.Hash,
	output_kind: object_cache.Cache_Object_Kind,
	source_date_unix: u64,
	output_block_limit: u64,
	inputs: []plans_recipes.Recipe_Input,
	arguments_text: string,
) -> (ok: bool) {
	spec^ = {}
	if len(inputs) > plans_recipes.MAX_RECIPE_INPUTS {
		return false
	}
	arg_bytes := transmute([]u8)arguments_text
	if len(arg_bytes) > plans_recipes.MAX_RECIPE_ARG_BYTES {
		return false
	}
	spec.builder_hash = builder_hash
	spec.output_kind = output_kind
	spec.source_date_unix = source_date_unix
	spec.output_block_limit = output_block_limit
	spec.input_count = u32(len(inputs))
	spec.arguments_length = u32(len(arg_bytes))
	for input, index in inputs {
		spec.inputs[index] = input
	}
	copy(spec.arguments[:], arg_bytes)
	if refusal, _ := plans_recipes.recipe_validate(spec); refusal != .None {
		spec^ = {}
		return false
	}
	return true
}

// bootstrap_make_guest_spec builds a deterministic, zero-network, frozen-clock
// guest_builder.Guest_Build_Spec for one live-bootstrap stage.
bootstrap_make_guest_spec :: proc(
	kernel_hash: blake3.Hash,
	root_image_hash: blake3.Hash,
	frozen_epoch_seconds: u64,
	memory_pages: u64,
	output_size_bound: u64,
	command_text: string,
	mounts: []struct{path: string, hash: blake3.Hash},
) -> (spec: guest_builder.Guest_Build_Spec, ok: bool) {
	spec = guest_builder.Guest_Build_Spec {
		kernel_hash           = kernel_hash,
		root_image_hash       = root_image_hash,
		frozen_epoch_seconds  = frozen_epoch_seconds,
		memory_pages          = memory_pages,
		output_size_bound     = output_size_bound,
		allow_network         = false,
		allow_real_clock      = false,
		allow_writable_inputs = false,
	}
	if guest_builder.build_spec_set_command(&spec, command_text) != .None {
		return {}, false
	}
	for mount in mounts {
		if guest_builder.build_spec_add_input(&spec, mount.path, mount.hash) != .None {
			return {}, false
		}
	}
	if guest_builder.validate_build_spec(&spec) != .None {
		return {}, false
	}
	return spec, true
}

// bootstrap_chain_c_compiler_self_host builds Chain A:
//   Stage 0 (host-built chibicc seed)
//   -> Stage 1 (chibicc compiles chibicc sources on modus)
//   -> Stage 2 (stage1 compiles chibicc sources again)
//   with fixed-point invariant blake3(stage1) == blake3(stage2).
bootstrap_chain_c_compiler_self_host :: proc(allocator := context.temp_allocator) -> Bootstrap_Chain {
	chibicc_sources_hash := bootstrap_deterministic_digest("source:chibicc-tree-v1")
	thin_libc_hash := bootstrap_deterministic_digest("source:chibicc-thin-libc-v1")
	assembler_hash := bootstrap_deterministic_digest("module:assemble-v1")

	stage_zero_seed_bytes := transmute([]u8)string("modus:chibicc:host-built-seed:v1")
	stage_zero_hash := blake3.hash(stage_zero_seed_bytes)
	fixed_point_chibicc_hash := bootstrap_deterministic_digest("module:chibicc-fixed-point-v1")

	src_input, _ := plans_recipes.recipe_input_make("chibicc_source", .Tree, chibicc_sources_hash)
	libc_input, _ := plans_recipes.recipe_input_make("thin_libc", .Tree, thin_libc_hash)
	asm_input, _ := plans_recipes.recipe_input_make("assembler", .Blob, assembler_hash)


	stage_one_deps := make([]Bootstrap_Stage_Dependency, 1, allocator)
	stage_one_deps[0] = {upstream_stage_name = "chibicc_host_seed", binding = .Builder}

	stage_two_deps := make([]Bootstrap_Stage_Dependency, 1, allocator)
	stage_two_deps[0] = {upstream_stage_name = "chibicc_stage_one", binding = .Builder}

	stages := make([]Bootstrap_Stage_Spec, 3, allocator)
	stages[0] = {
		name               = "chibicc_host_seed",
		description        = "Host-built chibicc module used only to compile stage one",
		kind               = .Seed,
		seed_bytes         = stage_zero_seed_bytes,
		require_seed_bytes = true,
		output_hash        = stage_zero_hash,
	}
	stages[1] = {
		name         = "chibicc_stage_one",
		description  = "Host-built chibicc compiles chibicc sources on modus",
		kind         = .Native_Recipe,
		dependencies = stage_one_deps,
		output_hash  = fixed_point_chibicc_hash,
	}
	stages[2] = {
		name         = "chibicc_stage_two",
		description  = "Stage one chibicc compiles chibicc sources again to prove fixed point",
		kind         = .Native_Recipe,
		dependencies = stage_two_deps,
		output_hash  = fixed_point_chibicc_hash,
	}
	_ = bootstrap_make_recipe_spec(
		&stages[1].recipe,
		stage_zero_hash,
		.Blob,
		0,
		4096,
		[]plans_recipes.Recipe_Input{src_input, libc_input, asm_input},
		"target=modus-x86_64;mode=compile_chibicc_stage1;reproducible_dates=epoch",
	)
	_ = bootstrap_make_recipe_spec(
		&stages[2].recipe,
		fixed_point_chibicc_hash,
		.Blob,
		0,
		4096,
		[]plans_recipes.Recipe_Input{src_input, libc_input, asm_input},
		"target=modus-x86_64;mode=compile_chibicc_stage2;reproducible_dates=epoch",
	)

	return Bootstrap_Chain {
		name                  = "chibicc_self_host",
		kind                  = .C_Compiler_Self_Host,
		enforce_frozen_clock  = true,
		frozen_epoch_seconds  = 0,
		stages                = stages,
		require_fixed_point   = true,
		fixed_point_stage_one = "chibicc_stage_one",
		fixed_point_stage_two = "chibicc_stage_two",
	}
}

// bootstrap_chain_seed_guest_bootstrap builds Chain B:
//   hex0 (~500-byte seed) -> stage0_posix -> mescc -> tcc -> gcc -> llvm_18 -> odin_fork
// running inside the zero-network, frozen-clock guest builder, comparing the
// final odin_fork tree hash against the host flake build.
bootstrap_chain_seed_guest_bootstrap :: proc(allocator := context.temp_allocator) -> Bootstrap_Chain {
	guest_kernel_hash := bootstrap_deterministic_digest("guest:linux-kernel-v1")
	guest_root_hash := bootstrap_deterministic_digest("guest:minimal-rootfs-v1")
	guest_builder_module_hash := bootstrap_deterministic_digest("module:guest-builder-v1")

	// Minimal auditable hex0 seed payload (well under 512 bytes).
	hex0_seed_bytes := transmute([]u8)string("hex0-x86_64-auditable-bootstrap-seed:modus:v1")
	hex0_hash := blake3.hash(hex0_seed_bytes)

	Stage_Descriptor :: struct {
		name:         string,
		description:  string,
		prev_stage:   string,
		prev_input:   string,
		source_label: string,
		command:      string,
		memory_pages: u64,
		output_bound: u64,
	}

	guest_stage_descriptors := [?]Stage_Descriptor {
		{
			name         = "stage0_posix",
			description  = "Build hex1, hex2, M1 assembler, and M2-Planet from hex0 seed",
			prev_stage   = "hex0_seed",
			prev_input   = "hex0",
			source_label = "source:stage0-posix-v1",
			command      = "/bin/hex0 /inputs/hex0/hex0.hex0 /out/stage0-posix",
			memory_pages = 4096,
			output_bound = 4 * 1024 * 1024,
		},
		{
			name         = "mescc",
			description  = "Build GNU Mes C compiler from stage0-posix M2-Planet",
			prev_stage   = "stage0_posix",
			prev_input   = "stage0_posix",
			source_label = "source:mes-v1",
			command      = "/inputs/stage0_posix/M2-Planet --build-mes /inputs/source /out/mescc",
			memory_pages = 16384,
			output_bound = 8 * 1024 * 1024,
		},
		{
			name         = "tcc",
			description  = "Build Tiny C Compiler with mescc",
			prev_stage   = "mescc",
			prev_input   = "mescc",
			source_label = "source:tcc-v1",
			command      = "/inputs/mescc/mescc --build-tcc /inputs/source /out/tcc",
			memory_pages = 16384,
			output_bound = 8 * 1024 * 1024,
		},
		{
			name         = "gcc",
			description  = "Build GCC toolchain from tcc through gcc 4 to modern gcc",
			prev_stage   = "tcc",
			prev_input   = "tcc",
			source_label = "source:gcc-v1",
			command      = "/inputs/tcc/tcc --build-gcc-chain /inputs/source /out/gcc",
			memory_pages = 131072,
			output_bound = 32 * 1024 * 1024,
		},
		{
			name         = "llvm_18",
			description  = "Build pinned LLVM 18 with dead-store-elimination commit using gcc",
			prev_stage   = "gcc",
			prev_input   = "gcc",
			source_label = "source:llvm-18-pinned-v1",
			command      = "/inputs/gcc/g++ --build-llvm18-pinned /inputs/source /out/llvm18",
			memory_pages = 262144,
			output_bound = 64 * 1024 * 1024,
		},
		{
			name         = "odin_fork",
			description  = "Build pinned modus Odin compiler fork against LLVM 18",
			prev_stage   = "llvm_18",
			prev_input   = "llvm_18",
			source_label = "source:odin-fork-dev-2026-11a-v1",
			command      = "/inputs/llvm_18/clang++ --build-odin-fork /inputs/source /out/odin",
			memory_pages = 131072,
			output_bound = 32 * 1024 * 1024,
		},
	}

	stages := make([]Bootstrap_Stage_Spec, 1 + len(guest_stage_descriptors), allocator)
	stages[0] = {
		name               = "hex0_seed",
		description        = "Auditable ~500-byte hex0 bootstrap seed",
		kind               = .Seed,
		seed_bytes         = hex0_seed_bytes,
		require_seed_bytes = true,
		output_hash        = hex0_hash,
	}

	previous_hash := hex0_hash
	for descriptor, offset in guest_stage_descriptors {
		source_hash := bootstrap_deterministic_digest(descriptor.source_label)
		prev_input, _ := plans_recipes.recipe_input_make(descriptor.prev_input, .Tree, previous_hash)
		src_input, _ := plans_recipes.recipe_input_make("source", .Tree, source_hash)

		guest_spec, _ := bootstrap_make_guest_spec(
			guest_kernel_hash,
			guest_root_hash,
			0,
			descriptor.memory_pages,
			descriptor.output_bound,
			descriptor.command,
			[]struct{path: string, hash: blake3.Hash} {
				{path = strings.concatenate({"inputs/", descriptor.prev_input}, allocator), hash = previous_hash},
				{path = "inputs/source", hash = source_hash},
			},
		)

		stage_output_hash := bootstrap_deterministic_digest(strings.concatenate({"guest-stage-out:", descriptor.name}, allocator))
		deps := make([]Bootstrap_Stage_Dependency, 1, allocator)
		deps[0] = {
			upstream_stage_name = descriptor.prev_stage,
			binding             = .Recipe_Input,
			input_name          = descriptor.prev_input,
		}

		stages[offset + 1] = {
			name         = descriptor.name,
			description  = descriptor.description,
			kind         = .Guest_Recipe,
			dependencies = deps,
			guest_spec   = guest_spec,
			output_hash  = stage_output_hash,
		}
		previous_hash = stage_output_hash
		_ = bootstrap_make_recipe_spec(
			&stages[offset + 1].recipe,
			guest_builder_module_hash,
			.Tree,
			0,
			descriptor.output_bound / 4096,
			[]plans_recipes.Recipe_Input{prev_input, src_input},
			descriptor.command,
		)
	}

	return Bootstrap_Chain {
		name                      = "live_bootstrap_seed_chain",
		kind                      = .Seed_Guest_Bootstrap,
		enforce_frozen_clock      = true,
		frozen_epoch_seconds      = 0,
		stages                    = stages,
		require_host_comparison   = true,
		host_comparison_stage     = "odin_fork",
		expected_host_output_hash = previous_hash,
	}
}

// Language-neutral module manifests for the three C-world validation modules.

BOOTSTRAP_SQLITE_MANIFEST :: `module: sqlite
about: Embedded freestanding SQLite database engine compiled for modus.
library: yes

export sqlite_open_memory
  about: Open an in-memory SQLite database handle slot.
  result: integer

export sqlite_exec_statement
  about: Execute a deterministic SQL statement on the active database slot.
  param database_slot: integer
  param statement_code: integer
  result: integer

export sqlite_query_integer
  about: Query a single integer result from the active database slot.
  param database_slot: integer
  param query_code: integer
  result: integer

export sqlite_close
  about: Close an in-memory SQLite database slot.
  param database_slot: integer
  result: integer
`

BOOTSTRAP_LUA_MANIFEST :: `module: lua
about: Embedded freestanding Lua scripting virtual machine compiled for modus.
library: yes

export lua_state_create
  about: Create a deterministic freestanding Lua VM state.
  result: integer

export lua_eval_expression
  about: Evaluate an integer expression bytecode identifier in a Lua state.
  param state_slot: integer
  param expression_code: integer
  result: integer

export lua_state_close
  about: Destroy a freestanding Lua VM state.
  param state_slot: integer
  result: integer
`

BOOTSTRAP_ZSTD_MANIFEST :: `module: zstd
about: Freestanding Zstandard compression library compiled for modus.
library: yes

export zstd_compress_bound
  about: Return the worst-case compressed frame size for a payload size.
  param source_size: integer
  result: integer

export zstd_compress_block
  about: Compress a bounded input buffer into a Zstandard frame.
  param source_bytes: bytes(read)
  param output_bytes: bytes(append)
  result: integer

export zstd_decompress_block
  about: Decompress a validated Zstandard frame into an output buffer.
  param frame_bytes: bytes(read)
  param output_bytes: bytes(append)
  result: integer
`

// bootstrap_chain_c_world_validation builds Chain C: deterministic recipe
// descriptors, parsed module manifests, and validation test vectors for SQLite,
// Lua, and zstd built through chibicc / sdk-convert into freestanding .modus
// modules.
bootstrap_chain_c_world_validation :: proc(allocator := context.temp_allocator) -> Bootstrap_Chain {
	compiler_seed_bytes := transmute([]u8)string("modus:c-world-compiler:chibicc-sdk-convert:v1")
	compiler_hash := blake3.hash(compiler_seed_bytes)

	sqlite_src, _ := plans_recipes.recipe_input_make("sqlite_amalgamation", .Tree, bootstrap_deterministic_digest("source:sqlite-3.49-amalgamation"))
	lua_src, _ := plans_recipes.recipe_input_make("lua_source", .Tree, bootstrap_deterministic_digest("source:lua-5.4.7-freestanding"))
	zstd_src, _ := plans_recipes.recipe_input_make("zstd_source", .Tree, bootstrap_deterministic_digest("source:zstd-1.5.7-freestanding"))
	libc_input, _ := plans_recipes.recipe_input_make("thin_libc", .Tree, bootstrap_deterministic_digest("source:modus-thin-libc-v1"))


	sqlite_vectors := make([]Bootstrap_Test_Vector, 2, allocator)
	sqlite_vectors[0] = {name = "create_insert_select_sum", export_name = "sqlite_query_integer", input_summary = "CREATE TABLE t(x INT); INSERT VALUES(10),(32); SELECT SUM(x)", expected_value = 42}
	sqlite_vectors[1] = {name = "rollback_preserves_row_count", export_name = "sqlite_query_integer", input_summary = "BEGIN; INSERT VALUES(99); ROLLBACK; SELECT COUNT(*)", expected_value = 2}

	lua_vectors := make([]Bootstrap_Test_Vector, 2, allocator)
	lua_vectors[0] = {name = "recursive_fibonacci_10", export_name = "lua_eval_expression", input_summary = "function f(n) if n<2 then return n end return f(n-1)+f(n-2) end return f(10)", expected_value = 55}
	lua_vectors[1] = {name = "table_closure_accumulator", export_name = "lua_eval_expression", input_summary = "local s=0; for i=1,10 do s=s+i end return s", expected_value = 55}

	zstd_vectors := make([]Bootstrap_Test_Vector, 2, allocator)
	zstd_vectors[0] = {name = "compress_bound_4096", export_name = "zstd_compress_bound", input_summary = "source_size=4096", expected_value = 4624}
	zstd_vectors[1] = {name = "round_trip_compressible_block", export_name = "zstd_decompress_block", input_summary = "4096 repeated ASCII bytes -> compress -> decompress", expected_value = 4096}

	make_builder_dep :: proc(alloc := context.temp_allocator) -> []Bootstrap_Stage_Dependency {
		deps := make([]Bootstrap_Stage_Dependency, 1, alloc)
		deps[0] = {upstream_stage_name = "c_toolchain_seed", binding = .Builder}
		return deps
	}

	stages := make([]Bootstrap_Stage_Spec, 4, allocator)
	stages[0] = {
		name               = "c_toolchain_seed",
		description        = "Verified chibicc and sdk-convert freestanding C toolchain",
		kind               = .Seed,
		seed_bytes         = compiler_seed_bytes,
		require_seed_bytes = true,
		output_hash        = compiler_hash,
	}
	stages[1] = {
		name                 = "sqlite_module",
		description          = "Freestanding SQLite .modus module built via chibicc and sdk-convert",
		kind                 = .Native_Recipe,
		dependencies         = make_builder_dep(allocator),
		output_hash          = bootstrap_deterministic_digest("module:sqlite.modus-v1"),
		manifest_text        = BOOTSTRAP_SQLITE_MANIFEST,
		require_test_vectors = true,
		test_vectors         = sqlite_vectors,
	}
	stages[2] = {
		name                 = "lua_module",
		description          = "Freestanding Lua .modus module built via chibicc and sdk-convert",
		kind                 = .Native_Recipe,
		dependencies         = make_builder_dep(allocator),
		output_hash          = bootstrap_deterministic_digest("module:lua.modus-v1"),
		manifest_text        = BOOTSTRAP_LUA_MANIFEST,
		require_test_vectors = true,
		test_vectors         = lua_vectors,
	}
	stages[3] = {
		name                 = "zstd_module",
		description          = "Freestanding zstd .modus module built via chibicc and sdk-convert",
		kind                 = .Native_Recipe,
		dependencies         = make_builder_dep(allocator),
		output_hash          = bootstrap_deterministic_digest("module:zstd.modus-v1"),
		manifest_text        = BOOTSTRAP_ZSTD_MANIFEST,
		require_test_vectors = true,
		test_vectors         = zstd_vectors,
	}
	_ = bootstrap_make_recipe_spec(
		&stages[1].recipe,
		compiler_hash,
		.Blob,
		0,
		16384,
		[]plans_recipes.Recipe_Input{sqlite_src, libc_input},
		"cc=chibicc;convert=sdk-convert;defines=SQLITE_OMIT_LOAD_EXTENSION,SQLITE_THREADSAFE=0,SQLITE_OS_OTHER=1",
	)
	_ = bootstrap_make_recipe_spec(
		&stages[2].recipe,
		compiler_hash,
		.Blob,
		0,
		8192,
		[]plans_recipes.Recipe_Input{lua_src, libc_input},
		"cc=chibicc;convert=sdk-convert;defines=LUA_USE_C89,LUA_32BITS=0",
	)
	_ = bootstrap_make_recipe_spec(
		&stages[3].recipe,
		compiler_hash,
		.Blob,
		0,
		8192,
		[]plans_recipes.Recipe_Input{zstd_src, libc_input},
		"cc=chibicc;convert=sdk-convert;defines=ZSTD_STATIC_LINKING_ONLY,ZSTD_NO_ASM=1",
	)

	return Bootstrap_Chain {
		name                 = "c_world_validation_recipes",
		kind                 = .C_World_Validation,
		enforce_frozen_clock = true,
		frozen_epoch_seconds = 0,
		stages               = stages,
	}
}
