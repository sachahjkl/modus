// Semantic element records in the draw table (src/md/features/accessibility.md,
// "1. The semantic tree"): the closed WAI-ARIA 1.2 element roles, states,
// live modes, tristate toggles and expanded states, the fields of an
// Element_Push record, the 16-byte detail record, and the unified order
// border of clips and elements.
package draw_record

import "base:intrinsics"
import "modus:contract/enum_word"

// The most nested element pushes open at one time: a bound of cost for the
// reader stack, as CLIP_DEPTH_LIMIT is for clips.
ELEMENT_DEPTH_LIMIT :: 32

// The longest explicit accessible name in an Element_Push, in UTF-8 bytes.
ELEMENT_NAME_LIMIT :: 256

// The most 16-byte detail entries attached to one Element_Push.
ELEMENT_DETAIL_LIMIT :: 32

// The byte size of one Element_Detail_Record in the byte table.
ELEMENT_DETAIL_RECORD_SIZE :: 16

// The concrete element roles of WAI-ARIA 1.2, section 5.4, in the order of
// the standard, with no abstract role. Value 0 is None (presentation).
Element_Role :: enum u8 {
	None               = 0,  // presentation / none
	Alert              = 1,  // alert
	Alert_Dialog       = 2,  // alertdialog
	Application        = 3,  // application
	Article            = 4,  // article
	Banner             = 5,  // banner
	Blockquote         = 6,  // blockquote
	Button             = 7,  // button
	Caption            = 8,  // caption
	Cell               = 9,  // cell
	Checkbox           = 10, // checkbox
	Code               = 11, // code
	Column_Header      = 12, // columnheader
	Combobox           = 13, // combobox
	Complementary      = 14, // complementary
	Content_Info       = 15, // contentinfo
	Definition         = 16, // definition
	Deletion           = 17, // deletion
	Dialog             = 18, // dialog
	Directory          = 19, // directory
	Document           = 20, // document
	Emphasis           = 21, // emphasis
	Feed               = 22, // feed
	Figure             = 23, // figure
	Form               = 24, // form
	Generic            = 25, // generic
	Grid               = 26, // grid
	Grid_Cell          = 27, // gridcell
	Group              = 28, // group
	Heading            = 29, // heading
	Image              = 30, // img
	Insertion          = 31, // insertion
	Link               = 32, // link
	List               = 33, // list
	List_Box           = 34, // listbox
	List_Item          = 35, // listitem
	Log                = 36, // log
	Main               = 37, // main
	Marquee            = 38, // marquee
	Math               = 39, // math
	Menu               = 40, // menu
	Menu_Bar           = 41, // menubar
	Menu_Item          = 42, // menuitem
	Menu_Item_Checkbox = 43, // menuitemcheckbox
	Menu_Item_Radio    = 44, // menuitemradio
	Meter              = 45, // meter
	Navigation         = 46, // navigation
	Note               = 47, // note
	Option             = 48, // option
	Paragraph          = 49, // paragraph
	Progress_Bar       = 50, // progressbar
	Radio              = 51, // radio
	Radio_Group        = 52, // radiogroup
	Region             = 53, // region
	Row                = 54, // row
	Row_Group          = 55, // rowgroup
	Row_Header         = 56, // rowheader
	Scroll_Bar         = 57, // scrollbar
	Search             = 58, // search
	Search_Box         = 59, // searchbox
	Separator          = 60, // separator
	Slider             = 61, // slider
	Spin_Button        = 62, // spinbutton
	Status             = 63, // status
	Strong             = 64, // strong
	Subscript          = 65, // subscript
	Superscript        = 66, // superscript
	Switch             = 67, // switch
	Tab                = 68, // tab
	Tab_List           = 69, // tablist
	Tab_Panel          = 70, // tabpanel
	Table              = 71, // table
	Term               = 72, // term
	Text_Box           = 73, // textbox
	Time               = 74, // time
	Timer              = 75, // timer
	Toolbar            = 76, // toolbar
	Tooltip            = 77, // tooltip
	Tree               = 78, // tree
	Tree_Grid          = 79, // treegrid
	Tree_Item          = 80, // treeitem
}

// The politeness of a live region (aria-live).
Live_Mode :: enum u8 {
	Off       = 0, // Not a live region unless its role implies one.
	Polite    = 1, // Announced after the utterance in progress.
	Assertive = 2, // Announced at once.
}

// The tristate value of aria-checked or aria-pressed, as the role selects.
Toggle_State :: enum u8 {
	None  = 0, // Not a toggle element.
	False = 1, // Not checked or not pressed.
	True  = 2, // Checked or pressed.
	Mixed = 3, // Partially checked or partially pressed.
}

// The disclosure state of aria-expanded.
Expanded_State :: enum u8 {
	None      = 0, // Not expandable.
	Collapsed = 1, // Collapsed.
	Expanded  = 2, // Expanded.
}

// The boolean states and properties of WAI-ARIA 1.2 plus the three platform
// states of Core Accessibility API Mappings (Focusable, Focused, Protected).
Element_State :: enum u8 {
	Busy            = 0,  // aria-busy
	Disabled        = 1,  // aria-disabled
	Hidden          = 2,  // aria-hidden
	Invalid         = 3,  // aria-invalid
	Modal           = 4,  // aria-modal
	Multiline       = 5,  // aria-multiline
	Multiselectable = 6,  // aria-multiselectable
	Read_Only       = 7,  // aria-readonly
	Required        = 8,  // aria-required
	Selected        = 9,  // aria-selected
	Atomic          = 10, // aria-atomic
	Focusable       = 11, // Element can take keyboard focus.
	Focused         = 12, // Element currently holds keyboard focus.
	Protected       = 13, // Passphrase or secret field: value, caret and length are absent.
}

// A packed set of element states, carried in a 32-bit word.
Element_States :: bit_set[Element_State; u32]

// The bit mask of all valid members of Element_State.
ELEMENT_STATES_VALID_MASK :: u32((u64(1) << (u64(max(Element_State)) + 1)) - 1)

// The fields of an Element_Push record, 24 bytes at offset 24 of Draw_Record.
Element_Push_Fields :: struct {
	role:            u8,  // The word of an Element_Role.
	live:            u8,  // The word of a Live_Mode.
	toggle:          u8,  // The word of a Toggle_State.
	expanded:        u8,  // The word of an Expanded_State.
	states:          u32, // The packed bits of Element_States; unknown bits are refused.
	name_first:      u32, // First byte of explicit UTF-8 accessible name in byte table; 0 when name_count is 0.
	name_count:      u16, // Byte count of accessible name, at most ELEMENT_NAME_LIMIT; 0 takes name from content.
	name_reserved:   u16, // 0.
	detail_first:    u32, // First byte of Element_Detail_Record entries in byte table, multiple of 4; 0 when detail_count is 0.
	detail_count:    u16, // Count of 16-byte detail entries, at most ELEMENT_DETAIL_LIMIT.
	detail_reserved: u16, // 0.
}

#assert(size_of(Element_Push_Fields) == FIELDS_SIZE)
#assert(offset_of(Element_Push_Fields, role) == 0)
#assert(offset_of(Element_Push_Fields, live) == 1)
#assert(offset_of(Element_Push_Fields, toggle) == 2)
#assert(offset_of(Element_Push_Fields, expanded) == 3)
#assert(offset_of(Element_Push_Fields, states) == 4)
#assert(offset_of(Element_Push_Fields, name_first) == 8)
#assert(offset_of(Element_Push_Fields, name_count) == 12)
#assert(offset_of(Element_Push_Fields, name_reserved) == 14)
#assert(offset_of(Element_Push_Fields, detail_first) == 16)
#assert(offset_of(Element_Push_Fields, detail_count) == 20)
#assert(offset_of(Element_Push_Fields, detail_reserved) == 22)

// One 16-byte detail record in the byte table, 4-byte aligned so it shares
// the alignment rule of cells and path points in Draw_Table.text.
Element_Detail_Record :: struct {
	kind:       u32, // The word of an accessibility.Element_Detail_Kind; 0 names no detail.
	reserved:   u32, // 0.
	value_low:  u32, // Low 32 bits of the 64-bit value, or first byte of a text range.
	value_high: u32, // High 32 bits of the 64-bit value, or byte count of a text range.
}

#assert(size_of(Element_Detail_Record) == ELEMENT_DETAIL_RECORD_SIZE)
#assert(align_of(Element_Detail_Record) == 4)

// An Element_Push past the border: each word is its closed enum or bit set.
Draw_Element_Push :: struct {
	role:         Element_Role,
	live:         Live_Mode,
	toggle:       Toggle_State,
	expanded:     Expanded_State,
	states:       Element_States,
	name_first:   u32,
	name_count:   u16,
	detail_first: u32,
	detail_count: u16,
}

// An Element_Pop past the border: no fields, box of zeros.
Draw_Element_Pop :: struct {}

// element_role_of_word reads a byte as an Element_Role, refusing any unknown value.
element_role_of_word :: proc "contextless" (word: u8) -> (role: Element_Role, ok: bool) {
	return enum_word.member_of_word(Element_Role, u64(word))
}

// live_mode_of_word reads a byte as a Live_Mode, refusing any unknown value.
live_mode_of_word :: proc "contextless" (word: u8) -> (mode: Live_Mode, ok: bool) {
	return enum_word.member_of_word(Live_Mode, u64(word))
}

// toggle_state_of_word reads a byte as a Toggle_State, refusing any unknown value.
toggle_state_of_word :: proc "contextless" (word: u8) -> (state: Toggle_State, ok: bool) {
	return enum_word.member_of_word(Toggle_State, u64(word))
}

// expanded_state_of_word reads a byte as an Expanded_State, refusing any unknown value.
expanded_state_of_word :: proc "contextless" (word: u8) -> (state: Expanded_State, ok: bool) {
	return enum_word.member_of_word(Expanded_State, u64(word))
}

// element_states_of_word reads a 32-bit word as Element_States, refusing any unknown bit.
element_states_of_word :: proc "contextless" (word: u32) -> (states: Element_States, ok: bool) {
	if word & ~ELEMENT_STATES_VALID_MASK != 0 {
		return {}, false
	}
	return transmute(Element_States)word, true
}

// Why the unified border of the order of clips and elements refuses a table.
// Values 0 to 3 match Clip_Order_Problem so existing error reporting keeps
// one numbering for clip and element nesting faults.
Table_Order_Problem :: enum u8 {
	None                  = 0, // Each clip and element push is balanced, within depth limits, and records match their innermost element.
	Pop_Without_Push      = 1, // A Clip_Pop or Element_Pop with no push open.
	Push_Past_Depth_Limit = 2, // A Clip_Push past CLIP_DEPTH_LIMIT or an Element_Push past ELEMENT_DEPTH_LIMIT.
	Push_Without_Pop      = 3, // The table ends with a Clip_Push or Element_Push open.
	Pop_Wrong_Kind        = 4, // A Clip_Pop tried to close an Element_Push, or an Element_Pop tried to close a Clip_Push.
	Element_Word_Mismatch = 5, // A record under an open Element_Push carried an element word other than 0 or the innermost push's word.
	Element_Word_Zero     = 6, // An Element_Push carried element word 0.
}

@(private = "file")
Order_Entry_Kind :: enum u8 {
	Clip,
	Element,
}

@(private = "file")
Order_Entry :: struct {
	kind:    Order_Entry_Kind,
	element: u32, // Element word for .Element entries; 0 for .Clip.
}

// table_order_check is the unified border of the order of clips and elements
// in a draw table. It loads the kind and element word of each record once
// and checks that:
// - clips and elements nest strictly in one stack (no interleaved pop),
// - clip depth never exceeds CLIP_DEPTH_LIMIT and element depth never exceeds ELEMENT_DEPTH_LIMIT,
// - every Element_Push has a non-zero element word,
// - every record under an open Element_Push carries either 0 or the innermost open Element_Push's element word,
// - no push remains open at the end of the table (reporting the outermost open push index).
table_order_check :: proc "contextless" (records: []Draw_Record) -> (problem: Table_Order_Problem, index: int) {
	stack: [CLIP_DEPTH_LIMIT + ELEMENT_DEPTH_LIMIT]Order_Entry
	stack_depth := 0
	clip_depth := 0
	element_depth := 0
	current_element: u32 = 0
	outermost := 0

	for place in 0 ..< len(records) {
		// One 64-bit volatile load captures kind (byte 0) and element (bytes 4..7) together.
		header := intrinsics.volatile_load((^u64)(&records[place]))
		kind_word := u8(header & 0xFF)
		element_word := u32(header >> 32)
		kind, known := draw_kind_of_word(kind_word)
		if !known {
			if element_depth > 0 && element_word != 0 && element_word != current_element {
				return .Element_Word_Mismatch, place
			}
			continue
		}
		switch kind {
		case .Clip_Push:
			if element_depth > 0 && element_word != 0 && element_word != current_element {
				return .Element_Word_Mismatch, place
			}
			if clip_depth >= CLIP_DEPTH_LIMIT {
				return .Push_Past_Depth_Limit, place
			}
			if stack_depth == 0 {
				outermost = place
			}
			stack[stack_depth] = {kind = .Clip}
			stack_depth += 1
			clip_depth += 1
		case .Clip_Pop:
			if stack_depth == 0 {
				return .Pop_Without_Push, place
			}
			if stack[stack_depth - 1].kind != .Clip {
				return .Pop_Wrong_Kind, place
			}
			if element_depth > 0 && element_word != 0 && element_word != current_element {
				return .Element_Word_Mismatch, place
			}
			stack_depth -= 1
			clip_depth -= 1
		case .Element_Push:
			if element_word == 0 {
				return .Element_Word_Zero, place
			}
			if element_depth >= ELEMENT_DEPTH_LIMIT {
				return .Push_Past_Depth_Limit, place
			}
			if stack_depth == 0 {
				outermost = place
			}
			stack[stack_depth] = {kind = .Element, element = element_word}
			stack_depth += 1
			element_depth += 1
			current_element = element_word
		case .Element_Pop:
			if stack_depth == 0 {
				return .Pop_Without_Push, place
			}
			if stack[stack_depth - 1].kind != .Element {
				return .Pop_Wrong_Kind, place
			}
			if element_word != 0 && element_word != current_element {
				return .Element_Word_Mismatch, place
			}
			stack_depth -= 1
			element_depth -= 1
			current_element = 0
			for i := stack_depth - 1; i >= 0; i -= 1 {
				if stack[i].kind == .Element {
					current_element = stack[i].element
					break
				}
			}
		case .None, .Rectangle, .Text, .Picture, .Text_Grid, .Gradient, .Path:
			if element_depth > 0 && element_word != 0 && element_word != current_element {
				return .Element_Word_Mismatch, place
			}
		}
	}
	if stack_depth != 0 {
		return .Push_Without_Pop, outermost
	}
	return .None, 0
}
