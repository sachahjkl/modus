; The instructions that a process needs and that Odin cannot write.
bits 64
default rel
section .text

global system_enter
system_enter:                    ; (wait: u64) -> u64: the one kernel entry point
	syscall
	ret

global thread_record
thread_record:                   ; () -> ^Thread_Record: the kernel keeps this address in gs
	mov rax, [gs:0]
	ret

global port_write_8
port_write_8:                    ; (port: u16, value: u8)
	mov edx, edi
	mov eax, esi
	out dx, al
	ret

global port_read_8
port_read_8:                     ; (port: u16) -> u8
	mov edx, edi
	xor eax, eax
	in al, dx
	ret

global port_write_32
port_write_32:                   ; (port: u16, value: u32)
	mov edx, edi
	mov eax, esi
	out dx, eax
	ret

global port_read_32
port_read_32:                    ; (port: u16) -> u32
	mov edx, edi
	in eax, dx
	ret

; The one routine that calls an export from values in memory: the call form
; of docs/MODULE_CONTRACT.md, section 4. Every parameter is a scalar, so the
; routine does not need the description of the export. Integers 1 to 6 go
; in registers, 7 to 16 on the stack at the call, the 7th at the lowest
; address, as System V passes them. The routine always writes the ten words:
; a callee reads the words that it has, so no count is needed.
global export_call
export_call:                     ; (address, integers: ^[16]u64, floats: ^[8]u64, results: ^[4]u64)
	push rbp
	mov rbp, rsp
	push rbx
	push r12                     ; The stack is at a multiple of 16 here.
	sub rsp, 80                  ; Ten words of stack arguments keep that multiple for the call.
	mov r11, rdi
	mov r10, rsi
	mov rbx, rcx
	mov rax, [r10 + 48]
	mov [rsp], rax
	mov rax, [r10 + 56]
	mov [rsp + 8], rax
	mov rax, [r10 + 64]
	mov [rsp + 16], rax
	mov rax, [r10 + 72]
	mov [rsp + 24], rax
	mov rax, [r10 + 80]
	mov [rsp + 32], rax
	mov rax, [r10 + 88]
	mov [rsp + 40], rax
	mov rax, [r10 + 96]
	mov [rsp + 48], rax
	mov rax, [r10 + 104]
	mov [rsp + 56], rax
	mov rax, [r10 + 112]
	mov [rsp + 64], rax
	mov rax, [r10 + 120]
	mov [rsp + 72], rax
	movq xmm0, [rdx]
	movq xmm1, [rdx + 8]
	movq xmm2, [rdx + 16]
	movq xmm3, [rdx + 24]
	movq xmm4, [rdx + 32]
	movq xmm5, [rdx + 40]
	movq xmm6, [rdx + 48]
	movq xmm7, [rdx + 56]
	mov rdi, [r10]
	mov rsi, [r10 + 8]
	mov rdx, [r10 + 16]
	mov rcx, [r10 + 24]
	mov r8, [r10 + 32]
	mov r9, [r10 + 40]
	call r11
	mov [rbx], rax
	mov [rbx + 8], rdx
	movq [rbx + 16], xmm0
	movq [rbx + 24], xmm1
	add rsp, 80
	pop r12
	pop rbx
	pop rbp
	ret
