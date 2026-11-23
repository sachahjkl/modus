type: Fixed

**A commit on a damaged object keeps its pending changes.** When `storage.commit` finds the state before damaged, it gives `Data_Damaged` and the pending changes of the connection stay, as the outcome says that nothing changed; only a commit after another change of the object drops them.
