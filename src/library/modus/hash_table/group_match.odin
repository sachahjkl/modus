package hash_table

// The match of one group of 16 control bytes: a mask of 16 bits, bit i for
// the control byte i. The public procedures choose the form by the target
// at compile time (docs/SIMD.md, "1. The rule of the same bytes"); the
// scalar forms are the reference of the host tests and the code of a
// target that is not amd64.

// group_match_tag gives the control bytes equal to a tag: the full slots
// whose key can be the key searched.
group_match_tag :: #force_inline proc "contextless" (controls: ^[GROUP_WIDTH]u8, tag: u8) -> u16 {
	when ODIN_ARCH == .amd64 {
		return group_match_tag_sse2(controls, tag)
	} else {
		return group_match_tag_scalar(controls, tag)
	}
}

// group_match_empty gives the empty slots: a slot that no key took since
// the last rebuild of the table. A search stops at a group that has one.
group_match_empty :: #force_inline proc "contextless" (controls: ^[GROUP_WIDTH]u8) -> u16 {
	when ODIN_ARCH == .amd64 {
		return group_match_empty_sse2(controls)
	} else {
		return group_match_empty_scalar(controls)
	}
}

// group_match_free gives the slots that an insert can take: empty or
// deleted, the control bytes with bit 7 clear.
group_match_free :: #force_inline proc "contextless" (controls: ^[GROUP_WIDTH]u8) -> u16 {
	when ODIN_ARCH == .amd64 {
		return group_match_free_sse2(controls)
	} else {
		return group_match_free_scalar(controls)
	}
}

group_match_tag_scalar :: proc "contextless" (controls: ^[GROUP_WIDTH]u8, tag: u8) -> (mask: u16) {
	for control, lane in controls {
		if control == tag {
			mask |= 1 << uint(lane)
		}
	}
	return
}

group_match_empty_scalar :: proc "contextless" (controls: ^[GROUP_WIDTH]u8) -> (mask: u16) {
	for control, lane in controls {
		if control == u8(Control_Mark.Empty) {
			mask |= 1 << uint(lane)
		}
	}
	return
}

group_match_free_scalar :: proc "contextless" (controls: ^[GROUP_WIDTH]u8) -> (mask: u16) {
	for control, lane in controls {
		if control & FULL_BIT == 0 {
			mask |= 1 << uint(lane)
		}
	}
	return
}
