#+build !freestanding
package devices_core

import "core:testing"
import "modus:contract/pci_topology"
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

// A Bind_Device whose identity word names another record than the one in
// the bind place is refused, counted, and binds nothing: a word of another
// device, of another place, with a bit past the packed form, and the
// largest word. The word of the record binds it, last.
@(test)
bind_device_refuses_a_record_that_the_command_does_not_name :: proc(t: ^testing.T) {
	state: Devices_State
	blk := make_virtio_device(0, 0x10, 0, rd.PCI_DEVICE_VIRTIO_BLOCK, 0xFE00_0000)
	_, uninit_ref, _ := bind_device(&state, &blk, 1, rd.device_bind_identity_word(&blk))
	testing.expect_value(t, uninit_ref, Devices_Bind_Refusal.Uninitialized)

	state_init(&state)
	other_device := make_virtio_device(0, 0x10, 0, rd.PCI_DEVICE_VIRTIO_NETWORK, 0xFE10_0000)
	other_place := make_virtio_device(0, 0x11, 0, rd.PCI_DEVICE_VIRTIO_BLOCK, 0xFE20_0000)
	word := rd.device_bind_identity_word(&blk)
	wrong_words := [?]u64{rd.device_bind_identity_word(&other_device), rd.device_bind_identity_word(&other_place), word | 1 << 56, max(u64), 0}
	for wrong, index in wrong_words {
		before := state
		_, refusal, grant_refusal := bind_device(&state, &blk, 1, wrong)
		testing.expectf(t, refusal == .Identity_Mismatch, "the word %d is taken", index)
		testing.expect_value(t, grant_refusal, rd.Device_Grant_Refusal.None)
		testing.expect_value(t, state.counters.total_refusals, before.counters.total_refusals + 1)
		testing.expect_value(t, state.counters.active_bindings, before.counters.active_bindings)
		testing.expect(t, state.bindings == before.bindings)
	}
	spec, refusal, _ := bind_device(&state, &blk, 1, word)
	testing.expect_value(t, refusal, Devices_Bind_Refusal.None)
	testing.expect_value(t, spec.location, blk.location)
	testing.expect_value(t, state.counters.active_bindings, u64(1))
}

@(test)
pci_topology_ecam_ivmd_and_forged_irq_enforcement :: proc(t: ^testing.T) {
	state: Devices_State
	state_init(&state)

	// Unaligned ECAM base and inverted bus range are refused.
	testing.expect(t, !register_root_bus(&state, 0, 0, 15, 0xB000_0001))
	testing.expect(t, !register_root_bus(&state, 0, 16, 8, 0xB000_0000))
	testing.expect(t, !register_root_bus(&state, 0, 0, 15, 0))

	// Register valid segment 0 ECAM window [0..15] and number a PCIe bridge.
	testing.expect(t, register_root_bus(&state, 0, 0, 15, 0xB000_0000))
	// Overlapping root bus range in same segment is refused.
	testing.expect(t, !register_root_bus(&state, 0, 8, 20, 0xC000_0000))
	// Disjoint second root bus segment succeeds.
	testing.expect(t, register_root_bus(&state, 1, 0, 7, 0xD000_0000))

	sec_bus, bridge_ok := number_bridge(&state, 0, 0, 0x1C, 0)
	testing.expect(t, bridge_ok && sec_bus == 1)

	// Install shared multi-device IVMD reserved DMA range covering bus 0..1.
	testing.expect(t, register_ivmd(&state, 0xFE50_0000, 0xFE51_0000, 0x0000, 0x01FF, true))
	testing.expect(t, !register_ivmd(&state, 0xFE51_0000, 0xFE50_0000, 0x0000, 0x01FF, true))

	// A QEMU NVMe controller whose BAR collides with the IVMD range is refused.
	nvme_collision := rd.Pci_Discovered_Device{
		location         = {bus = sec_bus, device = 0, function = 0},
		pci_vendor_id    = rd.PCI_VENDOR_QEMU_NVME,
		pci_device_id    = rd.PCI_DEVICE_QEMU_NVME,
		bars             = {0 = {base_address = 0xFE50_4000, page_count = 4}},
		bar_count        = 1,
		interrupt_vector = 0x50,
		has_interrupt    = true,
	}
	_, ivmd_ref, _ := scan_and_bind(&state, &nvme_collision, 12)
	testing.expect_value(t, ivmd_ref, Devices_Bind_Refusal.Reserved_Dma_Collision)

	// A device outside the configured ECAM bus range [0..15] is refused.
	nvme_oob := nvme_collision
	nvme_oob.location.bus = 16
	nvme_oob.bars[0].base_address = 0xFE60_0000
	_, ecam_ref, _ := scan_and_bind(&state, &nvme_oob, 12)
	testing.expect_value(t, ecam_ref, Devices_Bind_Refusal.Ecam_Page_Conflict)

	// Valid QEMU NVMe device behind the bridge binds with exact 4 KiB ECAM page
	// and installs its AMD-Vi IRTE entry for forged-IRQ verification.
	nvme_ok := nvme_collision
	nvme_ok.bars[0].base_address = 0xFE60_0000
	spec, ok_ref, _ := scan_and_bind(&state, &nvme_ok, 12)
	testing.expect_value(t, ok_ref, Devices_Bind_Refusal.None)
	testing.expect_value(t, spec.role, rd.Device_Class_Role.Block_Device)

	binding, found := find_binding(&state, nvme_ok.location)
	testing.expect(t, found)
	expected_ecam, ecam_err := pci_topology.ecam_function_page_address(state.ecam_region, sec_bus, 0, 0)
	testing.expect_value(t, ecam_err, pci_topology.Ecam_Refusal.None)
	testing.expect_value(t, binding.ecam_function_page, expected_ecam)

	// Legitimate IRQ is allowed; forged source BDF or wrong vector is refused.
	testing.expect_value(t, verify_device_interrupt(&state, nvme_ok.location, 0x50), pci_topology.Iommu_Decision.Allow)
	testing.expect_value(t, verify_device_interrupt(&state, nvme_ok.location, 0x51), pci_topology.Iommu_Decision.Refuse_Forged_Irq)
	testing.expect_value(t, verify_device_interrupt(&state, {bus = 0, device = 1, function = 0}, 0x50), pci_topology.Iommu_Decision.Refuse_Forged_Irq)
	testing.expect_value(t, check_device_dma(&state, nvme_ok.location, 0xFE50_0000, 4096), pci_topology.Iommu_Decision.Refuse_Reserved)
	testing.expect_value(t, check_device_dma(&state, nvme_ok.location, 0xFE60_0000, 4096), pci_topology.Iommu_Decision.Allow)
}

@(test)
amd_iommu_irte_refuses_bad_vectors_exhaustion_and_unbinds_on_release :: proc(t: ^testing.T) {
	state: Devices_State
	state_init(&state)

	blk := make_virtio_device(0, 0x10, 0, rd.PCI_DEVICE_VIRTIO_BLOCK, 0xFE00_0000)

	// Interrupt vectors below 32 or above 255 are refused with Irte_Bind_Failed.
	low_vec := blk
	low_vec.interrupt_vector = 31
	_, low_ref, _ := scan_and_bind(&state, &low_vec, 1)
	testing.expect_value(t, low_ref, Devices_Bind_Refusal.Irte_Bind_Failed)
	testing.expect_value(t, state.counters.active_bindings, u64(0))
	testing.expect_value(t, state.iommu.irte_count, 0)

	high_vec := blk
	high_vec.interrupt_vector = 256
	_, high_ref, _ := scan_and_bind(&state, &high_vec, 1)
	testing.expect_value(t, high_ref, Devices_Bind_Refusal.Irte_Bind_Failed)
	testing.expect_value(t, state.counters.active_bindings, u64(0))
	testing.expect_value(t, state.iommu.irte_count, 0)

	// Repeated bind and release cycles beyond MAX_IOMMU_IRTE never leak IRTE slots,
	// and released devices fail forged-IRQ checks.
	for cycle in 0 ..< pci_topology.MAX_IOMMU_IRTE + 5 {
		_, ref, _ := scan_and_bind(&state, &blk, u32(10 + cycle))
		testing.expect_value(t, ref, Devices_Bind_Refusal.None)
		testing.expect_value(t, state.iommu.irte_count, 1)
		testing.expect_value(t, verify_device_interrupt(&state, blk.location, u8(blk.interrupt_vector)), pci_topology.Iommu_Decision.Allow)
		if cycle % 2 == 0 {
			testing.expect(t, release_device(&state, blk.location))
		} else {
			testing.expect_value(t, release_service(&state, u32(10 + cycle)), u32(1))
		}
		testing.expect_value(t, state.iommu.irte_count, 0)
		testing.expect_value(t, verify_device_interrupt(&state, blk.location, u8(blk.interrupt_vector)), pci_topology.Iommu_Decision.Refuse_Forged_Irq)
	}

	// Exhausting the IRTE table causes bind refusal with zero binding leak.
	for i in 0 ..< pci_topology.MAX_IOMMU_IRTE {
		testing.expect(t, pci_topology.amd_iommu_bind_irq(&state.iommu, u16(0x0200 + i), u8(0x40 + (i % 100)), 0))
	}
	_, full_ref, _ := scan_and_bind(&state, &blk, 99)
	testing.expect_value(t, full_ref, Devices_Bind_Refusal.Irte_Bind_Failed)
	testing.expect_value(t, state.counters.active_bindings, u64(0))
}
