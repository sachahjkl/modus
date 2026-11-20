package root

import "modus:contract/datagram"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/ring"
import "modus:support/system"

// The network. The network service is the one client of the frame service of
// the network device; it starts when a process with the grant Network starts
// (on demand, as the storage service). This service gives each such process
// one endpoint (src/library/contract/datagram): a datagram ring that it gives to the two
// processes, and a grant that it names on the control ring of the network
// service. The process cannot choose its remote or its local port: it has
// no ambient network, and no port is a global name.

// The right Inspect of the grant of an endpoint (the facts of the network
// of the machine: the frames that no endpoint owns, the kernel entries of
// the two services) goes only to a process that holds the machine with the
// right Inspect: it reads the facts of all processes already, and no other
// process learns of the traffic of another.

QUIC_ECHO_PORT :: 4433 // The UDP port of quic_echo: the port of the examples of RFC 9000 implementations.

// endpoint_of gives the grant of the endpoint of a process (docs/NETWORK.md):
//   net     a datagram endpoint: the echo server of the test, 10.0.2.2 port 7.
//   remote  a datagram endpoint with a listen grant: the UDP port
//           remote.LISTEN_PORT, and only the remotes of the address of the
//           host (10.0.2.2) that send a datagram of 1200 bytes to it: QUIC
//           in the process (docs/QUIC.md, section 7).
//   remote_display  the same, on the UDP port remote_display.LISTEN_PORT
//           (docs/QUIC.md, "8. The remote display").
//   server  a segment endpoint with a listen grant: the TCP port 80, and the
//           remotes that send a segment to it.
//   fetch   a segment endpoint with a client grant: 10.0.2.100 port 80, the
//           web server of the test (the tool behind QEMU user networking).
//   processes  the same client grant: the module file service fetches a
//           module file from the web server that QEMU gives that address.
//   quic_echo  a datagram endpoint with a listen grant: the UDP port 4433,
//           and the remotes that send a datagram of 1200 bytes to it.
endpoint_of :: proc "contextless" (name: string) -> datagram.Grant {
	switch name {
	case "net":
		return {address = 0x0A000202, port = 7}
	case "remote":
		return {address = remote.HOST_ADDRESS, port = remote.LISTEN_PORT, listen = true}
	case "remote_display":
		return {address = remote.HOST_ADDRESS, port = remote_display.LISTEN_PORT, listen = true}
	case "server":
		return {port = 80, tcp = true, listen = true}
	case "fetch", "module_files":
		return {address = 0x0A000264, port = 80, tcp = true}
	case "quic_echo":
		return {port = QUIC_ECHO_PORT, listen = true}
	}
	return {}
}

// The network service stopped, or did not start: no process with an
// endpoint starts until the machine starts again. A frame service that
// stops at each start would cost a start of two services and a line for
// each process that asks (src/md/features/missing_hardware.md).
network_refused: bool

// network_refuse refuses the network from now on, with one line.
network_refuse :: proc "contextless" (cause: string) {
	if network_refused {
		return
	}
	network_refused = true
	system.log_fact(.Warning, Network_Refused{network_cause = text_field(cause, 40)})
}

// network_service gives the network service that runs, or starts it.
network_service :: proc "contextless" () -> (service: ^Started, status: system.Status) {
	for &item in started {
		if item.process != 0 && item.network.head != nil {
			return &item, .Ok
		}
	}
	if network_refused {
		return nil, .Bad_State
	}
	if status = start("network"); status != .Ok {
		// Only an absent device is for ever: driver_start gives Bad_Handle
		// when no network device is at its place. A full table, a short
		// budget or short memory can pass at a later start.
		if status == .Bad_Handle {
			network_refuse("the network service did not start")
		}
		return nil, status
	}
	for &item in started {
		if item.process != 0 && item.network.head != nil {
			return &item, .Ok
		}
	}
	return nil, .Bad_State
}

// endpoint_open makes the endpoint of a process that starts: the datagram
// ring and the datagram region, given to the network service with the
// grant. This service makes the region, not the process: a region of the
// process would let the process revoke the mapping of the network service,
// which would stop on a page fault for all processes. The network service
// gets the region with Give: it gives it to the frame service with Read
// only, and the device reads the data of each send there
// (src/md/infrastructure/network_data_path.md, "The send with no copy").
// When the unit of the IOMMU of the network device gives device windows, the
// region is not contiguous: the kernel gives the device a window where its
// pages follow each other, and a machine with fragmented memory still
// starts the process. Else (no IOMMU, a device that no unit covers, a unit
// of too few bits) it is contiguous, as the device needs one address. It
// gives the two handles: give them to the process, then close them.
endpoint_open :: proc "contextless" (slot: ^Started, name: string) -> (ring_memory, region_memory: system.Handle, status: system.Status) {
	service := network_service() or_return
	ring_memory = system.memory_create(ring.pages(datagram.RING_CAPACITY)) or_return
	region_flags := network_device_windows ? op.Memory_Flags{} : op.Memory_Flags{.Contiguous}
	region_memory, status = system.memory_create(datagram.REGION_PAGES, 0, region_flags)
	given: [2]system.Handle
	if status == .Ok {
		given[0], status = system.give(service.network_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		given[1], status = system.give(service.network_memory, region_memory, {.Read, .Write, .Give})
	}
	grant := endpoint_of(name)
	grant.inspect = .Inspect in slot.role.grants
	packed := system.name_pack(name)
	if status == .Ok && !system.send(&service.network.commands, ring.Record{kind = u32(datagram.Control.Endpoint_Add), values = {0 = u64(given[0]), 1 = u64(given[1]), 2 = datagram.grant_pack(grant), 3 = packed[0], 4 = packed[1], 5 = packed[2], 6 = packed[3]}}) {
		status = .No_Slot
	}
	if status != .Ok {
		// A handle that the network service received and never uses stays in
		// its table until it stops; the case needs a full control ring.
		system.close(ring_memory)
		if region_memory != 0 {
			system.close(region_memory)
		}
		return 0, 0, status
	}
	slot.endpoint, slot.network_service = given[0], service
	return ring_memory, region_memory, .Ok
}

// endpoint_close ends the endpoint of a process that stopped.
endpoint_close :: proc "contextless" (item: ^Started) {
	if item.endpoint != 0 && item.network_service != nil && item.network_service.process != 0 {
		system.send(&item.network_service.network.commands, ring.Record{kind = u32(datagram.Control.Endpoint_Remove), values = {0 = u64(item.endpoint)}})
	}
	item.endpoint, item.network_service = 0, nil
}

// endpoint_revoke ends the grant of an endpoint: the network service refuses
// each request that names a remote, and no datagram reaches the process.
endpoint_revoke :: proc "contextless" (item: ^Started) -> (count: u64) {
	if item.endpoint != 0 && item.network_service != nil && item.network_service.process != 0 {
		if system.send(&item.network_service.network.commands, ring.Record{kind = u32(datagram.Control.Endpoint_Grant), values = {0 = u64(item.endpoint), 1 = 0}}) {
			return 1
		}
	}
	return 0
}

// network_answers reads the completions of the control ring of each network
// service: a refused endpoint goes on the log.
network_answers :: proc "contextless" (wait: ^system.Wait) {
	for &item in started {
		if item.process == 0 || item.network.head == nil {
			continue
		}
		for record in system.receive(&item.network.completions) {
			if datagram.Status(record.kind) != .Ok {
				error := errors.completion_record(record.values)
				text: [240]u8
				writer := system.Writer{buffer = text[:]}
				system.ring_error_text(&writer, &error, "datagram", datagram.control_name(error.operation), datagram.control_argument_name(error.operation, error.argument))
				system.log(.Warning, "root: the network service refused a command of its control ring: ", system.written(&writer))
			}
		}
		if wait != nil {
			system.wait_records(wait, &item.network.completions)
		}
	}
}

// network_end forgets a network service that stopped.
network_end :: proc "contextless" (item: ^Started) {
	for &other in started {
		if other.network_service == item {
			other.network_service, other.endpoint = nil, 0
		}
	}
	system.ring_close(&item.network)
	system.close(item.network_memory)
	network_refuse("the network service stopped")
}
