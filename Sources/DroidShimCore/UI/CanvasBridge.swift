//
//  CanvasBridge.swift
//  DroidShimCore
//
//  Maps Android Canvas/Paint to CoreGraphics CGContext.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Android Paint style equivalent.
public enum PaintStyle {
    case fill
    case stroke
}

/// Android Paint surrogate.
public final class PaintBridge {
    public var argb: UInt32 = 0xff000000
    public var strokeWidth: Double = 1.0
    public var style: PaintStyle = .fill
    public var textSize: Double = 14.0
    public var isAntiAlias = true

    public init() {}

    #if canImport(UIKit)
    var color: UIColor {
        let alpha = CGFloat((argb >> 24) & 0xff) / 255.0
        let red = CGFloat((argb >> 16) & 0xff) / 255.0
        let green = CGFloat((argb >> 8) & 0xff) / 255.0
        let blue = CGFloat(argb & 0xff) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #endif
}

/// Android Bitmap surrogate.
public final class BitmapBridge {
    #if canImport(UIKit)
    let image: UIImage?
    init(image: UIImage?) { self.image = image }
    #endif

    public init() {
        #if canImport(UIKit)
        self.image = nil
        #endif
    }
}

/// Android Canvas surrogate.
public final class CanvasBridge {
    #if canImport(UIKit)
    var context: CGContext?

    init(context: CGContext?) {
        self.context = context
    }

    public init() {
        self.context = nil
    }

    public func drawRect(x: Double, y: Double, width: Double, height: Double, paint: PaintBridge) {
        guard let ctx = context else { return }
        let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
        ctx.setFillColor(paint.color.cgColor)
        ctx.fill(rect)
    }

    public func drawText(_ text: String, x: Double, y: Double, paint: PaintBridge) {
        guard let ctx = context else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: CGFloat(paint.textSize)),
            .foregroundColor: paint.color
        ]
        (text as NSString).draw(at: CGPoint(x: CGFloat(x), y: CGFloat(y)), withAttributes: attrs)
        // Restore context state after text drawing.
        ctx.beginPath()
    }

    public func drawBitmap(_ bitmap: BitmapBridge, left: Double, top: Double, paint: PaintBridge?) {
        guard let image = bitmap.image else { return }
        image.draw(at: CGPoint(x: CGFloat(left), y: CGFloat(top)))
        _ = paint
    }
    #else
    public init() {}
    #endif
}
