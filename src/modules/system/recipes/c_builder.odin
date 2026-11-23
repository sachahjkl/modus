package recipes_service

// The native C builder (src/md/features/program_loop.md, "The native C
// builder"): the module c_compiler of the boot image in a call host, then
// the module assemble in another one. Each call host holds its module and
// the memory that this service lends for its one call, and nothing else:
// no store, no network, no root ring. Its seed is the recipe hash.

import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/call_status"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:system"

// The pages of the text of the assembly and of the module file: the bound
// of the output of a C build, the bound of an object of the local store.
C_BUILD_PAGES :: recipes_core.MAX_OBJECT_BYTES / system.PAGE_SIZE

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
	ready:           bool,
	image:           []u8,
	image_memory:    system.Handle,
	compiler_file:   []u8,
	assembler_file:  []u8,
	compiler_hash:   blake3.Hash,
	assembler_hash:  blake3.Hash,
	text_memory:     system.Handle,
	module_memory:   system.Handle,
}

// One C build: the source that the caller gave, and the failure of a step.
C_Build_Work :: struct {
	source: []u8,
	step:   C_Build_Step,
	error:  errors.Error_Record,
}

c_builder: C_Builder

// c_builder_bind keeps the boot image and the two modules of the builder,
// and makes the memory of the text and of the module. With no image or
// either module, build_c refuses each build.
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
		return
	}
	text_memory, text_status := system.memory_create(C_BUILD_PAGES)
	module_memory, module_status := system.memory_create(C_BUILD_PAGES)
	if text_status != .Ok || module_status != .Ok {
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
		text_memory    = text_memory,
		module_memory  = module_memory,
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

// c_builder_call starts a call host of file, calls its export with the
// arguments, and ends the call host: chibicc takes one source for each
// call host. The result is the integer result of the export.
@(private = "file")
c_builder_call :: proc "contextless" (work: ^C_Build_Work, file: []u8, name: string, export_name: string, arguments: []isolated.Argument, seed: blake3.Hash, start_step, call_step: C_Build_Step) -> (result: i64, ok: bool) {
	load_error: module.Load_Error
	connection, status := system.call_host_start(c_builder.image, c_builder.image_memory, file, name, c_builder_values(seed), &load_error)
	if status != .Ok {
		work.step = start_step
		work.error = errors.error_make(.Refused, .None, 0, 0, 0, i64(status))
		return 0, false
	}
	defer system.call_connection_end(&connection)
	export := module.export_find(file, export_name)
	if export == 0 {
		work.step = call_step
		work.error = errors.error_make(.Absent, .None)
		return 0, false
	}
	call_error: errors.Error_Record
	called, call_result := system.call_isolated(&connection, file, export, arguments, &call_error)
	if call_result != call_status.Call_Status.Ok || called < 0 {
		work.step = call_step
		work.error = call_error
		if call_error.kind == 0 {
			work.error = errors.error_make(.Refused, .None, 0, 0, 0, i64(call_result))
		}
		return 0, false
	}
	return called, true
}

// c_builder_invoke is the builder of build_recipe: the source to the text
// of the assembly, then the text to the module file, which it copies into
// out_payload after module.validate. A failed step writes its step and its
// error record in the work, and gives ok false: no realisation is kept.
c_builder_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, out_payload: []u8, user_data: rawptr) -> (payload_length: int, ok: bool) {
	work := (^C_Build_Work)(user_data)
	compile_arguments := [2]isolated.Argument{{table = {records = work.source, count = u64(len(work.source))}}, {integer = u64(c_builder.text_memory)}}
	text_size := c_builder_call(work, c_builder.compiler_file, "c_compiler", "compile", compile_arguments[:], sandbox.random_seed, .Compiler_Start, .Compile) or_return
	text_address, text_status := system.memory_map(c_builder.text_memory, {})
	if text_status != .Ok || text_size > recipes_core.MAX_OBJECT_BYTES {
		work.step = .Compile
		work.error = errors.error_make(.Full, .Bytes, 2, text_size, recipes_core.MAX_OBJECT_BYTES)
		return 0, false
	}
	text := ([^]u8)(text_address)[:text_size]
	assemble_arguments := [2]isolated.Argument{{table = {records = text, count = u64(len(text))}}, {integer = u64(c_builder.module_memory)}}
	module_size, assembled := c_builder_call(work, c_builder.assembler_file, "assemble", "assemble", assemble_arguments[:], sandbox.random_seed, .Assembler_Start, .Assemble)
	system.memory_unmap(text_address)
	if !assembled {
		return 0, false
	}
	if module_size > i64(len(out_payload)) {
		work.step = .Assemble
		work.error = errors.error_make(.Full, .Bytes, 2, module_size, i64(len(out_payload)))
		return 0, false
	}
	module_address, module_status := system.memory_map(c_builder.module_memory, {})
	if module_status != .Ok {
		work.step = .Assemble
		work.error = errors.error_make(.Refused, .None, 0, 0, 0, i64(module_status))
		return 0, false
	}
	copy(out_payload, ([^]u8)(module_address)[:module_size])
	system.memory_unmap(module_address)
	if refusal := module.validate(out_payload[:module_size]); refusal != .None {
		work.step = .Module_Refused
		work.error = errors.error_make(.Malformed, .None, 0, 0, 0, i64(refusal))
		return 0, false
	}
	return int(module_size), true
}
