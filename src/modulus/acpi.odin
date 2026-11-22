package kernel

import "base:intrinsics"

// The reader of the ACPI tables that the firmware gives, through the
// direct map. The IOMMU and the search of the processors use it. A browser
// machine has no ACPI root, so each read gives nil.

direct_map_size: u64

// acpi_bytes gives count bytes of physical memory, or nil if the direct
// map does not hold them.
@(private = "file")
acpi_bytes :: proc "contextless" (address: u64, count: u64) -> [^]u8 {
	// No sum: an address of the firmware near 2^64 would wrap it.
	if address == 0 || count > direct_map_size || address > direct_map_size - count {
		return nil
	}
	return ([^]u8)(direct(address, u8))
}

@(private = "file")
load :: proc "contextless" (bytes: [^]u8, offset: u64, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(&bytes[offset]))
}

ACPI_HEADER_SIZE :: 36

// acpi_table gives the ACPI table with this signature, and its size. The
// IOMMU reads the tables DMAR and MCFG with it (iommu.odin).
acpi_table :: proc "contextless" (root: u64, signature: string) -> (table: [^]u8, size: u64) {
	record := acpi_bytes(root, 36)
	if record == nil || string(record[:8]) != "RSD PTR " {
		return nil, 0
	}
	list_address := u64(load(record, 16, u32))
	entry_size := u64(4)
	if record[15] >= 2 && load(record, 24, u64) != 0 {
		list_address = load(record, 24, u64)
		entry_size = 8
	}
	list := acpi_bytes(list_address, ACPI_HEADER_SIZE)
	if list == nil {
		return nil, 0
	}
	list_size := u64(load(list, 4, u32))
	if acpi_bytes(list_address, list_size) == nil {
		return nil, 0
	}
	for offset := u64(ACPI_HEADER_SIZE); offset + entry_size <= list_size; offset += entry_size {
		address := entry_size == 8 ? load(list, offset, u64) : u64(load(list, offset, u32))
		table = acpi_bytes(address, ACPI_HEADER_SIZE)
		if table == nil || string(table[:4]) != signature {
			continue
		}
		size = u64(load(table, 4, u32))
		if acpi_bytes(address, size) != nil {
			return table, size
		}
	}
	return nil, 0
}
