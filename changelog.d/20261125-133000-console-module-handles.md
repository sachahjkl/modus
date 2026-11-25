type: Changed

**Bound, namespaced console module handles.** `load`, `isolate`, and `isolate_memory` now require binding to a variable (`m = load("math")`, `s = isolate("sample")`) and register exports and record constructors strictly under `<binding>.<name>`. Multiple instances of the same module can run simultaneously, `help(s)` lists the commands of one handle, and `unload(s)` or reassigning `s` removes only that handle's commands and stops its call host or releases its module.
