package browser

import "modus:contract/draw_record"
import "modus:contract/html_css"
import "modus:graphics"
import "modus:interface"

// The workspace of the document of the page that the window shows: the
// origin worker parses it with html_css, resolves its styles, lays out its
// boxes and paints them as draw records (src/md/features/
// desktop_to_browser.md, "E. A light browser"). The records are in the
// places of the document; each frame copies the ones that the view shows
// into the draw table of the window, moved by the scroll. Each table is a
// global: the tree, the style sheet and the boxes are far larger than a
// stack frame should hold.

document_tree: html_css.Dom_Tree
sheet: html_css.Css_Stylesheet
document_layout: html_css.Layout_Tree

// The key of the style sheet in the workspace: the origin that parsed it,
// and the hash of its style text. The origin worker reuses the sheet only
// for that origin and that text.
sheet_valid: bool
sheet_origin: html_css.Document_Origin
sheet_source_hash: u64

// A box paints at most a rectangle, the four sides of its border, and a
// text.
DOCUMENT_RECORD_CAPACITY :: 4 * html_css.MAX_DOM_NODES
document_records: [DOCUMENT_RECORD_CAPACITY]draw_record.Draw_Record
document_record_count: int
document_text: [html_css.MAX_TEXT_POOL]u8
document_text_count: int

// The width at which the boxes were laid out last, and the height of the
// document at that width. A frame lays the document out again only when
// the width of the view changes.
laid_out_width: i32 = -1
document_height: int
document_background: draw_record.Draw_Color

// What a press on a node does: each node of a link, and each node of a
// button inside a form, has a target, which its descendants share.
Target_Kind :: enum u8 {
	None,
	Link, // node: the element a with its href.
	Submit, // node: the form that the button sends.
}

Node_Target :: struct {
	kind: Target_Kind,
	node: u16,
}

node_targets: [html_css.MAX_DOM_NODES]Node_Target
// The form that holds each node, or html_css.NO_NODE.
node_forms: [html_css.MAX_DOM_NODES]u16

// A text field of a form: an element input with a name. The window draws
// an editable field of the interface package over its document box.
FORM_FIELD_CAPACITY :: 4
FIELD_TEXT_CAPACITY :: 60
FIELD_NAME_CAPACITY :: 32

Form_Field :: struct {
	node:       u16,
	form:       u16,
	box:        u16, // Its document box, html_css.NO_NODE when the layout gave it none.
	name:       [FIELD_NAME_CAPACITY]u8,
	name_count: int,
	text:       [FIELD_TEXT_CAPACITY]u8,
	count:      int,
}

form_fields: [FORM_FIELD_CAPACITY]Form_Field
form_field_count: int

// document_workspace_clear wipes the workspace of the document: the
// records, their text, the targets and the fields of the page before.
// The style sheet keeps its key, which names its origin.
document_workspace_clear :: proc "contextless" () {
	document_tree = {}
	document_layout = {}
	document_records = {}
	document_record_count = 0
	document_text = {}
	document_text_count = 0
	node_targets = {}
	node_forms = {}
	form_fields = {}
	form_field_count = 0
	document_height = 0
	document_background = 0
	laid_out_width = -1
}

// document_targets_read reads the targets and the form fields of the
// parsed document.
document_targets_read :: proc "contextless" () {
	// The nodes are in pre-order: a parent comes before each child, so one
	// pass gives each node the target and the form of its parent.
	for index in 0 ..< int(document_tree.node_count) {
		node := &document_tree.nodes[index]
		parent := node.parent
		target := Node_Target{}
		form := html_css.NO_NODE
		if parent != html_css.NO_NODE && int(parent) < index {
			target = node_targets[parent]
			form = node_forms[parent]
		}
		if node.kind == .Element {
			if node.tag == .Form {
				form = u16(index)
			} else if node.tag == .A {
				if _, has_href := html_css.dom_node_attr(&document_tree, u16(index), "href"); has_href {
					target = {kind = .Link, node = u16(index)}
				}
			} else if node.tag == .Button && form != html_css.NO_NODE {
				target = {kind = .Submit, node = form}
			}
		}
		node_targets[index] = target
		node_forms[index] = form
	}
	form_field_count = 0
	for index in 0 ..< int(document_tree.node_count) {
		node := &document_tree.nodes[index]
		if node.kind != .Element || node.tag != .Input || form_field_count >= FORM_FIELD_CAPACITY {
			continue
		}
		name, named := html_css.dom_node_attr(&document_tree, u16(index), "name")
		if !named || len(name) == 0 || len(name) > FIELD_NAME_CAPACITY {
			continue
		}
		field := &form_fields[form_field_count]
		field^ = {node = u16(index), form = node_forms[index], box = html_css.NO_NODE}
		field.name_count = copy(field.name[:], name)
		if value, has_value := html_css.dom_node_attr(&document_tree, u16(index), "value"); has_value {
			field.count = copy(field.text[:], value)
		}
		form_field_count += 1
	}
	laid_out_width = -1
}

// document_lay_out lays the document out at the width of the view, and
// paints its boxes into the records of the document.
document_lay_out :: proc "contextless" (width, height: i32) {
	if width == laid_out_width {
		return
	}
	laid_out_width = width
	html_css.compute_layout(&document_tree, &sheet, width, height, &document_layout)
	document_record_count, document_text_count = html_css.emit_draw_records(&document_tree, &document_layout, document_records[:], document_text[:])
	document_height = 0
	document_background = 0
	for index in 0 ..< int(document_layout.box_count) {
		box := &document_layout.boxes[index]
		if !box.used {
			continue
		}
		document_height = max(document_height, int(box.y + box.height + box.style.margin_bottom))
		if !box.is_text && document_tree.nodes[box.node_index].tag == .Body {
			document_background = box.style.background_color
		}
	}
	for &field in form_fields[:form_field_count] {
		field.box = html_css.NO_NODE
		for index in 0 ..< int(document_layout.box_count) {
			if document_layout.boxes[index].used && document_layout.boxes[index].node_index == field.node {
				field.box = u16(index)
				break
			}
		}
	}
}

// document_title gives the text of the element title, or "".
document_title :: proc "contextless" () -> string {
	for index in 0 ..< int(document_tree.node_count) {
		node := &document_tree.nodes[index]
		if node.kind == .Element && node.tag == .Title && node.first_child != html_css.NO_NODE {
			return string(html_css.dom_node_text(&document_tree, node.first_child))
		}
	}
	return ""
}

// target_at gives the target of the box on top at a place of the document:
// the boxes are in pre-order, so the last box that holds the place is the
// one drawn over the others.
target_at :: proc "contextless" (x, y: int) -> (target: Node_Target) {
	for index in 0 ..< int(document_layout.box_count) {
		box := &document_layout.boxes[index]
		if !box.used || int(box.node_index) >= int(document_tree.node_count) {
			continue
		}
		candidate := node_targets[box.node_index]
		if candidate.kind == .None {
			continue
		}
		if x >= int(box.x) && x < int(box.x + box.width) && y >= int(box.y) && y < int(box.y + box.height) {
			target = candidate
		}
	}
	return
}

// document_paint copies the records of the document that the view shows
// into the draw table of the window, moved by the scroll, inside a clip of
// the view. The text of the cells is as wide as html_css measures it, half
// its size for each byte, so a text box of several lines takes its lines
// in that width.
document_paint :: proc "contextless" (table: ^interface.Draw_Table, view: interface.Area, scroll: int, page_color: graphics.Color) {
	interface.draw_clip_push(table, view.x, view.y, view.width, view.height)
	defer interface.draw_clip_pop(table)
	if document_background != 0 {
		interface.draw_rectangle_with_alpha(table, view.x, view.y, view.width, view.height, document_background)
	} else {
		interface.draw_rectangle(table, view.x, view.y, view.width, view.height, page_color)
	}
	for record in document_records[:document_record_count] {
		primitive, problem := draw_record.read(record)
		if problem != .None {
			continue
		}
		left := draw_record.pixels_floor(record.left)
		top := draw_record.pixels_floor(record.top)
		width := draw_record.pixels_ceiling(record.right) - left
		height := draw_record.pixels_ceiling(record.bottom) - top
		x := view.x + left
		y := view.y + top - scroll
		if y + height <= view.y || y >= view.y + view.height || width <= 0 || height <= 0 {
			continue
		}
		switch fields in primitive {
		case draw_record.Draw_Rectangle:
			interface.draw_rectangle_with_alpha(table, x, y, width, height, fields.color)
		case draw_record.Draw_Text:
			if int(fields.first) + int(fields.count) > document_text_count {
				continue
			}
			text := string(document_text[fields.first:fields.first + fields.count])
			node := u16(record.element - 1)
			underline := int(node) < int(document_tree.node_count) && node_targets[node].kind == .Link
			text_paint(table, x, y, width, height, text, fields, underline)
		case draw_record.Draw_Nothing, draw_record.Draw_Gradient, draw_record.Draw_Clip_Push, draw_record.Draw_Clip_Pop, draw_record.Draw_Element_Push, draw_record.Draw_Element_Pop, draw_record.Draw_Picture, draw_record.Draw_Text_Grid, draw_record.Draw_Path:
			// html_css paints rectangles and texts only.
		}
	}
}

// text_paint draws a text of the document in the font of the cells at its
// size, in the lines that its box holds: at the spaces when the lines fit
// in the box, else at the width of the box, as html_css counted them.
text_paint :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, text: string, fields: draw_record.Draw_Text, underline: bool) {
	font := interface.Font{kind = .Cells_8x16, size = clamp(fields.size, draw_record.TEXT_SIZE_MINIMUM, draw_record.TEXT_SIZE_LIMIT)}
	line_height := int(font.size) / draw_record.UNITS_PER_PIXEL
	cell_width := max(interface.cell_width_of(font), 1)
	columns := max(width / cell_width, 1)
	lines := max(height / max(line_height, 1), 1)
	break_at_spaces := wrapped_line_count(text, columns, true) <= lines
	rest := text
	line_y := y
	for line in 0 ..< lines {
		if len(rest) == 0 {
			break
		}
		part := rest
		if line < lines - 1 || len(rest) > columns {
			part, rest = wrap_line(rest, columns, break_at_spaces)
		} else {
			rest = ""
		}
		end := interface.draw_text_with_alpha(table, x, line_y, part, fields.color, font)
		if underline {
			interface.draw_rectangle_with_alpha(table, x, line_y + line_height - 1, end - x, 1, fields.color)
		}
		line_y += line_height
	}
}

// wrap_line cuts the first line of a text at most columns bytes long: at
// the last space in it when spaces is true and one is there, else at the
// width. The spaces at the cut go to neither line.
wrap_line :: proc "contextless" (text: string, columns: int, spaces: bool) -> (line: string, rest: string) {
	if len(text) <= columns {
		return text, ""
	}
	cut := columns
	if spaces {
		for place := columns; place > 0; place -= 1 {
			if text[place] == ' ' {
				cut = place
				break
			}
		}
	}
	line, rest = text[:cut], text[cut:]
	for len(rest) > 0 && rest[0] == ' ' {
		rest = rest[1:]
	}
	return
}

wrapped_line_count :: proc "contextless" (text: string, columns: int, spaces: bool) -> (count: int) {
	rest := text
	for len(rest) > 0 {
		_, rest = wrap_line(rest, columns, spaces)
		count += 1
	}
	return
}
