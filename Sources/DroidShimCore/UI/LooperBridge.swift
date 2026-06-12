//
//  LooperBridge.swift
//  DroidShimCore
//
//  Maps Android Looper/Handler to DispatchQueue.main and Timers.
//

import Foundation

/// Android Looper shim.  On iOS the main thread RunLoop is already running,
/// so prepare/loop are mostly no-ops.
public final class LooperBridge {
    public static let main = LooperBridge(queue: .main)

    public let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public static func prepare() -> LooperBridge {
        return main
    }

    public static func loop() {
        // No-op: RunLoop.main is already spinning.
    }
}

/// Android Handler shim.
public final class HandlerBridge {
    public let looper: LooperBridge

    public init(looper: LooperBridge = .main) {
        self.looper = looper
    }

    public func post(_ block: @escaping () -> Void) {
        looper.queue.async(execute: block)
    }

    public func postDelayed(_ delayMillis: Int, _ block: @escaping () -> Void) {
        let deadline = DispatchTime.now() + .milliseconds(delayMillis)
        looper.queue.asyncAfter(deadline: deadline, execute: block)
    }

    public func removeCallbacks(_ block: @escaping () -> Void) {
        // Phase 1: cancellation is not tracked.
        _ = block
    }
}

/// Placeholder Message type.
public final class MessageBridge {
    public var what: Int = 0
    public var obj: Any?
    public var runnable: (() -> Void)?
}
