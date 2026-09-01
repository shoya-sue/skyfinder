#!/bin/bash
# 全テスト（単体 + rcd 統合）を実行する。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
./scripts/fetch-rclone.sh >/dev/null
xcodegen generate --quiet
xcodebuild -project SkyFolder.xcodeproj -scheme SkyFolderKit -configuration Debug test \
  2>&1 | grep -aE '(error:|✘|Test run with)' || true
