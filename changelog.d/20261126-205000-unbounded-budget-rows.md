type: Added

**Unbounded budget rows up to the safety ceiling.** Plans now accept `budget_pages = .unbounded`, `console` accepts `start(name, "unbounded")`, and the desktop start menu supports Shift+Enter / Shift+Space for processes of unknown memory need, reserving floor and default size at start and permitting unreserved `Budget_Grow` growth up to the machine safety ceiling (one quarter by default) while charging named principals against their session budget.
