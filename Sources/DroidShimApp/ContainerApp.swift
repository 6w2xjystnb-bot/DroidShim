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
import DroidShimNative

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        droidshim_initialize_shim()
        return true
    }
}

@main
struct DroidShimApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContainerGridView()
                .environmentObject(ContainerEngine())
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
