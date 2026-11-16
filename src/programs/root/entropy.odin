package root

import "base:intrinsics"
import "modus:contract/entropy_service"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:support/pci"
import "modus:support/random"
import "modus:support/system"

// The entropy service (src/md/features/entropy_device.md): the device
// service of the entropy device, with this service as its one client. This
// service asks it for bytes once, at its start, and mixes them into the
// generator that gives each program its seed. It never waits for them: a
// device that does not answer leaves the seed of the processor, and the
// start goes on.

ENTROPY_READS_AT_START :: 2 // Two reads of 32 bytes: 512 bits, as many as the values of rdseed in a seed.
ENTROPY_READ_BYTES :: 32
#assert(ENTROPY_READ_BYTES <= entropy_service.READ_BYTES_LIMIT)
#assert(ENTROPY_READS_AT_START <= entropy_service.RING_CAPACITY)

entropy_ring: ring.Ring
entropy_ring_memory: system.Handle
entropy_program: ^Started
entropy_reads_answered: u32
entropy_bytes_given: u64 // The bytes that the completions carried, mixed or refused.
entropy_mixing: random.Device_Mixing

// entropy_service_start starts the entropy service when the machine has an
// entropy device at its place, and asks it for the reads of the start.
// With no device, it writes one line and starts nothing.
entropy_service_start :: proc "contextless" () {
	place := pci.Place{device = pci.ENTROPY_DEVICE}
	if configuration_status := configuration_open(); configuration_status != .Ok {
		system.log_in("devices", .Warning, "root: cannot read the configuration of the bus for the entropy device: status ", configuration_status, ": the random seed of the system has the sources of the processor only")
		return
	}
	identity := pci.read_32(place, 0)
	if identity != (pci.VENDOR_VIRTIO | pci.DEVICE_VIRTIO_ENTROPY << 16) {
		system.log_in("devices", .Info, "root: no entropy device at the place ", u64(place.device), " of the bus: the random seed of the system has the sources of the processor only")
		return
	}
	driver, ring_memory, status := driver_start(place, DRIVER_ENTROPY)
	if status != .Ok {
		system.log_in("devices", .Warning, "root: cannot start the entropy service: status ", status, ": the random seed of the system has the sources of the processor only")
		return
	}
	opened: ring.Ring
	if opened, status = system.ring_open(ring_memory); status != .Ok {
		// reap takes the device back when the service stopped.
		system.call(.Program_Stop, u64(driver.program), 0)
		system.close(ring_memory)
		system.log_in("devices", .Warning, "root: cannot open the entropy ring: status ", status, ": the random seed of the system has the sources of the processor only")
		return
	}
	entropy_ring, entropy_ring_memory, entropy_program = opened, ring_memory, driver
	entropy_report.device_present = true
	// The ring is new and empty: each command has a place.
	for index in 0 ..< ENTROPY_READS_AT_START {
		ring.push(&entropy_ring.commands, ring.Record{kind = u32(entropy_service.Command.Read), tag = u32(index), values = {0 = ENTROPY_READ_BYTES}})
	}
	system.wake_reader(&entropy_ring.commands)
}

// entropy_answers reads the completions of the reads of the start, and
// mixes the bytes of each one into the generator of the programs
// (random.device_bytes_mix refuses a read that adds nothing). After the
// last one it writes the line of the device, and reads the ring no more: a
// completion that this service did not ask for is never read. wait is nil
// when the service stopped.
entropy_answers :: proc "contextless" (wait: ^system.Wait) {
	if entropy_ring.head == nil || entropy_reads_answered >= ENTROPY_READS_AT_START {
		return
	}
	for entropy_reads_answered < ENTROPY_READS_AT_START {
		record := system.receive(&entropy_ring.completions) or_break
		entropy_reads_answered += 1
		if entropy_service.Status(record.kind) == .Ok {
			bytes: [entropy_service.READ_BYTES_LIMIT]u8
			count := entropy_service.bytes_unpack(record.values, &bytes)
			entropy_bytes_given += u64(count)
			random.device_bytes_mix(&program_generator, &entropy_mixing, bytes[:count], &entropy_report)
			intrinsics.mem_zero_volatile(&bytes, size_of(bytes))
			intrinsics.mem_zero_volatile(&record, size_of(record))
			continue
		}
		entropy_report.device_reads_refused += 1
		error := errors.completion_record(record.values)
		text: [240]u8
		writer := system.Writer{buffer = text[:]}
		system.ring_error_text(&writer, &error, "entropy", entropy_service.command_name(error.operation), entropy_service.argument_name(error.operation, error.argument))
		system.log_in("devices", .Warning, "root: the entropy service refused a read: ", system.written(&writer))
	}
	if entropy_reads_answered == ENTROPY_READS_AT_START {
		// The hash of the last read finds a read that comes again; no read
		// comes after this one, and no copy of the bytes is kept.
		intrinsics.mem_zero_volatile(&entropy_mixing, size_of(entropy_mixing))
		system.log_in("devices", .Info, "root: the entropy device gave ", entropy_bytes_given, " bytes in ", u64(ENTROPY_READS_AT_START), " reads: ", u64(entropy_report.device_bytes), " bytes mixed into the random generator of the system; refused reads: ", u64(entropy_report.device_reads_refused))
		return
	}
	if wait != nil {
		system.wait_records(wait, &entropy_ring.completions)
	}
}

// entropy_service_end forgets the ring of an entropy service that stopped,
// after it read the completions that the service wrote before its stop.
entropy_service_end :: proc "contextless" (item: ^Started) {
	if item != entropy_program || entropy_program == nil {
		return
	}
	entropy_answers(nil)
	if entropy_reads_answered < ENTROPY_READS_AT_START {
		system.log_in("devices", .Warning, "root: the entropy service stopped after ", u64(entropy_reads_answered), " of ", u64(ENTROPY_READS_AT_START), " reads: the random seed of the system has the bytes of those reads only")
	}
	system.ring_close(&entropy_ring)
	system.close(entropy_ring_memory)
	entropy_ring_memory, entropy_program = 0, nil
}
