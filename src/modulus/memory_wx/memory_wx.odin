// Per-memory-object write-xor-execute tracking (src/md/features/guest.md,
// "The rule of property 11 for the process"; docs/PROPERTIES.md,
// "11. Reproducible system").
//
// Each memory object counts its live non-switching Write mappings, its live
// non-switching Execute mappings, and its live guest switching mappings under
// the frame lock:
//
//   - No memory object holds both a Write mapping and an Execute mapping at
//     the same time (in one process or across processes and guests).
//   - No memory object with a live guest switching mapping holds an Execute
//     mapping in any process (guest memory is never executable by a process
//     of the system).
//   - A guest switching mapping coexists with the VMM process's Write mapping
//     and with other switching mappings on the same guest RAM object.
//
// This package is pure and freestanding so host tests verify every transition
// and refusal edge directly.
package memory_wx

// Access is the write-xor-execute category of one live mapping.
Access :: enum u8 {
	Read_Only = 0, // Read-only or No_Access (non-switching).
	Write     = 1, // Non-switching mapping with active Write access.
	Execute   = 2, // Non-switching mapping with active Execute access.
	Switching = 3, // Guest switching mapping (limit allows both Write and Execute).
}

// Counts holds the live mapping counts per memory object, protected by the
// kernel frame lock.
Counts :: struct {
	write:     u32,
	execute:   u32,
	switching: u32,
}

// access_of_bits classifies a mapping from its active page bits and its
// limit bits. A switching mapping (limit allows both Write and Execute) stays
// Switching regardless of its current bits, because the next guest fault can
// switch any page between Write and Execute.
access_of_bits :: proc "contextless" (bits, limit_bits, page_present, page_write, page_no_execute: u64) -> Access {
	if limit_bits & page_write != 0 && limit_bits & page_no_execute == 0 {
		return .Switching
	}
	if bits & page_present == 0 {
		return .Read_Only
	}
	if bits & page_write != 0 {
		return .Write
	}
	if bits & page_no_execute == 0 {
		return .Execute
	}
	return .Read_Only
}

// can_claim reports whether a new mapping or whole-mapping protection gain
// with `access` can join `counts` without violating write-xor-execute.
can_claim :: proc "contextless" (counts: Counts, access: Access) -> bool {
	switch access {
	case .Read_Only:
		return true
	case .Write:
		return counts.execute == 0
	case .Execute:
		return counts.write == 0 && counts.switching == 0
	case .Switching:
		return counts.execute == 0
	}
	return false
}

// claim adds one mapping of `access` to `counts`, or returns false without
// modifying `counts` when a conflict or u32 saturation would occur.
claim :: proc "contextless" (counts: ^Counts, access: Access) -> bool {
	if !can_claim(counts^, access) {
		return false
	}
	switch access {
	case .Read_Only:
		return true
	case .Write:
		if counts.write == max(u32) {
			return false
		}
		counts.write += 1
		return true
	case .Execute:
		if counts.execute == max(u32) {
			return false
		}
		counts.execute += 1
		return true
	case .Switching:
		if counts.switching == max(u32) {
			return false
		}
		counts.switching += 1
		return true
	}
	return false
}

// release removes one mapping of `access` from `counts`, returning false
// without underflowing when the matching count is already 0.
release :: proc "contextless" (counts: ^Counts, access: Access) -> bool {
	switch access {
	case .Read_Only:
		return true
	case .Write:
		if counts.write == 0 {
			return false
		}
		counts.write -= 1
		return true
	case .Execute:
		if counts.execute == 0 {
			return false
		}
		counts.execute -= 1
		return true
	case .Switching:
		if counts.switching == 0 {
			return false
		}
		counts.switching -= 1
		return true
	}
	return false
}
