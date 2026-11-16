title: The devices behind an older PCI bridge work with the IOMMU on
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

An older bridge of PCI makes the requests of each device behind it with one requester, so the IOMMU cannot tell those devices apart. Until now the kernel refused each of their accesses. Now they have one domain. The kernel makes it only when one service holds the registers of each device behind the bridge, and ends it when that service lets one of them go. The root service gives them all to one service. The test machine with the IOMMU of AMD has a disk and an entropy device behind such a bridge: the disk reads and writes through the shared domain, and the kernel refuses the domain when the service gives back the registers of the entropy device.
