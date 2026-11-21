package line_editor

// The vector form of the fuzzy match (src/md/features/fuzzy_match.md, "The
// vector form"). It uses portable 128-bit vectors (#simd[16]u8) and
// base:intrinsics, which lower to SSE2 on x86-64 and work on every
// architecture. It gives the result of fuzzy_match_scalar for every
// input: a name or query with a byte past ASCII goes to the scalar form,
// and for a name in ASCII a byte place is a character place, so the two
// passes find the places of the scalar form from a mask of each query
// character.

import "base:intrinsics"

@(private)
BLOCK_SIZE :: 16 // The bytes of the name in one vector.
@(private)
BLOCK_CAPACITY :: NAME_SCAN_LIMIT / BLOCK_SIZE
#assert(NAME_SCAN_LIMIT % BLOCK_SIZE == 0)
#assert(NAME_SCAN_LIMIT == 128) // A mask of the places of the name is one u128.

@(private)
Block :: #simd[BLOCK_SIZE]u8

// The scalar form decodes each control character as the replacement
// character, so two control characters are equal there. In the lowered
// name each control byte becomes this byte past ASCII, which no lowered
// byte of ASCII equals.
@(private)
CONTROL_MARK :: 0x80

// block_lowered gives the bytes of ASCII as the scalar form compares them:
// 'A' to 'Z' lowered, each control byte as CONTROL_MARK.
@(private)
block_lowered :: #force_inline proc "contextless" (block: Block) -> Block {
	upper := intrinsics.simd_bit_and(intrinsics.simd_lanes_ge(block, Block('A')), intrinsics.simd_lanes_le(block, Block('Z')))
	control := intrinsics.simd_bit_or(intrinsics.simd_lanes_lt(block, Block(0x20)), intrinsics.simd_lanes_eq(block, Block(0x7F)))
	lowered := intrinsics.simd_bit_or(block, intrinsics.simd_bit_and(upper, Block(0x20)))
	return intrinsics.simd_bit_or(intrinsics.simd_bit_and(lowered, intrinsics.simd_bit_xor(control, Block(0xFF))), intrinsics.simd_bit_and(control, Block(CONTROL_MARK)))
}

fuzzy_match_vectors :: proc "contextless" (query: string, name: string) -> (score: int, places: Match_Places, matched: bool) {
	if len(query) > QUERY_LIMIT {
		return 0, {}, false
	}
	if len(query) == 0 {
		return 0, {}, true
	}
	length := min(len(name), NAME_SCAN_LIMIT)
	block_count := (length + BLOCK_SIZE - 1) / BLOCK_SIZE
	name_bytes := raw_data(name)

	// The blocks of the name, lowered. A block that the name does not fill
	// is copied into zeros: no load reads past the slice of the caller.
	blocks: [BLOCK_CAPACITY]Block = ---
	any_high: Block
	for index in 0 ..< block_count {
		start := index * BLOCK_SIZE
		block: Block
		if start + BLOCK_SIZE <= length {
			block = intrinsics.unaligned_load((^Block)(&name_bytes[start]))
		} else {
			tail: [BLOCK_SIZE]u8
			intrinsics.mem_copy_non_overlapping(&tail, &name_bytes[start], length - start)
			block = transmute(Block)tail
		}
		any_high = intrinsics.simd_bit_or(any_high, block)
		blocks[index] = block_lowered(block)
	}
	if intrinsics.simd_extract_msbs(any_high) != {} {
		return fuzzy_match_scalar(query, name)
	}
	// A byte of the query past ASCII: the scalar form decides. An invalid
	// byte of the query is the replacement character, which a control
	// byte of the name equals.
	for index in 0 ..< len(query) {
		if query[index] >= 0x80 {
			return fuzzy_match_scalar(query, name)
		}
	}
	inside: u128 = length == NAME_SCAN_LIMIT ? max(u128) : (u128(1) << uint(length)) - 1

	// The mask of each query character, and the pass forward: the lowest
	// place of each character after the place before. A character that
	// the name lacks there ends the match.
	masks: [QUERY_LIMIT]u128 = ---
	query_count := len(query)
	floor := 0
	end := 0
	for number in 0 ..< query_count {
		wanted := query[number]
		if wanted >= 'A' && wanted <= 'Z' {
			wanted += 'a' - 'A'
		} else if wanted < 0x20 || wanted == 0x7F {
			wanted = CONTROL_MARK
		}
		wanted_block := Block(wanted)
		mask: u128
		for index in 0 ..< block_count {
			bits := transmute(u16)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(blocks[index], wanted_block))
			mask |= u128(bits) << uint(index * BLOCK_SIZE)
		}
		mask &= inside
		masks[number] = mask
		// A shift by the width of the word is not defined: the last place
		// of the name leaves no place after it.
		if floor >= NAME_SCAN_LIMIT {
			return 0, {}, false
		}
		after := mask & (max(u128) << uint(floor))
		if after == 0 {
			return 0, {}, false
		}
		end = int(intrinsics.count_trailing_zeros(after))
		floor = end + 1
	}

	// The pass back: the highest place of each character at or below the
	// place after it, so the latest start of the window that ends at end.
	positions: [QUERY_LIMIT]int = ---
	ceiling := end
	for number := query_count - 1; number >= 0; number -= 1 {
		at_or_below := ceiling >= NAME_SCAN_LIMIT - 1 ? max(u128) : (u128(1) << uint(ceiling + 1)) - 1
		// The pass forward found each character in order, so a place is
		// always there.
		position := NAME_SCAN_LIMIT - 1 - int(intrinsics.count_leading_zeros(masks[number] & at_or_below))
		positions[number] = position
		ceiling = position - 1
	}

	for number in 0 ..< query_count {
		position := positions[number]
		places += {position}
		score += SCORE_MATCH
		if position == 0 {
			score += SCORE_START
		} else if before := name[position - 1]; before == '.' || before == '_' {
			score += SCORE_SEGMENT
		}
		if number > 0 {
			gap := position - positions[number - 1] - 1
			if gap == 0 {
				score += SCORE_SIDE_BY_SIDE
			} else {
				score -= SCORE_GAP_OPEN + (gap - 1) * SCORE_GAP_CHARACTER
			}
		}
	}
	return score, places, true
}
