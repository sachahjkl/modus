// The boot program: a UEFI program (docs/PROPERTIES.md, "Trusted boot").
//
// It contains the kernel module, the boot image, and the public key of the
// signing key with its key number. It does this:
//   1. reads the framebuffer of the firmware;
//   2. verifies the system description and the hash of the kernel and of
//      each file of the boot image, refuses an older system or a revoked
//      key with the TPM floors and raises them, and asks the firmware to
//      measure the description into the TPM (trust.odin);
//   3. loads the kernel module with the loader of package module;
//   4. builds page tables: all physical memory at DIRECT_MAP_BASE, the kernel
//      at KERNEL_BASE, and the same physical memory at its own addresses for
//      the moment of the jump;
//   5. reads the memory map and leaves the firmware services;
//   6. starts the entry of the kernel with a Boot_Info record.
package boot

import info "modus:contract/boot_info"
import "modus:contract/enum_word"
import "modus:support/bootscreen"
import "modus:support/firmware_memory_map"
import "modus:support/graphics"
import op "modus:contract/operation"
import module "modus:contract/module"
import "base:intrinsics"

kernel_file := #load(#config(KERNEL_MODULE, "../../build/modules/kernel.module"))
// The tool can give another boot image, for the test of a start that fails.
boot_image := #load(#config(BOOT_IMAGE, "../../build/boot.image"))
display_data: bootscreen.Data

// The self test that the tool chose for this build. The word of the build
// must name a test: the build stops on a word past the last one, so the
// kernel never reads a test that names nothing.
BOOT_SELF_TEST_WORD :: u64(#config(SELF_TEST, 0))
#assert(BOOT_SELF_TEST_WORD <= u64(max(info.Self_Test)))

foreign _ {
	boot_jump :: proc "win64" (page_table: u64, entry: u64, boot: u64, stack: u64) -> ! ---
}

PAGE_SIZE :: info.PAGE_SIZE
PAGE_PRESENT :: u64(1) << 0
PAGE_WRITE :: u64(1) << 1
PAGE_LARGE :: u64(1) << 7
PAGE_NO_EXECUTE :: u64(1) << 63
LARGE_PAGE_SIZE :: 2 << 20
TABLE_SPAN :: 1 << 30 // The memory that one table of large pages maps.
MINIMUM_DIRECT_MAP :: 4 << 30 // Device memory, such as the framebuffer, is below this.

PREFERRED_WIDTH :: 1024
PREFERRED_HEIGHT :: 768

system: ^Efi_System_Table
image_handle: rawptr

// The record and the step that a stop shows on the boot display (stop): a
// stop can come from a procedure that has no record, such as allocate. The
// record is nil until its own pages exist.
stop_record: ^info.Boot_Info
stop_step := bootscreen.Step.Firmware

@(export, link_name = "efi_main")
efi_main :: proc "win64" (image: rawptr, system_table: ^Efi_System_Table) -> Efi_Status {
	cycles_start := u64(intrinsics.read_cycle_counter())
	system = system_table
	image_handle = image
	services := system.boot_services
	print("boot program: started\r\n")

	boot := (^info.Boot_Info)(allocate(1))
	stop_record = boot
	boot.magic = info.MAGIC
	boot.cycles_start = cycles_start
	boot.self_test = BOOT_SELF_TEST_WORD
	boot.framebuffer = framebuffer()
	for &character, index in boot.firmware_vendor[:len(boot.firmware_vendor) - 1] {
		unit := system.firmware_vendor[index]
		if unit == 0 {
			break
		}
		character = unit < 0x7F ? u8(unit) : '?'
	}
	boot.firmware_revision = u64(system.firmware_revision)
	// The kernel reads the list of the processors in the ACPI tables.
	for entry in system.tables[:system.table_count] {
		if entry.guid == EFI_ACPI_GUID {
			boot.acpi_root = u64(uintptr(entry.table))
		}
	}

	// The boot image goes to its own pages: the kernel gives it to the root
	// service as memory. The checks read this copy, the one that the kernel
	// receives.
	stop_step = .Boot_Image
	image_copy := allocate((u64(len(boot_image)) + PAGE_SIZE - 1) / PAGE_SIZE)
	intrinsics.mem_copy_non_overlapping(image_copy, raw_data(boot_image), len(boot_image))
	image_bytes := ([^]u8)(image_copy)[:len(boot_image)]
	description := trust_check(boot, image_bytes)
	floors_check(boot, description)
	measure(boot, description)

	// The kernel module.
	stop_step = .Kernel_Module
	if module.validate(kernel_file) != .None {
		stop("the kernel module is not valid")
	}
	head, _ := module.header(kernel_file)
	kernel := ([^]u8)(allocate(head.memory_size / PAGE_SIZE))[:head.memory_size]
	module.copy_segments(kernel_file, kernel)
	if module.rebase(kernel_file, kernel, info.KERNEL_BASE) != .None || module.count(kernel_file, .Imports) > 1 {
		stop("the kernel module cannot be loaded")
	}
	entry, has_entry := module.export_address(kernel_file, info.KERNEL_BASE, head.entry_export)
	if !has_entry {
		stop("the kernel module has no entry")
	}
	boot.kernel_address = u64(uintptr(raw_data(kernel)))
	boot.kernel_size = head.memory_size
	boot.kernel_file = u64(uintptr(raw_data(kernel_file)))
	boot.kernel_file_size = u64(len(kernel_file))
	boot.boot_image = u64(uintptr(image_copy))
	boot.boot_image_size = u64(len(boot_image))
	boot.cycles_loaded = u64(intrinsics.read_cycle_counter())

	stop_step = .Memory_Map
	stack := u64(uintptr(allocate(info.BOOT_STACK_PAGES))) + info.BOOT_STACK_PAGES * PAGE_SIZE
	ranges := ([^]info.Memory_Range)(allocate((firmware_memory_map.RANGE_CAPACITY * size_of(info.Memory_Range) + PAGE_SIZE - 1) / PAGE_SIZE))
	firmware_map: Firmware_Map

	// The page tables need the size of physical memory, so the memory map is
	// read once now, and once more after the last allocation.
	top := u64(MINIMUM_DIRECT_MAP)
	{
		list, _ := read_memory_map(&firmware_map, ranges)
		for range in ranges[:list.count] {
			op.boot_range_add(&display_data.boot, range.start, range.page_count, u64(range.kind))
			if range.kind != .Reserved {
				top = max(top, range.start + range.page_count * PAGE_SIZE)
			}
		}
	}
	_ = display(boot, "the boot program starts the kernel")
	top = (top + TABLE_SPAN - 1) / TABLE_SPAN * TABLE_SPAN
	boot.direct_map_size = top
	boot.page_table = build_page_tables(top, kernel, head.memory_size)
	boot.memory_ranges = u64(uintptr(ranges))

	// After the last allocation that stops the machine when it fails, so a
	// debug image never takes the memory that the start needs; before the
	// last read of the memory map, which gives its pages the kind Boot. The
	// page tables map all memory, its pages too.
	boot.debug_image, boot.debug_image_size = debug_image_read()
	print("boot program: ok\r\n")
	stop_step = .Kernel
	for attempt in 0 ..< 2 {
		list, key := read_memory_map(&firmware_map, ranges)
		boot.memory_range_count = u64(list.count)
		if services.exit_boot_services(image_handle, key) == 0 {
			// After the end of the firmware services: the serial port only.
			dropped_ranges_line(&list)
			boot_jump(boot.page_table, u64(entry), u64(info.DIRECT_MAP_BASE) + u64(uintptr(boot)), u64(info.DIRECT_MAP_BASE) + stack)
		}
		_ = attempt
	}
	stop("the firmware refused to end its services")
}

// build_page_tables gives the address of the top level table.
build_page_tables :: proc "contextless" (top: u64, kernel: []u8, kernel_size: u64) -> u64 {
	table :: proc "contextless" () -> ^[512]u64 {
		return (^[512]u64)(allocate(1))
	}
	// child gives the table that entry `index` of `parent` points to. It makes the table if needed.
	child :: proc "contextless" (parent: ^[512]u64, index: u64) -> ^[512]u64 {
		if parent[index] & PAGE_PRESENT == 0 {
			parent[index] = u64(uintptr(table())) | PAGE_PRESENT | PAGE_WRITE
		}
		return (^[512]u64)(uintptr(parent[index] &~ 0xFFF))
	}

	root := table()

	// Physical memory, in large pages: one set of tables, reached from entry 0
	// (the addresses that the boot program runs at) and from the direct map.
	physical := table()
	for span in 0 ..< top / TABLE_SPAN {
		large := child(physical, span)
		for i in 0 ..< u64(512) {
			large[i] = (span * TABLE_SPAN + i * LARGE_PAGE_SIZE) | PAGE_PRESENT | PAGE_WRITE | PAGE_LARGE
		}
	}
	root[0] = u64(uintptr(physical)) | PAGE_PRESENT | PAGE_WRITE
	root[(u64(info.DIRECT_MAP_BASE) >> 39) & 511] = u64(uintptr(physical)) | PAGE_PRESENT | PAGE_WRITE

	// The kernel, in small pages, with the protection of each segment.
	for index in 1 ..< module.count(kernel_file, .Segments) {
		segment, _ := module.record(kernel_file, .Segments, index, module.Segment)
		flags := PAGE_PRESENT
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
			flags |= PAGE_WRITE
		}
		if .Execute not_in segment.flags {
			flags |= PAGE_NO_EXECUTE
		}
		for offset := segment.memory_offset; offset < segment.memory_offset + segment.memory_size; offset += PAGE_SIZE {
			address := u64(info.KERNEL_BASE) + offset
			level3 := child(root, (address >> 39) & 511)
			level2 := child(level3, (address >> 30) & 511)
			level1 := child(level2, (address >> 21) & 511)
			level1[(address >> 12) & 511] = (u64(uintptr(raw_data(kernel))) + offset) | flags
		}
	}
	_ = kernel_size
	return u64(uintptr(root))
}

// The buffer of the memory map of the firmware. It has no pages before the
// first read; each read that the firmware finds too small gives it the size
// that the firmware asks, with a margin (package firmware_memory_map).
Firmware_Map :: struct {
	address: rawptr,
	pages:   u64,
}

// read_memory_map reads the memory map of the firmware into ranges: each
// usable range, and the reserved ranges that the room still takes
// (firmware_memory_map.Range_List). It does not return when the firmware
// refuses the read, when the map grows at each read, or when the usable
// ranges pass the room.
read_memory_map :: proc "contextless" (firmware_map: ^Firmware_Map, ranges: [^]info.Memory_Range) -> (list: firmware_memory_map.Range_List, key: uint) {
	size: uint
	descriptor_size: uint
	version: u32
	map_read := false
	for read_number := 1; !map_read; read_number += 1 {
		size = uint(firmware_map.pages * PAGE_SIZE)
		status := system.boot_services.get_memory_map(&size, firmware_map.address, &key, &descriptor_size, &version)
		switch firmware_memory_map.read_outcome(read_number, u64(status)) {
		case .Read:
			map_read = true
		case .Larger_Buffer:
			pages, problem := firmware_memory_map.buffer_pages(u64(size), u64(descriptor_size))
			if problem != .None {
				text: bootscreen.Text
				bootscreen.put(&text, "the firmware asks a buffer of ")
				bootscreen.put_number(&text, u64(size))
				bootscreen.put(&text, " bytes for its memory map, with descriptors of ")
				bootscreen.put_number(&text, u64(descriptor_size))
				bootscreen.put(&text, " bytes")
				stop(string(text.bytes[:text.count]))
			}
			// The free and the allocation change the map: the next read
			// gives its new size.
			if firmware_map.pages != 0 {
				_ = system.boot_services.free_pages(u64(uintptr(firmware_map.address)), uint(firmware_map.pages))
			}
			firmware_map^ = {address = allocate(pages), pages = pages}
		case .Refused:
			text: bootscreen.Text
			bootscreen.put(&text, "the firmware refused to give its memory map: status ")
			bootscreen.put_hex(&text, u64(status), 16)
			stop(string(text.bytes[:text.count]))
		case .Still_Growing:
			text: bootscreen.Text
			bootscreen.put(&text, "the memory map of the firmware grew at each of ")
			bootscreen.put_number(&text, firmware_memory_map.READ_TRY_LIMIT)
			bootscreen.put(&text, " reads")
			stop(string(text.bytes[:text.count]))
		}
	}
	if !firmware_memory_map.descriptor_size_valid(u64(descriptor_size)) {
		text: bootscreen.Text
		bootscreen.put(&text, "the memory map of the firmware has descriptors of ")
		bootscreen.put_number(&text, u64(descriptor_size))
		bootscreen.put(&text, " bytes, fewer than the specification")
		stop(string(text.bytes[:text.count]))
	}
	descriptor_end := uint(size_of(Efi_Memory_Descriptor))
	usable_count := 0
	for offset := uint(0); offset + descriptor_end <= size; offset += descriptor_size {
		descriptor := (^Efi_Memory_Descriptor)(uintptr(firmware_map.address) + uintptr(offset))
		if memory_kind_of(descriptor) != .Reserved && descriptor.page_count != 0 {
			usable_count += 1
		}
	}
	fits: bool
	list, fits = firmware_memory_map.list_begin(ranges[:firmware_memory_map.RANGE_CAPACITY], usable_count)
	if !fits {
		text: bootscreen.Text
		bootscreen.put(&text, "the memory map of the firmware has ")
		bootscreen.put_number(&text, u64(usable_count))
		bootscreen.put(&text, " ranges of usable memory; the boot record holds ")
		bootscreen.put_number(&text, firmware_memory_map.RANGE_CAPACITY)
		stop(string(text.bytes[:text.count]))
	}
	for offset := uint(0); offset + descriptor_end <= size; offset += descriptor_size {
		descriptor := (^Efi_Memory_Descriptor)(uintptr(firmware_map.address) + uintptr(offset))
		if !firmware_memory_map.list_add(&list, descriptor.physical_start, descriptor.page_count, memory_kind_of(descriptor)) {
			// The two walks read one buffer: this is a fault of the count.
			stop("the usable ranges of the memory map do not fit the room that the boot program counted for them")
		}
	}
	return
}

// memory_kind_of gives what a descriptor of the firmware holds for the
// kernel. The specification keeps the types past Persistent for the vendor
// of the firmware and for the operating system: the kernel does not know
// such memory, so it is reserved, as each type that the kernel must not
// take.
memory_kind_of :: proc "contextless" (descriptor: ^Efi_Memory_Descriptor) -> info.Memory_Kind {
	type, known := enum_word.member_of_word(Efi_Memory_Type, u64(descriptor.type))
	if !known {
		return .Reserved
	}
	switch type {
	case .Conventional:
		return .Free
	case .Loader_Code, .Loader_Data:
		return .Boot
	case .Reserved, .Boot_Services_Code, .Boot_Services_Data, .Runtime_Services_Code, .Runtime_Services_Data, .Unusable, .Acpi_Reclaim, .Acpi_Storage, .Device, .Device_Ports, .Processor_Code, .Persistent:
		return .Reserved
	}
	return .Reserved
}

// dropped_ranges_line writes, on the serial port, the reserved ranges that
// the list left out. It runs after the end of the firmware services, when
// the console of the firmware is gone; the kernel reads the address of no
// range as it reads a reserved one.
dropped_ranges_line :: proc "contextless" (list: ^firmware_memory_map.Range_List) {
	if list.dropped_count == 0 {
		return
	}
	text: bootscreen.Text
	bootscreen.put(&text, "boot program: the memory map has more ranges than the ")
	bootscreen.put_number(&text, firmware_memory_map.RANGE_CAPACITY)
	bootscreen.put(&text, " of the boot record: ")
	serial_port_print(string(text.bytes[:text.count]))
	text.count = 0
	bootscreen.put_number(&text, list.dropped_count)
	bootscreen.put(&text, " reserved ranges of ")
	bootscreen.put_number(&text, list.dropped_pages)
	bootscreen.put(&text, " pages are left out, and the kernel reads them as reserved\r\n")
	serial_port_print(string(text.bytes[:text.count]))
}

// framebuffer chooses a graphics mode and gives its description.
framebuffer :: proc "contextless" () -> (result: info.Framebuffer) {
	guid := EFI_GRAPHICS_OUTPUT_GUID
	graphics: ^Efi_Graphics_Output
	if system.boot_services.locate_protocol(&guid, nil, (^rawptr)(&graphics)) != 0 || graphics == nil {
		print("boot program: no graphics output\r\n")
		return
	}
	for mode in 0 ..< graphics.mode.mode_count {
		size: uint
		mode_info: ^Efi_Graphics_Mode_Info
		if graphics.query_mode(graphics, mode, &size, &mode_info) != 0 {
			continue
		}
		if mode_info.width == PREFERRED_WIDTH && mode_info.height == PREFERRED_HEIGHT && mode_info.format <= .Blue_Green_Red {
			graphics.set_mode(graphics, mode)
			break
		}
	}
	mode_info := graphics.mode.info
	result = {
		address         = graphics.mode.framebuffer_base,
		width           = mode_info.width,
		height          = mode_info.height,
		pixels_per_line = mode_info.pixels_per_line,
	}
	// The firmware writes the format: a word that names no format gives no
	// display, as a format with no pixels in memory does.
	format, format_ok := enum_word.member_of_word(Efi_Pixel_Format, u64(mode_info.format))
	if !format_ok {
		return {}
	}
	switch format {
	case .Red_Green_Blue:
		result.format = .Red_Green_Blue_X
	case .Blue_Green_Red:
		result.format = .Blue_Green_Red_X
	case .Bit_Mask, .Blt_Only:
		result = {}
	}
	return
}

// allocate gives zero pages that stay in use after the boot program.
allocate :: proc "contextless" (page_count: u64) -> rawptr {
	address: u64
	if system.boot_services.allocate_pages(.Any, .Loader_Data, uint(page_count), &address) != 0 {
		text: bootscreen.Text
		bootscreen.put(&text, "the firmware gives no memory for ")
		bootscreen.put_number(&text, page_count)
		bootscreen.put(&text, " pages")
		stop(string(text.bytes[:text.count]))
	}
	intrinsics.mem_zero(rawptr(uintptr(address)), int(page_count * PAGE_SIZE))
	return rawptr(uintptr(address))
}

// stop writes why the boot program cannot go on, then shows it and waits,
// as a refusal of trust does (boot_stop), at the step of stop_step.
stop :: proc "contextless" (text: string) -> ! {
	print("boot program: ")
	print(text)
	print("\r\n")
	boot_stop(stop_record, stop_step, text)
}

// boot_stop shows a failure of the boot program and keeps it. The watchdog
// of the firmware restarts the machine after 5 minutes and starts the same
// boot program again: the boot program turns the watchdog off, so the
// failure stays until the machine is stopped by hand. With no record or no
// screen, the line that the caller wrote stays on the console of the
// firmware. A power off would remove the failure before anyone reads it.
boot_stop :: proc "contextless" (boot: ^info.Boot_Info, step: bootscreen.Step, text: string) -> ! {
	if boot != nil && display(boot, text, .Failed, step) {
		// After the draw, print writes on the serial port only.
		print("boot program: the boot display shows the failure\r\n")
	} else {
		print("boot program: no boot display: the failure stays on the console of the firmware\r\n")
	}
	system.boot_services.set_watchdog_timer(0, 0, 0, nil)
	for {
		intrinsics.cpu_relax()
	}
}

// Set when the boot display is on the screen. The console of the firmware
// writes on the screen as well as on the serial port: after the first draw
// of the display, each line goes to the serial port only, so that no text
// lies over the display.
display_on_screen := false

// print writes ASCII text on the firmware console, which takes UTF-16; after
// the first draw of the boot display, on the serial port only.
print :: proc "contextless" (text: string) {
	if display_on_screen {
		serial_port_print(text)
		return
	}
	buffer: [128]u16
	count := 0
	for i in 0 ..< len(text) {
		if count == len(buffer) - 1 {
			buffer[count] = 0
			system.console_out.output_string(system.console_out, raw_data(buffer[:]))
			count = 0
		}
		buffer[count] = u16(text[i])
		count += 1
	}
	buffer[count] = 0
	system.console_out.output_string(system.console_out, raw_data(buffer[:]))
}

// The Odin runtime refers to these two symbols on a Windows object target.
// The C runtime normally defines them; this program has none.

@(export, link_name = "_fltused")
_fltused: i32 = 0x9875

@(export, link_name = "_tls_index")
_tls_index: u32

// display draws the boot display (package bootscreen) with what the boot
// program knows; drawn is false with no screen. The kernel does not draw:
// the root service draws the display again with the records of the kernel.
display :: proc "contextless" (boot: ^info.Boot_Info, message: string, state := bootscreen.State.Running, step := bootscreen.Step.Kernel) -> (drawn: bool) {
	screen := boot.framebuffer
	if screen.address == 0 || screen.format == .None {
		return false
	}
	display_on_screen = true
	data := &display_data
	data.boot.firmware_vendor = boot.firmware_vendor
	data.boot.firmware_revision = boot.firmware_revision
	data.boot.framebuffer_address = screen.address
	data.boot.framebuffer_width = u64(screen.width)
	data.boot.framebuffer_height = u64(screen.height)
	data.boot.framebuffer_line = u64(screen.pixels_per_line)
	data.boot.framebuffer_format = u64(screen.format)
	data.boot.kernel_size = boot.kernel_size
	data.boot.kernel_file_size = boot.kernel_file_size
	data.boot.boot_image_size = boot.boot_image_size
	data.boot.acpi_root = boot.acpi_root
	data.boot.trust = boot.trust
	data.image = boot_image
	data.processor_name = bootscreen.processor_name()
	data.message = message
	data.state = state
	data.step = step
	data.red_first = screen.format == .Red_Green_Blue_X
	bootscreen.draw_screen({pixels = ([^]graphics.Color)(uintptr(screen.address)), width = int(screen.width), height = int(screen.height), stride = int(screen.pixels_per_line)}, data)
	return true
}
