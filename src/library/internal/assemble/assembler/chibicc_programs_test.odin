#+build !freestanding
package assembler

import module "modus:contract/module"
import writer "modus:contract/module_file_writer"
import "core:mem/virtual"
import "core:testing"

// Verbatim assembly emitted by the patched chibicc of modus for:
//
//   int fact(int n) {
//     int r = 1;
//     for (int i = 2; i <= n; i = i + 1) r = r * i;
//     return r;
//   }
//   int fib(int n) {
//     if (n <= 1) return n;
//     return fib(n - 1) + fib(n - 2);
//   }
//   int sdiv(int a, int b) { return (a / b) * 100 + (a % b); }
//   long div64(long a, long b) {
//     unsigned long ua = (unsigned long)a, ub = (unsigned long)b;
//     return (a / b) + (a % b) + (long)(ua / ub) + (long)(ua % ub);
//   }
//   int bits(int a, int b) {
//     unsigned int ua = (unsigned int)a, ub = (unsigned int)b;
//     int c = (a == b) + (a != b) * 2 + (a < b) * 4 + (a <= b) * 8 + (ua < ub) * 16 + (ua <= ub) * 32;
//     int v = ((a & b) ^ (~b)) | ((a << (b & 3)) + (a >> (b & 3)) + (int)(ua >> (b & 3)));
//     return c + v + (-a) + (!a);
//   }
//   static int mix6(signed char a, unsigned char b, short c, unsigned short d, int e, long f) {
//     return a + b * 2 + c * 3 + d * 4 + e * 5 + (int)f * 6;
//   }
//   int small(int x) {
//     signed char sc[2] = {-10, 20};
//     unsigned char uc[2] = {200, 50};
//     short ss[2] = {-300, 400};
//     unsigned short us[2] = {50000, 100};
//     sc[0] = (signed char)x;
//     return mix6(sc[0], uc[0], ss[0], us[0], sc[1] + ss[1], uc[1] + us[1]);
//   }
@(private = "file")
CHIBICC_SUITE :: `section data
.L..15:
  byte 115
  byte 109
  byte 97
  byte 108
  byte 108
  byte 0
section data
.L..14:
  byte 115
  byte 109
  byte 97
  byte 108
  byte 108
  byte 0
section data
.L..13:
  byte 109
  byte 105
  byte 120
  byte 54
  byte 0
section data
.L..12:
  byte 109
  byte 105
  byte 120
  byte 54
  byte 0
section data
.L..11:
  byte 98
  byte 105
  byte 116
  byte 115
  byte 0
section data
.L..10:
  byte 98
  byte 105
  byte 116
  byte 115
  byte 0
section data
.L..9:
  byte 100
  byte 105
  byte 118
  byte 54
  byte 52
  byte 0
section data
.L..8:
  byte 100
  byte 105
  byte 118
  byte 54
  byte 52
  byte 0
section data
.L..7:
  byte 115
  byte 100
  byte 105
  byte 118
  byte 0
section data
.L..6:
  byte 115
  byte 100
  byte 105
  byte 118
  byte 0
section data
.L..5:
  byte 102
  byte 105
  byte 98
  byte 0
section data
.L..4:
  byte 102
  byte 105
  byte 98
  byte 0
section data
.L..1:
  byte 102
  byte 97
  byte 99
  byte 116
  byte 0
section data
.L..0:
  byte 102
  byte 97
  byte 99
  byte 116
  byte 0
section code
export small(x: Integer) -> Integer
small:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -24(%rbp)
  mov %edi, -28(%rbp)
  mov $2, %rcx
  lea -12(%rbp), %rdi
  mov $0, %al
  rep stosb
  mov $1, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -12(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $10, %rax
  neg %rax
  movsbl %al, %eax
  pop %rdi
  mov %al, (%rdi)
  mov $1, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -12(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $20, %rax
  movsbl %al, %eax
  pop %rdi
  mov %al, (%rdi)
  mov $2, %rcx
  lea -10(%rbp), %rdi
  mov $0, %al
  rep stosb
  mov $1, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -10(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $200, %rax
  movzbl %al, %eax
  pop %rdi
  mov %al, (%rdi)
  mov $1, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -10(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $50, %rax
  movzbl %al, %eax
  pop %rdi
  mov %al, (%rdi)
  mov $4, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  mov $2, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -8(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $300, %rax
  neg %rax
  movswl %ax, %eax
  pop %rdi
  mov %ax, (%rdi)
  mov $2, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -8(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $400, %rax
  movswl %ax, %eax
  pop %rdi
  mov %ax, (%rdi)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  mov $2, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -4(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $50000, %rax
  movzwl %ax, %eax
  pop %rdi
  mov %ax, (%rdi)
  mov $2, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -4(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  mov $100, %rax
  movzwl %ax, %eax
  pop %rdi
  mov %ax, (%rdi)
  mov $1, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -12(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  movsbl %al, %eax
  pop %rdi
  mov %al, (%rdi)
  mov $2, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -4(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movzwl (%rax), %eax
  push %rax
  mov $1, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -10(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movzbl (%rax), %eax
  pop %rdi
  add %edi, %eax
  movsxd %eax, %rax
  push %rax
  mov $2, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -8(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movswl (%rax), %eax
  push %rax
  mov $1, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -12(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movsbl (%rax), %eax
  pop %rdi
  add %edi, %eax
  push %rax
  mov $2, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -4(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movzwl (%rax), %eax
  push %rax
  mov $2, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -8(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movswl (%rax), %eax
  push %rax
  mov $1, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -10(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movzbl (%rax), %eax
  push %rax
  mov $1, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea -12(%rbp), %rax
  pop %rdi
  add %rdi, %rax
  movsbl (%rax), %eax
  push %rax
  lea mix6(%rip), %rax
  pop %rdi
  pop %rsi
  pop %rdx
  pop %rcx
  pop %r8
  pop %r9
  mov %rax, %r10
  mov $0, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.small
.L.return.small:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
mix6:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -8(%rbp)
  mov %dil, -9(%rbp)
  mov %sil, -10(%rbp)
  mov %dx, -12(%rbp)
  mov %cx, -14(%rbp)
  mov %r8d, -20(%rbp)
  mov %r9, -32(%rbp)
  mov $6, %rax
  push %rax
  lea -32(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $5, %rax
  push %rax
  lea -20(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $4, %rax
  push %rax
  lea -14(%rbp), %rax
  movzwl (%rax), %eax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $3, %rax
  push %rax
  lea -12(%rbp), %rax
  movswl (%rax), %eax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $2, %rax
  push %rax
  lea -10(%rbp), %rax
  movzbl (%rax), %eax
  pop %rdi
  imul %edi, %eax
  push %rax
  lea -9(%rbp), %rax
  movsbl (%rax), %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  jmp .L.return.mix6
.L.return.mix6:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export bits(a: Integer, b: Integer) -> Integer
bits:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -24(%rbp)
  mov %edi, -28(%rbp)
  mov %esi, -32(%rbp)
  mov $4, %rcx
  lea -16(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -16(%rbp), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  mov %eax, (%rdi)
  mov $4, %rcx
  lea -12(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -12(%rbp), %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  mov %eax, (%rdi)
  mov $4, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  mov $32, %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setbe %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $16, %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setb %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $8, %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setle %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $4, %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setl %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $2, %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setne %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  sete %al
  movzb %al, %rax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  mov %eax, (%rdi)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -4(%rbp), %rax
  push %rax
  mov $3, %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  and %edi, %eax
  push %rax
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  mov %rdi, %rcx
  shr %cl, %eax
  push %rax
  mov $3, %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  and %edi, %eax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  mov %rdi, %rcx
  sar %cl, %eax
  push %rax
  mov $3, %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  and %edi, %eax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  mov %rdi, %rcx
  shl %cl, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  not %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  and %edi, %eax
  pop %rdi
  xor %edi, %eax
  pop %rdi
  or %edi, %eax
  pop %rdi
  mov %eax, (%rdi)
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  cmp $0, %eax
  sete %al
  movzx %al, %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  neg %rax
  push %rax
  lea -4(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -8(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  jmp .L.return.bits
.L.return.bits:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export div64(a: Integer, b: Integer) -> Integer
div64:
  push %rbp
  mov %rsp, %rbp
  sub $48, %rsp
  mov %rsp, -24(%rbp)
  mov %rdi, -32(%rbp)
  mov %rsi, -40(%rbp)
  mov $8, %rcx
  lea -16(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -16(%rbp), %rax
  push %rax
  lea -32(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  mov %rax, (%rdi)
  mov $8, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  lea -40(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  mov %rax, (%rdi)
  lea -8(%rbp), %rax
  mov (%rax), %rax
  push %rax
  lea -16(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  mov $0, %rdx
  div %rdi
  mov %rdx, %rax
  push %rax
  lea -8(%rbp), %rax
  mov (%rax), %rax
  push %rax
  lea -16(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  mov $0, %rdx
  div %rdi
  push %rax
  lea -40(%rbp), %rax
  mov (%rax), %rax
  push %rax
  lea -32(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  cqo
  idiv %rdi
  mov %rdx, %rax
  push %rax
  lea -40(%rbp), %rax
  mov (%rax), %rax
  push %rax
  lea -32(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  cqo
  idiv %rdi
  pop %rdi
  add %rdi, %rax
  pop %rdi
  add %rdi, %rax
  pop %rdi
  add %rdi, %rax
  jmp .L.return.div64
.L.return.div64:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export sdiv(a: Integer, b: Integer) -> Integer
sdiv:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %edi, -12(%rbp)
  mov %esi, -16(%rbp)
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cdq
  idiv %edi
  mov %rdx, %rax
  push %rax
  mov $100, %rax
  push %rax
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cdq
  idiv %edi
  pop %rdi
  imul %edi, %eax
  pop %rdi
  add %edi, %eax
  jmp .L.return.sdiv
.L.return.sdiv:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export fib(n: Integer) -> Integer
fib:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %edi, -12(%rbp)
  mov $1, %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setle %al
  movzb %al, %rax
  cmp $0, %eax
  je  .L.else.1
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  jmp .L.return.fib
  jmp .L.end.1
.L.else.1:
.L.end.1:
  mov $2, %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  sub %edi, %eax
  push %rax
  lea fib(%rip), %rax
  pop %rdi
  mov %rax, %r10
  mov $0, %rax
  call *%r10
  add $0, %rsp
  push %rax
  sub $8, %rsp
  mov $1, %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  sub %edi, %eax
  push %rax
  lea fib(%rip), %rax
  pop %rdi
  mov %rax, %r10
  mov $0, %rax
  call *%r10
  add $8, %rsp
  pop %rdi
  add %edi, %eax
  jmp .L.return.fib
.L.return.fib:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export fact(n: Integer) -> Integer
fact:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -16(%rbp)
  mov %edi, -20(%rbp)
  mov $4, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  mov $1, %rax
  pop %rdi
  mov %eax, (%rdi)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -4(%rbp), %rax
  push %rax
  mov $2, %rax
  pop %rdi
  mov %eax, (%rdi)
.L.begin.2:
  lea -20(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -4(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  cmp %edi, %eax
  setle %al
  movzb %al, %rax
  cmp $0, %eax
  je .L..2
  lea -8(%rbp), %rax
  push %rax
  lea -4(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -8(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  imul %edi, %eax
  pop %rdi
  mov %eax, (%rdi)
.L..3:
  lea -4(%rbp), %rax
  push %rax
  mov $1, %rax
  push %rax
  lea -4(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  add %edi, %eax
  pop %rdi
  mov %eax, (%rdi)
  jmp .L.begin.2
.L..2:
  lea -8(%rbp), %rax
  movsxd (%rax), %rax
  jmp .L.return.fact
.L.return.fact:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
`

@(test)
chibicc_suite_assembles_validates_and_runs :: proc(t: ^testing.T) {
	workspace := new(Workspace)
	defer free(workspace)
	parts, refusal := assemble(CHIBICC_SUITE, workspace)
	if !testing.expectf(t, refusal.refusal == .None, "refused with %v at line %d, column %d", refusal.refusal, refusal.place.line, refusal.place.column) {
		return
	}
	size, needed := writer.file_size_needed(parts)
	testing.expect_value(t, needed.refusal, writer.Refusal.None)
	file := make([]u8, int(size))
	defer delete(file)
	written, written_refusal := writer.write(parts, file)
	testing.expect_value(t, written_refusal.refusal, writer.Refusal.None)
	testing.expect_value(t, written, size)
	testing.expect_value(t, module.validate(file), module.Error.None)

	// 6 exported functions (+ slot 0 reserved by the module format).
	testing.expect_value(t, len(parts.exports), 6)
	testing.expect_value(t, module.count(file, .Exports), u32(7))

	when ODIN_ARCH == .amd64 {
		last := parts.segments[len(parts.segments) - 1]
		memory_size := last.memory_offset + last.memory_size
		memory, error := virtual.reserve_and_commit(uint(memory_size))
		if !testing.expect(t, error == .None, "the host gave no memory for the code") {
			return
		}
		defer virtual.release(raw_data(memory), uint(memory_size))
		for segment in parts.segments {
			copy(memory[segment.memory_offset:], segment.data)
		}
		testing.expect(t, virtual.protect(raw_data(memory), uint(parts.segments[0].memory_size), {.Read, .Execute}))

		One_Arg :: proc "c" (a: i64) -> i64
		Two_Args :: proc "c" (a: i64, b: i64) -> i64
		export_at :: proc(memory: []u8, workspace: ^Workspace, index: int) -> rawptr {
			return &memory[workspace.export_parts[index].code_offset]
		}

		// Exports appear in emission order: small, bits, div64, sdiv, fib, fact.
		small_fn := cast(One_Arg)export_at(memory, workspace, 0)
		bits_fn := cast(Two_Args)export_at(memory, workspace, 1)
		div64_fn := cast(Two_Args)export_at(memory, workspace, 2)
		sdiv_fn := cast(Two_Args)export_at(memory, workspace, 3)
		fib_fn := cast(One_Arg)export_at(memory, workspace, 4)
		fact_fn := cast(One_Arg)export_at(memory, workspace, 5)

		// Factorial loop.
		testing.expect_value(t, fact_fn(0), i64(1))
		testing.expect_value(t, fact_fn(1), i64(1))
		testing.expect_value(t, fact_fn(5), i64(120))
		testing.expect_value(t, fact_fn(10), i64(3628800))

		// Recursive Fibonacci via indirect call *%r10.
		testing.expect_value(t, fib_fn(0), i64(0))
		testing.expect_value(t, fib_fn(1), i64(1))
		testing.expect_value(t, fib_fn(10), i64(55))
		testing.expect_value(t, fib_fn(15), i64(610))

		// Signed 32-bit division and modulo (cdq + idiv).
		testing.expect_value(t, sdiv_fn(17, 5), i64(302))
		testing.expect_value(t, sdiv_fn(-17, 5), i64(-302))
		testing.expect_value(t, sdiv_fn(17, -5), i64(-298))
		testing.expect_value(t, sdiv_fn(-17, -5), i64(298))

		// Signed and unsigned 64-bit division and modulo (cqo + idiv, div).
		testing.expect_value(t, div64_fn(100, 7), i64(32))
		testing.expect_value(t, div64_fn(-100, 7), i64(2635249153387078772))

		// Signed & unsigned comparisons, bitwise ops, variable shifts, neg, logical !.
		testing.expect_value(t, bits_fn(0, 0), i64(41))
		testing.expect_value(t, bits_fn(-8, 2), i64(19))
		testing.expect_value(t, bits_fn(13, 5), i64(-12))
		testing.expect_value(t, bits_fn(5, 13), i64(56))

		// Byte/short arrays, rep stosb initializers, sign/zero extensions, 6-arg call.
		testing.expect_value(t, small_fn(0), i64(202500))
		testing.expect_value(t, small_fn(-1), i64(202499))
		testing.expect_value(t, small_fn(255), i64(202499))
		testing.expect_value(t, small_fn(128), i64(202372))
	}
}

// Exercises scaled indexed addressing (disp(base, index, scale)), test,
// cwtl/cltq, 3-operand imul, and indirect jmp/call in a valid module.
@(private = "file")
INDEXED_PROGRAM :: `export sum_table(count: Integer) -> Integer
sum_table:
	lea bytes_table(%rip), %r8
	lea shorts_table(%rip), %r9
	xor %rax, %rax
	xor %rcx, %rcx
.L.loop:
	cmp %rdi, %rcx
	jge .L.done
	movsbl (%r8,%rcx,1), %edx
	movzwl (%r9,%rcx,2), %r10d
	imul $3, %edx, %edx
	add %r10d, %edx
	movslq %edx, %rdx
	add %rdx, %rax
	inc %rcx
	jmp .L.loop
.L.done:
	test %rax, %rax
	jnz .L.finish
	mov $1, %eax
	cwtl
	cltq
.L.finish:
	lea .L.exit(%rip), %r11
	jmp *%r11
.L.exit:
	ret
section data
bytes_table:
	byte -5, 10, -2, 4
shorts_table:
	byte 0xE8, 0x03, 0x10, 0x27, 0xFF, 0xFF, 0x01, 0x00
`

@(test)
indexed_and_indirect_program_validates_and_runs :: proc(t: ^testing.T) {
	workspace := new(Workspace)
	defer free(workspace)
	parts, refusal := assemble(INDEXED_PROGRAM, workspace)
	if !testing.expectf(t, refusal.refusal == .None, "refused with %v at line %d, column %d", refusal.refusal, refusal.place.line, refusal.place.column) {
		return
	}
	size, needed := writer.file_size_needed(parts)
	testing.expect_value(t, needed.refusal, writer.Refusal.None)
	file := make([]u8, int(size))
	defer delete(file)
	written, written_refusal := writer.write(parts, file)
	testing.expect_value(t, written_refusal.refusal, writer.Refusal.None)
	testing.expect_value(t, written, size)
	testing.expect_value(t, module.validate(file), module.Error.None)

	when ODIN_ARCH == .amd64 {
		last := parts.segments[len(parts.segments) - 1]
		memory_size := last.memory_offset + last.memory_size
		memory, error := virtual.reserve_and_commit(uint(memory_size))
		if !testing.expect(t, error == .None, "the host gave no memory for the code") {
			return
		}
		defer virtual.release(raw_data(memory), uint(memory_size))
		for segment in parts.segments {
			copy(memory[segment.memory_offset:], segment.data)
		}
		testing.expect(t, virtual.protect(raw_data(memory), uint(parts.segments[0].memory_size), {.Read, .Execute}))

		One_Arg :: proc "c" (n: i64) -> i64
		sum_table_fn := cast(One_Arg)rawptr(&memory[workspace.export_parts[0].code_offset])
		// count == 0 -> sum == 0 -> test sets ZF -> returns 1.
		testing.expect_value(t, sum_table_fn(0), i64(1))
		// i=0: -5*3 + 1000 = 985
		testing.expect_value(t, sum_table_fn(1), i64(985))
		// i=0..3: (-5+10-2+4)*3 + (1000 + 10000 + 65535 + 1) = 21 + 76536 = 76557
		testing.expect_value(t, sum_table_fn(4), i64(76557))
	}
}


// Verbatim assembly emitted by the patched chibicc of modus for a program
// with tables of addresses in its data (`quad` lines that the module
// rebases), float and double arithmetic, comparisons and conversions
// (the conversion of an unsigned long uses the numeric local labels `1f`
// and `2f`), and the atomic `xchg` and `lock cmpxchg`:
//
//   typedef int (*operation)(int, int);
//   static int add(int a, int b) { return a + b; }
//   static int sub(int a, int b) { return a - b; }
//   static int mul(int a, int b) { return a * b; }
//   static operation operations[] = {add, sub, mul};
//   static char *names[] = {"add", "sub", "mul"};
//   static int numbers[] = {10, 20, 30, 40};
//   static int *middle = &numbers[2];
//   long apply(long index, long a, long b) { return operations[index](a, b); }
//   long name_byte(long index, long at) { return names[index][at]; }
//   long middle_value(long step) { return middle[step - 1]; }
//   int average(int a, int b) { double x = a; double y = b; double half = (x + y) / 2; return (int)(half * 10); }
//   int scale(int a) { float f = a; f = f * f - f / 4; return (int)f; }
//   int compare(int a, int b) { double x = a; double y = b; return (x < y) + (x == y) * 2 + (x > y) * 4; }
//   long widen(long a) { float f = (float)a; double d = f; unsigned long u = (unsigned long)a; double e = (double)u; return (long)(d + e); }
//   int exchange(int value) { int slot = 5; int old = __builtin_atomic_exchange(&slot, value); return old * 100 + slot; }
//   int swap_if(int expected, int desired) { int slot = 7; int ok = __builtin_compare_and_swap(&slot, &expected, desired); return ok * 1000 + slot * 10 + expected; }
@(private = "file")
REBASED_FLOATING_ATOMIC_PROGRAM :: `section data
.L..29:
  byte 115
  byte 119
  byte 97
  byte 112
  byte 95
  byte 105
  byte 102
  byte 0
section data
.L..28:
  byte 115
  byte 119
  byte 97
  byte 112
  byte 95
  byte 105
  byte 102
  byte 0
section data
.L..27:
  byte 101
  byte 120
  byte 99
  byte 104
  byte 97
  byte 110
  byte 103
  byte 101
  byte 0
section data
.L..26:
  byte 101
  byte 120
  byte 99
  byte 104
  byte 97
  byte 110
  byte 103
  byte 101
  byte 0
section data
.L..25:
  byte 119
  byte 105
  byte 100
  byte 101
  byte 110
  byte 0
section data
.L..24:
  byte 119
  byte 105
  byte 100
  byte 101
  byte 110
  byte 0
section data
.L..23:
  byte 99
  byte 111
  byte 109
  byte 112
  byte 97
  byte 114
  byte 101
  byte 0
section data
.L..22:
  byte 99
  byte 111
  byte 109
  byte 112
  byte 97
  byte 114
  byte 101
  byte 0
section data
.L..21:
  byte 115
  byte 99
  byte 97
  byte 108
  byte 101
  byte 0
section data
.L..20:
  byte 115
  byte 99
  byte 97
  byte 108
  byte 101
  byte 0
section data
.L..19:
  byte 97
  byte 118
  byte 101
  byte 114
  byte 97
  byte 103
  byte 101
  byte 0
section data
.L..18:
  byte 97
  byte 118
  byte 101
  byte 114
  byte 97
  byte 103
  byte 101
  byte 0
section data
.L..17:
  byte 109
  byte 105
  byte 100
  byte 100
  byte 108
  byte 101
  byte 95
  byte 118
  byte 97
  byte 108
  byte 117
  byte 101
  byte 0
section data
.L..16:
  byte 109
  byte 105
  byte 100
  byte 100
  byte 108
  byte 101
  byte 95
  byte 118
  byte 97
  byte 108
  byte 117
  byte 101
  byte 0
section data
.L..15:
  byte 110
  byte 97
  byte 109
  byte 101
  byte 95
  byte 98
  byte 121
  byte 116
  byte 101
  byte 0
section data
.L..14:
  byte 110
  byte 97
  byte 109
  byte 101
  byte 95
  byte 98
  byte 121
  byte 116
  byte 101
  byte 0
section data
.L..13:
  byte 97
  byte 112
  byte 112
  byte 108
  byte 121
  byte 0
section data
.L..12:
  byte 97
  byte 112
  byte 112
  byte 108
  byte 121
  byte 0
section data
  zero 4
middle:
  quad numbers+8
section data
numbers:
  byte 10
  byte 0
  byte 0
  byte 0
  byte 20
  byte 0
  byte 0
  byte 0
  byte 30
  byte 0
  byte 0
  byte 0
  byte 40
  byte 0
  byte 0
  byte 0
section data
.L..11:
  byte 109
  byte 117
  byte 108
  byte 0
section data
.L..10:
  byte 115
  byte 117
  byte 98
  byte 0
section data
.L..9:
  byte 97
  byte 100
  byte 100
  byte 0
section data
.L..8:
  byte 109
  byte 117
  byte 108
  byte 0
section data
.L..7:
  byte 115
  byte 117
  byte 98
  byte 0
section data
.L..6:
  byte 97
  byte 100
  byte 100
  byte 0
section data
  zero 8
names:
  quad .L..9+0
  quad .L..10+0
  quad .L..11+0
section data
  zero 8
operations:
  quad add+0
  quad sub+0
  quad mul+0
section data
.L..5:
  byte 109
  byte 117
  byte 108
  byte 0
section data
.L..4:
  byte 109
  byte 117
  byte 108
  byte 0
section data
.L..3:
  byte 115
  byte 117
  byte 98
  byte 0
section data
.L..2:
  byte 115
  byte 117
  byte 98
  byte 0
section data
.L..1:
  byte 97
  byte 100
  byte 100
  byte 0
section data
.L..0:
  byte 97
  byte 100
  byte 100
  byte 0
section code
export swap_if(expected: Integer, desired: Integer) -> Integer
swap_if:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -16(%rbp)
  mov %edi, -20(%rbp)
  mov %esi, -24(%rbp)
  mov $4, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  mov $7, %rax
  pop %rdi
  mov %eax, (%rdi)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -4(%rbp), %rax
  push %rax
  lea -8(%rbp), %rax
  push %rax
  lea -24(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -20(%rbp), %rax
  mov %rax, %r8
  movsxd (%rax), %rax
  pop %rdx
  pop %rdi
  lock cmpxchg %edx, (%rdi)
  sete %cl
  je 1f
  mov %eax, (%r8)
1:
  movzbl %cl, %eax
  pop %rdi
  mov %eax, (%rdi)
  lea -20(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  mov $10, %rax
  push %rax
  lea -8(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $1000, %rax
  push %rax
  lea -4(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  imul %edi, %eax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  jmp .L.return.swap_if
.L.return.swap_if:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export exchange(value: Integer) -> Integer
exchange:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -16(%rbp)
  mov %edi, -20(%rbp)
  mov $4, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  mov $5, %rax
  pop %rdi
  mov %eax, (%rdi)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -4(%rbp), %rax
  push %rax
  lea -8(%rbp), %rax
  push %rax
  lea -20(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  xchg %eax, (%rdi)
  pop %rdi
  mov %eax, (%rdi)
  lea -8(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  mov $100, %rax
  push %rax
  lea -4(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  imul %edi, %eax
  pop %rdi
  add %edi, %eax
  jmp .L.return.exchange
.L.return.exchange:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export widen(a: Integer) -> Integer
widen:
  push %rbp
  mov %rsp, %rbp
  sub $48, %rsp
  mov %rsp, -40(%rbp)
  mov %rdi, -48(%rbp)
  mov $4, %rcx
  lea -28(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -28(%rbp), %rax
  push %rax
  lea -48(%rbp), %rax
  mov (%rax), %rax
  cvtsi2ssq %rax, %xmm0
  pop %rdi
  movss %xmm0, (%rdi)
  mov $8, %rcx
  lea -24(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -24(%rbp), %rax
  push %rax
  lea -28(%rbp), %rax
  movss (%rax), %xmm0
  cvtss2sd %xmm0, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $8, %rcx
  lea -16(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -16(%rbp), %rax
  push %rax
  lea -48(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  mov %rax, (%rdi)
  mov $8, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  lea -16(%rbp), %rax
  mov (%rax), %rax
  test %rax,%rax; js 1f; pxor %xmm0,%xmm0; cvtsi2sd %rax,%xmm0; jmp 2f; 1: mov %rax,%rdi; and $1,%eax; pxor %xmm0,%xmm0; shr %rdi; or %rax,%rdi; cvtsi2sd %rdi,%xmm0; addsd %xmm0,%xmm0; 2:
  pop %rdi
  movsd %xmm0, (%rdi)
  lea -8(%rbp), %rax
  movsd (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -24(%rbp), %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  addsd %xmm1, %xmm0
  cvttsd2siq %xmm0, %rax
  jmp .L.return.widen
.L.return.widen:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export compare(a: Integer, b: Integer) -> Integer
compare:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -24(%rbp)
  mov %edi, -28(%rbp)
  mov %esi, -32(%rbp)
  mov $8, %rcx
  lea -16(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -16(%rbp), %rax
  push %rax
  lea -28(%rbp), %rax
  movsxd (%rax), %rax
  cvtsi2sdl %eax, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $8, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  lea -32(%rbp), %rax
  movsxd (%rax), %rax
  cvtsi2sdl %eax, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $4, %rax
  push %rax
  lea -16(%rbp), %rax
  movsd (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -8(%rbp), %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  ucomisd %xmm0, %xmm1
  seta %al
  and $1, %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  mov $2, %rax
  push %rax
  lea -8(%rbp), %rax
  movsd (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -16(%rbp), %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  ucomisd %xmm0, %xmm1
  sete %al
  setnp %dl
  and %dl, %al
  and $1, %al
  movzb %al, %rax
  pop %rdi
  imul %edi, %eax
  push %rax
  lea -8(%rbp), %rax
  movsd (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -16(%rbp), %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  ucomisd %xmm0, %xmm1
  seta %al
  and $1, %al
  movzb %al, %rax
  pop %rdi
  add %edi, %eax
  pop %rdi
  add %edi, %eax
  jmp .L.return.compare
.L.return.compare:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export scale(a: Integer) -> Integer
scale:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -16(%rbp)
  mov %edi, -20(%rbp)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -4(%rbp), %rax
  push %rax
  lea -20(%rbp), %rax
  movsxd (%rax), %rax
  cvtsi2ssl %eax, %xmm0
  pop %rdi
  movss %xmm0, (%rdi)
  lea -4(%rbp), %rax
  push %rax
  mov $4, %rax
  cvtsi2ssl %eax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -4(%rbp), %rax
  movss (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  divss %xmm1, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -4(%rbp), %rax
  movss (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -4(%rbp), %rax
  movss (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  mulss %xmm1, %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  subss %xmm1, %xmm0
  pop %rdi
  movss %xmm0, (%rdi)
  lea -4(%rbp), %rax
  movss (%rax), %xmm0
  cvttss2sil %xmm0, %eax
  jmp .L.return.scale
.L.return.scale:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export average(a: Integer, b: Integer) -> Integer
average:
  push %rbp
  mov %rsp, %rbp
  sub $48, %rsp
  mov %rsp, -32(%rbp)
  mov %edi, -36(%rbp)
  mov %esi, -40(%rbp)
  mov $8, %rcx
  lea -24(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -24(%rbp), %rax
  push %rax
  lea -36(%rbp), %rax
  movsxd (%rax), %rax
  cvtsi2sdl %eax, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $8, %rcx
  lea -16(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -16(%rbp), %rax
  push %rax
  lea -40(%rbp), %rax
  movsxd (%rax), %rax
  cvtsi2sdl %eax, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $8, %rcx
  lea -8(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -8(%rbp), %rax
  push %rax
  mov $2, %rax
  cvtsi2sdl %eax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -16(%rbp), %rax
  movsd (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -24(%rbp), %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  addsd %xmm1, %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  divsd %xmm1, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $10, %rax
  cvtsi2sdl %eax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -8(%rbp), %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  mulsd %xmm1, %xmm0
  cvttsd2sil %xmm0, %eax
  jmp .L.return.average
.L.return.average:
  movsxd %eax, %rax
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export middle_value(step: Integer) -> Integer
middle_value:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %rdi, -16(%rbp)
  mov $4, %rax
  push %rax
  mov $1, %rax
  movsxd %eax, %rax
  push %rax
  lea -16(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  sub %rdi, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea middle(%rip), %rax
  mov (%rax), %rax
  pop %rdi
  add %rdi, %rax
  movsxd (%rax), %rax
  movsxd %eax, %rax
  jmp .L.return.middle_value
.L.return.middle_value:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export name_byte(index: Integer, at: Integer) -> Integer
name_byte:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -8(%rbp)
  mov %rdi, -16(%rbp)
  mov %rsi, -24(%rbp)
  mov $1, %rax
  push %rax
  lea -24(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  mov $8, %rax
  push %rax
  lea -16(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea names(%rip), %rax
  pop %rdi
  add %rdi, %rax
  mov (%rax), %rax
  pop %rdi
  add %rdi, %rax
  movsbl (%rax), %eax
  movsxd %eax, %rax
  jmp .L.return.name_byte
.L.return.name_byte:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export apply(index: Integer, a: Integer, b: Integer) -> Integer
apply:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -8(%rbp)
  mov %rdi, -16(%rbp)
  mov %rsi, -24(%rbp)
  mov %rdx, -32(%rbp)
  lea -32(%rbp), %rax
  mov (%rax), %rax
  push %rax
  lea -24(%rbp), %rax
  mov (%rax), %rax
  push %rax
  mov $8, %rax
  push %rax
  lea -16(%rbp), %rax
  mov (%rax), %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea operations(%rip), %rax
  pop %rdi
  add %rdi, %rax
  mov (%rax), %rax
  pop %rdi
  pop %rsi
  mov %rax, %r10
  mov $0, %rax
  call *%r10
  add $0, %rsp
  movsxd %eax, %rax
  jmp .L.return.apply
.L.return.apply:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
mul:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %edi, -12(%rbp)
  mov %esi, -16(%rbp)
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  imul %edi, %eax
  jmp .L.return.mul
.L.return.mul:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
sub:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %edi, -12(%rbp)
  mov %esi, -16(%rbp)
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  sub %edi, %eax
  jmp .L.return.sub
.L.return.sub:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
add:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %edi, -12(%rbp)
  mov %esi, -16(%rbp)
  lea -16(%rbp), %rax
  movsxd (%rax), %rax
  push %rax
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  pop %rdi
  add %edi, %eax
  jmp .L.return.add
.L.return.add:
  mov %rbp, %rsp
  pop %rbp
  ret
`

@(test)
rebased_floating_and_atomic_program_validates_and_runs :: proc(t: ^testing.T) {
	workspace := new(Workspace)
	defer free(workspace)
	parts, refusal := assemble(REBASED_FLOATING_ATOMIC_PROGRAM, workspace)
	if !testing.expectf(t, refusal.refusal == .None, "refused with %v at line %d, column %d", refusal.refusal, refusal.place.line, refusal.place.column) {
		return
	}
	// One rebase for each address: middle, three names, three operations.
	testing.expect_value(t, len(parts.rebases), 7)
	size, needed := writer.file_size_needed(parts)
	testing.expect_value(t, needed.refusal, writer.Refusal.None)
	file := make([]u8, int(size))
	defer delete(file)
	written, written_refusal := writer.write(parts, file)
	testing.expect_value(t, written_refusal.refusal, writer.Refusal.None)
	testing.expect_value(t, written, size)
	testing.expect_value(t, module.validate(file), module.Error.None)
	testing.expect(t, module.count(file, .Rebases) > 0, "the file has a rebase table")

	when ODIN_ARCH == .amd64 {
		last := parts.segments[len(parts.segments) - 1]
		memory_size := last.memory_offset + last.memory_size
		memory, error := virtual.reserve_and_commit(uint(memory_size))
		if !testing.expect(t, error == .None, "the host gave no memory for the module") {
			return
		}
		defer virtual.release(raw_data(memory), uint(memory_size))
		for segment in parts.segments {
			copy(memory[segment.memory_offset:], segment.data)
		}
		// The load: the loader of modus adds the base to each rebase.
		testing.expect_value(t, module.rebase(file, memory, uintptr(raw_data(memory))), module.Error.None)
		testing.expect(t, virtual.protect(raw_data(memory), uint(parts.segments[0].memory_size), {.Read, .Execute}))

		One_Arg :: proc "c" (a: i64) -> i64
		Two_Args :: proc "c" (a: i64, b: i64) -> i64
		Three_Args :: proc "c" (a: i64, b: i64, c: i64) -> i64
		export_named :: proc(memory: []u8, parts: writer.Module_Parts, name: string) -> rawptr {
			for export in parts.exports {
				if export.name == name {
					return &memory[export.code_offset]
				}
			}
			return nil
		}

		// A table of function pointers, rebased.
		apply := cast(Three_Args)export_named(memory, parts, "apply")
		testing.expect_value(t, apply(0, 7, 5), i64(12))
		testing.expect_value(t, apply(1, 7, 5), i64(2))
		testing.expect_value(t, apply(2, 7, 5), i64(35))
		// A table of pointers to string literals, rebased.
		name_byte := cast(Two_Args)export_named(memory, parts, "name_byte")
		testing.expect_value(t, name_byte(0, 0), i64('a'))
		testing.expect_value(t, name_byte(1, 0), i64('s'))
		testing.expect_value(t, name_byte(2, 2), i64('l'))
		testing.expect_value(t, name_byte(2, 3), i64(0))
		// A pointer into an array, with an offset: `quad numbers+8`.
		middle_value := cast(One_Arg)export_named(memory, parts, "middle_value")
		testing.expect_value(t, middle_value(0), i64(20))
		testing.expect_value(t, middle_value(1), i64(30))
		testing.expect_value(t, middle_value(2), i64(40))
		// Double arithmetic and the conversions of int and double.
		average := cast(Two_Args)export_named(memory, parts, "average")
		testing.expect_value(t, average(3, 4), i64(35))
		testing.expect_value(t, average(-3, -4), i64(-35))
		testing.expect_value(t, average(0, 0), i64(0))
		// Float arithmetic: 4 * 4 - 4 / 4, and 10 * 10 - 10 / 4 truncated.
		scale := cast(One_Arg)export_named(memory, parts, "scale")
		testing.expect_value(t, scale(4), i64(15))
		testing.expect_value(t, scale(10), i64(97))
		testing.expect_value(t, scale(-2), i64(4))
		// ucomisd and the flags of an unordered compare.
		compare := cast(Two_Args)export_named(memory, parts, "compare")
		testing.expect_value(t, compare(1, 2), i64(1))
		testing.expect_value(t, compare(2, 2), i64(2))
		testing.expect_value(t, compare(3, 2), i64(4))
		// long to float, float to double, unsigned long to double (`js 1f`):
		// -1 is 2^64 - 1 unsigned, and the sum past 2^63 truncates to the
		// integer indefinite value of cvttsd2si.
		widen := cast(One_Arg)export_named(memory, parts, "widen")
		testing.expect_value(t, widen(3), i64(6))
		testing.expect_value(t, widen(1 << 40), i64(1 << 41))
		testing.expect_value(t, widen(-1), min(i64))
		// xchg with memory.
		exchange := cast(One_Arg)export_named(memory, parts, "exchange")
		testing.expect_value(t, exchange(9), i64(509))
		testing.expect_value(t, exchange(-1), i64(499))
		// lock cmpxchg: a swap that succeeds, and one that fails and writes
		// the value that it found into `expected`.
		swap_if := cast(Two_Args)export_named(memory, parts, "swap_if")
		testing.expect_value(t, swap_if(7, 3), i64(1037))
		testing.expect_value(t, swap_if(6, 3), i64(77))
	}
}

// Verbatim assembly emitted by the patched chibicc of modus, with the
// strtold of its thin libc, for a program with floating constants:
// decimal, scientific and hexadecimal, of double and of float, the least
// normal and the least subnormal double, and a table of doubles in the
// data. Each constant must be the double or the float nearest to its text:
// the test compares the bits.
//
//   static long double_bits_of(double value) { return *(long *)&value; }
//   static long float_bits_of(float value) { return *(unsigned int *)&value; }
//
//   long double_constant(long which) {
//     switch (which) {
//     case 0: return double_bits_of(3.141592653589793);
//     case 1: return double_bits_of(0x1.8p+1);
//     case 2: return double_bits_of(1e-6);
//     case 3: return double_bits_of(2.5E+10);
//     case 4: return double_bits_of(1e308);
//     case 5: return double_bits_of(.5);
//     case 6: return double_bits_of(42.);
//     case 7: return double_bits_of(0X0.Fp0);
//     case 8: return double_bits_of(0x1p-10);
//     case 9: return double_bits_of(2.2250738585072014e-308);
//     case 10: return double_bits_of(4.9406564584124654e-324);
//     case 11: return double_bits_of(0.1);
//     case 12: return double_bits_of(-0.0);
//     }
//     return 0;
//   }
//
//   long float_constant(long which) {
//     switch (which) {
//     case 0: return float_bits_of(1.5f);
//     case 1: return float_bits_of(0.1f);
//     case 2: return float_bits_of(3.4028235e38f);
//     case 3: return float_bits_of(0x1.8p+1f);
//     }
//     return 0;
//   }
//
//   double table[3] = {0.25, 1e100, -2.5};
//
//   long scaled(long value) {
//     double pi = 3.141592653589793;
//     float half = 0.5f;
//     return (long)(value * pi * half * 1000.0 + table[0] * 4);
//   }
FLOATING_CONSTANT_PROGRAM :: `section data
.L..28:
  byte 115
  byte 99
  byte 97
  byte 108
  byte 101
  byte 100
  byte 0
section data
.L..27:
  byte 115
  byte 99
  byte 97
  byte 108
  byte 101
  byte 100
  byte 0
section data
  zero 2
table:
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0
  byte -48
  byte 63
  byte 125
  byte -61
  byte -108
  byte 37
  byte -83
  byte 73
  byte -78
  byte 84
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0
  byte 0
  byte 4
  byte -64
section data
.L..21:
  byte 102
  byte 108
  byte 111
  byte 97
  byte 116
  byte 95
  byte 99
  byte 111
  byte 110
  byte 115
  byte 116
  byte 97
  byte 110
  byte 116
  byte 0
section data
.L..20:
  byte 102
  byte 108
  byte 111
  byte 97
  byte 116
  byte 95
  byte 99
  byte 111
  byte 110
  byte 115
  byte 116
  byte 97
  byte 110
  byte 116
  byte 0
section data
  zero 10
.L..5:
  byte 100
  byte 111
  byte 117
  byte 98
  byte 108
  byte 101
  byte 95
  byte 99
  byte 111
  byte 110
  byte 115
  byte 116
  byte 97
  byte 110
  byte 116
  byte 0
section data
.L..4:
  byte 100
  byte 111
  byte 117
  byte 98
  byte 108
  byte 101
  byte 95
  byte 99
  byte 111
  byte 110
  byte 115
  byte 116
  byte 97
  byte 110
  byte 116
  byte 0
section data
.L..3:
  byte 102
  byte 108
  byte 111
  byte 97
  byte 116
  byte 95
  byte 98
  byte 105
  byte 116
  byte 115
  byte 95
  byte 111
  byte 102
  byte 0
section data
.L..2:
  byte 102
  byte 108
  byte 111
  byte 97
  byte 116
  byte 95
  byte 98
  byte 105
  byte 116
  byte 115
  byte 95
  byte 111
  byte 102
  byte 0
section data
.L..1:
  byte 100
  byte 111
  byte 117
  byte 98
  byte 108
  byte 101
  byte 95
  byte 98
  byte 105
  byte 116
  byte 115
  byte 95
  byte 111
  byte 102
  byte 0
section data
.L..0:
  byte 100
  byte 111
  byte 117
  byte 98
  byte 108
  byte 101
  byte 95
  byte 98
  byte 105
  byte 116
  byte 115
  byte 95
  byte 111
  byte 102
  byte 0
section code
export scaled(value: Integer) -> Integer
scaled:
  push %rbp
  mov %rsp, %rbp
  sub $32, %rsp
  mov %rsp, -24(%rbp)
  mov %rdi, -32(%rbp)
  mov $8, %rcx
  lea -16(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -16(%rbp), %rax
  push %rax
  mov $4614256656552045848, %rax  # double ?
  movq %rax, %xmm0
  pop %rdi
  movsd %xmm0, (%rdi)
  mov $4, %rcx
  lea -4(%rbp), %rdi
  mov $0, %al
  rep stosb
  lea -4(%rbp), %rax
  push %rax
  mov $1056964608, %eax  # float ?
  movq %rax, %xmm0
  pop %rdi
  movss %xmm0, (%rdi)
  mov $4, %rax
  cvtsi2sdl %eax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  mov $8, %rax
  push %rax
  mov $0, %rax
  movsxd %eax, %rax
  pop %rdi
  imul %rdi, %rax
  push %rax
  lea table(%rip), %rax
  pop %rdi
  add %rdi, %rax
  movsd (%rax), %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  mulsd %xmm1, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  mov $4652007308841189376, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -4(%rbp), %rax
  movss (%rax), %xmm0
  cvtss2sd %xmm0, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -16(%rbp), %rax
  movsd (%rax), %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea -32(%rbp), %rax
  mov (%rax), %rax
  cvtsi2sdq %rax, %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  mulsd %xmm1, %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  mulsd %xmm1, %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  mulsd %xmm1, %xmm0
  movsd (%rsp), %xmm1
  add $8, %rsp
  addsd %xmm1, %xmm0
  cvttsd2siq %xmm0, %rax
  jmp .L.return.scaled
.L.return.scaled:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export float_constant(which: Integer) -> Integer
float_constant:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %rdi, -16(%rbp)
  lea -16(%rbp), %rax
  mov (%rax), %rax
  cmp $3, %rax
  je .L..26
  cmp $2, %rax
  je .L..25
  cmp $1, %rax
  je .L..24
  cmp $0, %rax
  je .L..23
  jmp .L..22
.L..23:
  mov $1069547520, %eax  # float ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea float_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.float_constant
.L..24:
  mov $1036831949, %eax  # float ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea float_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.float_constant
.L..25:
  mov $2139095039, %eax  # float ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea float_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.float_constant
.L..26:
  mov $1077936128, %eax  # float ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea float_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.float_constant
.L..22:
  mov $0, %rax
  movsxd %eax, %rax
  jmp .L.return.float_constant
.L.return.float_constant:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
export double_constant(which: Integer) -> Integer
double_constant:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  mov %rdi, -16(%rbp)
  lea -16(%rbp), %rax
  mov (%rax), %rax
  cmp $12, %rax
  je .L..19
  cmp $11, %rax
  je .L..18
  cmp $10, %rax
  je .L..17
  cmp $9, %rax
  je .L..16
  cmp $8, %rax
  je .L..15
  cmp $7, %rax
  je .L..14
  cmp $6, %rax
  je .L..13
  cmp $5, %rax
  je .L..12
  cmp $4, %rax
  je .L..11
  cmp $3, %rax
  je .L..10
  cmp $2, %rax
  je .L..9
  cmp $1, %rax
  je .L..8
  cmp $0, %rax
  je .L..7
  jmp .L..6
.L..7:
  mov $4614256656552045848, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..8:
  mov $4613937818241073152, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..9:
  mov $4517329193108106637, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..10:
  mov $4762354806503243776, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..11:
  mov $9214871658872686752, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..12:
  mov $4602678819172646912, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..13:
  mov $4631107791820423168, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..14:
  mov $4606619468846596096, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..15:
  mov $4562146422526312448, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..16:
  mov $4503599627370496, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..17:
  mov $1, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..18:
  mov $4591870180066957722, %rax  # double ?
  movq %rax, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..19:
  mov $0, %rax  # double ?
  movq %rax, %xmm0
  mov $1, %rax
  shl $63, %rax
  movq %rax, %xmm1
  xorpd %xmm1, %xmm0
  sub $8, %rsp
  movsd %xmm0, (%rsp)
  lea double_bits_of(%rip), %rax
  movsd (%rsp), %xmm0
  add $8, %rsp
  mov %rax, %r10
  mov $1, %rax
  call *%r10
  add $0, %rsp
  jmp .L.return.double_constant
.L..6:
  mov $0, %rax
  movsxd %eax, %rax
  jmp .L.return.double_constant
.L.return.double_constant:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
float_bits_of:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  movss %xmm0, -12(%rbp)
  lea -12(%rbp), %rax
  movsxd (%rax), %rax
  mov %eax, %eax
  jmp .L.return.float_bits_of
.L.return.float_bits_of:
  mov %rbp, %rsp
  pop %rbp
  ret
section code
double_bits_of:
  push %rbp
  mov %rsp, %rbp
  sub $16, %rsp
  mov %rsp, -8(%rbp)
  movsd %xmm0, -16(%rbp)
  lea -16(%rbp), %rax
  mov (%rax), %rax
  jmp .L.return.double_bits_of
.L.return.double_bits_of:
  mov %rbp, %rsp
  pop %rbp
  ret
`

@(test)
floating_constant_program_validates_and_runs :: proc(t: ^testing.T) {
	workspace := new(Workspace)
	defer free(workspace)
	parts, refusal := assemble(FLOATING_CONSTANT_PROGRAM, workspace)
	if !testing.expectf(t, refusal.refusal == .None, "refused with %v at line %d, column %d", refusal.refusal, refusal.place.line, refusal.place.column) {
		return
	}
	size, needed := writer.file_size_needed(parts)
	testing.expect_value(t, needed.refusal, writer.Refusal.None)
	file := make([]u8, int(size))
	defer delete(file)
	written, written_refusal := writer.write(parts, file)
	testing.expect_value(t, written_refusal.refusal, writer.Refusal.None)
	testing.expect_value(t, written, size)
	testing.expect_value(t, module.validate(file), module.Error.None)

	when ODIN_ARCH == .amd64 {
		last := parts.segments[len(parts.segments) - 1]
		memory_size := last.memory_offset + last.memory_size
		memory, error := virtual.reserve_and_commit(uint(memory_size))
		if !testing.expect(t, error == .None, "the host gave no memory for the module") {
			return
		}
		defer virtual.release(raw_data(memory), uint(memory_size))
		for segment in parts.segments {
			copy(memory[segment.memory_offset:], segment.data)
		}
		testing.expect_value(t, module.rebase(file, memory, uintptr(raw_data(memory))), module.Error.None)
		testing.expect(t, virtual.protect(raw_data(memory), uint(parts.segments[0].memory_size), {.Read, .Execute}))

		One_Arg :: proc "c" (a: i64) -> i64
		export_named :: proc(memory: []u8, parts: writer.Module_Parts, name: string) -> rawptr {
			for export in parts.exports {
				if export.name == name {
					return &memory[export.code_offset]
				}
			}
			return nil
		}

		// The bits that the host compiler gives to the same constants.
		double_bits := [?]u64 {
			0x400921FB54442D18, // 3.141592653589793
			0x4008000000000000, // 0x1.8p+1
			0x3EB0C6F7A0B5ED8D, // 1e-6
			0x42174876E8000000, // 2.5E+10
			0x7FE1CCF385EBC8A0, // 1e308
			0x3FE0000000000000, // .5
			0x4045000000000000, // 42.
			0x3FEE000000000000, // 0X0.Fp0
			0x3F50000000000000, // 0x1p-10
			0x0010000000000000, // 2.2250738585072014e-308
			0x0000000000000001, // 4.9406564584124654e-324
			0x3FB999999999999A, // 0.1
			0x8000000000000000, // -0.0
		}
		double_constant := cast(One_Arg)export_named(memory, parts, "double_constant")
		for bits, which in double_bits {
			found := u64(double_constant(i64(which)))
			testing.expectf(t, found == bits, "double %d: %x, not %x", which, found, bits)
		}
		float_bits := [?]u64 {
			0x3FC00000, // 1.5f
			0x3DCCCCCD, // 0.1f
			0x7F7FFFFF, // 3.4028235e38f
			0x40400000, // 0x1.8p+1f
		}
		float_constant := cast(One_Arg)export_named(memory, parts, "float_constant")
		for bits, which in float_bits {
			found := u64(float_constant(i64(which)))
			testing.expectf(t, found == bits, "float %d: %x, not %x", which, found, bits)
		}
		// value * pi * 0.5 * 1000 + 0.25 * 4, truncated toward zero.
		scaled := cast(One_Arg)export_named(memory, parts, "scaled")
		testing.expect_value(t, scaled(0), i64(1))
		testing.expect_value(t, scaled(1), i64(1571))
		testing.expect_value(t, scaled(7), i64(10996))
		testing.expect_value(t, scaled(-3), i64(-4711))
	}
}
