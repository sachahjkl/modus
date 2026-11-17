type: Changed

**One folder of modules by group.** The programs and the other modules are one folder, `src/modules`, in four groups by what each module is for: `system` (the root service, the services, the desktop and the tools of a principal), `libraries` (the modules with no entry that other modules import), `demonstrations` (the programs that each show a property) and `tests` (the test modules that only a machine test starts). The path of a source in a stop report, a stack trace and the debugger names its group: `src/modules/demonstrations/fault/main.odin:15`.
