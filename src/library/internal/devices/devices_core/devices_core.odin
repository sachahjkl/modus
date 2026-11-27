// Pure state machine for the delegated devices service
// (src/md/api/root_service_split.md).
//
// Maps discovered PCI devices to closed Device_Class_Role members through the
// Device_Identity_Table, refuses unknown identities and duplicate location
// claims, and mints strictly attenuated per-device Device_Grant_Spec records.
//
// Allocates no memory and calls no kernel operation.
package devices_core

import op "modus:contract/operation"
import "modus:contract/pci_topology"
import rd "modus:contract/root_delegation"

// Plan value: maximum simultaneously bound PCI devices tracked by the devices service.
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
	// A BAR or DMA range collides with an AMD-Vi IVMD reserved range.
	Reserved_Dma_Collision   = 9,
	// The device's ECAM function page is outside the configured region or
	// collides with an active binding.
	Ecam_Page_Conflict       = 10,
	// Interrupt vector is out of 32..=255 or AMD-Vi IRTE table could not bind it.
	Irte_Bind_Failed         = 11,
}

// Active binding between a PCI bus location, its device service slot, its
// dedicated 4 KiB ECAM function page (when ECAM is configured), and its
// attenuated grant specification.
Device_Binding :: struct {
	active:             bool,
	service_slot:       u32,
	ecam_function_page: u64,
	grant_spec:         rd.Device_Grant_Spec,
}

// Operational counters exposed through the devices service status export.
Devices_Counters :: struct {
	identity_count:  u64,
	active_bindings: u64,
	total_binds:     u64,
	total_releases:  u64,
	total_refusals:  u64,
}

// Fixed-capacity state of the delegated devices service, including live PCI
// topology, per-function ECAM page mapping, and AMD-Vi IOMMU IRTE/IVMD tables.
Devices_State :: struct {
	initialized: bool,
	identities:  rd.Device_Identity_Table,
	topology:    pci_topology.Topology_State,
	iommu:       pci_topology.Amd_Iommu_Table,
	ecam_region: pci_topology.Ecam_Region,
	has_ecam:    bool,
	bindings:    [MAX_DEVICE_BINDINGS]Device_Binding,
	counters:    Devices_Counters,
}

// pci_bdf_of packs a PCI bus/device/function location into a 16-bit BDF word.
pci_bdf_of :: proc "contextless" (location: rd.Pci_Location) -> u16 {
	return u16(location.bus) << 8 | u16(location.device) << 3 | u16(location.function)
}

// state_init resets state, loads the default PCI device identity table, and
// initializes PCI topology and AMD-Vi IOMMU tracking tables.
state_init :: proc "contextless" (state: ^Devices_State) {
	if state == nil {
		return
	}
	state^ = {}
	state.identities = rd.device_identity_table_default()
	pci_topology.topology_init(&state.topology)
	pci_topology.amd_iommu_init(&state.iommu)
	state.counters.identity_count = u64(state.identities.count)
	state.initialized = true
}

// register_root_bus registers an ACPI MCFG root bus segment with the topology
// tracker and binds segment 0's ECAM window for per-function 4 KiB page checks.
register_root_bus :: proc "contextless" (
	state: ^Devices_State,
	segment: u16,
	start_bus, end_bus: u8,
	ecam_base: u64,
) -> bool {
	if state == nil || !state.initialized {
		return false
	}
	region := pci_topology.Ecam_Region{
		base_physical_address = ecam_base,
		start_bus             = start_bus,
		end_bus               = end_bus,
	}
	if pci_topology.ecam_region_validate(region) != .None {
		state.counters.total_refusals += 1
		return false
	}
	if !pci_topology.topology_add_root_bus(&state.topology, segment, start_bus, end_bus, ecam_base) {
		state.counters.total_refusals += 1
		return false
	}
	if segment == 0 && !state.has_ecam {
		state.ecam_region = region
		state.has_ecam = true
	}
	return true
}

// number_bridge allocates the next secondary bus number behind a PCIe-to-PCI
// bridge on an active root segment and widens parent subordinate bounds.
number_bridge :: proc "contextless" (
	state: ^Devices_State,
	segment: u16,
	primary_bus, device, function: u8,
) -> (secondary_bus: u8, ok: bool) {
	if state == nil || !state.initialized {
		return 0, false
	}
	secondary_bus, ok = pci_topology.topology_number_bridge(&state.topology, segment, primary_bus, device, function)
	if !ok {
		state.counters.total_refusals += 1
	}
	return secondary_bus, ok
}

// register_ivmd records a shared multi-device AMD-Vi IVMD reserved range.
register_ivmd :: proc "contextless" (
	state: ^Devices_State,
	start_phys, end_phys: u64,
	device_first, device_last: u16,
	exclusion: bool,
) -> bool {
	if state == nil || !state.initialized {
		return false
	}
	if !pci_topology.amd_iommu_add_ivmd(&state.iommu, start_phys, end_phys, device_first, device_last, exclusion) {
		state.counters.total_refusals += 1
		return false
	}
	return true
}

// verify_device_interrupt checks an incoming MSI/MSI-X message from location
// against installed AMD-Vi IRTE entries to refuse forged interrupts.
verify_device_interrupt :: proc "contextless" (
	state: ^Devices_State,
	location: rd.Pci_Location,
	vector: u8,
) -> pci_topology.Iommu_Decision {
	if state == nil || !state.initialized || !rd.pci_location_valid(location) {
		return .Refuse_Bad_Device
	}
	decision := pci_topology.amd_iommu_verify_interrupt(&state.iommu, pci_bdf_of(location), vector)
	if decision != .Allow {
		state.counters.total_refusals += 1
	}
	return decision
}

// check_device_dma checks whether location may map [phys, phys+length) without
// colliding with any AMD-Vi IVMD reserved memory range.
check_device_dma :: proc "contextless" (
	state: ^Devices_State,
	location: rd.Pci_Location,
	phys, length: u64,
) -> pci_topology.Iommu_Decision {
	if state == nil || !state.initialized || !rd.pci_location_valid(location) {
		return .Refuse_Bad_Device
	}
	decision := pci_topology.amd_iommu_dma_allowed(&state.iommu, pci_bdf_of(location), phys, length)
	if decision != .Allow {
		state.counters.total_refusals += 1
	}
	return decision
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

	// Enforce AMD-Vi IVMD reserved ranges on every BAR window before binding.
	bdf := pci_bdf_of(spec.location)
	for bar_idx in 0 ..< int(spec.bar_count) {
		bar := spec.bars[bar_idx]
		bar_bytes := u64(bar.page_count) * op.PAGE_SIZE
		if pci_topology.amd_iommu_dma_allowed(&state.iommu, bdf, bar.base_address, bar_bytes) != .Allow {
			state.counters.total_refusals += 1
			return {}, .Reserved_Dma_Collision, .None
		}
	}

	// Compute dedicated 4 KiB per-function ECAM page when an ECAM window is active.
	ecam_page: u64
	if state.has_ecam {
		ecam_ref: pci_topology.Ecam_Refusal
		ecam_page, ecam_ref = pci_topology.ecam_function_page_address(
			state.ecam_region,
			spec.location.bus,
			spec.location.device,
			spec.location.function,
		)
		if ecam_ref != .None {
			state.counters.total_refusals += 1
			return {}, .Ecam_Page_Conflict, .None
		}
		for &existing in state.bindings {
			if !existing.active {
				continue
			}
			disjoint, disj_ref := pci_topology.ecam_functions_disjoint(
				state.ecam_region,
				existing.grant_spec.location.bus,
				existing.grant_spec.location.device,
				existing.grant_spec.location.function,
				spec.location.bus,
				spec.location.device,
				spec.location.function,
			)
			if disj_ref != .None || !disjoint {
				state.counters.total_refusals += 1
				return {}, .Ecam_Page_Conflict, .None
			}
		}
	}

	// Bind required or present device interrupt in AMD-Vi IRTE table; refuse
	// out-of-range vectors or IRTE exhaustion so no device runs without an IRTE.
	if identity.needs_interrupt || spec.has_interrupt {
		if spec.interrupt_vector < 32 || spec.interrupt_vector > 255 {
			state.counters.total_refusals += 1
			return {}, .Irte_Bind_Failed, .None
		}
		if !pci_topology.amd_iommu_bind_irq(&state.iommu, bdf, u8(spec.interrupt_vector), 0) {
			state.counters.total_refusals += 1
			return {}, .Irte_Bind_Failed, .None
		}
	}

	state.bindings[free_index] = {
		active             = true,
		service_slot       = service_slot,
		ecam_function_page = ecam_page,
		grant_spec         = spec,
	}
	state.counters.active_bindings += 1
	state.counters.total_binds += 1
	return spec, .None, .None
}

// iommu_unbind_device removes all AMD-Vi IRTE entries bound to bdf and
// compacts the table so repeated bind/release cycles never leak IRTE slots
// and released devices cannot pass forged-IRQ verification.
@(private = "file")
iommu_unbind_device :: proc "contextless" (tbl: ^pci_topology.Amd_Iommu_Table, bdf: u16) {
	write_idx := 0
	for read_idx in 0 ..< tbl.irte_count {
		entry := tbl.irtes[read_idx]
		if entry.active && entry.device_id == bdf {
			continue
		}
		tbl.irtes[write_idx] = entry
		write_idx += 1
	}
	for idx in write_idx ..< tbl.irte_count {
		tbl.irtes[idx] = {}
	}
	tbl.irte_count = write_idx
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
			iommu_unbind_device(&state.iommu, pci_bdf_of(location))
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
			iommu_unbind_device(&state.iommu, pci_bdf_of(entry.grant_spec.location))
			entry = {}
			state.counters.active_bindings -= 1
			state.counters.total_releases += 1
			released += 1
		}
	}
	return released
}
