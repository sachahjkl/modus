#+build !freestanding
package root_plan_values

import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/memory_screen"
import "modus:contract/plan_values"

@(private = "file")
values_of :: proc(defaults, locks: []chosen_values.Change) -> (values: plan_values.Owner_Values) {
	defaults_bytes := make([]u8, chosen_values.HEADER_SIZE + 16 * chosen_values.ENTRY_SIZE, context.temp_allocator)
	locks_bytes := make([]u8, chosen_values.HEADER_SIZE + 16 * chosen_values.ENTRY_SIZE, context.temp_allocator)
	written, _ := chosen_values.write_record({}, defaults, defaults_bytes)
	values.defaults, _ = chosen_values.read_record(defaults_bytes[:written])
	written, _ = chosen_values.write_record({}, locks, locks_bytes)
	values.locks, _ = chosen_values.read_record(locks_bytes[:written])
	return values
}

// A share and sizes outside their borders hold as no value, at each edge; a
// start size past the largest size gives the four defaults together; the
// values that pass hold, a lock over a default. No value is the defaults.
@(test)
the_plan_of_the_root_is_read_at_its_borders :: proc(t: ^testing.T) {
	none, none_refused := root_plan_of({})
	testing.expect(t, none == ROOT_PLAN_DEFAULTS && !none_refused)
	for share in ([?]u64{0, BUDGET_SHARE_MOST + 1, max(u64)}) {
		plan, _ := root_plan_of(values_of({{name = BUDGET_SHARE_FIELD, kind = .Choose, value = share}}, nil))
		testing.expectf(t, plan.budget_share == BUDGET_SHARE_DEFAULT && plan.budget_share_layer == .Contract_Default, "the share %d is taken", share)
	}
	for width in ([?]u64{0, u64(memory_screen.MIN_WIDTH) - 1, u64(memory_screen.MAX_WIDTH) + 1, max(u64)}) {
		plan, _ := root_plan_of(values_of({{name = MEMORY_SCREEN_START_WIDTH_FIELD, kind = .Choose, value = width}}, nil))
		testing.expectf(t, plan.memory_screen_start_width == ROOT_PLAN_DEFAULTS.memory_screen_start_width, "the width %d is taken", width)
	}
	past, refused := root_plan_of(values_of({{name = MEMORY_SCREEN_START_WIDTH_FIELD, kind = .Choose, value = 1280}, {name = MEMORY_SCREEN_MOST_WIDTH_FIELD, kind = .Choose, value = 1024}}, nil))
	testing.expect(t, refused && past.memory_screen_start_width == ROOT_PLAN_DEFAULTS.memory_screen_start_width && past.memory_screen_most_width == ROOT_PLAN_DEFAULTS.memory_screen_most_width)
	edges, edges_refused := root_plan_of(values_of({{name = BUDGET_SHARE_FIELD, kind = .Choose, value = BUDGET_SHARE_MOST}, {name = MEMORY_SCREEN_START_WIDTH_FIELD, kind = .Choose, value = u64(memory_screen.MIN_WIDTH)}, {name = MEMORY_SCREEN_START_HEIGHT_FIELD, kind = .Choose, value = u64(memory_screen.MIN_HEIGHT)}}, {{name = MEMORY_SCREEN_MOST_WIDTH_FIELD, kind = .Choose, value = 1280}}))
	testing.expect(t, !edges_refused && edges.budget_share == BUDGET_SHARE_MOST && edges.budget_share_layer == .Plan_Default)
	testing.expect(t, edges.memory_screen_start_width == memory_screen.MIN_WIDTH && edges.memory_screen_most_width == 1280 && edges.memory_screen_layer == .Locked)
	for blocks in ([?]u64{0, STORE_BLOCKS_MOST + 1, max(u64)}) {
		_, found := store_blocks_of(values_of({{name = STORE_BLOCKS_FIELD, kind = .Choose, value = blocks}}, nil))
		testing.expectf(t, !found, "the quota %d is taken", blocks)
	}
	quota, quota_found := store_blocks_of(values_of(nil, {{name = STORE_BLOCKS_FIELD, kind = .Choose, value = STORE_BLOCKS_LEAST}}))
	testing.expect(t, quota_found && quota == STORE_BLOCKS_LEAST)
}
