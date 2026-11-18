// The check of the reuse list of the properties (docs/TOOLS.md, "The reuse
// list"; src/md/infrastructure/reuse_list.md).
//
// The list is written by hand, so that it says what was decided. The tool
// derives the same works from the records that the build and the site
// already read, and refuses each difference: a list that nothing compares
// with the code becomes false in silence.
package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"
import "modustool:resources"

REUSE_LIST_DOCUMENT :: SITE_PROPERTIES_FILE
REUSE_LIST_HEADING :: "## Reuse list"
REUSE_LIST_HEADER_ROW :: "| Work | Place | License | License file |"
REUSE_LIST_COLUMN_COUNT :: 4
// The SPDX value of a work with no license.
REUSE_LICENSE_NONE :: "NONE"
// The words of a record that grants no license at all.
REUSE_NO_LICENSE_WORDS :: "All rights reserved"
// The runtime of the compiler: the compiler puts it in each module and in
// the boot program with no import, so no scan of the imports finds it.
REUSE_COMPILER_RUNTIME :: "base:runtime"
// The start of the import path of a package of the core library of the
// compiler.
REUSE_CORE_LIBRARY_START :: "core:"
// The fallback font is compiled into the graphics package from this file.
REUSE_SPLEEN_FONT_DATA :: foundation.SOURCE_FOLDER_SUPPORT + "/graphics/font.odin"
REUSE_FIAT_FOLDER :: foundation.CRYPTOGRAPHY_FOLDER + "/_fiat"
// The build tag of a file that only the host compiles.
REUSE_HOST_ONLY_TAG :: "!freestanding"

// A work of others that the system ships or copies, as the records of the
// repository give it.
Reused_Work :: struct {
	what:         string, // For the messages only.
	place:        string, // The key of the match: a path of the repository, or an import path.
	license:      string, // The SPDX identifier that the record gives; "" when the record gives none.
	license_file: string, // The license file that the record names; "" when it names none.
}

// One row of the table of the list.
Reuse_Row :: struct {
	line:         int, // In the document, from 1.
	work:         string,
	place:        string,
	license:      string,
	license_file: string,
}

// reuse_spdx_of_record_words gives the SPDX identifier that the words of a
// record name, or "" when the words name none that the site translates.
reuse_spdx_of_record_words :: proc(words: string) -> string {
	for pair in site_spdx_names {
		if strings.has_prefix(words, pair[0]) {
			return pair[1]
		}
	}
	if strings.has_prefix(words, REUSE_NO_LICENSE_WORDS) {
		return REUSE_LICENSE_NONE
	}
	return ""
}

// reuse_license_is_spdx_expression tells whether a cell is an SPDX
// identifier, or identifiers joined by OR and AND. Words such as "SIL OFL
// 1.1" are refused: a reader must find the license by its identifier.
reuse_license_is_spdx_expression :: proc(cell: string) -> bool {
	words := strings.split(cell, " ", context.temp_allocator)
	if len(words) % 2 == 0 {
		return false
	}
	for word, index in words {
		if index % 2 == 1 {
			if word != "OR" && word != "AND" {
				return false
			}
			continue
		}
		if word == "" || word == "OR" || word == "AND" {
			return false
		}
		for character in transmute([]u8)word {
			if !is_name_byte(character) && character != '.' && character != '-' && character != '+' {
				return false
			}
		}
	}
	return true
}

// reuse_code_span gives the text of a cell that is one code span.
reuse_code_span :: proc(cell: string) -> (text: string, found: bool) {
	if len(cell) < 3 || cell[0] != '`' || cell[len(cell) - 1] != '`' || strings.contains(cell[1:len(cell) - 1], "`") {
		return "", false
	}
	return cell[1:len(cell) - 1], true
}

// reuse_list_rows_parse reads the table of the section "Reuse list": the
// lines that start with "|" between its heading and the next heading of
// level 2. The first two are the header and its separator.
reuse_list_rows_parse :: proc(document: string, problems: ^[dynamic]string) -> []Reuse_Row {
	rows := make([dynamic]Reuse_Row, context.temp_allocator)
	in_section := false
	found_section := false
	table_line := 0
	for line, index in foundation.site_lines(document) {
		number := index + 1
		if strings.has_prefix(line, "## ") {
			in_section = line == REUSE_LIST_HEADING
			found_section ||= in_section
			continue
		}
		if !in_section || !strings.has_prefix(line, "|") {
			continue
		}
		table_line += 1
		switch table_line {
		case 1:
			if line != REUSE_LIST_HEADER_ROW {
				append(problems, fmt.tprintf("%s:%d: the header of the reuse list must be %q", REUSE_LIST_DOCUMENT, number, REUSE_LIST_HEADER_ROW))
			}
			continue
		case 2:
			continue
		}
		inner := strings.trim_suffix(strings.trim_prefix(strings.trim_space(line), "| "), " |")
		cells := strings.split(inner, " | ", context.temp_allocator)
		if len(cells) != REUSE_LIST_COLUMN_COUNT {
			append(problems, fmt.tprintf("%s:%d: a row of the reuse list has %d cells, not %d", REUSE_LIST_DOCUMENT, number, len(cells), REUSE_LIST_COLUMN_COUNT))
			continue
		}
		row := Reuse_Row {
			line    = number,
			work    = strings.trim_space(cells[0]),
			license = strings.trim_space(cells[2]),
		}
		place, place_found := reuse_code_span(strings.trim_space(cells[1]))
		license_file, file_found := reuse_code_span(strings.trim_space(cells[3]))
		row.place = place
		row.license_file = license_file
		switch {
		case row.work == "":
			append(problems, fmt.tprintf("%s:%d: a row of the reuse list names no work", REUSE_LIST_DOCUMENT, number))
		case !place_found:
			append(problems, fmt.tprintf("%s:%d: the place of a row of the reuse list is one code span: a path of the repository or an import path", REUSE_LIST_DOCUMENT, number))
		case !file_found:
			append(problems, fmt.tprintf("%s:%d: the license file of a row of the reuse list is one code span: a path of the repository", REUSE_LIST_DOCUMENT, number))
		case !reuse_license_is_spdx_expression(row.license):
			append(problems, fmt.tprintf("%s:%d: the license %q is not an SPDX identifier, or identifiers joined by OR and AND (%s for a work with no license)", REUSE_LIST_DOCUMENT, number, row.license, REUSE_LICENSE_NONE))
		case:
			append(&rows, row)
		}
	}
	if !found_section {
		append(problems, fmt.tprintf("%s: no section %q", REUSE_LIST_DOCUMENT, REUSE_LIST_HEADING))
	}
	return rows[:]
}

// reuse_list_problems compares the list of a document with the works that
// the repository records. file_exists answers for a path of the repository.
reuse_list_problems :: proc(document: string, works: []Reused_Work, file_exists: proc(path: string) -> bool) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	rows := reuse_list_rows_parse(document, &problems)
	row_of_place := make(map[string]int, context.temp_allocator)
	for row, row_index in rows {
		if earlier, seen := row_of_place[row.place]; seen {
			append(&problems, fmt.tprintf("%s:%d: the reuse list names `%s` a second time (line %d)", REUSE_LIST_DOCUMENT, row.line, row.place, rows[earlier].line))
			continue
		}
		row_of_place[row.place] = row_index
		work_index := -1
		for work, index in works {
			if work.place == row.place {
				work_index = index
				break
			}
		}
		if work_index < 0 {
			append(&problems, fmt.tprintf("%s:%d: the reuse list names `%s`, which the system does not ship and the repository does not hold: remove the row, or correct its place", REUSE_LIST_DOCUMENT, row.line, row.place))
		} else {
			work := works[work_index]
			if work.license != "" && row.license != work.license {
				append(&problems, fmt.tprintf("%s:%d: the reuse list gives `%s` the license %s; its record says %s", REUSE_LIST_DOCUMENT, row.line, row.place, row.license, work.license))
			}
			if work.license_file != "" && row.license_file != work.license_file {
				append(&problems, fmt.tprintf("%s:%d: the reuse list gives `%s` the license file `%s`; its record names `%s`", REUSE_LIST_DOCUMENT, row.line, row.place, row.license_file, work.license_file))
			}
		}
		if !file_exists(row.license_file) {
			append(&problems, fmt.tprintf("%s:%d: the license file `%s` of `%s` does not exist", REUSE_LIST_DOCUMENT, row.line, row.license_file, row.place))
		}
	}
	for work in works {
		if _, named := row_of_place[work.place]; !named {
			append(&problems, fmt.tprintf("%s: %s (`%s`) is shipped or copied by the system, and the reuse list has no row for it", REUSE_LIST_DOCUMENT, work.what, work.place))
		}
	}
	return problems[:]
}

reuse_file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// reuse_source_is_host_only tells whether the first line of a source is a
// build tag that leaves it out of every module.
reuse_source_is_host_only :: proc(source: string) -> bool {
	end := strings.index_byte(source, '\n')
	first := end < 0 ? source : source[:end]
	return strings.has_prefix(first, "#+build") && strings.contains(first, REUSE_HOST_ONLY_TAG)
}

// reuse_core_imports_of_source appends each package of the core library
// that one source imports, once.
reuse_core_imports_of_source :: proc(source: string, imports: ^[dynamic]string) {
	for line in foundation.site_lines(source) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "import ") {
			continue
		}
		path, _, found := foundation.site_quoted(trimmed)
		if !found || !strings.has_prefix(path, REUSE_CORE_LIBRARY_START) {
			continue
		}
		known := false
		for earlier in imports {
			known ||= earlier == path
		}
		if !known {
			append(imports, path)
		}
	}
}

// reuse_works_read derives the reused works from the records of the
// repository. Each record that is missing or out of its form is a problem.
reuse_works_read :: proc(problems: ^[dynamic]string) -> []Reused_Work {
	works := make([dynamic]Reused_Work, context.temp_allocator)
	missing :: proc(problems: ^[dynamic]string, path, what: string) {
		append(problems, fmt.tprintf("%s: cannot read the record of %s", path, what))
	}

	// The license of the repository: a pointer theme under it is a work of
	// the system, not of others.
	repository_license := ""
	if text, ok := foundation.site_read_quiet(resources.SITE_LICENSE_FILE); ok {
		repository_license = reuse_spdx_of_record_words(strings.trim_space(foundation.site_lines(text)[0]))
	} else {
		missing(problems, resources.SITE_LICENSE_FILE, "the license of the repository")
	}

	// The fonts that the repository holds as subsets.
	font_lists := [?][]resources.Vector_Font_Candidate{resources.vector_font_candidates[:], resources.vector_font_emphasis[:], resources.vector_font_interface[:]}
	for list in font_lists {
		for candidate in list {
			record := foundation.join(SITE_FONT_FOLDER, "/", candidate.name, ".license")
			text, ok := foundation.site_read_quiet(record)
			if !ok {
				missing(problems, record, candidate.family)
				continue
			}
			font, font_problem := site_font_license_parse(record, text)
			if font_problem != "" {
				append(problems, font_problem)
				continue
			}
			append(&works, Reused_Work {
				what         = font.family,
				place        = foundation.join(SITE_FONT_FOLDER, "/", candidate.name, ".ttf"),
				license      = reuse_spdx_of_record_words(font.license),
				license_file = foundation.join(SITE_FONT_FOLDER, "/", candidate.license_file),
			})
		}
	}

	// Spleen, the fallback font.
	if text, ok := foundation.site_read_quiet(resources.SITE_SPLEEN_LICENSE_FILE); ok {
		append(&works, Reused_Work {
			what         = "Spleen 8x16",
			place        = REUSE_SPLEEN_FONT_DATA,
			license      = site_line_after(text, SPDX_IDENTIFIER_LINE_START),
			license_file = resources.SITE_SPLEEN_LICENSE_FILE,
		})
	} else {
		missing(problems, resources.SITE_SPLEEN_LICENSE_FILE, "Spleen 8x16")
	}

	// Each pointer theme that the build makes and that is not under the
	// license of the repository. Its manifest is its notice.
	for theme in resources.pointer_theme_builds {
		text, ok := foundation.site_read_quiet(theme.manifest)
		if !ok {
			missing(problems, theme.manifest, "a pointer theme")
			continue
		}
		manifest, manifest_problem := site_pointer_manifest_parse(theme.manifest, text)
		if manifest_problem != "" {
			append(problems, manifest_problem)
			continue
		}
		if manifest.license == repository_license {
			continue
		}
		append(&works, Reused_Work {
			what         = foundation.join("the pointer theme \"", manifest.theme, "\""),
			place        = theme.manifest,
			license      = manifest.license,
			license_file = theme.manifest,
		})
	}

	// The cryptography taken from Odin, with the field arithmetic of
	// fiat-crypto, and the libraries of the compiler: one license file of
	// Odin covers all of them.
	odin_license := ""
	if text, ok := foundation.site_read_quiet(SITE_ODIN_LICENSE_FILE); ok {
		odin_license = strings.contains(text, "(zlib)") ? "Zlib" : ""
	} else {
		missing(problems, SITE_ODIN_LICENSE_FILE, "the code of Odin")
	}
	if text, ok := foundation.site_read_quiet(foundation.CRYPTOGRAPHY_MANIFEST); ok {
		taken := 0
		fiat_taken := false
		for line in foundation.site_lines(text) {
			if strings.trim_space(line) == "" || strings.has_prefix(line, "#") {
				continue
			}
			taken += 1
			fiat_taken ||= strings.has_prefix(line, REUSE_FIAT_FOLDER + "/")
		}
		if taken > 0 {
			append(&works, Reused_Work{what = "the cryptography of Odin's core:crypto", place = foundation.CRYPTOGRAPHY_FOLDER, license = odin_license, license_file = SITE_ODIN_LICENSE_FILE})
		}
		if fiat_taken {
			fiat_license := ""
			if fiat_text, fiat_ok := foundation.site_read_quiet(SITE_FIAT_LICENSE_FILE); fiat_ok {
				fiat_license = strings.contains(fiat_text, "(BSD-1-Clause)") ? "BSD-1-Clause" : ""
			}
			append(&works, Reused_Work{what = "the field arithmetic of fiat-crypto", place = REUSE_FIAT_FOLDER, license = fiat_license, license_file = SITE_FIAT_LICENSE_FILE})
		}
	} else {
		missing(problems, foundation.CRYPTOGRAPHY_MANIFEST, "the cryptography of Odin")
	}
	append(&works, Reused_Work{what = "the runtime of the Odin compiler", place = REUSE_COMPILER_RUNTIME, license = odin_license, license_file = SITE_ODIN_LICENSE_FILE})
	files := make([dynamic]string, context.temp_allocator)
	folders := ALLOCATOR_CHECKED_FOLDERS
	for folder in folders {
		if !foundation.source_files_of_a_folder(folder, &files) {
			append(problems, fmt.tprintf("%s: cannot list the sources of the system", folder))
		}
	}
	core_imports := make([dynamic]string, context.temp_allocator)
	for file in files {
		if source_is_a_test(file) {
			continue
		}
		source, ok := foundation.site_read_quiet(file)
		if !ok {
			append(problems, fmt.tprintf("%s: cannot read", file))
			continue
		}
		if !reuse_source_is_host_only(source) {
			reuse_core_imports_of_source(source, &core_imports)
		}
	}
	for path in core_imports {
		append(&works, Reused_Work{what = foundation.join("the package ", path, " of the Odin compiler"), place = path, license = odin_license, license_file = SITE_ODIN_LICENSE_FILE})
	}

	// The portraits of the module hall_of_fame.
	credits, credits_problem := resources.hall_of_fame_credits_read()
	if credits_problem != "" {
		append(problems, credits_problem)
	}
	for credit in credits {
		append(&works, Reused_Work {
			what         = foundation.join("the portrait of ", credit.person),
			place        = foundation.join(resources.HALL_OF_FAME_RESOURCE_FOLDER, "/", credit.file),
			license      = reuse_spdx_of_record_words(credit.license),
			license_file = resources.HALL_OF_FAME_CREDITS_FILE,
		})
	}
	return works[:]
}

// reuse_list_check holds the reuse list of the properties against the
// repository.
reuse_list_check :: proc() -> bool {
	problems := make([dynamic]string, context.temp_allocator)
	works := reuse_works_read(&problems)
	if document, ok := foundation.site_read_quiet(REUSE_LIST_DOCUMENT); ok {
		append(&problems, ..reuse_list_problems(document, works, reuse_file_exists))
	} else {
		append(&problems, fmt.tprintf("%s: cannot read", REUSE_LIST_DOCUMENT))
	}
	if len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("modustool: test failed: the reuse list has %d problems", len(problems))
		return false
	}
	foundation.test_passed_print("the reuse list of %s names the %d works of others that the system ships or copies, each with the license of its record and a license file that exists", REUSE_LIST_DOCUMENT, len(works))
	return true
}
