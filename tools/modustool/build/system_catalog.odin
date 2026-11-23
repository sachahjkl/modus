// The catalog declaration of the system written by its build
// (src/md/features/application_projects.md, "The catalog of the system").
//
// Each build writes build/catalog.lex from the built boot image and
// build/catalog_release.lex for the release boot image without test modules.
// Projects read their system modules and C builder recipe from catalog
// instead of writing hashes by hand.
package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/release"
import "modus:contract/system_description"
import "modus:contract/text_encoding"
import "modus:lex_parser"
import "modustool:foundation"

// The catalog declarations written by the build.
CATALOG_FILE :: foundation.BUILD_FOLDER + "/catalog.lex"
CATALOG_RELEASE_FILE :: foundation.BUILD_FOLDER + "/catalog_release.lex"

// The modules that catalog.c.module uses to build a C module.
CATALOG_C_BUILDER_MODULE :: "c_builder"
CATALOG_C_COMPILER_MODULE :: "c_compiler"
CATALOG_ASSEMBLER_MODULE :: "assemble"
CATALOG_HOST_MODULE :: "host"

// Which modules a generated catalog declaration can hold.
Catalog_Scope :: enum u8 {
	Boot_Image    = 0, // Every module of the boot image.
	Release_Image = 1, // Shipped modules only: any test module or unknown module is refused.
}

// catalog_release_number_valid says whether release_number can appear
// unescaped inside a Lex text literal: non-empty valid text with no quote,
// backslash or control character.
catalog_release_number_valid :: proc(release_number: string) -> bool {
	if len(release_number) == 0 || !text_encoding.text_valid(transmute([]u8)release_number) {
		return false
	}
	for byte_value in transmute([]u8)release_number {
		if byte_value == '"' || byte_value == '\\' {
			return false
		}
	}
	return true
}

// boot_image_module_hashes extracts each module entry of a boot image and
// verifies that its bytes lie inside the image and hash to its stated
// BLAKE3 hash.
boot_image_module_hashes :: proc(image: []u8) -> (modules: []Module_Hash, problem: string) {
	entries, _, valid := info.image_tables(image)
	if !valid {
		return nil, "the bytes are not a boot image"
	}
	list := make([dynamic]Module_Hash, 0, len(entries), context.temp_allocator)
	for &entry in entries {
		name := system_description.name_of(&entry.name)
		bytes, inside := info.image_entry_bytes(image, &entry)
		if !inside {
			return nil, fmt.tprintf("the entry %s of the boot image points outside it", name)
		}
		if blake3.hash(bytes) != entry.hash {
			return nil, fmt.tprintf("the module %s of the boot image does not hash to its stated BLAKE3 hash", name)
		}
		append(&list, Module_Hash{name = name, hash = entry.hash})
	}
	return list[:], ""
}

// system_catalog_of_modules generates the canonical Lex catalog declaration
// deterministically from a list of module names and BLAKE3 hashes. Entries
// are sorted by name in ascending byte order so output does not depend on
// input order. In Release_Image scope, any test module or module absent from
// the module table is refused.
system_catalog_of_modules :: proc(modules: []Module_Hash, release_number: string, scope: Catalog_Scope) -> (text: string, problem: string) {
	if !catalog_release_number_valid(release_number) {
		return "", fmt.tprintf("the release number %q is not valid text for a catalog declaration", release_number)
	}
	if len(modules) == 0 {
		return "", "the boot image holds no module"
	}
	sorted := slice.clone(modules, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Module_Hash) -> bool {
		return a.name < b.name
	})

	c_builder_hash: blake3.Hash
	has_c_builder := false
	c_compiler_hash: blake3.Hash
	has_c_compiler := false
	assemble_hash: blake3.Hash
	has_assemble := false
	host_hash: blake3.Hash
	has_host := false

	for item, index in sorted {
		if !lex_parser.name_valid(item.name) {
			return "", fmt.tprintf("the module name %q is not a valid Lex field name", item.name)
		}
		if index > 0 && item.name == sorted[index - 1].name {
			return "", fmt.tprintf("the boot image names the module %s twice", item.name)
		}
		switch scope {
		case .Boot_Image:
		case .Release_Image:
			row, found := module_row_of_name(item.name)
			if !found {
				return "", fmt.tprintf("the release boot image holds the module %s, which the table of the modules does not name", item.name)
			}
			if !module_included_in_release_image(row) {
				return "", fmt.tprintf("the release boot image holds the test module %s: a release catalog declaration names no test module", item.name)
			}
		}
		switch item.name {
		case CATALOG_C_BUILDER_MODULE:
			c_builder_hash = item.hash
			has_c_builder = true
		case CATALOG_C_COMPILER_MODULE:
			c_compiler_hash = item.hash
			has_c_compiler = true
		case CATALOG_ASSEMBLER_MODULE:
			assemble_hash = item.hash
			has_assemble = true
		case CATALOG_HOST_MODULE:
			host_hash = item.hash
			has_host = true
		}
	}

	if !has_c_builder {
		return "", fmt.tprintf("the boot image does not hold the module %s, which catalog.c.module needs", CATALOG_C_BUILDER_MODULE)
	}
	if !has_c_compiler {
		return "", fmt.tprintf("the boot image does not hold the module %s, which catalog.c.module needs", CATALOG_C_COMPILER_MODULE)
	}
	if !has_assemble {
		return "", fmt.tprintf("the boot image does not hold the module %s, which catalog.c.module needs", CATALOG_ASSEMBLER_MODULE)
	}
	if !has_host {
		return "", fmt.tprintf("the boot image does not hold the module %s, which catalog.c.module needs", CATALOG_HOST_MODULE)
	}

	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&out, "// Catalog declaration of modus %s.\n", release_number)
	strings.write_string(&out, "{\n")
	fmt.sbprintf(&out, "  release = \"%s\",\n", release_number)
	strings.write_string(&out, "  modules = {\n")
	for item in sorted {
		fmt.sbprintf(&out, "    %s = module(blake3:%s),\n", item.name, hash_as_hexadecimal(item.hash))
	}
	strings.write_string(&out, "  },\n")
	c_builder_hex := hash_as_hexadecimal(c_builder_hash)
	c_compiler_hex := hash_as_hexadecimal(c_compiler_hash)
	assemble_hex := hash_as_hexadecimal(assemble_hash)
	host_hex := hash_as_hexadecimal(host_hash)
	strings.write_string(&out, "  c = {\n")
	fmt.sbprintf(&out, "    builder = module(blake3:%s),\n", c_builder_hex)
	fmt.sbprintf(&out, "    compiler = module(blake3:%s),\n", c_compiler_hex)
	fmt.sbprintf(&out, "    assembler = module(blake3:%s),\n", assemble_hex)
	fmt.sbprintf(&out, "    module = (path) => recipe(module(blake3:%s), {{\n", c_builder_hex)
	fmt.sbprintf(&out, "      assembler = module(blake3:%s),\n", assemble_hex)
	fmt.sbprintf(&out, "      compiler = module(blake3:%s),\n", c_compiler_hex)
	fmt.sbprintf(&out, "      host = module(blake3:%s),\n", host_hex)
	strings.write_string(&out, "      path = path,\n")
	strings.write_string(&out, "      source = here(),\n")
	strings.write_string(&out, "    }),\n")
	strings.write_string(&out, "  },\n")
	strings.write_string(&out, "}\n")
	return strings.to_string(out), ""
}

// system_catalog_of_image generates the canonical Lex catalog declaration
// directly from the bytes of a built boot image.
system_catalog_of_image :: proc(image: []u8, release_number: string, scope: Catalog_Scope) -> (text: string, problem: string) {
	modules, extract_problem := boot_image_module_hashes(image)
	if extract_problem != "" {
		return "", extract_problem
	}
	return system_catalog_of_modules(modules, release_number, scope)
}

// system_catalog_release_of_boot_image derives the release catalog
// declaration from the development boot image by keeping only the modules
// that module_included_in_release_image ships, matching release_boot_image_of
// without copying the module bytes.
system_catalog_release_of_boot_image :: proc(boot_image: []u8, release_number: string) -> (text: string, problem: string) {
	modules, extract_problem := boot_image_module_hashes(boot_image)
	if extract_problem != "" {
		return "", extract_problem
	}
	shipped := make([dynamic]Module_Hash, 0, len(modules), context.temp_allocator)
	for item in modules {
		row, found := module_row_of_name(item.name)
		if !found {
			return "", fmt.tprintf("the boot image of the build holds the module %s, which the table of the modules does not name", item.name)
		}
		if !module_included_in_release_image(row) {
			continue
		}
		append(&shipped, item)
	}
	return system_catalog_of_modules(shipped[:], release_number, .Release_Image)
}

// system_catalogs_write writes build/catalog.lex and
// build/catalog_release.lex from the built boot image.
system_catalogs_write :: proc() -> bool {
	boot_image := foundation.read_file(BOOT_IMAGE) or_return
	catalog_text, catalog_problem := system_catalog_of_image(boot_image, release.RELEASE_NUMBER, .Boot_Image)
	if catalog_problem != "" {
		fmt.eprintfln("modustool: catalog: %s", catalog_problem)
		return false
	}
	if error := os.write_entire_file(CATALOG_FILE, transmute([]u8)catalog_text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CATALOG_FILE, error)
		return false
	}
	release_text, release_problem := system_catalog_release_of_boot_image(boot_image, release.RELEASE_NUMBER)
	if release_problem != "" {
		fmt.eprintfln("modustool: release catalog: %s", release_problem)
		return false
	}
	if error := os.write_entire_file(CATALOG_RELEASE_FILE, transmute([]u8)release_text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CATALOG_RELEASE_FILE, error)
		return false
	}
	return true
}
