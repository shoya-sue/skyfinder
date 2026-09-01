#!/bin/bash
# G0-2: 同梱する rclone を公式リリースから取得し、SHA-256 を検証して配置する。
# 冪等: 配置済みのバイナリが期待ハッシュと一致すれば何もしない。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/SkyFolder/Resources/rclone"
SHA_RECORD="${DEST}.sha256"

# docs/BUNDLED.md と一致させること。上げるときは §14.1 の検証を再実施する（R-G06）。
RCLONE_VERSION="v1.75.0"
EXPECTED_SHA256="f52ccc22e6fe61ea5791f0e186db323155ad1cc1b6dfe547f4bc665bea57a2dd"
URL="https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-osx-arm64.zip"

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -f "$DEST" ]]; then
  actual="$(sha_of "$DEST")"
  if [[ "$actual" == "$EXPECTED_SHA256" ]]; then
    printf '%s  %s\n' "$EXPECTED_SHA256" "$RCLONE_VERSION" > "$SHA_RECORD"
    echo "[fetch-rclone] 配置済み・ハッシュ一致（${RCLONE_VERSION}）。何もしない。"
    exit 0
  fi
  echo "[fetch-rclone] 配置済みだがハッシュ不一致。取り直す。" >&2
  echo "  期待: ${EXPECTED_SHA256}" >&2
  echo "  実際: ${actual}" >&2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[fetch-rclone] 取得: ${URL}"
curl -fsSL --retry 3 -o "${TMP}/rclone.zip" "$URL"
unzip -q "${TMP}/rclone.zip" -d "${TMP}/x"

BIN="$(find "${TMP}/x" -type f -name rclone -perm -u+x | head -1)"
if [[ -z "$BIN" ]]; then
  echo "[fetch-rclone] 展開物に rclone バイナリが見つからない" >&2
  exit 1
fi

actual="$(sha_of "$BIN")"
if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
  echo "[fetch-rclone] SHA-256 検証に失敗。配置しない（SEC NOTE: サプライチェーン）" >&2
  echo "  期待: ${EXPECTED_SHA256}" >&2
  echo "  実際: ${actual}" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST"
chmod +x "$DEST"
# T-G30: .app 内の rclone は署名でハッシュが変わるため、
# docs/BUNDLED.md と照合できる「配布物のハッシュ」を別ファイルで同梱する。
printf '%s  %s\n' "$EXPECTED_SHA256" "$RCLONE_VERSION" > "$SHA_RECORD"
echo "[fetch-rclone] 配置完了: ${DEST}"
echo "[fetch-rclone] ${RCLONE_VERSION} / sha256=${actual}"
