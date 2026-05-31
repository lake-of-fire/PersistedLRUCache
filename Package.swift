// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PersistedLRUCache",
    platforms: [
        .iOS(.v15),
        .macOS("15.0"),
    ],
    products: [
        .library(
            name: "PersistedLRUCache",
            targets: ["PersistedLRUCache"]
        ),
        .library(
            name: "PersistedLRUFileCache",
            targets: ["PersistedLRUFileCache"]
        ),
        .library(
            name: "PersistedLRUSQLiteCache",
            targets: ["PersistedLRUSQLiteCache"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/LRUCache.git", from: "1.1.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
    ],
    targets: [
        .target(name: "PersistedLRUCacheCore"),
        .target(
            name: "PersistedLRUFileCache",
            dependencies: [
                "PersistedLRUCacheCore",
                .product(name: "LRUCache", package: "LRUCache"),
            ]
        ),
        .target(
            name: "PersistedLRUSQLiteCache",
            dependencies: [
                "PersistedLRUCacheCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "LRUCache", package: "LRUCache"),
            ]
        ),
        .target(
            name: "PersistedLRUCache",
            dependencies: [
                "PersistedLRUFileCache",
                "PersistedLRUSQLiteCache",
            ]
        ),
        .testTarget(
            name: "PersistedLRUFileCacheTests",
            dependencies: ["PersistedLRUFileCache"]
        ),
        .testTarget(
            name: "PersistedLRUCacheCoreTests",
            dependencies: ["PersistedLRUCacheCore"]
        ),
        .testTarget(
            name: "PersistedLRUSQLiteCacheTests",
            dependencies: ["PersistedLRUSQLiteCache"]
        ),
        .executableTarget(
            name: "PersistedLRUCacheBenchmark",
            dependencies: [
                "PersistedLRUFileCache",
                "PersistedLRUSQLiteCache",
            ]
        ),
    ]
)
