package machine

import "modustool:build"
import "modustool:foundation"

// The machine of the assistant (src/md/features/assistant.md): the window,
// the agent runner of the tool with a fake model of one reply in each step
// Assistant_Turn, and the act dialog of the trusted display.
//
// - A request, then a reply with one act on the read-only list of the
//   bridge: the reply shows, and the act is done with the rows of Process.
// - A reply with a grant-adding act, plans.apply: the bridge stops it, the
//   window shows the act dialog of the trusted display, Enter on its first
//   focus refuses it, and nothing runs: the remote service never connects
//   to plans, and the act keeps the state refused by the principal.
// - A malformed reply: the border of the runner refuses it whole, and the
//   window shows the words of its error record; no act of it runs.
scenario_assistant := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	// The key of the client of the peer, for the calls of the runner.
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Launch, text = "assistant"},
	{kind = .Wait, text = "assistant: ok"},
	// No request waits: the runner asks, and answers none.
	{kind = .Assistant_Turn, text = `{"text": "unused"}`, expected = "no request waits"},
	// A request and a read-only act.
	{kind = .Type, text = "which processes run"},
	{kind = .Wait, text = "assistant: request 1 is kept: which processes run"},
	{kind = .Assistant_Turn, text = `{"text": "Reading the processes.", "acts": [{"kind": "eval_lex", "line": "monitor.processes()"}]}` + "\n" + `{"text": "Here are the processes that run."}`, expected = "request 1 answered, 2 steps, 1 acts"},
	{kind = .Wait, text = "assistant: request 1 is taken"},
	{kind = .Wait, text = "assistant: the reply to request 1 shows, 22 bytes: Reading the processes."},
	{kind = .Wait, text = "assistant: act 1 of request 1 is proposed: monitor.processes()"},
	{kind = .Wait, text = "assistant: act 1 is done: "},
	{kind = .Wait, text = " rows of Process: "},
	// The typed result: the rows of the table of the processes, which the
	// window draws as the console does.
	{kind = .Wait, text = "assistant: act 1 shows "},
	// A grant-adding act: the bridge stops it for the principal, and the
	// principal refuses it on the trusted display with Enter, which acts on
	// Refuse, the first focus of the dialog. The act of the last request
	// started monitor, whose window came to the front.
	{kind = .Front, text = "assistant"},
	{kind = .Shot, text = "assistant_reply"},
	{kind = .Type, text = "apply my plan home"},
	{kind = .Wait, text = "assistant: request 2 is kept: apply my plan home"},
	{kind = .Assistant_Turn, text = `{"text": "Checking plan home.", "acts": [{"kind": "eval_lex", "line": "plans.apply(\"home\")"}]}` + "\n" + `{"text": "Your plan home needs your decision."}`, expected = "act 2: Awaiting_Principal"},
	{kind = .Wait, text = "assistant: act 2 is waiting for the principal: the bridge stopped it for the principal: Principal_Approval_Required"},
	{kind = .Wait, text = "compositor: the act plans.apply of assistant shows", any_order = true},
	{kind = .Wait, text = "assistant: act 2 waits for the principal in the act dialog "},
	{kind = .Shot, text = "assistant_act_dialog"},
	{kind = .Key_Again_Until, text = "ret", expected = "compositor: the act plans.apply of assistant is refused", fails_on = "is allowed"},
	{kind = .Wait, text = "assistant: act 2 is refused by the principal; nothing ran", fails_on = "connected remote to the service plans"},
	{kind = .Call, text = "assistant.act_state(2)", expected = "6"},
	// A malformed reply: an act kind that names no member. The border
	// refuses the reply whole: argument 3 is the kind, found 1 the act.
	{kind = .Front, text = "assistant"},
	{kind = .Type, text = "and now"},
	{kind = .Wait, text = "assistant: request 3 is kept: and now"},
	{kind = .Assistant_Turn, text = `{"text": "I approve it for you.", "acts": [{"kind": "approve", "line": "plans.apply(\"home\")"}]}`, expected = "the reply to request 3 was refused at the border: kind 4, unit 1, argument 3"},
	{kind = .Wait, text = "assistant: the reply to request 3 was refused at the border: Bad_Value, unit bytes, argument 3", fails_on = "assistant: act 3"},
	{kind = .Shot, text = "assistant_refused"},
	// The runner never writes a decision of the principal: the window
	// refuses the state at its border, and the act keeps its state.
	{kind = .Call, text = "assistant.act_result(2, 5, \"allowed\")", outcome = .Failed, expected = "the argument state has the value 5, which the call refuses"},
	{kind = .Call, text = "assistant.act_state(2)", expected = "6"},
	{kind = .Quit},
}

assistant_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_assistant[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_ASSISTANT, exit_status = QEMU_QUIT_STATUS})
}

TEST_OUTPUT_ASSISTANT :: foundation.BUILD_FOLDER + "/test_output_assistant.txt"

@(init)
assistant_test_part_register :: proc "contextless" () {
	test_part_scenario_register("assistant", assistant_tests_run)
}
