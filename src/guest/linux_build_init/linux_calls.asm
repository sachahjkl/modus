; The entry of the init of a guest build, its system calls of Linux and the
; two port instructions of the build protocol
; (src/md/features/guest_build_image.md, "The program init").
bits 64
section .text
global _start
global linux_call
global port_in32
global port_out32
extern init_main

; The stack of a new process is aligned to 16 bytes at _start, with argc
; at its top: the entry gets that place, and a call pushes 8 bytes, as a
; procedure of the System V ABI expects at its entry.
_start:
	xor rbp, rbp
	mov rdi, rsp
	and rsp, -16
	call init_main
	ud2

; linux_call(number, a, b, c, d, e, f): rdi, rsi, rdx, rcx, r8, r9, then
; the seventh argument on the stack. Linux takes rax, rdi, rsi, rdx, r10,
; r8, r9.
linux_call:
	mov rax, rdi
	mov rdi, rsi
	mov rsi, rdx
	mov rdx, rcx
	mov r10, r8
	mov r8, r9
	mov r9, [rsp + 8]
	syscall
	ret

; port_in32(port) reads 4 bytes of an I/O port.
port_in32:
	mov edx, edi
	in eax, dx
	ret

; port_out32(port, value) writes 4 bytes to an I/O port.
port_out32:
	mov edx, edi
	mov eax, esi
	out dx, eax
	ret
