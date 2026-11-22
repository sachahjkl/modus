type: Changed

**Core service resolution by role in the root service.** `root` now resolves `Display`, `Input`, `Terminal`, `Storage`, and `Network` holders through `role_holder_name` and `is_role_holder` instead of hardcoded module names across startup, connections, and disk-process loading.
