type: Added

**The requested grants in the menu of the windows.** The menu of the windows lists, under each window, each grant that its process asked for and that the principal allowed, with a button Revoke: a press on it, or Enter on the row, ends the grant at once with no console. `compositor.window_grants()` lists the same grants and `compositor.revoke_grant(number)` ends one. `compositor.plan_diff_ask(name, added, removed)` shows the difference of a plan on the trusted display, which the principal accepts or refuses whole.
