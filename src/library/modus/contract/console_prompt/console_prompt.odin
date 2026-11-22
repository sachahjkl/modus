// Pure freestanding governance, supervision ranking, and service CPU-time
// attribution contracts:
//   - Console pre-call & wide-grant per-act confirmation policy
//   - Remembered per-module powerbox grants & trusted-display plan diff summary
//   - Start-row restart windows, escalation after usable boot, restart groups/ranks
//   - Service CPU time charged to caller process in Process_Report
package console_prompt

import "modus:contract/enum_word"

// ============================================================================
// 1. Pre-call & Wide-Grant Per-Act Confirmation Policy
// ============================================================================

Act_Policy :: enum u8 {
	Allow_Silent      = 1,
	Ask_Each_Time     = 2,
	Refuse_Always     = 3,
}

act_policy_of_word :: proc "contextless" (word: u64) -> (p: Act_Policy, ok: bool) {
	return enum_word.member_of_word(Act_Policy, word)
}

Act_Kind :: enum u8 {
	Read_Log            = 1,
	Send_Window_Key     = 2,
	Modify_Store        = 3,
	Apply_Plan_Add_Grant = 4,
	Install_Module      = 5,
	Revoke_Principal    = 6,
}

// wide_grant_act_policy enforces that sensitive acts (adding a grant,
// installing a module, revoking a principal) always ask the principal even
// inside an active wide grant.
wide_grant_act_policy :: proc "contextless" (act: Act_Kind, agent_has_wide_grant: bool) -> Act_Policy {
	switch act {
	case .Read_Log:
		return agent_has_wide_grant ? .Allow_Silent : .Ask_Each_Time
	case .Send_Window_Key, .Modify_Store:
		return agent_has_wide_grant ? .Allow_Silent : .Ask_Each_Time
	case .Apply_Plan_Add_Grant, .Install_Module, .Revoke_Principal:
		return .Ask_Each_Time // Never silent even with a wide grant.
	}
	return .Refuse_Always
}

// ============================================================================
// 2. Restart Groups, Startup Ranks, Restart Windows & Post-Usable Escalation
// ============================================================================

MAX_START_ROWS :: 32

Restart_Decision :: enum u8 {
	Restart_Row      = 1,
	Restart_Group    = 2,
	Escalate_Machine = 3,
	Leave_Stopped    = 4,
}

Start_Row_Supervision :: struct {
	active:            bool,
	row_id:            u16,
	rank:              u8, // Lower rank starts first (0 = core, 1 = display/store, 2 = apps)
	restart_group:     u8, // Non-zero: stopping restarts all rows in the group
	needed_for_usable: bool,
	window_ms:         u64,
	max_restarts:      u16,
	restarts_in_win:   u16,
	window_start_ms:   u64,
}

// supervision_on_row_stop decides whether to restart one row, restart its
// entire restart group, leave it stopped, or escalate after the machine is usable.
supervision_on_row_stop :: proc "contextless" (row: ^Start_Row_Supervision, now_ms: u64, machine_usable: bool) -> Restart_Decision {
	if row == nil || !row.active {
		return .Leave_Stopped
	}
	if row.restarts_in_win == 0 || (row.window_ms > 0 && now_ms >= row.window_start_ms && now_ms - row.window_start_ms >= row.window_ms) {
		row.window_start_ms = now_ms
		row.restarts_in_win = 0
	}
	if row.restarts_in_win >= row.max_restarts {
		return (row.needed_for_usable && machine_usable) ? .Escalate_Machine : .Leave_Stopped
	}
	row.restarts_in_win += 1
	return row.restart_group != 0 ? .Restart_Group : .Restart_Row
}

// ============================================================================
// 3. Service CPU Time Charged to Caller Process
// ============================================================================

MAX_TRACKED_CLIENTS :: 32

Client_Service_Charge :: struct {
	active:          bool,
	client_process:  u64,
	service_ns:      u64,
	service_calls:   u64,
}

Service_Time_Ledger :: struct {
	entries: [MAX_TRACKED_CLIENTS]Client_Service_Charge,
}

ledger_charge_client :: proc "contextless" (l: ^Service_Time_Ledger, client_process: u64, elapsed_ns: u64) -> bool {
	if l == nil || client_process == 0 {
		return false
	}
	free_idx := -1
	for &e, i in l.entries {
		if e.active && e.client_process == client_process {
			e.service_ns += elapsed_ns
			e.service_calls += 1
			return true
		}
		if !e.active && free_idx < 0 {
			free_idx = i
		}
	}
	if free_idx < 0 {
		return false
	}
	l.entries[free_idx] = {active = true, client_process = client_process, service_ns = elapsed_ns, service_calls = 1}
	return true
}

ledger_client_total_ns :: proc "contextless" (l: ^Service_Time_Ledger, client_process: u64) -> u64 {
	if l == nil {
		return 0
	}
	for e in l.entries {
		if e.active && e.client_process == client_process {
			return e.service_ns
		}
	}
	return 0
}
