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
    str wzr, [x1]
    mov x8, #0x7c7c
    mov x0, #0x6b6b
    ret
1:  mov x0, #0
    ret

.section __TEXT,__const
.globl _dm_net_test_packet
_dm_net_test_packet:
    .byte 0x15, 1, 2, 3
