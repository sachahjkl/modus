#+build !freestanding
package memory_wx

import "core:testing"

@(private = "file")
TEST_PRESENT :: u64(1) << 0
@(private = "file")
TEST_WRITE :: u64(1) << 1
@(private = "file")
TEST_NX :: u64(1) << 63

// Refusals and edge cases come first: Write vs Execute, Execute vs Write,
// Switching vs Execute, Execute vs Switching, u32 overflow, and zero release
// underflow must all refuse with zero state change.
@(test)
wx_refusals_and_edges :: proc(t: ^testing.T) {
	// Write conflicts with Execute.
	c := Counts{write = 1}
	testing.expect(t, !can_claim(c, .Execute))
	testing.expect(t, !claim(&c, .Execute))
	testing.expect_value(t, c, Counts{write = 1})

	// Execute conflicts with Write and with Switching.
	e := Counts{execute = 1}
	testing.expect(t, !can_claim(e, .Write))
	testing.expect(t, !claim(&e, .Write))
	testing.expect(t, !can_claim(e, .Switching))
	testing.expect(t, !claim(&e, .Switching))
	testing.expect_value(t, e, Counts{execute = 1})

	// Switching conflicts with Execute.
	s := Counts{switching = 1}
	testing.expect(t, !can_claim(s, .Execute))
	testing.expect(t, !claim(&s, .Execute))
	testing.expect_value(t, s, Counts{switching = 1})

	// Release at zero refuses without underflow.
	zero: Counts
	testing.expect(t, !release(&zero, .Write))
	testing.expect(t, !release(&zero, .Execute))
	testing.expect(t, !release(&zero, .Switching))
	testing.expect(t, release(&zero, .Read_Only))
	testing.expect_value(t, zero, Counts{})

	// Saturation at max(u32) refuses without wrapping.
	sat_w := Counts{write = max(u32)}
	testing.expect(t, !claim(&sat_w, .Write))
	testing.expect_value(t, sat_w.write, max(u32))
	sat_e := Counts{execute = max(u32)}
	testing.expect(t, !claim(&sat_e, .Execute))
	testing.expect_value(t, sat_e.execute, max(u32))
	sat_s := Counts{switching = max(u32)}
	testing.expect(t, !claim(&sat_s, .Switching))
	testing.expect_value(t, sat_s.switching, max(u32))
}

// Allowed transitions and coexistence: shared Execute, shared Write, VMM Write
// with multiple guest Switching mappings, and downgrade-then-upgrade sequence
// (write -> unmap/protect -> execute -> unmap/protect -> write).
@(test)
wx_coexistence_and_lifecycle :: proc(t: ^testing.T) {
	c: Counts
	// VMM maps guest RAM Write, then maps two Switching ranges into guest.
	testing.expect(t, claim(&c, .Write))
	testing.expect(t, claim(&c, .Switching))
	testing.expect(t, claim(&c, .Switching))
	testing.expect_value(t, c, Counts{write = 1, switching = 2})
	// Read_Only always coexists.
	testing.expect(t, claim(&c, .Read_Only))
	// Normal Execute is refused while either Write or Switching is active.
	testing.expect(t, !claim(&c, .Execute))
	// Releasing VMM Write still keeps Switching blocking Execute.
	testing.expect(t, release(&c, .Write))
	testing.expect(t, !claim(&c, .Execute))
	// Releasing one Switching still blocks Execute; releasing both unlocks it.
	testing.expect(t, release(&c, .Switching))
	testing.expect(t, !claim(&c, .Execute))
	testing.expect(t, release(&c, .Switching))
	testing.expect_value(t, c, Counts{})

	// Multiple processes can map Execute together; Write is blocked until all leave.
	testing.expect(t, claim(&c, .Execute))
	testing.expect(t, claim(&c, .Execute))
	testing.expect(t, !claim(&c, .Write))
	testing.expect(t, release(&c, .Execute))
	testing.expect(t, !claim(&c, .Write))
	testing.expect(t, release(&c, .Execute))
	testing.expect(t, claim(&c, .Write))
	testing.expect(t, release(&c, .Write))
	testing.expect_value(t, c, Counts{})
}

// Bit classification matches normal mappings, No_Access mappings, and guest
// switching mappings across every Memory_Protect state.
@(test)
wx_access_classification :: proc(t: ^testing.T) {
	// Normal read-only, write, execute, and No_Access.
	testing.expect_value(t, access_of_bits(TEST_PRESENT | TEST_NX, TEST_PRESENT | TEST_NX, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Read_Only)
	testing.expect_value(t, access_of_bits(TEST_PRESENT | TEST_WRITE | TEST_NX, TEST_PRESENT | TEST_WRITE | TEST_NX, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Write)
	testing.expect_value(t, access_of_bits(TEST_PRESENT, TEST_PRESENT, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Execute)
	testing.expect_value(t, access_of_bits(0, TEST_PRESENT | TEST_WRITE | TEST_NX, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Read_Only)
	testing.expect_value(t, access_of_bits(0, TEST_PRESENT, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Read_Only)

	// Switching mapping (limit has Write and no NX) stays Switching across No_Access, Write, and Execute.
	sw_limit := TEST_PRESENT | TEST_WRITE
	testing.expect_value(t, access_of_bits(0, sw_limit, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Switching)
	testing.expect_value(t, access_of_bits(TEST_PRESENT | TEST_WRITE | TEST_NX, sw_limit, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Switching)
	testing.expect_value(t, access_of_bits(TEST_PRESENT, sw_limit, TEST_PRESENT, TEST_WRITE, TEST_NX), Access.Switching)
}
