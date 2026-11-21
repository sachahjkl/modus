#+build amd64
package hash_table

import "base:intrinsics"

// The SSE2 forms of the group matches of group_match.odin: one load of the
// 16 control bytes, one compare of 16 lanes, and the bit 7 of each lane
// gathered into a mask (pmovmskb). No table lookup in lanes: a byte
// shuffle by a run-time index is slow on plain x86-64, and a match needs
// none.

@(private)
Sixteen_Controls :: #simd[GROUP_WIDTH]u8

group_match_tag_sse2 :: #force_inline proc "contextless" (controls: ^[GROUP_WIDTH]u8, tag: u8) -> u16 {
	lanes := intrinsics.unaligned_load((^Sixteen_Controls)(controls))
	equal := intrinsics.simd_lanes_eq(lanes, Sixteen_Controls(tag))
	return transmute(u16)intrinsics.simd_extract_msbs(equal)
}

group_match_empty_sse2 :: #force_inline proc "contextless" (controls: ^[GROUP_WIDTH]u8) -> u16 {
	lanes := intrinsics.unaligned_load((^Sixteen_Controls)(controls))
	equal := intrinsics.simd_lanes_eq(lanes, Sixteen_Controls(u8(Control_Mark.Empty)))
	return transmute(u16)intrinsics.simd_extract_msbs(equal)
}

group_match_free_sse2 :: #force_inline proc "contextless" (controls: ^[GROUP_WIDTH]u8) -> u16 {
	lanes := intrinsics.unaligned_load((^Sixteen_Controls)(controls))
	return ~transmute(u16)intrinsics.simd_extract_msbs(lanes)
}
