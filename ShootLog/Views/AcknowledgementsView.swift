import SwiftUI

// 設定画面の「謝辞」タブ。超解像機能で使用する第三者の重み・アーキテクチャの著作権表示を掲載する。
// Real-ESRGANの重み(BSD-3-Clause)とRRDBNetアーキテクチャの移植元BasicSR(Apache-2.0)は
// 著作権者・ライセンスが別のため、それぞれ独立したセクションで表示する
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                Text("settings.acknowledgements.intro")
                    .foregroundStyle(.secondary)
            }

            Section("settings.acknowledgements.realesrgan.name") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.acknowledgements.realesrgan.copyright")
                    Text("settings.acknowledgements.realesrgan.license")
                    Link(realESRGANURL.absoluteString, destination: realESRGANURL)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
            }

            Section("settings.acknowledgements.basicsr.name") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.acknowledgements.basicsr.copyright")
                    Text("settings.acknowledgements.basicsr.license")
                    Link(basicSRURL.absoluteString, destination: basicSRURL)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("settings.tab.acknowledgements")
    }

    private var realESRGANURL: URL {
        URL(string: "https://github.com/xinntao/Real-ESRGAN") ?? URL(fileURLWithPath: "/")
    }

    private var basicSRURL: URL {
        URL(string: "https://github.com/XPixelGroup/BasicSR") ?? URL(fileURLWithPath: "/")
    }
}

#Preview {
    AcknowledgementsView()
        .frame(width: 460, height: 400)
}
