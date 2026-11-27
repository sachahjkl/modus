package checks

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The check against hardware random instructions (rdrand and rdseed) in the
// code of the system (src/md/features/record_and_replay.md).
//
// Outside a hypervisor, rdrand and rdseed cannot be trapped when a process is
// recorded. The shipped code of the system executes them only inside
// random.entropy_gather in src/library/modus/random/entropy.odin (for the seed
// of the root service). One test-only divergence probe
// (src/modules/tests/replay_rdrand_probe/main.odin, excluded from every release
// boot image) is also allowed so live machine tests verify that executing
// rdrand during a recorded run triggers an exact replay divergence. Every
// other Odin source, assembly file, and LLVM IR unit of src/ is refused.

PROCESSOR_RANDOM_ALLOWED_FILE :: foundation.SOURCE_FOLDER_PUBLIC + "/random/entropy.odin"
PROCESSOR_RANDOM_ALLOWED_PROBE_FILE :: foundation.TEST_MODULE_SOURCES + "replay_rdrand_probe/main.odin"

PROCESSOR_RANDOM_CHECKED_FOLDERS :: [?]string {
	foundation.SOURCE_FOLDER_KERNEL,
	foundation.SOURCE_FOLDER_BOOT,
	foundation.SOURCE_FOLDER_RUNTIME,
	foundation.SOURCE_FOLDER_MODULES,
	foundation.SOURCE_FOLDER_LIBRARY,
}

// One forbidden occurrence of rdrand or rdseed.
Processor_Random_Use :: struct {
	file: string,
	line: int,
	what: string, // Instruction or intrinsic name found.
}

@(private = "file")
Processor_Random_Walk :: struct {
	file:            string,
	source:          string,
	intrinsics_name: string,
	uses:            ^[dynamic]Processor_Random_Use,
}

@(private = "file")
is_random_mnemonic :: proc(word: string) -> bool {
	return strings.equal_fold(word, "rdrand") || strings.equal_fold(word, "rdseed")
}

// find_random_mnemonic_in_lines searches comment-stripped lines for a word
// token matching rdrand or rdseed. `comment_prefix` is "//" for Odin asm
// templates and ";" for NASM assembly files.
@(private = "file")
find_random_mnemonic_in_lines :: proc(file: string, text: string, start_line: int, comment_prefix: string, uses: ^[dynamic]Processor_Random_Use) {
	rest := text
	line_number := start_line
	for line in strings.split_lines_iterator(&rest) {
		code := line
		if comment := strings.index(code, comment_prefix); comment >= 0 {
			code = code[:comment]
		}
		// Scan identifier tokens inside the line.
		i := 0
		for i < len(code) {
			if !is_name_byte(code[i]) && code[i] != '_' {
				i += 1
				continue
			}
			start := i
			for i < len(code) && (is_name_byte(code[i]) || code[i] == '_') {
				i += 1
			}
			word := code[start:i]
			if is_random_mnemonic(word) {
				append(uses, Processor_Random_Use {
					file = file,
					line = line_number,
					what = strings.to_lower(word, context.temp_allocator),
				})
			}
		}
		line_number += 1
	}
}

@(private = "file")
processor_random_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Processor_Random_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Asm_Template:
		start := item.pos.offset
		end := item.end.offset
		if start >= 0 && end >= start && end <= len(walk.source) {
			template_text := walk.source[start:end]
			find_random_mnemonic_in_lines(walk.file, template_text, item.pos.line, "//", walk.uses)
		}
	case ^ast.Selector_Expr:
		if walk.intrinsics_name == "" || item.field == nil {
			break
		}
		if base, is_ident := item.expr.derived.(^ast.Ident); is_ident && base.name == walk.intrinsics_name {
			lower := strings.to_lower(item.field.name, context.temp_allocator)
			if strings.contains(lower, "rdrand") || strings.contains(lower, "rdseed") {
				append(walk.uses, Processor_Random_Use {
					file = walk.file,
					line = item.pos.line,
					what = fmt.tprintf("%s.%s", base.name, item.field.name),
				})
			}
		}
	}
	return visitor
}

// processor_random_uses_of_odin_source parses one Odin source file and returns
// every asm template or intrinsic call that uses rdrand or rdseed.
processor_random_uses_of_odin_source :: proc(file, source: string) -> (uses: []Processor_Random_Use, ok: bool) {
	list := make([dynamic]Processor_Random_Use, context.temp_allocator)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, false
	}
	defer virtual.arena_destroy(&arena)
	{
		context.allocator = virtual.arena_allocator(&arena)
		tree := ast.new_from_positions(ast.File, {}, {})
		tree.src = source
		tree.fullpath = file
		reader := parser.default_parser()
		reader.err = foundation.tokenizer_quiet_error
		reader.warn = foundation.tokenizer_quiet_error
		if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
			return nil, false
		}
		walk := Processor_Random_Walk {
			file   = file,
			source = source,
			uses   = &list,
		}
		for decl in tree.imports {
			if strings.trim(decl.fullpath, "\"`") == "base:intrinsics" {
				walk.intrinsics_name = decl.name.text != "" ? strings.clone(decl.name.text, context.temp_allocator) : "intrinsics"
			}
		}
		visitor := ast.Visitor {
			visit = processor_random_visit,
			data  = &walk,
		}
		for decl in tree.decls {
			ast.walk(&visitor, decl)
		}
	}
	return list[:], true
}

// processor_random_uses_of_assembly finds rdrand or rdseed instructions in a
// NASM assembly file, ignoring ";" comments.
processor_random_uses_of_assembly :: proc(file, source: string) -> []Processor_Random_Use {
	list := make([dynamic]Processor_Random_Use, context.temp_allocator)
	find_random_mnemonic_in_lines(file, source, 1, ";", &list)
	return list[:]
}

// processor_random_uses_of_llvm_ir finds LLVM x86 rdrand/rdseed intrinsics and
// inline assembly uses of rdrand/rdseed in an LLVM IR module.
processor_random_uses_of_llvm_ir :: proc(file, ir: string) -> []Processor_Random_Use {
	list := make([dynamic]Processor_Random_Use, context.temp_allocator)
	rest := ir
	line_number := 0
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		code := line
		if comment := strings.index(code, ";"); comment >= 0 {
			code = code[:comment]
		}
		if strings.contains(code, "@llvm.x86.rdrand") {
			append(&list, Processor_Random_Use{file = file, line = line_number, what = "@llvm.x86.rdrand"})
			continue
		}
		if strings.contains(code, "@llvm.x86.rdseed") {
			append(&list, Processor_Random_Use{file = file, line = line_number, what = "@llvm.x86.rdseed"})
			continue
		}
		if strings.contains(code, "asm ") {
			lower := strings.to_lower(code, context.temp_allocator)
			if strings.contains(lower, "rdrand") {
				append(&list, Processor_Random_Use{file = file, line = line_number, what = "inline asm rdrand"})
			} else if strings.contains(lower, "rdseed") {
				append(&list, Processor_Random_Use{file = file, line = line_number, what = "inline asm rdseed"})
			}
		}
	}
	return list[:]
}

// assembly_files_of_a_folder recursively collects all .asm files under folder.
@(private = "file")
assembly_files_of_a_folder :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		return false
	}
	for entry in entries {
		path := foundation.join(folder, "/", entry.name)
		if entry.type == .Directory {
			assembly_files_of_a_folder(path, files) or_return
		} else if strings.has_suffix(entry.name, ".asm") {
			append(files, path)
		}
	}
	return true
}

// processor_random_path_allowed says if a repository-relative path is allowed
// to execute rdrand and rdseed: random.entropy_gather for shipped code, or the
// test-only planted divergence probe excluded from release boot images.
processor_random_path_allowed :: proc(relative_path: string) -> bool {
	return relative_path == PROCESSOR_RANDOM_ALLOWED_FILE || relative_path == PROCESSOR_RANDOM_ALLOWED_PROBE_FILE
}

// processor_random_uses_of_tree scans every non-test Odin source and every
// assembly source under src/ (from root; "" for current repository).
processor_random_uses_of_tree :: proc(root: string) -> (uses: []Processor_Random_Use, file_count: int, ok: bool) {
	odin_files := make([dynamic]string, context.temp_allocator)
	asm_files := make([dynamic]string, context.temp_allocator)
	folders := PROCESSOR_RANDOM_CHECKED_FOLDERS
	for folder in folders {
		target := root == "" ? folder : foundation.join(root, "/", folder)
		if !os.is_dir(target) {
			continue
		}
		foundation.source_files_of_a_folder(target, &odin_files) or_return
		assembly_files_of_a_folder(target, &asm_files) or_return
	}
	slice.sort(odin_files[:])
	slice.sort(asm_files[:])

	prefix := root == "" ? "" : foundation.join(root, "/")
	relative_of :: proc(path, prefix: string) -> string {
		if prefix != "" && strings.has_prefix(path, prefix) {
			return path[len(prefix):]
		}
		return path
	}

	list := make([dynamic]Processor_Random_Use, context.temp_allocator)
	for file in odin_files {
		if source_is_a_test(file) {
			continue
		}
		rel := relative_of(file, prefix)
		if processor_random_path_allowed(rel) {
			continue
		}
		source, read_ok := foundation.read_text_file_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, false
		}
		file_count += 1
		found, parsed := processor_random_uses_of_odin_source(rel, source)
		if !parsed {
			fmt.eprintfln("modustool: cannot parse %s for rdrand/rdseed check", rel)
			return nil, 0, false
		}
		append(&list, ..found)
	}
	for file in asm_files {
		rel := relative_of(file, prefix)
		source, read_ok := foundation.read_text_file_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, false
		}
		file_count += 1
		append(&list, ..processor_random_uses_of_assembly(rel, source))
	}
	return list[:], file_count, true
}

// processor_random_check refuses rdrand and rdseed anywhere in src/ outside
// random.entropy_gather (src/library/modus/random/entropy.odin).
processor_random_check :: proc() -> bool {
	uses, file_count, ok := processor_random_uses_of_tree("")
	if !ok {
		return false
	}
	for use in uses {
		fmt.eprintfln("modustool: %s:%d: %s: rdrand and rdseed are allowed only in %s (random.entropy_gather)", use.file, use.line, use.what, PROCESSOR_RANDOM_ALLOWED_FILE)
	}
	if len(uses) > 0 {
		fmt.eprintfln("modustool: test failed: %d places outside %s use rdrand or rdseed", len(uses), PROCESSOR_RANDOM_ALLOWED_FILE)
		return false
	}
	foundation.test_passed_print("none of the %d non-test source and assembly files outside %s uses rdrand or rdseed", file_count, PROCESSOR_RANDOM_ALLOWED_FILE)
	return true
}
