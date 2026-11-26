extension CPU6502 {
    /// Runs `opcode` (fetched from `address`) on `operand`; `end` is the cycle
    /// it ends on, which a branch taken moves.
    func execute(_ opcode: Opcode, _ operand: Operand, at address: UInt16) throws {
        let mode = opcode.mode
        switch opcode.mnemonic {
        // Loads and stores
        case .lda: a = nz(load(operand))
        case .ldx: x = nz(load(operand))
        case .ldy: y = nz(load(operand))
        case .sta: store(a, operand)
        case .stx: store(x, operand)
        case .sty: store(y, operand)

        // Arithmetic and logic
        case .adc: isCMOS && isSet(Flag.decimal) ? addDecimalCMOS(load(operand)) : addWithCarry(load(operand))
        case .sbc: isCMOS && isSet(Flag.decimal) ? subtractDecimalCMOS(load(operand)) : subtractWithBorrow(load(operand))
        case .and: a = nz(a & load(operand))
        case .ora: a = nz(a | load(operand))
        case .eor: a = nz(a ^ load(operand))
        case .cmp: compare(a, load(operand))
        case .cpx: compare(x, load(operand))
        case .cpy: compare(y, load(operand))
        case .bit where mode == .immediate:     // 65C02: Z only
            set(Flag.zero, a & load(operand) == 0)
        case .bit:
            let value = load(operand)
            set(Flag.zero, a & value == 0)
            set(Flag.negative, value & 0x80 != 0)
            set(Flag.overflow, value & 0x40 != 0)

        // Shifts, rotations, increments and decrements
        case .asl: modify(mode, operand) { shiftLeft($0) }
        case .lsr: modify(mode, operand) { shiftRight($0) }
        case .rol: modify(mode, operand) { rotateLeft($0) }
        case .ror: modify(mode, operand) { rotateRight($0) }
        case .inc: modify(mode, operand) { nz($0 &+ 1) }
        case .dec: modify(mode, operand) { nz($0 &- 1) }
        case .inx: x = nz(x &+ 1)
        case .iny: y = nz(y &+ 1)
        case .dex: x = nz(x &- 1)
        case .dey: y = nz(y &- 1)

        // Register transfers
        case .tax: x = nz(a)
        case .tay: y = nz(a)
        case .txa: a = nz(x)
        case .tya: a = nz(y)
        case .tsx: x = nz(sp)
        case .txs: sp = x

        // Stack
        case .pha: push(a)
        case .php: push(p | Flag.brk | Flag.unused)
        case .pla: a = nz(pull())
        case .plp: p = pullStatus()

        // Jumps, subroutines and interrupts
        case .jmp: jump(to: operand.address)
        case .jsr: jumpToSubroutine()
        case .rts: returnFromSubroutine()
        case .rti:
            p = pullStatus()
            pc = pullWord()
        case .brk:
            pc &+= 1                            // skips the byte after BRK
            interrupt(through: 0xFFFE, pushing: p | Flag.brk | Flag.unused)

        // Branches
        case .bpl: branch(to: operand, if: !isSet(Flag.negative))
        case .bmi: branch(to: operand, if: isSet(Flag.negative))
        case .bvc: branch(to: operand, if: !isSet(Flag.overflow))
        case .bvs: branch(to: operand, if: isSet(Flag.overflow))
        case .bcc: branch(to: operand, if: !isSet(Flag.carry))
        case .bcs: branch(to: operand, if: isSet(Flag.carry))
        case .bne: branch(to: operand, if: !isSet(Flag.zero))
        case .beq: branch(to: operand, if: isSet(Flag.zero))

        // Flags
        case .clc: set(Flag.carry, false)
        case .sec: set(Flag.carry, true)
        case .cli: set(Flag.interrupt, false)
        case .sei: set(Flag.interrupt, true)
        case .cld: set(Flag.decimal, false)
        case .sed: set(Flag.decimal, true)
        case .clv: set(Flag.overflow, false)

        case .nop: if mode != .implied && !(isCMOS && opcode.byte == 0x5C) { _ = load(operand) }  // 65C02 $5C: no read, as AppleWin

        // 65C02
        case .bra: branch(to: operand, if: true)
        case .phx: push(x)
        case .phy: push(y)
        case .plx: x = nz(pull())
        case .ply: y = nz(pull())
        case .stz: store(0, operand)
        case .tsb: modify(mode, operand) { testBits($0); return $0 | a }
        case .trb: modify(mode, operand) { testBits($0); return $0 & ~a }

        // Undocumented (UndocumentedInstructions.swift)
        case .slo: a = nz(a | modify(mode, operand) { shiftLeft($0) })
        case .rla: a = nz(a & modify(mode, operand) { rotateLeft($0) })
        case .sre: a = nz(a ^ modify(mode, operand) { shiftRight($0) })
        case .rra: addWithCarry(modify(mode, operand) { rotateRight($0) })
        case .dcp: compare(a, modify(mode, operand) { $0 &- 1 })
        case .isc: subtractWithBorrow(modify(mode, operand) { $0 &+ 1 })
        case .lax: lax(operand)
        case .sax: store(a & x, operand)
        case .las: las(operand)
        case .sha: storeANDHighByte(a & x, operand)
        case .shx: storeANDHighByte(x, operand)
        case .shy: storeANDHighByte(y, operand)
        case .tas: tas(operand)
        case .anc: anc(operand)
        case .alr: alr(operand)
        case .arr: arr(operand)
        case .ane: ane(operand)
        case .lxa: lxa(operand)
        case .sbx: sbx(operand)
        case .jam:
            pc = address
            isJammed = true
            throw CPUError.jammed(at: address)
        }
    }

    /// TSB, TRB: Z = no bit of `value` set in A.
    func testBits(_ value: UInt8) {
        set(Flag.zero, a & value == 0)
    }

    /// JSR pushes the address of its own last byte (RTS adds 1) and jumps.  The
    /// 6502 reads the target's high byte only after the pushes, which can
    /// overwrite it (AppleWin GH#1257).  To a subroutine in `callTraps`, the
    /// JSR done, `onCall` decides what follows: the instructions it steps end
    /// on their own cycles, the JSR on the cycle it leaves.
    func jumpToSubroutine() {
        let low = fetch()
        pushWord(pc)
        pc = UInt16(read(pc)) << 8 | UInt16(low)
        if callTraps[Int(pc)] {
            cycles = end
            onCall(pc)
            end = cycles
        }
    }

    /// JMP.  To a subroutine in `jumpTraps` (a tail call), `onCall` decides
    /// what follows, as after a JSR: the JMP ends on the cycle it leaves.
    func jump(to address: UInt16) {
        pc = address
        if jumpTraps[Int(pc)] {
            cycles = end
            onCall(pc)
            end = cycles
        }
    }

    /// A branch taken takes a cycle more, two when it lands on another page
    /// than the next instruction's.
    func branch(to target: Operand, if condition: Bool) {
        guard condition else { return }
        end += target.address & 0xFF00 == pc & 0xFF00 ? 1 : 2
        pc = target.address
    }
}
