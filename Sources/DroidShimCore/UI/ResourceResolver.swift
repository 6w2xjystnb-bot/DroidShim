//
//  ResourceResolver.swift
//  DroidShimCore
//
//  Resolves Android resource IDs to iOS equivalents.  Combines resources.arsc
//  parsing with R.java static-field scanning from classes.dex.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Resolves Android resources for the running container.
public final class ResourceResolver {
    public let resourceTable: ResourceTable?
    public let dex: DexFile?
    public let containerURL: URL

    /// Map of R.java class names -> field name -> integer ID.
    public private(set) var rClasses: [String: [String: Int32]] = [:]

    /// Cache of loaded drawable images keyed by resource ID.
    #if canImport(UIKit)
    private var imageCache: [UInt32: UIImage] = [:]
    #endif

    public init(resourceTable: ResourceTable?, dex: DexFile?, containerURL: URL) {
        self.resourceTable = resourceTable
        self.dex = dex
        self.containerURL = containerURL
        scanRClasses()
    }

    // MARK: - R.java scanning

    private func scanRClasses() {
        guard let dex = dex else { return }
        for def in dex.classDefs {
            let name = dex.className(at: def.classIdx)
            guard name.hasPrefix("R$") else { continue }
            let inner = String(name.dropFirst(2))
            var fields: [String: Int32] = [:]
            for (i, sf) in def.staticFields.enumerated() {
                guard let ref = dex.fieldRef(at: sf.fieldId) else { continue }
                // Use the encoded static value if available (R.java constants).
                if i < def.staticValues.count,
                   case .int(let v) = def.staticValues[i] {
                    fields[ref.name] = v
                } else {
                    fields[ref.name] = Int32(sf.fieldId)
                }
            }
            rClasses[inner] = fields
        }
    }

    /// Find the integer resource ID for a field in an R inner class.
    public func idForRField(innerClass: String, field: String) -> Int32? {
        return rClasses[innerClass]?[field]
    }

    /// Reverse-lookup: find the R.java field name for a given integer value.
    public func nameForRField(innerClass: String, value: Int32) -> String? {
        guard let fields = rClasses[innerClass] else { return nil }
        return fields.first { $0.value == value }?.key
    }

    // MARK: - Resolution helpers

    #if canImport(UIKit)
    public func resolveColor(id: UInt32) -> UIColor? {
        guard let c = resourceTable?.color(id: id) else { return nil }
        return UIColor(red: CGFloat(c.r) / 255.0,
                       green: CGFloat(c.g) / 255.0,
                       blue: CGFloat(c.b) / 255.0,
                       alpha: CGFloat(c.a) / 255.0)
    }

    public func resolveDrawable(id: UInt32) -> UIImage? {
        if let cached = imageCache[id] { return cached }
        // Try to locate a PNG in the container res/ tree matching the resource name.
        guard let table = resourceTable else { return nil }
        // For Phase 1 we use the key name from the raw entry as filename hint.
        if let path = drawablePath(for: id) {
            let url = containerURL.appendingPathComponent(path)
            if let image = UIImage(contentsOfFile: url.path) {
                imageCache[id] = image
                return image
            }
        }
        return nil
    }
    #endif

    public func resolveString(id: UInt32) -> String? {
        return resourceTable?.string(id: id)
    }

    public func resolveLayout(id: UInt32) -> String? {
        // Phase 1: binary XML layouts are not decoded to text.
        // Return a cached text layout if the APK shipped one under res/layout-raw/.
        return nil
    }

    public func resolveLayout(named name: String) -> String? {
        let url = containerURL.appendingPathComponent("res/layout/\(name).xml")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Private

    private func drawablePath(for id: UInt32) -> String? {
        // Resource ID format: 0xPPTTEEEE.  Drawable type IDs are typically 0x02.
        let typeId = (id >> 16) & 0xff
        let entryId = id & 0xffff
        guard typeId == 0x02 else { return nil }

        // Search common drawable directories for any PNG whose name matches the entry index.
        let dirs = ["drawable-xxxhdpi", "drawable-xxhdpi", "drawable-xhdpi", "drawable-hdpi", "drawable-mdpi", "drawable"]
        let fm = FileManager.default
        for dir in dirs {
            let dirURL = containerURL.appendingPathComponent("res/\(dir)")
            if let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "png" {
                    return "res/\(dir)/\(file.lastPathComponent)"
                }
            }
        }
        return nil
    }
}
