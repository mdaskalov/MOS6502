import Testing
@testable import MOS6502

/// A CPU with `code` at $0300, PC there.
private func cpu(_ code: [UInt8], at origin: Int = 0x0300, _ variant: CPU6502.Variant = .nmos6502) -> CPU6502 {
    var mem = [UInt8](repeating: 0, count: 0x10000)
    mem.replaceSubrange(origin ..< origin + code.count, with: code)
    let cpu = CPU6502(memory: mem, variant: variant)
    cpu.pc = UInt16(origin)
    return cpu
}

/// Cycles one instruction takes.
private func cycles(_ cpu: CPU6502) throws -> UInt64 {
    let start = cpu.cycles
    try cpu.step()
    return cpu.cycles - start
}

@Suite struct OpcodeTable {
    @Test func everyByteHasItsOpcode() {
        #expect(Opcode.table.count == 256)
        for (i, opcode) in Opcode.table.enumerated() { #expect(Int(opcode.byte) == i) }
        #expect(Opcode.table.filter(\.isDocumented).count == 151)
        #expect(Opcode.table.filter { $0.mnemonic == .jam }.count == 12)
    }

    @Test func pageCrossCycleOnlyForIndexedReads() {
        #expect(Opcode(0xBD).addsCycleOnPageCross)          // LDA abs,X
        #expect(Opcode(0xB1).addsCycleOnPageCross)          // LDA (zp),Y
        #expect(Opcode(0xBF).addsCycleOnPageCross)          // LAX abs,Y
        #expect(!Opcode(0x9D).addsCycleOnPageCross)         // STA abs,X
        #expect(!Opcode(0xFE).addsCycleOnPageCross)         // INC abs,X
        #expect(!Opcode(0xB5).addsCycleOnPageCross)         // LDA zp,X
        #expect(Opcode(0xBD).description == "LDA abs,X")
    }
}

@Suite struct Cycles {
    @Test func indexedReadCrossingAPage() throws {
        let c = cpu([0xBD, 0xFF, 0x20, 0xBD, 0x00, 0x20])  // LDA $20FF,X  LDA $2000,X
        c.x = 1
        #expect(try cycles(c) == 5)
        #expect(try cycles(c) == 4)
    }

    @Test func indexedWriteAlwaysTakesTheLongWay() throws {
        let c = cpu([0x9D, 0x00, 0x20])                     // STA $2000,X
        #expect(try cycles(c) == 5)
    }

    @Test func branches() throws {
        let c = cpu([0xD0, 0x01, 0xEA, 0xF0, 0x02, 0xD0, 0x7F], at: 0x03F8)
        c.p &= ~CPU6502.Flag.zero
        #expect(try cycles(c) == 3)                         // BNE taken, same page
        #expect(c.pc == 0x03FB)
        #expect(try cycles(c) == 2)                         // BEQ not taken
        #expect(try cycles(c) == 4)                         // BNE from $03FF to $047E
        #expect(c.pc == 0x047E)
    }

    @Test func accessesHappenOnTheirBusCycles() throws {
        let c = cpu([0xAD, 0x30, 0xC0, 0xEE, 0x30, 0xC0, 0x9D, 0x30, 0xC0])  // LDA $C030  INC $C030  STA $C030,X
        c.ioPages[0xC0] = true
        var accesses: [(String, UInt64)] = []
        c.ioRead = { _ in accesses.append(("read", c.cycles)); return 0 }
        c.ioWrite = { _, _ in accesses.append(("write", c.cycles)) }
        try c.step()
        try c.step()
        try c.step()
        #expect(accesses.map(\.0) == ["read", "read", "write", "write"])
        let expected: [UInt64] = [3, 4 + 3, 4 + 5, 10 + 4]  // LDA: its 4th cycle; INC: its 4th and 6th; STA: its 5th
        #expect(accesses.map(\.1) == expected)
        #expect(c.cycles == 15)
    }
}

@Suite struct Documented {
    @Test func jmpIndirectDoesNotCarryIntoThePointersHighByte() throws {
        let c = cpu([0x6C, 0xFF, 0x12])                     // JMP ($12FF)
        c.mem[0x12FF] = 0x34
        c.mem[0x1200] = 0x56
        c.mem[0x1300] = 0x99
        try c.step()
        #expect(c.pc == 0x5634)
    }

    @Test func zeroPageIndexingWraps() throws {
        let c = cpu([0xB5, 0xFF, 0xA1, 0xFF, 0xB1, 0xFF])   // LDA $FF,X  LDA ($FF,X)  LDA ($FF),Y
        c.x = 2
        c.mem[0x0001] = 0x00                                // $01: pointer to $4200
        c.mem[0x0002] = 0x42
        c.mem[0x4200] = 0x77
        try c.step()
        #expect(c.a == 0x00)
        try c.step()
        #expect(c.a == 0x77)
        c.mem[0x00FF] = 0x00                                // $FF: pointer to $4200, high byte from $00
        c.mem[0x0000] = 0x42
        c.y = 1
        c.mem[0x4201] = 0x88
        try c.step()
        #expect(c.a == 0x88)
    }

    @Test func decimalAddFlagsAreTheNMOSOnes() throws {
        let c = cpu([0xF8, 0x18, 0xA9, 0x99, 0x69, 0x01])   // SED  CLC  LDA #$99  ADC #$01
        for _ in 0 ..< 4 { try c.step() }
        #expect(c.a == 0x00)
        #expect(c.p & CPU6502.Flag.carry != 0)
        #expect(c.p & CPU6502.Flag.zero == 0)               // Z from the binary sum $9A
        #expect(c.p & CPU6502.Flag.negative != 0)           // N from $A0 before the high digit's fix
    }

    @Test func decimalSubtract() throws {
        let c = cpu([0xF8, 0x38, 0xA9, 0x10, 0xE9, 0x01])   // SED  SEC  LDA #$10  SBC #$01
        for _ in 0 ..< 4 { try c.step() }
        #expect(c.a == 0x09)
        #expect(c.p & CPU6502.Flag.carry != 0)
    }

    @Test func jsrAndRts() throws {
        let c = cpu([0x20, 0x00, 0x04])                     // JSR $0400
        c.mem[0x0400] = 0x60                                // RTS
        #expect(try cycles(c) == 6)
        #expect(c.pc == 0x0400)
        #expect(c.mem[0x01FF] == 0x03 && c.mem[0x01FE] == 0x02)
        #expect(try cycles(c) == 6)
        #expect(c.pc == 0x0303)
    }

    @Test func brkPushesBAndRtiReturnsPastItsByte() throws {
        let c = cpu([0x00, 0xEA, 0xEA])                     // BRK  (signature)  NOP
        c.mem[0xFFFE] = 0x00
        c.mem[0xFFFF] = 0x05
        c.mem[0x0500] = 0x40                                // RTI
        #expect(try cycles(c) == 7)
        #expect(c.pc == 0x0500)
        #expect(c.mem[0x01FD] & CPU6502.Flag.brk != 0)
        #expect(c.p & CPU6502.Flag.interrupt != 0)
        try c.step()
        #expect(c.pc == 0x0302)
        #expect(c.p & CPU6502.Flag.brk == 0)
    }

    @Test func stopsAtBRKWhenAsked() {
        let c = cpu([0x00])
        c.stopsAtBRK = true
        #expect(throws: CPU6502.CPUError.self) { try c.step() }
        #expect(c.pc == 0x0300)
    }

    @Test func irqWaitsForI() {
        let c = cpu([0xEA])
        c.mem[0xFFFE] = 0x00
        c.mem[0xFFFF] = 0x06
        #expect(!c.irq())
        c.p &= ~CPU6502.Flag.interrupt
        #expect(c.irq())
        #expect(c.pc == 0x0600)
        #expect(c.mem[0x01FD] & CPU6502.Flag.brk == 0)
    }
}

@Suite struct Undocumented {
    @Test func jamHaltsUntilReset() throws {
        let c = cpu([0x02])
        #expect(throws: CPU6502.CPUError.self) { try c.step() }
        #expect(c.isJammed && c.pc == 0x0300 && c.cycles == 2)
        c.reset()
        #expect(!c.isJammed)
    }

    @Test func dcpComparesTheWrappedByte() throws {
        let c = cpu([0xC7, 0x10])                           // DCP $10
        c.a = 0xFF
        try c.step()
        #expect(c.mem[0x10] == 0xFF)
        #expect(c.p & CPU6502.Flag.carry != 0)              // AppleWin: clear
        #expect(c.p & CPU6502.Flag.zero != 0)
    }

    @Test func iscSubtractsTheWrappedByte() throws {
        let c = cpu([0x38, 0xE7, 0x10])                     // SEC  ISC $10
        c.mem[0x10] = 0xFF
        c.a = 0x42
        try c.step()
        try c.step()
        #expect(c.mem[0x10] == 0x00)
        #expect(c.a == 0x42)
        #expect(c.p & CPU6502.Flag.carry != 0)              // AppleWin: clear
    }

    @Test func laxSaxSbx() throws {
        let c = cpu([0xA7, 0x10, 0x87, 0x11, 0xCB, 0x01])   // LAX $10  SAX $11  SBX #$01
        c.mem[0x10] = 0x8F
        try c.step()
        #expect(c.a == 0x8F && c.x == 0x8F && c.p & CPU6502.Flag.negative != 0)
        c.a = 0xF0
        try c.step()
        #expect(c.mem[0x11] == 0x80)
        try c.step()
        #expect(c.x == 0x7F && c.p & CPU6502.Flag.carry != 0)
    }

    @Test func shaPutsItsValueOnTheHighByteWhenCrossingAPage() throws {
        let c = cpu([0x9F, 0xF0, 0x12, 0x9F, 0x00, 0x12])   // SHA $12F0,Y  SHA $1200,Y
        (c.a, c.x, c.y) = (0xFF, 0x0F, 0x20)
        try c.step()
        #expect(c.mem[0x0310] == 0x03)                      // $0F AND $13 = $03, at $0310 not $1310
        try c.step()
        #expect(c.mem[0x1220] == 0x03)
    }

    @Test func arrInDecimalModeFixesByTheANDResult() throws {
        let c = cpu([0xF8, 0x18, 0xA9, 0xFF, 0x6B, 0x66])   // SED  CLC  LDA #$FF  ARR #$66
        for _ in 0 ..< 4 { try c.step() }
        // $66 >> 1 = $33; low digit 6 > 5: $39; high digit 6 > 5: $99, C set
        #expect(c.a == 0x99)
        #expect(c.p & CPU6502.Flag.carry != 0)
    }

    @Test func nopsReadTheirOperand() throws {
        let c = cpu([0x0C, 0x30, 0xC0, 0x1A])               // NOP $C030  NOP
        c.ioPages[0xC0] = true
        var reads = 0
        c.ioRead = { _ in reads += 1; return 0 }
        #expect(try cycles(c) == 4)
        #expect(try cycles(c) == 2)
        #expect(reads == 1)
    }
}

/// A 65C02 with `code` at $0300, PC there.
private func cmos(_ code: [UInt8]) -> CPU6502 {
    cpu(code, at: 0x0300, .cmos65C02)
}

@Suite struct CMOS65C02 {
    @Test func tableAgreesWithTheModes() {
        for (i, op) in Opcode.table65C02.enumerated() {
            #expect(Int(op.byte) == i)
            #expect(op.mnemonic != .jam)
            #expect(op.isDocumented || op.mnemonic == .nop)     // the unused opcodes are NOPs
        }
        #expect(Opcode(0x80, .cmos65C02).mnemonic == .bra)
        #expect(Opcode(0x80).mnemonic == .nop)
        #expect(Opcode(0xB2, .cmos65C02).description == "LDA (zp)")
        #expect(AddressingMode.absoluteIndexedIndirect.syntax(0x1234, next: 0) == "($1234,X)")
    }

    @Test func newInstructions() throws {
        // LDX #$12  PHX  PLY  STZ $10  LDA #$0F  TSB $11  TRB $12  INC A  BRA +1  BRK  DEC A
        let c = cmos([0xA2, 0x12, 0xDA, 0x7A, 0x64, 0x10, 0xA9, 0x0F, 0x04, 0x11, 0x14, 0x12, 0x1A, 0x80, 0x01, 0x00, 0x3A])
        c.mem[0x10] = 0x55
        c.mem[0x11] = 0xF0
        c.mem[0x12] = 0x3C
        for _ in 0 ..< 3 { try c.step() }
        #expect(c.y == 0x12)
        try c.step()
        #expect(c.mem[0x10] == 0)
        try c.step()
        try c.step()                                        // TSB: no bit in common, Z set
        #expect(c.mem[0x11] == 0xFF && c.p & CPU6502.Flag.zero != 0)
        try c.step()                                        // TRB: $0C in common
        #expect(c.mem[0x12] == 0x30 && c.p & CPU6502.Flag.zero == 0)
        try c.step()
        #expect(c.a == 0x10)
        #expect(try cycles(c) == 3)                         // BRA: always taken
        try c.step()
        #expect(c.a == 0x0F)
    }

    @Test func newModes() throws {
        // LDA ($20)  JMP ($0400,X)
        let c = cmos([0xB2, 0x20, 0x7C, 0x00, 0x04])
        c.mem[0x20] = 0x00
        c.mem[0x21] = 0x50
        c.mem[0x5000] = 0x42
        c.x = 4
        c.mem[0x404] = 0x34
        c.mem[0x405] = 0x12
        #expect(try cycles(c) == 5)
        #expect(c.a == 0x42)
        #expect(try cycles(c) == 6)
        #expect(c.pc == 0x1234)
    }

    @Test func jmpIndirectCarriesIntoThePointersHighByte() throws {
        let c = cmos([0x6C, 0xFF, 0x12])
        c.mem[0x12FF] = 0x34
        c.mem[0x1300] = 0x56
        c.mem[0x1200] = 0x99
        #expect(try cycles(c) == 7)
        #expect(c.pc == 0x5634)
    }

    @Test func bitImmediateSetsZOnly() throws {
        let c = cmos([0xA9, 0x01, 0x89, 0xC0])
        c.p |= CPU6502.Flag.negative
        try c.step()
        c.p |= CPU6502.Flag.overflow
        try c.step()
        #expect(c.p & CPU6502.Flag.zero != 0)
        #expect(c.p & CPU6502.Flag.overflow != 0)
    }

    @Test func decimalModeFlagsAreValidAndCostACycle() throws {
        // SED  CLC  LDA #$99  ADC #$01: $00, Z set, C set; 3 cycles
        let c = cmos([0xF8, 0x18, 0xA9, 0x99, 0x69, 0x01, 0x38, 0xA9, 0x00, 0xE9, 0x01])
        for _ in 0 ..< 3 { try c.step() }
        #expect(try cycles(c) == 3)
        #expect(c.a == 0x00 && c.p & CPU6502.Flag.zero != 0 && c.p & CPU6502.Flag.carry != 0)
        for _ in 0 ..< 2 { try c.step() }                   // SEC  LDA #$00  SBC #$01: $99, N set, C clear
        try c.step()
        #expect(c.a == 0x99 && c.p & CPU6502.Flag.negative != 0 && c.p & CPU6502.Flag.carry == 0)
    }

    @Test func brkAndInterruptsClearD() throws {
        let c = cmos([0xF8, 0x00])
        c.mem[0xFFFE] = 0x00
        c.mem[0xFFFF] = 0x40
        try c.step()
        try c.step()
        #expect(c.pc == 0x4000 && c.p & CPU6502.Flag.decimal == 0)
        #expect(c.mem[0x100 + Int(c.sp) + 1] & CPU6502.Flag.decimal != 0)    // pushed with D
        c.p |= CPU6502.Flag.decimal
        c.reset()
        #expect(c.p & CPU6502.Flag.decimal == 0)
    }

    @Test func shiftsAbsXCrossingAPageTakeACycleMore() throws {
        let c = cmos([0x1E, 0xFF, 0x20, 0xFE, 0xFF, 0x20])  // ASL $20FF,X  INC $20FF,X
        c.x = 1
        #expect(try cycles(c) == 7)
        #expect(try cycles(c) == 7)
        let n = cpu([0x1E, 0xFF, 0x20])
        n.x = 1
        #expect(try cycles(n) == 7)
        let same = cmos([0x1E, 0x00, 0x20])
        #expect(try cycles(same) == 6)
    }

    @Test func unusedOpcodesAreNOPs() throws {
        let c = cmos([0x03, 0x02, 0x00, 0x5C, 0x30, 0xC0, 0xDC, 0x30, 0xC0])
        c.ioPages[0xC0] = true
        var reads = 0
        c.ioRead = { _ in reads += 1; return 0 }
        #expect(try cycles(c) == 1)
        #expect(try cycles(c) == 2)
        #expect(try cycles(c) == 8)                         // $5C: no read
        #expect(try cycles(c) == 4)                         // $DC: reads
        #expect(reads == 1 && c.pc == 0x0309)
    }

    @Test func ioWritePagesTakeWritesOnly() throws {
        let c = cmos([0xAD, 0x00, 0x40, 0x8D, 0x01, 0x40])   // LDA $4000  STA $4001
        c.mem[0x4000] = 0x77
        c.ioWritePages[0x40] = true
        var written: [UInt16: UInt8] = [:]
        c.ioWrite = { written[$0] = $1 }
        try c.step()
        try c.step()
        #expect(c.a == 0x77 && written == [0x4001: 0x77] && c.mem[0x4001] == 0)
    }
}

/// `Registers`' helpers against the CPU running the instruction, for every
/// operand pair and incoming carry, with the other flags set and clear.
@Suite struct RegisterHelpers {
    /// Runs `opcode #m` with A = `a` and P = `p`; the registers it leaves.
    private static func run(_ c: CPU6502, _ opcode: UInt8, a: UInt8, m: UInt8, p: UInt8) throws -> CPU6502.Registers {
        (c.mem[0x0300], c.mem[0x0301], c.pc) = (opcode, m, 0x0300)
        c.registers = CPU6502.Registers(a: a, x: 0x11, y: 0x22, p: p)
        try c.step()
        return c.registers
    }

    /// Ps to start from: carry clear and set, the others all clear and all set
    /// (D clear: the helpers are binary mode).
    private static let starts: [UInt8] = [0x20, 0x21, 0xF6, 0xF7]

    private static func each(_ body: (UInt8, UInt8, UInt8) throws -> Void) rethrows {
        for p in starts { for a in 0 ... 255 { for m in 0 ... 255 { try body(UInt8(a), UInt8(m), p) } } }
    }

    @Test func adcAndSbc() throws {
        let c = cpu([])
        try Self.each { a, m, p in
            var r = CPU6502.Registers(a: a, x: 0x11, y: 0x22, p: p)
            r.a = r.adc(a, m)
            let adc = try Self.run(c, 0x69, a: a, m: m, p: p)            // ADC #m
            #expect(r == adc)
            r = CPU6502.Registers(a: a, x: 0x11, y: 0x22, p: p)
            r.a = r.sbc(a, m)
            let sbc = try Self.run(c, 0xE9, a: a, m: m, p: p)            // SBC #m
            #expect(r == sbc)
        }
    }

    @Test func compare() throws {
        let c = cpu([])
        try Self.each { a, m, p in
            var r = CPU6502.Registers(a: a, x: 0x11, y: 0x22, p: p)
            r.compare(a, m)
            let cmp = try Self.run(c, 0xC9, a: a, m: m, p: p)            // CMP #m
            #expect(r == cmp)
        }
    }

    @Test func bitAndLoad() throws {
        let c = cpu([])
        try Self.each { a, m, p in
            var r = CPU6502.Registers(a: a, x: 0x11, y: 0x22, p: p)
            r.bit(a, m)
            c.mem[0x0080] = m
            let bit = try Self.run(c, 0x24, a: a, m: 0x80, p: p)         // BIT $80
            #expect(r == bit)
            r = CPU6502.Registers(a: a, x: 0x11, y: 0x22, p: p)
            r.a = r.nz(m)
            let lda = try Self.run(c, 0xA9, a: a, m: m, p: p)            // LDA #m
            #expect(r == lda)
        }
    }

    @Test func adderCarriesThroughTheChain() {
        var add = CPU6502.Adder()
        #expect(add(0xF0, 0x20) == 0x10 && add.carry)
        #expect(add(0x01, 0x01) == 0x03 && !add.carry)                 // the carry in
    }
}

/// `callTraps`: `onCall` asked at a JSR to the subroutine, not where a branch
/// gets there.  $0300: `LDX #3 / JSR $0310 / RTS`; $0310: `DEX / BNE $0310 /
/// RTS`, branching back to its own start.
@Suite struct CallTraps {
    private func loop() -> CPU6502 {
        let c = cpu([0xA2, 0x03, 0x20, 0x10, 0x03, 0x60])
        c.mem.replaceSubrange(0x0310 ..< 0x0314, with: [0xCA, 0xD0, 0xFD, 0x60])
        c.callTraps[0x0310] = true
        return c
    }

    @Test func onlyTheJSR() throws {
        let c = loop()
        var calls: [UInt16] = []
        c.onCall = { calls.append($0) }
        try c.call(0x0300)
        #expect(calls == [0x0310] && c.x == 0)
        // LDX 2, JSR 6, (DEX 2 + BNE 3) x2, DEX 2 + BNE 2, RTS 6 (+ the call's RTS 6)
        #expect(c.cycles == 2 + 6 + 10 + 4 + 6 + 6)
    }

    @Test func runsTheSubroutineItself() throws {
        let c = loop()
        var after: UInt64 = 0
        c.onCall = { [unowned c] _ in
            #expect(c.cycles == 8 && c.pc == 0x0310 && c.sp == 0xFD - 2)
            while c.pc != 0x0305 { try? c.step() }
            after = c.cycles
        }
        c.sp = 0xFF
        c.pushWord(0xFFFE)
        c.pc = 0x0300
        while c.pc != 0xFFFF { try c.step() }
        #expect(after == 8 + 20 && c.cycles == after + 6 && c.x == 0)
    }

    @Test func skipsIt() throws {
        let c = loop()
        c.onCall = { [unowned c] _ in
            c.returnFromSubroutine()
            c.x = 0x42
            c.cycles += 1
        }
        try c.call(0x0300)
        #expect(c.x == 0x42 && c.cycles == 2 + 6 + 1 + 6)
    }

    /// $0320: `LDX #3 / JMP $0310`, a tail call: the subroutine returns to
    /// $0320's caller.
    private func tailCall() -> CPU6502 {
        let c = loop()
        c.mem.replaceSubrange(0x0320 ..< 0x0325, with: [0xA2, 0x03, 0x4C, 0x10, 0x03])
        return c
    }

    @Test func notAJMPByDefault() throws {
        let c = tailCall()
        var calls: [UInt16] = []
        c.onCall = { calls.append($0) }
        try c.call(0x0320)
        #expect(calls.isEmpty && c.x == 0)
    }

    @Test func aJMPToAJumpTrap() throws {
        let c = tailCall()
        c.jumpTraps[0x0310] = true
        var calls: [UInt16] = []
        c.onCall = { [unowned c] in
            // LDX 2, JMP 3: the JMP's cycles taken, the caller's return on the stack.
            #expect(c.cycles == 5 && c.pc == 0x0310 && c.sp == 0xFD)
            calls.append($0)
        }
        try c.call(0x0320)
        // Not the BNE back to its start.
        #expect(calls == [0x0310] && c.x == 0)
        // LDX 2, JMP 3, (DEX 2 + BNE 3) x2, DEX 2 + BNE 2, RTS 6
        #expect(c.cycles == 2 + 3 + 10 + 4 + 6)
    }

    @Test func aJMPRunsItItself() throws {
        let c = tailCall()
        c.jumpTraps[0x0310] = true
        c.onCall = { [unowned c] _ in
            c.returnFromSubroutine()
            c.x = 0x42
            c.cycles += 1
        }
        try c.call(0x0320)
        #expect(c.x == 0x42 && c.cycles == 2 + 3 + 1)
    }
}
