// Pure state machine for the delegated devices service
// (src/md/api/root_service_split.md).
//
// Maps discovered PCI devices to closed Device_Class_Role members through the
// Device_Identity_Table, refuses unknown identities and duplicate location
// claims, and mints strictly attenuated per-device Device_Grant_Spec records.
//
// Allocates no memory and calls no kernel operation.
package devices_core

import rd "modus:contract/root_delegation"

// Maximum simultaneously bound PCI devices tracked by the devices service.
MAX_DEVICE_BINDINGS :: 32

// Why scan_and_bind refused a discovered PCI device.
Devices_Bind_Refusal :: enum u8 {
	None                     = 0,
	Uninitialized            = 1,
	Zero_Service_Slot        = 2,
	Invalid_Pci_Location     = 3,
	Unknown_Device_Identity  = 4,
	Location_Already_Claimed = 5,
	Table_Full               = 6,
	Invalid_Grant_Spec       = 7,
	// The record in the bind place names another device than the word of
	// the command: the core reused the place for a newer binding.
	Identity_Mismatch        = 8,
}

// Active binding between a PCI bus location, its device service slot, and its
// attenuated grant specification.
Device_Binding :: struct {
	active:       bool,
	service_slot: u32,
	grant_spec:   rd.Device_Grant_Spec,
}

// Operational counters exposed through the devices service status export.
Devices_Counters :: struct {
	identity_count:  u64,
	active_bindings: u64,
	total_binds:     u64,
	total_releases:  u64,
	total_refusals:  u64,
}

// Fixed-capacity state of the delegated devices service.
Devices_State :: struct {
	initialized: bool,
	identities:  rd.Device_Identity_Table,
	bindings:    [MAX_DEVICE_BINDINGS]Device_Binding,
	counters:    Devices_Counters,
}

// state_init resets state and loads the default PCI device identity table.
state_init :: proc "contextless" (state: ^Devices_State) {
	if state == nil {
		return
	}
	state^ = {}
	state.identities = rd.device_identity_table_default()
	state.counters.identity_count = u64(state.identities.count)
	state.initialized = true
}

// register_identity appends a new PCI identity mapping, refusing invalid or
// duplicate identities.
register_identity :: proc "contextless" (state: ^Devices_State, entry: rd.Device_Identity_Entry) -> rd.Device_Identity_Refusal {
	if state == nil || !state.initialized {
		return .Corrupt_Table_Count
	}
	refusal := rd.device_identity_table_add(&state.identities, entry)
	if refusal != .None {
		state.counters.total_refusals += 1
		return refusal
	}
	state.counters.identity_count = u64(state.identities.count)
	return .None
}

// scan_and_bind classifies a discovered PCI device via Device_Identity_Table,
// refuses unknown identities and duplicate location claims, mints an
// attenuated Device_Grant_Spec, validates it against the contract border, and
// records the active binding.
scan_and_bind :: proc "contextless" (
	state: ^Devices_State,
	discovered: ^rd.Pci_Discovered_Device,
	service_slot: u32,
) -> (
	grant_spec: rd.Device_Grant_Spec,
	refusal: Devices_Bind_Refusal,
	grant_refusal: rd.Device_Grant_Refusal,
) {
	if state == nil || !state.initialized || discovered == nil {
		return {}, .Uninitialized, .None
	}
	if service_slot == 0 {
		state.counters.total_refusals += 1
		return {}, .Zero_Service_Slot, .None
	}
	if !rd.pci_location_valid(discovered.location) {
		state.counters.total_refusals += 1
		return {}, .Invalid_Pci_Location, .None
	}

	identity, id_refusal := rd.device_identity_table_lookup(&state.identities, discovered.pci_vendor_id, discovered.pci_device_id)
	if id_refusal != .None {
		state.counters.total_refusals += 1
		return {}, .Unknown_Device_Identity, .None
	}

	free_index := -1
	for &binding, idx in state.bindings {
		if !binding.active {
			if free_index < 0 {
				free_index = idx
			}
			continue
		}
		if binding.grant_spec.location == discovered.location {
			state.counters.total_refusals += 1
			return {}, .Location_Already_Claimed, .None
		}
	}
	if free_index < 0 {
		state.counters.total_refusals += 1
		return {}, .Table_Full, .None
	}

	spec := rd.Device_Grant_Spec {
		location            = discovered.location,
		pci_vendor_id       = discovered.pci_vendor_id,
		pci_device_id       = discovered.pci_device_id,
		role                = identity.role,
		bars                = discovered.bars,
		bar_count           = discovered.bar_count,
		interrupt_vector    = discovered.interrupt_vector,
		has_interrupt       = discovered.has_interrupt,
		iommu_allowed       = identity.needs_iommu,
		config_read_only    = true,
		granted_rights_word = rd.DEVICE_GRANT_ALLOWED_RIGHTS_MASK,
	}

	g_refusal := rd.validate_device_grant_spec(&spec, &state.identities)
	if g_refusal != .None {
		state.counters.total_refusals += 1
		return {}, .Invalid_Grant_Spec, g_refusal
	}

	state.bindings[free_index] = {
		active       = true,
		service_slot = service_slot,
		grant_spec   = spec,
	}
	state.counters.active_bindings += 1
	state.counters.total_binds += 1
	return spec, .None, .None
}

// bind_device serves a Bind_Device: it checks that the record copied from
// the bind place is the record that the core named in the command
// (identity_word), then binds it as scan_and_bind does. A mismatch is
// refused before any state changes.
bind_device :: proc "contextless" (
	state: ^Devices_State,
	discovered: ^rd.Pci_Discovered_Device,
	service_slot: u32,
	identity_word: u64,
) -> (
	grant_spec: rd.Device_Grant_Spec,
	refusal: Devices_Bind_Refusal,
	grant_refusal: rd.Device_Grant_Refusal,
) {
	if state == nil || !state.initialized || discovered == nil {
		return {}, .Uninitialized, .None
	}
	if !rd.device_bind_identity_matches(discovered, identity_word) {
		state.counters.total_refusals += 1
		return {}, .Identity_Mismatch, .None
	}
	return scan_and_bind(state, discovered, service_slot)
}

// lookup_identity finds the identity entry of a PCI vendor and device pair
// for the core, which classifies the bus with it before it arms any device.
// Each refusal counts.
lookup_identity :: proc "contextless" (state: ^Devices_State, vendor_id, device_id: u16) -> (entry: rd.Device_Identity_Entry, refusal: rd.Device_Identity_Refusal) {
	if state == nil || !state.initialized {
		return {}, .Corrupt_Table_Count
	}
	entry, refusal = rd.device_identity_table_lookup(&state.identities, vendor_id, device_id)
	if refusal != .None {
		state.counters.total_refusals += 1
	}
	return entry, refusal
}

// find_binding returns the active Device_Binding at location, if any.
find_binding :: proc "contextless" (state: ^Devices_State, location: rd.Pci_Location) -> (binding: Device_Binding, found: bool) {
	if state == nil || !state.initialized || !rd.pci_location_valid(location) {
		return {}, false
	}
	for entry in state.bindings {
		if entry.active && entry.grant_spec.location == location {
			return entry, true
		}
	}
	return {}, false
}

// release_device releases the active binding at location so another service
// may claim the device after teardown.
release_device :: proc "contextless" (state: ^Devices_State, location: rd.Pci_Location) -> bool {
	if state == nil || !state.initialized || !rd.pci_location_valid(location) {
		return false
	}
	for &entry in state.bindings {
		if entry.active && entry.grant_spec.location == location {
			entry = {}
			state.counters.active_bindings -= 1
			state.counters.total_releases += 1
			return true
		}
	}
	return false
}

// release_service releases every active device binding owned by service_slot.
release_service :: proc "contextless" (state: ^Devices_State, service_slot: u32) -> u32 {
	if state == nil || !state.initialized || service_slot == 0 {
		return 0
	}
	released := u32(0)
	for &entry in state.bindings {
		if entry.active && entry.service_slot == service_slot {
			entry = {}
			state.counters.active_bindings -= 1
			state.counters.total_releases += 1
			released += 1
		}
	}
	return released
}
