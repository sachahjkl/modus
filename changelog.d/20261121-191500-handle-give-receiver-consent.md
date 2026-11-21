type: Security

**A handle given into a shared memory only to a process that agreed to receive one.** `Handle_Give` targeting a memory object now transfers a handle only into another process that mapped that memory with `Map_Flag.Receive_Handles`, and refuses mappings without consent with `No_Right` (`Refused`) while leaving every handle table untouched. Output rings, list pages, wiring rings on the wiring service side, and root rings without handle-lending grants never accept unsolicited handles.
