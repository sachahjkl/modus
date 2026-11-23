package vector_font

// The walk of the scripts and the features of GSUB and GPOS, kept for a
// font (src/md/features/written_shaping.md, "The engine of the lookups"):
// layout_cache_fill walks each feature of the default language system of
// each script once, when the font opens; layout_lookups then reads the
// lookups of a feature from the cache with no walk. A cache is written by
// its fill only, before the font draws, so the threads of a process read
// it with no lock.

// The scripts of one table that a cache holds.
LAYOUT_CACHE_SCRIPT_LIMIT :: 16

// The lookups of one feature of one script of one table.
Layout_Cache_Entry :: struct {
	kind:   Layout_Kind,
	script: Feature_Tag,
	tag:    Feature_Tag,
	first:  u16, // The first of its lookup indices in Layout_Cache.indices.
	count:  u16,
}

Layout_Cache :: struct {
	entries:       []Layout_Cache_Entry, // The memory of the entries, from the owner of the font.
	indices:       []u16, // The memory of the lookup indices, from the owner.
	entry_count:   int,
	index_count:   int,
	scripts:       [Layout_Kind][LAYOUT_CACHE_SCRIPT_LIMIT]Feature_Tag, // The scripts of each table that have a default language system.
	script_counts: [Layout_Kind]int,
	complete:      [Layout_Kind]bool, // Each feature of each script of the table is in the cache; else layout_lookups walks the table.
}

// layout_cache_fill walks each table of a font into a cache, and gives the
// cache to the font. A table that does not fit the memory of the cache, or
// that a walk refuses, stays out of it: layout_lookups walks it.
layout_cache_fill :: proc "contextless" (font: ^Font_File, cache: ^Layout_Cache) {
	cache.entry_count, cache.index_count = 0, 0
	for kind in Layout_Kind {
		cache.complete[kind] = layout_cache_fill_table(font, cache, kind)
	}
	font.layout_cache = cache
}

@(private)
layout_cache_fill_table :: proc "contextless" (font: ^Font_File, cache: ^Layout_Cache, kind: Layout_Kind) -> bool {
	place := kind == .Substitution ? font.gsub : font.gpos
	cache.script_counts[kind] = 0
	if place.length == 0 {
		return true
	}
	if place.offset < 0 || place.length < 0 || place.offset + place.length > len(font.bytes) {
		return false
	}
	table := font.bytes[place.offset:][:place.length]
	script_list := part_at(table, read_u16(table, 4) or_return) or_return
	feature_list := part_at(table, read_u16(table, 6) or_return) or_return
	feature_count := read_u16(feature_list, 0) or_return
	script_count := read_u16(script_list, 0) or_return
	if script_count > LAYOUT_CACHE_SCRIPT_LIMIT {
		return false
	}
	for script_number in 0 ..< script_count {
		script_tag := tag_at(script_list, 2 + 6 * script_number) or_return
		script := part_at(script_list, read_u16(script_list, 6 + 6 * script_number) or_return) or_return
		default_offset := read_u16(script, 0) or_return
		if default_offset == 0 {
			continue
		}
		system := part_at(script, default_offset) or_return
		cache.scripts[kind][cache.script_counts[kind]] = script_tag
		cache.script_counts[kind] += 1
		for index_number in 0 ..< (read_u16(system, 4) or_return) {
			feature_index := read_u16(system, 6 + 2 * index_number) or_return
			if feature_index >= feature_count {
				return false
			}
			tag := tag_at(feature_list, 2 + 6 * feature_index) or_return
			if layout_cache_find(cache, kind, script_tag, tag) != nil {
				continue
			}
			// The walk itself gives the lookups, so the cache answers as it.
			lookups: Layout_Lookups
			if layout_lookups_walk(font, place, script_tag, script_tag, tag, &lookups) != .None {
				return false
			}
			if cache.entry_count == len(cache.entries) || cache.index_count + lookups.count > len(cache.indices) {
				return false
			}
			cache.entries[cache.entry_count] = {kind = kind, script = script_tag, tag = tag, first = u16(cache.index_count), count = u16(lookups.count)}
			cache.entry_count += 1
			copy(cache.indices[cache.index_count:], lookups.indices[:lookups.count])
			cache.index_count += lookups.count
		}
	}
	return true
}

@(private)
layout_cache_find :: proc "contextless" (cache: ^Layout_Cache, kind: Layout_Kind, script, tag: Feature_Tag) -> ^Layout_Cache_Entry {
	for &entry in cache.entries[:cache.entry_count] {
		if entry.kind == kind && entry.script == script && entry.tag == tag {
			return &entry
		}
	}
	return nil
}

// layout_cache_lookups answers layout_lookups from the cache of a font:
// found is false when the cache does not hold the table, and the caller
// walks it.
@(private)
layout_cache_lookups :: proc "contextless" (font: ^Font_File, place: Table, script, other_script, tag: Feature_Tag, out: ^Layout_Lookups) -> (problem: Font_Problem, found: bool) {
	cache := font.layout_cache
	if cache == nil {
		return .None, false
	}
	kind: Layout_Kind
	if place == font.gsub {
		kind = .Substitution
	} else if place == font.gpos {
		kind = .Positioning
	} else {
		return .None, false
	}
	if !cache.complete[kind] || place.length == 0 {
		return .None, false
	}
	chosen: Feature_Tag
	has := false
	for wanted in ([2]Feature_Tag{script, other_script}) {
		for present in cache.scripts[kind][:cache.script_counts[kind]] {
			if present == wanted {
				chosen, has = wanted, true
				break
			}
		}
		if has {
			break
		}
	}
	if !has {
		return .No_Feature, true
	}
	entry := layout_cache_find(cache, kind, chosen, tag)
	if entry == nil {
		return .No_Feature, true
	}
	out.count = 0
	for index in cache.indices[entry.first:][:entry.count] {
		lookup := layout_lookup_of(font, place, int(index)) or_return
		out.indices[out.count] = index
		out.parts[out.count] = lookup
		out.count += 1
	}
	return .None, true
}
