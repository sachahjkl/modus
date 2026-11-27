#+build !freestanding
#+build !modus
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
		testing.expectf(t, pol.size_kind == .Default, "bad pages %d accepted", bad_pages)
	}
	for bad_share in ([?]u64{0, BUDGET_SHARE_PARTS_MOST + 1, max(u64)}) {
		pol, _, _ := module_budget_policy_of(values_of({{name = BUDGET_SHARE_PARTS_FIELD, kind = .Choose, value = bad_share}}, nil))
		testing.expectf(t, pol.size_kind == .Default, "bad share %d accepted", bad_share)
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
	testing.expect(t, both_conflict && both.size_kind == .Default && both.pages == 0 && both.share_parts == 0)

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
	testing.expect(t, valid.size_kind == .Share_Parts && valid.share_parts == 256)
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

// Unbounded rows and safety ceiling enforcement: edges and refusals come first
// (non-"unbounded" text, unbounded combined with share_parts, unbounded on
// ceiling/reserve/disk class, reserve without ceiling, zero safety ceiling,
// ceiling above machine share capped), then valid unbounded rows and start
// options.
@(test)
unbounded_row_and_safety_ceiling_edges :: proc(t: ^testing.T) {
	// Any text other than exact "unbounded" on budget_pages is refused.
	for bad_text in ([?]string{"", "Unbounded", "UNBOUNDED", "unbounded ", " unbounded", "infinite", "all", "0"}) {
		pol, _, _ := module_budget_policy_of(values_of({{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = bad_text}}, nil))
		testing.expectf(t, pol.size_kind == .Default, "bad budget_pages text %q accepted", bad_text)
	}

	// Text "unbounded" on ceiling, growth_reserve, or disk_processes_pages is refused:
	// no form can remove the safety ceiling or make an unbounded reservation.
	ceil_txt, _, _ := module_budget_policy_of(values_of({{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT}}, nil))
	testing.expect(t, !ceil_txt.has_ceiling && ceil_txt.ceiling_pages == 0)
	res_txt, _, _ := module_budget_policy_of(values_of({{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT}}, nil))
	testing.expect(t, !res_txt.has_growth_reserve && res_txt.growth_reserve_pages == 0)
	disk_txt, _ := root_plan_of(values_of({{name = DISK_PROCESSES_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT}}, nil))
	testing.expect(t, disk_txt.disk_processes_pages == 0)

	// Unbounded + share_parts conflicts: both are dropped so neither holds.
	unb_share, unb_conflict, _ := module_budget_policy_of(values_of({
		{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT},
		{name = BUDGET_SHARE_PARTS_FIELD, kind = .Choose, value = 128},
	}, nil))
	testing.expect(t, unb_conflict && unb_share.size_kind == .Default && unb_share.share_parts == 0)

	// Unbounded + growth_reserve without explicit ceiling drops the reserve.
	unb_res, _, unb_res_over := module_budget_policy_of(values_of({
		{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT},
		{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose, value = 1024},
	}, nil))
	testing.expect(t, unb_res.size_kind == .Unbounded && unb_res_over && !unb_res.has_growth_reserve)

	// Lock-over-default precedence across Word and Text on budget_pages.
	lock_unb, _, _ := module_budget_policy_of(
		values_of({{name = BUDGET_PAGES_FIELD, kind = .Choose, value = 4096}}, {{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT}}),
	)
	testing.expect(t, lock_unb.size_kind == .Unbounded && lock_unb.pages == 0)
	lock_num, _, _ := module_budget_policy_of(
		values_of({{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT}}, {{name = BUDGET_PAGES_FIELD, kind = .Choose, value = 4096}}),
	)
	testing.expect(t, lock_num.size_kind == .Pages && lock_num.pages == 4096)

	// Unbounded row gives has_size == false from planned_pages_of, so start
	// reserves floor and default size identically to no row.
	unb, c0, o0 := module_budget_policy_of(values_of({{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT}}, nil))
	testing.expect(t, !c0 && !o0 && unb.size_kind == .Unbounded)
	start_pages, has_size := planned_pages_of(unb, 200_000)
	testing.expect(t, !has_size && start_pages == 0)

	// effective_growth_of: zero safety ceiling refuses all growth.
	c_zero, r_zero, cap_zero := effective_growth_of(unb, 0, true)
	testing.expect(t, c_zero == 0 && r_zero == 0 && !cap_zero)

	// Default policy with no start option gets no growth.
	c_def, r_def, cap_def := effective_growth_of({}, 50_000, false)
	testing.expect(t, c_def == 0 && r_def == 0 && !cap_def)

	// Unbounded row with no explicit ceiling uses safety ceiling (machine share).
	c_unb, r_unb, cap_unb := effective_growth_of(unb, 50_000, false)
	testing.expect(t, c_unb == 50_000 && r_unb == 0 && !cap_unb)

	// Unbounded row can lower its ceiling below the machine share.
	unb_low, _, _ := module_budget_policy_of(values_of({
		{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT},
		{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose, value = 16_384},
	}, nil))
	c_low, r_low, cap_low := effective_growth_of(unb_low, 50_000, false)
	testing.expect(t, c_low == 16_384 && r_low == 0 && !cap_low)

	// Unbounded row at exact safety ceiling is not capped; +1 and max are capped.
	unb_eq, _, _ := module_budget_policy_of(values_of({
		{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT},
		{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose, value = 50_000},
	}, nil))
	c_eq, _, cap_eq := effective_growth_of(unb_eq, 50_000, false)
	testing.expect(t, c_eq == 50_000 && !cap_eq)

	for high in ([?]u64{50_001, BUDGET_PAGES_MOST}) {
		unb_high, _, _ := module_budget_policy_of(values_of({
			{name = BUDGET_PAGES_FIELD, kind = .Choose_Text, text = BUDGET_PAGES_UNBOUNDED_TEXT},
			{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose, value = high},
			{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose, value = high},
		}, nil))
		c_hi, r_hi, cap_hi := effective_growth_of(unb_high, 50_000, false)
		testing.expectf(t, c_hi == 50_000 && r_hi == 50_000 && cap_hi, "high ceiling %d not capped", high)
	}

	// Bounded row with ceiling above machine share is also capped at machine share.
	bounded_high, _, _ := module_budget_policy_of(values_of({
		{name = BUDGET_PAGES_FIELD, kind = .Choose, value = 4096},
		{name = BUDGET_CEILING_PAGES_FIELD, kind = .Choose, value = 90_000},
		{name = BUDGET_GROWTH_RESERVE_PAGES_FIELD, kind = .Choose, value = 60_000},
	}, nil))
	c_bh, r_bh, cap_bh := effective_growth_of(bounded_high, 50_000, false)
	testing.expect(t, c_bh == 50_000 && r_bh == 50_000 && cap_bh)

	// Start option (start_unbounded = true) enables growth up to safety ceiling
	// when no plan ceiling exists, and never raises above a lower plan ceiling.
	c_opt, r_opt, cap_opt := effective_growth_of({}, 50_000, true)
	testing.expect(t, c_opt == 50_000 && r_opt == 0 && !cap_opt)
	c_opt_low, _, cap_opt_low := effective_growth_of(unb_low, 50_000, true)
	testing.expect(t, c_opt_low == 16_384 && !cap_opt_low)

	// Extreme safety_ceiling_pages edges (1 and max(u64)) and a synthetic
	// policy with has_ceiling = true and ceiling_pages = 0 (fails closed to 0).
	c_one, r_one, cap_one := effective_growth_of(unb, 1, false)
	testing.expect(t, c_one == 1 && r_one == 0 && !cap_one)
	c_one_cap, _, cap_one_hi := effective_growth_of(unb_low, 1, false)
	testing.expect(t, c_one_cap == 1 && cap_one_hi)

	c_max, r_max, cap_max := effective_growth_of(unb, max(u64), false)
	testing.expect(t, c_max == max(u64) && r_max == 0 && !cap_max)
	c_max_low, _, cap_max_low := effective_growth_of(unb_low, max(u64), false)
	testing.expect(t, c_max_low == 16_384 && !cap_max_low)

	zero_ceil_policy := Module_Budget_Policy{
		size_kind            = .Unbounded,
		has_ceiling          = true,
		ceiling_pages        = 0,
		has_growth_reserve   = true,
		growth_reserve_pages = 512,
	}
	c_zceil, r_zceil, cap_zceil := effective_growth_of(zero_ceil_policy, 50_000, true)
	testing.expect(t, c_zceil == 0 && r_zceil == 0 && !cap_zceil)
}

// Merging budget policy layers keeps base fields whenever a higher-precedence
// layer omits them (such as a live plan that only changes a non-budget setting
// of the same owner), overrides explicitly set fields, and drops an inherited
// growth reserve if a lower override ceiling falls below it.
@(test)
module_budget_policy_merge_precedence_and_edges :: proc(t: ^testing.T) {
	base := Module_Budget_Policy {
		size_kind            = .Pages,
		pages                = 16_384,
		ceiling_pages        = 32_768,
		has_ceiling          = true,
		growth_reserve_pages = 8_192,
		has_growth_reserve   = true,
		processor            = 2_000_000,
		has_processor        = true,
		log_records          = 40,
		has_log_records      = true,
		screen_pages         = 2_048,
		has_screen_pages     = true,
	}

	// Empty override preserves every base field.
	testing.expect_value(t, module_budget_policy_merge({}, base), base)
	// Empty base returns override unchanged.
	testing.expect_value(t, module_budget_policy_merge(base, {}), base)

	// Override with unbounded size and 0 log records replaces size and log
	// records while inheriting processor and screen pages.
	unb_override := Module_Budget_Policy {
		size_kind       = .Unbounded,
		log_records     = 0,
		has_log_records = true,
	}
	merged_unb := module_budget_policy_merge(unb_override, base)
	testing.expect(t, merged_unb.size_kind == .Unbounded && merged_unb.pages == 0 && merged_unb.share_parts == 0)
	testing.expect(t, merged_unb.has_log_records && merged_unb.log_records == 0)
	testing.expect(t, merged_unb.has_processor && merged_unb.processor == 2_000_000)
	testing.expect(t, merged_unb.has_screen_pages && merged_unb.screen_pages == 2_048)
	testing.expect(t, merged_unb.has_ceiling && merged_unb.ceiling_pages == 32_768)
	testing.expect(t, merged_unb.has_growth_reserve && merged_unb.growth_reserve_pages == 8_192)

	// Override lowering ceiling below base's growth reserve drops the reserve.
	low_ceil := Module_Budget_Policy {
		ceiling_pages = 4_096,
		has_ceiling   = true,
	}
	merged_low := module_budget_policy_merge(low_ceil, base)
	testing.expect(t, merged_low.has_ceiling && merged_low.ceiling_pages == 4_096)
	testing.expect(t, !merged_low.has_growth_reserve && merged_low.growth_reserve_pages == 0)
	testing.expect(t, merged_low.size_kind == .Pages && merged_low.pages == 16_384)
}

// script_fonts_cache_key and script_fonts_manifest_hash enforce strict
// 64-lowercase-hex non-zero parsing and lock-over-default precedence.
@(test)
script_fonts_cache_key_and_manifest_hash_borders :: proc(t: ^testing.T) {
	bad_keys := [?]string{
		"",
		"a",
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde",   // 63 chars
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0", // 65 chars
		"0000000000000000000000000000000000000000000000000000000000000000",  // all zero
		"ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",  // uppercase
		"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",  // non-hex
	}
	for bad in bad_keys {
		_, ok := hex_key_parse(bad)
		testing.expectf(t, !ok, "bad hex key %q accepted", bad)
		plan, _ := root_plan_of(values_of({
			{name = SCRIPT_FONTS_CACHE_KEY_FIELD, kind = .Choose_Text, text = bad},
			{name = SCRIPT_FONTS_MANIFEST_HASH_FIELD, kind = .Choose_Text, text = bad},
		}, nil))
		testing.expect(t, plan.script_fonts_cache_key == {} && plan.script_fonts_cache_key_layer == .Contract_Default)
		testing.expect(t, plan.script_fonts_manifest_hash == {} && plan.script_fonts_manifest_hash_layer == .Contract_Default)
	}

	key_a := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	key_b := "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	parsed_a, ok_a := hex_key_parse(key_a)
	parsed_b, ok_b := hex_key_parse(key_b)
	testing.expect(t, ok_a && ok_b && parsed_a[0] == 0x01 && parsed_a[31] == 0xef && parsed_b[0] == 0xfe)

	plan, refused := root_plan_of(values_of({
		{name = SCRIPT_FONTS_CACHE_KEY_FIELD, kind = .Choose_Text, text = key_a},
		{name = SCRIPT_FONTS_MANIFEST_HASH_FIELD, kind = .Choose_Text, text = key_a},
	}, {
		{name = SCRIPT_FONTS_CACHE_KEY_FIELD, kind = .Choose_Text, text = key_b},
	}))
	testing.expect(t, !refused)
	testing.expect(t, plan.script_fonts_cache_key == parsed_b && plan.script_fonts_cache_key_layer == .Locked)
	testing.expect(t, plan.script_fonts_manifest_hash == parsed_a && plan.script_fonts_manifest_hash_layer == .Plan_Default)
	testing.expect(t, root_text_field_is(SCRIPT_FONTS_CACHE_KEY_FIELD))
	testing.expect(t, root_text_field_is(SCRIPT_FONTS_MANIFEST_HASH_FIELD))
	testing.expect(t, !root_text_field_is(BUDGET_SHARE_FIELD))
}
