import Foundation

package enum PersistedLRUCacheSupport {
    package static func cacheVersionString(baseVersion version: String) -> String {
        #if DEBUG
        return version + "-debug-build-" + bundleBuild
        #else
        return version
        #endif
    }

    package static var bundleVersionString: String {
        let appVersion = bundleInfo("CFBundleShortVersionString")
        let build = bundleInfo("CFBundleVersion")
        return appVersion + "-" + build
    }

    package static var bundleBuild: String {
        bundleInfo("CFBundleVersion")
    }

    package static func cacheKeyHash<I: Encodable>(_ key: I, encoder: JSONEncoder) -> String? {
        guard let data = try? encoder.encode(key) else { return nil }
        let hash = stableHash(data)
        var hashData = withUnsafeBytes(of: hash) { Data($0) }
        while hashData.first == 0 { hashData.removeFirst() }
        if hashData.isEmpty {
            return "0"
        }

        let base64 = hashData.base64EncodedString()
        var output = [UInt8]()
        output.reserveCapacity(base64.utf8.count)

        for byte in base64.utf8 {
            switch byte {
            case UInt8(ascii: "+"): output.append(UInt8(ascii: "-"))
            case UInt8(ascii: "/"): output.append(UInt8(ascii: "_"))
            case UInt8(ascii: "="): break
            default: output.append(byte)
            }
        }

        return String(decoding: output, as: UTF8.self)
    }

    package static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func bundleInfo(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "UNKNOWN-VERSION"
    }

    private static func stableHash(_ data: Data) -> UInt64 {
        let mask: UInt64 = 0x00ff_ffff_ffff_ffff
        var result: UInt64 = 5381
        data.withUnsafeBytes { raw in
            for byte in raw {
                result = (result & mask) * 127 + UInt64(byte)
            }
        }
        return result
    }
}
