type: Changed

**The last exports with a negative result give their call outcome.** `module_files.put` and `read`, `recipes.build_c`, `projects.new`, the act dialog of the compositor (`act_ask`, `act_poll`, `act_cancel`, `plan_diff_poll`) and the exports of the conversation of the assistant now give the call outcome first and the value second, as every other export does. A refusal of a recipe, of the debugger and of a step of the C builder now pairs its outcome with a kind that the outcome explains.
