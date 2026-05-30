import Foundation
import XCTest
@testable import PersistedLRUFileCache

final class LRUFileCacheTests: XCTestCase {
    struct Record: Codable, Equatable {
        var title: String
        var values: [Int]
    }

    func testStringValuePersistsAcrossInstances() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()

        let cache = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)
        cache.setValue("hello", forKey: "greeting")

        XCTAssertEqual(cache.value(forKey: "greeting"), "hello")
        XCTAssertTrue(cache.containsKey("greeting"))

        let reloaded = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertEqual(reloaded.value(forKey: "greeting"), "hello")
    }

    func testDataAndCodableValuesRoundTripCompressed() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()

        let dataCache = LRUFileCache<String, Data>(
            namespace: namespace + ".data",
            compressionThreshold: 32,
            cacheRootURL: root
        )
        let data = Data(repeating: 0x42, count: 512)
        dataCache.setValue(data, forKey: "data")
        XCTAssertEqual(dataCache.value(forKey: "data"), data)

        let recordCache = LRUFileCache<String, Record>(
            namespace: namespace + ".record",
            compressionThreshold: 32,
            cacheRootURL: root
        )
        let record = Record(title: String(repeating: "x", count: 256), values: Array(0..<32))
        recordCache.setValue(record, forKey: "record")
        XCTAssertEqual(recordCache.value(forKey: "record"), record)
    }

    func testMemoryEvictionRetainsDiskValue() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUFileCache<String, String>(
            namespace: namespace,
            totalBytesLimit: .max,
            countLimit: 1,
            cacheRootURL: root
        )

        cache.setValue("A", forKey: "a")
        cache.setValue("B", forKey: "b")

        XCTAssertEqual(cache.value(forKey: "a"), "A")
        XCTAssertEqual(cache.value(forKey: "b"), "B")
    }

    func testLargeValueCanStayDiskOnly() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUFileCache<String, String>(
            namespace: namespace,
            memoryThreshold: 16,
            compressionThreshold: 32,
            cacheRootURL: root
        )
        let largeValue = String(repeating: "large", count: 128)

        cache.setValue(largeValue, forKey: "large")
        XCTAssertEqual(cache.value(forKey: "large"), largeValue)

        let reloaded = LRUFileCache<String, String>(
            namespace: namespace,
            memoryThreshold: 16,
            compressionThreshold: 32,
            cacheRootURL: root
        )
        XCTAssertEqual(reloaded.value(forKey: "large"), largeValue)
    }

    func testNilValueRecordsPresenceWithoutValue() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)

        cache.setValue(nil, forKey: "missing")

        XCTAssertNil(cache.value(forKey: "missing"))
        XCTAssertTrue(cache.containsKey("missing"))

        let reloaded = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(reloaded.value(forKey: "missing"))
        XCTAssertTrue(reloaded.containsKey("missing"))
    }

    func testRemoveValueAndRemoveAllDeletePersistedValues() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()
        let cache = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)

        cache.setValue("A", forKey: "a")
        cache.setValue("B", forKey: "b")
        cache.removeValue(forKey: "a")

        let afterRemove = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(afterRemove.value(forKey: "a"))
        XCTAssertEqual(afterRemove.value(forKey: "b"), "B")

        afterRemove.removeAll()
        let afterRemoveAll = LRUFileCache<String, String>(namespace: namespace, cacheRootURL: root)
        XCTAssertNil(afterRemoveAll.value(forKey: "b"))
        XCTAssertFalse(afterRemoveAll.containsKey("b"))
    }

    func testVersionChangeClearsNamespace() throws {
        let root = try makeTemporaryRoot()
        let namespace = makeNamespace()

        let v1 = LRUFileCache<String, String>(namespace: namespace, version: 1, cacheRootURL: root)
        v1.setValue("persist", forKey: "key")
        XCTAssertEqual(v1.value(forKey: "key"), "persist")

        let v2 = LRUFileCache<String, String>(namespace: namespace, version: 2, cacheRootURL: root)
        XCTAssertNil(v2.value(forKey: "key"))
        XCTAssertFalse(v2.containsKey("key"))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedLRUFileCacheTests")
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
