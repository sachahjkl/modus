type: Removed

**The rule of a bridge as a contract of its own.** The contract package `modus:contract/bridge_requester` holds the rule that gives the devices behind a conventional bridge of PCI one requester, which the kernel and the root service share. The four packages `modus:contract/iommu`, `modus:contract/acpi_processors`, `modus:contract/debug_exception` and `modus:contract/processor_counters` leave the source library `modus`: only the kernel reads them, and a program outside the repository can no longer import them.
