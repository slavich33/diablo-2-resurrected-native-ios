.text
.p2align 2
.globl _dm_net_test_send
_dm_net_test_send:
    mov x9, #0x1234
    cmp x0, x9
    b.ne 1f
    ldp x9, x10, [x1]
    sub x10, x10, x9
    cmp x10, #4
    b.ne 1f
    ldrb w10, [x9]
    cmp w10, #0x3c
    b.ne 1f
    mov x0, #0x5a5a
    mov x8, #0x7c7c
    ret
1:  mov x0, #0
    ret

// Independent bodies for queue entries after their first two instructions.
// The native continuation must supply those instructions' stack frame.
.p2align 2
.globl _dm_net_test_receive_body
_dm_net_test_receive_body:
    adrp x9, _dm_net_test_packet@PAGE
    add x9, x9, _dm_net_test_packet@PAGEOFF
    add x10, x9, #4
    stp x9, x10, [x8]
    mov w9, #1
    strb w9, [x8, #16]
    str xzr, [x1]
    mov x8, #0x7c7c
    mov x0, #0x6b6b
    ldp x29, x30, [sp], #16
    ret

.p2align 2
.globl _dm_net_test_send_body
_dm_net_test_send_body:
    stp x20, x19, [sp, #32]
    stp x29, x30, [sp, #48]
    mov x29, sp
    mov x19, #0x1234
    cmp x0, x19
    b.ne 1f
    ldp x21, x22, [x1]
    sub x23, x22, x21
    cmp x23, #4
    b.ne 1f
    mov x0, #0x5a5a
    b 2f
1:  mov x0, #0
2:  ldp x29, x30, [sp, #48]
    ldp x20, x19, [sp, #32]
    ldp x22, x21, [sp, #16]
    ldr x23, [sp], #64
    ret

.p2align 2
.globl _dm_net_test_receive
_dm_net_test_receive:
    mov x9, #0x1234
    cmp x0, x9
    b.ne 1f
    adrp x9, _dm_net_test_packet@PAGE
    add x9, x9, _dm_net_test_packet@PAGEOFF
    add x10, x9, #4
    stp x9, x10, [x8]
    mov w9, #1
    strb w9, [x8, #16]
    str xzr, [x1]
    mov x8, #0x7c7c
    mov x0, #0x6b6b
    ret
1:  mov x0, #0
    ret

.section __TEXT,__const
.globl _dm_net_test_packet
_dm_net_test_packet:
    .byte 0x15, 1, 2, 3

.text
.p2align 2
.globl _dm_net_test_connected_body
_dm_net_test_connected_body:
    mov x0, #7
    ldp x29, x30, [sp, #16]
    ldp x20, x19, [sp], #32
    ret

// Exact remaining leaf layout: the zero-byte path must skip two instructions.
.p2align 2
.globl _dm_net_test_failed_body
_dm_net_test_failed_body:
    mov w0, #1
    ret
    ldr w8, [x0, #0x14]
    cmp w8, #0
    cset w0, eq
    ret

.p2align 2
.globl _dm_net_test_hard_close_body
_dm_net_test_hard_close_body:
    cset w0, eq
    ret

.p2align 2
.globl _dm_net_test_graceful_close_body
_dm_net_test_graceful_close_body:
    stp x20, x19, [sp, #0x30]
    stp x29, x30, [sp, #0x40]
    mov x0, #0x42
    ldp x29, x30, [sp, #0x40]
    ldp x20, x19, [sp, #0x30]
    ldp x22, x21, [sp, #0x20]
    add sp, sp, #0x50
    ret

// Independent branch-gate fixture. The production rewriter's key-page lookup
// is checked by structck; here a direct address reaches the REAL full dm_gate.
// All nine arguments, original x8, NZCV, SP and caller LR must survive it.
.p2align 2
.macro NET_TEST_GUARD
    cmp xzr, xzr
    mov x8, #0xaaaa
    stp x8, xzr, [sp, #-16]!
    stp x29, x30, [sp, #-16]!
    adrp x30, _dm_gate@PAGE
    add x30, x30, _dm_gate@PAGEOFF
    blr x30
    ldp x29, x30, [sp], #16
    cbz w8, 1f
    ldp x8, xzr, [sp], #16
    ret
1:  ldp x8, xzr, [sp], #16
.endm
.globl _dm_net_test_connect_gate
_dm_net_test_connect_gate:
    NET_TEST_GUARD
    stp x28, x27, [sp, #-0x60]!
    b.ne 2f
    mov x9, #0xaaaa
    cmp x8, x9
    b.ne 2f
    add x0, x0, x1
    add x0, x0, x2
    add x0, x0, x3
    add x0, x0, x4
    add x0, x0, x5
    add x0, x0, x6
    add x0, x0, x7
    ldr x9, [sp, #0x60]
    add x0, x0, x9
    b 3f
2:  mov x0, #0
3:  ldp x28, x27, [sp], #0x60
    ret

.p2align 2
.globl _dm_net_test_start_gate
_dm_net_test_start_gate:
    NET_TEST_GUARD
    sub sp, sp, #0x40
    b.ne 2f
    mov x9, #0xaaaa
    cmp x8, x9
    b.ne 2f
    add x0, x0, x1
    add x0, x0, x2
    add x0, x0, x3
    add x0, x0, x4
    add x0, x0, x5
    add x0, x0, x6
    add x0, x0, x7
    ldr x9, [sp, #0x40]
    add x0, x0, x9
    b 3f
2:  mov x0, #0
3:  add sp, sp, #0x40
    ret

// Startup gate resumes this displaced STP only on unbound/prepared inputs.
.p2align 2
.globl _dm_net_test_bootstrap_gate
_dm_net_test_bootstrap_gate:
    NET_TEST_GUARD
    stp x28, x23, [sp, #-0x40]!
    b.ne 2f
    mov x9, #0xaaaa
    cmp x8, x9
    b.ne 2f
    add x0, x0, x1
    add x0, x0, x2
    add x0, x0, x3
    add x0, x0, x4
    add x0, x0, x5
    add x0, x0, x6
    add x0, x0, x7
    ldr x9, [sp, #0x40]
    add x0, x0, x9
    b 3f
2:  mov x0, #0
3:  ldp x28, x23, [sp], #0x40
    ret
