//
//  ResourceExtractor.swift
//  DroidShimCore
//
//  Parses resources.arsc and maps resource IDs (0xPPTTEEEE) to entries.
//  Phase 1 supports string, color, and reference lookups.
//

import Foundation

/// A parsed resources.arsc table.
public final class ResourceTable {
    private let data: Data
    private var globalStrings: [String] = []
    private var entries: [UInt32: ResValue] = [:]

    public init(data: Data) throws {
        self.data = data
        try parse()
    }

    // MARK: - Public resolution

    public func string(id: UInt32) -> String? {
        if let value = entries[id], case .string(let s) = value { return s }
        return nil
    }

    public func color(id: UInt32) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        if let value = entries[id], case .color(let c) = value { return c }
        return nil
    }

    public func reference(id: UInt32) -> UInt32? {
        if let value = entries[id], case .reference(let r) = value { return r }
        return nil
    }

    public func allEntries() -> [UInt32: ResValue] { entries }

    // MARK: - Internal parser

    private func parse() throws {
        guard data.count >= 12 else { throw ResourceTableError.truncated }
        let headerSize = Int(readUInt16(at: 2))
        let packageCount = readUInt32(at: 8)

        var offset = headerSize
        for _ in 0..<packageCount {
            let chunkType = readUInt16(at: offset)
            let chunkHeaderSize = Int(readUInt16(at: offset + 2))
            let chunkSize = Int(readUInt32(at: offset + 4))

            if chunkType == 0x0001 { // RES_STRING_POOL_TYPE (global)
                globalStrings = try readStringPool(at: offset, headerSize: chunkHeaderSize)
            } else if chunkType == 0x0200 { // RES_TABLE_PACKAGE_TYPE
                try parsePackage(at: offset, headerSize: chunkHeaderSize, chunkSize: chunkSize)
            }

            offset += chunkSize
        }
    }

    private func parsePackage(at offset: Int, headerSize: Int, chunkSize: Int) throws {
        let packageId = UInt32(readUInt32(at: offset + 8))

        let typeStringsOffset = offset + Int(readUInt32(at: offset + 12 + 512))
        let keyStringsOffset = offset + Int(readUInt32(at: offset + 12 + 516))

        let typeStrings = try readStringPool(at: typeStringsOffset, headerSize: 0)
        let keyStrings = try readStringPool(at: keyStringsOffset, headerSize: 0)

        var childOffset = offset + headerSize
        while childOffset < offset + chunkSize {
            let chunkType = readUInt16(at: childOffset)
            let childHeaderSize = Int(readUInt16(at: childOffset + 2))
            let childSize = Int(readUInt32(at: childOffset + 4))

            if chunkType == 0x0202 { // RES_TABLE_TYPE_TYPE
                try parseTypeChunk(at: childOffset,
                                   headerSize: childHeaderSize,
                                   packageId: packageId,
                                   typeStrings: typeStrings,
                                   keyStrings: keyStrings)
            }

            childOffset += childSize
        }
    }

    private func parseTypeChunk(at offset: Int,
                                headerSize: Int,
                                packageId: UInt32,
                                typeStrings: [String],
                                keyStrings: [String]) throws {
        let typeId = UInt32(data[offset + 8])
        let entryCount = readUInt32(at: offset + 12)
        let entriesStart = Int(readUInt32(at: offset + 16))
        let typeName = typeId < UInt32(typeStrings.count) ? typeStrings[Int(typeId)] : ""
        _ = typeName

        let entryBase = offset + entriesStart
        let indexTableOffset = offset + headerSize

        for i in 0..<entryCount {
            let entryOffsetRel = Int(readUInt32(at: indexTableOffset + Int(i) * 4))
            if entryOffsetRel == 0xffffffff { continue }
            let fullId = (packageId << 24) | (typeId << 16) | i
            let value = try parseEntry(at: entryBase + entryOffsetRel,
                                       typeName: typeName,
                                       keyStrings: keyStrings)
            entries[fullId] = value
        }
    }

    private func parseEntry(at offset: Int, typeName: String, keyStrings: [String]) throws -> ResValue {
        let size = readUInt16(at: offset)
        let flags = readUInt16(at: offset + 2)
        let keyIndex = readUInt32(at: offset + 4)
        let keyName = keyIndex < UInt32(keyStrings.count) ? keyStrings[Int(keyIndex)] : ""
        _ = size
        _ = flags

        let valueDataType = data[offset + 11]
        let valueData = readUInt32(at: offset + 12)

        switch valueDataType {
        case 0x03: // TYPE_STRING
            guard valueData < globalStrings.count else { return .string("") }
            return .string(globalStrings[Int(valueData)])
        case 0x1c: // TYPE_COLOR_INT / ARGB8
            return .color(decodeColor(valueData))
        case 0x01: // TYPE_REFERENCE
            return .reference(valueData)
        default:
            return .raw(valueDataType, valueData, keyName)
        }
    }

    private func readStringPool(at offset: Int, headerSize: Int) throws -> [String] {
        let count = Int(readUInt32(at: offset + 8))
        let flags = readUInt32(at: offset + 16)
        let stringsStart = Int(readUInt32(at: offset + 20))
        let isUTF8 = (flags & 0x100) != 0
        let offsetsOffset = offset + (headerSize > 0 ? headerSize : Int(readUInt16(at: offset + 2)))

        var pool: [String] = []
        for i in 0..<count {
            let rel = Int(readUInt32(at: offsetsOffset + i * 4))
            let abs = offset + stringsStart + rel
            pool.append(try decodeString(at: abs, isUTF8: isUTF8))
        }
        return pool
    }

    private func decodeString(at offset: Int, isUTF8: Bool) throws -> String {
        var pos = offset
        if isUTF8 {
            let (_, p1) = readULEB128(at: pos); pos = p1
            let (byteLen, p2) = readULEB128(at: pos); pos = p2
            let bytes = data.subdata(in: pos..<pos + Int(byteLen))
            guard let s = String(data: bytes, encoding: .utf8) else {
                throw ResourceTableError.invalidString
            }
            return s
        } else {
            let (charLen, p1) = readULEB128(at: pos); pos = p1
            let byteLen = Int(charLen) * 2
            let bytes = data.subdata(in: pos..<pos + byteLen)
            guard let s = String(data: bytes, encoding: .utf16LittleEndian) else {
                throw ResourceTableError.invalidString
            }
            return s
        }
    }

    private func decodeColor(_ value: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        let a = UInt8((value >> 24) & 0xff)
        let r = UInt8((value >> 16) & 0xff)
        let g = UInt8((value >> 8) & 0xff)
        let b = UInt8(value & 0xff)
        return (r, g, b, a)
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
            value = base[offset / 2]
        }
        return value
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            value = base[offset / 4]
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
}

public enum ResValue {
    case string(String)
    case color((UInt8, UInt8, UInt8, UInt8))
    case reference(UInt32)
    case raw(UInt8, UInt32, String)
}

public enum ResourceTableError: Error {
    case truncated
    case invalidString
}
