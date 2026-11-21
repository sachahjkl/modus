type: Changed

**Two terms renamed: start grant set and stint.** What the root service gives a process at its start is now a start grant set (the table `start_grant_sets`, in `src/modules/system/root/start_grant_sets.odin`), so "role" means only a contract. The time that a thread runs on a processor from its pick until it leaves is now a stint, so "turn" means only the unit of angle: the guides, the log lines of the root service and of `scheduler`, and the view of `scheduler` use the new words.
