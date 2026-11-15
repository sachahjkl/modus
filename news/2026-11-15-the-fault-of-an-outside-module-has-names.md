title: The fault of an outside module names its procedures and its lines
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A module built outside the repository runs on a machine from its data disk. When it stops on a fault, the root service now keeps its stop report: before, the report left the machine with the program.

Type `stop_report("outsider_fault")` in the console. No attach is needed. The debugger reads the debug object of the module from the disk, and gives one row for each frame of the stack: the procedure, the source file by the name of the folder of the developer, and the line.

`outsider_fault  visitor::fault_three  outsider/main.odin   169`

The report holds only the frames that a module of the program holds, so no word of the memory of the program leaves it. The caller must act for the principal of the program.
