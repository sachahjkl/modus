type: Added

**Project console session lifecycle**: `projects.enter` and `exit()` manage bounded, nested child project consoles per principal without modifying the applied plan or installing modules globally, requiring verified trusted display consent when entering adds module or store grants outside the current session and revoking all temporary connections and store shares on exit.
