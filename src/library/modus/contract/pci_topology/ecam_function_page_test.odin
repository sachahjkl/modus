#+build !freestanding
#+build !modus
package pci_topology

import "core:testing"

@(test)
ecam_refusal_border_and_validation_edges :: proc(t: ^testing.T) {
	ref, ok := ecam_refusal_of_word(u64(Ecam_Refusal.Address_Overflow))
	testing.expect(t, ok)
	testing.expect_value(t, ref, Ecam_Refusal.Address_Overflow)
	_, bad_high := ecam_refusal_of_word(u64(Ecam_Refusal.Address_Overflow) + 1)
	testing.expect(t, !bad_high)
	_, bad_max := ecam_refusal_of_word(max(u64))
	testing.expect(t, !bad_max)

	// Zero and misaligned bases refused.
	_, r := ecam_function_page_address({base_physical_address = 0, start_bus = 0, end_bus = 0}, 0, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Bad_Base)
	_, r = ecam_function_page_address({base_physical_address = 0xE000_1000, start_bus = 0, end_bus = 0}, 0, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Bad_Base)
	_, r = ecam_function_page_address({base_physical_address = 0xE00F_F000, start_bus = 0, end_bus = 0}, 0, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Bad_Base)

	// Inverted bus range refused.
	_, r = ecam_function_page_address({base_physical_address = 0xE000_0000, start_bus = 5, end_bus = 4}, 5, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Bad_Bus_Range)

	// Overflowing region refused.
	top_1m := max(u64) &~ ECAM_BUS_ALIGN_MASK
	_, r = ecam_function_page_address({base_physical_address = top_1m, start_bus = 0, end_bus = 1}, 0, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Address_Overflow)

	// Out-of-range bus, device, and function refused.
	region := Ecam_Region{base_physical_address = 0xE000_0000, start_bus = 2, end_bus = 5}
	_, r = ecam_function_page_address(region, 1, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Bus_Out_Of_Range)
	_, r = ecam_function_page_address(region, 6, 0, 0)
	testing.expect_value(t, r, Ecam_Refusal.Bus_Out_Of_Range)
	_, r = ecam_function_page_address(region, 2, 32, 0)
	testing.expect_value(t, r, Ecam_Refusal.Device_Out_Of_Range)
	_, r = ecam_function_page_address(region, 2, 255, 0)
	testing.expect_value(t, r, Ecam_Refusal.Device_Out_Of_Range)
	_, r = ecam_function_page_address(region, 2, 0, 8)
	testing.expect_value(t, r, Ecam_Refusal.Function_Out_Of_Range)
	_, r = ecam_function_page_address(region, 2, 0, 255)
	testing.expect_value(t, r, Ecam_Refusal.Function_Out_Of_Range)
}

@(test)
ecam_function_pages_are_exact_and_pairwise_disjoint :: proc(t: ^testing.T) {
	region := Ecam_Region{base_physical_address = 0xE000_0000, start_bus = 4, end_bus = 7}

	// Exact formula on first, middle, and last functions.
	p0, r0 := ecam_function_page_address(region, 4, 0, 0)
	testing.expect_value(t, r0, Ecam_Refusal.None)
	testing.expect_value(t, p0, u64(0xE000_0000))

	p1, r1 := ecam_function_page_address(region, 4, 31, 7)
	testing.expect_value(t, r1, Ecam_Refusal.None)
	testing.expect_value(t, p1, u64(0xE000_0000) + ((u64(31) << 15) | (u64(7) << 12)))

	p2, r2 := ecam_function_page_address(region, 5, 0, 0)
	testing.expect_value(t, r2, Ecam_Refusal.None)
	testing.expect_value(t, p2, u64(0xE010_0000))
	testing.expect_value(t, p2 - p1, ECAM_FUNCTION_PAGE_BYTES)

	// Exhaustively check all 256 functions on bus 4 are strictly increasing by 4 KiB
	// and never collide with any other function or with bus 5.
	prev: u64 = 0
	for dev in u8(0) ..< ECAM_DEVICES_PER_BUS {
		for fn in u8(0) ..< ECAM_FUNCTIONS_PER_DEVICE {
			addr, ref := ecam_function_page_address(region, 4, dev, fn)
			testing.expect_value(t, ref, Ecam_Refusal.None)
			testing.expect_value(t, addr % ECAM_FUNCTION_PAGE_BYTES, u64(0))
			if prev != 0 {
				testing.expect_value(t, addr - prev, ECAM_FUNCTION_PAGE_BYTES)
			}
			prev = addr
		}
	}

	// Identical tuple is not disjoint; distinct tuples across same/adjacent buses are disjoint.
	same, ref_same := ecam_functions_disjoint(region, 4, 3, 2, 4, 3, 2)
	testing.expect_value(t, ref_same, Ecam_Refusal.None)
	testing.expect(t, !same)

	diff_fn, ref_fn := ecam_functions_disjoint(region, 4, 3, 2, 4, 3, 3)
	testing.expect_value(t, ref_fn, Ecam_Refusal.None)
	testing.expect(t, diff_fn)

	diff_bus, ref_bus := ecam_functions_disjoint(region, 4, 31, 7, 5, 0, 0)
	testing.expect_value(t, ref_bus, Ecam_Refusal.None)
	testing.expect(t, diff_bus)
}
