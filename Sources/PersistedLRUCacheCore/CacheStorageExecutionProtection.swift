import Foundation

/// A host-provided execution grant retained until SQLite has settled its read or
/// write transaction. The host decides whether storage may start while inactive.
public struct CacheStorageExecutionLease: Sendable {
    private let check: @Sendable () throws -> Void
    private let end: @Sendable () -> Void

    public init(checkpoint: @escaping @Sendable () throws -> Void,
                release: @escaping @Sendable () -> Void) {
        check = checkpoint
        end = release
    }

    public func checkpoint() throws { try check() }
    public func release() { end() }
}

public enum CacheStorageExecutionProtection {
    public typealias Acquisition = @Sendable () throws -> CacheStorageExecutionLease?

    private final class Provider: @unchecked Sendable {
        let lock = NSLock()
        var acquisition: Acquisition?
        func get() -> Acquisition? { lock.withLock { acquisition } }
        func install(_ value: @escaping Acquisition) { lock.withLock { acquisition = value } }
    }

    private static let provider = Provider()

    /// Install before starting application cache work. Without a host policy,
    /// standalone/desktop clients retain their existing storage behavior.
    public static func installDefaultAcquisition(_ acquisition: @escaping Acquisition) {
        provider.install(acquisition)
    }

#if DEBUG
    @TaskLocal public static var _test_acquisitionOverride: Acquisition?
#endif

    package static func withExecution<T>(
        _ operation: (_ checkpoint: @Sendable () throws -> Void) throws -> T
    ) throws -> T {
        let acquisition: Acquisition?
#if DEBUG
        acquisition = _test_acquisitionOverride ?? provider.get()
#else
        acquisition = provider.get()
#endif
        let lease = try acquisition?()
        defer { lease?.release() }
        let checkpoint: @Sendable () throws -> Void = { try lease?.checkpoint() }
        try checkpoint()
        return try operation(checkpoint)
    }
}
