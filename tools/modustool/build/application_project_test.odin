#+build !freestanding
package build

import "base:runtime"
import "core:crypto/ed25519"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"
import "internal:projects/projects_core"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/release"
import "modus:contract/tree_hash"
import "modus:lex_evaluator"

// The first application of the system described as a Lex project, through
// the layer that holds today (src/md/features/application_projects.md, "The
// layers"): the real files of src/outside/projects/collatz, the tree hash of
// the folder as here(), the generated catalog declaration from a boot image,
// the evaluation of project.lex, the load by projects_core, and the stop of
// layer 2 as the service gives it.

@(private = "file")
COLLATZ_FOLDER :: "src/outside/projects/collatz"

@(private = "file")
concat :: proc(parts: []string) -> string {
	total := 0
	for part in parts {
		total += len(part)
	}
	bytes := make([]u8, total, context.temp_allocator)
	at := 0
	for part in parts {
		copy(bytes[at:], part)
		at += len(part)
	}
	return string(bytes)
}

@(private = "file")
hash_literal :: proc(hash: blake3.Hash) -> string {
	HEX :: "0123456789abcdef"
	hex := HEX
	text := make([]u8, 7 + 64, context.temp_allocator)
	copy(text[:7], "blake3:")
	for byte_value, index in hash {
		text[7 + index * 2] = hex[byte_value >> 4]
		text[7 + index * 2 + 1] = hex[byte_value & 0x0f]
	}
	return string(text)
}

// The files of the project, by name, as the folder holds them.
@(private = "file")
Project_File :: struct {
	name:  string,
	bytes: []u8,
}

@(private = "file")
project_files_read :: proc(t: ^testing.T) -> (files: []Project_File, ok: bool) {
	names := [?]string{"collatz.c", "pins.lex", "project.lex"}
	list := make([]Project_File, len(names), context.temp_allocator)
	for name, index in names {
		bytes, error := os.read_entire_file(concat({COLLATZ_FOLDER, "/", name}), context.temp_allocator)
		testing.expectf(t, error == nil, "%s/%s cannot be read: %v", COLLATZ_FOLDER, name, error)
		if error != nil {
			return nil, false
		}
		list[index] = {name, bytes}
	}
	return list, true
}

// The tree hash of a folder of files: each file an object by the BLAKE3
// hash of its bytes, the entries sorted by name, as the storage freezes it.
@(private = "file")
folder_tree_hash :: proc(files: []Project_File) -> (hash: blake3.Hash, refusal: tree_hash.Tree_Refusal) {
	sorted := slice.clone(files, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Project_File) -> bool {return a.name < b.name})
	entries := make([]tree_hash.Tree_Entry, len(sorted), context.temp_allocator)
	for file, index in sorted {
		entries[index], refusal = tree_hash.tree_entry_make(.Object, file.name, blake3.hash(file.bytes))
		if refusal != .None {
			return {}, refusal
		}
	}
	encoded := make([]u8, tree_hash.tree_encoded_size(entries), context.temp_allocator)
	written: int
	written, refusal = tree_hash.tree_encode(entries, encoded)
	if refusal != .None {
		return {}, refusal
	}
	return tree_hash.tree_hash(encoded[:written])
}

@(private = "file")
file_bytes :: proc(files: []Project_File, name: string) -> []u8 {
	for file in files {
		if file.name == name {
			return file.bytes
		}
	}
	return nil
}

// generated_test_catalogs builds a boot image with c_compiler, assemble,
// shipped modules, and a test module, then runs the real catalog declaration
// generator to produce both catalog.lex and catalog_release.lex.
@(private = "file")
generated_test_catalogs :: proc(t: ^testing.T, c_compiler_text, assemble_text: string) -> (dev_catalog, release_catalog: string, c_compiler_hash, assemble_hash: blake3.Hash, ok: bool) {
	root_text, console_text, flood_text: string = "root-module", "console-module", "flood-test-module"
	cc_bytes := transmute([]u8)c_compiler_text
	asm_bytes := transmute([]u8)assemble_text
	image_files := []Image_File {
		{name = ROOT_SERVICE_MODULE, file = transmute([]u8)root_text},
		{name = "console", file = transmute([]u8)console_text},
		{name = CATALOG_C_COMPILER_MODULE, file = cc_bytes},
		{name = CATALOG_ASSEMBLER_MODULE, file = asm_bytes},
		{name = "flood", file = transmute([]u8)flood_text},
	}
	boot_image := boot_image_encode(image_files, len(image_files))
	dev_problem, release_problem: string
	dev_catalog, dev_problem = system_catalog_of_image(boot_image, release.RELEASE_NUMBER, .Boot_Image)
	testing.expect_value(t, dev_problem, "")
	release_catalog, release_problem = system_catalog_release_of_boot_image(boot_image, release.RELEASE_NUMBER)
	testing.expect_value(t, release_problem, "")
	if dev_problem != "" || release_problem != "" {
		return "", "", {}, {}, false
	}
	return dev_catalog, release_catalog, blake3.hash(cc_bytes), blake3.hash(asm_bytes), true
}

@(private = "file")
evaluation_config :: proc(here: blake3.Hash, catalog_lex: string, bindings: ^[1]lex_evaluator.Declaration_Binding) -> lex_evaluator.Declaration_Config {
	bindings[0] = {name = "catalog", kind = .Lex_Source, source = catalog_lex}
	return {bindings = bindings[:], has_here = true, here_hash = here, stack_bytes = 2 * 1024 * 1024}
}

// The recipe hash that the evaluator gives for outputs.default.
@(private = "file")
output_recipe_hash :: proc(t: ^testing.T, project_lex: string, config: lex_evaluator.Declaration_Config) -> (hash: blake3.Hash, ok: bool) {
	workspace := application_test_workspace()
	result := lex_evaluator.declaration_evaluate(workspace, project_lex, "outputs.default", config)
	testing.expectf(t, result.ok && result.value.kind == .Recipe_Ref, "outputs.default is not a recipe: %v", result)
	if !result.ok || result.value.kind != .Recipe_Ref {
		return {}, false
	}
	return workspace.evaluation.recipes[result.value.integer].recipe_hash, true
}

@(private = "file")
signed_realisation :: proc(recipe, output: blake3.Hash, seed_byte: u8) -> (record: object_cache.Realisation_Record) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for &item in seed {
		item = seed_byte
	}
	private_key: ed25519.Private_Key
	_ = ed25519.private_key_set_bytes(&private_key, seed[:])
	ed25519.private_key_public_bytes(&private_key, record.signer_public_key[:])
	record.recipe_hash, record.output_hash, record.output_kind = recipe, output, .Tree
	signing, _ := object_cache.realisation_signing_bytes(&record)
	ed25519.sign(&private_key, signing[:], record.signature[:])
	return record
}

@(private = "file")
ed25519_check :: proc "contextless" (public_key: [object_cache.PUBLIC_KEY_SIZE]u8, message: []u8, signature: [object_cache.SIGNATURE_SIZE]u8, _: rawptr) -> bool {
	context = runtime.default_context()
	key_copy, signature_copy := public_key, signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, key_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, signature_copy[:])
}

// The refusals of layer 1, on the real files with the generated catalog
// declaration: a pins.lex with a damaged hash, a project whose source is not
// a tree, a project with no pin asked for the recipe of its inputs, a recipe
// whose builder needs the sandbox, and a realisation of the project signed
// by a key that the policy does not trust or with a wrong signature. Nothing
// is kept after a refusal.
@(test)
the_collatz_project_refuses_what_layer_one_must_refuse :: proc(t: ^testing.T) {
	files, read := project_files_read(t)
	if !read {
		return
	}
	here, tree_refusal := folder_tree_hash(files)
	testing.expect_value(t, tree_refusal, tree_hash.Tree_Refusal.None)
	catalog_lex, _, c_compiler_hash, _, catalog_ok := generated_test_catalogs(t, "c_compiler-module", "assemble-module")
	if !catalog_ok {
		return
	}
	bindings: [1]lex_evaluator.Declaration_Binding
	config := evaluation_config(here, catalog_lex, &bindings)
	project_lex := string(file_bytes(files, "project.lex"))

	workspace := application_test_workspace()
	evaluation: [4096]u8
	evaluation_length, evaluated := lex_evaluator.declaration_evaluate_to_buffer(workspace, project_lex, "", config, evaluation[:])
	testing.expect(t, evaluated, "project.lex evaluates")

	state := new(projects_core.Projects_State, context.temp_allocator)
	table := new(projects_core.Loaded_Projects, context.temp_allocator)
	store := new(pr.Memory_Private_Store, context.temp_allocator)
	projects_core.state_init(state)
	projects_core.loaded_projects_init(table, pr.memory_private_store_port(store))
	name := transmute([]u8)string("collatz")

	// A pins.lex whose hash is not 64 hexadecimal digits.
	damaged := "{\n  tool = { tree = blake3:12 },\n}\n"
	_, refusal := projects_core.load_project(table, state, 1, name, evaluation[:evaluation_length], transmute([]u8)damaged)
	testing.expect_value(t, refusal, pr.Project_Refusal.Invalid_Hash_Literal)
	testing.expect(t, projects_core.find_loaded(table, 1, name) == nil, "a refused load keeps no project")

	// A project whose source is a text, and one whose source is a bare
	// hash: neither is a tree.
	texted := "project {\n  source = \"collatz\",\n}\n"
	text_length, _ := lex_evaluator.declaration_evaluate_to_buffer(workspace, texted, "", config, evaluation[:])
	_, refusal = projects_core.load_project(table, state, 1, name, evaluation[:text_length], file_bytes(files, "pins.lex"))
	testing.expect_value(t, refusal, pr.Project_Refusal.Missing_Field)
	bare := concat({"project {\n  source = ", hash_literal(here), ",\n}\n"})
	bare_length, _ := lex_evaluator.declaration_evaluate_to_buffer(workspace, bare, "", config, evaluation[:])
	_, refusal = projects_core.load_project(table, state, 1, name, evaluation[:bare_length], file_bytes(files, "pins.lex"))
	testing.expect_value(t, refusal, pr.Project_Refusal.Missing_Field)

	// A recipe whose arguments name the source by a bare hash: the
	// evaluation refuses it, as the conversion does.
	untyped := concat({"project {\n  source = here(),\n  outputs = { default = recipe(module(", hash_literal(c_compiler_hash), "), { source = ", hash_literal(here), " }) },\n}\n"})
	untyped_result := lex_evaluator.declaration_evaluate(workspace, untyped, "outputs.default", config)
	testing.expect_value(t, untyped_result.failure_kind, declaration_eval.Failure_Kind.Recipe_Refused)
	testing.expect_value(t, untyped_result.detail, pr.recipe_refusal_words[.Untyped_Hash])
	// A builder given by a bare hash names no kind either.
	bare_builder := concat({"project {\n  source = here(),\n  outputs = { default = recipe(", hash_literal(c_compiler_hash), ", { source = here() }) },\n}\n"})
	bare_builder_result := lex_evaluator.declaration_evaluate(workspace, bare_builder, "outputs.default", config)
	testing.expect_value(t, bare_builder_result.failure_kind, declaration_eval.Failure_Kind.Type_Error)
	testing.expect_value(t, bare_builder_result.detail, "recipe")

	// Loaded right, the project has no pin, so no recipe of its inputs.
	evaluation_length, _ = lex_evaluator.declaration_evaluate_to_buffer(workspace, project_lex, "", config, evaluation[:])
	count, loaded := projects_core.load_project(table, state, 1, name, evaluation[:evaluation_length], file_bytes(files, "pins.lex"))
	testing.expect_value(t, loaded, pr.Project_Refusal.None)
	testing.expect_value(t, count, 0)
	inputs_spec := new(pr.Recipe_Spec, context.temp_allocator)
	inputs_refusal := projects_core.inputs_recipe(table, state, 1, name, inputs_spec)
	testing.expect_value(t, inputs_refusal, pr.Project_Refusal.Pin_Not_Found)

	// The recipe of the output, on the path of the export
	// register_evaluation: the evaluator writes outputs.default, the service
	// converts it with the one conversion and registers it, and refuses at
	// its build a builder that needs the sandbox, and keeps nothing.
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	output_length, output_ok := lex_evaluator.declaration_evaluate_to_buffer(workspace, project_lex, "outputs.default", config, evaluation[:])
	testing.expect(t, output_ok, "outputs.default evaluates")
	recipes := new(recipes_core.Recipes_State, context.temp_allocator)
	registry := new(recipes_core.Recipe_Registry, context.temp_allocator)
	recipes_store := new(pr.Memory_Private_Store, context.temp_allocator)
	recipes_core.state_init(recipes, pr.memory_private_store_port(recipes_store))
	recipe, register_refusal := recipes_core.register_evaluation(registry, evaluation[:output_length], spec)
	testing.expect_value(t, register_refusal, pr.Recipe_Refusal.None)
	built := recipes_core.build_registered(recipes, registry, recipe, .Cache_First)
	testing.expect_value(t, built.refusal, pr.Recipe_Refusal.Builder_Needs_Sandbox)
	testing.expect_value(t, recipes_core.realisation_rows(recipes, nil), 0)

	// A realisation of that recipe from a cache: signed by a key that the
	// policy does not trust, then by the trusted key with one bit changed.
	trusted := signed_realisation(recipe, here, 1)
	stranger := signed_realisation(recipe, here, 2)
	signers := [1][object_cache.PUBLIC_KEY_SIZE]u8{trusted.signer_public_key}
	policy := object_cache.Substitution_Policy{mode = .Cache_Only, trusted_signers = signers[:]}
	decision := object_cache.substitution_check(policy, object_cache.Substitution_Realisation_Subject{expected_recipe_hash = recipe, realisation = stranger}, ed25519_check)
	testing.expect_value(t, decision, object_cache.Substitution_Decision.Refuse_Untrusted_Signer)
	forged := trusted
	forged.signature[0] ~= 1
	decision = object_cache.substitution_check(policy, object_cache.Substitution_Realisation_Subject{expected_recipe_hash = recipe, realisation = forged}, ed25519_check)
	testing.expect_value(t, decision, object_cache.Substitution_Decision.Refuse_Bad_Signature)
	other_recipe := blake3.hash(transmute([]u8)string("another recipe"))
	decision = object_cache.substitution_check(policy, object_cache.Substitution_Realisation_Subject{expected_recipe_hash = other_recipe, realisation = trusted}, ed25519_check)
	testing.expect(t, decision != .Trust_By_Signer, "a realisation of another recipe is not trusted")

	// The success case of the check: the trusted, intact realisation.
	decision = object_cache.substitution_check(policy, object_cache.Substitution_Realisation_Subject{expected_recipe_hash = recipe, realisation = trusted}, ed25519_check)
	testing.expect_value(t, decision, object_cache.Substitution_Decision.Trust_By_Signer)
}

// Layer 1, the success case: the real project evaluates against the generated
// catalog.lex (and catalog_release.lex), loads, registers its recipe with
// recipes_core under one identity, and changes its recipe hash when any byte
// of collatz.c, c_compiler, or assemble changes.
@(test)
the_collatz_project_evaluates_loads_and_names_its_output :: proc(t: ^testing.T) {
	files, read := project_files_read(t)
	if !read {
		return
	}
	here, tree_refusal := folder_tree_hash(files)
	testing.expect_value(t, tree_refusal, tree_hash.Tree_Refusal.None)
	catalog_lex, release_catalog_lex, c_compiler_hash, assemble_hash, catalog_ok := generated_test_catalogs(t, "c_compiler-module", "assemble-module")
	if !catalog_ok {
		return
	}
	bindings: [1]lex_evaluator.Declaration_Binding
	config := evaluation_config(here, catalog_lex, &bindings)
	project_lex := string(file_bytes(files, "project.lex"))

	workspace := application_test_workspace()
	evaluation: [4096]u8
	evaluation_length, evaluated := lex_evaluator.declaration_evaluate_to_buffer(workspace, project_lex, "", config, evaluation[:])
	testing.expect(t, evaluated, "project.lex evaluates")
	header, output_refusal := declaration_eval.output_validate(evaluation[:evaluation_length])
	testing.expect_value(t, output_refusal, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, header.status, declaration_eval.Output_Status.Ok)

	declaration: pr.Project_Declaration
	testing.expect_value(t, pr.project_declaration_of_evaluation(transmute([]u8)string("collatz"), evaluation[:evaluation_length], &declaration), pr.Project_Refusal.None)
	testing.expect(t, declaration.project_tree_hash == here, "the source of the project is the tree of its folder")

	state := new(projects_core.Projects_State, context.temp_allocator)
	table := new(projects_core.Loaded_Projects, context.temp_allocator)
	store := new(pr.Memory_Private_Store, context.temp_allocator)
	projects_core.state_init(state)
	projects_core.loaded_projects_init(table, pr.memory_private_store_port(store))
	count, refusal := projects_core.load_project(table, state, 1, transmute([]u8)string("collatz"), evaluation[:evaluation_length], file_bytes(files, "pins.lex"))
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, count, 0)

	first, first_ok := output_recipe_hash(t, project_lex, config)
	again, again_ok := output_recipe_hash(t, project_lex, config)
	testing.expect(t, first_ok && again_ok && first == again, "the same files give the same recipe")

	// Development catalog and release catalog give the exact same recipe hash
	// because c_compiler and assemble have the same bytes in both images.
	release_bindings: [1]lex_evaluator.Declaration_Binding
	from_release, from_release_ok := output_recipe_hash(t, project_lex, evaluation_config(here, release_catalog_lex, &release_bindings))
	testing.expect(t, from_release_ok && from_release == first, "catalog.lex and catalog_release.lex give the same collatz recipe hash")

	// One identity: the hash that the evaluator gives is the hash under
	// which the service registers the recipe of the output, through the
	// real conversion, and the record names c_compiler as builder and
	// assembler and source as typed inputs.
	output_length, output_ok := lex_evaluator.declaration_evaluate_to_buffer(workspace, project_lex, "outputs.default", config, evaluation[:])
	testing.expect(t, output_ok, "outputs.default evaluates")
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	registry := new(recipes_core.Recipe_Registry, context.temp_allocator)
	registered, register_refusal := recipes_core.register_evaluation(registry, evaluation[:output_length], spec)
	testing.expect_value(t, register_refusal, pr.Recipe_Refusal.None)
	testing.expect(t, registered == first, "the service registers the recipe under the hash of the evaluator")
	testing.expect(t, spec.builder_hash == c_compiler_hash, "the builder of catalog.c.module is c_compiler")
	testing.expect_value(t, spec.input_count, u32(2))
	testing.expect_value(t, string(spec.inputs[0].name_bytes[:spec.inputs[0].name_length]), "assembler")
	testing.expect_value(t, spec.inputs[0].kind, object_cache.Cache_Object_Kind.Blob)
	testing.expect(t, spec.inputs[0].hash == assemble_hash, "the first input is the assemble module file")
	testing.expect_value(t, string(spec.inputs[1].name_bytes[:spec.inputs[1].name_length]), "source")
	testing.expect_value(t, spec.inputs[1].kind, object_cache.Cache_Object_Kind.Tree)
	testing.expect(t, spec.inputs[1].hash == here, "the second input is the tree of the folder")

	// One changed byte of collatz.c gives another tree and another recipe.
	changed := slice.clone(files, context.temp_allocator)
	for &file in changed {
		if file.name == "collatz.c" {
			file.bytes = slice.clone(file.bytes, context.temp_allocator)
			file.bytes[0] ~= 1
		}
	}
	other_here, _ := folder_tree_hash(changed)
	testing.expect(t, other_here != here, "a changed byte of the source gives another tree")
	other_bindings: [1]lex_evaluator.Declaration_Binding
	other, other_ok := output_recipe_hash(t, project_lex, evaluation_config(other_here, catalog_lex, &other_bindings))
	testing.expect(t, other_ok && other != first, "another source gives another recipe")

	// One changed byte of c_compiler or assemble changes the generated
	// catalog and gives another recipe.
	other_cc_catalog, _, _, _, other_cc_ok := generated_test_catalogs(t, "c_compiler-module-v2", "assemble-module")
	testing.expect(t, other_cc_ok && other_cc_catalog != catalog_lex)
	other_cc_bindings: [1]lex_evaluator.Declaration_Binding
	other_cc, other_cc_eval_ok := output_recipe_hash(t, project_lex, evaluation_config(here, other_cc_catalog, &other_cc_bindings))
	testing.expect(t, other_cc_eval_ok && other_cc != first, "another c_compiler gives another recipe")

	other_asm_catalog, _, _, _, other_asm_ok := generated_test_catalogs(t, "c_compiler-module", "assemble-module-v2")
	testing.expect(t, other_asm_ok && other_asm_catalog != catalog_lex)
	other_asm_bindings: [1]lex_evaluator.Declaration_Binding
	other_asm, other_asm_eval_ok := output_recipe_hash(t, project_lex, evaluation_config(here, other_asm_catalog, &other_asm_bindings))
	testing.expect(t, other_asm_eval_ok && other_asm != first, "another assemble gives another recipe")
}

// application_test_workspace gives an evaluation workspace with the pools
// of the scale 0, which hold each project of these tests.
@(private)
application_test_workspace :: proc() -> ^lex_evaluator.Declaration_Workspace {
	workspace := new(lex_evaluator.Declaration_Workspace, context.temp_allocator)
	pools := lex_evaluator.declaration_pools_of_scale(0)
	memory, _ := mem.alloc_bytes(lex_evaluator.declaration_workspace_bytes(pools), 64, context.temp_allocator)
	lex_evaluator.declaration_workspace_carve(workspace, memory, pools)
	return workspace
}
