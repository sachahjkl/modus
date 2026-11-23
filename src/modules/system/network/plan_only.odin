package network_service

import module "modus:contract/module"
import "modus:contract/errors"
import "modus:network"

// plan_only describes the plan-only values of the network service: a static address of the machine in place of DHCP. Only the plan of principal 0 gives them (src/md/features/dhcp_client.md, "The static address of the plan"); the console types a plan by this description. The network service serves no call: the description is in its module file only.
//
// - **static_address**: the IPv4 address and the bits of its prefix, "10.0.2.15/24": a prefix of 1 to 32 bits, an address that a machine of its prefix can hold.
// - **static_gateway**: the IPv4 address of the gateway, "10.0.2.2", on the link of the address.
//
// The result is -1 with an error record: No_Grant, unit Plan_Lock.
//
// ```
// plans.apply("static", plan { values = { network = { static_address = "10.0.2.15/24", static_gateway = "10.0.2.2" } } }, {})
// ```
@(export, link_name = "plan_only", parameter_ranges = "static_address = 9..18, static_gateway = 7..15")
plan_only_export :: proc "c" (static_address_presence: module.Presence, static_address: ^string, static_gateway_presence: module.Presence, static_gateway: ^string, error: ^errors.Error_Record) -> i64 {
	return errors.fail(error, -1, .No_Grant, .Plan_Lock, 0)
}

// The bounds of the description are the longest texts of the border:
// "255.255.255.255/32" and "255.255.255.255"; the shortest are "0.0.0.0/0"
// and "0.0.0.0".
#assert(network.INTERFACE_TEXT_BYTES_MOST == 18 && network.ADDRESS_TEXT_BYTES_MOST == 15)
