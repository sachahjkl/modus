// The colors of the code on the site (docs/SITE.md, "The colors of the
// code"). The tool colors the code when it writes the pages, as static
// markup: no script, no request, nothing new in the Content-Security-Policy.
// Odin is read by the tokenizer of the compiler itself (core:odin/tokenizer),
// not by a grammar of regular expressions, so a token is what the compiler
// sees. The output holds every byte of the source: the text of the output
// with its tags removed is the source.
package site

import "core:fmt"
import "core:odin/tokenizer"
import "core:strings"
import "modus:console_language"
import "modus:graphics"
import "modus:lex_parser"
import "modustool:foundation"
import "modustool:build"

// The classes of the code. Each one has a short class name, because a page
// of declarations holds thousands of them:
//   c-k  a keyword
//   c-t  a type: a built-in type, or a name in the place of a type
//   c-l  a literal: a number, a string, a rune, a constant, a member
//   c-n  a name at its declaration: "name :: proc", "Name :: struct"
//   c-d  a directive or an attribute: #assert, @(private)
//   c-c  a comment
//   c-p  an operator or punctuation: the one quiet class
// A type of the contract is a reference to its card (site_type_reference),
// in the color of c-t.
Site_Code_Class :: enum {
	None,
	Keyword,
	Type,
	Literal,
	Name,
	Directive,
	Comment,
	Punctuation,
	Reference, // A type of the contract: a reference to its card.
}

Site_Code_Class_Description :: struct {
	name:  string, // The class "c-<name>".
	title: string,
	class: graphics.Code_Class, // Its color: the table of the colors of code of the system.
}

// The classes of the site and the classes of the colors of code of the
// system (src/library/modus/graphics/code_colors.odin): the terminal of the system
// reads the same table, so a type or a literal has one color on the site
// and in the console. Each color is at least SITE_VALUE_CONTRAST_LEAST on
// the background of a block of code (the track color) in both forms.
site_code_classes := [Site_Code_Class]Site_Code_Class_Description {
	.None        = {},
	.Keyword     = {name = "k", title = "Keyword", class = .Keyword},
	.Type        = {name = "t", title = "Type", class = .Type},
	.Literal     = {name = "l", title = "Literal, constant or member", class = .Literal},
	.Name        = {name = "n", title = "Name at its declaration", class = .Name},
	.Directive   = {name = "d", title = "Directive or attribute", class = .Directive},
	.Comment     = {name = "c", title = "Comment", class = .Comment},
	.Punctuation = {name = "p", title = "Operator and punctuation", class = .Punctuation},
	.Reference   = {},
}

// site_code_color gives the color of a class in one form.
site_code_color :: proc(class: Site_Code_Class, light: bool) -> graphics.Color {
	return graphics.code_class_color(site_code_classes[class].class, light ? graphics.Appearance.Light : graphics.Appearance.Dark)
}

// site_code_rules gives the rules of the style sheet for the classes of the
// code in one form; a reference to a card in a block of code takes the
// color of a type.
site_code_rules :: proc(light: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for class in Site_Code_Class {
		if site_code_classes[class].name == "" {
			continue
		}
		fmt.sbprintf(&b, ".c-%s {{ color: %s; }}\n", site_code_classes[class].name, site_color(site_code_color(class, light)))
	}
	fmt.sbprintf(&b, "pre .type-reference {{ color: %s; }}\n", site_color(site_code_color(.Type, light)))
	return strings.to_string(b)
}

site_code_token_text :: proc(source: string, token: build.Odin_Token) -> string {
	return source[token.start:token.end]
}

// site_code_token_before gives the token before an index with no comment
// between, or -1.
site_code_token_before :: proc(tokens: []build.Odin_Token, index: int) -> int {
	for other := index - 1; other >= 0; other -= 1 {
		if tokens[other].kind != .Comment {
			return other
		}
	}
	return -1
}

// site_code_token_after gives the token after an index with no comment
// between, or -1.
site_code_token_after :: proc(tokens: []build.Odin_Token, index: int) -> int {
	for other := index + 1; other < len(tokens); other += 1 {
		if tokens[other].kind != .Comment {
			return other
		}
	}
	return -1
}

// site_code_in_type_place tells whether a name is in the place of a type:
// after ":" (but not "::"), "^", "]", "->" or "distinct"; a name after
// "qualifier." takes the place of its qualifier.
site_code_in_type_place :: proc(source: string, tokens: []build.Odin_Token, index: int) -> bool {
	previous := site_code_token_before(tokens, index)
	if previous < 0 {
		return false
	}
	#partial switch tokens[previous].kind {
	case .Period:
		qualifier := site_code_token_before(tokens, previous)
		return qualifier >= 0 && tokens[qualifier].kind == .Ident && site_code_in_type_place(source, tokens, qualifier)
	case .Colon:
		// The second colon of "::" is not the place of a type.
		first := site_code_token_before(tokens, previous)
		return !(first >= 0 && tokens[first].kind == .Colon && tokens[first].end == tokens[previous].start)
	case .Pointer, .Close_Bracket, .Arrow_Right, .Distinct:
		return true
	}
	return false
}

// site_code_odin_classes gives the class of each token, and for a reference
// the key of its type. The rules, from the tokens only:
//   a comment, a number, a string, a rune: their class;
//   a keyword of the tokenizer: Keyword;
//   "#" and the name after it, "@" and the first name of its attribute: Directive;
//   a name before "::": Name;
//   true, false, nil, a name in capitals, ".Member" (a period with no value
//   before it), a member of an enum body: Literal;
//   "package.Name" of a documented package, or Name of the package of the
//   text, that is a type of the contract: Reference;
//   a built-in type: Type;
//   a name with a capital in the place of a type (after ":", "^", "]",
//   "->" or "distinct", or after "qualifier." in that place): Type;
//   an operator or punctuation: Punctuation; any other name: no class.
// A name with a capital elsewhere is not guessed to be a type.
site_code_odin_classes :: proc(site: ^Site, source: string, tokens: []build.Odin_Token, package_name: string) -> (classes: []Site_Code_Class, keys: []string) {
	classes = make([]Site_Code_Class, len(tokens), context.temp_allocator)
	keys = make([]string, len(tokens), context.temp_allocator)
	text := site_code_token_text
	before := site_code_token_before
	after := site_code_token_after
	in_type_place := site_code_in_type_place
	documented := make(map[string]bool, context.temp_allocator)
	packages := SITE_TYPE_PACKAGES
	for folder in packages {
		documented[folder[strings.last_index_byte(folder, '/') + 1:]] = true
	}
	built_in := make(map[string]bool, context.temp_allocator)
	built_in_names := build.ODIN_BUILT_IN_TYPES
	for name in built_in_names {
		built_in[name] = true
	}
	braces := make([dynamic]bool, context.temp_allocator) // For each open brace: is it the body of an enum.
	enum_pending := false
	directive_next := false
	attribute_open := false

	for token, index in tokens {
		kind := token.kind
		switch {
		case kind == .Comment:
			classes[index] = .Comment
			continue
		case kind == .File_Tag:
			classes[index] = .Directive
			continue
		case kind == .Integer || kind == .Float || kind == .Imag || kind == .String || kind == .Rune:
			classes[index] = .Literal
		case kind == .Hash:
			classes[index] = .Directive
			directive_next = true
			continue
		case kind == .At:
			classes[index] = .Directive
			directive_next = true
			continue
		case kind == .Typeid:
			classes[index] = .Type
		case tokenizer.is_keyword(kind):
			classes[index] = .Keyword
			if kind == .Enum {
				enum_pending = true
			} else if kind == .Struct || kind == .Union || kind == .Proc || kind == .Bit_Set || kind == .Bit_Field {
				enum_pending = false
			}
		case kind == .Ident:
			name := text(source, token)
			previous := before(tokens, index)
			next := after(tokens, index)
			declares := next >= 0 && tokens[next].kind == .Colon && next + 1 < len(tokens) && tokens[next + 1].kind == .Colon && tokens[next].end == tokens[next + 1].start
			after_period := previous >= 0 && tokens[previous].kind == .Period
			qualifier := after_period ? before(tokens, previous) : -1
			qualified := qualifier >= 0 && tokens[qualifier].kind == .Ident
			in_enum := len(braces) > 0 && braces[len(braces) - 1] && previous >= 0 && (tokens[previous].kind == .Open_Brace || tokens[previous].kind == .Comma)
			switch {
			case directive_next || attribute_open:
				classes[index] = .Directive
				attribute_open = false
			case declares:
				classes[index] = .Name
			case name == "true" || name == "false" || name == "nil":
				classes[index] = .Literal
			case qualified && documented[text(source, tokens[qualifier])]:
				key := strings.concatenate({text(source, tokens[qualifier]), ".", name}, context.temp_allocator)
				if _, found := site_type_index(site, key); found {
					classes[index] = .Reference
					keys[index] = key
				} else if build.name_is_constant(name) {
					classes[index] = .Literal
				} else if build.name_is_capital(name) && in_type_place(source, tokens, index) {
					classes[index] = .Type
				}
			case after_period && !qualified:
				// ".Member": a period with no name before it.
				previous_value := before(tokens, previous)
				if previous_value < 0 || (tokens[previous_value].kind != .Close_Paren && tokens[previous_value].kind != .Close_Bracket && tokens[previous_value].kind != .Pointer && tokens[previous_value].kind != .Close_Brace) {
					classes[index] = .Literal
				}
			case in_enum:
				classes[index] = .Literal
			case !after_period && package_name != "" && build.name_is_capital(name):
				key := strings.concatenate({package_name, ".", name}, context.temp_allocator)
				if _, found := site_type_index(site, key); found {
					classes[index] = .Reference
					keys[index] = key
				} else if build.name_is_constant(name) {
					classes[index] = .Literal
				} else if in_type_place(source, tokens, index) {
					classes[index] = .Type
				}
			case built_in[name]:
				classes[index] = .Type
			case build.name_is_constant(name):
				classes[index] = .Literal
			case build.name_is_capital(name) && in_type_place(source, tokens, index):
				classes[index] = .Type
			}
		case kind > .B_Operator_Begin && kind < .B_Operator_End:
			classes[index] = .Punctuation
			#partial switch kind {
			case .Open_Brace:
				append(&braces, enum_pending)
				enum_pending = false
			case .Close_Brace:
				if len(braces) > 0 {
					pop(&braces)
				}
			case .Open_Paren:
				// "@(" opens an attribute: its first name is a directive.
				previous := before(tokens, index)
				if previous >= 0 && tokens[previous].kind == .At {
					attribute_open = true
				}
			}
		}
		directive_next = false
	}
	return classes, keys
}

// What a fragment of code in a text needs to link its names to their
// declarations: the page that holds it and the folders that the text
// around it names (docs/SITE.md, "The declarations of the sources").
Site_Code_Links :: struct {
	site:            ^Site,
	from_page:       string,
	context_folders: []string,
}

// site_code_link_place gives the declaration that a name of a fragment of
// code links to, or -1. A name after "package." is looked for in that
// package; a name after another value and a period is a field, and a short
// name is a local of the example: neither links.
site_code_link_place :: proc(links: ^Site_Code_Links, source: string, tokens: []build.Odin_Token, index: int) -> int {
	if links == nil || links.site == nil || len(links.site.declarations.declarations) == 0 {
		return -1
	}
	name := site_code_token_text(source, tokens[index])
	if len(name) < SITE_DECLARATION_SHORTEST_NAME_IN_CODE || build.is_odin_word(name) {
		return -1
	}
	span := build.Declaration_Span{name = name}
	previous := site_code_token_before(tokens, index)
	if previous >= 0 && tokens[previous].kind == .Period {
		qualifier := site_code_token_before(tokens, previous)
		if qualifier < 0 || tokens[qualifier].kind != .Ident {
			return -1
		}
		span.qualifier = site_code_token_text(source, tokens[qualifier])
		if span.qualifier not_in links.site.declarations.packages {
			return -1
		}
	}
	next := site_code_token_after(tokens, index)
	span.called = next >= 0 && tokens[next].kind == .Open_Paren
	place, resolution := build.declaration_resolve(&links.site.declarations, span, links.context_folders)
	return resolution == .Linked ? place : -1
}

// site_code_odin writes a text of Odin with the class of each token, and
// each type of the contract as a reference to its card. package_name is the
// package of the text ("operation" for a declaration of src/library/modus/contract/operation),
// or "" when it is not known (a block of a guide): then only "package.Name"
// of a documented package is a reference. With links, each name that the
// declaration index resolves is a link to its declaration. It writes
// nothing and gives false when the tokenizer refuses the text.
site_code_odin :: proc(site: ^Site, b: ^strings.Builder, source, package_name: string, links: ^Site_Code_Links = nil) -> bool {
	tokens, ok := build.odin_tokens(source)
	if !ok {
		return false
	}
	classes, keys := site_code_odin_classes(site, source, tokens, package_name)
	position := 0
	open := Site_Code_Class.None // The class of the span that is open.
	close_span :: proc(b: ^strings.Builder, open: ^Site_Code_Class) {
		if open^ != .None {
			strings.write_string(b, "</span>")
			open^ = .None
		}
	}
	for token, index in tokens {
		gap := source[position:token.start]
		class := classes[index]
		// Two tokens of one class with only spaces between share one span:
		// the pages stay smaller.
		if open != .None && (class != open || strings.trim_space(gap) != "") {
			close_span(b, &open)
		}
		foundation.html_escape(b, gap)
		bytes := source[token.start:token.end]
		if token.kind == .Ident && links != nil && (class == .None || class == .Type || class == .Literal) {
			if place := site_code_link_place(links, source, tokens, index); place >= 0 {
				close_span(b, &open)
				site_declaration_link_in_code(links.site, b, links.from_page, bytes, class, place)
				position = token.end
				continue
			}
		}
		switch class {
		case .None:
			close_span(b, &open)
			foundation.html_escape(b, bytes)
		case .Reference:
			close_span(b, &open)
			site_type_reference(site, b, keys[index], bytes, false)
		case .Keyword, .Type, .Literal, .Name, .Directive, .Comment, .Punctuation:
			if open != class {
				close_span(b, &open)
				fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
				open = class
			}
			foundation.html_escape(b, bytes)
		}
		position = token.end
	}
	close_span(b, &open)
	foundation.html_escape(b, source[position:])
	return true
}

// site_code_block_html gives a text of Odin as the inside of a block of
// code: colored, or plain when the tokenizer refuses it. A plain block is
// counted, and the first one is named by its place, so that it is seen.
site_code_block_html :: proc(site: ^Site, source, package_name, place: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	if site_code_odin(site, &b, source, package_name) {
		return strings.to_string(b)
	}
	site.code_blocks_not_colored += 1
	if site.first_code_block_not_colored == "" {
		site.first_code_block_not_colored = place
	}
	plain := strings.builder_make(context.temp_allocator)
	foundation.html_escape(&plain, source)
	return strings.to_string(plain)
}

// site_code_span writes a part of a signature in the span of a class: the
// signatures are built from their parts, so each part has its role with no
// tokenizer.
site_code_span :: proc(b: ^strings.Builder, class: Site_Code_Class, text: string) {
	fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
	foundation.html_escape(b, text)
	strings.write_string(b, "</span>")
}

// ---- Static Lex syntax highlighting (docs/SITE.md, "The colors of the code").
//
// Reads Lex source with the canonical scanner (modus:console_language) and
// parser unit/kind tables (modus:lex_parser). Preserves every byte of source
// verbatim and never rejects partial expressions, error examples, or console
// transcripts whose prompt lines start with "> ".

Site_Lex_Token_Kind :: enum u8 {
	Comment,
	Name,
	Number,
	Text,
	Hash,
	Member,
	Operator,
	Unknown,
}

Site_Lex_Token :: struct {
	kind:  Site_Lex_Token_Kind,
	start: int,
	end:   int,
}

@(private = "file")
site_lex_token_before :: proc(tokens: []Site_Lex_Token, index: int) -> int {
	for other := index - 1; other >= 0; other -= 1 {
		if tokens[other].kind != .Comment {
			return other
		}
	}
	return -1
}

@(private = "file")
site_lex_token_after :: proc(tokens: []Site_Lex_Token, index: int) -> int {
	for other := index + 1; other < len(tokens); other += 1 {
		if tokens[other].kind != .Comment {
			return other
		}
	}
	return -1
}

@(private = "file")
site_lex_is_unit_name :: proc(name: string) -> bool {
	if _, ok := lex_parser.integer_unit_of_name(name); ok {
		return true
	}
	switch name {
	case "GiB", "min", "h", "d":
		return true
	}
	return false
}

@(private = "file")
site_lex_is_control_keyword :: proc(name: string) -> bool {
	switch name {
	case "let", "in", "if", "then", "else", "match", "with", "for", "and", "or", "not":
		return true
	}
	return false
}

@(private = "file")
site_lex_is_form_keyword :: proc(name: string) -> bool {
	switch name {
	case "plan", "project", "recipe", "store":
		return true
	}
	return false
}

@(private = "file")
site_lex_is_type_name :: proc(name: string) -> bool {
	if _, ok := lex_parser.param_kind_of_name(name); ok {
		return true
	}
	switch name {
	case "Unit", "Stream", "Value", "Process", "Memory", "Grant", "Reading", "Rectangle", "Command", "Loaded", "Wiring", "Log_Level":
		return true
	}
	return false
}

@(private = "file")
site_lex_is_dot :: proc(source: string, tok: Site_Lex_Token) -> bool {
	return tok.kind == .Operator && tok.end - tok.start == 1 && source[tok.start] == '.'
}

@(private = "file")
site_lex_is_single_equal :: proc(source: string, tokens: []Site_Lex_Token, index: int) -> bool {
	if index < 0 || index >= len(tokens) {
		return false
	}
	tok := tokens[index]
	if tok.kind != .Operator || tok.end - tok.start != 1 || source[tok.start] != '=' {
		return false
	}
	if index + 1 < len(tokens) {
		nxt := tokens[index + 1]
		if nxt.kind == .Operator && nxt.start == tok.end && nxt.end - nxt.start == 1 && source[nxt.start] == '=' {
			return false
		}
	}
	return true
}

// site_code_lex_tokens scans a Lex source with console_language.token_next,
// emitting comments explicitly and splitting dotted names into name segments
// and '.' punctuation tokens while keeping every byte span exact.
site_code_lex_tokens :: proc(source: string) -> []Site_Lex_Token {
	tokens := make([dynamic]Site_Lex_Token, context.temp_allocator)
	position := 0
	for position < len(source) {
		tok := console_language.token_next(source, position, true)
		// Emit any "// ..." line comments inside source[position:tok.start].
		gap_pos := position
		for gap_pos < tok.start {
			if console_language.comment_starts(source, gap_pos) {
				cend := console_language.comment_end(source, gap_pos)
				append(&tokens, Site_Lex_Token{kind = .Comment, start = gap_pos, end = cend})
				gap_pos = cend
			} else {
				gap_pos += 1
			}
		}
		if tok.kind == .None {
			break
		}
		switch tok.kind {
		case .None:
			break
		case .Name:
			// Split dotted names ("settings.set", "values.display.font") into
			// segments and '.' tokens so calls and field paths highlight cleanly.
			seg_start := tok.start
			for i := tok.start; i < tok.end; i += 1 {
				if source[i] == '.' {
					if i > seg_start {
						append(&tokens, Site_Lex_Token{kind = .Name, start = seg_start, end = i})
					}
					append(&tokens, Site_Lex_Token{kind = .Operator, start = i, end = i + 1})
					seg_start = i + 1
				}
			}
			if seg_start < tok.end {
				append(&tokens, Site_Lex_Token{kind = .Name, start = seg_start, end = tok.end})
			}
		case .Number:
			append(&tokens, Site_Lex_Token{kind = .Number, start = tok.start, end = tok.end})
		case .Text, .Text_Unfinished:
			append(&tokens, Site_Lex_Token{kind = .Text, start = tok.start, end = tok.end})
		case .Hash:
			append(&tokens, Site_Lex_Token{kind = .Hash, start = tok.start, end = tok.end})
		case .Member:
			// ".field" glued directly after ')', ']', '}', or a Name is postfix
			// field selection, not a standalone enum member literal.
			is_field_select := false
			if len(tokens) > 0 {
				prev := tokens[len(tokens) - 1]
				if prev.end == tok.start {
					if prev.kind == .Name {
						is_field_select = true
					} else if prev.kind == .Operator && prev.end - prev.start == 1 {
						ch := source[prev.start]
						is_field_select = ch == ')' || ch == ']' || ch == '}'
					}
				}
			}
			if is_field_select {
				append(&tokens, Site_Lex_Token{kind = .Operator, start = tok.start, end = tok.start + 1})
				if tok.start + 1 < tok.end {
					append(&tokens, Site_Lex_Token{kind = .Name, start = tok.start + 1, end = tok.end})
				}
			} else {
				append(&tokens, Site_Lex_Token{kind = .Member, start = tok.start, end = tok.end})
			}
		case .Operator, .Arrow, .Pipe, .Function_Arrow:
			append(&tokens, Site_Lex_Token{kind = .Operator, start = tok.start, end = tok.end})
		case .Unknown:
			append(&tokens, Site_Lex_Token{kind = .Unknown, start = tok.start, end = tok.end})
		}
		if tok.end <= position {
			break
		}
		position = tok.end
	}
	return tokens[:]
}

// site_code_lex_classes assigns each Lex token a Site_Code_Class.
site_code_lex_classes :: proc(source: string, tokens: []Site_Lex_Token) -> []Site_Code_Class {
	classes := make([]Site_Code_Class, len(tokens), context.temp_allocator)
	for tok, index in tokens {
		switch tok.kind {
		case .Comment:
			classes[index] = .Comment
		case .Number, .Text, .Hash, .Member:
			classes[index] = .Literal
		case .Operator:
			classes[index] = .Punctuation
		case .Unknown:
			classes[index] = .None
		case .Name:
			name := source[tok.start:tok.end]
			prev := site_lex_token_before(tokens, index)
			next := site_lex_token_after(tokens, index)
			after_dot := prev >= 0 && site_lex_is_dot(source, tokens[prev])
			before_dot := next >= 0 && site_lex_is_dot(source, tokens[next])
			before_paren := next >= 0 && tokens[next].kind == .Operator && source[tokens[next].start:tokens[next].end] == "("
			before_eq := site_lex_is_single_equal(source, tokens, next)

			// 1. Placeholder / wildcard '_' -> quiet punctuation.
			if name == "_" {
				classes[index] = .Punctuation
				continue
			}
			// 2. Boolean literals.
			if name == "true" || name == "false" {
				classes[index] = .Literal
				continue
			}
			// 3. Unit suffix directly after a number on the same line.
			if prev >= 0 && tokens[prev].kind == .Number && site_lex_is_unit_name(name) && strings.index_byte(source[tokens[prev].end:tok.start], '\n') < 0 {
				classes[index] = .Type
				continue
			}
			// 4. Unit inside `Integer[Unit]`.
			if prev >= 0 && tokens[prev].kind == .Operator && source[tokens[prev].start:tokens[prev].end] == "[" && site_lex_is_unit_name(name) {
				prev2 := site_lex_token_before(tokens, prev)
				if prev2 >= 0 && tokens[prev2].kind == .Name && source[tokens[prev2].start:tokens[prev2].end] == "Integer" {
					classes[index] = .Type
					continue
				}
			}
			// 5. Control keywords (`let`, `in`, `if`, `then`, `else`, `match`, `with`, `for`, `and`, `or`, `not`).
			if !after_dot && site_lex_is_control_keyword(name) {
				classes[index] = .Keyword
				continue
			}
			// 6. Declaration form keywords (`plan`, `project`, `recipe`, `store`),
			// except when used as a record field key (`store = ...`) or after '.'.
			if !after_dot && !before_eq && site_lex_is_form_keyword(name) {
				classes[index] = .Keyword
				continue
			}
			// 7. Type names: after ':', inside known Lex/contract type set, or
			// capitalized type after '.' (such as `log_reader.Fact_Probe`) when not a call.
			if prev >= 0 && tokens[prev].kind == .Operator && source[tokens[prev].start:tokens[prev].end] == ":" && build.name_is_capital(name) {
				classes[index] = .Type
				continue
			}
			if !before_eq && site_lex_is_type_name(name) {
				classes[index] = .Type
				continue
			}
			if after_dot && !before_paren && !before_eq && build.name_is_capital(name) {
				classes[index] = .Type
				continue
			}
			// 8. Function / command call name before '('.
			if before_paren {
				classes[index] = .Name
				continue
			}
			// 9. Bare piped command stage (`|> f` or `|> s.sum_values`).
			if !before_dot {
				chain_head := index
				for {
					p := site_lex_token_before(tokens, chain_head)
					if p < 0 || !site_lex_is_dot(source, tokens[p]) {
						break
					}
					q := site_lex_token_before(tokens, p)
					if q < 0 || tokens[q].kind != .Name {
						break
					}
					chain_head = q
				}
				before_chain := site_lex_token_before(tokens, chain_head)
				if before_chain >= 0 && tokens[before_chain].kind == .Operator && source[tokens[before_chain].start:tokens[before_chain].end] == "|>" {
					classes[index] = .Name
					continue
				}
			}
			// 10. Binding name, record field key, or named argument before '='.
			if before_eq {
				chain_head := index
				for {
					p := site_lex_token_before(tokens, chain_head)
					if p < 0 || !site_lex_is_dot(source, tokens[p]) {
						break
					}
					q := site_lex_token_before(tokens, p)
					if q < 0 || tokens[q].kind != .Name {
						break
					}
					chain_head = q
				}
				lhs_prev := site_lex_token_before(tokens, chain_head)
				is_binding := lhs_prev < 0
				if !is_binding {
					if strings.index_byte(source[tokens[lhs_prev].end:tokens[chain_head].start], '\n') >= 0 {
						is_binding = true
					} else if tokens[lhs_prev].kind == .Name && source[tokens[lhs_prev].start:tokens[lhs_prev].end] == "let" {
						is_binding = true
					} else if tokens[lhs_prev].kind == .Operator {
						op := source[tokens[lhs_prev].start:tokens[lhs_prev].end]
						is_binding = op == "{" || op == "(" || op == ","
					}
				}
				if is_binding {
					classes[index] = .Name
					continue
				}
			}
			// 11. As-pattern binding (`r @ { ... }`) or comprehension binder (`for x in`).
			if next >= 0 && tokens[next].kind == .Operator && source[tokens[next].start:tokens[next].end] == "@" {
				classes[index] = .Name
				continue
			}
			if prev >= 0 && tokens[prev].kind == .Name && source[tokens[prev].start:tokens[prev].end] == "for" &&
			   next >= 0 && tokens[next].kind == .Name && source[tokens[next].start:tokens[next].end] == "in" {
				classes[index] = .Name
				continue
			}
		}
	}
	return classes
}

@(private = "file")
site_code_lex_fragment :: proc(b: ^strings.Builder, source: string) {
	tokens := site_code_lex_tokens(source)
	classes := site_code_lex_classes(source, tokens)
	position := 0
	open := Site_Code_Class.None
	close_span :: proc(b: ^strings.Builder, open: ^Site_Code_Class) {
		if open^ != .None {
			strings.write_string(b, "</span>")
			open^ = .None
		}
	}
	for tok, index in tokens {
		gap := source[position:tok.start]
		class := classes[index]
		if open != .None && (class != open || strings.trim_space(gap) != "") {
			close_span(b, &open)
		}
		foundation.html_escape(b, gap)
		bytes := source[tok.start:tok.end]
		switch class {
		case .None, .Reference:
			close_span(b, &open)
			foundation.html_escape(b, bytes)
		case .Keyword, .Type, .Literal, .Name, .Directive, .Comment, .Punctuation:
			if open != class {
				close_span(b, &open)
				fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
				open = class
			}
			foundation.html_escape(b, bytes)
		}
		position = tok.end
	}
	close_span(b, &open)
	foundation.html_escape(b, source[position:])
}

@(private = "file")
site_code_lex_is_transcript :: proc(source: string) -> bool {
	rest := source
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		if strings.trim_space(line) != "" {
			return strings.has_prefix(line, "> ")
		}
		if nl < 0 {
			break
		}
		rest = rest[nl + 1:]
	}
	return false
}

// site_code_lex writes Lex source (or a console transcript whose prompt lines
// start with "> ") with static Site_Code_Class spans. Every byte of source is
// preserved verbatim.
site_code_lex :: proc(b: ^strings.Builder, source: string) -> bool {
	if !site_code_lex_is_transcript(source) {
		site_code_lex_fragment(b, source)
		return true
	}
	rest := source
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		if strings.has_prefix(line, "> ") {
			site_code_span(b, .Punctuation, ">")
			strings.write_byte(b, ' ')
			site_code_lex_fragment(b, line[2:])
		} else {
			foundation.html_escape(b, line)
		}
		if nl < 0 {
			break
		}
		strings.write_byte(b, '\n')
		rest = rest[nl + 1:]
	}
	return true
}

// site_code_lex_block_html gives a Lex fenced block as colored static HTML.
site_code_lex_block_html :: proc(site: ^Site, source, place: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	if site_code_lex(&b, source) {
		return strings.to_string(b)
	}
	site.code_blocks_not_colored += 1
	if site.first_code_block_not_colored == "" {
		site.first_code_block_not_colored = place
	}
	plain := strings.builder_make(context.temp_allocator)
	foundation.html_escape(&plain, source)
	return strings.to_string(plain)
}
