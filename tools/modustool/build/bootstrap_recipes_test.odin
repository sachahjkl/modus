package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import assembler "internal:assemble/assembler"
import "modus:contract/blake3"
import module "modus:contract/module"
import module_writer "modus:contract/module_file_writer"
import "modus:contract/plans_recipes"
import "modustool:foundation"

@(test)
bootstrap_recipes_catalog_validates_all_sandboxes_and_hashes :: proc(t: ^testing.T) {
	catalog, ok := bootstrap_recipe_catalog()
	testing.expect(t, ok, "canonical bootstrap recipe catalog must build cleanly")

	digest_a, refusal_a := bootstrap_recipe_catalog_verify(catalog[:])
	testing.expect_value(t, refusal_a, Bootstrap_Recipe_Catalog_Refusal.None)
	testing.expect(t, !bootstrap_hash_is_zero(digest_a), "catalog digest must be non-zero")

	// Determinism: building and verifying again gives the exact same catalog digest.
	catalog_b, ok_b := bootstrap_recipe_catalog()
	testing.expect(t, ok_b)
	digest_b, refusal_b := bootstrap_recipe_catalog_verify(catalog_b[:])
	testing.expect_value(t, refusal_b, Bootstrap_Recipe_Catalog_Refusal.None)
	testing.expect(t, digest_a == digest_b, "catalog digest must be bit-for-bit stable across runs")

	// Verify chibicc Stage 1 == Stage 2 fixed-point hash check.
	ch1, ch2, ch_ok := bootstrap_recipe_chibicc_self_host()
	testing.expect(t, ch_ok)
	testing.expect_value(t, bootstrap_verify_chibicc_fixed_point(ch1.expected_output_hash, ch2.expected_output_hash), Bootstrap_Recipe_Catalog_Refusal.None)

	// Verify input-order independence of plans_recipes.recipe_hash on chibicc_stage1.
	{
		h_orig, r_orig := plans_recipes.recipe_hash(&ch1.recipe)
		testing.expect_value(t, r_orig, plans_recipes.Recipe_Refusal.None)
		reordered := ch1.recipe
		reordered.inputs[0], reordered.inputs[2] = reordered.inputs[2], reordered.inputs[0]
		h_reordered, r_reordered := plans_recipes.recipe_hash(&reordered)
		testing.expect_value(t, r_reordered, plans_recipes.Recipe_Refusal.None)
		testing.expect(t, h_orig == h_reordered, "recipe_hash must be invariant to input order")
	}

	// Verify live_bootstrap_chain has the exact 6-stage topological chain:
	// hex0 -> M2-Planet -> mes -> tcc -> gcc -> odin.
	chain, chain_ok := bootstrap_recipe_live_bootstrap_chain()
	testing.expect(t, chain_ok)
	expected_ids := [LIVE_BOOTSTRAP_STAGE_COUNT]Bootstrap_Recipe_Id {
		.Live_Bootstrap_Hex0,
		.Live_Bootstrap_M2_Planet,
		.Live_Bootstrap_Mes,
		.Live_Bootstrap_Tcc,
		.Live_Bootstrap_Gcc,
		.Live_Bootstrap_Odin,
	}
	for expected_id, i in expected_ids {
		testing.expect_value(t, chain[i].id, expected_id)
		testing.expect(t, chain[i].has_guest_spec, "every live-bootstrap stage must carry a guest_builder spec")
		testing.expect(t, !chain[i].guest_spec.allow_network)
		testing.expect(t, !chain[i].guest_spec.allow_real_clock)
		testing.expect(t, !chain[i].guest_spec.allow_writable_inputs)
		testing.expect_value(t, chain[i].guest_spec.frozen_epoch_seconds, u64(0))
	}
	chain_digest, chain_refusal := bootstrap_recipe_catalog_verify(chain[:])
	testing.expect_value(t, chain_refusal, Bootstrap_Recipe_Catalog_Refusal.None)
	testing.expect(t, !bootstrap_hash_is_zero(chain_digest))
}

@(test)
bootstrap_recipes_catalog_adversarial_refusals :: proc(t: ^testing.T) {
	// Closed enum border: 0, one past highest member, max(u64).
	for bad_word in ([?]u64{0, 12, 255, max(u64)}) {
		_, id_ok := bootstrap_recipe_id_from_word(bad_word)
		testing.expectf(t, !id_ok, "recipe id %d must be refused", bad_word)
	}
	for good_word in u64(1) ..= 11 {
		_, id_ok := bootstrap_recipe_id_from_word(good_word)
		testing.expect(t, id_ok)
	}

	// Empty catalog refused.
	_, empty_refusal := bootstrap_recipe_catalog_verify(nil)
	testing.expect_value(t, empty_refusal, Bootstrap_Recipe_Catalog_Refusal.Empty_Catalog)

	// Chibicc fixed-point refusals: zero hash and 1-bit divergence.
	ch1, ch2, _ := bootstrap_recipe_chibicc_self_host()
	testing.expect_value(t, bootstrap_verify_chibicc_fixed_point({}, ch2.expected_output_hash), Bootstrap_Recipe_Catalog_Refusal.Zero_Stage_Hash)
	testing.expect_value(t, bootstrap_verify_chibicc_fixed_point(ch1.expected_output_hash, {}), Bootstrap_Recipe_Catalog_Refusal.Zero_Stage_Hash)
	tampered_ch2 := ch2.expected_output_hash
	tampered_ch2[31] ~= 0x01
	testing.expect_value(t, bootstrap_verify_chibicc_fixed_point(ch1.expected_output_hash, tampered_ch2), Bootstrap_Recipe_Catalog_Refusal.Fixed_Point_Mismatch)

	// Reversed topological order in live_bootstrap_chain must be refused.
	{
		bad_chain, _ := bootstrap_recipe_live_bootstrap_chain()
		bad_chain[1], bad_chain[2] = bad_chain[2], bad_chain[1]
		_, ref := bootstrap_recipe_catalog_verify(bad_chain[:])
		testing.expect_value(t, ref, Bootstrap_Recipe_Catalog_Refusal.Topological_Order_Violation)
	}

	// Sandbox violations on guest stages must be refused.
	{
		bad_chain, _ := bootstrap_recipe_live_bootstrap_chain()
		bad_chain[2].guest_spec.allow_network = true
		_, ref := bootstrap_recipe_catalog_verify(bad_chain[:])
		testing.expect_value(t, ref, Bootstrap_Recipe_Catalog_Refusal.Guest_Network_Enabled)
	}
	{
		bad_chain, _ := bootstrap_recipe_live_bootstrap_chain()
		bad_chain[3].guest_spec.allow_real_clock = true
		_, ref := bootstrap_recipe_catalog_verify(bad_chain[:])
		testing.expect_value(t, ref, Bootstrap_Recipe_Catalog_Refusal.Guest_Real_Clock_Enabled)
	}
	{
		bad_chain, _ := bootstrap_recipe_live_bootstrap_chain()
		bad_chain[4].guest_spec.allow_writable_inputs = true
		_, ref := bootstrap_recipe_catalog_verify(bad_chain[:])
		testing.expect_value(t, ref, Bootstrap_Recipe_Catalog_Refusal.Guest_Writable_Inputs_Enabled)
	}
	{
		bad_catalog, _ := bootstrap_recipe_catalog()
		bad_catalog[2].recipe.source_date_unix = 1700000000
		_, ref := bootstrap_recipe_catalog_verify(bad_catalog[:])
		testing.expect_value(t, ref, Bootstrap_Recipe_Catalog_Refusal.Clock_Not_Frozen)
	}
	{
		bad_catalog, _ := bootstrap_recipe_catalog()
		bad_catalog[0].id = .Sqlite
		_, ref := bootstrap_recipe_catalog_verify(bad_catalog[:])
		testing.expect_value(t, ref, Bootstrap_Recipe_Catalog_Refusal.Duplicate_Recipe_Id)
	}
}

// Proves the native x86-64 assembler (internal:assemble/assembler) and module
// file writer assemble multi-function AT&T x86-64 assembly deterministically
// across two independent runs into bit-for-bit identical validated .modus modules.
@(test)
bootstrap_recipes_native_assembler_deterministic_module :: proc(t: ^testing.T) {
	asm_source := `section data
factor:
  byte 3
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0

section code
export scale_add(a: Integer, b: Integer) -> Integer
export sum_range(limit: Integer) -> Integer

helper_scale:
  push %rbp
  mov %rsp, %rbp
  mov factor(%rip), %rax
  imul %rdi, %rax
  mov %rbp, %rsp
  pop %rbp
  ret

scale_add:
  push %rbp
  mov %rsp, %rbp
  push %rsi
  call helper_scale
  pop %rsi
  add %rsi, %rax
  mov %rbp, %rsp
  pop %rbp
  ret

sum_range:
  push %rbp
  mov %rsp, %rbp
  xor %rax, %rax
  xor %rcx, %rcx
.L.loop:
  cmp %rdi, %rcx
  jg .L.done
  add %rcx, %rax
  inc %rcx
  jmp .L.loop
.L.done:
  mov %rbp, %rsp
  pop %rbp
  ret
`

	assemble_once :: proc(t: ^testing.T, source: string) -> (module_bytes: []u8, digest: blake3.Hash) {
		memory := new(assembler.Workspace_Memory)
		defer free(memory)
		workspace := assembler.workspace_of_memory(memory)

		parts, asm_refusal := assembler.assemble(source, &workspace)
		testing.expect_value(t, asm_refusal.refusal, assembler.Refusal.None)

		size_needed, size_refusal := module_writer.file_size_needed(parts)
		testing.expect_value(t, size_refusal.refusal, module_writer.Refusal.None)
		testing.expect(t, size_needed > 0)

		output := make([]u8, int(size_needed))
		written_bytes, write_refusal := module_writer.write(parts, output)
		testing.expect_value(t, write_refusal.refusal, module_writer.Refusal.None)
		testing.expect_value(t, written_bytes, size_needed)
		testing.expect_value(t, module.validate(output), module.Error.None)
		return output, blake3.hash(output)
	}

	mod_one, hash_one := assemble_once(t, asm_source)
	defer delete(mod_one)
	mod_two, hash_two := assemble_once(t, asm_source)
	defer delete(mod_two)

	testing.expect(t, hash_one == hash_two, "native x86-64 assembler must emit bit-for-bit identical .modus modules")
	testing.expect_value(t, len(mod_one), len(mod_two))
	testing.expect_value(t, int(module.count(mod_one, .Exports)), 3)
}

@(private = "file")
recipes_test_temp_dir :: proc(t: ^testing.T, label: string) -> string {
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.tprintf("%s/modus_recipes_test_%s_%d", strings.trim_right(temp_base, "/"), label, os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "must create recipes test temporary directory")
	return dir
}

@(private = "file")
recipes_test_run_command :: proc(command: []string, working_dir: string) -> bool {
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

// Proves multi-function C + hand-written x86-64 assembly compiled through
// clang + ld.lld -r (ET_REL) + convert_elf_with_manifest produces bit-for-bit
// identical validated .modus modules across two independent runs.
@(test)
bootstrap_recipes_c_and_asm_et_rel_to_modus_deterministic :: proc(t: ^testing.T) {
	temp_root := recipes_test_temp_dir(t, "c_asm_et_rel")
	defer _ = os.remove_all(temp_root)

	asm_helper_s := `.text
.globl asm_mix_pair
.type asm_mix_pair, @function
asm_mix_pair:
	movq %rdi, %rax
	shlq $3, %rax
	xorq %rsi, %rax
	addq $17, %rax
	ret
.size asm_mix_pair, .-asm_mix_pair
`

	c_driver := `typedef long long int64_t;
typedef unsigned char uint8_t;

uint8_t modus_own_hash[32];

extern int64_t asm_mix_pair(int64_t a, int64_t b);

static int64_t fold_sequence(int64_t seed, int64_t count) {
	int64_t acc = seed;
	for (int64_t i = 0; i < count; i += 1) {
		acc = asm_mix_pair(acc, i * 13 + 5);
	}
	return acc;
}

int64_t bootstrap_mix_hash(int64_t seed, int64_t rounds) {
	if (rounds < 0) {
		return -1;
	}
	if (rounds > 64) {
		rounds = 64;
	}
	return fold_sequence(seed, rounds);
}

int64_t bootstrap_pair_combine(int64_t left, int64_t right) {
	return asm_mix_pair(left, right) ^ asm_mix_pair(right, left);
}
`

	manifest_text := `module: c_asm_proof
about: Deterministic freestanding C plus x86-64 assembly module proof.
library: yes

export bootstrap_mix_hash
  about: Fold a deterministic x86-64 assembly mixing routine over a bounded round count.
  param seed: integer
  param rounds: integer
  result: integer

export bootstrap_pair_combine
  about: Combine two integers symmetrically using the linked x86-64 assembly helper.
  param left: integer
  param right: integer
  result: integer
`

	testing.expect(t, os.write_entire_file(foundation.join(temp_root, "/helper.S"), transmute([]u8)asm_helper_s) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(temp_root, "/driver.c"), transmute([]u8)c_driver) == nil)

	parsed_manifest, manifest_problem := manifest_parse(manifest_text)
	testing.expect_value(t, manifest_problem, "")

	build_run :: proc(t: ^testing.T, work_dir: string, tag: string, manifest: Module_Manifest) -> (module_bytes: []u8, digest: blake3.Hash) {
		asm_obj := fmt.tprintf("helper_%s.o", tag)
		c_obj := fmt.tprintf("driver_%s.o", tag)
		rel_obj := fmt.tprintf("merged_%s.o", tag)

		cmd_asm := [?]string{
			"clang", "-target", "x86_64-unknown-none-elf",
			"-c", "helper.S", "-o", asm_obj,
		}
		testing.expect(t, recipes_test_run_command(cmd_asm[:], work_dir), "clang must assemble helper.S")

		cmd_c := [?]string{
			"clang", "-target", "x86_64-unknown-none-elf",
			"-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-fno-common",
			"-fPIC", "-mno-red-zone", "-fno-asynchronous-unwind-tables", "-O2",
			"-c", "driver.c", "-o", c_obj,
		}
		testing.expect(t, recipes_test_run_command(cmd_c[:], work_dir), "clang must compile driver.c")

		cmd_ld := [?]string{"ld.lld", "-r", "-o", rel_obj, asm_obj, c_obj}
		testing.expect(t, recipes_test_run_command(cmd_ld[:], work_dir), "ld.lld -r must link C and assembly ET_REL objects")

		rel_bytes, read_err := os.read_entire_file(foundation.join(work_dir, "/", rel_obj), context.allocator)
		testing.expect(t, read_err == nil)
		defer delete(rel_bytes)

		converted, ok := convert_elf_with_manifest(rel_bytes, manifest, nil)
		testing.expect(t, ok, "convert_elf_with_manifest must convert C+asm ET_REL into .modus")
		testing.expect_value(t, module.validate(converted), module.Error.None)
		return converted, blake3.hash(converted)
	}

	run_one, hash_one := build_run(t, temp_root, "a", parsed_manifest)
	defer delete(run_one)
	run_two, hash_two := build_run(t, temp_root, "b", parsed_manifest)
	defer delete(run_two)

	testing.expect(t, hash_one == hash_two, "C + x86-64 assembly ET_REL -> .modus conversion must be bit-for-bit deterministic")
	testing.expect_value(t, len(run_one), len(run_two))
	testing.expect_value(t, int(module.count(run_one, .Exports)), 3)
}
