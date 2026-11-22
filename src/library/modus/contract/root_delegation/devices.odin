// Contract for the delegated devices service: PCI identity-to-role table and
// strictly attenuated per-device grant specifications
// (src/md/api/root_service_split.md).
//
// Each PCI identity maps to a closed Device_Class_Role member; unknown and
// duplicate identities are refused. A Device_Grant_Spec carries only the
// registers, interrupt, read-only configuration view, and IOMMU permission of
// one device, never config-write or elevated machine rights.
package root_delegation

import "modus:contract/enum_word"
import op "modus:contract/operation"
import "modus:contract/role_contract"

// Maximum PCI identities held in one Device_Identity_Table.
DEVICE_IDENTITY_CAPACITY :: 32

// Standard PCI Type 0 Base Address Register count and location bounds.
PCI_BAR_CAPACITY :: 6
PCI_DEVICE_LIMIT :: 32
PCI_FUNCTION_LIMIT :: 8

// Upper bound on pages mapped for a single PCI BAR register window (64 MiB).
DEVICE_BAR_PAGES_LIMIT :: 16384

// Context handle slots used by the delegated devices service.
DEVICES_RING_SLOT :: 10
DEVICES_REGION_SLOT :: 11

// The shared region of the devices service holds one bind place for each
// place of the table of processes of the core, so two Bind_Device commands
// in flight never share bytes: the discovered record at the start of the
// place, the grant specification that the service writes after it.
DEVICES_BIND_PLACE_COUNT :: 32
DEVICES_BIND_PLACE_BYTES :: 512
DEVICES_BIND_SPEC_OFFSET :: 256
DEVICES_REGION_PAGES :: DEVICES_BIND_PLACE_COUNT * DEVICES_BIND_PLACE_BYTES / op.PAGE_SIZE
#assert(DEVICES_BIND_PLACE_COUNT * DEVICES_BIND_PLACE_BYTES % op.PAGE_SIZE == 0)
#assert(size_of(Pci_Discovered_Device) <= DEVICES_BIND_SPEC_OFFSET)
#assert(size_of(Device_Grant_Spec) <= DEVICES_BIND_PLACE_BYTES - DEVICES_BIND_SPEC_OFFSET)

// PCI vendor and device identifiers for VirtIO 1.0 modern devices and TPM 2.0.
PCI_VENDOR_VIRTIO :: u16(0x1AF4)
PCI_DEVICE_VIRTIO_NETWORK :: u16(0x1041)
PCI_DEVICE_VIRTIO_BLOCK :: u16(0x1042)
PCI_DEVICE_VIRTIO_ENTROPY :: u16(0x1044)
PCI_DEVICE_VIRTIO_GPU :: u16(0x1050)
PCI_DEVICE_VIRTIO_INPUT :: u16(0x1052)
PCI_DEVICE_VIRTIO_SOUND :: u16(0x1059)
PCI_VENDOR_INFINEON_TPM :: u16(0x15D1)
PCI_DEVICE_TPM_SLB9670 :: u16(0x001B)

// Exact bitmask of kernel handle rights allowed on an attenuated per-device
// grant: Read and Write only, never Control, Debug, Devices, Stop, or Spend.
DEVICE_GRANT_ALLOWED_RIGHTS_MASK :: u64((u32(1) << u32(op.Right.Read)) | (u32(1) << u32(op.Right.Write)))

// Closed set of device class roles bound by the devices service.
// Zero means unset and is refused at the border.
Device_Class_Role :: enum u32 {
	None           = 0,
	Block_Device   = 1,
	Network_Device = 2,
	Sound_Device   = 3,
	Entropy_Device = 4,
	Tpm_Device     = 5,
	Input_Device   = 6,
	Gpu_Device     = 7,
}

// Commands accepted on the delegated devices service ring.
Devices_Ring_Command :: enum u32 {
	None              = 0,
	Register_Identity = 1,
	Bind_Device       = 2,
	Release_Device    = 3,
	Query_Binding     = 4,
	Lookup_Identity   = 5,
}

// Completion statuses returned on the delegated devices service ring.
Devices_Ring_Status :: enum u32 {
	Ok          = 0,
	Refused     = 1,
	Bad_Command = 2,
}

// Why a Device_Identity_Table operation refused an identity or lookup.
Device_Identity_Refusal :: enum u8 {
	None                 = 0,
	Invalid_Pci_Id       = 1,
	Unknown_Device_Class = 2,
	Invalid_Bar_Count    = 3,
	Duplicate_Identity   = 4,
	Table_Full           = 5,
	Unknown_Identity     = 6,
	Corrupt_Table_Count  = 7,
}

// Why validate_device_grant_spec refused a Device_Grant_Spec.
Device_Grant_Refusal :: enum u8 {
	None                     = 0,
	Invalid_Pci_Location     = 1,
	Unknown_Device_Identity  = 2,
	Role_Mismatch            = 3,
	Config_Write_Forbidden   = 4,
	Insufficient_Bars        = 5,
	Too_Many_Bars            = 6,
	Invalid_Bar_Range        = 7,
	Overlapping_Bar_Ranges   = 8,
	Trailing_Bar_Data        = 9,
	Missing_Interrupt        = 10,
	Unexpected_Interrupt     = 11,
	Unauthorized_Iommu       = 12,
	Elevated_Or_Empty_Rights = 13,
}

// One PCI (vendor, device) -> Device_Class_Role entry in the identity table.
Device_Identity_Entry :: struct {
	pci_vendor_id:      u16,
	pci_device_id:      u16,
	role:               Device_Class_Role,
	required_bar_count: u8,
	needs_iommu:        bool,
	needs_interrupt:    bool,
}

// Fixed-capacity table mapping PCI identities to closed Device_Class_Role
// values without duplicates.
Device_Identity_Table :: struct {
	entries: [DEVICE_IDENTITY_CAPACITY]Device_Identity_Entry,
	count:   u32,
}

// PCI Bus/Device/Function address.
Pci_Location :: struct {
	bus:      u8,
	device:   u8,
	function: u8,
}

// One page-aligned MMIO BAR window granted to a device service.
Device_Bar_Range :: struct {
	base_address: u64,
	page_count:   u32,
}

// Raw PCI discovery record that the core reads from the configuration of a
// device after it armed the device, sent with Bind_Device.
Pci_Discovered_Device :: struct {
	location:         Pci_Location,
	pci_vendor_id:    u16,
	pci_device_id:    u16,
	bars:             [PCI_BAR_CAPACITY]Device_Bar_Range,
	bar_count:        u8,
	interrupt_vector: u32,
	has_interrupt:    bool,
}

// Attenuated per-device grant minted by the devices service for one device
// service process.
Device_Grant_Spec :: struct {
	location:            Pci_Location,
	pci_vendor_id:       u16,
	pci_device_id:       u16,
	role:                Device_Class_Role,
	bars:                [PCI_BAR_CAPACITY]Device_Bar_Range,
	bar_count:           u8,
	interrupt_vector:    u32,
	has_interrupt:       bool,
	iommu_allowed:       bool,
	config_read_only:    bool,
	granted_rights_word: u64,
}

// device_class_role_from_word converts a transport word into a
// Device_Class_Role, refusing zero and every unknown word.
device_class_role_from_word :: proc "contextless" (word: u64) -> (role: Device_Class_Role, ok: bool) {
	member := enum_word.member_of_word(Device_Class_Role, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// devices_ring_command_from_word converts a ring command word into a
// Devices_Ring_Command, refusing zero and every unknown word.
devices_ring_command_from_word :: proc "contextless" (word: u32) -> (command: Devices_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Devices_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// device_identity_answer_values gives the completion words of a
// Lookup_Identity that found an entry: its role, its count of BARs, and
// whether it needs the IOMMU and an interrupt.
device_identity_answer_values :: proc "contextless" (entry: Device_Identity_Entry) -> (values: [7]u64) {
	values[0] = u64(entry.role)
	values[1] = u64(entry.required_bar_count)
	values[2] = entry.needs_iommu ? 1 : 0
	values[3] = entry.needs_interrupt ? 1 : 0
	return values
}

// device_identity_answer_of_values reads the completion words of a
// Lookup_Identity at the border of the core: a role that names no member or
// None, a count of BARs out of 1 to PCI_BAR_CAPACITY, a flag that is not 0
// or 1, and a word after the flags that is not zero are each refused.
device_identity_answer_of_values :: proc "contextless" (values: [7]u64, vendor_id, device_id: u16) -> (entry: Device_Identity_Entry, ok: bool) {
	role := device_class_role_from_word(values[0]) or_return
	if values[1] == 0 || values[1] > PCI_BAR_CAPACITY || values[2] > 1 || values[3] > 1 {
		return {}, false
	}
	for index in 4 ..< len(values) {
		if values[index] != 0 {
			return {}, false
		}
	}
	return {
		pci_vendor_id      = vendor_id,
		pci_device_id      = device_id,
		role               = role,
		required_bar_count = u8(values[1]),
		needs_iommu        = values[2] == 1,
		needs_interrupt    = values[3] == 1,
	}, true
}

// devices_bind_place_offsets gives the offsets in the shared region of the
// discovered record and of the grant specification of one bind place,
// refusing a place past DEVICES_BIND_PLACE_COUNT.
devices_bind_place_offsets :: proc "contextless" (place: int) -> (discovered_offset, spec_offset: u64, ok: bool) {
	if place < 0 || place >= DEVICES_BIND_PLACE_COUNT {
		return 0, 0, false
	}
	discovered_offset = u64(place) * DEVICES_BIND_PLACE_BYTES
	return discovered_offset, discovered_offset + DEVICES_BIND_SPEC_OFFSET, true
}

// devices_ring_status_from_word converts a completion status word into a
// Devices_Ring_Status, refusing every unknown word.
devices_ring_status_from_word :: proc "contextless" (word: u32) -> (status: Devices_Ring_Status, ok: bool) {
	return enum_word.member_of_word(Devices_Ring_Status, u64(word))
}

// device_class_to_system_role maps a Device_Class_Role to the system role
// enum member that represents its class.
device_class_to_system_role :: proc "contextless" (class: Device_Class_Role) -> (role: role_contract.Role, ok: bool) {
	validated, valid := device_class_role_from_word(u64(class))
	if !valid {
		return .None, false
	}
	switch validated {
	case .None:
		return .None, false
	case .Block_Device:
		return .Block_Device, true
	case .Network_Device:
		return .Network_Device, true
	case .Sound_Device:
		return .Sound_Device, true
	case .Entropy_Device:
		return .Entropy_Device, true
	case .Tpm_Device:
		return .Tpm, true
	case .Input_Device:
		return .Input, true
	case .Gpu_Device:
		return .Display, true
	}
	return .None, false
}

// pci_id_valid reports whether a PCI vendor/device ID pair is populated.
// PCI reserves 0x0000 and 0xFFFF for unpopulated or invalid slots.
pci_id_valid :: proc "contextless" (vendor_id: u16, device_id: u16) -> bool {
	return vendor_id != 0 && vendor_id != 0xFFFF && device_id != 0 && device_id != 0xFFFF
}

// pci_location_valid checks that a PCI BDF fits within the PCI 5-bit device
// and 3-bit function limits.
pci_location_valid :: proc "contextless" (location: Pci_Location) -> bool {
	return location.device < PCI_DEVICE_LIMIT && location.function < PCI_FUNCTION_LIMIT
}

// device_rights_from_word validates the attenuated rights mask for a device
// service: non-empty and strictly within {Read, Write}.
device_rights_from_word :: proc "contextless" (word: u64) -> (rights: op.Rights, ok: bool) {
	if word == 0 || (word &~ DEVICE_GRANT_ALLOWED_RIGHTS_MASK) != 0 {
		return {}, false
	}
	return transmute(op.Rights)u32(word), true
}

// device_identity_table_add inserts one validated PCI identity mapping into
// table, refusing invalid IDs, unknown roles, bad BAR counts, and duplicates.
device_identity_table_add :: proc "contextless" (table: ^Device_Identity_Table, entry: Device_Identity_Entry) -> Device_Identity_Refusal {
	if table == nil {
		return .Corrupt_Table_Count
	}
	if table.count > DEVICE_IDENTITY_CAPACITY {
		return .Corrupt_Table_Count
	}
	if !pci_id_valid(entry.pci_vendor_id, entry.pci_device_id) {
		return .Invalid_Pci_Id
	}
	if _, role_ok := device_class_role_from_word(u64(entry.role)); !role_ok {
		return .Unknown_Device_Class
	}
	if entry.required_bar_count == 0 || entry.required_bar_count > PCI_BAR_CAPACITY {
		return .Invalid_Bar_Count
	}
	for index in u32(0) ..< table.count {
		existing := table.entries[index]
		if existing.pci_vendor_id == entry.pci_vendor_id && existing.pci_device_id == entry.pci_device_id {
			return .Duplicate_Identity
		}
	}
	if table.count >= DEVICE_IDENTITY_CAPACITY {
		return .Table_Full
	}
	table.entries[table.count] = entry
	table.count += 1
	return .None
}

// device_identity_table_default returns the built-in PCI identity table for
// the supported VirtIO 1.0 devices and TPM 2.0.
device_identity_table_default :: proc "contextless" () -> (table: Device_Identity_Table) {
	defaults := [7]Device_Identity_Entry {
		{pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_BLOCK, role = .Block_Device, required_bar_count = 1, needs_iommu = true, needs_interrupt = true},
		{pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_NETWORK, role = .Network_Device, required_bar_count = 1, needs_iommu = true, needs_interrupt = true},
		{pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_SOUND, role = .Sound_Device, required_bar_count = 1, needs_iommu = true, needs_interrupt = true},
		{pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_ENTROPY, role = .Entropy_Device, required_bar_count = 1, needs_iommu = true, needs_interrupt = true},
		{pci_vendor_id = PCI_VENDOR_INFINEON_TPM, pci_device_id = PCI_DEVICE_TPM_SLB9670, role = .Tpm_Device, required_bar_count = 1, needs_iommu = false, needs_interrupt = false},
		{pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_INPUT, role = .Input_Device, required_bar_count = 1, needs_iommu = true, needs_interrupt = true},
		{pci_vendor_id = PCI_VENDOR_VIRTIO, pci_device_id = PCI_DEVICE_VIRTIO_GPU, role = .Gpu_Device, required_bar_count = 1, needs_iommu = true, needs_interrupt = true},
	}
	for entry in defaults {
		_ = device_identity_table_add(&table, entry)
	}
	return table
}

// device_identity_table_lookup finds the Device_Identity_Entry for a PCI
// vendor/device pair, refusing invalid or unmapped identities.
device_identity_table_lookup :: proc "contextless" (table: ^Device_Identity_Table, vendor_id: u16, device_id: u16) -> (entry: Device_Identity_Entry, refusal: Device_Identity_Refusal) {
	if table == nil || table.count > DEVICE_IDENTITY_CAPACITY {
		return {}, .Corrupt_Table_Count
	}
	if !pci_id_valid(vendor_id, device_id) {
		return {}, .Invalid_Pci_Id
	}
	for index in u32(0) ..< table.count {
		candidate := table.entries[index]
		if candidate.pci_vendor_id == vendor_id && candidate.pci_device_id == device_id {
			if _, role_ok := device_class_role_from_word(u64(candidate.role)); !role_ok {
				return {}, .Unknown_Device_Class
			}
			return candidate, .None
		}
	}
	return {}, .Unknown_Identity
}

// device_identity_table_validate checks that an entire table has a valid
// count, valid entries, and zero duplicate PCI identities.
device_identity_table_validate :: proc "contextless" (table: ^Device_Identity_Table) -> Device_Identity_Refusal {
	if table == nil || table.count > DEVICE_IDENTITY_CAPACITY {
		return .Corrupt_Table_Count
	}
	for index in u32(0) ..< table.count {
		entry := table.entries[index]
		if !pci_id_valid(entry.pci_vendor_id, entry.pci_device_id) {
			return .Invalid_Pci_Id
		}
		if _, role_ok := device_class_role_from_word(u64(entry.role)); !role_ok {
			return .Unknown_Device_Class
		}
		if entry.required_bar_count == 0 || entry.required_bar_count > PCI_BAR_CAPACITY {
			return .Invalid_Bar_Count
		}
		for earlier in u32(0) ..< index {
			prev := table.entries[earlier]
			if prev.pci_vendor_id == entry.pci_vendor_id && prev.pci_device_id == entry.pci_device_id {
				return .Duplicate_Identity
			}
		}
	}
	return .None
}

// validate_device_grant_spec verifies that an attenuated per-device grant
// matches a known identity in table, keeps PCI configuration space read-only,
// carries valid non-overlapping page-aligned BAR windows, respects interrupt
// and IOMMU bounds, and stays strictly within {Read, Write} rights.
validate_device_grant_spec :: proc "contextless" (spec: ^Device_Grant_Spec, table: ^Device_Identity_Table) -> Device_Grant_Refusal {
	if spec == nil || !pci_location_valid(spec.location) {
		return .Invalid_Pci_Location
	}
	entry, lookup_refusal := device_identity_table_lookup(table, spec.pci_vendor_id, spec.pci_device_id)
	if lookup_refusal != .None {
		return .Unknown_Device_Identity
	}
	role, role_ok := device_class_role_from_word(u64(spec.role))
	if !role_ok || role != entry.role {
		return .Role_Mismatch
	}
	if !spec.config_read_only {
		return .Config_Write_Forbidden
	}
	if spec.bar_count > PCI_BAR_CAPACITY {
		return .Too_Many_Bars
	}
	if spec.bar_count < entry.required_bar_count {
		return .Insufficient_Bars
	}
	for index in 0 ..< int(spec.bar_count) {
		bar := spec.bars[index]
		if bar.base_address == 0 || (bar.base_address & (op.PAGE_SIZE - 1)) != 0 {
			return .Invalid_Bar_Range
		}
		if bar.page_count == 0 || bar.page_count > DEVICE_BAR_PAGES_LIMIT {
			return .Invalid_Bar_Range
		}
		byte_size := u64(bar.page_count) * op.PAGE_SIZE
		if bar.base_address > max(u64) - byte_size {
			return .Invalid_Bar_Range
		}
		bar_end := bar.base_address + byte_size
		for earlier in 0 ..< index {
			prev := spec.bars[earlier]
			prev_end := prev.base_address + u64(prev.page_count) * op.PAGE_SIZE
			if bar.base_address < prev_end && prev.base_address < bar_end {
				return .Overlapping_Bar_Ranges
			}
		}
	}
	for index in int(spec.bar_count) ..< PCI_BAR_CAPACITY {
		if spec.bars[index].base_address != 0 || spec.bars[index].page_count != 0 {
			return .Trailing_Bar_Data
		}
	}
	if entry.needs_interrupt && (!spec.has_interrupt || spec.interrupt_vector == 0) {
		return .Missing_Interrupt
	}
	if !spec.has_interrupt && spec.interrupt_vector != 0 {
		return .Unexpected_Interrupt
	}
	if spec.iommu_allowed && !entry.needs_iommu {
		return .Unauthorized_Iommu
	}
	if _, rights_ok := device_rights_from_word(spec.granted_rights_word); !rights_ok {
		return .Elevated_Or_Empty_Rights
	}
	return .None
}
