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

// The first memory object of the text of the assembly: about 8 bytes of
// text for each byte of C, 1 MiB at least; and of the module: a quarter of
// the text, as an instruction of about 5 bytes takes about 20 bytes of
// text, and 64 KiB more for the data and the tables. A build that writes
// more gives the bytes that it needs in its Too_Small error record, and the
// service makes a memory object of that size and calls it again, once.
C_TEXT_BYTES_FOR_EACH_SOURCE_BYTE :: 8
C_TEXT_FIRST_BYTES_LEAST :: 1024 * 1024
C_MODULE_FIRST_BYTES_MORE :: 64 * 1024
#assert(pr.C_MODULE_BYTES_LIMIT <= recipes_core.OUTPUT_BYTES_MOST)

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
// runs, the memory object of its module, mapped until build_recipe returns
// (the output of the builder is a view of it), and the failure of a step.
// The caller ends the module with c_build_work_end.
C_Build_Work :: struct {
	source_memory:  system.Handle,
	source:         []u8,
	module_memory:  system.Handle,
	module_address: rawptr,
	step:           C_Build_Step,
	outcome:        call_outcome.Call_Outcome, // The outcome that build_c gives for the failed step.
	error:          errors.Error_Record, // The record of the step, with the kind that the step gave: the log keeps it.
}

// c_build_work_end unmaps and closes the memory of the module of a build.
c_build_work_end :: proc "contextless" (work: ^C_Build_Work) {
	if work.module_address != nil {
		system.memory_unmap(work.module_address)
		work.module_address = nil
	}
	if work.module_memory != 0 {
		system.close(work.module_memory)
		work.module_memory = 0
	}
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

// The pages of the budget of this service that it keeps while a call host
// of a build runs: its tables, its stack and its connections.
C_BUILD_SERVICE_PAGES_KEPT :: 1024

// The memory of a build for each byte of its source: the tokens and the
// tree of chibicc take about 40 bytes for each byte of C, and the text of
// the assembly about 8. A build plans its memory from it and from what the
// grant of this service holds at the call (c_build_plan).
C_BUILD_BYTES_FOR_EACH_SOURCE_BYTE :: 48

// c_build_plan gives the pages that a build of a source of source_bytes
// needs, and if the pages that the budget holds now pay them with the
// pages that the service keeps.
c_build_plan :: proc "contextless" (budget_pages: u64, source_bytes: u64) -> (needed: u64, fits: bool) {
	needed = (source_bytes * C_BUILD_BYTES_FOR_EACH_SOURCE_BYTE + system.PAGE_SIZE - 1) / system.PAGE_SIZE + system.CALL_HOST_PAGES
	return needed, budget_pages >= C_BUILD_SERVICE_PAGES_KEPT && budget_pages - C_BUILD_SERVICE_PAGES_KEPT >= needed
}

// c_builder_host_pages gives the pages of the budget of a call host of a
// build: what the budget of this service still holds, after the memory
// objects of the build, less the pages that it keeps. The compiler and the
// assembler size their arenas from it, so a build of a large program takes
// what the budget pays, and one that passes it fails with the error record
// of the budget.
@(private)
c_builder_host_pages :: proc "contextless" () -> u64 {
	amounts, status := system.budget_read()
	if status != .Ok || amounts.pages <= C_BUILD_SERVICE_PAGES_KEPT + system.CALL_HOST_PAGES {
		return system.CALL_HOST_PAGES
	}
	return amounts.pages - C_BUILD_SERVICE_PAGES_KEPT
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
	added := system.Call_Host_Context{pages = c_builder_host_pages()}
	connection, status := system.call_host_start(c_builder.image, c_builder.image_memory, file, name, c_builder_values(seed), &load_error, added = &added)
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

// c_builder_call_sized calls an export that writes into a new memory
// object of first_bytes, its argument output: when the export answers
// Too_Small with the bytes that it needs, at most most_bytes, the service
// makes a memory object of that size and calls again, once. The memory
// object is paid by the budget of this service: the call host that writes
// it ends before the service reads it. On ok, the caller closes memory.
@(private = "file")
c_builder_call_sized :: proc "contextless" (work: ^C_Build_Work, file: []u8, name: string, export_name: string, arguments: []isolated.Argument, output: int, first_bytes, most_bytes: u64, seed: blake3.Hash, start_step, call_step: C_Build_Step) -> (result: i64, memory: system.Handle, ok: bool) {
	bytes := min(first_bytes, most_bytes)
	for attempt in 0 ..< 2 {
		pages := max((bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE, 1)
		status: system.Status
		if memory, status = system.memory_create(pages); status != .Ok {
			c_build_fail(work, call_step, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(status)), system.outcome_of_own_status(status))
			return 0, 0, false
		}
		arguments[output].integer = u64(memory)
		if result, ok = c_builder_call(work, file, name, export_name, arguments, seed, start_step, call_step); ok {
			return result, memory, true
		}
		system.close(memory)
		needed := work.error.limit
		if attempt == 1 || work.error.kind != i64(errors.Kind.Too_Small) || needed <= 0 || u64(needed) <= pages * system.PAGE_SIZE || u64(needed) > most_bytes {
			return 0, 0, false
		}
		work.step, work.outcome, work.error = .None, .Succeeded, {}
		bytes = u64(needed)
	}
	return 0, 0, false
}

// c_builder_invoke is the builder of build_recipe: the source to the text
// of the assembly, then the text to the module file, each in a memory
// object of the size that the build needs. The output is a view of the
// memory of the module, after the check of the module: it stays mapped
// until the caller ends the work. A failed step writes its step and its
// error record in the work, and gives ok false: no realisation is kept.
c_builder_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, staging: []u8, user_data: rawptr) -> (payload: []u8, ok: bool) {
	work := (^C_Build_Work)(user_data)
	// The memory of the build comes from what the grant holds now: a build
	// that it cannot pay is refused before any call host starts, with the
	// pages that it needs and the pages that are left.
	own, budget_status := system.budget_read()
	if budget_status != .Ok {
		c_build_fail(work, .Compiler_Start, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(budget_status)), system.outcome_of_own_status(budget_status))
		return nil, false
	}
	if needed, fits := c_build_plan(own.pages, u64(len(work.source))); !fits {
		left := own.pages > C_BUILD_SERVICE_PAGES_KEPT ? own.pages - C_BUILD_SERVICE_PAGES_KEPT : 0
		c_build_fail(work, .Compiler_Start, errors.error_make(.Budget, .Pages, 0, 0, i64(needed), i64(left)), .Budget_Or_Capacity_Exhausted)
		return nil, false
	}
	// The source goes through its memory object, which the call host maps
	// with Read only; the text memory with the rights of the description.
	compile_arguments := [2]isolated.Argument{{table = {records = work.source, count = u64(len(work.source)), memory_handle = u64(work.source_memory)}}, {}}
	text_first := max(u64(len(work.source)) * C_TEXT_BYTES_FOR_EACH_SOURCE_BYTE, C_TEXT_FIRST_BYTES_LEAST)
	text_size, text_memory, compiled := c_builder_call_sized(work, c_builder.compiler_file, "c_compiler", "compile", compile_arguments[:], 1, text_first, pr.C_TEXT_BYTES_LIMIT, sandbox.random_seed, .Compiler_Start, .Compile)
	if !compiled {
		return nil, false
	}
	defer system.close(text_memory)
	text_pages, _ := system.memory_size(text_memory)
	if refusal := pr.c_build_written_refusal(text_size, i64(min(text_pages * system.PAGE_SIZE, pr.C_TEXT_BYTES_LIMIT))); refusal.kind != 0 {
		c_build_fail(work, .Compile, refusal)
		return nil, false
	}
	text_address, text_map_status := system.memory_map(text_memory, {})
	if text_map_status != .Ok {
		c_build_fail(work, .Compile, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(text_map_status)), system.outcome_of_own_status(text_map_status))
		return nil, false
	}
	defer system.memory_unmap(text_address)
	text := ([^]u8)(text_address)[:text_size]
	assemble_arguments := [2]isolated.Argument{{table = {records = text, count = u64(len(text)), memory_handle = u64(text_memory)}}, {}}
	module_first := u64(text_size) / 4 + C_MODULE_FIRST_BYTES_MORE
	module_size, module_memory, assembled := c_builder_call_sized(work, c_builder.assembler_file, "assemble", "assemble", assemble_arguments[:], 1, module_first, pr.C_MODULE_BYTES_LIMIT, sandbox.random_seed, .Assembler_Start, .Assemble)
	if !assembled {
		return nil, false
	}
	work.module_memory = module_memory
	module_pages, _ := system.memory_size(module_memory)
	if refusal := pr.c_build_written_refusal(module_size, i64(min(module_pages * system.PAGE_SIZE, pr.C_MODULE_BYTES_LIMIT))); refusal.kind != 0 {
		c_build_fail(work, .Assemble, refusal)
		return nil, false
	}
	module_address, module_map_status := system.memory_map(module_memory, {})
	if module_map_status != .Ok {
		c_build_fail(work, .Assemble, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(module_map_status)), system.outcome_of_own_status(module_map_status))
		return nil, false
	}
	work.module_address = module_address
	module := ([^]u8)(module_address)[:module_size]
	if refusal := pr.c_build_module_refusal(module); refusal.kind != 0 {
		c_build_fail(work, .Module_Refused, refusal)
		return nil, false
	}
	return module, true
}
