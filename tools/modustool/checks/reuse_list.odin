// The check of docs/CREDITS.md (docs/TOOLS.md, "The reuse list";
// src/md/infrastructure/credits_and_licences.md).
//
// The document is written by hand, so that it says what was decided. The tool
// verifies all three tables (Reused code, Reimplemented algorithms, and
// Inspirations), checks that every path exists in the repository, and compares
// Reused code with the records that the build and the site already read.
package checks

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"
import "modustool:resources"
import "modustool:build"

CREDITS_FILE :: "docs/CREDITS.md"
REUSE_LIST_DOCUMENT :: CREDITS_FILE
REUSE_LIST_HEADING :: "## Reused code"
REUSE_LIST_HEADER_ROW :: "| Work | Place | Upstream | Authors | License | License file | Funding |"
REUSE_LIST_COLUMN_COUNT :: 7

CREDITS_ALGORITHMS_HEADING :: "## Reimplemented algorithms"
CREDITS_ALGORITHMS_HEADER_ROW :: "| Algorithm | Authors | Upstream | Reference license | Place | Funding |"
CREDITS_ALGORITHMS_COLUMN_COUNT :: 6

CREDITS_INSPIRATIONS_HEADING :: "## Inspirations"
CREDITS_INSPIRATIONS_HEADER_ROW :: "| System or idea | Authors | Took and left | Link | Funding |"
CREDITS_INSPIRATIONS_COLUMN_COUNT :: 5
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

// One row of the Reused code table.
Reuse_Row :: struct {
	line:         int, // In the document, from 1.
	work:         string,
	place:        string,
	upstream:     string,
	authors:      string,
	license:      string,
	license_file: string,
	funding:      string,
}

// One row of the Reimplemented algorithms table.
Algorithm_Row :: struct {
	line:              int,
	algorithm:         string,
	authors:           string,
	upstream:          string,
	reference_license: string,
	place:             string,
	funding:           string,
}

// One row of the Inspirations table.
Inspiration_Row :: struct {
	line:          int,
	system:        string,
	authors:       string,
	took_and_left: string,
	link:          string,
	funding:       string,
}

// All three tables parsed from docs/CREDITS.md.
Credits_Document :: struct {
	reused:       []Reuse_Row,
	algorithms:   []Algorithm_Row,
	inspirations: []Inspiration_Row,
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

Credits_Section :: enum {
	None,
	Reused_Code,
	Reimplemented_Algorithms,
	Inspirations,
}

// credits_table_cells splits one Markdown table row into trimmed cells.
credits_table_cells :: proc(line: string) -> []string {
	trimmed := strings.trim_space(line)
	if strings.has_prefix(trimmed, "|") {
		trimmed = trimmed[1:]
	}
	if strings.has_suffix(trimmed, "|") {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	raw := strings.split(trimmed, "|", context.temp_allocator)
	for &cell in raw {
		cell = strings.trim_space(cell)
	}
	return raw
}

// credits_parse reads all three tables of docs/CREDITS.md: Reused code,
// Reimplemented algorithms, and Inspirations.
credits_parse :: proc(document: string, problems: ^[dynamic]string) -> Credits_Document {
	reused := make([dynamic]Reuse_Row, context.temp_allocator)
	algorithms := make([dynamic]Algorithm_Row, context.temp_allocator)
	inspirations := make([dynamic]Inspiration_Row, context.temp_allocator)

	section: Credits_Section = .None
	found_reused := false
	found_algorithms := false
	found_inspirations := false
	table_line := 0

	for line, index in foundation.lines_of_text(document) {
		number := index + 1
		if strings.has_prefix(line, "## ") {
			table_line = 0
			switch line {
			case REUSE_LIST_HEADING:
				section = .Reused_Code
				found_reused = true
			case CREDITS_ALGORITHMS_HEADING:
				section = .Reimplemented_Algorithms
				found_algorithms = true
			case CREDITS_INSPIRATIONS_HEADING:
				section = .Inspirations
				found_inspirations = true
			case:
				section = .None
			}
			continue
		}
		if section == .None || !strings.has_prefix(line, "|") {
			continue
		}
		table_line += 1
		switch section {
		case .None:
			continue
		case .Reused_Code:
			if table_line == 1 {
				if line != REUSE_LIST_HEADER_ROW {
					append(problems, fmt.tprintf("%s:%d: the header of %s must be %q", REUSE_LIST_DOCUMENT, number, REUSE_LIST_HEADING, REUSE_LIST_HEADER_ROW))
				}
				continue
			}
			if table_line == 2 {
				continue
			}
			cells := credits_table_cells(line)
			if len(cells) != REUSE_LIST_COLUMN_COUNT {
				append(problems, fmt.tprintf("%s:%d: a row of Reused code has %d cells, not %d", REUSE_LIST_DOCUMENT, number, len(cells), REUSE_LIST_COLUMN_COUNT))
				continue
			}
			place, place_found := reuse_code_span(cells[1])
			license_file, file_found := reuse_code_span(cells[5])
			row := Reuse_Row {
				line         = number,
				work         = cells[0],
				place        = place,
				upstream     = cells[2],
				authors      = cells[3],
				license      = cells[4],
				license_file = license_file,
				funding      = cells[6],
			}
			switch {
			case row.work == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reused code names no work", REUSE_LIST_DOCUMENT, number))
			case !place_found:
				append(problems, fmt.tprintf("%s:%d: the place of a row of Reused code is one code span: a path of the repository or an import path", REUSE_LIST_DOCUMENT, number))
			case row.upstream == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reused code has an empty Upstream cell", REUSE_LIST_DOCUMENT, number))
			case row.authors == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reused code has an empty Authors cell", REUSE_LIST_DOCUMENT, number))
			case !reuse_license_is_spdx_expression(row.license):
				append(problems, fmt.tprintf("%s:%d: the license %q is not an SPDX identifier, or identifiers joined by OR and AND (%s for a work with no license)", REUSE_LIST_DOCUMENT, number, row.license, build.REUSE_LICENSE_NONE))
			case !file_found:
				append(problems, fmt.tprintf("%s:%d: the license file of a row of Reused code is one code span: a path of the repository", REUSE_LIST_DOCUMENT, number))
			case row.funding == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reused code has an empty Funding cell (use — when none is known)", REUSE_LIST_DOCUMENT, number))
			case:
				append(&reused, row)
			}

		case .Reimplemented_Algorithms:
			if table_line == 1 {
				if line != CREDITS_ALGORITHMS_HEADER_ROW {
					append(problems, fmt.tprintf("%s:%d: the header of %s must be %q", REUSE_LIST_DOCUMENT, number, CREDITS_ALGORITHMS_HEADING, CREDITS_ALGORITHMS_HEADER_ROW))
				}
				continue
			}
			if table_line == 2 {
				continue
			}
			cells := credits_table_cells(line)
			if len(cells) != CREDITS_ALGORITHMS_COLUMN_COUNT {
				append(problems, fmt.tprintf("%s:%d: a row of Reimplemented algorithms has %d cells, not %d", REUSE_LIST_DOCUMENT, number, len(cells), CREDITS_ALGORITHMS_COLUMN_COUNT))
				continue
			}
			place, place_found := reuse_code_span(cells[4])
			row := Algorithm_Row {
				line              = number,
				algorithm         = cells[0],
				authors           = cells[1],
				upstream          = cells[2],
				reference_license = cells[3],
				place             = place,
				funding           = cells[5],
			}
			switch {
			case row.algorithm == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reimplemented algorithms has an empty Algorithm cell", REUSE_LIST_DOCUMENT, number))
			case row.authors == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reimplemented algorithms has an empty Authors cell", REUSE_LIST_DOCUMENT, number))
			case row.upstream == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reimplemented algorithms has an empty Upstream cell", REUSE_LIST_DOCUMENT, number))
			case row.reference_license == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reimplemented algorithms has an empty Reference license cell", REUSE_LIST_DOCUMENT, number))
			case !place_found:
				append(problems, fmt.tprintf("%s:%d: the place of a row of Reimplemented algorithms is one code span: a path in src/", REUSE_LIST_DOCUMENT, number))
			case row.funding == "":
				append(problems, fmt.tprintf("%s:%d: a row of Reimplemented algorithms has an empty Funding cell (use — when none is known)", REUSE_LIST_DOCUMENT, number))
			case:
				append(&algorithms, row)
			}

		case .Inspirations:
			if table_line == 1 {
				if line != CREDITS_INSPIRATIONS_HEADER_ROW {
					append(problems, fmt.tprintf("%s:%d: the header of %s must be %q", REUSE_LIST_DOCUMENT, number, CREDITS_INSPIRATIONS_HEADING, CREDITS_INSPIRATIONS_HEADER_ROW))
				}
				continue
			}
			if table_line == 2 {
				continue
			}
			cells := credits_table_cells(line)
			if len(cells) != CREDITS_INSPIRATIONS_COLUMN_COUNT {
				append(problems, fmt.tprintf("%s:%d: a row of Inspirations has %d cells, not %d", REUSE_LIST_DOCUMENT, number, len(cells), CREDITS_INSPIRATIONS_COLUMN_COUNT))
				continue
			}
			row := Inspiration_Row {
				line          = number,
				system        = cells[0],
				authors       = cells[1],
				took_and_left = cells[2],
				link          = cells[3],
				funding       = cells[4],
			}
			switch {
			case row.system == "":
				append(problems, fmt.tprintf("%s:%d: a row of Inspirations has an empty System or idea cell", REUSE_LIST_DOCUMENT, number))
			case row.authors == "":
				append(problems, fmt.tprintf("%s:%d: a row of Inspirations has an empty Authors cell", REUSE_LIST_DOCUMENT, number))
			case row.took_and_left == "":
				append(problems, fmt.tprintf("%s:%d: a row of Inspirations has an empty Took and left cell", REUSE_LIST_DOCUMENT, number))
			case row.link == "":
				append(problems, fmt.tprintf("%s:%d: a row of Inspirations has an empty Link cell", REUSE_LIST_DOCUMENT, number))
			case row.funding == "":
				append(problems, fmt.tprintf("%s:%d: a row of Inspirations has an empty Funding cell (use — when none is known)", REUSE_LIST_DOCUMENT, number))
			case:
				append(&inspirations, row)
			}
		}
	}
	if !found_reused {
		append(problems, fmt.tprintf("%s: no section %q", REUSE_LIST_DOCUMENT, REUSE_LIST_HEADING))
	}
	if !found_algorithms {
		append(problems, fmt.tprintf("%s: no section %q", REUSE_LIST_DOCUMENT, CREDITS_ALGORITHMS_HEADING))
	}
	if !found_inspirations {
		append(problems, fmt.tprintf("%s: no section %q", REUSE_LIST_DOCUMENT, CREDITS_INSPIRATIONS_HEADING))
	}
	return Credits_Document{reused = reused[:], algorithms = algorithms[:], inspirations = inspirations[:]}
}

// reuse_list_problems checks all three tables of docs/CREDITS.md against
// the works that the repository records and file_exists.
reuse_list_problems :: proc(document: string, works: []Reused_Work, file_exists: proc(path: string) -> bool) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	credits := credits_parse(document, &problems)

	// 1. Reused code.
	row_of_place := make(map[string]int, context.temp_allocator)
	for row, row_index in credits.reused {
		if earlier, seen := row_of_place[row.place]; seen {
			append(&problems, fmt.tprintf("%s:%d: Reused code names `%s` a second time (line %d)", REUSE_LIST_DOCUMENT, row.line, row.place, credits.reused[earlier].line))
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
			append(&problems, fmt.tprintf("%s:%d: Reused code names `%s`, which the system does not ship and the repository does not hold: remove the row, or correct its place", REUSE_LIST_DOCUMENT, row.line, row.place))
		} else {
			work := works[work_index]
			if work.license != "" && row.license != work.license {
				append(&problems, fmt.tprintf("%s:%d: Reused code gives `%s` the license %s; its record says %s", REUSE_LIST_DOCUMENT, row.line, row.place, row.license, work.license))
			}
			if work.license_file != "" && row.license_file != work.license_file {
				append(&problems, fmt.tprintf("%s:%d: Reused code gives `%s` the license file `%s`; its record names `%s`", REUSE_LIST_DOCUMENT, row.line, row.place, row.license_file, work.license_file))
			}
		}
		if !strings.contains_rune(row.place, ':') && !file_exists(row.place) {
			append(&problems, fmt.tprintf("%s:%d: the place `%s` of Reused code does not exist", REUSE_LIST_DOCUMENT, row.line, row.place))
		}
		if !file_exists(row.license_file) {
			append(&problems, fmt.tprintf("%s:%d: the license file `%s` of `%s` does not exist", REUSE_LIST_DOCUMENT, row.line, row.license_file, row.place))
		}
	}
	for work in works {
		if _, named := row_of_place[work.place]; !named {
			append(&problems, fmt.tprintf("%s: %s (`%s`) is shipped or copied by the system, and Reused code has no row for it", REUSE_LIST_DOCUMENT, work.what, work.place))
		}
	}

	// 2. Reimplemented algorithms.
	algo_seen := make(map[string]int, context.temp_allocator)
	for row in credits.algorithms {
		if earlier, seen := algo_seen[row.algorithm]; seen {
			append(&problems, fmt.tprintf("%s:%d: Reimplemented algorithms names %q a second time (line %d)", REUSE_LIST_DOCUMENT, row.line, row.algorithm, earlier))
		} else {
			algo_seen[row.algorithm] = row.line
		}
		if !file_exists(row.place) {
			append(&problems, fmt.tprintf("%s:%d: the place `%s` of Reimplemented algorithms does not exist", REUSE_LIST_DOCUMENT, row.line, row.place))
		}
	}

	// 3. Inspirations.
	insp_seen := make(map[string]int, context.temp_allocator)
	for row in credits.inspirations {
		if earlier, seen := insp_seen[row.system]; seen {
			append(&problems, fmt.tprintf("%s:%d: Inspirations names %q a second time (line %d)", REUSE_LIST_DOCUMENT, row.line, row.system, earlier))
		} else {
			insp_seen[row.system] = row.line
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
	for line in foundation.lines_of_text(source) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "import ") {
			continue
		}
		path, _, found := foundation.quoted_text_after(trimmed)
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
	if text, ok := foundation.read_text_file_quiet(resources.REPOSITORY_LICENSE_FILE); ok {
		repository_license = build.reuse_spdx_of_record_words(strings.trim_space(foundation.lines_of_text(text)[0]))
	} else {
		missing(problems, resources.REPOSITORY_LICENSE_FILE, "the license of the repository")
	}

	// The fonts that the repository holds as subsets.
	font_lists := [?][]resources.Vector_Font_Candidate{resources.vector_font_candidates[:], resources.vector_font_emphasis[:], resources.vector_font_interface[:]}
	for list in font_lists {
		for candidate in list {
			record := foundation.join(FONT_FOLDER, "/", candidate.name, ".license")
			text, ok := foundation.read_text_file_quiet(record)
			if !ok {
				missing(problems, record, candidate.family)
				continue
			}
			font, font_problem := font_license_parse(record, text)
			if font_problem != "" {
				append(problems, font_problem)
				continue
			}
			append(&works, Reused_Work {
				what         = font.family,
				place        = foundation.join(FONT_FOLDER, "/", candidate.name, ".ttf"),
				license      = build.reuse_spdx_of_record_words(font.license),
				license_file = foundation.join(FONT_FOLDER, "/", candidate.license_file),
			})
		}
	}

	// Spleen, the fallback font.
	if text, ok := foundation.read_text_file_quiet(resources.SPLEEN_LICENSE_FILE); ok {
		append(&works, Reused_Work {
			what         = "Spleen 8x16",
			place        = REUSE_SPLEEN_FONT_DATA,
			license      = line_after(text, SPDX_IDENTIFIER_LINE_START),
			license_file = resources.SPLEEN_LICENSE_FILE,
		})
		// The sizes of the boot display: the same font and license.
		append(&works, Reused_Work {
			what         = "Spleen 12x24, 16x32 and 32x64",
			place        = foundation.BOOT_DISPLAY_FONT_OUTPUT,
			license      = line_after(text, SPDX_IDENTIFIER_LINE_START),
			license_file = resources.SPLEEN_LICENSE_FILE,
		})
	} else {
		missing(problems, resources.SPLEEN_LICENSE_FILE, "Spleen 8x16")
	}

	// Each pointer theme that the build makes and that is not under the
	// license of the repository. Its manifest is its notice.
	for theme in resources.pointer_theme_builds {
		text, ok := foundation.read_text_file_quiet(theme.manifest)
		if !ok {
			missing(problems, theme.manifest, "a pointer theme")
			continue
		}
		manifest, manifest_problem := pointer_manifest_head_parse(theme.manifest, text)
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
	if text, ok := foundation.read_text_file_quiet(ODIN_LICENSE_FILE); ok {
		odin_license = strings.contains(text, "(zlib)") ? "Zlib" : ""
	} else {
		missing(problems, ODIN_LICENSE_FILE, "the code of Odin")
	}
	if text, ok := foundation.read_text_file_quiet(foundation.CRYPTOGRAPHY_MANIFEST); ok {
		taken := 0
		fiat_taken := false
		for line in foundation.lines_of_text(text) {
			if strings.trim_space(line) == "" || strings.has_prefix(line, "#") {
				continue
			}
			taken += 1
			fiat_taken ||= strings.has_prefix(line, REUSE_FIAT_FOLDER + "/")
		}
		if taken > 0 {
			append(&works, Reused_Work{what = "the cryptography of Odin's core:crypto", place = foundation.CRYPTOGRAPHY_FOLDER, license = odin_license, license_file = ODIN_LICENSE_FILE})
		}
		if fiat_taken {
			fiat_license := ""
			if fiat_text, fiat_ok := foundation.read_text_file_quiet(FIAT_LICENSE_FILE); fiat_ok {
				fiat_license = strings.contains(fiat_text, "(BSD-1-Clause)") ? "BSD-1-Clause" : ""
			}
			append(&works, Reused_Work{what = "the field arithmetic of fiat-crypto", place = REUSE_FIAT_FOLDER, license = fiat_license, license_file = FIAT_LICENSE_FILE})
		}
	} else {
		missing(problems, foundation.CRYPTOGRAPHY_MANIFEST, "the cryptography of Odin")
	}
	append(&works, Reused_Work{what = "the runtime of the Odin compiler", place = REUSE_COMPILER_RUNTIME, license = odin_license, license_file = ODIN_LICENSE_FILE})
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
		source, ok := foundation.read_text_file_quiet(file)
		if !ok {
			append(problems, fmt.tprintf("%s: cannot read", file))
			continue
		}
		if !reuse_source_is_host_only(source) {
			reuse_core_imports_of_source(source, &core_imports)
		}
	}
	for path in core_imports {
		append(&works, Reused_Work{what = foundation.join("the package ", path, " of the Odin compiler"), place = path, license = odin_license, license_file = ODIN_LICENSE_FILE})
	}

	// The works in C that a module compiles in: the license of each is the
	// copy in its folder of the repository, whose first line names it.
	for source in foundation.outside_sources() {
		license_file := foundation.join(source.folder, "/", OUTSIDE_SOURCE_LICENSE_NAME)
		text, ok := foundation.read_text_file_quiet(license_file)
		if !ok {
			missing(problems, license_file, source.work)
			continue
		}
		append(&works, Reused_Work {
			what         = foundation.join("the work ", source.work, " in C"),
			place        = source.folder,
			license      = build.reuse_spdx_of_record_words(strings.trim_space(foundation.lines_of_text(text)[0])),
			license_file = license_file,
		})
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
			license      = build.reuse_spdx_of_record_words(credit.license),
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
	if document, ok := foundation.read_text_file_quiet(REUSE_LIST_DOCUMENT); ok {
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

FONT_FOLDER :: "resources/fonts"

// The copy of the license of a work in C, in its folder of the repository
// (src/md/infrastructure/outside_source.md).
OUTSIDE_SOURCE_LICENSE_NAME :: "LICENSE"

ODIN_LICENSE_FILE :: foundation.CRYPTOGRAPHY_FOLDER + "/LICENSE.odin.txt"

FIAT_LICENSE_FILE :: foundation.CRYPTOGRAPHY_FOLDER + "/LICENSE.fiat-crypto.txt"

// The start of the line of a license file that names its license, in the
// form of SPDX: "SPDX-License-Identifier: BSD-2-Clause".
SPDX_IDENTIFIER_LINE_START :: "SPDX-License-Identifier: "

// What a ".license" file beside a font subset records. The form: line 1 is
// the copyright, with the address of the source in parentheses at its end
// when the source gives one; a line "... carries the name "<family>"."; a
// line "License of the source: <words>.".
Font_License :: struct {
	copyright: string,
	address:   string,
	family:    string,
	license:   string,
}

font_license_parse :: proc(file_name, content: string) -> (font: Font_License, problem: string) {
	lines := foundation.lines_of_text(content)
	if len(lines) == 0 || strings.trim_space(lines[0]) == "" {
		return {}, fmt.tprintf("%s: line 1 must be the copyright", file_name)
	}
	font.copyright = strings.trim_space(lines[0])
	if open := strings.last_index(font.copyright, " (http"); open > 0 && strings.has_suffix(font.copyright, ")") {
		font.address = font.copyright[open + 2:len(font.copyright) - 1]
		font.copyright = font.copyright[:open]
	}
	FAMILY :: "carries the name \""
	LICENSE :: "License of the source: "
	for line in lines {
		if start := strings.index(line, FAMILY); start >= 0 {
			rest := line[start + len(FAMILY):]
			if end := strings.index_byte(rest, '"'); end > 0 {
				font.family = rest[:end]
			}
		}
		if strings.has_prefix(line, LICENSE) {
			font.license = strings.trim_suffix(strings.trim_space(line[len(LICENSE):]), ".")
		}
	}
	if font.family == "" {
		return {}, fmt.tprintf("%s: no line with %s<family>\"", file_name, FAMILY)
	}
	if font.license == "" {
		return {}, fmt.tprintf("%s: no line \"%s<words>.\"", file_name, LICENSE)
	}
	return font, ""
}

// What a pointer manifest records in its head: "theme <name>",
// "license <SPDX identifier>", and lines "attribution <text>".
Pointer_Manifest_Head :: struct {
	theme:       string,
	license:     string,
	attribution: []string,
}

pointer_manifest_head_parse :: proc(file_name, content: string) -> (manifest: Pointer_Manifest_Head, problem: string) {
	attribution := make([dynamic]string, context.temp_allocator)
	for line in foundation.lines_of_text(content) {
		switch {
		case strings.has_prefix(line, "theme "):
			manifest.theme = strings.trim_space(line[len("theme "):])
		case strings.has_prefix(line, "license "):
			manifest.license = strings.trim_space(line[len("license "):])
		case strings.has_prefix(line, "attribution "):
			append(&attribution, strings.trim_space(line[len("attribution "):]))
		}
	}
	manifest.attribution = attribution[:]
	if manifest.theme == "" || manifest.license == "" {
		return {}, fmt.tprintf("%s: a line \"theme <name>\" and a line \"license <identifier>\" are expected", file_name)
	}
	return manifest, ""
}

// line_after gives the rest of the first line that starts with start.
line_after :: proc(content, start: string) -> string {
	for line in foundation.lines_of_text(content) {
		if strings.has_prefix(line, start) {
			return strings.trim_space(line[len(start):])
		}
	}
	return ""
}

PROPERTIES_FILE :: "docs/PROPERTIES.md"
