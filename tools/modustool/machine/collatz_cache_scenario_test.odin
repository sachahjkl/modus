// Host unit tests for the two-machine collatz build, QUIC publish, and
// cache-only pull scenario (collatz_cache_scenario.odin).
package machine

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
collatz_test_bindings :: proc() -> Collatz_Cache_Bindings {
	return {
		cache_server_key     = strings.repeat("a", 64, context.temp_allocator),
		cache_signer_key     = strings.repeat("b", 64, context.temp_allocator),
		cache_publisher_seed = strings.repeat("c", 64, context.temp_allocator),
		collatz_here         = strings.repeat("d", 64, context.temp_allocator),
		collatz_recipe       = strings.repeat("e", 64, context.temp_allocator),
	}
}

@(test)
collatz_cache_expand_steps_refuses_empty_bindings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Refusal edges first: completely empty bindings fail for both machines.
	_, builder_empty_ok := collatz_cache_expand_steps(scenario_collatz_builder[:], {})
	testing.expect(t, !builder_empty_ok, "builder template refuses empty bindings")
	_, consumer_empty_ok := collatz_cache_expand_steps(scenario_collatz_consumer[:], {})
	testing.expect(t, !consumer_empty_ok, "consumer template refuses empty bindings")

	// Each individual required binding missing must be refused on builder.
	base := collatz_test_bindings()
	missing_server := base
	missing_server.cache_server_key = ""
	_, ok := collatz_cache_expand_steps(scenario_collatz_builder[:], missing_server)
	testing.expect(t, !ok, "builder refuses empty cache_server_key")

	missing_signer := base
	missing_signer.cache_signer_key = ""
	_, ok = collatz_cache_expand_steps(scenario_collatz_builder[:], missing_signer)
	testing.expect(t, !ok, "builder refuses empty cache_signer_key")

	missing_seed := base
	missing_seed.cache_publisher_seed = ""
	_, ok = collatz_cache_expand_steps(scenario_collatz_builder[:], missing_seed)
	testing.expect(t, !ok, "builder refuses empty cache_publisher_seed")

	missing_here := base
	missing_here.collatz_here = ""
	_, ok = collatz_cache_expand_steps(scenario_collatz_builder[:], missing_here)
	testing.expect(t, !ok, "builder refuses empty collatz_here")

	missing_recipe := base
	missing_recipe.collatz_recipe = ""
	_, ok = collatz_cache_expand_steps(scenario_collatz_builder[:], missing_recipe)
	testing.expect(t, !ok, "builder refuses empty collatz_recipe")

	// Consumer refuses empty cache_server_key, cache_signer_key, and collatz_recipe,
	// but does not require cache_publisher_seed because it never publishes.
	_, ok = collatz_cache_expand_steps(scenario_collatz_consumer[:], missing_server)
	testing.expect(t, !ok, "consumer refuses empty cache_server_key")
	_, ok = collatz_cache_expand_steps(scenario_collatz_consumer[:], missing_signer)
	testing.expect(t, !ok, "consumer refuses empty cache_signer_key")
	_, ok = collatz_cache_expand_steps(scenario_collatz_consumer[:], missing_recipe)
	testing.expect(t, !ok, "consumer refuses empty collatz_recipe")

	consumer_no_seed, no_seed_ok := collatz_cache_expand_steps(scenario_collatz_consumer[:], missing_seed)
	if testing.expect(t, no_seed_ok, "consumer expands without cache_publisher_seed") {
		collatz_cache_steps_free(consumer_no_seed)
	}

	// Empty template expands cleanly to an empty slice.
	empty_out, empty_ok := collatz_cache_expand_steps(nil, {})
	testing.expect(t, empty_ok && len(empty_out) == 0, "empty template expands to empty slice")

	// collatz_cache_run refuses nil part and empty boot volume without starting QEMU.
	part := Test_Part_Run{}
	testing.expect(t, !collatz_cache_run(nil, "build/boot.img"), "collatz_cache_run refuses nil part")
	testing.expect(t, !collatz_cache_run(&part, ""), "collatz_cache_run refuses empty boot volume")
}

@(test)
collatz_cache_scenarios_verify_build_publish_and_cache_only_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	bindings := collatz_test_bindings()
	builder, builder_ok := collatz_cache_expand_steps(scenario_collatz_builder[:], bindings)
	if !testing.expect(t, builder_ok, "builder scenario expands with valid bindings") {
		return
	}
	defer collatz_cache_steps_free(builder)

	consumer, consumer_ok := collatz_cache_expand_steps(scenario_collatz_consumer[:], bindings)
	if !testing.expect(t, consumer_ok, "consumer scenario expands with valid bindings") {
		return
	}
	defer collatz_cache_steps_free(consumer)

	builder_has_build_only := false
	builder_has_publish := false
	builder_has_steps_27 := false
	builder_has_111 := false
	builder_has_steps_0 := false
	builder_has_neg_one := false
	for step, index in builder {
		testing.expectf(t, !strings.contains(step.text, "{cache_") && !strings.contains(step.text, "{collatz_"), "builder step %d has unexpanded placeholder: %q", index + 1, step.text)
		if step.kind == .Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "builder step %d contains untypeable character at %d: %q", index + 1, unknown, step.text)
			if strings.contains(step.text, "recipes.build_project(\"build_only\")") {
				builder_has_build_only = true
			}
			if strings.contains(step.text, "recipes.publish") {
				builder_has_publish = true
			}
			if step.text == "collatz.steps(27)" {
				builder_has_steps_27 = true
			}
			if step.text == "collatz.steps(0)" {
				builder_has_steps_0 = true
			}
		}
		if step.kind == .Wait {
			if step.text == "[console] 111" {
				builder_has_111 = true
			}
			if step.text == "[console] -1" {
				builder_has_neg_one = true
			}
		}
	}
	testing.expect(t, builder_has_build_only, "builder builds collatz with build_only")
	testing.expect(t, builder_has_publish, "builder publishes collatz over QUIC")
	testing.expect(t, builder_has_steps_27 && builder_has_111, "builder checks collatz.steps(27) == 111")
	testing.expect(t, builder_has_steps_0 && builder_has_neg_one, "builder checks collatz.steps(0) == -1")
	testing.expect_value(t, builder[len(builder) - 2].text, "shutdown()")
	testing.expect_value(t, builder[len(builder) - 1].text, "kernel: the machine stops with code 0")

	consumer_has_cache_only := false
	consumer_has_remote_origin := false
	consumer_has_signer := false
	consumer_has_steps_27 := false
	consumer_has_111 := false
	for step, index in consumer {
		testing.expectf(t, !strings.contains(step.text, "{cache_") && !strings.contains(step.text, "{collatz_"), "consumer step %d has unexpanded placeholder: %q", index + 1, step.text)
		testing.expectf(t, !strings.contains(step.text, "configure_publisher"), "consumer step %d must not configure a publisher key", index + 1)
		testing.expectf(t, !strings.contains(step.text, bindings.cache_publisher_seed), "consumer step %d must not contain the publisher seed", index + 1)
		testing.expectf(t, !strings.contains(step.text, "build_only"), "consumer step %d must not run build_only", index + 1)
		if step.kind == .Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "consumer step %d contains untypeable character at %d: %q", index + 1, unknown, step.text)
			if strings.contains(step.text, "recipes.build_project(\"cache_only\")") {
				consumer_has_cache_only = true
			}
			if step.text == "collatz.steps(27)" {
				consumer_has_steps_27 = true
			}
		}
		if step.kind == .Wait {
			if step.text == "[console]   origin  remote_cache" {
				consumer_has_remote_origin = true
			}
			if step.text == strings.concatenate({"[console]   signer  ", bindings.cache_signer_key}, context.temp_allocator) {
				consumer_has_signer = true
			}
			if step.text == "[console] 111" {
				consumer_has_111 = true
			}
		}
	}
	testing.expect(t, consumer_has_cache_only, "consumer pulls collatz with cache_only")
	testing.expect(t, consumer_has_remote_origin, "consumer verifies remote_cache provenance")
	testing.expect(t, consumer_has_signer, "consumer verifies trusted signer provenance")
	testing.expect(t, consumer_has_steps_27 && consumer_has_111, "consumer checks collatz.steps(27) == 111")
	testing.expect_value(t, consumer[len(consumer) - 2].text, "shutdown()")
	testing.expect_value(t, consumer[len(consumer) - 1].text, "kernel: the machine stops with code 0")
}

@(test)
collatz_project_tree_hash_and_recipe_are_deterministic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	objects, trees, here_hash, read_ok := tutorial_read_project_tree(COLLATZ_PROJECT_DIR)
	if !testing.expect(t, read_ok, "src/outside/projects/collatz reads cleanly as a MODTREE2 tree") {
		return
	}
	defer tutorial_free_project_tree(objects, trees)

	testing.expect_value(t, len(objects), 3)
	testing.expect_value(t, len(trees), 0)
	testing.expect(t, here_hash != {}, "collatz MODTREE2 hash is non-zero")

	again_hash, again_ok := tutorial_tree_hash_of(objects, trees)
	testing.expect(t, again_ok && again_hash == here_hash, "collatz MODTREE2 hash is deterministic")

	here_hex := tutorial_hex_of(here_hash, context.temp_allocator)
	testing.expect_value(t, len(here_hex), 64)

	project_lex_bytes, lex_err := os.read_entire_file(COLLATZ_PROJECT_DIR + "/project.lex", context.temp_allocator)
	if !testing.expect(t, lex_err == nil, "collatz/project.lex is readable") {
		return
	}
	cb_hex := strings.repeat("1", 64, context.temp_allocator)
	cc_hex := strings.repeat("2", 64, context.temp_allocator)
	as_hex := strings.repeat("3", 64, context.temp_allocator)
	hs_hex := strings.repeat("4", 64, context.temp_allocator)
	fake_catalog := strings.concatenate({
		"{\n  c = {\n",
		"    module = (path) => recipe(module(blake3:", cb_hex, "), {\n",
		"      assembler = module(blake3:", as_hex, "),\n",
		"      compiler = module(blake3:", cc_hex, "),\n",
		"      host = module(blake3:", hs_hex, "),\n",
		"      path = path,\n",
		"      source = here(),\n",
		"    }),\n",
		"  },\n}\n",
	}, context.temp_allocator)

	recipe_hash, recipe_ok := tutorial_evaluate_project_recipe(string(project_lex_bytes), here_hash, fake_catalog)
	testing.expect(t, recipe_ok, "collatz/project.lex evaluates outputs.default to a Recipe_Ref")
	testing.expect(t, recipe_hash != {}, "collatz recipe hash is non-zero")

	changed_here := here_hash
	changed_here[0] ~= 0x01
	other_recipe, other_ok := tutorial_evaluate_project_recipe(string(project_lex_bytes), changed_here, fake_catalog)
	testing.expect(t, other_ok && other_recipe != recipe_hash, "changing collatz here() changes its recipe hash")
}
