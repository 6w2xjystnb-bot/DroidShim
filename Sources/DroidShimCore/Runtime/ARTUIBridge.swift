//
//  ARTUIBridge.swift
//  DroidShimCore
//
//  Bridge between the Dalvik interpreter and the UIKit view tree.
//  Enables Java code to call findViewById/setText on mapped Views.
//

import Foundation

/// Protocol implemented by the UI layer to service Android View calls
/// made from interpreted bytecode.
public protocol ARTUIBridge: AnyObject {
    /// Find a view by its Android resource id and return a Java object wrapper.
    func findViewById(id: Int32) -> JavaObject

    /// Update the text of a mapped TextView/Label.
    func setText(view: JavaObject, text: String)

    /// Update the text of a mapped TextView/Label from a resource id.
    func setText(view: JavaObject, resId: Int32)

    /// Inflate and set the Activity content view from a layout resource id.
    func setContentView(resId: Int32)
}
