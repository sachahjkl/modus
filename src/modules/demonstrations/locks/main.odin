// The checks and the measures of the locks of the kernel.
//
// The process starts four processes `locker`. Each one works on its own
// objects only: a kernel entry of one locker touches no object of another
// locker. So a locker waits for another one only when the kernel makes it
// wait. With 1, 2 and 4 lockers at one time, each locker enters the kernel
// a fixed count of times, then writes a fixed count of pages for the first
// time. Then two threads of this process wake each other with the word
// wait a fixed count of times, alone, then while two lockers enter the
// kernel. The window shows the counts, and the waits of each lock of the
// kernel in each run. In a [measure run](term:measure-run) each run has a
// fixed time and no count, and the numbers are the kernel entries, the
// page faults on first use and the wakes in one second.
//
// The process checks the counts: the kernel counted each entry of a
// locker, each page returned to its budget, each free page is in a budget
// or reserved, and no wake was lost. It does not check a speed.
//
// The process needs the grant to inspect the machine, and the boot image
// (it starts the lockers).
//
// **What it is for.** It shows how the kernel behaves when many processes
// enter it at one time: the count of the waits of each
// [lock of the kernel](term:lock-of-the-kernel), one
// [run queue](term:run-queue) for each processor, and the
// [word wait](term:word-wait) that loses no wake under load. The checks
// are of counts and of order; the rates are measures.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("locks")` in the console. The window shows the kernel entries and
// the page faults of the check with 1, 2 and 4 lockers, the wakes of the
// word wait between two threads alone and under load, and, for each
// run, the waits of each lock. In a measure run (`modustool measure`) the
// numbers are in one second. The log gets one line for each locker
// (`locks: locker 1 counted ... entries, the kernel ...`), the lines of the
// stress case and of the case of the frames, then the summary.
//
// **Its grants**: **Inspect**, to read the counts of the locks and of the
// kernel entries, and **Image**, to start the process `locker`. Its budget
// holds 9216 pages and 8 processes: 4 lockers of 1024 pages, then 3 at a
// time in the stress case.
//
// **What it does not prove.** A count of waits says how often a lock was
// contended, not how long: the times are printed as measures, and depend
// on the host of the run.
package locks

import "base:intrinsics"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:lockers"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:random"
import "modus:system"

// Four lockers of 1024 pages, then three at a time of the stress case:
// 7745 pages. And the glyph memory of the copy of the text rendering of
// the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 7745 + 354 = 8099.
// With the pages of the case of the wait room: a room of the most words
// (op.wait_room_pages, 512 pages), its list and its words (160 pages);
// the two processes of the case of the untouched page, with 2 threads and
// 1024 pages each (untouched_page.odin); and the mapping of the measure of
// an unmap, 4096 pages and its frame list (wait_room.odin).
// 8099 + 672 + 2048 + 4097 = 14916.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 14916, processes = 10, threads = 24, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(1024, 16384)

MEASURE_TIME :: 300 // Milliseconds of one measure, in a measure run.
PAIR_TIME :: 500 // Milliseconds of one measure of the word wait, in a measure run.
// The work of the checks: each locker ends its command after this count.
ENTRIES_CHECKED :: 16_384 // Kernel entries of one locker.
FAULT_PAGES_CHECKED :: 8 * lockers.FAULT_PAGES // Pages that one locker writes for the first time.
LARGE_OBJECTS_CHECKED :: 16 // Memory objects of 600 pages that one locker makes and closes.
PAIR_ROUNDS_CHECKED :: 2_000 // Turns of the first thread of the word wait.
LOAD_ENTRIES_CHECKED :: 65_536 // Kernel entries of each locker that loads the kernel during the word wait.
// A wait that ends at this deadline after the word changed lost its wake. A
// wake that is only late on a loaded host comes long before it: the bound of
// a hang.
LOST_WAIT :: system.TEST_HANG_BOUND_MILLISECONDS
LOCKER_AMOUNTS :: system.Budget_Amounts{pages = 1024, processes = 1, threads = 1, processor = 1_000_000, log_records = 10}
CHURN_AMOUNTS :: system.Budget_Amounts{pages = 512, processes = 1, threads = lockers.CHURN_THREADS, processor = 1_000_000, log_records = 10}
CHURN_ROUNDS :: 40
CHURN_COUNT :: 3 // The processes of one round.

// The window follows docs/DESIGN.md where it is cheap: rectangles only,
// the spacing tokens, the colors of the rules, a name in the dim color
// and a value in the text color.
WIDTH :: 784
LINE :: 24 // A line of text (16) and 8 between lines.
LEFT :: 16
GAP :: 8
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
HEIGHT :: 624
#assert(HEIGHT == LEFT + 4 * LINE + 2 * GAP + 2 * LINE + GAP + (len(op.Lock_Kind) + 1) * LINE + GAP + (CACHE_ROWS + 1) * LINE + GAP + 2 * LINE + LEFT)
CACHE_ROWS :: 4 // The frame caches of the first 4 processors.
COLUMN_X :: 304
COLUMN_WIDTH :: 120
LOCK_X :: 176 // The table of the locks: the names are short.
LOCK_COLUMN_WIDTH :: 200
#assert(WIDTH >= 2 * GAP + (COLUMN_X - GAP) + 3 * COLUMN_WIDTH)
#assert(WIDTH >= 2 * GAP + (LOCK_X - GAP) + 3 * LOCK_COLUMN_WIDTH)

locks_layout_tree: layout.Box_Tree

Locks_Places :: struct {
	intro:          interface.Area,
	lockers_header: interface.Area,
	lockers_rows:   [2]interface.Area,
	lockers_cols:   [4]layout.Table_Column_Place,
	pair_header:    interface.Area,
	pair_row:       interface.Area,
	locks_header:   interface.Area,
	locks_rows:     [len(op.Lock_Kind)]interface.Area,
	locks_cols:     [4]layout.Table_Column_Place,
	cache_header:   interface.Area,
	cache_rows:     [CACHE_ROWS]interface.Area,
	cache_cols:     [5]layout.Table_Column_Place,
	stress_row:     interface.Area,
	verdict_row:    interface.Area,
}

@(private)
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// locks_window_layout computes all stacked sections and table columns of locks
// with modus:layout.
locks_window_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height: int, tokens: layout.Element_Tokens) -> (places: Locks_Places, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = tokens.gap, .Y = tokens.margin}, gap = tokens.gap}) != .Done {
		return {}, false
	}
	intro_box, s0 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	// Lockers table: header + 2 rows.
	_, s1 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(3 * LINE)}, child_axis = .Y})
	lh_box, s2a := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	lr_boxes: [2]layout.Box_Index
	s2b, s2c: layout.Box_Status
	lr_boxes[0], s2b = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	lr_boxes[1], s2c = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	s3 := layout.box_close(tree)
	// Word wait pair table: header + 1 row.
	_, s4 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(2 * LINE)}, child_axis = .Y})
	ph_box, s5 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	pr_box, s6 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	s7 := layout.box_close(tree)
	if s0 != .Done || s1 != .Done || s2a != .Done || s2b != .Done || s2c != .Done || s3 != .Done || s4 != .Done || s5 != .Done || s6 != .Done || s7 != .Done {
		return {}, false
	}
	// Kernel lock contention table.
	if _, st := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px((len(op.Lock_Kind) + 1) * LINE)}, child_axis = .Y}); st != .Done {
		return {}, false
	}
	kh_box, skh := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	if skh != .Done {
		return {}, false
	}
	kr_boxes: [len(op.Lock_Kind)]layout.Box_Index
	for i in 0 ..< len(op.Lock_Kind) {
		st: layout.Box_Status
		kr_boxes[i], st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
		if st != .Done {
			return {}, false
		}
	}
	if layout.box_close(tree) != .Done {
		return {}, false
	}
	// Frame cache table.
	if _, st := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px((CACHE_ROWS + 1) * LINE)}, child_axis = .Y}); st != .Done {
		return {}, false
	}
	ch_box, sch := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	if sch != .Done {
		return {}, false
	}
	cr_boxes: [CACHE_ROWS]layout.Box_Index
	for i in 0 ..< CACHE_ROWS {
		st: layout.Box_Status
		cr_boxes[i], st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
		if st != .Done {
			return {}, false
		}
	}
	if layout.box_close(tree) != .Done {
		return {}, false
	}
	// Footer: stress count + verdict.
	if _, st := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(2 * LINE)}, child_axis = .Y}); st != .Done {
		return {}, false
	}
	sr_box, ssr := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	vr_box, svr := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	sc := layout.box_close(tree)
	if ssr != .Done || svr != .Done || sc != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	places.intro = area_of(tree, intro_box)
	places.lockers_header = area_of(tree, lh_box)
	places.lockers_rows[0] = area_of(tree, lr_boxes[0])
	places.lockers_rows[1] = area_of(tree, lr_boxes[1])
	places.pair_header = area_of(tree, ph_box)
	places.pair_row = area_of(tree, pr_box)
	places.locks_header = area_of(tree, kh_box)
	for i in 0 ..< len(op.Lock_Kind) {
		places.locks_rows[i] = area_of(tree, kr_boxes[i])
	}
	places.cache_header = area_of(tree, ch_box)
	for i in 0 ..< CACHE_ROWS {
		places.cache_rows[i] = area_of(tree, cr_boxes[i])
	}
	places.stress_row = area_of(tree, sr_box)
	places.verdict_row = area_of(tree, vr_box)

	rect_of :: proc "contextless" (a: interface.Area) -> layout.Rect {
		return {i32(a.x), i32(a.y), i32(a.width), i32(a.height)}
	}
	lockers_spec := [4]layout.Table_Column{
		{width = COLUMN_X - GAP},
		{weight = 1, least = COLUMN_WIDTH},
		{weight = 1, least = COLUMN_WIDTH},
		{weight = 1, least = COLUMN_WIDTH},
	}
	if layout.table_columns(lockers_spec[:], places.lockers_cols[:], rect_of(places.lockers_header), 0) != .Done {
		return {}, false
	}
	locks_spec := [4]layout.Table_Column{
		{width = LOCK_X - GAP},
		{weight = 1, least = LOCK_COLUMN_WIDTH},
		{weight = 1, least = LOCK_COLUMN_WIDTH},
		{weight = 1, least = LOCK_COLUMN_WIDTH},
	}
	if layout.table_columns(locks_spec[:], places.locks_cols[:], rect_of(places.locks_header), 0) != .Done {
		return {}, false
	}
	cache_spec := [5]layout.Table_Column{
		{width = LOCK_X - GAP},
		{weight = 1, least = LOCK_COLUMN_WIDTH * 3 / 4},
		{weight = 1, least = LOCK_COLUMN_WIDTH * 3 / 4},
		{weight = 1, least = LOCK_COLUMN_WIDTH * 3 / 4},
		{weight = 1, least = LOCK_COLUMN_WIDTH * 3 / 4},
	}
	if layout.table_columns(cache_spec[:], places.cache_cols[:], rect_of(places.cache_header), 0) != .Done {
		return {}, false
	}
	return places, true
}


@(rodata)
counts := [3]int{1, 2, 4}

machine: system.Handle
board: ^lockers.Board
processes: [lockers.LOCKER_CAPACITY]system.Handle

// All the lockers together: the kernel entries and the pages on first use
// of the check; in a measure run, in one second.
entry_rates: [len(counts)]u64
fault_rates: [len(counts)]u64
pairs_alone, pairs_loaded: u64 // Wakes between the two threads: of the check; in a measure run, in one second.
lost_wakes: u64
entry_locks, fault_locks, pair_locks: [op.LOCK_KIND_CAPACITY]op.Lock_Count // The locks during the measures with 4 lockers, and with the word wait.
entries_right, faults_right, pages_right, pairs_right := true, true, true, true
done: bool
caches: [CACHE_ROWS]op.Processor_Report // The frame caches after the measures.

report :: proc "contextless" () -> (report: op.System_Report) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	return report
}

locks_between :: proc "contextless" (before, after: op.System_Report) -> (delta: [op.LOCK_KIND_CAPACITY]op.Lock_Count) {
	for &count, index in delta {
		count = {takes = after.locks[index].takes - before.locks[index].takes, waits = after.locks[index].waits - before.locks[index].waits}
	}
	return delta
}

// lockers_answered says if each of the first `active` lockers ended the
// command that it had when `seen` was read.
lockers_answered :: proc "contextless" (active: int, seen: ^[lockers.LOCKER_CAPACITY]u32) -> bool {
	for index in 0 ..< active {
		if intrinsics.atomic_load(&board.slots[index].done) == seen[index] {
			return false
		}
	}
	return true
}

// command gives one command to the first `active` lockers, and waits for
// their results. A locker ends at the time `end`, or after `limit`
// operations (0: no limit).
command :: proc "contextless" (active: int, mode: lockers.Mode, start, end, limit: u64) -> bool {
	seen: [lockers.LOCKER_CAPACITY]u32
	for index in 0 ..< active {
		slot := &board.slots[index]
		seen[index] = intrinsics.atomic_load(&slot.done)
		slot.mode = u32(mode)
		slot.start = start
		slot.end = end
		slot.limit = limit
		intrinsics.atomic_add(&slot.command, 1)
		system.word_wake(&slot.command, system.WAKE_ALL)
	}
	deadline := end + system.TEST_HANG_BOUND_MILLISECONDS // The bound only ends a hang.
	for index in 0 ..< active {
		slot := &board.slots[index]
		for intrinsics.atomic_load(&slot.done) == seen[index] {
			if system.time() >= deadline {
				return false
			}
			system.word_wait(&slot.done, seen[index], deadline)
		}
	}
	return true
}

// measure runs one mode on 1, 2 and 4 lockers, and checks the counts. The
// check ends when each locker did its count of work: the time of its end
// is the hang bound. A measure run has a fixed time and no count, and
// gives the rate.
measure :: proc "contextless" (mode: lockers.Mode, rates: ^[len(counts)]u64, locks: ^[op.LOCK_KIND_CAPACITY]op.Lock_Count) {
	measured := system.measure_run()
	limit: u64
	if !measured {
		limit = mode == .Entries ? ENTRIES_CHECKED : FAULT_PAGES_CHECKED
	}
	for active, row in counts {
		entries_before: [lockers.LOCKER_CAPACITY]u64
		for index in 0 ..< active {
			entries_before[index] = system.process_entries(processes[index])
		}
		before := report()
		// A measure starts a little later: each locker is at its start
		// before the time counts.
		start := system.time() + (measured ? 20 : 0)
		end := start + (measured ? MEASURE_TIME : system.TEST_HANG_BOUND_MILLISECONDS)
		answered := command(active, mode, start, end, limit)
		after := report()
		total: u64
		kernel_total: u64
		for index in 0 ..< active {
			slot := &board.slots[index]
			total += slot.count
			kernel := system.process_entries(processes[index]) - entries_before[index]
			kernel_total += kernel
			// The kernel counted each entry that the library of the locker
			// counted: the loop, two budget reads, the wake of this process,
			// and the wait that follows (it can be in the count or not yet).
			if mode == .Entries && (slot.entries != slot.count + 1 || kernel < slot.count + 3 || kernel > slot.count + 8) {
				if entries_right {
					system.log_fact(.Info, Locker_Entries_Differ{locker = u64(index + 1), operations = slot.count, entries = slot.entries, kernel_entries = kernel})
				}
				entries_right = false
			}
			if slot.budget_before != slot.budget_after {
				pages_right = false
			}
			// A locker of the check that ended before its count ended at the
			// hang bound.
			if slot.count < limit {
				answered = false
			}
		}
		// The entries of the lockers are a part of the entries of the machine.
		if !answered || kernel_total > after.entries - before.entries {
			entries_right = false
		}
		if mode == .Faults && after.first_use_faults - before.first_use_faults < total {
			faults_right = false
		}
		if after.budget_pages + after.reserved_pages != after.free_pages {
			pages_right = false
		}
		rates[row] = measured ? total * 1000 / MEASURE_TIME : total
		if active == lockers.LOCKER_CAPACITY {
			locks^ = locks_between(before, after)
		}
	}
}

// The word wait between two threads: each one changes the word, wakes the
// other one, and waits while the word holds its own value, in one kernel entry.
Pair :: struct {
	turn:   u32, // Even: the first thread runs. Odd: the second one.
	stop:   u32,
	rounds: [2]u64,
	lost:   [2]u64,
	refused: [2]u64, // The batches of a wake and a wait that the library refused: a fault of this process.
}

pair: Pair

// pair_round is one turn of one side: the side writes turn + 1, wakes the
// other side and waits while the word holds turn + 1.
pair_round :: proc "contextless" (side: int, turn: u32) {
	next := turn + 1
	intrinsics.atomic_store(&pair.turn, next)
	word := op.Word{address = u64(uintptr(&pair.turn)), value = u64(next)}
	// The wake and the wait in one kernel entry.
	commands := [2]ring.Record{{kind = u32(op.Operation.Word_Wake), values = {0 = u64(uintptr(&pair.turn)), 1 = 1}}, {kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&word)), 1 = 1}}}
	completions: [2]ring.Record
	deadline := system.time() + LOST_WAIT
	now, status := system.commands_call(commands[:], completions[:], deadline)
	if status != .Ok {
		pair.refused[side] += 1
	}
	// The word changed while the wait ended at its deadline: a lost wake.
	if now >= deadline && intrinsics.atomic_load(&pair.turn) != next {
		pair.lost[side] += 1
	}
	pair.rounds[side] += 1
}

// pair_second is the entry of the second thread.
pair_second :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&pair.stop) == 0 {
		turn := intrinsics.atomic_load(&pair.turn)
		if turn % 2 == 0 {
			system.word_wait(&pair.turn, turn, system.time() + LOST_WAIT)
			continue
		}
		pair_round(1, turn)
	}
	system.thread_stop()
}

// pairs runs the word wait between the two threads, with `load` lockers
// that enter the kernel at the same time. The check goes on until the
// first thread did PAIR_ROUNDS_CHECKED turns and each locker of the load
// did its count of entries, and gives the wakes. A measure run goes on for
// PAIR_TIME, and gives the wakes in one second.
pairs :: proc "contextless" (load: int) -> u64 {
	measured := system.measure_run()
	pair = {}
	thread, status := system.thread_start(pair_second, nil)
	if status != .Ok {
		pairs_right = false
		return 0
	}
	before := report()
	start := system.time() + (measured ? 20 : 0)
	end := start + (measured ? PAIR_TIME : system.TEST_HANG_BOUND_MILLISECONDS)
	seen: [lockers.LOCKER_CAPACITY]u32
	for index in 0 ..< load {
		slot := &board.slots[index]
		seen[index] = intrinsics.atomic_load(&slot.done)
		slot.mode = u32(lockers.Mode.Entries)
		slot.start = start
		slot.end = end
		slot.limit = measured ? 0 : LOAD_ENTRIES_CHECKED
		intrinsics.atomic_add(&slot.command, 1)
		system.word_wake(&slot.command, system.WAKE_ALL)
	}
	for system.time() < start {
		intrinsics.cpu_relax()
	}
	for system.time() < end && (measured || pair.rounds[0] < PAIR_ROUNDS_CHECKED || !lockers_answered(load, &seen)) {
		turn := intrinsics.atomic_load(&pair.turn)
		if turn % 2 == 1 {
			system.word_wait(&pair.turn, turn, system.time() + LOST_WAIT)
			continue
		}
		pair_round(0, turn)
	}
	after := report()
	// The lockers end at the same time.
	for index in 0 ..< load {
		slot := &board.slots[index]
		for intrinsics.atomic_load(&slot.done) == seen[index] {
			system.word_wait(&slot.done, seen[index], system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
		}
	}
	intrinsics.atomic_store(&pair.stop, 1)
	intrinsics.atomic_add(&pair.turn, 2)
	system.word_wake(&pair.turn, system.WAKE_ALL)
	system.thread_wait(thread)
	lost_wakes += pair.lost[0] + pair.lost[1]
	if pair.refused[0] + pair.refused[1] != 0 || pair.rounds[0] < pair.rounds[1] || pair.rounds[0] > pair.rounds[1] + 1 {
		pairs_right = false
	}
	if load != 0 {
		pair_locks = locks_between(before, after)
	}
	if measured {
		return pair.rounds[0] * 1000 / PAIR_TIME
	}
	// A check that ended before its count ended at the hang bound.
	if pair.rounds[0] < PAIR_ROUNDS_CHECKED {
		pairs_right = false
	}
	return pair.rounds[0]
}

row :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area, cols: []layout.Table_Column_Place, label: string, values: []u64, tokens: layout.Element_Tokens) {
	text_y := area.y + (area.height - graphics.CELL_HEIGHT) / 2
	interface.draw_text(table, area.x + GAP, text_y, label, tokens.text_dim)
	line: [48]u8
	for value, index in values {
		if index + 1 < len(cols) {
			interface.draw_text(table, int(cols[index + 1].x), text_y, system.format(line[:], value), tokens.text)
		}
	}
}

// draw builds a frame of the window with the interface package.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	draw_records(frame.table, window.width, window.height)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

draw_records :: proc "contextless" (table: ^interface.Draw_Table, width, height: int) {
	tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
	places, layout_ok := locks_window_layout(&locks_layout_tree, width, height, tokens)
	if !layout_ok {
		return
	}
	text_y :: proc "contextless" (a: interface.Area) -> int {
		return a.y + (a.height - graphics.CELL_HEIGHT) / 2
	}
	measured := system.measure_run()
	interface.draw_text(table, places.intro.x + GAP, text_y(places.intro), measured ? "each locker works on its own objects: it waits only if the kernel makes it wait." : "each locker works on its own objects. rates in one second: run `modustool measure`.", tokens.text_dim)
	interface.draw_text(table, places.lockers_header.x + GAP, text_y(places.lockers_header), measured ? "in one second, all lockers" : "in the check, all lockers", tokens.text_dim)
	for active, index in counts {
		line: [24]u8
		interface.draw_text(table, int(places.lockers_cols[index + 1].x), text_y(places.lockers_header), system.format(line[:], u64(active), active == 1 ? " locker" : " lockers"), tokens.text_dim)
	}
	interface.draw_rectangle(table, places.lockers_rows[0].x, places.lockers_rows[0].y, places.lockers_rows[0].width, places.lockers_rows[0].height, tokens.surface_card)
	row(table, places.lockers_rows[0], places.lockers_cols[:], "kernel entries", entry_rates[:], tokens)
	row(table, places.lockers_rows[1], places.lockers_cols[:], "pages on first use", fault_rates[:], tokens)

	interface.draw_text(table, places.pair_header.x + GAP, text_y(places.pair_header), "word wait, two threads", tokens.text_dim)
	interface.draw_text(table, int(places.lockers_cols[1].x), text_y(places.pair_header), "alone", tokens.text_dim)
	interface.draw_text(table, int(places.lockers_cols[2].x), text_y(places.pair_header), "2 lockers enter", tokens.text_dim)
	interface.draw_rectangle(table, places.pair_row.x, places.pair_row.y, places.pair_row.width, places.pair_row.height, tokens.surface_card)
	row(table, places.pair_row, places.lockers_cols[:], "wakes", {pairs_alone, pairs_loaded}, tokens)

	interface.draw_text(table, places.locks_header.x + GAP, text_y(places.locks_header), "waits of takes", tokens.text_dim)
	for name, index in ([3]string{"4 lockers, entries", "4 lockers, faults", "word wait"}) {
		interface.draw_text(table, int(places.locks_cols[index + 1].x), text_y(places.locks_header), name, tokens.text_dim)
	}
	for kind in op.Lock_Kind {
		row_area := places.locks_rows[int(kind)]
		if int(kind) % 2 == 0 {
			interface.draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, tokens.surface_card)
		}
		ty := text_y(row_area)
		interface.draw_text(table, row_area.x + GAP, ty, op.LOCK_KIND_NAMES[kind], tokens.text_dim)
		line: [48]u8
		for locks, index in ([3][op.LOCK_KIND_CAPACITY]op.Lock_Count{entry_locks, fault_locks, pair_locks}) {
			count := locks[kind]
			interface.draw_text(table, int(places.locks_cols[index + 1].x), ty, system.format(line[:], count.waits, " of ", count.takes), tokens.text)
		}
	}
	// The frame cache of each processor (Processor_Report): a stack of free
	// frames that pages on first use take with no frame lock.
	interface.draw_text(table, places.cache_header.x + GAP, text_y(places.cache_header), "frame cache", tokens.text_dim)
	for name, index in ([4]string{"frames now", "batches taken", "batches given", "drains"}) {
		interface.draw_text(table, int(places.cache_cols[index + 1].x), text_y(places.cache_header), name, tokens.text_dim)
	}
	for index in 0 ..< CACHE_ROWS {
		cache := caches[index]
		row_area := places.cache_rows[index]
		if index % 2 == 0 {
			interface.draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, tokens.surface_card)
		}
		ty := text_y(row_area)
		cache_line: [32]u8
		interface.draw_text(table, row_area.x + GAP, ty, system.format(cache_line[:], "processor ", u64(index)), tokens.text_dim)
		for value, column in ([4]u64{cache.cache_frames, cache.cache_batches_taken, cache.cache_batches_given, cache.cache_drains}) {
			interface.draw_text(table, int(places.cache_cols[column + 1].x), ty, system.format(cache_line[:], value), tokens.text)
		}
	}
	line: [64]u8
	interface.draw_text(table, places.stress_row.x + GAP, text_y(places.stress_row), "processes stopped while they ran", tokens.text_dim)
	interface.draw_text(table, int(places.lockers_cols[1].x), text_y(places.stress_row), system.format(line[:], stress_started), tokens.text)
	if done {
		right := entries_right && faults_right && pages_right && pairs_right && lost_wakes == 0 && stress_right
		interface.draw_text(table, places.verdict_row.x + GAP, text_y(places.verdict_row), right ? "the counts add up, no wake was lost, stopped processes returned all" : "a count is wrong", right ? tokens.expected : tokens.failed)
	} else {
		interface.draw_text(table, places.verdict_row.x + GAP, text_y(places.verdict_row), measured ? "measures in progress" : "checks in progress", tokens.text_dim)
	}
}

// stress stops processes while their threads run, many times: each round
// starts three churn lockers; the second and the third stop the one before
// them after a few milliseconds, while this process stops each one, or
// closes its last handle at once. At the end, each page, process and thread
// is back in the budget of this process, and the free pages are the pages
// of the budgets and the reserved pages.
stress :: proc "contextless" (image: []u8, processes_free: u64) {
	// The lockers of the measures have ended: their slots are back.
	initial: system.Budget_Amounts
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		initial, _ = system.budget_read()
		if initial.processes == processes_free {
			break
		}
		system.sleep(system.time() + 10)
	}
	file := system.image_find(image, "locker")
	started, stopped, closed: u64
	helper, _ := system.thread_start(stopper_run, nil)
	for round in 0 ..< u64(CHURN_ROUNDS) {
		churners: [CHURN_COUNT]system.Handle
		for &churner, index in churners {
			grants: [op.CONTEXT_HANDLES]system.Grant
			values: [op.CONTEXT_VALUES]u64
			values[lockers.VALUE_ROLE] = u64(lockers.Role.Churn)
			values[lockers.VALUE_STOP_AFTER] = 1 + (round + u64(index)) % 4
			if index != 0 {
				grants[lockers.GRANT_PEER] = {churners[index - 1], {.Control}}
			}
			status: system.Status
			churner, status = system.process_start(file, "churn", grants, random.values_with_seed(&process_generator, values), CHURN_AMOUNTS)
			if status == .Ok {
				started += 1
			}
		}
		pause := system.time() + 2 + round % 3
		for system.time() < pause {
			intrinsics.cpu_relax()
		}
		for churner, index in churners {
			if churner == 0 {
				continue
			}
			switch (round + u64(index)) % 3 {
			case 0:
				system.process_stop(churner)
				stopped += 1
			case 1:
				// The other thread stops it while this one closes the handle.
				seen := intrinsics.atomic_load(&stopper.done)
				intrinsics.atomic_store(&stopper.target, u32(churner))
				system.word_wake(&stopper.target)
				for intrinsics.atomic_load(&stopper.target) != 0 {
					intrinsics.cpu_relax()
				}
				system.close(churner)
				for intrinsics.atomic_load(&stopper.done) == seen {
					intrinsics.cpu_relax()
				}
				stopped += 1
				closed += 1
				continue
			}
			system.close(churner) // The last handle of this process to it, at once.
			closed += 1
		}
	}
	intrinsics.atomic_store(&stopper.quit, 1)
	system.word_wake(&stopper.target)
	system.thread_wait(helper)
	// The cleanup of a process runs when its last thread leaves its
	// processor: wait for the budget. The bound only ends a hang.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	after: system.Budget_Amounts
	for system.time() < deadline {
		after, _ = system.budget_read()
		if after.pages == initial.pages && after.processes == initial.processes && after.threads == initial.threads {
			break
		}
		system.sleep(system.time() + 10)
	}
	stress_started = started
	final := report()
	stress_right = started == CHURN_ROUNDS * CHURN_COUNT && after.pages == initial.pages && after.processes == initial.processes && after.threads == initial.threads && final.budget_pages + final.reserved_pages == final.free_pages
	system.log_fact(.Info, Stress_Done{started = started, stopped = stopped, closed_only = closed - stopped, pages = after.pages, pages_at_start = initial.pages, processes = after.processes, processes_at_start = initial.processes, threads = after.threads, threads_at_start = initial.threads, free_pages = final.free_pages, budget_pages = final.budget_pages, reserved_pages = final.reserved_pages})
}

stress_right: bool
stress_started: u64

// The stress case of the frames: two lockers make and close memory objects
// of 600 pages (three list pages each), two lockers fault pages on first
// use, and this process reads System_Report with no pause. The kernel checks
// its sums of the frames at each report and at each drain (in the test
// build); this process checks that the free pages less the reserved pages
// are the pages of the budgets in each report. The lockers and this process
// are different processes: no process lock orders their kernel entries.
FRAMES_STRESS_TIME :: 500 // Milliseconds of one round, in a measure run.

frames_stress_right: bool

frames_stress :: proc "contextless" () {
	modes := [lockers.LOCKER_CAPACITY]lockers.Mode{.Large, .Large, .Faults, .Faults}
	reports, wrong, made, faulted: u64
	answered := true
	measured := system.measure_run()
	// In the check, each locker ends after its count of work, and this
	// process reads reports until each one ended. A measure run has rounds
	// of a fixed time: a loaded host can give the lockers no time in one
	// round, so the rounds go on until each kind of work ran at least once.
	// The bound only ends a hang.
	for stress_deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; answered && (made == 0 || faulted == 0) && system.time() < stress_deadline; {
		seen: [lockers.LOCKER_CAPACITY]u32
		start := system.time() + (measured ? 20 : 0)
		end := start + (measured ? FRAMES_STRESS_TIME : system.TEST_HANG_BOUND_MILLISECONDS)
		for index in 0 ..< lockers.LOCKER_CAPACITY {
			slot := &board.slots[index]
			seen[index] = intrinsics.atomic_load(&slot.done)
			slot.mode = u32(modes[index])
			slot.start = start
			slot.end = end
			slot.limit = 0
			if !measured {
				slot.limit = modes[index] == .Large ? LARGE_OBJECTS_CHECKED : FAULT_PAGES_CHECKED
			}
			intrinsics.atomic_add(&slot.command, 1)
			system.word_wake(&slot.command, system.WAKE_ALL)
		}
		for (measured ? system.time() < end + 5 : system.time() < end && !lockers_answered(lockers.LOCKER_CAPACITY, &seen)) {
			read := report()
			reports += 1
			if read.budget_pages + read.reserved_pages != read.free_pages {
				wrong += 1
			}
		}
		for index in 0 ..< lockers.LOCKER_CAPACITY {
			slot := &board.slots[index]
			for intrinsics.atomic_load(&slot.done) == seen[index] {
				if system.time() > end + system.TEST_HANG_BOUND_MILLISECONDS {
					answered = false
					break
				}
				system.word_wait(&slot.done, seen[index], system.time() + 100)
			}
		}
		made += board.slots[0].count + board.slots[1].count
		faulted += board.slots[2].count + board.slots[3].count
	}
	frames_stress_right = answered && made != 0 && faulted != 0 && wrong == 0
	system.log_fact(.Info, Frames_Stress_Done{made = made, faulted = faulted, reports = reports, wrong = wrong})
}

// The second thread of the stress case: it stops the process that the
// first thread names in `stop_target`, while the first thread closes its
// last handle to it.
Stopper :: struct {
	target: u32, // A process handle. 0: none.
	done:   u32, // Adds 1 after each stop.
	quit:   u32,
}

stopper: Stopper

stopper_run :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&stopper.quit) == 0 {
		target := intrinsics.atomic_exchange(&stopper.target, 0)
		if target == 0 {
			system.word_wait(&stopper.target, 0, system.time() + 100)
			continue
		}
		system.process_stop(system.Handle(target))
		intrinsics.atomic_add(&stopper.done, 1)
	}
	system.thread_stop()
}

// The random generator of this process (src/library/modus/random).
process_generator: random.Generator

// entry starts the four lockers, runs the measures with 1, 2 and 4 of
// them, the word wait alone and under load, the stress case and the case
// of the frames, checks the counts, and writes the summary. It then keeps
// the window open until the process is stopped. With no random seed, it
// writes the reason on the log and stops with `Refused`; with no boot
// image, no memory for the board, or a locker that does not start, with
// `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this process, from the seed that its starter
	// gave: it gives the seed of each process that this one starts.
	if !random.generator_from_context(&process_generator, ctx) {
		system.log_fact(.Info, No_Random_Seed{})
		system.stop(.Refused)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "locks")
	if !ok {
		system.stop(.Failed)
	}
	draw(&window)

	machine = ctx.handles[system.GRANT_MACHINE]
	at_start, _ := system.budget_read()
	image: []u8
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	memory, memory_status := system.memory_create(1)
	address, map_status := system.memory_map(memory)
	if image == nil || memory_status != .Ok || map_status != .Ok {
		system.log_fact(.Info, No_Boot_Image_Or_Memory{})
		system.stop(.Failed)
	}
	board = (^lockers.Board)(address)
	names := [lockers.LOCKER_CAPACITY]string{"locker 1", "locker 2", "locker 3", "locker 4"}
	for &process, index in processes {
		grants: [op.CONTEXT_HANDLES]system.Grant
		values: [op.CONTEXT_VALUES]u64
		grants[lockers.GRANT_BOARD] = {memory, {.Read, .Write}}
		values[lockers.VALUE_INDEX] = u64(index)
		status: system.Status
		if process, status = system.process_start(system.image_find(image, "locker"), names[index], grants, random.values_with_seed(&process_generator, values), LOCKER_AMOUNTS); status != .Ok {
			system.log_fact(.Info, Locker_Not_Started{status = status})
			system.stop(.Failed)
		}
	}

	// Each locker is ready: its start is not in a measure.
	for &slot in board.slots {
		deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
		for intrinsics.atomic_load(&slot.done) == 0 && system.time() < deadline {
			system.word_wait(&slot.done, 0, deadline)
		}
	}
	// The rates are in the lines of a measure run only: the lines of the
	// check have the counts of its work.
	measured := system.measure_run()
	measure(.Entries, &entry_rates, &entry_locks)
	if measured {
		system.log_fact(.Info, Kernel_Entries_Measured{one_locker = entry_rates[0], two_lockers = entry_rates[1], four_lockers = entry_rates[2]})
	} else {
		system.log_fact(.Info, Kernel_Entries_Counted{one_locker = entry_rates[0], two_lockers = entry_rates[1], four_lockers = entry_rates[2]})
	}
	measure(.Faults, &fault_rates, &fault_locks)
	if measured {
		system.log_fact(.Info, Pages_On_First_Use_Measured{one_locker = fault_rates[0], two_lockers = fault_rates[1], four_lockers = fault_rates[2]})
	} else {
		system.log_fact(.Info, Pages_On_First_Use_Counted{one_locker = fault_rates[0], two_lockers = fault_rates[1], four_lockers = fault_rates[2]})
	}
	pairs_alone = pairs(0)
	pairs_loaded = pairs(2)
	if measured {
		system.log_fact(.Info, Word_Wait_Measured{alone = pairs_alone, loaded = pairs_loaded, lost = lost_wakes})
	} else {
		system.log_fact(.Info, Word_Wait_Counted{alone = pairs_alone, loaded = pairs_loaded, lost = lost_wakes})
	}
	wait_room_case(image) // wait_room.odin
	untouched_page_case(image) // untouched_page.odin
	read_only_wake_case() // read_only_wake.odin
	unmap_wait_case(image) // unmap_wait.odin
	for kind in op.Lock_Kind {
		system.log_fact(.Info, Entry_Lock_Waits{waits = entry_locks[kind].waits, takes = entry_locks[kind].takes, lock = lock_field(kind)})
	}
	for kind in op.Lock_Kind {
		system.log_fact(.Info, Fault_Lock_Waits{waits = fault_locks[kind].waits, takes = fault_locks[kind].takes, lock = lock_field(kind)})
	}
	for kind in op.Lock_Kind {
		system.log_fact(.Info, Pair_Lock_Waits{waits = pair_locks[kind].waits, takes = pair_locks[kind].takes, lock = lock_field(kind)})
	}
	frames_stress()
	for process in processes {
		system.close(process)
	}
	stress(image, at_start.processes)
	// The frame caches of the processors, after the measures and the stress.
	processor_count := report().processors
	for &cache, index in caches {
		if u64(index) < processor_count {
			system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), u64(index), u64(uintptr(&cache)), size_of(cache))
		}
	}
	for cache, index in caches {
		if u64(index) >= processor_count {
			break
		}
		system.log_fact(.Info, Frame_Cache_Shown{processor = u64(index), frames = cache.cache_frames, batches_taken = cache.cache_batches_taken, batches_given = cache.cache_batches_given, drains = cache.cache_drains})
	}
	done = true
	if entries_right && faults_right && pages_right && pairs_right && lost_wakes == 0 && stress_right && frames_stress_right {
		system.log_fact(.Info, Checks_Passed{})
	} else {
		system.log_fact(.Info, Checks_Wrong{entries_right = u64(entries_right), faults_right = u64(faults_right), pages_right = u64(pages_right), wakes_right = u64(pairs_right), lost = lost_wakes, stress_right = u64(stress_right), frames_right = u64(frames_stress_right)})
	}
	draw(&window)
	for {
		for _ in interface.window_next_event(&window_memory.drawing, &window) {}
		// The bars, the wheel and the page keys of a window that scrolls.
		if interface.window_scroll_frame_take(&window_memory.drawing) {
			draw(&window)
		}
		display.wait(&window, system.WAIT_FOREVER)
	}
}
