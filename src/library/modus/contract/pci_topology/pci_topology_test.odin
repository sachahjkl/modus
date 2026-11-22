#+build !freestanding
package pci_topology

import "core:testing"

@(test)
pci_multi_root_bridges_and_amd_iommu_isolation :: proc(t: ^testing.T) {
	_, bad := iommu_decision_of_word(99)
	testing.expect(t, !bad)

	topo: Topology_State
	topology_init(&topo)
	// Two root buses: bus 0..127 and second root bus 128..255.
	testing.expect(t, topology_add_root_bus(&topo, 0, 0, 127, 0xE000_0000))
	testing.expect(t, topology_add_root_bus(&topo, 0, 128, 255, 0xE800_0000))
	// Overlapping root bus refused.
	testing.expect(t, !topology_add_root_bus(&topo, 0, 64, 150, 0xF000_0000))

	// PCIe-to-PCI bridge on bus 0 -> gets secondary bus 1; nested bridge on bus 1 -> gets bus 2 and widens parent subordinate to 2.
	b1, ok1 := topology_number_bridge(&topo, 0, 0, 3, 0)
	testing.expect(t, ok1 && b1 == 1)
	b2, ok2 := topology_number_bridge(&topo, 0, 1, 0, 0)
	testing.expect(t, ok2 && b2 == 2)
	testing.expect_value(t, topo.bridges[0].subordinate_bus, u8(2))

	// Bridge on second root bus 128 -> gets secondary bus 129.
	b3, ok3 := topology_number_bridge(&topo, 0, 128, 1, 0)
	testing.expect(t, ok3 && b3 == 129)

	// AMD-Vi IOMMU forged IRQ defense & shared multi-device IVMD.
	iommu: Amd_Iommu_Table
	amd_iommu_init(&iommu)
	testing.expect(t, amd_iommu_bind_irq(&iommu, 0x0100, 48, 0))
	testing.expect_value(t, amd_iommu_verify_interrupt(&iommu, 0x0100, 48), Iommu_Decision.Allow)
	testing.expect_value(t, amd_iommu_verify_interrupt(&iommu, 0x0200, 48), Iommu_Decision.Refuse_Forged_Irq)

	testing.expect(t, amd_iommu_add_ivmd(&iommu, 0x7000_0000, 0x7010_0000, 0x0100, 0x01FF, true))
	testing.expect_value(t, amd_iommu_dma_allowed(&iommu, 0x0108, 0x7000_2000, 4096), Iommu_Decision.Refuse_Reserved)
	testing.expect_value(t, amd_iommu_dma_allowed(&iommu, 0x0108, 0x8000_0000, 4096), Iommu_Decision.Allow)
}
