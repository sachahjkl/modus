// The client of the picker ring (src/md/features/powerbox.md, "The picker
// ring"): the store picker of the trusted display reads the stores of the
// principal from the powerbox by pages, and the powerbox checks the pick
// against its copy of the list. The compositor holds no list of stores and
// no connection to the storage service.
package compositor

import "base:intrinsics"
import "modus:contract/powerbox"
import "modus:contract/ring"
import "modus:system"

picker_ring: ring.Ring
picker_region: []u8
picker_next_tag: u32

// What the picker waits for, or shows.
Picker_Stage :: enum u8 {
	None,
	Opening, // The Open waits for the list of the powerbox.
	Ready, // A page shows.
	Paging, // A Page waits; the page of before still shows.
	Picking, // A Pick waits: the prompt closes at its answer.
	No_List, // The powerbox gave no list, or no powerbox runs.
}

Picker_Client :: struct {
	stage:        Picker_Stage,
	tag:          u32, // Of the command that waits.
	serial:       u64, // The dialog of the powerbox.
	page:         powerbox.Picker_Page, // The copy of the page that shows, checked at its border.
	chosen:       [powerbox.MAX_NAME_BYTES]u8,
	chosen_length: int,
}

picker: Picker_Client

// powerbox_picker_open_ring opens the end of the picker ring of this
// process. With none, a store picker shows no list.
powerbox_picker_open_ring :: proc "contextless" (ctx: ^system.Context) {
	ring_handle, region_handle := ctx.handles[powerbox.DISPLAY_PICKER_RING_SLOT], ctx.handles[powerbox.DISPLAY_PICKER_REGION_SLOT]
	if ring_handle == 0 || region_handle == 0 {
		return
	}
	pages, size_status := system.memory_size(region_handle)
	address, map_status := system.memory_map(region_handle, {.Write})
	if size_status != .Ok || map_status != .Ok || pages < powerbox.PICKER_REGION_PAGES {
		return
	}
	opened, ring_status := system.ring_open(ring_handle)
	if ring_status != .Ok {
		return
	}
	picker_ring = opened
	picker_region = ([^]u8)(address)[:pages * system.PAGE_SIZE]
}

@(private = "file")
picker_send :: proc "contextless" (command: powerbox.Picker_Ring_Command, values: [7]u64) -> bool {
	if picker_ring.head == nil {
		return false
	}
	picker_next_tag = picker_next_tag == max(u32) ? 1 : picker_next_tag + 1
	if !system.send(&picker_ring.commands, ring.Record{kind = u32(command), tag = picker_next_tag, values = values}) {
		return false
	}
	picker.tag = picker_next_tag
	return true
}

// powerbox_picker_open asks the powerbox for the stores of principal.
powerbox_picker_open :: proc "contextless" (principal: u64) {
	picker = {}
	picker.stage = picker_send(.Open, {0 = principal}) ? .Opening : .No_List
}

// powerbox_picker_total gives the count of the whole list.
powerbox_picker_total :: proc "contextless" () -> int {
	return picker.stage == .Ready || picker.stage == .Paging || picker.stage == .Picking ? int(picker.page.total) : 0
}

// powerbox_picker_name gives the name at a place of the whole list, when
// the page that shows holds it.
powerbox_picker_name :: proc "contextless" (list_index: int) -> (name: string, found: bool) {
	for &candidate in picker.page.candidates[:min(picker.page.candidate_count, powerbox.PICKER_PAGE_CANDIDATES)] {
		if int(candidate.list_index) == list_index {
			return string(candidate.name_bytes[:candidate.name_length]), true
		}
	}
	return "", false
}

// powerbox_picker_show asks for the page that starts at first when the
// page that shows does not hold the rows from first to first + rows.
powerbox_picker_show :: proc "contextless" (first, rows: int) {
	if picker.stage != .Ready {
		return
	}
	_, first_found := powerbox_picker_name(first)
	_, last_found := powerbox_picker_name(min(first + rows, int(picker.page.total)) - 1)
	if first_found && last_found {
		return
	}
	request := powerbox.Picker_Page_Request{dialog_serial = picker.serial, first = u32(first)}
	intrinsics.mem_copy_non_overlapping(&picker_region[powerbox.PICKER_REGION_REQUEST_OFFSET], &request, size_of(powerbox.Picker_Page_Request))
	if picker_send(.Page, {0 = picker.serial}) {
		picker.stage = .Paging
	}
}

// powerbox_picker_pick sends the pick of the row at list_index, which the
// page shows. false: nothing to pick.
powerbox_picker_pick :: proc "contextless" (list_index: int) -> bool {
	if picker.stage != .Ready {
		return false
	}
	for &candidate in picker.page.candidates[:min(picker.page.candidate_count, powerbox.PICKER_PAGE_CANDIDATES)] {
		if int(candidate.list_index) != list_index {
			continue
		}
		hash := transmute([4]u64)candidate.name_hash
		if !picker_send(.Pick, {picker.serial, u64(list_index), picker.page.change_count, hash[0], hash[1], hash[2], hash[3]}) {
			return false
		}
		picker.chosen_length = copy(picker.chosen[:], candidate.name_bytes[:candidate.name_length])
		picker.stage = .Picking
		return true
	}
	return false
}

// powerbox_picker_close ends the dialog of the powerbox with no pick.
powerbox_picker_close :: proc "contextless" () {
	if picker.serial != 0 {
		picker_send(.Close, {0 = picker.serial})
	}
	picker = {}
}

// powerbox_picker_step reads the answers of the powerbox. A page is
// copied once out of the region and checked before it shows. An answer
// with the tag of no command that waits is dropped.
powerbox_picker_step :: proc "contextless" () {
	if picker_ring.head == nil {
		return
	}
	for {
		record := system.receive(&picker_ring.completions) or_break
		if record.tag != picker.tag || picker.stage == .None || picker.stage == .Ready || picker.stage == .No_List {
			continue
		}
		status, known := enum_member_of_picker_status(record.kind)
		ok := known && status == .Ok
		switch picker.stage {
		case .None, .Ready, .No_List:
		case .Opening, .Paging:
			if !ok {
				picker.stage = .No_List
				break
			}
			page: powerbox.Picker_Page
			intrinsics.mem_copy_non_overlapping(&page, &picker_region[powerbox.PICKER_REGION_PAGE_OFFSET], size_of(powerbox.Picker_Page))
			refusal, _ := powerbox.picker_page_validate(&page)
			if refusal != .None || page.dialog_serial != record.values[1] || (picker.stage == .Paging && page.dialog_serial != picker.serial) {
				picker.stage = .No_List
				break
			}
			picker.page = page
			picker.serial = page.dialog_serial
			picker.stage = .Ready
		case .Picking:
			powerbox_prompt_picked(ok, string(picker.chosen[:picker.chosen_length]))
			picker = {}
		}
		damage_whole_screen()
	}
}

@(private = "file")
enum_member_of_picker_status :: proc "contextless" (word: u32) -> (status: powerbox.Picker_Ring_Status, ok: bool) {
	switch word {
	case u32(powerbox.Picker_Ring_Status.Ok):
		return .Ok, true
	case u32(powerbox.Picker_Ring_Status.Refused):
		return .Refused, true
	case u32(powerbox.Picker_Ring_Status.Bad_Command):
		return .Bad_Command, true
	case u32(powerbox.Picker_Ring_Status.Busy):
		return .Busy, true
	case u32(powerbox.Picker_Ring_Status.No_List):
		return .No_List, true
	}
	return .Refused, false
}

// powerbox_picker_wait adds the answers of the powerbox to the wait.
powerbox_picker_wait :: proc "contextless" (wait: ^system.Wait) {
	if picker_ring.head != nil {
		system.wait_records(wait, &picker_ring.completions)
	}
}

