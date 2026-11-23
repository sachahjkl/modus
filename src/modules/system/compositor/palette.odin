package compositor

import process_page "modus:contract/disk_process_page"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/palette_table"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "internal:compositor/bar"
import "modus:display"
import "modus:interface"
import "modus:line_editor"
import "internal:compositor/palette"
import "modus:system"
import "base:intrinsics"

// The palette of the desktop (docs/DESIGN.md, "Palette"): the panel that
// the key super opens. This file is its part in the compositor: the keys
// and the pointer that reach it, its two sources of entries (the names of
// the modules and the client table), what a chosen entry does, its draw
// table and its lines in the log. The state, the ranking and the draw
// records are in src/library/internal/compositor/palette, where the host tests run them.
//
// The panel holds no right. A process starts through the root service as
// the start menu starts it; a window comes to the front as a
// press brings it; a close stops a process as the close button does.

palette_panel: palette.Panel // The state of the panel. Its list is one of palette_lists.
kept_key: u32 // A key that the palette took when it was pressed: its release goes to no process.
// The measures of one open of the panel: the frames drawn while it is
// open and their time, in nanoseconds.
palette_frames, palette_time: u64
// The panel as draw records: the table of now, the table that the screen
// shows, the interface state.
// The records hold the icons of the 12 rows too: an icon is at most
// kind_icons.RECTANGLE_LIMIT rectangles, 240 for a full list; and the
// buttons of the setting rows, at most 3 records for each of 6 values.
palette_records_now, palette_records_before: [768]interface.Draw_Record
palette_text_now, palette_text_before: [6144]u8
palette_now, palette_before: interface.Draw_Table
palette_interface_state: interface.Interface_State
// The pointer, as the next frame of the panel reads it: the scroll bar of
// the panel is an element of the interface package, and takes its presses
// and its drags from here. palette_pointer fills it; a frame clears the
// press and the release that it read.
palette_input: interface.Input
palette_scroll_dragged: bool // The thumb that is held now moved the view: its release writes one line of the log.
// The named elements of the last frame of the panel, and the set that the
// log has: the facts Palette_Element_Placed, "compositor: the palette: the
// element field 1 at x,y,w,h", in pixels of the screen.
palette_element_places_drawn, palette_element_places_written: interface.Element_Places

// The ranking thread. The loop of the compositor never makes a list: it
// writes a request (the typed part, the windows, the remembered choices)
// and wakes the second thread, which collects the entries, copies and
// checks the table of the palette provider, ranks, and publishes the
// list. The loop then adopts it: one address changes.
//
// The two lists take turns. The thread writes only the list that the loop
// does not read: it starts a list only after the loop adopted the one
// before, so the loop never reads a list that changes. Each list's backing
// memory is sized on demand off the main thread for any entry count.
Palette_List_Memory :: struct {
	handle:            system.Handle,
	memory:            []u8,
	provider_capacity: int,
	total_capacity:    int,
}
palette_lists: [2]palette.List
palette_list_memories: [2]Palette_List_Memory

// palette_list_ensure grows the backing memory of palette_lists[slot] off the
// main thread whenever provider or total entries exceed its current capacity.
palette_list_ensure :: proc "contextless" (slot: u32, provider_needed, total_needed: int) -> bool {
	mem := &palette_list_memories[slot]
	if mem.provider_capacity >= provider_needed && mem.total_capacity >= total_needed && len(mem.memory) > 0 {
		return true
	}
	provider_cap := max(provider_needed, palette_table.INITIAL_ENTRY_CAPACITY)
	if mem.provider_capacity > 0 && provider_cap > mem.provider_capacity && mem.provider_capacity <= max(int) / 2 {
		provider_cap = max(provider_cap, mem.provider_capacity * 2)
	}
	base_local := len(bar.names) + 2 * CLIENT_CAPACITY + palette.FRONT_WINDOW_ENTRY_COUNT
	if provider_cap > max(int) - base_local {
		return false
	}
	total_cap := max(total_needed, provider_cap + base_local)
	if mem.total_capacity > 0 && total_cap > mem.total_capacity && mem.total_capacity <= max(int) / 2 {
		total_cap = max(total_cap, mem.total_capacity * 2)
	}
	bytes, ok := palette.list_memory_bytes(provider_cap, total_cap)
	if !ok || bytes > max(u64) - (system.PAGE_SIZE - 1) {
		return false
	}
	pages := (bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	if pages > max(u64) / system.PAGE_SIZE {
		return false
	}
	new_handle, create_status := system.memory_create(pages)
	if create_status != .Ok {
		return false
	}
	address, map_status := system.memory_map(new_handle, {.Write})
	if map_status != .Ok {
		system.close(new_handle)
		return false
	}
	new_memory := ([^]u8)(address)[:pages * system.PAGE_SIZE]
	if !palette.list_bind_memory(&palette_lists[slot], new_memory, provider_cap, total_cap) {
		system.memory_unmap(address)
		system.close(new_handle)
		return false
	}
	if mem.memory != nil {
		system.memory_unmap(raw_data(mem.memory))
		system.close(mem.handle)
	}
	mem^ = {handle = new_handle, memory = new_memory, provider_capacity = provider_cap, total_capacity = total_cap}
	return true
}

// A table of a provider that the interface thread retired: the ranking
// thread unmaps and closes it once neither thread reads it.
Table_Slot :: struct {
	handle: system.Handle,
	table:  []u8,
}

// An object of the entries alone that the provider gave with
// Table_Replaced (modus:contract/palette_table, "The object of the
// entries"). The compositor never maps it: the ranking thread proves it
// and copies it by the kernel (system.memory_read), so a revocation or a
// page with no frame is a status, not a fault that stops the trusted
// display.
Entries_Object :: struct {
	handle: system.Handle,
	bytes:  u64,
	number: u32, // As Header.entries_object names it: 1 for the first, then higher.
}

TABLE_QUEUE_CAPACITY :: 8

Ranking_Window :: struct {
	title:  system.Name,
	number: u32,
	focus:  bool,
	resizable: bool, // As palette.Window.resizable.
	maximized: bool, // As palette.Window.maximized.
	from_disk:   bool, // A window of a disk process: hash_prefix holds the hash prefix of its file.
	hash_prefix: [process_page.HASH_PREFIX_DIGITS]u8,
}

Ranking :: struct {
	// Held only for O(1) copies of small structs and queue pointers: never
	// held across memory_create, memory_map, memory_unmap, header_read, or
	// list_collect, so the compositor main thread never blocks on ranking work.
	lock:           system.Lock,
	query:          [palette.TYPED_CAPACITY]u8, // The typed part of the request.
	query_length:   int,
	windows:        [CLIENT_CAPACITY]Ranking_Window, // The windows, the front one first.
	window_count:   int,
	recents:        [palette.RECENT_CAPACITY]palette.Recent, // The remembered choices.
	recent_count:   int,
	frecency:       line_editor.Frecency, // The frecency of the panel.
	requested:      u32, // The number of the newest request. The thread waits on this word.
	published:      u32, // The lists that the thread published. The loop waits on this word.
	published_list: u32, // The index of the newest whole list.
	adopted:        u32, // The value of `published` that the loop adopted. The thread waits on this word.
	longest:        u64, // The longest making of a list since the last close of the panel, in nanoseconds.
	// The tables of the provider, handed over in constant time under `lock`:
	// - the interface thread queues each object of Table_Replaced in
	//   pending_entries, and retires the table of a provider that ends in
	//   retire_tables;
	// - the ranking thread proves each pending object, holds the newest one
	//   (palette_entries_held, its own), closes the ones before it, and
	//   unmaps and closes each retired table.
	provider_ring_handle: system.Handle,
	active_table_handle:  system.Handle,
	active_table:         []u8, // The table that the root service made: the header, the result, the candidates.
	pending_entries:      [TABLE_QUEUE_CAPACITY]Entries_Object,
	pending_entry_count:  int,
	retire_tables:        [TABLE_QUEUE_CAPACITY]Table_Slot,
	retire_table_count:   int,
}

palette_ranking: Ranking
// The main thread's read-only view of the active provider table: updated only
// on the main thread so palette_wait, palette_turn, and palette_answer read it
// with no lock and zero contention.
palette_main_table: []u8
// The copy of the frecency of a request, for the ranking thread only: a
// global, because the stack of that thread is small.
palette_ranking_frecency: line_editor.Frecency
palette_published_seen: u32 // The value of `published` that the loop saw last.
palette_enter_waits: bool // Enter came while the list of the typed part was not made yet: it runs when the list comes.
palette_go_to_waits: bool // Shift with Enter came while the list of the typed part was not made yet: it goes when the list comes.
palette_pressed_value: int = -1 // The value of a setting row where the left button went down, until it goes up; or palette.NO_ROW.
palette_pressed_button: int = -1 // The button of the field of a form where the left button went down, as an index in its shown candidates, until it goes up; or palette.NO_ROW.
palette_tab_waits: bool // Tab came while the candidates of the field were on their way: it acts when they come.
// The measures of one open of the panel: the lists that the loop adopted
// while it was open, and how many of them showed what the list before
// showed.
palette_adoptions, palette_adoptions_same: u64

// The palette provider, as the root service gave it: its ring and its
// entry table, read-only (modus:contract/palette_table). The table is hostile
// input: the ranking thread copies it and checks the copy.
palette_provider_ring: ring.Ring
palette_provider_ring_handle, palette_provider_table_handle: system.Handle
palette_provider_window_name: system.Name
palette_generation_seen: u32 // The change count of the table that the loop saw last.
palette_tags: u32 // The tag of the last choice sent.
palette_candidates_awaited: u32 // Not 0: the tag of the request for the candidates of the current field of the form.
palette_sent_setting: bool // The entry that the panel sent is a setting: the panel then goes back to its list.
palette_answer_awaited: u32 // Not 0: the tag of the choice whose answer the desktop still acts on.
// The name of the setting row that the log named last: the line of a row
// is written when the chosen row changes, not at each list.
palette_row_logged: [palette.NAME_CAPACITY]u8
palette_row_logged_length: int
ACT_NAME_SETS_LOGGED :: 8 // The sets of act names of one window that the log names: a window that changes its set at each frame does not fill the log.

// palette_start gives the draw tables their memory and their font, starts
// the ranking thread and asks for the first list. The compositor calls it
// once, after the interface font is loaded.
palette_start :: proc "contextless" () {
	palette_now = {records = palette_records_now[:], text = palette_text_now[:], interface_font = display.interface_font_of()}
	palette_before = {records = palette_records_before[:], text = palette_text_before[:], interface_font = palette_now.interface_font}
	palette_panel.pressed_row = palette.NO_ROW
	palette_panel.list = &palette_lists[0]
	if _, status := system.thread_start(palette_ranking_thread, nil); status != .Ok {
		system.log_fact(.Info, Ranking_Thread_Not_Started{})
	}
	palette_entries_refresh()
}

// The ranking thread's own state of the object of the entries: the object
// that it holds, and the ring of the provider that gave it.
palette_entries_held: Entries_Object
palette_entries_ring: system.Handle

// Why an object of Table_Replaced is refused.
Entries_Refusal :: enum {
	None,
	Not_Memory, // The handle names no memory object.
	Not_Read_Only, // It holds no Read, or holds Write or Execute.
	Uncommitted, // Its pages can have no frame.
	Not_Newer, // Its number is not past the number of the object that the ranking thread holds.
}

@(rodata)
palette_entries_refusal_names := [Entries_Refusal]string {
	.None          = "no problem",
	.Not_Memory    = "an object of the entries that is no memory",
	.Not_Read_Only = "an object of the entries that is not read-only",
	.Uncommitted   = "an object of the entries whose pages can have no frame",
	.Not_Newer     = "an object of the entries that is not newer than the one held",
}

// palette_entries_object_prove is the border of an object of
// Table_Replaced that came through the ring of the provider: a memory
// object, read-only, not Uncommitted, newer than the one held. Its bytes
// are the pages that the kernel counts, never the count of the record.
palette_entries_object_prove :: proc "contextless" (offer: Entries_Object, kind: op.Object_Kind, rights: system.Rights, held_number: u32) -> (held: Entries_Object, refusal: Entries_Refusal) {
	if kind != .Memory {
		return {}, .Not_Memory
	}
	if .Read not_in rights || .Write in rights || .Execute in rights {
		return {}, .Not_Read_Only
	}
	if offer.number <= held_number {
		return {}, .Not_Newer
	}
	pages, flags, status := system.memory_size_and_flags(offer.handle)
	if status != .Ok {
		return {}, .Not_Memory
	}
	if .Uncommitted in flags {
		return {}, .Uncommitted
	}
	return {handle = offer.handle, bytes = pages * system.PAGE_SIZE, number = offer.number}, .None
}

// palette_entries_copy copies the entries of the held object by the
// kernel: a page with no frame or a revocation is false, which the
// snapshot gives as Entries_Lost.
palette_entries_copy :: proc "contextless" (user: rawptr, into: []u8) -> bool {
	_, status := system.memory_read((^Entries_Object)(user).handle, 0, into)
	return status == .Ok
}

// palette_ranking_thread is the entry of the second thread: it makes one
// list for each request, the newest one when several came.
palette_ranking_thread :: proc "c" (parameter: rawptr) -> ! {
	ranking := &palette_ranking
	done: u32
	refused_before: palette_table.Problem
	for {
		system.word_wait(&ranking.requested, done)
		if intrinsics.atomic_load_explicit(&ranking.requested, .Relaxed) == done {
			continue
		}
		// The loop reads the list that it adopted: the other one is free
		// only when the loop adopted the newest published list.
		for {
			adopted := intrinsics.atomic_load_explicit(&ranking.adopted, .Relaxed)
			if adopted == intrinsics.atomic_load_explicit(&ranking.published, .Relaxed) {
				break
			}
			system.word_wait(&ranking.adopted, adopted)
		}
		// The request and any pending/retired table handoffs, copied under
		// ranking.lock (O(1)): no syscall or O(N) work runs under any lock.
		query: [palette.TYPED_CAPACITY]u8
		titles: [CLIENT_CAPACITY]system.Name
		prefixes: [CLIENT_CAPACITY][process_page.HASH_PREFIX_DIGITS]u8
		windows: [CLIENT_CAPACITY]palette.Window
		recents: [palette.RECENT_CAPACITY]palette.Recent
		pending: [TABLE_QUEUE_CAPACITY]Entries_Object
		retired: [TABLE_QUEUE_CAPACITY]Table_Slot
		system.lock(&ranking.lock)
		sequence := intrinsics.atomic_load_explicit(&ranking.requested, .Relaxed)
		query_length := copy(query[:], ranking.query[:clamp(ranking.query_length, 0, len(ranking.query))])
		window_count := clamp(ranking.window_count, 0, CLIENT_CAPACITY)
		for index in 0 ..< window_count {
			titles[index] = ranking.windows[index].title
			windows[index] = {title = system.name_of(titles[index][:]), number = ranking.windows[index].number, focus = ranking.windows[index].focus, resizable = ranking.windows[index].resizable, maximized = ranking.windows[index].maximized}
			if ranking.windows[index].from_disk {
				prefixes[index] = ranking.windows[index].hash_prefix
				windows[index].hash_prefix = string(prefixes[index][:])
			}
		}
		recent_count := copy(recents[:], ranking.recents[:clamp(ranking.recent_count, 0, len(ranking.recents))])
		palette_ranking_frecency = ranking.frecency
		retired_count := copy(retired[:], ranking.retire_tables[:ranking.retire_table_count])
		ranking.retire_table_count = 0
		pending_count := copy(pending[:], ranking.pending_entries[:ranking.pending_entry_count])
		ranking.pending_entry_count = 0
		ring_handle := ranking.provider_ring_handle
		active_handle := ranking.active_table_handle
		current_table := ranking.active_table
		system.unlock(&ranking.lock)

		// Unmap and close tables that the main thread retired (neither thread
		// reads them anymore).
		for slot in retired[:retired_count] {
			if slot.table != nil {
				system.memory_unmap(raw_data(slot.table))
			}
			if slot.handle != 0 {
				system.close(slot.handle)
			}
		}

		// The object of the entries belongs to one provider: a provider that
		// ended, or another one, takes the object of the one before with it.
		if ring_handle != palette_entries_ring {
			if palette_entries_held.handle != 0 {
				system.close(palette_entries_held.handle)
			}
			palette_entries_held = {}
			palette_entries_ring = ring_handle
		}
		// Prove each object of Table_Replaced off the interface thread, and
		// hold the newest one. None is mapped.
		if ring_handle != 0 {
			for offer in pending[:pending_count] {
				if offer.handle == palette_entries_held.handle || offer.handle == active_handle || offer.handle == ring_handle {
					continue
				}
				kind, rights, through := system.handle_state(offer.handle, ring_handle)
				// A number that did not come through the ring names no object
				// of the provider: it is not this thread's to close.
				if !through {
					continue
				}
				if held, refusal := palette_entries_object_prove(offer, kind, rights, palette_entries_held.number); refusal == .None {
					if palette_entries_held.handle != 0 {
						system.close(palette_entries_held.handle)
					}
					palette_entries_held = held
				} else {
					system.close(offer.handle)
					system.log_fact(.Warning, Provider_Table_Refused{entry_index = 0, table_problem = value_kinds.text_field(palette_entries_refusal_names[refusal], TABLE_PROBLEM_FIELD_BYTES)})
				}
			}
		}
		entries := palette_table.entries_of_table(current_table)
		if palette_entries_held.handle != 0 {
			entries = {user = &palette_entries_held, bytes = palette_entries_held.bytes, object = palette_entries_held.number, copy = palette_entries_copy}
		}

		target := 1 - intrinsics.atomic_load_explicit(&ranking.published_list, .Relaxed)
		list := &palette_lists[target]
		start := system.nanoseconds()
		local_needed := len(bar.names) + 2 * window_count
		provider_needed := 0
		if current_table != nil {
			if header, header_problem := palette_table.header_read(current_table, entries); header_problem == .None {
				provider_needed = int(header.entry_count)
			}
		}
		_ = palette_list_ensure(target, provider_needed, provider_needed + local_needed)
		problem, problem_index := palette.list_collect(list, {recents = recents[:recent_count], frecency = &palette_ranking_frecency}, bar.names[:], windows[:window_count], current_table, entries)
		if problem == .Too_Many_Entries && current_table != nil {
			if header, header_problem := palette_table.header_read(current_table, entries); header_problem == .None {
				if palette_list_ensure(target, int(header.entry_count), int(header.entry_count) + local_needed) {
					problem, problem_index = palette.list_collect(list, {recents = recents[:recent_count], frecency = &palette_ranking_frecency}, bar.names[:], windows[:window_count], current_table, entries)
				}
			}
		}
		palette.list_rank(list, string(query[:query_length]))
		list.sequence = sequence
		spent := system.nanoseconds() - start
		if problem != refused_before {
			refused_before = problem
			// Entries that move are no fault: their Table_Replaced comes.
			if problem != .None && problem != .Entries_Moving {
				system.log_fact(.Warning, Provider_Table_Refused{entry_index = u64(problem_index), table_problem = value_kinds.text_field(palette_table.problem_names[problem], TABLE_PROBLEM_FIELD_BYTES)})
			}
		}
		system.lock(&ranking.lock)
		ranking.longest = max(ranking.longest, spent)
		system.unlock(&ranking.lock)
		intrinsics.atomic_store(&ranking.published_list, target)
		intrinsics.atomic_add(&ranking.published, 1)
		system.word_wake(&ranking.published)
		done = sequence
	}
}

// palette_is_open says if the panel is on the screen and takes the keys.
palette_is_open :: proc "contextless" () -> bool {
	return palette_panel.state != .Closed
}

palette_place :: proc "contextless" () -> (x, y: int) {
	return palette.panel_place(desktop_width)
}

damage_palette :: proc "contextless" () {
	x, y := palette_place()
	damage_add(x, y, palette.PANEL_WIDTH, palette.PANEL_HEIGHT)
}

// palette_entries_refresh asks the ranking thread for a new list: the
// typed part of now, the windows of the client table with the front one
// first, the choices that the panel remembers. The compositor calls it
// when a window appears, leaves or comes to the front, after a choice, at
// each change of the typed part, and when the table of the provider
// changes: at a change of the data. The work here is one copy of at most
// 32 titles and 16 names.
palette_entries_refresh :: proc "contextless" () {
	ranking := &palette_ranking
	system.lock(&ranking.lock)
	ranking.query_length = copy(ranking.query[:], palette.typed_text(&palette_panel))
	ranking.window_count = 0
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		resizable := client.resizable && !client.resize_asked && client.resize_pictures == nil && !client.released
		ranking.windows[ranking.window_count] = {title = client.title, number = u32(order[position]), focus = position == order_count - 1, resizable = resizable, maximized = client.maximized, from_disk = client.from_disk, hash_prefix = client.hash_prefix}
		ranking.window_count += 1
	}
	ranking.recent_count = copy(ranking.recents[:], palette_panel.recents[:clamp(palette_panel.recent_count, 0, palette.RECENT_CAPACITY)])
	ranking.frecency = palette_panel.frecency
	intrinsics.atomic_add(&ranking.requested, 1)
	system.unlock(&ranking.lock)
	system.word_wake(&ranking.requested)
}

// palette_list_is_current says if the list of the panel answers the newest
// request: the typed part and the windows of now.
palette_list_is_current :: proc "contextless" () -> bool {
	return palette_panel.list.sequence == intrinsics.atomic_load_explicit(&palette_ranking.requested, .Relaxed)
}

// palette_wait adds the words of the palette to the wait of the loop: a
// list that the ranking thread published, an answer of the provider, a
// change of its table.
palette_wait :: proc "contextless" (wait: ^system.Wait) {
	system.wait_word(wait, &palette_ranking.published, palette_published_seen)
	if palette_provider_ring.head != nil {
		system.wait_records(wait, &palette_provider_ring.completions)
		if palette_main_table != nil {
			header := (^palette_table.Header)(raw_data(palette_main_table))
			system.wait_word(wait, &header.change_count, palette_generation_seen)
		}
	}
}

// palette_turn is the part of the palette in each turn of the loop, after
// the wait: a table of the provider that changed asks for a new list; a
// published list is adopted; an answer of the provider is shown.
palette_turn :: proc "contextless" () {
	// A held arrow button of the scroll bar takes its next step at a time
	// of the clock: the frame of that time moves the view.
	if step := palette_wake(); step != 0 && system.time() >= step {
		palette_refresh()
	}
	if palette_provider_ring.head != nil {
		// The table is memory that the root service made: this thread reads
		// its header, its result and its candidates, and never an object of
		// the entries, which the ranking thread copies.
		if palette_main_table != nil {
			header := (^palette_table.Header)(raw_data(palette_main_table))
			if generation := intrinsics.atomic_load_explicit(&header.change_count, .Acquire); generation != palette_generation_seen {
				palette_generation_seen = generation
				palette_entries_refresh()
			}
		}
		for record in system.receive(&palette_provider_ring.completions) {
			palette_answer(record)
		}
	}
	published := intrinsics.atomic_load_explicit(&palette_ranking.published, .Relaxed)
	if published == palette_published_seen {
		return
	}
	palette_published_seen = published
	asked := palette_panel.state == .Confirm
	// The choice is an entry: it stays on its entry at whatever row the
	// new list gives it (palette.panel_adopt).
	adoption := palette.panel_adopt(&palette_panel, &palette_lists[intrinsics.atomic_load_explicit(&palette_ranking.published_list, .Relaxed) & 1])
	// The thread can now write the other list.
	intrinsics.atomic_store(&palette_ranking.adopted, published)
	system.word_wake(&palette_ranking.adopted)
	if !palette_is_open() {
		return
	}
	palette_adoptions += 1
	if adoption == .Same {
		// The list shows what the list before showed: no line of the
		// log, no frame. Enter that waited for this list runs now: the
		// screen shows its entry already.
		palette_adoptions_same += 1
	} else {
		if asked && palette_panel.state != .Confirm {
			system.log_fact(.Info, Palette_Entries_Changed{})
		}
		if adoption == .Moved {
			system.log_fact(.Info, Chosen_Entry_Left{})
			palette_enter_waits = false
			palette_go_to_waits = false
		}
		if palette_list_is_current() {
			palette_list_log()
		}
		palette_refresh()
	}
	if palette_enter_waits && palette_list_is_current() {
		palette_enter_waits = false
		if palette_panel.state == .Search {
			palette_act(.Run, .Enter, 0, "")
		}
	}
	if palette_go_to_waits && palette_list_is_current() {
		palette_go_to_waits = false
		if palette_panel.state == .Search {
			palette_act(.Go_To, .Shift_Enter, 0, "")
		}
	}
}

// palette_wake gives the time of the next step of a held arrow button of
// the scroll bar of the panel, in milliseconds of the clock of the system,
// or 0: the loop of the compositor has no wake for the palette.
palette_wake :: proc "contextless" () -> u64 {
	if !palette_is_open() {
		return 0
	}
	return palette_interface_state.scroll_bar_repeat_at
}

// palette_frame_drawn tells the panel that a frame showed it: Enter runs
// the chosen entry again after a list moved the choice. The compositor
// calls it at the end of each frame.
palette_frame_drawn :: proc "contextless" () {
	palette.panel_drawn(&palette_panel)
}

// palette_provider_add takes the ring and the entry table of the palette
// provider from the root service. The table is mapped read-only.
palette_provider_add :: proc "contextless" (ring_handle, table_handle: system.Handle) {
	if palette_provider_ring.head != nil {
		palette_provider_remove()
	}
	opened, status := system.ring_open(ring_handle, receive_handles = true)
	address: rawptr
	table_pages: u64
	if status == .Ok {
		table_status: system.Status
		table_pages, table_status = system.memory_size(table_handle)
		if table_status != .Ok {
			status = table_status
		} else if table_pages < palette_table.MIN_TABLE_PAGES {
			status = .Bad_Handle
		}
	}
	if status == .Ok {
		address, status = system.memory_map(table_handle, {})
	}
	if status != .Ok {
		if opened.head != nil {
			system.ring_close(&opened)
		}
		system.close(ring_handle)
		system.close(table_handle)
		system.log_fact(.Warning, Palette_Provider_Refused{})
		return
	}
	palette_provider_ring = opened
	palette_provider_ring_handle, palette_provider_table_handle = ring_handle, table_handle
	palette_main_table = ([^]u8)(address)[:table_pages * system.PAGE_SIZE]
	system.lock(&palette_ranking.lock)
	palette_ranking.provider_ring_handle = ring_handle
	palette_ranking.active_table_handle = table_handle
	palette_ranking.active_table = palette_main_table
	palette_ranking.pending_entry_count = 0
	system.unlock(&palette_ranking.lock)
	palette_generation_seen = intrinsics.atomic_load_explicit(&(^palette_table.Header)(address).change_count, .Acquire)
	system.log_fact(.Info, Palette_Provider_Present{})
	palette_entries_refresh()
}

// palette_provider_table_replace queues the object of the entries of a
// Table_Replaced for the ranking thread, which proves it and copies it.
// A word past a handle number or a number, and a handle of the table or
// of the ring, are dropped here without a close: this thread makes no
// system call for them.
palette_provider_table_replace :: proc "contextless" (record: ring.Record) {
	raw_handle, raw_number := record.values[1], record.values[3]
	if raw_handle == 0 || raw_handle > u64(max(u32)) || raw_number == 0 || raw_number > u64(max(u32)) {
		return
	}
	new_handle := system.Handle(raw_handle)
	if new_handle == palette_provider_table_handle || new_handle == palette_provider_ring_handle {
		return
	}
	system.lock(&palette_ranking.lock)
	duplicate := new_handle == palette_ranking.active_table_handle || new_handle == palette_ranking.provider_ring_handle
	for index in 0 ..< palette_ranking.pending_entry_count {
		if palette_ranking.pending_entries[index].handle == new_handle {
			duplicate = true
			break
		}
	}
	queued := false
	if !duplicate && palette_ranking.pending_entry_count < len(palette_ranking.pending_entries) {
		palette_ranking.pending_entries[palette_ranking.pending_entry_count] = {handle = new_handle, number = u32(raw_number)}
		palette_ranking.pending_entry_count += 1
		intrinsics.atomic_add(&palette_ranking.requested, 1)
		queued = true
	}
	system.unlock(&palette_ranking.lock)
	if queued {
		system.word_wake(&palette_ranking.requested)
	}
}

// palette_provider_remove ends the palette provider: the process stopped,
// or its grant ended. The palette keeps the modules and the windows. A
// panel that waits for an answer shows that none comes.
palette_provider_remove :: proc "contextless" () {
	if palette_provider_ring.head == nil {
		return
	}
	system.lock(&palette_ranking.lock)
	if (palette_main_table != nil || palette_provider_table_handle != 0) && palette_ranking.retire_table_count < len(palette_ranking.retire_tables) {
		palette_ranking.retire_tables[palette_ranking.retire_table_count] = {handle = palette_provider_table_handle, table = palette_main_table}
		palette_ranking.retire_table_count += 1
	}
	palette_ranking.active_table = nil
	palette_ranking.active_table_handle = 0
	// The ranking thread closes the object of the entries that it holds
	// when it sees the ring change.
	palette_ranking.provider_ring_handle = 0
	palette_ranking.pending_entry_count = 0
	intrinsics.atomic_add(&palette_ranking.requested, 1)
	system.unlock(&palette_ranking.lock)
	palette_main_table = nil
	palette_provider_table_handle = 0
	system.ring_close(&palette_provider_ring)
	palette_provider_ring = {}
	system.close(palette_provider_ring_handle)
	palette_provider_ring_handle = 0
	palette_answer_awaited = 0
	system.log_fact(.Info, Palette_Provider_Absent{})
	palette_candidates_awaited = 0
	if palette_panel.state == .Arguments || palette_panel.state == .Confirm && palette_panel.form.active {
		palette_panel.state = .Running // The form has no provider to go to.
	}
	if palette_panel.state == .Running {
		palette.form_close(&palette_panel)
		palette.result_sentence(&palette_panel, "the console stopped, or it is no more the palette provider")
		palette_refresh()
	}
	palette_entries_refresh()
}

// palette_choose sends an entry of the provider on its ring: the
// generation of the table that had the entry, the index of the entry and
// the hash of its name, the mode, and the count of the Argument records
// before it. A setting row sends the entry of its chosen value
// (palette.entry_sent). It gives false with no provider or a full ring.
palette_choose :: proc "contextless" (generation: u32, picked: ^palette.Entry, mode: palette_table.Choose_Mode, argument_count: int, tag: u32) -> bool {
	if palette_provider_ring.head == nil {
		return false
	}
	number, name := palette.entry_sent(&palette_panel, picked)
	return system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Choose), tag = tag, values = {0 = u64(generation), 1 = u64(number), 2 = palette_table.name_hash(name), 3 = u64(mode), 4 = u64(argument_count)}})
}

// palette_act_names_take takes the record Act_Names of a window: the set of
// what its elements act on. The values are those of another process: the
// set is checked (palette.act_name_set_of_record), and a set that fails
// leaves the window with none. The log names the first sets of a window.
palette_act_names_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	set, ok := palette.act_name_set_of_record(record.values)
	if !ok {
		set = {}
	}
	if set == client.act_names {
		return
	}
	client.act_names = set
	if client.act_name_sets_logged < ACT_NAME_SETS_LOGGED {
		client.act_name_sets_logged += 1
		if ok {
			system.log_fact(.Info, Act_Names_Given{act_names = u64(set.count), window = window_field(client.title[:])})
		} else {
			system.log_fact(.Warning, Act_Names_Refused{window = window_field(client.title[:])})
		}
	}
	// An open panel offers go to by these sets.
	palette_refresh()
}

// palette_act_window gives the position in the order of the window in
// front that names the act name of an entry, or -1. The work is one pass
// over the windows, at most 32 sets of 6 hashes.
palette_act_window :: proc "contextless" (picked: ^palette.Entry) -> int {
	if picked == nil || picked.act == 0 {
		return -1
	}
	sets: [CLIENT_CAPACITY]^palette.Act_Name_Set
	positions: [CLIENT_CAPACITY]int
	count := 0
	for position := order_count - 1; position >= 0; position -= 1 {
		sets[count] = &clients[order[position]].act_names
		positions[count] = position
		count += 1
	}
	found := palette.act_name_front(sets[:count], picked.act)
	return found == palette.NO_ROW ? -1 : positions[found]
}

// palette_go_to raises the window in front that names the act name of the
// chosen entry, and sends it the event Go_To: its window layer gives the
// focus to the element. The panel closes, as after each choice that
// brings a window to the front.
palette_go_to :: proc "contextless" () {
	panel := &palette_panel
	if !palette_list_is_current() {
		// The list of the typed part is not made yet: go to waits for it,
		// as Enter does, and never acts on an entry of the list before.
		palette_go_to_waits = true
		return
	}
	picked := palette.chosen_entry(panel)
	if picked == nil {
		return
	}
	position := palette_act_window(picked)
	if position < 0 {
		system.log_fact(.Info, Act_Without_Window{entry = entry_field(palette.entry_name(picked))})
		return
	}
	name: [palette.NAME_CAPACITY]u8
	name_text := string(name[:copy(name[:], palette.entry_name(picked))])
	act := picked.act
	index := order[position]
	palette.recent_note(panel, picked)
	palette_close("")
	raise(position)
	send(&clients[index], .Go_To, {0 = u64(act)})
	system.log_fact(.Info, Palette_Goes_To_Window{entry = entry_field(name_text), window = window_field(clients[index].title[:])})
	palette_entries_refresh()
}

// palette_window_to_front brings the window with a title to the front:
// the window of the provider, where the line and its result are, or the
// window of the manual.
palette_window_to_front :: proc "contextless" (title: string) {
	for position := order_count - 1; position >= 0; position -= 1 {
		if index := order[position]; system.name_of(clients[index].title[:]) == title {
			raise(position)
			system.log_fact(.Info, Window_In_Front{window = window_field(clients[index].title[:])})
			return
		}
	}
}

@(rodata)
palette_kind_words := [palette_table.Value_Kind]string {
	.None    = "no value",
	.Integer = "an Integer",
	.Text    = "a Text",
	.Record  = "a Record",
	.Handle  = "a Handle",
	.Table   = "a Table",
	.Bytes   = "Bytes",
	.Enum    = "a member",
}

// palette_answer takes one answer of the provider. Each value is the
// value of another process: the outcome and the kind are checked, and the
// result is copied and checked before the panel shows it
// (palette.result_set). An answer to a choice that the desktop no longer
// waits for is dropped.
palette_answer :: proc "contextless" (record: ring.Record) {
	outcome := record.values[0]
	if outcome == u64(palette_table.Outcome.Table_Replaced) {
		palette_provider_table_replace(record)
		return
	}
	if record.tag != 0 && record.tag == palette_candidates_awaited {
		palette_candidates_awaited = 0
		// An answer that gives no candidate ends the wait of Tab too.
		palette_panel.form.candidates_pending = false
		if outcome != u64(palette_table.Outcome.Candidates_Ready) && palette_tab_waits && palette_panel.state == .Arguments {
			palette_tab_waits = false
			palette_act(.Field_Next, .Tab, 0, "")
		}
		if outcome == u64(palette_table.Outcome.Candidates_Ready) && palette_panel.state == .Arguments {
			form := &palette_panel.form
			palette.form_candidates_set(form, palette_main_table, record.values[2], record.values[1], record.values[3], record.values[4], record.values[5])
			system.log_fact(.Info, Palette_Candidates_Ready{candidates = u64(form.candidate_count), field = u64(form.current), buttons_words = value_kinds.text_field(palette.field_control(form, form.current) == .Buttons ? BUTTONS_WORDS : "", BUTTONS_WORDS_FIELD_BYTES)})
			// Tab that came before the candidates acts now, on them.
			if palette_tab_waits {
				palette_tab_waits = false
				palette_act(.Field_Next, .Tab, 0, "")
			}
			palette_refresh()
		}
		return
	}
	if record.tag == 0 || record.tag != palette_answer_awaited {
		return
	}
	palette_answer_awaited = 0
	if outcome == u64(palette_table.Outcome.Manual_Opened) {
		system.log_fact(.Info, Palette_Manual_Shown{})
		palette_window_to_front("manual")
	}
	in_console := outcome == u64(palette_table.Outcome.Shown_In_Console) || outcome == u64(palette_table.Outcome.Edit_Opened)
	if in_console {
		if outcome == u64(palette_table.Outcome.Edit_Opened) {
			system.log_fact(.Info, Palette_Entry_Opened_In_Console{})
		} else {
			system.log_fact(.Info, Palette_Result_In_Console{})
		}
		provider := system.name_of(palette_provider_window_name[:])
		palette_window_to_front(provider != "" ? provider : "console")
	}
	if palette_panel.state != .Running {
		return
	}
	palette.result_set(&palette_panel, outcome, record.values[1], palette_main_table, record.values[2])
	palette.form_close(&palette_panel)
	if palette_sent_setting && palette_panel.state == .Result && palette_panel.result.outcome == .Shown_In_Panel {
		// A setting: the desktop shows the change, and the panel shows
		// its list again, with the value in use marked.
		palette_sent_setting = false
		palette_panel.state = .Search
		system.log_fact(.Info, Palette_Did{sent_entry = entry_field(palette.sent_text(&palette_panel))})
		palette_refresh()
		return
	}
	if palette_panel.state == .Closed {
		palette_panel.state = .Running // palette_close closes an open panel.
		palette_close("")
		return
	}
	result := &palette_panel.result
	// result_set keeps Shown_In_Panel, Failed and Refused only; each other
	// outcome closes the panel before this line.
	switch result.outcome {
	case .Shown_In_Panel:
		system.log_fact(.Info, Palette_Shows_Result{result_kind = value_kinds.text_field(palette_kind_words[result.kind], RESULT_KIND_FIELD_BYTES)})
	case .Failed:
		system.log_fact(.Info, Palette_Shows_Error{})
	case .Refused:
		system.log_fact(.Info, Palette_Shows_Refusal{})
	case .None, .Shown_In_Console, .Edit_Opened, .Candidates_Ready, .Manual_Opened, .Table_Replaced:
		system.log_fact(.Info, Palette_Shows_No_Result{})
	}
	palette_refresh()
}

// palette_key_of translates a key of the keyboard into a key of the panel.
palette_key_of :: proc "contextless" (code: u32, character: rune) -> palette.Key {
	switch code {
	case display.KEY_SUPER:
		return .Super
	case display.KEY_ESCAPE:
		return .Escape
	case display.KEY_ENTER:
		return .Enter
	case display.KEY_UP:
		return .Up
	case display.KEY_DOWN:
		return .Down
	case display.KEY_PAGE_UP:
		return .Page_Up
	case display.KEY_PAGE_DOWN:
		return .Page_Down
	case display.KEY_LEFT:
		return .Left
	case display.KEY_RIGHT:
		return .Right
	case display.KEY_HOME:
		return .Home
	case display.KEY_END:
		return .End
	case display.KEY_BACKSPACE:
		return .Backspace
	case display.KEY_DELETE:
		return .Delete
	case display.KEY_TAB:
		return .Tab
	}
	return text_encoding.character_in_text(character) ? palette.Key.Character : palette.Key.Other
}

// palette_key takes a key for the palette. It gives true if the key is for
// the palette, and false if it goes to the window that has the focus. The
// key super opens and closes the panel. While the panel is open, it takes
// each key: what a key does in each state is palette.key_action.
palette_key :: proc "contextless" (code: u32, character: rune, pressed: bool, modifiers: u32) -> bool {
	if !pressed {
		if code == kept_key {
			kept_key = 0
			return true
		}
		return palette_is_open() || code == display.KEY_SUPER
	}
	key := palette_key_of(code, character)
	shift := modifiers & display.MODIFIER_SHIFT != 0
	control := modifiers & display.MODIFIER_CONTROL != 0
	// Shift with Tab, arrows, Home/End and Control with Enter/A/C/X/V are keys of their own.
	if shift && !control {
		switch key {
		case .Tab:
			key = .Shift_Tab
		case .Enter:
			key = .Shift_Enter
		case .Left:
			key = .Select_Left
		case .Right:
			key = .Select_Right
		case .Home:
			key = .Select_Home
		case .End:
			key = .Select_End
		case .Other, .Super, .Escape, .Up, .Down, .Page_Up, .Page_Down, .Backspace, .Delete, .Character, .Shift_Tab, .Control_Enter, .Shift_Enter, .Select_Left, .Select_Right, .Select_Home, .Select_End, .Select_All, .Copy, .Cut, .Paste:
		}
	}
	if control {
		switch {
		case key == .Enter:
			key = .Control_Enter
		case character == 'a' || character == 'A':
			key = .Select_All
		case character == 'c' || character == 'C':
			key = .Copy
		case character == 'x' || character == 'X':
			key = .Cut
		case character == 'v' || character == 'V':
			key = .Paste
		case key == .Character:
			key = .Other // Other Control chords type no character.
		}
	}
	was_open := palette_is_open()
	// On a setting row, and in a field with a row of buttons, Left and
	// Right choose a value.
	action := palette.key_action_for(&palette_panel, key)
	if !was_open && action == .None {
		return false
	}
	if key != .Super {
		kept_key = code
	}
	palette_act(action, key, character, key == .Super ? "the key super" : "the key escape")
	return true
}

// palette_act does one action of the panel: from a key, or from the
// pointer (a press and a release on a row is Run or Confirm; a press
// outside the panel is Close). cause: what closes the panel, for the log.
palette_act :: proc "contextless" (action: palette.Action, key: palette.Key, character: rune, cause: string) {
	panel := &palette_panel
	// The palette runs the row that is drawn: after a list moved the
	// choice to another entry, Enter does nothing until a frame showed it.
	if panel.choice_undrawn && palette.action_runs(action) {
		system.log_fact(.Info, Palette_Enter_Dropped{})
		palette_refresh()
		return
	}
	if action != .Field_Next {
		palette_tab_waits = false // Another key came: Tab waits for nothing more.
	}
	chosen := palette.chosen_of(panel)
	state_next := palette.state_after(panel.state, action, chosen)
	switch action {
	case .None:
		// A key that the panel does not use: it goes to no process.
	case .Open:
		capture_popover_close()
		if menu_open != .None {
			menu_open = .None
			menu_line = -1
			menu_action = .None
			damage_menu()
		}
		palette.panel_open(panel)
		// The pointer is where it is now, with no press of an open before.
		palette_interface_state = {}
		palette_input = {pointer_x = pointer_x, pointer_y = pointer_y, pointer_known = true}
		palette_scroll_dragged = false
		// The provider reads again the facts of its entries that change
		// with no line of its own, and writes a new table when one did. A
		// full ring sends nothing: the table of the last line stays.
		if palette_provider_ring.head != nil {
			system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Refresh)})
		}
		system.log_fact(.Info, Palette_Open{})
		palette_refresh()
	case .Close:
		palette_close(cause)
	case .Edit:
		// The typed part shows at once; its list comes from the ranking
		// thread, and the panel shows the list before until then.
		drawn, text_changed := palette.typed_edit(panel, key, character)
		if text_changed {
			palette_enter_waits = false
			palette_go_to_waits = false
			palette_entries_refresh()
		}
		if drawn {
			palette_refresh()
		}
	case .Copy:
		buffer: [line_editor.LINE_CAPACITY]u8
		if copied, ok := palette.panel_copy(panel, buffer[:]); ok {
			_ = clipboard_store_local(buffer[:copied], "palette")
		}
	case .Cut:
		buffer: [line_editor.LINE_CAPACITY]u8
		if copied, ok := palette.panel_copy(panel, buffer[:]); ok {
			if clipboard_store_local(buffer[:copied], "palette") {
				if _, text_changed, cut_ok := palette.panel_cut(panel, buffer[:]); cut_ok {
					if text_changed && panel.state == .Search {
						palette_enter_waits = false
						palette_go_to_waits = false
						palette_entries_refresh()
					}
					palette_refresh()
				}
			}
		}
	case .Paste:
		buffer: [display.CLIPBOARD_TEXT_LIMIT]u8
		if count, ok := clipboard_read_local(buffer[:]); ok {
			drawn, text_changed, _ := palette.panel_paste(panel, string(buffer[:count]))
			if text_changed && panel.state == .Search {
				palette_enter_waits = false
				palette_go_to_waits = false
				palette_entries_refresh()
			}
			if drawn {
				palette_refresh()
			}
		}
	case .Choose_Previous, .Choose_Next, .Choose_Page_Before, .Choose_Page_After:
		// The case above holds the four members that move the choice.
		step := palette.Choice_Step.Previous
		switch {
		case action == .Choose_Next:
			step = .Next
		case action == .Choose_Page_Before:
			step = .Page_Before
		case action == .Choose_Page_After:
			step = .Page_After
		}
		if palette.choice_move(panel, step) {
			palette_choice_log()
			palette_refresh()
		}
	case .Run:
		if !palette_list_is_current() {
			// The list of the typed part is not made yet: Enter waits for
			// it, and never runs an entry of the list before.
			palette_enter_waits = true
			break
		}
		picked := palette.chosen_entry(panel)
		if picked == nil {
			// The panel stays open with its typed part, and says that Enter
			// ran nothing (src/md/features/palette.md, "Enter with nothing to
			// run").
			palette.nothing_to_run_show(panel)
			system.log_fact(.Info, Palette_No_Entry_To_Run{})
			palette_refresh()
			break
		}
		if state_next == .Confirm {
			panel.state = .Confirm
			system.log_fact(.Info, Palette_Asks_To_Confirm{entry = entry_field(palette.entry_name(picked))})
			palette_refresh()
			break
		}
		if state_next == .Running {
			if palette.entry_is_setting_row(picked) {
				// The pointer acts with the key Other: a press on a button.
				system.log_fact(.Info, Palette_Sets_Value{entry = entry_field(palette.entry_name(picked)), value_name = value_kinds.text_field(palette.value_name(panel.list, picked, palette.value_chosen(panel, picked)), VALUE_NAME_FIELD_BYTES), input = value_kinds.text_field(key == .Other ? "a press" : "a key", INPUT_WORDS_FIELD_BYTES)})
			}
			palette_entry_send(picked)
			break
		}
		if state_next == .Arguments {
			palette.form_open(panel, picked)
			system.log_fact(.Info, Palette_Asks_For_Arguments{entry = entry_field(palette.entry_name(picked))})
			for field in 0 ..< panel.form.field_count {
				if unit_text := palette.field_unit_text(&panel.form, field); unit_text != "" {
					// The text of a unit starts with its space, which the
					// template writes.
					system.log_fact(.Info, Palette_Field_Unit{field = u64(field), entry = entry_field(palette.entry_name(&panel.form.entry)), unit = value_kinds.text_field(unit_text[1:], UNIT_FIELD_BYTES)})
				}
			}
			palette_candidates_ask()
			palette_refresh()
			break
		}
		palette_entry_run(picked)
	case .Confirm:
		confirmed := palette.chosen_entry(panel)
		switch {
		case panel.form.active:
			palette_form_send()
		case confirmed == nil:
			palette_close("")
		case state_next == .Running:
			palette_entry_send(confirmed)
		case:
			palette_entry_run(confirmed)
		}
	case .Back:
		if state_next == .Arguments {
			system.log_fact(.Info, Palette_Back_To_Arguments{})
		} else {
			palette.form_close(panel)
			system.log_fact(.Info, Palette_Back_To_Search{})
		}
		panel.state = state_next
		palette_refresh()
	case .Field_Edit:
		text_before_hash := palette_table.name_hash(palette.field_text(&panel.form, panel.form.current))
		drawn, leave := palette.form_field_edit(panel, key, character)
		// A list that the page does not hold whole is narrowed by the
		// provider: the text of the field goes with a new request.
		if !leave && panel.form.candidate_total > 0 && !palette.form_candidates_whole(&panel.form) && palette_table.name_hash(palette.field_text(&panel.form, panel.form.current)) != text_before_hash {
			palette_candidates_ask()
		}
		if leave {
			palette.form_close(panel)
			panel.state = .Search
			system.log_fact(.Info, Palette_Back_To_Search{})
		}
		if drawn || leave {
			if message := palette.form_message(&panel.form); message != "" {
				system.log_fact(.Info, Palette_Key_Refused{form_refusal = value_kinds.text_field(message, MESSAGE_FIELD_BYTES)})
			}
			palette_refresh()
			// The panel is built with the key: a machine test takes its
			// picture after this line, not before the key is drawn.
			if !leave {
				form := &panel.form
				system.log_fact(.Info, Palette_Field_Shows{field = u64(form.current), entry = entry_field(palette.entry_name(&form.entry))}, palette.field_text(form, form.current))
			}
		}
	case .Field_Next:
		switch palette.form_tab(&panel.form) {
		case .Waits:
			// The candidates of the field are on their way: Tab acts
			// when they come, and never jumps to the next field before.
			palette_tab_waits = true
			system.log_fact(.Info, Palette_Tab_Waits{})
		case .Takes:
			palette.form_candidate_take(&panel.form)
			system.log_fact(.Info, Palette_Takes_Candidate{candidate = value_kinds.text_field(palette.field_text(&panel.form, panel.form.current), CANDIDATE_FIELD_BYTES)})
		case .Moves:
			if palette.form_field_move(panel, 1) {
				palette_candidates_ask()
			}
		}
		palette_refresh()
	case .Field_Previous:
		if palette.form_field_move(panel, -1) {
			palette_candidates_ask()
		}
		palette_refresh()
	case .Candidate_Previous, .Candidate_Next:
		step := action == .Candidate_Next ? 1 : -1
		// Past the edge of a page that does not end the list, the next page
		// comes: the list has any count of candidates.
		if first, wanted := palette.form_candidate_page_wanted(&panel.form, step); wanted {
			palette_candidates_ask(first, step < 0)
		} else if palette.form_candidate_move(&panel.form, step) {
			palette_refresh()
		}
	case .Submit, .Submit_All:
		ready, moved := palette.form_submit(panel, action == .Submit_All)
		switch {
		case ready && state_next == .Confirm:
			panel.state = .Confirm
			system.log_fact(.Info, Palette_Asks_To_Confirm{entry = entry_field(palette.entry_name(&panel.form.entry))})
		case ready:
			palette_form_send()
			return
		case moved:
			palette_candidates_ask()
		case:
			system.log_fact(.Info, Palette_Arguments_Refused{form_refusal = value_kinds.text_field(palette.form_message(&panel.form), MESSAGE_FIELD_BYTES)})
		}
		palette_refresh()
	case .Go_To:
		palette_go_to()
	case .Value_Previous, .Value_Next:
		if palette.value_move(panel, action == .Value_Next ? 1 : -1) {
			if picked := palette.chosen_entry(panel); picked != nil {
				system.log_fact(.Info, Palette_Chooses_Value{entry = entry_field(palette.entry_name(picked)), value_name = value_kinds.text_field(palette.value_name(panel.list, picked, palette.value_chosen(panel, picked)), VALUE_NAME_FIELD_BYTES)})
			}
			palette_refresh()
		}
	case .Open_In_Console:
		// The entry of a provider goes to the edit line of its window,
		// where a line can compose its arguments.
		if picked := palette.chosen_entry(panel); picked != nil && palette_list_is_current() && (picked.kind == .Command || picked.kind == .Export) {
			palette.recent_note(panel, picked)
			opened: [palette.NAME_CAPACITY]u8
			opened_name := string(opened[:copy(opened[:], palette.entry_name(picked))])
			sent := palette_choose(panel.list.snapshot.generation, picked, .Edit, 0, palette_tag_next())
			palette_close("")
			if sent {
				system.log_fact(.Info, Palette_Opens_In_Console{entry = entry_field(opened_name)})
			}
		}
	}
}

// palette_tag_next gives the tag of the next choice: the desktop acts on
// the answer with this tag, and on no older one.
palette_tag_next :: proc "contextless" () -> u32 {
	palette_tags += 1
	if palette_tags == 0 {
		palette_tags = 1
	}
	palette_answer_awaited = palette_tags
	return palette_tags
}

// palette_form_send sends the entry of the form with its typed values:
// one Argument record for each field, an Integer as a number and a Text
// as its bytes, then the choice. The provider builds the line; the panel
// sends no text of a line. The panel then waits for what the entry gives.
palette_form_send :: proc "contextless" () {
	panel := &palette_panel
	form := &panel.form
	palette.sent_set(panel, &form.entry)
	palette_sent_setting = false
	panel.state = .Running
	sent := palette_provider_ring.head != nil
	tag := palette_tag_next()
	for field in 0 ..< form.field_count {
		sent = sent && system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Argument), tag = tag, values = palette.form_argument(form, field)})
	}
	sent = sent && palette_choose(form.generation, &form.entry, .Run_With_Arguments, form.field_count, tag)
	if sent {
		system.log_fact(.Info, Palette_Sends_With_Arguments{arguments = u64(form.field_count), sent_entry = entry_field(palette.sent_text(panel))})
	} else {
		palette.form_close(panel)
		palette.result_sentence(panel, "the console takes no choice now")
		system.log_fact(.Info, Palette_Shows_Refusal{})
	}
	palette_refresh()
}

// palette_candidates_ask asks the provider for one page of the values that
// the field of the form that has the caret can take: the page from the
// place first of the list of the candidates that the text of the field
// matches. The text goes as an Argument of the same tag. The answer comes
// on the ring; the form shows its fields at once.
palette_candidates_ask :: proc "contextless" (first: int = 0, choose_last: bool = false) {
	form := &palette_panel.form
	if palette_provider_ring.head == nil || !form.active {
		return
	}
	palette_tags += 1
	if palette_tags == 0 {
		palette_tags = 1
	}
	palette_candidates_awaited = palette_tags
	form.candidate_choose_last = choose_last
	form.candidate_first_asked = max(first, 0)
	text := palette.field_text(form, form.current)
	if len(text) > 0 && len(text) <= palette_table.ARGUMENT_TEXT_CAPACITY {
		if !system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Argument), tag = palette_tags, values = palette_table.argument_pack(form.current, .Text, 0, text)}) {
			form.candidates_pending = false
			return
		}
	}
	// Until the answer, Tab waits (palette.form_tab). A ring that takes
	// no record gives no answer: Tab then does not wait.
	form.candidates_pending = system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Candidates), tag = palette_tags, values = {0 = u64(form.generation), 1 = u64(form.entry.number), 2 = palette_table.name_hash(palette.entry_name(&form.entry)), 3 = u64(form.current), 4 = u64(max(first, 0))}})
}

// palette_entry_send sends a chosen entry with no parameter to the
// provider, and makes the panel wait for what it gives. The panel stays
// open and takes its keys: Escape closes it, and the line goes on in the
// window of the provider.
palette_entry_send :: proc "contextless" (picked: ^palette.Entry) {
	panel := &palette_panel
	palette.recent_note(panel, picked)
	palette.sent_set(panel, picked)
	panel.state = .Running
	palette_sent_setting = picked.kind == .Setting
	sent := false
	if picked.kind == .Module {
		// The prefix of the manual: the provider gets the name of the
		// process, as a typed value, and shows its page.
		packed := system.name_pack(palette.entry_name(picked))
		sent = palette_provider_ring.head != nil && system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Manual), tag = palette_tag_next(), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
		if sent {
			system.log_fact(.Info, Palette_Asks_For_Manual{sent_entry = entry_field(palette.sent_text(panel))})
		}
	} else {
		sent = palette_choose(panel.list.snapshot.generation, picked, .Run, 0, palette_tag_next())
		if sent {
			system.log_fact(.Info, Palette_Sends{sent_entry = entry_field(palette.sent_text(panel))})
		}
	}
	if !sent {
		palette.result_sentence(panel, "the console takes no choice now")
		system.log_fact(.Info, Palette_Shows_Refusal{})
	}
	palette_refresh()
}

// palette_entry_run does what a chosen entry is, then closes the panel:
// what the entry started shows on the desktop. The number of an entry of a
// window is an index in the client table; the entries are made again at
// each change of that table, and the number is checked here once more.
palette_entry_run :: proc "contextless" (picked: ^palette.Entry) {
	name: [palette.NAME_CAPACITY]u8
	name_text := string(name[:copy(name[:], palette.entry_name(picked))])
	kind, number := picked.kind, int(picked.number)
	palette.recent_note(&palette_panel, picked)
	// The close first: the entries are made again below, and the panel
	// that is closed then draws nothing.
	palette_close("")
	switch kind {
	case .Module:
		if number < len(bar.names) {
			packed := system.name_pack(bar.names[number])
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
			system.log_fact(.Info, Palette_Starts{entry = entry_field(name_text)})
		}
		palette_entries_refresh() // The choice is the newest recent one.
	case .Window:
		system.log_fact(.Info, Palette_Brings_To_Front{entry = entry_field(name_text)})
		for position in 0 ..< order_count {
			// The place of the client table can hold another window now:
			// the title is checked, so the choice never reaches a window
			// that the row did not name.
			if order[position] == number && system.name_of(clients[number].title[:]) == name_text {
				raise(position)
				system.log_fact(.Info, Window_In_Front{window = window_field(clients[number].title[:])})
				break
			}
		}
		palette_entries_refresh() // The choice is the newest recent one, also when the window was in front.
	case .Close_Window:
		// The window that the row named, and no other one that took its
		// place in the client table: the name of the row is "close" and
		// the title.
		close_start := palette.CLOSE_NAME_START
		if number < CLIENT_CAPACITY && clients[number].created && len(name_text) > len(close_start) && system.name_of(clients[number].title[:]) == name_text[len(close_start):] {
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(clients[number].ring_memory)}})
			system.log_fact(.Info, Palette_Closes_Window{window = window_field(clients[number].title[:])})
		}
	case .Move_Window, .Resize_Window:
		// The window that the row named, if it is still in front: a
		// window that took the front since then is not the one chosen.
		if order_count > 0 && order[order_count - 1] == number {
			keyboard_window_begin(kind == .Move_Window ? bar.Keyboard_Window_Mode.Move : bar.Keyboard_Window_Mode.Resize) // keyboard_desktop.odin
		}
	case .Maximize_Window:
		// The same rule: only the window that is still in front.
		if order_count > 0 && order[order_count - 1] == number {
			_ = desktop_toggle_maximize(&clients[number]) // desktop_features.odin
		}
	case .Command, .Export:
		// An entry with parameters: the provider writes it in its edit
		// line, and its window comes to the front when it answers.
		if palette_choose(palette_panel.list.snapshot.generation, picked, .Edit, 0, palette_tag_next()) {
			system.log_fact(.Info, Palette_Opens_In_Console{entry = entry_field(name_text)})
		}
		palette_entries_refresh()
	case .Setting:
		// A setting has no parameter: the panel sends it (palette_entry_send).
	}
}

// palette_pointer takes the pointer while the panel is open: no window
// and no menu receives it. A move over an entry chooses it (only a move: a
// list that changes under a still pointer keeps its choice). A press and a
// release on one row run it. A press outside the panel closes it; a press
// inside the panel that is on no row does nothing.
//
// In a form, a press in the input band puts the caret in the field under
// the pointer, at the character under it; a move over a candidate chooses
// it, and a press and a release on one candidate take it, as Tab does. A
// press and a release on one button of a field take its value too.
//
// The scroll bar of the list is an element of the interface package: a
// press on it, and each move while it holds the press, builds a frame of
// the panel with the pointer, and the element moves the view. While the
// scroll bar holds the press, the pointer chooses and runs no row. A notch
// of the wheel over the rows or over the bar builds a frame too, and the
// element moves the view by it; a notch elsewhere moves nothing.
palette_pointer :: proc "contextless" (moved, pressed, released: bool, wheel: int) {
	panel := &palette_panel
	left, top := palette_place()
	given := &palette_input
	given.pointer_x, given.pointer_y = pointer_x, pointer_y
	given.pointer_known = true
	given.wheel += wheel
	if pressed {
		given.press_x, given.press_y = pointer_x, pointer_y
	}
	given.pressed ||= pressed
	given.released ||= released
	given.button_held = buttons & display.BUTTON_LEFT != 0
	bar_area, bar_shown := palette.scroll_bar_area(panel, left, top)
	bar_identity := palette.scroll_bar_identity()
	// The pointer is over the scroll bar, holds it, leaves it lit, or turns
	// the wheel over the rows: the panel needs a frame for it. A panel with
	// no scroll bar has no view that the wheel moves.
	view_area := bar_shown ? palette.scroll_view_area(left, top) : interface.Area{}
	bar_wants_frame := interface.scroll_bar_wants_frame(&palette_interface_state, given, bar_area, bar_identity, view_area)
	if palette_interface_state.pressed == bar_identity || pressed && bar_shown && interface.area_contains(bar_area, pointer_x, pointer_y) {
		panel.pressed_row = palette.NO_ROW
		palette_refresh()
		return
	}
	row := palette.row_at(panel, left, top, pointer_x, pointer_y)
	candidate := palette.candidate_at(panel, left, top, pointer_x, pointer_y)
	changed := false
	if moved {
		if panel.state == .Search && palette.choice_set(panel, row) {
			palette_choice_log()
			changed = true
		}
		if panel.state == .Arguments && palette.form_candidate_set(&panel.form, candidate) {
			changed = true
		}
	}
	if pressed {
		part := palette.part_at(left, top, pointer_x, pointer_y)
		if part == .Outside {
			palette_close("a press of the pointer outside it")
			return
		}
		if panel.state == .Arguments {
			panel.pressed_row = candidate
			// A press on a button of the field: its release takes that
			// value. The layout is the one that the last frame drew.
			palette_pressed_button = palette.form_button_at(panel, &palette_before, left, top, pointer_x, pointer_y)
			if part == .Input_Band && palette_pressed_button == palette.NO_ROW {
				if field, caret, in_a_field := palette.form_place_at(&panel.form, left, pointer_x); in_a_field {
					// Tab that waited for the candidates of the field
					// before waits for nothing more.
					palette_tab_waits = false
					if palette.form_caret_put(panel, field, caret) {
						palette_candidates_ask()
					}
					system.log_fact(.Info, Palette_Caret_Put{field = u64(field), characters = u64(caret)})
					changed = true
				}
			}
		} else {
			palette_pressed_button = palette.NO_ROW
			panel.pressed_row = palette.row_is_entry(panel, row) ? row : palette.NO_ROW
			// A press on a button of a setting row: its release sets that
			// value. The layout is the one that the last frame drew.
			_, palette_pressed_value = palette.value_at(panel, &palette_before, left, top, pointer_x, pointer_y)
		}
	}
	if released {
		pressed_row := panel.pressed_row
		panel.pressed_row = palette.NO_ROW
		switch panel.state {
		case .Closed, .Running, .Result:
			// No row of the panel takes a release in these states.
		case .Search:
			pressed_value := palette_pressed_value
			palette_pressed_value = palette.NO_ROW
			if pressed_row != palette.NO_ROW && pressed_row == row {
				palette.choice_set(panel, row)
				// The release on the button that took the press chooses
				// its value; a release elsewhere on the row sets the value
				// that the row shows chosen.
				if value_row, value := palette.value_at(panel, &palette_before, left, top, pointer_x, pointer_y); value_row == row && value != palette.NO_ROW && value == pressed_value {
					if picked := palette.chosen_entry(panel); picked != nil {
						palette.value_set(panel, picked, value)
					}
				}
				interface.input_clear(given)
				palette_act(.Run, .Other, 0, "")
				return
			}
		case .Confirm:
			if pressed_row != palette.NO_ROW && pressed_row == row {
				// The row that asks: the second Enter. Another row: back.
				interface.input_clear(given)
				palette_act(row == panel.choice ? palette.Action.Confirm : palette.Action.Back, .Other, 0, "")
				return
			}
		case .Arguments:
			// A press and a release on one button of the field take its
			// value, as Tab takes the value that Left and Right chose.
			pressed_button := palette_pressed_button
			palette_pressed_button = palette.NO_ROW
			if pressed_button != palette.NO_ROW && pressed_button == palette.form_button_at(panel, &palette_before, left, top, pointer_x, pointer_y) {
				form := &panel.form
				palette.form_candidate_set(form, pressed_button)
				if palette.form_candidate_take(form) {
					system.log_fact(.Info, Palette_Button_Pressed{field = u64(form.current), candidate = value_kinds.text_field(palette.field_text(form, form.current), CANDIDATE_FIELD_BYTES)})
				}
				changed = true
			}
			if pressed_row != palette.NO_ROW && pressed_row == candidate {
				palette.form_candidate_set(&panel.form, candidate)
				if palette.form_candidate_take(&panel.form) {
					system.log_fact(.Info, Palette_Takes_Candidate{candidate = value_kinds.text_field(palette.field_text(&panel.form, panel.form.current), CANDIDATE_FIELD_BYTES)})
				}
				changed = true
			}
		}
	}
	if changed || bar_wants_frame {
		palette_refresh()
	} else {
		// No frame reads this press or this release.
		interface.input_clear(given)
	}
}

// palette_refresh builds the panel again and damages the difference with
// the panel on the screen.
palette_refresh :: proc "contextless" () {
	if !palette_is_open() {
		return
	}
	// The band offers go to when a window in front of the others names
	// what the chosen entry acts on.
	palette_panel.go_to_offered = palette_act_window(palette.chosen_entry(&palette_panel)) >= 0
	left, top := palette_place()
	// The frame reads the pointer for the scroll bar of the panel, and the
	// clock for a held arrow button. When the scroll bar moved the view,
	// the rows of that frame are those of the view before: a second frame
	// draws the rows of the new view. The second frame has no press, so
	// it moves nothing more.
	for _ in 0 ..< 2 {
		built := interface.frame_begin(&palette_now, &palette_interface_state, &palette_input, system.time())
		palette.panel_draw(&built, &palette_panel, left, top)
		interface.frame_end(&built)
		palette_element_places_drawn = built.element_places
		interface.input_clear(&palette_input)
		scrolled := palette_panel.scrolled
		moved := palette.view_scrolled(&palette_panel)
		if moved {
			palette_scroll_dragged ||= scrolled.held == .Thumb
			if scrolled.pressed_now != .None && scrolled.pressed_now != .Thumb {
				system.log_fact(.Info, Palette_Scroll_Pressed{first_row = u64(scrolled.first), scroll_part = value_kinds.text_field(palette_scroll_part_words(scrolled.pressed_now), SCROLL_PART_FIELD_BYTES)})
			}
			if scrolled.wheel_taken {
				system.log_fact(.Info, Palette_Wheel_Moved{first_row = u64(scrolled.first)})
			}
		}
		if scrolled.drag_ended {
			if palette_scroll_dragged {
				system.log_fact(.Info, Palette_Thumb_Dragged{first_row = u64(scrolled.first)})
			}
			palette_scroll_dragged = false
		}
		if !moved {
			break
		}
	}
	if palette_now.full {
		system.log_fact(.Warning, Palette_Draw_Table_Full{})
	}
	// The panel is no window: the compositor writes the places of its
	// named elements itself, in pixels of the screen, so that a machine
	// test presses a field or a button by its name.
	palette_element_places_publish() // facts.odin
	// The difference through the drawing module. It refuses only a table
	// of more than 2^40 records or bytes; with no difference, the whole
	// screen is drawn again.
	changed: interface.Damage
	refused: errors.Error_Record
	if !interface.difference_through_module(&palette_before, &palette_now, &changed, &refused) {
		damage_whole_screen()
	}
	for rectangle in changed.rectangles[:changed.count] {
		damage_add(rectangle.left, rectangle.top, rectangle.right - rectangle.left, rectangle.bottom - rectangle.top)
	}
	interface.draw_table_copy(&palette_before, &palette_now)
}

// palette_scroll_part_words gives the words of the log for a part of the
// scroll bar of the panel.
palette_scroll_part_words :: proc "contextless" (part: interface.Scroll_Bar_Part) -> string {
	switch part {
	case .None:
		return "no part"
	case .Arrow_Back:
		return "the arrow up"
	case .Arrow_Forward:
		return "the arrow down"
	case .Track_Back:
		return "the track above the thumb"
	case .Track_Forward:
		return "the track under the thumb"
	case .Thumb:
		return "the thumb"
	}
	return "no part"
}

PALETTE_LOG_NAMES :: 4 // The first rows that the log names: the line stays short for a long list.

// palette_list_log writes the list on the log: "compositor: the palette
// lists 3 of 61 for "mon": monitor (window), monitor (module), close
// monitor (close a window)". It names the first rows only; the names are
// one text view of the fact.
palette_list_log :: proc "contextless" () {
	panel := &palette_panel
	buffer: [PALETTE_LOG_NAMES * (palette.NAME_CAPACITY + 24)]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	named := 0
	list := panel.list
	for row in list.rows[:list.row_count] {
		if row.kind != .Entry {
			continue
		}
		if named == PALETTE_LOG_NAMES {
			system.write_part(&writer, ", ...")
			break
		}
		listed := &list.entries[row.entry]
		system.write_part(&writer, named > 0 ? ", " : "")
		system.write_part(&writer, palette.entry_name(listed))
		system.write_part(&writer, " (")
		system.write_part(&writer, palette.kind_words(listed.kind))
		system.write_part(&writer, ")")
		named += 1
	}
	system.log_fact(.Info, Palette_Listed{matched = u64(list.matched_count), entries = u64(list.entry_count), typed = value_kinds.text_field(palette.typed_text(panel), TYPED_FIELD_BYTES)}, system.written(&writer))
	palette_row_log()
}

// palette_row_log writes one line when the chosen entry becomes a setting
// row: "compositor: the palette shows the setting font as one row of 2
// values". The line is written when the chosen row changes, not at each
// list of a typed key.
palette_row_log :: proc "contextless" () {
	picked := palette.chosen_entry(&palette_panel)
	if picked == nil || !palette.entry_is_setting_row(picked) {
		palette_row_logged_length = 0
		return
	}
	name := palette.entry_name(picked)
	if string(palette_row_logged[:palette_row_logged_length]) == name {
		return
	}
	palette_row_logged_length = copy(palette_row_logged[:], name)
	system.log_fact(.Info, Palette_Setting_Row_Shown{values = u64(picked.value_count), entry = entry_field(name)})
}

// palette_choice_log writes the chosen entry on the log: "compositor: the
// palette chooses plasma (window)".
palette_choice_log :: proc "contextless" () {
	if picked := palette.chosen_entry(&palette_panel); picked != nil {
		system.log_fact(.Info, Palette_Chooses_Entry{entry = entry_field(palette.entry_name(picked)), kind_words = value_kinds.text_field(palette.kind_words(picked.kind), KIND_WORDS_FIELD_BYTES)})
	}
	palette_row_log()
}

// palette_close closes the panel, and writes on the log the measures of
// this open: the frames and their mean time, and the longest ranking. With
// a cause, a second line says what closed the panel.
palette_close :: proc "contextless" (cause: string) {
	if !palette_is_open() {
		return
	}
	if palette_panel.state == .Running {
		// The line goes on in the console; the desktop does nothing with
		// its answer.
		palette_answer_awaited = 0
	}
	palette.panel_close(&palette_panel)
	// A scroll bar that held the press holds nothing in the next open.
	palette_interface_state = {}
	interface.input_clear(&palette_input)
	palette_scroll_dragged = false
	palette_enter_waits = false
	palette_go_to_waits = false
	palette_row_logged_length = 0
	damage_palette()
	interface.draw_table_clear(&palette_before)
	// A closed panel has no element: each one that the log has is gone.
	palette_element_places_drawn = {}
	palette_element_places_publish() // facts.odin
	per_frame := palette_time / max(palette_frames, 1)
	system.lock(&palette_ranking.lock)
	longest := palette_ranking.longest
	palette_ranking.longest = 0
	system.unlock(&palette_ranking.lock)
	system.log_fact(.Info, Palette_Open_Measured{frames = palette_frames, frame_time = value_kinds.Nanoseconds_As_Microseconds(per_frame), longest_list_time = value_kinds.Nanoseconds_As_Microseconds(longest), adopted_lists = palette_adoptions, same_lists = palette_adoptions_same})
	palette_frames, palette_time = 0, 0
	palette_adoptions, palette_adoptions_same = 0, 0
	palette_tab_waits = false
	palette.panel_drawn(&palette_panel)
	// The list of an empty typed part, ready for the next open.
	palette_entries_refresh()
	if cause != "" {
		system.log_fact(.Info, Palette_Closed{close_cause = value_kinds.text_field(cause, CLOSE_CAUSE_FIELD_BYTES)})
	}
}
