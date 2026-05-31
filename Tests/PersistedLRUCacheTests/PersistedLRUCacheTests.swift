import XCTest
@testable import PersistedLRUCacheHybrid

final class PersistedLRUCacheTests: XCTestCase {
    func testSmallValuesPersistInlineAndLargeValuesPersistAsFiles() throws {
        let root = try temporaryRoot()
        let namespace = "mixed-\(UUID().uuidString)"
        let cache = PersistedLRUCache<String, String>(
            namespace: namespace,
            inlineStorageThreshold: 16,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        let largeValue = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 8)
        cache.setValue("small", forKey: "small")
        cache.setValue(largeValue, forKey: "large")

        XCTAssertEqual(cache.value(forKey: "small"), "small")
        XCTAssertEqual(cache.value(forKey: "large"), largeValue)
        XCTAssertNil(cache.debugDiskEntryURL(for: "small"))

        let largeURL = try XCTUnwrap(cache.debugDiskEntryURL(for: "large"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: largeURL.path))

        let reloaded = PersistedLRUCache<String, String>(
            namespace: namespace,
            inlineStorageThreshold: 16,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertEqual(reloaded.value(forKey: "small"), "small")
        XCTAssertEqual(reloaded.value(forKey: "large"), largeValue)
    }

    func testCountLimitEvictsExternalFiles() throws {
        let root = try temporaryRoot()
        let cache = PersistedLRUCache<String, String>(
            namespace: "count-limit-\(UUID().uuidString)",
            countLimit: 1,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValue(String(repeating: "a", count: 32), forKey: "a")
        let evictedURL = try XCTUnwrap(cache.debugDiskEntryURL(for: "a"))
        cache.setValue(String(repeating: "b", count: 32), forKey: "b")

        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: evictedURL.path))
        XCTAssertEqual(cache.value(forKey: "b"), String(repeating: "b", count: 32))
    }

    func testReplacingExternalValueWithInlineValueDeletesExternalFile() throws {
        let root = try temporaryRoot()
        let cache = PersistedLRUCache<String, String>(
            namespace: "replace-\(UUID().uuidString)",
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValue(String(repeating: "a", count: 32), forKey: "key")
        let oldURL = try XCTUnwrap(cache.debugDiskEntryURL(for: "key"))
        cache.setValue("small", forKey: "key")

        XCTAssertEqual(cache.value(forKey: "key"), "small")
        XCTAssertNil(cache.debugDiskEntryURL(for: "key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
    }

    func testBatchSetPersistsMixedValues() throws {
        let root = try temporaryRoot()
        let namespace = "batch-\(UUID().uuidString)"
        let cache = PersistedLRUCache<Int, String>(
            namespace: namespace,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValues([
            (1, "one"),
            (2, String(repeating: "two", count: 16)),
            (3, "three"),
        ])

        let reloaded = PersistedLRUCache<Int, String>(
            namespace: namespace,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertEqual(reloaded.value(forKey: 1), "one")
        XCTAssertEqual(reloaded.value(forKey: 2), String(repeating: "two", count: 16))
        XCTAssertEqual(reloaded.value(forKey: 3), "three")
        XCTAssertNotNil(reloaded.debugDiskEntryURL(for: 2))
    }

    func testRemoveAllDeletesExternalFiles() throws {
        let root = try temporaryRoot()
        let cache = PersistedLRUCache<String, String>(
            namespace: "remove-all-\(UUID().uuidString)",
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValue(String(repeating: "a", count: 32), forKey: "a")
        let externalURL = try XCTUnwrap(cache.debugDiskEntryURL(for: "a"))
        cache.removeAll()

        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalURL.path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedLRUCacheTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
