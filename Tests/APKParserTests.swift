//
//  APKParserTests.swift
//  DroidShimTests
//

import XCTest
import DroidShimCore

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
}
