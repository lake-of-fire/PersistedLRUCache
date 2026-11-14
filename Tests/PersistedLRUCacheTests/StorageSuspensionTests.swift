import Foundation
import GRDB
import XCTest
@testable import PersistedLRUCacheHybrid

final class StorageSuspensionTests: XCTestCase {
    func testSuspensionRejectsHybridWritesUntilResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridSuspension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PersistedLRUCache<String, String>(namespace: "suspension", cacheRootURL: root)
        cache.setValue("before", forKey: "key")
        cache.flushPendingWrites()
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        defer { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }
        cache.setValue("rejected", forKey: "key")
        cache.flushPendingWrites()
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        let reloaded = PersistedLRUCache<String, String>(namespace: "suspension", cacheRootURL: root)
        XCTAssertEqual(reloaded.value(forKey: "key"), "before")
        cache.setValue("resumed", forKey: "key")
        cache.flushPendingWrites()
        XCTAssertEqual(PersistedLRUCache<String, String>(namespace: "suspension", cacheRootURL: root).value(forKey: "key"), "resumed")
    }
}
