// The display protocol, and the code that a process uses to show a surface.
//
// A process and the compositor share one ring. The process sends command
// records; the compositor sends input as completion records. The pixels of
// the surface are memory that the process creates and grants to the
// compositor. No pixel goes through the ring or through the kernel.
//
// The memory of a surface has two pictures. The process draws one while
// the compositor reads the other, and Present names the picture that is
// complete: the screen never shows a picture that is being drawn. After a
// Present, `window.canvas` is the other picture, which holds the frame of
// two frames before: a process that draws by hand draws the whole canvas.
// The process draws only when the compositor took the last Present
// (`canvas_free`, `canvas_wait`).
//
// Who uses it: each process with a window (`open`, `next_event`,
// `present`), the compositor (the other side of the ring, and the rings
// `Control` and `Input`), and `src/library/support/interface`, which draws with it. It
// also loads the text settings of the process: the glyph caches and the
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
// A window is fixed unless its process calls `resizable_set`: the
// principal can then drag its edges, the process gets the event `Resized`
// and calls `surface_resize`, which makes the surface of the new size
// (src/md/features/window_resize.md).
//
// See [surface](term:surface), [whole frame](term:whole-frame),
// [resizable window](term:resizable-window) and
// [compositor](term:compositor).
package display

import "modus:contract/enum_word"
import "base:intrinsics"
import "modus:contract/errors"
import "modus:support/graphics"
import "modus:contract/ring"
import "modus:support/key_path"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import op "modus:contract/operation"
import "modus:contract/glyph_cache"
import "modus:support/text_rendering"
import "modus:contract/pointer_pictures"
import "modus:contract/settings"
import "modus:contract/text_encoding"
import "modus:support/system"

// A command of a process to the compositor, on the ring of its window.
Command :: enum u32 {
	None           = 0, // Not a command.
	Surface_Create = 1, // values: memory handle (in the compositor), width, height, title (4 values)
	// The pixels of the surface changed. values: the picture to show (0 or
	// 1), then the rectangle that changed: x, y, width, height (width 0: the
	// whole surface), then at PRESENT_KEY_SERIAL the serial of the newest
	// key that the picture shows, or 0 (key_shown).
	Present        = 2,
	Pointer_Shape  = 3, // The pointer shape over this surface (docs/POINTERS.md). values: a number of pointer_pictures.Pointer_Shape
	// The act names of the window: what its elements act on, so that the
	// palette offers to go there (docs/INTERFACE.md, "4.2 Act names").
	// values[0]: the count, 0 to ACT_NAME_SET_CAPACITY; values[1..]: the
	// act_name_hash of each act name. The set replaces the set before. The
	// window layer sends it when the set of a frame changes (act_names_send).
	Act_Names      = 4,
	// A change of the window waits for its next picture: the process draws
	// it at a time of its own clock, or when the compositor took the last
	// picture. values[0]: 1 when a picture is due, 0 when it is no longer
	// due. A Present ends it too. The compositor gives it in windows(), so
	// a reader of the screen knows that the window is not its last picture
	// while the process waits (picture_due_set).
	Picture_Due    = 5,
	// The window is resizable within its size limits; with no such record
	// it is fixed (src/md/features/window_resize.md). values: the least
	// width, the least height, the largest width and the largest height of
	// the surface. The record replaces the limits before. The compositor
	// refuses limits that size_limits_of_words refuses, and the window stays
	// as it was (resizable_set).
	Resizable      = 6,
	// The surface of a new size, the answer to the event Resized: the
	// compositor shows it from the next Present, and the old surface until
	// then. Its size is the size of the event; the compositor takes one
	// answer for each event, and refuses any other. values: memory handle
	// (in the compositor), width, height (surface_resize).
	Surface_Resize = 7,
	// The other answer to the event Resized: the window keeps its size,
	// after a refused budget, or because the process does not take the
	// event (present_rectangle sends it then). No values.
	Resize_Declined = 8,
	// The answer to the event Copy_Asked: the content of the copy, a
	// memory object of this process that the compositor reads with Read
	// and lends with Give (src/md/features/clipboard.md). values: memory
	// handle (in the compositor), the Clipboard_Kind, the count of bytes,
	// the serial of the Copy_Asked that it answers (copy_send).
	Copy            = 9,
	// The other answer to Copy_Asked: the window has nothing to copy, or
	// refused its text or its budget. values: the serial of the Copy_Asked
	// (copy_decline).
	Copy_Declined   = 10,
	// The answer to the event Pasted: the process copied the content, and
	// closed the handle. The compositor revokes the lent handle. values:
	// the serial of the Pasted (paste_read, paste_refuse).
	Paste_Taken     = 11,
}

// The kind of a content of the clipboard. A word of a record becomes a
// member at one place only (clipboard_kind_of_word).
Clipboard_Kind :: enum u32 {
	None = 0, // No content.
	Text = 1, // UTF-8 with no control character.
}

// The most bytes of a text on the clipboard: one page, a field or a line
// of the console.
CLIPBOARD_TEXT_LIMIT :: 4096

// clipboard_kind_of_word is the border of the kind of a content: the
// member, or false for a word that names no member, None included.
clipboard_kind_of_word :: proc "contextless" (word: u64) -> (kind: Clipboard_Kind, ok: bool) {
	member := enum_word.member_of_word(Clipboard_Kind, word) or_return
	return member, member != .None
}

// The rule that a text to copy, or the copy of a paste, breaks. None: it
// holds.
Clipboard_Problem :: enum {
	None,
	Not_Asked, // No Copy_Asked waits for an answer.
	Empty, // No byte.
	Too_Large, // Past CLIPBOARD_TEXT_LIMIT, or past the room of the field that pastes.
	Not_Text, // A byte that starts no well-formed sequence of UTF-8, or a control character.
	Hidden_Character, // A character that a reader does not see, or that changes the order of the text (character_hidden).
	Unknown_Kind, // A kind that this process does not read.
	Not_Given, // The handle of a paste is not memory with Read that the compositor gave through the ring.
	Too_Small, // The memory of a paste does not hold its count of bytes.
	Ring_Full, // The command ring of the window is full: nothing was made.
	Kernel_Refused, // A kernel operation refused: the status says which (No_Budget for a budget that cannot pay).
}

// The words of each problem, for a line of the log.
@(rodata)
CLIPBOARD_PROBLEM_SENTENCES := [Clipboard_Problem]string {
	.None           = "the text holds",
	.Not_Asked      = "no copy of the principal waits",
	.Empty          = "the text is empty",
	.Too_Large      = "the text is larger than the room",
	.Not_Text       = "the bytes are not UTF-8 with no control character",
	.Hidden_Character = "the text has a character that a reader does not see, or that changes the order of the text",
	.Unknown_Kind   = "the kind is not text",
	.Not_Given      = "the handle is not memory that the compositor gave",
	.Too_Small      = "the memory does not hold the count of bytes",
	.Ring_Full      = "the command ring of the window is full",
	.Kernel_Refused = "the kernel refused",
}

// clipboard_text_problem checks a text at a border of the clipboard: the
// text to copy before it is made, and the copy of a paste after it is
// copied. room is the most bytes that the place takes. It reads and
// changes no state, so a host test gives it each refused text.
clipboard_text_problem :: proc "contextless" (text: []u8, room: int) -> Clipboard_Problem {
	switch {
	case len(text) == 0:
		return .Empty
	case len(text) > CLIPBOARD_TEXT_LIMIT || len(text) > room:
		return .Too_Large
	case !text_encoding.text_valid(text):
		return .Not_Text
	}
	for place := 0; place < len(text); {
		character, length, _ := text_encoding.character_decode(text, place)
		if length == 0 {
			break
		}
		if character_hidden(character) {
			return .Hidden_Character
		}
		place += length
	}
	return .None
}

// character_hidden says if a character is one that a reader does not see,
// or one that changes the order in which a text shows: the spaces and the
// joiners of no width, the marks and the embeddings of direction, the
// isolates, the separators of lines and of paragraphs, and the mark of the
// byte order. A pasted text with one of them could show as another text,
// in a line of the console that the principal then runs.
character_hidden :: proc "contextless" (character: rune) -> bool {
	switch character {
	case 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2066 ..= 0x2069, 0x2028, 0x2029, 0xFEFF:
		return true
	}
	return false
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

// What the compositor tells a process, as the kind of a completion record of
// its ring, and as the kind of an `Event`.
Event_Kind :: enum u32 {
	None             = 0, // No event.
	Key              = 1, // values: code, character, 1 when pressed, modifiers, then at KEY_EVENT_SERIAL the serial of the key (0: the compositor does not measure it)
	Pointer          = 2, // values: x, y in the surface (signed), buttons, wheel notches (signed: WHEEL_TOWARD_THE_END for each notch toward the end of the content)
	// The settings of the owner changed (modus:contract/settings): next_event
	// already gave the new font to src/library/support/graphics; the process draws its
	// window again. values: the change count of the settings page.
	Settings_Changed = 3,
	// The palette goes to an element of this window: the compositor raised
	// it. values[0]: the act_name_hash of the act name. The window layer
	// puts the focus on the element that names it
	// (src/library/support/interface, window_events).
	Go_To            = 4,
	// The principal dragged an edge of the window to a new size: the
	// process makes its surface of that size (surface_resize), or ignores
	// the event and keeps its size. Only a resizable window gets it.
	// values: the width, the height of the surface.
	Resized          = 5,
	// The principal pressed the key of a copy: the process answers once,
	// with copy_send or copy_decline. A newer Copy_Asked replaces it.
	// values: the serial of the key, never 0.
	Copy_Asked       = 6,
	// The principal pressed the key of a paste: a handle with Read to the
	// content, lent until the process answers (paste_read). values: the
	// handle (in this process), the Clipboard_Kind, the count of bytes,
	// the serial of the key, never 0.
	Pasted           = 7,
}

// The ring between the root service and the compositor.
Control :: enum u32 {
	None          = 0, // Not a command.
	// root to compositor. values: ring memory handle (in the compositor). For
	// a disk process, values 1 to 3 hold its nickname, as the root ring
	// carries a name of 23 bytes, and value 4 the first 8 bytes of the hash
	// of its file (modus:contract/disk_process_page, hash_head); for another
	// process, values 1 to 4 are 0.
	Client_Add    = 1,
	Client_Remove = 2, // root to compositor. values: the same handle
	Start         = 3, // compositor to root. values: name (4 values)
	Stop          = 4, // compositor to root. values: the handle of the client
	// root to compositor: a process is the palette provider. values: the
	// handle of its ring, then the handle of its entry table, read-only
	// (modus:contract/palette_table), both in the compositor.
	Palette_Provider_Add    = 5,
	Palette_Provider_Remove = 6, // root to compositor: the palette provider ended. values: the same two handles.
	// root to compositor: the process of a window started. values: the
	// handle of Client_Add, then the time of the system, in nanoseconds,
	// when the root service called system.process_start: the start of the
	// measure of the start of a window
	// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
	Client_Started          = 7,
}

// The ring from the input service to the compositor.
Input :: enum u32 {
	None    = 0, // Not a command.
	Key     = 1, // values: code, character (a code point, or 0), 1 when pressed, modifiers, then at INPUT_KEY_READ_AT the time of the system, in nanoseconds, when the input service read the key
	Pointer = 2, // values: x motion, y motion (signed), buttons, wheel notches (signed)
}

// The places of the values of the measure of a key to the screen, in the
// records that carry it: the input record Key, the event Key and the
// command Present. The values before them are the values of each record.
INPUT_KEY_READ_AT :: 4
KEY_EVENT_SERIAL :: 4
PRESENT_KEY_SERIAL :: 5

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

// The least size of a resizable surface: the title bar holds the close
// button and a part of the title.
RESIZABLE_LEAST_WIDTH :: 160
RESIZABLE_LEAST_HEIGHT :: 64

// The sizes between which the principal can resize a window: its process
// states them (resizable_set), the compositor keeps the drag inside them.
Size_Limits :: struct {
	least_width, least_height:     int,
	largest_width, largest_height: int,
}

// The rule that size limits break. None: they hold.
Size_Limits_Problem :: enum {
	None,
	Largest_Past_Limit, // A largest size is past SURFACE_LIMIT.
	Least_Below_Floor, // A least size is below RESIZABLE_LEAST_WIDTH or RESIZABLE_LEAST_HEIGHT.
	Least_Past_Largest, // A least size is past its largest size.
	Size_Outside, // The size of the surface now is outside the limits.
}

// The words of each problem, for a line of the log.
@(rodata)
SIZE_LIMITS_PROBLEM_SENTENCES := [Size_Limits_Problem]string {
	.None               = "the limits hold",
	.Largest_Past_Limit = "a largest size is past the largest surface",
	.Least_Below_Floor  = "a least size is below the least size of a resizable surface",
	.Least_Past_Largest = "a least size is past its largest size",
	.Size_Outside       = "the size of the surface is outside the limits",
}

// size_limits_of_words is the border of the record Resizable: the four
// words of the limits, checked as words before any of them becomes an int,
// so that a word past the limit never reads as a negative size. width and
// height are the size of the surface now. It reads and changes no state,
// so a host test gives it each refused word.
size_limits_of_words :: proc "contextless" (words: [4]u64, width, height: int) -> (limits: Size_Limits, problem: Size_Limits_Problem) {
	switch {
	case words[2] > SURFACE_LIMIT || words[3] > SURFACE_LIMIT:
		return {}, .Largest_Past_Limit
	case words[0] < RESIZABLE_LEAST_WIDTH || words[1] < RESIZABLE_LEAST_HEIGHT:
		return {}, .Least_Below_Floor
	case words[0] > words[2] || words[1] > words[3]:
		return {}, .Least_Past_Largest
	}
	limits = {least_width = int(words[0]), least_height = int(words[1]), largest_width = int(words[2]), largest_height = int(words[3])}
	if !size_inside(limits, width, height) {
		return {}, .Size_Outside
	}
	return limits, .None
}

// size_inside says if a size is inside the limits.
size_inside :: proc "contextless" (limits: Size_Limits, width, height: int) -> bool {
	return width >= limits.least_width && width <= limits.largest_width && height >= limits.least_height && height <= limits.largest_height
}

// One event of a window, as `next_event` gives it. A key event fills
// `code`, `character`, `pressed` and `modifiers`; a pointer event fills
// `x`, `y`, `buttons` and `wheel`.
Event :: struct {
	kind:      Event_Kind, // What happened.
	code:      u32, // A key: its code (`KEY_` constants).
	character: rune, // A key: its character as a code point, or 0. A process that keeps it writes its UTF-8.
	pressed:   bool, // A key: true when it went down, false when it went up.
	modifiers: u32, // A key: the `MODIFIER_` bits.
	x, y:      int, // The pointer: its place in the surface, in pixels; it can be outside the surface.
	buttons:   u32, // The pointer: the `BUTTON_` bits.
	wheel:     int, // The pointer: the notches that the wheel turned since the event before, signed (WHEEL_TOWARD_THE_END).
	act:       u64, // Go_To: the act_name_hash of the act name.
	width, height: int, // Resized: the size that the principal asks for the surface, 1 to SURFACE_LIMIT.
	paste_handle:   system.Handle, // Pasted: the lent handle of the content.
	clipboard_kind: Clipboard_Kind, // Pasted: the kind of the content, never None.
	byte_count:     int, // Pasted: the bytes of the content, 1 to CLIPBOARD_TEXT_LIMIT.
	clipboard_serial: u64, // Copy_Asked and Pasted: the serial of the key, never 0; the answer names it.
	key_serial: u64, // A key: the serial that the compositor gave it, or 0. A process that shows the key names it (key_shown).
}

// One window of a process: its ring to the compositor and its surface.
// `open` makes it; the process draws in `canvas` and calls `present`.
Window :: struct {
	ring_memory: system.Handle, // The memory of the ring to the compositor.
	ring:        ring.Ring, // The ring, mapped.
	surface:     system.Handle, // The memory of the pixels of the surface.
	canvas:      graphics.Canvas, // Where the process draws now.
	pictures:    [2]graphics.Canvas, // The two pictures of the surface.
	picture:     int, // The index of canvas in pictures.
	presented:   u32, // The count of commands after the last Present.
	wake_when_free: bool, // canvas_free said no: wait_events also ends when the compositor has read the ring.
	compositor_late: bool, // The compositor did not take a picture within the bound: canvas_wait waits no more until it does.
	picture_due_sent: bool, // The compositor has a Picture_Due of 1 and no Present or Picture_Due of 0 after it.
	size_limits: Size_Limits, // The limits of the last Resizable that went to the compositor.
	resizable:   bool, // A Resizable went to the compositor: the window can get Resized.
	resized_picture_due: bool, // surface_resize made a new surface, and no Present of it went yet: the first one writes a line.
	// The last event Resized that next_event gave, with no answer sent yet:
	// surface_resize answers it, or the next present declines it.
	resize_asked: bool,
	resize_asked_width, resize_asked_height: int,
	copy_asked: bool, // A Copy_Asked came, and no answer went: copy_send or copy_decline answers it.
	copy_serial: u64, // The serial of the newest Copy_Asked, which the answer names.
	key_shown_serial: u64, // The newest key that the pictures of the window show (key_shown): each Present names it.
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
// none of these lines: they would add three lines for each window to the
// log of each test.

// picture_begin marks the start of a picture, for the measure of present.
picture_begin :: proc "contextless" (window: ^Window) {
	window.picture_started = system.nanoseconds()
}

// picture_end ends the measure of a picture: present calls it, and a
// process that draws nothing in a frame (no damage) calls it.
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

// open creates a surface of two pictures and shows it. The process draws in
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
	// process. Until then, the grant has no receiver.
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
// that the process draws. The compositor refuses a surface with less
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
	// A process that presents with a request that it did not answer keeps
	// its size: the answer goes before the picture, so that the compositor
	// takes a drag of the window again.
	if window.resize_asked && !resize_decline(window) {
		return false
	}
	picture_end(window)
	record := ring.Record{kind = u32(Command.Present), values = {0 = u64(window.picture), 1 = u64(max(x, 0)), 2 = u64(max(y, 0)), 3 = u64(max(width, 0)), 4 = u64(max(height, 0)), PRESENT_KEY_SERIAL = window.key_shown_serial}}
	if !system.send(&window.ring.commands, record) {
		return false
	}
	window.presented = window.ring.commands.counters.write
	window.picture = 1 - window.picture
	window.canvas = window.pictures[window.picture]
	// The compositor ends the due picture at the Present.
	window.picture_due_sent = false
	// The compositor shows the new surface from this Present: a machine
	// test waits for this line before a picture of the new size.
	if window.resized_picture_due {
		window.resized_picture_due = false
		system.log_in("processes", .Info, "display: ", string(window.title[:window.title_count]), ": the first picture of ", u64(window.canvas.width), "x", u64(window.canvas.height), " after a resize")
	}
	return true
}

// key_shown says that the next picture of the window shows the key of a
// serial (Event.key_serial) and each key before it: the process calls it
// when the key changed what it draws, as the console when a character goes
// into its line. Each Present names the newest serial, and the compositor
// measures the time of those keys to the screen at the flip of that
// picture. A serial of 0, or one older than the newest, changes nothing.
key_shown :: proc "contextless" (window: ^Window, serial: u64) {
	window.key_shown_serial = max(window.key_shown_serial, serial)
}

// resizable_set makes the window resizable within limits: the principal
// can then drag its edges, and the process gets the event Resized. With no
// call the window is fixed. A process that draws with constant sizes stays
// fixed; one whose texts need a width states that width as its least.
//
// The limits must hold for the size of the surface now
// (size_limits_of_words): problem says which rule they break, and nothing
// goes to the compositor. sent is false when the command ring was full:
// the window stays as it was, and the caller tries again later.
resizable_set :: proc "contextless" (window: ^Window, limits: Size_Limits) -> (problem: Size_Limits_Problem, sent: bool) {
	words := [4]u64{u64(max(limits.least_width, 0)), u64(max(limits.least_height, 0)), u64(max(limits.largest_width, 0)), u64(max(limits.largest_height, 0))}
	checked, refused := size_limits_of_words(words, window.pictures[0].width, window.pictures[0].height)
	if refused != .None {
		return refused, false
	}
	record := ring.Record{kind = u32(Command.Resizable), values = {0 = words[0], 1 = words[1], 2 = words[2], 3 = words[3]}}
	if !system.send(&window.ring.commands, record) {
		return .None, false
	}
	window.size_limits, window.resizable = checked, true
	return .None, true
}

// surface_resize gives the window a surface of a new size, after the event
// Resized: the process calls it, then draws its next frame in
// window.canvas, which the compositor does not read yet. The compositor
// shows the old surface until the first Present of the new one.
//
// The new surface is memory of this process, paid by its budget. This
// procedure unmaps and closes the old one, which the compositor still maps
// until that Present: the budget pays for both until then, and the old
// memory ends when the compositor unmaps it.
//
// It answers the last Resized that next_event gave, with its size only:
// the compositor takes no other size, and no surface that the principal
// did not ask for.
//
// The statuses: Ok; Bad_Operation for a window that is not resizable, with
// no Resized to answer, for another size than the asked one, or for a size
// outside its limits (nothing changes); No_Slot when the command ring is
// full (nothing was made: call again later, or the next present declines
// the request); No_Budget, or another status of Memory_Create, Memory_Map
// or Handle_Give, with its error record: the window keeps its size, writes
// one line, and declines the request (Resize_Declined), so that the
// principal can drag it again.
surface_resize :: proc "contextless" (window: ^Window, width, height: int, error: ^errors.Error_Record = nil) -> system.Status {
	title := string(window.title[:window.title_count])
	switch {
	case !window.resizable:
		errors.fail(error, 0, .State, .None, 1)
		return .Bad_Operation
	case !window.resize_asked || width != window.resize_asked_width || height != window.resize_asked_height:
		errors.fail(error, 0, .State, .None, 2, i64(width), i64(window.resize_asked_width), i64(height))
		return .Bad_Operation
	case !size_inside(window.size_limits, width, height):
		errors.fail(error, 0, .Out_Of_Range, .None, width < window.size_limits.least_width || width > window.size_limits.largest_width ? 2 : 3, i64(width), i64(window.size_limits.largest_width), i64(height))
		return .Bad_Operation
	case ring.count(&window.ring.commands) == ring.capacity(&window.ring.commands):
		// The ring has one writer, this thread: the room seen here stays.
		// Without it, the handle given below would wait in the table of the
		// compositor with no record that names it.
		errors.fail(error, 0, .Full, .None, 0)
		return .No_Slot
	}
	pages := (u64(width * height * size_of(graphics.Color) * PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, status := system.memory_create(pages, error = error)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(memory, error = error)
		if status != .Ok {
			system.close(memory)
		}
	}
	granted: system.Handle
	if status == .Ok {
		granted, status = system.give(window.ring_memory, memory, {.Read}, error)
		if status != .Ok {
			system.memory_unmap(address)
			system.close(memory)
		}
	}
	if status != .Ok {
		system.log_in("processes", .Warning, "display: ", title, ": no surface of ", u64(width), "x", u64(height), " (", op.STATUS_NAMES[status], "): the window keeps ", u64(window.pictures[0].width), "x", u64(window.pictures[0].height))
		// A full ring keeps the request: the next present declines it.
		resize_decline(window)
		return status
	}
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Resize), values = {0 = u64(granted), 1 = u64(width), 2 = u64(height)}})
	window.resize_asked = false
	system.memory_unmap(rawptr(window.pictures[0].pixels))
	system.close(window.surface)
	window.surface = memory
	for &picture, index in window.pictures {
		picture = {pixels = ([^]graphics.Color)(address)[index * width * height:], width = width, height = height, stride = width}
	}
	window.picture = 0
	window.canvas = window.pictures[0]
	window.resized_picture_due = true
	return .Ok
}

// resize_decline answers the last Resized with Resize_Declined: the window
// keeps its size, and the compositor takes a drag of it again. It gives
// false when the command ring was full: the request stays, and the next
// present declines it.
resize_decline :: proc "contextless" (window: ^Window) -> bool {
	if !system.send(&window.ring.commands, ring.Record{kind = u32(Command.Resize_Declined)}) {
		return false
	}
	window.resize_asked = false
	system.log_in("processes", .Info, "display: ", string(window.title[:window.title_count]), ": the window keeps ", u64(window.pictures[0].width), "x", u64(window.pictures[0].height), ", not the asked ", u64(max(window.resize_asked_width, 0)), "x", u64(max(window.resize_asked_height, 0)))
	return true
}

// picture_due_set tells the compositor that a change of the window waits
// for its next picture (due), or that no picture is due any more. A process
// that draws on its own clock, or that waits for the compositor to take its
// last picture, calls it before it waits with a change that it did not
// draw: the wait then does not look like a window with nothing to draw. A
// frame with no change to present calls it with false. A record goes only
// when the state changes. When the command ring is full, nothing goes, and
// the next call tries again.
picture_due_set :: proc "contextless" (window: ^Window, due: bool) {
	if window.picture_due_sent == due {
		return
	}
	if system.send(&window.ring.commands, ring.Record{kind = u32(Command.Picture_Due), values = {0 = due ? u64(1) : u64(0)}}) {
		window.picture_due_sent = due
	}
}

// pointer_shape_set asks the compositor for a pointer shape over the
// surface of the window. The compositor shows it while the pointer is over
// this surface and the surface is in front at that place, never over
// another surface, the bar or a frame: a process changes the pointer only
// over its own window. The shape stays until
// the next request; the shape of a new surface is the arrow.
pointer_shape_set :: proc "contextless" (window: ^Window, shape: pointer_pictures.Pointer_Shape) {
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Pointer_Shape), values = {0 = u64(shape)}})
}

// canvas_free says if the process can draw in window.canvas. The compositor
// reads the other picture only after it took the last Present: until then,
// it can still read this one. A process that must never wait asks it
// before it builds a frame. After a no, wait_events also ends when the
// compositor has read the ring of the window: the process asks again.
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

// canvas_wait waits until the process can draw in window.canvas: until the
// compositor took the last Present. The thread waits on the count of the
// records that the compositor read; the compositor wakes it. true: draw.
//
// false: the compositor did not take the Present within the bound. The
// process draws nothing in this turn. The log has one line, and the next
// calls give false at once, with no wait, until the compositor reads
// again: a compositor that does not read costs a process one bound.
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
		system.log_in("processes", .Warning, "display: ", string(window.title[:window.title_count]), ": the compositor did not take a picture in ", u64(CANVAS_WAIT_BOUND_MILLISECONDS), " ms: this window draws no picture until it does")
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
// process that does not ask again does not turn with no sleep.
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

// key_character_of gives the character of a key record: its code point, or
// 0 for a value past the last code point. A key with a control character
// (Enter, Tab, Backspace) keeps it.
key_character_of :: proc "contextless" (value: u64) -> rune {
	return value <= text_encoding.CODE_POINT_LAST ? rune(value) : 0
}

// next_event gives the next input event of the window, if there is one. A
// record that event_of_record refuses is not an event: it costs one line of
// the log, and the next record is read.
next_event :: proc "contextless" (window: ^Window) -> (event: Event, ok: bool) {
	for {
		record := system.receive(&window.ring.completions) or_return
		read, read_ok := event_of_record(record)
		if !read_ok {
			system.log_in("processes", .Warning, "display: ", string(window.title[:window.title_count]), ": the compositor sent a record of the kind ", u64(record.kind), ", which names no event or has a size out of its range: it is refused")
			continue
		}
		if read.kind == .Settings_Changed {
			text_settings_apply()
		}
		if read.kind == .Resized {
			window.resize_asked = true
			window.resize_asked_width, window.resize_asked_height = read.width, read.height
		}
		if read.kind == .Copy_Asked {
			// The newest request replaces the one before: the compositor
			// takes only an answer to it.
			window.copy_asked, window.copy_serial = true, read.clipboard_serial
		}
		return read, true
	}
}

// control_of_ring_word, input_of_ring_word and command_of_ring_word are the
// borders of the kind of a record that the compositor reads: from the root
// service (Control), from the input service (Input) and from a window
// (Command). Each gives the member, or false for a word that names no
// member, None included. They read and change no state, so a host test
// gives them each refused word.
control_of_ring_word :: proc "contextless" (word: u32) -> (control: Control, ok: bool) {
	member := enum_word.member_of_word(Control, u64(word)) or_return
	return member, member != .None
}

input_of_ring_word :: proc "contextless" (word: u32) -> (input: Input, ok: bool) {
	member := enum_word.member_of_word(Input, u64(word)) or_return
	return member, member != .None
}

command_of_ring_word :: proc "contextless" (word: u32) -> (command: Command, ok: bool) {
	member := enum_word.member_of_word(Command, u64(word)) or_return
	return member, member != .None
}

// event_of_record is the border of an input record of the compositor: the
// event, or false for a kind that names no event, None included, and for a
// Resized whose size is 0 or past SURFACE_LIMIT, and for a Copy_Asked or a
// Pasted whose words are out of their range. It reads
// and changes no state, so a host test gives it each refused kind.
event_of_record :: proc "contextless" (record: ring.Record) -> (event: Event, ok: bool) {
	kind := enum_word.member_of_word(Event_Kind, u64(record.kind)) or_return
	event.kind = kind
	switch kind {
	case .None:
		return {}, false
	case .Key:
		event.code = u32(record.values[0])
		event.character = key_character_of(record.values[1])
		event.pressed = record.values[2] != 0
		event.modifiers = u32(record.values[3])
		event.key_serial = record.values[KEY_EVENT_SERIAL]
	case .Pointer:
		event.x = int(i64(record.values[key_path.POINTER_RECORD_X]))
		event.y = int(i64(record.values[key_path.POINTER_RECORD_Y]))
		event.buttons = u32(record.values[key_path.POINTER_RECORD_BUTTONS])
		// The compositor writes the notches: a count past the limit is cut,
		// so that a sum of them stays far inside an int.
		event.wheel = int(clamp(i64(record.values[key_path.POINTER_RECORD_WHEEL]), -key_path.WHEEL_NOTCHES_LIMIT, key_path.WHEEL_NOTCHES_LIMIT))
	case .Settings_Changed:
	case .Go_To:
		event.act = record.values[0]
	case .Resized:
		// The words are read as words: one past the limit never becomes a
		// negative size.
		width, height := record.values[0], record.values[1]
		if width == 0 || height == 0 || width > SURFACE_LIMIT || height > SURFACE_LIMIT {
			return {}, false
		}
		event.width, event.height = int(width), int(height)
	case .Copy_Asked:
		if record.values[0] == 0 {
			return {}, false
		}
		event.clipboard_serial = record.values[0]
	case .Pasted:
		// A handle is 32 bits, a kind a member, a count 1 to the limit, a
		// serial not 0: each is checked as the word that the compositor
		// wrote.
		handle, count, serial := record.values[0], record.values[2], record.values[3]
		kind, kind_ok := clipboard_kind_of_word(record.values[1])
		if handle == 0 || handle > u64(max(u32)) || !kind_ok || count == 0 || count > CLIPBOARD_TEXT_LIMIT || serial == 0 {
			return {}, false
		}
		event.paste_handle, event.clipboard_kind, event.byte_count, event.clipboard_serial = system.Handle(handle), kind, int(count), serial
	}
	return event, true
}

// The settings page of this process (modus:contract/settings), or nil.
settings_page: ^settings.Page

// The text state of the graphics package has its table of the blend: the
// first text_settings_load filled it.
@(private)
text_state_started: bool

// The two glyph caches of this process, each validated once: with the grid fit
// and without it (the setting "grid_fit").
glyph_caches: [settings.Grid_Fit]glyph_cache.Cache
glyph_cache_valid: [settings.Grid_Fit]bool

// text_settings_open finds the settings page in the context, validates the
// glyph caches once (a font file and a cache are hostile input), and
// applies the choice of the owner. With no page, or a cache that the
// validation refuses, the text of the process is Spleen 8x16, with a line
// on the log. The compositor calls it too.
//
// Why one validation is enough: the drawing code reads the counts and the
// offsets of a cache again at each glyph, so the bytes must not change
// after `validate`. A process trusts its starter, which already chooses
// its grants, its mappings and its budget: the starter states in the
// context which fixed ranges it mapped (modus:contract/fixed_addresses) and maps
// the memory there; the cache states its own size in its header. So a
// starter that sets a bit with no mapping, or maps less than the header
// states, makes this process fault, and a starter that keeps that memory
// with Write could change it. The root service is the starter of each
// process with a surface. It maps each cache from the boot image with the
// right Read only, for every process, and the one handle of the boot image,
// its own, has no right Write. So under the root service no process can
// write the bytes of a cache, nor point this process at other bytes. The
// settings page, which the process `settings` writes, gives choices only.
text_settings_open :: proc "contextless" (ctx: ^system.Context) {
	problems, loaded := text_settings_load(ctx)
	if !loaded {
		return
	}
	for problem, grid_fit in problems.cells {
		switch {
		case problem.kind == .None:
		case problem.kind == .Not_Mapped:
			system.log_in("processes", .Warning, "display: no glyph cache with the grid fit ", settings.descriptions[.Grid_Fit].value_names[grid_fit], ": that text is Spleen 8x16")
		case problems.cells_of_another_font[grid_fit]:
			system.log_in("processes", .Warning, "display: the glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ": that text is Spleen 8x16")
		case:
			system.log_in("processes", .Warning, "display: the glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value, ", limit ", problem.limit, ": that text is Spleen 8x16")
		}
	}
	if problems.bold.kind != .None && problems.bold.kind != .Not_Mapped {
		system.log_in("processes", .Warning, "display: the bold glyph cache is refused: ", glyph_cache.problem_sentences[problems.bold.kind], ": the titles are the regular weight")
	}
	if problems.outlines.kind != .None && problems.outlines.kind != .Not_Mapped {
		system.log_in("processes", .Warning, "display: the font outlines are refused: ", font_outlines.problem_sentences[problems.outlines.kind], ", value ", problems.outlines.value, ": the characters past the glyph caches draw the replacement glyph")
	}
	if problems.fonts_missing != {} {
		system.log_in("processes", .Warning, "display: the font outlines lack ", u64(card(problems.fonts_missing)), " fonts of the fallback chains, or the renderer refuses them: the chains skip them")
	}
}

// What text_settings_load refused: the problem of each glyph cache of the
// font of the cells, of the bold weight and of the font outlines. A record
// of zeros: no problem.
Text_Settings_Problems :: struct {
	cells:                 [settings.Grid_Fit]glyph_cache.Problem, // The cache of each grid fit.
	cells_of_another_font: [settings.Grid_Fit]bool, // The cache is valid, and cannot draw cells (graphics.cell_cache_problem).
	bold:                  glyph_cache.Problem, // The cache of the bold weight. Not_Mapped: the process has none.
	outlines:              font_outlines.Problem, // The font outlines. Not_Mapped: the process has none.
	fonts_missing:         text_rendering.Outline_Fonts, // The fonts of the chains that the outlines lack or that the renderer refuses.
}

// text_settings_load does the work of text_settings_open and writes no
// line: the problems are values. loaded is false when the process has no
// settings page, or when the settings were loaded before: nothing was done.
//
// Why it is apart: the drawing module loads the text settings of the
// process that runs it, into its own data, and the process has already
// written the lines. The module must also hold no table of sentences: a
// table of texts has addresses that the loader writes
// (docs/MODULE_CONTRACT.md, "A library as a module").
text_settings_load :: proc "contextless" (ctx: ^system.Context) -> (problems: Text_Settings_Problems, loaded: bool) {
	// The table of the blend once, at the start of the process, also with
	// no settings page: the draw records with alpha blend with it.
	if !text_state_started {
		graphics.text_state_start()
		text_state_started = true
	}
	if .Settings_Page not_in fixed_addresses.ranges_mapped(&ctx.values) || settings_page != nil {
		return {}, false
	}
	settings_page = (^settings.Page)(uintptr(settings.PAGE_ADDRESS))
	// The outlines first: the faces of the glyph caches below are found
	// by the hash of their font files.
	problems.outlines, problems.fonts_missing = fallback_load(ctx)
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
// is absent or refused, with a line on the log: the process then draws its
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
			// A process that its starter gave no interface font: its
			// elements draw in the font of the cells, with no line on the log.
			return {}, false
		}
		if problem.kind != .None {
			system.log_in("processes", .Warning, "display: the glyph cache of the interface font is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value)
			return {}, false
		}
	}
	return {regular = caches[0], bold = caches[1]}, true
}

// The interface font of this process, validated once by open: the elements
// of src/library/support/interface draw their names, titles and labels in it
// (docs/FONTS.md, section 12.6). Absent: they draw in the font of the
// cells.
process_interface_font: Interface_Font
process_interface_font_given: bool

// interface_font_load validates the interface font of this process once:
// open calls it, and the compositor, which draws with no window of its own.
interface_font_load :: proc "contextless" (ctx: ^system.Context) {
	if !process_interface_font_given {
		process_interface_font, process_interface_font_given = interface_font_open(ctx)
	}
}

// interface_font_of gives the interface font of this process, or nil.
interface_font_of :: proc "contextless" () -> ^Interface_Font {
	return process_interface_font_given ? &process_interface_font : nil
}

// appearance_apply gives the appearance in force of the settings page to
// src/library/support/graphics. It gives true when the appearance changed:
// the caller then draws its whole window, so that no picture shows two
// appearances. With no page the process keeps the dark appearance.
appearance_apply :: proc "contextless" () -> (changed: bool) {
	if settings_page == nil {
		return false
	}
	// A refused page gives the defaults: the process draws with them, as
	// with a page that never stays stable.
	choice, _ := settings.read(settings_page)
	return appearance_of_choice_use(choice)
}

// appearance_of_choice_use makes the appearance in force of a choice the
// appearance of the graphics package, and gives true when it changed.
@(private)
appearance_of_choice_use :: proc "contextless" (choice: settings.Choice) -> bool {
	wanted := choice.appearance_in_force == .Light ? graphics.Appearance.Light : graphics.Appearance.Dark
	if wanted == graphics.appearance {
		return false
	}
	graphics.appearance_use(wanted)
	return true
}

// text_settings_apply gives the choice of the settings page to
// src/library/support/graphics: the font, the order of the stripes, the
// glyph cache of the grid fit, and the appearance in force. The private
// glyph cache keeps its glyphs: its key holds the grid fit and the scale,
// and its words do not depend on the order of the stripes.
text_settings_apply :: proc "contextless" () {
	if settings_page == nil {
		return
	}
	// A refused page gives the defaults: the process draws with them, as
	// with a page that never stays stable.
	choice, _ := settings.read(settings_page)
	_ = appearance_of_choice_use(choice)
	grid_fit := choice.grid_fit
	font := choice.font == .Spleen ? graphics.Text_Font.Spleen : graphics.Text_Font.Vector
	if glyph_cache_valid[grid_fit] {
		graphics.text_cache_use(glyph_caches[grid_fit])
	} else {
		font = .Spleen
	}
	order: graphics.Subpixel_Order
	switch choice.subpixel_order {
	case .Red_Green_Blue:
		order = .Red_Green_Blue
	case .Blue_Green_Red:
		order = .Blue_Green_Red
	case .None:
		order = .None
	}
	graphics.text_choice_set(font, order)
}
