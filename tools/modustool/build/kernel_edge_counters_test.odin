package build

import "core:slice"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The IR of a counted kernel after the pass, in a short form: the comdat of
// the constructor of the pass, two arrays of guards, a global of another
// section, a list of constructors, the list of the used globals that keeps
// the constructor, the constructor, and code of the kernel
// before and after it.
@(private = "file")
INSTRUMENTED_IR :: `$sancov.module_ctor_trace_pc_guard = comdat any
@__sancov_gen_ = private global [3 x i32] zeroinitializer, section "__sancov_guards", comdat($kernel.enter), align 4, !associated !1
@__sancov_gen_.1 = private global [12 x i32] zeroinitializer, section "__sancov_guards", align 4, !associated !2
@kernel.table = internal global [8 x i32] zeroinitializer, section ".data.table", align 4
@llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 2, ptr @sancov.module_ctor_trace_pc_guard, ptr @sancov.module_ctor_trace_pc_guard }]
@llvm.used = appending global [1 x ptr] [ptr @sancov.module_ctor_trace_pc_guard], section "llvm.metadata"
define void @kernel.enter() {
  call void @__sanitizer_cov_trace_pc_guard(ptr @__sancov_gen_)
  ret void
}
define internal void @sancov.module_ctor_trace_pc_guard() #3 comdat {
  call void @__sanitizer_cov_trace_pc_guard_init(ptr @__start___sancov_guards, ptr @__stop___sancov_guards)
  ret void
}
define void @kernel.after() {
  ret void
}
declare void @__sanitizer_cov_trace_pc_guard_init(ptr, ptr)
`

// The IR above with no list of the constructors, no constructor of the
// pass and no comdat of it: each other line stays, in its order.
@(private = "file")
INSTRUMENTED_IR_WITHOUT_CONSTRUCTOR :: `@__sancov_gen_ = private global [3 x i32] zeroinitializer, section "__sancov_guards", comdat($kernel.enter), align 4, !associated !1
@__sancov_gen_.1 = private global [12 x i32] zeroinitializer, section "__sancov_guards", align 4, !associated !2
@kernel.table = internal global [8 x i32] zeroinitializer, section ".data.table", align 4
define void @kernel.enter() {
  call void @__sanitizer_cov_trace_pc_guard(ptr @__sancov_gen_)
  ret void
}
define void @kernel.after() {
  ret void
}
declare void @__sanitizer_cov_trace_pc_guard_init(ptr, ptr)
`

// The tool counts the guards of each array of the section of the guards,
// and only of it; an array of that section with no length that it reads is
// refused, so the count is never short.
@(test)
the_guards_of_the_ir_are_counted :: proc(t: ^testing.T) {
	count, counted := kernel_ir_guard_count(INSTRUMENTED_IR)
	testing.expect(t, counted)
	testing.expect_value(t, count, 3 + 12)
	none, none_counted := kernel_ir_guard_count("define void @a() {\n  ret void\n}\n")
	testing.expect(t, none_counted && none == 0, "an IR with no guard has no count")
	refused := []string {
		`@g = private global i32 0, section "__sancov_guards"`,
		`@g = private global [0 x i32] zeroinitializer, section "__sancov_guards"`,
		`@g = private global [-3 x i32] zeroinitializer, section "__sancov_guards"`,
		`@g = private global [3 x i64] zeroinitializer, section "__sancov_guards"`,
		`@g = private global [x i32] zeroinitializer, section "__sancov_guards"`,
		`@g = private global [99999999999999999999 x i32] zeroinitializer, section "__sancov_guards"`,
		// The array of guards only in the initialiser: the type is no array.
		`@g = private global { [3 x i32] } zeroinitializer, section "__sancov_guards"`,
		// Another array type, then an array of i32 in the initialiser.
		`@g = private global [3 x i64] [i64 0, i64 0, i64 0], section "__sancov_guards", !note [2 x i32]`,
	}
	for line in refused {
		with_line := strings.concatenate({INSTRUMENTED_IR, line, "\n"}, context.temp_allocator)
		refused_count, refused_counted := kernel_ir_guard_count(with_line)
		testing.expectf(t, !refused_counted && refused_count == 0, "the line %q of the section of the guards is taken", line)
	}
	// A `[` in the name, before the type: the type after `global` counts.
	named := strings.concatenate({INSTRUMENTED_IR, `@"guards[1]" = private global [7 x i32] zeroinitializer, section "__sancov_guards"`, "\n"}, context.temp_allocator)
	named_count, named_counted := kernel_ir_guard_count(named)
	testing.expect(t, named_counted)
	testing.expect_value(t, named_count, 3 + 12 + 7)
}

// The list of the constructors, the constructor of the pass and its comdat
// leave the IR, and no other line does: the code before and after the
// constructor stays whole, no code calls the init, and no procedure is left
// that no entry of the kernel reaches.
@(test)
the_constructor_of_the_pass_leaves_the_ir :: proc(t: ^testing.T) {
	without, lists, constructors := kernel_ir_constructors_removed(INSTRUMENTED_IR)
	testing.expect_value(t, lists, 1)
	testing.expect_value(t, constructors, 1)
	testing.expect_value(t, without, INSTRUMENTED_IR_WITHOUT_CONSTRUCTOR)
	testing.expect(t, !strings.contains(without, KERNEL_IR_PASS_CONSTRUCTOR), "a reference to the constructor stays")
	testing.expect(t, !strings.contains(without, "call void @__sanitizer_cov_trace_pc_guard_init"), "a call of the init stays")
	// A second pass of the removal finds nothing: the tool refuses that
	// form, as a pass of opt of another form.
	again, lists_again, constructors_again := kernel_ir_constructors_removed(without)
	testing.expect(t, lists_again == 0 && constructors_again == 0, "the removal found a list or a constructor twice")
	testing.expect_value(t, again, without)
	count, _ := kernel_ir_guard_count(without)
	testing.expect_value(t, count, 3 + 12)
	// A `}` line that ends with a carriage return ends the constructor too.
	with_carriage_returns, _ := strings.replace_all(INSTRUMENTED_IR, "\n", "\r\n", context.temp_allocator)
	without_carriage_returns, _, crlf_constructors := kernel_ir_constructors_removed(with_carriage_returns)
	testing.expect_value(t, crlf_constructors, 1)
	testing.expect(t, strings.contains(without_carriage_returns, "define void @kernel.after()"), "the code after the constructor left with it")
	// A list of the used globals that holds another global too stays whole,
	// so its reference to the constructor stays, and the build stops on it.
	shared_used :: `@llvm.used = appending global [2 x ptr] [ptr @sancov.module_ctor_trace_pc_guard, ptr @kernel.table], section "llvm.metadata"`
	with_shared := strings.concatenate({INSTRUMENTED_IR, shared_used, "\n"}, context.temp_allocator)
	without_shared, _, _ := kernel_ir_constructors_removed(with_shared)
	testing.expect(t, strings.contains(without_shared, shared_used), "a list of the used globals with another global left the IR")
}

// Only the counted kernel gets the pass and the file of the callback, and
// each other kernel says that it has no counter.
@(test)
only_the_counted_kernel_gets_the_edge_counters :: proc(t: ^testing.T) {
	counted := 0
	for row in foundation.module_builds {
		pass := module_edge_counter_command(row)
		compile := module_compile_command(row)
		false_setting := "-define:" + foundation.KERNEL_EDGE_COUNTERS_SETTING + "=false"
		if foundation.module_counts_kernel_edges(row) {
			counted += 1
			testing.expect_value(t, row.name, foundation.KERNEL_EDGE_COUNTERS_MODULE)
			testing.expect(t, pass != nil && slice.contains(pass, "-sanitizer-coverage-trace-pc-guard"), "the counted kernel has no pass")
			testing.expect(t, !slice.contains(compile, false_setting), "the counted kernel has the setting false")
			continue
		}
		testing.expectf(t, pass == nil, "the module %s has the pass of the counters", row.name)
		testing.expectf(t, slice.contains(compile, false_setting) == row.kernel, "the module %s: the setting false of the counters goes with a kernel", row.name)
		if row.kernel {
			files, listed := module_assembly_files(row)
			testing.expect(t, listed)
			testing.expectf(t, !slice.contains(files, KERNEL_EDGE_COUNTERS_ASSEMBLY), "the kernel %s links the file of the counters", row.name)
		}
	}
	testing.expect_value(t, counted, 1)
}
