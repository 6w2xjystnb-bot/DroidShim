//
//  DexLoader.swift
//  DroidShimCore
//
//  Parses Android DEX files into in-memory Swift structures.
//  Phase 1 supports DEX version 035 and the subset of the file format
//  required by simple Java-only APKs.
//

import Foundation

/// Errors that can occur while loading a DEX file.
public enum DexLoadError: Error, CustomStringConvertible {
    case invalidMagic
    case truncated
    case unsupportedEndian
    case invalidString
    case invalidIndex(String)

    public var description: String {
        switch self {
        case .invalidMagic: return "DEX magic mismatch"
        case .truncated: return "DEX file truncated"
        case .unsupportedEndian: return "DEX endian tag unsupported"
        case .invalidString: return "Invalid MUTF-8 string"
        case .invalidIndex(let msg): return "Invalid index: \(msg)"
        }
    }
}

/// Fixed-size DEX header (0x70 bytes).
private struct DexHeader {
    let magic: [UInt8]
    let checksum: UInt32
    let signature: [UInt8]
    let fileSize: UInt32
    let headerSize: UInt32
    let endianTag: UInt32
    let linkSize: UInt32
    let linkOff: UInt32
    let mapOff: UInt32
    let stringIdsSize: UInt32
    let stringIdsOff: UInt32
    let typeIdsSize: UInt32
    let typeIdsOff: UInt32
    let protoIdsSize: UInt32
    let protoIdsOff: UInt32
    let fieldIdsSize: UInt32
    let fieldIdsOff: UInt32
    let methodIdsSize: UInt32
    let methodIdsOff: UInt32
    let classDefsSize: UInt32
    let classDefsOff: UInt32
    let dataSize: UInt32
    let dataOff: UInt32
}

/// A decoded DEX string.
public struct DexString {
    public let raw: String
}

/// A DEX type descriptor (e.g. "Ljava/lang/String;").
public struct DexType {
    public let descriptor: String
}

/// A DEX method prototype.
public struct DexProto {
    public let shorty: String
    public let returnType: DexType
    public let parameterTypes: [DexType]
}

/// A DEX field reference.
public struct DexFieldRef {
    public let classType: DexType
    public let type: DexType
    public let name: String
}

/// A DEX method reference.
public struct DexMethodRef {
    public let classType: DexType
    public let proto: DexProto
    public let name: String
}

/// Encoded field with access flags.
public struct DexField {
    public let fieldId: UInt32
    public let accessFlags: UInt32
}

/// Encoded method with code item.
public struct DexMethod {
    public let methodId: UInt32
    public let accessFlags: UInt32
    public let codeOffset: UInt32
    public var code: DexCodeItem?
}

/// Decoded `code_item` structure.
public struct DexCodeItem {
    public let registersSize: UInt16
    public let insSize: UInt16
    public let outsSize: UInt16
    public let triesSize: UInt16
    public let debugInfoOff: UInt32
    public let insnsSize: UInt32
    public let insns: [UInt16]
}

/// A decoded DEX class definition.
/// Typed constant value parsed from DEX `encoded_value`.
public enum DexEncodedValue {
    case int(Int32)
    case long(Int64)
    case null
    case unknown
}

public struct DexClassDef {
    public let classIdx: UInt32
    public let accessFlags: UInt32
    public let superclassIdx: UInt32
    public let interfacesOff: UInt32
    public let sourceFileIdx: UInt32
    public let annotationsOff: UInt32
    public let classDataOff: UInt32
    public let staticValuesOff: UInt32

    public var staticFields: [DexField] = []
    public var instanceFields: [DexField] = []
    public var directMethods: [DexMethod] = []
    public var virtualMethods: [DexMethod] = []
    public var staticValues: [DexEncodedValue] = []
}

/// In-memory representation of a loaded DEX file.
public final class DexFile {
    public let data: Data
    public private(set) var strings: [DexString] = []
    public private(set) var types: [DexType] = []
    public private(set) var protos: [DexProto] = []
    public private(set) var fieldRefs: [DexFieldRef] = []
    public private(set) var methodRefs: [DexMethodRef] = []
    public private(set) var classDefs: [DexClassDef] = []

    private var header: DexHeader!

    public init(data: Data) throws {
        self.data = data
        try parse()
    }

    // MARK: - Header parsing

    private func parse() throws {
        guard data.count >= 0x70 else { throw DexLoadError.truncated }

        let magic = Array(data[0..<8])
        guard magic[0] == 0x64, magic[1] == 0x65, magic[2] == 0x78, magic[3] == 0x0a else {
            throw DexLoadError.invalidMagic
        }

        header = DexHeader(
            magic: magic,
            checksum: readUInt32(at: 8),
            signature: Array(data[12..<32]),
            fileSize: readUInt32(at: 32),
            headerSize: readUInt32(at: 36),
            endianTag: readUInt32(at: 40),
            linkSize: readUInt32(at: 44),
            linkOff: readUInt32(at: 48),
            mapOff: readUInt32(at: 52),
            stringIdsSize: readUInt32(at: 56),
            stringIdsOff: readUInt32(at: 60),
            typeIdsSize: readUInt32(at: 64),
            typeIdsOff: readUInt32(at: 68),
            protoIdsSize: readUInt32(at: 72),
            protoIdsOff: readUInt32(at: 76),
            fieldIdsSize: readUInt32(at: 80),
            fieldIdsOff: readUInt32(at: 84),
            methodIdsSize: readUInt32(at: 88),
            methodIdsOff: readUInt32(at: 92),
            classDefsSize: readUInt32(at: 96),
            classDefsOff: readUInt32(at: 100),
            dataSize: readUInt32(at: 104),
            dataOff: readUInt32(at: 108)
        )

        guard header.endianTag == 0x12345678 else { throw DexLoadError.unsupportedEndian }
        guard data.count >= Int(header.fileSize) else { throw DexLoadError.truncated }

        try parseStrings()
        try parseTypes()
        try parseProtos()
        try parseFieldIds()
        try parseMethodIds()
        try parseClassDefs()
    }

    // MARK: - Low-level helpers

    private func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            value = base[offset / 4]
        }
        return value
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
            value = base[offset / 2]
        }
        return value
    }

    private func readULEB128(at offset: Int) -> (value: UInt32, next: Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var i = offset
        while true {
            let byte = data[i]
            i += 1
            result |= UInt32(byte & 0x7f) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
        }
        return (result, i)
    }

    /// Decodes a Modified UTF-8 (MUTF-8) string starting at `offset`.
    private func readMUTF8String(at offset: Int) throws -> String {
        // DEX string data is encoded as ULEB128 length followed by MUTF-8 bytes.
        let (byteCount, dataOff) = readULEB128(at: offset)
        var bytes = data.subdata(in: dataOff..<dataOff + Int(byteCount))
        // MUTF-8 is similar to CESU-8; for Phase 1 we decode as standard UTF-8
        // after handling the two-byte NUL encoding 0xC0 0x80.
        var utf8 = bytes
        for i in 0..<utf8.count {
            if utf8[i] == 0xC0 && i + 1 < utf8.count && utf8[i + 1] == 0x80 {
                utf8[i] = 0
                utf8[i + 1] = 0
            }
        }
        guard let s = String(data: utf8, encoding: .utf8) else {
            throw DexLoadError.invalidString
        }
        return s
    }

    // MARK: - String / type / proto tables

    private func parseStrings() throws {
        let count = Int(header.stringIdsSize)
        strings.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(header.stringIdsOff) + i * 4
            let strOff = Int(readUInt32(at: off))
            let s = try readMUTF8String(at: strOff)
            strings.append(DexString(raw: s))
        }
    }

    private func parseTypes() throws {
        let count = Int(header.typeIdsSize)
        types.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(header.typeIdsOff) + i * 4
            let idx = readUInt32(at: off)
            guard idx < strings.count else { throw DexLoadError.invalidIndex("typeIds") }
            types.append(DexType(descriptor: strings[Int(idx)].raw))
        }
    }

    private func parseProtos() throws {
        let count = Int(header.protoIdsSize)
        protos.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(header.protoIdsOff) + i * 12
            let shortyIdx = readUInt32(at: off)
            let returnTypeIdx = readUInt32(at: off + 4)
            let parametersOff = readUInt32(at: off + 8)

            guard shortyIdx < strings.count,
                  returnTypeIdx < types.count else {
                throw DexLoadError.invalidIndex("protoIds")
            }

            var parameterTypes: [DexType] = []
            if parametersOff != 0 {
                let size = Int(readUInt32(at: Int(parametersOff)))
                for j in 0..<size {
                    let typeIdx = readUInt16(at: Int(parametersOff) + 4 + j * 2)
                    guard typeIdx < types.count else { throw DexLoadError.invalidIndex("proto parameters") }
                    parameterTypes.append(types[Int(typeIdx)])
                }
            }

            protos.append(DexProto(
                shorty: strings[Int(shortyIdx)].raw,
                returnType: types[Int(returnTypeIdx)],
                parameterTypes: parameterTypes
            ))
        }
    }

    private func parseFieldIds() throws {
        let count = Int(header.fieldIdsSize)
        fieldRefs.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(header.fieldIdsOff) + i * 8
            let classIdx = readUInt16(at: off)
            let typeIdx = readUInt16(at: off + 2)
            let nameIdx = readUInt32(at: off + 4)
            guard classIdx < types.count,
                  typeIdx < types.count,
                  nameIdx < strings.count else {
                throw DexLoadError.invalidIndex("fieldIds")
            }
            fieldRefs.append(DexFieldRef(
                classType: types[Int(classIdx)],
                type: types[Int(typeIdx)],
                name: strings[Int(nameIdx)].raw
            ))
        }
    }

    private func parseMethodIds() throws {
        let count = Int(header.methodIdsSize)
        methodRefs.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(header.methodIdsOff) + i * 8
            let classIdx = readUInt16(at: off)
            let protoIdx = readUInt16(at: off + 2)
            let nameIdx = readUInt32(at: off + 4)
            guard classIdx < types.count,
                  protoIdx < protos.count,
                  nameIdx < strings.count else {
                throw DexLoadError.invalidIndex("methodIds")
            }
            methodRefs.append(DexMethodRef(
                classType: types[Int(classIdx)],
                proto: protos[Int(protoIdx)],
                name: strings[Int(nameIdx)].raw
            ))
        }
    }

    // MARK: - Class definitions

    private func parseClassDefs() throws {
        let count = Int(header.classDefsSize)
        classDefs.reserveCapacity(count)
        for i in 0..<count {
            let off = Int(header.classDefsOff) + i * 32
            var def = DexClassDef(
                classIdx: readUInt32(at: off),
                accessFlags: readUInt32(at: off + 4),
                superclassIdx: readUInt32(at: off + 8),
                interfacesOff: readUInt32(at: off + 12),
                sourceFileIdx: readUInt32(at: off + 16),
                annotationsOff: readUInt32(at: off + 20),
                classDataOff: readUInt32(at: off + 24),
                staticValuesOff: readUInt32(at: off + 28)
            )
            if def.classDataOff != 0 {
                try parseClassData(def: &def, offset: Int(def.classDataOff))
            }
            if def.staticValuesOff != 0 {
                def.staticValues = parseEncodedArray(at: Int(def.staticValuesOff))
            }
            classDefs.append(def)
        }
    }

    private func parseClassData(def: inout DexClassDef, offset: Int) throws {
        var pos = offset
        let (staticFieldSize, p1) = readULEB128(at: pos); pos = p1
        let (instanceFieldSize, p2) = readULEB128(at: pos); pos = p2
        let (directMethodSize, p3) = readULEB128(at: pos); pos = p3
        let (virtualMethodSize, p4) = readULEB128(at: pos); pos = p4

        var prevIndex: UInt32 = 0
        for _ in 0..<staticFieldSize {
            let (idxDiff, p) = readULEB128(at: pos); pos = p
            let (access, p2) = readULEB128(at: pos); pos = p2
            prevIndex += idxDiff
            def.staticFields.append(DexField(fieldId: prevIndex, accessFlags: access))
        }
        prevIndex = 0
        for _ in 0..<instanceFieldSize {
            let (idxDiff, p) = readULEB128(at: pos); pos = p
            let (access, p2) = readULEB128(at: pos); pos = p2
            prevIndex += idxDiff
            def.instanceFields.append(DexField(fieldId: prevIndex, accessFlags: access))
        }

        func decodeMethod() -> DexMethod {
            let (idxDiff, p) = readULEB128(at: pos); pos = p
            let (access, p2) = readULEB128(at: pos); pos = p2
            let (codeOff, p3) = readULEB128(at: pos); pos = p3
            prevIndex += idxDiff
            return DexMethod(methodId: prevIndex, accessFlags: access, codeOffset: codeOff, code: nil)
        }

        prevIndex = 0
        for _ in 0..<directMethodSize {
            var m = decodeMethod()
            if m.codeOffset != 0 {
                m.code = parseCodeItem(offset: Int(m.codeOffset))
            }
            def.directMethods.append(m)
        }
        prevIndex = 0
        for _ in 0..<virtualMethodSize {
            var m = decodeMethod()
            if m.codeOffset != 0 {
                m.code = parseCodeItem(offset: Int(m.codeOffset))
            }
            def.virtualMethods.append(m)
        }
    }

    private func parseCodeItem(offset: Int) -> DexCodeItem {
        return DexCodeItem(
            registersSize: readUInt16(at: offset),
            insSize: readUInt16(at: offset + 2),
            outsSize: readUInt16(at: offset + 4),
            triesSize: readUInt16(at: offset + 6),
            debugInfoOff: readUInt32(at: offset + 8),
            insnsSize: readUInt32(at: offset + 12),
            insns: Array((0..<readUInt32(at: offset + 12)).map { readUInt16(at: offset + 16 + Int($0) * 2) })
        )
    }

    // MARK: - Encoded values (static fields, annotations)

    private func parseEncodedArray(at offset: Int) -> [DexEncodedValue] {
        let (size, pos) = readULEB128(at: offset)
        var values: [DexEncodedValue] = []
        var p = pos
        for _ in 0..<size {
            let (value, next) = parseEncodedValue(at: p)
            values.append(value)
            p = next
        }
        return values
    }

    private func parseEncodedValue(at offset: Int) -> (DexEncodedValue, Int) {
        let header = data[offset]
        let valueType = header & 0x1f
        let valueArg = (header >> 5) & 0x7
        let valueSize = Int(valueArg) + 1
        var pos = offset + 1

        func nextBytes(_ count: Int) -> [UInt8] {
            let bytes = Array(data[pos..<pos + count])
            pos += count
            return bytes
        }

        func signedN(_ n: Int) -> Int64 {
            let bytes = nextBytes(n)
            var result: Int64 = 0
            for (i, b) in bytes.enumerated() {
                result |= Int64(b) << (i * 8)
            }
            let shift = (8 - n) * 8
            return (result << shift) >> shift // sign extend
        }

        switch valueType {
        case 0x02: // SHORT
            return (.int(Int32(truncatingIfNeeded: signedN(valueSize))), pos)
        case 0x04: // INT
            return (.int(Int32(truncatingIfNeeded: signedN(valueSize))), pos)
        case 0x06: // LONG
            return (.long(signedN(valueSize)), pos)
        case 0x1e: // NULL
            return (.null, pos)
        default:
            // For Phase 1 we only need primitive int constants (R.java).
            // Skip the payload size based on type and move on.
            let skip: Int
            switch valueType {
            case 0x00: skip = 1 // BYTE
            case 0x03: skip = valueSize // CHAR
            case 0x10: skip = valueSize // FLOAT
            case 0x11: skip = valueSize // DOUBLE
            case 0x17, 0x18, 0x19, 0x1a, 0x1b: // STRING/TYPE/FIELD/METHOD/ENUM
                let (_, p) = readULEB128(at: pos)
                pos = p
                skip = 0
            case 0x1c: // ARRAY
                _ = parseEncodedArray(at: pos)
                skip = 0
            case 0x1d: // ANNOTATION
                let (_, p1) = readULEB128(at: pos); pos = p1
                let (count, p2) = readULEB128(at: pos); pos = p2
                for _ in 0..<count {
                    let (_, p3) = readULEB128(at: pos); pos = p3
                    let (_, p4) = parseEncodedValue(at: pos)
                    pos = p4
                }
                skip = 0
            case 0x1f: skip = 0 // BOOLEAN
            default: skip = 0
            }
            pos += skip
            return (.unknown, pos)
        }
    }

    // MARK: - Public lookup helpers

    public func className(at idx: UInt32) -> String {
        guard idx < types.count else { return "<invalid>" }
        let desc = types[Int(idx)].descriptor
        // Convert Lcom/example/Foo; -> com.example.Foo
        if desc.hasPrefix("L") && desc.hasSuffix(";") {
            return String(desc.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
        }
        return desc
    }

    public func methodRef(at idx: UInt32) -> DexMethodRef? {
        guard idx < methodRefs.count else { return nil }
        return methodRefs[Int(idx)]
    }

    public func fieldRef(at idx: UInt32) -> DexFieldRef? {
        guard idx < fieldRefs.count else { return nil }
        return fieldRefs[Int(idx)]
    }
}
