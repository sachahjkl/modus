// Per-function PCIe Enhanced Configuration Access Mechanism (ECAM) page
// addressing contract (src/md/api/root_service_split.md).
//
// Each PCIe function owns one dedicated 4 KiB physical page in the ECAM MMIO
// window so the root core can hand a device service a memory handle covering
// exclusively its own function's configuration registers without exposing
// legacy configuration ports or neighboring devices.
//
// Pure freestanding contract: zero kernel calls, zero host imports, zero
// heap allocation.
package pci_topology

import "modus:contract/enum_word"

// Format property: PCIe ECAM assigns one 4 KiB page per (bus, device, function).
ECAM_FUNCTION_PAGE_BYTES :: u64(4096)
ECAM_BUS_SHIFT :: u64(20)      // 1 MiB per bus (32 devices x 8 functions x 4 KiB).
ECAM_DEVICE_SHIFT :: u64(15)   // 32 KiB per device (8 functions x 4 KiB).
ECAM_FUNCTION_SHIFT :: u64(12) // 4 KiB per function.
ECAM_BUS_ALIGN_MASK :: (u64(1) << ECAM_BUS_SHIFT) - 1
ECAM_DEVICES_PER_BUS :: u8(32)
ECAM_FUNCTIONS_PER_DEVICE :: u8(8)

// Closed set of refusals for ECAM region and per-function page address checks.
// Explicit values cross transport borders.
Ecam_Refusal :: enum u8 {
	None                  = 0,
	Bad_Base              = 1,
	Bad_Bus_Range         = 2,
	Bus_Out_Of_Range      = 3,
	Device_Out_Of_Range   = 4,
	Function_Out_Of_Range = 5,
	Address_Overflow      = 6,
}

// One ACPI MCFG ECAM region covering [start_bus, end_bus] at a 1 MiB aligned
// physical base address.
Ecam_Region :: struct {
	base_physical_address: u64,
	start_bus:             u8,
	end_bus:               u8,
}

// ecam_refusal_of_word converts a raw word into Ecam_Refusal at a border,
// refusing any word that does not name a member.
ecam_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Ecam_Refusal, ok: bool) {
	return enum_word.member_of_word(Ecam_Refusal, word)
}

// ecam_region_validate checks that region has a non-zero 1 MiB aligned base,
// a valid non-inverted bus range, and a span that does not overflow u64.
ecam_region_validate :: proc "contextless" (region: Ecam_Region) -> Ecam_Refusal {
	if region.base_physical_address == 0 || (region.base_physical_address & ECAM_BUS_ALIGN_MASK) != 0 {
		return .Bad_Base
	}
	if region.start_bus > region.end_bus {
		return .Bad_Bus_Range
	}
	bus_count := u64(region.end_bus - region.start_bus) + 1
	span_bytes := bus_count << ECAM_BUS_SHIFT
	if region.base_physical_address > max(u64) - span_bytes {
		return .Address_Overflow
	}
	return .None
}

// ecam_function_page_address computes the exact 4 KiB physical page address of
// (bus, device, function) inside region:
//   base + (((bus - start_bus) << 20) | (device << 15) | (function << 12))
// Refuses misaligned or overflowing regions, out-of-range bus numbers,
// device >= 32, and function >= 8.
ecam_function_page_address :: proc "contextless" (
	region: Ecam_Region,
	bus: u8,
	device: u8,
	function: u8,
) -> (physical_page: u64, refusal: Ecam_Refusal) {
	if reg_ref := ecam_region_validate(region); reg_ref != .None {
		return 0, reg_ref
	}
	if bus < region.start_bus || bus > region.end_bus {
		return 0, .Bus_Out_Of_Range
	}
	if device >= ECAM_DEVICES_PER_BUS {
		return 0, .Device_Out_Of_Range
	}
	if function >= ECAM_FUNCTIONS_PER_DEVICE {
		return 0, .Function_Out_Of_Range
	}
	offset := (u64(bus - region.start_bus) << ECAM_BUS_SHIFT) | (u64(device) << ECAM_DEVICE_SHIFT) | (u64(function) << ECAM_FUNCTION_SHIFT)
	if region.base_physical_address > max(u64) - offset {
		return 0, .Address_Overflow
	}
	page_addr := region.base_physical_address + offset
	if page_addr > max(u64) - ECAM_FUNCTION_PAGE_BYTES {
		return 0, .Address_Overflow
	}
	return page_addr, .None
}

// ecam_functions_disjoint reports whether two valid (bus, device, function)
// addresses in region map to distinct non-overlapping 4 KiB ECAM pages.
ecam_functions_disjoint :: proc "contextless" (
	region: Ecam_Region,
	bus_a, dev_a, fn_a: u8,
	bus_b, dev_b, fn_b: u8,
) -> (disjoint: bool, refusal: Ecam_Refusal) {
	addr_a, ref_a := ecam_function_page_address(region, bus_a, dev_a, fn_a)
	if ref_a != .None {
		return false, ref_a
	}
	addr_b, ref_b := ecam_function_page_address(region, bus_b, dev_b, fn_b)
	if ref_b != .None {
		return false, ref_b
	}
	return addr_a != addr_b, .None
}
