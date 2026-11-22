// Per-endpoint isolated receive queue helpers for network_service
// (contract-level helpers wired with owner-bound register/dequeue/unregister).
package network_service

import "modus:contract/serial_ring"

network_endpoint_rx: serial_ring.Endpoint_Rx_Table

network_endpoint_rx_register :: proc "contextless" (owner_id: u64, port: u16) -> bool {
	return serial_ring.endpoint_rx_register(&network_endpoint_rx, owner_id, port)
}

network_endpoint_rx_unregister :: proc "contextless" (owner_id: u64, port: u16) -> bool {
	return serial_ring.endpoint_rx_unregister(&network_endpoint_rx, owner_id, port)
}

network_endpoint_rx_admit :: proc "contextless" (port: u16) -> bool {
	return serial_ring.endpoint_rx_enqueue(&network_endpoint_rx, port)
}

network_endpoint_rx_consume :: proc "contextless" (owner_id: u64, port: u16) -> bool {
	return serial_ring.endpoint_rx_dequeue(&network_endpoint_rx, owner_id, port)
}
