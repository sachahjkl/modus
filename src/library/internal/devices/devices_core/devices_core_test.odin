#+build !freestanding
package devices_core

import "core:testing"
import rd "modus:contract/root_delegation"

@(private = "file")
make_virtio_device :: proc(bus, dev, fn: u8, device_id: u16, bar_base: u64) -> rd.Pci_Discovered_Device {
	return {
		location         = {bus = bus, device = dev, function = fn},
		pci_vendor_id    = rd.PCI_VENDOR_VIRTIO,
		pci_device_id    = device_id,
		bars             = {0 = {base_address = bar_base, page_count = 4}},
		bar_count        = 1,
		interrupt_vector = 0x40 + u32(dev),
		has_interrupt    = true,
	}
}

@(test)
scan_and_bind_refuses_unknown_duplicates_and_invalid_hardware :: proc(t: ^testing.T) {
	state: Devices_State
	// Uninitialized state refuses bind.
	blk := make_virtio_device(0, 0x10, 0, rd.PCI_DEVICE_VIRTIO_BLOCK, 0xFE00_0000)
	_, uninit_ref, _ := scan_and_bind(&state, &blk, 1)
	testing.expect_value(t, uninit_ref, Devices_Bind_Refusal.Uninitialized)

	state_init(&state)

	// Zero service slot refused.
	_, zero_slot, _ := scan_and_bind(&state, &blk, 0)
	testing.expect_value(t, zero_slot, Devices_Bind_Refusal.Zero_Service_Slot)

	// Invalid PCI location (device >= 32 or function >= 8) refused.
	bad_loc := blk
	bad_loc.location.device = rd.PCI_DEVICE_LIMIT
	_, loc_ref, _ := scan_and_bind(&state, &bad_loc, 1)
	testing.expect_value(t, loc_ref, Devices_Bind_Refusal.Invalid_Pci_Location)

	bad_fn := blk
	bad_fn.location.function = rd.PCI_FUNCTION_LIMIT
	_, fn_ref, _ := scan_and_bind(&state, &bad_fn, 1)
	testing.expect_value(t, fn_ref, Devices_Bind_Refusal.Invalid_Pci_Location)

	// Unknown PCI identity refused.
	unknown := blk
	unknown.pci_vendor_id = 0x8086
	unknown.pci_device_id = 0x1234
	_, unk_ref, _ := scan_and_bind(&state, &unknown, 1)
	testing.expect_value(t, unk_ref, Devices_Bind_Refusal.Unknown_Device_Identity)

	// Missing interrupt on VirtIO block refused by grant validator.
	no_irq := blk
	no_irq.has_interrupt = false
	no_irq.interrupt_vector = 0
	_, irq_ref, g_ref := scan_and_bind(&state, &no_irq, 1)
	testing.expect_value(t, irq_ref, Devices_Bind_Refusal.Invalid_Grant_Spec)
	testing.expect_value(t, g_ref, rd.Device_Grant_Refusal.Missing_Interrupt)

	// Valid bind succeeds with read-only config and strictly attenuated rights.
	spec, ok_ref, _ := scan_and_bind(&state, &blk, 7)
	testing.expect_value(t, ok_ref, Devices_Bind_Refusal.None)
	testing.expect_value(t, spec.role, rd.Device_Class_Role.Block_Device)
	testing.expect(t, spec.config_read_only)
	testing.expect(t, spec.iommu_allowed)
	testing.expect_value(t, spec.granted_rights_word, rd.DEVICE_GRANT_ALLOWED_RIGHTS_MASK)
	testing.expect_value(t, state.counters.active_bindings, u64(1))

	// Duplicate claim at the same PCI location is strictly refused.
	_, dup_ref, _ := scan_and_bind(&state, &blk, 8)
	testing.expect_value(t, dup_ref, Devices_Bind_Refusal.Location_Already_Claimed)
	testing.expect_value(t, state.counters.active_bindings, u64(1))

	// Release and re-bind succeeds.
	testing.expect(t, release_device(&state, blk.location))
	testing.expect_value(t, state.counters.active_bindings, u64(0))
	_, rebind_ref, _ := scan_and_bind(&state, &blk, 9)
	testing.expect_value(t, rebind_ref, Devices_Bind_Refusal.None)
	testing.expect_value(t, release_service(&state, 9), u32(1))
	testing.expect_value(t, state.counters.active_bindings, u64(0))
}

// Lookup_Identity: an uninitialized state, the reserved identifiers, an
// unknown pair and a vendor of one entry with the device of another are
// refused, and each refusal counts; each default identity is found last.
@(test)
lookup_identity_refuses_unknown_and_reserved_identities :: proc(t: ^testing.T) {
	state: Devices_State
	_, uninitialized := lookup_identity(&state, rd.PCI_VENDOR_VIRTIO, rd.PCI_DEVICE_VIRTIO_BLOCK)
	testing.expect_value(t, uninitialized, rd.Device_Identity_Refusal.Corrupt_Table_Count)
	_, nil_state := lookup_identity(nil, rd.PCI_VENDOR_VIRTIO, rd.PCI_DEVICE_VIRTIO_BLOCK)
	testing.expect_value(t, nil_state, rd.Device_Identity_Refusal.Corrupt_Table_Count)
	state_init(&state)
	refused := [?][2]u16{{0, rd.PCI_DEVICE_VIRTIO_BLOCK}, {0xFFFF, rd.PCI_DEVICE_VIRTIO_BLOCK}, {rd.PCI_VENDOR_VIRTIO, 0}, {rd.PCI_VENDOR_VIRTIO, 0xFFFF}}
	for pair in refused {
		_, refusal := lookup_identity(&state, pair[0], pair[1])
		testing.expect_value(t, refusal, rd.Device_Identity_Refusal.Invalid_Pci_Id)
	}
	_, unknown := lookup_identity(&state, 0x8086, 0x29C0)
	testing.expect_value(t, unknown, rd.Device_Identity_Refusal.Unknown_Identity)
	_, crossed := lookup_identity(&state, rd.PCI_VENDOR_INFINEON_TPM, rd.PCI_DEVICE_VIRTIO_BLOCK)
	testing.expect_value(t, crossed, rd.Device_Identity_Refusal.Unknown_Identity)
	testing.expect_value(t, state.counters.total_refusals, u64(len(refused) + 2))
	for index in 0 ..< int(state.identities.count) {
		expected := state.identities.entries[index]
		entry, refusal := lookup_identity(&state, expected.pci_vendor_id, expected.pci_device_id)
		testing.expect_value(t, refusal, rd.Device_Identity_Refusal.None)
		testing.expect_value(t, entry, expected)
	}
	testing.expect_value(t, state.counters.total_refusals, u64(len(refused) + 2))
}

@(test)
all_device_classes_and_capacity_bound :: proc(t: ^testing.T) {
	state: Devices_State
	state_init(&state)

	// Bind one device of every VirtIO class plus TPM.
	virtio_ids := [6]struct {
		id:   u16,
		role: rd.Device_Class_Role,
	}{
		{rd.PCI_DEVICE_VIRTIO_BLOCK, .Block_Device},
		{rd.PCI_DEVICE_VIRTIO_NETWORK, .Network_Device},
		{rd.PCI_DEVICE_VIRTIO_SOUND, .Sound_Device},
		{rd.PCI_DEVICE_VIRTIO_ENTROPY, .Entropy_Device},
		{rd.PCI_DEVICE_VIRTIO_INPUT, .Input_Device},
		{rd.PCI_DEVICE_VIRTIO_GPU, .Gpu_Device},
	}
	for item, idx in virtio_ids {
		dev := make_virtio_device(0, u8(idx), 0, item.id, 0xFE10_0000 + u64(idx) * 0x10000)
		spec, ref, _ := scan_and_bind(&state, &dev, u32(idx + 1))
		testing.expect_value(t, ref, Devices_Bind_Refusal.None)
		testing.expect_value(t, spec.role, item.role)
	}

	tpm := rd.Pci_Discovered_Device {
		location      = {bus = 0, device = 0x1F, function = 0},
		pci_vendor_id = rd.PCI_VENDOR_INFINEON_TPM,
		pci_device_id = rd.PCI_DEVICE_TPM_SLB9670,
		bars          = {0 = {base_address = 0xFED4_0000, page_count = 5}},
		bar_count     = 1,
		has_interrupt = false,
	}
	tpm_spec, tpm_ref, _ := scan_and_bind(&state, &tpm, 99)
	testing.expect_value(t, tpm_ref, Devices_Bind_Refusal.None)
	testing.expect_value(t, tpm_spec.role, rd.Device_Class_Role.Tpm_Device)
	testing.expect(t, !tpm_spec.iommu_allowed)

	// Fill up to MAX_DEVICE_BINDINGS and verify bound+1 returns Table_Full.
	for idx := int(state.counters.active_bindings); idx < MAX_DEVICE_BINDINGS; idx += 1 {
		dev := make_virtio_device(1, u8(idx % 32), u8(idx / 32), rd.PCI_DEVICE_VIRTIO_BLOCK, 0xFE80_0000 + u64(idx) * 0x10000)
		_, ref, _ := scan_and_bind(&state, &dev, u32(200 + idx))
		testing.expect_value(t, ref, Devices_Bind_Refusal.None)
	}
	overflow := make_virtio_device(2, 0, 0, rd.PCI_DEVICE_VIRTIO_BLOCK, 0xFF00_0000)
	_, full_ref, _ := scan_and_bind(&state, &overflow, 999)
	testing.expect_value(t, full_ref, Devices_Bind_Refusal.Table_Full)
}
