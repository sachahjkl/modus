// Host unit tests for the deterministic multi-service host simulator
// (host_sim.odin).
package machine

import "core:testing"

@(private = "file")
Sim_Flow_Trace :: struct {
	client_to_recipes:  int,
	recipes_to_storage: int,
	storage_to_recipes: int,
	recipes_to_client:  int,
	replies:            [8]u64,
	reply_count:        int,
}

@(private = "file")
sim_noop_handler :: proc(sim: ^Host_Sim, self_id: int, msg: Host_Sim_Message) -> Host_Sim_Status {
	_ = sim
	_ = self_id
	_ = msg
	return .Ok
}

@(private = "file")
sim_client_handler :: proc(sim: ^Host_Sim, self_id: int, msg: Host_Sim_Message) -> Host_Sim_Status {
	trace := (^Sim_Flow_Trace)(sim.services[self_id].user_data)
	if trace.reply_count < len(trace.replies) {
		trace.replies[trace.reply_count] = msg.tag
		trace.reply_count += 1
	}
	return .Ok
}

@(private = "file")
sim_recipes_handler :: proc(sim: ^Host_Sim, self_id: int, msg: Host_Sim_Message) -> Host_Sim_Status {
	msg := msg
	trace := (^Sim_Flow_Trace)(sim.services[self_id].user_data)
	switch msg.kind {
	case 1: // Build request from client -> forward read to storage.
		status, _ := host_sim_send(sim, trace.recipes_to_storage, 2, msg.tag, {.Read_Store}, msg.payload[:msg.payload_len])
		return status
	case 3: // Storage response -> reply to client.
		status, _ := host_sim_send(sim, trace.recipes_to_client, 4, msg.tag, {}, msg.payload[:msg.payload_len])
		return status
	}
	return .Refused_Bad_Message
}

@(private = "file")
sim_storage_handler :: proc(sim: ^Host_Sim, self_id: int, msg: Host_Sim_Message) -> Host_Sim_Status {
	msg := msg
	trace := (^Sim_Flow_Trace)(sim.services[self_id].user_data)
	status, _ := host_sim_send(sim, trace.storage_to_recipes, 3, msg.tag, {}, msg.payload[:msg.payload_len])
	return status
}

@(private = "file")
sim_ping_handler :: proc(sim: ^Host_Sim, self_id: int, msg: Host_Sim_Message) -> Host_Sim_Status {
	link_id := (^int)(sim.services[self_id].user_data)^
	status, _ := host_sim_send(sim, link_id, msg.kind, msg.tag + 1, {})
	return status
}

@(test)
host_sim_refuses_invalid_setup_grants_overflow_and_loops :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sim := new(Host_Sim, context.temp_allocator)
	host_sim_init(sim)

	// Registration refusals.
	_, ref := host_sim_register_service(sim, "", {}, sim_noop_handler)
	testing.expect_value(t, ref, Host_Sim_Refusal.Empty_Service_Name)
	_, ref = host_sim_register_service(sim, "alpha", {}, nil)
	testing.expect_value(t, ref, Host_Sim_Refusal.Nil_Handler)

	a, ref_a := host_sim_register_service(sim, "alpha", {.Read_Store}, sim_noop_handler)
	testing.expect_value(t, ref_a, Host_Sim_Refusal.None)
	_, dup_ref := host_sim_register_service(sim, "alpha", {}, sim_noop_handler)
	testing.expect_value(t, dup_ref, Host_Sim_Refusal.Duplicate_Service_Name)

	b, ref_b := host_sim_register_service(sim, "beta", {}, sim_noop_handler)
	testing.expect_value(t, ref_b, Host_Sim_Refusal.None)

	// Link refusals.
	_, self_ref := host_sim_connect(sim, a, a, {.Read_Store})
	testing.expect_value(t, self_ref, Host_Sim_Refusal.Self_Link_Refused)
	_, bad_svc_ref := host_sim_connect(sim, a, 99, {})
	testing.expect_value(t, bad_svc_ref, Host_Sim_Refusal.Invalid_Service_Id)

	link_ab, link_ref := host_sim_connect(sim, a, b, {.Read_Store})
	testing.expect_value(t, link_ref, Host_Sim_Refusal.None)

	// Missing grant is refused without enqueuing.
	st, send_ref := host_sim_send(sim, link_ab, 1, 7, {.Write_Store})
	testing.expect_value(t, st, Host_Sim_Status.Refused_No_Grant)
	testing.expect_value(t, send_ref, Host_Sim_Refusal.None)
	testing.expect_value(t, sim.links[link_ab].count, 0)

	// Payload past bound and invalid link are refused.
	too_big: [HOST_SIM_PAYLOAD_BYTES + 1]u8
	_, big_ref := host_sim_send(sim, link_ab, 1, 8, {}, too_big[:])
	testing.expect_value(t, big_ref, Host_Sim_Refusal.Payload_Too_Large)
	_, bad_link_ref := host_sim_send(sim, 99, 1, 8, {})
	testing.expect_value(t, bad_link_ref, Host_Sim_Refusal.Invalid_Link_Id)

	// Fill ring to capacity and verify deterministic ring-full refusal.
	for i in 0 ..< HOST_SIM_RING_CAPACITY {
		fill_st, fill_ref := host_sim_send(sim, link_ab, 1, u64(i), {.Read_Store})
		testing.expect_value(t, fill_st, Host_Sim_Status.Ok)
		testing.expect_value(t, fill_ref, Host_Sim_Refusal.None)
	}
	full_st, full_ref := host_sim_send(sim, link_ab, 1, 999, {.Read_Store})
	testing.expect_value(t, full_st, Host_Sim_Status.Refused_Full)
	testing.expect_value(t, full_ref, Host_Sim_Refusal.Ring_Full)

	// Non-terminating ping-pong loop stops cleanly at Step_Limit_Reached.
	loop_sim := new(Host_Sim, context.temp_allocator)
	host_sim_init(loop_sim)
	link_01, link_10: int
	p0, _ := host_sim_register_service(loop_sim, "p0", {}, sim_ping_handler, &link_01)
	p1, _ := host_sim_register_service(loop_sim, "p1", {}, sim_ping_handler, &link_10)
	link_01, _ = host_sim_connect(loop_sim, p0, p1, {})
	link_10, _ = host_sim_connect(loop_sim, p1, p0, {})
	_, _ = host_sim_send(loop_sim, link_01, 1, 1, {})
	ran_steps, loop_ref := host_sim_run_until_idle(loop_sim, 10)
	testing.expect_value(t, ran_steps, 10)
	testing.expect_value(t, loop_ref, Host_Sim_Refusal.Step_Limit_Reached)
}

@(test)
host_sim_multi_service_flow_is_deterministic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	run_once :: proc() -> (sim: ^Host_Sim, trace: Sim_Flow_Trace, steps: int, refusal: Host_Sim_Refusal) {
		sim = new(Host_Sim, context.temp_allocator)
		host_sim_init(sim, 500_000)
		client_id, _ := host_sim_register_service(sim, "console", {.Read_Store}, sim_client_handler, &trace)
		recipes_id, _ := host_sim_register_service(sim, "recipes", {.Read_Store}, sim_recipes_handler, &trace)
		storage_id, _ := host_sim_register_service(sim, "storage", {.Read_Store}, sim_storage_handler, &trace)

		trace.client_to_recipes, _ = host_sim_connect(sim, client_id, recipes_id, {.Read_Store})
		trace.recipes_to_storage, _ = host_sim_connect(sim, recipes_id, storage_id, {.Read_Store})
		trace.storage_to_recipes, _ = host_sim_connect(sim, storage_id, recipes_id, {})
		trace.recipes_to_client, _ = host_sim_connect(sim, recipes_id, client_id, {})

		payload := transmute([]u8)string("collatz")
		_, _ = host_sim_send(sim, trace.client_to_recipes, 1, 101, {.Read_Store}, payload)
		_, _ = host_sim_send(sim, trace.client_to_recipes, 1, 202, {.Read_Store}, payload)
		steps, refusal = host_sim_run_until_idle(sim, 64)
		return
	}

	sim1, trace1, steps1, ref1 := run_once()
	sim2, trace2, steps2, ref2 := run_once()

	testing.expect_value(t, ref1, Host_Sim_Refusal.None)
	testing.expect_value(t, ref2, Host_Sim_Refusal.None)
	testing.expect_value(t, steps1, 8)
	testing.expect_value(t, steps1, steps2)
	testing.expect_value(t, sim1.now_ns, sim2.now_ns)
	testing.expect_value(t, sim1.delivered_messages, u64(8))
	testing.expect_value(t, sim1.delivered_messages, sim2.delivered_messages)
	testing.expect_value(t, trace1.reply_count, 2)
	testing.expect_value(t, trace1.replies[0], u64(101))
	testing.expect_value(t, trace1.replies[1], u64(202))
	testing.expect_value(t, trace1.replies, trace2.replies)
}
