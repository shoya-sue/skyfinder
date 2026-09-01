#!/bin/bash
# G0-2: 同梱する rclone を公式リリースから取得し、SHA-256 を検証して配置する。
# 冪等: 配置済みのバイナリが期待ハッシュと一致すれば何もしない。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/SkyFolder/Resources/rclone"
SHA_RECORD="${DEST}.sha256"
# rclone は MIT ライセンス。バイナリを再配布する以上、著作権表示と許諾文の同梱が要る。
# 公式の配布 zip に LICENSE ファイルは入っておらず、本文は README.txt の中にあるため、
# **配布物そのものから抜き出す**（別途 GitHub から取ると、同梱するバージョンとずれうる）。
LICENSE_DEST="${REPO_ROOT}/SkyFolder/Resources/rclone-LICENSE.txt"

# docs/BUNDLED.md と一致させること。上げるときは §14.1 の検証を再実施する（R-G06）。
RCLONE_VERSION="v1.75.0"
EXPECTED_SHA256="f52ccc22e6fe61ea5791f0e186db323155ad1cc1b6dfe547f4bc665bea57a2dd"
URL="https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-osx-arm64.zip"

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -f "$DEST" ]]; then
  actual="$(sha_of "$DEST")"
  # ライセンス文が欠けている場合も取り直す。バイナリだけあっても配布できない。
  if [[ "$actual" == "$EXPECTED_SHA256" && -s "$LICENSE_DEST" ]]; then
    printf '%s  %s\n' "$EXPECTED_SHA256" "$RCLONE_VERSION" > "$SHA_RECORD"
    echo "[fetch-rclone] 配置済み・ハッシュ一致（${RCLONE_VERSION}）。何もしない。"
    exit 0
  fi
  if [[ "$actual" == "$EXPECTED_SHA256" ]]; then
    echo "[fetch-rclone] バイナリは一致するがライセンス文が無い。取り直す。" >&2
  else
    echo "[fetch-rclone] 配置済みだがハッシュ不一致。取り直す。" >&2
    echo "  期待: ${EXPECTED_SHA256}" >&2
    echo "  実際: ${actual}" >&2
  fi
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

# MIT ライセンス本文を README.txt から抜き出す。
# 取り出せなければ**配置しない** — ライセンス文の無いバイナリは再配布できない。
README_TXT="$(find "${TMP}/x" -type f -name README.txt | head -1)"
if [[ -z "$README_TXT" ]]; then
  echo "[fetch-rclone] 展開物に README.txt が無く、ライセンス本文を取り出せない" >&2
  exit 1
fi
# 終端は "…OTHER DEALINGS IN" で折り返された次の行 "    THE SOFTWARE." になる。
# 1 行に "DEALINGS IN THE SOFTWARE" は現れない（実測）。
awk '/Copyright \(C\) [0-9]+ by Nick Craig-Wood/,/^[[:space:]]*THE SOFTWARE\.[[:space:]]*$/' \
  "$README_TXT" > "${TMP}/license.txt"
license_lines="$(wc -l < "${TMP}/license.txt" | tr -d ' ')"
# 中身の検査に加えて**行数の上限**も見る。終端パターンが外れると awk は
# ファイル末尾まで出し続けるが、それはエラーにならず「取りすぎ」として通ってしまう。
if ! grep -q "Permission is hereby granted" "${TMP}/license.txt" \
  || ! grep -q "THE SOFTWARE IS PROVIDED" "${TMP}/license.txt" \
  || [[ "$license_lines" -gt 40 ]]; then
  echo "[fetch-rclone] README.txt から MIT ライセンス本文を取り出せなかった（${license_lines} 行）" >&2
  echo "  （README.txt の書式が変わった可能性がある。手で確認すること）" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST"
chmod +x "$DEST"
{
  echo "rclone ${RCLONE_VERSION} — MIT License"
  echo "https://rclone.org/  /  https://github.com/rclone/rclone"
  echo "本文は公式配布物 rclone-${RCLONE_VERSION}-osx-arm64.zip の README.txt から抽出したもの。"
  echo
  cat "${TMP}/license.txt"
} > "$LICENSE_DEST"
# T-G30: .app 内の rclone は署名でハッシュが変わるため、
# docs/BUNDLED.md と照合できる「配布物のハッシュ」を別ファイルで同梱する。
printf '%s  %s\n' "$EXPECTED_SHA256" "$RCLONE_VERSION" > "$SHA_RECORD"
echo "[fetch-rclone] 配置完了: ${DEST}"
echo "[fetch-rclone] ${RCLONE_VERSION} / sha256=${actual}"
echo "[fetch-rclone] ライセンス: ${LICENSE_DEST}"
