package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modustool:build"
import "modustool:foundation"

// Live QEMU bootstrap verification (src/md/features/bootstrap.md):
//   1. Runs host `c_self_host` to compute the exact Stage 1 == Stage 2 BLAKE3
//      hash and size of chibicc, and packs the 14 C sources, headers, and
//      `self_host/jump.s` into the private store `bootstrap_probe`.
//   2. Builds the freestanding `sqlite` (3.54.1), `lua` (5.4.7), and `zstd`
//      (1.5.7) modules from pinned flake sources (`SQLITE_SOURCE`,
//      `LUA_SOURCE`, `ZSTD_SOURCE`), computes each module's BLAKE3 hash and
//      the host zstd reference frame BLAKE3 hash, and packs them into the same
//      private store on `TEST_DISK_BOOTSTRAP`.
//   3. Boots `plan_and_audit` under QEMU, starts `bootstrap_probe`, and
//      asserts that modus executes `chibicc` Stage 0 -> Stage 1 -> Stage 2
//      live through `c_compiler.compile_unit`, `assemble.assemble_program`,
//      and `system.module_space_load` to the exact host BLAKE3 hash, then
//      loads and validates `sqlite`, `lua`, and `zstd` live on modus matching
//      every host module hash and compressed frame hash.

TEST_OUTPUT_BOOTSTRAP :: foundation.BUILD_FOLDER + "/test_output_bootstrap.txt"
TEST_DISK_BOOTSTRAP :: foundation.BUILD_FOLDER + "/test_disk_bootstrap.img"
BOOTSTRAP_WORK_FOLDER :: foundation.BUILD_FOLDER + "/bootstrap_test_work"
BOOTSTRAP_PROBE_WRONG :: "bootstrap_probe: WRONG"

// Plan value: matches store_blocks for `bootstrap_probe` in start_grant_sets.odin.
BOOTSTRAP_STORE_BLOCKS :: 4096

// Expected Lua stdout length ("15|42|57|17\n") in bootstrap_probe/main.odin.
BOOTSTRAP_LUA_EXPECTED_OUTPUT_BYTES :: 12

@(private = "file")
bootstrap_hex :: proc(hash: blake3.Hash, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for value in hash {
		fmt.sbprintf(&b, "%02x", value)
	}
	return strings.to_string(b)
}

@(private = "file")
bootstrap_owned :: proc(owned: ^[dynamic]string, format: string, args: ..any) -> string {
	text := fmt.aprintf(format, ..args)
	append(owned, text)
	return text
}

bootstrap_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	source_folder, folder_ok := build.c_source_folder(foundation.CHIBICC, "bootstrap")
	if !folder_ok {
		return false
	}
	program, program_ok := build.c_self_host_program(source_folder)
	if !program_ok {
		return false
	}

	foundation.reset_folder(BOOTSTRAP_WORK_FOLDER) or_return
	c_host_work := foundation.join(BOOTSTRAP_WORK_FOLDER, "/c_self_host")
	report, host_ok := build.c_self_host(c_host_work)
	if !host_ok || !report.fixed_point || !report.texts_equal {
		fmt.eprintln("modustool: bootstrap: host c-self-host did not reach a fixed point")
		return false
	}

	packed, packed_ok := build.c_self_host_program_pack(program, context.temp_allocator)
	if !packed_ok {
		fmt.eprintln("modustool: bootstrap: cannot pack chibicc program sources")
		return false
	}

	sqlite_mod, sqlite_ok := build.c_world_build_recipe_module(.Sqlite, BOOTSTRAP_WORK_FOLDER)
	if !sqlite_ok {
		return false
	}
	defer delete(sqlite_mod)
	lua_mod, lua_ok := build.c_world_build_recipe_module(.Lua, BOOTSTRAP_WORK_FOLDER)
	if !lua_ok {
		return false
	}
	defer delete(lua_mod)
	zstd_mod, zstd_ok := build.c_world_build_recipe_module(.Zstd, BOOTSTRAP_WORK_FOLDER)
	if !zstd_ok {
		return false
	}
	defer delete(zstd_mod)

	zstd_comp_bytes, zstd_frame_hash, zstd_ref_ok := build.c_world_zstd_reference_frame(zstd_mod)
	if !zstd_ref_ok {
		fmt.eprintln("modustool: bootstrap: cannot compute host zstd reference frame hash")
		return false
	}

	objects := make([dynamic]build.Module_File, context.temp_allocator)
	append(&objects, ..packed)
	append(&objects, build.Module_File{name = "sqlite.module", bytes = sqlite_mod})
	append(&objects, build.Module_File{name = "lua.module", bytes = lua_mod})
	append(&objects, build.Module_File{name = "zstd.module", bytes = zstd_mod})

	image, disk_ok := build.data_disk_encode({name = "bootstrap_probe", limit = BOOTSTRAP_STORE_BLOCKS, objects = objects[:]}, build.DATA_DISK_SIZE)
	if !disk_ok {
		return false
	}
	defer delete(image)
	if write_err := os.write_entire_file(TEST_DISK_BOOTSTRAP, image); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DISK_BOOTSTRAP, write_err)
		return false
	}

	chibicc_hex := bootstrap_hex(report.stage_one_hash)
	defer delete(chibicc_hex)
	sqlite_hex := bootstrap_hex(blake3.hash(sqlite_mod))
	defer delete(sqlite_hex)
	lua_hex := bootstrap_hex(blake3.hash(lua_mod))
	defer delete(lua_hex)
	zstd_hex := bootstrap_hex(blake3.hash(zstd_mod))
	defer delete(zstd_hex)
	zstd_frame_hex := bootstrap_hex(zstd_frame_hash)
	defer delete(zstd_frame_hex)

	fmt.printfln(
		"modustool: %s: packed %d objects (chibicc %d B %s, sqlite %d B, lua %d B, zstd %d B, frame %d B %s)",
		TEST_DISK_BOOTSTRAP,
		len(objects),
		report.stage_one_size,
		chibicc_hex,
		len(sqlite_mod),
		len(lua_mod),
		len(zstd_mod),
		zstd_comp_bytes,
		zstd_frame_hex,
	)

	owned: [dynamic]string
	defer {
		for text in owned {
			delete(text)
		}
		delete(owned)
	}
	steps := make([dynamic]Step)
	defer delete(steps)
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "storage: ok, generation 2: 1 stores, %d objects", len(objects)), any_order = true})
	append(&steps, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "start(\"bootstrap_probe\")"})
	append(&steps, Step{kind = .Wait, text = "bootstrap_probe: refusals checked", fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "bootstrap_probe: chibicc stage 1 assembled: %d bytes, hash %s", report.stage_one_size, chibicc_hex), fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "bootstrap_probe: chibicc stage 2 assembled: %d bytes, hash %s", report.stage_two_size, chibicc_hex), fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "bootstrap_probe: chibicc self-host fixed point verified across %d units: %d bytes, hash %s", len(report.sources), report.stage_one_size, chibicc_hex), fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "bootstrap_probe: sqlite 3054001 verified (sum=42, rows=2), module hash %s", sqlite_hex), fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "bootstrap_probe: lua 5.4.7 verified (%d bytes, zero leaked heap), module hash %s", BOOTSTRAP_LUA_EXPECTED_OUTPUT_BYTES, lua_hex), fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = bootstrap_owned(&owned, "bootstrap_probe: zstd 10507 verified (%d compressed bytes, frame hash %s), module hash %s", zstd_comp_bytes, zstd_frame_hex, zstd_hex), fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = "bootstrap_probe: ok, live chibicc self-host and C libraries verified", fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Wait, text = "root: bootstrap_probe stopped: itself, done", fails_on = BOOTSTRAP_PROBE_WRONG})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})

	return machine_test(part, steps[:], {
		volume      = build.BOOT_VOLUME_PLAN_AND_AUDIT,
		output      = TEST_OUTPUT_BOOTSTRAP,
		exit_status = build.MACHINE_STOP_OK,
		data_disk   = TEST_DISK_BOOTSTRAP,
	})
}

@(init)
bootstrap_test_part_register :: proc "contextless" () {
	test_part_scenario_register("bootstrap", bootstrap_tests_run)
}
