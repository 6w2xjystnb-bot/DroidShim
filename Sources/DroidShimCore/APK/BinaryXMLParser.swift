//
//  BinaryXMLParser.swift
//  DroidShimCore
//
//  Parser for Android's binary XML (AXML) format used in AndroidManifest.xml.
//

import Foundation

/// Known AXML chunk types.
private enum AXMLChunkType: UInt16 {
    case stringPool = 0x0001
    case resourceMap = 0x0180
    case startNamespace = 0x0100
    case endNamespace = 0x0101
    case startElement = 0x0102
    case endElement = 0x0103
    case text = 0x0104
}

/// Errors specific to AXML parsing.
public enum BinaryXMLParserError: Error, CustomStringConvertible {
    case truncated
    case invalidChunkType(UInt16)
    case invalidStringIndex(UInt32)

    public var description: String {
        switch self {
        case .truncated: return "AXML data truncated"
        case .invalidChunkType(let t): return "Invalid AXML chunk type 0x\(String(t, radix: 16))"
        case .invalidStringIndex(let i): return "Invalid string pool index \(i)"
        }
    }
}

/// A parsed AndroidManifest.xml attribute.
public struct AXMLAttribute {
    public let namespaceUri: UInt32
    public let nameIndex: UInt32
    public let rawValue: UInt32
    public let typedValue: AXMLTypedValue
}

/// Typed value as stored in AXML attributes.
public struct AXMLTypedValue {
    public let size: UInt16
    public let res0: UInt8
    public let dataType: UInt8
    public let data: UInt32
}

/// A parsed XML element start event.
public struct AXMLStartElement {
    public let lineNumber: UInt32
    public let namespaceUri: UInt32
    public let nameIndex: UInt32
    public let attributes: [AXMLAttribute]
}

/// Result of parsing an AndroidManifest.xml.
public struct AndroidManifest {
    public var packageName: String = ""
    public var versionCode: Int = 0
    public var applicationLabel: String = ""
    public var applicationIcon: String = ""
    public var mainActivity: String = ""
    public var activities: [ActivityRecord] = []
}

/// Minimal activity record extracted from the manifest.
public struct ActivityRecord {
    public let name: String
    public let isMain: Bool
    public let isLauncher: Bool
}

/// Parser for binary AndroidManifest.xml.
public final class BinaryXMLParser {
    private var data: Data
    private var stringPool: [String] = []
    private var resourceMap: [UInt32] = []
    private var currentElement: AXMLStartElement?
    private var manifest = AndroidManifest()

    public init(data: Data) {
        self.data = data
    }

    public func parse() throws -> AndroidManifest {
        guard data.count >= 8 else { throw BinaryXMLParserError.truncated }

        // First chunk: RES_XML_TYPE header.
        let type = readUInt16(at: 0)
        guard type == 0x0003 else { throw BinaryXMLParserError.invalidChunkType(type) }
        let headerSize = Int(readUInt16(at: 2))
        let chunkSize = Int(readUInt32(at: 4))
        guard data.count >= chunkSize else { throw BinaryXMLParserError.truncated }

        var offset = headerSize
        while offset < chunkSize {
            guard offset + 8 <= data.count else { throw BinaryXMLParserError.truncated }
            let childType = readUInt16(at: offset)
            let childHeaderSize = Int(readUInt16(at: offset + 2))
            let childChunkSize = Int(readUInt32(at: offset + 4))
            guard childChunkSize > 0, offset + childChunkSize <= data.count else {
                throw BinaryXMLParserError.truncated
            }

            guard let kind = AXMLChunkType(rawValue: childType) else {
                offset += childChunkSize
                continue
            }

            switch kind {
            case .stringPool:
                try parseStringPool(at: offset, headerSize: childHeaderSize, chunkSize: childChunkSize)
            case .resourceMap:
                parseResourceMap(at: offset, headerSize: childHeaderSize, chunkSize: childChunkSize)
            case .startElement:
                try parseStartElement(at: offset, headerSize: childHeaderSize)
            case .endElement:
                parseEndElement(at: offset)
            default:
                break
            }

            offset += childChunkSize
        }

        return manifest
    }

    // MARK: - String pool

    private func parseStringPool(at offset: Int, headerSize: Int, chunkSize: Int) throws {
        // Header layout after type+headerSize+chunkSize:
        // uint32 stringCount, styleCount, flags, stringsStart, stylesStart
        let stringCount = Int(readUInt32(at: offset + 8))
        let styleCount = Int(readUInt32(at: offset + 12))
        let flags = readUInt32(at: offset + 16)
        _ = styleCount
        let stringsStart = Int(readUInt32(at: offset + 20))
        let stylesStart = Int(readUInt32(at: offset + 24))

        let isUTF8 = (flags & 0x100) != 0
        let stringOffsetsOffset = offset + headerSize

        stringPool.reserveCapacity(stringCount)
        for i in 0..<stringCount {
            let strOffsetOffset = stringOffsetsOffset + i * 4
            let relativeOffset = Int(readUInt32(at: strOffsetOffset))
            let absoluteOffset = offset + stringsStart + relativeOffset
            let s = try decodeString(at: absoluteOffset, isUTF8: isUTF8)
            stringPool.append(s)
        }

        if styleCount > 0 && stylesStart > 0 {
            // Styles are not needed for manifest parsing in Phase 1.
        }
    }

    private func decodeString(at offset: Int, isUTF8: Bool) throws -> String {
        var pos = offset
        if isUTF8 {
            // UTF-8: ULEB128 character length (ignored), then ULEB128 byte length, then bytes.
            let (_, p1) = readULEB128(at: pos); pos = p1
            let (byteLen, p2) = readULEB128(at: pos); pos = p2
            guard pos + Int(byteLen) <= data.count else { throw BinaryXMLParserError.truncated }
            let bytes = data.subdata(in: pos..<pos + Int(byteLen))
            guard let s = String(data: bytes, encoding: .utf8) else {
                throw BinaryXMLParserError.invalidStringIndex(0)
            }
            return s
        } else {
            // UTF-16: ULEB128 char length * 2 bytes, null-terminated.
            let (charLen, p1) = readULEB128(at: pos); pos = p1
            let byteLen = Int(charLen) * 2
            guard pos + byteLen <= data.count else { throw BinaryXMLParserError.truncated }
            let bytes = data.subdata(in: pos..<pos + byteLen)
            guard let s = String(data: bytes, encoding: .utf16LittleEndian) else {
                throw BinaryXMLParserError.invalidStringIndex(0)
            }
            return s
        }
    }

    // MARK: - Resource map

    private func parseResourceMap(at offset: Int, headerSize: Int, chunkSize: Int) {
        let count = (chunkSize - headerSize) / 4
        let base = offset + headerSize
        for i in 0..<count {
            resourceMap.append(readUInt32(at: base + i * 4))
        }
    }

    // MARK: - Elements

    private func parseStartElement(at offset: Int, headerSize: Int) throws {
        // Start element header:
        // uint32 lineNumber, comment, nsUri, nameIdx, attributeStart, attributeSize,
        // attributeCount, idIndex, classIndex, styleIndex
        let lineNumber = readUInt32(at: offset + 8)
        let nsUri = readUInt32(at: offset + 12)
        let nameIdx = readUInt32(at: offset + 16)
        let attrStart = Int(readUInt16(at: offset + 20))
        let attrSize = Int(readUInt16(at: offset + 22))
        let attrCount = Int(readUInt16(at: offset + 24))

        var attrs: [AXMLAttribute] = []
        var attrOffset = offset + attrStart
        for _ in 0..<attrCount {
            guard attrOffset + 20 <= data.count else { throw BinaryXMLParserError.truncated }
            let ns = readUInt32(at: attrOffset)
            let name = readUInt32(at: attrOffset + 4)
            let rawValue = readUInt32(at: attrOffset + 8)
            let tvSize = readUInt16(at: attrOffset + 12)
            let tvRes0 = data[attrOffset + 14]
            let tvType = data[attrOffset + 15]
            let tvData = readUInt32(at: attrOffset + 16)
            attrs.append(AXMLAttribute(
                namespaceUri: ns,
                nameIndex: name,
                rawValue: rawValue,
                typedValue: AXMLTypedValue(size: tvSize, res0: tvRes0, dataType: tvType, data: tvData)
            ))
            attrOffset += attrSize
        }

        let element = AXMLStartElement(lineNumber: lineNumber,
                                       namespaceUri: nsUri,
                                       nameIndex: nameIdx,
                                       attributes: attrs)
        currentElement = element
        processElement(element)
    }

    private func parseEndElement(at offset: Int) {
        currentElement = nil
    }

    private func processElement(_ element: AXMLStartElement) {
        guard element.nameIndex < stringPool.count else { return }
        let name = stringPool[Int(element.nameIndex)]

        if name == "manifest" {
            for attr in element.attributes {
                let attrName = attr.nameIndex < stringPool.count ? stringPool[Int(attr.nameIndex)] : ""
                if attrName == "package" {
                    manifest.packageName = attrValueString(attr) ?? ""
                } else if attrName == "versionCode" {
                    manifest.versionCode = Int(attr.typedValue.data)
                }
            }
        } else if name == "application" {
            for attr in element.attributes {
                let attrName = attr.nameIndex < stringPool.count ? stringPool[Int(attr.nameIndex)] : ""
                if attrName == "label" {
                    manifest.applicationLabel = attrValueString(attr) ?? ""
                } else if attrName == "icon" {
                    manifest.applicationIcon = attrValueString(attr) ?? ""
                }
            }
        } else if name == "activity" {
            var activityName = ""
            for attr in element.attributes {
                let attrName = attr.nameIndex < stringPool.count ? stringPool[Int(attr.nameIndex)] : ""
                if attrName == "name" {
                    activityName = attrValueString(attr) ?? ""
                }
            }
            let record = ActivityRecord(name: activityName, isMain: false, isLauncher: false)
            manifest.activities.append(record)
        } else if name == "intent-filter" || name == "action" || name == "category" {
            // These are handled below by scanning attributes.
            ()
        }

        // Simple intent-filter heuristic: scan attributes for action/category names.
        for attr in element.attributes {
            let attrName = attr.nameIndex < stringPool.count ? stringPool[Int(attr.nameIndex)] : ""
            if attrName == "name" {
                let value = attrValueString(attr) ?? ""
                if value == "android.intent.action.MAIN" {
                    if let last = manifest.activities.last {
                        manifest.activities[manifest.activities.count - 1] = ActivityRecord(
                            name: last.name, isMain: true, isLauncher: last.isLauncher)
                    }
                } else if value == "android.intent.category.LAUNCHER" {
                    if let last = manifest.activities.last {
                        manifest.activities[manifest.activities.count - 1] = ActivityRecord(
                            name: last.name, isMain: last.isMain, isLauncher: true)
                    }
                }
            }
        }

        // Pick main activity.
        if manifest.mainActivity.isEmpty {
            for act in manifest.activities where act.isMain && act.isLauncher {
                manifest.mainActivity = act.name
                break
            }
        }
    }

    private func attrValueString(_ attr: AXMLAttribute) -> String? {
        if attr.typedValue.dataType == 0x03 { // TYPE_STRING
            let idx = attr.typedValue.data
            guard idx < stringPool.count else { return nil }
            return stringPool[Int(idx)]
        }
        // Fallback to raw string index.
        if attr.rawValue < stringPool.count {
            return stringPool[Int(attr.rawValue)]
        }
        return nil
    }

    // MARK: - Low-level readers

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readULEB128(at offset: Int) -> (value: UInt32, next: Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var i = offset
        while i < data.count {
            let byte = data[i]
            i += 1
            result |= UInt32(byte & 0x7f) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
        }
        return (result, i)
    }
}

/// Generic Android binary XML decoder used for layouts under res/layout*.
/// It preserves element names and basic typed attributes as text XML that the
/// lightweight LayoutInflater can consume.
public final class BinaryXMLDocumentDecoder {
    private let data: Data
    private var stringPool: [String] = []

    public init(data: Data) {
        self.data = data
    }

    public func decode() throws -> String {
        guard data.count >= 8 else { throw BinaryXMLParserError.truncated }
        let type = readUInt16(at: 0)
        guard type == 0x0003 else { throw BinaryXMLParserError.invalidChunkType(type) }
        let headerSize = Int(readUInt16(at: 2))
        let chunkSize = Int(readUInt32(at: 4))
        guard data.count >= chunkSize else { throw BinaryXMLParserError.truncated }

        var output = ""
        var depth = 0
        var offset = headerSize

        while offset < chunkSize {
            guard offset + 8 <= data.count else { throw BinaryXMLParserError.truncated }
            let childType = readUInt16(at: offset)
            let childHeaderSize = Int(readUInt16(at: offset + 2))
            let childChunkSize = Int(readUInt32(at: offset + 4))
            guard childChunkSize > 0, offset + childChunkSize <= data.count else {
                throw BinaryXMLParserError.truncated
            }

            guard let kind = AXMLChunkType(rawValue: childType) else {
                offset += childChunkSize
                continue
            }

            switch kind {
            case .stringPool:
                try parseStringPool(at: offset, headerSize: childHeaderSize)
            case .startElement:
                let element = try readStartElement(at: offset)
                let name = try string(at: element.nameIndex)
                let attrs = try element.attributes
                    .map { try "\(attributeName($0))=\"\(attributeValue($0))\"" }
                    .joined(separator: " ")
                let indent = String(repeating: "  ", count: depth)
                output += attrs.isEmpty ? "\(indent)<\(name)>\n" : "\(indent)<\(name) \(attrs)>\n"
                depth += 1
            case .endElement:
                let nameIndex = readUInt32(at: offset + 16)
                depth = max(0, depth - 1)
                let indent = String(repeating: "  ", count: depth)
                output += "\(indent)</\(try string(at: nameIndex))>\n"
            default:
                break
            }

            offset += childChunkSize
        }

        return output
    }

    private func parseStringPool(at offset: Int, headerSize: Int) throws {
        let stringCount = Int(readUInt32(at: offset + 8))
        let flags = readUInt32(at: offset + 16)
        let stringsStart = Int(readUInt32(at: offset + 20))
        let isUTF8 = (flags & 0x100) != 0
        let offsetsOffset = offset + headerSize

        stringPool.removeAll(keepingCapacity: true)
        stringPool.reserveCapacity(stringCount)
        for i in 0..<stringCount {
            let relativeOffset = Int(readUInt32(at: offsetsOffset + i * 4))
            let absoluteOffset = offset + stringsStart + relativeOffset
            stringPool.append(try decodeString(at: absoluteOffset, isUTF8: isUTF8))
        }
    }

    private func readStartElement(at offset: Int) throws -> AXMLStartElement {
        let lineNumber = readUInt32(at: offset + 8)
        let nsUri = readUInt32(at: offset + 12)
        let nameIdx = readUInt32(at: offset + 16)
        let attrStart = Int(readUInt16(at: offset + 20))
        let attrSize = Int(readUInt16(at: offset + 22))
        let attrCount = Int(readUInt16(at: offset + 24))

        var attrs: [AXMLAttribute] = []
        var attrOffset = offset + attrStart
        for _ in 0..<attrCount {
            guard attrOffset + 20 <= data.count else { throw BinaryXMLParserError.truncated }
            attrs.append(AXMLAttribute(
                namespaceUri: readUInt32(at: attrOffset),
                nameIndex: readUInt32(at: attrOffset + 4),
                rawValue: readUInt32(at: attrOffset + 8),
                typedValue: AXMLTypedValue(
                    size: readUInt16(at: attrOffset + 12),
                    res0: data[attrOffset + 14],
                    dataType: data[attrOffset + 15],
                    data: readUInt32(at: attrOffset + 16)
                )
            ))
            attrOffset += attrSize
        }

        return AXMLStartElement(lineNumber: lineNumber,
                                namespaceUri: nsUri,
                                nameIndex: nameIdx,
                                attributes: attrs)
    }

    private func attributeName(_ attr: AXMLAttribute) throws -> String {
        let name = try string(at: attr.nameIndex)
        if attr.namespaceUri != 0xffffffff,
           let namespace = try? string(at: attr.namespaceUri),
           namespace.contains("schemas.android.com/apk/res/android") {
            return "android:\(name)"
        }
        return name
    }

    private func attributeValue(_ attr: AXMLAttribute) throws -> String {
        if attr.rawValue != 0xffffffff,
           attr.rawValue < UInt32(stringPool.count) {
            return escape(try string(at: attr.rawValue))
        }

        let name = try attributeName(attr)
        let value = attr.typedValue
        switch value.dataType {
        case 0x01: // TYPE_REFERENCE
            return String(value.data)
        case 0x03: // TYPE_STRING
            return escape(try string(at: value.data))
        case 0x05: // TYPE_DIMENSION
            return decodeDimension(value.data)
        case 0x10: // TYPE_INT_DEC
            if name.hasSuffix("layout_width") || name.hasSuffix("layout_height") {
                if value.data == 0xffffffff { return "match_parent" }
                if value.data == 0xfffffffe { return "wrap_content" }
            }
            return String(Int32(bitPattern: value.data))
        case 0x11: // TYPE_INT_HEX
            return String(format: "0x%08x", value.data)
        case 0x12: // TYPE_INT_BOOLEAN
            return value.data == 0 ? "false" : "true"
        case 0x1c, 0x1d, 0x1e, 0x1f: // colors
            return String(format: "#%08x", value.data)
        default:
            return String(value.data)
        }
    }

    private func decodeDimension(_ data: UInt32) -> String {
        let unitNames = ["px", "dp", "sp", "pt", "in", "mm"]
        let unit = Int(data & 0xf)
        let signed = Int32(bitPattern: data) >> 8
        let suffix = unit < unitNames.count ? unitNames[unit] : "px"
        return "\(signed)\(suffix)"
    }

    private func string(at index: UInt32) throws -> String {
        guard index < UInt32(stringPool.count) else {
            throw BinaryXMLParserError.invalidStringIndex(index)
        }
        return stringPool[Int(index)]
    }

    private func escape(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func decodeString(at offset: Int, isUTF8: Bool) throws -> String {
        var pos = offset
        if isUTF8 {
            let (_, p1) = readULEB128(at: pos); pos = p1
            let (byteLen, p2) = readULEB128(at: pos); pos = p2
            guard pos + Int(byteLen) <= data.count else { throw BinaryXMLParserError.truncated }
            let bytes = data.subdata(in: pos..<pos + Int(byteLen))
            guard let s = String(data: bytes, encoding: .utf8) else {
                throw BinaryXMLParserError.invalidStringIndex(0)
            }
            return s
        }

        let (charLen, p1) = readULEB128(at: pos); pos = p1
        let byteLen = Int(charLen) * 2
        guard pos + byteLen <= data.count else { throw BinaryXMLParserError.truncated }
        let bytes = data.subdata(in: pos..<pos + byteLen)
        guard let s = String(data: bytes, encoding: .utf16LittleEndian) else {
            throw BinaryXMLParserError.invalidStringIndex(0)
        }
        return s
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readULEB128(at offset: Int) -> (value: UInt32, next: Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var i = offset
        while i < data.count {
            let byte = data[i]
            i += 1
            result |= UInt32(byte & 0x7f) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
        }
        return (result, i)
    }
}
