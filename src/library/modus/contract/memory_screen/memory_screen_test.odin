#+build !freestanding
package memory_screen

import "core:testing"

@(test)
source_of_word_refuses_unknown_and_none :: proc(t: ^testing.T) {
	refused := [?]u64{u64(Source.None), u64(max(Source)) + 1, 1 << 32, max(u64)}
	for word in refused {
		src, ok := source_of_word(word)
		testing.expectf(t, !ok && src == .None, "word %d must be refused", word)
	}
	for member in Source {
		if member == .None {
			continue
		}
		src, ok := source_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, src, member)
	}
}

@(test)
geometry_validate_refuses_zero_overflow_misaligned_and_oversized :: proc(t: ^testing.T) {
	// Zero dimensions.
	{
		geo, err := geometry_validate(0, 0, 0)
		testing.expect_value(t, err, Validation_Error.Zero_Dimension)
		testing.expect_value(t, geo, Geometry{})
		geo, err = geometry_validate(0, MIN_HEIGHT, packed_stride(MIN_WIDTH) > 0 ? u64(packed_stride(MIN_WIDTH)) : 1280)
		testing.expect_value(t, err, Validation_Error.Zero_Dimension)
		geo, err = geometry_validate(MIN_WIDTH, 0, u64(MIN_WIDTH * BYTES_PER_PIXEL))
		testing.expect_value(t, err, Validation_Error.Zero_Dimension)
	}

	// Integer overflow in width * 4, width * height, width * height * 4, or height * stride.
	overflow_cases := [?][3]u64{
		{max(u64), 1, 4},
		{(u64(1) << 62) + 1, 1, 4},
		{u64(1) << 32, u64(1) << 32, 4},
		{u64(1) << 31, u64(1) << 32, 4},
		{MAX_WIDTH, MAX_HEIGHT, max(u64)},
		{MAX_WIDTH, MAX_HEIGHT, (max(u64) / MAX_HEIGHT) + 1},
	}
	for item in overflow_cases {
		geo, err := geometry_validate(item[0], item[1], item[2])
		testing.expectf(t, err == .Size_Overflow && geo == Geometry{}, "case %v must return Size_Overflow, got %v", item, err)
	}

	// Below minimum pixel bounds.
	for item in ([?][3]u64{
		{1, 1, 4},
		{MIN_WIDTH - 1, MIN_HEIGHT, (MIN_WIDTH - 1) * BYTES_PER_PIXEL},
		{MIN_WIDTH, MIN_HEIGHT - 1, MIN_WIDTH * BYTES_PER_PIXEL},
	}) {
		geo, err := geometry_validate(item[0], item[1], item[2])
		testing.expectf(t, err == .Below_Minimum && geo == Geometry{}, "case %v must return Below_Minimum, got %v", item, err)
	}

	// Above maximum pixel bounds (one past MAX_WIDTH and MAX_HEIGHT).
	for item in ([?][3]u64{
		{MAX_WIDTH + 1, MAX_HEIGHT, (MAX_WIDTH + 1) * BYTES_PER_PIXEL},
		{MAX_WIDTH, MAX_HEIGHT + 1, MAX_WIDTH * BYTES_PER_PIXEL},
		{MAX_WIDTH + 1, MAX_HEIGHT + 1, (MAX_WIDTH + 1) * BYTES_PER_PIXEL},
	}) {
		geo, err := geometry_validate(item[0], item[1], item[2])
		testing.expectf(t, err == .Above_Maximum && geo == Geometry{}, "case %v must return Above_Maximum, got %v", item, err)
	}

	// Misaligned strides (+1, +2, +3 bytes).
	for offset in ([?]u64{1, 2, 3}) {
		geo, err := geometry_validate(640, 480, 640 * BYTES_PER_PIXEL + offset)
		testing.expectf(t, err == .Stride_Misaligned && geo == Geometry{}, "offset %d must return Stride_Misaligned, got %v", offset, err)
	}

	// Stride too small (0, or 4 bytes short).
	for bad_stride in ([?]u64{0, 640 * BYTES_PER_PIXEL - 4}) {
		geo, err := geometry_validate(640, 480, bad_stride)
		testing.expectf(t, err == .Stride_Too_Small && geo == Geometry{}, "stride %d must return Stride_Too_Small, got %v", bad_stride, err)
	}

	// Over byte budget (explicit small budget, zero budget, or padded stride exceeding MAX_FRAMEBUFFER_BYTES).
	{
		_, err := geometry_validate(640, 480, 640 * BYTES_PER_PIXEL, 0)
		testing.expect_value(t, err, Validation_Error.Over_Byte_Budget)
		exact := u64(640) * 480 * BYTES_PER_PIXEL
		_, err = geometry_validate(640, 480, 640 * BYTES_PER_PIXEL, exact - 1)
		testing.expect_value(t, err, Validation_Error.Over_Byte_Budget)
		// Padded stride at max resolution exceeds MAX_FRAMEBUFFER_BYTES even if caller passes max(u64) budget.
		_, err = geometry_validate(MAX_WIDTH, MAX_HEIGHT, MAX_WIDTH * BYTES_PER_PIXEL + 64, max(u64))
		testing.expect_value(t, err, Validation_Error.Over_Byte_Budget)
	}

	// Exact valid bounds: min, max, and valid padded stride within budget.
	{
		geo, err := geometry_validate(MIN_WIDTH, MIN_HEIGHT, u64(packed_stride(MIN_WIDTH)))
		testing.expect_value(t, err, Validation_Error.None)
		testing.expect_value(t, geo.width, u32(MIN_WIDTH))
		testing.expect_value(t, geo.height, u32(MIN_HEIGHT))
		testing.expect_value(t, geo.byte_size, u64(MIN_WIDTH) * MIN_HEIGHT * BYTES_PER_PIXEL)
		testing.expect_value(t, geo.page_count, u64(75))
	}
	{
		geo, err := geometry_validate(MAX_WIDTH, MAX_HEIGHT, u64(packed_stride(MAX_WIDTH)))
		testing.expect_value(t, err, Validation_Error.None)
		testing.expect_value(t, geo.byte_size, MAX_FRAMEBUFFER_BYTES)
		testing.expect_value(t, geo.page_count, MAX_FRAMEBUFFER_PAGES)
	}
	{
		padded_stride := u64(640 * BYTES_PER_PIXEL + 64)
		geo, err := geometry_validate(640, 480, padded_stride, 480 * padded_stride)
		testing.expect_value(t, err, Validation_Error.None)
		testing.expect_value(t, geo.stride_bytes, u32(padded_stride))
		testing.expect_value(t, geo.byte_size, 480 * padded_stride)
	}
}

@(test)
damage_clipping_merging_and_take_never_drop_pixels :: proc(t: ^testing.T) {
	screen: Memory_Screen
	testing.expect_value(t, screen_init(&screen, 800, 600, u64(packed_stride(800))), Validation_Error.None)
	// Initial state has one full-screen damage rect.
	testing.expect_value(t, screen.damage.count, 1)
	testing.expect_value(t, screen.damage.rectangles[0], Damage_Rectangle{0, 0, 800, 600})

	// Empty out slice must NOT discard pending damage.
	taken, merged := screen_damage_take(&screen, nil)
	testing.expect(t, taken == 0 && !merged)
	testing.expect_value(t, screen.damage.count, 1)

	out: [DAMAGE_CAPACITY]Damage_Rectangle
	taken, merged = screen_damage_take(&screen, out[:])
	testing.expect(t, taken == 1 && !merged)
	testing.expect_value(t, out[0], Damage_Rectangle{0, 0, 800, 600})
	testing.expect_value(t, screen.damage.count, 0)

	// Empty, inverted, and out-of-screen rectangles are refused.
	testing.expect(t, !screen_damage_add(&screen, {10, 10, 10, 20}))
	testing.expect(t, !screen_damage_add(&screen, {20, 10, 10, 20}))
	testing.expect(t, !screen_damage_add(&screen, {800, 0, 900, 100}))
	testing.expect(t, !screen_damage_add(&screen, {0, 600, 100, 700}))
	testing.expect_value(t, screen.damage.count, 0)

	// Add DAMAGE_CAPACITY distinct rectangles, including one that clips to screen bounds.
	for i in 0 ..< DAMAGE_CAPACITY {
		x := u32(i * 40)
		testing.expect(t, screen_damage_add(&screen, {x, 10, x + 20, 30}))
	}
	testing.expect_value(t, screen.damage.count, DAMAGE_CAPACITY)
	testing.expect_value(t, screen.damage.merges, u64(0))

	// A contained sub-rectangle does not force a merge.
	testing.expect(t, screen_damage_add(&screen, {5, 15, 15, 25}))
	testing.expect_value(t, screen.damage.count, DAMAGE_CAPACITY)
	testing.expect_value(t, screen.damage.merges, u64(0))

	// One past DAMAGE_CAPACITY merges into a single bounding rectangle enclosing all.
	testing.expect(t, screen_damage_add(&screen, {750, 550, 900, 700})) // Clipped to (750, 550, 800, 600).
	testing.expect_value(t, screen.damage.count, 1)
	testing.expect_value(t, screen.damage.merges, u64(1))
	testing.expect_value(t, screen.damage.rectangles[0], Damage_Rectangle{0, 10, 800, 600})

	// Test screen_damage_take collapsing into a 1-element caller buffer.
	damage_reset(&screen.damage)
	testing.expect(t, screen_damage_add(&screen, {10, 20, 30, 40}))
	testing.expect(t, screen_damage_add(&screen, {100, 200, 150, 250}))
	small_out: [1]Damage_Rectangle
	taken, merged = screen_damage_take(&screen, small_out[:])
	testing.expect(t, taken == 1 && merged)
	testing.expect_value(t, small_out[0], Damage_Rectangle{10, 20, 150, 250})
	testing.expect_value(t, screen.damage.count, 0)
}

@(test)
viewer_resize_transitions_are_atomic_and_last_valid_holds :: proc(t: ^testing.T) {
	// Inactive screen refuses resize.
	inactive: Memory_Screen
	testing.expect_value(t, screen_request_viewer_resize(&inactive, 800, 600, u64(packed_stride(800)), true), Validation_Error.Not_Active)
	changed, _ := screen_commit_resize(&inactive)
	testing.expect(t, !changed)

	// Init with invalid source refuses without activating.
	testing.expect_value(t, screen_init(&inactive, 800, 600, u64(packed_stride(800)), MAX_FRAMEBUFFER_BYTES, .None), Validation_Error.Invalid_Source)
	testing.expect(t, !inactive.active)

	// Start active screen at 1280x720 with a tight 4 MiB budget.
	screen: Memory_Screen
	budget := u64(4 * 1024 * 1024)
	testing.expect_value(t, screen_init(&screen, 1280, 720, u64(packed_stride(1280)), budget, .Start_List), Validation_Error.None)
	damage_reset(&screen.damage)
	testing.expect_value(t, screen.generation, u64(1))

	// Viewer without input authority is refused; geometry & damage untouched.
	testing.expect_value(t, screen_request_viewer_resize(&screen, 800, 600, u64(packed_stride(800)), false, 1), Validation_Error.Input_Not_Allowed)
	testing.expect_value(t, screen.resize_refusals, u64(1))
	testing.expect(t, !screen.pending_resize.pending)
	testing.expect_value(t, screen.geometry.width, u32(1280))

	// Two valid viewer requests before the next frame: second wins ("last request holds").
	testing.expect_value(t, screen_request_viewer_resize(&screen, 800, 600, u64(packed_stride(800)), true, 10), Validation_Error.None)
	testing.expect_value(t, screen_request_viewer_resize(&screen, 1024, 768, u64(packed_stride(1024)), true, 11), Validation_Error.None)
	testing.expect(t, screen.pending_resize.pending)
	testing.expect_value(t, screen.pending_resize.viewer_serial, u64(11))
	testing.expect_value(t, screen.pending_resize.geometry.width, u32(1024))

	// An invalid request (1920x1080 exceeds the 4 MiB budget) must NOT corrupt active OR pending geometry.
	testing.expect_value(t, screen_request_viewer_resize(&screen, MAX_WIDTH, MAX_HEIGHT, u64(packed_stride(MAX_WIDTH)), true, 12), Validation_Error.Over_Byte_Budget)
	testing.expect_value(t, screen.resize_refusals, u64(2))
	testing.expect_value(t, screen.geometry.width, u32(1280))
	testing.expect(t, screen.pending_resize.pending)
	testing.expect_value(t, screen.pending_resize.viewer_serial, u64(11))
	testing.expect_value(t, screen.pending_resize.geometry.width, u32(1024))

	// Commit transitions atomically to 1024x768, bumps generation, marks full screen damaged.
	geo: Geometry
	changed, geo = screen_commit_resize(&screen)
	testing.expect(t, changed)
	testing.expect_value(t, geo.width, u32(1024))
	testing.expect_value(t, geo.height, u32(768))
	testing.expect_value(t, screen.source, Source.Viewer)
	testing.expect_value(t, screen.generation, u64(2))
	testing.expect_value(t, screen.resize_commits, u64(1))
	testing.expect(t, !screen.pending_resize.pending)
	testing.expect_value(t, screen.damage.count, 1)
	testing.expect_value(t, screen.damage.rectangles[0], Damage_Rectangle{0, 0, 1024, 768})

	// Second commit with nothing pending is a no-op.
	changed, _ = screen_commit_resize(&screen)
	testing.expect(t, !changed)
	testing.expect_value(t, screen.generation, u64(2))

	// Atomic screen_apply_resize refusal leaves generation and geometry untouched.
	testing.expect_value(t, screen_apply_resize(&screen, 640, 480, 640 * BYTES_PER_PIXEL + 1, true), Validation_Error.Stride_Misaligned)
	testing.expect_value(t, screen.generation, u64(2))
	testing.expect_value(t, screen.geometry.width, u32(1024))

	// Valid screen_apply_resize commits immediately.
	testing.expect_value(t, screen_apply_resize(&screen, 640, 480, u64(packed_stride(640)), true, 20), Validation_Error.None)
	testing.expect_value(t, screen.generation, u64(3))
	testing.expect_value(t, screen.geometry.width, u32(640))
	testing.expect_value(t, screen.geometry.height, u32(480))
}

// The screen of memory follows the screen in force: 1440p, 4K, 5K and 8K
// pass with the bytes of their size, one pixel past 8K is refused, and a
// byte budget one byte short of a size refuses it.
@(test)
memory_screen_takes_screens_up_to_8k_within_its_byte_budget :: proc(t: ^testing.T) {
	testing.expect_value(t, MAX_WIDTH, 7680)
	testing.expect_value(t, MAX_HEIGHT, 4320)
	testing.expect_value(t, DEFAULT_WIDTH, 1920)
	sizes := [?][2]u64{{1920, 1080}, {2560, 1440}, {3840, 2160}, {5120, 2880}, {7680, 4320}}
	for size in sizes {
		bytes := size[0] * size[1] * BYTES_PER_PIXEL
		geo, err := geometry_validate(size[0], size[1], size[0] * BYTES_PER_PIXEL, bytes)
		testing.expectf(t, err == .None && geo.byte_size == bytes, "%v gave %v", size, err)
		_, short := geometry_validate(size[0], size[1], size[0] * BYTES_PER_PIXEL, bytes - 1)
		testing.expectf(t, short == .Over_Byte_Budget, "%v one byte short gave %v", size, short)
	}
	_, wide := geometry_validate(MAX_WIDTH + 1, 1080, (MAX_WIDTH + 1) * BYTES_PER_PIXEL, max(u64))
	testing.expect_value(t, wide, Validation_Error.Above_Maximum)
	_, tall := geometry_validate(1920, MAX_HEIGHT + 1, 1920 * BYTES_PER_PIXEL, max(u64))
	testing.expect_value(t, tall, Validation_Error.Above_Maximum)
}

// The border of a cause refuses None and each word past the members, and
// takes each member.
@(test)
resize_refusal_words_at_their_edges :: proc(t: ^testing.T) {
	for word in ([?]u64{0, u64(max(Resize_Refusal)) + 1, u64(max(Resize_Refusal)) + 2, u64(max(u32)), max(u64)}) {
		_, ok := resize_refusal_of_word(word)
		testing.expectf(t, !ok, "the word %d was taken as a cause", word)
	}
	for member in Resize_Refusal {
		if member == .None {
			continue
		}
		refusal, ok := resize_refusal_of_word(u64(member))
		testing.expect(t, ok && refusal == member)
		testing.expect(t, RESIZE_REFUSAL_SENTENCES[member] != "")
	}
}

// The decision of the compositor: a screen of a device first, then each
// side at its bounds, then the size in force, then the budget at its
// edge; a size that fits comes last.
@(test)
resize_decide_refuses_at_each_edge :: proc(t: ^testing.T) {
	refusal, same := resize_decide(false, 1920, 1080, 1920, 1080, max(u64))
	testing.expect(t, refusal == .Device_Screen && !same)
	sizes_out := [?][2]u64{{0, 1080}, {1920, 0}, {MIN_WIDTH - 1, 1080}, {1920, MIN_HEIGHT - 1}, {MAX_WIDTH + 1, 1080}, {1920, MAX_HEIGHT + 1}, {max(u64), max(u64)}}
	for size in sizes_out {
		refusal, same = resize_decide(true, size[0], size[1], 1920, 1080, max(u64))
		testing.expectf(t, refusal == .Outside_Bounds && !same, "%v gave %v", size, refusal)
	}
	refusal, same = resize_decide(true, 1920, 1080, 1920, 1080, 0)
	testing.expect(t, refusal == .None && same, "the size in force is no change, whatever the budget")
	// While a trusted dialog or a local-input-only window shows, a size
	// change is refused before the budget check, while the size in force
	// stays a no-op and device/bounds checks still run first.
	refusal, same = resize_decide(false, 2560, 1440, 1920, 1080, max(u64), blocked = true)
	testing.expect(t, refusal == .Device_Screen && !same)
	refusal, same = resize_decide(true, MAX_WIDTH + 1, 1080, 1920, 1080, max(u64), blocked = true)
	testing.expect(t, refusal == .Outside_Bounds && !same)
	refusal, same = resize_decide(true, 1920, 1080, 1920, 1080, 0, blocked = true)
	testing.expect(t, refusal == .None && same, "the size in force stays a no-op while blocked")
	refusal, same = resize_decide(true, 2560, 1440, 1920, 1080, max(u64), blocked = true)
	testing.expect(t, refusal == .Trusted_Surface && !same)
	refusal, same = resize_decide(true, 2560, 1440, 1920, 1080, 0, blocked = true)
	testing.expect(t, refusal == .Trusted_Surface && !same, "Trusted_Surface runs before Compositor_Budget")
	needed := COMPOSITOR_PICTURES * picture_pages(2560, 1440)
	testing.expect_value(t, needed, 7200)
	refusal, same = resize_decide(true, 2560, 1440, 1920, 1080, needed - 1)
	testing.expect(t, refusal == .Compositor_Budget && !same)
	refusal, same = resize_decide(true, 2560, 1440, 1920, 1080, needed)
	testing.expect(t, refusal == .None && !same)
	for size in ([?][2]u64{{MIN_WIDTH, MIN_HEIGHT}, {MAX_WIDTH, MAX_HEIGHT}}) {
		refusal, same = resize_decide(true, size[0], size[1], 1920, 1080, max(u64))
		testing.expect(t, refusal == .None && !same)
	}
}

// The decision of the service: the bounds, then its pages at the edge,
// with a sum that would wrap.
@(test)
service_resize_decide_refuses_at_each_edge :: proc(t: ^testing.T) {
	testing.expect_value(t, service_resize_decide(MAX_WIDTH + 1, 1080, 1, 0, max(u64)), Resize_Refusal.Outside_Bounds)
	testing.expect_value(t, service_resize_decide(2560, 1440, 1000, 400, 599), Resize_Refusal.Service_Budget)
	testing.expect_value(t, service_resize_decide(2560, 1440, 1000, max(u64), max(u64)), Resize_Refusal.Service_Budget)
	testing.expect_value(t, service_resize_decide(2560, 1440, 1000, 400, 600), Resize_Refusal.None)
	testing.expect_value(t, picture_pages(MAX_WIDTH + 1, 1080), 0)
	testing.expect_value(t, picture_pages(1920, 1080), 2025)
}

// The least time between two changes: an ask of a viewer and a change of
// the screen each hold their second, at its edge; 0 is no time yet, and a
// clock that went back counts as age 0.
@(test)
resize_interval_at_its_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, resize_interval_decide(5000, 0, 0), Resize_Refusal.None)
	testing.expect_value(t, resize_interval_decide(5000, 4001, 0), Resize_Refusal.Too_Soon)
	testing.expect_value(t, resize_interval_decide(5000, 4000, 0), Resize_Refusal.None)
	testing.expect_value(t, resize_interval_decide(5000, 0, 4001), Resize_Refusal.Too_Soon)
	testing.expect_value(t, resize_interval_decide(5000, 0, 4000), Resize_Refusal.None)
	testing.expect_value(t, resize_interval_decide(5000, 9000, 0), Resize_Refusal.Too_Soon)
	testing.expect_value(t, resize_interval_decide(max(u64), max(u64) - RESIZE_INTERVAL_MILLISECONDS, max(u64) - RESIZE_INTERVAL_MILLISECONDS), Resize_Refusal.None)
}

// A growth that breaks each rule, in its order: a sender that is not the
// service, a screen of a device, each side past its bounds, two extra
// budgets held by either process (and more, as a count past the bound),
// each share one page past; then each share at its edge, which passes with
// the pages of each process, also with one extra budget held by each.
@(test)
a_growth_of_the_budgets_is_refused_at_each_edge :: proc(t: ^testing.T) {
	good := Grow_Facts{from_service = true, screen_of_memory = true, width = 2560, height = 1440, compositor_paid = 30000, service_paid = 8000, share = 50000}
	compositor_pages := compositor_grow_pages(2560, 1440)
	service_pages := service_copies_pages(2560, 1440)
	testing.expect_value(t, compositor_pages, 7200)
	testing.expect_value(t, service_pages, 1 + 7200 + 3600)
	cases := [?]struct {
		change:  proc(facts: ^Grow_Facts),
		refusal: Grow_Refusal,
	} {
		{proc(facts: ^Grow_Facts) {facts.from_service = false}, .Not_The_Service},
		{proc(facts: ^Grow_Facts) {facts.screen_of_memory = false}, .No_Screen_Of_Memory},
		{proc(facts: ^Grow_Facts) {facts.width = MAX_WIDTH + 1}, .Outside_Bounds},
		{proc(facts: ^Grow_Facts) {facts.max_width = 2559}, .Outside_Bounds},
		{proc(facts: ^Grow_Facts) {facts.max_height = 1439}, .Outside_Bounds},
		{proc(facts: ^Grow_Facts) {facts.height = MIN_HEIGHT - 1}, .Outside_Bounds},
		{proc(facts: ^Grow_Facts) {facts.width, facts.height = max(u64), max(u64)}, .Outside_Bounds},
		{proc(facts: ^Grow_Facts) {facts.now, facts.last_growth_at = 5000, 4001}, .Too_Soon},
		{proc(facts: ^Grow_Facts) {facts.now, facts.last_growth_at = 5000, 9000}, .Too_Soon},
		{proc(facts: ^Grow_Facts) {facts.now, facts.last_growth_at = 5000, 4001; facts.compositor_extras = EXTRAS_PER_PROCESS}, .Too_Soon},
		{proc(facts: ^Grow_Facts) {facts.compositor_extras = EXTRAS_PER_PROCESS}, .Compositor_Replacing},
		{proc(facts: ^Grow_Facts) {facts.compositor_extras = max(int)}, .Compositor_Replacing},
		{proc(facts: ^Grow_Facts) {facts.service_extras = EXTRAS_PER_PROCESS}, .Service_Replacing},
		{proc(facts: ^Grow_Facts) {facts.service_extras = max(int)}, .Service_Replacing},
		{proc(facts: ^Grow_Facts) {facts.compositor_paid = facts.share - compositor_grow_pages(2560, 1440) + 1}, .Past_Compositor_Share},
		{proc(facts: ^Grow_Facts) {facts.compositor_paid = max(u64)}, .Past_Compositor_Share},
		{proc(facts: ^Grow_Facts) {facts.service_paid = facts.share - service_copies_pages(2560, 1440) + 1}, .Past_Service_Share},
		{proc(facts: ^Grow_Facts) {facts.service_paid = max(u64)}, .Past_Service_Share},
	}
	for item in cases {
		facts := good
		item.change(&facts)
		refusal, a, b := screen_budget_grow_decide(facts)
		testing.expectf(t, refusal == item.refusal && a == 0 && b == 0, "%v gave %v", item.refusal, refusal)
	}
	edge := good
	edge.max_width, edge.max_height = 2560, 1440
	edge.compositor_paid = edge.share - compositor_pages
	edge.service_paid = edge.share - service_pages
	refusal, a, b := screen_budget_grow_decide(edge)
	testing.expect(t, refusal == .None && a == compositor_pages && b == service_pages)
	edge.now, edge.last_growth_at = 5000, 4000
	refusal, a, b = screen_budget_grow_decide(edge)
	testing.expect(t, refusal == .None, "a growth one interval after the last was refused")
	edge.compositor_extras, edge.service_extras = 1, 1
	refusal, a, b = screen_budget_grow_decide(edge)
	testing.expect(t, refusal == .None && a == compositor_pages && b == service_pages, "a replacement at the edge of the share was refused")
}

// A screen that grew grows again: 2560 x 1440, then 3840 x 2160 while the
// extra budgets of 2560 x 1440 are held, passes when the share pays both,
// and is refused by the process whose share does not, with no pages.
@(test)
a_grown_screen_grows_again_when_the_share_pays_both :: proc(t: ^testing.T) {
	start := Grow_Facts{from_service = true, screen_of_memory = true, width = 2560, height = 1440, compositor_paid = 23820, service_paid = 6800, share = 50000}
	refusal, compositor_first, service_first := screen_budget_grow_decide(start)
	testing.expect_value(t, refusal, Grow_Refusal.None)
	again := start
	again.width, again.height = 3840, 2160
	again.compositor_extras, again.service_extras = 1, 1
	again.compositor_paid += compositor_first
	again.service_paid += service_first
	compositor_second, service_second: u64
	refusal, compositor_second, service_second = screen_budget_grow_decide(again)
	testing.expect(t, refusal == .None && compositor_second == compositor_grow_pages(3840, 2160) && service_second == service_copies_pages(3840, 2160))
	// One page short in the share of each process, held by its old extra budget.
	short := again
	short.share = again.compositor_paid + compositor_second - 1
	refusal, compositor_second, service_second = screen_budget_grow_decide(short)
	testing.expect(t, refusal == .Past_Compositor_Share && compositor_second == 0 && service_second == 0)
	short = again
	short.share = max(again.compositor_paid + compositor_second, again.service_paid + service_second - 1)
	short.compositor_paid = 0
	short.service_paid = short.share - service_second + 1
	refusal, compositor_second, service_second = screen_budget_grow_decide(short)
	testing.expect(t, refusal == .Past_Service_Share && compositor_second == 0 && service_second == 0)
}

// The word of a refused growth at its border, and the cause that a viewer
// gets for each refusal.
@(test)
a_grow_refusal_word_at_its_border :: proc(t: ^testing.T) {
	for word in ([?]u64{0, u64(max(Grow_Refusal)) + 1, max(u64)}) {
		_, ok := grow_refusal_of_word(word)
		testing.expectf(t, !ok, "the word %d was taken", word)
	}
	for member in Grow_Refusal {
		if member == .None {
			continue
		}
		refusal, ok := grow_refusal_of_word(u64(member))
		testing.expect(t, ok && refusal == member)
		testing.expect(t, resize_refusal_of_grow(member) != .None)
	}
	testing.expect_value(t, resize_refusal_of_grow(.Too_Soon), Resize_Refusal.Too_Soon)
	testing.expect_value(t, resize_refusal_of_grow(.Compositor_Replacing), Resize_Refusal.Compositor_Budget)
	testing.expect_value(t, resize_refusal_of_grow(.Service_Replacing), Resize_Refusal.Service_Budget)
	testing.expect_value(t, resize_refusal_of_grow(.Past_Compositor_Share), Resize_Refusal.Compositor_Budget)
	testing.expect_value(t, resize_refusal_of_grow(.Past_Service_Share), Resize_Refusal.Service_Budget)
}

// The extra budgets of a process refuse a handle of 0, a number of 0, a
// number or a handle held already, and a third one, and change nothing.
@(test)
a_process_holds_two_extra_budgets_at_most :: proc(t: ^testing.T) {
	held: Held_Extras
	testing.expect(t, !held_extras_take(&held, {0, 1, 2560, 1440}))
	testing.expect(t, !held_extras_take(&held, {5, 0, 2560, 1440}))
	testing.expect(t, held == {})
	testing.expect(t, held_extras_take(&held, {5, 1, 2560, 1440}))
	before := held
	testing.expect(t, !held_extras_take(&held, {9, 1, 3840, 2160}), "a number held already was taken")
	testing.expect(t, !held_extras_take(&held, {5, 2, 3840, 2160}), "a handle held already was taken")
	testing.expect(t, held == before)
	testing.expect(t, held_extras_take(&held, {9, 2, 3840, 2160}))
	before = held
	testing.expect(t, !held_extras_take(&held, {13, 3, 1920, 1200}), "a third extra budget was taken")
	testing.expect(t, held == before)
	extra, ok := held_extras_of_size(&held, 3840, 2160)
	testing.expect(t, ok && extra.growth == 2)
	_, ok = held_extras_of_size(&held, 3840, 2161)
	testing.expect(t, !ok, "a size that no extra budget pays was paid")
}

// A replacement gives back the old extra budget once the pictures are in
// the new one; a refused size gives back the new one and keeps the one
// that holds the pictures.
@(test)
a_replacement_gives_back_what_holds_no_picture :: proc(t: ^testing.T) {
	held: Held_Extras
	held_extras_take(&held, {5, 1, 2560, 1440})
	held_extras_take(&held, {9, 2, 3840, 2160})
	given := held_extras_give_back(&held, 2)
	testing.expect(t, given == {0 = {5, 1, 2560, 1440}})
	testing.expect(t, held.extras == {1 = {9, 2, 3840, 2160}})
	held_extras_take(&held, {13, 3, 5120, 2880})
	given = held_extras_give_back(&held, 2)
	testing.expect(t, given == {0 = {13, 3, 5120, 2880}}, "the extra budget of a refused size was kept")
	testing.expect(t, held.extras == {1 = {9, 2, 3840, 2160}})
}

// A growth no longer needed while the face is closed: the pictures are in
// the extra budget of growth 1, the one of growth 2 never held one. The
// face ends: the compositor goes back to its start size, and both go back;
// the service, with no copy, gives both back too.
@(test)
a_growth_not_needed_with_the_face_closed_goes_back :: proc(t: ^testing.T) {
	compositor, service: Held_Extras
	for held in ([2]^Held_Extras{&compositor, &service}) {
		held_extras_take(held, {5, 1, 2560, 1440})
		held_extras_take(held, {9, 2, 3840, 2160})
	}
	pictures_growth := u64(1)
	testing.expect(t, face_ended_goes_to_start(true, pictures_growth))
	pictures_growth = 0 // The pictures of the start size are made from the budget of the process.
	given := held_extras_give_back(&compositor, pictures_growth)
	testing.expect(t, given == {{5, 1, 2560, 1440}, {9, 2, 3840, 2160}})
	testing.expect(t, compositor == {})
	given = held_extras_give_back(&service, 0)
	testing.expect(t, given == {{5, 1, 2560, 1440}, {9, 2, 3840, 2160}})
	testing.expect(t, service == {})
}

// The last viewer leaves after a growth: the face ends with the pictures
// in an extra budget, the compositor goes back to its start size, and the
// extra budget goes back. A screen at its start size, or a screen of a
// device, does not change, and with no extra budget nothing goes back.
@(test)
the_last_viewer_leaving_after_a_growth_returns_to_the_start_size :: proc(t: ^testing.T) {
	held: Held_Extras
	held_extras_take(&held, {5, 3, 2560, 1440})
	testing.expect(t, face_ended_goes_to_start(true, 3))
	given := held_extras_give_back(&held, 0)
	testing.expect(t, given == {0 = {5, 3, 2560, 1440}})
	testing.expect(t, !face_ended_goes_to_start(true, 0), "a screen at its start size changed at the end of the face")
	testing.expect(t, !face_ended_goes_to_start(false, 3), "a screen of a device changed at the end of the face")
	testing.expect(t, held_extras_give_back(&held, 0) == {})
}

// A step back between two grown sizes: the face confirmed A (growth 1),
// the compositor takes B (growth 2) and keeps the extra budget of A until
// the face confirms B. If the copies of B are refused and the compositor
// steps back to A, the extra budget of A pays it, and B goes back when the
// face confirms A. A step back to the start size keeps A until the start
// size is confirmed.
@(test)
the_extra_budget_of_a_confirmed_size_stays_until_the_next_is_confirmed :: proc(t: ^testing.T) {
	held: Held_Extras
	held_extras_take(&held, {5, 1, 2560, 1440})
	held_extras_take(&held, {9, 2, 3840, 2160})
	// B taken, A confirmed.
	testing.expect(t, held_extras_give_back(&held, 2, 1) == {}, "the extra budget of the confirmed size went back before the next was confirmed")
	extra, ok := held_extras_of_size(&held, 2560, 1440)
	testing.expect(t, ok && extra.growth == 1)
	// The step back to A, then the face confirms A.
	testing.expect(t, held_extras_give_back(&held, 1, 1) == {1 = {9, 2, 3840, 2160}})
	// B again; the face confirms B: A goes.
	held_extras_take(&held, {13, 3, 3840, 2160})
	testing.expect(t, held_extras_give_back(&held, 3, 1) == {})
	testing.expect(t, held_extras_give_back(&held, 3, 3) == {0 = {5, 1, 2560, 1440}})
	// A step back to the start size, before and after its confirmation.
	testing.expect(t, held_extras_give_back(&held, 0, 3) == {})
	testing.expect(t, held_extras_give_back(&held, 0, 0) == {1 = {13, 3, 3840, 2160}})
}

// A release that the ring did not take is owed: 0 and a number owed
// already are refused, at most EXTRAS_PER_PROCESS are held, a later pass
// sends them, and one that the ring refuses again stays owed.
@(test)
an_owed_release_goes_in_a_later_pass :: proc(t: ^testing.T) {
	owed: Owed_Releases
	testing.expect(t, !owed_release_add(&owed, 0))
	testing.expect(t, owed_release_add(&owed, 4))
	testing.expect(t, !owed_release_add(&owed, 4), "one release was owed twice")
	testing.expect(t, owed_release_add(&owed, max(u64)))
	before := owed
	testing.expect(t, !owed_release_add(&owed, 7), "a release past the places was owed")
	testing.expect(t, owed == before)
	refuse_all :: proc "contextless" (growth: u64) -> bool {return false}
	owed_releases_send(&owed, refuse_all)
	testing.expect(t, owed == before, "a release that the ring refused again was dropped")
	take_four :: proc "contextless" (growth: u64) -> bool {return growth == 4}
	owed_releases_send(&owed, take_four)
	testing.expect(t, owed.growths == {0, max(u64)})
	take_all :: proc "contextless" (growth: u64) -> bool {return true}
	owed_releases_send(&owed, take_all)
	testing.expect(t, owed == {})
}
