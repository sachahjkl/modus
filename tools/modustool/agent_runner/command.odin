package agent_runner

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "modustool:agent_bridge"
import "modustool:foundation"
import "modustool:machine"
import contract "modus:contract/agent_bridge"
import "modus:contract/remote"

// The time between two questions to the window when no request waits: a
// person who types a request waits less than a second for its reply.
IDLE_PAUSE :: 500 * time.Millisecond

USAGE :: "modustool: assistant --remote-key <64-hex> --client-key <64-hex> [--socket <path>] [--principal <id>] [--key-variable <NAME>] [--fake <script>] [--once] [--key-in-clear-off-host]"

// run_assistant is the command `modustool assistant`: the agent runner. It
// answers the requests of the window of the assistant through remote, one
// at a time, until it stops; with --once, it answers one request, or none
// when none waits. The model is the endpoint of MODUS_ASSISTANT_ENDPOINT
// with the key of MODUS_ASSISTANT_KEY (or of --key-variable), or the script
// of --fake, which reads no variable. The key is never printed. The
// endpoint is this machine, unless --key-in-clear-off-host accepts that
// plain HTTP carries the key in clear on the network.
run_assistant :: proc(args: []string) -> int {
	remote_key_text, client_key_text, socket_override, fake_path := "", "", "", ""
	key_variable := KEY_VARIABLE
	principal_id: u64
	once, off_host_allowed := false, false
	for index := 0; index < len(args); index += 1 {
		value_needed := args[index] != "--once" && args[index] != OFF_HOST_OPTION
		if value_needed && index + 1 >= len(args) {
			fmt.eprintln(USAGE)
			return foundation.EXIT_USAGE
		}
		switch args[index] {
		case "--remote-key":
			index += 1
			remote_key_text = args[index]
		case "--client-key":
			index += 1
			client_key_text = args[index]
		case "--socket":
			index += 1
			socket_override = args[index]
		case "--principal":
			index += 1
			parsed, parsed_ok := strconv.parse_u64(args[index])
			if !parsed_ok {
				fmt.eprintln("modustool: assistant: --principal must be a number")
				return foundation.EXIT_USAGE
			}
			principal_id = parsed
		case "--key-variable":
			index += 1
			key_variable = args[index]
		case "--fake":
			index += 1
			fake_path = args[index]
		case "--once":
			once = true
		case OFF_HOST_OPTION:
			off_host_allowed = true
		case:
			fmt.eprintfln("modustool: assistant: unknown option %s", args[index])
			fmt.eprintln(USAGE)
			return foundation.EXIT_USAGE
		}
	}
	remote_key, remote_key_ok := agent_bridge.parse_hex_32(remote_key_text)
	client_key, client_key_ok := agent_bridge.parse_hex_32(client_key_text)
	if !remote_key_ok || !client_key_ok {
		fmt.eprintln(USAGE)
		return foundation.EXIT_USAGE
	}
	model: Model
	fake: Fake_Model
	endpoint_model: Http_Model
	if fake_path != "" {
		script, read_error := os.read_entire_file(fake_path, context.allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: assistant: cannot read the script %s", fake_path)
			return foundation.EXIT_FAILURE
		}
		fake.replies = fake_script_read(string(script))
		model = fake_model(&fake)
	} else {
		url := os.get_env(ENDPOINT_VARIABLE, context.allocator)
		endpoint, problem := endpoint_parse(url, off_host_allowed)
		if problem != "" {
			fmt.eprintfln("modustool: assistant: %s: %s", ENDPOINT_VARIABLE, problem)
			return foundation.EXIT_USAGE
		}
		key := os.get_env(key_variable, context.allocator)
		if key == "" {
			fmt.eprintfln("modustool: assistant: the variable %s holds no key", key_variable)
			return foundation.EXIT_USAGE
		}
		if key_problem := key_check(key); key_problem != "" {
			fmt.eprintfln("modustool: assistant: the variable %s: %s", key_variable, key_problem)
			return foundation.EXIT_USAGE
		}
		name := os.get_env(MODEL_NAME_VARIABLE, context.allocator)
		endpoint_model = {endpoint = endpoint, key = key, model_name = name != "" ? name : "default"}
		model = http_model(&endpoint_model)
	}
	socket_path := socket_override
	if socket_path == "" {
		resolved, problem := machine.call_socket_path(machine.CALL_SOCKET_RUN_NAME)
		if problem != "" {
			fmt.eprintfln("modustool: assistant: %s", problem)
			return foundation.EXIT_FAILURE
		}
		socket_path = resolved
	}
	client: machine.Call_Client
	machine.call_client_open(&client, socket_path, remote_key)
	defer machine.call_client_close(&client)
	transport: agent_bridge.Remote_Machine_Transport
	if !agent_bridge.remote_transport_open(&transport, socket_path, remote_key) {
		fmt.eprintln("modustool: assistant: cannot open the transport of the bridge")
		return foundation.EXIT_FAILURE
	}
	defer agent_bridge.remote_transport_close(&transport)
	bridge: agent_bridge.Agent_Bridge
	if !agent_bridge.bridge_init(&bridge, runner_policy(client_key, principal_id), agent_bridge.remote_transport_interface(&transport)) {
		fmt.eprintln("modustool: assistant: cannot start the bridge")
		return foundation.EXIT_FAILURE
	}
	defer agent_bridge.bridge_destroy(&bridge)
	runner := Runner{client = &client, bridge = &bridge, model = model}
	defer conversation_close(&runner)
	for {
		report := runner_turn(&runner)
		report_print(report)
		free_all(context.temp_allocator)
		switch report.outcome {
		case .Window_Failed:
			return foundation.EXIT_FAILURE
		case .No_Request:
			if once {
				return 0
			}
			time.sleep(IDLE_PAUSE)
		case .Answered, .Reply_Refused, .Model_Failed:
			if once {
				return 0
			}
		}
	}
}

// runner_policy is the policy of the bridge for the runner: the act of a
// model is a line of Lex, through the uses Calls of the client key.
runner_policy :: proc(client_key: [32]u8, principal_id: u64) -> contract.Bridge_Client_Policy {
	return {
		client_key_public   = client_key,
		principal_id        = principal_id,
		permissions_word    = contract.bridge_permissions_to_word({.Eval_Lex}),
		remote_uses_word    = remote.client_uses_word({.Calls}),
		collector_available = true,
	}
}

// report_print writes one line for a turn. It names no secret: a problem
// of the model names its variable, never its value.
report_print :: proc(report: Turn_Report) {
	if report.outcome == .No_Request {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	report_write(&builder, report)
	rest := strings.to_string(builder)
	for line in strings.split_lines_iterator(&rest) {
		if report.outcome == .Window_Failed {
			fmt.eprintfln("modustool: assistant: %s", line)
		} else {
			fmt.printfln("modustool: assistant: %s", line)
		}
	}
}
