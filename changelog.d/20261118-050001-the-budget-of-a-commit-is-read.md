type: Fixed

**The budget of a commit is always read**: the form of the budget of `Memory_Commit` in `op.OPERATIONS` is now a handle, not a handle or 0, and `op.argument_is_read` says that a commit reads a budget of 0. The kernel refuses that budget with a detail of its own, and the contract now agrees with it. A decommit still reads no budget.
