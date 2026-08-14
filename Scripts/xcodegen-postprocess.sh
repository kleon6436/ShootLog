#!/usr/bin/env python3
"""xcodegen generate 直後に走る後処理パッチ (options.postGenCommand から呼ばれる)。

XcodeGen の project.yml オプションでは制御できない、Xcode 側が
プロジェクトを開いて保存した際にのみ付与/整形されるメタデータを
決定論的な文字列置換で補正する。対象パターンが見つからない場合は
「既に正しい状態」か「xcodegen の出力形式が変わった」のどちらかなので、
後者を静かに見逃さないよう、両方に該当しない場合はエラー終了する。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "ShootLog.xcodeproj" / "project.pbxproj"
XCSCHEME = (
    ROOT
    / "ShootLog.xcodeproj"
    / "xcshareddata"
    / "xcschemes"
    / "ShootLog.xcscheme"
)


def replace_or_skip(text: str, generated: str, desired: str, label: str) -> str:
    """generated パターンを desired に置換する。既に desired 側ならスキップ。"""
    if desired in text:
        return text
    if generated not in text:
        sys.exit(
            f"[xcodegen-postprocess] {label}: 想定パターンが見つからない。"
            f" xcodegen の出力形式が変わった可能性。パッチスクリプトの見直しが必要。"
        )
    return text.replace(generated, desired, 1)


def patch_pbxproj() -> None:
    text = PBXPROJ.read_text()
    text = replace_or_skip(
        text,
        'isa = PBXFileReference; path = realesrgan.mlpackage;',
        'isa = PBXFileReference; lastKnownFileType = folder.mlpackage; path = realesrgan.mlpackage;',
        "project.pbxproj: realesrgan.mlpackage",
    )

    # DEVELOPMENT_TEAM を buildSettings に書くと、xcodegen は
    # PBXProject.attributes.TargetAttributes にも DevelopmentTeam を
    # 重複して書き込む。正しい状態はこの重複エントリを持たないため除去する。
    dev_team_pattern = re.compile(r"\n[ \t]*DevelopmentTeam = 235777R328;")
    if dev_team_pattern.search(text):
        text = dev_team_pattern.sub("", text)

    PBXPROJ.write_text(text)


def patch_xcscheme() -> None:
    text = XCSCHEME.read_text()

    text = replace_or_skip(
        text,
        'LastUpgradeVersion = "1600"',
        'LastUpgradeVersion = "2660"',
        "Scheme.LastUpgradeVersion",
    )

    text = replace_or_skip(
        text,
        '\n   version = "1.7">',
        '\n   version = "1.3">',
        "Scheme.version",
    )

    text = replace_or_skip(
        text,
        'buildImplicitDependencies = "YES"\n      runPostActionsOnFailure = "NO">',
        'buildImplicitDependencies = "YES">',
        "BuildAction.runPostActionsOnFailure",
    )

    text = replace_or_skip(
        text,
        'shouldUseLaunchSchemeArgsEnv = "YES"\n      onlyGenerateCoverageForSpecifiedTargets = "NO">',
        'shouldUseLaunchSchemeArgsEnv = "YES">',
        "TestAction.onlyGenerateCoverageForSpecifiedTargets",
    )

    empty_cmdline_pattern = re.compile(
        r"\n\s*<CommandLineArguments>\s*\n\s*</CommandLineArguments>"
    )
    text = empty_cmdline_pattern.sub("", text)

    XCSCHEME.write_text(text)


def main() -> None:
    patch_pbxproj()
    patch_xcscheme()


if __name__ == "__main__":
    main()
