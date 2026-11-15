// The display protocol, and the code that a program uses to show a surface.
//
// A program and the compositor share one ring. The program sends command
// records; the compositor sends input as completion records. The pixels of
// the surface are memory that the program creates and grants to the
// compositor. No pixel goes through the ring or through the kernel.
//
// The memory of a surface has two pictures. The program draws one while
// the compositor reads the other, and Present names the picture that is
// complete: the screen never shows a picture that is being drawn. After a
// Present, `window.canvas` is the other picture, which holds the frame of
// two frames before: a program that draws by hand draws the whole canvas.
// The program draws only when the compositor took the last Present
// (`canvas_free`, `canvas_wait`).
//
// Who uses it: each program with a window (`open`, `next_event`,
// `present`), the compositor (the other side of the ring, and the rings
// `Control` and `Input`), and `src/library/support/interface`, which draws with it. It
// also loads the text settings of the program: the glyph caches and the
// setting of the font (`text_settings_open`, `interface_font_open`).
//
// ```odin
// window := display.open(ctx, 640, 400, "clock") or_return
// for {
// 	for event in display.next_event(&window) {
// 		// ... the keys and the pointer ...
// 	}
// 	if display.canvas_wait(&window) {
// 		// ... draw the whole of window.canvas ...
// 		display.present(&window)
// 	}
// 	display.wait(&window)
// }
// ```
//
// See [surface](term:surface), [whole frame](term:whole-frame) and
// [compositor](term:compositor).
package display

import "base:intrinsics"
import "modus:contract/errors"
import "modus:support/graphics"
import "modus:contract/ring"
import "modus:support/key_path"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import "modus:contract/pointer_pictures"
import "modus:contract/settings"
import "modus:support/system"

// A command of a program to the compositor, on the ring of its window.
Command :: enum u32 {
	None           = 0, // Not a command.
	Surface_Create = 1, // values: memory handle (in the compositor), width, height, title (4 values)
	Present        = 2, // The pixels of the surface changed. values: the picture to show (0 or 1), then the rectangle that changed: x, y, width, height (width 0: the whole surface)
	Pointer_Shape  = 3, // The pointer shape over this surface (docs/POINTERS.md). values: a number of pointer_pictures.Pointer_Shape
	// The act names of the window: what its elements act on, so that the
	// palette offers to go there (docs/INTERFACE.md, "4.2 Act names").
	// values[0]: the count, 0 to ACT_NAME_SET_CAPACITY; values[1..]: the
	// act_name_hash of each act name. The set replaces the set before. The
	// window layer sends it when the set of a frame changes (act_names_send).
	Act_Names      = 4,
}

ACT_NAME_SET_CAPACITY :: 6 // The act names of one window: the values of one record after its count.
ACT_NAME_CAPACITY :: 32 // The bytes of an act name: "settings.set:font".

// act_name_hash gives the hash of an act name: the 64-bit FNV-1a hash of
// its bytes, never 0. A record of a ring holds 7 values, so a set of act
// names travels as hashes; the palette hashes the act name of an entry the
// same way.
act_name_hash :: proc "contextless" (name: string) -> u64 {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return hash | 1
}

// act_names_send gives the compositor the set of the act names of the
// window. It gives false when the command ring was full: the compositor has
// the set before, and the caller sends it again later.
act_names_send :: proc "contextless" (window: ^Window, hashes: []u64) -> bool {
	record := ring.Record{kind = u32(Command.Act_Names)}
	count := min(len(hashes), ACT_NAME_SET_CAPACITY)
	record.values[0] = u64(count)
	for hash, index in hashes[:count] {
		record.values[1 + index] = hash
	}
	return system.send(&window.ring.commands, record)
}

// What the compositor tells a program, as the kind of a completion record of
// its ring, and as the kind of an `Event`.
Event_Kind :: enum u32 {
	None             = 0, // No event.
	Key              = 1, // values: code, character, 1 when pressed, modifiers
	Pointer          = 2, // values: x, y in the surface (signed), buttons, wheel notches (signed: WHEEL_TOWARD_THE_END for each notch toward the end of the content)
	// The settings of the owner changed (modus:contract/settings): next_event
	// already gave the new font to src/library/support/graphics; the program draws its
	// window again. values: the change count of the settings page.
	Settings_Changed = 3,
	// The palette goes to an element of this window: the compositor raised
	// it. values[0]: the act_name_hash of the act name. The window layer
	// puts the focus on the element that names it
	// (src/library/support/interface, window_events).
	Go_To            = 4,
}

// The ring between the root service and the compositor.
Control :: enum u32 {
	None          = 0, // Not a command.
	// root to compositor. values: ring memory handle (in the compositor). For
	// a disk program, values 1 to 3 hold its nickname, as the root ring
	// carries a name of 23 bytes, and value 4 the first 8 bytes of the hash
	// of its file (modus:contract/disk_program_page, hash_head); for another
	// program, values 1 to 4 are 0.
	Client_Add    = 1,
	Client_Remove = 2, // root to compositor. values: the same handle
	Start         = 3, // compositor to root. values: name (4 values)
	Stop          = 4, // compositor to root. values: the handle of the client
	// root to compositor: a program is the palette provider. values: the
	// handle of its ring, then the handle of its entry table, read-only
	// (modus:contract/palette_table), both in the compositor.
	Palette_Provider_Add    = 5,
	Palette_Provider_Remove = 6, // root to compositor: the palette provider ended. values: the same two handles.
}

// The ring from the input service to the compositor.
Input :: enum u32 {
	None    = 0, // Not a command.
	Key     = 1, // values: code, character, 1 when pressed, modifiers
	Pointer = 2, // values: x motion, y motion (signed), buttons, wheel notches (signed)
}

// The sign of the wheel notches of a pointer record and of an `Event`: a
// notch toward the principal (the wheel turned down) moves a view toward
// the end of its content, as the key Down does. A notch away from the
// principal is the negative of this.
WHEEL_TOWARD_THE_END :: 1

// The codes of the keys: the scan code of set 1 of the keyboard of the PC.
// A key whose scan code comes after the prefix 0xE0 has KEY_EXTENDED added.
KEY_EXTENDED :: 0x100
KEY_ESCAPE :: 0x01 // Escape.
KEY_BACKSPACE :: 0x0E // Backspace.
KEY_ENTER :: 0x1C // Enter.
KEY_TAB :: 0x0F // Tab.
KEY_DELETE :: KEY_EXTENDED | 0x53
KEY_UP :: KEY_EXTENDED | 0x48
KEY_DOWN :: KEY_EXTENDED | 0x50
KEY_LEFT :: KEY_EXTENDED | 0x4B
KEY_RIGHT :: KEY_EXTENDED | 0x4D
KEY_HOME :: KEY_EXTENDED | 0x47
KEY_END :: KEY_EXTENDED | 0x4F
KEY_PAGE_UP :: KEY_EXTENDED | 0x49
KEY_PAGE_DOWN :: KEY_EXTENDED | 0x51
KEY_SUPER :: KEY_EXTENDED | 0x5B // The left key with the logo. The compositor keeps it: it opens the palette.

MODIFIER_SHIFT :: 1 // The bit of `Event.modifiers` set while a Shift key is down.
MODIFIER_CONTROL :: 2 // The bit set while a Control key is down.

BUTTON_LEFT :: 1 // The bit of `Event.buttons` set while the left button is down.
BUTTON_RIGHT :: 2 // The bit set while the right button is down.

SURFACE_LIMIT :: 2048 // The largest width and height.

// One event of a window, as `next_event` gives it. A key event fills
// `code`, `character`, `pressed` and `modifiers`; a pointer event fills
// `x`, `y`, `buttons` and `wheel`.
Event :: struct {
	kind:      Event_Kind, // What happened.
	code:      u32, // A key: its code (`KEY_` constants).
	character: u8, // A key: its character in ASCII, or 0.
	pressed:   bool, // A key: true when it went down, false when it went up.
	modifiers: u32, // A key: the `MODIFIER_` bits.
	x, y:      int, // The pointer: its place in the surface, in pixels; it can be outside the surface.
	buttons:   u32, // The pointer: the `BUTTON_` bits.
	wheel:     int, // The pointer: the notches that the wheel turned since the event before, signed (WHEEL_TOWARD_THE_END).
	act:       u64, // Go_To: the act_name_hash of the act name.
}

// One window of a program: its ring to the compositor and its surface.
// `open` makes it; the program draws in `canvas` and calls `present`.
Window :: struct {
	ring_memory: system.Handle, // The memory of the ring to the compositor.
	ring:        ring.Ring, // The ring, mapped.
	surface:     system.Handle, // The memory of the pixels of the surface.
	canvas:      graphics.Canvas, // Where the program draws now.
	pictures:    [2]graphics.Canvas, // The two pictures of the surface.
	picture:     int, // The index of canvas in pictures.
	presented:   u32, // The count of commands after the last Present.
	wake_when_free: bool, // canvas_free said no: wait_events also ends when the compositor has read the ring.
	compositor_late: bool, // The compositor did not take a picture within the bound: canvas_wait waits no more until it does.
	// The measure of the time of a picture (docs/DESIGN.md, section 7):
	// picture_begin marks the start, present the end; in a measure run the
	// log has their mean after 1, 3 and 10 pictures.
	title:              [32]u8, // The title of the window, for the lines of the measure.
	title_count:        int, // The bytes of the title.
	picture_started:    u64, // Nanoseconds: the start of the picture that is drawn now.
	picture_count:      u64, // The pictures presented.
	picture_time:       u64, // Nanoseconds: the sum of the times of the pictures.
}

PICTURES_MEASURED :: 10 // The pictures after which a measure run writes its last line.
// In a measure run (system.measure_run), the log has the time of the
// pictures of each window, after 1, 3 and 10 pictures. A usual run writes
// none of these lines: the ring of the log keeps 1023 records, and the main
// scenario reads its oldest records (the channel boot) late in the run,
// with about 13 records of room.

// picture_begin marks the start of a picture, for the measure of present.
picture_begin :: proc "contextless" (window: ^Window) {
	window.picture_started = system.nanoseconds()
}

// picture_end ends the measure of a picture: present calls it, and a
// program that draws nothing in a frame (no damage) calls it.
picture_end :: proc "contextless" (window: ^Window) {
	if window.picture_started != 0 && window.picture_count < PICTURES_MEASURED {
		window.picture_time += system.nanoseconds() - window.picture_started
		window.picture_count += 1
		if count := window.picture_count; system.measure_run() && (count == 1 || count == 3 || count == PICTURES_MEASURED) {
			mean := window.picture_time / count
			system.log("display: ", string(window.title[:window.title_count]), " drew one picture in ", mean / 1000, ".", mean / 100 % 10, " us, the mean of ", count)
		}
	}
	window.picture_started = 0
}

// open creates a surface of two pictures and shows it. The program draws in
// window.canvas, then calls present, which changes window.canvas to the
// other picture. The compositor shows the surface after the first present.
//
// error: the record of a failure, if the caller gives one. The record of a
// kernel operation that failed has its operation; a record of open itself
// has the operation 0 and the arguments of OPEN_ARGUMENTS (error_text).
open :: proc "contextless" (ctx: ^system.Context, width, height: int, title: string, error: ^errors.Error_Record = nil) -> (window: Window, ok: bool) {
	window.ring_memory = ctx.handles[system.GRANT_DISPLAY]
	switch {
	case window.ring_memory == 0:
		errors.fail(error, 0, .No_Grant, .Display)
		return {}, false
	case width < 1 || width > SURFACE_LIMIT:
		errors.fail(error, 0, .Bad_Value, .None, 2, i64(width), SURFACE_LIMIT)
		return {}, false
	case height < 1 || height > SURFACE_LIMIT:
		errors.fail(error, 0, .Bad_Value, .None, 3, i64(height), SURFACE_LIMIT)
		return {}, false
	case len(title) > len(system.Name) - 1:
		errors.fail(error, 0, .Too_Long, .Bytes, 4, i64(len(title)), len(system.Name) - 1)
		return {}, false
	}
	text_settings_open(ctx)
	interface_font_load(ctx)
	status: system.Status
	if window.ring, status = system.ring_open(window.ring_memory, error); status != .Ok {
		return {}, false
	}
	address: rawptr
	pages := (u64(width * height * size_of(graphics.Color) * PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	window.surface, status = system.memory_create(pages, error = error)
	if status != .Ok {
		return {}, false
	}
	address, status = system.memory_map(window.surface, error = error)
	if status != .Ok {
		return {}, false
	}
	window.title_count = copy(window.title[:], title)
	for &picture, index in window.pictures {
		picture = {pixels = ([^]graphics.Color)(address)[index * width * height:], width = width, height = height, stride = width}
	}
	window.canvas = window.pictures[0]

	// The compositor maps the ring when the root service tells it of this
	// program. Until then, the grant has no receiver.
	granted: system.Handle
	for attempt in 0 ..< 200 {
		granted, status = system.give(window.ring_memory, window.surface, {.Read}, attempt == 199 ? error : nil) // The compositor reads the surface.
		if status == .Ok {
			break
		}
		system.sleep(system.time() + 5)
	}
	if status != .Ok {
		return {}, false
	}
	name := system.name_pack(title)
	command := ring.Record {
		kind = u32(Command.Surface_Create),
		values = {u64(granted), u64(width), u64(height), name[0], name[1], name[2], name[3]},
	}
	system.send(&window.ring.commands, command)
	return window, true
}

// The names of the arguments of open, for the sentence of a record that
// open wrote: system.wrapper_error_text(writer, &error, "display.open", display.OPEN_ARGUMENTS[:]).
@(rodata)
OPEN_ARGUMENTS := [?]string{"ctx", "width", "height", "title"}

// The pictures of a surface: the one that the compositor reads and the one
// that the program draws. The compositor refuses a surface with less
// memory.
PICTURE_COUNT :: 2

// present tells the compositor that the picture in window.canvas is
// complete. It gives false when the command ring was full: the compositor
// did not get the present.
present :: proc "contextless" (window: ^Window) -> bool {
	return present_rectangle(window, 0, 0, 0, 0)
}

// present_rectangle tells the compositor that the picture in window.canvas
// is complete, and that only one rectangle of the screen differs from it:
// the compositor draws again only that part of the window. A width of 0 is
// the whole surface. After it, window.canvas is the other picture: draw in
// it only when canvas_free or canvas_wait says yes. It gives false when the
// command ring was full: the compositor did not get the present, and the
// canvas stays the same.
present_rectangle :: proc "contextless" (window: ^Window, x, y, width, height: int) -> bool {
	picture_end(window)
	record := ring.Record{kind = u32(Command.Present), values = {0 = u64(window.picture), 1 = u64(max(x, 0)), 2 = u64(max(y, 0)), 3 = u64(max(width, 0)), 4 = u64(max(height, 0))}}
	if !system.send(&window.ring.commands, record) {
		return false
	}
	window.presented = window.ring.commands.counters.write
	window.picture = 1 - window.picture
	window.canvas = window.pictures[window.picture]
	return true
}

// pointer_shape_set asks the compositor for a pointer shape over the
// surface of the window. The compositor shows it while the pointer is over
// this surface and the surface is in front at that place, never over
// another surface, the bar or a frame: a program changes the pointer only
// over its own window. The shape stays until
// the next request; the shape of a new surface is the arrow.
pointer_shape_set :: proc "contextless" (window: ^Window, shape: pointer_pictures.Pointer_Shape) {
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Pointer_Shape), values = {0 = u64(shape)}})
}

// canvas_free says if the program can draw in window.canvas. The compositor
// reads the other picture only after it took the last Present: until then,
// it can still read this one. A program that must never wait asks it
// before it builds a frame. After a no, wait_events also ends when the
// compositor has read the ring of the window: the program asks again.
canvas_free :: proc "contextless" (window: ^Window) -> bool {
	free := compositor_took_the_last_present(window)
	window.wake_when_free = !free
	if free {
		window.compositor_late = false
	}
	return free
}

// compositor_took_the_last_present reads the count of the records that the
// compositor read from the ring of the window.
@(private)
compositor_took_the_last_present :: proc "contextless" (window: ^Window) -> bool {
	return i32(intrinsics.atomic_load_explicit(&window.ring.commands.counters.read, .Relaxed) - window.presented) >= 0
}

// The bound of canvas_wait, in milliseconds. It is not the time that a
// picture takes: the compositor takes a Present in one turn of its loop.
// It only ends a wait for a compositor that does not read at all, so it is
// the hang bound of a check, the same for each host
// (docs/TOOLS.md, "The bounds of the tests").
CANVAS_WAIT_BOUND_MILLISECONDS :: system.TEST_HANG_BOUND_MILLISECONDS

// canvas_wait waits until the program can draw in window.canvas: until the
// compositor took the last Present. The thread waits on the count of the
// records that the compositor read; the compositor wakes it. true: draw.
//
// false: the compositor did not take the Present within the bound. The
// program draws nothing in this turn. The log has one line, and the next
// calls give false at once, with no wait, until the compositor reads
// again: a compositor that does not read costs a program one bound.
//
// One thread owns a window: the flag of the ring that this wait sets is
// cleared after the wait, so a second thread that waits on the same window
// would lose its wake.
canvas_wait :: proc "contextless" (window: ^Window) -> bool {
	if canvas_free(window) {
		return true
	}
	if window.compositor_late {
		return false
	}
	started := system.nanoseconds()
	deadline := system.time() + CANVAS_WAIT_BOUND_MILLISECONDS
	free := false
	for {
		list: system.Wait
		canvas_event_wait(&list, window)
		now := system.wait_end(&list, deadline)
		free = canvas_free(window)
		if free || now >= deadline {
			break
		}
	}
	// The wait for the compositor is not a part of the time of a picture.
	if window.picture_started != 0 {
		window.picture_started += system.nanoseconds() - started
	}
	if !free {
		window.compositor_late = true
		system.log_in("programs", .Warning, "display: ", string(window.title[:window.title_count]), ": the compositor did not take a picture in ", u64(CANVAS_WAIT_BOUND_MILLISECONDS), " ms: this window draws no picture until it does")
	}
	return free
}

// canvas_event_wait adds to a wait list the event of the surface: the
// compositor read a record of the ring of the window.
//
// The list waits while the count of the records read holds the value that
// this procedure read, and only when that value says "not free". The
// compositor adds 1 to the count for each record of any kind, so each
// record that it takes after this read ends the wait: the thread then asks
// again. The wait is on a value that was read, never on a value that is
// computed: a computed value can come true when the compositor takes a
// record more, and the thread then sleeps with no wake to come.
//
// When the canvas is free at this read, no word is added: the list is
// marked full, which ends the wait at once with no kernel entry. The mark
// of the "no" is cleared: one "no" of canvas_free gives one wake, so a
// program that does not ask again does not turn with no sleep.
@(private)
canvas_event_wait :: proc "contextless" (list: ^system.Wait, window: ^Window) {
	counters := window.ring.commands.counters
	read := intrinsics.atomic_load_explicit(&counters.read, .Relaxed)
	if i32(read - window.presented) >= 0 {
		window.wake_when_free = false
		list.full = true
		return
	}
	// The flag "the writer waits" of the ring: the compositor enters the
	// kernel to wake this thread only when it is set (system.wake_writer).
	system.wait_word(list, &counters.read, read, &counters.writer_waits)
}

// wait stops the thread until the window has an input event, or until the
// time is deadline. It gives the time.
wait :: proc "contextless" (window: ^Window, deadline: u64 = system.WAIT_FOREVER) -> u64 {
	list: system.Wait
	wait_events(&list, window)
	return system.wait_end(&list, deadline)
}

// wait_events adds the input events of the window to a wait list, and,
// after canvas_free said no, the event of the surface: the wait also ends
// when the compositor has read the ring of the window.
wait_events :: proc "contextless" (list: ^system.Wait, window: ^Window) {
	system.wait_records(list, &window.ring.completions)
	if window.wake_when_free {
		canvas_event_wait(list, window)
	}
}

// next_event gives the next input event of the window, if there is one.
next_event :: proc "contextless" (window: ^Window) -> (event: Event, ok: bool) {
	record := system.receive(&window.ring.completions) or_return
	event.kind = Event_Kind(record.kind)
	#partial switch event.kind {
	case .Key:
		event.code = u32(record.values[0])
		event.character = u8(record.values[1])
		event.pressed = record.values[2] != 0
		event.modifiers = u32(record.values[3])
	case .Pointer:
		event.x = int(i64(record.values[0]))
		event.y = int(i64(record.values[1]))
		event.buttons = u32(record.values[2])
		// The compositor writes the notches: a count past the limit is cut,
		// so that a sum of them stays far inside an int.
		event.wheel = int(clamp(i64(record.values[3]), -key_path.WHEEL_NOTCHES_LIMIT, key_path.WHEEL_NOTCHES_LIMIT))
	case .Settings_Changed:
		text_settings_apply()
	case .Go_To:
		event.act = record.values[0]
	}
	return event, true
}

// The settings page of this program (modus:contract/settings), or nil.
settings_page: ^settings.Page

// The two glyph caches of this program, each validated once: with the grid fit
// and without it (the setting "grid_fit").
glyph_caches: [settings.Grid_Fit]glyph_cache.Cache
glyph_cache_valid: [settings.Grid_Fit]bool

// text_settings_open finds the settings page in the context, validates the
// glyph caches once (a font file and a cache are hostile input), and
// applies the choice of the owner. With no page, or a cache that the
// validation refuses, the text of the program is Spleen 8x16, with a line
// on the log. The compositor calls it too.
//
// Why one validation is enough: the drawing code reads the counts and the
// offsets of a cache again at each glyph, so the bytes must not change
// after `validate`. A program trusts its starter, which already chooses
// its grants, its mappings and its budget: the starter states in the
// context which fixed ranges it mapped (modus:contract/fixed_addresses) and maps
// the memory there; the cache states its own size in its header. So a
// starter that sets a bit with no mapping, or maps less than the header
// states, makes this program fault, and a starter that keeps that memory
// with Write could change it. The root service is the starter of each
// program with a surface. It maps each cache from the boot image with the
// right Read only, for every program, and the one handle of the boot image,
// its own, has no right Write. So under the root service no program can
// write the bytes of a cache, nor point this program at other bytes. The
// settings page, which the program `settings` writes, gives choices only.
text_settings_open :: proc "contextless" (ctx: ^system.Context) {
	problems, loaded := text_settings_load(ctx)
	if !loaded {
		return
	}
	for problem, grid_fit in problems.cells {
		switch {
		case problem.kind == .None:
		case problem.kind == .Not_Mapped:
			system.log_in("programs", .Warning, "display: no glyph cache with the grid fit ", settings.descriptions[.Grid_Fit].value_names[grid_fit], ": that text is Spleen 8x16")
		case problems.cells_of_another_font[grid_fit]:
			system.log_in("programs", .Warning, "display: the glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ": that text is Spleen 8x16")
		case:
			system.log_in("programs", .Warning, "display: the glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value, ", limit ", problem.limit, ": that text is Spleen 8x16")
		}
	}
	if problems.bold.kind != .None && problems.bold.kind != .Not_Mapped {
		system.log_in("programs", .Warning, "display: the bold glyph cache is refused: ", glyph_cache.problem_sentences[problems.bold.kind], ": the titles are the regular weight")
	}
}

// What text_settings_load refused: the problem of each glyph cache of the
// font of the cells, and of the bold weight. A record of zeros: no problem.
Text_Settings_Problems :: struct {
	cells:                 [settings.Grid_Fit]glyph_cache.Problem, // The cache of each grid fit.
	cells_of_another_font: [settings.Grid_Fit]bool, // The cache is valid, and cannot draw cells (graphics.cell_cache_problem).
	bold:                  glyph_cache.Problem, // The cache of the bold weight. Not_Mapped: the program has none.
}

// text_settings_load does the work of text_settings_open and writes no
// line: the problems are values. loaded is false when the program has no
// settings page, or when the settings were loaded before: nothing was done.
//
// Why it is apart: the drawing module loads the text settings of the
// program that runs it, into its own data, and the program has already
// written the lines. The module must also hold no table of sentences: a
// table of texts has addresses that the loader writes
// (docs/MODULE_CONTRACT.md, "A library as a module").
text_settings_load :: proc "contextless" (ctx: ^system.Context) -> (problems: Text_Settings_Problems, loaded: bool) {
	if .Settings_Page not_in fixed_addresses.ranges_mapped(&ctx.values) || settings_page != nil {
		return {}, false
	}
	settings_page = (^settings.Page)(uintptr(settings.PAGE_ADDRESS))
	places := [settings.Grid_Fit]settings.Glyph_Cache {
		.On  = .With_Grid_Fit,
		.Off = .Without_Grid_Fit,
	}
	for cache, grid_fit in places {
		glyph_caches[grid_fit], problems.cells[grid_fit] = settings.glyph_cache_open(&ctx.values, cache)
		if problems.cells[grid_fit].kind != .None {
			continue
		}
		if refused := graphics.cell_cache_problem(&glyph_caches[grid_fit]); refused.kind != .None {
			problems.cells[grid_fit] = refused
			problems.cells_of_another_font[grid_fit] = true
			continue
		}
		glyph_cache_valid[grid_fit] = true
	}
	// The bold weight of the titles: a text in the regular weight when it
	// is absent or refused.
	bold: glyph_cache.Cache
	bold, problems.bold = settings.glyph_cache_open(&ctx.values, .Bold)
	if problems.bold.kind == .None {
		problems.bold = graphics.text_bold_cache_use(bold)
	}
	text_settings_apply()
	return problems, true
}

// Interface_Font: the two glyph caches of the interface font (docs/FONTS.md,
// section 12), each validated once.
Interface_Font :: struct {
	regular: glyph_cache.Cache, // The regular weight.
	bold:    glyph_cache.Cache, // The bold weight.
}

// interface_font_open validates the two glyph caches of the interface font
// that the starter mapped at their fixed ranges (settings.glyph_cache_open:
// the same rule as the caches of the text of cells). ok is false when one
// is absent or refused, with a line on the log: the program then draws its
// text with the font of the cells. Each cache must be of a proportional
// font: graphics.text_proportional draws it.
interface_font_open :: proc "contextless" (ctx: ^system.Context) -> (font: Interface_Font, ok: bool) {
	weights := [2]settings.Glyph_Cache{.Interface, .Interface_Bold}
	caches: [2]glyph_cache.Cache
	for weight, index in weights {
		problem: glyph_cache.Problem
		caches[index], problem = settings.glyph_cache_open(&ctx.values, weight)
		if problem.kind == .None && caches[index].header.flags & glyph_cache.FLAG_PROPORTIONAL == 0 {
			problem = {kind = .Bad_Flags, value = u64(caches[index].header.flags), limit = glyph_cache.FLAG_PROPORTIONAL}
		}
		if problem.kind == .Not_Mapped {
			// A program that its starter gave no interface font: its
			// elements draw in the font of the cells, with no line on the log.
			return {}, false
		}
		if problem.kind != .None {
			system.log_in("programs", .Warning, "display: the glyph cache of the interface font is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value)
			return {}, false
		}
	}
	return {regular = caches[0], bold = caches[1]}, true
}

// The interface font of this program, validated once by open: the elements
// of src/library/support/interface draw their names, titles and labels in it
// (docs/FONTS.md, section 12.6). Absent: they draw in the font of the
// cells.
program_interface_font: Interface_Font
program_interface_font_given: bool

// interface_font_load validates the interface font of this program once:
// open calls it, and the compositor, which draws with no window of its own.
interface_font_load :: proc "contextless" (ctx: ^system.Context) {
	if !program_interface_font_given {
		program_interface_font, program_interface_font_given = interface_font_open(ctx)
	}
}

// interface_font_of gives the interface font of this program, or nil.
interface_font_of :: proc "contextless" () -> ^Interface_Font {
	return program_interface_font_given ? &program_interface_font : nil
}

// text_settings_apply gives the choice of the settings page to
// src/library/support/graphics: the font, the order of the stripes, and the glyph cache
// of the grid fit.
text_settings_apply :: proc "contextless" () {
	if settings_page == nil {
		return
	}
	choice := settings.read(settings_page)
	grid_fit := settings.grid_fit_of(choice)
	font := settings.font_of(choice) == .Spleen ? graphics.Text_Font.Spleen : graphics.Text_Font.Vector
	if glyph_cache_valid[grid_fit] {
		graphics.text_cache_use(glyph_caches[grid_fit])
	} else {
		font = .Spleen
	}
	graphics.text_choice_set(font, graphics.Subpixel_Order(u8(settings.subpixel_order_of(choice))))
}
