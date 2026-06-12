//
//  ContainerApp.swift
//  DroidShimApp
//
//  SwiftUI app entry point.
//

import SwiftUI
import UIKit
import DroidShimCore

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
