type: Changed

**The last eight modules move their post-ready memory off working_memory_pages.** Every module in `src/modules/` now omits hand-written working memory from its floor; shipped post-ready budgets live in the signed `default_plan_values` boot-image plan (`browser`, `clock`, `debugger`, `doom`, `guest_builder`, `linux`, `paint`, and `recipes`) and test budgets in `test_plan_values` (`pdpe1gb_probe`), layered beneath principal 0's live plan.
