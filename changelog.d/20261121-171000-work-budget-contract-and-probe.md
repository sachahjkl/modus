type: Added

**Work budget contract and per-connection work thread probe**: added the `work_budget` contract package with closed `Work_Account_State` and `Work_Budget_Refusal` enums, `Work_Budget_Requirements`, border-validated `Accounting_Snapshot` records, `work_budget_check`, and the `Connection_Worker_Table` state machine isolating client exhaustion and revocation; added the `work_accounting_probe` test module spawning one work thread and scratch memory per connection strictly on the client's offered child budget with `Spend` right, with adversarial host tests.
