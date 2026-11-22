#+build !freestanding
// The host test of the C programs: it compiles the thin libc, the adapters of
// SQLite, Lua and zstd and their test programs with the C flags of a module,
// links them into one relocatable object, converts it into a module with the
// converter of the tool, proves that the module imports nothing and holds no
// instruction that reaches the host, then loads a copy of the module for each
// test and calls its exports (src/md/features/c_compiler.md, "The C programs").
package c_programs

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "modus:contract/blake3"
import module "modus:contract/module"
import build "../../../tools/modustool/build"

C_PROGRAMS_FOLDER :: #directory
MANIFEST_TEXT :: #load("c_programs.manifest", string)

C_SOURCES := [?]string {
	"thin_libc/modus_thin_libc.c",
	"thin_libc/modus_thin_libc_memory.c",
	"sqlite/modus_vfs.c",
	"lua/modus_lua_output.c",
	"programs/codec.c",
	"programs/script.c",
	"programs/kv_store.c",
	"programs/entry.c",
}

// The flags of a C file of a module (src/md/infrastructure/outside_source.md,
// "The compile of a C file"). The headers are the headers of the thin libc
// only: the wrapper of clang in Nix adds the folder of glibc with -isystem,
// which comes before the headers of the compiler itself, so the thin libc has
// its own stddef.h and stdint.h too, and the dependency check below proves
// that the compiler read no other header.
C_FLAGS := [?]string {
	"--target=x86_64-unknown-none-elf",
	"-std=gnu11",
	"-O2",
	"-ffreestanding",
	"-nostdinc",
	"-fPIC",
	"-fvisibility=hidden",
	"-fno-omit-frame-pointer",
	"-mno-omit-leaf-frame-pointer",
	"-mlong-double-64",
	"-fno-stack-protector",
	"-fcf-protection=none",
	"-fzero-call-used-regs=skip",
	"-U_FORTIFY_SOURCE",
	"-fno-asynchronous-unwind-tables",
	"-fno-unwind-tables",
	"-fno-common",
	"-Wall",
	"-Wextra",
	"-Werror",
	"-Wno-unused-parameter",
	"-Wno-unused-command-line-argument",
}

C_INCLUDE_FOLDERS := [?]string{"thin_libc/include", "thin_libc", "sqlite", "lua", "zstd", "programs"}

// Instructions that reach the host or the privileged machine. A module of C
// runs none of them: it reaches the machine through its exports only.
// int3 is allowed only as the padding that the linker puts before the start
// of a function, which no jump reaches.
HOST_INSTRUCTIONS := [?]string{"syscall", "sysenter", "sysexit", "sysret", "int", "into", "in", "out", "ins", "outs", "hlt", "cli", "sti", "cpuid", "rdtsc", "rdtscp", "rdrand", "rdseed", "rdpid", "lgdt", "lidt", "wrmsr", "rdmsr", "invlpg", "swapgs", "iretq"}

Built_Module :: struct {
	file:                   []u8,
	digest:                 blake3.Hash,
	problem:                string, // "" when each step passed.
	undefined_symbols:      string,
	host_instruction_lines: [dynamic]string,
	headers_outside:        [dynamic]string,
	instruction_count:      int,
}

@(private = "file")
built_once: sync.Once
@(private = "file")
built_shared: Built_Module

@(private = "file")
build_folder_count: int

folder_of_programs :: proc() -> string {
	return strings.trim_right(C_PROGRAMS_FOLDER, "/")
}

// run_tool gives the standard output of a tool when it succeeds, and both of
// its outputs when it fails.
@(private = "file")
run_tool :: proc(command: []string, working_dir: string) -> (ok: bool, output: string) {
	state, stdout, stderr, error := os.process_exec({command = command, working_dir = working_dir}, context.allocator)
	if error != nil {
		return false, fmt.aprintf("cannot start %s: %v", command[0], error)
	}
	if state.success {
		return true, string(stdout)
	}
	return false, strings.concatenate({string(stdout), string(stderr)})
}

@(private = "file")
compile_command :: proc(source: string, extra: ..string) -> [dynamic]string {
	command := make([dynamic]string)
	append(&command, "clang")
	for flag in C_FLAGS {
		append(&command, flag)
	}
	for folder in C_INCLUDE_FOLDERS {
		append(&command, "-I", strings.concatenate({folder_of_programs(), "/", folder}))
	}
	for flag in extra {
		append(&command, flag)
	}
	append(&command, strings.concatenate({folder_of_programs(), "/", source}))
	return command
}

// build_module compiles, links, checks and converts the C of the folder. It
// gives the problem of the first step that failed.
build_module :: proc(result_allocator := context.allocator) -> Built_Module {
	// Each step works in the temporary memory; the file of the module and the
	// texts of the result go to the allocator of the caller.
	built := build_module_in_temporary_memory()
	return Built_Module {
		file = slice.clone(built.file, result_allocator),
		digest = built.digest,
		problem = strings.clone(built.problem, result_allocator),
		undefined_symbols = strings.clone(built.undefined_symbols, result_allocator),
		host_instruction_lines = clone_texts(built.host_instruction_lines, result_allocator),
		headers_outside = clone_texts(built.headers_outside, result_allocator),
		instruction_count = built.instruction_count,
	}
}

@(private = "file")
build_module_in_temporary_memory :: proc() -> (built: Built_Module) {
	context.allocator = context.temp_allocator
	temp_base, _ := os.temp_dir(context.allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	build_folder_count += 1
	work := fmt.aprintf("%s/modus_c_programs_%d_%d", strings.trim_right(temp_base, "/"), os.get_pid(), build_folder_count)
	_ = os.remove_all(work)
	if os.make_directory_all(work) != nil {
		built.problem = fmt.aprintf("cannot make %s", work)
		return
	}
	defer _ = os.remove_all(work)

	ok: bool
	output: string
	objects := make([dynamic]string)
	for source, index in C_SOURCES {
		object := fmt.aprintf("%s/object_%d.o", work, index)
		command := compile_command(source, "-c", "-o", object)
		ok, output = run_tool(command[:], work)
		if !ok {
			built.problem = fmt.aprintf("clang refused %s:\n%s", source, output)
			return
		}
		append(&objects, object)

		// The headers that the compiler read: the folder of the programs and
		// the headers of the compiler only, never a header of a C library of
		// the host.
		dependency_command := compile_command(source, "-M", "-MT", "object")
		ok, output = run_tool(dependency_command[:], work)
		if !ok {
			built.problem = fmt.aprintf("clang -M refused %s:\n%s", source, output)
			return
		}
		joined, _ := strings.replace_all(output, "\\\n", " ")
		for path, path_index in strings.fields(joined) {
			if path_index == 0 || path == "" {
				continue
			}
			inside := strings.has_prefix(path, folder_of_programs())
			if !inside {
				append(&built.headers_outside, strings.clone(path))
			}
		}
	}

	combined := fmt.aprintf("%s/c_programs.o", work)
	link_command := make([dynamic]string)
	append(&link_command, "ld.lld", "-r", "-o", combined)
	for object in objects {
		append(&link_command, object)
	}
	ok, output = run_tool(link_command[:], work)
	if !ok {
		built.problem = fmt.aprintf("ld.lld -r failed:\n%s", output)
		return
	}

	ok, output = run_tool({"llvm-nm", "-u", combined}, work)
	if !ok {
		built.problem = fmt.aprintf("llvm-nm failed:\n%s", output)
		return
	}
	built.undefined_symbols = strings.trim_space(output)

	ok, output = run_tool({"llvm-objdump", "-d", "--no-show-raw-insn", combined}, work)
	if !ok {
		built.problem = fmt.aprintf("llvm-objdump failed:\n%s", output)
		return
	}
	padding := make([dynamic]string)
	for line in strings.split_lines(output) {
		// An instruction line is "<address>: <tab><mnemonic><tab><operands>";
		// a line of a symbol is "<address> <name>:"; an empty line ends a
		// function.
		parts := strings.split(line, "\t")
		if len(parts) < 2 || !strings.has_suffix(strings.trim_space(parts[0]), ":") {
			clear(&padding)
			continue
		}
		mnemonic := strings.trim_space(parts[1])
		if space := strings.index_byte(mnemonic, ' '); space >= 0 {
			mnemonic = mnemonic[:space]
		}
		if mnemonic == "" {
			continue
		}
		built.instruction_count += 1
		if mnemonic == "int3" {
			append(&padding, line)
			continue
		}
		// An int3 that an instruction follows in the same function is no padding.
		for padding_line in padding {
			append(&built.host_instruction_lines, strings.clone(padding_line))
		}
		clear(&padding)
		for host in HOST_INSTRUCTIONS {
			if mnemonic == host || mnemonic == strings.concatenate({host, "b"}) || mnemonic == strings.concatenate({host, "l"}) || mnemonic == strings.concatenate({host, "w"}) {
				append(&built.host_instruction_lines, strings.clone(line))
			}
		}
	}

	elf, read_error := os.read_entire_file(combined, context.allocator)
	if read_error != nil {
		built.problem = fmt.aprintf("cannot read %s", combined)
		return
	}
	manifest, manifest_problem := build.manifest_parse(MANIFEST_TEXT)
	if manifest_problem != "" {
		built.problem = fmt.aprintf("the manifest is refused: %s", manifest_problem)
		return
	}
	file, converted := build.convert_elf_with_manifest(elf, manifest, nil)
	if !converted {
		built.problem = "convert_elf_with_manifest refused the object"
		return
	}
	built.file = file
	built.digest = blake3.hash(file)
	return
}

@(private = "file")
clone_texts :: proc(texts: [dynamic]string, allocator: runtime.Allocator) -> [dynamic]string {
	copies := make([dynamic]string, allocator)
	for text in texts {
		append(&copies, strings.clone(text, allocator))
	}
	return copies
}

// The module that each test loads is built once for the whole run, in memory
// that the run keeps.
shared_module :: proc() -> ^Built_Module {
	sync.once_do(&built_once, proc() {
		built_shared = build_module(runtime.heap_allocator())
	})
	return &built_shared
}

delete_built_module :: proc(built: Built_Module) {
	delete(built.file)
	delete(built.problem)
	delete(built.undefined_symbols)
	for text in built.host_instruction_lines {
		delete(text)
	}
	delete(built.host_instruction_lines)
	for text in built.headers_outside {
		delete(text)
	}
	delete(built.headers_outside)
}

Loaded_Module :: struct {
	file:   []u8,
	memory: []u8,
}

// load_module maps a copy of the module for one test: each test has its own
// data, so tests that run at once share no state of the C part.
load_module :: proc(t: ^testing.T) -> (loaded: Loaded_Module, ok: bool) {
	built := shared_module()
	if !testing.expectf(t, built.problem == "", "the build of the C programs failed: %s", built.problem) {
		return
	}
	file := built.file
	if !testing.expect_value(t, module.validate(file), module.Error.None) {
		return
	}
	head, _ := module.header(file)
	memory, error := virtual.reserve_and_commit(uint(head.memory_size))
	if !testing.expect(t, error == .None, "the host gave no memory for the module") {
		return
	}
	module.copy_segments(file, memory)
	if !testing.expect_value(t, module.rebase(file, memory, uintptr(raw_data(memory))), module.Error.None) {
		virtual.release(raw_data(memory), len(memory))
		return
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Execute in segment.flags {
			testing.expect(t, virtual.protect(raw_data(memory[segment.memory_offset:]), uint(segment.memory_size), {.Read, .Execute}))
		}
	}
	return Loaded_Module{file, memory}, true
}

unload_module :: proc(loaded: Loaded_Module) {
	virtual.release(raw_data(loaded.memory), len(loaded.memory))
}

call :: proc(loaded: Loaded_Module, name: string, arguments: ..i64) -> i64 {
	index := module.export_find(loaded.file, name)
	fmt.assertf(index != 0, "the module has no export %s", name)
	address, found := module.export_address(loaded.file, uintptr(raw_data(loaded.memory)), index)
	fmt.assertf(found, "the export %s has no address", name)
	code := rawptr(address)
	switch len(arguments) {
	case 0:
		return (proc "c" () -> i64)(code)()
	case 1:
		return (proc "c" (_: i64) -> i64)(code)(arguments[0])
	case 2:
		return (proc "c" (_, _: i64) -> i64)(code)(arguments[0], arguments[1])
	case 3:
		return (proc "c" (_, _, _: i64) -> i64)(code)(arguments[0], arguments[1], arguments[2])
	case 4:
		return (proc "c" (_, _, _, _: i64) -> i64)(code)(arguments[0], arguments[1], arguments[2], arguments[3])
	case 5:
		return (proc "c" (_, _, _, _, _: i64) -> i64)(code)(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])
	case 6:
		return (proc "c" (_, _, _, _, _, _: i64) -> i64)(code)(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5])
	}
	panic("an export of the module takes at most 6 integers")
}

address_of :: proc(pointer: rawptr) -> i64 {
	return i64(uintptr(pointer))
}

text_address :: proc(text: string) -> i64 {
	return address_of(rawptr(strings.clone_to_cstring(text, context.temp_allocator)))
}

// A generator of the test, with a fixed seed: each run tries the same inputs.
Generator :: struct {
	state: u64,
}

next_word :: proc(generator: ^Generator) -> u64 {
	generator.state ~= generator.state << 13
	generator.state ~= generator.state >> 7
	generator.state ~= generator.state << 17
	return generator.state
}

next_below :: proc(generator: ^Generator, bound: u64) -> u64 {
	return next_word(generator) % bound
}

// ---- The build ------------------------------------------------------------------------

@(test)
c_programs_build_freestanding_with_no_import_and_no_host_instruction :: proc(t: ^testing.T) {
	built := shared_module()
	if !testing.expectf(t, built.problem == "", "the build failed: %s", built.problem) {
		return
	}
	testing.expectf(t, built.undefined_symbols == "", "the object needs symbols that no file defines:\n%s", built.undefined_symbols)
	testing.expectf(t, len(built.host_instruction_lines) == 0, "the object holds instructions that reach the host: %v", built.host_instruction_lines)
	testing.expectf(t, len(built.headers_outside) == 0, "the compiler read headers outside the C programs: %v", built.headers_outside)
	testing.expect(t, built.instruction_count > 1000, "the disassembly must list the instructions of the object")
	testing.expect_value(t, module.validate(built.file), module.Error.None)
	// Record 0 of a table is the empty record: a count of 1 is no import.
	testing.expect_value(t, module.count(built.file, .Imports), u32(1))
	testing.expect(t, module.count(built.file, .Import_Slots) <= 1, "the module has no import slot")
	// Index 0 of the export table is reserved.
	testing.expect_value(t, int(module.count(built.file, .Exports)), strings.count(MANIFEST_TEXT, "\nexport ") + 1)
	testing.expect(t, module.count(built.file, .Rebases) > 0, "the tables of function pointers of the VFS need rebases")
	fmt.printfln("c_programs: module of %d bytes, %d instructions, %d exports, %d rebase words", len(built.file), built.instruction_count, module.count(built.file, .Exports) - 1, module.count(built.file, .Rebases))
}

@(test)
c_programs_build_is_deterministic :: proc(t: ^testing.T) {
	shared := shared_module()
	if !testing.expectf(t, shared.problem == "", "the build failed: %s", shared.problem) {
		return
	}
	again := build_module()
	defer delete_built_module(again)
	testing.expectf(t, again.problem == "", "the second build failed: %s", again.problem)
	testing.expect(t, again.digest == shared.digest, "two builds of one source must give the same bytes")
}

@(test)
c_programs_manifest_names_each_export_once :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	// A name that the manifest does not hold finds no export.
	testing.expect_value(t, module.export_find(loaded.file, "malloc"), u32(0))
	testing.expect_value(t, module.export_find(loaded.file, "setjmp"), u32(0))
	testing.expect(t, module.export_find(loaded.file, "call_kv_open") != 0)
}
