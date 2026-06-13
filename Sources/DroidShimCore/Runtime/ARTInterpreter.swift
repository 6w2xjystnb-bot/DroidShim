//
//  ARTInterpreter.swift
//  DroidShimCore
//
//  Register-based Dalvik bytecode interpreter.  Phase 1 runs in a single
//  thread with no JIT.  It executes the subset of opcodes required for
//  simple Android activities with TextView / Button onClick handlers.
//

import Foundation

/// Errors thrown by the interpreter.
public enum ARTError: Error, CustomStringConvertible {
    case invalidProgramCounter
    case unknownOpcode(UInt8)
    case divByZero
    case methodNotFound(String)
    case classNotFound(String)
    case fieldNotFound(String)
    case invalidInvokeKind(String)
    case unimplemented(String)

    public var description: String {
        switch self {
        case .invalidProgramCounter: return "Invalid program counter"
        case .unknownOpcode(let op): return "Unknown opcode 0x\(String(op, radix: 16))"
        case .divByZero: return "Division by zero"
        case .methodNotFound(let m): return "Method not found: \(m)"
        case .classNotFound(let c): return "Class not found: \(c)"
        case .fieldNotFound(let f): return "Field not found: \(f)"
        case .invalidInvokeKind(let k): return "Invalid invoke kind: \(k)"
        case .unimplemented(let u): return "Unimplemented: \(u)"
        }
    }
}

/// A Dalvik interpreter frame.
public final class Frame {
    public var registers: [UInt32]
    public var returnFrame: Frame?
    public var method: DexMethod
    public var pc: Int = 0

    public init(method: DexMethod, returnFrame: Frame? = nil) {
        self.method = method
        self.returnFrame = returnFrame
        let code = method.code ?? DexCodeItem(registersSize: 0, insSize: 0, outsSize: 0, triesSize: 0, debugInfoOff: 0, insnsSize: 0, insns: [])
        self.registers = Array(repeating: 0, count: Int(code.registersSize))
    }
}

/// A single interpreted thread.
public final class ARTThread {
    public var frames: [Frame] = []
    public var exception: JavaObject?
}

/// Dalvik interpreter.  One instance per loaded DEX file.
public final class ARTInterpreter {
    public let dex: DexFile
    public private(set) var loadedClasses: [String: DexClassDef] = [:]

    /// Static field storage keyed by fully-qualified field name.
    public var staticFields: [String: JavaValue] = [:]

    /// Optional bridge to the UIKit layer for framework View calls.
    public weak var uiBridge: ARTUIBridge?

    public init(dex: DexFile) {
        self.dex = dex
        indexClasses()
    }

    private func indexClasses() {
        for def in dex.classDefs {
            let name = dex.className(at: def.classIdx)
            loadedClasses[name] = def
        }
    }

    // MARK: - Instruction decoding helpers

    private func s4(_ value: UInt32) -> Int32 {
        let v = value & 0xf
        return v & 0x8 != 0 ? Int32(v | 0xfffffff0) : Int32(v)
    }

    private func s8(_ value: UInt32) -> Int32 {
        let v = value & 0xff
        return v & 0x80 != 0 ? Int32(v | 0xffffff00) : Int32(v)
    }

    private func s16(_ value: UInt32) -> Int32 {
        let v = value & 0xffff
        return v & 0x8000 != 0 ? Int32(v | 0xffff0000) : Int32(v)
    }

    private func u16pair(_ low: UInt16, _ high: UInt16) -> UInt32 {
        return (UInt32(high) << 16) | UInt32(low)
    }

    // MARK: - Execution entry point

    /// Start execution at the given method.
    public func execute(method: DexMethod, args: [JavaValue] = []) throws -> JavaValue {
        let frame = Frame(method: method)
        // Copy args into the end of the register file (Dalvik calling convention).
        guard frame.registers.count >= args.count else {
            throw ARTError.unimplemented("Method register file too small for argument count")
        }
        var regIdx = frame.registers.count - args.count
        for arg in args {
            switch arg {
            case .int(let v):
                frame.registers[regIdx] = UInt32(bitPattern: v)
                regIdx += 1
            case .object(let obj):
                frame.registers[regIdx] = JavaHeap.shared.reference(for: obj)
                regIdx += 1
            default:
                regIdx += 1
            }
        }
        return try run(frame: frame)
    }

    private func run(frame: Frame) throws -> JavaValue {
        let thread = ARTThread()
        thread.frames.append(frame)

        while !thread.frames.isEmpty {
            let current = thread.frames.last!
            guard let code = current.method.code else {
                return .void
            }
            let insns = code.insns

            if current.pc >= insns.count {
                thread.frames.removeLast()
                continue
            }

            let inst = insns[current.pc]
            let op = UInt8(inst & 0xff)
            let a = UInt8((inst >> 8) & 0xf)
            let b = UInt8((inst >> 12) & 0xf)

            // Helper to advance PC.
            func advance(_ n: Int) { current.pc += n }

            switch op {
            case 0x00: // nop
                advance(1)

            case 0x01: // move vA, vB
                let vA = UInt32(a)
                let vB = UInt32(b)
                current.registers[Int(vA)] = current.registers[Int(vB)]
                advance(1)

            case 0x02: // move/from16 vAAAA, vBBBB
                let vA = UInt32(insns[current.pc + 1])
                let vB = UInt32(insns[current.pc + 2])
                current.registers[Int(vA)] = current.registers[Int(vB)]
                advance(3)

            case 0x03: // move/16 vAAAA, vBBBB
                let vA = UInt32(insns[current.pc + 1])
                let vB = UInt32(insns[current.pc + 2])
                current.registers[Int(vA)] = current.registers[Int(vB)]
                advance(3)

            case 0x04: // move-wide vA, vB
                let vA = Int(a)
                let vB = Int(b)
                current.registers[vA] = current.registers[vB]
                current.registers[vA + 1] = current.registers[vB + 1]
                advance(1)

            case 0x07: // move-object vA, vB
                let vA = Int(a)
                let vB = Int(b)
                current.registers[vA] = current.registers[vB]
                advance(1)

            case 0x0a: // const/4 vA, #+B
                let vA = Int(a)
                current.registers[vA] = UInt32(bitPattern: s4(UInt32(b)))
                advance(1)

            case 0x0b: // const/16 vAA, #BBBB
                let vA = Int(inst >> 8)
                current.registers[vA] = UInt32(bitPattern: s16(UInt32(insns[current.pc + 1])))
                advance(2)

            case 0x0c: // const vAA, #BBBBBBBB
                let vA = Int(inst >> 8)
                let value = u16pair(insns[current.pc + 1], insns[current.pc + 2])
                current.registers[vA] = value
                advance(3)

            case 0x0d: // const/high16 vAA, #BBBB0000
                let vA = Int(inst >> 8)
                let high = UInt32(insns[current.pc + 1]) << 16
                current.registers[vA] = high
                advance(2)

            case 0x1a: // const-string vAA, string@BBBB
                let vA = Int(inst >> 8)
                let stringIdx = insns[current.pc + 1]
                let text = dex.strings[Int(stringIdx)].raw
                let obj = JavaHeap.shared.allocate(className: "java.lang.String")
                obj.fields["__value"] = text
                current.registers[vA] = JavaHeap.shared.reference(for: obj)
                advance(2)

            case 0x1b: // const-string/jumbo vAA, string@BBBBBBBB
                let vA = Int(inst >> 8)
                let stringIdx = u16pair(insns[current.pc + 1], insns[current.pc + 2])
                let text = dex.strings[Int(stringIdx)].raw
                let obj = JavaHeap.shared.allocate(className: "java.lang.String")
                obj.fields["__value"] = text
                current.registers[vA] = JavaHeap.shared.reference(for: obj)
                advance(3)

            case 0x0e: // return-void
                thread.frames.removeLast()

            case 0x0f: // return vAA
                let vA = Int(inst >> 8)
                let value = JavaValue.int(Int32(bitPattern: current.registers[vA]))
                thread.frames.removeLast()
                if thread.frames.isEmpty { return value }
                if let parent = current.returnFrame {
                    // Place return in parent result register (v0 by convention).
                    parent.registers[0] = current.registers[vA]
                }

            case 0x10: // return-wide vAA
                let vA = Int(inst >> 8)
                thread.frames.removeLast()
                if let parent = current.returnFrame {
                    parent.registers[0] = current.registers[vA]
                    parent.registers[1] = current.registers[vA + 1]
                }

            case 0x11: // return-object vAA
                let vA = Int(inst >> 8)
                thread.frames.removeLast()
                if let parent = current.returnFrame {
                    parent.registers[0] = current.registers[vA]
                }

            case 0x28: // goto +AA
                current.pc += Int(s8(UInt32(a)))

            case 0x29: // goto/16 +AAAA
                current.pc += Int(s16(UInt32(insns[current.pc + 1])))

            case 0x2a: // goto/32 +AAAAAAAA
                let offset = u16pair(insns[current.pc + 1], insns[current.pc + 2])
                current.pc += Int(Int32(bitPattern: offset)) // signed 32-bit

            case 0x2b: // if-eq vA, vB, +CCCC
                fallthrough
            case 0x2c, 0x2d, 0x2e, 0x2f, 0x30:
                let vA = Int(a)
                let vB = Int(b)
                let c = s16(UInt32(insns[current.pc + 1]))
                let lhs = Int32(bitPattern: current.registers[vA])
                let rhs = Int32(bitPattern: current.registers[vB])
                var taken = false
                switch op {
                case 0x2b: taken = (lhs == rhs)
                case 0x2c: taken = (lhs != rhs)
                case 0x2d: taken = (lhs < rhs)
                case 0x2e: taken = (lhs >= rhs)
                case 0x2f: taken = (lhs > rhs)
                case 0x30: taken = (lhs <= rhs)
                default: break
                }
                current.pc += taken ? Int(c) : 2

            case 0x32: // if-eqz vAA, +BBBB
                fallthrough
            case 0x33, 0x34, 0x35, 0x36, 0x37:
                let vA = Int(inst >> 8)
                let c = s16(UInt32(insns[current.pc + 1]))
                let val = Int32(bitPattern: current.registers[vA])
                var taken = false
                switch op {
                case 0x32: taken = (val == 0)
                case 0x33: taken = (val != 0)
                case 0x34: taken = (val < 0)
                case 0x35: taken = (val >= 0)
                case 0x36: taken = (val > 0)
                case 0x37: taken = (val <= 0)
                default: break
                }
                current.pc += taken ? Int(c) : 2

            case 0x22: // new-instance vAA, type@BBBB
                let vA = Int(inst >> 8)
                let typeIdx = insns[current.pc + 1]
                let className = dex.className(at: UInt32(typeIdx))
                let obj = JavaHeap.shared.allocate(className: className)
                current.registers[vA] = JavaHeap.shared.reference(for: obj)
                advance(2)

            case 0x23: // new-array vAA, vBB, type@CCCC
                let vA = Int(a)
                let vB = Int(b)
                let typeIdx = insns[current.pc + 1]
                let className = dex.className(at: UInt32(typeIdx))
                let length = Int(Int32(bitPattern: current.registers[vB]))
                let obj = JavaHeap.shared.allocateArray(className: className, length: length)
                current.registers[vA] = JavaHeap.shared.reference(for: obj)
                advance(2)

            case 0x44: // aget vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                guard let arr = object(from: current.registers[vB]) else {
                    throw ARTError.unimplemented("Null array aget")
                }
                let idx = Int(Int32(bitPattern: current.registers[vC]))
                if idx >= 0 && idx < arr.arrayValues.count,
                   case .int(let v) = arr.arrayValues[idx] {
                    current.registers[vA] = UInt32(bitPattern: v)
                }
                advance(2)

            case 0x4b: // aput vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                guard let arr = object(from: current.registers[vB]) else {
                    throw ARTError.unimplemented("Null array aput")
                }
                let idx = Int(Int32(bitPattern: current.registers[vC]))
                if idx >= 0 && idx < arr.arrayValues.count {
                    arr.arrayValues[idx] = .int(Int32(bitPattern: current.registers[vA]))
                }
                advance(2)

            case 0x52: // iget vA, vB, field@CCCC
                let vA = Int(a)
                let vB = Int(b)
                let fieldIdx = UInt32(insns[current.pc + 1])
                guard let field = dex.fieldRef(at: fieldIdx) else {
                    throw ARTError.fieldNotFound("index \(fieldIdx)")
                }
                guard let obj = object(from: current.registers[vB]) else {
                    throw ARTError.unimplemented("Null receiver iget")
                }
                if let v = obj.fields[field.name] as? Int32 {
                    current.registers[vA] = UInt32(bitPattern: v)
                } else {
                    current.registers[vA] = 0
                }
                advance(2)

            case 0x59: // iput vA, vB, field@CCCC
                let vA = Int(a)
                let vB = Int(b)
                let fieldIdx = UInt32(insns[current.pc + 1])
                guard let field = dex.fieldRef(at: fieldIdx) else {
                    throw ARTError.fieldNotFound("index \(fieldIdx)")
                }
                guard let obj = object(from: current.registers[vB]) else {
                    throw ARTError.unimplemented("Null receiver iput")
                }
                obj.fields[field.name] = Int32(bitPattern: current.registers[vA])
                advance(2)

            case 0x60: // sget vAA, field@BBBB
                let vA = Int(inst >> 8)
                let fieldIdx = UInt32(insns[current.pc + 1])
                guard let field = dex.fieldRef(at: fieldIdx) else {
                    throw ARTError.fieldNotFound("index \(fieldIdx)")
                }
                let key = "\(field.classType.descriptor).\(field.name)"
                if case .int(let v) = staticFields[key] {
                    current.registers[vA] = UInt32(bitPattern: v)
                } else {
                    current.registers[vA] = 0
                }
                advance(2)

            case 0x67: // sput vAA, field@BBBB
                let vA = Int(inst >> 8)
                let fieldIdx = UInt32(insns[current.pc + 1])
                guard let field = dex.fieldRef(at: fieldIdx) else {
                    throw ARTError.fieldNotFound("index \(fieldIdx)")
                }
                let key = "\(field.classType.descriptor).\(field.name)"
                staticFields[key] = .int(Int32(bitPattern: current.registers[vA]))
                advance(2)

            case 0x6e, 0x71, 0x72, 0x76: // invoke-virtual/static/interface/super
                let count = Int(a)
                let argWord = insns[current.pc + 1]
                let methodIdx = UInt32(insns[current.pc + 2])
                let regs = [
                    Int(argWord & 0xf),
                    Int((argWord >> 4) & 0xf),
                    Int((argWord >> 8) & 0xf),
                    Int((argWord >> 12) & 0xf),
                    Int((inst >> 12) & 0xf)
                ]

                guard let methodRef = dex.methodRef(at: methodIdx) else {
                    throw ARTError.methodNotFound("index \(methodIdx)")
                }

                // Build argument list from decoded register list.
                var args: [JavaValue] = []
                for i in 0..<count {
                    args.append(.int(Int32(bitPattern: current.registers[regs[i]])))
                }

                let targetName = methodRef.classType.descriptor
                let javaClassName = javaName(from: targetName)

                // Framework method interception (Activity.findViewById, TextView.setText, etc.).
                switch handleFrameworkMethod(methodRef: methodRef,
                                             receiverReg: regs[0],
                                             argValues: args,
                                             current: current) {
                case .value(let v):
                    current.registers[Int(inst >> 8)] = UInt32(bitPattern: v)
                    advance(3)
                    continue
                case .void:
                    advance(3)
                    continue
                case .notIntercepted:
                    break
                }

                // If the method is native, delegate to JNIRegistry.
                if let method = try? resolveMethod(in: javaClassName, name: methodRef.name),
                   (method.accessFlags & 0x0100) != 0 { // ACC_NATIVE
                    // Phase 1: native methods return void/integer via JNIRegistry.
                    _ = JNIRegistry.shared.invoke(
                        NativeMethodSignature(className: javaClassName,
                                               methodName: methodRef.name,
                                               signature: methodRef.proto.shorty),
                        libraryPath: "", // Set by container engine.
                        this: nil,
                        args: args
                    )
                    advance(3)
                    break
                }

                let method = try resolveMethod(in: javaClassName, name: methodRef.name)

                let newFrame = Frame(method: method, returnFrame: current)
                let code = method.code ?? DexCodeItem(registersSize: 0, insSize: 0, outsSize: 0, triesSize: 0, debugInfoOff: 0, insnsSize: 0, insns: [])
                var tail = Int(code.registersSize) - count
                for i in 0..<count {
                    newFrame.registers[tail] = current.registers[regs[i]]
                    tail += 1
                }

                thread.frames.append(newFrame)
                advance(3)

            case 0x90: // add-int vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                current.registers[vA] = UInt32(bitPattern: Int32(bitPattern: current.registers[vB]) + Int32(bitPattern: current.registers[vC]))
                advance(2)
            case 0x91: // sub-int vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                current.registers[vA] = UInt32(bitPattern: Int32(bitPattern: current.registers[vB]) - Int32(bitPattern: current.registers[vC]))
                advance(2)
            case 0x92: // mul-int vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                current.registers[vA] = UInt32(bitPattern: Int32(bitPattern: current.registers[vB]) * Int32(bitPattern: current.registers[vC]))
                advance(2)
            case 0x93: // div-int vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                let rhs = Int32(bitPattern: current.registers[vC])
                if rhs == 0 { throw ARTError.divByZero }
                current.registers[vA] = UInt32(bitPattern: Int32(bitPattern: current.registers[vB]) / rhs)
                advance(2)
            case 0x94: // rem-int vAA, vBB, vCC
                let vA = Int(inst >> 8)
                let vB = Int(insns[current.pc + 1] & 0xff)
                let vC = Int((insns[current.pc + 1] >> 8) & 0xff)
                let rhs = Int32(bitPattern: current.registers[vC])
                if rhs == 0 { throw ARTError.divByZero }
                current.registers[vA] = UInt32(bitPattern: Int32(bitPattern: current.registers[vB]) % rhs)
                advance(2)

            case 0xb0: // add-int/2addr vA, vB
                let vA = Int(a)
                let vB = Int(b)
                current.registers[vA] = UInt32(bitPattern: Int32(bitPattern: current.registers[vA]) + Int32(bitPattern: current.registers[vB]))
                advance(1)

            case 0x1f: // check-cast vAA, type@BBBB
                // Phase 1: no-op; real verifier omitted.
                advance(2)

            case 0x20: // instance-of vAA, vBB, type@CCCC
                let vA = Int(a)
                let vB = Int(b)
                let typeIdx = Int(insns[current.pc + 1])
                guard let obj = object(from: current.registers[vB]) else {
                    current.registers[vA] = 0
                    advance(2)
                    break
                }
                let target = dex.className(at: UInt32(typeIdx))
                current.registers[vA] = (obj.className == target || isSubclass(obj.className, target)) ? 1 : 0
                advance(2)

            default:
                throw ARTError.unknownOpcode(op)
            }
        }

        return .void
    }

    // MARK: - Helpers

    private func object(from bits: UInt32) -> JavaObject? {
        return JavaHeap.shared.object(for: bits)
    }

    /// Result of intercepting a framework method call.
    private enum FrameworkResult {
        case notIntercepted
        case void
        case value(Int32)
    }

    /// Intercept framework calls that the DEX bytecode makes against
    /// android.app.Activity / android.widget.TextView etc.
    private func handleFrameworkMethod(methodRef: DexMethodRef,
                                       receiverReg: Int,
                                       argValues: [JavaValue],
                                       current: Frame) -> FrameworkResult {
        guard let bridge = uiBridge else { return .notIntercepted }
        let name = methodRef.name
        let desc = methodRef.classType.descriptor

        // Activity.findViewById(I)Landroid/view/View;
        // argValues[0] is the Activity receiver, argValues[1] is the resource id.
        if name == "findViewById" && desc.hasSuffix("Activity;") && argValues.count >= 2 {
            if case .int(let id) = argValues[1] {
                let view = bridge.findViewById(id: id)
                return .value(Int32(bitPattern: JavaHeap.shared.reference(for: view)))
            }
        }

        // TextView.setText(...)  argValues[0] is the TextView receiver, argValues[1] is the argument.
        if name == "setText" && desc.hasSuffix("TextView;") && argValues.count >= 2 {
            if let obj = object(from: current.registers[receiverReg]) {
                switch argValues[1] {
                case .int(let stringId):
                    bridge.setText(view: obj, resId: stringId)
                case .object(let strObj?):
                    // Extract string value stored by const-string.
                    let text = strObj.fields["__value"] as? String ?? ""
                    bridge.setText(view: obj, text: text)
                default:
                    bridge.setText(view: obj, text: "")
                }
            }
            return .void
        }

        // Activity.setContentView(I)V
        if name == "setContentView" && desc.hasSuffix("Activity;") && argValues.count >= 2 {
            if case .int(let layoutId) = argValues[1] {
                bridge.setContentView(resId: layoutId)
            }
            return .void
        }

        return .notIntercepted
    }

    private func resolveMethod(in className: String, name: String) throws -> DexMethod {
        guard let def = loadedClasses[className] else {
            throw ARTError.classNotFound(className)
        }
        for m in def.directMethods + def.virtualMethods {
            guard let ref = dex.methodRef(at: m.methodId) else { continue }
            if ref.name == name { return m }
        }
        throw ARTError.methodNotFound("\(className).\(name)")
    }

    private func javaName(from descriptor: String) -> String {
        if descriptor.hasPrefix("L") && descriptor.hasSuffix(";") {
            return String(descriptor.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
        }
        return descriptor
    }

    private func isSubclass(_ className: String, _ target: String) -> Bool {
        // Phase 1: naive equality.  Inheritance table can be added later.
        return className == target
    }

    /// Resolve a class definition by Java name.
    public func classDef(named name: String) -> DexClassDef? {
        return loadedClasses[name]
    }
}
