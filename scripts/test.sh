#!/bin/bash
# 全テスト（単体 + rcd 統合）を実行する。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
./scripts/fetch-rclone.sh >/dev/null
xcodegen generate --quiet

# **`| grep ... || true` で終わらせてはいけない。**
#
# grep は一致が無いと 1 を返すので `|| true` を付けたくなるが、それを付けると
# **xcodebuild 自身の失敗まで飲み込む**。実測: `false | grep x || true` の終了コードは 0。
# つまりテストが落ちてもこのスクリプトは成功として終わり、
# 呼び出し側（CI・リリース手順）は緑だと信じることになる。
#
# パイプの左側の終了コードを PIPESTATUS で取り出し、それで判定する。
set +e
xcodebuild -project SkyFolder.xcodeproj -scheme SkyFolderKit -configuration Debug test \
  2>&1 | grep -aE '(error:|failed|Test run with)'
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  echo "FAILED: xcodebuild exit=$status" >&2
  exit "$status"
fi
