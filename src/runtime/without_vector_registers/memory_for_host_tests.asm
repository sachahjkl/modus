; The kernel form of src/runtime/memory.asm, for the tests of the modus tool
; (src/runtime/without_vector_registers/memory_test.odin): the long names only,
; and no x87, SSE or AVX register. The modus tool runs the tests from the
; root of the repository.
%define HOST
%define WITHOUT_VECTOR_REGISTERS
%include "src/runtime/memory.asm"
