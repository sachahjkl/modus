package resources

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The tables of the written shaper (src/md/features/written_shaping.md),
// generated from the Unicode Character Database that UNICODE_DATA_SOURCE
// names: the bidirectional class of each character, the marks, the
// combining classes, the joining types of Arabic, the mirrored pairs and
// the primary compositions. The command "unicode_tables" writes them into
// UNICODE_TABLES_OUTPUT, which is in the repository: a build does not need
// the database. Run it to change the version of Unicode.

UNICODE_DATA_SOURCE_VARIABLE :: "UNICODE_DATA_SOURCE"
UNICODE_TABLES_OUTPUT :: foundation.SOURCE_FOLDER_PUBLIC + "/text_rendering/unicode_tables.odin"

// One line of a file of the database: a range of characters and its fields.
@(private = "file")
Unicode_Line :: struct {
	first, last: rune,
	fields:      []string,
}

// unicode_lines_read reads a file of the database: each line that is not a
// comment, its range (one code point or first..last) and its fields after
// the first, trimmed, with the comment cut.
@(private = "file")
unicode_lines_read :: proc(folder, name: string) -> (lines: [dynamic]Unicode_Line, version: string, ok: bool) {
	path := foundation.join(folder, "/", name)
	bytes, error := os.read_entire_file(path, context.temp_allocator)
	if error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", path, error)
		return nil, "", false
	}
	lines = make([dynamic]Unicode_Line, context.temp_allocator)
	text := string(bytes)
	first_line := true
	for line in strings.split_lines_iterator(&text) {
		if first_line {
			first_line = false
			// "# DerivedBidiClass-17.0.0.txt": the version after the last "-".
			if dash := strings.last_index_byte(line, '-'); dash >= 0 && strings.has_suffix(line, ".txt") {
				version = line[dash + 1:len(line) - 4]
			}
		}
		content := line
		if hash := strings.index_byte(content, '#'); hash >= 0 {
			content = content[:hash]
		}
		if strings.trim_space(content) == "" {
			continue
		}
		fields := strings.split(content, ";", context.temp_allocator)
		for &field in fields {
			field = strings.trim_space(field)
		}
		range := fields[0]
		first_text, last_text := range, range
		if dots := strings.index(range, ".."); dots >= 0 {
			first_text, last_text = range[:dots], range[dots + 2:]
		}
		first, first_ok := strconv.parse_int(first_text, 16)
		last, last_ok := strconv.parse_int(last_text, 16)
		if !first_ok || !last_ok || last < first {
			fmt.eprintfln("modustool: %s: the range %q does not read", path, range)
			return nil, "", false
		}
		append(&lines, Unicode_Line{rune(first), rune(last), fields[1:]})
	}
	return lines, version, true
}

// A run of characters with one value, for a table of ranges.
@(private = "file")
Value_Range :: struct {
	first, last: rune,
	value:       string,
}

// ranges_merge sorts the ranges and joins two that touch and have one value.
@(private = "file")
ranges_merge :: proc(ranges: [dynamic]Value_Range) -> []Value_Range {
	slice.sort_by(ranges[:], proc(a, b: Value_Range) -> bool {return a.first < b.first})
	merged := make([dynamic]Value_Range, context.temp_allocator)
	for range in ranges {
		if count := len(merged); count > 0 && merged[count - 1].last + 1 == range.first && merged[count - 1].value == range.value {
			merged[count - 1].last = range.last
			continue
		}
		append(&merged, range)
	}
	return merged[:]
}

@(private = "file")
ranges_write :: proc(out: ^strings.Builder, comment, name, type: string, ranges: []Value_Range, value_prefix: string) {
	fmt.sbprintfln(out, "\n// %s: %d ranges.", comment, len(ranges))
	fmt.sbprintfln(out, "@(rodata)\n%s := [?]%s {{", name, type)
	for range in ranges {
		fmt.sbprintfln(out, "\t{{0x%04X, 0x%04X, %s%s}},", int(range.first), int(range.last), value_prefix, range.value)
	}
	fmt.sbprintln(out, "}")
}

run_unicode_tables :: proc(args: []string) -> int {
	folder := os.get_env(UNICODE_DATA_SOURCE_VARIABLE, context.temp_allocator)
	if folder == "" {
		fmt.eprintln("modustool: " + UNICODE_DATA_SOURCE_VARIABLE + " is not set. Use the development shell: nix develop")
		return foundation.EXIT_FAILURE
	}
	bidi_lines, version, bidi_ok := unicode_lines_read(folder, "extracted/DerivedBidiClass.txt")
	category_lines, _, category_ok := unicode_lines_read(folder, "extracted/DerivedGeneralCategory.txt")
	class_lines, _, class_ok := unicode_lines_read(folder, "extracted/DerivedCombiningClass.txt")
	joining_lines, _, joining_ok := unicode_lines_read(folder, "extracted/DerivedJoiningType.txt")
	mirror_lines, _, mirror_ok := unicode_lines_read(folder, "BidiMirroring.txt")
	data_lines, _, data_ok := unicode_lines_read(folder, "UnicodeData.txt")
	exclusion_lines, _, exclusion_ok := unicode_lines_read(folder, "DerivedNormalizationProps.txt")
	if !bidi_ok || !category_ok || !class_ok || !joining_ok || !mirror_ok || !data_ok || !exclusion_ok {
		return foundation.EXIT_FAILURE
	}
	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&out, "// The tables of the written shaper (src/md/features/written_shaping.md),")
	fmt.sbprintfln(&out, "// written by \"modustool unicode_tables\" from the Unicode Character")
	fmt.sbprintfln(&out, "// Database %s. Do not edit: change the generator, then run it again.", version)
	fmt.sbprintln(&out, "package text_rendering")
	fmt.sbprintfln(&out, "\nUNICODE_VERSION :: %q", version)

	bidi := make([dynamic]Value_Range, context.temp_allocator)
	for line in bidi_lines {
		if line.fields[0] != "L" { // L is the class of each character out of the table.
			append(&bidi, Value_Range{line.first, line.last, line.fields[0]})
		}
	}
	ranges_write(&out, "The bidirectional class of each character that is not L (DerivedBidiClass.txt)", "bidi_class_ranges", "Bidi_Range", ranges_merge(bidi), ".")

	marks := make([dynamic]Value_Range, context.temp_allocator)
	for line in category_lines {
		if line.fields[0] == "Mn" || line.fields[0] == "Me" {
			append(&marks, Value_Range{line.first, line.last, "true"})
		}
	}
	merged_marks := ranges_merge(marks)
	fmt.sbprintfln(&out, "\n// The marks: the general categories Mn and Me (DerivedGeneralCategory.txt): %d ranges.", len(merged_marks))
	fmt.sbprintln(&out, "@(rodata)\nmark_ranges := [?]Character_Range {")
	for range in merged_marks {
		fmt.sbprintfln(&out, "\t{{0x%04X, 0x%04X}},", int(range.first), int(range.last))
	}
	fmt.sbprintln(&out, "}")

	classes := make([dynamic]Value_Range, context.temp_allocator)
	for line in class_lines {
		if line.fields[0] != "0" {
			append(&classes, Value_Range{line.first, line.last, line.fields[0]})
		}
	}
	ranges_write(&out, "The canonical combining class of each character whose class is not 0 (DerivedCombiningClass.txt)", "combining_class_ranges", "Class_Range", ranges_merge(classes), "")

	joining := make([dynamic]Value_Range, context.temp_allocator)
	for line in joining_lines {
		value: string
		switch line.fields[0] {
		case "R":
			value = "Right"
		case "D":
			value = "Dual"
		case "L":
			value = "Left"
		case "C":
			value = "Join_Causing"
		case "T":
			// The marks, and the format characters that draw nothing
			// (U+200B, U+200E, U+2060): a letter joins through them.
			value = "Transparent"
		case:
			continue // U joins nothing.
		}
		append(&joining, Value_Range{line.first, line.last, value})
	}
	ranges_write(&out, "The joining type of each character that joins (DerivedJoiningType.txt)", "joining_ranges", "Joining_Range", ranges_merge(joining), ".")

	fmt.sbprintfln(&out, "\n// The mirrored form of each character (BidiMirroring.txt): %d pairs, by the first.", len(mirror_lines))
	fmt.sbprintln(&out, "@(rodata)\nmirror_pairs := [?][2]rune {")
	for line in mirror_lines {
		mirror, _ := strconv.parse_int(line.fields[0], 16)
		fmt.sbprintfln(&out, "\t{{0x%04X, 0x%04X}},", int(line.first), mirror)
	}
	fmt.sbprintln(&out, "}")

	// The primary compositions: a canonical decomposition of two characters,
	// with no tag, of a character that the full composition exclusion does
	// not name.
	excluded := make(map[rune]bool, 2048, context.temp_allocator)
	for line in exclusion_lines {
		if line.fields[0] == "Full_Composition_Exclusion" {
			for character in line.first ..= line.last {
				excluded[character] = true
			}
		}
	}
	Composition_Line :: struct {
		first, second, composed: rune,
	}
	compositions := make([dynamic]Composition_Line, context.temp_allocator)
	for line in data_lines {
		if len(line.fields) < 5 || line.fields[4] == "" || strings.has_prefix(line.fields[4], "<") || excluded[line.first] {
			continue
		}
		parts := strings.fields(line.fields[4], context.temp_allocator)
		if len(parts) != 2 {
			continue
		}
		first, _ := strconv.parse_int(parts[0], 16)
		second, _ := strconv.parse_int(parts[1], 16)
		append(&compositions, Composition_Line{rune(first), rune(second), line.first})
	}
	slice.sort_by(compositions[:], proc(a, b: Composition_Line) -> bool {
		return a.first < b.first || a.first == b.first && a.second < b.second
	})
	fmt.sbprintfln(&out, "\n// The primary compositions (UnicodeData.txt, DerivedNormalizationProps.txt): %d, by the first character, then the second.", len(compositions))
	fmt.sbprintln(&out, "@(rodata)\ncompositions := [?]Composition {")
	for composition in compositions {
		fmt.sbprintfln(&out, "\t{{0x%04X, 0x%04X, 0x%04X}},", int(composition.first), int(composition.second), int(composition.composed))
	}
	fmt.sbprintln(&out, "}")
	// The presentation forms of Arabic: the compatibility decompositions
	// <isolated>, <final>, <initial> and <medial> of one letter, and those of
	// lam with an alef (src/md/features/written_shaping.md).
	Arabic_Form_Line :: struct {
		character: rune,
		forms:     [4]rune, // isolated, final, initial, medial; 0: none.
	}
	Lam_Alef_Line :: struct {
		alef:            rune,
		isolated, final: rune,
	}
	form_tags := [4]string{"<isolated>", "<final>", "<initial>", "<medial>"}
	arabic_forms := make(map[rune][4]rune, 256, context.temp_allocator)
	lam_alefs := make(map[rune][2]rune, 8, context.temp_allocator)
	for line in data_lines {
		if len(line.fields) < 5 {
			continue
		}
		parts := strings.fields(line.fields[4], context.temp_allocator)
		if len(parts) < 2 {
			continue
		}
		for tag, form in form_tags {
			if parts[0] != tag {
				continue
			}
			first, _ := strconv.parse_int(parts[1], 16)
			switch len(parts) {
			case 2:
				forms := arabic_forms[rune(first)]
				if forms[form] == 0 {
					forms[form] = line.first
				}
				arabic_forms[rune(first)] = forms
			case 3:
				second, _ := strconv.parse_int(parts[2], 16)
				if first == 0x0644 && form < 2 && (second == 0x0622 || second == 0x0623 || second == 0x0625 || second == 0x0627) {
					pair := lam_alefs[rune(second)]
					pair[form] = line.first
					lam_alefs[rune(second)] = pair
				}
			}
		}
	}
	forms_sorted := make([dynamic]Arabic_Form_Line, context.temp_allocator)
	for character, forms in arabic_forms {
		if character >= 0x0600 && character <= 0x08FF {
			append(&forms_sorted, Arabic_Form_Line{character, forms})
		}
	}
	slice.sort_by(forms_sorted[:], proc(a, b: Arabic_Form_Line) -> bool {return a.character < b.character})
	fmt.sbprintfln(&out, "\n// The presentation forms of each letter of Arabic (UnicodeData.txt): isolated, final, initial, medial; 0 for a form that Unicode does not name. %d letters, by the letter.", len(forms_sorted))
	fmt.sbprintln(&out, "@(rodata)\narabic_forms := [?]Arabic_Forms {")
	for line in forms_sorted {
		fmt.sbprintfln(&out, "\t{{0x%04X, {{0x%04X, 0x%04X, 0x%04X, 0x%04X}}}},", int(line.character), int(line.forms[0]), int(line.forms[1]), int(line.forms[2]), int(line.forms[3]))
	}
	fmt.sbprintln(&out, "}")
	alefs_sorted := make([dynamic]Lam_Alef_Line, context.temp_allocator)
	for alef, pair in lam_alefs {
		append(&alefs_sorted, Lam_Alef_Line{alef, pair[0], pair[1]})
	}
	slice.sort_by(alefs_sorted[:], proc(a, b: Lam_Alef_Line) -> bool {return a.alef < b.alef})
	fmt.sbprintfln(&out, "\n// The ligature of lam with an alef (UnicodeData.txt): the alef, the isolated and the final form. %d, by the alef.", len(alefs_sorted))
	fmt.sbprintln(&out, "@(rodata)\nlam_alef_forms := [?]Lam_Alef {")
	for line in alefs_sorted {
		fmt.sbprintfln(&out, "\t{{0x%04X, 0x%04X, 0x%04X}},", int(line.alef), int(line.isolated), int(line.final))
	}
	fmt.sbprintln(&out, "}")
	// The categories of the scripts of India (IndicSyllabicCategory.txt and
	// IndicPositionalCategory.txt), for the blocks of those scripts and the
	// joiners and the dotted circle that a syllable holds
	// (src/md/features/written_shaping.md, "Devanagari").
	indic_in_scope :: proc(line: Unicode_Line) -> bool {
		return line.first >= 0x0900 && line.last <= 0x0DFF || line.first == 0x200C || line.first == 0x200D || line.first == 0x25CC
	}
	for table in ([2]struct {
			file, comment, name, type: string,
		}{{"IndicSyllabicCategory.txt", "The syllabic category of each character of the scripts of India that has one (IndicSyllabicCategory.txt)", "indic_syllabic_ranges", "Indic_Syllabic_Range"}, {"IndicPositionalCategory.txt", "The position of each mark of the scripts of India (IndicPositionalCategory.txt)", "indic_position_ranges", "Indic_Position_Range"}}) {
		lines, _, read := unicode_lines_read(folder, table.file)
		if !read {
			return foundation.EXIT_FAILURE
		}
		ranges := make([dynamic]Value_Range, context.temp_allocator)
		for line in lines {
			if indic_in_scope(line) && line.fields[0] != "Other" && line.fields[0] != "NA" {
				append(&ranges, Value_Range{line.first, line.last, line.fields[0]})
			}
		}
		ranges_write(&out, table.comment, table.name, table.type, ranges_merge(ranges), ".")
	}
	// The paired brackets (BidiBrackets.txt), for the rule N0 of UAX #9.
	bracket_lines, _, brackets_read := unicode_lines_read(folder, "BidiBrackets.txt")
	if !brackets_read {
		return foundation.EXIT_FAILURE
	}
	fmt.sbprintln(&out, "\n// The paired brackets (BidiBrackets.txt): each bracket, its pair, and if it opens; by the bracket.")
	fmt.sbprintln(&out, "@(rodata)\nbracket_pairs := [?]Bracket_Pair {")
	for line in bracket_lines {
		if len(line.fields) < 2 {
			continue
		}
		pair, _ := strconv.parse_int(line.fields[0], 16)
		fmt.sbprintfln(&out, "\t{{0x%04X, 0x%04X, %v}},", int(line.first), pair, line.fields[1] == "o")
	}
	fmt.sbprintln(&out, "}")
	// The canonical decompositions of two characters in the blocks of the
	// scripts of India: the vowel signs of two parts (ো is ে and া) and the
	// letters with a nukta. The shaper decides which to apply
	// (text_rendering.indic_decomposition_of).
	fmt.sbprintln(&out, "\n// The canonical decompositions of two characters of the scripts of India (UnicodeData.txt), by the character.")
	fmt.sbprintln(&out, "@(rodata)\nindic_decompositions := [?]Indic_Decomposition {")
	for line in data_lines {
		if line.first < 0x0900 || line.first > 0x0DFF || len(line.fields) < 5 || line.fields[4] == "" || strings.has_prefix(line.fields[4], "<") {
			continue
		}
		parts := strings.fields(line.fields[4], context.temp_allocator)
		if len(parts) != 2 {
			continue
		}
		first, _ := strconv.parse_int(parts[0], 16)
		second, _ := strconv.parse_int(parts[1], 16)
		fmt.sbprintfln(&out, "\t{{0x%04X, 0x%04X, 0x%04X}},", int(line.first), first, second)
	}
	fmt.sbprintln(&out, "}")
	if err := os.write_entire_file(UNICODE_TABLES_OUTPUT, transmute([]u8)strings.to_string(out)); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", UNICODE_TABLES_OUTPUT, err)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: wrote %s from the Unicode Character Database %s: %d compositions", UNICODE_TABLES_OUTPUT, version, len(compositions))
	return 0
}
