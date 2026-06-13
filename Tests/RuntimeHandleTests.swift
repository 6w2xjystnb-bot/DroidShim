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

    func testInvoke35cDecodesMethodWordBeforeRegisterWord() {
        let decoded = ARTInterpreter.decodeInvoke35c(
            first: 0x526e,
            methodWord: 0x1234,
            registerWord: 0x4321
        )

        XCTAssertEqual(decoded.argumentCount, 2)
        XCTAssertEqual(decoded.methodIndex, 0x1234)
        XCTAssertEqual(decoded.registers, [1, 2, 3, 4, 5])
    }
}
