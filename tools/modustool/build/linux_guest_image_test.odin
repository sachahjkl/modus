#+build !freestanding
package build

import "core:strconv"
import "core:strings"
import "core:testing"

// Cpio_Read is one entry of the archive as a reader of the form newc reads it.
@(private = "file")
Cpio_Read :: struct {
	name:  string,
	mode:  u64,
	data:  []u8,
	major: u64,
	minor: u64,
}

// cpio_read_all reads the archive whole, as Linux reads it: each header at
// a multiple of 4, its magic, its name with its zero byte, its data, up to
// the trailer. false at the first fault.
@(private = "file")
cpio_read_all :: proc(archive: []u8) -> (entries: [dynamic]Cpio_Read, ok: bool) {
	field :: proc(header: []u8, index: int) -> u64 {
		value, _ := strconv.parse_u64_of_base(string(header[6 + index * 8:][:8]), 16)
		return value
	}
	at := 0
	for {
		if at % 4 != 0 || at + 110 > len(archive) || string(archive[at:][:6]) != "070701" {
			return entries, false
		}
		header := archive[at:][:110]
		name_size := int(field(header, 11))
		data_size := int(field(header, 6))
		name_start := at + 110
		if name_size == 0 || name_start + name_size > len(archive) || archive[name_start + name_size - 1] != 0 {
			return entries, false
		}
		name := string(archive[name_start:][:name_size - 1])
		data_start := (name_start + name_size + 3) &~ 3
		if data_start + data_size > len(archive) {
			return entries, false
		}
		if name == "TRAILER!!!" {
			return entries, data_start + data_size <= len(archive)
		}
		append(&entries, Cpio_Read{name = name, mode = field(header, 1), data = archive[data_start:][:data_size], major = field(header, 9), minor = field(header, 10)})
		at = (data_start + data_size + 3) &~ 3
	}
}

// The archive of the guest: each entry reads back, the init of busybox is
// /init, the console, the serial port and hvc0 are nodes, each module is
// in its folder and the script loads each in order, the transport with the
// windows of the command line, the shell runs on hvc0, and poweroff halts.
@(test)
linux_guest_initial_archive_reads_back :: proc(t: ^testing.T) {
	busybox := []u8{0x7F, 'E', 'L', 'F', 1, 2, 3}
	modules: [Linux_Guest_Module][]u8
	for &module, index in modules {
		module = []u8{0x7F, 'E', 'L', 'F', u8(index)}
	}
	archive := linux_guest_initial_archive(busybox, modules)
	testing.expect_value(t, len(archive) % 4, 0)
	entries, ok := cpio_read_all(archive)
	defer delete(entries)
	testing.expect(t, ok)
	find :: proc(entries: []Cpio_Read, name: string) -> (entry: Cpio_Read, found: bool) {
		for candidate in entries {
			if candidate.name == name {
				return candidate, true
			}
		}
		return {}, false
	}
	init, has_init := find(entries[:], "init")
	testing.expect(t, has_init && init.mode == 0o120777 && string(init.data) == "bin/busybox")
	file, has_file := find(entries[:], "bin/busybox")
	testing.expect(t, has_file && file.mode == 0o100755 && string(file.data) == string(busybox))
	console, has_console := find(entries[:], "dev/console")
	testing.expect(t, has_console && console.mode == 0o020600 && console.major == 5 && console.minor == 1)
	serial, has_serial := find(entries[:], "dev/ttyS0")
	testing.expect(t, has_serial && serial.major == 4 && serial.minor == 64)
	poweroff, has_poweroff := find(entries[:], "sbin/poweroff")
	testing.expect(t, has_poweroff && string(poweroff.data) == LINUX_GUEST_POWEROFF)
	inittab, has_inittab := find(entries[:], "etc/inittab")
	testing.expect(t, has_inittab && string(inittab.data) == LINUX_GUEST_INITTAB)
	testing.expect(t, strings.contains(LINUX_GUEST_INITTAB, "hvc0::respawn:-/bin/sh"), "the shell runs on hvc0")
	testing.expect(t, !strings.contains(LINUX_GUEST_INITTAB, "ttyS0::"), "no shell runs on the serial port")
	hvc, has_hvc := find(entries[:], "dev/hvc0")
	testing.expect(t, has_hvc && hvc.major == 229 && hvc.minor == 0)
	files := LINUX_GUEST_MODULE_FILES
	script, has_script := find(entries[:], "etc/modules.sh")
	testing.expect(t, has_script)
	last_place := -1
	for module in Linux_Guest_Module {
		path := strings.concatenate({LINUX_GUEST_MODULES_FOLDER, "/", files[module]}, context.temp_allocator)
		entry, found := find(entries[:], path)
		testing.expectf(t, found && string(entry.data) == string(modules[module]), "the module %v is in the archive", module)
		place := strings.index(string(script.data), strings.concatenate({"insmod /", path}, context.temp_allocator))
		testing.expectf(t, place > last_place, "the module %v loads after the modules that it needs", module)
		last_place = place
	}
	testing.expect(t, strings.contains(string(script.data), "virtio_mmio.ko $devices"), "the transport takes the windows of the command line")
	// A cut archive is refused at its cut, as Linux refuses it.
	for cut in ([?]int{0, 1, 109, 110, len(archive) - 4, len(archive) - 1}) {
		cut_entries, cut_ok := cpio_read_all(archive[:cut])
		delete(cut_entries)
		testing.expectf(t, !cut_ok, "the archive cut at %v is refused", cut)
	}
}
