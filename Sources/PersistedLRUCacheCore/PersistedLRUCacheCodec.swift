import Foundation

package struct PersistedLRUCachePayload: Sendable, Equatable {
    package var data: Data?
    package var encoding: String
    package var cost: Int

    package init(data: Data?, encoding: String) {
        self.data = data
        self.encoding = encoding
        self.cost = max(data?.count ?? 1, 1)
    }
}

package enum PersistedLRUCacheCodec {
    package static func encode<Value: Codable>(
        _ value: Value?,
        compressionThreshold: Int,
        encoder: JSONEncoder
    ) throws -> PersistedLRUCachePayload {
        guard let value else {
            return PersistedLRUCachePayload(data: nil, encoding: "nil")
        }

        if let uint8Array = value as? [UInt8] {
            return try rawPayload(Data(uint8Array), compressionThreshold: compressionThreshold)
        }

        if let stringValue = value as? String {
            return try rawPayload(Data(stringValue.utf8), compressionThreshold: compressionThreshold)
        }

        if let dataValue = value as? Data {
            return try rawPayload(dataValue, compressionThreshold: compressionThreshold)
        }

        let rawData = try encoder.encode(value)
        if rawData.count > compressionThreshold {
            let compressed = try (rawData as NSData).compressed(using: .lz4) as Data
            return PersistedLRUCachePayload(data: compressed, encoding: "json.lz4")
        }

        return PersistedLRUCachePayload(data: rawData, encoding: "json")
    }

    package static func decode<Value: Codable>(
        _ type: Value.Type,
        from payload: PersistedLRUCachePayload,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value? {
        let encoding = normalizedEncoding(payload.encoding)
        if encoding == "nil" {
            guard payload.data == nil else {
                throw PersistedLRUCacheCodecError.unexpectedDataForNil
            }
            return nil
        }

        guard let data = payload.data else {
            throw PersistedLRUCacheCodecError.missingData(encoding: encoding)
        }

        switch encoding {
        case "raw":
            return try decodeRaw(type, data: data)
        case "lz4":
            let decompressed = try (data as NSData).decompressed(using: .lz4) as Data
            return try decodeRaw(type, data: decompressed)
        case "json":
            return try decoder.decode(type, from: data)
        case "json.lz4":
            let decompressed = try (data as NSData).decompressed(using: .lz4) as Data
            return try decoder.decode(type, from: decompressed)
        default:
            throw PersistedLRUCacheCodecError.unsupportedEncoding(encoding)
        }
    }

    private static func rawPayload(
        _ rawData: Data,
        compressionThreshold: Int
    ) throws -> PersistedLRUCachePayload {
        if rawData.count > compressionThreshold {
            let compressed = try (rawData as NSData).compressed(using: .lz4) as Data
            return PersistedLRUCachePayload(data: compressed, encoding: "lz4")
        }

        return PersistedLRUCachePayload(data: rawData, encoding: "raw")
    }

    private static func decodeRaw<Value: Codable>(_ type: Value.Type, data: Data) throws -> Value {
        if type == String.self {
            guard let value = String(data: data, encoding: .utf8) as? Value else {
                throw PersistedLRUCacheCodecError.invalidRawValue
            }
            return value
        }

        if type == [UInt8].self {
            guard let value = [UInt8](data) as? Value else {
                throw PersistedLRUCacheCodecError.invalidRawValue
            }
            return value
        }

        if type == Data.self {
            guard let value = data as? Value else {
                throw PersistedLRUCacheCodecError.invalidRawValue
            }
            return value
        }

        throw PersistedLRUCacheCodecError.unsupportedRawType
    }

    private static func normalizedEncoding(_ encoding: String) -> String {
        switch encoding {
        case "json-lz4":
            return "json.lz4"
        default:
            return encoding
        }
    }
}

package enum PersistedLRUCacheCodecError: Error, Equatable, Sendable {
    case missingData(encoding: String)
    case unexpectedDataForNil
    case unsupportedEncoding(String)
    case unsupportedRawType
    case invalidRawValue
}
