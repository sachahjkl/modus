type: Added

**Typed objects at the border of the storage service**: the storage service now holds the border of a typed object for the owner of a store: it copies the object, checks its descriptions, its records and the description hash that the owner expects, and runs a derived forward migration or the checked backward migration of a rollback, which refuses the whole object (no clamp, no cut text, no byte written) when a value does not fit. Host tests run one stored type through three releases and back. No module declares a stored type yet, so no store migrates.
