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
}
