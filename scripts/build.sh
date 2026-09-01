#!/bin/bash
# 一括ビルド。何度実行しても同じ結果になる（§8.6 の冪等性と同じ考え方）。
#
#   ./scripts/build.sh                 … Debug ビルド
#   ./scripts/build.sh release         … Release ビルド（ad-hoc 署名）
#   ./scripts/build.sh release dmg     … Release + DMG 作成
#
# Developer ID で署名する場合（G5-2）:
#   SKYFOLDER_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#   SKYFOLDER_TEAM_ID=TEAMID ./scripts/build.sh release dmg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="Debug"
MAKE_DMG="no"
for arg in "$@"; do
  case "$arg" in
    release) CONFIG="Release" ;;
    debug)   CONFIG="Debug" ;;
    dmg)     MAKE_DMG="yes" ;;
    *) echo "不明な引数: $arg" >&2; exit 1 ;;
  esac
done

SIGN_IDENTITY="${SKYFOLDER_SIGN_IDENTITY:--}"
TEAM_ID="${SKYFOLDER_TEAM_ID:-}"

echo "==> 1/5 同梱 rclone（SHA-256 検証つき）"
./scripts/fetch-rclone.sh

echo "==> 2/5 アセット生成（原本 → Assets.xcassets）"
./scripts/make-assets.sh

echo "==> 3/5 Xcode プロジェクト生成"
command -v xcodegen >/dev/null || { echo "xcodegen がありません（brew install xcodegen）" >&2; exit 1; }
xcodegen generate --quiet

echo "==> 4/5 ビルド (${CONFIG}) — 署名: ${SIGN_IDENTITY}"
xcodebuild -project SkyFolder.xcodeproj -scheme SkyFolder -configuration "$CONFIG" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
  build | grep -E '(error:|warning:.*\.swift|BUILD)' || true

BUILD_DIR="$(xcodebuild -project SkyFolder.xcodeproj -scheme SkyFolder -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)"
APP="${BUILD_DIR}/SkyFolder.app"
[ -d "$APP" ] || { echo "ビルド成果物がありません: $APP" >&2; exit 1; }

echo "==> 5/5 検証"
echo "--- 署名 ---"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|CodeDirectory|Signature|TeamIdentifier' || true
echo "--- 同梱 rclone の署名（ネストされた実行可能ファイル）---"
codesign -dv "$APP/Contents/Resources/rclone" 2>&1 | grep -E 'Identifier|CodeDirectory' || true
echo "--- 自己診断 ---"
"$APP/Contents/MacOS/SkyFolder" --selftest

if [ "$SIGN_IDENTITY" = "-" ]; then
  cat <<'NOTE'

注意: ad-hoc 署名です。Developer ID 証明書が無いため、
      T-G28（Developer ID + 公証チケット）と T-G29（別 Mac で Gatekeeper 警告なし）は達成できません。
      Apple Developer Program 加入後に SKYFOLDER_SIGN_IDENTITY を指定して再実行してください。
NOTE
fi

if [ "$MAKE_DMG" = "yes" ]; then
  echo "==> DMG 作成"
  DIST="${REPO_ROOT}/dist"
  mkdir -p "$DIST"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="${DIST}/SkyFolder.dmg"
  rm -f "$DMG"
  hdiutil create -volname "SkyFolder" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  echo "作成: $DMG"

  if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> 公証（notarytool）"
    echo "  次のコマンドを実行してください（Apple ID の認証情報が要ります）:"
    echo "    xcrun notarytool submit \"$DMG\" --keychain-profile skyfolder --wait"
    echo "    xcrun stapler staple \"$DMG\""
  else
    echo "  ad-hoc 署名のため公証はできません（G5-3）。"
  fi
fi
