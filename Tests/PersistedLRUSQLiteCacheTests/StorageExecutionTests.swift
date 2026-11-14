import Foundation
import SQLite3
import XCTest
@testable import PersistedLRUSQLiteCache

#if DEBUG
final class StorageExecutionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CacheExecution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDeniedColdOpenDoesNotCreateSQLiteFile() throws {
        let root = try root()
        let cache = CacheStorageExecutionProtection.$_test_acquisitionOverride.withValue({ throw CancellationError() }) {
            LRUSQLiteCache<String, String>(namespace: "denied", cacheRootURL: root)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.cacheDirectory.appendingPathComponent("cache.sqlite").path))
        let retry = LRUSQLiteCache<String, String>(namespace: "denied", cacheRootURL: root)
        retry.setValue("retry", forKey: "key")
        XCTAssertEqual(LRUSQLiteCache<String, String>(namespace: "denied", cacheRootURL: root).value(forKey: "key"), "retry")
    }

    func testDeniedWriteKeepsPreviousDurableValue() throws {
        let root = try root()
        let cache = LRUSQLiteCache<String, String>(namespace: "denied-write", cacheRootURL: root)
        cache.setValue("before", forKey: "key")
        CacheStorageExecutionProtection.$_test_acquisitionOverride.withValue({ throw CancellationError() }) {
            cache.setValue("rejected", forKey: "key")
        }
        XCTAssertEqual(LRUSQLiteCache<String, String>(namespace: "denied-write", cacheRootURL: root).value(forKey: "key"), "before")
    }

    func testExpirationBeforeCommitRollsBackSQLiteMutationAndReleasesGrant() throws {
        let root = try root()
        let cache = LRUSQLiteCache<String, String>(namespace: "expired", cacheRootURL: root)
        cache.setValue("before", forKey: "key")
        let state = ExecutionState()
        CacheStorageExecutionProtection.$_test_acquisitionOverride.withValue({
            CacheStorageExecutionLease(checkpoint: {
                if state.checkpoint() == 3 { throw CancellationError() }
            }, release: { state.released() })
        }) {
            cache.setValue("expired", forKey: "key")
        }
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertEqual(LRUSQLiteCache<String, String>(namespace: "expired", cacheRootURL: root).value(forKey: "key"), "before")
    }

    func testGrantReleasesOnlyAfterSQLiteUnlocks() throws {
        let root = try root()
        let cache = LRUSQLiteCache<String, String>(namespace: "release", cacheRootURL: root)
        let databasePath = cache.cacheDirectory.appendingPathComponent("cache.sqlite").path
        let state = ExecutionState()
        CacheStorageExecutionProtection.$_test_acquisitionOverride.withValue({
            CacheStorageExecutionLease(checkpoint: {}, release: {
                var database: OpaquePointer?
                guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                    if let database { sqlite3_close(database) }
                    return
                }
                defer { sqlite3_close(database) }
                if sqlite3_exec(database, "BEGIN IMMEDIATE; ROLLBACK;", nil, nil, nil) == SQLITE_OK { state.released() }
            })
        }) {
            cache.setValue("committed", forKey: "key")
        }
        XCTAssertEqual(state.releaseCount, 1, "A second SQLite writer can enter when the execution grant is released")
    }
}

private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints = 0
    private var releases = 0
    func checkpoint() -> Int { lock.withLock { checkpoints += 1; return checkpoints } }
    func released() { lock.withLock { releases += 1 } }
    var releaseCount: Int { lock.withLock { releases } }
}
#endif
