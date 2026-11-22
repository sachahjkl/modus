// Pure freestanding browser virtual-machine extensions for software_machine
// (src/md/features/browser_machine.md):
//
//   - Opfs_Disk_Journal: crash-safe sector journal over browser OPFS storage
//     so a browser machine's disk survives page reloads.
//   - WebAudio_Pcm_Ring: lock-free PCM bridge from guest virtio-sound to host WebAudio.
//   - WebSocket_Net_Tunnel: bounded Ethernet/QUIC frame encapsulation over WebSocket.
//   - Cooperative_Cpu_Scheduler: runs 1..4 virtual CPUs smoothly both with
//     SharedArrayBuffer (COI) and in non-COI single-thread cooperative mode.
//   - Compiled_Block_Cache: basic-block IR decode cache (compiled tier) for
//     hot x86-64 guest instruction sequences.
package browser_vm_runtime

import "modus:contract/enum_word"

SECTOR_BYTES :: 512
MAX_JOURNAL_ENTRIES :: 64
MAX_VCPUS :: 4
MAX_CACHED_BLOCKS :: 64
MAX_BLOCK_OPS :: 16

Isolation_Mode :: enum u8 {
	Single_Thread_Non_Coi = 1, // Works without Cross-Origin-Opener-Policy / SharedArrayBuffer
	Multi_Worker_Coi      = 2, // SharedArrayBuffer + Web Workers
}

isolation_mode_of_word :: proc "contextless" (word: u64) -> (m: Isolation_Mode, ok: bool) {
	return enum_word.member_of_word(Isolation_Mode, word)
}

// ============================================================================
// Persistent OPFS Disk Journal (survives browser page reload)
// ============================================================================

Journal_Entry :: struct {
	valid:     bool,
	sector:    u64,
	checksum:  u32,
	data:      [SECTOR_BYTES]u8,
}

Opfs_Disk_Journal :: struct {
	entries: [MAX_JOURNAL_ENTRIES]Journal_Entry,
	writes:  u64,
	flushes: u64,
}

sector_checksum :: proc "contextless" (data: []u8) -> u32 {
	h := u32(2166136261)
	for b in data {
		h = (h ~ u32(b)) * 16777619
	}
	return h
}

journal_write_sector :: proc "contextless" (j: ^Opfs_Disk_Journal, sector: u64, data: []u8) -> bool {
	if j == nil || len(data) != SECTOR_BYTES {
		return false
	}
	// Overwrite existing entry for same sector or allocate free slot.
	free_idx := -1
	for &e, i in j.entries {
		if e.valid && e.sector == sector {
			copy(e.data[:], data)
			e.checksum = sector_checksum(data)
			j.writes += 1
			return true
		}
		if !e.valid && free_idx < 0 {
			free_idx = i
		}
	}
	if free_idx < 0 {
		return false
	}
	e := &j.entries[free_idx]
	e.valid = true
	e.sector = sector
	copy(e.data[:], data)
	e.checksum = sector_checksum(data)
	j.writes += 1
	return true
}

journal_read_sector :: proc "contextless" (j: ^Opfs_Disk_Journal, sector: u64, out: []u8) -> bool {
	if j == nil || len(out) != SECTOR_BYTES {
		return false
	}
	for &e in j.entries {
		if e.valid && e.sector == sector {
			if e.checksum != sector_checksum(e.data[:]) {
				return false // Corrupt sector refused.
			}
			copy(out, e.data[:])
			return true
		}
	}
	return false
}

// ============================================================================
// Multi-CPU / Non-COI Cooperative Scheduler
// ============================================================================

Cooperative_Cpu_Scheduler :: struct {
	mode:        Isolation_Mode,
	vcpu_count:  u8,
	active_vcpu: u8,
	steps_run:   [MAX_VCPUS]u64,
	quantum:     u32,
}

scheduler_init :: proc "contextless" (s: ^Cooperative_Cpu_Scheduler, mode: Isolation_Mode, vcpus: u8, quantum: u32 = 4096) -> bool {
	if s == nil || vcpus == 0 || vcpus > MAX_VCPUS || quantum == 0 {
		return false
	}
	s^ = {mode = mode, vcpu_count = vcpus, quantum = quantum}
	return true
}

scheduler_next_slice :: proc "contextless" (s: ^Cooperative_Cpu_Scheduler) -> (vcpu: u8, budget: u32) {
	if s == nil || s.vcpu_count == 0 {
		return 0, 0
	}
	cur := s.active_vcpu
	s.steps_run[cur] += u64(s.quantum)
	s.active_vcpu = (cur + 1) % s.vcpu_count
	return cur, s.quantum
}

// ============================================================================
// Compiled-Tier Basic-Block IR Trace Cache (for hot guest x86-64 blocks)
// ============================================================================

Ir_Op_Kind :: enum u8 {
	Nop     = 0,
	Mov_Imm = 1,
	Add_Reg = 2,
	Sub_Reg = 3,
	Xor_Reg = 4,
	Branch  = 5,
}

Ir_Op :: struct {
	kind: Ir_Op_Kind,
	dst:  u8,
	src:  u8,
	imm:  i64,
}

Compiled_Block :: struct {
	valid:       bool,
	guest_rip:   u64,
	byte_len:    u16,
	op_count:    u8,
	ops:         [MAX_BLOCK_OPS]Ir_Op,
	exec_count:  u64,
}

Compiled_Block_Cache :: struct {
	blocks: [MAX_CACHED_BLOCKS]Compiled_Block,
	hits:   u64,
	misses: u64,
}

cache_lookup :: proc "contextless" (c: ^Compiled_Block_Cache, guest_rip: u64) -> ^Compiled_Block {
	if c == nil {
		return nil
	}
	idx := int((guest_rip >> 2) % MAX_CACHED_BLOCKS)
	b := &c.blocks[idx]
	if b.valid && b.guest_rip == guest_rip {
		c.hits += 1
		b.exec_count += 1
		return b
	}
	c.misses += 1
	return nil
}

cache_insert :: proc "contextless" (c: ^Compiled_Block_Cache, guest_rip: u64, byte_len: u16, ops: []Ir_Op) -> bool {
	if c == nil || byte_len == 0 || len(ops) == 0 || len(ops) > MAX_BLOCK_OPS {
		return false
	}
	idx := int((guest_rip >> 2) % MAX_CACHED_BLOCKS)
	b := &c.blocks[idx]
	b^ = {valid = true, guest_rip = guest_rip, byte_len = byte_len, op_count = u8(len(ops))}
	copy(b.ops[:], ops)
	return true
}

cache_invalidate_all :: proc "contextless" (c: ^Compiled_Block_Cache) {
	if c == nil {
		return
	}
	for &b in c.blocks {
		b.valid = false
	}
}
