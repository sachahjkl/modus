// Sandboxed .lex declaration evaluator module
// (src/md/features/declarations.md, "Text stops at the evaluation").
//
// Runs inside a call host with zero grants: no writable store, no network and
// no root ring. The caller passes a .lex source, an optional dotted field path
// to force lazily, a read-only v2 bundle of referenced files and declarations
// (carrying a caller-supplied hash seed), and a lent memory object for the
// canonical serialized output or refusal. Zero static bundle/output/workspace
// BSS caps: all buffers are carved from the process arena bounded by its budget.
package declaration_eval_module

import "base:intrinsics"
import "modus:contract/call_outcome"
import contract "modus:contract/declaration_eval"
import "modus:contract/errors"
import "modus:lex_evaluator"
import "modus:lex_parser"
import "modus:system"

SOURCE_BYTES_MOST :: lex_parser.DECLARATION_TEXT_BYTES_MOST
FIELD_PATH_BYTES_MOST :: 256

ARGUMENT_SOURCE :: 1
ARGUMENT_FIELD_PATH :: 2
ARGUMENT_BUNDLE :: 3
ARGUMENT_OUTPUT :: 4

MEMORY_MAP_ARGUMENT_MEMORY :: 1

field_path_copy: [FIELD_PATH_BYTES_MOST]u8
bundle_view: []u8
workspace: lex_evaluator.Declaration_Workspace

// refusal_give gives the error record of the budget or of the arena as
// the error record of the export.
@(private)
refusal_give :: proc "contextless" (error: ^errors.Error_Record, refusal: errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
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

// evaluate parses, compiles, and lazily evaluates a .lex declaration in mode
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

	// Copy source into the arena once.
	source_address, source_status := system.arena_push(&arena, source_count, 1, &arena_refusal)
	if source_status != .Ok {
		return refusal_give(error, arena_refusal)
	}
	intrinsics.mem_copy_non_overlapping(source_address, source.bytes, int(source_count))
	source_text := string(([^]u8)(source_address)[:source_count])

	path_count := intrinsics.volatile_load(&field_path.count)
	if path_count > FIELD_PATH_BYTES_MOST {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_FIELD_PATH, i64(path_count), FIELD_PATH_BYTES_MOST)
	}
	if path_count > 0 {
		intrinsics.mem_copy_non_overlapping(&field_path_copy[0], field_path.bytes, int(path_count))
	}
	path_text := string(field_path_copy[:path_count])

	// Copy bundle into the arena (bounded only by process memory budget, no 256 KiB cap).
	bundle_count := intrinsics.volatile_load(&bundle.count)
	bundle_view = nil
	config := lex_evaluator.Declaration_Config{}
	if bundle_count > 0 {
		bundle_address, bundle_status := system.arena_push(&arena, bundle_count, 8, &arena_refusal)
		if bundle_status != .Ok {
			return refusal_give(error, arena_refusal)
		}
		intrinsics.mem_copy_non_overlapping(bundle_address, bundle.bytes, int(bundle_count))
		bundle_view = ([^]u8)(bundle_address)[:bundle_count]
		if refusal := contract.bundle_validate(bundle_view); refusal != .None {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, ARGUMENT_BUNDLE, 0, 0, i64(refusal))
		}
		config.loader = lex_evaluator.bundle_loader(&bundle_view)
		config.here_hash, config.has_here = contract.bundle_here_hash(bundle_view)
		config.hash_seed = contract.bundle_hash_seed(bundle_view)
	}

	// Map output lent memory once to learn its capacity, and carve staging of
	// the exact output capacity from the arena (no 256 KiB static staging cap).
	memory, map_outcome := output_map(output.handle, error)
	if map_outcome != .Succeeded {
		return map_outcome, 0
	}
	defer system.memory_unmap(raw_data(memory))

	output_cap := u64(len(memory))
	staging_address, staging_status := system.arena_push(&arena, output_cap, 8, &arena_refusal)
	if staging_status != .Ok {
		return refusal_give(error, arena_refusal)
	}
	output_staging := ([^]u8)(staging_address)[:output_cap]

	pools_mark := arena.used_bytes
	config.text_bytes_most = SOURCE_BYTES_MOST
	scale := lex_evaluator.declaration_scale_of_text(source_count + bundle_count)
	written: int
	ok: bool
	for {
		system.arena_reset_to(&arena, pools_mark)
		pools := lex_evaluator.declaration_pools_of_scale(scale)
		need := u64(lex_evaluator.declaration_workspace_bytes(pools))
		pools_address, pools_status := system.arena_push(&arena, need, 64, &arena_refusal)
		if pools_status != .Ok {
			return refusal_give(error, arena_refusal)
		}
		lex_evaluator.declaration_workspace_carve(&workspace, ([^]u8)(pools_address)[:need], pools)
		written, ok = lex_evaluator.declaration_evaluate_to_buffer(&workspace, source_text, path_text, config, output_staging)
		next, larger := lex_evaluator.declaration_scale_after(&workspace, scale)
		if !larger {
			break
		}
		scale = next
	}
	if !ok {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, ARGUMENT_OUTPUT, i64(output_cap), i64(output_cap))
	}
	intrinsics.mem_copy_non_overlapping(raw_data(memory), raw_data(output_staging), written)

	if header, _, hdr_err := contract.output_read_header(output_staging[:written]); hdr_err == .None {
		if header.status == .Ok {
			system.log_fact(.Info, Evaluation_Completed{bytes = u64(written), steps = u64(header.steps_taken)})
		} else {
			system.log_fact(.Info, Evaluation_Refused{steps = u64(header.steps_taken), failure = u64(header.failure_kind), line = header.line, column = header.column})
		}
	}
	return .Succeeded, i64(written)
}
