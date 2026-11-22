// Reproducible recipe definitions for self-hosting chibicc (Stage 1 == Stage 2)
// and building SQLite, Lua, and zstd with the modus C compiler on modus
// (src/md/features/bootstrap.md).
package build

import "modus:contract/blake3"

C_World_Recipe_Stage :: enum u8 {
	Chibicc_Stage1 = 1,
	Chibicc_Stage2 = 2,
	Sqlite_Core    = 3,
	Lua_Vm         = 4,
	Zstd_Codec     = 5,
}

C_World_Recipe :: struct {
	stage:           C_World_Recipe_Stage,
	name:            string,
	compiler_stage:  string,
	entry_source:    string,
	cflags:          string,
	self_test_suite: string,
	target_triple:   string,
}

@(rodata)
C_WORLD_RECIPES := [?]C_World_Recipe{
	{
		stage           = .Chibicc_Stage1,
		name            = "chibicc_stage1",
		compiler_stage  = "host_c_compiler",
		entry_source    = "main.c",
		cflags          = "-std=c11 -O0 -ffreestanding -fno-pic",
		self_test_suite = "chibicc_unit_tests",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Chibicc_Stage2,
		name            = "chibicc_stage2",
		compiler_stage  = "chibicc_stage1",
		entry_source    = "main.c",
		cflags          = "-std=c11 -O0 -ffreestanding -fno-pic",
		self_test_suite = "chibicc_stage_hash_equal",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Sqlite_Core,
		name            = "sqlite3",
		compiler_stage  = "chibicc_stage2",
		entry_source    = "sqlite3.c",
		cflags          = "-DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1",
		self_test_suite = "sqlite3_in_memory_sql_test",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Lua_Vm,
		name            = "lua54",
		compiler_stage  = "chibicc_stage2",
		entry_source    = "onelua.c",
		cflags          = "-DLUA_USE_C89 -DLUA_32BITS=0 -ffreestanding",
		self_test_suite = "lua_language_suite",
		target_triple   = "x86_64-modus-freestanding",
	},
	{
		stage           = .Zstd_Codec,
		name            = "zstd",
		compiler_stage  = "chibicc_stage2",
		entry_source    = "zstd_single_file.c",
		cflags          = "-DZSTD_DISABLE_ASM=1 -DZSTD_MULTITHREAD=0 -ffreestanding",
		self_test_suite = "zstd_roundtrip_vectors",
		target_triple   = "x86_64-modus-freestanding",
	},
}

// c_world_recipe_hash computes the deterministic BLAKE3 recipe identity hash
// over all build inputs so the object cache keys each stage unambiguously.
c_world_recipe_hash :: proc(r: C_World_Recipe) -> [32]u8 {
	buf: [512]u8
	pos := 0
	parts := [?]string{r.name, "|", r.compiler_stage, "|", r.entry_source, "|", r.cflags, "|", r.target_triple}
	for p in parts {
		n := min(len(p), len(buf) - pos)
		copy(buf[pos : pos + n], p[:n])
		pos += n
	}
	return blake3.derive_key("modus c world recipe v1", buf[:pos])
}

// chibicc_stages_fixed_point verifies Stage 1 == Stage 2 reproducibility: two
// consecutive compiler outputs built from the same source tree must have the
// exact same 32-byte BLAKE3 hash.
chibicc_stages_fixed_point :: proc(stage1_bytes, stage2_bytes: []u8) -> bool {
	if len(stage1_bytes) == 0 || len(stage1_bytes) != len(stage2_bytes) {
		return false
	}
	return blake3.hash(stage1_bytes) == blake3.hash(stage2_bytes)
}
