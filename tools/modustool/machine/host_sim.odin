// Deterministic single-threaded multi-service message-passing host simulator
// (src/md/infrastructure/fast_build.md).
//
// Runs simulated modus services connected by bounded grant-checked rings on a
// deterministic virtual monotonic clock with a round-robin step scheduler,
// zero sleeps, and zero QEMU overhead.
package machine

// Plan value: maximum distinct services in one host simulation run.
HOST_SIM_MAX_SERVICES :: 16

// Plan value: maximum directed rings connecting simulated services.
HOST_SIM_MAX_LINKS :: 32

// Inline capacity: fixed FIFO message queue capacity per directed ring so
// ring-full backpressure is deterministic and directly testable.
HOST_SIM_RING_CAPACITY :: 32

// Format property: fixed compact message payload size per simulated ring record.
HOST_SIM_PAYLOAD_BYTES :: 128

// Plan value: default virtual monotonic clock increment per scheduler step (1 ms).
HOST_SIM_DEFAULT_TICK_NS :: u64(1_000_000)

// Closed status set for simulated service message delivery and handler replies.
Host_Sim_Status :: enum u8 {
	Ok,
	Refused_No_Grant,
	Refused_Full,
	Refused_Unknown_Service,
	Refused_Stopped,
	Refused_Bad_Message,
}

// Closed border refusal set for simulation setup and stepping operations.
Host_Sim_Refusal :: enum u8 {
	None,
	Service_Limit_Reached,
	Duplicate_Service_Name,
	Empty_Service_Name,
	Nil_Handler,
	Ring_Limit_Reached,
	Invalid_Service_Id,
	Invalid_Link_Id,
	Self_Link_Refused,
	Ring_Full,
	Payload_Too_Large,
	Step_Limit_Reached,
}

// Closed grant bit set checked on every simulated ring send.
Host_Sim_Grant_Bit :: enum u8 {
	Read_Store,
	Write_Store,
	Network_Client,
	Publish_Cache,
	Plan_Apply,
}

Host_Sim_Grants :: bit_set[Host_Sim_Grant_Bit; u32]

// One fixed-layout message transferred across a simulated service ring.
Host_Sim_Message :: struct {
	tag:         u64,
	kind:        u32,
	status:      Host_Sim_Status,
	sender_id:   int,
	sent_at_ns:  u64,
	payload_len: u16,
	payload:     [HOST_SIM_PAYLOAD_BYTES]u8,
}

// One bounded directed FIFO ring between two simulated services.
Host_Sim_Ring :: struct {
	active:  bool,
	from_id: int,
	to_id:   int,
	grants:  Host_Sim_Grants,
	head:    int,
	count:   int,
	slots:   [HOST_SIM_RING_CAPACITY]Host_Sim_Message,
}

Host_Sim_Handler :: proc(sim: ^Host_Sim, self_id: int, msg: Host_Sim_Message) -> Host_Sim_Status

// One registered service inside the deterministic host simulation.
Host_Sim_Service :: struct {
	active:           bool,
	id:               int,
	name:             string,
	grants:           Host_Sim_Grants,
	steps_run:        u64,
	handled_messages: u64,
	handler:          Host_Sim_Handler,
	user_data:        rawptr,
}

// Whole deterministic multi-service host simulation state.
Host_Sim :: struct {
	now_ns:              u64,
	tick_step_ns:        u64,
	total_steps:         u64,
	delivered_messages:  u64,
	refused_messages:    u64,
	next_service_cursor: int,
	service_count:       int,
	link_count:          int,
	services:            [HOST_SIM_MAX_SERVICES]Host_Sim_Service,
	links:               [HOST_SIM_MAX_LINKS]Host_Sim_Ring,
}

// host_sim_init resets sim to a clean zero state with a monotonic virtual clock.
host_sim_init :: proc(sim: ^Host_Sim, tick_step_ns := HOST_SIM_DEFAULT_TICK_NS) {
	sim^ = {}
	sim.tick_step_ns = tick_step_ns > 0 ? tick_step_ns : HOST_SIM_DEFAULT_TICK_NS
}

// host_sim_register_service registers a service with its fixed grant set and
// message handler. Refuses empty names, duplicate names, nil handlers, and
// capacity overflow.
host_sim_register_service :: proc(sim: ^Host_Sim, name: string, grants: Host_Sim_Grants, handler: Host_Sim_Handler, user_data: rawptr = nil) -> (id: int, refusal: Host_Sim_Refusal) {
	if len(name) == 0 {
		return -1, .Empty_Service_Name
	}
	if handler == nil {
		return -1, .Nil_Handler
	}
	if sim.service_count >= HOST_SIM_MAX_SERVICES {
		return -1, .Service_Limit_Reached
	}
	for i in 0 ..< sim.service_count {
		if sim.services[i].name == name {
			return -1, .Duplicate_Service_Name
		}
	}
	id = sim.service_count
	sim.services[id] = {
		active    = true,
		id        = id,
		name      = name,
		grants    = grants,
		handler   = handler,
		user_data = user_data,
	}
	sim.service_count += 1
	return id, .None
}

// host_sim_connect creates a bounded directed ring from from_id to to_id
// carrying link_grants (bounded by sender's grants at send time).
host_sim_connect :: proc(sim: ^Host_Sim, from_id, to_id: int, link_grants: Host_Sim_Grants) -> (link_id: int, refusal: Host_Sim_Refusal) {
	if from_id < 0 || from_id >= sim.service_count || !sim.services[from_id].active {
		return -1, .Invalid_Service_Id
	}
	if to_id < 0 || to_id >= sim.service_count || !sim.services[to_id].active {
		return -1, .Invalid_Service_Id
	}
	if from_id == to_id {
		return -1, .Self_Link_Refused
	}
	if sim.link_count >= HOST_SIM_MAX_LINKS {
		return -1, .Ring_Limit_Reached
	}
	link_id = sim.link_count
	sim.links[link_id] = {
		active  = true,
		from_id = from_id,
		to_id   = to_id,
		grants  = link_grants,
	}
	sim.link_count += 1
	return link_id, .None
}

// host_sim_send enqueues a message onto link_id after enforcing sender grants,
// link grants, payload bounds, and ring capacity.
host_sim_send :: proc(sim: ^Host_Sim, link_id: int, kind: u32, tag: u64, required_grants: Host_Sim_Grants, payload: []u8 = nil) -> (status: Host_Sim_Status, refusal: Host_Sim_Refusal) {
	if link_id < 0 || link_id >= sim.link_count || !sim.links[link_id].active {
		return .Refused_Unknown_Service, .Invalid_Link_Id
	}
	if len(payload) > HOST_SIM_PAYLOAD_BYTES {
		return .Refused_Bad_Message, .Payload_Too_Large
	}
	link := &sim.links[link_id]
	sender := &sim.services[link.from_id]
	receiver := &sim.services[link.to_id]
	if !sender.active || !receiver.active {
		sim.refused_messages += 1
		return .Refused_Stopped, .None
	}
	if (required_grants & link.grants) != required_grants || (required_grants & sender.grants) != required_grants {
		sim.refused_messages += 1
		return .Refused_No_Grant, .None
	}
	if link.count >= HOST_SIM_RING_CAPACITY {
		sim.refused_messages += 1
		return .Refused_Full, .Ring_Full
	}
	tail := (link.head + link.count) % HOST_SIM_RING_CAPACITY
	msg := Host_Sim_Message {
		tag         = tag,
		kind        = kind,
		status      = .Ok,
		sender_id   = link.from_id,
		sent_at_ns  = sim.now_ns,
		payload_len = u16(len(payload)),
	}
	if len(payload) > 0 {
		copy(msg.payload[:], payload)
	}
	link.slots[tail] = msg
	link.count += 1
	return .Ok, .None
}

// host_sim_step_once picks the next ready service in deterministic round-robin
// order, advances the virtual clock by one tick, and dispatches one queued
// message to that service's handler.
host_sim_step_once :: proc(sim: ^Host_Sim) -> (dispatched: bool) {
	if sim.service_count == 0 {
		return false
	}
	for offset in 0 ..< sim.service_count {
		service_id := (sim.next_service_cursor + offset) % sim.service_count
		svc := &sim.services[service_id]
		if !svc.active {
			continue
		}
		for link_idx in 0 ..< sim.link_count {
			link := &sim.links[link_idx]
			if !link.active || link.to_id != service_id || link.count == 0 {
				continue
			}
			msg := link.slots[link.head]
			link.head = (link.head + 1) % HOST_SIM_RING_CAPACITY
			link.count -= 1

			sim.now_ns += sim.tick_step_ns
			sim.total_steps += 1
			svc.steps_run += 1
			svc.handled_messages += 1
			sim.next_service_cursor = (service_id + 1) % sim.service_count

			outcome := svc.handler(sim, service_id, msg)
			if outcome == .Ok {
				sim.delivered_messages += 1
			} else {
				sim.refused_messages += 1
			}
			return true
		}
	}
	return false
}

// host_sim_run_until_idle steps the simulation deterministically until every
// ring is empty or max_steps is reached.
host_sim_run_until_idle :: proc(sim: ^Host_Sim, max_steps: int) -> (steps: int, refusal: Host_Sim_Refusal) {
	if max_steps <= 0 {
		return 0, .Step_Limit_Reached
	}
	for steps < max_steps {
		if !host_sim_step_once(sim) {
			return steps, .None
		}
		steps += 1
	}
	// If work remains after max_steps, report non-termination cleanly.
	for link_idx in 0 ..< sim.link_count {
		if sim.links[link_idx].active && sim.links[link_idx].count > 0 {
			return steps, .Step_Limit_Reached
		}
	}
	return steps, .None
}
