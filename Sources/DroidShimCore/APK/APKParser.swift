//
//  APKParser.swift
//  DroidShimCore
//
//  High-level APK importer.  Unzips the archive, parses AndroidManifest.xml,
//  extracts DEX, native libraries, resources.arsc and the launcher icon.
//

import Foundation
import Compression

/// Errors raised by APK parsing.
public enum APKParserError: Error, CustomStringConvertible {
    case notFound(URL)
    case invalidZip
    case missingManifest
    case missingDex
    case missingResources

    public var description: String {
        switch self {
        case .notFound(let url): return "APK not found at \(url)"
        case .invalidZip: return "Invalid APK/ZIP archive"
        case .missingManifest: return "AndroidManifest.xml missing"
        case .missingDex: return "classes.dex missing"
        case .missingResources: return "resources.arsc missing"
        }
    }
}

/// Parsed APK metadata.
public struct APKMetadata {
    public let package: String
    public let versionCode: Int
    public let mainActivity: String
    public let label: String
    public let iconPath: String
    public let dexData: Data
    public let arscData: Data
    public let nativeLibs: [String: Data]
    public let iconData: Data?

    public var displayName: String {
        return label.isEmpty ? package : label
    }
}

/// Parses APK archives.
public final class APKParser {
    public init() {}

    /// Parse an APK at the given URL and extract all required files.
    public func parse(url: URL) throws -> APKMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw APKParserError.notFound(url)
        }

        let data = try Data(contentsOf: url)
        guard let archive = ZipArchive(data: data) else {
            throw APKParserError.invalidZip
        }

        // AndroidManifest.xml
        guard let manifestEntry = archive.entry(named: "AndroidManifest.xml"),
              let manifestData = archive.extract(entry: manifestEntry) else {
            throw APKParserError.missingManifest
        }
        let manifest = try BinaryXMLParser(data: manifestData).parse()

        // classes.dex
        guard let dexEntry = archive.entry(named: "classes.dex"),
              let dexData = archive.extract(entry: dexEntry) else {
            throw APKParserError.missingDex
        }

        // resources.arsc
        guard let arscEntry = archive.entry(named: "resources.arsc"),
              let arscData = archive.extract(entry: arscEntry) else {
            throw APKParserError.missingResources
        }

        // Native libraries (arm64 only in Phase 1).
        var nativeLibs: [String: Data] = [:]
        let libPrefix = "lib/arm64-v8a/"
        for entry in archive.entries where entry.name.hasPrefix(libPrefix) && entry.name.hasSuffix(".so") {
            if let libData = archive.extract(entry: entry) {
                nativeLibs[entry.name] = libData
            }
        }

        // Launcher icon.
        let iconPath = bestIconPath(in: archive, manifestIcon: manifest.applicationIcon)
        let iconData = iconPath.flatMap { archive.entry(named: $0) }.flatMap { archive.extract(entry: $0) }

        return APKMetadata(
            package: manifest.packageName,
            versionCode: manifest.versionCode,
            mainActivity: manifest.mainActivity,
            label: manifest.applicationLabel,
            iconPath: iconPath ?? "",
            dexData: dexData,
            arscData: arscData,
            nativeLibs: nativeLibs,
            iconData: iconData
        )
    }

    /// Extract and cache APK contents to a container directory.
    @discardableResult
    public func extractToContainer(metadata: APKMetadata, containerURL: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: containerURL, withIntermediateDirectories: true)

        try metadata.dexData.write(to: containerURL.appendingPathComponent("classes.dex"))
        try metadata.arscData.write(to: containerURL.appendingPathComponent("resources.arsc"))
        if let icon = metadata.iconData {
            try icon.write(to: containerURL.appendingPathComponent("icon.png"))
        }

        let frameworksURL = containerURL.appendingPathComponent("Frameworks")
        try fm.createDirectory(at: frameworksURL, withIntermediateDirectories: true)
        for (name, data) in metadata.nativeLibs {
            let libName = (name as NSString).lastPathComponent
            try data.write(to: frameworksURL.appendingPathComponent(libName))
        }

        return containerURL
    }

    private func bestIconPath(in archive: ZipArchive, manifestIcon: String) -> String? {
        if !manifestIcon.isEmpty, archive.entry(named: manifestIcon) != nil {
            return manifestIcon
        }
        let densities = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"]
        for d in densities {
            let candidates = [
                "res/mipmap-\(d)/ic_launcher.png",
                "res/mipmap-\(d)/ic_launcher_foreground.png"
            ]
            for c in candidates where archive.entry(named: c) != nil {
                return c
            }
        }
        return nil
    }
}

// MARK: - Minimal in-memory ZIP parser using Compression framework.

private struct ZipEntry {
    let name: String
    let offset: Int
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let compressionMethod: UInt16
    let crc32: UInt32
}

private final class ZipArchive {
    let data: Data
    var entries: [ZipEntry] = []

    init?(data: Data) {
        self.data = data
        do {
            try scan()
        } catch {
            return nil
        }
    }

    func entry(named name: String) -> ZipEntry? {
        return entries.first { $0.name == name }
    }

    func extract(entry: ZipEntry) -> Data? {
        guard entry.offset + Int(entry.compressedSize) <= data.count else { return nil }
        let compressed = data.subdata(in: entry.offset..<entry.offset + Int(entry.compressedSize))

        if entry.compressionMethod == 0 {
            return compressed
        } else if entry.compressionMethod == 8 {
            return decompressZlib(compressed, uncompressedSize: Int(entry.uncompressedSize))
        }
        return nil
    }

    private func scan() throws {
        // Find End of Central Directory record.
        guard data.count > 22 else { throw APKParserError.invalidZip }
        var eocdOffset = 0
        for i in (0..<(data.count - 22)).reversed() {
            if data[i] == 0x50 && data[i+1] == 0x4B && data[i+2] == 0x05 && data[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset > 0 else { throw APKParserError.invalidZip }

        let cdCount = readUInt16(at: eocdOffset + 10)
        let cdSize = Int(readUInt32(at: eocdOffset + 12))
        let cdOffset = Int(readUInt32(at: eocdOffset + 16))

        var pos = cdOffset
        for _ in 0..<cdCount {
            let signature = readUInt32(at: pos)
            guard signature == 0x02014b50 else { throw APKParserError.invalidZip }
            let compression = readUInt16(at: pos + 10)
            let crc = readUInt32(at: pos + 16)
            let compSize = readUInt64Like(at: pos + 20)
            let uncompSize = readUInt64Like(at: pos + 24)
            let nameLen = Int(readUInt16(at: pos + 28))
            let extraLen = Int(readUInt16(at: pos + 30))
            let commentLen = Int(readUInt16(at: pos + 32))
            let localHeaderOffset = Int(readUInt32(at: pos + 42))
            let nameData = data.subdata(in: pos + 46..<pos + 46 + nameLen)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw APKParserError.invalidZip
            }

            entries.append(ZipEntry(
                name: name,
                offset: localHeaderOffset + 30 + nameLen + extraLen,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                compressionMethod: compression,
                crc32: crc
            ))

            pos += 46 + nameLen + extraLen + commentLen
        }
    }

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

    private func readUInt64Like(at offset: Int) -> UInt64 {
        // ZIP uses uint32 for sizes unless zip64.
        return UInt64(readUInt32(at: offset))
    }

    private func decompressZlib(_ data: Data, uncompressedSize: Int) -> Data? {
        var output = Data(count: uncompressedSize)
        let result = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { dest in
                compression_decode_buffer(
                    dest.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    uncompressedSize,
                    source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard result == uncompressedSize else { return nil }
        return output
    }
}
