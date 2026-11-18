// The pointers of a text to a document: a path of docs/ or of the intent
// folder, then the heading in quotes (docs/SITE.md, "The references to
// documents"). The rule on comments, the check of the intent folder and the
// site each read them.
package checks

import "core:strings"
import "modustool:foundation"

// The words that start a label of a place in a document: "section 8",
// "sections 4 and 5", "property <n>". The last one names a numbered item
// of a list, not a heading (site_item_find).
SITE_POINTER_LABEL_WORDS :: [?]string{"sections ", "section ", "property ", "item "}

// A pointer of a text to a document of docs/.
Site_Document_Pointer :: struct {
	start:    int, // The first byte of what the pointer takes from the text.
	end:      int, // The byte after it.
	path:     string, // "docs/ARCHITECTURE.md".
	labels:   []string, // Each part after the path that names a place, in its order: "\"Kernel systems\"", "section 8", "U3".
	// An aside (a parenthesis, or "see ..."): its text leaves the sentence
	// and its reference goes after the text. Else the path is a word of the
	// sentence ("the rules of docs/DESIGN.md"), and its reference takes its
	// place.
	detached: bool,
}

// site_document_path_end tells whether a path "docs/<NAME>.md", or a file
// of the glossary "docs/glossary/<name>.md", starts at an index of a text,
// and gives the byte after it. A part of a longer path ("tools/docs/X.md")
// or of a word is not a pointer.
site_document_path_end :: proc(text: string, start: int) -> (end: int, found: bool) {
	if start >= 0 && start < len(text) && strings.has_prefix(text[start:], INTENT_PREFIX) {
		return site_intent_path_end(text, start)
	}
	if start < 0 || start >= len(text) || !strings.has_prefix(text[start:], "docs/") {
		return 0, false
	}
	if start > 0 {
		before := text[start - 1]
		if foundation.site_is_word_byte(before) || before == '/' || before == '.' || before == '-' {
			return 0, false
		}
	}
	end = start + len("docs/")
	// The files of the glossary have names in lower case, as the other
	// files of the repository, and its index is README.md.
	in_glossary := strings.has_prefix(text[end:], "glossary/")
	if in_glossary {
		end += len("glossary/")
	}
	name_start := end
	for end < len(text) && ((text[end] >= 'A' && text[end] <= 'Z') || (in_glossary && text[end] >= 'a' && text[end] <= 'z') || (text[end] >= '0' && text[end] <= '9') || text[end] == '_') {
		end += 1
	}
	if end == name_start || !strings.has_prefix(text[end:], ".md") {
		return 0, false
	}
	end += len(".md")
	if end < len(text) && (foundation.site_is_word_byte(text[end]) || text[end] == '/') {
		return 0, false
	}
	return end, true
}

// site_intent_path_end tells whether the path of an intent file
// ("src/md/features/palette.md", "src/md/README.md") starts at an index of
// a text, and gives the byte after it. The folders and the file have
// letters, digits and "_" in their names. A part of a longer path or of a
// word is not a pointer.
site_intent_path_end :: proc(text: string, start: int) -> (end: int, found: bool) {
	if start > 0 {
		before := text[start - 1]
		if foundation.site_is_word_byte(before) || before == '/' || before == '.' || before == '-' {
			return 0, false
		}
	}
	end = start + len(INTENT_PREFIX)
	name_start := end
	for end < len(text) {
		character := text[end]
		is_name_byte := (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_'
		// A "/" goes on to the next folder only when a name follows it.
		if !is_name_byte && !(character == '/' && end > name_start && text[end - 1] != '/') {
			break
		}
		end += 1
	}
	if end == name_start || text[end - 1] == '/' || !strings.has_prefix(text[end:], ".md") {
		return 0, false
	}
	end += len(".md")
	if end < len(text) && (foundation.site_is_word_byte(text[end]) || text[end] == '/') {
		return 0, false
	}
	return end, true
}

// site_document_path_start gives the first place at or after an index
// where the path of a document can start: "docs/", or the folder of the
// intent files. It gives the length of the prefix found, and -1 when the
// text has none.
site_document_path_start :: proc(text: string, position: int) -> (start: int, prefix_length: int) {
	start = -1
	if found := strings.index(text[position:], "docs/"); found >= 0 {
		start, prefix_length = position + found, len("docs/")
	}
	if found := strings.index(text[position:], INTENT_PREFIX); found >= 0 && (start < 0 || position + found < start) {
		start, prefix_length = position + found, len(INTENT_PREFIX)
	}
	return start, prefix_length
}

// site_enclosing_parenthesis gives the parenthesis around an index of a
// text: its "(" and its ")", or the end of the text when the text stops
// before the ")". The open is -1 when no parenthesis holds the index.
site_enclosing_parenthesis :: proc(text: string, at: int) -> (open: int, close: int) {
	open = -1
	depth := 0
	for index := at - 1; index >= 0 && open < 0; index -= 1 {
		if text[index] == ')' {
			depth += 1
		} else if text[index] == '(' {
			if depth == 0 {
				open = index
			} else {
				depth -= 1
			}
		}
	}
	if open < 0 {
		return -1, -1
	}
	close = len(text)
	depth = 0
	for index in at ..< len(text) {
		if text[index] == '(' {
			depth += 1
		} else if text[index] == ')' {
			if depth == 0 {
				close = index
				break
			}
			depth -= 1
		}
	}
	return open, close
}

// site_parenthesis_part gives the bounds of the part of a parenthesis that
// holds the bytes from at to after. The parts are separated by "; ", outside
// quotes and inner parentheses: "(the call form; docs/MODULE_CONTRACT.md)".
site_parenthesis_part :: proc(text: string, open, close, at, after: int) -> (start: int, end: int) {
	start, end = open + 1, close
	quoted := false
	depth := 0
	for index in open + 1 ..< close {
		character := text[index]
		if character == '"' {
			quoted = !quoted
		} else if !quoted && character == '(' {
			depth += 1
		} else if !quoted && character == ')' {
			depth -= 1
		} else if !quoted && depth == 0 && character == ';' && index + 1 < close && text[index + 1] == ' ' {
			if index < at {
				start = index + 2
			} else if index >= after {
				end = index
				break
			}
		}
	}
	return start, end
}

// site_parts_outside_quotes splits a text at each ", " that is not inside
// quotes: a quoted heading can hold a comma ("Did not fit, across calls").
site_parts_outside_quotes :: proc(text: string) -> []string {
	parts := make([dynamic]string, context.temp_allocator)
	quoted := false
	start := 0
	for index in 0 ..< len(text) {
		if text[index] == '"' {
			quoted = !quoted
		} else if !quoted && text[index] == ',' && index + 1 < len(text) && text[index + 1] == ' ' {
			append(&parts, strings.trim_space(text[start:index]))
			start = index + 2
		}
	}
	append(&parts, strings.trim_space(text[start:]))
	return parts[:]
}

// site_label_token_end reads a label of a section at an index: "8", "12.4",
// "5a", "U2b", "K1". With capital_required, the label starts with a capital
// letter: a bare number after a comma is a word of the sentence.
site_label_token_end :: proc(text: string, at: int, capital_required: bool) -> (end: int, found: bool) {
	decimal_digit :: proc(character: u8) -> bool {
		return character >= '0' && character <= '9'
	}
	index := at
	if index < len(text) && text[index] >= 'A' && text[index] <= 'Z' {
		index += 1
	} else if capital_required {
		return 0, false
	}
	digits_start := index
	for index < len(text) && decimal_digit(text[index]) {
		index += 1
	}
	if index == digits_start {
		return 0, false
	}
	if index < len(text) && text[index] >= 'a' && text[index] <= 'z' {
		index += 1
	}
	for index + 1 < len(text) && text[index] == '.' && decimal_digit(text[index + 1]) {
		index += 1
		for index < len(text) && decimal_digit(text[index]) {
			index += 1
		}
		if index < len(text) && text[index] >= 'a' && text[index] <= 'z' {
			index += 1
		}
	}
	if index < len(text) && foundation.site_is_word_byte(text[index]) {
		return 0, false
	}
	return index, true
}

// site_pointer_label_end reads one label of a place at an index: a heading
// in quotes, a word of SITE_POINTER_LABEL_WORDS and its number or its
// quoted heading, or a label that starts with a capital letter ("U3").
site_pointer_label_end :: proc(text: string, at: int) -> (end: int, found: bool) {
	if at >= len(text) {
		return 0, false
	}
	if text[at] == '"' {
		closing := strings.index_byte(text[at + 1:], '"')
		if closing <= 0 {
			return 0, false
		}
		return at + 1 + closing + 1, true
	}
	words := SITE_POINTER_LABEL_WORDS
	for word in words {
		if !strings.has_prefix(text[at:], word) {
			continue
		}
		after := at + len(word)
		if after < len(text) && text[after] == '"' {
			return site_pointer_label_end(text, after)
		}
		end, found = site_label_token_end(text, after, false)
		if found && word == "sections " && strings.has_prefix(text[end:], " and ") {
			if second, has_second := site_label_token_end(text, end + len(" and "), false); has_second {
				end = second
			}
		}
		return end, found
	}
	return site_label_token_end(text, at, true)
}

// site_pointer_labels reads the labels after a path in running text, each
// after ", ": `docs/FONTS.md, section 12.4` or `ARCHITECTURE.md`, "The fault
// ring". It stops at the first part that is not a label, and gives the
// byte after the last label.
site_pointer_labels :: proc(text: string, at: int) -> (labels: []string, end: int) {
	list := make([dynamic]string, context.temp_allocator)
	end = at
	for end < len(text) {
		separator := 0
		if strings.has_prefix(text[end:], ", ") {
			separator = 2
		} else if strings.has_prefix(text[end:], " section ") || strings.has_prefix(text[end:], " sections ") {
			separator = 1
		} else {
			break
		}
		label_end, found := site_pointer_label_end(text, end + separator)
		if !found {
			break
		}
		append(&list, text[end + separator:label_end])
		end = label_end
	}
	return list[:], end
}

// site_document_pointer_at reads the pointer whose path is at path_start:
// its labels, the bytes that it takes from the text, and whether it is an
// aside.
site_document_pointer_at :: proc(text: string, path_start, path_end: int) -> Site_Document_Pointer {
	pointer := Site_Document_Pointer{start = path_start, end = path_end, path = text[path_start:path_end]}
	if open, close := site_enclosing_parenthesis(text, path_start); open >= 0 {
		part_start, part_end := site_parenthesis_part(text, open, close, path_start, path_end)
		before := text[part_start:path_start]
		after := text[path_end:part_end]
		labels_text := ""
		labelled := true
		if strings.has_prefix(after, ", ") {
			labels_text = after[2:]
		} else if strings.has_prefix(after, " section") {
			labels_text = after[1:]
		} else if strings.trim_space(after) != "" {
			labelled = false // Words after the path: the path is a word of the parenthesis.
		}
		// The bytes of the part that stay before the pointer, or -1 when
		// the path is a word of the parenthesis.
		kept := -1
		if before == "" || before == "see " || before == "See " {
			kept = 0
		} else if strings.has_suffix(before, ", see ") || strings.has_suffix(before, ", See ") {
			kept = len(before) - len(", see ")
		} else if strings.has_suffix(before, ", ") {
			kept = len(before) - len(", ")
		}
		if labelled && kept >= 0 {
			aside_labels := make([dynamic]string, context.temp_allocator)
			if labels_text != "" {
				for part in site_parts_outside_quotes(labels_text) {
					if part != "" {
						append(&aside_labels, part)
					}
				}
			}
			pointer.labels = aside_labels[:]
			pointer.detached = true
			pointer.start = part_start + kept
			pointer.end = part_end
			if kept == 0 {
				if part_start == open + 1 && part_end == close {
					// The whole parenthesis, and the space before it.
					pointer.start = open
					if open > 0 && text[open - 1] == ' ' {
						pointer.start = open - 1
					}
					pointer.end = min(close + 1, len(text))
				} else if part_start > open + 1 {
					pointer.start = part_start - len("; ")
				} else {
					pointer.end = part_end + len("; ")
				}
			}
			return pointer
		}
	}
	if path_start >= 4 {
		see := text[path_start - 4:path_start]
		if see == "see " || see == "See " {
			see_labels, see_end := site_pointer_labels(text, path_end)
			pointer.labels = see_labels
			pointer.detached = true
			pointer.start = path_start - 4
			pointer.end = see_end
			if pointer.start >= 2 && (text[pointer.start - 2:pointer.start] == ", " || text[pointer.start - 2:pointer.start] == "; ") {
				pointer.start -= 2
			} else if see == "See " && see_end < len(text) && text[see_end] == '.' {
				pointer.end = see_end + 1 // "See docs/X.md." is a whole sentence.
			}
			return pointer
		}
	}
	// A path in code marks ("`docs/X.md`") takes its marks with it.
	labels_start := path_end
	if path_start > 0 && text[path_start - 1] == '`' && path_end < len(text) && text[path_end] == '`' {
		pointer.start = path_start - 1
		labels_start = path_end + 1
	}
	word_labels, word_end := site_pointer_labels(text, labels_start)
	pointer.labels = word_labels
	pointer.end = word_end
	return pointer
}

// site_document_pointers gives each pointer of a text to a document of
// docs/, in the order of the text. A text with no pointer gives none.
site_document_pointers :: proc(text: string) -> []Site_Document_Pointer {
	pointers := make([dynamic]Site_Document_Pointer, context.temp_allocator)
	position := 0
	for position < len(text) {
		path_start, prefix_length := site_document_path_start(text, position)
		if path_start < 0 {
			break
		}
		path_end, is_path := site_document_path_end(text, path_start)
		// The target of a link "[text](docs/X.md#id)" is not a pointer: the
		// link names its place (site_comment_link_target).
		if path_start >= 2 && text[path_start - 2:path_start] == "](" {
			is_path = false
		}
		if !is_path {
			position = path_start + prefix_length
			continue
		}
		pointer := site_document_pointer_at(text, path_start, path_end)
		append(&pointers, pointer)
		position = max(path_end, pointer.end)
	}
	return pointers[:]
}
