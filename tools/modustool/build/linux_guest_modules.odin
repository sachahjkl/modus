// The kernel modules of a Linux guest (src/md/features/linux_shell.md, "The
// virtio modules"): the kernel of Nixpkgs builds the virtio transport, its
// ring, the console and the block device as loadable modules, and the flake
// gives them decompressed in one folder (MODUS_LINUX_GUEST_MODULES). The
// shell of the process linux and the init of a guest build load them from
// their initial archive, in this order.
package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The variable of the flake that names the folder of the modules.
LINUX_GUEST_MODULES_VARIABLE :: "MODUS_LINUX_GUEST_MODULES"

// The modules, each after the modules that it needs: the ring, the core of
// virtio, the transport of the windows that the command line declares, then
// the two drivers.
Linux_Guest_Module :: enum u8 {
	Virtio_Ring    = 0,
	Virtio         = 1,
	Virtio_Mmio    = 2,
	Virtio_Console = 3,
	Virtio_Block   = 4,
}

// The file of each module in the folder, and in the initial archive under
// LINUX_GUEST_MODULES_FOLDER.
LINUX_GUEST_MODULE_FILES :: [Linux_Guest_Module]string {
	.Virtio_Ring    = "virtio_ring.ko",
	.Virtio         = "virtio.ko",
	.Virtio_Mmio    = "virtio_mmio.ko",
	.Virtio_Console = "virtio_console.ko",
	.Virtio_Block   = "virtio_blk.ko",
}

// The folder of the modules in an initial archive.
LINUX_GUEST_MODULES_FOLDER :: "lib/modules"

// linux_guest_modules_read reads each module of the folder that the flake
// names, in temporary memory. Each must be an ELF file.
linux_guest_modules_read :: proc() -> (modules: [Linux_Guest_Module][]u8, ok: bool) {
	folder := os.get_env(LINUX_GUEST_MODULES_VARIABLE, context.temp_allocator)
	if folder == "" {
		fmt.eprintfln("modustool: the guest of linux needs the variable %s: run the tool in a shell of the flake (src/md/features/linux_shell.md)", LINUX_GUEST_MODULES_VARIABLE)
		return {}, false
	}
	files := LINUX_GUEST_MODULE_FILES
	for module in Linux_Guest_Module {
		path, _ := filepath.join({folder, files[module]}, context.temp_allocator)
		bytes, error := os.read_entire_file(path, context.temp_allocator)
		if error != nil || !strings.has_prefix(string(bytes), "\x7fELF") {
			fmt.eprintfln("modustool: cannot read the kernel module %s, or it is no ELF file", path)
			return {}, false
		}
		modules[module] = bytes
	}
	return modules, true
}
