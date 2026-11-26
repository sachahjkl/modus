#+build !freestanding
#+build !modus
package nvme

import "core:testing"

// Verify hardware sizes, closed enum borders, and doorbell offset edge cases.
@(test)
enum_borders_and_doorbell_offsets :: proc(t: ^testing.T) {
	// Closed enum borders accept exact members and refuse unknown values.
	op, ok := admin_opcode_of_word(0x06)
	testing.expect(t, ok && op == .Identify, "0x06 must decode as Identify")
	_, ok = admin_opcode_of_word(0x02)
	testing.expect(t, !ok, "0x02 is not a supported Admin_Opcode")
	_, ok = admin_opcode_of_word(0x100)
	testing.expect(t, !ok, "0x100 is out of range for Admin_Opcode")

	io_op, io_ok := io_opcode_of_word(0x02)
	testing.expect(t, io_ok && io_op == .Read, "0x02 must decode as Read")
	_, io_ok = io_opcode_of_word(0x03)
	testing.expect(t, !io_ok, "0x03 is not a valid Io_Opcode")

	sct, sct_ok := status_code_type_of_word(0x07)
	testing.expect(t, sct_ok && sct == .Vendor_Specific, "0x07 must decode as Vendor_Specific")
	for bad in ([]u64{4, 5, 6, 8, 255}) {
		_, b_ok := status_code_type_of_word(bad)
		testing.expect(t, !b_ok, "reserved Status Code Type must be refused")
	}

	// Doorbell offsets: 0x1000 + (2 * qid + is_cq) * (4 << dstrd).
	off, r := doorbell_offset(0, false, 0)
	testing.expect_value(t, r, Nvme_Refusal.None)
	testing.expect_value(t, off, u64(0x1000))

	off, r = doorbell_offset(0, true, 0)
	testing.expect_value(t, r, Nvme_Refusal.None)
	testing.expect_value(t, off, u64(0x1004))

	off, r = doorbell_offset(1, false, 0)
	testing.expect_value(t, r, Nvme_Refusal.None)
	testing.expect_value(t, off, u64(0x1008))

	off, r = doorbell_offset(1, true, 2) // stride = 16, index = 3 -> 0x1030
	testing.expect_value(t, r, Nvme_Refusal.None)
	testing.expect_value(t, off, u64(0x1030))

	// Max valid dstrd (15) succeeds; 16 and 255 refused.
	off, r = doorbell_offset(max(u16), true, 15)
	testing.expect_value(t, r, Nvme_Refusal.None)
	testing.expect_value(t, off, u64(0x1000) + (2 * u64(max(u16)) + 1) * (u64(4) << 15))

	_, r = doorbell_offset(0, false, 16)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Doorbell_Stride)
	_, r = doorbell_offset(0, false, 255)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Doorbell_Stride)

	// BAR0 bounds check catches doorbell overflow.
	_, r = doorbell_offset_in_bar(0, true, 0, 0x1007)
	testing.expect_value(t, r, Nvme_Refusal.Doorbell_Offset_Overflow)
	off, r = doorbell_offset_in_bar(0, true, 0, 0x1008)
	testing.expect_value(t, r, Nvme_Refusal.None)
	testing.expect_value(t, off, u64(0x1004))
}

// Exhaustive Queue_Pair_State tests: queue size edges, full ring, duplicate/unknown CID,
// phase flip on CQ wraparound, bad SQ ID/head, and error completions.
@(test)
queue_pair_state_edges_phase_flip_and_cid_tracking :: proc(t: ^testing.T) {
	qp := new(Queue_Pair_State)
	defer free(qp)

	// Uninitialized queue refuses submit and complete.
	_, _, r := queue_pair_submit(qp, 1)
	testing.expect_value(t, r, Nvme_Refusal.Not_Initialized)
	_, _, _, r = queue_pair_complete(qp, {})
	testing.expect_value(t, r, Nvme_Refusal.Not_Initialized)

	// Bad queue sizes: 0, 1, 3, 6, 4097, 8192.
	for bad_size in ([]u16{0, 1, 3, 6, 4097, 8192, max(u16)}) {
		testing.expect_value(t, queue_pair_init(qp, 1, bad_size, 4), Nvme_Refusal.Bad_Queue_Size)
		testing.expect_value(t, queue_pair_init(qp, 1, 4, bad_size), Nvme_Refusal.Bad_Queue_Size)
	}
	testing.expect(t, !qp.initialized, "refused init must leave qp uninitialized")

	// Valid edge sizes: 2 and 4096.
	testing.expect_value(t, queue_pair_init(qp, 1, 4096, 4096), Nvme_Refusal.None)
	testing.expect_value(t, queue_pair_init(qp, 1, 2, 2), Nvme_Refusal.None)
	testing.expect_value(t, qp.cq_phase, true)

	// SQ size 2 holds at most 1 in-flight entry (next_tail == sq_head when full).
	slot, tail, sr := queue_pair_submit(qp, 42)
	testing.expect_value(t, sr, Nvme_Refusal.None)
	testing.expect_value(t, slot, u16(0))
	testing.expect_value(t, tail, u16(1))
	testing.expect(t, queue_pair_command_in_flight(qp, 42), "CID 42 must be in-flight")

	_, _, sr = queue_pair_submit(qp, 43)
	testing.expect_value(t, sr, Nvme_Refusal.Queue_Full)

	// Re-init with size 4 to test duplicate CID, unknown CID, bad fields, and CQ phase flip.
	testing.expect_value(t, queue_pair_init(qp, 3, 4, 4), Nvme_Refusal.None)
	s0, _, r0 := queue_pair_submit(qp, 0x0000)
	testing.expect_value(t, r0, Nvme_Refusal.None)
	testing.expect_value(t, s0, u16(0))

	// Duplicate CID 0 refused without moving sq_tail.
	_, _, r_dup := queue_pair_submit(qp, 0x0000)
	testing.expect_value(t, r_dup, Nvme_Refusal.Duplicate_Command_Id)
	testing.expect_value(t, qp.sq_tail, u16(1))
	testing.expect_value(t, qp.in_flight_count, u16(1))

	s1, _, r1 := queue_pair_submit(qp, 0xFFFF)
	testing.expect_value(t, r1, Nvme_Refusal.None)
	testing.expect_value(t, s1, u16(1))
	s2, _, r2 := queue_pair_submit(qp, 0x1234)
	testing.expect_value(t, r2, Nvme_Refusal.None)
	testing.expect_value(t, s2, u16(2))
	// 4th submit fails: ring of size 4 is full at 3 outstanding.
	_, _, r3 := queue_pair_submit(qp, 0x5678)
	testing.expect_value(t, r3, Nvme_Refusal.Queue_Full)

	// Wrong phase (phase = false when expected = true) -> No_Completion_Ready, zero mutation.
	bad_phase := Completion_Entry{sq_head = 1, sq_id = 3, command_id = 0x0000, status_and_phase = encode_status_and_phase(false, 0, .Generic)}
	_, _, _, cr := queue_pair_complete(qp, bad_phase)
	testing.expect_value(t, cr, Nvme_Refusal.No_Completion_Ready)

	// Wrong sq_id -> Bad_Sq_Id.
	bad_sqid := Completion_Entry{sq_head = 1, sq_id = 2, command_id = 0x0000, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	_, _, _, cr = queue_pair_complete(qp, bad_sqid)
	testing.expect_value(t, cr, Nvme_Refusal.Bad_Sq_Id)

	// Out-of-bounds sq_head (>= 4) -> Bad_Sq_Head.
	bad_head := Completion_Entry{sq_head = 4, sq_id = 3, command_id = 0x0000, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	_, _, _, cr = queue_pair_complete(qp, bad_head)
	testing.expect_value(t, cr, Nvme_Refusal.Bad_Sq_Head)

	// Unknown CID -> Unknown_Command_Id.
	bad_cid := Completion_Entry{sq_head = 1, sq_id = 3, command_id = 0x9999, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	_, _, _, cr = queue_pair_complete(qp, bad_cid)
	testing.expect_value(t, cr, Nvme_Refusal.Unknown_Command_Id)

	// Reserved SCT (4) -> Bad_Status_Code_Type.
	bad_sct := Completion_Entry{sq_head = 1, sq_id = 3, command_id = 0x0000, status_and_phase = u16(1) | (u16(4) << 9)}
	_, _, _, cr = queue_pair_complete(qp, bad_sct)
	testing.expect_value(t, cr, Nvme_Refusal.Bad_Status_Code_Type)
	testing.expect_value(t, qp.in_flight_count, u16(3))
	testing.expect_value(t, qp.cq_head, u16(0))

	// Complete 4 entries across a full CQ wraparound and confirm phase flips from true -> false!
	c0 := Completion_Entry{sq_head = 1, sq_id = 3, command_id = 0x0000, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	sct, sc, head, cr0 := queue_pair_complete(qp, c0)
	testing.expect_value(t, cr0, Nvme_Refusal.None)
	testing.expect_value(t, sct, Nvme_Status_Code_Type.Generic)
	testing.expect_value(t, sc, u8(0))
	testing.expect_value(t, head, u16(1))
	testing.expect(t, !queue_pair_command_in_flight(qp, 0x0000), "completed CID must be retired")

	// Replaying the same completion for retired CID 0x0000 must fail as Unknown_Command_Id.
	_, _, _, cr_replay := queue_pair_complete(qp, c0)
	testing.expect_value(t, cr_replay, Nvme_Refusal.Unknown_Command_Id)

	// Submit a 4th command (slot 3 -> wraps sq_tail to 0!) and complete remaining 3 to wrap CQ.
	s3, t3, r_s3 := queue_pair_submit(qp, 0xBEEF)
	testing.expect_value(t, r_s3, Nvme_Refusal.None)
	testing.expect_value(t, s3, u16(3))
	testing.expect_value(t, t3, u16(0))

	// Hardware error completion retires CID and returns Command_Failed with parsed SCT/SC.
	c1 := Completion_Entry{sq_head = 2, sq_id = 3, command_id = 0xFFFF, status_and_phase = encode_status_and_phase(true, 0x81, .Media_And_Data_Integrity)}
	sct1, sc1, head1, cr1 := queue_pair_complete(qp, c1)
	testing.expect_value(t, cr1, Nvme_Refusal.Command_Failed)
	testing.expect_value(t, sct1, Nvme_Status_Code_Type.Media_And_Data_Integrity)
	testing.expect_value(t, sc1, u8(0x81))
	testing.expect_value(t, head1, u16(2))

	c2 := Completion_Entry{sq_head = 3, sq_id = 3, command_id = 0x1234, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	_, _, head2, cr2 := queue_pair_complete(qp, c2)
	testing.expect_value(t, cr2, Nvme_Refusal.None)
	testing.expect_value(t, head2, u16(3))
	testing.expect_value(t, qp.cq_phase, true)

	// 4th completion wraps cq_head from 3 -> 0 and flips cq_phase from true -> false.
	c3 := Completion_Entry{sq_head = 0, sq_id = 3, command_id = 0xBEEF, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	_, _, head3, cr3 := queue_pair_complete(qp, c3)
	testing.expect_value(t, cr3, Nvme_Refusal.None)
	testing.expect_value(t, head3, u16(0))
	testing.expect_value(t, qp.cq_phase, false)
	testing.expect_value(t, qp.in_flight_count, u16(0))

	// Next generation completion must carry phase = false.
	_, _, _ = queue_pair_submit(qp, 0x0007)
	stale_phase := Completion_Entry{sq_head = 1, sq_id = 3, command_id = 0x0007, status_and_phase = encode_status_and_phase(true, 0, .Generic)}
	_, _, _, cr_stale := queue_pair_complete(qp, stale_phase)
	testing.expect_value(t, cr_stale, Nvme_Refusal.No_Completion_Ready)

	gen2 := Completion_Entry{sq_head = 1, sq_id = 3, command_id = 0x0007, status_and_phase = encode_status_and_phase(false, 0, .Generic)}
	_, _, head4, cr4 := queue_pair_complete(qp, gen2)
	testing.expect_value(t, cr4, Nvme_Refusal.None)
	testing.expect_value(t, head4, u16(1))
}

// Exhaustive adversarial tests for Admin and I/O command builders:
// 4 KiB PRP alignment, LBA + sector_count overflow, max transfer size, zero-sector refusal.
@(test)
command_builders_validate_alignment_lba_overflow_and_limits :: proc(t: ^testing.T) {
	// Admin Identify Controller & Namespace.
	_, r := build_identify_controller(1, 0)
	testing.expect_value(t, r, Nvme_Refusal.Zero_Address)
	_, r = build_identify_controller(1, 0x1001)
	testing.expect_value(t, r, Nvme_Refusal.Unaligned_Address)
	id_ctrl, r_ok := build_identify_controller(7, 0x2000_0000)
	testing.expect_value(t, r_ok, Nvme_Refusal.None)
	testing.expect_value(t, id_ctrl.opcode, u8(Admin_Opcode.Identify))
	testing.expect_value(t, id_ctrl.cdw10, u32(Identify_Cns.Controller))

	_, r = build_identify_namespace(2, 0, 0x2000_0000)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Namespace_Id)
	_, r = build_identify_namespace(2, BROADCAST_NSID, 0x2000_0000)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Namespace_Id)
	id_ns, r_ns := build_identify_namespace(8, 1, 0x2000_1000)
	testing.expect_value(t, r_ns, Nvme_Refusal.None)
	testing.expect_value(t, id_ns.nsid, u32(1))
	testing.expect_value(t, id_ns.cdw10, u32(Identify_Cns.Namespace))

	// Create I/O CQ and SQ.
	_, r = build_create_io_cq(3, 0, 64, 0x3000_0000, 1, true)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Queue_Id)
	_, r = build_create_io_cq(3, 1, 63, 0x3000_0000, 1, true)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Queue_Size)
	_, r = build_create_io_cq(3, 1, 64, 0x3000_0008, 1, true)
	testing.expect_value(t, r, Nvme_Refusal.Unaligned_Address)
	cq_cmd, r_cq := build_create_io_cq(3, 1, 64, 0x3000_0000, 5, true)
	testing.expect_value(t, r_cq, Nvme_Refusal.None)
	testing.expect_value(t, cq_cmd.opcode, u8(Admin_Opcode.Create_IO_CQ))
	testing.expect_value(t, cq_cmd.cdw10, u32(1) | (u32(63) << 16))
	testing.expect_value(t, cq_cmd.cdw11, u32(3) | (u32(5) << 16))

	_, r = build_create_io_sq(4, 0, 1, 64, 0x3000_1000)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Queue_Id)
	_, r = build_create_io_sq(4, 1, 0, 64, 0x3000_1000)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Queue_Id)
	sq_cmd, r_sq := build_create_io_sq(4, 2, 1, 128, 0x3000_1000)
	testing.expect_value(t, r_sq, Nvme_Refusal.None)
	testing.expect_value(t, sq_cmd.opcode, u8(Admin_Opcode.Create_IO_SQ))
	testing.expect_value(t, sq_cmd.cdw10, u32(2) | (u32(127) << 16))
	testing.expect_value(t, sq_cmd.cdw11, u32(1) | (u32(1) << 16))

	// I/O Read / Write / Flush edge refusals.
	base := Io_Transfer_Params {
		command_id         = 10,
		nsid               = 1,
		lba                = 0,
		sector_count       = 8, // 8 * 512 = 4096 bytes (1 page)
		sector_size        = 512,
		namespace_blocks   = 1024,
		max_transfer_bytes = 65536,
		prp1               = 0x4000_0000,
		prp2               = 0,
	}

	// Zero sectors refused.
	p := base; p.sector_count = 0
	_, r = build_io_read(p)
	testing.expect_value(t, r, Nvme_Refusal.Zero_Sector_Count)

	// Past NLB limit (65537) and past max_transfer_bytes refused.
	p = base; p.sector_count = 65537
	_, r = build_io_read(p)
	testing.expect_value(t, r, Nvme_Refusal.Transfer_Too_Large)
	p = base; p.sector_count = 129; p.prp2 = 0x4000_1000 // 129 * 512 > 65536
	_, r = build_io_write(p)
	testing.expect_value(t, r, Nvme_Refusal.Transfer_Too_Large)

	// Bad sector sizes (0, 256, 1000, 8192).
	for bad_ss in ([]u32{0, 256, 1000, 8192}) {
		p = base; p.sector_size = bad_ss
		_, r = build_io_read(p)
		testing.expect_value(t, r, Nvme_Refusal.Bad_Sector_Size)
	}

	// LBA + sector_count overflow and exact boundary.
	p = base; p.lba = max(u64); p.sector_count = 1; p.namespace_blocks = max(u64)
	_, r = build_io_read(p)
	testing.expect_value(t, r, Nvme_Refusal.Lba_Out_Of_Range)

	p = base; p.lba = 1017; p.sector_count = 8; p.namespace_blocks = 1024 // 1017 + 8 = 1025 > 1024
	_, r = build_io_write(p)
	testing.expect_value(t, r, Nvme_Refusal.Lba_Out_Of_Range)

	// Exact end of namespace (1016 + 8 == 1024) succeeds!
	p = base; p.lba = 1016; p.sector_count = 8; p.namespace_blocks = 1024
	rd, r_rd := build_io_read(p)
	testing.expect_value(t, r_rd, Nvme_Refusal.None)
	testing.expect_value(t, rd.opcode, u8(Io_Opcode.Read))
	testing.expect_value(t, rd.cdw10, u32(1016))
	testing.expect_value(t, rd.cdw11, u32(0))
	testing.expect_value(t, rd.cdw12, u32(7))

	// PRP1/PRP2 alignment and presence checks.
	p = base; p.prp1 = 0x4000_0001
	_, r = build_io_read(p)
	testing.expect_value(t, r, Nvme_Refusal.Unaligned_Address)

	// Single-page transfer with stray non-zero PRP2 refused.
	p = base; p.prp2 = 0x4000_1000
	_, r = build_io_read(p)
	testing.expect_value(t, r, Nvme_Refusal.Unexpected_Prp2)

	// Multi-page transfer (2 pages = 8192 bytes) requires 4 KiB-aligned PRP2.
	p = base; p.sector_count = 16; p.prp2 = 0
	_, r = build_io_write(p)
	testing.expect_value(t, r, Nvme_Refusal.Missing_Prp2)
	p = base; p.sector_count = 16; p.prp2 = 0x4000_1004
	_, r = build_io_write(p)
	testing.expect_value(t, r, Nvme_Refusal.Unaligned_Address)
	p = base; p.sector_count = 16; p.prp2 = 0x4000_1000; p.lba = 0x0000_0002_0000_0005; p.namespace_blocks = 0x0000_0003_0000_0000
	wr, r_wr := build_io_write(p)
	testing.expect_value(t, r_wr, Nvme_Refusal.None)
	testing.expect_value(t, wr.opcode, u8(Io_Opcode.Write))
	testing.expect_value(t, wr.cdw10, u32(5))
	testing.expect_value(t, wr.cdw11, u32(2))
	testing.expect_value(t, wr.cdw12, u32(15))
	testing.expect_value(t, wr.prp2, u64(0x4000_1000))

	// Flush.
	_, r = build_io_flush(11, 0)
	testing.expect_value(t, r, Nvme_Refusal.Bad_Namespace_Id)
	fl, r_fl := build_io_flush(11, 1)
	testing.expect_value(t, r_fl, Nvme_Refusal.None)
	testing.expect_value(t, fl.opcode, u8(Io_Opcode.Flush))
	testing.expect_value(t, fl.nsid, u32(1))
}
