// NVMe 1.4+ Submission/Completion Queue hardware layouts, state machine,
// doorbell offset calculation, and Admin/I/O command builders
// (src/md/features/device_services.md).
//
// Pure freestanding zero-allocation contract package so user-space NVMe
// device services and host tests share one validated protocol border.
package nvme

import "modus:contract/enum_word"

// Hardware page size for PRP1/PRP2 DMA buffers (4 KiB).
PAGE_SIZE :: u64(4096)

// Supported queue depth bounds (power of two, 2 ..= 4096 entries).
MIN_QUEUE_SIZE :: u16(2)
MAX_QUEUE_SIZE :: u16(4096)

// Maximum sectors expressible in the 16-bit 0-based NLB field of CDW12.
MAX_NLB_SECTORS :: u32(65536)

// Supported logical sector size bounds (power of two, 512 ..= 4096 bytes).
MIN_SECTOR_SIZE :: u32(512)
MAX_SECTOR_SIZE :: u32(4096)

// BAR0 base offset of the Submission/Completion Queue doorbell array.
DOORBELL_BASE_OFFSET :: u64(0x1000)

// Maximum value of the 4-bit CAP.DSTRD register field (0 ..= 15).
MAX_DOORBELL_STRIDE :: u8(15)

// Broadcast namespace identifier rejected for single-namespace commands.
BROADCAST_NSID :: u32(0xFFFF_FFFF)

// Number of 64-bit bitmap words tracking all 65,536 possible u16 command IDs.
CID_BITMAP_WORDS :: 1024

// Closed set of supported NVMe 1.4+ Admin command opcodes.
Admin_Opcode :: enum u8 {
	Delete_IO_SQ = 0x00,
	Create_IO_SQ = 0x01,
	Delete_IO_CQ = 0x04,
	Create_IO_CQ = 0x05,
	Identify     = 0x06,
	Set_Features = 0x09,
}

// Closed set of supported NVMe 1.4+ NVM I/O command opcodes.
Io_Opcode :: enum u8 {
	Flush = 0x00,
	Write = 0x01,
	Read  = 0x02,
}

// Closed set of Identify CNS selectors built by this contract.
Identify_Cns :: enum u8 {
	Namespace  = 0x00,
	Controller = 0x01,
}

// Closed set of NVMe 1.4+ Completion Queue Status Code Types (bits 11:9).
Nvme_Status_Code_Type :: enum u8 {
	Generic                  = 0x00,
	Command_Specific         = 0x01,
	Media_And_Data_Integrity = 0x02,
	Path_Related             = 0x03,
	Vendor_Specific          = 0x07,
}

// Closed set of validation and state-machine refusals for NVMe queues and commands.
Nvme_Refusal :: enum u8 {
	None                     = 0,
	Bad_Opcode               = 1,
	Bad_Status_Code_Type     = 2,
	Bad_Queue_Size           = 3,
	Not_Initialized          = 4,
	Queue_Full               = 5,
	No_Completion_Ready      = 6,
	Duplicate_Command_Id     = 7,
	Unknown_Command_Id       = 8,
	Bad_Sq_Head              = 9,
	Bad_Sq_Id                = 10,
	Bad_Doorbell_Stride      = 11,
	Doorbell_Offset_Overflow = 12,
	Zero_Address             = 13,
	Unaligned_Address        = 14,
	Zero_Sector_Count        = 15,
	Bad_Sector_Size          = 16,
	Transfer_Too_Large       = 17,
	Lba_Out_Of_Range         = 18,
	Bad_Namespace_Id         = 19,
	Bad_Queue_Id             = 20,
	Missing_Prp2             = 21,
	Unexpected_Prp2          = 22,
	Command_Failed           = 23,
}

// NVMe 1.4+ 64-byte Submission Queue Entry (SQE), little-endian hardware layout.
Submission_Entry :: struct {
	opcode:       u8,
	flags:        u8,
	command_id:   u16,
	nsid:         u32,
	cdw2:         u32,
	cdw3:         u32,
	metadata_ptr: u64,
	prp1:         u64,
	prp2:         u64,
	cdw10:        u32,
	cdw11:        u32,
	cdw12:        u32,
	cdw13:        u32,
	cdw14:        u32,
	cdw15:        u32,
}

#assert(size_of(Submission_Entry) == 64)
#assert(offset_of(Submission_Entry, nsid) == 4)
#assert(offset_of(Submission_Entry, metadata_ptr) == 16)
#assert(offset_of(Submission_Entry, prp1) == 24)
#assert(offset_of(Submission_Entry, prp2) == 32)
#assert(offset_of(Submission_Entry, cdw10) == 40)
#assert(offset_of(Submission_Entry, cdw15) == 60)

// NVMe 1.4+ 16-byte Completion Queue Entry (CQE), little-endian hardware layout.
Completion_Entry :: struct {
	result:           u32,
	reserved:         u32,
	sq_head:          u16,
	sq_id:            u16,
	command_id:       u16,
	status_and_phase: u16,
}

#assert(size_of(Completion_Entry) == 16)
#assert(offset_of(Completion_Entry, sq_head) == 8)
#assert(offset_of(Completion_Entry, sq_id) == 10)
#assert(offset_of(Completion_Entry, command_id) == 12)
#assert(offset_of(Completion_Entry, status_and_phase) == 14)

// Parameters for building validated NVMe Read and Write I/O commands.
Io_Transfer_Params :: struct {
	command_id:         u16,
	nsid:               u32,
	lba:                u64,
	sector_count:       u32,
	sector_size:        u32,
	namespace_blocks:   u64,
	max_transfer_bytes: u64,
	prp1:               u64,
	prp2:               u64,
}

// Pure protocol state machine for one NVMe Submission/Completion queue pair.
// Tracks ring pointers, CQ phase bit inversion on wraparound, and every
// in-flight 16-bit command ID to refuse duplicate submissions and unknown
// completions.
Queue_Pair_State :: struct {
	initialized:      bool,
	queue_id:         u16,
	sq_size:          u16,
	cq_size:          u16,
	sq_head:          u16,
	sq_tail:          u16,
	cq_head:          u16,
	cq_phase:         bool,
	in_flight_count:  u16,
	in_flight_bitmap: [CID_BITMAP_WORDS]u64,
}

// Transport word borders converting raw register/ring values into closed enums.

admin_opcode_of_word :: proc "contextless" (word: u64) -> (opcode: Admin_Opcode, ok: bool) {
	return enum_word.member_of_word(Admin_Opcode, word)
}

io_opcode_of_word :: proc "contextless" (word: u64) -> (opcode: Io_Opcode, ok: bool) {
	return enum_word.member_of_word(Io_Opcode, word)
}

status_code_type_of_word :: proc "contextless" (word: u64) -> (sct: Nvme_Status_Code_Type, ok: bool) {
	return enum_word.member_of_word(Nvme_Status_Code_Type, word)
}

refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Nvme_Refusal, ok: bool) {
	return enum_word.member_of_word(Nvme_Refusal, word)
}

// is_valid_queue_size reports whether size is a power of two in 2 ..= 4096.
is_valid_queue_size :: proc "contextless" (size: u16) -> bool {
	if size < MIN_QUEUE_SIZE || size > MAX_QUEUE_SIZE {
		return false
	}
	return (size & (size - 1)) == 0
}

// is_valid_sector_size reports whether bytes is a power of two in 512 ..= 4096.
is_valid_sector_size :: proc "contextless" (bytes: u32) -> bool {
	if bytes < MIN_SECTOR_SIZE || bytes > MAX_SECTOR_SIZE {
		return false
	}
	return (bytes & (bytes - 1)) == 0
}

@(private)
validate_page_aligned_address :: proc "contextless" (address: u64) -> Nvme_Refusal {
	if address == 0 {
		return .Zero_Address
	}
	if (address & (PAGE_SIZE - 1)) != 0 {
		return .Unaligned_Address
	}
	return .None
}

// doorbell_offset calculates the BAR0 byte offset of a Submission or Completion
// Queue doorbell: 0x1000 + (2 * qid + is_cq) * (4 << dstrd).
// Refuses dstrd > 15 (CAP.DSTRD is 4 bits) and checks arithmetic bounds.
doorbell_offset :: proc "contextless" (queue_id: u16, is_cq: bool, dstrd: u8) -> (offset: u64, refusal: Nvme_Refusal) {
	if dstrd > MAX_DOORBELL_STRIDE {
		return 0, .Bad_Doorbell_Stride
	}
	stride := u64(4) << uint(dstrd)
	index := u64(queue_id) * 2 + (is_cq ? u64(1) : u64(0))
	if index > (max(u64) - DOORBELL_BASE_OFFSET) / stride {
		return 0, .Doorbell_Offset_Overflow
	}
	return DOORBELL_BASE_OFFSET + index * stride, .None
}

// doorbell_offset_in_bar calculates the doorbell offset and verifies that the
// 4-byte doorbell register fits strictly within bar_size bytes.
doorbell_offset_in_bar :: proc "contextless" (
	queue_id: u16,
	is_cq: bool,
	dstrd: u8,
	bar_size: u64,
) -> (offset: u64, refusal: Nvme_Refusal) {
	computed, off_refusal := doorbell_offset(queue_id, is_cq, dstrd)
	if off_refusal != .None {
		return 0, off_refusal
	}
	if bar_size < 4 || computed > bar_size - 4 {
		return 0, .Doorbell_Offset_Overflow
	}
	return computed, .None
}

// queue_pair_init initializes a queue pair with power-of-two SQ and CQ sizes.
// Per NVMe 1.4+, the controller initializes CQ memory to 0 and writes the
// first generation of completions with Phase Tag = 1 (cq_phase = true).
queue_pair_init :: proc "contextless" (
	qp: ^Queue_Pair_State,
	queue_id: u16,
	sq_size: u16,
	cq_size: u16,
) -> Nvme_Refusal {
	if !is_valid_queue_size(sq_size) || !is_valid_queue_size(cq_size) {
		return .Bad_Queue_Size
	}
	qp^ = Queue_Pair_State {
		initialized     = true,
		queue_id        = queue_id,
		sq_size         = sq_size,
		cq_size         = cq_size,
		sq_head         = 0,
		sq_tail         = 0,
		cq_head         = 0,
		cq_phase        = true,
		in_flight_count = 0,
	}
	return .None
}

@(private)
cid_is_in_flight :: proc "contextless" (qp: ^Queue_Pair_State, command_id: u16) -> bool {
	word := int(command_id >> 6)
	bit := uint(command_id & 63)
	return ((qp.in_flight_bitmap[word] >> bit) & 1) != 0
}

@(private)
cid_set_in_flight :: proc "contextless" (qp: ^Queue_Pair_State, command_id: u16) {
	word := int(command_id >> 6)
	bit := uint(command_id & 63)
	qp.in_flight_bitmap[word] |= u64(1) << bit
}

@(private)
cid_clear_in_flight :: proc "contextless" (qp: ^Queue_Pair_State, command_id: u16) {
	word := int(command_id >> 6)
	bit := uint(command_id & 63)
	qp.in_flight_bitmap[word] &= ~(u64(1) << bit)
}

// queue_pair_command_in_flight reports whether command_id is currently active.
queue_pair_command_in_flight :: proc "contextless" (qp: ^Queue_Pair_State, command_id: u16) -> bool {
	if !qp.initialized {
		return false
	}
	return cid_is_in_flight(qp, command_id)
}

// queue_pair_submit reserves the next SQ slot for command_id and advances
// sq_tail. Refuses uninitialized queues, full rings (sq_size - 1 slots used),
// or duplicate in-flight command IDs without mutating queue state.
queue_pair_submit :: proc "contextless" (
	qp: ^Queue_Pair_State,
	command_id: u16,
) -> (slot: u16, new_sq_tail: u16, refusal: Nvme_Refusal) {
	if !qp.initialized {
		return 0, 0, .Not_Initialized
	}
	next_tail := (qp.sq_tail + 1) & (qp.sq_size - 1)
	if next_tail == qp.sq_head || qp.in_flight_count >= qp.sq_size - 1 {
		return 0, 0, .Queue_Full
	}
	if cid_is_in_flight(qp, command_id) {
		return 0, 0, .Duplicate_Command_Id
	}
	slot = qp.sq_tail
	qp.sq_tail = next_tail
	cid_set_in_flight(qp, command_id)
	qp.in_flight_count += 1
	return slot, qp.sq_tail, .None
}

// completion_phase extracts the Phase Tag bit (bit 0 of status_and_phase).
completion_phase :: proc "contextless" (entry: Completion_Entry) -> bool {
	return (entry.status_and_phase & 1) != 0
}

// completion_status_code extracts the 8-bit Status Code (bits 8:1).
completion_status_code :: proc "contextless" (entry: Completion_Entry) -> u8 {
	return u8((entry.status_and_phase >> 1) & 0xFF)
}

// completion_status_code_type converts bits 11:9 into Nvme_Status_Code_Type.
completion_status_code_type :: proc "contextless" (entry: Completion_Entry) -> (sct: Nvme_Status_Code_Type, ok: bool) {
	raw := u64((entry.status_and_phase >> 9) & 0x07)
	return status_code_type_of_word(raw)
}

// encode_status_and_phase packs phase, status_code, and status_code_type into
// the 16-bit status_and_phase field of a Completion_Entry.
encode_status_and_phase :: proc "contextless" (phase: bool, status_code: u8, sct: Nvme_Status_Code_Type) -> u16 {
	return (phase ? u16(1) : u16(0)) | (u16(status_code) << 1) | (u16(sct) << 9)
}

// queue_pair_complete validates and consumes a Completion_Entry at cq_head.
// Refuses mismatched phase tags (no new completion ready), wrong sq_id,
// out-of-range sq_head, unknown command_id, or invalid Status Code Type
// without mutating state. On a valid hardware completion, retires command_id,
// updates sq_head, advances cq_head (flipping cq_phase on wraparound), and
// returns .Command_Failed if the controller reported non-zero status.
queue_pair_complete :: proc "contextless" (
	qp: ^Queue_Pair_State,
	entry: Completion_Entry,
) -> (sct: Nvme_Status_Code_Type, status_code: u8, new_cq_head: u16, refusal: Nvme_Refusal) {
	if !qp.initialized {
		return {}, 0, 0, .Not_Initialized
	}
	if completion_phase(entry) != qp.cq_phase {
		return {}, 0, qp.cq_head, .No_Completion_Ready
	}
	if entry.sq_id != qp.queue_id {
		return {}, 0, qp.cq_head, .Bad_Sq_Id
	}
	if entry.sq_head >= qp.sq_size {
		return {}, 0, qp.cq_head, .Bad_Sq_Head
	}
	if !cid_is_in_flight(qp, entry.command_id) {
		return {}, 0, qp.cq_head, .Unknown_Command_Id
	}
	parsed_sct, sct_ok := completion_status_code_type(entry)
	if !sct_ok {
		return {}, 0, qp.cq_head, .Bad_Status_Code_Type
	}
	sc := completion_status_code(entry)

	cid_clear_in_flight(qp, entry.command_id)
	qp.in_flight_count -= 1
	qp.sq_head = entry.sq_head

	next_head := qp.cq_head + 1
	if next_head == qp.cq_size {
		qp.cq_head = 0
		qp.cq_phase = !qp.cq_phase
	} else {
		qp.cq_head = next_head
	}

	if parsed_sct != .Generic || sc != 0 {
		return parsed_sct, sc, qp.cq_head, .Command_Failed
	}
	return parsed_sct, sc, qp.cq_head, .None
}

// build_identify_controller builds an Admin Identify Controller (CNS = 0x01) SQE.
build_identify_controller :: proc "contextless" (command_id: u16, prp1: u64) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	if addr_refusal := validate_page_aligned_address(prp1); addr_refusal != .None {
		return {}, addr_refusal
	}
	return Submission_Entry {
		opcode     = u8(Admin_Opcode.Identify),
		command_id = command_id,
		nsid       = 0,
		prp1       = prp1,
		cdw10      = u32(Identify_Cns.Controller),
	}, .None
}

// build_identify_namespace builds an Admin Identify Namespace (CNS = 0x00) SQE.
build_identify_namespace :: proc "contextless" (command_id: u16, nsid: u32, prp1: u64) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	if nsid == 0 || nsid == BROADCAST_NSID {
		return {}, .Bad_Namespace_Id
	}
	if addr_refusal := validate_page_aligned_address(prp1); addr_refusal != .None {
		return {}, addr_refusal
	}
	return Submission_Entry {
		opcode     = u8(Admin_Opcode.Identify),
		command_id = command_id,
		nsid       = nsid,
		prp1       = prp1,
		cdw10      = u32(Identify_Cns.Namespace),
	}, .None
}

// build_create_io_cq builds an Admin Create I/O Completion Queue SQE with
// Physically Contiguous (PC = 1) set in CDW11.
build_create_io_cq :: proc "contextless" (
	command_id: u16,
	queue_id: u16,
	queue_size: u16,
	prp1: u64,
	interrupt_vector: u16,
	interrupts_enabled: bool,
) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	if queue_id == 0 {
		return {}, .Bad_Queue_Id
	}
	if !is_valid_queue_size(queue_size) {
		return {}, .Bad_Queue_Size
	}
	if addr_refusal := validate_page_aligned_address(prp1); addr_refusal != .None {
		return {}, addr_refusal
	}
	cdw10 := u32(queue_id) | (u32(queue_size - 1) << 16)
	cdw11 := u32(1) | (interrupts_enabled ? u32(1 << 1) : u32(0)) | (u32(interrupt_vector) << 16)
	return Submission_Entry {
		opcode     = u8(Admin_Opcode.Create_IO_CQ),
		command_id = command_id,
		prp1       = prp1,
		cdw10      = cdw10,
		cdw11      = cdw11,
	}, .None
}

// build_create_io_sq builds an Admin Create I/O Submission Queue SQE bound to
// cq_id with Physically Contiguous (PC = 1) set in CDW11.
build_create_io_sq :: proc "contextless" (
	command_id: u16,
	queue_id: u16,
	cq_id: u16,
	queue_size: u16,
	prp1: u64,
) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	if queue_id == 0 || cq_id == 0 {
		return {}, .Bad_Queue_Id
	}
	if !is_valid_queue_size(queue_size) {
		return {}, .Bad_Queue_Size
	}
	if addr_refusal := validate_page_aligned_address(prp1); addr_refusal != .None {
		return {}, addr_refusal
	}
	cdw10 := u32(queue_id) | (u32(queue_size - 1) << 16)
	cdw11 := u32(1) | (u32(cq_id) << 16)
	return Submission_Entry {
		opcode     = u8(Admin_Opcode.Create_IO_SQ),
		command_id = command_id,
		prp1       = prp1,
		cdw10      = cdw10,
		cdw11      = cdw11,
	}, .None
}

@(private)
build_io_rw :: proc "contextless" (opcode: Io_Opcode, params: Io_Transfer_Params) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	if params.nsid == 0 || params.nsid == BROADCAST_NSID {
		return {}, .Bad_Namespace_Id
	}
	if params.sector_count == 0 {
		return {}, .Zero_Sector_Count
	}
	if params.sector_count > MAX_NLB_SECTORS {
		return {}, .Transfer_Too_Large
	}
	if !is_valid_sector_size(params.sector_size) {
		return {}, .Bad_Sector_Size
	}
	total_bytes := u64(params.sector_count) * u64(params.sector_size)
	if params.max_transfer_bytes == 0 || total_bytes > params.max_transfer_bytes {
		return {}, .Transfer_Too_Large
	}
	// Overflow-safe check for lba + sector_count <= namespace_blocks.
	if u64(params.sector_count) > params.namespace_blocks || params.lba > params.namespace_blocks - u64(params.sector_count) {
		return {}, .Lba_Out_Of_Range
	}
	if addr_refusal := validate_page_aligned_address(params.prp1); addr_refusal != .None {
		return {}, addr_refusal
	}
	if total_bytes > PAGE_SIZE {
		if params.prp2 == 0 {
			return {}, .Missing_Prp2
		}
		if (params.prp2 & (PAGE_SIZE - 1)) != 0 {
			return {}, .Unaligned_Address
		}
	} else if params.prp2 != 0 {
		return {}, .Unexpected_Prp2
	}

	return Submission_Entry {
		opcode     = u8(opcode),
		command_id = params.command_id,
		nsid       = params.nsid,
		prp1       = params.prp1,
		prp2       = params.prp2,
		cdw10      = u32(params.lba & 0xFFFF_FFFF),
		cdw11      = u32(params.lba >> 32),
		cdw12      = params.sector_count - 1,
	}, .None
}

// build_io_read validates DMA addresses, LBA range, and transfer limits, then
// constructs an NVMe I/O Read SQE.
build_io_read :: proc "contextless" (params: Io_Transfer_Params) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	return build_io_rw(.Read, params)
}

// build_io_write validates DMA addresses, LBA range, and transfer limits, then
// constructs an NVMe I/O Write SQE.
build_io_write :: proc "contextless" (params: Io_Transfer_Params) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	return build_io_rw(.Write, params)
}

// build_io_flush constructs an NVMe I/O Flush SQE for nsid.
build_io_flush :: proc "contextless" (command_id: u16, nsid: u32) -> (entry: Submission_Entry, refusal: Nvme_Refusal) {
	if nsid == 0 || nsid == BROADCAST_NSID {
		return {}, .Bad_Namespace_Id
	}
	return Submission_Entry {
		opcode     = u8(Io_Opcode.Flush),
		command_id = command_id,
		nsid       = nsid,
	}, .None
}
