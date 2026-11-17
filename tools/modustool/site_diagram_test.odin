package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
diagram_font :: proc(t: ^testing.T) -> (font: Site_Diagram_Font, ok: bool) {
	bytes, read_error := os.read_entire_file(SITE_DIAGRAM_FONT_SOURCE, context.temp_allocator)
	if read_error != nil {
		testing.expectf(t, false, "cannot read %s", SITE_DIAGRAM_FONT_SOURCE)
		return {}, false
	}
	problem: string
	font, problem = site_diagram_font_open(bytes)
	testing.expectf(t, problem == "", "the font: %s", problem)
	return font, problem == ""
}

// diagram_of reads and lays out a text: the problem of the reader or of
// the layout, whichever comes first.
@(private = "file")
diagram_of :: proc(font: ^Site_Diagram_Font, body: string) -> (picture: Site_Diagram_Picture, problem: Site_Diagram_Problem) {
	diagram: Site_Diagram
	diagram, problem = site_diagram_parse(body)
	if problem.text != "" {
		return {}, problem
	}
	return site_diagram_draw(&diagram, font)
}

@(private = "file")
strictly_inside :: proc(point: [2]int, rectangle: Site_Diagram_Rectangle) -> bool {
	return point.x > rectangle.x && point.x < rectangle.x + rectangle.width && point.y > rectangle.y && point.y < rectangle.y + rectangle.height
}

@(private = "file")
on_border :: proc(point: [2]int, rectangle: Site_Diagram_Rectangle) -> bool {
	inside := point.x >= rectangle.x && point.x <= rectangle.x + rectangle.width && point.y >= rectangle.y && point.y <= rectangle.y + rectangle.height
	return inside && (point.x == rectangle.x || point.x == rectangle.x + rectangle.width || point.y == rectangle.y || point.y == rectangle.y + rectangle.height)
}

// segment_enters says if a segment passes inside a rectangle, at a step
// of one pixel.
@(private = "file")
segment_enters :: proc(from, to: [2]int, rectangle: Site_Diagram_Rectangle) -> bool {
	steps := max(abs(to.x - from.x), abs(to.y - from.y), 1)
	for step in 0 ..= steps {
		point := [2]int{from.x + (to.x - from.x) * step / steps, from.y + (to.y - from.y) * step / steps}
		if strictly_inside(point, rectangle) {
			return true
		}
	}
	return false
}

// picture_check checks what each picture must hold: each text inside its
// box and no wider than its place, no two boxes over each other but a node
// in its subgraph, the label of a subgraph over none of its nodes, each
// line inside the picture and over no box but its own, each edge from the
// border of its source to the border of its target, each message from a
// lifeline to a lifeline.
@(private = "file")
picture_check :: proc(t: ^testing.T, font: ^Site_Diagram_Font, picture: ^Site_Diagram_Picture, name: string) {
	whole := Site_Diagram_Rectangle{0, 0, picture.width, picture.height}
	for box, box_index in picture.boxes {
		testing.expectf(t, site_diagram_rectangle_inside(box.rectangle, whole), "%s: the box %d is outside the picture", name, box_index)
		testing.expectf(t, site_diagram_rectangle_inside(box.text_place, box.rectangle), "%s: the text %v of the box %d passes its box", name, box.text.lines, box_index)
		testing.expectf(t, len(box.text.lines) > 0, "%s: the box %d has no text", name, box_index)
		testing.expect_value(t, box.text.height, len(box.text.lines) * font.line_height)
		testing.expect_value(t, box.text_place.width, box.text.width)
		testing.expect_value(t, box.text_place.height, box.text.height)
		for width, line_index in box.text.widths {
			testing.expectf(t, width <= box.text_place.width, "%s: the line %q of the box %d passes its place", name, box.text.lines[line_index], box_index)
			testing.expect_value(t, width, site_diagram_text_width(font, box.text.lines[line_index]))
			// A line passes the bound of its text only when it is one word
			// that is wider than the bound by itself.
			testing.expectf(t, width <= box.text.limit || !strings.contains(box.text.lines[line_index], " "), "%s: the line %q of the box %d is %d pixels wide, past its bound %d, and is not one word", name, box.text.lines[line_index], box_index, width, box.text.limit)
		}
		testing.expectf(t, box.text.limit > 0, "%s: the text of the box %d has no bound", name, box_index)
		for other, other_index in picture.boxes {
			if other_index <= box_index {
				continue
			}
			if other.parent == box_index || box.parent == other_index {
				testing.expectf(t, site_diagram_rectangle_inside(other.parent == box_index ? other.rectangle : box.rectangle, other.parent == box_index ? box.rectangle : other.rectangle), "%s: a node passes its subgraph", name)
				group_label := other.parent == box_index ? box.text_place : other.text_place
				node := other.parent == box_index ? other.rectangle : box.rectangle
				testing.expectf(t, !site_diagram_rectangles_overlap(group_label, node), "%s: the label of a subgraph is over one of its nodes", name)
				continue
			}
			testing.expectf(t, !site_diagram_rectangles_overlap(box.rectangle, other.rectangle), "%s: the boxes %d %v and %d %v overlap", name, box_index, box.text.lines, other_index, other.text.lines)
		}
	}
	for line, line_index in picture.lines {
		testing.expectf(t, len(line.points) >= 2, "%s: the line %d has fewer than two points", name, line_index)
		if len(line.points) < 2 {
			continue
		}
		for point in line.points {
			testing.expectf(t, point.x >= 0 && point.x <= picture.width && point.y >= 0 && point.y <= picture.height, "%s: the line %d leaves the picture", name, line_index)
		}
		first, last := line.points[0], line.points[len(line.points) - 1]
		switch line.kind {
		case .Edge:
			testing.expectf(t, on_border(first, picture.boxes[line.from_box].rectangle), "%s: the edge %d does not start at the border of its source", name, line_index)
			testing.expectf(t, on_border(last, picture.boxes[line.to_box].rectangle), "%s: the edge %d does not end at the border of its target", name, line_index)
		case .Message:
			from := picture.boxes[line.from_box].rectangle
			to := picture.boxes[line.to_box].rectangle
			testing.expectf(t, first.x == from.x + from.width / 2 && last.x == to.x + to.width / 2, "%s: the message %d does not join its two lifelines", name, line_index)
			testing.expectf(t, first.y > from.y + from.height, "%s: the message %d is not under its participants", name, line_index)
		case .Lifeline:
			box := picture.boxes[line.from_box].rectangle
			testing.expectf(t, first == [2]int{box.x + box.width / 2, box.y + box.height}, "%s: the lifeline %d does not leave its participant", name, line_index)
			continue
		}
		testing.expect(t, line.arrow)
		if line.label_box >= 0 {
			label := picture.boxes[line.label_box]
			testing.expect_value(t, label.kind, Site_Diagram_Box_Kind.Edge_Label)
		}
		// A line passes over no box but its two ends, the subgraphs that
		// hold them and its own label.
		allowed := [?]int{line.from_box, line.to_box, picture.boxes[line.from_box].parent, picture.boxes[line.to_box].parent, line.label_box}
		for box, box_index in picture.boxes {
			skip := false
			for allowed_box in allowed {
				skip = skip || allowed_box == box_index
			}
			if skip {
				continue
			}
			for step in 0 ..< len(line.points) - 1 {
				testing.expectf(t, !segment_enters(line.points[step], line.points[step + 1], box.rectangle), "%s: the line %d passes over the box %d %v", name, line_index, box_index, box.text.lines)
			}
		}
	}
}

// The label of an edge sits on its edge: one segment of the edge passes
// through the middle of the label.
@(private = "file")
labels_on_their_edges :: proc(t: ^testing.T, picture: ^Site_Diagram_Picture, name: string) {
	for line, line_index in picture.lines {
		if line.kind != .Edge || line.label_box < 0 {
			continue
		}
		rectangle := picture.boxes[line.label_box].rectangle
		middle := [2]int{rectangle.x + rectangle.width / 2, rectangle.y + rectangle.height / 2}
		found := false
		for step in 0 ..< len(line.points) - 1 {
			a, b := line.points[step], line.points[step + 1]
			if a.x == b.x && a.x == middle.x && min(a.y, b.y) <= middle.y && middle.y <= max(a.y, b.y) {
				found = true
			}
			if a.y == b.y && a.y == middle.y && min(a.x, b.x) <= middle.x && middle.x <= max(a.x, b.x) {
				found = true
			}
		}
		testing.expectf(t, found, "%s: the label of the edge %d is not on its edge", name, line_index)
	}
}

@(test)
site_diagram_refuses_each_syntax_outside_the_subset :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	Refused :: struct {
		body:     string,
		line:     int,
		fragment: string,
	}
	refused := [?]Refused {
		{"", 0, "an empty diagram"},
		{"\n   \n", 0, "an empty diagram"},
		{"graph TD\n  a[\"A\"]\n", 1, "the diagram kind"},
		{"flowchart TD\n  a[\"A\"]\n", 1, "the direction LR or TB"},
		{"flowchart\n", 1, "the direction LR or TB"},
		{"flowchart TB\n", 1, "a flowchart with no node"},
		{"\n\nflowchart TB\n  a\n", 4, "the node a has no label"},
		{"flowchart TB\n  a[\"A\"]\n  b[\"B\"]\n  a --- b\n", 4, "an edge is"},
		{"flowchart TB\n  a[\"A\"]\n  b[\"B\"]\n  a ==> b\n", 4, "an edge is"},
		{"flowchart LR\n  a[\"A\"] -.-> b[\"B\"]\n", 2, "an edge is"},
		{"flowchart LR\n  a[\"A\"] -- \"x\" --- b[\"B\"]\n", 2, "an edge is"},
		{"flowchart LR\n  a[\"A\"] -. \"x\" --> b[\"B\"]\n", 2, "an edge is"},
		// The label runs to the next quote, after `b[`: its text holds the
		// arrow, whose > is markup.
		{"flowchart LR\n  a[\"A\"] -- \"unclosed --> b[\"B\"]\n", 2, "the character >"},
		{"flowchart LR\n  a[\"A\"] -- \"\" --> b[\"B\"]\n", 2, "an edge with an empty label"},
		{"flowchart LR\n  a[\"A\"] -- \"x;y\" --> b[\"B\"]\n", 2, "the character ;"},
		{"flowchart TB\n  a(\"A\")\n", 2, "a shape other than a box"},
		{"flowchart TB\n  a{\"A\"}\n", 2, "a shape other than a box"},
		{"flowchart TB\n  a>\"A\"]\n", 2, "a shape other than a box"},
		{"flowchart TB\n  a[A]\n", 2, "a text in quotes inside brackets"},
		{"flowchart TB\n  a[\"A\"\n", 2, "a text in quotes inside brackets"},
		{"flowchart TB\n  a[\"  \"]\n", 2, "has an empty label"},
		{"flowchart TB\n  a[\"A <b>\"]\n", 2, "the character <"},
		{"flowchart TB\n  a[\"A #35;\"]\n", 2, "the character #"},
		{"flowchart TB\n  a[\"`A`\"]\n", 2, "the character `"},
		{"flowchart TB\n  a[\"A\tB\"]\n", 2, "a control character"},
		{"flowchart TB\n  a[\"A\"]\n  a[\"B\"]\n", 3, "declared twice"},
		{"flowchart TB\n  subgraph a[\"S\"]\n    b[\"B\"]\n  end\n  a[\"A\"]\n", 5, "declared twice"},
		{"flowchart TB\n  a[\"A\"]\n  a --> b\n", 3, "b, which is no node and no subgraph"},
		{"flowchart TB\n  a[\"A\"]\n  a --> a\n", 3, "stays inside one box"},
		{"flowchart TB\n  subgraph s[\"S\"]\n    subgraph u[\"U\"]\n", 3, "a subgraph inside a subgraph"},
		{"flowchart TB\n  subgraph s[\"S\"]\n  end\n", 2, "holds no node"},
		{"flowchart TB\n  subgraph s[\"S\"]\n    a[\"A\"]\n", 2, "has no end"},
		{"flowchart TB\n  a[\"A\"]\n  end\n", 3, "an end with no subgraph"},
		{"flowchart TB\n  subgraph s\n    a[\"A\"]\n  end\n", 2, "has no label"},
		{"flowchart TB\n  subgraph s[\"S\"] more\n", 2, "text after the label"},
		{"flowchart TB\n  subgraph s[\"S\"]\n    a[\"A\"]\n    b[\"B\"]\n    a --> b\n  end\n", 5, "an edge inside a subgraph"},
		{"flowchart TB\n  subgraph s[\"S\"]\n    a[\"A\"]\n  end\n  s --> a\n", 5, "stays inside one box"},
		{"flowchart TB\n  subgraph s[\"S\"]\n    a[\"A\"]\n    b[\"B\"]\n  end\n  a --> b\n", 6, "stays inside one box"},
		{"flowchart LR\n  a[\"A\"] --> b[\"B\"] --> c[\"C\"]\n", 2, "text after the end of an edge"},
		{"flowchart LR\n  end[\"A\"]\n", 2, "the word end is not a node id"},
		{"flowchart LR\n  %% a comment\n", 2, "a node id of letters"},
		{"flowchart LR\n  a[\"A\"]\n  style a fill:#f00\n", 3, "an edge is"},
		{"flowchart LR\n  a[\"A\"]\n  click a call\n", 3, "an edge is"},
		{"sequenceDiagram\n", 1, "a sequence diagram with no participant"},
		{"sequenceDiagram\n  participant A\n  Note right of A: x\n", 3, "a line of a sequence diagram"},
		{"sequenceDiagram\n  participant A\n  loop Every minute\n", 3, "a line of a sequence diagram"},
		{"sequenceDiagram\n  participant A\n  autonumber\n", 3, "a line of a sequence diagram"},
		{"sequenceDiagram\n  actor A\n", 2, "a line of a sequence diagram"},
		{"sequenceDiagram\n  participant A\n  A->>B: x\n", 3, "B, which no participant line above declares"},
		{"sequenceDiagram\n  participant B\n  A->>B: x\n", 3, "A, which no participant line above declares"},
		{"sequenceDiagram\n  participant A\n  A->A: x\n", 3, "a line of a sequence diagram"},
		{"sequenceDiagram\n  participant A\n  A-->>A: x\n", 3, "a line of a sequence diagram"},
		{"sequenceDiagram\n  participant A\n  A->>A x\n", 3, "a line of a sequence diagram"},
		{"sequenceDiagram\n  participant A\n  A->>A:   \n", 3, "a message with no text"},
		{"sequenceDiagram\n  participant A\n  A->>A: one; two\n", 3, "the character ;"},
		{"sequenceDiagram\n  participant A\n  A->>A: <br>\n", 3, "the character <"},
		{"sequenceDiagram\n  participant A\n  participant A as B\n", 3, "declared twice"},
		{"sequenceDiagram\n  participant A as\n", 2, "a participant is"},
		{"sequenceDiagram\n  participant A as  \n", 2, "a participant is"},
		{"sequenceDiagram\n  participant A-B\n", 2, "a participant is"},
		{"sequenceDiagram\n  participant\n", 2, "a line of a sequence diagram"},
		// The layout refuses a character that the font of the diagrams lacks.
		{"flowchart LR\n  a[\"漢\"]\n", 2, "is not in the font of the diagrams"},
		{"sequenceDiagram\n  participant A as 漢\n", 2, "is not in the font of the diagrams"},
		{"sequenceDiagram\n  participant A\n  A->>A: 漢\n", 3, "is not in the font of the diagrams"},
	}
	for item in refused {
		picture, problem := diagram_of(&font, item.body)
		testing.expectf(t, problem.text != "", "%q is accepted", item.body)
		testing.expectf(t, problem.line == item.line, "%q: the fault is on line %d, not %d: %s", item.body, problem.line, item.line, problem.text)
		testing.expectf(t, strings.contains(problem.text, item.fragment), "%q: the fault %q does not say %q", item.body, problem.text, item.fragment)
		testing.expect_value(t, len(picture.boxes), 0)
		testing.expect_value(t, len(picture.lines), 0)
	}
}

@(test)
site_diagram_refuses_a_cycle :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	// The edges a --> b (line 2), b --> c (line 3) and c --> a (line 4)
	// make a cycle; d --> a leads into it. The line is the first edge of
	// the cycle.
	picture, problem := diagram_of(&font, "flowchart LR\n  a[\"A\"] --> b[\"B\"]\n  b --> c[\"C\"]\n  c --> a\n  d[\"D\"] --> a\n")
	testing.expect_value(t, problem.line, 2)
	testing.expectf(t, strings.contains(problem.text, "a --> b --> c --> a"), "the fault: %s", problem.text)
	testing.expect_value(t, len(picture.boxes), 0)
	// A cycle of two, between subgraphs.
	_, two := diagram_of(&font, "flowchart TB\n  subgraph s[\"S\"]\n    a[\"A\"]\n  end\n  subgraph u[\"U\"]\n    b[\"B\"]\n  end\n  s --> u\n  b --> a\n")
	testing.expect_value(t, two.line, 8)
	testing.expectf(t, strings.contains(two.text, "cycle"), "the fault: %s", two.text)
	// Two edges in the same direction are no cycle.
	_, twice := diagram_of(&font, "flowchart LR\n  a[\"A\"] --> b[\"B\"]\n  a --> b\n")
	testing.expect_value(t, twice.text, "")
}

@(test)
site_diagram_wraps_a_long_label :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	repeated := strings.repeat("label ", 33, context.temp_allocator)
	words := strings.concatenate({repeated[:198], "ok"}, context.temp_allocator)
	testing.expect_value(t, len(words), 200)
	word := strings.repeat("x", 200, context.temp_allocator)
	bodies := [?]string {
		fmt.tprintf("flowchart TB\n  a[\"%s\"] -- \"%s\" --> b[\"%s\"]\n", words, words, word),
		fmt.tprintf("flowchart LR\n  subgraph s[\"%s\"]\n    a[\"%s\"]\n  end\n  b[\"B\"] -. \"%s\" .-> s\n", words, word, words),
		fmt.tprintf("sequenceDiagram\n  participant A as %s\n  participant B as %s\n  A->>B: %s\n  B->>B: %s\n  B->>A: %s\n", words, word, words, words, word),
	}
	for body, body_index in bodies {
		picture, problem := diagram_of(&font, body)
		testing.expectf(t, problem.text == "", "the text %d is refused: %s", body_index, problem.text)
		name := fmt.tprintf("the long labels %d", body_index)
		picture_check(t, &font, &picture, name)
		labels_on_their_edges(t, &picture, name)
		for box in picture.boxes {
			joined := strings.join(box.text.lines, " ", context.temp_allocator)
			if joined == words {
				// The sentence wraps onto more lines, each inside its bound.
				testing.expectf(t, len(box.text.lines) > 1, "%s: a label of 200 characters is on one line", name)
				for width in box.text.widths {
					testing.expectf(t, width <= box.text.limit, "%s: a line of %d pixels passes its bound %d", name, width, box.text.limit)
				}
			}
			if joined == word {
				// A word is never cut: it is one line, wider than its bound,
				// and its box grows to hold it.
				testing.expect_value(t, len(box.text.lines), 1)
				testing.expectf(t, box.text.width > box.text.limit, "%s: the word of 200 characters is %d pixels, inside its bound %d", name, box.text.width, box.text.limit)
				testing.expect(t, site_diagram_rectangle_inside(box.text_place, box.rectangle))
			}
		}
	}
}

@(test)
site_diagram_lays_out_thirty_nodes :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	NODE_COUNT :: 30
	for direction in ([]string{"TB", "LR"}) {
		// Thirty nodes: a chain, a fan from the first node, edges that skip
		// ranks, labels, dotted edges.
		body := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&body, "flowchart %s\n", direction)
		for node in 0 ..< NODE_COUNT {
			fmt.sbprintf(&body, "  n%d[\"Node number %d\"]\n", node, node)
		}
		for node in 1 ..< NODE_COUNT {
			switch node % 4 {
			case 0:
				fmt.sbprintf(&body, "  n%d --> n%d\n", node - 1, node)
			case 1:
				fmt.sbprintf(&body, "  n0 -- \"fan %d\" --> n%d\n", node, node)
			case 2:
				fmt.sbprintf(&body, "  n%d -. \"skip\" .-> n%d\n", max(node - 5, 0), node)
			case 3:
				fmt.sbprintf(&body, "  n%d --> n%d\n", node / 2, node)
			}
		}
		picture, problem := diagram_of(&font, strings.to_string(body))
		testing.expectf(t, problem.text == "", "%s: %s", direction, problem.text)
		name := fmt.tprintf("thirty nodes %s", direction)
		node_boxes := 0
		for box in picture.boxes {
			node_boxes += box.kind == .Node ? 1 : 0
		}
		testing.expect_value(t, node_boxes, NODE_COUNT)
		testing.expect_value(t, len(picture.lines), NODE_COUNT - 1)
		picture_check(t, &font, &picture, name)
		labels_on_their_edges(t, &picture, name)
	}
	// Thirty nodes in three subgraphs, with edges to subgraphs and to the
	// nodes inside them.
	for direction in ([]string{"TB", "LR"}) {
		body := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&body, "flowchart %s\n", direction)
		for group in 0 ..< 3 {
			fmt.sbprintf(&body, "  subgraph g%d[\"Group %d of ten nodes\"]\n", group, group)
			for node in 0 ..< NODE_COUNT / 3 {
				fmt.sbprintf(&body, "    n%d_%d[\"Node %d\"]\n", group, node, node)
			}
			strings.write_string(&body, "  end\n")
		}
		strings.write_string(&body, "  g0 -- \"to the group\" --> g1\n  g1 --> g2\n  n0_3 -. \"to a node\" .-> n2_7\n  g0 --> n1_9\n")
		picture, problem := diagram_of(&font, strings.to_string(body))
		testing.expectf(t, problem.text == "", "%s: %s", direction, problem.text)
		name := fmt.tprintf("thirty nodes in subgraphs %s", direction)
		picture_check(t, &font, &picture, name)
		labels_on_their_edges(t, &picture, name)
	}
}

@(test)
site_diagram_draws_the_diagrams_of_the_guide :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	data, read_error := os.read_entire_file("docs/ARCHITECTURE.md", context.temp_allocator)
	testing.expect(t, read_error == nil)
	lines := strings.split_lines(string(data), context.temp_allocator)
	count := 0
	for index := 0; index < len(lines); index += 1 {
		if strings.trim_space(lines[index]) != "```" + SITE_DIAGRAM_LANGUAGE {
			continue
		}
		body := strings.builder_make(context.temp_allocator)
		fence_line := index + 1
		index += 1
		for index < len(lines) && strings.trim_space(lines[index]) != "```" {
			strings.write_string(&body, lines[index])
			strings.write_byte(&body, '\n')
			index += 1
		}
		count += 1
		name := fmt.tprintf("docs/ARCHITECTURE.md, line %d", fence_line)
		picture, problem := diagram_of(&font, strings.to_string(body))
		testing.expectf(t, problem.text == "", "%s: %s", name, problem.text)
		testing.expectf(t, len(picture.boxes) > 0, "%s: no box", name)
		picture_check(t, &font, &picture, name)
		labels_on_their_edges(t, &picture, name)
		// The picture is SVG with a title, and the text of the diagram
		// stays in the page.
		html := strings.builder_make(context.temp_allocator)
		site_diagram_html_write(&html, &picture, &font, "diagram", "A <title>", strings.to_string(body))
		written := strings.to_string(html)
		testing.expect(t, strings.contains(written, "<svg class=\"diagram-picture\""))
		testing.expect(t, strings.contains(written, "role=\"img\" aria-labelledby=\"diagram-title\""))
		testing.expect(t, strings.contains(written, "<title id=\"diagram-title\">A &lt;title&gt;</title>"))
		testing.expect(t, strings.contains(written, "<details class=\"diagram-source\">"))
		testing.expect(t, !strings.contains(written, "style="))
		testing.expect_value(t, strings.count(written, "<text "), site_diagram_line_count(&picture))
		testing.expect_value(t, strings.count(written, "<polygon "), site_diagram_arrow_count(&picture))
	}
	// The five diagrams of the guide: one flowchart TB, one flowchart LR,
	// three sequence diagrams.
	testing.expect_value(t, count, 5)
}

// The lines of text of a picture, and its arrows: each is one element.
@(private = "file")
site_diagram_line_count :: proc(picture: ^Site_Diagram_Picture) -> int {
	count := 0
	for box in picture.boxes {
		count += len(box.text.lines)
	}
	return count
}

@(private = "file")
site_diagram_arrow_count :: proc(picture: ^Site_Diagram_Picture) -> int {
	count := 0
	for line in picture.lines {
		count += line.arrow ? 1 : 0
	}
	return count
}

@(test)
site_diagram_draws_a_sequence_in_rows :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	body := "sequenceDiagram\n  participant A as First\n  participant B\n  participant C as Third participant\n  A->>C: across the middle lifeline\n  C->>A: back\n  C->>C: to itself, at the right of the last lifeline\n  B->>B: to itself, before the next lifeline\n"
	picture, problem := diagram_of(&font, body)
	testing.expect_value(t, problem.text, "")
	picture_check(t, &font, &picture, "a sequence")
	middles: [3]int
	for index in 0 ..< 3 {
		box := picture.boxes[index]
		testing.expect_value(t, box.kind, Site_Diagram_Box_Kind.Participant)
		middles[index] = box.rectangle.x + box.rectangle.width / 2
	}
	testing.expect(t, middles[0] < middles[1] && middles[1] < middles[2])
	previous_bottom := 0
	for line in picture.lines {
		if line.kind != .Message {
			continue
		}
		label := picture.boxes[line.label_box]
		// The messages are rows in their order.
		testing.expect(t, label.rectangle.y >= previous_bottom)
		for point in line.points {
			previous_bottom = max(previous_bottom, point.y)
		}
		if line.from_box == line.to_box {
			// A loop: its text at the right of the loop, before the next
			// lifeline, inside the picture.
			loop_right := line.points[1].x
			testing.expect(t, label.rectangle.x > loop_right)
			if line.from_box + 1 < 3 {
				testing.expect(t, label.rectangle.x + label.rectangle.width < middles[line.from_box + 1])
			}
		} else {
			left, right := min(middles[line.from_box], middles[line.to_box]), max(middles[line.from_box], middles[line.to_box])
			testing.expect(t, label.rectangle.x > left && label.rectangle.x + label.rectangle.width < right)
		}
	}
	// A diagram with participants and no message: the boxes and their
	// lifelines.
	alone, alone_problem := diagram_of(&font, "sequenceDiagram\n  participant A\n")
	testing.expect_value(t, alone_problem.text, "")
	testing.expect_value(t, len(alone.boxes), 1)
	testing.expect_value(t, len(alone.lines), 1)
	picture_check(t, &font, &alone, "one participant")
}

@(test)
site_diagram_measures_with_the_font :: proc(t: ^testing.T) {
	font, ok := diagram_font(t)
	if !ok {
		return
	}
	testing.expect_value(t, site_diagram_text_width(&font, ""), 0)
	one := site_diagram_text_width(&font, "M")
	testing.expect(t, one > 0)
	testing.expect(t, site_diagram_text_width(&font, "MM") >= one)
	testing.expect(t, font.line_height >= SITE_DIAGRAM_LINE_HEIGHT)
	testing.expect(t, font.baseline > 0 && font.baseline <= font.line_height)
	// A text that fits its bound stays on one line; a bound of 0 puts each
	// word on its own line, and no line is empty.
	text := site_diagram_wrap(&font, "two words", 1000)
	testing.expect_value(t, len(text.lines), 1)
	narrow := site_diagram_wrap(&font, "two  words", 0)
	testing.expect_value(t, len(narrow.lines), 2)
	testing.expect_value(t, narrow.lines[0], "two")
	testing.expect_value(t, narrow.lines[1], "words")
	// A damaged font is refused, not read past its end.
	_, short_problem := site_diagram_font_open([]u8{0, 1, 0, 0})
	testing.expect(t, short_problem != "")
	_, empty_problem := site_diagram_font_open(nil)
	testing.expect(t, empty_problem != "")
}
