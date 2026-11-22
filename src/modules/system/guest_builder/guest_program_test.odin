#+build !freestanding
package guest_builder_module

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import contract "modus:contract/guest_builder"
import "modus:contract/guest_os"
import op "modus:contract/operation"
import sm "modus:contract/software_machine"

// A build from end to end on the host, with no kernel: a real program of
// 64 bits boots through linux_boot_prepare as a vmlinux, in long mode with
// rsi at the zero page, and runs on the software processor of
// modus:contract/software_machine. A small adapter turns what the software
// processor stops on into the exits that Guest_Run gives (a port, cpuid,
// rdmsr, a device access through the nested page table), and the loop of
// the builder (build_exit_handle) answers each with the machine of
// modus:contract/guest_os. The program checks the zero page in rsi, reads
// EFER, the page attribute table and MTRRCAP with rdmsr, the vendor with
// cpuid, the time stamp counter twice with rdtsc, and runs wbinvd: each an
// exit that the machine answers. Then it drives the virtio devices as a
// driver does, with the forms of mov of the accessors of Linux: it starts
// each device by the transport of version 2, reads the capacity with movzx
// and movsx, reads the read-only disk of inputs, copies its first file to
// the writable disk of outputs, prints the FNV-1a hash of that file on the
// serial port and the virtio console, and ends with its exit status on
// Build_Exit_Status.
//
// The bytes were assembled by nasm (bits 64, org 0x1000000) from the
// assembly in the comments.
GUEST_PROGRAM_ADDRESS :: u64(0x100_0000)
GUEST_PROGRAM_CONFIGURATION :: u64(0x200_3F00) // One byte: not 0 asks for a write to the read-only disk first.
GUEST_PROGRAM_MEMORY_PAGES :: u64(16_384) // 64 MiB: the least memory of a Linux guest.
GUEST_PROGRAM_INPUT_BYTES_MOST :: 0x1_0000 // The buffer of the program: 128 sectors.
// The steps of the software processor in one run: a bound on the work
// between two exits, which then counts as an exit Interrupted.
SOFTWARE_STEPS_PER_RUN :: u64(100_000)
GUEST_PROGRAM_EXITS_MOST :: 100_000

// The exit status of each failure of the program, in the order of its
// checks: the test names the one that it waits for.
Guest_Program_Status :: enum u32 {
	Built                 = 0,
	No_Zero_Page          = 1,
	Not_Long_Mode         = 2,
	Page_Attribute_Table  = 3,
	Memory_Type_Ranges    = 4,
	Processor_Vendor      = 5,
	Input_Device          = 6,
	Output_Device         = 7,
	Console_Device        = 8,
	Input_Capacity        = 9,
	Read_Only_Not_Refused = 10,
	Input_Read            = 11,
	Input_Not_A_Disk      = 12,
	Input_File_Outside    = 13,
	Output_Write          = 14,
	Console_Write         = 15,
	Clock_Not_Moving      = 16,
}

// The places of the program in the memory of the guest: the queues of the
// input disk, the output disk and the console at 0x200_0000, 0x200_1000 and
// 0x200_2000 (8 descriptors, the available ring at +0x100, the used ring at
// +0x200), the header of a request at 0x200_3000 and its status at
// 0x200_3100, the line of text at 0x200_3200, the configuration byte at
// 0x200_3F00, and the buffers of the input and of the output at 0x201_0000
// and 0x202_0000, 64 KiB each. The windows of the devices are at
// 0xD000_0000 (console), 0xD000_1000 (inputs) and 0xD000_2000 (outputs).
GUEST_PROGRAM := [?]u8{
	// start:
	0x81, 0xBE, 0x02, 0x02, 0x00, 0x00, 0x48, 0x64, 0x72, 0x53, // cmp dword [rsi+0x202], 0x53726448
	0xBF, 0x01, 0x00, 0x00, 0x00, // mov edi, 1
	0x0F, 0x85, 0xCE, 0x02, 0x00, 0x00, // jne fail
	0x48, 0x8D, 0x35, 0x4A, 0x05, 0x00, 0x00, // lea rsi, [rel banner]
	0xE8, 0xCC, 0x02, 0x00, 0x00, // call serial_string
	0xB9, 0x80, 0x00, 0x00, 0xC0, // mov ecx, 0xC0000080
	0x0F, 0x32, // rdmsr
	0xA9, 0x00, 0x04, 0x00, 0x00, // test eax, 0x400
	0xBF, 0x02, 0x00, 0x00, 0x00, // mov edi, 2
	0x0F, 0x84, 0xAB, 0x02, 0x00, 0x00, // jz fail
	0xB9, 0x77, 0x02, 0x00, 0x00, // mov ecx, 0x277
	0x0F, 0x32, // rdmsr
	0x3D, 0x06, 0x04, 0x07, 0x00, // cmp eax, 0x00070406
	0xBF, 0x03, 0x00, 0x00, 0x00, // mov edi, 3
	0x0F, 0x85, 0x94, 0x02, 0x00, 0x00, // jne fail
	0x81, 0xFA, 0x06, 0x04, 0x07, 0x00, // cmp edx, 0x00070406
	0x0F, 0x85, 0x88, 0x02, 0x00, 0x00, // jne fail
	0xB9, 0xFE, 0x00, 0x00, 0x00, // mov ecx, 0xFE
	0x0F, 0x32, // rdmsr
	0x09, 0xD0, // or eax, edx
	0xBF, 0x04, 0x00, 0x00, 0x00, // mov edi, 4
	0x0F, 0x85, 0x74, 0x02, 0x00, 0x00, // jnz fail
	0x31, 0xC0, // xor eax, eax
	0x31, 0xC9, // xor ecx, ecx
	0x0F, 0xA2, // cpuid
	0x81, 0xFB, 0x4D, 0x6F, 0x64, 0x75, // cmp ebx, 0x75646F4D
	0xBF, 0x05, 0x00, 0x00, 0x00, // mov edi, 5
	0x0F, 0x85, 0x5D, 0x02, 0x00, 0x00, // jne fail
	0x0F, 0x31, // rdtsc
	0x48, 0xC1, 0xE2, 0x20, // shl rdx, 32
	0x48, 0x09, 0xD0, // or rax, rdx
	0x49, 0x89, 0xC0, // mov r8, rax
	0x0F, 0x31, // rdtsc
	0x48, 0xC1, 0xE2, 0x20, // shl rdx, 32
	0x48, 0x09, 0xD0, // or rax, rdx
	0x4C, 0x39, 0xC0, // cmp rax, r8
	0xBF, 0x10, 0x00, 0x00, 0x00, // mov edi, 16
	0x0F, 0x86, 0x3A, 0x02, 0x00, 0x00, // jbe fail
	0x0F, 0x09, // wbinvd
	0xBB, 0x00, 0x10, 0x00, 0xD0, // mov ebx, INPUT
	0xBA, 0x00, 0x00, 0x00, 0x02, // mov edx, Q_IN
	0x31, 0xC9, // xor ecx, ecx
	0xE8, 0x89, 0x02, 0x00, 0x00, // call virtio_start
	0xBF, 0x06, 0x00, 0x00, 0x00, // mov edi, 6
	0x85, 0xC0, // test eax, eax
	0x0F, 0x85, 0x1A, 0x02, 0x00, 0x00, // jnz fail
	0xBB, 0x00, 0x20, 0x00, 0xD0, // mov ebx, OUTPUT
	0xBA, 0x00, 0x10, 0x00, 0x02, // mov edx, Q_OUT
	0x31, 0xC9, // xor ecx, ecx
	0xE8, 0x6B, 0x02, 0x00, 0x00, // call virtio_start
	0xBF, 0x07, 0x00, 0x00, 0x00, // mov edi, 7
	0x85, 0xC0, // test eax, eax
	0x0F, 0x85, 0xFC, 0x01, 0x00, 0x00, // jnz fail
	0xBB, 0x00, 0x00, 0x00, 0xD0, // mov ebx, CONSOLE
	0xBA, 0x00, 0x20, 0x00, 0x02, // mov edx, Q_CON
	0xB9, 0x01, 0x00, 0x00, 0x00, // mov ecx, 1
	0xE8, 0x4A, 0x02, 0x00, 0x00, // call virtio_start
	0xBF, 0x08, 0x00, 0x00, 0x00, // mov edi, 8
	0x85, 0xC0, // test eax, eax
	0x0F, 0x85, 0xDB, 0x01, 0x00, 0x00, // jnz fail
	0xBB, 0x00, 0x10, 0x00, 0xD0, // mov ebx, INPUT
	0x44, 0x0F, 0xB7, 0xA3, 0x00, 0x01, 0x00, 0x00, // movzx r12d, word [rbx+0x100]
	0x0F, 0xBE, 0x8B, 0x07, 0x01, 0x00, 0x00, // movsx ecx, byte [rbx+0x107]
	0xBF, 0x09, 0x00, 0x00, 0x00, // mov edi, 9
	0x85, 0xC9, // test ecx, ecx
	0x0F, 0x85, 0xBA, 0x01, 0x00, 0x00, // jnz fail
	0x45, 0x85, 0xE4, // test r12d, r12d
	0x0F, 0x84, 0xB1, 0x01, 0x00, 0x00, // jz fail
	0x41, 0x81, 0xFC, 0x80, 0x00, 0x00, 0x00, // cmp r12d, BUF_BYTES / 512
	0x76, 0x06, // jbe .capacity_fits
	0x41, 0xBC, 0x80, 0x00, 0x00, 0x00, // mov r12d, BUF_BYTES / 512
	// .capacity_fits:
	0xB8, 0x00, 0x3F, 0x00, 0x02, // mov eax, CONFIG
	0x80, 0x38, 0x00, // cmp byte [rax], 0
	0x74, 0x3C, // je .read_inputs
	0xBB, 0x00, 0x10, 0x00, 0xD0, // mov ebx, INPUT
	0xBA, 0x00, 0x00, 0x00, 0x02, // mov edx, Q_IN
	0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
	0x45, 0x31, 0xC0, // xor r8d, r8d
	0x41, 0xB9, 0x00, 0x00, 0x01, 0x02, // mov r9d, BUF
	0x41, 0xBA, 0x00, 0x02, 0x00, 0x00, // mov r10d, 512
	0xE8, 0xC8, 0x02, 0x00, 0x00, // call block_request
	0xBF, 0x0A, 0x00, 0x00, 0x00, // mov edi, 10
	0x3C, 0x01, // cmp al, 1
	0x0F, 0x85, 0x68, 0x01, 0x00, 0x00, // jne fail
	0x48, 0x8D, 0x35, 0xFC, 0x03, 0x00, 0x00, // lea rsi, [rel refused_text]
	0xE8, 0x66, 0x01, 0x00, 0x00, // call serial_string
	// .read_inputs:
	0xBB, 0x00, 0x10, 0x00, 0xD0, // mov ebx, INPUT
	0xBA, 0x00, 0x00, 0x00, 0x02, // mov edx, Q_IN
	0x31, 0xC0, // xor eax, eax
	0x45, 0x31, 0xC0, // xor r8d, r8d
	0x41, 0xB9, 0x00, 0x00, 0x01, 0x02, // mov r9d, BUF
	0x45, 0x89, 0xE2, // mov r10d, r12d
	0x41, 0xC1, 0xE2, 0x09, // shl r10d, 9
	0xE8, 0x8E, 0x02, 0x00, 0x00, // call block_request
	0xBF, 0x0B, 0x00, 0x00, 0x00, // mov edi, 11
	0x84, 0xC0, // test al, al
	0x0F, 0x85, 0x2E, 0x01, 0x00, 0x00, // jnz fail
	0xBE, 0x00, 0x00, 0x01, 0x02, // mov esi, BUF
	0xBF, 0x0C, 0x00, 0x00, 0x00, // mov edi, 12
	0x81, 0x3E, 0x4D, 0x4F, 0x44, 0x47, // cmp dword [rsi], 0x47444F4D
	0x0F, 0x85, 0x18, 0x01, 0x00, 0x00, // jne fail
	0x81, 0x7E, 0x04, 0x42, 0x44, 0x31, 0x01, // cmp dword [rsi+4], 0x01314442
	0x0F, 0x85, 0x0B, 0x01, 0x00, 0x00, // jne fail
	0x83, 0x7E, 0x10, 0x01, // cmp dword [rsi+16], 1
	0x0F, 0x82, 0x01, 0x01, 0x00, 0x00, // jb fail
	0x4C, 0x8B, 0xAE, 0xC0, 0x00, 0x00, 0x00, // mov r13, [rsi+64+128]
	0x4C, 0x8B, 0xB6, 0xC8, 0x00, 0x00, 0x00, // mov r14, [rsi+64+136]
	0xBF, 0x0D, 0x00, 0x00, 0x00, // mov edi, 13
	0x44, 0x89, 0xE0, // mov eax, r12d
	0xC1, 0xE0, 0x09, // shl eax, 9
	0x49, 0x81, 0xFE, 0x00, 0x00, 0x01, 0x00, // cmp r14, BUF_BYTES
	0x0F, 0x87, 0xDB, 0x00, 0x00, 0x00, // ja fail
	0x4D, 0x85, 0xF6, // test r14, r14
	0x0F, 0x84, 0xD2, 0x00, 0x00, 0x00, // jz fail
	0x49, 0x39, 0xC5, // cmp r13, rax
	0x0F, 0x87, 0xC9, 0x00, 0x00, 0x00, // ja fail
	0x48, 0x89, 0xC1, // mov rcx, rax
	0x4C, 0x29, 0xE9, // sub rcx, r13
	0x49, 0x39, 0xCE, // cmp r14, rcx
	0x0F, 0x87, 0xBA, 0x00, 0x00, 0x00, // ja fail
	0xFC, // cld
	0xBF, 0x00, 0x00, 0x02, 0x02, // mov edi, OUTBUF
	0xB9, 0x00, 0x00, 0x01, 0x00, // mov ecx, BUF_BYTES
	0x31, 0xC0, // xor eax, eax
	0xF3, 0xAA, // rep stosb
	0xBF, 0x00, 0x00, 0x02, 0x02, // mov edi, OUTBUF
	0xBE, 0x00, 0x00, 0x01, 0x02, // mov esi, BUF
	0x4C, 0x01, 0xEE, // add rsi, r13
	0x4C, 0x89, 0xF1, // mov rcx, r14
	0xF3, 0xA4, // rep movsb
	0xBE, 0x00, 0x00, 0x02, 0x02, // mov esi, OUTBUF
	0x4C, 0x89, 0xF1, // mov rcx, r14
	0xB8, 0xC5, 0x9D, 0x1C, 0x81, // mov eax, 0x811C9DC5
	// .hash:
	0x0F, 0xB6, 0x16, // movzx edx, byte [rsi]
	0x31, 0xD0, // xor eax, edx
	0x69, 0xC0, 0x93, 0x01, 0x00, 0x01, // imul eax, eax, 0x01000193
	0x48, 0xFF, 0xC6, // inc rsi
	0x48, 0xFF, 0xC9, // dec rcx
	0x75, 0xED, // jnz .hash
	0x41, 0x89, 0xC7, // mov r15d, eax
	0x4D, 0x89, 0xF2, // mov r10, r14
	0x49, 0x81, 0xC2, 0xFF, 0x01, 0x00, 0x00, // add r10, 511
	0x49, 0x81, 0xE2, 0x00, 0xFE, 0xFF, 0xFF, // and r10, -512
	0xBB, 0x00, 0x20, 0x00, 0xD0, // mov ebx, OUTPUT
	0xBA, 0x00, 0x10, 0x00, 0x02, // mov edx, Q_OUT
	0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
	0x45, 0x31, 0xC0, // xor r8d, r8d
	0x41, 0xB9, 0x00, 0x00, 0x02, 0x02, // mov r9d, OUTBUF
	0xE8, 0x9B, 0x01, 0x00, 0x00, // call block_request
	0xBF, 0x0E, 0x00, 0x00, 0x00, // mov edi, 14
	0x84, 0xC0, // test al, al
	0x75, 0x3F, // jnz fail
	0xBF, 0x00, 0x32, 0x00, 0x02, // mov edi, MSG
	0x48, 0x8D, 0x35, 0xEA, 0x02, 0x00, 0x00, // lea rsi, [rel hash_text]
	0xE8, 0x57, 0x00, 0x00, 0x00, // call copy_string
	0x44, 0x89, 0xF8, // mov eax, r15d
	0xE8, 0x61, 0x00, 0x00, 0x00, // call write_hex32
	0xC6, 0x07, 0x0A, // mov byte [rdi], 10
	0xC6, 0x47, 0x01, 0x00, // mov byte [rdi+1], 0
	0xBE, 0x00, 0x32, 0x00, 0x02, // mov esi, MSG
	0xE8, 0x1F, 0x00, 0x00, 0x00, // call serial_string
	0xBE, 0x00, 0x32, 0x00, 0x02, // mov esi, MSG
	0xE8, 0x26, 0x02, 0x00, 0x00, // call console_string
	0xBF, 0x0F, 0x00, 0x00, 0x00, // mov edi, 15
	0x85, 0xC0, // test eax, eax
	0x75, 0x02, // jnz fail
	0x31, 0xFF, // xor edi, edi
	// fail:
	0x89, 0xF8, // mov eax, edi
	0xBA, 0x08, 0x05, 0x00, 0x00, // mov edx, 0x508
	0xEF, // out dx, eax
	0xEB, 0xF6, // jmp fail
	// serial_string:
	0x0F, 0xB6, 0x0E, // movzx ecx, byte [rsi]
	0x85, 0xC9, // test ecx, ecx
	0x74, 0x17, // jz .done
	// .wait:
	0xBA, 0xFD, 0x03, 0x00, 0x00, // mov edx, 0x3FD
	0xEC, // in al, dx
	0xA8, 0x20, // test al, 0x20
	0x74, 0xF6, // jz .wait
	0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
	0x89, 0xC8, // mov eax, ecx
	0xEE, // out dx, al
	0x48, 0xFF, 0xC6, // inc rsi
	0xEB, 0xE2, // jmp serial_string
	// .done:
	0xC3, // ret
	// copy_string:
	0x0F, 0xB6, 0x06, // movzx eax, byte [rsi]
	0x85, 0xC0, // test eax, eax
	0x74, 0x0A, // jz .done
	0x88, 0x07, // mov [rdi], al
	0x48, 0xFF, 0xC6, // inc rsi
	0x48, 0xFF, 0xC7, // inc rdi
	0xEB, 0xEF, // jmp copy_string
	// .done:
	0xC3, // ret
	// write_hex32:
	0x41, 0x89, 0xC0, // mov r8d, eax
	0xB9, 0x1C, 0x00, 0x00, 0x00, // mov ecx, 28
	0x4C, 0x8D, 0x1D, 0x74, 0x02, 0x00, 0x00, // lea r11, [rel hex_digits]
	// .digit:
	0x44, 0x89, 0xC2, // mov edx, r8d
	0xD3, 0xEA, // shr edx, cl
	0x83, 0xE2, 0x0F, // and edx, 0xF
	0x41, 0x0F, 0xB6, 0x14, 0x13, // movzx edx, byte [r11+rdx]
	0x88, 0x17, // mov [rdi], dl
	0x48, 0xFF, 0xC7, // inc rdi
	0x83, 0xE9, 0x04, // sub ecx, 4
	0x79, 0xE9, // jns .digit
	0xC3, // ret
	// virtio_start:
	0x8B, 0x03, // mov eax, [rbx]
	0x3D, 0x76, 0x69, 0x72, 0x74, // cmp eax, 0x74726976
	0x0F, 0x85, 0xDE, 0x00, 0x00, 0x00, // jne .bad
	0x8B, 0x43, 0x04, // mov eax, [rbx+4]
	0x83, 0xF8, 0x02, // cmp eax, 2
	0x0F, 0x85, 0xD2, 0x00, 0x00, 0x00, // jne .bad
	0xC7, 0x43, 0x70, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0x70], 0
	0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
	0x89, 0x43, 0x70, // mov [rbx+0x70], eax
	0xB8, 0x03, 0x00, 0x00, 0x00, // mov eax, 3
	0x89, 0x43, 0x70, // mov [rbx+0x70], eax
	0xC7, 0x43, 0x14, 0x01, 0x00, 0x00, 0x00, // mov dword [rbx+0x14], 1
	0x8B, 0x43, 0x10, // mov eax, [rbx+0x10]
	0xA9, 0x01, 0x00, 0x00, 0x00, // test eax, 1
	0x0F, 0x84, 0xA6, 0x00, 0x00, 0x00, // jz .bad
	0xC7, 0x43, 0x24, 0x01, 0x00, 0x00, 0x00, // mov dword [rbx+0x24], 1
	0xC7, 0x43, 0x20, 0x01, 0x00, 0x00, 0x00, // mov dword [rbx+0x20], 1
	0xC7, 0x43, 0x24, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0x24], 0
	0xC7, 0x43, 0x20, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0x20], 0
	0xB8, 0x0B, 0x00, 0x00, 0x00, // mov eax, 0xB
	0x89, 0x43, 0x70, // mov [rbx+0x70], eax
	0x8B, 0x43, 0x70, // mov eax, [rbx+0x70]
	0xA9, 0x08, 0x00, 0x00, 0x00, // test eax, 8
	0x74, 0x78, // jz .bad
	0x89, 0x4B, 0x30, // mov [rbx+0x30], ecx
	0x8B, 0x43, 0x34, // mov eax, [rbx+0x34]
	0x83, 0xF8, 0x08, // cmp eax, QSIZE
	0x72, 0x6D, // jb .bad
	0xC7, 0x43, 0x38, 0x08, 0x00, 0x00, 0x00, // mov dword [rbx+0x38], QSIZE
	0x57, // push rdi
	0x51, // push rcx
	0x48, 0x89, 0xD7, // mov rdi, rdx
	0xB9, 0x00, 0x03, 0x00, 0x00, // mov ecx, 0x300
	0x31, 0xC0, // xor eax, eax
	0xF3, 0xAA, // rep stosb
	0x59, // pop rcx
	0x5F, // pop rdi
	0x89, 0x93, 0x80, 0x00, 0x00, 0x00, // mov [rbx+0x80], edx
	0xC7, 0x83, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0x84], 0
	0x8D, 0x82, 0x00, 0x01, 0x00, 0x00, // lea eax, [rdx+0x100]
	0x89, 0x83, 0x90, 0x00, 0x00, 0x00, // mov [rbx+0x90], eax
	0xC7, 0x83, 0x94, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0x94], 0
	0x8D, 0x82, 0x00, 0x02, 0x00, 0x00, // lea eax, [rdx+0x200]
	0x89, 0x83, 0xA0, 0x00, 0x00, 0x00, // mov [rbx+0xA0], eax
	0xC7, 0x83, 0xA4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0xA4], 0
	0xC7, 0x43, 0x44, 0x01, 0x00, 0x00, 0x00, // mov dword [rbx+0x44], 1
	0x8B, 0x43, 0x44, // mov eax, [rbx+0x44]
	0x83, 0xF8, 0x01, // cmp eax, 1
	0x75, 0x0B, // jne .bad
	0xB8, 0x0F, 0x00, 0x00, 0x00, // mov eax, 0xF
	0x89, 0x43, 0x70, // mov [rbx+0x70], eax
	0x31, 0xC0, // xor eax, eax
	0xC3, // ret
	// .bad:
	0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
	0xC3, // ret
	// block_request:
	0x41, 0xBB, 0x00, 0x30, 0x00, 0x02, // mov r11d, HDR
	0x41, 0x89, 0x03, // mov [r11], eax
	0x41, 0xC7, 0x43, 0x04, 0x00, 0x00, 0x00, 0x00, // mov dword [r11+4], 0
	0x4D, 0x89, 0x43, 0x08, // mov [r11+8], r8
	0x41, 0xBB, 0x00, 0x31, 0x00, 0x02, // mov r11d, STATUS
	0x41, 0xC6, 0x03, 0xFF, // mov byte [r11], 0xFF
	0x41, 0xBB, 0x00, 0x30, 0x00, 0x02, // mov r11d, HDR
	0x4C, 0x89, 0x1A, // mov [rdx], r11
	0xC7, 0x42, 0x08, 0x10, 0x00, 0x00, 0x00, // mov dword [rdx+8], 16
	0x66, 0xC7, 0x42, 0x0C, 0x01, 0x00, // mov word [rdx+12], 1
	0x66, 0xC7, 0x42, 0x0E, 0x01, 0x00, // mov word [rdx+14], 1
	0x4C, 0x89, 0x4A, 0x10, // mov [rdx+16], r9
	0x44, 0x89, 0x52, 0x18, // mov [rdx+24], r10d
	0x41, 0xBB, 0x01, 0x00, 0x00, 0x00, // mov r11d, 1
	0x85, 0xC0, // test eax, eax
	0x75, 0x06, // jnz .readable
	0x41, 0xBB, 0x03, 0x00, 0x00, 0x00, // mov r11d, 3
	// .readable:
	0x66, 0x44, 0x89, 0x5A, 0x1C, // mov [rdx+28], r11w
	0x66, 0xC7, 0x42, 0x1E, 0x02, 0x00, // mov word [rdx+30], 2
	0x41, 0xBB, 0x00, 0x31, 0x00, 0x02, // mov r11d, STATUS
	0x4C, 0x89, 0x5A, 0x20, // mov [rdx+32], r11
	0xC7, 0x42, 0x28, 0x01, 0x00, 0x00, 0x00, // mov dword [rdx+40], 1
	0x66, 0xC7, 0x42, 0x2C, 0x02, 0x00, // mov word [rdx+44], 2
	0x66, 0xC7, 0x42, 0x2E, 0x00, 0x00, // mov word [rdx+46], 0
	0x0F, 0xB7, 0x82, 0x02, 0x01, 0x00, 0x00, // movzx eax, word [rdx+0x102]
	0x41, 0x89, 0xC3, // mov r11d, eax
	0x83, 0xE0, 0x07, // and eax, QSIZE - 1
	0x66, 0xC7, 0x84, 0x42, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, // mov word [rdx+0x104+rax*2], 0
	0x41, 0xFF, 0xC3, // inc r11d
	0x66, 0x44, 0x89, 0x9A, 0x02, 0x01, 0x00, 0x00, // mov [rdx+0x102], r11w
	0xC7, 0x43, 0x50, 0x00, 0x00, 0x00, 0x00, // mov dword [rbx+0x50], 0
	0x0F, 0xB7, 0x82, 0x02, 0x02, 0x00, 0x00, // movzx eax, word [rdx+0x202]
	0x66, 0x44, 0x39, 0xD8, // cmp ax, r11w
	0x75, 0x11, // jne .bad
	0x8B, 0x43, 0x60, // mov eax, [rbx+0x60]
	0x89, 0x43, 0x64, // mov [rbx+0x64], eax
	0x41, 0xBB, 0x00, 0x31, 0x00, 0x02, // mov r11d, STATUS
	0x41, 0x0F, 0xB6, 0x03, // movzx eax, byte [r11]
	0xC3, // ret
	// .bad:
	0xB8, 0xFE, 0x00, 0x00, 0x00, // mov eax, 0xFE
	0xC3, // ret
	// console_string:
	0x31, 0xC9, // xor ecx, ecx
	// .length:
	0x80, 0x3C, 0x0E, 0x00, // cmp byte [rsi+rcx], 0
	0x74, 0x04, // je .counted
	0xFF, 0xC1, // inc ecx
	0xEB, 0xF6, // jmp .length
	// .counted:
	0xBA, 0x00, 0x20, 0x00, 0x02, // mov edx, Q_CON
	0x48, 0x89, 0x32, // mov [rdx], rsi
	0x89, 0x4A, 0x08, // mov [rdx+8], ecx
	0xC7, 0x42, 0x0C, 0x00, 0x00, 0x00, 0x00, // mov dword [rdx+12], 0
	0x0F, 0xB7, 0x82, 0x02, 0x01, 0x00, 0x00, // movzx eax, word [rdx+0x102]
	0x41, 0x89, 0xC0, // mov r8d, eax
	0x83, 0xE0, 0x07, // and eax, QSIZE - 1
	0x66, 0xC7, 0x84, 0x42, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, // mov word [rdx+0x104+rax*2], 0
	0x41, 0xFF, 0xC0, // inc r8d
	0x66, 0x44, 0x89, 0x82, 0x02, 0x01, 0x00, 0x00, // mov [rdx+0x102], r8w
	0xBB, 0x00, 0x00, 0x00, 0xD0, // mov ebx, CONSOLE
	0xC7, 0x43, 0x50, 0x01, 0x00, 0x00, 0x00, // mov dword [rbx+0x50], 1
	0x0F, 0xB7, 0x82, 0x02, 0x02, 0x00, 0x00, // movzx eax, word [rdx+0x202]
	0x66, 0x44, 0x39, 0xC0, // cmp ax, r8w
	0x75, 0x09, // jne .bad
	0x8B, 0x43, 0x60, // mov eax, [rbx+0x60]
	0x89, 0x43, 0x64, // mov [rbx+0x64], eax
	0x31, 0xC0, // xor eax, eax
	0xC3, // ret
	// .bad:
	0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
	0xC3, // ret
	0x6D, 0x6F, 0x64, 0x75, 0x73, 0x20, 0x67, 0x75, 0x65, 0x73, 0x74, 0x3A, 0x20, 0x6C, 0x6F, 0x6E, // banner: db "modus guest: long mode", 10, 0
	0x67, 0x20, 0x6D, 0x6F, 0x64, 0x65, 0x0A, 0x00,
	0x69, 0x6E, 0x70, 0x75, 0x74, 0x20, 0x64, 0x69, 0x73, 0x6B, 0x20, 0x72, 0x65, 0x66, 0x75, 0x73, // refused_text: db "input disk refused a write", 10, 0
	0x65, 0x64, 0x20, 0x61, 0x20, 0x77, 0x72, 0x69, 0x74, 0x65, 0x0A, 0x00,
	0x66, 0x6E, 0x76, 0x31, 0x61, 0x20, 0x00, // hash_text: db "fnv1a ", 0
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, // hex_digits: db "0123456789abcdef"
}

// The program of the initial archive: it reads the place and the size of
// the initial archive in the zero page (ramdisk_image at 0x218,
// ramdisk_size at 0x21C, their high halves at 0xC0 and 0xC4), checks that
// the archive is below 4 GiB, page aligned, above the program and at least
// one cpio header and its name long, and that it starts with the magic
// "070701" of the cpio newc form. Then it ends with its exit status on
// Build_Exit_Status. Assembled by nasm (bits 64, org 0x1000000) from the
// assembly in the comments.
ARCHIVE_PROGRAM := [?]u8{
	0xBF, 0x01, 0x00, 0x00, 0x00, // mov edi, 1
	0x81, 0xBE, 0x02, 0x02, 0x00, 0x00, 0x48, 0x64, 0x72, 0x53, // cmp dword [rsi+0x202], 0x53726448
	0x75, 0x52, // jne fail
	0x8B, 0x86, 0x18, 0x02, 0x00, 0x00, // mov eax, [rsi+0x218]
	0x8B, 0x8E, 0x1C, 0x02, 0x00, 0x00, // mov ecx, [rsi+0x21C]
	0x8B, 0x96, 0xC0, 0x00, 0x00, 0x00, // mov edx, [rsi+0x0C0]
	0x0B, 0x96, 0xC4, 0x00, 0x00, 0x00, // or edx, [rsi+0x0C4]
	0xBF, 0x02, 0x00, 0x00, 0x00, // mov edi, 2
	0x75, 0x33, // jnz fail
	0xBF, 0x03, 0x00, 0x00, 0x00, // mov edi, 3
	0x83, 0xF9, 0x7C, // cmp ecx, 124
	0x72, 0x29, // jb fail
	0xA9, 0xFF, 0x0F, 0x00, 0x00, // test eax, 0xFFF
	0x75, 0x22, // jnz fail
	0x3D, 0x00, 0x00, 0x00, 0x01, // cmp eax, 0x1000000
	0x72, 0x1B, // jb fail
	0xBF, 0x04, 0x00, 0x00, 0x00, // mov edi, 4
	0x81, 0x38, 0x30, 0x37, 0x30, 0x37, // cmp dword [rax], 0x37303730
	0x75, 0x0E, // jne fail
	0x0F, 0xB7, 0x50, 0x04, // movzx edx, word [rax+4]
	0x81, 0xFA, 0x30, 0x31, 0x00, 0x00, // cmp edx, 0x3130
	0x75, 0x02, // jne fail
	0x31, 0xFF, // xor edi, edi
	// fail:
	0x89, 0xF8, // mov eax, edi
	0xBA, 0x08, 0x05, 0x00, 0x00, // mov edx, 0x508
	0xEF, // out dx, eax
	0xEB, 0xF6, // jmp fail
}

// The exit status of each failure of the program of the initial archive.
Archive_Program_Status :: enum u32 {
	Archive_Read        = 0,
	No_Zero_Page        = 1,
	Archive_Above_4_GiB = 2,
	Archive_Misplaced   = 3,
	Archive_Not_Cpio    = 4,
}

// guest_program_elf writes a program as a vmlinux: an ELF64 file for
// x86-64 with one loaded segment at 16 MiB, whose entry is its first byte.
guest_program_elf :: proc(code: []u8) -> []u8 {
	CODE_OFFSET :: 0x80
	image := make([]u8, CODE_OFFSET + len(code))
	copy(image, []u8{0x7F, 'E', 'L', 'F', 2, 1, 1})
	byte_order.write_u16_little_endian(image, 16, 2) // An executable.
	byte_order.write_u16_little_endian(image, 18, 0x3E) // x86-64.
	byte_order.write_u32_little_endian(image, 20, 1)
	byte_order.write_u64_little_endian(image, 0x18, GUEST_PROGRAM_ADDRESS)
	byte_order.write_u64_little_endian(image, 0x20, 64)
	byte_order.write_u16_little_endian(image, 0x34, 64)
	byte_order.write_u16_little_endian(image, 0x36, 56)
	byte_order.write_u16_little_endian(image, 0x38, 1)
	byte_order.write_u32_little_endian(image, 64, 1) // A loaded segment.
	byte_order.write_u32_little_endian(image, 64 + 4, 5) // Read and execute.
	byte_order.write_u64_little_endian(image, 64 + 0x08, CODE_OFFSET)
	byte_order.write_u64_little_endian(image, 64 + 0x10, GUEST_PROGRAM_ADDRESS)
	byte_order.write_u64_little_endian(image, 64 + 0x18, GUEST_PROGRAM_ADDRESS)
	byte_order.write_u64_little_endian(image, 64 + 0x20, u64(len(code)))
	byte_order.write_u64_little_endian(image, 64 + 0x28, u64(len(code)))
	byte_order.write_u64_little_endian(image, 64 + 0x30, 0x1000)
	copy(image[CODE_OFFSET:], code)
	return image
}

// The software processor of a guest and the memory that it runs in.
Software_Guest :: struct {
	processor: sm.Processor_State,
	memory:    guest_os.Guest_Memory,
}

// software_guest_start gives the software processor the page table of the
// boot, with two changes. The software processor runs at the user
// privilege only, so each entry allows it. The 2 MiB of the windows of the
// devices are not present: the nested page table of a guest has no
// mapping there, so an access makes an exit, as a page fault does here.
software_guest_start :: proc(guest: ^Software_Guest, memory: guest_os.Guest_Memory, registers: op.Guest_Registers) {
	tables := memory.bytes[guest_os.LINUX_PAGE_TABLES_ADDRESS:][:guest_os.LINUX_PAGE_TABLE_PAGES * 4096]
	for offset := 0; offset < len(tables); offset += 8 {
		entry := byte_order.read_u64_little_endian(tables, offset)
		if entry & guest_os.PAGE_ENTRY_PRESENT != 0 {
			byte_order.write_u64_little_endian(tables, offset, entry | sm.PAGE_USER)
		}
	}
	// The directories of each GiB follow the top table and the two tables
	// of the third level.
	windows_directory := guest_os.LINUX_PAGE_TABLES_ADDRESS + 0x3000 + (guest_os.LINUX_VIRTIO_BASE >> 30) * 0x1000
	windows_entry := windows_directory + (guest_os.LINUX_VIRTIO_BASE >> 21 & 0x1FF) * 8
	byte_order.write_u64_little_endian(memory.bytes, int(windows_entry), 0)
	sm.processor_init(&guest.processor, registers.cr3, registers.rip, registers.rsp)
	guest.memory = memory
}

// software_guest_run runs the guest from its record until it does what
// makes a processor of a guest exit, and gives that exit as Guest_Run
// gives it. ok is false for a stop that no exit stands for.
software_guest_run :: proc(guest: ^Software_Guest, registers: ^op.Guest_Registers) -> (exit: guest_os.Machine_Exit, ok: bool) {
	processor := &guest.processor
	processor.registers = {registers.rax, registers.rcx, registers.rdx, registers.rbx, registers.rsp, registers.rbp, registers.rsi, registers.rdi, registers.r8, registers.r9, registers.r10, registers.r11, registers.r12, registers.r13, registers.r14, registers.r15}
	processor.rip = registers.rip
	processor.rflags = registers.rflags
	// The software processor runs cpuid and rdtsc itself, and a processor of
	// a guest exits on them: the adapter looks at each instruction before
	// its step. The program puts no prefix on them.
	outcome := sm.Step_Outcome.Step_Budget_Exhausted
	intercepted: guest_os.Machine_Exit
	steps: for _ in 0 ..< SOFTWARE_STEPS_PER_RUN {
		opcode: [2]u8
		if guest_os.guest_instruction_fetch(guest.memory, registers^, processor.rip, opcode[:]) == 2 && opcode[0] == 0x0F {
			if opcode[1] == 0xA2 {
				intercepted = {kind = .Cpuid, next = processor.rip + 2}
				break steps
			}
			if opcode[1] == 0x31 {
				intercepted = {kind = .Other, code = u64(guest_os.Other_Exit_Code.Time_Stamp_Counter), next = processor.rip + 2}
				break steps
			}
		}
		outcome = sm.processor_step(processor, guest.memory.bytes)
		if outcome != .Running {
			break
		}
	}
	values := processor.registers
	registers.rax, registers.rcx, registers.rdx, registers.rbx = values[0], values[1], values[2], values[3]
	registers.rsp, registers.rbp, registers.rsi, registers.rdi = values[4], values[5], values[6], values[7]
	registers.r8, registers.r9, registers.r10, registers.r11 = values[8], values[9], values[10], values[11]
	registers.r12, registers.r13, registers.r14, registers.r15 = values[12], values[13], values[14], values[15]
	registers.rip = processor.rip
	registers.rflags = processor.rflags
	if intercepted.kind != .None {
		return intercepted, true
	}
	switch outcome {
	case .Syscall, .Breakpoint, .Halted, .Divide_Error, .Simd_Floating_Point:
		return {}, false
	case .Running, .Step_Budget_Exhausted:
		// The bound of one run: the timer of the machine ends it.
		return {kind = .Interrupted}, true
	case .Page_Fault:
		// Inside the memory, a fault is a fault of the program.
		if processor.fault_address < u64(len(guest.memory.bytes)) {
			return {}, false
		}
		access := u64(1)
		if processor.fault_error_code & sm.PAGE_FAULT_WRITE != 0 {
			access |= guest_os.FAULT_ACCESS_WRITE
		}
		if processor.fault_error_code & sm.PAGE_FAULT_INSTRUCTION != 0 {
			access |= guest_os.FAULT_ACCESS_EXECUTE
		}
		return {kind = .Memory, a = processor.fault_address, b = access}, true
	case .General_Protection, .Invalid_Opcode:
		return software_guest_intercept(guest, registers^)
	}
	return {}, false
}

// The extraction of a tree: its own workspace and buffer for each test,
// because the tests run on several threads and the ones of the module are
// shared.
Tree_Extraction :: struct {
	workspace: contract.Disk_Unpack_Workspace,
	tree:      [TREE_OUTPUT_BYTES_MOST]u8,
}

// software_guest_intercept gives the exit of an instruction that the
// processor of a guest intercepts and the software processor refuses at
// the user privilege: in and out, hlt, cpuid, rdmsr, wrmsr and wbinvd.
software_guest_intercept :: proc(guest: ^Software_Guest, registers: op.Guest_Registers) -> (exit: guest_os.Machine_Exit, ok: bool) {
	bytes: [3]u8
	count := guest_os.guest_instruction_fetch(guest.memory, registers, registers.rip, bytes[:])
	at := 0
	operand_16 := false
	if count > 0 && bytes[0] == 0x66 {
		operand_16 = true
		at = 1
	}
	if at >= count {
		return {}, false
	}
	switch bytes[at] {
	case 0xE4, 0xE5, 0xE6, 0xE7, 0xEC, 0xED, 0xEE, 0xEF:
		opcode := bytes[at]
		size := u64(1)
		if opcode & 1 != 0 {
			size = operand_16 ? 2 : 4
		}
		port := registers.rdx & 0xFFFF
		length := u64(at + 1)
		if opcode < 0xEC {
			if at + 1 >= count {
				return {}, false
			}
			port = u64(bytes[at + 1])
			length += 1
		}
		kind := opcode & 2 == 0 ? op.Guest_Exit_Kind.Port_Read : op.Guest_Exit_Kind.Port_Write
		return {kind = kind, a = port, b = size, c = registers.rax & guest_os.size_mask(u8(size)), next = registers.rip + length}, true
	case 0xF4:
		return {kind = .Halt, next = registers.rip + u64(at) + 1}, true
	case 0x0F:
		if at != 0 || count < 2 {
			return {}, false
		}
		switch bytes[1] {
		case 0xA2:
			return {kind = .Cpuid, next = registers.rip + 2}, true
		case 0x32, 0x30:
			return {kind = .Other, code = u64(guest_os.Other_Exit_Code.Model_Specific_Register), information = bytes[1] == 0x30 ? 1 : 0, next = registers.rip + 2}, true
		case 0x09:
			return {kind = .Other, code = u64(guest_os.Other_Exit_Code.Write_Back_Invalidate)}, true
		}
	}
	return {}, false
}

// One build of the program: its runner, its machine, its disks.
Guest_Program_Build :: struct {
	runner:      contract.Guest_Sandbox_Runner,
	machine:     guest_os.Linux_Machine,
	software:    Software_Guest,
	memory:      []u8,
	input_disk:  []u8,
	output_disk: []u8,
	registers:   op.Guest_Registers,
	exits:       int,
	stopped:     bool, // The adapter met a stop that no exit stands for.
}

// guest_program_input_disk packs the read-only disk of inputs: one file,
// result.img, whose bytes the program copies to the output disk. The disk
// ends on a whole sector, as a block device has whole sectors.
guest_program_input_disk :: proc(content: []u8) -> []u8 {
	files := [1]contract.Disk_File_Input{{path = "result.img", content = content}}
	required, _ := contract.disk_image_required_size(files[:])
	disk := make([]u8, (required + 511) &~ 511)
	_, refusal := contract.pack_input_disk(files[:], 0, disk)
	assert(refusal == .None)
	return disk
}

// guest_program_spec gives the spec of a build of the program code.
guest_program_spec :: proc(code: []u8, output_bound: u64) -> (spec: contract.Guest_Build_Spec) {
	kernel := guest_program_elf(code)
	defer delete(kernel)
	spec.kernel_hash = blake3.hash(kernel)
	spec.root_image_hash = blake3.hash([]u8{2})
	spec.memory_pages = GUEST_PROGRAM_MEMORY_PAGES
	spec.output_size_bound = output_bound
	contract.build_spec_set_command(&spec, "build")
	return spec
}

// program_build_start prepares a build of the program code up to its first
// run, in the order of build: the initial archive at its place and checked
// there, then the runner, the machine and the boot. A refused archive
// returns before the runner starts, so no instruction of the guest runs.
program_build_start :: proc(build: ^Guest_Program_Build, code: []u8, spec: ^contract.Guest_Build_Spec, archive: []u8, input_disk: []u8) -> contract.Guest_Builder_Refusal {
	kernel := guest_program_elf(code)
	defer delete(kernel)
	build.memory = make([]u8, spec.memory_pages * 4096)
	build.input_disk = input_disk
	build.output_disk = make([]u8, spec.output_size_bound)
	parsed, parse_refusal := guest_os.linux_image_parse(kernel, u64(len(build.memory)))
	assert(parse_refusal == .None && parsed.kind == .Elf)
	staged, archive_refusal := initial_archive_stage(build.memory, parsed, u64(len(build.memory)), spec, raw_data(archive), u64(len(archive)))
	if archive_refusal != .None {
		return archive_refusal
	}
	assert(contract.runner_prepare(&build.runner, spec, nil, build.input_disk, build.output_disk) == .None)
	assert(contract.runner_start(&build.runner) == .None)
	memory := guest_os.Guest_Memory{build.memory}
	guest_os.linux_machine_start(&build.machine, memory, build.input_disk, build.output_disk)
	places := guest_os.linux_machine_places()
	boot_refusal: guest_os.Linux_Boot_Refusal
	build.registers, boot_refusal = guest_os.linux_boot_prepare(memory, kernel, parsed, places[:], spec.command[:spec.command_length], staged, u64(len(build.memory)))
	assert(boot_refusal == .None)
	software_guest_start(&build.software, memory, build.registers)
	return .None
}

// guest_program_build_start prepares a build of the program on an input
// disk, up to the first run.
guest_program_build_start :: proc(build: ^Guest_Program_Build, input_disk: []u8, output_bound: u64, write_read_only_disk: bool) {
	spec := guest_program_spec(GUEST_PROGRAM[:], output_bound)
	assert(program_build_start(build, GUEST_PROGRAM[:], &spec, nil, input_disk) == .None)
	build.memory[GUEST_PROGRAM_CONFIGURATION] = write_read_only_disk ? 1 : 0
}

guest_program_build_end :: proc(build: ^Guest_Program_Build) {
	delete(build.memory)
	delete(build.input_disk)
	delete(build.output_disk)
	free(build)
}

// guest_program_build_run runs the loop of the builder until it ends.
guest_program_build_run :: proc(t: ^testing.T, build: ^Guest_Program_Build) {
	reported := u64(0)
	for build.exits < GUEST_PROGRAM_EXITS_MOST {
		exit, ok := software_guest_run(&build.software, &build.registers)
		if !ok {
			build.stopped = true
			testing.expectf(t, false, "the program stopped at %x with %v", build.registers.rip, build.software.processor.outcome)
			return
		}
		build.exits += 1
		action := build_exit_handle(&build.runner, &build.machine, &build.registers, exit, &reported)
		testing.expectf(t, build.registers.inject_kind == 0, "no event for the program after %v", exit)
		switch action {
		case .Run_Again:
		case .Switch_Write, .Switch_Execute:
			testing.expectf(t, false, "a switch of a region in the software processor: %v", exit)
			return
		case .End:
			return
		}
	}
	testing.expectf(t, false, "the program did not end in %v exits", GUEST_PROGRAM_EXITS_MOST)
}

// fnv_1a_32 is the hash that the program prints.
fnv_1a_32 :: proc(bytes: []u8) -> u32 {
	hash := u32(0x811C_9DC5)
	for value in bytes {
		hash = (hash ~ u32(value)) * 0x0100_0193
	}
	return hash
}

// The output disk that the program copies: a canonical MODGBD1 disk of
// two files, which the builder extracts into its tree.
guest_program_output_image :: proc() -> []u8 {
	files := [2]contract.Disk_File_Input{{path = "bin/hello", content = transmute([]u8)string("#!/bin/sh\necho built in a guest\n")}, {path = "share/doc/hello.txt", content = transmute([]u8)string("The output of a build in a guest of 64 bits.\n")}}
	required, _ := contract.disk_image_required_size(files[:])
	image := make([]u8, required)
	_, refusal := contract.pack_disk_image(.Output_Writable, files[:], 0, image)
	assert(refusal == .None)
	return image
}

// The build from end to end: the program reads the input disk, writes the
// output disk, prints its hash on both consoles and exits with 0; the
// builder extracts the tree, and the hashes are the ones of the disk that
// the host packed. No model-specific register faulted, the input disk did
// not change, and no write reached it.
@(test)
guest_program_builds_from_input_to_output :: proc(t: ^testing.T) {
	OUTPUT_BOUND :: u64(64 * 1024)
	image := guest_program_output_image()
	defer delete(image)
	build := new(Guest_Program_Build)
	defer guest_program_build_end(build)
	extraction := new(Tree_Extraction)
	defer free(extraction)
	guest_program_build_start(build, guest_program_input_disk(image), OUTPUT_BOUND, false)
	input_hash := blake3.hash(build.input_disk)
	guest_program_build_run(t, build)
	testing.expect_value(t, build.runner.guest_exit_code, u32(Guest_Program_Status.Built))
	testing.expect(t, build.runner.guest_exited && build.runner.sandbox_violations == 0)
	testing.expect_value(t, build.machine.failure, guest_os.Machine_Failure.None)
	testing.expect_value(t, build.machine.faults_injected, u64(0))
	testing.expect_value(t, build.machine.devices[.Input_Disk].writes_refused, u64(0))
	testing.expect_value(t, build.machine.devices[.Input_Disk].malformed_chains + build.machine.devices[.Output_Disk].malformed_chains + build.machine.devices[.Console].malformed_chains, u64(0))
	testing.expect_value(t, blake3.hash(build.input_disk), input_hash)
	// The output disk: the packed image, then zeros to its bound.
	expected_disk := make([]u8, OUTPUT_BOUND)
	defer delete(expected_disk)
	copy(expected_disk, image)
	testing.expect(t, string(build.output_disk) == string(expected_disk))
	testing.expect_value(t, blake3.hash(build.output_disk), blake3.hash(expected_disk))
	// Both consoles carry the line of the hash, which the host computes.
	hash_text: [8]u8
	hash := fnv_1a_32(image)
	digits := "0123456789abcdef"
	for index in 0 ..< 8 {
		hash_text[index] = digits[hash >> u32(28 - index * 4) & 0xF]
	}
	line := strings.concatenate({"fnv1a ", string(hash_text[:]), "\n"}, context.temp_allocator)
	serial := string(build.machine.serial.capture[:build.machine.serial.captured])
	console := string(build.machine.devices[.Console].console[:build.machine.devices[.Console].console_length])
	testing.expect_value(t, serial, strings.concatenate({"modus guest: long mode\n", line}, context.temp_allocator))
	testing.expect_value(t, console, line)
	// The builder extracts the tree; its hash is the hash of the tree of the
	// packed image, which an independent extraction of the host gives.
	tree_hash, written, refusal := contract.runner_finish(&build.runner, &extraction.workspace, extraction.tree[:])
	testing.expect_value(t, refusal, contract.Guest_Builder_Refusal.None)
	testing.expect_value(t, build.runner.state, contract.Guest_Build_State.Succeeded)
	host_workspace := new(contract.Disk_Unpack_Workspace)
	defer free(host_workspace)
	host_tree: [TREE_OUTPUT_BYTES_MOST]u8
	host_written, host_hash, host_refusal := contract.unpack_output_disk(expected_disk, OUTPUT_BOUND, host_workspace, host_tree[:])
	testing.expect_value(t, host_refusal, contract.Guest_Builder_Refusal.None)
	testing.expect(t, written == host_written && written > 0)
	testing.expect_value(t, tree_hash, host_hash)
	testing.expect_value(t, build.runner.output_tree_hash, host_hash)
	testing.expect(t, string(extraction.tree[:written]) == string(host_tree[:host_written]))
	testing.expect(t, build.exits > 100)
}

// A write to the read-only disk: the device refuses it with IOERR and
// changes no byte, and the guest sees the status. The machine alone runs
// the program here, so the guest goes on and still builds; the builder
// itself ends the build at the first refused write (the next test).
@(test)
guest_program_sees_the_refused_write :: proc(t: ^testing.T) {
	image := guest_program_output_image()
	defer delete(image)
	build := new(Guest_Program_Build)
	defer guest_program_build_end(build)
	guest_program_build_start(build, guest_program_input_disk(image), 64 * 1024, true)
	input_hash := blake3.hash(build.input_disk)
	exit_status := max(u64)
	run: for build.exits < GUEST_PROGRAM_EXITS_MOST {
		exit, ok := software_guest_run(&build.software, &build.registers)
		if !testing.expectf(t, ok, "the program stopped at %x", build.registers.rip) {
			return
		}
		build.exits += 1
		switch guest_os.linux_machine_handle_exit(&build.machine, &build.registers, exit) {
		case .Continue:
		case .Not_Handled:
			if exit.kind == .Port_Write && exit.a == u64(contract.Guest_Io_Port.Build_Exit_Status) {
				exit_status = exit.c
				break run
			}
			testing.expectf(t, false, "a port that the program does not use: %v", exit)
			return
		case .Switch_Write, .Switch_Execute, .Halted, .Failed:
			testing.expectf(t, false, "the machine stopped the program: %v", build.machine.failure)
			return
		}
	}
	testing.expect_value(t, exit_status, u64(Guest_Program_Status.Built))
	testing.expect_value(t, build.machine.devices[.Input_Disk].writes_refused, u64(1))
	testing.expect_value(t, blake3.hash(build.input_disk), input_hash)
	serial := string(build.machine.serial.capture[:build.machine.serial.captured])
	testing.expect(t, strings.contains(serial, "input disk refused a write\n"))
}

// The builder ends the build at the first write to the read-only disk: a
// violation of the sandbox, no tree, and no byte of the input changed.
@(test)
guest_program_write_to_inputs_refuses_the_build :: proc(t: ^testing.T) {
	image := guest_program_output_image()
	defer delete(image)
	build := new(Guest_Program_Build)
	defer guest_program_build_end(build)
	extraction := new(Tree_Extraction)
	defer free(extraction)
	guest_program_build_start(build, guest_program_input_disk(image), 64 * 1024, true)
	input_hash := blake3.hash(build.input_disk)
	guest_program_build_run(t, build)
	testing.expect(t, !build.stopped && !build.runner.guest_exited)
	testing.expect_value(t, build.runner.sandbox_violations, u64(1))
	testing.expect_value(t, build.runner.state, contract.Guest_Build_State.Refused)
	tree_hash, written, refusal := contract.runner_finish(&build.runner, &extraction.workspace, extraction.tree[:])
	testing.expect_value(t, refusal, contract.Guest_Builder_Refusal.Writable_Input_Forbidden)
	testing.expect(t, written == 0 && tree_hash == {})
	testing.expect_value(t, blake3.hash(build.input_disk), input_hash)
}

// The guest ends with 0 but its output disk is no disk: the builder gives
// no tree. And a first file that the input disk does not hold whole makes
// the program fail with its own status.
@(test)
guest_program_output_refusals :: proc(t: ^testing.T) {
	garbage := make([]u8, 700)
	defer delete(garbage)
	for &value, index in garbage {
		value = u8(index * 31 + 7)
	}
	build := new(Guest_Program_Build)
	defer guest_program_build_end(build)
	extraction := new(Tree_Extraction)
	defer free(extraction)
	guest_program_build_start(build, guest_program_input_disk(garbage), 64 * 1024, false)
	guest_program_build_run(t, build)
	testing.expect_value(t, build.runner.guest_exit_code, u32(Guest_Program_Status.Built))
	_, written, refusal := contract.runner_finish(&build.runner, &extraction.workspace, extraction.tree[:])
	testing.expect(t, refusal != .None && written == 0)
	testing.expect(t, build.runner.state != .Succeeded)

	// A file past the buffer of the program: it refuses it and exits with
	// its status; the builder gives no tree.
	large := make([]u8, GUEST_PROGRAM_INPUT_BYTES_MOST)
	defer delete(large)
	second := new(Guest_Program_Build)
	defer guest_program_build_end(second)
	guest_program_build_start(second, guest_program_input_disk(large), 64 * 1024, false)
	guest_program_build_run(t, second)
	testing.expect_value(t, second.runner.guest_exit_code, u32(Guest_Program_Status.Input_File_Outside))
	_, written, refusal = contract.runner_finish(&second.runner, &extraction.workspace, extraction.tree[:])
	testing.expect(t, refusal == .Nonzero_Guest_Exit && written == 0)
}

// cpio_newc_entry appends one entry of the cpio newc form to archive: the
// magic 070701, thirteen fields of eight hexadecimal digits, the name with
// its null byte, then the content, each padded to 4 bytes.
cpio_newc_entry :: proc(archive: ^[dynamic]u8, name: string, mode: u32, content: []u8) {
	digits := "0123456789ABCDEF"
	fields := [13]u32{1, mode, 0, 0, 1, 0, u32(len(content)), 0, 0, 0, 0, u32(len(name) + 1), 0}
	append(archive, "070701")
	for field in fields {
		for shift := 28; shift >= 0; shift -= 4 {
			append(archive, digits[field >> u32(shift) & 0xF])
		}
	}
	append(archive, name)
	append(archive, 0)
	for len(archive) % 4 != 0 {
		append(archive, 0)
	}
	append(archive, ..content)
	for len(archive) % 4 != 0 {
		append(archive, 0)
	}
}

// cpio_newc_archive gives a real initial archive: an init program and the
// trailer that ends the archive.
cpio_newc_archive :: proc() -> []u8 {
	archive: [dynamic]u8
	cpio_newc_entry(&archive, "init", 0o100755, transmute([]u8)string("#!/bin/sh\nexec /bin/build\n"))
	cpio_newc_entry(&archive, "TRAILER!!!", 0, nil)
	return archive[:]
}

// The initial archive from end to end: the spec names a real cpio newc
// archive by its hash, the builder copies it to its place in the memory of
// the guest and checks it there, the boot names it in the zero page, and
// the program of 64 bits finds it there with the magic of cpio and exits
// with 0.
@(test)
guest_program_reads_its_initial_archive :: proc(t: ^testing.T) {
	archive := cpio_newc_archive()
	defer delete(archive)
	spec := guest_program_spec(ARCHIVE_PROGRAM[:], 4096)
	testing.expect_value(t, contract.build_spec_set_initial_archive(&spec, archive), contract.Guest_Builder_Refusal.None)
	testing.expect_value(t, contract.validate_build_spec(&spec), contract.Guest_Builder_Refusal.None)
	build := new(Guest_Program_Build)
	defer guest_program_build_end(build)
	testing.expect_value(t, program_build_start(build, ARCHIVE_PROGRAM[:], &spec, archive, nil), contract.Guest_Builder_Refusal.None)
	page := build.memory[guest_os.LINUX_ZERO_PAGE_ADDRESS:][:guest_os.ZERO_PAGE_BYTES]
	address := u64(byte_order.read_u32_little_endian(page, guest_os.SETUP_RAMDISK_ADDRESS)) | u64(byte_order.read_u32_little_endian(page, guest_os.ZERO_PAGE_EXTENDED_RAMDISK_ADDRESS)) << 32
	size := u64(byte_order.read_u32_little_endian(page, guest_os.SETUP_RAMDISK_SIZE)) | u64(byte_order.read_u32_little_endian(page, guest_os.ZERO_PAGE_EXTENDED_RAMDISK_SIZE)) << 32
	testing.expect_value(t, size, u64(len(archive)))
	testing.expect(t, address % 4096 == 0 && address >= GUEST_PROGRAM_ADDRESS && address + size <= u64(len(build.memory)))
	testing.expect_value(t, blake3.hash(build.memory[address:][:size]), spec.initial_archive_hash)
	guest_program_build_run(t, build)
	testing.expect(t, build.runner.guest_exited)
	testing.expect_value(t, build.runner.guest_exit_code, u32(Archive_Program_Status.Archive_Read))
	testing.expect_value(t, build.machine.failure, guest_os.Machine_Failure.None)
}

// expect_no_archive_bytes checks that a refused archive left no byte in the
// memory of the guest, and that the runner never started: no instruction of
// the guest ran.
expect_no_archive_bytes :: proc(t: ^testing.T, build: ^Guest_Program_Build) {
	for value in build.memory {
		if value != 0 {
			testing.expect(t, false, "a refused archive left a byte in the memory of the guest")
			return
		}
	}
	testing.expect_value(t, build.runner.state, contract.Guest_Build_State(0))
	testing.expect_value(t, build.exits, 0)
}

// Each refusal of the initial archive, before any byte of the guest runs:
// bytes that are not the bytes of the hash, a count that is not the size of
// the spec, a size past the bound, an archive that leaves no room for the
// kernel, bytes with no hash in the spec. An empty archive with no hash
// boots as before.
@(test)
guest_program_initial_archive_refusals :: proc(t: ^testing.T) {
	archive := cpio_newc_archive()
	defer delete(archive)
	signed := guest_program_spec(ARCHIVE_PROGRAM[:], 4096)
	assert(contract.build_spec_set_initial_archive(&signed, archive) == .None)

	// A tampered byte: the hash of the copy is not the hash of the spec.
	{
		tampered := make([]u8, len(archive))
		defer delete(tampered)
		copy(tampered, archive)
		tampered[len(tampered) - 1] ~= 0x01
		spec := signed
		build := new(Guest_Program_Build)
		defer guest_program_build_end(build)
		testing.expect_value(t, program_build_start(build, ARCHIVE_PROGRAM[:], &spec, tampered, nil), contract.Guest_Builder_Refusal.Initial_Archive_Mismatch)
		expect_no_archive_bytes(t, build)
	}
	// One byte fewer and one byte more than the size of the spec.
	for count in ([]int{len(archive) - 1, len(archive) + 1, 0}) {
		longer := make([]u8, len(archive) + 1)
		defer delete(longer)
		copy(longer, archive)
		spec := signed
		build := new(Guest_Program_Build)
		defer guest_program_build_end(build)
		testing.expect_value(t, program_build_start(build, ARCHIVE_PROGRAM[:], &spec, longer[:count], nil), contract.Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
		expect_no_archive_bytes(t, build)
	}
	// A count past the bound, whatever the spec says: refused before a copy.
	{
		spec := signed
		build := new(Guest_Program_Build)
		defer guest_program_build_end(build)
		build.memory = make([]u8, spec.memory_pages * 4096)
		kernel := guest_program_elf(ARCHIVE_PROGRAM[:])
		defer delete(kernel)
		parsed, _ := guest_os.linux_image_parse(kernel, u64(len(build.memory)))
		staged, refusal := initial_archive_stage(build.memory, parsed, u64(len(build.memory)), &spec, raw_data(archive), contract.MAX_INITIAL_ARCHIVE_BYTES + 1)
		testing.expect_value(t, refusal, contract.Guest_Builder_Refusal.Initial_Archive_Too_Large)
		testing.expect(t, staged == nil)
		_, refusal = initial_archive_stage(build.memory, parsed, u64(len(build.memory)), &spec, raw_data(archive), max(u64))
		testing.expect_value(t, refusal, contract.Guest_Builder_Refusal.Initial_Archive_Too_Large)
		expect_no_archive_bytes(t, build)
	}
	// An archive under the bound and under the memory, but with no room
	// above the program: 60 MiB in 64 MiB, with the program at 16 MiB.
	{
		large := make([]u8, 60 * 1024 * 1024)
		defer delete(large)
		copy(large, archive)
		spec := guest_program_spec(ARCHIVE_PROGRAM[:], 4096)
		testing.expect_value(t, contract.build_spec_set_initial_archive(&spec, large), contract.Guest_Builder_Refusal.None)
		testing.expect_value(t, contract.validate_build_spec(&spec), contract.Guest_Builder_Refusal.None)
		build := new(Guest_Program_Build)
		defer guest_program_build_end(build)
		testing.expect_value(t, program_build_start(build, ARCHIVE_PROGRAM[:], &spec, large, nil), contract.Guest_Builder_Refusal.Initial_Archive_Too_Large)
		expect_no_archive_bytes(t, build)
	}
	// Bytes that the spec does not name, and a size with no hash.
	{
		spec := guest_program_spec(ARCHIVE_PROGRAM[:], 4096)
		build := new(Guest_Program_Build)
		defer guest_program_build_end(build)
		testing.expect_value(t, program_build_start(build, ARCHIVE_PROGRAM[:], &spec, archive, nil), contract.Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
		expect_no_archive_bytes(t, build)
		spec.initial_archive_size = u64(len(archive))
		second := new(Guest_Program_Build)
		defer guest_program_build_end(second)
		testing.expect_value(t, program_build_start(second, ARCHIVE_PROGRAM[:], &spec, nil, nil), contract.Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
		expect_no_archive_bytes(t, second)
	}
	// No hash and no bytes: the boot names no archive, and the program sees
	// none and exits with its status.
	{
		spec := guest_program_spec(ARCHIVE_PROGRAM[:], 4096)
		build := new(Guest_Program_Build)
		defer guest_program_build_end(build)
		testing.expect_value(t, program_build_start(build, ARCHIVE_PROGRAM[:], &spec, nil, nil), contract.Guest_Builder_Refusal.None)
		page := build.memory[guest_os.LINUX_ZERO_PAGE_ADDRESS:][:guest_os.ZERO_PAGE_BYTES]
		testing.expect_value(t, byte_order.read_u32_little_endian(page, guest_os.SETUP_RAMDISK_SIZE), u32(0))
		guest_program_build_run(t, build)
		testing.expect_value(t, build.runner.guest_exit_code, u32(Archive_Program_Status.Archive_Misplaced))
	}
}
