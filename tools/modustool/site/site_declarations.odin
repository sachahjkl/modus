// The declarations of the sources on the site (docs/SITE.md, "The
// declarations of the sources"). The tool reads every procedure, type,
// constant and global variable that the sources of the system declare at
// the top of a package, with the parser of Odin, into one declaration
// index. A code span of a guide, of a news entry or of a source comment that
// names one of them becomes a link to it, with a short card that the page
// holds once; a code span that is a fragment of Odin is colored by the
// tokenizer of the compiler, as the blocks of code are.
package site

import "modus:contract/value_kinds"
import "core:fmt"
import "core:odin/tokenizer"
import "core:strings"
import "modustool:foundation"
import "modustool:build"

// The id of the card of a declaration on a page is this prefix and the
// place of the declaration in the index; its first sentence has the suffix
// of the type cards too, so that a screen reader reads it with the link.
SITE_DECLARATION_CARD_PREFIX :: "declaration-"
// The spans that the command names when it counts the spans that are
// ambiguous or that name no declaration.
SITE_DECLARATION_FIRST_LISTED :: 5
// Inside a fragment of code, a name shorter than this is a local of the
// example ("a", "d"), not a reference.
SITE_DECLARATION_SHORTEST_NAME_IN_CODE :: 3

// The value kind of each kind of declaration: its icon and its color.
site_declaration_value_kinds := [build.Declaration_Kind]value_kinds.Value_Kind {
	.Procedure = .Procedure,
	.Type      = .Type,
	.Constant  = .Constant,
	.Variable  = .Variable,
}

// What became of the code spans that name a declaration, for the summary of
// the command: a stale name in a guide is then seen.
Site_Declaration_Span_Counts :: struct {
	linked:          int,
	ambiguous:       int,
	not_found:       int,
	first_ambiguous: [SITE_DECLARATION_FIRST_LISTED]string,
	first_not_found: [SITE_DECLARATION_FIRST_LISTED]string,
}

// site_declarations_read makes the declaration index of the sources of the
// system. A file that the parser refuses is counted, not fatal: the build
// of the system checks its sources.
site_declarations_read :: proc(site: ^Site) -> bool {
	site.declarations = build.declaration_index_make()
	return build.declaration_index_fill(&site.declarations, nil)
}

// site_context_folders gives the folders of the index that a text names:
// "src/library/modus/graphics" and "src/library/modus/graphics/blend.odin" both give
// "src/library/modus/graphics". The heading and the paragraph of a span give the
// packages that the span most likely means.
site_context_folders :: proc(index: ^build.Declaration_Index, text: string) -> []string {
	folders := make([dynamic]string, context.temp_allocator)
	if index == nil || len(index.folders) == 0 {
		return folders[:]
	}
	start := 0
	for start < len(text) {
		for start < len(text) && strings.index_byte(" `()[],;\"'*", text[start]) >= 0 {
			start += 1
		}
		end := start
		for end < len(text) && strings.index_byte(" `()[],;\"'*", text[end]) < 0 {
			end += 1
		}
		word := strings.trim_right(text[start:end], ".:")
		if colon := strings.index_byte(word, ':'); colon > 0 {
			word = word[:colon]
		}
		if strings.contains(word, "/") {
			candidate := strings.trim_suffix(word, "/")
			if strings.has_suffix(candidate, ".odin") {
				candidate = candidate[:max(strings.last_index_byte(candidate, '/'), 0)]
			}
			if candidate in index.folders {
				append(&folders, candidate)
			}
		}
		start = end
	}
	return folders[:]
}

// site_declaration_count records what became of a span that has the form
// of a name, with its place, so that the command names the first ones.
site_declaration_count :: proc(site: ^Site, resolution: build.Declaration_Resolution, place, code: string) {
	counts := &site.declaration_spans
	// A span is listed once, among the first ones.
	listed :: proc(list: ^[SITE_DECLARATION_FIRST_LISTED]string, entry: string) {
		for slot in 0 ..< SITE_DECLARATION_FIRST_LISTED {
			if list[slot] == entry {
				return
			}
			if list[slot] == "" {
				list[slot] = entry
				return
			}
		}
	}
	entry := fmt.tprintf("%s: `%s`", place, code)
	switch resolution {
	case .Linked:
		counts.linked += 1
	case .Ambiguous:
		counts.ambiguous += 1
		listed(&counts.first_ambiguous, entry)
	case .Not_Found:
		counts.not_found += 1
		listed(&counts.first_not_found, entry)
	}
}

// site_declaration_summary gives the lines that the command prints: the
// declarations of the index and the files that the parser refused, then
// the code spans that have the form of a name: linked, ambiguous and not
// found, with the first ones of the last two. A name that is not found does
// not stop the command: many spans are words of a log or of a command.
site_declaration_summary :: proc(site: ^Site) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	index := &site.declarations
	counts := site.declaration_spans
	by_kind: [build.Declaration_Kind]int
	for declaration in index.declarations {
		by_kind[declaration.kind] += 1
	}
	parsed := fmt.tprintf("%d declarations of the sources: %d procedures, %d types, %d constants, %d global variables; %d files not parsed", len(index.declarations), by_kind[.Procedure], by_kind[.Type], by_kind[.Constant], by_kind[.Variable], index.files_not_parsed)
	if index.first_file_not_parsed != "" {
		parsed = strings.concatenate({parsed, ", the first: ", index.first_file_not_parsed}, context.temp_allocator)
	}
	append(&lines, parsed)
	first :: proc(list: [SITE_DECLARATION_FIRST_LISTED]string) -> string {
		parts := make([dynamic]string, context.temp_allocator)
		for item in list {
			if item != "" {
				append(&parts, item)
			}
		}
		return strings.join(parts[:], "; ", context.temp_allocator)
	}
	append(&lines, fmt.tprintf("%d code spans name a declaration and link to it, %d are ambiguous, %d name no declaration", counts.linked, counts.ambiguous, counts.not_found))
	if counts.ambiguous > 0 {
		append(&lines, strings.concatenate({"ambiguous, the first: ", first(counts.first_ambiguous)}, context.temp_allocator))
	}
	if counts.not_found > 0 {
		append(&lines, strings.concatenate({"no declaration, the first: ", first(counts.first_not_found)}, context.temp_allocator))
	}
	return lines[:]
}

// site_declaration_card_id gives the id of the card of a declaration.
site_declaration_card_id :: proc(place: int) -> string {
	return fmt.tprintf("%s%d", SITE_DECLARATION_CARD_PREFIX, place)
}

// site_declaration_export_page gives the place of a declaration on the page
// of its module when it is an export of a module of the build, or "".
site_declaration_export_page :: proc(site: ^Site, declaration: build.Indexed_Declaration) -> string {
	if declaration.kind != .Procedure {
		return ""
	}
	for item in site.reference.modules {
		if item.build.source != declaration.folder {
			continue
		}
		for export in item.description.exports {
			if export.name == declaration.name {
				return strings.concatenate({item.page, "#export-", foundation.text_slug(export.name)}, context.temp_allocator)
			}
		}
	}
	return ""
}

// site_declaration_address gives the link of a declaration from a page: the
// page of its module for an export, else its line in the repository at the
// commit of the build.
site_declaration_address :: proc(site: ^Site, from_page: string, declaration: build.Indexed_Declaration) -> string {
	if page := site_declaration_export_page(site, declaration); page != "" {
		return site_page_link(site, from_page, page)
	}
	return fmt.tprintf("%s#L%d", site_repository_file(site, declaration.file), declaration.line)
}

// site_declaration_type_key gives the key of the type card of a declaration
// that is a type of the contract, or "".
site_declaration_type_key :: proc(site: ^Site, declaration: build.Indexed_Declaration) -> string {
	if declaration.kind != .Type || !strings.has_prefix(declaration.folder, foundation.SOURCE_FOLDER_CONTRACT + "/") {
		return ""
	}
	key := strings.concatenate({declaration.package_name, ".", declaration.name}, context.temp_allocator)
	if _, found := site_type_index(site, key); found {
		return key
	}
	return ""
}

// site_declaration_reference writes a code span that names a declaration:
// a type of the contract as the reference to its type card; another
// declaration as a link in the color and with the icon of its kind, whose
// card the script opens when the pointer rests on it or the focus reaches
// it. With no script the link works and no card opens.
site_declaration_reference :: proc(site: ^Site, b: ^strings.Builder, from_page, code: string, place: int) {
	declaration := site.declarations.declarations[place]
	if key := site_declaration_type_key(site, declaration); key != "" {
		site_type_reference(site, b, key, code, true)
		return
	}
	id := site_declaration_card_id(place)
	strings.write_string(b, "<a class=\"declaration-reference\" href=\"")
	foundation.html_escape(b, site_declaration_address(site, from_page, declaration))
	fmt.sbprintf(b, "\" data-declaration-card=\"%s\" aria-describedby=\"%s%s\">", id, id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
	site_value(b, site_declaration_value_kinds[declaration.kind], code, true)
	strings.write_string(b, "</a>")
}

// site_declaration_link_in_code writes a name inside a colored fragment of
// code as a link to its declaration, with no card: the link is enough
// inside an expression.
site_declaration_link_in_code :: proc(site: ^Site, b: ^strings.Builder, from_page, text: string, class: Site_Code_Class, place: int) {
	declaration := site.declarations.declarations[place]
	strings.write_string(b, "<a class=\"declaration-link\" href=\"")
	foundation.html_escape(b, site_declaration_address(site, from_page, declaration))
	strings.write_string(b, "\">")
	if class != .None && site_code_classes[class].name != "" {
		fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
		foundation.html_escape(b, text)
		strings.write_string(b, "</span>")
	} else {
		foundation.html_escape(b, text)
	}
	strings.write_string(b, "</a>")
}

// The commands that start a code span of a shell: such a span is not Odin.
SITE_COMMAND_NAMES :: [?]string{"modustool", "nix", "odin", "git", "gh", "qemu-system-x86_64", "qemu-img", "cargo", "make", "sh", "bash", "fish", "cd", "ls", "cat", "curl", "ssh", "sudo", "rm", "cp", "mv", "mkdir", "echo", "grep", "rg", "objdump", "readelf", "llvm-objdump", "swtpm", "sbsign", "openssl", "python", "node", "zstd", "sha256sum", "dd", "printf", "basenc", "sops", "lsblk", "sync"}

// site_code_span_is_odin tells whether a code span that is not a single
// name is a fragment of Odin that the site colors. The test leaves a span
// plain when it is unsure; it refuses:
//   a text that the tokenizer refuses, or of one token;
//   a command of a shell (its first word is a known command, or it has
//   "--", "$" or "~/");
//   a path (a "/" with no space on either side) or a file name;
//   a setting "NAME=value" (an "=" with no space on either side);
//   a line of a log or of prose: two names or values side by side with no
//   operator between ("test return_fault", "1031293 us"), or two labels
//   "name: " in one span ("kernel: boot: firmware");
//   a combination of keys or names with "+" alone ("Ctrl+C"): a fragment
//   must hold one part that only code has (a keyword, a literal, a bracket,
//   ":", "::", "->", "^", "." between names, "#" or "@").
site_code_span_is_odin :: proc(code: string) -> bool {
	text := strings.trim_space(code)
	if text == "" || (strings.contains(text, "--") && !strings.contains(text, "---")) || strings.contains_any(text, "$\\") || strings.contains(text, "~/") {
		return false
	}
	first_word := text
	if space := strings.index_byte(text, ' '); space >= 0 {
		first_word = text[:space]
	}
	commands := SITE_COMMAND_NAMES
	for command in commands {
		if first_word == command {
			return false
		}
	}
	if strings.has_prefix(text, "./") || strings.has_prefix(text, "/") {
		return false
	}
	for index in 0 ..< len(text) {
		if text[index] == '/' && index > 0 && index + 1 < len(text) && text[index - 1] != ' ' && text[index + 1] != ' ' {
			return false
		}
		// "NAME=value" with no space is a setting of a command or of the
		// environment, not an assignment of the code.
		if text[index] == '=' && index > 0 && index + 1 < len(text) && foundation.is_word_byte(text[index - 1]) && foundation.is_word_byte(text[index + 1]) {
			return false
		}
	}
	labels := 0
	for index in 1 ..< len(text) {
		if text[index] == ':' && index + 1 < len(text) && text[index + 1] == ' ' && foundation.is_word_byte(text[index - 1]) {
			labels += 1
		}
	}
	if labels >= 2 {
		return false
	}
	tokens, ok := build.odin_tokens(text)
	if !ok || len(tokens) < 2 {
		return false
	}
	is_operand :: proc(kind: tokenizer.Token_Kind) -> bool {
		return kind == .Ident || kind == .Integer || kind == .Float || kind == .Imag || kind == .String || kind == .Rune
	}
	has_code_part := false
	for token, index in tokens {
		if token.kind == .Comment {
			return false
		}
		if index > 0 && is_operand(token.kind) && is_operand(tokens[index - 1].kind) {
			return false
		}
		#partial switch token.kind {
		case .Integer, .Float, .Imag, .String, .Rune, .Open_Paren, .Open_Bracket, .Open_Brace, .Colon, .Arrow_Right, .Pointer, .Hash, .At, .Period, .Ellipsis, .Range_Half, .Range_Full, .Shl, .Shr, .Cmp_Eq, .Not_Eq, .Eq:
			has_code_part = true
		case:
			if tokenizer.is_keyword(token.kind) {
				has_code_part = true
			}
		}
		// An extension after a name and a period is a file: "build.sh".
		if token.kind == .Ident && index >= 2 && tokens[index - 1].kind == .Period && tokens[index - 1].start == tokens[index - 2].end {
			extensions := build.SPAN_FILE_EXTENSIONS
			for extension in extensions {
				if text[token.start:token.end] == extension && token.end == len(text) {
					return false
				}
			}
		}
	}
	return has_code_part
}

// site_declaration_code_span writes a code span that may name a declaration
// or be a fragment of Odin, and tells whether it wrote it. A span of one
// name is resolved and counted; a fragment of Odin is colored, each name of
// the index in it a link; any other span is left to the caller.
site_declaration_code_span :: proc(site: ^Site, b: ^strings.Builder, from_page, place, code: string, context_folders: []string) -> bool {
	if site == nil {
		return false
	}
	span, is_name := build.declaration_span_read(code)
	// "header.size" is a field of a value, not a name after its package:
	// it is not counted, and it is colored as a fragment of code. With no
	// index (a test of the renderer alone) no name is resolved.
	if is_name && (len(site.declarations.declarations) == 0 || (span.qualifier != "" && span.qualifier not_in site.declarations.packages)) {
		is_name = false
	}
	if is_name {
		found, resolution := build.declaration_resolve(&site.declarations, span, context_folders)
		site_declaration_count(site, resolution, place, code)
		if resolution != .Linked {
			return false
		}
		site_declaration_reference(site, b, from_page, code, found)
		return true
	}
	if !site_code_span_is_odin(code) {
		return false
	}
	links := Site_Code_Links{site = site, from_page = from_page, context_folders = context_folders}
	strings.write_string(b, "<code class=\"code-inline\">")
	if !site_code_odin(site, b, code, "", &links) {
		foundation.html_escape(b, code)
	}
	strings.write_string(b, "</code>")
	return true
}

// site_declaration_cards_html gives the cards of the declarations that the
// text of a page links to: one for each declaration, in the order of the
// first link to it, at the end of the text, as the type cards.
site_declaration_cards_html :: proc(site: ^Site, from_page, body: string) -> string {
	seen := make(map[string]bool, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for id in site_attribute_values(body, "data-declaration-card=\"") {
		if id in seen || !strings.has_prefix(id, SITE_DECLARATION_CARD_PREFIX) {
			continue
		}
		seen[id] = true
		place := foundation.decimal_digits_value(id[len(SITE_DECLARATION_CARD_PREFIX):])
		if place < 0 || place >= len(site.declarations.declarations) {
			continue // The check of the page names it.
		}
		if strings.builder_len(b) == 0 {
			strings.write_string(&b, "<div class=\"declaration-cards\">\n")
		}
		site_declaration_card_write(site, &b, from_page, place)
	}
	if strings.builder_len(b) > 0 {
		strings.write_string(&b, "</div>\n")
	}
	return strings.to_string(b)
}

// site_declaration_card_write writes the card of a declaration: its name
// as the link to it, its kind and its package, its one line colored, the
// first sentence of its comment, and its file and line.
site_declaration_card_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string, place: int) {
	declaration := site.declarations.declarations[place]
	id := site_declaration_card_id(place)
	address := site_declaration_address(site, from_page, declaration)
	fmt.sbprintf(b, "<div class=\"declaration-card\" id=\"%s\" popover>\n<p class=\"declaration-card-title\"><a href=\"", id)
	foundation.html_escape(b, address)
	strings.write_string(b, "\">")
	site_value(b, site_declaration_value_kinds[declaration.kind], declaration.name, true)
	strings.write_string(b, "</a> <span class=\"declaration-card-kind\">")
	foundation.html_escape(b, fmt.tprintf("%s of the package %s", build.declaration_kind_names[declaration.kind], declaration.package_name))
	strings.write_string(b, "</span></p>\n<pre class=\"declaration-card-signature\"><code>")
	if !site_code_odin(site, b, declaration.signature, "", nil) {
		foundation.html_escape(b, declaration.signature)
	}
	fmt.sbprintf(b, "</code></pre>\n<p class=\"declaration-card-summary\" id=\"%s%s\">", id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
	if declaration.first_sentence != "" {
		foundation.html_escape(b, site_source_comment_plain(site, declaration.first_sentence))
		strings.write_byte(b, '.')
	} else {
		foundation.html_escape(b, fmt.tprintf("A %s with no comment in its source.", build.declaration_kind_names[declaration.kind]))
	}
	strings.write_string(b, "</p>\n<p class=\"declaration-card-place\"><a href=\"")
	foundation.html_escape(b, fmt.tprintf("%s#L%d", site_repository_file(site, declaration.file), declaration.line))
	strings.write_string(b, "\">")
	foundation.html_escape(b, fmt.tprintf("%s:%d", declaration.file, declaration.line))
	strings.write_string(b, "</a></p>\n</div>\n")
}
