import Foundation
import XCTest
@testable import PersistedLRUSQLiteCache

final class LRUSQLiteCacheTests: XCTestCase {
    struct Record: Codable, Equatable {
        var title: String
        var values: [Int]
    }

    func testStringDataAndCodableValuesPersistAcrossInstances() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()

        let stringCache = LRUSQLiteCache<String, String>(namespace: namespace + ".string", cacheRootURL: root)
        stringCache.setValue("hello", forKey: "greeting")
        XCTAssertEqual(stringCache.value(forKey: "greeting"), "hello")

        let dataCache = LRUSQLiteCache<String, Data>(
            namespace: namespace + ".data",
            compressionThreshold: 32,
            cacheRootURL: root
        )
        let data = Data(repeating: 0x42, count: 512)
        dataCache.setValue(data, forKey: "data")
        XCTAssertEqual(dataCache.value(forKey: "data"), data)

        let recordCache = LRUSQLiteCache<String, Record>(
            namespace: namespace + ".record",
            compressionThreshold: 32,
            cacheRootURL: root
        )
        let record = Record(title: String(repeating: "x", count: 256), values: Array(0..<32))
        recordCache.setValue(record, forKey: "record")
        XCTAssertEqual(recordCache.value(forKey: "record"), record)

        XCTAssertEqual(
            LRUSQLiteCache<String, String>(namespace: namespace + ".string", cacheRootURL: root)
                .value(forKey: "greeting"),
            "hello"
        )
        XCTAssertEqual(
            LRUSQLiteCache<String, Data>(namespace: namespace + ".data", compressionThreshold: 32, cacheRootURL: root)
                .value(forKey: "data"),
            data
        )
        XCTAssertEqual(
            LRUSQLiteCache<String, Record>(
                namespace: namespace + ".record",
                compressionThreshold: 32,
                cacheRootURL: root
            )
            .value(forKey: "record"),
            record
        )
    }

    func testMemoryEvictionDoesNotDeletePersistedRow() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            countLimit: .max,
            memoryCountLimit: 1,
            cacheRootURL: root
        )

        cache.setValue("A", forKey: "a")
        cache.setValue("B", forKey: "b")

        XCTAssertEqual(cache.value(forKey: "a"), "A")
        XCTAssertEqual(cache.value(forKey: "b"), "B")

        let reloaded = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertEqual(reloaded.value(forKey: "a"), "A")
        XCTAssertEqual(reloaded.value(forKey: "b"), "B")
    }

    func testSetValuesPersistsBatchAcrossInstances() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)

        cache.setValues([
            (key: "a", value: "A"),
            (key: "b", value: "B"),
            (key: "nil", value: nil),
        ])

        XCTAssertEqual(cache.value(forKey: "a"), "A")
        XCTAssertEqual(cache.value(forKey: "b"), "B")
        XCTAssertNil(cache.value(forKey: "nil"))
        XCTAssertTrue(cache.containsKey("nil"))

        let reloaded = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertEqual(reloaded.value(forKey: "a"), "A")
        XCTAssertEqual(reloaded.value(forKey: "b"), "B")
        XCTAssertNil(reloaded.value(forKey: "nil"))
        XCTAssertTrue(reloaded.containsKey("nil"))
    }

    func testSetValuesHonorsPersistentCountLimit() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 2,
            cacheRootURL: root
        )

        cache.setValues([
            (key: "k1", value: "1"),
            (key: "k2", value: "2"),
            (key: "k3", value: "3"),
        ])

        XCTAssertNil(cache.value(forKey: "k1"))
        XCTAssertFalse(cache.containsKey("k1"))
        XCTAssertEqual(cache.value(forKey: "k2"), "2")
        XCTAssertEqual(cache.value(forKey: "k3"), "3")
    }

    func testPersistentCountLimitEvictsOldestRow() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 2,
            cacheRootURL: root
        )

        cache.setValue("1", forKey: "k1")
        cache.setValue("2", forKey: "k2")
        cache.setValue("3", forKey: "k3")

        XCTAssertNil(cache.value(forKey: "k1"))
        XCTAssertFalse(cache.containsKey("k1"))
        XCTAssertEqual(cache.value(forKey: "k2"), "2")
        XCTAssertEqual(cache.value(forKey: "k3"), "3")

        let reloaded = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(reloaded.value(forKey: "k1"))
        XCTAssertFalse(reloaded.containsKey("k1"))
        XCTAssertEqual(reloaded.value(forKey: "k2"), "2")
        XCTAssertEqual(reloaded.value(forKey: "k3"), "3")
    }

    func testSetValueDoesNotKeepMemoryValueWhenInsertedRowIsTrimmed() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 0,
            memoryCountLimit: .max,
            cacheRootURL: root
        )

        cache.setValue("A", forKey: "a")

        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertFalse(cache.containsKey("a"))
    }

    func testSetValuesDoesNotKeepMemoryValuesWhenRowsAreTrimmed() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 2,
            memoryCountLimit: .max,
            cacheRootURL: root
        )

        cache.setValues([
            (key: "k1", value: "1"),
            (key: "k2", value: "2"),
            (key: "k3", value: "3"),
        ])

        XCTAssertNil(cache.value(forKey: "k1"))
        XCTAssertFalse(cache.containsKey("k1"))
        XCTAssertEqual(cache.value(forKey: "k2"), "2")
        XCTAssertEqual(cache.value(forKey: "k3"), "3")
    }

    func testReadUpdatesPersistentLRUOrderBeforeTrim() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 2,
            cacheRootURL: root
        )

        cache.setValue("A", forKey: "a")
        cache.setValue("B", forKey: "b")
        XCTAssertEqual(cache.value(forKey: "a"), "A")
        cache.setValue("C", forKey: "c")

        XCTAssertEqual(cache.value(forKey: "a"), "A")
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertFalse(cache.containsKey("b"))
        XCTAssertEqual(cache.value(forKey: "c"), "C")
    }

    func testDeferredReadAccessFlushesBeforeNextInstanceTrims() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()

        var cache: LRUSQLiteCache<String, String>? = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 2,
            cacheRootURL: root
        )
        cache?.setValue("A", forKey: "a")
        cache?.setValue("B", forKey: "b")
        XCTAssertEqual(cache?.value(forKey: "a"), "A")
        cache = nil

        let reloaded = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 2,
            cacheRootURL: root
        )
        reloaded.setValue("C", forKey: "c")

        XCTAssertEqual(reloaded.value(forKey: "a"), "A")
        XCTAssertNil(reloaded.value(forKey: "b"))
        XCTAssertFalse(reloaded.containsKey("b"))
        XCTAssertEqual(reloaded.value(forKey: "c"), "C")
    }

    func testPersistentTotalBytesLimitEvictsOldestRows() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(
            namespace: namespace,
            totalBytesLimit: 12,
            countLimit: .max,
            compressionThreshold: .max,
            cacheRootURL: root
        )

        cache.setValue("123456", forKey: "one")
        cache.setValue("abcdef", forKey: "two")
        cache.setValue("uvwxyz", forKey: "three")

        XCTAssertNil(cache.value(forKey: "one"))
        XCTAssertEqual(cache.value(forKey: "two"), "abcdef")
        XCTAssertEqual(cache.value(forKey: "three"), "uvwxyz")
    }

    func testNilValueRecordsPresenceWithoutValue() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)

        cache.setValue(nil, forKey: "missing")

        XCTAssertNil(cache.value(forKey: "missing"))
        XCTAssertTrue(cache.containsKey("missing"))

        let reloaded = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(reloaded.value(forKey: "missing"))
        XCTAssertTrue(reloaded.containsKey("missing"))
    }

    func testRemoveValueAndRemoveAllDeletePersistedRows() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)

        cache.setValue("A", forKey: "a")
        cache.setValue("B", forKey: "b")
        cache.removeValue(forKey: "a")

        let afterRemove = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(afterRemove.value(forKey: "a"))
        XCTAssertFalse(afterRemove.containsKey("a"))
        XCTAssertEqual(afterRemove.value(forKey: "b"), "B")

        afterRemove.removeAll()
        let afterRemoveAll = LRUSQLiteCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(afterRemoveAll.value(forKey: "b"))
        XCTAssertFalse(afterRemoveAll.containsKey("b"))
    }

    func testVersionChangeClearsStore() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()

        let v1 = LRUSQLiteCache<String, String>(namespace: namespace, version: 1, cacheRootURL: root)
        v1.setValue("persist", forKey: "key")
        XCTAssertEqual(v1.value(forKey: "key"), "persist")

        let v2 = LRUSQLiteCache<String, String>(namespace: namespace, version: 2, cacheRootURL: root)
        XCTAssertNil(v2.value(forKey: "key"))
        XCTAssertFalse(v2.containsKey("key"))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedLRUSQLiteCacheTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeNamespace() -> String {
        "test.\(UUID().uuidString)"
    }
}
