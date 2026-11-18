package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "modustool:build"
import "modustool:foundation"

// A part of the machine that stops to answer, or is absent
// (src/md/features/missing_hardware.md).
//
// The silent disk: the disk that the tool serves stops to answer at the
// first write of a block whose bytes start with a marker, and keeps its
// connection: QEMU waits for an answer that never comes. The block service
// fails the requests in flight at its deadline and stops, the storage
// service writes its line, refuses the write and a later read at once, and
// the console still runs a command that needs no store. A marker places the
// silence, not a count of requests: QEMU joins and splits requests, and the
// count of the start changes with each release.
//
// The machine with no network device: the root service writes its line at
// the first process with an endpoint, refuses a second one with no new
// start of the frame service, and the console still runs.

SILENT_DISK_MARKER :: "the version that the disk does not answer"
SILENT_DISK_OBJECT :: "silent"
TEST_OUTPUT_SILENT_DISK :: foundation.BUILD_FOLDER + "/test_output_silent_disk.txt"
TEST_OUTPUT_NO_NETWORK_DEVICE :: foundation.BUILD_FOLDER + "/test_output_no_network_device.txt"

// The end of the line of the storage service when the disk goes silent,
// after its cause (src/modules/system/storage/engine.odin, DISK_SILENT_LINE).
// The cause depends on which bound ends first: the block service and the
// storage service have the same one.
SILENT_DISK_STORAGE_LINE_END :: "; the service reads and changes nothing on the disk until its next start, and refuses each call that needs the disk"

scenario_silent_disk := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Wait, text = "[console]   module     storage"},
	// The write whose block starts with the marker: the disk answers it
	// never. The two services end their waits at the one hang bound of a
	// process, which is below the bound of this step.
	{kind = .Type, text = "storage.write(0, \"" + SILENT_DISK_OBJECT + "\", \"" + SILENT_DISK_MARKER + "\")"},
	{kind = .Wait, text = "block: the device did not answer a request in ", any_order = true},
	{kind = .Wait, text = " requests in flight fail, and the service stops", any_order = true},
	{kind = .Wait, text = "storage: the disk does not answer: ", any_order = true},
	{kind = .Wait, text = SILENT_DISK_STORAGE_LINE_END},
	{kind = .Wait, text = "[console] error: storage.write: "},
	// A read needs the disk too: it is refused at once, with no new wait.
	{kind = .Type, text = "storage.read(0, \"" + SILENT_DISK_OBJECT + "\")"},
	{kind = .Wait, text = "[console] error: storage.read: ", fails_on = "[console] " + SILENT_DISK_MARKER},
	// A command that needs no store still runs.
	{kind = .Type, text = "1 + 2 * 3"},
	{kind = .Wait, text = "[console] 7"},
	// QEMU drains the requests of its disks before it ends: the closed
	// connection fails the request that waits.
	{kind = .Disk_Disconnect},
	{kind = .Quit},
}

silent_disk_run :: proc(part: ^Test_Part_Run) -> bool {
	fresh := make([]u8, build.DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	// The thread of the server reads the marker at each write; no machine
	// is connected yet.
	sync.mutex_lock(&server.lock)
	server.silence_marker = SILENT_DISK_MARKER
	sync.mutex_unlock(&server.lock)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(part, scenario_silent_disk[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_SILENT_DISK, exit_status = 0, data_disk = address, disk_server = &server, data_disk_without_ioevent = true})
	disk_server_stop(&server)
	if !ran {
		return false
	}
	silent := sync.atomic_load(&server.silent)
	unanswered := sync.atomic_load(&server.silent_requests)
	sync.mutex_lock(&server.lock)
	kept := strings.contains(string(server.current), SILENT_DISK_MARKER)
	sync.mutex_unlock(&server.lock)
	refused := sync.atomic_load(&server.connections_refused)
	if !silent || unanswered < 1 || kept || refused != 0 {
		fmt.eprintfln("modustool: test failed: the silent disk: the disk went silent: %v; requests that it did not answer: %d; the marker is in its image: %v; connections of QEMU refused after the disconnect: %d", silent, unanswered, kept, refused)
		return false
	}
	// The block service and the storage service each write their line once:
	// the storage service does not stop, so the root service starts no
	// second one, and no second block service.
	if !lines_once(TEST_OUTPUT_SILENT_DISK, {"block: the device did not answer a request in ", "storage: the disk does not answer: "}) {
		return false
	}
	foundation.test_passed_print("the silent disk: the disk answered none of %d requests from the write of the marker, and kept none of it; the block service failed its requests at its deadline and stopped, the storage service refused the write and a read, and the console ran on", unanswered)
	return true
}

scenario_no_network_device := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "net"},
	{kind = .Wait, text = "root: no virtio device for frame at the place 18 of the bus"},
	{kind = .Wait, text = "root: the network service did not start: no process with an endpoint of the network starts until the machine starts again; the other processes start"},
	// A second process with an endpoint: refused with no new start of the
	// frame service, so no second line of the device.
	{kind = .Launch, text = "net"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "1 + 2 * 3"},
	{kind = .Wait, text = "[console] 7", fails_on = "root: the network service did not start"},
	{kind = .Quit},
}

no_network_device_run :: proc(part: ^Test_Part_Run) -> bool {
	if !machine_test(part, scenario_no_network_device[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_NO_NETWORK_DEVICE, exit_status = 0, no_network_device = true}) {
		return false
	}
	// Two starts of net, one line of each: the second start is refused
	// with no new start of the frame service and no new line.
	return lines_once(TEST_OUTPUT_NO_NETWORK_DEVICE, {"root: no virtio device for frame", "root: the network service did not start"})
}

// lines_once says if the log of a machine holds each text exactly once,
// and writes the count of each one that it holds another count of times.
lines_once :: proc(log_path: string, texts: []string) -> bool {
	log, read_error := os.read_entire_file(log_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", log_path, read_error)
		return false
	}
	once := true
	for text in texts {
		if count := strings.count(string(log), text); count != 1 {
			fmt.eprintfln("modustool: test failed: the log %s holds \"%s\" %d times, and it must hold it once", log_path, text, count)
			once = false
		}
	}
	return once
}
