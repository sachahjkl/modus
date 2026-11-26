#+build !freestanding
#+build !modus
package browser_vm_runtime

import "core:testing"

@(test)
browser_vm_opfs_journal_non_coi_scheduler_and_compiled_tier_cache :: proc(t: ^testing.T) {
	_, bad := isolation_mode_of_word(99)
	testing.expect(t, !bad)

	// OPFS persistent disk journal survives reload & rejects corrupted sector.
	j: Opfs_Disk_Journal
	sec: [SECTOR_BYTES]u8
	sec[0] = 0x5A; sec[511] = 0xA5
	testing.expect(t, journal_write_sector(&j, 12, sec[:]))
	out: [SECTOR_BYTES]u8
	testing.expect(t, journal_read_sector(&j, 12, out[:]))
	testing.expect(t, out == sec)
	j.entries[0].data[10] ~= 0xFF
	testing.expect(t, !journal_read_sector(&j, 12, out[:]))

	// Non-COI multi-vCPU round-robin scheduler.
	sched: Cooperative_Cpu_Scheduler
	testing.expect(t, scheduler_init(&sched, .Single_Thread_Non_Coi, 2, 1024))
	v0, b0 := scheduler_next_slice(&sched)
	v1, b1 := scheduler_next_slice(&sched)
	testing.expect(t, v0 == 0 && b0 == 1024 && v1 == 1 && b1 == 1024)

	// Compiled-tier basic-block IR cache.
	cache: Compiled_Block_Cache
	testing.expect(t, cache_lookup(&cache, 0x401000) == nil)
	ops := [2]Ir_Op{{kind = .Mov_Imm, dst = 0, imm = 42}, {kind = .Add_Reg, dst = 0, src = 1}}
	testing.expect(t, cache_insert(&cache, 0x401000, 10, ops[:]))
	hit := cache_lookup(&cache, 0x401000)
	testing.expect(t, hit != nil && hit.op_count == 2 && hit.exec_count == 1)
	cache_invalidate_all(&cache)
	testing.expect(t, cache_lookup(&cache, 0x401000) == nil)
}
