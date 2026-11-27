#!/bin/sh
# 性能計測用の合成 JPEG フィクスチャ（F-SYN）を生成する。
# 使い方: Scripts/make-perf-fixtures.sh [出力先]（既定は ~/ShootLogPerfFixtures、リポジトリ外）
set -eu
script_dir=$(cd "$(dirname "$0")" && pwd)
exec xcrun swift "$script_dir/make-perf-fixtures.swift" "$@"
