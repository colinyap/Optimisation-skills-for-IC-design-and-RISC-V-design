# selftest.s -- self-checking bringup program.
#
# Each block checks one thing and branches to `fail` on mismatch, so a failing
# run tells you which check broke without a debugger. Ends by writing 1 (pass)
# or 0 (fail) to the result MMIO register, which terminates the testbench.
#
#   python3 ../scripts/rv_model.py --asm selftest.s --hex selftest.hex

    # ---- ALU immediate ----------------------------------------------------
    li    t0, 5
    li    t1, 10
    add   t2, t0, t1
    li    t3, 15
    bne   t2, t3, fail

    sub   t2, t1, t0
    li    t3, 5
    bne   t2, t3, fail

    # ---- logic and shifts ---------------------------------------------------
    li    t0, 0xF0F0F0F0
    li    t1, 0x0F0F0F0F
    or    t2, t0, t1
    li    t3, 0xFFFFFFFF
    bne   t2, t3, fail

    and   t2, t0, t1
    bne   t2, x0, fail

    xor   t2, t0, t3
    bne   t2, t1, fail

    li    t0, 0x80000000
    srai  t2, t0, 4
    li    t3, 0xF8000000
    bne   t2, t3, fail            # SRA must fill with the sign bit

    srli  t2, t0, 4
    li    t3, 0x08000000
    bne   t2, t3, fail            # SRL must fill with zero

    # ---- signed vs unsigned compare -----------------------------------------
    li    t0, 0x80000000
    li    t1, 1
    slt   t2, t0, t1
    li    t3, 1
    bne   t2, t3, fail            # signed: 0x80000000 is negative, so less

    sltu  t2, t0, t1
    bne   t2, x0, fail            # unsigned: 0x80000000 is huge, so not less

    # ---- loads and stores, all widths and offsets ----------------------------
    li    s0, 0x10000000          # data memory base
    li    t0, 0xAABBCCDD
    sw    t0, 0(s0)
    lw    t1, 0(s0)
    bne   t1, t0, fail

    lbu   t1, 0(s0)
    li    t3, 0xDD
    bne   t1, t3, fail            # little-endian: low byte first

    lbu   t1, 3(s0)
    li    t3, 0xAA
    bne   t1, t3, fail

    lb    t1, 0(s0)
    li    t3, 0xFFFFFFDD
    bne   t1, t3, fail            # LB sign-extends

    lhu   t1, 2(s0)
    li    t3, 0xAABB
    bne   t1, t3, fail

    lh    t1, 2(s0)
    li    t3, 0xFFFFAABB
    bne   t1, t3, fail

    li    t0, 0x11
    sb    t0, 1(s0)               # byte store at a non-zero offset
    lw    t1, 0(s0)
    li    t3, 0xAABB11DD
    bne   t1, t3, fail            # only lane 1 may have changed

    # ---- branches, all six --------------------------------------------------
    li    t0, 5
    li    t1, 5
    beq   t0, t1, b1
    j     fail
b1: li    t1, 6
    bne   t0, t1, b2
    j     fail
b2: blt   t0, t1, b3
    j     fail
b3: bge   t1, t0, b4
    j     fail
b4: li    t0, 0xFFFFFFFF
    li    t1, 1
    bltu  t1, t0, b5              # unsigned: 1 < 0xFFFFFFFF
    j     fail
b5: blt   t0, t1, b6              # signed: -1 < 1
    j     fail
b6:

    # ---- jal / jalr and the link register -----------------------------------
    jal   ra, subr
    li    t3, 42
    bne   a0, t3, fail

    # ---- upper immediates ---------------------------------------------------
    lui   t0, 0xABCDE
    li    t3, 0xABCDE000
    bne   t0, t3, fail

    # ---- multiply extension --------------------------------------------------
    li    t0, 0xFFFFFFFF
    li    t1, 0xFFFFFFFF
    mul   t2, t0, t1
    li    t3, 1
    bne   t2, t3, fail            # (-1) * (-1) low half = 1

    mulh  t2, t0, t1
    bne   t2, x0, fail            # signed high half = 0

    mulhu t2, t0, t1
    li    t3, 0xFFFFFFFE
    bne   t2, t3, fail            # unsigned high half

    mulhsu t2, t0, t1
    li    t3, 0xFFFFFFFF
    bne   t2, t3, fail            # rs1 signed, rs2 unsigned -- the tricky one

    li    t0, 0x80000000
    li    t1, 0x80000000
    mulh  t2, t0, t1
    li    t3, 0x40000000
    bne   t2, t3, fail

    # ---- custom CRC extension ------------------------------------------------
    # CRC-32 over "123456789" must equal 0xCBF43926, the published check value.
    li    a0, 0xFFFFFFFF          # initial state
    li    a1, 0x34333231          # "1234" little-endian
    crc.w a0, a0, a1
    li    a1, 0x38373635          # "5678"
    crc.w a0, a0, a1
    li    a1, 0x39                # "9"
    crc.b a0, a0, a1
    not   a0, a0                  # final XOR
    li    t3, 0xCBF43926
    bne   a0, t3, fail

    # CRC.W must equal four chained CRC.B on the same bytes.
    li    a0, 0xFFFFFFFF
    li    a1, 0x34333231
    crc.w a0, a0, a1
    li    a2, 0xFFFFFFFF
    li    a3, 0x31
    crc.b a2, a2, a3
    li    a3, 0x32
    crc.b a2, a2, a3
    li    a3, 0x33
    crc.b a2, a2, a3
    li    a3, 0x34
    crc.b a2, a2, a3
    bne   a0, a2, fail

    # ---- a real loop: sum 1..10 ------------------------------------------------
    li    t0, 0
    li    t1, 1
    li    t2, 11
loop:
    add   t0, t0, t1
    addi  t1, t1, 1
    blt   t1, t2, loop
    li    t3, 55
    bne   t0, t3, fail

    # ---- AUIPC (PC-relative adder) and FENCE ----------------------------
    # Position-independent: check the delta between two AUIPCs, not absolutes.
    auipc t0, 0                 # t0 = PC_a
    auipc t1, 0                 # t1 = PC_a + 4
    sub   t2, t1, t0
    li    t3, 4
    bne   t2, t3, fail

    auipc t0, 1                 # t0 = PC_b + 0x1000
    auipc t1, 0                 # t1 = PC_b + 4
    sub   t2, t0, t1            # 0x1000 - 4
    li    t3, 0xFFC
    bne   t2, t3, fail

    fence                       # decoded, retires as a no-op
    li    t0, 0x5A5A
    fence
    li    t1, 0x5A5A
    bne   t0, t1, fail          # fence must not disturb architectural state

pass:
    li    t0, 0x20000000
    li    t1, 1
    sw    t1, 0(t0)
hang_p:
    j     hang_p

fail:
    li    t0, 0x20000000
    sw    x0, 0(t0)
hang_f:
    j     hang_f

subr:
    li    a0, 42
    ret
