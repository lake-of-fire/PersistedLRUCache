import Combine
import Foundation
import GRDB
import LRUCache
import PersistedLRUCacheCore

private struct HybridCacheEntry: Sendable, Equatable {
    var id: String
    var data: Data?
    var fileName: String?
    var encoding: String
    var cost: Int
    var lastAccess: Int64

    init(id: String, data: Data?, fileName: String?, encoding: String, cost: Int, lastAccess: Int64) {
        self.id = id
        self.data = data
        self.fileName = fileName
        self.encoding = encoding
        self.cost = max(cost, 1)
        self.lastAccess = lastAccess
    }
}

private struct HybridCacheValue: Sendable, Equatable {
    var data: Data?
    var fileName: String?
    var encoding: String
    var cost: Int

    init(row: Row) {
        data = row[0]
        fileName = row[1]
        encoding = row[2]
        let rowCost: Int = row[3]
        cost = max(rowCost, 1)
    }
}

private struct HybridCacheMutationResult: Sendable, Equatable {
    var evictedIDs: [String] = []
    var obsoleteFileNames: [String] = []
    var itemCountDelta: Int = 0
    var totalCostDelta: Int = 0
}

private struct HybridCacheStats: Sendable, Equatable {
    var count: Int
    var totalCost: Int
}

private struct HybridExistingEntry: Sendable, Equatable {
    var cost: Int
    var fileName: String?
}

private struct HybridSQLiteLRUStore {
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

    func fetch(id: String) throws -> HybridCacheValue? {
        try pool.read { db in
            let statement = try db.cachedStatement(sql: Self.fetchSQL)
            return try Row.fetchOne(statement, arguments: [id]).map(HybridCacheValue.init(row:))
        }
    }

    func exists(id: String) -> Bool {
        (try? pool.read { db in
            let statement = try db.cachedStatement(sql: Self.existsSQL)
            return try Int.fetchOne(statement, arguments: [id]) != nil
        }) ?? false
    }

    func fileName(id: String) throws -> String? {
        try pool.read { db in
            let statement = try db.cachedStatement(sql: Self.fileNameSQL)
            return try String.fetchOne(statement, arguments: [id])
        }
    }

    func upsert(_ entry: HybridCacheEntry) throws -> HybridCacheMutationResult {
        try pool.write { db in
            try Self.upsert([entry], in: db)
        }
    }

    func upsert(_ entries: [HybridCacheEntry]) throws -> HybridCacheMutationResult {
        guard !entries.isEmpty else { return HybridCacheMutationResult() }

        return try pool.write { db in
            try Self.upsert(entries, in: db)
        }
    }

    func upsert(_ entry: HybridCacheEntry, pendingAccesses: [String: Int64]) throws -> HybridCacheMutationResult {
        try pool.write { db in
            try Self.updateLastAccesses(pendingAccesses, in: db)
            return try Self.upsert([entry], in: db)
        }
    }

    func upsert(_ entries: [HybridCacheEntry], pendingAccesses: [String: Int64]) throws -> HybridCacheMutationResult {
        guard !entries.isEmpty else { return HybridCacheMutationResult() }

        return try pool.write { db in
            try Self.updateLastAccesses(pendingAccesses, in: db)
            return try Self.upsert(entries, in: db)
        }
    }

    func upsertAndTrim(
        _ entry: HybridCacheEntry,
        pendingAccesses: [String: Int64],
        countLimit: Int,
        totalBytesLimit: Int
    ) throws -> HybridCacheMutationResult {
        try pool.write { db in
            try Self.updateLastAccesses(pendingAccesses, in: db)
            var result = try Self.upsert([entry], in: db)
            result.merge(try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db))
            return result
        }
    }

    func upsertAndTrim(
        _ entries: [HybridCacheEntry],
        pendingAccesses: [String: Int64],
        countLimit: Int,
        totalBytesLimit: Int
    ) throws -> HybridCacheMutationResult {
        guard !entries.isEmpty else { return HybridCacheMutationResult() }

        return try pool.write { db in
            try Self.updateLastAccesses(pendingAccesses, in: db)
            var result = try Self.upsert(entries, in: db)
            result.merge(try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db))
            return result
        }
    }

    func updateLastAccesses(_ accesses: [String: Int64]) throws {
        guard !accesses.isEmpty else { return }
        try pool.write { db in
            try Self.updateLastAccesses(accesses, in: db)
        }
    }

    func trim(countLimit: Int, totalBytesLimit: Int) throws -> HybridCacheMutationResult {
        try pool.write { db in
            try Self.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit, in: db)
        }
    }

    func cacheStats() throws -> HybridCacheStats {
        try pool.read { db in
            try Self.cacheStats(in: db)
        }
    }

    func removeByID(_ id: String) throws -> HybridCacheMutationResult {
        try pool.write { db in
            let existing = try Self.existingEntries(forIDs: [id], in: db)
            let fileNames = existing.values.compactMap(\.fileName)
            try Self.removeByIDs([id], in: db)
            let oldCost = existing[id]?.cost ?? 0
            return HybridCacheMutationResult(
                obsoleteFileNames: fileNames,
                itemCountDelta: existing[id] == nil ? 0 : -1,
                totalCostDelta: -oldCost
            )
        }
    }

    func removeAll() throws -> [String] {
        try pool.write { db in
            let fileNames = try String.fetchAll(db, sql: "SELECT file_name FROM cache WHERE file_name IS NOT NULL")
            try db.execute(sql: "DELETE FROM cache")
            return fileNames
        }
    }

    func maximumLastAccess() -> Int64 {
        (try? pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(last_access), 0) FROM cache") ?? 0
        }) ?? 0
    }

    private static func trim(countLimit: Int, totalBytesLimit: Int, in db: Database) throws -> HybridCacheMutationResult {
        guard countLimit != .max || totalBytesLimit != .max else {
            return HybridCacheMutationResult()
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
            evictedIDs.append(contentsOf: ids)
        }

        let uniqueEvictedIDs = orderedUnique(evictedIDs)
        let fileNames = try fileNames(forIDs: uniqueEvictedIDs, in: db)
        try removeByIDs(uniqueEvictedIDs, in: db)
        return HybridCacheMutationResult(
            evictedIDs: uniqueEvictedIDs,
            obsoleteFileNames: fileNames
        )
    }

    private static func cacheStats(in db: Database) throws -> HybridCacheStats {
        let row = try Row.fetchOne(db, sql: "SELECT COUNT(*), COALESCE(SUM(cost), 0) FROM cache")
        return HybridCacheStats(
            count: row?[0] ?? 0,
            totalCost: row?[1] ?? 0
        )
    }

    private static func ensureSchema(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS cache(
                    id TEXT NOT NULL PRIMARY KEY,
                    data BLOB,
                    file_name TEXT,
                    encoding TEXT NOT NULL,
                    cost INTEGER NOT NULL DEFAULT 1,
                    last_access INTEGER NOT NULL DEFAULT 0
                )
                """
        )

        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(cache)")
        let columnNames = Set(columns.compactMap { row -> String? in row["name"] })

        if !columnNames.contains("file_name") {
            try db.execute(sql: "ALTER TABLE cache ADD COLUMN file_name TEXT")
        }

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

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS cache_last_access_id_idx ON cache(last_access, id)")
        try db.execute(sql: "DROP INDEX IF EXISTS cache_last_access_idx")
    }

    private static func upsert(_ entries: [HybridCacheEntry], in db: Database) throws -> HybridCacheMutationResult {
        guard !entries.isEmpty else { return HybridCacheMutationResult() }

        let ids = orderedUnique(entries.map(\.id))
        let existing = try existingEntries(forIDs: ids, in: db)
        let oldFileNames = existing.values.compactMap(\.fileName)
        let newFileNames = Set(entries.compactMap(\.fileName))
        let obsoleteFileNames = oldFileNames.filter { !newFileNames.contains($0) }
        var finalCostByID = [String: Int]()
        finalCostByID.reserveCapacity(ids.count)
        for entry in entries {
            finalCostByID[entry.id] = entry.cost
        }
        var itemCountDelta = 0
        var totalCostDelta = 0
        for (id, cost) in finalCostByID {
            if let existing = existing[id] {
                totalCostDelta += cost - existing.cost
            } else {
                itemCountDelta += 1
                totalCostDelta += cost
            }
        }

        let statement = try db.cachedStatement(sql: Self.upsertSQL)
        for entry in entries {
            try statement.execute(arguments: [
                entry.id,
                entry.data,
                entry.fileName,
                entry.encoding,
                entry.cost,
                entry.lastAccess,
            ])
        }

        return HybridCacheMutationResult(
            obsoleteFileNames: obsoleteFileNames,
            itemCountDelta: itemCountDelta,
            totalCostDelta: totalCostDelta
        )
    }

    private static func existingEntries(forIDs ids: [String], in db: Database) throws -> [String: HybridExistingEntry] {
        let ids = orderedUnique(ids)
        guard !ids.isEmpty else { return [:] }

        var output = [String: HybridExistingEntry]()
        output.reserveCapacity(ids.count)
        let batchSize = 500
        var startIndex = ids.startIndex

        while startIndex < ids.endIndex {
            let endIndex = ids.index(
                startIndex,
                offsetBy: batchSize,
                limitedBy: ids.endIndex
            ) ?? ids.endIndex
            let batch = Array(ids[startIndex..<endIndex])
            let questionMarks = sqlQuestionMarks(count: batch.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, cost, file_name FROM cache WHERE id IN (\(questionMarks))",
                arguments: StatementArguments(batch)
            )
            for row in rows {
                let id: String = row[0]
                let cost: Int = row[1]
                let fileName: String? = row[2]
                output[id] = HybridExistingEntry(cost: max(cost, 1), fileName: fileName)
            }
            startIndex = endIndex
        }

        return output
    }

    private static func fileNames(forIDs ids: [String], in db: Database) throws -> [String] {
        let ids = orderedUnique(ids)
        guard !ids.isEmpty else { return [] }

        var output: [String] = []
        let batchSize = 500
        var startIndex = ids.startIndex

        while startIndex < ids.endIndex {
            let endIndex = ids.index(
                startIndex,
                offsetBy: batchSize,
                limitedBy: ids.endIndex
            ) ?? ids.endIndex
            let batch = Array(ids[startIndex..<endIndex])
            let questionMarks = sqlQuestionMarks(count: batch.count)
            let fileNames = try String.fetchAll(
                db,
                sql: "SELECT file_name FROM cache WHERE id IN (\(questionMarks)) AND file_name IS NOT NULL",
                arguments: StatementArguments(batch)
            )
            output.append(contentsOf: fileNames)
            startIndex = endIndex
        }

        return orderedUnique(output)
    }

    private static func removeByIDs(_ ids: [String], in db: Database) throws {
        let ids = orderedUnique(ids)
        guard !ids.isEmpty else { return }

        let batchSize = 500
        var startIndex = ids.startIndex

        while startIndex < ids.endIndex {
            let endIndex = ids.index(
                startIndex,
                offsetBy: batchSize,
                limitedBy: ids.endIndex
            ) ?? ids.endIndex
            let batch = Array(ids[startIndex..<endIndex])
            let questionMarks = sqlQuestionMarks(count: batch.count)
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

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        seen.reserveCapacity(values.count)
        return values.filter { seen.insert($0).inserted }
    }

    private static func sqlQuestionMarks(count: Int) -> String {
        precondition(count > 0)
        return Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static let fetchSQL = """
        SELECT data, file_name, encoding, cost
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

    private static let fileNameSQL = """
        SELECT file_name
        FROM cache
        WHERE id = ?
        LIMIT 1
        """

    private static let updateLastAccessSQL = """
        UPDATE cache
        SET last_access = ?
        WHERE id = ?
        """

    private static let upsertSQL = """
        INSERT INTO cache(id, data, file_name, encoding, cost, last_access)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            data = excluded.data,
            file_name = excluded.file_name,
            encoding = excluded.encoding,
            cost = excluded.cost,
            last_access = excluded.last_access
        """
}

private extension HybridCacheMutationResult {
    mutating func merge(_ other: HybridCacheMutationResult) {
        evictedIDs.append(contentsOf: other.evictedIDs)
        obsoleteFileNames.append(contentsOf: other.obsoleteFileNames)
        itemCountDelta += other.itemCountDelta
        totalCostDelta += other.totalCostDelta
    }
}

/// A persisted LRU cache backed by SQLite metadata with an in-memory front cache.
///
/// Small encoded values are stored inline in SQLite. Values whose encoded payload
/// exceeds `inlineStorageThreshold` are stored as external files while SQLite
/// keeps their LRU metadata, encoding, cost, and file pointer. This keeps SQLite
/// fast for many small cache entries without pushing large blobs into the WAL.
open class PersistedLRUCache<I: Encodable, O: Codable>: ObservableObject {
    @Published public var cacheDirectory: URL

    private let cache: LRUCache<String, Any>
    private let totalBytesLimit: Int
    private let countLimit: Int
    private let inlineStorageThreshold: Int
    private let memoryThreshold: Int
    private let compressionThreshold: Int
    private let tracksPersistentAccess: Bool
    private let externalFilesDirectory: URL
    private let store: HybridSQLiteLRUStore?
    private let lock = NSRecursiveLock()
    private var lastAccessCounter: Int64 = 0
    private var pendingLastAccesses: [String: Int64] = [:]
    private var approximatePersistentEntryCount = 0
    private var approximatePersistentTotalCost = 0
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
        memoryThreshold: Int = 1_048_576,
        memoryTotalBytesLimit: Int? = nil,
        memoryCountLimit: Int? = nil,
        inlineStorageThreshold: Int = 256_000,
        compressionThreshold: Int = 200_000,
        cacheRootURL: URL? = nil
    ) {
        assert(!namespace.isEmpty, "PersistedLRUCache namespace must not be empty")

        self.totalBytesLimit = totalBytesLimit
        self.countLimit = countLimit
        self.inlineStorageThreshold = max(inlineStorageThreshold, 0)
        self.memoryThreshold = memoryThreshold
        self.compressionThreshold = compressionThreshold
        tracksPersistentAccess = countLimit != .max || totalBytesLimit != .max

        let fileManager = FileManager.default
        let cacheRoot = cacheRootURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDirectory = cacheRoot.appendingPathComponent("PersistedLRUCache").appendingPathComponent(namespace)
        let filesDirectory = cacheDirectory.appendingPathComponent("files", isDirectory: true)
        self.cacheDirectory = cacheDirectory
        externalFilesDirectory = filesDirectory
        cache = LRUCache(
            totalCostLimit: memoryTotalBytesLimit ?? min(totalBytesLimit, memoryThreshold),
            countLimit: memoryCountLimit ?? countLimit
        )

        let versionFileURL = cacheDirectory.appendingPathComponent("lru_cache_version.txt")
        let versionString = PersistedLRUCacheSupport.cacheVersionString(
            baseVersion: version.map(String.init) ?? PersistedLRUCacheSupport.bundleVersionString
        )
        let dbURL = cacheDirectory.appendingPathComponent("cache.sqlite")
        let removeFiles = { (fileNames: [String]) in
            for fileName in Set(fileNames) where !fileName.contains("/") && !fileName.contains("\\") {
                try? fileManager.removeItem(at: filesDirectory.appendingPathComponent(fileName))
            }
        }
        let resetFilesDirectory = {
            try? fileManager.removeItem(at: filesDirectory)
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        }

        do {
            try fileManager.createDirectory(at: externalFilesDirectory, withIntermediateDirectories: true)
            let store = try HybridSQLiteLRUStore(fileURL: dbURL)
            if let versionData = try? Data(contentsOf: versionFileURL),
               String(data: versionData, encoding: .utf8) != versionString {
                removeFiles(try store.removeAll())
                try resetFilesDirectory()
            } else if !fileManager.fileExists(atPath: versionFileURL.path) {
                removeFiles(try store.removeAll())
                try resetFilesDirectory()
            }

            try Data(versionString.utf8).write(to: versionFileURL)
            self.store = store
            lastAccessCounter = max(monotonicTime(), store.maximumLastAccess())
            if let stats = try? store.cacheStats() {
                approximatePersistentEntryCount = stats.count
                approximatePersistentTotalCost = stats.totalCost
            }
        } catch {
            print("Failed to initialize PersistedLRUCache store: \(error)")
            self.store = nil
        }
    }

    public func removeValue(forKey key: I) {
        guard let keyHash = cacheKeyHash(key) else { return }
        removeMemoryValue(forKeyHash: keyHash)
        discardPendingAccess(forKeyHash: keyHash)
        if let result = try? store?.removeByID(keyHash) {
            applyPersistentStatsDelta(result)
            removeExternalFiles(fileNames: result.obsoleteFileNames)
        }
    }

    public func removeAll() {
        lock.lock()
        cache.removeAll()
        pendingLastAccesses.removeAll(keepingCapacity: true)
        lock.unlock()

        if let fileNames = try? store?.removeAll() {
            removeExternalFiles(fileNames: fileNames)
        }
        resetPersistentStats(HybridCacheStats(count: 0, totalCost: 0))
        removeExternalFilesDirectory()
        try? FileManager.default.createDirectory(at: externalFilesDirectory, withIntermediateDirectories: true)
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

        guard let payload = payload(from: entry) else {
            removeValue(forKey: key)
            return nil
        }

        let decoded = try? PersistedLRUCacheCodec.decode(O.self, from: payload)
        if let decoded, payload.cost <= memoryThreshold {
            setMemoryValue(decoded, forKeyHash: keyHash, cost: payload.cost)
        }

        if tracksPersistentAccess {
            recordPersistentAccess(forKeyHash: keyHash)
        }
        return decoded ?? nil
    }

    public func setValue(_ value: O?, forKey key: I) {
        guard let keyHash = cacheKeyHash(key) else { return }

        let encoded: EncodedHybridValue
        do {
            encoded = try makeEncodedHybridValue(value, keyHash: keyHash)
        } catch {
            print("Encoding error: \(error)")
            return
        }

        let entry = HybridCacheEntry(
            id: keyHash,
            data: encoded.inlineData,
            fileName: encoded.fileName,
            encoding: encoded.payload.encoding,
            cost: encoded.payload.cost,
            lastAccess: nextLastAccess()
        )

        let result: HybridCacheMutationResult
        let evictedIDs: [String]
        do {
            if tracksPersistentAccess {
                result = try store?.upsert(
                    entry,
                    pendingAccesses: takePendingAccesses()
                ) ?? HybridCacheMutationResult()
            } else {
                result = try store?.upsert(entry) ?? HybridCacheMutationResult()
            }
            applyPersistentStatsDelta(result)
            removeExternalFiles(fileNames: result.obsoleteFileNames)
            let trimResult = trimPersistentStoreIfNeeded()
            removeExternalFiles(fileNames: trimResult.obsoleteFileNames)
            evictedIDs = result.evictedIDs + trimResult.evictedIDs
            removeMemoryValues(forKeyHashes: evictedIDs)
        } catch {
            removeExternalFiles(fileNames: encoded.newExternalFileNames)
            print("Persisted cache write error: \(error)")
            return
        }

        if evictedIDs.contains(keyHash) {
            removeMemoryValue(forKeyHash: keyHash)
        } else if let value, encoded.payload.cost <= memoryThreshold {
            setMemoryValue(value, forKeyHash: keyHash, cost: encoded.payload.cost)
        } else {
            removeMemoryValue(forKeyHash: keyHash)
        }
    }

    public func setValues(_ values: [(key: I, value: O?)]) {
        guard !values.isEmpty else { return }

        var encodedValues: [(keyHash: String, value: O?, encoded: EncodedHybridValue)] = []
        encodedValues.reserveCapacity(values.count)
        var memoryUpdates: [(keyHash: String, value: O, cost: Int)] = []
        memoryUpdates.reserveCapacity(values.count)
        var memoryRemovals: [String] = []
        memoryRemovals.reserveCapacity(values.count)
        var newExternalFileNames: [String] = []
        let encoder = jsonEncoder

        for (key, value) in values {
            guard let keyHash = cacheKeyHash(key) else { continue }

            let encoded: EncodedHybridValue
            do {
                encoded = try makeEncodedHybridValue(value, keyHash: keyHash, encoder: encoder)
            } catch {
                print("Encoding error: \(error)")
                continue
            }

            encodedValues.append((keyHash, value, encoded))
            newExternalFileNames.append(contentsOf: encoded.newExternalFileNames)

            if let value, encoded.payload.cost <= memoryThreshold {
                memoryUpdates.append((keyHash, value, encoded.payload.cost))
            } else {
                memoryRemovals.append(keyHash)
            }
        }

        guard !encodedValues.isEmpty else { return }

        let lastAccesses = nextLastAccesses(count: encodedValues.count)
        var entries: [HybridCacheEntry] = []
        entries.reserveCapacity(encodedValues.count)
        for (offset, encodedValue) in encodedValues.enumerated() {
            entries.append(
                HybridCacheEntry(
                    id: encodedValue.keyHash,
                    data: encodedValue.encoded.inlineData,
                    fileName: encodedValue.encoded.fileName,
                    encoding: encodedValue.encoded.payload.encoding,
                    cost: encodedValue.encoded.payload.cost,
                    lastAccess: lastAccesses[offset]
                )
            )
        }

        let result: HybridCacheMutationResult
        let evictedIDs: [String]
        do {
            if tracksPersistentAccess {
                result = try store?.upsert(
                    entries,
                    pendingAccesses: takePendingAccesses()
                ) ?? HybridCacheMutationResult()
            } else {
                result = try store?.upsert(entries) ?? HybridCacheMutationResult()
            }
            applyPersistentStatsDelta(result)
            removeExternalFiles(fileNames: result.obsoleteFileNames)
            let trimResult = trimPersistentStoreIfNeeded()
            removeExternalFiles(fileNames: trimResult.obsoleteFileNames)
            evictedIDs = result.evictedIDs + trimResult.evictedIDs
        } catch {
            removeExternalFiles(fileNames: newExternalFileNames)
            print("Persisted cache write error: \(error)")
            return
        }

        updateMemoryValues(memoryUpdates, removing: memoryRemovals + evictedIDs)
    }

    public func debugKeyHash(for key: I) -> String? {
        cacheKeyHash(key)
    }

    public func debugDiskEntryURL(for key: I) -> URL? {
        guard let keyHash = cacheKeyHash(key),
              let store,
              let fileName = try? store.fileName(id: keyHash)
        else {
            return nil
        }
        return externalFileURL(forFileName: fileName)
    }

    private func applyPersistentStatsDelta(_ result: HybridCacheMutationResult) {
        guard tracksPersistentAccess else { return }

        lock.lock()
        approximatePersistentEntryCount = max(0, approximatePersistentEntryCount + result.itemCountDelta)
        approximatePersistentTotalCost = max(0, approximatePersistentTotalCost + result.totalCostDelta)
        lock.unlock()
    }

    private func resetPersistentStats(_ stats: HybridCacheStats) {
        lock.lock()
        approximatePersistentEntryCount = max(0, stats.count)
        approximatePersistentTotalCost = max(0, stats.totalCost)
        lock.unlock()
    }

    private func trimPersistentStoreIfNeeded() -> HybridCacheMutationResult {
        guard tracksPersistentAccess, shouldTrimPersistentStore(), let store else {
            return HybridCacheMutationResult()
        }

        do {
            let result = try store.trim(countLimit: countLimit, totalBytesLimit: totalBytesLimit)
            let stats = try store.cacheStats()
            resetPersistentStats(stats)
            return result
        } catch {
            print("Persisted cache trim error: \(error)")
            return HybridCacheMutationResult()
        }
    }

    private func shouldTrimPersistentStore() -> Bool {
        lock.lock()
        let count = approximatePersistentEntryCount
        let totalCost = approximatePersistentTotalCost
        lock.unlock()

        if countLimit != .max, count > countLimit + persistentCountTrimSlack {
            return true
        }
        if totalBytesLimit != .max, totalCost > totalBytesLimit + persistentCostTrimSlack {
            return true
        }
        return false
    }

    private var persistentCountTrimSlack: Int {
        guard countLimit != .max, countLimit >= 64 else { return 0 }
        return min(max(countLimit / 16, 64), 8_192)
    }

    private var persistentCostTrimSlack: Int {
        guard totalBytesLimit != .max, totalBytesLimit >= 1_048_576 else { return 0 }
        return min(max(totalBytesLimit / 16, 4_194_304), 67_108_864)
    }

    private struct EncodedHybridValue {
        var payload: PersistedLRUCachePayload
        var inlineData: Data?
        var fileName: String?
        var newExternalFileNames: [String]
    }

    private func makeEncodedHybridValue(
        _ value: O?,
        keyHash: String,
        encoder: JSONEncoder? = nil
    ) throws -> EncodedHybridValue {
        let payload = try PersistedLRUCacheCodec.encode(
            value,
            compressionThreshold: compressionThreshold,
            encoder: encoder ?? jsonEncoder
        )

        guard let data = payload.data, data.count > inlineStorageThreshold else {
            return EncodedHybridValue(
                payload: payload,
                inlineData: payload.data,
                fileName: nil,
                newExternalFileNames: []
            )
        }

        let fileName = externalFileName(forKeyHash: keyHash, encoding: payload.encoding)
        let fileURL = externalFileURL(forFileName: fileName)
        try FileManager.default.createDirectory(at: externalFilesDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return EncodedHybridValue(
            payload: payload,
            inlineData: nil,
            fileName: fileName,
            newExternalFileNames: [fileName]
        )
    }

    private func cacheKeyHash(_ key: I) -> String? {
        PersistedLRUCacheSupport.cacheKeyHash(key)
    }

    private func payload(from entry: HybridCacheValue) -> PersistedLRUCachePayload? {
        if let fileName = entry.fileName {
            guard let data = try? Data(contentsOf: externalFileURL(forFileName: fileName)) else {
                return nil
            }
            return PersistedLRUCachePayload(data: data, encoding: entry.encoding)
        }

        return PersistedLRUCachePayload(data: entry.data, encoding: entry.encoding)
    }

    private func externalFileName(forKeyHash keyHash: String, encoding: String) -> String {
        keyHash + "." + fileExtension(forEncoding: encoding)
    }

    private func externalFileURL(forFileName fileName: String) -> URL {
        externalFilesDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func removeExternalFiles(fileNames: [String]) {
        guard !fileNames.isEmpty else { return }
        let fileManager = FileManager.default
        for fileName in Set(fileNames) where !fileName.contains("/") && !fileName.contains("\\") {
            try? fileManager.removeItem(at: externalFileURL(forFileName: fileName))
        }
    }

    private func removeExternalFilesDirectory() {
        try? FileManager.default.removeItem(at: externalFilesDirectory)
    }

    private func fileExtension(forEncoding encoding: String) -> String {
        switch encoding {
        case "json.lz4":
            return "json-lz4"
        default:
            return encoding
        }
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
