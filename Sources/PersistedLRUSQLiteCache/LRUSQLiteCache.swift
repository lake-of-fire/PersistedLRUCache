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
        id = row[0]
        data = row[1]
        encoding = row[2]
        let rowCost: Int = row[3]
        cost = max(rowCost, 1)
        lastAccess = row[4]
    }
}

private struct SQLiteCacheValue: Sendable, Equatable {
    var data: Data?
    var encoding: String
    var cost: Int

    init(row: Row) {
        data = row[0]
        encoding = row[1]
        let rowCost: Int = row[2]
        cost = max(rowCost, 1)
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

    func fetch(id: String) throws -> SQLiteCacheValue? {
        try pool.read { db in
            let statement = try db.cachedStatement(sql: Self.fetchSQL)
            return try Row.fetchOne(statement, arguments: [id]).map(SQLiteCacheValue.init(row:))
        }
    }

    func exists(id: String) -> Bool {
        (try? pool.read { db in
            let statement = try db.cachedStatement(sql: Self.existsSQL)
            return try Int.fetchOne(statement, arguments: [id]) != nil
        }) ?? false
    }

    func upsert(_ entry: SQLiteCacheEntry) throws {
        try pool.write { db in
            try Self.upsert(entry, in: db)
        }
    }

    func upsert(_ entries: [SQLiteCacheEntry]) throws {
        guard !entries.isEmpty else { return }

        try pool.write { db in
            try Self.upsert(entries, in: db)
        }
    }

    func upsertAndTrim(
        _ entry: SQLiteCacheEntry,
        pendingAccesses: [String: Int64],
        countLimit: Int,
        totalBytesLimit: Int
    ) throws -> [String] {
        try pool.write { db in
            try Self.updateLastAccesses(pendingAccesses, in: db)
            try Self.upsert(entry, in: db)
            return try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db)
        }
    }

    func upsertAndTrim(
        _ entries: [SQLiteCacheEntry],
        pendingAccesses: [String: Int64],
        countLimit: Int,
        totalBytesLimit: Int
    ) throws -> [String] {
        guard !entries.isEmpty else { return [] }

        return try pool.write { db in
            try Self.updateLastAccesses(pendingAccesses, in: db)
            try Self.upsert(entries, in: db)
            return try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db)
        }
    }

    func updateLastAccesses(_ accesses: [String: Int64]) throws {
        guard !accesses.isEmpty else { return }
        try pool.write { db in
            try Self.updateLastAccesses(accesses, in: db)
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

                try Self.removeByIDs(ids, in: db)
                evictedIDs.append(contentsOf: ids)
            }
        }

        if totalBytesLimit != .max {
            let effectiveTotalBytesLimit = max(totalBytesLimit, 0)

            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM (
                        SELECT
                            id,
                            SUM(cost) OVER (
                                ORDER BY last_access DESC, id DESC
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                            ) AS retained_cost
                        FROM cache
                    )
                    WHERE retained_cost > ?
                    """,
                arguments: [effectiveTotalBytesLimit]
            )

            if !ids.isEmpty {
                try Self.removeByIDs(ids, in: db)
                evictedIDs.append(contentsOf: ids)
            }
        }

        return evictedIDs
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

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS cache_last_access_id_idx ON cache(last_access, id)")
        try db.execute(sql: "DROP INDEX IF EXISTS cache_last_access_idx")
    }

    private static func removeByID(_ id: String, in db: Database) throws {
        let statement = try db.cachedStatement(sql: Self.removeByIDSQL)
        try statement.execute(arguments: [id])
    }

    private static func removeByIDs(_ ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }

        let uniqueIDs = Array(Set(ids))
        let batchSize = 500
        var startIndex = uniqueIDs.startIndex

        while startIndex < uniqueIDs.endIndex {
            let endIndex = uniqueIDs.index(
                startIndex,
                offsetBy: batchSize,
                limitedBy: uniqueIDs.endIndex
            ) ?? uniqueIDs.endIndex
            let batch = Array(uniqueIDs[startIndex..<endIndex])
            let questionMarks = databaseQuestionMarks(count: batch.count)
            try db.execute(
                sql: "DELETE FROM cache WHERE id IN (\(questionMarks))",
                arguments: StatementArguments(batch)
            )
            startIndex = endIndex
        }
    }

    private static func updateLastAccesses(_ accesses: [String: Int64], in db: Database) throws {
        guard !accesses.isEmpty else { return }

        let statement = try db.cachedStatement(sql: Self.updateLastAccessSQL)
        for (id, lastAccess) in accesses {
            try statement.execute(arguments: [lastAccess, id])
        }
    }

    private static func upsert(_ entry: SQLiteCacheEntry, in db: Database) throws {
        let statement = try db.cachedStatement(sql: Self.upsertSQL)
        try statement.execute(arguments: [entry.id, entry.data, entry.encoding, entry.cost, entry.lastAccess])
    }

    private static func upsert(_ entries: [SQLiteCacheEntry], in db: Database) throws {
        guard !entries.isEmpty else { return }

        let statement = try db.cachedStatement(sql: Self.upsertSQL)
        for entry in entries {
            try statement.execute(arguments: [entry.id, entry.data, entry.encoding, entry.cost, entry.lastAccess])
        }
    }

    private static let fetchSQL = """
        SELECT data, encoding, cost
        FROM cache
        WHERE id = ?
        LIMIT 1
        """

    private static let existsSQL = """
        SELECT 1
        FROM cache
        WHERE id = ?
        LIMIT 1
        """

    private static let removeByIDSQL = """
        DELETE FROM cache
        WHERE id = ?
        """

    private static let updateLastAccessSQL = """
        UPDATE cache
        SET last_access = ?
        WHERE id = ?
        """

    private static let upsertSQL = """
        INSERT INTO cache(id, data, encoding, cost, last_access)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            data = excluded.data,
            encoding = excluded.encoding,
            cost = excluded.cost,
            last_access = excluded.last_access
        """
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
    private let tracksPersistentAccess: Bool
    private let store: SQLiteLRUStore?
    private let lock = NSRecursiveLock()
    private var lastAccessCounter: Int64 = 0
    private var pendingLastAccesses: [String: Int64] = [:]
    private let pendingAccessFlushCount = 256

    private var jsonEncoder: JSONEncoder {
        PersistedLRUCacheSupport.jsonEncoder()
    }

    deinit {
        flushPendingAccesses()
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
        tracksPersistentAccess = countLimit != .max || totalBytesLimit != .max

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
        discardPendingAccess(forKeyHash: keyHash)
        try? store?.removeByID(keyHash)
    }

    public func removeAll() {
        lock.lock()
        cache.removeAll()
        pendingLastAccesses.removeAll(keepingCapacity: true)
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
            if tracksPersistentAccess {
                recordPersistentAccess(forKeyHash: keyHash)
            }
            return cached
        }

        guard let entry = try? store?.fetch(id: keyHash) else {
            return nil
        }

        let decoded = try? PersistedLRUCacheCodec.decode(O.self, from: payload(from: entry))
        if let decoded {
            setMemoryValue(decoded, forKeyHash: keyHash, cost: entry.cost)
        }

        if tracksPersistentAccess {
            recordPersistentAccess(forKeyHash: keyHash)
        }
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

        let evictedIDs: [String]
        do {
            if tracksPersistentAccess {
                evictedIDs = try store?.upsertAndTrim(
                    entry,
                    pendingAccesses: takePendingAccesses(),
                    countLimit: countLimit,
                    totalBytesLimit: totalBytesLimit
                ) ?? []
            } else {
                try store?.upsert(entry)
                evictedIDs = []
            }

            removeMemoryValues(forKeyHashes: evictedIDs)
        } catch {
            print("SQLite cache write error: \(error)")
            return
        }

        if evictedIDs.contains(keyHash) {
            removeMemoryValue(forKeyHash: keyHash)
        } else if let value {
            setMemoryValue(value, forKeyHash: keyHash, cost: payload.cost)
        } else {
            removeMemoryValue(forKeyHash: keyHash)
        }
    }

    public func setValues(_ values: [(key: I, value: O?)]) {
        guard !values.isEmpty else { return }

        var encodedValues: [(keyHash: String, value: O?, payload: PersistedLRUCachePayload)] = []
        encodedValues.reserveCapacity(values.count)
        var memoryUpdates: [(keyHash: String, value: O, cost: Int)] = []
        memoryUpdates.reserveCapacity(values.count)
        var memoryRemovals: [String] = []
        memoryRemovals.reserveCapacity(values.count)
        let encoder = jsonEncoder

        for (key, value) in values {
            guard let keyHash = cacheKeyHash(key) else { continue }

            let payload: PersistedLRUCachePayload
            do {
                payload = try PersistedLRUCacheCodec.encode(
                    value,
                    compressionThreshold: compressionThreshold,
                    encoder: encoder
                )
            } catch {
                print("Encoding error: \(error)")
                continue
            }

            encodedValues.append((keyHash, value, payload))

            if let value {
                memoryUpdates.append((keyHash, value, payload.cost))
            } else {
                memoryRemovals.append(keyHash)
            }
        }

        guard !encodedValues.isEmpty else { return }

        let lastAccesses = nextLastAccesses(count: encodedValues.count)
        var entries: [SQLiteCacheEntry] = []
        entries.reserveCapacity(encodedValues.count)
        for (offset, encodedValue) in encodedValues.enumerated() {
            entries.append(
                SQLiteCacheEntry(
                    id: encodedValue.keyHash,
                    data: encodedValue.payload.data,
                    encoding: encodedValue.payload.encoding,
                    cost: encodedValue.payload.cost,
                    lastAccess: lastAccesses[offset]
                )
            )
        }

        let evictedIDs: [String]
        do {
            if tracksPersistentAccess {
                evictedIDs = try store?.upsertAndTrim(
                    entries,
                    pendingAccesses: takePendingAccesses(),
                    countLimit: countLimit,
                    totalBytesLimit: totalBytesLimit
                ) ?? []
            } else {
                try store?.upsert(entries)
                evictedIDs = []
            }

        } catch {
            print("SQLite cache write error: \(error)")
            return
        }

        updateMemoryValues(memoryUpdates, removing: memoryRemovals + evictedIDs)
    }

    private func cacheKeyHash(_ key: I) -> String? {
        PersistedLRUCacheSupport.cacheKeyHash(key)
    }

    private func payload(from entry: SQLiteCacheValue) -> PersistedLRUCachePayload {
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

    private func removeMemoryValues(forKeyHashes keyHashes: [String]) {
        guard !keyHashes.isEmpty else { return }

        lock.lock()
        for keyHash in keyHashes {
            cache.removeValue(forKey: keyHash)
        }
        lock.unlock()
    }

    private func updateMemoryValues(
        _ updates: [(keyHash: String, value: O, cost: Int)],
        removing removals: [String]
    ) {
        guard !updates.isEmpty || !removals.isEmpty else { return }

        lock.lock()
        for (keyHash, value, cost) in updates {
            cache.setValue(value, forKey: keyHash, cost: cost)
        }
        for keyHash in removals {
            cache.removeValue(forKey: keyHash)
        }
        lock.unlock()
    }

    private func recordPersistentAccess(forKeyHash keyHash: String) {
        let pendingAccessesToFlush: [String: Int64]?

        lock.lock()
        advanceLastAccessCounter()
        pendingLastAccesses[keyHash] = lastAccessCounter
        if pendingLastAccesses.count >= pendingAccessFlushCount {
            pendingAccessesToFlush = pendingLastAccesses
            pendingLastAccesses.removeAll(keepingCapacity: true)
        } else {
            pendingAccessesToFlush = nil
        }
        lock.unlock()

        if let pendingAccessesToFlush {
            try? store?.updateLastAccesses(pendingAccessesToFlush)
        }
    }

    private func takePendingAccesses() -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        let pendingAccesses = pendingLastAccesses
        pendingLastAccesses.removeAll(keepingCapacity: true)
        return pendingAccesses
    }

    private func discardPendingAccess(forKeyHash keyHash: String) {
        lock.lock()
        pendingLastAccesses.removeValue(forKey: keyHash)
        lock.unlock()
    }

    private func flushPendingAccesses() {
        let pendingAccesses = takePendingAccesses()
        try? store?.updateLastAccesses(pendingAccesses)
    }

    private func nextLastAccess() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return advanceLastAccessCounter()
    }

    private func nextLastAccesses(count: Int) -> [Int64] {
        lock.lock()
        defer { lock.unlock() }

        var accesses: [Int64] = []
        accesses.reserveCapacity(count)
        for _ in 0..<count {
            accesses.append(advanceLastAccessCounter())
        }
        return accesses
    }

    @discardableResult
    private func advanceLastAccessCounter() -> Int64 {
        if lastAccessCounter == .max {
            lastAccessCounter = monotonicTime()
        } else {
            lastAccessCounter += 1
        }
        return lastAccessCounter
    }

    private func monotonicTime() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
