package checks

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The check of the field image_checks of system.Load_Source
// (docs/TRUSTED_BOOT.md, "Layer 1: the signed system description"). The
// field gives a loader the table of the entries of the boot image whose
// hash a party already checked, and the loader then hashes those entries no
// more. Only the root service holds such a table, for the image that it
// checked at its start: a process that gave one could load a file of an
// image that nothing checked. So the field is named only in the loader that
// reads it and in the one place of the root service that gives it, and in
// the host tests of the loader.

IMAGE_CHECKS_FIELD :: "image_checks"
IMAGE_CHECKS_ALLOWED_FILES :: [?]string{foundation.SOURCE_FOLDER_PUBLIC + "/system/load.odin", foundation.SOURCE_FOLDER_MODULES + "/system/root/main.odin"}
IMAGE_CHECKS_TEST_FOLDER :: foundation.SOURCE_FOLDER_PUBLIC + "/system/"

// One place of a source that names the field.
Image_Checks_Use :: struct {
	file: string,
	line: int,
}

@(private = "file")
Image_Checks_Walk :: struct {
	file: string,
	uses: ^[dynamic]Image_Checks_Use,
}

@(private = "file")
image_checks_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Image_Checks_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Selector_Expr:
		// The read of the field: source.image_checks.
		if item.field != nil && item.field.name == IMAGE_CHECKS_FIELD {
			append(walk.uses, Image_Checks_Use{file = walk.file, line = item.pos.line})
		}
	case ^ast.Field_Value:
		// The field in a literal: {image_checks = ...}.
		if name, is_name := item.field.derived.(^ast.Ident); is_name && name.name == IMAGE_CHECKS_FIELD {
			append(walk.uses, Image_Checks_Use{file = walk.file, line = item.pos.line})
		}
	}
	return visitor
}

// image_checks_uses_of_source gives each place of one Odin source that
// reads the field or writes it in a literal. A variable of the same name is
// no use: only a selector and a field of a literal name a field.
image_checks_uses_of_source :: proc(file, source: string) -> (uses: []Image_Checks_Use, ok: bool) {
	list := make([dynamic]Image_Checks_Use, context.temp_allocator)
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
		walk := Image_Checks_Walk{file = file, uses = &list}
		visitor := ast.Visitor{visit = image_checks_visit, data = &walk}
		for decl in tree.decls {
			ast.walk(&visitor, decl)
		}
	}
	return list[:], true
}

// image_checks_path_allowed says if a path of the repository may name the
// field: the loader, the root service, and the host tests of the loader.
image_checks_path_allowed :: proc(relative_path: string) -> bool {
	allowed := IMAGE_CHECKS_ALLOWED_FILES
	for path in allowed {
		if relative_path == path {
			return true
		}
	}
	return strings.has_prefix(relative_path, IMAGE_CHECKS_TEST_FOLDER) && strings.has_suffix(relative_path, "_test.odin") && !strings.contains(relative_path[len(IMAGE_CHECKS_TEST_FOLDER):], "/")
}

// image_checks_field_check refuses each source of src/ and tools/ but the
// allowed ones that names the field image_checks.
image_checks_field_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	for folder in ([]string{"src", foundation.TOOL_SOURCE_FOLDER}) {
		if !foundation.source_files_of_a_folder(folder, &files) {
			fmt.eprintfln("modustool: cannot list the sources of %s", folder)
			return false
		}
	}
	slice.sort(files[:])
	uses := make([dynamic]Image_Checks_Use, context.temp_allocator)
	for file in files {
		if image_checks_path_allowed(file) {
			continue
		}
		source, read_ok := foundation.read_text_file_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return false
		}
		if !strings.contains(source, IMAGE_CHECKS_FIELD) {
			continue
		}
		found, parsed := image_checks_uses_of_source(file, source)
		if !parsed {
			fmt.eprintfln("modustool: cannot parse %s for the check of the field %s", file, IMAGE_CHECKS_FIELD)
			return false
		}
		append(&uses, ..found)
	}
	for use in uses {
		fmt.eprintfln("modustool: %s:%d: names the field %s of system.Load_Source, which only the root service gives (%s)", use.file, use.line, IMAGE_CHECKS_FIELD, IMAGE_CHECKS_ALLOWED_FILES[1])
	}
	if len(uses) > 0 {
		fmt.eprintfln("modustool: test failed: %d places name the field %s outside the loader and the root service", len(uses), IMAGE_CHECKS_FIELD)
		return false
	}
	foundation.test_passed_print("none of the %d sources outside the loader and the root service names the field %s", len(files), IMAGE_CHECKS_FIELD)
	return true
}
