type: Changed

**Start policy, network plan endpoints, and console palette provider resolved by role.** `root` now resolves `Start_Policy` and `Remote_Display` by role, supports plan-supplied network endpoint rules via `plan_endpoint_set`, wires `supervision` generation advancement and `work_budget` checks into `role_holders.odin`, and `compositor` raises the active palette provider window instead of hardcoding `console`.
