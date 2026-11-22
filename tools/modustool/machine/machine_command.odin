// The command line of QEMU for a test machine, with its disks, its firmware
// and its devices, and the logs and the disks of the parts of the machine
// test (docs/TOOLS.md, "The parts of the machine test").
package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/reference_screen"
import "modus:contract/remote"
import "modus:contract/timed_stream"
import "modus:bochs_display"
import "modus:pci"
import "modustool:build"
import "modustool:foundation"

TEST_OUTPUT_SHORTAGE :: foundation.BUILD_FOLDER + "/test_output_shortage.txt"

TEST_OUTPUT_OPERATION_SEQUENCES :: foundation.BUILD_FOLDER + "/test_output_operation_sequences.txt"

// The private copy of the variable store of the firmware of `run`. A test
// machine has its own copy beside its log, with the same name after the
// name of its log (machine_command): two machines that run at the same
// time never write one store.
FIRMWARE_VARIABLES :: foundation.BUILD_FOLDER + "/ovmf_vars.fd"

FIRMWARE_FULL_VARIABLES :: foundation.BUILD_FOLDER + "/ovmf_full_vars.fd"

FIRMWARE_TPM_VARIABLES :: foundation.BUILD_FOLDER + "/ovmf_tpm_vars.fd"

FIRMWARE_VARIABLES_SUFFIX :: "_ovmf_vars.fd"

FIRMWARE_FULL_VARIABLES_SUFFIX :: "_ovmf_full_vars.fd"

FIRMWARE_TPM_VARIABLES_SUFFIX :: "_ovmf_tpm_vars.fd"

TEST_OUTPUT_FAILS :: foundation.BUILD_FOLDER + "/test_output_fails.txt"

TEST_OUTPUT_SELF_TEST :: foundation.BUILD_FOLDER + "/test_output_self_test_%d.txt"

SCRATCH_DISK :: foundation.BUILD_FOLDER + "/scratch_disk.img"

SCRATCH_DISK_SUFFIX :: "_scratch_disk.img"

// The FIFO of the input of the serial line of a test machine, beside its
// log (serial_input_linux.odin).
SERIAL_INPUT_SUFFIX :: "_serial_input.fifo"

// The socket of the source of an entropy device that never answers, beside
// the log of its machine.
ENTROPY_SOURCE_SOCKET_SUFFIX :: "_entropy_source.socket"

// The processors of each machine (`-smp`). The whole test starts at most
// one part for each of these counts of processors of the host, and fewer
// when the memory of the host holds fewer (test_parts_at_once).
MACHINE_PROCESSOR_COUNT :: 4

// The data disk of the three machines of the test of persistence: new
// before the first one, kept for the two others.
TEST_PERSIST_DISK :: foundation.BUILD_FOLDER + "/test_persist_disk.img"

TEST_OUTPUT_PERSIST :: foundation.BUILD_FOLDER + "/test_output_persist_%d.txt"

SCRATCH_DISK_SIZE :: 32 << 20

// The processor of a test machine, as the -cpu of QEMU.
Processor_Model :: enum {
	Maximum, // Each feature that the host processor, or the emulation, has.
	Without_Random, // No rdrand and no rdseed: the fallback of the seed of the root service (`test random`).
	Without_Avx, // No AVX: the kernel saves x87 and SSE with xsaveopt (`test extended_state`).
	Without_Xsave, // No xsave: the kernel saves with fxsave (`test extended_state`).
	// No leaf 0x15 of CPUID and none above: the processor states no
	// frequency of its cycle counter, on every host (`test no_pit`).
	Without_Frequency_Leaves,
}

@(rodata)
processor_models := [Processor_Model]string {
	.Maximum                  = "max",
	.Without_Random           = "max,-rdrand,-rdseed",
	.Without_Avx              = "max,-avx",
	.Without_Xsave            = "max,-xsave",
	.Without_Frequency_Leaves = "max,level=0x14",
}

// machine_command gives the one QEMU command line of the project: the first
// fixed machine that the system targets (QEMU on x86-64 with virtio
// devices, UEFI firmware and a TPM). The boot volume is a virtio block device. If
// test_output is a path, the machine has no window and writes its log there.
// The network device sends each frame to the peer (peer.odin) on the
// loopback of the host, at peer_port, as one UDP datagram.
// The network device goes to the peer (`-netdev dgram`), or, when forward
// has a port, to QEMU user networking with its TCP (web_host.odin).
// processor gives the processor of the machine (Processor_Model).
// entropy_device gives the machine the entropy device of virtio at the place
// pci.ENTROPY_DEVICE (src/md/features/entropy_device.md).
// The IOMMU of a machine: none, the unit of Intel, or the unit of AMD
// (src/md/infrastructure/iommu.md).
Machine_Iommu :: enum {
	None,
	Intel,
	Amd,
}

// firmware_files names the files of a firmware: the variable of the
// environment that gives its code, the one that gives its variable store,
// the copy of that store outside a test, and the end of the name of the
// copy of a test machine. The start of a machine and the names of the
// addresses at a failure both read them, so the two name the same files.
firmware_files :: proc(firmware: Machine_Firmware) -> (code_variable, variables_variable, variables_copy, variables_suffix: string) {
	switch firmware {
	case .Usual:
		code_variable, variables_variable, variables_copy, variables_suffix = "OVMF_CODE", "OVMF_VARS", FIRMWARE_VARIABLES, FIRMWARE_VARIABLES_SUFFIX
	case .With_Tpm_Driver:
		code_variable, variables_variable, variables_copy, variables_suffix = "OVMF_TPM_CODE", "OVMF_TPM_VARS", FIRMWARE_TPM_VARIABLES, FIRMWARE_TPM_VARIABLES_SUFFIX
	case .With_Secure_Boot:
		code_variable, variables_variable, variables_copy, variables_suffix = "OVMF_FULL_CODE", "OVMF_FULL_VARS", FIRMWARE_FULL_VARIABLES, FIRMWARE_FULL_VARIABLES_SUFFIX
	}
	return
}

// The memory of a test machine, in MiB. Below the hole of PCI of q35, so an
// offset in the memory file of a machine is a physical address: the mailbox
// of the operation sequences and the counters of the counted kernel are read
// at their physical address as an offset. q35 keeps all the memory below
// 4 GiB while it is at most Q35_LOW_MEMORY_MIB (QEMU, hw/i386/pc_q35.c, the
// limit 0xB0000000 of the memory below 4 GiB); past it, the memory above
// 2 GiB moves above 4 GiB, and an offset is no longer an address. The bound
// by memory of the parts at once reads it (test_part_memory_mib).
MACHINE_MEMORY_MIB :: 1024
Q35_LOW_MEMORY_MIB :: 0xB000_0000 >> 20
#assert(MACHINE_MEMORY_MIB <= Q35_LOW_MEMORY_MIB)

// The video memory of the standard VGA of a test machine, in MiB: the
// amount of QEMU with no option, stated so that the check below reads it.
// The machine passes no option for it: with `-global VGA.vgamem_mb`, the
// firmware gives no graphics output, and the boot program finds no screen.
// The compositor flips between two screen pages of the reference screen in
// it (src/md/infrastructure/whole_frame.md); a screen whose two pages do
// not fit stops the build of the tool, not a machine test.
MACHINE_VIDEO_MEMORY_MIB :: 16
#assert(bochs_display.PAGE_COUNT * reference_screen.WIDTH * reference_screen.HEIGHT * bochs_display.BITS_PER_PIXEL / 8 <= MACHINE_VIDEO_MEMORY_MIB << 20)

// memory_file: "", or a file of the host that holds the memory of the
// machine, which the tool reads and writes (operation_sequences.odin); such
// a machine has one processor, so that a sequence gives the same answers at
// each run (src/md/infrastructure/kernel_fuzzing.md, "The machine").
// The parts that a machine can lack (src/md/features/missing_hardware.md):
// without_screen leaves out the display device, without_ps2_controller the
// PS/2 controller, and entropy_device_silent gives the entropy device a
// source that never answers, in place of the device of entropy_device.
// no_network_device leaves the network device out: the root service then
// starts no frame service (src/md/features/missing_hardware.md).
// data_disk_without_ioevent gives the data disk no ioevent file: QEMU then
// takes each request in the thread of its notify, and does not drain the
// requests of the disk when the root service turns its bus master off, so a
// request that the disk never answers stops no processor (silent_disk.odin).
// without_pit leaves the 8254 out of the machine (`pit=off`): the start of
// the kernel with no time base (src/md/features/missing_hardware.md).
// shared_variables: the variable store that the machines of a part share
// (start_policy_scenario.odin), or "" for a new copy. serial_input: the
// FIFO that is the input of the serial line of a test machine, which the
// caller made and opened (serial_input_linux.odin), or "" for none.
machine_command :: proc(volume: string, test_output: string, data_disk: string, peer: ^Peer, forward: Forward = {}, processor: Processor_Model = .Maximum, firmware: Machine_Firmware = .Usual, vnc := false, paused := false, iommu: Machine_Iommu = .None, entropy_device := false, tpm_device := false, clock_argument := "base=utc", memory_file := "", sound_output := "", without_screen := false, without_ps2_controller := false, entropy_device_silent := false, no_network_device := false, data_disk_without_ioevent := false, without_pit := false, shared_variables := "", serial_input := "") -> (command: []string, ok: bool) {
	// A machine starts only from a boot volume that this process built or
	// kept: a volume that the command did not ask for can be the volume of
	// older sources, and a test on it proves nothing. The variable store of
	// Secure Boot is an output of the build of one volume.
	if !build.boot_volume_is_ready(volume) || (firmware == .With_Secure_Boot && !build.boot_volume_is_ready(build.BOOT_VOLUME_SECURE_BOOT)) {
		fmt.eprintfln("modustool: the boot volume %s, or the variable store of Secure Boot, was not built or kept by the build of this command: add it to the volumes of the command (boot_volumes.odin)", volume)
		return nil, false
	}
	// Each machine starts from a new disk of the measures, of the first
	// size: the machine of AMD gives that disk a new size during its test
	// (iommu_scenario.odin), and a machine that kept the file would see that
	// size. The disk holds no data that a process keeps. A test machine has
	// its files beside its log: machines that run at the same time share no
	// file that QEMU writes.
	scratch_disk := test_output != "" ? machine_file(test_output, SCRATCH_DISK_SUFFIX) : SCRATCH_DISK
	if !disk_prepare(scratch_disk, SCRATCH_DISK_SIZE, true) {
		return nil, false
	}
	code_variable, variables_variable, variables_copy, variables_suffix := firmware_files(firmware)
	if test_output != "" {
		variables_copy = machine_file(test_output, variables_suffix)
	}
	firmware_code := os.get_env(code_variable, context.temp_allocator)
	firmware_variables := os.get_env(variables_variable, context.temp_allocator)
	// The machine with Secure Boot on starts from the variable store in
	// which the build enrolled the certificate of the firmware signing key
	// (secure_boot.odin), not from the empty store of the firmware.
	if firmware == .With_Secure_Boot {
		firmware_variables = build.SECURE_BOOT_VARIABLES
	}
	if firmware_code == "" || firmware_variables == "" {
		fmt.eprintfln("modustool: %s and %s are not set. Use the development shell: nix develop", code_variable, variables_variable)
		return nil, false
	}
	// The firmware writes its variables, so it gets a private copy. The
	// machines of a part that share a store copy it once: the first one
	// writes there what the next one reads.
	if shared_variables != "" {
		variables_copy = shared_variables
	}
	if shared_variables == "" || !os.exists(shared_variables) {
		if err := os.copy_file(variables_copy, firmware_variables); err != nil {
			fmt.eprintfln("modustool: cannot copy %s: %v", firmware_variables, err)
			return nil, false
		}
		if !foundation.run({"chmod", "u+w", variables_copy}) {
			return nil, false
		}
	}
	listener_port := forward.listener != nil ? forward.listener.port : 0
	// With the peer, QEMU uses a copy of the socket of the peer for the
	// machine; the caller closes the copy once QEMU started.
	machine_descriptor := 0
	if forward.host_port == 0 {
		machine_descriptor = peer_machine_socket_lend(peer) or_return
	}
	network_device := network_device_of(forward.host_port, listener_port, machine_descriptor)
	if problem := network_device_problem(network_device); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		peer_machine_socket_lent_close(peer)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	append(
		&list,
		"qemu-system-x86_64",
		"-machine",
		// The firmware with Secure Boot needs the system management mode of
		// the processor: its variables are written only there. QEMU refuses
		// interrupt remapping when KVM holds the whole interrupt controller:
		// the machine with the IOMMU splits it. QEMU accepts both together.
		strings.concatenate({"q35", firmware == .With_Secure_Boot ? ",smm=on" : "", iommu != .None ? ",kernel-irqchip=split" : "", memory_file != "" ? ",memory-backend=machine_memory" : "", without_ps2_controller ? ",i8042=off" : "", without_pit ? ",pit=off" : ""}, context.temp_allocator),
		"-accel",
		"kvm",
		"-accel",
		"tcg",
		"-cpu",
		processor_models[processor],
		// The main test keeps about 30 windows open, each with two
		// pictures, and then starts a process that maps 164 MiB.
		"-m",
		fmt.tprintf("%d", MACHINE_MEMORY_MIB),
		"-smp",
		fmt.tprintf("%d", memory_file != "" ? 1 : MACHINE_PROCESSOR_COUNT),
		"-device",
		"isa-debug-exit,iobase=0xf4,iosize=0x04",
		"-no-reboot",
		// The real-time clock of the machine: the clock of the host in UTC
		// for a machine that a principal runs; a fixed hour of the night for
		// a test machine (machine_clock.odin).
		"-rtc", clock_argument,
		"-net",
		"none", // No other network device than the one below.
		"-netdev",
		network_device,
	)
	// The machines of the parts iommu and iommu_amd: the remapping unit of
	// Intel or of AMD, before each device of PCI, which takes its place
	// behind it, with interrupt remapping (src/md/infrastructure/iommu.md,
	// "Interrupt remapping"). Without dma-remap, the unit of AMD translates
	// no access of an emulated device. Each virtio device sends its accesses
	// through the unit only with iommu_platform, which a device with the
	// legacy interface refuses.
	virtio_iommu := ""
	switch iommu {
	case .None:
	case .Intel:
		append(&list, "-device", "intel-iommu,intremap=on")
		virtio_iommu = ",iommu_platform=on"
	case .Amd:
		append(&list, "-device", "amd-iommu,dma-remap=on,intremap=on")
		virtio_iommu = ",iommu_platform=on"
	}
	if memory_file != "" {
		// The memory of the machine in a file that the tool reads and
		// writes while the machine runs: share=on gives the tool the pages
		// that the machine sees.
		append(&list, "-object", fmt.tprintf("memory-backend-file,id=machine_memory,size=%dM,mem-path=%s,share=on", MACHINE_MEMORY_MIB, memory_file))
	}
	if paused {
		// The machine waits for the step Monitor "cont" of the scenario: a
		// film catches each line of the start that a viewer must read.
		append(&list, "-S")
	}
	if forward.host_port != 0 {
		// Each frame of the device, with its time, for the tool after the run
		// (web_host.odin, frames_of_the_fetch_report).
		append(&list, "-object", strings.concatenate({"filter-dump,id=frames,netdev=network,file=", frames_of_user_network_file(test_output)}, context.temp_allocator))
	}
	if !no_network_device {
		append(&list, "-device", fmt.tprintf("virtio-net-pci,netdev=network,disable-legacy=on,mac=%s,addr=0x%x%s", MACHINE_HARDWARE, pci.NETWORK_DEVICE, virtio_iommu))
	}
	append(
		&list,
		"-drive",
		strings.concatenate({"if=pflash,format=raw,readonly=on,file=", firmware_code}, context.temp_allocator),
		"-drive",
		strings.concatenate({"if=pflash,format=raw,file=", variables_copy}, context.temp_allocator),
		"-drive",
		// Several machines boot one volume at the same time, and QEMU takes
		// a lock for writing on each image that it opens for writing: the
		// second machine would not start. With snapshot=on QEMU opens the
		// volume to read only, with a shared lock, and keeps each write of
		// the machine in a temporary file of its own. No process of the
		// system writes its boot volume (the block service serves the data
		// disk and the disk of the measures), and the firmware is not ours:
		// a write that it makes stays private, and no machine reads one.
		strings.concatenate({"if=none,id=boot,format=raw,snapshot=on,file=", volume}, context.temp_allocator),
		"-device",
		// The boot volume is the first boot option of the firmware: with no
		// bootindex, the order of its options follows its own enumeration,
		// and a firmware with a network stack can try a network boot first.
		// On the machine with the IOMMU, the boot disk has the modern
		// interface only, so that it too goes through the unit.
		iommu != .None ? "virtio-blk-pci,drive=boot,bootindex=0,disable-legacy=on,iommu_platform=on" : "virtio-blk-pci,drive=boot,bootindex=0",
		"-drive",
		strings.concatenate({"if=none,id=data,format=raw,file=", data_disk}, context.temp_allocator),
		"-device",
		fmt.tprintf("virtio-blk-pci,drive=data,disable-legacy=on,addr=0x%x%s%s", pci.DATA_DISK_DEVICE, data_disk_without_ioevent ? ",ioeventfd=off" : "", virtio_iommu),
		"-drive",
		strings.concatenate({"if=none,id=scratch,format=raw,file=", scratch_disk}, context.temp_allocator),
	)
	switch iommu {
	case .Intel:
		// The disk of the measures behind a root port of PCI Express, on the
		// bus that the firmware gives the port: the kernel must give it a
		// context table of that bus (src/md/infrastructure/iommu.md,
		// "Bridges").
		append(
			&list,
			"-device",
			fmt.tprintf("pcie-root-port,id=scratch_port,bus=pcie.0,chassis=1,addr=0x%x", pci.SCRATCH_BRIDGE_DEVICE),
			"-device",
			fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,bus=scratch_port,addr=0x0%s", virtio_iommu),
		)
	case .Amd:
		// The disk of the measures and an entropy device behind a
		// conventional bridge with no capability of PCI Express: both give
		// their accesses the requester of the bridge, on bus 0, and the
		// kernel gives them one domain (src/md/infrastructure/iommu.md,
		// "Bridges"). QEMU 10 records the device of a page fault of AMD-Vi
		// by its device and its function only, with no bus, so the line of
		// a DMA fault names the device only on bus 0: the requester of the
		// bridge is there (src/md/infrastructure/iommu.md, "Two vendors
		// behind one kernel side"). With no ioevent file, QEMU takes or
		// refuses a request of the disk before the notify of its service
		// returns: the stop of the machine in the test then ends each read
		// that it took.
		append(
			&list,
			"-device",
			fmt.tprintf("i82801b11-bridge,id=conventional_bridge,bus=pcie.0,addr=0x%x", pci.SCRATCH_BRIDGE_DEVICE),
			"-device",
			fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,ioeventfd=off,bus=conventional_bridge,addr=0x0%s", virtio_iommu),
			"-device",
			fmt.tprintf("virtio-rng-pci,disable-legacy=on,bus=conventional_bridge,addr=0x1%s", virtio_iommu),
		)
	case .None:
		append(&list, "-device", fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,addr=0x%x", pci.SCRATCH_DISK_DEVICE))
	}
	if entropy_device {
		// The bytes come from the generator of QEMU. Two vectors give the
		// device a table of message interrupts: the root service gives a
		// device service its entry 0, and starts none for a device with no
		// table.
		append(&list, "-device", fmt.tprintf("virtio-rng-pci,disable-legacy=on,vectors=2,addr=0x%x%s", pci.ENTROPY_DEVICE, virtio_iommu))
	}
	if entropy_device_silent {
		if test_output == "" {
			fmt.eprintln("modustool: a machine with an entropy device that never answers runs only as a test machine, with its own files")
			return nil, false
		}
		// The same device, whose source is the EGD protocol over a socket
		// that QEMU serves and no process connects to: the device takes
		// each read and never ends it, as a source of the host that stalls.
		append(&list, "-chardev", strings.concatenate({"socket,id=entropy_source,server=on,wait=off,path=", machine_file(test_output, ENTROPY_SOURCE_SOCKET_SUFFIX)}, context.temp_allocator))
		append(&list, "-object", "rng-egd,id=entropy_backend,chardev=entropy_source")
		append(&list, "-device", fmt.tprintf("virtio-rng-pci,rng=entropy_backend,disable-legacy=on,vectors=2,addr=0x%x%s", pci.ENTROPY_DEVICE, virtio_iommu))
	}
	if without_screen {
		// No display device: the firmware finds no graphics output, and the
		// kernel gives the root service no framebuffer.
		append(&list, "-vga", "none")
	}
	if sound_output != "" {
		// The sound device writes each frame that its stream gives to a wave
		// file, in the one format of the timed stream: QEMU then converts no
		// rate, and the file holds the frames of the sound service in order
		// (src/md/features/timed_stream.md, "The proof").
		append(&list, "-audiodev", fmt.tprintf("wav,id=sound,path=%s,out.frequency=%d,out.channels=%d,out.format=s16", sound_output, timed_stream.FRAME_RATE, timed_stream.CHANNELS))
		append(&list, "-device", fmt.tprintf("virtio-sound-pci,audiodev=sound,disable-legacy=on,addr=0x%x%s", pci.SOUND_DEVICE, virtio_iommu))
	}
	if firmware != .Usual || tpm_device {
		if test_output == "" {
			fmt.eprintln("modustool: a machine with a TPM or with Secure Boot runs only as a test machine, with its own files")
			return nil, false
		}
		// The firmware writes its own log on the debug console port: the
		// tool shows its end when the boot program does not start.
		append(&list, "-debugcon", strings.concatenate({"file:", machine_file(test_output, FIRMWARE_LOG_SUFFIX)}, context.temp_allocator), "-global", "isa-debugcon.iobase=0x402")
	}
	if firmware == .With_Secure_Boot {
		// The flash of the firmware with Secure Boot is writable only in
		// system management mode.
		append(&list, "-global", "driver=cfi.pflash01,property=secure,value=on")
	}
	if tpm_device {
		// The software TPM that machine_test starts (tpm_machine.odin),
		// through the socket of this machine, on the CRB interface: the
		// command and its answer are in a buffer of memory, not moved byte
		// by byte through one register. The device does not depend on the
		// firmware: the firmware with Secure Boot has a TPM driver too.
		append(&list, "-chardev", strings.concatenate({"socket,id=tpm_socket,path=", tpm_socket_of(test_output)}, context.temp_allocator))
		append(&list, "-tpmdev", "emulator,id=tpm,chardev=tpm_socket", "-device", "tpm-crb,tpmdev=tpm")
		// The trace of QEMU for the TPM, with the time of each line: when the
		// device received each command of the firmware and when the firmware
		// wrote to the device (a start, a cancel). It shows whether an
		// abandoned command reached QEMU and when the firmware gave it up.
		append(&list, "-msg", "timestamp=on", "-D", machine_file(test_output, QEMU_TRACE_SUFFIX))
		append(&list, "-trace", "enable=tpm_emulator_handle_request", "-trace", "enable=tpm_crb_mmio_write", "-trace", "enable=tpm_emulator_set_locality")
	}
	if test_output != "" {
		// No window. The log of the kernel (the serial port) goes to a file.
		// The monitor of QEMU for a reader is on the standard input: the tool
		// ends QEMU through it. The machine protocol of QEMU is on a socket
		// beside the log: the tool sends the keys and the moves of the
		// pointer through it, and each command has a reply (qmp.odin).
		// A film takes its pictures of a display with no window too, but a
		// display: QEMU draws the console of the firmware and of the boot
		// program in text there, which no display draws.
		if vnc {
			append(&list, "-display", strings.concatenate({"vnc=unix:", film_vnc_socket_of(test_output)}, context.temp_allocator))
		} else {
			append(&list, "-display", "none")
		}
		// With an input, the same file is the output of a file chardev, and
		// the FIFO beside it its input: each reader of the log is the same.
		if serial_input != "" {
			append(&list, "-chardev", strings.concatenate({"file,id=serial0,path=", test_output, ",input-path=", serial_input}, context.temp_allocator), "-serial", "chardev:serial0")
		} else {
			append(&list, "-serial", strings.concatenate({"file:", test_output}, context.temp_allocator))
		}
		append(&list, "-monitor", "stdio")
		append(&list, "-qmp", strings.concatenate({"unix:", qmp_socket_of(test_output), ",server=on,wait=off"}, context.temp_allocator))
		// A second socket of the same protocol, for the worker of a film:
		// its pictures and the keys of the scenario never share a reply
		// (film.odin). A machine with no film leaves it with no connection.
		append(&list, "-qmp", strings.concatenate({"unix:", film_qmp_socket_of(test_output), ",server=on,wait=off"}, context.temp_allocator))
	} else {
		append(&list, "-serial", "stdio")
	}
	return list[:], true
}

// network_device_of gives the network device of a machine: QEMU user
// networking with its TCP when host_port is not 0 (web_host.odin), else the
// peer (`-netdev dgram`).
network_device_of :: proc(host_port, listener_port, machine_descriptor: int) -> string {
	if host_port != 0 {
		return fmt.tprintf("user,id=network,restrict=on,hostfwd=tcp:127.0.0.1:%d-10.0.2.15:80,guestfwd=tcp:%s:80-tcp:127.0.0.1:%d", host_port, GUEST_ADDRESS, listener_port)
	}
	// The socket is bound and connected to the peer: QEMU takes no
	// address of its own (peer_start).
	return fmt.tprintf("dgram,id=network,local.type=fd,local.str=%d", machine_descriptor)
}

// network_device_problem refuses a network device that forwards a UDP port
// of the host to the port of `remote`. QEMU user networking gives each
// forwarded datagram the address 10.0.2.2, the one address that the grant
// of `remote` admits: such a forward opens the calls as the principal to
// whoever reaches the port of the host (docs/QUIC.md, section 7). A
// forward is "hostfwd=[tcp|udp]:[address]:port-[address]:port"; with no
// protocol it is TCP.
network_device_problem :: proc(device: string) -> string {
	for part in strings.split(device, ",", context.temp_allocator) {
		if !strings.has_prefix(part, "hostfwd=") {
			continue
		}
		rule := part[len("hostfwd="):]
		if !strings.has_prefix(rule, "udp:") {
			continue
		}
		dash := strings.last_index_byte(rule, '-')
		colon := strings.last_index_byte(rule, ':')
		if dash < 0 || colon < dash {
			return fmt.tprintf("the network device has a UDP forward that the tool cannot read: %s", part)
		}
		if rule[colon + 1:] == fmt.tprintf("%d", remote.LISTEN_PORT) {
			return fmt.tprintf("the network device forwards a UDP port of the host to the port %d of remote: each sender would call as the principal of the session of remote (%s)", remote.LISTEN_PORT, part)
		}
	}
	return ""
}

// disk_prepare makes a disk of zero bytes when the file is absent, or always
// with fresh.
disk_prepare :: proc(path: string, size: int, fresh: bool) -> bool {
	if !fresh && os.exists(path) {
		return true
	}
	zero := make([]u8, size)
	defer delete(zero)
	if err := os.write_entire_file(path, zero); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// The disks beside the boot volume (src/library/modus/pci has their places on the
// bus). The data disk keeps the stores of the storage service: `run` uses
// one that stays from run to run; each part of the test makes a new one of
// its own (Test_Part_Run). The disk of the measures holds no data that a
// process keeps: `run` uses SCRATCH_DISK, and a test machine a new one
// beside its log.
DATA_DISK :: foundation.BUILD_FOLDER + "/data_disk.img"
