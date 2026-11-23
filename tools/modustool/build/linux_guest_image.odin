// The initial archive of the guest of the process `linux` in the machine
// test: a cpio archive in the form newc with a static busybox
// (src/md/features/linux_shell.md, "The initial archive of the test").
package build

import "core:fmt"
import "core:os"
import "core:strings"

// The variable of the flake that names the static busybox of Nixpkgs.
LINUX_GUEST_BUSYBOX_VARIABLE :: "MODUS_LINUX_GUEST_BUSYBOX"
// The variable of the flake that names the bzImage of Nixpkgs.
LINUX_KERNEL_IMAGE_VARIABLE :: "MODUS_LINUX_KERNEL_IMAGE"

// The table of init: install the links of the applets, mount the two file
// systems of the kernel, write the line that the test waits for, and run a
// shell on the serial port, again when it ends.
LINUX_GUEST_INITTAB :: `::sysinit:/bin/busybox --install -s /bin
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t sysfs sysfs /sys
::sysinit:/bin/busybox echo modus-guest-ready
ttyS0::respawn:-/bin/sh
`

// poweroff: the machine has no device that turns it off, and the power
// off of Linux then panics; its halt stops the processor, which ends the
// process linux (src/md/features/linux_shell.md, "The end of the guest").
LINUX_GUEST_POWEROFF :: `#!/bin/sh
exec /bin/busybox halt "$@"
`

// The kinds of a cpio entry, as the bits of its mode.
Cpio_Kind :: enum u32 {
	Directory = 0o040000,
	File      = 0o100000,
	Link      = 0o120000,
	Character = 0o020000,
}

Cpio_Entry :: struct {
	name:        string,
	kind:        Cpio_Kind,
	permissions: u32,
	data:        []u8, // A file: its bytes; a link: its target.
	major:       u32, // A character device: its numbers.
	minor:       u32,
}

// cpio_entry_write appends one entry: the header of 110 bytes, the name with
// its zero byte, padded to 4 bytes, then the data, padded to 4 bytes.
cpio_entry_write :: proc(out: ^[dynamic]u8, entry: Cpio_Entry, inode: int) {
	header := fmt.tprintf("070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X", inode, u32(entry.kind) | entry.permissions, 0, 0, entry.kind == .Directory ? 2 : 1, 0, len(entry.data), 0, 0, entry.major, entry.minor, len(entry.name) + 1, 0)
	append(out, ..transmute([]u8)header)
	append(out, ..transmute([]u8)entry.name)
	append(out, 0)
	for len(out) % 4 != 0 {
		append(out, 0)
	}
	append(out, ..entry.data)
	for len(out) % 4 != 0 {
		append(out, 0)
	}
}

// linux_guest_initial_archive gives the archive of a static busybox, in
// temporary memory.
linux_guest_initial_archive :: proc(busybox: []u8) -> []u8 {
	entries := [?]Cpio_Entry {
		{name = "bin", kind = .Directory, permissions = 0o755},
		{name = "dev", kind = .Directory, permissions = 0o755},
		{name = "etc", kind = .Directory, permissions = 0o755},
		{name = "proc", kind = .Directory, permissions = 0o755},
		{name = "root", kind = .Directory, permissions = 0o700},
		{name = "sbin", kind = .Directory, permissions = 0o755},
		{name = "sys", kind = .Directory, permissions = 0o755},
		{name = "tmp", kind = .Directory, permissions = 0o1777},
		{name = "bin/busybox", kind = .File, permissions = 0o755, data = busybox},
		{name = "bin/sh", kind = .Link, permissions = 0o777, data = transmute([]u8)string("busybox")},
		{name = "init", kind = .Link, permissions = 0o777, data = transmute([]u8)string("bin/busybox")},
		{name = "sbin/poweroff", kind = .File, permissions = 0o755, data = transmute([]u8)string(LINUX_GUEST_POWEROFF)},
		{name = "etc/inittab", kind = .File, permissions = 0o644, data = transmute([]u8)string(LINUX_GUEST_INITTAB)},
		{name = "dev/console", kind = .Character, permissions = 0o600, major = 5, minor = 1},
		{name = "dev/ttyS0", kind = .Character, permissions = 0o660, major = 4, minor = 64},
		{name = "dev/null", kind = .Character, permissions = 0o666, major = 1, minor = 3},
		{name = "TRAILER!!!", kind = .File},
	}
	out := make([dynamic]u8, context.temp_allocator)
	for entry, index in entries {
		cpio_entry_write(&out, entry, entry.name == "TRAILER!!!" ? 0 : index + 1)
	}
	return out[:]
}

// linux_guest_image_read reads the kernel and the busybox that the flake
// names, and gives the kernel and the archive, in temporary memory.
linux_guest_image_read :: proc() -> (kernel: []u8, archive: []u8, ok: bool) {
	kernel_path := os.get_env(LINUX_KERNEL_IMAGE_VARIABLE, context.temp_allocator)
	busybox_path := os.get_env(LINUX_GUEST_BUSYBOX_VARIABLE, context.temp_allocator)
	if kernel_path == "" || busybox_path == "" {
		fmt.eprintfln("modustool: the guest of linux needs the variables %s and %s: run the tool in a shell of the flake (src/md/features/linux_shell.md)", LINUX_KERNEL_IMAGE_VARIABLE, LINUX_GUEST_BUSYBOX_VARIABLE)
		return nil, nil, false
	}
	kernel_bytes, kernel_error := os.read_entire_file(kernel_path, context.temp_allocator)
	if kernel_error != nil {
		fmt.eprintfln("modustool: cannot read the kernel %s: %v", kernel_path, kernel_error)
		return nil, nil, false
	}
	busybox_bytes, busybox_error := os.read_entire_file(busybox_path, context.temp_allocator)
	if busybox_error != nil || !strings.has_prefix(string(busybox_bytes), "\x7fELF") {
		fmt.eprintfln("modustool: cannot read the busybox %s, or it is no ELF file", busybox_path)
		return nil, nil, false
	}
	return kernel_bytes, linux_guest_initial_archive(busybox_bytes), true
}
