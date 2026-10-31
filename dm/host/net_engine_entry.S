// Exact prologue continuations for the optional 3.3.94012 queue-entry cuts.
// x16 is the original body at entry+8; x8 remains the hidden receive output.
// No generated code, executable-memory writes, or guest vtable mutation.
.text
.p2align 2
.globl _dm_net_resume_poll
_dm_net_resume_poll:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    br x16

.p2align 2
.globl _dm_net_resume_send
_dm_net_resume_send:
    str x23, [sp, #-64]!
    stp x22, x21, [sp, #16]
    br x16
