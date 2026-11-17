package modustool

import "core:mem"
import "core:slice"
import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"

// The fuzz target of the demand cache (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the font service writes it while each
// program with text reads it. A reader copies each entry once and checks
// it against the constants of the contract, so a wrong entry draws the
// replacement glyph and is never a read outside the cache.

// One entry of an input, and its place: the home place of its key plus its
// probe. A probe of PROBE_LIMIT or more puts the entry where no search
// reads it.
Fuzz_Demand_Placed_Entry :: struct {
	probe:    u8,
	reserved: [7]u8,
	entry:    demand_cache.Entry,
}
#assert(size_of(Fuzz_Demand_Placed_Entry) == 8 + demand_cache.ENTRY_SIZE)

FUZZ_DEMAND_ENTRY_LIMIT :: 64
FUZZ_DEMAND_INPUT_LIMIT :: demand_cache.HEADER_SIZE + FUZZ_DEMAND_ENTRY_LIMIT * size_of(Fuzz_Demand_Placed_Entry)

// The memory of a demand cache, on a page, for the process. Each execution
// writes the header and its places, and clears them after.
@(private = "file")
fuzz_demand_memory: []u8

fuzz_demand_cache_start :: proc() -> bool {
	memory, error := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	fuzz_demand_memory = memory
	return error == nil && len(memory) == demand_cache.SIZE
}

@(private = "file")
fuzz_demand_entries :: proc() -> []demand_cache.Entry {
	return ([^]demand_cache.Entry)(&fuzz_demand_memory[demand_cache.ENTRIES_OFFSET])[:demand_cache.ENTRY_CAPACITY]
}

@(private = "file")
fuzz_demand_words :: proc() -> []u32 {
	return ([^]u32)(&fuzz_demand_memory[demand_cache.WORDS_OFFSET])[:demand_cache.WORD_CAPACITY]
}

// fuzz_demand_character_of gives the face and the character of a key, or
// false for a key that names no face.
@(private = "file")
fuzz_demand_character_of :: proc(key: u32) -> (face: demand_cache.Face, character: rune, ok: bool) {
	word := key >> demand_cache.KEY_FACE_SHIFT
	if word >= len(demand_cache.Face) {
		return {}, 0, false
	}
	return demand_cache.Face(word), rune(key & (1 << demand_cache.KEY_FACE_SHIFT - 1)), true
}

fuzz_demand_cache_execute :: proc(input: []u8) -> Fuzz_Verdict {
	header_bytes := fuzz_demand_memory[:demand_cache.HEADER_SIZE]
	copy(header_bytes, input)
	entries := fuzz_demand_entries()
	places := make([dynamic]int, context.temp_allocator)
	rest := input[min(len(input), demand_cache.HEADER_SIZE):]
	for index in 0 ..< min(len(rest) / size_of(Fuzz_Demand_Placed_Entry), FUZZ_DEMAND_ENTRY_LIMIT) {
		placed: Fuzz_Demand_Placed_Entry
		mem.copy(&placed, &rest[index * size_of(placed)], size_of(placed))
		place := (demand_cache.home_place_of(placed.entry.key) + int(placed.probe)) & (demand_cache.ENTRY_CAPACITY - 1)
		entries[place] = placed.entry
		append(&places, place)
	}
	defer {
		slice.zero(header_bytes)
		for place in places {
			entries[place] = {}
		}
	}
	header_before := slice.clone(header_bytes, context.temp_allocator)
	entries_before := make([]demand_cache.Entry, len(places), context.temp_allocator)
	for place, index in places {
		entries_before[index] = entries[place]
	}
	found := make([dynamic]demand_cache.Entry, context.temp_allocator)
	if verdict := fuzz_demand_readers_check(places[:], &found); verdict.oracle != .None {
		return verdict
	}
	if !slice.equal(header_before, header_bytes) {
		return fuzz_broken(.Contract, "a reader changed the header of the cache")
	}
	for place, index in places {
		if entries[place] != entries_before[index] {
			return fuzz_broken(.Contract, "a reader changed the entry at the place %d", place)
		}
	}
	return fuzz_demand_writer_check(found[:], places[:])
}

// fuzz_demand_readers_check runs the reader of each face: the limit of a
// frame is the generation of a header with the magic, the version, the
// font file and the flags of the face, else 0; a find of a character that
// is no code point finds nothing; an entry that find gives Drawn is the
// entry of its face and character, of a generation of the frame, whose
// glyphs read words of the cache only.
@(private = "file")
fuzz_demand_readers_check :: proc(places: []int, found: ^[dynamic]demand_cache.Entry) -> Fuzz_Verdict {
	base := uintptr(raw_data(fuzz_demand_memory))
	header := (^demand_cache.Header)(base)
	entries := fuzz_demand_entries()
	words := fuzz_demand_words()
	for face in demand_cache.Face {
		face_header := header.faces[face]
		reader, ok := demand_cache.reader_of(base, face, face_header.font_hash, face_header.flags)
		if !ok {
			return fuzz_broken(.Contract, "reader_of refuses the base of a page")
		}
		demand_cache.reader_frame_begin(&reader)
		expected: u64
		if header.magic == demand_cache.MAGIC && header.version == demand_cache.VERSION {
			expected = header.generation
		}
		if reader.generation_limit != expected {
			return fuzz_broken(.Contract, "the frame of the face %v has the limit %d, not %d", face, reader.generation_limit, expected)
		}
		// Another font file: the reader finds nothing.
		other_hash := face_header.font_hash
		other_hash[0] ~= 1
		other, _ := demand_cache.reader_of(base, face, other_hash, face_header.flags)
		demand_cache.reader_frame_begin(&other)
		if other.generation_limit != 0 {
			return fuzz_broken(.Contract, "a reader of another font file has the limit %d", other.generation_limit)
		}
		characters := make([dynamic]rune, context.temp_allocator)
		append(&characters, 0, -1, text_encoding.CODE_POINT_LAST + 1, max(rune))
		for place in places {
			if entry_face, character, named := fuzz_demand_character_of(entries[place].key); named && entry_face == face {
				append(&characters, character)
			}
		}
		for character in characters {
			entry, state := demand_cache.find(&reader, character)
			valid_character := character > 0 && character <= text_encoding.CODE_POINT_LAST
			switch state {
			case .Empty:
				if entry != (demand_cache.Entry{}) {
					return fuzz_broken(.Contract, "find gives Empty and an entry for %x", character)
				}
			case .Absent:
				if !valid_character {
					return fuzz_broken(.Contract, "find gives Absent for %x, which is no code point", character)
				}
			case .Drawn:
				if !valid_character || entry.key != demand_cache.key_of(face, character) || entry.generation == 0 || entry.generation > reader.generation_limit || !demand_cache.entry_valid(face, &entry) {
					return fuzz_broken(.Contract, "find gives Drawn for %x: the key %x, the generation %d of %d", character, entry.key, entry.generation, reader.generation_limit)
				}
				if verdict := fuzz_demand_glyphs_check(face, &entry, words); verdict.oracle != .None {
					return verdict
				}
				append(found, entry)
			case:
				return fuzz_broken(.Contract, "find gives a state out of its enumeration: %d", u32(state))
			}
		}
	}
	return FUZZ_PASSED
}

// fuzz_demand_glyphs_check reads the words of each glyph of a checked
// entry, as a draw does, and each place of glyph_of_entry.
@(private = "file")
fuzz_demand_glyphs_check :: proc(face: demand_cache.Face, entry: ^demand_cache.Entry, words: []u32) -> Fuzz_Verdict {
	for scale in -1 ..= demand_cache.SIZE_COUNT + 1 {
		positions := demand_cache.position_count_of(face, scale)
		for position in -1 ..= demand_cache.POSITIONS_AT_SCALE_ONE {
			glyph, ok := demand_cache.glyph_of_entry(face, entry, scale, position)
			if ok != (position >= 0 && position < positions) {
				return fuzz_broken(.Contract, "glyph_of_entry gives %v for the scale %d and the position %d of %d", ok, scale, position, positions)
			}
			if !ok {
				if glyph != (glyph_cache.Glyph_Entry{}) {
					return fuzz_broken(.Contract, "glyph_of_entry refuses and gives a glyph")
				}
				continue
			}
			start := int(glyph.word_offset)
			end := start + int(glyph.row_count) * int(glyph.width)
			total: u32
			for word in words[start:end] {
				total += word
			}
			_ = total
		}
	}
	return FUZZ_PASSED
}

// fuzz_demand_writer_check writes each entry that the readers found into a
// new cache with the writer of the font service: a reader then finds each
// one Drawn, with its advances and its glyphs.
@(private = "file")
fuzz_demand_writer_check :: proc(found: []demand_cache.Entry, places: []int) -> Fuzz_Verdict {
	if len(found) == 0 {
		return FUZZ_PASSED
	}
	base := uintptr(raw_data(fuzz_demand_memory))
	header := (^demand_cache.Header)(base)
	faces := header.faces
	// The header and the entries of the input go first: the writer starts
	// on a cache with no entry.
	slice.zero(fuzz_demand_memory[:demand_cache.HEADER_SIZE])
	entries := fuzz_demand_entries()
	for place in places {
		entries[place] = {}
	}
	written := make([dynamic]int, context.temp_allocator)
	defer {
		slice.zero(fuzz_demand_memory[:demand_cache.HEADER_SIZE])
		for place in written {
			entries[place] = {}
		}
	}
	writer := demand_cache.writer_open(base, 1, faces)
	published := make([dynamic]demand_cache.Entry, context.temp_allocator)
	for entry in found {
		face, character, _ := fuzz_demand_character_of(entry.key)
		place, search := demand_cache.place_find(&writer, face, character)
		switch search {
		case .Free:
			demand_cache.publish(&writer, place, face, character, entry)
			append(&written, place)
			append(&published, entry)
		case .Published, .Full:
		}
	}
	for entry in published {
		face, character, _ := fuzz_demand_character_of(entry.key)
		reader, _ := demand_cache.reader_of(base, face, faces[face].font_hash, faces[face].flags)
		demand_cache.reader_frame_begin(&reader)
		again, state := demand_cache.find(&reader, character)
		if state != .Drawn || again.advances != entry.advances || again.glyphs != entry.glyphs {
			return fuzz_broken(.Round_Trip, "an entry that the writer published reads as %v", state)
		}
	}
	return FUZZ_PASSED
}

// fuzz_demand_entry_of gives an entry of a face that its check accepts.
@(private = "file")
fuzz_demand_entry_of :: proc(face: demand_cache.Face, character: rune, generation: u64) -> (entry: demand_cache.Entry) {
	entry.key = demand_cache.key_of(face, character)
	entry.state = .Drawn
	entry.generation = generation
	form := demand_cache.face_forms[face]
	for scale in 1 ..= form.scale_count {
		cell_width := demand_cache.CELL_WIDTH_AT_SCALE_ONE * scale
		entry.advances[scale - 1] = i32(cell_width * glyph_cache.SUBPIXEL)
		for position in 0 ..< demand_cache.position_count_of(face, scale) {
			place, _ := demand_cache.glyph_place_of(scale, position)
			entry.glyphs[place] = {first_row = 0, row_count = u16(demand_cache.LINE_HEIGHT_AT_SCALE_ONE * scale), word_offset = u32(demand_cache.WORD_CAPACITY - demand_cache.LINE_HEIGHT_AT_SCALE_ONE * scale * cell_width), width = u16(cell_width)}
		}
	}
	return entry
}

fuzz_demand_cache_seeds :: proc(seeds: ^[dynamic][]u8) {
	header: demand_cache.Header
	header.magic, header.version, header.generation = demand_cache.MAGIC, demand_cache.VERSION, 3
	for face in demand_cache.Face {
		header.faces[face].font_hash[0] = u8(face) + 1
		header.faces[face].flags = u32(face)
	}
	placed := make([dynamic]Fuzz_Demand_Placed_Entry, context.temp_allocator)
	// A drawn entry of each face, at its home place and one probe after
	// it; one of a generation past the frame; one Absent; one at the last
	// probe and one past it; a key of no face.
	generation := u64(1)
	for face in demand_cache.Face {
		character := demand_cache.subset_of(face)[0].first
		append(&placed, Fuzz_Demand_Placed_Entry{entry = fuzz_demand_entry_of(face, character, generation)})
		append(&placed, Fuzz_Demand_Placed_Entry{probe = 1, entry = fuzz_demand_entry_of(face, character + 1, generation)})
		generation = generation % 3 + 1
	}
	append(&placed, Fuzz_Demand_Placed_Entry{entry = fuzz_demand_entry_of(.Cells, 0x2500, 4)})
	absent := fuzz_demand_entry_of(.Cells, 0x2501, 1)
	absent.state = .Absent
	append(&placed, Fuzz_Demand_Placed_Entry{entry = absent})
	append(&placed, Fuzz_Demand_Placed_Entry{probe = demand_cache.PROBE_LIMIT - 1, entry = fuzz_demand_entry_of(.Cells, 0x2502, 1)})
	append(&placed, Fuzz_Demand_Placed_Entry{probe = demand_cache.PROBE_LIMIT, entry = fuzz_demand_entry_of(.Cells, 0x2503, 1)})
	wrong := fuzz_demand_entry_of(.Cells, 0x2504, 1)
	wrong.key = u32(len(demand_cache.Face)) << demand_cache.KEY_FACE_SHIFT | 0x2504
	append(&placed, Fuzz_Demand_Placed_Entry{entry = wrong})
	seed := make([dynamic]u8)
	append(&seed, ..mem.ptr_to_bytes(&header))
	append(&seed, ..slice.to_bytes(placed[:]))
	append(seeds, seed[:])
	// The same cache with no magic, and with another version.
	for change in 0 ..< 2 {
		other := slice.clone(seed[:])
		changed := header
		if change == 0 {
			changed.magic = 0
		} else {
			changed.version = demand_cache.VERSION + 1
		}
		copy(other, mem.ptr_to_bytes(&changed))
		append(seeds, other)
	}
}

fuzz_demand_cache_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < demand_cache.HEADER_SIZE {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = demand_cache.Header, count = 1})
	count := min((len(input) - demand_cache.HEADER_SIZE) / size_of(Fuzz_Demand_Placed_Entry), FUZZ_DEMAND_ENTRY_LIMIT)
	if count > 0 {
		append(regions, Fuzz_Region{offset = demand_cache.HEADER_SIZE, type = Fuzz_Demand_Placed_Entry, count = count})
	}
}
