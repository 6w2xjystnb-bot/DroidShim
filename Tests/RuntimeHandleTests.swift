//
//  RuntimeHandleTests.swift
//  DroidShimTests
//

import XCTest
@testable import DroidShimCore

final class RuntimeHandleTests: XCTestCase {
    func testHeapReferencesRoundTripWithoutRawPointers() {
        let object = JavaHeap.shared.allocate(className: "com.example.MainActivity")
        let reference = JavaHeap.shared.reference(for: object)

        XCTAssertNotEqual(reference, 0)
        XCTAssertTrue(JavaHeap.shared.object(for: reference) === object)
        XCTAssertNil(JavaHeap.shared.object(for: 0))
    }

    func testManagedReferencesKeepObjectsAliveDuringCollection() {
        let object = JavaHeap.shared.allocate(className: "java.lang.String")
        let reference = JavaHeap.shared.reference(for: object)

        JavaHeap.shared.collect(roots: [])

        XCTAssertTrue(JavaHeap.shared.object(for: reference) === object)
    }
}
