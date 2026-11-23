package checks

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The check of the display texts of the modules (docs/WRITING.md).
//
// Each display text of a module — a member display text (@(member_texts)),
// a setting title, explanation or value label (Setting_Text and *_EXPLANATION),
// a window problem sentence (window_problem_texts), a button or action bar
// label, and a context menu item label — must obey the guide:
//
// - no forbidden word ("invalid", "illegal", "fatal", "catastrophic",
//   "please", "sorry", "abort", "kill", "terminate", "unable to");
// - no contraction ("can't", "don't", "isn't", "it's", "you're", ...);
// - no "Error" or "Failure" as a title or prefix;
// - no "failed" with nothing after it;
// - sentence case (capital at the start except "modus", no Title Case of
//   common function words, no ALL CAPS multi-word phrases);
// - a label has no end period, and a sentence ends with a period or '?'.

DISPLAY_TEXT_CHECKED_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_MODULES}

// The grammatical role of a display text.
Display_Text_Kind :: enum u8 {
	Label,    // A button, action bar item, menu item, setting title, value label, or member display text: no end period.
	Sentence, // A setting explanation or window problem sentence: ends with '.' or '?'.
}

// Why a display text is refused by docs/WRITING.md.
Display_Text_Problem :: enum u8 {
	None,
	Forbidden_Word,    // Uses a word or phrase refused by docs/WRITING.md, "2. Words that a text does not use".
	Contraction,       // Uses an English contraction.
	Error_Title,       // Uses "Error" or "Failure" as a title or message prefix.
	Failed_Alone,      // Uses "failed" with no cause after it.
	Not_Sentence_Case, // Starts with a lowercase letter (other than "modus"), uses Title Case, or is ALL CAPS.
	Wrong_End_Period,  // A Label ends with '.', or a Sentence lacks '.' or '?' at its end.
}

// One display text that broke a rule of docs/WRITING.md.
Display_Text_Fault :: struct {
	file:    string,
	line:    int,
	kind:    Display_Text_Kind,
	problem: Display_Text_Problem,
	text:    string,
	detail:  string, // The offending word or reason.
}

@(private = "file")
FORBIDDEN_WORDS :: [?]string {
	"invalid",
	"illegal",
	"fatal",
	"catastrophic",
	"please",
	"sorry",
	"abort",
	"kill",
	"terminate",
}

@(private = "file")
CONTRACTION_WORDS :: [?]string {
	"it's",
	"that's",
	"there's",
	"here's",
	"what's",
	"who's",
	"let's",
}

@(private = "file")
CONTRACTION_SUFFIXES :: [?]string {
	"n't",
	"'re",
	"'ve",
	"'ll",
	"'m",
	"'d",
}

// Common English function words that stay lowercase inside a sentence or
// label in sentence case (not at the start and not after '.', '?', '!').
@(private = "file")
TITLE_CASE_FUNCTION_WORDS :: [?]string {
	"A",
	"An",
	"All",
	"And",
	"At",
	"By",
	"For",
	"From",
	"In",
	"Into",
	"Is",
	"Of",
	"Off",
	"On",
	"Or",
	"The",
	"This",
	"That",
	"To",
	"With",
	"Your",
}

@(private = "file")
display_is_ascii_letter :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(private = "file")
display_is_lower :: proc(b: u8) -> bool {
	return b >= 'a' && b <= 'z'
}

@(private = "file")
display_is_upper :: proc(b: u8) -> bool {
	return b >= 'A' && b <= 'Z'
}

@(private = "file")
display_is_word_byte :: proc(b: u8) -> bool {
	return display_is_ascii_letter(b) || b == '\''
}

// display_has_whole_phrase reports whether lower contains phrase bounded
// on both sides by non-letter bytes.
@(private = "file")
display_has_whole_phrase :: proc(lower, phrase: string) -> bool {
	search := 0
	for search < len(lower) {
		found := strings.index(lower[search:], phrase)
		if found < 0 {
			return false
		}
		start := search + found
		end := start + len(phrase)
		search = end
		before_letter := start > 0 && display_is_ascii_letter(lower[start - 1])
		after_letter := end < len(lower) && display_is_ascii_letter(lower[end])
		if !before_letter && !after_letter {
			return true
		}
	}
	return false
}

// display_find_contraction gives the first contraction in lower, or "".
@(private = "file")
display_find_contraction :: proc(lower: string) -> string {
	index := 0
	for index < len(lower) {
		for index < len(lower) && !display_is_word_byte(lower[index]) {
			index += 1
		}
		start := index
		for index < len(lower) && display_is_word_byte(lower[index]) {
			index += 1
		}
		word := lower[start:index]
		if strings.index_byte(word, '\'') < 0 {
			continue
		}
		exact := CONTRACTION_WORDS
		for candidate in exact {
			if word == candidate {
				return word
			}
		}
		suffixes := CONTRACTION_SUFFIXES
		for suffix in suffixes {
			if len(word) > len(suffix) && strings.has_suffix(word, suffix) {
				return word
			}
		}
	}
	return ""
}

// display_has_failed_alone reports whether lower contains the whole word
// "failed" with no ASCII letter after it.
@(private = "file")
display_has_failed_alone :: proc(lower: string) -> bool {
	word :: "failed"
	search := 0
	for search < len(lower) {
		found := strings.index(lower[search:], word)
		if found < 0 {
			return false
		}
		start := search + found
		end := start + len(word)
		search = end
		if start > 0 && display_is_ascii_letter(lower[start - 1]) {
			continue
		}
		if end < len(lower) && display_is_ascii_letter(lower[end]) {
			continue
		}
		has_letter_after := false
		for rest in end ..< len(lower) {
			if display_is_ascii_letter(lower[rest]) {
				has_letter_after = true
				break
			}
		}
		if !has_letter_after {
			return true
		}
	}
	return false
}

// display_sentence_case_problem checks sentence case of a trimmed text:
// lowercase start (except "modus"), ALL CAPS multi-word phrase, or a
// capitalized common function word inside a sentence or label.
@(private = "file")
display_sentence_case_problem :: proc(trimmed: string) -> string {
	if len(trimmed) == 0 {
		return ""
	}
	// First byte: a lowercase letter is refused except for the system name "modus".
	if display_is_lower(trimmed[0]) {
		end := 0
		for end < len(trimmed) && display_is_ascii_letter(trimmed[end]) {
			end += 1
		}
		if trimmed[:end] != "modus" {
			return "starts with a lowercase letter"
		}
	}
	// Walk words to detect ALL CAPS multi-word phrases (outside parentheses, so
	// acronym pairs such as "US (QWERTY)" pass) and mid-sentence Title Case.
	alpha_words := 0
	all_caps_words := 0
	paren_depth := 0
	word_index := 0
	after_sentence_end := true
	index := 0
	for index < len(trimmed) {
		for index < len(trimmed) && !display_is_ascii_letter(trimmed[index]) {
			ch := trimmed[index]
			if ch == '.' || ch == '?' || ch == '!' {
				after_sentence_end = true
			} else if ch == '(' {
				paren_depth += 1
			} else if ch == ')' && paren_depth > 0 {
				paren_depth -= 1
			}
			index += 1
		}
		if index >= len(trimmed) {
			break
		}
		start := index
		for index < len(trimmed) && display_is_ascii_letter(trimmed[index]) {
			index += 1
		}
		word := trimmed[start:index]
		if paren_depth == 0 {
			alpha_words += 1
			word_all_upper := true
			for pos in 0 ..< len(word) {
				if !display_is_upper(word[pos]) {
					word_all_upper = false
					break
				}
			}
			if word_all_upper {
				all_caps_words += 1
			}
		}
		if word_index > 0 && !after_sentence_end {
			function_words := TITLE_CASE_FUNCTION_WORDS
			for candidate in function_words {
				if word == candidate {
					return "title case word"
				}
			}
		}
		after_sentence_end = false
		word_index += 1
	}
	if alpha_words >= 2 && all_caps_words == alpha_words {
		return "all capital letters"
	}
	return ""
}

// display_text_check_one checks one text against docs/WRITING.md for its
// kind. Empty texts are skipped (an unused slot in a fixed array).
display_text_check_one :: proc(text: string, kind: Display_Text_Kind, english := true) -> (problem: Display_Text_Problem, detail: string) {
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 {
		return .None, ""
	}
	lower := strings.to_lower(trimmed, context.temp_allocator)
	if english {
		words := FORBIDDEN_WORDS
		for word in words {
			if display_has_whole_phrase(lower, word) {
				return .Forbidden_Word, word
			}
		}
		if display_has_whole_phrase(lower, "unable to") {
			return .Forbidden_Word, "unable to"
		}
		if contraction := display_find_contraction(lower); contraction != "" {
			return .Contraction, contraction
		}
		switch kind {
		case .Label:
			if lower == "error" || lower == "failure" || strings.has_prefix(lower, "error:") || strings.has_prefix(lower, "failure:") {
				return .Error_Title, trimmed
			}
		case .Sentence:
			if strings.has_prefix(lower, "error:") || strings.has_prefix(lower, "failure:") {
				return .Error_Title, trimmed
			}
		}
		if display_has_failed_alone(lower) {
			return .Failed_Alone, "failed"
		}
	}
	if case_reason := display_sentence_case_problem(trimmed); case_reason != "" {
		return .Not_Sentence_Case, case_reason
	}
	switch kind {
	case .Label:
		if strings.has_suffix(trimmed, ".") {
			return .Wrong_End_Period, "a label has no end period"
		}
	case .Sentence:
		last := trimmed[len(trimmed) - 1]
		if last != '.' && last != '?' {
			return .Wrong_End_Period, "a sentence ends with a period"
		}
	}
	return .None, ""
}

@(private = "file")
display_string_literal :: proc(expr: ^ast.Expr) -> (value: string, line: int, ok: bool) {
	if expr == nil {
		return "", 0, false
	}
	#partial switch item in expr.derived {
	case ^ast.Paren_Expr:
		return display_string_literal(item.expr)
	case ^ast.Basic_Lit:
		if item.tok.kind != .String || len(item.tok.text) < 2 {
			return "", 0, false
		}
		raw := item.tok.text
		if raw[0] == '`' {
			return raw[1:len(raw) - 1], item.pos.line, true
		}
		inner := raw[1:len(raw) - 1]
		if strings.index_byte(inner, '\\') < 0 {
			return inner, item.pos.line, true
		}
		b := strings.builder_make(context.temp_allocator)
		for idx := 0; idx < len(inner); idx += 1 {
			if inner[idx] == '\\' && idx + 1 < len(inner) {
				idx += 1
				switch inner[idx] {
				case 'n':
					strings.write_byte(&b, '\n')
				case 't':
					strings.write_byte(&b, '\t')
				case 'r':
					strings.write_byte(&b, '\r')
				case '"', '\\', '\'':
					strings.write_byte(&b, inner[idx])
				case:
					strings.write_byte(&b, inner[idx])
				}
			} else {
				strings.write_byte(&b, inner[idx])
			}
		}
		return strings.to_string(b), item.pos.line, true
	}
	return "", 0, false
}

@(private = "file")
Display_Text_Walk :: struct {
	file:       string,
	faults:     ^[dynamic]Display_Text_Fault,
	text_count: int,
}

@(private = "file")
display_record_check :: proc(walk: ^Display_Text_Walk, text: string, line: int, kind: Display_Text_Kind, english := true) {
	if strings.trim_space(text) == "" {
		return
	}
	walk.text_count += 1
	if problem, detail := display_text_check_one(text, kind, english); problem != .None {
		append(walk.faults, Display_Text_Fault{
			file    = walk.file,
			line    = line,
			kind    = kind,
			problem = problem,
			text    = strings.clone(text, context.temp_allocator),
			detail  = strings.clone(detail, context.temp_allocator),
		})
	}
}

@(private = "file")
display_check_expr :: proc(walk: ^Display_Text_Walk, expr: ^ast.Expr, kind: Display_Text_Kind, english := true) {
	if expr == nil {
		return
	}
	#partial switch item in expr.derived {
	case ^ast.Paren_Expr:
		display_check_expr(walk, item.expr, kind, english)
	case ^ast.Ternary_If_Expr:
		display_check_expr(walk, item.x, kind, english)
		display_check_expr(walk, item.y, kind, english)
	case ^ast.Ternary_When_Expr:
		display_check_expr(walk, item.x, kind, english)
		display_check_expr(walk, item.y, kind, english)
	case ^ast.Basic_Lit:
		if value, line, ok := display_string_literal(expr); ok {
			display_record_check(walk, value, line, kind, english)
		}
	}
}

@(private = "file")
display_check_setting_text_literal :: proc(walk: ^Display_Text_Walk, lit: ^ast.Comp_Lit) {
	for elem, index in lit.elems {
		if pair, is_pair := elem.derived.(^ast.Field_Value); is_pair {
			field, is_ident := pair.field.derived.(^ast.Ident)
			if !is_ident {
				continue
			}
			switch field.name {
			case "title":
				display_check_expr(walk, pair.value, .Label)
			case "explanation":
				display_check_expr(walk, pair.value, .Sentence)
			case "value_labels":
				if values, is_comp := pair.value.derived.(^ast.Comp_Lit); is_comp {
					for item in values.elems {
						display_check_expr(walk, item, .Label)
					}
				}
			}
			continue
		}
		switch index {
		case 0:
			display_check_expr(walk, elem, .Label)
		case 1:
			display_check_expr(walk, elem, .Sentence)
		case 2:
			if values, is_comp := elem.derived.(^ast.Comp_Lit); is_comp {
				for item in values.elems {
					display_check_expr(walk, item, .Label)
				}
			}
		}
	}
}

@(private = "file")
display_type_name :: proc(expr: ^ast.Expr) -> string {
	if expr == nil {
		return ""
	}
	#partial switch item in expr.derived {
	case ^ast.Ident:
		return item.name
	case ^ast.Selector_Expr:
		if item.field != nil {
			return item.field.name
		}
	}
	return ""
}

@(private = "file")
display_is_english_tag :: proc(tag: string) -> bool {
	lower := strings.to_lower(tag, context.temp_allocator)
	return lower == "en" || strings.has_prefix(lower, "en-")
}

@(private = "file")
display_check_value_decl :: proc(walk: ^Display_Text_Walk, decl: ^ast.Value_Decl) {
	if len(decl.names) != 1 || len(decl.values) != 1 {
		return
	}
	ident, has_name := decl.names[0].derived.(^ast.Ident)
	if !has_name {
		return
	}
	// 1. @(member_texts = "<tag>") tables.
	for attribute in decl.attributes {
		for element in attribute.elems {
			pair, is_pair := element.derived.(^ast.Field_Value)
			if !is_pair {
				continue
			}
			field, is_field := pair.field.derived.(^ast.Ident)
			if !is_field || field.name != foundation.MEMBER_TEXTS_ATTRIBUTE_NAME {
				continue
			}
			tag, _, tag_ok := display_string_literal(pair.value)
			if !tag_ok {
				continue
			}
			english := display_is_english_tag(tag)
			if comp, is_comp := decl.values[0].derived.(^ast.Comp_Lit); is_comp {
				for elem in comp.elems {
					if row, is_row := elem.derived.(^ast.Field_Value); is_row {
						display_check_expr(walk, row.value, .Label, english)
					} else {
						display_check_expr(walk, elem, .Label, english)
					}
				}
			}
			return
		}
	}
	// 2. *_EXPLANATION string constants.
	if strings.has_suffix(ident.name, "_EXPLANATION") {
		display_check_expr(walk, decl.values[0], .Sentence)
		return
	}
	// 3. window_problem_texts tables.
	if ident.name == "window_problem_texts" {
		if comp, is_comp := decl.values[0].derived.(^ast.Comp_Lit); is_comp {
			for elem in comp.elems {
				if row, is_row := elem.derived.(^ast.Field_Value); is_row {
					display_check_expr(walk, row.value, .Sentence)
				} else {
					display_check_expr(walk, elem, .Sentence)
				}
			}
		}
		return
	}
	// 4. Tables of Setting_Text records (e.g. setting_texts := [settings.Setting]Setting_Text{...}).
	if comp, is_comp := decl.values[0].derived.(^ast.Comp_Lit); is_comp {
		type_expr := decl.type != nil ? decl.type : comp.type
		if type_expr != nil {
			if arr, is_arr := type_expr.derived.(^ast.Array_Type); is_arr && display_type_name(arr.elem) == "Setting_Text" {
				for elem in comp.elems {
					item_expr := elem
					if row, is_row := elem.derived.(^ast.Field_Value); is_row {
						item_expr = row.value
					}
					if setting_lit, is_lit := item_expr.derived.(^ast.Comp_Lit); is_lit && setting_lit.type == nil {
						display_check_setting_text_literal(walk, setting_lit)
					}
				}
				return
			}
		}
	}
}

@(private = "file")
display_call_name :: proc(expr: ^ast.Expr) -> string {
	if expr == nil {
		return ""
	}
	#partial switch item in expr.derived {
	case ^ast.Ident:
		return item.name
	case ^ast.Selector_Expr:
		if item.field != nil {
			return item.field.name
		}
	}
	return ""
}

@(private = "file")
display_arg_at :: proc(args: []^ast.Expr, position: int, name: string) -> ^ast.Expr {
	for arg in args {
		if pair, is_pair := arg.derived.(^ast.Field_Value); is_pair {
			if field, is_ident := pair.field.derived.(^ast.Ident); is_ident && field.name == name {
				return pair.value
			}
		}
	}
	if position < len(args) {
		if _, is_pair := args[position].derived.(^ast.Field_Value); !is_pair {
			return args[position]
		}
	}
	return nil
}

@(private = "file")
display_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Display_Text_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Value_Decl:
		display_check_value_decl(walk, item)
	case ^ast.Call_Expr:
		name := display_call_name(item.expr)
		switch name {
		case "action_bar_item":
			display_check_expr(walk, display_arg_at(item.args, 0, "name"), .Label)
		case "button", "button_fitted", "bevelled_button":
			display_check_expr(walk, display_arg_at(item.args, 3, "label"), .Label)
		}
	case ^ast.Comp_Lit:
		if display_type_name(item.type) == "Setting_Text" {
			display_check_setting_text_literal(walk, item)
		} else if item.type != nil {
			if arr, is_arr := item.type.derived.(^ast.Array_Type); is_arr && display_type_name(arr.elem) == "Context_Menu_Item" {
				for elem in item.elems {
					if row, is_row := elem.derived.(^ast.Comp_Lit); is_row {
						for field in row.elems {
							if pair, is_pair := field.derived.(^ast.Field_Value); is_pair {
								if ident, is_ident := pair.field.derived.(^ast.Ident); is_ident && ident.name == "label" {
									display_check_expr(walk, pair.value, .Label)
								}
							}
						}
					}
				}
			}
		}
	}
	return visitor
}

// display_texts_of_source parses one Odin source file and reports each
// display text that breaks docs/WRITING.md.
display_texts_of_source :: proc(file, source: string) -> (faults: []Display_Text_Fault, text_count: int, ok: bool) {
	list := make([dynamic]Display_Text_Fault, context.temp_allocator)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, 0, false
	}
	defer virtual.arena_destroy(&arena)
	walk := Display_Text_Walk{file = file, faults = &list}
	{
		context.allocator = virtual.arena_allocator(&arena)
		tree := ast.new_from_positions(ast.File, {}, {})
		tree.src = source
		tree.fullpath = file
		reader := parser.default_parser()
		reader.err = foundation.tokenizer_quiet_error
		reader.warn = foundation.tokenizer_quiet_error
		if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
			return nil, 0, false
		}
		visitor := ast.Visitor{visit = display_visit, data = &walk}
		for decl in tree.decls {
			ast.walk(&visitor, decl)
		}
	}
	return list[:], walk.text_count, true
}

// display_texts_of_tree checks every non-test module source under root
// ("": the repository root).
display_texts_of_tree :: proc(root: string) -> (faults: []Display_Text_Fault, file_count: int, text_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := DISPLAY_TEXT_CHECKED_FOLDERS
	for folder in folders {
		foundation.source_files_of_a_folder(root == "" ? folder : foundation.join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	list := make([dynamic]Display_Text_Fault, context.temp_allocator)
	for file in files {
		if source_is_a_test(file) {
			continue
		}
		source, read_ok := foundation.read_text_file_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, 0, false
		}
		file_count += 1
		found, count, parsed := display_texts_of_source(file, source)
		if !parsed {
			fmt.eprintfln("modustool: cannot parse %s for the check of the display texts", file)
			return nil, 0, 0, false
		}
		text_count += count
		append(&list, ..found)
	}
	return list[:], file_count, text_count, true
}

@(private = "file")
display_text_problem_message :: proc(problem: Display_Text_Problem) -> string {
	switch problem {
	case .None:
		return ""
	case .Forbidden_Word:
		return "uses a forbidden word of docs/WRITING.md"
	case .Contraction:
		return "uses a contraction (docs/WRITING.md forbids contractions)"
	case .Error_Title:
		return "uses Error or Failure as a title or prefix"
	case .Failed_Alone:
		return "uses \"failed\" with nothing after it"
	case .Not_Sentence_Case:
		return "is not in sentence case"
	case .Wrong_End_Period:
		return "has a wrong end period"
	}
	return ""
}

// display_text_check refuses module display texts, setting descriptions,
// and labels that break docs/WRITING.md.
display_text_check :: proc() -> bool {
	faults, file_count, text_count, ok := display_texts_of_tree("")
	if !ok {
		return false
	}
	for fault in faults {
		fmt.eprintfln("modustool: %s:%d: %q %s (%s)", fault.file, fault.line, fault.text, display_text_problem_message(fault.problem), fault.detail)
	}
	if len(faults) > 0 {
		fmt.eprintfln("modustool: test failed: %d display texts break docs/WRITING.md", len(faults))
		return false
	}
	foundation.test_passed_print("all %d display texts across %d module sources keep docs/WRITING.md", text_count, file_count)
	return true
}
