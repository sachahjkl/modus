#+build !freestanding
package build

import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"
import info "modus:contract/boot_info"

// A module of the binary format with one import section and one export
// section, built byte by byte.
@(private = "file")
webassembly_module_bytes :: proc(sections: ..[]u8) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	append(&bytes, ..transmute([]u8)string(WEBASSEMBLY_MAGIC))
	append(&bytes, ..transmute([]u8)string(WEBASSEMBLY_VERSION))
	for section in sections {
		append(&bytes, ..section)
	}
	return bytes[:]
}

@(private = "file")
webassembly_section :: proc(id: u8, content: []u8) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	append(&bytes, id)
	// The length in LEB128: a section of the border passes 127 bytes.
	length := len(content)
	for {
		next := u8(length & 0x7F)
		length >>= 7
		if length == 0 {
			append(&bytes, next)
			break
		}
		append(&bytes, next | 0x80)
	}
	append(&bytes, ..content)
	return bytes[:]
}

@(private = "file")
webassembly_name :: proc(bytes: ^[dynamic]u8, name: string) {
	append(bytes, u8(len(name)))
	append(bytes, ..transmute([]u8)name)
}

// The border of the kernel as the page gives it: each import a function of
// modus_page, and the three exports.
@(private = "file")
webassembly_kernel_border :: proc() -> []u8 {
	imports := make([dynamic]u8, context.temp_allocator)
	names := BROWSER_MACHINE_IMPORT_NAMES
	append(&imports, u8(len(names)))
	for name in names {
		webassembly_name(&imports, BROWSER_MACHINE_IMPORT_MODULE)
		webassembly_name(&imports, name)
		append(&imports, u8(Webassembly_External_Kind.Function), 0)
	}
	exports := make([dynamic]u8, context.temp_allocator)
	expected := BROWSER_MACHINE_EXPORTS
	append(&exports, u8(len(expected)))
	for item in expected {
		webassembly_name(&exports, item.name)
		append(&exports, u8(item.kind), 0)
	}
	// A type section before them: a section that the reader skips.
	return webassembly_module_bytes(webassembly_section(1, {1, 0x60, 0, 0}), webassembly_section(WEBASSEMBLY_SECTION_IMPORT, imports[:]), webassembly_section(WEBASSEMBLY_SECTION_EXPORT, exports[:]))
}

@(test)
webassembly_border_read_refuses_what_is_not_a_module :: proc(t: ^testing.T) {
	for bytes in ([][]u8{{}, {0, 'a', 's'}, {0, 'a', 's', 'm', 2, 0, 0, 0}, {'a', 's', 'm', 0, 1, 0, 0, 0}}) {
		_, _, fault := webassembly_border_read(bytes, context.temp_allocator)
		testing.expect_value(t, fault, Webassembly_Read_Fault.Not_Webassembly)
	}
}

@(test)
webassembly_border_read_refuses_damaged_sections :: proc(t: ^testing.T) {
	// A section longer than the bytes that follow it.
	_, _, fault := webassembly_border_read(webassembly_module_bytes({WEBASSEMBLY_SECTION_IMPORT, 9, 1}), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Truncated)
	// A length whose LEB128 never ends within 64 bits.
	_, _, fault = webassembly_border_read(webassembly_module_bytes({1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01}), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Number_Too_Long)
	// An export of the kind 5, which names no kind.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_EXPORT, {1, 1, 'x', 5, 0})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Unknown_Kind)
	// An imported memory whose limits have the flag 8.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_IMPORT, {1, 1, 'm', 1, 'x', 2, 8, 1})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Unknown_Limits)
	// A count of two imports with the bytes of one.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_IMPORT, {2, 1, 'm', 1, 'x', 0, 0})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Truncated)
	// An import section with bytes after its last import.
	_, _, fault = webassembly_border_read(webassembly_module_bytes(webassembly_section(WEBASSEMBLY_SECTION_IMPORT, {1, 1, 'm', 1, 'x', 0, 0, 7})), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.Truncated)
}

@(test)
browser_machine_border_faults_name_each_difference :: proc(t: ^testing.T) {
	imports, exports, fault := webassembly_border_read(webassembly_kernel_border(), context.temp_allocator)
	testing.expect_value(t, fault, Webassembly_Read_Fault.None)
	names := BROWSER_MACHINE_IMPORT_NAMES
	testing.expect_value(t, len(imports), len(names))
	testing.expect_value(t, len(exports), len(BROWSER_MACHINE_EXPORTS))

	// An import that the page does not give, and one that is missing.
	changed := make([dynamic]Webassembly_Import, context.temp_allocator)
	append(&changed, ..imports[1:])
	append(&changed, Webassembly_Import{module = "env", name = "memcpy", kind = .Function})
	testing.expect_value(t, len(browser_machine_border_faults(changed[:], exports[:], context.temp_allocator)), 2)
	// An import of the right name with the kind of a memory.
	changed[len(changed) - 1] = {module = BROWSER_MACHINE_IMPORT_MODULE, name = imports[0].name, kind = .Memory}
	testing.expect_value(t, len(browser_machine_border_faults(changed[:], exports[:], context.temp_allocator)), 1)
	// An import twice.
	twice := make([dynamic]Webassembly_Import, context.temp_allocator)
	append(&twice, ..imports[:])
	append(&twice, imports[0])
	testing.expect_value(t, len(browser_machine_border_faults(twice[:], exports[:], context.temp_allocator)), 1)
	// The memory exported as a function, and an export more.
	wrong_exports := make([dynamic]Webassembly_Export, context.temp_allocator)
	append(&wrong_exports, ..exports[:])
	wrong_exports[0].kind = .Function
	append(&wrong_exports, Webassembly_Export{name = "modus_vm_init", kind = .Function})
	testing.expect_value(t, len(browser_machine_border_faults(imports[:], wrong_exports[:], context.temp_allocator)), 3)
	// No export at all.
	testing.expect_value(t, len(browser_machine_border_faults(imports[:], {}, context.temp_allocator)), len(BROWSER_MACHINE_EXPORTS))

	// Last: the border of the kernel has no fault.
	testing.expect_value(t, len(browser_machine_border_faults(imports[:], exports[:], context.temp_allocator)), 0)
}

// The text of the host of the page.
@(private = "file")
browser_machine_host_text :: proc() -> string {
	files := BROWSER_MACHINE_PAGE_FILES
	for file in files {
		if file.name == BROWSER_MACHINE_HOST_FILE {
			return file.text
		}
	}
	return ""
}

// The numbers of one object of the host, as "name: number," lines between
// "export const <name> = {" and the next "};" (or "}" on one line).
@(private = "file")
host_object_numbers :: proc(t: ^testing.T, constant: string) -> map[string]int {
	numbers := make(map[string]int, context.temp_allocator)
	text := browser_machine_host_text()
	start := strings.index(text, strings.concatenate({"export const ", constant, " = {"}, context.temp_allocator))
	if !testing.expectf(t, start >= 0, "the host names no %s", constant) {
		return numbers
	}
	body := text[start + strings.index_byte(text[start:], '{') + 1:]
	body = body[:strings.index_byte(body, '}')]
	for part in strings.split(body, ",", context.temp_allocator) {
		name, separator, number := strings.partition(part, ":")
		if len(separator) == 0 {
			continue
		}
		value, parsed := strconv.parse_int(strings.trim_space(number))
		testing.expectf(t, parsed, "%s.%s is not a number", constant, strings.trim_space(name))
		numbers[strings.trim_space(name)] = value
	}
	return numbers
}

@(private = "file")
expect_offsets :: proc(t: ^testing.T, constant: string, $T: typeid) {
	numbers := host_object_numbers(t, constant)
	fields := reflect.struct_fields_zipped(T)
	testing.expectf(t, len(numbers) == len(fields), "%s has %d fields, and %v has %d", constant, len(numbers), typeid_of(T), len(fields))
	for field in fields {
		offset, found := numbers[field.name]
		testing.expectf(t, found && offset == int(field.offset), "%s.%s is %d; offset_of is %d", constant, field.name, offset, field.offset)
	}
}

// The host writes the boot record at the offsets of the record that the
// kernel reads: a field moved in boot_info.odin fails here, not in a page.
@(test)
browser_machine_host_writes_the_boot_record_of_the_kernel :: proc(t: ^testing.T) {
	expect_offsets(t, "BOOT_INFO_OFFSETS", info.Boot_Info)
	expect_offsets(t, "FRAMEBUFFER_OFFSETS", info.Framebuffer)
	expect_offsets(t, "MEMORY_RANGE_OFFSETS", info.Memory_Range)
	text := browser_machine_host_text()
	testing.expect(t, strings.contains(text, strings.concatenate({"export const BOOT_INFO_SIZE = ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(size_of(info.Boot_Info)), 10), ";"}, context.temp_allocator)))
	testing.expect(t, strings.contains(text, strings.concatenate({"export const MEMORY_RANGE_SIZE = ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(size_of(info.Memory_Range)), 10), ";"}, context.temp_allocator)))
	for kind in info.Memory_Kind {
		testing.expectf(t, strings.contains(text, strings.concatenate({reflect.enum_string(kind), ": ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(kind), 10)}, context.temp_allocator)), "the host names no Memory_Kind %v", kind)
	}
	for format in info.Pixel_Format {
		testing.expectf(t, strings.contains(text, strings.concatenate({reflect.enum_string(format), ": ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(format), 10)}, context.temp_allocator)), "the host names no Pixel_Format %v", format)
	}
}

// The host gives each import that the tool checks in the kernel, and calls
// each export.
@(test)
browser_machine_host_names_the_border_of_the_tool :: proc(t: ^testing.T) {
	text := browser_machine_host_text()
	testing.expect(t, strings.contains(text, strings.concatenate({"export const PAGE_IMPORT_MODULE = \"", BROWSER_MACHINE_IMPORT_MODULE, "\";"}, context.temp_allocator)))
	names := BROWSER_MACHINE_IMPORT_NAMES
	for name in names {
		testing.expectf(t, strings.contains(text, strings.concatenate({"  \"", name, "\",\n"}, context.temp_allocator)), "PAGE_IMPORT_NAMES names no %s", name)
		testing.expectf(t, strings.contains(text, strings.concatenate({"        ", name, ": "}, context.temp_allocator)), "the imports of the machine give no %s", name)
	}
	exports := BROWSER_MACHINE_EXPORTS
	for item in exports {
		testing.expectf(t, strings.contains(text, strings.concatenate({"\"", item.name, "\""}, context.temp_allocator)), "KERNEL_EXPORT_NAMES names no %s", item.name)
	}
	// And each import of the host is an import of the tool: a name added
	// to the host and to the kernel alone fails here, not at the build.
	start := strings.index(text, "export const PAGE_IMPORT_NAMES = [")
	if !testing.expect(t, start >= 0, "the host names no PAGE_IMPORT_NAMES") {
		return
	}
	body := text[start + strings.index_byte(text[start:], '[') + 1:]
	body = body[:strings.index_byte(body, ']')]
	host_count := 0
	for part in strings.split(body, ",", context.temp_allocator) {
		name := strings.trim(strings.trim_space(part), "\"")
		if len(name) == 0 {
			continue
		}
		host_count += 1
		known := false
		for tool_name in names {
			known ||= tool_name == name
		}
		testing.expectf(t, known, "the host gives %s, which BROWSER_MACHINE_IMPORT_NAMES does not name", name)
	}
	testing.expect_value(t, host_count, len(names))
}

// The line of the framebuffer of the Node program: each form that is not
// "framebuffer: <lit> <pixels>" with lit at most pixels is refused.
@(test)
browser_machine_framebuffer_line_refuses_each_damaged_form :: proc(t: ^testing.T) {
	refused := []string {
		"",
		"framebuffer:",
		"framebuffer: ",
		"framebuffer: 12",
		"framebuffer: 12 ",
		"framebuffer:  12 100",
		"framebuffer: -1 100",
		"framebuffer: 12 x",
		"framebuffer: 101 100",
		"framebuffer: 0 0",
		"framebuffer: 1 18446744073709551616",
		"Framebuffer: 1 100",
		"serial: framebuffer: 1 100",
	}
	for line in refused {
		_, _, ok := browser_machine_framebuffer_line_parse(line)
		testing.expectf(t, !ok, "%q is read", line)
	}
	lit, pixels, ok := browser_machine_framebuffer_line_parse("framebuffer: 0 1024000")
	testing.expect(t, ok)
	testing.expect_value(t, lit, u64(0))
	testing.expect_value(t, pixels, u64(1024000))
	lit, pixels, ok = browser_machine_framebuffer_line_parse("framebuffer: 1024000 1024000")
	testing.expect(t, ok && lit == 1024000 && pixels == 1024000)
}

// The host raises the lines that the kernel delivers to the input service,
// and the import that gives them to the kernel is in the imports of the
// machine.
@(test)
browser_machine_host_raises_the_lines_of_the_input_service :: proc(t: ^testing.T) {
	text := browser_machine_host_text()
	lines := host_object_numbers(t, "InterruptLine")
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines["Keyboard"], 1)
	testing.expect_value(t, lines["Mouse"], 12)
	testing.expect(t, strings.contains(text, "page_interrupt_lines_take: () => machine.interruptLinesTake(),"))
	// The command that the boot types needs only keys of the layout.
	testing.expect(t, strings.contains(text, "[\"Digit9\", \"9\", \"(\"]"))
	testing.expect(t, strings.contains(text, "[\"Digit0\", \"0\", \")\"]"))
	for character in BROWSER_MACHINE_TYPED_COMMAND {
		testing.expectf(t, (character >= 'a' && character <= 'z') || character == '(' || character == ')', "the command has %q, which the test does not find in the layout", character)
	}
}

// Each file of the page that another file names is a file of the page.
@(test)
browser_machine_page_files_name_each_other :: proc(t: ^testing.T) {
	files := BROWSER_MACHINE_PAGE_FILES
	text_of :: proc(files: []Browser_Machine_Page_File, name: string) -> string {
		for file in files {
			if file.name == name {
				return file.text
			}
		}
		return ""
	}
	testing.expect(t, strings.has_prefix(text_of(files[:], "browser_machine.html"), "<!doctype html>"))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine.html"), "src=\"browser_machine_page.js\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_page.js"), "new Worker(\"browser_machine_worker.js\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_page.js"), "\"" + BROWSER_MACHINE_KERNEL_FILE + "\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_page.js"), "\"" + BROWSER_MACHINE_BOOT_IMAGE_FILE + "\""))
	testing.expect(t, strings.contains(text_of(files[:], "browser_machine_worker.js"), "from \"./" + BROWSER_MACHINE_HOST_FILE + "\""))
	for file in files {
		testing.expectf(t, len(file.text) > 0, "%s is empty", file.name)
	}
}
