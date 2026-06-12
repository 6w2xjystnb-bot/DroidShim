//
//  CanvasBridge.swift
//  DroidShimCore
//
//  Maps Android Canvas/Paint to CoreGraphics CGContext.
//

import Foundation
import CoreGraphics
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
    #if canImport(UIKit)
    public var color: UIColor? = .black
    #else
    public var color: CGColor? = CGColor(gray: 0, alpha: 1)
    #endif
    public var strokeWidth: CGFloat = 1.0
    public var style: PaintStyle = .fill
    public var textSize: CGFloat = 14.0
    public var isAntiAlias = true

    public init() {}
}

/// Android Bitmap surrogate.
public final class BitmapBridge {
    #if canImport(UIKit)
    public let image: UIImage?
    public init(image: UIImage?) { self.image = image }
    #else
    public init() {}
    #endif
}

/// Android Canvas surrogate.
public final class CanvasBridge {
    #if canImport(UIKit)
    public var context: CGContext?

    public init(context: CGContext?) {
        self.context = context
    }

    public func drawRect(_ rect: CGRect, paint: PaintBridge) {
        guard let ctx = context else { return }
        ctx.setFillColor(paint.color?.cgColor ?? UIColor.black.cgColor)
        ctx.fill(rect)
    }

    public func drawText(_ text: String, x: CGFloat, y: CGFloat, paint: PaintBridge) {
        guard let ctx = context, let color = paint.color else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: paint.textSize),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        // Restore context state after text drawing.
        ctx.beginPath()
    }

    public func drawBitmap(_ bitmap: BitmapBridge, left: CGFloat, top: CGFloat, paint: PaintBridge?) {
        guard let image = bitmap.image else { return }
        image.draw(at: CGPoint(x: left, y: top))
        _ = paint
    }
    #else
    public init() {}
    #endif
}
