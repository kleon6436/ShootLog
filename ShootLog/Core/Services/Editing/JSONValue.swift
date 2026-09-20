import Foundation

/// 任意の JSON 値を型付きで保持する汎用値型。
///
/// Swift 標準ライブラリには `AnyCodable` 相当が無く、`Decoder` から「未知キー配下の生バイト列」を
/// 取り出す API も無い。`MaskSource.unrecognized` が未知のマスク種別のペイロードを失わずに
/// 再エンコードするために、JSON の構造をそのまま値として持ち回る。
///
/// 数値は常に `Double` として保持するため、2^53 を超える精度が必要な整数（例: ナノ秒
/// タイムスタンプ）が含まれる場合は精度が丸められる。現時点で `MaskSource` の未知ペイロードに
/// そのような値は存在しないが、「失わずに再エンコードする」という保証は数値の整数精度には及ばない。
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
