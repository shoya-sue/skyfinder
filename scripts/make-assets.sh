#!/bin/bash
# G0-4: 原本 → Assets.xcassets の派生物。何度実行しても同じ結果になる。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec swift "${REPO_ROOT}/scripts/make-assets.swift" "${REPO_ROOT}"
