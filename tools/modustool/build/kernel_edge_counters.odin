package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The build of the counted kernel (src/md/infrastructure/kernel_fuzzing.md,
// "The test kernel"): between the compile and llc, opt adds a call of the
// callback of src/kernel/edge_counters.asm at each edge of the IR of the
// kernel; the tool then removes the list of the constructors that the pass
// adds, counts the guards, and gives the count to nasm for that one file.
// No other kernel links the file.

// The assembly file of the callback, the init and the counters.
KERNEL_EDGE_COUNTERS_ASSEMBLY :: foundation.SOURCE_FOLDER_KERNEL + "/edge_counters.asm"

// The section of the guards, which the pass names.
KERNEL_EDGE_GUARD_SECTION :: "section \"__sancov_guards\""

// The start of the line of the list of the constructors of the IR.
KERNEL_IR_CONSTRUCTORS_LINE_START :: "@llvm.global_ctors "

// The options of the pass: each block and each critical edge, and a call
// with the address of a guard at each.
@(rodata)
kernel_edge_counter_pass_options := [?]string {
	"-passes=sancov-module",
	"-sanitizer-coverage-level=3",
	"-sanitizer-coverage-trace-pc-guard",
}

// module_edge_counter_command gives the command of opt for a counted
// kernel, which writes the instrumented IR in place of the IR; nil for each
// other module. The build key of the module holds it.
module_edge_counter_command :: proc(build: foundation.Module_Build) -> []string {
	if !foundation.module_counts_kernel_edges(build) {
		return nil
	}
	ir := foundation.join(foundation.module_build_folder, "/", build.name, "/", build.name, ".ll")
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "opt")
	append(&command, ..kernel_edge_counter_pass_options[:])
	append(&command, "-S", "-o", ir, ir)
	return command[:]
}

// kernel_ir_constructors_removed gives the IR with no line of the list of
// the constructors, and the count of the lines that it removed. The kernel
// runs no constructor, and the conversion refuses a module with one.
kernel_ir_constructors_removed :: proc(ir: string, allocator := context.temp_allocator) -> (without: string, removed: int) {
	builder := strings.builder_make(allocator)
	rest := ir
	for line in strings.split_lines_after_iterator(&rest) {
		if strings.has_prefix(line, KERNEL_IR_CONSTRUCTORS_LINE_START) {
			removed += 1
			continue
		}
		strings.write_string(&builder, line)
	}
	return strings.to_string(builder), removed
}

// The words before the type of a global of the IR.
@(rodata)
kernel_ir_global_words := [?]string{" global ", " constant "}

// The end of the type of an array of guards, after its length.
KERNEL_IR_GUARD_ARRAY_END :: " x i32]"

// kernel_ir_guard_count gives the count of the guards of an instrumented
// IR: the sum of the lengths of the arrays of i32 of the section of the
// guards. The type of a global is the text right after `global` or
// `constant`: a `[` in its name or in its initialiser is not its type. ok
// is false for a line of that section whose type is no array of i32 with a
// length: the count would be short, and an edge past it would count
// nothing.
kernel_ir_guard_count :: proc(ir: string) -> (count: int, ok: bool) {
	rest := ir
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "@") || !strings.contains(line, KERNEL_EDGE_GUARD_SECTION) {
			continue
		}
		type_start := -1
		for word in kernel_ir_global_words {
			if at := strings.index(line, word); at >= 0 && (type_start < 0 || at + len(word) < type_start) {
				type_start = at + len(word)
			}
		}
		if type_start < 0 || !strings.has_prefix(line[type_start:], "[") {
			return 0, false
		}
		type_end := strings.index(line[type_start:], KERNEL_IR_GUARD_ARRAY_END)
		// The array type is the first bracket: a length of digits, then the end.
		if type_end <= 1 || strings.index_byte(line[type_start:], ']') != type_end + len(KERNEL_IR_GUARD_ARRAY_END) - 1 {
			return 0, false
		}
		length, parsed := strconv.parse_int(line[type_start + 1:type_start + type_end], 10)
		if !parsed || length <= 0 {
			return 0, false
		}
		count += length
	}
	return count, true
}

// KERNEL_EDGE_GUARD_SECTION_NAME is the name of the section of the guards
// in the linked kernel; KERNEL_EDGE_GUARD_BYTES the size of one guard.
KERNEL_EDGE_GUARD_SECTION_NAME :: "__sancov_guards"
KERNEL_EDGE_GUARD_BYTES :: 4

// kernel_linked_guard_count gives the count of the guards that the link of
// a counted kernel kept: at most the count of its IR, which sizes its
// counters. No call of the callback names a guard past it, so the counters
// past it stay 0 in each run.
kernel_linked_guard_count :: proc(module_name: string) -> (count: int, ok: bool) {
	elf := foundation.read_file(module_linked_file(module_name)) or_return
	header, sections, read := elf_sections(elf)
	if !read {
		return 0, false
	}
	guards, found := elf_section_named(elf, header, sections, KERNEL_EDGE_GUARD_SECTION_NAME)
	if !found || len(guards) % KERNEL_EDGE_GUARD_BYTES != 0 {
		return 0, false
	}
	return len(guards) / KERNEL_EDGE_GUARD_BYTES, true
}

// kernel_edge_counters_instrument runs the pass on the IR of a counted
// kernel, removes the list of the constructors, and gives the count of the
// guards for nasm.
kernel_edge_counters_instrument :: proc(build: foundation.Module_Build) -> (guard_count: int, ok: bool) {
	foundation.run(module_edge_counter_command(build)) or_return
	path := foundation.join(foundation.module_build_folder, "/", build.name, "/", build.name, ".ll")
	ir := foundation.read_file(path) or_return
	without, removed := kernel_ir_constructors_removed(string(ir))
	if removed == 0 {
		fmt.eprintfln("modustool: the IR of %s after the pass has no list of constructors: the pass of opt did not run as the tool expects", build.name)
		return 0, false
	}
	count, counted := kernel_ir_guard_count(without)
	if !counted || count == 0 {
		fmt.eprintfln("modustool: the IR of %s after the pass has no guard that the tool can count", build.name)
		return 0, false
	}
	if err := os.write_entire_file(path, without); err != nil {
		fmt.eprintfln("modustool: cannot write the LLVM IR of %s: %v", build.name, err)
		return 0, false
	}
	fmt.printfln("modustool: measure: the counted kernel %s has %d edges", build.name, count)
	return count, true
}
