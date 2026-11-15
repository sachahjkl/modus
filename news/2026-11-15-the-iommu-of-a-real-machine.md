title: The IOMMU takes the form of a real machine
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

A machine of Intel has more than one remapping unit, devices behind bridges, and memory that the firmware keeps for a device. The kernel now programs up to 4 units, and gives each device the unit that the firmware names for it. A device behind a bridge of PCI Express has its own domain. A device behind an older bridge of PCI gets none, and the log says why: every device behind such a bridge has the same name for the IOMMU. The memory that the firmware keeps for a device stays mapped for that device, and no program gets it. On a machine with the IOMMU, the memory of an endpoint of the network no longer needs 512 KiB in one run: the device sees its pages in one run through the IOMMU. The test machine with the IOMMU puts its disk of the measures behind a bridge, and the device of that disk still reaches only the memory of its service.
