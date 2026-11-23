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

// The reads of all the walks of one fill: a fill past them is refused.
// The fill of a font of the script font set reads at most 5 595 (Noto Sans
// Bengali; the test the_cache_of_each_font_of_the_set prints each).
LAYOUT_FILL_READ_LIMIT :: 1 << 17

// Layout_Cache_Fill_Status: the outcome of filling a font's layout cache.
Layout_Cache_Fill_Status :: enum u8 {
	Complete  = 0, // Both tables passed validation and fit the inline pool; font.layout_cache is set.
	Pool_Full = 1, // Both tables passed validation and LAYOUT_FILL_READ_LIMIT, but did not fit the inline pool; font walks tables uncached.
	Refused   = 2, // A table is malformed, a walk refused it, or it passed LAYOUT_FILL_READ_LIMIT.
}

// layout_cache_fill walks each table of a font into a cache, and gives the
// cache to the font when both tables fit it. Pool_Full means both tables
// passed validation and LAYOUT_FILL_READ_LIMIT, so the font can stay open on
// the slower uncached walk path; Refused means a table is malformed or passed
// LAYOUT_FILL_READ_LIMIT, so the caller refuses the font.
layout_cache_fill :: proc "contextless" (font: ^Font_File, cache: ^Layout_Cache) -> (status: Layout_Cache_Fill_Status, reads: int) {
	cache.entry_count, cache.index_count = 0, 0
	status = .Complete
	for kind in Layout_Kind {
		table_status := layout_cache_fill_table(font, cache, kind, &reads)
		cache.complete[kind] = table_status == .Complete
		if table_status == .Refused {
			status = .Refused
		} else if table_status == .Pool_Full && status == .Complete {
			status = .Pool_Full
		}
	}
	if status == .Complete {
		font.layout_cache = cache
	} else {
		font.layout_cache = nil
	}
	return status, reads
}

@(private)
layout_cache_fill_table :: proc "contextless" (font: ^Font_File, cache: ^Layout_Cache, kind: Layout_Kind, reads: ^int) -> Layout_Cache_Fill_Status {
	place := kind == .Substitution ? font.gsub : font.gpos
	cache.script_counts[kind] = 0
	if place.length == 0 {
		return .Complete
	}
	if place.offset < 0 || place.length < 0 || place.offset + place.length > len(font.bytes) {
		return .Refused
	}
	table := font.bytes[place.offset:][:place.length]
	script_list_offset, ok1 := read_u16(table, 4)
	feature_list_offset, ok2 := read_u16(table, 6)
	if !ok1 || !ok2 {
		return .Refused
	}
	script_list, ok3 := part_at(table, script_list_offset)
	feature_list, ok4 := part_at(table, feature_list_offset)
	if !ok3 || !ok4 {
		return .Refused
	}
	feature_count, ok5 := read_u16(feature_list, 0)
	script_count, ok6 := read_u16(script_list, 0)
	if !ok5 || !ok6 {
		return .Refused
	}
	pool_full := script_count > LAYOUT_CACHE_SCRIPT_LIMIT
	// The walk takes the first record of a tag and stops there: a later
	// record of the same tag is never read, so the cache skips it too.
	seen: [LAYOUT_CACHE_SCRIPT_LIMIT]Feature_Tag
	seen_count := 0
	scripts: for script_number in 0 ..< script_count {
		reads^ += 1
		if reads^ > LAYOUT_FILL_READ_LIMIT {
			return .Refused
		}
		script_tag, tag_ok := tag_at(script_list, 2 + 6 * script_number)
		if !tag_ok {
			return .Refused
		}
		if script_count <= LAYOUT_CACHE_SCRIPT_LIMIT {
			for earlier in seen[:seen_count] {
				if earlier == script_tag {
					continue scripts
				}
			}
			seen[seen_count] = script_tag
			seen_count += 1
		} else {
			for earlier_number in 0 ..< script_number {
				reads^ += 1
				if reads^ > LAYOUT_FILL_READ_LIMIT {
					return .Refused
				}
				earlier_tag, earlier_ok := tag_at(script_list, 2 + 6 * earlier_number)
				if !earlier_ok {
					return .Refused
				}
				if earlier_tag == script_tag {
					continue scripts
				}
			}
		}
		script_offset, soff_ok := read_u16(script_list, 6 + 6 * script_number)
		if !soff_ok {
			return .Refused
		}
		script, script_ok := part_at(script_list, script_offset)
		if !script_ok {
			return .Refused
		}
		default_offset, doff_ok := read_u16(script, 0)
		if !doff_ok {
			return .Refused
		}
		if default_offset == 0 {
			continue
		}
		system, sys_ok := part_at(script, default_offset)
		if !sys_ok {
			return .Refused
		}
		if !pool_full {
			cache.scripts[kind][cache.script_counts[kind]] = script_tag
			cache.script_counts[kind] += 1
		}
		index_count, ic_ok := read_u16(system, 4)
		if !ic_ok {
			return .Refused
		}
		for index_number in 0 ..< index_count {
			reads^ += 1
			if reads^ > LAYOUT_FILL_READ_LIMIT {
				return .Refused
			}
			feature_index, fi_ok := read_u16(system, 6 + 2 * index_number)
			if !fi_ok || feature_index >= feature_count {
				return .Refused
			}
			tag, ftag_ok := tag_at(feature_list, 2 + 6 * feature_index)
			if !ftag_ok {
				return .Refused
			}
			if !pool_full && layout_cache_find(cache, kind, script_tag, tag) != nil {
				continue
			}
			// The walk itself gives the lookups, so the cache answers as it.
			lookups: Layout_Lookups
			if layout_lookups_walk(font, place, script_tag, script_tag, tag, &lookups, reads) != .None || reads^ > LAYOUT_FILL_READ_LIMIT {
				return .Refused
			}
			if pool_full || cache.entry_count == len(cache.entries) || cache.index_count + lookups.count > len(cache.indices) {
				pool_full = true
				continue
			}
			cache.entries[cache.entry_count] = {kind = kind, script = script_tag, tag = tag, first = u16(cache.index_count), count = u16(lookups.count)}
			cache.entry_count += 1
			copy(cache.indices[cache.index_count:], lookups.indices[:lookups.count])
			cache.index_count += lookups.count
		}
	}
	return pool_full ? .Pool_Full : .Complete
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
	indices: []u16
	indices, problem, found = layout_cache_indices(font, place, script, other_script, tag)
	if !found || problem != .None {
		return problem, found
	}
	out.count = 0
	for index in indices[:min(len(indices), SUBSTITUTION_LOOKUP_LIMIT)] {
		lookup := layout_lookup_of(font, place, int(index)) or_return
		out.indices[out.count] = index
		out.parts[out.count] = lookup
		out.count += 1
	}
	return .None, true
}

// layout_cache_indices gives the lookup indices of a feature from the cache
// of a font, in place: found is false when the cache does not hold the
// table, and the caller walks it.
@(private)
layout_cache_indices :: proc "contextless" (font: ^Font_File, place: Table, script, other_script, tag: Feature_Tag) -> (indices: []u16, problem: Font_Problem, found: bool) {
	cache := font.layout_cache
	if cache == nil {
		return nil, .None, false
	}
	kind: Layout_Kind
	if place == font.gsub {
		kind = .Substitution
	} else if place == font.gpos {
		kind = .Positioning
	} else {
		return nil, .None, false
	}
	if !cache.complete[kind] || place.length == 0 {
		return nil, .None, false
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
		return nil, .No_Feature, true
	}
	entry := layout_cache_find(cache, kind, chosen, tag)
	if entry == nil {
		return nil, .No_Feature, true
	}
	return cache.indices[entry.first:][:entry.count], .None, true
}

// layout_feature_indices gives the lookup indices of a feature, in the
// order of the lookup list: from the cache of the font in place, else
// walked into room; used is the part of room that they take.
layout_feature_indices :: proc "contextless" (font: ^Font_File, place: Table, script, other_script, tag: Feature_Tag, room: []u16) -> (indices: []u16, used: int, problem: Font_Problem) {
	if cached, cached_problem, found := layout_cache_indices(font, place, script, other_script, tag); found {
		return cached, 0, cached_problem
	}
	return layout_feature_indices_walked(font, place, script, other_script, tag, room)
}

// layout_feature_indices_walked walks a feature into room. Its lookups are
// on its own frame, which ends before the caller applies them.
@(private)
layout_feature_indices_walked :: #force_no_inline proc "contextless" (font: ^Font_File, place: Table, script, other_script, tag: Feature_Tag, room: []u16) -> (indices: []u16, used: int, problem: Font_Problem) {
	lookups: Layout_Lookups
	reads := 0
	problem = layout_lookups_walk(font, place, script, other_script, tag, &lookups, &reads)
	if problem != .None {
		return nil, 0, problem
	}
	if lookups.count > len(room) {
		return nil, 0, .Too_Much_Work
	}
	copy(room, lookups.indices[:lookups.count])
	return room[:lookups.count], lookups.count, .None
}
