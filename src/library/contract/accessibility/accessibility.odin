// The accessibility contract (src/md/features/accessibility.md): the closed
// WAI-ARIA 1.2 element roles, states, live modes, declared actions, 16-byte
// detail records, and strict border converters shared by writers (the
// interface package) and readers (assistive holders and tests).
//
// This package holds no kernel operation calls and imports no support package.
package accessibility

import "base:intrinsics"
import "modus:contract/draw_record"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Re-export the shared draw-record element types so every writer and reader
// compiles against one single set of closed enums and bounds.
ELEMENT_DEPTH_LIMIT :: draw_record.ELEMENT_DEPTH_LIMIT
ELEMENT_NAME_LIMIT :: draw_record.ELEMENT_NAME_LIMIT
ELEMENT_DETAIL_LIMIT :: draw_record.ELEMENT_DETAIL_LIMIT
ELEMENT_DETAIL_RECORD_SIZE :: draw_record.ELEMENT_DETAIL_RECORD_SIZE
ELEMENT_STATES_VALID_MASK :: draw_record.ELEMENT_STATES_VALID_MASK

Element_Role :: draw_record.Element_Role
Live_Mode :: draw_record.Live_Mode
Toggle_State :: draw_record.Toggle_State
Expanded_State :: draw_record.Expanded_State
Element_State :: draw_record.Element_State
Element_States :: draw_record.Element_States
Element_Detail_Record :: draw_record.Element_Detail_Record

// The standard WAI-ARIA 1.2 name of each concrete element role.
@(rodata)
ELEMENT_ROLE_NAMES := [Element_Role]string {
	.None               = "none",
	.Alert              = "alert",
	.Alert_Dialog       = "alertdialog",
	.Application        = "application",
	.Article            = "article",
	.Banner             = "banner",
	.Blockquote         = "blockquote",
	.Button             = "button",
	.Caption            = "caption",
	.Cell               = "cell",
	.Checkbox           = "checkbox",
	.Code               = "code",
	.Column_Header      = "columnheader",
	.Combobox           = "combobox",
	.Complementary      = "complementary",
	.Content_Info       = "contentinfo",
	.Definition         = "definition",
	.Deletion           = "deletion",
	.Dialog             = "dialog",
	.Directory          = "directory",
	.Document           = "document",
	.Emphasis           = "emphasis",
	.Feed               = "feed",
	.Figure             = "figure",
	.Form               = "form",
	.Generic            = "generic",
	.Grid               = "grid",
	.Grid_Cell          = "gridcell",
	.Group              = "group",
	.Heading            = "heading",
	.Image              = "img",
	.Insertion          = "insertion",
	.Link               = "link",
	.List               = "list",
	.List_Box           = "listbox",
	.List_Item          = "listitem",
	.Log                = "log",
	.Main               = "main",
	.Marquee            = "marquee",
	.Math               = "math",
	.Menu               = "menu",
	.Menu_Bar           = "menubar",
	.Menu_Item          = "menuitem",
	.Menu_Item_Checkbox = "menuitemcheckbox",
	.Menu_Item_Radio    = "menuitemradio",
	.Meter              = "meter",
	.Navigation         = "navigation",
	.Note               = "note",
	.Option             = "option",
	.Paragraph          = "paragraph",
	.Progress_Bar       = "progressbar",
	.Radio              = "radio",
	.Radio_Group        = "radiogroup",
	.Region             = "region",
	.Row                = "row",
	.Row_Group          = "rowgroup",
	.Row_Header         = "rowheader",
	.Scroll_Bar         = "scrollbar",
	.Search             = "search",
	.Search_Box         = "searchbox",
	.Separator          = "separator",
	.Slider             = "slider",
	.Spin_Button        = "spinbutton",
	.Status             = "status",
	.Strong             = "strong",
	.Subscript          = "subscript",
	.Superscript        = "superscript",
	.Switch             = "switch",
	.Tab                = "tab",
	.Tab_List           = "tablist",
	.Tab_Panel          = "tabpanel",
	.Table              = "table",
	.Term               = "term",
	.Text_Box           = "textbox",
	.Time               = "time",
	.Timer              = "timer",
	.Toolbar            = "toolbar",
	.Tooltip            = "tooltip",
	.Tree               = "tree",
	.Tree_Grid          = "treegrid",
	.Tree_Item          = "treeitem",
}

// The closed set of declared actions an element may support. An assistive
// holder acts on an element only through the actions declared in its last frame.
Element_Action :: enum u8 {
	Press            = 0,
	Focus            = 1,
	Increment        = 2,
	Decrement        = 3,
	Set_Value        = 4,
	Insert_Text      = 5,
	Expand           = 6,
	Collapse         = 7,
	Select           = 8,
	Scroll_Into_View = 9,
	Show_Menu        = 10,
	Dismiss          = 11,
}

// A packed set of declared element actions, carried in a 64-bit detail value.
Element_Actions :: bit_set[Element_Action; u64]

// The bit mask of all valid members of Element_Action.
ELEMENT_ACTIONS_VALID_MASK :: u64((u64(1) << (u64(max(Element_Action)) + 1)) - 1)

// The closed set of 16-byte detail kinds attached to an Element_Push in the
// byte table. Value 0 names no detail so a zeroed record is refused.
Element_Detail_Kind :: enum u32 {
	Value_Now         = 1,  // Signed 64-bit integer value in the element's unit.
	Value_Minimum     = 2,  // Signed 64-bit minimum value.
	Value_Maximum     = 3,  // Signed 64-bit maximum value.
	Value_Text        = 4,  // Byte-table UTF-8 range (low 32: first, high 32: count).
	Caret             = 5,  // Character offset of the caret.
	Selection_Start   = 6,  // Character offset of the selection start.
	Selection_End     = 7,  // Character offset of the selection end.
	Description       = 8,  // Byte-table UTF-8 range for accessible description.
	Placeholder       = 9,  // Byte-table UTF-8 range for placeholder text.
	Key_Shortcuts     = 10, // Byte-table UTF-8 range for aria-keyshortcuts.
	Level             = 11, // Positive integer heading or tree level.
	Position_In_Set   = 12, // 1-based position within a set (aria-posinset).
	Set_Size          = 13, // Total count of items in a set (aria-setsize).
	Row_Index         = 14, // 1-based row index (aria-rowindex).
	Row_Count         = 15, // Total row count (aria-rowcount).
	Column_Index      = 16, // 1-based column index (aria-colindex).
	Column_Count      = 17, // Total column count (aria-colcount).
	Row_Span          = 18, // Row span count (aria-rowspan).
	Column_Span       = 19, // Column span count (aria-colspan).
	Orientation       = 20, // Element_Orientation word (aria-orientation).
	Sort              = 21, // Element_Sort word (aria-sort).
	Current           = 22, // Element_Current word (aria-current).
	Has_Popup         = 23, // Element_Popup word (aria-haspopup).
	Auto_Complete     = 24, // Element_Auto_Complete word (aria-autocomplete).
	Relevant          = 25, // Element_Relevant_Set bit mask (aria-relevant).
	Language          = 26, // Byte-table UTF-8 range for BCP 47 locale tag.
	Actions           = 27, // Element_Actions bit mask of declared actions.
	Labelled_By       = 28, // Relation: element word (low 32 bits, high 32 zero).
	Described_By      = 29, // Relation: element word.
	Controls          = 30, // Relation: element word.
	Details           = 31, // Relation: element word.
	Error_Message     = 32, // Relation: element word.
	Flow_To           = 33, // Relation: element word.
	Active_Descendant = 34, // Relation: element word.
}

// WAI-ARIA 1.2 aria-orientation.
Element_Orientation :: enum u8 {
	None       = 0,
	Horizontal = 1,
	Vertical   = 2,
}

// WAI-ARIA 1.2 aria-sort.
Element_Sort :: enum u8 {
	None       = 0,
	Ascending  = 1,
	Descending = 2,
	Other      = 3,
}

// WAI-ARIA 1.2 aria-current.
Element_Current :: enum u8 {
	False    = 0,
	True     = 1,
	Page     = 2,
	Step     = 3,
	Location = 4,
	Date     = 5,
	Time     = 6,
}

// WAI-ARIA 1.2 aria-haspopup.
Element_Popup :: enum u8 {
	False    = 0,
	Menu     = 1,
	List_Box = 2,
	Tree     = 3,
	Grid     = 4,
	Dialog   = 5,
}

// WAI-ARIA 1.2 aria-autocomplete.
Element_Auto_Complete :: enum u8 {
	None   = 0,
	Inline = 1,
	List   = 2,
	Both   = 3,
}

// WAI-ARIA 1.2 aria-relevant flags.
Element_Relevant :: enum u8 {
	Additions = 0,
	Removals  = 1,
	Text      = 2,
}

Element_Relevant_Set :: bit_set[Element_Relevant; u8]

ELEMENT_RELEVANT_VALID_MASK :: u64((u64(1) << (u64(max(Element_Relevant)) + 1)) - 1)

// The longest text carried by a single text detail, in UTF-8 bytes.
ELEMENT_DETAIL_TEXT_LIMIT :: 1024

// Decoded view of one 16-byte Element_Detail_Record past the border.
Element_Detail :: struct {
	kind:  Element_Detail_Kind,
	value: u64, // Signed/unsigned integer, enum word, action mask, or target element word.
	first: u32, // For text-range details: first byte in the byte table.
	count: u32, // For text-range details: byte count in the byte table.
}

// Border converters: each refuses every word or bit that names no member.

element_role_of_word :: proc "contextless" (word: u8) -> (role: Element_Role, ok: bool) {
	return draw_record.element_role_of_word(word)
}

live_mode_of_word :: proc "contextless" (word: u8) -> (mode: Live_Mode, ok: bool) {
	return draw_record.live_mode_of_word(word)
}

toggle_state_of_word :: proc "contextless" (word: u8) -> (state: Toggle_State, ok: bool) {
	return draw_record.toggle_state_of_word(word)
}

expanded_state_of_word :: proc "contextless" (word: u8) -> (state: Expanded_State, ok: bool) {
	return draw_record.expanded_state_of_word(word)
}

element_states_of_word :: proc "contextless" (word: u32) -> (states: Element_States, ok: bool) {
	return draw_record.element_states_of_word(word)
}

element_action_of_word :: proc "contextless" (word: u8) -> (action: Element_Action, ok: bool) {
	return enum_word.member_of_word(Element_Action, u64(word))
}

element_actions_of_word :: proc "contextless" (word: u64) -> (actions: Element_Actions, ok: bool) {
	if word & ~ELEMENT_ACTIONS_VALID_MASK != 0 {
		return {}, false
	}
	return transmute(Element_Actions)word, true
}

element_detail_kind_of_word :: proc "contextless" (word: u32) -> (kind: Element_Detail_Kind, ok: bool) {
	return enum_word.member_of_word(Element_Detail_Kind, u64(word))
}

element_orientation_of_word :: proc "contextless" (word: u64) -> (orientation: Element_Orientation, ok: bool) {
	return enum_word.member_of_word(Element_Orientation, word)
}

element_sort_of_word :: proc "contextless" (word: u64) -> (sort: Element_Sort, ok: bool) {
	return enum_word.member_of_word(Element_Sort, word)
}

element_current_of_word :: proc "contextless" (word: u64) -> (current: Element_Current, ok: bool) {
	return enum_word.member_of_word(Element_Current, word)
}

element_popup_of_word :: proc "contextless" (word: u64) -> (popup: Element_Popup, ok: bool) {
	return enum_word.member_of_word(Element_Popup, word)
}

element_auto_complete_of_word :: proc "contextless" (word: u64) -> (auto_complete: Element_Auto_Complete, ok: bool) {
	return enum_word.member_of_word(Element_Auto_Complete, word)
}

element_relevant_of_word :: proc "contextless" (word: u64) -> (relevant: Element_Relevant_Set, ok: bool) {
	if word & ~ELEMENT_RELEVANT_VALID_MASK != 0 {
		return {}, false
	}
	return transmute(Element_Relevant_Set)u8(word), true
}

// Role classification helpers following WAI-ARIA 1.2.

// element_role_takes_name_from_content reports whether a role derives its
// accessible name from descendant text runs when no explicit name is set
// (WAI-ARIA 1.2, section 5.2.8.4).
element_role_takes_name_from_content :: proc "contextless" (role: Element_Role) -> bool {
	#partial switch role {
	case .Button, .Cell, .Checkbox, .Column_Header, .Grid_Cell, .Heading, .Link, .Menu_Item, .Menu_Item_Checkbox, .Menu_Item_Radio, .Option, .Radio, .Row, .Row_Header, .Switch, .Tab, .Tooltip, .Tree_Item:
		return true
	}
	return false
}

// element_role_default_live_mode gives the implicit politeness of WAI-ARIA 1.2
// live-region roles when the push itself specifies Live_Mode.Off.
element_role_default_live_mode :: proc "contextless" (role: Element_Role) -> Live_Mode {
	#partial switch role {
	case .Alert:
		return .Assertive
	case .Log, .Status:
		return .Polite
	}
	return .Off
}

// element_role_is_pressable reports roles that represent clickable or
// activatable controls requiring keyboard reachability and at least one action.
element_role_is_pressable :: proc "contextless" (role: Element_Role) -> bool {
	#partial switch role {
	case .Button, .Checkbox, .Link, .Menu_Item, .Menu_Item_Checkbox, .Menu_Item_Radio, .Radio, .Switch, .Tab:
		return true
	}
	return false
}

// element_role_is_composite reports container widgets that manage keyboard
// navigation (arrow keys, Enter, Space) for their child items.
element_role_is_composite :: proc "contextless" (role: Element_Role) -> bool {
	#partial switch role {
	case .Combobox, .Grid, .List_Box, .Menu, .Menu_Bar, .Radio_Group, .Tab_List, .Tree, .Tree_Grid:
		return true
	}
	return false
}

// element_detail_kind_is_text_range reports whether a detail stores a byte-table
// range in value_low (first) and value_high (count).
element_detail_kind_is_text_range :: proc "contextless" (kind: Element_Detail_Kind) -> bool {
	#partial switch kind {
	case .Value_Text, .Description, .Placeholder, .Key_Shortcuts, .Language:
		return true
	}
	return false
}

// element_detail_kind_is_relation reports whether a detail names another
// element in the same draw table by its element word.
element_detail_kind_is_relation :: proc "contextless" (kind: Element_Detail_Kind) -> bool {
	#partial switch kind {
	case .Labelled_By, .Described_By, .Controls, .Details, .Error_Message, .Flow_To, .Active_Descendant:
		return true
	}
	return false
}

// Constructors for 16-byte Element_Detail_Record entries.

detail_unsigned_record :: proc "contextless" (kind: Element_Detail_Kind, value: u64) -> Element_Detail_Record {
	return {
		kind       = u32(kind),
		reserved   = 0,
		value_low  = u32(value & 0xFFFF_FFFF),
		value_high = u32(value >> 32),
	}
}

detail_integer_record :: proc "contextless" (kind: Element_Detail_Kind, value: i64) -> Element_Detail_Record {
	return detail_unsigned_record(kind, u64(value))
}

detail_range_record :: proc "contextless" (kind: Element_Detail_Kind, first, count: u32) -> Element_Detail_Record {
	return {
		kind       = u32(kind),
		reserved   = 0,
		value_low  = count == 0 ? 0 : first,
		value_high = count,
	}
}

detail_actions_record :: proc "contextless" (actions: Element_Actions) -> Element_Detail_Record {
	return detail_unsigned_record(.Actions, transmute(u64)actions)
}

detail_relation_record :: proc "contextless" (kind: Element_Detail_Kind, target_element: u32) -> Element_Detail_Record {
	return {
		kind       = u32(kind),
		reserved   = 0,
		value_low  = target_element,
		value_high = 0,
	}
}

detail_orientation_record :: proc "contextless" (orientation: Element_Orientation) -> Element_Detail_Record {
	return detail_unsigned_record(.Orientation, u64(orientation))
}

detail_sort_record :: proc "contextless" (sort: Element_Sort) -> Element_Detail_Record {
	return detail_unsigned_record(.Sort, u64(sort))
}

detail_current_record :: proc "contextless" (current: Element_Current) -> Element_Detail_Record {
	return detail_unsigned_record(.Current, u64(current))
}

detail_popup_record :: proc "contextless" (popup: Element_Popup) -> Element_Detail_Record {
	return detail_unsigned_record(.Has_Popup, u64(popup))
}

detail_auto_complete_record :: proc "contextless" (auto_complete: Element_Auto_Complete) -> Element_Detail_Record {
	return detail_unsigned_record(.Auto_Complete, u64(auto_complete))
}

detail_relevant_record :: proc "contextless" (relevant: Element_Relevant_Set) -> Element_Detail_Record {
	return detail_unsigned_record(.Relevant, u64(transmute(u8)relevant))
}

// detail_record_copy_from_bytes reads one 16-byte detail record once from a
// byte slice using volatile loads so concurrent writes in shared memory cannot
// split a check, without requiring the slice base address to be 4-byte aligned.
detail_record_copy_from_bytes :: proc "contextless" (bytes: []u8) -> Element_Detail_Record {
	if uintptr(raw_data(bytes)) % align_of(Element_Detail_Record) == 0 {
		return detail_record_copy_once((^Element_Detail_Record)(raw_data(bytes)))
	}
	raw: [ELEMENT_DETAIL_RECORD_SIZE]u8
	for i in 0 ..< ELEMENT_DETAIL_RECORD_SIZE {
		raw[i] = intrinsics.volatile_load(&bytes[i])
	}
	return transmute(Element_Detail_Record)raw
}

// detail_record_copy_once reads one 16-byte detail record once with volatile
// loads so concurrent modification in shared memory cannot split a check.
detail_record_copy_once :: proc "contextless" (record: ^Element_Detail_Record) -> Element_Detail_Record {
	words := intrinsics.volatile_load((^[4]u32)(record))
	return {kind = words[0], reserved = words[1], value_low = words[2], value_high = words[3]}
}

// element_detail_read validates one 16-byte Element_Detail_Record against the
// closed enum, reserved-zero, range, UTF-8, and relation rules.
element_detail_read :: proc "contextless" (raw: Element_Detail_Record, byte_table: []u8) -> (detail: Element_Detail, refusal: Semantic_Tree_Refusal) {
	if raw.reserved != 0 {
		return {}, .Detail_Invalid
	}
	kind, kind_ok := element_detail_kind_of_word(raw.kind)
	if !kind_ok {
		return {}, .Detail_Invalid
	}
	value := u64(raw.value_low) | (u64(raw.value_high) << 32)
	switch kind {
	case .Value_Now, .Value_Minimum, .Value_Maximum, .Caret, .Selection_Start, .Selection_End, .Level, .Position_In_Set, .Set_Size, .Row_Index, .Row_Count, .Column_Index, .Column_Count, .Row_Span, .Column_Span:
		return {kind = kind, value = value}, .None
	case .Value_Text, .Description, .Placeholder, .Key_Shortcuts, .Language:
		first := raw.value_low
		count := raw.value_high
		if count > ELEMENT_DETAIL_TEXT_LIMIT {
			return {}, .Detail_Invalid
		}
		if count == 0 && first != 0 {
			return {}, .Detail_Invalid
		}
		if u64(first) + u64(count) > u64(len(byte_table)) {
			return {}, .Detail_Range_Out_Of_Bounds
		}
		if count > 0 && !text_encoding.text_valid(byte_table[first:][:count]) {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value, first = first, count = count}, .None
	case .Orientation:
		if _, ok := element_orientation_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Sort:
		if _, ok := element_sort_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Current:
		if _, ok := element_current_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Has_Popup:
		if _, ok := element_popup_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Auto_Complete:
		if _, ok := element_auto_complete_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Relevant:
		if _, ok := element_relevant_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Actions:
		if _, ok := element_actions_of_word(value); !ok {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = value}, .None
	case .Labelled_By, .Described_By, .Controls, .Details, .Error_Message, .Flow_To, .Active_Descendant:
		if raw.value_high != 0 || raw.value_low == 0 {
			return {}, .Detail_Invalid
		}
		return {kind = kind, value = u64(raw.value_low)}, .None
	}
	return {}, .Detail_Invalid
}
