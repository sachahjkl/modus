package agent_runner

import "core:fmt"
import "core:strings"
import "modustool:agent_bridge"
import "modustool:machine"

// The step Assistant_Turn of the machine test runs one turn of the runner
// with a fake model of one reply, through the remote service of the machine
// (tools/modustool/machine/assistant_turn.odin).
@(init)
assistant_turn_register :: proc "contextless" () {
	machine.assistant_turn_run = machine_turn_run
}

// The key that the policy of the bridge names in a test. The bridge refuses
// a policy with no key; the key that remote checks is the key of the client
// of the peer, which the scenario allowed with remote_allow.
@(private = "file")
TEST_POLICY_KEY :: [32]u8{0 = 0x5A, 31 = 0xA5}

@(private = "file")
machine_turn_run :: proc(client: ^machine.Call_Client, socket: string, reply: string) -> (printed: string, ran: bool) {
	transport: agent_bridge.Remote_Machine_Transport
	if !agent_bridge.remote_transport_open(&transport, socket, {}) {
		return "the transport of the bridge does not open", false
	}
	defer agent_bridge.remote_transport_close(&transport)
	bridge: agent_bridge.Agent_Bridge
	if !agent_bridge.bridge_init(&bridge, runner_policy(TEST_POLICY_KEY, 0), agent_bridge.remote_transport_interface(&transport)) {
		return "the bridge does not start", false
	}
	defer agent_bridge.bridge_destroy(&bridge)
	replies := [1]string{reply}
	fake := Fake_Model{replies = replies[:]}
	runner := Runner{client = client, bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)
	report := runner_turn(&runner)
	builder := strings.builder_make(context.temp_allocator)
	report_write(&builder, report)
	return strings.to_string(builder), report.outcome != .Window_Failed
}

// report_write writes the lines of a turn, as report_print prints them.
report_write :: proc(builder: ^strings.Builder, turn: Turn_Report) {
	report := turn
	switch report.outcome {
	case .No_Request:
		strings.write_string(builder, "no request waits\n")
	case .Answered:
		fmt.sbprintf(builder, "request %d answered, %d acts\n", report.serial, report.act_count)
		for act in report.acts[:report.act_count] {
			fmt.sbprintf(builder, "act %d: %v: %s\n", act.number, act.state, act.text)
		}
	case .Reply_Refused:
		fmt.sbprintf(builder, "the reply to request %d was refused at the border: kind %d, unit %d, argument %d, value %d, limit %d, found %d\n", report.serial, report.record.kind, report.record.unit, report.record.argument, report.record.value, report.record.limit, report.record.found)
	case .Model_Failed:
		fmt.sbprintf(builder, "the model gave no reply to request %d: %s\n", report.serial, report.problem)
	case .Window_Failed:
		fmt.sbprintf(builder, "%s\n", report.problem)
	}
}
