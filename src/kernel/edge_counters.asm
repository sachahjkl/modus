; The edge counters of the counted kernel, kernel_edge_counters
; (src/md/infrastructure/kernel_fuzzing.md, "The test kernel"). Only that
; module links this file: the build of each other kernel leaves it out, and
; gives this one the count of the guards of its IR as EDGE_COUNT.
;
; The pass sancov-module of opt adds, at each edge of the compiled code of
; the kernel, a call of __sanitizer_cov_trace_pc_guard with the address of a
; guard of 4 bytes in the section __sancov_guards. The callback is here, in
; assembly, so that it has no IR and the pass does not add a call of the
; callback inside the callback. It pushes nothing: the measure of the stack
; takes it with no frame. System V convention: rax and rcx are the
; registers of the caller.
bits 64
default rel

%ifndef EDGE_COUNT
%error "EDGE_COUNT: the tool gives the count of the guards of the IR of the kernel"
%endif

; ld.lld defines the start of the section of the guards, which the pass
; names, for the code that names it.
extern __start___sancov_guards

section .text

; (guard: ^u32): one edge ran. The place of the guard in its section is the
; number of the edge. The guards stay 0: the number comes from the place,
; with no write at the start.
global __sanitizer_cov_trace_pc_guard
__sanitizer_cov_trace_pc_guard:
	cmp byte [edge_counting], 0
	je .done                     ; The code of no counted process.
	mov rax, rdi
	lea rcx, [__start___sancov_guards]
	sub rax, rcx
	shr rax, 2                   ; One guard of 4 bytes for each edge.
	cmp rax, EDGE_COUNT
	jae .done                    ; Past the guards of the IR: no counter.
	lea rcx, [edge_counters]
	cmp byte [rcx + rax], 255
	je .done                     ; The counter stays at its largest value.
	inc byte [rcx + rax]
.done:
	ret

; (start, end: ^u32): the constructor that the pass adds calls it. The
; kernel runs no constructor, and the tool removes the list of the
; constructors from the IR; the constructor itself stays, with this call,
; so the symbol is defined here: a symbol with no definition would be an
; import, and the kernel has none.
global __sanitizer_cov_trace_pc_guard_init
__sanitizer_cov_trace_pc_guard_init:
	ret

section .rodata

; The count of the counters, which the boot line gives.
global edge_counter_count
align 8
edge_counter_count:
	dq EDGE_COUNT

section .bss

; 1 while the kernel runs the code of a counted process (edge_counters.odin).
global edge_counting
edge_counting:
	resb 1

; One byte for each edge. A run of physical pages: the counted kernel checks
; it at its start, and the tool reads it through the memory file.
global edge_counters
alignb 64
edge_counters:
	resb EDGE_COUNT
