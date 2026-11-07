extension CPU6502 {
    /// A, X, Y and P as a value, for Swift code that stands in for 6502 code
    /// (a routine trapped at its entry, `onTrap`): it takes the registers its
    /// callers pass parameters in and leaves them as the original does, a
    /// result in A or a flag to branch on.  The helpers set the flags as the
    /// instructions do (binary mode).
    public struct Registers: Equatable, Sendable {
        public var a: UInt8
        public var x: UInt8
        public var y: UInt8
        public var p: UInt8

        public init(a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0, p: UInt8 = Flag.unused) {
            (self.a, self.x, self.y, self.p) = (a, x, y, p)
        }

        public var carry: Bool {
            get { p & Flag.carry != 0 }
            set { set(Flag.carry, newValue) }
        }

        public var zero: Bool { p & Flag.zero != 0 }
        public var negative: Bool { p & Flag.negative != 0 }
        public var overflow: Bool { p & Flag.overflow != 0 }

        public mutating func set(_ flag: UInt8, _ on: Bool) {
            p = on ? p | flag : p & ~flag
        }

        /// N and Z as a load, transfer, INC/DEC or logic instruction leaves
        /// them; returns `v`.
        @discardableResult
        public mutating func nz(_ v: UInt8) -> UInt8 {
            set(Flag.zero, v == 0)
            set(Flag.negative, v & 0x80 != 0)
            return v
        }

        /// CMP, CPX, CPY: register `r` with `m`.
        public mutating func compare(_ r: UInt8, _ m: UInt8) {
            carry = r >= m
            nz(r &- m)
        }

        /// ADC (binary mode) with the carry as it is.
        public mutating func adc(_ a: UInt8, _ m: UInt8) -> UInt8 {
            let s = Int(a) + Int(m) + (carry ? 1 : 0)
            let r = UInt8(s & 0xFF)
            set(Flag.overflow, (a ^ r) & (m ^ r) & 0x80 != 0)
            carry = s > 0xFF
            return nz(r)
        }

        /// SBC (binary mode) with the carry as it is.
        public mutating func sbc(_ a: UInt8, _ m: UInt8) -> UInt8 {
            adc(a, ~m)
        }

        /// BIT: Z from A AND m, N and V from bits 7 and 6 of m.
        public mutating func bit(_ a: UInt8, _ m: UInt8) {
            set(Flag.zero, a & m == 0)
            set(Flag.negative, m & 0x80 != 0)
            set(Flag.overflow, m & 0x40 != 0)
        }
    }

    /// The carry through a chain of additions that doesn't touch the flags in
    /// between, `CLC / ADC / ADC …`: code that adds two constants in a row
    /// without clearing it.
    public struct Adder: Sendable {
        public private(set) var carry = false

        public init() {}

        public mutating func callAsFunction(_ a: UInt8, _ b: UInt8) -> UInt8 {
            let s = Int(a) + Int(b) + (carry ? 1 : 0)
            carry = s > 0xFF
            return UInt8(s & 0xFF)
        }
    }

    /// A, X, Y and P.
    public var registers: Registers {
        get { Registers(a: a, x: x, y: y, p: p) }
        set { (a, x, y, p) = (newValue.a, newValue.x, newValue.y, newValue.p) }
    }
}
