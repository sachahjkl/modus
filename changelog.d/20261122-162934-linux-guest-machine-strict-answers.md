type: Fixed

**Stricter answers of the machine of a Linux guest.** A write of `EFER` that changes `LME` while paging is on gives the guest a general protection fault, as the processor does; `rdmsr` and `wrmsr` complete at the next instruction that the kernel gives; and a relocatable kernel whose preferred address wraps at its alignment is refused with `Bad_Alignment`.
