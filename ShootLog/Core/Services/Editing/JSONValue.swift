import Foundation

/// 任意の JSON 値を型付きで保持する汎用値型。
///
/// Swift 標準ライブラリには `AnyCodable` 相当が無く、`Decoder` から「未知キー配下の生バイト列」を
/// 取り出す API も無い。`MaskSource.unrecognized` が未知のマスク種別のペイロードを失わずに
/// 再エンコードするために、JSON の構造をそのまま値として持ち回る。
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Bool は Double より先に試す（JSONDecoder は true/false を Double として読まないが、
        // 逆順にすると将来の実装差で数値が Bool へ吸われる余地を残すため）。
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "JSON として解釈できない値です"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
