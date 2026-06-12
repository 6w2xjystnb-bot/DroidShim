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
            let childType = readUInt16(at: offset)
            let childHeaderSize = Int(readUInt16(at: offset + 2))
            let childChunkSize = Int(readUInt32(at: offset + 4))

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
            let bytes = data.subdata(in: pos..<pos + Int(byteLen))
            guard let s = String(data: bytes, encoding: .utf8) else {
                throw BinaryXMLParserError.invalidStringIndex(0)
            }
            return s
        } else {
            // UTF-16: ULEB128 char length * 2 bytes, null-terminated.
            let (charLen, p1) = readULEB128(at: pos); pos = p1
            let byteLen = Int(charLen) * 2
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
