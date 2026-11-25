// Host unit tests for the main scenario parallel shard partitioning table
// (main_shards.odin).
package machine

import "core:testing"

@(test)
main_scenario_shards_refuses_malformed_inputs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	prelude := Main_Shard_Marker{kind = .Wait, text = "boot done"}
	epilogue := Main_Shard_Marker{kind = .Type, text = "shutdown()"}
	valid_specs := [2]Main_Shard_Spec{
		{name = "first", summary = "First section", start = {kind = .Type, text = "a"}},
		{name = "second", summary = "Second section", start = {kind = .Type, text = "b"}},
	}
	valid_steps := [6]Step{
		{kind = .Wait, text = "boot start"},
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "stopped"},
	}

	// Empty scenario and empty specs are refused.
	_, ref := main_scenario_shards_of(nil, valid_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Empty_Scenario)
	_, ref = main_scenario_shards_of(valid_steps[:], nil, prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Empty_Scenario)

	// Missing and ambiguous prelude markers are refused.
	_, ref = main_scenario_shards_of(valid_steps[:], valid_specs[:], {kind = .Wait, text = "absent"}, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Prelude_Not_Found)
	dup_prelude := [7]Step{
		{kind = .Wait, text = "boot done"},
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "stopped"},
		{kind = .Wait, text = "tail"},
	}
	_, ref = main_scenario_shards_of(dup_prelude[:], valid_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Prelude_Ambiguous)

	// Missing and ambiguous epilogue markers are refused.
	_, ref = main_scenario_shards_of(valid_steps[:], valid_specs[:], prelude, {kind = .Type, text = "absent"})
	testing.expect_value(t, ref, Main_Shard_Refusal.Epilogue_Not_Found)
	dup_epilogue := [7]Step{
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "stopped"},
		{kind = .Wait, text = "tail"},
	}
	_, ref = main_scenario_shards_of(dup_epilogue[:], valid_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Epilogue_Ambiguous)

	// Epilogue before or immediately after prelude is refused.
	inverted_bounds := [4]Step{
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
	}
	_, ref = main_scenario_shards_of(inverted_bounds[:], valid_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Order_Invalid)

	// Missing and ambiguous shard markers are refused.
	missing_spec := [1]Main_Shard_Spec{{name = "gone", summary = "Missing", start = {kind = .Type, text = "missing"}}}
	_, ref = main_scenario_shards_of(valid_steps[:], missing_spec[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Marker_Not_Found)
	dup_marker_steps := [7]Step{
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "stopped"},
		{kind = .Wait, text = "tail"},
	}
	_, ref = main_scenario_shards_of(dup_marker_steps[:], valid_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Marker_Ambiguous)

	// Gap between prelude end and first shard start is refused.
	gap_steps := [7]Step{
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "unowned"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "stopped"},
		{kind = .Wait, text = "tail"},
	}
	_, ref = main_scenario_shards_of(gap_steps[:], valid_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Coverage_Gap)

	// Out-of-order shard markers are refused.
	swapped_specs := [2]Main_Shard_Spec{valid_specs[1], valid_specs[0]}
	_, ref = main_scenario_shards_of(valid_steps[:], swapped_specs[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Coverage_Gap)

	reversed_tail := [3]Main_Shard_Spec{
		valid_specs[0],
		{name = "later", summary = "Later", start = {kind = .Type, text = "c"}},
		valid_specs[1],
	}
	three_steps := [7]Step{
		{kind = .Wait, text = "boot done"},
		{kind = .Type, text = "a"},
		{kind = .Type, text = "b"},
		{kind = .Type, text = "c"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "stopped"},
		{kind = .Wait, text = "tail"},
	}
	_, ref = main_scenario_shards_of(three_steps[:], reversed_tail[:], prelude, epilogue)
	testing.expect_value(t, ref, Main_Shard_Refusal.Order_Invalid)

	// Out-of-range shard materialization is refused cleanly.
	_, ref = main_shard_steps(nil, {})
	testing.expect_value(t, ref, Main_Shard_Refusal.Empty_Scenario)
	_, ref = main_shard_steps(valid_steps[:], Main_Shard_Range{prelude_first = 0, prelude_end = 2, body_first = 2, body_end = 99, epilogue_first = 4, epilogue_end = 6})
	testing.expect_value(t, ref, Main_Shard_Refusal.Shard_Out_Of_Range)
}

@(test)
main_scenario_shards_cover_every_step_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	shards, refusal := main_scenario_shards(scenario[:], context.temp_allocator)
	testing.expect_value(t, refusal, Main_Shard_Refusal.None)
	if !testing.expect_value(t, len(shards), MAIN_SHARD_COUNT) {
		return
	}

	// Verify unique non-empty names, non-empty summaries, lookup, and contiguous bodies.
	seen_names := make(map[string]bool, allocator = context.temp_allocator)
	prelude_end := shards[0].prelude_end
	epilogue_first := shards[0].epilogue_first
	testing.expect(t, prelude_end > 0, "boot prelude is non-empty")
	testing.expect(t, epilogue_first > prelude_end && epilogue_first < len(scenario), "shutdown epilogue is non-empty")

	coverage := make([]int, len(scenario), context.temp_allocator)
	for i in 0 ..< prelude_end {
		coverage[i] += 1
	}
	for i in epilogue_first ..< len(scenario) {
		coverage[i] += 1
	}

	for shard, index in shards {
		testing.expectf(t, len(shard.name) > 0 && len(shard.summary) > 0, "shard %d has non-empty name and summary", index)
		testing.expectf(t, shard.name not_in seen_names, "shard name %s is unique", shard.name)
		seen_names[shard.name] = true

		found_shard, found := main_shard_find(shards, shard.name)
		testing.expectf(t, found && found_shard == shard, "main_shard_find locates %s", shard.name)

		testing.expect_value(t, shard.prelude_first, 0)
		testing.expect_value(t, shard.prelude_end, prelude_end)
		testing.expect_value(t, shard.epilogue_first, epilogue_first)
		testing.expect_value(t, shard.epilogue_end, len(scenario))
		testing.expectf(t, shard.body_end > shard.body_first, "shard %s has a non-empty body", shard.name)
		if index > 0 {
			testing.expect_value(t, shard.body_first, shards[index - 1].body_end)
		} else {
			testing.expect_value(t, shard.body_first, prelude_end)
		}
		for pos in shard.body_first ..< shard.body_end {
			coverage[pos] += 1
		}

		// Verify 1-based Step_Span and full materialized shard steps.
		span := main_shard_step_span(shard)
		testing.expect_value(t, span.first, shard.body_first + 1)
		testing.expect_value(t, span.last, shard.body_end)

		assembled, mat_ref := main_shard_steps(scenario[:], shard, context.temp_allocator)
		testing.expect_value(t, mat_ref, Main_Shard_Refusal.None)
		expected_len := prelude_end + (shard.body_end - shard.body_first) + (len(scenario) - epilogue_first)
		testing.expect_value(t, len(assembled), expected_len)
		if len(assembled) == expected_len {
			testing.expect_value(t, assembled[0].text, "boot program: ok")
			testing.expect_value(t, assembled[len(assembled) - 1].text, "kernel: the machine stops with code 0")
		}
	}
	testing.expect_value(t, shards[len(shards) - 1].body_end, epilogue_first)

	// Prove 100% coverage with zero dropped steps and zero duplicate steps.
	for count, index in coverage {
		testing.expectf(t, count == 1, "scenario step %d is covered exactly once across prelude, shards, and epilogue (got %d)", index + 1, count)
	}

	_, unknown_found := main_shard_find(shards, "no_such_shard")
	testing.expect(t, !unknown_found, "main_shard_find refuses unknown shard name")
}
