package surface_budget_edges

import "modus:contract/value_kinds"

// The log facts of the test module surface_budget_edges (src/md/features/log_facts.md).

@(log_fact = "surface_budget_edges: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

@(log_fact = "surface_budget_edges: the compositor refused a budget one page short, a revoked copy and a budget with no Spend: as it must")
Budgets_Refused :: struct {}

// A measure, with no bound: the close of the last handle of a budget that
// pays one live object, which walks the tables of the kernel.
@(log_fact = "surface_budget_edges: the end of the budget of a surface took {nanoseconds} ns, the kernel entry included")
Budget_End_Measured :: struct {
	nanoseconds: u64,
}

@(log_fact = "surface_budget_edges: the compositor made the surface of {width}x{height} with the budget of the window, which the window cannot take back: as it must")
Surface_Made_By_The_Compositor :: struct {
	width:  u64,
	height: u64,
}
