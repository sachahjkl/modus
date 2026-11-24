#+build !freestanding
package root_plan_values

import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/memory_screen"
import "modus:contract/plan_values"

@(private = "file")
values_of :: proc(defaults, locks: []chosen_values.Change) -> (values: plan_values.Owner_Values) {
	defaults_bytes := make([]u8, chosen_values.HEADER_SIZE + 32 * chosen_values.ENTRY_SIZE, context.temp_allocator)
	locks_bytes := make([]u8, chosen_values.HEADER_SIZE + 32 * chosen_values.ENTRY_SIZE, context.temp_allocator)
	written, _ := chosen_values.write_record({}, defaults, defaults_bytes)
	values.defaults, _ = chosen_values.read_record(defaults_bytes[:written])
	written, _ = chosen_values.write_record({}, locks, locks_bytes)
	values.locks, _ = chosen_values.read_record(locks_bytes[:written])
	return values
}

// A share, growth factor, growth period, disk class field, and sizes outside
// their borders hold as no value, at each edge; a start size past the largest
// size gives the four defaults together; the values that pass hold, a lock
// over a default. No value is the defaults.
@(test)
the_plan_of_the_root_is_read_at_its_borders :: proc(t: ^testing.T) {
	none, none_refused := root_plan_of({})
	testing.expect(t, none == ROOT_PLAN_DEFAULTS && !none_refused)
	for share in ([?]u64{0, BUDGET_SHARE_MOST + 1, max(u64)}) {
		plan, _ := root_plan_of(values_of({{name = BUDGET_SHARE_FIELD, kind = .Choose, value = share}}, nil))
		testing.expectf(t, plan.budget_share == BUDGET_SHARE_DEFAULT && plan.budget_share_layer == .Contract_Default, "the share %d is taken", share)
	}
	for factor in ([?]u64{0, DEFAULT_GROWTH_FACTOR_MOST + 1, max(u64)}) {
		plan, _ := root_plan_of(values_of({{name = DEFAULT_GROWTH_FACTOR_FIELD, kind = .Choose, value = factor}}, nil))
		testing.expectf(t, plan.default_growth_factor == DEFAULT_GROWTH_FACTOR_DEFAULT && plan.growth_factor_layer == .Contract_Default, "the factor %d is taken", factor)
	}
	for period in ([?]u64{0, BUDGET_GROWTH_PERIOD_MS_MOST + 1, max(u64)}) {
		plan, _ := root_plan_of(values_of({{name = BUDGET_GROWTH_PERIOD_MS_FIELD, kind = .Choose, value = period}}, nil))
		testing.expectf(t, plan.budget_growth_period_ms == BUDGET_GROWTH_PERIOD_MS_DEFAULT && plan.growth_period_layer == .Contract_Default, "the period %d is taken", period)
	}
	for width in ([?]u64{0, u64(memory_screen.MIN_WIDTH) - 1, u64(memory_screen.MAX_WIDTH) + 1, max(u64)}) {
		plan, _ := root_plan_of(values_of({{name = MEMORY_SCREEN_START_WIDTH_FIELD, kind = .Choose, value = width}}, nil))
		testing.expectf(t, plan.memory_screen_start_width == ROOT_PLAN_DEFAULTS.memory_screen_start_width, "the width %d is taken", width)
	}
	past, refused := root_plan_of(values_of({{name = MEMORY_SCREEN_START_WIDTH_FIELD, kind = .Choose, value = 1280}, {name = MEMORY_SCREEN_MOST_WIDTH_FIELD, kind = .Choose, value = 1024}}, nil))
	testing.expect(t, refused && past.memory_screen_start_width == ROOT_PLAN_DEFAULTS.memory_screen_start_width && past.memory_screen_most_width == ROOT_PLAN_DEFAULTS.memory_screen_most_width)
	edges, edges_refused := root_plan_of(values_of({
		{name = BUDGET_SHARE_FIELD, kind = .Choose, value = BUDGET_SHARE_MOST},
		{name = DEFAULT_GROWTH_FACTOR_FIELD, kind = .Choose, value = DEFAULT_GROWTH_FACTOR_MOST},
		{name = BUDGET_GROWTH_PERIOD_MS_FIELD, kind = .Choose, value = BUDGET_GROWTH_PERIOD_MS_LEAST},
		{name = DISK_PROCESSES_PAGES_FIELD, kind = .Choose, value = 16_384},
		{name = DISK_PROCESSES_PROCESSES_FIELD, kind = .Choose, value = 8},
		{name = DISK_PROCESSES_THREADS_FIELD, kind = .Choose, value = 32},
		{name = DISK_PROCESSES_PROCESSOR_FIELD, kind = .Choose, value = 2_000_000},
		{name = MEMORY_SCREEN_START_WIDTH_FIELD, kind = .Choose, value = u64(memory_screen.MIN_WIDTH)},
		{name = MEMORY_SCREEN_START_HEIGHT_FIELD, kind = .Choose, value = u64(memory_screen.MIN_HEIGHT)},
	}, {
		{name = MEMORY_SCREEN_MOST_WIDTH_FIELD, kind = .Choose, value = 1280},
		{name = DEFAULT_GROWTH_FACTOR_FIELD, kind = .Choose, value = DEFAULT_GROWTH_FACTOR_LEAST},
	}))
	testing.expect(t, !edges_refused && edges.budget_share == BUDGET_SHARE_MOST && edges.budget_share_layer == .Plan_Default)
	testing.expect(t, edges.default_growth_factor == DEFAULT_GROWTH_FACTOR_LEAST && edges.growth_factor_layer == .Locked)
	testing.expect(t, edges.budget_growth_period_ms == BUDGET_GROWTH_PERIOD_MS_LEAST && edges.growth_period_layer == .Plan_Default)
	testing.expect(t, edges.disk_processes_pages == 16_384 && edges.disk_processes_processes == 8 && edges.disk_processes_threads == 32 && edges.disk_processes_processor == 2_000_000)
	testing.expect(t, edges.memory_screen_start_width == memory_screen.MIN_WIDTH && edges.memory_screen_most_width == 1280 && edges.memory_screen_layer == .Locked)
	for blocks in ([?]u64{0, STORE_BLOCKS_MOST + 1, max(u64)}) {
		_, found := store_blocks_of(values_of({{name = STORE_BLOCKS_FIELD, kind = .Choose, value = blocks}}, nil))
		testing.expectf(t, !found, "the quota %d is taken", blocks)
	}
	quota, quota_found := store_blocks_of(values_of(nil, {{name = STORE_BLOCKS_FIELD, kind = .Choose, value = STORE_BLOCKS_LEAST}}))
	testing.expect(t, quota_found && quota == STORE_BLOCKS_LEAST)
}

// Per-owner budget policy rows enforce each border, refuse pages + share
// together, refuse a growth reserve without or above its ceiling, and accept
// zero log records distinctly from unset.
@(test)
module_budget_policy_enforces_borders_and_conflicts :: proc(t: ^testing.T) {
	empty, conflict, over := module_budget_policy_of({})
	testing.expect(t, empty == {} && !conflict && !over)
	_, has_size := planned_pages_of(empty, 262_144)
	testing.expect(t, !has_size)

	// Out-of-range values are refused at each edge.
	for bad_pages in ([?]u64{0, BUDGET_PAGES_MOST + 1, max(u64)}) {
		pol, _, _ := module_budget_policy_of(values_of({{name = BUDGET_PAGES_FIELD, kind = .Choose, value = bad_pages}}, nil))
		testing.expectf(t, !pol.has_pages, "bad pages %d accepted", bad_pages)
	}
	for bad_share in ([?]u64{0, BUDGET_SHARE_PARTS_MOST + 1, max(u64)}) {
		pol, _, _ := module_budget_policy_of(values_of({{name = BUDGET_SHARE_PARTS_FIELD, kind = .Choose, value = bad_share}}, nil))
		testing.expectf(t, !pol.has_share_parts, "bad share %d accepted", bad_share)
	}
	for bad_proc in ([?]u64{0, BUDGET_PROCESSOR_LEAST - 1, BUDGET_PROCESSOR_MOST + 1, max(u64)}) {
		pol, _, _ := module_budget_policy_of(values_of({{name = BUDGET_PROCESSOR_FIELD, kind = .Choose, value = bad_proc}}, nil))
		testing.expectf(t, !pol.has_processor, "bad processor %d accepted", bad_proc)
	}
	for bad_log in ([?]u64{BUDGET_LOG_RECORDS_MOST + 1, max(u64)}) {
		pol, _, _ := module_budget_policy_of(values_of({{name = BUDGET_LOG_RECORDS_FIELD, kind = .Choose, value = bad_log}}, nil))
		testing.expectf(t, !pol.has_log_records, "bad log_records %d accepted", bad_log)
	}

	// Both pages and share_parts conflict: both are dropped.
	both, both_conflict, _ := module_budget_policy_of(values_of({
		{name = BUDGET_PAGES_FIELD, kind = .Choose, value = 4096},
		{name = BUDGET_SHARE_PARTS_FIELD, kind = .Choose, value = 128},
	}, nil))
	testing.expect(t, both_conflict && !both.has_pages && !both.has_share_parts)

	// Growth reserve with no ceiling, or above ceiling, is dropped.
	no_ceil, _, no_ceil_over := module_budget_policy_of(values_of({
		{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose, value = 1024},
	}, nil))
	testing.expect(t, no_ceil_over && !no_ceil.has_growth_reserve)
	past_ceil, _, past_ceil_over := module_budget_policy_of(values_of({
		{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose, value = 2048},
		{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose, value = 2049},
	}, nil))
	testing.expect(t, past_ceil_over && past_ceil.has_ceiling && past_ceil.ceiling_pages == 2048 && !past_ceil.has_growth_reserve)

	// Valid full row, including 0 log records and reserve == ceiling.
	valid, valid_conflict, valid_over := module_budget_policy_of(values_of({
		{name = BUDGET_SHARE_PARTS_FIELD, kind = .Choose, value = 256},
		{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose, value = 8192},
		{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose, value = 8192},
		{name = BUDGET_PROCESSOR_FIELD, kind = .Choose, value = 1_500_000},
		{name = BUDGET_LOG_RECORDS_FIELD, kind = .Choose, value = 0},
		{name = BUDGET_SCREEN_PAGES_FIELD, kind = .Choose, value = 512},
	}, nil))
	testing.expect(t, !valid_conflict && !valid_over)
	testing.expect(t, valid.has_share_parts && valid.share_parts == 256)
	testing.expect(t, valid.has_ceiling && valid.ceiling_pages == 8192)
	testing.expect(t, valid.has_growth_reserve && valid.growth_reserve_pages == 8192)
	testing.expect(t, valid.has_processor && valid.processor == 1_500_000)
	testing.expect(t, valid.has_log_records && valid.log_records == 0)
	testing.expect(t, valid.has_screen_pages && valid.screen_pages == 512)
	scaled, scaled_ok := planned_pages_of(valid, 262_144)
	testing.expect(t, scaled_ok && scaled == 65_536)

	// field_range_of separates root fields from per-owner fields.
	_, root_has_owner_field := field_range_of(OWNER, BUDGET_PAGES_FIELD)
	testing.expect(t, !root_has_owner_field)
	_, root_has_growth := field_range_of(OWNER, DEFAULT_GROWTH_FACTOR_FIELD)
	testing.expect(t, root_has_growth)
	_, other_has_growth := field_range_of("console", DEFAULT_GROWTH_FACTOR_FIELD)
	testing.expect(t, !other_has_growth)
	range, other_has_ceiling := field_range_of("console", BUDGET_CEILING_PAGES_FIELD)
	testing.expect(t, other_has_ceiling && range.least == BUDGET_PAGES_LEAST && range.most == BUDGET_PAGES_MOST)
}
