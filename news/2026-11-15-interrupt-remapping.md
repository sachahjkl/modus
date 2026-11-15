title: A device sends only the interrupts that its service was given
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

A message interrupt is a write of 4 bytes to the interrupt addresses, and a device can make that write as any other. Before, a device service could give those addresses to its device as a buffer, and make it send any interrupt of the machine. The kernel now turns interrupt remapping on in the IOMMU of Intel. Each message interrupt that the kernel makes has an entry that names its device, and the IOMMU refuses the message to every other device. A refused interrupt writes one line on the log with the device, the entry and the reason, and nothing stops. The test machine with the IOMMU runs the whole system with remapping on. A test device service reads a block into the interrupt addresses, and the log shows that the IOMMU refused its messages. The IOMMU of AMD is not built yet.
