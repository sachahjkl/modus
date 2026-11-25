type: Added

**Per-function ECAM page isolation, multi-vCPU Linux guest MADT and store-backed image descriptors, and counted module floors with glyph cache memory**: extended `modus:contract/pci_topology` with `Ecam_Region` per-function 4 KiB page addressing, `modus:contract/guest_os` with deterministic ACPI MADT Local APIC generation and store-backed guest image validation, and `modus:contract/work_budget` with overflow-safe counted module floor summation including per-copy text glyph caches.
