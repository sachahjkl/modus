package system

import "modus:contract/ring"
import "modus:contract/root_ring"

// ready says to the root service that this process reached its first state
// of work: its start is done, and it waits for its work. The root service
// then reads the peak of the budget of the process, and checks it against
// the floor of its start (src/md/features/module_budget_request.md, "The
// peak of a budget"). A Ready that the root service takes has no
// completion, so the caller waits for nothing; a second one changes
// nothing. requests is the root ring of the process. sent is false when the
// ring holds no room: the check then does not happen, and the process runs
// on.
ready :: proc "contextless" (requests: ^ring.Ring) -> (sent: bool) {
	return send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Ready)})
}
