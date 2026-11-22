package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// chibicc built by clang compiles each source of chibicc; the module that
// the assembler of modus makes of the texts compiles the same sources to
// the same texts, and its own texts give a module of the same hash. Before
// the chain, the test gives stage 0 what it must refuse. The development
// shell and the check of the flake set the variable of the source, and
// give clang, nasm and ld.lld.
@(test)
chibicc_builds_itself_to_the_same_bytes :: proc(t: ^testing.T) {
	folder := os.get_env(foundation.CHIBICC.variable, context.temp_allocator)
	if !testing.expectf(t, folder != "", "%s is set: run the tests in the development shell or in the check of the flake", foundation.CHIBICC.variable) {
		return
	}
	temp_base, _ := os.temp_dir(context.temp_allocator)
	work := fmt.tprintf("%s/modus_c_self_host_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(work)
	if !testing.expect(t, os.make_directory_all(work) == nil, "the test makes its folder") {
		return
	}
	defer os.remove_all(work)
	program, program_ok := c_self_host_program(folder)
	if !testing.expect(t, program_ok, "the folder of chibicc holds its program") {
		return
	}
	stage_zero, stage_zero_ok := c_self_host_stage_zero(work)
	if !testing.expect(t, stage_zero_ok, "clang, nasm, ld.lld and the conversion build stage 0") {
		return
	}
	defer delete(stage_zero)

	// A source with an error of syntax: the diagnostic names its file.
	_, diagnostic, compiled := c_stage_compile(stage_zero, program, {name = "chibicc/broken.c", bytes = transmute([]u8)string("int f( {")})
	testing.expect(t, !compiled, "stage 0 refuses a source with an error of syntax")
	testing.expectf(t, strings.contains(diagnostic, "chibicc/broken.c:1:"), "the diagnostic names the file and its line: %q", diagnostic)
	// An export of the program that does not give an Integer.
	pointer_program := program
	pointer_program.export_names = {"compile_record_at"}
	_, diagnostic, compiled = c_stage_compile(stage_zero, pointer_program, {name = "chibicc/pointer.c", bytes = transmute([]u8)string("char *compile_record_at(void) { return 0; }")})
	testing.expect(t, !compiled, "stage 0 refuses an export that gives a pointer")
	testing.expectf(t, strings.contains(diagnostic, "is an export"), "the diagnostic says why: %q", diagnostic)
	// A source that includes a file that the table does not hold.
	_, diagnostic, compiled = c_stage_compile(stage_zero, program, {name = "chibicc/missing.c", bytes = transmute([]u8)string("#include \"missing.h\"\n")})
	testing.expect(t, !compiled, "stage 0 refuses an include that the table does not hold")
	// A static function of one unit is not seen by another: the assembler
	// refuses the program whole.
	caller, _, caller_ok := c_stage_compile(stage_zero, program, {name = "chibicc/caller.c", bytes = transmute([]u8)string("int helper(void);\nlong compile_record_at(long record) { return helper(); }\n")})
	callee, _, callee_ok := c_stage_compile(stage_zero, program, {name = "chibicc/callee.c", bytes = transmute([]u8)string("static int helper(void) { return 1; }\nint use(void) { return helper(); }\n")})
	if testing.expect(t, caller_ok && callee_ok, "stage 0 compiles the two units") {
		defer delete(caller)
		defer delete(callee)
		empty_program := program
		empty_program.assembly = nil
		file, linked := c_program_assemble({caller, callee}, empty_program)
		testing.expect(t, !linked, "the assembler refuses a call of a static function of another unit")
		delete(file)
	}

	report, ok := c_self_host_chain(program, stage_zero, work)
	if !testing.expect(t, ok, "each step of the chain runs") {
		return
	}
	testing.expect_value(t, len(report.sources), 14)
	testing.expect_value(t, len(report.assembly), 1)
	testing.expectf(t, report.texts_equal, "stage 1 gives the text of stage 0 for each source; %s differs at the byte %d", report.first_text_difference, report.text_difference_offset)
	testing.expect_value(t, report.first_module_difference, -1)
	testing.expect(t, report.fixed_point, "blake3(stage 1) == blake3(stage 2)")
	testing.expect_value(t, report.stage_one_size, report.stage_two_size)

	// Stage 1 ends a refused compile through the jump of jump.s, which no
	// module of clang runs: the diagnostic comes back, and the next compile
	// of a fresh copy works.
	stage_one, read_error := os.read_entire_file(fmt.tprintf("%s/stage_one/chibicc.modus", work), context.allocator)
	if !testing.expect(t, read_error == nil, "the chain wrote the module of stage 1") {
		return
	}
	defer delete(stage_one)
	_, diagnostic, compiled = c_stage_compile(stage_one, program, {name = "chibicc/broken.c", bytes = transmute([]u8)string("int f( {")})
	testing.expect(t, !compiled, "stage 1 refuses a source with an error of syntax")
	testing.expectf(t, strings.contains(diagnostic, "chibicc/broken.c:1:"), "the diagnostic of stage 1 names the file and its line: %q", diagnostic)
	text, _, fresh_ok := c_stage_compile(stage_one, program, {name = "chibicc/one.c", bytes = transmute([]u8)string("long compile_record_at(long record) { return record + 1; }\n")})
	testing.expect(t, fresh_ok, "a fresh copy of stage 1 compiles after a refusal")
	testing.expect(t, strings.has_prefix(string(text), "unit\n"), "the text of a unit starts with unit")
	delete(text)
}
