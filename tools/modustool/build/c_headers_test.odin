package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

@(private = "file")
c_headers_test_temp_dir :: proc(t: ^testing.T, label: string) -> string {
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.tprintf("%s/modus_c_headers_test_%s_%d", strings.trim_right(temp_base, "/"), label, os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "must create test temporary directory")
	return dir
}

// Empty and root output paths must be refused cleanly without modifying disk.
@(test)
c_headers_refuses_bad_output_paths :: proc(t: ^testing.T) {
	for bad in ([]string{"", "   ", "/"}) {
		problem := c_headers_generate(bad)
		testing.expectf(t, problem != "", "bad output path %q must be refused", bad)
	}
}

// Generates all five C11 headers twice to prove byte determinism, verifies
// every required header and static assertion exists, and compiles both
// standalone header checks and a combined C11 verification program with
// clang -std=c11 -Wall -Wextra -Werror -fsyntax-only to prove every
// _Static_assert(sizeof(...)) and _Static_assert(offsetof(...)) passes.
@(test)
c_headers_generate_and_compile_cleanly :: proc(t: ^testing.T) {
	root := c_headers_test_temp_dir(t, "compile")
	defer _ = os.remove_all(root)

	dir_a := foundation.join(root, "/headers_a")
	dir_b := foundation.join(root, "/headers_b")
	testing.expect_value(t, c_headers_generate(dir_a), "")
	testing.expect_value(t, c_headers_generate(dir_b), "")

	for name in C_HEADER_FILE_NAMES {
		path_a := foundation.join(dir_a, "/", name)
		path_b := foundation.join(dir_b, "/", name)
		bytes_a, err_a := os.read_entire_file(path_a, context.temp_allocator)
		bytes_b, err_b := os.read_entire_file(path_b, context.temp_allocator)
		testing.expectf(t, err_a == nil && len(bytes_a) > 0, "header %s must exist and be non-empty", name)
		testing.expectf(t, err_b == nil && len(bytes_b) > 0, "second header %s must exist and be non-empty", name)
		testing.expectf(t, string(bytes_a) == string(bytes_b), "header %s must be byte-for-byte deterministic", name)
		testing.expectf(t, strings.contains(string(bytes_a), "_Static_assert(sizeof("), "header %s must contain sizeof static assertions", name)
		testing.expectf(t, strings.contains(string(bytes_a), "_Static_assert(offsetof("), "header %s must contain offsetof static assertions", name)
	}

	// Check if clang is available in PATH.
	probe_state, _, _, probe_err := os.process_exec({command = {"clang", "--version"}}, context.temp_allocator)
	if probe_err != nil || !probe_state.exited || !probe_state.success {
		return
	}

	// Verify each generated header compiles cleanly standalone as C11 with
	// strict warnings treated as errors.
	for name in C_HEADER_FILE_NAMES {
		check_c := foundation.join(root, "/standalone_", name, ".c")
		src := fmt.tprintf("#include \"%s\"\nint modus_standalone_check(void) {{ return 0; }}\n", name)
		testing.expect(t, os.write_entire_file(check_c, src) == nil)
		// -Wno-unused-command-line-argument ignores linker flags injected by Nix cc-wrapper during -fsyntax-only.
		cmd := [?]string{"clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-command-line-argument", "-fsyntax-only", "-I", dir_a, check_c}
		state, _, stderr_bytes, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
		testing.expectf(t, err == nil && state.exited && state.success, "standalone C11 check failed for %s: %s", name, string(stderr_bytes))
	}

	// Verify a realistic C11 consumer using all five headers together passes
	// every sizeof/offsetof _Static_assert and zero-warning strict compilation.
	verify_c := foundation.join(root, "/verify_all.c")
	verify_src := `#include "modus_types.h"
#include "modus_operation.h"
#include "modus_errors.h"
#include "modus_ring.h"
#include "modus_module.h"

int modus_c11_contract_verify(void) {
	Modus_Ring_Record cmd = {0};
	cmd.kind = MODUS_OPERATION_MEMORY_CREATE;
	cmd.tag = 1U;
	cmd.values[0] = (uint64_t)MODUS_CONTEXT_LOG;

	Modus_Error_Record err = {0};
	err.kind = MODUS_ERROR_KIND_BAD_VALUE;
	err.unit = MODUS_ERROR_UNIT_FRAMES;
	err.operation = (int64_t)MODUS_OPERATION_LOG;

	Modus_Module_Header hdr = {0};
	hdr.magic = MODUS_MODULE_MAGIC;
	hdr.version = MODUS_MODULE_VERSION;
	hdr.machine = MODUS_MODULE_MACHINE_X86_64;
	hdr.table_count = MODUS_MODULE_TABLE_COUNT;

	Modus_Rights rights = MODUS_RIGHT_BIT(MODUS_RIGHT_READ) | MODUS_RIGHT_BIT(MODUS_RIGHT_WRITE);
	Modus_Context ctx = {0};
	ctx.handles[MODUS_CONTEXT_LOG] = 1U;

	return (cmd.kind == MODUS_OPERATION_MEMORY_CREATE &&
	        err.kind == MODUS_ERROR_KIND_BAD_VALUE &&
	        hdr.version == MODUS_MODULE_VERSION &&
	        rights != 0U &&
	        ctx.handles[MODUS_CONTEXT_LOG] == 1U) ? 0 : 1;
}
`
	testing.expect(t, os.write_entire_file(verify_c, verify_src) == nil)
	verify_cmd := [?]string{"clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-command-line-argument", "-fsyntax-only", "-I", dir_a, verify_c}
	v_state, _, v_stderr, v_err := os.process_exec({command = verify_cmd[:]}, context.temp_allocator)
	testing.expectf(t, v_err == nil && v_state.exited && v_state.success, "combined C11 verification failed: %s", string(v_stderr))
}
