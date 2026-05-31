# PersistedLRUCache

Persisted LRU caches for Swift apps.

## Products

- `PersistedLRUCache`: hybrid cache that stores metadata and small values in SQLite, with large values stored as files.
- `PersistedLRUFileCache`: legacy file-per-value cache with an in-memory LRU front cache.
- `PersistedLRUSQLiteCache`: SQLite-only cache with an in-memory LRU front cache.

These caches support iOS 15+ and macOS 15+.

## Usage

```swift
import PersistedLRUCacheHybrid

let cache = PersistedLRUCache<String, Data>(
    namespace: "reader-content",
    totalBytesLimit: 100_000_000,
    countLimit: 10_000,
    inlineStorageThreshold: 256_000
)

cache.setValue(data, forKey: "article-1")
let data = cache.value(forKey: "article-1")
```

For bulk cache hydration, use `setValues(_:)` to persist a batch in one SQLite transaction:

```swift
cache.setValues(articles.map { (key: $0.id, value: $0.data) })
```

Use `memoryTotalBytesLimit` and `memoryCountLimit` when the persisted LRU limits should be larger than the in-memory front cache.
Use `inlineStorageThreshold` to choose when encoded values move out of SQLite and into external files managed by the same LRU metadata.

## Development

```sh
swift test
swift run -c release PersistedLRUCacheBenchmark
```

## License

MIT.
