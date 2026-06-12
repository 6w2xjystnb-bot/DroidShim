//
//  ContainerModel.swift
//  DroidShimApp
//
//  Observable model for a single imported APK container.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import DroidShimCore

/// Container runtime state.
public enum ContainerState: String, Codable, CaseIterable {
    case installed
    case running
    case paused
    case error
}

/// Persisted container record.
public final class ContainerModel: ObservableObject, Identifiable, Codable {
    public let id: UUID
    public let package: String
    public let name: String
    public let mainActivity: String
    public let vmPath: URL

    @Published public var state: ContainerState
    @Published public var icon: UIImage?

    public init(id: UUID = UUID(),
                package: String,
                name: String,
                mainActivity: String,
                vmPath: URL,
                state: ContainerState = .installed,
                icon: UIImage? = nil) {
        self.id = id
        self.package = package
        self.name = name
        self.mainActivity = mainActivity
        self.vmPath = vmPath
        self.state = state
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey {
        case id, package, name, mainActivity, vmPath, state
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        package = try c.decode(String.self, forKey: .package)
        name = try c.decode(String.self, forKey: .name)
        mainActivity = try c.decode(String.self, forKey: .mainActivity)
        vmPath = try c.decode(URL.self, forKey: .vmPath)
        state = try c.decode(ContainerState.self, forKey: .state)
        icon = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(package, forKey: .package)
        try c.encode(name, forKey: .name)
        try c.encode(mainActivity, forKey: .mainActivity)
        try c.encode(vmPath, forKey: .vmPath)
        try c.encode(state, forKey: .state)
    }
}
#endif
