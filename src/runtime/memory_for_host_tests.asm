; The form of the host of src/runtime/memory.asm, for the tests of the modus tool
; (src/runtime/memory_test.odin): the long names only. The compiler assembles
; this file itself and links its object by its path. The modus tool runs
; the tests from the root of the repository.
%define HOST
%include "src/runtime/memory.asm"
