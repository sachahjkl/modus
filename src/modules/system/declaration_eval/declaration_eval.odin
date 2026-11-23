// Sandboxed .lex declaration evaluator module
// (src/md/features/declarations.md, "Text stops at the evaluation").
//
// Runs inside a call host with zero grants: no writable store, no network and
// no root ring. The caller passes a .lex source, an optional dotted field path
// to force lazily, a read-only bundle of referenced files and declarations,
// and a lent memory object for the canonical serialized output or refusal.
package declaration_eval_module

import "base:intrinsics"
import "modus:contract/call_outcome"
import contract "modus:contract/declaration_eval"
import "modus:contract/errors"
import "modus:lex_evaluator"
import "modus:lex_parser"
import "modus:system"

// The bytes of a declaration file. The copy of the source and the pools
// of the evaluation are memory of an arena of the budget of the call host,
// sized from the file: a short file does not pay for the bound.
SOURCE_BYTES_MOST :: lex_parser.DECLARATION_TEXT_BYTES_MOST
FIELD_PATH_BYTES_MOST :: 256
BUNDLE_BYTES_MOST :: 256 * 1024
OUTPUT_BYTES_MOST :: 256 * 1024

ARGUMENT_SOURCE :: 1
ARGUMENT_FIELD_PATH :: 2
ARGUMENT_BUNDLE :: 3
ARGUMENT_OUTPUT :: 4

MEMORY_MAP_ARGUMENT_MEMORY :: 1

field_path_copy: [FIELD_PATH_BYTES_MOST]u8
bundle_copy: [BUNDLE_BYTES_MOST]u8
bundle_view: []u8
output_staging: [OUTPUT_BYTES_MOST]u8
workspace: lex_evaluator.Declaration_Workspace

// refusal_give gives the error record of the budget or of the arena as
// the error record of the export.
@(private)
refusal_give :: proc "contextless" (error: ^errors.Error_Record, refusal: errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	// The budget of the call host did not pay the memory of the call.
	if error != nil {
		error^ = call_outcome.record_explained(.Budget_Or_Capacity_Exhausted, refusal)
		error.operation = 0
		error.argument = 0
	}
	return .Budget_Or_Capacity_Exhausted, 0
}

@(private)
output_map :: proc "contextless" (memory: system.Handle, error: ^errors.Error_Record) -> (bytes: []u8, outcome: call_outcome.Call_Outcome) {
	refusal: errors.Error_Record
	address, status := system.memory_map(memory, {.Write}, error = &refusal)
	if status != .Ok {
		if error != nil {
			error^ = refusal
			error.operation = 0
			error.argument = refusal.argument == MEMORY_MAP_ARGUMENT_MEMORY ? i64(ARGUMENT_OUTPUT) : 0
			if refusal.kind == i64(errors.Kind.None) {
				error^ = errors.error_make(.Refused, argument = ARGUMENT_OUTPUT, found = i64(status))
			}
		}
		return nil, system.outcome_of_status(status)
	}
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], .Succeeded
}

// evaluate parses and lazily evaluates a .lex declaration in mode
// `declaration` with zero side effects, forces `field_path` when non-empty,
// and writes the canonical serialized result or typed refusal record into
// `output`, returning the byte count written.
@(export, link_name = "evaluate")
evaluate :: proc "c" (
	source: ^system.Bytes_To_Read,
	field_path: ^system.Bytes_To_Read,
	bundle: ^system.Bytes_To_Read,
	output: system.Lent({.Read, .Write}),
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	// Copy every caller count and buffer once: in an isolated call the caller
	// can change shared memory concurrently.
	source_count := intrinsics.volatile_load(&source.count)
	if source_count == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, ARGUMENT_SOURCE, 0, SOURCE_BYTES_MOST)
	}
	if source_count > SOURCE_BYTES_MOST {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_SOURCE, i64(source_count), SOURCE_BYTES_MOST)
	}
	amounts, budget_status := system.budget_read()
	if budget_status != .Ok {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0, 0, 0, i64(budget_status))
	}
	arena_refusal: errors.Error_Record
	arena, arena_status := system.arena_create(system.arena_reservation_pages(amounts.pages), 0, &arena_refusal)
	if arena_status != .Ok {
		return refusal_give(error, arena_refusal)
	}
	defer system.arena_end(&arena)
	source_address, source_status := system.arena_push(&arena, source_count, 1, &arena_refusal)
	if source_status != .Ok {
		return refusal_give(error, arena_refusal)
	}
	intrinsics.mem_copy_non_overlapping(source_address, source.bytes, int(source_count))
	source_text := string(([^]u8)(source_address)[:source_count])
	// The arena holds the source first: a larger scale of the pools goes
	// back to this mark, and the source stays.
	pools_mark := arena.used_bytes

	path_count := intrinsics.volatile_load(&field_path.count)
	if path_count > FIELD_PATH_BYTES_MOST {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_FIELD_PATH, i64(path_count), FIELD_PATH_BYTES_MOST)
	}
	if path_count > 0 {
		intrinsics.mem_copy_non_overlapping(&field_path_copy[0], field_path.bytes, int(path_count))
	}
	path_text := string(field_path_copy[:path_count])

	bundle_count := intrinsics.volatile_load(&bundle.count)
	if bundle_count > BUNDLE_BYTES_MOST {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_BUNDLE, i64(bundle_count), BUNDLE_BYTES_MOST)
	}
	bundle_view = nil
	config := lex_evaluator.Declaration_Config{}
	catalog_bindings: [1]lex_evaluator.Declaration_Binding
	if bundle_count > 0 {
		intrinsics.mem_copy_non_overlapping(&bundle_copy[0], bundle.bytes, int(bundle_count))
		bundle_view = bundle_copy[:bundle_count]
		if refusal := contract.bundle_validate(bundle_view); refusal != .None {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, ARGUMENT_BUNDLE, 0, 0, i64(refusal))
		}
		config.loader = lex_evaluator.bundle_loader(&bundle_view)
		config.here_hash, config.has_here = contract.bundle_here_hash(bundle_view)
		if catalog_source, has_catalog := contract.bundle_lookup_path(bundle_view, "catalog.lex"); has_catalog {
			catalog_bindings[0] = {name = "catalog", kind = .Lex_Source, source = catalog_source}
			config.bindings = catalog_bindings[:]
		}
	}

	// The first scale is the one whose share of text holds the source and
	// the bundle. A node pool or a text arena that the files fill doubles
	// the scale, until the evaluation passes, no scale holds it, or the
	// budget of the call host refuses the pools: then the call fails with
	// that error record.
	config.text_bytes_most = SOURCE_BYTES_MOST
	scale := lex_evaluator.declaration_scale_of_text(source_count + bundle_count)
	written: int
	ok: bool
	for {
		system.arena_reset_to(&arena, pools_mark)
		pools := lex_evaluator.declaration_pools_of_scale(scale)
		pools_address, pools_status := system.arena_push(&arena, u64(lex_evaluator.declaration_workspace_bytes(pools)), 64, &arena_refusal)
		if pools_status != .Ok {
			return refusal_give(error, arena_refusal)
		}
		lex_evaluator.declaration_workspace_carve(&workspace, ([^]u8)(pools_address)[:lex_evaluator.declaration_workspace_bytes(pools)], pools)
		written, ok = lex_evaluator.declaration_evaluate_to_buffer(&workspace, source_text, path_text, config, output_staging[:])
		next, larger := lex_evaluator.declaration_scale_after(&workspace, scale)
		if !larger {
			break
		}
		scale = next
	}
	if !ok {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Over_Limit, .Bytes, ARGUMENT_OUTPUT, 0, OUTPUT_BYTES_MOST)
	}

	memory, map_outcome := output_map(output.handle, error)
	if map_outcome != .Succeeded {
		return map_outcome, 0
	}
	if written > len(memory) {
		system.memory_unmap(raw_data(memory))
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, ARGUMENT_OUTPUT, i64(len(memory)), i64(written))
	}
	intrinsics.mem_copy_non_overlapping(raw_data(memory), &output_staging[0], written)
	system.memory_unmap(raw_data(memory))

	if header, _, hdr_err := contract.output_read_header(output_staging[:written]); hdr_err == .None {
		if header.status == .Ok {
			system.log_fact(.Info, Evaluation_Completed{bytes = u64(written), steps = u64(header.steps_taken)})
		} else {
			system.log_fact(.Info, Evaluation_Refused{steps = u64(header.steps_taken), failure = u64(header.failure_kind), line = header.line, column = header.column})
		}
	}
	return .Succeeded, i64(written)
}
