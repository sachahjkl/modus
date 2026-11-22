// Pure freestanding multi-process zero-copy buffer handoff and 2 MiB large-page
// surface/image/arena descriptor contract.
//
// Enforces single-writer ownership transfer across pipeline stages: while a
// stage holds .Write ownership, no other stage can read or write; once sealed
// into .Read_Only, multiple downstream stages can share the same memory object
// with zero byte copies until all readers release.
package zero_copy_buffer

import "modus:contract/enum_word"

LARGE_PAGE_BYTES :: u64(2 * 1024 * 1024) // 2 MiB x86-64 huge page
SMALL_PAGE_BYTES :: u64(4096)
MAX_PIPELINE_BUFFERS :: 32

Buffer_State :: enum u8 {
	Free      = 0,
	Writing   = 1,
	Read_Only = 2,
}

buffer_state_of_word :: proc "contextless" (word: u64) -> (s: Buffer_State, ok: bool) {
	return enum_word.member_of_word(Buffer_State, word)
}

Buffer_Refusal :: enum u8 {
	None             = 0,
	Nil_Pool         = 1,
	Pool_Full        = 2,
	Invalid_Size     = 3,
	Bad_Handle       = 4,
	Wrong_Owner      = 5,
	Wrong_State      = 6,
	Readers_Active   = 7,
}

Buffer_Descriptor :: struct {
	id:           u64,
	state:        Buffer_State,
	owner_stage:  u64,
	reader_count: u32,
	byte_size:    u64,
	large_pages:  u32, // Number of 2 MiB pages backing the buffer (0 if 4 KiB pages)
	small_pages:  u32,
	generation:   u32,
}

Buffer_Pool :: struct {
	slots:   [MAX_PIPELINE_BUFFERS]Buffer_Descriptor,
	next_id: u64,
}

pool_init :: proc "contextless" (p: ^Buffer_Pool) {
	if p == nil {
		return
	}
	p^ = {next_id = 1}
}

// pages_for_buffer computes the optimal 2 MiB large-page + 4 KiB tail split
// for surfaces, decoded pictures, and arenas.
pages_for_buffer :: proc "contextless" (byte_size: u64) -> (large_pages, small_pages: u32, ok: bool) {
	if byte_size == 0 || byte_size > u64(1024) * LARGE_PAGE_BYTES {
		return 0, 0, false
	}
	lp := byte_size / LARGE_PAGE_BYTES
	rem := byte_size % LARGE_PAGE_BYTES
	sp := (rem + SMALL_PAGE_BYTES - 1) / SMALL_PAGE_BYTES
	return u32(lp), u32(sp), true
}

pool_acquire_for_write :: proc "contextless" (p: ^Buffer_Pool, writer_stage: u64, byte_size: u64) -> (id: u64, refusal: Buffer_Refusal) {
	if p == nil {
		return 0, .Nil_Pool
	}
	lp, sp, ok := pages_for_buffer(byte_size)
	if !ok || writer_stage == 0 {
		return 0, .Invalid_Size
	}
	for &s in p.slots {
		if s.state == .Free {
			assigned := p.next_id
			p.next_id += 1
			s = {
				id          = assigned,
				state       = .Writing,
				owner_stage = writer_stage,
				byte_size   = byte_size,
				large_pages = lp,
				small_pages = sp,
				generation  = s.generation + 1,
			}
			return assigned, .None
		}
	}
	return 0, .Pool_Full
}

pool_seal_to_readers :: proc "contextless" (p: ^Buffer_Pool, id: u64, writer_stage: u64, reader_count: u32) -> Buffer_Refusal {
	if p == nil {
		return .Nil_Pool
	}
	if reader_count == 0 {
		return .Invalid_Size
	}
	for &s in p.slots {
		if s.id == id && s.state != .Free {
			if s.state != .Writing {
				return .Wrong_State
			}
			if s.owner_stage != writer_stage {
				return .Wrong_Owner
			}
			s.state = .Read_Only
			s.owner_stage = 0
			s.reader_count = reader_count
			return .None
		}
	}
	return .Bad_Handle
}

pool_reader_release :: proc "contextless" (p: ^Buffer_Pool, id: u64) -> (freed: bool, refusal: Buffer_Refusal) {
	if p == nil {
		return false, .Nil_Pool
	}
	for &s in p.slots {
		if s.id == id && s.state != .Free {
			if s.state != .Read_Only || s.reader_count == 0 {
				return false, .Wrong_State
			}
			s.reader_count -= 1
			if s.reader_count == 0 {
				s.state = .Free
				s.id = 0
				return true, .None
			}
			return false, .None
		}
	}
	return false, .Bad_Handle
}
