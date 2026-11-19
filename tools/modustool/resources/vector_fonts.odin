package resources

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/font_outlines"
import "modus:contract/glyph_cache"
import "modus:support/vector_font"
import "modustool:foundation"

// The vector fonts of the system (docs/FONTS.md).
//
// The command "vector_fonts" reads the font files of the candidates from
// the build inputs of flake.nix (VECTOR_FONT_SOURCES), and writes for each
// one a subset in resources/fonts: the characters of a glyph cache (ASCII
// 32 to 126, the Latin-1 Supplement and the added characters,
// glyph_cache.character_index) and
// the glyph .notdef, each glyph a simple glyph with no hinting
// instructions. A font that lacks one of them is refused. The subsets of
// the regular weight of the interface font and of the two weights of the
// font of the cells also hold characters past the glyph cache, which each
// process draws from the outlines into its private glyph cache
// (past_cache_characters_of), after the others, so the glyphs of
// their glyph caches do not change; the hash of the font file in the
// header of each cache does. The
// subsets are in the repository, as the output of the command "font" is:
// a build does not need the build inputs. The command also writes
// build/fonts/candidates.png, the picture of the choice, from the same
// renderer as the system.
//
// The build makes the glyph caches of the default font and of the interface font, and
// the font outlines (build_glyph_caches): the boot image holds them as resources.

VECTOR_FONT_SOURCES_VARIABLE :: "VECTOR_FONT_SOURCES"
VECTOR_FONT_FOLDER :: "resources/fonts"
VECTOR_FONT_BUILD_FOLDER :: foundation.BUILD_FOLDER + "/fonts"
GLYPH_CACHE_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/glyph_cache.bin"
GLYPH_CACHE_RESOURCE :: "glyph_cache"
GLYPH_CACHE_WITHOUT_GRID_FIT_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/glyph_cache_no_grid_fit.bin"
GLYPH_CACHE_WITHOUT_GRID_FIT_RESOURCE :: "glyph_cache_no_grid_fit"
GLYPH_CACHE_BOLD_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/glyph_cache_bold.bin"
GLYPH_CACHE_BOLD_RESOURCE :: "glyph_cache_bold"
CANDIDATES_PICTURE :: VECTOR_FONT_BUILD_FOLDER + "/candidates.png"
INTERFACE_GLYPH_CACHE_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/interface_glyph_cache.bin"
INTERFACE_GLYPH_CACHE_BOLD_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/interface_glyph_cache_bold.bin"
INTERFACE_GLYPH_CACHE_RESOURCE :: "interface_glyph_cache"
INTERFACE_GLYPH_CACHE_BOLD_RESOURCE :: "interface_glyph_cache_bold"

// The default font of the system: one line to change (docs/FONTS.md, "The
// font file").
DEFAULT_VECTOR_FONT :: "paper_mono"

// The candidates, in the order of the picture. family: the name that the
// subset carries. A font with a Reserved Font Name (SIL OFL 1.1) is renamed
// in its subset: a subset is a Modified Version (OFL FAQ 2.6).
Vector_Font_Candidate :: struct {
	name:         string, // The file name in resources/fonts, and the key in VECTOR_FONT_SOURCES.
	family:       string,
	license:      string,
	license_file: string, // The full text of the license, in resources/fonts.
	zero_form:    Zero_Form,
}

// The form of the zero in a subset. Slashed: the glyph that the feature
// "zero" of the table GSUB gives for '0' (a single substitution), read from
// the font file; a font with no such feature keeps its zero, and the tool
// says so. The default zero of Paper Mono looks like its capital O.
Zero_Form :: enum u8 {
	Of_The_Font,
	Slashed,
}
ZERO_FEATURE :: vector_font.Feature_Tag{'z', 'e', 'r', 'o'}

vector_font_candidates := [?]Vector_Font_Candidate {
	{"paper_mono", "Paper Mono ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Slashed},
	{"dejavu_sans_mono", "DejaVu Sans Mono ASCII", "Bitstream Vera license; DejaVu changes in the public domain", "BITSTREAM_VERA_LICENSE.txt", .Of_The_Font},
	{"jetbrains_mono", "JetBrains Mono ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
	{"ibm_mono", "IBM Mono ASCII", "SIL OFL 1.1, Reserved Font Name Plex: renamed", "OFL.txt", .Of_The_Font},
	{"fira_mono", "Fira Mono ASCII", "SIL OFL 1.1", "OFL.txt", .Of_The_Font},
	{"commit_mono", "CommitMono ASCII", "SIL OFL 1.1 in the font file; MIT in its repository", "OFL.txt", .Of_The_Font},
	{"iosevka", "Iosevka ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
}

// The weight of the default font for emphasis (the titles of the cards):
// subset with the candidates, drawn at scale 1 only. Paper Mono has a
// SemiBold and no Bold: the SemiBold is the emphasis.
vector_font_emphasis := [?]Vector_Font_Candidate {
	{"paper_mono_semibold", "Paper Mono ASCII SemiBold", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Slashed},
}
EMPHASIS_VECTOR_FONT :: "paper_mono_semibold"

// The interface font (docs/FONTS.md, section 12): proportional, its two
// weights. Not a candidate of the picture: the grid of cells is not its
// place.
vector_font_interface := [?]Vector_Font_Candidate {
	{"b612", "B612 ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
	{"b612_bold", "B612 ASCII Bold", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
}
INTERFACE_VECTOR_FONT :: "b612"
INTERFACE_EMPHASIS_VECTOR_FONT :: "b612_bold"

run_vector_fonts :: proc(args: []string) -> int {
	sources := os.get_env(VECTOR_FONT_SOURCES_VARIABLE, context.temp_allocator)
	if sources == "" {
		fmt.eprintln("modustool: " + VECTOR_FONT_SOURCES_VARIABLE + " is not set. Use the development shell: nix develop")
		return foundation.EXIT_FAILURE
	}
	foundation.make_folder(VECTOR_FONT_FOLDER)
	foundation.make_folder(VECTOR_FONT_BUILD_FOLDER)
	fmt.printfln("%-18s %10s %8s %10s %8s %8s %8s %6s %s", "font", "source", "subset", "composite", "advance", "x-height", "cap", "pairs", "zero")
	// proportional: each character has its own advance; the subset keeps
	// the pair adjustments of kern.
	Subset_Request :: struct {
		candidate:    Vector_Font_Candidate,
		proportional: bool,
	}
	all := make([dynamic]Subset_Request, context.temp_allocator)
	for candidate in vector_font_candidates {
		append(&all, Subset_Request{candidate, false})
	}
	for candidate in vector_font_emphasis {
		append(&all, Subset_Request{candidate, false})
	}
	for candidate in vector_font_interface {
		append(&all, Subset_Request{candidate, true})
	}
	for request in all {
		candidate := request.candidate
		path := ""
		rest := sources
		for item in strings.split_iterator(&rest, ";") {
			if strings.has_prefix(item, strings.concatenate({candidate.name, "="}, context.temp_allocator)) {
				path = item[len(candidate.name) + 1:]
			}
		}
		if path == "" {
			fmt.eprintfln("modustool: %s has no %s", VECTOR_FONT_SOURCES_VARIABLE, candidate.name)
			return foundation.EXIT_FAILURE
		}
		source, read := foundation.read_file(path)
		if !read {
			return foundation.EXIT_FAILURE
		}
		subset, report, ok := font_subset(source, candidate, request.proportional)
		if !ok {
			fmt.eprintfln("modustool: %s: %s", path, report.problem)
			return foundation.EXIT_FAILURE
		}
		output := foundation.join(VECTOR_FONT_FOLDER, "/", candidate.name, ".ttf")
		if err := os.write_entire_file(output, subset); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", output, err)
			return foundation.EXIT_FAILURE
		}
		license_path := foundation.join(VECTOR_FONT_FOLDER, "/", candidate.name, ".license")
		if err := os.write_entire_file(license_path, transmute([]u8)report.license_text); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", license_path, err)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("%-18s %10d %8d %10d %8d %8d %8d %6d %s", candidate.name, len(source), len(subset), report.composites, report.measures.advance, report.measures.x_height, report.measures.cap_height, report.pairs, report.zero)
		for equivalent in report.equivalents {
			fmt.printfln("modustool: %s has no glyph for U+%04X: its subset draws it with the glyph of U+%04X", candidate.name, int(equivalent.character), int(equivalent.taken_from))
		}
		if candidate.zero_form == .Slashed && report.zero_glyph == 0 {
			fmt.printfln("modustool: %s has no single substitution of the feature zero for '0': its subset keeps the zero of the font", candidate.name)
		}
	}
	_, interface_written := interface_glyph_caches_write()
	if !candidates_picture_write() || !interface_written {
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: the subsets are in %s, the picture of the choice is %s", VECTOR_FONT_FOLDER, CANDIDATES_PICTURE)
	return 0
}

Subset_Report :: struct {
	problem:      string,
	composites:   int, // Glyphs made of glyphs, made simple.
	pairs:        int, // The pair adjustments between the characters of the subset that it keeps.
	zero_glyph:   int, // The glyph of the source that the subset draws for '0' in place of the glyph of the cmap; 0: the zero of the font.
	zero:         string, // For the table of the command: "slashed (glyph n)" or "of the font".
	measures:     vector_font.Font_Measures,
	license_text: string,
	equivalents:  [dynamic]Equivalent_Glyph, // The characters that the font lacks and that take the glyph of their equivalent.
}

// The glyphs of a subset: .notdef, then the characters of a glyph cache in
// the order of their character index: the glyph of the index i is i + 1.
// The characters past the glyph cache of a subset, if it has some, come
// after these.
SUBSET_GLYPHS :: 1 + glyph_cache.CHARACTER_COUNT

// subset_character gives the character of a glyph of a subset, past
// .notdef.
subset_character :: proc(glyph: int) -> rune {
	character, _ := glyph_cache.character_of_index(glyph - 1)
	return character
}

// A run of code points with no gap.
Character_Range :: struct {
	first, last: rune,
}

// The characters past the glyph cache that the subset of B612 holds: the
// Greek letters that the character map of B612 1.008 has. It lacks the
// capital pi (U+03A0) and the small rho (U+03C1); U+03A2 is no character.
@(rodata)
interface_past_cache_ranges := [?]Character_Range {
	{0x0391, 0x039F}, // Alpha to omicron, capitals.
	{0x03A1, 0x03A1}, // Rho, capital.
	{0x03A3, 0x03A9}, // Sigma to omega, capitals.
	{0x03B1, 0x03C0}, // Alpha to pi, small.
	{0x03C2, 0x03C9}, // Final sigma to omega, small.
}

// The characters past the glyph cache that Paper Mono has, in its regular
// and its SemiBold weight: its five Greek letters, the box-drawing
// characters and the block elements. It has no other Greek letter.
@(rodata)
cell_past_cache_ranges := [?]Character_Range {
	{0x039B, 0x039B}, // Lambda, capital.
	{0x03A9, 0x03A9}, // Omega, capital.
	{0x03BB, 0x03BC}, // Lambda and mu, small.
	{0x03C0, 0x03C0}, // Pi, small.
	{0x2500, 0x257F}, // The box-drawing characters.
	{0x2580, 0x259F}, // The block elements.
}

// past_cache_ranges_of gives the runs of the characters past the glyph
// cache that the subset of a font holds, which each process draws from the
// outlines into its private glyph cache
// (src/md/features/glyphs_on_demand.md): for the regular weight of the
// interface font and for the two weights of the font of the cells; none
// for each other font. The tool adds them after the characters of the
// glyph cache, so the glyphs of the glyph caches of the build do not
// change.
past_cache_ranges_of :: proc(name: string) -> []Character_Range {
	switch name {
	case INTERFACE_VECTOR_FONT:
		return interface_past_cache_ranges[:]
	case DEFAULT_VECTOR_FONT, EMPHASIS_VECTOR_FONT:
		return cell_past_cache_ranges[:]
	}
	return nil
}

// past_cache_characters_of gives the characters of past_cache_ranges_of, in the
// order of the code points. Their glyphs come after the glyphs of the
// characters of the cache.
past_cache_characters_of :: proc(name: string) -> []rune {
	characters := make([dynamic]rune, context.temp_allocator)
	for range in past_cache_ranges_of(name) {
		for character in range.first ..= range.last {
			append(&characters, character)
		}
	}
	return characters[:]
}

// A character of the subset that the font lacks, drawn with the glyph of
// another character.
Equivalent_Glyph :: struct {
	character:  rune,
	taken_from: rune,
}

// The two characters of the Latin-1 Supplement that a font can lack and
// that have a standard equivalent of the same form: the space with no
// break draws as the space, the soft hyphen as the hyphen. Paper Mono has
// no soft hyphen. Each other character that a font lacks is refused, the
// euro sign too: a guessed form would be a wrong character (docs/FONTS.md,
// "6. The font file").
@(rodata)
equivalent_characters := [?]Equivalent_Glyph{{character = 0xA0, taken_from = ' '}, {character = 0xAD, taken_from = '-'}}

// subset_glyph_of gives the glyph of the source that the subset draws for a
// character: its own glyph, or the glyph of its equivalent when the font
// lacks it. taken_from is the character whose glyph it is.
subset_glyph_of :: proc(font: ^vector_font.Font_File, character: rune) -> (glyph: int, taken_from: rune, problem: vector_font.Font_Problem) {
	glyph, problem = vector_font.glyph_of(font, character)
	if problem != .No_Glyph {
		return glyph, character, problem
	}
	for equivalent in equivalent_characters {
		if equivalent.character == character {
			glyph, problem = vector_font.glyph_of(font, equivalent.taken_from)
			return glyph, equivalent.taken_from, problem
		}
	}
	return 0, character, problem
}

// font_subset writes a TrueType file with the characters of a glyph cache
// of a font, from the first face of a collection.
font_subset :: proc(source: []u8, candidate: Vector_Font_Candidate, proportional: bool) -> (subset: []u8, report: Subset_Report, ok: bool) {
	face, face_problem := vector_font.collection_face_offset(source, 0)
	font, problem := vector_font.font_open(source, face)
	if face_problem != .None || problem != .None {
		report.problem = vector_font.font_problem_names[face_problem != .None ? face_problem : problem]
		return nil, report, false
	}
	memory := new(vector_font.Render_Memory, context.temp_allocator)
	report.measures, problem = vector_font.font_measures(&font, memory)
	if problem != .None || !report.measures.monospace && !proportional {
		report.problem = problem != .None ? vector_font.font_problem_names[problem] : "the font is not monospace"
		return nil, report, false
	}
	report.zero = "of the font"
	report.equivalents = make([dynamic]Equivalent_Glyph, context.temp_allocator)
	// The pair adjustments, read from the source as hostile input: each
	// pair of two characters of the subset, by the glyphs of the subset.
	kern: []u8
	if proportional {
		// The measures that the glyph cache uses: the stated cap height and
		// x-height, and the units of one cell in place of an advance.
		report.measures, problem = vector_font.proportional_measures(&font, report.measures)
		if problem != .None {
			report.problem = vector_font.font_problem_names[problem]
			return nil, report, false
		}
		pair_table, pair_problem := vector_font.pair_table_open(&font)
		if pair_problem != .None {
			report.problem = fmt.tprintf("the table kern: %s", vector_font.font_problem_names[pair_problem])
			return nil, report, false
		}
		kern, report.pairs = kern_table_write(&font, &pair_table)
	}
	// The glyphs, each as a simple glyph: .notdef, the characters of a
	// glyph cache, then the characters past the glyph cache.
	past_cache_characters := past_cache_characters_of(candidate.name)
	glyph_count := SUBSET_GLYPHS + len(past_cache_characters)
	glyphs := make([dynamic]u8, context.temp_allocator)
	offsets := make([]u32, glyph_count + 1, context.temp_allocator)
	advances := make([]u16, glyph_count, context.temp_allocator)
	left_sides := make([]i16, glyph_count, context.temp_allocator)
	box := [4]i32{max(i32), max(i32), min(i32), min(i32)}
	most_points, most_contours := 0, 0
	outline := vector_font.Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for index in 0 ..< glyph_count {
		glyph := 0
		if index > 0 {
			character: rune
			if index < SUBSET_GLYPHS {
				character = subset_character(index)
			} else {
				character = past_cache_characters[index - SUBSET_GLYPHS]
			}
			taken_from: rune
			glyph, taken_from, problem = subset_glyph_of(&font, character)
			if problem != .None {
				report.problem = fmt.tprintf("the character U+%04X: %s", int(character), vector_font.font_problem_names[problem])
				return nil, report, false
			}
			if taken_from != character {
				append(&report.equivalents, Equivalent_Glyph{character = character, taken_from = taken_from})
			}
			if character == '0' && candidate.zero_form == .Slashed {
				substitute, substitution_problem := vector_font.single_substitution(&font, ZERO_FEATURE, glyph)
				#partial switch substitution_problem {
				case .None:
					glyph = substitute
					report.zero_glyph = substitute
					report.zero = fmt.tprintf("slashed (glyph %d)", substitute)
				case .No_Feature:
				case:
					report.problem = fmt.tprintf("the table GSUB: %s", vector_font.font_problem_names[substitution_problem])
					return nil, report, false
				}
			}
		}
		if is_composite(&font, glyph) {
			report.composites += 1
		}
		if problem = vector_font.glyph_outline(&font, glyph, &outline); problem != .None {
			report.problem = fmt.tprintf("the glyph %d: %s", glyph, vector_font.font_problem_names[problem])
			return nil, report, false
		}
		offsets[index] = u32(len(glyphs))
		advances[index] = u16(outline.advance)
		if outline.point_count > 0 {
			glyph_box := simple_glyph_write(&glyphs, &outline)
			left_sides[index] = i16(glyph_box[0])
			box = {min(box[0], glyph_box[0]), min(box[1], glyph_box[1]), max(box[2], glyph_box[2]), max(box[3], glyph_box[3])}
			most_points = max(most_points, outline.point_count)
			most_contours = max(most_contours, outline.contour_count)
		}
	}
	offsets[glyph_count] = u32(len(glyphs))
	tables := make([dynamic]Subset_Table, context.temp_allocator)
	// OS/2: the table of the source, as it is.
	if font.os2.length > 0 {
		append(&tables, Subset_Table{"OS/2", slice.clone(source[font.os2.offset:][:font.os2.length], context.temp_allocator)})
	}
	append(&tables, Subset_Table{"cmap", character_map_write(past_cache_characters)})
	append(&tables, Subset_Table{"glyf", glyphs[:]})
	head := slice.clone(source[font.head.offset:][:54], context.temp_allocator)
	put_u32(head, 8, 0) // checkSumAdjustment, set at the end.
	put_u16(head, 36, u16(i16(box[0])))
	put_u16(head, 38, u16(i16(box[1])))
	put_u16(head, 40, u16(i16(box[2])))
	put_u16(head, 42, u16(i16(box[3])))
	put_u16(head, 50, 1) // Long offsets in loca.
	append(&tables, Subset_Table{"head", head})
	hhea := slice.clone(source[font.hhea.offset:][:36], context.temp_allocator)
	put_u16(hhea, 10, slice.max(advances[:])) // advanceWidthMax.
	put_u16(hhea, 34, u16(glyph_count))
	append(&tables, Subset_Table{"hhea", hhea})
	metrics := make([]u8, 4 * glyph_count, context.temp_allocator)
	for index in 0 ..< glyph_count {
		put_u16(metrics, 4 * index, advances[index])
		put_u16(metrics, 4 * index + 2, u16(left_sides[index]))
	}
	append(&tables, Subset_Table{"hmtx", metrics})
	if len(kern) > 0 {
		append(&tables, Subset_Table{"kern", kern})
	}
	loca := make([]u8, 4 * (glyph_count + 1), context.temp_allocator)
	for offset, index in offsets {
		put_u32(loca, 4 * index, offset)
	}
	append(&tables, Subset_Table{"loca", loca})
	maxp := make([]u8, 32, context.temp_allocator)
	put_u32(maxp, 0, 0x00010000)
	put_u16(maxp, 4, u16(glyph_count))
	put_u16(maxp, 6, u16(most_points))
	put_u16(maxp, 8, u16(most_contours))
	put_u16(maxp, 14, 2) // maxZones.
	append(&tables, Subset_Table{"maxp", maxp})
	copyright := name_string(&font, 0)
	license := name_string(&font, 13)
	license_place := name_string(&font, 14)
	append(&tables, Subset_Table{"name", name_table_write(candidate.family, copyright, license, license_place)})
	post := make([]u8, 32, context.temp_allocator)
	put_u32(post, 0, 0x00030000)
	if font.post.length >= 32 {
		copy(post[4:16], source[font.post.offset + 4:][:12]) // The angle and the underline.
	}
	put_u32(post, 12, proportional ? 0 : 1) // isFixedPitch.
	append(&tables, Subset_Table{"post", post})
	subset = sfnt_write(tables[:])
	added := strings.builder_make(context.temp_allocator)
	for character in glyph_cache.added_characters {
		fmt.sbprintf(&added, " U+%04X", int(character))
	}
	past_cache := strings.builder_make(context.temp_allocator)
	if len(past_cache_characters) > 0 {
		// The list of the added characters goes on with the characters past
		// the glyph cache: a comma ends it.
		fmt.sbprint(&added, ",")
		fmt.sbprint(&past_cache, "the characters that each process draws from the outlines,")
		for range in past_cache_ranges_of(candidate.name) {
			fmt.sbprintf(&past_cache, " U+%04X to U+%04X", int(range.first), int(range.last))
		}
		fmt.sbprint(&past_cache, ",\n")
	}
	report.license_text = fmt.aprintf(
		"%s\n\nThis file is a subset of %s, made by \"modustool vector_fonts\" (docs/FONTS.md):\nthe characters 32 to 126, the characters U+00A0 to U+00FF, the characters%s\n%sand the glyph .notdef, each glyph a simple glyph\n(%d glyphs made of glyphs were made simple), no hinting instructions, no\nOpenType layout tables%s. The subset carries the name \"%s\".\nLicense of the source: %s.\n\nThe text of the license in the source font file:\n\n%s\n\nURL of the license: %s\nThe full text of the license: %s, in this folder.\n",
		copyright, candidate.name, strings.to_string(added), strings.to_string(past_cache), report.composites, strings.concatenate({proportional ? fmt.tprintf("; the %d pair adjustments of its table kern between\nthese characters", report.pairs) : "", report.zero_glyph != 0 ? fmt.tprintf(";\nthe character 0 is the glyph %d of the source, the slashed zero of its\nfeature zero", report.zero_glyph) : ""}, context.temp_allocator), candidate.family, candidate.license, license, license_place, candidate.license_file,
		allocator = context.temp_allocator,
	)
	return subset, report, true
}

// kern_table_write gives a kern table of version 0 with one subtable of
// format 0: the pairs of the characters of the subset whose adjustment is
// not 0, by the glyphs of the subset (subset_character). The loops go in
// the order of the glyphs, so the pairs are sorted.
@(private = "file")
kern_table_write :: proc(font: ^vector_font.Font_File, pair_table: ^vector_font.Pair_Table) -> (table: []u8, count: int) {
	pairs := make([dynamic]u8, context.temp_allocator)
	for left in 1 ..< SUBSET_GLYPHS {
		for right in 1 ..< SUBSET_GLYPHS {
			adjustment := vector_font.character_pair_adjustment(font, pair_table, subset_character(left), subset_character(right))
			if adjustment != 0 {
				append_u16(&pairs, u16(left))
				append_u16(&pairs, u16(right))
				append_u16(&pairs, u16(i16(adjustment)))
				count += 1
			}
		}
	}
	if count == 0 {
		return nil, 0
	}
	out := make([dynamic]u8, context.temp_allocator)
	append_u16(&out, 0) // version
	append_u16(&out, 1) // one subtable
	append_u16(&out, 0) // the version of the subtable
	append_u16(&out, u16(vector_font.KERN_SUBTABLE_HEADER_SIZE + len(pairs)))
	append_u16(&out, 0x0001) // format 0, horizontal
	append_u16(&out, u16(count))
	power := 1
	exponent := 0
	for power * 2 <= count {
		power *= 2
		exponent += 1
	}
	append_u16(&out, u16(vector_font.KERN_PAIR_SIZE * power)) // searchRange
	append_u16(&out, u16(exponent)) // entrySelector
	append_u16(&out, u16(vector_font.KERN_PAIR_SIZE * (count - power))) // rangeShift
	append(&out, ..pairs[:])
	return out[:], count
}

// is_composite says if a glyph is made of other glyphs.
@(private = "file")
is_composite :: proc(font: ^vector_font.Font_File, glyph: int) -> bool {
	loca := font.bytes[font.loca.offset:][:font.loca.length]
	start := font.long_offsets ? int(get_u32(loca, 4 * glyph)) : 2 * int(get_u16(loca, 2 * glyph))
	end := font.long_offsets ? int(get_u32(loca, 4 * glyph + 4)) : 2 * int(get_u16(loca, 2 * glyph + 2))
	if end <= start {
		return false
	}
	return i16(get_u16(font.bytes, font.glyf.offset + start)) < 0
}

// simple_glyph_write appends a simple glyph: each coordinate as a 16-bit
// difference, no instruction. It pads to 4 bytes and gives the box.
@(private = "file")
simple_glyph_write :: proc(out: ^[dynamic]u8, outline: ^vector_font.Outline) -> (box: [4]i32) {
	box = {max(i32), max(i32), min(i32), min(i32)}
	for point in outline.points[:outline.point_count] {
		box = {min(box[0], point.x), min(box[1], point.y), max(box[2], point.x), max(box[3], point.y)}
	}
	append_u16(out, u16(outline.contour_count))
	for value in box {
		append_u16(out, u16(i16(value)))
	}
	for end in outline.contour_ends[:outline.contour_count] {
		append_u16(out, u16(end - 1))
	}
	append_u16(out, 0) // No instruction.
	for point in outline.points[:outline.point_count] {
		append(out, point.on_curve ? 1 : 0) // 16-bit differences on both axes.
	}
	previous: i32
	for point in outline.points[:outline.point_count] {
		append_u16(out, u16(i16(point.x - previous)))
		previous = point.x
	}
	previous = 0
	for point in outline.points[:outline.point_count] {
		append_u16(out, u16(i16(point.y - previous)))
		previous = point.y
	}
	for len(out) % 4 != 0 {
		append(out, 0)
	}
	return box
}

// character_map_write gives a cmap with one subtable of format 4: the
// characters 32 to 126 are the glyphs 1 to 95, the characters U+00A0 to
// U+00FF the glyphs 96 to 191, each added character a segment of its own
// with the glyph of its character index plus 1, each run of the characters
// past the glyph cache a segment whose glyphs follow SUBSET_GLYPHS, and the last
// segment ends at 0xFFFF, as the format needs. The segments are sorted by
// their characters, as the format needs.
@(private = "file")
character_map_write :: proc(past_cache_characters: []rune) -> []u8 {
	// The glyph of a character of a segment is the character plus delta.
	Character_Map_Segment :: struct {
		first, last: u16,
		delta:       int,
	}
	segments := make([dynamic]Character_Map_Segment, context.temp_allocator)
	append(&segments, Character_Map_Segment{first = glyph_cache.ASCII_FIRST, last = glyph_cache.ASCII_LAST, delta = 1 - glyph_cache.ASCII_FIRST})
	append(&segments, Character_Map_Segment{first = glyph_cache.LATIN_FIRST, last = glyph_cache.LATIN_LAST, delta = 1 + glyph_cache.ASCII_COUNT - glyph_cache.LATIN_FIRST})
	for character, offset in glyph_cache.added_characters {
		append(&segments, Character_Map_Segment{first = u16(character), last = u16(character), delta = 1 + glyph_cache.ADDED_FIRST_INDEX + offset - int(character)})
	}
	// The characters past the glyph cache: one segment for each run of code points
	// that follow each other, as their glyphs do.
	for character, offset in past_cache_characters {
		glyph := SUBSET_GLYPHS + offset
		last := len(segments) - 1
		if offset > 0 && character == past_cache_characters[offset - 1] + 1 {
			segments[last].last = u16(character)
		} else {
			append(&segments, Character_Map_Segment{first = u16(character), last = u16(character), delta = glyph - int(character)})
		}
	}
	slice.sort_by(segments[:], proc(a, b: Character_Map_Segment) -> bool {
		return a.first < b.first
	})
	// The last one maps 0xFFFF to the glyph 0.
	append(&segments, Character_Map_Segment{first = 0xFFFF, last = 0xFFFF, delta = 1})
	count := len(segments)
	power := 1
	exponent := 0
	for power * 2 <= count {
		power *= 2
		exponent += 1
	}
	out := make([dynamic]u8, context.temp_allocator)
	append_u16(&out, 0)
	append_u16(&out, 1)
	append_u16(&out, 3) // Windows, Unicode basic plane.
	append_u16(&out, 1)
	append_u32(&out, 12)
	append_u16(&out, 4)
	append_u16(&out, u16(16 + 8 * count)) // length
	append_u16(&out, 0) // language
	append_u16(&out, u16(2 * count))
	append_u16(&out, u16(2 * power)) // searchRange: 2 * 2^floor(log2(count)).
	append_u16(&out, u16(exponent)) // entrySelector: floor(log2(count)).
	append_u16(&out, u16(2 * count - 2 * power)) // rangeShift: 2 * count - searchRange.
	for segment in segments {
		append_u16(&out, segment.last)
	}
	append_u16(&out, 0) // reservedPad
	for segment in segments {
		append_u16(&out, segment.first)
	}
	// The delta of each segment, modulo 65536.
	for segment in segments {
		append_u16(&out, u16((segment.delta + 0x10000) % 0x10000))
	}
	// No range offset: each glyph is its character plus the delta.
	for _ in segments {
		append_u16(&out, 0)
	}
	return out[:]
}

// name_string gives a name of the font (Windows, Unicode) as UTF-16 code
// units turned to bytes: ASCII stays, another character becomes "?" but
// for the copyright sign.
@(private = "file")
name_string :: proc(font: ^vector_font.Font_File, name_id: int) -> string {
	table := font.bytes[font.name.offset:][:font.name.length]
	if len(table) < 6 {
		return ""
	}
	count := int(get_u16(table, 2))
	storage := int(get_u16(table, 4))
	for index in 0 ..< count {
		record := 6 + 12 * index
		if record + 12 > len(table) {
			break
		}
		if get_u16(table, record) != 3 || int(get_u16(table, record + 6)) != name_id {
			continue
		}
		length := int(get_u16(table, record + 8))
		offset := storage + int(get_u16(table, record + 10))
		if offset + length > len(table) {
			break
		}
		builder := strings.builder_make(context.temp_allocator)
		for at := offset; at + 1 < offset + length; at += 2 {
			unit := get_u16(table, at)
			switch {
			case unit == 0xA9:
				strings.write_string(&builder, "(c)")
			case unit == '\n' || unit >= 32 && unit < 127:
				strings.write_byte(&builder, u8(unit))
			case:
				strings.write_byte(&builder, '?')
			}
		}
		return strings.to_string(builder)
	}
	return ""
}

// name_table_write gives a name table of format 0 with the copyright, the
// family, the style, the full name, the license and its place.
@(private = "file")
name_table_write :: proc(family, copyright, license, license_place: string) -> []u8 {
	names := [?]struct {
		id:   u16,
		text: string,
	}{{0, copyright}, {1, family}, {2, "Regular"}, {4, family}, {13, license}, {14, license_place}}
	out := make([dynamic]u8, context.temp_allocator)
	append_u16(&out, 0)
	append_u16(&out, u16(len(names)))
	append_u16(&out, u16(6 + 12 * len(names)))
	offset := 0
	for name in names {
		append_u16(&out, 3)
		append_u16(&out, 1)
		append_u16(&out, 0x409)
		append_u16(&out, name.id)
		append_u16(&out, u16(2 * len(name.text)))
		append_u16(&out, u16(offset))
		offset += 2 * len(name.text)
	}
	for name in names {
		for character in transmute([]u8)name.text {
			append_u16(&out, u16(character))
		}
	}
	return out[:]
}

Subset_Table :: struct {
	tag:  string,
	data: []u8,
}

// sfnt_write gives a TrueType file of tables in the order of their tags,
// with the checksums and the checksum adjustment of head. The font of the
// name of the mark is written with it too (mark_font.odin).
sfnt_write :: proc(tables: []Subset_Table) -> []u8 {
	count := len(tables)
	out := make([dynamic]u8, context.temp_allocator)
	append_u32(&out, 0x00010000)
	append_u16(&out, u16(count))
	power := 1
	exponent := 0
	for power * 2 <= count {
		power *= 2
		exponent += 1
	}
	append_u16(&out, u16(16 * power))
	append_u16(&out, u16(exponent))
	append_u16(&out, u16(16 * count - 16 * power))
	offset := 12 + 16 * count
	head_offset := 0
	for table in tables {
		append(&out, ..transmute([]u8)table.tag)
		append_u32(&out, table_checksum(table.data))
		append_u32(&out, u32(offset))
		append_u32(&out, u32(len(table.data)))
		if table.tag == "head" {
			head_offset = offset
		}
		offset += (len(table.data) + 3) / 4 * 4
	}
	for table in tables {
		append(&out, ..table.data)
		for len(out) % 4 != 0 {
			append(&out, 0)
		}
	}
	put_u32(out[:], head_offset + 8, 0xB1B0AFBA - table_checksum(out[:]))
	return out[:]
}

// table_checksum gives the checksum of a table or of a whole file: the sum
// of its words of 32 bits, big endian, with zeros after its last byte up to
// a whole word. The sum wraps at 32 bits.
table_checksum :: proc(data: []u8) -> (sum: u32) {
	for at := 0; at < len(data); at += 4 {
		word: u32
		for index in 0 ..< 4 {
			word <<= 8
			if at + index < len(data) {
				word |= u32(data[at + index])
			}
		}
		sum += word
	}
	return sum
}

get_u16 :: proc(data: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(data) {
		return 0
	}
	return u16(data[at]) << 8 | u16(data[at + 1])
}

get_u32 :: proc(data: []u8, at: int) -> u32 {
	return u32(get_u16(data, at)) << 16 | u32(get_u16(data, at + 2))
}

put_u16 :: proc(data: []u8, at: int, value: u16) {
	data[at] = u8(value >> 8)
	data[at + 1] = u8(value)
}

put_u32 :: proc(data: []u8, at: int, value: u32) {
	put_u16(data, at, u16(value >> 16))
	put_u16(data, at + 2, u16(value))
}

append_u16 :: proc(out: ^[dynamic]u8, value: u16) {
	append(out, u8(value >> 8), u8(value))
}

append_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append_u16(out, u16(value >> 16))
	append_u16(out, u16(value))
}

// glyph_cache_of draws the characters of a glyph cache of a font file at the three
// scales of the grid, and gives the glyph cache file (src/library/contract/glyph_cache),
// in memory aligned on 8 bytes.
glyph_cache_of :: proc(font_bytes: []u8, font_name: string, grid_fit: bool, scale_count := 3) -> (cache: []u8, ok: bool) {
	font, problem := vector_font.font_open(font_bytes)
	memory := new(vector_font.Render_Memory, context.temp_allocator)
	words := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8, context.temp_allocator)
	out := ([^]u8)(raw_data(words))[:vector_font.GLYPH_CACHE_LIMIT]
	size := 0
	if problem == .None {
		size, problem = vector_font.glyph_cache_build(&font, font_bytes, font_name, grid_fit, memory, out, scale_count)
	}
	if problem != .None {
		fmt.eprintfln("modustool: the font %s: %s", font_name, vector_font.font_problem_names[problem])
		return nil, false
	}
	// The reader of the modules checks the cache here too: a cache that it
	// refuses is found at the build, not at the boot.
	if _, refused := glyph_cache.validate(out[:size]); refused.kind != .None {
		fmt.eprintfln("modustool: the glyph cache of %s is refused: %s, value %d, limit %d", font_name, glyph_cache.problem_sentences[refused.kind], refused.value, refused.limit)
		return nil, false
	}
	return out[:size], true
}

// build_glyph_caches writes the glyph caches of the default font, with the
// grid fit and without it, and of its bold weight at scale 1, and gives
// them as resources of the boot image. The setting "grid_fit" of the
// system chooses one of the first two at run time.
build_glyph_caches :: proc() -> (resources: [6]Resource_File, ok: bool) {
	foundation.make_folder(VECTOR_FONT_BUILD_FOLDER)
	builds := [3]struct {
		font:         string,
		grid_fit:     bool,
		scale_count:  int,
		output, name: string,
	}{{DEFAULT_VECTOR_FONT, true, 3, GLYPH_CACHE_OUTPUT, GLYPH_CACHE_RESOURCE}, {DEFAULT_VECTOR_FONT, false, 3, GLYPH_CACHE_WITHOUT_GRID_FIT_OUTPUT, GLYPH_CACHE_WITHOUT_GRID_FIT_RESOURCE}, {EMPHASIS_VECTOR_FONT, true, 1, GLYPH_CACHE_BOLD_OUTPUT, GLYPH_CACHE_BOLD_RESOURCE}}
	for build, index in builds {
		font := foundation.read_file(foundation.join(VECTOR_FONT_FOLDER, "/", build.font, ".ttf")) or_return
		cache := glyph_cache_of(font, build.font, build.grid_fit, build.scale_count) or_return
		if err := os.write_entire_file(build.output, cache); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", build.output, err)
			return {}, false
		}
		resources[index] = {name = build.name, path = build.output}
	}
	// The two caches of the interface font (docs/FONTS.md, section 12).
	interface_resources := interface_glyph_caches_write() or_return
	resources[3], resources[4] = interface_resources[0], interface_resources[1]
	// The font outlines: the files of the four caches, from which each
	// process draws the glyphs past them (docs/FONTS.md, "13. Glyphs past
	// the glyph cache").
	resources[5] = font_outlines_write() or_return
	return resources, true
}

FONT_OUTLINES_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/font_outlines.bin"

// The fonts of the resource of the outlines, by the names that
// text_rendering.outline_font_name gives: the files of the glyph caches.
FONT_OUTLINES_FONTS :: [?]string{INTERFACE_VECTOR_FONT, INTERFACE_EMPHASIS_VECTOR_FONT, DEFAULT_VECTOR_FONT, EMPHASIS_VECTOR_FONT}

// font_outlines_write writes the resource of the font outlines from the
// subsets in resources/fonts, checks it with the reader of the modules,
// and gives it as a resource of the boot image.
font_outlines_write :: proc() -> (resource: Resource_File, ok: bool) {
	names := FONT_OUTLINES_FONTS
	fonts: [len(names)]font_outlines.Font_Input
	for name, index in names {
		if len(name) == 0 || len(name) >= font_outlines.NAME_SIZE {
			fmt.eprintfln("modustool: the font %s has a name of %d bytes; the font outlines hold names of 1 to %d bytes", name, len(name), font_outlines.NAME_SIZE - 1)
			return {}, false
		}
		bytes := foundation.read_file(foundation.join(VECTOR_FONT_FOLDER, "/", name, ".ttf")) or_return
		fonts[index] = {name = name, bytes = bytes}
	}
	size := font_outlines.resource_size(fonts[:])
	words := make([]u64, (size + 7) / 8, context.temp_allocator)
	out := ([^]u8)(raw_data(words))[:size]
	if _, written := font_outlines.resource_write(fonts[:], out); !written {
		fmt.eprintln("modustool: the font outlines cannot be written: a name or a file is refused")
		return {}, false
	}
	if _, problem := font_outlines.validate(out); problem.kind != .None {
		fmt.eprintfln("modustool: the font outlines are refused: %s", font_outlines.problem_sentences[problem.kind])
		return {}, false
	}
	if err := os.write_entire_file(FONT_OUTLINES_OUTPUT, out); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", FONT_OUTLINES_OUTPUT, err)
		return {}, false
	}
	return {name = font_outlines.RESOURCE_NAME, path = FONT_OUTLINES_OUTPUT}, true
}

// The subpixel positions of the caches of the interface font, for each
// scale (docs/FONTS.md, section 12.4): three at scale 1, one at the scales
// 2 and 3; the bold weight at scale 1 only, for the titles.
INTERFACE_POSITIONS := [3]int{3, 1, 1}
INTERFACE_BOLD_POSITIONS := [1]int{3}

// interface_glyph_caches_write draws the two glyph caches of the interface
// font from its subsets, checks them with the reader of the modules (so a
// resource is never shorter than its header, and states its own size), and
// writes them with their sizes: the two resources of the boot image of the
// interface font.
interface_glyph_caches_write :: proc() -> (resources: [2]Resource_File, ok: bool) {
	builds := [2]struct {
		font, output, name: string,
		positions:          []int,
	}{{INTERFACE_VECTOR_FONT, INTERFACE_GLYPH_CACHE_OUTPUT, INTERFACE_GLYPH_CACHE_RESOURCE, INTERFACE_POSITIONS[:]}, {INTERFACE_EMPHASIS_VECTOR_FONT, INTERFACE_GLYPH_CACHE_BOLD_OUTPUT, INTERFACE_GLYPH_CACHE_BOLD_RESOURCE, INTERFACE_BOLD_POSITIONS[:]}}
	for build, index in builds {
		font_bytes := foundation.read_file(foundation.join(VECTOR_FONT_FOLDER, "/", build.font, ".ttf")) or_return
		font, problem := vector_font.font_open(font_bytes)
		memory := new(vector_font.Render_Memory, context.temp_allocator)
		words := make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8, context.temp_allocator)
		out := ([^]u8)(raw_data(words))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
		size := 0
		if problem == .None {
			size, problem = vector_font.glyph_cache_build_proportional(&font, font_bytes, build.font, true, memory, out, build.positions)
		}
		if problem != .None {
			fmt.eprintfln("modustool: the interface font %s: %s", build.font, vector_font.font_problem_names[problem])
			return {}, false
		}
		if _, refused := glyph_cache.validate(out[:size]); refused.kind != .None {
			fmt.eprintfln("modustool: the glyph cache of %s is refused: %s", build.font, glyph_cache.problem_sentences[refused.kind])
			return {}, false
		}
		if err := os.write_entire_file(build.output, out[:size]); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", build.output, err)
			return {}, false
		}
		fmt.printfln("modustool: the glyph cache of %s with the positions %v: %d bytes, in %s", build.font, build.positions, size, build.output)
		resources[index] = {name = build.name, path = build.output}
	}
	return resources, true
}
