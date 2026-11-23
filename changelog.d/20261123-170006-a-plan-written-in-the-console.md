type: Added

**A plan written as `plan { ... }` reaches `plans.apply`.** `plans.apply("home", plan { values = { browser = { home = "modus://guide" } }, locks = { settings = { appearance = .dark } } }, {})` applies a plan written in the console: roles by the hash of their module, store grants, defaults and locks. Each value is typed by the description of its owner before the call, and a refusal names what is wrong: the owner, the field, the member, the range or the bound.
