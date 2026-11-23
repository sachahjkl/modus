type: Security

**An unmap wakes the threads that wait on its frames.** A thread that waited on a word of a memory object that its process then unmapped and closed kept waiting on a frame that returned to the free frames: the next process that took the frame had its wakes of count 1 taken by that thread, and the thread learned its wakes. The unmap, and the end of the point copies of a record, now wake such a thread first, as a decommit and a revocation did. A refused `Word_Wait` now leaves its whole entry with no wait.
