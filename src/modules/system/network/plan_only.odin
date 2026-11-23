package network_service

import module "modus:contract/module"
import "modus:contract/errors"
import "internal:network/dhcp_client"

// plan_only describes the plan-only values of the network service: a static address of the machine in place of DHCP. Only the plan of principal 0 gives them (src/md/features/dhcp_client.md); the console types a plan by this description. The network service serves no call: the description is in its module file only.
//
// - **static_address**: the IPv4 address, as one number: 10.0.2.15 is 167772687.
// - **static_prefix**: the bits of the subnet, 8 to 30.
// - **static_gateway**: the IPv4 address of the gateway, 0 for none.
//
// The result is -1 with an error record: No_Grant, unit Plan_Lock.
@(export, link_name = "plan_only", parameter_ranges = "static_address = 1..4294967294, static_prefix = 8..30, static_gateway = 0..4294967294")
plan_only_export :: proc "c" (static_address_presence: module.Presence, static_address: i64, static_prefix_presence: module.Presence, static_prefix: i64, static_gateway_presence: module.Presence, static_gateway: i64, error: ^errors.Error_Record) -> i64 {
	return errors.fail(error, -1, .No_Grant, .Plan_Lock, 0)
}

#assert(dhcp_client.PREFIX_LEAST == 8 && dhcp_client.PREFIX_MOST == 30)
