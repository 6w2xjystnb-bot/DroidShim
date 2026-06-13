//
//  APKParserTests.swift
//  DroidShimTests
//

import XCTest
@testable import DroidShimCore

final class APKParserTests: XCTestCase {

    func testBinaryXMLParserPlaceholder() {
        // Phase 1: empty AXML is invalid.
        let parser = BinaryXMLParser(data: Data())
        XCTAssertThrowsError(try parser.parse())
    }

    func testDexLoaderPlaceholder() {
        // Empty DEX is invalid.
        XCTAssertThrowsError(try DexFile(data: Data()))
    }

    func testZipArchiveExtractsStoredEntryWithLocalExtraField() throws {
        let payload = Data("hello apk".utf8)
        let archiveData = makeStoredZip(
            name: "assets/payload.txt",
            payload: payload,
            localExtra: Data([0xde, 0xad, 0xbe, 0xef]),
            centralExtra: Data()
        )

        let archive = try XCTUnwrap(ZipArchive(data: archiveData))
        let entry = try XCTUnwrap(archive.entry(named: "assets/payload.txt"))
        XCTAssertEqual(archive.extract(entry: entry), payload)
    }

    func testBinaryXMLDocumentDecoderProducesInflatableLayoutXML() throws {
        let layoutData = makeBinaryLayoutXML()
        let xml = try BinaryXMLDocumentDecoder(data: layoutData).decode()

        XCTAssertTrue(xml.contains("<LinearLayout android:layout_width=\"match_parent\" android:layout_height=\"match_parent\">"))
        XCTAssertTrue(xml.contains("<TextView android:text=\"Hello\">"))
        XCTAssertTrue(xml.contains("</LinearLayout>"))
    }

    private func makeStoredZip(name: String,
                               payload: Data,
                               localExtra: Data = Data(),
                               centralExtra: Data = Data()) -> Data {
        let nameData = Data(name.utf8)
        var data = Data()

        let localHeaderOffset = UInt32(data.count)
        appendUInt32(0x04034b50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        appendUInt16(UInt16(nameData.count), to: &data)
        appendUInt16(UInt16(localExtra.count), to: &data)
        data.append(nameData)
        data.append(localExtra)
        data.append(payload)

        let centralDirectoryOffset = UInt32(data.count)
        appendUInt32(0x02014b50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        appendUInt16(UInt16(nameData.count), to: &data)
        appendUInt16(UInt16(centralExtra.count), to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(localHeaderOffset, to: &data)
        data.append(nameData)
        data.append(centralExtra)

        let centralDirectorySize = UInt32(data.count) - centralDirectoryOffset
        appendUInt32(0x06054b50, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(centralDirectorySize, to: &data)
        appendUInt32(centralDirectoryOffset, to: &data)
        appendUInt16(0, to: &data)

        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func makeBinaryLayoutXML() -> Data {
        let strings = [
            "http://schemas.android.com/apk/res/android",
            "LinearLayout",
            "layout_width",
            "layout_height",
            "TextView",
            "text",
            "Hello"
        ]
        var chunks = Data()
        chunks.append(makeStringPool(strings))
        chunks.append(makeStartElement(nameIndex: 1, attributes: [
            (namespace: UInt32(0), name: UInt32(2), raw: UInt32.max, type: UInt8(0x10), data: UInt32.max),
            (namespace: UInt32(0), name: UInt32(3), raw: UInt32.max, type: UInt8(0x10), data: 0xffffffff)
        ]))
        chunks.append(makeStartElement(nameIndex: 4, attributes: [
            (namespace: UInt32(0), name: UInt32(5), raw: UInt32(6), type: UInt8(0x03), data: UInt32(6))
        ]))
        chunks.append(makeEndElement(nameIndex: 4))
        chunks.append(makeEndElement(nameIndex: 1))

        var data = Data()
        appendUInt16(0x0003, to: &data)
        appendUInt16(8, to: &data)
        appendUInt32(UInt32(8 + chunks.count), to: &data)
        data.append(chunks)
        return data
    }

    private func makeStringPool(_ strings: [String]) -> Data {
        var encoded = Data()
        var offsets: [UInt32] = []
        for string in strings {
            offsets.append(UInt32(encoded.count))
            let bytes = Array(string.utf8)
            encoded.append(UInt8(bytes.count))
            encoded.append(UInt8(bytes.count))
            encoded.append(contentsOf: bytes)
            encoded.append(0)
        }

        var data = Data()
        let stringsStart = UInt32(28 + strings.count * 4)
        appendUInt16(0x0001, to: &data)
        appendUInt16(28, to: &data)
        appendUInt32(stringsStart + UInt32(encoded.count), to: &data)
        appendUInt32(UInt32(strings.count), to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0x100, to: &data)
        appendUInt32(stringsStart, to: &data)
        appendUInt32(0, to: &data)
        for offset in offsets {
            appendUInt32(offset, to: &data)
        }
        data.append(encoded)
        return data
    }

    private typealias TestAXMLAttribute = (namespace: UInt32, name: UInt32, raw: UInt32, type: UInt8, data: UInt32)

    private func makeStartElement(nameIndex: UInt32, attributes: [TestAXMLAttribute]) -> Data {
        var data = Data()
        let attrStart: UInt16 = 28
        appendUInt16(0x0102, to: &data)
        appendUInt16(attrStart, to: &data)
        appendUInt32(UInt32(Int(attrStart) + attributes.count * 20), to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendUInt32(nameIndex, to: &data)
        appendUInt16(attrStart, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(UInt16(attributes.count), to: &data)
        appendUInt16(0, to: &data)
        for attribute in attributes {
            appendUInt32(attribute.namespace, to: &data)
            appendUInt32(attribute.name, to: &data)
            appendUInt32(attribute.raw, to: &data)
            appendUInt16(8, to: &data)
            data.append(0)
            data.append(attribute.type)
            appendUInt32(attribute.data, to: &data)
        }
        return data
    }

    private func makeEndElement(nameIndex: UInt32) -> Data {
        var data = Data()
        appendUInt16(0x0103, to: &data)
        appendUInt16(24, to: &data)
        appendUInt32(24, to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendUInt32(nameIndex, to: &data)
        appendUInt32(0, to: &data)
        return data
    }
}
