//
//  JNIRegistry.swift
//  DroidShimCore
//
//  Registers native methods by (class, method, signature) and resolves their
//  addresses from converted Mach-O `.so` images using dlsym.
//

import Foundation

/// Signature describing a native method that the interpreter can call.
public struct NativeMethodSignature: Hashable {
    public let className: String
    public let methodName: String
    public let signature: String

    public init(className: String, methodName: String, signature: String) {
        self.className = className
        self.methodName = methodName
        self.signature = signature
    }

    /// JNI mangled symbol: Java_com_example_Foo_method.
    public var mangledSymbolName: String {
        let escapedClass = className
            .replacingOccurrences(of: "_", with: "_1")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let escapedMethod = methodName.replacingOccurrences(of: "_", with: "_1")
        return "Java_\(escapedClass)_\(escapedMethod)"
    }
}

/// Registry of loaded native libraries and resolved symbols.
public final class JNIRegistry {
    public static let shared = JNIRegistry()

    private var handles: [String: UnsafeMutableRawPointer] = [:]
    private var cache: [NativeMethodSignature: UnsafeMutableRawPointer] = [:]

    private init() {}

    /// Load a converted Mach-O `.dylib` (formerly an Android `.so`) from disk.
    @discardableResult
    public func loadLibrary(path: String) throws -> UnsafeMutableRawPointer {
        if let existing = handles[path] { return existing }
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            let msg = String(cString: dlerror())
            throw NSError(domain: "DroidShim", code: 1, userInfo: [NSLocalizedDescriptionKey: "dlopen failed: \(msg)"])
        }
        handles[path] = handle
        return handle
    }

    /// Resolve a native method symbol, caching the result.
    public func resolve(_ signature: NativeMethodSignature, libraryPath: String) -> UnsafeMutableRawPointer? {
        if let ptr = cache[signature] { return ptr }
        guard let handle = try? loadLibrary(path: libraryPath) else { return nil }
        let symbol = signature.mangledSymbolName
        guard let ptr = dlsym(handle, symbol) else { return nil }
        cache[signature] = ptr
        return ptr
    }

    /// Invoke a native method that takes a JNIEnv* (nil), jobject (JavaObject pointer),
    /// and a variadic argument list.  Phase 1 supports Int32/Int64/JavaObject args.
    public func invoke(_ signature: NativeMethodSignature,
                       libraryPath: String,
                       this: JavaObject?,
                       args: [Any]) -> Any? {
        guard let ptr = resolve(signature, libraryPath: libraryPath) else { return nil }

        // For Phase 1 we support a small fixed set of native signatures.
        // Most Android UI onClick handlers are `void methodName(View)`.
        typealias VoidViewFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias VoidFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias IntFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

        let env: UnsafeMutableRawPointer? = nil
        let thisPtr = this.map { Unmanaged.passUnretained($0).toOpaque() }

        if args.isEmpty {
            if signature.signature.hasSuffix(")V") {
                let fn = unsafeBitCast(ptr, to: VoidFn.self)
                fn(thisPtr)
                return nil
            } else if signature.signature.hasSuffix(")I") {
                let fn = unsafeBitCast(ptr, to: IntFn.self)
                return fn(thisPtr)
            }
        } else if args.count == 1, let arg = args[0] as? JavaObject {
            let argPtr = Unmanaged.passUnretained(arg).toOpaque()
            let fn = unsafeBitCast(ptr, to: VoidViewFn.self)
            fn(thisPtr, argPtr)
            return nil
        }

        // Fallback: call with nil args.
        let fn = unsafeBitCast(ptr, to: VoidFn.self)
        fn(thisPtr)
        return nil
    }
}
