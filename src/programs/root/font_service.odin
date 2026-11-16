package root

import "modus:contract/demand_cache"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/system"

// The font service (src/md/features/glyphs_on_demand.md): this service
// creates the demand cache, starts the program `glyphs` with it and a
// control ring, and gives each program that start gives a ring to the
// compositor a request ring to it (font_requests_give says which). The program maps
// the demand cache read-only and its request ring with Write, at their
// fixed ranges; the font service receives the ring with a Client_Add
// record. A program that stops is removed with Client_Remove.
//
// With no font service (absent from the boot image, or stopped), a program
// gets neither range, and draws the replacement glyph for each character
// past the glyph cache.

FONT_SERVICE_NAME :: "glyphs"

demand_cache_memory: system.Handle
font_service: ^Started // nil: no font service runs.
font_control: ring.Ring
font_control_memory: system.Handle

// The request ring of one program, as this service and the font service
// hold it.
Font_Client :: struct {
	item:       ^Started, // nil: a free place.
	memory:     system.Handle, // The ring, as this service holds it until the program stops.
	in_service: system.Handle, // The ring in the handle table of the font service.
	removal_lost: bool, // Its Client_Remove did not fit the control ring: the place stays taken in the font service.
}
font_clients: [STARTED_CAPACITY]Font_Client

// font_service_start creates the demand cache and the control ring, and
// starts the font service in a place of the table of the programs. A
// failure writes one line, and the system runs with no font service.
font_service_start :: proc "contextless" () {
	file := system.image_find(image, FONT_SERVICE_NAME)
	if len(file) == 0 {
		system.log_in("programs", .Info, "root: the boot image has no font service: the characters past the glyph cache draw the replacement glyph")
		return
	}
	slot: ^Started
	for &item in started {
		if item.program == 0 {
			slot = &item
			break
		}
	}
	if slot == nil {
		system.log_in("programs", .Warning, "root: no place for the font service: the characters past the glyph cache draw the replacement glyph")
		return
	}
	status: system.Status
	demand_cache_memory, status = system.memory_create(demand_cache.PAGE_COUNT)
	if status == .Ok {
		font_control_memory, font_control, status = system.ring_create()
		if status != .Ok {
			system.close(demand_cache_memory)
			demand_cache_memory = 0
		}
	}
	if status != .Ok {
		system.log_in("programs", .Warning, "root: cannot create the demand cache of the font service: status ", status, ": the characters past the glyph cache draw the replacement glyph")
		return
	}
	slot^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[demand_cache.SERVICE_GRANT_CACHE] = {demand_cache_memory, {.Read, .Write}}
	grants[demand_cache.SERVICE_GRANT_CONTROL] = {font_control_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = log_grant(FONT_SERVICE_NAME)
	slot.program, status = system.program_start(file, FONT_SERVICE_NAME, grants, random.values_with_seed(&program_generator, {}), budget_of(file, FONT_SERVICE_NAME), nil, &prepared)
	if status != .Ok {
		system.log_in("programs", .Warning, "root: cannot start the font service: status ", status, ": the characters past the glyph cache draw the replacement glyph")
		slot^ = {}
		system.ring_close(&font_control)
		system.close(font_control_memory)
		system.close(demand_cache_memory)
		font_control_memory, demand_cache_memory = 0, 0
		return
	}
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == FONT_SERVICE_NAME {
			slot.hash = item.hash
		}
	}
	slot.role = {.System_Part}
	copy(slot.name[:len(slot.name) - 1], FONT_SERVICE_NAME)
	font_service = slot
	started_log(FONT_SERVICE_NAME, principals.MACHINE, "")
}

// font_requests_give creates the request ring of a program that start gives
// a ring to the compositor: each program of the boot image but a program
// with a terminal, whether it opens a window or not. A program started
// from a disk, the compositor and the input service get none. It gives
// the ring to the font service, and adds the demand cache, read-only, and
// the ring, with Write, to the mappings of the program, with the bits of
// their ranges. The demand cache has no flag: the right Read only.
font_requests_give :: proc "contextless" (item: ^Started, name: string, mappings: []system.Mapping, count: ^int, values: ^[op.CONTEXT_VALUES]u64) {
	if font_service == nil || font_service.program == 0 {
		return
	}
	if count^ + 2 > len(mappings) {
		mapping_dropped_log("the demand cache and the request ring", len(mappings))
		return
	}
	place: ^Font_Client
	held := 0
	for &client in font_clients {
		if client.item != nil || client.removal_lost {
			held += 1
		} else if place == nil {
			place = &client
		}
	}
	if place == nil || held >= demand_cache.CLIENT_CAPACITY {
		system.log_in("programs", .Warning, "root: the font service serves ", u64(demand_cache.CLIENT_CAPACITY), " programs: ", system.Module_Name{name}, " draws the replacement glyph past the glyph cache that the demand cache does not hold")
		return
	}
	// Room in the control ring before the give: a handle given to the font
	// service that no Client_Add names would stay in its table for ever.
	// This service is the one writer of the ring, so the room stays.
	if ring.count(&font_control.commands) >= ring.capacity(&font_control.commands) {
		system.log_in("programs", .Warning, "root: the control ring of the font service is full: ", system.Module_Name{name}, " gets no request ring and no demand cache")
		return
	}
	memory, status := system.memory_create(demand_cache.REQUEST_RING_PAGES)
	if status != .Ok {
		return
	}
	in_service: system.Handle
	in_service, status = system.give(font_service.program, memory, {.Read, .Write})
	if status != .Ok {
		system.close(memory)
		return
	}
	packed := system.name_pack(name)
	if !system.send(&font_control.commands, ring.Record{kind = u32(demand_cache.Control_Kind.Client_Add), values = {0 = u64(in_service), 1 = packed[0], 2 = packed[1], 3 = packed[2], 4 = packed[3]}}) {
		// Not reached while this service is the one writer: the room was
		// checked above. The handle in the font service stays there.
		system.log_in("programs", .Warning, "root: the control ring of the font service is full after its check: ", system.Module_Name{name}, " gets no request ring, and one handle stays in the table of the font service")
		system.close(memory)
		return
	}
	place^ = {item = item, memory = memory, in_service = in_service}
	mappings[count^] = {memory = demand_cache_memory, address = demand_cache.ADDRESS, first = 0, page_count = demand_cache.PAGE_COUNT, flags = {}}
	mappings[count^ + 1] = {memory = memory, address = demand_cache.REQUESTS_ADDRESS, first = 0, page_count = demand_cache.REQUEST_RING_PAGES, flags = {.Write}}
	count^ += 2
	fixed_addresses.range_mapped_add(values, .Demand_Cache)
	fixed_addresses.range_mapped_add(values, .Glyph_Requests)
}

// font_service_end removes the request ring of a program that stopped, or
// that did not start. When the font service itself stopped, it forgets its
// control ring and each ring: the programs keep their mappings, and draw
// the replacement glyph for each character that they did not have.
font_service_end :: proc "contextless" (item: ^Started) {
	for &client in font_clients {
		if client.item == item {
			lost := false
			if font_service != nil && !system.send(&font_control.commands, ring.Record{kind = u32(demand_cache.Control_Kind.Client_Remove), values = {0 = u64(client.in_service)}}) {
				// The font service keeps the place of this ring: this
				// place stays counted, so no later program gets a ring
				// that the service has no place for.
				lost = true
				system.log_in("programs", .Warning, "root: the control ring of the font service is full: the removal of the ring of ", system.Module_Name{system.name_of(item.name[:])}, " is lost, and its place in the font service stays taken")
			}
			system.close(client.memory)
			client = {removal_lost = lost}
		}
	}
	if font_service == nil || item != font_service {
		return
	}
	system.log_in("programs", .Warning, "root: the font service stopped: the characters past the glyph cache that a program does not have draw the replacement glyph")
	for &client in font_clients {
		if client.item != nil {
			system.close(client.memory)
		}
		client = {}
	}
	system.ring_close(&font_control)
	system.close(font_control_memory)
	font_control_memory = 0
	font_service = nil
}
