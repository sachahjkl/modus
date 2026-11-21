// BEAM-style supervision tree, restart groups, optional sliding restart window,
// and bounded escalation for the root service and start policies
// (src/md/features/supervision.md, src/md/features/start_policy.md).
//
// Pure freestanding state machine: monotonic clock timestamps are passed as
// arguments, window_milliseconds == 0 counts over whole uptime without ever
// reading a clock, and every refusal leaves the tree unchanged.
package start_policy_rules

import op "modus:contract/operation"
import "modus:contract/start_list"
import "modus:contract/supervision"

// Maximum supervised children tracked in one supervision tree.
SUPERVISION_NODE_CAPACITY :: start_list.ROW_CAPACITY

// Maximum explicit provider dependencies declared by one supervised child.
SUPERVISION_DEPENDENCY_CAPACITY :: 8

// Ring capacity for recent restart timestamps when window_milliseconds > 0.
RESTART_WINDOW_RING_CAPACITY :: start_list.RESTART_LIMIT

// Restart history for one supervised child.
// When window_milliseconds == 0, only total_restarts is consulted or updated;
// no clock value is read or stored.
Restart_Window_State :: struct {
	total_restarts:              u64,
	timestamps:                  [RESTART_WINDOW_RING_CAPACITY]u64,
	ring_head:                   u32,
	ring_count:                  u32,
	last_timestamp_milliseconds: u64,
	has_last_timestamp:          bool,
}

// Configuration passed when registering a child in a supervision tree.
Supervised_Child_Config :: struct {
	child_id:            u32, // Non-zero unique identifier of the child.
	parent_id:           u32, // 0 for a direct child of the root starter, else an active child_id.
	child_strategy:      supervision.Restart_Strategy, // Strategy applied if this node supervises its own children.
	needed:              bool, // When true, exhausting restarts escalates to parent or root; when false, stops permanently.
	max_restarts:        u32, // 0 ..= start_list.RESTART_LIMIT.
	window_milliseconds: u64, // 0: whole-uptime bound (no clock); > 0: sliding window in milliseconds.
}

// One active node in a Supervision_Tree.
Supervised_Child :: struct {
	active:              bool,
	child_id:            u32,
	parent_id:           u32,
	start_order:         u32,
	child_strategy:      supervision.Restart_Strategy,
	needed:              bool,
	max_restarts:        u32,
	window_milliseconds: u64,
	dependency_ids:      [SUPERVISION_DEPENDENCY_CAPACITY]u32,
	dependency_count:    u8,
	permanently_stopped: bool,
	history:             Restart_Window_State,
}

// Fixed-capacity supervision tree. Initialize with supervision_tree_init.
Supervision_Tree :: struct {
	initialized:      bool,
	root_strategy:    supervision.Restart_Strategy,
	next_start_order: u32,
	nodes:            [SUPERVISION_NODE_CAPACITY]Supervised_Child,
}

// Why an operation on a Supervision_Tree was refused. Any refusal leaves the
// tree completely unchanged.
Supervision_Refusal :: enum u8 {
	None                      = 0,
	Null_Tree                 = 1,
	Tree_Not_Initialized      = 2,
	Invalid_Strategy          = 3,
	Zero_Child_Id             = 4,
	Duplicate_Child           = 5,
	Unknown_Parent            = 6,
	Unknown_Child             = 7,
	Unknown_Dependency        = 8,
	Duplicate_Dependency      = 9,
	Dependency_Cycle          = 10,
	Too_Many_Dependencies     = 11,
	Tree_Full                 = 12,
	Restart_Limit_Exceeded    = 13,
	Invalid_Stop_Words        = 14,
	Clock_Moved_Backwards     = 15,
	Child_Permanently_Stopped = 16,
}

// Result of handling a child stop event in a Supervision_Tree.
Supervision_Stop_Decision :: struct {
	refusal:            Supervision_Refusal,
	action:             supervision.Escalation_Action,
	escalated_to_id:    u32, // Parent node ID that absorbed the escalation, or 0 when escalated to the root starter.
	stop_order:         [SUPERVISION_NODE_CAPACITY]u32, // Active children to stop, dependents first.
	stop_count:         int,
	restart_order:      [SUPERVISION_NODE_CAPACITY]u32, // Children to start again, providers first.
	restart_count:      int,
	restarts_in_window: u64, // Active restart count for the stopped child (or lifetime count when window == 0).
}

@(private = "file")
tree_find_node :: proc "contextless" (tree: ^Supervision_Tree, child_id: u32) -> (index: int, found: bool) {
	if child_id == 0 {
		return -1, false
	}
	for &node, idx in tree.nodes {
		if node.active && node.child_id == child_id {
			return idx, true
		}
	}
	return -1, false
}

@(private = "file")
tree_find_free_slot :: proc "contextless" (tree: ^Supervision_Tree) -> (index: int, found: bool) {
	for &node, idx in tree.nodes {
		if !node.active {
			return idx, true
		}
	}
	return -1, false
}

// node_depends_directly_on reports whether node depends directly on target_id
// through either its parent link or its declared dependency_ids.
@(private = "file")
node_depends_directly_on :: proc "contextless" (node: ^Supervised_Child, target_id: u32) -> bool {
	if node.parent_id != 0 && node.parent_id == target_id {
		return true
	}
	for idx in 0 ..< int(node.dependency_count) {
		if node.dependency_ids[idx] == target_id {
			return true
		}
	}
	return false
}

// node_reaches_target reports whether target_id is reachable from start_id by
// following directed dependency edges (parent_id and dependency_ids). Uses a
// bounded stack walk over SUPERVISION_NODE_CAPACITY nodes.
@(private = "file")
node_reaches_target :: proc "contextless" (tree: ^Supervision_Tree, start_id: u32, target_id: u32) -> bool {
	if start_id == 0 || target_id == 0 {
		return false
	}
	if start_id == target_id {
		return true
	}
	visited: [SUPERVISION_NODE_CAPACITY]bool
	stack: [SUPERVISION_NODE_CAPACITY]int
	stack_len := 0

	start_idx, start_ok := tree_find_node(tree, start_id)
	if !start_ok {
		return false
	}
	visited[start_idx] = true
	stack[stack_len] = start_idx
	stack_len += 1

	for stack_len > 0 {
		stack_len -= 1
		cur_idx := stack[stack_len]
		cur := &tree.nodes[cur_idx]

		// Follow parent edge.
		if cur.parent_id != 0 {
			if cur.parent_id == target_id {
				return true
			}
			if p_idx, p_ok := tree_find_node(tree, cur.parent_id); p_ok && !visited[p_idx] {
				visited[p_idx] = true
				stack[stack_len] = p_idx
				stack_len += 1
			}
		}
		// Follow explicit dependency edges.
		for dep_pos in 0 ..< int(cur.dependency_count) {
			dep_id := cur.dependency_ids[dep_pos]
			if dep_id == target_id {
				return true
			}
			if d_idx, d_ok := tree_find_node(tree, dep_id); d_ok && !visited[d_idx] {
				visited[d_idx] = true
				stack[stack_len] = d_idx
				stack_len += 1
			}
		}
	}
	return false
}

// supervision_tree_init initializes an empty supervision tree with the given
// root-level restart strategy. Refuses nil tree or an invalid strategy.
supervision_tree_init :: proc "contextless" (tree: ^Supervision_Tree, root_strategy: supervision.Restart_Strategy) -> Supervision_Refusal {
	if tree == nil {
		return .Null_Tree
	}
	valid_strategy, ok := supervision.restart_strategy_from_word(u64(root_strategy))
	if !ok {
		return .Invalid_Strategy
	}
	tree^ = {
		initialized   = true,
		root_strategy = valid_strategy,
	}
	return .None
}

// supervision_tree_add_child registers a supervised child in start order.
// Refuses invalid configs, unknown parents, duplicate IDs, restart limits
// above start_list.RESTART_LIMIT, or a full tree, leaving tree unchanged.
supervision_tree_add_child :: proc "contextless" (tree: ^Supervision_Tree, config: Supervised_Child_Config) -> Supervision_Refusal {
	if tree == nil {
		return .Null_Tree
	}
	if !tree.initialized {
		return .Tree_Not_Initialized
	}
	if config.child_id == 0 {
		return .Zero_Child_Id
	}
	valid_strategy, strategy_ok := supervision.restart_strategy_from_word(u64(config.child_strategy))
	if !strategy_ok {
		return .Invalid_Strategy
	}
	if config.max_restarts > start_list.RESTART_LIMIT {
		return .Restart_Limit_Exceeded
	}
	if config.parent_id == config.child_id {
		return .Dependency_Cycle
	}
	if _, exists := tree_find_node(tree, config.child_id); exists {
		return .Duplicate_Child
	}
	if config.parent_id != 0 {
		parent_idx, parent_ok := tree_find_node(tree, config.parent_id)
		if !parent_ok {
			return .Unknown_Parent
		}
		if tree.nodes[parent_idx].permanently_stopped {
			return .Child_Permanently_Stopped
		}
	}
	free_slot, has_room := tree_find_free_slot(tree)
	if !has_room {
		return .Tree_Full
	}

	tree.nodes[free_slot] = {
		active              = true,
		child_id            = config.child_id,
		parent_id           = config.parent_id,
		start_order         = tree.next_start_order,
		child_strategy      = valid_strategy,
		needed              = config.needed,
		max_restarts        = config.max_restarts,
		window_milliseconds = config.window_milliseconds,
	}
	tree.next_start_order += 1
	return .None
}

// supervision_tree_add_dependency declares that dependent_id requires
// provider_id to be running (so a restart of provider_id restarts dependent_id
// after it). Refuses self-dependencies, unknown nodes, duplicates, overflow,
// and any edge that introduces a cycle in the start tree.
supervision_tree_add_dependency :: proc "contextless" (
	tree: ^Supervision_Tree,
	dependent_id: u32,
	provider_id: u32,
) -> Supervision_Refusal {
	if tree == nil {
		return .Null_Tree
	}
	if !tree.initialized {
		return .Tree_Not_Initialized
	}
	if dependent_id == 0 {
		return .Zero_Child_Id
	}
	if provider_id == 0 {
		return .Unknown_Dependency
	}
	if dependent_id == provider_id {
		return .Dependency_Cycle
	}
	dep_idx, dep_ok := tree_find_node(tree, dependent_id)
	if !dep_ok {
		return .Unknown_Child
	}
	if _, prov_ok := tree_find_node(tree, provider_id); !prov_ok {
		return .Unknown_Dependency
	}
	dependent := &tree.nodes[dep_idx]
	for idx in 0 ..< int(dependent.dependency_count) {
		if dependent.dependency_ids[idx] == provider_id {
			return .Duplicate_Dependency
		}
	}
	if int(dependent.dependency_count) >= SUPERVISION_DEPENDENCY_CAPACITY {
		return .Too_Many_Dependencies
	}
	// Adding edge (dependent_id -> provider_id) creates a cycle iff
	// dependent_id is already reachable from provider_id.
	if node_reaches_target(tree, provider_id, dependent_id) {
		return .Dependency_Cycle
	}

	dependent.dependency_ids[dependent.dependency_count] = provider_id
	dependent.dependency_count += 1
	return .None
}

// restart_window_check_monotonic verifies that now_milliseconds does not move
// backwards relative to the last observed timestamp when window_milliseconds > 0.
// When window_milliseconds == 0, no clock is read and monotonicity always holds.
@(private = "file")
restart_window_check_monotonic :: proc "contextless" (node: ^Supervised_Child, now_milliseconds: u64) -> bool {
	if node.window_milliseconds == 0 {
		return true
	}
	if node.history.has_last_timestamp && now_milliseconds < node.history.last_timestamp_milliseconds {
		return false
	}
	return true
}

// restart_window_try_consume evaluates whether a node is within its restart
// bound and consumes one restart slot if allowed.
// - window_milliseconds == 0: counts over whole uptime; never reads now_milliseconds.
// - window_milliseconds > 0: prunes timestamps strictly older than
//   window_milliseconds (age > window_milliseconds), then checks ring_count < max_restarts.
@(private = "file")
restart_window_try_consume :: proc "contextless" (
	node: ^Supervised_Child,
	now_milliseconds: u64,
) -> (allowed: bool, active_count: u64) {
	if node.window_milliseconds == 0 {
		if node.history.total_restarts >= u64(node.max_restarts) {
			return false, node.history.total_restarts
		}
		node.history.total_restarts += 1
		return true, node.history.total_restarts
	}

	// Prune expired entries strictly older than window_milliseconds.
	for node.history.ring_count > 0 {
		oldest := node.history.timestamps[node.history.ring_head]
		if now_milliseconds - oldest > node.window_milliseconds {
			node.history.ring_head = (node.history.ring_head + 1) % RESTART_WINDOW_RING_CAPACITY
			node.history.ring_count -= 1
		} else {
			break
		}
	}
	node.history.last_timestamp_milliseconds = now_milliseconds
	node.history.has_last_timestamp = true

	if node.history.ring_count >= node.max_restarts {
		return false, u64(node.history.ring_count)
	}
	tail := (node.history.ring_head + node.history.ring_count) % RESTART_WINDOW_RING_CAPACITY
	node.history.timestamps[tail] = now_milliseconds
	node.history.ring_count += 1
	node.history.total_restarts += 1
	return true, u64(node.history.ring_count)
}

// restart_window_would_allow reports without mutating whether a node can
// consume a restart at now_milliseconds (assuming monotonicity already held).
@(private = "file")
restart_window_would_allow :: proc "contextless" (node: ^Supervised_Child, now_milliseconds: u64) -> bool {
	if node.window_milliseconds == 0 {
		return node.history.total_restarts < u64(node.max_restarts)
	}
	remaining := node.history.ring_count
	head := node.history.ring_head
	for remaining > 0 {
		oldest := node.history.timestamps[head]
		if now_milliseconds - oldest > node.window_milliseconds {
			head = (head + 1) % RESTART_WINDOW_RING_CAPACITY
			remaining -= 1
		} else {
			break
		}
	}
	return remaining < node.max_restarts
}

// restart_window_reset clears the restart counts of a child whose ancestor
// supervisor restarted it cleanly, while preserving the monotonic clock floor
// if the child uses a timed window.
@(private = "file")
restart_window_reset :: proc "contextless" (node: ^Supervised_Child, now_milliseconds: u64) {
	node.history = {}
	if node.window_milliseconds > 0 {
		node.history.last_timestamp_milliseconds = now_milliseconds
		node.history.has_last_timestamp = true
	}
	node.permanently_stopped = false
}

// compute_restart_and_stop_orders computes the transitive restart group for
// target_idx under its supervisor's Restart_Strategy and sorts it in
// deterministic topological start order (providers before dependents, breaking
// ties by start_order) and reverse stop order (dependents before providers).
@(private = "file")
compute_restart_and_stop_orders :: proc "contextless" (
	tree: ^Supervision_Tree,
	target_idx: int,
	decision: ^Supervision_Stop_Decision,
) {
	target := &tree.nodes[target_idx]
	strategy := tree.root_strategy
	if target.parent_id != 0 {
		if parent_idx, ok := tree_find_node(tree, target.parent_id); ok {
			strategy = tree.nodes[parent_idx].child_strategy
		}
	}

	in_set: [SUPERVISION_NODE_CAPACITY]bool
	in_set[target_idx] = true

	// Step 1: apply supervisor Restart_Strategy over active siblings of target.
	switch strategy {
	case .None:
		// Validated at tree init / child add; unreachable.
	case .One_For_One:
		// Only target initially; explicit dependents are added by closure below.
	case .One_For_All:
		for &sibling, idx in tree.nodes {
			if sibling.active && !sibling.permanently_stopped && sibling.parent_id == target.parent_id {
				in_set[idx] = true
			}
		}
	case .Rest_For_One:
		for &sibling, idx in tree.nodes {
			if sibling.active && !sibling.permanently_stopped && sibling.parent_id == target.parent_id && sibling.start_order >= target.start_order {
				in_set[idx] = true
			}
		}
	}

	// Step 2: transitive closure over descendants and explicit dependents.
	for {
		added := false
		for &node, idx in tree.nodes {
			if !node.active || node.permanently_stopped || in_set[idx] {
				continue
			}
			for &provider, prov_idx in tree.nodes {
				if in_set[prov_idx] && node_depends_directly_on(&node, provider.child_id) {
					in_set[idx] = true
					added = true
					break
				}
			}
		}
		if !added {
			break
		}
	}

	// Step 3: Kahn's topological sort on in_set, breaking ties by start_order.
	in_degree: [SUPERVISION_NODE_CAPACITY]int
	emitted: [SUPERVISION_NODE_CAPACITY]bool
	total := 0
	for idx in 0 ..< SUPERVISION_NODE_CAPACITY {
		if !in_set[idx] {
			continue
		}
		total += 1
		node := &tree.nodes[idx]
		for prov_idx in 0 ..< SUPERVISION_NODE_CAPACITY {
			if prov_idx != idx && in_set[prov_idx] && node_depends_directly_on(node, tree.nodes[prov_idx].child_id) {
				in_degree[idx] += 1
			}
		}
	}

	count := 0
	for count < total {
		best_idx := -1
		best_order := max(u32)
		for idx in 0 ..< SUPERVISION_NODE_CAPACITY {
			if !in_set[idx] || emitted[idx] || in_degree[idx] != 0 {
				continue
			}
			if tree.nodes[idx].start_order < best_order {
				best_order = tree.nodes[idx].start_order
				best_idx = idx
			}
		}
		if best_idx < 0 {
			break
		}
		emitted[best_idx] = true
		decision.restart_order[count] = tree.nodes[best_idx].child_id
		count += 1

		emitted_id := tree.nodes[best_idx].child_id
		for idx in 0 ..< SUPERVISION_NODE_CAPACITY {
			if in_set[idx] && !emitted[idx] && node_depends_directly_on(&tree.nodes[idx], emitted_id) {
				in_degree[idx] -= 1
			}
		}
	}
	decision.restart_count = count

	// Step 4: stop order is the reverse of start order (dependents first).
	for pos in 0 ..< count {
		decision.stop_order[pos] = decision.restart_order[count - 1 - pos]
	}
	decision.stop_count = count
}

// mark_subtree_permanently_stopped marks root_idx and all of its active
// descendants permanently stopped after escalation exhausts the subtree.
@(private = "file")
mark_subtree_permanently_stopped :: proc "contextless" (tree: ^Supervision_Tree, root_idx: int) {
	in_sub: [SUPERVISION_NODE_CAPACITY]bool
	in_sub[root_idx] = true
	for {
		added := false
		for &node, idx in tree.nodes {
			if !node.active || in_sub[idx] || node.parent_id == 0 {
				continue
			}
			if p_idx, ok := tree_find_node(tree, node.parent_id); ok && in_sub[p_idx] {
				in_sub[idx] = true
				added = true
			}
		}
		if !added {
			break
		}
	}
	for idx in 0 ..< SUPERVISION_NODE_CAPACITY {
		if in_sub[idx] {
			tree.nodes[idx].permanently_stopped = true
		}
	}
}

// reset_descendant_histories resets restart histories of all active
// descendants of root_idx (excluding root_idx itself) when root_idx restarts.
@(private = "file")
reset_descendant_histories :: proc "contextless" (tree: ^Supervision_Tree, root_idx: int, now_milliseconds: u64) {
	in_sub: [SUPERVISION_NODE_CAPACITY]bool
	in_sub[root_idx] = true
	for {
		added := false
		for &node, idx in tree.nodes {
			if !node.active || in_sub[idx] || node.parent_id == 0 {
				continue
			}
			if p_idx, ok := tree_find_node(tree, node.parent_id); ok && in_sub[p_idx] {
				in_sub[idx] = true
				added = true
			}
		}
		if !added {
			break
		}
	}
	for idx in 0 ..< SUPERVISION_NODE_CAPACITY {
		if in_sub[idx] && idx != root_idx {
			restart_window_reset(&tree.nodes[idx], now_milliseconds)
		}
	}
}

// supervision_tree_record_stop evaluates a child stop at monotonic timestamp
// now_milliseconds and decides whether to restart the child, restart its
// group, escalate to its parent supervisor (or root starter), or stop
// permanently.
//
// Invariants:
// - Invalid stop_cause/stop_outcome pairs are refused with tree unchanged.
// - Done and Refused stops never restart and never consume restart budget.
// - Backwards clock timestamps (when window_milliseconds > 0) are refused
//   with tree unchanged.
// - window_milliseconds == 0 never reads or validates now_milliseconds.
// - Escalation walks strictly upward in the acyclic tree and always terminates.
supervision_tree_record_stop :: proc "contextless" (
	tree: ^Supervision_Tree,
	child_id: u32,
	stop_cause: op.Stop_Cause,
	stop_outcome: op.Stop_Outcome,
	now_milliseconds: u64,
) -> Supervision_Stop_Decision {
	if tree == nil {
		return {refusal = .Null_Tree}
	}
	if !tree.initialized {
		return {refusal = .Tree_Not_Initialized}
	}
	if child_id == 0 {
		return {refusal = .Zero_Child_Id}
	}
	child_idx, found := tree_find_node(tree, child_id)
	if !found {
		return {refusal = .Unknown_Child}
	}
	if tree.nodes[child_idx].permanently_stopped {
		return {refusal = .Child_Permanently_Stopped}
	}

	// Validate stop cause and stop outcome through the kernel stop border.
	_, _, valid_outcome, stop_ok := op.stop_of_words(u64(op.Process_State.Stopped), u64(stop_cause), u64(stop_outcome))
	if !stop_ok {
		return {refusal = .Invalid_Stop_Words}
	}

	child := &tree.nodes[child_idx]

	// Clean Done or Refused stops never restart and never consume restart budget.
	if !start_list.stop_restarts(valid_outcome) {
		child.permanently_stopped = true
		return {
			refusal            = .None,
			action             = .Stop_Permanently,
			restarts_in_window = child.window_milliseconds == 0 ? child.history.total_restarts : u64(child.history.ring_count),
		}
	}

	// Pre-validate monotonic clock on the child and, if escalation will occur,
	// on every ancestor that escalation will consult, so any refusal leaves
	// tree completely unchanged.
	if !restart_window_check_monotonic(child, now_milliseconds) {
		return {refusal = .Clock_Moved_Backwards}
	}
	if !restart_window_would_allow(child, now_milliseconds) && child.needed {
		walk_idx := child_idx
		for _ in 0 ..< SUPERVISION_NODE_CAPACITY {
			if tree.nodes[walk_idx].parent_id == 0 {
				break
			}
			p_idx, p_ok := tree_find_node(tree, tree.nodes[walk_idx].parent_id)
			if !p_ok {
				break
			}
			if !restart_window_check_monotonic(&tree.nodes[p_idx], now_milliseconds) {
				return {refusal = .Clock_Moved_Backwards}
			}
			if restart_window_would_allow(&tree.nodes[p_idx], now_milliseconds) || !tree.nodes[p_idx].needed {
				break
			}
			walk_idx = p_idx
		}
	}

	// Attempt to consume one restart within the child's own bound/window.
	allowed, count := restart_window_try_consume(child, now_milliseconds)
	if allowed {
		decision := Supervision_Stop_Decision {
			refusal            = .None,
			restarts_in_window = count,
		}
		compute_restart_and_stop_orders(tree, child_idx, &decision)
		decision.action = decision.restart_count > 1 ? .Restart_Group : .Restart_Child
		return decision
	}

	// Child exceeded its restart bound.
	if !child.needed {
		mark_subtree_permanently_stopped(tree, child_idx)
		return {
			refusal            = .None,
			action             = .Stop_Permanently,
			restarts_in_window = count,
		}
	}

	// Escalate up the supervision tree until an ancestor absorbs the restart,
	// a non-needed ancestor stops permanently, or the root starter is reached.
	cur_idx := child_idx
	for _ in 0 ..< SUPERVISION_NODE_CAPACITY {
		parent_id := tree.nodes[cur_idx].parent_id
		if parent_id == 0 {
			mark_subtree_permanently_stopped(tree, cur_idx)
			return {
				refusal            = .None,
				action             = .Escalate_To_Parent,
				escalated_to_id    = 0,
				restarts_in_window = count,
			}
		}
		parent_idx, parent_ok := tree_find_node(tree, parent_id)
		if !parent_ok {
			mark_subtree_permanently_stopped(tree, cur_idx)
			return {
				refusal            = .None,
				action             = .Escalate_To_Parent,
				escalated_to_id    = 0,
				restarts_in_window = count,
			}
		}
		parent := &tree.nodes[parent_idx]
		parent_allowed, _ := restart_window_try_consume(parent, now_milliseconds)
		if parent_allowed {
			// Parent absorbs escalation: reset descendant restart histories
			// and restart the parent's group and subtree cleanly.
			reset_descendant_histories(tree, parent_idx, now_milliseconds)
			decision := Supervision_Stop_Decision {
				refusal            = .None,
				action             = .Escalate_To_Parent,
				escalated_to_id    = parent.child_id,
				restarts_in_window = count,
			}
			compute_restart_and_stop_orders(tree, parent_idx, &decision)
			return decision
		}
		if !parent.needed {
			mark_subtree_permanently_stopped(tree, parent_idx)
			return {
				refusal            = .None,
				action             = .Stop_Permanently,
				restarts_in_window = count,
			}
		}
		cur_idx = parent_idx
	}

	mark_subtree_permanently_stopped(tree, cur_idx)
	return {
		refusal            = .None,
		action             = .Stop_Permanently,
		restarts_in_window = count,
	}
}
