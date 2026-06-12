//
//  MachOWriterTests.swift
//  DroidShimTests
//

import XCTest
import DroidShimCore
import DroidShimNative

final class MachOWriterTests: XCTestCase {

    func testGenerateMachO() throws {
        let elfData = Data(repeating: 0, count: 128)
        let bridge = DSBinaryBridge()
        XCTAssertEqual(bridge.parseELF(elfData), -1)

        // The minimal ELF above lacks sections; conversion will fail gracefully.
        var error: NSString?
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("test.dylib")
        let ok = bridge.writeMachO(toPath: temp.path, installName: "com.test", error: &error)
        XCTAssertFalse(ok, "Conversion should fail for invalid ELF")
    }
}
