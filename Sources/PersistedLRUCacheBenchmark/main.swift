import Foundation
import PersistedLRUFileCache
import PersistedLRUSQLiteCache

private struct Payload: Codable, Equatable {
    var id: Int
    var title: String
    var body: String
    var values: [Int]
}

@main
enum PersistedLRUCacheBenchmark {
    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedLRUCacheBenchmark")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let smallPayloads = (0..<2_000).map { index in
            Payload(
                id: index,
                title: "payload-\(index)",
                body: String(repeating: "x", count: 256),
                values: Array(0..<16)
            )
        }

        let largePayloads = (0..<250).map { index in
            Payload(
                id: index,
                title: "large-payload-\(index)",
                body: String(repeating: "large-body-\(index)", count: 2_000),
                values: Array(0..<128)
            )
        }

        benchmarkSQLite(root: root, payloads: smallPayloads, label: "sqlite small", compressionThreshold: 200_000)
        benchmarkSQLite(root: root, payloads: largePayloads, label: "sqlite large compressed", compressionThreshold: 20_000)
        benchmarkFile(root: root, payloads: smallPayloads, label: "file small", compressionThreshold: 200_000)
    }

    private static func benchmarkSQLite(
        root: URL,
        payloads: [Payload],
        label: String,
        compressionThreshold: Int
    ) {
        let namespace = "bench.sqlite.\(UUID().uuidString)"
        let cache = LRUSQLiteCache<Int, Payload>(
            namespace: namespace,
            countLimit: .max,
            memoryCountLimit: 512,
            compressionThreshold: compressionThreshold,
            cacheRootURL: root
        )

        measure("\(label) writes", operations: payloads.count) {
            for payload in payloads {
                cache.setValue(payload, forKey: payload.id)
            }
        }

        measure("\(label) hot reads", operations: payloads.count) {
            for payload in payloads {
                _ = cache.value(forKey: payload.id)
            }
        }

        let reloaded = LRUSQLiteCache<Int, Payload>(
            namespace: namespace,
            countLimit: .max,
            memoryCountLimit: 512,
            compressionThreshold: compressionThreshold,
            cacheRootURL: root
        )

        measure("\(label) persisted reads", operations: payloads.count) {
            for payload in payloads {
                _ = reloaded.value(forKey: payload.id)
            }
        }
    }

    private static func benchmarkFile(
        root: URL,
        payloads: [Payload],
        label: String,
        compressionThreshold: Int
    ) {
        let namespace = "bench.file.\(UUID().uuidString)"
        let cache = LRUFileCache<Int, Payload>(
            namespace: namespace,
            countLimit: 512,
            compressionThreshold: compressionThreshold,
            cacheRootURL: root
        )

        measure("\(label) writes", operations: payloads.count) {
            for payload in payloads {
                cache.setValue(payload, forKey: payload.id)
            }
        }

        measure("\(label) reads", operations: payloads.count) {
            for payload in payloads {
                _ = cache.value(forKey: payload.id)
            }
        }
    }

    private static func measure(_ label: String, operations: Int, block: () -> Void) {
        let start = Date()
        block()
        let elapsed = Date().timeIntervalSince(start)
        let operationsPerSecond = elapsed > 0 ? Double(operations) / elapsed : 0
        print("\(label): \(String(format: "%.3f", elapsed))s, \(Int(operationsPerSecond)) ops/s")
    }
}
