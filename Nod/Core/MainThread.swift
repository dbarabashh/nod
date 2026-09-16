import Foundation

extension MainActor {
    /// `assumeIsolated` for callbacks AppKit delivers synchronously on the
    /// main thread. It checks the thread rather than the runtime's executor
    /// record: on macOS 26.5–26.6 that check can dereference a garbage
    /// executor identity while on the main thread and take the process down.
    static func assumeMainThread<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread, "assumeMainThread called off the main thread")
        return try withoutActuallyEscaping(operation) { escapable in
            try unsafeBitCast(escapable, to: (() throws -> T).self)()
        }
    }
}
