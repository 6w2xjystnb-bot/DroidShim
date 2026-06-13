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
    public var arrayValues: [JavaValue] = []
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
    private var references: [UInt32: JavaObject] = [:]
    private var nextReference: UInt32 = 1
    private var allocationCount = 0

    private init() {}

    /// Allocate a new object of the given class.
    public func allocate(className: String) -> JavaObject {
        let obj = JavaObject(className: className)
        objects.append(obj)
        _ = reference(for: obj)
        allocationCount += 1
        if objects.count > threshold {
            collect(roots: Array(references.values))
        }
        return obj
    }

    /// Allocate a new array of a given length.
    public func allocateArray(className: String, length: Int) -> JavaObject {
        let obj = JavaObject(className: className)
        obj.isArray = true
        obj.arrayValues = Array(repeating: JavaValue.int(0), count: max(0, length))
        objects.append(obj)
        _ = reference(for: obj)
        allocationCount += 1
        return obj
    }

    /// Return a stable 32-bit managed reference for an object.
    public func reference(for object: JavaObject?) -> UInt32 {
        guard let object else { return 0 }
        if let existing = references.first(where: { $0.value === object })?.key {
            return existing
        }

        let ref = nextReference
        nextReference &+= 1
        if nextReference == 0 {
            nextReference = 1
        }
        references[ref] = object
        return ref
    }

    /// Resolve a managed Dalvik reference back to a heap object.
    public func object(for reference: UInt32) -> JavaObject? {
        guard reference != 0 else { return nil }
        return references[reference]
    }

    /// Run a synchronous stop-the-world collection.
    public func collect(roots: [JavaObject]) {
        // Clear marks.
        for obj in objects { obj.markBit = false }

        // Mark from roots.
        var worklist = roots + Array(references.values)
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
        references = references.filter { entry in objects.contains { $0 === entry.value } }
    }

    public var liveObjectCount: Int { objects.count }
    public var totalAllocations: Int { allocationCount }
}
