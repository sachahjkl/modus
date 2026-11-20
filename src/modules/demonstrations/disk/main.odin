// A check and a measure of the block service (src/library/contract/block), on a disk
// of its own: the disk of the measures, that holds no data of a process.
//
// The process reads and writes blocks in five runs: one block in each
// request, with one request in flight and then with 32. The check sends a
// fixed count of requests in each run, and no request must fail. In a
// [measure run](term:measure-run) each run goes on for one second, and
// the process writes the blocks in one second. In the two it
// counts the kernel entries of the two processes for each
// request: its own entries (the system library counts them) and those of
// the block service (the command Statistics). Then it writes a pattern,
// flushes, reads it back and compares.
//
// **What it is for.** It measures the cost of a disk under this design: a
// [block service](term:block-service) that is a process, a
// [block ring](term:block-ring) between two processes, and a
// [data region](term:data-region) that the device reads and writes
// directly. The kernel entries for each request show that the kernel is
// not on the path of the data: an entry is a wait or a wake, and one entry
// serves many requests when several are in flight.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("disk")` in the console. The window has one row for each of the
// five runs: a read or a write, the blocks in each request, the
// requests in flight, a bar of the requests that the check sent, and a bar
// of the kernel entries of this process and of the block service for 100
// requests. In a measure run (`modustool measure disk`) the first bar is
// the blocks in one second. Its lines in the log:
//
// - `disk: ok, the disk has <count> blocks, 64 blocks in one request at
//   most`;
// - one line for each run: `disk: read, 1 block in each request, 32 in
//   flight: 256 requests, ...`; in a measure run: `... 32 in flight: <rate>
//   blocks in one second, ...`;
// - `disk: a read of 2 blocks from the last block: ...`, the error record of
//   a read past the end of the disk, which the process checks field by
//   field;
// - one line for each word of a command record that names no command
//   (None, one past the last command, the largest word): `disk: the
//   command word 0 of the block ring: refused with Bad_Command and the
//   record Unsupported of the word, and the next Info is served: as it
//   must`;
// - `disk: the window sent the command words 0, <the first word past the
//   last display command> and 4294967295: the compositor read the three:
//   as it must`; the compositor writes its own
//   line at the first one, and the count when the window closes;
// - `disk: ok, 5 runs, 0 errors, write then read back: 0 wrong`, or
//   `disk: wrong: ...`.
//
// **Its grant**: **Scratch_Disk**: a block service of the
// [disk of the measures](term:disk-of-the-measures), and its block ring.
// The disk holds no data of a process, so the measure writes over it. The
// process has no store and no other disk.
//
// **What it does not prove.** The numbers are those of virtio under QEMU on
// the host of the run, not of a real disk: they are printed as measures,
// and no test compares them to a bound. The measures use the first 4096
// blocks (16 MiB) of the disk only.
package disk

import "base:intrinsics"
import "modus:contract/block"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

DURATION :: 1000 // Milliseconds of one measure, in a measure run.
REQUESTS_CHECKED :: 256 // The requests of one run of the check.
REGION_PAGES :: 256 // The data region: 1 MiB.
MEASURE_BLOCKS :: 4096 // The blocks that the measures use, from block 0: 16 MiB.

LINE :: 24
BAR_WIDTH :: 200
RATE_X :: 300
ENTRIES_X :: RATE_X + BAR_WIDTH + 90
// Literals, so the tool reads the window of the budget; the assertions
// keep them the sizes of the layout.
WIDTH :: 860
#assert(WIDTH == ENTRIES_X + BAR_WIDTH + 70)
HEIGHT :: 312
#assert(HEIGHT == 12 + 4 * LINE + len(measures) * LINE + 3 * LINE + 12)
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (525 pages): its module, its
// stack, its tables, its blocks and its glyph memory. The tool counts the
// window at the window bound (docs/MODULE_CONTRACT.md, "The budget that a
// module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1523, window_width = WIDTH, window_height = HEIGHT}

Measure :: struct {
	write:   bool,
	depth:   u32, // Requests in flight.
	blocks:  u64, // Blocks in each request.
	done:    bool,
	requests: u64, // The requests that the run sent and that were answered.
	rate:    u64, // Blocks in one second: a measure run only.
	client:  u64, // Kernel entries of this process for 100 requests.
	service: u64, // Kernel entries of the block service for 100 requests.
	errors:  u64,
}

measures := [?]Measure {
	{write = false, depth = 1, blocks = 1},
	{write = false, depth = 32, blocks = 1},
	{write = true, depth = 1, blocks = 1},
	{write = true, depth = 32, blocks = 1},
	{write = false, depth = 8, blocks = 16},
}

blocks: ring.Ring
region: [^]u8
disk_blocks: u64
wrong: u64 // The bytes of the check that did not read back as written, and its requests that failed.
statistics_tag: u32 = 1 << 31

// request sends one command, and waits for room if the queue is full.
request :: proc "contextless" (command: block.Command, tag: u32, values: [7]u64 = {}) {
	request_word(u32(command), tag, values)
}

// request_word sends one record with the word of its kind as it is: the
// cases of the words that name no command send it.
request_word :: proc "contextless" (word: u32, tag: u32, values: [7]u64 = {}) {
	record := ring.Record{kind = word, tag = tag, values = values}
	for !system.send(&blocks.commands, record) {
		wait: system.Wait
		system.wait_room(&wait, &blocks.commands)
		system.wait_end(&wait)
	}
}

// answer waits for the next completion.
answer :: proc "contextless" () -> ring.Record {
	for {
		if record, ok := system.receive(&blocks.completions); ok {
			return record
		}
		wait: system.Wait
		system.wait_records(&wait, &blocks.completions)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait)
		}
	}
}

// call sends one command and waits for its completion.
call :: proc "contextless" (command: block.Command, values: [7]u64 = {}) -> ring.Record {
	return call_word(u32(command), values)
}

// call_word sends one record with the word of its kind as it is, and waits
// for its completion.
call_word :: proc "contextless" (word: u32, values: [7]u64 = {}) -> ring.Record {
	statistics_tag += 1
	request_word(word, statistics_tag, values)
	for {
		record := answer()
		if record.tag == statistics_tag {
			return record
		}
	}
}

// service_entries gives the kernel entries of the block service so far,
// from the command `Statistics`.
service_entries :: proc "contextless" () -> u64 {
	return call(.Statistics).values[2]
}

// run keeps `measure.depth` requests in flight, each of `measure.blocks`
// blocks, at places that walk the first 4096 blocks of the disk. The check
// ends after REQUESTS_CHECKED answers; a measure run goes on for one
// second, and has the rate. It writes the kernel entries of the two
// processes for 100 requests and the failed requests into the record, and
// one line on the log.
run :: proc "contextless" (measure: ^Measure) {
	measured := system.measure_run()
	command := measure.write ? block.Command.Write : block.Command.Read
	next: u64 // The number of the next request.
	issue :: proc "contextless" (command: block.Command, measure: ^Measure, next: ^u64) {
		place := next^ % u64(measure.depth)
		first := next^ * measure.blocks % (MEASURE_BLOCKS - measure.blocks)
		request(command, u32(place), {0 = first, 1 = measure.blocks, 2 = place * measure.blocks * block.BLOCK_SIZE})
		next^ += 1
	}
	service_before := service_entries()
	client_before := system.kernel_entries()
	start := system.time()
	for _ in 0 ..< measure.depth {
		issue(command, measure, &next)
	}
	done: u64
	for {
		record := answer()
		if block.Status(record.kind) != .Ok {
			measure.errors += 1
		}
		done += 1
		if (measured ? system.time() - start >= DURATION : done >= REQUESTS_CHECKED) {
			break
		}
		issue(command, measure, &next)
	}
	for done < next {
		if block.Status(answer().kind) != .Ok {
			measure.errors += 1
		}
		done += 1
	}
	elapsed := max(system.time() - start, 1)
	client := system.kernel_entries() - client_before
	service := service_entries() - service_before
	measure.requests = done
	measure.client = client * 100 / max(done, 1)
	measure.service = service * 100 / max(done, 1)
	measure.done = true
	direction := value_kinds.text_field(measure.write ? "write" : "read", 8)
	block_word := value_kinds.text_field(measure.blocks == 1 ? "block" : "blocks", 8)
	if !measured {
		system.log_fact(.Info, Run_Checked{request_blocks = measure.blocks, depth = u64(measure.depth), requests = done, own_entries = measure.client, service_entries = measure.service, request_errors = measure.errors, direction = direction, block_word = block_word})
		return
	}
	measure.rate = done * measure.blocks * 1000 / elapsed
	system.log_fact(.Info, Run_Measured{request_blocks = measure.blocks, depth = u64(measure.depth), blocks_in_second = measure.rate, own_entries = measure.client, service_entries = measure.service, request_errors = measure.errors, direction = direction, block_word = block_word})
}

// check writes a pattern in 128 blocks after the blocks of the measures,
// flushes, reads the blocks back into the second half of the region, and
// compares each byte. Each failed request and each wrong byte adds 1 to
// `wrong`.
check :: proc "contextless" () {
	COUNT :: 128
	for index in 0 ..< COUNT * block.BLOCK_SIZE {
		region[index] = u8(index / block.BLOCK_SIZE * 7 + index % 251)
	}
	for request_index in u64(0) ..< COUNT / 16 {
		request(.Write, u32(request_index), {0 = MEASURE_BLOCKS + request_index * 16, 1 = 16, 2 = request_index * 16 * block.BLOCK_SIZE})
	}
	for _ in 0 ..< COUNT / 16 {
		if block.Status(answer().kind) != .Ok {
			wrong += 1
		}
	}
	if block.Status(call(.Flush).kind) != .Ok {
		wrong += 1
	}
	base := u64(COUNT * block.BLOCK_SIZE)
	for request_index in u64(0) ..< COUNT / 16 {
		request(.Read, u32(request_index), {0 = MEASURE_BLOCKS + request_index * 16, 1 = 16, 2 = base + request_index * 16 * block.BLOCK_SIZE})
	}
	for _ in 0 ..< COUNT / 16 {
		if block.Status(answer().kind) != .Ok {
			wrong += 1
		}
	}
	for index in 0 ..< COUNT * block.BLOCK_SIZE {
		if region[base + u64(index)] != region[index] {
			wrong += 1
		}
	}
}

// The words of the kind of a command record that name no command: None,
// the word one past the last command, and the largest word of the field.
// The block service decides each one at its border, which a host test
// gives the same words (block.command_of_ring_word); this case shows that
// the service answers what its border decided.
@(rodata)
refused_block_words := [3]u32{u32(block.Command.None), u32(max(block.Command)) + 1, max(u32)}

// The same three words for the kind of a record of the ring of a window
// (display.command_of_ring_word).
@(rodata)
refused_window_words := [3]u32{u32(display.Command.None), u32(max(display.Command)) + 1, max(u32)}

// block_words_check sends each refused word to the block service, checks
// that the completion is Bad_Command with the record Unsupported of the
// word, and that the next Info gives the same disk: the refusal changed
// nothing. One line for each word.
block_words_check :: proc "contextless" () {
	for word in refused_block_words {
		refused := call_word(word)
		error := errors.completion_record(refused.values)
		after := call(.Info)
		right := refused.kind == u32(block.Status.Bad_Command) && error.kind == i64(errors.Kind.Unsupported) && error.unit == i64(errors.Unit.None) && error.operation == i64(word) && error.argument == 0 && error.value == i64(word) && after.kind == u32(block.Status.Ok) && after.values[0] == disk_blocks
		if right {
			system.log_fact(.Info, Command_Word_Refused{command_word = u64(word)})
		} else {
			system.log_fact(.Info, Command_Word_Not_Refused{command_word = u64(word), status_word = u64(refused.kind), error_kind = errors.Kind_Word(max(error.kind, 0)), operation_word = u64(max(error.operation, 0)), next_status_word = u64(after.kind)})
		}
	}
}

// window_words_check writes each refused word on the ring of the window,
// then waits until the compositor read the three records. The compositor
// sends no answer on that ring: its answer is one line of the log at the
// first refused word, and the count when the window closes, which the
// scenario of the tool waits for. The wait wakes at each turn of the
// compositor that took a record of this window; the bound only ends a hang.
window_words_check :: proc "contextless" (window: ^display.Window) {
	for word in refused_window_words {
		for !system.send(&window.ring.commands, ring.Record{kind = word}) {
			list: system.Wait
			system.wait_room(&list, &window.ring.commands)
			system.wait_end(&list)
		}
	}
	counters := window.ring.commands.counters
	written := intrinsics.atomic_load_explicit(&counters.write, .Relaxed)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		read := intrinsics.atomic_load_explicit(&counters.read, .Relaxed)
		if i32(read - written) >= 0 {
			system.log_fact(.Info, Window_Words_Read{first_word = u64(refused_window_words[0]), second_word = u64(refused_window_words[1]), third_word = u64(refused_window_words[2])})
			return
		}
		if system.time() >= deadline {
			system.log_fact(.Info, Window_Words_Not_Read{first_word = u64(refused_window_words[0]), second_word = u64(refused_window_words[1]), third_word = u64(refused_window_words[2]), bound = u64(system.TEST_HANG_BOUND_MILLISECONDS)})
			return
		}
		list: system.Wait
		system.wait_word(&list, &counters.read, read, &counters.writer_waits)
		system.wait_end(&list, deadline)
	}
}

checked: bool

// The columns of a row of the table, from the left margin: the kind of the
// request, its blocks and their word, the requests in flight, the rate and
// the kernel entries.
ROW_SIZES :: [6]interface.Size{{.Pixels, 52}, {.Pixels, 28}, {.Pixels, 64}, {.Pixels, RATE_X - 156}, {.Pixels, ENTRIES_X - RATE_X}, {.Share, 1}}
// The columns of the head of the table: the request, the requests in
// flight, the rate and the kernel entries.
HEAD_SIZES :: [4]interface.Size{{.Pixels, 128}, {.Pixels, RATE_X - 140}, {.Pixels, ENTRIES_X - RATE_X}, {.Share, 1}}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	measured := system.measure_run()
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measured ? measure.rate : measure.requests), max(most_entries, measure.client + measure.service)
	}
	// Each line is a line of a table: its text 4 pixels under its top.
	column := interface.column_of({12, 8, WIDTH - 24, HEIGHT - 8})
	interface.cell_text(&frame, interface.column_take(&column, LINE), "the block service: a virtio disk, a ring, the data in shared memory.", graphics.colors.dim)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "the device reads and writes the memory of this process: no copy.", graphics.colors.dim)
	// The size of the disk: a label, its number, and the unit after it.
	number: interface.Text_Builder
	disk_line := interface.column_take(&column, LINE)
	text_y := disk_line.y + (disk_line.height - interface.line_height({})) / 2
	interface.draw_text(frame.table, disk_line.x, text_y, "disk:", graphics.colors.dim)
	after := interface.draw_text(frame.table, disk_line.x + 48, text_y, interface.number_text(&number, disk_blocks), graphics.colors.text)
	interface.cell_text(&frame, {after + 8, disk_line.y, disk_line.x + disk_line.width - (after + 8), disk_line.height}, "blocks of 4096 bytes", graphics.colors.dim)
	interface.column_take(&column, LINE / 2)
	head_sizes := HEAD_SIZES
	head: [len(HEAD_SIZES)]interface.Area
	interface.row_split(interface.column_take(&column, LINE), head_sizes[:], head[:])
	titles := [len(HEAD_SIZES)]string{"request", "in flight", measured ? "blocks in one second" : "requests answered", "kernel entries, 100 requests"}
	for title, index in titles {
		interface.cell_text(&frame, head[index], title, graphics.colors.dim)
	}
	row_sizes := ROW_SIZES
	cells: [len(ROW_SIZES)]interface.Area
	for measure, index in measures {
		row := interface.column_take(&column, LINE)
		interface.table_band(&frame, {row.x - 6, row.y, row.width + 12, row.height}, index)
		interface.row_split(row, row_sizes[:], cells[:])
		interface.cell_text(&frame, cells[0], measure.write ? "write" : "read", graphics.colors.text)
		interface.cell_text(&frame, cells[1], interface.number_text(&number, measure.blocks), graphics.colors.text)
		interface.cell_text(&frame, cells[2], measure.blocks == 1 ? "block" : "blocks", graphics.colors.dim)
		interface.cell_text(&frame, cells[3], interface.number_text(&number, u64(measure.depth)), graphics.colors.text)
		if measure.done {
			interface.bar_with_value(&frame, cells[4], BAR_WIDTH, measured ? measure.rate : measure.requests - measure.errors, most_rate, measure.errors == 0 ? graphics.colors.process : graphics.colors.failed)
			interface.bar_with_value(&frame, cells[5], BAR_WIDTH, measure.client + measure.service, most_entries, graphics.colors.kernel)
		} else {
			interface.cell_text(&frame, cells[4], "...", graphics.colors.dim)
		}
	}
	interface.column_take(&column, LINE / 2)
	checked_line := interface.column_take(&column, LINE)
	if checked {
		interface.cell_text(&frame, checked_line, wrong == 0 ? "write, flush, read back: 128 blocks, 0 wrong" : "write, flush, read back: WRONG", wrong == 0 ? graphics.colors.process : graphics.colors.failed)
	}
	measure_line := interface.column_take(&column, LINE)
	if !measured {
		interface.cell_text(&frame, measure_line, "the blocks in one second are a measure: run `modustool measure disk`.", graphics.colors.dim)
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// entry runs the five runs once, shows them, then keeps the window open
// until the process is stopped.
//
// **What it does**, in order:
//
// 1. It opens a window, the block ring, and a data region of 256 pages
//    (1 MiB, contiguous: the device reads and writes it).
// 2. It gives the data region to the block service through the block ring,
//    and sends `Attach`. The block service maps the ring when it starts; the
//    process tries again each millisecond, until the hang bound.
// 3. It asks `Info` for the size of the disk.
// 4. It runs each of the five runs (`run`): a count of requests, or one
//    second in a measure run.
// 5. It writes a pattern, flushes, reads it back and compares (`check`).
// 6. It reads 2 blocks from the last block of the disk, and checks the
//    error record of the refusal: kind `Out_Of_Range`, argument 1, value
//    the count of blocks + 1, limit the count of blocks.
// 7. It sends the three words that name no command to the block service
//    and checks each answer (`block_words_check`), then writes them on the
//    ring of its window and waits until the compositor read them
//    (`window_words_check`).
// 8. It writes the summary line, then draws the window at each event.
//
// **The stop**: with no window, no block ring, no data region, no block
// service, or a refused `Attach`, it writes the reason on the log and stops
// with `Failed`. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "disk")
	if !ok {
		system.stop(.Failed)
	}
	ring_memory := ctx.handles[block.GRANT_RING]
	status: system.Status
	if blocks, status = system.ring_open(ring_memory); status != .Ok {
		system.log_fact(.Info, No_Block_Ring{})
		system.stop(.Failed)
	}
	memory, memory_status := system.memory_create(REGION_PAGES, 0, {.Contiguous}) // The device reads and writes it.
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		system.log_fact(.Info, No_Data_Region{})
		system.stop(.Failed)
	}
	region = ([^]u8)(address)
	// The data region goes to the block service through the block ring.
	// The block service maps the ring when it starts: until then, the kernel
	// does not know the other side. The bound only ends a hang: a loaded
	// host can start the block service late.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; give_status != .Ok && system.time() < deadline; {
		if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok {
		system.log_fact(.Info, Block_Ring_Not_Mapped{})
		system.stop(.Failed)
	}
	if attached := call(.Attach, {0 = u64(given)}); block.Status(attached.kind) != .Ok {
		system.log_fact(.Warning, Data_Region_Refused(errors.error_record_fact_fields(errors.completion_record(attached.values))))
		system.stop(.Failed)
	}
	info := call(.Info)
	disk_blocks = info.values[0]
	system.log_fact(.Info, Disk_Ready{disk_blocks = disk_blocks, request_blocks_most = info.values[1]})
	draw(&window)
	error_count: u64
	for &measure in measures {
		run(&measure)
		error_count += measure.errors
		draw(&window)
	}
	check()
	checked = true
	// A request past the end of the disk: the completion holds its error
	// record.
	past := call(.Read, {0 = disk_blocks - 1, 1 = 2, 2 = 0})
	past_error := errors.completion_record(past.values)
	past_right := block.Status(past.kind) == .Out_Of_Range && errors.Kind(past_error.kind) == .Out_Of_Range && past_error.argument == 1 && u64(past_error.value) == disk_blocks + 1 && u64(past_error.limit) == disk_blocks
	if past_right {
		system.log_fact(.Info, Read_Past_End_Refused(errors.error_record_fact_fields(past_error)))
	} else {
		system.log_fact(.Info, Read_Past_End_Not_Refused(errors.error_record_fact_fields(past_error)))
	}
	// Each of these writes its own line with "as it must" or "WRONG": the
	// scenario of the tool waits for each line.
	block_words_check()
	window_words_check(&window)
	if error_count == 0 && wrong == 0 {
		system.log_fact(.Info, Disk_Held{runs = u64(len(measures))})
	} else {
		system.log_fact(.Info, Disk_Wrong{request_errors = error_count, wrong_bytes = wrong})
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
