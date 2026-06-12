//
//  AndroidBridge.swift
//  DroidShimCore
//
//  Mirrors Android Activity lifecycle with a UIKit UIViewController.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A minimal Android Bundle surrogate.
public final class BundleBridge {
    public var values: [String: Any] = [:]
    public init() {}
}

/// Android Intent surrogate.
public final class IntentBridge {
    public let targetClassName: String
    public var extras: [String: Any] = [:]

    public init(className: String) {
        self.targetClassName = className
    }
}

/// Mirrors an Android Activity and drives a UIViewController.
#if canImport(UIKit)
public final class ActivityBridge: NSObject {
    public let className: String
    public let interpreter: ARTInterpreter
    public let viewMapper: ViewMapper
    public let resourceResolver: ResourceResolver

    public var viewController = UIViewController()
    private var activityClassDef: DexClassDef?

    public init(className: String,
                interpreter: ARTInterpreter,
                viewMapper: ViewMapper,
                resourceResolver: ResourceResolver) {
        self.className = className
        self.interpreter = interpreter
        self.viewMapper = viewMapper
        self.resourceResolver = resourceResolver
        self.activityClassDef = interpreter.classDef(named: className)
        super.init()
        interpreter.uiBridge = self
    }

    // MARK: - Lifecycle

    public func onCreate(savedInstanceState: BundleBridge?) {
        _ = savedInstanceState
        // Call Java onCreate if it exists.  Pass a null Bundle reference as the argument.
        _ = try? invokeLifecycleMethod("onCreate", args: [.object(nil)])

        // If setContentView was not called by Java code, build from a default layout.
        if viewController.view.subviews.isEmpty, let layoutName = defaultLayoutName() {
            setContentView(layoutName: layoutName)
        }
    }

    public func onResume() {
        _ = try? invokeLifecycleMethod("onResume", args: [])
    }

    public func onPause() {
        _ = try? invokeLifecycleMethod("onPause", args: [])
    }

    public func onDestroy() {
        _ = try? invokeLifecycleMethod("onDestroy", args: [])
    }

    public func setContentView(layoutName: String) {
        guard let xml = resourceResolver.resolveLayout(named: layoutName) else { return }
        let root = LayoutInflater(mapper: viewMapper).inflate(xml: xml)
        viewController.view = root
    }

    public func setContentView(layoutResID: Int) {
        // Phase 1: try to resolve the layout name from R.java and inflate it.
        if let layoutName = resourceResolver.nameForRField(innerClass: "layout", value: Int32(layoutResID)),
           let xml = resourceResolver.resolveLayout(named: layoutName) {
            let root = LayoutInflater(mapper: viewMapper).inflate(xml: xml)
            viewController.view = root
        }
    }

    public func findViewById(id: Int) -> UIView? {
        return viewController.view.viewWithTag(id)
    }

    public func startActivity(_ intent: IntentBridge) {
        // Phase 1: present the new activity full-screen.
        let newActivity = ActivityBridge(
            className: intent.targetClassName,
            interpreter: interpreter,
            viewMapper: viewMapper,
            resourceResolver: resourceResolver
        )
        newActivity.onCreate(savedInstanceState: nil)
        if let topVC = UIApplication.shared.keyWindow?.rootViewController {
            topVC.present(newActivity.viewController, animated: true)
        }
    }

    // MARK: - Private

    private func defaultLayoutName() -> String? {
        // Fallback to "main" or "activity_main" if present.
        for name in ["activity_main", "main"] {
            if resourceResolver.resolveLayout(named: name) != nil { return name }
        }
        return nil
    }

    private func invokeLifecycleMethod(_ name: String, args: [JavaValue]) throws {
        guard let def = activityClassDef else { return }
        for m in def.directMethods + def.virtualMethods where interpreter.dex.methodRef(at: m.methodId)?.name == name {
            _ = try interpreter.execute(method: m, args: args)
            return
        }
    }
}

// MARK: - ART UI bridge

extension ActivityBridge: ARTUIBridge {
    public func findViewById(id: Int32) -> JavaObject {
        let obj = JavaHeap.shared.allocate(className: "android.view.View")
        // Store the resource id so setText/setClick/etc can resolve the UIView.
        obj.fields["__resId"] = id
        return obj
    }

    public func setText(view: JavaObject, text: String) {
        guard let resId = view.fields["__resId"] as? Int32 else { return }
        DispatchQueue.main.async {
            if let label = self.viewController.view.viewWithTag(Int(resId)) as? UILabel {
                label.text = text
            }
        }
    }

    public func setText(view: JavaObject, resId: Int32) {
        let text = resourceResolver.resolveString(id: UInt32(bitPattern: resId)) ?? ""
        setText(view: view, text: text)
    }

    public func setContentView(resId: Int32) {
        if let name = resourceResolver.nameForRField(innerClass: "layout", value: resId),
           let xml = resourceResolver.resolveLayout(named: name) {
            let root = LayoutInflater(mapper: viewMapper).inflate(xml: xml)
            DispatchQueue.main.async {
                self.viewController.view = root
            }
        }
    }
}

#else

public final class ActivityBridge {
    public let className: String
    public init(className: String, interpreter: ARTInterpreter, viewMapper: ViewMapper, resourceResolver: ResourceResolver) {
        self.className = className
    }
    public func onCreate(savedInstanceState: BundleBridge?) {}
    public func onResume() {}
    public func onPause() {}
    public func onDestroy() {}
}

#endif
