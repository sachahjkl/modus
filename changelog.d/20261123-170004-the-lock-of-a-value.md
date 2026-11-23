type: Added

**The lock of a value.** A plan of principal 0 can lock a setting: its value holds over the choice of the principal, and each setter and `reset` refuses a change of it with `No_Grant`, unit `Plan_Lock`: "the argument font is locked by the plan of principal 0". The choice of the principal stays kept, and holds again when the lock ends; `settings_state` gives the layer `Locked`.
