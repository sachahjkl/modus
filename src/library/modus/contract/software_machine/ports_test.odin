#+build !freestanding
package software_machine

import "core:testing"

// What the bus of a test saw. The test runner runs each test on its own
// thread, so the record is a thread-local.
@(private = "file")
Port_Bus_Record :: struct {
	reads:        int,
	writes:       int,
	last_port:    u16,
	last_width:   Operand_Width,
	last_value:   u32,
	read_answer:  u32,
}

@(private = "file", thread_local)
bus_record: Port_Bus_Record

@(private = "file")
test_port_read :: proc "contextless" (port: u16, width: Operand_Width) -> u32 {
	bus_record.reads += 1
	bus_record.last_port = port
	bus_record.last_width = width
	return bus_record.read_answer
}

@(private = "file")
test_port_write :: proc "contextless" (port: u16, width: Operand_Width, value: u32) {
	bus_record.writes += 1
	bus_record.last_port = port
	bus_record.last_width = width
	bus_record.last_value = value
}

// The map of the task state: 8192 bytes and the byte of all ones that the
// processor reads past the last port.
PORT_MAP_BYTES :: 8192 + 1

@(private = "file")
map_with_open_ports :: proc(permission_map: []u8, open: []u16) {
	for &b in permission_map {
		b = 0xFF
	}
	for port in open {
		permission_map[port / 8] &~= u8(1) << (port % 8)
	}
}

@(private = "file")
Port_Machine :: struct {
	machine:    Test_Machine,
	code_frame: u64,
	cpu:        Processor_State,
}

PORT_CODE_ADDRESS :: u64(0x0000_0000_0040_0000)

@(private = "file")
port_machine_load :: proc(m: ^Port_Machine, code: []u8, bus: Port_Bus) {
	for &b in m.machine.ram[m.code_frame:m.code_frame + PAGE_SIZE] {
		b = 0x90
	}
	test_load_code(&m.machine, m.code_frame, code)
	processor_init(&m.cpu, m.machine.cr3, PORT_CODE_ADDRESS, 0)
	m.cpu.ports = bus
	bus_record = {}
}

@(private = "file")
port_machine_create :: proc() -> Port_Machine {
	m := Port_Machine{machine = test_machine_create(256 * 1024)}
	m.code_frame = test_alloc_frame(&m.machine)
	test_map_4k_page(&m.machine, PORT_CODE_ADDRESS, m.code_frame, PAGE_PRESENT | PAGE_USER)
	return m
}

// Each form of in and out, with no bus and with a bus that opens no port:
// a protection fault with error code 0, rip and the registers kept, and
// the device never reached.
@(test)
test_ports_refused_with_no_bus_and_closed_map :: proc(t: ^testing.T) {
	m := port_machine_create()
	defer test_machine_destroy(&m.machine)
	closed: [PORT_MAP_BYTES]u8
	map_with_open_ports(closed[:], {})
	forms := [][]u8{{0xE4, 0x60}, {0xE5, 0x60}, {0xE6, 0x60}, {0xE7, 0x60}, {0xEC}, {0xED}, {0xEE}, {0xEF}, {0x66, 0xED}, {0x48, 0xEF}}
	buses := []Port_Bus{{}, {permission_map = closed[:], read = test_port_read, write = test_port_write}, {permission_map = nil, read = test_port_read, write = test_port_write}}
	for bus in buses {
		for form in forms {
			port_machine_load(&m, form, bus)
			m.cpu.registers[int(General_Register.Rax)] = 0x1122_3344_5566_7788
			m.cpu.registers[int(General_Register.Rdx)] = 0x60
			before := m.cpu.registers
			outcome := processor_step(&m.cpu, m.machine.ram)
			testing.expectf(t, outcome == .General_Protection, "%x: %v", form, outcome)
			testing.expect_value(t, m.cpu.fault_error_code, u64(0))
			testing.expect_value(t, m.cpu.rip, PORT_CODE_ADDRESS)
			testing.expect(t, m.cpu.registers == before, "a refused port changed a register")
			testing.expect_value(t, bus_record.reads + bus_record.writes, 0)
		}
	}
	// A bus with a map and only one of its two procedures opens nothing.
	open: [PORT_MAP_BYTES]u8
	map_with_open_ports(open[:], {0x60})
	port_machine_load(&m, {0xE4, 0x60}, {permission_map = open[:], read = test_port_read})
	testing.expect_value(t, processor_step(&m.cpu, m.machine.ram), Step_Outcome.General_Protection)
}

// The map decides each byte of an access: one closed byte refuses the
// whole access, and a port whose bits pass the end of the map is refused.
@(test)
test_ports_permission_edges :: proc(t: ^testing.T) {
	permission_map: [PORT_MAP_BYTES]u8
	map_with_open_ports(permission_map[:], {0x60, 0x64, 0x3F8, 0x3F9, 0x3FA, 0x3FB, 0xFFFF})
	bus := Port_Bus{permission_map = permission_map[:], read = test_port_read, write = test_port_write}
	cases := []struct {
		port:      u16,
		width:     Operand_Width,
		permitted: bool,
	} {
		{0x60, .Bits_8, true},
		{0x61, .Bits_8, false},
		{0x60, .Bits_16, false}, // 0x61 is closed.
		{0x60, .Bits_32, false},
		{0x64, .Bits_8, true},
		{0x63, .Bits_8, false},
		{0x3F8, .Bits_32, true},
		{0x3F9, .Bits_32, false}, // 0x3FC is closed.
		{0x3F8, .Bits_64, false}, // No port access has 8 bytes.
		{0xFFFF, .Bits_8, true},
		{0xFFFF, .Bits_16, false}, // Bit 65536 is in the byte of all ones.
		{0xFFFF, .Bits_32, false},
		{0x0000, .Bits_8, false},
	}
	for c in cases {
		testing.expectf(t, port_access_permitted(bus, c.port, c.width) == c.permitted, "port %x, width %v", c.port, c.width)
	}
	// A map of 8192 bytes has no byte past the last port: the access that
	// passes its end is refused, not read past the slice.
	short := Port_Bus{permission_map = permission_map[:8192], read = test_port_read, write = test_port_write}
	testing.expect(t, port_access_permitted(short, 0xFFFF, .Bits_8))
	testing.expect(t, !port_access_permitted(short, 0xFFFF, .Bits_16))
	empty := Port_Bus{permission_map = permission_map[:0], read = test_port_read, write = test_port_write}
	testing.expect(t, !port_access_permitted(empty, 0, .Bits_8))
}

// An open port reaches the bus with its width and its value: in al keeps
// the upper bytes of rax, in ax keeps the upper 48 bits, in eax clears the
// upper half, and REX.W changes nothing.
@(test)
test_ports_reach_the_bus_with_their_width :: proc(t: ^testing.T) {
	m := port_machine_create()
	defer test_machine_destroy(&m.machine)
	permission_map: [PORT_MAP_BYTES]u8
	map_with_open_ports(permission_map[:], {0x60, 0x61, 0x62, 0x63, 0x64, 0x3F8, 0x3F9})
	bus := Port_Bus{permission_map = permission_map[:], read = test_port_read, write = test_port_write}
	RAX_BEFORE :: u64(0x1122_3344_5566_7788)
	reads := []struct {
		code:  []u8,
		width: Operand_Width,
		port:  u16,
		rax:   u64,
		size:  u64,
	} {
		{{0xE4, 0x64}, .Bits_8, 0x64, 0x1122_3344_5566_77EF, 2},
		{{0xEC}, .Bits_8, 0x60, 0x1122_3344_5566_77EF, 1},
		{{0x66, 0xED}, .Bits_16, 0x60, 0x1122_3344_5566_CDEF, 2},
		{{0xED}, .Bits_32, 0x60, 0x0000_0000_89AB_CDEF, 1},
		{{0x48, 0xED}, .Bits_32, 0x60, 0x0000_0000_89AB_CDEF, 2},
		{{0xE5, 0x60}, .Bits_32, 0x60, 0x0000_0000_89AB_CDEF, 2},
	}
	for c in reads {
		port_machine_load(&m, c.code, bus)
		bus_record.read_answer = 0x89AB_CDEF & u32(width_mask(c.width))
		m.cpu.registers[int(General_Register.Rax)] = RAX_BEFORE
		m.cpu.registers[int(General_Register.Rdx)] = 0xFFFF_0000_0000_0060 // Only dx names the port.
		testing.expect_value(t, processor_step(&m.cpu, m.machine.ram), Step_Outcome.Running)
		testing.expect_value(t, bus_record.reads, 1)
		testing.expect_value(t, bus_record.writes, 0)
		testing.expect_value(t, bus_record.last_port, c.port)
		testing.expect_value(t, bus_record.last_width, c.width)
		testing.expectf(t, m.cpu.registers[int(General_Register.Rax)] == c.rax, "%x: rax %x", c.code, m.cpu.registers[int(General_Register.Rax)])
		testing.expect_value(t, m.cpu.rip, PORT_CODE_ADDRESS + c.size)
		testing.expect_value(t, m.cpu.steps_executed, u64(1))
	}
	writes := []struct {
		code:  []u8,
		width: Operand_Width,
		port:  u16,
		value: u32,
	} {
		{{0xE6, 0x60}, .Bits_8, 0x60, 0x88},
		{{0xEE}, .Bits_8, 0x3F8, 0x88},
		{{0x66, 0xEF}, .Bits_16, 0x3F8, 0x7788},
		{{0xE7, 0x60}, .Bits_32, 0x60, 0x5566_7788},
	}
	for c in writes {
		port_machine_load(&m, c.code, bus)
		m.cpu.registers[int(General_Register.Rax)] = RAX_BEFORE
		m.cpu.registers[int(General_Register.Rdx)] = 0x3F8
		testing.expect_value(t, processor_step(&m.cpu, m.machine.ram), Step_Outcome.Running)
		testing.expect_value(t, bus_record.writes, 1)
		testing.expect_value(t, bus_record.reads, 0)
		testing.expect_value(t, bus_record.last_port, c.port)
		testing.expect_value(t, bus_record.last_width, c.width)
		testing.expect_value(t, bus_record.last_value, c.value)
		testing.expect_value(t, m.cpu.registers[int(General_Register.Rax)], RAX_BEFORE)
	}
}

// The immediate of in is on a page that is not mapped: a page fault at
// the address of the immediate, and the device never reached.
@(test)
test_ports_immediate_fault_reaches_no_device :: proc(t: ^testing.T) {
	m := port_machine_create()
	defer test_machine_destroy(&m.machine)
	permission_map: [PORT_MAP_BYTES]u8
	map_with_open_ports(permission_map[:], {0x60})
	bus := Port_Bus{permission_map = permission_map[:], read = test_port_read, write = test_port_write}
	port_machine_load(&m, {}, bus)
	m.machine.ram[m.code_frame + PAGE_SIZE - 1] = 0xE4
	m.cpu.rip = PORT_CODE_ADDRESS + PAGE_SIZE - 1
	testing.expect_value(t, processor_step(&m.cpu, m.machine.ram), Step_Outcome.Page_Fault)
	testing.expect_value(t, m.cpu.fault_address, PORT_CODE_ADDRESS + PAGE_SIZE)
	testing.expect_value(t, m.cpu.rip, PORT_CODE_ADDRESS + PAGE_SIZE - 1)
	testing.expect_value(t, bus_record.reads + bus_record.writes, 0)
}
