// The exports of the recipes service (src/md/features/recipes.md, "The
// builder"; src/md/features/declarations.md, "The services of the
// declarations").
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:system"

// The failures of the exports of this file, each with its error record:
// - Grant_Or_Right_Missing: No_Grant, Connection (the call came through no
//   connection), or No_Grant, Acts_For_Principal (the caller does not act
//   for its principal).
// - Wrong_State: State, Requests: the service has not started its tables.
// - The outcome of a refusal of a recipe or of a build
//   (recipes_core.recipe_refusal_outcome): the value found is the
//   Recipe_Refusal.

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
caller_check :: proc "contextless" (acts: bool, error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome, ok: bool) {
	connection := system.service_caller()
	if connection == nil {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Connection)
		return failure, false
	}
	if acts && connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
		return failure, false
	}
	if !service_state.initialized {
		failure, _ = call_outcome.fail(error, .Wrong_State, .State, .Requests)
		return failure, false
	}
	return .Succeeded, true
}

// recipe_refusal_fail writes the error record of a refusal of the recipes
// contract, with the refusal as the value found.
@(private = "file")
recipe_refusal_fail :: proc "contextless" (error: ^errors.Error_Record, refusal: pr.Recipe_Refusal, argument: i64 = 0, bad_index: u32 = 0) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if error != nil {
		error^ = recipes_core.recipe_refusal_record(refusal, argument, bad_index)
	}
	return recipes_core.recipe_refusal_outcome(refusal), 0
}

// register keeps a recipe by its hash, so build and cache_lookup name it
// with 32 bytes.
//
// - **head**: the builder hash, the output kind, the date of the recipe and
//   the bound of its output in blocks.
// - **inputs**: one row for each input, a name and a hash, at most 256.
// - **arguments**: the bytes of the argument record, at most 64 KiB. A
//   table or bytes past the call region come in a memory object that the
//   caller lends.
// - **result**: one row: the recipe hash.
//
// The value is 1. A failure gives its outcome and its
// error record (the list above).
@(export, link_name = "register")
register :: proc "c" (head: ^pr.Recipe_Head, inputs: ^system.Table_To_Read(pr.Recipe_Input_Row), arguments: ^system.Bytes_To_Read, result: ^[]pr.Recipe_Reference, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if head == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	copied_head = intrinsics.volatile_load(head)
	input_count: u64 = 0
	if inputs != nil {
		input_count = intrinsics.volatile_load(&inputs.count)
	}
	if input_count > pr.MAX_RECIPE_INPUTS {
		return recipe_refusal_fail(error, .Too_Many_Inputs, 2)
	}
	for index in 0 ..< input_count {
		copied_inputs[index] = intrinsics.volatile_load(&inputs.records[index])
	}
	argument_count: u64 = 0
	if arguments != nil {
		argument_count = intrinsics.volatile_load(&arguments.count)
	}
	if argument_count > pr.MAX_RECIPE_ARG_BYTES {
		return recipe_refusal_fail(error, .Arguments_Too_Large, 3)
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
		return recipe_refusal_fail(error, refusal, argument, bad_index)
	}
	recipe_hash, register_refusal := recipes_core.register_recipe(&service_registry, &export_spec)
	if register_refusal != .None {
		return recipe_refusal_fail(error, register_refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = {recipe_hash = value_kinds.Hash_Field(recipe_hash)}
	}
	return .Succeeded, 1
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
// The value is 1. A failure gives its outcome and its error record (the
// list above), with the refusal as the value found: a bare hash, an input
// below the first level, a value that is no recipe, a damaged output, too
// many inputs, arguments too large.
@(export, link_name = "register_evaluation")
register_evaluation :: proc "c" (output: ^system.Bytes_To_Read, result: ^[]pr.Recipe_Reference, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if output == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	count := intrinsics.volatile_load(&output.count)
	if count > recipes_core.MAX_RECIPE_OUTPUT_BYTES {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, 0, recipes_core.MAX_RECIPE_OUTPUT_BYTES, i64(count))
	}
	// A private copy: the caller can change its memory during the call, and
	// the conversion reads the bytes more than once.
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_output[0], output.bytes, int(count))
	}
	recipe_hash, refusal := recipes_core.register_evaluation(&service_registry, copied_output[:count], &export_spec)
	if refusal != .None {
		return recipe_refusal_fail(error, refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = {recipe_hash = value_kinds.Hash_Field(recipe_hash)}
	}
	return .Succeeded, 1
}

// build realises a registered recipe, or a recipe that the private store
// keeps by its hash. A mode that takes the cache gives a realisation of the
// local store at once, with no build; on a miss the service builds the
// recipe, keeps its output and its realisation, and the next build of the
// recipe is a hit. The inputs tree builder builds in the call. A recipe of
// the guest builder starts its build on the build thread and answers
// Building: builds and cache_lookup give its end. A second guest build
// while one runs is refused with Builder_Busy.
//
// - **recipe**: the recipe hash that register gave.
// - **mode**: the Build_Mode word: 1 Cache_First, 2 Build_Only,
//   3 Cache_Only, 4 Verify.
// - **result**: one row: the outcome, the recipe hash and the output hash.
//
// The value is 1. A failure gives its outcome and its
// error record (the list above).
@(export, link_name = "build")
build :: proc "c" (recipe: ^pr.Recipe_Reference, mode: i64, result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if recipe == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if mode < 0 {
		return recipe_refusal_fail(error, .Bad_Build_Mode, 2)
	}
	checked_mode, mode_ok := pr.build_mode_of_word(u64(mode))
	if !mode_ok {
		return recipe_refusal_fail(error, .Bad_Build_Mode, 2)
	}
	copied_reference = intrinsics.volatile_load(recipe)
	return build_of_hash(blake3.Hash(copied_reference.recipe_hash), checked_mode, result, error)
}

// build_stored is build for a recipe named by its hash as text, the form in
// which the console types a hash: a record with a hash field has no
// command that makes it.
//
// - **recipe**: 64 lowercase hexadecimal digits, the recipe hash.
// - **mode**: the Build_Mode word, as for build.
// - **result**: one row, as for build.
//
// The result is 1, or a negative number with an error record, as for
// build; a text that is not 64 lowercase hexadecimal digits is refused with
// ERROR_BUILD and the refusal Unknown_Recipe.
@(export, link_name = "build_stored")
build_stored :: proc "c" (recipe: ^system.Bytes_To_Read, mode: i64, result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if recipe == nil {
		return errors.fail(error, ERROR_BUILD, .Bad_Address, .None, 1)
	}
	count := intrinsics.volatile_load(&recipe.count)
	if count != 2 * blake3.HASH_SIZE {
		return recipe_refusal_fail(error, ERROR_BUILD, .Unknown_Recipe, 1)
	}
	digits: [2 * blake3.HASH_SIZE]u8
	intrinsics.mem_copy_non_overlapping(&digits[0], recipe.bytes, len(digits))
	recipe_hash, hash_ok := pr.hash_of_hexadecimal(digits[:])
	if !hash_ok {
		return recipe_refusal_fail(error, ERROR_BUILD, .Unknown_Recipe, 1)
	}
	if mode < 0 {
		return recipe_refusal_fail(error, ERROR_BUILD, .Bad_Build_Mode, 2)
	}
	checked_mode, mode_ok := pr.build_mode_of_word(u64(mode))
	if !mode_ok {
		return recipe_refusal_fail(error, ERROR_BUILD, .Bad_Build_Mode, 2)
	}
	return build_of_hash(recipe_hash, checked_mode, result, error)
}

// build_cancel cancels a guest build that the principal of the caller
// queued, named by its recipe hash as text (src/md/features/recipes.md,
// "The queue of the guest builds"): a waiting build leaves the queue, and a
// running build ends at the next exit of its guest, refused with
// Build_Cancelled.
//
// - **recipe**: 64 lowercase hexadecimal digits, the recipe hash.
//
// The result is 1 when the build left the queue, 2 when the running build
// was asked to end, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or ERROR_BUILD
// with Unknown_Recipe: no build of this recipe of the principal of the
// caller waits or runs, or the text is not a hash. A build of another
// principal gets the same answer, so a caller learns nothing of it.
@(export, link_name = "build_cancel")
build_cancel :: proc "c" (recipe: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if recipe == nil {
		return errors.fail(error, ERROR_BUILD, .Bad_Address, .None, 1)
	}
	count := intrinsics.volatile_load(&recipe.count)
	if count != 2 * blake3.HASH_SIZE {
		return recipe_refusal_fail(error, ERROR_BUILD, .Unknown_Recipe, 1)
	}
	digits: [2 * blake3.HASH_SIZE]u8
	intrinsics.mem_copy_non_overlapping(&digits[0], recipe.bytes, len(digits))
	recipe_hash, hash_ok := pr.hash_of_hexadecimal(digits[:])
	if !hash_ok {
		return recipe_refusal_fail(error, ERROR_BUILD, .Unknown_Recipe, 1)
	}
	switch guest_build_cancel(caller_principal(), recipe_hash) {
	case .Removed:
		return 1
	case .Requested:
		return 2
	case .Absent:
		return recipe_refusal_fail(error, ERROR_BUILD, .Unknown_Recipe, 1)
	}
	return recipe_refusal_fail(error, ERROR_BUILD, .Unknown_Recipe, 1)
}

// caller_principal gives the number of the principal of the caller of the
// call that runs: the key of its quota of put and of its share of the
// queue. A connection that closes and opens again keeps it.
@(private = "file")
caller_principal :: proc "contextless" () -> u64 {
	connection := system.service_caller()
	if connection == nil {
		return recipes_core.GUEST_QUEUE_RING_PRINCIPAL
	}
	return isolated.caller_principal(connection.grant)
}

// build_of_hash builds the recipe of recipe_hash for build and build_stored.
@(private = "file")
build_of_hash :: proc "contextless" (recipe_hash: blake3.Hash, checked_mode: pr.Build_Mode, result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> i64 {
	// A recipe that a writer of the store kept there registers at its first
	// build (guest_build.odin).
	stored_recipe_register(recipe_hash)
	// A recipe of the guest builder builds on the build thread, so the
	// service answers each other call while its guest runs; the answer is
	// Building, and the history and the log give its end. Cache_Only never
	// builds, and answers here.
	if spec := recipes_core.registered_recipe(&service_registry, recipe_hash); spec != nil && spec.builder_hash == pr.guest_builder_hash() && checked_mode != .Cache_Only {
		if refusal := guest_build_queue({principal = caller_principal(), recipe_hash = recipe_hash, mode = checked_mode}); refusal != .None {
			return recipe_refusal_fail(error, ERROR_BUILD, refusal, 1)
		}
		export_result = {outcome = .Building, recipe_hash = recipe_hash}
		if len(result^) > 0 {
			result[0] = pr.recipe_build_row_of(&export_result, checked_mode)
		}
		return 1
	}
	export_result = recipes_core.build_registered(&service_state, &service_registry, recipe_hash, checked_mode, &builder_start)
	system.log_fact(.Info, Recipe_Build_Completed{outcome = u64(export_result.outcome), refusal_code = u64(export_result.refusal)})
	if export_result.refusal != .None {
		return recipe_refusal_fail(error, export_result.refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = pr.recipe_build_row_of(&export_result, checked_mode)
	}
	return .Succeeded, 1
}

// The bytes of the largest object that put takes in one call.
OBJECT_PUT_BYTES_MOST :: recipes_core.PUT_OBJECT_BYTES_MOST

// One object of the private store, as put gives it: its hash.
Object_Reference :: struct {
	hash: value_kinds.Hash_Field,
}

copied_object: [OBJECT_PUT_BYTES_MOST]u8

// put keeps an object in the private store by its hash, so a recipe names
// it as an input, or a guest build as its kernel or its initial archive. A
// caller keeps at most recipes_core.PUT_OBJECTS_PER_CALLER_MOST objects in
// one run of the service (Put_Quota_Reached past it); past the run, only
// what a recipe or a realisation names stays.
//
// - **kind**: the Cache_Object_Kind word: 1 a blob, 2 a tree, whose bytes
//   are a canonical MODTREE1 node.
// - **bytes**: the object, at most OBJECT_PUT_BYTES_MOST bytes.
// - **result**: one row: the hash of the object.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_RECIPE with the refusal as the value found.
@(export, link_name = "put")
put :: proc "c" (kind: i64, bytes: ^system.Bytes_To_Read, result: ^[]Object_Reference, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if bytes == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 2)
	}
	count := intrinsics.volatile_load(&bytes.count)
	if count > OBJECT_PUT_BYTES_MOST {
		return errors.fail(error, ERROR_RECIPE, .Too_Long, .Bytes, 2, i64(min(count, 1 << 62)), OBJECT_PUT_BYTES_MOST)
	}
	// A private copy: the hash and the write read the same bytes.
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_object[0], bytes.bytes, int(count))
	}
	hash, refusal := recipes_core.put_object(&service_state, &put_ledger, caller_principal(), system.time() / 1000, kind, copied_object[:count])
	if refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, refusal == .Bad_Input_Kind ? 1 : 2)
	}
	if len(result^) > 0 {
		result[0] = {hash = value_kinds.Hash_Field(hash)}
	}
	return 1
}

// cache_lookup gives the realisation of a recipe in the local store, with
// no build.
//
// - **recipe**: the recipe hash.
// - **result**: one row when the store holds a realisation of the recipe.
//
// The value is 1 when the store holds one, 0 when it holds none. A failure
// gives its outcome and its error record (the list above).
@(export, link_name = "cache_lookup")
cache_lookup :: proc "c" (recipe: ^pr.Recipe_Reference, result: ^[]pr.Realisation_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(false, error); !ok {
		return failure, 0
	}
	if recipe == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	copied_reference = intrinsics.volatile_load(recipe)
	slot, found := recipes_core.query_provenance(&service_state, blake3.Hash(copied_reference.recipe_hash))
	if !found {
		return .Succeeded, 0
	}
	if len(result^) > 0 {
		result[0] = pr.realisation_row_of(&slot.record, u64(slot.origin))
	}
	return .Succeeded, 1
}

// builds gives the newest builds, oldest first, at most 32.
//
// The value is the count of builds. A failure gives its outcome and its
// error record (the list above).
@(export, link_name = "builds")
builds :: proc "c" (result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(false, error); !ok {
		return failure, 0
	}
	return .Succeeded, i64(recipes_core.history_rows(&service_registry, result^))
}

// realisations gives each realisation of the local store.
//
// The value is the count of realisations. A failure gives its outcome and its
// error record (the list above).
@(export, link_name = "realisations")
realisations :: proc "c" (result: ^[]pr.Realisation_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(false, error); !ok {
		return failure, 0
	}
	return .Succeeded, i64(recipes_core.realisation_rows(&service_state, result^))
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
// - **source_size**: the bytes of the source, 1 to 64 MiB, the bound of compile.
// - **module**: a memory object that holds the module, at most 16 MiB, one object of a cache, which the caller lends
//   with Read and Write. The service makes the memory of the text and of the module of each build of the size that
//   the build needs, and reads the module from its store into this memory object.
//
// The log says whether the module was built or substituted, with the recipe hash and the hash of the module.
//
// The caller must act for its principal (**Acts_For_Principal**). The result is the bytes of the module, or a failure
// with its call outcome and an error record:
//
// - The refusals of the caller, as for build.
// - `Unsupported` (Operation_Unsupported): the service has no boot image, or the image has no module c_compiler or
//   assemble, or the module has no export compile or assemble.
// - `Empty` or `Too_Long` (Argument_Refused, argument 1): the name; `Bad_Value` (Argument_Refused): a name that no
//   tree takes.
// - `Out_Of_Range` (Argument_Refused, argument 3): a size of 0, past 64 MiB or past the memory object.
// - The outcome and the record of the step that refused its input: the record of compile, whose value is the byte of
//   the source that the diagnostic names (argument 2), or of assemble (argument 0). Nothing is kept.
// - Callee_Unavailable when the compiler or the assembler fails: `No_Answer` when it gives no answer before the hang
//   bound, which ends its call host; `Refused` for a call host that does not start, a count of bytes that the call
//   host gave and its memory object cannot hold, or a module that module.validate refuses. The log names the kind.
//   Nothing is kept.
// - `Too_Small` (Argument_Refused, argument 4): the memory object of the module holds fewer bytes than the module.
// - The refusal of the recipe, as for build: `Store_Failed` when the private store refused the realisation.
// - `Damaged` (Data_Damaged): the module of a realisation has bytes whose hash is not its output hash. Nothing is
//   given.
//
// Example: `recipes.build_c("hello.c", source, 120, module)`.
@(export, link_name = "build_c")
build_c :: proc "c" (source_name: ^string, source: system.Lent({.Read}), source_size: i64, module: system.Lent({.Read, .Write}), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if !c_builder.ready {
		return call_outcome.fail(error, .Operation_Unsupported, .Unsupported, .Modules)
	}
	if source_name == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	name_view := intrinsics.volatile_load(source_name)
	if refusal := pr.c_build_name_refusal(len(name_view)); refusal.kind != 0 {
		error^ = refusal
		return .Argument_Refused, 0
	}
	intrinsics.mem_copy_non_overlapping(&copied_source_name[0], raw_data(name_view), len(name_view))
	name := string(copied_source_name[:len(name_view)])
	pages, size_status := system.memory_size(source.handle)
	if size_status != .Ok {
		pages = 0
	}
	if refusal := pr.c_build_source_refusal(source_size, pages * system.PAGE_SIZE); refusal.kind != 0 {
		error^ = refusal
		return .Argument_Refused, 0
	}
	// One copy into a new memory object of this build: the caller can
	// change its memory object during the call, the recipe names the bytes
	// that the compiler reads, and the call host maps no memory of the
	// caller.
	work := C_Build_Work{}
	source_memory, source_status := system.memory_create((u64(source_size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	if source_status != .Ok {
		return call_outcome.fail(error, system.outcome_of_own_status(source_status), .Refused, .Kernel_Status, pr.C_BUILD_ARGUMENT_SOURCE, 0, 0, i64(source_status))
	}
	defer system.close(source_memory)
	copy_address, copy_status := system.memory_map(source_memory, {.Write})
	if copy_status != .Ok {
		return call_outcome.fail(error, system.outcome_of_own_status(copy_status), .Refused, .Kernel_Status, pr.C_BUILD_ARGUMENT_SOURCE, 0, 0, i64(copy_status))
	}
	defer system.memory_unmap(copy_address)
	caller_address, caller_status := system.memory_map(source.handle, {})
	if caller_status != .Ok {
		return call_outcome.fail(error, .Argument_Refused, .Refused, .Kernel_Status, pr.C_BUILD_ARGUMENT_SOURCE, 0, 0, i64(caller_status))
	}
	intrinsics.mem_copy_non_overlapping(copy_address, caller_address, int(source_size))
	system.memory_unmap(caller_address)
	work.source_memory = source_memory
	work.source = ([^]u8)(copy_address)[:source_size]
	if refusal := pr.c_build_recipe(c_builder.compiler_hash, c_builder.assembler_hash, name, blake3.hash(work.source), &export_spec); refusal != .None {
		return recipe_refusal_fail(error, refusal, 1)
	}
	export_result = recipes_core.build_recipe(&service_state, &export_spec, .Cache_First, {}, nil, c_builder_invoke, nil, nil, &work)
	// The store holds the module now, or the build failed: the memory of
	// the module of the build ends here.
	c_build_work_end(&work)
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
			// A kind that the outcome does not explain goes out as Refused;
			// the fact keeps the kind that the step gave.
			if kind, known := errors.kind_of_word(work.error.kind); !known || kind not_in call_outcome.KINDS_OF[work.outcome] {
				error.kind = i64(errors.Kind.Refused)
			}
			system.log_fact(.Warning, C_Build_Failed{step_code = u64(work.step), error_kind = u64(work.error.kind), error_value = work.error.value})
			return work.outcome, 0
		}
		return recipe_refusal_fail(error, export_result.refusal, 1)
	}
	length, found := recipes_core.output_length(&service_state, export_result.output_hash)
	if !found {
		return recipe_refusal_fail(error, .Cache_Miss, 1)
	}
	module_pages, module_size_status := system.memory_size(module.handle)
	if module_size_status != .Ok {
		module_pages = 0
	}
	if refusal := pr.c_build_module_room_refusal(int(length), module_pages * system.PAGE_SIZE); refusal.kind != 0 {
		error^ = refusal
		return .Argument_Refused, 0
	}
	module_address, module_status := system.memory_map(module.handle, {.Write})
	if module_status != .Ok {
		return call_outcome.fail(error, .Argument_Refused, .Refused, .Kernel_Status, pr.C_BUILD_ARGUMENT_MODULE, 0, 0, i64(module_status))
	}
	// The module goes from the store into the memory of the caller by
	// pieces, and out only with the bytes that its output hash names: a
	// caller that changes its memory during the read gets a refusal.
	bytes, read_refusal := recipes_core.output_read(&service_state, export_result.output_hash, ([^]u8)(module_address)[:length])
	system.memory_unmap(module_address)
	// The bytes of the store that are not the bytes of the output hash are
	// a damaged module, which goes out to no caller.
	if read_refusal == .Store_Damaged {
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Modules)
	}
	if read_refusal != .None {
		return recipe_refusal_fail(error, read_refusal, 1)
	}
	switch export_result.outcome {
	case .From_Cache:
		system.log_fact(.Info, C_Substituted{size = value_kinds.Size_In_Bytes(len(bytes)), recipe_hash = value_kinds.Hash_Field(export_result.recipe_hash), output_hash = value_kinds.Hash_Field(export_result.output_hash)}, name)
	case .Built_Locally, .None, .Refused, .Building:
		// A C build answers in its call: it is never Building.
		system.log_fact(.Info, C_Built{size = value_kinds.Size_In_Bytes(len(bytes)), recipe_hash = value_kinds.Hash_Field(export_result.recipe_hash), output_hash = value_kinds.Hash_Field(export_result.output_hash)}, name)
	}
	return .Succeeded, i64(len(bytes))
}
