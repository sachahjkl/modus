// Sandboxed .lex declaration evaluator module
// (src/md/features/declarations.md, "Text stops at the evaluation").
//
// Runs inside a call host with zero grants: no writable store, no network and
// no root ring. The caller passes a .lex source, an optional dotted field path
// to force lazily, a read-only bundle of referenced files and declarations,
// and a lent memory object for the canonical serialized output or refusal.
package declaration_eval_module

import "base:intrinsics"
import contract "modus:contract/declaration_eval"
import "modus:contract/errors"
import "modus:support/lex_evaluator"
import "modus:support/lex_parser"
import "modus:support/system"

SOURCE_BYTES_MOST :: lex_parser.DECLARATION_TEXT_BYTES_MOST
FIELD_PATH_BYTES_MOST :: 256
BUNDLE_BYTES_MOST :: 256 * 1024
OUTPUT_BYTES_MOST :: 256 * 1024

ERROR :: -1

ARGUMENT_SOURCE :: 1
ARGUMENT_FIELD_PATH :: 2
ARGUMENT_BUNDLE :: 3
ARGUMENT_OUTPUT :: 4

MEMORY_MAP_ARGUMENT_MEMORY :: 1

source_copy: [SOURCE_BYTES_MOST]u8
field_path_copy: [FIELD_PATH_BYTES_MOST]u8
bundle_copy: [BUNDLE_BYTES_MOST]u8
bundle_view: []u8
output_staging: [OUTPUT_BYTES_MOST]u8
workspace: lex_evaluator.Declaration_Workspace

@(private)
output_map :: proc "contextless" (memory: system.Handle, error: ^errors.Error_Record) -> (bytes: []u8, ok: bool) {
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
		return nil, false
	}
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], true
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
) -> i64 {
	// Copy every caller count and buffer once: in an isolated call the caller
	// can change shared memory concurrently.
	source_count := intrinsics.volatile_load(&source.count)
	if source_count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, ARGUMENT_SOURCE, 0, SOURCE_BYTES_MOST)
	}
	if source_count > SOURCE_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_SOURCE, i64(source_count), SOURCE_BYTES_MOST)
	}
	intrinsics.mem_copy_non_overlapping(&source_copy[0], source.bytes, int(source_count))
	source_text := string(source_copy[:source_count])

	path_count := intrinsics.volatile_load(&field_path.count)
	if path_count > FIELD_PATH_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_FIELD_PATH, i64(path_count), FIELD_PATH_BYTES_MOST)
	}
	if path_count > 0 {
		intrinsics.mem_copy_non_overlapping(&field_path_copy[0], field_path.bytes, int(path_count))
	}
	path_text := string(field_path_copy[:path_count])

	bundle_count := intrinsics.volatile_load(&bundle.count)
	if bundle_count > BUNDLE_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_BUNDLE, i64(bundle_count), BUNDLE_BYTES_MOST)
	}
	bundle_view = nil
	config := lex_evaluator.Declaration_Config{}
	if bundle_count > 0 {
		intrinsics.mem_copy_non_overlapping(&bundle_copy[0], bundle.bytes, int(bundle_count))
		bundle_view = bundle_copy[:bundle_count]
		if refusal := contract.bundle_validate(bundle_view); refusal != .None {
			return errors.fail(error, ERROR, .Bad_Value, .None, ARGUMENT_BUNDLE, 0, 0, i64(refusal))
		}
		config.loader = lex_evaluator.bundle_loader(&bundle_view)
		config.here_hash, config.has_here = contract.bundle_here_hash(bundle_view)
	}

	written, ok := lex_evaluator.declaration_evaluate_to_buffer(&workspace, source_text, path_text, config, output_staging[:])
	if !ok {
		return errors.fail(error, ERROR, .Over_Limit, .Bytes, ARGUMENT_OUTPUT, 0, OUTPUT_BYTES_MOST)
	}

	memory, mapped := output_map(output.handle, error)
	if !mapped {
		return ERROR
	}
	if written > len(memory) {
		system.memory_unmap(raw_data(memory))
		return errors.fail(error, ERROR, .Too_Small, .Bytes, ARGUMENT_OUTPUT, i64(len(memory)), i64(written))
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
	return i64(written)
}
