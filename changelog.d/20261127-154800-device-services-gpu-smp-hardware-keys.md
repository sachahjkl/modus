type: Added

**Live runtime wiring for device services, Venus GPU, Linux SMP, and `gui_toolkit`.** Wired PCI topology, AMD-Vi IVMD/IRTE checks, and live NVMe 1.4+ controller support into `devices` and `block`; Venus shared-memory ring submission with `Write_Combining` ordering into `gpu_device`; multi-vCPU ACPI MADT and round-robin SMP scheduling into `linux`; fail-closed origin isolation, WebAuthn single-use challenges, and cycle-checked outside-module import graphs into `browser` and `disk_processes`; and single-use hardware-key verification into `unlock`, `recipes`, and `root`.
