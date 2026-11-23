// A demonstration of communication between processes: a ring is the one way
// that processes communicate, and a process reaches only the rings that it
// was given.
//
// Each square is a process with its own address space. Each line between two
// squares is a ring: two pages of shared memory. A small colored square is a
// record. A node takes a record from the ring before it, works on it for
// some time, and puts it in the ring after it. No record goes through the
// kernel: the kernel only wakes a process that waits.
//
// This process starts the nodes and gives each one its rings. It maps the
// same rings, so the picture is the real content of the queues.
//
//   left button on a node, or a: add a record
//   right button on a node, or 1 to 6: stop the process, or start it again
//
// A stopped node takes no record: the records wait in the ring before it.
// A ring holds 32 records. When it is full, the node before keeps its
// record and waits.
//
// **What it is for.** It makes the base interface of the kernel visible:
// six isolated processes in a circle, each with four memory objects and no
// other handle. The picture is not a model: it is the content of the real
// queues, which this process maps too. A stopped node shows that the others
// go on, and that its records wait for it in its ring.
//
// **Start**: `start("rings")` in the console, or the bar of the desktop. It
// starts its six nodes from the boot image (the module `node`), each with
// its own work time: 260, 420, 180, 700, 240 and 340 ms. Its budget has room
// for seven processes: itself and the six nodes.
//
// **Grants**, as the root service gives them:
//
// - **Image**: the boot image, read-only, to start the nodes from it.
//
// **What a reader sees**: the circle of nodes, the records in each ring, an
// arrow on each ring from the node that writes it to the node that reads it,
// the record that each node holds, and its work time. The log has "rings: ok, 6
// processes, 6 rings, 5 records", "rings: node N stopped" or "started" after
// a key, "rings: the key a adds a record: N records in all", "rings: node N
// stopped alone" when the kernel stopped it, and
// "rings: node N does not run: M records wait in the ring before it".
package rings

import "modus:contract/draw_record"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:relay"
import "modus:contract/ring"
import "modus:random"
import "modus:system"

// Six nodes: 4114 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 4114 + 354 = 4468.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4468, processes = 7, threads = 7, window_width = WIDTH, window_height = HEIGHT}

WIDTH :: 720
HEIGHT :: 540
NODE_SIZE :: 92
FRAME_TIME :: 33
START_RECORDS :: 5
CELL :: 8 // The side of a record in the picture.
SHOWN_RECORDS :: 9 // Records of a ring that the picture shows as squares.


Node :: struct {
	process:        system.Handle, // 0: the process does not run.
	after_memory:   system.Handle, // The ring from this node to the next one.
	after:          ring.Ring,
	control_memory: system.Handle,
	control:        ring.Ring,
	state_memory:   system.Handle,
	state:          ^relay.State,
	waiting_logged: bool,
}

nodes: [relay.NODE_COUNT]Node
prepared: system.Prepared_Modules // The shared code of the nodes.
image: []u8
added: int

// The center of each node, and the time that it keeps a record.
@(rodata)
centers := [relay.NODE_COUNT][2]int{{360, 84}, {540, 180}, {540, 356}, {360, 452}, {180, 356}, {180, 180}}
@(rodata)
work_times := [relay.NODE_COUNT]u64{260, 420, 180, 700, 240, 340}

// series_color gives the color of a series number of a record. The number
// comes from a node, another process: it is taken modulo the count of the
// series, never used as it is.
series_color :: proc "contextless" (number: u64) -> graphics.Color {
	return graphics.colors.series[number % graphics.SERIES_COLOR_COUNT]
}

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Info, Start_Failed{cause = cause_field(text)})
	system.stop(.Failed)
}

// node_start starts the process of a node. The process receives the ring
// before it, the ring after it, its control ring and its state. A node that
// starts again has the same rings: the records that waited are still there.
node_start :: proc "contextless" (index: int) -> bool {
	node := &nodes[index]
	node.state^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[relay.GRANT_BEFORE] = {nodes[(index + relay.NODE_COUNT - 1) % relay.NODE_COUNT].after_memory, {.Read, .Write}}
	grants[relay.GRANT_AFTER] = {node.after_memory, {.Read, .Write}}
	grants[relay.GRANT_CONTROL] = {node.control_memory, {.Read, .Write}}
	grants[relay.GRANT_STATE] = {node.state_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	values[relay.VALUE_WORK_TIME] = work_times[index]
	name := [?]u8{'n', 'o', 'd', 'e', ' ', u8('1' + index)}
	status: system.Status
	node.process, status = system.process_start(system.image_find(image, "node"), string(name[:]), grants, random.values_with_seed(&process_generator, values), {pages = 256, processes = 1, threads = 1, processor = 200_000, log_records = 100}, nil, &prepared)
	node.waiting_logged = false
	return status == .Ok
}

// node_stop closes the handle of the process: the kernel stops it. The
// record that the node had is lost with the process.
node_stop :: proc "contextless" (index: int) {
	system.close(nodes[index].process)
	nodes[index].process = 0
	nodes[index].state^ = {}
}

toggle :: proc "contextless" (index: int) {
	if nodes[index].process != 0 {
		node_stop(index)
		system.log_fact(.Info, Node_Stopped{node = u64(index + 1)})
	} else if node_start(index) {
		system.log_fact(.Info, Node_Started{node = u64(index + 1)})
	}
}

// add gives a new record to a node, through its control ring.
add :: proc "contextless" (index: int) {
	node := &nodes[index]
	if system.send(&node.control.commands, ring.Record{kind = relay.RECORD, values = {0 = u64(added % graphics.SERIES_COLOR_COUNT)}}) {
		added += 1
	}
}

// pending gives the records that wait in a queue. The other processes write
// the two counters: the result is never more than the capacity.
pending :: proc "contextless" (queue: ^ring.Queue) -> (first, count: u32) {
	return queue.counters.read, ring.count(queue)
}

// The drawing of the window with the interface package: the tables of the
// frame now and of the frame on the surface.
window_memory: interface.Window_Memory(384, 2048)

// The random generator of this process (src/library/modus/random).
process_generator: random.Generator

// The entry of rings: it makes the rings, starts the six nodes, puts five
// records in the circle, then draws and answers keys and clicks for ever.
//
// It takes its random generator: each node gets its seed from it. With no
// seed, it stops with `Refused`; with no window, no boot image, no memory
// for the rings or a node that does not start, with `Failed` (`fail`). Each turn of the loop
// takes the events, looks for a node that stopped (`watch`), draws the
// rings, and waits 33 ms or until the next event.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this process, from the seed that its starter
	// gave: it gives the seed of each process that this one starts.
	if !random.generator_from_context(&process_generator, ctx) {
		system.log_fact(.Info, No_Random_Seed{})
		system.stop(.Refused)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "rings")
	if !ok {
		fail("no surface")
	}
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	} else {
		fail("no grant to read the boot image")
	}
	for &node in nodes {
		status: system.Status
		node.after_memory, node.after, status = system.ring_create()
		if status == .Ok {
			node.control_memory, node.control, status = system.ring_create()
		}
		if status == .Ok {
			node.state_memory, status = system.memory_create(1)
		}
		address: rawptr
		if status == .Ok {
			address, status = system.memory_map(node.state_memory)
		}
		if status != .Ok {
			fail("no memory for the rings")
		}
		node.state = (^relay.State)(address)
	}
	for index in 0 ..< relay.NODE_COUNT {
		if !node_start(index) {
			fail("cannot start a node")
		}
	}
	for index in 0 ..< START_RECORDS {
		add(index)
	}
	system.log_fact(.Info, Nodes_Running{processes = u64(relay.NODE_COUNT), rings = u64(relay.NODE_COUNT), records = u64(START_RECORDS)})

	buttons: u32
	for {
		for event in interface.window_next_event(&window_memory.drawing, &window, .Every_Event) {
			switch event.kind {
			case .Key:
				if !event.pressed {
					continue
				}
				// The open list of the action bar takes its keys first.
				press := interface.Key_Press{code = event.code, character = event.character, modifiers = event.modifiers}
				outcome := interface.action_bar_key(&bar, press)
				if outcome.ran {
					key_run(outcome.run)
				}
				if !outcome.taken {
					key_run(press)
				}
			case .Pointer:
				pressed := event.buttons & ~buttons
				buttons = event.buttons
				// The action bar takes the pointer from the input of the
				// next frame; a press on it, or while its list is open, is
				// not a press on a square.
				// The squares are in the coordinates of the layout, which
				// the window scrolls when it does not fit the work area.
				if interface.action_bar_takes_pointer(&bar, event.x, event.y) {
					continue
				}
				for center, index in centers {
					if abs(event.x - center.x) > NODE_SIZE / 2 || abs(event.y - center.y) > NODE_SIZE / 2 {
						continue
					}
					if pressed & display.BUTTON_LEFT != 0 {
						add(index)
					}
					if pressed & display.BUTTON_RIGHT != 0 {
						toggle(index)
					}
				}
			case .None, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Surface_Answer, .Work_Area:
				// next_event never gives None, and this window does nothing for the other events.
			}
		}
		now := system.time()
		watch()
		frame := interface.window_frame_start(&window_memory, &window)
		interface.action_bar_input_take(&frame, &bar)
		draw(frame.table, now)
		// The keys of the window, in its action bar (docs/INTERFACE.md,
		// "4.4 The action bar"), at the right of what the pointer does.
		// The items stand from the right edge.
		bar_y := HEIGHT - interface.ACTION_BAR_ROW_HEIGHT
		pointer_end := interface.draw_text(frame.table, 12, bar_y + (interface.ACTION_BAR_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, POINTER_NOTE, graphics.colors.dim)
		bar_left := pointer_end + 16
		items := bar_items()
		bar_result := interface.action_bar(&frame, {bar_left, bar_y, WIDTH - bar_left, interface.ACTION_BAR_ROW_HEIGHT}, items[:], &bar, {alignment = .Right})
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		if bar_result.ran {
			key_run(bar_result.run)
		}
		display.wait(&window, now + FRAME_TIME)
	}
}

// What the pointer does on a square: a fact at the left of the action bar.
POINTER_NOTE :: "click a square: left adds, right stops or starts"

// The keys of the window. The keys 1 to 6 stop or start the process with
// that number: a key with an argument takes no press, and a click on its
// square does the same.
// A procedure, not a global array: an item is made by a call, and a
// freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [2]interface.Action_Bar_Item {
	return {interface.action_bar_item("add a record", 2, "a"), interface.action_bar_item("stop or start", 1, "1-6")}
}
#assert(relay.NODE_COUNT == 6) // The face "1-6" names the keys of the processes.
bar: interface.Action_Bar_State

// key_run runs one key: a typed key, or the key of an item of the action
// bar that a press ran.
key_run :: proc "contextless" (press: interface.Key_Press) {
	switch press.character {
	case '1' ..= '0' + relay.NODE_COUNT:
		toggle(int(press.character - '1'))
	case 'a':
		add(added % relay.NODE_COUNT)
		system.log_fact(.Info, Record_Added{records = u64(added)})
	}
}

// watch finds a node that the kernel stopped, and writes on the log when all
// the records wait before a stopped node.
watch :: proc "contextless" () {
	total: u32
	for &node in nodes {
		_, count := pending(&node.after.commands)
		total += count + node.state.holding
	}
	for &node, index in nodes {
		if node.process != 0 {
			if state, _, _ := system.process_state(node.process); state == .Stopped {
				node_stop(index)
				system.log_fact(.Info, Node_Stopped_Alone{node = u64(index + 1)})
			}
			continue
		}
		_, count := pending(&nodes[(index + relay.NODE_COUNT - 1) % relay.NODE_COUNT].after.commands)
		if count == total && total > 0 && !node.waiting_logged {
			node.waiting_logged = true
			system.log_fact(.Info, Records_Wait_Before_Node{node = u64(index + 1), records = u64(total)})
		}
	}
}

// The arrow of a ring, in pixels from the center of the node that writes
// the ring: its base and its tip on the line, out of the card of the node,
// and half its width. The records wait at the other end, next to the node
// that reads them.
ARROW_BASE :: NODE_SIZE / 2 + 14
ARROW_TIP :: NODE_SIZE / 2 + 28
ARROW_HALF_WIDTH :: 7

// ring_arrow_draw draws the arrow of the ring from one node to the next:
// a triangle, one filled path with antialiased edges, along the line of
// the ring at any angle.
ring_arrow_draw :: proc "contextless" (table: ^interface.Draw_Table, from, to: [2]int) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	along_x, along_y := i64(to.x - from.x), i64(to.y - from.y)
	length := i64(interface.square_root_floor(u64(along_x * along_x + along_y * along_y)))
	if length <= ARROW_TIP {
		return
	}
	// A place on the line, at a distance from the center of the writer, and
	// a step across it, in units.
	on_line :: proc "contextless" (center: int, along, length, distance: i64) -> i64 {
		return i64(center) * UNITS + along * distance * UNITS / length
	}
	across_x := -along_y * ARROW_HALF_WIDTH * UNITS / length
	across_y := along_x * ARROW_HALF_WIDTH * UNITS / length
	base_x, base_y := on_line(from.x, along_x, length, ARROW_BASE), on_line(from.y, along_y, length, ARROW_BASE)
	tip_x, tip_y := on_line(from.x, along_x, length, ARROW_TIP), on_line(from.y, along_y, length, ARROW_TIP)
	points := [4]interface.Path_Point {
		{command = .Move, x = i32(base_x + across_x), y = i32(base_y + across_y)},
		{command = .Line, x = i32(tip_x), y = i32(tip_y)},
		{command = .Line, x = i32(base_x - across_x), y = i32(base_y - across_y)},
		{command = .Close},
	}
	interface.draw_path(table, points[:], draw_record.opaque(graphics.colors.dim), 0, 0)
}

draw :: proc "contextless" (table: ^interface.Draw_Table, now: u64) {
	interface.draw_text(table, 12, 8, "Each square is a process. Each line is a ring in shared memory.", graphics.colors.text)
	// The band of the action bar, from edge to edge.
	bar_y := HEIGHT - interface.ACTION_BAR_ROW_HEIGHT
	interface.draw_rectangle(table, 0, bar_y, WIDTH, interface.ACTION_BAR_ROW_HEIGHT, graphics.colors.card_bottom)
	interface.draw_rectangle(table, 0, bar_y, WIDTH, 1, graphics.colors.track)

	// The rings, under the nodes.
	for &node, index in nodes {
		from := centers[index]
		to := centers[(index + 1) % relay.NODE_COUNT]
		// A ring is a line of less weight than the nodes and the records, and
		// its arrow says the way that its records go.
		interface.draw_line(table, from.x, from.y, to.x, to.y, 2, graphics.colors.dim)
		ring_arrow_draw(table, from, to)
		first, count := pending(&node.after.commands)
		// The oldest record is next to the node that reads the ring.
		length := abs(to.x - from.x) + abs(to.y - from.y)
		for position in 0 ..< min(count, SHOWN_RECORDS) {
			record := node.after.commands.records[(first + position) & node.after.commands.mask]
			// 256 is the end of the line at the reader. The first square is
			// just out of the node.
			along := 256 - (NODE_SIZE / 2 + 10 + int(position) * (CELL + 3)) * 256 * 3 / (length * 2)
			x := from.x + (to.x - from.x) * along / 256
			y := from.y + (to.y - from.y) * along / 256
			interface.draw_rectangle(table, x - CELL / 2 - 1, y - CELL / 2 - 1, CELL + 2, CELL + 2, graphics.colors.background)
			interface.draw_rectangle(table, x - CELL / 2, y - CELL / 2, CELL, CELL, series_color(record.values[0]))
		}
		// The number of records in the ring, beside the middle of the line.
		middle_x := (from.x + to.x) / 2 + (to.y - from.y) / 7 - 20
		middle_y := (from.y + to.y) / 2 - (to.x - from.x) / 7 - 8
		color := count == ring.CAPACITY ? graphics.colors.warning : graphics.colors.dim
		x := interface.draw_unsigned(table, middle_x, middle_y, u64(count), color)
		interface.draw_text(table, x, middle_y, "/32", color)
	}

	for &node, index in nodes {
		center := centers[index]
		x, y := center.x - NODE_SIZE / 2, center.y - NODE_SIZE / 2
		state := node.state^ // One copy: the node writes this record.
		// A node runs, is blocked by a full ring, or is stopped. A stopped
		// node is there and cannot be used: its border is the color of what
		// is not usable, which is not a text, so its word is the dim text.
		border := graphics.colors.process
		status_color := graphics.colors.process
		status := "waits"
		switch {
		case node.process == 0:
			border, status_color, status = graphics.colors.not_usable, graphics.colors.dim, "stopped"
		case state.blocked != 0:
			border, status_color, status = graphics.colors.warning, graphics.colors.warning, "ring full"
		case state.holding != 0:
			status = "works"
		}
		// A node is a card: one subject.
		interface.draw_rectangle(table, x, y, NODE_SIZE, NODE_SIZE, graphics.colors.card_top)
		interface.draw_outline(table, x, y, NODE_SIZE, NODE_SIZE, 2, border)
		after := interface.draw_text(table, x + 8, y + 6, "node ", graphics.colors.text)
		interface.draw_unsigned(table, after, y + 6, u64(index + 1), graphics.colors.text)
		interface.draw_text(table, x + 8, y + 24, status, status_color)
		if state.holding != 0 {
			// The record, and the part of the work that is done.
			interface.draw_rectangle(table, x + 8, y + 46, 14, 14, series_color(u64(state.series)))
			span := max(state.release - state.since, 1)
			done := min(now - min(state.since, now), span)
			interface.draw_rectangle(table, x + 28, y + 50, NODE_SIZE - 36, 6, graphics.colors.track)
			interface.draw_rectangle(table, x + 28, y + 50, int(done * (NODE_SIZE - 36) / span), 6, series_color(u64(state.series)))
		}
		interface.draw_unsigned(table, x + 8, y + NODE_SIZE - 22, state.passed, graphics.colors.dim)
		interface.draw_unsigned(table, x + NODE_SIZE - 8 - 5 * graphics.CELL_WIDTH, y + NODE_SIZE - 22, work_times[index], graphics.colors.dim, 3)
		interface.draw_text(table, x + NODE_SIZE - 8 - 2 * graphics.CELL_WIDTH, y + NODE_SIZE - 22, "ms", graphics.colors.dim)
	}
}
