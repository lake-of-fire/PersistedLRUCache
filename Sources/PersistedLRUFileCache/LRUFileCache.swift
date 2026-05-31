import Combine
import Foundation
import LRUCache
import PersistedLRUCacheCore

/// A disk-persisted cache with an in-memory LRU front cache.
///
/// Values are stored as individual files in the system cache directory. Small
/// values are also kept in memory; large values remain disk-only and are loaded
/// on demand.
open class LRUFileCache<I: Encodable, O: Codable>: ObservableObject {
    @Published public var cacheDirectory: URL

    private let cache: LRUCache<String, Any?>
    private let memoryThreshold: Int
    private let compressionThreshold: Int
    private var diskOnlyKeys: Set<String> = []

    private var jsonEncoder: JSONEncoder {
        PersistedLRUCacheSupport.jsonEncoder()
    }

    public init(
        namespace: String,
        version: Int? = nil,
        totalBytesLimit: Int = .max,
        countLimit: Int = .max,
        memoryThreshold: Int = 1_048_576,
        compressionThreshold: Int = 20_000,
        cacheRootURL: URL? = nil
    ) {
        assert(!namespace.isEmpty, "LRUFileCache namespace must not be empty")

        self.memoryThreshold = memoryThreshold
        self.compressionThreshold = compressionThreshold

        let fileManager = FileManager.default
        let cacheRoot = cacheRootURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDirectory = cacheRoot.appendingPathComponent("LRUFileCache").appendingPathComponent(namespace)
        self.cacheDirectory = cacheDirectory

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        cache = LRUCache(totalCostLimit: totalBytesLimit, countLimit: countLimit)

        let versionFileURL = cacheRoot.appendingPathComponent("lru-cache-version-\(namespace).txt")
        let versionString = PersistedLRUCacheSupport.cacheVersionString(
            baseVersion: version.map(String.init) ?? PersistedLRUCacheSupport.bundleVersionString
        )

        if let versionData = try? Data(contentsOf: versionFileURL),
           String(data: versionData, encoding: .utf8) != versionString {
            removeAll()
            try? fileManager.removeItem(at: cacheDirectory)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } else if !fileManager.fileExists(atPath: versionFileURL.path) {
            try? fileManager.removeItem(at: cacheDirectory)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        try? Data(versionString.utf8).write(to: versionFileURL)

        rebuild()
    }

    public func removeValue(forKey key: I) {
        guard let keyHash = cacheKeyHash(key) else { return }
        cache.removeValue(forKey: keyHash)
        removeFiles(forKeyHash: keyHash)
        diskOnlyKeys.remove(keyHash)
    }

    public func removeAll() {
        cache.removeAll()
        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                try? fileManager.removeItem(at: file)
            }
        }
        diskOnlyKeys.removeAll()
    }

    public func hasKey(_ key: I) -> Bool {
        guard let keyHash = cacheKeyHash(key) else { return false }
        return cache.hasValue(forKey: keyHash) || diskOnlyKeys.contains(keyHash) || fileURL(forKeyHash: keyHash) != nil
    }

    public func containsKey(_ key: I) -> Bool {
        hasKey(key)
    }

    public func value(forKey key: I) -> O? {
        guard let keyHash = cacheKeyHash(key) else { return nil }

        if let cached = cache.value(forKey: keyHash) as? O {
            return cached
        }

        guard let fileURL = fileURL(forKeyHash: keyHash) else {
            diskOnlyKeys.remove(keyHash)
            return nil
        }

        let payload = payload(from: fileURL)
        guard let decoded = try? PersistedLRUCacheCodec.decode(O.self, from: payload) else {
            return nil
        }

        if payload.cost <= memoryThreshold {
            cache.setValue(decoded, forKey: keyHash, cost: payload.cost)
            diskOnlyKeys.remove(keyHash)
        } else {
            diskOnlyKeys.insert(keyHash)
        }

        return decoded
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

        if let value, payload.cost <= memoryThreshold {
            cache.setValue(value, forKey: keyHash, cost: payload.cost)
            diskOnlyKeys.remove(keyHash)
        } else {
            cache.removeValue(forKey: keyHash)
            diskOnlyKeys.insert(keyHash)
        }

        removeFiles(forKeyHash: keyHash)

        let fileURL = cacheDirectory
            .appendingPathComponent(keyHash)
            .appendingPathExtension(fileExtension(forEncoding: payload.encoding))

        if let data = payload.data {
            try? data.write(to: fileURL, options: .atomic)
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private func rebuild() {
        cache.removeAll()
        diskOnlyKeys.removeAll()

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        for file in files {
            let keyHash = keyHash(from: file)
            let payload = payload(from: file)

            if payload.cost <= memoryThreshold,
               let decoded = try? PersistedLRUCacheCodec.decode(O.self, from: payload) {
                cache.setValue(decoded, forKey: keyHash, cost: payload.cost)
                diskOnlyKeys.remove(keyHash)
            } else {
                diskOnlyKeys.insert(keyHash)
            }
        }
    }

    private func cacheKeyHash(_ key: I) -> String? {
        PersistedLRUCacheSupport.cacheKeyHash(key)
    }

    private func fileURL(forKeyHash keyHash: String) -> URL? {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }

        return files.first { keyHashFromFilename($0) == keyHash }
    }

    private func removeFiles(forKeyHash keyHash: String) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files where keyHashFromFilename(file) == keyHash {
            try? fileManager.removeItem(at: file)
        }
    }

    private func payload(from fileURL: URL) -> PersistedLRUCachePayload {
        let encoding = encoding(fromFileExtension: fileURL.pathExtension)
        guard encoding != "nil" else {
            return PersistedLRUCachePayload(data: nil, encoding: encoding)
        }

        return PersistedLRUCachePayload(data: try? Data(contentsOf: fileURL), encoding: encoding)
    }

    private func keyHash(from fileURL: URL) -> String {
        keyHashFromFilename(fileURL)
    }

    private func keyHashFromFilename(_ fileURL: URL) -> String {
        var name = fileURL.lastPathComponent
        for suffix in [".json-lz4", ".json.lz4", ".raw", ".lz4", ".json", ".nil"] {
            if name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
                return name
            }
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private func fileExtension(forEncoding encoding: String) -> String {
        switch encoding {
        case "json.lz4":
            return "json-lz4"
        default:
            return encoding
        }
    }

    private func encoding(fromFileExtension fileExtension: String) -> String {
        switch fileExtension {
        case "json-lz4":
            return "json.lz4"
        default:
            return fileExtension
        }
    }
}
