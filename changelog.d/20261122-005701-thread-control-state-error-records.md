type: Changed

**The records of the states of Thread_Control.** Every `Bad_State` refusal of `Thread_Control` now returns a specific error record (`Absent`, `State`, `Over_Limit`, or `Object_Shared` with exact unit and argument) instead of generic `Refused`, naming missing threads or processes, stopped targets, unheld threads, active recording, or exhausted stop counts while respecting handle `Read` rights.
