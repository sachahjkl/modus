# The jump of exit for a program that chibicc builds: chibicc has no
# built-in of a jump. A buffer keeps the registers that a call keeps, the
# stack after the return, and the place of the return.
unit
section code
  global thin_libc_jump_set
thin_libc_jump_set:
  mov %rbx, 0(%rdi)
  mov %rbp, 8(%rdi)
  mov %r12, 16(%rdi)
  mov %r13, 24(%rdi)
  mov %r14, 32(%rdi)
  mov %r15, 40(%rdi)
  lea 8(%rsp), %rdx
  mov %rdx, 48(%rdi)
  mov (%rsp), %rdx
  mov %rdx, 56(%rdi)
  mov $0, %eax
  ret
  global thin_libc_jump
thin_libc_jump:
  mov 0(%rdi), %rbx
  mov 8(%rdi), %rbp
  mov 16(%rdi), %r12
  mov 24(%rdi), %r13
  mov 32(%rdi), %r14
  mov 40(%rdi), %r15
  mov 48(%rdi), %rsp
  mov 56(%rdi), %rdx
  mov $1, %eax
  jmp *%rdx
