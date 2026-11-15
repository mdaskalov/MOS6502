/// The operations the documented and the undocumented instructions share.
extension CPU6502 {
    // MARK: shifts and rotations (C = the bit shifted out)

    func shiftLeft(_ value: UInt8) -> UInt8 {
        set(Flag.carry, value & 0x80 != 0)
        return nz(value << 1)
    }

    func shiftRight(_ value: UInt8) -> UInt8 {
        set(Flag.carry, value & 0x01 != 0)
        return nz(value >> 1)
    }

    func rotateLeft(_ value: UInt8) -> UInt8 {
        let c = carry
        set(Flag.carry, value & 0x80 != 0)
        return nz(value << 1 | c)
    }

    func rotateRight(_ value: UInt8) -> UInt8 {
        let c = carry
        set(Flag.carry, value & 0x01 != 0)
        return nz(value >> 1 | c << 7)
    }

    // MARK: arithmetic

    /// CMP, CPX, CPY: `register` - `value` without keeping it; C = no borrow.
    func compare(_ register: UInt8, _ value: UInt8) {
        set(Flag.carry, register >= value)
        nz(register &- value)
    }

    /// ADC: A + `value` + C.  In decimal mode the NMOS 6502 adds BCD digits but
    /// takes Z from the binary sum, and N and V from the sum before the high
    /// digit's decimal fix.
    func addWithCarry(_ value: UInt8) {
        let a = Int(self.a), v = Int(value), c = Int(carry)
        guard isSet(Flag.decimal) else {
            let sum = a + v + c
            set(Flag.carry, sum > 0xFF)
            set(Flag.overflow, (a ^ sum) & (v ^ sum) & 0x80 != 0)
            self.a = nz(UInt8(sum & 0xFF))
            return
        }
        var low = (a & 0x0F) + (v & 0x0F) + c
        if low > 0x09 { low += 0x06 }
        var sum = (a & 0xF0) + (v & 0xF0) + (low > 0x0F ? 0x10 : 0) + (low & 0x0F)
        set(Flag.zero, (a + v + c) & 0xFF == 0)
        set(Flag.negative, sum & 0x80 != 0)
        set(Flag.overflow, (a ^ sum) & (v ^ sum) & 0x80 != 0)
        if sum & 0x1F0 > 0x90 { sum += 0x60 }
        set(Flag.carry, sum & 0xFF0 > 0xF0)
        self.a = UInt8(sum & 0xFF)
    }

    /// SBC: A - `value` - (1 - C).  The flags are the binary difference's, in
    /// decimal mode too, where A gets the BCD difference.
    func subtractWithBorrow(_ value: UInt8) {
        let a = Int(self.a), v = Int(value), borrow = 1 - Int(carry)
        let difference = a - v - borrow
        set(Flag.carry, difference >= 0)
        set(Flag.overflow, (a ^ v) & (a ^ difference) & 0x80 != 0)
        nz(UInt8(truncatingIfNeeded: difference))
        guard isSet(Flag.decimal) else {
            self.a = UInt8(truncatingIfNeeded: difference)
            return
        }
        var low = (a & 0x0F) - (v & 0x0F) - borrow
        var high = (a & 0xF0) - (v & 0xF0)
        if low < 0 {
            low = (low - 0x06) & 0x0F
            high -= 0x10
        }
        if high < 0 { high -= 0x60 }
        self.a = UInt8(truncatingIfNeeded: high + low)
    }

    // MARK: the 65C02's decimal mode

    /// ADC in decimal mode on the 65C02: the BCD sum, N and Z from it, V and C
    /// as AppleWin works them out; a cycle more than in binary.
    func addDecimalCMOS(_ value: UInt8) {
        let a = Int(self.a), v = Int(value)
        var overflow = (a ^ v) & 0x80 == 0
        var sum = (a & 0x0F) + (v & 0x0F) + Int(carry)
        if sum >= 0x0A { sum = 0x10 | ((sum + 6) & 0x0F) }
        sum += (a & 0xF0) + (v & 0xF0)
        if sum >= 0xA0 {
            set(Flag.carry, true)
            if sum >= 0x180 { overflow = false }
            sum += 0x60
        } else {
            set(Flag.carry, false)
            if sum < 0x80 { overflow = false }
        }
        set(Flag.overflow, overflow)
        self.a = nz(UInt8(sum & 0xFF))
        end += 1
    }

    /// SBC in decimal mode on the 65C02: the BCD difference, N and Z from it,
    /// V and C as AppleWin works them out; a cycle more than in binary.
    func subtractDecimalCMOS(_ value: UInt8) {
        let a = Int(self.a), v = Int(value)
        var overflow = (a ^ v) & 0x80 != 0
        var low = 0x0F + (a & 0x0F) - (v & 0x0F) + Int(carry)
        var difference: Int
        if low < 0x10 {
            difference = 0
            low -= 0x06
        } else {
            difference = 0x10
            low -= 0x10
        }
        difference += 0xF0 + (a & 0xF0) - (v & 0xF0)
        if difference < 0x100 {
            set(Flag.carry, false)
            if difference < 0x80 { overflow = false }
            difference -= 0x60
        } else {
            set(Flag.carry, true)
            if difference >= 0x180 { overflow = false }
        }
        set(Flag.overflow, overflow)
        self.a = nz(UInt8((difference + low) & 0xFF))
        end += 1
    }
}
