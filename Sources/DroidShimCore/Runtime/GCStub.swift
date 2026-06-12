//
//  GCStub.swift
//  DroidShimCore
//
//  Simple mark-and-sweep heap for Java objects created by the interpreter.
//  Phase 1 is single-threaded and stop-the-world.
//

import Foundation

/// A boxed Java object managed by the DroidShim heap.
public final class JavaObject {
    public let className: String
    public var fields: [String: Any] = [:]
    public var arrayValues: [Any] = []
    public var isArray = false
    public var markBit = false

    public init(className: String) {
        self.className = className
    }
}

/// Primitive Java types used by the interpreter.
public enum JavaValue {
    case void
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case object(JavaObject?)
    case boolean(Bool)
}

/// Simple mark-and-sweep heap.
public final class JavaHeap {
    public static let shared = JavaHeap()

    public var threshold: Int = 10000
    private var objects: [JavaObject] = []
    private var allocationCount = 0

    private init() {}

    /// Allocate a new object of the given class.
    public func allocate(className: String) -> JavaObject {
        let obj = JavaObject(className: className)
        objects.append(obj)
        allocationCount += 1
        if objects.count > threshold {
            collect(roots: [])
        }
        return obj
    }

    /// Allocate a new array of a given length.
    public func allocateArray(className: String, length: Int) -> JavaObject {
        let obj = JavaObject(className: className)
        obj.isArray = true
        obj.arrayValues = Array(repeating: JavaValue.int(0), count: max(0, length))
        objects.append(obj)
        allocationCount += 1
        return obj
    }

    /// Run a synchronous stop-the-world collection.
    public func collect(roots: [JavaObject]) {
        // Clear marks.
        for obj in objects { obj.markBit = false }

        // Mark from roots.
        var worklist = roots
        while let obj = worklist.popLast() {
            if obj.markBit { continue }
            obj.markBit = true

            // Scan object fields.
            for (_, value) in obj.fields {
                if let ref = value as? JavaObject, !ref.markBit {
                    worklist.append(ref)
                }
            }
            // Scan array elements.
            for value in obj.arrayValues {
                switch value {
                case .object(let ref?):
                    if !ref.markBit { worklist.append(ref) }
                default:
                    break
                }
            }
        }

        // Sweep unmarked objects.
        objects.removeAll { !$0.markBit }
    }

    public var liveObjectCount: Int { objects.count }
    public var totalAllocations: Int { allocationCount }
}
