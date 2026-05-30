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
        guard let data = payload.data else {
            return nil
        }

        switch normalizedEncoding(payload.encoding) {
        case "raw":
            return decodeRaw(type, data: data)
        case "lz4":
            let decompressed = try (data as NSData).decompressed(using: .lz4) as Data
            return decodeRaw(type, data: decompressed)
        case "json":
            return try decoder.decode(type, from: data)
        case "json.lz4":
            let decompressed = try (data as NSData).decompressed(using: .lz4) as Data
            return try decoder.decode(type, from: decompressed)
        case "nil":
            return nil
        default:
            return nil
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

    private static func decodeRaw<Value: Codable>(_ type: Value.Type, data: Data) -> Value? {
        if type == String.self {
            return String(data: data, encoding: .utf8) as? Value
        }

        if type == [UInt8].self {
            return [UInt8](data) as? Value
        }

        if type == Data.self {
            return data as? Value
        }

        return nil
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
