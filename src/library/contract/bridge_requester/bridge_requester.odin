// The rule of a bridge of PCI that the kernel and the root service share:
// whether a bridge gives each device behind it its own requester, or one
// requester for all of them. The kernel reads it to give the devices behind
// a conventional bridge one domain of the IOMMU, and the root service reads
// it to give those devices to one service, so that no service reaches the
// memory of the devices of another (src/md/infrastructure/iommu.md,
// "Bridges"). The rule reads the space of the configuration of PCI of the
// bridge, as the "PCI Express Base Specification" gives it.
//
// Each procedure here is pure: it reads values and gives values, so the
// host tests check the rule with no machine.
//
// This package allocates no memory and calls no kernel operation.
package bridge_requester

// The words of the configuration of a function that the kernel and the
// root service read to know the kind of a bridge: the first 256 bytes, the
// space of PCI before PCI Express, which holds the capability of PCI
// Express.
CONFIGURATION_WORDS :: 64
CAPABILITY_PCI_EXPRESS :: 0x10
STATUS_CAPABILITIES :: u32(1) << 20 // The bit of the status, in the word 1: the function has a list of capabilities.

// The port types of the capability of PCI Express (bits 7:4 of its
// capability register) whose bridge passes the requester of each device
// behind it unchanged: a root port, the upstream and the downstream port of
// a switch.
PORT_ROOT :: 4
PORT_SWITCH_UPSTREAM :: 5
PORT_SWITCH_DOWNSTREAM :: 6
// The port type of a bridge from PCI Express to PCI: a conventional bridge
// that gives the devices behind it the requester of its secondary bus.
PORT_PCI_EXPRESS_TO_PCI :: 7

// express_port_type gives the port type of the capability of PCI Express of
// a function. found: the function has that capability. The walk of the
// capabilities stops after 48, as a list that loops would never end.
express_port_type :: proc "contextless" (configuration: ^[CONFIGURATION_WORDS]u32) -> (port: u32, found: bool) {
	if configuration[1] & STATUS_CAPABILITIES == 0 {
		return 0, false
	}
	offset := configuration[0x34 / 4] & 0xFC
	for _ in 0 ..< 48 {
		if offset < 0x40 || offset > 0xFC {
			return 0, false
		}
		word := configuration[offset / 4]
		if word & 0xFF == CAPABILITY_PCI_EXPRESS {
			return word >> 20 & 0xF, true
		}
		offset = word >> 8 & 0xFC
	}
	return 0, false
}

// bridge_passes_requesters says if a bridge gives each device behind it
// its own requester. A bridge of PCI Express does. A conventional bridge (a
// bridge from PCI Express to PCI, or one with no capability of PCI Express)
// gives the accesses of the devices behind it one shared requester.
bridge_passes_requesters :: proc "contextless" (configuration: ^[CONFIGURATION_WORDS]u32) -> bool {
	port, found := express_port_type(configuration)
	return found && (port == PORT_ROOT || port == PORT_SWITCH_UPSTREAM || port == PORT_SWITCH_DOWNSTREAM)
}
