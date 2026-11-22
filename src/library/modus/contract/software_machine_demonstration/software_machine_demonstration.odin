// Freestanding WebAssembly export bridge of the demonstration page of the
// software processor (src/md/features/browser_machine.md, "State"). It is
// a package of its own, so a build that imports software_machine, as the
// kernel for WebAssembly does, exports none of its procedures.
//
// Exposes a strict, zero-allocation, C-ABI surface compiling cleanly under
// freestanding_amd64_sysv, freestanding_wasm32, and freestanding_wasm64p32:
//   - static 2 MiB guest physical RAM with four-level x86-64 page tables;
//   - configurable bounded virtual RGBA framebuffer (up to 640x400) mapped
//     writable non-executable inside guest virtual memory;
//   - bounded circular keyboard and pointer input rings and serial output ring
//     that refuse overflow without silent drops;
//   - strict border validation on every transport word, memory offset, step
//     budget, and device coordinate.
package software_machine_demonstration

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import software "modus:contract/software_machine"

// Static memory geometry and bounded device capacities.
VM_MAX_FRAMEBUFFER_WIDTH :: u32(640)
VM_MAX_FRAMEBUFFER_HEIGHT :: u32(400)
VM_PIXEL_BYTES :: u32(4)
VM_MAX_FRAMEBUFFER_BYTES :: VM_MAX_FRAMEBUFFER_WIDTH * VM_MAX_FRAMEBUFFER_HEIGHT * VM_PIXEL_BYTES

// Fixed 2 MiB physical guest RAM (512 four-KiB pages mapped by one page table).
VM_GUEST_RAM_BYTES :: u32(2 * 1024 * 1024)
VM_PML4_OFFSET :: u64(0x0000_1000)
VM_PDPT_OFFSET :: u64(0x0000_2000)
VM_PD_OFFSET :: u64(0x0000_3000)
VM_PT_OFFSET :: u64(0x0000_4000)

// Guest virtual and physical regions (identity-mapped with strict W^X permissions).
VM_CODE_BASE :: u64(0x0001_0000)
VM_CODE_BYTES :: u32(64 * 1024)
VM_DATA_BASE :: u64(0x0002_0000)
VM_DATA_BYTES :: u32(64 * 1024)
VM_STACK_BASE :: u64(0x0003_0000)
VM_STACK_BYTES :: u32(64 * 1024)
VM_STACK_INITIAL_RSP :: u64(0x0003_FFF0)
VM_FRAMEBUFFER_BASE :: u64(0x0010_0000)

// Dedicated static staging buffer for host-to-guest loads across WebAssembly linear memory.
VM_STAGING_BYTES :: u32(64 * 1024)

// Execution and ring capacity limits.
VM_MAX_STEP_BUDGET :: u32(1_000_000)
VM_INPUT_RING_CAPACITY :: u32(128)
VM_SERIAL_RING_CAPACITY :: u32(4096)
VM_MAX_KEY_CODE :: u32(0xFFFF)
VM_KEY_MODIFIER_VALID_MASK :: u32(0x0F)
VM_POINTER_BUTTON_VALID_MASK :: u32(0x1F)

// Status codes returned by the exported C-ABI calls.
Vm_Call_Status :: enum u32 {
	Ok                       = 0,
	Not_Initialized          = 1,
	Invalid_Framebuffer_Size = 2,
	Load_Out_Of_Bounds       = 3,
	Load_Empty_Or_Null       = 4,
	Invalid_Step_Budget      = 5,
	Invalid_Key_Event        = 6,
	Invalid_Pointer_Event    = 7,
	Ring_Full                = 8,
	Invalid_Entry_Address    = 9,
}

// Machine lifecycle and stop state returned by `modus_vm_state_word`.
Vm_Run_State :: enum u32 {
	Uninitialized              = 0,
	Ready                      = 1,
	Running                    = 2,
	Halted                     = 3,
	Faulted_Page_Fault         = 4,
	Faulted_General_Protection = 5,
	Faulted_Invalid_Opcode     = 6,
	Faulted_Divide_Error       = 7,
	Faulted_Invalid_Syscall    = 8,
	Breakpoint                 = 9,
}

// Closed set of keyboard event actions accepted at the browser border.
Vm_Key_Action :: enum u32 {
	Press   = 1,
	Release = 2,
	Repeat  = 3,
}

// Closed set of pointer event kinds accepted at the browser border.
Vm_Pointer_Event_Kind :: enum u32 {
	Move        = 1,
	Button_Down = 2,
	Button_Up   = 3,
	Wheel       = 4,
}

// Closed set of guest syscall numbers serviced by the browser machine loop.
Vm_Syscall_Number :: enum u64 {
	Write_Serial_Byte    = 1,
	Write_Serial_Slice   = 2,
	Read_Key_Event       = 3,
	Read_Pointer_Event   = 4,
	Get_Framebuffer_Info = 5,
	Halt                 = 6,
}

// One validated keyboard event stored in the input ring.
Vm_Key_Event :: struct {
	key_code:  u32,
	action:    Vm_Key_Action,
	modifiers: u32,
}

// One validated pointer event stored in the input ring.
Vm_Pointer_Event :: struct {
	kind:    Vm_Pointer_Event_Kind,
	x:       u32,
	y:       u32,
	buttons: u32,
}

// Static state of the single-processor browser machine instance.
// guest_ram and staging_buffer sit first with multiples of 8 bytes so both
// are 8-byte aligned for atomic page-table updates.
Browser_Vm_State :: struct #align(8) {
	guest_ram:       [VM_GUEST_RAM_BYTES]u8,
	staging_buffer:  [VM_STAGING_BYTES]u8,
	initialized:     bool,
	run_state:       Vm_Run_State,
	fb_width:        u32,
	fb_height:       u32,
	fb_bytes:        u32,
	cpu:             software.Processor_State,
	key_ring:        [VM_INPUT_RING_CAPACITY]Vm_Key_Event,
	key_head:        u32,
	key_tail:        u32,
	key_count:       u32,
	key_dropped:     u32,
	pointer_ring:    [VM_INPUT_RING_CAPACITY]Vm_Pointer_Event,
	pointer_head:    u32,
	pointer_tail:    u32,
	pointer_count:   u32,
	pointer_dropped: u32,
	serial_ring:     [VM_SERIAL_RING_CAPACITY]u8,
	serial_head:     u32,
	serial_tail:     u32,
	serial_count:    u32,
	serial_dropped:  u32,
}

@(private = "package")
vm_instance: Browser_Vm_State

// Border decoders converting raw transport words into closed enums.

vm_call_status_from_word :: proc "contextless" (word: u64) -> (status: Vm_Call_Status, ok: bool) {
	return enum_word.member_of_word(Vm_Call_Status, word)
}

vm_run_state_from_word :: proc "contextless" (word: u64) -> (state: Vm_Run_State, ok: bool) {
	return enum_word.member_of_word(Vm_Run_State, word)
}

vm_key_action_from_word :: proc "contextless" (word: u64) -> (action: Vm_Key_Action, ok: bool) {
	return enum_word.member_of_word(Vm_Key_Action, word)
}

vm_pointer_event_kind_from_word :: proc "contextless" (word: u64) -> (kind: Vm_Pointer_Event_Kind, ok: bool) {
	return enum_word.member_of_word(Vm_Pointer_Event_Kind, word)
}

vm_syscall_number_from_word :: proc "contextless" (word: u64) -> (number: Vm_Syscall_Number, ok: bool) {
	return enum_word.member_of_word(Vm_Syscall_Number, word)
}

// vm_zero_bytes clears a byte slice without calling a host runtime routine.
@(private = "file")
vm_zero_bytes :: proc "contextless" (target: []u8) {
	for index in 0 ..< len(target) {
		target[index] = 0
	}
}

// vm_map_identity_range writes 4 KiB page-table entries inside the single page
// table covering the 2 MiB guest RAM with the requested architectural flags.
@(private = "file")
vm_map_identity_range :: proc "contextless" (ram: []u8, start_address: u64, byte_count: u64, leaf_flags: u64) {
	if byte_count == 0 {
		return
	}
	page_count := (byte_count + software.PAGE_SIZE - 1) / software.PAGE_SIZE
	for page_index in u64(0) ..< page_count {
		address := start_address + page_index * software.PAGE_SIZE
		pt_index := (address >> 12) & software.PAGE_TABLE_INDEX_MASK
		entry_offset := int(VM_PT_OFFSET + pt_index * 8)
		byte_order.write_u64_little_endian(ram, entry_offset, (address & software.PAGE_ADDRESS_MASK) | leaf_flags)
	}
}

// vm_serial_push_byte appends one byte to the serial output ring without
// silently dropping bytes: overflow is counted explicitly and reported.
@(private = "file")
vm_serial_push_byte :: proc "contextless" (vm: ^Browser_Vm_State, value: u8) -> bool {
	if vm.serial_count >= VM_SERIAL_RING_CAPACITY {
		vm.serial_dropped += 1
		return false
	}
	vm.serial_ring[vm.serial_tail] = value
	vm.serial_tail = (vm.serial_tail + 1) % VM_SERIAL_RING_CAPACITY
	vm.serial_count += 1
	return true
}

// vm_handle_syscall dispatches one validated guest syscall without bypassing
// the Software MMU or device ring capacities.
@(private = "file")
vm_handle_syscall :: proc "contextless" (vm: ^Browser_Vm_State) {
	raw_number := vm.cpu.registers[int(software.General_Register.Rax)]
	syscall_number, valid := vm_syscall_number_from_word(raw_number)
	if !valid {
		vm.cpu.registers[int(software.General_Register.Rax)] = max(u64)
		vm.run_state = .Faulted_Invalid_Syscall
		return
	}

	switch syscall_number {
	case .Write_Serial_Byte:
		byte_val := u8(vm.cpu.registers[int(software.General_Register.Rdi)] & 0xFF)
		pushed := vm_serial_push_byte(vm, byte_val)
		vm.cpu.registers[int(software.General_Register.Rax)] = 0 if pushed else 1

	case .Write_Serial_Slice:
		guest_ptr := vm.cpu.registers[int(software.General_Register.Rdi)]
		requested_len := vm.cpu.registers[int(software.General_Register.Rsi)]
		if requested_len > u64(VM_SERIAL_RING_CAPACITY) {
			vm.cpu.registers[int(software.General_Register.Rax)] = max(u64)
			vm.run_state = .Faulted_Invalid_Syscall
			return
		}
		if requested_len > 0 && guest_ptr > max(u64) - (requested_len - 1) {
			vm.cpu.fault_address = guest_ptr
			vm.cpu.fault_error_code = 0
			vm.run_state = .Faulted_General_Protection
			return
		}
		written := u64(0)
		for offset in u64(0) ..< requested_len {
			byte_val, read_res := software.mmu_read_u8(&vm.cpu.tlb, vm.guest_ram[:], vm.cpu.cr3, guest_ptr + offset, .User)
			if read_res.status != .Ok {
				vm.cpu.fault_address = read_res.fault_address
				vm.cpu.fault_error_code = read_res.fault_error_code
				vm.run_state = .Faulted_Page_Fault if read_res.status == .Page_Fault else .Faulted_General_Protection
				return
			}
			if !vm_serial_push_byte(vm, byte_val) {
				break
			}
			written += 1
		}
		vm.cpu.registers[int(software.General_Register.Rax)] = written

	case .Read_Key_Event:
		if vm.key_count == 0 {
			vm.cpu.registers[int(software.General_Register.Rax)] = 0
			vm.cpu.registers[int(software.General_Register.Rdi)] = 0
			vm.cpu.registers[int(software.General_Register.Rsi)] = 0
			vm.cpu.registers[int(software.General_Register.Rdx)] = 0
		} else {
			event := vm.key_ring[vm.key_head]
			vm.key_head = (vm.key_head + 1) % VM_INPUT_RING_CAPACITY
			vm.key_count -= 1
			vm.cpu.registers[int(software.General_Register.Rax)] = 1
			vm.cpu.registers[int(software.General_Register.Rdi)] = u64(event.key_code)
			vm.cpu.registers[int(software.General_Register.Rsi)] = u64(event.action)
			vm.cpu.registers[int(software.General_Register.Rdx)] = u64(event.modifiers)
		}

	case .Read_Pointer_Event:
		if vm.pointer_count == 0 {
			vm.cpu.registers[int(software.General_Register.Rax)] = 0
			vm.cpu.registers[int(software.General_Register.Rdi)] = 0
			vm.cpu.registers[int(software.General_Register.Rsi)] = 0
			vm.cpu.registers[int(software.General_Register.Rdx)] = 0
		} else {
			event := vm.pointer_ring[vm.pointer_head]
			vm.pointer_head = (vm.pointer_head + 1) % VM_INPUT_RING_CAPACITY
			vm.pointer_count -= 1
			vm.cpu.registers[int(software.General_Register.Rax)] = 1
			vm.cpu.registers[int(software.General_Register.Rdi)] = u64(event.x)
			vm.cpu.registers[int(software.General_Register.Rsi)] = u64(event.y)
			vm.cpu.registers[int(software.General_Register.Rdx)] = u64(event.buttons) | (u64(event.kind) << 32)
		}

	case .Get_Framebuffer_Info:
		vm.cpu.registers[int(software.General_Register.Rax)] = VM_FRAMEBUFFER_BASE
		vm.cpu.registers[int(software.General_Register.Rdi)] = u64(vm.fb_width)
		vm.cpu.registers[int(software.General_Register.Rsi)] = u64(vm.fb_height)
		vm.cpu.registers[int(software.General_Register.Rdx)] = u64(vm.fb_width * VM_PIXEL_BYTES)

	case .Halt:
		vm.cpu.outcome = .Halted
		vm.run_state = .Halted
	}
}

// modus_vm_init initializes the browser machine with a bounded framebuffer
// size, constructs fresh 4-level x86-64 page tables with W^X enforcement,
// resets all device rings, and readies the software processor at VM_CODE_BASE.
@(export)
modus_vm_init :: proc "c" (framebuffer_width: u32, framebuffer_height: u32) -> u32 {
	if framebuffer_width == 0 || framebuffer_width > VM_MAX_FRAMEBUFFER_WIDTH ||
		framebuffer_height == 0 || framebuffer_height > VM_MAX_FRAMEBUFFER_HEIGHT {
		return u32(Vm_Call_Status.Invalid_Framebuffer_Size)
	}

	vm := &vm_instance
	vm.initialized = false
	vm.run_state = .Uninitialized
	vm.fb_width = framebuffer_width
	vm.fb_height = framebuffer_height
	vm.fb_bytes = framebuffer_width * framebuffer_height * VM_PIXEL_BYTES
	vm.key_head = 0
	vm.key_tail = 0
	vm.key_count = 0
	vm.key_dropped = 0
	vm.pointer_head = 0
	vm.pointer_tail = 0
	vm.pointer_count = 0
	vm.pointer_dropped = 0
	vm.serial_head = 0
	vm.serial_tail = 0
	vm.serial_count = 0
	vm.serial_dropped = 0

	vm_zero_bytes(vm.guest_ram[:])
	vm_zero_bytes(vm.staging_buffer[:])

	// Build 4-level x86-64 page tables covering the 2 MiB guest RAM.
	upper_flags := software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_USER
	byte_order.write_u64_little_endian(vm.guest_ram[:], int(VM_PML4_OFFSET), VM_PDPT_OFFSET | upper_flags)
	byte_order.write_u64_little_endian(vm.guest_ram[:], int(VM_PDPT_OFFSET), VM_PD_OFFSET | upper_flags)
	byte_order.write_u64_little_endian(vm.guest_ram[:], int(VM_PD_OFFSET), VM_PT_OFFSET | upper_flags)

	// Map code (RX User), data (RW NX User), stack (RW NX User), and active framebuffer pages (RW NX User).
	vm_map_identity_range(vm.guest_ram[:], VM_CODE_BASE, u64(VM_CODE_BYTES), software.PAGE_PRESENT | software.PAGE_USER)
	vm_map_identity_range(vm.guest_ram[:], VM_DATA_BASE, u64(VM_DATA_BYTES), software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_USER | software.PAGE_NO_EXECUTE)
	vm_map_identity_range(vm.guest_ram[:], VM_STACK_BASE, u64(VM_STACK_BYTES), software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_USER | software.PAGE_NO_EXECUTE)
	vm_map_identity_range(vm.guest_ram[:], VM_FRAMEBUFFER_BASE, u64(vm.fb_bytes), software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_USER | software.PAGE_NO_EXECUTE)

	software.processor_init(&vm.cpu, VM_PML4_OFFSET, VM_CODE_BASE, VM_STACK_INITIAL_RSP)
	vm.initialized = true
	vm.run_state = .Ready
	return u32(Vm_Call_Status.Ok)
}

// modus_vm_load_bytes copies a bounded guest program or data slice into guest
// RAM at `guest_offset` (refusing page-table memory below VM_CODE_BASE and
// any out-of-bounds or empty load) and invalidates the software TLB.
@(export)
modus_vm_load_bytes :: proc "c" (guest_offset: u32, source_ptr: [^]u8, byte_count: u32) -> u32 {
	vm := &vm_instance
	if !vm.initialized {
		return u32(Vm_Call_Status.Not_Initialized)
	}
	if source_ptr == nil || byte_count == 0 {
		return u32(Vm_Call_Status.Load_Empty_Or_Null)
	}
	offset_u64 := u64(guest_offset)
	count_u64 := u64(byte_count)
	ram_limit := u64(VM_GUEST_RAM_BYTES)
	if offset_u64 < VM_CODE_BASE || offset_u64 > ram_limit || count_u64 > ram_limit - offset_u64 {
		return u32(Vm_Call_Status.Load_Out_Of_Bounds)
	}

	destination_start := int(guest_offset)
	for index in 0 ..< int(byte_count) {
		vm.guest_ram[destination_start + index] = source_ptr[index]
	}
	software.tlb_flush_all(&vm.cpu.tlb)
	return u32(Vm_Call_Status.Ok)
}

// modus_vm_set_entry moves the processor instruction pointer to a validated
// address inside the executable guest code segment.
@(export)
modus_vm_set_entry :: proc "c" (entry_rip: u64) -> u32 {
	vm := &vm_instance
	if !vm.initialized {
		return u32(Vm_Call_Status.Not_Initialized)
	}
	if entry_rip < VM_CODE_BASE || entry_rip >= VM_CODE_BASE + u64(VM_CODE_BYTES) {
		return u32(Vm_Call_Status.Invalid_Entry_Address)
	}
	vm.cpu.rip = entry_rip
	vm.run_state = .Ready
	return u32(Vm_Call_Status.Ok)
}

// modus_vm_step_budget executes at most `max_steps` guest instructions,
// servicing virtual device syscalls and stopping immediately on halt, fault,
// or breakpoint. Refuses zero or oversized step budgets without mutating state.
@(export)
modus_vm_step_budget :: proc "c" (max_steps: u32) -> u32 {
	vm := &vm_instance
	if !vm.initialized {
		return u32(Vm_Call_Status.Not_Initialized)
	}
	if max_steps == 0 || max_steps > VM_MAX_STEP_BUDGET {
		return u32(Vm_Call_Status.Invalid_Step_Budget)
	}

	switch vm.run_state {
	case .Uninitialized:
		return u32(Vm_Call_Status.Not_Initialized)
	case .Halted, .Faulted_Page_Fault, .Faulted_General_Protection, .Faulted_Invalid_Opcode, .Faulted_Divide_Error, .Faulted_Invalid_Syscall:
		return u32(Vm_Call_Status.Ok)
	case .Ready, .Running, .Breakpoint:
		vm.run_state = .Running
	}

	for _ in u32(0) ..< max_steps {
		outcome := software.processor_step(&vm.cpu, vm.guest_ram[:])
		switch outcome {
		case .Running:
			continue
		case .Syscall:
			vm_handle_syscall(vm)
			if vm.run_state != .Running {
				return u32(Vm_Call_Status.Ok)
			}
		case .Breakpoint:
			vm.run_state = .Breakpoint
			return u32(Vm_Call_Status.Ok)
		case .Halted:
			vm.run_state = .Halted
			return u32(Vm_Call_Status.Ok)
		case .Page_Fault:
			vm.run_state = .Faulted_Page_Fault
			return u32(Vm_Call_Status.Ok)
		case .General_Protection:
			vm.run_state = .Faulted_General_Protection
			return u32(Vm_Call_Status.Ok)
		case .Invalid_Opcode:
			vm.run_state = .Faulted_Invalid_Opcode
			return u32(Vm_Call_Status.Ok)
		case .Divide_Error, .Simd_Floating_Point:
			vm.run_state = .Faulted_Divide_Error
			return u32(Vm_Call_Status.Ok)
		case .Step_Budget_Exhausted:
			return u32(Vm_Call_Status.Ok)
		}
	}
	return u32(Vm_Call_Status.Ok)
}

// modus_vm_framebuffer_ptr returns the linear-memory address of the active
// virtual RGBA framebuffer, or 0 before initialization.
@(export)
modus_vm_framebuffer_ptr :: proc "c" () -> uintptr {
	if !vm_instance.initialized {
		return 0
	}
	return uintptr(&vm_instance.guest_ram[int(VM_FRAMEBUFFER_BASE)])
}

// modus_vm_framebuffer_bytes returns the byte size of the active framebuffer,
// or 0 before initialization.
@(export)
modus_vm_framebuffer_bytes :: proc "c" () -> u32 {
	if !vm_instance.initialized {
		return 0
	}
	return vm_instance.fb_bytes
}

// modus_vm_framebuffer_width returns the active framebuffer width in pixels.
@(export)
modus_vm_framebuffer_width :: proc "c" () -> u32 {
	if !vm_instance.initialized {
		return 0
	}
	return vm_instance.fb_width
}

// modus_vm_framebuffer_height returns the active framebuffer height in pixels.
@(export)
modus_vm_framebuffer_height :: proc "c" () -> u32 {
	if !vm_instance.initialized {
		return 0
	}
	return vm_instance.fb_height
}

// modus_vm_staging_ptr returns the linear-memory address of the 64 KiB static
// staging buffer for WebAssembly host-to-guest byte transfers.
@(export)
modus_vm_staging_ptr :: proc "c" () -> uintptr {
	return uintptr(&vm_instance.staging_buffer[0])
}

// modus_vm_staging_bytes returns the capacity in bytes of the static staging buffer.
@(export)
modus_vm_staging_bytes :: proc "c" () -> u32 {
	return VM_STAGING_BYTES
}

// modus_vm_push_key validates and enqueues one keyboard event into the virtual
// keyboard input ring, refusing invalid codes, unknown actions, unknown
// modifier bits, or overflow.
@(export)
modus_vm_push_key :: proc "c" (key_code: u32, action_word: u32, modifiers_word: u32) -> u32 {
	vm := &vm_instance
	if !vm.initialized {
		return u32(Vm_Call_Status.Not_Initialized)
	}
	action, action_ok := vm_key_action_from_word(u64(action_word))
	if !action_ok || key_code == 0 || key_code > VM_MAX_KEY_CODE || (modifiers_word & ~VM_KEY_MODIFIER_VALID_MASK) != 0 {
		return u32(Vm_Call_Status.Invalid_Key_Event)
	}
	if vm.key_count >= VM_INPUT_RING_CAPACITY {
		vm.key_dropped += 1
		return u32(Vm_Call_Status.Ring_Full)
	}
	vm.key_ring[vm.key_tail] = Vm_Key_Event {
		key_code  = key_code,
		action    = action,
		modifiers = modifiers_word,
	}
	vm.key_tail = (vm.key_tail + 1) % VM_INPUT_RING_CAPACITY
	vm.key_count += 1
	return u32(Vm_Call_Status.Ok)
}

// modus_vm_push_pointer validates and enqueues one pointer event into the
// virtual pointer input ring, refusing unknown event kinds, out-of-bounds
// coordinates, unknown button bits, or overflow.
@(export)
modus_vm_push_pointer :: proc "c" (event_kind_word: u32, x: u32, y: u32, buttons_word: u32) -> u32 {
	vm := &vm_instance
	if !vm.initialized {
		return u32(Vm_Call_Status.Not_Initialized)
	}
	kind, kind_ok := vm_pointer_event_kind_from_word(u64(event_kind_word))
	if !kind_ok || x >= vm.fb_width || y >= vm.fb_height || (buttons_word & ~VM_POINTER_BUTTON_VALID_MASK) != 0 {
		return u32(Vm_Call_Status.Invalid_Pointer_Event)
	}
	if vm.pointer_count >= VM_INPUT_RING_CAPACITY {
		vm.pointer_dropped += 1
		return u32(Vm_Call_Status.Ring_Full)
	}
	vm.pointer_ring[vm.pointer_tail] = Vm_Pointer_Event {
		kind    = kind,
		x       = x,
		y       = y,
		buttons = buttons_word,
	}
	vm.pointer_tail = (vm.pointer_tail + 1) % VM_INPUT_RING_CAPACITY
	vm.pointer_count += 1
	return u32(Vm_Call_Status.Ok)
}

// modus_vm_pop_serial dequeues one byte (0..255) from the serial console output
// ring, or returns -1 when the machine is uninitialized or the ring is empty.
@(export)
modus_vm_pop_serial :: proc "c" () -> i32 {
	vm := &vm_instance
	if !vm.initialized || vm.serial_count == 0 {
		return -1
	}
	value := vm.serial_ring[vm.serial_head]
	vm.serial_head = (vm.serial_head + 1) % VM_SERIAL_RING_CAPACITY
	vm.serial_count -= 1
	return i32(value)
}

// modus_vm_serial_available returns the number of unread bytes waiting in the
// serial output ring.
@(export)
modus_vm_serial_available :: proc "c" () -> u32 {
	if !vm_instance.initialized {
		return 0
	}
	return vm_instance.serial_count
}

// modus_vm_state_word returns the current Vm_Run_State word of the machine.
@(export)
modus_vm_state_word :: proc "c" () -> u32 {
	return u32(vm_instance.run_state)
}

// modus_vm_steps_executed returns the total x86-64 instructions executed since
// the last modus_vm_init call.
@(export)
modus_vm_steps_executed :: proc "c" () -> u64 {
	if !vm_instance.initialized {
		return 0
	}
	return vm_instance.cpu.steps_executed
}

// modus_vm_fault_address returns the last faulting guest virtual address.
@(export)
modus_vm_fault_address :: proc "c" () -> u64 {
	if !vm_instance.initialized {
		return 0
	}
	return vm_instance.cpu.fault_address
}
