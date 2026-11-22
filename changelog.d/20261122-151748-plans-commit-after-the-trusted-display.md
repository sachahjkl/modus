type: Changed

**A plan commits only after the trusted display**: `plans.apply` shows the difference of a plan with `compositor.plan_diff_ask` and gives a ticket, and `plans.apply_poll(ticket)` commits the plan only when the principal accepted it, which `compositor.plan_diff_poll` gives; a refused difference changes nothing.
The services `plans`, `projects` and `recipes` keep their applied plans, their projects with `pins.lex`, and their realisations in their private store, and read them back after a start; until the root service gives them that store, each commit is refused with `Store_Failed`.
