package checks

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The check of the two bounds of the tests (docs/TOOLS.md, "The bounds of
// the tests"). TEST_HANG_BOUND_MILLISECONDS ends a hang in a check, and
// nothing else. A service or a library that waits for another part of the
// machine names a deadline of its contract, which comes from
// system.ANSWER_BOUND_MILLISECONDS: a service that read the bound of the
// tests would change its behaviour when the tests change their bound. So a
// bound of the tests is named only in a host test, in a test module, in a
// demonstration (each one is a case of a machine test), and in the file
// that defines it.

SERVICE_DEADLINE_REFUSED_NAMES :: [?]string{"TEST_HANG_BOUND_MILLISECONDS", "TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS"}
SERVICE_DEADLINE_DEFINITION_FILE :: foundation.SOURCE_FOLDER_PUBLIC + "/system/test_bounds.odin"
SERVICE_DEADLINE_ALLOWED_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_MODULES + "/tests/", foundation.SOURCE_FOLDER_MODULES + "/demonstrations/"}

// One place of a source that names a bound of the tests.
Service_Deadline_Use :: struct {
	file: string,
	line: int,
	name: string,
}

@(private = "file")
Service_Deadline_Walk :: struct {
	file: string,
	uses: ^[dynamic]Service_Deadline_Use,
}

@(private = "file")
service_deadline_bound_name :: proc(name: string) -> (string, bool) {
	names := SERVICE_DEADLINE_REFUSED_NAMES
	for bound in names {
		if name == bound {
			return bound, true
		}
	}
	return "", false
}

@(private = "file")
service_deadline_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Service_Deadline_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Selector_Expr:
		// system.TEST_HANG_BOUND_MILLISECONDS: the walk does not go on into
		// the field, so the name counts once.
		if item.field != nil {
			if bound, found := service_deadline_bound_name(item.field.name); found {
				append(walk.uses, Service_Deadline_Use{file = walk.file, line = item.pos.line, name = bound})
				return nil
			}
		}
	case ^ast.Ident:
		// The name inside the package system itself.
		if bound, found := service_deadline_bound_name(item.name); found {
			append(walk.uses, Service_Deadline_Use{file = walk.file, line = item.pos.line, name = bound})
		}
	}
	return visitor
}

// service_deadline_uses_of_source gives each place of one Odin source that names a
// bound of the tests. A comment and a text name no bound.
service_deadline_uses_of_source :: proc(file, source: string) -> (uses: []Service_Deadline_Use, ok: bool) {
	list := make([dynamic]Service_Deadline_Use, context.temp_allocator)
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
		walk := Service_Deadline_Walk{file = file, uses = &list}
		visitor := ast.Visitor{visit = service_deadline_visit, data = &walk}
		for decl in tree.decls {
			ast.walk(&visitor, decl)
		}
	}
	return list[:], true
}

// service_deadline_path_allowed says if a path of the repository may name a bound
// of the tests: a host test, a test module, a demonstration, and the file
// that defines the bounds.
service_deadline_path_allowed :: proc(relative_path: string) -> bool {
	if relative_path == SERVICE_DEADLINE_DEFINITION_FILE || strings.has_suffix(relative_path, "_test.odin") {
		return true
	}
	folders := SERVICE_DEADLINE_ALLOWED_FOLDERS
	for folder in folders {
		if strings.has_prefix(relative_path, folder) {
			return true
		}
	}
	return false
}

// service_deadline_check refuses each source of src/ but the allowed ones that
// names a bound of the tests.
service_deadline_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	if !foundation.source_files_of_a_folder("src", &files) {
		fmt.eprintln("modustool: cannot list the sources of src")
		return false
	}
	slice.sort(files[:])
	uses := make([dynamic]Service_Deadline_Use, context.temp_allocator)
	for file in files {
		if service_deadline_path_allowed(file) {
			continue
		}
		source, read_ok := foundation.read_text_file_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return false
		}
		if !strings.contains(source, "TEST_") {
			continue
		}
		found, parsed := service_deadline_uses_of_source(file, source)
		if !parsed {
			fmt.eprintfln("modustool: cannot parse %s for the check of the bounds of the tests", file)
			return false
		}
		append(&uses, ..found)
	}
	for use in uses {
		fmt.eprintfln("modustool: %s:%d: names %s, a bound of the tests: a service waits for its peer with a deadline of its contract (system.ANSWER_BOUND_MILLISECONDS)", use.file, use.line, use.name)
	}
	if len(uses) > 0 {
		fmt.eprintfln("modustool: test failed: %d places of the services and the libraries name a bound of the tests", len(uses))
		return false
	}
	foundation.test_passed_print("none of the %d sources of the services and the libraries names a bound of the tests", len(files))
	return true
}
