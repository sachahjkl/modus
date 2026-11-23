// The exports of the recipes service (src/md/features/recipes.md, "The
// builder"; src/md/features/declarations.md, "The services of the
// declarations").
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:system"

// The failures of the exports of this file, each with its error record.
ERROR_NO_CALLER :: i64(-1) // No_Grant, Connection: the call came through no connection.
ERROR_ACTS_FOR_PRINCIPAL :: i64(-2) // No_Grant, Acts_For_Principal: the caller does not act for its principal.
ERROR_NOT_READY :: i64(-3) // State, Requests: the service has not started its tables.
ERROR_RECIPE :: i64(-4) // The recipe is refused: the value found is the Recipe_Refusal.
ERROR_BUILD :: i64(-5) // The build is refused: the value found is the Recipe_Refusal.

// The registered recipes and the history of the builds.
service_registry: recipes_core.Recipe_Registry

// The parts of a recipe of the call, copied once out of the call region.
copied_head: pr.Recipe_Head
copied_inputs: [pr.MAX_RECIPE_INPUTS]pr.Recipe_Input_Row
copied_arguments: [pr.MAX_RECIPE_ARG_BYTES]u8
copied_output: [recipes_core.MAX_RECIPE_OUTPUT_BYTES]u8 // The output of an evaluation of the call, copied once out of the call region.
copied_reference: pr.Recipe_Reference
export_spec: pr.Recipe_Spec
export_result: pr.Recipe_Build_Result

// caller_check refuses a call with no connection and, when acts is true, a
// caller that does not act for its principal: a build spends the store of
// the service for the principal that asks.
@(private = "file")
caller_check :: proc "contextless" (acts: bool, error: ^errors.Error_Record) -> (failure: i64, ok: bool) {
	connection := system.service_caller()
	if connection == nil {
		return errors.fail(error, ERROR_NO_CALLER, .No_Grant, .Connection), false
	}
	if acts && connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal), false
	}
	if !service_state.initialized {
		return errors.fail(error, ERROR_NOT_READY, .State, .Requests), false
	}
	return 0, true
}

// recipe_refusal_fail writes the error record of a refusal of the recipes
// contract, with the refusal as the value found.
@(private = "file")
recipe_refusal_fail :: proc "contextless" (error: ^errors.Error_Record, result: i64, refusal: pr.Recipe_Refusal, argument: i64 = 0, bad_index: u32 = 0) -> i64 {
	if error != nil {
		error^ = recipes_core.recipe_refusal_record(refusal, argument, bad_index)
	}
	return result
}

// register keeps a recipe by its hash, so build and cache_lookup name it
// with 32 bytes.
//
// - **head**: the builder hash, the output kind, the date of the recipe and
//   the bound of its output in blocks.
// - **inputs**: one row for each input, a name and a hash, at most 32.
// - **arguments**: the bytes of the argument record, at most 4096.
// - **result**: one row: the recipe hash.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_RECIPE with the refusal as the value found.
@(export, link_name = "register")
register :: proc "c" (head: ^pr.Recipe_Head, inputs: ^system.Table_To_Read(pr.Recipe_Input_Row), arguments: ^system.Bytes_To_Read, result: ^[]pr.Recipe_Reference, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if head == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	copied_head = intrinsics.volatile_load(head)
	input_count: u64 = 0
	if inputs != nil {
		input_count = intrinsics.volatile_load(&inputs.count)
	}
	if input_count > pr.MAX_RECIPE_INPUTS {
		return recipe_refusal_fail(error, ERROR_RECIPE, .Too_Many_Inputs, 2)
	}
	for index in 0 ..< input_count {
		copied_inputs[index] = intrinsics.volatile_load(&inputs.records[index])
	}
	argument_count: u64 = 0
	if arguments != nil {
		argument_count = intrinsics.volatile_load(&arguments.count)
	}
	if argument_count > pr.MAX_RECIPE_ARG_BYTES {
		return recipe_refusal_fail(error, ERROR_RECIPE, .Arguments_Too_Large, 3)
	}
	if argument_count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_arguments[0], arguments.bytes, int(argument_count))
	}
	refusal, bad_index := pr.recipe_spec_of_parts(&copied_head, copied_inputs[:input_count], copied_arguments[:argument_count], &export_spec)
	if refusal != .None {
		argument := i64(1)
		if refusal == .Invalid_Input_Name || refusal == .Bad_Input_Kind || refusal == .Zero_Input_Hash || refusal == .Duplicate_Input {
			argument = 2
		}
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, argument, bad_index)
	}
	recipe_hash, register_refusal := recipes_core.register_recipe(&service_registry, &export_spec)
	if register_refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, register_refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = {recipe_hash = value_kinds.Hash_Field(recipe_hash)}
	}
	return 1
}

// register_evaluation keeps the recipe that a declaration names, from the
// output of its evaluation: outputs.default of a project, as the evaluator
// wrote it (src/md/features/application_projects.md, "The export of the
// service"). The service copies the bytes into its own memory before it
// reads them, converts them with the one conversion of the contract, and
// registers the record under the hash that the evaluator wrote.
//
// - **output**: the output of the evaluation, whose value is a recipe.
// - **result**: one row: the recipe hash.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_RECIPE with the refusal as the value found: a bare hash, an input
// below the first level, a value that is no recipe, a damaged output, too
// many inputs, arguments too large.
@(export, link_name = "register_evaluation")
register_evaluation :: proc "c" (output: ^system.Bytes_To_Read, result: ^[]pr.Recipe_Reference, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if output == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	count := intrinsics.volatile_load(&output.count)
	if count > recipes_core.MAX_RECIPE_OUTPUT_BYTES {
		return errors.fail(error, ERROR_RECIPE, .Too_Long, .Bytes, 1, 0, recipes_core.MAX_RECIPE_OUTPUT_BYTES, i64(count))
	}
	// A private copy: the caller can change its memory during the call, and
	// the conversion reads the bytes more than once.
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_output[0], output.bytes, int(count))
	}
	recipe_hash, refusal := recipes_core.register_evaluation(&service_registry, copied_output[:count], &export_spec)
	if refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = {recipe_hash = value_kinds.Hash_Field(recipe_hash)}
	}
	return 1
}

// build realises a registered recipe. A mode that takes the cache gives a
// realisation of the local store at once, with no build; on a miss the
// service builds the recipe, keeps its output and its realisation, and the
// next build of the recipe is a hit.
//
// - **recipe**: the recipe hash that register gave.
// - **mode**: the Build_Mode word: 1 Cache_First, 2 Build_Only,
//   3 Cache_Only, 4 Verify.
// - **result**: one row: the outcome, the recipe hash and the output hash.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or ERROR_BUILD
// with the refusal as the value found.
@(export, link_name = "build")
build :: proc "c" (recipe: ^pr.Recipe_Reference, mode: i64, result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if recipe == nil {
		return errors.fail(error, ERROR_BUILD, .Bad_Address, .None, 1)
	}
	if mode < 0 {
		return recipe_refusal_fail(error, ERROR_BUILD, .Bad_Build_Mode, 2)
	}
	checked_mode, mode_ok := pr.build_mode_of_word(u64(mode))
	if !mode_ok {
		return recipe_refusal_fail(error, ERROR_BUILD, .Bad_Build_Mode, 2)
	}
	copied_reference = intrinsics.volatile_load(recipe)
	export_result = recipes_core.build_registered(&service_state, &service_registry, blake3.Hash(copied_reference.recipe_hash), checked_mode, &builder_start)
	system.log_fact(.Info, Recipe_Build_Completed{outcome = u64(export_result.outcome), refusal_code = u64(export_result.refusal)})
	if export_result.refusal != .None {
		return recipe_refusal_fail(error, ERROR_BUILD, export_result.refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = pr.recipe_build_row_of(&export_result, checked_mode)
	}
	return 1
}

// cache_lookup gives the realisation of a recipe in the local store, with
// no build.
//
// - **recipe**: the recipe hash.
// - **result**: one row when the store holds a realisation of the recipe.
//
// The result is 1 when the store holds one, 0 when it holds none, or a
// negative number with an error record: ERROR_NO_CALLER or ERROR_NOT_READY.
@(export, link_name = "cache_lookup")
cache_lookup :: proc "c" (recipe: ^pr.Recipe_Reference, result: ^[]pr.Realisation_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(false, error); !ok {
		return failure
	}
	if recipe == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	copied_reference = intrinsics.volatile_load(recipe)
	slot, found := recipes_core.query_provenance(&service_state, blake3.Hash(copied_reference.recipe_hash))
	if !found {
		return 0
	}
	if len(result^) > 0 {
		result[0] = pr.realisation_row_of(&slot.record, u64(slot.origin))
	}
	return 1
}

// builds gives the newest builds, oldest first, at most 32.
//
// The result is the count of builds, or a negative number with an error
// record: ERROR_NO_CALLER or ERROR_NOT_READY.
@(export, link_name = "builds")
builds :: proc "c" (result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(false, error); !ok {
		return failure
	}
	return i64(recipes_core.history_rows(&service_registry, result^))
}

// realisations gives each realisation of the local store.
//
// The result is the count of realisations, or a negative number with an
// error record: ERROR_NO_CALLER or ERROR_NOT_READY.
@(export, link_name = "realisations")
realisations :: proc "c" (result: ^[]pr.Realisation_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(false, error); !ok {
		return failure
	}
	return i64(recipes_core.realisation_rows(&service_state, result^))
}

// The name of the source of a C build, copied once out of the call.
copied_source_name: [pr.MAX_ENTRY_NAME_BYTES]u8

// build_c builds one C source into a module file with the native C builder, or substitutes its realisation
// (src/md/features/program_loop.md, "The native C builder").
//
// The recipe names the hash of the module c_compiler and of the module assemble of the boot image, the name of the
// source and the hash of its bytes. A realisation of that recipe in the local store gives the module with no compile;
// else the compiler and the assembler run, each in a call host with no grant, and the realisation and the module are
// kept in the private store of the service. The module goes into the memory object that the caller lends.
//
// - **source_name**: the name of the source, a name of an entry of a tree: `hello.c`.
// - **source**: a memory object with the source, which the caller lends with Read.
// - **source_size**: the bytes of the source, 1 to 256 KiB, the bound of compile.
// - **module**: a memory object that holds the module, at most 64 KiB, which the caller lends with Read and Write.
//
// The log says whether the module was built or substituted, with the recipe hash and the hash of the module.
//
// The caller must act for its principal (**Acts_For_Principal**). The result is the bytes of the module, or a negative
// number with an error record:
//
// - ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL or ERROR_NOT_READY.
// - `Unsupported` (-5): the service has no boot image, or the image has no module c_compiler or assemble.
// - `Empty` or `Too_Long` (-4, argument 1): the name; `Bad_Value` (-4): a name that no tree takes.
// - `Out_Of_Range` (-4, argument 3): a size of 0, past 256 KiB or past the memory object.
// - The error record of the step that failed (-5): the record of compile, whose value is the byte of the source that
//   the diagnostic names (argument 2); of assemble; `No_Answer` when the compiler or the assembler gives no answer
//   before the hang bound, which ends its call host; `Empty` or `Out_Of_Range` for a count of bytes that the call
//   host gave and its memory object cannot hold; or `Malformed` for a module that module.validate refuses. Nothing is
//   kept.
// - `Too_Small` (-5, argument 4): the memory object of the module holds fewer bytes than the module.
// - The refusal of the recipe (-5), as for build: `Store_Failed` when the private store refused the realisation.
// - `Damaged` (-5): the module of a realisation has bytes whose hash is not its output hash. Nothing is given.
//
// Example: `recipes.build_c("hello.c", source, 120, module)`.
@(export, link_name = "build_c")
build_c :: proc "c" (source_name: ^string, source: system.Lent({.Read}), source_size: i64, module: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if !c_builder.ready {
		return errors.fail(error, ERROR_BUILD, .Unsupported, .Modules)
	}
	if source_name == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	name_view := intrinsics.volatile_load(source_name)
	if refusal := pr.c_build_name_refusal(len(name_view)); refusal.kind != 0 {
		error^ = refusal
		return ERROR_RECIPE
	}
	intrinsics.mem_copy_non_overlapping(&copied_source_name[0], raw_data(name_view), len(name_view))
	name := string(copied_source_name[:len(name_view)])
	pages, size_status := system.memory_size(source.handle)
	if size_status != .Ok {
		pages = 0
	}
	if refusal := pr.c_build_source_refusal(source_size, pages * system.PAGE_SIZE); refusal.kind != 0 {
		error^ = refusal
		return ERROR_RECIPE
	}
	// One copy into a new memory object of this build: the caller can
	// change its memory object during the call, the recipe names the bytes
	// that the compiler reads, and the call host maps no memory of the
	// caller.
	work := C_Build_Work{}
	source_memory, source_status := system.memory_create((u64(source_size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	if source_status != .Ok {
		return errors.fail(error, ERROR_BUILD, .Refused, .None, pr.C_BUILD_ARGUMENT_SOURCE, 0, 0, i64(source_status))
	}
	defer system.close(source_memory)
	copy_address, copy_status := system.memory_map(source_memory, {.Write})
	if copy_status != .Ok {
		return errors.fail(error, ERROR_BUILD, .Refused, .None, pr.C_BUILD_ARGUMENT_SOURCE, 0, 0, i64(copy_status))
	}
	defer system.memory_unmap(copy_address)
	caller_address, caller_status := system.memory_map(source.handle, {})
	if caller_status != .Ok {
		return errors.fail(error, ERROR_RECIPE, .Refused, .None, pr.C_BUILD_ARGUMENT_SOURCE, 0, 0, i64(caller_status))
	}
	intrinsics.mem_copy_non_overlapping(copy_address, caller_address, int(source_size))
	system.memory_unmap(caller_address)
	work.source_memory = source_memory
	work.source = ([^]u8)(copy_address)[:source_size]
	if refusal := pr.c_build_recipe(c_builder.compiler_hash, c_builder.assembler_hash, name, blake3.hash(work.source), &export_spec); refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, 1)
	}
	export_result = recipes_core.build_recipe(&service_state, &export_spec, .Cache_First, {}, nil, c_builder_invoke, nil, nil, &work)
	if export_result.refusal != .None {
		if work.step != .None {
			error^ = work.error
			// The record of compile names its own argument 1, the source:
			// here that is the argument source. The text of the assembly
			// and the module are no argument of this export.
			switch work.step {
			case .Compile:
				error.argument = work.error.argument == 1 ? pr.C_BUILD_ARGUMENT_SOURCE : 0
			case .None, .Compiler_Start, .Assembler_Start, .Assemble, .Module_Refused:
				error.argument = 0
			}
			system.log_fact(.Warning, C_Build_Failed{step_code = u64(work.step), error_kind = u64(work.error.kind), error_value = work.error.value})
			return ERROR_BUILD
		}
		return recipe_refusal_fail(error, ERROR_BUILD, export_result.refusal, 1)
	}
	bytes, found := recipes_core.output_bytes(&service_state, export_result.output_hash)
	if !found {
		return recipe_refusal_fail(error, ERROR_BUILD, .Cache_Miss, 1)
	}
	// A realisation read back from the private store keeps its object under
	// the output hash of its record, with no new hash of the bytes: the
	// module goes out only with the bytes that the hash names.
	if refusal := pr.c_build_substitute_refusal(bytes, export_result.output_hash); refusal.kind != 0 {
		error^ = refusal
		return ERROR_BUILD
	}
	module_pages, module_size_status := system.memory_size(module.handle)
	if module_size_status != .Ok {
		module_pages = 0
	}
	if refusal := pr.c_build_module_room_refusal(len(bytes), module_pages * system.PAGE_SIZE); refusal.kind != 0 {
		error^ = refusal
		return ERROR_BUILD
	}
	module_address, module_status := system.memory_map(module.handle, {.Write})
	if module_status != .Ok {
		return errors.fail(error, ERROR_BUILD, .Refused, .None, pr.C_BUILD_ARGUMENT_MODULE, 0, 0, i64(module_status))
	}
	intrinsics.mem_copy_non_overlapping(module_address, raw_data(bytes), len(bytes))
	system.memory_unmap(module_address)
	switch export_result.outcome {
	case .From_Cache:
		system.log_fact(.Info, C_Substituted{size = value_kinds.Size_In_Bytes(len(bytes)), recipe_hash = value_kinds.Hash_Field(export_result.recipe_hash), output_hash = value_kinds.Hash_Field(export_result.output_hash)}, name)
	case .Built_Locally, .None, .Refused:
		system.log_fact(.Info, C_Built{size = value_kinds.Size_In_Bytes(len(bytes)), recipe_hash = value_kinds.Hash_Field(export_result.recipe_hash), output_hash = value_kinds.Hash_Field(export_result.output_hash)}, name)
	}
	return i64(len(bytes))
}
