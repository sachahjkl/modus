type: Fixed

**Input history recording during CPU-bound work.** Recording a process now ends at the stint bound only when a shared writer has waited one full time slice, rather than ending after a short scheduler slice when no shared writer waits.
