package root

import "base:intrinsics"
import "modus:contract/entropy_service"
import "modus:contract/errors"
import "modus:contract/fresh_bytes"
import "modus:contract/ring"
import "modus:private/root/entropy_read_deadline"
import "modus:support/pci"
import "modus:support/random"
import "modus:support/system"

// The entropy service (src/md/features/entropy_device.md): the device
// service of the entropy device, with this service as its one client. This
// service asks it for two reads at its start, and mixes them into the
// generator that gives each process its seed. It never waits for them: a
// device that does not answer leaves the seed of the processor, and the
// start goes on.
//
// After the reads of the start, it asks for one read every
// FRESH_BYTES_PERIOD_MILLISECONDS, mixes it into its generator the same
// way, and writes 32 bytes of its stream in the fresh bytes page of each
// process (src/md/features/fresh_bytes.md; the code is in fresh_bytes.odin). The period
// bounds the time that a reader of one copy of the state of a process
// keeps its stream; the device and this service pay one read and one pass
// over the pages for each period, whatever the processes draw.
//
// Each read in flight has a deadline (entropy_read_deadline). A device that
// takes a read and never ends it holds the entropy service, which serves one
// read at a time: past the deadline, the reads in flight count as refused,
// one line says so, and the entropy service stops. The seed keeps the
// sources of the processor and the reads that ended.

ENTROPY_READS_AT_START :: 2 // Two reads of 32 bytes: 512 bits, as many as the values of rdseed in a seed.
ENTROPY_READ_BYTES :: 32
#assert(ENTROPY_READ_BYTES <= entropy_service.READ_BYTES_LIMIT)
#assert(ENTROPY_READS_AT_START <= entropy_service.RING_CAPACITY)

FRESH_BYTES_PERIOD_MILLISECONDS :: 30_000 // The time from one read of the fresh bytes to the next, and from the reads of the start to the first.
FRESH_BYTES_REFUSALS_LIMIT :: 3 // Refused reads in a row after which this service asks for no more: a broken device gives no fresh bytes.

entropy_ring: ring.Ring
entropy_ring_memory: system.Handle
entropy_process: ^Started
entropy_reads_asked: u32 // The reads that this service asked for: the tag of a read is its number.
entropy_reads_answered: u32
entropy_bytes_given: u64 // The bytes that the completions of the reads of the start carried, mixed or refused.
// The hash of the last read, which finds a read that comes again. It is a
// hash, not the bytes, and it stays for the reads of the fresh bytes.
entropy_mixing: random.Device_Mixing
// The device counts of the reads of the fresh bytes. The entropy report
// keeps the reads of the start only, so that what a process shows of the
// seed of the system does not depend on the time of its start.
fresh_bytes_counts: random.Entropy_Report
fresh_bytes_deadline: u64 = system.WAIT_FOREVER // The time of the next read of the fresh bytes. WAIT_FOREVER: none, or a read in flight.
fresh_bytes_refreshes: u64 // The reads of the fresh bytes that this service mixed.
fresh_bytes_refusals_in_a_row: u32
fresh_bytes_stopped: bool // No more reads of the fresh bytes: the service stopped, or the device refused too many.
entropy_read_asked_at: u64 // The time of the last read that this service asked for: its deadline counts from there.

// entropy_service_start starts the entropy service when the machine has an
// entropy device at its place, and asks it for the reads of the start.
// With no device, it writes one line and starts nothing.
entropy_service_start :: proc "contextless" () {
	place := pci.Place{device = pci.ENTROPY_DEVICE}
	if configuration_status := configuration_open(); configuration_status != .Ok {
		system.log(.Warning, "root: cannot read the configuration of the bus for the entropy device: status ", configuration_status, ": the random seed of the system has the sources of the processor only")
		return
	}
	identity := pci.read_32(place, 0)
	if identity != (pci.VENDOR_VIRTIO | pci.DEVICE_VIRTIO_ENTROPY << 16) {
		system.log(.Info, "root: no entropy device at the place ", u64(place.device), " of the bus: the random seed of the system has the sources of the processor only")
		return
	}
	driver, ring_memory, status := driver_start(place, DRIVER_ENTROPY)
	if status != .Ok {
		system.log(.Warning, "root: cannot start the entropy service: status ", status, ": the random seed of the system has the sources of the processor only")
		return
	}
	opened: ring.Ring
	if opened, status = system.ring_open(ring_memory); status != .Ok {
		// reap takes the device back when the service stopped.
		system.process_stop(driver.process)
		system.close(ring_memory)
		system.log(.Warning, "root: cannot open the entropy ring: status ", status, ": the random seed of the system has the sources of the processor only")
		return
	}
	entropy_ring, entropy_ring_memory, entropy_process = opened, ring_memory, driver
	entropy_report.device_present = true
	// The ring is new and empty: each command has a place.
	for _ in 0 ..< ENTROPY_READS_AT_START {
		ring.push(&entropy_ring.commands, ring.Record{kind = u32(entropy_service.Command.Read), tag = entropy_reads_asked, values = {0 = ENTROPY_READ_BYTES}})
		entropy_reads_asked += 1
	}
	entropy_read_asked_at = system.time()
	system.wake_reader(&entropy_ring.commands)
}

// entropy_answers reads the completion of each read that this service
// asked for, and no other one, and mixes the bytes of each one into the
// generator of the processes (random.device_bytes_mix refuses a read that
// adds nothing). After the last read of the start it writes the line of the
// device. After a read of the fresh bytes it writes the pages
// (fresh_bytes_refresh_end). Then it asks for the next read of the fresh
// bytes when its time came. wait is nil when the service stopped: nothing
// is asked then.
entropy_answers :: proc "contextless" (wait: ^system.Wait) {
	if entropy_ring.head == nil {
		return
	}
	for entropy_reads_answered < entropy_reads_asked {
		record := system.receive(&entropy_ring.completions) or_break
		number := entropy_reads_answered
		entropy_reads_answered += 1
		at_start := number < ENTROPY_READS_AT_START
		counts := at_start ? &entropy_report : &fresh_bytes_counts
		mixed := false
		if record.tag != number {
			// A completion of a read that was not asked for, or out of its
			// order: its bytes add nothing.
			counts.device_reads_refused += 1
			system.log_fact(.Warning, Entropy_Answer_Out_Of_Order{answered_read = u64(number), tagged_read = u64(record.tag)})
		} else if entropy_service.Status(record.kind) == .Ok {
			bytes: [entropy_service.READ_BYTES_LIMIT]u8
			count := entropy_service.bytes_unpack(record.values, &bytes)
			if at_start {
				entropy_bytes_given += u64(count)
			}
			mixed = random.device_bytes_mix(&process_generator, &entropy_mixing, bytes[:count], counts) == .Mixed
			intrinsics.mem_zero_volatile(&bytes, size_of(bytes))
		} else {
			counts.device_reads_refused += 1
			error := errors.completion_record(record.values)
			text: [240]u8
			writer := system.Writer{buffer = text[:]}
			system.ring_error_text(&writer, &error, "entropy", entropy_service.command_name(error.operation), entropy_service.argument_name(error.operation, error.argument))
			system.log(.Warning, "root: the entropy service refused a read: ", system.written(&writer))
		}
		intrinsics.mem_zero_volatile(&record, size_of(record))
		if !at_start {
			fresh_bytes_refresh_end(mixed)
		} else if entropy_reads_answered == ENTROPY_READS_AT_START {
			system.log(.Info, "root: the entropy device gave ", entropy_bytes_given, " bytes in ", u64(ENTROPY_READS_AT_START), " reads: ", u64(entropy_report.device_bytes), " bytes mixed into the random generator of the system; refused reads: ", u64(entropy_report.device_reads_refused))
			fresh_bytes_deadline = system.time() + FRESH_BYTES_PERIOD_MILLISECONDS
		}
	}
	if wait == nil {
		return
	}
	if entropy_reads_answered < entropy_reads_asked && entropy_read_deadline.read_overdue(entropy_read_asked_at, system.time()) {
		entropy_reads_late_end()
		return
	}
	fresh_bytes_read_ask()
	if entropy_reads_answered < entropy_reads_asked {
		system.wait_records(wait, &entropy_ring.completions)
	}
}

// entropy_read_deadline_time gives the time at which the reads in flight
// count as refused, or WAIT_FOREVER with no read in flight. The loop of this
// service ends its wait there.
entropy_read_deadline_time :: proc "contextless" () -> u64 {
	if entropy_ring.head == nil || entropy_reads_answered >= entropy_reads_asked {
		return system.WAIT_FOREVER
	}
	return entropy_read_deadline.read_deadline(entropy_read_asked_at)
}

// entropy_reads_late_end ends the reads in flight past their deadline: each
// counts as refused, as a read that the service refused, and the entropy
// service stops, as its device holds a read that it never ends and the
// service takes no other read while it waits. The answers that the service
// still writes before its stop are not read: this service no longer counts
// them.
entropy_reads_late_end :: proc "contextless" () {
	late := entropy_reads_asked - entropy_reads_answered
	for number in entropy_reads_answered ..< entropy_reads_asked {
		counts := number < ENTROPY_READS_AT_START ? &entropy_report : &fresh_bytes_counts
		counts.device_reads_refused += 1
	}
	entropy_reads_answered = entropy_reads_asked
	fresh_bytes_stopped = true
	fresh_bytes_deadline = system.WAIT_FOREVER
	intrinsics.mem_zero_volatile(&entropy_mixing, size_of(entropy_mixing)) // No read comes after these.
	system.log_fact(.Warning, Entropy_Reads_Late{deadline_seconds = u64(entropy_read_deadline.READ_DEADLINE_MILLISECONDS / 1000), late_reads = u64(late)})
	system.process_stop(entropy_process.process)
}

// fresh_bytes_read_ask asks the entropy service for the next read of the
// fresh bytes, when its time came and no read is in flight: one read at a
// time, so a device that does not answer is asked nothing more.
fresh_bytes_read_ask :: proc "contextless" () {
	if fresh_bytes_stopped || fresh_bytes_deadline == system.WAIT_FOREVER || entropy_reads_answered < entropy_reads_asked || system.time() < fresh_bytes_deadline {
		return
	}
	if !system.send(&entropy_ring.commands, ring.Record{kind = u32(entropy_service.Command.Read), tag = entropy_reads_asked, values = {0 = ENTROPY_READ_BYTES}}) {
		// Not reached while one read at most is in flight: the ring has a
		// place. The next period tries again, and the loop does not spin.
		fresh_bytes_deadline = system.time() + FRESH_BYTES_PERIOD_MILLISECONDS
		return
	}
	entropy_reads_asked += 1
	entropy_read_asked_at = system.time()
	fresh_bytes_deadline = system.WAIT_FOREVER
}

// fresh_bytes_refresh_end ends one read of the fresh bytes: after a mixed
// read it writes the page of each process, and the first time one line;
// after a refused read it writes one warning, and after
// FRESH_BYTES_REFUSALS_LIMIT in a row it asks for no more reads. A line for
// each refresh would fill the log.
fresh_bytes_refresh_end :: proc "contextless" (mixed: bool) {
	if !mixed {
		fresh_bytes_refusals_in_a_row += 1
		if fresh_bytes_refusals_in_a_row >= FRESH_BYTES_REFUSALS_LIMIT {
			system.log_fact(.Warning, Fresh_Bytes_Reads_Refused_In_A_Row{refused_reads = u64(fresh_bytes_refusals_in_a_row)})
			fresh_bytes_stopped = true
			fresh_bytes_deadline = system.WAIT_FOREVER
			intrinsics.mem_zero_volatile(&entropy_mixing, size_of(entropy_mixing)) // No read comes after this one.
			return
		}
		system.log_fact(.Warning, Fresh_Bytes_Read_Added_Nothing{refused_reads = u64(fresh_bytes_refusals_in_a_row)})
	} else {
		fresh_bytes_refusals_in_a_row = 0
		processes := fresh_bytes_write_all()
		fresh_bytes_refreshes += 1
		if fresh_bytes_refreshes == 1 {
			system.log(.Info, "root: the first fresh bytes: ", u64(ENTROPY_READ_BYTES), " bytes of the entropy device mixed into the random generator of the system, then ", u64(fresh_bytes.BYTES), " bytes of its stream in the fresh bytes page of each of ", processes, " processes; a read every ", u64(FRESH_BYTES_PERIOD_MILLISECONDS / 1000), " seconds after this one, with no line")
		}
	}
	fresh_bytes_deadline = system.time() + FRESH_BYTES_PERIOD_MILLISECONDS
}

// entropy_service_end forgets the ring of an entropy service that stopped,
// after it read the completions that the service wrote before its stop.
entropy_service_end :: proc "contextless" (item: ^Started) {
	if item != entropy_process || entropy_process == nil {
		return
	}
	// After a read past its deadline, each read counts as answered and the
	// fresh bytes are stopped: the line of the deadline is the one line.
	entropy_answers(nil)
	if entropy_reads_answered < ENTROPY_READS_AT_START {
		system.log_fact(.Warning, Entropy_Service_Stopped_Early{answered_reads = u64(entropy_reads_answered), start_reads = ENTROPY_READS_AT_START})
	} else if !fresh_bytes_stopped {
		system.log(.Warning, "root: the entropy service stopped: no more fresh bytes for the running processes")
	}
	fresh_bytes_stopped = true
	fresh_bytes_deadline = system.WAIT_FOREVER
	intrinsics.mem_zero_volatile(&entropy_mixing, size_of(entropy_mixing))
	system.ring_close(&entropy_ring)
	system.close(entropy_ring_memory)
	entropy_ring_memory, entropy_process = 0, nil
}
