#+build !freestanding
package bridge_requester

import "core:testing"

// configuration_with_express_port gives the configuration of a function
// whose list of capabilities holds a capability of messages at 0x40, then
// the capability of PCI Express of a port type at 0x60.
configuration_with_express_port :: proc(port: u32) -> (configuration: [CONFIGURATION_WORDS]u32) {
	configuration[1] = STATUS_CAPABILITIES
	configuration[0x34 / 4] = 0x40
	configuration[0x40 / 4] = 0x0000_6005 // A capability of messages, then 0x60.
	configuration[0x60 / 4] = port << 20 | CAPABILITY_PCI_EXPRESS
	return
}

// A list of capabilities that the walk must refuse: no status bit, a first
// place inside the header, a list that loops, a next place inside the
// header. Each gives no port, and no bridge that passes the requesters.
@(test)
a_list_of_capabilities_that_names_no_port :: proc(t: ^testing.T) {
	configuration: [CONFIGURATION_WORDS]u32
	_, found := express_port_type(&configuration)
	testing.expect(t, !found) // No list of capabilities.
	testing.expect(t, !bridge_passes_requesters(&configuration))

	// A capability of PCI Express that the status does not announce.
	configuration = configuration_with_express_port(PORT_ROOT)
	configuration[1] = 0
	_, found = express_port_type(&configuration)
	testing.expect(t, !found)
	testing.expect(t, !bridge_passes_requesters(&configuration))

	// A first place inside the header of 64 bytes.
	configuration = configuration_with_express_port(PORT_ROOT)
	configuration[0x34 / 4] = 0x3C
	_, found = express_port_type(&configuration)
	testing.expect(t, !found)

	// A next place inside the header.
	configuration = configuration_with_express_port(PORT_ROOT)
	configuration[0x40 / 4] = 0x0000_3C05
	_, found = express_port_type(&configuration)
	testing.expect(t, !found)

	// A list that comes back to 0x40 and holds no capability of PCI Express.
	configuration = configuration_with_express_port(PORT_ROOT)
	configuration[0x60 / 4] = 0x0000_4005
	_, found = express_port_type(&configuration)
	testing.expect(t, !found)
	testing.expect(t, !bridge_passes_requesters(&configuration))
}

// A bridge of PCI Express passes the requester of each device behind it; a
// conventional bridge, and each port type that is not a bridge of PCI
// Express, does not.
@(test)
the_kinds_of_a_bridge :: proc(t: ^testing.T) {
	for port in u32(0) ..= 0xF {
		configuration := configuration_with_express_port(port)
		found_port, found := express_port_type(&configuration)
		testing.expect(t, found)
		testing.expect_value(t, found_port, port)
		passes := port == PORT_ROOT || port == PORT_SWITCH_UPSTREAM || port == PORT_SWITCH_DOWNSTREAM
		testing.expect_value(t, bridge_passes_requesters(&configuration), passes)
	}
	// A bridge from PCI Express to PCI, and a bridge from PCI to PCI
	// Express (the port type after it), are conventional.
	configuration := configuration_with_express_port(PORT_PCI_EXPRESS_TO_PCI)
	testing.expect(t, !bridge_passes_requesters(&configuration))
	configuration = configuration_with_express_port(PORT_PCI_EXPRESS_TO_PCI + 1)
	testing.expect(t, !bridge_passes_requesters(&configuration))
	// The last case: a root port at the first place of the list.
	configuration = {}
	configuration[1] = STATUS_CAPABILITIES
	configuration[0x34 / 4] = 0x40
	configuration[0x40 / 4] = u32(PORT_ROOT) << 20 | CAPABILITY_PCI_EXPRESS
	testing.expect(t, bridge_passes_requesters(&configuration))
}
