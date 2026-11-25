// Pure logical shard partitioning table for the monolithic main machine test
// scenario (src/md/infrastructure/fast_build.md).
//
// Partitions `scenario` by exact unique boundary markers into independent
// logical sections of roughly 240 steps each, pairing every section with the
// shared boot prelude and shutdown epilogue without altering `scenario` itself
// or coupling core tool binaries to `main_scenario.odin`.
package machine

// Plan value: number of balanced logical sections partitioning the main machine
// scenario (targeting roughly 240 steps per section across about 2400 steps).
MAIN_SHARD_COUNT :: 10

// Unique boundary marker identifying one step in a scenario. When next_text is
// non-empty, the immediately following step must carry that exact text.
Main_Shard_Marker :: struct {
	kind:      Step_Kind,
	text:      string,
	next_text: string,
}

// Declarative specification of one logical shard of the main scenario.
Main_Shard_Spec :: struct {
	name:    string,
	summary: string,
	start:   Main_Shard_Marker,
}

// Resolved 0-based half-open [first, end) slices of one main scenario shard.
Main_Shard_Range :: struct {
	name:           string,
	summary:        string,
	prelude_first:  int,
	prelude_end:    int,
	body_first:     int,
	body_end:       int,
	epilogue_first: int,
	epilogue_end:   int,
}

// Closed border refusal set for main scenario shard partitioning.
Main_Shard_Refusal :: enum u8 {
	None,
	Empty_Scenario,
	Prelude_Not_Found,
	Prelude_Ambiguous,
	Epilogue_Not_Found,
	Epilogue_Ambiguous,
	Marker_Not_Found,
	Marker_Ambiguous,
	Order_Invalid,
	Coverage_Gap,
	Shard_Out_Of_Range,
}

// Last step of the shared boot prelude in `main_scenario.odin`.
MAIN_SHARD_PRELUDE_END :: Main_Shard_Marker {
	kind = .Wait,
	text = "root: settings stopped: itself, done",
}

// First step of the shared shutdown epilogue in `main_scenario.odin`.
MAIN_SHARD_EPILOGUE_START :: Main_Shard_Marker {
	kind      = .Type,
	text      = "memory()",
	next_text = "free_no_budget_holds  0 pages",
}

// Ordered logical shard boundaries of `main_scenario.odin`.
@(rodata)
main_shard_specs := [MAIN_SHARD_COUNT]Main_Shard_Spec {
	{
		name    = "console_and_desktop",
		summary = "Console language, UTF-8 fallback glyphs, desktop windows, and palette search",
		start   = {kind = .Type, text = "1 + 2 * 3"},
	},
	{
		name    = "palette_provider",
		summary = "Fault isolation, palette confirmation, console palette commands, settings, and revocation",
		start   = {kind = .Launch, text = "fault"},
	},
	{
		name    = "console_calls_and_compiler",
		summary = "Console diagnostics, direct and isolated calls, pipes, revocation, assembler, and C compiler",
		start   = {kind = .Type, text = "where(processes(), name = \"paint\")"},
	},
	{
		name    = "demos_and_concurrency",
		summary = "Remote allow, demonstrations, IPC rings, threads, locks, budgets, clock, and scheduler",
		start   = {kind = .Type, text = "remote_allow(\"{client key}\")"},
	},
	{
		name    = "memory_and_services",
		summary = "Virtual memory, boot display, paging, frame runs, and multi-role services",
		start   = {kind = .Launch, text = "address_space"},
	},
	{
		name    = "manual_and_imports",
		summary = "Manual pages and Markdown checks, library imports, and loader refusals",
		start   = {kind = .Launch, text = "manual"},
	},
	{
		name    = "log_and_streams",
		summary = "Log scopes and facts, record outputs, merge and filter streams, and root refusals",
		start   = {kind = .Launch, text = "log"},
	},
	{
		name    = "tables_terminal_and_storage",
		summary = "Table call parameters, terminal scroll and flood, block device, and storage service",
		start   = {kind = .Type, text = "sd = load(\"sample\")"},
	},
	{
		name    = "notes_editor_inspect_and_ui",
		summary = "Notes versions, editor undo, diagnostic errors, inspect, interface elements, fonts, and pointers",
		start   = {kind = .Launch, text = "notes"},
	},
	{
		name    = "settings_editor_and_builders",
		summary = "Live settings, scale and appearance, tables conformance, line editor, and sandboxed builders",
		start   = {kind = .Launch, text = "settings", next_text = "compositor: surface settings"},
	},
}

// main_shard_marker_find counts every step matching marker and returns the
// index of the first match alongside the total match count.
main_shard_marker_find :: proc(steps: []Step, marker: Main_Shard_Marker) -> (first_index: int, matches: int) {
	first_index = -1
	for step, index in steps {
		if step.kind != marker.kind || step.text != marker.text {
			continue
		}
		if marker.next_text != "" {
			if index + 1 >= len(steps) || steps[index + 1].text != marker.next_text {
				continue
			}
		}
		if matches == 0 {
			first_index = index
		}
		matches += 1
	}
	return first_index, matches
}

// main_scenario_shards_of resolves an ordered shard specification table against
// steps, verifying unique markers, strict ordering, and gap-free coverage of
// every step between prelude_end_marker and epilogue_start_marker.
main_scenario_shards_of :: proc(
	steps: []Step,
	specs: []Main_Shard_Spec,
	prelude_end_marker: Main_Shard_Marker,
	epilogue_start_marker: Main_Shard_Marker,
	allocator := context.allocator,
) -> (
	shards: []Main_Shard_Range,
	refusal: Main_Shard_Refusal,
) {
	if len(steps) == 0 || len(specs) == 0 {
		return nil, .Empty_Scenario
	}
	prelude_last, prelude_matches := main_shard_marker_find(steps, prelude_end_marker)
	if prelude_matches == 0 {
		return nil, .Prelude_Not_Found
	}
	if prelude_matches > 1 {
		return nil, .Prelude_Ambiguous
	}
	prelude_end := prelude_last + 1

	epilogue_first, epilogue_matches := main_shard_marker_find(steps, epilogue_start_marker)
	if epilogue_matches == 0 {
		return nil, .Epilogue_Not_Found
	}
	if epilogue_matches > 1 {
		return nil, .Epilogue_Ambiguous
	}
	if prelude_end >= epilogue_first {
		return nil, .Order_Invalid
	}

	starts := make([]int, len(specs), context.temp_allocator)
	for spec, index in specs {
		found_at, match_count := main_shard_marker_find(steps, spec.start)
		if match_count == 0 {
			return nil, .Marker_Not_Found
		}
		if match_count > 1 {
			return nil, .Marker_Ambiguous
		}
		starts[index] = found_at
	}

	if starts[0] < prelude_end {
		return nil, .Order_Invalid
	}
	if starts[0] > prelude_end {
		return nil, .Coverage_Gap
	}
	for index in 1 ..< len(starts) {
		if starts[index] <= starts[index - 1] {
			return nil, .Order_Invalid
		}
	}
	if starts[len(starts) - 1] >= epilogue_first {
		return nil, .Order_Invalid
	}

	out := make([]Main_Shard_Range, len(specs), allocator)
	for spec, index in specs {
		body_end := index + 1 < len(specs) ? starts[index + 1] : epilogue_first
		out[index] = Main_Shard_Range {
			name           = spec.name,
			summary        = spec.summary,
			prelude_first  = 0,
			prelude_end    = prelude_end,
			body_first     = starts[index],
			body_end       = body_end,
			epilogue_first = epilogue_first,
			epilogue_end   = len(steps),
		}
	}
	return out, .None
}

// main_scenario_shards resolves the canonical main_shard_specs table against
// the provided main scenario step slice.
main_scenario_shards :: proc(steps: []Step, allocator := context.allocator) -> (shards: []Main_Shard_Range, refusal: Main_Shard_Refusal) {
	return main_scenario_shards_of(steps, main_shard_specs[:], MAIN_SHARD_PRELUDE_END, MAIN_SHARD_EPILOGUE_START, allocator)
}

// main_shard_find locates a resolved shard by name.
main_shard_find :: proc(shards: []Main_Shard_Range, name: string) -> (shard: Main_Shard_Range, found: bool) {
	for item in shards {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// main_shard_step_span returns the 1-based inclusive Step_Span of shard's body
// for use with `modustool test main steps ...`.
main_shard_step_span :: proc(shard: Main_Shard_Range) -> Step_Span {
	return {first = shard.body_first + 1, last = shard.body_end}
}

// main_shard_steps materializes the full runnable step slice (shared boot
// prelude, shard body, and shared shutdown epilogue) for one shard.
main_shard_steps :: proc(steps: []Step, shard: Main_Shard_Range, allocator := context.allocator) -> (out: []Step, refusal: Main_Shard_Refusal) {
	n := len(steps)
	if n == 0 {
		return nil, .Empty_Scenario
	}
	if shard.prelude_first < 0 || shard.prelude_end < shard.prelude_first || shard.prelude_end > n ||
	   shard.body_first < shard.prelude_end || shard.body_end <= shard.body_first || shard.body_end > n ||
	   shard.epilogue_first < shard.body_end || shard.epilogue_end < shard.epilogue_first || shard.epilogue_end > n {
		return nil, .Shard_Out_Of_Range
	}
	prelude_len := shard.prelude_end - shard.prelude_first
	body_len := shard.body_end - shard.body_first
	epilogue_len := shard.epilogue_end - shard.epilogue_first
	out = make([]Step, prelude_len + body_len + epilogue_len, allocator)
	copy(out[:prelude_len], steps[shard.prelude_first:shard.prelude_end])
	copy(out[prelude_len : prelude_len + body_len], steps[shard.body_first:shard.body_end])
	copy(out[prelude_len + body_len:], steps[shard.epilogue_first:shard.epilogue_end])
	return out, .None
}
