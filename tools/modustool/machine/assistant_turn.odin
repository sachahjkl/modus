package machine

import "core:time"

// The turn of the agent runner of the assistant that the step
// Assistant_Turn runs: the runner lives in tools/modustool/agent_runner,
// which imports this package, so it sets this procedure when the tool
// starts. reply is the one reply of the fake model of the turn; printed is
// what the runner writes for the turn. nil in a binary with no runner.
Assistant_Turn_Run :: proc(client: ^Call_Client, socket: string, reply: string) -> (printed: string, ran: bool)

assistant_turn_run: Assistant_Turn_Run

// The time between two presses of the step Key_Again_Until: a press each
// tenth of a second gives a dialog a few presses after its arm time, and
// is not a stream of keys.
KEY_AGAIN_PERIOD :: 100 * time.Millisecond
