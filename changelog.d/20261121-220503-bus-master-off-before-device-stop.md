type: Fixed

**The bus master off before a device service stops.** The root service now clears PCI Bus Master on a device before calling `Process_Stop` on every device service, preventing memory accesses between service stop and reap on machines with or without an IOMMU.
