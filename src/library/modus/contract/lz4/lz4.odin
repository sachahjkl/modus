// Freestanding, zero-allocation LZ4 raw block codec
// (src/md/data/performance_primitives.md).
//
// Implements the standard LZ4 raw block format:
//   Each sequence starts with a 1-byte token:
//     high nibble (bits 4..7): literal length (0..15; 15 extends by base-255 bytes)
//     low  nibble (bits 0..3): match length minus 4 (0..15; 15 extends by base-255 bytes)
//   Followed by literal bytes. The final sequence of a non-empty block stops
//   immediately after its literals with no offset and no match. Every earlier
//   sequence continues with a 16-bit little-endian match offset (1..65535) and
//   optional match-length extension bytes.
//
// Zero heap allocation: compress_block takes a caller-supplied 4096-entry u16
// hash table (8 KiB). Storing low 16-bit positions and checking wrapping u16
// deltas handles arbitrary block lengths beyond 64 KiB within the 65535-byte
// LZ4 match window.
//
// Both decompress_block_reference (byte-by-byte oracle) and decompress_block
// (8-byte word fast path) strictly validate every token, length extension,
// offset, and output bound so hostile inputs never read or write out of bounds.
package lz4

import "base:intrinsics"
import "modus:contract/byte_order"

// Minimum length of a back-reference match in the LZ4 block format.
MINIMUM_MATCH_LENGTH :: 4

// The last five bytes of a block are always emitted as literals so standard
// LZ4 decoders have a safe trailing literal run.
LAST_LITERALS_MINIMUM :: 5

// A match cannot begin inside the final twelve bytes of an input block.
MATCH_SEARCH_MARGIN :: 12

// Largest representable 16-bit back-reference distance.
MAXIMUM_MATCH_OFFSET :: 65535

// Largest uncompressed block length accepted by the codec (standard LZ4 limit).
MAXIMUM_BLOCK_BYTES :: 0x7E00_0000

// Number of bits indexing the caller-supplied compression hash table.
HASH_LOG_BITS :: 12

// Fixed entry count of the caller-supplied compression hash table (8 KiB).
HASH_TABLE_ENTRIES :: 1 << HASH_LOG_BITS

// Knuth 32-bit multiplicative hash constant for 4-byte sequence heads.
@(private)
HASH_MULTIPLIER :: u32(2654435761)

// Shift controlling search-step acceleration across incompressible stretches.
@(private)
ACCELERATION_STEP_SHIFT :: 6

// Caller-supplied scratch table for compress_block (8 KiB).
Hash_Table :: [HASH_TABLE_ENTRIES]u16

// Closed set of refusals returned by LZ4 compression and decompression.
Refusal :: enum u8 {
	None                   = 0,
	Source_Too_Large       = 1,
	Destination_Too_Small  = 2,
	Truncated              = 3,
	Zero_Match_Offset      = 4,
	Match_Offset_Too_Large = 5,
	Length_Overflow        = 6,
	Hash_Table_Nil         = 7,
}

// compress_bound returns the worst-case compressed byte length for a raw block
// of source_length bytes, or 0 when source_length is 0, negative, or above
// MAXIMUM_BLOCK_BYTES.
compress_bound :: proc "contextless" (source_length: int) -> int {
	if source_length <= 0 || source_length > MAXIMUM_BLOCK_BYTES {
		return 0
	}
	return source_length + (source_length / 255) + 16
}

@(private)
hash_four_bytes :: #force_inline proc "contextless" (word: u32) -> u32 {
	return (word * HASH_MULTIPLIER) >> (32 - HASH_LOG_BITS)
}

@(private)
read_u32_unaligned :: #force_inline proc "contextless" (bytes: [^]u8, offset: int) -> u32 {
	return intrinsics.unaligned_load((^u32)(&bytes[offset]))
}

@(private)
read_u64_unaligned :: #force_inline proc "contextless" (bytes: [^]u8, offset: int) -> u64 {
	return intrinsics.unaligned_load((^u64)(&bytes[offset]))
}

@(private)
extension_byte_count :: #force_inline proc "contextless" (length: int) -> int {
	if length < 15 {
		return 0
	}
	return (length - 15) / 255 + 1
}

@(private)
write_length_extension :: #force_inline proc "contextless" (destination: [^]u8, start_offset: int, length: int) -> int {
	offset := start_offset
	if length >= 15 {
		remaining := length - 15
		for remaining >= 255 {
			destination[offset] = 255
			offset += 1
			remaining -= 255
		}
		destination[offset] = u8(remaining)
		offset += 1
	}
	return offset
}

// copy_bytes_without_overlap copies count bytes from source to destination
// when the ranges do not overlap.
@(private)
copy_bytes_without_overlap :: #force_inline proc "contextless" (destination: [^]u8, source: [^]u8, count: int) {
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(destination, source, count)
	}
}

// compress_block compresses source into destination in standard LZ4 raw block
// format using the caller-supplied hash_table. The hash table is zeroed on
// entry so output is deterministic regardless of prior scratch contents.
compress_block :: proc "contextless" (source: []u8, destination: []u8, hash_table: ^Hash_Table) -> (written: int, refusal: Refusal) {
	if hash_table == nil {
		return 0, .Hash_Table_Nil
	}
	source_length := len(source)
	if source_length > MAXIMUM_BLOCK_BYTES {
		return 0, .Source_Too_Large
	}
	if source_length == 0 {
		return 0, .None
	}
	hash_table^ = {}

	source_pointer := raw_data(source)
	destination_pointer := raw_data(destination)
	destination_length := len(destination)
	output_position := 0
	anchor := 0

	if source_length >= MATCH_SEARCH_MARGIN + 1 {
		match_limit := source_length - LAST_LITERALS_MINIMUM
		search_limit := source_length - MATCH_SEARCH_MARGIN
		hash_table[hash_four_bytes(read_u32_unaligned(source_pointer, 0))] = 0
		position := 1

		encode_loop: for {
			forward_position := position
			search_step := 1
			step_counter := 1 << ACCELERATION_STEP_SHIFT
			candidate := -1

			for {
				position = forward_position
				forward_position += search_step
				step_counter += 1
				search_step = step_counter >> ACCELERATION_STEP_SHIFT

				if position > search_limit {
					break encode_loop
				}
				current_word := read_u32_unaligned(source_pointer, position)
				slot := hash_four_bytes(current_word)
				stored := hash_table[slot]
				hash_table[slot] = u16(position)
				delta := u16(position) - stored
				if delta != 0 {
					possible := position - int(delta)
					if possible >= 0 && read_u32_unaligned(source_pointer, possible) == current_word {
						candidate = possible
						break
					}
				}
			}

			// Extend the match backward into pending literals when both sides agree.
			for position > anchor && candidate > 0 && source_pointer[position - 1] == source_pointer[candidate - 1] {
				position -= 1
				candidate -= 1
			}

			literal_length := position - anchor
			match_offset := position - candidate

			// Extend the match forward up to match_limit using 8-byte comparisons.
			match_length := MINIMUM_MATCH_LENGTH
			when ODIN_ENDIAN == .Little {
				for position + match_length + 8 <= match_limit {
					difference := read_u64_unaligned(source_pointer, position + match_length) ~ read_u64_unaligned(source_pointer, candidate + match_length)
					if difference != 0 {
						match_length += int(intrinsics.count_trailing_zeros(difference) >> 3)
						break
					}
					match_length += 8
				}
			}
			for position + match_length < match_limit && source_pointer[position + match_length] == source_pointer[candidate + match_length] {
				match_length += 1
			}

			match_extra := match_length - MINIMUM_MATCH_LENGTH
			sequence_bytes := 1 + extension_byte_count(literal_length) + literal_length + 2 + extension_byte_count(match_extra)
			if output_position + sequence_bytes > destination_length {
				return 0, .Destination_Too_Small
			}

			literal_nibble := u8(min(literal_length, 15))
			match_nibble := u8(min(match_extra, 15))
			destination_pointer[output_position] = (literal_nibble << 4) | match_nibble
			output_position += 1

			output_position = write_length_extension(destination_pointer, output_position, literal_length)
			copy_bytes_without_overlap(&destination_pointer[output_position], &source_pointer[anchor], literal_length)
			output_position += literal_length

			byte_order.write_u16_little_endian(destination, output_position, u16(match_offset))
			output_position += 2

			output_position = write_length_extension(destination_pointer, output_position, match_extra)

			position += match_length
			anchor = position
			if position > search_limit {
				break
			}
			hash_table[hash_four_bytes(read_u32_unaligned(source_pointer, position - 2))] = u16(position - 2)
		}
	}

	// Emit the final literal-only sequence required by the LZ4 block format.
	last_literals := source_length - anchor
	final_bytes := 1 + extension_byte_count(last_literals) + last_literals
	if output_position + final_bytes > destination_length {
		return 0, .Destination_Too_Small
	}
	destination_pointer[output_position] = u8(min(last_literals, 15)) << 4
	output_position += 1
	output_position = write_length_extension(destination_pointer, output_position, last_literals)
	copy_bytes_without_overlap(&destination_pointer[output_position], &source_pointer[anchor], last_literals)
	output_position += last_literals

	return output_position, .None
}

// decompress_block_reference is the simple byte-by-byte reference decoder for
// standard LZ4 raw blocks. It enforces the exact same bounds checks and
// refusals as decompress_block and serves as the specification oracle in tests.
decompress_block_reference :: proc "contextless" (compressed: []u8, destination: []u8) -> (written: int, refusal: Refusal) {
	input_length := len(compressed)
	if input_length == 0 {
		return 0, .None
	}
	destination_length := len(destination)
	input_position := 0
	output_position := 0

	for input_position < input_length {
		token := compressed[input_position]
		input_position += 1

		literal_length := int(token >> 4)
		if literal_length == 15 {
			for {
				if input_position >= input_length {
					return 0, .Truncated
				}
				extra := int(compressed[input_position])
				input_position += 1
				if literal_length > MAXIMUM_BLOCK_BYTES - extra {
					return 0, .Length_Overflow
				}
				literal_length += extra
				if extra != 255 {
					break
				}
			}
		}

		if literal_length > input_length - input_position {
			return 0, .Truncated
		}
		if literal_length > destination_length - output_position {
			return 0, .Destination_Too_Small
		}
		for index in 0 ..< literal_length {
			destination[output_position + index] = compressed[input_position + index]
		}
		input_position += literal_length
		output_position += literal_length

		// A valid non-empty LZ4 block ends immediately after its final literals.
		if input_position == input_length {
			return output_position, .None
		}

		if input_length - input_position < 2 {
			return 0, .Truncated
		}
		match_offset := int(byte_order.read_u16_little_endian(compressed, input_position))
		input_position += 2
		if match_offset == 0 {
			return 0, .Zero_Match_Offset
		}
		if match_offset > output_position {
			return 0, .Match_Offset_Too_Large
		}

		match_length := int(token & 0x0F) + MINIMUM_MATCH_LENGTH
		if (token & 0x0F) == 15 {
			for {
				if input_position >= input_length {
					return 0, .Truncated
				}
				extra := int(compressed[input_position])
				input_position += 1
				if match_length > MAXIMUM_BLOCK_BYTES - extra {
					return 0, .Length_Overflow
				}
				match_length += extra
				if extra != 255 {
					break
				}
			}
		}

		if match_length > destination_length - output_position {
			return 0, .Destination_Too_Small
		}
		// Copy sequentially byte-by-byte so overlapping matches (offset < length)
		// repeat the pattern faithfully.
		match_source := output_position - match_offset
		for index in 0 ..< match_length {
			destination[output_position + index] = destination[match_source + index]
		}
		output_position += match_length
	}

	// Reached end of input immediately after a match without a final literal run.
	return 0, .Truncated
}

// decompress_block decodes a standard LZ4 raw block into destination using
// 8-byte copies for literals and non-overlapping or repeating matches while
// enforcing strict bounds checks identical to decompress_block_reference.
decompress_block :: proc "contextless" (compressed: []u8, destination: []u8) -> (written: int, refusal: Refusal) {
	input_length := len(compressed)
	if input_length == 0 {
		return 0, .None
	}
	destination_length := len(destination)
	input_pointer := raw_data(compressed)
	destination_pointer := raw_data(destination)
	input_position := 0
	output_position := 0

	for input_position < input_length {
		token := input_pointer[input_position]
		input_position += 1

		literal_length := int(token >> 4)
		if literal_length == 15 {
			for {
				if input_position >= input_length {
					return 0, .Truncated
				}
				extra := int(input_pointer[input_position])
				input_position += 1
				if literal_length > MAXIMUM_BLOCK_BYTES - extra {
					return 0, .Length_Overflow
				}
				literal_length += extra
				if extra != 255 {
					break
				}
			}
		}

		if literal_length > input_length - input_position {
			return 0, .Truncated
		}
		if literal_length > destination_length - output_position {
			return 0, .Destination_Too_Small
		}
		copy_bytes_without_overlap(&destination_pointer[output_position], &input_pointer[input_position], literal_length)
		input_position += literal_length
		output_position += literal_length

		if input_position == input_length {
			return output_position, .None
		}

		if input_length - input_position < 2 {
			return 0, .Truncated
		}
		match_offset := int(byte_order.read_u16_little_endian(compressed, input_position))
		input_position += 2
		if match_offset == 0 {
			return 0, .Zero_Match_Offset
		}
		if match_offset > output_position {
			return 0, .Match_Offset_Too_Large
		}

		match_length := int(token & 0x0F) + MINIMUM_MATCH_LENGTH
		if (token & 0x0F) == 15 {
			for {
				if input_position >= input_length {
					return 0, .Truncated
				}
				extra := int(input_pointer[input_position])
				input_position += 1
				if match_length > MAXIMUM_BLOCK_BYTES - extra {
					return 0, .Length_Overflow
				}
				match_length += extra
				if extra != 255 {
					break
				}
			}
		}

		if match_length > destination_length - output_position {
			return 0, .Destination_Too_Small
		}

		source_index := output_position - match_offset
		target_index := output_position
		remaining := match_length

		if match_offset >= 8 {
			// When offset >= 8, each 8-byte store finishes before any subsequent
			// 8-byte load can read it, even when offset < match_length.
			for remaining >= 8 {
				word := intrinsics.unaligned_load((^u64)(&destination_pointer[source_index]))
				intrinsics.unaligned_store((^u64)(&destination_pointer[target_index]), word)
				source_index += 8
				target_index += 8
				remaining -= 8
			}
			for remaining > 0 {
				destination_pointer[target_index] = destination_pointer[source_index]
				source_index += 1
				target_index += 1
				remaining -= 1
			}
		} else if match_offset == 1 {
			repeated_byte := destination_pointer[source_index]
			pattern := u64(repeated_byte) * 0x0101_0101_0101_0101
			for remaining >= 8 {
				intrinsics.unaligned_store((^u64)(&destination_pointer[target_index]), pattern)
				target_index += 8
				remaining -= 8
			}
			for remaining > 0 {
				destination_pointer[target_index] = repeated_byte
				target_index += 1
				remaining -= 1
			}
		} else if match_offset == 2 {
			pair := intrinsics.unaligned_load((^u16)(&destination_pointer[source_index]))
			pattern := u64(pair) * 0x0001_0001_0001_0001
			for remaining >= 8 {
				intrinsics.unaligned_store((^u64)(&destination_pointer[target_index]), pattern)
				source_index += 8
				target_index += 8
				remaining -= 8
			}
			for remaining > 0 {
				destination_pointer[target_index] = destination_pointer[source_index]
				source_index += 1
				target_index += 1
				remaining -= 1
			}
		} else if match_offset == 4 {
			quad := intrinsics.unaligned_load((^u32)(&destination_pointer[source_index]))
			pattern := u64(quad) | (u64(quad) << 32)
			for remaining >= 8 {
				intrinsics.unaligned_store((^u64)(&destination_pointer[target_index]), pattern)
				source_index += 8
				target_index += 8
				remaining -= 8
			}
			for remaining > 0 {
				destination_pointer[target_index] = destination_pointer[source_index]
				source_index += 1
				target_index += 1
				remaining -= 1
			}
		} else {
			for remaining > 0 {
				destination_pointer[target_index] = destination_pointer[source_index]
				source_index += 1
				target_index += 1
				remaining -= 1
			}
		}

		output_position += match_length
	}

	return 0, .Truncated
}
