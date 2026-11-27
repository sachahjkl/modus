// Live NVMe 1.4+ block device-service runtime wired to modus:contract/nvme
// (src/md/features/device_services.md).
//
// Translates the block class ring protocol (Attach, Info, Read, Write, Flush,
// Statistics) onto an NVMe PCIe controller's Admin and I/O Submission and
// Completion Queues through BAR0 registers and DMA queue memory, with zero
// kernel driver code and zero heap allocation.
package block_service

import "base:intrinsics"
import "modus:contract/block"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/nvme"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:pci"
import "modus:system"

// Format property: PCI class/subclass/prog-if identifying an NVMe Express
// controller in PCI configuration space offsets 0x09..0x0B.
PCI_OFFSET_PROG_IF :: 0x09
PCI_OFFSET_SUBCLASS :: 0x0A
PCI_OFFSET_CLASS_CODE :: 0x0B
PCI_CLASS_MASS_STORAGE :: u8(0x01)
PCI_SUBCLASS_NVM :: u8(0x08)
PCI_PROG_IF_NVME :: u8(0x02)

// Format property: NVMe 1.4+ controller BAR0 register offsets.
NVME_REG_CAP :: u64(0x00)
NVME_REG_VS :: u64(0x08)
NVME_REG_CC :: u64(0x14)
NVME_REG_CSTS :: u64(0x1C)
NVME_REG_AQA :: u64(0x24)
NVME_REG_ASQ :: u64(0x28)
NVME_REG_ACQ :: u64(0x30)

// Format property: NVMe 1.4+ CC and CSTS register bit masks and shifts.
NVME_CC_ENABLE :: u32(1 << 0)
NVME_CC_IOSQES_64B :: u32(6 << 16) // 2^6 = 64-byte Submission Queue Entry.
NVME_CC_IOCQES_16B :: u32(4 << 20) // 2^4 = 16-byte Completion Queue Entry.
NVME_CSTS_RDY :: u32(1 << 0)
NVME_CSTS_CFS :: u32(1 << 1)

// Format property: NVMe Identify Namespace (CNS 0x00) field offsets.
NVME_NS_OFFSET_NSZE :: 0
NVME_NS_OFFSET_FLBAS :: 26
NVME_NS_OFFSET_LBAF0 :: 128

// Format property: NVMe Identify Controller (CNS 0x01) MDTS offset.
NVME_CTRL_OFFSET_MDTS :: 77

// Computed: layout of NVMe queues inside pci.QUEUE_PAGES (8 contiguous 4 KiB pages).
// Page 0: Admin SQ (64 entries x 64B = 4 KiB).
// Page 1: Admin CQ (64 entries x 16B = 1 KiB).
// Page 2: I/O SQ (32 entries x 64B = 2 KiB).
// Page 3: I/O CQ (32 entries x 16B = 512B).
// Page 4: Identify data DMA page (4 KiB).
// Pages 5..7: 3 dedicated 4 KiB PRP list pages for >2-page transfers.
NVME_PAGE_ADMIN_SQ :: 0
NVME_PAGE_ADMIN_CQ :: 1
NVME_PAGE_IO_SQ :: 2
NVME_PAGE_IO_CQ :: 3
NVME_PAGE_IDENTIFY :: 4
NVME_PAGE_PRP_LISTS :: 5
NVME_PRP_LIST_PAGE_COUNT :: 3
#assert(NVME_PAGE_PRP_LISTS + NVME_PRP_LIST_PAGE_COUNT <= pci.QUEUE_PAGES)

// Computed: Admin and I/O queue depths fitting inside one 4 KiB page each.
NVME_ADMIN_QUEUE_SIZE :: u16(64)
NVME_IO_QUEUE_SIZE :: u16(32)
NVME_IO_QUEUE_ID :: u16(1)
NVME_PRIMARY_NSID :: u32(1)
NVME_PRP_ENTRIES_PER_PAGE :: int(nvme.PAGE_SIZE / size_of(u64))

// Plan value: bounded register poll iterations waiting for CSTS.RDY or an
// Admin completion during bring-up so a hung controller stops cleanly.
NVME_POLL_BOUND :: u32(1_000_000)

// Closed set of refusals returned by NVMe controller startup.
Nvme_Startup_Refusal :: enum u8 {
	None                 = 0,
	Bad_Bar              = 1,
	Bad_Doorbell         = 2,
	Disable_Timeout      = 3,
	Enable_Timeout       = 4,
	Controller_Fatal     = 5,
	Queue_Init_Failed    = 6,
	Admin_Command_Failed = 7,
	Bad_Namespace        = 8,
}

// Register access callbacks so hardware MMIO and host simulation share one
// controller state machine.
Nvme_Bar_Ops :: struct {
	read_32:  proc "contextless" (user: rawptr, offset: u64) -> u32,
	write_32: proc "contextless" (user: rawptr, offset: u64, value: u32),
	read_64:  proc "contextless" (user: rawptr, offset: u64) -> u64,
	write_64: proc "contextless" (user: rawptr, offset: u64, value: u64),
	user:     rawptr,
}

// One in-flight NVMe I/O request tracked by command_id slot.
Nvme_Io_Request :: struct {
	busy:          bool,
	tag:           u32,
	command_id:    u16,
	blocks:        u64,
	command:       block.Command,
	prp_list_used: bool,
	prp_list_idx:  u8,
}

// Live runtime state for one NVMe 1.4+ controller serving the block class ring.
Nvme_Runtime :: struct {
	initialized:        bool,
	bar_ops:            Nvme_Bar_Ops,
	bar_size:           u64,
	dstrd:              u8,
	admin_sq_db_offset: u64,
	admin_cq_db_offset: u64,
	io_sq_db_offset:    u64,
	io_cq_db_offset:    u64,
	max_transfer_bytes: u64,
	sector_size:        u32,
	namespace_blocks:   u64,
	disk_blocks:        u64,
	poll_limit:         u32,

	admin_qp:           nvme.Queue_Pair_State,
	io_qp:              nvme.Queue_Pair_State,
	next_cid:           u16,

	admin_sq:           [^]nvme.Submission_Entry,
	admin_cq:           [^]nvme.Completion_Entry,
	io_sq:              [^]nvme.Submission_Entry,
	io_cq:              [^]nvme.Completion_Entry,
	identify_buf:       [^]u8,
	prp_lists_virt:     [NVME_PRP_LIST_PAGE_COUNT][^]u64,
	prp_lists_phys:     [NVME_PRP_LIST_PAGE_COUNT]u64,
	prp_list_busy:      [NVME_PRP_LIST_PAGE_COUNT]bool,

	admin_sq_phys:      u64,
	admin_cq_phys:      u64,
	io_sq_phys:         u64,
	io_cq_phys:         u64,
	identify_phys:      u64,

	requests:           [NVME_IO_QUEUE_SIZE]Nvme_Io_Request,
	deadlines:          [NVME_IO_QUEUE_SIZE]u64,
	in_flight:          u32,
	requests_done:      u64,
	blocks_moved:       u64,
	corrupt_completion: bool,
}

// One harvested NVMe completion ready to push to the block class ring.
Nvme_Harvested :: struct {
	tag:     u32,
	outcome: call_outcome.Call_Outcome,
	values:  [7]u64,
}

// pci_is_nvme_controller reports whether a PCI configuration header identifies
// an NVMe Express controller (class 0x01, subclass 0x08, prog-if 0x02).
pci_is_nvme_controller :: proc "contextless" (configuration: []u8) -> bool {
	if len(configuration) < pci.CONFIGURATION_SIZE {
		return false
	}
	return configuration[PCI_OFFSET_CLASS_CODE] == PCI_CLASS_MASS_STORAGE &&
		configuration[PCI_OFFSET_SUBCLASS] == PCI_SUBCLASS_NVM &&
		configuration[PCI_OFFSET_PROG_IF] == PCI_PROG_IF_NVME
}

@(private = "file")
mmio_read_32 :: proc "contextless" (user: rawptr, offset: u64) -> u32 {
	return intrinsics.volatile_load((^u32)(uintptr(user) + uintptr(offset)))
}

@(private = "file")
mmio_write_32 :: proc "contextless" (user: rawptr, offset: u64, value: u32) {
	intrinsics.volatile_store((^u32)(uintptr(user) + uintptr(offset)), value)
}

@(private = "file")
mmio_read_64 :: proc "contextless" (user: rawptr, offset: u64) -> u64 {
	low := u64(mmio_read_32(user, offset))
	high := u64(mmio_read_32(user, offset + 4))
	return low | (high << 32)
}

@(private = "file")
mmio_write_64 :: proc "contextless" (user: rawptr, offset: u64, value: u64) {
	mmio_write_32(user, offset, u32(value))
	mmio_write_32(user, offset + 4, u32(value >> 32))
}

nvme_mmio_bar_ops :: proc "contextless" (bar0_base: rawptr) -> Nvme_Bar_Ops {
	return {
		read_32  = mmio_read_32,
		write_32 = mmio_write_32,
		read_64  = mmio_read_64,
		write_64 = mmio_write_64,
		user     = bar0_base,
	}
}

@(private = "file")
nvme_next_command_id :: proc "contextless" (rt: ^Nvme_Runtime) -> u16 {
	rt.next_cid += 1
	if rt.next_cid == 0 {
		rt.next_cid = 1
	}
	return rt.next_cid
}

@(private = "file")
nvme_wait_csts_ready :: proc "contextless" (rt: ^Nvme_Runtime, want_ready: bool) -> bool {
	limit := rt.poll_limit > 0 ? rt.poll_limit : NVME_POLL_BOUND
	for _ in u32(0) ..< limit {
		csts := rt.bar_ops.read_32(rt.bar_ops.user, NVME_REG_CSTS)
		if (csts & NVME_CSTS_CFS) != 0 {
			return false
		}
		is_ready := (csts & NVME_CSTS_RDY) != 0
		if is_ready == want_ready {
			return true
		}
		intrinsics.cpu_relax()
	}
	return false
}

// nvme_load_cqe_acquired reads status_and_phase with Acquire ordering first so
// DW0..DW2 are only loaded after the controller's DMA write of the CQE is
// visible with the expected phase tag, preventing torn reads.
@(private = "file")
nvme_load_cqe_acquired :: proc "contextless" (slot: ^nvme.Completion_Entry, expected_phase: bool) -> (cqe: nvme.Completion_Entry, ready: bool) {
	status_and_phase := intrinsics.atomic_load_explicit(&slot.status_and_phase, .Acquire)
	if ((status_and_phase & 1) != 0) != expected_phase {
		return {}, false
	}
	intrinsics.atomic_thread_fence(.Acquire)
	cqe.result = intrinsics.volatile_load(&slot.result)
	cqe.reserved = intrinsics.volatile_load(&slot.reserved)
	cqe.sq_head = intrinsics.volatile_load(&slot.sq_head)
	cqe.sq_id = intrinsics.volatile_load(&slot.sq_id)
	cqe.command_id = intrinsics.volatile_load(&slot.command_id)
	cqe.status_and_phase = status_and_phase
	return cqe, true
}

// nvme_admin_run submits one Admin SQE on Queue 0, rings the Admin SQ
// doorbell, polls the Admin CQ until completion or poll_limit, and rings the
// Admin CQ head doorbell.
@(private = "file")
nvme_admin_run :: proc "contextless" (rt: ^Nvme_Runtime, entry: nvme.Submission_Entry) -> bool {
	slot, new_tail, sub_ref := nvme.queue_pair_submit(&rt.admin_qp, entry.command_id)
	if sub_ref != .None {
		return false
	}
	rt.admin_sq[slot] = entry
	intrinsics.atomic_thread_fence(.Seq_Cst)
	rt.bar_ops.write_32(rt.bar_ops.user, rt.admin_sq_db_offset, u32(new_tail))

	limit := rt.poll_limit > 0 ? rt.poll_limit : NVME_POLL_BOUND
	for _ in u32(0) ..< limit {
		csts := rt.bar_ops.read_32(rt.bar_ops.user, NVME_REG_CSTS)
		if (csts & NVME_CSTS_CFS) != 0 {
			return false
		}
		cqe, ready := nvme_load_cqe_acquired(&rt.admin_cq[rt.admin_qp.cq_head], rt.admin_qp.cq_phase)
		if !ready {
			intrinsics.cpu_relax()
			continue
		}
		_, _, new_cq_head, comp_ref := nvme.queue_pair_complete(&rt.admin_qp, cqe)
		if comp_ref != .None {
			return false
		}
		rt.bar_ops.write_32(rt.bar_ops.user, rt.admin_cq_db_offset, u32(new_cq_head))
		return true
	}
	return false
}

// nvme_runtime_start brings up an NVMe 1.4+ controller over BAR0 registers and
// 8 contiguous 4 KiB DMA queue pages: disables and re-enables CC, identifies
// the controller and namespace 1, and creates I/O CQ 1 and I/O SQ 1.
nvme_runtime_start :: proc "contextless" (
	rt: ^Nvme_Runtime,
	bar_ops: Nvme_Bar_Ops,
	bar_size: u64,
	queue_virt: uintptr,
	queue_phys: u64,
	queue_pages: u64,
	poll_limit: u32 = NVME_POLL_BOUND,
) -> Nvme_Startup_Refusal {
	if rt == nil || bar_ops.read_32 == nil || bar_ops.write_32 == nil || bar_ops.read_64 == nil || bar_ops.write_64 == nil {
		return .Bad_Bar
	}
	if bar_size < nvme.DOORBELL_BASE_OFFSET + 16 || queue_virt == 0 || queue_phys == 0 || (queue_phys & (nvme.PAGE_SIZE - 1)) != 0 || queue_pages < pci.QUEUE_PAGES {
		return .Bad_Bar
	}
	queue_span_bytes := u64(pci.QUEUE_PAGES) * system.PAGE_SIZE
	if queue_phys > max(u64) - queue_span_bytes {
		return .Bad_Bar
	}

	rt^ = {}
	rt.bar_ops = bar_ops
	rt.bar_size = bar_size
	rt.poll_limit = poll_limit > 0 ? poll_limit : NVME_POLL_BOUND

	cap := bar_ops.read_64(bar_ops.user, NVME_REG_CAP)
	if cap == 0 || cap == max(u64) {
		return .Bad_Bar
	}
	// Verify CAP.MPSMIN == 0 (4 KiB host page size supported for CC.MPS = 0)
	// and CAP.CSS bit 0 == 1 (NVM command set supported for CC.CSS = 0).
	mpsmin := uint((cap >> 48) & 0x0F)
	css_nvm := ((cap >> 37) & 1) != 0
	if mpsmin != 0 || !css_nvm {
		return .Bad_Bar
	}
	dstrd := u8((cap >> 32) & 0x0F)
	mqes := u32(cap & 0xFFFF) + 1
	if mqes < u32(NVME_IO_QUEUE_SIZE) {
		return .Queue_Init_Failed
	}
	rt.dstrd = dstrd

	asq_db, asq_ref := nvme.doorbell_offset_in_bar(0, false, dstrd, bar_size)
	acq_db, acq_ref := nvme.doorbell_offset_in_bar(0, true, dstrd, bar_size)
	isq_db, isq_ref := nvme.doorbell_offset_in_bar(NVME_IO_QUEUE_ID, false, dstrd, bar_size)
	icq_db, icq_ref := nvme.doorbell_offset_in_bar(NVME_IO_QUEUE_ID, true, dstrd, bar_size)
	if asq_ref != .None || acq_ref != .None || isq_ref != .None || icq_ref != .None {
		return .Bad_Doorbell
	}
	rt.admin_sq_db_offset = asq_db
	rt.admin_cq_db_offset = acq_db
	rt.io_sq_db_offset = isq_db
	rt.io_cq_db_offset = icq_db

	// Zero all queue and identify DMA pages before exposing them to the device.
	intrinsics.mem_zero(rawptr(queue_virt), int(pci.QUEUE_PAGES * system.PAGE_SIZE))
	rt.admin_sq = ([^]nvme.Submission_Entry)(queue_virt + NVME_PAGE_ADMIN_SQ * system.PAGE_SIZE)
	rt.admin_cq = ([^]nvme.Completion_Entry)(queue_virt + NVME_PAGE_ADMIN_CQ * system.PAGE_SIZE)
	rt.io_sq = ([^]nvme.Submission_Entry)(queue_virt + NVME_PAGE_IO_SQ * system.PAGE_SIZE)
	rt.io_cq = ([^]nvme.Completion_Entry)(queue_virt + NVME_PAGE_IO_CQ * system.PAGE_SIZE)
	rt.identify_buf = ([^]u8)(queue_virt + NVME_PAGE_IDENTIFY * system.PAGE_SIZE)
	rt.admin_sq_phys = queue_phys + NVME_PAGE_ADMIN_SQ * system.PAGE_SIZE
	rt.admin_cq_phys = queue_phys + NVME_PAGE_ADMIN_CQ * system.PAGE_SIZE
	rt.io_sq_phys = queue_phys + NVME_PAGE_IO_SQ * system.PAGE_SIZE
	rt.io_cq_phys = queue_phys + NVME_PAGE_IO_CQ * system.PAGE_SIZE
	rt.identify_phys = queue_phys + NVME_PAGE_IDENTIFY * system.PAGE_SIZE
	for idx in 0 ..< NVME_PRP_LIST_PAGE_COUNT {
		page_off := u64(NVME_PAGE_PRP_LISTS + idx) * system.PAGE_SIZE
		rt.prp_lists_virt[idx] = ([^]u64)(queue_virt + uintptr(page_off))
		rt.prp_lists_phys[idx] = queue_phys + page_off
	}

	// Disable controller cleanly and wait for CSTS.RDY == 0.
	cc := bar_ops.read_32(bar_ops.user, NVME_REG_CC)
	if (cc & NVME_CC_ENABLE) != 0 {
		bar_ops.write_32(bar_ops.user, NVME_REG_CC, cc &~ NVME_CC_ENABLE)
	}
	if !nvme_wait_csts_ready(rt, false) {
		return .Disable_Timeout
	}

	// Program Admin Queue attributes and base addresses, then enable controller.
	aqa := u32(NVME_ADMIN_QUEUE_SIZE - 1) | (u32(NVME_ADMIN_QUEUE_SIZE - 1) << 16)
	bar_ops.write_32(bar_ops.user, NVME_REG_AQA, aqa)
	bar_ops.write_64(bar_ops.user, NVME_REG_ASQ, rt.admin_sq_phys)
	bar_ops.write_64(bar_ops.user, NVME_REG_ACQ, rt.admin_cq_phys)
	bar_ops.write_32(bar_ops.user, NVME_REG_CC, NVME_CC_ENABLE | NVME_CC_IOSQES_64B | NVME_CC_IOCQES_16B)
	if !nvme_wait_csts_ready(rt, true) {
		csts := bar_ops.read_32(bar_ops.user, NVME_REG_CSTS)
		if (csts & NVME_CSTS_CFS) != 0 {
			return .Controller_Fatal
		}
		return .Enable_Timeout
	}

	if nvme.queue_pair_init(&rt.admin_qp, 0, NVME_ADMIN_QUEUE_SIZE, NVME_ADMIN_QUEUE_SIZE) != .None {
		return .Queue_Init_Failed
	}

	// 1. Identify Controller (CNS 0x01) to read MDTS.
	id_ctrl, id_ctrl_ref := nvme.build_identify_controller(nvme_next_command_id(rt), rt.identify_phys)
	if id_ctrl_ref != .None || !nvme_admin_run(rt, id_ctrl) {
		return .Admin_Command_Failed
	}
	min_page_bytes := nvme.PAGE_SIZE
	mdts := rt.identify_buf[NVME_CTRL_OFFSET_MDTS]
	max_xfer := u64(REQUEST_BLOCKS_LIMIT) * block.BLOCK_SIZE
	if mdts > 0 && mdts < 20 {
		ctrl_max := min_page_bytes << uint(mdts)
		if ctrl_max < max_xfer {
			max_xfer = ctrl_max
		}
	}
	if max_xfer < block.BLOCK_SIZE {
		return .Bad_Namespace
	}
	rt.max_transfer_bytes = max_xfer

	// 2. Identify Namespace 1 (CNS 0x00) to read NSZE and active LBA format.
	intrinsics.mem_zero(rt.identify_buf, int(system.PAGE_SIZE))
	id_ns, id_ns_ref := nvme.build_identify_namespace(nvme_next_command_id(rt), NVME_PRIMARY_NSID, rt.identify_phys)
	if id_ns_ref != .None || !nvme_admin_run(rt, id_ns) {
		return .Admin_Command_Failed
	}
	ns_bytes := rt.identify_buf[:system.PAGE_SIZE]
	nsze := byte_order.read_u64_little_endian(ns_bytes, NVME_NS_OFFSET_NSZE)
	flbas := ns_bytes[NVME_NS_OFFSET_FLBAS] & 0x0F
	lbaf := byte_order.read_u32_little_endian(ns_bytes, NVME_NS_OFFSET_LBAF0 + int(flbas) * 4)
	// Refuse namespaces formatted with non-zero LBA metadata size (MS != 0),
	// because I/O commands supply no metadata pointer.
	if (lbaf & 0xFFFF) != 0 {
		return .Bad_Namespace
	}
	lbads := (lbaf >> 16) & 0xFF
	if lbads < 9 || lbads > 12 {
		return .Bad_Namespace
	}
	sector_size := u32(1) << uint(lbads)
	if !nvme.is_valid_sector_size(sector_size) || nsze == 0 {
		return .Bad_Namespace
	}
	sectors_per_block := u64(block.BLOCK_SIZE) / u64(sector_size)
	if sectors_per_block == 0 {
		return .Bad_Namespace
	}
	disk_blocks := nsze / sectors_per_block
	if disk_blocks == 0 {
		return .Bad_Namespace
	}
	rt.sector_size = sector_size
	rt.namespace_blocks = nsze
	rt.disk_blocks = disk_blocks

	// 3. Create I/O Completion Queue 1 and I/O Submission Queue 1.
	create_cq, cq_ref := nvme.build_create_io_cq(nvme_next_command_id(rt), NVME_IO_QUEUE_ID, NVME_IO_QUEUE_SIZE, rt.io_cq_phys, 0, true)
	if cq_ref != .None || !nvme_admin_run(rt, create_cq) {
		return .Admin_Command_Failed
	}
	create_sq, sq_ref := nvme.build_create_io_sq(nvme_next_command_id(rt), NVME_IO_QUEUE_ID, NVME_IO_QUEUE_ID, NVME_IO_QUEUE_SIZE, rt.io_sq_phys)
	if sq_ref != .None || !nvme_admin_run(rt, create_sq) {
		return .Admin_Command_Failed
	}
	if nvme.queue_pair_init(&rt.io_qp, NVME_IO_QUEUE_ID, NVME_IO_QUEUE_SIZE, NVME_IO_QUEUE_SIZE) != .None {
		return .Queue_Init_Failed
	}

	rt.initialized = true
	return .None
}

// nvme_runtime_submit_block translates one validated block ring Read, Write,
// or Flush command into an NVMe I/O SQE and rings the I/O SQ doorbell.
nvme_runtime_submit_block :: proc "contextless" (
	rt: ^Nvme_Runtime,
	command: ring.Record,
	kind: block.Command,
	has_region: bool,
	region_phys: u64,
	region_bytes: u64,
	now_ms: u64,
) -> (ended: call_outcome.Call_Outcome, progress: Request_Progress, values: [7]u64) {
	if rt == nil || !rt.initialized {
		return .Wrong_State, .Done, errors.ring_fail(command.kind, .State, .None)
	}
	first, count, offset := command.values[0], command.values[1], command.values[2]
	max_blocks := min(u64(REQUEST_BLOCKS_LIMIT), rt.max_transfer_bytes / block.BLOCK_SIZE)
	if kind != .Flush {
		if !has_region {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Absent, .Region)
		}
		if region_phys == 0 || (region_phys & (nvme.PAGE_SIZE - 1)) != 0 || region_bytes == 0 || region_phys > max(u64) - region_bytes {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Bad_Value, .Bytes, 3)
		}
		if count == 0 {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Too_Small, .Blocks, 2, 0, 1)
		}
		if count > max_blocks {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Too_Long, .Blocks, 2, i64(count), i64(max_blocks))
		}
		if offset % block.BLOCK_SIZE != 0 {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Bad_Value, .Bytes, 3, i64(offset))
		}
		if first >= rt.disk_blocks || count > rt.disk_blocks - first {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Out_Of_Range, .Blocks, 1, i64(min(first, 1 << 62) + count), i64(rt.disk_blocks))
		}
		if offset > region_bytes || count * block.BLOCK_SIZE > region_bytes - offset {
			return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 3, i64(min(offset, 1 << 62) + count * block.BLOCK_SIZE), i64(region_bytes))
		}
	}

	req_idx := -1
	for idx in 0 ..< int(NVME_IO_QUEUE_SIZE) {
		if !rt.requests[idx].busy {
			req_idx = idx
			break
		}
	}
	if req_idx < 0 || rt.in_flight >= u32(NVME_IO_QUEUE_SIZE - 1) {
		return .Succeeded, .Full, {}
	}

	cid := nvme_next_command_id(rt)
	for nvme.queue_pair_command_in_flight(&rt.io_qp, cid) {
		cid = nvme_next_command_id(rt)
	}

	sqe: nvme.Submission_Entry
	build_ref: nvme.Nvme_Refusal
	prp_used := false
	prp_idx := u8(0)
	transfer_blocks := count

	switch kind {
	case .Read, .Write:
		sectors_per_block := u64(block.BLOCK_SIZE) / u64(rt.sector_size)
		prp1 := region_phys + offset
		prp2: u64 = 0
		if count == 2 {
			prp2 = prp1 + nvme.PAGE_SIZE
		} else if count > 2 {
			if int(count - 1) > NVME_PRP_ENTRIES_PER_PAGE {
				return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Too_Long, .Blocks, 2, i64(count), i64(NVME_PRP_ENTRIES_PER_PAGE + 1))
			}
			free_prp := -1
			for p in 0 ..< NVME_PRP_LIST_PAGE_COUNT {
				if !rt.prp_list_busy[p] {
					free_prp = p
					break
				}
			}
			if free_prp < 0 {
				return .Succeeded, .Full, {}
			}
			prp_used = true
			prp_idx = u8(free_prp)
			list_page := rt.prp_lists_virt[free_prp]
			for page_i in u64(1) ..< count {
				list_page[page_i - 1] = prp1 + page_i * nvme.PAGE_SIZE
			}
			prp2 = rt.prp_lists_phys[free_prp]
		}
		params := nvme.Io_Transfer_Params{
			command_id         = cid,
			nsid               = NVME_PRIMARY_NSID,
			lba                = first * sectors_per_block,
			sector_count       = u32(count * sectors_per_block),
			sector_size        = rt.sector_size,
			namespace_blocks   = rt.namespace_blocks,
			max_transfer_bytes = rt.max_transfer_bytes,
			prp1               = prp1,
			prp2               = prp2,
		}
		if kind == .Read {
			sqe, build_ref = nvme.build_io_read(params)
		} else {
			sqe, build_ref = nvme.build_io_write(params)
		}
	case .Flush:
		transfer_blocks = 0
		sqe, build_ref = nvme.build_io_flush(cid, NVME_PRIMARY_NSID)
	case .None, .Attach, .Info, .Statistics:
		return .Operation_Unsupported, .Done, errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))
	}

	if build_ref != .None {
		return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Bad_Value, .None, 0, i64(build_ref))
	}

	sq_slot, new_tail, sub_ref := nvme.queue_pair_submit(&rt.io_qp, cid)
	if sub_ref == .Queue_Full {
		return .Succeeded, .Full, {}
	}
	if sub_ref != .None {
		return .Argument_Refused, .Done, errors.ring_fail(command.kind, .Bad_Value, .None, 0, i64(sub_ref))
	}

	if prp_used {
		rt.prp_list_busy[prp_idx] = true
	}
	rt.requests[req_idx] = {
		busy          = true,
		tag           = command.tag,
		command_id    = cid,
		blocks        = transfer_blocks,
		command       = kind,
		prp_list_used = prp_used,
		prp_list_idx  = prp_idx,
	}
	rt.deadlines[req_idx] = system.answer_deadline(now_ms)
	rt.in_flight += 1

	rt.io_sq[sq_slot] = sqe
	intrinsics.atomic_thread_fence(.Seq_Cst)
	rt.bar_ops.write_32(rt.bar_ops.user, rt.io_sq_db_offset, u32(new_tail))
	return .Succeeded, .Sent, {}
}

// nvme_runtime_harvest consumes ready NVMe I/O Completion Queue entries,
// updates the I/O CQ doorbell once, and writes block-ring completion records
// into out. A malformed CQE sets rt.corrupt_completion so the service stops.
nvme_runtime_harvest :: proc "contextless" (rt: ^Nvme_Runtime, out: []Nvme_Harvested) -> (count: int) {
	if rt == nil || !rt.initialized {
		return 0
	}
	doorbell_dirty := false
	for count < len(out) {
		cqe, ready := nvme_load_cqe_acquired(&rt.io_cq[rt.io_qp.cq_head], rt.io_qp.cq_phase)
		if !ready {
			break
		}
		_, sc, new_cq_head, comp_ref := nvme.queue_pair_complete(&rt.io_qp, cqe)
		if comp_ref == .No_Completion_Ready {
			break
		}
		if comp_ref != .None && comp_ref != .Command_Failed {
			rt.corrupt_completion = true
			break
		}
		matched := -1
		for idx in 0 ..< int(NVME_IO_QUEUE_SIZE) {
			if rt.requests[idx].busy && rt.requests[idx].command_id == cqe.command_id {
				matched = idx
				break
			}
		}
		if matched < 0 {
			rt.corrupt_completion = true
			break
		}
		doorbell_dirty = true
		req := rt.requests[matched]
		if req.prp_list_used && int(req.prp_list_idx) < NVME_PRP_LIST_PAGE_COUNT {
			rt.prp_list_busy[req.prp_list_idx] = false
		}
		outcome := call_outcome.Call_Outcome.Succeeded
		values: [7]u64
		if comp_ref == .Command_Failed {
			outcome = block.device_failure_outcome(req.command)
			values = errors.ring_fail(u32(req.command), .Device, .None, 0, 0, 0, i64(sc))
		}
		out[count] = {tag = req.tag, outcome = outcome, values = values}
		count += 1
		rt.requests_done += 1
		rt.blocks_moved += req.blocks
		rt.requests[matched] = {}
		rt.deadlines[matched] = 0
		rt.in_flight -= 1
		_ = new_cq_head
	}
	if doorbell_dirty && !rt.corrupt_completion {
		rt.bar_ops.write_32(rt.bar_ops.user, rt.io_cq_db_offset, u32(rt.io_qp.cq_head))
	}
	return count
}

// Package-level NVMe runtime state kept in BSS to stay off the thread stack.
nvme_state: Nvme_Runtime
nvme_harvest_batch: [NVME_IO_QUEUE_SIZE]Nvme_Harvested

@(private = "file")
nvme_room :: proc "contextless" () -> bool {
	return ring.count(&clients.completions) + nvme_state.in_flight < ring.capacity(&clients.completions)
}

@(private = "file")
nvme_stop_all_in_flight :: proc "contextless" (cause: Device_Stop) -> ! {
	for idx in 0 ..< int(NVME_IO_QUEUE_SIZE) {
		if !nvme_state.requests[idx].busy {
			continue
		}
		req := nvme_state.requests[idx]
		complete(req.tag, block.device_failure_outcome(req.command), block.no_answer_values(req.command))
	}
	system.wake_reader(&clients.completions)
	switch cause {
	case .No_Answer:
		system.log_fact(.Error, Device_Silent{bound = value_kinds.Time_In_Milliseconds(system.ANSWER_BOUND_MILLISECONDS), in_flight = u64(nvme_state.in_flight)})
	case .Needs_Reset:
		system.log_fact(.Error, Device_Needs_Reset{in_flight = u64(nvme_state.in_flight)})
	}
	system.stop(.Failed)
}

// nvme_device_entry maps BAR0 and DMA queue memory for an NVMe controller,
// brings up Admin and I/O queue pairs, and serves the block class ring.
nvme_device_entry :: proc "contextless" (ctx: ^system.Context) -> ! {
	bar0_handle := ctx.handles[pci.GRANT_BAR]
	if bar0_handle == 0 {
		fail("the nvme device has no BAR0 registers")
	}
	bar0_pages, bar0_size_status := system.memory_size(bar0_handle)
	if bar0_size_status != .Succeeded || bar0_pages == 0 {
		fail("the nvme BAR0 register window has no pages")
	}
	bar0_addr, bar0_map_status := system.memory_map(bar0_handle, {.Write})
	if bar0_map_status != .Succeeded {
		fail("the nvme BAR0 registers did not map")
	}

	queues := ctx.handles[pci.GRANT_QUEUES]
	queue_pages, queue_size_status := system.memory_size(queues)
	if queue_size_status != .Succeeded || queue_pages < pci.QUEUE_PAGES {
		fail("the memory of the nvme queues is too small")
	}
	queue_addr, queue_map_status := system.memory_map(queues, {.Write})
	queue_phys, queue_phys_status := system.memory_physical(machine, queues)
	if queue_map_status != .Succeeded || queue_phys_status != .Succeeded {
		fail("no physical address for the nvme queues")
	}

	start_ref := nvme_runtime_start(
		&nvme_state,
		nvme_mmio_bar_ops(bar0_addr),
		bar0_pages * system.PAGE_SIZE,
		uintptr(queue_addr),
		queue_phys,
		queue_pages,
	)
	if start_ref != .None {
		fail("the nvme controller did not start")
	}

	disk_blocks = nvme_state.disk_blocks
	has_flush = true
	system.log_fact(.Info, Ready_With_Flush{
		disk_size          = value_kinds.Size_In_Blocks(disk_blocks),
		queue_size         = u64(NVME_IO_QUEUE_SIZE),
		requests_in_flight = u64(NVME_IO_QUEUE_SIZE - 1),
	})

	waiting: ring.Record
	has_waiting := false
	system.ready()
	for {
		wait := system.wait_begin()
		harvested := nvme_runtime_harvest(&nvme_state, nvme_harvest_batch[:])
		if nvme_state.corrupt_completion {
			nvme_stop_all_in_flight(.Needs_Reset)
		}
		changed := harvested
		for idx in 0 ..< harvested {
			item := nvme_harvest_batch[idx]
			complete(item.tag, item.outcome, item.values)
		}
		if changed == 0 && nvme_state.in_flight != 0 {
			csts := nvme_state.bar_ops.read_32(nvme_state.bar_ops.user, NVME_REG_CSTS)
			if (csts & NVME_CSTS_CFS) != 0 {
				nvme_stop_all_in_flight(.Needs_Reset)
			}
		}
		if system.time() >= system.answer_deadline_earliest(nvme_state.deadlines[:]) {
			nvme_stop_all_in_flight(.No_Answer)
		}
		for nvme_room() {
			command: ring.Record
			if has_waiting {
				command, has_waiting = waiting, false
			} else {
				ok: bool
				if command, ok = system.receive(&clients.commands); !ok {
					break
				}
			}
			result := call_outcome.Call_Outcome.Succeeded
			values: [7]u64
			kind, kind_ok := block.command_of_ring_word(command.kind)
			if !kind_ok {
				complete(command.tag, .Operation_Unsupported, errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)))
				changed += 1
				continue
			}
			switch kind {
			case .None:
			case .Attach:
				in_flight = nvme_state.in_flight
				result, values = attach(system.Handle(command.values[0]))
			case .Info:
				max_blocks := min(u64(REQUEST_BLOCKS_LIMIT), nvme_state.max_transfer_bytes / block.BLOCK_SIZE)
				values = {0 = nvme_state.disk_blocks, 1 = max_blocks, 2 = 1}
			case .Statistics:
				results, _ := system.call(.Interrupt_Read, u64(interrupt))
				interrupts += results[0]
				values = {0 = nvme_state.requests_done, 1 = nvme_state.blocks_moved, 2 = system.kernel_entries(), 3 = interrupts}
			case .Read, .Write, .Flush:
				progress: Request_Progress
				result, progress, values = nvme_runtime_submit_block(
					&nvme_state,
					command,
					kind,
					region_memory != 0,
					region_physical,
					region_size,
					system.time(),
				)
				if progress == .Sent {
					continue
				}
				if progress == .Full {
					waiting, has_waiting = command, true
				}
			}
			if has_waiting {
				break
			}
			complete(command.tag, result, values)
			changed += 1
		}
		if changed != 0 {
			system.wake_reader(&clients.completions)
		}
		if nvme_room() && !has_waiting {
			system.wait_records(&wait, &clients.commands)
		}
		system.wait_end(&wait, system.answer_deadline_earliest(nvme_state.deadlines[:]))
	}
}
