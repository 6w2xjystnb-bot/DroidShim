//
//  ContainerEngine.swift
//  DroidShimApp
//
//  Orchestrates APK install, .so conversion, and Activity launch.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import DroidShimCore

/// Errors raised by the container engine.
public enum ContainerEngineError: Error, CustomStringConvertible {
    case invalidMetadata
    case conversionFailed(String)
    case codesignFailed(Int32)
    case launchFailed(String)
    case importFailed(String)

    public var description: String {
        switch self {
        case .invalidMetadata: return "Invalid APK metadata"
        case .conversionFailed(let msg): return "Conversion failed: \(msg)"
        case .codesignFailed(let code): return "codesign exited \(code)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        case .importFailed(let msg): return "Import failed: \(msg)"
        }
    }
}

public enum ContainerEngineActivity: Equatable {
    case idle
    case importing(String)
    case launching(String)
    case failed(String)

    public var message: String? {
        switch self {
        case .idle: return nil
        case .importing(let name): return "Importing \(name)..."
        case .launching(let name): return "Launching \(name)..."
        case .failed(let message): return message
        }
    }
}

/// Central engine managing all containers.
@MainActor
public final class ContainerEngine: ObservableObject {
    @Published public var containers: [ContainerModel] = []
    @Published public var activity: ContainerEngineActivity = .idle

    private let parser = APKParser()
    private let registryKey = "droidshim.containers"

    public init() {
        loadRegistry()
    }

    // MARK: - Registry persistence

    private func loadRegistry() {
        guard let data = UserDefaults.standard.data(forKey: registryKey),
              let list = try? JSONDecoder().decode([ContainerModel].self, from: data) else {
            return
        }
        containers = list
        for i in containers.indices {
            let iconURL = containers[i].vmPath.appendingPathComponent("icon.png")
            containers[i].icon = UIImage(contentsOfFile: iconURL.path)
        }
    }

    private func saveRegistry() {
        if let data = try? JSONEncoder().encode(containers) {
            UserDefaults.standard.set(data, forKey: registryKey)
        }
    }

    // MARK: - Install

    @discardableResult
    public func openAPK(from url: URL, launchAfterInstall: Bool) async throws -> ContainerModel {
        activity = .importing(url.lastPathComponent)
        do {
            let container = try await installImportedAPK(from: url)
            if launchAfterInstall {
                activity = .launching(container.name)
                launch(container)
            } else {
                activity = .idle
            }
            return container
        } catch {
            let message = describe(error)
            activity = .failed(message)
            throw error
        }
    }

    public func installImportedAPK(from url: URL) async throws -> ContainerModel {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let stagedURL = try stageAPKForImport(url)
        return try await install(apkURL: stagedURL)
    }

    public func install(apkURL: URL) async throws -> ContainerModel {
        let metadata = try parser.parse(url: apkURL)

        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let containerURL = base.appendingPathComponent("Containers/\(metadata.package)")
        if FileManager.default.fileExists(atPath: containerURL.path) {
            try FileManager.default.removeItem(at: containerURL)
        }
        try parser.extractToContainer(metadata: metadata, containerURL: containerURL)
        appendLog("Installed \(metadata.package) from \(apkURL.lastPathComponent)", to: containerURL)

        // Convert each arm64 .so to Mach-O and codesign.
        let frameworksURL = containerURL.appendingPathComponent("Frameworks")
        for (name, data) in metadata.nativeLibs {
            let baseName = (name as NSString).lastPathComponent
            let outName = baseName.replacingOccurrences(of: ".so", with: ".dylib")
            let outURL = frameworksURL.appendingPathComponent(outName)

            try DroidShimNativeConverter.convertELFToMachO(
                data: data,
                outputPath: outURL.path,
                installName: metadata.package + "." + outName
            )

            try codesign(url: outURL)
        }

        let iconURL = containerURL.appendingPathComponent("icon.png")
        let icon = UIImage(contentsOfFile: iconURL.path)

        let container = ContainerModel(
            package: metadata.package,
            name: metadata.displayName,
            mainActivity: metadata.mainActivity,
            vmPath: containerURL,
            state: .installed,
            icon: icon
        )

        containers.removeAll { $0.package == container.package }
        containers.append(container)
        saveRegistry()
        return container
    }

    private func stageAPKForImport(_ sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw ContainerEngineError.importFailed("File is not accessible: \(sourceURL.lastPathComponent)")
        }

        let importsURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ImportedAPKs", isDirectory: true)
        try fm.createDirectory(at: importsURL, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let fileName = (baseName.isEmpty ? UUID().uuidString : baseName) + ".apk"
        let stagedURL = importsURL.appendingPathComponent(fileName)

        if fm.fileExists(atPath: stagedURL.path) {
            try fm.removeItem(at: stagedURL)
        }
        try fm.copyItem(at: sourceURL, to: stagedURL)
        return stagedURL
    }

    private func codesign(url: URL) throws {
        #if os(macOS)
        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["-s", "-", "--force", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.launch()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw ContainerEngineError.codesignFailed(task.terminationStatus)
        }
        #else
        // On iOS the dylib must already be ad-hoc signed; skip external codesign.
        _ = url
        #endif
    }

    // MARK: - Launch

    public func launch(_ container: ContainerModel) {
        Task { @MainActor in
            do {
                activity = .launching(container.name)
                appendLog("Launching \(container.package)", to: container.vmPath)
                let dexData = try Data(contentsOf: container.vmPath.appendingPathComponent("classes.dex"))
                let dex = try DexFile(data: dexData)
                let interpreter = ARTInterpreter(dex: dex)

                let arscURL = container.vmPath.appendingPathComponent("resources.arsc")
                let arscData = try Data(contentsOf: arscURL)
                let table = try ResourceTable(data: arscData)

                let resolver = ResourceResolver(resourceTable: table, dex: dex, containerURL: container.vmPath)
                let registry = JNIRegistry.shared
                let frameworksURL = container.vmPath.appendingPathComponent("Frameworks")
                let libPath = frameworksURL.appendingPathComponent("libmain.dylib").path
                if FileManager.default.fileExists(atPath: libPath) {
                    _ = try? registry.loadLibrary(path: libPath)
                }

                // Load main activity class from manifest.
                let mainActivity = container.mainActivity
                guard !mainActivity.isEmpty else {
                    throw ContainerEngineError.launchFailed("No MAIN/LAUNCHER activity in manifest")
                }

                let mapper = ViewMapper(resolver: resolver,
                                        jniRegistry: registry,
                                        libraryPath: libPath,
                                        activityClassName: mainActivity)
                mapper.javaTapHandler = { methodName in
                    do {
                        guard let def = interpreter.classDef(named: mainActivity) else { return }
                        for m in def.directMethods + def.virtualMethods {
                            if interpreter.dex.methodRef(at: m.methodId)?.name == methodName {
                                _ = try interpreter.execute(method: m, args: [.object(nil)])
                                break
                            }
                        }
                    } catch {
                        print("Tap handler error: \(error)")
                    }
                }

                let activity = ActivityBridge(
                    className: mainActivity,
                    interpreter: interpreter,
                    viewMapper: mapper,
                    resourceResolver: resolver
                )

                container.state = .running
                if let window = UIApplication.shared.keyWindow {
                    window.rootViewController = activity.viewController
                }
                activity.onCreate(savedInstanceState: nil)
                activity.onResume()
                self.activity = .idle
            } catch {
                container.state = .error
                let message = "Launch error: \(describe(error))"
                appendLog(message, to: container.vmPath)
                activity = .failed(message)
                print(message)
            }
        }
    }

    // MARK: - Pause / Resume / Uninstall

    public func pause(_ container: ContainerModel) {
        container.state = .paused
        saveRegistry()
    }

    public func resume(_ container: ContainerModel) {
        container.state = .running
        saveRegistry()
    }

    public func uninstall(_ container: ContainerModel) {
        try? FileManager.default.removeItem(at: container.vmPath)
        containers.removeAll { $0.id == container.id }
        saveRegistry()
    }

    public func exportLogs(_ container: ContainerModel) -> URL {
        let logURL = container.vmPath.appendingPathComponent("droidshim.log")
        return logURL
    }

    public func clearActivity() {
        activity = .idle
    }

    private func describe(_ error: Error) -> String {
        if let custom = error as? CustomStringConvertible {
            return custom.description
        }
        return error.localizedDescription
    }

    private func appendLog(_ message: String, to containerURL: URL) {
        let logURL = containerURL.appendingPathComponent("droidshim.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
#endif
