package recipes_service

// The native C builder (src/md/features/program_loop.md, "The native C
// builder"): the module c_compiler of the boot image in a call host, then
// the module assemble in another one. recipes starts each builder in a call
// host with no grant (src/md/features/recipes.md, "The builder"): it holds
// its module and the memory objects of its one call, and nothing else. Its
// seed is the recipe hash.
//
// Each build makes new memory objects for its source, for the text of the
// assembly and for the module. A memory object of an earlier build would
// give the call host of one principal the assembly of another, and would
// let a call host that writes nothing pass the bytes of the earlier build
// as its output.

import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:system"

// The pages of the memory objects of one build, from the bounds of a C
// build (plans_recipes).
C_SOURCE_PAGES :: pr.C_SOURCE_BYTES_LIMIT / system.PAGE_SIZE
C_TEXT_PAGES :: pr.C_TEXT_BYTES_LIMIT / system.PAGE_SIZE
C_MODULE_PAGES :: pr.C_MODULE_BYTES_LIMIT / system.PAGE_SIZE
#assert(pr.C_MODULE_BYTES_LIMIT <= recipes_core.MAX_OBJECT_BYTES)

// The step of a C build that failed, which its error record names.
C_Build_Step :: enum u8 {
	None,
	Compiler_Start,
	Compile,
	Assembler_Start,
	Assemble,
	Module_Refused,
}

// The two modules of the builder, from the boot image.
C_Builder :: struct {
	ready:          bool,
	image:          []u8,
	image_memory:   system.Handle,
	compiler_file:  []u8,
	assembler_file: []u8,
	compiler_hash:  blake3.Hash,
	assembler_hash: blake3.Hash,
}

// One C build: the new memory object of its source, mapped while the build
// runs, and the failure of a step.
C_Build_Work :: struct {
	source_memory: system.Handle,
	source:        []u8,
	step:          C_Build_Step,
	outcome:       call_outcome.Call_Outcome, // The outcome that build_c gives for the failed step.
	error:         errors.Error_Record, // The record of the step, with the kind that the step gave: the log keeps it.
}

c_builder: C_Builder

// c_builder_bind keeps the boot image and the two modules of the builder.
// With no image or either module, build_c refuses each build.
c_builder_bind :: proc "contextless" (ctx: ^system.Context) {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	if image_handle == 0 {
		return
	}
	address, map_status := system.memory_map(image_handle, {})
	if map_status != .Ok {
		return
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	compiler := system.image_find(image, "c_compiler")
	assembler := system.image_find(image, "assemble")
	if len(compiler) == 0 || len(assembler) == 0 {
		system.memory_unmap(address)
		return
	}
	c_builder = {
		ready          = true,
		image          = image,
		image_memory   = image_handle,
		compiler_file  = compiler,
		assembler_file = assembler,
		compiler_hash  = blake3.hash(compiler),
		assembler_hash = blake3.hash(assembler),
	}
}

// c_builder_values gives the context values of a call host of the build:
// the recipe hash as its seed. A seed that everyone can compute claims no
// entropy, so its strength is Weak.
@(private = "file")
c_builder_values :: proc "contextless" (seed: blake3.Hash) -> (values: [op.CONTEXT_VALUES]u64) {
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		value: u64
		for byte in 0 ..< 8 {
			value |= u64(seed[index * 8 + byte]) << (8 * uint(byte))
		}
		values[op.CONTEXT_VALUE_SEED + index] = value
	}
	values[op.CONTEXT_VALUE_SEED_STRENGTH] = u64(op.Seed_Strength.Weak)
	return values
}

// c_build_fail writes the step, the outcome and the error record of a
// failed step. The build keeps nothing of a failed step, so no outcome is
// in doubt: a compiler or an assembler that fails, or that gives a result
// that this service does not take, is a party that the build needs, and
// gives Callee_Unavailable.
@(private = "file")
c_build_fail :: proc "contextless" (work: ^C_Build_Work, step: C_Build_Step, record: errors.Error_Record, outcome: call_outcome.Call_Outcome = .Callee_Unavailable) {
	work.step = step
	work.outcome = outcome
	work.error = record
}

// c_builder_call starts a call host of file, calls its export with the
// arguments, and ends the call host: chibicc takes one source for each
// call host. The result is the integer result of the export. The call has
// the hang bound of an answer: a source that makes the compiler or the
// assembler loop would else hold this service for each principal. At the
// bound, the end of the call host stops it.
@(private = "file")
c_builder_call :: proc "contextless" (work: ^C_Build_Work, file: []u8, name: string, export_name: string, arguments: []isolated.Argument, seed: blake3.Hash, start_step, call_step: C_Build_Step) -> (result: i64, ok: bool) {
	load_error: module.Load_Error
	connection, status := system.call_host_start(c_builder.image, c_builder.image_memory, file, name, c_builder_values(seed), &load_error)
	if status != .Ok {
		c_build_fail(work, start_step, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(status)))
		return 0, false
	}
	defer system.call_connection_end(&connection)
	export := module.export_find(file, export_name)
	if export == 0 {
		c_build_fail(work, call_step, errors.error_make(.Unsupported, .Modules), .Operation_Unsupported)
		return 0, false
	}
	call_error: errors.Error_Record
	called, outcome := system.call_isolated(&connection, file, export, arguments, &call_error, keep_memory_objects = true, deadline = system.answer_deadline(system.time()))
	switch {
	case outcome == .Succeeded:
		return called, true
	case outcome == .Deadline_Passed_During_The_Call:
		// The end of the call host stops it: nothing of the step stays.
		c_build_fail(work, call_step, errors.error_make(.No_Answer, .Milliseconds, 0, 0, system.ANSWER_BOUND_MILLISECONDS))
	case system.connection_to_renew(outcome):
		c_build_fail(work, call_step, call_error)
	case:
		// The step refused its input, and the build keeps nothing.
		c_build_fail(work, call_step, call_error, call_outcome.outcome_passed_on(outcome, false))
	}
	return 0, false
}

// c_builder_invoke is the builder of build_recipe: the source to the text
// of the assembly, then the text to the module file, which it copies into
// out_payload after the check of the module. A failed step writes its step
// and its error record in the work, and gives ok false: no realisation is
// kept.
c_builder_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, out_payload: []u8, user_data: rawptr) -> (payload_length: int, ok: bool) {
	work := (^C_Build_Work)(user_data)
	text_memory, text_status := system.memory_create(C_TEXT_PAGES)
	if text_status != .Ok {
		c_build_fail(work, .Compile, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(text_status)), system.outcome_of_own_status(text_status))
		return 0, false
	}
	defer system.close(text_memory)
	// The source goes through its memory object, which the call host maps
	// with Read only; the text memory with the rights of the description.
	compile_arguments := [2]isolated.Argument{{table = {records = work.source, count = u64(len(work.source)), memory_handle = u64(work.source_memory)}}, {integer = u64(text_memory)}}
	text_size := c_builder_call(work, c_builder.compiler_file, "c_compiler", "compile", compile_arguments[:], sandbox.random_seed, .Compiler_Start, .Compile) or_return
	if refusal := pr.c_build_written_refusal(text_size, pr.C_TEXT_BYTES_LIMIT); refusal.kind != 0 {
		c_build_fail(work, .Compile, refusal)
		return 0, false
	}
	text_address, text_map_status := system.memory_map(text_memory, {})
	if text_map_status != .Ok {
		c_build_fail(work, .Compile, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(text_map_status)), system.outcome_of_own_status(text_map_status))
		return 0, false
	}
	defer system.memory_unmap(text_address)
	text := ([^]u8)(text_address)[:text_size]
	module_memory, module_status := system.memory_create(C_MODULE_PAGES)
	if module_status != .Ok {
		c_build_fail(work, .Assemble, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(module_status)), system.outcome_of_own_status(module_status))
		return 0, false
	}
	defer system.close(module_memory)
	assemble_arguments := [2]isolated.Argument{{table = {records = text, count = u64(len(text)), memory_handle = u64(text_memory)}}, {integer = u64(module_memory)}}
	module_size := c_builder_call(work, c_builder.assembler_file, "assemble", "assemble", assemble_arguments[:], sandbox.random_seed, .Assembler_Start, .Assemble) or_return
	if refusal := pr.c_build_written_refusal(module_size, i64(min(len(out_payload), pr.C_MODULE_BYTES_LIMIT))); refusal.kind != 0 {
		c_build_fail(work, .Assemble, refusal)
		return 0, false
	}
	module_address, module_map_status := system.memory_map(module_memory, {})
	if module_map_status != .Ok {
		c_build_fail(work, .Assemble, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(module_map_status)), system.outcome_of_own_status(module_map_status))
		return 0, false
	}
	copy(out_payload, ([^]u8)(module_address)[:module_size])
	system.memory_unmap(module_address)
	if refusal := pr.c_build_module_refusal(out_payload[:module_size]); refusal.kind != 0 {
		c_build_fail(work, .Module_Refused, refusal)
		return 0, false
	}
	return int(module_size), true
}
