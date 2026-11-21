// The layout of a diagram of a guide (docs/SITE.md, "The diagrams"): each
// text measured with the advances and the pairs of the font that the site
// serves for the diagrams, each box sized from its text, then a layered
// layout for a flowchart and columns and rows for a sequence diagram. The
// result is a picture of boxes and lines in whole pixels, which the writer
// turns into SVG and the tests check: no two boxes overlap, each text is
// inside its box, each line ends at its two boxes.
package site

import "core:fmt"
import "core:slice"
import "core:strings"
import "modus:vector_font"
import "modustool:resources"

// The font of the text of the diagrams: the interface font of the system,
// which the site serves, so its advances are known when the tool lays out
// a diagram. The reading font of a page is the font of the system of the
// reader, whose advances no build can know.
SITE_DIAGRAM_FONT_SOURCE :: resources.VECTOR_FONT_FOLDER + "/" + resources.INTERFACE_VECTOR_FONT + ".ttf"
SITE_DIAGRAM_FONT_SIZE :: 14
SITE_DIAGRAM_LINE_HEIGHT :: 20 // The least height of a line of text; a font with a taller ascent and descent gets more.

// The sizes of the layout, in pixels of the picture.
SITE_DIAGRAM_MARGIN :: 8
SITE_DIAGRAM_NODE_LABEL_LIMIT :: 176 // A longer label of a node wraps onto more lines.
SITE_DIAGRAM_NODE_PADDING_X :: 12
SITE_DIAGRAM_NODE_PADDING_Y :: 8
SITE_DIAGRAM_GROUP_LABEL_LIMIT :: 160
SITE_DIAGRAM_GROUP_PADDING :: 12
SITE_DIAGRAM_GROUP_NODE_GAP :: 12
SITE_DIAGRAM_EDGE_LABEL_LIMIT :: 160
SITE_DIAGRAM_LABEL_PADDING_X :: 4
SITE_DIAGRAM_LABEL_PADDING_Y :: 2
SITE_DIAGRAM_UNIT_GAP :: 24 // Between two units of one rank.
SITE_DIAGRAM_RANK_GAP :: 24 // Between two ranks.
SITE_DIAGRAM_ARROW_STUB :: 12 // The straight part of an edge before its target, under its arrow head.
SITE_DIAGRAM_ARROW_LENGTH :: 8
SITE_DIAGRAM_ARROW_HALF_WIDTH :: 4
SITE_DIAGRAM_ORDER_SWEEPS :: 8 // The passes of the barycenter that order the ranks: down, up, down...
SITE_DIAGRAM_PLACEMENT_ROUNDS :: 4 // The passes that move each unit toward its neighbours.
SITE_DIAGRAM_PARTICIPANT_LABEL_LIMIT :: 160
SITE_DIAGRAM_PARTICIPANT_GAP :: 24
SITE_DIAGRAM_MESSAGE_LABEL_LIMIT :: 320
SITE_DIAGRAM_MESSAGE_LABEL_PADDING :: 8 // Between a text of a message and a lifeline.
SITE_DIAGRAM_SELF_LABEL_LIMIT :: 240
SITE_DIAGRAM_SELF_LOOP_WIDTH :: 24
SITE_DIAGRAM_SELF_LOOP_LEAST_HEIGHT :: 16
SITE_DIAGRAM_MESSAGE_GAP :: 12
SITE_DIAGRAM_ARROW_GAP :: 4 // Between the box of a text of a message and its arrow.

Site_Diagram_Font :: struct {
	file:        vector_font.Font_File,
	pairs:       vector_font.Pair_Table,
	line_height: int,
	baseline:    int, // From the top of a line to its baseline.
}

site_diagram_ceiling_divide :: proc(value, divisor: int) -> int {
	return (value + divisor - 1) / divisor
}

// site_diagram_font_open reads the font of the diagrams from its bytes,
// which the font keeps.
site_diagram_font_open :: proc(bytes: []u8) -> (font: Site_Diagram_Font, problem: string) {
	file, file_problem := vector_font.font_open(bytes)
	if file_problem != .None {
		return {}, fmt.tprintf("the font of the diagrams %s: %s", SITE_DIAGRAM_FONT_SOURCE, vector_font.font_problem_names[file_problem])
	}
	if file.units_per_em <= 0 {
		return {}, fmt.tprintf("the font of the diagrams %s has no units in its em", SITE_DIAGRAM_FONT_SOURCE)
	}
	pairs, pairs_problem := vector_font.pair_table_open(&file)
	if pairs_problem != .None {
		return {}, fmt.tprintf("the pairs of the font of the diagrams %s: %s", SITE_DIAGRAM_FONT_SOURCE, vector_font.font_problem_names[pairs_problem])
	}
	font.file = file
	font.pairs = pairs
	ascent := site_diagram_ceiling_divide(max(file.ascender, 0) * SITE_DIAGRAM_FONT_SIZE, file.units_per_em)
	descent := site_diagram_ceiling_divide(abs(file.descender) * SITE_DIAGRAM_FONT_SIZE, file.units_per_em)
	font.line_height = max(SITE_DIAGRAM_LINE_HEIGHT, ascent + descent)
	font.baseline = (font.line_height - ascent - descent) / 2 + ascent
	return font, ""
}

// site_diagram_text_width gives the width of a line of text in pixels,
// rounded up: the advances and the pair adjustments of the font, as a
// browser sets the line with its kerning.
site_diagram_text_width :: proc(font: ^Site_Diagram_Font, text: string) -> int {
	units := 0
	previous: rune = -1
	for character in text {
		units += vector_font.character_advance(&font.file, character)
		if previous >= 0 {
			units += vector_font.character_pair_adjustment(&font.file, &font.pairs, previous, character)
		}
		previous = character
	}
	return site_diagram_ceiling_divide(max(units, 0) * SITE_DIAGRAM_FONT_SIZE, font.file.units_per_em)
}

// site_diagram_font_problem refuses a text with a character that the font
// lacks: a browser would draw it in another font, with another advance.
site_diagram_font_problem :: proc(font: ^Site_Diagram_Font, text: string, line: int) -> Site_Diagram_Problem {
	for character in text {
		if _, problem := vector_font.glyph_of(&font.file, character); problem != .None {
			return {line = line, text = fmt.tprintf("the character U+%04X of %q is not in the font of the diagrams", int(character), text)}
		}
	}
	return {}
}

// A text cut into lines, each with its width.
Site_Diagram_Text :: struct {
	lines:  []string,
	widths: []int,
	width:  int, // The widest line.
	height: int, // The lines times the line height.
	limit:  int, // The bound that the text was wrapped to.
}

// site_diagram_wrap cuts a text into lines no wider than limit, at its
// spaces. The rule: a line is wider than limit only when it is one word
// that is wider than limit by itself. That word is a line of its own, the
// box of the text grows to hold it, and the word is never cut.
site_diagram_wrap :: proc(font: ^Site_Diagram_Font, text: string, limit: int) -> Site_Diagram_Text {
	words := strings.fields(text, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	widths := make([dynamic]int, context.temp_allocator)
	current := ""
	for word in words {
		if current == "" {
			current = word
			continue
		}
		candidate := strings.concatenate({current, " ", word}, context.temp_allocator)
		if site_diagram_text_width(font, candidate) <= limit {
			current = candidate
			continue
		}
		append(&lines, current)
		append(&widths, site_diagram_text_width(font, current))
		current = word
	}
	if current != "" {
		append(&lines, current)
		append(&widths, site_diagram_text_width(font, current))
	}
	result := Site_Diagram_Text{lines = lines[:], widths = widths[:], height = len(lines) * font.line_height, limit = limit}
	for width in widths {
		result.width = max(result.width, width)
	}
	return result
}

Site_Diagram_Rectangle :: struct {
	x, y, width, height: int,
}

site_diagram_rectangles_overlap :: proc(a, b: Site_Diagram_Rectangle) -> bool {
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

site_diagram_rectangle_inside :: proc(inner, outer: Site_Diagram_Rectangle) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

// site_diagram_text_centered gives the place of a text in the middle of a
// rectangle.
site_diagram_text_centered :: proc(rectangle: Site_Diagram_Rectangle, text: Site_Diagram_Text) -> Site_Diagram_Rectangle {
	return {rectangle.x + (rectangle.width - text.width) / 2, rectangle.y + (rectangle.height - text.height) / 2, text.width, text.height}
}

Site_Diagram_Box_Kind :: enum {
	Node,
	Group, // A subgraph: a box around its nodes.
	Edge_Label, // The text of an edge or of a message, on a background.
	Participant,
}

Site_Diagram_Box :: struct {
	kind:       Site_Diagram_Box_Kind,
	rectangle:  Site_Diagram_Rectangle,
	text:       Site_Diagram_Text,
	text_place: Site_Diagram_Rectangle, // Inside the rectangle, as wide and as high as the text.
	parent:     int, // The box of the subgraph that holds a node, or -1.
}

Site_Diagram_Line_Kind :: enum {
	Edge,
	Message,
	Lifeline,
}

Site_Diagram_Line :: struct {
	kind:             Site_Diagram_Line_Kind,
	style:            Site_Diagram_Edge_Style,
	points:           [][2]int,
	arrow:            bool, // An arrow head at the last point.
	from_box, to_box: int, // The boxes at its two ends; for a message, the participants whose lifelines it joins.
	label_box:        int, // The box of its text, or -1.
}

Site_Diagram_Picture :: struct {
	kind:          Site_Diagram_Kind,
	width, height: int,
	boxes:         [dynamic]Site_Diagram_Box,
	lines:         [dynamic]Site_Diagram_Line,
}

// site_diagram_draw lays out a diagram that site_diagram_parse accepted.
site_diagram_draw :: proc(diagram: ^Site_Diagram, font: ^Site_Diagram_Font) -> (picture: Site_Diagram_Picture, problem: Site_Diagram_Problem) {
	if diagram.kind == .Sequence {
		return site_diagram_sequence_draw(&diagram.sequence, font)
	}
	return site_diagram_flowchart_draw(&diagram.flowchart, font)
}

// The inside of a subgraph: its size, the place of its label and the place
// of each of its nodes, from its top left corner. In TB the label is at the
// left and the nodes are in a row; in LR the label is at the top and the
// nodes are in a column. So the label is at the start of the axis across
// the flow, and no edge, which enters and leaves along the flow, crosses it.
Site_Diagram_Group_Inside :: struct {
	width, height: int,
	label:         Site_Diagram_Text,
	label_place:   Site_Diagram_Rectangle,
	places:        []Site_Diagram_Rectangle, // In the order of the nodes of the subgraph.
}

Site_Diagram_Unit_Kind :: enum {
	Node, // A node outside each subgraph.
	Group,
	Lane, // A point of an edge in a rank between its two ends.
	Label, // The text of an edge, in the first rank after its source.
}

// A unit of the layered layout. flow is the axis of the edges (y in TB, x
// in LR); across is the other one.
Site_Diagram_Unit :: struct {
	kind:        Site_Diagram_Unit_Kind,
	index:       int, // The node, the subgraph or the edge.
	rank:        int,
	flow_size:   int,
	across_size: int,
	flow:        int, // The start of the unit on the axis of the flow.
	across:      int, // The start of the unit on the axis across the flow.
	text:        Site_Diagram_Text, // Of a label.
}

// A neighbour of a unit in the next or the previous rank, through one step
// of an edge: the place of the step inside each unit, from its start on the
// axis across the flow.
Site_Diagram_Link :: struct {
	other:        int,
	own_offset:   int,
	other_offset: int,
}

site_diagram_rectangle_of :: proc(left_to_right: bool, flow, across, flow_size, across_size: int) -> Site_Diagram_Rectangle {
	if left_to_right {
		return {flow, across, flow_size, across_size}
	}
	return {across, flow, across_size, flow_size}
}

site_diagram_point_of :: proc(left_to_right: bool, flow, across: int) -> [2]int {
	if left_to_right {
		return {flow, across}
	}
	return {across, flow}
}

// The start and the size of a rectangle on the axis across the flow, and
// its start and its end on the axis of the flow.
site_diagram_across_of :: proc(left_to_right: bool, rectangle: Site_Diagram_Rectangle) -> (start, size: int) {
	if left_to_right {
		return rectangle.y, rectangle.height
	}
	return rectangle.x, rectangle.width
}

site_diagram_flow_of :: proc(left_to_right: bool, rectangle: Site_Diagram_Rectangle) -> (start, end: int) {
	if left_to_right {
		return rectangle.x, rectangle.x + rectangle.width
	}
	return rectangle.y, rectangle.y + rectangle.height
}

// site_diagram_flowchart_draw lays out a flowchart.
//
// The rule:
//   - the units of the top are the subgraphs and the nodes outside each
//     subgraph; an edge joins the units that hold its two ends;
//   - the rank of a unit is the longest path to it: 0 for a unit that no
//     edge enters, else two more than the rank of each source. A cycle has
//     no such rank and is refused, with the line of its first edge;
//   - each edge has a unit in each rank between its ends: its label in the
//     first one, a lane of no width in the others. So a label is a box of
//     the layout as a node is, and never lies on another box;
//   - a few passes of the barycenter order each rank, and the order with
//     the fewest crossings is kept; then a few passes move each unit
//     toward the mean of its neighbours, with the gap kept;
//   - an edge leaves the end of its source along the flow and enters the
//     start of its target along the flow; it is straight between two
//     ranks, and the points of the edges that share a side of a box are
//     spread along that side.
site_diagram_flowchart_draw :: proc(chart: ^Site_Diagram_Flowchart, font: ^Site_Diagram_Font) -> (picture: Site_Diagram_Picture, problem: Site_Diagram_Problem) {
	for node in chart.nodes {
		if problem = site_diagram_font_problem(font, node.label, node.line); problem.text != "" {
			return
		}
	}
	for group in chart.groups {
		if problem = site_diagram_font_problem(font, group.label, group.line); problem.text != "" {
			return
		}
	}
	for edge in chart.edges {
		if problem = site_diagram_font_problem(font, edge.label, edge.line); problem.text != "" {
			return
		}
	}
	left_to_right := chart.direction == .Left_To_Right

	node_texts := make([]Site_Diagram_Text, len(chart.nodes), context.temp_allocator)
	node_sizes := make([][2]int, len(chart.nodes), context.temp_allocator)
	for node, node_index in chart.nodes {
		node_texts[node_index] = site_diagram_wrap(font, node.label, SITE_DIAGRAM_NODE_LABEL_LIMIT)
		node_sizes[node_index] = {node_texts[node_index].width + 2 * SITE_DIAGRAM_NODE_PADDING_X, node_texts[node_index].height + 2 * SITE_DIAGRAM_NODE_PADDING_Y}
	}
	insides := make([]Site_Diagram_Group_Inside, len(chart.groups), context.temp_allocator)
	for group, group_index in chart.groups {
		inside := &insides[group_index]
		inside.places = make([]Site_Diagram_Rectangle, len(group.nodes), context.temp_allocator)
		padding :: SITE_DIAGRAM_GROUP_PADDING
		if left_to_right {
			column := 0
			for node in group.nodes {
				column = max(column, node_sizes[node].x)
			}
			// One bound for each kind of text: a node with a long word
			// makes its column wide, and the label does not follow it.
			inside.label = site_diagram_wrap(font, group.label, SITE_DIAGRAM_GROUP_LABEL_LIMIT)
			inner_width := max(column, inside.label.width)
			inside.label_place = {padding + (inner_width - inside.label.width) / 2, padding, inside.label.width, inside.label.height}
			y := padding + inside.label.height + padding
			for node, place in group.nodes {
				inside.places[place] = {padding + (inner_width - column) / 2, y, column, node_sizes[node].y}
				y += node_sizes[node].y + SITE_DIAGRAM_GROUP_NODE_GAP
			}
			inside.width = inner_width + 2 * padding
			inside.height = y - SITE_DIAGRAM_GROUP_NODE_GAP + padding
		} else {
			row := 0
			for node in group.nodes {
				row = max(row, node_sizes[node].y)
			}
			inside.label = site_diagram_wrap(font, group.label, SITE_DIAGRAM_GROUP_LABEL_LIMIT)
			inner_height := max(row, inside.label.height)
			inside.label_place = {padding, padding + (inner_height - inside.label.height) / 2, inside.label.width, inside.label.height}
			x := padding + inside.label.width + padding
			for node, place in group.nodes {
				inside.places[place] = {x, padding + (inner_height - row) / 2, node_sizes[node].x, row}
				x += node_sizes[node].x + SITE_DIAGRAM_GROUP_NODE_GAP
			}
			inside.width = x - SITE_DIAGRAM_GROUP_NODE_GAP + padding
			inside.height = inner_height + 2 * padding
		}
	}

	// The units of the top, in the order of the text.
	units := make([dynamic]Site_Diagram_Unit, context.temp_allocator)
	node_units := make([]int, len(chart.nodes), context.temp_allocator)
	group_units := make([]int, len(chart.groups), context.temp_allocator)
	add_unit :: proc(units: ^[dynamic]Site_Diagram_Unit, left_to_right: bool, kind: Site_Diagram_Unit_Kind, index, width, height: int) -> int {
		append(units, Site_Diagram_Unit{kind = kind, index = index, flow_size = left_to_right ? width : height, across_size = left_to_right ? height : width})
		return len(units^) - 1
	}
	node_cursor, group_cursor := 0, 0
	for node_cursor < len(chart.nodes) || group_cursor < len(chart.groups) {
		if node_cursor < len(chart.nodes) && chart.nodes[node_cursor].group >= 0 {
			node_units[node_cursor] = -1
			node_cursor += 1
			continue
		}
		take_group := group_cursor < len(chart.groups) && (node_cursor >= len(chart.nodes) || chart.groups[group_cursor].line < chart.nodes[node_cursor].line)
		if take_group {
			group_units[group_cursor] = add_unit(&units, left_to_right, .Group, group_cursor, insides[group_cursor].width, insides[group_cursor].height)
			group_cursor += 1
		} else {
			node_units[node_cursor] = add_unit(&units, left_to_right, .Node, node_cursor, node_sizes[node_cursor].x, node_sizes[node_cursor].y)
			node_cursor += 1
		}
	}
	top_count := len(units)
	unit_of_end :: proc(chart: ^Site_Diagram_Flowchart, node_units, group_units: []int, end: Site_Diagram_End) -> int {
		outer := site_diagram_outer_of(chart, end)
		return outer.group ? group_units[outer.index] : node_units[outer.index]
	}
	edge_count := len(chart.edges)
	edge_from := make([]int, edge_count, context.temp_allocator)
	edge_to := make([]int, edge_count, context.temp_allocator)
	for edge, edge_index in chart.edges {
		edge_from[edge_index] = unit_of_end(chart, node_units, group_units, edge.from)
		edge_to[edge_index] = unit_of_end(chart, node_units, group_units, edge.to)
	}

	// The ranks, by the longest path, in the order of a topological sort.
	waiting := make([]int, top_count, context.temp_allocator) // The edges that enter a unit and whose source has no rank yet.
	for edge_index in 0 ..< edge_count {
		waiting[edge_to[edge_index]] += 1
	}
	ranked := make([dynamic]int, context.temp_allocator)
	for unit_index in 0 ..< top_count {
		if waiting[unit_index] == 0 {
			append(&ranked, unit_index)
		}
	}
	for head := 0; head < len(ranked); head += 1 {
		source := ranked[head]
		for edge_index in 0 ..< edge_count {
			if edge_from[edge_index] != source {
				continue
			}
			target := edge_to[edge_index]
			units[target].rank = max(units[target].rank, units[source].rank + 2)
			waiting[target] -= 1
			if waiting[target] == 0 {
				append(&ranked, target)
			}
		}
	}
	if len(ranked) < top_count {
		return {}, site_diagram_cycle_problem(chart, units[:top_count], edge_from, edge_to, waiting)
	}

	// The units of the edges in the ranks between their ends, and the chain
	// of units of each edge from its source to its target.
	chains := make([][]int, edge_count, context.temp_allocator)
	for edge, edge_index in chart.edges {
		chain := make([dynamic]int, context.temp_allocator)
		source, target := edge_from[edge_index], edge_to[edge_index]
		append(&chain, source)
		for rank in units[source].rank + 1 ..< units[target].rank {
			unit := Site_Diagram_Unit{kind = .Lane, index = edge_index, rank = rank}
			if rank == units[source].rank + 1 && edge.label != "" {
				unit.kind = .Label
				unit.text = site_diagram_wrap(font, edge.label, SITE_DIAGRAM_EDGE_LABEL_LIMIT)
				width := unit.text.width + 2 * SITE_DIAGRAM_LABEL_PADDING_X
				height := unit.text.height + 2 * SITE_DIAGRAM_LABEL_PADDING_Y
				unit.flow_size = left_to_right ? width : height
				unit.across_size = left_to_right ? height : width
			}
			append(&units, unit)
			append(&chain, len(units) - 1)
		}
		append(&chain, target)
		chains[edge_index] = chain[:]
	}

	// The place of an end of an edge inside its unit, across the flow: the
	// middle of the node that it names inside a subgraph, else the middle
	// of the unit.
	end_offset :: proc(chart: ^Site_Diagram_Flowchart, insides: []Site_Diagram_Group_Inside, units: []Site_Diagram_Unit, unit: int, end: Site_Diagram_End, left_to_right: bool) -> int {
		if !end.group {
			if group := chart.nodes[end.index].group; group >= 0 {
				for node, place in chart.groups[group].nodes {
					if node == end.index {
						start, size := site_diagram_across_of(left_to_right, insides[group].places[place])
						return start + size / 2
					}
				}
			}
		}
		return units[unit].across_size / 2
	}
	ups := make([][dynamic]Site_Diagram_Link, len(units), context.temp_allocator)
	downs := make([][dynamic]Site_Diagram_Link, len(units), context.temp_allocator)
	for unit_index in 0 ..< len(units) {
		ups[unit_index] = make([dynamic]Site_Diagram_Link, context.temp_allocator)
		downs[unit_index] = make([dynamic]Site_Diagram_Link, context.temp_allocator)
	}
	for chain, edge_index in chains {
		for step in 0 ..< len(chain) - 1 {
			upper, lower := chain[step], chain[step + 1]
			upper_offset := units[upper].across_size / 2
			lower_offset := units[lower].across_size / 2
			if step == 0 {
				upper_offset = end_offset(chart, insides, units[:], upper, chart.edges[edge_index].from, left_to_right)
			}
			if step == len(chain) - 2 {
				lower_offset = end_offset(chart, insides, units[:], lower, chart.edges[edge_index].to, left_to_right)
			}
			append(&downs[upper], Site_Diagram_Link{other = lower, own_offset = upper_offset, other_offset = lower_offset})
			append(&ups[lower], Site_Diagram_Link{other = upper, own_offset = lower_offset, other_offset = upper_offset})
		}
	}

	// The ranks, each a list of units in its order.
	rank_count := 0
	for unit in units {
		rank_count = max(rank_count, unit.rank + 1)
	}
	ranks := make([][dynamic]int, rank_count, context.temp_allocator)
	for rank in 0 ..< rank_count {
		ranks[rank] = make([dynamic]int, context.temp_allocator)
	}
	for unit, unit_index in units {
		append(&ranks[unit.rank], unit_index)
	}
	positions := make([]int, len(units), context.temp_allocator)
	site_diagram_positions_set(ranks, positions)
	best := site_diagram_orders_copy(ranks)
	best_crossings := site_diagram_crossings(ranks, downs, positions)
	for sweep in 0 ..< SITE_DIAGRAM_ORDER_SWEEPS {
		if sweep % 2 == 0 {
			for rank in 1 ..< rank_count {
				site_diagram_rank_order(ranks[rank][:], ups, positions)
			}
		} else {
			for rank := rank_count - 2; rank >= 0; rank -= 1 {
				site_diagram_rank_order(ranks[rank][:], downs, positions)
			}
		}
		if crossings := site_diagram_crossings(ranks, downs, positions); crossings < best_crossings {
			best_crossings = crossings
			best = site_diagram_orders_copy(ranks)
		}
	}
	for rank in 0 ..< rank_count {
		copy(ranks[rank][:], best[rank])
	}
	site_diagram_positions_set(ranks, positions)

	// The places across the flow: each rank packed with the gap and centred
	// on the widest one, then moved toward the neighbours.
	widest := 0
	for rank in ranks {
		widest = max(widest, site_diagram_rank_width(units[:], rank[:]))
	}
	for rank in ranks {
		cursor := (widest - site_diagram_rank_width(units[:], rank[:])) / 2
		for unit in rank {
			units[unit].across = cursor
			cursor += units[unit].across_size + SITE_DIAGRAM_UNIT_GAP
		}
	}
	for _ in 0 ..< SITE_DIAGRAM_PLACEMENT_ROUNDS {
		for rank in 1 ..< rank_count {
			site_diagram_rank_place(units[:], ranks[rank][:], ups)
		}
		for rank := rank_count - 2; rank >= 0; rank -= 1 {
			site_diagram_rank_place(units[:], ranks[rank][:], downs)
		}
	}
	least := units[0].across
	for unit in units {
		least = min(least, unit.across)
	}
	across_extent := 0
	for &unit in units {
		unit.across += SITE_DIAGRAM_MARGIN - least
		across_extent = max(across_extent, unit.across + unit.across_size)
	}
	across_extent += SITE_DIAGRAM_MARGIN

	// The places along the flow: each rank as thick as its thickest unit,
	// each unit in the middle of its rank.
	rank_starts := make([]int, rank_count, context.temp_allocator)
	rank_thickness := make([]int, rank_count, context.temp_allocator)
	for unit in units {
		rank_thickness[unit.rank] = max(rank_thickness[unit.rank], unit.flow_size)
	}
	rank_starts[0] = SITE_DIAGRAM_MARGIN
	for rank in 1 ..< rank_count {
		rank_starts[rank] = rank_starts[rank - 1] + rank_thickness[rank - 1] + SITE_DIAGRAM_RANK_GAP
	}
	for &unit in units {
		unit.flow = rank_starts[unit.rank] + (rank_thickness[unit.rank] - unit.flow_size) / 2
	}
	flow_extent := rank_starts[rank_count - 1] + rank_thickness[rank_count - 1] + SITE_DIAGRAM_MARGIN

	// The boxes: the subgraphs, the nodes, the labels.
	picture.kind = .Flowchart
	picture.boxes = make([dynamic]Site_Diagram_Box, context.temp_allocator)
	picture.lines = make([dynamic]Site_Diagram_Line, context.temp_allocator)
	if left_to_right {
		picture.width, picture.height = flow_extent, across_extent
	} else {
		picture.width, picture.height = across_extent, flow_extent
	}
	unit_rectangle :: proc(left_to_right: bool, unit: Site_Diagram_Unit) -> Site_Diagram_Rectangle {
		return site_diagram_rectangle_of(left_to_right, unit.flow, unit.across, unit.flow_size, unit.across_size)
	}
	group_boxes := make([]int, len(chart.groups), context.temp_allocator)
	node_boxes := make([]int, len(chart.nodes), context.temp_allocator)
	label_boxes := make([]int, edge_count, context.temp_allocator)
	slice.fill(label_boxes, -1)
	for group_index in 0 ..< len(chart.groups) {
		rectangle := unit_rectangle(left_to_right, units[group_units[group_index]])
		inside := insides[group_index]
		place := inside.label_place
		place.x += rectangle.x
		place.y += rectangle.y
		append(&picture.boxes, Site_Diagram_Box{kind = .Group, rectangle = rectangle, text = inside.label, text_place = place, parent = -1})
		group_boxes[group_index] = len(picture.boxes) - 1
	}
	for node, node_index in chart.nodes {
		box := Site_Diagram_Box{kind = .Node, text = node_texts[node_index], parent = -1}
		if node.group >= 0 {
			group_rectangle := picture.boxes[group_boxes[node.group]].rectangle
			for member, place in chart.groups[node.group].nodes {
				if member == node_index {
					box.rectangle = insides[node.group].places[place]
				}
			}
			box.rectangle.x += group_rectangle.x
			box.rectangle.y += group_rectangle.y
			box.parent = group_boxes[node.group]
		} else {
			box.rectangle = unit_rectangle(left_to_right, units[node_units[node_index]])
		}
		box.text_place = site_diagram_text_centered(box.rectangle, box.text)
		append(&picture.boxes, box)
		node_boxes[node_index] = len(picture.boxes) - 1
	}
	for unit in units {
		if unit.kind != .Label {
			continue
		}
		rectangle := unit_rectangle(left_to_right, unit)
		append(&picture.boxes, Site_Diagram_Box{kind = .Edge_Label, rectangle = rectangle, text = unit.text, text_place = site_diagram_text_centered(rectangle, unit.text), parent = -1})
		label_boxes[unit.index] = len(picture.boxes) - 1
	}

	// The ends of the edges, spread along each side of a box.
	box_of_end :: proc(group_boxes, node_boxes: []int, end: Site_Diagram_End) -> int {
		return end.group ? group_boxes[end.index] : node_boxes[end.index]
	}
	from_boxes := make([]int, edge_count, context.temp_allocator)
	to_boxes := make([]int, edge_count, context.temp_allocator)
	for edge, edge_index in chart.edges {
		from_boxes[edge_index] = box_of_end(group_boxes, node_boxes, edge.from)
		to_boxes[edge_index] = box_of_end(group_boxes, node_boxes, edge.to)
	}
	unit_middle :: proc(unit: Site_Diagram_Unit) -> int {
		return unit.across + unit.across_size / 2
	}
	from_across := site_diagram_spread(picture.boxes[:], from_boxes, chains, units[:], left_to_right, true)
	to_across := site_diagram_spread(picture.boxes[:], to_boxes, chains, units[:], left_to_right, false)
	// A point that is the point before it adds nothing: a box can end at
	// the end of its rank, and a lane has no thickness.
	add :: proc(points: ^[dynamic][2]int, point: [2]int) {
		if len(points^) == 0 || points^[len(points^) - 1] != point {
			append(points, point)
		}
	}
	for edge, edge_index in chart.edges {
		chain := chains[edge_index]
		points := make([dynamic][2]int, context.temp_allocator)
		_, source_end := site_diagram_flow_of(left_to_right, picture.boxes[from_boxes[edge_index]].rectangle)
		target_start, _ := site_diagram_flow_of(left_to_right, picture.boxes[to_boxes[edge_index]].rectangle)
		source_rank := units[chain[0]].rank
		target_rank := units[chain[len(chain) - 1]].rank
		add(&points, site_diagram_point_of(left_to_right, source_end, from_across[edge_index]))
		add(&points, site_diagram_point_of(left_to_right, rank_starts[source_rank] + rank_thickness[source_rank], from_across[edge_index]))
		for step in 1 ..< len(chain) - 1 {
			unit := units[chain[step]]
			add(&points, site_diagram_point_of(left_to_right, rank_starts[unit.rank], unit_middle(unit)))
			add(&points, site_diagram_point_of(left_to_right, rank_starts[unit.rank] + rank_thickness[unit.rank], unit_middle(unit)))
		}
		add(&points, site_diagram_point_of(left_to_right, rank_starts[target_rank] - SITE_DIAGRAM_ARROW_STUB, to_across[edge_index]))
		add(&points, site_diagram_point_of(left_to_right, rank_starts[target_rank], to_across[edge_index]))
		add(&points, site_diagram_point_of(left_to_right, target_start, to_across[edge_index]))
		append(&picture.lines, Site_Diagram_Line{kind = .Edge, style = edge.style, points = points[:], arrow = true, from_box = from_boxes[edge_index], to_box = to_boxes[edge_index], label_box = label_boxes[edge_index]})
	}
	return picture, {}
}

// site_diagram_cycle_problem finds a cycle among the units that the sort
// left, and names it with the line of its first edge. Each unit left has an
// edge from another unit left, so a walk back along those edges comes back
// to a unit that it passed: the walk from there is a cycle.
site_diagram_cycle_problem :: proc(chart: ^Site_Diagram_Flowchart, units: []Site_Diagram_Unit, edge_from, edge_to, waiting: []int) -> Site_Diagram_Problem {
	unit_name :: proc(chart: ^Site_Diagram_Flowchart, unit: Site_Diagram_Unit) -> string {
		return unit.kind == .Group ? chart.groups[unit.index].id : chart.nodes[unit.index].id
	}
	walk_place := make([]int, len(units), context.temp_allocator)
	slice.fill(walk_place, -1)
	walk_units := make([dynamic]int, context.temp_allocator)
	walk_edges := make([dynamic]int, context.temp_allocator)
	current := 0
	for waiting[current] == 0 {
		current += 1
	}
	for walk_place[current] < 0 {
		walk_place[current] = len(walk_units)
		append(&walk_units, current)
		for edge_index in 0 ..< len(edge_from) {
			if edge_to[edge_index] == current && waiting[edge_from[edge_index]] > 0 {
				append(&walk_edges, edge_index)
				current = edge_from[edge_index]
				break
			}
		}
	}
	cycle_units := walk_units[walk_place[current]:]
	cycle_edges := walk_edges[walk_place[current]:]
	line := chart.edges[cycle_edges[0]].line
	for edge_index in cycle_edges {
		line = min(line, chart.edges[edge_index].line)
	}
	// The walk went back along the edges: its units from the end are the
	// cycle in the direction of its edges.
	names := make([dynamic]string, context.temp_allocator)
	append(&names, unit_name(chart, units[current]))
	for place := len(cycle_units) - 1; place >= 1; place -= 1 {
		append(&names, unit_name(chart, units[cycle_units[place]]))
	}
	append(&names, unit_name(chart, units[current]))
	return {line = line, text = fmt.tprintf("the edges make a cycle, %s: a flowchart is drawn in ranks, each target after its sources, and a cycle has no such order", strings.join(names[:], " --> ", context.temp_allocator))}
}

site_diagram_positions_set :: proc(ranks: [][dynamic]int, positions: []int) {
	for rank in ranks {
		for unit, place in rank {
			positions[unit] = place
		}
	}
}

site_diagram_orders_copy :: proc(ranks: [][dynamic]int) -> [][]int {
	orders := make([][]int, len(ranks), context.temp_allocator)
	for rank, rank_index in ranks {
		orders[rank_index] = slice.clone(rank[:], context.temp_allocator)
	}
	return orders
}

// site_diagram_crossings counts the pairs of steps of edges between two
// next ranks that cross.
site_diagram_crossings :: proc(ranks: [][dynamic]int, downs: [][dynamic]Site_Diagram_Link, positions: []int) -> int {
	crossings := 0
	steps := make([dynamic][2]int, context.temp_allocator)
	for rank in ranks {
		clear(&steps)
		for unit in rank {
			for link in downs[unit] {
				append(&steps, [2]int{positions[unit], positions[link.other]})
			}
		}
		for first in 0 ..< len(steps) {
			for second in first + 1 ..< len(steps) {
				a, b := steps[first], steps[second]
				if (a[0] < b[0] && a[1] > b[1]) || (a[0] > b[0] && a[1] < b[1]) {
					crossings += 1
				}
			}
		}
	}
	return crossings
}

// site_diagram_rank_order orders one rank by the barycenter: the mean place
// of the neighbours of each unit in the rank before it in the sweep. A unit
// with no neighbour there keeps its place; a tie keeps the order before.
site_diagram_rank_order :: proc(rank: []int, links: [][dynamic]Site_Diagram_Link, positions: []int) {
	Keyed :: struct {
		key:   f64,
		place: int,
		unit:  int,
	}
	keyed := make([]Keyed, len(rank), context.temp_allocator)
	for unit, place in rank {
		key := f64(place)
		if len(links[unit]) > 0 {
			sum := 0
			for link in links[unit] {
				sum += positions[link.other]
			}
			key = f64(sum) / f64(len(links[unit]))
		}
		keyed[place] = {key, place, unit}
	}
	slice.sort_by(keyed, proc(a, b: Keyed) -> bool {
		return a.key < b.key || (a.key == b.key && a.place < b.place)
	})
	for item, place in keyed {
		rank[place] = item.unit
		positions[item.unit] = place
	}
}

site_diagram_rank_width :: proc(units: []Site_Diagram_Unit, rank: []int) -> int {
	width := 0
	for unit, place in rank {
		width += units[unit].across_size
		if place > 0 {
			width += SITE_DIAGRAM_UNIT_GAP
		}
	}
	return width
}

// site_diagram_rank_place moves each unit of a rank toward the mean of the
// places of its neighbours, in its order and with the gap between two
// units, then moves the whole rank so that its mean is the mean that the
// units asked for.
site_diagram_rank_place :: proc(units: []Site_Diagram_Unit, rank: []int, links: [][dynamic]Site_Diagram_Link) {
	if len(rank) == 0 {
		return
	}
	wanted := make([]int, len(rank), context.temp_allocator)
	for unit, place in rank {
		wanted[place] = units[unit].across
		if len(links[unit]) > 0 {
			sum := 0
			for link in links[unit] {
				sum += units[link.other].across + link.other_offset - link.own_offset
			}
			wanted[place] = sum / len(links[unit])
		}
	}
	wanted_sum, placed_sum := 0, 0
	for unit, place in rank {
		start := wanted[place]
		if place > 0 {
			before := units[rank[place - 1]]
			start = max(start, before.across + before.across_size + SITE_DIAGRAM_UNIT_GAP)
		}
		units[unit].across = start
		wanted_sum += wanted[place]
		placed_sum += start
	}
	shift := (wanted_sum - placed_sum) / len(rank)
	for unit in rank {
		units[unit].across += shift
	}
}

// site_diagram_spread gives the place across the flow of one end of each
// edge: the ends on one side of a box are spread evenly along it, in the
// order of the places of the next unit of each edge, so two arrows never
// share a point.
site_diagram_spread :: proc(boxes: []Site_Diagram_Box, end_boxes: []int, chains: [][]int, units: []Site_Diagram_Unit, left_to_right: bool, sources: bool) -> []int {
	across := make([]int, len(end_boxes), context.temp_allocator)
	Ordered :: struct {
		key:  int,
		edge: int,
	}
	for box_index in 0 ..< len(boxes) {
		ends := make([dynamic]Ordered, context.temp_allocator)
		for end_box, edge_index in end_boxes {
			if end_box != box_index {
				continue
			}
			chain := chains[edge_index]
			next := units[chain[sources ? 1 : len(chain) - 2]]
			append(&ends, Ordered{next.across + next.across_size / 2, edge_index})
		}
		if len(ends) == 0 {
			continue
		}
		slice.sort_by(ends[:], proc(a, b: Ordered) -> bool {
			return a.key < b.key || (a.key == b.key && a.edge < b.edge)
		})
		start, size := site_diagram_across_of(left_to_right, boxes[box_index].rectangle)
		for end, place in ends {
			across[end.edge] = start + size * (place + 1) / (len(ends) + 1)
		}
	}
	return across
}

// site_diagram_sequence_draw lays out a sequence diagram.
//
// The rule:
//   - the participants are columns in the order of their lines, each a box
//     at the top with a lifeline under it;
//   - two columns are apart by their two boxes and a gap, and by the text
//     of each message between them: a text wrapped to its bound, with a
//     margin at each lifeline. The space that a message needs goes to the
//     last gap before its right column;
//   - the messages are rows in their order: the text, then the arrow under
//     it. A message to the same participant is a loop at the right of its
//     lifeline with its text at the right of the loop, before the next
//     lifeline.
site_diagram_sequence_draw :: proc(sequence: ^Site_Diagram_Sequence, font: ^Site_Diagram_Font) -> (picture: Site_Diagram_Picture, problem: Site_Diagram_Problem) {
	for participant in sequence.participants {
		if problem = site_diagram_font_problem(font, participant.name, participant.line); problem.text != "" {
			return
		}
	}
	for message in sequence.messages {
		if problem = site_diagram_font_problem(font, message.text, message.line); problem.text != "" {
			return
		}
	}
	count := len(sequence.participants)
	names := make([]Site_Diagram_Text, count, context.temp_allocator)
	widths := make([]int, count, context.temp_allocator)
	box_height := 0
	for participant, index in sequence.participants {
		names[index] = site_diagram_wrap(font, participant.name, SITE_DIAGRAM_PARTICIPANT_LABEL_LIMIT)
		widths[index] = names[index].width + 2 * SITE_DIAGRAM_NODE_PADDING_X
		box_height = max(box_height, names[index].height + 2 * SITE_DIAGRAM_NODE_PADDING_Y)
	}
	// The least distance between the middles of two columns: from the
	// boxes, then from the messages.
	needs := make([]int, count, context.temp_allocator)
	for index in 1 ..< count {
		needs[index] = (widths[index - 1] - widths[index - 1] / 2) + widths[index] / 2 + SITE_DIAGRAM_PARTICIPANT_GAP
	}
	Span :: struct {
		left, right, distance: int,
	}
	spans := make([dynamic]Span, context.temp_allocator)
	right_room := 0 // The room at the right of the last lifeline, for the loops of its messages.
	for message in sequence.messages {
		if message.from == message.to {
			loop_text := site_diagram_wrap(font, message.text, SITE_DIAGRAM_SELF_LABEL_LIMIT)
			loop_room := SITE_DIAGRAM_SELF_LOOP_WIDTH + 2 * SITE_DIAGRAM_MESSAGE_LABEL_PADDING + loop_text.width
			if message.from + 1 < count {
				append(&spans, Span{message.from, message.from + 1, loop_room})
			} else {
				right_room = max(right_room, loop_room)
			}
			continue
		}
		span_text := site_diagram_wrap(font, message.text, SITE_DIAGRAM_MESSAGE_LABEL_LIMIT)
		append(&spans, Span{min(message.from, message.to), max(message.from, message.to), span_text.width + 2 * SITE_DIAGRAM_MESSAGE_LABEL_PADDING})
	}
	middles := make([]int, count, context.temp_allocator)
	middles[0] = SITE_DIAGRAM_MARGIN + widths[0] / 2
	for index in 1 ..< count {
		middles[index] = middles[index - 1] + needs[index]
		for span in spans {
			if span.right == index {
				middles[index] = max(middles[index], middles[span.left] + span.distance)
			}
		}
	}
	last := count - 1
	picture.kind = .Sequence
	picture.width = max(middles[last] + (widths[last] - widths[last] / 2), middles[last] + right_room) + SITE_DIAGRAM_MARGIN
	picture.boxes = make([dynamic]Site_Diagram_Box, context.temp_allocator)
	picture.lines = make([dynamic]Site_Diagram_Line, context.temp_allocator)
	for index in 0 ..< count {
		rectangle := Site_Diagram_Rectangle{middles[index] - widths[index] / 2, SITE_DIAGRAM_MARGIN, widths[index], box_height}
		append(&picture.boxes, Site_Diagram_Box{kind = .Participant, rectangle = rectangle, text = names[index], text_place = site_diagram_text_centered(rectangle, names[index]), parent = -1})
	}
	label_rectangle :: proc(place: Site_Diagram_Rectangle) -> Site_Diagram_Rectangle {
		return {place.x - SITE_DIAGRAM_LABEL_PADDING_X, place.y - SITE_DIAGRAM_LABEL_PADDING_Y, place.width + 2 * SITE_DIAGRAM_LABEL_PADDING_X, place.height + 2 * SITE_DIAGRAM_LABEL_PADDING_Y}
	}
	y := SITE_DIAGRAM_MARGIN + box_height + SITE_DIAGRAM_MESSAGE_GAP + SITE_DIAGRAM_LABEL_PADDING_Y
	for message in sequence.messages {
		points := make([dynamic][2]int, context.temp_allocator)
		text: Site_Diagram_Text
		place: Site_Diagram_Rectangle
		if message.from == message.to {
			middle := middles[message.from]
			text = site_diagram_wrap(font, message.text, SITE_DIAGRAM_SELF_LABEL_LIMIT)
			place = {middle + SITE_DIAGRAM_SELF_LOOP_WIDTH + SITE_DIAGRAM_MESSAGE_LABEL_PADDING, y, text.width, text.height}
			top := y + font.line_height / 2
			bottom := max(top + SITE_DIAGRAM_SELF_LOOP_LEAST_HEIGHT, y + text.height + SITE_DIAGRAM_LABEL_PADDING_Y + SITE_DIAGRAM_ARROW_GAP)
			append(&points, [2]int{middle, top}, [2]int{middle + SITE_DIAGRAM_SELF_LOOP_WIDTH, top}, [2]int{middle + SITE_DIAGRAM_SELF_LOOP_WIDTH, bottom}, [2]int{middle, bottom})
			y = bottom + SITE_DIAGRAM_MESSAGE_GAP + SITE_DIAGRAM_LABEL_PADDING_Y
		} else {
			left, right := min(message.from, message.to), max(message.from, message.to)
			room := middles[right] - middles[left] - 2 * SITE_DIAGRAM_MESSAGE_LABEL_PADDING
			text = site_diagram_wrap(font, message.text, min(room, SITE_DIAGRAM_MESSAGE_LABEL_LIMIT))
			place = {(middles[left] + middles[right]) / 2 - text.width / 2, y, text.width, text.height}
			arrow := y + text.height + SITE_DIAGRAM_LABEL_PADDING_Y + SITE_DIAGRAM_ARROW_GAP
			append(&points, [2]int{middles[message.from], arrow}, [2]int{middles[message.to], arrow})
			y = arrow + SITE_DIAGRAM_MESSAGE_GAP + SITE_DIAGRAM_LABEL_PADDING_Y
		}
		append(&picture.boxes, Site_Diagram_Box{kind = .Edge_Label, rectangle = label_rectangle(place), text = text, text_place = place, parent = -1})
		append(&picture.lines, Site_Diagram_Line{kind = .Message, style = .Solid, points = points[:], arrow = true, from_box = message.from, to_box = message.to, label_box = len(picture.boxes) - 1})
	}
	end := y - SITE_DIAGRAM_LABEL_PADDING_Y
	for index in 0 ..< count {
		points := make([][2]int, 2, context.temp_allocator)
		points[0] = {middles[index], SITE_DIAGRAM_MARGIN + box_height}
		points[1] = {middles[index], end}
		append(&picture.lines, Site_Diagram_Line{kind = .Lifeline, style = .Solid, points = points, from_box = index, to_box = index, label_box = -1})
	}
	picture.height = end + SITE_DIAGRAM_MARGIN
	return picture, {}
}
