import Logging
import PostgresNIO

extension Logger.Metadata: @retroactive PostgresThrowingDynamicTypeEncodable {
    public var psqlType: PostgresNIO.PostgresDataType {
        .jsonb
    }

    public var psqlFormat: PostgresNIO.PostgresFormat {
        .binary
    }

    public func encode<JSONEncoder>(into byteBuffer: inout NIOCore.ByteBuffer, context: PostgresNIO.PostgresEncodingContext<JSONEncoder>) throws
    where JSONEncoder: PostgresNIO.PostgresJSONEncoder {
        let JSONBVersionByte: UInt8 = 0x01
        byteBuffer.writeInteger(JSONBVersionByte)
        try context.jsonEncoder.encode(self, into: &byteBuffer)
    }
}

extension Logger.Metadata: @retroactive PostgresDecodable {}

// Implement this
extension Logger.MetadataValue: Codable, PostgresCodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .stringConvertible(let convertible):
            try container.encode(convertible.description)
        case .dictionary(let dictionary):
            try container.encode(dictionary)
        case .array(let array):
            try container.encode(array)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let dictionary = try? container.decode(Logger.Metadata.self) {
            self = .dictionary(dictionary)
        } else if let array = try? container.decode([Logger.MetadataValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode MetadataValue")
        }
    }
}
