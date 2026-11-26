#+build !freestanding
#+build !modus
package guest_os

import "core:testing"
import op "modus:contract/operation"

@(private = "file")
put_all :: proc(line: ^Console_Line, bytes: string) -> (changes: [dynamic]Console_Change) {
	for index in 0 ..< len(bytes) {
		append(&changes, console_line_put(line, bytes[index]))
	}
	return
}

@(private = "file")
text_of :: proc(line: ^Console_Line) -> string {
	text, _ := console_line_text(line)
	return string(text)
}

// The hostile bytes first: control bytes, bytes of 128 or more, a sequence
// with no end, a number past its bound, a line past its bound.
@(test)
console_line_refuses_hostile_bytes :: proc(t: ^testing.T) {
	line: Console_Line
	// Each control byte but the four that the line reads does nothing.
	for value in 0 ..< 0x20 {
		if value == '\n' || value == '\r' || value == '\b' || value == '\t' || value == 0x1B {
			continue
		}
		testing.expectf(t, console_line_put(&line, u8(value)) == .None, "control byte %x", value)
	}
	testing.expect_value(t, console_line_put(&line, 0x7F), Console_Change.None)
	testing.expect_value(t, text_of(&line), "")
	// A byte of 128 or more becomes '?': a sequence of UTF-8 of the guest
	// reaches no reader whole.
	for value in ([?]u8{0x80, 0xC3, 0xA9, 0xFF}) {
		testing.expect_value(t, console_line_put(&line, value), Console_Change.Changed)
	}
	testing.expect_value(t, text_of(&line), "????")
	// A long sequence writes nothing until its final byte, which does
	// nothing when no rule names it.
	console_line_next(&line)
	delete(put_all(&line, "\x1b[0000000000000000000000000000;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;x"))
	testing.expect_value(t, text_of(&line), "")
	testing.expect_value(t, line.number, 0)
	// A number past its bound moves the cursor to the start, no further.
	console_line_next(&line)
	delete(put_all(&line, "abc\x1b[99999999999999999999D"))
	_, cursor := console_line_text(&line)
	testing.expect_value(t, cursor, 0)
	delete(put_all(&line, "\x1b[99999999999999999999C"))
	_, cursor = console_line_text(&line)
	testing.expect_value(t, cursor, 3)
	testing.expect_value(t, line.number, CONSOLE_SEQUENCE_NUMBER_MOST)
	// An unknown sequence does nothing; ESC with no [ takes the one byte
	// after it.
	console_line_next(&line)
	delete(put_all(&line, "a\x1b[31mb\x1b(c\x1b]d"))
	testing.expect_value(t, text_of(&line), "abcd")
	// A line of CONSOLE_LINE_BYTES ends at its last byte.
	console_line_next(&line)
	for _ in 0 ..< CONSOLE_LINE_BYTES - 1 {
		testing.expect_value(t, console_line_put(&line, 'x'), Console_Change.Changed)
	}
	testing.expect_value(t, console_line_put(&line, 'y'), Console_Change.Ended)
	text, _ := console_line_text(&line)
	testing.expect_value(t, len(text), CONSOLE_LINE_BYTES)
	testing.expect_value(t, text[CONSOLE_LINE_BYTES - 1], u8('y'))
	// A tab at the end of a line ends it with no write past the bound.
	console_line_next(&line)
	for _ in 0 ..< CONSOLE_LINE_BYTES - 3 {
		console_line_put(&line, 'x')
	}
	testing.expect_value(t, console_line_put(&line, '\t'), Console_Change.Ended)
	text, _ = console_line_text(&line)
	testing.expect_value(t, len(text), CONSOLE_LINE_BYTES)
}

// The line editing of a shell: the prompt, the echo of a key, a backspace
// in its two forms, an erase to the end, a carriage return and a new line.
@(test)
console_line_follows_a_shell :: proc(t: ^testing.T) {
	line: Console_Line
	delete(put_all(&line, "~ # ech"))
	text, cursor := console_line_text(&line)
	testing.expect_value(t, string(text), "~ # ech")
	testing.expect_value(t, cursor, 7)
	// Backspace as "\b \b", then as "\b" and erase to the end.
	delete(put_all(&line, "\b \b"))
	text, cursor = console_line_text(&line)
	testing.expect_value(t, string(text), "~ # ec ")
	testing.expect_value(t, cursor, 6)
	delete(put_all(&line, "\b\x1b[K"))
	text, cursor = console_line_text(&line)
	testing.expect_value(t, string(text), "~ # e")
	testing.expect_value(t, cursor, 5)
	// A move left, an insert as a shell redraws it, and the tab stop.
	delete(put_all(&line, "cho\x1b[3Dx"))
	testing.expect_value(t, text_of(&line), "~ # exho")
	console_line_next(&line)
	delete(put_all(&line, "a\tb"))
	testing.expect_value(t, text_of(&line), "a       b")
	// ESC [ 2 K erases the whole line.
	console_line_next(&line)
	delete(put_all(&line, "abc\x1b[2K"))
	testing.expect_value(t, text_of(&line), "   ")
	// The successful case last: the output of a command, with "\r\n".
	console_line_next(&line)
	changes := put_all(&line, "modus-guest-ok\r\n")
	defer delete(changes)
	testing.expect_value(t, changes[len(changes) - 1], Console_Change.Ended)
	testing.expect_value(t, changes[len(changes) - 2], Console_Change.Changed)
	testing.expect_value(t, text_of(&line), "modus-guest-ok")
	console_line_next(&line)
	text, cursor = console_line_text(&line)
	testing.expect_value(t, len(text), 0)
	testing.expect_value(t, cursor, 0)
}

// The receive queue of the serial port: empty reads, a full queue, the
// order of the bytes, the line status, the identification and the line.
@(test)
serial_receive_queue_edges :: proc(t: ^testing.T) {
	port: Serial_Port
	// Empty: the register reads 0, no data ready, no interrupt.
	testing.expect_value(t, serial_read(&port, 0), u8(0))
	testing.expect_value(t, serial_read(&port, 5) & SERIAL_LINE_STATUS_DATA_READY, u8(0))
	testing.expect(t, !serial_interrupt(&port))
	testing.expect_value(t, serial_receive_put(&port, nil), 0)
	// A byte with the interrupt of received data off: data ready, no line.
	testing.expect_value(t, serial_receive_put(&port, {'a'}), 1)
	testing.expect_value(t, serial_read(&port, 5) & SERIAL_LINE_STATUS_DATA_READY, SERIAL_LINE_STATUS_DATA_READY)
	testing.expect(t, !serial_interrupt(&port))
	testing.expect_value(t, serial_read(&port, 2), SERIAL_INTERRUPT_NONE)
	// With it on: the line rises, and received data comes before the
	// holding register.
	serial_write(&port, 1, SERIAL_ENABLE_RECEIVED | SERIAL_ENABLE_TRANSMIT)
	testing.expect(t, serial_interrupt(&port))
	testing.expect_value(t, serial_read(&port, 2), SERIAL_INTERRUPT_RECEIVED)
	testing.expect_value(t, serial_read(&port, 2), SERIAL_INTERRUPT_RECEIVED)
	testing.expect_value(t, serial_read(&port, 0), u8('a'))
	testing.expect_value(t, serial_read(&port, 2), SERIAL_INTERRUPT_TRANSMIT)
	testing.expect(t, !serial_interrupt(&port))
	// The divisor latch hides the queue.
	serial_receive_put(&port, {'b'})
	serial_write(&port, 3, SERIAL_LINE_DIVISOR_LATCH)
	serial_write(&port, 0, 0x0C)
	testing.expect_value(t, serial_read(&port, 0), u8(0x0C))
	serial_write(&port, 3, 0x03)
	testing.expect_value(t, serial_read(&port, 0), u8('b'))
	// Full: the queue takes SERIAL_RECEIVE_BYTES, the rest is counted.
	bytes: [SERIAL_RECEIVE_BYTES + 5]u8
	for &value, index in bytes {
		value = u8(index)
	}
	testing.expect_value(t, serial_receive_put(&port, bytes[:]), SERIAL_RECEIVE_BYTES)
	testing.expect_value(t, port.receive_dropped, u64(5))
	testing.expect_value(t, serial_receive_put(&port, {1}), 0)
	testing.expect_value(t, port.receive_dropped, u64(6))
	// The successful case last: the bytes come out in order, around the end.
	for index in 0 ..< SERIAL_RECEIVE_BYTES {
		testing.expectf(t, serial_read(&port, 0) == u8(index), "byte %v", index)
	}
	testing.expect_value(t, serial_read(&port, 5) & SERIAL_LINE_STATUS_DATA_READY, u8(0))
	testing.expect_value(t, serial_read(&port, 0), u8(0))
}

// The output of the port leaves it in order, in parts, and the capture
// takes new bytes after.
@(test)
serial_output_take_in_parts :: proc(t: ^testing.T) {
	port: Serial_Port
	out: [4]u8
	testing.expect_value(t, serial_output_take(&port, out[:]), 0)
	for value in "hello" {
		serial_write(&port, 0, u8(value))
	}
	testing.expect_value(t, serial_output_take(&port, out[:0]), 0)
	testing.expect_value(t, serial_output_take(&port, out[:]), 4)
	testing.expect_value(t, string(out[:]), "hell")
	serial_write(&port, 0, '!')
	count := serial_output_take(&port, out[:])
	testing.expect_value(t, string(out[:count]), "o!")
	testing.expect_value(t, serial_output_take(&port, out[:]), 0)
	// Loop mode sends no byte to the output.
	serial_write(&port, 4, SERIAL_MODEM_LOOP)
	serial_write(&port, 0, 'x')
	testing.expect_value(t, serial_output_take(&port, out[:]), 0)
}

// An idle guest with waits_for_input: the machine gives Waiting, the wait
// is the ticks to the next interrupt of the timer, and the resume moves the
// clock at most to that tick, then asks for the tick.
@(test)
machine_waiting_guest_follows_the_time_of_the_machine :: proc(t: ^testing.T) {
	machine := new(Linux_Machine)
	defer free(machine)
	linux_machine_start(machine, {}, nil, nil)
	machine.waits_for_input = true
	registers := op.Guest_Registers{rflags = 0x2, rip = 0x100}
	out :: proc(machine: ^Linux_Machine, registers: ^op.Guest_Registers, port: u16, value: u8) {
		linux_machine_handle_exit(machine, registers, {kind = .Port_Write, a = u64(port), b = 1, c = u64(value), next = registers.rip + 1})
	}
	for pair in ([?][2]u16{{0x20, 0x11}, {0x21, 0x30}, {0x21, 0x04}, {0x21, 0x01}, {0xA0, 0x11}, {0xA1, 0x38}, {0xA1, 0x02}, {0xA1, 0x01}, {0x21, 0xFF}, {0xA1, 0xFF}}) {
		out(machine, &registers, pair[0], u8(pair[1]))
	}
	// hlt with the interrupts off: the guest stopped, whatever the setting.
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = registers.rip + 1}), Machine_Step.Halted)
	// Interrupts on, every line masked, the timer off: Waiting, and only an
	// input wakes the guest.
	registers.rflags = 0x202
	testing.expect_value(t, linux_machine_handle_exit(machine, &registers, {kind = .Halt, next = registers.rip + 1}), Machine_Step.Waiting)
	_, bounded := linux_machine_wait_ticks(machine)
	testing.expect(t, !bounded)
	// A key with the serial line unmasked and its interrupt on: the resume
	// asks for its vector, with no tick.
	out(machine, &registers, 0x21, 0xEF) // Line 4 only.
	out(machine, &registers, 0x3F9, SERIAL_ENABLE_RECEIVED)
	clock := machine.clock
	testing.expect_value(t, linux_machine_serial_input(machine, {'l', 's', '\r'}), 3)
	linux_machine_resume(machine, &registers, max(u64))
	testing.expect_value(t, machine.clock, max(u64)) // No bound: the time that passed, with no wrap.
	testing.expect(t, machine.clock >= clock)
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x34))
	// The timer: unmasked, 4096 ticks. A late wake moves the clock to the
	// tick, not past it.
	machine2 := new(Linux_Machine)
	defer free(machine2)
	linux_machine_start(machine2, {}, nil, nil)
	machine2.waits_for_input = true
	registers = op.Guest_Registers{rflags = 0x2, rip = 0x100}
	for pair in ([?][2]u16{{0x20, 0x11}, {0x21, 0x30}, {0x21, 0x04}, {0x21, 0x01}, {0xA0, 0x11}, {0xA1, 0x38}, {0xA1, 0x02}, {0xA1, 0x01}, {0x21, 0xFE}, {0xA1, 0xFF}}) {
		out(machine2, &registers, pair[0], u8(pair[1]))
	}
	out(machine2, &registers, 0x43, 0x34)
	out(machine2, &registers, 0x40, 0x00)
	out(machine2, &registers, 0x40, 0x10)
	registers.rflags = 0x202
	testing.expect_value(t, linux_machine_handle_exit(machine2, &registers, {kind = .Halt, next = registers.rip + 1}), Machine_Step.Waiting)
	ticks, timer_bounded := linux_machine_wait_ticks(machine2)
	testing.expect(t, timer_bounded && ticks > 0 && ticks <= 4096)
	start := machine2.clock
	// A wake before the tick: the clock moves by the time, and no tick yet.
	linux_machine_resume(machine2, &registers, 1)
	testing.expect_value(t, machine2.clock, start + 1)
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.None))
	// The successful case last: a late wake reaches the tick exactly.
	ticks, _ = linux_machine_wait_ticks(machine2)
	linux_machine_resume(machine2, &registers, ticks * 1000)
	testing.expect_value(t, machine2.clock, start + 1 + ticks)
	testing.expect_value(t, registers.inject_kind, u8(op.Guest_Inject_Kind.External_Interrupt))
	testing.expect_value(t, registers.inject_vector, u8(0x30))
	// Without waits_for_input, the same hlt jumps the clock, as a build needs.
	machine2.waits_for_input = false
	registers.inject_kind, registers.inject_vector = 0, 0
	out(machine2, &registers, 0x20, 0x20)
	testing.expect_value(t, linux_machine_handle_exit(machine2, &registers, {kind = .Halt, next = registers.rip + 1}), Machine_Step.Continue)
}

// The debug registers of the guest: the refusals first (another
// instruction, a register that the exit does not name, DR8, a mov with a
// memory operand), then a write and a read of DR7 and DR0 in long mode.
@(test)
machine_debug_registers_edges :: proc(t: ^testing.T) {
	ram := make([]u8, 2 * 4096)
	defer delete(ram)
	machine := new(Linux_Machine)
	defer free(machine)
	run :: proc(machine: ^Linux_Machine, ram: []u8, code: []u8, exit_code: u64, registers: ^op.Guest_Registers) -> Machine_Step {
		for &value in ram[0x1000:0x1010] {
			value = 0
		}
		copy(ram[0x1000:], code)
		registers.rip = 0x1000
		return linux_machine_handle_exit(machine, registers, {kind = .Other, code = exit_code})
	}
	linux_machine_start(machine, {ram}, nil, nil)
	testing.expect_value(t, machine.debug_registers[6], DEBUG_STATUS_FIXED)
	testing.expect_value(t, machine.debug_registers[7], DEBUG_CONTROL_FIXED)
	registers := op.Guest_Registers{cr0 = 1}
	// 0F 23 F8: mov dr7, eax. The exit names DR6: refused. 0F 0B: ud2.
	// 0F 23 38: a memory operand. 44 0F 23 C0 (REX.R): dr8 in long mode.
	refused := [?]struct {
		code:      []u8,
		exit_code: u64,
		long:      bool,
	}{
		{{0x0F, 0x23, 0xF8}, 0x36, false},
		{{0x0F, 0x0B, 0x00}, 0x37, false},
		{{0x0F, 0x23, 0x38}, 0x37, false},
		{{0x0F, 0x21, 0xF8}, 0x37, false},
		{{0x44, 0x0F, 0x23, 0xC0}, 0x38, true},
	}
	for case_of in refused {
		machine.failure = .None
		registers = op.Guest_Registers{cr0 = 1, rax = 0x55}
		if case_of.long {
			registers.efer = op.GUEST_EFER_LONG_MODE_ACTIVE | op.GUEST_EFER_LONG_MODE_ENABLE
		}
		testing.expectf(t, run(machine, ram, case_of.code, case_of.exit_code, &registers) == .Failed, "%v with the code %x", case_of.code, case_of.exit_code)
		testing.expect_value(t, registers.rip, u64(0x1000))
		testing.expect_value(t, machine.debug_registers[7], DEBUG_CONTROL_FIXED)
	}
	// The successful cases last: mov dr7, rax keeps the fixed bit; mov rcx,
	// dr7 reads it back; mov dr0, rdx and back; 0F 21 E8 reads DR5 as DR7.
	registers = op.Guest_Registers{cr0 = 1, efer = op.GUEST_EFER_LONG_MODE_ACTIVE | op.GUEST_EFER_LONG_MODE_ENABLE, rax = 0x1_0000_0001}
	testing.expect_value(t, run(machine, ram, {0x0F, 0x23, 0xF8}, 0x37, &registers), Machine_Step.Continue)
	testing.expect_value(t, registers.rip, u64(0x1003))
	testing.expect_value(t, machine.debug_registers[7], u64(0x1_0000_0401))
	testing.expect_value(t, run(machine, ram, {0x0F, 0x21, 0xF9}, 0x27, &registers), Machine_Step.Continue)
	testing.expect_value(t, registers.rcx, u64(0x1_0000_0401))
	registers.rdx = 0xFFFF_8000_1234_5678
	testing.expect_value(t, run(machine, ram, {0x0F, 0x23, 0xC2}, 0x30, &registers), Machine_Step.Continue)
	testing.expect_value(t, run(machine, ram, {0x0F, 0x21, 0xC3}, 0x20, &registers), Machine_Step.Continue)
	testing.expect_value(t, registers.rbx, u64(0xFFFF_8000_1234_5678))
	testing.expect_value(t, run(machine, ram, {0x0F, 0x21, 0xE8}, 0x25, &registers), Machine_Step.Continue)
	testing.expect_value(t, registers.rax, u64(0x1_0000_0401))
}

// The one-shot tick of Linux: mode 4 fires once at the end of its count,
// gives no deadline after it, and a new count (with no control word) arms
// it again. Modes 1 and 5 wait for a gate that the channel 0 has not.
@(test)
timer_strobe_mode_fires_once_for_each_count :: proc(t: ^testing.T) {
	timer: Interval_Timer
	timer_write(&timer, TIMER_CONTROL_PORT, 0x38, 0) // Channel 0, both bytes, mode 4.
	_, before_load := timer_deadline(&timer)
	testing.expect(t, !before_load)
	timer_write(&timer, TIMER_PORT_BASE, 0x00, 100)
	timer_write(&timer, TIMER_PORT_BASE, 0x10, 100) // 4096 ticks.
	deadline, armed := timer_deadline(&timer)
	testing.expect(t, armed && deadline == 100 + 4096)
	testing.expect(t, !timer_advance(&timer, 100 + 4095))
	testing.expect(t, timer_advance(&timer, 100 + 4096))
	_, after_fire := timer_deadline(&timer)
	testing.expect(t, !after_fire)
	testing.expect(t, !timer_advance(&timer, 1_000_000))
	// The successful case last: a new count arms it again.
	timer_write(&timer, TIMER_PORT_BASE, 0x20, 2_000_000)
	timer_write(&timer, TIMER_PORT_BASE, 0x00, 2_000_000)
	deadline, armed = timer_deadline(&timer)
	testing.expect(t, armed && deadline == 2_000_000 + 0x20)
	// Modes 1 and 5 give no deadline.
	for control in ([?]u8{0x32, 0x3A}) {
		gated: Interval_Timer
		timer_write(&gated, TIMER_CONTROL_PORT, control, 0)
		timer_write(&gated, TIMER_PORT_BASE, 0x10, 0)
		timer_write(&gated, TIMER_PORT_BASE, 0x00, 0)
		_, gated_armed := timer_deadline(&gated)
		testing.expectf(t, !gated_armed, "control %x", control)
	}
}
// The width of the line follows the window: a width of 0, a negative width
// and one past CONSOLE_LINE_BYTES are refused and keep the width; a line at
// the width ends, and its next byte starts the next line.
@(test)
console_line_columns_follow_the_window :: proc(t: ^testing.T) {
	line: Console_Line
	testing.expect_value(t, console_line_limit(&line), CONSOLE_LINE_BYTES)
	for columns in ([?]int{0, -1, CONSOLE_LINE_BYTES + 1, max(int)}) {
		testing.expectf(t, !console_line_set_columns(&line, columns), "the width %d is refused", columns)
		testing.expect_value(t, console_line_limit(&line), CONSOLE_LINE_BYTES)
	}
	testing.expect(t, !console_line_set_columns(nil, 10))
	testing.expect(t, console_line_set_columns(&line, CONSOLE_LINE_BYTES))
	testing.expect(t, console_line_set_columns(&line, 1))
	testing.expect_value(t, console_line_limit(&line), 1)
	testing.expect(t, console_line_set_columns(&line, 4))
	changes := put_all(&line, "abcd")
	defer delete(changes)
	testing.expect_value(t, text_of(&line), "abcd")
	testing.expect_value(t, console_line_put(&line, 'e'), Console_Change.Ended)
	testing.expect_value(t, text_of(&line), "abcd")
	console_line_next(&line)
	testing.expect_value(t, console_line_put(&line, 'f'), Console_Change.Changed)
}
