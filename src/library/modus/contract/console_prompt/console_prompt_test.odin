#+build !freestanding
#+build !modus
package console_prompt

import "core:testing"

@(test)
wide_grant_policy_restart_groups_and_service_time_charging :: proc(t: ^testing.T) {
	_, bad := act_policy_of_word(99)
	testing.expect(t, !bad)

	// Wide grant allows silent log/window keys, but ALWAYS asks before adding grants or installing modules.
	testing.expect_value(t, wide_grant_act_policy(.Send_Window_Key, true), Act_Policy.Allow_Silent)
	testing.expect_value(t, wide_grant_act_policy(.Send_Window_Key, false), Act_Policy.Ask_Each_Time)
	testing.expect_value(t, wide_grant_act_policy(.Apply_Plan_Add_Grant, true), Act_Policy.Ask_Each_Time)
	testing.expect_value(t, wide_grant_act_policy(.Install_Module, true), Act_Policy.Ask_Each_Time)

	// Restart group & escalation after usable boot.
	row := Start_Row_Supervision{
		active            = true,
		row_id            = 1,
		rank              = 1,
		restart_group     = 2,
		needed_for_usable = true,
		window_ms         = 10_000,
		max_restarts      = 2,
	}
	testing.expect_value(t, supervision_on_row_stop(&row, 1_000, true), Restart_Decision.Restart_Group)
	testing.expect_value(t, supervision_on_row_stop(&row, 2_000, true), Restart_Decision.Restart_Group)
	testing.expect_value(t, supervision_on_row_stop(&row, 3_000, true), Restart_Decision.Escalate_Machine)

	// Service CPU time charged to client process.
	ledger: Service_Time_Ledger
	testing.expect(t, ledger_charge_client(&ledger, 42, 150_000))
	testing.expect(t, ledger_charge_client(&ledger, 42, 250_000))
	testing.expect_value(t, ledger_client_total_ns(&ledger, 42), u64(400_000))
}
