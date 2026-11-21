package build

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "core:fmt"
import "core:slice"
import "core:strings"

// The check of the fact waits (src/md/infrastructure/scenario_fault_loop.md,
// "The check of the fact waits"). A step of a scenario that waits for a
// text of the log does not say whether the text is the sentence of a log
// fact or a line that a process writes as text. The rule needs no mark on
// the step: a text whose words after the head of a process start with the
// fact prefix of some fact template, "storage: ", is a fact wait, and it
// must be the start of a sentence that some fact template with that prefix
// can render, each field a wildcard of its class. A fact whose sentence
// changed, a fact split into two and a list that became one fact for each
// row then fail before any machine starts, not at the end of a hang bound.

// How a field of a template renders, for the match: a Text can hold any
// character, every other field is one word with no space, then the text of
// its integer unit.
Fact_Wait_Field_Class :: enum u8 {
	Any,  // A Text, a text view, a module name, a log body and a status, whose words can hold spaces.
	Word, // An Integer, a hash, bytes: one character or more, none of them a space.
}

// A field of a fact template: its name in the braces, its class and the
// text of its integer unit, which the sentence writes after the value.
Fact_Wait_Field :: struct {
	name:  string,
	class: Fact_Wait_Field_Class,
	unit:  string,
}

// One item of a template for the match.
Fact_Wait_Item_Kind :: enum u8 {
	Literal,  // One byte of the template.
	Any,      // Any characters, none too.
	Word_One, // One character that is not a space.
	Word_More, // Characters that are not a space, none too.
}

Fact_Wait_Item :: struct {
	kind:    Fact_Wait_Item_Kind,
	literal: u8,
}

// A fact template, ready for the match. Its memory is of the allocator
// that made it.
Fact_Wait_Template :: struct {
	template: string,
	modules:  [dynamic]string, // The modules whose fact table holds it: a fact type of a support package is in each module that compiles it in.
	prefix:   string, // Its fact prefix, "storage: ", or "" for a template that starts with a field.
	items:    []Fact_Wait_Item,
	// The form of a text line that a source writes, not a fact template: a
	// wait can match it, but its prefix makes no wait a fact wait.
	text_line: bool,
}

// The templates of every fact type that a build writes, and their fact
// prefixes.
Fact_Wait_Templates :: struct {
	templates:       []Fact_Wait_Template,
	prefixes:        []string, // Sorted, each once.
	// "<module> <prefix>" of each fact template, sorted, each once: a wait
	// with the head of a process is a fact wait only when the module of
	// that name writes a fact of its prefix. The console writes a result
	// of `storage.stores()` as "[console] notes: 2 objects", which no fact
	// of `notes` renders.
	module_prefixes: []string,
}

// The verdict on one text of a step.
Fact_Wait_Verdict :: enum u8 {
	Not_A_Fact_Wait, // Its words start with no fact prefix: a line of the kernel, of the boot program, of a process that writes text.
	Matches,         // Some template with its prefix can render it.
	Matches_None,    // A fact wait that no template can render: the fault.
}

// fact_prefix_of gives the fact prefix of a sentence: its first word, made
// of the characters of a name, then ": ". A sentence that starts with a
// field, or with words that hold a space, has none.
fact_prefix_of :: proc(text: string) -> (prefix: string, ok: bool) {
	colon := strings.index(text, ": ")
	if colon <= 0 {
		return "", false
	}
	for character in transmute([]u8)text[:colon] {
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return "", false
		}
	}
	return text[:colon + 2], true
}

// fact_wait_template_make reads a fact template into its items: each byte
// a literal, "{{" and "}}" one brace, and each field in braces the items
// of its class, then its unit as literals. A field that the list does not
// name is Any: the match then refuses less, never more.
fact_wait_template_make :: proc(template: string, fields: []Fact_Wait_Field, module_name: string, allocator := context.allocator) -> Fact_Wait_Template {
	items := make([dynamic]Fact_Wait_Item, allocator)
	for at := 0; at < len(template); {
		character := template[at]
		switch {
		case character == '{' && at + 1 < len(template) && template[at + 1] == '{', character == '}' && at + 1 < len(template) && template[at + 1] == '}':
			append(&items, Fact_Wait_Item{kind = .Literal, literal = character})
			at += 2
		case character == '{':
			closing := strings.index_byte(template[at:], '}')
			if closing < 0 {
				append(&items, Fact_Wait_Item{kind = .Literal, literal = character})
				at += 1
				continue
			}
			name := template[at + 1:][:closing - 1]
			class := Fact_Wait_Field_Class.Any
			unit := ""
			for field in fields {
				if field.name == name {
					class, unit = field.class, field.unit
				}
			}
			switch class {
			case .Any:
				append(&items, Fact_Wait_Item{kind = .Any})
			case .Word:
				append(&items, Fact_Wait_Item{kind = .Word_One}, Fact_Wait_Item{kind = .Word_More})
			}
			for unit_byte in transmute([]u8)unit {
				append(&items, Fact_Wait_Item{kind = .Literal, literal = unit_byte})
			}
			at += closing + 1
		case:
			append(&items, Fact_Wait_Item{kind = .Literal, literal = character})
			at += 1
		}
	}
	prefix, _ := fact_prefix_of(template)
	modules := make([dynamic]string, allocator)
	append(&modules, strings.clone(module_name, allocator))
	return {template = strings.clone(template, allocator), modules = modules, prefix = strings.clone(prefix, allocator), items = items[:]}
}

// fact_wait_templates_make joins templates and gives their fact prefixes.
fact_wait_templates_make :: proc(templates: []Fact_Wait_Template, allocator := context.allocator) -> Fact_Wait_Templates {
	prefixes := make([dynamic]string, allocator)
	module_prefixes := make([dynamic]string, allocator)
	for template in templates {
		if template.text_line || template.prefix == "" {
			continue
		}
		if !slice.contains(prefixes[:], template.prefix) {
			append(&prefixes, template.prefix)
		}
		for module_name in template.modules {
			pair := strings.concatenate({module_name, " ", template.prefix}, allocator)
			if !slice.contains(module_prefixes[:], pair) {
				append(&module_prefixes, pair)
			}
		}
	}
	slice.sort(prefixes[:])
	slice.sort(module_prefixes[:])
	return {templates = templates, prefixes = prefixes[:], module_prefixes = module_prefixes[:]}
}

// fact_wait_body gives the words of the text of a step that a fact
// sentence must hold: the text after the head of a process, "[log_reader]
// ", and before the first mark of the scenario, "{record}", whose value
// the scenario learns at its run.
fact_wait_body :: proc(text: string) -> string {
	body := text
	if process, has_head := fact_wait_head(text); has_head {
		body = body[len(process) + 3:]
	}
	if mark := strings.index_byte(body, '{'); mark >= 0 {
		body = body[:mark]
	}
	return body
}

// fact_wait_head gives the name in the head of a process of a text,
// "[log_reader child 1] ...", as the serial line writes it before each line.
fact_wait_head :: proc(text: string) -> (process: string, ok: bool) {
	if !strings.has_prefix(text, "[") {
		return "", false
	}
	end := strings.index(text, "] ")
	if end <= 1 || strings.index_byte(text[1:end], '[') >= 0 {
		return "", false
	}
	return text[1:end], true
}

// fact_wait_verdict says whether the text of a step is a fact wait, and
// whether some template can render it. For a finding, nearest is the
// template of the prefix that renders the longest start of the text, and
// matched the count of the bytes of the body that it renders.
fact_wait_verdict :: proc(known: ^Fact_Wait_Templates, text: string) -> (verdict: Fact_Wait_Verdict, nearest: Fact_Wait_Template, matched: int) {
	body := fact_wait_body(text)
	prefix, has_prefix := fact_prefix_of(body)
	if !has_prefix {
		return .Not_A_Fact_Wait, {}, 0
	}
	if _, found := slice.binary_search(known.prefixes, prefix); !found {
		return .Not_A_Fact_Wait, {}, 0
	}
	if process, has_head := fact_wait_head(text); has_head {
		// The head names the process that wrote the line; its module is
		// the first word of the head ("[log_reader child 1]").
		module_name := process
		if space := strings.index_byte(process, ' '); space > 0 {
			module_name = process[:space]
		}
		if _, found := slice.binary_search(known.module_prefixes, strings.concatenate({module_name, " ", prefix}, context.temp_allocator)); !found {
			return .Not_A_Fact_Wait, {}, 0
		}
	}
	matched = -1
	for template in known.templates {
		// A quick refusal: a template that does not hold the prefix
		// cannot hold it in its literals.
		if !strings.contains(template.template, prefix) {
			continue
		}
		reached, whole := fact_wait_template_match(template.items, body, prefix)
		if whole {
			return .Matches, template, len(body)
		}
		if template.prefix == prefix && reached > matched {
			nearest, matched = template, reached
		}
	}
	return .Matches_None, nearest, max(matched, 0)
}

// fact_wait_template_match says whether the template renders a sentence
// that holds body from some place where the prefix of the body stands in
// the literals of the template: its fact prefix, or the same words later,
// as "display: monitor: the surface" in a sentence of `display`. reached
// is the most bytes of the body that one such place renders.
fact_wait_template_match :: proc(items: []Fact_Wait_Item, body: string, prefix: string) -> (reached: int, whole: bool) {
	for start in 0 ..= len(items) - len(prefix) {
		literal := true
		for index in 0 ..< len(prefix) {
			if items[start + index].kind != .Literal || items[start + index].literal != prefix[index] {
				literal = false
				break
			}
		}
		if !literal {
			continue
		}
		count := fact_wait_items_render(items[start:], body)
		if count == len(body) {
			return count, true
		}
		reached = max(reached, count)
	}
	return reached, false
}

// fact_wait_items_render gives how many bytes of the start of a text some
// sentence of the items holds: the text, whole, when the items render a
// sentence that starts with it. The end of the text can be inside a field
// or before the end of the items. The match is a walk of the set of the
// places in the items, one byte at a time, so a field that is a wildcard
// never makes it try each split.
fact_wait_items_render :: proc(items: []Fact_Wait_Item, text: string) -> int {
	places := make([]bool, len(items) + 1, context.temp_allocator)
	next := make([]bool, len(items) + 1, context.temp_allocator)
	// A place before a field that can be empty is also the place after it.
	close :: proc(items: []Fact_Wait_Item, places: []bool) {
		for index in 0 ..< len(items) {
			if places[index] && (items[index].kind == .Any || items[index].kind == .Word_More) {
				places[index + 1] = true
			}
		}
	}
	places[0] = true
	close(items, places)
	for character, count in transmute([]u8)text {
		slice.fill(next, false)
		any := false
		for index in 0 ..< len(items) {
			if !places[index] {
				continue
			}
			item := items[index]
			switch item.kind {
			case .Literal:
				if item.literal == character {
					next[index + 1] = true
					any = true
				}
			case .Any:
				next[index] = true
				any = true
			case .Word_One:
				if character != ' ' {
					next[index + 1] = true
					any = true
				}
			case .Word_More:
				if character != ' ' {
					next[index] = true
					any = true
				}
			}
		}
		if !any {
			return count
		}
		places, next = next, places
		close(items, places)
	}
	return len(text)
}

// fact_wait_field_of gives the class and the unit of a field of the
// description of a fact type, as the sentence writes its value.
fact_wait_field_of :: proc(file: []u8, item: module.Field) -> Fact_Wait_Field {
	field := Fact_Wait_Field {
		name  = module.string_at(file, item.name_offset, item.name_count),
		class = .Word,
	}
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		field.class = .Any
		return field
	}
	switch kind {
	case .Text_View, .Module_Name, .Log_Body, .Status, .Fact_Values:
		// A status writes the words of its member, and the values of a
		// fact or a log body write nothing when their bytes are zero.
		field.class = .Any
		return field
	case .Nanoseconds_As_Microseconds:
		field.unit = " us"
		return field
	case .Plain, .Hexadecimal, .Hash, .Hash_Head, .Hexadecimal_Sixteen_Digits, .Hundredths, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day:
	}
	if type == .Text {
		field.class = .Any
	} else if type == .Integer && kind == .Plain && value_kinds.integer_unit_valid(item.integer_unit) {
		field.unit = value_kinds.integer_unit_text(item.integer_unit)
	}
	return field
}

// fact_wait_templates_of_catalog gives the template of each fact type of
// each module file of a catalog, in the temporary memory: the fact types
// that a module reaches, since a module file holds no other. The forms of
// the text lines join them, each field Any.
fact_wait_templates_of_catalog :: proc(catalog: ^Fact_Catalog, text_lines: []string) -> Fact_Wait_Templates {
	templates := make([dynamic]Fact_Wait_Template, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	fact_places := make(map[string]int, context.temp_allocator)
	for line in text_lines {
		if seen[line] {
			continue
		}
		seen[line] = true
		template := fact_wait_template_make(line, nil, "a text line", context.temp_allocator)
		template.text_line = true
		append(&templates, template)
	}
	for index in 0 ..< len(catalog.modules) {
		path := catalog.modules[index].path
		file := fact_catalog_file(catalog, module_tag_of(catalog.modules[index].hash))
		if file == nil || module.count(file, .Facts) <= 1 {
			continue
		}
		module_name := path[strings.last_index_byte(path, '/') + 1:]
		if dot := strings.index_byte(module_name, '.'); dot > 0 {
			module_name = module_name[:dot]
		}
		for row_index in 1 ..< module.count(file, .Facts) {
			row, description, row_ok := module.fact(file, row_index)
			if !row_ok {
				continue
			}
			template := module.string_at(file, row.template_offset, row.template_count)
			fields := make([dynamic]Fact_Wait_Field, context.temp_allocator)
			for number in 0 ..< description.field_count {
				item, item_ok := module.field(file, description, number)
				if item_ok {
					append(&fields, fact_wait_field_of(file, item))
				}
			}
			// A support package puts one fact type in many modules: one
			// template of one form, with the name of each module.
			key := fmt.tprintf("%s\x00%v", template, fields[:])
			if place, seen_before := fact_places[key]; seen_before {
				append(&templates[place].modules, strings.clone(module_name, context.temp_allocator))
				continue
			}
			fact_places[key] = len(templates)
			append(&templates, fact_wait_template_make(template, fields[:], module_name, context.temp_allocator))
		}
	}
	return fact_wait_templates_make(templates[:], context.temp_allocator)
}
