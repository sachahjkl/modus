#+build !freestanding
package software_machine_demonstration

import "core:sync"
import "core:testing"
import "modus:contract/byte_order"
import software "modus:contract/software_machine"

// The C-ABI export bridge owns one static VM instance; serialize tests that
// exercise it so multi-threaded test runners do not race on vm_instance.
@(private = "file")
vm_export_test_mutex: sync.Mutex

// Helper: append bytes to a fixed code buffer during test assembly.
@(private = "file")
Code_Emitter :: struct {
	bytes: [1024]u8,
	count: int,
}

@(private = "file")
emit_bytes :: proc(e: ^Code_Emitter, raw: ..u8) {
	for b in raw {
		e.bytes[e.count] = b
		e.count += 1
	}
}

@(private = "file")
emit_u32_le :: proc(e: ^Code_Emitter, val: u32) {
	emit_bytes(e, u8(val), u8(val >> 8), u8(val >> 16), u8(val >> 24))
}

@(private = "file")
emit_u64_le :: proc(e: ^Code_Emitter, val: u64) {
	emit_u32_le(e, u32(val))
	emit_u32_le(e, u32(val >> 32))
}

// Emit: mov rax, imm64 (48 B8 imm64)
@(private = "file")
emit_mov_rax_imm64 :: proc(e: ^Code_Emitter, imm: u64) {
	emit_bytes(e, 0x48, 0xB8)
	emit_u64_le(e, imm)
}

// Emit: mov rdi, imm64 (48 BF imm64)
@(private = "file")
emit_mov_rdi_imm64 :: proc(e: ^Code_Emitter, imm: u64) {
	emit_bytes(e, 0x48, 0xBF)
	emit_u64_le(e, imm)
}

// Emit: mov rsi, imm64 (48 BE imm64)
@(private = "file")
emit_mov_rsi_imm64 :: proc(e: ^Code_Emitter, imm: u64) {
	emit_bytes(e, 0x48, 0xBE)
	emit_u64_le(e, imm)
}

// Emit: mov rbx, imm64 (48 BB imm64)
@(private = "file")
emit_mov_rbx_imm64 :: proc(e: ^Code_Emitter, imm: u64) {
	emit_bytes(e, 0x48, 0xBB)
	emit_u64_le(e, imm)
}

// Emit: syscall (0F 05)
@(private = "file")
emit_syscall :: proc(e: ^Code_Emitter) {
	emit_bytes(e, 0x0F, 0x05)
}

@(test)
test_wasm_exports_uninitialized_and_border_refusals :: proc(t: ^testing.T) {
	sync.mutex_guard(&vm_export_test_mutex)
	// Reset static VM state to uninitialized.
	vm_instance = {}

	testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Uninitialized))
	testing.expect_value(t, modus_vm_framebuffer_ptr(), uintptr(0))
	testing.expect_value(t, modus_vm_framebuffer_bytes(), u32(0))
	testing.expect_value(t, modus_vm_framebuffer_width(), u32(0))
	testing.expect_value(t, modus_vm_framebuffer_height(), u32(0))
	testing.expect_value(t, modus_vm_pop_serial(), i32(-1))
	testing.expect_value(t, modus_vm_serial_available(), u32(0))
	testing.expect_value(t, modus_vm_steps_executed(), u64(0))

	sample := [4]u8{0x90, 0x90, 0x90, 0x90}
	testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(sample[:]), 4), u32(Vm_Call_Status.Not_Initialized))
	testing.expect_value(t, modus_vm_step_budget(1), u32(Vm_Call_Status.Not_Initialized))
	testing.expect_value(t, modus_vm_push_key(65, u32(Vm_Key_Action.Press), 0), u32(Vm_Call_Status.Not_Initialized))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Move), 0, 0, 0), u32(Vm_Call_Status.Not_Initialized))
	testing.expect_value(t, modus_vm_set_entry(VM_CODE_BASE), u32(Vm_Call_Status.Not_Initialized))

	// Refused framebuffer dimension edges: 0, one past bound, max(u32).
	bad_dims := [?][2]u32 {
		{0, 0},
		{0, 1},
		{1, 0},
		{VM_MAX_FRAMEBUFFER_WIDTH + 1, 1},
		{1, VM_MAX_FRAMEBUFFER_HEIGHT + 1},
		{VM_MAX_FRAMEBUFFER_WIDTH + 1, VM_MAX_FRAMEBUFFER_HEIGHT + 1},
		{max(u32), 1},
		{1, max(u32)},
	}
	for dim in bad_dims {
		status := modus_vm_init(dim[0], dim[1])
		testing.expect_value(t, status, u32(Vm_Call_Status.Invalid_Framebuffer_Size))
		testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Uninitialized))
	}

	// Valid init at minimum 1x1 succeeds, then an invalid re-init leaves state intact.
	testing.expect_value(t, modus_vm_init(1, 1), u32(Vm_Call_Status.Ok))
	testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Ready))
	testing.expect_value(t, modus_vm_framebuffer_bytes(), u32(4))
	testing.expect_value(t, modus_vm_init(VM_MAX_FRAMEBUFFER_WIDTH + 1, 10), u32(Vm_Call_Status.Invalid_Framebuffer_Size))
	testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Ready))
	testing.expect_value(t, modus_vm_framebuffer_width(), u32(1))
	testing.expect_value(t, modus_vm_framebuffer_height(), u32(1))

	// Valid full 640x400 init succeeds.
	testing.expect_value(t, modus_vm_init(VM_MAX_FRAMEBUFFER_WIDTH, VM_MAX_FRAMEBUFFER_HEIGHT), u32(Vm_Call_Status.Ok))
	testing.expect_value(t, modus_vm_framebuffer_bytes(), VM_MAX_FRAMEBUFFER_BYTES)
	testing.expect(t, modus_vm_framebuffer_ptr() != 0, "framebuffer pointer must be non-zero")
	testing.expect(t, modus_vm_staging_ptr() != 0, "staging pointer must be non-zero")
	testing.expect_value(t, modus_vm_staging_bytes(), VM_STAGING_BYTES)

	// Load border refusals: nil pointer, zero length, page-table region (< VM_CODE_BASE), OOB, u32 wraparound.
	testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), nil, 4), u32(Vm_Call_Status.Load_Empty_Or_Null))
	testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(sample[:]), 0), u32(Vm_Call_Status.Load_Empty_Or_Null))
	testing.expect_value(t, modus_vm_load_bytes(0, raw_data(sample[:]), 4), u32(Vm_Call_Status.Load_Out_Of_Bounds))
	testing.expect_value(t, modus_vm_load_bytes(u32(VM_PML4_OFFSET), raw_data(sample[:]), 4), u32(Vm_Call_Status.Load_Out_Of_Bounds))
	testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE) - 1, raw_data(sample[:]), 4), u32(Vm_Call_Status.Load_Out_Of_Bounds))
	testing.expect_value(t, modus_vm_load_bytes(VM_GUEST_RAM_BYTES, raw_data(sample[:]), 1), u32(Vm_Call_Status.Load_Out_Of_Bounds))
	testing.expect_value(t, modus_vm_load_bytes(VM_GUEST_RAM_BYTES - 2, raw_data(sample[:]), 4), u32(Vm_Call_Status.Load_Out_Of_Bounds))
	testing.expect_value(t, modus_vm_load_bytes(max(u32) - 2, raw_data(sample[:]), 4), u32(Vm_Call_Status.Load_Out_Of_Bounds))

	// Step budget refusals: 0, one past max, max(u32).
	testing.expect_value(t, modus_vm_step_budget(0), u32(Vm_Call_Status.Invalid_Step_Budget))
	testing.expect_value(t, modus_vm_step_budget(VM_MAX_STEP_BUDGET + 1), u32(Vm_Call_Status.Invalid_Step_Budget))
	testing.expect_value(t, modus_vm_step_budget(max(u32)), u32(Vm_Call_Status.Invalid_Step_Budget))
	testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Ready))

	// Entry address refusals.
	testing.expect_value(t, modus_vm_set_entry(0), u32(Vm_Call_Status.Invalid_Entry_Address))
	testing.expect_value(t, modus_vm_set_entry(VM_CODE_BASE - 1), u32(Vm_Call_Status.Invalid_Entry_Address))
	testing.expect_value(t, modus_vm_set_entry(VM_CODE_BASE + u64(VM_CODE_BYTES)), u32(Vm_Call_Status.Invalid_Entry_Address))
	testing.expect_value(t, modus_vm_set_entry(max(u64)), u32(Vm_Call_Status.Invalid_Entry_Address))

	// Key event border refusals: key_code 0 / past max, action 0 / 4 / max, invalid modifier bit.
	testing.expect_value(t, modus_vm_push_key(0, u32(Vm_Key_Action.Press), 0), u32(Vm_Call_Status.Invalid_Key_Event))
	testing.expect_value(t, modus_vm_push_key(VM_MAX_KEY_CODE + 1, u32(Vm_Key_Action.Press), 0), u32(Vm_Call_Status.Invalid_Key_Event))
	testing.expect_value(t, modus_vm_push_key(65, 0, 0), u32(Vm_Call_Status.Invalid_Key_Event))
	testing.expect_value(t, modus_vm_push_key(65, 4, 0), u32(Vm_Call_Status.Invalid_Key_Event))
	testing.expect_value(t, modus_vm_push_key(65, max(u32), 0), u32(Vm_Call_Status.Invalid_Key_Event))
	testing.expect_value(t, modus_vm_push_key(65, u32(Vm_Key_Action.Press), 0x10), u32(Vm_Call_Status.Invalid_Key_Event))
	testing.expect_value(t, modus_vm_push_key(65, u32(Vm_Key_Action.Press), max(u32)), u32(Vm_Call_Status.Invalid_Key_Event))

	// Pointer event border refusals: kind 0 / 5 / max, OOB x/y, invalid buttons.
	testing.expect_value(t, modus_vm_push_pointer(0, 0, 0, 0), u32(Vm_Call_Status.Invalid_Pointer_Event))
	testing.expect_value(t, modus_vm_push_pointer(5, 0, 0, 0), u32(Vm_Call_Status.Invalid_Pointer_Event))
	testing.expect_value(t, modus_vm_push_pointer(max(u32), 0, 0, 0), u32(Vm_Call_Status.Invalid_Pointer_Event))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Move), VM_MAX_FRAMEBUFFER_WIDTH, 0, 0), u32(Vm_Call_Status.Invalid_Pointer_Event))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Move), 0, VM_MAX_FRAMEBUFFER_HEIGHT, 0), u32(Vm_Call_Status.Invalid_Pointer_Event))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Button_Down), 10, 10, 0x20), u32(Vm_Call_Status.Invalid_Pointer_Event))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Button_Down), 10, 10, max(u32)), u32(Vm_Call_Status.Invalid_Pointer_Event))

	// Closed enum word decoders must refuse unknown values.
	for bad in ([?]u64{10, 255, max(u64)}) {
		_, s_ok := vm_call_status_from_word(bad)
		testing.expect(t, !s_ok)
		_, r_ok := vm_run_state_from_word(bad)
		testing.expect(t, !r_ok)
		_, k_ok := vm_key_action_from_word(bad)
		testing.expect(t, !k_ok)
		_, p_ok := vm_pointer_event_kind_from_word(bad)
		testing.expect(t, !p_ok)
		_, sc_ok := vm_syscall_number_from_word(bad)
		testing.expect(t, !sc_ok)
	}
}

@(test)
test_wasm_exports_program_draws_framebuffer_writes_serial_and_reads_input :: proc(t: ^testing.T) {
	sync.mutex_guard(&vm_export_test_mutex)
	testing.expect_value(t, modus_vm_init(64, 32), u32(Vm_Call_Status.Ok))
	testing.expect_value(t, modus_vm_framebuffer_bytes(), u32(64 * 32 * 4))

	// Load static banner bytes into guest data segment at VM_DATA_BASE.
	banner := "MODUS:"
	testing.expect_value(t, modus_vm_load_bytes(u32(VM_DATA_BASE), raw_data(banner), u32(len(banner))), u32(Vm_Call_Status.Ok))

	// Inject one keyboard event ('A' = 0x41, Press, Shift=1) and one pointer event (x=5, y=3, Button_Down, primary=1).
	testing.expect_value(t, modus_vm_push_key(0x41, u32(Vm_Key_Action.Press), 0x01), u32(Vm_Call_Status.Ok))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Button_Down), 5, 3, 0x01), u32(Vm_Call_Status.Ok))

	// Assemble a real x86-64 program that:
	// 1. Queries framebuffer info (syscall 5) -> RAX = fb_base, RDX = stride (256)
	// 2. Writes RGBA pixel 0xFF112233 at pixel (0, 0) -> [rax]
	// 3. Writes RGBA pixel 0xFF445566 at pixel (1, 0) -> [rax + 4]
	// 4. Emits "MODUS:" from VM_DATA_BASE via Write_Serial_Slice (syscall 2)
	// 5. Reads key event via Read_Key_Event (syscall 3) -> RDI = key_code (0x41)
	// 6. Emits key_code byte via Write_Serial_Byte (syscall 1) -> 'A'
	// 7. Reads pointer event via Read_Pointer_Event (syscall 4) -> RDI = x (5), RSI = y (3)
	// 8. Computes pixel offset = y * 256 + x * 4 = (rsi << 8) + (rdi << 2) and writes 0xFFAA_BBCC at [fb + offset]
	// 9. Halts via Halt (syscall 6)
	e: Code_Emitter

	// 1. Get_Framebuffer_Info -> RAX=fb_base, RDX=stride
	emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Get_Framebuffer_Info))
	emit_syscall(&e)
	// Save fb_base in rbx (48 89 C3)
	emit_bytes(&e, 0x48, 0x89, 0xC3)

	// 2. mov dword [rbx], 0xFF112233 (C7 03 imm32)
	emit_bytes(&e, 0xC7, 0x03)
	emit_u32_le(&e, 0xFF112233)

	// 3. mov dword [rbx + 4], 0xFF445566 (C7 43 04 imm32)
	emit_bytes(&e, 0xC7, 0x43, 0x04)
	emit_u32_le(&e, 0xFF445566)

	// 4. Write_Serial_Slice(VM_DATA_BASE, len("MODUS:"))
	emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Write_Serial_Slice))
	emit_mov_rdi_imm64(&e, VM_DATA_BASE)
	emit_mov_rsi_imm64(&e, u64(len(banner)))
	emit_syscall(&e)

	// 5. Read_Key_Event -> RDI = key_code ('A')
	emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Read_Key_Event))
	emit_syscall(&e)

	// 6. Write_Serial_Byte(RDI)
	emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Write_Serial_Byte))
	emit_syscall(&e)

	// 7. Read_Pointer_Event -> RDI = x (5), RSI = y (3)
	emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Read_Pointer_Event))
	emit_syscall(&e)

	// 8. shl rsi, 8 (48 C1 E6 08); shl rdi, 2 (48 C1 E7 02); add rsi, rdi (48 01 FE); add rbx, rsi (48 01 F3)
	emit_bytes(&e, 0x48, 0xC1, 0xE6, 0x08)
	emit_bytes(&e, 0x48, 0xC1, 0xE7, 0x02)
	emit_bytes(&e, 0x48, 0x01, 0xFE)
	emit_bytes(&e, 0x48, 0x01, 0xF3)
	// mov dword [rbx], 0xFFAABBCC (C7 03 imm32)
	emit_bytes(&e, 0xC7, 0x03)
	emit_u32_le(&e, 0xFFAABBCC)

	// 9. Halt
	emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Halt))
	emit_syscall(&e)

	testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(e.bytes[:e.count]), u32(e.count)), u32(Vm_Call_Status.Ok))

	// Step with tight 3-instruction budget first to verify incremental stepping without halting prematurely.
	testing.expect_value(t, modus_vm_step_budget(3), u32(Vm_Call_Status.Ok))
	testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Running))
	testing.expect_value(t, modus_vm_steps_executed(), u64(3))

	// Step remaining instructions until Halt.
	testing.expect_value(t, modus_vm_step_budget(100), u32(Vm_Call_Status.Ok))
	testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Halted))

	// Read back exact RGBA pixels through modus_vm_framebuffer_ptr / modus_vm_framebuffer_bytes.
	fb_ptr := ([^]u8)(modus_vm_framebuffer_ptr())
	fb_slice := fb_ptr[:modus_vm_framebuffer_bytes()]
	testing.expect_value(t, byte_order.read_u32_little_endian(fb_slice, 0), u32(0xFF112233))
	testing.expect_value(t, byte_order.read_u32_little_endian(fb_slice, 4), u32(0xFF445566))
	pointer_pixel_offset := (3 * 64 + 5) * 4
	testing.expect_value(t, byte_order.read_u32_little_endian(fb_slice, pointer_pixel_offset), u32(0xFFAABBCC))

	// Drain serial output ring via modus_vm_pop_serial and confirm exact "MODUS:A".
	expected_serial := "MODUS:A"
	testing.expect_value(t, modus_vm_serial_available(), u32(len(expected_serial)))
	for i in 0 ..< len(expected_serial) {
		ch := modus_vm_pop_serial()
		testing.expect_value(t, ch, i32(expected_serial[i]))
	}
	testing.expect_value(t, modus_vm_pop_serial(), i32(-1))
	testing.expect_value(t, modus_vm_serial_available(), u32(0))
}

@(test)
test_wasm_exports_ring_capacity_and_mmu_fault_isolation :: proc(t: ^testing.T) {
	sync.mutex_guard(&vm_export_test_mutex)
	// Small 32x16 framebuffer = 2048 bytes -> occupies exactly 1 four-KiB page at 0x100000.
	testing.expect_value(t, modus_vm_init(32, 16), u32(Vm_Call_Status.Ok))

	// Fill keyboard and pointer rings to exact capacity; next push must fail with Ring_Full.
	for i in u32(0) ..< VM_INPUT_RING_CAPACITY {
		testing.expect_value(t, modus_vm_push_key(65 + (i % 26), u32(Vm_Key_Action.Press), 0), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Move), i % 32, i % 16, 0), u32(Vm_Call_Status.Ok))
	}
	testing.expect_value(t, modus_vm_push_key(65, u32(Vm_Key_Action.Press), 0), u32(Vm_Call_Status.Ring_Full))
	testing.expect_value(t, modus_vm_push_pointer(u32(Vm_Pointer_Event_Kind.Move), 0, 0, 0), u32(Vm_Call_Status.Ring_Full))
	testing.expect_value(t, vm_instance.key_dropped, u32(1))
	testing.expect_value(t, vm_instance.pointer_dropped, u32(1))

	// Adversarial guest program 1: attempt to write past the single active framebuffer page (0x101000) -> Page_Fault.
	{
		e: Code_Emitter
		emit_mov_rbx_imm64(&e, VM_FRAMEBUFFER_BASE + software.PAGE_SIZE)
		emit_bytes(&e, 0xC7, 0x03)
		emit_u32_le(&e, 0xDEADBEEF)
		testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(e.bytes[:e.count]), u32(e.count)), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_step_budget(10), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Faulted_Page_Fault))
		testing.expect_value(t, modus_vm_fault_address(), VM_FRAMEBUFFER_BASE + software.PAGE_SIZE)
	}

	// Adversarial guest program 2: attempt to overwrite executable code (W^X violation at VM_CODE_BASE) -> Page_Fault.
	{
		testing.expect_value(t, modus_vm_init(32, 16), u32(Vm_Call_Status.Ok))
		e: Code_Emitter
		emit_mov_rbx_imm64(&e, VM_CODE_BASE)
		emit_bytes(&e, 0xC7, 0x03)
		emit_u32_le(&e, 0x90909090)
		testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(e.bytes[:e.count]), u32(e.count)), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_step_budget(10), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Faulted_Page_Fault))
		testing.expect_value(t, modus_vm_fault_address(), VM_CODE_BASE)
	}

	// Adversarial guest program 3: unknown syscall number -> Faulted_Invalid_Syscall.
	{
		testing.expect_value(t, modus_vm_init(32, 16), u32(Vm_Call_Status.Ok))
		e: Code_Emitter
		emit_mov_rax_imm64(&e, 999)
		emit_syscall(&e)
		testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(e.bytes[:e.count]), u32(e.count)), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_step_budget(10), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Faulted_Invalid_Syscall))
		// Stepping again after fault does not advance steps_executed.
		steps_before := modus_vm_steps_executed()
		testing.expect_value(t, modus_vm_step_budget(10), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_steps_executed(), steps_before)
	}

	// Adversarial guest program 4: Write_Serial_Slice with unmapped pointer -> Faulted_Page_Fault, zero bytes emitted.
	{
		testing.expect_value(t, modus_vm_init(32, 16), u32(Vm_Call_Status.Ok))
		e: Code_Emitter
		emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Write_Serial_Slice))
		emit_mov_rdi_imm64(&e, 0x0000_0000_0050_0000)
		emit_mov_rsi_imm64(&e, 4)
		emit_syscall(&e)
		testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), raw_data(e.bytes[:e.count]), u32(e.count)), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_step_budget(10), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Faulted_Page_Fault))
		testing.expect_value(t, modus_vm_pop_serial(), i32(-1))
	}

	// Staging buffer path: host writes code into staging_buffer, then calls modus_vm_load_bytes from staging_ptr.
	{
		testing.expect_value(t, modus_vm_init(16, 16), u32(Vm_Call_Status.Ok))
		e: Code_Emitter
		emit_mov_rax_imm64(&e, u64(Vm_Syscall_Number.Halt))
		emit_syscall(&e)
		staging := ([^]u8)(modus_vm_staging_ptr())
		for i in 0 ..< e.count {
			staging[i] = e.bytes[i]
		}
		testing.expect_value(t, modus_vm_load_bytes(u32(VM_CODE_BASE), staging, u32(e.count)), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_step_budget(16), u32(Vm_Call_Status.Ok))
		testing.expect_value(t, modus_vm_state_word(), u32(Vm_Run_State.Halted))
	}
}
