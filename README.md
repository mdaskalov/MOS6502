# MOS6502

The NMOS 6502 of the Apple II and //e, and the 65C02 of the enhanced //e, as
AppleWin (and so Mariani) runs them, in Swift: all 256 opcodes of each, the
6502's undocumented ones included, with their cycle counts.

```swift
let cpu = CPU6502(memory: ram)              // 64K, the NMOS 6502
let cmos = CPU6502(memory: ram, variant: .cmos65C02)
cpu.ioPages[0xC0] = true                    // $C000-$C0FF go to ioRead/ioWrite
cpu.ioWritePages[0x20] = true               // $2000-$20FF: writes to ioWrite, reads from mem
cpu.ioRead = { address in … }
cpu.ioWrite = { address, value in … }
cpu.watchedPages[0x20] = true               // $2000-$20FF written as ever, then told:
cpu.onWrite = { address, old, new in … }
cpu.pc = 0x0800
try cpu.step()                              // one instruction
try cpu.call(0x6000)                        // JSR and run until it returns
```

## Files

| File | What |
|---|---|
| `OpcodeTable.swift` | the 6502's 256 opcodes as `Opcode` values: byte, mnemonic, addressing mode, cycles, documented or not |
| `OpcodeTable65C02.swift` | the 65C02's, generated from AppleWin's `cpu65C02.h` |
| `Opcode.swift` | `Opcode`: length, the page‑crossing rule, `Opcode(0xBD)`, `Opcode(0x80, .cmos65C02)` |
| `Mnemonic.swift` | what each instruction does, AppleWin's names for the undocumented ones, how it uses its operand (`Access`) |
| `AddressingMode.swift` | the 15 modes (the 65C02's `(zp)` and `(abs,X)` among them), their length and assembly syntax |
| `CPU6502.swift` | the variant, registers, memory, I/O, write‑only I/O and watched pages, traps, call traps, `step`, `call`, reset, IRQ, NMI |
| `Addressing.swift` | finding the operand, and reading/writing it on the 6502's cycles |
| `Instructions.swift` | `execute`: every instruction, one line each where it can be |
| `UndocumentedInstructions.swift` | the undocumented ones that need more than a line |
| `Arithmetic.swift` | shifts, compare, ADC/SBC with the NMOS and the 65C02 decimal mode |
| `Flag.swift` | the status bits |
| `Registers.swift` | `Registers` (A, X, Y, P as a value, with the flags of LDA, CMP, ADC, SBC, BIT) and `Adder`, for Swift standing in for 6502 code |

## Swift in place of 6502 code

A host can trap a routine's entry (`traps`, `onTrap`) and run Swift there
instead. `cpu.registers` hands it A, X, Y and P as a value, and the helpers
leave the flags as the instructions do (binary mode), so its callers find them
as the original leaves them:

```swift
cpu.traps[0x6000] = true
cpu.onTrap = { pc in
    var r = cpu.registers
    r.a = r.adc(r.a, cpu.mem[0x80])         // ADC $80
    r.compare(r.a, 0x40)                    // CMP #$40
    cpu.registers = r
    cpu.returnFromSubroutine()              // RTS
    return true
}
```

`Adder` carries through `CLC / ADC / ADC …` where nothing in between touches
the flags.

A trap at the entry also stops a branch or a JMP back to the routine's
start.  `callTraps` and `onCall` stop only a JSR to it: `onCall` gets the
address after the JSR's pushes and cycles, and may step the routine to its
RTS itself, set the registers, PC and `cycles`, or leave them for the
routine to run as ever:

```swift
cpu.callTraps[0x6000] = true
cpu.onCall = { _ in
    let sp = cpu.sp &+ 2                    // the caller's, after the RTS
    let back = (UInt16(cpu.mem[0x101 + Int(cpu.sp)]) | UInt16(cpu.mem[0x102 + Int(cpu.sp)]) << 8) &+ 1
    // … before
    while !(cpu.pc == back && cpu.sp == sp) { try? cpu.step() }
    // … after
}
```

## Cycles

`Opcode.cycles` is the count without extras; on top, as on the chip:

* +1 for an indexed read (abs,X, abs,Y, (zp),Y) whose index crosses a page.
  Writes and read‑modify‑writes always take that cycle, it is in their count
  (`Opcode.addsCycleOnPageCross` follows from `Mnemonic.access`).
* +1 for a branch taken, +1 more when it lands on another page than the
  next instruction's.

`cpu.cycles` counts on. Between instructions it is the cycle the next one
starts on. While an instruction runs, a read or write sees the cycle the
6502 makes it on: the instruction's last for reads and writes; a
read‑modify‑write (INC, ASL, …, DCP, ISC, …) reads three cycles before its
end and writes on its last. `LDA $C030` at cycle 1000 reads the speaker at
1003, `INC $C030` reads at 1003 and writes at 1005. (AppleWin hands its I/O
handlers the cycle the instruction starts on; the distances between accesses
of the same kind are the same.)

Each instruction makes the accesses its operation needs – one read, one write,
or a read then a write – and, as AppleWin, none of the 6502's dummy accesses
(the read at the unfixed address of an index crossing a page, the old value
written back by a read‑modify‑write).

## The 65C02

`CPU6502(memory:, variant: .cmos65C02)` runs the 65C02 of the enhanced //e
(the NCR/GTE chip: no RMB, SMB, BBR, BBS, which are Rockwell's and WDC's),
from AppleWin's `cpu65C02.h`:

* new instructions: BRA, PHX, PHY, PLX, PLY, STZ, TSB, TRB, INC A, DEC A,
  BIT #imm (Z only), BIT zp,X and abs,X; new modes: `(zp)` and `JMP (abs,X)`;
* `JMP ($xxFF)` takes its high byte from the next page (no NMOS bug), a
  cycle more then (6 or 7);
* decimal mode: N, Z and V from the BCD result, a cycle more for ADC and SBC;
* BRK, IRQ, NMI and RESET clear D;
* ASL, LSR, ROL, ROR abs,X: 6 cycles, 7 crossing a page (INC and DEC
  abs,X 7 always);
* the 6502's undocumented opcodes are NOPs, as AppleWin has them: $x3,
  $x7, $xB, $xF one byte and one cycle; $x2 with an immediate operand;
  $44, $54, $D4, $F4 with a zero‑page operand; $DC and $FC read an absolute
  operand (4 cycles), $5C doesn't (8 cycles). Nothing jams.

`Opcode(byte)` is the 6502's opcode, `Opcode(byte, .cmos65C02)` the
65C02's (`Opcode.table65C02`), for disassembling.

## Undocumented opcodes

They run as on the chip; AppleWin names differ for several
(`Mnemonic.swift`): SLO (ASO), RLA, SRE (LSE), RRA, SAX (AXS), LAX, DCP (DCM),
ISC (INS), ANC, ALR, ARR, ANE (XAA), LXA (OAL), SBX (SAX), SHA (AXA), SHX
(XAS), SHY (SAY), TAS, LAS, the NOPs with operands (they read it) and JAM
(HLT). A JAM halts the CPU: `step` throws `CPUError.jammed` and PC stays on
it until `reset`. ANE and LXA mix in a constant that varies between chips;
these take AppleWin's ($FF and $EE).

## Where it differs from AppleWin

The results are the 6502's where AppleWin's differ from it:

| Opcodes | 6502 | AppleWin |
|---|---|---|
| DCP | DEC of $00 is $FF, compared with A = $FF: C set | keeps 16 bits, compares with $FFFF: C clear |
| ISC | INC of $FF is $00, subtracted: C set unless A − borrow < 0 | subtracts $100: C clear |
| ARR in decimal mode | the digit fixes are decided on the AND result | decided on the rotated value |
| NOP with an operand | reads it (a soft switch there switches) | doesn't |

BRK runs as on the chip (pushes, I, the vector at $FFFE) unless `stopsAtBRK`
is set: then `step` throws `CPUError.brk`, for hosts with no ROM behind the
vector. B is never set in `p`, only in the copy PHP and BRK push.

## Checks

* `swift test`: the table, cycles and bus cycles, decimal mode, the JMP
  ($xxFF) bug, BRK/RTI/IRQ, JAM, the undocumented edge cases.
* Against AppleWin's own code: `Data/cpu_check.sh path/to/AppleWin [N]`
  builds AppleWin's `cpu6502.h` and `cpu65C02.h` (from the checkout,
  with a small shim) and runs N random instructions of every opcode on both
  (random registers, flags, PC, operands, memory), comparing registers,
  flags, cycles, the jam and every byte written, for the 6502 and then the
  65C02. 10,000 of each (2.56 M a variant): identical but for the table
  above, and on the 65C02 `JMP ($FFFF)` and `JMP ($FFxx,X)` past $FFFF,
  where the pointer's next byte is $0000 and AppleWin reads past its 64K.
* The opcodes that differ, and the store/load ones with odd high‑byte
  behaviour (SHA, SHX, SHY, TAS, LAS, LXA), were run on Tom Harte's
  SingleStepTests (6502 v1, from real chip behaviour, 10,000 cases each):
  all identical, cycle counts included, but ANE, where those take $EE.
