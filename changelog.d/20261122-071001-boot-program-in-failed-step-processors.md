type: Added

**The boot program named in the processors of a failed step.** The boot program logs its UEFI loaded image base address and size, and the tool parses that range when reporting processors on a failed step so an instruction inside the boot program names the boot program and its offset instead of "no known code".
