//
//  ELFReaderTests.swift
//  DroidShimTests
//

import XCTest
import DroidShimCore
import DroidShimNative

final class ELFReaderTests: XCTestCase {

    /// Build a minimal valid ELF64 AArch64 shared object as raw bytes.
    private func minimalELF() -> Data {
        var data = Data()

        // e_ident[16]
        data.append(contentsOf: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0,
                                  0, 0, 0, 0, 0, 0, 0, 0])
        // e_type (ET_DYN = 3)
        data.append(contentsOf: [0x03, 0x00])
        // e_machine (EM_AARCH64 = 183)
        data.append(contentsOf: [0xb7, 0x00])
        // e_version
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        // e_entry
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        // e_phoff = 64
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // e_shoff = 0
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        // e_flags
        data.append(contentsOf: Array(repeating: UInt8(0), count: 4))
        // e_ehsize = 64
        data.append(contentsOf: [0x40, 0x00])
        // e_phentsize = 56
        data.append(contentsOf: [0x38, 0x00])
        // e_phnum = 1
        data.append(contentsOf: [0x01, 0x00])
        // e_shentsize = 64
        data.append(contentsOf: [0x40, 0x00])
        // e_shnum = 0
        data.append(contentsOf: [0x00, 0x00])
        // e_shstrndx = 0
        data.append(contentsOf: [0x00, 0x00])

        // Program header: PT_LOAD
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // p_type
        data.append(contentsOf: [0x05, 0x00, 0x00, 0x00]) // p_flags
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // p_offset
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // p_vaddr
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // p_paddr
        data.append(contentsOf: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // p_filesz
        data.append(contentsOf: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // p_memsz
        data.append(contentsOf: [0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // p_align

        // Pad to 128 bytes.
        data.append(contentsOf: Array(repeating: UInt8(0), count: 128 - data.count))
        return data
    }

    func testParseMinimalELF() {
        let elfData = minimalELF()
        let bridge = DSBinaryBridge()
        let count = bridge.parseELF(elfData)
        XCTAssertEqual(count, 0, "Minimal ELF has no dynamic symbols")
    }

    func testInvalidMagicFails() {
        var data = minimalELF()
        data[0] = 0x00
        let bridge = DSBinaryBridge()
        let count = bridge.parseELF(data)
        XCTAssertEqual(count, -1, "Invalid magic should fail")
    }
}
