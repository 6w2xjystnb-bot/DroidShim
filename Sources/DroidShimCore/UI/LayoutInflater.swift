//
//  LayoutInflater.swift
//  DroidShimCore
//
//  Minimal layout inflater.  Phase 1 supports a small text/XML subset used for
//  debugging; real APK binary layout XML is decoded via BinaryXMLParser in
//  Phase 2.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Inflates a simple Android-like XML layout into a UIKit view tree.
public final class LayoutInflater {
    let mapper: ViewMapper

    public init(mapper: ViewMapper) {
        self.mapper = mapper
    }

    /// Inflate XML text into a UIKit view hierarchy.
    public func inflate(xml: String) -> UIView {
        guard let root = parse(xml: xml) else {
            return UIView()
        }
        return build(node: root)
    }

    // MARK: - Tiny XML parser

    private struct XMLNode {
        let name: String
        let attributes: [String: String]
        var children: [XMLNode]
    }

    private func parse(xml: String) -> XMLNode? {
        var stack: [XMLNode] = []
        var current: XMLNode?

        let scanner = Scanner(string: xml)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("<")
            if scanner.isAtEnd { break }
            _ = scanner.scanString("<")

            if scanner.scanString("!--") != nil {
                _ = scanner.scanUpToString("-->")
                _ = scanner.scanString("-->")
                continue
            }

            if scanner.scanString("/") != nil {
                // Closing tag
                if let name = scanner.scanUpToString(">") {
                    _ = scanner.scanString(">")
                    if let last = stack.last, last.name == name {
                        let completed = stack.removeLast()
                        if stack.isEmpty {
                            return completed
                        } else {
                            stack[stack.count - 1].children.append(completed)
                        }
                    }
                }
                continue
            }

            // Opening/self-closing tag
            guard let tag = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: " />")) else { continue }
            var attrs: [String: String] = [:]
            while true {
                _ = scanner.scanCharacters(from: .whitespacesAndNewlines)
                if scanner.scanString(">") != nil {
                    // Opening tag
                    stack.append(XMLNode(name: tag, attributes: attrs, children: []))
                    break
                }
                if scanner.scanString("/>") != nil {
                    // Self-closing tag
                    let node = XMLNode(name: tag, attributes: attrs, children: [])
                    if stack.isEmpty {
                        return node
                    } else {
                        stack[stack.count - 1].children.append(node)
                    }
                    break
                }
                guard let key = scanner.scanUpToString("=") else { break }
                _ = scanner.scanString("=")
                _ = scanner.scanString("\"")
                guard let value = scanner.scanUpToString("\"") else { break }
                _ = scanner.scanString("\"")
                attrs[key.trimmingCharacters(in: .whitespaces)] = value
            }
        }

        return stack.first
    }

    // MARK: - View building

    private func build(node: XMLNode) -> UIView {
        let view = mapper.createView(androidClass: node.name, attributes: node.attributes)
        for child in node.children {
            let childView = build(node: child)
            mapper.addChild(childView, to: view, attributes: child.attributes)
            applyConstraints(child: childView, parent: view, attributes: child.attributes)
        }
        return view
    }

    private func applyConstraints(child: UIView, parent: UIView, attributes: [String: String]) {
        let width = attributes["android:layout_width"] ?? "wrap_content"
        let height = attributes["android:layout_height"] ?? "wrap_content"

        if width == "match_parent" {
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor).isActive = true
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor).isActive = true
        }
        if height == "match_parent" {
            child.topAnchor.constraint(equalTo: parent.topAnchor).isActive = true
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor).isActive = true
        }
    }
}
#endif
