// The reader of the text of a diagram of a guide (docs/SITE.md, "The
// diagrams"). It reads the subset of mermaid that the guides use, and no
// more: a flowchart LR or TB with nodes, edges and subgraphs, and a
// sequence diagram with participants and messages. Each other line is a
// problem with its line, so that the command stops on a diagram that the
// tool cannot draw, never draws a part of it.
package modustool

import "core:fmt"
import "core:strings"

Site_Diagram_Kind :: enum {
	Flowchart,
	Sequence,
}

// The direction of a flowchart: the axis along which an edge goes from its
// source to its target.
Site_Diagram_Direction :: enum {
	Left_To_Right,
	Top_To_Bottom,
}

Site_Diagram_Edge_Style :: enum {
	Solid,
	Dotted,
}

// A fault of the text of a diagram. line: the line in the body of the
// fence, from 1; 0 names the line of the fence itself.
Site_Diagram_Problem :: struct {
	line: int,
	text: string,
}

Site_Diagram_Node :: struct {
	id, label: string,
	group:     int, // The subgraph that holds it, or -1.
	line:      int,
}

Site_Diagram_Group :: struct {
	id, label: string,
	line:      int,
	nodes:     [dynamic]int, // In the order of the text.
}

// One end of an edge: a node or a subgraph, by its index.
Site_Diagram_End :: struct {
	id:    string,
	group: bool,
	index: int,
}

Site_Diagram_Edge :: struct {
	from, to: Site_Diagram_End,
	label:    string, // "" for an edge with no label.
	style:    Site_Diagram_Edge_Style,
	line:     int,
}

Site_Diagram_Flowchart :: struct {
	direction: Site_Diagram_Direction,
	nodes:     [dynamic]Site_Diagram_Node,
	groups:    [dynamic]Site_Diagram_Group,
	edges:     [dynamic]Site_Diagram_Edge,
	line:      int, // The line of the head "flowchart".
}

Site_Diagram_Participant :: struct {
	id, name: string,
	line:     int,
}

Site_Diagram_Message :: struct {
	from, to: int, // Indices of the participants; equal for a message to the same participant.
	text:     string,
	line:     int,
}

Site_Diagram_Sequence :: struct {
	participants: [dynamic]Site_Diagram_Participant,
	messages:     [dynamic]Site_Diagram_Message,
	line:         int, // The line of the head "sequenceDiagram".
}

Site_Diagram :: struct {
	kind:      Site_Diagram_Kind,
	flowchart: Site_Diagram_Flowchart,
	sequence:  Site_Diagram_Sequence,
}

// site_diagram_parse reads the body of a fence "mermaid". A problem with a
// text means that the diagram is refused.
site_diagram_parse :: proc(body: string) -> (diagram: Site_Diagram, problem: Site_Diagram_Problem) {
	lines := strings.split_lines(body, context.temp_allocator)
	head := -1
	for line, index in lines {
		if strings.trim_space(line) != "" {
			head = index
			break
		}
	}
	if head < 0 {
		return {}, {line = 0, text = "an empty diagram"}
	}
	fields := strings.fields(strings.trim_space(lines[head]), context.temp_allocator)
	switch {
	case len(fields) == 1 && fields[0] == "sequenceDiagram":
		diagram.kind = .Sequence
		diagram.sequence, problem = site_diagram_sequence_parse(lines, head)
	case len(fields) == 2 && fields[0] == "flowchart" && (fields[1] == "LR" || fields[1] == "TB"):
		diagram.kind = .Flowchart
		diagram.flowchart, problem = site_diagram_flowchart_parse(lines, head, fields[1] == "LR" ? Site_Diagram_Direction.Left_To_Right : Site_Diagram_Direction.Top_To_Bottom)
	case len(fields) >= 1 && fields[0] == "flowchart":
		problem = {line = head + 1, text = "a flowchart has the direction LR or TB: \"flowchart LR\" or \"flowchart TB\""}
	case:
		problem = {line = head + 1, text = fmt.tprintf("the diagram kind %q: the site draws \"flowchart LR\", \"flowchart TB\" and \"sequenceDiagram\"", strings.trim_space(lines[head]))}
	}
	return
}

// site_diagram_text_problem says why a text of a label cannot be drawn as
// it is written: mermaid reads these characters as markup or as the end of
// a statement, so the text would not be the text that mermaid shows.
site_diagram_text_problem :: proc(text: string) -> string {
	for character in text {
		switch character {
		case '<', '>', '#', ';', '`':
			return fmt.tprintf("the character %c in a label, which mermaid reads as markup", character)
		}
		if character < ' ' || character == 0x7F {
			return "a control character in a label"
		}
	}
	return ""
}

site_diagram_is_id_byte :: proc(character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_'
}

// site_diagram_id_length gives the length of the id at the start of text:
// letters, digits and "_".
site_diagram_id_length :: proc(text: string) -> int {
	length := 0
	for length < len(text) && site_diagram_is_id_byte(text[length]) {
		length += 1
	}
	return length
}

// The parts of `id` or `id["label"]` at the start of a text.
Site_Diagram_Named :: struct {
	id:        string,
	label:     string,
	has_label: bool,
	rest:      string, // The text after it, with no space at its start.
}

// site_diagram_named_parse reads `id` or `id["label"]` at the start of text.
site_diagram_named_parse :: proc(text: string) -> (named: Site_Diagram_Named, problem: string) {
	length := site_diagram_id_length(text)
	if length == 0 {
		return {}, fmt.tprintf("a node id of letters, digits and _ is expected at %q", text)
	}
	named.id = text[:length]
	if named.id == "end" || named.id == "subgraph" {
		return {}, fmt.tprintf("the word %s is not a node id", named.id)
	}
	rest := text[length:]
	if strings.has_prefix(rest, "[\"") {
		closing := strings.index_byte(rest[2:], '"')
		if closing < 0 || !strings.has_prefix(rest[2 + closing + 1:], "]") {
			return {}, "a label is a text in quotes inside brackets: id[\"label\"]"
		}
		named.label = strings.trim_space(rest[2:2 + closing])
		named.has_label = true
		if named.label == "" {
			return {}, fmt.tprintf("the node %s has an empty label", named.id)
		}
		if text_problem := site_diagram_text_problem(named.label); text_problem != "" {
			return {}, text_problem
		}
		rest = rest[2 + closing + 2:]
	} else if len(rest) > 0 && strings.index_byte("([{>", rest[0]) >= 0 {
		return {}, fmt.tprintf("the node %s has a shape other than a box: write id[\"label\"]", named.id)
	}
	named.rest = strings.trim_left_space(rest)
	return named, ""
}

// site_diagram_arrow_parse reads the arrow of an edge at the start of text:
// `-->`, `-- "label" -->` or `-. "label" .->`.
site_diagram_arrow_parse :: proc(text: string) -> (style: Site_Diagram_Edge_Style, label: string, rest: string, problem: string) {
	refused :: "an edge is -->, -- \"label\" --> or -. \"label\" .->"
	opening, closing_arrow := "", ""
	switch {
	case strings.has_prefix(text, "-->"):
		return .Solid, "", strings.trim_left_space(text[3:]), ""
	case strings.has_prefix(text, "-- \""):
		opening, closing_arrow, style = "-- \"", "-->", .Solid
	case strings.has_prefix(text, "-. \""):
		opening, closing_arrow, style = "-. \"", ".->", .Dotted
	case:
		return .Solid, "", "", refused
	}
	after := text[len(opening):]
	quote := strings.index_byte(after, '"')
	if quote < 0 {
		return .Solid, "", "", refused
	}
	label = strings.trim_space(after[:quote])
	if label == "" {
		return .Solid, "", "", "an edge with an empty label"
	}
	if text_problem := site_diagram_text_problem(label); text_problem != "" {
		return .Solid, "", "", text_problem
	}
	after = strings.trim_left_space(after[quote + 1:])
	if !strings.has_prefix(after, closing_arrow) {
		return .Solid, "", "", refused
	}
	return style, label, strings.trim_left_space(after[len(closing_arrow):]), ""
}

site_diagram_flowchart_parse :: proc(lines: []string, head: int, direction: Site_Diagram_Direction) -> (chart: Site_Diagram_Flowchart, problem: Site_Diagram_Problem) {
	chart.direction = direction
	chart.line = head + 1
	chart.nodes = make([dynamic]Site_Diagram_Node, context.temp_allocator)
	chart.groups = make([dynamic]Site_Diagram_Group, context.temp_allocator)
	chart.edges = make([dynamic]Site_Diagram_Edge, context.temp_allocator)
	declared := make(map[string]int, context.temp_allocator) // An id to the line that declares it.
	open_group := -1
	declare_node :: proc(chart: ^Site_Diagram_Flowchart, declared: ^map[string]int, named: Site_Diagram_Named, group, line: int) -> string {
		if first, found := declared^[named.id]; found {
			return fmt.tprintf("the id %s is declared twice: on line %d and here", named.id, first)
		}
		declared^[named.id] = line
		append(&chart.nodes, Site_Diagram_Node{id = named.id, label = named.label, group = group, line = line})
		if group >= 0 {
			append(&chart.groups[group].nodes, len(chart.nodes) - 1)
		}
		return ""
	}
	for index in head + 1 ..< len(lines) {
		line := index + 1
		text := strings.trim_space(lines[index])
		if text == "" {
			continue
		}
		if text == "end" {
			if open_group < 0 {
				return chart, {line = line, text = "an end with no subgraph"}
			}
			if len(chart.groups[open_group].nodes) == 0 {
				return chart, {line = chart.groups[open_group].line, text = fmt.tprintf("the subgraph %s holds no node", chart.groups[open_group].id)}
			}
			open_group = -1
			continue
		}
		if strings.has_prefix(text, "subgraph ") {
			if open_group >= 0 {
				return chart, {line = line, text = "a subgraph inside a subgraph"}
			}
			named, named_problem := site_diagram_named_parse(strings.trim_space(text[len("subgraph "):]))
			if named_problem != "" {
				return chart, {line = line, text = named_problem}
			}
			if !named.has_label {
				return chart, {line = line, text = fmt.tprintf("the subgraph %s has no label: write subgraph id[\"label\"]", named.id)}
			}
			if named.rest != "" {
				return chart, {line = line, text = fmt.tprintf("text after the label of the subgraph %s", named.id)}
			}
			if first, found := declared[named.id]; found {
				return chart, {line = line, text = fmt.tprintf("the id %s is declared twice: on line %d and here", named.id, first)}
			}
			declared[named.id] = line
			append(&chart.groups, Site_Diagram_Group{id = named.id, label = named.label, line = line, nodes = make([dynamic]int, context.temp_allocator)})
			open_group = len(chart.groups) - 1
			continue
		}
		first, first_problem := site_diagram_named_parse(text)
		if first_problem != "" {
			return chart, {line = line, text = first_problem}
		}
		if first.rest == "" {
			if !first.has_label {
				return chart, {line = line, text = fmt.tprintf("the node %s has no label: write id[\"label\"]", first.id)}
			}
			if declare_problem := declare_node(&chart, &declared, first, open_group, line); declare_problem != "" {
				return chart, {line = line, text = declare_problem}
			}
			continue
		}
		if open_group >= 0 {
			return chart, {line = line, text = "an edge inside a subgraph: write the edges after its end"}
		}
		style, label, after_arrow, arrow_problem := site_diagram_arrow_parse(first.rest)
		if arrow_problem != "" {
			return chart, {line = line, text = arrow_problem}
		}
		second, second_problem := site_diagram_named_parse(after_arrow)
		if second_problem != "" {
			return chart, {line = line, text = second_problem}
		}
		if second.rest != "" {
			return chart, {line = line, text = fmt.tprintf("text after the end of an edge: %q", second.rest)}
		}
		for named in ([]Site_Diagram_Named{first, second}) {
			if named.has_label {
				if declare_problem := declare_node(&chart, &declared, named, -1, line); declare_problem != "" {
					return chart, {line = line, text = declare_problem}
				}
			}
		}
		append(&chart.edges, Site_Diagram_Edge{from = {id = first.id}, to = {id = second.id}, label = label, style = style, line = line})
	}
	if open_group >= 0 {
		return chart, {line = chart.groups[open_group].line, text = fmt.tprintf("the subgraph %s has no end", chart.groups[open_group].id)}
	}
	if len(chart.nodes) == 0 {
		return chart, {line = chart.line, text = "a flowchart with no node"}
	}
	// The ends of the edges, now that each id is declared: an edge may name
	// a node that a later line declares.
	for &edge in chart.edges {
		for end in ([]^Site_Diagram_End{&edge.from, &edge.to}) {
			found := false
			for node, node_index in chart.nodes {
				if node.id == end.id {
					end^ = {id = end.id, group = false, index = node_index}
					found = true
				}
			}
			for group, group_index in chart.groups {
				if group.id == end.id {
					end^ = {id = end.id, group = true, index = group_index}
					found = true
				}
			}
			if !found {
				return chart, {line = edge.line, text = fmt.tprintf("the edge names %s, which is no node and no subgraph", end.id)}
			}
		}
		if site_diagram_outer_of(&chart, edge.from) == site_diagram_outer_of(&chart, edge.to) {
			return chart, {line = edge.line, text = fmt.tprintf("the edge from %s to %s stays inside one box: a node to itself, or a subgraph and a node inside it", edge.from.id, edge.to.id)}
		}
	}
	return chart, {}
}

// An item at the top of a flowchart: a subgraph, or a node outside each
// subgraph. The layered layout places these.
Site_Diagram_Outer :: struct {
	group: bool,
	index: int,
}

// site_diagram_outer_of gives the item at the top that holds an end.
site_diagram_outer_of :: proc(chart: ^Site_Diagram_Flowchart, end: Site_Diagram_End) -> Site_Diagram_Outer {
	if end.group {
		return {group = true, index = end.index}
	}
	if group := chart.nodes[end.index].group; group >= 0 {
		return {group = true, index = group}
	}
	return {group = false, index = end.index}
}

site_diagram_sequence_parse :: proc(lines: []string, head: int) -> (sequence: Site_Diagram_Sequence, problem: Site_Diagram_Problem) {
	sequence.line = head + 1
	sequence.participants = make([dynamic]Site_Diagram_Participant, context.temp_allocator)
	sequence.messages = make([dynamic]Site_Diagram_Message, context.temp_allocator)
	find :: proc(sequence: ^Site_Diagram_Sequence, id: string) -> int {
		for participant, index in sequence.participants {
			if participant.id == id {
				return index
			}
		}
		return -1
	}
	for index in head + 1 ..< len(lines) {
		line := index + 1
		text := strings.trim_space(lines[index])
		if text == "" {
			continue
		}
		if strings.has_prefix(text, "participant ") {
			rest := strings.trim_space(text[len("participant "):])
			length := site_diagram_id_length(rest)
			after := rest[length:]
			if length == 0 || (after != "" && !strings.has_prefix(after, " as ")) {
				return sequence, {line = line, text = "a participant is \"participant id\" or \"participant id as name\""}
			}
			id := rest[:length]
			name := after == "" ? id : strings.trim_space(after[len(" as "):])
			if name == "" {
				return sequence, {line = line, text = fmt.tprintf("the participant %s has an empty name", id)}
			}
			if text_problem := site_diagram_text_problem(name); text_problem != "" {
				return sequence, {line = line, text = text_problem}
			}
			if first := find(&sequence, id); first >= 0 {
				return sequence, {line = line, text = fmt.tprintf("the participant %s is declared twice: on line %d and here", id, sequence.participants[first].line)}
			}
			append(&sequence.participants, Site_Diagram_Participant{id = id, name = name, line = line})
			continue
		}
		refused :: "a line of a sequence diagram is \"participant id as name\" or a message \"a->>b: text\""
		from_length := site_diagram_id_length(text)
		if from_length == 0 || !strings.has_prefix(text[from_length:], "->>") {
			return sequence, {line = line, text = refused}
		}
		rest := text[from_length + len("->>"):]
		to_length := site_diagram_id_length(rest)
		if to_length == 0 || !strings.has_prefix(rest[to_length:], ":") {
			return sequence, {line = line, text = refused}
		}
		from := find(&sequence, text[:from_length])
		to := find(&sequence, rest[:to_length])
		for end, end_index in ([]int{from, to}) {
			if end < 0 {
				return sequence, {line = line, text = fmt.tprintf("the message names %s, which no participant line above declares", end_index == 0 ? text[:from_length] : rest[:to_length])}
			}
		}
		message := strings.trim_space(rest[to_length + 1:])
		if message == "" {
			return sequence, {line = line, text = "a message with no text"}
		}
		if text_problem := site_diagram_text_problem(message); text_problem != "" {
			return sequence, {line = line, text = text_problem}
		}
		append(&sequence.messages, Site_Diagram_Message{from = from, to = to, text = message, line = line})
	}
	if len(sequence.participants) == 0 {
		return sequence, {line = sequence.line, text = "a sequence diagram with no participant"}
	}
	return sequence, {}
}
