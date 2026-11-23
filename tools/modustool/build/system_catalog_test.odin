#+build !freestanding
package build

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/declaration_eval"
import "modus:contract/release"
import "modus:lex_evaluator"
import "modustool:foundation"

// Host tests of the system catalog declaration generator
// (src/md/features/application_projects.md, "The catalog of the system").
// Refusals and edge inputs come first, followed by full-scale boot image
// determinism, lex_evaluator parsing and evaluation, and release filtering.

@(private = "file")
CATALOG_TEST_STACK :: 2 * 1024 * 1024

@(private = "file")
synthetic_module_bytes :: proc(name: string) -> []u8 {
	text := fmt.tprintf("synthetic-module:%s", name)
	return transmute([]u8)text
}

// synthetic_boot_image_files builds one synthetic Image_File for every
// module of foundation.module_builds that belongs in build/boot.image, plus
// one trailing resource entry so tests prove resources are not emitted as
// modules.
@(private = "file")
synthetic_boot_image_files :: proc() -> (files: []Image_File, module_count: int) {
	list := make([dynamic]Image_File, context.temp_allocator)
	for row in foundation.module_builds {
		if !foundation.module_in_boot_image(row) {
			continue
		}
		append(&list, Image_File{name = row.name, file = synthetic_module_bytes(row.name)})
	}
	module_count = len(list)
	resource_text: string = "start-list-bytes"
	append(&list, Image_File{name = "start_list", file = transmute([]u8)resource_text})
	return list[:], module_count
}

// Refusals first: damaged boot images, mismatched hashes, out-of-bounds
// entries, bad release strings, invalid or duplicate module names, missing
// c_compiler or assemble, and any test or unknown module in a release
// catalog declaration.
@(test)
system_catalog_refuses_damaged_or_invalid_inputs :: proc(t: ^testing.T) {
	// Not a boot image: empty, cut header, zero modules.
	_, problem := system_catalog_of_image(nil, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "empty bytes must be refused")
	empty_image := boot_image_encode(nil, 0)
	_, problem = system_catalog_of_image(empty_image[:8], release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "a cut header must be refused")
	_, problem = system_catalog_of_image(empty_image, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "an image with zero modules must be refused")

	// Minimal valid pair of modules for mutation tests.
	base_files := []Image_File {
		{name = CATALOG_C_COMPILER_MODULE, file = synthetic_module_bytes(CATALOG_C_COMPILER_MODULE)},
		{name = CATALOG_ASSEMBLER_MODULE, file = synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE)},
	}
	base_image := boot_image_encode(base_files, len(base_files))

	// Entry whose stated BLAKE3 hash does not match its bytes (1 bit flipped).
	corrupted_bytes := slice.clone(base_image, context.temp_allocator)
	corrupted_bytes[len(corrupted_bytes) - 1] ~= 1
	_, problem = system_catalog_of_image(corrupted_bytes, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "a module whose bytes disagree with its hash must be refused")

	// Entry whose offset points past the end of the image.
	oob_image := slice.clone(base_image, context.temp_allocator)
	first_entry := (^info.Image_Entry)(&oob_image[size_of(info.Image_Header)])
	first_entry.offset = u64(len(oob_image)) + info.PAGE_SIZE
	_, problem = system_catalog_of_image(oob_image, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "an entry pointing outside the image must be refused")

	// Invalid release numbers: empty, quote, backslash, newline, control byte.
	bad_releases := [?]string{"", "0.97\"0", "0.97\\0", "0.97\n0", "0.97\x01"}
	for bad in bad_releases {
		_, problem = system_catalog_of_image(base_image, bad, .Boot_Image)
		testing.expectf(t, problem != "", "release number %q must be refused", bad)
	}

	// Invalid module names (non-identifiers and Lex keywords).
	bad_names := [?]string{"", "1bad", "bad-name", "bad.name", "let", "in", "with", "if", "then", "else", "true", "false", "_"}
	for bad_name in bad_names {
		entries := []Module_Hash {
			{name = CATALOG_C_COMPILER_MODULE, hash = blake3.hash(synthetic_module_bytes(CATALOG_C_COMPILER_MODULE))},
			{name = CATALOG_ASSEMBLER_MODULE, hash = blake3.hash(synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE))},
			{name = bad_name, hash = blake3.hash(synthetic_module_bytes("other"))},
		}
		_, problem = system_catalog_of_modules(entries, release.RELEASE_NUMBER, .Boot_Image)
		testing.expectf(t, problem != "", "module name %q must be refused", bad_name)
	}

	// Duplicate module name.
	duplicate_entries := []Module_Hash {
		{name = CATALOG_C_COMPILER_MODULE, hash = blake3.hash(synthetic_module_bytes(CATALOG_C_COMPILER_MODULE))},
		{name = CATALOG_C_COMPILER_MODULE, hash = blake3.hash(synthetic_module_bytes(CATALOG_C_COMPILER_MODULE))},
		{name = CATALOG_ASSEMBLER_MODULE, hash = blake3.hash(synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE))},
	}
	_, problem = system_catalog_of_modules(duplicate_entries, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "duplicate module names must be refused")

	// Missing c_compiler, then missing assemble.
	only_assemble := []Image_File{{name = CATALOG_ASSEMBLER_MODULE, file = synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE)}}
	_, problem = system_catalog_of_image(boot_image_encode(only_assemble, 1), release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "an image without c_compiler must be refused")

	only_compiler := []Image_File{{name = CATALOG_C_COMPILER_MODULE, file = synthetic_module_bytes(CATALOG_C_COMPILER_MODULE)}}
	_, problem = system_catalog_of_image(boot_image_encode(only_compiler, 1), release.RELEASE_NUMBER, .Boot_Image)
	testing.expect(t, problem != "", "an image without assemble must be refused")

	// Release scope refuses test modules, single-image test modules, and
	// unknown modules.
	with_test := []Image_File {
		{name = CATALOG_C_COMPILER_MODULE, file = synthetic_module_bytes(CATALOG_C_COMPILER_MODULE)},
		{name = CATALOG_ASSEMBLER_MODULE, file = synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE)},
		{name = "flood", file = synthetic_module_bytes("flood")},
	}
	_, problem = system_catalog_of_image(boot_image_encode(with_test, len(with_test)), release.RELEASE_NUMBER, .Release_Image)
	testing.expect(t, problem != "", "a release catalog must refuse a test module")

	with_only_in_image := []Image_File {
		{name = CATALOG_C_COMPILER_MODULE, file = synthetic_module_bytes(CATALOG_C_COMPILER_MODULE)},
		{name = CATALOG_ASSEMBLER_MODULE, file = synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE)},
		{name = foundation.OPERATION_FUZZING_MODULE, file = synthetic_module_bytes(foundation.OPERATION_FUZZING_MODULE)},
	}
	_, problem = system_catalog_of_image(boot_image_encode(with_only_in_image, len(with_only_in_image)), release.RELEASE_NUMBER, .Release_Image)
	testing.expect(t, problem != "", "a release catalog must refuse a single-image test module")

	with_unknown := []Image_File {
		{name = CATALOG_C_COMPILER_MODULE, file = synthetic_module_bytes(CATALOG_C_COMPILER_MODULE)},
		{name = CATALOG_ASSEMBLER_MODULE, file = synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE)},
		{name = "unknown_module_not_in_table", file = synthetic_module_bytes("unknown_module_not_in_table")},
	}
	unknown_image := boot_image_encode(with_unknown, len(with_unknown))
	_, problem = system_catalog_of_image(unknown_image, release.RELEASE_NUMBER, .Release_Image)
	testing.expect(t, problem != "", "a release catalog must refuse a module absent from the module table")
	_, problem = system_catalog_release_of_boot_image(unknown_image, release.RELEASE_NUMBER)
	testing.expect(t, problem != "", "release derivation must refuse a module absent from the module table")
}

// Full boot image: deterministic output across repeated calls and reversed
// entry order, every boot module present with its exact BLAKE3 hash, no
// resource listed as a module, and real lex_evaluator evaluation and
// canonical serialization.
@(test)
system_catalog_is_deterministic_and_evaluates_with_lex_evaluator :: proc(t: ^testing.T) {
	files, module_count := synthetic_boot_image_files()
	testing.expect(t, module_count > 100, "the boot image must hold the full module set")

	boot_image := boot_image_encode(files, module_count)
	catalog_first, p1 := system_catalog_of_image(boot_image, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect_value(t, p1, "")
	catalog_again, p2 := system_catalog_of_image(boot_image, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect_value(t, p2, "")
	testing.expect(t, catalog_first == catalog_again, "repeated generation must produce identical bytes")

	// Reversing the module order in the boot image produces identical bytes.
	reversed := slice.clone(files, context.temp_allocator)
	for i in 0 ..< module_count / 2 {
		reversed[i], reversed[module_count - 1 - i] = reversed[module_count - 1 - i], reversed[i]
	}
	reversed_image := boot_image_encode(reversed, module_count)
	catalog_reversed, p3 := system_catalog_of_image(reversed_image, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect_value(t, p3, "")
	testing.expect(t, catalog_first == catalog_reversed, "catalog output must not depend on boot image entry order")

	// Evaluate the generated catalog.lex with the real lex_evaluator.
	workspace := application_test_workspace()
	cfg := lex_evaluator.Declaration_Config{stack_bytes = CATALOG_TEST_STACK}
	root := lex_evaluator.declaration_evaluate(workspace, catalog_first, "", cfg)
	testing.expectf(t, root.ok && root.value.kind == .Record_Literal, "catalog.lex must evaluate to a record: %v", root)
	if !root.ok {
		return
	}

	// catalog.release matches release.RELEASE_NUMBER.
	rel_val, rel_ok := lex_evaluator.declaration_force_path(workspace, root.value, "release")
	testing.expect(t, rel_ok && rel_val.kind == .Text && rel_val.text == release.RELEASE_NUMBER, "catalog.release must match release.RELEASE_NUMBER")

	// catalog.c.compiler, catalog.c.assembler, and catalog.c.module.
	cc_val, cc_ok := lex_evaluator.declaration_force_path(workspace, root.value, "c.compiler")
	testing.expect(t, cc_ok && cc_val.kind == .Module_Ref, "catalog.c.compiler must be a module file")
	cc_hash, _ := lex_evaluator.hash_of(&workspace.evaluation, cc_val)
	testing.expect(t, cc_hash == blake3.hash(synthetic_module_bytes(CATALOG_C_COMPILER_MODULE)), "catalog.c.compiler must hold exact c_compiler hash")

	asm_val, asm_ok := lex_evaluator.declaration_force_path(workspace, root.value, "c.assembler")
	testing.expect(t, asm_ok && asm_val.kind == .Module_Ref, "catalog.c.assembler must be a module file")
	asm_hash, _ := lex_evaluator.hash_of(&workspace.evaluation, asm_val)
	testing.expect(t, asm_hash == blake3.hash(synthetic_module_bytes(CATALOG_ASSEMBLER_MODULE)), "catalog.c.assembler must hold exact assemble hash")

	mod_fn, fn_ok := lex_evaluator.declaration_force_path(workspace, root.value, "c.module")
	testing.expect(t, fn_ok && mod_fn.kind == .Function, "catalog.c.module must be a function")

	// Every module of the boot image is present under catalog.modules.<name>
	// with its exact BLAKE3 hash.
	for item in files[:module_count] {
		path := fmt.tprintf("modules.%s", item.name)
		val, ok := lex_evaluator.declaration_force_path(workspace, root.value, path)
		testing.expectf(t, ok && val.kind == .Module_Ref, "catalog.%s must evaluate to a module file", path)
		if ok {
			got_hash, hash_ok := lex_evaluator.hash_of(&workspace.evaluation, val)
			testing.expectf(t, hash_ok && got_hash == blake3.hash(item.file), "catalog.%s hash mismatch", path)
		}
	}

	// A resource of the boot image must not appear in catalog.modules.
	res_check := lex_evaluator.declaration_evaluate(workspace, catalog_first, "modules.start_list", cfg)
	testing.expect(t, !res_check.ok && res_check.failure_kind == .Field_Unknown, "a resource must not appear in catalog.modules")

	// Canonical serialization of catalog.modules succeeds and validates even
	// with all boot image modules.
	out_buf := make([]u8, 32 * 1024, context.temp_allocator)
	written, serialized := lex_evaluator.declaration_evaluate_to_buffer(workspace, catalog_first, "modules", cfg, out_buf)
	testing.expect(t, serialized, "catalog.modules must serialize cleanly")
	if serialized {
		header, val_refusal := declaration_eval.output_validate(out_buf[:written])
		testing.expect_value(t, val_refusal, declaration_eval.Output_Refusal.None)
		testing.expect_value(t, header.status, declaration_eval.Output_Status.Ok)
	}
}

// Release catalog: derived from release_boot_image_of and directly from
// boot.image give identical bytes, hold every shipped module with its exact
// BLAKE3 hash, and hold no test module.
@(test)
release_catalog_holds_shipped_modules_and_no_test_module :: proc(t: ^testing.T) {
	files, module_count := synthetic_boot_image_files()
	boot_image := boot_image_encode(files, module_count)

	// The un-filtered development boot image has test modules and must be
	// refused in Release_Image scope.
	_, refused_dev := system_catalog_of_image(boot_image, release.RELEASE_NUMBER, .Release_Image)
	testing.expect(t, refused_dev != "", "Release_Image scope must refuse the development boot image")

	release_image, img_problem := release_boot_image_of(boot_image)
	testing.expect_value(t, img_problem, "")

	from_release_image, p1 := system_catalog_of_image(release_image, release.RELEASE_NUMBER, .Release_Image)
	testing.expect_value(t, p1, "")
	from_boot_image, p2 := system_catalog_release_of_boot_image(boot_image, release.RELEASE_NUMBER)
	testing.expect_value(t, p2, "")
	testing.expect(t, from_release_image == from_boot_image, "release catalog from boot_release.image and from boot.image must be identical")

	workspace := application_test_workspace()
	cfg := lex_evaluator.Declaration_Config{stack_bytes = CATALOG_TEST_STACK}
	root := lex_evaluator.declaration_evaluate(workspace, from_release_image, "", cfg)
	testing.expectf(t, root.ok && root.value.kind == .Record_Literal, "catalog_release.lex must evaluate to a record: %v", root)
	if !root.ok {
		return
	}

	shipped_checked := 0
	tests_excluded := 0
	for row in foundation.module_builds {
		if module_included_in_release_image(row) {
			path := fmt.tprintf("modules.%s", row.name)
			val, ok := lex_evaluator.declaration_force_path(workspace, root.value, path)
			testing.expectf(t, ok && val.kind == .Module_Ref, "shipped module %s missing from release catalog", row.name)
			if ok {
				got_hash, hash_ok := lex_evaluator.hash_of(&workspace.evaluation, val)
				testing.expectf(t, hash_ok && got_hash == blake3.hash(synthetic_module_bytes(row.name)), "shipped module %s hash mismatch", row.name)
			}
			shipped_checked += 1
		} else {
			group, found := foundation.module_group_of_source(row.source)
			if (found && group == .Tests) || row.only_in_image != "" {
				field_decl := fmt.tprintf("    %s = ", row.name)
				testing.expectf(t, !strings.contains(from_release_image, field_decl), "test module %s must not appear in release catalog", row.name)
				tests_excluded += 1
			}
		}
	}
	testing.expect(t, shipped_checked > 30 && tests_excluded > 0, "must verify shipped modules and excluded test modules")

	// Confirm lex_evaluator also reports Field_Unknown for a test module.
	probe_res := lex_evaluator.declaration_evaluate(workspace, from_release_image, "modules.flood", cfg)
	testing.expect(t, !probe_res.ok && probe_res.failure_kind == .Field_Unknown, "modules.flood must be absent from catalog_release.lex")
}
