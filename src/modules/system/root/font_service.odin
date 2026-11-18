package root

import "modus:contract/demand_cache"
import op "modus:contract/operation"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/system"

// The font service and the demand cache (src/md/features/glyphs_on_demand.md):
// this service creates the demand cache with the text settings, before the
// compositor starts, then starts the process `glyphs` with it and with
// the font outlines. The font service draws the fixed subsets into the
// cache, then ends. Each process that gets the glyph caches gets the font
// outlines and the demand cache read-only (text_settings_give): it draws
// each other glyph past the glyph caches itself, in its private glyph
// cache. Nothing goes from a process to the font service, so this service
// keeps no handle for each process.
//
// With no font service in the boot image, there is no demand cache: each
// process draws each glyph past the glyph caches itself.

FONT_SERVICE_NAME :: "glyphs"

// This service keeps two handles for the font service: the demand cache,
// which it maps in each process that it starts, and the process of the
// service while it runs. Its handle table also holds the process of each
// process that runs, its rings, and the parts of the prepared modules (up
// to 64), and a full table refuses the load of the next process
// (memory_create of a writable segment gives No_Slot).
demand_cache_memory: system.Handle
font_service: ^Started // nil: no font service runs.

// demand_cache_create creates the demand cache when the boot image has a
// font service. The text settings call it before the compositor starts,
// so the compositor gets it too. A failure writes one line, and each
// process draws its glyphs past the glyph caches itself.
demand_cache_create :: proc "contextless" () {
	if len(system.image_find(image, FONT_SERVICE_NAME)) == 0 {
		system.log_in("processes", .Info, "root: the boot image has no font service: each process draws its glyphs past the glyph caches itself")
		return
	}
	status: system.Status
	demand_cache_memory, status = system.memory_create(demand_cache.PAGE_COUNT)
	if status != .Ok {
		demand_cache_memory = 0
		system.log_in("processes", .Warning, "root: cannot create the demand cache: status ", status, ": each process draws its glyphs past the glyph caches itself")
	}
}

// font_service_start starts the font service in a place of the table of
// the processes, with the demand cache with Write and the font outlines
// read-only. A failure writes one line; the demand cache then stays empty,
// and each process draws its glyphs past the glyph caches itself. A start
// policy asks for it, and gets the status.
font_service_start :: proc "contextless" () -> system.Status {
	file := system.image_find(image, FONT_SERVICE_NAME)
	if len(file) == 0 || demand_cache_memory == 0 {
		return .Bad_Handle
	}
	if font_outlines_mapping.page_count == 0 {
		system.log_in("processes", .Warning, "root: the boot image has no valid font outlines: the font service does not start")
		return .Bad_State
	}
	slot: ^Started
	for &item in started {
		if place_is_free(&item) {
			slot = &item
			break
		}
	}
	if slot == nil {
		system.log_in("processes", .Warning, "root: no place for the font service: each process draws its glyphs past the glyph caches itself")
		return .No_Slot
	}
	slot^ = {}
	role := role_of(FONT_SERVICE_NAME)
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, demand_cache.SERVICE_GRANT_CACHE, {demand_cache_memory, {.Read, .Write}})
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(role))
	// The outlines, read-only, from the boot image: the mapping has no flag.
	mappings := [1]system.Mapping{font_outlines_mapping}
	mappings[0].flags = {}
	system.range_mapped_put(&values, .Font_Outlines)
	if context_refused(FONT_SERVICE_NAME, &context_grants, &values) {
		return .Bad_State
	}
	status: system.Status
	slot.process, status = system.process_start(file, FONT_SERVICE_NAME, context_grants.grants, random.values_with_seed(&process_generator, values.values), budget_of(file, FONT_SERVICE_NAME), mappings[:], &prepared)
	if status != .Ok {
		system.log_in("processes", .Warning, "root: cannot start the font service: status ", status, ": each process draws its glyphs past the glyph caches itself")
		slot^ = {}
		return status
	}
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == FONT_SERVICE_NAME {
			slot.hash = item.hash
		}
	}
	slot.role = role
	copy(slot.name[:len(slot.name) - 1], FONT_SERVICE_NAME)
	font_service = slot
	started_log(FONT_SERVICE_NAME, principals.MACHINE, "")
	return .Ok
}

// demand_cache_give adds the demand cache, read-only, to the mappings of a
// process, with the bit of its range. The mapping uses the handle that this
// service keeps for the cache: it adds no handle. The cache holds what the
// font service published: whole entries only, from its first to its last.
demand_cache_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if demand_cache_memory == 0 {
		return
	}
	if count^ + 1 > len(mappings) {
		mapping_dropped_log("the demand cache", len(mappings))
		return
	}
	mappings[count^] = {memory = demand_cache_memory, address = demand_cache.ADDRESS, first = 0, page_count = demand_cache.PAGE_COUNT, flags = {}}
	count^ += 1
	system.range_mapped_put(values, .Demand_Cache)
}

// font_service_end forgets the font service when it stopped. Its work ends
// at its start: a stop with the code 0 is its end. The demand cache stays,
// with what it published, and each process keeps its mapping.
font_service_end :: proc "contextless" (item: ^Started) {
	if font_service == nil || item != font_service {
		return
	}
	font_service = nil
}
