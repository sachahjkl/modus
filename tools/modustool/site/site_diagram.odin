// The diagrams of the guides (docs/SITE.md, "The diagrams"): a fence
// "mermaid" of a guide becomes a picture in SVG inside the page, drawn when
// the site is built, with no script and no other file than the font. The
// text of the diagram stays in the page under the picture. A diagram that
// the tool cannot draw stops the command with its file and its line.
package site

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "modustool:foundation"
import "modustool:resources"

// The font of the diagrams in the site, and the name of its family in the
// style sheet. The text of a picture asks for this font only, so the
// widths that the layout measured are the widths that the browser draws.
SITE_DIAGRAM_FONT :: "fonts/" + resources.INTERFACE_VECTOR_FONT + ".ttf"
SITE_DIAGRAM_FONT_FAMILY :: "modus diagram"
SITE_DIAGRAM_LANGUAGE :: "mermaid"

// site_diagram_fence_write writes the picture of a fence "mermaid" of a
// guide in the place of its block. A diagram that the tool cannot draw is
// recorded in the second pass over the guides only, so that it is printed
// once, and its text is shown as a block of code.
site_diagram_fence_write :: proc(renderer: ^Site_Renderer, body: string, fence_line: int) {
	site := renderer.site
	html, problem := site_diagram_html(renderer, body)
	if problem.text == "" {
		strings.write_string(&renderer.builder, html)
		return
	}
	if !site.document_headings_pending {
		append(&site.diagram_problems, fmt.tprintf("%s, line %d: %s", site_renderer_place(renderer), fence_line + problem.line, problem.text))
	}
	strings.write_string(&renderer.builder, "<pre><code>")
	foundation.html_escape(&renderer.builder, body)
	strings.write_string(&renderer.builder, "</code></pre>\n")
}

// site_diagram_html reads, lays out and writes one diagram.
site_diagram_html :: proc(renderer: ^Site_Renderer, body: string) -> (html: string, problem: Site_Diagram_Problem) {
	bytes, read_error := os.read_entire_file(SITE_DIAGRAM_FONT_SOURCE, context.temp_allocator)
	if read_error != nil {
		return "", {line = 0, text = fmt.tprintf("cannot read the font of the diagrams %s", SITE_DIAGRAM_FONT_SOURCE)}
	}
	font, font_problem := site_diagram_font_open(bytes)
	if font_problem != "" {
		return "", {line = 0, text = font_problem}
	}
	diagram, parse_problem := site_diagram_parse(body)
	if parse_problem.text != "" {
		return "", parse_problem
	}
	picture, draw_problem := site_diagram_draw(&diagram, &font)
	if draw_problem.text != "" {
		return "", draw_problem
	}
	heading := len(renderer.headings) > 0 ? renderer.headings[len(renderer.headings) - 1].text : "The page"
	id := site_unique_id(renderer, "diagram")
	b := strings.builder_make(context.temp_allocator)
	site_diagram_html_write(&b, &picture, &font, id, site_diagram_title(&diagram, heading), body)
	return strings.to_string(b), {}
}

// site_diagram_title gives the name of a picture for a screen reader: the
// heading above it and what it shows. The text of the diagram follows the
// picture in the page.
site_diagram_title :: proc(diagram: ^Site_Diagram, heading: string) -> string {
	if diagram.kind == .Sequence {
		return fmt.tprintf("%s: a sequence diagram of %d participants and %d messages", heading, len(diagram.sequence.participants), len(diagram.sequence.messages))
	}
	return fmt.tprintf("%s: a flowchart of %d boxes, %d subgraphs and %d edges", heading, len(diagram.flowchart.nodes), len(diagram.flowchart.groups), len(diagram.flowchart.edges))
}

// site_diagram_html_write writes the figure: the picture, then the text of
// the diagram in a disclosure. The order of the drawing: the lifelines,
// the subgraphs, the nodes and the participants, the edges and the
// messages, then the labels on their background over the lines.
site_diagram_html_write :: proc(b: ^strings.Builder, picture: ^Site_Diagram_Picture, font: ^Site_Diagram_Font, id, title, body: string) {
	fmt.sbprintf(b, "<figure class=\"diagram\" id=\"%s\">\n", id)
	fmt.sbprintf(b, "<svg class=\"diagram-picture\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\" aria-labelledby=\"%s-title\">\n", picture.width, picture.height, picture.width, picture.height, id)
	fmt.sbprintf(b, "<title id=\"%s-title\">", id)
	site_plain(b, title)
	strings.write_string(b, "</title>\n")
	for &line in picture.lines {
		if line.kind == .Lifeline {
			site_diagram_line_write(b, &line, "diagram-lifeline")
		}
	}
	for &box in picture.boxes {
		if box.kind == .Group {
			site_diagram_box_write(b, font, &box, "diagram-group", "diagram-text diagram-group-label")
		}
	}
	for &box in picture.boxes {
		if box.kind == .Node || box.kind == .Participant {
			site_diagram_box_write(b, font, &box, "diagram-node", "diagram-text")
		}
	}
	for &line in picture.lines {
		if line.kind != .Lifeline {
			site_diagram_line_write(b, &line, line.style == .Dotted ? "diagram-line diagram-dotted" : "diagram-line")
		}
	}
	for &box in picture.boxes {
		if box.kind == .Edge_Label {
			site_diagram_box_write(b, font, &box, "diagram-label", "diagram-text")
		}
	}
	strings.write_string(b, "</svg>\n<details class=\"diagram-source\"><summary>The text of the diagram</summary><pre><code>")
	foundation.html_escape(b, body)
	strings.write_string(b, "</code></pre></details>\n</figure>\n")
}

// site_diagram_box_write writes a rectangle and its text, one element for
// each line. Each line is held to the width that the layout measured, so
// that a browser that sets the font a little wider or narrower still keeps
// the text inside its box.
site_diagram_box_write :: proc(b: ^strings.Builder, font: ^Site_Diagram_Font, box: ^Site_Diagram_Box, box_class, text_class: string) {
	rectangle := box.rectangle
	fmt.sbprintf(b, "<rect class=\"%s\" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"/>\n", box_class, rectangle.x, rectangle.y, rectangle.width, rectangle.height)
	for line, line_index in box.text.lines {
		x := box.text_place.x + box.text_place.width / 2
		y := box.text_place.y + line_index * font.line_height + font.baseline
		fmt.sbprintf(b, "<text class=\"%s\" x=\"%d\" y=\"%d\" text-anchor=\"middle\" textLength=\"%d\" lengthAdjust=\"spacingAndGlyphs\">", text_class, x, y, box.text.widths[line_index])
		foundation.html_escape(b, line)
		strings.write_string(b, "</text>\n")
	}
}

// site_diagram_line_write writes a line, and its arrow head at its last
// point: the line stops at the base of the head, so its end does not show
// past the point of the head.
site_diagram_line_write :: proc(b: ^strings.Builder, line: ^Site_Diagram_Line, class: string) {
	count := len(line.points)
	if count < 2 {
		return
	}
	fmt.sbprintf(b, "<polyline class=\"%s\" points=\"", class)
	for point, index in line.points[:count - 1] {
		if index > 0 {
			strings.write_byte(b, ' ')
		}
		fmt.sbprintf(b, "%d,%d", point.x, point.y)
	}
	tip := line.points[count - 1]
	if !line.arrow {
		fmt.sbprintf(b, " %d,%d\"/>\n", tip.x, tip.y)
		return
	}
	before := line.points[count - 2]
	along_x, along_y := f64(tip.x - before.x), f64(tip.y - before.y)
	length := math.sqrt(along_x * along_x + along_y * along_y)
	along_x, along_y = along_x / length, along_y / length
	base_x := f64(tip.x) - along_x * SITE_DIAGRAM_ARROW_LENGTH
	base_y := f64(tip.y) - along_y * SITE_DIAGRAM_ARROW_LENGTH
	fmt.sbprintf(b, " %.1f,%.1f\"/>\n", base_x, base_y)
	half :: SITE_DIAGRAM_ARROW_HALF_WIDTH
	fmt.sbprintf(b, "<polygon class=\"diagram-arrow\" points=\"%d,%d %.1f,%.1f %.1f,%.1f\"/>\n", tip.x, tip.y, base_x - along_y * half, base_y + along_x * half, base_x + along_y * half, base_y - along_x * half)
}

// site_diagram_rules gives the rules of the style sheet for the diagrams.
// The colors are the tokens of the site, so a diagram follows the light and
// the dark form with no rule of its own. The picture shrinks to the column
// and keeps its shape; its text is the font that the layout measured.
site_diagram_rules :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "/* The diagrams of the guides (docs/SITE.md, \"The diagrams\"). */\n")
	strings.write_string(&b, "@font-face { font-family: \"" + SITE_DIAGRAM_FONT_FAMILY + "\"; src: url(\"" + SITE_DIAGRAM_FONT + "\") format(\"truetype\"); font-weight: 400; font-style: normal; font-display: block; }\n")
	strings.write_string(&b, ".diagram { margin: 0 0 24px; }\n")
	strings.write_string(&b, ".diagram-picture { display: block; max-width: 100%; height: auto; }\n")
	strings.write_string(&b, ".diagram-text { font-family: \"" + SITE_DIAGRAM_FONT_FAMILY + "\", var(--reading); font-size: ")
	strings.write_int(&b, SITE_DIAGRAM_FONT_SIZE)
	strings.write_string(&b, "px; font-weight: 400; font-style: normal; font-synthesis: none; font-kerning: normal; letter-spacing: 0; fill: var(--text); }\n")
	strings.write_string(&b, ".diagram-group-label { fill: var(--dim); }\n")
	strings.write_string(&b, ".diagram-group { fill: var(--card-bottom); stroke: var(--line); stroke-width: 1px; }\n")
	strings.write_string(&b, ".diagram-node { fill: var(--card-top); stroke: var(--dim); stroke-width: 1px; }\n")
	strings.write_string(&b, ".diagram-label { fill: var(--background); }\n")
	strings.write_string(&b, ".diagram-line { fill: none; stroke: var(--dim); stroke-width: 1.5px; }\n")
	strings.write_string(&b, ".diagram-dotted { stroke-dasharray: 6 4; }\n")
	strings.write_string(&b, ".diagram-arrow { fill: var(--dim); }\n")
	strings.write_string(&b, ".diagram-lifeline { fill: none; stroke: var(--line); stroke-width: 1px; }\n")
	strings.write_string(&b, ".diagram-source summary { color: var(--dim); font-size: 14px; cursor: pointer; }\n")
	return strings.to_string(b)
}
