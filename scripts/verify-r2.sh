#!/bin/bash
# G1-9「実 R2 アカウントでの通し確認」。設計書 §11 が必須としているもの。
#
#   SKYFOLDER_ACCOUNT_ID=... SKYFOLDER_ACCESS_KEY_ID=... SKYFOLDER_SECRET_ACCESS_KEY=... \
#   SKYFOLDER_PRIVATE_BUCKET=... ./scripts/verify-r2.sh
#
# 秘密情報は環境変数からのみ受け取り、ディスクにも引数にも置かない（SEC-G01 / SEC-G02）。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="${SKYFOLDER_CONFIG:-Release}"
BUILD_DIR="$(xcodebuild -project SkyFolder.xcodeproj -scheme SkyFolder -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)"
APP="${BUILD_DIR}/SkyFolder.app"
if [ ! -d "$APP" ]; then
  echo "先に ./scripts/build.sh release を実行してください（$APP がありません）" >&2
  exit 1
fi
exec "$APP/Contents/MacOS/SkyFolder" --verify-r2
