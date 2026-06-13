//
//  ContainerApp.swift
//  DroidShimApp
//
//  SwiftUI app entry point.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
import DroidShimCore

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DroidShimBootstrap.initialize()
        return true
    }
}

@main
struct DroidShimApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = ContainerEngine()

    var body: some Scene {
        WindowGroup {
            ContainerGridView()
                .environmentObject(engine)
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await engine.installImportedAPK(from: url)
                        } catch {
                            print("Open APK error: \(error)")
                        }
                    }
                }
        }
    }
}
#else
@main
struct DroidShimApp: App {
    var body: some Scene {
        WindowGroup {
            Text("DroidShim requires iOS.")
        }
    }
}
#endif
