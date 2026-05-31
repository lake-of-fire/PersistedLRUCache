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

    package static func cacheKeyHash<I: Encodable>(_ key: I) -> String? {
        cacheKeyHash(key) {
            jsonEncoder()
        }
    }

    package static func cacheKeyHash<I: Encodable>(_ key: I, encoder: JSONEncoder) -> String? {
        cacheKeyHash(key) {
            encoder
        }
    }

    private static func cacheKeyHash<I: Encodable>(_ key: I, makeEncoder: () -> JSONEncoder) -> String? {
        let data: Data
        if let fastData = fastJSONEncodedKeyData(key) {
            data = fastData
        } else if let encodedData = try? makeEncoder().encode(key) {
            data = encodedData
        } else {
            return nil
        }

        return cacheKeyHash(encodedData: data)
    }

    package static func cacheKeyHash(encodedData data: Data) -> String {
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

    private static func fastJSONEncodedKeyData<I: Encodable>(_ key: I) -> Data? {
        switch key {
        case let value as String:
            return fastJSONStringData(value)
        case let value as URL:
            return fastJSONStringData(value.absoluteString)
        case let value as UUID:
            return fastJSONStringData(value.uuidString)
        case let value as Bool:
            return Data(value ? "true".utf8 : "false".utf8)
        case let value as Int:
            return Data(String(value).utf8)
        case let value as Int8:
            return Data(String(value).utf8)
        case let value as Int16:
            return Data(String(value).utf8)
        case let value as Int32:
            return Data(String(value).utf8)
        case let value as Int64:
            return Data(String(value).utf8)
        case let value as UInt:
            return Data(String(value).utf8)
        case let value as UInt8:
            return Data(String(value).utf8)
        case let value as UInt16:
            return Data(String(value).utf8)
        case let value as UInt32:
            return Data(String(value).utf8)
        case let value as UInt64:
            return Data(String(value).utf8)
        default:
            return nil
        }
    }

    private static func fastJSONStringData(_ value: String) -> Data? {
        var output = [UInt8]()
        output.reserveCapacity(value.utf8.count + 2)
        output.append(UInt8(ascii: "\""))

        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                output.append(UInt8(ascii: "\\"))
                output.append(byte)
            case 0x00...0x1f:
                return nil
            default:
                output.append(byte)
            }
        }

        output.append(UInt8(ascii: "\""))
        return Data(output)
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
