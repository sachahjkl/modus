package checks

import "core:testing"

// Odin source check catches rdrand/rdseed inside asm templates and intrinsics
// while ignoring normal identifiers, comments, and string literals.
@(test)
processor_random_odin_source_detection :: proc(t: ^testing.T) {
	bad_asm := `package sample

bad_rand :: asm() -> (value: u64, ok: bool) [
	ok = %flags.c,
	#volatile,
] {
	rdrand value
}

bad_seed :: asm() -> (value: u64, ok: bool) [
	ok = %flags.c,
	#volatile,
] {
	RDSEED value
}
`
	uses, ok := processor_random_uses_of_odin_source("src/modules/tests/bad/main.odin", bad_asm)
	testing.expect(t, ok)
	testing.expect_value(t, len(uses), 2)
	if len(uses) == 2 {
		testing.expect_value(t, uses[0].what, "rdrand")
		testing.expect_value(t, uses[0].line, 7)
		testing.expect_value(t, uses[1].what, "rdseed")
		testing.expect_value(t, uses[1].line, 14)
	}

	// Intrinsic calls (default name and aliased import) are caught too.
	bad_intrinsic := `package sample
import intr "base:intrinsics"
f :: proc() {
	_ = intr.x86_rdrand64_step()
	_ = intr.x86_rdseed64_step()
}
`
	uses, ok = processor_random_uses_of_odin_source("src/modules/tests/bad/intr.odin", bad_intrinsic)
	testing.expect(t, ok)
	testing.expect_value(t, len(uses), 2)

	// Identifiers, comments, and string literals mentioning rdrand/rdseed are NOT false positives.
	clean := `package sample
// rdrand and rdseed are discussed here.
Report :: struct {
	rdrand_present: bool,
	rdseed_present: bool,
}
name :: proc() -> string {
	return "rdrand rdseed"
}
`
	uses, ok = processor_random_uses_of_odin_source("src/modules/tests/clean/main.odin", clean)
	testing.expect(t, ok)
	testing.expect_value(t, len(uses), 0)
}

// Assembly file check catches rdrand and rdseed mnemonics and ignores comments.
@(test)
processor_random_assembly_detection :: proc(t: ^testing.T) {
	asm_source := `section .text
; rdrand rax is only in a comment here
foo:
	mov rax, rdi
	rdrand rax
	RDSEED rbx
	ret
`
	uses := processor_random_uses_of_assembly("src/runtime/bad.asm", asm_source)
	testing.expect_value(t, len(uses), 2)
	if len(uses) == 2 {
		testing.expect_value(t, uses[0].line, 5)
		testing.expect_value(t, uses[0].what, "rdrand")
		testing.expect_value(t, uses[1].line, 6)
		testing.expect_value(t, uses[1].what, "rdseed")
	}
}

// LLVM IR check catches @llvm.x86.rdrand/rdseed intrinsics and inline asm.
@(test)
processor_random_llvm_ir_detection :: proc(t: ^testing.T) {
	ir := `define void @f() {
  ; comment mentioning @llvm.x86.rdrand.64
  %1 = call { i64, i32 } @llvm.x86.rdrand.64()
  %2 = call { i64, i32 } @llvm.x86.rdseed.64()
  %3 = call i64 asm sideeffect "rdrand $0", "=r"()
  %4 = call i64 asm sideeffect "rdseed $0", "=r"()
  ret void
}
`
	uses := processor_random_uses_of_llvm_ir("build/modules/sample/sample.ll", ir)
	testing.expect_value(t, len(uses), 4)
	if len(uses) == 4 {
		testing.expect_value(t, uses[0].line, 3)
		testing.expect_value(t, uses[1].line, 4)
		testing.expect_value(t, uses[2].line, 5)
		testing.expect_value(t, uses[3].line, 6)
	}
}

// Only src/library/modus/random/entropy.odin and the test-only planted
// divergence probe src/modules/tests/replay_rdrand_probe/main.odin are exempt,
// and the real repository tree passes with zero breaches.
@(test)
processor_random_rule_holds_in_repository :: proc(t: ^testing.T) {
	testing.expect(t, processor_random_path_allowed("src/library/modus/random/entropy.odin"))
	testing.expect(t, processor_random_path_allowed("src/modules/tests/replay_rdrand_probe/main.odin"))
	testing.expect(t, !processor_random_path_allowed("src/library/modus/random/generator.odin"))
	testing.expect(t, !processor_random_path_allowed("src/modules/tests/replay_probe/main.odin"))
	testing.expect(t, !processor_random_path_allowed("src/modules/tests/replay_rdrand_probe/facts.odin"))

	uses, file_count, ok := processor_random_uses_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, file_count > 100)
	for use in uses {
		testing.expectf(t, false, "%s:%d: %s", use.file, use.line, use.what)
	}
}
