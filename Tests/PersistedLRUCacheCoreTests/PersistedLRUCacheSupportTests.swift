import Foundation
@testable import PersistedLRUCacheCore
import XCTest

final class PersistedLRUCacheSupportTests: XCTestCase {
    func testCacheKeyFastPathsMatchPackageJSONEncoderHashing() throws {
        try assertFastHashMatchesJSONEncoder("plain")
        try assertFastHashMatchesJSONEncoder("https://example.com/path/to/file?q=1")
        try assertFastHashMatchesJSONEncoder("quote\"and\\backslash")
        try assertFastHashMatchesJSONEncoder("日本語")
        try assertFastHashMatchesJSONEncoder(URL(string: "https://example.com/path/to/file?q=1")!)
        try assertFastHashMatchesJSONEncoder(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!)
        try assertFastHashMatchesJSONEncoder(true)
        try assertFastHashMatchesJSONEncoder(false)
        try assertFastHashMatchesJSONEncoder(Int.min)
        try assertFastHashMatchesJSONEncoder(Int.max)
        try assertFastHashMatchesJSONEncoder(UInt.max)
        try assertFastHashMatchesJSONEncoder(Int8.min)
        try assertFastHashMatchesJSONEncoder(UInt8.max)
        try assertFastHashMatchesJSONEncoder(Int16.min)
        try assertFastHashMatchesJSONEncoder(UInt16.max)
        try assertFastHashMatchesJSONEncoder(Int32.min)
        try assertFastHashMatchesJSONEncoder(UInt32.max)
        try assertFastHashMatchesJSONEncoder(Int64.min)
        try assertFastHashMatchesJSONEncoder(UInt64.max)
    }

    func testCacheKeyHashFallsBackToJSONEncoderForControlCharacters() throws {
        try assertFastHashMatchesJSONEncoder("line\nbreak")
    }

    private func assertFastHashMatchesJSONEncoder<I: Encodable>(
        _ key: I,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encodedData = try PersistedLRUCacheSupport.jsonEncoder().encode(key)

        XCTAssertEqual(
            PersistedLRUCacheSupport.cacheKeyHash(key),
            PersistedLRUCacheSupport.cacheKeyHash(encodedData: encodedData),
            file: file,
            line: line
        )
    }
}
