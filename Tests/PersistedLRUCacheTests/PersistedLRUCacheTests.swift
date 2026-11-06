import XCTest
@testable import PersistedLRUCacheHybrid

final class PersistedLRUCacheTests: XCTestCase {
    struct Record: Codable, Equatable {
        var title: String
        var values: [Int]
    }

    func testUndecodableInlineValueIsEvictedOnRead() throws {
        let root = try temporaryRoot()
        let namespace = "decode-inline-\(UUID().uuidString)"

        let writer = PersistedLRUCache<String, Record>(
            namespace: namespace,
            inlineStorageThreshold: .max,
            cacheRootURL: root
        )
        writer.setValue(Record(title: "old schema", values: [1, 2, 3]), forKey: "page")

        let reader = PersistedLRUCache<String, String>(
            namespace: namespace,
            inlineStorageThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertTrue(reader.containsKey("page"))
        XCTAssertNil(reader.value(forKey: "page"))
        XCTAssertFalse(reader.containsKey("page"))
    }

    func testUndecodableExternalValueAndFileAreEvictedOnRead() throws {
        let root = try temporaryRoot()
        let namespace = "decode-external-\(UUID().uuidString)"

        let writer = PersistedLRUCache<String, Record>(
            namespace: namespace,
            inlineStorageThreshold: 1,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        writer.setValue(Record(title: "old schema", values: [1, 2, 3]), forKey: "page")
        let externalURL = try XCTUnwrap(writer.debugDiskEntryURL(for: "page"))

        let reader = PersistedLRUCache<String, String>(
            namespace: namespace,
            inlineStorageThreshold: 1,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertTrue(reader.containsKey("page"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
        XCTAssertNil(reader.value(forKey: "page"))
        XCTAssertFalse(reader.containsKey("page"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalURL.path))
    }

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

    func testLargeCountLimitTrimsOnlyAfterSlackThreshold() throws {
        let root = try temporaryRoot()
        let namespace = "threshold-count-limit-\(UUID().uuidString)"
        let cache = PersistedLRUCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 100,
            memoryCountLimit: 8,
            cacheRootURL: root
        )

        for index in 0..<164 {
            cache.setValue("value-\(index)", forKey: "key-\(index)")
        }

        let beforeThresholdReload = PersistedLRUCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 100,
            memoryCountLimit: 8,
            cacheRootURL: root
        )
        XCTAssertEqual(beforeThresholdReload.value(forKey: "key-0"), "value-0")
        XCTAssertEqual(beforeThresholdReload.value(forKey: "key-163"), "value-163")

        cache.setValue("value-164", forKey: "key-164")

        let afterThresholdReload = PersistedLRUCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 100,
            memoryCountLimit: 8,
            cacheRootURL: root
        )
        XCTAssertNil(afterThresholdReload.value(forKey: "key-0"))
        XCTAssertNil(afterThresholdReload.value(forKey: "key-64"))
        XCTAssertEqual(afterThresholdReload.value(forKey: "key-65"), "value-65")
        XCTAssertEqual(afterThresholdReload.value(forKey: "key-164"), "value-164")
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

    func testAsynchronousWritesUpdateMemoryImmediatelyAndPersistOnFlush() throws {
        let root = try temporaryRoot()
        let namespace = "async-\(UUID().uuidString)"
        let cache = PersistedLRUCache<String, String>(
            namespace: namespace,
            compressionThreshold: .max,
            writeMode: .asynchronous(batchDelay: 60),
            cacheRootURL: root
        )

        cache.setValue("value", forKey: "key")

        XCTAssertEqual(cache.value(forKey: "key"), "value")
        XCTAssertNil(
            PersistedLRUCache<String, String>(
                namespace: namespace,
                compressionThreshold: .max,
                cacheRootURL: root
            )
            .value(forKey: "key")
        )

        cache.flushPendingWrites()

        XCTAssertEqual(
            PersistedLRUCache<String, String>(
                namespace: namespace,
                compressionThreshold: .max,
                cacheRootURL: root
            )
            .value(forKey: "key"),
            "value"
        )
    }

    func testAsynchronousWritesCoalesceDuplicateKeysBeforePersisting() throws {
        let root = try temporaryRoot()
        let namespace = "async-coalesce-\(UUID().uuidString)"
        let cache = PersistedLRUCache<String, String>(
            namespace: namespace,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            writeMode: .asynchronous(batchDelay: 60),
            cacheRootURL: root
        )

        cache.setValue(String(repeating: "a", count: 32), forKey: "key")
        cache.setValue("small", forKey: "key")
        cache.flushPendingWrites()

        let reloaded = PersistedLRUCache<String, String>(
            namespace: namespace,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertEqual(reloaded.value(forKey: "key"), "small")
        XCTAssertNil(reloaded.debugDiskEntryURL(for: "key"))
        XCTAssertEqual(try externalFileNames(root: root, namespace: namespace), [])
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

    func testQueuedExternalReplacementPreservesCommittedBytesUntilFlush() throws {
        let root = try temporaryRoot()
        let namespace = "async-committed-replacement-\(UUID().uuidString)"
        let first = String(repeating: "a", count: 32)
        let second = String(repeating: "b", count: 32)
        let committed = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        committed.setValue(first, forKey: "key")
        let originalURL = try XCTUnwrap(committed.debugDiskEntryURL(for: "key"))
        let writer = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            writeMode: .asynchronous(batchDelay: 60),
            cacheRootURL: root
        )

        writer.setValue(second, forKey: "key")
        let beforeFlush = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertEqual(beforeFlush.value(forKey: "key"), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))

        writer.flushPendingWrites()
        let afterFlush = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertEqual(afterFlush.value(forKey: "key"), second)
        let replacementURL = try XCTUnwrap(afterFlush.debugDiskEntryURL(for: "key"))
        XCTAssertNotEqual(replacementURL, originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try externalFileNames(root: root, namespace: namespace), [replacementURL.lastPathComponent])
    }

    func testQueuedExternalReplacementsRetainTheFinalPayloadFile() throws {
        let root = try temporaryRoot()
        let namespace = "async-external-replacements-\(UUID().uuidString)"
        let finalValue = String(repeating: "b", count: 32)
        let writer = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            writeMode: .asynchronous(batchDelay: 60),
            cacheRootURL: root
        )

        writer.setValue(String(repeating: "a", count: 32), forKey: "key")
        writer.setValue(finalValue, forKey: "key")
        writer.flushPendingWrites()

        let reloaded = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        let finalURL = try XCTUnwrap(reloaded.debugDiskEntryURL(for: "key"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(reloaded.value(forKey: "key"), finalValue)
        XCTAssertEqual(try externalFileNames(root: root, namespace: namespace), [finalURL.lastPathComponent])
    }

    func testDuplicateBatchEndingInlineRemovesIntermediateExternalFiles() throws {
        let root = try temporaryRoot()
        let namespace = "batch-duplicate-inline-\(UUID().uuidString)"
        let cache = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValues([
            ("key", String(repeating: "a", count: 32)),
            ("key", "small"),
        ])

        let reloaded = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        XCTAssertEqual(reloaded.value(forKey: "key"), "small")
        XCTAssertNil(reloaded.debugDiskEntryURL(for: "key"))
        XCTAssertEqual(try externalFileNames(root: root, namespace: namespace), [])
    }

    func testDuplicateBatchEndingExternalRetainsOnlyTheFinalPayloadFile() throws {
        let root = try temporaryRoot()
        let namespace = "batch-duplicate-external-\(UUID().uuidString)"
        let finalValue = String(repeating: "b", count: 32)
        let cache = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValues([
            ("key", String(repeating: "a", count: 32)),
            ("key", finalValue),
        ])

        let reloaded = PersistedLRUCache<String, String>(
            namespace: namespace,
            memoryThreshold: 0,
            inlineStorageThreshold: 8,
            compressionThreshold: .max,
            cacheRootURL: root
        )
        let finalURL = try XCTUnwrap(reloaded.debugDiskEntryURL(for: "key"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(reloaded.value(forKey: "key"), finalValue)
        XCTAssertEqual(try externalFileNames(root: root, namespace: namespace), [finalURL.lastPathComponent])
    }

    func testUnavailableStoreCleansNewExternalFilesAndPreservesMemoryFallback() throws {
        let root = try temporaryRoot()
        for writeMode in [PersistedLRUCacheWriteMode.immediate, .asynchronous(batchDelay: 60)] {
            let namespace = "unavailable-store-\(UUID().uuidString)"
            let databaseURL = root.appendingPathComponent("PersistedLRUCache")
                .appendingPathComponent(namespace).appendingPathComponent("cache.sqlite")
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
            let cache = PersistedLRUCache<String, String>(
                namespace: namespace,
                memoryThreshold: 1_024,
                inlineStorageThreshold: 8,
                compressionThreshold: .max,
                writeMode: writeMode,
                cacheRootURL: root
            )
            let finalValue = String(repeating: "b", count: 32)

            cache.setValue(String(repeating: "a", count: 32), forKey: "key")
            cache.setValue(finalValue, forKey: "key")
            cache.flushPendingWrites()

            XCTAssertEqual(cache.value(forKey: "key"), finalValue)
            XCTAssertNil(cache.debugDiskEntryURL(for: "key"))
            XCTAssertEqual(try externalFileNames(root: root, namespace: namespace), [])
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedLRUCacheTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func externalFileNames(root: URL, namespace: String) throws -> [String] {
        let filesURL = root
            .appendingPathComponent("PersistedLRUCache")
            .appendingPathComponent(namespace)
            .appendingPathComponent("files", isDirectory: true)
        guard FileManager.default.fileExists(atPath: filesURL.path) else {
            return []
        }
        return try FileManager.default
            .contentsOfDirectory(atPath: filesURL.path)
            .sorted()
    }
}
