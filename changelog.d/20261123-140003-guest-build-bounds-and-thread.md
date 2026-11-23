type: Fixed

**A guest build ends on a time bound, and the service answers while it runs.** A guest that never exits by itself is ended by the time bound of its spec, at most one day, and refused with `Builder_Timed_Out`; before, it held the service `recipes` for ever. A guest build runs on a thread of its own: `recipes.build` answers `Building`, and the service answers each other call while the guest runs. Guest builds wait in a queue of 8, at most 2 for each principal, in turns between principals, and `recipes.build_cancel` cancels a build of the principal that asks.
