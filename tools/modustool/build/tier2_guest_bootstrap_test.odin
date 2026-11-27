#+build !freestanding
package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import gb "modus:contract/guest_builder"
import pr "modus:contract/plans_recipes"
import "modustool:foundation"

// Execute a native x86-64 Linux ELF binary with stdin_bytes piped in, capturing stdout.
@(private = "file")
tier2_test_run_elf_with_stdin :: proc(elf_path: string, stdin_bytes: []u8) -> (stdout_bytes: []u8, ok: bool) {
	in_path := strings.concatenate({elf_path, ".in"}, context.temp_allocator)
	out_path := strings.concatenate({elf_path, ".out"}, context.temp_allocator)
	if os.write_entire_file(in_path, stdin_bytes) != nil {
		return nil, false
	}
	defer _ = os.remove(in_path)
	defer _ = os.remove(out_path)

	in_fd, in_err := os.open(in_path, {.Read})
	if in_err != nil {
		return nil, false
	}
	defer os.close(in_fd)
	out_fd, out_err := os.open(out_path, {.Read, .Write, .Create, .Trunc}, os.Permissions_Default_File)
	if out_err != nil {
		return nil, false
	}
	defer os.close(out_fd)

	child, start_err := os.process_start({
		command = {elf_path},
		stdin   = in_fd,
		stdout  = out_fd,
		stderr  = os.stderr,
	})
	if start_err != nil {
		return nil, false
	}
	state, wait_err := os.process_wait(child)
	if wait_err != nil || !state.success {
		return nil, false
	}
	data, read_err := os.read_entire_file(out_path, context.allocator)
	if read_err != nil {
		return nil, false
	}
	return data, true
}

// Verify the 262-byte auditable x86-64 Linux ELF hex0 seed actually executes
// on Linux x86-64, self-assembles `hex0_x86_64.hex0` to the exact same 262
// bytes (`blake3(seed) == blake3(stage1)`), and Stage 1 hex0 assembles the
// 191-byte `catm` ELF which executes and copies arbitrary bytes losslessly.
@(test)
tier2_hex0_seed_executes_self_hosts_and_assembles_catm :: proc(t: ^testing.T) {
	// Refusals first: empty hex0 source and odd trailing nibble must be refused.
	_, empty_ok := tier2_hex0_assemble_reference("")
	testing.expect(t, !empty_ok, "empty hex0 source must be refused")
	_, comment_only_ok := tier2_hex0_assemble_reference("# only comment\n; another\n")
	testing.expect(t, !comment_only_ok, "comment-only hex0 source must be refused")
	_, odd_ok := tier2_hex0_assemble_reference("7F 4")
	testing.expect(t, !odd_ok, "odd trailing hex nibble must be refused")

	seed, seed_ok := tier2_hex0_assemble_reference(TIER2_HEX0_X86_64_SOURCE)
	if !testing.expect(t, seed_ok, "reference decoder must assemble TIER2_HEX0_X86_64_SOURCE") {
		return
	}
	defer delete(seed)
	testing.expect_value(t, len(seed), TIER2_HEX0_SEED_BYTES)
	testing.expect(t, len(seed) <= BOOTSTRAP_HEX0_SEED_MAX_BYTES, "hex0 seed must stay within human audit bound")
	testing.expect(t, strings.has_prefix(string(seed), "\x7fELF"), "hex0 seed must be a valid ELF64 binary")

	catm_ref, catm_ref_ok := tier2_hex0_assemble_reference(TIER2_CATM_X86_64_SOURCE)
	if !testing.expect(t, catm_ref_ok, "reference decoder must assemble TIER2_CATM_X86_64_SOURCE") {
		return
	}
	defer delete(catm_ref)
	testing.expect_value(t, len(catm_ref), TIER2_CATM_ELF_BYTES)

	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		temp_base, _ := os.temp_dir(context.temp_allocator)
		work := fmt.aprintf("%s/modus_tier2_hex0_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
		defer delete(work)
		_ = os.remove_all(work)
		testing.expect(t, os.make_directory_all(work) == nil)
		defer os.remove_all(work)

		hex0_seed_path := foundation.join(work, "/hex0_seed")
		testing.expect(t, os.write_entire_file(hex0_seed_path, seed) == nil)
		testing.expect(t, os.chmod(hex0_seed_path, {.Read_User, .Write_User, .Execute_User}) == nil)

		// Stage 1: execute the 262-byte ELF hex0 seed on its own annotated source!
		stage1_hex0, s1_ok := tier2_test_run_elf_with_stdin(hex0_seed_path, transmute([]u8)string(TIER2_HEX0_X86_64_SOURCE))
		if !testing.expect(t, s1_ok, "262-byte x86-64 ELF hex0 seed must execute cleanly on Linux") {
			return
		}
		defer delete(stage1_hex0)
		testing.expect_value(t, len(stage1_hex0), len(seed))
		testing.expect(t, slice.equal(stage1_hex0, seed), "hex0 self-assembly must reproduce exact seed bytes")
		testing.expect_value(t, blake3.hash(stage1_hex0), blake3.hash(seed))

		// Stage 2: execute Stage 1 hex0 to assemble the 191-byte catm ELF!
		hex0_s1_path := foundation.join(work, "/hex0_stage1")
		testing.expect(t, os.write_entire_file(hex0_s1_path, stage1_hex0) == nil)
		testing.expect(t, os.chmod(hex0_s1_path, {.Read_User, .Write_User, .Execute_User}) == nil)

		stage2_catm, s2_ok := tier2_test_run_elf_with_stdin(hex0_s1_path, transmute([]u8)string(TIER2_CATM_X86_64_SOURCE))
		if !testing.expect(t, s2_ok, "Stage 1 hex0 must assemble catm_x86_64.hex0") {
			return
		}
		defer delete(stage2_catm)
		testing.expect_value(t, len(stage2_catm), len(catm_ref))
		testing.expect(t, slice.equal(stage2_catm, catm_ref), "Stage 2 catm ELF must match reference assembly")

		// Execute the hex0-assembled catm binary on a multi-kilobyte payload!
		catm_path := foundation.join(work, "/catm")
		testing.expect(t, os.write_entire_file(catm_path, stage2_catm) == nil)
		testing.expect(t, os.chmod(catm_path, {.Read_User, .Write_User, .Execute_User}) == nil)

		payload := make([]u8, 4097)
		defer delete(payload)
		for i in 0 ..< len(payload) {
			payload[i] = u8((i * 37 + 13) & 0xFF)
		}
		echoed, catm_ok := tier2_test_run_elf_with_stdin(catm_path, payload)
		if !testing.expect(t, catm_ok, "hex0-assembled 191-byte catm ELF must execute cleanly") {
			return
		}
		defer delete(echoed)
		testing.expect(t, slice.equal(echoed, payload), "catm must copy multi-chunk payload identically")
	}
}

// Verify multi-stage Tier 2 guest_builder bundle packaging, cryptographic
// Stage 1 -> Stage 2 chaining, strict sandbox invariants, and multi-unit
// c_builder chibicc recipe encoding.
@(test)
tier2_guest_bootstrap_bundle_and_chibicc_c_builder_recipes :: proc(t: ^testing.T) {
	// Refusal: empty kernel or archive must be refused.
	_, bad_k := tier2_guest_bootstrap_make(nil, []u8{1})
	testing.expect(t, !bad_k, "empty kernel must be refused")
	_, bad_a := tier2_guest_bootstrap_make([]u8{1}, nil)
	testing.expect(t, !bad_a, "empty archive must be refused")

	kernel := []u8{'k', 'e', 'r', 'n', 'e', 'l', '-', 'v', '1'}
	archive := []u8{'0', '7', '0', '7', '0', '1', 'c', 'p', 'i', 'o'}
	bundle1, ok1 := tier2_guest_bootstrap_make(kernel, archive)
	bundle2, ok2 := tier2_guest_bootstrap_make(kernel, archive)
	if !testing.expect(t, ok1 && ok2, "tier2_guest_bootstrap_make must succeed deterministically") {
		return
	}
	testing.expect_value(t, bundle1.hex0_hash, bundle2.hex0_hash)
	testing.expect_value(t, bundle1.stage1_hex0.recipe_hash, bundle2.stage1_hex0.recipe_hash)
	testing.expect_value(t, bundle1.stage1_hex0.expected_output, bundle2.stage1_hex0.expected_output)
	testing.expect_value(t, bundle1.stage2_catm.recipe_hash, bundle2.stage2_catm.recipe_hash)
	testing.expect_value(t, bundle1.stage2_catm.expected_output, bundle2.stage2_catm.expected_output)
	testing.expect(t, bundle1.stage1_hex0.recipe_hash != bundle1.stage2_catm.recipe_hash)

	// Decode Stage 2's stored recipe object and confirm its `hex0_stage1` input
	// hash is cryptographically bound to Stage 1's expected MODTREE1 output hash
	// and its Guest_Build_Spec enforces zero network, frozen clock 0, read-only inputs.
	s2_rec_name := pr.recipe_object_name(bundle1.stage2_catm.recipe_hash)
	s2_name_text := pr.private_object_name_text(&s2_rec_name)
	found_s2 := false
	for obj in bundle1.objects {
		if obj.name != s2_name_text {
			continue
		}
		found_s2 = true
		spec := new(pr.Recipe_Spec, context.temp_allocator)
		decoded_hash, dec_ref := pr.recipe_object_decode(obj.bytes, spec)
		testing.expect_value(t, dec_ref, pr.Recipe_Refusal.None)
		testing.expect_value(t, decoded_hash, bundle1.stage2_catm.recipe_hash)
		testing.expect_value(t, spec.source_date_unix, u64(0))
		found_stage1_link := false
		for i in 0 ..< spec.input_count {
			in_name := string(spec.inputs[i].name_bytes[:spec.inputs[i].name_length])
			if in_name == "hex0_stage1" {
				found_stage1_link = true
				testing.expect_value(t, spec.inputs[i].hash, bundle1.stage1_hex0.expected_output)
			}
		}
		testing.expect(t, found_stage1_link, "Stage 2 recipe must link hex0_stage1 input to Stage 1 output tree")

		guest_spec, gb_ref := gb.decode_build_spec(spec.arguments[:spec.arguments_length])
		testing.expect_value(t, gb_ref, gb.Guest_Builder_Refusal.None)
		testing.expect(t, !guest_spec.allow_network)
		testing.expect(t, !guest_spec.allow_real_clock)
		testing.expect(t, !guest_spec.allow_writable_inputs)
		testing.expect_value(t, guest_spec.frozen_epoch_seconds, u64(0))
	}
	testing.expect(t, found_s2, "Stage 2 recipe object must be stored in bundle")

	// Verify readiness table covers all 8 stages and honestly separates
	// executable guest stages from upstream archive-gated stages.
	testing.expect_value(t, len(TIER2_BOOTSTRAP_STAGES), 8)
	testing.expect_value(t, TIER2_BOOTSTRAP_STAGES[0].readiness, Tier2_Stage_Readiness.Executable_In_Guest)
	testing.expect_value(t, TIER2_BOOTSTRAP_STAGES[1].readiness, Tier2_Stage_Readiness.Executable_In_Guest)
	testing.expect_value(t, TIER2_BOOTSTRAP_STAGES[2].readiness, Tier2_Stage_Readiness.Gated_Upstream_Archive_Pin)
	testing.expect_value(t, TIER2_BOOTSTRAP_STAGES[7].readiness, Tier2_Stage_Readiness.Gated_Multi_Hour_Guest_Budget)

	// Verify real multi-unit c_builder recipe construction for chibicc Stage 1 & Stage 2.
	chibicc_folder := os.get_env(foundation.CHIBICC.variable, context.temp_allocator)
	if chibicc_folder != "" {
		prog, prog_ok := c_self_host_program(chibicc_folder)
		if testing.expect(t, prog_ok) {
			c_builder_h := blake3.hash(transmute([]u8)string("c_builder"))
			src_tree_h := blake3.hash(transmute([]u8)string("chibicc_tree"))
			cc0_h := blake3.hash(transmute([]u8)string("chibicc_stage0"))
			cc1_h := blake3.hash(transmute([]u8)string("chibicc_stage1"))
			asm_h := blake3.hash(transmute([]u8)string("assemble"))
			host_h := blake3.hash(transmute([]u8)string("host"))

			// Refusal: zero builder hash must be refused.
			bad_spec := new(pr.Recipe_Spec, context.temp_allocator)
			_, zero_ok := bootstrap_chibicc_c_builder_recipe_make(bad_spec, {}, src_tree_h, cc0_h, asm_h, host_h, prog)
			testing.expect(t, !zero_ok, "zero c_builder hash must be refused")

			s1_spec := new(pr.Recipe_Spec, context.temp_allocator)
			s2_spec := new(pr.Recipe_Spec, context.temp_allocator)
			rh1, ok_r1 := bootstrap_chibicc_c_builder_recipe_make(s1_spec, c_builder_h, src_tree_h, cc0_h, asm_h, host_h, prog)
			rh2, ok_r2 := bootstrap_chibicc_c_builder_recipe_make(s2_spec, c_builder_h, src_tree_h, cc1_h, asm_h, host_h, prog)
			testing.expect(t, ok_r1 && ok_r2, "chibicc Stage 1 and Stage 2 c_builder recipes must validate")
			testing.expect(t, rh1 != rh2, "Stage 1 and Stage 2 recipes differ by compiler input hash")
			testing.expect_value(t, s1_spec.input_count, u32(4))
			testing.expect_value(t, s1_spec.arguments_length, s2_spec.arguments_length)
		}
	}
}
