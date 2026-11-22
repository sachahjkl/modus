// The browser machine of the tool: the build of the kernel for
// WebAssembly, the check of its border with the page, the folder of the
// page, and its start in Node (src/md/features/browser_machine.md, "The
// page and its host").
package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modustool:foundation"

BROWSER_MACHINE_FOLDER :: foundation.BUILD_FOLDER + "/browser_machine"
BROWSER_MACHINE_KERNEL_FILE :: "modulus_kernel.wasm"
BROWSER_MACHINE_BOOT_IMAGE_FILE :: "boot.image"
BROWSER_MACHINE_HOST_FILE :: "browser_machine_host.js"
BROWSER_MACHINE_KERNEL_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_KERNEL_FILE
BROWSER_MACHINE_BOOT_IMAGE_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_BOOT_IMAGE_FILE
BROWSER_MACHINE_HOST_PATH :: BROWSER_MACHINE_FOLDER + "/" + BROWSER_MACHINE_HOST_FILE

// The lowest major version of Node that runs the host: the version that the
// development shell of the project was checked with.
BROWSER_MACHINE_NODE_MAJOR_VERSION :: 24

// The lines of the kernel that a start in Node must write: its mark, and,
// with a boot image, the line of the stage of the root service.
BROWSER_MACHINE_KERNEL_MARK :: "kernel: ok"
BROWSER_MACHINE_ROOT_STAGE_LINE :: "kernel: boot: kernel: root service: "

// One file of the page of a browser machine. The site writes the same
// files (site_browser_machine.odin).
Browser_Machine_Page_File :: struct {
	name: string,
	text: string,
}

BROWSER_MACHINE_PAGE_FILES :: [?]Browser_Machine_Page_File {
	{"browser_machine.html", #load("browser_machine/browser_machine.html", string)},
	{"browser_machine_page.js", #load("browser_machine/browser_machine_page.js", string)},
	{"browser_machine_worker.js", #load("browser_machine/browser_machine_worker.js", string)},
	{BROWSER_MACHINE_HOST_FILE, #load("browser_machine/browser_machine_host.js", string)},
}

// The border of the kernel with the page: the module of the imports, the
// name of each import (each is a function), and each export. The host of
// the page names the same lists.
BROWSER_MACHINE_IMPORT_MODULE :: "modus_page"
BROWSER_MACHINE_IMPORT_NAMES :: [?]string {
	"page_clock_nanoseconds",
	"page_port_write_8",
	"page_port_read_8",
	"page_processor_loop_unwind",
	"page_processor_stop",
	"page_idle_wait",
}
BROWSER_MACHINE_EXPORTS :: [?]Webassembly_Export {
	{name = "memory", kind = .Memory},
	{name = "entry", kind = .Function},
	{name = "modus_processor_loop_run", kind = .Function},
}

// The kind of an import or an export of a WebAssembly module: the byte of
// its description in the binary format.
Webassembly_External_Kind :: enum u8 {
	Function = 0,
	Table    = 1,
	Memory   = 2,
	Global   = 3,
	Tag      = 4,
}

Webassembly_Import :: struct {
	module, name: string,
	kind:         Webassembly_External_Kind,
}

Webassembly_Export :: struct {
	name: string,
	kind: Webassembly_External_Kind,
}

// Why the read of a WebAssembly module stopped.
Webassembly_Read_Fault :: enum {
	None,
	Not_Webassembly, // The magic number or the version is not the one of the binary format 1.
	Truncated, // A section, a number or a name passes the end of its bytes.
	Number_Too_Long, // A number of LEB128 has more bytes than a number of 64 bits.
	Unknown_Kind, // The byte of a kind names no kind.
	Unknown_Limits, // The flags of the limits of a table or a memory name no form.
}

WEBASSEMBLY_MAGIC :: "\x00asm"
WEBASSEMBLY_VERSION :: "\x01\x00\x00\x00"
WEBASSEMBLY_SECTION_IMPORT :: 2
WEBASSEMBLY_SECTION_EXPORT :: 7
// The flags of limits: bit 0 a maximum, bit 1 shared, bit 2 addresses of 64 bits.
WEBASSEMBLY_LIMITS_FLAGS_ALL :: 0x07

@(private = "file")
Webassembly_Reader :: struct {
	bytes: []u8,
	at:    int,
	fault: Webassembly_Read_Fault,
}

@(private = "file")
reader_byte :: proc(reader: ^Webassembly_Reader) -> u8 {
	if reader.fault != .None {
		return 0
	}
	if reader.at >= len(reader.bytes) {
		reader.fault = .Truncated
		return 0
	}
	reader.at += 1
	return reader.bytes[reader.at - 1]
}

@(private = "file")
reader_number :: proc(reader: ^Webassembly_Reader) -> u64 {
	value: u64
	for shift: uint = 0; reader.fault == .None; shift += 7 {
		if shift >= 64 {
			reader.fault = .Number_Too_Long
			return 0
		}
		next := reader_byte(reader)
		value |= u64(next & 0x7F) << shift
		if next & 0x80 == 0 {
			return value
		}
	}
	return 0
}

@(private = "file")
reader_bytes :: proc(reader: ^Webassembly_Reader, count: u64) -> []u8 {
	if reader.fault != .None {
		return nil
	}
	if count > u64(len(reader.bytes) - reader.at) {
		reader.fault = .Truncated
		return nil
	}
	start := reader.at
	reader.at += int(count)
	return reader.bytes[start:reader.at]
}

@(private = "file")
reader_name :: proc(reader: ^Webassembly_Reader) -> string {
	return string(reader_bytes(reader, reader_number(reader)))
}

@(private = "file")
reader_kind :: proc(reader: ^Webassembly_Reader) -> Webassembly_External_Kind {
	word := reader_byte(reader)
	if reader.fault != .None {
		return .Function
	}
	switch word {
	case u8(Webassembly_External_Kind.Function):
		return .Function
	case u8(Webassembly_External_Kind.Table):
		return .Table
	case u8(Webassembly_External_Kind.Memory):
		return .Memory
	case u8(Webassembly_External_Kind.Global):
		return .Global
	case u8(Webassembly_External_Kind.Tag):
		return .Tag
	}
	reader.fault = .Unknown_Kind
	return .Function
}

@(private = "file")
reader_limits :: proc(reader: ^Webassembly_Reader) {
	flags := reader_byte(reader)
	if flags & ~u8(WEBASSEMBLY_LIMITS_FLAGS_ALL) != 0 {
		if reader.fault == .None {
			reader.fault = .Unknown_Limits
		}
		return
	}
	_ = reader_number(reader)
	if flags & 1 != 0 {
		_ = reader_number(reader)
	}
}

// webassembly_border_read reads the imports and the exports of a
// WebAssembly module. The names are slices of bytes.
webassembly_border_read :: proc(bytes: []u8, allocator := context.allocator) -> (imports: [dynamic]Webassembly_Import, exports: [dynamic]Webassembly_Export, fault: Webassembly_Read_Fault) {
	imports = make([dynamic]Webassembly_Import, allocator)
	exports = make([dynamic]Webassembly_Export, allocator)
	if len(bytes) < 8 || string(bytes[:4]) != WEBASSEMBLY_MAGIC || string(bytes[4:8]) != WEBASSEMBLY_VERSION {
		return imports, exports, .Not_Webassembly
	}
	reader := Webassembly_Reader{bytes = bytes, at = 8}
	for reader.fault == .None && reader.at < len(bytes) {
		section := reader_byte(&reader)
		content := reader_bytes(&reader, reader_number(&reader))
		if reader.fault != .None {
			break
		}
		if section != WEBASSEMBLY_SECTION_IMPORT && section != WEBASSEMBLY_SECTION_EXPORT {
			continue
		}
		inner := Webassembly_Reader{bytes = content}
		count := reader_number(&inner)
		for _ in 0 ..< count {
			if inner.fault != .None {
				break
			}
			if section == WEBASSEMBLY_SECTION_EXPORT {
				name := reader_name(&inner)
				kind := reader_kind(&inner)
				_ = reader_number(&inner)
				append(&exports, Webassembly_Export{name = name, kind = kind})
				continue
			}
			module := reader_name(&inner)
			name := reader_name(&inner)
			kind := reader_kind(&inner)
			switch kind {
			case .Function, .Tag:
				if kind == .Tag {
					_ = reader_byte(&inner)
				}
				_ = reader_number(&inner)
			case .Table:
				_ = reader_byte(&inner)
				reader_limits(&inner)
			case .Memory:
				reader_limits(&inner)
			case .Global:
				_ = reader_byte(&inner)
				_ = reader_byte(&inner)
			}
			append(&imports, Webassembly_Import{module = module, name = name, kind = kind})
		}
		if inner.fault != .None {
			reader.fault = inner.fault
		} else if inner.at != len(content) {
			reader.fault = .Truncated
		}
	}
	return imports, exports, reader.fault
}

// browser_machine_border_faults lists each difference between the border
// of a kernel and the border that the page gives: an import or an export
// that the page does not know, one that is missing, and one that comes
// twice. No fault: the kernel runs on the host of the page.
browser_machine_border_faults :: proc(imports: []Webassembly_Import, exports: []Webassembly_Export, allocator := context.allocator) -> []string {
	faults := make([dynamic]string, allocator)
	import_names := BROWSER_MACHINE_IMPORT_NAMES
	for item in imports {
		known := item.module == BROWSER_MACHINE_IMPORT_MODULE && item.kind == .Function
		if known {
			known = false
			for name in import_names {
				known ||= name == item.name
			}
		}
		if !known {
			append(&faults, fmt.aprintf("the import %s.%s (%v) is not an import that the page gives", item.module, item.name, item.kind, allocator = allocator))
		}
	}
	for name in import_names {
		count := 0
		for item in imports {
			count += int(item.module == BROWSER_MACHINE_IMPORT_MODULE && item.name == name)
		}
		if count != 1 {
			append(&faults, fmt.aprintf("the import %s.%s comes %d times, not once", BROWSER_MACHINE_IMPORT_MODULE, name, count, allocator = allocator))
		}
	}
	expected_exports := BROWSER_MACHINE_EXPORTS
	for item in exports {
		known := false
		for expected in expected_exports {
			known ||= expected == item
		}
		if !known {
			append(&faults, fmt.aprintf("the export %s (%v) is not an export that the page calls", item.name, item.kind, allocator = allocator))
		}
	}
	for expected in expected_exports {
		count := 0
		for item in exports {
			count += int(item == expected)
		}
		if count != 1 {
			append(&faults, fmt.aprintf("the export %s (%v) comes %d times, not once", expected.name, expected.kind, count, allocator = allocator))
		}
	}
	return faults[:]
}

// browser_machine_build compiles the kernel for WebAssembly into the folder
// of the page, checks its border, and writes the files of the page beside
// it, with a copy of the boot image of the build when there is one.
browser_machine_build :: proc() -> bool {
	if error := os.make_directory_all(BROWSER_MACHINE_FOLDER); error != nil && error != .Exist {
		fmt.eprintfln("modustool: cannot make %s: %v", BROWSER_MACHINE_FOLDER, error)
		return false
	}
	kernel := BROWSER_MACHINE_KERNEL_PATH
	if !foundation.run({"odin", "build", foundation.SOURCE_FOLDER_KERNEL, "-target:freestanding_wasm64p32", "-no-entry-point", "-default-to-nil-allocator", foundation.SOURCE_LIBRARY_FLAG, foundation.INTERNAL_LIBRARY_FLAG, foundation.KERNEL_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG, "-out:" + BROWSER_MACHINE_KERNEL_PATH}) {
		return false
	}
	bytes, read_error := os.read_entire_file(kernel, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", kernel, read_error)
		return false
	}
	imports, exports, fault := webassembly_border_read(bytes, context.temp_allocator)
	if fault != .None {
		fmt.eprintfln("modustool: %s is not a WebAssembly module that the tool reads: %v", kernel, fault)
		return false
	}
	faults := browser_machine_border_faults(imports[:], exports[:], context.temp_allocator)
	for line in faults {
		fmt.eprintfln("modustool: %s: %s", kernel, line)
	}
	if len(faults) != 0 {
		return false
	}
	fmt.printfln("modustool: %s: %d bytes, %d imports of %s, the exports %d", kernel, len(bytes), len(imports), BROWSER_MACHINE_IMPORT_MODULE, len(exports))
	files := BROWSER_MACHINE_PAGE_FILES
	for file in files {
		path := strings.concatenate({BROWSER_MACHINE_FOLDER, "/", file.name}, context.temp_allocator)
		if error := os.write_entire_file(path, transmute([]u8)file.text); error != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", path, error)
			return false
		}
	}
	if os.is_file(BOOT_IMAGE) {
		return browser_machine_boot_image_copy(BOOT_IMAGE)
	}
	return true
}

@(private = "file")
browser_machine_boot_image_copy :: proc(source: string) -> bool {
	bytes, read_error := os.read_entire_file(source, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", source, read_error)
		return false
	}
	if write_error := os.write_entire_file(BROWSER_MACHINE_BOOT_IMAGE_PATH, bytes); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BROWSER_MACHINE_BOOT_IMAGE_PATH, write_error)
		return false
	}
	return true
}

// The program that Node runs: it imports the host of the page, starts the
// kernel with a boot image or none, prints each line of the serial port,
// and ends when the machine stops or at the bound. Its arguments: the host
// module, the kernel, the boot image (empty: none), the bound in
// milliseconds. Its last line is "machine: <state> <stop code> <trap>".
BROWSER_MACHINE_NODE_PROGRAM :: `
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
const [hostPath, kernelPath, imagePath, boundText] = process.argv.slice(1);
const host = await import(pathToFileURL(resolve(hostPath)).href);
const kernelModule = await WebAssembly.compile(readFileSync(kernelPath));
const bootImage = imagePath ? new Uint8Array(readFileSync(imagePath)) : undefined;
const idleWord = new Int32Array(new SharedArrayBuffer(4));
const machine = new host.BrowserMachine({
  kernelModule, bootImage, memoryMebibytes: 512, framebufferWidth: 1280, framebufferHeight: 800,
  clockNanoseconds: () => process.hrtime.bigint(),
  idleWait: (bound) => { Atomics.wait(idleWord, 0, 0, Number(bound) / 1e6); },
  onSerialLine: (line) => console.log("serial: " + line),
});
await machine.start();
const end = Date.now() + Number(boundText);
while (machine.state === host.MachineState.Running && Date.now() < end) {
  if (machine.runSlice(10000000) === host.LoopResult.Idle) Atomics.wait(idleWord, 0, 0, 1);
}
const trap = machine.trap ? String(machine.trap).replace(/\s+/g, " ") : "";
console.log("machine: " + machine.state + " " + machine.stopCode + " " + trap);
`

// browser_machine_node_major gives the major version of the node of the
// host; 0 when there is none.
@(private = "file")
browser_machine_node_major :: proc() -> int {
	state, output, _, error := os.process_exec({command = {"node", "--version"}}, context.temp_allocator)
	if error != nil || !state.success {
		return 0
	}
	text := strings.trim_space(string(output))
	if !strings.has_prefix(text, "v") {
		return 0
	}
	major := 0
	for character in text[1:] {
		if character < '0' || character > '9' {
			break
		}
		major = major * 10 + int(character - '0')
	}
	return major
}

// browser_machine_boot starts the kernel of the folder in Node with the
// host of the page, prints each line of its serial port, and checks the
// mark of the kernel and, with a boot image, the start of the root service.
browser_machine_boot :: proc(boot_image: string) -> bool {
	if major := browser_machine_node_major(); major < BROWSER_MACHINE_NODE_MAJOR_VERSION {
		fmt.eprintfln("modustool: browser-machine boot needs node %d or later on the path; found %d (0: none)", BROWSER_MACHINE_NODE_MAJOR_VERSION, major)
		return false
	}
	bound := fmt.tprintf("%d", i64(foundation.HANG_BOUND / time.Millisecond))
	started := time.tick_now()
	state, output, error_output, error := os.process_exec({command = {"node", "--input-type=module", "--eval", BROWSER_MACHINE_NODE_PROGRAM, BROWSER_MACHINE_HOST_PATH, BROWSER_MACHINE_KERNEL_PATH, boot_image, bound}}, context.temp_allocator)
	if error != nil {
		fmt.eprintfln("modustool: cannot start node: %v", error)
		return false
	}
	if !state.success {
		fmt.eprintfln("modustool: node failed (code %d): %s", state.exit_code, string(error_output))
		return false
	}
	mark_seen, root_seen := false, false
	machine_line := ""
	lines := string(output)
	for line in strings.split_lines_iterator(&lines) {
		if strings.has_prefix(line, "serial: ") {
			serial := line[len("serial: "):]
			fmt.println(serial)
			mark_seen ||= serial == BROWSER_MACHINE_KERNEL_MARK
			root_seen ||= strings.has_prefix(serial, BROWSER_MACHINE_ROOT_STAGE_LINE)
		} else if strings.has_prefix(line, "machine: ") {
			machine_line = line
		}
	}
	fmt.printfln("modustool: measure: the browser machine in node: %.1f s, %s", time.duration_seconds(time.tick_since(started)), machine_line)
	if !mark_seen {
		fmt.eprintfln("modustool: the kernel in node wrote no line %q", BROWSER_MACHINE_KERNEL_MARK)
		return false
	}
	if boot_image != "" && !root_seen {
		fmt.eprintfln("modustool: the kernel in node wrote no line that starts with %q", BROWSER_MACHINE_ROOT_STAGE_LINE)
		return false
	}
	if strings.has_prefix(machine_line, "machine: trapped") {
		fmt.eprintln("modustool: the kernel in node ended with a trap of WebAssembly")
		return false
	}
	foundation.test_passed_print("the kernel for WebAssembly starts in node %s", boot_image != "" ? "to the root service" : "to its mark, with no boot image")
	return true
}

// run_browser_machine is the command browser-machine.
run_browser_machine :: proc(args: []string) -> int {
	boot := len(args) >= 1 && args[0] == "boot"
	if len(args) > 2 || (len(args) >= 1 && !boot) {
		fmt.eprintln("modustool: browser-machine takes no argument, or boot [<boot image>]")
		return foundation.EXIT_USAGE
	}
	if !browser_machine_build() {
		return foundation.EXIT_FAILURE
	}
	if !boot {
		return 0
	}
	// The boot image of the page: the one that the command names, else the
	// one of the build that browser_machine_build copied, else none.
	if len(args) == 2 && !browser_machine_boot_image_copy(args[1]) {
		return foundation.EXIT_FAILURE
	}
	boot_image := os.is_file(BROWSER_MACHINE_BOOT_IMAGE_PATH) ? BROWSER_MACHINE_BOOT_IMAGE_PATH : ""
	return browser_machine_boot(boot_image) ? 0 : foundation.EXIT_FAILURE
}
