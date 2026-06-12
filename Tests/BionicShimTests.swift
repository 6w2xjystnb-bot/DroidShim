//
//  BionicShimTests.swift
//  DroidShimTests
//

import XCTest
import DroidShimCore

final class BionicShimTests: XCTestCase {

    func testInitializeShim() {
        droidshim_initialize_shim()
    }

    func testFdTable() {
        let path = "/tmp/test"
        path.withCString { cstr in
            droidshim_fd_register(42, cstr)
        }
        if let cpath = droidshim_fd_path(42) {
            XCTAssertEqual(String(cString: cpath), path)
        } else {
            XCTFail("fd path not found")
        }
        droidshim_fd_unregister(42)
        XCTAssertNil(droidshim_fd_path(42))
    }
}
