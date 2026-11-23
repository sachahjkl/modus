type: Fixed

**A guest build ends on a time bound, and the service answers while it runs.** A guest that never exits by itself is ended by the time bound of its spec, at most one day, and refused with `Build_Timed_Out`; before, it held the service `recipes` for ever. A guest build runs on a thread of its own: `recipes.build` answers `Building`, the service answers each other call while the guest runs, and a second guest build is refused with `Builder_Busy`.
