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
