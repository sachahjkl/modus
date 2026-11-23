// The tables of the sources of the collector (src/md/features/wide_grants.md,
// "The starter pays for the audits"): no count of them is fixed. The links
// and the lists of tags that a pass fills grow together in arenas of the
// budget, never move, and hold one entry for each place of the table of the
// ends of the process, so input_tags and output_pairs always fit them.
package collector_service

import "base:intrinsics"
import "modus:contract/wide_grants"
import "modus:system"

Link_Tables :: struct {
	links:        system.Arena,
	held:         system.Arena,
	source_tags:  system.Arena,
	closed:       system.Arena,
	pair_tags:    system.Arena,
	pair_sources: system.Arena,
	made:         bool,
	count:        int,
}

link_tables: Link_Tables

// The lists of tags of a pass, one entry for each link.
source_tags: []u32
closed_tags: []u32
pair_tags: []u32
pair_source_tags: []u32

// link_tables_port gives the port of the links. The arenas are made at the
// first growth, from what the budget holds then.
link_tables_port :: proc "contextless" () -> wide_grants.Source_Links_Port {
	return {user = &link_tables, grow = links_grow}
}

// link_tables_ensure makes each table hold count entries. false: the
// budget does not pay them, and the tables stay as they were.
link_tables_ensure :: proc "contextless" (count: int) -> bool {
	tables := &link_tables
	if count <= tables.count {
		return true
	}
	if !tables.made {
		amounts, read := system.budget_read()
		if read != .Ok || amounts.pages == 0 {
			return false
		}
		pages := system.arena_reservation_pages(amounts.pages)
		arenas := [?]^system.Arena{&tables.links, &tables.held, &tables.source_tags, &tables.closed, &tables.pair_tags, &tables.pair_sources}
		for arena in arenas {
			made, status := system.arena_create(pages)
			if status != .Ok {
				return false
			}
			arena^ = made
		}
		tables.made = true
	}
	before := tables.count
	extend :: proc "contextless" (arena: ^system.Arena, $T: typeid, before, count: int) -> bool {
		size := u64(count - before) * size_of(T)
		added, status := system.arena_push(arena, size, align_of(T))
		if status != .Ok {
			return false
		}
		intrinsics.mem_zero(added, int(size))
		return true
	}
	// Each table grows by the same count, or the ones that grew give it
	// back, so the tables keep one length.
	done := 0
	grown := extend(&tables.links, wide_grants.Source_Link, before, count)
	if grown {
		done = 1
		grown = extend(&tables.held, u32, before, count)
	}
	tag_arenas := [?]^system.Arena{&tables.source_tags, &tables.closed, &tables.pair_tags, &tables.pair_sources}
	for arena in tag_arenas {
		if !grown {
			break
		}
		done += 1
		grown = extend(arena, u32, before, count)
	}
	if !grown {
		all := [?]^system.Arena{&tables.links, &tables.held, &tables.source_tags, &tables.closed, &tables.pair_tags, &tables.pair_sources}
		sizes := [?]u64{size_of(wide_grants.Source_Link), size_of(u32), size_of(u32), size_of(u32), size_of(u32), size_of(u32)}
		for index in 0 ..< done {
			_ = system.arena_pop(all[index], u64(count - before) * sizes[index])
		}
		return false
	}
	tables.count = count
	source_tags = ([^]u32)(tables.source_tags.base)[:count]
	closed_tags = ([^]u32)(tables.closed.base)[:count]
	pair_tags = ([^]u32)(tables.pair_tags.base)[:count]
	pair_source_tags = ([^]u32)(tables.pair_sources.base)[:count]
	// The wait of the loop holds a ring of a source and of a pair for each
	// place. A set that the budget does not pay keeps its places: the loop
	// then reads the rings past them at its retry period (sources_wait).
	_ = system.wait_set_grow(&collector_wait, collector_wait_words(count))
	return true
}

@(private = "file")
links_grow :: proc "contextless" (user: rawptr, count: int) -> (links: []wide_grants.Source_Link, held: []u32) {
	tables := (^Link_Tables)(user)
	if !link_tables_ensure(count) {
		return nil, nil
	}
	return ([^]wide_grants.Source_Link)(tables.links.base)[:tables.count], ([^]u32)(tables.held.base)[:tables.count]
}

// link_tables_follow_the_ends makes the lists of tags hold one entry for
// each place of the table of the ends: a pass lists that many rings. The
// links grow with them.
link_tables_follow_the_ends :: proc "contextless" () {
	if places := system.stream_end_places(); places > link_tables.count {
		if link_tables_ensure(places) {
			source_links.links = ([^]wide_grants.Source_Link)(link_tables.links.base)[:link_tables.count]
			source_links.held = ([^]u32)(link_tables.held.base)[:link_tables.count]
		}
	}
}
