package resources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/font_characters"
import "modus:vector_font"

// Each source font of VECTOR_FONT_SOURCES has a glyph for each character
// of a glyph cache, through the reader of the tool: with its own glyph, or
// for U+00A0 and U+00AD with the glyph of their equivalent. The test prints
// each character that a font lacks, so the log of the test is the list that
// a reader checks; a character with no glyph and no equivalent fails it.
// The development shell and the check of the flake set the variable.
@(test)
each_source_font_has_the_characters_of_a_cache :: proc(t: ^testing.T) {
	sources := os.get_env(VECTOR_FONT_SOURCES_VARIABLE, context.temp_allocator)
	testing.expectf(t, sources != "", "%s is set: run the tests in the development shell or in the check of the flake", VECTOR_FONT_SOURCES_VARIABLE)
	names := make([dynamic]string, context.temp_allocator)
	for candidate in vector_font_candidates {
		append(&names, candidate.name)
	}
	for candidate in vector_font_emphasis {
		append(&names, candidate.name)
	}
	for candidate in vector_font_interface {
		append(&names, candidate.name)
	}
	for candidate in vector_font_script_fallback {
		append(&names, candidate.name)
	}
	for name in names {
		path := ""
		rest := sources
		prefix := strings.concatenate({name, "="}, context.temp_allocator)
		for item in strings.split_iterator(&rest, ";") {
			if strings.has_prefix(item, prefix) {
				path = item[len(prefix):]
			}
		}
		if !testing.expectf(t, path != "", "%s names %s", VECTOR_FONT_SOURCES_VARIABLE, name) {
			continue
		}
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, read_error == nil, "%s can be read", path) {
			continue
		}
		face, face_problem := vector_font.collection_face_offset(bytes, 0)
		font, problem := vector_font.font_open(bytes, face)
		if !testing.expectf(t, face_problem == .None && problem == .None, "%s opens", name) {
			continue
		}
		lacks := strings.builder_make(context.temp_allocator)
		for glyph in 1 ..< SUBSET_GLYPHS {
			character := subset_character(glyph)
			_, taken_from, glyph_problem := subset_glyph_of(&font, character)
			testing.expectf(t, glyph_problem == .None, "%s has no glyph for U+%04X and no equivalent: %s", name, int(character), vector_font.font_problem_names[glyph_problem])
			if taken_from != character {
				fmt.sbprintf(&lacks, " U+%04X (drawn as U+%04X)", int(character), int(taken_from))
			}
		}
		fmt.printfln("modustool: %s: the %d characters of a cache; it lacks:%s", name, font_characters.CHARACTER_COUNT, strings.builder_len(lacks) == 0 ? " none" : strings.to_string(lacks))
		// The characters past the glyph cache that its subset holds: each
		// one with its own glyph, as no equivalent is such a character.
		past_cache_characters := past_cache_characters_of(name)
		for character in past_cache_characters {
			_, glyph_problem := vector_font.glyph_of(&font, character)
			testing.expectf(t, glyph_problem == .None, "%s has no glyph for U+%04X, a character past the glyph cache", name, int(character))
		}
		if len(past_cache_characters) > 0 {
			fmt.printfln("modustool: %s: %d characters past the glyph cache, each with its own glyph", name, len(past_cache_characters))
		}
	}
}
