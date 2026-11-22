// Live per-endpoint isolated receive queue table integrated into the network
// service so a packet flood on one port never starves another endpoint.
package network_service

import "modus:contract/serial_ring"

network_endpoint_rx: serial_ring.Endpoint_Rx_Table

network_endpoint_rx_register :: proc "contextless" (port: u16) -> bool {
	if port == 0 {
		return false
	}
	for i in 0 ..< serial_ring.MAX_ENDPOINTS {
		if network_endpoint_rx.active[i] && network_endpoint_rx.endpoint_ports[i] == port {
			return true
		}
	}
	for i in 0 ..< serial_ring.MAX_ENDPOINTS {
		if !network_endpoint_rx.active[i] {
			network_endpoint_rx.active[i] = true
			network_endpoint_rx.endpoint_ports[i] = port
			network_endpoint_rx.queued[i] = 0
			return true
		}
	}
	return false
}

network_endpoint_rx_admit :: proc "contextless" (port: u16) -> bool {
	return serial_ring.endpoint_rx_enqueue(&network_endpoint_rx, port)
}
