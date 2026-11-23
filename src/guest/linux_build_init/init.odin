// The init of a guest build (src/md/features/guest_build_image.md): process 1
// of a Linux guest that the guest builder starts. It loads the virtio
// modules, unpacks the read-only input disk into /inputs, runs the command
// of the spec, packs /outputs into the output disk, and writes the exit
// status of the command to the port Build_Exit_Status. It runs on Linux,
// not on modus: it reaches Linux through its system calls
// (linux_calls.asm), and it reads and writes the disks with the contract
// of the guest builder, as the host does.
package linux_build_init

import "base:intrinsics"
import "base:runtime"
import "modus:contract/byte_order"
import gb "modus:contract/guest_builder"

foreign import calls "linux_calls.asm"

@(default_calling_convention = "sysv")
foreign calls {
	linux_call :: proc(number: uintptr, a: uintptr = 0, b: uintptr = 0, c: uintptr = 0, d: uintptr = 0, e: uintptr = 0, f: uintptr = 0) -> int ---
	port_in32 :: proc(port: u32) -> u32 ---
	port_out32 :: proc(port: u32, value: u32) ---
}

// The system calls of Linux on x86-64 that init makes.
Linux_Call :: enum uintptr {
	Read          = 0,
	Write         = 1,
	Open          = 2,
	Close         = 3,
	Lseek         = 8,
	Mmap          = 9,
	Fork          = 57,
	Execve        = 59,
	Wait4         = 61,
	Kill          = 62,
	Fsync         = 74,
	Chdir         = 80,
	Mkdir         = 83,
	Chown         = 92,
	Setuid        = 105,
	Setgid        = 106,
	Setgroups     = 116,
	Mknod         = 133,
	Iopl          = 172,
	Mount         = 165,
	Getdents64    = 217,
	Finit_Module  = 313,
}

// The user and the group of the build command: no right to the ports, to
// the nodes of the disks or to the modules of the kernel, which belong to
// init, process 1 and the one root of the guest.
BUILD_USER :: uintptr(1000)

// The status that init gives when it fails itself, as a shell gives 126
// and 127: no command returns it by chance.
INIT_FAILED_STATUS :: u32(125)

// The words of the flags of Linux that init passes.
OPEN_READ :: 0
OPEN_WRITE :: 1
OPEN_DIRECTORY :: 0o200000
OPEN_NO_FOLLOW :: 0o400000
OPEN_CREATE_TRUNCATE :: 0o100 | 0o1000
MAP_PRIVATE_ANONYMOUS :: 0x02 | 0x20
PROTECT_READ_WRITE :: 0x1 | 0x2
SEEK_END :: 2
ERROR_EXISTS :: -17
ERROR_NO_CHILD :: -10
ERROR_INTERRUPTED :: -4
BLOCK_DEVICE_MODE :: 0o060000 | 0o600

// The bytes of one path that a system call takes, with its zero byte.
PATH_BYTES :: 256
// The bytes of a small file of /proc or /sys that init reads.
SMALL_FILE_BYTES :: 4096
// The bytes of the command line of the command, and of one module parameter list.
COMMAND_BYTES :: 4096

// The files of the output, sorted before they are written.
output_paths: [gb.MAX_DISK_ENTRIES][gb.MAX_MOUNT_PATH_BYTES]u8
output_path_lengths: [gb.MAX_DISK_ENTRIES]int
output_order: [gb.MAX_DISK_ENTRIES]int
output_count: int
directory_entries: [gb.MAX_PATH_DEPTH][8192]u8

// init_main is the entry: stack is the place of argc, then the arguments.
@(export, link_name = "init_main")
init_main :: proc "sysv" (stack: rawptr) -> ! {
	context = runtime.default_context()
	status := build(stack)
	_ = linux_call(uintptr(Linux_Call.Iopl), 3)
	port_out32(u32(gb.Guest_Io_Port.Build_Exit_Status), status)
	// The port ends the run: the machine stops this guest at the write.
	for {
		intrinsics.cpu_relax()
	}
}

// say writes one line on the console of the guest, which the machine
// writes in the log of the build.
say :: proc "contextless" (parts: ..string) {
	line: [512]u8
	length := 0
	for part in parts {
		length += copy(line[length:len(line) - 1], part)
	}
	line[length] = '\n'
	_ = linux_call(uintptr(Linux_Call.Write), 1, uintptr(&line[0]), uintptr(length + 1))
}

// c_text gives text with its zero byte, in into.
c_text :: proc "contextless" (into: []u8, parts: ..string) -> (pointer: uintptr, ok: bool) {
	length := 0
	for part in parts {
		if length + len(part) >= len(into) {
			return 0, false
		}
		length += copy(into[length:], part)
	}
	into[length] = 0
	return uintptr(&into[0]), true
}

decimal :: proc "contextless" (into: []u8, value: u64) -> string {
	digits: [20]u8
	count := 0
	rest := value
	for {
		digits[count] = u8('0' + rest % 10)
		count += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	for index in 0 ..< count {
		into[index] = digits[count - 1 - index]
	}
	return string(into[:count])
}

// map_bytes gives count bytes of zeroed memory.
map_bytes :: proc "contextless" (count: int) -> (bytes: []u8, ok: bool) {
	if count <= 0 {
		return nil, count == 0
	}
	address := linux_call(uintptr(Linux_Call.Mmap), 0, uintptr(count), PROTECT_READ_WRITE, MAP_PRIVATE_ANONYMOUS, ~uintptr(0), 0)
	if address < 0 && address > -4096 {
		return nil, false
	}
	return ([^]u8)(uintptr(address))[:count], true
}

open_path :: proc "contextless" (flags: uintptr, mode: uintptr, parts: ..string) -> int {
	path: [PATH_BYTES]u8
	pointer, ok := c_text(path[:], ..parts)
	if !ok {
		return -36 // ENAMETOOLONG
	}
	return linux_call(uintptr(Linux_Call.Open), pointer, flags, mode)
}

// read_whole reads a file of /proc or /sys into into.
read_whole :: proc "contextless" (into: []u8, parts: ..string) -> (text: string, ok: bool) {
	descriptor := open_path(OPEN_READ, 0, ..parts)
	if descriptor < 0 {
		return "", false
	}
	defer _ = linux_call(uintptr(Linux_Call.Close), uintptr(descriptor))
	length := 0
	for length < len(into) {
		count := linux_call(uintptr(Linux_Call.Read), uintptr(descriptor), uintptr(&into[length]), uintptr(len(into) - length))
		if count < 0 {
			return "", false
		}
		if count == 0 {
			break
		}
		length += count
	}
	return string(into[:length]), true
}

// write_all writes bytes to a descriptor, at offset when it is not negative.
write_all :: proc "contextless" (descriptor: int, bytes: []u8) -> bool {
	done := 0
	for done < len(bytes) {
		count := linux_call(uintptr(Linux_Call.Write), uintptr(descriptor), uintptr(&bytes[done]), uintptr(len(bytes) - done))
		if count <= 0 {
			return false
		}
		done += count
	}
	return true
}

read_all :: proc "contextless" (descriptor: int, into: []u8) -> bool {
	done := 0
	for done < len(into) {
		count := linux_call(uintptr(Linux_Call.Read), uintptr(descriptor), uintptr(&into[done]), uintptr(len(into) - done))
		if count <= 0 {
			return false
		}
		done += count
	}
	return true
}

trimmed :: proc "contextless" (text: string) -> string {
	end := len(text)
	for end > 0 && (text[end - 1] == '\n' || text[end - 1] == ' ' || text[end - 1] == 0) {
		end -= 1
	}
	return text[:end]
}

// mount_file_systems mounts /proc and /sys, which the modules and the
// disks are read from.
mount_file_systems :: proc "contextless" () -> bool {
	for pair in ([2][2]string{{"proc", "/proc"}, {"sysfs", "/sys"}}) {
		kind_text, target_text: [32]u8
		kind, _ := c_text(kind_text[:], pair[0])
		target, _ := c_text(target_text[:], pair[1])
		if result := linux_call(uintptr(Linux_Call.Mount), kind, target, kind, 0, 0); result < 0 && result != -16 {
			say("linux_build_init: ", pair[1], " was not mounted")
			return false
		}
	}
	return true
}

// load_modules loads the virtio modules in order; the transport takes the
// windows that the command line declares.
load_modules :: proc "contextless" () -> bool {
	command_line: [SMALL_FILE_BYTES]u8
	line, read_ok := read_whole(command_line[:], "/proc/cmdline")
	if !read_ok {
		say("linux_build_init: the modules were not loaded: /proc/cmdline was not read")
		return false
	}
	parameters: [COMMAND_BYTES]u8
	length := 0
	PREFIX :: "virtio_mmio."
	start := 0
	for index in 0 ..= len(line) {
		if index < len(line) && line[index] != ' ' && line[index] != '\n' {
			continue
		}
		word := line[start:index]
		start = index + 1
		if len(word) > len(PREFIX) && word[:len(PREFIX)] == PREFIX && length + len(word) + 1 < len(parameters) {
			if length > 0 {
				parameters[length] = ' '
				length += 1
			}
			length += copy(parameters[length:], word[len(PREFIX):])
		}
	}
	parameters[length] = 0
	empty := [1]u8{0}
	for name in ([4]string{"virtio_ring", "virtio", "virtio_mmio", "virtio_blk"}) {
		descriptor := open_path(OPEN_READ, 0, "/lib/modules/", name, ".ko")
		if descriptor < 0 {
			say("linux_build_init: the module ", name, " was not loaded: the archive holds no file of it")
			return false
		}
		given := name == "virtio_mmio" ? uintptr(&parameters[0]) : uintptr(&empty[0])
		result := linux_call(uintptr(Linux_Call.Finit_Module), uintptr(descriptor), given, 0)
		_ = linux_call(uintptr(Linux_Call.Close), uintptr(descriptor))
		if result < 0 && result != ERROR_EXISTS {
			say("linux_build_init: the module ", name, " was not loaded: the kernel refused it")
			return false
		}
	}
	return true
}

// disk_open finds the disk whose identifier is serial, makes its node, and
// opens it; it gives its size in bytes.
disk_open :: proc "contextless" (serial: string, flags: uintptr) -> (descriptor: int, size: int, ok: bool) {
	for name in ([4]string{"vda", "vdb", "vdc", "vdd"}) {
		text: [SMALL_FILE_BYTES]u8
		found, read_ok := read_whole(text[:], "/sys/block/", name, "/serial")
		if !read_ok || trimmed(found) != serial {
			continue
		}
		numbers, numbers_ok := read_whole(text[:], "/sys/block/", name, "/dev")
		if !numbers_ok {
			continue
		}
		numbers = trimmed(numbers)
		major, minor, seen_colon := u64(0), u64(0), false
		for value in transmute([]u8)numbers {
			switch value {
			case ':':
				seen_colon = true
			case '0' ..= '9':
				if seen_colon {
					minor = minor * 10 + u64(value - '0')
				} else {
					major = major * 10 + u64(value - '0')
				}
			}
		}
		device := (minor & 0xff) | (major << 8) | ((minor &~ 0xff) << 12)
		path: [PATH_BYTES]u8
		pointer, _ := c_text(path[:], "/dev/", name)
		if result := linux_call(uintptr(Linux_Call.Mknod), pointer, BLOCK_DEVICE_MODE, uintptr(device)); result < 0 && result != ERROR_EXISTS {
			say("linux_build_init: the node of the disk ", serial, " was not made")
			return -1, 0, false
		}
		descriptor = open_path(flags, 0, "/dev/", name)
		if descriptor < 0 {
			say("linux_build_init: the disk ", serial, " was not opened")
			return -1, 0, false
		}
		size = linux_call(uintptr(Linux_Call.Lseek), uintptr(descriptor), 0, SEEK_END)
		_ = linux_call(uintptr(Linux_Call.Lseek), uintptr(descriptor), 0, 0)
		return descriptor, size, size > 0
	}
	say("linux_build_init: no disk has the identifier ", serial)
	return -1, 0, false
}

// give_to_build_user makes the build user the owner of a path, so the
// command writes there.
give_to_build_user :: proc "contextless" (parts: ..string) -> bool {
	path: [PATH_BYTES]u8
	pointer, ok := c_text(path[:], ..parts)
	return ok && linux_call(uintptr(Linux_Call.Chown), pointer, BUILD_USER, BUILD_USER) >= 0
}

// make_folders makes each folder of path under root, owned by the build
// user.
make_folders :: proc "contextless" (root: string, path: string) -> bool {
	for index in 0 ..< len(path) {
		if path[index] != '/' {
			continue
		}
		folder: [PATH_BYTES]u8
		pointer, ok := c_text(folder[:], root, "/", path[:index])
		if !ok {
			return false
		}
		if result := linux_call(uintptr(Linux_Call.Mkdir), pointer, 0o755); result < 0 && result != ERROR_EXISTS {
			return false
		}
		if !give_to_build_user(root, "/", path[:index]) {
			return false
		}
	}
	return true
}

// unpack_inputs reads the input disk whole, checks it, and writes each of
// its files under /inputs.
unpack_inputs :: proc "contextless" () -> bool {
	descriptor, size, ok := disk_open("modus-inputs", OPEN_READ)
	if !ok {
		return false
	}
	image, mapped := map_bytes(size)
	if !mapped || !read_all(descriptor, image) {
		say("linux_build_init: the input disk was not read")
		return false
	}
	header, refusal := gb.validate_disk_image(image, .Inputs_Read_Only, 0)
	if refusal != .None {
		say("linux_build_init: the input disk is not a disk of inputs that the contract reads")
		return false
	}
	for index in 0 ..< int(header.entry_count) {
		entry, entry_ok := gb.disk_image_entry_at(image, index)
		if !entry_ok || !make_folders("/inputs", entry.path) {
			say("linux_build_init: the inputs were not written: a folder of ", entry.path, " was not made")
			return false
		}
		file := open_path(OPEN_WRITE | OPEN_CREATE_TRUNCATE, 0o644, "/inputs/", entry.path)
		if file < 0 || !write_all(file, image[entry.data_offset:][:entry.data_size]) || !give_to_build_user("/inputs/", entry.path) {
			say("linux_build_init: the input ", entry.path, " was not written")
			return false
		}
		_ = linux_call(uintptr(Linux_Call.Close), uintptr(file))
	}
	return true
}

// run waits for a child that runs program with arguments, and gives its
// status: the exit code, or 128 and the signal that ended it.
run :: proc "contextless" (arguments: []uintptr, environment: []uintptr, folder: string, as_build_user: bool) -> (status: u32, ok: bool) {
	child := linux_call(uintptr(Linux_Call.Fork))
	if child < 0 {
		return 0, false
	}
	if child == 0 {
		// The command runs as the build user: no supplementary group, then
		// the group, then the user, each checked. The I/O privilege level of
		// init is 0 here (build drops it before the fork), and a user that
		// is not root cannot raise it.
		if as_build_user {
			if linux_call(uintptr(Linux_Call.Iopl), 0) < 0 || linux_call(uintptr(Linux_Call.Setgroups), 0, 0) < 0 || linux_call(uintptr(Linux_Call.Setgid), BUILD_USER) < 0 || linux_call(uintptr(Linux_Call.Setuid), BUILD_USER) < 0 {
				say("linux_build_init: the command was not run: init did not become the build user")
				for {
					_ = linux_call(60, uintptr(INIT_FAILED_STATUS))
				}
			}
		}
		place: [PATH_BYTES]u8
		pointer, _ := c_text(place[:], folder)
		_ = linux_call(uintptr(Linux_Call.Chdir), pointer)
		_ = linux_call(uintptr(Linux_Call.Execve), arguments[0], uintptr(&arguments[0]), uintptr(&environment[0]))
		say("linux_build_init: the shell of busybox was not started")
		for {
			_ = linux_call(60, uintptr(INIT_FAILED_STATUS))
		}
	}
	word: i32
	for {
		result := linux_call(uintptr(Linux_Call.Wait4), uintptr(child), uintptr(&word), 0, 0)
		if result == child {
			break
		}
		if result != ERROR_INTERRUPTED {
			return 0, false
		}
	}
	if word & 0x7f == 0 {
		return u32(word >> 8) & 0xff, true
	}
	return 128 + u32(word & 0x7f), true
}

// command_run runs the command of the spec, the arguments of init joined
// with one space, with sh -c in /inputs.
command_run :: proc "contextless" (stack: rawptr, epoch: u64) -> (status: u32, ok: bool) {
	words := ([^]uintptr)(stack)
	count := int(words[0])
	command: [COMMAND_BYTES]u8
	length := 0
	for index in 1 ..< count {
		argument := ([^]u8)(words[1 + index])
		if index > 1 && length < len(command) - 1 {
			command[length] = ' '
			length += 1
		}
		for place := 0; argument[place] != 0 && length < len(command) - 1; place += 1 {
			command[length] = argument[place]
			length += 1
		}
	}
	command[length] = 0
	if length == 0 {
		say("linux_build_init: no command was run: the command line gives none after --")
		return 0, false
	}
	shell := [?]u8{'/', 'b', 'i', 'n', '/', 's', 'h', 0}
	dash_c := [?]u8{'-', 'c', 0}
	epoch_text: [64]u8
	epoch_digits: [24]u8
	epoch_pointer, _ := c_text(epoch_text[:], "SOURCE_DATE_EPOCH=", decimal(epoch_digits[:], epoch))
	path_variable := [?]u8{'P', 'A', 'T', 'H', '=', '/', 'b', 'i', 'n', 0}
	environment := [3]uintptr{uintptr(&path_variable[0]), epoch_pointer, 0}
	arguments := [4]uintptr{uintptr(&shell[0]), uintptr(&dash_c[0]), uintptr(&command[0]), 0}
	return run(arguments[:], environment[:], "/inputs", true)
}

// busybox_install makes the links of the applets of busybox in /bin.
busybox_install :: proc "contextless" () -> bool {
	busybox := [?]u8{'/', 'b', 'i', 'n', '/', 'b', 'u', 's', 'y', 'b', 'o', 'x', 0}
	install := [?]u8{'-', '-', 'i', 'n', 's', 't', 'a', 'l', 'l', 0}
	symbolic := [?]u8{'-', 's', 0}
	folder := [?]u8{'/', 'b', 'i', 'n', 0}
	arguments := [5]uintptr{uintptr(&busybox[0]), uintptr(&install[0]), uintptr(&symbolic[0]), uintptr(&folder[0]), 0}
	environment := [1]uintptr{0}
	status, ok := run(arguments[:], environment[:], "/", false)
	return ok && status == 0
}

// collect_outputs walks folder (relative to /outputs, "" at the top) and
// adds each file to the outputs. A link or a device is refused: the disk
// holds files.
collect_outputs :: proc "contextless" (folder: string, depth: int) -> bool {
	if depth >= gb.MAX_PATH_DEPTH {
		say("linux_build_init: the output was not written: /outputs/", folder, " is deeper than a disk holds")
		return false
	}
	descriptor := open_path(OPEN_READ | OPEN_DIRECTORY | OPEN_NO_FOLLOW, 0, "/outputs/", folder)
	if descriptor < 0 {
		return depth == 0 // No /outputs: an empty output.
	}
	defer _ = linux_call(uintptr(Linux_Call.Close), uintptr(descriptor))
	buffer := directory_entries[depth][:]
	for {
		count := linux_call(uintptr(Linux_Call.Getdents64), uintptr(descriptor), uintptr(&buffer[0]), uintptr(len(buffer)))
		if count < 0 {
			return false
		}
		if count == 0 {
			return true
		}
		place := 0
		for place < count {
			record_length := int(byte_order.read_u16_little_endian(buffer[:], place + 16))
			kind := buffer[place + 18]
			name_start := place + 19
			name_end := name_start
			for buffer[name_end] != 0 {
				name_end += 1
			}
			name := string(buffer[name_start:name_end])
			place += record_length
			if name == "." || name == ".." {
				continue
			}
			path: [gb.MAX_MOUNT_PATH_BYTES + 1]u8
			length := 0
			if len(folder) + 1 + len(name) > gb.MAX_MOUNT_PATH_BYTES {
				say("linux_build_init: the output was not written: a path under /outputs/", folder, " is longer than a disk holds")
				return false
			}
			if len(folder) > 0 {
				length += copy(path[:], folder)
				path[length] = '/'
				length += 1
			}
			length += copy(path[length:], name)
			switch kind {
			case 4: // A folder.
				if !collect_outputs(string(path[:length]), depth + 1) {
					return false
				}
			case 8: // A file.
				if output_count >= gb.MAX_DISK_ENTRIES {
					say("linux_build_init: the output was not written: /outputs holds more files than a disk holds")
					return false
				}
				copy(output_paths[output_count][:], path[:length])
				output_path_lengths[output_count] = length
				output_order[output_count] = output_count
				output_count += 1
			case:
				say("linux_build_init: the output was not written: /outputs/", string(path[:length]), " is not a file or a folder")
				return false
			}
		}
	}
}

output_path :: proc "contextless" (index: int) -> []u8 {
	return output_paths[index][:output_path_lengths[index]]
}

// sort_outputs sorts the files by the bytes of their paths, the order of a
// disk: a heap sort, with no memory.
sort_outputs :: proc "contextless" () {
	less :: proc "contextless" (left, right: int) -> bool {
		return gb.compare_path_bytes(output_path(left), output_path(right)) < 0
	}
	order := output_order[:output_count]
	sift :: proc "contextless" (order: []int, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && less(order[child], order[child + 1]) {
				child += 1
			}
			if !less(order[root], order[child]) {
				return
			}
			order[root], order[child] = order[child], order[root]
			root = child
		}
	}
	for start := len(order) / 2 - 1; start >= 0; start -= 1 {
		sift(order, start, len(order))
	}
	for end := len(order) - 1; end > 0; end -= 1 {
		order[0], order[end] = order[end], order[0]
		sift(order, 0, end)
	}
}

// pack_outputs writes the files of /outputs as one disk of the size of the
// output device, then writes it to the device and syncs it.
pack_outputs :: proc "contextless" (epoch: u64) -> bool {
	if !collect_outputs("", 0) {
		return false
	}
	sort_outputs()
	descriptor, size, ok := disk_open("modus-outputs", OPEN_WRITE)
	if !ok {
		return false
	}
	image, image_ok := map_bytes(size)
	content, content_ok := map_bytes(size)
	if !image_ok || !content_ok {
		say("linux_build_init: the output was not written: the memory of the guest does not hold two copies of the output disk")
		return false
	}
	writer: gb.Disk_Stream_Writer
	if gb.disk_stream_begin(&writer, .Output_Writable, u32(output_count), epoch, image) != .None {
		say("linux_build_init: the output was not written: its files do not fit the output disk")
		return false
	}
	for index in output_order[:output_count] {
		path := string(output_path(index))
		// No link is followed: a link that the command made in /outputs
		// is refused, never read through.
		file := open_path(OPEN_READ | OPEN_NO_FOLLOW, 0, "/outputs/", path)
		if file < 0 {
			say("linux_build_init: the output ", path, " was not read")
			return false
		}
		bytes := linux_call(uintptr(Linux_Call.Lseek), uintptr(file), 0, SEEK_END)
		_ = linux_call(uintptr(Linux_Call.Lseek), uintptr(file), 0, 0)
		if bytes < 0 || bytes > size || (bytes > 0 && !read_all(file, content[:bytes])) {
			say("linux_build_init: the output ", path, " was not read whole")
			return false
		}
		_ = linux_call(uintptr(Linux_Call.Close), uintptr(file))
		if gb.disk_stream_write_entry(&writer, path, content[:max(bytes, 0)]) != .None {
			say("linux_build_init: the output was not written: ", path, " does not fit the output disk, or its path is not a path of a disk")
			return false
		}
	}
	if _, refusal := gb.disk_stream_finish(&writer); refusal != .None {
		say("linux_build_init: the output disk was not finished")
		return false
	}
	if !write_all(descriptor, image) || linux_call(uintptr(Linux_Call.Fsync), uintptr(descriptor)) < 0 {
		say("linux_build_init: the output disk was not written")
		return false
	}
	return true
}

// build runs the steps of a build, and gives the status that the port
// takes: the status of the command, or INIT_FAILED_STATUS.
build :: proc "contextless" (stack: rawptr) -> u32 {
	if linux_call(uintptr(Linux_Call.Iopl), 3) < 0 {
		say("linux_build_init: the ports of the build are not open to init")
		return INIT_FAILED_STATUS
	}
	if !mount_file_systems() || !load_modules() || !unpack_inputs() || !busybox_install() {
		return INIT_FAILED_STATUS
	}
	for folder in ([2]string{"/outputs", "/inputs"}) {
		path: [32]u8
		pointer, _ := c_text(path[:], folder)
		_ = linux_call(uintptr(Linux_Call.Mkdir), pointer, 0o755)
		if !give_to_build_user(folder) {
			say("linux_build_init: the command was not run: ", folder, " was not given to the build user")
			return INIT_FAILED_STATUS
		}
	}
	// The frozen time, then the ports close: the command runs with no right
	// to them, and init opens them again for the status.
	epoch := u64(port_in32(u32(gb.Guest_Io_Port.Frozen_Clock_High))) << 32 | u64(port_in32(u32(gb.Guest_Io_Port.Frozen_Clock_Low)))
	if linux_call(uintptr(Linux_Call.Iopl), 0) < 0 {
		say("linux_build_init: the command was not run: the ports of the build did not close")
		return INIT_FAILED_STATUS
	}
	status, ran := command_run(stack, epoch)
	// Each process that the command left ends before init reads /outputs:
	// none changes a file between the walk and the read.
	_ = linux_call(uintptr(Linux_Call.Kill), ~uintptr(0), 9)
	// The kill is sent, not done: init waits for each child until none is
	// left (ECHILD), so no process of the command runs during the walk.
	// A process that the command left gets init as its parent, so init
	// waits for it too.
	for {
		result := linux_call(uintptr(Linux_Call.Wait4), ~uintptr(0), 0, 0, 0)
		if result == ERROR_NO_CHILD {
			break
		}
		if result < 0 && result != ERROR_INTERRUPTED {
			say("linux_build_init: the output was not written: the processes of the command did not end")
			return INIT_FAILED_STATUS
		}
	}
	if !ran {
		return INIT_FAILED_STATUS
	}
	if status != 0 {
		return status
	}
	if !pack_outputs(epoch) {
		return INIT_FAILED_STATUS
	}
	return 0
}
