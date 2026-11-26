type: Fixed

**Open desktop applications without a data disk and bound host module test memory.** On a machine without a data disk (such as Web Desktop or a virtual machine booted from the boot image alone), desktop applications that carry a store grant (`settings`, `monitor`, `edit`, `files`, `paint`, `notes`, `code`, `browser`, `assistant`) now open without a store instead of failing to launch, and the `host_modules` test clears temporary allocations between modules so it stays within CI memory limits.
