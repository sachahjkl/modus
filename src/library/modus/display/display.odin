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
// `Control` and `Input`), and `src/library/modus/interface`, which draws with it. It
// also loads the text settings of the process: the font outlines, their
// faces and the setting of the font (`text_settings_open`,
// `interface_font_open`).
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
import "modus:graphics"
import "modus:contract/ring"
import "modus:key_path"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import op "modus:contract/operation"
import "modus:text_rendering"
import "modus:contract/pointer_pictures"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:contract/text_encoding"
import "modus:system"

// A command of a process to the compositor, on the ring of its window.
Command :: enum u32 {
	None           = 0, // Not a command.
	// The first surface of the window. values: the handle of a budget that pays the surface alone (in the
	// compositor, given with Spend and Read: surface_budget_pages) with the word of the scale of the surface
	// above its 32 bits (SURFACE_CREATE_SCALE_SHIFT), the logical width, the logical height, title (4
	// values). The compositor makes the surface with the budget and answers with Surface_Answer,
	// Create_Taken and the copy of the surface for this process, or Create_Refused. Its surface serial is 1.
	Surface_Create = 1,
	// The pixels of the surface changed. values: the picture to show (0 or
	// 1), then the rectangle that changed: x, y, width, height (width 0: the
	// whole surface), then at PRESENT_KEY_SERIAL the serial of the newest
	// key that the picture shows, or 0 (key_shown), then at
	// PRESENT_SURFACE_SERIAL the surface serial of the picture: the
	// compositor refuses a Present of a surface that it does not hold.
	Present        = 2,
	Pointer_Shape  = 3, // The pointer shape over this surface (docs/POINTERS.md). values: a number of pointer_pictures.Pointer_Shape
	// The act names of the window: what its elements act on, so that the
	// palette offers to go there (docs/INTERFACE.md, "4.2 Act names").
	// values[0]: the count, 0 to ACT_NAME_SET_CAPACITY; values[1..]: the
	// act_name_hash of each act name, two in each value, the first in the
	// low 32 bits (act_names_of_values). The set replaces the set before.
	// The window layer sends it when the set of a frame changes
	// (act_names_send).
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
	// answer for each event, and refuses any other. values: the handle of a
	// budget that pays the surface alone (in the compositor), width, height
	// in pixels of the screen at the scale of the surface shown, the next
	// surface serial (surface_resize). The compositor makes the surface with
	// the budget and answers with Surface_Answer, Resize_Taken and the copy
	// of the surface for this process, or Resize_Refused; the window keeps
	// the surface before it until then.
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
	// The capture face and the input face (src/md/features/remote_display.md):
	// the compositor takes them only from a client whose Client_Add holds
	// CLIENT_CAPTURE, and counts and drops them from any other.
	// The size of the screen: the compositor answers with the event
	// Capture_Size. No values.
	Capture_Size_Ask = 12,
	// The memory of the copy of the screen: a header page (Capture_Header),
	// then two pictures of the size of the screen. values: the handle of a
	// budget that pays that memory alone (in the compositor, given with
	// Spend and Read: capture_budget_pages), width, height. The compositor
	// makes the memory with it, so it never writes into memory that a
	// client made, and answers with the event Capture_Opened.
	Capture_Open     = 13,
	// The process copied the picture of the last Capture_Frame, and the
	// compositor may write it again. values: the picture.
	Capture_Taken    = 14,
	// The end of the copy: the compositor unmaps the memory. No values.
	Capture_Close    = 15,
	// The viewers that the bar names in its mark, in parts of
	// CAPTURE_VIEWER_KEYS_OF_A_PART keys: values[0]: the count, 0 to
	// CAPTURE_VIEWER_CAPACITY; values[1]: bit n when viewer n has the
	// input; values[2]: the place of the first key of this part, a
	// multiple of CAPTURE_VIEWER_KEYS_OF_A_PART; values[3..6]: the first 8
	// bytes of the key of each viewer of the part. The parts go in order,
	// and the last one names the last viewer (capture_viewers_part_check).
	Capture_Viewers  = 16,
	// A key of a viewer, in the form of the input record Key: code,
	// character, 1 when pressed, modifiers; values[4] viewer slot,
	// values[5] viewer input serial, values[6] viewer generation.
	Remote_Key       = 17,
	// The pointer of a viewer at a place of the screen: x, y, buttons,
	// wheel notches (signed); values[4] viewer slot, values[5] viewer
	// input serial, values[6] viewer generation.
	Remote_Pointer   = 18,
	// The surface of the window at a new scale, after the compositor
	// released the old one (src/md/features/window_resize.md, "The
	// rescale: one state machine on each side"): the same logical size,
	// its pixels of the screen at the scale. The compositor answers with
	// Surface_Answer, Rescale_Taken and the copy of the surface that it made
	// for this process, or Rescale_Refused, and shows a taken surface from
	// the first Present of its serial. values: the handle of a budget that
	// pays the surface alone (in the compositor), the width and the height
	// in pixels of the screen, the word of the scale, the surface serial.
	Surface_Rescale  = 19,
	// The window lets its surface of a serial go: the compositor unmaps
	// it, shown or pending, ends a request of the principal, draws the
	// frame of the window with the background, and answers with
	// Surface_Answer, Released. values: the surface serial, then the width
	// and the height of the view that the window holds, the size of the
	// surface that it offers next: a release answers a clamp only when that
	// view is the asked size (src/md/features/window_resize.md).
	Surface_Release  = 20,
	// The budget of the window could not pay its surface at the scale of
	// the compositor, after its release: the window declines that scale and
	// draws nothing. The compositor draws the frame with the background,
	// counts the window among those that declined the scale in force, and
	// names the count in Settings_Changed; it sends no answer. The window
	// offers the next serial at the next scale. values: the serial of the
	// offer, one past the serial released, and the word of the scale.
	Surface_Declined = 21,
	// The capture face: a size of a screen of memory that a viewer with the
	// input asked (src/md/features/screen_of_memory.md). The compositor
	// answers with the event Capture_Size: the new size, or with values[2]
	// the cause of its refusal. values: width, height.
	Screen_Size_Set  = 22,
}

// The place of the capture flag in the values of Client_Add.
CLIENT_ADD_CAPTURE :: 5
// The flag of a client that holds the start grant Screen_Capture. A flag,
// not a choice: 0 says the opposite.
CLIENT_CAPTURE :: 1
// The place of the flag of a window that takes the keys of the input
// service only, in the values of Client_Add: the window of `unlock` that
// proves a principal for a wide grant (src/md/features/wide_grants.md, "The
// deliberate act: the proof of the principal"). No key and no pointer of the
// remote display reaches it.
CLIENT_ADD_LOCAL_INPUT_ONLY :: 6
CLIENT_LOCAL_INPUT_ONLY :: 1

// The viewers of the capture face: each viewer that the service of the
// remote display holds has its place here, by the place of its record.
CAPTURE_VIEWER_CAPACITY :: 8
// The keys of one part of Capture_Viewers: the values after the count, the
// mask of the input and the place.
CAPTURE_VIEWER_KEYS_OF_A_PART :: 4
// The mask of the input of the viewers fits one word of a record, and the
// bit of each viewer of a warp fits a u32.
#assert(CAPTURE_VIEWER_CAPACITY <= 32)

// capture_viewers_part_check is the border of a part of Capture_Viewers:
// it refuses a count past CAPTURE_VIEWER_CAPACITY, a bit of the input past
// the count, and a place that is not a multiple of
// CAPTURE_VIEWER_KEYS_OF_A_PART, or that is past the count (the place 0 of
// a count of 0 passes: it names no viewer). last is true for the part
// that names the last viewer.
capture_viewers_part_check :: proc "contextless" (values: [7]u64) -> (count: int, input: u64, place: int, last: bool, ok: bool) {
	if values[0] > CAPTURE_VIEWER_CAPACITY || values[2] % CAPTURE_VIEWER_KEYS_OF_A_PART != 0 {
		return 0, 0, 0, false, false
	}
	if values[2] != 0 && values[2] >= values[0] {
		return 0, 0, 0, false, false
	}
	if values[1] >> values[0] != 0 {
		return 0, 0, 0, false, false
	}
	count, input, place = int(values[0]), values[1], int(values[2])
	return count, input, place, place + CAPTURE_VIEWER_KEYS_OF_A_PART >= count, true
}

// capture_viewers_parts writes the records of Capture_Viewers for the keys
// heads of the viewers and the mask of their input, and gives their count:
// one part for each CAPTURE_VIEWER_KEYS_OF_A_PART keys, and one part for no
// viewer. A count past CAPTURE_VIEWER_CAPACITY is cut to it.
capture_viewers_parts :: proc "contextless" (keys: []u64, input: u64, parts: ^[CAPTURE_VIEWER_CAPACITY / CAPTURE_VIEWER_KEYS_OF_A_PART]ring.Record) -> (part_count: int) {
	count := min(len(keys), CAPTURE_VIEWER_CAPACITY)
	mask := count == 0 ? 0 : input & ((u64(1) << u64(count)) - 1)
	for place := 0; place == 0 || place < count; place += CAPTURE_VIEWER_KEYS_OF_A_PART {
		record := ring.Record{kind = u32(Command.Capture_Viewers), values = {0 = u64(count), 1 = mask, 2 = u64(place)}}
		for index in place ..< min(place + CAPTURE_VIEWER_KEYS_OF_A_PART, count) {
			record.values[3 + index - place] = keys[index]
		}
		parts[part_count] = record
		part_count += 1
	}
	return part_count
}
// The rectangles of one record of a picture: the damage of the compositor.
CAPTURE_RECTANGLE_CAPACITY :: 8
// The pages of the header of the memory of a copy of the screen.
CAPTURE_HEADER_PAGES :: 1

// What the compositor writes for one picture before its Capture_Frame: the
// serial of the record, the rectangles that changed since the record
// before, and the pointer. The process copies it before it checks it.
Capture_Picture_Header :: struct {
	serial:                        u64,
	count:                         u64, // The rectangles, at most CAPTURE_RECTANGLE_CAPACITY.
	rectangles:                    [CAPTURE_RECTANGLE_CAPACITY][4]u32, // left, top, right, bottom; right and bottom are not in the rectangle.
	// The place of the pointer, and the rectangle that its picture covers on
	// the screen: four zeros when the pointer is not drawn.
	pointer_x, pointer_y:          u32,
	pointer_left, pointer_top:     u32,
	pointer_right, pointer_bottom: u32,
	// The pointer shape, form, size in pixels, hot spot, and a per-viewer
	// bitmask (bit n set when the pointer moved without a Remote_Pointer of
	// viewer slot n since the picture before).
	pointer_shape:                 u32,
	pointer_form:                  u32,
	pointer_size:                  u32,
	pointer_hot_spot_x:            u32,
	pointer_hot_spot_y:            u32,
	pointer_warped_mask:           u32,
	// For each viewer slot: the generation and monotonic count of applied
	// Remote_Key and Remote_Pointer records included in this captured frame.
	viewer_input_generation:       [CAPTURE_VIEWER_CAPACITY]u64,
	viewer_input_echo:             [CAPTURE_VIEWER_CAPACITY]u64,
}

Capture_Header :: struct {
	pictures: [PICTURE_COUNT]Capture_Picture_Header,
}
#assert(size_of(Capture_Header) <= CAPTURE_HEADER_PAGES * 4096)

// capture_pages gives the pages of the memory of a copy of a screen.
capture_pages :: proc "contextless" (width, height: int) -> u64 {
	return CAPTURE_HEADER_PAGES + (u64(PICTURE_COUNT * width * height * size_of(graphics.Color)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
}

// capture_budget_pages gives the pages of a budget that pays the memory of
// the capture face of a screen: its pages and its frame list, which the
// client gives the compositor with Capture_Open.
capture_budget_pages :: proc "contextless" (width, height: int) -> u64 {
	pages := capture_pages(width, height)
	return pages + op.memory_list_pages(pages)
}

// The kind of a content of the clipboard. A word of a record becomes a
// member at one place only (clipboard_kind_of_word).
Clipboard_Kind :: enum u32 {
	None = 0, // No content.
	Text = 1, // UTF-8 with no control character, or with LF line ends and tabs for multi-line text.
}

// Which action of Copy_Asked the principal asked for: Control+C copies,
// Control+X cuts (copies and removes the selection when the copy succeeds).
// A word of a record becomes a member at copy_action_of_word only.
Copy_Action :: enum u64 {
	Copy = 0, // Control+C.
	Cut  = 1, // Control+X.
}

// Whether a clipboard text border takes line ends and tabs or refuses them:
// single-line fields (the console, a text input) refuse them so a paste
// never runs a line; multi-line editors take LF and tab while still
// refusing CR, NUL and every other control character.
Clipboard_Text_Form :: enum u8 {
	Single_Line = 0, // No control character at all (text_encoding.text_valid).
	Multi_Line  = 1, // LF ('\n') and tab ('\t') allowed; CR, NUL and all other controls refused.
}

// The most bytes of a text on the clipboard: one memory object, which the
// process that copies makes with its own budget (src/md/features/clipboard.md,
// "The size of a content"). The budget of the copier and the room of the
// reader bound a content; this bound only keeps a count word inside one
// object.
CLIPBOARD_TEXT_LIMIT :: op.MEMORY_PAGE_LIMIT * system.PAGE_SIZE

// clipboard_kind_of_word is the border of the kind of a content: the
// member, or false for a word that names no member, None included.
clipboard_kind_of_word :: proc "contextless" (word: u64) -> (kind: Clipboard_Kind, ok: bool) {
	member := enum_word.member_of_word(Clipboard_Kind, word) or_return
	return member, member != .None
}

// copy_action_of_word is the border of values[1] of Copy_Asked: the member,
// or false for a word that names no member.
copy_action_of_word :: proc "contextless" (word: u64) -> (action: Copy_Action, ok: bool) {
	return enum_word.member_of_word(Copy_Action, word)
}

// The rule that a text to copy, or the copy of a paste, breaks. None: it
// holds.
Clipboard_Problem :: enum {
	None,
	Not_Asked, // No Copy_Asked waits for an answer.
	Empty, // No byte.
	Too_Large, // Past CLIPBOARD_TEXT_LIMIT, or past the room of the field that pastes.
	Not_Text, // A byte that starts no well-formed sequence of UTF-8, or a control character.
	Hidden_Character, // A character that a reader does not see, or that changes the order of the text (text_encoding.character_hidden).
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

// clipboard_text_valid checks that bytes are well-formed UTF-8 with no
// control characters (Single_Line) or with LF and tab allowed (Multi_Line).
// CR, NUL, every other C0/C1 control and invalid UTF-8 are always refused.
clipboard_text_valid :: proc "contextless" (text: []u8, form: Clipboard_Text_Form = .Multi_Line) -> bool {
	switch form {
	case .Single_Line:
		return text_encoding.text_valid(text)
	case .Multi_Line:
		for place := 0; place < len(text); {
			if text[place] == '\n' || text[place] == '\t' {
				place += 1
				continue
			}
			_, length, valid := text_encoding.character_decode(text, place)
			if !valid {
				return false
			}
			place += length
		}
		return true
	}
	return false
}

// clipboard_text_problem checks a text at a border of the clipboard: the
// text to copy before it is made, and the copy of a paste after it is
// copied. room is the most bytes that the place takes. form chooses
// whether LF line ends and tabs are taken (Multi_Line) or refused
// (Single_Line). It reads and changes no state, so a host test gives it
// each refused text.
clipboard_text_problem :: proc "contextless" (text: []u8, room: int, form: Clipboard_Text_Form = .Multi_Line) -> Clipboard_Problem {
	switch {
	case len(text) == 0:
		return .Empty
	case len(text) > CLIPBOARD_TEXT_LIMIT || len(text) > room:
		return .Too_Large
	case !clipboard_text_valid(text, form):
		return .Not_Text
	}
	for place := 0; place < len(text); {
		if form == .Multi_Line && (text[place] == '\n' || text[place] == '\t') {
			place += 1
			continue
		}
		character, length, _ := text_encoding.character_decode(text, place)
		if length == 0 {
			break
		}
		// A pasted text with a hidden character could show as another text,
		// in a line of the console that the principal then runs.
		if text_encoding.character_hidden(character) {
			return .Hidden_Character
		}
		place += length
	}
	return .None
}

// The act names of one window: two hashes in each of the 6 values of one
// record after its count. The settings window names one act for each
// setting of the settings page, which has room for 8.
ACT_NAME_SET_CAPACITY :: 12
ACT_NAME_CAPACITY :: 32 // The bytes of an act name: "settings.set:font".
#assert(ACT_NAME_SET_CAPACITY == 2 * (len(ring.Record{}.values) - 1))

// act_name_hash gives the hash of an act name: the 32-bit FNV-1a hash of
// its bytes, never 0. A record of a ring holds 7 values, so a set of act
// names travels as hashes, two in a value; the palette hashes the act name
// of an entry the same way. Two names with one hash only make the palette
// offer a go to that finds no element.
act_name_hash :: proc "contextless" (name: string) -> u32 {
	hash: u32 = 0x811C_9DC5
	for index in 0 ..< len(name) {
		hash = (hash ~ u32(name[index])) * 0x0100_0193
	}
	return hash | 1
}

// act_names_values gives the values of a record Act_Names for a set of
// hashes: the count, then two hashes in each value, the first in the low
// 32 bits. A set past ACT_NAME_SET_CAPACITY gives its first hashes.
act_names_values :: proc "contextless" (hashes: []u32) -> (values: [7]u64) {
	count := min(len(hashes), ACT_NAME_SET_CAPACITY)
	values[0] = u64(count)
	for hash, index in hashes[:count] {
		values[1 + index / 2] |= u64(hash) << (32 * uint(index % 2))
	}
	return values
}

// act_names_of_values is the border of a record Act_Names: the values are
// those of another process. A count past ACT_NAME_SET_CAPACITY, a hash of 0
// in the count and a hash that is not 0 after it are refused, and ok is
// false.
act_names_of_values :: proc "contextless" (values: [7]u64) -> (hashes: [ACT_NAME_SET_CAPACITY]u32, count: int, ok: bool) {
	if values[0] > ACT_NAME_SET_CAPACITY {
		return {}, 0, false
	}
	count = int(values[0])
	for index in 0 ..< ACT_NAME_SET_CAPACITY {
		hash := u32(values[1 + index / 2] >> (32 * uint(index % 2)))
		if index < count && hash == 0 || index >= count && hash != 0 {
			return {}, 0, false
		}
		hashes[index] = hash
	}
	return hashes, count, true
}

// act_names_send gives the compositor the set of the act names of the
// window. It gives false when the command ring was full: the compositor has
// the set before, and the caller sends it again later.
act_names_send :: proc "contextless" (window: ^Window, hashes: []u32) -> bool {
	return system.send(&window.ring.commands, ring.Record{kind = u32(Command.Act_Names), values = act_names_values(hashes)})
}

// What the compositor tells a process, as the kind of a completion record of
// its ring, and as the kind of an `Event`.
Event_Kind :: enum u32 {
	None             = 0, // No event.
	Key              = 1, // values: code, character, 1 when pressed, modifiers, then at KEY_EVENT_SERIAL the serial of the key (0: the compositor does not measure it)
	Pointer          = 2, // values: x, y in the surface (signed), buttons, wheel notches (signed: WHEEL_TOWARD_THE_END for each notch toward the end of the content)
	// The settings of the owner changed (modus:contract/settings): next_event
	// already gave the new font to src/library/modus/graphics; the process draws its
	// window again. values: the change count of the settings page, the word
	// of the scale of the compositor, to which the window rescales, and the
	// count of the windows that declined that scale (Surface_Declined), up
	// to WINDOWS_DECLINED_LIMIT.
	Settings_Changed = 3,
	// The palette goes to an element of this window: the compositor raised
	// it. values[0]: the act_name_hash of the act name. The window layer
	// puts the focus on the element that names it
	// (src/library/modus/interface, window_events).
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
	// The capture face (Command.Capture_Size_Ask, Screen_Size_Set): the size
	// of the screen. values: width, height, and 0, or the cause
	// (memory_screen.Resize_Refusal) of a refused Screen_Size_Set with the
	// size that it asked. The compositor sends it again after a change of
	// the size of a screen of memory. Only a client of the capture face gets
	// it; a window refuses it (event_of_record).
	Capture_Size     = 8,
	// The capture face: the compositor wrote a picture and its header.
	// values: the picture, the count of its rectangles, the serial of the
	// record. A window refuses it (event_of_record).
	Capture_Frame    = 9,
	// The answer of the compositor to Surface_Release, Surface_Rescale or
	// Surface_Resize
	// (Surface_Answer_Kind). next_event takes it into the rescale of the
	// window first. values: the word of the answer, the surface serial.
	Surface_Answer     = 10,
	// The capture face: the principal clicked disconnect for one viewer in
	// the bar viewer list popover. values[0]: the first 8 bytes of that
	// viewer's public key (matching Capture_Viewers). A window refuses it.
	Capture_Disconnect = 11,
	// The work area of the window: the logical width and height of the
	// screen that the holder of the display gives windows, without the
	// parts that it draws itself (a bar, a panel). The holder sends it when
	// it takes the surface of the window, and again when the area changes.
	// A window sizes itself from it, never from the bar of one holder.
	// values: the width, the height, each 1 to WORK_AREA_LIMIT.
	Work_Area          = 12,
	// The capture face: the answer of the compositor to Capture_Open. It made
	// the memory of the copy of the screen with the budget that the client
	// gave, and gives the client a copy with Read. values: that copy, as the
	// client names it, or 0 when the compositor refused the budget. A window
	// refuses it.
	Capture_Opened     = 13,
}

// The largest width and height of a work area, in logical pixels: a place
// of the screen fits an i32 with room.
WORK_AREA_LIMIT :: 1 << 15

// The ring between the root service and the compositor.
Control :: enum u32 {
	None          = 0, // Not a command.
	// root to compositor. values: ring memory handle (in the compositor). For
	// a disk process, values 1 to 3 hold its nickname, as the root ring
	// carries a name of 23 bytes, and value 4 the first 8 bytes of the hash
	// of its file (modus:contract/disk_process_page, hash_head); for a
	// process of the boot image, values 1 to 3 hold the name of its module
	// in the same form, and value 4 is 0. Value CLIENT_ADD_CAPTURE is
	// CLIENT_CAPTURE for a process with the start grant Screen_Capture.
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
	// compositor to root: the tile Appearance of the Control Center was
	// pressed. The root service decides (settings.start_answer): it starts
	// `settings` for the pass of the next appearance, or sends
	// Settings_Raise for the window of `settings` that runs, or refuses
	// while a pass runs. No values.
	Appearance_Next         = 8,
	// root to compositor: the answer to a start of `settings` or to
	// Appearance_Next while a window of `settings` runs: one process is the
	// one writer of the settings page. values: the handle of Client_Add of
	// that window, then a Settings_Raise_Focus. The root service names the
	// window by the process that it started, so no other window can take it.
	Settings_Raise          = 9,
	// root to compositor: the extra budget of a growth of the screen of
	// memory (src/md/features/screen_of_memory.md, "The growth of the
	// budgets"). values: the handle (in the compositor) with Read and Spend,
	// its pages, the width and the height that it pays, the number of its
	// growth.
	Screen_Budget_Give      = 10,
	// compositor to root: the compositor closed its extra budget of a growth,
	// as no picture of it is left. values: the number of the growth.
	Screen_Budget_Release   = 11,
	// root to compositor: show the screen of a wide grant
	// (src/md/features/wide_grants.md, "The path of a grant, end to end").
	// values: wide_grants.screen_show_values.
	Wide_Grant_Screen_Show    = 12,
	// compositor to root: the answer of the principal on that screen.
	// values: wide_grants.screen_answer_values.
	Wide_Grant_Screen_Answer  = 13,
	// root to compositor: the mark of a grant that holds, or its end with
	// a grant serial of 0. values: wide_grants.mark_values.
	Wide_Grant_Mark           = 14,
	// compositor to root: the principal pressed revoke on the mark, with
	// the keys or the pointer of the input service. values[0]: the grant
	// serial of the mark.
	Wide_Grant_Revoke_Pressed = 15,
}

// Where the focus goes in the window that Settings_Raise raises. The values
// cross the ring, so they are stated; settings_raise_focus_of_word is their
// border.
Settings_Raise_Focus :: enum u64 {
	Keep       = 0, // A start of the window: the focus stays where it was.
	Appearance = 1, // The tile Appearance: the focus on the appearance in force.
}

// settings_raise_focus_of_word is the border of the second word of
// Settings_Raise: a word that names no member is refused.
settings_raise_focus_of_word :: proc "contextless" (word: u64) -> (focus: Settings_Raise_Focus, ok: bool) {
	return enum_word.member_of_word(Settings_Raise_Focus, word)
}

// The ring from the input service to the compositor.
Input :: enum u32 {
	None             = 0, // Not a command.
	Key              = 1, // values: code, character (a code point, or 0), 1 when pressed, modifiers, then at INPUT_KEY_READ_AT the time of the system, in nanoseconds, when the input service read the key
	Pointer          = 2, // values: x motion, y motion (signed), buttons, wheel notches (signed)
	Pointer_Absolute = 3, // values: x in [0..width-1], y in [0..height-1], buttons, wheel notches (signed), width (> 0), height (> 0)
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
KEY_SPACE :: 0x39 // Space.
KEY_F3 :: 0x3D // F3.
KEY_F7 :: 0x41 // F7: with Control and Shift, the compositor moves the window in front by keys.
KEY_F8 :: 0x42 // F8: with Control and Shift, the compositor resizes the window in front by keys.
KEY_F10 :: 0x44 // F10: with Control and Shift, the bar of the desktop takes the focus of the keys.
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
MODIFIER_ALT :: 4 // The bit set while the left Alt key is down. The right Alt key is AltGr: it changes the character, and sets no bit.

BUTTON_LEFT :: 1 // The bit of `Event.buttons` set while the left button is down.
BUTTON_RIGHT :: 2 // The bit set while the right button is down.

// The largest logical width and height of a surface: a window as wide as a
// screen of 8K at the scale 1. It is a bound of the words of the ring; the
// holder of the display bounds each surface by the screen in force too,
// and the budget of the window pays its pixels.
SURFACE_LIMIT :: 8192

// The most windows that a Settings_Changed counts as declining the scale:
// more than a compositor holds, so a larger word is no count.
WINDOWS_DECLINED_LIMIT :: 64

// The windows that declined the scale in force, as the newest
// Settings_Changed of the compositor named them: the window of settings
// shows a notice while it is not 0.
windows_declined_scale: int

// windows_that_declined_the_scale gives the windows that declined the scale
// in force: their budget does not pay a surface at it.
windows_that_declined_the_scale :: proc "contextless" () -> int {
	return windows_declined_scale
}

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

// layout_size_of gives the layout of a window from its view, the logical
// size of its surface: a fixed window lays out at the size that it opened
// with; a resizable one at the larger of the view and its least size. So a
// clamp of the compositor to the work area never breaks a layout: the window
// layer of the interface package scrolls it in the view
// (src/md/features/window_scroll.md).
layout_size_of :: proc "contextless" (view_width, view_height: int, resizable: bool, limits: Size_Limits, opened_width, opened_height: int) -> (width, height: int) {
	if !resizable {
		return opened_width, opened_height
	}
	return max(view_width, limits.least_width), max(view_height, limits.least_height)
}

// view_size gives the logical size of the surface of a window: its view,
// or its layout for a window in plain memory that has no view.
view_size :: proc "contextless" (window: ^Window) -> (width, height: int) {
	if window.view_width <= 0 || window.view_height <= 0 {
		return window.width, window.height
	}
	return window.view_width, window.view_height
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
	x, y:      int, // The pointer: its place in the surface, in logical pixels; it can be outside the surface.
	buttons:   u32, // The pointer: the `BUTTON_` bits.
	wheel:     int, // The pointer: the notches that the wheel turned since the event before, signed (WHEEL_TOWARD_THE_END).
	act:       u32, // Go_To: the act_name_hash of the act name.
	width, height: int, // Resized: the size that the principal asks for the window, in logical pixels, 1 to SURFACE_LIMIT. Work_Area: the work area, 1 to WORK_AREA_LIMIT.
	paste_handle:   system.Handle, // Pasted: the lent handle of the content.
	clipboard_kind: Clipboard_Kind, // Pasted: the kind of the content, never None.
	byte_count:     int, // Pasted: the bytes of the content, 1 to CLIPBOARD_TEXT_LIMIT.
	clipboard_serial: u64, // Copy_Asked and Pasted: the serial of the key, never 0; the answer names it.
	copy_action:    Copy_Action, // Copy_Asked: Copy (Ctrl+C) or Cut (Ctrl+X).
	key_serial: u64, // A key: the serial that the compositor gave it, or 0. A process that shows the key names it (key_shown).
	scale: scale_factor.Scale, // Settings_Changed: the scale of the compositor.
	windows_declined: int, // Settings_Changed: the windows that declined that scale, 0 to WINDOWS_DECLINED_LIMIT.
	surface_answer: Surface_Answer_Kind, // Surface_Answer: the answer.
	surface_serial: u64, // Surface_Answer: the serial that it names.
	surface_memory: system.Handle, // Surface_Answer of a surface made (surface_answer_gives_surface): the copy for this process; else 0.
}

// One window of a process: its ring to the compositor and its surface.
// `open` makes it; the process draws in `canvas` and calls `present`.
Window :: struct {
	ring_memory: system.Handle, // The memory of the ring to the compositor.
	ring:        ring.Ring, // The ring, mapped.
	surface:     system.Handle, // The memory of the pixels of the surface; 0 while the rescale let it go.
	width, height: int, // The size of the window, in logical pixels: its layout, which the process lays out at.
	// The logical size of the surface: the layout, or less when the
	// compositor clamped the window to the work area; the window layer of
	// the interface package then scrolls the layout in it
	// (src/md/features/window_scroll.md).
	view_width, view_height: int,
	// The size that the window opened with: the layout of a fixed window.
	opened_width, opened_height: int,
	rescale:     Rescale_Machine, // The scale and the serial of the surface, and the phase of a change of the scale (scale.odin).
	rescale_due: Rescale_Action, // A record of the rescale that the full command ring did not take yet.
	// A Surface_Declined that the full command ring did not take yet, with
	// the serial and the scale of the offer that the budget did not pay. It
	// goes before the due action: a later offer names the serial after it.
	decline_due:    bool,
	decline_serial: u64,
	decline_scale:  scale_factor.Scale,
	asked_surface: Asked_Surface, // The surface that the window asked the compositor to make, until the answer (scale.odin).
	// The records that came before the answer of Surface_Create, while open
	// waited for it: next_event gives them first, in their order.
	early_records: [EARLY_RECORD_CAPACITY]Event_Record,
	early_first, early_count: int,
	early_records_dropped: u64, // The records past early_records: the compositor sends none (EARLY_RECORD_CAPACITY).
	presented_serial: u64, // The surface serial of the last Present: 0 before the first one (picture_owed).
	canvas:      graphics.Canvas, // Where the drawing module draws now, in pixels of the screen. A process that draws by hand draws in a logical picture of its own (interface.Hand_Picture).
	pictures:    [2]graphics.Canvas, // The two pictures of the surface, in pixels of the screen.
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
	// The last Work_Area of the holder of the display, in logical pixels:
	// 0 before the first one (work_area).
	work_area_width, work_area_height: int,
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
			system.log(.Info, "display: ", string(window.title[:window.title_count]), " drew one picture in ", mean / 1000, ".", mean / 100 % 10, " us, the mean of ", count)
		}
	}
	window.picture_started = 0
}

// open creates a surface of two pictures and shows it. width and height are
// logical pixels, from 1 to SURFACE_LIMIT: the surface has their pixels of
// the screen at the scale in force (scale.odin). The drawing module draws
// in window.canvas, then present changes window.canvas to the other
// picture. The compositor shows the surface after the first present.
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
	if window.ring, status = system.ring_open(window.ring_memory, error, receive_handles = true); status != .Ok {
		return {}, false
	}
	// The size is logical; the surface is in pixels of the screen, at the
	// scale in force (scale.odin).
	window.width, window.height = width, height
	window.view_width, window.view_height = width, height
	window.opened_width, window.opened_height = width, height
	scale := scale_in_force()
	window.rescale = {phase = .Steady, scale = scale, wanted = scale, serial = 1}
	screen_width, screen_height := surface_size_of(width, height, scale)
	window.title_count = copy(window.title[:], title)

	// The compositor maps the ring when the root service tells it of this
	// process. Until then, the grant has no receiver.
	granted: system.Handle
	// Bound the wait for the display holder to map this client's ring on a
	// loaded machine: succeeds on the first pass when the holder is ready.
	OPEN_RING_WAIT_ATTEMPTS :: 2000
	for attempt in 0 ..< OPEN_RING_WAIT_ATTEMPTS {
		// The compositor makes the surface with a budget of it (scale.odin).
		granted, status = surface_budget_give(&window, screen_width, screen_height, attempt == OPEN_RING_WAIT_ATTEMPTS - 1 ? error : nil)
		if status == .No_Budget || status == .Bad_Operation {
			break // The budget of this process does not pay the surface: no wait changes it.
		}
		if status == .Ok {
			break
		}
		system.sleep(system.time() + 5)
	}
	if status != .Ok {
		return {}, false
	}
	name := system.name_pack(title)
	// The logical size and the scale: the compositor computes the pixels of
	// the screen with the rule of each edge, and names its own scale to a
	// window whose scale is another.
	command := ring.Record {
		kind = u32(Command.Surface_Create),
		values = {u64(granted) | u64(scale) << SURFACE_CREATE_SCALE_SHIFT, u64(width), u64(height), name[0], name[1], name[2], name[3]},
	}
	// An answer of a surface that waits already is no answer of this
	// open: an open before it failed, and the compositor answered late.
	surface_answers_stale_close(&window)
	system.send(&window.ring.commands, command)
	memory, outcome := surface_create_answer_wait(&window, system.time() + SURFACE_CREATE_ANSWER_DEADLINE_MILLISECONDS)
	mapped := outcome == .Taken && surface_answer_map(&window, memory, screen_width, screen_height)
	if !mapped {
		// The compositor may hold a window for this record (a late answer,
		// a surface that did not map): the release of serial 1 before any
		// Present ends it there, so a failed open leaves no window behind.
		if outcome != .Refused {
			system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Release), values = {0 = 1}})
		}
		system.ring_close(&window.ring)
		errors.fail(error, 0, .Refused, .None, 0, i64(outcome))
		return {}, false
	}
	return window, true
}

// What the wait of open for the answer of Surface_Create found.
Create_Outcome :: enum u8 {
	Taken, // Create_Taken: the compositor made the surface.
	Refused, // Create_Refused: the compositor holds nothing.
	Late, // No answer before the deadline.
}

// surface_answer_close closes the copy of a surface that an answer names
// when it answers no request of the window: an answer that came late, or
// of another serial. A number that came through no gift of the ring is no
// handle of the window to close.
@(private)
surface_answer_close :: proc "contextless" (window: ^Window, memory: system.Handle) {
	if memory == 0 {
		return
	}
	if _, _, through := system.handle_state(memory, window.ring_memory); through {
		system.close(memory)
	}
}

// surface_answers_stale_close reads the records that wait before open sends
// Surface_Create: an answer of a surface among them answers an open before
// it, and its surface is closed; each other record is kept in order.
@(private)
surface_answers_stale_close :: proc "contextless" (window: ^Window) {
	for record in system.receive(&window.ring.completions) {
		if event, ok := event_of_record(record); ok && event.kind == .Surface_Answer {
			surface_answer_close(window, event.surface_memory)
			continue
		}
		early_record_keep(window, record)
	}
}

// early_record_keep keeps a record that came before the answer of
// Surface_Create, for next_event. A record past EARLY_RECORD_CAPACITY,
// which the rule of the answer slot of the compositor never sends, is
// counted, and the wait goes on.
@(private)
early_record_keep :: proc "contextless" (window: ^Window, record: Event_Record) {
	if window.early_count == EARLY_RECORD_CAPACITY {
		window.early_records_dropped += 1
		return
	}
	window.early_records[(window.early_first + window.early_count) % EARLY_RECORD_CAPACITY] = record
	window.early_count += 1
}

// surface_create_answer_wait waits for the answer of Surface_Create, until
// deadline, and gives the copy of the surface that the compositor made.
// Each other record that comes first is kept in order (early_record_keep),
// which next_event gives first, so no event of a new window is lost; the
// wait ends only at the answer or at the deadline.
@(private)
surface_create_answer_wait :: proc "contextless" (window: ^Window, deadline: u64) -> (memory: system.Handle, outcome: Create_Outcome) {
	defer if window.early_records_dropped > 0 {
		system.log(.Warning, "display: ", string(window.title[:window.title_count]), ": ", window.early_records_dropped, " records came before the answer of the compositor, past the records that the window keeps: they are lost")
	}
	for {
		record, received := system.receive(&window.ring.completions)
		if !received {
			if system.time() >= deadline {
				return 0, .Late
			}
			list: system.Wait
			system.wait_records(&list, &window.ring.completions)
			system.wait_end(&list, deadline)
			continue
		}
		event, read_ok := event_of_record(record)
		if read_ok && event.kind == .Surface_Answer {
			switch event.surface_answer {
			case .Create_Taken:
				if event.surface_serial == 1 {
					return event.surface_memory, .Taken
				}
			case .Create_Refused:
				if event.surface_serial == 1 {
					return 0, .Refused
				}
			case .Released, .Rescale_Taken, .Rescale_Refused, .Resize_Taken, .Resize_Refused:
				// A window with no surface made no request that these answer.
			}
			surface_answer_close(window, event.surface_memory)
			continue
		}
		early_record_keep(window, record)
	}
}

// The names of the arguments of open, for the sentence of a record that
// open wrote: system.wrapper_error_text(writer, &error, "display.open", display.OPEN_ARGUMENTS[:]).
@(rodata)
OPEN_ARGUMENTS := [?]string{"ctx", "width", "height", "title"}

// The pictures of a surface: the one that the compositor reads and the one
// that the process draws. The compositor refuses a surface with less
// memory.
PICTURE_COUNT :: 2

// The records that open keeps while it waits for the answer of
// Surface_Create. The compositor sends an answer of a surface to the ring,
// or to the one answer slot of the window, which goes before each other
// waiting event when the ring has room (bar.Answer_Slot): so no more
// records than the ring holds come before the answer.
EARLY_RECORD_CAPACITY :: ring.CAPACITY

// A record of the ring of a window: the field ring of Window hides the
// package inside the record.
Event_Record :: ring.Record

// The deadline of the wait of open for the answer of Surface_Create: a
// deadline of the display contract, not a bound of a test. The compositor
// answers in its next turn; the deadline only ends the wait for a
// compositor that stopped.
SURFACE_CREATE_ANSWER_DEADLINE_MILLISECONDS :: 10_000

// surface_budget_pages gives the pages of a budget that pays the surface
// of a size in pixels of the screen: its two pictures, and the frame list
// of its memory object, which the budget pays too (op.memory_list_pages).
// A window gives the compositor a budget of these pages, and the
// compositor refuses one that holds fewer. A size past SURFACE_SCREEN_LIMIT
// on a side gives 0: no budget pays it.
surface_budget_pages :: proc "contextless" (screen_width, screen_height: u64) -> u64 {
	if screen_width == 0 || screen_height == 0 || screen_width > u64(SURFACE_SCREEN_LIMIT) || screen_height > u64(SURFACE_SCREEN_LIMIT) {
		return 0
	}
	bytes := screen_width * screen_height * size_of(graphics.Color) * PICTURE_COUNT
	pages := (bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	return pages + op.memory_list_pages(pages)
}

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
	// While the rescale let the surface go, the compositor holds no
	// surface that a Present could name (scale.odin).
	if !rescale_draws(&window.rescale) {
		return false
	}
	picture_end(window)
	// A picture ends a frame of the text of the process: a process that
	// draws its text by hand with src/library/modus/graphics calls no
	// other procedure at its frame, and its copy of the text rendering
	// gets its glyph memory here, after its first glyph. Without it, each
	// glyph of each frame would be drawn band by band.
	text_frame_begin()
	// The serial names the surface of the pictures: the compositor shows
	// no picture of a surface that it does not hold.
	record := ring.Record{kind = u32(Command.Present), values = {0 = u64(window.picture), 1 = u64(max(x, 0)), 2 = u64(max(y, 0)), 3 = u64(max(width, 0)), 4 = u64(max(height, 0)), PRESENT_KEY_SERIAL = window.key_shown_serial, PRESENT_SURFACE_SERIAL = window.rescale.serial}}
	if !system.send(&window.ring.commands, record) {
		return false
	}
	window.presented = window.ring.commands.counters.write
	window.presented_serial = window.rescale.serial
	window.picture = 1 - window.picture
	window.canvas = window.pictures[window.picture]
	// The compositor ends the due picture at the Present.
	window.picture_due_sent = false
	// The compositor shows the new surface from this Present: a machine
	// test waits for this line before a picture of the new size.
	if window.resized_picture_due {
		window.resized_picture_due = false
		system.log(.Info, "display: ", string(window.title[:window.title_count]), ": the first picture of ", u64(window.view_width), "x", u64(window.view_height), " after a resize")
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
	checked, refused := size_limits_of_words(words, window.width, window.height)
	if refused != .None {
		return refused, false
	}
	// Logical pixels, which mean the same at each scale: the unit of the
	// drag of the compositor.
	record := ring.Record{kind = u32(Command.Resizable), values = {0 = words[0], 1 = words[1], 2 = words[2], 3 = words[3]}}
	if !system.send(&window.ring.commands, record) {
		return .None, false
	}
	window.size_limits, window.resizable = checked, true
	// A clamp of the compositor can come before the limits: the layout of a
	// resizable window is then the view, or its least size.
	view_width, view_height := view_size(window)
	window.width, window.height = layout_size_of(view_width, view_height, true, checked, window.opened_width, window.opened_height)
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
// The size is the view: the surface. A resizable window takes a Resized
// below its least size: the compositor clamps the window to the work area,
// and the layout keeps its size (layout_size_of), which the window layer
// scrolls (src/md/features/window_scroll.md). A fixed window takes its
// clamp in next_event, by a release and an offer (clamp_take), never here.
//
// The statuses: Ok; Bad_Operation for a fixed window, with no Resized to answer, for another size than
// the asked one, or for a size past its largest limit (nothing changes); No_Slot when the command ring is
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
	case window.rescale.phase != .Steady:
		// A change of the scale goes on: the compositor holds no surface of
		// this window, or a pending one; the request waits for no answer.
		errors.fail(error, 0, .State, .None, 1)
		_ = resize_decline(window)
		return .Bad_Operation
	case !window.resize_asked || width != window.resize_asked_width || height != window.resize_asked_height:
		errors.fail(error, 0, .State, .None, 2, i64(width), i64(window.resize_asked_width), i64(height))
		return .Bad_Operation
	case window.resizable && (width < 1 || height < 1 || width > window.size_limits.largest_width || height > window.size_limits.largest_height):
		errors.fail(error, 0, .Out_Of_Range, .None, width < 1 || width > window.size_limits.largest_width ? 2 : 3, i64(width), i64(window.size_limits.largest_width), i64(height))
		return .Bad_Operation
	case ring.count(&window.ring.commands) == ring.capacity(&window.ring.commands):
		// The ring has one writer, this thread: the room seen here stays.
		// Without it, the handle given below would wait in the table of the
		// compositor with no record that names it.
		errors.fail(error, 0, .Full, .None, 0)
		return .No_Slot
	}
	// The new surface keeps the scale of the window, which is the scale of
	// the compositor in the phase Steady; it has the next serial.
	screen_width, screen_height := surface_size_of(width, height, window.rescale.scale)
	granted, status := surface_budget_give(window, screen_width, screen_height)
	if status != .Ok {
		errors.fail(error, 0, status == .No_Budget ? errors.Kind.Budget : errors.Kind.Refused, .None, 2, i64(screen_width), i64(screen_height))
		system.log(.Warning, "display: ", title, ": no surface of ", u64(width), "x", u64(height), " (", op.STATUS_NAMES[status], "): the window keeps ", u64(window.view_width), "x", u64(window.view_height))
		// A full ring keeps the request: the next present declines it.
		_ = resize_decline(window)
		return status
	}
	// The machine takes the next serial and waits for the answer, which
	// names the surface that the compositor made (rescale_take). The
	// surface before it stays the surface of the window until then: the
	// compositor shows it, and a refusal keeps it.
	_, _ = rescale_step(&window.rescale, {kind = .Resize_Offered})
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Resize), values = {0 = u64(granted), 1 = u64(screen_width), 2 = u64(screen_height), 3 = window.rescale.serial}})
	window.resize_asked = false
	layout_width, layout_height := layout_size_of(width, height, window.resizable, window.size_limits, window.opened_width, window.opened_height)
	window.asked_surface = {screen_width = screen_width, screen_height = screen_height, view_width = width, view_height = height, layout_width = layout_width, layout_height = layout_height}
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
	system.log(.Info, "display: ", string(window.title[:window.title_count]), ": the window keeps ", u64(window.view_width), "x", u64(window.view_height), ", not the asked ", u64(max(window.resize_asked_width, 0)), "x", u64(max(window.resize_asked_height, 0)))
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
	// While the rescale let the surface go, nothing is drawn: the answer of
	// the compositor is an event, which ends the wait of the process.
	if !rescale_draws(&window.rescale) {
		return false
	}
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
	if !rescale_draws(&window.rescale) {
		return false
	}
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
		system.log(.Warning, "display: ", string(window.title[:window.title_count]), ": the compositor did not take a picture in ", u64(CANVAS_WAIT_BOUND_MILLISECONDS), " ms: this window draws no picture until it does")
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
	// The records that open kept are events that wait already.
	if window.early_count > 0 {
		list.full = true
	}
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
	// A record of the rescale that a full ring did not take goes first.
	rescale_due_run(window)
	for {
		record: ring.Record
		if window.early_count > 0 {
			record = window.early_records[window.early_first]
			window.early_first = (window.early_first + 1) % EARLY_RECORD_CAPACITY
			window.early_count -= 1
		} else {
			record = system.receive(&window.ring.completions) or_return
		}
		read, read_ok := event_of_record(record)
		if !read_ok {
			system.log(.Warning, "display: ", string(window.title[:window.title_count]), ": the compositor sent a record of the kind ", u64(record.kind), ", which names no event or has a size out of its range: it is refused")
			continue
		}
		// The rescale takes the scale that the compositor names, and its
		// answers (scale.odin): the window never reads the scale of the
		// page for it.
		if read.kind == .Settings_Changed {
			_ = text_settings_apply()
			rescale_take(window, {kind = .Scale_Named, scale = read.scale})
			windows_declined_scale = read.windows_declined
		}
		if read.kind == .Surface_Answer {
			kind: Rescale_Input_Kind
			switch read.surface_answer {
			case .Create_Taken, .Create_Refused:
				// open took the answer of its Surface_Create: a second one
				// answers no request. A copy that it names is closed.
				surface_answer_close(window, read.surface_memory)
				continue
			case .Released:
				kind = .Released
			case .Rescale_Taken:
				kind = .Taken
			case .Rescale_Refused:
				kind = .Refused
			case .Resize_Taken:
				kind = .Resize_Taken
			case .Resize_Refused:
				kind = .Resize_Refused
			}
			rescale_take(window, {kind = kind, serial = read.surface_serial, memory = read.surface_memory})
		}
		if read.kind == .Resized {
			window.resize_asked = true
			window.resize_asked_width, window.resize_asked_height = read.width, read.height
			// A fixed window gets Resized only as a clamp of the compositor to
			// the work area: its layout keeps the size that it opened with, so
			// the answer needs no choice of the process, and a process whose
			// loop reads its events by itself takes the clamp too. It holds
			// one surface at a time (src/md/features/window_resize.md, "The
			// clamp of a fixed window").
			if !window.resizable {
				clamp_take(window, read.width, read.height)
			}
		}
		if read.kind == .Copy_Asked {
			// The newest request replaces the one before: the compositor
			// takes only an answer to it.
			window.copy_asked, window.copy_serial = true, read.clipboard_serial
		}
		if read.kind == .Work_Area && work_area_take(window, read.width, read.height) {
			system.log_fact(.Info, Window_Taken{width = u64(read.width), height = u64(read.height), window = window_fact_title(window)})
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
		// The scale of the compositor: a member of the range, never a word
		// that names no scale for a window to rescale to.
		scale, problem := scale_factor.scale_of_word(record.values[1])
		if problem != .None || record.values[2] > WINDOWS_DECLINED_LIMIT {
			return {}, false
		}
		event.scale = scale
		event.windows_declined = int(record.values[2])
	case .Surface_Answer:
		answer, answer_ok := surface_answer_of_word(record.values[0])
		if !answer_ok || record.values[1] == 0 {
			return {}, false
		}
		// The copy of a surface is a handle of 32 bits, in the answers that
		// give one only.
		memory := record.values[2]
		if surface_answer_gives_surface(answer) ? memory == 0 || memory > u64(max(u32)) : memory != 0 {
			return {}, false
		}
		event.surface_answer, event.surface_serial, event.surface_memory = answer, record.values[1], system.Handle(memory)
	case .Go_To:
		// A hash is 32 bits: a word past them names no act name.
		if record.values[0] > u64(max(u32)) {
			return {}, false
		}
		event.act = u32(record.values[0])
	case .Resized:
		// The words are read as words: one past the limit never becomes a
		// negative size.
		width, height := record.values[0], record.values[1]
		if width == 0 || height == 0 || width > SURFACE_LIMIT || height > SURFACE_LIMIT {
			return {}, false
		}
		event.width, event.height = int(width), int(height)
	case .Copy_Asked:
		action, action_ok := copy_action_of_word(record.values[1])
		if record.values[0] == 0 || !action_ok {
			return {}, false
		}
		event.clipboard_serial = record.values[0]
		event.copy_action = action
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
	case .Work_Area:
		// The words are read as words, as for Resized.
		width, height := record.values[0], record.values[1]
		if width == 0 || height == 0 || width > WORK_AREA_LIMIT || height > WORK_AREA_LIMIT {
			return {}, false
		}
		event.width, event.height = int(width), int(height)
	case .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened:
		// The records of the capture face: the service of the remote
		// display reads them itself, and a window takes none.
		return {}, false
	}
	return event, true
}

// The holder of the display took the window: its first Work_Area, which
// the holder sends when it takes the surface. Each holder of the role sends
// it, so a test of another part waits for this fact, never for a line of
// one holder (src/md/features/roles_and_contracts.md, "Conformance").
@(log_fact = "display: {window}: the holder of the display took the window, in a work area of {width}x{height}")
Window_Taken :: struct {
	width:  u64,
	height: u64,
	window: [40]u8,
}

// work_area_take keeps the work area of an event Work_Area. It gives true
// for the first one of the window: the holder took the window. The caller
// gives a size that event_of_record checked.
work_area_take :: proc "contextless" (window: ^Window, width, height: int) -> (first: bool) {
	first = window.work_area_width == 0
	window.work_area_width, window.work_area_height = width, height
	return first
}

// work_area gives the work area that the holder of the display named, in
// logical pixels, or false before the first one. A window that fills the
// screen sizes itself to it.
work_area :: proc "contextless" (window: ^Window) -> (width, height: int, named: bool) {
	return window.work_area_width, window.work_area_height, window.work_area_width != 0
}

// The settings page of this process (modus:contract/settings), or nil.
settings_page: ^settings.Page

// The text state of the graphics package has its table of the blend: the
// first text_settings_load filled it.
@(private)
text_state_started: bool

// text_settings_open finds the settings page in the context, opens the
// font outlines once (a font file is hostile input), and applies the
// choice of the owner. With no page, with no outlines, or with outlines
// that the validation refuses, the text of the process is Spleen 8x16,
// with a line on the log. The compositor calls it too.
//
// Why one validation is enough: the parser reads the tables of a font file
// again at each glyph, so the bytes must not change after `validate`. A
// process trusts its starter, which already chooses its grants, its
// mappings and its budget: the starter states in the context which fixed
// ranges it mapped (modus:contract/fixed_addresses) and maps the memory
// there; the outlines state their own size in their header. So a starter
// that sets a bit with no mapping, or maps less than the header states,
// makes this process fault, and a starter that keeps that memory with
// Write could change it. The root service is the starter of each process
// with a surface. It maps the outlines from the boot image with the right
// Read only, for every process, and the one handle of the boot image, its
// own, has no right Write. So under the root service no process can write
// the bytes of a font file, nor point this process at other bytes. The
// settings page, which the process `settings` writes, gives choices only.
text_settings_open :: proc "contextless" (ctx: ^system.Context) {
	problems, loaded := text_settings_load(ctx)
	if !loaded {
		return
	}
	switch {
	case problems.outlines.kind == .None:
	case problems.outlines.kind == .Not_Mapped:
		system.log(.Warning, "display: no font outlines: the text is Spleen 8x16")
	case:
		system.log(.Warning, "display: the font outlines are refused: ", font_outlines.problem_sentences[problems.outlines.kind], ", value ", problems.outlines.value, ": the text is Spleen 8x16")
	}
	if problems.fonts_missing != {} {
		system.log(.Warning, "display: the font outlines lack ", u64(card(problems.fonts_missing)), " fonts of the fallback chains, or the renderer refuses them: the chains skip them")
	}
	// A script font whose tables pass the bound of their read at the open
	// draws the box: the process says which, once. text_settings_load
	// writes no line, as the drawing module runs it.
	for font in text_rendering.layout_refused_fonts() {
		system.log(.Warning, "display: the script font ", text_rendering.outline_font_name(font), " is refused: its tables of GSUB and GPOS pass the bound of their read at the open, or the memory of the cache: its characters draw the replacement glyph")
	}
}

// What text_settings_load refused: the problem of the font outlines, and
// the fonts that they lack. A record of zeros: no problem.
Text_Settings_Problems :: struct {
	outlines:      font_outlines.Problem, // The font outlines. Not_Mapped: the process has none.
	fonts_missing: text_rendering.Outline_Fonts, // The fonts of the chains that the outlines lack or that the renderer refuses.
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
	problems.outlines, problems.fonts_missing = fallback_load(ctx)
	_ = text_settings_apply()
	return problems, true
}

// Interface_Font: the two faces of the interface font (docs/FONTS.md,
// section 12), which this copy of text_rendering opened. A draw table that
// points to one draws its texts of the kind Interface in it.
Interface_Font :: struct {
	regular: text_rendering.Face, // The regular weight: Interface.
	bold:    text_rendering.Face, // The bold weight: Interface_Bold.
}

// The interface font of a copy of text_rendering that opened its two faces.
INTERFACE_FONT :: Interface_Font{regular = .Interface, bold = .Interface_Bold}

// interface_faces_opened says if this copy of
// src/library/modus/text_rendering opened the two faces of the interface
// font: every text in the interface font is measured and drawn from its
// font files, so a process with no outlines, or outlines that lack B612,
// draws its elements in the font of the cells.
interface_faces_opened :: proc "contextless" () -> bool {
	return text_rendering.face_opened(.Interface) && text_rendering.face_opened(.Interface_Bold)
}

// interface_font_open says if this process draws its elements in the
// interface font: the faces of the outlines that text_settings_open
// opened. ok is false with no outlines, with no line on the log (the line
// of text_settings_open says it), and when the outlines lack the interface
// font, with a line: the process then draws its text with the font of the
// cells.
interface_font_open :: proc "contextless" (ctx: ^system.Context) -> (font: Interface_Font, ok: bool) {
	if .Font_Outlines not_in fixed_addresses.ranges_mapped(&ctx.values) || !text_rendering.state.opened {
		return {}, false
	}
	if !interface_faces_opened() {
		system.log(.Warning, "display: the font outlines lack the interface font: the elements draw in the font of the cells")
		return {}, false
	}
	return INTERFACE_FONT, true
}

// The interface font of this process, found once by open: the elements
// of src/library/modus/interface draw their names, titles and labels in it
// (docs/FONTS.md, section 12.6). Absent: they draw in the font of the
// cells.
process_interface_font: Interface_Font
process_interface_font_given: bool

// interface_font_load finds the interface font of this process once:
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

// The face of the cells of each value of the setting "grid_fit".
@(rodata)
cell_faces := [settings.Grid_Fit]text_rendering.Face {
	.On  = .Cells,
	.Off = .Cells_Without_Grid_Fit,
}

// text_settings_apply gives the choice of the settings page to
// src/library/modus/graphics: the font, the order of the stripes, the
// face of the cells of the grid fit, and the appearance in force. The
// private glyph cache keeps its glyphs: its key holds the face and the
// size, and its words do not depend on the order of the stripes. A face
// that the outlines lack draws nothing, and graphics draws in Spleen.
//
// It gives true when the font, the order of the stripes, a face or the
// appearance changed, and then moves text_settings_generation. A window
// compares that number with the number of its last frame: the true of one
// call goes to that caller only, and next_event calls it too.
// interface.window_frame_begin calls it at each frame, as the drawing
// module does at each draw. The event Settings_Changed alone is not
// enough: the compositor tells only the windows that have a surface, and a
// window that read the page before the boot pass of `settings` and made
// its surface after it gets no event, while its cells, which the drawing
// module draws, follow the page.
text_settings_apply :: proc "contextless" () -> (changed: bool) {
	if settings_page == nil {
		return false
	}
	// A refused page gives the defaults: the process draws with them, as
	// with a page that never stays stable.
	choice, _ := settings.read(settings_page)
	state := &graphics.text_state
	font_before, order_before, cells_before, bold_before := state.font, state.order, state.cell_face, state.bold_face
	changed = appearance_of_choice_use(choice)
	font := choice.font == .Spleen ? graphics.Text_Font.Spleen : graphics.Text_Font.Vector
	graphics.text_faces_use(cell_faces[choice.grid_fit], .Cells_Bold)
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
	changed = changed || state.font != font_before || state.order != order_before || state.cell_face != cells_before || state.bold_face != bold_before
	if changed {
		text_settings_generation += 1
	}
	return changed
}

// The count of the changes of the text settings that text_settings_apply
// made in this process: the appearance, the font, the order of the stripes
// and the faces. A drawer that keeps pixels between frames keeps the number
// of its last frame, and draws whole when the number moved, whoever read
// the change (interface.window_frame_begin).
text_settings_generation: u64
