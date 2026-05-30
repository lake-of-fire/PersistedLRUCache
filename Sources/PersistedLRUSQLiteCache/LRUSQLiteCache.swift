import Combine
import Foundation
import GRDB
import LRUCache
import PersistedLRUCacheCore

private struct SQLiteCacheEntry: Sendable, Equatable {
    var id: String
    var data: Data?
    var encoding: String
    var cost: Int
    var lastAccess: Int64

    init(id: String, data: Data?, encoding: String, cost: Int, lastAccess: Int64) {
        self.id = id
        self.data = data
        self.encoding = encoding
        self.cost = max(cost, 1)
        self.lastAccess = lastAccess
    }

    init(row: Row) {
        id = row["id"]
        data = row["data"]
        encoding = row["encoding"]
        let rowCost: Int = row["cost"]
        cost = max(rowCost, 1)
        lastAccess = row["last_access"]
    }
}

private struct SQLiteLRUStore {
    private let pool: DatabasePool

    init(fileURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.maximumReaderCount = 8
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys=OFF")
        }

        pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try pool.write { db in
            try Self.ensureSchema(db)
        }
    }

    func fetch(id: String) throws -> SQLiteCacheEntry? {
        try pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, data, encoding, cost, last_access
                    FROM cache
                    WHERE id = ?
                    LIMIT 1
                    """,
                arguments: [id]
            ).map(SQLiteCacheEntry.init(row:))
        }
    }

    func exists(id: String) -> Bool {
        (try? pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM cache
                    WHERE id = ?
                    LIMIT 1
                    """,
                arguments: [id]
            ) != nil
        }) ?? false
    }

    func upsert(_ entry: SQLiteCacheEntry) throws {
        try pool.write { db in
            try Self.upsert(entry, in: db)
        }
    }

    func upsertAndTrim(_ entry: SQLiteCacheEntry, countLimit: Int, totalBytesLimit: Int) throws -> [String] {
        try pool.write { db in
            try Self.upsert(entry, in: db)
            return try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db)
        }
    }

    func updateLastAccess(id: String, lastAccess: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cache
                    SET last_access = ?
                    WHERE id = ?
                    """,
                arguments: [lastAccess, id]
            )
        }
    }

    func removeByID(_ id: String) throws {
        try pool.write { db in
            try Self.removeByID(id, in: db)
        }
    }

    func removeAll() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM cache")
        }
    }

    func maximumLastAccess() -> Int64 {
        (try? pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(last_access), 0) FROM cache") ?? 0
        }) ?? 0
    }

    func trim(countLimit: Int, totalBytesLimit: Int) throws -> [String] {
        try pool.write { db in
            try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db)
        }
    }

    private static func trim(countLimit: Int, totalBytesLimit: Int, in db: Database) throws -> [String] {
        guard countLimit != .max || totalBytesLimit != .max else {
            return []
        }

        var evictedIDs: [String] = []

        if countLimit != .max {
            let effectiveCountLimit = max(countLimit, 0)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cache") ?? 0
            let overflowCount = count - effectiveCountLimit

            if overflowCount > 0 {
                let ids = try String.fetchAll(
                    db,
                    sql: """
                        SELECT id
                        FROM cache
                        ORDER BY last_access ASC, id ASC
                        LIMIT ?
                        """,
                    arguments: [overflowCount]
                )

                for id in ids {
                    try Self.removeByID(id, in: db)
                }
                evictedIDs.append(contentsOf: ids)
            }
        }

        if totalBytesLimit != .max {
            let effectiveTotalBytesLimit = max(totalBytesLimit, 0)
            var totalCost = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(cost), 0) FROM cache") ?? 0

            if totalCost > effectiveTotalBytesLimit {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, cost
                        FROM cache
                        ORDER BY last_access ASC, id ASC
                        """
                )

                for row in rows where totalCost > effectiveTotalBytesLimit {
                    let id: String = row["id"]
                    let rowCost: Int = row["cost"]
                    let cost = max(rowCost, 1)
                    try Self.removeByID(id, in: db)
                    evictedIDs.append(id)
                    totalCost -= cost
                }
            }
        }

        return Array(Set(evictedIDs))
    }

    private static func ensureSchema(_ db: Database) throws {
        let tableExists = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM sqlite_master
                    WHERE type = 'table' AND name = 'cache'
                )
                """
        ) ?? false

        if !tableExists {
            try db.execute(
                sql: """
                    CREATE TABLE cache(
                        id TEXT NOT NULL PRIMARY KEY,
                        data BLOB,
                        encoding TEXT NOT NULL,
                        cost INTEGER NOT NULL DEFAULT 1,
                        last_access INTEGER NOT NULL DEFAULT 0
                    )
                    """
            )
        } else {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(cache)")
            let columnNames = Set(columns.compactMap { row -> String? in row["name"] })

            if !columnNames.contains("cost") {
                try db.execute(sql: "ALTER TABLE cache ADD COLUMN cost INTEGER NOT NULL DEFAULT 1")
                try db.execute(
                    sql: """
                        UPDATE cache
                        SET cost = CASE
                            WHEN data IS NULL OR length(data) < 1 THEN 1
                            ELSE length(data)
                        END
                        """
                )
            }

            if !columnNames.contains("last_access") {
                try db.execute(sql: "ALTER TABLE cache ADD COLUMN last_access INTEGER NOT NULL DEFAULT 0")
                try db.execute(sql: "UPDATE cache SET last_access = rowid WHERE last_access = 0")
            }
        }

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS cache_last_access_idx ON cache(last_access)")
    }

    private static func removeByID(_ id: String, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM cache
                WHERE id = ?
                """,
            arguments: [id]
        )
    }

    private static func upsert(_ entry: SQLiteCacheEntry, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO cache(id, data, encoding, cost, last_access)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    data = excluded.data,
                    encoding = excluded.encoding,
                    cost = excluded.cost,
                    last_access = excluded.last_access
                """,
            arguments: [entry.id, entry.data, entry.encoding, entry.cost, entry.lastAccess]
        )
    }
}

/// An SQLite-backed persisted cache with an in-memory LRU front cache.
///
/// The SQLite table is the persisted LRU store. The in-memory cache only
/// accelerates hot reads, so memory evictions do not make persisted values
/// disappear.
open class LRUSQLiteCache<I: Encodable, O: Codable>: ObservableObject {
    @Published public var cacheDirectory: URL

    private let cache: LRUCache<String, Any>
    private let totalBytesLimit: Int
    private let countLimit: Int
    private let compressionThreshold: Int
    private let store: SQLiteLRUStore?
    private let lock = NSRecursiveLock()
    private var lastAccessCounter: Int64 = 0

    private var jsonEncoder: JSONEncoder {
        PersistedLRUCacheSupport.jsonEncoder()
    }

    public init(
        namespace: String,
        version: Int? = nil,
        totalBytesLimit: Int = .max,
        countLimit: Int = .max,
        memoryTotalBytesLimit: Int? = nil,
        memoryCountLimit: Int? = nil,
        compressionThreshold: Int = 200_000,
        cacheRootURL: URL? = nil
    ) {
        assert(!namespace.isEmpty, "LRUSQLiteCache namespace must not be empty")

        self.totalBytesLimit = totalBytesLimit
        self.countLimit = countLimit
        self.compressionThreshold = compressionThreshold

        let fileManager = FileManager.default
        let cacheRoot = cacheRootURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDirectory = cacheRoot.appendingPathComponent("LRUFileCache").appendingPathComponent(namespace)
        self.cacheDirectory = cacheDirectory
        cache = LRUCache(
            totalCostLimit: memoryTotalBytesLimit ?? totalBytesLimit,
            countLimit: memoryCountLimit ?? countLimit
        )

        let versionFileURL = cacheDirectory.appendingPathComponent("lru_cache_version.txt")
        let versionString = PersistedLRUCacheSupport.cacheVersionString(
            baseVersion: version.map(String.init) ?? PersistedLRUCacheSupport.bundleVersionString
        )
        let dbURL = cacheDirectory.appendingPathComponent("cache.sqlite")

        do {
            let store = try SQLiteLRUStore(fileURL: dbURL)
            if let versionData = try? Data(contentsOf: versionFileURL),
               String(data: versionData, encoding: .utf8) != versionString {
                try store.removeAll()
            } else if !fileManager.fileExists(atPath: versionFileURL.path) {
                try store.removeAll()
            }

            try Data(versionString.utf8).write(to: versionFileURL)
            self.store = store
            lastAccessCounter = max(monotonicTime(), store.maximumLastAccess())
        } catch {
            print("Failed to initialize SQLiteLRUStore: \(error)")
            store = nil
        }
    }

    public func removeValue(forKey key: I) {
        guard let keyHash = cacheKeyHash(key) else { return }
        removeMemoryValue(forKeyHash: keyHash)
        try? store?.removeByID(keyHash)
    }

    public func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()

        try? store?.removeAll()
    }

    public func hasKey(_ key: I) -> Bool {
        containsKey(key)
    }

    public func containsKey(_ key: I) -> Bool {
        guard let keyHash = cacheKeyHash(key) else { return false }
        if hasMemoryValue(forKeyHash: keyHash) {
            return true
        }
        return store?.exists(id: keyHash) ?? false
    }

    public func value(forKey key: I) -> O? {
        guard let keyHash = cacheKeyHash(key) else { return nil }

        if let cached = memoryValue(forKeyHash: keyHash) {
            try? store?.updateLastAccess(id: keyHash, lastAccess: nextLastAccess())
            return cached
        }

        guard let entry = try? store?.fetch(id: keyHash) else {
            return nil
        }

        let decoded = try? PersistedLRUCacheCodec.decode(O.self, from: payload(from: entry))
        if let decoded {
            setMemoryValue(decoded, forKeyHash: keyHash, cost: entry.cost)
        }

        try? store?.updateLastAccess(id: keyHash, lastAccess: nextLastAccess())
        return decoded ?? nil
    }

    public func setValue(_ value: O?, forKey key: I) {
        guard let keyHash = cacheKeyHash(key) else { return }

        let payload: PersistedLRUCachePayload
        do {
            payload = try PersistedLRUCacheCodec.encode(
                value,
                compressionThreshold: compressionThreshold,
                encoder: jsonEncoder
            )
        } catch {
            print("Encoding error: \(error)")
            return
        }

        let entry = SQLiteCacheEntry(
            id: keyHash,
            data: payload.data,
            encoding: payload.encoding,
            cost: payload.cost,
            lastAccess: nextLastAccess()
        )

        do {
            if let evictedIDs = try store?.upsertAndTrim(
                entry,
                countLimit: countLimit,
                totalBytesLimit: totalBytesLimit
            ) {
                for evictedID in evictedIDs {
                    removeMemoryValue(forKeyHash: evictedID)
                }
            }
        } catch {
            print("SQLite cache write error: \(error)")
            return
        }

        if let value {
            setMemoryValue(value, forKeyHash: keyHash, cost: payload.cost)
        } else {
            removeMemoryValue(forKeyHash: keyHash)
        }
    }

    private func cacheKeyHash(_ key: I) -> String? {
        PersistedLRUCacheSupport.cacheKeyHash(key, encoder: jsonEncoder)
    }

    private func payload(from entry: SQLiteCacheEntry) -> PersistedLRUCachePayload {
        PersistedLRUCachePayload(data: entry.data, encoding: entry.encoding)
    }

    private func hasMemoryValue(forKeyHash keyHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache.hasValue(forKey: keyHash)
    }

    private func memoryValue(forKeyHash keyHash: String) -> O? {
        lock.lock()
        defer { lock.unlock() }
        return cache.value(forKey: keyHash) as? O
    }

    private func setMemoryValue(_ value: O, forKeyHash keyHash: String, cost: Int) {
        lock.lock()
        cache.setValue(value, forKey: keyHash, cost: cost)
        lock.unlock()
    }

    private func removeMemoryValue(forKeyHash keyHash: String) {
        lock.lock()
        cache.removeValue(forKey: keyHash)
        lock.unlock()
    }

    private func nextLastAccess() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        lastAccessCounter = max(lastAccessCounter + 1, monotonicTime())
        return lastAccessCounter
    }

    private func monotonicTime() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
