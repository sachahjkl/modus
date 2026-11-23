package compositor

import "internal:compositor/bar"
import process_page "modus:contract/disk_process_page"
import "modus:contract/palette_table"
import "modus:contract/pointer_pictures"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "internal:compositor/palette"
import "modus:interface"
import "modus:system"

// The log facts of the compositor (src/md/features/log_facts.md, "The facts
// of the compositor and of the windows"): the lines of the windows that a
// reader groups or filters, as records of fields. Each fact template is
// the sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line whose sentence
// differs by its case is one fact type for each case: the template has no
// condition. No field has the name of a column of the head of facts():
// number, time, process, level.
//
// The title of a window is a system.Name: 31 bytes at most and a zero
// byte, as a Module_Name_Field holds it whole. It is the last field: the
// serial line of a fact stops at its last byte that is not zero, so the
// zeros after a short title cost no byte.

// A window has a surface: the first one, or the new one after a resize.
// Its size, and the place of its surface on the screen.
@(log_fact = "compositor: surface {window} {width}x{height} at {x},{y}")
Surface_Made :: struct {
	width:  u64,
	height: u64,
	x:      u64,
	y:      u64,
	window: value_kinds.Module_Name_Field,
}

// The first Present of a new surface serial: the surface of a resize or of
// a rescale is the surface of the window from here on. width and height
// are its pixels of the screen.
@(log_fact = "compositor: window {window} shows a surface of {width}x{height} at {scale} eighths, serial {serial}")
Surface_Shown :: struct {
	serial: u64,
	width:  u64,
	height: u64,
	scale:  u64,
	window: value_kinds.Module_Name_Field,
}

// After a change of the scale, each window shows a surface of the scale in
// force: none is released, none waits for its Present, none is at the old
// scale. One line for each change.
@(log_fact = "compositor: each of the {windows} windows shows a surface at {scale} eighths")
Windows_At_Scale :: struct {
	windows: u64,
	scale:   u64,
}

// The root service answered a press on the tile Appearance with
// Settings_Raise: the compositor raised the window of settings, with the
// focus on the appearance in force.
@(log_fact = "compositor: the tile appearance raises the window settings, with the focus on the appearance in force")
Appearance_Tile_Goes_To_Settings :: struct {}

// Settings_Raise named a window that closed since the answer of the root
// service: nothing is raised, and a next press asks again.
@(log_fact = "compositor: the root service asked to raise the window settings, and no window has its ring")
Settings_Raise_Without_Window :: struct {}

// A start of settings while its window runs: the root service asked to
// raise that window in place of a second process.
@(log_fact = "compositor: the root service raised the window settings in place of a second process settings")
Settings_Window_Raised :: struct {}

// Settings_Raise named a focus that is no member: nothing is raised.
@(log_fact = "compositor: the root service asked to raise the window settings with the focus word {word}, which names no focus")
Settings_Raise_Focus_Refused :: struct {
	word: u64,
}

// A press on the tile Appearance: the compositor asks the root service,
// which knows the process settings.
@(log_fact = "compositor: the tile appearance asks for the next appearance")
Appearance_Tile_Asks_Next :: struct {}

// The control ring to the root service was full: the press is lost, and a
// next press asks again.
@(log_fact = "compositor: the tile appearance found the ring of the root service full: the press asks nothing")
Appearance_Tile_Ring_Full :: struct {}

// A window declined the scale in force: its budget does not pay a surface
// at it. The compositor draws its frame with the background until the
// window offers a surface at another scale.
@(log_fact = "compositor: window {window} declined the scale of {scale} eighths: its budget does not pay its surface; its frame stays empty until another scale")
Window_Declined_Scale :: struct {
	scale:  u64,
	window: value_kinds.Module_Name_Field,
}

// The first picture of a window reached the screen: from here on the
// window is in the menu of the windows.
@(log_fact = "compositor: window {window} is shown")
Window_Shown :: struct {
	window: value_kinds.Module_Name_Field,
}

// A window came to the front: by the menu of the windows or by the
// palette.
@(log_fact = "compositor: window {window} in front")
Window_In_Front :: struct {
	window: value_kinds.Module_Name_Field,
}

// A window closed after records whose word names no command: the count
// that the first such record announced.
@(log_fact = "compositor: window {window} closed after {refused} records whose word names no command")
Window_Closed_After_Refused_Commands :: struct {
	refused: u64,
	window:  value_kinds.Module_Name_Field,
}

// A window closed after clipboard records that the compositor refused.
@(log_fact = "compositor: window {window} closed after {refused} clipboard records that no key of the principal started or that the border refused")
Window_Closed_After_Refused_Clipboard_Records :: struct {
	refused: u64,
	window:  value_kinds.Module_Name_Field,
}

// A window closed while its queue lost records: the end of the loss.
@(log_fact = "compositor: window {window} closed and did not read its events: {key_records} key records, {pointer_records} pointer records and {other_records} other records were lost")
Window_Closed_With_Lost_Events :: struct {
	key_records:     u64,
	pointer_records: u64,
	other_records:   u64,
	window:          value_kinds.Module_Name_Field,
}

// The ring of a window and its queue are full: a record is lost, and the
// loss begins.
@(log_fact = "compositor: window {window} does not read its events: {waiting} records wait for it, and a new record is lost")
Window_Events_Lost :: struct {
	waiting: u64,
	window:  value_kinds.Module_Name_Field,
}

// A window that lost records reads its events again: the end of the loss,
// with its counts.
@(log_fact = "compositor: window {window} reads its events again: {key_records} key records, {pointer_records} pointer records and {other_records} other records were lost")
Window_Events_Read_Again :: struct {
	key_records:     u64,
	pointer_records: u64,
	other_records:   u64,
	window:          value_kinds.Module_Name_Field,
}

// The first record of a window whose word names no command: the next
// ones are counted, and Window_Closed_After_Refused_Commands gives the
// count.
@(log_fact = "compositor: a window sent the word {word}, which names no command; the next ones are counted, and the count comes when the window closes")
Window_Word_Refused :: struct {
	word: u64,
}

// A word of the control ring that names no control command.
@(log_fact = "compositor: the root service sent the control word {word}, which names no control command")
Control_Word_Refused :: struct {
	word: u64,
}

// A control command that goes from the compositor to the root service,
// never the other way.
@(log_fact = "compositor: the root service sent the control command {word}, which the compositor does not take")
Control_Command_Not_Taken :: struct {
	word: u64,
}

// A word of the input ring that names no input.
@(log_fact = "compositor: the input service sent the word {word}, which names no input")
Input_Word_Refused :: struct {
	word: u64,
}

// A window asked for a pointer shape that names no shape.
@(log_fact = "compositor: {window} asks for the pointer shape {shape}, which names no shape: it is refused")
Pointer_Shape_Refused :: struct {
	shape:  u64,
	window: value_kinds.Module_Name_Field,
}

// The palette placed a named element, or moved it: its rectangle in
// pixels of the screen. The palette is a panel of the compositor, not a
// window, so the compositor writes these facts, as interface.Element_Placed
// for a window.
@(log_fact = "compositor: the palette: the element {element} at {x},{y},{width},{height}")
Palette_Element_Placed :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	element: [40]u8,
}

// A named element that the palette no longer has: each one when it closes.
@(log_fact = "compositor: the palette: the element {element} is gone")
Palette_Element_Gone :: struct {
	element: [40]u8,
}

// The tool reads the length of a Text field as a literal: the field of an
// element name has the bytes of the field of a window.
#assert(size_of(Palette_Element_Placed) == 4 * size_of(i64) + interface.ELEMENT_FACT_TEXT_BYTES && size_of(Palette_Element_Gone) == interface.ELEMENT_FACT_TEXT_BYTES)

// palette_element_places_publish writes the facts of the elements of the
// palette that changed since the set that was written, as
// interface.element_places_publish does for a window, then keeps the set
// of the frame.
palette_element_places_publish :: proc "contextless" () {
	written, now := &palette_element_places_written, &palette_element_places_drawn
	for &place in now.places[:now.count] {
		if !interface.element_place_changed(written, &place) {
			continue
		}
		system.log_fact(.Info, Palette_Element_Placed{element = value_kinds.text_field(interface.element_place_name(&place), interface.ELEMENT_FACT_TEXT_BYTES), x = i64(place.area.x), y = i64(place.area.y), width = i64(place.area.width), height = i64(place.area.height)})
	}
	for &place in written.places[:written.count] {
		name := interface.element_place_name(&place)
		if interface.element_places_find(now, name) == nil {
			system.log_fact(.Info, Palette_Element_Gone{element = value_kinds.text_field(name, interface.ELEMENT_FACT_TEXT_BYTES)})
		}
	}
	interface.element_places_keep(written, now)
}

// window_field gives the field of the title of a window: its text before
// the first zero byte.
window_field :: proc "contextless" (title: []u8) -> value_kinds.Module_Name_Field {
	return value_kinds.module_name_field(system.name_of(title))
}

// The other lines of the compositor that have a value. A Text field that
// is not a title holds words of a closed set, a palette entry name or a
// name of the pointer theme: each has a bound, and its field holds the
// longest one and a zero byte. The text of a field of the palette, with
// no small bound, is a text view.

// The bytes of the Text field of a palette entry name: palette.NAME_CAPACITY,
// a zero byte, and the bytes that end the record on 8 bytes.
ENTRY_NAME_FIELD_BYTES :: 72
#assert(ENTRY_NAME_FIELD_BYTES > palette.NAME_CAPACITY)
// The bytes of the Text field of a value name of a setting row:
// palette_table.VALUE_NAME_CAPACITY and a zero byte, on 8 bytes.
VALUE_NAME_FIELD_BYTES :: 32
#assert(VALUE_NAME_FIELD_BYTES > palette_table.VALUE_NAME_CAPACITY)
// The bytes of the Text field of the sentence of a refused key or field of
// the palette: palette.MESSAGE_CAPACITY and a zero byte, on 8 bytes.
MESSAGE_FIELD_BYTES :: 104
#assert(MESSAGE_FIELD_BYTES > palette.MESSAGE_CAPACITY)
// The bytes of the Text field of the hash prefix of a disk process: its
// digits and a zero byte, on 8 bytes.
HASH_PREFIX_FIELD_BYTES :: 24
#assert(HASH_PREFIX_FIELD_BYTES > process_page.HASH_PREFIX_DIGITS)
// The bytes of the Text field of the name and of the license of a pointer
// theme: pointer_pictures.NAME_CAPACITY or LICENSE_CAPACITY, which a name
// can fill, and a zero byte, on 8 bytes.
THEME_TEXT_FIELD_BYTES :: 40
#assert(THEME_TEXT_FIELD_BYTES > pointer_pictures.NAME_CAPACITY && THEME_TEXT_FIELD_BYTES > pointer_pictures.LICENSE_CAPACITY)
// The bytes of the Text fields of short closed sets of words: "yes" or
// "no"; a pointer form; a kind of an entry; a cause of an end of the
// capture face; a part of a scroll bar; a cause of a close of the palette;
// a pointer shape; a refusal of the capture face; a problem of the size
// limits; a kind of a result; a unit of a field.
YES_NO_FIELD_BYTES :: 8
POINTER_FORM_FIELD_BYTES :: 8
KIND_WORDS_FIELD_BYTES :: 16
CAPTURE_END_FIELD_BYTES :: 24
SCROLL_PART_FIELD_BYTES :: 32
CLOSE_CAUSE_FIELD_BYTES :: 40
SHAPE_NAME_FIELD_BYTES :: 32
CAPTURE_REFUSAL_FIELD_BYTES :: 64
LIMITS_PROBLEM_FIELD_BYTES :: 64
RESULT_KIND_FIELD_BYTES :: 16
// The bytes of the Text field of a problem of the table of the palette
// provider: the longest text of palette_table.problem_names, 80 bytes, and
// a zero byte, on 8 bytes.
TABLE_PROBLEM_FIELD_BYTES :: 88
UNIT_FIELD_BYTES :: 8
INPUT_WORDS_FIELD_BYTES :: 8
BUTTONS_WORDS_FIELD_BYTES :: 24
// The words of a field whose candidates are a row of buttons.
BUTTONS_WORDS :: ", as a row of buttons"
#assert(len(BUTTONS_WORDS) < BUTTONS_WORDS_FIELD_BYTES)

// The first command of the capture face that the compositor refused: the
// next ones are counted.
@(log_fact = "compositor: refused a command of the capture face: {capture_refusal}; the next refusals are counted only")
Capture_Command_Refused :: struct {
	capture_refusal: [64]u8,
}

// The capture face is open: a copy of the screen after each frame.
@(log_fact = "compositor: the capture face is open: a copy of {width}x{height} after each frame, and the mark of a viewer in the bar")
Capture_Face_Opened :: struct {
	width:  u64,
	height: u64,
}

// The capture face ended: why, and what passed through it.
@(log_fact = "compositor: the capture face ended ({capture_end}) after {pictures} pictures, {viewer_keys} keys and {viewer_pointer_records} pointer records of viewers, {refused} refused commands")
Capture_Face_Ended :: struct {
	pictures:               u64,
	viewer_keys:            u64,
	viewer_pointer_records: u64,
	refused:                u64,
	capture_end:            [24]u8,
}

// The copy key went to the window in front.
@(log_fact = "compositor: the copy key goes to {window}")
Copy_Key_Sent :: struct {
	window: value_kinds.Module_Name_Field,
}

// The cut key went to the window in front.
@(log_fact = "compositor: the cut key goes to {window}")
Cut_Key_Sent :: struct {
	window: value_kinds.Module_Name_Field,
}

// A paste with an empty clipboard: nothing goes to the window.
@(log_fact = "compositor: a paste with an empty clipboard: nothing goes to {window}")
Paste_Of_Empty_Clipboard :: struct {
	window: value_kinds.Module_Name_Field,
}

// The kernel refused the lend of the clipboard to the window.
@(log_fact = "compositor: the paste to {window} is refused by the kernel: nothing goes")
Paste_Refused :: struct {
	window: value_kinds.Module_Name_Field,
}

// A paste of the clipboard went to a window.
@(log_fact = "compositor: a paste of {length} of text from {owner_window} goes to {window}")
Paste_Sent :: struct {
	length:       value_kinds.Size_In_Bytes,
	owner_window: value_kinds.Module_Name_Field,
	window:       value_kinds.Module_Name_Field,
}

// A window copied a text: the clipboard holds it.
@(log_fact = "compositor: a copy of {length} of text from {window}")
Text_Copied :: struct {
	length: value_kinds.Size_In_Bytes,
	window: value_kinds.Module_Name_Field,
}

// The window in front had nothing to copy.
@(log_fact = "compositor: {window} has nothing to copy")
Nothing_To_Copy :: struct {
	window: value_kinds.Module_Name_Field,
}

// The window that owned the clipboard ended: the clipboard is empty.
@(log_fact = "compositor: the clipboard is empty: {window} ended")
Clipboard_Emptied :: struct {
	window: value_kinds.Module_Name_Field,
}

// The bar is drawn in the interface font: the width of the widest name of
// the start menu, in pixels.
@(log_fact = "compositor: the bar is in the interface font: the widest name {name_width} pixels")
Bar_In_Interface_Font :: struct {
	name_width: u64,
}

// The menu of the windows shows a disk process, by its hash prefix.
@(log_fact = "compositor: the menu of the windows shows the disk process {window} with the hash prefix {hash_prefix}, from the root service")
Disk_Process_In_Menu :: struct {
	hash_prefix: [24]u8,
	window:      value_kinds.Module_Name_Field,
}

// The budget of the compositor does not hold the two screen pages: the
// service stops.
@(log_fact = "compositor: a screen of {width}x{height} needs {needed_pages} pages, the budget holds {budget_pages}")
Screen_Past_Budget :: struct {
	width:        u64,
	height:       u64,
	needed_pages: u64,
	budget_pages: u64,
}

// The compositor runs: the size of the screen.
@(log_fact = "compositor: ok {width}x{height}")
Compositor_Ready :: struct {
	width:  u64,
	height: u64,
}

// A press of the left button: its place on the screen.
@(log_fact = "compositor: a press of the left button at {x},{y}")
Left_Button_Pressed :: struct {
	x: u64,
	y: u64,
}

// Alt+Tab opened the window switcher over the windows.
@(log_fact = "compositor: the window switcher lists {windows} windows")
Window_Switcher_Opened :: struct {
	windows: u64,
}

// The release of Alt brought the window that the switcher chose to the
// front.
@(log_fact = "compositor: the window switcher brought {window} to the front")
Window_Switched :: struct {
	window: value_kinds.Module_Name_Field,
}

// A press on the plate of the window in front minimized it.
@(log_fact = "compositor: the plate of {window} minimized it")
Plate_Minimized :: struct {
	window: value_kinds.Module_Name_Field,
}

// A press on a plate brought its window to the front.
@(log_fact = "compositor: the plate of {window} brought it to the front")
Plate_Raised :: struct {
	window: value_kinds.Module_Name_Field,
}

// A press on the plate of a minimized window restored it.
@(log_fact = "compositor: the plate of {window} restored it")
Plate_Restored :: struct {
	window: value_kinds.Module_Name_Field,
}

// A window moved: its new place.
@(log_fact = "compositor: window {window} moved to {x},{y}")
Window_Moved :: struct {
	x:      u64,
	y:      u64,
	window: value_kinds.Module_Name_Field,
}

// The frames of the move of a window, and their times.
@(log_fact = "compositor: the move of {window}: {frames} frames, {time_per_frame} per frame, {longest_frame} the longest")
Window_Move_Measured :: struct {
	frames:         u64,
	time_per_frame: value_kinds.Time_In_Microseconds,
	longest_frame:  value_kinds.Time_In_Microseconds,
	window:         value_kinds.Module_Name_Field,
}

// The display kept another offset than the flip asked: each later frame
// goes to the screen page 0.
@(log_fact = "compositor: the display refused the page flip to the screen page {screen_page}: each later frame is written into the screen page 0, which the display shows")
Page_Flip_Refused :: struct {
	screen_page: u64,
}

// The copy instructions of the processor that the copies of bytes use.
@(log_fact = "compositor: the processor: ERMS {erms}, FSRM {fsrm}")
Processor_Copy_Features :: struct {
	erms: [8]u8,
	fsrm: [8]u8,
}

// The drawing module refused a draw of the screen: the part is not drawn,
// and the line comes one time.
@(log_fact = "compositor: the drawing module refused execute_draw_table_in_rectangles_20 (the error kind {error_kind}, the argument {error_argument}): the part of the screen is not drawn. The compositor writes this line one time")
Screen_Draw_Refused :: struct {
	error_kind:     u64,
	error_argument: u64,
}

// The table of the palette provider breaks a rule: the palette lists the
// processes and the windows only.
@(log_fact = "compositor: the table of the palette provider is refused: {table_problem}, entry {entry_index}; the palette lists the processes and the windows only")
Provider_Table_Refused :: struct {
	entry_index:   u64,
	table_problem: [88]u8,
}

// A window gave the names of what its elements act on.
@(log_fact = "compositor: the window {window} gave {act_names} act names")
Act_Names_Given :: struct {
	act_names: u64,
	window:    value_kinds.Module_Name_Field,
}

// A window gave a set of act names that is refused: it has none now.
@(log_fact = "compositor: the window {window} gave a set of act names that is refused: it has none now")
Act_Names_Refused :: struct {
	window: value_kinds.Module_Name_Field,
}

// No open window names what a palette entry acts on.
@(log_fact = "compositor: no open window names what {entry} acts on: the palette does not go to it")
Act_Without_Window :: struct {
	entry: [72]u8,
}

// The palette went to the element of a window that acts on an entry.
@(log_fact = "compositor: the palette goes to {entry} in the window {window}, now in front")
Palette_Goes_To_Window :: struct {
	entry:  [72]u8,
	window: value_kinds.Module_Name_Field,
}

// The provider gave the candidates of a field of the palette.
@(log_fact = "compositor: the palette has {candidates} candidates for the field {field}{buttons_words}")
Palette_Candidates_Ready :: struct {
	candidates:    u64,
	field:         u64,
	buttons_words: [24]u8,
}

// The palette did what the provider was sent.
@(log_fact = "compositor: the palette did: {sent_entry}")
Palette_Did :: struct {
	sent_entry: [72]u8,
}

// The palette shows a result of a kind.
@(log_fact = "compositor: the palette shows {result_kind}")
Palette_Shows_Result :: struct {
	result_kind: [16]u8,
}

// An entry that destroys something waits for a second Enter.
@(log_fact = "compositor: the palette asks to confirm: {entry}")
Palette_Asks_To_Confirm :: struct {
	entry: [72]u8,
}

// A value of a setting row is set by the palette.
@(log_fact = "compositor: the palette sets {entry} to {value_name}, by {input}")
Palette_Sets_Value :: struct {
	entry:      [72]u8,
	value_name: [32]u8,
	input:      [8]u8,
}

// The palette opened the form of the arguments of an entry.
@(log_fact = "compositor: the palette asks for the arguments of {entry}")
Palette_Asks_For_Arguments :: struct {
	entry: [72]u8,
}

// A field of the form takes a number in a unit.
@(log_fact = "compositor: the field {field} of {entry} takes a number in {unit}")
Palette_Field_Unit :: struct {
	field: u64,
	entry: [72]u8,
	unit:  [8]u8,
}

// The palette refused a key or the arguments of its form: the sentence of
// the form.
@(log_fact = "compositor: the palette refuses the key: {form_refusal}")
Palette_Key_Refused :: struct {
	form_refusal: [104]u8,
}

// The palette refused the arguments of its form.
@(log_fact = "compositor: the palette refuses the arguments: {form_refusal}")
Palette_Arguments_Refused :: struct {
	form_refusal: [104]u8,
}

// The palette chose a value of a setting row.
@(log_fact = "compositor: the palette chooses the value {value_name} of {entry}")
Palette_Chooses_Value :: struct {
	entry:      [72]u8,
	value_name: [32]u8,
}

// The palette asked the provider to open an entry in its edit line.
@(log_fact = "compositor: the palette opens {entry} in the console")
Palette_Opens_In_Console :: struct {
	entry: [72]u8,
}

// The palette sent an entry and the arguments of its form to the provider.
@(log_fact = "compositor: the palette sends {sent_entry} with {arguments} arguments to the console")
Palette_Sends_With_Arguments :: struct {
	arguments:  u64,
	sent_entry: [72]u8,
}

// The palette asked for the page of the manual of an entry.
@(log_fact = "compositor: the palette asks for the page of the manual of {sent_entry}")
Palette_Asks_For_Manual :: struct {
	sent_entry: [72]u8,
}

// The palette sent an entry to the provider.
@(log_fact = "compositor: the palette sends {sent_entry} to the console")
Palette_Sends :: struct {
	sent_entry: [72]u8,
}

// The palette started a module.
@(log_fact = "compositor: the palette starts {entry}")
Palette_Starts :: struct {
	entry: [72]u8,
}

// The palette brought a window to the front.
@(log_fact = "compositor: the palette brings {entry} to the front")
Palette_Brings_To_Front :: struct {
	entry: [72]u8,
}

// The palette closed a window.
@(log_fact = "compositor: the palette closes the window {window}")
Palette_Closes_Window :: struct {
	window: value_kinds.Module_Name_Field,
}

// A press put the caret of the palette in a field.
@(log_fact = "compositor: a press puts the caret of the palette in the field {field}, after {characters} characters")
Palette_Caret_Put :: struct {
	field:      u64,
	characters: u64,
}

// A press on a part of the scroll bar of the palette moved its rows.
@(log_fact = "compositor: the scroll bar of the palette: a press on {scroll_part}, the rows from {first_row}")
Palette_Scroll_Pressed :: struct {
	first_row:   u64,
	scroll_part: [32]u8,
}

// The wheel moved the rows of the palette.
@(log_fact = "compositor: the wheel moves the rows of the palette: the rows from {first_row}")
Palette_Wheel_Moved :: struct {
	first_row: u64,
}

// A drag of the thumb of the scroll bar of the palette ended.
@(log_fact = "compositor: the scroll bar of the palette: a drag of the thumb, the rows from {first_row}")
Palette_Thumb_Dragged :: struct {
	first_row: u64,
}

// The palette shows a setting as one row of buttons.
@(log_fact = "compositor: the palette shows the setting {entry} as one row of {values} values")
Palette_Setting_Row_Shown :: struct {
	values: u64,
	entry:  [72]u8,
}

// The palette chose an entry: its name and its kind.
@(log_fact = "compositor: the palette chooses {entry} ({kind_words})")
Palette_Chooses_Entry :: struct {
	entry:      [72]u8,
	kind_words: [16]u8,
}

// The palette is closed: by what.
@(log_fact = "compositor: the palette is closed by {close_cause}")
Palette_Closed :: struct {
	close_cause: [40]u8,
}

// The pointer theme of a file of the boot image is valid: its name, its
// license, its counts, and the time of its check.
@(log_fact = "compositor: the pointer theme {theme} ({license}): {shapes} shapes, {pictures} pictures, {size}, validated in {elapsed}")
Pointer_Theme_Validated :: struct {
	shapes:   u64,
	pictures: u64,
	size:     value_kinds.Size_In_Bytes,
	elapsed:  value_kinds.Time_In_Microseconds,
	theme:    [40]u8,
	license:  [40]u8,
}

// The pointer form in use: light or dark.
@(log_fact = "compositor: the pointer form in use: {pointer_form}")
Pointer_Form_In_Use :: struct {
	pointer_form: [8]u8,
}

// The pointer theme in use.
@(log_fact = "compositor: the pointer theme in use: {theme}")
Pointer_Theme_In_Use :: struct {
	theme: [40]u8,
}

// A window asks for a pointer shape over its surface.
@(log_fact = "compositor: {window} asks for the pointer shape {shape_name} over its surface")
Pointer_Shape_Asked :: struct {
	shape_name: [32]u8,
	window:     value_kinds.Module_Name_Field,
}

// The time of the pointer picture over a count of frames.
@(log_fact = "compositor: the pointer picture in {frames} frames: {mean_time} for a frame in the mean, {longest_time} the longest")
Pointer_Picture_Measured :: struct {
	frames:       u64,
	mean_time:    value_kinds.Time_In_Nanoseconds,
	longest_time: value_kinds.Time_In_Nanoseconds,
}

// The rate of the frames while the pointer moves, over a series of frames
// that each show a new pointer record.
@(log_fact = "compositor: measure: the pointer moved in {frames} frames over {span}: {frames_each_second} frames each second, for {records} pointer records")
Pointer_Motion_Measured :: struct {
	frames:             u64,
	span:               value_kinds.Nanoseconds_As_Microseconds,
	frames_each_second: u64,
	records:            u64,
}

// The blend of the arrow and a copy of the same size.
@(log_fact = "compositor: the blend of the arrow of {width}x{height} ({transparent_pixels} of {pixels} pixels transparent): {blend_time}; a copy of the same size: {copy_time}")
Arrow_Blend_Measured :: struct {
	width:              u64,
	height:             u64,
	transparent_pixels: u64,
	pixels:             u64,
	blend_time:         value_kinds.Time_In_Nanoseconds,
	copy_time:          value_kinds.Time_In_Nanoseconds,
}

// The losses of the measure of the keys to the screen since the start.
@(log_fact = "compositor: the measure of the keys to the screen: {lost_keys} keys left the table before a flip showed them, and {refused_serials} serials that a window named were past the keys that it got, since the start")
Key_Measure_Losses :: struct {
	lost_keys:       u64,
	refused_serials: u64,
}

// The compositor has no memory to keep the records that wait for a window
// whose ring is full.
@(log_fact = "compositor: no memory for the records that wait for window {window}: each record that its full ring refuses is lost")
No_Memory_For_Waiting_Records :: struct {
	window: value_kinds.Module_Name_Field,
}

// A window asks for size limits that it cannot have: the line comes one
// time for each window.
@(log_fact = "compositor: window {window} asks to be resizable with limits that it cannot have: {limits_problem}; it stays as it was. A window writes this line one time")
Resizable_Refused :: struct {
	limits_problem: [64]u8,
	window:         value_kinds.Module_Name_Field,
}

// A window is resizable between its limits.
@(log_fact = "compositor: window {window} is resizable from {least_width}x{least_height} to {largest_width}x{largest_height}")
Window_Resizable :: struct {
	least_width:    u64,
	least_height:   u64,
	largest_width:  u64,
	largest_height: u64,
	window:         value_kinds.Module_Name_Field,
}

// The surface of a new size cannot be mapped: the window keeps its size.
@(log_fact = "compositor: window {window}: the surface of {width}x{height} cannot be mapped; the window keeps its size")
Surface_Not_Mapped :: struct {
	width:  u64,
	height: u64,
	window: value_kinds.Module_Name_Field,
}

// A window kept its size after a resize.
@(log_fact = "compositor: window {window} keeps its size {width}x{height}")
Window_Keeps_Size :: struct {
	width:  u64,
	height: u64,
	window: value_kinds.Module_Name_Field,
}

// A window took its new size.
@(log_fact = "compositor: window {window} resized from {old_width}x{old_height} to {width}x{height}")
Window_Resized :: struct {
	old_width:  u64,
	old_height: u64,
	width:      u64,
	height:     u64,
	window:     value_kinds.Module_Name_Field,
}

// A window took the work area: the maximize.
@(log_fact = "compositor: window {window} maximized")
Window_Maximized :: struct {
	window: value_kinds.Module_Name_Field,
}

// A maximized window takes back its place, and its size of before.
@(log_fact = "compositor: window {window} restored")
Window_Restored :: struct {
	window: value_kinds.Module_Name_Field,
}

// The compositor asked a window to draw at a size.
@(log_fact = "compositor: window {window} asked to draw at {width}x{height}")
Draw_Size_Asked :: struct {
	width:  u64,
	height: u64,
	window: value_kinds.Module_Name_Field,
}

// The bar shows the local time of a new time zone: the time as it draws
// it, the zone, and the date of UTC in seconds since 1970.
@(log_fact = "compositor: the bar shows the local time {local_time} with the time zone {zone}, at {date} since 1970")
Bar_Local_Time :: struct {
	date:       value_kinds.Time_In_Seconds,
	local_time: [24]u8,
	zone:       [8]u8,
}

// The bytes of the Text field of the local time of the bar: the buffer
// that calendar.iso_text fills, whose text is 19 bytes, on 8 bytes; and
// of a time zone: settings.ZONE_TEXT_SIZE and a zero byte.
LOCAL_TIME_FIELD_BYTES :: 24
ZONE_FIELD_BYTES :: 8
#assert(ZONE_FIELD_BYTES > settings.ZONE_TEXT_SIZE)

// The lines of the compositor with no value: each is a fact type with no
// field, whose sentence is its template.

// The first key of a viewer of the remote display reached the path of the
// keys.
@(log_fact = "compositor: the first key of a viewer of the remote display goes along the path of the keys")
First_Viewer_Key :: struct {}

// The copy key came with no window in front.
@(log_fact = "compositor: the copy key with no window in front")
Copy_Key_Without_Window :: struct {}

// The paste key came with no window in front.
@(log_fact = "compositor: the paste key with no window in front")
Paste_Key_Without_Window :: struct {}

// The bar is drawn in the font of the cells.
@(log_fact = "compositor: the bar is in the font of the cells")
Bar_In_Cell_Font :: struct {}

// The compositor has no memory for its frame.
@(log_fact = "compositor: no memory")
No_Memory :: struct {}

// The display has two screen pages: each frame reaches the screen whole.
@(log_fact = "compositor: two screen pages: each frame reaches the screen whole, by a page flip")
Two_Screen_Pages :: struct {}

// The display has one screen page: each frame is written into the page
// that it shows.
@(log_fact = "compositor: one screen page: each frame is written into the screen page that the display shows")
One_Screen_Page :: struct {}

// The screen is the scanout of the virtual GPU: each frame goes to the
// device in one batch of its damage rectangles
// (src/md/infrastructure/whole_frame.md).
@(log_fact = "compositor: the screen is the scanout of the virtual GPU, resource {resource_id} at {width}x{height}: each frame goes to the device in one batch of its damage rectangles")
Screen_Is_Gpu_Scanout :: struct {
	width:       u64,
	height:      u64,
	resource_id: u64,
}

// gpu_device answered, but the compositor did not take its scanout: the
// status of the step that failed. The screen pages stay.
@(log_fact = "compositor: the scanout of the virtual GPU is not taken (status {status}): the screen pages show the frames")
Gpu_Scanout_Not_Taken :: struct {
	status: u64,
}

// A present of the scanout was refused, or had no answer in the hang
// bound: the screen pages take the frames from a whole frame on.
@(log_fact = "compositor: the scanout of the virtual GPU ended after {presents} frames (status {status}): the screen pages take the frames")
Gpu_Present_Refused :: struct {
	status:   u64,
	presents: u64,
}

// The context gives no framebuffer.
@(log_fact = "compositor: no framebuffer")
No_Framebuffer :: struct {}

// The context gives no framebuffer and the size of a screen of memory: the
// frame is the screen (src/md/features/screen_of_memory.md).
@(log_fact = "compositor: no screen: a screen of memory of {width} x {height}")
Screen_Of_Memory_Started :: struct {
	width:  u64,
	height: u64,
}

// The capture face ended with the screen of memory past its start size: no
// viewer looks, and the screen went back to its start size.
@(log_fact = "compositor: no viewer looks: the screen of memory is back to {width} x {height}, and {windows} windows fit it again")
Screen_Of_Memory_Back_To_Start :: struct {
	width:   u64,
	height:  u64,
	windows: u64,
}

// The screen of memory did not go back to its start size when no viewer
// looked: the kernel had fewer pages than the budget of the compositor says.
@(log_fact = "compositor: no viewer looks, and the screen of memory did not go back to {width} x {height}: the kernel made no frame and no background of that size")
Screen_Of_Memory_Not_Back_To_Start :: struct {
	width:  u64,
	height: u64,
}

// A viewer asked a size of the screen of memory, and the compositor took it.
@(log_fact = "compositor: the screen of memory is now {width} x {height}, which a viewer asked: {windows} windows fit it again")
Screen_Of_Memory_Resized :: struct {
	width:   u64,
	height:  u64,
	windows: u64,
}

// The root service gave an extra budget for a larger screen of memory.
@(log_fact = "compositor: an extra budget of {pages} for a screen of memory of {width} x {height}")
Screen_Budget_Taken :: struct {
	width:  u64,
	height: u64,
	pages:  value_kinds.Size_In_Pages,
}

// The root service gave a handle that is no budget, an extra budget with no
// number, or a third one: it is closed with no use.
@(log_fact = "compositor: closed an extra budget for {width} x {height} with no use: it is no budget, has no number, or two are held already")
Screen_Budget_Not_Taken :: struct {
	width:  u64,
	height: u64,
}

// The control ring had no room for the release of the extra budget: the
// root service ends it at the stop of the compositor.
@(log_fact = "compositor: the control ring has no room for the release of the extra budget of the screen of memory: its pages return at the stop of the compositor")
Screen_Budget_Release_Not_Sent :: struct {}

// A viewer asked a size of the screen, and the compositor refused it.
@(log_fact = "compositor: refused a screen of {width} x {height} that a viewer asked: {resize_refusal}")
Screen_Of_Memory_Refused :: struct {
	width:          u64,
	height:         u64,
	resize_refusal: [88]u8,
}

// The context gives no input ring or no control ring.
@(log_fact = "compositor: no input ring or no control ring")
No_Input_Or_Control_Ring :: struct {}

// The first frame reached the screen.
@(log_fact = "compositor: first frame")
First_Frame :: struct {}

// The start menu is open.
@(log_fact = "compositor: the start menu is open")
Start_Menu_Open :: struct {}

// The start menu shows its demonstrations: the quick action opened them.
@(log_fact = "compositor: the demonstrations of the start menu are shown")
Start_Menu_Demonstrations_Shown :: struct {}

// The start menu hides its demonstrations again.
@(log_fact = "compositor: the demonstrations of the start menu are hidden")
Start_Menu_Demonstrations_Hidden :: struct {}

// Control+Shift+F7 or the palette: the arrows move the window in front.
@(log_fact = "compositor: window {window} moves by keys")
Keyboard_Move_Started :: struct {
	window: value_kinds.Module_Name_Field,
}

// Control+Shift+F8 or the palette: the arrows resize the window in front.
@(log_fact = "compositor: window {window} resizes by keys")
Keyboard_Resize_Started :: struct {
	window: value_kinds.Module_Name_Field,
}

// A resize by keys did not start: the window is fixed, or a resize of it
// waits for its process.
@(log_fact = "compositor: window {window} does not resize by keys: it is fixed, or its process has not answered a resize")
Keyboard_Resize_Refused :: struct {
	window: value_kinds.Module_Name_Field,
}

// Escape ended a move or a resize by keys: the window has its place and
// its size of before.
@(log_fact = "compositor: window {window} keeps its place and its size")
Keyboard_Window_Kept :: struct {
	window: value_kinds.Module_Name_Field,
}

// Control+Shift+F10, or a key while a menu of the bar is open: the bar has
// the focus of the keys.
@(log_fact = "compositor: the bar has the focus of the keys")
Bar_Focus_Taken :: struct {}

// The bar gave the focus of the keys back to the window in front.
@(log_fact = "compositor: the bar gives the focus of the keys back")
Bar_Focus_Left :: struct {}

// The draw table of the screen is full: records are missing.
@(log_fact = "compositor: the draw table of the screen is full: records are missing")
Screen_Draw_Table_Full :: struct {}

// The ranking thread of the palette does not start: the palette lists
// nothing.
@(log_fact = "compositor: cannot start the ranking thread: the palette lists nothing")
Ranking_Thread_Not_Started :: struct {}

// The entries changed while the form was open: the palette goes back to
// the search.
@(log_fact = "compositor: the palette goes back to the search: the entries changed")
Palette_Entries_Changed :: struct {}

// The chosen entry left the list: the first entry is chosen.
@(log_fact = "compositor: the chosen entry of the palette left the list: the first entry is chosen, and Enter waits for a frame")
Chosen_Entry_Left :: struct {}

// The palette provider is refused: its ring or its table cannot be mapped.
@(log_fact = "compositor: the palette provider is refused: its ring or its table cannot be mapped")
Palette_Provider_Refused :: struct {}

// The palette has a provider.
@(log_fact = "compositor: the palette has a provider")
Palette_Provider_Present :: struct {}

// The palette has no provider.
@(log_fact = "compositor: the palette has no provider")
Palette_Provider_Absent :: struct {}

// The manual shows the page that the palette asked for.
@(log_fact = "compositor: the manual shows the page")
Palette_Manual_Shown :: struct {}

// The result of a choice of the palette is in the window of the console.
@(log_fact = "compositor: the result of the palette is in the console")
Palette_Result_In_Console :: struct {}

// The palette opened an entry in the edit line of the console.
@(log_fact = "compositor: the palette opened the entry in the console")
Palette_Entry_Opened_In_Console :: struct {}

// The palette shows an error.
@(log_fact = "compositor: the palette shows an error")
Palette_Shows_Error :: struct {}

// The palette shows a refusal.
@(log_fact = "compositor: the palette shows a refusal")
Palette_Shows_Refusal :: struct {}

// The palette shows no result.
@(log_fact = "compositor: the palette shows no result")
Palette_Shows_No_Result :: struct {}

// The palette drops Enter: the choice changed and no frame showed it.
@(log_fact = "compositor: the palette drops Enter: the choice changed and no frame showed it yet")
Palette_Enter_Dropped :: struct {}

// The palette is open.
@(log_fact = "compositor: the palette is open")
Palette_Open :: struct {}

// Enter with no entry in the list.
@(log_fact = "compositor: the palette has no entry to run")
Palette_No_Entry_To_Run :: struct {}

// The palette goes back from the confirm to the arguments.
@(log_fact = "compositor: the palette goes back to the arguments")
Palette_Back_To_Arguments :: struct {}

// The palette goes back to the search.
@(log_fact = "compositor: the palette goes back to the search")
Palette_Back_To_Search :: struct {}

// Tab waits for the candidates of the field.
@(log_fact = "compositor: Tab waits for the candidates of the field")
Palette_Tab_Waits :: struct {}

// The draw table of the palette is full: records are missing.
@(log_fact = "compositor: the draw table of the palette is full: records are missing")
Palette_Draw_Table_Full :: struct {}

// The boot image has no pointer theme: the arrow of squares.
@(log_fact = "compositor: no pointer theme: the arrow of squares")
No_Pointer_Theme :: struct {}

// The measures of the bar and of the start menu, built and drawn, the
// least of 20 rounds: in the font of the cells only, with no interface
// font; and in both fonts.
@(log_fact = "compositor: the bar and the start menu, built and drawn (the least of 20): the font of the cells {cells_font_time}; no interface font")
Bar_Measured_Without_Interface_Font :: struct {
	cells_font_time: value_kinds.Nanoseconds_As_Microseconds,
}

@(log_fact = "compositor: the bar and the start menu, built and drawn (the least of 20): the font of the cells {cells_font_time}, the interface font {interface_font_time}")
Bar_Measured :: struct {
	cells_font_time:     value_kinds.Nanoseconds_As_Microseconds,
	interface_font_time: value_kinds.Nanoseconds_As_Microseconds,
}

// One window of the menu of the windows, in its order: one fact for each
// window, from the first.
@(log_fact = "compositor: windows: {window}, the window {place} of {windows}")
Window_Listed :: struct {
	place:   u64,
	windows: u64,
	window:  value_kinds.Module_Name_Field,
}

// The settings changed: the values, the appearance in force, the time zone,
// and the windows that draw again.
@(log_fact = "compositor: the settings changed: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; the appearance in force {in_force}; the time zone {zone}; {windows} windows draw again")
Settings_Changed :: struct {
	windows:         u64,
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
	in_force:        [8]u8,
	zone:            [8]u8,
}

// The bytes of the Text field of the name of a value of a setting, and of
// an appearance in force: the longest name and a zero byte.
SETTING_VALUE_FIELD_BYTES :: 8

// A frame that redrew the whole screen: its size, its windows, its time.
// The measure record reads it.
@(log_fact = "compositor: a full frame of {width}x{height} with {windows} windows in {elapsed}")
Full_Frame_Measured :: struct {
	width:   u64,
	height:  u64,
	windows: u64,
	elapsed: value_kinds.Time_In_Microseconds,
}

// Three forms of the title bar of the widest window, each in microseconds
// with one decimal.
@(log_fact = "compositor: a title bar of {width} pixels: one color {one_color_time}, a mix for each pixel {mix_time}, one row of colors then copies {row_copy_time}")
Title_Bar_Measured :: struct {
	width:          u64,
	one_color_time: value_kinds.Nanoseconds_As_Microseconds,
	mix_time:       value_kinds.Nanoseconds_As_Microseconds,
	row_copy_time:  value_kinds.Nanoseconds_As_Microseconds,
}

// The palette took the candidate of a field: the text of the field.
@(log_fact = "compositor: the palette takes the candidate {candidate}")
Palette_Takes_Candidate :: struct {
	candidate: [40]u8,
}

// A press took a button of a row of candidates.
@(log_fact = "compositor: a press takes the button {candidate} of the field {field}")
Palette_Button_Pressed :: struct {
	field:     u64,
	candidate: [40]u8,
}

// The bytes of the Text field of a candidate: palette_table.
// CANDIDATE_NAME_CAPACITY and a zero byte, on 8 bytes.
CANDIDATE_FIELD_BYTES :: 40
#assert(CANDIDATE_FIELD_BYTES > palette_table.CANDIDATE_NAME_CAPACITY)

// The list of the palette: the entries that match what is typed, and the
// names and the kinds of its first rows, ", ..." after them when more rows
// are left out. The rows are one text view: the waits of the machine tests
// read the list as one sentence.
@(log_fact = "compositor: the palette lists {matched} of {entries} for \"{typed}\": {rows}")
Palette_Listed :: struct {
	matched: u64,
	entries: u64,
	typed:   [72]u8,
	rows:    value_kinds.Text_View,
}

// The bytes of the Text field of what is typed in the palette:
// palette.TYPED_CAPACITY, a zero byte, on 8 bytes.
TYPED_FIELD_BYTES :: 72
#assert(TYPED_FIELD_BYTES > palette.TYPED_CAPACITY)

// The palette was open: its frames, their mean time, the longest list of
// the ranking thread, and the lists that it adopted.
@(log_fact = "compositor: the palette was open for {frames} frames, {frame_time} per frame; the longest list of the ranking thread {longest_list_time}; {adopted_lists} lists adopted, {same_lists} of them the same")
Palette_Open_Measured :: struct {
	frames:            u64,
	frame_time:        value_kinds.Nanoseconds_As_Microseconds,
	longest_list_time: value_kinds.Nanoseconds_As_Microseconds,
	adopted_lists:     u64,
	same_lists:        u64,
}

// The principal requested disconnecting a remote display viewer from the bar
// viewer list popover.
@(log_fact = "compositor: the principal asked to disconnect viewer {viewer_key_head} from the bar")
Viewer_Disconnect_Requested :: struct {
	viewer_key_head: [24]u8,
}

// The quality profile that the compositor chose, and why.
@(log_fact = "compositor: the quality profile is {profile}: {profile_reason}")
Quality_Profile_Chosen :: struct {
	profile:        [24]u8,
	profile_reason: [32]u8,
}

// The bytes of the Text fields of a profile and of its reason: the longest
// of quality.profile_sentences and of quality.reason_sentences, and a zero
// byte.
PROFILE_FIELD_BYTES :: 24
PROFILE_REASON_FIELD_BYTES :: 32

// The start of a window, from Process_Start to its first frame.
@(log_fact = "compositor: measure: the start of the window {window}, from Process_Start to its first frame: {start_time}")
Window_Start_Measured :: struct {
	start_time: value_kinds.Nanoseconds_As_Microseconds,
	window:     value_kinds.Module_Name_Field,
}

// The time of a frame, from the first record that the compositor reads to
// the flip: the least and the median of the last frames.
@(log_fact = "compositor: measure: the time of a frame, from the first record that the compositor reads to the flip: least {least}, median {median}, over {frames} frames")
Frame_Time_Measured :: struct {
	least:  value_kinds.Nanoseconds_As_Microseconds,
	median: value_kinds.Nanoseconds_As_Microseconds,
	frames: u64,
}

// The time of a key to the screen: the least and the median of the keys of
// a line.
@(log_fact = "compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it: least {least}, median {median}, over {keys} keys")
Key_Time_Measured :: struct {
	least:  value_kinds.Nanoseconds_As_Microseconds,
	median: value_kinds.Nanoseconds_As_Microseconds,
	keys:   u64,
}

// A field of the form of the palette after a key: its text, of up to
// line_editor.LINE_CAPACITY bytes, is a text view.
@(log_fact = "compositor: the field {field} of {entry} shows \"{text}\"")
Palette_Field_Shows :: struct {
	field: u64,
	entry: [72]u8,
	text:  value_kinds.Text_View,
}

// The measures of the copies and the fills of bytes, one fact for each
// form: the time of one call for each of the six sizes, in tenths of a
// nanosecond.
@(log_fact = "compositor: copy_bytes_without_overlap, ns for 8 64 512 4096 65536 3145600 bytes, aligned: {time_8} {time_64} {time_512} {time_4096} {time_65536} {time_3145600}")
Copy_Aligned_Measured :: struct {
	time_8:       value_kinds.Tenths,
	time_64:      value_kinds.Tenths,
	time_512:     value_kinds.Tenths,
	time_4096:    value_kinds.Tenths,
	time_65536:   value_kinds.Tenths,
	time_3145600: value_kinds.Tenths,
}

@(log_fact = "compositor: copy_bytes_without_overlap, not aligned: {time_8} {time_64} {time_512} {time_4096} {time_65536} {time_3145600}")
Copy_Unaligned_Measured :: struct {
	time_8:       value_kinds.Tenths,
	time_64:      value_kinds.Tenths,
	time_512:     value_kinds.Tenths,
	time_4096:    value_kinds.Tenths,
	time_65536:   value_kinds.Tenths,
	time_3145600: value_kinds.Tenths,
}

@(log_fact = "compositor: a loop of 16 bytes, aligned: {time_8} {time_64} {time_512} {time_4096} {time_65536} {time_3145600}")
Loop_Aligned_Measured :: struct {
	time_8:       value_kinds.Tenths,
	time_64:      value_kinds.Tenths,
	time_512:     value_kinds.Tenths,
	time_4096:    value_kinds.Tenths,
	time_65536:   value_kinds.Tenths,
	time_3145600: value_kinds.Tenths,
}

@(log_fact = "compositor: a loop of 16 bytes, not aligned: {time_8} {time_64} {time_512} {time_4096} {time_65536} {time_3145600}")
Loop_Unaligned_Measured :: struct {
	time_8:       value_kinds.Tenths,
	time_64:      value_kinds.Tenths,
	time_512:     value_kinds.Tenths,
	time_4096:    value_kinds.Tenths,
	time_65536:   value_kinds.Tenths,
	time_3145600: value_kinds.Tenths,
}

@(log_fact = "compositor: fill_bytes_with_value, aligned: {time_8} {time_64} {time_512} {time_4096} {time_65536} {time_3145600}")
Fill_Aligned_Measured :: struct {
	time_8:       value_kinds.Tenths,
	time_64:      value_kinds.Tenths,
	time_512:     value_kinds.Tenths,
	time_4096:    value_kinds.Tenths,
	time_65536:   value_kinds.Tenths,
	time_3145600: value_kinds.Tenths,
}

@(log_fact = "compositor: fill_bytes_with_value, not aligned: {time_8} {time_64} {time_512} {time_4096} {time_65536} {time_3145600}")
Fill_Unaligned_Measured :: struct {
	time_8:       value_kinds.Tenths,
	time_64:      value_kinds.Tenths,
	time_512:     value_kinds.Tenths,
	time_4096:    value_kinds.Tenths,
	time_65536:   value_kinds.Tenths,
	time_3145600: value_kinds.Tenths,
}

// A pointer theme file breaks a rule of its format: it is not used. The
// part, the field and the rule are members of the contract enums of
// pointer_pictures, which a reader writes by their names; the index names
// the entry of a table or the pixel, and is 0 for a part with no entries.
@(log_fact = "compositor: the pointer theme file {theme_file} is not valid, not used: part {theme_part}, index {place_index}, field {theme_field}, problem {problem_kind}, value {value}, limit {limit}")
Pointer_Theme_Refused :: struct {
	problem_kind: pointer_pictures.Problem_Kind_Word,
	theme_part:   pointer_pictures.Part_Word,
	theme_field:  pointer_pictures.Field_Word,
	place_index:  u64,
	value:        u64,
	limit:        u64,
	theme_file:   [16]u8,
}

// The bytes of the Text field of the name of a pointer theme file: the
// longest of pointer_pictures.RESOURCE_PREFERENCE, "pointers_system", and
// a zero byte.
THEME_FILE_FIELD_BYTES :: 16
#assert(len(pointer_pictures.RESOURCE_OF_THE_SYSTEM) < THEME_FILE_FIELD_BYTES && len(pointer_pictures.RESOURCE_OF_THE_OWNER) < THEME_FILE_FIELD_BYTES)

// setting_value_field gives the Text field of the name of the value of one
// setting of a choice.
setting_value_field :: proc "contextless" (choice: settings.Choice, setting: settings.Setting) -> [SETTING_VALUE_FIELD_BYTES]u8 {
	values := settings.values_of(choice)
	return value_kinds.text_field(settings.value_name_of(setting, values[setting]), SETTING_VALUE_FIELD_BYTES)
}

// The bytes of the Text field of the object of a requested grant: the
// object whole, and a zero byte.
GRANT_RESOURCE_FIELD_BYTES :: 96
#assert(GRANT_RESOURCE_FIELD_BYTES == bar.WINDOW_GRANT_RESOURCE_BYTES + 1)
// The bytes of the Text field of the name of a plan: the name whole and a
// zero byte, rounded up to a word, so the fact has no padding after its
// counts.
PLAN_NAME_FIELD_BYTES :: 56
#assert(PLAN_NAME_FIELD_BYTES == (bar.PLAN_DIFFERENCE_NAME_BYTES + 1 + 7) / 8 * 8)

// The principal kept a requested grant on the trusted display: the menu of
// the windows lists it under the window of its process.
@(log_fact = "compositor: {window} holds the grant {grant} to {resource}")
Window_Grant_Recorded :: struct {
	grant:    u64,
	resource: [96]u8,
	window:   value_kinds.Module_Name_Field,
}

// A requested grant that the principal kept is not in the menu of the
// windows: the table of the grants is full, or a name does not fit.
@(log_fact = "compositor: a grant of {window} is not listed in the menu of the windows: the table of the grants is full or a name does not fit")
Window_Grant_Not_Listed :: struct {
	window: value_kinds.Module_Name_Field,
}

// The principal revoked a requested grant: by its button in the menu of
// the windows, or by revoke_grant.
@(log_fact = "compositor: the grant {grant} of {window} to {resource} is revoked")
Window_Grant_Revoked :: struct {
	grant:    u64,
	resource: [96]u8,
	window:   value_kinds.Module_Name_Field,
}

// The window of a process closed: its grants for this run end with it.
@(log_fact = "compositor: {window} closed, and its {grants} grants end")
Window_Grants_Ended :: struct {
	grants: u64,
	window: value_kinds.Module_Name_Field,
}

// The difference of a plan shows on the trusted display.
@(log_fact = "compositor: the difference of the plan {plan} shows: {added} added, {removed} removed")
Plan_Difference_Shown :: struct {
	added:   u64,
	removed: u64,
	plan:    [56]u8,
}

// The principal accepted the difference of a plan.
@(log_fact = "compositor: the difference of the plan {plan} is accepted")
Plan_Difference_Accepted :: struct {
	plan: [56]u8,
}

// The asker of the dialog of a plan lost the grant to ask: the dialog is
// refused and closes.
@(log_fact = "compositor: the difference of the plan {plan} closes: its asker no longer holds the role Plans")
Plan_Difference_Asker_Lost :: struct {
	plan: [56]u8,
}

// The principal refused the difference of a plan.
@(log_fact = "compositor: the difference of the plan {plan} is refused")
Plan_Difference_Refused :: struct {
	plan: [56]u8,
}

// An act of an agent shows on the trusted display: the asker is the
// process that called act_ask, the act an export that it names
// (src/md/features/assistant.md, "The act dialog").
@(log_fact = "compositor: the act {act} of {asker} shows")
Act_Shown :: struct {
	asker: [56]u8,
	act:   [56]u8,
}

// The principal allowed an act once.
@(log_fact = "compositor: the act {act} of {asker} is allowed")
Act_Allowed :: struct {
	asker: [56]u8,
	act:   [56]u8,
}

// The principal refused an act.
@(log_fact = "compositor: the act {act} of {asker} is refused")
Act_Refused :: struct {
	asker: [56]u8,
	act:   [56]u8,
}

// The asker withdrew the act that showed: the dialog closed with a
// refusal, and the principal decided nothing.
@(log_fact = "compositor: the act {act} of {asker} is withdrawn by its asker")
Act_Cancelled :: struct {
	asker: [56]u8,
	act:   [56]u8,
}

// The connection of the asker of an act dialog ended, or its grant no
// longer names an asker of acts: the dialog is refused and closes.
@(log_fact = "compositor: the act dialog of {asker} closes: its asker is gone or may no longer ask")
Act_Asker_Lost :: struct {
	asker: [56]u8,
}

// A holder of the assistive role reads the trees from here on: the bar
// shows its mark.
@(log_fact = "compositor: the assistive holder {holder} reads the trees as {kind}: {nickname}")
Assistive_Holder_Attached :: struct {
	holder:   u64,
	kind:     [16]u8,
	nickname: value_kinds.Module_Name_Field,
}

// A holder of the assistive role stopped reading the trees; holders is the
// count that still read, and the mark goes with the last one.
@(log_fact = "compositor: the assistive holder {holder} stopped: {nickname}; {holders} holders still read")
Assistive_Holder_Detached :: struct {
	holder:   u64,
	holders:  u64,
	nickname: value_kinds.Module_Name_Field,
}

// The bytes of the Text field of the kind of an assistive holder: the
// longest name, "screen_reader", and a zero byte.
ASSISTIVE_KIND_FIELD_BYTES :: 16

// entry_field gives the Text field of a palette entry name.
entry_field :: proc "contextless" (name: string) -> [ENTRY_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, ENTRY_NAME_FIELD_BYTES)
}
