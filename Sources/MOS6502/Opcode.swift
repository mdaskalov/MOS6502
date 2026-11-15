/// One of the 256 opcodes of a CPU variant: the instruction, where it finds
/// its operand and the cycles it takes (`table`, `table65C02`).
public struct Opcode: Sendable, Hashable, CustomStringConvertible {
    public let byte: UInt8
    public let mnemonic: Mnemonic
    public let mode: AddressingMode
    /// Cycles without the extras: +1 for an indexed read that crosses a page
    /// (`addsCycleOnPageCross`); a branch taken +1, +2 when it lands on another
    /// page; the 65C02's ADC and SBC +1 in decimal mode.
    public let cycles: Int
    /// False for the opcodes MOS didn't document (and the 65C02's unused
    /// ones, all NOPs).
    public let isDocumented: Bool
    /// The instruction takes a cycle more when its address crosses a page.
    /// The 6502: an indexed read (abs,X, abs,Y, (zp),Y) whose index carries
    /// into the address's high byte – it reads the address without the carry
    /// first and finds it wrong; writes and read-modify-writes always take
    /// that cycle, it's in `cycles`.  The 65C02 also for ASL, LSR, ROL and
    /// ROR abs,X, and for JMP ($xxFF) (as AppleWin).
    public let addsCycleOnPageCross: Bool

    init(_ byte: UInt8, _ mnemonic: Mnemonic, _ mode: AddressingMode, _ cycles: Int, documented: Bool = true,
         pageCross: Bool? = nil) {
        self.byte = byte
        self.mnemonic = mnemonic
        self.mode = mode
        self.cycles = cycles
        self.isDocumented = documented
        addsCycleOnPageCross = pageCross ?? (mnemonic.access == .read && mode.isIndexedAbsolute)
    }

    /// The NMOS 6502's opcode `byte`.
    public init(_ byte: UInt8) {
        self = Opcode.table[Int(byte)]
    }

    /// `variant`'s opcode `byte`.
    public init(_ byte: UInt8, _ variant: CPU6502.Variant) {
        self = Opcode.table(for: variant)[Int(byte)]
    }

    /// `variant`'s 256 opcodes, by byte.
    public static func table(for variant: CPU6502.Variant) -> [Opcode] {
        variant == .cmos65C02 ? table65C02 : table
    }

    /// Bytes of the instruction, the opcode included.
    public var length: Int { mode.length }

    /// "LDA abs,X", "JMP (ind)".
    public var description: String {
        let operand = switch mode {
        case .implied: ""
        case .accumulator: " A"
        case .immediate: " #imm"
        case .zeroPage: " zp"
        case .zeroPageX: " zp,X"
        case .zeroPageY: " zp,Y"
        case .absolute: " abs"
        case .absoluteX: " abs,X"
        case .absoluteY: " abs,Y"
        case .indirectX: " (zp,X)"
        case .indirectY: " (zp),Y"
        case .indirect: " (ind)"
        case .relative: " rel"
        case .zeroPageIndirect: " (zp)"
        case .absoluteIndexedIndirect: " (abs,X)"
        }
        return mnemonic.name + operand
    }
}
