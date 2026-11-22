// Pure guest builder sandbox controller (Guest_Sandbox_Runner).
//
// Enforces every determinism and isolation invariant of a guest build without
// performing any kernel operation or dynamic allocation:
//   - validates Guest_Build_Spec before execution (refusing network, real
//     clock, writable inputs, zero hashes, and out-of-bounds memory/output);
//   - enforces read-only protection on Root_Image and Inputs_Read_Only disks,
//     returning Io_Error and recording a sandbox violation on any write;
//   - refuses every network device request or network port access;
//   - freezes RTC and 64-bit clock reads to spec.frozen_epoch_seconds;
//   - answers CPUID deterministically with no host hardware leakage;
//   - extracts and hashes the output disk only when the guest cleanly exits
//     with exit code 0 and zero sandbox violations.
package guest_builder

import "modus:contract/blake3"
import op "modus:contract/operation"

// Bounded capture buffer for guest diagnostic serial output (never parsed as
// commands and never included in the output tree hash).
MAX_CONSOLE_CAPTURE_BYTES :: 1024

// Maximum UTC year representable in legacy 4-digit BCD CMOS/RTC registers.
RTC_MAX_EPOCH_SECONDS :: u64(253_402_300_799) // 9999-12-31T23:59:59Z

// Pure state machine driving one sandboxed guest build.
Guest_Sandbox_Runner :: struct {
	spec:                     Guest_Build_Spec,
	state:                    Guest_Build_State,
	refusal:                  Guest_Builder_Refusal,
	sandbox_violations:       u64,
	last_violation:           Sandbox_Violation_Kind,
	guest_exits_handled:      u64,
	guest_exit_code:          u32,
	guest_exited:             bool,
	rtc_selected_register:    u8,
	block_selected_disk_word: u32,
	block_offset:             u64,
	block_length:             u32,
	block_last_status:        Guest_Block_Status,
	root_disk:                []u8,
	input_disk:               []u8,
	output_disk:              []u8,
	console_length:           u32,
	console_buffer:           [MAX_CONSOLE_CAPTURE_BYTES]u8,
	output_tree_hash:         blake3.Hash,
	output_tree_bytes_written: int,
}

// Frozen UTC calendar fields derived purely from frozen_epoch_seconds.
Frozen_Utc_Date :: struct {
	year:    u16,
	month:   u8,
	day:     u8,
	weekday: u8,
	hour:    u8,
	minute:  u8,
	second:  u8,
}

// frozen_utc_date_from_epoch converts a Unix epoch timestamp in seconds into
// UTC calendar fields using pure integer arithmetic. Values past 9999-12-31
// clamp cleanly to 9999-12-31T23:59:59Z for legacy CMOS/RTC registers.
frozen_utc_date_from_epoch :: proc "contextless" (epoch_seconds: u64) -> Frozen_Utc_Date {
	clamped := min(epoch_seconds, RTC_MAX_EPOCH_SECONDS)
	days := clamped / 86400
	seconds_of_day := clamped % 86400
	hour := u8(seconds_of_day / 3600)
	minute := u8((seconds_of_day % 3600) / 60)
	second := u8(seconds_of_day % 60)
	weekday := u8(((days + 4) % 7) + 1)

	z := i64(days) + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	day_of_era := u64(z - era * 146097)
	year_of_era := (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365
	year := i64(year_of_era) + era * 400
	day_of_year := day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
	month_part := (5 * day_of_year + 2) / 153
	day := u8(day_of_year - (153 * month_part + 2) / 5 + 1)
	month := u8(month_part < 10 ? month_part + 3 : month_part - 9)
	if month <= 2 {
		year += 1
	}

	return Frozen_Utc_Date {
		year    = u16(year),
		month   = month,
		day     = day,
		weekday = weekday,
		hour    = hour,
		minute  = minute,
		second  = second,
	}
}

// bcd_encode converts a value in 0 ..= 99 to binary-coded decimal for CMOS RTC.
@(private = "file")
bcd_encode :: proc "contextless" (value: u8) -> u8 {
	tens := (value / 10) % 10
	ones := value % 10
	return (tens << 4) | ones
}

// rtc_register_value returns the deterministic CMOS/RTC byte for register
// computed solely from frozen_epoch_seconds.
rtc_register_value :: proc "contextless" (epoch_seconds: u64, register: Guest_Rtc_Register) -> u8 {
	date := frozen_utc_date_from_epoch(epoch_seconds)
	switch register {
	case .Seconds:
		return bcd_encode(date.second)
	case .Minutes:
		return bcd_encode(date.minute)
	case .Hours:
		return bcd_encode(date.hour)
	case .Weekday:
		return bcd_encode(date.weekday)
	case .Day_Of_Month:
		return bcd_encode(date.day)
	case .Month:
		return bcd_encode(date.month)
	case .Year:
		return bcd_encode(u8(date.year % 100))
	case .Century:
		return bcd_encode(u8(date.year / 100))
	case .Status_A:
		// Update-in-progress bit clear so the guest never spins waiting for RTC.
		return 0x26
	case .Status_B:
		// 24-hour BCD mode, no periodic or alarm interrupts.
		return 0x02
	}
	return 0
}

// runner_prepare validates spec and attaches the read-only root/input disks
// and blank writable output disk. On any refusal, state becomes .Refused and
// no disk buffer is modified.
runner_prepare :: proc "contextless" (
	runner: ^Guest_Sandbox_Runner,
	spec: ^Guest_Build_Spec,
	root_disk: []u8,
	input_disk: []u8,
	output_disk: []u8,
) -> Guest_Builder_Refusal {
	if runner == nil {
		return .Zero_Kernel_Hash
	}
	runner^ = {}
	if spec_refusal := validate_build_spec(spec); spec_refusal != .None {
		runner.state = .Refused
		runner.refusal = spec_refusal
		return spec_refusal
	}
	if u64(len(output_disk)) < spec.output_size_bound {
		runner.state = .Refused
		runner.refusal = .Output_Too_Large
		return .Output_Too_Large
	}
	if len(input_disk) > 0 {
		if _, disk_refusal := validate_disk_image(input_disk, .Inputs_Read_Only, 0); disk_refusal != .None {
			runner.state = .Refused
			runner.refusal = disk_refusal
			return disk_refusal
		}
	}
	// Zero the blank writable output disk so no stale bytes leak into the build.
	for &value in output_disk[:spec.output_size_bound] {
		value = 0
	}
	runner.spec = spec^
	runner.state = .Prepared
	runner.refusal = .None
	runner.root_disk = root_disk
	runner.input_disk = input_disk
	runner.output_disk = output_disk[:spec.output_size_bound]
	return .None
}

// runner_start transitions a prepared sandbox runner into the Running state.
runner_start :: proc "contextless" (runner: ^Guest_Sandbox_Runner) -> Guest_Builder_Refusal {
	if runner == nil {
		return .Zero_Kernel_Hash
	}
	if runner.state != .Prepared {
		if runner.refusal != .None {
			return runner.refusal
		}
		return .Nonzero_Guest_Exit
	}
	runner.state = .Running
	return .None
}

// runner_record_violation records one sandbox violation and the refusal code.
@(private = "file")
runner_record_violation :: proc "contextless" (runner: ^Guest_Sandbox_Runner, kind: Sandbox_Violation_Kind, refusal: Guest_Builder_Refusal) {
	runner.sandbox_violations += 1
	runner.last_violation = kind
	if runner.refusal == .None {
		runner.refusal = refusal
	}
}

// runner_request_network_device always refuses any guest attempt to attach or
// probe a network device, recording a sandbox violation.
runner_request_network_device :: proc "contextless" (runner: ^Guest_Sandbox_Runner) -> Guest_Builder_Refusal {
	if runner == nil {
		return .Network_Forbidden
	}
	runner_record_violation(runner, .Network_Access_Attempt, .Network_Forbidden)
	return .Network_Forbidden
}

// runner_read_frozen_clock returns the build's frozen epoch timestamp in
// seconds. It never consults any wall clock.
runner_read_frozen_clock :: proc "contextless" (runner: ^Guest_Sandbox_Runner) -> u64 {
	if runner == nil {
		return 0
	}
	return runner.spec.frozen_epoch_seconds
}

// runner_handle_block_request executes one virtio-blk style block request
// against the selected guest disk while strictly enforcing read-only isolation
// on Root_Image and Inputs_Read_Only and the output size bound on Output_Writable.
runner_handle_block_request :: proc "contextless" (
	runner: ^Guest_Sandbox_Runner,
	role: Guest_Disk_Role,
	operation: Guest_Block_Operation,
	offset: u64,
	data: []u8,
) -> Guest_Block_Status {
	if runner == nil || runner.state != .Running {
		return .Io_Error
	}
	checked_role, role_ok := guest_disk_role_of_word(u64(role))
	if !role_ok {
		return .Unsupported
	}
	checked_op, op_ok := guest_block_operation_of_word(u64(operation))
	if !op_ok {
		return .Unsupported
	}

	switch checked_role {
	case .Root_Image, .Inputs_Read_Only:
		disk := checked_role == .Root_Image ? runner.root_disk : runner.input_disk
		switch checked_op {
		case .Read:
			if offset > u64(len(disk)) || u64(len(data)) > u64(len(disk)) - offset {
				return .Io_Error
			}
			copy(data, disk[offset:][:len(data)])
			return .Ok
		case .Write:
			// Read-only disk protection: never mutate a byte; record violation.
			runner_record_violation(runner, .Read_Only_Disk_Write, .Writable_Input_Forbidden)
			return .Io_Error
		case .Flush:
			return .Ok
		}
	case .Output_Writable:
		bound := runner.spec.output_size_bound
		switch checked_op {
		case .Read:
			if offset > bound || u64(len(data)) > bound - offset {
				return .Io_Error
			}
			copy(data, runner.output_disk[offset:][:len(data)])
			return .Ok
		case .Write:
			if offset > bound || u64(len(data)) > bound - offset {
				runner_record_violation(runner, .Output_Size_Exceeded, .Output_Too_Large)
				return .Io_Error
			}
			copy(runner.output_disk[offset:][:len(data)], data)
			return .Ok
		case .Flush:
			return .Ok
		}
	}
	return .Unsupported
}

// port_read_mask returns the bit mask corresponding to an x86 I/O port width.
@(private = "file")
port_read_mask :: proc "contextless" (size_bytes: u64) -> u64 {
	switch size_bytes {
	case 1:
		return 0xFF
	case 2:
		return 0xFFFF
	case 4:
		return 0xFFFF_FFFF
	}
	return 0xFF
}

// write_port_read_result updates the low bytes of rax for an x86 IN instruction
// while preserving the upper bytes for 1-byte and 2-byte reads, and zeroing the
// upper 32 bits for a 4-byte read.
@(private = "file")
write_port_read_result :: proc "contextless" (registers: ^op.Guest_Registers, size_bytes: u64, value: u64) {
	switch size_bytes {
	case 1:
		registers.rax = (registers.rax & ~u64(0xFF)) | (value & 0xFF)
	case 2:
		registers.rax = (registers.rax & ~u64(0xFFFF)) | (value & 0xFFFF)
	case 4:
		registers.rax = value & 0xFFFF_FFFF
	case:
		registers.rax = (registers.rax & ~u64(0xFF)) | (value & 0xFF)
	}
}

// runner_handle_cpuid fills deterministic virtual CPUID registers with zero
// host hardware feature leakage (RDRAND, RDSEED, and host brand strings absent).
@(private = "file")
runner_handle_cpuid :: proc "contextless" (registers: ^op.Guest_Registers) {
	leaf := u32(registers.rax)
	switch leaf {
	case 0:
		// Max standard leaf 1, vendor string "ModusVMM    ".
		registers.rax = 1
		registers.rbx = 0x7564_6F4D // "Modu"
		registers.rdx = 0x4D56_7373 // "ssVM"
		registers.rcx = 0x2020_204D // "M   "
	case 1:
		// Deterministic family/model and minimal SSE2 baseline; no RDRAND/TSC_DEADLINE.
		registers.rax = 0x0000_0663
		registers.rbx = 0x0001_0800
		registers.rcx = 0x8000_0000 // Hypervisor present bit only.
		registers.rdx = 0x0780_0101 // FPU, PAE, FXSR, SSE, SSE2.
	case:
		registers.rax = 0
		registers.rbx = 0
		registers.rcx = 0
		registers.rdx = 0
	}
}

// runner_report_violation records a sandbox violation that a device of the
// guest found, such as a write to a read-only disk through virtio-blk, and
// ends the run: the build is refused.
runner_report_violation :: proc "contextless" (runner: ^Guest_Sandbox_Runner, kind: Sandbox_Violation_Kind) {
	if runner == nil {
		return
	}
	refusal := Guest_Builder_Refusal.Network_Forbidden
	switch kind {
	case .Read_Only_Disk_Write:
		refusal = .Writable_Input_Forbidden
	case .Output_Size_Exceeded:
		refusal = .Output_Too_Large
	case .Network_Access_Attempt, .None:
	}
	runner_record_violation(runner, kind, refusal)
	runner.state = .Refused
}

// runner_exit_counted counts one Guest_Run exit against the bound of the
// spec, and gives false, with the state Timed_Out, past it. An exit
// Interrupted comes from the timer of the host, not from the guest: its
// count depends on the speed of the machine, so it is never counted, never
// ends the run, and never reaches the report. Only the exits that the guest
// causes are counted, so two builds of one spec count the same exits.
runner_exit_counted :: proc "contextless" (runner: ^Guest_Sandbox_Runner, exit_kind: op.Guest_Exit_Kind) -> bool {
	if runner == nil || runner.state != .Running {
		return false
	}
	if exit_kind == .Interrupted {
		return true
	}
	limit := runner.spec.max_guest_exits
	if limit == 0 {
		limit = DEFAULT_MAX_GUEST_EXITS
	}
	if runner.guest_exits_handled >= limit {
		runner.state = .Timed_Out
		return false
	}
	runner.guest_exits_handled += 1
	return true
}

// runner_handle_exit processes one Guest_Run exit deterministically. Returns
// keep_running = true when the VMM loop should re-enter the guest, or false
// when execution has ended (exit port, violation, fault, or timeout).
runner_handle_exit :: proc "contextless" (
	runner: ^Guest_Sandbox_Runner,
	registers: ^op.Guest_Registers,
	exit_kind: op.Guest_Exit_Kind,
	a: u64,
	b: u64,
	c: u64,
	next_rip: u64,
) -> (keep_running: bool) {
	if registers == nil || !runner_exit_counted(runner, exit_kind) {
		return false
	}
	return runner_answer_exit(runner, registers, exit_kind, a, b, c, next_rip)
}

// runner_answer_exit answers one exit that the caller counted with
// runner_exit_counted: the ports of the build (the frozen clock, the exit
// status, the trap of a network device), cpuid, and the end of the run on
// each other exit.
runner_answer_exit :: proc "contextless" (
	runner: ^Guest_Sandbox_Runner,
	registers: ^op.Guest_Registers,
	exit_kind: op.Guest_Exit_Kind,
	a: u64,
	b: u64,
	c: u64,
	next_rip: u64,
) -> (keep_running: bool) {
	if runner == nil || registers == nil || runner.state != .Running {
		return false
	}
	switch exit_kind {
	case .Interrupted:
		return true

	case .Port_Read:
		mask := port_read_mask(b)
		port, port_ok := guest_io_port_of_word(a)
		if !port_ok {
			write_port_read_result(registers, b, mask)
			registers.rip = next_rip
			return true
		}
		switch port {
		case .Rtc_Data:
			reg, reg_ok := guest_rtc_register_of_word(u64(runner.rtc_selected_register & 0x7F))
			value := u64(0)
			if reg_ok {
				value = u64(rtc_register_value(runner.spec.frozen_epoch_seconds, reg))
			}
			write_port_read_result(registers, b, value)
		case .Frozen_Clock_Low:
			write_port_read_result(registers, b, u64(u32(runner.spec.frozen_epoch_seconds)))
		case .Frozen_Clock_High:
			write_port_read_result(registers, b, u64(u32(runner.spec.frozen_epoch_seconds >> 32)))
		case .Debug_Console_Status:
			// Transmitter holding register empty + transmitter empty (0x60).
			write_port_read_result(registers, b, 0x60)
		case .Block_Command:
			write_port_read_result(registers, b, u64(runner.block_last_status))
		case .Network_Device_Trap:
			_ = runner_request_network_device(runner)
			write_port_read_result(registers, b, mask)
			registers.rip = next_rip
			runner.state = .Refused
			return false
		case .Rtc_Index, .Debug_Console_Data, .Build_Exit_Status, .Block_Disk_Select, .Block_Offset_Low, .Block_Length:
			write_port_read_result(registers, b, 0)
		}
		registers.rip = next_rip
		return true

	case .Port_Write:
		port, port_ok := guest_io_port_of_word(a)
		if !port_ok {
			registers.rip = next_rip
			return true
		}
		switch port {
		case .Rtc_Index:
			runner.rtc_selected_register = u8(c & 0x7F)
		case .Rtc_Data:
			// Ignore guest writes to CMOS/RTC so time remains frozen.
		case .Debug_Console_Data:
			if int(runner.console_length) < MAX_CONSOLE_CAPTURE_BYTES {
				runner.console_buffer[runner.console_length] = u8(c & 0xFF)
				runner.console_length += 1
			}
		case .Build_Exit_Status:
			runner.guest_exit_code = u32(c)
			runner.guest_exited = true
			registers.rip = next_rip
			return false
		case .Block_Disk_Select:
			runner.block_selected_disk_word = u32(c)
		case .Block_Offset_Low:
			runner.block_offset = u64(u32(c))
		case .Block_Length:
			runner.block_length = u32(c)
		case .Block_Command:
			role, role_ok := guest_disk_role_of_word(u64(runner.block_selected_disk_word))
			operation, op_ok := guest_block_operation_of_word(c)
			if !role_ok || !op_ok {
				runner.block_last_status = .Unsupported
			} else {
				// Port-driven command checks permissions/bounds without DMA.
				scratch: [1]u8
				probe_len := min(int(runner.block_length), 1)
				runner.block_last_status = runner_handle_block_request(runner, role, operation, runner.block_offset, scratch[:probe_len])
			}
		case .Network_Device_Trap:
			_ = runner_request_network_device(runner)
			registers.rip = next_rip
			runner.state = .Refused
			return false
		case .Debug_Console_Status, .Frozen_Clock_Low, .Frozen_Clock_High:
			// Read-only ports ignore guest writes.
		}
		registers.rip = next_rip
		return true

	case .Cpuid:
		runner_handle_cpuid(registers)
		registers.rip = next_rip
		return true

	case .Halt, .Memory, .Shutdown, .Refused_State, .Other, .Interrupt_Window, .None:
		runner.state = .Failed
		if runner.refusal == .None {
			runner.refusal = .Nonzero_Guest_Exit
		}
		return false
	}

	return false
}

// runner_finish finalizes a guest build after the execution loop stops.
// Extracts and hashes the writable output disk ONLY when the guest exited
// cleanly with exit code 0 and zero sandbox violations. On any failure or
// violation, canonical_tree_output is left untouched and output_tree_hash is zero.
runner_finish :: proc "contextless" (
	runner: ^Guest_Sandbox_Runner,
	workspace: ^Disk_Unpack_Workspace,
	canonical_tree_output: []u8,
) -> (output_tree_hash: blake3.Hash, written_tree_bytes: int, refusal: Guest_Builder_Refusal) {
	if runner == nil {
		return {}, 0, .Output_Extraction_Failed
	}
	runner.output_tree_hash = {}
	runner.output_tree_bytes_written = 0

	if runner.state == .Timed_Out {
		runner.refusal = .Nonzero_Guest_Exit
		return {}, 0, .Nonzero_Guest_Exit
	}
	if runner.sandbox_violations > 0 {
		runner.state = .Refused
		effective_refusal := runner.refusal
		if effective_refusal == .None {
			switch runner.last_violation {
			case .Read_Only_Disk_Write:
				effective_refusal = .Writable_Input_Forbidden
			case .Network_Access_Attempt:
				effective_refusal = .Network_Forbidden
			case .Output_Size_Exceeded:
				effective_refusal = .Output_Too_Large
			case .None:
				effective_refusal = .Network_Forbidden
			}
		}
		runner.refusal = effective_refusal
		return {}, 0, effective_refusal
	}
	if runner.state == .Refused {
		return {}, 0, runner.refusal
	}
	if !runner.guest_exited || runner.guest_exit_code != 0 {
		runner.state = .Failed
		runner.refusal = .Nonzero_Guest_Exit
		return {}, 0, .Nonzero_Guest_Exit
	}

	written, hash, unpack_refusal := unpack_output_disk(
		runner.output_disk,
		runner.spec.output_size_bound,
		workspace,
		canonical_tree_output,
	)
	if unpack_refusal != .None {
		runner.state = .Failed
		runner.refusal = unpack_refusal
		return {}, 0, unpack_refusal
	}

	runner.state = .Succeeded
	runner.refusal = .None
	runner.output_tree_hash = hash
	runner.output_tree_bytes_written = written
	return hash, written, .None
}
