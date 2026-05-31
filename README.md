# PersistedLRUCache

Persisted LRU caches for Swift apps.

## Products

- `PersistedLRUFileCache`: stores values as files with an in-memory LRU front cache.
- `PersistedLRUSQLiteCache`: stores values in SQLite with an in-memory LRU front cache.
- `PersistedLRUCache`: umbrella product that re-exports both cache products.

Both caches support iOS 15+ and macOS 15+.

## Usage

```swift
import PersistedLRUSQLiteCache

let cache = LRUSQLiteCache<String, Data>(
    namespace: "reader-content",
    totalBytesLimit: 100_000_000,
    countLimit: 10_000
)

cache.setValue(data, forKey: "article-1")
let data = cache.value(forKey: "article-1")
```

Use `memoryTotalBytesLimit` and `memoryCountLimit` when the persisted LRU limits should be larger than the in-memory front cache.

## Development

```sh
swift test
swift run -c release PersistedLRUCacheBenchmark
```

## License

MIT.
