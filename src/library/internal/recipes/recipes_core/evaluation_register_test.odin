#+build !freestanding
package recipes_core

import "core:mem"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/builder"
import "modus:contract/call_outcome"
import "modus:contract/declaration_eval"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:lex_evaluator"

@(private = "file")
registered_count :: proc(registry: ^Recipe_Registry) -> (count: int) {
	for recipe in registry.recipes {
		if recipe.active {
			count += 1
		}
	}
	return count
}

@(private = "file")
evaluation_hash :: proc(tag: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)tag)
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

// The output of the evaluation of a recipe of the C builder over a source
// tree, as the evaluation process gives it to the service.
@(private = "file")
recipe_output :: proc(buffer: []u8, here: blake3.Hash, source: string) -> (written: int, ok: bool) {
	workspace := new(lex_evaluator.Declaration_Workspace, context.temp_allocator)
	pools := lex_evaluator.declaration_pools_of_scale(0)
	memory, _ := mem.alloc_bytes(lex_evaluator.declaration_workspace_bytes(pools), 64, context.temp_allocator)
	lex_evaluator.declaration_workspace_carve(workspace, memory, pools)
	config := lex_evaluator.Declaration_Config{has_here = true, here_hash = here, stack_bytes = 2 * 1024 * 1024}
	return lex_evaluator.declaration_evaluate_to_buffer(workspace, source, "", config, buffer)
}

@(private = "file")
collatz_source :: proc() -> string {
	builder := hash_literal(evaluation_hash("the C builder"))
	parts := [?]string{"recipe(module(", builder, "), { source = here(), path = \"collatz.c\" })"}
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

// The refusals of the path of the export, each with its error record: an
// output of a refused evaluation and one whose value is no recipe, an
// output that ends early, an output past the bound of the copy, an output
// that holds a bare hash, and a missing registry. Nothing is registered,
// and the record is zero.
@(test)
a_refused_evaluation_registers_nothing_and_says_why :: proc(t: ^testing.T) {
	registry := new(Recipe_Registry, context.temp_allocator)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	output: [MAX_RECIPE_OUTPUT_BYTES + 8]u8

	expect :: proc(t: ^testing.T, registry: ^Recipe_Registry, spec: ^pr.Recipe_Spec, output: []u8, refusal: pr.Recipe_Refusal, kind: errors.Kind, location := #caller_location) {
		spec.input_count = 2
		_, got := register_evaluation(registry, output, spec)
		testing.expect_value(t, got, refusal, loc = location)
		testing.expect(t, spec^ == {}, "a refusal leaves the record zero", loc = location)
		testing.expect_value(t, registered_count(registry), 0, loc = location)
		record := recipe_refusal_record(got, 1)
		testing.expect_value(t, record.kind, i64(kind), loc = location)
		testing.expect_value(t, record.found, i64(refusal), loc = location)
		testing.expect_value(t, record.argument, i64(1), loc = location)
	}

	refused_length, _ := declaration_eval.output_write_refusal(output[:], .Type_Error, 1, 2, 3, "recipe")
	expect(t, registry, spec, output[:refused_length], .Not_A_Recipe, .Bad_Value)

	writer := declaration_eval.output_writer_start(output[:], {status = .Ok})
	declaration_eval.output_write_integer(&writer, 4)
	expect(t, registry, spec, output[:writer.written], .Not_A_Recipe, .Bad_Value)

	length, ok := recipe_output(output[:], evaluation_hash("collatz"), collatz_source())
	testing.expect(t, ok, "the recipe evaluates")
	expect(t, registry, spec, output[:length - 1], .Damaged_Recipe, .Malformed)
	expect(t, registry, spec, output[:MAX_RECIPE_OUTPUT_BYTES + 1], .Arguments_Too_Large, .Too_Long)

	// A bare hash cannot come from the evaluator, which refuses it; an
	// output that a caller wrote by hand with one is refused here too.
	writer = declaration_eval.output_writer_start(output[:], {status = .Ok})
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Recipe_Ref))
	written := evaluation_hash("written")
	builder := evaluation_hash("the C builder")
	declaration_eval.output_write_bytes(&writer, written[:])
	declaration_eval.output_write_bytes(&writer, builder[:])
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 1)
	declaration_eval.output_write_string(&writer, "source")
	declaration_eval.output_write_hash(&writer, evaluation_hash("collatz"))
	expect(t, registry, spec, output[:writer.written], .Untyped_Hash, .Bad_Value)

	_, missing := register_evaluation(nil, output[:length], spec)
	testing.expect_value(t, missing, pr.Recipe_Refusal.Buffer_Too_Small)
}

// The success case of the path of the export: the output of the evaluation
// of a recipe is registered under the hash that the evaluator wrote, its
// record names the source tree, and a build of it is the refusal of the
// stop of layer 2, with its error record.
@(test)
the_output_of_an_evaluation_is_registered_under_its_hash :: proc(t: ^testing.T) {
	registry := new(Recipe_Registry, context.temp_allocator)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	output: [MAX_RECIPE_OUTPUT_BYTES]u8
	here := evaluation_hash("collatz")
	length, ok := recipe_output(output[:], here, collatz_source())
	testing.expect(t, ok, "the recipe evaluates")

	_, reader, _ := declaration_eval.output_read_header(output[:length])
	_, _ = declaration_eval.output_read_tag(&reader)
	written, _ := declaration_eval.output_read_hash(&reader)

	recipe, refusal := register_evaluation(registry, output[:length], spec)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	testing.expect(t, recipe == written, "the hash that the evaluator wrote is the hash of the registry")
	testing.expect_value(t, registered_count(registry), 1)
	testing.expect(t, spec.inputs[0].hash == here && spec.inputs[0].kind == .Tree, "the source tree is the input")

	state := new(Recipes_State, context.temp_allocator)
	store := recipes_test_state_init(state)
	defer free(store)
	built := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, built.refusal, pr.Recipe_Refusal.Builder_Needs_Sandbox)
	record := recipe_refusal_record(built.refusal, 1)
	testing.expect_value(t, record.kind, i64(errors.Kind.Unsupported))
}

// Each error record of a refusal of a recipe carries the refusal as its
// value found, which a caller reads back with recipe_refusal_of_word: the
// one rule of the records of the service. A kind whose value found means
// another thing (No_Answer) would break it.
@(test)
each_refusal_record_carries_its_refusal :: proc(t: ^testing.T) {
	for member in pr.Recipe_Refusal {
		if member == .None {
			continue
		}
		record := recipe_refusal_record(member, 1)
		read, ok := pr.recipe_refusal_of_word(u64(record.found))
		testing.expectf(t, ok && read == member, "%v: the value found %d", member, record.found)
		testing.expect_value(t, record.argument, i64(1))
	}
	// The bound that a refusal names is its limit.
	testing.expect_value(t, recipe_refusal_record(.Input_Too_Large, 1).limit, i64(builder.MAX_INPUT_OBJECTS))
	testing.expect_value(t, recipe_refusal_record(.Builder_Timed_Out, 1).limit, i64(builder.BUILD_TIME_BOUND_MILLISECONDS))
}

// Each refusal of a recipe gives an outcome whose kinds hold the kind of
// its record: a caller that reads the outcome finds a record that the
// outcome explains.
@(test)
each_refusal_record_has_a_kind_of_its_outcome :: proc(t: ^testing.T) {
	for member in pr.Recipe_Refusal {
		outcome := recipe_refusal_outcome(member)
		record := recipe_refusal_record(member, 1)
		kind, known := errors.kind_of_word(record.kind)
		testing.expectf(t, known && kind in call_outcome.KINDS_OF[outcome], "%v: the outcome %v with the kind %v", member, outcome, kind)
	}
}
