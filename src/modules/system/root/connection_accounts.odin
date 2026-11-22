// Live per-connection work-budget accounting, supervision generation tracking,
// and service CPU-time attribution inside the root core
// (src/md/features/work_accounting.md) and (src/md/features/supervision.md).
package root

import "modus:contract/console_prompt"
import "modus:contract/role_contract"
import "modus:contract/work_budget"

CONNECTION_ACCOUNT_CAPACITY :: 64

Connection_Account :: struct {
	active:          bool,
	caller_process:  u64,
	service_role:    role_contract.Role,
	generation:      u64,
	budget_pages:    u64,
	established_ms:  u64,
}

connection_accounts: [CONNECTION_ACCOUNT_CAPACITY]Connection_Account
connection_service_ledger: console_prompt.Service_Time_Ledger

// connection_account_open records a new live client-to-service connection after
// checking its per-connection work budget against work_budget contract limits.
connection_account_open :: proc "contextless" (caller_process: u64, service_name: string, now_ms: u64) -> bool {
	if caller_process == 0 {
		return false
	}
	role := role_of_module_name(service_name)
	reqs := work_budget.Work_Budget_Requirements{
		stack_pages                    = 2,
		scratch_pages                  = 4,
		ring_pages                     = 4,
		minimum_processor_microseconds = 1_000,
	}
	if !role_connection_work_budget_check(reqs, 16, 1_000_000, 1) {
		return false
	}
	gen := role != .None ? role_service_generations[role] : u64(0)
	for &acc in connection_accounts {
		if !acc.active {
			acc = {
				active         = true,
				caller_process = caller_process,
				service_role   = role,
				generation     = gen,
				budget_pages   = 16,
				established_ms = now_ms,
			}
			return true
		}
	}
	return true
}

// connection_account_close releases the tracked connection account and records
// its service duration on the client's service-time ledger.
connection_account_close :: proc "contextless" (caller_process: u64, service_name: string, now_ms: u64) {
	role := role_of_module_name(service_name)
	for &acc in connection_accounts {
		if acc.active && acc.caller_process == caller_process && acc.service_role == role {
			elapsed_ns := now_ms >= acc.established_ms ? (now_ms - acc.established_ms) * 1_000_000 : 0
			_ = console_prompt.ledger_charge_client(&connection_service_ledger, caller_process, elapsed_ns)
			acc = {}
			return
		}
	}
}
