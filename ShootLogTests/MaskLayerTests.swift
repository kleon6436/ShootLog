import Foundation
import Testing

@testable import ShootLog

/// マスク（ローカル調整）の永続化。`DevelopParameters` は `encode(to:)` が合成・`init(from:)` が
/// 手書きという非対称構成で、`masks` の取りこぼしをコンパイラが検出できないため往復で担保する。
struct MaskLayerPersistenceTests {

    private func makeAdjustments() -> LocalAdjustments {
        var adjustments = LocalAdjustments()
        adjustments.exposure = 0.5
        adjustments.contrast = 10
        adjustments.highlights = -20
        adjustments.shadows = 30
        adjustments.whites = -5
        adjustments.blacks = 15
        adjustments.saturation = 25
        adjustments.vibrance = -35
        adjustments.clarity = 40
        adjustments.structure = -45
        adjustments.sharpness = 55
        adjustments.luminanceNoiseReduction = 60
        adjustments.colorNoiseReduction = -65
        adjustments.temperature = 70
        adjustments.tint = -75
        return adjustments
    }

    private func makeMaskedParameters() -> DevelopParameters {
        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.25
        parameters.saturation = -20

        let linear = MaskLayer(
            id: UUID(),
            name: "linear",
            source: .linearGradient(
                LinearGradientMask(
                    start: NormalizedPoint(x: 0.1, y: 0.2),
                    end: NormalizedPoint(x: 0.8, y: 0.9)
                )
            ),
            isInverted: true,
            density: 80,
            feather: 25,
            adjustments: makeAdjustments()
        )

        let radial = MaskLayer(
            id: UUID(),
            name: "radial",
            source: .radialGradient(
                RadialGradientMask(
                    center: NormalizedPoint(x: 0.5, y: 0.4),
                    radius: 0.3,
                    aspectRatio: 1.5,
                    rotationDegrees: 30,
                    falloff: 0.6
                )
            ),
            isEnabled: false,
            adjustments: makeAdjustments()
        )

        let brushed = MaskLayer(
            id: UUID(),
            name: "brush",
            source: .none,
            brushEdits: [
                BrushStroke(
                    points: [BrushPoint(x: 0.1, y: 0.1), BrushPoint(x: 0.2, y: 0.25)],
                    radius: 0.05, hardness: 70, opacity: 90, isEraser: false
                ),
                BrushStroke(
                    points: [BrushPoint(x: 0.6, y: 0.7)],
                    radius: 0.02, hardness: 10, opacity: 50, isEraser: true
                )
            ],
            adjustments: makeAdjustments()
        )

        parameters.masks = [linear, radial, brushed]
        return parameters
    }

    /// JSONValue へ一度落としてから任意のキーを取り除いた JSON を作る。
    private func jsonValue(of parameters: DevelopParameters) throws -> JSONValue {
        let data = try JSONEncoder().encode(parameters)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func decodeParameters(_ value: JSONValue) throws -> DevelopParameters {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(DevelopParameters.self, from: data)
    }

    @Test func maskedParametersRoundTripThroughJSON() throws {
        let original = makeMaskedParameters()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DevelopParameters.self, from: data)

        #expect(decoded == original)
        #expect(decoded.masks.count == 3)
        #expect(decoded.masks[0].source == original.masks[0].source)
        #expect(decoded.masks[1].isEnabled == false)
        #expect(decoded.masks[2].brushEdits.count == 2)
        #expect(decoded.masks[2].adjustments == original.masks[2].adjustments)
    }

    @Test func blobWithoutMasksKeyDecodesToEmptyMasksAndKeepsOtherFields() throws {
        var original = makeMaskedParameters()
        original.contrast = -30
        original.lensDistortion = 12

        guard case .object(var root) = try jsonValue(of: original) else {
            Issue.record("エンコード結果が JSON オブジェクトではありません")
            return
        }
        #expect(root["masks"] != nil)
        root["masks"] = nil

        let decoded = try decodeParameters(.object(root))

        #expect(decoded.masks.isEmpty)
        #expect(decoded.exposure == original.exposure)
        #expect(decoded.contrast == -30)
        #expect(decoded.saturation == original.saturation)
        #expect(decoded.lensDistortion == 12)

        var expected = original
        expected.masks = []
        #expect(decoded == expected)
    }

    @Test func unknownMaskSourceDecodesToUnrecognizedAndReEncodesVerbatim() throws {
        let placeholder = MaskLayer(
            id: UUID(), name: "future", source: .none, adjustments: LocalAdjustments()
        )
        var parameters = DevelopParameters.neutral
        parameters.masks = [placeholder]

        let unknownSource = JSONValue.object([
            "type": .string("luminanceRange"),
            "payload": .object([
                "min": .number(0.2),
                "max": .number(0.8),
                "smooth": .bool(true),
                "label": .string("highlights"),
                "unused": .null
            ]),
            "extra": .array([.number(1), .string("a"), .bool(false)])
        ])

        guard case .object(var root) = try jsonValue(of: parameters),
              case .array(let maskValues) = root["masks"] ?? .null,
              case .object(var maskObject) = maskValues[0] else {
            Issue.record("エンコード結果の masks 配列を取り出せませんでした")
            return
        }
        maskObject["source"] = unknownSource
        root["masks"] = .array([.object(maskObject)])

        let decoded = try decodeParameters(.object(root))

        guard case .unrecognized(let type, let raw) = decoded.masks.first?.source else {
            Issue.record("未知の type が .unrecognized へ落ちていません")
            return
        }
        #expect(type == "luminanceRange")
        #expect(raw == unknownSource)

        // 再エンコードしても payload が意味的に同一で戻ること
        guard case .object(let reRoot) = try jsonValue(of: decoded),
              case .array(let reMasks) = reRoot["masks"] ?? .null,
              case .object(let reMask) = reMasks[0] else {
            Issue.record("再エンコード結果の masks 配列を取り出せませんでした")
            return
        }
        #expect(reMask["source"] == unknownSource)
    }

    @Test func applyingDeltaAppendsMasksWithFreshIdentifiers() {
        let base = makeMaskedParameters()
        var delta = DevelopParameters.neutral
        delta.masks = [
            MaskLayer(
                id: UUID(),
                name: "delta",
                source: .radialGradient(
                    RadialGradientMask(
                        center: NormalizedPoint(x: 0.5, y: 0.5),
                        radius: 0.2, aspectRatio: 1, rotationDegrees: 0, falloff: 0.5
                    )
                ),
                adjustments: makeAdjustments()
            )
        ]

        let applied = base.applying(delta: delta)

        #expect(applied.masks.count == 4)
        #expect(Array(applied.masks.prefix(3)) == base.masks)

        let appended = applied.masks.last
        #expect(appended?.id != delta.masks[0].id)
        #expect(appended?.name == "delta")
        #expect(appended?.source == delta.masks[0].source)

        // 同じプリセットを 2 回当てても id が重複しない
        let twice = applied.applying(delta: delta)
        let identifiers = Set(twice.masks.map(\.id))
        #expect(twice.masks.count == 5)
        #expect(identifiers.count == 5)
    }

    @Test func neutralParametersHaveNoMasks() {
        #expect(DevelopParameters.neutral.masks.isEmpty)
        #expect(DevelopParameters.neutral.isNeutral)

        var withMask = DevelopParameters.neutral
        withMask.masks = [
            MaskLayer(id: UUID(), name: "m", source: .none, adjustments: LocalAdjustments())
        ]
        #expect(!withMask.isNeutral)
    }
}

struct JSONValueTests {

    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func primitivesRoundTrip() throws {
        #expect(try roundTrip(.string("テキスト")) == .string("テキスト"))
        #expect(try roundTrip(.number(-12.5)) == .number(-12.5))
        #expect(try roundTrip(.bool(true)) == .bool(true))
        #expect(try roundTrip(.bool(false)) == .bool(false))
        #expect(try roundTrip(.null) == .null)
    }

    @Test func nestedContainersRoundTrip() throws {
        let value = JSONValue.object([
            "array": .array([.number(1), .string("two"), .bool(false), .null]),
            "nested": .object([
                "inner": .array([.object(["deep": .number(0.25)])])
            ]),
            "empty": .object([:])
        ])

        #expect(try roundTrip(value) == value)
    }

    /// 真偽値が数値として読まれないこと（`true` が `.number(1)` に化けると payload が壊れる）。
    @Test func booleansDoNotDecodeAsNumbers() throws {
        let data = try #require("""
            {"flag": true, "count": 1}
            """.data(using: .utf8))

        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == .object(["flag": .bool(true), "count": .number(1)]))
    }
}
