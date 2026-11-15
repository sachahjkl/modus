title: The IOMMU of AMD holds a device in the memory of its service
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

The kernel programs the IOMMU of AMD when the firmware lists one, as it programs the IOMMU of Intel. One boot image runs on both. A device reads and writes only the pages that its service declared, and sends only the message interrupts that its service was given. A device with no service reaches no memory and sends no interrupt. A refused access is one line on the log with the device, the address and a count, and no program stops. The test machine with the IOMMU of AMD starts the whole system with translation and interrupt remapping on. A test device service then gets its message interrupt through the interrupt table of its device, and reads a block into a page that it no longer declares: the page keeps its bytes, and the line of the fault names the device. The emulated unit records no refused interrupt, so the refusal of a forged interrupt is tested on the IOMMU of Intel only.
