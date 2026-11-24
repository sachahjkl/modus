// Sandboxed C builder module implementing the modus:contract/builder contract
// (src/md/features/application_projects.md, "The catalog of the system";
// src/md/features/recipes.md, "The builder").
//
// Runs inside a zero-grant call host started by recipes with read-only input
// store and empty writable output store. Reads the typed inputs ("source" Tree,
// "compiler" Blob, "assembler" Blob, "host" Blob) and the canonical argument
// record ("path"), verifies every content hash, compiles the C source via
// c_compiler and assembles the text via assemble in zero-grant child call
// hosts, validates the resulting module, and writes it to the output store
// under "module".
package c_builder

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modus:contract/value_kinds"
import "modus:storage"
import "modus:system"

// Format property: piece size fitting inside a storage call region.
STORE_PIECE_BYTES :: 32 * 1024

// Plan value: commit interval for writing large modules to the output store.
COMMIT_STEP_BYTES :: 1024 * 1024

// Plan value: initial sizing estimates matching recipes/c_builder.odin.
C_TEXT_BYTES_FOR_EACH_SOURCE_BYTE :: 8
C_TEXT_FIRST_BYTES_LEAST :: 1024 * 1024
C_MODULE_FIRST_BYTES_MORE :: 64 * 1024

// Computed/Plan value: pages kept by c_builder while a child call host runs.
BUILDER_PAGES_KEPT :: 512

// BSS scratch for reading canonical tree nodes and arguments without using the stack.
tree_buffer: [tree_hash.MAX_ENCODED_TREE_BYTES]u8
copied_arguments: [pr.MAX_RECIPE_ARG_BYTES]u8
child_load_error: module.Load_Error

@(private = "file")
HEX_DIGITS :: "0123456789abcdef"

@(private = "file")
hash_hex :: proc "contextless" (hash: blake3.Hash) -> (text: [64]u8) {
	digits := HEX_DIGITS
	for byte_value, index in hash {
		text[2 * index] = digits[byte_value >> 4]
		text[2 * index + 1] = digits[byte_value & 0x0f]
	}
	return text
}

@(private = "file")
child_seed_values :: proc "contextless" (ctx: ^system.Context) -> (values: [op.CONTEXT_VALUES]u64) {
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		values[op.CONTEXT_VALUE_SEED + index] = ctx.values[op.CONTEXT_VALUE_SEED + index]
	}
	// Preserve Seed_Strength.None: the recipe hash seed is public and deterministic.
	values[op.CONTEXT_VALUE_SEED_STRENGTH] = u64(op.Seed_Strength.None)
	return values
}

@(private = "file")
log_builder_failure :: proc "contextless" (step: u64, error: ^errors.Error_Record) {
	kind := error != nil ? error.kind : 0
	value := error != nil ? error.value : 0
	system.log_fact(.Warning, C_Builder_Failed{step = step, error_kind = kind, error_value = value})
}

@(private = "file")
child_host_pages :: proc "contextless" () -> u64 {
	amounts, status := system.budget_read()
	if status != .Succeeded || amounts.pages <= BUILDER_PAGES_KEPT + system.CALL_HOST_PAGES {
		return system.CALL_HOST_PAGES
	}
	return amounts.pages - BUILDER_PAGES_KEPT
}

@(private = "file")
fail_outcome :: proc "contextless" (
	error: ^errors.Error_Record,
	outcome: call_outcome.Call_Outcome,
	kind: errors.Kind,
	unit: errors.Unit = .None,
	argument: i64 = 0,
	value: i64 = 0,
	limit: i64 = 0,
	found: i64 = 0,
) -> call_outcome.Call_Outcome {
	res, _ := call_outcome.fail(error, outcome, kind, unit, argument, value, limit, found)
	return res
}

// resolve_source_in_tree walks relative path segments through verified MODTREE2
// nodes in input_store and returns the BLAKE3 hash of the target C source file.
@(private = "file")
resolve_source_in_tree :: proc "contextless" (
	input_store: ^storage.Client,
	root_tree_hash: blake3.Hash,
	path: string,
	error: ^errors.Error_Record,
) -> (file_hash: blake3.Hash, outcome: call_outcome.Call_Outcome) {
	current_tree := root_tree_hash
	rest := path
	for {
		segment, next, seg_ok := path_segment_next(rest)
		if !seg_ok {
			return {}, fail_outcome(error, .Argument_Refused, .Bad_Value, .None, 2)
		}
		name := hash_hex(current_tree)
		args := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name[:]}}
		tree_size, text, status, _ := storage.call(input_store, "tree_read", args[:], error)
		if status != .Ok || tree_size < 0 || len(text) > len(tree_buffer) {
			if error == nil || error.kind == 0 {
				return {}, fail_outcome(error, .Callee_Unavailable, .Refused, .Store, 1, 0, 0, i64(status))
			}
			return {}, .Callee_Unavailable
		}
		copy(tree_buffer[:], text)
		tree_bytes := tree_buffer[:len(text)]
		computed_tree, hash_refusal := tree_hash.tree_hash(tree_bytes)
		if hash_refusal != .None || computed_tree != current_tree {
			return {}, fail_outcome(error, .Data_Damaged, .Damaged, .Objects, 1)
		}
		entry, found, lookup_refusal := tree_hash.tree_lookup(tree_bytes, segment)
		if lookup_refusal != .None || !found {
			return {}, fail_outcome(error, .Nothing_Has_That_Name, .Absent, .Objects, 2)
		}
		if len(next) == 0 {
			if entry.kind != .Object {
				return {}, fail_outcome(error, .Argument_Refused, .Bad_Value, .Objects, 2)
			}
			return entry.hash, .Succeeded
		}
		if entry.kind != .Tree {
			return {}, fail_outcome(error, .Nothing_Has_That_Name, .Absent, .Objects, 2)
		}
		current_tree = entry.hash
		rest = next
	}
}

// read_blob_to_memory reads a content-addressed blob from input_store into a
// new page-aligned memory object, verifies its BLAKE3 hash, and returns the
// handle and mapped slice. Caller unmaps and closes on ok.
@(private = "file")
read_blob_to_memory :: proc "contextless" (
	input_store: ^storage.Client,
	expected_hash: blake3.Hash,
	max_bytes: u64,
	error: ^errors.Error_Record,
) -> (handle: system.Handle, addr: rawptr, bytes: []u8, outcome: call_outcome.Call_Outcome) {
	hex_name := hash_hex(expected_hash)
	name := string(hex_name[:])
	size, size_status := storage.size(input_store, storage.ROOT, name, error)
	if size_status == .Absent {
		return 0, nil, nil, fail_outcome(error, .Nothing_Has_That_Name, .Absent, .Objects, 1)
	}
	if size_status != .Ok || size <= 0 || u64(size) > max_bytes {
		return 0, nil, nil, fail_outcome(error, .Data_Damaged, .Out_Of_Range, .Bytes, 1, size, i64(max_bytes))
	}
	pages := (u64(size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	mem_handle, create_status := system.memory_create(pages)
	if create_status != .Succeeded {
		return 0, nil, nil, fail_outcome(error, system.own_operation_outcome(create_status), .Refused, .Kernel_Status, 1, 0, 0, i64(create_status))
	}
	mapped, map_status := system.memory_map(mem_handle, {.Write})
	if map_status != .Succeeded {
		system.close(mem_handle)
		return 0, nil, nil, fail_outcome(error, system.own_operation_outcome(map_status), .Refused, .Kernel_Status, 1, 0, 0, i64(map_status))
	}
	dst := ([^]u8)(mapped)[:size]
	read_total := u64(0)
	for read_total < u64(size) {
		end := min(read_total + STORE_PIECE_BYTES, u64(size))
		chunk, read_status := storage.read_range(input_store, storage.ROOT, name, read_total, dst[read_total:end], error)
		if read_status != .Ok || len(chunk) == 0 || u64(len(chunk)) > u64(size) - read_total {
			system.memory_unmap(mapped)
			system.close(mem_handle)
			if error == nil || error.kind == 0 {
				return 0, nil, nil, fail_outcome(error, .Callee_Unavailable, .Refused, .Store, 1, 0, 0, i64(read_status))
			}
			return 0, nil, nil, .Callee_Unavailable
		}
		read_total += u64(len(chunk))
	}
	if blake3.hash(dst) != expected_hash {
		system.memory_unmap(mapped)
		system.close(mem_handle)
		return 0, nil, nil, fail_outcome(error, .Data_Damaged, .Damaged, .Objects, 1)
	}
	return mem_handle, mapped, dst, .Succeeded
}

// write_output_blob writes data into output_store under name, chunking large
// modules into STORE_PIECE_BYTES write_range calls with periodic commits.
@(private = "file")
write_output_blob :: proc "contextless" (
	output_store: ^storage.Client,
	name: string,
	data: []u8,
	error: ^errors.Error_Record,
) -> bool {
	if len(data) <= STORE_PIECE_BYTES {
		gen, status := storage.write(output_store, storage.ROOT, name, data, error)
		return status == .Ok && gen >= 0
	}
	committed := 0
	for written := 0; written < len(data); {
		part := data[written:min(written + STORE_PIECE_BYTES, len(data))]
		if _, status := storage.write_range(output_store, storage.ROOT, name, u64(written), part, error); status != .Ok {
			_ = storage.drop_pending(output_store, storage.ROOT, name, error)
			return false
		}
		written += len(part)
		if written - committed >= COMMIT_STEP_BYTES {
			if _, status := storage.commit(output_store, storage.ROOT, name, error); status != .Ok {
				_ = storage.drop_pending(output_store, storage.ROOT, name, error)
				return false
			}
			committed = written
		}
	}
	if storage.set_size(output_store, storage.ROOT, name, u64(len(data)), error) != .Ok {
		_ = storage.drop_pending(output_store, storage.ROOT, name, error)
		return false
	}
	_, status := storage.commit(output_store, storage.ROOT, name, error)
	if status != .Ok {
		_ = storage.drop_pending(output_store, storage.ROOT, name, error)
		return false
	}
	return true
}

// call_child_sized runs one export of module_file in a fresh zero-grant child
// call host, auto-retrying once if the export returns Too_Small with its needed
// byte count up to most_bytes.
@(private = "file")
call_child_sized :: proc "contextless" (
	host_file: []u8,
	module_memory: system.Handle,
	module_file: []u8,
	name: string,
	export_name: string,
	arguments: []isolated.Argument,
	output_index: int,
	first_bytes: u64,
	most_bytes: u64,
	seed_values: [op.CONTEXT_VALUES]u64,
	error: ^errors.Error_Record,
) -> (result: i64, memory: system.Handle, outcome: call_outcome.Call_Outcome) {
	export := module.export_find(module_file, export_name)
	if export == 0 {
		return 0, 0, fail_outcome(error, .Operation_Unsupported, .Unsupported, .Modules)
	}
	bytes := min(first_bytes, most_bytes)
	for attempt in 0 ..< 2 {
		pages := max((bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE, 1)
		mem_handle, create_status := system.memory_create(pages)
		if create_status != .Succeeded {
			return 0, 0, fail_outcome(error, system.own_operation_outcome(create_status), .Refused, .Kernel_Status, 0, 0, 0, i64(create_status))
		}
		arguments[output_index].integer = u64(mem_handle)
		added := system.Call_Host_Context{pages = child_host_pages(), processes = 1}
		conn, start_status := system.call_host_start_from_memory(host_file, module_memory, module_file, name, seed_values, &child_load_error, added = &added)
		if start_status != .Succeeded {
			system.close(mem_handle)
			return 0, 0, fail_outcome(error, .Callee_Unavailable, .Refused, .Kernel_Status, 0, 0, 0, i64(start_status))
		}
		call_err: errors.Error_Record
		called, call_out := system.call_isolated(&conn, module_file, export, arguments, &call_err, keep_memory_objects = true, deadline = system.answer_deadline(system.time()))
		system.call_connection_end(&conn)
		if call_out == .Succeeded {
			return called, mem_handle, .Succeeded
		}
		system.close(mem_handle)
		needed := call_err.limit
		if attempt == 0 && call_err.kind == i64(errors.Kind.Too_Small) && needed > 0 && u64(needed) > pages * system.PAGE_SIZE && u64(needed) <= most_bytes {
			bytes = u64(needed)
			continue
		}
		if error != nil {
			error^ = call_err
		}
		return 0, 0, call_out
	}
	return 0, 0, fail_outcome(error, .Callee_Unavailable, .Refused, .Modules)
}

// build is the export of the modus:contract/builder contract.
@(export, link_name = "build")
build :: proc "c" (inputs: ^system.Table_To_Read(pr.Recipe_Input_Row), arguments: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if inputs == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if arguments == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	arg_count := intrinsics.volatile_load(&arguments.count)
	if arg_count > pr.MAX_RECIPE_ARG_BYTES {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(min(arg_count, 1 << 62)), pr.MAX_RECIPE_ARG_BYTES)
	}
	if arg_count > 0 && arguments.bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	if arg_count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_arguments[0], arguments.bytes, int(arg_count))
	}
	path, has_path := argument_path(copied_arguments[:arg_count])
	if !has_path {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2)
	}

	rows := system.table_records(inputs)
	source_tree_hash, has_source := input_row_find(rows, "source", .Tree)
	compiler_hash, has_compiler := input_row_find(rows, "compiler", .Blob)
	assembler_hash, has_assembler := input_row_find(rows, "assembler", .Blob)
	host_hash, has_host := input_row_find(rows, "host", .Blob)
	if !has_source || !has_compiler || !has_assembler || !has_host {
		return call_outcome.fail(error, .Argument_Refused, .Absent, .Objects, 1)
	}

	ctx := system.context_record()
	input_store, output_store, opened := storage.builder_stores_open(ctx)
	if !opened {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 0)
	}

	// 1. Resolve and verify the C source file inside the verified source tree.
	source_file_hash, resolve_out := resolve_source_in_tree(&input_store, source_tree_hash, path, error)
	if resolve_out != .Succeeded {
		log_builder_failure(1, error)
		return resolve_out, 0
	}

	// 2. Load and verify host, c_compiler, assemble, and the C source file.
	host_mem, host_addr, host_bytes, host_out := read_blob_to_memory(&input_store, host_hash, pr.C_MODULE_BYTES_LIMIT, error)
	if host_out != .Succeeded {
		return host_out, 0
	}
	defer {
		system.memory_unmap(host_addr)
		system.close(host_mem)
	}

	compiler_mem, compiler_addr, compiler_bytes, cc_out := read_blob_to_memory(&input_store, compiler_hash, pr.C_MODULE_BYTES_LIMIT, error)
	if cc_out != .Succeeded {
		return cc_out, 0
	}
	defer {
		system.memory_unmap(compiler_addr)
		system.close(compiler_mem)
	}

	assembler_mem, assembler_addr, assembler_bytes, asm_out := read_blob_to_memory(&input_store, assembler_hash, pr.C_MODULE_BYTES_LIMIT, error)
	if asm_out != .Succeeded {
		return asm_out, 0
	}
	defer {
		system.memory_unmap(assembler_addr)
		system.close(assembler_mem)
	}

	source_mem, source_addr, source_bytes, src_out := read_blob_to_memory(&input_store, source_file_hash, pr.C_SOURCE_BYTES_LIMIT, error)
	if src_out != .Succeeded {
		return src_out, 0
	}
	defer {
		system.memory_unmap(source_addr)
		system.close(source_mem)
	}

	seed_values := child_seed_values(ctx)

	// 3. Compile C source -> assembly text in a zero-grant child call host.
	compile_args := [2]isolated.Argument{{table = {records = source_bytes, count = u64(len(source_bytes)), memory_handle = u64(source_mem)}}, {}}
	text_first := max(u64(len(source_bytes)) * C_TEXT_BYTES_FOR_EACH_SOURCE_BYTE, C_TEXT_FIRST_BYTES_LEAST)
	text_size, text_mem, compile_out := call_child_sized(
		host_bytes,
		compiler_mem,
		compiler_bytes,
		"c_compiler",
		"compile",
		compile_args[:],
		1,
		text_first,
		pr.C_TEXT_BYTES_LIMIT,
		seed_values,
		error,
	)
	if compile_out != .Succeeded {
		log_builder_failure(2, error)
		return compile_out, 0
	}
	defer system.close(text_mem)

	text_pages, _ := system.memory_size(text_mem)
	if refusal := pr.c_build_written_refusal(text_size, i64(min(text_pages * system.PAGE_SIZE, pr.C_TEXT_BYTES_LIMIT))); refusal.kind != 0 {
		if error != nil {
			error^ = refusal
		}
		return .Callee_Unavailable, 0
	}
	text_addr, text_map_status := system.memory_map(text_mem, {})
	if text_map_status != .Succeeded {
		return call_outcome.fail(error, system.own_operation_outcome(text_map_status), .Refused, .Kernel_Status, 0, 0, 0, i64(text_map_status))
	}
	defer system.memory_unmap(text_addr)
	text_bytes := ([^]u8)(text_addr)[:text_size]

	// 4. Assemble assembly text -> modus module in a zero-grant child call host.
	assemble_args := [2]isolated.Argument{{table = {records = text_bytes, count = u64(len(text_bytes)), memory_handle = u64(text_mem)}}, {}}
	module_first := u64(text_size) / 4 + C_MODULE_FIRST_BYTES_MORE
	module_size, module_mem, assemble_out := call_child_sized(
		host_bytes,
		assembler_mem,
		assembler_bytes,
		"assemble",
		"assemble",
		assemble_args[:],
		1,
		module_first,
		pr.C_MODULE_BYTES_LIMIT,
		seed_values,
		error,
	)
	if assemble_out != .Succeeded {
		log_builder_failure(3, error)
		return assemble_out, 0
	}
	defer system.close(module_mem)

	module_pages, _ := system.memory_size(module_mem)
	if refusal := pr.c_build_written_refusal(module_size, i64(min(module_pages * system.PAGE_SIZE, pr.C_MODULE_BYTES_LIMIT))); refusal.kind != 0 {
		if error != nil {
			error^ = refusal
		}
		return .Callee_Unavailable, 0
	}
	module_addr, module_map_status := system.memory_map(module_mem, {})
	if module_map_status != .Succeeded {
		return call_outcome.fail(error, system.own_operation_outcome(module_map_status), .Refused, .Kernel_Status, 0, 0, 0, i64(module_map_status))
	}
	defer system.memory_unmap(module_addr)
	module_bytes := ([^]u8)(module_addr)[:module_size]

	if refusal := pr.c_build_module_refusal(module_bytes); refusal.kind != 0 {
		if error != nil {
			error^ = refusal
		}
		return .Callee_Unavailable, 0
	}

	// 5. Write validated module into the empty output store under "module".
	if !write_output_blob(&output_store, "module", module_bytes, error) {
		if error != nil && error.kind == 0 {
			_, _ = call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
		}
		log_builder_failure(4, error)
		return .Callee_Unavailable, 0
	}

	system.log_fact(.Info, C_Module_Built{size = value_kinds.Size_In_Bytes(len(module_bytes))}, path)
	return .Succeeded, 1
}
