#+build !freestanding
package bootstrap_chain

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
test_hash :: proc(seed: u8) -> blake3.Hash {
	h: blake3.Hash
	h[0] = seed
	h[15] = seed ~ 0x5A
	h[31] = seed + 1
	return h
}

@(test)
bootstrap_border_and_stage_refusals :: proc(t: ^testing.T) {
	// Enum border refusals.
	_, ok := bootstrap_stage_kind_of_word(0)
	testing.expect_value(t, ok, false)
	_, ok = bootstrap_stage_kind_of_word(99)
	testing.expect_value(t, ok, false)
	kind, kind_ok := bootstrap_stage_kind_of_word(u64(Bootstrap_Stage_Kind.Odin_Fork_Stage))
	testing.expect_value(t, kind_ok, true)
	testing.expect_value(t, kind, Bootstrap_Stage_Kind.Odin_Fork_Stage)

	// Stage construction refusals.
	h1 := test_hash(1)
	h2 := test_hash(2)
	_, ref := bootstrap_stage_make("", .Seed_Hex0, h1, h2)
	testing.expect_value(t, ref, Bootstrap_Refusal.Empty_Stage_Name)

	long_name := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 49 bytes > 48
	_, ref = bootstrap_stage_make(long_name, .Seed_Hex0, h1, h2)
	testing.expect_value(t, ref, Bootstrap_Refusal.Name_Too_Long)

	_, ref = bootstrap_stage_make("bad\tstage", .Seed_Hex0, h1, h2)
	testing.expect_value(t, ref, Bootstrap_Refusal.Bad_Control_Byte)

	_, ref = bootstrap_stage_make("hex0", Bootstrap_Stage_Kind(0), h1, h2)
	testing.expect_value(t, ref, Bootstrap_Refusal.Bad_Stage_Kind)

	_, ref = bootstrap_stage_make("hex0", .Seed_Hex0, {}, h2)
	testing.expect_value(t, ref, Bootstrap_Refusal.Zero_Hash)

	_, ref = bootstrap_stage_make("hex0", .Seed_Hex0, h1, {})
	testing.expect_value(t, ref, Bootstrap_Refusal.Zero_Hash)

	// Null and empty chain refusals.
	_, ref = bootstrap_chain_validate(nil)
	testing.expect_value(t, ref, Bootstrap_Refusal.Null_Chain)

	empty: Bootstrap_Chain
	_, ref = bootstrap_chain_validate(&empty)
	testing.expect_value(t, ref, Bootstrap_Refusal.Empty_Chain)
}

@(test)
bootstrap_seed_and_c_self_host_bounds :: proc(t: ^testing.T) {
	chain: Bootstrap_Chain

	// hex0 seed past 1024 bytes (1025) is refused.
	bad_seed, _ := bootstrap_stage_make("hex0", .Seed_Hex0, test_hash(1), test_hash(2))
	bad_seed.seed_bytes = HEX0_SEED_MAX_BYTES + 1
	_, ref := bootstrap_chain_add_stage(&chain, bad_seed)
	testing.expect_value(t, ref, Bootstrap_Refusal.Seed_Too_Large)
	testing.expect_value(t, chain.count, u16(0))

	// hex0 seed of 0 bytes is refused.
	bad_seed.seed_bytes = 0
	_, ref = bootstrap_chain_add_stage(&chain, bad_seed)
	testing.expect_value(t, ref, Bootstrap_Refusal.Seed_Too_Large)

	// hex0 seed with an upstream dependency is refused.
	bad_seed.seed_bytes = 512
	testing.expect_value(t, bootstrap_stage_add_dep(&bad_seed, 0), Bootstrap_Refusal.Seed_Has_Dependencies)

	// C_Self_Host_Stage with workspace < 295 KiB or missing sources is refused.
	c_stage, _ := bootstrap_stage_make("chibicc_stage1", .C_Self_Host_Stage, test_hash(3), test_hash(4))
	c_stage.workspace_bytes = CHIBICC_WORKSPACE_MIN_BYTES - 1
	testing.expect_value(t, bootstrap_stage_add_source(&c_stage, test_hash(5)), Bootstrap_Refusal.None)
	_, ref = bootstrap_chain_add_stage(&chain, c_stage)
	testing.expect_value(t, ref, Bootstrap_Refusal.Workspace_Too_Small)

	c_no_src, _ := bootstrap_stage_make("chibicc_no_src", .C_Self_Host_Stage, test_hash(3), test_hash(4))
	c_no_src.workspace_bytes = CHIBICC_WORKSPACE_MIN_BYTES
	_, ref = bootstrap_chain_add_stage(&chain, c_no_src)
	testing.expect_value(t, ref, Bootstrap_Refusal.Missing_Sources)

	// Zero source hash is refused.
	testing.expect_value(t, bootstrap_stage_add_source(&c_no_src, {}), Bootstrap_Refusal.Zero_Hash)
}

@(test)
bootstrap_dag_cycle_and_unknown_dep_refusals :: proc(t: ^testing.T) {
	// Self-dependency refused.
	self_chain: Bootstrap_Chain
	a, _ := bootstrap_stage_make("a", .Live_Bootstrap_Tool, test_hash(1), test_hash(2))
	testing.expect_value(t, bootstrap_stage_add_dep(&a, 0), Bootstrap_Refusal.None)
	_, ref := bootstrap_chain_add_stage(&self_chain, a)
	testing.expect_value(t, ref, Bootstrap_Refusal.None)
	_, val_ref := bootstrap_chain_validate(&self_chain)
	testing.expect_value(t, val_ref, Bootstrap_Refusal.Self_Dependency)

	// Unknown dependency index refused.
	unk_chain: Bootstrap_Chain
	u, _ := bootstrap_stage_make("u", .Live_Bootstrap_Tool, test_hash(1), test_hash(2))
	testing.expect_value(t, bootstrap_stage_add_dep(&u, 9), Bootstrap_Refusal.None)
	_, _ = bootstrap_chain_add_stage(&unk_chain, u)
	_, val_ref = bootstrap_chain_validate(&unk_chain)
	testing.expect_value(t, val_ref, Bootstrap_Refusal.Unknown_Dependency)

	// 2-node cycle (0 -> 1 -> 0) refused with zero mutation to topo_order_out.
	cyc_chain: Bootstrap_Chain
	n0, _ := bootstrap_stage_make("n0", .Live_Bootstrap_Tool, test_hash(1), test_hash(2))
	n1, _ := bootstrap_stage_make("n1", .Live_Bootstrap_Tool, test_hash(3), test_hash(4))
	testing.expect_value(t, bootstrap_stage_add_dep(&n0, 1), Bootstrap_Refusal.None)
	testing.expect_value(t, bootstrap_stage_add_dep(&n1, 0), Bootstrap_Refusal.None)
	_, _ = bootstrap_chain_add_stage(&cyc_chain, n0)
	_, _ = bootstrap_chain_add_stage(&cyc_chain, n1)

	sentinel := [2]u16{99, 88}
	cnt, cyc_ref := bootstrap_chain_validate(&cyc_chain, sentinel[:])
	testing.expect_value(t, cyc_ref, Bootstrap_Refusal.Cycle_Detected)
	testing.expect_value(t, cnt, 0)
	testing.expect_value(t, sentinel[0], u16(99))
	testing.expect_value(t, sentinel[1], u16(88))

	// Duplicate stage name refused.
	dup, _ := bootstrap_stage_make("n0", .Live_Bootstrap_Tool, test_hash(5), test_hash(6))
	_, dup_ref := bootstrap_chain_add_stage(&cyc_chain, dup)
	testing.expect_value(t, dup_ref, Bootstrap_Refusal.Duplicate_Stage)
}

@(test)
bootstrap_full_chain_and_host_equivalence :: proc(t: ^testing.T) {
	// Full chain covering hex0 -> live-bootstrap -> odin_fork and
	// c_compiler -> chibicc self-host -> sqlite/lua/zstd.
	chain: Bootstrap_Chain

	hex0, _ := bootstrap_stage_make("hex0", .Seed_Hex0, test_hash(10), test_hash(11))
	hex0.seed_bytes = 512
	idx_hex0, r0 := bootstrap_chain_add_stage(&chain, hex0)
	testing.expect_value(t, r0, Bootstrap_Refusal.None)

	live_bs, _ := bootstrap_stage_make("live_bootstrap", .Live_Bootstrap_Tool, test_hash(20), test_hash(21))
	testing.expect_value(t, bootstrap_stage_add_dep(&live_bs, idx_hex0), Bootstrap_Refusal.None)
	idx_live, r1 := bootstrap_chain_add_stage(&chain, live_bs)
	testing.expect_value(t, r1, Bootstrap_Refusal.None)

	odin_fork, _ := bootstrap_stage_make("odin_fork", .Odin_Fork_Stage, test_hash(30), test_hash(31))
	testing.expect_value(t, bootstrap_stage_add_dep(&odin_fork, idx_live), Bootstrap_Refusal.None)
	idx_odin, r2 := bootstrap_chain_add_stage(&chain, odin_fork)
	testing.expect_value(t, r2, Bootstrap_Refusal.None)

	chibicc1, _ := bootstrap_stage_make("chibicc_stage1", .C_Self_Host_Stage, test_hash(40), test_hash(41))
	chibicc1.workspace_bytes = CHIBICC_WORKSPACE_MIN_BYTES
	testing.expect_value(t, bootstrap_stage_add_dep(&chibicc1, idx_live), Bootstrap_Refusal.None)
	for s in u8(1) ..= u8(14) {
		testing.expect_value(t, bootstrap_stage_add_source(&chibicc1, test_hash(100 + s)), Bootstrap_Refusal.None)
	}
	idx_ch1, r3 := bootstrap_chain_add_stage(&chain, chibicc1)
	testing.expect_value(t, r3, Bootstrap_Refusal.None)

	// Fixed-point stage 2 shares expected_output_hash with stage 1.
	chibicc2, _ := bootstrap_stage_make("chibicc_stage2", .C_Self_Host_Stage, test_hash(42), test_hash(41))
	chibicc2.workspace_bytes = CHIBICC_WORKSPACE_MIN_BYTES
	testing.expect_value(t, bootstrap_stage_add_dep(&chibicc2, idx_ch1), Bootstrap_Refusal.None)
	for s in u8(1) ..= u8(14) {
		testing.expect_value(t, bootstrap_stage_add_source(&chibicc2, test_hash(100 + s)), Bootstrap_Refusal.None)
	}
	idx_ch2, r4 := bootstrap_chain_add_stage(&chain, chibicc2)
	testing.expect_value(t, r4, Bootstrap_Refusal.None)

	sqlite, _ := bootstrap_stage_make("sqlite", .Library_Build_Stage, test_hash(50), test_hash(51))
	testing.expect_value(t, bootstrap_stage_add_dep(&sqlite, idx_ch2), Bootstrap_Refusal.None)
	_, r5 := bootstrap_chain_add_stage(&chain, sqlite)
	testing.expect_value(t, r5, Bootstrap_Refusal.None)

	lua, _ := bootstrap_stage_make("lua", .Library_Build_Stage, test_hash(60), test_hash(61))
	testing.expect_value(t, bootstrap_stage_add_dep(&lua, idx_ch2), Bootstrap_Refusal.None)
	_, r6 := bootstrap_chain_add_stage(&chain, lua)
	testing.expect_value(t, r6, Bootstrap_Refusal.None)

	zstd, _ := bootstrap_stage_make("zstd", .Library_Build_Stage, test_hash(70), test_hash(71))
	testing.expect_value(t, bootstrap_stage_add_dep(&zstd, idx_ch2), Bootstrap_Refusal.None)
	_, r7 := bootstrap_chain_add_stage(&chain, zstd)
	testing.expect_value(t, r7, Bootstrap_Refusal.None)

	order: [CHAIN_MAX_STAGES]u16
	topo_n, val_ref := bootstrap_chain_validate(&chain, order[:])
	testing.expect_value(t, val_ref, Bootstrap_Refusal.None)
	testing.expect_value(t, topo_n, 8)
	testing.expect_value(t, order[0], idx_hex0)
	testing.expect_value(t, order[1], idx_live)
	testing.expect_value(t, order[2], idx_odin)

	// Matching host outputs pass equivalence verification.
	observed := [8]blake3.Hash{
		test_hash(11),
		test_hash(21),
		test_hash(31),
		test_hash(41),
		test_hash(41),
		test_hash(51),
		test_hash(61),
		test_hash(71),
	}
	report := bootstrap_chain_verify_host_equivalence(&chain, observed[:])
	testing.expect_value(t, report.refusal, Bootstrap_Refusal.None)
	testing.expect_value(t, report.matched, true)
	testing.expect_value(t, report.verified_stages, u16(8))

	// Wrong output count is refused.
	bad_len := bootstrap_chain_verify_host_equivalence(&chain, observed[:3])
	testing.expect_value(t, bad_len.refusal, Bootstrap_Refusal.Output_Count_Mismatch)
	testing.expect_value(t, bad_len.matched, false)

	// Tampering one bit on odin_fork output hash fails at that exact stage.
	tampered := observed
	tampered[idx_odin][0] ~= 0x01
	mismatch := bootstrap_chain_verify_host_equivalence(&chain, tampered[:])
	testing.expect_value(t, mismatch.refusal, Bootstrap_Refusal.Host_Mismatch)
	testing.expect_value(t, mismatch.matched, false)
	testing.expect_value(t, mismatch.first_mismatch_stage, idx_odin)
	testing.expect_value(t, mismatch.verified_stages, u16(2))
}
