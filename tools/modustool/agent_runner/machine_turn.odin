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
	replies := fake_script_read(reply, context.temp_allocator)
	fake := Fake_Model{replies = replies}
	runner := Runner{client = client, window = remote_window_port(client), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)
	report := runner_turn(&runner)
	builder := strings.builder_make(context.temp_allocator)
	report_write(&builder, report)
	return strings.to_string(builder), report.end != .Window_Failed && report.end != .Grant_Ended
}

// report_write writes the lines of a turn, as report_print prints them.
report_write :: proc(builder: ^strings.Builder, turn: Turn_Report) {
	report := turn
	if !report.has_request {
		if report.end == .Window_Failed || report.end == .Grant_Ended {
			fmt.sbprintf(builder, "%s\n", report.problem)
			return
		}
		strings.write_string(builder, "no request waits\n")
		return
	}
	switch report.end {
	case .Final_Reply:
		fmt.sbprintf(builder, "request %d answered, %d steps, %d acts\n", report.serial, report.step_count, report.total_acts)
	case .Step_Limit:
		fmt.sbprintf(builder, "request %d stopped: step limit, %d steps, %d acts\n", report.serial, report.step_count, report.total_acts)
	case .Repeated_Step:
		fmt.sbprintf(builder, "request %d stopped: repeated step, %d steps, %d acts\n", report.serial, report.step_count, report.total_acts)
	case .Stopped_By_Principal:
		fmt.sbprintf(builder, "request %d stopped by the principal, %d steps, %d acts\n", report.serial, report.step_count, report.total_acts)
	case .Model_Failed:
		if report.reply_refused {
			fmt.sbprintf(builder, "the reply to request %d was refused at the border: kind %d, unit %d, argument %d, value %d, limit %d, found %d\n", report.serial, report.record.kind, report.record.unit, report.record.argument, report.record.value, report.record.limit, report.record.found)
		} else {
			fmt.sbprintf(builder, "the model gave no reply to request %d: %s\n", report.serial, report.problem)
		}
	case .Window_Failed:
		fmt.sbprintf(builder, "%s\n", report.problem)
	case .Grant_Ended:
		fmt.sbprintf(builder, "request %d stopped: grant ended: %s\n", report.serial, report.problem)
	}
	for &step in report.steps[:report.step_count] {
		for act in step.acts[:step.act_count] {
			fmt.sbprintf(builder, "act %d: %v: %s\n", act.number, act.state, act.text)
			if act.table_problem != "" {
				fmt.sbprintf(builder, "act %d: the window refused its table, and shows its words: %s\n", act.number, act.table_problem)
			}
		}
	}
}
