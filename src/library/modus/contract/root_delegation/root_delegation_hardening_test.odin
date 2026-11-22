#+build !freestanding
package root_delegation

import "core:testing"
import op "modus:contract/operation"

// The refusal of a Lookup_Identity at the border of the core: only
// Unknown_Identity and Invalid_Pci_Id with zero words after them answer.
// Each other member, a word past the last member, the largest word and a
// word after the refusal that is not zero leave the lookup unanswered.
@(test)
a_lookup_refusal_answers_only_for_an_identity_with_no_class :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(max(Device_Identity_Refusal)) + 1, 0xFF, 0x100, max(u64)}) {
		_, answered := device_identity_refusal_of_values({0 = word})
		testing.expectf(t, !answered, "the word %d is an answer", word)
	}
	for refusal in Device_Identity_Refusal {
		read, answered := device_identity_refusal_of_values({0 = u64(refusal)})
		testing.expect_value(t, read, refusal)
		testing.expect_value(t, answered, refusal == .Unknown_Identity || refusal == .Invalid_Pci_Id)
	}
	for place in 1 ..< 7 {
		values: [7]u64
		values[0] = u64(Device_Identity_Refusal.Unknown_Identity)
		values[place] = 1
		_, answered := device_identity_refusal_of_values(values)
		testing.expectf(t, !answered, "a word at %d after the refusal is taken", place)
	}
}

// The identity word of a Bind_Device names one record: each field that
// changes, a bit past the 56 bits of the packed form and the largest word
// are refused; the word of the record itself is taken, at the edges of
// each field.
@(test)
the_identity_word_of_a_bind_names_one_record :: proc(t: ^testing.T) {
	edges := [?]Pci_Discovered_Device {
		{location = {bus = 0, device = 0, function = 0}, pci_vendor_id = 0, pci_device_id = 0},
		{location = {bus = 255, device = 31, function = 7}, pci_vendor_id = max(u16), pci_device_id = max(u16)},
		{location = {bus = 1, device = 2, function = 3}, pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_BLOCK},
	}
	for &device in edges {
		word := device_bind_identity_word(&device)
		testing.expect(t, device_bind_identity_matches(&device, word))
		testing.expect(t, !device_bind_identity_matches(&device, word | 1 << 56))
		testing.expect(t, !device_bind_identity_matches(&device, max(u64)))
		changed := [?]Pci_Discovered_Device{device, device, device, device, device}
		changed[0].location.bus ~= 1
		changed[1].location.device ~= 1
		changed[2].location.function ~= 1
		changed[3].pci_vendor_id ~= 1
		changed[4].pci_device_id ~= 1
		for &other, index in changed {
			testing.expectf(t, !device_bind_identity_matches(&other, word), "a change of the field %d keeps the word", index)
		}
	}
	zero: Pci_Discovered_Device
	testing.expect_value(t, device_bind_identity_word(&zero), u64(0))
}

// The count of pages of a BAR: 0, one byte, one page, one page and a byte,
// the limit, one byte past the limit, and the largest size of a 64-bit
// BAR. A count past the limit is max(u32), which the border refuses whole.
@(test)
a_bar_past_the_page_limit_is_refused_and_never_cut :: proc(t: ^testing.T) {
	limit_bytes := u64(DEVICE_BAR_PAGES_LIMIT) * op.PAGE_SIZE
	cases := [?]struct {
		size:  u64,
		pages: u32,
	} {
		{0, 0},
		{1, 1},
		{op.PAGE_SIZE, 1},
		{op.PAGE_SIZE + 1, 2},
		{limit_bytes, DEVICE_BAR_PAGES_LIMIT},
		{limit_bytes + 1, max(u32)},
		{u64(max(u32)) * op.PAGE_SIZE, max(u32)},
		{max(u64), max(u32)},
	}
	for item in cases {
		testing.expectf(t, device_bar_page_count_word(item.size) == item.pages, "a BAR of %d bytes gives %d pages", item.size, device_bar_page_count_word(item.size))
	}
	table := device_identity_table_default()
	spec := Device_Grant_Spec {
		location            = {bus = 0, device = 3, function = 0},
		pci_vendor_id       = PCI_VENDOR_VIRTIO,
		pci_device_id       = PCI_DEVICE_VIRTIO_BLOCK,
		role                = .Block_Device,
		bars                = {0 = {base_address = 0xFE00_0000, page_count = device_bar_page_count_word(limit_bytes + 1)}},
		bar_count           = 1,
		interrupt_vector    = 0x40,
		has_interrupt       = true,
		iommu_allowed       = true,
		config_read_only    = true,
		granted_rights_word = DEVICE_GRANT_ALLOWED_RIGHTS_MASK,
	}
	testing.expect_value(t, validate_device_grant_spec(&spec, &table), Device_Grant_Refusal.Invalid_Bar_Range)
	spec.bars[0].page_count = device_bar_page_count_word(limit_bytes)
	testing.expect_value(t, validate_device_grant_spec(&spec, &table), Device_Grant_Refusal.None)
}

// The BARs of the MSI-X table and of its pending bits are withheld, and no
// other: the same BAR for both, two BARs, and an index past the last BAR.
@(test)
the_msix_bars_are_withheld_from_the_record :: proc(t: ^testing.T) {
	for index in u32(0) ..< PCI_BAR_CAPACITY {
		testing.expect_value(t, device_bar_withheld(index, 2, 2), index == 2)
		testing.expect_value(t, device_bar_withheld(index, 0, 5), index == 0 || index == 5)
	}
	testing.expect(t, !device_bar_withheld(PCI_BAR_CAPACITY, 0, 1))
}

// The places of the transfer region of the principals service: a negative
// place, the count and the largest int are refused; the first and the last
// place are taken, a page apart, inside the region, and each input record
// fits one place.
@(test)
the_principals_places_stay_inside_the_region :: proc(t: ^testing.T) {
	for place in ([?]int{-1, PRINCIPALS_TRANSFER_PLACE_COUNT, max(int)}) {
		_, ok := principals_transfer_place_offset(place)
		testing.expectf(t, !ok, "the place %d is taken", place)
	}
	first, first_ok := principals_transfer_place_offset(0)
	last, last_ok := principals_transfer_place_offset(PRINCIPALS_TRANSFER_PLACE_COUNT - 1)
	testing.expect(t, first_ok && last_ok)
	testing.expect_value(t, first, u64(0))
	testing.expect_value(t, last, u64(PRINCIPALS_TRANSFER_PLACE_COUNT - 1) * PRINCIPALS_TRANSFER_PLACE_BYTES)
	testing.expect(t, last + PRINCIPALS_TRANSFER_PLACE_BYTES <= u64(PRINCIPALS_REGION_PAGES * op.PAGE_SIZE))
	sizes := [?]int{size_of(Disk_Rows_Set_Request), size_of(Register_Principal_Input), size_of(Session_Transition_Input), size_of(Client_Key_Input), size_of(Start_Policy_Input)}
	for size in sizes {
		testing.expect(t, size <= PRINCIPALS_TRANSFER_PLACE_BYTES)
	}
}

// The words of the actions of the principals ring: 0, a word past the last
// member and the largest word are refused; each member other than None is
// taken.
@(test)
the_principals_action_words_refuse_what_names_no_action :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(max(Session_Action)) + 1, max(u32)}) {
		_, ok := session_action_from_word(word)
		testing.expect(t, !ok)
	}
	for word in ([?]u32{0, u32(max(Client_Key_Action)) + 1, max(u32)}) {
		_, ok := client_key_action_from_word(word)
		testing.expect(t, !ok)
	}
	for word in ([?]u32{0, u32(max(Start_Policy_Action)) + 1, max(u32)}) {
		_, ok := start_policy_action_from_word(word)
		testing.expect(t, !ok)
	}
	for action in Session_Action {
		read, ok := session_action_from_word(u32(action))
		testing.expect_value(t, ok, action != .None)
		testing.expect(t, !ok || read == action)
	}
	for action in Client_Key_Action {
		read, ok := client_key_action_from_word(u32(action))
		testing.expect_value(t, ok, action != .None)
		testing.expect(t, !ok || read == action)
	}
	for action in Start_Policy_Action {
		read, ok := start_policy_action_from_word(u32(action))
		testing.expect_value(t, ok, action != .None)
		testing.expect(t, !ok || read == action)
	}
}
