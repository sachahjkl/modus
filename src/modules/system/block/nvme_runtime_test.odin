#+build !freestanding
package block_service

import "core:testing"
import "modus:contract/block"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/nvme"
import "modus:pci"
import "modus:system"

// Simulated NVMe 1.4+ controller responding to BAR0 register writes, Admin
// doorbells, and I/O doorbells over host memory backing DMA queues.
Sim_Nvme_Controller :: struct {
	cap:                u64,
	cc:                 u32,
	csts:               u32,
	aqa:                u32,
	asq_phys:           u64,
	acq_phys:           u64,
	io_sq_phys:         u64,
	io_cq_phys:         u64,
	queue_base_virt:    uintptr,
	queue_base_phys:    u64,
	admin_sq_head:      u16,
	admin_cq_tail:      u16,
	admin_cq_phase:     bool,
	io_sq_head:         u16,
	io_cq_tail:         u16,
	io_cq_phase:        bool,
	ns_sectors:         u64,
	lbads:              u8,
	lba_metadata_bytes: u16,
	mdts:               u8,
	fail_next_io:       bool,
	corrupt_next_sq_id: bool,
	hang_enable:        bool,
	hang_disable:       bool,
	last_io_sqe:        nvme.Submission_Entry,
	io_doorbell_writes: u32,
	io_cq_db_writes:    u32,
}

@(private = "file")
sim_phys_to_virt :: proc "contextless" (sim: ^Sim_Nvme_Controller, phys: u64) -> uintptr {
	return sim.queue_base_virt + uintptr(phys - sim.queue_base_phys)
}

@(private = "file")
sim_read_32 :: proc "contextless" (user: rawptr, offset: u64) -> u32 {
	sim := (^Sim_Nvme_Controller)(user)
	switch offset {
	case NVME_REG_CAP:
		return u32(sim.cap)
	case NVME_REG_CAP + 4:
		return u32(sim.cap >> 32)
	case NVME_REG_CC:
		return sim.cc
	case NVME_REG_CSTS:
		return sim.csts
	case NVME_REG_AQA:
		return sim.aqa
	}
	return 0
}

@(private = "file")
sim_read_64 :: proc "contextless" (user: rawptr, offset: u64) -> u64 {
	sim := (^Sim_Nvme_Controller)(user)
	switch offset {
	case NVME_REG_CAP:
		return sim.cap
	case NVME_REG_ASQ:
		return sim.asq_phys
	case NVME_REG_ACQ:
		return sim.acq_phys
	}
	return 0
}

@(private = "file")
sim_write_64 :: proc "contextless" (user: rawptr, offset: u64, value: u64) {
	sim := (^Sim_Nvme_Controller)(user)
	switch offset {
	case NVME_REG_ASQ:
		sim.asq_phys = value
	case NVME_REG_ACQ:
		sim.acq_phys = value
	}
}

@(private = "file")
sim_post_admin_cqe :: proc "contextless" (sim: ^Sim_Nvme_Controller, cid: u16, status_code: u8) {
	acq := ([^]nvme.Completion_Entry)(sim_phys_to_virt(sim, sim.acq_phys))
	acq[sim.admin_cq_tail] = {
		sq_head          = sim.admin_sq_head,
		sq_id            = 0,
		command_id       = cid,
		status_and_phase = nvme.encode_status_and_phase(sim.admin_cq_phase, status_code, .Generic),
	}
	sim.admin_cq_tail += 1
	if sim.admin_cq_tail == NVME_ADMIN_QUEUE_SIZE {
		sim.admin_cq_tail = 0
		sim.admin_cq_phase = !sim.admin_cq_phase
	}
}

@(private = "file")
sim_post_io_cqe :: proc "contextless" (sim: ^Sim_Nvme_Controller, cid: u16, status_code: u8) {
	icq := ([^]nvme.Completion_Entry)(sim_phys_to_virt(sim, sim.io_cq_phys))
	sq_id := sim.corrupt_next_sq_id ? u16(99) : NVME_IO_QUEUE_ID
	sim.corrupt_next_sq_id = false
	icq[sim.io_cq_tail] = {
		sq_head          = sim.io_sq_head,
		sq_id            = sq_id,
		command_id       = cid,
		status_and_phase = nvme.encode_status_and_phase(sim.io_cq_phase, status_code, .Generic),
	}
	sim.io_cq_tail += 1
	if sim.io_cq_tail == NVME_IO_QUEUE_SIZE {
		sim.io_cq_tail = 0
		sim.io_cq_phase = !sim.io_cq_phase
	}
}

@(private = "file")
sim_write_32 :: proc "contextless" (user: rawptr, offset: u64, value: u32) {
	sim := (^Sim_Nvme_Controller)(user)
	switch offset {
	case NVME_REG_CC:
		sim.cc = value
		if (value & NVME_CC_ENABLE) != 0 {
			if !sim.hang_enable {
				sim.csts |= NVME_CSTS_RDY
			}
		} else {
			if !sim.hang_disable {
				sim.csts &= ~NVME_CSTS_RDY
			}
		}
		return
	case NVME_REG_AQA:
		sim.aqa = value
		return
	}
	dstrd := u8((sim.cap >> 32) & 0x0F)
	asq_db, _ := nvme.doorbell_offset(0, false, dstrd)
	isq_db, _ := nvme.doorbell_offset(NVME_IO_QUEUE_ID, false, dstrd)
	icq_db, _ := nvme.doorbell_offset(NVME_IO_QUEUE_ID, true, dstrd)
	if offset == icq_db {
		sim.io_cq_db_writes += 1
		return
	}
	if offset == asq_db {
		asq := ([^]nvme.Submission_Entry)(sim_phys_to_virt(sim, sim.asq_phys))
		target_tail := u16(value)
		for sim.admin_sq_head != target_tail {
			sqe := asq[sim.admin_sq_head]
			sim.admin_sq_head = (sim.admin_sq_head + 1) & (NVME_ADMIN_QUEUE_SIZE - 1)
			op, ok := nvme.admin_opcode_of_word(u64(sqe.opcode))
			if !ok {
				sim_post_admin_cqe(sim, sqe.command_id, 1)
				continue
			}
			switch op {
			case .Identify:
				buf := ([^]u8)(sim_phys_to_virt(sim, sqe.prp1))[:system.PAGE_SIZE]
				if sqe.cdw10 == u32(nvme.Identify_Cns.Controller) {
					buf[NVME_CTRL_OFFSET_MDTS] = sim.mdts
				} else if sqe.cdw10 == u32(nvme.Identify_Cns.Namespace) {
					byte_order.write_u64_little_endian(buf, NVME_NS_OFFSET_NSZE, sim.ns_sectors)
					buf[NVME_NS_OFFSET_FLBAS] = 0
					byte_order.write_u32_little_endian(buf, NVME_NS_OFFSET_LBAF0, u32(sim.lba_metadata_bytes) | (u32(sim.lbads) << 16))
				}
				sim_post_admin_cqe(sim, sqe.command_id, 0)
			case .Create_IO_CQ:
				sim.io_cq_phys = sqe.prp1
				sim_post_admin_cqe(sim, sqe.command_id, 0)
			case .Create_IO_SQ:
				sim.io_sq_phys = sqe.prp1
				sim_post_admin_cqe(sim, sqe.command_id, 0)
			case .Delete_IO_SQ, .Delete_IO_CQ, .Set_Features:
				sim_post_admin_cqe(sim, sqe.command_id, 0)
			}
		}
		return
	}
	if offset == isq_db {
		sim.io_doorbell_writes += 1
		isq := ([^]nvme.Submission_Entry)(sim_phys_to_virt(sim, sim.io_sq_phys))
		target_tail := u16(value)
		for sim.io_sq_head != target_tail {
			sqe := isq[sim.io_sq_head]
			sim.last_io_sqe = sqe
			sim.io_sq_head = (sim.io_sq_head + 1) & (NVME_IO_QUEUE_SIZE - 1)
			sc := sim.fail_next_io ? u8(0x81) : u8(0)
			sim.fail_next_io = false
			sim_post_io_cqe(sim, sqe.command_id, sc)
		}
	}
}

@(private = "file")
make_sim_ops :: proc(sim: ^Sim_Nvme_Controller) -> Nvme_Bar_Ops {
	return {
		read_32  = sim_read_32,
		write_32 = sim_write_32,
		read_64  = sim_read_64,
		write_64 = sim_write_64,
		user     = sim,
	}
}

@(test)
pci_nvme_class_detection_refuses_other_devices :: proc(t: ^testing.T) {
	short: [pci.CONFIGURATION_SIZE - 1]u8
	testing.expect(t, !pci_is_nvme_controller(short[:]))

	cfg: [pci.CONFIGURATION_SIZE]u8
	testing.expect(t, !pci_is_nvme_controller(cfg[:]))
	cfg[PCI_OFFSET_CLASS_CODE] = PCI_CLASS_MASS_STORAGE
	cfg[PCI_OFFSET_SUBCLASS] = 0x06 // SATA AHCI, not NVMe.
	cfg[PCI_OFFSET_PROG_IF] = 0x01
	testing.expect(t, !pci_is_nvme_controller(cfg[:]))

	cfg[PCI_OFFSET_SUBCLASS] = PCI_SUBCLASS_NVM
	cfg[PCI_OFFSET_PROG_IF] = 0x01 // NVMHCI, not NVMe Express.
	testing.expect(t, !pci_is_nvme_controller(cfg[:]))

	cfg[PCI_OFFSET_PROG_IF] = PCI_PROG_IF_NVME
	testing.expect(t, pci_is_nvme_controller(cfg[:]))
}

@(test)
nvme_runtime_refuses_bad_hardware_and_serves_live_io_roundtrip :: proc(t: ^testing.T) {
	queue_mem := new([pci.QUEUE_PAGES * system.PAGE_SIZE]u8)
	defer free(queue_mem)
	rt := new(Nvme_Runtime)
	defer free(rt)

	sim := Sim_Nvme_Controller{
		cap             = u64(255) | (u64(0) << 32) | (u64(1) << 37), // MQES=256, DSTRD=0, CSS.NVM=1, MPSMIN=0.
		queue_base_virt = uintptr(raw_data(queue_mem[:])),
		queue_base_phys = 0x2000_0000,
		admin_cq_phase  = true,
		io_cq_phase     = true,
		ns_sectors      = 8192, // 1024 blocks of 4 KiB at 512B/sector.
		lbads           = 9,    // 512-byte sectors.
		mdts            = 5,    // 2^5 * 4 KiB = 128 KiB max transfer (32 blocks).
	}
	ops := make_sim_ops(&sim)

	// Refusals first: nil state, zero/undersized BAR, unaligned/overflowing queue phys, short queue pages.
	testing.expect_value(t, nvme_runtime_start(nil, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	testing.expect_value(t, nvme_runtime_start(rt, {}, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x1000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys + 1, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, max(u64) - 0x1000 + 1, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES - 1, 64), Nvme_Startup_Refusal.Bad_Bar)

	// Non-zero CAP.MPSMIN or missing CAP.CSS.NVM bit is refused with Bad_Bar.
	saved_cap := sim.cap
	sim.cap = saved_cap | (u64(1) << 48) // MPSMIN = 1 (8 KiB minimum page size).
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	sim.cap = saved_cap &~ (u64(1) << 37) // CSS.NVM = 0.
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Bar)
	sim.cap = saved_cap

	// Non-zero LBA metadata size (MS != 0) is refused with Bad_Namespace.
	sim.lba_metadata_bytes = 8
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Namespace)
	sim.lba_metadata_bytes = 0
	sim.cc, sim.csts = 0, 0
	sim.admin_sq_head, sim.admin_cq_tail, sim.admin_cq_phase = 0, 0, true

	// Hang on enable is refused with Enable_Timeout.
	sim.hang_enable = true
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 16), Nvme_Startup_Refusal.Enable_Timeout)
	sim.hang_enable = false
	sim.cc = 0
	sim.csts = 0

	// Zero namespace sectors is refused with Bad_Namespace.
	sim.ns_sectors = 0
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.Bad_Namespace)
	sim.ns_sectors = 8192
	sim.admin_sq_head, sim.admin_cq_tail, sim.admin_cq_phase = 0, 0, true

	// Valid startup succeeds and computes exact geometry from Identify.
	testing.expect_value(t, nvme_runtime_start(rt, ops, 0x4000, sim.queue_base_virt, sim.queue_base_phys, pci.QUEUE_PAGES, 64), Nvme_Startup_Refusal.None)
	testing.expect(t, rt.initialized)
	testing.expect_value(t, rt.sector_size, u32(512))
	testing.expect_value(t, rt.disk_blocks, u64(1024))
	testing.expect_value(t, rt.max_transfer_bytes, u64(32 * block.BLOCK_SIZE))

	// Refusal edges on I/O submission: unattached region, 0 blocks, past max_transfer, misaligned offset, out-of-range LBA.
	region_phys := u64(0x4000_0000)
	region_bytes := u64(64 * block.BLOCK_SIZE)
	outcome, progress, _ := nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 1, values = {0 = 0, 1 = 1, 2 = 0}}, .Read, false, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)

	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 2, values = {0 = 0, 1 = 0, 2 = 0}}, .Read, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)

	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 3, values = {0 = 0, 1 = 33, 2 = 0}}, .Read, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)

	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 4, values = {0 = 0, 1 = 1, 2 = 512}}, .Read, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)

	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Write), tag = 5, values = {0 = 1024, 1 = 1, 2 = 0}}, .Write, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)

	// Valid 1-block Read, 2-block Write (direct PRP2), 4-block Read (PRP list page), and Flush.
	harvested: [NVME_IO_QUEUE_SIZE]Nvme_Harvested

	// 1-block Read: prp2 must be 0.
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 10, values = {0 = 2, 1 = 1, 2 = 0}}, .Read, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Succeeded && progress == .Sent)
	testing.expect_value(t, sim.last_io_sqe.prp1, region_phys)
	testing.expect_value(t, sim.last_io_sqe.prp2, u64(0))
	testing.expect_value(t, sim.last_io_sqe.cdw10, u32(16)) // block 2 * 8 sectors/block.
	testing.expect_value(t, sim.last_io_sqe.cdw12, u32(7))  // 8 sectors - 1.

	// 2-block Write: prp2 points directly to second page.
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Write), tag = 11, values = {0 = 5, 1 = 2, 2 = block.BLOCK_SIZE}}, .Write, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Succeeded && progress == .Sent)
	testing.expect_value(t, sim.last_io_sqe.prp1, region_phys + block.BLOCK_SIZE)
	testing.expect_value(t, sim.last_io_sqe.prp2, region_phys + 2 * block.BLOCK_SIZE)

	// 4-block Read: prp2 points to a dedicated 4 KiB PRP list page holding pages 1..3.
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 12, values = {0 = 10, 1 = 4, 2 = 0}}, .Read, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Succeeded && progress == .Sent)
	testing.expect_value(t, sim.last_io_sqe.prp2, rt.prp_lists_phys[0])
	testing.expect_value(t, rt.prp_lists_virt[0][0], region_phys + 1 * nvme.PAGE_SIZE)
	testing.expect_value(t, rt.prp_lists_virt[0][1], region_phys + 2 * nvme.PAGE_SIZE)
	testing.expect_value(t, rt.prp_lists_virt[0][2], region_phys + 3 * nvme.PAGE_SIZE)

	// Flush succeeds with 0 blocks moved.
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Flush), tag = 13}, .Flush, true, region_phys, region_bytes, 100)
	testing.expect(t, outcome == .Succeeded && progress == .Sent)

	got := nvme_runtime_harvest(rt, harvested[:])
	testing.expect_value(t, got, 4)
	testing.expect(t, !rt.corrupt_completion)
	testing.expect_value(t, rt.in_flight, u32(0))
	testing.expect_value(t, rt.requests_done, u64(4))
	testing.expect_value(t, rt.blocks_moved, u64(7))
	testing.expect(t, !rt.prp_list_busy[0])

	// Phase-bit wraparound across NVME_IO_QUEUE_SIZE + 5 completions.
	for step in u32(0) ..< u32(NVME_IO_QUEUE_SIZE + 5) {
		outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 100 + step, values = {0 = 0, 1 = 1, 2 = 0}}, .Read, true, region_phys, region_bytes, 200)
		testing.expect(t, outcome == .Succeeded && progress == .Sent)
		n := nvme_runtime_harvest(rt, harvested[:])
		testing.expect_value(t, n, 1)
		testing.expect_value(t, harvested[0].outcome, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, harvested[0].tag, 100 + step)
	}

	// Controller I/O error reports device_failure_outcome cleanly.
	sim.fail_next_io = true
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Write), tag = 500, values = {0 = 0, 1 = 1, 2 = 0}}, .Write, true, region_phys, region_bytes, 300)
	testing.expect(t, outcome == .Succeeded && progress == .Sent)
	got = nvme_runtime_harvest(rt, harvested[:])
	testing.expect_value(t, got, 1)
	testing.expect_value(t, harvested[0].outcome, block.device_failure_outcome(.Write))

	// Overflowing or misaligned DMA region_phys is refused before PRP calculation.
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 6, values = {0 = 0, 1 = 1, 2 = 0}}, .Read, true, max(u64) - block.BLOCK_SIZE + 1, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 7, values = {0 = 0, 1 = 1, 2 = 0}}, .Read, true, 0x4000_0001, region_bytes, 100)
	testing.expect(t, outcome == .Argument_Refused && progress == .Done)

	// Corrupt CQE sq_id trips corrupt_completion and does NOT ring the I/O CQ doorbell.
	db_before_corrupt := sim.io_cq_db_writes
	sim.corrupt_next_sq_id = true
	outcome, progress, _ = nvme_runtime_submit_block(rt, {kind = u32(block.Command.Read), tag = 501, values = {0 = 0, 1 = 1, 2 = 0}}, .Read, true, region_phys, region_bytes, 300)
	testing.expect(t, outcome == .Succeeded && progress == .Sent)
	_ = nvme_runtime_harvest(rt, harvested[:])
	testing.expect(t, rt.corrupt_completion)
	testing.expect_value(t, sim.io_cq_db_writes, db_before_corrupt)
}
