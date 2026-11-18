package fallback_glyphs

import "modus:contract/glyph_cache"
import "modus:support/vector_font"

// The private glyph cache (src/md/features/glyphs_on_demand.md, "Layer 2:
// the private glyph cache"): the glyphs that this copy of the package drew,
// in its own memory,
// which the budget of the process pays. No other process reads it, so its
// content and its evictions tell nothing to another process.
//
// An entry is one glyph: its key (the face, the scale, the position and
// the code point) and its glyph entry in the form of a glyph cache. Its
// words take one run of blocks: BLOCK_WORDS words split and joined by
// halves, so a glyph is contiguous and a freed run joins its free
// neighbour. The order of use counts in frames: a glyph used in a frame
// goes to the newest end once in that frame, and a new glyph that finds no
// room evicts from the oldest end. A glyph that the renderer refuses has
// an entry with no words, so it is not drawn again at each frame.

WORD_CAPACITY :: 1 << 16 // The words of the glyphs: 256 KiB.
BLOCK_WORDS :: 32 // The words of the smallest block.
BLOCK_COUNT :: WORD_CAPACITY / BLOCK_WORDS
ORDER_COUNT :: 12 // The sizes of a block: BLOCK_WORDS << 0 to BLOCK_WORDS << 11, the whole words.
#assert(BLOCK_WORDS << (ORDER_COUNT - 1) == WORD_CAPACITY)
ENTRY_CAPACITY :: 1024 // The glyphs that the cache holds at most.
BUCKET_BITS :: 11
BUCKET_COUNT :: 1 << BUCKET_BITS // The places of the hash table: twice the entries.
// The largest glyph: a proportional glyph as wide as the widest glyph and
// as high as its line at scale 3. It fits one block of the largest size.
GLYPH_WORDS_LIMIT :: glyph_cache.GLYPH_WIDTH_LIMIT * glyph_cache.CELL_HEIGHT_LIMIT
#assert(GLYPH_WORDS_LIMIT <= WORD_CAPACITY)
// An index of an entry or a block is stored plus one: 0 is no index, so
// the cache of all zero is empty and valid.
#assert(ENTRY_CAPACITY < 1 << 16 && BLOCK_COUNT < 1 << 16)

Private_Entry :: struct {
	key:            u32, // key_of; 0: a free entry.
	glyph:          glyph_cache.Glyph_Entry, // word_offset: from the first word of the cache.
	frame:          u64, // The frame of its last use.
	newer, older:   u16, // Its neighbours in the order of use, plus one.
	next_in_bucket: u16, // The next entry of its place in the table, plus one; for a free entry, the next free entry.
	first_block:    u16, // The first block of its words.
	order:          u8, // The size of its run: BLOCK_WORDS << order words.
	has_words:      bool, // A glyph with no ink, and a glyph that the renderer refused, have no words.
	drawn:          bool, // false: the renderer refused its outline: the glyph is Missing.
}

Private_Cache :: struct {
	entries:         [ENTRY_CAPACITY]Private_Entry,
	entries_used:    int, // The entries taken once: the next new entry.
	free_entry:      u16, // The first free entry, plus one.
	buckets:         [BUCKET_COUNT]u16, // The first entry of each place, plus one.
	newest, oldest:  u16, // The two ends of the order of use, plus one.
	words:           [WORD_CAPACITY]u32,
	// For the first block of a free run: its order plus one; 0 for each
	// other block.
	free_order:      [BLOCK_COUNT]u8,
	free_next:       [BLOCK_COUNT]u16, // The next free run of its order, plus one.
	free_previous:   [BLOCK_COUNT]u16, // The free run before it, plus one.
	free_heads:      [ORDER_COUNT]u16, // The first free run of each order, plus one.
	words_ready:     bool, // The words are one free run: the first take makes it.
	counts:          Private_Counts,
}

// The counts of a private glyph cache, since the start of the process.
Private_Counts :: struct {
	drawn:          u64, // The glyphs drawn into the cache.
	refused:        u64, // The outlines that the renderer refused.
	evicted:        u64, // The glyphs that left the cache.
	evicted_in_use: u64, // Of them, the glyphs that the frame of their eviction had used: a working set larger than the cache.
}

// key_of gives the key of a glyph: never 0, as a face is never None.
key_of :: #force_inline proc "contextless" (face: Face, character: rune, scale, position: int) -> u32 {
	return u32(character) | u32(position) << 21 | u32(scale) << 23 | u32(face) << 25
}
#assert(int(max(Face)) < 1 << 7 && glyph_cache.SIZE_LIMIT < 4 && glyph_cache.POSITION_LIMIT <= 4)

@(private)
bucket_of :: #force_inline proc "contextless" (key: u32) -> int {
	return int((key * 2654435769) >> (32 - BUCKET_BITS))
}

// counts gives the counts of the private glyph cache of this copy.
counts :: proc "contextless" () -> Private_Counts {
	return private_cache.counts
}

// ---- The runs of blocks.

@(private)
free_push :: proc "contextless" (cache: ^Private_Cache, block, order: int) {
	head := cache.free_heads[order]
	cache.free_order[block] = u8(order + 1)
	cache.free_previous[block] = 0
	cache.free_next[block] = head
	if head != 0 {
		cache.free_previous[head - 1] = u16(block + 1)
	}
	cache.free_heads[order] = u16(block + 1)
}

@(private)
free_remove :: proc "contextless" (cache: ^Private_Cache, block, order: int) {
	previous, next := cache.free_previous[block], cache.free_next[block]
	if previous != 0 {
		cache.free_next[previous - 1] = next
	} else {
		cache.free_heads[order] = next
	}
	if next != 0 {
		cache.free_previous[next - 1] = previous
	}
	cache.free_order[block] = 0
	cache.free_previous[block] = 0
	cache.free_next[block] = 0
}

// order_of_words gives the order of the run that holds count words; ok is
// false past the whole words.
order_of_words :: proc "contextless" (count: int) -> (order: int, ok: bool) {
	if count < 1 || count > WORD_CAPACITY {
		return 0, false
	}
	blocks := (count + BLOCK_WORDS - 1) / BLOCK_WORDS
	for 1 << uint(order) < blocks {
		order += 1
	}
	return order, true
}

// run_take takes a free run of an order: the smallest free run at least as
// large, split by halves. ok is false when no run is that large.
@(private)
run_take :: proc "contextless" (cache: ^Private_Cache, order: int) -> (block: int, ok: bool) {
	if !cache.words_ready {
		cache.words_ready = true
		free_push(cache, 0, ORDER_COUNT - 1)
	}
	for found in order ..< ORDER_COUNT {
		if cache.free_heads[found] == 0 {
			continue
		}
		block = int(cache.free_heads[found] - 1)
		free_remove(cache, block, found)
		split := found
		for split > order {
			split -= 1
			free_push(cache, block + (1 << uint(split)), split)
		}
		return block, true
	}
	return 0, false
}

// run_give gives back a run, joined with its free neighbour of the same
// size while there is one.
@(private)
run_give :: proc "contextless" (cache: ^Private_Cache, block_given, order_given: int) {
	block, order := block_given, order_given
	for order < ORDER_COUNT - 1 {
		neighbour := block ~ (1 << uint(order))
		if int(cache.free_order[neighbour]) != order + 1 {
			break
		}
		free_remove(cache, neighbour, order)
		block = min(block, neighbour)
		order += 1
	}
	free_push(cache, block, order)
}

// ---- The entries.

@(private)
order_unlink :: proc "contextless" (cache: ^Private_Cache, index: int) {
	entry := &cache.entries[index]
	if entry.newer != 0 {
		cache.entries[entry.newer - 1].older = entry.older
	} else {
		cache.newest = entry.older
	}
	if entry.older != 0 {
		cache.entries[entry.older - 1].newer = entry.newer
	} else {
		cache.oldest = entry.newer
	}
	entry.newer, entry.older = 0, 0
}

@(private)
order_push_newest :: proc "contextless" (cache: ^Private_Cache, index: int) {
	entry := &cache.entries[index]
	entry.newer = 0
	entry.older = cache.newest
	if cache.newest != 0 {
		cache.entries[cache.newest - 1].newer = u16(index + 1)
	} else {
		cache.oldest = u16(index + 1)
	}
	cache.newest = u16(index + 1)
}

// entry_find gives the index of the entry of a key, or -1. The walk of a
// place ends after ENTRY_CAPACITY entries, whatever the links say.
@(private)
entry_find :: proc "contextless" (cache: ^Private_Cache, key: u32) -> int {
	next := cache.buckets[bucket_of(key)]
	for _ in 0 ..< ENTRY_CAPACITY {
		if next == 0 {
			return -1
		}
		entry := &cache.entries[next - 1]
		if entry.key == key {
			return int(next - 1)
		}
		next = entry.next_in_bucket
	}
	return -1
}

@(private)
bucket_unlink :: proc "contextless" (cache: ^Private_Cache, index: int) {
	place := &cache.buckets[bucket_of(cache.entries[index].key)]
	if place^ == u16(index + 1) {
		place^ = cache.entries[index].next_in_bucket
		return
	}
	next := place^
	for _ in 0 ..< ENTRY_CAPACITY {
		if next == 0 {
			return
		}
		entry := &cache.entries[next - 1]
		if entry.next_in_bucket == u16(index + 1) {
			entry.next_in_bucket = cache.entries[index].next_in_bucket
			return
		}
		next = entry.next_in_bucket
	}
}

// evict_oldest removes the entry used the longest time ago, and gives back
// its words. false: the cache holds no entry.
@(private)
evict_oldest :: proc "contextless" (cache: ^Private_Cache, frame: u64) -> bool {
	if cache.oldest == 0 {
		return false
	}
	index := int(cache.oldest - 1)
	entry := &cache.entries[index]
	order_unlink(cache, index)
	bucket_unlink(cache, index)
	if entry.has_words {
		run_give(cache, int(entry.first_block), int(entry.order))
	}
	cache.counts.evicted += 1
	if entry.frame == frame {
		cache.counts.evicted_in_use += 1
	}
	entry^ = {next_in_bucket = cache.free_entry}
	cache.free_entry = u16(index + 1)
	return true
}

// entry_take gives a free entry, out of the table and of the order: a
// free one, a new one, or the oldest, evicted.
@(private)
entry_take :: proc "contextless" (cache: ^Private_Cache, frame: u64) -> (index: int, ok: bool) {
	if cache.free_entry == 0 && cache.entries_used < ENTRY_CAPACITY {
		cache.entries_used += 1
		return cache.entries_used - 1, true
	}
	if cache.free_entry == 0 && !evict_oldest(cache, frame) {
		return 0, false
	}
	index = int(cache.free_entry - 1)
	cache.free_entry = cache.entries[index].next_in_bucket
	cache.entries[index] = {}
	return index, true
}

// entry_insert puts a new entry in the table and at the newest end.
@(private)
entry_insert :: proc "contextless" (cache: ^Private_Cache, index: int, key: u32, frame: u64) {
	entry := &cache.entries[index]
	entry.key = key
	entry.frame = frame
	place := &cache.buckets[bucket_of(key)]
	entry.next_in_bucket = place^
	place^ = u16(index + 1)
	order_push_newest(cache, index)
}

// entry_touch notes a use of an entry: it goes to the newest end once in
// each frame.
@(private)
entry_touch :: proc "contextless" (cache: ^Private_Cache, index: int, frame: u64) {
	entry := &cache.entries[index]
	if entry.frame == frame {
		return
	}
	entry.frame = frame
	order_unlink(cache, index)
	order_push_newest(cache, index)
}

// words_take gives a run for count words, evicting from the oldest end
// until one is free. The entry that the caller holds is in no list, so it
// is never evicted. ok is false only for a count past the whole words.
@(private)
words_take :: proc "contextless" (cache: ^Private_Cache, count: int, frame: u64) -> (block, order: int, ok: bool) {
	order = order_of_words(count) or_return
	for _ in 0 ..= ENTRY_CAPACITY {
		if block, ok = run_take(cache, order); ok {
			return block, order, true
		}
		if !evict_oldest(cache, frame) {
			break
		}
	}
	return 0, 0, false
}

// private_glyph gives the glyph of a character of a face from the private
// glyph cache, and draws it there at its first use.
@(private)
private_glyph :: proc "contextless" (face: Face, font: Outline_Font, character: rune, scale, position: int) -> (entry: glyph_cache.Glyph_Entry, words: [^]u32, source: Glyph_Source) {
	cache := &private_cache
	key := key_of(face, character, scale, position)
	if index := entry_find(cache, key); index >= 0 {
		entry_touch(cache, index, state.frame)
		found := &cache.entries[index]
		if !found.drawn {
			return {}, nil, .Missing
		}
		return found.glyph, ([^]u32)(&cache.words[found.glyph.word_offset]), .Private_Cache
	}
	index, taken := entry_take(cache, state.frame)
	if !taken {
		return {}, nil, .Missing
	}
	drawn, rows, width, first_row, left, source_words, stride := glyph_draw(face, font, character, scale, position)
	count := rows * width
	if !drawn {
		cache.counts.refused += 1
	} else if count > 0 {
		block, order, has_room := words_take(cache, count, state.frame)
		if !has_room {
			// Not reached: a glyph is at most GLYPH_WORDS_LIMIT words,
			// and the whole words are free once each entry is evicted.
			cache.entries[index] = {next_in_bucket = cache.free_entry}
			cache.free_entry = u16(index + 1)
			return {}, nil, .Missing
		}
		offset := block * BLOCK_WORDS
		for row in 0 ..< rows {
			copy(cache.words[offset + row * width:][:width], source_words[row * stride:][:width])
		}
		cache.entries[index].has_words = true
		cache.entries[index].first_block = u16(block)
		cache.entries[index].order = u8(order)
		cache.entries[index].glyph = {first_row = u16(first_row), row_count = u16(rows), word_offset = u32(offset), left = i16(left), width = u16(width)}
	}
	cache.entries[index].drawn = drawn
	entry_insert(cache, index, key, state.frame)
	if !drawn {
		return {}, nil, .Missing
	}
	cache.counts.drawn += 1
	return cache.entries[index].glyph, ([^]u32)(&cache.words[cache.entries[index].glyph.word_offset]), .Private_Cache
}

// glyph_draw draws one glyph of a font in the frame of a face, as the
// build draws a glyph of the cache of that face: a proportional glyph as
// the box of its ink at a position of the pixel, a glyph of cells cut to
// its cell with only its rows of ink. It gives the rows, the words of a
// row, the first row and the left side, and the first word of the box in
// the work memory with its words from one row to the next. drawn is false
// when the renderer refuses the outline.
@(private)
glyph_draw :: proc "contextless" (face: Face, font: Outline_Font, character: rune, scale, position: int) -> (drawn: bool, rows, width, first_row, left: int, words: []u32, stride: int) {
	form := face_forms[face]
	opened := &state.fonts[font]
	measures := measures_in_frame(face, font)
	style := style_of(face, scale)
	memory := &render_memory
	if form.proportional {
		box, problem := vector_font.glyph_render_placed(&opened.file, measures, style, character, position, form.positions[scale - 1], memory)
		if problem != .None {
			return false, 0, 0, 0, 0, nil, 0
		}
		if box.row_count == 0 {
			return true, 0, 0, 0, 0, nil, 0
		}
		start := box.first_row * vector_font.PLACED_WIDTH_LIMIT + box.first_column
		return true, box.row_count, box.width, box.first_row, box.left, memory.placed[start:], vector_font.PLACED_WIDTH_LIMIT
	}
	#assert(vector_font.PLACED_WIDTH_LIMIT >= vector_font.CELL_WIDTH_LIMIT)
	cell_width := style.cell_width
	pixels := memory.placed[:cell_width * style.cell_height]
	if vector_font.glyph_render(&opened.file, measures, style, character, memory, pixels) != .None {
		return false, 0, 0, 0, 0, nil, 0
	}
	first, last := style.cell_height, -1
	for row in 0 ..< style.cell_height {
		for word in pixels[row * cell_width:][:cell_width] {
			if word != 0 {
				first = min(first, row)
				last = max(last, row)
			}
		}
	}
	if last < first {
		return true, 0, 0, 0, 0, nil, 0
	}
	return true, last - first + 1, cell_width, first, 0, pixels[first * cell_width:], cell_width
}
