// The picker of the trusted display, on the side of this service
// (src/md/features/powerbox.md, "The picker ring"): the picker ring and
// its region, made at the start of the holder of Display and given to the
// powerbox at its start; the start of the powerbox after the holder of
// Display; and the one connection that lists the stores of a principal.
// That connection acts for the principal and reads only; this service
// makes it when the powerbox asks, gives its handles to the powerbox for
// one call of `stores`, and ends it when the powerbox says that the call
// ended, or at its bound.
package root

import "modus:contract/powerbox"
import "modus:contract/root_ring"
import "modus:contract/ring"
import "modus:disk_process"
import "modus:principals"
import "modus:system"

// The ring and the region between the holder of Display and the
// powerbox: made once, so a holder or a powerbox that starts again finds
// the ring of the other.
picker_ring_memory: system.Handle
picker_region_memory: system.Handle

// The ring of this service to the powerbox, and its region, made at each
// start of the powerbox.
powerbox_ring: ring.Ring
powerbox_ring_memory: system.Handle
powerbox_region_memory: system.Handle
powerbox_holder: ^Started
powerbox_next_tag: u32

// The caller of the connection that lists the stores: its name is the
// name of the store of the module files, as for the debug store reader,
// and grant_for gives it the grant to act for its principal and to read
// only.
picker_store_lister: Started

// The bound of one listing: the bound of the powerbox for the call, and
// the same again for its answer to come back.
PICKER_LISTING_BOUND_MILLISECONDS :: 2 * 10_000

Picker_Listing :: struct {
	connection: ^Connection,
	tag:        u32,
	deadline:   u64,
}

picker_listing: Picker_Listing

// picker_rings_make makes the picker ring and its region, once.
picker_rings_make :: proc "contextless" () -> bool {
	if picker_ring_memory != 0 {
		return true
	}
	memory, opened, status := system.ring_create()
	if status != .Ok {
		return false
	}
	// This service reads no record of the ring: the display and the
	// powerbox map it.
	system.ring_close(&opened)
	region, region_status := system.memory_create(powerbox.PICKER_REGION_PAGES)
	if region_status != .Ok {
		system.close(memory)
		return false
	}
	picker_ring_memory, picker_region_memory = memory, region
	return true
}

// display_picker_grants_put gives the holder of Display its end of the
// picker ring and the region. With no ring, the holder starts with no
// picker of stores.
display_picker_grants_put :: proc "contextless" (context_grants: ^system.Context_Grants) {
	if !picker_rings_make() {
		return
	}
	system.grant_put(context_grants, powerbox.DISPLAY_PICKER_RING_SLOT, {picker_ring_memory, {.Read, .Write}})
	system.grant_put(context_grants, powerbox.DISPLAY_PICKER_REGION_SLOT, {picker_region_memory, {.Read, .Write}})
}

// powerbox_context_give gives the powerbox its rings, its regions, the
// boot image and the slot of the holder of Display. Its ring from this
// service is new at each start: a ring of a powerbox that stopped holds
// records that no process reads.
powerbox_context_give :: proc "contextless" (work: ^Start_Work) {
	powerbox_ring_end()
	if !picker_rings_make() {
		return
	}
	memory, opened, status := system.ring_create(receive_handles = true)
	if status != .Ok {
		return
	}
	region, region_status := system.memory_create(4)
	if region_status != .Ok {
		system.ring_close(&opened)
		system.close(memory)
		return
	}
	powerbox_ring_memory, powerbox_ring, powerbox_region_memory = memory, opened, region
	powerbox_holder = work.slot
	system.grant_put(&work.grants, powerbox.SERVICE_RING_SLOT, {memory, {.Read, .Write}})
	system.grant_put(&work.grants, powerbox.TRUSTED_DISPLAY_RING_SLOT, {picker_ring_memory, {.Read, .Write}})
	system.grant_put(&work.grants, powerbox.SERVICE_REGION_SLOT, {region, {.Read, .Write}})
	system.grant_put(&work.grants, powerbox.PICKER_REGION_SLOT, {picker_region_memory, {.Read, .Write}})
	system.grant_put(&work.grants, powerbox.IMAGE_SLOT, {image_memory, {.Read}})
	system.value_put(&work.values, powerbox.CONTEXT_VALUE_IMAGE_SIZE, u64(len(image)))
	if display_holder != 0 {
		slot, _, _ := system.process_place(display_holder)
		system.value_put(&work.values, powerbox.CONTEXT_VALUE_DISPLAY_SLOT, u64(slot))
	}
}

// powerbox_ring_end forgets the ring of a powerbox, and ends its listing.
@(private = "file")
powerbox_ring_end :: proc "contextless" () {
	picker_listing_end()
	if powerbox_ring.head != nil {
		system.ring_close(&powerbox_ring)
	}
	for handle in ([2]system.Handle{powerbox_ring_memory, powerbox_region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	powerbox_ring, powerbox_ring_memory, powerbox_region_memory, powerbox_holder = {}, 0, 0, nil
}

// powerbox_service_end forgets the powerbox when its process stops, in the
// reap, before its place takes another process: the ring and the listing
// of that powerbox end with it.
powerbox_service_end :: proc "contextless" (item: ^Started) {
	if powerbox_holder != nil && item == powerbox_holder {
		powerbox_ring_end()
	}
}

// powerbox_service_start starts the powerbox after the holder of Display,
// so the picker of the display has its other end.
powerbox_service_start :: proc "contextless" () {
	name := role_holder_name(.Powerbox)
	if name == "" || find(name) != nil || len(system.image_find(image, name)) == 0 {
		return
	}
	if outcome := start(name); outcome != .Succeeded {
		system.log_fact(.Warning, Powerbox_Start_Failed{outcome = outcome})
	}
}

@(private = "file")
picker_listing_end :: proc "contextless" () {
	if picker_listing.connection != nil {
		disconnect(picker_listing.connection)
	}
	picker_listing = {}
}

// picker_listing_refuse tells the powerbox that no list of the principal
// comes, so the Open that waits for it ends now and not at its bound.
@(private = "file")
picker_listing_refuse :: proc "contextless" (principal: u64) {
	system.log_fact(.Warning, Picker_Listing_Refused{principal = principal})
	if powerbox_ring.head == nil {
		return
	}
	powerbox_next_tag = powerbox_next_tag == max(u32) ? 1 : powerbox_next_tag + 1
	system.send(&powerbox_ring.commands, ring.Record{kind = u32(powerbox.Service_Ring_Command.Stores_Refused), tag = powerbox_next_tag, values = {0 = principal}})
}

// picker_listing_begin makes the connection that lists the stores of a
// principal and gives it to the powerbox. A principal that is not
// unlocked gets no list: its stores are no choice while its session is
// locked.
@(private = "file")
picker_listing_begin :: proc "contextless" (principal: u64) {
	if picker_listing.connection != nil || powerbox_holder == nil {
		return
	}
	if principal >= principals.PRINCIPAL_CAPACITY || (principal != principals.MACHINE && principal_records[principal].state != .In_Front) {
		picker_listing_refuse(principal)
		return
	}
	storage_place: u64
	for &item, index in system.image_entries(image) {
		if is_role_holder(system.name_of(item.name[:]), .Storage) {
			storage_place = u64(index + 1)
		}
	}
	picker_store_lister = {}
	copy(picker_store_lister.name[:len(picker_store_lister.name) - 1], disk_process.STORE_NAME)
	picker_store_lister.principal = principal
	open_refusal: [7]u64
	connection, service, ring_memory, region_memory, opened := connection_open(&picker_store_lister, role_holder_name(.Storage), &open_refusal, u32(root_ring.Root_Command.Connect))
	if opened != .Succeeded {
		picker_listing_refuse(principal)
		return
	}
	// The powerbox receives the handles through its ring; this service
	// keeps none of the memory.
	defer system.close(ring_memory)
	defer system.close(region_memory)
	sources := [3]system.Handle{service.process, ring_memory, region_memory}
	rights := [3]system.Rights{{.Read}, {.Read, .Write}, {.Read, .Write}}
	given: [3]system.Handle
	given_count := 0
	status: system.Status
	for source, index in sources {
		given[index], status = system.give(powerbox_ring_memory, source, rights[index])
		if status != .Ok {
			break
		}
		given_count += 1
	}
	powerbox_next_tag = powerbox_next_tag == max(u32) ? 1 : powerbox_next_tag + 1
	tag := powerbox_next_tag
	sent := status == .Ok && system.send(&powerbox_ring.commands, ring.Record{kind = u32(powerbox.Service_Ring_Command.Stores_Connection), tag = tag, values = {u64(given[0]), u64(given[1]), u64(given[2]), principal, storage_place, 0, 0}})
	if !sent {
		// A refusal names no handle, so the powerbox closes none: the
		// handles given before it are revoked here.
		for source in sources[:given_count] {
			system.handle_revoke(source, powerbox_holder.process)
		}
		disconnect(connection)
		picker_listing_refuse(principal)
		return
	}
	picker_listing = {connection = connection, tag = tag, deadline = system.time() + PICKER_LISTING_BOUND_MILLISECONDS}
}

// powerbox_answers reads the records of the powerbox on its ring: a wish
// for the list of a principal, and the end of a listing.
powerbox_answers :: proc "contextless" (wait: ^system.Wait) {
	if powerbox_holder == nil || powerbox_ring.head == nil {
		return
	}
	if powerbox_holder.process == 0 {
		powerbox_ring_end()
		return
	}
	for _ in 0 ..< powerbox.REQUESTS_PER_PASS {
		record := root_receive(&powerbox_ring.completions, "the powerbox") or_break
		if record.tag == 0 && record.kind == u32(powerbox.Service_Ring_Status.Stores_Wanted) {
			picker_listing_begin(record.values[0])
		} else if picker_listing.connection != nil && record.tag == picker_listing.tag {
			picker_listing_end()
		}
	}
	if picker_listing.connection != nil && system.time() >= picker_listing.deadline {
		picker_listing_end()
	}
	system.wait_records(wait, &powerbox_ring.completions)
}

// picker_listing_deadline gives the time at which the loop must run again
// for a listing, or no time.
picker_listing_deadline :: proc "contextless" () -> u64 {
	return picker_listing.connection != nil ? picker_listing.deadline : system.WAIT_FOREVER
}
