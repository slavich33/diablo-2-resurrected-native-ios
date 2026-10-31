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
