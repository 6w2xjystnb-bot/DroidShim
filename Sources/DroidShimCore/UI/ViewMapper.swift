//
//  ViewMapper.swift
//  DroidShimCore
//
//  Factory that maps Android View class names to UIKit views at runtime.
//

import Foundation
#if canImport(UIKit)
import UIKit
import Metal
import QuartzCore
#endif

/// Maps Android layout XML attributes to UIKit view configuration.
public final class ViewMapper {
    public let resolver: ResourceResolver
    public let jniRegistry: JNIRegistry
    public let libraryPath: String
    public let activityClassName: String
    public var javaTapHandler: ((String) -> Void)?

    public init(resolver: ResourceResolver,
                jniRegistry: JNIRegistry,
                libraryPath: String,
                activityClassName: String = "MainActivity",
                javaTapHandler: ((String) -> Void)? = nil) {
        self.resolver = resolver
        self.jniRegistry = jniRegistry
        self.libraryPath = libraryPath
        self.activityClassName = activityClassName
        self.javaTapHandler = javaTapHandler
    }

    #if canImport(UIKit)
    /// Create a UIKit view from an Android class name and attribute dictionary.
    public func createView(androidClass: String, attributes: [String: String]) -> UIView {
        let view: UIView

        switch androidClass {
        case "android.widget.LinearLayout":
            let stack = UIStackView()
            stack.axis = (attributes["android:orientation"] == "horizontal") ? .horizontal : .vertical
            stack.distribution = .fill
            stack.alignment = .fill
            stack.spacing = dimenValue(attributes["android:dividerPadding"] ?? "0")
            view = stack

        case "android.widget.FrameLayout":
            view = UIView()

        case "android.widget.ScrollView":
            view = UIScrollView()

        case "android.widget.TextView":
            let label = UILabel()
            label.text = attributes["android:text"] ?? ""
            if let size = attributes["android:textSize"] {
                label.font = UIFont.systemFont(ofSize: spValue(size))
            }
            if let colorRef = attributes["android:textColor"], let id = parseId(colorRef),
               let color = resolver.resolveColor(id: id) {
                label.textColor = color
            } else {
                label.textColor = .label
            }
            label.textAlignment = gravityToAlignment(attributes["android:gravity"])
            view = label

        case "android.widget.EditText":
            let tf = UITextField()
            tf.placeholder = attributes["android:hint"] ?? ""
            if let type = attributes["android:inputType"] {
                tf.keyboardType = inputTypeToKeyboard(type)
            }
            view = tf

        case "android.widget.Button":
            let button = UIButton(type: .system)
            button.setTitle(attributes["android:text"] ?? "", for: .normal)
            if let click = attributes["android:onClick"] {
                button.addTarget(self, action: #selector(handleButtonTap(_:)), for: .touchUpInside)
                objc_setAssociatedObject(button, &AssociatedKeys.onClick, click, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            view = button

        case "android.widget.ImageView":
            let imageView = UIImageView()
            if let srcRef = attributes["android:src"], let id = parseId(srcRef),
               let image = resolver.resolveDrawable(id: id) {
                imageView.image = image
            }
            imageView.contentMode = scaleTypeToContentMode(attributes["android:scaleType"])
            view = imageView

        case "android.widget.RecyclerView":
            let layout = UICollectionViewFlowLayout()
            let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
            cv.backgroundColor = .systemBackground
            view = cv

        case "android.view.SurfaceView":
            let surface = UIView()
            surface.layer.contentsScale = UIScreen.main.scale
            if let metalLayer = surface.layer as? CAMetalLayer {
                metalLayer.pixelFormat = .bgra8Unorm
            }
            view = surface

        default:
            // Unknown view falls back to a plain UIView.
            view = UIView()
            view.backgroundColor = .systemGray6
        }

        // Apply common attributes.
        applyLayoutAttributes(view: view, attributes: attributes)
        if let idRef = attributes["android:id"], let id = parseId(idRef) {
            view.tag = Int(id)
        }
        if let bgRef = attributes["android:background"] {
            if let colorId = parseId(bgRef), let color = resolver.resolveColor(id: colorId) {
                view.backgroundColor = color
            }
        }

        return view
    }

    public func addChild(_ child: UIView, to parent: UIView, attributes: [String: String]) {
        if let stack = parent as? UIStackView {
            stack.addArrangedSubview(child)
        } else {
            parent.addSubview(child)
        }
        _ = attributes
    }

    // MARK: - Actions

    @objc private func handleButtonTap(_ sender: UIButton) {
        guard let click = objc_getAssociatedObject(sender, &AssociatedKeys.onClick) as? String else { return }
        // Resolve handler via JNI-style reflection.
        if let handler = javaTapHandler {
            handler(click)
        } else {
            let sig = NativeMethodSignature(className: activityClassName, methodName: click, signature: "(Landroid/view/View;)V")
            _ = jniRegistry.invoke(sig, libraryPath: libraryPath, this: nil, args: [])
        }
    }

    // MARK: - Attribute helpers

    private func applyLayoutAttributes(view: UIView, attributes: [String: String]) {
        view.translatesAutoresizingMaskIntoConstraints = false

        let width = attributes["android:layout_width"] ?? "wrap_content"
        let height = attributes["android:layout_height"] ?? "wrap_content"

        if width == "match_parent" {
            // Defer to superview constraints.
        } else if let w = dimenValueOptional(width) {
            view.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
        if height == "match_parent" {
            // Defer to superview constraints.
        } else if let h = dimenValueOptional(height) {
            view.heightAnchor.constraint(equalToConstant: h).isActive = true
        }

        // Padding.
        if let padding = dimenValueOptional(attributes["android:padding"] ?? "") {
            // UIEdgeInsets requires a layout pass; store for later.
            view.layoutMargins = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        }
    }

    private func parseId(_ ref: String) -> UInt32? {
        // Accepts "@+id/foo" or "@id/foo" and resolves via R$id.
        let trimmed = ref.replacingOccurrences(of: "@+id/", with: "")
            .replacingOccurrences(of: "@id/", with: "")
            .replacingOccurrences(of: "@android:id/", with: "")
        if let intVal = UInt32(trimmed) { return intVal }
        guard let idVal = resolver.idForRField(innerClass: "id", field: trimmed) else { return nil }
        return UInt32(bitPattern: idVal)
    }

    private func dimenValue(_ value: String) -> CGFloat {
        return dimenValueOptional(value) ?? 0
    }

    private func dimenValueOptional(_ value: String) -> CGFloat? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("dp") || trimmed.hasSuffix("sp") || trimmed.hasSuffix("px") {
            if let v = Double(trimmed.dropLast(2)) { return CGFloat(v) }
        }
        return Double(trimmed).map { CGFloat($0) }
    }

    private func spValue(_ value: String) -> CGFloat {
        return dimenValue(value)
    }

    private func gravityToAlignment(_ gravity: String?) -> NSTextAlignment {
        guard let g = gravity else { return .natural }
        if g.contains("center") { return .center }
        if g.contains("right") { return .right }
        if g.contains("left") { return .left }
        return .natural
    }

    private func inputTypeToKeyboard(_ type: String) -> UIKeyboardType {
        if type.contains("number") { return .numberPad }
        if type.contains("textEmailAddress") { return .emailAddress }
        if type.contains("textUri") { return .URL }
        if type.contains("phone") { return .phonePad }
        return .default
    }

    private func scaleTypeToContentMode(_ scaleType: String?) -> UIView.ContentMode {
        switch scaleType {
        case "fitXY": return .scaleToFill
        case "fitCenter", "centerInside": return .scaleAspectFit
        case "centerCrop": return .scaleAspectFill
        case "center": return .center
        default: return .scaleAspectFit
        }
    }
    #else
    // macOS stubs (UIKit unavailable).
    public func createView(androidClass: String, attributes: [String: String]) -> Any { return () }
    #endif
}

private struct AssociatedKeys {
    static var onClick: UInt8 = 0
}
