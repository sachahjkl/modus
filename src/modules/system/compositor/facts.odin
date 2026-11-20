package compositor

import process_page "modus:contract/disk_process_page"
import "modus:contract/palette_table"
import "modus:contract/pointer_pictures"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "modus:private/compositor/palette"
import "modus:support/interface"
import "modus:support/system"

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
// longest one and a zero byte. A line that holds a time with one decimal,
// a list of the windows, a sentence of a refusal of another writer, the
// text of a field of the palette, or a measure that the measure record or
// quality_lines_check reads from the raw log stays text.

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

// The bar is drawn in the interface font: the widths of its labels and of
// the widest name, in pixels.
@(log_fact = "compositor: the bar is in the interface font: start {start_width} pixels, windows {windows_width}, the widest name {name_width}")
Bar_In_Interface_Font :: struct {
	start_width:   u64,
	windows_width: u64,
	name_width:    u64,
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
@(log_fact = "compositor: the drawing module refused execute_draw_table_in_rectangles_18 (the error kind {error_kind}, the argument {error_argument}): the part of the screen is not drawn. The compositor writes this line one time")
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

// entry_field gives the Text field of a palette entry name.
entry_field :: proc "contextless" (name: string) -> [ENTRY_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, ENTRY_NAME_FIELD_BYTES)
}
